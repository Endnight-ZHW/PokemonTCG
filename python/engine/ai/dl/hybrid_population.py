"""Production ``hybrid_population_rl`` trainer.

This is an orchestration layer over the established rules-v5 rollout and model
training primitives.  Its important property is transactional progress: a
rollout batch is not counted until its replay shard and full population
checkpoint have both been atomically committed.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import random
import shutil
import subprocess
import time
from concurrent.futures import ProcessPoolExecutor
from collections import OrderedDict
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any, Iterable

from engine.ai.dl.encoder import (
    CARD_VOCAB_SHA256,
    CARD_VOCAB_SIZE,
    CARD_VOCAB_VERSION,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
)
from engine.ai.dl.model import (
    checkpoint_payload,
    create_model,
    load_checkpoint,
)
from engine.ai.dl.population_rollout import (
    PopulationGameResult,
    play_population_game,
)
from engine.ai.dl.production_contract import (
    HYBRID_POPULATION_TRAINER_VERSION,
    RELEASE_DECKS,
    TRAINER_HYBRID_POPULATION,
    PopulationPreset,
    PopulationTask,
    build_population_schedule,
    preset_for,
    validate_schedule_closure,
)
from engine.ai.dl.run_store import (
    CheckpointStore,
    ReplayShardStore,
    TrainingEventWriter,
    _atomic_torch_save,
    atomic_write_json,
    build_fingerprint,
    capture_rng_state,
    create_run_layout,
    read_json,
    resolve_within,
    restore_rng_state,
    runtime_environment,
    sha256_file,
    update_run,
    utc_now,
    validate_fingerprint,
)
from engine.ai.dl.training import (
    BootstrapTask,
    ChoiceTrainingExample,
    DeepTrainingTaskRunner,
    TrainingExample,
    _collect_rollout_batch,
    _forward_choice_batch,
    _make_grad_scaler,
    _model_from_worker_payload,
    _model_payload_for_worker,
    _train_choice_examples,
    _train_examples,
    _worker_init,
)

try:
    import torch
except Exception:  # pragma: no cover
    torch = None


REPLAY_CAPACITY_PER_DECK = 50_000
CHOICE_REPLAY_CAPACITY_PER_DECK = 50_000
CHOICE_VALIDATION_CAPACITY_PER_DECK = 10_000
CHOICE_REPLAY_RATIO = 0.20
DEFAULT_LEARNING_RATE = 5e-4
ACTION_MIX = {
    "fresh": 0.50,
    "replay": 0.30,
    "teacher": 0.20,
}
FINGERPRINT_FILES = (
    "python/data/ai_card_vocab.json",
    "python/data/deck_definitions.py",
    "python/engine/game_engine.py",
    "python/engine/game_state.py",
    "python/engine/ai/challenge_ai.py",
    "python/engine/ai/observation.py",
    "python/engine/ai/training.py",
    "python/engine/ai/dl/hybrid_population.py",
    "python/engine/ai/dl/population_rollout.py",
    "python/engine/ai/dl/mcts.py",
    "python/engine/ai/planner.py",
)

_WORKER_MODEL_CACHE: OrderedDict[str, Any] = OrderedDict()
_WORKER_MODEL_CACHE_CAPACITY = 4


class TrainingCancelled(RuntimeError):
    pass


@dataclass(frozen=True)
class HybridPopulationConfig:
    preset: str
    decks: tuple[str, ...]
    seed: int
    teacher_games: int
    dagger_games: int
    generations: int
    games_per_matchup: int
    current_generation_games: int
    historical_games: int
    mcts_simulations: int
    rollout_workers: int
    batch_size: int
    max_steps: int
    rollout_batch_games: int
    use_amp: bool
    device: str
    teacher_search_preset: str
    promotable: bool
    learning_rate: float = DEFAULT_LEARNING_RATE
    updates_per_rollout: int = 2
    model_variant: str = "v6_cross_attention"

    @classmethod
    def from_preset(
        cls,
        preset: PopulationPreset | str,
        *,
        seed: int = 17,
        smoke_deck: str | None = None,
        model_variant: str = "v6_cross_attention",
    ) -> "HybridPopulationConfig":
        selected = preset_for(preset) if isinstance(preset, str) else preset
        if selected.name == "release" and int(seed) != 17:
            raise ValueError(
                "The promotable Release preset is fixed to seed 17"
            )
        decks = selected.decks
        if selected.name == "smoke" and smoke_deck:
            if smoke_deck not in RELEASE_DECKS:
                raise ValueError(f"Unknown Smoke deck: {smoke_deck}")
            decks = (smoke_deck,)
        normalized_variant = str(model_variant).strip().lower()
        if normalized_variant not in {
            "v6_pooled",
            "v6_cross_attention",
        }:
            raise ValueError(
                f"Unknown Deep AI model variant: {model_variant!r}"
            )
        return cls(
            preset=selected.name,
            decks=tuple(decks),
            seed=int(seed),
            teacher_games=selected.teacher_games,
            dagger_games=selected.dagger_games,
            generations=selected.generations,
            games_per_matchup=selected.games_per_matchup,
            current_generation_games=selected.current_generation_games,
            historical_games=selected.historical_games,
            mcts_simulations=selected.mcts_simulations,
            rollout_workers=selected.rollout_workers,
            batch_size=selected.batch_size,
            max_steps=selected.max_steps,
            rollout_batch_games=selected.rollout_batch_games,
            use_amp=selected.use_amp,
            device=selected.device,
            teacher_search_preset=selected.teacher_search_preset,
            promotable=selected.promotable,
            model_variant=normalized_variant,
        )

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["decks"] = list(self.decks)
        return result


def _effective_device(requested: str) -> tuple[str, str]:
    if torch is None:
        raise RuntimeError("PyTorch is required for hybrid_population_rl")
    value = str(requested or "cpu")
    if value.startswith("cuda") and not torch.cuda.is_available():
        return "cpu", "CUDA requested but torch.cuda.is_available() is false"
    return value, ""


def prepare_hybrid_run(
    repo_root: str | os.PathLike[str],
    runs_root: str | os.PathLike[str],
    run_id: str,
    config: HybridPopulationConfig,
) -> Path:
    root = Path(repo_root).resolve()
    config_payload = config.to_dict()
    fingerprint = build_fingerprint(
        root,
        config_payload,
        extra_files=FINGERPRINT_FILES,
    )
    return create_run_layout(
        runs_root,
        run_id,
        run_payload={
            "trainer": TRAINER_HYBRID_POPULATION,
            "trainer_version": HYBRID_POPULATION_TRAINER_VERSION,
            "preset": config.preset,
            "status": "created",
            "resumable": True,
            "promotable": bool(config.promotable),
            "config": config_payload,
            "fingerprint": fingerprint,
            "environment": runtime_environment(),
            "pid": 0,
            "progress": {"stage": "created", "completed": 0, "total": 0},
            "gate": {
                "status": "not_evaluated",
                "evidence_sha256": "",
                "checks": {},
            },
        },
    )


def load_hybrid_config(run_dir: str | os.PathLike[str]) -> HybridPopulationConfig:
    payload = read_json(Path(run_dir) / "run.json")
    config = dict(payload.get("config") or {})
    config["decks"] = tuple(config.get("decks") or ())
    return HybridPopulationConfig(**config)


def _sample_rows(
    rows: list[TrainingExample],
    count: int,
    rng: random.Random,
) -> list[TrainingExample]:
    count = max(0, int(count))
    if count <= 0 or not rows:
        return []
    if len(rows) >= count:
        return rng.sample(rows, count)
    return [rows[rng.randrange(len(rows))] for _ in range(count)]


def mix_action_training_rows(
    fresh: list[TrainingExample],
    replay: list[TrainingExample],
    teacher: list[TrainingExample],
    *,
    rng: random.Random,
) -> tuple[list[TrainingExample], dict[str, int]]:
    """Return the fixed 50%/30%/20% production action mix."""

    if not fresh:
        return [], {"fresh": 0, "replay": 0, "teacher": 0}
    # Work in ten-row units so 50/30/20 is exact even for tiny rollout groups.
    # The fresh half always contains every newly generated trajectory row.
    units = max(1, math.ceil(len(fresh) / 5))
    total = units * 10
    fresh_count = units * 5
    replay_count = units * 3
    teacher_count = units * 2
    mixed = list(fresh)
    mixed.extend(_sample_rows(fresh, fresh_count - len(fresh), rng))
    replay_rows = _sample_rows(replay, replay_count, rng)
    teacher_rows = _sample_rows(teacher, teacher_count, rng)
    missing = (replay_count - len(replay_rows)) + (teacher_count - len(teacher_rows))
    mixed.extend(replay_rows)
    mixed.extend(teacher_rows)
    if missing > 0:
        mixed.extend(_sample_rows(fresh, missing, rng))
        fresh_count += missing
    return mixed, {
        "fresh": fresh_count,
        "replay": len(replay_rows),
        "teacher": len(teacher_rows),
    }


def split_choice_examples(
    examples: Iterable[ChoiceTrainingExample],
) -> tuple[list[ChoiceTrainingExample], list[ChoiceTrainingExample]]:
    """Stable game-key hash split: 90% train/replay and 10% validation."""

    train: list[ChoiceTrainingExample] = []
    validation: list[ChoiceTrainingExample] = []
    for example in examples:
        split_key = str(getattr(example, "split_key", "") or "")
        if not split_key:
            raise ValueError("DAgger Choice example has no stable split_key")
        bucket = int.from_bytes(
            hashlib.sha256(split_key.encode("utf-8")).digest()[:8],
            "big",
        ) % 10
        (validation if bucket == 0 else train).append(example)
    return train, validation


def _choice_metric_group(
    model: Any,
    examples: list[ChoiceTrainingExample],
    *,
    device: str,
    batch_size: int = 256,
) -> dict[str, Any]:
    if not examples:
        return {"count": 0, "top1": 0.0, "nll": 0.0, "ece10": 0.0}
    correct: list[float] = []
    confidence: list[float] = []
    losses: list[float] = []
    model.eval()
    with torch.no_grad():
        for start in range(0, len(examples), max(1, int(batch_size))):
            batch = examples[start:start + max(1, int(batch_size))]
            logits, mask = _forward_choice_batch(model, batch, device)
            if logits is None or mask is None:
                continue
            for index, example in enumerate(batch):
                count = int(mask[index].sum().item())
                target = int(example.teacher_target_index)
                if count <= 0 or target < 0 or target >= count:
                    continue
                probabilities = torch.softmax(
                    logits[index, :count].float(),
                    dim=0,
                )
                predicted = int(torch.argmax(probabilities).item())
                probability = float(probabilities[predicted].item())
                target_probability = max(
                    1e-12,
                    float(probabilities[target].item()),
                )
                correct.append(1.0 if predicted == target else 0.0)
                confidence.append(probability)
                losses.append(-math.log(target_probability))
    sample_count = len(correct)
    if sample_count <= 0:
        return {"count": 0, "top1": 0.0, "nll": 0.0, "ece10": 0.0}
    ece = 0.0
    for bin_index in range(10):
        members = [
            row
            for row, value in enumerate(confidence)
            if min(9, int(value * 10.0)) == bin_index
        ]
        if not members:
            continue
        accuracy = sum(correct[row] for row in members) / len(members)
        mean_confidence = (
            sum(confidence[row] for row in members) / len(members)
        )
        ece += (
            len(members)
            / sample_count
            * abs(accuracy - mean_confidence)
        )
    return {
        "count": sample_count,
        "top1": round(sum(correct) / sample_count, 6),
        "nll": round(sum(losses) / sample_count, 6),
        "ece10": round(ece, 6),
    }


def evaluate_choice_metrics(
    model: Any,
    examples: Iterable[ChoiceTrainingExample],
    *,
    device: str,
) -> dict[str, Any]:
    rows = list(examples)
    request_types = sorted(
        {str(example.request_type) for example in rows}
    )
    return {
        "overall": _choice_metric_group(model, rows, device=device),
        "request_types": {
            request_type: _choice_metric_group(
                model,
                [
                    example
                    for example in rows
                    if str(example.request_type) == request_type
                ],
                device=device,
            )
            for request_type in request_types
        },
    }


def choice_drift_gate(
    baseline: dict[str, Any],
    current: dict[str, Any],
) -> dict[str, Any]:
    failures: list[str] = []
    baseline_overall = dict(baseline.get("overall") or {})
    current_overall = dict(current.get("overall") or {})
    if int(baseline_overall.get("count") or 0) > 0:
        delta = (
            float(current_overall.get("top1") or 0.0)
            - float(baseline_overall.get("top1") or 0.0)
        )
        if delta < -0.02 - 1e-12:
            failures.append(f"overall_top1_delta={delta:.6f}")
    baseline_types = dict(baseline.get("request_types") or {})
    current_types = dict(current.get("request_types") or {})
    for request_type, baseline_row_value in baseline_types.items():
        baseline_row = dict(baseline_row_value or {})
        if int(baseline_row.get("count") or 0) < 50:
            continue
        current_row = dict(current_types.get(request_type) or {})
        delta = (
            float(current_row.get("top1") or 0.0)
            - float(baseline_row.get("top1") or 0.0)
        )
        if delta < -0.05 - 1e-12:
            failures.append(
                f"{request_type}_top1_delta={delta:.6f}"
            )
    return {"passed": not failures, "failures": failures}


def _gpu_metrics() -> dict[str, Any]:
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return {}
        values = [item.strip() for item in result.stdout.splitlines()[0].split(",")]
        return {
            "gpu_utilization_percent": float(values[0]),
            "gpu_memory_used_mb": float(values[1]),
            "gpu_memory_total_mb": float(values[2]),
        }
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}


def _population_group_worker(payload: dict[str, Any]) -> list[PopulationGameResult]:
    """Process-pool entry point with a four-model SHA-addressed LRU."""

    load_started = time.perf_counter()
    model_a, hit_a = _cached_worker_model(
        payload["model_a_sha"],
        payload["model_a_state"],
        payload["model_a_config"],
    )
    model_b, hit_b = _cached_worker_model(
        payload["model_b_sha"],
        payload["model_b_state"],
        payload["model_b_config"],
    )
    model_load_seconds = time.perf_counter() - load_started
    results = [
        play_population_game(
            PopulationTask(**row),
            model_a,
            model_b,
            device="cpu",
            max_steps=int(payload["max_steps"]),
            mcts_simulations=int(payload["mcts_simulations"]),
            teacher_search_preset=str(payload["teacher_search_preset"]),
            training_exploration=bool(
                payload.get("training_exploration", True)
            ),
            record_trajectories=bool(
                payload.get("record_trajectories", True)
            ),
        )
        for row in payload["tasks"]
    ]
    for index, result in enumerate(results):
        result.diagnostics["_worker"] = {
            "model_load_seconds": (
                model_load_seconds if index == 0 else 0.0
            ),
            "model_cache_hits": (
                int(hit_a) + int(hit_b) if index == 0 else 0
            ),
            "model_cache_size": len(_WORKER_MODEL_CACHE),
        }
    return results


def _model_payload_sha256(
    state: dict[str, Any],
    config: dict[str, Any],
) -> str:
    digest = hashlib.sha256(
        json.dumps(
            config,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )
    for key in sorted(state):
        tensor = state[key].detach().cpu().contiguous()
        digest.update(key.encode("utf-8"))
        digest.update(str(tensor.dtype).encode("ascii"))
        digest.update(str(tuple(tensor.shape)).encode("ascii"))
        digest.update(tensor.numpy().tobytes())
    return digest.hexdigest()


def _cached_worker_model(
    model_sha: str,
    state: dict[str, Any],
    config: dict[str, Any],
) -> tuple[Any, bool]:
    key = str(model_sha)
    cached = _WORKER_MODEL_CACHE.pop(key, None)
    if cached is not None:
        _WORKER_MODEL_CACHE[key] = cached
        return cached, True
    model = _model_from_worker_payload(state, config)
    _WORKER_MODEL_CACHE[key] = model
    while len(_WORKER_MODEL_CACHE) > _WORKER_MODEL_CACHE_CAPACITY:
        _WORKER_MODEL_CACHE.popitem(last=False)
    return model, False


class HybridPopulationTrainer:
    def __init__(
        self,
        repo_root: str | os.PathLike[str],
        run_dir: str | os.PathLike[str],
    ):
        if torch is None:
            raise RuntimeError("PyTorch is required for hybrid_population_rl")
        self.repo_root = Path(repo_root).resolve()
        self.run_dir = Path(run_dir).resolve()
        self.run = read_json(self.run_dir / "run.json")
        self.run_id = str(self.run.get("run_id", ""))
        self.config = load_hybrid_config(self.run_dir)
        self.device, self.device_fallback_reason = _effective_device(
            self.config.device
        )
        self.events = TrainingEventWriter(self.run_dir, self.run_id)
        self.checkpoints = CheckpointStore(self.run_dir)
        self.replay_store = ReplayShardStore(self.run_dir)
        self.models: dict[str, Any] = {}
        self.optimizers: dict[str, Any] = {}
        self.scalers: dict[str, Any] = {}
        self.completed: set[str] = set()
        self.counters: dict[str, Any] = {
            "teacher_games": {deck: 0 for deck in self.config.decks},
            "dagger_games": {deck: 0 for deck in self.config.decks},
            "generation": 0,
            "population_games": 0,
        }
        self.teacher_pool: dict[str, list[TrainingExample]] = {
            deck: [] for deck in self.config.decks
        }
        self.replay_pool: dict[str, list[TrainingExample]] = {
            deck: [] for deck in self.config.decks
        }
        self.choice_train_pool: dict[str, list[ChoiceTrainingExample]] = {
            deck: [] for deck in self.config.decks
        }
        self.choice_replay_pool: dict[str, list[ChoiceTrainingExample]] = {
            deck: [] for deck in self.config.decks
        }
        self.choice_validation_pool: dict[
            str, list[ChoiceTrainingExample]
        ] = {
            deck: [] for deck in self.config.decks
        }
        self.choice_baseline_metrics: dict[str, dict[str, Any]] = {}
        self.choice_metrics_history: list[dict[str, Any]] = []
        self.league_snapshots: list[dict[str, Any]] = []
        self.started = time.monotonic()
        self._last_pause_event = False
        self._fingerprint = build_fingerprint(
            self.repo_root,
            self.config.to_dict(),
            extra_files=FINGERPRINT_FILES,
        )
        validate_fingerprint(
            dict(self.run.get("fingerprint") or {}),
            self._fingerprint,
        )

    def _initialize(self) -> None:
        random.seed(self.config.seed)
        torch.manual_seed(self.config.seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(self.config.seed)
        try:
            torch.use_deterministic_algorithms(
                self.device == "cpu", warn_only=True
            )
            torch.set_float32_matmul_precision("high")
        except Exception:
            pass
        amp_enabled = bool(
            self.config.use_amp and self.device.startswith("cuda")
        )
        for index, deck in enumerate(self.config.decks):
            torch.manual_seed(self.config.seed + index * 1009)
            model = create_model(
                choice_head_enabled=True,
                candidate_cross_attention=(
                    self.config.model_variant
                    == "v6_cross_attention"
                ),
            )
            model.to(self.device)
            self.models[deck] = model
            optimizer = torch.optim.AdamW(
                model.parameters(),
                lr=self.config.learning_rate,
                weight_decay=1e-4,
            )
            self.optimizers[deck] = optimizer
            self.scalers[deck] = _make_grad_scaler(amp_enabled)

    def _load_replay_pools(self, referenced_rows: list[dict[str, Any]]) -> None:
        manifest_rows = {
            str(row.get("batch_id", "")): row
            for row in self.replay_store.rows(verify=True)
        }
        for reference in referenced_rows:
            batch_id = str(reference.get("batch_id", ""))
            row = manifest_rows.get(batch_id)
            if row is None or row.get("sha256") != reference.get("sha256"):
                raise RuntimeError(f"Replay shard reference mismatch: {batch_id}")
            path = resolve_within(
                self.run_dir / "replay", str(row.get("path", ""))
            )
            try:
                payload = torch.load(path, map_location="cpu", weights_only=False)
            except TypeError:
                payload = torch.load(path, map_location="cpu")
            if not isinstance(payload, dict):
                raise RuntimeError(f"Invalid replay shard: {path.name}")
            schema = dict(payload.get("data_schema") or {})
            expected_schema = {
                "encoder_version": ENCODER_SCHEMA_VERSION,
                "state_card_slots": STATE_CARD_SLOTS,
                "card_vocab_version": CARD_VOCAB_VERSION,
                "card_vocab_size": CARD_VOCAB_SIZE,
                "card_vocab_sha256": CARD_VOCAB_SHA256,
            }
            if schema != expected_schema:
                raise RuntimeError(
                    f"Replay shard encoder/vocabulary mismatch: {path.name}"
                )
            for deck, rows in dict(payload.get("teacher") or {}).items():
                if deck in self.teacher_pool:
                    self.teacher_pool[deck].extend(list(rows or []))
            for deck, rows in dict(payload.get("replay") or {}).items():
                if deck in self.replay_pool:
                    self.replay_pool[deck].extend(list(rows or []))
            for deck, rows in dict(payload.get("choice_train") or {}).items():
                if deck in self.choice_train_pool:
                    self.choice_train_pool[deck].extend(list(rows or []))
            for deck, rows in dict(payload.get("choice_replay") or {}).items():
                if deck in self.choice_replay_pool:
                    self.choice_replay_pool[deck].extend(list(rows or []))
            for deck, rows in dict(
                payload.get("choice_validation") or {}
            ).items():
                if deck in self.choice_validation_pool:
                    self.choice_validation_pool[deck].extend(
                        list(rows or [])
                    )
        self._trim_pools()

    def _resume(self) -> bool:
        latest = self.checkpoints.load_latest(map_location=self.device)
        if latest is None:
            return False
        payload, row = latest
        validate_fingerprint(
            dict(payload.get("fingerprint") or {}),
            self._fingerprint,
        )
        model_states = dict(payload.get("models") or {})
        if set(model_states) != set(self.config.decks):
            raise RuntimeError("Checkpoint model population is incomplete")
        for deck in self.config.decks:
            self.models[deck].load_state_dict(model_states[deck])
            self.models[deck].to(self.device)
            self.optimizers[deck].load_state_dict(
                dict(payload.get("optimizers") or {})[deck]
            )
            scaler_state = dict(payload.get("scalers") or {}).get(deck)
            if scaler_state is not None and self.scalers[deck] is not None:
                self.scalers[deck].load_state_dict(scaler_state)
        self.completed = set(payload.get("completed_task_ids") or ())
        self.counters = copy.deepcopy(payload.get("counters") or self.counters)
        self.league_snapshots = list(payload.get("league_snapshots") or [])
        self.choice_baseline_metrics = copy.deepcopy(
            payload.get("choice_baseline_metrics") or {}
        )
        self.choice_metrics_history = copy.deepcopy(
            payload.get("choice_metrics_history") or []
        )
        self._load_replay_pools(list(payload.get("replay_shards") or []))
        restore_rng_state(dict(payload.get("rng") or {}))
        self.events.emit(
            stage=str(payload.get("stage", "resume")),
            completed=len(self.completed),
            total=len(self.completed),
            metrics={"checkpoint_sha256": row["sha256"]},
            message=f"已从批次 {row['batch_id']} 恢复",
            event="run_resumed",
        )
        return True

    def _trim_pools(self) -> None:
        for deck in self.config.decks:
            if len(self.teacher_pool[deck]) > REPLAY_CAPACITY_PER_DECK:
                self.teacher_pool[deck] = self.teacher_pool[deck][
                    -REPLAY_CAPACITY_PER_DECK:
                ]
            if len(self.replay_pool[deck]) > REPLAY_CAPACITY_PER_DECK:
                self.replay_pool[deck] = self.replay_pool[deck][
                    -REPLAY_CAPACITY_PER_DECK:
                ]
            if (
                len(self.choice_train_pool[deck])
                > CHOICE_REPLAY_CAPACITY_PER_DECK
            ):
                self.choice_train_pool[deck] = self.choice_train_pool[deck][
                    -CHOICE_REPLAY_CAPACITY_PER_DECK:
                ]
            if (
                len(self.choice_replay_pool[deck])
                > CHOICE_REPLAY_CAPACITY_PER_DECK
            ):
                self.choice_replay_pool[deck] = self.choice_replay_pool[deck][
                    -CHOICE_REPLAY_CAPACITY_PER_DECK:
                ]
            if (
                len(self.choice_validation_pool[deck])
                > CHOICE_VALIDATION_CAPACITY_PER_DECK
            ):
                self.choice_validation_pool[deck] = (
                    self.choice_validation_pool[deck][
                        -CHOICE_VALIDATION_CAPACITY_PER_DECK:
                    ]
                )

    def _control_point(self, stage: str) -> None:
        cancel_path = self.run_dir / "cancel.request"
        pause_path = self.run_dir / "pause.request"
        if cancel_path.exists():
            raise TrainingCancelled("cancel requested")
        while pause_path.exists():
            if not self._last_pause_event:
                update_run(
                    self.run_dir,
                    status="paused",
                    resumable=True,
                    progress={
                        "stage": stage,
                        "completed": len(self.completed),
                        "total": len(self.completed),
                    },
                )
                self.events.emit(
                    stage=stage,
                    completed=len(self.completed),
                    total=len(self.completed),
                    message="训练已在批次边界暂停",
                    event="paused",
                )
                self._last_pause_event = True
            time.sleep(0.2)
            if cancel_path.exists():
                raise TrainingCancelled("cancel requested")
        if self._last_pause_event:
            update_run(self.run_dir, status="running")
            self.events.emit(
                stage=stage,
                completed=len(self.completed),
                total=len(self.completed),
                message="训练已恢复",
                event="resumed",
            )
            self._last_pause_event = False

    def _checkpoint_payload(self, stage: str) -> dict[str, Any]:
        return {
            "trainer": TRAINER_HYBRID_POPULATION,
            "trainer_version": HYBRID_POPULATION_TRAINER_VERSION,
            "run_id": self.run_id,
            "stage": stage,
            "fingerprint": self._fingerprint,
            "models": {
                deck: {
                    key: value.detach().cpu().clone()
                    for key, value in model.state_dict().items()
                }
                for deck, model in self.models.items()
            },
            "optimizers": {
                deck: optimizer.state_dict()
                for deck, optimizer in self.optimizers.items()
            },
            "scalers": {
                deck: (
                    scaler.state_dict()
                    if scaler is not None
                    else None
                )
                for deck, scaler in self.scalers.items()
            },
            "rng": capture_rng_state(),
            "completed_task_ids": sorted(self.completed),
            "counters": copy.deepcopy(self.counters),
            "league_snapshots": copy.deepcopy(self.league_snapshots[-3:]),
            "choice_baseline_metrics": copy.deepcopy(
                self.choice_baseline_metrics
            ),
            "choice_metrics_history": copy.deepcopy(
                self.choice_metrics_history
            ),
            "replay_shards": self.replay_store.rows(verify=True),
        }

    def _commit(
        self,
        batch_id: str,
        *,
        stage: str,
        shard_teacher: dict[str, list[TrainingExample]] | None = None,
        shard_replay: dict[str, list[TrainingExample]] | None = None,
        shard_choice_train: dict[
            str, list[ChoiceTrainingExample]
        ] | None = None,
        shard_choice_replay: dict[
            str, list[ChoiceTrainingExample]
        ] | None = None,
        shard_choice_validation: dict[
            str, list[ChoiceTrainingExample]
        ] | None = None,
        new_task_ids: Iterable[str] = (),
        metrics: dict[str, Any] | None = None,
        deck: str = "",
        completed: int = 0,
        total: int = 0,
    ) -> None:
        self.replay_store.write(
            batch_id,
            {
                "data_schema": {
                    "encoder_version": ENCODER_SCHEMA_VERSION,
                    "state_card_slots": STATE_CARD_SLOTS,
                    "card_vocab_version": CARD_VOCAB_VERSION,
                    "card_vocab_size": CARD_VOCAB_SIZE,
                    "card_vocab_sha256": CARD_VOCAB_SHA256,
                },
                "teacher": dict(shard_teacher or {}),
                "replay": dict(shard_replay or {}),
                "choice_train": dict(shard_choice_train or {}),
                "choice_replay": dict(shard_choice_replay or {}),
                "choice_validation": dict(
                    shard_choice_validation or {}
                ),
            },
        )
        self.completed.update(str(item) for item in new_task_ids)
        checkpoint = self.checkpoints.save(
            batch_id, self._checkpoint_payload(stage)
        )
        speed = len(self.completed) / max(1e-6, time.monotonic() - self.started)
        event_metrics = {
            **dict(metrics or {}),
            **_gpu_metrics(),
            "games_per_second": round(speed, 4),
            "replay_pool": {
                key: len(value) for key, value in self.replay_pool.items()
            },
            "teacher_pool": {
                key: len(value) for key, value in self.teacher_pool.items()
            },
            "choice_replay_pool": {
                key: len(value)
                for key, value in self.choice_replay_pool.items()
            },
            "choice_validation_pool": {
                key: len(value)
                for key, value in self.choice_validation_pool.items()
            },
            "checkpoint_sha256": checkpoint["sha256"],
        }
        update_run(
            self.run_dir,
            status="running",
            latest_checkpoint=checkpoint,
            progress={
                "stage": stage,
                "deck": deck,
                "completed": int(completed),
                "total": int(total),
                "metrics": event_metrics,
            },
        )
        self.events.emit(
            stage=stage,
            deck=deck,
            completed=completed,
            total=total,
            metrics=event_metrics,
            message=f"批次 {batch_id} 已原子提交",
            event="batch_committed",
        )

    def _train_teacher(self) -> None:
        stage = "teacher"
        worker_count = max(1, int(self.config.rollout_workers))
        with DeepTrainingTaskRunner(worker_count) as runner:
            for deck_index, deck in enumerate(self.config.decks):
                total = int(self.config.teacher_games)
                for start in range(0, total, self.config.rollout_batch_games):
                    self._control_point(stage)
                    count = min(self.config.rollout_batch_games, total - start)
                    task_ids = [
                        f"teacher:{deck}:{index}"
                        for index in range(start, start + count)
                    ]
                    if all(task_id in self.completed for task_id in task_ids):
                        continue
                    task_rows: list[BootstrapTask] = []
                    cursor = start
                    parts = min(worker_count, count)
                    for part in range(parts):
                        part_count = count // parts + (
                            1 if part < count % parts else 0
                        )
                        task_rows.append(
                            BootstrapTask(
                                deck,
                                self.config.seed + deck_index * 1009,
                                cursor,
                                part_count,
                                self.config.max_steps,
                                self.config.teacher_search_preset,
                            )
                        )
                        cursor += part_count
                    task_results = runner.run_bootstrap_tasks(task_rows)
                    examples = [
                        example
                        for rows in task_results
                        for example in rows
                    ]
                    result = _train_examples(
                        self.models[deck],
                        list(examples),
                        device=self.device,
                        learning_rate=self.config.learning_rate,
                        epochs=self.config.updates_per_rollout,
                        batch_size=self.config.batch_size,
                        entropy_coef=0.0,
                        optimizer=self.optimizers[deck],
                        grad_scaler=self.scalers[deck],
                        use_amp=bool(
                            self.config.use_amp
                            and self.device.startswith("cuda")
                        ),
                    )
                    self.teacher_pool[deck].extend(examples)
                    self.replay_pool[deck].extend(examples)
                    self._trim_pools()
                    self.counters["teacher_games"][deck] = start + count
                    self._commit(
                        f"teacher_{deck}_{start + count:05d}",
                        stage=stage,
                        shard_teacher={deck: examples},
                        shard_replay={deck: examples},
                        new_task_ids=task_ids,
                        metrics=result,
                        deck=deck,
                        completed=start + count,
                        total=total,
                    )

    def _train_dagger(self) -> None:
        stage = "dagger"
        worker_count = max(1, int(self.config.rollout_workers))
        with DeepTrainingTaskRunner(worker_count) as runner:
            for deck_index, deck in enumerate(self.config.decks):
                total = int(self.config.dagger_games)
                base_seed = self.config.seed + deck_index * 1009 + 300_000
                for start in range(0, total, self.config.rollout_batch_games):
                    self._control_point(stage)
                    count = min(self.config.rollout_batch_games, total - start)
                    task_ids = [
                        f"dagger:{deck}:{index}"
                        for index in range(start, start + count)
                    ]
                    if all(task_id in self.completed for task_id in task_ids):
                        continue
                    seeds = [
                        base_seed + index * 109
                        for index in range(start, start + count)
                    ]
                    rows = _collect_rollout_batch(
                        self.models[deck],
                        deck,
                        seeds,
                        device=self.device,
                        max_steps=self.config.max_steps,
                        workers=worker_count,
                        teacher_search_preset=self.config.teacher_search_preset,
                        teacher_label_model_states=True,
                        phase_tag="dagger",
                        task_runner=runner,
                    )
                    action_examples: list[TrainingExample] = []
                    choice_examples: list[ChoiceTrainingExample] = []
                    wins = losses = draws = 0
                    for winner, _score, examples, choices, _diagnostics in rows:
                        action_examples.extend(
                            item for item in examples if item.source == "dagger"
                        )
                        choice_examples.extend(choices)
                        if winner == 0:
                            wins += 1
                        elif winner == 1:
                            losses += 1
                        else:
                            draws += 1
                    choice_train, choice_validation = split_choice_examples(
                        choice_examples
                    )
                    action_result = _train_examples(
                        self.models[deck],
                        action_examples,
                        device=self.device,
                        learning_rate=self.config.learning_rate * 0.6,
                        epochs=self.config.updates_per_rollout,
                        batch_size=self.config.batch_size,
                        entropy_coef=0.005,
                        optimizer=self.optimizers[deck],
                        grad_scaler=self.scalers[deck],
                        use_amp=bool(
                            self.config.use_amp
                            and self.device.startswith("cuda")
                        ),
                    )
                    choice_result = _train_choice_examples(
                        self.models[deck],
                        choice_train,
                        device=self.device,
                        learning_rate=self.config.learning_rate * 0.6,
                        epochs=self.config.updates_per_rollout,
                        batch_size=self.config.batch_size,
                        optimizer=self.optimizers[deck],
                        grad_scaler=self.scalers[deck],
                        use_amp=bool(
                            self.config.use_amp
                            and self.device.startswith("cuda")
                        ),
                    )
                    self.teacher_pool[deck].extend(action_examples)
                    self.replay_pool[deck].extend(action_examples)
                    self.choice_train_pool[deck].extend(choice_train)
                    self.choice_replay_pool[deck].extend(choice_train)
                    self.choice_validation_pool[deck].extend(
                        choice_validation
                    )
                    self._trim_pools()
                    if start + count >= total:
                        self.choice_baseline_metrics[deck] = (
                            evaluate_choice_metrics(
                                self.models[deck],
                                self.choice_validation_pool[deck],
                                device=self.device,
                            )
                        )
                    self.counters["dagger_games"][deck] = start + count
                    self._commit(
                        f"dagger_{deck}_{start + count:05d}",
                        stage=stage,
                        shard_teacher={deck: action_examples},
                        shard_replay={deck: action_examples},
                        shard_choice_train={deck: choice_train},
                        shard_choice_replay={deck: choice_train},
                        shard_choice_validation={
                            deck: choice_validation
                        },
                        new_task_ids=task_ids,
                        metrics={
                            **action_result,
                            **choice_result,
                            "wins": wins,
                            "losses": losses,
                            "draws": draws,
                            "choice_validation_examples": len(
                                choice_validation
                            ),
                            "choice_baseline": self.choice_baseline_metrics.get(
                                deck,
                                {},
                            ),
                        },
                        deck=deck,
                        completed=start + count,
                        total=total,
                    )

    def _save_generation_snapshot(self, generation: int) -> dict[str, Any]:
        directory = self.run_dir / "league" / f"generation_{generation}"
        directory.mkdir(parents=True, exist_ok=True)
        models: dict[str, Any] = {}
        for deck, model in self.models.items():
            path = directory / f"{deck}.pt"
            _atomic_torch_save(
                path,
                checkpoint_payload(
                    model,
                    {
                        "trainer": TRAINER_HYBRID_POPULATION,
                        "run_id": self.run_id,
                        "deck": deck,
                        "generation": generation,
                        "accepted": False,
                        "verified": False,
                    },
                ),
            )
            models[deck] = {
                "path": str(path.relative_to(self.run_dir).as_posix()),
                "sha256": sha256_file(path),
            }
        row = {
            "generation": generation,
            "created_at": utc_now(),
            "models": models,
        }
        self.league_snapshots = [
            item
            for item in self.league_snapshots
            if int(item.get("generation", -1)) != generation
        ]
        self.league_snapshots.append(row)
        self.league_snapshots.sort(key=lambda item: int(item["generation"]))
        self.league_snapshots = self.league_snapshots[-3:]
        atomic_write_json(directory / "snapshot.json", row)
        return row

    def _snapshot_model_payload(
        self, generation: int, deck: str
    ) -> tuple[dict[str, Any], dict[str, Any], str]:
        if generation == int(self.counters.get("generation", 0)) + 1:
            state, config = _model_payload_for_worker(self.models[deck])
            return state, config, _model_payload_sha256(state, config)
        snapshot = next(
            (
                item
                for item in self.league_snapshots
                if int(item.get("generation", -1)) == generation
            ),
            None,
        )
        if snapshot is None:
            raise RuntimeError(f"League generation {generation} is unavailable")
        row = dict(snapshot.get("models") or {}).get(deck)
        if not isinstance(row, dict):
            raise RuntimeError(
                f"League generation {generation} lacks deck {deck}"
            )
        path = resolve_within(self.run_dir, str(row.get("path", "")))
        if sha256_file(path) != str(row.get("sha256", "")).lower():
            raise RuntimeError(f"League snapshot hash mismatch: {path.name}")
        model, _ = load_checkpoint(str(path), "cpu")
        state, config = _model_payload_for_worker(model)
        return state, config, str(row.get("sha256", "")).lower()

    def _group_requests(
        self,
        schedule: list[PopulationTask],
        current_payloads: dict[
            str,
            tuple[dict[str, Any], dict[str, Any], str],
        ],
    ) -> list[dict[str, Any]]:
        groups: dict[tuple[int, str, str], list[PopulationTask]] = {}
        for task in schedule:
            groups.setdefault(
                (
                    task.matchup_index,
                    task.opponent_kind,
                    "%s:%s" % (
                        task.history_generation,
                        task.history_side,
                    ),
                ),
                [],
            ).append(task)
        requests: list[dict[str, Any]] = []
        for key in sorted(groups):
            tasks = groups[key]
            if all(task.task_id in self.completed for task in tasks):
                continue
            first = tasks[0]
            if first.opponent_kind == "history":
                if first.history_side == "a":
                    state_a, config_a, sha_a = self._snapshot_model_payload(
                        int(first.history_generation), first.deck_a
                    )
                    state_b, config_b, sha_b = current_payloads[first.deck_b]
                elif first.history_side == "b":
                    state_a, config_a, sha_a = current_payloads[first.deck_a]
                    state_b, config_b, sha_b = self._snapshot_model_payload(
                        int(first.history_generation), first.deck_b
                    )
                else:
                    raise RuntimeError(
                        "Historical population task has no history side"
                    )
            else:
                state_a, config_a, sha_a = current_payloads[first.deck_a]
                state_b, config_b, sha_b = current_payloads[first.deck_b]
            requests.append(
                {
                    "tasks": [task.to_dict() for task in tasks],
                    "model_a_state": state_a,
                    "model_a_config": config_a,
                    "model_a_sha": sha_a,
                    "model_b_state": state_b,
                    "model_b_config": config_b,
                    "model_b_sha": sha_b,
                    "max_steps": self.config.max_steps,
                    "mcts_simulations": self.config.mcts_simulations,
                    "teacher_search_preset": self.config.teacher_search_preset,
                }
            )
        return requests

    @staticmethod
    def _current_trajectories(
        task: PopulationTask,
        result: PopulationGameResult,
    ) -> dict[str, list[TrainingExample]]:
        if task.opponent_kind != "history":
            collapsed: dict[str, list[TrainingExample]] = {}
            for owner, examples in result.trajectories.items():
                collapsed.setdefault(owner.split("@", 1)[0], []).extend(examples)
            return collapsed
        current_is_a = task.history_side == "b"
        current_deck = task.deck_a if current_is_a else task.deck_b
        current_player = (
            (1 if task.seat_a == 1 else 0)
            if current_is_a
            else (0 if task.seat_a == 1 else 1)
        )
        owner = f"{current_deck}@p{current_player}"
        return {
            current_deck: list(
                result.trajectories.get(
                    owner,
                    result.trajectories.get(current_deck, []),
                )
            )
        }

    def _train_population_group(
        self,
        generation: int,
        tasks: list[PopulationTask],
        results: list[PopulationGameResult],
    ) -> None:
        fresh_by_deck: dict[str, list[TrainingExample]] = {
            deck: [] for deck in self.config.decks
        }
        diagnostics = {
            "wins_a": 0,
            "losses_a": 0,
            "draws": 0,
            "invalid_actions": 0,
            "rule_exceptions": 0,
            "decision_timeouts": 0,
            "max_step_exhaustions": 0,
            "model_load_seconds": 0.0,
            "encoding_seconds": 0.0,
            "search_seconds": 0.0,
            "model_value_seconds": 0.0,
            "environment_step_seconds": 0.0,
            "reward_components": {},
            "search_samples": [],
        }
        for task, result in zip(tasks, results):
            for deck, examples in self._current_trajectories(task, result).items():
                fresh_by_deck[deck].extend(examples)
            if result.winner_player is None:
                diagnostics["draws"] += 1
            else:
                deck_a_player = 1 if task.seat_a == 1 else 0
                if result.winner_player == deck_a_player:
                    diagnostics["wins_a"] += 1
                else:
                    diagnostics["losses_a"] += 1
            for row in result.diagnostics.values():
                for key in (
                    "invalid_actions",
                    "rule_exceptions",
                    "decision_timeouts",
                    "max_step_exhaustions",
                ):
                    diagnostics[key] += int(row.get(key, 0))
                for key in (
                    "model_load_seconds",
                    "encoding_seconds",
                    "search_seconds",
                    "model_value_seconds",
                    "environment_step_seconds",
                ):
                    diagnostics[key] += float(row.get(key, 0.0))
                for component, value in dict(
                    row.get("reward_components") or {}
                ).items():
                    diagnostics["reward_components"][component] = (
                        float(
                            diagnostics["reward_components"].get(
                                component,
                                0.0,
                            )
                        )
                        + float(value)
                    )
                if len(diagnostics["search_samples"]) < 8:
                    remaining = 8 - len(diagnostics["search_samples"])
                    diagnostics["search_samples"].extend(
                        list(row.get("searches") or [])[:remaining]
                    )

        train_metrics: dict[str, Any] = {}
        shard_replay: dict[str, list[TrainingExample]] = {}
        for deck, fresh in fresh_by_deck.items():
            if not fresh:
                continue
            rng = random.Random(
                self.config.seed
                + generation * 1_000_003
                + tasks[0].matchup_index * 1009
                + RELEASE_DECKS.index(deck)
            )
            mixed, mix_counts = mix_action_training_rows(
                fresh,
                self.replay_pool[deck],
                self.teacher_pool[deck],
                rng=rng,
            )
            optimization_started = time.perf_counter()
            result = _train_examples(
                self.models[deck],
                mixed,
                device=self.device,
                learning_rate=self.config.learning_rate * 0.35,
                epochs=self.config.updates_per_rollout,
                batch_size=self.config.batch_size,
                optimizer=self.optimizers[deck],
                grad_scaler=self.scalers[deck],
                use_amp=bool(
                    self.config.use_amp and self.device.startswith("cuda")
                ),
            )
            choice_replay_count = int(
                math.ceil(len(mixed) * CHOICE_REPLAY_RATIO)
            )
            choice_replay = _sample_rows(
                self.choice_replay_pool[deck],
                choice_replay_count,
                rng,
            )
            choice_result = _train_choice_examples(
                self.models[deck],
                choice_replay,
                device=self.device,
                learning_rate=self.config.learning_rate * 0.35,
                epochs=self.config.updates_per_rollout,
                batch_size=self.config.batch_size,
                optimizer=self.optimizers[deck],
                grad_scaler=self.scalers[deck],
                use_amp=bool(
                    self.config.use_amp and self.device.startswith("cuda")
                ),
            )
            optimization_seconds = (
                time.perf_counter() - optimization_started
            )
            train_metrics[deck] = {
                **result,
                **choice_result,
                "mix": mix_counts,
                "choice_replay_requested": choice_replay_count,
                "choice_replay_sampled": len(choice_replay),
                "optimization_seconds": round(
                    optimization_seconds,
                    6,
                ),
            }
            self.replay_pool[deck].extend(fresh)
            shard_replay[deck] = fresh
        self._trim_pools()
        self.counters["population_games"] = int(
            self.counters.get("population_games", 0)
        ) + len(tasks)
        total_generation_games = len(
            build_population_schedule(
                generation=generation,
                decks=self.config.decks,
                base_seed=self.config.seed,
                games_per_matchup=self.config.games_per_matchup,
                current_generation_games=self.config.current_generation_games,
                historical_games=self.config.historical_games,
            )
        )
        generation_schedule = build_population_schedule(
            generation=generation,
            decks=self.config.decks,
            base_seed=self.config.seed,
            games_per_matchup=self.config.games_per_matchup,
            current_generation_games=self.config.current_generation_games,
            historical_games=self.config.historical_games,
        )
        done_in_generation = sum(
            task.task_id in self.completed for task in generation_schedule
        )
        batch_id = (
            f"generation_{generation}_matchup_{tasks[0].matchup_index:02d}_"
            f"{tasks[0].opponent_kind}_{tasks[0].history_side or 'both'}"
        )
        self._commit(
            batch_id,
            stage=f"population_generation_{generation}",
            shard_replay=shard_replay,
            new_task_ids=[task.task_id for task in tasks],
            metrics={
                **diagnostics,
                "losses": train_metrics,
                "opponent_kind": tasks[0].opponent_kind,
                "history_generation": tasks[0].history_generation,
            },
            deck=f"{tasks[0].deck_a} vs {tasks[0].deck_b}",
            completed=min(total_generation_games, done_in_generation + len(tasks)),
            total=total_generation_games,
        )

    def _record_choice_generation_metrics(
        self,
        generation: int,
    ) -> dict[str, Any]:
        decks: dict[str, Any] = {}
        failures: list[str] = []
        for deck in self.config.decks:
            current = evaluate_choice_metrics(
                self.models[deck],
                self.choice_validation_pool[deck],
                device=self.device,
            )
            baseline = copy.deepcopy(
                self.choice_baseline_metrics.get(deck)
                or {
                    "overall": {
                        "count": 0,
                        "top1": 0.0,
                        "nll": 0.0,
                        "ece10": 0.0,
                    },
                    "request_types": {},
                }
            )
            gate = choice_drift_gate(baseline, current)
            decks[deck] = {
                "baseline": baseline,
                "current": current,
                "gate": gate,
            }
            failures.extend(
                f"{deck}:{failure}"
                for failure in gate["failures"]
            )
        row = {
            "schema": "choice_drift_metrics_v1",
            "generation": int(generation),
            "created_at": utc_now(),
            "decks": decks,
            "passed": not failures,
            "failures": failures,
        }
        self.choice_metrics_history = [
            item
            for item in self.choice_metrics_history
            if int(item.get("generation", -1)) != int(generation)
        ]
        self.choice_metrics_history.append(row)
        atomic_write_json(
            self.run_dir
            / "evaluation"
            / f"choice_generation_{generation}.json",
            row,
        )
        self.events.emit(
            stage=f"population_generation_{generation}",
            completed=generation,
            total=self.config.generations,
            metrics={"choice_drift": row},
            message=(
                f"第 {generation} 代 Choice 验证通过"
                if not failures
                else f"第 {generation} 代 Choice 漂移门禁失败"
            ),
            event="choice_metrics",
        )
        if failures:
            raise RuntimeError(
                "Choice validation drift gate failed: "
                + "; ".join(failures)
            )
        return row

    def _train_population(self) -> None:
        if not self.league_snapshots:
            self._save_generation_snapshot(0)
        for generation in range(1, self.config.generations + 1):
            self._control_point(f"population_generation_{generation}")
            schedule = build_population_schedule(
                generation=generation,
                decks=self.config.decks,
                base_seed=self.config.seed,
                games_per_matchup=self.config.games_per_matchup,
                current_generation_games=self.config.current_generation_games,
                historical_games=self.config.historical_games,
            )
            closure = validate_schedule_closure(
                schedule, expected_decks=self.config.decks
            )
            current_payloads = {}
            for deck, model in self.models.items():
                state, config = _model_payload_for_worker(model)
                current_payloads[deck] = (
                    state,
                    config,
                    _model_payload_sha256(state, config),
                )
            requests = self._group_requests(schedule, current_payloads)
            self.events.emit(
                stage=f"population_generation_{generation}",
                completed=sum(
                    task.task_id in self.completed for task in schedule
                ),
                total=len(schedule),
                metrics={
                    **closure,
                    "history_generations": [
                        int(row["generation"])
                        for row in self.league_snapshots[-3:]
                    ],
                },
                message=f"第 {generation} 代人口赛程已闭合",
                event="generation_started",
            )
            task_by_id = {task.task_id: task for task in schedule}
            worker_count = max(1, int(self.config.rollout_workers))
            pool = (
                ProcessPoolExecutor(
                    max_workers=min(worker_count, len(requests)),
                    initializer=_worker_init,
                )
                if worker_count > 1 and len(requests) > 1
                else None
            )
            try:
                for start in range(0, len(requests), worker_count):
                    self._control_point(
                        f"population_generation_{generation}"
                    )
                    wave = requests[start:start + worker_count]
                    if pool is not None:
                        result_groups = list(
                            pool.map(_population_group_worker, wave)
                        )
                    else:
                        result_groups = [
                            _population_group_worker(payload)
                            for payload in wave
                        ]
                    for payload, results in zip(wave, result_groups):
                        tasks = [
                            task_by_id[str(row["task_id"])]
                            for row in payload["tasks"]
                        ]
                        self._train_population_group(
                            generation,
                            tasks,
                            results,
                        )
            finally:
                if pool is not None:
                    pool.shutdown(wait=True, cancel_futures=True)
            self._record_choice_generation_metrics(generation)
            self.counters["generation"] = generation
            snapshot = self._save_generation_snapshot(generation)
            # A generation boundary is also checkpointed even when every group
            # had already been committed before a restart.
            boundary_id = f"generation_{generation}_complete"
            if boundary_id not in self.completed:
                self._commit(
                    boundary_id,
                    stage=f"population_generation_{generation}",
                    new_task_ids=[boundary_id],
                    metrics={
                        "generation_complete": True,
                        "league_snapshot": snapshot,
                    },
                    completed=len(schedule),
                    total=len(schedule),
                )

    def _write_models(self) -> dict[str, dict[str, Any]]:
        result: dict[str, dict[str, Any]] = {}
        model_dir = self.run_dir / "models"
        for deck, model in self.models.items():
            path = model_dir / f"{deck}.pt"
            metadata = {
                "trainer": TRAINER_HYBRID_POPULATION,
                "trainer_version": HYBRID_POPULATION_TRAINER_VERSION,
                "run_id": self.run_id,
                "deck": deck,
                "generation": int(self.counters.get("generation", 0)),
                "accepted": False,
                "verified": False,
                "verification_status": "candidate_pending_godot_evidence",
                "choice_head_source": "teacher_dagger",
                "population_action_mix": dict(ACTION_MIX),
                "completed_task_count": len(self.completed),
                "model_variant": self.config.model_variant,
            }
            payload = checkpoint_payload(model, metadata)
            _atomic_torch_save(path, payload)
            sidecar = {
                "format_version": 1,
                "path": path.name,
                "sha256": sha256_file(path),
                "metadata": payload["metadata"],
                "schema": payload["schema"],
                "model_config": payload["model_config"],
            }
            atomic_write_json(model_dir / f"{deck}.json", sidecar)
            result[deck] = sidecar
        return result

    def run_training(self) -> dict[str, Any]:
        self._initialize()
        resumed = self._resume()
        update_run(
            self.run_dir,
            status="running",
            pid=os.getpid(),
            started_at=self.run.get("started_at") or utc_now(),
            resumable=True,
            environment=runtime_environment(),
            device=self.device,
            device_fallback_reason=self.device_fallback_reason,
        )
        self.events.emit(
            stage="initializing",
            metrics={
                "resumed": resumed,
                "preset": self.config.preset,
                "device": self.device,
                "device_fallback_reason": self.device_fallback_reason,
                "decks": list(self.config.decks),
            },
            message="hybrid_population_rl 已启动",
            event="run_started",
        )
        try:
            self._train_teacher()
            self._train_dagger()
            self._train_population()
            models = self._write_models()
            candidate_stage: dict[str, Any] = {}
            if self.config.preset == "release":
                update_run(
                    self.run_dir,
                    status="exporting_candidate",
                    progress={
                        "stage": "onnx_export",
                        "completed": 0,
                        "total": len(self.config.decks),
                    },
                )
                self.events.emit(
                    stage="onnx_export",
                    completed=0,
                    total=len(self.config.decks),
                    message="正在导出独立候选 ONNX 并验证普通/空槽输入 parity",
                    event="phase_started",
                )
                from scripts.prepare_hybrid_candidate import prepare_candidate

                candidate_stage = prepare_candidate(self.run_dir)
                self.events.emit(
                    stage="onnx_export",
                    completed=len(self.config.decks),
                    total=len(self.config.decks),
                    metrics={
                        "candidate_manifest_sha256": candidate_stage[
                            "candidate_manifest_sha256"
                        ],
                        "candidate_evidence_sha256": candidate_stage[
                            "candidate_evidence_sha256"
                        ],
                    },
                    message="候选 ONNX 与 parity 验证完成；正式模型仍未修改",
                    event="phase_finished",
                )
            summary = {
                "trainer": TRAINER_HYBRID_POPULATION,
                "trainer_version": HYBRID_POPULATION_TRAINER_VERSION,
                "run_id": self.run_id,
                "preset": self.config.preset,
                "completed_task_count": len(self.completed),
                "counters": self.counters,
                "models": models,
                "promotable": bool(self.config.promotable),
                "gate_status": "not_evaluated",
                "candidate_stage": candidate_stage,
            }
            atomic_write_json(
                self.run_dir / "evaluation" / "training_summary.json",
                summary,
            )
            final_metrics = dict(
                dict(
                    read_json(self.run_dir / "run.json").get(
                        "progress"
                    ) or {}
                ).get("metrics") or {}
            )
            update_run(
                self.run_dir,
                status="completed",
                pid=0,
                resumable=True,
                completed_at=utc_now(),
                candidate_models={
                    deck: {
                        "path": f"models/{deck}.pt",
                        "sha256": row["sha256"],
                    }
                    for deck, row in models.items()
                },
                gate={
                    "status": "not_evaluated",
                    "evidence_sha256": "",
                    "checks": {},
                },
                progress={
                    "stage": "completed",
                    "completed": len(self.completed),
                    "total": len(self.completed),
                    "metrics": {
                        **final_metrics,
                        "models": len(models),
                        "promotable": bool(self.config.promotable),
                    },
                },
            )
            self.events.emit(
                stage="completed",
                completed=len(self.completed),
                total=len(self.completed),
                metrics={
                    "models": len(models),
                    "promotable": bool(self.config.promotable),
                },
                message="训练完成；候选模型尚未通过 Godot 门禁，不能晋升",
                event="run_completed",
            )
            return summary
        except TrainingCancelled:
            update_run(
                self.run_dir,
                status="cancelled",
                pid=0,
                resumable=True,
                cancelled_at=utc_now(),
                progress={
                    "stage": "cancelled",
                    "completed": len(self.completed),
                    "total": len(self.completed),
                },
            )
            self.events.emit(
                stage="cancelled",
                completed=len(self.completed),
                total=len(self.completed),
                message="训练已取消；最后一个已提交批次仍可恢复",
                event="run_cancelled",
            )
            return {"run_id": self.run_id, "status": "cancelled"}
        except Exception as exc:
            update_run(
                self.run_dir,
                status="failed",
                pid=0,
                resumable=True,
                failed_at=utc_now(),
                error={"type": type(exc).__name__, "message": str(exc)},
                progress={
                    "stage": "failed",
                    "completed": len(self.completed),
                    "total": len(self.completed),
                    "metrics": {"error_type": type(exc).__name__},
                },
            )
            self.events.emit(
                stage="failed",
                completed=len(self.completed),
                total=len(self.completed),
                metrics={"error_type": type(exc).__name__},
                message=str(exc),
                event="error",
            )
            raise


def run_hybrid_population_training(
    repo_root: str | os.PathLike[str],
    run_dir: str | os.PathLike[str],
) -> dict[str, Any]:
    return HybridPopulationTrainer(repo_root, run_dir).run_training()

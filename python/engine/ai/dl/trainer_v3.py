"""Cycle-based native actor/learner orchestration for Deep AI v3."""
from __future__ import annotations

import copy
import contextlib
import hashlib
import json
import math
import os
import tempfile
import time
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any, Callable, Iterable

from .actor_v3 import ActorConfigV3, GameTaskV3, NativeActorServiceV3
from .learner_v3 import DeepLearnerV3, LearnerConfigV3
from .model_v3 import create_model
from .replay_v3 import ReplayStoreV3, SOURCE_SELF_PLAY, SOURCE_TEACHER
from .run_control_v3 import RunControlV3
from .run_store import TrainingEventWriter, read_json
from .v3_contract import (
    DEFAULT_CYCLE_SAMPLES,
    DEFAULT_REPLAY_BYTES,
    DEFAULT_REPLAY_CAPACITY,
    DEFAULT_REPLAY_SHARD_SAMPLES,
    DEFAULT_TEACHER_FRACTION,
    MODEL_VARIANT,
    RELEASE_DECKS,
    RUN_FORMAT_VERSION,
    TRAINER_ID,
)


TRAINING_STATE_SCHEMA = "ptcg_deep_training_state_v3"


def _atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


@dataclass(frozen=True, slots=True)
class AlphaZeroV3Config:
    output_dir: str
    preset: str = "release"
    teacher_replay: str = ""
    device: str = "cuda"
    seed: int = 17
    cycles: int = 20
    cycle_samples: int = DEFAULT_CYCLE_SAMPLES
    simulations: int = 128
    actor_threads: int = 16
    concurrent_games: int = 64
    inference_target_batch: int = 128
    inference_max_batch: int = 256
    inference_coalesce_ms: float = 2.0
    native_inflight_leaves: int = 8
    max_game_decisions: int = 512
    batch_size: int = 512
    warmup_epochs: int = 5
    teacher_warmup_learning_rate: float = 2e-3
    teacher_wdl_loss_weight: float = 0.25
    teacher_retention_search_steps: int = 10
    replay_passes: int = 2
    replay_capacity: int = DEFAULT_REPLAY_CAPACITY
    replay_bytes: int = DEFAULT_REPLAY_BYTES
    replay_shard_samples: int = DEFAULT_REPLAY_SHARD_SAMPLES
    teacher_fraction: float = DEFAULT_TEACHER_FRACTION
    learning_rate: float = 3e-4
    optimizer_warmup_steps: int = 2_000
    schedule_total_steps: int = 50_000
    arena_games_per_matchup: int = 4
    arena_matchup_limit: int = 55
    arena_max_decisions: int = 512
    promotion_score_rate: float = 0.55
    strict_actor_errors: bool = True
    minimum_teacher_improvement: float = 0.20
    maximum_teacher_regression: float = 0.10
    minimum_normalized_policy_entropy: float = 0.01

    @classmethod
    def smoke(cls, output_dir: str, **overrides: Any) -> "AlphaZeroV3Config":
        values = {
            "preset": "smoke",
            "device": "cpu",
            "cycles": 1,
            "cycle_samples": 64,
            "simulations": 2,
            "actor_threads": 2,
            "concurrent_games": 2,
            "inference_target_batch": 2,
            "inference_max_batch": 4,
            "native_inflight_leaves": 2,
            "batch_size": 8,
            "warmup_epochs": 1,
            "replay_passes": 1,
            "max_game_decisions": 512,
            "arena_games_per_matchup": 1,
            "arena_matchup_limit": 1,
            "arena_max_decisions": 64,
            "strict_actor_errors": True,
            "schedule_total_steps": 100,
            "optimizer_warmup_steps": 1,
        }
        values.update(overrides)
        return cls(output_dir, **values)

    @classmethod
    def pilot(cls, output_dir: str, **overrides: Any) -> "AlphaZeroV3Config":
        values = {
            "preset": "pilot",
            "cycles": 2,
            "cycle_samples": 25_000,
            "batch_size": 128,
            "optimizer_warmup_steps": 20,
            "arena_games_per_matchup": 4,
            "arena_matchup_limit": 55,
        }
        values.update(overrides)
        return cls(output_dir, **values)

    def validate(self) -> None:
        if self.preset not in {"smoke", "pilot", "release"}:
            raise ValueError("invalid_v3_training_preset")
        if self.cycles <= 0 or self.cycle_samples <= 0:
            raise ValueError("invalid_v3_training_cycles")
        if self.simulations <= 0 or self.native_inflight_leaves <= 0:
            raise ValueError("invalid_v3_training_search")
        if self.native_inflight_leaves > self.simulations:
            raise ValueError("v3_inflight_exceeds_simulations")
        if self.concurrent_games <= 0 or self.actor_threads <= 0:
            raise ValueError("invalid_v3_actor_concurrency")
        if self.arena_games_per_matchup <= 0 or self.arena_max_decisions <= 0:
            raise ValueError("invalid_v3_arena_games")
        if not 0.0 <= self.minimum_teacher_improvement < 1.0:
            raise ValueError("invalid_v3_teacher_improvement_gate")
        if self.maximum_teacher_regression < 0.0:
            raise ValueError("invalid_v3_teacher_regression_gate")
        if not 0.0 <= self.minimum_normalized_policy_entropy <= 1.0:
            raise ValueError("invalid_v3_entropy_gate")
        if (
            self.teacher_warmup_learning_rate <= 0
            or self.teacher_wdl_loss_weight < 0
            or self.teacher_retention_search_steps <= 0
        ):
            raise ValueError("invalid_v3_teacher_warmup_optimizer")


def _matchups() -> list[tuple[str, str]]:
    return [
        (left, right)
        for left_index, left in enumerate(RELEASE_DECKS)
        for right in RELEASE_DECKS[left_index:]
    ]


def cycle_tasks_v3(
    *,
    cycle: int,
    games: int,
    seed: int,
    max_decisions: int,
    ordinal_offset: int = 0,
) -> list[GameTaskV3]:
    matchups = _matchups()
    result = []
    for local in range(int(games)):
        ordinal = int(ordinal_offset) + local
        matchup_index = ordinal % len(matchups)
        closure = (ordinal // len(matchups)) % 4
        deck_a, deck_b = matchups[matchup_index]
        seat_a = closure & 1
        model_slots = [0, 0]
        model_versions = [cycle, cycle]
        if ordinal % 5 == 4:
            model_slots[1 - seat_a] = 1
            model_versions[1 - seat_a] = max(0, cycle - 1)
        result.append(
            GameTaskV3(
                f"cycle-{cycle:04d}-{ordinal:06d}",
                cycle,
                deck_a,
                deck_b,
                int(seed) + cycle * 10_000_000 + ordinal * 101,
                seat_a,
                (closure >> 1) & 1,
                tuple(model_slots),
                tuple(model_versions),
                int(max_decisions),
            )
        )
    return result


class AlphaZeroV3Trainer:
    def __init__(
        self,
        config: AlphaZeroV3Config,
        *,
        status_callback: Callable[[str], None] | None = None,
    ) -> None:
        config.validate()
        self.config = config
        self.output_dir = Path(config.output_dir).resolve()
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.events_path = self.output_dir / "events-v3.jsonl"
        self.state_path = self.output_dir / "training-state-v3.json"
        self.warmup_path = self.output_dir / "teacher-warmup-v3.json"
        self.pilot_path = self.output_dir / "pilot-evidence-v3.json"
        self.champion_root = self.output_dir / "champion-v3"
        self.control = RunControlV3(
            self.output_dir,
            status_callback=status_callback,
        )
        self.dashboard_events: TrainingEventWriter | None = None
        if (self.output_dir / "run.json").is_file():
            run_id = str(read_json(self.output_dir / "run.json").get("run_id", ""))
            self.dashboard_events = TrainingEventWriter(
                self.output_dir,
                run_id,
                schema="ptcg_deep_event_v3",
            )
        self.replay = ReplayStoreV3(
            self.output_dir / "replay-v3",
            capacity=config.replay_capacity,
            byte_capacity=config.replay_bytes,
            shard_samples=config.replay_shard_samples,
            seed=config.seed,
        )
        if config.teacher_replay:
            teacher_root = Path(config.teacher_replay).resolve()
            if not teacher_root.is_dir():
                raise FileNotFoundError(
                    "v3_teacher_replay_missing:" + str(teacher_root)
                )
            imported = self.replay.import_teacher(
                ReplayStoreV3(teacher_root)
            )
            if imported["samples"]:
                self._event("teacher_replay_imported", **imported)
        if config.preset in {"pilot", "release"} and not config.teacher_replay:
            raise ValueError("v3_pilot_requires_teacher_replay")
        learner_config = LearnerConfigV3(
            device=config.device,
            batch_size=config.batch_size,
            learning_rate=config.learning_rate,
            optimizer_warmup_steps=config.optimizer_warmup_steps,
            schedule_total_steps=config.schedule_total_steps,
            teacher_fraction=config.teacher_fraction,
            replay_passes=config.replay_passes,
            seed=config.seed,
        )
        self.learner = DeepLearnerV3(
            self.replay,
            self.output_dir / "checkpoints-v3",
            config=learner_config,
            control=self.control,
        )
        self.champion = None
        self.champion_version = 0
        self.previous_rows: list[dict[str, Any]] = []
        self.warmup_evidence: dict[str, Any] = {}

    def _event(self, event: str, **payload: Any) -> None:
        row = {
            "schema": "ptcg_deep_event_v3",
            "time": time.time(),
            "event": event,
            **payload,
        }
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        if self.dashboard_events is not None:
            self.dashboard_events.emit(
                stage=str(event),
                metrics=payload,
                message=str(event),
                event=str(event),
            )

    def _actor_config(self, *, training: bool) -> ActorConfigV3:
        return ActorConfigV3(
            concurrent_games=self.config.concurrent_games,
            search_slots=self.config.actor_threads,
            simulations=self.config.simulations,
            max_depth=128,
            max_inflight_leaves=self.config.native_inflight_leaves,
            inference_target_batch=self.config.inference_target_batch,
            inference_max_batch=self.config.inference_max_batch,
            inference_coalesce_ms=self.config.inference_coalesce_ms,
            training=training,
            strict=self.config.strict_actor_errors,
        )

    def _load_or_initialize(self) -> int:
        resumed = self.learner.latest_path.is_file()
        if resumed:
            latest_root = self.learner.load_latest()
            next_cycle = self.learner.cycle + 1
            if self.state_path.is_file():
                training_state = json.loads(
                    self.state_path.read_text(encoding="utf-8")
                )
                if (
                    training_state.get("schema") != TRAINING_STATE_SCHEMA
                    or int(training_state.get("run_format", 0))
                        != RUN_FORMAT_VERSION
                ):
                    raise ValueError("incompatible_v2_training_state")
                self.previous_rows = list(training_state.get("rows", ()))
            checkpoint_state = json.loads(
                (latest_root / "state.json").read_text(encoding="utf-8")
            )
            cycle_record = dict(checkpoint_state.get("cycle_record", {}))
            if self.learner.cycle > 0 and not cycle_record:
                raise ValueError("v3_checkpoint_cycle_record_missing")
            if cycle_record:
                completed_cycle = int(cycle_record.get("cycle", -1))
                if completed_cycle != self.learner.cycle:
                    raise ValueError("v3_checkpoint_cycle_record_mismatch")
                known_cycles = {
                    int(row.get("cycle", -1)) for row in self.previous_rows
                }
                if completed_cycle not in known_cycles:
                    self.previous_rows.append({
                        **cycle_record,
                        "checkpoint": str(latest_root),
                    })
                    self.previous_rows.sort(key=lambda row: int(row["cycle"]))
            if self.warmup_path.is_file():
                self.warmup_evidence = json.loads(
                    self.warmup_path.read_text(encoding="utf-8")
                )
            self._event(
                "run_resumed",
                next_cycle=next_cycle,
                global_step=self.learner.global_step,
            )
        else:
            teacher = [
                row for row in self.replay.entries(split="train")
                if row.source == SOURCE_TEACHER
            ]
            validation = [
                row for row in self.replay.entries(split="validation")
                if row.source == SOURCE_TEACHER
            ]
            if self.config.preset in {"pilot", "release"} and (
                not teacher or not validation
            ):
                raise ValueError(
                    "v3_pilot_teacher_train_validation_required"
                )
            if teacher:
                self.warmup_evidence = self._teacher_warmup(
                    teacher_samples=len(teacher),
                    validation_samples=len(validation),
                )
                _atomic_json(self.warmup_path, self.warmup_evidence)
            self.learner.save_checkpoint(role="learner")
            next_cycle = 1
        if (self.champion_root / "state.json").is_file():
            self.champion, self.champion_version = self._load_champion()
            if self.champion_version > self.learner.cycle:
                raise ValueError("v3_champion_ahead_of_learner")
        else:
            if resumed and self.learner.cycle > 0:
                raise ValueError("v3_champion_checkpoint_missing")
            self.champion = copy.deepcopy(self.learner.model).cpu().eval()
            self.champion_version = max(0, self.learner.cycle)
            self._save_champion()
        if self.previous_rows:
            latest_row = max(
                self.previous_rows,
                key=lambda row: int(row.get("cycle", -1)),
            )
            if (
                bool(latest_row.get("accepted"))
                and self.champion_version < int(latest_row["cycle"])
                and int(latest_row["cycle"]) == self.learner.cycle
            ):
                self.champion = copy.deepcopy(self.learner.model).cpu().eval()
                self.champion_version = self.learner.cycle
                self._save_champion()
        return next_cycle

    def _teacher_warmup(
        self,
        *,
        teacher_samples: int,
        validation_samples: int,
    ) -> dict[str, Any]:
        baseline = (
            self.learner.evaluate(
                split="validation",
                source=SOURCE_TEACHER,
            )
            if validation_samples
            else None
        )
        steps_per_epoch = max(
            1,
            math.ceil(teacher_samples / self.config.batch_size),
        )
        epochs = []
        best_state: dict[str, Any] | None = None
        best_epoch: int | None = None
        best_loss = math.inf
        for epoch in range(1, self.config.warmup_epochs + 1):
            metrics = self.learner.train_steps(
                steps_per_epoch,
                learning_rate_override=(
                    self.config.teacher_warmup_learning_rate
                ),
                wdl_loss_weight=self.config.teacher_wdl_loss_weight,
                teacher_fraction_override=1.0,
            )
            validation = (
                self.learner.evaluate(
                    split="validation",
                    source=SOURCE_TEACHER,
                )
                if validation_samples
                else None
            )
            row = {
                "epoch": epoch,
                "training": metrics,
                "validation": validation,
            }
            epochs.append(row)
            if (
                validation is not None
                and float(validation["total_loss"]) < best_loss
            ):
                best_loss = float(validation["total_loss"])
                best_epoch = epoch
                best_state = self.learner.capture_training_state()
            self._event("teacher_warmup_epoch_complete", **row)
        losses = [
            float(row["validation"]["total_loss"])
            for row in epochs
            if row["validation"] is not None
        ]
        best = min(losses) if losses else None
        if best_state is not None:
            self.learner.restore_training_state(best_state)
        improvement = (
            (float(baseline["total_loss"]) - best)
            / max(float(baseline["total_loss"]), 1e-12)
            if baseline is not None and best is not None
            else None
        )
        passed = (
            improvement is None
            or improvement >= self.config.minimum_teacher_improvement
        )
        evidence = {
            "schema": "ptcg_deep_teacher_warmup_v3",
            "epochs_requested": self.config.warmup_epochs,
            "epochs_completed": len(epochs),
            "teacher_train_samples": teacher_samples,
            "teacher_validation_samples": validation_samples,
            "baseline": baseline,
            "epochs": epochs,
            "best_validation_total_loss": best,
            "selected_epoch": best_epoch,
            "selected_global_step": self.learner.global_step,
            "selection": "restore_best_validation_epoch",
            "teacher_warmup_learning_rate": (
                self.config.teacher_warmup_learning_rate
            ),
            "teacher_wdl_loss_weight": self.config.teacher_wdl_loss_weight,
            "validation_improvement": improvement,
            "minimum_required_improvement": (
                self.config.minimum_teacher_improvement
            ),
            "passed": passed,
        }
        evidence.update(self._save_teacher_anchor())
        self._event("teacher_warmup_complete", **evidence)
        return evidence

    def _save_teacher_anchor(self) -> dict[str, Any]:
        from safetensors.torch import save_file

        name = "teacher-anchor-v3.safetensors"
        path = self.output_dir / name
        temporary = self.output_dir / (name + ".tmp")
        save_file(
            {
                key: value.detach().contiguous().cpu()
                for key, value in self.learner.model.state_dict().items()
            },
            str(temporary),
        )
        os.replace(temporary, path)
        return {
            "anchor_model": name,
            "anchor_model_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }

    def _load_teacher_anchor(self) -> dict[str, Any]:
        from safetensors.torch import load_file

        configured = str(self.warmup_evidence.get("anchor_model", ""))
        if configured:
            path = (self.output_dir / configured).resolve()
            if path.parent != self.output_dir or not path.is_file():
                raise ValueError("v3_teacher_anchor_path_invalid")
            expected = str(
                self.warmup_evidence.get("anchor_model_sha256", "")
            )
            if expected and hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError("v3_teacher_anchor_hash_mismatch")
        else:
            # Runs created before the explicit anchor artifact use the immutable
            # cycle-zero checkpoint selected at the end of warmup.
            candidates = sorted(
                (self.output_dir / "checkpoints-v3").glob(
                    "cycle-0000-step-*/model.safetensors"
                )
            )
            if len(candidates) != 1:
                raise ValueError("v3_teacher_anchor_checkpoint_ambiguous")
            path = candidates[0]
        anchor = load_file(str(path), device="cpu")
        current = self.learner.model.state_dict()
        if set(anchor) != set(current) or any(
            anchor[key].shape != current[key].shape for key in current
        ):
            raise ValueError("v3_teacher_anchor_model_mismatch")
        return anchor

    def _enforce_teacher_retention(self) -> dict[str, Any] | None:
        """Project a mixed-pass learner into the teacher-safe trust region.

        Validation only selects a point on the line between the immutable
        warmup anchor and the newly trained learner. Adam/scaler/RNG/global-step
        state is retained, and the champion is never used as a rollback source.
        """
        warmup_best = self.warmup_evidence.get("best_validation_total_loss")
        if warmup_best is None:
            return None
        threshold = float(warmup_best) * (
            1.0 + self.config.maximum_teacher_regression
        )
        initial = self.learner.evaluate(
            split="validation",
            source=SOURCE_TEACHER,
        )
        if float(initial["total_loss"]) <= threshold:
            evidence = {
                "schema": "ptcg_deep_teacher_retention_v3",
                "initial": initial,
                "evaluations": [],
                "threshold": threshold,
                "selected_learner_fraction": 1.0,
                "final": initial,
                "passed": True,
                "selection": "mixed_learner_already_inside_teacher_trust_region",
            }
            self._event("teacher_retention_complete", **evidence)
            return evidence
        import torch

        anchor = self._load_teacher_anchor()
        current = {
            key: value.detach().contiguous().cpu().clone()
            for key, value in self.learner.model.state_dict().items()
        }

        def select(fraction: float) -> None:
            selected = {}
            for key, anchor_value in anchor.items():
                current_value = current[key]
                if torch.is_floating_point(anchor_value):
                    selected[key] = anchor_value.lerp(
                        current_value.to(anchor_value.dtype),
                        float(fraction),
                    )
                else:
                    selected[key] = current_value if fraction >= 0.5 else anchor_value
            self.learner.model.load_state_dict(selected, strict=True)
            self.learner.model.eval()

        evaluations: list[dict[str, Any]] = []
        select(0.0)
        anchor_validation = self.learner.evaluate(
            split="validation",
            source=SOURCE_TEACHER,
        )
        evaluations.append({
            "learner_fraction": 0.0,
            "validation": anchor_validation,
        })
        if float(anchor_validation["total_loss"]) > threshold:
            select(1.0)
            raise RuntimeError("v3_teacher_anchor_outside_retention_threshold")
        lower = 0.0
        upper = 1.0
        best_validation = anchor_validation
        for _index in range(self.config.teacher_retention_search_steps):
            fraction = (lower + upper) * 0.5
            select(fraction)
            validation = self.learner.evaluate(
                split="validation",
                source=SOURCE_TEACHER,
            )
            evaluations.append({
                "learner_fraction": fraction,
                "validation": validation,
            })
            if float(validation["total_loss"]) <= threshold:
                lower = fraction
                best_validation = validation
            else:
                upper = fraction
        select(lower)
        final = self.learner.evaluate(
            split="validation",
            source=SOURCE_TEACHER,
        )
        evidence = {
            "schema": "ptcg_deep_teacher_retention_v3",
            "initial": initial,
            "anchor": anchor_validation,
            "evaluations": evaluations,
            "threshold": threshold,
            "selected_learner_fraction": lower,
            "final": final,
            "passed": float(final["total_loss"]) <= threshold,
            "selection": "maximum_validation_safe_mixed_learner_fraction",
        }
        self._event("teacher_retention_complete", **evidence)
        return evidence

    def _save_champion(self) -> None:
        from safetensors.torch import save_file

        assert self.champion is not None
        self.champion_root.mkdir(parents=True, exist_ok=True)
        model_name = (
            f"model-v{self.champion_version:04d}-{time.time_ns()}.safetensors"
        )
        model_path = self.champion_root / model_name
        temporary = self.champion_root / (model_name + ".tmp")
        save_file(
            {
                key: value.detach().contiguous().cpu()
                for key, value in self.champion.state_dict().items()
            },
            str(temporary),
        )
        os.replace(temporary, model_path)
        _atomic_json(
            self.champion_root / "state.json",
            {
                "schema": "ptcg_deep_champion_v3",
                "model_variant": MODEL_VARIANT,
                "champion_version": self.champion_version,
                "model_file": model_name,
                "model_config": self.champion.config_dict(),
                "model_sha256": hashlib.sha256(model_path.read_bytes()).hexdigest(),
            },
        )

    def _load_champion(self) -> tuple[Any, int]:
        from safetensors.torch import load_file

        state = json.loads(
            (self.champion_root / "state.json").read_text(encoding="utf-8")
        )
        if (
            state.get("schema") != "ptcg_deep_champion_v3"
            or state.get("model_variant") != MODEL_VARIANT
        ):
            raise ValueError("incompatible_v2_champion_use_v3_fresh_run")
        model_name = str(state.get("model_file", "model.safetensors"))
        model_path = (self.champion_root / model_name).resolve()
        if model_path.parent != self.champion_root or not model_path.is_file():
            raise ValueError("v3_champion_model_path_invalid")
        if hashlib.sha256(model_path.read_bytes()).hexdigest() != state.get(
            "model_sha256"
        ):
            raise ValueError("v3_champion_hash_mismatch")
        model = create_model(**dict(state.get("model_config", {})))
        model.load_state_dict(load_file(str(model_path), device="cpu"), strict=True)
        return model.cpu().eval(), int(state.get("champion_version", 0))

    def _learning_gate(
        self,
        train_metrics: dict[str, Any],
        teacher_validation: dict[str, Any] | None,
    ) -> dict[str, Any]:
        warmup_best = self.warmup_evidence.get(
            "best_validation_total_loss"
        )
        teacher_regression = (
            (
                float(teacher_validation["total_loss"])
                - float(warmup_best)
            )
            / max(float(warmup_best), 1e-12)
            if teacher_validation is not None and warmup_best is not None
            else None
        )
        gate = {
            "teacher_regression": teacher_regression,
            "maximum_teacher_regression": (
                self.config.maximum_teacher_regression
            ),
            "teacher_loss_passed": (
                teacher_regression is None
                or teacher_regression <= self.config.maximum_teacher_regression
            ),
            "normalized_policy_entropy": float(
                train_metrics["normalized_policy_entropy"]
            ),
            "minimum_normalized_policy_entropy": (
                self.config.minimum_normalized_policy_entropy
            ),
            "entropy_passed": float(
                train_metrics["normalized_policy_entropy"]
            ) >= self.config.minimum_normalized_policy_entropy,
        }
        gate["passed"] = bool(
            gate["teacher_loss_passed"] and gate["entropy_passed"]
        )
        return gate

    def _repair_resumed_teacher_gate(self) -> None:
        """Finish a retention guardrail interrupted between cycle boundaries."""
        if not self.previous_rows:
            return
        latest_index = max(
            range(len(self.previous_rows)),
            key=lambda index: int(self.previous_rows[index].get("cycle", -1)),
        )
        previous = dict(self.previous_rows[latest_index])
        gate = dict(previous.get("learning_gate", {}))
        if (
            int(previous.get("cycle", -1)) != self.learner.cycle
            or bool(gate.get("teacher_loss_passed", True))
        ):
            return
        retention = self._enforce_teacher_retention()
        if retention is None:
            return
        teacher_validation = dict(retention["final"])
        training = dict(previous.get("training", {}))
        training["teacher_retention"] = retention
        learning_gate = self._learning_gate(training, teacher_validation)
        arena = dict(previous.get("arena", {}))
        accepted = bool(
            int(arena.get("failed_games", 1)) == 0
            and float(arena.get("score_rate", 0.0))
                >= self.config.promotion_score_rate
            and learning_gate["passed"]
        )
        cycle_record = {
            **previous,
            "training": training,
            "teacher_validation": teacher_validation,
            "learning_gate": learning_gate,
            "accepted": accepted,
        }
        cycle_record.pop("checkpoint", None)
        checkpoint = self.learner.save_checkpoint(
            role="learner",
            cycle_record=cycle_record,
            allow_revision=True,
        )
        repaired = {**cycle_record, "checkpoint": str(checkpoint)}
        self.previous_rows[latest_index] = repaired
        _atomic_json(
            self.state_path,
            {
                "schema": TRAINING_STATE_SCHEMA,
                "run_format": RUN_FORMAT_VERSION,
                "next_cycle": self.learner.cycle + 1,
                "global_step": self.learner.global_step,
                "champion_version": self.champion_version,
                "warmup": self.warmup_evidence,
                "rows": self.previous_rows,
            },
        )
        self._event(
            "cycle_teacher_gate_repaired",
            cycle=self.learner.cycle,
            checkpoint=str(checkpoint),
            teacher_retention=retention,
            learning_gate=learning_gate,
        )

    def run(self) -> dict[str, Any]:
        self.control.status("running")
        next_cycle = self._load_or_initialize()
        self._repair_resumed_teacher_gate()
        rows: list[dict[str, Any]] = list(self.previous_rows)
        self._event("run_started", config=asdict(self.config), next_cycle=next_cycle)
        for cycle in range(next_cycle, self.config.cycles + 1):
            self.control.checkpoint()
            generated = self._generate_cycle(cycle)
            train_metrics = self.learner.train_cycle(generated["written_samples"])
            teacher_retention = self._enforce_teacher_retention()
            teacher_validation = (
                dict(teacher_retention["final"])
                if teacher_retention is not None
                else None
            )
            if teacher_retention is not None:
                train_metrics["teacher_retention"] = teacher_retention
            arena = self._arena(cycle)
            learning_gate = self._learning_gate(
                train_metrics,
                teacher_validation,
            )
            accepted = (
                arena["failed_games"] == 0
                and arena["score_rate"] >= self.config.promotion_score_rate
                and bool(learning_gate["passed"])
            )
            cycle_record = {
                "cycle": cycle,
                "generated": generated,
                "training": train_metrics,
                "teacher_validation": teacher_validation,
                "learning_gate": learning_gate,
                "arena": arena,
                "accepted": accepted,
            }
            checkpoint = self.learner.save_checkpoint(
                role="learner",
                cycle_record=cycle_record,
            )
            if accepted:
                self.champion = copy.deepcopy(self.learner.model).cpu().eval()
                self.champion_version = cycle
                self._save_champion()
            row = {**cycle_record, "checkpoint": str(checkpoint)}
            rows.append(row)
            _atomic_json(
                self.state_path,
                {
                    "schema": TRAINING_STATE_SCHEMA,
                    "run_format": RUN_FORMAT_VERSION,
                    "next_cycle": cycle + 1,
                    "global_step": self.learner.global_step,
                    "champion_version": self.champion_version,
                    "warmup": self.warmup_evidence,
                    "rows": rows,
                },
            )
            self._event("cycle_complete", **row)
        pilot_required = self.config.preset in {"pilot", "release"}
        pilot_passed = bool(
            len(rows) >= self.config.cycles
            and (
                not pilot_required
                or self.warmup_evidence.get("passed") is True
            )
            and all(
                bool(row.get("learning_gate", {}).get("passed"))
                and int(
                    row.get("arena", {}).get("structural_errors", 1)
                ) == 0
                for row in rows
            )
        )
        pilot_evidence = {
            "schema": "ptcg_deep_pilot_evidence_v3",
            "preset": self.config.preset,
            "warmup": self.warmup_evidence,
            "cycles_completed": len(rows),
            "cycles_required": self.config.cycles,
            "cycle_gates": [
                {
                    "cycle": row.get("cycle"),
                    "learning_gate": row.get("learning_gate"),
                    "arena_structural_errors": row.get("arena", {}).get(
                        "structural_errors"
                    ),
                    "arena_truncated_games": row.get("arena", {}).get(
                        "truncated_games"
                    ),
                }
                for row in rows
            ],
            "passed": pilot_passed,
        }
        _atomic_json(self.pilot_path, pilot_evidence)
        summary = {
            "trainer": TRAINER_ID,
            "model_variant": MODEL_VARIANT,
            "cycles": rows,
            "replay": self.replay.verify(),
            "global_step": self.learner.global_step,
            "champion_version": self.champion_version,
            "pilot_evidence": pilot_evidence,
            "pilot_passed": pilot_passed,
            "deep_runtime_enabled": False,
        }
        _atomic_json(self.output_dir / "summary-v3.json", summary)
        self._event("run_complete", **summary)
        self.control.status("completed" if pilot_passed else "failed")
        return summary

    def _generate_cycle(self, cycle: int) -> dict[str, Any]:
        assert self.champion is not None
        progress = self.replay.cycle_progress(
            cycle,
            source=SOURCE_SELF_PLAY,
        )
        accumulated = int(progress["samples"])
        base_seed = self.config.seed + cycle * 10_000_000
        ordinals = [
            (int(seed) - base_seed) // 101
            for seed in progress["game_seeds"]
            if int(seed) >= base_seed
            and (int(seed) - base_seed) % 101 == 0
        ]
        game_offset = max(ordinals, default=-1) + 1
        existing_samples = accumulated
        runs = []
        consecutive_empty_runs = 0
        cycle_train_samples = sum(
            1
            for row in self.replay.entries(split="train")
            if row.source == SOURCE_SELF_PLAY and row.cycle == cycle
        )
        while (
            accumulated < self.config.cycle_samples
            or cycle_train_samples <= 0
        ):
            remaining = self.config.cycle_samples - accumulated
            games = max(1, math.ceil(max(1, remaining) / 150))
            tasks = cycle_tasks_v3(
                cycle=cycle,
                games=games,
                seed=self.config.seed,
                max_decisions=self.config.max_game_decisions,
                ordinal_offset=game_offset,
            )
            game_offset += games
            with NativeActorServiceV3(
                {0: self.learner.model, 1: self.champion},
                device=self.config.device,
                config=self._actor_config(training=True),
                control=self.control,
            ) as actors:
                run = actors.run(tasks, replay=self.replay)
            accumulated += int(run["written_samples"])
            if accumulated >= self.config.cycle_samples:
                cycle_train_samples = sum(
                    1
                    for row in self.replay.entries(split="train")
                    if row.source == SOURCE_SELF_PLAY and row.cycle == cycle
                )
            runs.append({
                "game_count": run["game_count"],
                "failed_games": run["failed_games"],
                "structural_errors": run["structural_errors"],
                "failure_records": run["failure_records"],
                "written_samples": run["written_samples"],
                "native": run["native"],
                "inference": run["inference"],
            })
            if int(run["written_samples"]) <= 0:
                consecutive_empty_runs += 1
                if consecutive_empty_runs >= 3:
                    raise RuntimeError("v3_actor_cycle_produced_no_samples")
            else:
                consecutive_empty_runs = 0
        result = {
            "written_samples": accumulated,
            "existing_samples": existing_samples,
            "new_samples": accumulated - existing_samples,
            "train_samples": cycle_train_samples,
            "games": game_offset,
            "runs": runs,
        }
        self._event("self_play_complete", cycle=cycle, **result)
        return result

    def _arena(self, cycle: int) -> dict[str, Any]:
        assert self.champion is not None
        decision_cap = (
            min(64, self.config.arena_max_decisions)
            if self.config.preset == "pilot"
            else self.config.arena_max_decisions
        )
        tasks = []
        matchups = _matchups()[: self.config.arena_matchup_limit]
        for matchup_index, (deck_a, deck_b) in enumerate(matchups):
            for game_index in range(self.config.arena_games_per_matchup):
                closure = game_index % 4
                seat_a = closure & 1
                slots = [1, 1]
                slots[seat_a] = 0
                tasks.append(
                    GameTaskV3(
                        f"arena-{cycle:04d}-{matchup_index:02d}-{game_index:03d}",
                        cycle,
                        deck_a,
                        deck_b,
                        self.config.seed + 500_000_000 + cycle * 100_000
                        + matchup_index * 1_000 + game_index,
                        seat_a,
                        (closure >> 1) & 1,
                        tuple(slots),
                        (cycle, self.champion_version),
                        decision_cap,
                    )
                )
        arena_config = replace(
            self._actor_config(training=False),
            strict=False,
        )
        with NativeActorServiceV3(
            {0: self.learner.model, 1: self.champion},
            device=self.config.device,
            config=arena_config,
            control=self.control,
        ) as actors:
            result = actors.run(tasks)
        wins = 0
        draws = 0
        task_by_id = {task.game_id: task for task in tasks}
        for game in result["games"]:
            task = task_by_id[str(game["game_id"])]
            winner = int(game["winner"])
            if winner < 0:
                draws += 1
            elif winner == task.seat_a:
                wins += 1
        structural_errors = sum(
            1
            for game in result["games"]
            if str(game.get("error", ""))
                not in {"", "v3_actor_decision_cap"}
        )
        truncated_games = sum(
            1
            for game in result["games"]
            if str(game.get("error", "")) == "v3_actor_decision_cap"
        )
        games = len(tasks)
        return {
            "games": games,
            "decision_cap": decision_cap,
            "wins": wins,
            "draws": draws,
            "score_rate": (wins + 0.5 * draws) / max(1, games),
            "failed_games": int(result["failed_games"]),
            "structural_errors": structural_errors,
            "truncated_games": truncated_games,
            "native": result["native"],
            "inference": result["inference"],
        }

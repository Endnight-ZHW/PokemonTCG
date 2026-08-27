"""Persistent learner/checkpoint loop for Deep AI v3."""
from __future__ import annotations

import base64
import copy
import concurrent.futures
import contextlib
import hashlib
import json
import math
import os
import random
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator

import numpy as np

from .model_v3 import checkpoint_metadata, create_model
from .replay_v3 import ReplayEntryV3, ReplayStoreV3
from .run_control_v3 import RunControlV3
from .v3_contract import (
    CHECKPOINT_VERSION,
    DEFAULT_REPLAY_PASSES,
    DEFAULT_TEACHER_FRACTION,
    ENCODER_SCHEMA_VERSION,
    MODEL_VARIANT,
    RUN_FORMAT_VERSION,
)


CHECKPOINT_SCHEMA = "ptcg_deep_learner_v3"


@dataclass(frozen=True, slots=True)
class LearnerConfigV3:
    device: str = "cuda"
    batch_size: int = 512
    learning_rate: float = 3e-4
    weight_decay: float = 1e-4
    gradient_clip: float = 1.0
    optimizer_warmup_steps: int = 2_000
    schedule_total_steps: int = 50_000
    teacher_fraction: float = DEFAULT_TEACHER_FRACTION
    replay_passes: int = DEFAULT_REPLAY_PASSES
    prefetch_batches: int = 2
    amp_dtype: str = "bfloat16"
    seed: int = 17

    def validate(self) -> None:
        if self.batch_size <= 0 or self.learning_rate <= 0:
            raise ValueError("invalid_v3_learner_batch_or_rate")
        if self.gradient_clip <= 0 or self.schedule_total_steps <= 0:
            raise ValueError("invalid_v3_learner_schedule")
        if not 0.0 <= self.teacher_fraction <= 1.0:
            raise ValueError("invalid_v3_teacher_fraction")
        if self.prefetch_batches not in (1, 2):
            raise ValueError("v3_prefetch_batches_must_be_one_or_two")
        if self.amp_dtype not in {"bfloat16", "float16", "float32"}:
            raise ValueError("invalid_v3_amp_dtype")


def learning_rate_multiplier(
    global_step: int,
    warmup_steps: int,
    total_steps: int,
) -> float:
    step = max(0, int(global_step))
    warmup = max(0, int(warmup_steps))
    horizon = max(warmup + 1, int(total_steps))
    if warmup and step < warmup:
        return (step + 1) / warmup
    progress = (step - warmup) / max(1, horizon - warmup - 1)
    progress = min(1.0, max(0.0, progress))
    return 0.5 * (1.0 + math.cos(math.pi * progress))


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def _atomic_torch_save(path: Path, payload: Any) -> None:
    import torch

    fd, temporary = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )
    os.close(fd)
    try:
        torch.save(payload, temporary)
        with open(temporary, "rb+") as handle:
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def _bytes(value: Any) -> str:
    return base64.b64encode(bytes(value.tolist())).decode("ascii")


def _rng_state() -> dict[str, Any]:
    import torch

    numpy = np.random.get_state()
    return {
        "python": _jsonify(random.getstate()),
        "numpy": {
            "algorithm": str(numpy[0]),
            "keys": numpy[1].astype(np.uint32).tolist(),
            "position": int(numpy[2]),
            "has_gauss": int(numpy[3]),
            "cached_gaussian": float(numpy[4]),
        },
        "torch_cpu": _bytes(torch.get_rng_state()),
        "torch_cuda": (
            [_bytes(value) for value in torch.cuda.get_rng_state_all()]
            if torch.cuda.is_available()
            else []
        ),
    }


def _restore_rng_state(payload: dict[str, Any]) -> None:
    import torch

    random.setstate(_tupleify(payload["python"]))
    numpy = payload["numpy"]
    np.random.set_state(
        (
            str(numpy["algorithm"]),
            np.asarray(numpy["keys"], dtype=np.uint32),
            int(numpy["position"]),
            int(numpy["has_gauss"]),
            float(numpy["cached_gaussian"]),
        )
    )
    torch.set_rng_state(
        torch.tensor(
            list(base64.b64decode(payload["torch_cpu"])),
            dtype=torch.uint8,
        )
    )
    cuda = list(payload.get("torch_cuda", ()))
    if cuda and torch.cuda.is_available():
        torch.cuda.set_rng_state_all(
            [
                torch.tensor(list(base64.b64decode(value)), dtype=torch.uint8)
                for value in cuda
            ]
        )


def _jsonify(value: Any) -> Any:
    if isinstance(value, tuple):
        return {"__tuple__": [_jsonify(item) for item in value]}
    if isinstance(value, list):
        return [_jsonify(item) for item in value]
    return value


def _tupleify(value: Any) -> Any:
    if isinstance(value, dict) and set(value) == {"__tuple__"}:
        return tuple(_tupleify(item) for item in value["__tuple__"])
    if isinstance(value, list):
        return [_tupleify(item) for item in value]
    return value


class DeepLearnerV3:
    def __init__(
        self,
        replay: ReplayStoreV3,
        checkpoint_root: str | Path,
        *,
        config: LearnerConfigV3 | None = None,
        model: Any | None = None,
        control: RunControlV3 | None = None,
    ) -> None:
        import torch

        self.replay = replay
        self.checkpoint_root = Path(checkpoint_root).resolve()
        self.checkpoint_root.mkdir(parents=True, exist_ok=True)
        self.latest_path = self.checkpoint_root / "latest.json"
        self.config = config or LearnerConfigV3()
        self.config.validate()
        if self.config.device.startswith("cuda") and not torch.cuda.is_available():
            raise RuntimeError("v3_cuda_device_required_but_unavailable")
        random.seed(self.config.seed)
        np.random.seed(self.config.seed)
        torch.manual_seed(self.config.seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(self.config.seed)
        self.model = (model or create_model()).to(self.config.device)
        self.optimizer = torch.optim.AdamW(
            self.model.parameters(),
            lr=self.config.learning_rate,
            weight_decay=self.config.weight_decay,
        )
        self.amp_enabled = (
            self.config.device.startswith("cuda")
            and self.config.amp_dtype != "float32"
        )
        if (
            self.amp_enabled
            and self.config.amp_dtype == "bfloat16"
            and not torch.cuda.is_bf16_supported()
        ):
            raise RuntimeError("v3_bfloat16_device_unsupported")
        self.autocast_dtype = (
            torch.bfloat16
            if self.config.amp_dtype == "bfloat16"
            else torch.float16
        )
        self.scaler = torch.amp.GradScaler(
            "cuda",
            enabled=(
                self.config.device.startswith("cuda")
                and self.config.amp_dtype == "float16"
            ),
        )
        self.global_step = 0
        self.cycle = 0
        self.control = control

    @staticmethod
    def _model_inputs(batch: dict[str, Any]) -> tuple[Any, ...]:
        return tuple(
            batch[name]
            for name in (
                "state_global",
                "entity_numeric",
                "entity_card_ids",
                "entity_type_ids",
                "entity_mask",
                "candidate_numeric",
                "candidate_card_ids",
                "candidate_type_ids",
                "candidate_refs",
                "candidate_mask",
                "actor_deck_id",
                "opponent_deck_id",
            )
        )

    def train_cycle(self, new_samples: int) -> dict[str, float]:
        steps = max(
            1,
            math.ceil(max(1, int(new_samples)) / self.config.batch_size)
            * self.config.replay_passes,
        )
        metrics = self.train_steps(steps)
        self.cycle += 1
        metrics["cycle"] = float(self.cycle)
        metrics["new_samples"] = float(new_samples)
        return metrics

    def train_steps(
        self,
        steps: int,
        *,
        learning_rate_override: float | None = None,
        wdl_loss_weight: float = 1.0,
        teacher_fraction_override: float | None = None,
    ) -> dict[str, float]:
        import torch
        import torch.nn.functional as functional

        requested = max(1, int(steps))
        if learning_rate_override is not None and learning_rate_override <= 0:
            raise ValueError("invalid_v3_learning_rate_override")
        if wdl_loss_weight < 0:
            raise ValueError("invalid_v3_wdl_loss_weight")
        if teacher_fraction_override is not None and not (
            0.0 <= teacher_fraction_override <= 1.0
        ):
            raise ValueError("invalid_v3_teacher_fraction_override")
        teacher_fraction = (
            self.config.teacher_fraction
            if teacher_fraction_override is None
            else float(teacher_fraction_override)
        )
        entries = [
            self.replay.sample_entries(
                self.config.batch_size,
                teacher_fraction=teacher_fraction,
            )
            for _ in range(requested)
        ]
        self.model.train()
        policy_total = 0.0
        value_total = 0.0
        entropy_total = 0.0
        normalized_entropy_total = 0.0
        grad_total = 0.0
        data_wait = 0.0
        data_load = 0.0
        started = time.perf_counter()
        iterator = self._prefetched_batches(entries)
        for batch, wait_seconds, load_seconds in iterator:
            data_wait += wait_seconds
            data_load += load_seconds
            if self.control is not None:
                self.control.checkpoint()
            multiplier = learning_rate_multiplier(
                self.global_step,
                self.config.optimizer_warmup_steps,
                self.config.schedule_total_steps,
            )
            learning_rate = (
                float(learning_rate_override)
                if learning_rate_override is not None
                else self.config.learning_rate * multiplier
            )
            for group in self.optimizer.param_groups:
                group["lr"] = learning_rate
            self.optimizer.zero_grad(set_to_none=True)
            with torch.autocast(
                device_type="cuda" if self.config.device.startswith("cuda") else "cpu",
                dtype=self.autocast_dtype,
                enabled=self.amp_enabled,
            ):
                policy_logits, wdl_logits = self.model(*self._model_inputs(batch))
                log_policy = functional.log_softmax(policy_logits.float(), dim=-1)
                policy_loss = -(batch["policy_target"] * log_policy).sum(dim=-1).mean()
                value_loss = -(
                    batch["wdl_target"]
                    * functional.log_softmax(wdl_logits.float(), dim=-1)
                ).sum(dim=-1).mean()
                loss = policy_loss + float(wdl_loss_weight) * value_loss
            if not torch.isfinite(loss):
                raise RuntimeError("v3_non_finite_loss")
            scale_before = float(self.scaler.get_scale())
            self.scaler.scale(loss).backward()
            self.scaler.unscale_(self.optimizer)
            grad_norm = torch.nn.utils.clip_grad_norm_(
                self.model.parameters(),
                self.config.gradient_clip,
            )
            if not torch.isfinite(grad_norm):
                raise RuntimeError("v3_non_finite_gradient")
            self.scaler.step(self.optimizer)
            self.scaler.update()
            if float(self.scaler.get_scale()) < scale_before:
                raise RuntimeError("v3_gradient_overflow")
            probabilities = torch.softmax(policy_logits.float(), dim=-1)
            entropy = -(
                probabilities * torch.log(probabilities.clamp_min(1e-9))
            ).sum(dim=-1).mean()
            candidate_counts = batch["candidate_mask"].sum(dim=-1)
            variable = candidate_counts > 1
            normalized_entropy = (
                (
                    -(
                        probabilities
                        * torch.log(probabilities.clamp_min(1e-9))
                    ).sum(dim=-1)[variable]
                    / torch.log(candidate_counts[variable].float())
                ).mean()
                if bool(variable.any())
                else torch.ones((), device=policy_logits.device)
            )
            policy_total += float(policy_loss.detach().cpu())
            value_total += float(value_loss.detach().cpu())
            entropy_total += float(entropy.detach().cpu())
            normalized_entropy_total += float(
                normalized_entropy.detach().cpu()
            )
            grad_total += float(grad_norm.detach().cpu())
            self.global_step += 1
        elapsed = time.perf_counter() - started
        self.model.eval()
        consumed_samples = requested * self.config.batch_size
        parallel_loaders = min(self.config.prefetch_batches, requested)
        loader_seconds = data_load / parallel_loaders
        loader_rate = consumed_samples / max(loader_seconds, 1e-9)
        learner_rate = consumed_samples / max(elapsed, 1e-9)
        return {
            "steps": float(requested),
            "global_step": float(self.global_step),
            "policy_loss": policy_total / requested,
            "wdl_loss": value_total / requested,
            "policy_entropy": entropy_total / requested,
            "normalized_policy_entropy": (
                normalized_entropy_total / requested
            ),
            "gradient_norm": grad_total / requested,
            "elapsed_seconds": elapsed,
            "data_wait_seconds": data_wait,
            "data_wait_fraction": data_wait / max(elapsed, 1e-9),
            "data_load_worker_seconds": data_load,
            "effective_loader_seconds": loader_seconds,
            "loader_samples_per_second": loader_rate,
            "learner_samples_per_second": learner_rate,
            "loader_to_learner_ratio": loader_rate / max(learner_rate, 1e-9),
            "learning_rate": float(self.optimizer.param_groups[0]["lr"]),
            "wdl_loss_weight": float(wdl_loss_weight),
            "teacher_fraction": teacher_fraction,
        }

    def capture_training_state(self) -> dict[str, Any]:
        """Capture the exact mutable learner state for validation selection."""
        return {
            "model": {
                key: value.detach().contiguous().cpu().clone()
                for key, value in self.model.state_dict().items()
            },
            "optimizer": copy.deepcopy(self.optimizer.state_dict()),
            "scaler": copy.deepcopy(self.scaler.state_dict()),
            "global_step": self.global_step,
            "cycle": self.cycle,
            "rng": _rng_state(),
            "replay_rng": _jsonify(self.replay.random.getstate()),
        }

    def restore_training_state(self, state: dict[str, Any]) -> None:
        self.model.load_state_dict(dict(state["model"]), strict=True)
        self.optimizer.load_state_dict(copy.deepcopy(state["optimizer"]))
        self.scaler.load_state_dict(copy.deepcopy(state["scaler"]))
        self.global_step = int(state["global_step"])
        self.cycle = int(state["cycle"])
        _restore_rng_state(dict(state["rng"]))
        self.replay.random.setstate(_tupleify(state["replay_rng"]))
        self.model.eval()

    def evaluate(
        self,
        *,
        split: str = "validation",
        source: int | None = None,
        batch_size: int | None = None,
    ) -> dict[str, float]:
        """Evaluate a deterministic replay slice without consuming replay RNG."""
        import torch
        import torch.nn.functional as functional

        entries = self.replay.entries(split=split)
        if source is not None:
            entries = [row for row in entries if row.source == int(source)]
        if not entries:
            raise ValueError(f"v3_evaluation_split_empty:{split}:{source}")
        width = max(1, int(batch_size or self.config.batch_size))
        policy_total = 0.0
        value_total = 0.0
        entropy_total = 0.0
        normalized_total = 0.0
        sample_total = 0
        batches = 0
        was_training = self.model.training
        self.model.eval()
        with torch.no_grad():
            for start in range(0, len(entries), width):
                batch = self.replay.collate(
                    entries[start : start + width],
                    device=self.config.device,
                )
                policy_logits, wdl_logits = self.model(
                    *self._model_inputs(batch)
                )
                log_policy = functional.log_softmax(
                    policy_logits.float(), dim=-1
                )
                policy_rows = -(
                    batch["policy_target"] * log_policy
                ).sum(dim=-1)
                value_rows = -(
                    batch["wdl_target"]
                    * functional.log_softmax(wdl_logits.float(), dim=-1)
                ).sum(dim=-1)
                probabilities = torch.softmax(policy_logits.float(), dim=-1)
                entropy_rows = -(
                    probabilities
                    * torch.log(probabilities.clamp_min(1e-9))
                ).sum(dim=-1)
                candidate_counts = batch["candidate_mask"].sum(dim=-1)
                variable = candidate_counts > 1
                normalized_rows = torch.ones_like(entropy_rows)
                normalized_rows[variable] = (
                    entropy_rows[variable]
                    / torch.log(candidate_counts[variable].float())
                )
                if not all(
                    bool(torch.isfinite(value).all())
                    for value in (
                        policy_rows,
                        value_rows,
                        entropy_rows,
                        normalized_rows,
                    )
                ):
                    raise RuntimeError("v3_non_finite_validation_metric")
                count = int(policy_rows.shape[0])
                policy_total += float(policy_rows.sum().cpu())
                value_total += float(value_rows.sum().cpu())
                entropy_total += float(entropy_rows.sum().cpu())
                normalized_total += float(normalized_rows.sum().cpu())
                sample_total += count
                batches += 1
        if was_training:
            self.model.train()
        policy = policy_total / sample_total
        value = value_total / sample_total
        return {
            "samples": float(sample_total),
            "batches": float(batches),
            "policy_loss": policy,
            "wdl_loss": value,
            "total_loss": policy + value,
            "policy_entropy": entropy_total / sample_total,
            "normalized_policy_entropy": normalized_total / sample_total,
        }

    def _prefetched_batches(
        self,
        rows: Iterable[list[ReplayEntryV3]],
    ) -> Iterator[tuple[dict[str, Any], float, float]]:
        queue: list[
            tuple[
                concurrent.futures.Future[tuple[dict[str, Any], float]],
                float,
            ]
        ] = []

        def load(entries: list[ReplayEntryV3]) -> tuple[dict[str, Any], float]:
            started = time.perf_counter()
            batch = self.replay.collate(
                entries,
                device=self.config.device,
            )
            return batch, time.perf_counter() - started

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=self.config.prefetch_batches,
            thread_name_prefix="v3-replay-prefetch",
        ) as executor:
            iterator = iter(rows)
            for _ in range(self.config.prefetch_batches):
                try:
                    entries = next(iterator)
                except StopIteration:
                    break
                queue.append(
                    (
                        executor.submit(
                            load,
                            entries,
                        ),
                        time.perf_counter(),
                    )
                )
            while queue:
                future, submitted = queue.pop(0)
                waited = time.perf_counter()
                batch, load_seconds = future.result()
                wait_seconds = time.perf_counter() - waited
                yield batch, wait_seconds, load_seconds
                try:
                    entries = next(iterator)
                except StopIteration:
                    continue
                queue.append(
                    (
                        executor.submit(
                            load,
                            entries,
                        ),
                        time.perf_counter(),
                    )
                )

    def save_checkpoint(
        self,
        *,
        role: str = "learner",
        cycle_record: dict[str, Any] | None = None,
        allow_revision: bool = False,
    ) -> Path:
        import torch
        from safetensors.torch import save_file

        name = f"cycle-{self.cycle:04d}-step-{self.global_step:08d}"
        final = self.checkpoint_root / name
        if final.exists():
            if not allow_revision:
                raise FileExistsError(f"v3_checkpoint_exists:{name}")
            revision = 1
            while final.exists():
                final = self.checkpoint_root / (
                    f"{name}-revision-{revision:04d}"
                )
                revision += 1
            name = final.name
        temporary = Path(tempfile.mkdtemp(prefix=name + ".", dir=self.checkpoint_root))
        try:
            model_path = temporary / "model.safetensors"
            optimizer_path = temporary / "optimizer.pt"
            state_path = temporary / "state.json"
            state_dict = {
                key: value.detach().contiguous().cpu()
                for key, value in self.model.state_dict().items()
            }
            save_file(state_dict, str(model_path))
            _atomic_torch_save(
                optimizer_path,
                {
                    "optimizer": self.optimizer.state_dict(),
                    "scaler": self.scaler.state_dict(),
                    "scheduler": {
                        "kind": "cosine_with_warmup",
                        "global_step": self.global_step,
                    },
                },
            )
            state = {
                "schema": CHECKPOINT_SCHEMA,
                "run_format": RUN_FORMAT_VERSION,
                "checkpoint_version": CHECKPOINT_VERSION,
                "encoder_version": ENCODER_SCHEMA_VERSION,
                "model_variant": MODEL_VARIANT,
                "role": str(role),
                "global_step": self.global_step,
                "cycle": self.cycle,
                "config": asdict(self.config),
                "model_config": self.model.config_dict(),
                "metadata": checkpoint_metadata({"role": str(role)}),
                "rng": _rng_state(),
                "replay_rng": _jsonify(self.replay.random.getstate()),
                "cycle_record": dict(cycle_record or {}),
            }
            _atomic_json(state_path, state)
            bundle = {
                "schema": CHECKPOINT_SCHEMA,
                "checkpoint_version": CHECKPOINT_VERSION,
                "path": name,
                "files": {
                    "model.safetensors": _sha256(model_path),
                    "optimizer.pt": _sha256(optimizer_path),
                    "state.json": _sha256(state_path),
                },
            }
            _atomic_json(temporary / "bundle.json", bundle)
            os.replace(temporary, final)
            latest = {
                **bundle,
                "bundle_sha256": _sha256(final / "bundle.json"),
            }
            _atomic_json(self.latest_path, latest)
            return final
        finally:
            if temporary.exists():
                for child in temporary.iterdir():
                    with contextlib.suppress(FileNotFoundError):
                        child.unlink()
                with contextlib.suppress(OSError):
                    temporary.rmdir()

    def load_latest(self) -> Path:
        import torch
        from safetensors.torch import load_file

        if not self.latest_path.is_file():
            raise FileNotFoundError("v3_checkpoint_latest_missing")
        latest = json.loads(self.latest_path.read_text(encoding="utf-8"))
        if latest.get("schema") != CHECKPOINT_SCHEMA:
            raise ValueError("incompatible_v2_checkpoint_use_v3_fresh_run")
        root = (self.checkpoint_root / str(latest.get("path", ""))).resolve()
        if root.parent != self.checkpoint_root or not root.is_dir():
            raise ValueError("v3_checkpoint_path_invalid")
        bundle_path = root / "bundle.json"
        if _sha256(bundle_path) != latest.get("bundle_sha256"):
            raise ValueError("v3_checkpoint_bundle_hash_mismatch")
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        for name, expected in dict(bundle.get("files", {})).items():
            path = root / name
            if not path.is_file() or _sha256(path) != expected:
                raise ValueError(f"v3_checkpoint_file_hash_mismatch:{name}")
        state = json.loads((root / "state.json").read_text(encoding="utf-8"))
        if (
            int(state.get("checkpoint_version", 0)) != CHECKPOINT_VERSION
            or int(state.get("encoder_version", 0)) != ENCODER_SCHEMA_VERSION
            or state.get("model_variant") != MODEL_VARIANT
        ):
            raise ValueError("incompatible_v2_checkpoint_use_v3_fresh_run")
        if dict(state.get("config", {})) != asdict(self.config):
            raise ValueError("v3_checkpoint_learner_config_mismatch")
        self.model.load_state_dict(
            load_file(str(root / "model.safetensors"), device=self.config.device),
            strict=True,
        )
        try:
            optimizer = torch.load(
                root / "optimizer.pt",
                map_location=self.config.device,
                weights_only=True,
            )
        except TypeError:  # PyTorch 2.3 compatibility.
            optimizer = torch.load(root / "optimizer.pt", map_location=self.config.device)
        self.optimizer.load_state_dict(optimizer["optimizer"])
        self.scaler.load_state_dict(optimizer["scaler"])
        self.global_step = int(state["global_step"])
        self.cycle = int(state["cycle"])
        scheduler = dict(optimizer.get("scheduler", {}))
        if (
            scheduler.get("kind") != "cosine_with_warmup"
            or int(scheduler.get("global_step", -1)) != self.global_step
        ):
            raise ValueError("v3_checkpoint_scheduler_state_mismatch")
        _restore_rng_state(dict(state["rng"]))
        self.replay.random.setstate(_tupleify(state["replay_rng"]))
        self.model.eval()
        return root

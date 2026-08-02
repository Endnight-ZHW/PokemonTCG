"""Packed replay storage and collation for AlphaZero v2."""
from __future__ import annotations

import json
import os
import random
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np

from .infoset_encoder import EncodedCandidates, EncodedInformationSet
from .v2_contract import DEFAULT_REPLAY_CAPACITY, ENCODER_SCHEMA_VERSION


@dataclass(frozen=True)
class AlphaZeroSample:
    information_set: EncodedInformationSet
    candidates: EncodedCandidates
    policy_target: np.ndarray
    wdl_target: np.ndarray
    actor: int
    deck_key: str
    opponent_deck_key: str
    generation: int
    game_id: str
    ply: int
    source: str = "self_play"

    def validate(self) -> None:
        self.information_set.validate()
        self.candidates.validate()
        if self.policy_target.shape != (self.candidates.count,):
            raise ValueError("sample_policy_size_mismatch")
        if self.policy_target.dtype != np.float32:
            raise TypeError("sample_policy_dtype")
        if not np.isfinite(self.policy_target).all():
            raise ValueError("sample_policy_non_finite")
        if np.any(self.policy_target < 0.0):
            raise ValueError("sample_policy_negative")
        if not np.isclose(
            float(self.policy_target.sum()),
            1.0,
            atol=1e-5,
        ):
            raise ValueError("sample_policy_not_normalized")
        if self.wdl_target.shape != (3,):
            raise ValueError("sample_wdl_size_mismatch")
        if self.wdl_target.dtype != np.float32:
            raise TypeError("sample_wdl_dtype")
        if not np.isclose(float(self.wdl_target.sum()), 1.0, atol=1e-5):
            raise ValueError("sample_wdl_not_normalized")
        if self.actor not in (0, 1):
            raise ValueError("sample_actor_invalid")

    def with_winner(self, winner: int | None) -> "AlphaZeroSample":
        if winner is None:
            target = np.asarray((0.0, 1.0, 0.0), dtype=np.float32)
        elif int(winner) == self.actor:
            target = np.asarray((1.0, 0.0, 0.0), dtype=np.float32)
        else:
            target = np.asarray((0.0, 0.0, 1.0), dtype=np.float32)
        return replace(self, wdl_target=target)


def _atomic_torch_save(payload: Any, path: Path) -> None:
    import torch

    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        torch.save(payload, temporary)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


class ReplayStoreV2:
    """Generation-aware bounded replay with atomic tensor shards."""

    def __init__(
        self,
        root: str | Path,
        *,
        capacity: int = DEFAULT_REPLAY_CAPACITY,
        keep_generations: int = 3,
        seed: int = 17,
    ) -> None:
        self.root = Path(root)
        self.capacity = max(1, int(capacity))
        self.keep_generations = max(1, int(keep_generations))
        self.random = random.Random(int(seed))
        self._samples: list[AlphaZeroSample] = []
        self.root.mkdir(parents=True, exist_ok=True)

    def __len__(self) -> int:
        return len(self._samples)

    @property
    def samples(self) -> tuple[AlphaZeroSample, ...]:
        return tuple(self._samples)

    def add_generation(
        self,
        generation: int,
        samples: Iterable[AlphaZeroSample],
    ) -> Path:
        rows = list(samples)
        for row in rows:
            row.validate()
            if int(row.generation) != int(generation):
                raise ValueError("replay_generation_mismatch")
        shard = self.root / f"generation-{int(generation):03d}.pt"
        _atomic_torch_save(
            {
                "format": "alphazero_v2_replay",
                "encoder_version": ENCODER_SCHEMA_VERSION,
                "generation": int(generation),
                "samples": rows,
            },
            shard,
        )
        self._samples.extend(rows)
        self._trim(int(generation))
        self._write_index()
        return shard

    def load(self, current_generation: int | None = None) -> int:
        import torch

        self._samples.clear()
        minimum = (
            max(0, int(current_generation) - self.keep_generations + 1)
            if current_generation is not None
            else 0
        )
        for path in sorted(self.root.glob("generation-*.pt")):
            payload = torch.load(path, map_location="cpu", weights_only=False)
            if payload.get("format") != "alphazero_v2_replay":
                raise ValueError(f"invalid_replay_format:{path}")
            if int(payload.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION:
                raise ValueError(f"replay_encoder_mismatch:{path}")
            shard_generation = int(payload.get("generation") or 0)
            if (
                shard_generation < minimum
                or (
                    current_generation is not None
                    and shard_generation > int(current_generation)
                )
            ):
                continue
            for sample in payload.get("samples") or ():
                if not isinstance(sample, AlphaZeroSample):
                    raise TypeError(f"invalid_replay_sample:{path}")
                sample.validate()
                self._samples.append(sample)
        self._trim(
            int(current_generation)
            if current_generation is not None
            else max((row.generation for row in self._samples), default=0)
        )
        return len(self._samples)

    def stratified_epoch(self) -> list[AlphaZeroSample]:
        groups: dict[tuple[str, str, int], list[AlphaZeroSample]] = {}
        for sample in self._samples:
            phase_bucket = min(
                3,
                int(sample.information_set.state_global[17] * 30.0) // 6,
            )
            key = (
                sample.deck_key,
                sample.opponent_deck_key,
                phase_bucket,
            )
            groups.setdefault(key, []).append(sample)
        for group in groups.values():
            self.random.shuffle(group)
        ordered: list[AlphaZeroSample] = []
        keys = sorted(groups)
        while keys:
            remaining = []
            for key in keys:
                group = groups[key]
                if group:
                    ordered.append(group.pop())
                if group:
                    remaining.append(key)
            keys = remaining
        return ordered

    def _trim(self, current_generation: int) -> None:
        minimum = max(0, current_generation - self.keep_generations + 1)
        self._samples = [
            row
            for row in self._samples
            if int(row.generation) >= minimum
        ]
        if len(self._samples) > self.capacity:
            self._samples = self._samples[-self.capacity:]

    def _write_index(self) -> None:
        payload = {
            "format": "alphazero_v2_replay_index",
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "capacity": self.capacity,
            "keep_generations": self.keep_generations,
            "samples": len(self._samples),
            "generations": sorted(
                {int(row.generation) for row in self._samples}
            ),
        }
        path = self.root / "index.json"
        temporary = path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)


def collate_samples(
    samples: Sequence[AlphaZeroSample],
    *,
    device: str,
    pin_memory: bool = True,
    validate: bool = True,
    move_to_device: bool = True,
) -> dict[str, Any]:
    import torch

    if not samples:
        raise ValueError("cannot_collate_empty_batch")
    if validate:
        for sample in samples:
            sample.validate()
    batch = len(samples)
    max_candidates = max(row.candidates.count for row in samples)

    state_global = np.stack(
        [row.information_set.state_global for row in samples],
    )
    entity_numeric = np.stack(
        [row.information_set.entity_numeric for row in samples],
    )
    entity_card_ids = np.stack(
        [row.information_set.entity_card_ids for row in samples],
    )
    entity_type_ids = np.stack(
        [row.information_set.entity_type_ids for row in samples],
    )
    candidate_numeric = np.zeros(
        (batch, max_candidates, 32),
        dtype=np.float32,
    )
    candidate_card_ids = np.zeros(
        (batch, max_candidates),
        dtype=np.int64,
    )
    candidate_type_ids = np.zeros(
        (batch, max_candidates),
        dtype=np.int64,
    )
    candidate_refs = np.zeros(
        (batch, max_candidates, 4),
        dtype=np.int64,
    )
    candidate_mask = np.zeros(
        (batch, max_candidates),
        dtype=np.bool_,
    )
    policy_target = np.zeros(
        (batch, max_candidates),
        dtype=np.float32,
    )
    for index, row in enumerate(samples):
        count = row.candidates.count
        candidate_numeric[index, :count] = row.candidates.numeric
        candidate_card_ids[index, :count] = row.candidates.card_ids
        candidate_type_ids[index, :count] = row.candidates.type_ids
        candidate_refs[index, :count] = row.candidates.refs
        candidate_mask[index, :count] = row.candidates.mask
        policy_target[index, :count] = row.policy_target

    arrays = {
        "state_global": np.ascontiguousarray(state_global),
        "entity_numeric": np.ascontiguousarray(entity_numeric),
        "entity_card_ids": np.ascontiguousarray(entity_card_ids),
        "entity_type_ids": np.ascontiguousarray(entity_type_ids),
        "candidate_numeric": candidate_numeric,
        "candidate_card_ids": candidate_card_ids,
        "candidate_type_ids": candidate_type_ids,
        "candidate_refs": candidate_refs,
        "candidate_mask": candidate_mask,
        "actor_deck_id": np.asarray(
            [row.information_set.actor_deck_id for row in samples],
            dtype=np.int64,
        ),
        "opponent_deck_id": np.asarray(
            [row.information_set.opponent_deck_id for row in samples],
            dtype=np.int64,
        ),
        "policy_target": policy_target,
        "wdl_target": np.stack([row.wdl_target for row in samples]),
    }
    tensors = {
        name: torch.from_numpy(np.ascontiguousarray(value))
        for name, value in arrays.items()
    }
    if pin_memory and str(device).startswith("cuda"):
        tensors = {
            name: value.pin_memory()
            for name, value in tensors.items()
        }
    if not move_to_device:
        return tensors
    return {
        name: value.to(device, non_blocking=True)
        for name, value in tensors.items()
    }

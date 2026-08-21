"""Hash-verified streaming Safetensors replay for Deep AI v3."""
from __future__ import annotations

import contextlib
import hashlib
import json
import math
import os
import random
import shutil
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence

import numpy as np

from data.ai_card_vocab import card_vocab_sha256

from .encoder_v3 import EncodedCandidatesV3, EncodedInformationSetV3
from .v3_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    DEFAULT_REPLAY_BYTES,
    DEFAULT_REPLAY_CAPACITY,
    DEFAULT_REPLAY_SHARD_SAMPLES,
    DEFAULT_TEACHER_FRACTION,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
    REPLAY_FORMAT_VERSION,
    STATE_GLOBAL_SIZE,
)


MANIFEST_SCHEMA = "ptcg_deep_replay_v3"
SOURCE_SELF_PLAY = 0
SOURCE_TEACHER = 1
SOURCE_NAMES = {SOURCE_SELF_PLAY: "self_play", SOURCE_TEACHER: "teacher"}
SOURCE_IDS = {value: key for key, value in SOURCE_NAMES.items()}
REPO_ROOT = Path(__file__).resolve().parents[4]


def _contract_fingerprints() -> dict[str, str]:
    manifest = json.loads(
        (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
    )
    native = dict(manifest.get("native_rules", {}))
    return {
        "core_fingerprint": str(native.get("core_fingerprint", "")),
        "card_fingerprint": str(
            native.get("card_ir_content_fingerprint", "")
        ),
        "card_vocab_fingerprint": card_vocab_sha256(),
    }


def _safetensors():
    try:
        from safetensors import safe_open
        from safetensors.numpy import save_file
    except ImportError as exc:  # pragma: no cover - setup gate covers this.
        raise RuntimeError(
            "Deep AI v3 replay requires safetensors==0.4.5"
        ) from exc
    return safe_open, save_file


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


@contextlib.contextmanager
def _manifest_lock(path: Path, timeout_seconds: float = 30.0) -> Iterator[None]:
    """Acquire an atomic cross-platform publication lease.

    ``O_EXCL`` is the only coordination primitive used, so Windows and Linux
    workers share the same protocol without POSIX-only advisory locks.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + max(0.1, float(timeout_seconds))
    descriptor: int | None = None
    token = f"{os.getpid()}:{time.time_ns()}:{uuid.uuid4().hex}\n".encode(
        "ascii"
    )
    while descriptor is None:
        try:
            descriptor = os.open(
                path,
                os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                0o600,
            )
            os.write(descriptor, token)
            os.fsync(descriptor)
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise TimeoutError("replay_manifest_lock_timeout")
            time.sleep(0.05)
    try:
        yield
    finally:
        if descriptor is not None:
            os.close(descriptor)
        with contextlib.suppress(FileNotFoundError):
            path.unlink()


@dataclass(frozen=True, slots=True)
class ReplaySampleV3:
    information_set: EncodedInformationSetV3
    candidates: EncodedCandidatesV3
    policy_target: np.ndarray
    wdl_target: np.ndarray
    game_id: str
    game_seed: int
    ply: int
    actor: int
    deck_id: int
    opponent_deck_id: int
    model_version: int
    cycle: int
    phase_bucket: int
    source: str = "self_play"

    @property
    def sample_key(self) -> str:
        wire = (
            f"v3|{self.game_id}|{int(self.game_seed)}|{int(self.ply)}|"
            f"{int(self.actor)}|{int(self.model_version)}|{self.source}"
        ).encode("utf-8")
        return hashlib.sha256(wire).hexdigest()

    @property
    def validation_split(self) -> bool:
        digest = hashlib.sha256(
            f"v3-split|{int(self.game_seed)}".encode("ascii")
        ).digest()
        return int.from_bytes(digest[:8], "big") % 10 == 0

    def validate(self) -> None:
        self.information_set.validate()
        self.candidates.validate()
        if self.policy_target.dtype != np.float32 or self.policy_target.shape != (
            self.candidates.count,
        ):
            raise ValueError("v3_policy_target_shape_or_dtype")
        if self.wdl_target.dtype != np.float32 or self.wdl_target.shape != (3,):
            raise ValueError("v3_wdl_target_shape_or_dtype")
        if not np.isfinite(self.policy_target).all() or not np.isfinite(
            self.wdl_target
        ).all():
            raise ValueError("v3_replay_non_finite_target")
        if np.any(self.policy_target < 0) or not np.isclose(
            float(self.policy_target.sum()), 1.0, atol=1e-5
        ):
            raise ValueError("v3_policy_target_invalid")
        if np.any(self.wdl_target < 0) or not np.isclose(
            float(self.wdl_target.sum()), 1.0, atol=1e-5
        ):
            raise ValueError("v3_wdl_target_invalid")
        if self.actor not in (0, 1):
            raise ValueError("v3_sample_actor_invalid")
        if self.source not in SOURCE_IDS:
            raise ValueError("v3_sample_source_invalid")
        if not self.game_id or self.ply < 0 or self.game_seed < 0:
            raise ValueError("v3_sample_identity_invalid")


def _empty_manifest(capacity: int, byte_capacity: int) -> dict[str, Any]:
    return {
        "schema": MANIFEST_SCHEMA,
        "format_version": REPLAY_FORMAT_VERSION,
        "encoder_version": ENCODER_SCHEMA_VERSION,
        **_contract_fingerprints(),
        "capacity": int(capacity),
        "byte_capacity": int(byte_capacity),
        "samples": 0,
        "bytes": 0,
        "next_shard": 0,
        "shards": [],
    }


class ReplayStoreV3:
    """Append-only shards with bounded self-play retention and lazy reads."""

    def __init__(
        self,
        root: str | Path,
        *,
        capacity: int = DEFAULT_REPLAY_CAPACITY,
        byte_capacity: int = DEFAULT_REPLAY_BYTES,
        shard_samples: int = DEFAULT_REPLAY_SHARD_SAMPLES,
        seed: int = 17,
    ) -> None:
        self.root = Path(root).resolve()
        self.shard_root = self.root / "shards"
        self.manifest_path = self.root / "manifest.json"
        self.lock_path = self.root / "manifest.publish.lock"
        self.capacity = max(1, int(capacity))
        self.byte_capacity = max(1024, int(byte_capacity))
        self.shard_samples = max(1, int(shard_samples))
        self.random = random.Random(int(seed))
        self._buffer: list[ReplaySampleV3] = []
        self._known_keys: set[str] | None = None
        self._entry_cache: dict[
            str,
            tuple[tuple[int, int, int], tuple[ReplayEntryV3, ...]],
        ] = {}
        self.root.mkdir(parents=True, exist_ok=True)
        self.shard_root.mkdir(parents=True, exist_ok=True)
        if not self.manifest_path.exists():
            with _manifest_lock(self.lock_path):
                if not self.manifest_path.exists():
                    _atomic_json(
                        self.manifest_path,
                        _empty_manifest(self.capacity, self.byte_capacity),
                    )
        self._validate_manifest(self._read_manifest())

    def _read_manifest(self) -> dict[str, Any]:
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def _validate_manifest(self, manifest: dict[str, Any]) -> None:
        expected_fingerprints = _contract_fingerprints()
        if (
            manifest.get("schema") != MANIFEST_SCHEMA
            or int(manifest.get("format_version", 0)) != REPLAY_FORMAT_VERSION
            or int(manifest.get("encoder_version", 0)) != ENCODER_SCHEMA_VERSION
            or any(
                str(manifest.get(key, "")) != expected
                for key, expected in expected_fingerprints.items()
            )
        ):
            raise ValueError("incompatible_v2_replay_use_v3_fresh_run")
        if not isinstance(manifest.get("shards"), list):
            raise ValueError("v3_replay_manifest_invalid")

    @property
    def manifest(self) -> dict[str, Any]:
        manifest = self._read_manifest()
        self._validate_manifest(manifest)
        return manifest

    def __len__(self) -> int:
        return int(self.manifest.get("samples", 0)) + len(self._buffer)

    def add(self, sample: ReplaySampleV3) -> Path | None:
        sample.validate()
        self._load_known_keys()
        assert self._known_keys is not None
        if sample.sample_key in self._known_keys:
            raise ValueError(f"duplicate_v3_replay_sample:{sample.sample_key}")
        if any(row.sample_key == sample.sample_key for row in self._buffer):
            raise ValueError(f"duplicate_v3_replay_sample:{sample.sample_key}")
        self._buffer.append(sample)
        return self.flush() if len(self._buffer) >= self.shard_samples else None

    def add_if_missing(self, sample: ReplaySampleV3) -> tuple[bool, Path | None]:
        """Resume-safe append; normal ``add`` continues to reject duplicates."""
        sample.validate()
        self._load_known_keys()
        assert self._known_keys is not None
        if sample.sample_key in self._known_keys or any(
            row.sample_key == sample.sample_key for row in self._buffer
        ):
            return False, None
        self._buffer.append(sample)
        path = self.flush() if len(self._buffer) >= self.shard_samples else None
        return True, path

    def add_many(self, samples: Iterable[ReplaySampleV3]) -> list[Path]:
        paths: list[Path] = []
        for sample in samples:
            path = self.add(sample)
            if path is not None:
                paths.append(path)
        return paths

    def flush(self) -> Path | None:
        if not self._buffer:
            return None
        rows = tuple(self._buffer)
        self._buffer.clear()
        tensors = _pack_samples(rows)
        metadata = {
            "schema": MANIFEST_SCHEMA,
            "format_version": str(REPLAY_FORMAT_VERSION),
            "encoder_version": str(ENCODER_SCHEMA_VERSION),
            "samples": str(len(rows)),
            **_contract_fingerprints(),
        }
        _safe_open, save_file = _safetensors()
        removed: list[Path] = []
        with _manifest_lock(self.lock_path):
            manifest = self._read_manifest()
            self._validate_manifest(manifest)
            self._reject_published_duplicates(manifest, rows)
            shard_id = int(manifest.get("next_shard", 0))
            name = f"replay-{shard_id:08d}.safetensors"
            path = self.shard_root / name
            fd, temporary_name = tempfile.mkstemp(
                prefix=name + ".",
                suffix=".tmp",
                dir=self.shard_root,
            )
            os.close(fd)
            temporary = Path(temporary_name)
            try:
                save_file(tensors, str(temporary), metadata=metadata)
                with temporary.open("rb+") as handle:
                    os.fsync(handle.fileno())
                os.replace(temporary, path)
            finally:
                with contextlib.suppress(FileNotFoundError):
                    temporary.unlink()
            row = {
                "path": str(path.relative_to(self.root).as_posix()),
                "sha256": _sha256_file(path),
                "size": path.stat().st_size,
                "samples": len(rows),
                "teacher": all(sample.source == "teacher" for sample in rows),
                "game_seeds": sorted({int(sample.game_seed) for sample in rows}),
                "model_versions": sorted({
                    int(sample.model_version) for sample in rows
                }),
                "sources": sorted({sample.source for sample in rows}),
                "cycle_min": min(sample.cycle for sample in rows),
                "cycle_max": max(sample.cycle for sample in rows),
                "created_ns": time.time_ns(),
            }
            manifest["next_shard"] = shard_id + 1
            manifest["shards"].append(row)
            removed = self._trim_manifest(manifest)
            manifest["samples"] = sum(
                int(item["samples"]) for item in manifest["shards"]
            )
            manifest["bytes"] = sum(
                int(item["size"]) for item in manifest["shards"]
            )
            _atomic_json(self.manifest_path, manifest)
        for stale in removed:
            with contextlib.suppress(FileNotFoundError):
                stale.unlink()
        self._known_keys = None
        self._entry_cache.clear()
        return path

    def _trim_manifest(self, manifest: dict[str, Any]) -> list[Path]:
        rows = list(manifest["shards"])
        removed: list[Path] = []
        while (
            sum(int(row["samples"]) for row in rows) > self.capacity
            or sum(int(row["size"]) for row in rows) > self.byte_capacity
        ):
            index = next(
                (i for i, row in enumerate(rows) if not bool(row.get("teacher"))),
                None,
            )
            if index is None:
                break
            stale = rows.pop(index)
            removed.append(self._resolve_shard(stale))
        manifest["shards"] = rows
        return removed

    def _resolve_shard(self, row: dict[str, Any]) -> Path:
        path = (self.root / str(row.get("path", ""))).resolve()
        if path.parent != self.shard_root:
            raise ValueError("v3_replay_shard_outside_root")
        return path

    def verify(self) -> dict[str, int]:
        samples = 0
        size = 0
        seen: set[bytes] = set()
        safe_open, _save_file = _safetensors()
        for row in self.manifest["shards"]:
            path = self._resolve_shard(row)
            if not path.is_file() or _sha256_file(path) != row.get("sha256"):
                raise ValueError(f"v3_replay_shard_hash_mismatch:{path.name}")
            with safe_open(str(path), framework="np") as handle:
                keys = handle.get_tensor("sample_keys")
                if keys.shape != (int(row["samples"]), 32):
                    raise ValueError(f"v3_replay_key_shape:{path.name}")
                for key in keys:
                    wire = bytes(memoryview(np.ascontiguousarray(key)))
                    if wire in seen:
                        raise ValueError("duplicate_v3_replay_sample")
                    seen.add(wire)
            samples += int(row["samples"])
            size += int(row["size"])
        return {"samples": samples, "bytes": size, "shards": len(self.manifest["shards"])}

    def import_teacher(self, source: "ReplayStoreV3") -> dict[str, int]:
        """Import immutable teacher shards by hardlink, falling back to copy."""
        return self._import_store(source, teacher_only=True, prefix="teacher")

    def import_worker(self, source: "ReplayStoreV3") -> dict[str, int]:
        """Merge validated worker shards into this run's bounded replay."""
        return self._import_store(source, teacher_only=False, prefix="worker")

    def _import_store(
        self,
        source: "ReplayStoreV3",
        *,
        teacher_only: bool,
        prefix: str,
    ) -> dict[str, int]:
        if source.root == self.root:
            return {"samples": 0, "shards": 0}
        source.verify()
        source_manifest = source.manifest
        imported_samples = 0
        imported_shards = 0
        removed: list[Path] = []
        safe_open, _save_file = _safetensors()
        with _manifest_lock(self.lock_path):
            manifest = self._read_manifest()
            self._validate_manifest(manifest)
            known_hashes = {
                str(row.get("sha256", "")) for row in manifest["shards"]
            }
            known_keys: set[str] = set()
            for current in manifest["shards"]:
                with safe_open(
                    str(self._resolve_shard(current)), framework="np"
                ) as handle:
                    known_keys.update(
                        bytes(memoryview(np.ascontiguousarray(key))).hex()
                        for key in handle.get_tensor("sample_keys")
                    )
            for source_row in source_manifest["shards"]:
                if teacher_only and not bool(source_row.get("teacher")):
                    continue
                digest = str(source_row.get("sha256", ""))
                if digest in known_hashes:
                    continue
                source_path = source._resolve_shard(source_row)
                with safe_open(str(source_path), framework="np") as handle:
                    incoming = {
                        bytes(memoryview(np.ascontiguousarray(key))).hex()
                        for key in handle.get_tensor("sample_keys")
                    }
                if known_keys.intersection(incoming):
                    raise ValueError("duplicate_v3_replay_sample")
                shard_id = int(manifest.get("next_shard", 0))
                manifest["next_shard"] = shard_id + 1
                target = self.shard_root / (
                    f"{prefix}-{shard_id:08d}.safetensors"
                )
                temporary = self.shard_root / (
                    target.name + f".{uuid.uuid4().hex}.tmp"
                )
                try:
                    try:
                        os.link(source_path, temporary)
                    except OSError:
                        shutil.copy2(source_path, temporary)
                    os.replace(temporary, target)
                finally:
                    with contextlib.suppress(FileNotFoundError):
                        temporary.unlink()
                if _sha256_file(target) != digest:
                    target.unlink()
                    raise ValueError("v3_imported_worker_hash_mismatch")
                row = dict(source_row)
                row["path"] = str(target.relative_to(self.root).as_posix())
                if teacher_only:
                    row["teacher"] = True
                row["created_ns"] = time.time_ns()
                manifest["shards"].append(row)
                known_hashes.add(digest)
                known_keys.update(incoming)
                imported_samples += int(row["samples"])
                imported_shards += 1
            removed = self._trim_manifest(manifest)
            manifest["samples"] = sum(
                int(item["samples"]) for item in manifest["shards"]
            )
            manifest["bytes"] = sum(
                int(item["size"]) for item in manifest["shards"]
            )
            _atomic_json(self.manifest_path, manifest)
        for stale in removed:
            with contextlib.suppress(FileNotFoundError):
                stale.unlink()
        self._known_keys = None
        self._entry_cache.clear()
        return {"samples": imported_samples, "shards": imported_shards}

    def _load_known_keys(self) -> None:
        if self._known_keys is not None:
            return
        safe_open, _save_file = _safetensors()
        keys: set[str] = set()
        for row in self.manifest["shards"]:
            path = self._resolve_shard(row)
            with safe_open(str(path), framework="np") as handle:
                for key in handle.get_tensor("sample_keys"):
                    keys.add(bytes(memoryview(np.ascontiguousarray(key))).hex())
        self._known_keys = keys

    def _reject_published_duplicates(
        self,
        manifest: dict[str, Any],
        rows: Sequence[ReplaySampleV3],
    ) -> None:
        requested = {sample.sample_key for sample in rows}
        safe_open, _save_file = _safetensors()
        for row in manifest["shards"]:
            path = self._resolve_shard(row)
            with safe_open(str(path), framework="np") as handle:
                for key in handle.get_tensor("sample_keys"):
                    if bytes(memoryview(np.ascontiguousarray(key))).hex() in requested:
                        raise ValueError("duplicate_v3_replay_sample")

    def entries(self, *, split: str = "train") -> list["ReplayEntryV3"]:
        if split not in {"train", "validation", "all"}:
            raise ValueError("invalid_v3_replay_split")
        manifest = self.manifest
        signature = (
            int(manifest.get("next_shard", 0)),
            int(manifest.get("samples", 0)),
            int(manifest.get("bytes", 0)),
        )
        cached = self._entry_cache.get(split)
        if cached is not None and cached[0] == signature:
            return list(cached[1])
        safe_open, _save_file = _safetensors()
        result: list[ReplayEntryV3] = []
        for row in manifest["shards"]:
            path = self._resolve_shard(row)
            with safe_open(str(path), framework="np") as handle:
                validation = handle.get_tensor("validation_split")
                source = handle.get_tensor("source")
                deck = handle.get_tensor("deck_id")
                opponent = handle.get_tensor("opponent_deck_id")
                phase = handle.get_tensor("phase_bucket")
                cycle = handle.get_tensor("cycle")
                model_version = handle.get_tensor("model_version")
                count = int(row["samples"])
                for local in range(count):
                    is_validation = bool(validation[local])
                    if split == "train" and is_validation:
                        continue
                    if split == "validation" and not is_validation:
                        continue
                    result.append(
                        ReplayEntryV3(
                            path,
                            local,
                            int(source[local]),
                            int(deck[local]),
                            int(opponent[local]),
                            int(phase[local]),
                            int(cycle[local]),
                            int(model_version[local]),
                        )
                    )
        self._entry_cache[split] = (signature, tuple(result))
        return list(result)

    def sample_entries(
        self,
        count: int,
        *,
        split: str = "train",
        teacher_fraction: float = DEFAULT_TEACHER_FRACTION,
    ) -> list["ReplayEntryV3"]:
        rows = self.entries(split=split)
        if not rows:
            raise ValueError("v3_replay_split_empty")
        teacher = [row for row in rows if row.source == SOURCE_TEACHER]
        self_play = [row for row in rows if row.source == SOURCE_SELF_PLAY]
        target_teacher = min(
            len(teacher),
            max(0, int(round(int(count) * float(teacher_fraction)))),
        )
        target_self = max(0, int(count) - target_teacher)
        chosen = self._stratified_draw(self_play or teacher, target_self)
        chosen.extend(self._stratified_draw(teacher or self_play, target_teacher))
        self.random.shuffle(chosen)
        return chosen

    def cycle_progress(
        self,
        cycle: int,
        *,
        source: int = SOURCE_SELF_PLAY,
    ) -> dict[str, Any]:
        """Return durable progress using only compact shard metadata tensors."""
        safe_open, _save_file = _safetensors()
        samples = 0
        seeds: set[int] = set()
        for row in self.manifest["shards"]:
            if int(row.get("cycle_min", -1)) > int(cycle) or int(
                row.get("cycle_max", -1)
            ) < int(cycle):
                continue
            path = self._resolve_shard(row)
            with safe_open(str(path), framework="np") as handle:
                cycles = handle.get_tensor("cycle")
                sources = handle.get_tensor("source")
                game_seeds = handle.get_tensor("game_seed")
                selected = (cycles == int(cycle)) & (sources == int(source))
                samples += int(selected.sum())
                seeds.update(int(value) for value in game_seeds[selected])
        return {"samples": samples, "game_seeds": sorted(seeds)}

    def _stratified_draw(
        self,
        rows: Sequence["ReplayEntryV3"],
        count: int,
    ) -> list["ReplayEntryV3"]:
        if count <= 0:
            return []
        newest = max(row.model_version for row in rows)
        paths_by_recency: dict[int, list[Path]] = {}
        for row in rows:
            age = newest - row.model_version
            recency = 0 if age <= 0 else 1 if age <= 2 else 2
            paths_by_recency.setdefault(recency, []).append(row.path)
        selected_paths = {
            self.random.choice(sorted(set(paths)))
            for _recency, paths in sorted(paths_by_recency.items())
        }
        window: list[ReplayEntryV3] = []
        target_per_path = max(1, math.ceil(count / len(selected_paths)))
        for path in selected_paths:
            path_rows = [row for row in rows if row.path == path]
            first = min(row.local_index for row in path_rows)
            last = max(row.local_index for row in path_rows) + 1
            width = min(
                last - first,
                max(512, target_per_path * 4),
            )
            start = self.random.randint(first, max(first, last - width))
            selected = [
                row for row in path_rows
                if start <= row.local_index < start + width
            ]
            window.extend(selected or path_rows)
        groups: dict[tuple[int, int, int, int], list[ReplayEntryV3]] = {}
        for row in window:
            age = newest - row.model_version
            recency = 0 if age <= 0 else 1 if age <= 2 else 2
            groups.setdefault(
                (
                    row.deck_id,
                    row.opponent_deck_id,
                    row.phase_bucket,
                    recency,
                ),
                [],
            ).append(row)
        for values in groups.values():
            self.random.shuffle(values)
        keys = sorted(groups)
        result: list[ReplayEntryV3] = []
        cursor = 0
        while len(result) < count:
            key = keys[cursor % len(keys)]
            values = groups[key]
            result.append(values[(cursor // len(keys)) % len(values)])
            cursor += 1
        return result

    def collate(
        self,
        entries: Sequence["ReplayEntryV3"],
        *,
        device: str | None = None,
        pin_memory: bool = True,
    ) -> dict[str, Any]:
        if not entries:
            raise ValueError("cannot_collate_empty_v3_batch")
        safe_open, _save_file = _safetensors()
        loaded: list[dict[str, np.ndarray]] = []
        by_path: dict[Path, list[tuple[int, int]]] = {}
        for output_index, entry in enumerate(entries):
            by_path.setdefault(entry.path, []).append((output_index, entry.local_index))
        loaded = [{} for _ in entries]
        for path, indexes in by_path.items():
            with safe_open(str(path), framework="np") as handle:
                offsets = handle.get_tensor("candidate_offsets")
                fixed_names = (
                    "state_global",
                    "entity_numeric",
                    "entity_card_ids",
                    "entity_type_ids",
                    "entity_mask",
                    "actor_deck_id",
                    "opponent_deck_id",
                    "wdl_target",
                )
                ragged_names = (
                    "candidate_numeric",
                    "candidate_card_ids",
                    "candidate_type_ids",
                    "candidate_refs",
                    "policy_target",
                )
                local_values = [local for _output, local in indexes]
                local_first = min(local_values)
                local_last = max(local_values) + 1
                fixed = {
                    name: handle.get_slice(name)[local_first:local_last]
                    for name in fixed_names
                }
                candidate_first = min(
                    int(offsets[local]) for local in local_values
                )
                candidate_last = max(
                    int(offsets[local + 1]) for local in local_values
                )
                ragged = {
                    name: handle.get_slice(name)[
                        candidate_first:candidate_last
                    ]
                    for name in ragged_names
                }
                for output_index, local in indexes:
                    start, end = int(offsets[local]), int(offsets[local + 1])
                    loaded[output_index] = {
                        **{
                            name: value[local - local_first]
                            for name, value in fixed.items()
                        },
                        **{
                            name: value[
                                start - candidate_first : end - candidate_first
                            ]
                            for name, value in ragged.items()
                        },
                    }
        batch = len(loaded)
        maximum = max(row["candidate_card_ids"].shape[0] for row in loaded)
        arrays: dict[str, np.ndarray] = {
            "state_global": np.stack([row["state_global"] for row in loaded]).astype(np.float16, copy=False),
            "entity_numeric": np.stack([row["entity_numeric"] for row in loaded]).astype(np.float16, copy=False),
            "entity_card_ids": np.stack([row["entity_card_ids"] for row in loaded]).astype(np.int32, copy=False),
            "entity_type_ids": np.stack([row["entity_type_ids"] for row in loaded]).astype(np.int16, copy=False),
            "entity_mask": np.stack([row["entity_mask"] for row in loaded]).astype(np.bool_, copy=False),
            "actor_deck_id": np.asarray([row["actor_deck_id"] for row in loaded], dtype=np.int8),
            "opponent_deck_id": np.asarray([row["opponent_deck_id"] for row in loaded], dtype=np.int8),
            "wdl_target": np.stack([row["wdl_target"] for row in loaded]).astype(np.float32),
            "candidate_numeric": np.zeros((batch, maximum, CANDIDATE_NUMERIC_SIZE), dtype=np.float16),
            "candidate_card_ids": np.zeros((batch, maximum), dtype=np.int32),
            "candidate_type_ids": np.zeros((batch, maximum), dtype=np.int16),
            "candidate_refs": np.zeros((batch, maximum, CANDIDATE_REF_FIELDS), dtype=np.int16),
            "candidate_mask": np.zeros((batch, maximum), dtype=np.bool_),
            "policy_target": np.zeros((batch, maximum), dtype=np.float32),
        }
        for index, row in enumerate(loaded):
            width = row["candidate_card_ids"].shape[0]
            for name in (
                "candidate_numeric",
                "candidate_card_ids",
                "candidate_type_ids",
                "candidate_refs",
                "policy_target",
            ):
                arrays[name][index, :width] = row[name]
            arrays["candidate_mask"][index, :width] = True
        if device is None:
            return {name: np.ascontiguousarray(value) for name, value in arrays.items()}
        import torch

        tensors = {
            name: torch.from_numpy(np.ascontiguousarray(value))
            for name, value in arrays.items()
        }
        if pin_memory and str(device).startswith("cuda"):
            tensors = {name: value.pin_memory() for name, value in tensors.items()}
        return {
            name: value.to(device, non_blocking=True)
            for name, value in tensors.items()
        }


@dataclass(frozen=True, slots=True)
class ReplayEntryV3:
    path: Path
    local_index: int
    source: int
    deck_id: int
    opponent_deck_id: int
    phase_bucket: int
    cycle: int
    model_version: int


def _pack_samples(samples: Sequence[ReplaySampleV3]) -> dict[str, np.ndarray]:
    if not samples:
        raise ValueError("cannot_pack_empty_v3_shard")
    for sample in samples:
        sample.validate()
    offsets = np.zeros(len(samples) + 1, dtype=np.int64)
    for index, sample in enumerate(samples):
        offsets[index + 1] = offsets[index] + sample.candidates.count
    tensors = {
        "state_global": np.stack([row.information_set.state_global for row in samples]).astype(np.float16),
        "entity_numeric": np.stack([row.information_set.entity_numeric for row in samples]).astype(np.float16),
        "entity_card_ids": np.stack([row.information_set.entity_card_ids for row in samples]).astype(np.int32),
        "entity_type_ids": np.stack([row.information_set.entity_type_ids for row in samples]).astype(np.int16),
        "entity_mask": np.stack([row.information_set.entity_mask for row in samples]).astype(np.bool_),
        "candidate_offsets": offsets,
        "candidate_numeric": np.concatenate([row.candidates.numeric for row in samples]).astype(np.float16),
        "candidate_card_ids": np.concatenate([row.candidates.card_ids for row in samples]).astype(np.int32),
        "candidate_type_ids": np.concatenate([row.candidates.type_ids for row in samples]).astype(np.int16),
        "candidate_refs": np.concatenate([row.candidates.refs for row in samples]).astype(np.int16),
        "policy_target": np.concatenate([row.policy_target for row in samples]).astype(np.float32),
        "wdl_target": np.stack([row.wdl_target for row in samples]).astype(np.float32),
        "sample_keys": np.stack([
            np.frombuffer(bytes.fromhex(row.sample_key), dtype=np.uint8)
            for row in samples
        ]),
        "game_seed": np.asarray([row.game_seed for row in samples], dtype=np.int64),
        "ply": np.asarray([row.ply for row in samples], dtype=np.int32),
        "actor": np.asarray([row.actor for row in samples], dtype=np.int8),
        "deck_id": np.asarray([row.deck_id for row in samples], dtype=np.int8),
        "opponent_deck_id": np.asarray([row.opponent_deck_id for row in samples], dtype=np.int8),
        "model_version": np.asarray([row.model_version for row in samples], dtype=np.int32),
        "cycle": np.asarray([row.cycle for row in samples], dtype=np.int32),
        "phase_bucket": np.asarray([row.phase_bucket for row in samples], dtype=np.int8),
        "source": np.asarray([SOURCE_IDS[row.source] for row in samples], dtype=np.int8),
        "validation_split": np.asarray([row.validation_split for row in samples], dtype=np.bool_),
        "actor_deck_id": np.asarray([row.information_set.actor_deck_id for row in samples], dtype=np.int8),
        "opponent_deck_id_input": np.asarray([row.information_set.opponent_deck_id for row in samples], dtype=np.int8),
    }
    # Keep model input names stable while retaining sample metadata names.
    tensors["opponent_deck_id"] = tensors.pop("opponent_deck_id_input")
    tensors["actor_deck_id"] = np.asarray(
        [row.information_set.actor_deck_id for row in samples], dtype=np.int8
    )
    return {name: np.ascontiguousarray(value) for name, value in tensors.items()}

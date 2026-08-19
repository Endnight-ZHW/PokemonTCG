"""Atomic run, event, replay, and checkpoint storage for Deep AI training."""
from __future__ import annotations

import datetime as _datetime
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Iterable

from data.ai_card_vocab import (
    CARD_VOCAB_VERSION,
    card_vocab_sha256,
    card_vocab_size,
)
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai.dl.v2_contract import (
    CHECKPOINT_VERSION,
    ENCODER_SCHEMA_VERSION,
)
from engine.ai.dl.production_contract import (
    CHECKPOINT_FORMAT_VERSION,
    DEEP_PLANNER_SCHEMA_VERSION,
    RUN_FORMAT_VERSION,
    TRAINING_EVENT_SCHEMA,
)

try:
    import torch
except Exception:  # pragma: no cover - normal non-DL clients do not install torch.
    torch = None


RUN_ID_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$")
RUN_SUBDIRECTORIES = (
    "checkpoints",
    "models",
    "evaluation",
    "logs",
    "staging",
    "replay",
    "league",
)
TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled", "promoted"})
ACTIVE_STATUSES = frozenset({"starting", "running", "pausing", "paused", "cancelling", "promoting"})


def utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: str | os.PathLike[str]) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_bytes(path: str | os.PathLike[str], payload: bytes) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=destination.name + ".",
        suffix=".tmp",
        dir=str(destination.parent),
    )
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def atomic_write_json(path: str | os.PathLike[str], payload: Any) -> None:
    atomic_write_bytes(path, canonical_json_bytes(payload) + b"\n")


def read_json(path: str | os.PathLike[str]) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        result = json.load(handle)
    if not isinstance(result, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return result


def resolve_within(root: str | os.PathLike[str], candidate: str | os.PathLike[str]) -> Path:
    """Resolve a candidate and reject traversal outside ``root``."""

    root_path = Path(root).resolve()
    value = Path(candidate)
    resolved = value.resolve() if value.is_absolute() else (root_path / value).resolve()
    try:
        resolved.relative_to(root_path)
    except ValueError as exc:
        raise ValueError(f"Path escapes training root: {candidate}") from exc
    return resolved


def validate_run_id(run_id: str) -> str:
    value = str(run_id or "")
    if not RUN_ID_PATTERN.fullmatch(value) or value in {".", ".."}:
        raise ValueError(f"Invalid training run ID: {run_id!r}")
    return value


def create_run_layout(
    runs_root: str | os.PathLike[str],
    run_id: str,
    *,
    run_payload: dict[str, Any],
    exist_ok: bool = False,
) -> Path:
    run_id = validate_run_id(run_id)
    root = Path(runs_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    run_dir = resolve_within(root, run_id)
    run_dir.mkdir(parents=False, exist_ok=exist_ok)
    for name in RUN_SUBDIRECTORIES:
        (run_dir / name).mkdir(exist_ok=True)
    payload = {
        "format_version": RUN_FORMAT_VERSION,
        "run_id": run_id,
        "created_at": utc_now(),
        "updated_at": utc_now(),
        **run_payload,
    }
    atomic_write_json(run_dir / "run.json", payload)
    # The event file exists from creation, but only the trainer process appends.
    (run_dir / "events.jsonl").touch(exist_ok=True)
    return run_dir


def update_run(run_dir: str | os.PathLike[str], **changes: Any) -> dict[str, Any]:
    path = Path(run_dir) / "run.json"
    payload = read_json(path)
    payload.update(changes)
    payload["updated_at"] = utc_now()
    atomic_write_json(path, payload)
    return payload


class TrainingEventWriter:
    """The sole append-only JSONL writer used by the trainer main process."""

    def __init__(self, run_dir: str | os.PathLike[str], run_id: str):
        self.run_dir = Path(run_dir)
        self.run_id = validate_run_id(run_id)
        self.path = self.run_dir / "events.jsonl"
        self._lock = threading.Lock()
        self._seq = self._last_seq()

    @property
    def seq(self) -> int:
        return self._seq

    def _last_seq(self) -> int:
        if not self.path.exists():
            return 0
        last = 0
        with self.path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                    last = max(last, int(row.get("seq", 0)))
                except (ValueError, TypeError, json.JSONDecodeError):
                    continue
        return last

    def emit(
        self,
        *,
        stage: str,
        deck: str = "",
        completed: int = 0,
        total: int = 0,
        metrics: dict[str, Any] | None = None,
        message: str = "",
        event: str = "progress",
    ) -> dict[str, Any]:
        with self._lock:
            self._seq += 1
            now = time.time()
            row = {
                "type": TRAINING_EVENT_SCHEMA,
                "event": str(event),
                "run_id": self.run_id,
                "seq": self._seq,
                "time": utc_now(),
                "timestamp": now,
                "stage": str(stage),
                "deck": str(deck),
                "completed": max(0, int(completed)),
                "total": max(0, int(total)),
                "metrics": dict(metrics or {}),
                "message": str(message),
            }
            wire = json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            with self.path.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(wire)
                handle.flush()
                os.fsync(handle.fileno())
            return row


def read_events(
    path: str | os.PathLike[str],
    *,
    after_seq: int = 0,
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    last = int(after_seq)
    if not Path(path).exists():
        return result
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                # A concurrent reader may observe an incomplete final line.
                continue
            if not isinstance(row, dict):
                continue
            seq = int(row.get("seq", 0))
            if seq <= last:
                continue
            if result and seq <= int(result[-1].get("seq", 0)):
                raise ValueError("Training event sequence is not strictly increasing")
            result.append(row)
    return result


def _git_output(repo_root: Path, *args: str) -> bytes:
    try:
        return subprocess.check_output(
            ["git", *args],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return b""


def build_fingerprint(
    repo_root: str | os.PathLike[str],
    config: dict[str, Any],
    *,
    extra_files: Iterable[str | os.PathLike[str]] = (),
) -> dict[str, Any]:
    root = Path(repo_root).resolve()
    relative_files = {
        "release_manifest.json",
        "python/engine/actions.py",
        "python/engine/ai/dl/encoder.py",
        "python/data/ai_card_vocab.json",
        "python/engine/ai/dl/model_v2.py",
        "python/engine/ai/dl/alphazero_v2.py",
        "python/engine/ai/dl/production_contract.py",
        "python/engine/ai/dl/run_store.py",
        *(str(Path(item).as_posix()) for item in extra_files),
    }
    file_hashes: dict[str, str] = {}
    for relative in sorted(relative_files):
        path = root / relative
        if path.is_file():
            file_hashes[relative] = sha256_file(path)
    commit = _git_output(root, "rev-parse", "HEAD").decode("ascii", "replace").strip()
    dirty_patch = _git_output(root, "diff", "--binary", "HEAD")
    schemas = {
        "python_rules": RULES_SCHEMA_VERSION,
        "python_actions": ACTION_SCHEMA_VERSION,
        "encoder": ENCODER_SCHEMA_VERSION,
        "checkpoint": CHECKPOINT_VERSION,
        "card_vocab_version": CARD_VOCAB_VERSION,
        "card_vocab_size": card_vocab_size(),
        "card_vocab_sha256": card_vocab_sha256(),
        "deep_planner": DEEP_PLANNER_SCHEMA_VERSION,
    }
    return {
        "config_sha256": sha256_bytes(canonical_json_bytes(config)),
        "schemas": schemas,
        "git_commit": commit,
        "git_dirty_sha256": sha256_bytes(dirty_patch),
        "file_sha256": file_hashes,
    }


def validate_fingerprint(expected: dict[str, Any], actual: dict[str, Any]) -> None:
    mismatches: list[str] = []
    for key in ("config_sha256", "schemas", "git_commit", "git_dirty_sha256", "file_sha256"):
        if expected.get(key) != actual.get(key):
            mismatches.append(key)
    if mismatches:
        raise RuntimeError(
            "Training run is incompatible with the current configuration/code: "
            + ", ".join(mismatches)
        )


def capture_rng_state() -> dict[str, Any]:
    state: dict[str, Any] = {"python": random.getstate()}
    if torch is not None:
        state["torch_cpu"] = torch.get_rng_state()
        try:
            if torch.cuda.is_available():
                state["torch_cuda"] = torch.cuda.get_rng_state_all()
        except Exception:
            pass
    return state


def restore_rng_state(state: dict[str, Any]) -> None:
    if state.get("python") is not None:
        random.setstate(state["python"])
    if torch is not None and state.get("torch_cpu") is not None:
        cpu_state = state["torch_cpu"]
        if hasattr(cpu_state, "cpu"):
            cpu_state = cpu_state.cpu()
        torch.set_rng_state(cpu_state)
        if state.get("torch_cuda") is not None:
            try:
                cuda_states = [
                    item.cpu() if hasattr(item, "cpu") else item
                    for item in state["torch_cuda"]
                ]
                torch.cuda.set_rng_state_all(cuda_states)
            except Exception as exc:
                raise RuntimeError("Unable to restore CUDA RNG state") from exc


def _atomic_torch_save(path: Path, payload: Any) -> None:
    if torch is None:
        raise RuntimeError("PyTorch is required for training checkpoints")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )
    os.close(fd)
    try:
        torch.save(payload, temporary)
        # Windows requires a writable descriptor for fsync/FlushFileBuffers.
        with open(temporary, "rb+") as handle:
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


class CheckpointStore:
    def __init__(self, run_dir: str | os.PathLike[str]):
        self.run_dir = Path(run_dir).resolve()
        self.directory = self.run_dir / "checkpoints"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.latest_path = self.directory / "latest.json"

    def save(self, batch_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        safe_batch = re.sub(r"[^a-zA-Z0-9_.-]+", "_", str(batch_id))[:96]
        if not safe_batch:
            raise ValueError("Checkpoint batch ID is empty")
        path = self.directory / f"{safe_batch}.pt"
        wrapped = {
            "format_version": CHECKPOINT_FORMAT_VERSION,
            "created_at": utc_now(),
            **payload,
        }
        _atomic_torch_save(path, wrapped)
        row = {
            "format_version": CHECKPOINT_FORMAT_VERSION,
            "batch_id": str(batch_id),
            "path": path.name,
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
            "created_at": utc_now(),
        }
        atomic_write_json(self.latest_path, row)
        return row

    def load_latest(self, *, map_location: str = "cpu") -> tuple[dict[str, Any], dict[str, Any]] | None:
        if not self.latest_path.exists():
            return None
        if torch is None:
            raise RuntimeError("PyTorch is required for training checkpoints")
        row = read_json(self.latest_path)
        path = resolve_within(self.directory, str(row.get("path", "")))
        if not path.is_file():
            raise RuntimeError(f"Checkpoint file is missing: {path.name}")
        actual = sha256_file(path)
        expected = str(row.get("sha256", "")).lower()
        if not expected or actual != expected:
            raise RuntimeError(f"Checkpoint SHA-256 mismatch: {path.name}")
        try:
            payload = torch.load(path, map_location=map_location, weights_only=False)
        except TypeError:
            payload = torch.load(path, map_location=map_location)
        if not isinstance(payload, dict):
            raise RuntimeError("Checkpoint payload is not an object")
        if int(payload.get("format_version", 0)) != CHECKPOINT_FORMAT_VERSION:
            raise RuntimeError("Unsupported training checkpoint format")
        return payload, row


class ReplayShardStore:
    """Append-only replay shards with a hash-verified manifest."""

    def __init__(self, run_dir: str | os.PathLike[str]):
        self.run_dir = Path(run_dir).resolve()
        self.directory = self.run_dir / "replay"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.manifest_path = self.directory / "manifest.json"

    def _manifest(self) -> dict[str, Any]:
        if not self.manifest_path.exists():
            return {"format_version": 1, "shards": []}
        return read_json(self.manifest_path)

    def write(self, batch_id: str, payload: Any) -> dict[str, Any]:
        safe_batch = re.sub(r"[^a-zA-Z0-9_.-]+", "_", str(batch_id))[:96]
        path = self.directory / f"{safe_batch}.pt"
        _atomic_torch_save(path, payload)
        row = {
            "batch_id": str(batch_id),
            "path": path.name,
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
            "created_at": utc_now(),
        }
        if isinstance(payload, dict) and isinstance(
            payload.get("data_schema"),
            dict,
        ):
            row["data_schema"] = dict(payload["data_schema"])
        manifest = self._manifest()
        shards = [
            item for item in list(manifest.get("shards", []))
            if str(item.get("batch_id", "")) != str(batch_id)
        ]
        shards.append(row)
        manifest["shards"] = shards
        atomic_write_json(self.manifest_path, manifest)
        return row

    def rows(self, *, verify: bool = True) -> list[dict[str, Any]]:
        rows = list(self._manifest().get("shards", []))
        if verify:
            for row in rows:
                path = resolve_within(self.directory, str(row.get("path", "")))
                if not path.is_file() or sha256_file(path) != str(row.get("sha256", "")).lower():
                    raise RuntimeError(f"Replay shard hash mismatch: {path.name}")
        return rows


def process_is_alive(pid: int) -> bool:
    if int(pid) <= 0:
        return False
    if os.name == "nt":
        try:
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {int(pid)}", "/FO", "CSV", "/NH"],
                text=True,
                capture_output=True,
                timeout=5,
                check=False,
            )
            return result.returncode == 0 and f'"{int(pid)}"' in result.stdout
        except OSError:
            return False
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


def runtime_environment() -> dict[str, Any]:
    result: dict[str, Any] = {
        "python_version": sys.version,
        "python_executable": sys.executable,
    }
    if torch is not None:
        result.update(
            {
                "torch_version": str(getattr(torch, "__version__", "")),
                "cuda_version": str(getattr(getattr(torch, "version", None), "cuda", "")),
                "cuda_available": bool(torch.cuda.is_available()),
                "gpu_name": (
                    str(torch.cuda.get_device_name(0))
                    if torch.cuda.is_available()
                    else ""
                ),
            }
        )
    return result

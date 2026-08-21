"""Small, atomic run/event store shared by the v3 trainer and dashboard."""
from __future__ import annotations

import datetime as _datetime
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

from .v3_contract import RUN_FORMAT_VERSION


TRAINING_EVENT_SCHEMA = "ptcg_deep_event_v3"
RUN_ID_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$")
RUN_SUBDIRECTORIES = (
    "logs",
    "staging",
    "checkpoints-v3",
    "replay-v3",
    "champion-v3",
)
ACTIVE_STATUSES = frozenset(
    {"starting", "running", "pausing", "paused", "cancelling"}
)


def utc_now() -> str:
    return (
        _datetime.datetime.now(_datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def atomic_write_bytes(path: str | os.PathLike[str], payload: bytes) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=destination.name + ".",
        suffix=".tmp",
        dir=str(destination.parent),
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
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
    atomic_write_bytes(path, _canonical_json_bytes(payload) + b"\n")


def read_json(path: str | os.PathLike[str]) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        result = json.load(handle)
    if not isinstance(result, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return result


def resolve_within(
    root: str | os.PathLike[str],
    candidate: str | os.PathLike[str],
) -> Path:
    """Resolve a path and reject traversal outside ``root``."""
    root_path = Path(root).resolve()
    value = Path(candidate)
    resolved = (
        value.resolve()
        if value.is_absolute()
        else (root_path / value).resolve()
    )
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
    now = utc_now()
    atomic_write_json(
        run_dir / "run.json",
        {
            "format_version": RUN_FORMAT_VERSION,
            "run_id": run_id,
            "created_at": now,
            "updated_at": now,
            **run_payload,
        },
    )
    (run_dir / "events.jsonl").touch(exist_ok=True)
    return run_dir


def update_run(
    run_dir: str | os.PathLike[str],
    **changes: Any,
) -> dict[str, Any]:
    path = Path(run_dir) / "run.json"
    payload = read_json(path)
    payload.update(changes)
    payload["updated_at"] = utc_now()
    atomic_write_json(path, payload)
    return payload


class TrainingEventWriter:
    """Single-writer append-only event stream for one trainer process."""

    def __init__(
        self,
        run_dir: str | os.PathLike[str],
        run_id: str,
        *,
        schema: str = TRAINING_EVENT_SCHEMA,
    ) -> None:
        self.run_dir = Path(run_dir)
        self.run_id = validate_run_id(run_id)
        self.schema = str(schema)
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
                "type": self.schema,
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
    if not Path(path).exists():
        return result
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                # A concurrent reader can observe an incomplete final line.
                continue
            if not isinstance(row, dict):
                continue
            sequence = int(row.get("seq", 0))
            if sequence <= int(after_seq):
                continue
            if result and sequence <= int(result[-1].get("seq", 0)):
                raise ValueError(
                    "Training event sequence is not strictly increasing"
                )
            result.append(row)
    return result


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

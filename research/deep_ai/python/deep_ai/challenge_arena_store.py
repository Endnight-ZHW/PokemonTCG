"""Crash-safe, resumable result storage for long Native Arena runs."""
from __future__ import annotations

import hashlib
import json
import os
import socket
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from .challenge_arena_build import write_json_atomic


RUN_STATE_SCHEMA = "ptcg.challenge_arena.run_state/1"


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _process_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        synchronize = 0x00100000
        wait_timeout = 0x00000102
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = (
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_ulong,
        )
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_ulong)
        kernel32.WaitForSingleObject.restype = ctypes.c_ulong
        kernel32.CloseHandle.argtypes = (ctypes.c_void_p,)
        kernel32.CloseHandle.restype = ctypes.c_int
        handle = kernel32.OpenProcess(synchronize, False, pid)
        if not handle:
            return False
        try:
            return kernel32.WaitForSingleObject(handle, 0) == wait_timeout
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _jsonl_bytes(values: Iterable[Mapping[str, Any]]) -> bytes:
    return "".join(
        json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n"
        for value in values
    ).encode("utf-8")


def write_bytes_atomic(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    with temporary.open("wb") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


class ChallengeArenaRunStore:
    def __init__(
        self,
        root: Path,
        *,
        fingerprint: str,
        task_ids: Sequence[str],
    ) -> None:
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock_path = self.root / ".arena.lock"
        self.state_path = self.root / "arena-run-state.json"
        self.shards_root = self.root / "shards"
        self.fingerprint = str(fingerprint)
        self.task_ids = tuple(str(value) for value in task_ids)
        self._locked = False
        self._state: dict[str, Any] = {}
        self._games: dict[str, dict[str, Any]] = {}
        self._acquire_lock()
        try:
            self._open_or_create()
        except Exception:
            self.close()
            raise

    def _acquire_lock(self) -> None:
        payload = {
            "pid": os.getpid(),
            "host": socket.gethostname(),
        }
        for attempt in range(2):
            try:
                descriptor = os.open(
                    self.lock_path,
                    os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                    0o600,
                )
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    json.dump(payload, stream, sort_keys=True)
                    stream.flush()
                    os.fsync(stream.fileno())
                self._locked = True
                return
            except FileExistsError:
                if attempt:
                    break
                try:
                    existing = json.loads(self.lock_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    existing = {}
                if (
                    existing.get("host") == socket.gethostname()
                    and not _process_alive(int(existing.get("pid", -1)))
                ):
                    self.lock_path.unlink(missing_ok=True)
                    continue
                break
        raise RuntimeError("challenge_arena_output_locked")

    def _open_or_create(self) -> None:
        expected_ids = sorted(self.task_ids)
        if self.state_path.is_file():
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
            if state.get("schema") != RUN_STATE_SCHEMA:
                raise RuntimeError("arena_resume_state_schema_mismatch")
            if state.get("fingerprint") != self.fingerprint:
                raise RuntimeError("arena_resume_fingerprint_mismatch")
            if state.get("task_ids") != expected_ids:
                raise RuntimeError("arena_resume_task_matrix_mismatch")
            self._state = state
            self._load_shards()
            return
        self._state = {
            "schema": RUN_STATE_SCHEMA,
            "fingerprint": self.fingerprint,
            "task_ids": expected_ids,
            "status": "running",
            "shards": [],
            "completed_task_ids": [],
            "elapsed_seconds": 0.0,
        }
        write_json_atomic(self.state_path, self._state)

    def _load_shards(self) -> None:
        for row in self._state.get("shards", []):
            relative = Path(str(row["path"]))
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not relative.parts
                or relative.parts[0] != "shards"
            ):
                raise RuntimeError("arena_shard_path_invalid")
            path = self.root / relative
            payload = path.read_bytes()
            if _sha256_bytes(payload) != str(row["sha256"]):
                raise RuntimeError(f"arena_shard_sha256_mismatch:{path.name}")
            lines = payload.decode("utf-8").splitlines()
            if int(row.get("games", -1)) != len(lines):
                raise RuntimeError("arena_shard_game_count_mismatch")
            for line in lines:
                game = json.loads(line)
                task_id = str(game.get("task_id", ""))
                if not task_id or task_id in self._games:
                    raise RuntimeError("arena_shard_duplicate_task_id")
                if task_id not in self.task_ids:
                    raise RuntimeError("arena_shard_unknown_task_id")
                self._games[task_id] = game
        if sorted(self._games) != sorted(self._state.get("completed_task_ids", [])):
            raise RuntimeError("arena_resume_completed_index_mismatch")

    @property
    def complete(self) -> bool:
        return self._state.get("status") == "complete"

    @property
    def games(self) -> list[dict[str, Any]]:
        return [self._games[key] for key in sorted(self._games)]

    @property
    def completed_task_ids(self) -> set[str]:
        return set(self._games)

    @property
    def elapsed_seconds(self) -> float:
        return float(self._state.get("elapsed_seconds", 0.0))

    def append(self, games: Sequence[Mapping[str, Any]]) -> None:
        if not games:
            return
        rows = sorted((dict(value) for value in games), key=lambda row: row["task_id"])
        batch_ids: set[str] = set()
        for game in rows:
            task_id = str(game.get("task_id", ""))
            if task_id not in self.task_ids:
                raise RuntimeError("arena_shard_unknown_task_id")
            if task_id in self._games or task_id in batch_ids:
                raise RuntimeError("arena_shard_duplicate_task_id")
            batch_ids.add(task_id)
        existing_indices = [
            int(path.stem.split("-")[-1])
            for path in self.shards_root.glob("shard-*.jsonl")
            if path.stem.split("-")[-1].isdigit()
        ]
        index = max(existing_indices, default=0) + 1
        relative = Path("shards") / f"shard-{index:06d}.jsonl"
        payload = _jsonl_bytes(rows)
        write_bytes_atomic(self.root / relative, payload)
        for game in rows:
            self._games[str(game["task_id"])] = game
        self._state["shards"].append({
            "path": relative.as_posix(),
            "sha256": _sha256_bytes(payload),
            "games": len(rows),
        })
        self._state["completed_task_ids"] = sorted(self._games)
        write_json_atomic(self.state_path, self._state)

    def add_elapsed_seconds(self, value: float) -> None:
        self._state["elapsed_seconds"] = (
            self.elapsed_seconds + max(0.0, float(value))
        )
        write_json_atomic(self.state_path, self._state)

    def mark_complete(self, gate_status: str) -> None:
        self._state["status"] = "complete"
        self._state["gate_status"] = str(gate_status)
        self._state["remaining_task_ids"] = sorted(
            set(self.task_ids) - set(self._games)
        )
        write_json_atomic(self.state_path, self._state)

    def close(self) -> None:
        if self._locked:
            self.lock_path.unlink(missing_ok=True)
            self._locked = False

    def __enter__(self) -> "ChallengeArenaRunStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def write_jsonl_atomic(path: Path, values: Iterable[Mapping[str, Any]]) -> None:
    write_bytes_atomic(path, _jsonl_bytes(values))

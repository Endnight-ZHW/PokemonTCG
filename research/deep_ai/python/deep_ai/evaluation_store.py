"""Checksummed evidence journal and complete-round cache for both executors."""
from __future__ import annotations

import hashlib
import json
import os
import socket
import secrets
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from .challenge_arena_build import write_json_atomic
from .evaluation_fairness import canonical_hash
from .evaluation_protocol import EvaluationProtocol, GameEvidence, evidence_semantics


RUN_STATE_SCHEMA = "ptcg.ai_evaluation.run_state/1"


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


class EvaluationRunStore:
    def __init__(self, root: Path, protocol: EvaluationProtocol) -> None:
        if (root / "arena-summary.json").exists() and not (root / "evaluation-protocol.json").exists():
            raise ValueError("evaluation_output_protocol_missing")
        self.protocol = protocol
        self.tasks = {task.task_id: task for comparison in protocol.comparisons
                      for rep in range(protocol.maximum_replicates)
                      for task in protocol.tasks(comparison, rep)}
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock_path = self.root / ".arena.lock"
        self.state_path = self.root / "arena-run-state.json"
        self.shards_root = self.root / "shards"
        self.fingerprint = protocol.fingerprint
        self.task_ids = tuple(self.tasks)
        self._completed_digest = hashlib.sha256()
        self._next_shard_index: int | None = None
        self._task_id_set = set(self.task_ids)
        if len(self._task_id_set) != len(self.task_ids):
            raise ValueError("arena_store_duplicate_scheduled_task")
        self._locked = False
        self._state: dict[str, Any] = {}
        self._games: dict[str, dict[str, Any]] = {}
        self._attempts: list[dict[str, Any]] = []
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
        # Freeze the cohort under the directory lock before creating any journal.
        path = self.root / "evaluation-protocol.json"
        if path.exists():
            saved = EvaluationProtocol.from_dict(json.loads(path.read_text(encoding="utf-8")))
            if saved.fingerprint != self.protocol.fingerprint:
                raise ValueError("evaluation_resume_protocol_mismatch")
        else:
            write_json_atomic(path, self.protocol.to_dict())
        expected_ids = sorted(self.task_ids)
        if self.state_path.is_file():
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
            if state.get("schema") != RUN_STATE_SCHEMA:
                raise RuntimeError(
                    "arena_resume_state_schema_mismatch:"
                    f"expected={RUN_STATE_SCHEMA}:"
                    f"actual={state.get('schema', 'missing')}:"
                    "use_a_new_output_directory"
                )
            if state.get("fingerprint") != self.fingerprint:
                raise RuntimeError("arena_resume_fingerprint_mismatch")
            expected_matches = (
                state.get("task_ids_sha256") == canonical_hash(expected_ids)
                and state.get("task_count") == len(expected_ids)
            )
            if not expected_matches:
                raise RuntimeError("arena_resume_task_matrix_mismatch")
            self._state = state
            self._load_shards()
            return
        self._state = {
            "schema": RUN_STATE_SCHEMA,
            "fingerprint": self.fingerprint,
            "task_ids_sha256": canonical_hash(expected_ids),
            "task_count": len(expected_ids),
            "status": "running",
            "shards": [],
            "attempt_shards": [],
            "completed_count": 0,
            "completed_index_sha256": self._completed_digest.hexdigest(),
            "pending_retry_task_ids": [],
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
                if task_id not in self._task_id_set:
                    raise RuntimeError("arena_shard_unknown_task_id")
                GameEvidence.verify(self.protocol, self.tasks[task_id], game)
                self._games[task_id] = game
                self._completed_digest.update((task_id + "\n").encode("utf-8"))
        index_matches = (
            self._state.get("completed_count") == len(self._games)
            and self._state.get("completed_index_sha256") == self._completed_digest.hexdigest()
        )
        if not index_matches:
            raise RuntimeError("arena_resume_completed_index_mismatch")
        attempt_keys: set[tuple[str, int]] = set()
        for row in self._state.get("attempt_shards", []):
            relative = Path(str(row["path"]))
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not relative.parts
                or relative.parts[0] != "attempts"
            ):
                raise RuntimeError("arena_attempt_shard_path_invalid")
            path = self.root / relative
            payload = path.read_bytes()
            if _sha256_bytes(payload) != str(row["sha256"]):
                raise RuntimeError(f"arena_attempt_shard_sha256_mismatch:{path.name}")
            lines = payload.decode("utf-8").splitlines()
            if int(row.get("attempts", -1)) != len(lines):
                raise RuntimeError("arena_attempt_shard_count_mismatch")
            for line in lines:
                attempt = json.loads(line)
                task_id = str(attempt.get("task_id", ""))
                attempt_number = int(attempt.get("attempt_number", 0))
                if task_id not in self._task_id_set:
                    raise RuntimeError("arena_attempt_shard_unknown_task_id")
                if attempt_number not in (1, 2):
                    raise RuntimeError("arena_attempt_number_invalid")
                key = (task_id, attempt_number)
                if key in attempt_keys:
                    raise RuntimeError("arena_attempt_duplicate")
                attempt_keys.add(key)
                claimed_hash = str(attempt.get("attempt_hash", ""))
                unhashed = dict(attempt)
                unhashed.pop("attempt_hash", None)
                if claimed_hash != canonical_hash(unhashed):
                    raise RuntimeError("arena_attempt_hash_mismatch")
                GameEvidence.verify(self.protocol, self.tasks[task_id], attempt)
                self._attempts.append(attempt)
        pending = {
            str(value) for value in self._state.get("pending_retry_task_ids", [])
        }
        if pending - set(self.task_ids) or pending & set(self._games):
            raise RuntimeError("arena_resume_pending_retry_index_mismatch")
        attempted_tasks = {task_id for task_id, _ in attempt_keys}
        if (
            pending - attempted_tasks
            or attempted_tasks - (pending | set(self._games))
            or any(
                (task_id, 2) in attempt_keys
                and (task_id, 1) not in attempt_keys
                for task_id in attempted_tasks
            )
        ):
            raise RuntimeError("arena_resume_attempt_sequence_mismatch")

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
    def attempts(self) -> list[dict[str, Any]]:
        return list(self._attempts)

    @property
    def pending_retry_task_ids(self) -> set[str]:
        return {
            str(value) for value in self._state.get("pending_retry_task_ids", [])
        }

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
            if task_id not in self._task_id_set:
                raise RuntimeError("arena_shard_unknown_task_id")
            if task_id in self._games or task_id in batch_ids:
                raise RuntimeError("arena_shard_duplicate_task_id")
            GameEvidence.verify(self.protocol, self.tasks[task_id], game)
            batch_ids.add(task_id)
        if self._next_shard_index is None:
            self._next_shard_index = max((
                int(path.stem.split("-")[-1]) for path in self.shards_root.glob("shard-*.jsonl")
                if path.stem.split("-")[-1].isdigit()), default=0) + 1
        index = self._next_shard_index
        self._next_shard_index += 1
        relative = Path("shards") / f"shard-{index:06d}.jsonl"
        payload = _jsonl_bytes(rows)
        write_bytes_atomic(self.root / relative, payload)
        for game in rows:
            self._games[str(game["task_id"])] = game
            self._completed_digest.update((str(game["task_id"]) + "\n").encode("utf-8"))
        self._state["shards"].append({
            "path": relative.as_posix(),
            "sha256": _sha256_bytes(payload),
            "games": len(rows),
        })
        self._state.update(completed_count=len(self._games), completed_index_sha256=self._completed_digest.hexdigest())
        self._state["pending_retry_task_ids"] = sorted(
            self.pending_retry_task_ids - batch_ids
        )
        write_json_atomic(self.state_path, self._state)

    def append_attempts(self, attempts: Sequence[Mapping[str, Any]]) -> None:
        if not attempts:
            return
        normalized: list[dict[str, Any]] = []
        for value in attempts:
            row = dict(value)
            claimed_hash = str(row.pop("attempt_hash", ""))
            computed_hash = canonical_hash(row)
            if claimed_hash and claimed_hash != computed_hash:
                raise RuntimeError("arena_attempt_hash_mismatch")
            row["attempt_hash"] = computed_hash
            normalized.append(row)
        rows = sorted(
            normalized,
            key=lambda row: (
                str(row.get("task_id", "")),
                int(row.get("attempt_number", 0)),
            ),
        )
        pending = self.pending_retry_task_ids
        existing_keys = {
            (
                str(attempt.get("task_id", "")),
                int(attempt.get("attempt_number", 0)),
            )
            for attempt in self._attempts
        }
        batch_keys: set[tuple[str, int]] = set()
        for attempt in rows:
            task_id = str(attempt.get("task_id", ""))
            attempt_number = int(attempt.get("attempt_number", 0))
            if task_id not in self._task_id_set:
                raise RuntimeError("arena_attempt_shard_unknown_task_id")
            if task_id in self._games:
                raise RuntimeError("arena_attempt_for_completed_task")
            if attempt_number not in (1, 2):
                raise RuntimeError("arena_attempt_number_invalid")
            key = (task_id, attempt_number)
            if key in existing_keys or key in batch_keys:
                raise RuntimeError("arena_attempt_duplicate")
            if attempt_number == 2 and (task_id, 1) not in existing_keys:
                raise RuntimeError("arena_retry_primary_attempt_missing")
            GameEvidence.verify(self.protocol, self.tasks[task_id], attempt)
            batch_keys.add(key)
            pending.add(task_id)
        existing_indices = [
            int(path.stem.split("-")[-1])
            for path in (self.root / "attempts").glob("attempt-*.jsonl")
            if path.stem.split("-")[-1].isdigit()
        ]
        index = max(existing_indices, default=0) + 1
        relative = Path("attempts") / f"attempt-{index:06d}.jsonl"
        payload = _jsonl_bytes(rows)
        write_bytes_atomic(self.root / relative, payload)
        self._attempts.extend(rows)
        self._state["attempt_shards"].append({
            "path": relative.as_posix(),
            "sha256": _sha256_bytes(payload),
            "attempts": len(rows),
        })
        self._state["pending_retry_task_ids"] = sorted(pending)
        write_json_atomic(self.state_path, self._state)

    def add_elapsed_seconds(self, value: float) -> None:
        self._state["elapsed_seconds"] = (
            self.elapsed_seconds + max(0.0, float(value))
        )
        write_json_atomic(self.state_path, self._state)

    def mark_complete(self, gate_status: str) -> None:
        if self.pending_retry_task_ids:
            raise RuntimeError("arena_complete_with_pending_retries")
        self._state["status"] = "complete"
        self._state["gate_status"] = str(gate_status)
        self._state["remaining_task_count"] = len(self.task_ids) - len(self._games)
        write_json_atomic(self.state_path, self._state)

    def close(self) -> None:
        if self._locked:
            self.lock_path.unlink(missing_ok=True)
            self._locked = False

    def __enter__(self) -> "EvaluationRunStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def write_jsonl_atomic(path: Path, values: Iterable[Mapping[str, Any]]) -> None:
    write_bytes_atomic(path, _jsonl_bytes(values))


def cohort_for_output(output: Path) -> str:
    path = output / "evaluation-protocol.json"
    if path.is_file():
        return str(json.loads(path.read_text(encoding="utf-8"))["cohort"])
    return secrets.token_hex(16)


class EvaluationRoundCache:
    """Only trustworthy full rounds enter the cache; partial games stay in the run journal."""

    def __init__(self, root: Path | None):
        self.root = root
        self.hits = 0

    def _path(self, key: str) -> Path:
        assert self.root is not None
        return self.root / key[:2] / f"{key}.json"

    def read(self, protocol: EvaluationProtocol, comparison: str, replicate: int) -> list[dict[str, Any]] | None:
        if self.root is None:
            return None
        key = protocol.round_cache_key(comparison, replicate)
        path = self._path(key)
        if not path.is_file():
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
        checksum = payload.pop("sha256", None)
        if checksum != canonical_hash(payload) or payload.get("cache_key") != key:
            raise ValueError("evaluation_cache_checksum_mismatch")
        source_rows = payload["rows"]
        expected = protocol.tasks(comparison, replicate)
        if len(source_rows) != len(expected):
            raise ValueError("evaluation_cache_incomplete_round")
        conditions = {canonical_hash(row_task.conditions()): row_task for row_task in expected}
        seen = set()
        rows = []
        for source in source_rows:
            if source.get("evidence_hash") != canonical_hash(evidence_semantics(source)):
                raise ValueError("evaluation_cache_evidence_hash_mismatch")
            condition = {name: source.get(name) for name in expected[0].conditions()}
            task = conditions.get(canonical_hash(condition))
            if task is None or task.task_id in seen or not source.get("strength_eligible"):
                raise ValueError("evaluation_cache_conditions_mismatch")
            seen.add(task.task_id)
            rebound = {**source, **task.to_dict(), "cached": True,
                       "cache_source_protocol": source["protocol_fingerprint"]}
            rows.append(GameEvidence.from_result(protocol, task, rebound).row)
        self.hits += len(rows)
        return rows

    def write(self, protocol: EvaluationProtocol, comparison: str, replicate: int,
              rows: Sequence[Mapping[str, Any]]) -> None:
        if self.root is None or len(rows) != protocol.games_per_round:
            return
        tasks = {task.task_id: task for task in protocol.tasks(comparison, replicate)}
        if set(tasks) != {row["task_id"] for row in rows} or len(tasks) != len(rows):
            raise ValueError("evaluation_cache_incomplete_round")
        checked = [GameEvidence.verify(protocol, tasks[row["task_id"]], row).row for row in rows]
        if any(not row["strength_eligible"] for row in checked):
            return
        key = protocol.round_cache_key(comparison, replicate)
        path = self._path(key)
        payload = {"cache_key": key, "rows": sorted(checked, key=lambda row: row["task_id"])}
        payload["sha256"] = canonical_hash(payload)
        # Equivalent races can differ in latency metadata. Neither can change
        # cached semantic outcomes; files are always atomically published.
        if path.exists():
            previous = self.read(protocol, comparison, replicate)
            old = {canonical_hash({k: r[k] for k in ("candidate_deck", "baseline_deck", "game_seed", "candidate_seat", "first_player")}):
                   (r["winner_seat"], r["final_state_hash"]) for r in previous or []}
            new = {canonical_hash({k: r[k] for k in ("candidate_deck", "baseline_deck", "game_seed", "candidate_seat", "first_player")}):
                   (r["winner_seat"], r["final_state_hash"]) for r in checked}
            if old != new:
                raise ValueError("evaluation_cache_nondeterministic_result")
            self.hits -= len(previous or [])
            return
        write_json_atomic(path, payload)

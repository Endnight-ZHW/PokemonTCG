"""Cross-platform atomic task/result exchange for future remote v3 workers."""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable

from .v3_contract import RUN_FORMAT_VERSION, contract_dict


TASK_SCHEMA = "ptcg_deep_worker_task_v3"
RESULT_SCHEMA = "ptcg_deep_worker_result_v3"
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sealed(payload: dict[str, Any]) -> dict[str, Any]:
    body = dict(payload)
    body.pop("manifest_sha256", None)
    body["manifest_sha256"] = hashlib.sha256(_canonical(body)).hexdigest()
    return body


def _verify(payload: dict[str, Any]) -> None:
    expected = str(payload.get("manifest_sha256", ""))
    body = dict(payload)
    body.pop("manifest_sha256", None)
    if hashlib.sha256(_canonical(body)).hexdigest() != expected:
        raise ValueError("v3_worker_manifest_hash_mismatch")


def _publish_once(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    wire = _canonical(_sealed(payload)) + b"\n"
    descriptor, name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(wire)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            # Hard-link publication is atomic and never overwrites an existing
            # result on either Windows or Linux when source/destination share
            # the exchange filesystem.
            os.link(temporary, path)
        except FileExistsError:
            if path.read_bytes() != wire:
                raise ValueError(f"v3_worker_manifest_conflict:{path.name}")
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def _identifier(value: str, field: str) -> str:
    text = str(value)
    if not IDENTIFIER.fullmatch(text) or text in {".", ".."}:
        raise ValueError(f"invalid_v3_worker_{field}:{text}")
    return text


class AtomicWorkerExchangeV3:
    """Append-only manifests; claiming uses one same-volume atomic rename."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root).resolve()
        self.pending = self.root / "pending"
        self.claimed = self.root / "claimed"
        self.results = self.root / "results"
        for path in (self.pending, self.claimed, self.results):
            path.mkdir(parents=True, exist_ok=True)

    def publish_task(
        self,
        task_id: str,
        *,
        run_id: str,
        games: Iterable[dict[str, Any]],
    ) -> Path:
        task = _identifier(task_id, "task_id")
        rows = [dict(row) for row in games]
        if not rows:
            raise ValueError("v3_worker_task_games_empty")
        payload = {
            "schema": TASK_SCHEMA,
            "run_format": RUN_FORMAT_VERSION,
            "task_id": task,
            "run_id": _identifier(run_id, "run_id"),
            "created_ns": time.time_ns(),
            "contract": contract_dict(),
            "games": rows,
        }
        path = self.pending / f"{task}.json"
        _publish_once(path, payload)
        return path

    def claim(self, worker_id: str) -> tuple[Path, dict[str, Any]] | None:
        worker = _identifier(worker_id, "worker_id")
        for source in sorted(self.pending.glob("*.json")):
            task = _identifier(source.stem, "task_id")
            target = self.claimed / f"{task}--{worker}.json"
            try:
                os.replace(source, target)
            except FileNotFoundError:
                continue
            payload = json.loads(target.read_text(encoding="utf-8"))
            _verify(payload)
            if (
                payload.get("schema") != TASK_SCHEMA
                or int(payload.get("run_format", 0)) != RUN_FORMAT_VERSION
                or payload.get("contract") != contract_dict()
            ):
                raise ValueError("incompatible_v3_worker_task")
            return target, payload
        return None

    def publish_result(
        self,
        claim_path: str | Path,
        *,
        worker_id: str,
        games: Iterable[dict[str, Any]],
        replay_shards: Iterable[dict[str, Any]] = (),
    ) -> Path:
        claim = Path(claim_path).resolve()
        if claim.parent != self.claimed or not claim.is_file():
            raise ValueError("v3_worker_claim_outside_exchange")
        task = json.loads(claim.read_text(encoding="utf-8"))
        _verify(task)
        worker = _identifier(worker_id, "worker_id")
        if not claim.stem.endswith("--" + worker):
            raise ValueError("v3_worker_claim_owner_mismatch")
        payload = {
            "schema": RESULT_SCHEMA,
            "run_format": RUN_FORMAT_VERSION,
            "task_id": str(task["task_id"]),
            "run_id": str(task["run_id"]),
            "worker_id": worker,
            "task_manifest_sha256": str(task["manifest_sha256"]),
            "completed_ns": time.time_ns(),
            "games": [dict(row) for row in games],
            "replay_shards": [dict(row) for row in replay_shards],
        }
        target = self.results / f"{task['task_id']}.json"
        _publish_once(target, payload)
        return target

    def read_results(self) -> list[dict[str, Any]]:
        rows = []
        for path in sorted(self.results.glob("*.json")):
            payload = json.loads(path.read_text(encoding="utf-8"))
            _verify(payload)
            if payload.get("schema") != RESULT_SCHEMA:
                raise ValueError("invalid_v3_worker_result_schema")
            rows.append(payload)
        return rows

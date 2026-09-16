"""One evaluation state machine for native Challenge and learned-model runners."""
from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol, Sequence

from .challenge_arena_build import write_json_atomic, sha256_file
from .evaluation_store import write_jsonl_atomic
from .evaluation_protocol import EvaluationProtocol, EvaluationTask, GameEvidence
from .evaluation_statistics import EvaluationAccumulator
from .evaluation_store import EvaluationRunStore, EvaluationRoundCache


class EvaluationBackend(Protocol):
    def run(self, tasks: Sequence[EvaluationTask], *,
            on_games: Callable[[list[dict[str, Any]]], None], isolated: bool = False) -> None: ...
    def close(self) -> None: ...
    def performance(self) -> dict[str, Any]: ...


@dataclass(frozen=True)
class EvaluationReport:
    summary: dict[str, Any]
    games: list[dict[str, Any]]
    output: Path


def evaluate(protocol: EvaluationProtocol, backend: EvaluationBackend, *, output: Path,
             cache_root: Path | None = None,
             on_report: Callable[[dict[str, Any]], None] | None = None) -> EvaluationReport:
    cache = EvaluationRoundCache(cache_root)
    accumulator = EvaluationAccumulator(protocol)
    started = time.perf_counter()
    runtime_errors: list[str] = []
    backend_closed = False

    def close_backend() -> None:
        nonlocal backend_closed
        if backend_closed:
            return
        backend_closed = True
        try:
            backend.close()
        except Exception as error:
            runtime_errors.append(f"backend_close:{type(error).__name__}:{error}")
    try:
        with EvaluationRunStore(output, protocol) as store:
            for row in store.games:
                accumulator.add(GameEvidence(row))

            def persist(rows: Sequence[Mapping[str, Any]]) -> None:
                store.append(rows)
                for row in rows:
                    accumulator.add(GameEvidence(dict(row)))

            def accept(raw: list[dict[str, Any]], *, retry: bool = False) -> None:
                final = []
                attempts = []
                for result in raw:
                    identifier = str(result.get("task_id", ""))
                    task = store.tasks.get(identifier)
                    if task is None:
                        raise ValueError("evaluation_unknown_backend_result")
                    row = GameEvidence.from_result(protocol, task, result).row
                    if retry or row["failure_kind"] == "timeout":
                        attempts.append({**row, "attempt_number": 2 if retry else 1})
                    if retry or row["failure_kind"] != "timeout":
                        final.append({**row, "attempt_count": 2 if retry else 1,
                                      "persistent_timeout": row["failure_kind"] == "timeout",
                                      "recovered_timeout": retry and row["strength_eligible"]})
                # A crash after recording a retry but before its final shard is
                # repaired below; the successful retry is never played twice.
                store.append_attempts(attempts)
                persist(final)

            def retries() -> None:
                recorded = {row["task_id"]: row for row in store.attempts if row["attempt_number"] == 2}
                for identifier in sorted(store.pending_retry_task_ids):
                    if identifier in recorded:
                        row = dict(recorded[identifier])
                        row.pop("attempt_hash", None)
                        row.pop("attempt_number", None)
                        row.update(attempt_count=2, persistent_timeout=row["failure_kind"] == "timeout",
                                   recovered_timeout=row["strength_eligible"])
                        persist([row])
                pending = [store.tasks[key] for key in sorted(store.pending_retry_task_ids)]
                # One game at a time, fresh models/processes for both sides.
                for task in pending:
                    backend.run([task], on_games=lambda rows: accept(rows, retry=True), isolated=True)
                    if task.task_id in store.pending_retry_task_ids:
                        raise RuntimeError("evaluation_retry_result_missing")

            def execute_round(comparison: str, replicate: int) -> None:
                tasks = protocol.tasks(comparison, replicate)
                done = store.completed_task_ids
                pending = [task for task in tasks if task.task_id not in done]
                if not pending:
                    return
                cached = cache.read(protocol, comparison, replicate)
                if cached is not None:
                    persist([row for row in cached if row["task_id"] not in done])
                else:
                    backend.run(pending, on_games=accept)
                    retries()
                done = store.completed_task_ids
                if any(task.task_id not in done for task in tasks):
                    raise RuntimeError("evaluation_backend_result_missing")
                round_rows = [accumulator.rows[task.task_id] for task in tasks]
                cache.write(protocol, comparison, replicate, round_rows)

            def run_round(comparison: str, replicate: int) -> None:
                from .run_control_v3 import TrainingCancelled
                try:
                    execute_round(comparison, replicate)
                except (InterruptedError, TrainingCancelled):
                    raise
                except Exception as error:
                    runtime_errors.append(f"{type(error).__name__}:{error}")

            def publish(*, final: bool = False) -> dict[str, Any]:
                report = accumulator.report(final=final)
                if runtime_errors:
                    report.update(gate_status="infrastructure_fail", promotion_passed=False,
                                  stop_reasons=["infrastructure_error"])
                    report["strength"]["status"] = "not_evaluated"
                    report["reliability"].update(passed=False, runtime_errors=list(runtime_errors))
                report["performance_advisory"] = {
                    **backend.performance(), "gating": False, "cached_games": cache.hits,
                    "elapsed_seconds": store.elapsed_seconds + time.perf_counter() - started,
                }
                if final and hasattr(backend, "final_performance"):
                    report["performance_advisory"].update(backend.final_performance())
                report["reliability"].update(
                    recovered_timeout_games=sum(bool(r.get("recovered_timeout")) for r in accumulator.rows.values()),
                    persistent_timeout_games=sum(bool(r.get("persistent_timeout")) for r in accumulator.rows.values()),
                )
                report["evidence"] = {"protocol_fingerprint": protocol.fingerprint,
                                      "finalized": False,
                                      "candidate_content_hash": protocol.participants["candidate"]["content_hash"],
                                      "games_path": str((output / "arena-games.jsonl").resolve()),
                                      "protocol_path": str((output / "evaluation-protocol.json").resolve())}
                write_json_atomic(output / "arena-summary.json", report)
                if on_report is not None:
                    on_report(report)
                return report

            retries()
            report = publish()
            # Primary evidence is cheap relative to running all three edges.
            # All tasks were nevertheless declared before observing any result.
            if report["gate_status"] not in {"fail", "infrastructure_fail"}:
                for rep in range(protocol.maximum_replicates):
                    if protocol.mode == "promotion" and accumulator.primary.rounds >= protocol.minimum_replicates and accumulator.primary.lower > 0.5:
                        break
                    if protocol.mode != "promotion" and report["gate_status"] == "pass":
                        break
                    run_round("ac", rep)
                    report = publish()
                    if report["gate_status"] in {"fail", "infrastructure_fail"}:
                        break
                paired_screen = protocol.mode == "screen" and protocol.context.get("paired_anchor_screen", False)
                if ((protocol.mode == "promotion" and report["strength"]["status"] == "improved") or paired_screen) and not accumulator.faults:
                    for rep in range(protocol.maximum_replicates):
                        run_round("ah", rep)
                        if accumulator.faults or runtime_errors:
                            break
                        run_round("ch", rep)
                        report = publish()
                        if report["gate_status"] in {"pass", "fail", "infrastructure_fail"}:
                            break
            # Shutdown errors are reliability evidence too. Resolve them before
            # sealing a report that could authorize a champion replacement.
            close_backend()
            report = publish(final=True)
            games = store.games
            write_jsonl_atomic(output / "arena-games.jsonl", games)
            write_jsonl_atomic(output / "arena-attempts.jsonl", store.attempts)
            write_jsonl_atomic(output / "arena-failures.jsonl", accumulator.faults)
            report["evidence"].update(finalized=True, games_sha256=sha256_file(output / "arena-games.jsonl"))
            write_json_atomic(output / "arena-summary.json", report)
            write_json_atomic(output / "arena-manifest.json", {
                "schema": "ptcg.ai_evaluation.manifest/1", "protocol": protocol.to_dict(),
                "fingerprint": protocol.fingerprint, "gate_status": report["gate_status"],
                "backend": backend.performance(),
                "games_sha256": report["evidence"]["games_sha256"],
                "summary_sha256": sha256_file(output / "arena-summary.json"),
            })
            store.add_elapsed_seconds(time.perf_counter() - started)
            if not store.pending_retry_task_ids:
                store.mark_complete(report["gate_status"])
            return EvaluationReport(report, games, output)
    finally:
        close_backend()


def arena_promotion_passed(
    arena: dict[str, Any],
    *,
    candidate_content_hash: str | None = None,
) -> bool:
    """Accept only sealed evidence for these exact candidate weights."""
    from .evaluation_protocol import REPORT_SCHEMA
    evidence = arena.get("evidence", {})
    return bool(
        arena.get("schema") == REPORT_SCHEMA
        and arena.get("mode") == "promotion"
        and arena.get("gate_status") == "pass"
        and arena.get("promotion_passed") is True
        and arena.get("reliability", {}).get("passed") is True
        and candidate_content_hash
        and evidence.get("finalized") is True
        and len(str(evidence.get("games_sha256", ""))) == 64
        and evidence.get("candidate_content_hash") == candidate_content_hash
        and evidence.get("protocol_fingerprint") == arena.get("protocol_fingerprint")
        and arena.get("protocol_fingerprint")
    )

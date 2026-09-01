"""Crash-safe, strength-neutral timeout retry journaling for Challenge Arena."""
from __future__ import annotations

from typing import Any, Mapping, Sequence

from .challenge_arena_store import ChallengeArenaRunStore
from .evaluation_fairness import canonical_hash


def is_retryable_timeout(game: Mapping[str, Any]) -> bool:
    return (
        str(game.get("failure_kind", "")) == "decision_timeout"
        or "external_agent_timeout" in str(game.get("error", ""))
    )


def attempt_row(game: Mapping[str, Any], attempt_number: int) -> dict[str, Any]:
    result = dict(game)
    result["attempt_number"] = int(attempt_number)
    result["retryable_timeout"] = is_retryable_timeout(result)
    result["attempt_hash"] = canonical_hash(result)
    return result


def final_retry_result(
    game: Mapping[str, Any],
    *,
    primary_attempt: Mapping[str, Any],
) -> dict[str, Any]:
    result = dict(game)
    for key in ("attempt_number", "attempt_hash", "retryable_timeout"):
        result.pop(key, None)
    result["attempt_count"] = 2
    result["primary_timeout_error"] = str(primary_attempt.get(
        "error", "external_agent_timeout"
    ))
    if is_retryable_timeout(result):
        result.update({
            "success": False,
            "terminal": False,
            "strength_eligible": False,
            "winner_seat": -1,
            "winner_agent": -1,
            "candidate_score_x2": 1,
            "failure_kind": "persistent_timeout",
            "persistent_timeout": True,
            "recovered_timeout": False,
        })
    else:
        result["persistent_timeout"] = False
        result["recovered_timeout"] = bool(result.get("success", False))
    result["full_result_hash"] = canonical_hash(result)
    return result


class TimeoutRetryJournal:
    def __init__(
        self,
        store: ChallengeArenaRunStore,
        tasks_by_id: Mapping[str, Any],
    ) -> None:
        self.store = store
        self.tasks_by_id = dict(tasks_by_id)

    def attempts_for(self, task_id: str) -> list[dict[str, Any]]:
        return sorted(
            (
                row for row in self.store.attempts
                if str(row.get("task_id", "")) == task_id
            ),
            key=lambda row: int(row.get("attempt_number", 0)),
        )

    def primary_attempt(self, task_id: str) -> dict[str, Any]:
        primary = next(
            (
                row for row in self.attempts_for(task_id)
                if int(row.get("attempt_number", 0)) == 1
            ),
            None,
        )
        if primary is None:
            raise RuntimeError(f"arena_retry_primary_attempt_missing:{task_id}")
        return primary

    def persist_primary(self, games: Sequence[Mapping[str, Any]]) -> None:
        retryable: list[dict[str, Any]] = []
        final: list[dict[str, Any]] = []
        for game in games:
            if is_retryable_timeout(game):
                retryable.append(attempt_row(game, 1))
            else:
                row = dict(game)
                row["attempt_count"] = 1
                row["persistent_timeout"] = False
                row["recovered_timeout"] = False
                row["full_result_hash"] = canonical_hash(row)
                final.append(row)
        self.store.append_attempts(retryable)
        self.store.append(final)

    def finalize_recorded_retries(self) -> None:
        final: list[dict[str, Any]] = []
        for task_id in sorted(self.store.pending_retry_task_ids):
            retry = next(
                (
                    row for row in reversed(self.attempts_for(task_id))
                    if int(row.get("attempt_number", 0)) == 2
                ),
                None,
            )
            if retry is None:
                continue
            final.append(final_retry_result(
                retry,
                primary_attempt=self.primary_attempt(task_id),
            ))
        self.store.append(final)

    def pending_tasks(self) -> list[Any]:
        unknown = self.store.pending_retry_task_ids - set(self.tasks_by_id)
        if unknown:
            raise RuntimeError(f"arena_retry_unknown_task:{sorted(unknown)[0]}")
        return [
            self.tasks_by_id[task_id]
            for task_id in sorted(self.store.pending_retry_task_ids)
        ]

    def persist_retry(self, games: Sequence[Mapping[str, Any]]) -> None:
        recorded = [attempt_row(game, 2) for game in games]
        self.store.append_attempts(recorded)
        self.store.append([
            final_retry_result(
                game,
                primary_attempt=self.primary_attempt(
                    str(game.get("task_id", ""))
                ),
            )
            for game in games
        ])

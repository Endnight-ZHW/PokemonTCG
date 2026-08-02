"""Shared AlphaZero v2 task-integrity event policy.

Arena games that reach the fixed decision cap without any illegal action,
rule failure, timeout, or privacy violation reject that candidate through the
arena result.  They are not native-kernel integrity failures and therefore do
not make the whole training run non-resumable.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


INTEGRITY_COUNTER_FIELDS = (
    "invalid_actions",
    "illegal_choices",
    "rule_exceptions",
    "decision_timeouts",
    "hidden_information_violations",
)


def is_recoverable_arena_truncation_event(row: Mapping[str, Any]) -> bool:
    """Return whether *row* is an arena-only decision-cap truncation.

    The predicate intentionally fails closed: missing or malformed counters,
    diagnostics, a different phase, or any serious integrity counter make the
    event fatal.
    """

    if row.get("event") not in {
        "task_integrity_failure",
        "arena_task_truncated",
    }:
        return False
    if row.get("phase") != "arena" or row.get("truncated") is not True:
        return False
    for field in INTEGRITY_COUNTER_FIELDS:
        value = row.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value != 0:
            return False
    details = row.get("error_details")
    if not isinstance(details, (list, tuple)) or details:
        return False
    return True


def is_retriable_self_play_truncation_event(
    row: Mapping[str, Any],
    *,
    exhausted_attempts: int,
) -> bool:
    """Validate one exact self-play cap exhaustion before scheduling retries.

    This does not classify the game as successful: the old failure may only be
    bypassed after an explicit audit event raises the retry budget, and the
    replacement game must still reach a real terminal state.
    """
    if (
        row.get("event") != "task_integrity_failure"
        or row.get("phase") != "self_play"
        or row.get("truncated") is not True
        or isinstance(exhausted_attempts, bool)
        or not isinstance(exhausted_attempts, int)
        or exhausted_attempts <= 0
    ):
        return False
    for field in INTEGRITY_COUNTER_FIELDS:
        value = row.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value != 0:
            return False
    if row.get("error_details") != [
        f"self_play_truncation_reseed_attempts_exhausted:{exhausted_attempts}"
    ]:
        return False
    retries = row.get("truncation_retries")
    decisions = row.get("decisions")
    simulations = row.get("simulations")
    return (
        isinstance(retries, int)
        and not isinstance(retries, bool)
        and retries == exhausted_attempts - 1
        and isinstance(decisions, int)
        and not isinstance(decisions, bool)
        and decisions > 0
        and isinstance(simulations, int)
        and not isinstance(simulations, bool)
        and simulations > 0
    )


__all__ = [
    "INTEGRITY_COUNTER_FIELDS",
    "is_recoverable_arena_truncation_event",
    "is_retriable_self_play_truncation_event",
]

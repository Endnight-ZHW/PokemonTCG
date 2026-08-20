"""Python orchestration helpers for the authoritative C++ rules session.

This module deliberately contains no rule execution. It validates DTOs and
drives the same ``NativeRulesSession`` object used by Godot.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Mapping


class NativeRulesUnavailable(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class JournalReplayResult:
    success: bool
    mismatch_index: int = -1
    error_code: str = ""
    expected: Mapping[str, Any] | None = None
    actual: Mapping[str, Any] | None = None


def create_rules_session(
    catalog: Mapping[str, Any],
    decks: Iterable[Iterable[str]],
    match_config: Mapping[str, Any],
    seed: int,
):
    try:
        import ptcg_ai_core
    except ImportError as error:  # pragma: no cover - native build gate
        raise NativeRulesUnavailable("ptcg_ai_core is unavailable") from error
    if int(ptcg_ai_core.abi_version()) != 2:
        raise NativeRulesUnavailable("native_rules_abi_mismatch")
    session = ptcg_ai_core.NativeRulesSession()
    result = session.create(
        dict(catalog),
        [list(deck) for deck in decks],
        dict(match_config),
        int(seed),
    )
    if not result.get("success"):
        raise ValueError(str(result.get("error_code", "native_create_failed")))
    return session


def replay_match_journal(
    journal: Mapping[str, Any],
    *,
    catalog: Mapping[str, Any],
    decks: Iterable[Iterable[str]],
) -> JournalReplayResult:
    """Replay MatchJournal v1 and stop at the first deterministic divergence."""
    if str(journal.get("schema", "")) != "ptcg_match_journal/1":
        return JournalReplayResult(False, error_code="journal_schema_mismatch")
    if int(journal.get("format_version", 0)) != 1:
        return JournalReplayResult(False, error_code="journal_version_mismatch")
    if int(journal.get("native_abi_version", 0)) != 2:
        return JournalReplayResult(False, error_code="journal_abi_mismatch")
    if str(journal.get("hash_algorithm", "")) != "fnv1a64-canonical-json":
        return JournalReplayResult(False, error_code="journal_hash_mismatch")
    entries = list(journal.get("entries") or [])
    if not entries or str(entries[0].get("kind", "")) != "create":
        return JournalReplayResult(False, error_code="journal_create_missing")
    try:
        session = create_rules_session(
            catalog,
            decks,
            dict(journal.get("match_config") or {}),
            int(journal.get("initial_seed", 0)),
        )
    except (NativeRulesUnavailable, TypeError, ValueError) as error:
        return JournalReplayResult(False, error_code=str(error))

    actual_journal = session.journal()
    for field in (
        "catalog_fingerprint",
        "content_fingerprint",
        "contract_fingerprint",
        "vm_descriptor_digest",
    ):
        if journal.get(field) != actual_journal.get(field):
            return JournalReplayResult(
                False,
                0,
                f"journal_{field}_mismatch",
                journal,
                actual_journal,
            )
    actual_entries = list(actual_journal.get("entries") or [])
    mismatch = _entry_mismatch(entries[0], actual_entries[0])
    if mismatch:
        return JournalReplayResult(
            False, 0, mismatch, entries[0], actual_entries[0]
        )

    for index, expected in enumerate(entries[1:], start=1):
        kind = str(expected.get("kind", ""))
        payload = expected.get("input")
        if not isinstance(payload, dict):
            return JournalReplayResult(
                False, index, "journal_input_invalid", expected, None
            )
        if kind == "action":
            step = session.apply_action(payload)
        elif kind == "choice":
            step = session.apply_choice(payload)
        elif kind == "command" and payload.get("command") == "surrender":
            step = session.surrender(int(payload.get("actor", -1)))
        else:
            return JournalReplayResult(
                False, index, "journal_kind_unsupported", expected, None
            )
        if not step.get("success"):
            return JournalReplayResult(
                False,
                index,
                str(step.get("error_code", "journal_replay_step_failed")),
                expected,
                step,
            )
        actual = session.journal()["entries"][-1]
        mismatch = _entry_mismatch(expected, actual)
        if mismatch:
            return JournalReplayResult(False, index, mismatch, expected, actual)
    return JournalReplayResult(True)


def _entry_mismatch(expected: Mapping[str, Any], actual: Mapping[str, Any]) -> str:
    for field in (
        "index",
        "kind",
        "revision_before",
        "revision_after",
        "input",
        "state_hash",
        "event_hash",
        "rng_state",
    ):
        if expected.get(field) != actual.get(field):
            return f"journal_{field}_mismatch"
    return ""


__all__ = [
    "NativeRulesUnavailable",
    "JournalReplayResult",
    "create_rules_session",
    "replay_match_journal",
]

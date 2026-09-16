"""Shared fairness schedule and paired statistics for AI evaluation arenas."""
from __future__ import annotations

import hashlib
import json
import math
from collections import defaultdict
from typing import Any, Callable, Iterable, Mapping, Sequence


SEAT_FIRST_PLAYER_CLOSURES = ((0, 0), (1, 0), (0, 1), (1, 1))


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def rules_content_hash(catalog: Mapping[str, Any]) -> str:
    # The bundle fingerprint also covers AI strategies. Preserve every rule,
    # card and IR field while separating that provenance from rule identity.
    normalized = dict(catalog)
    if isinstance(catalog.get("card_ir"), Mapping):
        normalized["card_ir"] = {key: value for key, value in catalog["card_ir"].items()
                                 if key != "content_fingerprint"}
    return canonical_hash(normalized)


def _score(game: Mapping[str, Any]) -> float:
    return float(int(game["candidate_score_x2"])) / 2.0


def percentile(values: Sequence[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * max(0.0, min(1.0, quantile))
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def record(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    wins = sum(int(row["candidate_score_x2"]) == 2 for row in rows)
    draws = sum(int(row["candidate_score_x2"]) == 1 for row in rows)
    losses = sum(int(row["candidate_score_x2"]) == 0 for row in rows)
    score_rate = sum(_score(row) for row in rows) / len(rows) if rows else None
    return {
        "games": len(rows),
        "wins": wins,
        "draws": draws,
        "losses": losses,
        "score_rate": score_rate,
        "score_delta": None if score_rate is None else score_rate - 0.5,
        "average_turns": (
            sum(int(row.get("turns", 0)) for row in rows) / len(rows)
            if rows
            else 0.0
        ),
    }


def group_records(
    rows: Sequence[Mapping[str, Any]],
    key: Callable[[Mapping[str, Any]], str],
) -> dict[str, dict[str, Any]]:
    grouped: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(key(row))].append(row)
    return {group: record(grouped[group]) for group in sorted(grouped)}


def standard_breakdowns(
    rows: Sequence[Mapping[str, Any]],
) -> dict[str, dict[str, dict[str, Any]]]:
    return {
        "candidate_deck": group_records(
            rows, lambda row: str(row.get("candidate_deck", ""))
        ),
        "baseline_deck": group_records(
            rows, lambda row: str(row.get("baseline_deck", ""))
        ),
        "matchup": group_records(
            rows,
            lambda row: (
                f"{row.get('candidate_deck', '')}__vs__"
                f"{row.get('baseline_deck', '')}"
            ),
        ),
        "candidate_turn_order": group_records(
            rows,
            lambda row: (
                "first"
                if int(row.get("candidate_seat", 0))
                == int(row.get("first_player", 0))
                else "second"
            ),
        ),
        "candidate_seat": group_records(
            rows, lambda row: str(int(row.get("candidate_seat", 0)))
        ),
    }


def ordered_matchups(
    unordered: Iterable[tuple[str, str]],
) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    for left, right in unordered:
        result.append((str(left), str(right)))
        if str(left) != str(right):
            result.append((str(right), str(left)))
    return result


def unordered_matchups(decks: Sequence[str]) -> list[tuple[str, str]]:
    values = tuple(str(deck) for deck in decks)
    return [
        (left, right)
        for left_index, left in enumerate(values)
        for right in values[left_index:]
    ]

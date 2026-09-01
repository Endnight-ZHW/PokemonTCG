"""Shared fairness schedule and paired statistics for AI evaluation arenas."""
from __future__ import annotations

import hashlib
import json
import math
import random
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


def canonical_pair(left: str, right: str) -> tuple[str, str]:
    ordered = sorted((str(left), str(right)))
    return ordered[0], ordered[1]


def paired_seed(
    base_seed: int,
    left: str,
    right: str,
    replicate: int,
    *,
    namespace: str,
) -> int:
    pair = canonical_pair(left, right)
    material = "\0".join((
        str(namespace),
        str(int(base_seed) & 0xFFFFFFFF),
        pair[0],
        pair[1],
        str(int(replicate)),
    )).encode("utf-8")
    return int.from_bytes(hashlib.sha256(material).digest()[:4], "big") or 17


def block_kind(left: str, right: str) -> str:
    return "mirror" if str(left) == str(right) else "cross_deck"


def block_id(
    left: str,
    right: str,
    seed: int,
    replicate: int,
    *,
    prefix: str = "",
) -> str:
    pair = canonical_pair(left, right)
    stem = f"{pair[0]}__{pair[1]}:seed-{int(seed)}:rep-{int(replicate)}"
    return f"{prefix}:{stem}" if prefix else stem


def expected_block_size(left: str, right: str) -> int:
    return 4 if str(left) == str(right) else 8


def _score(game: Mapping[str, Any]) -> float:
    return float(int(game.get("candidate_score_x2", 1))) / 2.0


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
    wins = sum(int(row.get("candidate_score_x2", 1)) == 2 for row in rows)
    draws = sum(int(row.get("candidate_score_x2", 1)) == 1 for row in rows)
    losses = sum(int(row.get("candidate_score_x2", 1)) == 0 for row in rows)
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


def complete_strength_blocks(
    games: Sequence[Mapping[str, Any]],
) -> tuple[list[Mapping[str, Any]], dict[str, Any]]:
    """Keep only complete blocks whose every scheduled row is strength eligible."""
    blocks: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for index, row in enumerate(games):
        fallback = "|".join((
            *canonical_pair(
                str(row.get("candidate_deck", "")),
                str(row.get("baseline_deck", "")),
            ),
            str(int(row.get("game_seed", row.get("seed", 0)))),
            str(int(row.get("replicate", 0))),
        ))
        blocks[str(row.get("block_id") or fallback or f"row-{index}")].append(row)

    included: list[Mapping[str, Any]] = []
    excluded: list[dict[str, Any]] = []
    included_blocks = 0
    for identifier in sorted(blocks):
        rows = blocks[identifier]
        declared_sizes = {
            int(row.get("block_size", 0))
            for row in rows
            if int(row.get("block_size", 0)) > 0
        }
        expected = (
            next(iter(declared_sizes))
            if len(declared_sizes) == 1
            else expected_block_size(
                str(rows[0].get("candidate_deck", "")),
                str(rows[0].get("baseline_deck", "")),
            )
        )
        task_ids = [str(row.get("task_id", row.get("game_id", ""))) for row in rows]
        reasons: list[str] = []
        if len(declared_sizes) > 1:
            reasons.append("inconsistent_block_size")
        if len(rows) != expected:
            reasons.append("incomplete_block")
        if len(task_ids) != len(set(task_ids)):
            reasons.append("duplicate_task")
        if any(not bool(row.get("strength_eligible", True)) for row in rows):
            reasons.append("ineligible_game")
        if reasons:
            excluded.append({
                "block_id": identifier,
                "block_kind": str(rows[0].get(
                    "block_kind",
                    block_kind(
                        str(rows[0].get("candidate_deck", "")),
                        str(rows[0].get("baseline_deck", "")),
                    ),
                )),
                "expected_games": expected,
                "observed_games": len(rows),
                "reasons": sorted(set(reasons)),
                "task_ids": sorted(task_ids),
            })
            continue
        included_blocks += 1
        included.extend(rows)

    excluded_games = sum(int(row["observed_games"]) for row in excluded)
    missing_games = sum(
        max(0, int(row["expected_games"]) - int(row["observed_games"]))
        for row in excluded
    )
    return included, {
        "included_blocks": included_blocks,
        "included_games": len(included),
        "excluded_blocks": len(excluded),
        "excluded_games": excluded_games,
        "missing_games": missing_games,
        "excluded_scheduled_games": excluded_games + missing_games,
        "excluded": excluded,
    }


def paired_block_bootstrap_interval(
    games: Sequence[Mapping[str, Any]],
    *,
    seed: int,
    samples: int,
    alpha: float,
) -> dict[str, Any]:
    """Bootstrap complete closure blocks while preserving mirror/cross mix."""
    rows, block_selection = complete_strength_blocks(games)
    blocks: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for row in rows:
        blocks[str(row["block_id"])].append(row)

    strata: dict[str, list[tuple[float, int]]] = defaultdict(list)
    for identifier in sorted(blocks):
        values = blocks[identifier]
        kind = str(values[0].get(
            "block_kind",
            block_kind(
                str(values[0].get("candidate_deck", "")),
                str(values[0].get("baseline_deck", "")),
            ),
        ))
        strata[kind].append((sum(_score(row) for row in values), len(values)))

    bounded_alpha = max(1e-6, min(0.5, float(alpha)))
    flattened = [value for values in strata.values() for value in values]
    base = {
        "method": "stratified_paired_block_bootstrap",
        "seed": int(seed),
        "samples": max(1, int(samples)),
        "alpha": bounded_alpha,
        "confidence_level": 1.0 - bounded_alpha,
        "blocks": len(flattened),
        "block_strata": {
            kind: len(values) for kind, values in sorted(strata.items())
        },
        "block_selection": block_selection,
    }
    if not flattened:
        return {
            **base,
            "score_rate": None,
            "score_delta": None,
            "score_rate_ci": [None, None],
            "score_delta_ci": [None, None],
        }

    point = sum(total for total, _ in flattened) / sum(
        count for _, count in flattened
    )
    draws: list[float] = []
    rng = random.Random(int(seed))
    for _ in range(base["samples"]):
        sampled: list[tuple[float, int]] = []
        for kind in sorted(strata):
            values = strata[kind]
            sampled.extend(rng.choice(values) for _ in values)
        draws.append(
            sum(total for total, _ in sampled)
            / sum(count for _, count in sampled)
        )
    lower = percentile(draws, bounded_alpha / 2.0)
    upper = percentile(draws, 1.0 - bounded_alpha / 2.0)
    mean = sum(draws) / len(draws)
    variance = sum((value - mean) ** 2 for value in draws) / len(draws)
    return {
        **base,
        "score_rate": point,
        "score_delta": point - 0.5,
        "score_rate_ci": [lower, upper],
        "score_delta_ci": [lower - 0.5, upper - 0.5],
        "bootstrap_distribution": {
            "mean": mean,
            "standard_deviation": math.sqrt(variance),
            "minimum": min(draws),
            "maximum": max(draws),
            "quantiles": {
                "p01": percentile(draws, 0.01),
                "p05": percentile(draws, 0.05),
                "p25": percentile(draws, 0.25),
                "p50": percentile(draws, 0.50),
                "p75": percentile(draws, 0.75),
                "p95": percentile(draws, 0.95),
                "p99": percentile(draws, 0.99),
            },
        },
    }


def sequential_promotion_status(
    statistics: Mapping[str, Any],
    *,
    point_threshold: float,
    superiority_threshold: float = 0.5,
    final_look: bool,
) -> str:
    score = statistics.get("score_rate")
    interval = statistics.get("score_rate_ci", [None, None])
    lower, upper = interval if len(interval) >= 2 else (None, None)
    if (
        score is not None
        and float(score) >= float(point_threshold)
        and lower is not None
        and float(lower) > float(superiority_threshold)
    ):
        return "pass"
    if upper is not None and float(upper) < float(superiority_threshold):
        return "fail"
    return "inconclusive" if final_look else "continue"


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

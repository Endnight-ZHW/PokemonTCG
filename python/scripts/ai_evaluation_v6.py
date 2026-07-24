"""Authoritative schema-v6 aggregation for Godot traditional-AI evaluation.

The Godot runner deliberately emits shard evidence.  This module is the only
place that turns that evidence into acceptance metrics, so one-worker and
multi-worker runs cannot silently use different statistics.
"""
from __future__ import annotations

import hashlib
import math
import random
import time
import zlib
from collections import Counter, defaultdict
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = 6
BOOTSTRAP_ITERATIONS = 10_000
BOOTSTRAP_SEED = 90_210
DECK_ORDER = [
    "colorless",
    "darkness",
    "dragon",
    "fighting",
    "fire",
    "grass",
    "lightning",
    "psychic",
    "steel",
    "water",
]
PUBLIC_ACTION_KINDS = [
    "PLAY_BASIC",
    "EVOLVE",
    "ATTACH_ENERGY",
    "PLAY_TRAINER",
    "USE_ABILITY",
    "USE_STADIUM",
    "RETREAT",
    "DECLARE_ATTACK",
    "PROMOTE",
    "SETUP_DONE",
    "END_TURN",
]
MATCHUP_MIRROR = "mirror"
MATCHUP_CROSS = "cross"
STRATEGY_KEYS = ("A", "B")


class MergeError(ValueError):
    """Raised when shard evidence is mutually incompatible or ambiguous."""


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return default


def _float(value: Any, default: float = 0.0) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return default
    return result if math.isfinite(result) else default


def _round(value: float | None, digits: int = 4) -> float | None:
    return None if value is None else round(float(value), digits)


def _quantile(values: Sequence[float], probability: float) -> float | None:
    """R type-7 / NumPy default linear quantile without a NumPy dependency."""
    if not values:
        return None
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = max(0.0, min(1.0, probability)) * (len(ordered) - 1)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def _percentile_ms(values: Sequence[float], probability: float) -> float | None:
    value = _quantile(values, probability)
    return _round(value, 3)


def _match_point(row: dict[str, Any]) -> float:
    winner = str(row.get("winner") or "draw")
    if winner == "A":
        return 1.0
    if winner == "B":
        return 0.0
    return 0.5


def _is_clean_match(row: dict[str, Any]) -> bool:
    return (
        str(row.get("terminal_reason") or "") == "game_over"
        and _int(row.get("invalid_actions")) == 0
        and _int(row.get("choice_failures")) == 0
        and _int(row.get("rule_exceptions")) == 0
        and not bool(row.get("max_actions_exhausted"))
    )


def _canonical_mode(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    if normalized == "balanced":
        return "Balanced"
    if normalized == "matrix":
        return "Matrix"
    return "Mirror"


def _game_seed(base_seed: int, deck_index: int, block_index: int) -> int:
    return base_seed + deck_index * 1_000_003 + block_index * 10_007


def _cross_game_seed(
    base_seed: int,
    deck_a_index: int,
    deck_b_index: int,
    block_index: int,
) -> int:
    lower_index = min(deck_a_index, deck_b_index)
    upper_index = max(deck_a_index, deck_b_index)
    return (
        base_seed
        + 50_000_000
        + lower_index * 1_000_003
        + upper_index * 97_409
        + block_index * 10_007
    )


def _deck_index(deck: str, selected: Sequence[str]) -> int:
    try:
        return DECK_ORDER.index(deck)
    except ValueError:
        return list(selected).index(deck)


def _match_identity(row: dict[str, Any]) -> tuple[str, str, str, int, int, int]:
    deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
    deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
    return (
        str(row.get("matchup_kind") or MATCHUP_MIRROR),
        deck_a,
        deck_b,
        _int(row.get("seed_block")),
        _int(row.get("seed")),
        _int(row.get("seat"), -1),
    )


def _identity_text(identity: Sequence[Any]) -> str:
    return ":".join(str(value) for value in identity)


def _task_in_range(task_index: int, start: int, count: int) -> bool:
    return task_index >= start and (count <= 0 or task_index < start + count)


def expected_match_identities(
    deck_keys: Sequence[str], config: dict[str, Any]
) -> set[tuple[str, str, str, int, int, int]]:
    """Rebuild the runner's requested schedule without applying shard modulus."""
    selected = [str(value) for value in deck_keys]
    unknown = [deck for deck in selected if deck not in DECK_ORDER]
    if unknown:
        raise MergeError(f"unknown_decks:{','.join(sorted(unknown))}")
    if not selected:
        raise MergeError("no_decks")

    base_seed = _int(config.get("seed"), 17)
    seed_blocks = max(1, _int(config.get("seed_blocks_per_deck"), 1))
    cross_blocks = max(0, _int(config.get("cross_seed_blocks_per_matchup"), 0))
    block_start = max(0, _int(config.get("seed_block_start"), 0))
    requested_count = max(0, _int(config.get("seed_block_count"), 0))
    block_count = max(0, seed_blocks - block_start)
    if requested_count > 0:
        block_count = min(block_count, requested_count)
    block_end = block_start + block_count
    task_start = max(0, _int(config.get("task_start"), 0))
    task_count = max(0, _int(config.get("task_count"), 0))
    mode = _canonical_mode(config.get("matchup_mode"))
    run_mirror = mode in {"Mirror", "Balanced"}
    run_cross = mode in {"Matrix", "Balanced"}

    expected: set[tuple[str, str, str, int, int, int]] = set()
    task_index = 0
    if run_mirror:
        for deck in selected:
            deck_index = _deck_index(deck, selected)
            for block in range(block_start, block_end):
                if _task_in_range(task_index, task_start, task_count):
                    seed = _game_seed(base_seed, deck_index, block)
                    for seat in (0, 1):
                        expected.add((MATCHUP_MIRROR, deck, deck, block, seed, seat))
                task_index += 1
    if run_cross and cross_blocks > 0:
        cross_end = min(cross_blocks, block_end)
        for deck_a in selected:
            index_a = _deck_index(deck_a, selected)
            for deck_b in selected:
                if deck_a == deck_b:
                    continue
                index_b = _deck_index(deck_b, selected)
                for block in range(block_start, cross_end):
                    if _task_in_range(task_index, task_start, task_count):
                        seed = _cross_game_seed(base_seed, index_a, index_b, block)
                        for seat in (0, 1):
                            expected.add((MATCHUP_CROSS, deck_a, deck_b, block, seed, seat))
                    task_index += 1
    return expected


def _mirror_unit_key(row: dict[str, Any]) -> tuple[str, int, int]:
    return (
        str(row.get("strategy_a_deck") or row.get("deck") or ""),
        _int(row.get("seed_block")),
        _int(row.get("seed")),
    )


def _unordered_matchup(deck_a: str, deck_b: str) -> str:
    lower, upper = sorted((deck_a, deck_b))
    return f"{lower}_and_{upper}"


def _cross_unit_key(row: dict[str, Any]) -> tuple[str, int, int]:
    deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
    deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
    return (
        _unordered_matchup(deck_a, deck_b),
        _int(row.get("seed_block")),
        _int(row.get("seed")),
    )


def _mirror_unit(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    first = rows[0] if rows else {}
    seats = {_int(row.get("seat"), -1) for row in rows}
    seeds = {_int(row.get("seed")) for row in rows}
    blocks = {_int(row.get("seed_block")) for row in rows}
    forced = {_int(row.get("forced_first_player"), -1) for row in rows}
    decks = {
        (
            str(row.get("strategy_a_deck") or row.get("deck") or ""),
            str(row.get("strategy_b_deck") or row.get("deck") or ""),
        )
        for row in rows
    }
    players = {_int(row.get("strategy_a_player"), -1) for row in rows}
    assignments_valid = all(
        _int(row.get("strategy_a_player"), -1)
        == (0 if _int(row.get("seat"), -1) == 0 else 1)
        for row in rows
    )
    first_player_valid = all(
        _int(row.get("forced_first_player"), -1)
        == _int(row.get("seed_block")) % 2
        for row in rows
    )
    strategy_first_flag_valid = all(
        bool(row.get("strategy_a_first"))
        == (
            _int(row.get("strategy_a_player"), -1)
            == _int(row.get("forced_first_player"), -1)
        )
        for row in rows
    )
    player_decks_valid = all(
        list(row.get("player_decks") or [])
        == (
            [
                str(row.get("strategy_a_deck") or row.get("deck") or ""),
                str(row.get("strategy_b_deck") or row.get("deck") or ""),
            ]
            if _int(row.get("strategy_a_player"), -1) == 0
            else [
                str(row.get("strategy_b_deck") or row.get("deck") or ""),
                str(row.get("strategy_a_deck") or row.get("deck") or ""),
            ]
        )
        for row in rows
    )
    complete = (
        len(rows) == 2
        and seats == {0, 1}
        and players == {0, 1}
        and len(seeds) == 1
        and len(blocks) == 1
        and len(forced) == 1
        and len(decks) == 1
        and all(left == right for left, right in decks)
        and assignments_valid
        and first_player_valid
        and strategy_first_flag_valid
        and player_decks_valid
    )
    clean = complete and all(_is_clean_match(row) for row in rows)
    point_rate = sum(_match_point(row) for row in rows) / len(rows) if rows else None
    return {
        "kind": MATCHUP_MIRROR,
        "group": str(first.get("strategy_a_deck") or first.get("deck") or ""),
        "seed_block": _int(first.get("seed_block")),
        "seed": _int(first.get("seed")),
        "games": len(rows),
        "complete": complete,
        "clean": clean,
        "point_rate": _round(point_rate),
        "point_delta": _round(None if point_rate is None else point_rate - 0.5),
    }


def _cross_unit(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    first = rows[0] if rows else {}
    directions: dict[tuple[str, str], set[int]] = defaultdict(set)
    seeds = {_int(row.get("seed")) for row in rows}
    blocks = {_int(row.get("seed_block")) for row in rows}
    forced = {_int(row.get("forced_first_player"), -1) for row in rows}
    for row in rows:
        directions[(
            str(row.get("strategy_a_deck") or row.get("deck") or ""),
            str(row.get("strategy_b_deck") or row.get("deck") or ""),
        )].add(_int(row.get("seat"), -1))
    direction_keys = set(directions)
    reversed_directions = {
        (left, right)
        for left, right in direction_keys
        if (right, left) in direction_keys and left != right
    }
    assignments_valid = all(
        _int(row.get("strategy_a_player"), -1)
        == (0 if _int(row.get("seat"), -1) == 0 else 1)
        for row in rows
    )
    first_player_valid = all(
        _int(row.get("forced_first_player"), -1)
        == _int(row.get("seed_block")) % 2
        for row in rows
    )
    strategy_first_flag_valid = all(
        bool(row.get("strategy_a_first"))
        == (
            _int(row.get("strategy_a_player"), -1)
            == _int(row.get("forced_first_player"), -1)
        )
        for row in rows
    )
    player_decks_valid = all(
        list(row.get("player_decks") or [])
        == (
            [
                str(row.get("strategy_a_deck") or row.get("deck") or ""),
                str(row.get("strategy_b_deck") or row.get("deck") or ""),
            ]
            if _int(row.get("strategy_a_player"), -1) == 0
            else [
                str(row.get("strategy_b_deck") or row.get("deck") or ""),
                str(row.get("strategy_a_deck") or row.get("deck") or ""),
            ]
        )
        for row in rows
    )
    complete = (
        len(rows) == 4
        and len(seeds) == 1
        and len(blocks) == 1
        and len(forced) == 1
        and len(directions) == 2
        and len(reversed_directions) == 2
        and all(seats == {0, 1} for seats in directions.values())
        and assignments_valid
        and first_player_valid
        and strategy_first_flag_valid
        and player_decks_valid
    )
    clean = complete and all(_is_clean_match(row) for row in rows)
    point_rate = sum(_match_point(row) for row in rows) / len(rows) if rows else None
    deck_a = str(first.get("strategy_a_deck") or first.get("deck") or "")
    deck_b = str(first.get("strategy_b_deck") or first.get("deck") or "")
    return {
        "kind": MATCHUP_CROSS,
        "group": _unordered_matchup(deck_a, deck_b),
        "seed_block": _int(first.get("seed_block")),
        "seed": _int(first.get("seed")),
        "games": len(rows),
        "complete": complete,
        "clean": clean,
        "point_rate": _round(point_rate),
        "point_delta": _round(None if point_rate is None else point_rate - 0.5),
    }


def experimental_units(
    matches: Sequence[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    mirror_groups: dict[tuple[str, int, int], list[dict[str, Any]]] = defaultdict(list)
    cross_groups: dict[tuple[str, int, int], list[dict[str, Any]]] = defaultdict(list)
    for row in matches:
        kind = str(row.get("matchup_kind") or MATCHUP_MIRROR)
        if kind == MATCHUP_CROSS:
            cross_groups[_cross_unit_key(row)].append(row)
        elif kind == MATCHUP_MIRROR:
            mirror_groups[_mirror_unit_key(row)].append(row)
    mirror_units = [_mirror_unit(mirror_groups[key]) for key in sorted(mirror_groups)]
    cross_units = [_cross_unit(cross_groups[key]) for key in sorted(cross_groups)]
    return mirror_units, cross_units


def _bootstrap_group_equal_delta(
    grouped_deltas: dict[str, list[float]], seed: int
) -> list[float]:
    if not grouped_deltas or any(not values for values in grouped_deltas.values()):
        return []
    keys = sorted(grouped_deltas)
    rng = random.Random(seed)
    samples: list[float] = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        group_means = []
        for key in keys:
            values = grouped_deltas[key]
            group_means.append(
                sum(values[rng.randrange(len(values))] for _ in values) / len(values)
            )
        samples.append(sum(group_means) / len(group_means))
    return samples


def _probability_positive(values: Sequence[float]) -> float | None:
    if not values:
        return None
    positive = 0.0
    for value in values:
        if value > 0.0:
            positive += 1.0
        elif math.isclose(value, 0.0, abs_tol=1e-12):
            positive += 0.5
    return _round(positive / len(values), 4)


def _effect_summary(
    grouped_units: dict[str, list[dict[str, Any]]], seed: int
) -> dict[str, Any]:
    grouped_deltas = {
        key: [float(unit["point_delta"]) for unit in units]
        for key, units in grouped_units.items()
        if units
    }
    if not grouped_deltas:
        return {
            "groups": 0,
            "units": 0,
            "point_rate": None,
            "point_delta": None,
            "ci95": {
                "lower": None,
                "upper": None,
                "iterations": BOOTSTRAP_ITERATIONS,
                "unit": "cluster",
            },
            "probability_a_better": None,
        }
    group_means = [sum(values) / len(values) for values in grouped_deltas.values()]
    delta = sum(group_means) / len(group_means)
    bootstrap = _bootstrap_group_equal_delta(grouped_deltas, seed)
    return {
        "groups": len(grouped_deltas),
        "units": sum(len(values) for values in grouped_deltas.values()),
        "point_rate": _round(0.5 + delta),
        "point_delta": _round(delta),
        "ci95": {
            "lower": _round(_quantile(bootstrap, 0.025)),
            "upper": _round(_quantile(bootstrap, 0.975)),
            "iterations": BOOTSTRAP_ITERATIONS,
            "unit": "cluster",
        },
        "probability_a_better": _probability_positive(bootstrap),
    }


def summarize_strength(
    mirror_units: Sequence[dict[str, Any]],
    cross_units: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    def summarize_scope(
        units: Sequence[dict[str, Any]], *, seed: int, group_label: str, method: str
    ) -> dict[str, Any]:
        clean = [unit for unit in units if bool(unit.get("clean"))]
        grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for unit in clean:
            grouped[str(unit.get("group") or "")].append(dict(unit))
        overall = _effect_summary(dict(grouped), seed)
        per_group: dict[str, Any] = {}
        for key in sorted(grouped):
            stable_seed = seed + zlib.crc32(key.encode("utf-8")) % 1_000_000
            per_group[key] = _effect_summary({key: grouped[key]}, stable_seed)
        return {
            "method": method,
            "group_weighting": "equal",
            "all_units": len(units),
            "complete_units": sum(bool(unit.get("complete")) for unit in units),
            "clean_units": len(clean),
            "overall": overall,
            group_label: per_group,
        }

    return {
        "mirror": summarize_scope(
            mirror_units,
            seed=BOOTSTRAP_SEED,
            group_label="per_deck",
            method="same_seed_two_game_seat_pair_v2",
        ),
        "cross_role": summarize_scope(
            cross_units,
            seed=BOOTSTRAP_SEED + 50_000,
            group_label="per_unordered_matchup",
            method="same_seed_four_game_role_crossover_v2",
        ),
    }


def _coerce_latency_samples(value: Any) -> list[float]:
    if not isinstance(value, list):
        return []
    result: list[float] = []
    for raw in value:
        parsed = _float(raw, -1.0)
        if parsed >= 0.0:
            result.append(parsed)
    return result


def _performance_values(
    matches: Sequence[dict[str, Any]],
) -> tuple[dict[str, dict[str, list[float]]], bool]:
    values = {
        key: {"decision": [], "cache": [], "turn": []}
        for key in STRATEGY_KEYS
    }
    available = bool(matches)
    for row in matches:
        decisions = row.get("decision_ms_samples_by_strategy")
        cache_hits = row.get("turn_plan_cache_hit_samples_by_strategy")
        turns = row.get("ai_turn_ms_samples_by_strategy")
        if not all(isinstance(value, dict) for value in (decisions, cache_hits, turns)):
            available = False
            continue
        for strategy in STRATEGY_KEYS:
            strategy_decisions = _coerce_latency_samples(decisions.get(strategy))
            strategy_flags = cache_hits.get(strategy)
            strategy_turns = _coerce_latency_samples(turns.get(strategy))
            if (
                not isinstance(strategy_flags, list)
                or len(strategy_flags) != len(strategy_decisions)
                or any(not isinstance(flag, bool) for flag in strategy_flags)
            ):
                available = False
                continue
            values[strategy]["decision"].extend(strategy_decisions)
            values[strategy]["cache"].extend(
                sample
                for sample, flag in zip(strategy_decisions, strategy_flags)
                if flag
            )
            values[strategy]["turn"].extend(strategy_turns)
    return values, available


def summarize_performance(matches: Sequence[dict[str, Any]]) -> dict[str, Any]:
    values, available = _performance_values(matches)
    result: dict[str, Any] = {"available": available}
    for strategy in STRATEGY_KEYS:
        strategy_values = values[strategy]
        decisions = strategy_values["decision"]
        cache = strategy_values["cache"]
        turns = strategy_values["turn"]
        result[strategy] = {
            "decision_ms_sample_count": len(decisions),
            "decision_ms_p50": _percentile_ms(decisions, 0.50),
            "decision_ms_p95": _percentile_ms(decisions, 0.95),
            "cache_hit_decision_ms_sample_count": len(cache),
            "cache_hit_decision_ms_p95": _percentile_ms(cache, 0.95),
            "ai_turn_ms_sample_count": len(turns),
            "ai_turn_ms_p50": _percentile_ms(turns, 0.50),
            "ai_turn_ms_p95": _percentile_ms(turns, 0.95),
        }
    all_decisions = values["A"]["decision"] + values["B"]["decision"]
    all_cache = values["A"]["cache"] + values["B"]["cache"]
    all_turns = values["A"]["turn"] + values["B"]["turn"]
    result["overall"] = {
        "decision_ms_sample_count": len(all_decisions),
        "decision_ms_p50": _percentile_ms(all_decisions, 0.50),
        "decision_ms_p95": _percentile_ms(all_decisions, 0.95),
        "cache_hit_decision_ms_sample_count": len(all_cache),
        "cache_hit_decision_ms_p95": _percentile_ms(all_cache, 0.95),
        "ai_turn_ms_sample_count": len(all_turns),
        "ai_turn_ms_p50": _percentile_ms(all_turns, 0.50),
        "ai_turn_ms_p95": _percentile_ms(all_turns, 0.95),
    }
    return result


def _search_depth_scope(samples: Sequence[dict[str, Any]]) -> dict[str, Any]:
    requested = [max(1, _int(sample.get("requested"), 1)) for sample in samples]
    reached = [max(0, _int(sample.get("reached"))) for sample in samples]
    completed = [max(0, _int(sample.get("completed"))) for sample in samples]
    ratios = [
        min(1.0, float(actual) / float(target))
        for actual, target in zip(completed, requested)
    ]
    completion_reasons = Counter(
        str(sample.get("completion_reason") or sample.get("stop_reason") or "unknown")
        for sample in samples
    )
    completed_or_exhausted = [
        (
            (reason == "depth_complete" and actual >= target)
            or reason == "frontier_exhausted"
        )
        for actual, target, reason in zip(
            completed,
            requested,
            (
                str(
                    sample.get("completion_reason")
                    or sample.get("stop_reason")
                    or "unknown"
                )
                for sample in samples
            ),
        )
    ]
    stop_reasons = Counter(
        str(sample.get("stop_reason") or "unknown") for sample in samples
    )
    engine_counts = Counter(
        str(sample.get("engine_id") or "unknown") for sample in samples
    )
    return {
        "sample_count": len(samples),
        "requested_depth_min": min(requested) if requested else None,
        "requested_depth_p50": _round(_quantile(requested, 0.50)),
        "requested_depth_max": max(requested) if requested else None,
        "reached_depth_min": min(reached) if reached else None,
        "reached_depth_p10": _round(_quantile(reached, 0.10)),
        "reached_depth_p50": _round(_quantile(reached, 0.50)),
        "reached_depth_p95": _round(_quantile(reached, 0.95)),
        "reached_depth_max": max(reached) if reached else None,
        "completed_depth_min": min(completed) if completed else None,
        "completed_depth_p50": _round(_quantile(completed, 0.50)),
        "completed_depth_p95": _round(_quantile(completed, 0.95)),
        "completed_depth_max": max(completed) if completed else None,
        "depth_ratio_p50": _round(_quantile(ratios, 0.50)),
        "requested_depth_completed_rate": _round(
            sum(actual >= target for actual, target in zip(completed, requested))
            / len(samples)
            if samples
            else None
        ),
        "complete_or_frontier_exhausted_rate": _round(
            sum(completed_or_exhausted) / len(samples) if samples else None
        ),
        "incomplete_searches": sum(not value for value in completed_or_exhausted),
        "deadline_truncations": int(max(
            stop_reasons.get("deadline", 0),
            completion_reasons.get("deadline", 0),
        )),
        "node_budget_truncations": int(max(
            stop_reasons.get("node_budget", 0),
            completion_reasons.get("node_budget", 0),
        )),
        "stop_reasons": dict(sorted(stop_reasons.items())),
        "completion_reasons": dict(sorted(completion_reasons.items())),
        "engines": dict(sorted(engine_counts.items())),
    }


def summarize_search_depth(
    matches: Sequence[dict[str, Any]], deck_keys: Sequence[str]
) -> dict[str, Any]:
    """Summarize actual beam depth; wall-clock latency remains diagnostic only."""
    by_strategy: dict[str, list[dict[str, Any]]] = {
        strategy: [] for strategy in STRATEGY_KEYS
    }
    by_strategy_deck: dict[str, dict[str, list[dict[str, Any]]]] = {
        strategy: {deck: [] for deck in deck_keys} for strategy in STRATEGY_KEYS
    }
    for row in matches:
        if not _is_clean_match(row):
            continue
        raw = row.get("search_depth_samples_by_strategy") or {}
        if not isinstance(raw, dict):
            continue
        for strategy in STRATEGY_KEYS:
            samples = raw.get(strategy)
            if not isinstance(samples, list):
                continue
            deck = str(
                (
                    row.get("strategy_a_deck")
                    if strategy == "A"
                    else row.get("strategy_b_deck")
                )
                or ""
            )
            for sample in samples:
                if not isinstance(sample, dict):
                    continue
                normalized = {
                    "requested": max(1, _int(sample.get("requested"), 1)),
                    "reached": max(0, _int(sample.get("reached"))),
                    "completed": max(0, _int(sample.get("completed"))),
                    "max_path_depth": max(0, _int(sample.get("max_path_depth"))),
                    "reply_completed": max(0, _int(sample.get("reply_completed"))),
                    "layers_completed": max(0, _int(sample.get("layers_completed"))),
                    "completion_reason": str(
                        sample.get("completion_reason")
                        or sample.get("stop_reason")
                        or "unknown"
                    ),
                    "stop_reason": str(sample.get("stop_reason") or "unknown"),
                    "engine_id": str(sample.get("engine_id") or "unknown"),
                    "nodes_expanded": max(0, _int(sample.get("nodes_expanded"))),
                    "trajectory_hash": str(sample.get("trajectory_hash") or ""),
                }
                by_strategy[strategy].append(normalized)
                if deck in by_strategy_deck[strategy]:
                    by_strategy_deck[strategy][deck].append(normalized)

    result: dict[str, Any] = {
        "available": all(bool(by_strategy[strategy]) for strategy in STRATEGY_KEYS),
        "latency_is_diagnostic_only": True,
        "by_strategy": {},
    }
    for strategy in STRATEGY_KEYS:
        all_samples = by_strategy[strategy]
        result["by_strategy"][strategy] = {
            "overall": _search_depth_scope(all_samples),
            # Compatibility name retained for existing report layouts. Schema
            # v6 has no local/exhausted quality tier.
            "full_tier": _search_depth_scope(all_samples),
            "per_deck": {
                deck: {
                    "overall": _search_depth_scope(
                        by_strategy_deck[strategy][deck]
                    ),
                    "full_tier": _search_depth_scope(
                        by_strategy_deck[strategy][deck]
                    ),
                }
                for deck in deck_keys
            },
        }
    return result


def summarize_observed(matches: Sequence[dict[str, Any]]) -> dict[str, Any]:
    wins = sum(str(row.get("winner")) == "A" for row in matches)
    losses = sum(str(row.get("winner")) == "B" for row in matches)
    draws = len(matches) - wins - losses
    clean = [row for row in matches if _is_clean_match(row)]
    clean_points = sum(_match_point(row) for row in clean)
    games = len(matches)
    decisions = sum(_int(row.get("decisions")) for row in matches)
    choices = sum(_int(row.get("choices")) for row in matches)
    performance = summarize_performance(matches)
    overall_perf = performance.get("overall") or {}
    result = {
        "games": games,
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "point_rate": _round((wins + draws * 0.5) / games if games else None),
        "clean_games": len(clean),
        "clean_point_rate": _round(clean_points / len(clean) if clean else None),
        "completion_rate": _round(
            sum(str(row.get("terminal_reason")) == "game_over" for row in matches)
            / games
            if games
            else None
        ),
        "actions": sum(_int(row.get("actions")) for row in matches),
        "turns": sum(_int(row.get("turns")) for row in matches),
        "decisions": decisions,
        "choices": choices,
        "invalid_actions": sum(_int(row.get("invalid_actions")) for row in matches),
        "choice_failures": sum(_int(row.get("choice_failures")) for row in matches),
        "rule_exceptions": sum(_int(row.get("rule_exceptions")) for row in matches),
        "time_capped_decisions": sum(
            _int(row.get("time_capped_decisions")) for row in matches
        ),
        "deep_fallbacks": sum(_int(row.get("deep_fallbacks")) for row in matches),
        "max_actions_exhaustions": sum(
            bool(row.get("max_actions_exhausted")) for row in matches
        ),
    }
    result["max_action_exhaustion_rate"] = _round(
        result["max_actions_exhaustions"] / games if games else None
    )
    result["time_capped_decision_rate"] = _round(
        result["time_capped_decisions"] / decisions if decisions else 0.0
    )
    result["deep_fallback_rate"] = _round(
        result["deep_fallbacks"] / max(1, decisions + choices)
    )
    result.update(overall_perf)
    return result


def _empty_behavior_counts() -> dict[str, Counter[str]]:
    return {
        "selected": Counter(),
        "opportunities": Counter(),
        "choices": Counter(),
    }


def _merge_behavior_counts(
    target: dict[str, Counter[str]], source: dict[str, Any]
) -> None:
    mappings = (
        ("selected", "selected_action_counts"),
        ("opportunities", "legal_action_opportunity_counts"),
        ("choices", "choice_request_counts"),
    )
    for target_key, source_key in mappings:
        raw = source.get(source_key)
        if not isinstance(raw, dict):
            continue
        for key, value in raw.items():
            target[target_key][str(key)] += max(0, _int(value))


def _finalize_behavior_counts(counts: dict[str, Counter[str]]) -> dict[str, Any]:
    action_kinds = sorted(
        set(PUBLIC_ACTION_KINDS)
        | set(counts["selected"])
        | set(counts["opportunities"]),
        key=lambda value: (
            PUBLIC_ACTION_KINDS.index(value)
            if value in PUBLIC_ACTION_KINDS
            else 999,
            value,
        ),
    )
    selected = {key: int(counts["selected"].get(key, 0)) for key in action_kinds}
    opportunities = {
        key: int(counts["opportunities"].get(key, 0)) for key in action_kinds
    }
    total_selected = sum(selected.values())
    shares = {
        key: _round(value / total_selected if total_selected else 0.0)
        for key, value in selected.items()
    }
    rates = {
        key: _round(
            selected[key] / opportunities[key] if opportunities[key] else None
        )
        for key in action_kinds
    }
    available_kinds = [key for key, value in opportunities.items() if value > 0]
    selected_kinds = [key for key, value in selected.items() if value > 0]
    entropy = 0.0
    if total_selected:
        for value in selected.values():
            if value:
                probability = value / total_selected
                entropy -= probability * math.log(probability)
    normalized_entropy: float | None = None
    if len(available_kinds) > 1:
        normalized_entropy = entropy / math.log(len(available_kinds))
    return {
        "selected_action_counts": selected,
        "selected_action_shares": shares,
        "legal_action_opportunity_counts": opportunities,
        "selection_rate_when_available": rates,
        "choice_request_counts": dict(sorted(counts["choices"].items())),
        "available_action_kinds": len(available_kinds),
        "selected_action_kinds": len(selected_kinds),
        "action_kind_coverage": _round(
            len(selected_kinds) / len(available_kinds) if available_kinds else None
        ),
        "normalized_action_entropy": _round(normalized_entropy),
    }


def summarize_behavior(
    matches: Sequence[dict[str, Any]], deck_keys: Sequence[str]
) -> dict[str, Any]:
    overall = {strategy: _empty_behavior_counts() for strategy in STRATEGY_KEYS}
    per_deck = {
        strategy: {deck: _empty_behavior_counts() for deck in deck_keys}
        for strategy in STRATEGY_KEYS
    }
    rows_with_data = 0
    clean_rows = 0
    for row in matches:
        if not _is_clean_match(row):
            continue
        clean_rows += 1
        raw = row.get("behavior_by_strategy")
        if not isinstance(raw, dict):
            continue
        row_complete = True
        for strategy in STRATEGY_KEYS:
            source = raw.get(strategy)
            if not isinstance(source, dict):
                row_complete = False
                continue
            deck = str(
                (row.get("strategy_a_deck") if strategy == "A" else row.get("strategy_b_deck"))
                or ""
            )
            _merge_behavior_counts(overall[strategy], source)
            if deck in per_deck[strategy]:
                _merge_behavior_counts(per_deck[strategy][deck], source)
        if row_complete:
            rows_with_data += 1
    return {
        "method": "selected_action_and_legal_category_opportunity_v1",
        "diagnostic_only": True,
        "available": clean_rows > 0 and rows_with_data == clean_rows,
        "clean_rows": clean_rows,
        "rows_with_data": rows_with_data,
        "overall": {
            strategy: _finalize_behavior_counts(overall[strategy])
            for strategy in STRATEGY_KEYS
        },
        "per_deck": {
            strategy: {
                deck: _finalize_behavior_counts(per_deck[strategy][deck])
                for deck in deck_keys
            }
            for strategy in STRATEGY_KEYS
        },
    }


def summarize_fairness(
    matches: Sequence[dict[str, Any]],
    mirror_units: Sequence[dict[str, Any]],
    cross_units: Sequence[dict[str, Any]],
    deck_keys: Sequence[str],
) -> dict[str, Any]:
    assignment = {
        "A": {"player_0": 0, "player_1": 0, "first": 0, "second": 0},
        "B": {"player_0": 0, "player_1": 0, "first": 0, "second": 0},
    }
    by_strategy_deck = {
        strategy: {
            deck: {"player_0": 0, "player_1": 0, "first": 0, "second": 0}
            for deck in deck_keys
        }
        for strategy in STRATEGY_KEYS
    }
    first_points = 0.0
    for row in matches:
        a_player = _int(row.get("strategy_a_player"), -1)
        forced_first = _int(row.get("forced_first_player"), -1)
        a_first = a_player == forced_first
        deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
        deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
        for strategy, player, is_first, deck in (
            ("A", a_player, a_first, deck_a),
            ("B", 1 - a_player if a_player in (0, 1) else -1, not a_first, deck_b),
        ):
            if player in (0, 1):
                assignment[strategy][f"player_{player}"] += 1
                if deck in by_strategy_deck[strategy]:
                    by_strategy_deck[strategy][deck][f"player_{player}"] += 1
            assignment[strategy]["first" if is_first else "second"] += 1
            if deck in by_strategy_deck[strategy]:
                by_strategy_deck[strategy][deck]["first" if is_first else "second"] += 1
        winner = _int(row.get("engine_winner"), -1)
        if winner == forced_first:
            first_points += 1.0
        elif winner < 0:
            first_points += 0.5

    def balanced_counts(values: dict[str, int]) -> bool:
        return (
            values["player_0"] == values["player_1"]
            and values["first"] == values["second"]
        )

    assignment_balanced = all(
        balanced_counts(assignment[strategy]) for strategy in STRATEGY_KEYS
    )
    per_deck_balanced = all(
        balanced_counts(by_strategy_deck[strategy][deck])
        for strategy in STRATEGY_KEYS
        for deck in deck_keys
        if sum(by_strategy_deck[strategy][deck].values()) > 0
    )
    return {
        "assignment": assignment,
        "by_strategy_deck": by_strategy_deck,
        "assignment_balanced": assignment_balanced,
        "per_strategy_deck_balanced": per_deck_balanced,
        "mirror_units_complete": all(bool(unit.get("complete")) for unit in mirror_units),
        "cross_units_complete": all(bool(unit.get("complete")) for unit in cross_units),
        "role_balanced": assignment_balanced and per_deck_balanced,
        "first_player_point_rate": _round(
            first_points / len(matches) if matches else None
        ),
        "seed_count": len({_int(row.get("seed")) for row in matches}),
    }


def summarize_coverage(
    matches: Sequence[dict[str, Any]],
    deck_keys: Sequence[str],
    config: dict[str, Any],
    mirror_units: Sequence[dict[str, Any]],
    cross_units: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    expected = expected_match_identities(deck_keys, config)
    observed = {_match_identity(row) for row in matches}
    missing = sorted(expected - observed)
    unexpected = sorted(observed - expected)
    expected_mirror_games = sum(identity[0] == MATCHUP_MIRROR for identity in expected)
    expected_cross_games = sum(identity[0] == MATCHUP_CROSS for identity in expected)
    source_indices = sorted({
        _int(row.get("task_shard_index"), 0) for row in matches
    })
    source_counts = sorted({
        max(1, _int(row.get("task_shard_count"), 1)) for row in matches
    })
    shard_coverage_complete = (
        len(source_counts) == 1
        and source_indices == list(range(source_counts[0]))
    )
    structural_errors: list[str] = []
    for unit in mirror_units:
        if not unit.get("complete"):
            structural_errors.append(
                f"mirror_incomplete:{unit.get('group')}:{unit.get('seed_block')}:{unit.get('seed')}"
            )
    for unit in cross_units:
        if not unit.get("complete"):
            structural_errors.append(
                f"cross_incomplete:{unit.get('group')}:{unit.get('seed_block')}:{unit.get('seed')}"
            )
    return {
        "expected_games": len(expected),
        "actual_games": len(matches),
        "expected_mirror_games": expected_mirror_games,
        "actual_mirror_games": sum(
            str(row.get("matchup_kind")) == MATCHUP_MIRROR for row in matches
        ),
        "expected_mirror_units": expected_mirror_games // 2,
        "actual_mirror_units": len(mirror_units),
        "complete_mirror_units": sum(bool(unit.get("complete")) for unit in mirror_units),
        "clean_mirror_units": sum(bool(unit.get("clean")) for unit in mirror_units),
        "expected_cross_games": expected_cross_games,
        "actual_cross_games": sum(
            str(row.get("matchup_kind")) == MATCHUP_CROSS for row in matches
        ),
        "expected_cross_units": expected_cross_games // 4,
        "actual_cross_units": len(cross_units),
        "complete_cross_units": sum(bool(unit.get("complete")) for unit in cross_units),
        "clean_cross_units": sum(bool(unit.get("clean")) for unit in cross_units),
        "missing_match_count": len(missing),
        "missing_matches": [_identity_text(identity) for identity in missing],
        "unexpected_match_count": len(unexpected),
        "unexpected_matches": [_identity_text(identity) for identity in unexpected],
        "structural_errors": structural_errors,
        "source_task_shard_indices": source_indices,
        "source_task_shard_counts": source_counts,
        "shard_coverage_complete": shard_coverage_complete,
        "complete": (
            not missing
            and not unexpected
            and not structural_errors
            and shard_coverage_complete
        ),
    }


def summarize_decision_diagnostics(matches: Sequence[dict[str, Any]]) -> dict[str, Any]:
    labels: Counter[str] = Counter()
    by_strategy = {strategy: Counter() for strategy in STRATEGY_KEYS}
    decisions_by_strategy = {strategy: 0 for strategy in STRATEGY_KEYS}
    per_deck: dict[str, Counter[str]] = defaultdict(Counter)
    for row in matches:
        latency_samples = row.get("decision_ms_samples_by_strategy")
        if isinstance(latency_samples, dict):
            for strategy in STRATEGY_KEYS:
                samples = latency_samples.get(strategy)
                if isinstance(samples, list):
                    decisions_by_strategy[strategy] += len(samples)
        raw = row.get("decision_diagnostics")
        if isinstance(raw, dict):
            for key, value in raw.items():
                labels[str(key)] += _int(value)
        raw_by_strategy = row.get("decision_diagnostics_by_strategy")
        if isinstance(raw_by_strategy, dict):
            for strategy in STRATEGY_KEYS:
                strategy_values = raw_by_strategy.get(strategy)
                if not isinstance(strategy_values, dict):
                    continue
                actual_deck = str(
                    (row.get("strategy_a_deck") if strategy == "A" else row.get("strategy_b_deck"))
                    or ""
                )
                for key, value in strategy_values.items():
                    count = _int(value)
                    by_strategy[strategy][str(key)] += count
                    per_deck[actual_deck][str(key)] += count
    delta = Counter()
    for key in set(by_strategy["A"]) | set(by_strategy["B"]):
        delta[key] = by_strategy["A"][key] - by_strategy["B"][key]
    rates = {
        strategy: {
            key: _round(
                value / decisions_by_strategy[strategy]
                if decisions_by_strategy[strategy]
                else None
            )
            for key, value in sorted(by_strategy[strategy].items())
        }
        for strategy in STRATEGY_KEYS
    }
    return {
        "total": sum(labels.values()),
        "labels": dict(sorted(labels.items())),
        "per_deck": {
            key: dict(sorted(value.items())) for key, value in sorted(per_deck.items())
        },
        "by_strategy": {
            "A": {
                "total": sum(by_strategy["A"].values()),
                "decisions": decisions_by_strategy["A"],
                "labels": dict(sorted(by_strategy["A"].items())),
                "rates": rates["A"],
            },
            "B": {
                "total": sum(by_strategy["B"].values()),
                "decisions": decisions_by_strategy["B"],
                "labels": dict(sorted(by_strategy["B"].items())),
                "rates": rates["B"],
            },
            "delta": {"total": sum(delta.values()), "labels": dict(sorted(delta.items()))},
        },
    }


def _raw_matrix(matches: Sequence[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    grouped: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for row in matches:
        deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
        deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
        grouped[deck_a][deck_b].append(row)
    return {
        deck_a: {
            deck_b: summarize_observed(grouped[deck_a][deck_b])
            for deck_b in sorted(grouped[deck_a], key=_deck_sort_key)
        }
        for deck_a in sorted(grouped, key=_deck_sort_key)
    }


def _fair_adjusted_matrix(
    deck_keys: Sequence[str], strength: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    mirror = (strength.get("mirror") or {}).get("per_deck") or {}
    cross = (strength.get("cross_role") or {}).get("per_unordered_matchup") or {}
    result: dict[str, dict[str, Any]] = {}
    for deck_a in deck_keys:
        row: dict[str, Any] = {}
        for deck_b in deck_keys:
            if deck_a == deck_b:
                source = (mirror.get(deck_a) or {}).get("overall") or {}
                kind = MATCHUP_MIRROR
            else:
                source = (cross.get(_unordered_matchup(deck_a, deck_b)) or {}).get("overall") or {}
                kind = MATCHUP_CROSS
            row[deck_b] = {
                "kind": kind,
                "point_delta": source.get("point_delta"),
                "ci95": source.get("ci95"),
                "units": source.get("units", 0),
            }
        result[deck_a] = row
    return result


def _deck_sort_key(deck: str) -> tuple[int, str]:
    try:
        return DECK_ORDER.index(deck), deck
    except ValueError:
        return 999, deck


def merge_golden_scenarios(shards: Sequence[dict[str, Any]]) -> dict[str, Any]:
    cases: dict[tuple[str, str], dict[str, Any]] = {}
    for shard in shards:
        golden = shard.get("golden_scenarios") or {}
        for raw in golden.get("cases") or []:
            if not isinstance(raw, dict):
                continue
            row = dict(raw)
            key = (str(row.get("scope") or "unspecified"), str(row.get("name") or ""))
            if key in cases and cases[key] != row:
                raise MergeError(f"golden_case_mismatch:{key[0]}:{key[1]}")
            cases[key] = row
    ordered = [cases[key] for key in sorted(cases)]
    by_scope: dict[str, dict[str, int]] = {}
    for row in ordered:
        scope = str(row.get("scope") or "unspecified")
        summary = by_scope.setdefault(scope, {"total": 0, "passed": 0, "failed": 0})
        summary["total"] += 1
        summary["passed" if bool(row.get("passed")) else "failed"] += 1
    failed = sum(not bool(row.get("passed")) for row in ordered)
    return {
        "total": len(ordered),
        "passed": len(ordered) - failed,
        "failed": failed,
        "by_scope": by_scope,
        "cases": ordered,
    }


def merge_performance_profiles(shards: Sequence[dict[str, Any]]) -> dict[str, Any]:
    enabled = False
    segments: Counter[str] = Counter()
    counts: Counter[str] = Counter()
    for shard in shards:
        profile = shard.get("performance_profile") or {}
        enabled = enabled or bool(profile.get("enabled"))
        for key, value in (profile.get("segments_ms") or {}).items():
            segments[str(key)] += _float(value)
        for key, value in (profile.get("counts") or {}).items():
            counts[str(key)] += _int(value)
    return {
        "enabled": enabled,
        "segments_ms": {key: _round(value, 3) for key, value in sorted(segments.items())},
        "counts": dict(sorted(counts.items())),
    }


def _provenance_fingerprint(payload: dict[str, Any]) -> str:
    provenance = payload.get("provenance")
    if not isinstance(provenance, dict):
        return ""
    explicit = str(provenance.get("fingerprint") or "")
    if explicit:
        return explicit
    canonical = repr(sorted((str(key), repr(value)) for key, value in provenance.items()))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_shards(shards: Sequence[dict[str, Any]]) -> dict[str, Any]:
    if not shards:
        raise MergeError("no_shards")
    reference = shards[0]
    if _int(reference.get("schema_version")) != SCHEMA_VERSION:
        raise MergeError("schema_version")
    if reference.get("artifact_kind") != "ai_evaluation_shard":
        raise MergeError("artifact_kind")
    reference_decks = [str(value) for value in reference.get("deck_keys") or []]
    if (
        not reference_decks
        or len(reference_decks) != len(set(reference_decks))
        or any(deck not in DECK_ORDER for deck in reference_decks)
    ):
        raise MergeError("deck_keys")
    reference_config = reference.get("config") or {}
    if str(reference_config.get("platform") or "") != str(reference.get("platform") or ""):
        raise MergeError("config:platform")
    reference_provenance_object = reference.get("provenance") or {}
    if (
        not isinstance(reference_provenance_object, dict)
        or _int(reference_provenance_object.get("schema_version")) != SCHEMA_VERSION
    ):
        raise MergeError("provenance_schema")
    provenance_platform = str(reference_provenance_object.get("target_platform") or "")
    if provenance_platform and provenance_platform != str(reference.get("platform") or ""):
        raise MergeError("provenance_platform")
    strategy_fingerprint = reference.get("strategy_fingerprint") or {}
    if not isinstance(strategy_fingerprint, dict) or not all(
        str(strategy_fingerprint.get(strategy) or "") for strategy in STRATEGY_KEYS
    ):
        raise MergeError("strategy_fingerprint")
    reference_provenance = _provenance_fingerprint(reference)
    if not reference_provenance:
        raise MergeError("provenance")
    for index, payload in enumerate(shards):
        if _int(payload.get("schema_version")) != SCHEMA_VERSION:
            raise MergeError(f"shard_{index}:schema_version")
        if payload.get("artifact_kind") != "ai_evaluation_shard":
            raise MergeError(f"shard_{index}:artifact_kind")
        if payload.get("strategy_fingerprint") != reference.get("strategy_fingerprint"):
            raise MergeError(f"shard_{index}:strategy_fingerprint")
        if payload.get("platform") != reference.get("platform"):
            raise MergeError(f"shard_{index}:platform")
        if payload.get("deck_keys") != reference.get("deck_keys"):
            raise MergeError(f"shard_{index}:deck_keys")
        payload_provenance = payload.get("provenance") or {}
        if (
            not isinstance(payload_provenance, dict)
            or _int(payload_provenance.get("schema_version")) != SCHEMA_VERSION
        ):
            raise MergeError(f"shard_{index}:provenance_schema")
        if _provenance_fingerprint(payload) != reference_provenance:
            raise MergeError(f"shard_{index}:provenance")
        config = payload.get("config") or {}
        for key in (
            "seed",
            "seed_blocks_per_deck",
            "cross_seed_blocks_per_matchup",
            "seed_block_start",
            "seed_block_count",
            "task_start",
            "task_count",
            "task_shard_count",
            "max_actions",
            "eval_preset",
            "matchup_mode",
            "profile",
            "disable_ai_cache",
            "disable_native_math",
            "rules_options",
            "decision_latency_sampling",
            "ai_turn_latency_sampling",
            "platform",
            "run_role",
            "warmup_blocks_per_deck",
        ):
            if config.get(key) != reference_config.get(key):
                raise MergeError(f"shard_{index}:config:{key}")
    return reference


def _merge_matches(shards: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str, int, int, int]] = set()
    for shard_index, payload in enumerate(shards):
        raw_matches = payload.get("matches")
        if not isinstance(raw_matches, list):
            raise MergeError(f"shard_{shard_index}:matches")
        for raw in raw_matches:
            if not isinstance(raw, dict):
                raise MergeError(f"shard_{shard_index}:match_row")
            row = dict(raw)
            identity = _match_identity(row)
            if identity in seen:
                raise MergeError(f"duplicate_match:{_identity_text(identity)}")
            if identity[-1] not in (0, 1):
                raise MergeError(f"invalid_seat:{_identity_text(identity)}")
            if identity[1] not in DECK_ORDER or identity[2] not in DECK_ORDER:
                raise MergeError(f"unknown_match_deck:{_identity_text(identity)}")
            if identity[0] not in (MATCHUP_MIRROR, MATCHUP_CROSS):
                raise MergeError(f"invalid_matchup_kind:{_identity_text(identity)}")
            if str(row.get("winner") or "") not in ("A", "B", "draw"):
                raise MergeError(f"invalid_winner:{_identity_text(identity)}")
            if _int(row.get("strategy_a_player"), -1) not in (0, 1):
                raise MergeError(f"invalid_strategy_player:{_identity_text(identity)}")
            if _int(row.get("forced_first_player"), -1) not in (0, 1):
                raise MergeError(f"invalid_first_player:{_identity_text(identity)}")
            if str(row.get("sample_phase") or "") not in (
                "main",
                "warmup",
                "measurement",
            ):
                raise MergeError(f"invalid_sample_phase:{_identity_text(identity)}")
            for field in (
                "decision_ms_samples_by_strategy",
                "turn_plan_cache_hit_samples_by_strategy",
                "ai_turn_ms_samples_by_strategy",
                "behavior_by_strategy",
                "search_depth_samples_by_strategy",
            ):
                value = row.get(field)
                if not isinstance(value, dict) or not all(
                    strategy in value for strategy in STRATEGY_KEYS
                ):
                    raise MergeError(f"invalid_{field}:{_identity_text(identity)}")
            for strategy in STRATEGY_KEYS:
                decisions = row["decision_ms_samples_by_strategy"][strategy]
                cache_hits = row["turn_plan_cache_hit_samples_by_strategy"][strategy]
                turns = row["ai_turn_ms_samples_by_strategy"][strategy]
                if (
                    not isinstance(decisions, list)
                    or not isinstance(cache_hits, list)
                    or not isinstance(turns, list)
                    or len(decisions) != len(cache_hits)
                    or any(not isinstance(flag, bool) for flag in cache_hits)
                    or any(_float(value, -1.0) < 0.0 for value in decisions + turns)
                ):
                    raise MergeError(
                        f"invalid_latency_samples:{strategy}:{_identity_text(identity)}"
                    )
                behavior = row["behavior_by_strategy"][strategy]
                if not isinstance(behavior, dict) or not all(
                    isinstance(behavior.get(field), dict)
                    for field in (
                        "selected_action_counts",
                        "legal_action_opportunity_counts",
                        "choice_request_counts",
                    )
                ):
                    raise MergeError(
                        f"invalid_behavior_counts:{strategy}:{_identity_text(identity)}"
                    )
                depth_samples = row["search_depth_samples_by_strategy"][strategy]
                if not isinstance(depth_samples, list):
                    raise MergeError(
                        f"invalid_search_depth_samples:{strategy}:{_identity_text(identity)}"
                    )
                for sample in depth_samples:
                    if not isinstance(sample, dict):
                        raise MergeError(
                            f"invalid_search_depth_sample:{strategy}:{_identity_text(identity)}"
                        )
                    engine_id = str(sample.get("engine_id") or "")
                    requested = _int(sample.get("requested"), 0)
                    completed = _int(sample.get("completed"), -1)
                    layers = _int(sample.get("layers_completed"), -1)
                    reason = str(sample.get("completion_reason") or "")
                    if (
                        requested < 1
                        or _int(sample.get("reached"), -1) < 0
                        or _int(sample.get("reached"), -1)
                        > requested
                        or completed < 0
                        or completed > requested
                        or layers < 0
                        or layers > requested
                        or _int(sample.get("max_path_depth"), -1) < completed
                        or _int(sample.get("reply_completed"), -1) < 0
                        or not str(sample.get("stop_reason") or "")
                        or not reason
                        or engine_id not in ("turn_beam_v1", "turn_beam_v2")
                        or _int(sample.get("nodes_expanded"), -1) < 0
                        or len(str(sample.get("trajectory_hash") or "")) != 64
                        or (
                            engine_id == "turn_beam_v2"
                            and (
                                layers != completed
                                or reason
                                not in ("depth_complete", "frontier_exhausted")
                                or (
                                    reason == "depth_complete"
                                    and completed != requested
                                )
                                or (
                                    reason == "frontier_exhausted"
                                    and completed < 1
                                )
                            )
                        )
                    ):
                        raise MergeError(
                            f"invalid_search_depth_sample:{strategy}:{_identity_text(identity)}"
                        )
            seen.add(identity)
            row["source_shard_index"] = shard_index
            matches.append(row)
    matches.sort(key=lambda row: (
        0 if str(row.get("matchup_kind")) == MATCHUP_MIRROR else 1,
        _deck_sort_key(str(row.get("strategy_a_deck") or row.get("deck") or "")),
        _deck_sort_key(str(row.get("strategy_b_deck") or row.get("deck") or "")),
        _int(row.get("seed_block")),
        _int(row.get("seed")),
        _int(row.get("seat")),
    ))
    return matches


def _merge_search_depth_probe(
    main_reference: dict[str, Any],
    search_depth_shards: Sequence[dict[str, Any]] | None,
) -> dict[str, Any]:
    if not search_depth_shards:
        return {
            "available": False,
            "source": "single_process_search_depth_probe",
            "reason": "search_depth_probe_missing",
            "gate_basis": "search_depth",
            "latency_diagnostic_only": True,
        }
    probe_reference = validate_shards(search_depth_shards)
    if probe_reference.get("strategy_fingerprint") != main_reference.get("strategy_fingerprint"):
        raise MergeError("search_depth_probe:strategy_fingerprint")
    if probe_reference.get("platform") != main_reference.get("platform"):
        raise MergeError("search_depth_probe:platform")
    if _provenance_fingerprint(probe_reference) != _provenance_fingerprint(main_reference):
        raise MergeError("search_depth_probe:provenance")
    probe_matches = _merge_matches(search_depth_shards)
    config = dict(probe_reference.get("config") or {})
    mirror_units, cross_units = experimental_units(probe_matches)
    coverage = summarize_coverage(
        probe_matches,
        probe_reference.get("deck_keys") or [],
        config,
        mirror_units,
        cross_units,
    )
    measured = [
        row for row in probe_matches if str(row.get("sample_phase") or "measurement") == "measurement"
    ]
    warmup = [row for row in probe_matches if str(row.get("sample_phase") or "") == "warmup"]
    summary = summarize_performance(measured)
    search_depth = summarize_search_depth(
        measured, probe_reference.get("deck_keys") or []
    )
    return {
        "available": bool(summary.get("available")) and bool(search_depth.get("available")),
        "source": "single_process_search_depth_probe",
        "gate_basis": "search_depth",
        "latency_diagnostic_only": True,
        "config": config,
        "coverage": coverage,
        "games_total": len(probe_matches),
        "warmup_games": len(warmup),
        "measured_games": len(measured),
        "metrics": summary,
        "search_depth": search_depth,
        "observed": summarize_observed(probe_matches),
        "matches": probe_matches,
        "performance_profile": merge_performance_profiles(search_depth_shards),
    }


def merge_payloads(
    shards: Sequence[dict[str, Any]],
    *,
    workers: int = 1,
    search_depth_shards: Sequence[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    reference = validate_shards(shards)
    matches = _merge_matches(shards)
    deck_keys = [str(value) for value in reference.get("deck_keys") or []]
    config = dict(reference.get("config") or {})
    mirror_units, cross_units = experimental_units(matches)
    observed = summarize_observed(matches)
    strength = summarize_strength(mirror_units, cross_units)
    coverage = summarize_coverage(
        matches, deck_keys, config, mirror_units, cross_units
    )
    fairness = summarize_fairness(
        matches, mirror_units, cross_units, deck_keys
    )
    behavior = summarize_behavior(matches, deck_keys)
    search_depth = summarize_search_depth(matches, deck_keys)
    main_performance = summarize_performance(matches)
    performance = _merge_search_depth_probe(reference, search_depth_shards)
    raw_matrix = _raw_matrix(matches)
    fair_adjusted_matrix = _fair_adjusted_matrix(deck_keys, strength)
    config["parallel_workers"] = max(1, int(workers))
    config["source_task_shard_indices"] = coverage["source_task_shard_indices"]
    config["source_task_shard_counts"] = coverage["source_task_shard_counts"]
    result = {
        "schema_version": SCHEMA_VERSION,
        "artifact_kind": "ai_evaluation_result",
        "created_at_unix": int(time.time()),
        "platform": reference.get("platform"),
        "provenance": reference.get("provenance") or {},
        "self_check": bool(reference.get("self_check")),
        "eval_preset": reference.get("eval_preset"),
        "mode": str(reference.get("mode") or "mirror"),
        "matchup_mode": reference.get("matchup_mode") or config.get("matchup_mode"),
        "deck_keys": deck_keys,
        "config": config,
        "strategies": reference.get("strategies") or {},
        "strategy_fingerprint": reference.get("strategy_fingerprint") or {},
        "aggregation": {
            "version": "paired_cluster_v2",
            "bootstrap_iterations": BOOTSTRAP_ITERATIONS,
            "bootstrap_seed": BOOTSTRAP_SEED,
            "strength_uses_complete_clean_units_only": True,
        },
        "evaluation_policy": {
            "search_quality_gate": "complete_fixed_depth_layers",
            "production_engine": "turn_beam_v2",
            "latency": "diagnostic_only",
        },
        "observed": observed,
        "summary": observed,
        "strength": strength,
        "coverage": coverage,
        "fairness": fairness,
        "behavior": behavior,
        "search_depth": search_depth,
        "performance": performance,
        "main_performance": main_performance,
        "performance_by_strategy": main_performance,
        "raw_matrix": raw_matrix,
        "fair_adjusted_matrix": fair_adjusted_matrix,
        "matrix": raw_matrix,
        "decision_diagnostics": summarize_decision_diagnostics(matches),
        "golden_scenarios": merge_golden_scenarios(shards),
        "performance_profile": merge_performance_profiles(shards),
        "terminal_reasons": dict(sorted(Counter(
            str(row.get("terminal_reason") or "") for row in matches
        ).items())),
        "matches": matches,
        "shards": [
            {
                "index": index,
                "artifact_kind": payload.get("artifact_kind"),
                "games": len(payload.get("matches") or []),
                "config": payload.get("config") or {},
            }
            for index, payload in enumerate(shards)
        ],
    }
    return result


def source_fingerprint(entries: Iterable[tuple[str, bytes]]) -> str:
    digest = hashlib.sha256()
    for relative_path, content in sorted(entries, key=lambda item: item[0]):
        encoded = relative_path.replace("\\", "/").encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()

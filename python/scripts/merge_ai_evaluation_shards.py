"""Merge parallel Godot traditional-AI evaluation shards into one schema-v4 result."""
from __future__ import annotations

import argparse
import json
import math
import random
import time
import zlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 4
BOOTSTRAP_ITERATIONS = 400
BOOTSTRAP_SEED = 90210
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
STRATEGY_KEYS = ("A", "B")
STRATEGY_LATENCY_FIELDS = (
    "decision_ms_samples_by_strategy",
    "turn_plan_cache_hit_samples_by_strategy",
    "ai_turn_ms_samples_by_strategy",
)


class MergeError(ValueError):
    pass


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _coerce_latency_samples(raw_samples: Any, key: str) -> list[float]:
    if not isinstance(raw_samples, list):
        raise MergeError(key)
    samples: list[float] = []
    for index, value in enumerate(raw_samples):
        if isinstance(value, bool):
            raise MergeError(f"{key}:{index}")
        try:
            sample_ms = float(value)
        except (TypeError, ValueError) as exc:
            raise MergeError(f"{key}:{index}") from exc
        if not math.isfinite(sample_ms) or sample_ms < 0.0:
            raise MergeError(f"{key}:{index}")
        samples.append(sample_ms)
    return samples


def _latency_samples(row: dict[str, Any], key: str) -> list[float]:
    return _coerce_latency_samples(row.get(key), key)


def _strategy_latency_samples(
    row: dict[str, Any],
) -> dict[str, dict[str, list[Any]]] | None:
    present = [key in row for key in STRATEGY_LATENCY_FIELDS]
    if not any(present):
        # Schema v4 predates per-strategy samples. Old artifacts remain mergeable
        # and retain the original aggregate performance interpretation.
        return None
    if not all(present):
        raise MergeError("strategy_latency_samples:incomplete")

    raw_decisions = row.get("decision_ms_samples_by_strategy")
    raw_cache_hits = row.get("turn_plan_cache_hit_samples_by_strategy")
    raw_ai_turns = row.get("ai_turn_ms_samples_by_strategy")
    if not isinstance(raw_decisions, dict):
        raise MergeError("decision_ms_samples_by_strategy")
    if not isinstance(raw_cache_hits, dict):
        raise MergeError("turn_plan_cache_hit_samples_by_strategy")
    if not isinstance(raw_ai_turns, dict):
        raise MergeError("ai_turn_ms_samples_by_strategy")

    result: dict[str, dict[str, list[Any]]] = {}
    combined_decision_pairs: list[tuple[float, bool]] = []
    combined_ai_turns: list[float] = []
    for strategy_key in STRATEGY_KEYS:
        decision_key = f"decision_ms_samples_by_strategy:{strategy_key}"
        decisions = _coerce_latency_samples(raw_decisions.get(strategy_key), decision_key)
        strategy_cache_hits = raw_cache_hits.get(strategy_key)
        if not isinstance(strategy_cache_hits, list):
            raise MergeError(f"turn_plan_cache_hit_samples_by_strategy:{strategy_key}")
        if len(strategy_cache_hits) != len(decisions):
            raise MergeError(
                f"turn_plan_cache_hit_samples_by_strategy:{strategy_key}:length"
            )
        if any(not isinstance(value, bool) for value in strategy_cache_hits):
            raise MergeError(
                f"turn_plan_cache_hit_samples_by_strategy:{strategy_key}:type"
            )
        ai_turns = _coerce_latency_samples(
            raw_ai_turns.get(strategy_key),
            f"ai_turn_ms_samples_by_strategy:{strategy_key}",
        )
        result[strategy_key] = {
            "decision_ms_samples": decisions,
            "turn_plan_cache_hit_samples": list(strategy_cache_hits),
            "ai_turn_ms_samples": ai_turns,
        }
        combined_decision_pairs.extend(zip(decisions, strategy_cache_hits))
        combined_ai_turns.extend(ai_turns)

    global_decisions = _latency_samples(row, "decision_ms_samples")
    global_cache_hits = row.get("turn_plan_cache_hit_samples")
    if not isinstance(global_cache_hits, list):
        raise MergeError("turn_plan_cache_hit_samples")
    if len(global_cache_hits) != len(global_decisions):
        raise MergeError("turn_plan_cache_hit_samples:length")
    if any(not isinstance(value, bool) for value in global_cache_hits):
        raise MergeError("turn_plan_cache_hit_samples:type")
    if sorted(combined_decision_pairs) != sorted(zip(global_decisions, global_cache_hits)):
        raise MergeError("strategy_decision_latency_samples:mismatch")
    if sorted(combined_ai_turns) != sorted(_latency_samples(row, "ai_turn_ms_samples")):
        raise MergeError("strategy_ai_turn_latency_samples:mismatch")
    return result


def _summarize_performance_by_strategy(
    matches: list[dict[str, Any]],
) -> dict[str, Any]:
    parsed = [_strategy_latency_samples(row) for row in matches]
    available_rows = [row for row in parsed if row is not None]
    if not available_rows:
        return {"available": False}
    if len(available_rows) != len(matches):
        raise MergeError("strategy_latency_samples:coverage")

    accumulated = {
        strategy_key: {
            "decision_ms_samples": [],
            "cache_hit_decision_ms_samples": [],
            "ai_turn_ms_samples": [],
        }
        for strategy_key in STRATEGY_KEYS
    }
    for row in available_rows:
        assert row is not None
        for strategy_key in STRATEGY_KEYS:
            values = row[strategy_key]
            decisions = values["decision_ms_samples"]
            cache_hits = values["turn_plan_cache_hit_samples"]
            target = accumulated[strategy_key]
            target["decision_ms_samples"].extend(decisions)
            target["cache_hit_decision_ms_samples"].extend(
                sample
                for sample, cache_hit in zip(decisions, cache_hits)
                if cache_hit
            )
            target["ai_turn_ms_samples"].extend(values["ai_turn_ms_samples"])

    result: dict[str, Any] = {"available": True}
    for strategy_key in STRATEGY_KEYS:
        values = accumulated[strategy_key]
        decision_values = values["decision_ms_samples"]
        cache_values = values["cache_hit_decision_ms_samples"]
        ai_turn_values = values["ai_turn_ms_samples"]
        result[strategy_key] = {
            "decision_ms_sample_count": len(decision_values),
            "decision_ms_p95": _round(_percentile(decision_values, 0.95), 3),
            "cache_hit_decision_ms_sample_count": len(cache_values),
            "cache_hit_decision_ms_p95": _round(_percentile(cache_values, 0.95), 3),
            "ai_turn_ms_sample_count": len(ai_turn_values),
            "ai_turn_ms_p95": _round(_percentile(ai_turn_values, 0.95), 3),
        }
    return result


def _round(value: float, digits: int = 4) -> float:
    return round(float(value), digits)


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    index = int(max(0.0, min(1.0, pct)) * (len(ordered) - 1))
    return ordered[index]


def _ci(values: list[float]) -> dict[str, Any]:
    return {
        "lower": _round(_percentile(values, 0.025), 4),
        "upper": _round(_percentile(values, 0.975), 4),
        "samples": len(values),
    }


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


def _empty_stats() -> dict[str, Any]:
    return {
        "games": 0,
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "completed_games": 0,
        "clean_games": 0,
        "clean_wins": 0,
        "clean_losses": 0,
        "clean_draws": 0,
        "score_total": 0.0,
        "actions": 0,
        "turns": 0,
        "decisions": 0,
        "choices": 0,
        "decision_ms_total": 0.0,
        "decision_ms_sample_count": 0,
        "decision_ms_values": [],
        "cache_hit_decision_ms_sample_count": 0,
        "cache_hit_decision_ms_values": [],
        "ai_turn_ms_sample_count": 0,
        "ai_turn_ms_values": [],
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "time_capped_decisions": 0,
        "deep_fallbacks": 0,
        "dynamic_budget_stop_reasons": {},
        "max_actions_exhaustions": 0,
    }


def _merge_match(stats: dict[str, Any], row: dict[str, Any]) -> None:
    stats["games"] += 1
    winner = str(row.get("winner") or "draw")
    if winner == "A":
        stats["wins"] += 1
    elif winner == "B":
        stats["losses"] += 1
    else:
        stats["draws"] += 1

    if str(row.get("terminal_reason") or "") == "game_over":
        stats["completed_games"] += 1
    if _is_clean_match(row):
        stats["clean_games"] += 1
        if winner == "A":
            stats["clean_wins"] += 1
        elif winner == "B":
            stats["clean_losses"] += 1
        else:
            stats["clean_draws"] += 1

    decisions = _int(row.get("decisions"))
    choices = _int(row.get("choices"))
    stats["score_total"] += _float(row.get("score"))
    stats["actions"] += _int(row.get("actions"))
    stats["turns"] += _int(row.get("turns"))
    stats["decisions"] += decisions
    stats["choices"] += choices
    decision_samples = _latency_samples(row, "decision_ms_samples")
    if len(decision_samples) != decisions + choices:
        raise MergeError("decision_ms_samples:count")
    raw_cache_hits = row.get("turn_plan_cache_hit_samples")
    if not isinstance(raw_cache_hits, list):
        raise MergeError("turn_plan_cache_hit_samples")
    if len(raw_cache_hits) != len(decision_samples):
        raise MergeError("turn_plan_cache_hit_samples:length")
    if any(not isinstance(value, bool) for value in raw_cache_hits):
        raise MergeError("turn_plan_cache_hit_samples:type")
    for sample_ms, cache_hit in zip(decision_samples, raw_cache_hits):
        stats["decision_ms_total"] += sample_ms
        stats["decision_ms_sample_count"] += 1
        stats["decision_ms_values"].append(sample_ms)
        if cache_hit:
            stats["cache_hit_decision_ms_sample_count"] += 1
            stats["cache_hit_decision_ms_values"].append(sample_ms)
    for sample_ms in _latency_samples(row, "ai_turn_ms_samples"):
        stats["ai_turn_ms_sample_count"] += 1
        stats["ai_turn_ms_values"].append(sample_ms)
    stats["invalid_actions"] += _int(row.get("invalid_actions"))
    stats["choice_failures"] += _int(row.get("choice_failures"))
    stats["rule_exceptions"] += _int(row.get("rule_exceptions"))
    stats["time_capped_decisions"] += _int(row.get("time_capped_decisions"))
    stats["deep_fallbacks"] += _int(row.get("deep_fallbacks"))
    stop_reasons = row.get("dynamic_budget_stop_reasons") or {}
    if isinstance(stop_reasons, dict):
        target = stats["dynamic_budget_stop_reasons"]
        for reason, count in stop_reasons.items():
            reason_key = str(reason)
            if reason_key:
                target[reason_key] = _int(target.get(reason_key)) + _int(count)
    if bool(row.get("max_actions_exhausted")):
        stats["max_actions_exhaustions"] += 1


def _elo_delta(point_rate: float) -> float:
    clamped = max(0.001, min(0.999, float(point_rate)))
    return 400.0 * __import__("math").log10(clamped / (1.0 - clamped))


def _finalize_stats(stats: dict[str, Any]) -> dict[str, Any]:
    games = max(1, _int(stats.get("games")))
    decisions_and_choices = max(1, _int(stats.get("decisions")) + _int(stats.get("choices")))
    decision_sample_count = max(1, _int(stats.get("decision_ms_sample_count")))
    decisions = max(1, _int(stats.get("decisions")))
    point_rate = (_float(stats.get("wins")) + _float(stats.get("draws")) * 0.5) / games
    clean_games = _int(stats.get("clean_games"))
    clean_point_rate = 0.0
    if clean_games > 0:
        clean_point_rate = (
            _float(stats.get("clean_wins")) + _float(stats.get("clean_draws")) * 0.5
        ) / clean_games
    result = dict(stats)
    result["win_rate"] = _round(_float(stats.get("wins")) / games, 4)
    result["draw_rate"] = _round(_float(stats.get("draws")) / games, 4)
    result["point_rate"] = _round(point_rate, 4)
    result["completion_rate"] = _round(_float(stats.get("completed_games")) / games, 4)
    result["max_action_exhaustion_rate"] = _round(_float(stats.get("max_actions_exhaustions")) / games, 4)
    result["clean_point_rate"] = _round(clean_point_rate, 4)
    result["average_score"] = _round(_float(stats.get("score_total")) / games, 3)
    result["average_actions"] = _round(_float(stats.get("actions")) / games, 3)
    result["average_turns"] = _round(_float(stats.get("turns")) / games, 3)
    result["average_decision_ms"] = _round(_float(stats.get("decision_ms_total")) / decision_sample_count, 3)
    result["decision_ms_p50"] = _round(_percentile(list(stats.get("decision_ms_values") or []), 0.50), 3)
    result["decision_ms_p95"] = _round(_percentile(list(stats.get("decision_ms_values") or []), 0.95), 3)
    result["cache_hit_decision_ms_p95"] = _round(
        _percentile(list(stats.get("cache_hit_decision_ms_values") or []), 0.95), 3
    )
    result["ai_turn_ms_p95"] = _round(
        _percentile(list(stats.get("ai_turn_ms_values") or []), 0.95), 3
    )
    result["time_capped_decision_rate"] = _round(_float(stats.get("time_capped_decisions")) / decisions, 4)
    result["deep_fallback_rate"] = _round(_float(stats.get("deep_fallbacks")) / decisions_and_choices, 4)
    stop_reasons = dict(stats.get("dynamic_budget_stop_reasons") or {})
    dynamic_stops = _int(stop_reasons.get("single_action")) + _int(stop_reasons.get("confidence"))
    result["dynamic_budget_stop_reasons"] = stop_reasons
    result["dynamic_budget_stops"] = dynamic_stops
    result["dynamic_budget_stop_rate"] = _round(dynamic_stops / decisions, 4)
    result["elo_delta"] = _round(_elo_delta(point_rate), 3)
    result.pop("decision_ms_values", None)
    result.pop("cache_hit_decision_ms_values", None)
    result.pop("ai_turn_ms_values", None)
    return result


def _summarize_matches(matches: list[dict[str, Any]]) -> dict[str, Any]:
    stats = _empty_stats()
    for row in matches:
        _merge_match(stats, row)
    return _finalize_stats(stats)


def _group_by_deck(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row.get("deck") or "")].append(row)
    return dict(grouped)


def _group_by_matchup(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        key = str(row.get("matchup_key") or "")
        if not key:
            deck = str(row.get("deck") or "")
            key = f"{deck}_vs_{deck}"
        grouped[key].append(row)
    return dict(grouped)


def _bootstrap_point_rate_ci(matches: list[dict[str, Any]], seed: int) -> dict[str, Any]:
    if not matches:
        return _ci([])
    groups = _group_by_deck(matches)
    rng = random.Random(max(1, int(seed)))
    values: list[float] = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        points = 0.0
        count = 0
        for deck in sorted(groups):
            rows = groups[deck]
            for _sample in range(len(rows)):
                row = rows[rng.randrange(len(rows))]
                points += _match_point(row)
                count += 1
        values.append(points / max(1, count))
    return _ci(values)


def _pair_key(row: dict[str, Any]) -> tuple[str, int, int]:
    explicit = row.get("pair_key")
    if explicit:
        return (str(explicit), 0, 0)
    return (
        str(row.get("deck") or ""),
        _int(row.get("seed_block")),
        _int(row.get("seed")),
    )


def _paired_rows(matches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, int, int], list[dict[str, Any]]] = defaultdict(list)
    for row in matches:
        grouped[_pair_key(row)].append(row)
    pairs: list[dict[str, Any]] = []
    for (_deck, _block, _seed), rows in sorted(grouped.items()):
        first = rows[0]
        games = max(1, len(rows))
        points = sum(_match_point(row) for row in rows)
        score = sum(_float(row.get("score")) for row in rows)
        point_rate = points / games
        pairs.append({
            "deck": str(first.get("deck") or ""),
            "strategy_a_deck": str(first.get("strategy_a_deck") or first.get("deck") or ""),
            "strategy_b_deck": str(first.get("strategy_b_deck") or first.get("deck") or ""),
            "matchup_key": str(first.get("matchup_key") or ""),
            "matchup_kind": str(first.get("matchup_kind") or "mirror"),
            "seed": _int(first.get("seed")),
            "seed_block": _int(first.get("seed_block")),
            "games": games,
            "complete": len(rows) >= 2,
            "clean": all(_is_clean_match(row) for row in rows),
            "point_rate": _round(point_rate, 4),
            "point_delta": _round(point_rate - 0.5, 4),
            "score_delta": _round(score / games, 3),
        })
    return pairs


def _bootstrap_pair_delta_values(pair_rows: list[dict[str, Any]], seed: int) -> list[float]:
    if not pair_rows:
        return []
    groups = _group_by_deck(pair_rows)
    rng = random.Random(max(1, int(seed)))
    values: list[float] = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        total = 0.0
        count = 0
        for deck in sorted(groups):
            rows = groups[deck]
            for _sample in range(len(rows)):
                row = rows[rng.randrange(len(rows))]
                total += _float(row.get("point_delta"))
                count += 1
        values.append(total / max(1, count))
    return values


def _probability_positive(values: list[float]) -> float:
    if not values:
        return 0.5
    positive = 0.0
    for value in values:
        if value > 0.0:
            positive += 1.0
        elif value == 0.0:
            positive += 0.5
    return _round(positive / len(values), 4)


def _summarize_pairs(pair_rows: list[dict[str, Any]], seed: int) -> dict[str, Any]:
    count = len(pair_rows)
    boot = _bootstrap_pair_delta_values(pair_rows, seed)
    return {
        "pairs": pair_rows,
        "paired_pairs": count,
        "clean_pairs": sum(1 for row in pair_rows if bool(row.get("clean"))),
        "paired_point_delta": _round(sum(_float(row.get("point_delta")) for row in pair_rows) / max(1, count), 4),
        "paired_score_delta": _round(sum(_float(row.get("score_delta")) for row in pair_rows) / max(1, count), 3),
        "paired_delta_ci95": _ci(boot),
        "probability_a_better": _probability_positive(boot),
    }


def _apply_paired_summary(target: dict[str, Any], paired: dict[str, Any]) -> None:
    for key in (
        "paired_pairs",
        "clean_pairs",
        "paired_point_delta",
        "paired_score_delta",
        "paired_delta_ci95",
        "probability_a_better",
    ):
        target[key] = paired.get(key)


def _summarize_by_deck(matches: list[dict[str, Any]], pair_rows: list[dict[str, Any]]) -> dict[str, Any]:
    pairs_by_deck = _group_by_deck(pair_rows)
    result: dict[str, Any] = {}
    for deck, rows in sorted(_group_by_deck(matches).items(), key=lambda item: _deck_sort_key(item[0])):
        stats = _summarize_matches(rows)
        stats["point_rate_ci95"] = _bootstrap_point_rate_ci(rows, BOOTSTRAP_SEED + _stable_deck_seed(deck))
        paired = _summarize_pairs(
            pairs_by_deck.get(deck, []),
            BOOTSTRAP_SEED + 1000 + _stable_deck_seed(deck),
        )
        _apply_paired_summary(stats, paired)
        result[deck] = stats
    return result


def _summarize_by_matchup(matches: list[dict[str, Any]], pair_rows: list[dict[str, Any]]) -> dict[str, Any]:
    pairs_by_matchup = _group_by_matchup(pair_rows)
    result: dict[str, Any] = {}
    for matchup, rows in sorted(_group_by_matchup(matches).items()):
        stats = _summarize_matches(rows)
        stats["point_rate_ci95"] = _bootstrap_point_rate_ci(
            rows,
            BOOTSTRAP_SEED + _stable_deck_seed(matchup),
        )
        paired = _summarize_pairs(
            pairs_by_matchup.get(matchup, []),
            BOOTSTRAP_SEED + 2000 + _stable_deck_seed(matchup),
        )
        _apply_paired_summary(stats, paired)
        result[matchup] = stats
    return result


def _summarize_matrix(matches: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    grouped: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for row in matches:
        deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
        deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
        grouped[deck_a][deck_b].append(row)
    result: dict[str, dict[str, Any]] = {}
    for deck_a in sorted(grouped, key=_deck_sort_key):
        result[deck_a] = {}
        for deck_b in sorted(grouped[deck_a], key=_deck_sort_key):
            result[deck_a][deck_b] = _summarize_matches(grouped[deck_a][deck_b])
    return result


DIAGNOSTIC_LABELS = (
    "missed_immediate_ko",
    "ended_with_productive_attack",
    "ended_with_productive_development",
    "weak_attack_before_development",
    "retreat_without_good_target",
    "trainer_first_choice_cancelled",
    "unsafe_draw_pressure_attack",
    "unsafe_retaliation_attack",
)


def _empty_diagnostic_counts() -> dict[str, int]:
    return {label: 0 for label in DIAGNOSTIC_LABELS}


def _summarize_decision_diagnostics(matches: list[dict[str, Any]]) -> dict[str, Any]:
    labels = _empty_diagnostic_counts()
    per_deck: dict[str, dict[str, int]] = {}
    per_matchup: dict[str, dict[str, int]] = {}
    by_strategy = {
        "A": _empty_diagnostic_counts(),
        "B": _empty_diagnostic_counts(),
    }
    total = 0
    for row in matches:
        deck = str(row.get("strategy_a_deck") or row.get("deck") or "")
        matchup = str(row.get("matchup_key") or f"{deck}_vs_{deck}")
        per_deck.setdefault(deck, _empty_diagnostic_counts())
        per_matchup.setdefault(matchup, _empty_diagnostic_counts())
        row_counts = row.get("decision_diagnostics") or {}
        row_by_strategy = row.get("decision_diagnostics_by_strategy") or {}
        for label in DIAGNOSTIC_LABELS:
            value = _int(row_counts.get(label))
            labels[label] += value
            per_deck[deck][label] += value
            per_matchup[matchup][label] += value
            total += value
            if isinstance(row_by_strategy, dict):
                for strategy_key in ("A", "B"):
                    strategy_counts = row_by_strategy.get(strategy_key) or {}
                    if isinstance(strategy_counts, dict):
                        by_strategy[strategy_key][label] += _int(strategy_counts.get(label))
    by_strategy_summary: dict[str, Any] = {}
    for strategy_key in ("A", "B"):
        by_strategy_summary[strategy_key] = {
            "total": sum(by_strategy[strategy_key].values()),
            "labels": by_strategy[strategy_key],
        }
    delta_labels = {
        label: by_strategy["A"][label] - by_strategy["B"][label]
        for label in DIAGNOSTIC_LABELS
    }
    by_strategy_summary["delta"] = {
        "total": sum(delta_labels.values()),
        "labels": delta_labels,
    }
    return {
        "total": total,
        "labels": labels,
        "per_deck": per_deck,
        "per_matchup": per_matchup,
        "by_strategy": by_strategy_summary,
    }


def _merge_golden_scenarios(shards: list[dict[str, Any]]) -> dict[str, Any]:
    cases_by_name: dict[str, dict[str, Any]] = {}
    for payload in shards:
        for row in (payload.get("golden_scenarios") or {}).get("cases") or []:
            name = str(row.get("name") or "")
            if not name:
                continue
            existing = cases_by_name.get(name)
            if existing is None or bool(existing.get("passed", True)):
                cases_by_name[name] = dict(row)
    cases = [cases_by_name[name] for name in sorted(cases_by_name)]
    failed = sum(1 for row in cases if not bool(row.get("passed")))
    by_scope: dict[str, dict[str, int]] = {}
    for row in cases:
        scope = str(row.get("scope") or "unspecified")
        summary = by_scope.setdefault(
            scope, {"total": 0, "passed": 0, "failed": 0}
        )
        summary["total"] += 1
        if bool(row.get("passed")):
            summary["passed"] += 1
        else:
            summary["failed"] += 1
    return {
        "total": len(cases),
        "passed": len(cases) - failed,
        "failed": failed,
        "by_scope": by_scope,
        "cases": cases,
    }


def _merge_performance_profiles(shards: list[dict[str, Any]]) -> dict[str, Any]:
    enabled = any(bool((payload.get("performance_profile") or {}).get("enabled")) for payload in shards)
    if not enabled:
        return {"enabled": False}
    segments: Counter[str] = Counter()
    counts: Counter[str] = Counter()
    for payload in shards:
        profile = payload.get("performance_profile") or {}
        for key, value in (profile.get("segments_ms") or {}).items():
            segments[str(key)] += _float(value)
        for key, value in (profile.get("counts") or {}).items():
            counts[str(key)] += _int(value)
    return {
        "enabled": True,
        "segments_ms": {key: _round(segments[key], 3) for key in sorted(segments)},
        "counts": {key: counts[key] for key in sorted(counts)},
    }


def _summarize_seats(matches: list[dict[str, Any]]) -> dict[str, Any]:
    first = _empty_stats()
    second = _empty_stats()
    seat_counts = {"a_player_0": 0, "a_player_1": 0}
    for row in matches:
        _merge_match(first if bool(row.get("strategy_a_first")) else second, row)
        if _int(row.get("strategy_a_player")) == 0:
            seat_counts["a_player_0"] += 1
        else:
            seat_counts["a_player_1"] += 1
    first_stats = _finalize_stats(first)
    second_stats = _finalize_stats(second)
    return {
        "strategy_a_first": first_stats,
        "strategy_a_second": second_stats,
        "seat_counts": seat_counts,
        "seat_gap": abs(seat_counts["a_player_0"] - seat_counts["a_player_1"]),
        "first_player_point_rate_gap": _round(
            abs(_float(first_stats.get("point_rate")) - _float(second_stats.get("point_rate"))),
            4,
        ),
    }


def _stable_deck_seed(deck: str) -> int:
    return zlib.crc32(deck.encode("utf-8")) % 100000


def _deck_sort_key(deck: str) -> tuple[int, str]:
    try:
        return (DECK_ORDER.index(deck), deck)
    except ValueError:
        return (999, deck)


def _match_sort_key(row: dict[str, Any]) -> tuple[int, int, int, int, int]:
    deck = str(row.get("deck") or "")
    return (
        _deck_sort_key(deck)[0],
        _int(row.get("task_index")),
        _int(row.get("seed_block")),
        _int(row.get("seat")),
        _int(row.get("strategy_a_player")),
    )


def _source_task_shard_count(payload: dict[str, Any]) -> int:
    config = payload.get("config") or {}
    return max(
        1,
        _int(config.get("task_shard_count"), 1),
        _int(config.get("source_task_shard_count"), 1),
    )


def _validate_shards(shards: list[dict[str, Any]]) -> dict[str, Any]:
    if not shards:
        raise MergeError("no_shards")
    reference = shards[0]
    if _int(reference.get("schema_version")) != SCHEMA_VERSION:
        raise MergeError("schema_version")
    for index, payload in enumerate(shards):
        if _int(payload.get("schema_version")) != SCHEMA_VERSION:
            raise MergeError(f"shard_{index}:schema_version")
        if payload.get("strategy_fingerprint") != reference.get("strategy_fingerprint"):
            raise MergeError(f"shard_{index}:strategy_fingerprint")
        if payload.get("platform") != reference.get("platform"):
            raise MergeError(f"shard_{index}:platform")
        if payload.get("deck_keys") != reference.get("deck_keys"):
            raise MergeError(f"shard_{index}:deck_keys")
        config = payload.get("config") or {}
        ref_config = reference.get("config") or {}
        for key in (
            "seed",
            "seed_blocks_per_deck",
            "cross_seed_blocks_per_matchup",
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
        ):
            if config.get(key) != ref_config.get(key):
                raise MergeError(f"shard_{index}:config:{key}")
    return reference


def merge_payloads(shards: list[dict[str, Any]], *, workers: int = 1) -> dict[str, Any]:
    reference = _validate_shards(shards)
    matches: list[dict[str, Any]] = []
    seen: set[tuple[str, int, int, int]] = set()
    for shard_index, payload in enumerate(shards):
        for row in payload.get("matches") or []:
            key = (
                str(row.get("strategy_a_deck") or row.get("deck") or ""),
                str(row.get("strategy_b_deck") or row.get("deck") or ""),
                _int(row.get("seed_block")),
                _int(row.get("seed")),
                _int(row.get("seat")),
            )
            if key in seen:
                raise MergeError(f"duplicate_match:{key}")
            seen.add(key)
            merged_row = dict(row)
            merged_row["shard_index"] = shard_index
            matches.append(merged_row)
    matches.sort(key=_match_sort_key)

    pair_rows = _paired_rows(matches)
    paired = _summarize_pairs(pair_rows, BOOTSTRAP_SEED + 777)
    summary = _summarize_matches(matches)
    summary["point_rate_ci95"] = _bootstrap_point_rate_ci(matches, BOOTSTRAP_SEED)
    _apply_paired_summary(summary, paired)

    config = dict(reference.get("config") or {})
    config["seed_block_start"] = 0
    config["seed_block_count"] = _int(config.get("seed_blocks_per_deck"))
    config["task_start"] = 0
    config["task_count"] = 0
    config["task_shard_index"] = 0
    config["task_shard_count"] = 1
    config["task_pairs_run"] = len(pair_rows)
    config["source_task_shard_count"] = max(
        1,
        max(_source_task_shard_count(payload) for payload in shards),
    )
    config["parallel_workers"] = max(1, int(workers))
    config["shards"] = len(shards)

    result = {
        "schema_version": SCHEMA_VERSION,
        "created_at_unix": int(time.time()),
        "self_check": bool(reference.get("self_check")),
        "eval_preset": reference.get("eval_preset"),
        "mode": reference.get("mode", "mirror"),
        "matchup_mode": reference.get("matchup_mode", "Mirror"),
        "deck_keys": reference.get("deck_keys") or [],
        "config": config,
        "strategies": reference.get("strategies") or {},
        "strategy_fingerprint": reference.get("strategy_fingerprint") or {},
        "summary": summary,
        "per_deck": _summarize_by_deck(matches, pair_rows),
        "per_matchup": _summarize_by_matchup(matches, pair_rows),
        "matrix": _summarize_matrix(matches),
        "role_crossover": _summarize_role_crossover(matches),
        "paired": paired,
        "seat": _summarize_seats(matches),
        "decision_diagnostics": _summarize_decision_diagnostics(matches),
        "golden_scenarios": _merge_golden_scenarios(shards),
        "performance_profile": _merge_performance_profiles(shards),
        "performance_by_strategy": _summarize_performance_by_strategy(matches),
        "terminal_reasons": dict(Counter(str(row.get("terminal_reason") or "") for row in matches)),
        "matches": matches,
        "shards": [
            {
                "index": index,
                "games": _int((payload.get("summary") or {}).get("games")),
                "config": payload.get("config") or {},
            }
            for index, payload in enumerate(shards)
        ],
    }
    if reference.get("platform") is not None:
        result["platform"] = reference.get("platform")
    return result


def _unordered_matchup_key(deck_a: str, deck_b: str) -> str:
    lower, upper = sorted((deck_a, deck_b))
    return f"{lower}_and_{upper}"


def _role_crossover_block_key(row: dict[str, Any]) -> str:
    explicit = str(row.get("role_crossover_block_key") or "")
    if explicit:
        return explicit
    deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
    deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
    return (
        f"{_unordered_matchup_key(deck_a, deck_b)}:"
        f"{_int(row.get('seed_block'))}:{_int(row.get('seed'))}"
    )


def _role_crossover_block_complete(rows: list[dict[str, Any]]) -> bool:
    if len(rows) != 4:
        return False
    directions: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        directions[(
            str(row.get("strategy_a_deck") or ""),
            str(row.get("strategy_b_deck") or ""),
        )].append(row)
    return (
        len({_int(row.get("seed")) for row in rows}) == 1
        and len({_int(row.get("forced_first_player"), -1) for row in rows}) == 1
        and len(directions) == 2
        and all(
            len(direction_rows) == 2
            and {_int(row.get("seat"), -1) for row in direction_rows} == {0, 1}
            for direction_rows in directions.values()
        )
    )


def _role_crossover_scope_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    blocks: dict[str, list[dict[str, Any]]] = defaultdict(list)
    strategy_roles: dict[str, dict[str, Any]] = {
        "A": {"first_games": 0, "second_games": 0, "deck_games": {}},
        "B": {"first_games": 0, "second_games": 0, "deck_games": {}},
    }
    for row in rows:
        blocks[_role_crossover_block_key(row)].append(row)
        deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
        deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
        for strategy, deck in (("A", deck_a), ("B", deck_b)):
            deck_games = strategy_roles[strategy]["deck_games"]
            deck_games[deck] = int(deck_games.get(deck, 0)) + 1
        if bool(row.get("strategy_a_first")):
            strategy_roles["A"]["first_games"] += 1
            strategy_roles["B"]["second_games"] += 1
        else:
            strategy_roles["A"]["second_games"] += 1
            strategy_roles["B"]["first_games"] += 1

    complete_blocks = sum(
        1 for block_rows in blocks.values()
        if _role_crossover_block_complete(block_rows)
    )
    clean_blocks = sum(
        1 for block_rows in blocks.values()
        if _role_crossover_block_complete(block_rows)
        and all(_is_clean_match(row) for row in block_rows)
    )
    deck_keys = set(strategy_roles["A"]["deck_games"])
    role_balanced = (
        bool(rows)
        and complete_blocks == len(blocks)
        and strategy_roles["A"]["first_games"] == strategy_roles["A"]["second_games"]
        and strategy_roles["B"]["first_games"] == strategy_roles["B"]["second_games"]
        and all(
            strategy_roles["A"]["deck_games"].get(deck, 0)
            == strategy_roles["B"]["deck_games"].get(deck, 0)
            for deck in deck_keys
        )
    )
    point_rate = sum(_match_point(row) for row in rows) / max(1, len(rows))
    return {
        "games": len(rows),
        "blocks": len(blocks),
        "complete_blocks": complete_blocks,
        "clean_blocks": clean_blocks,
        "role_balanced": role_balanced,
        "role_crossover_adjusted_point_rate": _round(point_rate, 4),
        "role_crossover_adjusted_point_delta": _round(point_rate - 0.5, 4),
        "strategy_roles": strategy_roles,
    }


def _summarize_role_crossover(matches: list[dict[str, Any]]) -> dict[str, Any]:
    cross_rows = [
        row for row in matches if str(row.get("matchup_kind") or "") == "cross"
    ]
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in cross_rows:
        grouped[_unordered_matchup_key(
            str(row.get("strategy_a_deck") or row.get("deck") or ""),
            str(row.get("strategy_b_deck") or row.get("deck") or ""),
        )].append(row)
    return {
        "method": "same_seed_four_game_role_crossover_v1",
        "scope": "cross_matchups_only",
        "expected_games_per_block": 4,
        "overall": _role_crossover_scope_summary(cross_rows),
        "per_unordered_matchup": {
            key: _role_crossover_scope_summary(grouped[key]) for key in sorted(grouped)
        },
    }


def merge_files(input_paths: list[Path], output_path: Path, *, workers: int = 1) -> dict[str, Any]:
    shards = [json.loads(path.read_text(encoding="utf-8")) for path in input_paths]
    payload = merge_payloads(shards, workers=workers)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=1)
    args = parser.parse_args()
    try:
        payload = merge_files(args.input, args.output, workers=max(1, args.workers))
    except MergeError as exc:
        print(json.dumps({"valid": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps({"valid": True, "output": str(args.output), "games": payload["summary"]["games"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Paired statistics and promotion gates for Native Challenge Arena."""
from __future__ import annotations

import math
import random
from collections import defaultdict
from typing import Any, Callable, Iterable, Mapping, Sequence


SUMMARY_SCHEMA = "ptcg.challenge_arena.summary/2"


def _score(game: Mapping[str, Any]) -> float:
    return float(int(game.get("candidate_score_x2", 1))) / 2.0


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * max(0.0, min(1.0, percentile))
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def _strength_rows(
    games: Iterable[Mapping[str, Any]],
) -> list[Mapping[str, Any]]:
    return [row for row in games if bool(row.get("strength_eligible", True))]


def _record(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    wins = sum(int(row.get("candidate_score_x2", 1)) == 2 for row in rows)
    draws = sum(int(row.get("candidate_score_x2", 1)) == 1 for row in rows)
    losses = sum(int(row.get("candidate_score_x2", 1)) == 0 for row in rows)
    score_rate = (
        sum(_score(row) for row in rows) / len(rows) if rows else None
    )
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


def _group_records(
    rows: Sequence[Mapping[str, Any]],
    key: Callable[[Mapping[str, Any]], str],
) -> dict[str, dict[str, Any]]:
    grouped: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(key(row))].append(row)
    return {
        group: _record(grouped[group])
        for group in sorted(grouped)
    }


def paired_bootstrap_interval(
    games: Sequence[Mapping[str, Any]],
    *,
    seed: int = 20260829,
    samples: int = 2000,
    alpha: float = 0.05,
) -> dict[str, Any]:
    """Bootstrap complete matchup/seed blocks, retaining 4/8-game weights."""
    rows = _strength_rows(games)
    blocks: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for row in rows:
        fallback = "|".join((
            *sorted((
                str(row.get("candidate_deck", "")),
                str(row.get("baseline_deck", "")),
            )),
            str(int(row.get("game_seed", 0))),
        ))
        blocks[str(row.get("block_id", fallback))].append(row)
    block_values = [
        (sum(_score(row) for row in blocks[key]), len(blocks[key]))
        for key in sorted(blocks)
    ]
    if not block_values:
        return {
            "method": "paired_block_bootstrap",
            "seed": int(seed),
            "samples": int(samples),
            "alpha": float(alpha),
            "blocks": 0,
            "score_rate": None,
            "score_delta": None,
            "score_rate_ci95": [None, None],
            "score_delta_ci95": [None, None],
        }
    point = sum(total for total, _ in block_values) / sum(
        count for _, count in block_values
    )
    draws: list[float] = []
    rng = random.Random(int(seed))
    iterations = max(1, int(samples))
    for _ in range(iterations):
        sampled = [rng.choice(block_values) for _ in block_values]
        draws.append(
            sum(total for total, _ in sampled)
            / sum(count for _, count in sampled)
        )
    bounded_alpha = max(1e-6, min(0.5, float(alpha)))
    lower = _percentile(draws, bounded_alpha / 2.0)
    upper = _percentile(draws, 1.0 - bounded_alpha / 2.0)
    mean = sum(draws) / len(draws)
    variance = sum((value - mean) ** 2 for value in draws) / len(draws)
    return {
        "method": "paired_block_bootstrap",
        "seed": int(seed),
        "samples": iterations,
        "alpha": bounded_alpha,
        "blocks": len(block_values),
        "score_rate": point,
        "score_delta": point - 0.5,
        "score_rate_ci95": [lower, upper],
        "score_delta_ci95": [lower - 0.5, upper - 0.5],
        "bootstrap_distribution": {
            "mean": mean,
            "standard_deviation": math.sqrt(variance),
            "minimum": min(draws),
            "maximum": max(draws),
            "quantiles": {
                "p01": _percentile(draws, 0.01),
                "p05": _percentile(draws, 0.05),
                "p25": _percentile(draws, 0.25),
                "p50": _percentile(draws, 0.50),
                "p75": _percentile(draws, 0.75),
                "p95": _percentile(draws, 0.95),
                "p99": _percentile(draws, 0.99),
            },
        },
    }


def _agent_performance(
    games: Sequence[Mapping[str, Any]],
    prefix: str,
) -> dict[str, Any]:
    decision_samples = [
        float(sample)
        for row in games
        for sample in row.get(f"{prefix}_decision_samples_us", [])
    ]
    planner_samples = [
        float(sample)
        for row in games
        for sample in row.get(f"{prefix}_planner_samples_us", [])
    ]
    decisions = len(decision_samples)
    action_decisions = sum(
        int(row.get(f"{prefix}_action_decisions", 0)) for row in games
    )
    choice_decisions = sum(
        int(row.get(f"{prefix}_choice_decisions", 0)) for row in games
    )
    search_decisions = sum(
        int(row.get(f"{prefix}_search_decisions", 0)) for row in games
    )
    decision_us = sum(
        int(row.get(f"{prefix}_decision_us", 0)) for row in games
    )
    nodes = sum(int(row.get(f"{prefix}_nodes", 0)) for row in games)
    forced = sum(
        int(row.get(f"{prefix}_forced_tactics", 0)) for row in games
    )
    cache_hits = sum(
        int(row.get(f"{prefix}_plan_cache_hits", 0)) for row in games
    )

    def milliseconds(values: Sequence[float], percentile: float) -> float:
        return _percentile(values, percentile) / 1000.0

    return {
        "decision_count": decisions,
        "action_decision_count": action_decisions,
        "choice_decision_count": choice_decisions,
        "search_decision_count": search_decisions,
        "forced_decision_count": forced,
        "cache_decision_count": cache_hits,
        "decision_us_total": decision_us,
        "decision_ms_p50": milliseconds(decision_samples, 0.50),
        "decision_ms_p95": milliseconds(decision_samples, 0.95),
        "decision_ms_p99": milliseconds(decision_samples, 0.99),
        "planner_ms_p50": milliseconds(planner_samples, 0.50),
        "planner_ms_p95": milliseconds(planner_samples, 0.95),
        "planner_ms_p99": milliseconds(planner_samples, 0.99),
        "nodes_total": nodes,
        "nodes_per_decision": nodes / decisions if decisions else 0.0,
        "nodes_per_second": (
            nodes * 1_000_000.0 / decision_us if decision_us else 0.0
        ),
        "mandatory_tactic_rate": (
            forced / action_decisions if action_decisions else 0.0
        ),
        "plan_cache_hit_rate": (
            cache_hits / action_decisions if action_decisions else 0.0
        ),
        "average_completed_depth": (
            sum(int(row.get(f"{prefix}_completed_depth", 0)) for row in games)
            / search_decisions
            if search_decisions
            else 0.0
        ),
        "average_reply_depth": (
            sum(int(row.get(f"{prefix}_reply_depth", 0)) for row in games)
            / search_decisions
            if search_decisions
            else 0.0
        ),
        "average_belief_samples": (
            sum(int(row.get(f"{prefix}_belief_samples", 0)) for row in games)
            / search_decisions
            if search_decisions
            else 0.0
        ),
    }


def _gates(
    *,
    structural_errors: int,
    truncated_rate: float,
    score_rate: float | None,
    score_ci: Sequence[float | None],
    candidate_performance: Mapping[str, Any],
    baseline_performance: Mapping[str, Any],
    candidate_decks: Mapping[str, Mapping[str, Any]],
    truncated_rate_limit: float,
    latency_ratio_limit: float,
    min_deck_games: int,
    max_candidate_p95_ms: float | None,
) -> dict[str, Any]:
    lower = score_ci[0] if score_ci else None
    candidate_p95 = float(candidate_performance.get("decision_ms_p95", 0.0))
    baseline_p95 = float(baseline_performance.get("decision_ms_p95", 0.0))
    latency_ratio_ok = (
        candidate_p95 <= baseline_p95 * latency_ratio_limit
        if baseline_p95 > 0.0
        else candidate_p95 <= 0.0
    )
    absolute_latency_ok = (
        max_candidate_p95_ms is None
        or candidate_p95 <= float(max_candidate_p95_ms)
    )
    deck_regressions = {
        key: value
        for key, value in candidate_decks.items()
        if int(value.get("games", 0)) >= int(min_deck_games)
        and float(value.get("score_rate", 0.0)) < 0.45
    }
    regression_checks = {
        "structural_errors_zero": structural_errors == 0,
        "truncated_rate_within_limit": truncated_rate <= truncated_rate_limit,
        "score_ci_lower_above_minus_0_02": (
            lower is not None and float(lower) > 0.48
        ),
        "candidate_p95_within_ratio": latency_ratio_ok,
        "candidate_p95_within_budget": absolute_latency_ok,
    }
    promotion_checks = {
        "structural_errors_zero": structural_errors == 0,
        "truncated_rate_within_limit": truncated_rate <= truncated_rate_limit,
        "score_rate_at_least_0_53": (
            score_rate is not None and score_rate >= 0.53
        ),
        "score_ci_lower_above_0_50": (
            lower is not None and float(lower) > 0.50
        ),
        "no_candidate_deck_severe_regression": not deck_regressions,
        "candidate_p95_within_ratio": latency_ratio_ok,
        "candidate_p95_within_budget": absolute_latency_ok,
    }
    return {
        "configuration": {
            "truncated_rate_limit": truncated_rate_limit,
            "latency_ratio_limit": latency_ratio_limit,
            "minimum_deck_games": int(min_deck_games),
            "max_candidate_p95_ms": max_candidate_p95_ms,
        },
        "regression": {
            "passed": all(regression_checks.values()),
            "checks": regression_checks,
        },
        "promotion": {
            "passed": all(promotion_checks.values()),
            "checks": promotion_checks,
            "candidate_deck_regressions": deck_regressions,
        },
    }


def summarize_games(
    games: Sequence[Mapping[str, Any]],
    *,
    bootstrap_seed: int = 20260829,
    bootstrap_samples: int = 2000,
    confidence_alpha: float = 0.05,
    truncated_rate_limit: float = 0.001,
    latency_ratio_limit: float = 1.15,
    min_deck_games: int = 200,
    max_candidate_p95_ms: float | None = None,
    native_metrics: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    rows = list(games)
    strength = _strength_rows(rows)
    paired = paired_bootstrap_interval(
        strength,
        seed=bootstrap_seed,
        samples=bootstrap_samples,
        alpha=confidence_alpha,
    )
    counts = {
        "invalid_actions": sum(int(row.get("invalid_actions", 0)) for row in rows),
        "illegal_choices": sum(int(row.get("illegal_choices", 0)) for row in rows),
        "controller_failures": sum(
            int(row.get("controller_failures", 0)) for row in rows
        ),
        "rule_exceptions": sum(int(row.get("rule_exceptions", 0)) for row in rows),
        "nonterminal_games": sum(not bool(row.get("terminal", False)) for row in rows),
        "truncated_games": sum(bool(row.get("truncated", False)) for row in rows),
        "failed_games": sum(not bool(row.get("success", False)) for row in rows),
    }
    counts["unclassified_failures"] = sum(
        not bool(row.get("success", False))
        and not any(int(row.get(key, 0)) for key in (
            "invalid_actions",
            "illegal_choices",
            "controller_failures",
            "rule_exceptions",
        ))
        for row in rows
    )
    structural_errors = sum(counts[key] for key in (
        "invalid_actions",
        "illegal_choices",
        "controller_failures",
        "rule_exceptions",
        "unclassified_failures",
    ))
    candidate_decks = _group_records(
        strength, lambda row: str(row.get("candidate_deck", ""))
    )
    breakdowns = {
        "candidate_deck": candidate_decks,
        "baseline_deck": _group_records(
            strength, lambda row: str(row.get("baseline_deck", ""))
        ),
        "matchup": _group_records(
            strength,
            lambda row: (
                f"{row.get('candidate_deck', '')}__vs__"
                f"{row.get('baseline_deck', '')}"
            ),
        ),
        "candidate_turn_order": _group_records(
            strength,
            lambda row: (
                "first"
                if int(row.get("candidate_seat", 0))
                == int(row.get("first_player", 0))
                else "second"
            ),
        ),
        "candidate_seat": _group_records(
            strength, lambda row: str(int(row.get("candidate_seat", 0)))
        ),
    }
    candidate_performance = _agent_performance(rows, "candidate")
    baseline_performance = _agent_performance(rows, "baseline")
    total = len(rows)
    truncated_rate = counts["truncated_games"] / total if total else 0.0
    gates = _gates(
        structural_errors=structural_errors,
        truncated_rate=truncated_rate,
        score_rate=paired["score_rate"],
        score_ci=paired["score_rate_ci95"],
        candidate_performance=candidate_performance,
        baseline_performance=baseline_performance,
        candidate_decks=candidate_decks,
        truncated_rate_limit=float(truncated_rate_limit),
        latency_ratio_limit=float(latency_ratio_limit),
        min_deck_games=int(min_deck_games),
        max_candidate_p95_ms=max_candidate_p95_ms,
    )
    return {
        "schema": SUMMARY_SCHEMA,
        "games": total,
        "strength_games": len(strength),
        "record": _record(strength),
        "paired_statistics": paired,
        "integrity": {
            **counts,
            "structural_errors": structural_errors,
            "truncated_rate": truncated_rate,
        },
        "breakdowns": breakdowns,
        "performance": {
            "candidate": candidate_performance,
            "baseline": baseline_performance,
            "host": {
                "projection_us": sum(int(row.get("projection_us", 0)) for row in rows),
                "legal_actions_us": sum(
                    int(row.get("legal_actions_us", 0)) for row in rows
                ),
                "apply_us": sum(int(row.get("apply_us", 0)) for row in rows),
            },
        },
        "gates": gates,
        "native_metrics": dict(native_metrics or {}),
    }


def gate_status(
    summary: Mapping[str, Any],
    *,
    preset: str,
    look: int = 1,
    maximum_looks: int = 1,
    final_look: bool = True,
) -> str:
    integrity = summary["integrity"]
    if int(integrity.get("rule_exceptions", 0)) > 0 or int(
        integrity.get("unclassified_failures", 0)
    ) > 0:
        return "infrastructure_fail"
    if int(integrity.get("structural_errors", 0)) > 0:
        return "fail"
    truncated = int(integrity.get("truncated_games", 0))
    truncated_rate = float(integrity.get("truncated_rate", 0.0))
    truncated_rate_limit = float(
        summary.get("gates", {}).get("configuration", {}).get(
            "truncated_rate_limit", 0.001
        )
    )
    if preset == "release" and truncated > 0:
        return "fail"
    if preset != "release" and truncated_rate > truncated_rate_limit:
        return "fail"
    if preset in {"smoke", "focused"}:
        return "pass"
    if preset == "calibration":
        score_interval = summary["paired_statistics"].get(
            "score_rate_ci95", [None, None]
        )
        score_lower, score_upper = score_interval
        return (
            "pass"
            if score_lower is not None and score_upper is not None
            and float(score_lower) <= 0.5 <= float(score_upper)
            else "fail"
        )
    performance_ok = bool(
        summary["gates"]["regression"]["checks"].get(
            "candidate_p95_within_ratio", False
        )
    ) and bool(
        summary["gates"]["regression"]["checks"].get(
            "candidate_p95_within_budget", False
        )
    )
    if not performance_ok:
        return "fail"
    if not bool(summary.get("native_metrics", {}).get("deterministic", True)):
        return "fail"
    score_rate = summary["paired_statistics"].get("score_rate")
    interval = summary["paired_statistics"].get("score_rate_ci95", [None, None])
    lower, upper = interval
    if preset == "pr":
        return "pass" if score_rate is not None and float(score_rate) >= 0.40 else "fail"
    if preset == "nightly":
        if lower is not None and float(lower) > 0.48:
            return "pass"
        if upper is not None and float(upper) < 0.48:
            return "fail"
        return "inconclusive" if final_look or look >= maximum_looks else "continue"
    if preset == "release":
        deck_ok = bool(
            summary["gates"]["promotion"]["checks"].get(
                "no_candidate_deck_severe_regression", False
            )
        )
        if (
            score_rate is not None
            and float(score_rate) >= 0.53
            and lower is not None
            and float(lower) > 0.50
            and deck_ok
        ):
            return "pass"
        if upper is not None and float(upper) < 0.50:
            return "fail"
        return "inconclusive" if final_look or look >= maximum_looks else "continue"
    raise ValueError(f"unknown_challenge_arena_preset:{preset}")

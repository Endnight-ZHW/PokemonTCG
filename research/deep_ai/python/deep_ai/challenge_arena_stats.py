"""Fair paired statistics and promotion gates for Native Challenge Arena."""
from __future__ import annotations

from typing import Any, Mapping, Sequence

from .evaluation_fairness import (
    complete_strength_blocks,
    paired_block_bootstrap_interval,
    percentile as _percentile,
    record as _record,
    standard_breakdowns,
)

SUMMARY_SCHEMA = "ptcg.challenge_arena.summary/3"


def paired_bootstrap_interval(
    games: Sequence[Mapping[str, Any]],
    *,
    seed: int = 20260829,
    samples: int = 2000,
    alpha: float = 0.05,
) -> dict[str, Any]:
    return paired_block_bootstrap_interval(
        games,
        seed=seed,
        samples=samples,
        alpha=alpha,
    )


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
    deck_inspections = sum(
        int(row.get(f"{prefix}_deck_inspections", 0)) for row in games
    )
    inspection_memory_decisions = sum(
        int(row.get(f"{prefix}_inspection_memory_decisions", 0))
        for row in games
    )

    def milliseconds(values: Sequence[float], percentile: float) -> float:
        return _percentile(values, percentile) / 1000.0

    latency_by_origin: dict[str, dict[str, Any]] = {}
    for origin in ("search", "forced", "cache", "choice"):
        samples = [
            float(sample)
            for row in games
            for sample in row.get(
                f"{prefix}_{origin}_decision_samples_us", []
            )
        ]
        latency_by_origin[origin] = {
            "decision_count": len(samples),
            "decision_ms_p50": milliseconds(samples, 0.50),
            "decision_ms_p95": milliseconds(samples, 0.95),
            "decision_ms_p99": milliseconds(samples, 0.99),
        }

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
        "deck_inspection_count": deck_inspections,
        "inspection_memory_decision_count": inspection_memory_decisions,
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
        "latency_by_origin": latency_by_origin,
    }


def _gates(
    *,
    structural_errors: int,
    truncated_rate: float,
    score_rate: float | None,
    score_ci: Sequence[float | None],
    candidate_decks: Mapping[str, Mapping[str, Any]],
    truncated_rate_limit: float,
    min_deck_games: int,
) -> dict[str, Any]:
    lower = score_ci[0] if score_ci else None
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
    }
    return {
        "configuration": {
            "truncated_rate_limit": truncated_rate_limit,
            "minimum_deck_games": int(min_deck_games),
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


def _performance_advisory(
    candidate: Mapping[str, Any],
    baseline: Mapping[str, Any],
    *,
    latency_ratio_limit: float,
    max_candidate_p95_ms: float | None,
) -> dict[str, Any]:
    candidate_search = candidate.get("latency_by_origin", {}).get("search", {})
    baseline_search = baseline.get("latency_by_origin", {}).get("search", {})
    candidate_p95 = float(candidate_search.get(
        "decision_ms_p95", candidate.get("decision_ms_p95", 0.0)
    ))
    baseline_p95 = float(baseline_search.get(
        "decision_ms_p95", baseline.get("decision_ms_p95", 0.0)
    ))
    ratio = candidate_p95 / baseline_p95 if baseline_p95 > 0.0 else None
    reasons: list[str] = []
    if ratio is not None and ratio > float(latency_ratio_limit):
        reasons.append("candidate_search_p95_ratio_above_advisory_limit")
    if (
        max_candidate_p95_ms is not None
        and candidate_p95 > float(max_candidate_p95_ms)
    ):
        reasons.append("candidate_search_p95_above_advisory_budget")
    return {
        "status": "warn" if reasons else "ok",
        "gating": False,
        "metric": "search_decision_wall_clock_p95_ms",
        "candidate_p95_ms": candidate_p95,
        "baseline_p95_ms": baseline_p95,
        "candidate_to_baseline_ratio": ratio,
        "latency_ratio_advisory_limit": float(latency_ratio_limit),
        "max_candidate_p95_ms_advisory": max_candidate_p95_ms,
        "reasons": reasons,
        "caveat": (
            "Wall-clock latency is host, load, scheduler and hardware dependent; "
            "it is diagnostic only and never changes strength gate status."
        ),
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
    strength, block_selection = complete_strength_blocks(rows)
    paired = paired_bootstrap_interval(
        rows,
        seed=bootstrap_seed,
        samples=bootstrap_samples,
        alpha=confidence_alpha,
    )
    persistent_timeout_rows = [
        row for row in rows if bool(row.get("persistent_timeout", False))
    ]
    recovered_timeout_rows = [
        row for row in rows if bool(row.get("recovered_timeout", False))
    ]
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
        "persistent_timeout_games": len(persistent_timeout_rows),
        "recovered_timeout_games": len(recovered_timeout_rows),
    }
    counts["unclassified_failures"] = sum(
        not bool(row.get("success", False))
        and not bool(row.get("persistent_timeout", False))
        and not any(int(row.get(key, 0)) for key in (
            "invalid_actions",
            "illegal_choices",
            "controller_failures",
            "rule_exceptions",
        ))
        for row in rows
    )
    structural_controller_failures = sum(
        int(row.get("controller_failures", 0))
        for row in rows
        if not bool(row.get("persistent_timeout", False))
    )
    structural_errors = (
        counts["invalid_actions"]
        + counts["illegal_choices"]
        + structural_controller_failures
        + counts["rule_exceptions"]
        + counts["unclassified_failures"]
    )
    breakdowns = standard_breakdowns(strength)
    candidate_decks = breakdowns["candidate_deck"]
    candidate_performance = _agent_performance(rows, "candidate")
    baseline_performance = _agent_performance(rows, "baseline")
    total = len(rows)
    truncated_rate = counts["truncated_games"] / total if total else 0.0
    gates = _gates(
        structural_errors=structural_errors,
        truncated_rate=truncated_rate,
        score_rate=paired["score_rate"],
        score_ci=paired["score_rate_ci"],
        candidate_decks=candidate_decks,
        truncated_rate_limit=float(truncated_rate_limit),
        min_deck_games=int(min_deck_games),
    )
    performance_advisory = _performance_advisory(
        candidate_performance,
        baseline_performance,
        latency_ratio_limit=float(latency_ratio_limit),
        max_candidate_p95_ms=max_candidate_p95_ms,
    )
    reliability = {
        "passed": not persistent_timeout_rows,
        "persistent_timeout_games": len(persistent_timeout_rows),
        "recovered_timeout_games": len(recovered_timeout_rows),
        "persistent_timeout_task_ids": sorted(
            str(row.get("task_id", "")) for row in persistent_timeout_rows
        ),
        "recovered_timeout_task_ids": sorted(
            str(row.get("task_id", "")) for row in recovered_timeout_rows
        ),
    }
    return {
        "schema": SUMMARY_SCHEMA,
        "games": total,
        "strength_games": len(strength),
        "record": _record(strength),
        "paired_statistics": paired,
        "integrity": {
            **counts,
            "structural_errors": structural_errors,
            "structural_controller_failures": structural_controller_failures,
            "truncated_rate": truncated_rate,
            "strength_blocks": block_selection,
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
        "performance_advisory": performance_advisory,
        "reliability": reliability,
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
    if not bool(summary.get("reliability", {}).get("passed", True)):
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
            "score_rate_ci", [None, None]
        )
        score_lower, score_upper = score_interval
        return (
            "pass"
            if score_lower is not None and score_upper is not None
            and float(score_lower) <= 0.5 <= float(score_upper)
            else "fail"
        )
    if not bool(summary.get("native_metrics", {}).get("deterministic", True)):
        return "fail"
    score_rate = summary["paired_statistics"].get("score_rate")
    interval = summary["paired_statistics"].get("score_rate_ci", [None, None])
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

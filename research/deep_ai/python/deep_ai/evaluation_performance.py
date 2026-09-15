"""Challenge search throughput and latency; never used for promotion decisions."""
from __future__ import annotations
from typing import Any, Mapping, Sequence
from .evaluation_fairness import percentile as _percentile


def agent_performance(
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


def performance_advisory(
    candidate: Mapping[str, Any],
    baseline: Mapping[str, Any],
    *,
    latency_ratio_limit: float,
    max_candidate_p95_ms: float | None,
) -> dict[str, Any]:
    candidate_p95 = float(candidate["latency_by_origin"]["search"]["decision_ms_p95"])
    baseline_p95 = float(baseline["latency_by_origin"]["search"]["decision_ms_p95"])
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

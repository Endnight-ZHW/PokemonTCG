"""Validate Godot traditional-AI evaluation results against optimization gates."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


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


def _diagnostics(summary: dict[str, Any]) -> int:
    return sum(
        _int(summary.get(key))
        for key in ("invalid_actions", "choice_failures", "rule_exceptions")
    )


def _strategies_equal(payload: dict[str, Any]) -> bool:
    fingerprint = payload.get("strategy_fingerprint") or {}
    if isinstance(fingerprint, dict) and fingerprint.get("equal") is not None:
        return bool(fingerprint.get("equal"))
    return (payload.get("strategies") or {}).get("A") == (payload.get("strategies") or {}).get("B")


def _normalized_gate(payload: dict[str, Any], gate: str) -> str:
    normalized = gate.lower().replace("_", "-")
    if normalized == "stability":
        return "nightly-stability"
    if normalized == "strength":
        return "nightly-strength"
    if normalized == "equivalence":
        return "nightly-equivalence"
    if normalized == "deep":
        return "deep-practical"
    if normalized == "nightly":
        return "nightly-strength"
    if normalized == "auto":
        if payload.get("self_check") or _strategies_equal(payload):
            return "nightly-stability"
        return "nightly-strength"
    return normalized


def _decision_diagnostic_total(payload: dict[str, Any]) -> int:
    diagnostics = payload.get("decision_diagnostics") or {}
    if isinstance(diagnostics, dict):
        return _int(diagnostics.get("total"))
    return 0


def _decision_diagnostic_regression(payload: dict[str, Any]) -> int | None:
    diagnostics = payload.get("decision_diagnostics") or {}
    if not isinstance(diagnostics, dict):
        return None
    if "by_strategy" not in diagnostics:
        return None
    by_strategy = diagnostics.get("by_strategy") or {}
    if not isinstance(by_strategy, dict):
        return None
    delta = by_strategy.get("delta") or {}
    if isinstance(delta, dict) and delta.get("total") is not None:
        return _int(delta.get("total"))
    left = by_strategy.get("A") or {}
    right = by_strategy.get("B") or {}
    if isinstance(left, dict) and isinstance(right, dict):
        return _int(left.get("total")) - _int(right.get("total"))
    return None


def _golden_failures(payload: dict[str, Any]) -> int:
    golden = payload.get("golden_scenarios") or {}
    if isinstance(golden, dict):
        return _int(golden.get("failed"))
    return 0


def validate_evaluation_gate(
    payload: dict[str, Any],
    *,
    gate: str = "nightly",
    baseline: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return a machine-readable pass/fail result for Quick or Nightly gates."""
    summary = payload.get("summary") or {}
    per_deck = payload.get("per_deck") or {}
    normalized_gate = _normalized_gate(payload, gate)
    errors: list[str] = []

    if _diagnostics(summary) != 0:
        errors.append("diagnostics_nonzero")

    games = max(1, _int(summary.get("games")))
    max_action_rate = _float(
        summary.get("max_action_exhaustion_rate"),
        _float(summary.get("max_actions_exhaustions")) / games,
    )
    if max_action_rate > 0.01:
        errors.append("max_action_exhaustion_rate")
    if _float(summary.get("time_capped_decision_rate")) > 0.0:
        errors.append("time_capped_decision_rate")

    if normalized_gate in {
        "nightly-stability",
        "nightly-strength",
        "nightly-equivalence",
        "deep-practical",
    }:
        if _float(summary.get("completion_rate"), 1.0) < 0.95:
            errors.append("completion_rate")
        if normalized_gate == "nightly-stability" and _decision_diagnostic_total(payload) != 0:
            errors.append("decision_diagnostics_nonzero")
        if _golden_failures(payload) != 0:
            errors.append("golden_scenarios_failed")

    if normalized_gate == "quick":
        if _float(summary.get("paired_point_delta")) <= 0.0:
            errors.append("paired_delta_not_positive")
    elif normalized_gate == "nightly-stability":
        pass
    elif normalized_gate == "nightly-equivalence":
        diagnostic_delta = _decision_diagnostic_regression(payload)
        if diagnostic_delta is None:
            if _decision_diagnostic_total(payload) != 0:
                errors.append("decision_diagnostics_nonzero")
        elif diagnostic_delta > 0:
            errors.append("decision_diagnostics_regression")
        interval = summary.get("paired_delta_ci95") or {}
        if _float(interval.get("lower") if isinstance(interval, dict) else None) < -0.02:
            errors.append("paired_delta_ci_below_equivalence_floor")
        for deck_key, stats in per_deck.items():
            if _float((stats or {}).get("paired_point_delta")) < -0.04:
                errors.append(f"{deck_key}:paired_delta_below_equivalence_floor")
        for matchup_key, stats in (payload.get("per_matchup") or {}).items():
            if _float((stats or {}).get("paired_point_delta")) < -0.08:
                errors.append(f"{matchup_key}:paired_delta_below_equivalence_floor")
    elif normalized_gate == "nightly-strength":
        if payload.get("self_check") or _strategies_equal(payload):
            errors.append("strength_gate_requires_distinct_strategies")
        diagnostic_delta = _decision_diagnostic_regression(payload)
        if diagnostic_delta is None:
            if _decision_diagnostic_total(payload) != 0:
                errors.append("decision_diagnostics_nonzero")
        elif diagnostic_delta > 0:
            errors.append("decision_diagnostics_regression")
        interval = summary.get("paired_delta_ci95") or {}
        if _float(interval.get("lower") if isinstance(interval, dict) else None) <= 0.0:
            errors.append("paired_delta_ci_not_positive")
        if _float(summary.get("probability_a_better"), 0.0) < 0.95:
            errors.append("probability_a_better")
        for deck_key, stats in per_deck.items():
            if _float((stats or {}).get("paired_point_delta")) < -0.03:
                errors.append(f"{deck_key}:paired_delta_below_floor")
        for matchup_key, stats in (payload.get("per_matchup") or {}).items():
            if _float((stats or {}).get("paired_point_delta")) < -0.08:
                errors.append(f"{matchup_key}:paired_delta_below_floor")
        if baseline is not None:
            baseline_summary = baseline.get("summary") or {}
            baseline_p95 = _float(baseline_summary.get("decision_ms_p95"))
            candidate_p95 = _float(summary.get("decision_ms_p95"))
            if baseline_p95 > 0.0 and candidate_p95 > baseline_p95 * 1.25:
                errors.append("decision_ms_p95_regression")
    elif normalized_gate == "deep-practical":
        if payload.get("self_check") or _strategies_equal(payload):
            errors.append("deep_gate_requires_distinct_strategies")
        diagnostic_delta = _decision_diagnostic_regression(payload)
        if diagnostic_delta is None:
            if _decision_diagnostic_total(payload) != 0:
                errors.append("decision_diagnostics_nonzero")
        elif diagnostic_delta > 0:
            errors.append("decision_diagnostics_regression")
        if _float(summary.get("decision_ms_p95")) > 2000.0:
            errors.append("decision_ms_p95_latency")
        if _float(summary.get("deep_fallback_rate")) > 0.0:
            errors.append("deep_fallback_rate")
        interval = summary.get("paired_delta_ci95") or {}
        if _float(interval.get("lower") if isinstance(interval, dict) else None) < -0.04:
            errors.append("paired_delta_ci_below_practical_floor")
        for deck_key, stats in per_deck.items():
            if _float((stats or {}).get("paired_point_delta")) < -0.08:
                errors.append(f"{deck_key}:paired_delta_below_practical_floor")
    else:
        errors.append("unknown_gate")

    return {
        "valid": not errors,
        "gate": normalized_gate,
        "errors": errors,
        "games": _int(summary.get("games")),
        "paired_point_delta": _float(summary.get("paired_point_delta")),
        "probability_a_better": _float(summary.get("probability_a_better")),
        "max_action_exhaustion_rate": max_action_rate,
        "time_capped_decision_rate": _float(summary.get("time_capped_decision_rate")),
        "decision_ms_p95": _float(summary.get("decision_ms_p95")),
        "deep_fallback_rate": _float(summary.get("deep_fallback_rate")),
        "completion_rate": _float(summary.get("completion_rate")),
        "decision_diagnostics": _decision_diagnostic_total(payload),
        "decision_diagnostic_delta": _decision_diagnostic_regression(payload),
        "golden_failures": _golden_failures(payload),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument(
        "--gate",
        choices=[
            "quick",
            "nightly",
            "nightly-stability",
            "nightly-strength",
            "nightly-equivalence",
            "deep-practical",
            "stability",
            "strength",
            "equivalence",
            "deep",
            "auto",
        ],
        default="nightly-strength",
    )
    args = parser.parse_args()

    payload = json.loads(args.input.read_text(encoding="utf-8"))
    baseline = (
        json.loads(args.baseline.read_text(encoding="utf-8"))
        if args.baseline is not None
        else None
    )
    result = validate_evaluation_gate(payload, gate=args.gate, baseline=baseline)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

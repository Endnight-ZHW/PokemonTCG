"""Validate Godot traditional-AI evaluation results against optimization gates."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


PERFORMANCE_THRESHOLDS_MS = {
    "windows": {
        "decision_ms_p95": 900.0,
        "cache_hit_decision_ms_p95": 100.0,
        "ai_turn_ms_p95": 1500.0,
    },
    "android": {
        "decision_ms_p95": 1000.0,
        "cache_hit_decision_ms_p95": 200.0,
        "ai_turn_ms_p95": 2000.0,
    },
}

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


def _finite_number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(max(0.0, min(1.0, pct)) * (len(ordered) - 1))
    return ordered[index]


def _append_error(errors: list[str], error: str) -> None:
    if error not in errors:
        errors.append(error)


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
    if normalized == "equivalence":
        return "nightly-equivalence"
    if normalized == "deep":
        return "deep-practical"
    if normalized == "nightly":
        return "nightly-stability"
    if normalized == "auto":
        if payload.get("self_check") or _strategies_equal(payload):
            return "nightly-stability"
        return "nightly-equivalence"
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
    platform: str | None = None,
) -> dict[str, Any]:
    """Return a machine-readable pass/fail result for Quick or Nightly gates."""
    summary = payload.get("summary") or {}
    per_deck = payload.get("per_deck") or {}
    normalized_gate = _normalized_gate(payload, gate)
    errors: list[str] = []
    payload_platform = payload.get("platform")
    config_platform = (payload.get("config") or {}).get("platform")
    if (
        payload_platform is not None
        and config_platform is not None
        and str(payload_platform).lower() != str(config_platform).lower()
    ):
        errors.append("platform_mismatch")
    configured_platform = payload_platform or config_platform
    normalized_platform = str(platform or configured_platform or "windows").lower()
    if normalized_platform not in PERFORMANCE_THRESHOLDS_MS:
        errors.append("platform")
        normalized_platform = "windows"
    latency_thresholds = PERFORMANCE_THRESHOLDS_MS[normalized_platform]
    performance_gate_scope = "overall"
    performance_gate_metrics_ms = {
        metric_key: _float(summary.get(metric_key))
        for metric_key in latency_thresholds
    }
    schema_version = _int(payload.get("schema_version"))
    if schema_version >= 3:
        rules_options = (payload.get("config") or {}).get("rules_options")
        if (
            not isinstance(rules_options, dict)
            or rules_options.get("apply_type_matchups") is not False
        ):
            errors.append("rules_options")
        fingerprint_rules = (payload.get("strategy_fingerprint") or {}).get(
            "rules_options"
        )
        if (
            not isinstance(fingerprint_rules, dict)
            or fingerprint_rules.get("apply_type_matchups") is not False
        ):
            errors.append("fingerprint_rules_options")
    if schema_version >= 4:
        if (payload.get("config") or {}).get("decision_latency_sampling") != "per_decision":
            errors.append("decision_latency_sampling")
        if (
            (payload.get("config") or {}).get("ai_turn_latency_sampling")
            != "completed_turn_wall_clock"
        ):
            errors.append("ai_turn_latency_sampling")
        matches = payload.get("matches")
        decision_samples: list[float] = []
        cache_hit_decision_samples: list[float] = []
        ai_turn_samples: list[float] = []
        strategy_decision_samples: dict[str, list[float]] = {"A": [], "B": []}
        strategy_cache_hit_samples: dict[str, list[float]] = {"A": [], "B": []}
        strategy_ai_turn_samples: dict[str, list[float]] = {"A": [], "B": []}
        strategy_rows_present = 0
        strategy_rows_complete = 0
        strategy_rows_valid = 0
        strategy_rows_missing = 0
        if not isinstance(matches, list):
            _append_error(errors, "decision_latency_samples_missing")
            _append_error(errors, "turn_plan_cache_hit_samples_missing")
            _append_error(errors, "ai_turn_latency_samples_missing")
            matches = []
        for row in matches:
            if not isinstance(row, dict):
                _append_error(errors, "decision_latency_samples_missing")
                _append_error(errors, "turn_plan_cache_hit_samples_missing")
                _append_error(errors, "ai_turn_latency_samples_missing")
                strategy_rows_missing += 1
                continue

            raw_decisions = row.get("decision_ms_samples")
            row_decisions: list[float] = []
            if not isinstance(raw_decisions, list):
                _append_error(errors, "decision_latency_samples_missing")
            else:
                for value in raw_decisions:
                    sample = _finite_number(value)
                    if sample is None or sample < 0.0:
                        _append_error(errors, "decision_latency_samples_invalid")
                        continue
                    row_decisions.append(sample)
                    decision_samples.append(sample)
                if len(raw_decisions) != _int(row.get("decisions")) + _int(row.get("choices")):
                    _append_error(errors, "decision_latency_row_sample_count")

            raw_cache_hits = row.get("turn_plan_cache_hit_samples")
            if not isinstance(raw_cache_hits, list):
                _append_error(errors, "turn_plan_cache_hit_samples_missing")
            elif not isinstance(raw_decisions, list) or len(raw_cache_hits) != len(raw_decisions):
                _append_error(errors, "turn_plan_cache_hit_sample_count")
            elif any(not isinstance(value, bool) for value in raw_cache_hits):
                _append_error(errors, "turn_plan_cache_hit_samples_invalid")
            elif len(row_decisions) == len(raw_decisions):
                cache_hit_decision_samples.extend(
                    sample
                    for sample, cache_hit in zip(row_decisions, raw_cache_hits)
                    if cache_hit
                )

            raw_ai_turns = row.get("ai_turn_ms_samples")
            row_ai_turns: list[float] = []
            if not isinstance(raw_ai_turns, list):
                _append_error(errors, "ai_turn_latency_samples_missing")
            else:
                for value in raw_ai_turns:
                    sample = _finite_number(value)
                    if sample is None or sample < 0.0:
                        _append_error(errors, "ai_turn_latency_samples_invalid")
                        continue
                    row_ai_turns.append(sample)
                    ai_turn_samples.append(sample)

            strategy_field_names = (
                "decision_ms_samples_by_strategy",
                "turn_plan_cache_hit_samples_by_strategy",
                "ai_turn_ms_samples_by_strategy",
            )
            strategy_field_presence = [name in row for name in strategy_field_names]
            if not any(strategy_field_presence):
                strategy_rows_missing += 1
                continue
            strategy_rows_present += 1
            if not all(strategy_field_presence):
                _append_error(errors, "strategy_latency_samples_incomplete")
                continue
            strategy_rows_complete += 1
            raw_strategy_decisions = row.get("decision_ms_samples_by_strategy")
            raw_strategy_cache_hits = row.get(
                "turn_plan_cache_hit_samples_by_strategy"
            )
            raw_strategy_ai_turns = row.get("ai_turn_ms_samples_by_strategy")
            if not all(
                isinstance(value, dict)
                for value in (
                    raw_strategy_decisions,
                    raw_strategy_cache_hits,
                    raw_strategy_ai_turns,
                )
            ):
                _append_error(errors, "strategy_latency_samples_invalid")
                continue

            row_strategy_decision_pairs: list[tuple[float, bool]] = []
            row_strategy_ai_turns: list[float] = []
            row_strategy_valid = True
            for strategy_key in ("A", "B"):
                raw_values = raw_strategy_decisions.get(strategy_key)
                raw_flags = raw_strategy_cache_hits.get(strategy_key)
                raw_turn_values = raw_strategy_ai_turns.get(strategy_key)
                if not isinstance(raw_values, list) or not isinstance(raw_flags, list):
                    _append_error(errors, "strategy_decision_latency_samples_invalid")
                    row_strategy_valid = False
                    continue
                if len(raw_values) != len(raw_flags):
                    _append_error(errors, "strategy_cache_hit_sample_count")
                    row_strategy_valid = False
                    continue
                if any(not isinstance(value, bool) for value in raw_flags):
                    _append_error(errors, "strategy_cache_hit_samples_invalid")
                    row_strategy_valid = False
                    continue
                parsed_values: list[float] = []
                for value in raw_values:
                    sample = _finite_number(value)
                    if sample is None or sample < 0.0:
                        _append_error(errors, "strategy_decision_latency_samples_invalid")
                        row_strategy_valid = False
                        continue
                    parsed_values.append(sample)
                if not isinstance(raw_turn_values, list):
                    _append_error(errors, "strategy_ai_turn_latency_samples_invalid")
                    row_strategy_valid = False
                    continue
                parsed_turn_values: list[float] = []
                for value in raw_turn_values:
                    sample = _finite_number(value)
                    if sample is None or sample < 0.0:
                        _append_error(errors, "strategy_ai_turn_latency_samples_invalid")
                        row_strategy_valid = False
                        continue
                    parsed_turn_values.append(sample)
                if len(parsed_values) != len(raw_values):
                    continue
                strategy_decision_samples[strategy_key].extend(parsed_values)
                strategy_cache_hit_samples[strategy_key].extend(
                    sample
                    for sample, cache_hit in zip(parsed_values, raw_flags)
                    if cache_hit
                )
                strategy_ai_turn_samples[strategy_key].extend(parsed_turn_values)
                row_strategy_decision_pairs.extend(zip(parsed_values, raw_flags))
                row_strategy_ai_turns.extend(parsed_turn_values)
            if row_strategy_valid:
                if (
                    not isinstance(raw_decisions, list)
                    or len(row_decisions) != len(raw_decisions)
                    or not isinstance(raw_cache_hits, list)
                    or len(raw_cache_hits) != len(row_decisions)
                    or any(not isinstance(value, bool) for value in raw_cache_hits)
                    or sorted(row_strategy_decision_pairs)
                    != sorted(zip(row_decisions, raw_cache_hits))
                ):
                    _append_error(errors, "strategy_decision_latency_samples_mismatch")
                    row_strategy_valid = False
                if sorted(row_strategy_ai_turns) != sorted(row_ai_turns):
                    _append_error(errors, "strategy_ai_turn_latency_samples_mismatch")
                    row_strategy_valid = False
            if row_strategy_valid:
                strategy_rows_valid += 1

        strategy_latency_available = (
            bool(matches)
            and strategy_rows_complete == len(matches)
            and strategy_rows_valid == len(matches)
            and strategy_rows_missing == 0
        )
        if strategy_rows_present > 0 and strategy_rows_missing > 0:
            _append_error(errors, "strategy_latency_samples_coverage")

        sample_sets = (
            (
                "decision",
                decision_samples,
                "decision_ms_sample_count",
                "decision_ms_p95",
            ),
            (
                "cache_hit_decision",
                cache_hit_decision_samples,
                "cache_hit_decision_ms_sample_count",
                "cache_hit_decision_ms_p95",
            ),
            (
                "ai_turn",
                ai_turn_samples,
                "ai_turn_ms_sample_count",
                "ai_turn_ms_p95",
            ),
        )
        for label, samples, count_key, metric_key in sample_sets:
            if not samples:
                _append_error(errors, f"{label}_latency_samples_missing")
            if count_key not in summary or _int(summary.get(count_key), -1) != len(samples):
                _append_error(errors, f"{label}_latency_sample_count")
            metric = _finite_number(summary.get(metric_key))
            if metric is None or metric < 0.0:
                _append_error(errors, f"{metric_key}_missing")
                continue
            if samples and abs(metric - round(_percentile(samples, 0.95), 3)) > 0.0011:
                _append_error(errors, f"{metric_key}_mismatch")

        if strategy_latency_available:
            performance_by_strategy = payload.get("performance_by_strategy")
            if not isinstance(performance_by_strategy, dict) or not bool(
                performance_by_strategy.get("available")
            ):
                _append_error(errors, "performance_by_strategy_missing")
            else:
                strategy_sample_sets = {
                    strategy_key: (
                        (
                            "decision_ms_sample_count",
                            "decision_ms_p95",
                            strategy_decision_samples[strategy_key],
                        ),
                        (
                            "cache_hit_decision_ms_sample_count",
                            "cache_hit_decision_ms_p95",
                            strategy_cache_hit_samples[strategy_key],
                        ),
                        (
                            "ai_turn_ms_sample_count",
                            "ai_turn_ms_p95",
                            strategy_ai_turn_samples[strategy_key],
                        ),
                    )
                    for strategy_key in ("A", "B")
                }
                for strategy_key, strategy_sets in strategy_sample_sets.items():
                    reported = performance_by_strategy.get(strategy_key)
                    if not isinstance(reported, dict):
                        _append_error(errors, f"performance_by_strategy_{strategy_key}_missing")
                        continue
                    for count_key, metric_key, samples in strategy_sets:
                        if _int(reported.get(count_key), -1) != len(samples):
                            _append_error(
                                errors,
                                f"performance_by_strategy_{strategy_key}_{count_key}_mismatch",
                            )
                        metric = _finite_number(reported.get(metric_key))
                        if metric is None or metric < 0.0:
                            _append_error(
                                errors,
                                f"performance_by_strategy_{strategy_key}_{metric_key}_missing",
                            )
                        elif abs(
                            metric - round(_percentile(samples, 0.95), 3)
                        ) > 0.0011:
                            _append_error(
                                errors,
                                f"performance_by_strategy_{strategy_key}_{metric_key}_mismatch",
                            )

        for metric_key, threshold in latency_thresholds.items():
            metric = _finite_number(performance_gate_metrics_ms.get(metric_key))
            if metric is not None and metric > threshold:
                _append_error(errors, f"{metric_key}_latency")

    if _diagnostics(summary) != 0:
        errors.append("diagnostics_nonzero")

    games = max(1, _int(summary.get("games")))
    max_action_rate = _float(
        summary.get("max_action_exhaustion_rate"),
        _float(summary.get("max_actions_exhaustions")) / games,
    )
    if max_action_rate > 0.01:
        errors.append("max_action_exhaustion_rate")

    if normalized_gate in {
        "nightly-stability",
        "nightly-equivalence",
        "deep-practical",
    }:
        if _float(summary.get("completion_rate"), 1.0) < 0.95:
            errors.append("completion_rate")
        if normalized_gate == "nightly-stability":
            diagnostic_delta = _decision_diagnostic_regression(payload)
            if payload.get("self_check") or _strategies_equal(payload):
                if diagnostic_delta is None:
                    if _decision_diagnostic_total(payload) != 0:
                        errors.append("decision_diagnostics_nonzero")
                elif diagnostic_delta != 0:
                    errors.append("decision_diagnostics_nonzero")
            elif _decision_diagnostic_total(payload) != 0:
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
    elif normalized_gate == "deep-practical":
        if payload.get("self_check") or _strategies_equal(payload):
            errors.append("deep_gate_requires_distinct_strategies")
        diagnostic_delta = _decision_diagnostic_regression(payload)
        if diagnostic_delta is None:
            if _decision_diagnostic_total(payload) != 0:
                errors.append("decision_diagnostics_nonzero")
        elif diagnostic_delta > 0:
            errors.append("decision_diagnostics_regression")
        if schema_version < 4 and _float(summary.get("decision_ms_p95")) > 2000.0:
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
        "platform": normalized_platform,
        "latency_thresholds_ms": latency_thresholds,
        "performance_gate_scope": performance_gate_scope,
        "performance_gate_metrics_ms": performance_gate_metrics_ms,
        "errors": errors,
        "games": _int(summary.get("games")),
        "paired_point_delta": _float(summary.get("paired_point_delta")),
        "probability_a_better": _float(summary.get("probability_a_better")),
        "max_action_exhaustion_rate": max_action_rate,
        "time_capped_decision_rate": _float(summary.get("time_capped_decision_rate")),
        "decision_ms_p95": _float(summary.get("decision_ms_p95")),
        "cache_hit_decision_ms_p95": _float(summary.get("cache_hit_decision_ms_p95")),
        "ai_turn_ms_p95": _float(summary.get("ai_turn_ms_p95")),
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
    parser.add_argument("--platform", choices=sorted(PERFORMANCE_THRESHOLDS_MS))
    parser.add_argument(
        "--gate",
        choices=[
            "quick",
            "nightly",
            "nightly-stability",
            "nightly-equivalence",
            "deep-practical",
            "stability",
            "equivalence",
            "deep",
            "auto",
        ],
        default="nightly-stability",
    )
    args = parser.parse_args()

    payload = json.loads(args.input.read_text(encoding="utf-8"))
    baseline = (
        json.loads(args.baseline.read_text(encoding="utf-8"))
        if args.baseline is not None
        else None
    )
    result = validate_evaluation_gate(
        payload,
        gate=args.gate,
        baseline=baseline,
        platform=args.platform,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

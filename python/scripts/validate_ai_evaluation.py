"""Validate schema-v5 Godot traditional-AI evaluation evidence."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

try:
    from scripts.ai_evaluation_v5 import (
        DECK_ORDER,
        SCHEMA_VERSION,
        summarize_performance,
        summarize_search_depth,
    )
except ModuleNotFoundError:  # Direct script execution.
    from ai_evaluation_v5 import (  # type: ignore[no-redef]
        DECK_ORDER,
        SCHEMA_VERSION,
        summarize_performance,
        summarize_search_depth,
    )


SUPPORTED_PLATFORMS = {"windows", "android"}
SEARCH_DEPTH_THRESHOLDS = {
    "full_tier_requested_depth_min": 6.0,
    "full_tier_reached_depth_p50_min": 3.0,
    "full_tier_reached_depth_p95_min": 5.0,
    "a_vs_b_allowed_depth_deficit": 0.5,
}


ERROR_MESSAGES = {
    "schema_version": "结果不是 AI 评测 schema v5。",
    "artifact_kind": "输入不是已聚合的 AI 评测结果。",
    "provenance_missing": "缺少可复现来源指纹。",
    "platform_unsupported": "评测平台不是受支持的 Windows 或 Android。",
    "nightly_config": "Nightly 配置不是固定的 10 牌组、seed 17、50/10 区块。",
    "coverage_incomplete": "比赛覆盖不完整或包含意外比赛。",
    "experimental_unit_incomplete": "存在不完整的两局镜像对或四局角色交叉块。",
    "dirty_games": "存在非正常终局、非法动作、Choice/规则异常或动作上限耗尽。",
    "fairness_unbalanced": "玩家编号、先后手或牌组角色分配不平衡。",
    "behavior_missing": "行为画像埋点不完整。",
    "golden_scenarios_missing": "金标场景集合不完整。",
    "golden_scenarios_failed": "至少一个金标场景失败。",
    "search_depth_probe_missing": "缺少单进程搜索深度探针。",
    "search_depth_probe_coverage": "搜索深度探针不是 20 局预热加 40 局采样的固定结构。",
    "search_depth_probe_metrics": "搜索深度样本或聚合指标无效。",
    "search_depth_requested_below_floor": "策略配置的全预算搜索深度低于发布下限。",
    "search_depth_below_floor": "策略实际达到的搜索深度分位数低于发布下限。",
    "search_depth_regression": "候选策略的搜索深度低于对照策略。",
    "strategy_relation": "策略指纹关系与所选门禁不符。",
    "mirror_ci_below_floor": "镜像强度 95% 区间下界低于允许值。",
    "cross_ci_below_floor": "角色交叉强度 95% 区间下界低于允许值。",
    "decision_diagnostics_regression": "候选策略的决策错因多于对照策略。",
    "decision_diagnostics_unbalanced": "同策略稳定性评测的 A/B 决策错因计数不平衡。",
    "deep_fallback_rate": "Deep 评测发生了回退。",
}


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return default


def _float(value: Any, default: float | None = 0.0) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return default
    return result if math.isfinite(result) else default


def _strategies_equal(payload: dict[str, Any]) -> bool:
    fingerprint = payload.get("strategy_fingerprint") or {}
    if isinstance(fingerprint, dict) and fingerprint.get("equal") is not None:
        return bool(fingerprint.get("equal"))
    strategies = payload.get("strategies") or {}
    return strategies.get("A") == strategies.get("B")


def _normalized_gate(payload: dict[str, Any], gate: str) -> str:
    normalized = gate.lower().replace("_", "-")
    aliases = {
        "stability": "nightly-stability",
        "equivalence": "nightly-equivalence",
        "nightly": "nightly-stability",
        "deep": "deep-practical",
    }
    normalized = aliases.get(normalized, normalized)
    if normalized == "auto":
        return "nightly-stability" if _strategies_equal(payload) else "nightly-equivalence"
    return normalized


def _issue(code: str, section: str, **details: Any) -> dict[str, Any]:
    result: dict[str, Any] = {
        "code": code,
        "section": section,
        "message": ERROR_MESSAGES.get(code, code),
    }
    if details:
        result["details"] = details
    return result


def _append_issue(
    target: list[dict[str, Any]], code: str, section: str, **details: Any
) -> None:
    if not any(row.get("code") == code and row.get("details") == (details or None) for row in target):
        target.append(_issue(code, section, **details))


def _check(
    checks: list[dict[str, Any]],
    check_id: str,
    section: str,
    passed: bool,
    summary: str,
    **metrics: Any,
) -> None:
    row: dict[str, Any] = {
        "id": check_id,
        "section": section,
        "status": "pass" if passed else "fail",
        "summary": summary,
    }
    if metrics:
        row["metrics"] = metrics
    checks.append(row)


def _strength_scope(payload: dict[str, Any], name: str) -> dict[str, Any]:
    strength = payload.get("strength") or {}
    value = strength.get(name) or {}
    return value if isinstance(value, dict) else {}


def _ci_lower(scope: dict[str, Any]) -> float | None:
    overall = scope.get("overall") or {}
    interval = overall.get("ci95") or {}
    return _float(interval.get("lower"), None) if isinstance(interval, dict) else None


def _nightly_config_valid(payload: dict[str, Any]) -> bool:
    config = payload.get("config") or {}
    return (
        payload.get("deck_keys") == DECK_ORDER
        and _int(config.get("seed")) == 17
        and _int(config.get("seed_blocks_per_deck")) == 50
        and _int(config.get("cross_seed_blocks_per_matchup")) == 10
        and _int(config.get("seed_block_start")) == 0
        and _int(config.get("seed_block_count")) in (0, 50)
        and _int(config.get("task_start")) == 0
        and _int(config.get("task_count")) == 0
        and str(config.get("matchup_mode")) == "Balanced"
        and str(payload.get("eval_preset") or config.get("eval_preset")) == "Nightly"
        and str(config.get("run_role")) == "main"
        and _int(config.get("warmup_blocks_per_deck")) == 0
        and config.get("rules_options") == {"apply_type_matchups": False}
    )


def _coverage_valid(payload: dict[str, Any], *, canonical_nightly: bool) -> bool:
    coverage = payload.get("coverage") or {}
    if not isinstance(coverage, dict) or not bool(coverage.get("complete")):
        return False
    if _int(coverage.get("missing_match_count")) != 0:
        return False
    if _int(coverage.get("unexpected_match_count")) != 0:
        return False
    if coverage.get("structural_errors"):
        return False
    if canonical_nightly:
        return (
            _int(coverage.get("expected_games")) == 2800
            and _int(coverage.get("actual_games")) == 2800
            and _int(coverage.get("expected_mirror_units")) == 500
            and _int(coverage.get("complete_mirror_units")) == 500
            and _int(coverage.get("expected_cross_units")) == 450
            and _int(coverage.get("complete_cross_units")) == 450
        )
    return True


def _dirty_game_count(payload: dict[str, Any]) -> int:
    observed = payload.get("observed") or payload.get("summary") or {}
    games = _int(observed.get("games"))
    clean = _int(observed.get("clean_games"))
    explicit = sum(
        _int(observed.get(key))
        for key in (
            "invalid_actions",
            "choice_failures",
            "rule_exceptions",
            "max_actions_exhaustions",
        )
    )
    return max(games - clean, explicit)


def _golden_valid(payload: dict[str, Any]) -> tuple[bool, bool]:
    golden = payload.get("golden_scenarios") or {}
    by_scope = golden.get("by_scope") or {}
    decks = len(payload.get("deck_keys") or [])
    coverage_count = _int((by_scope.get("coverage_contract") or {}).get("total"))
    runtime_count = _int((by_scope.get("runtime_integration") or {}).get("total"))
    strategy_count = _int((by_scope.get("strategy_score") or {}).get("total"))
    complete = (
        decks > 0
        and coverage_count == decks
        and runtime_count == 3
        and decks * 8 <= strategy_count <= decks * 12
        and _int(golden.get("total")) == coverage_count + runtime_count + strategy_count
    )
    return complete, _int(golden.get("failed")) == 0


def _probe_validation(payload: dict[str, Any]) -> dict[str, Any]:
    performance = payload.get("performance") or {}
    if not isinstance(performance, dict) or not bool(performance.get("available")):
        return {
            "coverage_valid": False,
            "latency_metrics_valid": False,
            "search_depth_metrics_valid": False,
            "latency": {},
            "search_depth": {},
        }
    config = performance.get("config") or {}
    coverage = performance.get("coverage") or {}
    coverage_valid = (
        bool(coverage.get("complete"))
        and _int(performance.get("games_total")) == 60
        and _int(performance.get("warmup_games")) == 20
        and _int(performance.get("measured_games")) == 40
        and _int(config.get("seed")) == 17
        and _int(config.get("seed_blocks_per_deck")) == 3
        and _int(config.get("warmup_blocks_per_deck")) == 1
        and str(config.get("matchup_mode")) == "Mirror"
        and str(config.get("run_role")) == "search_depth_probe"
        and not bool(config.get("profile"))
        and _int(coverage.get("complete_mirror_units")) == 30
        and _int(coverage.get("clean_mirror_units")) == 30
        and _int((performance.get("observed") or {}).get("clean_games")) == 60
    )
    measured = [
        row
        for row in performance.get("matches") or []
        if isinstance(row, dict)
        and str(row.get("sample_phase") or "measurement") == "measurement"
    ]
    recomputed = summarize_performance(measured)
    reported_latency = performance.get("metrics") or {}
    latency_metrics_valid = (
        bool(recomputed.get("available"))
        and reported_latency == recomputed
        and all(
            _int((reported_latency.get(strategy) or {}).get("decision_ms_sample_count")) > 0
            and _int((reported_latency.get(strategy) or {}).get("ai_turn_ms_sample_count")) > 0
            for strategy in ("A", "B")
        )
    )
    recomputed_depth = summarize_search_depth(measured, payload.get("deck_keys") or [])
    reported_depth = performance.get("search_depth") or {}
    search_depth_metrics_valid = (
        bool(recomputed_depth.get("available"))
        and reported_depth == recomputed_depth
        and all(
            _int(
                (((reported_depth.get("by_strategy") or {}).get(strategy) or {}).get(
                    "full_tier"
                ) or {}).get("sample_count")
            )
            > 0
            and all(
                _int(
                    ((((reported_depth.get("by_strategy") or {}).get(strategy) or {}).get(
                        "per_deck"
                    ) or {}).get(deck) or {}).get("full_tier", {}).get("sample_count")
                )
                > 0
                for deck in DECK_ORDER
            )
            for strategy in ("A", "B")
        )
    )
    return {
        "coverage_valid": coverage_valid,
        "latency_metrics_valid": latency_metrics_valid,
        "search_depth_metrics_valid": search_depth_metrics_valid,
        "latency": reported_latency,
        "search_depth": reported_depth,
    }


def _search_depth_errors(
    reported: dict[str, Any], gate: str
) -> list[tuple[str, dict[str, Any]]]:
    errors: list[tuple[str, dict[str, Any]]] = []
    by_strategy = reported.get("by_strategy") or {}
    for strategy in ("A", "B"):
        full = (by_strategy.get(strategy) or {}).get("full_tier") or {}
        requested_min = _float(full.get("requested_depth_min"), None)
        p50 = _float(full.get("reached_depth_p50"), None)
        p95 = _float(full.get("reached_depth_p95"), None)
        requested_floor = SEARCH_DEPTH_THRESHOLDS["full_tier_requested_depth_min"]
        if requested_min is None or requested_min < requested_floor:
            errors.append((
                "search_depth_requested_below_floor",
                {
                    "strategy": strategy,
                    "value": requested_min,
                    "floor": requested_floor,
                },
            ))
        for metric, value, threshold_key in (
            ("reached_depth_p50", p50, "full_tier_reached_depth_p50_min"),
            ("reached_depth_p95", p95, "full_tier_reached_depth_p95_min"),
        ):
            floor = SEARCH_DEPTH_THRESHOLDS[threshold_key]
            if value is None or value < floor:
                errors.append((
                    "search_depth_below_floor",
                    {
                        "strategy": strategy,
                        "metric": metric,
                        "value": value,
                        "floor": floor,
                    },
                ))

    a_full = (by_strategy.get("A") or {}).get("full_tier") or {}
    b_full = (by_strategy.get("B") or {}).get("full_tier") or {}
    allowed = SEARCH_DEPTH_THRESHOLDS["a_vs_b_allowed_depth_deficit"]
    for metric in ("reached_depth_p50", "reached_depth_p95"):
        a_value = _float(a_full.get(metric), None)
        b_value = _float(b_full.get(metric), None)
        if a_value is None or b_value is None:
            continue
        regression = (
            abs(a_value - b_value) > allowed
            if gate == "nightly-stability"
            else a_value < b_value - allowed
        )
        if regression:
            errors.append((
                "search_depth_regression",
                {
                    "metric": metric,
                    "candidate_a": a_value,
                    "control_b": b_value,
                    "allowed_deficit": allowed,
                },
            ))
    return errors


def validate_evaluation_gate(
    payload: dict[str, Any],
    *,
    gate: str = "nightly-stability",
    platform: str | None = None,
) -> dict[str, Any]:
    normalized_gate = _normalized_gate(payload, gate)
    errors: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    checks: list[dict[str, Any]] = []
    strict = normalized_gate in {
        "nightly-stability",
        "nightly-equivalence",
        "deep-practical",
    }

    schema_valid = _int(payload.get("schema_version")) == SCHEMA_VERSION
    _check(checks, "schema", "integrity", schema_valid, f"schema v{SCHEMA_VERSION}")
    if not schema_valid:
        _append_issue(errors, "schema_version", "integrity", actual=payload.get("schema_version"))
    artifact_valid = payload.get("artifact_kind") == "ai_evaluation_result"
    _check(checks, "artifact", "integrity", artifact_valid, "权威聚合结果")
    if not artifact_valid:
        _append_issue(errors, "artifact_kind", "integrity")
    provenance = payload.get("provenance") or {}
    provenance_valid = (
        isinstance(provenance, dict)
        and _int(provenance.get("schema_version")) == SCHEMA_VERSION
        and bool(provenance.get("fingerprint"))
    )
    _check(checks, "provenance", "integrity", provenance_valid, "来源指纹")
    if not provenance_valid:
        _append_issue(errors, "provenance_missing", "integrity")

    if not schema_valid or not artifact_valid:
        return _result(
            payload,
            normalized_gate,
            platform,
            errors,
            warnings,
            checks,
            {},
        )

    canonical_nightly = normalized_gate.startswith("nightly-")
    config_valid = not canonical_nightly or _nightly_config_valid(payload)
    _check(checks, "nightly_config", "coverage", config_valid, "固定 Nightly 赛程")
    if not config_valid:
        _append_issue(errors, "nightly_config", "coverage")

    coverage_valid = _coverage_valid(payload, canonical_nightly=canonical_nightly)
    _check(checks, "coverage", "coverage", coverage_valid, "比赛与实验单元覆盖")
    if not coverage_valid:
        target = errors if strict else warnings
        _append_issue(target, "coverage_incomplete", "coverage")
        coverage = payload.get("coverage") or {}
        if coverage.get("structural_errors"):
            _append_issue(target, "experimental_unit_incomplete", "fairness")

    dirty_games = _dirty_game_count(payload)
    clean_valid = dirty_games == 0
    _check(checks, "clean_games", "reliability", clean_valid, "全部对局干净", dirty_games=dirty_games)
    if not clean_valid:
        _append_issue(errors if strict else warnings, "dirty_games", "reliability", dirty_games=dirty_games)

    fairness = payload.get("fairness") or {}
    fairness_valid = (
        bool(fairness.get("assignment_balanced"))
        and bool(fairness.get("per_strategy_deck_balanced"))
        and bool(fairness.get("mirror_units_complete"))
        and (
            _int((payload.get("coverage") or {}).get("expected_cross_units")) == 0
            or bool(fairness.get("cross_units_complete"))
        )
    )
    _check(checks, "fairness", "fairness", fairness_valid, "座位、先后手与牌组角色平衡")
    if not fairness_valid:
        _append_issue(errors if strict else warnings, "fairness_unbalanced", "fairness")

    behavior = payload.get("behavior") or {}
    behavior_valid = isinstance(behavior, dict) and bool(behavior.get("available"))
    _check(
        checks,
        "behavior",
        "diversity",
        True,
        "动作与 Choice 行为画像（仅诊断）",
        available=behavior_valid,
    )

    golden_complete, golden_passed = _golden_valid(payload)
    _check(
        checks,
        "golden_coverage",
        "golden",
        golden_complete if strict else True,
        "金标场景覆盖" if strict else "金标场景覆盖（此门禁不要求）",
        available=golden_complete,
    )
    _check(
        checks,
        "golden_results",
        "golden",
        golden_passed if strict else True,
        "金标场景结果" if strict else "金标场景结果（此门禁不要求）",
        golden_passed=golden_passed,
    )
    if strict and not golden_complete:
        _append_issue(errors, "golden_scenarios_missing", "golden")
    if strict and not golden_passed:
        _append_issue(errors, "golden_scenarios_failed", "golden")

    configured_platform = str(platform or payload.get("platform") or "").lower()
    platform_supported = configured_platform in SUPPORTED_PLATFORMS
    _check(checks, "platform", "integrity", platform_supported, "受支持的来源平台")
    if not platform_supported:
        _append_issue(errors, "platform_unsupported", "integrity", platform=configured_platform)
        configured_platform = "windows"
    probe = _probe_validation(payload)
    probe_coverage = bool(probe.get("coverage_valid"))
    depth_metrics_valid = bool(probe.get("search_depth_metrics_valid"))
    latency_metrics_valid = bool(probe.get("latency_metrics_valid"))
    _check(
        checks,
        "search_depth_probe_coverage",
        "search_depth",
        probe_coverage if strict else True,
        "单进程 20+40 搜索深度探针" if strict else "搜索深度探针（此门禁不要求）",
        available=probe_coverage,
    )
    _check(
        checks,
        "search_depth_probe_metrics",
        "search_depth",
        depth_metrics_valid if strict else True,
        "A/B 实际 beam 搜索深度" if strict else "搜索深度样本（此门禁不要求）",
        available=depth_metrics_valid,
    )
    _check(
        checks,
        "latency_diagnostics",
        "performance",
        True,
        "A/B 延迟仅作诊断，不参与门禁",
        available=latency_metrics_valid,
        metrics=probe.get("latency") or {},
    )
    if strict and not (payload.get("performance") or {}).get("available"):
        _append_issue(errors, "search_depth_probe_missing", "search_depth")
    elif strict and not probe_coverage:
        _append_issue(errors, "search_depth_probe_coverage", "search_depth")
    if strict and not depth_metrics_valid:
        _append_issue(errors, "search_depth_probe_metrics", "search_depth")
    depth_errors = (
        _search_depth_errors(probe.get("search_depth") or {}, normalized_gate)
        if depth_metrics_valid
        else []
    )
    if strict:
        for code, details in depth_errors:
            _append_issue(errors, code, "search_depth", **details)
    _check(
        checks,
        "search_depth_thresholds",
        "search_depth",
        (not depth_errors and depth_metrics_valid) if strict else True,
        "A/B 全预算搜索深度" if strict else "搜索深度阈值（此门禁不要求）",
        thresholds=SEARCH_DEPTH_THRESHOLDS,
    )

    relation_valid = True
    if normalized_gate == "nightly-stability":
        relation_valid = _strategies_equal(payload)
    elif normalized_gate in {"nightly-equivalence", "deep-practical"}:
        relation_valid = not _strategies_equal(payload)
    _check(checks, "strategy_relation", "strength", relation_valid, "策略指纹关系")
    if not relation_valid:
        _append_issue(errors, "strategy_relation", "strength")

    diagnostic_delta = _int(
        (((payload.get("decision_diagnostics") or {}).get("by_strategy") or {}).get("delta") or {}).get("total")
    )
    if normalized_gate == "nightly-stability":
        diagnostic_ok = diagnostic_delta == 0
        _check(
            checks,
            "decision_diagnostics",
            "diagnostics",
            diagnostic_ok,
            "同策略 A/B 错因计数平衡",
            delta=diagnostic_delta,
        )
        if not diagnostic_ok:
            _append_issue(
                errors,
                "decision_diagnostics_unbalanced",
                "diagnostics",
                delta=diagnostic_delta,
            )

    mirror = _strength_scope(payload, "mirror")
    cross = _strength_scope(payload, "cross_role")
    if normalized_gate in {"nightly-equivalence", "deep-practical"}:
        ci_floor = -0.02 if normalized_gate == "nightly-equivalence" else -0.04
        mirror_lower = _ci_lower(mirror)
        cross_lower = _ci_lower(cross)
        mirror_ok = mirror_lower is not None and mirror_lower >= ci_floor - 1e-12
        cross_ok = cross_lower is not None and cross_lower >= ci_floor - 1e-12
        _check(checks, "mirror_equivalence", "strength", mirror_ok, "镜像 CI 下界", lower=mirror_lower, floor=ci_floor)
        _check(checks, "cross_equivalence", "strength", cross_ok, "交叉 CI 下界", lower=cross_lower, floor=ci_floor)
        if not mirror_ok:
            _append_issue(errors, "mirror_ci_below_floor", "strength", lower=mirror_lower, floor=ci_floor)
        if not cross_ok:
            _append_issue(errors, "cross_ci_below_floor", "strength", lower=cross_lower, floor=ci_floor)

        deck_floor = -0.04 if normalized_gate == "nightly-equivalence" else -0.08
        for deck, stats in (mirror.get("per_deck") or {}).items():
            delta = _float((stats.get("overall") or {}).get("point_delta"), None)
            if delta is None or delta < deck_floor - 1e-12:
                _append_issue(
                    errors,
                    f"mirror_deck_{deck}_below_floor",
                    "strength",
                    deck=deck,
                    delta=delta,
                    floor=deck_floor,
                )
        if normalized_gate == "nightly-equivalence":
            for matchup, stats in (cross.get("per_unordered_matchup") or {}).items():
                delta = _float((stats.get("overall") or {}).get("point_delta"), None)
                if delta is None or delta < -0.08 - 1e-12:
                    _append_issue(
                        errors,
                        f"cross_matchup_{matchup}_below_floor",
                        "strength",
                        matchup=matchup,
                        delta=delta,
                        floor=-0.08,
                    )

        diagnostic_ok = diagnostic_delta <= 0
        _check(checks, "decision_diagnostics", "diagnostics", diagnostic_ok, "候选错因不多于对照", delta=diagnostic_delta)
        if not diagnostic_ok:
            _append_issue(errors, "decision_diagnostics_regression", "diagnostics", delta=diagnostic_delta)

    if normalized_gate == "deep-practical":
        fallback_rate = _float((payload.get("observed") or {}).get("deep_fallback_rate"), 0.0) or 0.0
        fallback_ok = fallback_rate == 0.0
        _check(checks, "deep_fallback", "reliability", fallback_ok, "Deep 零回退", rate=fallback_rate)
        if not fallback_ok:
            _append_issue(errors, "deep_fallback_rate", "reliability", rate=fallback_rate)
    elif normalized_gate not in {
        "nightly-stability",
        "nightly-equivalence",
        "quick",
        "smoke",
    }:
        _append_issue(errors, "unknown_gate", "integrity", gate=normalized_gate)

    return _result(
        payload,
        normalized_gate,
        configured_platform,
        errors,
        warnings,
        checks,
        SEARCH_DEPTH_THRESHOLDS,
    )


def _result(
    payload: dict[str, Any],
    gate: str,
    platform: str | None,
    errors: list[dict[str, Any]],
    warnings: list[dict[str, Any]],
    checks: list[dict[str, Any]],
    search_depth_thresholds: dict[str, float],
) -> dict[str, Any]:
    mirror = _strength_scope(payload, "mirror").get("overall") or {}
    cross = _strength_scope(payload, "cross_role").get("overall") or {}
    return {
        "schema_version": SCHEMA_VERSION,
        "artifact_kind": "ai_evaluation_validation",
        "valid": not errors,
        "gate": gate,
        "platform": platform,
        "errors": errors,
        "warnings": warnings,
        "error_codes": [str(row.get("code")) for row in errors],
        "warning_codes": [str(row.get("code")) for row in warnings],
        "checks": checks,
        "search_depth_thresholds": search_depth_thresholds,
        "latency_gate_enabled": False,
        "metrics": {
            "games": _int((payload.get("observed") or {}).get("games")),
            "mirror_point_delta": mirror.get("point_delta"),
            "mirror_ci95": mirror.get("ci95"),
            "cross_point_delta": cross.get("point_delta"),
            "cross_ci95": cross.get("ci95"),
            "dirty_games": _dirty_game_count(payload),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--platform", choices=sorted(SUPPORTED_PLATFORMS))
    parser.add_argument(
        "--gate",
        choices=[
            "quick",
            "smoke",
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
    payload = json.loads(args.input.read_text(encoding="utf-8-sig"))
    result = validate_evaluation_gate(payload, gate=args.gate, platform=args.platform)
    rendered = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

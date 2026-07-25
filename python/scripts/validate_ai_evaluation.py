"""Validate schema-v7 Godot traditional-AI evaluation evidence."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

try:
    from scripts.ai_evaluation_v7 import (
        DECK_ORDER,
        PROTOCOL_ID,
        REPLY_SEARCH_DEPTH,
        SCHEMA_VERSION,
        V2_SEARCH_DEPTH,
        complete_evidence_unit_ids,
        evidence_unit_ids_sha256,
        experimental_units,
        match_decision_contract_error,
        simulation_fingerprint_from_provenance,
        summarize_performance,
        summarize_coverage,
        summarize_search_depth,
        task_manifest_id,
    )
except ModuleNotFoundError:  # Direct script execution.
    from ai_evaluation_v7 import (  # type: ignore[no-redef]
        DECK_ORDER,
        PROTOCOL_ID,
        REPLY_SEARCH_DEPTH,
        SCHEMA_VERSION,
        V2_SEARCH_DEPTH,
        complete_evidence_unit_ids,
        evidence_unit_ids_sha256,
        experimental_units,
        match_decision_contract_error,
        simulation_fingerprint_from_provenance,
        summarize_performance,
        summarize_coverage,
        summarize_search_depth,
        task_manifest_id,
    )

try:
    from scripts.build_ai_evaluation_provenance import (
        current_analysis_fingerprint,
    )
except ModuleNotFoundError:  # Direct script execution.
    from build_ai_evaluation_provenance import (  # type: ignore[no-redef]
        current_analysis_fingerprint,
    )


SUPPORTED_PLATFORMS = {"windows", "android"}
SEARCH_DEPTH_THRESHOLDS = {
    "requested_depth": float(V2_SEARCH_DEPTH),
    "requested_depth_min": float(V2_SEARCH_DEPTH),
    "complete_or_frontier_exhausted_rate_min": 1.0,
    "deadline_truncations_max": 0.0,
    "node_budget_truncations_max": 0.0,
    "reply_requested_depth": float(REPLY_SEARCH_DEPTH),
    "reply_complete_or_frontier_exhausted_rate_min": 1.0,
}


ERROR_MESSAGES = {
    "schema_version": "结果不是 AI 评测 schema v7。",
    "protocol_id": "结果不是传统 AI v7 固定深度评测协议。",
    "artifact_kind": "输入不是已聚合的 AI 评测结果。",
    "provenance_missing": "缺少可复现来源指纹。",
    "simulation_fingerprint_mismatch": "模拟指纹与来源稳定字段重算结果不一致。",
    "simulation_config": "模拟来源配置不完整，或与赛程及执行配置不一致。",
    "godot_executable_hash": "来源记录缺少合法的 Godot 可执行文件 SHA-256。",
    "legacy_provenance_compatibility": "旧证据缺少部分 v7 来源字段；仅允许非最终 Nightly 使用。",
    "analysis_fingerprint_stale": "结果不是由当前聚合、校验与报告代码生成的。",
    "task_manifest": "任务清单标识与固定赛程不一致。",
    "execution_config": "缺少评测执行配置。",
    "checkpoint_summary": "检查点摘要缺失、结构无效或未覆盖完整 Nightly 证据单元。",
    "wall_clock_metadata": "墙钟耗时与 wall_clock_scope 的字段配对无效。",
    "gate_depth_source": "搜索深度门禁没有使用主评测矩阵。",
    "platform_unsupported": "评测平台不是受支持的 Windows 或 Android。",
    "nightly_config": "Nightly 配置不是固定的 10 牌组、seed 17、50/10 区块。",
    "coverage_incomplete": "比赛覆盖不完整或包含意外比赛。",
    "experimental_unit_incomplete": "存在不完整的两局镜像对或四局角色交叉块。",
    "dirty_games": "存在非正常终局、非法动作、Choice/规则异常或动作上限耗尽。",
    "fairness_unbalanced": "玩家编号、先后手或牌组角色分配不平衡。",
    "behavior_missing": "行为画像埋点不完整。",
    "golden_scenarios_missing": "金标场景集合不完整。",
    "golden_scenarios_failed": "至少一个金标场景失败。",
    "search_depth_metrics": "主评测矩阵的搜索深度样本或聚合指标无效。",
    "performance_benchmark_invalid": "可选性能基准不完整；不影响强度门禁。",
    "search_depth_requested_below_floor": "策略配置的全预算搜索深度低于发布下限。",
    "search_depth_requested_mismatch": "v2 搜索没有使用固定深度 8。",
    "search_depth_below_floor": "策略实际达到的搜索深度分位数低于发布下限。",
    "search_depth_incomplete": "存在未完整达到固定深度且未耗尽搜索空间的 v2 搜索。",
    "search_depth_time_or_node_stop": "v2 搜索仍被时间或节点预算截断。",
    "search_depth_engine_mismatch": "搜索深度门禁样本不是 turn_beam_v2。",
    "search_depth_decision_accounting": "动作决策与搜索深度样本没有完整守恒。",
    "reply_depth_evidence_missing": "缺少适用的对手回应搜索深度证据。",
    "reply_depth_requested_mismatch": "对手回应搜索没有使用固定深度 3。",
    "reply_depth_incomplete": "对手回应搜索未完整达到深度 3，也未提前耗尽搜索空间。",
    "search_depth_regression": "候选策略的搜索深度低于对照策略。",
    "strategy_relation": "策略指纹关系与所选门禁不符。",
    "mirror_ci_below_floor": "镜像强度 95% 区间下界低于允许值。",
    "cross_ci_below_floor": "角色交叉强度 95% 区间下界低于允许值。",
    "decision_diagnostics_regression": "候选策略的决策错因多于对照策略。",
    "weak_attack_not_reduced": "候选策略的过早弱攻击发生率未至少下降 50%。",
    "diagnostic_rate_regression": "候选策略至少一项决策诊断发生率上升超过 0.1 个百分点。",
    "decision_diagnostics_unbalanced": "同策略稳定性评测的 A/B 决策错因计数不平衡。",
    "deep_fallback_rate": "Deep 评测发生了回退。",
    "deep_runtime_contract": "候选评测没有完整使用正式 Deep 运行时与隐藏信息快照。",
    "deep_planner_coverage": "候选动作决策没有全部由 deep_root_ismcts_v1 完成。",
    "deep_decision_timeout": "至少一个适用的 Deep 决策超过 2 秒。",
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


def _valid_sha256(value: Any) -> bool:
    normalized = str(value or "")
    return len(normalized) == 64 and all(
        character in "0123456789abcdef" for character in normalized
    )


def _is_nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


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
        "superiority": "nightly-superiority",
        "nightly": "nightly-stability",
        "deep": "deep-practical",
        "deep-noninferiority": "deep-release",
        "hybrid-release": "deep-release",
    }
    normalized = aliases.get(normalized, normalized)
    if normalized == "auto":
        return (
            "nightly-stability"
            if _strategies_equal(payload)
            else "nightly-superiority"
        )
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


SIMULATION_CONFIG_FIELDS = (
    "protocol_id",
    "eval_preset",
    "deck_keys",
    "seed",
    "seed_blocks_per_deck",
    "cross_seed_blocks_per_matchup",
    "matchup_mode",
    "max_actions",
    "rules_options",
    "workers",
    "external_shard_count",
    "global_parallel_workers",
    "evidence_shard_count",
    "profile",
    "disable_ai_cache",
    "disable_native_math",
    "task_manifest_id",
    "execution_profile_id",
)


def _typed_equal(left: Any, right: Any) -> bool:
    return type(left) is type(right) and left == right


def _simulation_config_binding(
    payload: dict[str, Any],
    config: Any,
    execution_config: Any,
    simulation_config: Any,
    manifest_id: str,
) -> tuple[str, list[str]]:
    """Return ``valid``, ``legacy`` or ``invalid`` plus affected fields."""
    if not isinstance(simulation_config, dict) or not simulation_config:
        return "legacy", ["provenance.simulation_config"]
    if not isinstance(config, dict) or not isinstance(execution_config, dict):
        return "invalid", ["config", "execution_config"]

    missing: list[str] = []
    mismatched: list[str] = []
    for field in SIMULATION_CONFIG_FIELDS:
        if field not in simulation_config:
            missing.append(f"provenance.simulation_config.{field}")
        if field not in execution_config:
            missing.append(f"execution_config.{field}")

    expected_from_result = {
        "protocol_id": payload.get("protocol_id"),
        "eval_preset": payload.get("eval_preset"),
        "deck_keys": payload.get("deck_keys"),
        "seed": config.get("seed"),
        "seed_blocks_per_deck": config.get("seed_blocks_per_deck"),
        "cross_seed_blocks_per_matchup": config.get(
            "cross_seed_blocks_per_matchup"
        ),
        "matchup_mode": config.get("matchup_mode"),
        "max_actions": config.get("max_actions"),
        "rules_options": config.get("rules_options"),
        "profile": config.get("profile"),
        "disable_ai_cache": config.get("disable_ai_cache"),
        "disable_native_math": config.get("disable_native_math"),
        "task_manifest_id": manifest_id,
        "execution_profile_id": payload.get("execution_profile_id"),
    }
    for field, expected in expected_from_result.items():
        if field in simulation_config and not _typed_equal(
            simulation_config[field], expected
        ):
            mismatched.append(f"provenance.simulation_config.{field}")
        if field in execution_config and not _typed_equal(
            execution_config[field], expected
        ):
            mismatched.append(f"execution_config.{field}")

    for field in SIMULATION_CONFIG_FIELDS:
        if (
            field in simulation_config
            and field in execution_config
            and not _typed_equal(
                simulation_config[field],
                execution_config[field],
            )
        ):
            mismatched.append(f"execution_config.{field}")

    integer_rules = {
        "seed": lambda value: value >= 0,
        "seed_blocks_per_deck": lambda value: value > 0,
        "cross_seed_blocks_per_matchup": lambda value: value >= 0,
        "max_actions": lambda value: value > 0,
        "workers": lambda value: value > 0,
        "external_shard_count": lambda value: value > 0,
        "global_parallel_workers": lambda value: value > 0,
        "evidence_shard_count": lambda value: value > 0,
    }
    for field, predicate in integer_rules.items():
        if field not in simulation_config:
            continue
        value = simulation_config[field]
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or not predicate(value)
        ):
            mismatched.append(f"provenance.simulation_config.{field}")
    for field in ("profile", "disable_ai_cache", "disable_native_math"):
        if field in simulation_config and not isinstance(
            simulation_config[field], bool
        ):
            mismatched.append(f"provenance.simulation_config.{field}")
    if (
        "deck_keys" in simulation_config
        and (
            not isinstance(simulation_config["deck_keys"], list)
            or not simulation_config["deck_keys"]
            or any(
                not isinstance(deck, str) or not deck
                for deck in simulation_config["deck_keys"]
            )
        )
    ):
        mismatched.append("provenance.simulation_config.deck_keys")
    if (
        "rules_options" in simulation_config
        and not isinstance(simulation_config["rules_options"], dict)
    ):
        mismatched.append("provenance.simulation_config.rules_options")
    for field in (
        "protocol_id",
        "eval_preset",
        "matchup_mode",
        "task_manifest_id",
        "execution_profile_id",
    ):
        if field in simulation_config and (
            not isinstance(simulation_config[field], str)
            or not simulation_config[field]
        ):
            mismatched.append(f"provenance.simulation_config.{field}")

    workers = simulation_config.get("workers")
    external_shards = simulation_config.get("external_shard_count")
    global_workers = simulation_config.get("global_parallel_workers")
    if (
        isinstance(workers, int)
        and not isinstance(workers, bool)
        and isinstance(external_shards, int)
        and not isinstance(external_shards, bool)
        and isinstance(global_workers, int)
        and not isinstance(global_workers, bool)
        and global_workers != workers * external_shards
    ):
        mismatched.append(
            "provenance.simulation_config.global_parallel_workers"
        )

    result_bindings = {
        "workers": config.get("parallel_workers"),
        "evidence_shard_count": config.get("evidence_shard_count"),
        "profile": config.get("profile"),
        "disable_ai_cache": config.get("disable_ai_cache"),
        "disable_native_math": config.get("disable_native_math"),
        "execution_profile_id": config.get("execution_profile_id"),
    }
    for field, expected in result_bindings.items():
        if expected is None:
            missing.append(f"config.{field}")
        elif field in simulation_config and not _typed_equal(
            simulation_config[field], expected
        ):
            mismatched.append(f"config.{field}")
    if "parallel_workers" not in execution_config:
        missing.append("execution_config.parallel_workers")
    elif "workers" in simulation_config and not _typed_equal(
        execution_config["parallel_workers"],
        simulation_config["workers"],
    ):
        mismatched.append("execution_config.parallel_workers")
    if "platform" not in execution_config:
        missing.append("execution_config.platform")
    elif not _typed_equal(
        execution_config["platform"],
        payload.get("platform"),
    ):
        mismatched.append("execution_config.platform")

    if mismatched:
        return "invalid", sorted(set(mismatched))
    if missing:
        return "legacy", sorted(set(missing))
    return "valid", []


def _checkpoint_summary_validation(
    payload: dict[str, Any],
    *,
    canonical_nightly: bool,
) -> tuple[bool, list[str]]:
    summary = payload.get("checkpoint_summary")
    if not isinstance(summary, dict):
        return False, ["checkpoint_summary"]
    errors: list[str] = []
    enabled = summary.get("enabled")
    if not isinstance(enabled, bool):
        errors.append("enabled")
    count_fields = (
        "restored_units",
        "written_units",
        "pending_units",
    )
    counts: dict[str, int] = {}
    for field in count_fields:
        value = summary.get(field)
        if not _is_nonnegative_int(value):
            errors.append(field)
        else:
            counts[field] = int(value)

    has_shards_enabled = "shards_enabled" in summary
    has_shards_total = "shards_total" in summary
    shards_enabled = summary.get("shards_enabled")
    shards_total = summary.get("shards_total")
    if has_shards_enabled != has_shards_total:
        errors.append("shard_summary_pair")
    elif has_shards_enabled:
        if (
            not _is_nonnegative_int(shards_enabled)
            or not _is_nonnegative_int(shards_total)
            or int(shards_total) <= 0
            or int(shards_enabled) > int(shards_total)
        ):
            errors.append("shard_summary_counts")
    elif canonical_nightly:
        errors.append("shard_summary_missing")

    if (
        isinstance(enabled, bool)
        and has_shards_enabled
        and _is_nonnegative_int(shards_enabled)
    ):
        if enabled and int(shards_enabled) <= 0:
            errors.append("enabled_without_shards")
        if not enabled and int(shards_enabled) != 0:
            errors.append("disabled_with_shards")
    if (
        enabled is False
        and counts
        and any(counts.get(field, 0) != 0 for field in count_fields)
    ):
        errors.append("disabled_with_units")

    identity_fields = (
        "completed_units",
        "completed_unit_ids",
        "completed_unit_ids_sha256",
    )
    present_identity_fields = [
        field for field in identity_fields if field in summary
    ]
    completed_unit_ids: list[str] = []
    match_unit_ids: list[str] = []
    if present_identity_fields and len(present_identity_fields) != len(
        identity_fields
    ):
        errors.append("unit_identity_summary_pair")
    elif len(present_identity_fields) == len(identity_fields):
        raw_unit_ids = summary.get("completed_unit_ids")
        completed_units = summary.get("completed_units")
        if (
            not _is_nonnegative_int(completed_units)
            or not isinstance(raw_unit_ids, list)
            or any(
                not isinstance(unit_id, str) or not unit_id
                for unit_id in raw_unit_ids
            )
            or len(set(raw_unit_ids)) != len(raw_unit_ids)
            or list(raw_unit_ids) != sorted(raw_unit_ids)
        ):
            errors.append("unit_identity_manifest")
        else:
            completed_unit_ids = list(raw_unit_ids)
            if int(completed_units) != len(completed_unit_ids):
                errors.append("unit_identity_count")
            if (
                counts
                and int(completed_units)
                != counts.get("restored_units", 0)
                + counts.get("written_units", 0)
            ):
                errors.append("unit_identity_accounting")
            if (
                not _valid_sha256(
                    summary.get("completed_unit_ids_sha256")
                )
                or str(summary.get("completed_unit_ids_sha256"))
                != evidence_unit_ids_sha256(completed_unit_ids)
            ):
                errors.append("unit_identity_hash")
            matches = payload.get("matches")
            if (
                not isinstance(matches, list)
                or any(not isinstance(row, dict) for row in matches)
            ):
                errors.append("unit_identity_matches")
            else:
                match_unit_ids = complete_evidence_unit_ids(matches)
                if not set(completed_unit_ids).issubset(match_unit_ids):
                    errors.append("unit_identity_match_mismatch")
    elif canonical_nightly:
        errors.append("unit_identity_summary_missing")

    if canonical_nightly and not errors:
        if enabled is not True:
            errors.append("nightly_checkpoint_disabled")
        if int(shards_enabled) != 50 or int(shards_total) != 50:
            errors.append("nightly_shard_coverage")
        if (
            counts["restored_units"] + counts["written_units"]
            != 950
        ):
            errors.append("nightly_unit_coverage")
        if counts["pending_units"] != 0:
            errors.append("nightly_pending_units")
        if (
            len(completed_unit_ids) != 950
            or len(match_unit_ids) != 950
            or completed_unit_ids != match_unit_ids
        ):
            errors.append("nightly_unit_identity_coverage")
    return not errors, errors


def _wall_clock_metadata_validation(
    payload: dict[str, Any],
) -> tuple[bool, list[str]]:
    scope = payload.get("wall_clock_scope")
    has_wall_clock = "wall_clock_ms" in payload
    if scope not in {
        "not_recorded",
        "full_evidence_stage",
        "current_attempt_only",
    }:
        return False, ["wall_clock_scope"]
    if scope == "not_recorded":
        return (
            (not has_wall_clock),
            [] if not has_wall_clock else ["wall_clock_ms_unexpected"],
        )
    if not has_wall_clock:
        return False, ["wall_clock_ms_missing"]
    value = payload.get("wall_clock_ms")
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or float(value) <= 0.0
    ):
        return False, ["wall_clock_ms"]
    return True, []


def _recomputed_main_coverage(payload: dict[str, Any]) -> dict[str, Any] | None:
    matches = payload.get("matches")
    deck_keys = payload.get("deck_keys")
    config = payload.get("config")
    if (
        not isinstance(matches, list)
        or not matches
        or any(not isinstance(row, dict) for row in matches)
        or not isinstance(deck_keys, list)
        or not isinstance(config, dict)
    ):
        return None
    try:
        mirror_units, cross_units = experimental_units(matches)
        return summarize_coverage(
            matches,
            deck_keys,
            config,
            mirror_units,
            cross_units,
        )
    except (TypeError, ValueError):
        return None


def _coverage_valid(payload: dict[str, Any], *, canonical_nightly: bool) -> bool:
    coverage = payload.get("coverage") or {}
    recomputed = _recomputed_main_coverage(payload)
    if (
        not isinstance(coverage, dict)
        or recomputed is None
        or coverage != recomputed
        or not bool(recomputed.get("complete"))
    ):
        return False
    if _int(recomputed.get("missing_match_count")) != 0:
        return False
    if _int(recomputed.get("unexpected_match_count")) != 0:
        return False
    if recomputed.get("structural_errors"):
        return False
    if canonical_nightly:
        return (
            _int(recomputed.get("expected_games")) == 2800
            and _int(recomputed.get("actual_games")) == 2800
            and _int(recomputed.get("expected_mirror_units")) == 500
            and _int(recomputed.get("actual_mirror_units")) == 500
            and _int(recomputed.get("complete_mirror_units")) == 500
            and _int(recomputed.get("expected_cross_units")) == 450
            and _int(recomputed.get("actual_cross_units")) == 450
            and _int(recomputed.get("complete_cross_units")) == 450
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


def _deep_release_runtime_validation(
    payload: dict[str, Any],
) -> dict[str, Any]:
    strategies = payload.get("strategies") or {}
    strategy_a = strategies.get("A") or {}
    strategy_b = strategies.get("B") or {}
    runtime_contract = (
        isinstance(strategy_a, dict)
        and isinstance(strategy_b, dict)
        and str(strategy_a.get("mode") or "") == "deep"
        and bool(strategy_a.get("production_runtime"))
        and str(strategy_b.get("mode") or "challenge") == "challenge"
        and bool(strategy_b.get("production_runtime"))
    )
    planner_id = "deep_root_ismcts_v1"
    planner_coverage = True
    latency_coverage = True
    decision_accounting = True
    deep_action_decisions = 0
    deep_latency_samples = 0
    maximum_decision_ms = 0.0
    malformed_rows: list[int] = []
    engine_mismatch_rows: list[int] = []
    latency_mismatch_rows: list[int] = []
    matches = payload.get("matches")
    if not isinstance(matches, list) or not matches:
        planner_coverage = False
        latency_coverage = False
        matches = []
    for row_index, row in enumerate(matches):
        if not isinstance(row, dict):
            malformed_rows.append(row_index)
            planner_coverage = False
            latency_coverage = False
            decision_accounting = False
            continue
        decisions = row.get("decisions")
        choices = row.get("choices")
        all_samples = row.get("decision_ms_samples")
        decisions_by_strategy = row.get("action_decisions_by_strategy")
        engine_counts_by_strategy = row.get(
            "decision_engine_counts_by_strategy"
        )
        timings_by_strategy = row.get("decision_ms_samples_by_strategy")
        if (
            not _is_nonnegative_int(decisions)
            or not _is_nonnegative_int(choices)
            or not isinstance(all_samples, list)
            or not isinstance(decisions_by_strategy, dict)
            or not isinstance(timings_by_strategy, dict)
            or any(
                not isinstance(timings_by_strategy.get(label), list)
                for label in ("A", "B")
            )
            or sum(
                _int(decisions_by_strategy.get(label))
                for label in ("A", "B")
            )
            != _int(decisions)
            or len(all_samples) != _int(decisions) + _int(choices)
            or sum(
                len(timings_by_strategy.get(label) or [])
                for label in ("A", "B")
            )
            != len(all_samples)
            or any(_float(value, None) is None for value in all_samples)
        ):
            decision_accounting = False
            malformed_rows.append(row_index)
        if not isinstance(decisions_by_strategy, dict) or not isinstance(
            engine_counts_by_strategy, dict
        ):
            planner_coverage = False
            malformed_rows.append(row_index)
        else:
            expected = _int(decisions_by_strategy.get("A"))
            raw_counts = engine_counts_by_strategy.get("A")
            counts = (
                {
                    str(key): _int(value)
                    for key, value in raw_counts.items()
                    if _int(value) > 0
                }
                if isinstance(raw_counts, dict)
                else {}
            )
            expected_counts = {planner_id: expected} if expected > 0 else {}
            if counts != expected_counts:
                planner_coverage = False
                engine_mismatch_rows.append(row_index)
            deep_action_decisions += expected
        by_strategy = timings_by_strategy
        samples = by_strategy.get("A") if isinstance(by_strategy, dict) else None
        if not isinstance(samples, list):
            latency_coverage = False
            latency_mismatch_rows.append(row_index)
            continue
        for sample in samples:
            elapsed = _float(sample, None)
            if elapsed is None or elapsed < 0.0:
                latency_coverage = False
                latency_mismatch_rows.append(row_index)
                continue
            maximum_decision_ms = max(maximum_decision_ms, elapsed)
            deep_latency_samples += 1
    if deep_action_decisions <= 0 or deep_latency_samples <= 0:
        planner_coverage = False
        latency_coverage = False
    timeout_free = (
        latency_coverage and maximum_decision_ms <= 2000.0 + 1e-12
    )
    return {
        "runtime_contract": runtime_contract,
        "decision_accounting": decision_accounting,
        "planner_coverage": planner_coverage,
        "timeout_free": timeout_free,
        "planner_id": planner_id,
        "deep_action_decisions": deep_action_decisions,
        "deep_latency_samples": deep_latency_samples,
        "maximum_decision_ms": maximum_decision_ms,
        "malformed_rows": malformed_rows[:20],
        "engine_mismatch_rows": engine_mismatch_rows[:20],
        "latency_mismatch_rows": latency_mismatch_rows[:20],
    }


def _golden_valid(payload: dict[str, Any]) -> tuple[bool, bool]:
    golden = payload.get("golden_scenarios") or {}
    by_scope = golden.get("by_scope") or {}
    decks = len(payload.get("deck_keys") or [])
    coverage_count = _int((by_scope.get("coverage_contract") or {}).get("total"))
    runtime_count = _int((by_scope.get("runtime_integration") or {}).get("total"))
    strategy_count = _int((by_scope.get("strategy_score") or {}).get("total"))
    turn_sequence_count = _int((by_scope.get("turn_sequence") or {}).get("total"))
    complete = (
        decks > 0
        and coverage_count == decks
        and runtime_count == 3
        and decks * 8 <= strategy_count <= decks * 12
        and turn_sequence_count == decks * 3
        and _int(golden.get("total"))
        == coverage_count + runtime_count + strategy_count + turn_sequence_count
    )
    return complete, _int(golden.get("failed")) == 0


def _performance_benchmark_validation(payload: dict[str, Any]) -> dict[str, Any]:
    performance = (
        payload.get("performance_benchmark")
        or payload.get("performance")
        or {}
    )
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
        and str(config.get("run_role")) in {
            "search_depth_probe",
            "performance_benchmark",
        }
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


def _main_depth_contract_valid(
    payload: dict[str, Any],
    *,
    strict_v2_depth: bool = True,
) -> bool:
    matches = payload.get("matches")
    strategies = payload.get("strategies")
    if not isinstance(matches, list) or not isinstance(strategies, dict):
        return False
    configured_engines: dict[str, str] = {}
    configured_modes: dict[str, str] = {}
    for strategy in ("A", "B"):
        descriptor = strategies.get(strategy)
        if not isinstance(descriptor, dict):
            return False
        engine = str(descriptor.get("engine") or "")
        if engine not in {"turn_beam_v1", "turn_beam_v2"}:
            return False
        configured_engines[strategy] = engine
        configured_modes[strategy] = str(descriptor.get("mode") or "")
    return all(
        match_decision_contract_error(
            row,
            configured_engines,
            configured_modes=configured_modes,
            strict_v2_depth=strict_v2_depth,
        )
        is None
        for row in matches
    )


def _main_depth_validation(
    payload: dict[str, Any],
    *,
    strict_v2_depth: bool,
) -> dict[str, Any]:
    matches = payload.get("matches")
    deck_keys = payload.get("deck_keys") or []
    if not isinstance(matches, list) or not isinstance(deck_keys, list):
        return {
            "metrics_valid": False,
            "contract_valid": False,
            "reported": {},
            "recomputed": {},
        }
    recomputed = summarize_search_depth(matches, deck_keys)
    reported = payload.get("search_depth") or {}
    contract_valid = _main_depth_contract_valid(
        payload,
        strict_v2_depth=strict_v2_depth,
    )
    metrics_valid = (
        payload.get("gate_depth_source") == "main_matches"
        and isinstance(reported, dict)
        and bool(recomputed.get("available"))
        and reported == recomputed
        and contract_valid
        and all(
            _int(
                (((reported.get("by_strategy") or {}).get(strategy) or {}).get(
                    "overall"
                ) or {}).get("sample_count")
            )
            > 0
            and all(
                _int(
                    ((((reported.get("by_strategy") or {}).get(strategy) or {}).get(
                        "per_deck"
                    ) or {}).get(deck) or {}).get("overall", {}).get("sample_count")
                )
                > 0
                for deck in deck_keys
            )
            for strategy in ("A", "B")
        )
    )
    return {
        "metrics_valid": metrics_valid,
        "contract_valid": contract_valid,
        "reported": reported,
        "recomputed": recomputed,
    }


def _search_depth_errors(
    reported: dict[str, Any], gate: str
) -> list[tuple[str, dict[str, Any]]]:
    errors: list[tuple[str, dict[str, Any]]] = []
    by_strategy = reported.get("by_strategy") or {}
    strategies = ("A", "B") if gate == "nightly-stability" else ("A",)
    for strategy in strategies:
        strategy_rows = by_strategy.get(strategy) or {}
        scopes: list[tuple[str, dict[str, Any]]] = [
            ("overall", strategy_rows.get("overall") or {})
        ]
        scopes.extend(
            (f"deck:{deck}", (row or {}).get("overall") or {})
            for deck, row in (strategy_rows.get("per_deck") or {}).items()
        )
        for scope, metrics in scopes:
            if _int(metrics.get("sample_count")) <= 0:
                continue
            engines = metrics.get("engines") or {}
            if (
                not isinstance(engines, dict)
                or set(engines) != {"turn_beam_v2"}
                or _int(engines.get("turn_beam_v2"))
                != _int(metrics.get("sample_count"))
            ):
                errors.append((
                    "search_depth_engine_mismatch",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "engines": engines,
                    },
                ))
            requested_min = _float(metrics.get("requested_depth_min"), None)
            requested_max = _float(metrics.get("requested_depth_max"), None)
            requested_floor = SEARCH_DEPTH_THRESHOLDS["requested_depth_min"]
            if requested_min is None or requested_min < requested_floor:
                errors.append((
                    "search_depth_requested_below_floor",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "value": requested_min,
                        "floor": requested_floor,
                    },
                ))
            requested_target = SEARCH_DEPTH_THRESHOLDS["requested_depth"]
            if (
                requested_min is None
                or requested_max is None
                or requested_min != requested_target
                or requested_max != requested_target
            ):
                errors.append((
                    "search_depth_requested_mismatch",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "minimum": requested_min,
                        "maximum": requested_max,
                        "required": requested_target,
                    },
                ))
            complete_rate = _float(
                metrics.get("complete_or_frontier_exhausted_rate"), None
            )
            complete_floor = SEARCH_DEPTH_THRESHOLDS[
                "complete_or_frontier_exhausted_rate_min"
            ]
            if complete_rate is None or complete_rate < complete_floor - 1e-12:
                errors.append((
                    "search_depth_incomplete",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "value": complete_rate,
                        "floor": complete_floor,
                    },
                ))
            deadline = _int(metrics.get("deadline_truncations"))
            node_budget = _int(metrics.get("node_budget_truncations"))
            if deadline > 0 or node_budget > 0:
                errors.append((
                    "search_depth_time_or_node_stop",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "deadline": deadline,
                        "node_budget": node_budget,
                    },
                ))
            reply_applicable = _int(
                metrics.get("reply_applicable_count")
            )
            if reply_applicable <= 0:
                errors.append((
                    "reply_depth_evidence_missing",
                    {
                        "strategy": strategy,
                        "scope": scope,
                    },
                ))
                continue
            reply_requested_min = _float(
                metrics.get("reply_requested_depth_min"), None
            )
            reply_requested_max = _float(
                metrics.get("reply_requested_depth_max"), None
            )
            reply_target = SEARCH_DEPTH_THRESHOLDS[
                "reply_requested_depth"
            ]
            if (
                reply_requested_min is None
                or reply_requested_max is None
                or reply_requested_min != reply_target
                or reply_requested_max != reply_target
            ):
                errors.append((
                    "reply_depth_requested_mismatch",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "minimum": reply_requested_min,
                        "maximum": reply_requested_max,
                        "required": reply_target,
                    },
                ))
            reply_complete_rate = _float(
                metrics.get(
                    "reply_complete_or_frontier_exhausted_rate"
                ),
                None,
            )
            reply_complete_floor = SEARCH_DEPTH_THRESHOLDS[
                "reply_complete_or_frontier_exhausted_rate_min"
            ]
            if (
                reply_complete_rate is None
                or reply_complete_rate
                < reply_complete_floor - 1e-12
            ):
                errors.append((
                    "reply_depth_incomplete",
                    {
                        "strategy": strategy,
                        "scope": scope,
                        "value": reply_complete_rate,
                        "floor": reply_complete_floor,
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
        "nightly-superiority",
        "deep-practical",
        "deep-release",
    }
    canonical_nightly = (
        normalized_gate.startswith("nightly-")
        or normalized_gate == "deep-release"
    )

    schema_valid = _int(payload.get("schema_version")) == SCHEMA_VERSION
    _check(checks, "schema", "integrity", schema_valid, f"schema v{SCHEMA_VERSION}")
    if not schema_valid:
        _append_issue(errors, "schema_version", "integrity", actual=payload.get("schema_version"))
    protocol_valid = str(payload.get("protocol_id") or "") == PROTOCOL_ID
    _check(checks, "protocol", "integrity", protocol_valid, PROTOCOL_ID)
    if not protocol_valid:
        _append_issue(
            errors,
            "protocol_id",
            "integrity",
            actual=payload.get("protocol_id"),
        )
    artifact_valid = payload.get("artifact_kind") == "ai_evaluation_result"
    _check(checks, "artifact", "integrity", artifact_valid, "权威聚合结果")
    if not artifact_valid:
        _append_issue(errors, "artifact_kind", "integrity")
    provenance = payload.get("provenance") or {}
    provenance_valid = (
        isinstance(provenance, dict)
        and _int(provenance.get("schema_version")) == SCHEMA_VERSION
        and str(provenance.get("protocol_id") or "") == PROTOCOL_ID
        and _valid_sha256(provenance.get("simulation_fingerprint"))
        and _valid_sha256(provenance.get("analysis_fingerprint"))
        and payload.get("simulation_fingerprint")
        == provenance.get("simulation_fingerprint")
        and payload.get("analysis_fingerprint")
        == provenance.get("analysis_fingerprint")
    )
    _check(checks, "provenance", "integrity", provenance_valid, "来源指纹")
    if not provenance_valid:
        _append_issue(errors, "provenance_missing", "integrity")
    expected_analysis_fingerprint = current_analysis_fingerprint(
        Path(__file__).resolve().parents[2]
    )
    analysis_fingerprint_current = (
        provenance_valid
        and str(payload.get("analysis_fingerprint") or "")
        == expected_analysis_fingerprint
    )
    _check(
        checks,
        "analysis_fingerprint",
        "integrity",
        analysis_fingerprint_current,
        "当前分析代码指纹",
    )
    if provenance_valid and not analysis_fingerprint_current:
        _append_issue(
            errors,
            "analysis_fingerprint_stale",
            "integrity",
            expected=expected_analysis_fingerprint,
            actual=payload.get("analysis_fingerprint"),
        )

    if not schema_valid or not protocol_valid or not artifact_valid:
        return _result(
            payload,
            normalized_gate,
            platform,
            errors,
            warnings,
            checks,
            {},
        )

    config = payload.get("config") or {}
    execution_config = payload.get("execution_config")
    manifest_id = str(payload.get("task_manifest_id") or "")
    canonical_manifest = ""
    if isinstance(config, dict):
        try:
            canonical_manifest = task_manifest_id(
                payload.get("deck_keys") or [],
                config,
            )
        except (TypeError, ValueError):
            canonical_manifest = ""
    provenance_simulation_config = (
        provenance.get("simulation_config")
        if isinstance(provenance, dict)
        else None
    )
    simulation_config_state, simulation_config_fields = (
        _simulation_config_binding(
            payload,
            config,
            execution_config,
            provenance_simulation_config,
            manifest_id,
        )
    )
    simulation_config_valid = simulation_config_state == "valid"
    _check(
        checks,
        "simulation_config",
        "integrity",
        simulation_config_valid,
        "来源指纹绑定完整赛程与执行配置",
        state=simulation_config_state,
        fields=simulation_config_fields,
    )
    if simulation_config_state == "invalid" or (
        canonical_nightly and not simulation_config_valid
    ):
        _append_issue(
            errors,
            "simulation_config",
            "integrity",
            fields=simulation_config_fields,
        )

    godot_hash = (
        provenance.get("godot_executable_sha256")
        if isinstance(provenance, dict)
        else None
    )
    godot_hash_valid = _valid_sha256(godot_hash)
    godot_hash_missing = godot_hash in (None, "")
    _check(
        checks,
        "godot_executable_hash",
        "integrity",
        godot_hash_valid,
        "Godot 可执行文件 SHA-256",
    )
    if (not godot_hash_valid) and (
        canonical_nightly or not godot_hash_missing
    ):
        _append_issue(
            errors,
            "godot_executable_hash",
            "integrity",
            actual=godot_hash,
        )
    legacy_provenance_fields: list[str] = []
    if simulation_config_state == "legacy":
        legacy_provenance_fields.extend(simulation_config_fields)
    if godot_hash_missing:
        legacy_provenance_fields.append(
            "provenance.godot_executable_sha256"
        )
    if legacy_provenance_fields and not canonical_nightly:
        _append_issue(
            warnings,
            "legacy_provenance_compatibility",
            "integrity",
            fields=sorted(set(legacy_provenance_fields)),
        )
    try:
        recomputed_simulation_fingerprint = (
            simulation_fingerprint_from_provenance(provenance)
            if isinstance(provenance, dict)
            else ""
        )
    except (TypeError, ValueError):
        recomputed_simulation_fingerprint = ""
    simulation_fingerprint_recomputed = (
        provenance_valid
        and recomputed_simulation_fingerprint
        == str(provenance.get("simulation_fingerprint") or "")
    )
    simulation_fingerprint_accepted = (
        simulation_fingerprint_recomputed
        or bool(legacy_provenance_fields)
        and not canonical_nightly
    )
    _check(
        checks,
        "simulation_fingerprint",
        "integrity",
        simulation_fingerprint_accepted,
        "来源稳定字段重算模拟指纹",
    )
    if not simulation_fingerprint_accepted:
        _append_issue(
            errors,
            "simulation_fingerprint_mismatch",
            "integrity",
            expected=recomputed_simulation_fingerprint,
            actual=(
                provenance.get("simulation_fingerprint")
                if isinstance(provenance, dict)
                else None
            ),
        )

    provenance_manifest = (
        str(provenance_simulation_config.get("task_manifest_id") or "")
        if isinstance(provenance_simulation_config, dict)
        else ""
    )
    provenance_manifest_valid = (
        provenance_manifest == manifest_id
        if simulation_config_state != "legacy" or canonical_nightly
        else True
    )
    manifest_valid = (
        _valid_sha256(manifest_id)
        and isinstance(config, dict)
        and str(config.get("task_manifest_id") or "") == manifest_id
        and canonical_manifest == manifest_id
        and isinstance(execution_config, dict)
        and str(execution_config.get("task_manifest_id") or "")
        == manifest_id
        and provenance_manifest_valid
    )
    _check(checks, "task_manifest", "integrity", manifest_valid, "固定任务清单")
    if not manifest_valid:
        _append_issue(errors, "task_manifest", "integrity")
    execution_config_valid = (
        isinstance(execution_config, dict)
        and _int(execution_config.get("parallel_workers")) > 0
        and str(execution_config.get("platform") or "")
        == str(payload.get("platform") or "")
        and str(execution_config.get("task_manifest_id") or "")
        == manifest_id
    )
    _check(
        checks,
        "execution_config",
        "integrity",
        execution_config_valid,
        "执行配置",
    )
    if not execution_config_valid:
        _append_issue(errors, "execution_config", "integrity")
    checkpoint_valid, checkpoint_errors = (
        _checkpoint_summary_validation(
            payload,
            canonical_nightly=canonical_nightly,
        )
    )
    _check(
        checks,
        "checkpoint_summary",
        "integrity",
        checkpoint_valid,
        "检查点证据单元与分片摘要",
        errors=checkpoint_errors,
    )
    if not checkpoint_valid:
        _append_issue(
            errors,
            "checkpoint_summary",
            "integrity",
            errors=checkpoint_errors,
        )
    wall_clock_valid, wall_clock_errors = (
        _wall_clock_metadata_validation(payload)
    )
    _check(
        checks,
        "wall_clock_metadata",
        "integrity",
        wall_clock_valid,
        "墙钟耗时范围与数值配对",
        errors=wall_clock_errors,
    )
    if not wall_clock_valid:
        _append_issue(
            errors,
            "wall_clock_metadata",
            "integrity",
            errors=wall_clock_errors,
        )
    depth_source_valid = payload.get("gate_depth_source") == "main_matches"
    _check(
        checks,
        "gate_depth_source",
        "search_depth",
        depth_source_valid,
        "主评测矩阵作为深度门禁来源",
    )
    if not depth_source_valid:
        _append_issue(errors, "gate_depth_source", "search_depth")

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
    deep_release = normalized_gate == "deep-release"
    deep_runtime = (
        _deep_release_runtime_validation(payload)
        if deep_release
        else {}
    )
    main_depth = _main_depth_validation(
        payload,
        strict_v2_depth=strict and not deep_release,
    )
    depth_contract_valid = (
        bool(deep_runtime.get("decision_accounting"))
        if deep_release
        else bool(main_depth.get("contract_valid"))
    )
    _check(
        checks,
        "search_depth_decision_accounting",
        "search_depth",
        depth_contract_valid,
        "动作决策与搜索深度样本守恒",
    )
    if not depth_contract_valid:
        _append_issue(
            errors,
            "search_depth_decision_accounting",
            "search_depth",
        )
    depth_metrics_valid = bool(main_depth.get("metrics_valid"))
    _check(
        checks,
        "search_depth_main_matrix",
        "search_depth",
        depth_metrics_valid if strict and not deep_release else True,
        "主矩阵 A/B 实际 beam 搜索深度"
        if strict
        else "主矩阵搜索深度样本（此门禁不要求）",
        available=depth_metrics_valid,
    )
    if strict and not deep_release and not depth_metrics_valid:
        _append_issue(errors, "search_depth_metrics", "search_depth")
    depth_errors = (
        _search_depth_errors(
            main_depth.get("recomputed") or {},
            normalized_gate,
        )
        if bool((main_depth.get("recomputed") or {}).get("available"))
        else []
    )
    if strict and not deep_release:
        for code, details in depth_errors:
            _append_issue(errors, code, "search_depth", **details)
    _check(
        checks,
        "search_depth_thresholds",
        "search_depth",
        (
            not depth_errors and depth_metrics_valid
            if strict and not deep_release
            else True
        ),
        "候选侧全预算搜索深度"
        if strict
        else "搜索深度阈值（此门禁不要求）",
        thresholds=SEARCH_DEPTH_THRESHOLDS,
    )

    benchmark = _performance_benchmark_validation(payload)
    benchmark_payload = (
        payload.get("performance_benchmark")
        or payload.get("performance")
        or {}
    )
    benchmark_available = bool(
        isinstance(benchmark_payload, dict)
        and benchmark_payload.get("available")
    )
    benchmark_valid = bool(
        benchmark.get("coverage_valid")
        and benchmark.get("latency_metrics_valid")
        and benchmark.get("search_depth_metrics_valid")
    )
    _check(
        checks,
        "latency_diagnostics",
        "performance",
        True,
        "可选性能基准仅作诊断，不参与门禁",
        available=benchmark_available,
        valid=benchmark_valid if benchmark_available else None,
        metrics=benchmark.get("latency") or {},
    )
    if benchmark_available and not benchmark_valid:
        _append_issue(
            warnings,
            "performance_benchmark_invalid",
            "performance",
        )

    relation_valid = True
    if normalized_gate == "nightly-stability":
        relation_valid = _strategies_equal(payload)
    elif normalized_gate in {
        "nightly-equivalence",
        "nightly-superiority",
        "deep-practical",
        "deep-release",
    }:
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
    if normalized_gate in {
        "nightly-equivalence",
        "nightly-superiority",
        "deep-practical",
        "deep-release",
    }:
        ci_floor = (
            0.0
            if normalized_gate == "nightly-superiority"
            else (
                -0.02
                if normalized_gate in {
                    "nightly-equivalence",
                    "deep-release",
                }
                else -0.04
            )
        )
        mirror_lower = _ci_lower(mirror)
        cross_lower = _ci_lower(cross)
        mirror_ok = (
            mirror_lower is not None
            and (
                mirror_lower > 0.0
                if normalized_gate == "nightly-superiority"
                else mirror_lower >= ci_floor - 1e-12
            )
        )
        cross_ok = (
            cross_lower is not None
            and (
                cross_lower > 0.0
                if normalized_gate == "nightly-superiority"
                else cross_lower >= ci_floor - 1e-12
            )
        )
        _check(checks, "mirror_equivalence", "strength", mirror_ok, "镜像 CI 下界", lower=mirror_lower, floor=ci_floor)
        _check(checks, "cross_equivalence", "strength", cross_ok, "交叉 CI 下界", lower=cross_lower, floor=ci_floor)
        if not mirror_ok:
            _append_issue(errors, "mirror_ci_below_floor", "strength", lower=mirror_lower, floor=ci_floor)
        if not cross_ok:
            _append_issue(errors, "cross_ci_below_floor", "strength", lower=cross_lower, floor=ci_floor)

        deck_floor = (
            -0.04
            if normalized_gate in {
                "nightly-equivalence",
                "nightly-superiority",
                "deep-release",
            }
            else -0.08
        )
        for deck, stats in (mirror.get("per_deck") or {}).items():
            delta = _float(stats.get("point_delta"), None)
            if delta is None or delta < deck_floor - 1e-12:
                _append_issue(
                    errors,
                    f"mirror_deck_{deck}_below_floor",
                    "strength",
                    deck=deck,
                    delta=delta,
                    floor=deck_floor,
                )
        if normalized_gate in {
            "nightly-equivalence",
            "nightly-superiority",
            "deep-release",
        }:
            for matchup, stats in (cross.get("per_unordered_matchup") or {}).items():
                delta = _float(stats.get("point_delta"), None)
                if delta is None or delta < -0.08 - 1e-12:
                    _append_issue(
                        errors,
                        f"cross_matchup_{matchup}_below_floor",
                        "strength",
                        matchup=matchup,
                        delta=delta,
                        floor=-0.08,
                    )

        diagnostics = payload.get("decision_diagnostics") or {}
        diagnostic_by_strategy = diagnostics.get("by_strategy") or {}
        if normalized_gate == "nightly-superiority":
            a_rates = (diagnostic_by_strategy.get("A") or {}).get("rates") or {}
            b_rates = (diagnostic_by_strategy.get("B") or {}).get("rates") or {}
            weak_label = "weak_attack_before_development"
            weak_a = _float(a_rates.get(weak_label), 0.0) or 0.0
            weak_b = _float(b_rates.get(weak_label), 0.0) or 0.0
            weak_ok = weak_a <= weak_b * 0.5 + 1e-12
            _check(
                checks,
                "weak_attack_reduction",
                "diagnostics",
                weak_ok,
                "过早弱攻击发生率至少下降 50%",
                candidate=weak_a,
                baseline=weak_b,
            )
            if not weak_ok:
                _append_issue(
                    errors,
                    "weak_attack_not_reduced",
                    "diagnostics",
                    candidate=weak_a,
                    baseline=weak_b,
                )
            for label in sorted(set(a_rates) | set(b_rates)):
                if label == weak_label:
                    continue
                candidate_rate = _float(a_rates.get(label), 0.0) or 0.0
                baseline_rate = _float(b_rates.get(label), 0.0) or 0.0
                if candidate_rate > baseline_rate + 0.001 + 1e-12:
                    _append_issue(
                        errors,
                        "diagnostic_rate_regression",
                        "diagnostics",
                        label=label,
                        candidate=candidate_rate,
                        baseline=baseline_rate,
                        allowed_increase=0.001,
                    )
        else:
            diagnostic_ok = diagnostic_delta <= 0
            _check(checks, "decision_diagnostics", "diagnostics", diagnostic_ok, "候选错因不多于对照", delta=diagnostic_delta)
            if not diagnostic_ok:
                _append_issue(errors, "decision_diagnostics_regression", "diagnostics", delta=diagnostic_delta)

    if normalized_gate == "deep-release":
        runtime_ok = bool(deep_runtime.get("runtime_contract"))
        _check(
            checks,
            "deep_runtime_contract",
            "runtime",
            runtime_ok,
            "Deep A 对 Challenge B 且双方使用正式隐藏信息快照",
        )
        if not runtime_ok:
            _append_issue(errors, "deep_runtime_contract", "runtime")
        planner_ok = bool(deep_runtime.get("planner_coverage"))
        _check(
            checks,
            "deep_planner_coverage",
            "runtime",
            planner_ok,
            "A 侧动作全部由 deep_root_ismcts_v1 完成",
            **deep_runtime,
        )
        if not planner_ok:
            _append_issue(
                errors,
                "deep_planner_coverage",
                "runtime",
                **deep_runtime,
            )
        timeout_ok = bool(deep_runtime.get("timeout_free"))
        _check(
            checks,
            "deep_decision_timeout",
            "performance",
            timeout_ok,
            "全部适用 Deep 决策不超过 2000ms",
            maximum_decision_ms=deep_runtime.get("maximum_decision_ms"),
            samples=deep_runtime.get("deep_latency_samples"),
        )
        if not timeout_ok:
            _append_issue(
                errors,
                "deep_decision_timeout",
                "performance",
                maximum_decision_ms=deep_runtime.get(
                    "maximum_decision_ms"
                ),
            )

    if normalized_gate in {"deep-practical", "deep-release"}:
        observed = payload.get("observed") or {}
        fallback_rate = _float(observed.get("deep_fallback_rate"), 0.0) or 0.0
        fallback_count = _int(observed.get("deep_fallbacks"))
        fallback_ok = fallback_rate == 0.0 and fallback_count == 0
        _check(checks, "deep_fallback", "reliability", fallback_ok, "Deep 零回退", rate=fallback_rate)
        if not fallback_ok:
            _append_issue(
                errors,
                "deep_fallback_rate",
                "reliability",
                rate=fallback_rate,
                count=fallback_count,
            )
    elif normalized_gate not in {
        "nightly-stability",
        "nightly-equivalence",
        "nightly-superiority",
        "deep-release",
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
        "protocol_id": PROTOCOL_ID,
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
            "nightly-superiority",
            "deep-practical",
            "deep-release",
            "deep-noninferiority",
            "hybrid-release",
            "stability",
            "equivalence",
            "superiority",
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

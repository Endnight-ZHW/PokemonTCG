"""Compare deterministic results and performance of two schema-v7 profiles."""
from __future__ import annotations

import argparse
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

try:
    from scripts.ai_evaluation_v7 import (
        DECK_ORDER,
        PROTOCOL_ID,
        SCHEMA_VERSION,
        expected_match_identities,
        match_decision_contract_error,
        performance_host_fingerprint,
        task_manifest_id,
    )
except ModuleNotFoundError:
    from ai_evaluation_v7 import (
        DECK_ORDER,
        PROTOCOL_ID,
        SCHEMA_VERSION,
        expected_match_identities,
        match_decision_contract_error,
        performance_host_fingerprint,
        task_manifest_id,
    )


_MATCH_SOURCE_FIELDS = {
    "task_index",
    "task_shard_index",
    "task_shard_count",
    "source_shard_index",
    "evidence_shard_index",
    "evidence_shard_count",
}
_MATCH_SEPARATELY_COMPARED_FIELDS = {"search_depth_samples_by_strategy"}
_V2_ENGINE_ID = "turn_beam_v2"
_FIXED_280_REQUIRED_COMPONENT_HASHES = (
    "rules",
    "ai",
    "card_data",
    "evaluation_tool",
)
_FIXED_280_NON_TARGET_COMPONENT_HASHES = (
    "rules",
    "card_data",
    "evaluation_tool",
)
_V2_TRACE_INTEGER_FIELDS = (
    "requested",
    "reached",
    "completed",
    "max_path_depth",
    "reply_requested",
    "reply_completed",
    "layers_completed",
    "nodes_expanded",
)
_V2_TRACE_STRING_FIELDS = (
    "completion_reason",
    "stop_reason",
    "reply_completion_reason",
    "trajectory_hash",
    "decision_semantic_hash",
)
FIXED_280_SCHEDULE = {
    "protocol_id": PROTOCOL_ID,
    "seed": 17,
    "seed_blocks_per_deck": 5,
    "cross_seed_blocks_per_matchup": 1,
    "seed_block_start": 0,
    "seed_block_count": 0,
    "task_start": 0,
    "task_count": 0,
    "max_actions": 1200,
    "matchup_mode": "Balanced",
    "rules_options": {"apply_type_matchups": False},
}
FIXED_280_TASK_MANIFEST_ID = task_manifest_id(
    DECK_ORDER, FIXED_280_SCHEDULE
)
FIXED_280_CORPUS_ID = (
    "traditional_ai_v2_fixed_280:"
    f"{FIXED_280_TASK_MANIFEST_ID}"
)
_FIXED_280_IDENTITIES = frozenset(
    expected_match_identities(DECK_ORDER, FIXED_280_SCHEDULE)
)


def _float(value: Any, default: float = 0.0) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return default
    return result if math.isfinite(result) else default


def _finite_number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def _int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return default


def _is_nonnegative_int(value: Any) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and value >= 0
    )


def _valid_sha256(value: Any) -> bool:
    normalized = str(value or "")
    return len(normalized) == 64 and all(
        character in "0123456789abcdef" for character in normalized
    )


def _is_timing_field(key: str) -> bool:
    return (
        key == "elapsed_ms"
        or key.endswith("_ms")
        or "_ms_samples" in key
    )


def _normalize_match_value(value: Any) -> Any:
    """Remove execution-only data while preserving all gameplay observations."""
    if isinstance(value, dict):
        normalized: dict[str, Any] = {}
        for raw_key, child in value.items():
            key = str(raw_key)
            if (
                key in _MATCH_SOURCE_FIELDS
                or key in _MATCH_SEPARATELY_COMPARED_FIELDS
                or _is_timing_field(key)
            ):
                continue
            normalized[key] = _normalize_match_value(child)
        return normalized
    if isinstance(value, list):
        return [_normalize_match_value(child) for child in value]
    if isinstance(value, float) and math.isfinite(value) and value.is_integer():
        return int(value)
    return value


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _match_signature(payload: dict[str, Any]) -> list[str]:
    rows = payload.get("matches") or []
    if not isinstance(rows, list):
        return []
    return sorted(
        _canonical_json(_normalize_match_value(row))
        for row in rows
        if isinstance(row, dict)
    )


def _match_identity(row: dict[str, Any]) -> tuple[Any, ...]:
    return (
        str(row.get("sample_phase") or "main"),
        str(row.get("matchup_kind") or ""),
        str(row.get("strategy_a_deck") or row.get("deck") or ""),
        str(row.get("strategy_b_deck") or row.get("deck") or ""),
        _int(row.get("seed_block")),
        _int(row.get("seed")),
        _int(row.get("seat")),
        str(row.get("pair_key") or ""),
    )


def _v2_trace_signature(
    payload: dict[str, Any],
) -> tuple[list[tuple[Any, ...]], list[str]]:
    traces: list[tuple[Any, ...]] = []
    errors: list[str] = []
    identities: set[tuple[Any, ...]] = set()
    rows = payload.get("matches") or []
    if not isinstance(rows, list):
        return [], ["matches_not_list"]
    for row_index, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"match_{row_index}:not_object")
            continue
        identity = _match_identity(row)
        if identity in identities:
            errors.append(f"match_{row_index}:duplicate_identity")
        identities.add(identity)
        samples_by_strategy = row.get("search_depth_samples_by_strategy")
        if not isinstance(samples_by_strategy, dict):
            errors.append(f"match_{row_index}:search_samples_not_object")
            continue
        for strategy in ("A", "B"):
            samples = samples_by_strategy.get(strategy)
            if not isinstance(samples, list):
                errors.append(f"match_{row_index}:{strategy}:samples_not_list")
                continue
            for sample_index, sample in enumerate(samples):
                if not isinstance(sample, dict):
                    errors.append(
                        f"match_{row_index}:{strategy}:{sample_index}:not_object"
                    )
                    continue
                if str(sample.get("engine_id") or "") != _V2_ENGINE_ID:
                    continue
                missing = [
                    key
                    for key in (
                        *_V2_TRACE_INTEGER_FIELDS,
                        *_V2_TRACE_STRING_FIELDS,
                        "reply_applicable",
                    )
                    if key not in sample
                ]
                if missing:
                    errors.append(
                        f"match_{row_index}:{strategy}:{sample_index}:"
                        f"missing_{','.join(missing)}"
                    )
                integer_values = tuple(
                    _int(sample.get(field), -1)
                    for field in _V2_TRACE_INTEGER_FIELDS
                )
                string_values = tuple(
                    str(sample.get(field) or "")
                    for field in _V2_TRACE_STRING_FIELDS
                )
                if any(value < 0 for value in integer_values):
                    errors.append(
                        f"match_{row_index}:{strategy}:{sample_index}:invalid_integer"
                    )
                if any(not value for value in string_values):
                    errors.append(
                        f"match_{row_index}:{strategy}:{sample_index}:empty_reason_or_hash"
                    )
                if not _valid_sha256(sample.get("trajectory_hash")):
                    errors.append(
                        f"match_{row_index}:{strategy}:{sample_index}:"
                        "invalid_trajectory_hash"
                    )
                if not _valid_sha256(
                    sample.get("decision_semantic_hash")
                ):
                    errors.append(
                        f"match_{row_index}:{strategy}:{sample_index}:"
                        "invalid_decision_semantic_hash"
                    )
                traces.append((
                    *identity,
                    strategy,
                    sample_index,
                    *integer_values,
                    bool(sample.get("reply_applicable")),
                    *string_values,
                ))
    traces.sort()
    return traces, errors


def _schedule_match_identity(row: dict[str, Any]) -> tuple[str, str, str, int, int, int]:
    deck_a = str(row.get("strategy_a_deck") or row.get("deck") or "")
    deck_b = str(row.get("strategy_b_deck") or row.get("deck") or "")
    return (
        str(row.get("matchup_kind") or ""),
        deck_a,
        deck_b,
        _int(row.get("seed_block"), -1),
        _int(row.get("seed")),
        _int(row.get("seat"), -1),
    )


def _is_clean_fixed_280_match(row: dict[str, Any]) -> bool:
    stop_reasons = row.get("dynamic_budget_stop_reasons") or {}
    return (
        str(row.get("terminal_reason") or "") == "game_over"
        and _int(row.get("invalid_actions"), -1) == 0
        and _int(row.get("choice_failures"), -1) == 0
        and _int(row.get("rule_exceptions"), -1) == 0
        and _int(row.get("time_capped_decisions"), 0) == 0
        and _int(row.get("deep_fallbacks"), 0) == 0
        and not bool(row.get("max_actions_exhausted"))
        and isinstance(stop_reasons, dict)
        and not any(_int(value) for value in stop_reasons.values())
    )


def _fixed_280_execution(
    payload: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    config = payload.get("config")
    execution = payload.get("execution_config")
    provenance = payload.get("provenance")
    if not isinstance(config, dict):
        config = {}
        errors.append("config_not_object")
    if not isinstance(execution, dict):
        execution = {}
        errors.append("execution_config_not_object")
    provenance_config: dict[str, Any] = {}
    provenance_host: dict[str, Any] = {}
    if isinstance(provenance, dict):
        candidate = provenance.get("simulation_config")
        if isinstance(candidate, dict):
            provenance_config = candidate
        candidate_host = provenance.get("host")
        if isinstance(candidate_host, dict):
            provenance_host = candidate_host
        else:
            errors.append("performance_host_not_object")
    else:
        errors.append("provenance_not_object")

    godot_executable_sha256 = (
        str(provenance.get("godot_executable_sha256") or "")
        if isinstance(provenance, dict)
        else ""
    )
    if not _valid_sha256(godot_executable_sha256):
        errors.append("godot_executable_sha256_invalid")

    component_hashes = (
        provenance.get("component_hashes")
        if isinstance(provenance, dict)
        else None
    )
    normalized_component_hashes: dict[str, str] = {}
    if not isinstance(component_hashes, dict):
        errors.append("component_hashes_not_object")
    else:
        for component in _FIXED_280_REQUIRED_COMPONENT_HASHES:
            value = str(component_hashes.get(component) or "")
            if not _valid_sha256(value):
                errors.append(f"component_hash_{component}_invalid")
            else:
                normalized_component_hashes[component] = value

    platform = str(payload.get("platform") or "")
    platform_values = [
        platform,
        str(config.get("platform") or ""),
        str(execution.get("platform") or ""),
    ]
    provenance_platform = (
        str(provenance.get("target_platform") or "")
        if isinstance(provenance, dict)
        else ""
    )
    if provenance_platform:
        platform_values.append(provenance_platform)
    if not platform or any(value != platform for value in platform_values):
        errors.append("platform_inconsistent")

    worker_values = [
        _int(execution.get("workers"), -1),
        _int(execution.get("parallel_workers"), -1),
        _int(execution.get("global_parallel_workers"), -1),
    ]
    if provenance_config:
        worker_values.extend([
            _int(provenance_config.get("workers"), -1),
            _int(provenance_config.get("global_parallel_workers"), -1),
        ])
    if any(value != 12 for value in worker_values):
        errors.append("workers_not_fixed_12")

    profile = execution.get("profile")
    disable_ai_cache = execution.get("disable_ai_cache")
    disable_native_math = execution.get("disable_native_math")
    for key, value in (
        ("profile", profile),
        ("disable_ai_cache", disable_ai_cache),
        ("disable_native_math", disable_native_math),
    ):
        if not isinstance(value, bool):
            errors.append(f"{key}_not_boolean")
            continue
        if config.get(key) is not value:
            errors.append(f"{key}_inconsistent")
        if key in provenance_config and provenance_config.get(key) is not value:
            errors.append(f"{key}_provenance_inconsistent")
    if disable_ai_cache is not False:
        errors.append("ai_cache_not_enabled")
    if disable_native_math is not False:
        errors.append("native_math_not_enabled")

    evidence_shards = _int(execution.get("evidence_shard_count"), -1)
    if (
        evidence_shards != 50
        or _int(config.get("evidence_shard_count"), -1) != 50
        or (
            provenance_config
            and _int(provenance_config.get("evidence_shard_count"), -1) != 50
        )
    ):
        errors.append("evidence_shard_count_not_50")

    profile_ids = [
        str(payload.get("execution_profile_id") or ""),
        str(config.get("execution_profile_id") or ""),
        str(execution.get("execution_profile_id") or ""),
    ]
    if provenance_config:
        profile_ids.append(
            str(provenance_config.get("execution_profile_id") or "")
        )
    execution_profile_id = profile_ids[0]
    if (
        not execution_profile_id
        or any(value != execution_profile_id for value in profile_ids)
    ):
        errors.append("execution_profile_id_inconsistent")

    required_host_fields = (
        "system",
        "release",
        "machine",
        "python",
    )
    if any(
        not isinstance(provenance_host.get(key), str)
        or not str(provenance_host.get(key) or "").strip()
        for key in required_host_fields
    ) or not isinstance(provenance_host.get("processor"), str):
        errors.append("performance_host_fields")
    godot_runtime_version = (
        str(provenance.get("godot_runtime_version") or "")
        if isinstance(provenance, dict)
        else ""
    )
    target_platform = (
        str(provenance.get("target_platform") or "")
        if isinstance(provenance, dict)
        else ""
    )
    if not godot_runtime_version.strip() or not target_platform.strip():
        errors.append("performance_host_runtime_fields")
    derived_host_fingerprint = performance_host_fingerprint(
        provenance_host,
        godot_runtime_version=godot_runtime_version,
        target_platform=target_platform,
    )
    explicit_host_fingerprint = (
        str(provenance.get("performance_host_fingerprint") or "")
        if isinstance(provenance, dict)
        else ""
    )
    has_new_host_contract = (
        isinstance(provenance, dict)
        and "godot_executable_sha256" in provenance
    )
    if has_new_host_contract and not explicit_host_fingerprint:
        errors.append("performance_host_fingerprint_missing")
    if explicit_host_fingerprint:
        if (
            len(explicit_host_fingerprint) != 64
            or any(
                character not in "0123456789abcdef"
                for character in explicit_host_fingerprint
            )
        ):
            errors.append("performance_host_fingerprint_invalid")
        elif explicit_host_fingerprint != derived_host_fingerprint:
            errors.append("performance_host_fingerprint_mismatch")
    host_fingerprint = (
        explicit_host_fingerprint or derived_host_fingerprint
    )

    return {
        "platform": platform,
        "workers": 12,
        "evidence_shard_count": evidence_shards,
        "disable_ai_cache": disable_ai_cache,
        "disable_native_math": disable_native_math,
        "profile": profile,
        "execution_profile_id": execution_profile_id,
        "performance_host_fingerprint": host_fingerprint,
        "godot_executable_sha256": godot_executable_sha256,
        "non_target_component_hashes": {
            component: normalized_component_hashes.get(component, "")
            for component in _FIXED_280_NON_TARGET_COMPONENT_HASHES
        },
    }, errors


def _fixed_280_payload_validation(
    payload: dict[str, Any],
) -> dict[str, Any]:
    errors: list[str] = []
    deck_keys = payload.get("deck_keys")
    if deck_keys != DECK_ORDER:
        errors.append("deck_keys_not_canonical")

    config = payload.get("config")
    if not isinstance(config, dict):
        config = {}
        errors.append("config_not_object")
    expected_config = {
        "seed": 17,
        "seed_blocks_per_deck": 5,
        "cross_seed_blocks_per_matchup": 1,
        "seed_block_start": 0,
        "task_start": 0,
        "task_count": 0,
        "max_actions": 1200,
    }
    for key, expected in expected_config.items():
        if _int(config.get(key), -1) != expected:
            errors.append(f"config_{key}")
    if _int(config.get("seed_block_count"), -1) not in (0, 5):
        errors.append("config_seed_block_count")
    if str(config.get("matchup_mode") or "").lower() != "balanced":
        errors.append("config_matchup_mode")
    if config.get("rules_options") != {"apply_type_matchups": False}:
        errors.append("config_rules_options")
    if str(config.get("run_role") or "main") != "main":
        errors.append("config_run_role")

    manifest_values = [
        str(payload.get("task_manifest_id") or ""),
        str(config.get("task_manifest_id") or ""),
    ]
    execution = payload.get("execution_config")
    if isinstance(execution, dict):
        manifest_values.append(str(execution.get("task_manifest_id") or ""))
    provenance = payload.get("provenance")
    if isinstance(provenance, dict):
        provenance_config = provenance.get("simulation_config")
        if isinstance(provenance_config, dict):
            manifest_values.append(
                str(provenance_config.get("task_manifest_id") or "")
            )
    if any(value != FIXED_280_TASK_MANIFEST_ID for value in manifest_values):
        errors.append("task_manifest_id_not_canonical")

    strategies = payload.get("strategies")
    if not isinstance(strategies, dict):
        strategies = {}
        errors.append("strategies_not_object")
    for strategy in ("A", "B"):
        descriptor = strategies.get(strategy)
        if (
            not isinstance(descriptor, dict)
            or str(descriptor.get("engine") or "") != _V2_ENGINE_ID
        ):
            errors.append(f"strategy_{strategy}_not_turn_beam_v2")
    strategy_fingerprint = payload.get("strategy_fingerprint")
    strategy_identity = ""
    if not isinstance(strategy_fingerprint, dict):
        errors.append("strategy_fingerprint_not_object")
    else:
        fingerprint_a = str(strategy_fingerprint.get("A") or "")
        fingerprint_b = str(strategy_fingerprint.get("B") or "")
        if (
            not fingerprint_a
            or fingerprint_a != fingerprint_b
            or strategy_fingerprint.get("equal") is not True
        ):
            errors.append("strategy_fingerprint_not_v2_self_play")
        else:
            strategy_identity = fingerprint_a

    rows_value = payload.get("matches")
    rows = (
        [row for row in rows_value if isinstance(row, dict)]
        if isinstance(rows_value, list)
        else []
    )
    if not isinstance(rows_value, list):
        errors.append("matches_not_list")
    elif len(rows) != len(rows_value):
        errors.append("match_not_object")
    if len(rows) != 280:
        errors.append(f"game_count:{len(rows)}")

    identity_counts = Counter(_schedule_match_identity(row) for row in rows)
    actual_identities = set(identity_counts)
    duplicate_count = sum(count - 1 for count in identity_counts.values())
    missing_count = len(_FIXED_280_IDENTITIES - actual_identities)
    unexpected_count = len(actual_identities - _FIXED_280_IDENTITIES)
    if duplicate_count:
        errors.append(f"duplicate_matches:{duplicate_count}")
    if missing_count:
        errors.append(f"missing_matches:{missing_count}")
    if unexpected_count:
        errors.append(f"unexpected_matches:{unexpected_count}")

    structural_faults = sum(
        not _is_clean_fixed_280_match(row) for row in rows
    )
    if structural_faults:
        errors.append(f"structural_faults:{structural_faults}")
    if any(str(row.get("sample_phase") or "main") != "main" for row in rows):
        errors.append("non_main_sample_phase")
    decision_errors: Counter[str] = Counter()
    configured_engines = {
        "A": _V2_ENGINE_ID,
        "B": _V2_ENGINE_ID,
    }
    for row in rows:
        decision_error = match_decision_contract_error(
            row,
            configured_engines,
            strict_v2_depth=True,
        )
        if decision_error:
            decision_errors[decision_error] += 1
    errors.extend(
        f"decision_contract:{code}:{count}"
        for code, count in sorted(decision_errors.items())
    )

    mirror_units: defaultdict[tuple[Any, ...], list[tuple[Any, ...]]] = (
        defaultdict(list)
    )
    cross_units: defaultdict[tuple[Any, ...], list[tuple[Any, ...]]] = (
        defaultdict(list)
    )
    for identity in actual_identities & _FIXED_280_IDENTITIES:
        kind, deck_a, deck_b, block, seed, _seat = identity
        if kind == "mirror":
            mirror_units[(deck_a, block, seed)].append(identity)
        elif kind == "cross":
            cross_units[(
                tuple(sorted((deck_a, deck_b))),
                block,
                seed,
            )].append(identity)
    if (
        len(mirror_units) != 50
        or any(len(unit_rows) != 2 for unit_rows in mirror_units.values())
    ):
        errors.append("mirror_units_not_50_complete_pairs")
    if (
        len(cross_units) != 45
        or any(len(unit_rows) != 4 for unit_rows in cross_units.values())
    ):
        errors.append("cross_units_not_45_complete_closures")

    execution_signature, execution_errors = _fixed_280_execution(payload)
    errors.extend(execution_errors)
    profile_enabled = execution_signature.get("profile")
    config_checkpoint_enabled = config.get("checkpoint_enabled")
    if not isinstance(config_checkpoint_enabled, bool):
        errors.append("config_checkpoint_enabled_not_boolean")
    legacy_provenance = (
        isinstance(provenance, dict)
        and "godot_executable_sha256" not in provenance
        and "performance_host_fingerprint" not in provenance
    )
    legacy_profiled_result = (
        legacy_provenance
        and profile_enabled is True
        and config_checkpoint_enabled is False
    )
    checkpoint_summary = payload.get("checkpoint_summary")
    if not isinstance(checkpoint_summary, dict):
        if legacy_profiled_result:
            checkpoint_summary = {
                "enabled": False,
                "restored_units": 0,
                "written_units": 0,
                "pending_units": 0,
            }
        else:
            checkpoint_summary = {}
            errors.append("checkpoint_summary_not_object")
    checkpoint_enabled = checkpoint_summary.get("enabled")
    if not isinstance(checkpoint_enabled, bool):
        errors.append("checkpoint_enabled_not_boolean")
    elif (
        isinstance(config_checkpoint_enabled, bool)
        and checkpoint_enabled is not config_checkpoint_enabled
    ):
        errors.append("checkpoint_enabled_config_mismatch")
    count_values = {
        key: checkpoint_summary.get(key)
        for key in (
            "restored_units",
            "written_units",
            "pending_units",
        )
    }
    for key, value in count_values.items():
        if not _is_nonnegative_int(value):
            errors.append(f"checkpoint_{key}_invalid")
    restored_units = _int(count_values["restored_units"], -1)
    written_units = _int(count_values["written_units"], -1)
    pending_units = _int(count_values["pending_units"], -1)
    shards_enabled: int | None = None
    shards_total: int | None = None
    if (
        "shards_enabled" in checkpoint_summary
        or "shards_total" in checkpoint_summary
    ):
        raw_shards_enabled = checkpoint_summary.get("shards_enabled")
        raw_shards_total = checkpoint_summary.get("shards_total")
        if (
            not _is_nonnegative_int(raw_shards_enabled)
            or not _is_nonnegative_int(raw_shards_total)
        ):
            errors.append("checkpoint_shards_invalid")
        else:
            shards_enabled = int(raw_shards_enabled)
            shards_total = int(raw_shards_total)
            expected_shards_enabled = 50 if checkpoint_enabled else 0
            if (
                shards_total != 50
                or shards_enabled != expected_shards_enabled
            ):
                errors.append("checkpoint_shards_inconsistent")
    if profile_enabled is False:
        if restored_units != 0:
            errors.append("checkpoint_restored_units_not_zero")
        if pending_units != 0:
            errors.append("checkpoint_pending_units_not_zero")
        expected_written = 95 if checkpoint_enabled is True else 0
        if written_units != expected_written:
            errors.append("checkpoint_written_units_not_complete")
    elif profile_enabled is True:
        if (
            checkpoint_enabled is not False
            or restored_units != 0
            or written_units != 0
            or pending_units != 0
        ):
            errors.append("profiled_checkpoint_not_disabled")
    wall_clock_scope = payload.get("wall_clock_scope")
    if not isinstance(wall_clock_scope, str) or not wall_clock_scope.strip():
        if not legacy_profiled_result:
            errors.append("wall_clock_scope_missing")
        wall_clock_scope = ""
    elif wall_clock_scope != "full_evidence_stage":
        errors.append("wall_clock_scope_not_full_evidence_stage")
    return {
        "valid": not errors,
        "errors": errors,
        "games": len(rows),
        "mirror_games": sum(
            str(row.get("matchup_kind") or "") == "mirror" for row in rows
        ),
        "cross_games": sum(
            str(row.get("matchup_kind") or "") == "cross" for row in rows
        ),
        "mirror_units": len(mirror_units),
        "cross_units": len(cross_units),
        "missing_matches": missing_count,
        "unexpected_matches": unexpected_count,
        "duplicate_matches": duplicate_count,
        "structural_faults": structural_faults,
        "checkpoint_summary": {
            "enabled": checkpoint_enabled,
            "restored_units": restored_units,
            "written_units": written_units,
            "pending_units": pending_units,
            "shards_enabled": shards_enabled,
            "shards_total": shards_total,
        },
        "wall_clock_scope": wall_clock_scope,
        "strategy_fingerprint": strategy_identity,
        "execution_config": execution_signature,
    }


def _planner_costs(payload: dict[str, Any]) -> dict[str, Any]:
    costs: list[float] = []
    sample_count = 0
    missing_planner_ms = 0
    invalid_planner_ms = 0
    invalid_nodes = 0
    for row in payload.get("matches") or []:
        if not isinstance(row, dict):
            continue
        samples_by_strategy = row.get("search_depth_samples_by_strategy") or {}
        if not isinstance(samples_by_strategy, dict):
            continue
        for strategy in ("A", "B"):
            samples = samples_by_strategy.get(strategy) or []
            if not isinstance(samples, list):
                continue
            for sample in samples:
                if (
                    not isinstance(sample, dict)
                    or str(sample.get("engine_id") or "") != _V2_ENGINE_ID
                ):
                    continue
                sample_count += 1
                if "planner_ms" not in sample:
                    missing_planner_ms += 1
                    continue
                planner_ms = _finite_number(sample.get("planner_ms"))
                if planner_ms is None or planner_ms <= 0.0:
                    invalid_planner_ms += 1
                    continue
                nodes = _int(sample.get("nodes_expanded"), -1)
                if nodes <= 0:
                    invalid_nodes += 1
                    continue
                costs.append(planner_ms / nodes)
    complete = (
        sample_count > 0
        and len(costs) == sample_count
        and missing_planner_ms == 0
        and invalid_planner_ms == 0
        and invalid_nodes == 0
    )
    reason = ""
    if sample_count == 0:
        reason = "no_v2_search_samples"
    elif missing_planner_ms:
        reason = "planner_ms_missing"
    elif invalid_planner_ms:
        reason = "planner_ms_invalid"
    elif invalid_nodes:
        reason = "nodes_expanded_not_positive"
    return {
        "available": complete,
        "reason": reason,
        "sample_count": sample_count,
        "usable_sample_count": len(costs),
        "missing_planner_ms": missing_planner_ms,
        "invalid_planner_ms": invalid_planner_ms,
        "invalid_nodes": invalid_nodes,
        "median_ms_per_node": (
            round(statistics.median(costs), 9) if complete else None
        ),
    }


def _wall_clock(payload: dict[str, Any]) -> tuple[float | None, str]:
    for key in ("wall_clock_ms", "wall_elapsed_ms", "elapsed_ms"):
        if key not in payload:
            continue
        value = _finite_number(payload.get(key))
        if value is not None and value > 0.0:
            return value, key
        return None, key
    return None, ""


def _ratio(candidate: float | None, baseline: float | None) -> float | None:
    if candidate is None or baseline is None or baseline <= 0.0:
        return None
    return round(candidate / baseline, 6)


def _reduction(candidate: float | None, baseline: float | None) -> float | None:
    ratio = _ratio(candidate, baseline)
    return round(1.0 - ratio, 6) if ratio is not None else None


def compare_profiles(
    baseline: dict[str, Any], candidate: dict[str, Any]
) -> dict[str, Any]:
    if (
        int(baseline.get("schema_version") or 0) != SCHEMA_VERSION
        or int(candidate.get("schema_version") or 0) != SCHEMA_VERSION
        or baseline.get("protocol_id") != PROTOCOL_ID
        or candidate.get("protocol_id") != PROTOCOL_ID
    ):
        raise ValueError("schema v7 results are required")

    baseline_corpus = _fixed_280_payload_validation(baseline)
    candidate_corpus = _fixed_280_payload_validation(candidate)
    same_execution_config = (
        baseline_corpus["execution_config"]
        == candidate_corpus["execution_config"]
    )
    baseline_execution = baseline_corpus["execution_config"]
    candidate_execution = candidate_corpus["execution_config"]
    baseline_godot_sha256 = baseline_execution.get("godot_executable_sha256")
    candidate_godot_sha256 = candidate_execution.get("godot_executable_sha256")
    same_godot_executable = (
        _valid_sha256(baseline_godot_sha256)
        and _valid_sha256(candidate_godot_sha256)
        and baseline_godot_sha256 == candidate_godot_sha256
    )
    baseline_non_target = baseline_execution.get("non_target_component_hashes")
    candidate_non_target = candidate_execution.get("non_target_component_hashes")
    same_non_target_components = (
        isinstance(baseline_non_target, dict)
        and isinstance(candidate_non_target, dict)
        and set(baseline_non_target) == set(_FIXED_280_NON_TARGET_COMPONENT_HASHES)
        and all(_valid_sha256(value) for value in baseline_non_target.values())
        and baseline_non_target == candidate_non_target
    )
    same_strategy_fingerprint = (
        bool(baseline_corpus["strategy_fingerprint"])
        and baseline_corpus["strategy_fingerprint"]
        == candidate_corpus["strategy_fingerprint"]
    )
    fixed_corpus_errors = [
        *(f"baseline:{error}" for error in baseline_corpus["errors"]),
        *(f"candidate:{error}" for error in candidate_corpus["errors"]),
    ]
    if not same_execution_config:
        fixed_corpus_errors.append("execution_config_mismatch")
    if not same_godot_executable:
        fixed_corpus_errors.append("godot_executable_sha256_mismatch")
    if not same_non_target_components:
        fixed_corpus_errors.append("non_target_component_hashes_mismatch")
    if not same_strategy_fingerprint:
        fixed_corpus_errors.append("strategy_fingerprint_mismatch")

    baseline_match_signature = _match_signature(baseline)
    candidate_match_signature = _match_signature(candidate)
    baseline_traces, baseline_trace_errors = _v2_trace_signature(baseline)
    candidate_traces, candidate_trace_errors = _v2_trace_signature(candidate)
    same_v2_traces = (
        bool(baseline_traces)
        and baseline_traces == candidate_traces
        and not baseline_trace_errors
        and not candidate_trace_errors
    )

    baseline_segments = (baseline.get("performance_profile") or {}).get(
        "segments_ms"
    ) or {}
    candidate_segments = (candidate.get("performance_profile") or {}).get(
        "segments_ms"
    ) or {}
    segment_keys = sorted(set(baseline_segments) | set(candidate_segments))
    segments = {}
    for key in segment_keys:
        before = _float(baseline_segments.get(key))
        after = _float(candidate_segments.get(key))
        segments[key] = {
            "baseline_ms": round(before, 3),
            "candidate_ms": round(after, 3),
            "ratio": _ratio(after, before),
            "delta_ms": round(after - before, 3),
        }

    baseline_planner = _planner_costs(baseline)
    candidate_planner = _planner_costs(candidate)
    baseline_planner_median = baseline_planner["median_ms_per_node"]
    candidate_planner_median = candidate_planner["median_ms_per_node"]
    planner_reduction = _reduction(
        candidate_planner_median, baseline_planner_median
    )
    planner_available = (
        baseline_planner["available"]
        and candidate_planner["available"]
        and planner_reduction is not None
    )
    planner_reason = ""
    if not baseline_planner["available"]:
        planner_reason = f"baseline_{baseline_planner['reason']}"
    elif not candidate_planner["available"]:
        planner_reason = f"candidate_{candidate_planner['reason']}"
    elif planner_reduction is None:
        planner_reason = "baseline_median_not_positive"

    baseline_wall, baseline_wall_source = _wall_clock(baseline)
    candidate_wall, candidate_wall_source = _wall_clock(candidate)
    wall_reduction = _reduction(candidate_wall, baseline_wall)
    wall_available = wall_reduction is not None
    wall_authoritative = (
        baseline_wall_source == "wall_clock_ms"
        and candidate_wall_source == "wall_clock_ms"
    )
    wall_reason = ""
    if baseline_wall is None:
        wall_reason = "baseline_wall_clock_missing_or_invalid"
    elif candidate_wall is None:
        wall_reason = "candidate_wall_clock_missing_or_invalid"
    wall_authoritative_reason = (
        ""
        if wall_authoritative
        else "authoritative_wall_clock_ms_required"
    )

    same_matches = baseline_match_signature == candidate_match_signature
    elapsed = {
        "available": wall_available,
        "baseline": round(baseline_wall, 3) if baseline_wall is not None else None,
        "candidate": (
            round(candidate_wall, 3) if candidate_wall is not None else None
        ),
        "ratio": _ratio(candidate_wall, baseline_wall),
        "reduction": wall_reduction,
        "delta_ms": (
            round(candidate_wall - baseline_wall, 3)
            if baseline_wall is not None and candidate_wall is not None
            else None
        ),
        "baseline_source": baseline_wall_source,
        "candidate_source": candidate_wall_source,
        "reason": wall_reason,
        "authoritative": wall_authoritative,
        "authoritative_reason": wall_authoritative_reason,
    }
    return {
        "corpus_id": FIXED_280_CORPUS_ID,
        "fixed_280_corpus": {
            "valid": (
                baseline_corpus["valid"]
                and candidate_corpus["valid"]
                and same_execution_config
                and same_godot_executable
                and same_non_target_components
                and same_strategy_fingerprint
            ),
            "task_manifest_id": FIXED_280_TASK_MANIFEST_ID,
            "expected_games": 280,
            "expected_mirror_games": 100,
            "expected_cross_games": 180,
            "expected_mirror_units": 50,
            "expected_cross_units": 45,
            "same_execution_config": same_execution_config,
            "same_godot_executable": same_godot_executable,
            "same_non_target_components": same_non_target_components,
            "same_strategy_fingerprint": same_strategy_fingerprint,
            "baseline": baseline_corpus,
            "candidate": candidate_corpus,
            "errors": fixed_corpus_errors,
        },
        "same_match_results": same_matches,
        "same_v2_search_traces": same_v2_traces,
        "equivalent": same_matches and same_v2_traces,
        "baseline_games": len(baseline_match_signature),
        "candidate_games": len(candidate_match_signature),
        "v2_search_samples": {
            "baseline_count": len(baseline_traces),
            "candidate_count": len(candidate_traces),
            "baseline_validation_errors": baseline_trace_errors,
            "candidate_validation_errors": candidate_trace_errors,
        },
        "planner_ms_per_node": {
            "available": planner_available,
            "reason": planner_reason,
            "baseline_median": baseline_planner_median,
            "candidate_median": candidate_planner_median,
            "ratio": _ratio(
                candidate_planner_median, baseline_planner_median
            ),
            "reduction": planner_reduction,
            "baseline": baseline_planner,
            "candidate": candidate_planner,
        },
        "wall_clock_ms": elapsed,
        # Retained for consumers of the previous profile-comparison schema.
        "elapsed_ms": elapsed,
        "segments": segments,
    }


def evaluate_gates(
    comparison: dict[str, Any],
    *,
    require_planner_reduction: float | None = None,
    require_wall_reduction: float | None = None,
    require_fixed_280: bool = False,
) -> dict[str, Any]:
    errors: list[dict[str, Any]] = []
    if require_fixed_280:
        corpus = comparison.get("fixed_280_corpus") or {}
        if not corpus.get("valid"):
            errors.append({
                "code": "fixed_280_corpus_invalid",
                "message": (
                    "inputs are not the canonical deterministic 280-game "
                    "v2-v2 performance corpus"
                ),
                "details": list(corpus.get("errors") or []),
            })
    if not comparison.get("same_match_results"):
        errors.append({
            "code": "match_results_changed",
            "message": "normalized match results differ",
        })
    if not comparison.get("same_v2_search_traces"):
        errors.append({
            "code": "v2_search_traces_changed",
            "message": "v2 search samples differ or are not verifiable",
        })
    for name, required, metric_key in (
        (
            "planner",
            require_planner_reduction,
            "planner_ms_per_node",
        ),
        ("wall", require_wall_reduction, "wall_clock_ms"),
    ):
        if required is None:
            continue
        metric = comparison[metric_key]
        actual = metric.get("reduction")
        authoritative_wall_required = (
            name == "wall"
            and require_fixed_280
            and not metric.get("authoritative")
        )
        unavailable_reason = (
            metric.get("authoritative_reason")
            if authoritative_wall_required
            else metric.get("reason")
        )
        if (
            authoritative_wall_required
            or not metric.get("available")
            or actual is None
        ):
            errors.append({
                "code": f"{name}_metric_unavailable",
                "message": (
                    f"{name} reduction cannot be gated: "
                    f"{unavailable_reason or 'metric unavailable'}"
                ),
                "required_reduction": required,
            })
        elif float(actual) + 1e-12 < required:
            errors.append({
                "code": f"{name}_reduction_below_requirement",
                "message": (
                    f"{name} reduction {float(actual):.6f} is below "
                    f"required {required:.6f}"
                ),
                "required_reduction": required,
                "actual_reduction": actual,
            })
    return {
        "passed": not errors,
        "require_fixed_280": require_fixed_280,
        "require_planner_reduction": require_planner_reduction,
        "require_wall_reduction": require_wall_reduction,
        "errors": errors,
    }


def _format_float(value: Any, digits: int = 6) -> str:
    number = _finite_number(value)
    return "unavailable" if number is None else f"{number:.{digits}f}"


def render_text(comparison: dict[str, Any]) -> str:
    wall = comparison["wall_clock_ms"]
    planner = comparison["planner_ms_per_node"]
    traces = comparison["v2_search_samples"]
    corpus = comparison["fixed_280_corpus"]
    lines = [
        (
            f"corpus_id={comparison['corpus_id']} "
            f"valid={str(corpus['valid']).lower()}"
        ),
        f"same_match_results={str(comparison['same_match_results']).lower()}",
        (
            "same_v2_search_traces="
            f"{str(comparison['same_v2_search_traces']).lower()} "
            f"baseline_samples={traces['baseline_count']} "
            f"candidate_samples={traces['candidate_count']}"
        ),
        (
            "planner_ms_per_node_median: "
            f"baseline={_format_float(planner['baseline_median'], 9)} "
            f"candidate={_format_float(planner['candidate_median'], 9)} "
            f"reduction={_format_float(planner['reduction'])} "
            f"reason={planner['reason'] or 'ok'}"
        ),
        (
            "wall_clock_ms: "
            f"baseline={_format_float(wall['baseline'], 3)} "
            f"candidate={_format_float(wall['candidate'], 3)} "
            f"reduction={_format_float(wall['reduction'])} "
            f"reason={wall['reason'] or 'ok'}"
        ),
        "segments:",
    ]
    ordered = sorted(
        comparison["segments"].items(),
        key=lambda item: abs(_float(item[1].get("delta_ms"))),
        reverse=True,
    )
    for key, row in ordered[:12]:
        lines.append(
            f"- {key}: baseline={row['baseline_ms']:.3f} "
            f"candidate={row['candidate_ms']:.3f} ratio={row['ratio']}"
        )
    gate = comparison.get("gate")
    if isinstance(gate, dict):
        lines.append(f"gate_passed={str(gate['passed']).lower()}")
        for error in gate["errors"]:
            lines.append(f"- {error['code']}: {error['message']}")
    return "\n".join(lines)


def _reduction_requirement(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number from 0 to 1") from exc
    if not math.isfinite(parsed) or parsed < 0.0 or parsed > 1.0:
        raise argparse.ArgumentTypeError("must be a number from 0 to 1")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--require-planner-reduction",
        type=_reduction_requirement,
        help="minimum median planner_ms/nodes reduction (for example 0.25)",
    )
    parser.add_argument(
        "--require-wall-reduction",
        type=_reduction_requirement,
        help="minimum wall-clock reduction (for example 0.20)",
    )
    parser.add_argument(
        "--require-fixed-280",
        action="store_true",
        help=(
            "require the canonical 280-game v2-v2 corpus, fixed 12-worker "
            "execution profile, and authoritative wall_clock_ms"
        ),
    )
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    candidate = json.loads(args.candidate.read_text(encoding="utf-8"))
    comparison = compare_profiles(baseline, candidate)
    comparison["gate"] = evaluate_gates(
        comparison,
        require_planner_reduction=args.require_planner_reduction,
        require_wall_reduction=args.require_wall_reduction,
        require_fixed_280=args.require_fixed_280,
    )
    if args.json:
        print(json.dumps(comparison, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_text(comparison))
    return 0 if comparison["gate"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

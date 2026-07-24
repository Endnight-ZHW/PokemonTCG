"""Build or verify the one-time v7 decision-semantics migration evidence.

This tool is intentionally separate from the production v7 validator and
profile comparator.  It recognizes exactly one reviewed migration contract:
two pinned pre-semantic fixed-280 artifacts, two strict fixed-20 semantic
artifacts, and one strict final fixed-280 candidate.  The final candidate's
fixed-20 role is derived from its canonical fixed-280 subset.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

try:
    from scripts.ai_evaluation_v7 import (
        DECK_ORDER,
        PROTOCOL_ID,
        SCHEMA_VERSION,
        expected_match_identities,
        match_decision_contract_error,
        performance_host_fingerprint,
    )
    from scripts.compare_ai_evaluation_profiles import (
        FIXED_280_SCHEDULE,
        _fixed_280_payload_validation,
        _is_clean_fixed_280_match,
        _match_identity,
        _match_signature,
        _planner_costs,
        _reduction,
        _schedule_match_identity,
        _wall_clock,
    )
except ModuleNotFoundError:  # Direct script execution.
    from ai_evaluation_v7 import (  # type: ignore[no-redef]
        DECK_ORDER,
        PROTOCOL_ID,
        SCHEMA_VERSION,
        expected_match_identities,
        match_decision_contract_error,
        performance_host_fingerprint,
    )
    from compare_ai_evaluation_profiles import (  # type: ignore[no-redef]
        FIXED_280_SCHEDULE,
        _fixed_280_payload_validation,
        _is_clean_fixed_280_match,
        _match_identity,
        _match_signature,
        _planner_costs,
        _reduction,
        _schedule_match_identity,
        _wall_clock,
    )


ARTIFACT_KIND = "traditional_ai_decision_semantics_migration_evidence"
EVIDENCE_SCHEMA_VERSION = 1
V2_ENGINE_ID = "turn_beam_v2"
ROLE_ORDER = (
    "legacy_baseline_280",
    "legacy_candidate_280",
    "original_baseline_20",
    "current_final_20",
    "final_candidate_280",
)
LEGACY_ROLES = frozenset({
    "legacy_baseline_280",
    "legacy_candidate_280",
})
STRICT_20_ROLES = (
    "original_baseline_20",
    "current_final_20",
)
TRACE_INTEGER_FIELDS = (
    "requested",
    "reached",
    "completed",
    "max_path_depth",
    "reply_requested",
    "reply_completed",
    "layers_completed",
    "nodes_expanded",
)
TRACE_STRING_FIELDS_V0 = (
    "completion_reason",
    "stop_reason",
    "reply_completion_reason",
    "trajectory_hash",
)
TRACE_STRING_FIELDS_V1 = (
    *TRACE_STRING_FIELDS_V0,
    "decision_semantic_hash",
)
PERFORMANCE_CONFIG_FIELDS = (
    "platform",
    "workers",
    "parallel_workers",
    "global_parallel_workers",
    "external_shard_count",
    "profile",
    "disable_ai_cache",
    "disable_native_math",
    "evidence_shard_count",
    "execution_profile_id",
    "max_actions",
    "rules_options",
    "deck_keys",
    "seed",
    "seed_blocks_per_deck",
    "cross_seed_blocks_per_matchup",
    "matchup_mode",
)


class MigrationEvidenceError(RuntimeError):
    """Fail-closed migration error with a stable machine-readable code."""

    def __init__(self, code: str, details: Any = None):
        self.code = code
        self.details = details
        message = code
        if details is not None:
            message += f": {details}"
        super().__init__(message)


@dataclass(frozen=True)
class LoadedArtifact:
    role: str
    path: Path
    sha256: str
    payload: dict[str, Any]


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _domain_digest(domain: str, value: Any) -> str:
    encoded = f"{domain}\n{_canonical_json(value)}".encode("utf-8")
    return _sha256_bytes(encoded)


def _valid_sha256(value: Any) -> bool:
    normalized = str(value or "")
    return len(normalized) == 64 and all(
        character in "0123456789abcdef" for character in normalized
    )


def _int(value: Any, default: int = -1) -> int:
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


def _finite_float(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return result if math.isfinite(result) else None


def _require(condition: bool, code: str, details: Any = None) -> None:
    if not condition:
        raise MigrationEvidenceError(code, details)


def _json_object(path: Path) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-finite JSON number: {value}")

    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            path.read_text(encoding="utf-8-sig"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise MigrationEvidenceError("invalid_json", str(path)) from error
    if not isinstance(value, dict):
        raise MigrationEvidenceError("json_not_object", str(path))
    return value


def _load_artifacts(
    spec: dict[str, Any],
    input_paths: dict[str, Path],
) -> dict[str, LoadedArtifact]:
    _require(
        set(input_paths) == set(ROLE_ORDER),
        "input_roles",
        sorted(input_paths),
    )
    input_spec = spec.get("inputs")
    _require(isinstance(input_spec, dict), "spec_inputs")
    _require(set(input_spec) == set(ROLE_ORDER), "spec_input_roles")
    result: dict[str, LoadedArtifact] = {}
    for role in ROLE_ORDER:
        path = input_paths[role].resolve()
        _require(path.is_file(), "input_missing", {"role": role, "path": str(path)})
        sha256 = _sha256_file(path)
        role_spec = input_spec.get(role)
        _require(isinstance(role_spec, dict), "spec_input_role", role)
        expected_sha256 = str(role_spec.get("artifact_sha256") or "")
        generated = role_spec.get("generated") is True
        _require(
            bool(expected_sha256) != generated,
            "spec_input_binding",
            role,
        )
        if expected_sha256:
            _require(
                _valid_sha256(expected_sha256) and sha256 == expected_sha256,
                "artifact_sha256",
                {"role": role, "expected": expected_sha256, "actual": sha256},
            )
        payload = _json_object(path)
        result[role] = LoadedArtifact(role, path, sha256, payload)
    return result


def _rows(payload: dict[str, Any], role: str) -> list[dict[str, Any]]:
    value = payload.get("matches")
    _require(isinstance(value, list), "matches_not_list", role)
    _require(
        all(isinstance(row, dict) for row in value),
        "match_not_object",
        role,
    )
    return list(value)


def _trace_signature(
    payload: dict[str, Any],
    *,
    role: str,
    include_semantic_hash: bool,
) -> list[tuple[Any, ...]]:
    fields = (
        TRACE_STRING_FIELDS_V1
        if include_semantic_hash
        else TRACE_STRING_FIELDS_V0
    )
    traces: list[tuple[Any, ...]] = []
    for row_index, row in enumerate(_rows(payload, role)):
        identity = _match_identity(row)
        samples_by_strategy = row.get("search_depth_samples_by_strategy")
        _require(
            isinstance(samples_by_strategy, dict),
            "search_samples_not_object",
            {"role": role, "match": row_index},
        )
        for strategy in ("A", "B"):
            samples = samples_by_strategy.get(strategy)
            _require(
                isinstance(samples, list),
                "search_samples_not_list",
                {"role": role, "match": row_index, "strategy": strategy},
            )
            for sample_index, sample in enumerate(samples):
                location = {
                    "role": role,
                    "match": row_index,
                    "strategy": strategy,
                    "sample": sample_index,
                }
                _require(isinstance(sample, dict), "search_sample_not_object", location)
                _require(
                    str(sample.get("engine_id") or "") == V2_ENGINE_ID,
                    "search_sample_engine",
                    location,
                )
                required = (
                    *TRACE_INTEGER_FIELDS,
                    *fields,
                    "reply_applicable",
                )
                missing = [key for key in required if key not in sample]
                _require(not missing, "search_sample_missing", {**location, "fields": missing})
                integer_values = tuple(
                    sample.get(key) for key in TRACE_INTEGER_FIELDS)
                _require(
                    all(_is_nonnegative_int(value) for value in integer_values),
                    "search_sample_integer",
                    location,
                )
                integers = tuple(int(value) for value in integer_values)
                _require(
                    isinstance(sample.get("reply_applicable"), bool),
                    "search_sample_reply_applicable",
                    location,
                )
                strings = tuple(str(sample.get(key) or "") for key in fields)
                _require(all(strings), "search_sample_string", location)
                _require(
                    _valid_sha256(sample.get("trajectory_hash")),
                    "trajectory_hash",
                    location,
                )
                if include_semantic_hash:
                    _require(
                        _valid_sha256(sample.get("decision_semantic_hash")),
                        "decision_semantic_hash",
                        location,
                    )
                traces.append((
                    *identity,
                    strategy,
                    sample_index,
                    V2_ENGINE_ID,
                    *integers,
                    bool(sample.get("reply_applicable")),
                    *strings,
                ))
    traces.sort()
    return traces


def _semantic_fields_absent(payload: dict[str, Any], role: str) -> int:
    sample_count = 0
    for row in _rows(payload, role):
        samples_by_strategy = row.get("search_depth_samples_by_strategy")
        _require(isinstance(samples_by_strategy, dict), "search_samples_not_object", role)
        for strategy in ("A", "B"):
            samples = samples_by_strategy.get(strategy)
            _require(isinstance(samples, list), "search_samples_not_list", role)
            for sample in samples:
                _require(isinstance(sample, dict), "search_sample_not_object", role)
                _require(
                    "decision_semantic_hash" not in sample,
                    "legacy_semantic_hash_present",
                    role,
                )
                sample_count += 1
    return sample_count


def _task_manifest_values(payload: dict[str, Any]) -> list[str]:
    values = [str(payload.get("task_manifest_id") or "")]
    for container_name in ("config", "execution_config"):
        container = payload.get(container_name)
        if isinstance(container, dict):
            values.append(str(container.get("task_manifest_id") or ""))
    provenance = payload.get("provenance")
    if isinstance(provenance, dict):
        simulation_config = provenance.get("simulation_config")
        if isinstance(simulation_config, dict):
            values.append(str(simulation_config.get("task_manifest_id") or ""))
    return values


def _common_artifact_contract(
    artifact: LoadedArtifact,
    *,
    protocol_id: str,
    require_fingerprints: bool,
) -> None:
    payload = artifact.payload
    _require(_int(payload.get("schema_version")) == SCHEMA_VERSION, "schema_version", artifact.role)
    _require(str(payload.get("protocol_id") or "") == protocol_id, "protocol_id", artifact.role)
    _require(
        str(payload.get("artifact_kind") or "") == "ai_evaluation_result",
        "artifact_kind",
        artifact.role,
    )
    _require(
        str(payload.get("gate_depth_source") or "") == "main_matches",
        "gate_depth_source",
        artifact.role,
    )
    provenance = payload.get("provenance")
    _require(isinstance(provenance, dict), "provenance", artifact.role)
    if require_fingerprints:
        for key in ("simulation_fingerprint", "analysis_fingerprint"):
            top = str(payload.get(key) or "")
            nested = str(provenance.get(key) or "")
            _require(
                _valid_sha256(top) and top == nested,
                key,
                artifact.role,
            )


def _strict_v2_contract(artifact: LoadedArtifact, protocol_id: str) -> list[tuple[Any, ...]]:
    _common_artifact_contract(
        artifact,
        protocol_id=protocol_id,
        require_fingerprints=True,
    )
    configured_engines = {"A": V2_ENGINE_ID, "B": V2_ENGINE_ID}
    for index, row in enumerate(_rows(artifact.payload, artifact.role)):
        error = match_decision_contract_error(
            row,
            configured_engines,
            strict_v2_depth=True,
        )
        _require(
            error is None,
            "strict_v2_decision_contract",
            {"role": artifact.role, "match": index, "error": error},
        )
        _require(
            _is_clean_fixed_280_match(row),
            "dirty_match",
            {"role": artifact.role, "match": index},
        )
    return _trace_signature(
        artifact.payload,
        role=artifact.role,
        include_semantic_hash=True,
    )


def _schedule_identity_counts(payload: dict[str, Any], role: str) -> Counter[tuple[Any, ...]]:
    return Counter(_schedule_match_identity(row) for row in _rows(payload, role))


def _validate_legacy_fixed_280(
    artifact: LoadedArtifact,
    spec: dict[str, Any],
) -> list[tuple[Any, ...]]:
    protocol_id = str(spec.get("protocol_id") or "")
    _common_artifact_contract(
        artifact,
        protocol_id=protocol_id,
        require_fingerprints=True,
    )
    fixed = spec.get("fixed_280")
    _require(isinstance(fixed, dict), "spec_fixed_280")
    rows = _rows(artifact.payload, artifact.role)
    _require(len(rows) == _int(fixed.get("games")), "fixed_280_games", artifact.role)
    expected = Counter(expected_match_identities(DECK_ORDER, FIXED_280_SCHEDULE))
    actual = _schedule_identity_counts(artifact.payload, artifact.role)
    _require(actual == expected, "fixed_280_schedule", artifact.role)
    _require(
        all(_is_clean_fixed_280_match(row) for row in rows),
        "fixed_280_dirty",
        artifact.role,
    )
    task_manifest_id = str(fixed.get("task_manifest_id") or "")
    _require(
        all(value == task_manifest_id for value in _task_manifest_values(artifact.payload)),
        "fixed_280_task_manifest",
        artifact.role,
    )
    search_sample_count = _semantic_fields_absent(artifact.payload, artifact.role)
    _require(
        search_sample_count == _int(fixed.get("v2_search_samples")),
        "fixed_280_decisions",
        {"role": artifact.role, "actual": search_sample_count},
    )
    return _trace_signature(
        artifact.payload,
        role=artifact.role,
        include_semantic_hash=False,
    )


def _selected_fixed_20_identities(
    legacy_baseline: LoadedArtifact,
    spec: dict[str, Any],
) -> set[tuple[Any, ...]]:
    fixed = spec.get("fixed_20")
    _require(isinstance(fixed, dict), "spec_fixed_20")
    selector = fixed.get("selector")
    _require(isinstance(selector, dict), "spec_fixed_20_selector")
    kind = str(selector.get("matchup_kind") or "")
    seed_block = _int(selector.get("seed_block"))
    selected = {
        _schedule_match_identity(row)
        for row in _rows(legacy_baseline.payload, legacy_baseline.role)
        if (
            str(row.get("matchup_kind") or "") == kind
            and _int(row.get("seed_block")) == seed_block
        )
    }
    _require(
        len(selected) == _int(fixed.get("games")),
        "fixed_20_legacy_subset",
        len(selected),
    )
    return selected


def _subset_payload(
    payload: dict[str, Any],
    role: str,
    identities: set[tuple[Any, ...]],
) -> dict[str, Any]:
    selected = [
        row
        for row in _rows(payload, role)
        if _schedule_match_identity(row) in identities
    ]
    _require(
        len(selected) == len(identities),
        "subset_coverage",
        {"role": role, "rows": len(selected), "expected": len(identities)},
    )
    result = dict(payload)
    result["matches"] = selected
    return result


def _validate_fixed_20(
    artifact: LoadedArtifact,
    spec: dict[str, Any],
    expected_identities: set[tuple[Any, ...]],
) -> list[tuple[Any, ...]]:
    traces = _strict_v2_contract(artifact, str(spec.get("protocol_id") or ""))
    fixed = spec.get("fixed_20")
    _require(isinstance(fixed, dict), "spec_fixed_20")
    rows = _rows(artifact.payload, artifact.role)
    _require(len(rows) == _int(fixed.get("games")), "fixed_20_games", artifact.role)
    identities = _schedule_identity_counts(artifact.payload, artifact.role)
    _require(
        set(identities) == expected_identities and all(count == 1 for count in identities.values()),
        "fixed_20_schedule",
        artifact.role,
    )
    _require(
        all(
            value == str(fixed.get("task_manifest_id") or "")
            for value in _task_manifest_values(artifact.payload)
        ),
        "fixed_20_task_manifest",
        artifact.role,
    )
    _require(
        len(traces) == _int(fixed.get("v2_search_samples")),
        "fixed_20_decisions",
        {"role": artifact.role, "actual": len(traces)},
    )
    deck_units = Counter(
        str(row.get("strategy_a_deck") or row.get("deck") or "")
        for row in rows
    )
    _require(
        set(deck_units) == set(DECK_ORDER)
        and all(count == 2 for count in deck_units.values()),
        "fixed_20_deck_coverage",
        dict(deck_units),
    )
    return traces


def _provenance(payload: dict[str, Any], role: str) -> dict[str, Any]:
    value = payload.get("provenance")
    _require(isinstance(value, dict), "provenance", role)
    return value


def _source_hash_binding(
    artifact: LoadedArtifact,
    role_spec: dict[str, Any],
) -> None:
    expected = str(role_spec.get("simulation_source_hash") or "")
    if not expected:
        return
    actual = str(_provenance(artifact.payload, artifact.role).get(
        "simulation_source_hash") or "")
    _require(
        _valid_sha256(expected) and actual == expected,
        "simulation_source_hash",
        {"role": artifact.role, "expected": expected, "actual": actual},
    )


def _function_text(path: Path, function_name: str) -> str:
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    marker = f"func {function_name}("
    start = text.find(marker)
    _require(start >= 0, "semantic_hash_function_missing", str(path))
    end = text.find("\nfunc ", start + len(marker))
    if end < 0:
        end = len(text)
    return text[start:end].rstrip() + "\n"


def _validate_baseline_source_attestation(
    spec: dict[str, Any],
    artifacts: dict[str, LoadedArtifact],
    baseline_source_root: Path,
) -> dict[str, Any]:
    attestation = spec.get("baseline_source_attestation")
    _require(isinstance(attestation, dict), "spec_baseline_source_attestation")
    legacy = _provenance(
        artifacts["legacy_baseline_280"].payload,
        "legacy_baseline_280",
    )
    telemetry = _provenance(
        artifacts["original_baseline_20"].payload,
        "original_baseline_20",
    )
    for key, provenance_key in (
        ("legacy_source_hash", "source_hash"),
        ("legacy_simulation_source_hash", "simulation_source_hash"),
    ):
        _require(
            str(legacy.get(provenance_key) or "") == str(attestation.get(key) or ""),
            "legacy_source_attestation",
            key,
        )
    for key, provenance_key in (
        ("telemetry_source_hash", "source_hash"),
        ("telemetry_simulation_source_hash", "simulation_source_hash"),
    ):
        _require(
            str(telemetry.get(provenance_key) or "") == str(attestation.get(key) or ""),
            "telemetry_source_attestation",
            key,
        )
    legacy_components = legacy.get("component_hashes")
    telemetry_components = telemetry.get("component_hashes")
    _require(isinstance(legacy_components, dict), "legacy_component_hashes")
    _require(isinstance(telemetry_components, dict), "telemetry_component_hashes")
    unchanged_components = attestation.get("unchanged_component_hashes")
    changed_components = attestation.get("telemetry_component_hashes")
    _require(isinstance(unchanged_components, dict), "spec_unchanged_components")
    _require(isinstance(changed_components, dict), "spec_telemetry_components")
    for component, expected in unchanged_components.items():
        _require(
            str(legacy_components.get(component) or "") == str(expected)
            and str(telemetry_components.get(component) or "") == str(expected),
            "unchanged_component_hash",
            component,
        )
    for component, expected in changed_components.items():
        _require(
            str(telemetry_components.get(component) or "") == str(expected),
            "telemetry_component_hash",
            component,
        )

    source_root = baseline_source_root.resolve()
    _require(source_root.is_dir(), "baseline_source_root", str(source_root))
    allowed = attestation.get("allowed_changed_files")
    guards = attestation.get("guard_files")
    _require(isinstance(allowed, dict) and len(allowed) == 2, "allowed_changed_files")
    _require(isinstance(guards, dict), "guard_files")
    for relative, values in allowed.items():
        _require(isinstance(values, dict), "allowed_changed_file", relative)
        path = source_root / relative
        _require(path.is_file(), "attested_source_file_missing", relative)
        actual = _sha256_file(path)
        _require(
            actual == str(values.get("after_sha256") or ""),
            "attested_source_file_hash",
            {"path": relative, "actual": actual},
        )
        _require(
            _valid_sha256(values.get("before_sha256")),
            "attested_before_hash",
            relative,
        )
    for relative, expected in guards.items():
        path = source_root / relative
        _require(path.is_file(), "guard_file_missing", relative)
        _require(_sha256_file(path) == str(expected), "guard_file_hash", relative)

    source_files = legacy.get("source_files")
    _require(isinstance(source_files, list), "legacy_source_files")
    unchanged_rows: list[dict[str, str]] = []
    for relative_value in source_files:
        relative = str(relative_value)
        if relative in allowed:
            continue
        path = source_root / relative
        _require(path.is_file(), "unchanged_source_file_missing", relative)
        unchanged_rows.append({
            "path": relative,
            "sha256": _sha256_file(path),
        })
    unchanged_digest = _sha256_bytes(
        _canonical_json(unchanged_rows).encode("utf-8")
    )
    _require(
        unchanged_digest
        == str(attestation.get("unchanged_source_manifest_sha256") or ""),
        "unchanged_source_manifest",
        unchanged_digest,
    )
    challenge_path = source_root / "godot/ai/challenge_ai.gd"
    function_hash = _sha256_bytes(_function_text(
        challenge_path,
        "_traditional_decision_semantic_hash",
    ).encode("utf-8"))
    _require(
        function_hash == str(attestation.get("semantic_hash_function_sha256") or ""),
        "semantic_hash_function",
        function_hash,
    )
    transition_digest = _domain_digest(
        "traditional_ai_telemetry_transition_v1",
        {
            "allowed_changed_files": allowed,
            "semantic_hash_function_sha256": function_hash,
            "unchanged_source_manifest_sha256": unchanged_digest,
        },
    )
    _require(
        transition_digest
        == str(attestation.get("telemetry_transition_sha256") or ""),
        "telemetry_transition",
        transition_digest,
    )
    return {
        "legacy_source_hash": str(legacy.get("source_hash") or ""),
        "legacy_simulation_source_hash": str(
            legacy.get("simulation_source_hash") or ""),
        "telemetry_source_hash": str(telemetry.get("source_hash") or ""),
        "telemetry_simulation_source_hash": str(
            telemetry.get("simulation_source_hash") or ""),
        "unchanged_source_manifest_sha256": unchanged_digest,
        "semantic_hash_function_sha256": function_hash,
        "telemetry_transition_sha256": transition_digest,
        "allowed_changed_files": {
            relative: copy.deepcopy(values)
            for relative, values in sorted(allowed.items())
        },
        "guard_files": {
            relative: str(value)
            for relative, value in sorted(guards.items())
        },
    }


def _normalized_performance_value(value: Any) -> Any:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        number = _finite_float(value)
        if number is not None and number.is_integer():
            return int(number)
        return number
    return value


def _performance_config(payload: dict[str, Any], role: str) -> dict[str, Any]:
    execution = payload.get("execution_config")
    _require(isinstance(execution, dict), "execution_config", role)
    return {
        key: _normalized_performance_value(execution.get(key))
        for key in PERFORMANCE_CONFIG_FIELDS
    }


def _derived_performance_host(payload: dict[str, Any], role: str) -> str:
    provenance = _provenance(payload, role)
    host = provenance.get("host")
    _require(isinstance(host, dict), "performance_host", role)
    result = performance_host_fingerprint(
        host,
        godot_runtime_version=str(provenance.get("godot_runtime_version") or ""),
        target_platform=str(provenance.get("target_platform") or ""),
    )
    _require(_valid_sha256(result), "performance_host_fingerprint", role)
    return result


def _validate_performance(
    spec: dict[str, Any],
    legacy_baseline: LoadedArtifact,
    legacy_candidate: LoadedArtifact,
    final_candidate: LoadedArtifact,
) -> dict[str, Any]:
    performance_spec = spec.get("performance")
    _require(isinstance(performance_spec, dict), "spec_performance")
    baseline_config = _performance_config(
        legacy_baseline.payload,
        legacy_baseline.role,
    )
    candidate_config = _performance_config(
        final_candidate.payload,
        final_candidate.role,
    )
    _require(
        baseline_config == candidate_config,
        "performance_execution_config",
        {"baseline": baseline_config, "candidate": candidate_config},
    )
    for key in (
        "workers",
        "profile",
        "disable_ai_cache",
        "disable_native_math",
        "execution_profile_id",
    ):
        expected = _normalized_performance_value(performance_spec.get(key))
        _require(
            candidate_config.get(key) == expected,
            "performance_required_config",
            {"field": key, "expected": expected, "actual": candidate_config.get(key)},
        )
    baseline_host = _derived_performance_host(
        legacy_baseline.payload,
        legacy_baseline.role,
    )
    candidate_host = _derived_performance_host(
        final_candidate.payload,
        final_candidate.role,
    )
    _require(baseline_host == candidate_host, "performance_host_mismatch")
    legacy_candidate_provenance = _provenance(
        legacy_candidate.payload,
        legacy_candidate.role,
    )
    final_provenance = _provenance(
        final_candidate.payload,
        final_candidate.role,
    )
    legacy_godot = str(
        legacy_candidate_provenance.get("godot_executable_sha256") or "")
    final_godot = str(final_provenance.get("godot_executable_sha256") or "")
    _require(
        _valid_sha256(legacy_godot) and legacy_godot == final_godot,
        "performance_godot_executable",
    )
    baseline_wall, baseline_wall_field = _wall_clock(legacy_baseline.payload)
    candidate_wall, candidate_wall_field = _wall_clock(final_candidate.payload)
    _require(
        baseline_wall is not None and candidate_wall is not None,
        "performance_wall_clock",
    )
    _require(
        baseline_wall_field == "wall_clock_ms"
        and candidate_wall_field == "wall_clock_ms",
        "performance_wall_clock_authoritative",
        {
            "baseline_field": baseline_wall_field,
            "candidate_field": candidate_wall_field,
        },
    )
    candidate_wall_scope = final_candidate.payload.get("wall_clock_scope")
    _require(
        candidate_wall_scope == "full_evidence_stage",
        "performance_candidate_wall_clock_scope",
        candidate_wall_scope,
    )
    wall_reduction = _reduction(candidate_wall, baseline_wall)
    planner_baseline = _planner_costs(legacy_baseline.payload)
    planner_candidate = _planner_costs(final_candidate.payload)
    _require(
        bool(planner_baseline.get("available"))
        and bool(planner_candidate.get("available")),
        "performance_planner_samples",
        {
            "baseline": planner_baseline.get("reason"),
            "candidate": planner_candidate.get("reason"),
        },
    )
    baseline_median = _finite_float(planner_baseline.get("median_ms_per_node"))
    candidate_median = _finite_float(planner_candidate.get("median_ms_per_node"))
    _require(
        baseline_median is not None
        and candidate_median is not None
        and baseline_median > 0.0
        and candidate_median > 0.0,
        "performance_planner_median",
    )
    planner_reduction = _reduction(candidate_median, baseline_median)
    required_wall = _finite_float(performance_spec.get("wall_clock_reduction_min"))
    required_planner = _finite_float(
        performance_spec.get("planner_ms_per_node_reduction_min"))
    _require(
        required_wall is not None
        and wall_reduction is not None
        and wall_reduction + 1e-12 >= required_wall,
        "performance_wall_gate",
        {"actual": wall_reduction, "required": required_wall},
    )
    _require(
        required_planner is not None
        and planner_reduction is not None
        and planner_reduction + 1e-12 >= required_planner,
        "performance_planner_gate",
        {"actual": planner_reduction, "required": required_planner},
    )
    checkpoint = final_candidate.payload.get("checkpoint_summary")
    _require(isinstance(checkpoint, dict), "candidate_checkpoint_summary")
    _require(
        checkpoint.get("enabled") is False
        and _int(checkpoint.get("restored_units"), 0) == 0
        and _int(checkpoint.get("written_units"), 0) == 0
        and _int(checkpoint.get("pending_units"), 0) == 0,
        "candidate_profile_checkpoint",
        checkpoint,
    )
    return {
        "baseline_wall_clock_ms": baseline_wall,
        "baseline_wall_clock_field": baseline_wall_field,
        "candidate_wall_clock_ms": candidate_wall,
        "candidate_wall_clock_field": candidate_wall_field,
        "wall_clock_reduction": wall_reduction,
        "wall_clock_reduction_min": required_wall,
        "baseline_planner_ms_per_node_median": baseline_median,
        "candidate_planner_ms_per_node_median": candidate_median,
        "planner_ms_per_node_reduction": planner_reduction,
        "planner_ms_per_node_reduction_min": required_planner,
        "baseline_planner_samples": int(planner_baseline.get("sample_count") or 0),
        "candidate_planner_samples": int(planner_candidate.get("sample_count") or 0),
        "execution_config": candidate_config,
        "performance_host_fingerprint": candidate_host,
        "godot_executable_sha256": final_godot,
        "checkpoint_summary": copy.deepcopy(checkpoint),
    }


def _artifact_record(
    artifact: LoadedArtifact,
    *,
    search_sample_count: int,
) -> dict[str, Any]:
    payload = artifact.payload
    provenance = _provenance(payload, artifact.role)
    return {
        "artifact_sha256": artifact.sha256,
        "schema_version": _int(payload.get("schema_version")),
        "protocol_id": str(payload.get("protocol_id") or ""),
        "simulation_fingerprint": str(
            payload.get("simulation_fingerprint")
            or provenance.get("simulation_fingerprint")
            or ""
        ),
        "analysis_fingerprint": str(
            payload.get("analysis_fingerprint")
            or provenance.get("analysis_fingerprint")
            or ""
        ),
        "source_hash": str(provenance.get("source_hash") or ""),
        "simulation_source_hash": str(
            provenance.get("simulation_source_hash") or ""),
        "task_manifest_id": str(payload.get("task_manifest_id") or ""),
        "match_count": len(_rows(payload, artifact.role)),
        "v2_search_sample_count": search_sample_count,
    }


def _trace_digest(traces: Iterable[tuple[Any, ...]], version: str) -> str:
    return _domain_digest(f"traditional_ai_{version}", list(traces))


def _match_digest(payload: dict[str, Any]) -> str:
    return _domain_digest(
        "traditional_ai_normalized_matches_v1",
        _match_signature(payload),
    )


def _decision_counts_by_deck(payload: dict[str, Any], role: str) -> dict[str, int]:
    counts: Counter[str] = Counter()
    for row in _rows(payload, role):
        deck = str(row.get("strategy_a_deck") or row.get("deck") or "")
        samples = row.get("search_depth_samples_by_strategy")
        _require(isinstance(samples, dict), "search_samples_not_object", role)
        counts[deck] += sum(
            len(samples.get(strategy) or [])
            for strategy in ("A", "B")
        )
    return {
        deck: counts.get(deck, 0)
        for deck in DECK_ORDER
    }


def build_migration_evidence(
    spec: dict[str, Any],
    input_paths: dict[str, Path],
    baseline_source_root: Path,
) -> dict[str, Any]:
    _require(
        _int(spec.get("schema_version")) == EVIDENCE_SCHEMA_VERSION,
        "spec_schema_version",
    )
    contract_id = str(spec.get("migration_contract_id") or "")
    semantic_contract_id = str(spec.get("semantic_contract_id") or "")
    protocol_id = str(spec.get("protocol_id") or "")
    _require(bool(contract_id), "migration_contract_id")
    _require(bool(semantic_contract_id), "semantic_contract_id")
    _require(protocol_id == PROTOCOL_ID, "spec_protocol_id", protocol_id)
    artifacts = _load_artifacts(spec, input_paths)
    input_spec = spec["inputs"]
    for role, artifact in artifacts.items():
        _source_hash_binding(artifact, input_spec[role])

    legacy_traces: dict[str, list[tuple[Any, ...]]] = {}
    for role in LEGACY_ROLES:
        legacy_traces[role] = _validate_legacy_fixed_280(
            artifacts[role],
            spec,
        )
    _require(
        _match_signature(artifacts["legacy_baseline_280"].payload)
        == _match_signature(artifacts["legacy_candidate_280"].payload),
        "legacy_280_normalized_matches",
    )
    _require(
        legacy_traces["legacy_baseline_280"]
        == legacy_traces["legacy_candidate_280"],
        "legacy_280_trace_v0",
    )

    fixed_20_identities = _selected_fixed_20_identities(
        artifacts["legacy_baseline_280"],
        spec,
    )
    strict_20_traces: dict[str, list[tuple[Any, ...]]] = {}
    for role in STRICT_20_ROLES:
        strict_20_traces[role] = _validate_fixed_20(
            artifacts[role],
            spec,
            fixed_20_identities,
        )
    final_candidate = artifacts["final_candidate_280"]
    final_candidate_traces = _strict_v2_contract(final_candidate, protocol_id)
    fixed_validation = _fixed_280_payload_validation(final_candidate.payload)
    _require(
        bool(fixed_validation.get("valid")),
        "final_candidate_fixed_280_contract",
        fixed_validation.get("errors"),
    )
    fixed_280_spec = spec.get("fixed_280")
    _require(isinstance(fixed_280_spec, dict), "spec_fixed_280")
    _require(
        len(final_candidate_traces)
        == _int(fixed_280_spec.get("v2_search_samples")),
        "final_candidate_decisions",
        len(final_candidate_traces),
    )
    final_candidate_trace_v0 = _trace_signature(
        final_candidate.payload,
        role=final_candidate.role,
        include_semantic_hash=False,
    )
    _require(
        final_candidate_trace_v0 == legacy_traces["legacy_baseline_280"],
        "final_candidate_trace_v0",
    )
    final_match_signature = _match_signature(final_candidate.payload)
    _require(
        final_match_signature
        == _match_signature(artifacts["legacy_baseline_280"].payload),
        "final_candidate_normalized_matches",
    )

    subset_payloads = {
        role: _subset_payload(
            artifact.payload,
            role,
            fixed_20_identities,
        )
        for role, artifact in artifacts.items()
        if role.endswith("_280")
    }
    subset_trace_v0 = {
        role: _trace_signature(
            payload,
            role=role,
            include_semantic_hash=False,
        )
        for role, payload in subset_payloads.items()
    }
    for role in LEGACY_ROLES:
        _require(
            subset_trace_v0[role]
            == _trace_signature(
                artifacts[
                    "original_baseline_20"
                    if role == "legacy_baseline_280"
                    else "current_final_20"
                ].payload,
                role=role,
                include_semantic_hash=False,
            ),
            "fixed_20_legacy_trace_binding",
            role,
        )
    candidate_subset_v1 = _trace_signature(
        subset_payloads["final_candidate_280"],
        role="final_candidate_280",
        include_semantic_hash=True,
    )
    fixed_20_match_signature = _match_signature(
        subset_payloads["final_candidate_280"])
    for role in STRICT_20_ROLES:
        _require(
            strict_20_traces[role] == candidate_subset_v1,
            (
                "original_baseline_to_candidate_semantics"
                if role == "original_baseline_20"
                else "current_final_to_candidate_semantics"
            ),
        )
        _require(
            _match_signature(artifacts[role].payload)
            == fixed_20_match_signature,
            "fixed_20_normalized_matches",
            role,
        )

    source_attestation = _validate_baseline_source_attestation(
        spec,
        artifacts,
        baseline_source_root,
    )
    candidate_source = {
        field: copy.deepcopy(
            _provenance(final_candidate.payload, final_candidate.role).get(field)
        )
        for field in (
            "simulation_source_hash",
            "strategy_file_sha256",
            "component_hashes",
            "godot_executable_sha256",
            "godot_runtime_version",
            "toolchain_lock_sha256",
            "release_manifest_sha256",
            "target_platform",
        )
    }
    performance = _validate_performance(
        spec,
        artifacts["legacy_baseline_280"],
        artifacts["legacy_candidate_280"],
        final_candidate,
    )

    legacy_decisions = len(legacy_traces["legacy_baseline_280"])
    semantic_decisions = len(candidate_subset_v1)
    candidate_decisions = len(final_candidate_traces)
    _require(
        legacy_decisions == candidate_decisions,
        "decision_count_equivalence",
    )
    checks = [
        {"id": "legacy_inputs_pinned", "status": "pass"},
        {"id": "legacy_semantic_hash_uniformly_absent", "status": "pass"},
        {"id": "legacy_280_normalized_matches_equal", "status": "pass"},
        {"id": "legacy_280_trace_v0_equal", "status": "pass"},
        {"id": "fixed_20_is_exact_legacy_subset", "status": "pass"},
        {"id": "fixed_20_strict_v7_decision_contract", "status": "pass"},
        {"id": "original_baseline_to_candidate_trace_v1_equal", "status": "pass"},
        {"id": "current_final_to_candidate_trace_v1_equal", "status": "pass"},
        {"id": "candidate_fixed_20_projection_trace_v1", "status": "pass"},
        {"id": "final_candidate_280_strict", "status": "pass"},
        {"id": "final_candidate_280_trace_v0_equal", "status": "pass"},
        {"id": "baseline_source_attestation", "status": "pass"},
        {"id": "candidate_source_attestation", "status": "pass"},
        {"id": "performance_execution_comparable", "status": "pass"},
        {"id": "performance_thresholds", "status": "pass"},
    ]
    evidence: dict[str, Any] = {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "artifact_kind": ARTIFACT_KIND,
        "migration_contract_id": contract_id,
        "protocol_id": protocol_id,
        "semantic_contract_id": semantic_contract_id,
        "acceptance_mode": "one_time_migration_composite",
        "scope": {
            "one_time": True,
            "legacy_exception": "decision_semantic_hash_uniformly_absent_only",
            "fixed_280_task_manifest_id": str(
                fixed_280_spec.get("task_manifest_id") or ""),
            "fixed_20_task_manifest_id": str(
                spec["fixed_20"].get("task_manifest_id") or ""),
            "accepted_candidate_simulation_source_hash": str(
                candidate_source.get("simulation_source_hash") or ""),
        },
        "inputs": {
            role: _artifact_record(
                artifact,
                search_sample_count=(
                    len(legacy_traces[role])
                    if role in legacy_traces
                    else (
                        len(strict_20_traces[role])
                        if role in strict_20_traces
                        else len(final_candidate_traces)
                    )
                ),
            )
            for role, artifact in artifacts.items()
        },
        "derived_roles": {
            "final_candidate_fixed_20": {
                "source_role": "final_candidate_280",
                "match_count": len(fixed_20_identities),
                "v2_search_sample_count": semantic_decisions,
                "normalized_matches_sha256": _match_digest(
                    subset_payloads["final_candidate_280"]),
                "trace_v0_sha256": _trace_digest(
                    subset_trace_v0["final_candidate_280"],
                    "trace_v0",
                ),
                "trace_v1_sha256": _trace_digest(
                    candidate_subset_v1,
                    "trace_v1",
                ),
            },
        },
        "digests": {
            "normalized_matches": {
                role: _match_digest(artifact.payload)
                for role, artifact in artifacts.items()
            },
            "trace_v0": {
                role: _trace_digest(
                    (
                        legacy_traces[role]
                        if role in legacy_traces
                        else _trace_signature(
                            artifact.payload,
                            role=role,
                            include_semantic_hash=False,
                        )
                    ),
                    "trace_v0",
                )
                for role, artifact in artifacts.items()
            },
            "trace_v1": {
                role: _trace_digest(
                    (
                        strict_20_traces[role]
                        if role in strict_20_traces
                        else final_candidate_traces
                    ),
                    "trace_v1",
                )
                for role, artifact in artifacts.items()
                if role not in LEGACY_ROLES
            },
            "fixed_20_identity_sha256": _domain_digest(
                "traditional_ai_fixed_20_identities_v1",
                sorted(fixed_20_identities),
            ),
        },
        "source_attestation": {
            "original_baseline_telemetry": source_attestation,
            "final_candidate": candidate_source,
        },
        "coverage": {
            "legacy_fixed_280_games": len(
                _rows(
                    artifacts["legacy_baseline_280"].payload,
                    "legacy_baseline_280",
                )),
            "legacy_fixed_280_v2_search_samples": legacy_decisions,
            "semantic_anchor_games": len(fixed_20_identities),
            "semantic_anchor_v2_search_samples": semantic_decisions,
            "semantic_anchor_fraction": round(
                semantic_decisions / legacy_decisions,
                9,
            ),
            "baseline_v2_search_samples_not_directly_semantic_observed": (
                legacy_decisions - semantic_decisions
            ),
            "final_candidate_fixed_280_games": len(
                _rows(final_candidate.payload, final_candidate.role)),
            "final_candidate_fixed_280_v2_search_samples": candidate_decisions,
            "semantic_anchor_search_samples_by_deck": _decision_counts_by_deck(
                subset_payloads["final_candidate_280"],
                "final_candidate_fixed_20",
            ),
        },
        "performance": performance,
        "checks": checks,
        "limitations": [
            (
                "The legacy baseline's decision_semantic_hash is directly "
                "observed only for the fixed-20 subset; the remaining legacy "
                "decisions are bound by exact normalized matches and trace-v0."
            ),
            (
                "This artifact is a one-time release migration attestation and "
                "must not be accepted by the production schema-v7 validator."
            ),
        ],
        "result": {
            "passed": True,
            "check_count": len(checks),
            "failed_check_count": 0,
        },
    }
    evidence["migration_id"] = _domain_digest(
        "traditional_ai_semantic_migration_evidence_id_v1",
        evidence,
    )
    return evidence


def verify_migration_evidence(
    evidence: dict[str, Any],
    spec: dict[str, Any],
    input_paths: dict[str, Path],
    baseline_source_root: Path,
) -> dict[str, Any]:
    _require(
        _int(evidence.get("schema_version")) == EVIDENCE_SCHEMA_VERSION,
        "evidence_schema_version",
    )
    _require(
        str(evidence.get("artifact_kind") or "") == ARTIFACT_KIND,
        "evidence_artifact_kind",
    )
    migration_id = str(evidence.get("migration_id") or "")
    unsigned = dict(evidence)
    unsigned.pop("migration_id", None)
    _require(
        _valid_sha256(migration_id)
        and migration_id
        == _domain_digest(
            "traditional_ai_semantic_migration_evidence_id_v1",
            unsigned,
        ),
        "evidence_migration_id",
    )
    rebuilt = build_migration_evidence(
        spec,
        input_paths,
        baseline_source_root,
    )
    _require(
        _canonical_json(evidence) == _canonical_json(rebuilt),
        "evidence_rebuild_mismatch",
    )
    return rebuilt


def _input_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--legacy-baseline-280", required=True, type=Path)
    parser.add_argument("--legacy-candidate-280", required=True, type=Path)
    parser.add_argument("--original-baseline-20", required=True, type=Path)
    parser.add_argument("--current-final-20", required=True, type=Path)
    parser.add_argument("--final-candidate-280", required=True, type=Path)
    parser.add_argument("--baseline-source-root", required=True, type=Path)


def _paths_from_args(args: argparse.Namespace) -> dict[str, Path]:
    return {
        "legacy_baseline_280": args.legacy_baseline_280,
        "legacy_candidate_280": args.legacy_candidate_280,
        "original_baseline_20": args.original_baseline_20,
        "current_final_20": args.current_final_20,
        "final_candidate_280": args.final_candidate_280,
    }


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build")
    _input_arguments(build_parser)
    build_parser.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify")
    _input_arguments(verify_parser)
    verify_parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    try:
        spec = _json_object(Path(__file__).with_name(
            "ai_evaluation_semantic_migration_spec.json"))
        paths = _paths_from_args(args)
        if args.command == "build":
            evidence = build_migration_evidence(
                spec,
                paths,
                args.baseline_source_root,
            )
            _write_json_atomic(args.output, evidence)
            print(f"MIGRATION_EVIDENCE_OK {args.output}")
        else:
            evidence = _json_object(args.evidence)
            verified = verify_migration_evidence(
                evidence,
                spec,
                paths,
                args.baseline_source_root,
            )
            print(f"MIGRATION_EVIDENCE_VERIFIED {verified['migration_id']}")
    except MigrationEvidenceError as error:
        print(
            _canonical_json({
                "status": "fail",
                "code": error.code,
                "details": error.details,
            }),
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

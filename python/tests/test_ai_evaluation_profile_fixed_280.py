from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path

from scripts.ai_evaluation_v7 import (
    DECK_ORDER,
    MergeError,
    PROTOCOL_ID,
    SCHEMA_VERSION,
    expected_match_identities,
    merge_checkpoint_summaries,
    performance_host_fingerprint,
)
from scripts.compare_ai_evaluation_profiles import (
    FIXED_280_CORPUS_ID,
    FIXED_280_SCHEDULE,
    FIXED_280_TASK_MANIFEST_ID,
    compare_profiles,
    evaluate_gates,
)
from tests.temp_utils import temp_dir


STRATEGY_FINGERPRINT = "e" * 64
EXECUTION_PROFILE_ID = (
    "windows-h1-w12-cache-on-native-on-profile-off"
)
PROFILED_EXECUTION_PROFILE_ID = (
    "windows-h1-w12-cache-on-native-on-profile-on"
)
HOST = {
    "system": "Windows",
    "release": "10",
    "machine": "AMD64",
    "processor": "Intel64 Family 6 Model 183 Stepping 1, GenuineIntel",
    "python": "3.11.15",
}
GODOT_RUNTIME_VERSION = "4.7.stable.official.test"
PERFORMANCE_HOST_FINGERPRINT = performance_host_fingerprint(
    HOST,
    godot_runtime_version=GODOT_RUNTIME_VERSION,
    target_platform="windows",
)
COMPONENT_HASHES = {
    "rules": "1" * 64,
    "ai": "2" * 64,
    "card_data": "3" * 64,
    "evaluation_tool": "4" * 64,
    "analysis_tool": "5" * 64,
}


def _trajectory_hash(identity: tuple[object, ...], strategy: str) -> str:
    encoded = json.dumps(
        [*identity, strategy],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _decision_semantic_hash(
    identity: tuple[object, ...],
    strategy: str,
) -> str:
    encoded = json.dumps(
        ["decision_semantics_v1", *identity, strategy],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _depth_sample(
    identity: tuple[object, ...],
    strategy: str,
    planner_ms: float,
) -> dict[str, object]:
    return {
        "requested": 8,
        "reached": 8,
        "completed": 8,
        "max_path_depth": 8,
        "reply_requested": 3,
        "reply_completed": 3,
        "reply_applicable": True,
        "reply_completion_reason": "depth_complete",
        "layers_completed": 8,
        "completion_reason": "depth_complete",
        "stop_reason": "depth_complete",
        "engine_id": "turn_beam_v2",
        "nodes_expanded": 100,
        "planner_ms": planner_ms,
        "trajectory_hash": _trajectory_hash(identity, strategy),
        "decision_semantic_hash": _decision_semantic_hash(
            identity,
            strategy,
        ),
    }


def _match_row(
    identity: tuple[str, str, str, int, int, int],
    planner_ms: float,
) -> dict[str, object]:
    kind, deck_a, deck_b, block, seed, seat = identity
    return {
        "deck": deck_a,
        "strategy_a_deck": deck_a,
        "strategy_b_deck": deck_b,
        "matchup_kind": kind,
        "matchup_key": f"{deck_a}_vs_{deck_b}",
        "pair_key": f"{deck_a}:{deck_b}:{block}:{seed}",
        "role_crossover_block_key": (
            f"{'_and_'.join(sorted((deck_a, deck_b)))}:{block}:{seed}"
            if kind == "cross"
            else ""
        ),
        "sample_phase": "main",
        "seed_block": block,
        "seed": seed,
        "seat": seat,
        "winner": "draw",
        "terminal_reason": "game_over",
        "decisions": 2,
        "choices": 1,
        "decision_ms_samples": [1.0, 2.0, 3.0],
        "decision_ms_samples_by_strategy": {
            "A": [1.0, 2.0],
            "B": [3.0],
        },
        "action_decisions_by_strategy": {"A": 1, "B": 1},
        "search_depth_decision_counts_by_strategy": {
            "A": {
                "applicable": 1,
                "not_applicable": 0,
                "reasons": {},
            },
            "B": {
                "applicable": 1,
                "not_applicable": 0,
                "reasons": {},
            },
        },
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "time_capped_decisions": 0,
        "dynamic_budget_stop_reasons": {},
        "deep_fallbacks": 0,
        "max_actions_exhausted": False,
        "search_depth_samples_by_strategy": {
            "A": [_depth_sample(identity, "A", planner_ms)],
            "B": [_depth_sample(identity, "B", planner_ms)],
        },
    }


def _fixed_280_payload(
    *,
    planner_ms: float,
    wall_clock_ms: float,
) -> dict[str, object]:
    config = {
        **FIXED_280_SCHEDULE,
        "seed_block_count": 5,
        "run_role": "main",
        "platform": "windows",
        "profile": False,
        "checkpoint_enabled": True,
        "disable_ai_cache": False,
        "disable_native_math": False,
        "evidence_shard_count": 50,
        "task_manifest_id": FIXED_280_TASK_MANIFEST_ID,
        "execution_profile_id": EXECUTION_PROFILE_ID,
    }
    execution_config = {
        **FIXED_280_SCHEDULE,
        "platform": "windows",
        "workers": 12,
        "parallel_workers": 12,
        "global_parallel_workers": 12,
        "external_shard_count": 1,
        "profile": False,
        "disable_ai_cache": False,
        "disable_native_math": False,
        "evidence_shard_count": 50,
        "task_manifest_id": FIXED_280_TASK_MANIFEST_ID,
        "execution_profile_id": EXECUTION_PROFILE_ID,
    }
    identities = sorted(
        expected_match_identities(DECK_ORDER, FIXED_280_SCHEDULE)
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "artifact_kind": "ai_evaluation_result",
        "platform": "windows",
        "deck_keys": list(DECK_ORDER),
        "task_manifest_id": FIXED_280_TASK_MANIFEST_ID,
        "execution_profile_id": EXECUTION_PROFILE_ID,
        "config": config,
        "execution_config": execution_config,
        "provenance": {
            "schema_version": SCHEMA_VERSION,
            "protocol_id": PROTOCOL_ID,
            "target_platform": "windows",
            "godot_runtime_version": GODOT_RUNTIME_VERSION,
            "godot_executable_sha256": "d" * 64,
            "host": copy.deepcopy(HOST),
            "performance_host_fingerprint": (
                PERFORMANCE_HOST_FINGERPRINT
            ),
            "component_hashes": copy.deepcopy(COMPONENT_HASHES),
            "simulation_config": copy.deepcopy(execution_config),
        },
        "strategies": {
            "A": {"id": "fixed-v2", "engine": "turn_beam_v2"},
            "B": {"id": "fixed-v2", "engine": "turn_beam_v2"},
        },
        "strategy_fingerprint": {
            "A": STRATEGY_FINGERPRINT,
            "B": STRATEGY_FINGERPRINT,
            "equal": True,
        },
        "performance_profile": {
            "enabled": False,
        },
        "checkpoint_summary": {
            "enabled": True,
            "shards_enabled": 50,
            "shards_total": 50,
            "restored_units": 0,
            "written_units": 95,
            "pending_units": 0,
        },
        "wall_clock_ms": wall_clock_ms,
        "wall_clock_scope": "full_evidence_stage",
        "matches": [
            _match_row(identity, planner_ms)
            for identity in identities
        ],
    }


def _set_profile(
    payload: dict[str, object],
    *,
    enabled: bool,
) -> None:
    execution_profile_id = (
        PROFILED_EXECUTION_PROFILE_ID
        if enabled
        else EXECUTION_PROFILE_ID
    )
    payload["execution_profile_id"] = execution_profile_id
    for container in (
        payload["config"],
        payload["execution_config"],
        payload["provenance"]["simulation_config"],
    ):
        container["profile"] = enabled
        container["execution_profile_id"] = execution_profile_id
    payload["config"]["checkpoint_enabled"] = not enabled
    payload["performance_profile"]["enabled"] = enabled
    payload["checkpoint_summary"] = {
        "enabled": not enabled,
        "shards_enabled": 0 if enabled else 50,
        "shards_total": 50,
        "restored_units": 0,
        "written_units": 0 if enabled else 95,
        "pending_units": 0,
    }


def _strict_gate(
    baseline: dict[str, object],
    candidate: dict[str, object],
) -> tuple[dict[str, object], dict[str, object]]:
    comparison = compare_profiles(baseline, candidate)
    gate = evaluate_gates(
        comparison,
        require_planner_reduction=0.25,
        require_wall_reduction=0.20,
        require_fixed_280=True,
    )
    return comparison, gate


class Fixed280PerformanceComparisonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.baseline = _fixed_280_payload(
            planner_ms=10.0,
            wall_clock_ms=1000.0,
        )
        self.candidate = _fixed_280_payload(
            planner_ms=7.5,
            wall_clock_ms=800.0,
        )

    def test_canonical_v2_v2_corpus_passes_strict_gate(self):
        comparison, gate = _strict_gate(
            self.baseline, self.candidate
        )

        self.assertTrue(gate["passed"], gate["errors"])
        self.assertEqual(
            FIXED_280_TASK_MANIFEST_ID,
            "6185f019bd24d34df4cfa44ef87c7f0876b7c0396a2abf82a86e3d809189fd6a",
        )
        self.assertEqual(comparison["corpus_id"], FIXED_280_CORPUS_ID)
        corpus = comparison["fixed_280_corpus"]
        self.assertTrue(corpus["valid"], corpus["errors"])
        self.assertEqual(corpus["baseline"]["games"], 280)
        self.assertEqual(corpus["baseline"]["mirror_games"], 100)
        self.assertEqual(corpus["baseline"]["cross_games"], 180)
        self.assertEqual(corpus["baseline"]["mirror_units"], 50)
        self.assertEqual(corpus["baseline"]["cross_units"], 45)
        self.assertTrue(comparison["wall_clock_ms"]["authoritative"])

    def test_planner_gate_rejects_zero_duration_v2_samples(self):
        for role in ("baseline", "candidate"):
            with self.subTest(role=role):
                baseline = copy.deepcopy(self.baseline)
                candidate = copy.deepcopy(self.candidate)
                payload = baseline if role == "baseline" else candidate
                payload["matches"][0]["search_depth_samples_by_strategy"][
                    "A"
                ][0]["planner_ms"] = 0.0

                comparison, gate = _strict_gate(baseline, candidate)

                planner = comparison["planner_ms_per_node"]
                self.assertFalse(planner["available"])
                self.assertEqual(
                    f"{role}_planner_ms_invalid",
                    planner["reason"],
                )
                self.assertEqual(1, planner[role]["invalid_planner_ms"])
                self.assertFalse(gate["passed"])
                self.assertIn(
                    "planner_metric_unavailable",
                    [error["code"] for error in gate["errors"]],
                )

    def test_target_ai_hash_may_change_but_runtime_components_must_match(self):
        optimized = copy.deepcopy(self.candidate)
        optimized["provenance"]["component_hashes"]["ai"] = "9" * 64

        comparison, gate = _strict_gate(self.baseline, optimized)

        self.assertTrue(gate["passed"], comparison["fixed_280_corpus"]["errors"])
        self.assertTrue(
            comparison["fixed_280_corpus"]["same_non_target_components"]
        )

        for component in ("rules", "card_data", "evaluation_tool"):
            with self.subTest(component=component):
                changed = copy.deepcopy(self.candidate)
                changed["provenance"]["component_hashes"][component] = "9" * 64
                comparison, gate = _strict_gate(self.baseline, changed)
                self.assertFalse(comparison["fixed_280_corpus"]["valid"])
                self.assertFalse(gate["passed"])
                self.assertIn(
                    "non_target_component_hashes_mismatch",
                    comparison["fixed_280_corpus"]["errors"],
                )

    def test_exact_godot_executable_hash_is_required_and_matched(self):
        changed = copy.deepcopy(self.candidate)
        changed["provenance"]["godot_executable_sha256"] = "9" * 64
        comparison, gate = _strict_gate(self.baseline, changed)
        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "godot_executable_sha256_mismatch",
            comparison["fixed_280_corpus"]["errors"],
        )

        for value in (None, "not-a-sha256"):
            with self.subTest(value=value):
                malformed = copy.deepcopy(self.candidate)
                if value is None:
                    malformed["provenance"].pop("godot_executable_sha256")
                else:
                    malformed["provenance"]["godot_executable_sha256"] = value
                comparison, gate = _strict_gate(self.baseline, malformed)
                self.assertFalse(comparison["fixed_280_corpus"]["valid"])
                self.assertFalse(gate["passed"])
                self.assertIn(
                    "candidate:godot_executable_sha256_invalid",
                    comparison["fixed_280_corpus"]["errors"],
                )

    def test_checkpoint_summary_aggregation_is_additive_and_strict(self):
        summary = merge_checkpoint_summaries([
            {
                "checkpoint_summary": {
                    "enabled": True,
                    "restored_units": 0,
                    "written_units": 2,
                    "pending_units": 0,
                    "completed_unit_ids": [
                        "mirror|colorless|0|17",
                        "mirror|darkness|0|1000020",
                    ],
                },
            },
            {
                "checkpoint_summary": {
                    "enabled": True,
                    "restored_units": 3,
                    "written_units": 1,
                    "pending_units": 4,
                    "completed_unit_ids": [
                        "mirror|dragon|0|2000023",
                        "mirror|fighting|0|3000026",
                        "mirror|fire|0|4000029",
                        "mirror|grass|0|5000032",
                    ],
                },
            },
        ])

        self.assertEqual(summary["shards_enabled"], 2)
        self.assertEqual(summary["shards_total"], 2)
        self.assertEqual(summary["restored_units"], 3)
        self.assertEqual(summary["written_units"], 3)
        self.assertEqual(summary["pending_units"], 4)
        self.assertEqual(summary["completed_units"], 6)
        self.assertEqual(len(summary["completed_unit_ids"]), 6)
        self.assertEqual(len(summary["completed_unit_ids_sha256"]), 64)
        with self.assertRaisesRegex(
            MergeError, "invalid_checkpoint_summary"
        ):
            merge_checkpoint_summaries([{
                "checkpoint_summary": {
                    "enabled": True,
                    "restored_units": -1,
                    "written_units": 0,
                    "pending_units": 0,
                    "completed_unit_ids": [],
                },
            }])

    def test_incomplete_manifest_fault_and_wrong_engine_fail_closed(self):
        mutations = {}

        incomplete = copy.deepcopy(self.candidate)
        incomplete["matches"].pop()
        mutations["incomplete"] = incomplete

        wrong_manifest = copy.deepcopy(self.candidate)
        wrong_manifest["task_manifest_id"] = "0" * 64
        mutations["manifest"] = wrong_manifest

        structural_fault = copy.deepcopy(self.candidate)
        structural_fault["matches"][0]["invalid_actions"] = 1
        mutations["structural_fault"] = structural_fault

        wrong_engine = copy.deepcopy(self.candidate)
        wrong_engine["strategies"]["B"]["engine"] = "turn_beam_v1"
        mutations["wrong_engine"] = wrong_engine

        resumed = copy.deepcopy(self.candidate)
        resumed["checkpoint_summary"]["restored_units"] = 1
        mutations["resumed_checkpoint"] = resumed

        for label, candidate in mutations.items():
            with self.subTest(label=label):
                comparison, gate = _strict_gate(
                    self.baseline, candidate
                )
                self.assertFalse(comparison["fixed_280_corpus"]["valid"])
                self.assertFalse(gate["passed"])
                self.assertIn(
                    "fixed_280_corpus_invalid",
                    [error["code"] for error in gate["errors"]],
                )

    def test_decision_accounting_rejects_only_one_of_560_samples(self):
        candidate = copy.deepcopy(self.candidate)
        kept = copy.deepcopy(
            candidate["matches"][0][
                "search_depth_samples_by_strategy"
            ]["A"]
        )
        for row in candidate["matches"]:
            row["search_depth_samples_by_strategy"]["A"] = []
            row["search_depth_samples_by_strategy"]["B"] = []
        candidate["matches"][0]["search_depth_samples_by_strategy"][
            "A"
        ] = kept

        comparison, gate = _strict_gate(self.baseline, candidate)

        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertTrue(any(
            "decision_contract:" in error
            for error in comparison["fixed_280_corpus"]["errors"]
        ))

    def test_every_v2_decision_requires_a_valid_semantic_hash(self):
        for label, value in (
            ("missing", None),
            ("non_hex", "z" * 64),
            ("uppercase", "A" * 64),
        ):
            with self.subTest(label=label):
                candidate = copy.deepcopy(self.candidate)
                sample = candidate["matches"][0][
                    "search_depth_samples_by_strategy"
                ]["A"][0]
                if value is None:
                    sample.pop("decision_semantic_hash")
                else:
                    sample["decision_semantic_hash"] = value

                comparison, gate = _strict_gate(
                    self.baseline,
                    candidate,
                )

                self.assertFalse(
                    comparison["fixed_280_corpus"]["valid"]
                )
                self.assertFalse(comparison["same_v2_search_traces"])
                self.assertFalse(gate["passed"])
                self.assertTrue(any(
                    "decision_contract:A:decision_semantic_hash" in error
                    for error in comparison["fixed_280_corpus"]["errors"]
                ))
                self.assertTrue(any(
                    "decision_semantic_hash" in error
                    for error in comparison["v2_search_samples"][
                        "candidate_validation_errors"
                    ]
                ))

    def test_semantic_hash_is_compared_for_each_exact_v2_decision(self):
        candidate = copy.deepcopy(self.candidate)
        sample = candidate["matches"][0][
            "search_depth_samples_by_strategy"
        ]["A"][0]
        original_hash = str(sample["decision_semantic_hash"])
        sample["decision_semantic_hash"] = (
            ("0" if original_hash[0] != "0" else "1")
            + original_hash[1:]
        )

        comparison, gate = _strict_gate(self.baseline, candidate)

        self.assertTrue(
            comparison["fixed_280_corpus"]["valid"],
            comparison["fixed_280_corpus"]["errors"],
        )
        self.assertTrue(comparison["same_match_results"])
        self.assertFalse(comparison["same_v2_search_traces"])
        self.assertFalse(comparison["equivalent"])
        self.assertFalse(gate["passed"])
        self.assertEqual(
            comparison["v2_search_samples"][
                "candidate_validation_errors"
            ],
            [],
        )

    def test_execution_configuration_must_match_fixed_profile(self):
        mutations = {}

        workers = copy.deepcopy(self.candidate)
        workers["execution_config"]["workers"] = 11
        workers["execution_config"]["parallel_workers"] = 11
        workers["execution_config"]["global_parallel_workers"] = 11
        workers["provenance"]["simulation_config"]["workers"] = 11
        workers["provenance"]["simulation_config"][
            "global_parallel_workers"
        ] = 11
        mutations["workers"] = workers

        no_native = copy.deepcopy(self.candidate)
        for container in (
            no_native["config"],
            no_native["execution_config"],
            no_native["provenance"]["simulation_config"],
        ):
            container["disable_native_math"] = True
        mutations["native"] = no_native

        different_profile = copy.deepcopy(self.candidate)
        different_id = "windows-h1-w12-different"
        different_profile["execution_profile_id"] = different_id
        different_profile["config"]["execution_profile_id"] = different_id
        different_profile["execution_config"][
            "execution_profile_id"
        ] = different_id
        different_profile["provenance"]["simulation_config"][
            "execution_profile_id"
        ] = different_id
        mutations["execution_profile"] = different_profile

        for label, candidate in mutations.items():
            with self.subTest(label=label):
                comparison, gate = _strict_gate(
                    self.baseline, candidate
                )
                self.assertFalse(comparison["fixed_280_corpus"]["valid"])
                self.assertFalse(gate["passed"])

    def test_profile_mode_may_be_on_or_off_but_must_match(self):
        profiled_baseline = copy.deepcopy(self.baseline)
        profiled_candidate = copy.deepcopy(self.candidate)
        _set_profile(profiled_baseline, enabled=True)
        _set_profile(profiled_candidate, enabled=True)

        comparison, gate = _strict_gate(
            profiled_baseline,
            profiled_candidate,
        )
        self.assertTrue(gate["passed"], comparison["fixed_280_corpus"]["errors"])

        mismatched = copy.deepcopy(profiled_candidate)
        _set_profile(mismatched, enabled=False)
        comparison, gate = _strict_gate(profiled_baseline, mismatched)
        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "execution_config_mismatch",
            comparison["fixed_280_corpus"]["errors"],
        )

    def test_profiled_timing_must_disable_checkpoints(self):
        baseline = copy.deepcopy(self.baseline)
        candidate = copy.deepcopy(self.candidate)
        _set_profile(baseline, enabled=True)
        _set_profile(candidate, enabled=True)
        candidate["checkpoint_summary"]["enabled"] = True
        candidate["checkpoint_summary"]["restored_units"] = 1

        comparison, gate = _strict_gate(baseline, candidate)

        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "candidate:profiled_checkpoint_not_disabled",
            comparison["fixed_280_corpus"]["errors"],
        )

    def test_checkpoint_identity_counts_and_shards_fail_closed(self):
        mutations = {}

        enabled_mismatch = copy.deepcopy(self.candidate)
        enabled_mismatch["checkpoint_summary"]["enabled"] = False
        mutations["enabled_mismatch"] = enabled_mismatch

        incomplete_writes = copy.deepcopy(self.candidate)
        incomplete_writes["checkpoint_summary"]["written_units"] = 94
        mutations["incomplete_writes"] = incomplete_writes

        shard_mismatch = copy.deepcopy(self.candidate)
        shard_mismatch["checkpoint_summary"]["shards_enabled"] = 49
        mutations["shard_mismatch"] = shard_mismatch

        for label, candidate in mutations.items():
            with self.subTest(label=label):
                comparison, gate = _strict_gate(
                    self.baseline,
                    candidate,
                )
                self.assertFalse(comparison["fixed_280_corpus"]["valid"])
                self.assertFalse(gate["passed"])

    def test_wall_clock_scope_is_full_stage_and_legacy_runtime_is_rejected(self):
        for scope in (None, "current_attempt_only"):
            with self.subTest(scope=scope):
                candidate = copy.deepcopy(self.candidate)
                if scope is None:
                    candidate.pop("wall_clock_scope")
                else:
                    candidate["wall_clock_scope"] = scope
                comparison, gate = _strict_gate(
                    self.baseline,
                    candidate,
                )
                self.assertFalse(comparison["fixed_280_corpus"]["valid"])
                self.assertFalse(gate["passed"])

        legacy_baseline = copy.deepcopy(self.baseline)
        legacy_candidate = copy.deepcopy(self.candidate)
        for payload in (legacy_baseline, legacy_candidate):
            _set_profile(payload, enabled=True)
            payload.pop("wall_clock_scope")
            payload.pop("checkpoint_summary")
            payload["provenance"].pop("godot_executable_sha256")
            payload["provenance"].pop("performance_host_fingerprint")
        comparison, gate = _strict_gate(
            legacy_baseline,
            legacy_candidate,
        )
        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "baseline:godot_executable_sha256_invalid",
            comparison["fixed_280_corpus"]["errors"],
        )
        self.assertIn(
            "candidate:godot_executable_sha256_invalid",
            comparison["fixed_280_corpus"]["errors"],
        )

    def test_performance_host_fingerprint_is_verified_and_matched(self):
        tampered = copy.deepcopy(self.candidate)
        tampered["provenance"]["host"]["machine"] = "arm64"
        comparison, gate = _strict_gate(self.baseline, tampered)
        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "candidate:performance_host_fingerprint_mismatch",
            comparison["fixed_280_corpus"]["errors"],
        )

        other_host = copy.deepcopy(self.candidate)
        other_host["provenance"]["host"]["machine"] = "arm64"
        other_host["provenance"]["performance_host_fingerprint"] = (
            performance_host_fingerprint(
                other_host["provenance"]["host"],
                godot_runtime_version=GODOT_RUNTIME_VERSION,
                target_platform="windows",
            )
        )
        comparison, gate = _strict_gate(self.baseline, other_host)
        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "execution_config_mismatch",
            comparison["fixed_280_corpus"]["errors"],
        )

        missing = copy.deepcopy(self.candidate)
        missing["provenance"].pop("performance_host_fingerprint")
        comparison, gate = _strict_gate(self.baseline, missing)
        self.assertFalse(comparison["fixed_280_corpus"]["valid"])
        self.assertFalse(gate["passed"])
        self.assertIn(
            "candidate:performance_host_fingerprint_missing",
            comparison["fixed_280_corpus"]["errors"],
        )

    def test_strict_wall_gate_rejects_elapsed_fallback(self):
        baseline = copy.deepcopy(self.baseline)
        candidate = copy.deepcopy(self.candidate)
        baseline["elapsed_ms"] = baseline.pop("wall_clock_ms")
        candidate["elapsed_ms"] = candidate.pop("wall_clock_ms")

        comparison = compare_profiles(baseline, candidate)
        self.assertEqual(
            comparison["wall_clock_ms"]["baseline_source"],
            "elapsed_ms",
        )
        self.assertFalse(comparison["wall_clock_ms"]["authoritative"])
        gate = evaluate_gates(
            comparison,
            require_planner_reduction=0.25,
            require_wall_reduction=0.20,
            require_fixed_280=True,
        )

        self.assertFalse(gate["passed"])
        wall_errors = [
            error
            for error in gate["errors"]
            if error["code"] == "wall_metric_unavailable"
        ]
        self.assertEqual(len(wall_errors), 1)
        self.assertIn(
            "authoritative_wall_clock_ms_required",
            wall_errors[0]["message"],
        )

    def test_cli_requires_explicit_fixed_280_protocol(self):
        script = (
            Path(__file__).parents[1]
            / "scripts"
            / "compare_ai_evaluation_profiles.py"
        )
        with temp_dir() as directory:
            baseline_path = Path(directory) / "baseline.json"
            candidate_path = Path(directory) / "candidate.json"
            baseline_path.write_text(
                json.dumps(self.baseline),
                encoding="utf-8",
            )
            candidate_path.write_text(
                json.dumps(self.candidate),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--baseline",
                    str(baseline_path),
                    "--candidate",
                    str(candidate_path),
                    "--require-fixed-280",
                    "--require-planner-reduction",
                    "0.25",
                    "--require-wall-reduction",
                    "0.20",
                    "--json",
                ],
                capture_output=True,
                check=False,
                encoding="utf-8",
                timeout=30,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertTrue(payload["gate"]["passed"])
        self.assertTrue(payload["gate"]["require_fixed_280"])


if __name__ == "__main__":
    unittest.main()

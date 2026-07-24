from __future__ import annotations

import copy
import hashlib
import json
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.ai_evaluation_v7 import match_decision_contract_error
from scripts.build_ai_evaluation_semantic_migration import (
    LoadedArtifact,
    MigrationEvidenceError,
    _canonical_json,
    _domain_digest,
    _function_text,
    _sha256_bytes,
    _sha256_file,
    _validate_performance,
    build_migration_evidence,
    verify_migration_evidence,
)
from tests.temp_utils import temp_dir
from tests.test_ai_evaluation_profile_fixed_280 import (
    FIXED_280_TASK_MANIFEST_ID,
    _fixed_280_payload,
    _set_profile,
)


FIXED_20_TASK_MANIFEST_ID = "f" * 64
FINAL_SIMULATION_SOURCE_HASH = "9" * 64
TELEMETRY_SIMULATION_SOURCE_HASH = "8" * 64


def _write_json(path: Path, value: dict[str, object]) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True),
        encoding="utf-8",
    )


def _remove_semantic_hashes(payload: dict[str, object]) -> None:
    for row in payload["matches"]:
        for strategy in ("A", "B"):
            for sample in row["search_depth_samples_by_strategy"][strategy]:
                sample.pop("decision_semantic_hash", None)


def _fixed_20_payload(source: dict[str, object]) -> dict[str, object]:
    result = copy.deepcopy(source)
    result["matches"] = [
        row
        for row in result["matches"]
        if row["matchup_kind"] == "mirror" and row["seed_block"] == 0
    ]
    result["task_manifest_id"] = FIXED_20_TASK_MANIFEST_ID
    for container in (
        result["config"],
        result["execution_config"],
        result["provenance"]["simulation_config"],
    ):
        container["task_manifest_id"] = FIXED_20_TASK_MANIFEST_ID
    return result


def _bind_v7_provenance(
    payload: dict[str, object],
    *,
    simulation_source_hash: str,
    source_hash: str,
) -> None:
    payload["gate_depth_source"] = "main_matches"
    payload["simulation_fingerprint"] = "a" * 64
    payload["analysis_fingerprint"] = "b" * 64
    provenance = payload["provenance"]
    provenance["simulation_fingerprint"] = "a" * 64
    provenance["analysis_fingerprint"] = "b" * 64
    provenance["simulation_source_hash"] = simulation_source_hash
    provenance["source_hash"] = source_hash
    provenance["strategy_file_sha256"] = {"0": "c" * 64, "1": "c" * 64}
    provenance["toolchain_lock_sha256"] = "d" * 64
    provenance["release_manifest_sha256"] = "e" * 64


class SemanticMigrationFixture:
    def __init__(self, root: Path):
        self.root = root
        self.source_root = root / "baseline-source"
        (self.source_root / "godot/ai").mkdir(parents=True)
        (self.source_root / "godot/tools").mkdir(parents=True)
        (self.source_root / "godot/rules").mkdir(parents=True)
        self.challenge = self.source_root / "godot/ai/challenge_ai.gd"
        self.runner = self.source_root / "godot/tools/ai_evaluation_runner.gd"
        self.guard = self.source_root / "godot/rules/game_engine.gd"
        self.challenge.write_text(
            (
                "func _traditional_decision_semantic_hash(value):\n"
                "\treturn str(value).sha256_text()\n\n"
                "func next_function():\n"
                "\tpass\n"
            ),
            encoding="utf-8",
        )
        self.runner.write_text("runner telemetry\n", encoding="utf-8")
        self.guard.write_text("unchanged rules\n", encoding="utf-8")

        baseline = _fixed_280_payload(planner_ms=10.0, wall_clock_ms=1000.0)
        old_candidate = _fixed_280_payload(
            planner_ms=8.0,
            wall_clock_ms=850.0,
        )
        final_candidate = _fixed_280_payload(
            planner_ms=7.5,
            wall_clock_ms=800.0,
        )
        for payload in (baseline, old_candidate, final_candidate):
            _set_profile(payload, enabled=True)
            _bind_v7_provenance(
                payload,
                simulation_source_hash=FINAL_SIMULATION_SOURCE_HASH,
                source_hash="7" * 64,
            )
        baseline["provenance"]["simulation_source_hash"] = "1" * 64
        baseline["provenance"]["source_hash"] = "2" * 64
        old_candidate["provenance"]["simulation_source_hash"] = "3" * 64
        old_candidate["provenance"]["source_hash"] = "4" * 64
        original_baseline_20 = _fixed_20_payload(final_candidate)
        current_final_20 = _fixed_20_payload(final_candidate)
        _bind_v7_provenance(
            original_baseline_20,
            simulation_source_hash=TELEMETRY_SIMULATION_SOURCE_HASH,
            source_hash="6" * 64,
        )
        _bind_v7_provenance(
            current_final_20,
            simulation_source_hash="5" * 64,
            source_hash="5" * 64,
        )

        source_files = [
            "godot/ai/challenge_ai.gd",
            "godot/tools/ai_evaluation_runner.gd",
            "godot/rules/game_engine.gd",
        ]
        baseline["provenance"]["source_files"] = source_files
        _remove_semantic_hashes(baseline)
        _remove_semantic_hashes(old_candidate)
        self.payloads = {
            "legacy_baseline_280": baseline,
            "legacy_candidate_280": old_candidate,
            "original_baseline_20": original_baseline_20,
            "current_final_20": current_final_20,
            "final_candidate_280": final_candidate,
        }
        self.paths: dict[str, Path] = {}
        for role, payload in self.payloads.items():
            path = root / f"{role}.json"
            _write_json(path, payload)
            self.paths[role] = path

        fixed_20_count = sum(
            len(row["search_depth_samples_by_strategy"][strategy])
            for row in original_baseline_20["matches"]
            for strategy in ("A", "B")
        )
        fixed_280_count = sum(
            len(row["search_depth_samples_by_strategy"][strategy])
            for row in final_candidate["matches"]
            for strategy in ("A", "B")
        )
        unchanged_rows = [{
            "path": "godot/rules/game_engine.gd",
            "sha256": _sha256_file(self.guard),
        }]
        unchanged_manifest = _sha256_bytes(
            _canonical_json(unchanged_rows).encode("utf-8"))
        function_hash = _sha256_bytes(_function_text(
            self.challenge,
            "_traditional_decision_semantic_hash",
        ).encode("utf-8"))
        allowed_changed_files = {
            "godot/ai/challenge_ai.gd": {
                "before_sha256": "1" * 64,
                "after_sha256": _sha256_file(self.challenge),
            },
            "godot/tools/ai_evaluation_runner.gd": {
                "before_sha256": "2" * 64,
                "after_sha256": _sha256_file(self.runner),
            },
        }
        transition_digest = _domain_digest(
            "traditional_ai_telemetry_transition_v1",
            {
                "allowed_changed_files": allowed_changed_files,
                "semantic_hash_function_sha256": function_hash,
                "unchanged_source_manifest_sha256": unchanged_manifest,
            },
        )
        self.spec: dict[str, object] = {
            "schema_version": 1,
            "migration_contract_id": (
                "traditional_ai_v7_decision_semantics_migration_v1"
            ),
            "protocol_id": "traditional_ai_evaluation_v7",
            "semantic_contract_id": "traditional_ai_decision_semantics_v1",
            "inputs": {
                "legacy_baseline_280": {
                    "artifact_sha256": _sha256_file(
                        self.paths["legacy_baseline_280"]),
                    "semantic_hash_mode": "uniformly_absent",
                },
                "legacy_candidate_280": {
                    "artifact_sha256": _sha256_file(
                        self.paths["legacy_candidate_280"]),
                    "semantic_hash_mode": "uniformly_absent",
                },
                "original_baseline_20": {
                    "generated": True,
                    "semantic_hash_mode": "required",
                    "simulation_source_hash": TELEMETRY_SIMULATION_SOURCE_HASH,
                },
                "current_final_20": {
                    "generated": True,
                    "semantic_hash_mode": "required",
                    "simulation_source_hash": "5" * 64,
                },
                "final_candidate_280": {
                    "generated": True,
                    "semantic_hash_mode": "required",
                    "simulation_source_hash": FINAL_SIMULATION_SOURCE_HASH,
                },
            },
            "fixed_20": {
                "task_manifest_id": FIXED_20_TASK_MANIFEST_ID,
                "games": 20,
                "v2_search_samples": fixed_20_count,
                "mirror_units": 10,
                "selector": {
                    "matchup_kind": "mirror",
                    "seed_block": 0,
                },
            },
            "fixed_280": {
                "task_manifest_id": FIXED_280_TASK_MANIFEST_ID,
                "games": 280,
                "v2_search_samples": fixed_280_count,
                "mirror_units": 50,
                "cross_units": 45,
            },
            "performance": {
                "planner_ms_per_node_reduction_min": 0.25,
                "wall_clock_reduction_min": 0.2,
                "workers": 12,
                "profile": True,
                "disable_ai_cache": False,
                "disable_native_math": False,
                "execution_profile_id": (
                    "windows-h1-w12-cache-on-native-on-profile-on"
                ),
            },
            "baseline_source_attestation": {
                "legacy_source_hash": "2" * 64,
                "legacy_simulation_source_hash": "1" * 64,
                "telemetry_source_hash": "6" * 64,
                "telemetry_simulation_source_hash": (
                    TELEMETRY_SIMULATION_SOURCE_HASH
                ),
                "unchanged_source_manifest_sha256": unchanged_manifest,
                "semantic_hash_function_sha256": function_hash,
                "telemetry_transition_sha256": transition_digest,
                "allowed_changed_files": allowed_changed_files,
                "unchanged_component_hashes": {
                    "rules": "1" * 64,
                    "card_data": "3" * 64,
                },
                "telemetry_component_hashes": {
                    "ai": "2" * 64,
                    "evaluation_tool": "4" * 64,
                },
                "guard_files": {
                    "godot/rules/game_engine.gd": _sha256_file(self.guard),
                },
            },
        }

    def rewrite(self, role: str) -> None:
        _write_json(self.paths[role], self.payloads[role])

    def artifact(self, role: str) -> LoadedArtifact:
        return LoadedArtifact(
            role=role,
            path=self.paths[role],
            sha256=_sha256_file(self.paths[role]),
            payload=self.payloads[role],
        )

    def build(self) -> dict[str, object]:
        return build_migration_evidence(
            self.spec,
            self.paths,
            self.source_root,
        )


class SemanticMigrationEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.context = temp_dir()
        self.root = Path(self.context.__enter__())
        self.addCleanup(self.context.__exit__, None, None, None)
        self.fixture = SemanticMigrationFixture(self.root)

    def assert_migration_error(self, code: str, callback) -> None:
        with self.assertRaises(MigrationEvidenceError) as raised:
            callback()
        self.assertEqual(code, raised.exception.code)

    def test_happy_path_is_deterministic_and_verifiable(self):
        first = self.fixture.build()
        second = self.fixture.build()

        self.assertEqual(first, second)
        self.assertTrue(first["result"]["passed"])
        self.assertEqual(5, len(first["inputs"]))
        self.assertEqual(
            20,
            first["derived_roles"]["final_candidate_fixed_20"]["match_count"],
        )
        self.assertEqual(
            first,
            verify_migration_evidence(
                first,
                self.fixture.spec,
                self.fixture.paths,
                self.fixture.source_root,
            ),
        )

    def test_legacy_artifacts_are_byte_pinned(self):
        path = self.fixture.paths["legacy_baseline_280"]
        path.write_bytes(path.read_bytes() + b" ")

        self.assert_migration_error(
            "artifact_sha256",
            self.fixture.build,
        )

    def test_each_semantic_bridge_is_fail_closed(self):
        for role in ("original_baseline_20", "current_final_20"):
            with self.subTest(role=role):
                fixture = SemanticMigrationFixture(self.root / role)
                sample = fixture.payloads[role]["matches"][0][
                    "search_depth_samples_by_strategy"]["A"][0]
                sample["decision_semantic_hash"] = "0" * 64
                fixture.rewrite(role)

                self.assert_migration_error(
                    (
                        "original_baseline_to_candidate_semantics"
                        if role == "original_baseline_20"
                        else "current_final_to_candidate_semantics"
                    ),
                    fixture.build,
                )

    def test_candidate_280_trace_v0_mutation_fails(self):
        sample = self.fixture.payloads["final_candidate_280"]["matches"][0][
            "search_depth_samples_by_strategy"]["A"][0]
        sample["nodes_expanded"] += 1
        self.fixture.rewrite("final_candidate_280")

        self.assert_migration_error(
            "final_candidate_trace_v0",
            self.fixture.build,
        )

    def test_fixed_20_must_be_canonical_closed_subset(self):
        rows = self.fixture.payloads["current_final_20"]["matches"]
        rows[0] = copy.deepcopy(rows[1])
        self.fixture.rewrite("current_final_20")

        self.assert_migration_error(
            "fixed_20_schedule",
            self.fixture.build,
        )

    def test_source_attestation_cannot_be_self_declared(self):
        self.fixture.guard.write_text("changed rules\n", encoding="utf-8")

        self.assert_migration_error(
            "guard_file_hash",
            self.fixture.build,
        )

    def test_performance_thresholds_use_only_legacy_baseline_and_final(self):
        for row in self.fixture.payloads["final_candidate_280"]["matches"]:
            for strategy in ("A", "B"):
                for sample in row["search_depth_samples_by_strategy"][strategy]:
                    sample["planner_ms"] = 7.5001
        self.fixture.rewrite("final_candidate_280")

        self.assert_migration_error(
            "performance_planner_gate",
            self.fixture.build,
        )

    def test_performance_rejects_zero_duration_v2_sample(self):
        sample = self.fixture.payloads["final_candidate_280"]["matches"][0][
            "search_depth_samples_by_strategy"
        ]["A"][0]
        sample["planner_ms"] = 0.0
        self.fixture.rewrite("final_candidate_280")

        self.assert_migration_error(
            "performance_planner_samples",
            self.fixture.build,
        )

    def test_performance_rejects_nonpositive_candidate_median(self):
        baseline_costs = {
            "available": True,
            "reason": "",
            "median_ms_per_node": 0.01,
            "sample_count": 1,
        }
        candidate_costs = {
            "available": True,
            "reason": "",
            "median_ms_per_node": 0.0,
            "sample_count": 1,
        }
        with patch(
            f"{_validate_performance.__module__}._planner_costs",
            side_effect=(baseline_costs, candidate_costs),
        ):
            self.assert_migration_error(
                "performance_planner_median",
                lambda: _validate_performance(
                    self.fixture.spec,
                    self.fixture.artifact("legacy_baseline_280"),
                    self.fixture.artifact("legacy_candidate_280"),
                    self.fixture.artifact("final_candidate_280"),
                ),
            )

    def test_performance_requires_authoritative_wall_clock_fields(self):
        for role in ("legacy_baseline_280", "final_candidate_280"):
            with self.subTest(role=role):
                fixture = SemanticMigrationFixture(self.root / role)
                payload = fixture.payloads[role]
                payload["elapsed_ms"] = payload.pop("wall_clock_ms")
                fixture.rewrite(role)
                if role == "legacy_baseline_280":
                    fixture.spec["inputs"][role]["artifact_sha256"] = (
                        _sha256_file(fixture.paths[role])
                    )

                self.assert_migration_error(
                    "performance_wall_clock_authoritative",
                    fixture.build,
                )

    def test_performance_requires_candidate_full_evidence_scope(self):
        self.fixture.payloads["final_candidate_280"][
            "wall_clock_scope"
        ] = "current_attempt_only"

        self.assert_migration_error(
            "performance_candidate_wall_clock_scope",
            lambda: _validate_performance(
                self.fixture.spec,
                self.fixture.artifact("legacy_baseline_280"),
                self.fixture.artifact("legacy_candidate_280"),
                self.fixture.artifact("final_candidate_280"),
            ),
        )

    def test_evidence_tamper_is_detected(self):
        evidence = self.fixture.build()
        evidence["result"]["passed"] = False

        self.assert_migration_error(
            "evidence_migration_id",
            lambda: verify_migration_evidence(
                evidence,
                self.fixture.spec,
                self.fixture.paths,
                self.fixture.source_root,
            ),
        )

    def test_production_decision_contract_still_rejects_legacy_sample(self):
        row = self.fixture.payloads["legacy_baseline_280"]["matches"][0]

        self.assertEqual(
            "A:decision_semantic_hash",
            match_decision_contract_error(
                row,
                {"A": "turn_beam_v2", "B": "turn_beam_v2"},
                strict_v2_depth=True,
            ),
        )

    def test_production_spec_pins_the_reviewed_legacy_sha256(self):
        spec_path = (
            Path(__file__).resolve().parents[1]
            / "scripts"
            / "ai_evaluation_semantic_migration_spec.json"
        )
        spec = json.loads(spec_path.read_text(encoding="utf-8"))

        self.assertEqual(
            "49f04a5a5bb6b06d180cfdef4022f3712809dd56076089fdc2b3815ce111921e",
            spec["inputs"]["legacy_baseline_280"]["artifact_sha256"],
        )
        self.assertEqual(
            "32ff2c31fb988f8fc927bf064f34dfb5d6048053783368fe6bc4f4274297ebc9",
            spec["inputs"]["legacy_candidate_280"]["artifact_sha256"],
        )
        self.assertEqual(
            "7daf93d32c27ff71bf1f10c970314672637155c519f04a42edead2da01fabb5b",
            spec["inputs"]["original_baseline_20"]["artifact_sha256"],
        )
        self.assertNotIn("final_candidate_20", spec["inputs"])


if __name__ == "__main__":
    unittest.main()

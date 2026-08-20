from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from engine.ai.dl.release_evidence_v2 import (
    REQUIRED_INPUTS,
    build_release_evidence,
    finalize_release_evidence,
    validate_release_evidence_file,
)
from engine.ai.dl.run_store import atomic_write_json, read_json
from engine.ai.dl.v2_contract import RELEASE_DECKS
from scripts import promote_alphazero_v2 as promotion


def _zeroes(*names: str) -> dict[str, int]:
    return {name: 0 for name in names}


def _rules() -> dict:
    return {
        "schema": "native_action_transition_v2_audit/3",
        "scope_passed": True,
        "event_contract_status": "passed",
        "godot_replay_status": "passed",
        "release_gate_complete": True,
        "states_by_deck": {deck: 10_000 for deck in RELEASE_DECKS},
        **_zeroes(
            "legality_mismatches",
            "apply_mismatches",
            "state_mismatches",
            "rng_mismatches",
            "pending_shape_mismatches",
            "choice_apply_mismatches",
            "choice_state_mismatches",
            "choice_rng_mismatches",
            "choice_pending_shape_mismatches",
            "choice_mapping_errors",
            "choice_depth_exhaustions",
            "event_payload_mismatches",
            "trajectory_errors",
        ),
    }


def _infoset() -> dict:
    return {
        "schema": "native_infoset_security_v2_audit/1",
        "scope_passed": True,
        "godot_runtime_status": "passed",
        "release_gate_complete": True,
        "states_by_deck": {deck: 10_000 for deck in RELEASE_DECKS},
        **_zeroes(
            "unmasked_rejection_missing",
            "masked_boundary_errors",
            "masked_placeholder_errors",
            "mask_mismatches",
            "observation_mismatches",
            "hash_mismatches",
            "determinization_mismatches",
            "candidate_mismatches",
            "tensor_mismatches",
            "choice_reference_errors",
            "inventory_mismatches",
            "trajectory_errors",
        ),
    }


def _performance() -> dict:
    return {
        "schema": "native_vs_python_infoset_puct_benchmark/1",
        "same_seed_and_simulation_count": True,
        "throughput_speedup": 10.0,
    }


def _windows() -> dict:
    scenario = {
        "passed": True,
        "execution_provider": "CPUExecutionProvider",
    }
    return {
        "kind": "candidate_runtime_inference_v2",
        "passed": True,
        "platform": "windows",
        "native_extension": True,
        "encoder_golden_passed": True,
        "model_count": 1,
        "route_count": 10,
        "models": {
            deck: {
                "loaded": True,
                "hash_matches": True,
                "scenarios": [scenario, scenario],
            }
            for deck in RELEASE_DECKS
        },
        "search_deadline_passed": True,
        "minimum_simulations_passed": True,
        "fallback_path_passed": True,
        **_zeroes("illegal_actions", "timeouts", "degraded", "fallbacks"),
    }


def _android() -> dict:
    return {
        "schema": "alphazero_v2_android_runtime/1",
        "passed": True,
        "physical_device": True,
        "abi": "arm64-v8a",
        "native_bridge": False,
        "model_count": 1,
        "onnx_load_passed": True,
        "inference_passed": True,
        "search_deadline_passed": True,
        "minimum_simulations_passed": True,
        "fallback_path_passed": True,
        **_zeroes(
            "illegal_actions",
            "timeouts",
            "degraded",
            "fallbacks",
            "crashes",
        ),
    }


def _training() -> dict:
    return {
        "schema": "alphazero_v2_training_evidence/1",
        "trainer": "infoset_alphazero_v2",
        "accepted": True,
        "native_core_required": True,
        "native_core_available": True,
        "elapsed_seconds": 80_000.0,
        "wall_clock_budget_seconds": 86_400.0,
        "final_league": {
            "games": 6_000,
            "overall_score_rate": 0.53,
            "deck_score_rates": {
                deck: 0.50 for deck in RELEASE_DECKS
            },
            "structural_errors": 0,
            "truncated_games": 0,
            "native_inference": {
                "search_decisions": 1,
                "search_simulations": 128,
            },
        },
    }


class ReleaseEvidenceV2Tests(unittest.TestCase):
    def _fixture(self, root: Path):
        run = root / "run"
        run.mkdir()
        (run / "universal.pt").write_bytes(b"checkpoint")
        (run / "universal.json").write_text("{}", encoding="utf-8")
        onnx = (
            run
            / "release_staging"
            / "godot"
            / "data"
            / "ai_models"
            / "universal.onnx"
        )
        onnx.parent.mkdir(parents=True)
        onnx.write_bytes(b"onnx")
        runtime = onnx.parent.parent / "ai_models_runtime.json"
        release = onnx.parent.parent / "release_manifest.json"
        atomic_write_json(runtime, {"deep_planner": {"evidence_sha256": ""}})
        atomic_write_json(
            release,
            {
                "deep_planner": {"evidence_sha256": ""},
                "deep_runtime_enabled": False,
                "model_count": 0,
                "native_ai": {"production_ready": False},
                "deep_model": {"status": "candidate"},
            },
        )
        atomic_write_json(
            run / "run.json",
            {
                "run_id": "release-evidence-test",
                "status": "completed",
                "promotable": False,
            },
        )
        atomic_write_json(run / "release-evidence.json", _training())
        payloads = {
            "rules_parity": _rules(),
            "infoset_security": _infoset(),
            "performance": _performance(),
            "windows_runtime": _windows(),
            "android_runtime": _android(),
        }
        inputs = {}
        for name, payload in payloads.items():
            path = root / f"{name}.json"
            atomic_write_json(path, payload)
            inputs[name] = path
        return run, inputs

    @staticmethod
    def _ready_native() -> dict:
        return {
            "available": True,
            "abi_version": 2,
            "ready": True,
            "blockers": [],
        }

    def _promotion_fixture(self, root: Path):
        run = root / "run"
        repo = root / "repo"
        run.mkdir()
        evidence = run / "release-evidence.json"
        evidence.write_bytes(b"verified evidence")
        evidence_sha256 = promotion._sha256(evidence)
        atomic_write_json(
            run / "run.json",
            {
                "run_id": "promotion-test",
                "status": "completed",
                "promotable": True,
                "gate": {
                    "status": "passed",
                    "evidence_path": evidence.name,
                    "evidence_sha256": evidence_sha256,
                },
            },
        )

        source = run / "candidate"
        source.mkdir()
        checkpoint = source / "universal.pt"
        sidecar = source / "universal.json"
        onnx = source / "universal.onnx"
        runtime = source / "ai_models_runtime.json"
        checkpoint.write_bytes(b"checkpoint")
        sidecar.write_text("{}\n", encoding="utf-8")
        onnx.write_bytes(b"onnx")
        runtime_payload = {
            "format_version": 3,
            "deep_planner": {"evidence_sha256": evidence_sha256},
        }
        atomic_write_json(runtime, runtime_payload)

        disabled_release = {
            "format_version": 4,
            "deep_runtime_enabled": False,
            "model_count": 0,
            "native_ai": {"production_ready": False},
            "deep_model": {"status": "alphazero_v2_candidate_required"},
            "deep_planner": {"evidence_sha256": ""},
        }
        atomic_write_json(repo / "release_manifest.json", disabled_release)
        atomic_write_json(
            repo / "godot" / "data" / "release_manifest.json",
            disabled_release,
        )
        atomic_write_json(
            repo / "godot" / "data" / "ai_models_runtime.json",
            {"state": "disabled"},
        )
        bundle = (
            checkpoint,
            sidecar,
            onnx,
            runtime,
            runtime_payload,
        )
        return run, repo, evidence_sha256, bundle

    def test_promotion_atomically_enables_one_universal_model(self):
        with tempfile.TemporaryDirectory() as directory:
            run, repo, evidence_sha256, bundle = self._promotion_fixture(
                Path(directory)
            )
            with (
                patch.object(
                    promotion,
                    "validate_release_evidence_file",
                    return_value={"passed": True, "blockers": []},
                ),
                patch.object(
                    promotion,
                    "_validate_bundle",
                    return_value=bundle,
                ),
            ):
                journal = promotion.promote(
                    run,
                    evidence_sha256=evidence_sha256,
                    confirm_run_id="promotion-test",
                    repo_root=repo,
                )

            root_release = read_json(repo / "release_manifest.json")
            godot_release = read_json(
                repo / "godot" / "data" / "release_manifest.json"
            )
            self.assertEqual(journal["state"], "committed")
            self.assertEqual(root_release, godot_release)
            self.assertTrue(root_release["deep_runtime_enabled"])
            self.assertEqual(root_release["model_count"], 1)
            self.assertEqual(
                root_release["deep_planner"]["evidence_sha256"],
                evidence_sha256,
            )
            self.assertEqual(
                (repo / "python" / "data" / "ai_models" / "universal.pt")
                .read_bytes(),
                b"checkpoint",
            )
            self.assertEqual(read_json(run / "run.json")["status"], "promoted")

    def test_promotion_failure_rolls_back_the_disabled_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            run, repo, evidence_sha256, bundle = self._promotion_fixture(
                Path(directory)
            )
            failed_target = (
                repo / "godot" / "data" / "release_manifest.json"
            ).resolve()
            real_replace = promotion.os.replace

            def fail_final_manifest(source, target):
                if Path(target).resolve() == failed_target:
                    raise OSError("injected final manifest failure")
                return real_replace(source, target)

            with (
                patch.object(
                    promotion,
                    "validate_release_evidence_file",
                    return_value={"passed": True, "blockers": []},
                ),
                patch.object(
                    promotion,
                    "_validate_bundle",
                    return_value=bundle,
                ),
                patch.object(promotion.os, "replace", fail_final_manifest),
                self.assertRaisesRegex(OSError, "injected final manifest failure"),
            ):
                promotion.promote(
                    run,
                    evidence_sha256=evidence_sha256,
                    confirm_run_id="promotion-test",
                    repo_root=repo,
                )

            root_release = read_json(repo / "release_manifest.json")
            godot_release = read_json(
                repo / "godot" / "data" / "release_manifest.json"
            )
            self.assertEqual(root_release, godot_release)
            self.assertFalse(root_release["deep_runtime_enabled"])
            self.assertEqual(root_release["model_count"], 0)
            self.assertEqual(
                read_json(
                    repo / "godot" / "data" / "ai_models_runtime.json"
                ),
                {"state": "disabled"},
            )
            self.assertFalse(
                (repo / "python" / "data" / "ai_models" / "universal.pt")
                .exists()
            )
            journals = list(
                (run / "staging" / "promotion_transactions").glob(
                    "*/journal.json"
                )
            )
            self.assertEqual(len(journals), 1)
            self.assertEqual(read_json(journals[0])["state"], "rolled_back")

    def test_complete_bundle_passes_and_enables_only_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            run, inputs = self._fixture(Path(directory))
            result = finalize_release_evidence(
                run,
                inputs=inputs,
                native_status=self._ready_native(),
            )
            self.assertTrue(result["passed"], result)
            evidence = Path(result["evidence_path"])
            self.assertTrue(evidence.is_file())
            runtime = read_json(
                run
                / "release_staging"
                / "godot"
                / "data"
                / "ai_models_runtime.json"
            )
            release = read_json(
                run
                / "release_staging"
                / "godot"
                / "data"
                / "release_manifest.json"
            )
            self.assertEqual(
                runtime["deep_planner"]["evidence_sha256"],
                result["evidence_sha256"],
            )
            self.assertTrue(release["deep_runtime_enabled"])
            self.assertEqual(release["model_count"], 1)
            self.assertTrue(read_json(run / "run.json")["promotable"])

    def test_tampered_input_invalidates_recorded_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            run, inputs = self._fixture(Path(directory))
            evidence, gate, _digest = build_release_evidence(
                run,
                inputs=inputs,
                native_status=self._ready_native(),
            )
            self.assertTrue(gate["passed"], gate)
            copied = (
                run / "evidence" / "release_inputs" / "performance.json"
            )
            copied.write_text('{"throughput_speedup": 999}\n', encoding="utf-8")
            validated = validate_release_evidence_file(
                evidence,
                run_dir=run,
                native_status=self._ready_native(),
            )
            self.assertFalse(validated["passed"])
            self.assertIn(
                "performance.sha256",
                validated["blockers"],
            )
            self.assertIn(
                "evidence.recorded_gate_mismatch",
                validated["blockers"],
            )

    def test_pr_scale_or_unready_native_remains_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            run, inputs = self._fixture(Path(directory))
            rules = read_json(inputs["rules_parity"])
            rules["release_gate_complete"] = False
            rules["states_by_deck"]["fire"] = 9_999
            atomic_write_json(inputs["rules_parity"], rules)
            result = finalize_release_evidence(
                run,
                inputs=inputs,
                native_status={
                    "available": True,
                    "abi_version": 2,
                    "ready": False,
                    "blockers": ["compact_apply_undo_kernel_not_integrated"],
                },
            )
            self.assertFalse(result["passed"])
            self.assertIn(
                "rules_parity.release_scale",
                result["blockers"],
            )
            self.assertIn(
                "rules_parity.deck_fire_coverage",
                result["blockers"],
            )
            self.assertIn("native.ready", result["blockers"])
            run_payload = read_json(run / "run.json")
            self.assertFalse(run_payload["promotable"])
            release = read_json(
                run
                / "release_staging"
                / "godot"
                / "data"
                / "release_manifest.json"
            )
            self.assertFalse(release["deep_runtime_enabled"])

    def test_exact_external_input_set_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            run, inputs = self._fixture(Path(directory))
            inputs.pop(REQUIRED_INPUTS[0])
            with self.assertRaisesRegex(
                ValueError,
                "release_evidence_input_set",
            ):
                build_release_evidence(
                    run,
                    inputs=inputs,
                    native_status=self._ready_native(),
                )


if __name__ == "__main__":
    unittest.main()

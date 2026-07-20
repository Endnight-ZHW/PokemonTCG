from __future__ import annotations

import tempfile
import unittest
from unittest import mock
from pathlib import Path

from engine.actions import ACTION_SCHEMA_VERSION

from engine.ai.dl.rules_migration import (
    canonical_payload_sha256,
    evidence_gate_errors,
    migrated_checkpoint_payload,
    rules_source_fingerprint,
    runtime_contract_errors,
    validate_release_evidence_set,
)


def _result(points: list[float]) -> dict:
    wins = sum(1 for value in points if value == 1.0)
    draws = sum(1 for value in points if value == 0.5)
    return {
        "games": len(points),
        "wins": wins,
        "losses": len(points) - wins - draws,
        "draws": draws,
        "game_points": points,
        "invalid_action_rate": 0.0,
        "no_target_action_rate": 0.0,
        "rule_exception_rate": 0.0,
        "decision_timeout_rate": 0.0,
        "max_step_exhaustion_rate": 0.0,
    }


def _evidence(deck: str = "fire", model_hash: str = "abc") -> dict:
    candidate = _result([1.0, 0.0])
    baseline = _result([1.0, 0.0])
    return {
        "format_version": 1,
        "deck": deck,
        "model_sha256": model_hash,
        "migration": {"source_rules_version": 2, "target_rules_version": 3},
        "rules_source": {"sha256": "rules"},
        "candidate": candidate,
        "challenge_baseline": baseline,
        "paired_delta_point_rate": 0.0,
        "accepted": True,
        "release_eligible": True,
    }


class RulesMigrationEvidenceTests(unittest.TestCase):
    def test_canonical_payload_hash_is_order_independent(self):
        self.assertEqual(
            canonical_payload_sha256({"b": [2, 1], "a": 3}),
            canonical_payload_sha256({"a": 3, "b": [2, 1]}),
        )
        self.assertNotEqual(
            canonical_payload_sha256({"a": 3}),
            canonical_payload_sha256({"a": 4}),
        )

    def test_schema_label_does_not_change_semantic_fingerprint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "engine").mkdir()
            (root / "data").mkdir()
            actions = root / "engine" / "actions.py"
            actions.write_text(
                "ACTION_SCHEMA_VERSION = 2\nRULES_SCHEMA_VERSION = 2\nVALUE = 7\n",
                encoding="utf-8",
            )
            for name in (
                "card_models.py",
                "card_registry.py",
                "deck_definitions.py",
                "ai_policies.json",
            ):
                (root / "data" / name).write_text("{}\n", encoding="utf-8")
            before = rules_source_fingerprint(root)["sha256"]
            actions.write_text(
                "ACTION_SCHEMA_VERSION = 3\nRULES_SCHEMA_VERSION = 3\nVALUE = 7\n",
                encoding="utf-8",
            )
            after = rules_source_fingerprint(root)["sha256"]
            self.assertEqual(before, after)
            actions.write_text(
                "ACTION_SCHEMA_VERSION = 3\nRULES_SCHEMA_VERSION = 3\nVALUE = 8\n",
                encoding="utf-8",
            )
            self.assertNotEqual(before, rules_source_fingerprint(root)["sha256"])

    def test_runtime_contract_accepts_cuda_build_suffix_only(self):
        actual = {
            "python": "3.11.15",
            "implementation": "CPython",
            "numpy": "1.26.4",
            "torch": "2.4.1+cu118",
            "cuda_version": "11.8",
            "onnx": "1.22.0",
            "onnxruntime": "1.26.0",
            "cuda_available": True,
        }
        expected = {
            "python": "3.11.15",
            "numpy": "1.26.4",
            "torch": "2.4.1",
            "cuda": "11.8",
            "onnx": "1.22.0",
            "onnxruntime": "1.26.0",
        }
        self.assertEqual(runtime_contract_errors(actual, expected, require_cuda=True), [])
        actual["numpy"] = "1.25.2"
        actual["cuda_available"] = False
        actual["cuda_version"] = "12.1"
        errors = runtime_contract_errors(actual, expected, require_cuda=True)
        self.assertTrue(any(error.startswith("numpy:") for error in errors))
        self.assertIn("cuda:required", errors)
        self.assertTrue(any(error.startswith("cuda_version:") for error in errors))

    def test_valid_paired_evidence_passes_pure_gate(self):
        self.assertEqual(
            evidence_gate_errors(
                _evidence(),
                deck_key="fire",
                model_sha256="abc",
                target_rules_version=3,
                rules_fingerprint="rules",
                min_games=2,
            ),
            [],
        )

    def test_gate_rejects_hash_environment_and_incomplete_points(self):
        evidence = _evidence()
        evidence["release_eligible"] = False
        evidence["candidate"]["game_points"] = [1.0]
        errors = evidence_gate_errors(
            evidence,
            deck_key="fire",
            model_sha256="different",
            target_rules_version=3,
            rules_fingerprint="rules",
            min_games=2,
        )
        self.assertIn("model_sha256", errors)
        self.assertIn("release_environment", errors)
        self.assertIn("paired_game_points", errors)

    def test_release_set_requires_exactly_one_artifact_per_deck(self):
        errors = validate_release_evidence_set(
            [_evidence(), _evidence()],
            release_decks=["fire", "water"],
            model_hashes={"fire": "abc", "water": "def"},
            target_rules_version=3,
            rules_fingerprint="rules",
            min_games=2,
        )
        self.assertIn("duplicate_evidence", errors["fire"])
        self.assertEqual(errors["water"], ["missing_evidence"])

    def test_checkpoint_migration_is_copy_only_and_replaces_eval_evidence(self):
        source = {
            "schema": {"rules_version": 2, "action_version": 2},
            "metadata": {
                "deck": "fire",
                "rules_version": 2,
                "summary": {"fire": {"eval": {"games": 600, "wins": 1}}},
            },
            "model_state": {"weight": "unchanged"},
        }
        evidence = _evidence()
        evidence["evaluation"] = {"seed": 900017, "use_mcts": True, "mcts_simulations": 64}
        evidence["completed_at"] = 123
        migrated = migrated_checkpoint_payload(
            source,
            evidence,
            deck_key="fire",
            target_rules_version=3,
            evidence_sha256="evidence",
        )
        self.assertEqual(source["schema"]["rules_version"], 2)
        self.assertEqual(migrated["schema"]["rules_version"], 3)
        self.assertEqual(migrated["metadata"]["rules_version"], 3)
        self.assertEqual(migrated["model_state"], source["model_state"])
        row = migrated["metadata"]["summary"]["fire"]
        self.assertEqual(row["eval"], evidence["candidate"])
        self.assertEqual(row["eval_seed"], 900017)
        self.assertEqual(row["rules_migration_evidence_sha256"], "evidence")

    def test_evaluator_reuses_only_matching_completed_run_identity(self):
        from scripts import evaluate_rules_migration as evaluator

        result = _result([1.0, 0.0])
        checkpoint = {"version": 10}
        metadata = {"deck": "fire", "seed": 17, "summary": {"fire": {"eval_seed": 900017}}}
        schema = {
            "rules_version": 2,
            "action_version": ACTION_SCHEMA_VERSION,
        }
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            evaluator,
            "_load_source",
            return_value=(object(), checkpoint, metadata, schema, "model-hash"),
        ), mock.patch.object(
            evaluator,
            "evaluate_challenge_baseline",
            return_value=result,
        ) as baseline_mock, mock.patch.object(
            evaluator,
            "evaluate_model",
            return_value=result,
        ) as model_mock:
            kwargs = {
                "deck": "fire",
                "model_dir": Path(temporary),
                "output_dir": Path(temporary),
                "source_rules_version": 2,
                "target_rules_version": 3,
                "games": 2,
                "seed": None,
                "workers": 1,
                "max_steps": 20,
                "device": "cpu",
                "teacher_search_preset": "fast",
                "use_mcts": False,
                "mcts_simulations": 1,
                "rules_source": {"sha256": "rules", "files": []},
                "environment": {"python": "3.11.15"},
                "expected_environment": {"python": "3.11.15"},
                "environment_errors": [],
                "allow_unpinned_environment": False,
                "min_point_rate": 0.5,
                "min_delta_point_rate": -0.01,
                "max_step_exhaustion_rate": 0.05,
                "resume": True,
            }
            first, first_reused = evaluator.evaluate_deck(**kwargs)
            second, second_reused = evaluator.evaluate_deck(**kwargs)

            self.assertFalse(first_reused)
            self.assertTrue(second_reused)
            self.assertEqual(first["run_identity_sha256"], second["run_identity_sha256"])
            self.assertEqual(baseline_mock.call_count, 1)
            self.assertEqual(model_mock.call_count, 1)

            kwargs["max_steps"] = 21
            _third, third_reused = evaluator.evaluate_deck(**kwargs)
            self.assertFalse(third_reused)
            self.assertEqual(baseline_mock.call_count, 2)
            self.assertEqual(model_mock.call_count, 2)


if __name__ == "__main__":
    unittest.main()

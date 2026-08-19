import copy
import os
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.ai_evaluation_v7 import (
    DECK_ORDER,
    PROTOCOL_ID,
    _merge_matches,
    expected_match_identities,
    experimental_units,
    match_decision_contract_error,
    summarize_coverage,
)
from scripts.build_ai_evaluation_provenance import build_provenance
from scripts.validate_ai_evaluation import (
    _coverage_valid,
    _main_depth_contract_valid,
)


def _search_sample(*, reason: str = "depth_complete") -> dict:
    completed = 8 if reason == "depth_complete" else 4
    return {
        "requested": 8,
        "reached": completed,
        "completed": completed,
        "max_path_depth": completed,
        "reply_requested": 3,
        "reply_completed": 3,
        "reply_applicable": True,
        "reply_completion_reason": "depth_complete",
        "layers_completed": completed,
        "completion_reason": reason,
        "stop_reason": reason,
        "engine_id": "turn_beam_v2",
        "nodes_expanded": 64,
        "planner_ms": 1.0,
        "trajectory_hash": "a" * 64,
        "decision_semantic_hash": "c" * 64,
    }


def _decision_row() -> dict:
    return {
        "decisions": 2,
        "choices": 1,
        "decision_ms_samples": [1.0, 2.0, 3.0],
        "decision_ms_samples_by_strategy": {
            "A": [1.0, 2.0],
            "B": [3.0],
        },
        "action_decisions_by_strategy": {"A": 1, "B": 1},
        "search_depth_decision_counts_by_strategy": {
            "A": {"applicable": 1, "not_applicable": 0, "reasons": {}},
            "B": {"applicable": 1, "not_applicable": 0, "reasons": {}},
        },
        "search_depth_samples_by_strategy": {
            "A": [_search_sample()],
            "B": [{**_search_sample(), "trajectory_hash": "b" * 64}],
        },
    }


def _deep_decision_row() -> dict:
    row = _decision_row()
    row.update({
        "matchup_kind": "mirror",
        "strategy_a_deck": "fire",
        "strategy_b_deck": "fire",
        "seed_block": 0,
        "seed": 17,
        "seat": 0,
        "strategy_a_player": 0,
        "forced_first_player": 0,
        "sample_phase": "main",
        "winner": "draw",
        "turn_plan_cache_hit_samples_by_strategy": {
            "A": [False, False],
            "B": [False],
        },
        "ai_turn_ms_samples_by_strategy": {
            "A": [3.0],
            "B": [3.0],
        },
        "behavior_by_strategy": {
            strategy: {
                "selected_action_counts": {},
                "legal_action_opportunity_counts": {},
                "choice_request_counts": {},
            }
            for strategy in ("A", "B")
        },
        "decision_engine_counts_by_strategy": {
            "A": {"infoset_puct_v2": 1},
            "B": {"turn_beam_v2": 1},
        },
    })
    row["search_depth_decision_counts_by_strategy"]["A"] = {
        "applicable": 0,
        "not_applicable": 1,
        "reasons": {"search_complete": 1},
    }
    row["search_depth_samples_by_strategy"]["A"] = []
    return row


def _nightly_config() -> dict:
    return {
        "seed": 17,
        "seed_blocks_per_deck": 50,
        "cross_seed_blocks_per_matchup": 10,
        "seed_block_start": 0,
        "seed_block_count": 50,
        "task_start": 0,
        "task_count": 0,
        "task_shard_count": 1,
        "matchup_mode": "Balanced",
    }


def _coverage_row(identity: tuple[str, str, str, int, int, int]) -> dict:
    kind, deck_a, deck_b, block, seed, seat = identity
    strategy_a_player = seat
    forced_first = block % 2
    return {
        "deck": deck_a,
        "strategy_a_deck": deck_a,
        "strategy_b_deck": deck_b,
        "matchup_kind": kind,
        "seed_block": block,
        "seed": seed,
        "seat": seat,
        "strategy_a_player": strategy_a_player,
        "forced_first_player": forced_first,
        "strategy_a_first": strategy_a_player == forced_first,
        "player_decks": (
            [deck_a, deck_b]
            if strategy_a_player == 0
            else [deck_b, deck_a]
        ),
        "winner": "draw",
        "terminal_reason": "game_over",
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "max_actions_exhausted": False,
        "task_shard_index": 0,
        "task_shard_count": 1,
    }


class NativeSimulationFingerprintTests(unittest.TestCase):
    def test_native_sources_descriptor_and_target_binaries_are_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            native_source = (
                root
                / "godot"
                / "native"
                / "onnx_ai"
                / "src"
                / "challenge_ai_math.cpp"
            )
            descriptor = root / "godot" / "bin" / "pokemon_ai.gdextension"
            windows_binary = (
                root
                / "godot"
                / "bin"
                / "windows"
                / "libpokemon_ai.windows.template_debug.x86_64.dll"
            )
            android_binary = (
                root
                / "godot"
                / "bin"
                / "android"
                / "libpokemon_ai.android.template_debug.arm64.so"
            )
            godot_executable = root / "toolchain" / "godot-console.exe"
            orchestration = root / "tools" / "evaluate_godot_ai.ps1"
            workflow = root / ".github" / "workflows" / "verify.yml"
            validator = (
                root / "python" / "scripts" / "validate_ai_evaluation.py"
            )
            for path, content in (
                (native_source, b"native-v1"),
                (descriptor, b"[configuration]\n"),
                (windows_binary, b"windows-v1"),
                (android_binary, b"android-v1"),
                (godot_executable, b"godot-runtime-v1"),
                (orchestration, b"# scheduler-v1\n"),
                (workflow, b"# ci-topology-v1\n"),
                (validator, b"# validator-v1\n"),
            ):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            first = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertEqual(
                first["godot_executable_sha256"],
                "a9297c0c5bf9f4d96340f6acb04fb76788ace5a71b7800"
                "699579ed47797debdc",
            )
            source_files = set(first["source_files"])
            self.assertIn(
                "godot/native/onnx_ai/src/challenge_ai_math.cpp",
                source_files,
            )
            self.assertIn("godot/bin/pokemon_ai.gdextension", source_files)
            self.assertIn("tools/evaluate_godot_ai.ps1", source_files)
            self.assertIn(".github/workflows/verify.yml", source_files)
            self.assertIn(
                "godot/bin/windows/"
                "libpokemon_ai.windows.template_debug.x86_64.dll",
                source_files,
            )
            self.assertNotIn(
                "godot/bin/android/"
                "libpokemon_ai.android.template_debug.arm64.so",
                source_files,
            )

            orchestration.write_bytes(b"# scheduler-v2\n")
            scheduler_changed = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertNotEqual(
                first["simulation_fingerprint"],
                scheduler_changed["simulation_fingerprint"],
            )
            self.assertEqual(
                first["analysis_fingerprint"],
                scheduler_changed["analysis_fingerprint"],
            )
            self.assertNotEqual(
                first["component_hashes"]["evaluation_tool"],
                scheduler_changed["component_hashes"]["evaluation_tool"],
            )

            workflow.write_bytes(b"# ci-topology-v2\n")
            ci_changed = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertNotEqual(
                scheduler_changed["simulation_fingerprint"],
                ci_changed["simulation_fingerprint"],
            )
            self.assertEqual(
                scheduler_changed["analysis_fingerprint"],
                ci_changed["analysis_fingerprint"],
            )

            validator.write_bytes(b"# validator-v2\n")
            analysis_changed = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertEqual(
                ci_changed["simulation_fingerprint"],
                analysis_changed["simulation_fingerprint"],
            )
            self.assertNotEqual(
                ci_changed["analysis_fingerprint"],
                analysis_changed["analysis_fingerprint"],
            )
            self.assertEqual(
                ci_changed["component_hashes"]["evaluation_tool"],
                analysis_changed["component_hashes"]["evaluation_tool"],
            )
            self.assertNotEqual(
                ci_changed["component_hashes"]["analysis_tool"],
                analysis_changed["component_hashes"]["analysis_tool"],
            )

            native_source.write_bytes(b"native-v2")
            native_changed = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertNotEqual(
                first["simulation_fingerprint"],
                native_changed["simulation_fingerprint"],
            )
            self.assertEqual(
                analysis_changed["analysis_fingerprint"],
                native_changed["analysis_fingerprint"],
            )

            windows_binary.write_bytes(b"windows-v2")
            binary_changed = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertNotEqual(
                native_changed["simulation_fingerprint"],
                binary_changed["simulation_fingerprint"],
            )

            godot_executable.write_bytes(b"godot-runtime-v2")
            runtime_changed = build_provenance(
                root,
                [],
                godot_executable=godot_executable,
                target_platform="windows",
            )
            self.assertNotEqual(
                binary_changed["simulation_fingerprint"],
                runtime_changed["simulation_fingerprint"],
            )


class DecisionAndDepthContractTests(unittest.TestCase):
    def setUp(self):
        self.engines = {"A": "turn_beam_v2", "B": "turn_beam_v2"}

    def test_valid_depth_and_decision_accounting_contract(self):
        row = _decision_row()
        self.assertIsNone(match_decision_contract_error(
            row,
            self.engines,
            strict_v2_depth=True,
        ))
        self.assertTrue(_main_depth_contract_valid({
            "matches": [row],
            "strategies": {
                "A": {"engine": "turn_beam_v2"},
                "B": {"engine": "turn_beam_v2"},
            },
        }))

    def test_action_and_choice_timing_conservation_fail_closed(self):
        action_mismatch = _decision_row()
        action_mismatch["action_decisions_by_strategy"]["A"] = 0
        self.assertEqual(
            match_decision_contract_error(
                action_mismatch,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:search_counts",
        )

        timing_mismatch = _decision_row()
        timing_mismatch["decision_ms_samples"].pop()
        self.assertEqual(
            match_decision_contract_error(
                timing_mismatch,
                self.engines,
                strict_v2_depth=True,
            ),
            "timing_choice_total",
        )

    def test_fixed_depth_and_completion_semantics_fail_closed(self):
        cases = {}

        requested_nine = _decision_row()
        sample = requested_nine["search_depth_samples_by_strategy"]["A"][0]
        for field in (
            "requested",
            "reached",
            "completed",
            "max_path_depth",
            "layers_completed",
        ):
            sample[field] = 9
        cases["requested_nine"] = requested_nine

        invalid_frontier = _decision_row()
        sample = invalid_frontier["search_depth_samples_by_strategy"]["A"][0]
        sample["completion_reason"] = "frontier_exhausted"
        sample["stop_reason"] = "frontier_exhausted"
        cases["frontier_at_target"] = invalid_frontier

        stop_mismatch = _decision_row()
        stop_mismatch["search_depth_samples_by_strategy"]["A"][0][
            "stop_reason"
        ] = "cancelled"
        cases["stop_reason_mismatch"] = stop_mismatch

        for label, row in cases.items():
            with self.subTest(label=label):
                self.assertIsNotNone(
                    match_decision_contract_error(
                        row,
                        self.engines,
                        strict_v2_depth=True,
                    )
                )
                self.assertFalse(_main_depth_contract_valid({
                    "matches": [row],
                    "strategies": {
                        "A": {"engine": "turn_beam_v2"},
                        "B": {"engine": "turn_beam_v2"},
                    },
                }))

    def test_reached_depth_must_equal_maximum_path_depth(self):
        row = _decision_row()
        row["search_depth_samples_by_strategy"]["A"][0][
            "max_path_depth"
        ] = 7

        self.assertEqual(
            match_decision_contract_error(
                row,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:max_path_depth",
        )
        self.assertFalse(_main_depth_contract_valid({
            "matches": [row],
            "strategies": {
                "A": {"engine": "turn_beam_v2"},
                "B": {"engine": "turn_beam_v2"},
            },
        }))

    def test_information_set_puct_decisions_are_not_misclassified_as_beam_depth(self):
        row = _deep_decision_row()
        modes = {"A": "deep", "B": "challenge"}
        self.assertIsNone(match_decision_contract_error(
            row,
            self.engines,
            configured_modes=modes,
            strict_v2_depth=True,
        ))
        self.assertTrue(_main_depth_contract_valid({
            "matches": [row],
            "strategies": {
                "A": {"engine": "turn_beam_v2", "mode": "deep"},
                "B": {"engine": "turn_beam_v2", "mode": "challenge"},
            },
        }))
        merged = _merge_matches([{
            "strategies": {
                "A": {"engine": "turn_beam_v2", "mode": "deep"},
                "B": {"engine": "turn_beam_v2", "mode": "challenge"},
            },
            "matches": [row],
            "config": {},
        }])
        self.assertEqual(len(merged), 1)

        invalid_engine = copy.deepcopy(row)
        invalid_engine["decision_engine_counts_by_strategy"]["A"] = {
            "turn_beam_v1": 1,
        }
        self.assertEqual(
            match_decision_contract_error(
                invalid_engine,
                self.engines,
                configured_modes=modes,
            ),
            "A:decision_engine_counts",
        )

        invalid_reason = copy.deepcopy(row)
        invalid_reason["search_depth_decision_counts_by_strategy"]["A"][
            "reasons"
        ] = {"unknown": 1}
        self.assertEqual(
            match_decision_contract_error(
                invalid_reason,
                self.engines,
                configured_modes=modes,
            ),
            "A:not_applicable_reason",
        )

    def test_v2_reply_depth_non_applicable_and_node_contracts(self):
        wrong_reply_depth = _decision_row()
        wrong_reply_depth["search_depth_samples_by_strategy"]["A"][0][
            "reply_requested"
        ] = 2
        wrong_reply_depth["search_depth_samples_by_strategy"]["A"][0][
            "reply_completed"
        ] = 2
        self.assertEqual(
            match_decision_contract_error(
                wrong_reply_depth,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:v2_reply_requested_depth",
        )

        non_applicable = _decision_row()
        sample = non_applicable["search_depth_samples_by_strategy"]["A"][0]
        sample.update({
            "reply_applicable": False,
            "reply_completed": 0,
            "reply_completion_reason": "not_applicable",
        })
        self.assertIsNone(match_decision_contract_error(
            non_applicable,
            self.engines,
            strict_v2_depth=True,
        ))
        sample["reply_completion_reason"] = "depth_complete"
        self.assertEqual(
            match_decision_contract_error(
                non_applicable,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:reply_depth",
        )

        no_nodes = _decision_row()
        no_nodes["search_depth_samples_by_strategy"]["A"][0][
            "nodes_expanded"
        ] = 0
        self.assertEqual(
            match_decision_contract_error(
                no_nodes,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:v2_nodes_expanded",
        )

        missing_semantics = _decision_row()
        missing_semantics["search_depth_samples_by_strategy"]["A"][0].pop(
            "decision_semantic_hash"
        )
        self.assertEqual(
            match_decision_contract_error(
                missing_semantics,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:decision_semantic_hash",
        )

        malformed_semantics = _decision_row()
        malformed_semantics["search_depth_samples_by_strategy"]["A"][0][
            "decision_semantic_hash"
        ] = "not-a-sha256"
        self.assertEqual(
            match_decision_contract_error(
                malformed_semantics,
                self.engines,
                strict_v2_depth=True,
            ),
            "A:decision_semantic_hash",
        )


class MainMatrixCoverageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = _nightly_config()
        cls.matches = [
            _coverage_row(identity)
            for identity in sorted(
                expected_match_identities(DECK_ORDER, cls.config)
            )
        ]
        mirror_units, cross_units = experimental_units(cls.matches)
        cls.coverage = summarize_coverage(
            cls.matches,
            DECK_ORDER,
            cls.config,
            mirror_units,
            cross_units,
        )

    def _payload(self, matches=None, coverage=None):
        return {
            "schema_version": 7,
            "protocol_id": PROTOCOL_ID,
            "deck_keys": list(DECK_ORDER),
            "config": dict(self.config),
            "matches": list(self.matches if matches is None else matches),
            "coverage": copy.deepcopy(
                self.coverage if coverage is None else coverage
            ),
        }

    def test_exact_2800_game_500_plus_450_unit_matrix_is_accepted(self):
        self.assertEqual(len(self.matches), 2800)
        self.assertEqual(self.coverage["complete_mirror_units"], 500)
        self.assertEqual(self.coverage["complete_cross_units"], 450)
        self.assertTrue(
            _coverage_valid(self._payload(), canonical_nightly=True)
        )

    def test_truncated_or_identity_tampered_matches_reject_stale_coverage(self):
        self.assertFalse(_coverage_valid(
            self._payload(matches=self.matches[:-1]),
            canonical_nightly=True,
        ))

        tampered = list(self.matches)
        tampered[0] = dict(tampered[0])
        tampered[0]["seed"] += 1
        self.assertFalse(_coverage_valid(
            self._payload(matches=tampered),
            canonical_nightly=True,
        ))


if __name__ == "__main__":
    unittest.main()

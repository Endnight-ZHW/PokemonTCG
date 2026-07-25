import copy
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.ai_evaluation_v7 import (
    BOOTSTRAP_ITERATIONS,
    DECK_ORDER,
    MergeError,
    PROTOCOL_ID,
    complete_evidence_unit_ids,
    evidence_unit_ids_sha256,
    expected_match_identities,
    experimental_units,
    merge_payloads,
    summarize_behavior,
    summarize_coverage,
    summarize_observed,
    summarize_performance,
    summarize_search_depth,
    summarize_strength,
    task_manifest_id,
)
from scripts.compare_ai_evaluation_profiles import compare_profiles, evaluate_gates
from scripts.build_ai_evaluation_provenance import (
    build_provenance,
    current_analysis_fingerprint,
)
from scripts.ai_evaluation_v7 import simulation_fingerprint_from_provenance
from scripts.render_ai_evaluation_report import (
    evaluation_verdict,
    render_file,
    render_report,
)
from scripts.summarize_ai_evaluation_profile import summarize_profile
from scripts.validate_ai_evaluation import validate_evaluation_gate
from tests.temp_utils import temp_dir


RULES = {"apply_type_matchups": False}
REPO_ROOT = Path(__file__).parents[2]
CURRENT_ANALYSIS_FINGERPRINT = current_analysis_fingerprint(REPO_ROOT)
PROVENANCE = {
    "schema_version": 7,
    "protocol_id": PROTOCOL_ID,
    "fingerprint": "c" * 64,
    "analysis_fingerprint": CURRENT_ANALYSIS_FINGERPRINT,
    "godot_executable_sha256": "f" * 64,
    "simulation_source_hash": "1" * 64,
    "release_manifest_sha256": "2" * 64,
    "toolchain_lock_sha256": "3" * 64,
    "strategy_file_sha256": {},
    "product_version": "0.6.0",
    "release_ai_evaluation_schema": 7,
    "release_godot_version": "4.7",
    "toolchain_godot_version": "4.7",
    "godot_runtime_version": "4.7.stable.official.test",
    "target_platform": "windows",
    "simulation_config": {},
    "source_hash": "abc123",
}
PROVENANCE["simulation_fingerprint"] = (
    simulation_fingerprint_from_provenance(PROVENANCE)
)


def _behavior(a_kind="PLAY_BASIC", b_kind="END_TURN"):
    return {
        "A": {
            "selected_action_counts": {a_kind: 1},
            "legal_action_opportunity_counts": {a_kind: 1, "END_TURN": 1},
            "choice_request_counts": {"select_prize": 1},
        },
        "B": {
            "selected_action_counts": {b_kind: 1},
            "legal_action_opportunity_counts": {"PLAY_BASIC": 1, b_kind: 1},
            "choice_request_counts": {"select_attachment": 1},
        },
    }


def _config(
    decks=("fire", "water"),
    *,
    seed_blocks=1,
    cross_blocks=1,
    mode="Balanced",
    run_role="main",
    warmup=0,
    profile=True,
):
    del decks
    return {
        "seed": 17,
        "seed_blocks_per_deck": seed_blocks,
        "cross_seed_blocks_per_matchup": cross_blocks,
        "seed_block_start": 0,
        "seed_block_count": seed_blocks,
        "task_start": 0,
        "task_count": 0,
        "task_shard_index": 0,
        "task_shard_count": 1,
        "max_actions": 1200,
        "eval_preset": "Custom",
        "matchup_mode": mode,
        "profile": profile,
        "disable_ai_cache": False,
        "disable_native_math": False,
        "rules_options": RULES,
        "decision_latency_sampling": "per_decision",
        "ai_turn_latency_sampling": "completed_turn_wall_clock",
        "platform": "windows",
        "run_role": run_role,
        "warmup_blocks_per_deck": warmup,
    }


def _row(identity, winner="draw", *, sample_phase="main"):
    kind, deck_a, deck_b, block, seed, seat = identity
    a_player = seat
    player_decks = [deck_a, deck_b] if a_player == 0 else [deck_b, deck_a]
    engine_winner = a_player if winner == "A" else (1 - a_player if winner == "B" else -1)
    return {
        "deck": deck_a,
        "strategy_a_deck": deck_a,
        "strategy_b_deck": deck_b,
        "player_decks": player_decks,
        "matchup_kind": kind,
        "matchup_key": f"{deck_a}_vs_{deck_b}",
        "pair_key": f"{deck_a}:{deck_b}:{block}:{seed}",
        "role_crossover_block_key": (
            f"{'_and_'.join(sorted((deck_a, deck_b)))}:{block}:{seed}"
            if kind == "cross"
            else ""
        ),
        "sample_phase": sample_phase,
        "seed": seed,
        "seed_block": block,
        "seat": seat,
        "strategy_a_player": a_player,
        "forced_first_player": block % 2,
        "strategy_a_first": a_player == block % 2,
        "winner": winner,
        "engine_winner": engine_winner,
        "terminal_reason": "game_over",
        "terminal_message": "",
        "actions": 8,
        "turns": 4,
        "decisions": 2,
        "choices": 1,
        "elapsed_ms": 30,
        "decision_ms_samples": [10.0, 12.0, 11.0],
        "decision_ms_samples_by_strategy": {
            "A": [10.0, 12.0],
            "B": [11.0],
        },
        "turn_plan_cache_hit_samples": [True, False, True],
        "turn_plan_cache_hit_samples_by_strategy": {
            "A": [True, False],
            "B": [True],
        },
        "ai_turn_ms_samples_by_strategy": {"A": [20.0], "B": [21.0]},
        "action_decisions_by_strategy": {"A": 1, "B": 1},
        "search_depth_decision_counts_by_strategy": {
            "A": {"applicable": 1, "not_applicable": 0, "reasons": {}},
            "B": {"applicable": 1, "not_applicable": 0, "reasons": {}},
        },
        "decision_diagnostics": {},
        "decision_diagnostics_by_strategy": {"A": {}, "B": {}},
        "behavior_by_strategy": _behavior(),
        "search_depth_samples_by_strategy": {
            "A": [{
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
                "nodes_expanded": 1192,
                "planner_ms": 119.2,
                "trajectory_hash": "a" * 64,
                "decision_semantic_hash": "c" * 64,
            }],
            "B": [{
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
                "nodes_expanded": 1192,
                "planner_ms": 119.2,
                "trajectory_hash": "b" * 64,
                "decision_semantic_hash": "d" * 64,
            }],
        },
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "time_capped_decisions": 0,
        "deep_fallbacks": 0,
        "max_actions_exhausted": False,
    }


def _golden_cases():
    return {
        "cases": [
            {"scope": "runtime_integration", "name": "minimal", "passed": True}
        ]
    }


def _shard(
    *,
    decks=("fire", "water"),
    seed_blocks=1,
    cross_blocks=1,
    mode="Balanced",
    rows=None,
    fingerprint_a="strategy-a",
    fingerprint_b="strategy-b",
    provenance=None,
    task_shard_index=0,
    task_shard_count=1,
    golden=True,
):
    decks = list(decks)
    config = _config(
        decks,
        seed_blocks=seed_blocks,
        cross_blocks=cross_blocks,
        mode=mode,
    )
    config["task_shard_index"] = task_shard_index
    config["task_shard_count"] = task_shard_count
    manifest_id = task_manifest_id(decks, config)
    config["task_manifest_id"] = manifest_id
    config["execution_profile_id"] = "test-execution"
    if rows is None:
        rows = [_row(identity) for identity in sorted(expected_match_identities(decks, config))]
    rows = copy.deepcopy(rows)
    for row in rows:
        row["task_shard_index"] = task_shard_index
        row["task_shard_count"] = task_shard_count
    return {
        "schema_version": 7,
        "protocol_id": PROTOCOL_ID,
        "artifact_kind": "ai_evaluation_shard",
        "gate_depth_source": "main_matches",
        "platform": "windows",
        "provenance": copy.deepcopy(provenance or PROVENANCE),
        "simulation_fingerprint": (provenance or PROVENANCE)[
            "simulation_fingerprint"
        ],
        "analysis_fingerprint": (provenance or PROVENANCE)[
            "analysis_fingerprint"
        ],
        "task_manifest_id": manifest_id,
        "execution_profile_id": "test-execution",
        "self_check": fingerprint_a == fingerprint_b,
        "eval_preset": "Custom",
        "mode": mode.lower(),
        "matchup_mode": mode,
        "deck_keys": decks,
        "config": config,
        "strategies": {
            "A": {
                "id": fingerprint_a,
                "label": "Candidate A",
                "engine": "turn_beam_v2",
            },
            "B": {
                "id": fingerprint_b,
                "label": "Control B",
                "engine": "turn_beam_v2",
            },
        },
        "strategy_fingerprint": {
            "A": fingerprint_a,
            "B": fingerprint_b,
            "equal": fingerprint_a == fingerprint_b,
            "rules_options": RULES,
        },
        "golden_scenarios": _golden_cases() if golden else {"cases": []},
        "performance_profile": {
            "enabled": True,
            "segments_ms": {"runner_legal_actions_ms": 12.0},
            "counts": {"decisions": len(rows) * 2, "ai_simulations": 50},
        },
        "checkpoint_summary": {
            "enabled": False,
            "restored_units": 0,
            "written_units": 0,
            "pending_units": 0,
            "completed_unit_ids": [],
        },
        "matches": rows,
    }


def _probe_rows(side_values=None):
    config = _config(
        DECK_ORDER,
        seed_blocks=3,
        cross_blocks=0,
        mode="Mirror",
        run_role="search_depth_probe",
        warmup=1,
        profile=False,
    )
    config["task_manifest_id"] = "test-performance-manifest"
    config["execution_profile_id"] = "test-performance"
    rows = []
    values = side_values or {
        "A": {"decision": 900.0, "cache": 100.0, "turn": 1500.0},
        "B": {"decision": 900.0, "cache": 100.0, "turn": 1500.0},
    }
    for identity in sorted(expected_match_identities(DECK_ORDER, config)):
        phase = "warmup" if identity[3] == 0 else "measurement"
        row = _row(identity, sample_phase=phase)
        for side in ("A", "B"):
            row["decision_ms_samples_by_strategy"][side] = [
                values[side]["cache"],
                values[side]["decision"],
            ]
            row["turn_plan_cache_hit_samples_by_strategy"][side] = [True, False]
            row["ai_turn_ms_samples_by_strategy"][side] = [values[side]["turn"]]
        rows.append(row)
    return config, rows


def _performance_result(side_values=None):
    config, rows = _probe_rows(side_values)
    measured = [row for row in rows if row["sample_phase"] == "measurement"]
    return {
        "available": True,
        "source": "optional_performance_benchmark",
        "gate_basis": "diagnostic_only",
        "config": config,
        "coverage": {
            "complete": True,
            "complete_mirror_units": 30,
            "clean_mirror_units": 30,
        },
        "games_total": 60,
        "warmup_games": 20,
        "measured_games": 40,
        "metrics": summarize_performance(measured),
        "search_depth": summarize_search_depth(measured, DECK_ORDER),
        "observed": summarize_observed(rows),
        "matches": rows,
    }


def _set_main_depth(payload, strategy, *, requested=None, reached=None):
    for row in payload["matches"]:
        for sample in row["search_depth_samples_by_strategy"][strategy]:
            if requested is not None:
                sample["requested"] = requested
                sample["completed"] = min(sample["completed"], requested)
            if reached is not None:
                sample["reached"] = min(sample["requested"], reached)
                sample["completed"] = min(sample["requested"], reached)
                if sample["completed"] < sample["requested"]:
                    sample["completion_reason"] = "cancelled"
                    sample["stop_reason"] = "cancelled"
    payload["search_depth"] = summarize_search_depth(
        payload["matches"],
        DECK_ORDER,
    )


def _nightly_result(*, distinct=True, side_values=None):
    pair_keys = [
        f"{left}_and_{right}"
        for index, left in enumerate(DECK_ORDER)
        for right in DECK_ORDER[index + 1 :]
    ]
    fingerprint_b = "strategy-b" if distinct else "strategy-a"
    config = {
        **_config(DECK_ORDER, seed_blocks=50, cross_blocks=10, mode="Balanced"),
        "eval_preset": "Nightly",
        "seed_block_count": 50,
    }
    manifest_id = task_manifest_id(DECK_ORDER, config)
    config["task_manifest_id"] = manifest_id
    config["execution_profile_id"] = "test-nightly"
    config["parallel_workers"] = 12
    config["evidence_shard_count"] = 50
    simulation_config = {
        "protocol_id": PROTOCOL_ID,
        "eval_preset": "Nightly",
        "deck_keys": list(DECK_ORDER),
        "seed": config["seed"],
        "seed_blocks_per_deck": config["seed_blocks_per_deck"],
        "cross_seed_blocks_per_matchup": config[
            "cross_seed_blocks_per_matchup"
        ],
        "matchup_mode": config["matchup_mode"],
        "max_actions": config["max_actions"],
        "rules_options": copy.deepcopy(config["rules_options"]),
        "workers": 12,
        "external_shard_count": 1,
        "global_parallel_workers": 12,
        "evidence_shard_count": 50,
        "profile": config["profile"],
        "disable_ai_cache": config["disable_ai_cache"],
        "disable_native_math": config["disable_native_math"],
        "task_manifest_id": manifest_id,
        "execution_profile_id": "test-nightly",
    }
    provenance = copy.deepcopy(PROVENANCE)
    provenance["simulation_config"] = copy.deepcopy(simulation_config)
    provenance["simulation_fingerprint"] = (
        simulation_fingerprint_from_provenance(provenance)
    )
    depth_rows = [
        _row(identity)
        for identity in sorted(expected_match_identities(DECK_ORDER, config))
    ]
    if distinct:
        for row in depth_rows:
            for sample in row["search_depth_samples_by_strategy"]["B"]:
                sample["engine_id"] = "turn_beam_v1"
    mirror_units, cross_units = experimental_units(depth_rows)
    completed_unit_ids = complete_evidence_unit_ids(depth_rows)
    coverage = summarize_coverage(
        depth_rows,
        DECK_ORDER,
        config,
        mirror_units,
        cross_units,
    )
    performance_benchmark = _performance_result(side_values)
    return {
        "schema_version": 7,
        "protocol_id": PROTOCOL_ID,
        "artifact_kind": "ai_evaluation_result",
        "platform": "windows",
        "provenance": provenance,
        "simulation_fingerprint": provenance["simulation_fingerprint"],
        "analysis_fingerprint": PROVENANCE["analysis_fingerprint"],
        "task_manifest_id": manifest_id,
        "execution_config": {
            **copy.deepcopy(simulation_config),
            "parallel_workers": 12,
            "platform": "windows",
        },
        "execution_profile_id": "test-nightly",
        "gate_depth_source": "main_matches",
        "self_check": not distinct,
        "eval_preset": "Nightly",
        "matchup_mode": "Balanced",
        "deck_keys": list(DECK_ORDER),
        "config": config,
        "strategies": {
            "A": {"id": "strategy-a", "engine": "turn_beam_v2"},
            "B": {
                "id": fingerprint_b,
                "engine": (
                    "turn_beam_v1" if distinct else "turn_beam_v2"
                ),
            },
        },
        "strategy_fingerprint": {
            "A": "strategy-a",
            "B": fingerprint_b,
            "equal": not distinct,
        },
        "observed": {
            "games": 2800,
            "clean_games": 2800,
            "invalid_actions": 0,
            "choice_failures": 0,
            "rule_exceptions": 0,
            "max_actions_exhaustions": 0,
            "deep_fallback_rate": 0.0,
        },
        "coverage": coverage,
        "fairness": {
            "assignment_balanced": True,
            "per_strategy_deck_balanced": True,
            "mirror_units_complete": True,
            "cross_units_complete": True,
        },
        "behavior": {"available": True, "overall": {}, "per_deck": {}},
        "golden_scenarios": {
            "total": 152,
            "passed": 152,
            "failed": 0,
            "by_scope": {
                "coverage_contract": {"total": 10},
                "runtime_integration": {"total": 3},
                "strategy_score": {"total": 109},
                "turn_sequence": {"total": 30},
            },
            "cases": [],
        },
        "strength": {
            "mirror": {
                "overall": {
                    "point_delta": 0.0,
                    "ci95": {"lower": -0.02, "upper": 0.02, "iterations": 10000},
                },
                "per_deck": {
                    deck: {"point_delta": -0.04}
                    for deck in DECK_ORDER
                },
            },
            "cross_role": {
                "overall": {
                    "point_delta": 0.0,
                    "ci95": {"lower": -0.02, "upper": 0.02, "iterations": 10000},
                },
                "per_unordered_matchup": {
                    key: {"point_delta": -0.08}
                    for key in pair_keys
                },
            },
        },
        "search_depth": summarize_search_depth(depth_rows, DECK_ORDER),
        "performance_benchmark": performance_benchmark,
        "performance": performance_benchmark,
        "decision_diagnostics": {
            "total": 0,
            "by_strategy": {
                "A": {"total": 0, "decisions": 100, "rates": {}},
                "B": {"total": 0, "decisions": 100, "rates": {}},
                "delta": {"total": 0},
            },
        },
        "terminal_reasons": {"game_over": 2800},
        "raw_matrix": {},
        "matches": depth_rows,
        "performance_profile": {
            "enabled": True,
            "segments_ms": {"runner_legal_actions_ms": 20.0},
            "counts": {"decisions": 100, "ai_simulations": 200},
        },
        "checkpoint_summary": {
            "enabled": True,
            "shards_enabled": 50,
            "shards_total": 50,
            "restored_units": 0,
            "written_units": 950,
            "pending_units": 0,
            "completed_units": len(completed_unit_ids),
            "completed_unit_ids": completed_unit_ids,
            "completed_unit_ids_sha256": evidence_unit_ids_sha256(
                completed_unit_ids
            ),
        },
        "wall_clock_scope": "not_recorded",
    }


class ClusterAggregationTests(unittest.TestCase):
    def test_two_game_and_four_game_units_are_complete(self):
        result = merge_payloads([_shard()])
        self.assertEqual(result["coverage"]["complete_mirror_units"], 2)
        self.assertEqual(result["coverage"]["complete_cross_units"], 1)
        self.assertEqual(result["strength"]["mirror"]["overall"]["ci95"]["iterations"], 10000)
        self.assertEqual(result["strength"]["cross_role"]["overall"]["ci95"]["unit"], "cluster")

    def test_role_crossover_neutralizes_deck_role(self):
        shard = _shard()
        for row in shard["matches"]:
            if row["matchup_kind"] == "cross":
                row["winner"] = "A" if row["strategy_a_deck"] == "fire" else "B"
        result = merge_payloads([shard])
        cross = result["strength"]["cross_role"]["overall"]
        self.assertEqual(cross["point_delta"], 0.0)

    def test_decks_are_equal_weight_not_game_weighted(self):
        units = [{"group": "fire", "clean": True, "complete": True, "point_delta": 0.5}]
        units += [
            {"group": "water", "clean": True, "complete": True, "point_delta": -0.5}
            for _ in range(9)
        ]
        strength = summarize_strength(units, [])
        self.assertEqual(strength["mirror"]["overall"]["point_delta"], 0.0)

    def test_bootstrap_is_fixed_and_dirty_blocks_are_excluded(self):
        clean = {"group": "fire", "clean": True, "complete": True, "point_delta": 0.5}
        dirty = {"group": "fire", "clean": False, "complete": True, "point_delta": -0.5}
        first = summarize_strength([clean, dirty], [])
        second = summarize_strength([clean, dirty], [])
        self.assertEqual(first, second)
        self.assertEqual(first["mirror"]["clean_units"], 1)
        self.assertEqual(first["mirror"]["overall"]["point_delta"], 0.5)
        self.assertEqual(BOOTSTRAP_ITERATIONS, 10000)

    def test_bad_first_player_or_assignment_makes_unit_incomplete(self):
        shard = _shard(mode="Mirror", cross_blocks=0)
        shard["matches"][0]["forced_first_player"] = 1
        result = merge_payloads([shard])
        self.assertFalse(result["coverage"]["complete"])
        self.assertTrue(result["coverage"]["structural_errors"])


class BehaviorTests(unittest.TestCase):
    def test_behavior_is_attributed_to_strategy_actual_deck(self):
        row = _row(("cross", "fire", "water", 0, 123, 0))
        result = summarize_behavior([row], ["fire", "water"])
        self.assertTrue(result["available"])
        self.assertEqual(result["per_deck"]["A"]["fire"]["selected_action_counts"]["PLAY_BASIC"], 1)
        self.assertEqual(result["per_deck"]["B"]["water"]["selected_action_counts"]["END_TURN"], 1)
        self.assertEqual(result["overall"]["A"]["selection_rate_when_available"]["PLAY_BASIC"], 1.0)
        self.assertIn("select_prize", result["overall"]["A"]["choice_request_counts"])
        self.assertIsNotNone(result["overall"]["A"]["normalized_action_entropy"])

    def test_behavior_is_diagnostic_not_a_strict_gate(self):
        payload = _nightly_result(distinct=False)
        payload["behavior"] = {"available": False}
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"])


class MergeIntegrityTests(unittest.TestCase):
    def test_wall_clock_is_optional_diagnostic_metadata(self):
        without_timing = merge_payloads([_shard()])
        self.assertNotIn("wall_clock_ms", without_timing)
        self.assertEqual(
            without_timing["wall_clock_scope"], "not_recorded"
        )
        with_timing = merge_payloads([_shard()], wall_clock_ms=1234.56789)
        self.assertEqual(with_timing["wall_clock_ms"], 1234.5679)
        self.assertEqual(
            with_timing["wall_clock_scope"], "full_evidence_stage"
        )
        resumed_shard = _shard()
        resumed_shard["checkpoint_summary"] = {
            "enabled": True,
            "restored_units": 1,
            "written_units": 0,
            "pending_units": 0,
            "completed_unit_ids": complete_evidence_unit_ids(
                resumed_shard["matches"]
            )[:1],
        }
        resumed = merge_payloads([resumed_shard], wall_clock_ms=12.0)
        self.assertEqual(
            resumed["wall_clock_scope"], "current_attempt_only"
        )
        explicit = merge_payloads(
            [resumed_shard],
            wall_clock_ms=12.0,
            wall_clock_scope="full_evidence_stage",
        )
        self.assertEqual(
            explicit["wall_clock_scope"], "full_evidence_stage"
        )
        with self.assertRaisesRegex(MergeError, "wall_clock_ms"):
            merge_payloads([_shard()], wall_clock_ms=0.0)
        with self.assertRaisesRegex(MergeError, "wall_clock_scope"):
            merge_payloads(
                [_shard()],
                wall_clock_scope="full_evidence_stage",
            )
        with self.assertRaisesRegex(MergeError, "wall_clock_scope"):
            merge_payloads(
                [_shard()],
                wall_clock_ms=12.0,
                wall_clock_scope="not_recorded",
            )

    def test_each_v7_shard_requires_checkpoint_summary(self):
        shard = _shard()
        shard.pop("checkpoint_summary")
        with self.assertRaisesRegex(
            MergeError,
            "invalid_checkpoint_summary:0:missing",
        ):
            merge_payloads([shard])
        inconsistent = _shard()
        inconsistent["checkpoint_summary"]["written_units"] = 1
        with self.assertRaisesRegex(
            MergeError,
            "invalid_checkpoint_summary:0",
        ):
            merge_payloads([inconsistent])

    def test_checkpoint_unit_manifest_is_bound_to_shard_matches(self):
        shard = _shard()
        shard["checkpoint_summary"] = {
            "enabled": True,
            "restored_units": 1,
            "written_units": 0,
            "pending_units": 0,
            "completed_unit_ids": ["mirror|steel|999|999"],
        }

        with self.assertRaisesRegex(
            MergeError,
            "invalid_checkpoint_summary:0:match_identity",
        ):
            merge_payloads([shard])

    def test_missing_shard_is_visible_not_normalized_to_complete(self):
        shard = _shard()
        shard["matches"].pop()
        result = merge_payloads([shard])
        self.assertFalse(result["coverage"]["complete"])
        self.assertEqual(result["coverage"]["missing_match_count"], 1)
        self.assertEqual(result["observed"]["games"], 7)

    def test_duplicate_match_identifier_fails(self):
        shard = _shard()
        shard["matches"].append(copy.deepcopy(shard["matches"][0]))
        with self.assertRaisesRegex(MergeError, "duplicate_match"):
            merge_payloads([shard])

    def test_invalid_seat_fails_and_bad_seed_is_coverage_failure(self):
        bad_seat = _shard()
        bad_seat["matches"][0]["seat"] = 2
        with self.assertRaisesRegex(MergeError, "invalid_seat"):
            merge_payloads([bad_seat])
        bad_seed = _shard()
        bad_seed["matches"][0]["seed"] += 1
        result = merge_payloads([bad_seed])
        self.assertFalse(result["coverage"]["complete"])
        self.assertEqual(result["coverage"]["missing_match_count"], 1)
        self.assertEqual(result["coverage"]["unexpected_match_count"], 1)

    def test_provenance_and_config_conflicts_fail(self):
        full = _shard()
        left_rows = full["matches"][::2]
        right_rows = full["matches"][1::2]
        left = _shard(rows=left_rows, task_shard_index=0, task_shard_count=2)
        right = _shard(rows=right_rows, task_shard_index=1, task_shard_count=2)
        right["provenance"]["simulation_fingerprint"] = "d" * 64
        right["simulation_fingerprint"] = "d" * 64
        with self.assertRaisesRegex(MergeError, "simulation_fingerprint"):
            merge_payloads([left, right])
        right["provenance"] = copy.deepcopy(PROVENANCE)
        right["simulation_fingerprint"] = PROVENANCE["simulation_fingerprint"]
        right["analysis_fingerprint"] = PROVENANCE["analysis_fingerprint"]
        right["config"]["seed"] = 18
        with self.assertRaisesRegex(MergeError, "config:seed"):
            merge_payloads([left, right])

    def test_shard_merge_recomputes_simulation_fingerprint(self):
        tampered = _shard()
        tampered["provenance"]["product_version"] = "tampered"
        tampered["provenance"]["simulation_fingerprint"] = "d" * 64
        tampered["simulation_fingerprint"] = "d" * 64
        with self.assertRaisesRegex(MergeError, "simulation_fingerprint"):
            merge_payloads([tampered])

    def test_analysis_changes_reuse_identical_simulation_shards(self):
        full = _shard()
        left = _shard(
            rows=full["matches"][::2],
            task_shard_index=0,
            task_shard_count=2,
        )
        right = _shard(
            rows=full["matches"][1::2],
            task_shard_index=1,
            task_shard_count=2,
        )
        right["provenance"]["analysis_fingerprint"] = "d" * 64
        right["analysis_fingerprint"] = "d" * 64
        result = merge_payloads(
            [left, right],
            analysis_fingerprint="e" * 64,
        )
        self.assertEqual(
            result["simulation_fingerprint"],
            PROVENANCE["simulation_fingerprint"],
        )
        self.assertEqual(result["analysis_fingerprint"], "e" * 64)
        self.assertEqual(
            result["provenance"]["analysis_fingerprint"],
            "e" * 64,
        )

    def test_unknown_deck_and_pre_v7_results_are_rejected(self):
        unknown = _shard()
        unknown["deck_keys"] = ["missing"]
        with self.assertRaisesRegex(MergeError, "deck_keys"):
            merge_payloads([unknown])
        old = _shard()
        old["schema_version"] = 6
        with self.assertRaisesRegex(MergeError, "schema_version"):
            merge_payloads([old])
        wrong_protocol = _shard()
        wrong_protocol["protocol_id"] = "traditional_ai_evaluation_v6"
        with self.assertRaisesRegex(MergeError, "protocol_id"):
            merge_payloads([wrong_protocol])

    def test_v7_match_schema_rejects_unaligned_latency_samples(self):
        shard = _shard()
        shard["matches"][0]["turn_plan_cache_hit_samples_by_strategy"]["A"] = []
        with self.assertRaisesRegex(MergeError, "invalid_latency_samples:A"):
            merge_payloads([shard])

    def test_v7_match_schema_requires_valid_search_depth_samples(self):
        shard = _shard()
        del shard["matches"][0]["search_depth_samples_by_strategy"]
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_samples"):
            merge_payloads([shard])
        shard = _shard()
        shard["matches"][0]["search_depth_samples_by_strategy"]["A"][0]["reached"] = 9
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_sample"):
            merge_payloads([shard])
        shard = _shard()
        shard["matches"][0]["search_depth_samples_by_strategy"]["A"][0][
            "max_path_depth"
        ] = 7
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_sample"):
            merge_payloads([shard])
        shard = _shard()
        shard["matches"][0]["search_depth_samples_by_strategy"]["A"][0][
            "layers_completed"
        ] = 7
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_sample"):
            merge_payloads([shard])

        shard = _shard()
        del shard["matches"][0]["search_depth_samples_by_strategy"]["A"][0][
            "reply_requested"
        ]
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_sample"):
            merge_payloads([shard])

        shard = _shard()
        sample = shard["matches"][0]["search_depth_samples_by_strategy"]["A"][0]
        sample["reply_requested"] = 3
        sample["reply_completed"] = 1
        sample["reply_completion_reason"] = "depth_complete"
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_sample"):
            merge_payloads([shard])

    def test_v7_search_decision_accounting_is_conserved(self):
        shard = _shard()
        shard["matches"][0]["search_depth_decision_counts_by_strategy"]["A"][
            "applicable"
        ] = 0
        with self.assertRaisesRegex(
            MergeError, "invalid_search_depth_decision_counts:A"
        ):
            merge_payloads([shard])

        shard = _shard()
        row = shard["matches"][0]
        row["search_depth_samples_by_strategy"]["A"] = []
        row["search_depth_decision_counts_by_strategy"]["A"] = {
            "applicable": 0,
            "not_applicable": 1,
            "reasons": {"error": 1},
        }
        with self.assertRaisesRegex(
            MergeError, "invalid_search_depth_decision_counts:A"
        ):
            merge_payloads([shard])

    def test_merge_allows_non_gate_smoke_reply_depth_one(self):
        shard = _shard()
        for row in shard["matches"]:
            for strategy in ("A", "B"):
                for sample in row["search_depth_samples_by_strategy"][strategy]:
                    sample["requested"] = 1
                    sample["reached"] = 1
                    sample["completed"] = 1
                    sample["max_path_depth"] = 1
                    sample["layers_completed"] = 1
                    sample["reply_requested"] = 1
                    sample["reply_completed"] = 1
        result = merge_payloads([shard])
        self.assertEqual(
            result["search_depth"]["by_strategy"]["A"]["overall"][
                "reply_requested_depth_min"
            ],
            1,
        )

    def test_search_depth_is_aggregated_by_strategy_and_actual_deck(self):
        result = merge_payloads([_shard()])
        self.assertEqual(result["evaluation_policy"]["latency"], "diagnostic_only")
        depth = result["search_depth"]
        self.assertTrue(depth["available"])
        self.assertEqual(
            depth["by_strategy"]["A"]["full_tier"]["completed_depth_p50"], 8.0
        )
        self.assertGreater(
            depth["by_strategy"]["B"]["per_deck"]["water"]["full_tier"]["sample_count"],
            0,
        )

    def test_single_and_multi_shard_authoritative_metrics_match(self):
        full = _shard()
        single = merge_payloads([full], workers=1)
        left = _shard(
            rows=full["matches"][::2], task_shard_index=0, task_shard_count=2
        )
        right = _shard(
            rows=full["matches"][1::2], task_shard_index=1, task_shard_count=2, golden=False
        )
        multi = merge_payloads([left, right], workers=2)
        for key in (
            "observed",
            "strength",
            "fairness",
            "behavior",
            "search_depth",
            "raw_matrix",
            "fair_adjusted_matrix",
        ):
            self.assertEqual(single[key], multi[key], key)
        for key in (
            "expected_games",
            "actual_games",
            "complete_mirror_units",
            "complete_cross_units",
            "clean_mirror_units",
            "clean_cross_units",
            "missing_match_count",
            "unexpected_match_count",
            "complete",
        ):
            self.assertEqual(single["coverage"][key], multi["coverage"][key], key)

    def test_performance_benchmark_provenance_mismatch_fails(self):
        config, rows = _probe_rows()
        probe_provenance = copy.deepcopy(PROVENANCE)
        probe_provenance["product_version"] = "other"
        probe_provenance["simulation_fingerprint"] = (
            simulation_fingerprint_from_provenance(probe_provenance)
        )
        probe = _shard(
            decks=DECK_ORDER,
            seed_blocks=3,
            cross_blocks=0,
            mode="Mirror",
            rows=rows,
            provenance=probe_provenance,
        )
        probe["config"] = config
        probe["task_manifest_id"] = config["task_manifest_id"]
        probe["execution_profile_id"] = config["execution_profile_id"]
        with self.assertRaisesRegex(
            MergeError,
            "performance_benchmark:simulation_fingerprint",
        ):
            merge_payloads([_shard()], search_depth_shards=[probe])


class GateTests(unittest.TestCase):
    def test_equivalence_accepts_all_exact_boundaries(self):
        result = validate_evaluation_gate(_nightly_result(), gate="nightly-equivalence")
        self.assertTrue(result["valid"], result["error_codes"])

    def test_superiority_requires_both_ci_lowers_above_zero_and_diagnostic_reduction(self):
        payload = _nightly_result()
        payload["strength"]["mirror"]["overall"]["ci95"]["lower"] = 0.001
        payload["strength"]["cross_role"]["overall"]["ci95"]["lower"] = 0.001
        payload["decision_diagnostics"]["by_strategy"]["A"]["rates"] = {
            "weak_attack_before_development": 0.005,
        }
        payload["decision_diagnostics"]["by_strategy"]["B"]["rates"] = {
            "weak_attack_before_development": 0.01,
        }
        result = validate_evaluation_gate(payload, gate="nightly-superiority")
        self.assertTrue(result["valid"], result["error_codes"])
        payload["strength"]["cross_role"]["overall"]["ci95"]["lower"] = 0.0
        result = validate_evaluation_gate(payload, gate="nightly-superiority")
        self.assertIn("cross_ci_below_floor", result["error_codes"])

    def test_superiority_depth_gate_requires_v2_engine_evidence(self):
        payload = _nightly_result()
        for row in payload["matches"]:
            for sample in row["search_depth_samples_by_strategy"]["A"]:
                sample["engine_id"] = "turn_beam_v1"
        payload["search_depth"] = summarize_search_depth(
            payload["matches"], DECK_ORDER
        )
        result = validate_evaluation_gate(payload, gate="nightly-superiority")
        self.assertIn("search_depth_engine_mismatch", result["error_codes"])

    def test_dual_ci_and_group_floors_fail_independently(self):
        cases = [
            ("mirror_ci_below_floor", lambda p: p["strength"]["mirror"]["overall"]["ci95"].update(lower=-0.0201)),
            ("cross_ci_below_floor", lambda p: p["strength"]["cross_role"]["overall"]["ci95"].update(lower=-0.0201)),
            ("mirror_deck_fire_below_floor", lambda p: p["strength"]["mirror"]["per_deck"]["fire"].update(point_delta=-0.0401)),
            ("cross_matchup_colorless_and_darkness_below_floor", lambda p: p["strength"]["cross_role"]["per_unordered_matchup"]["colorless_and_darkness"].update(point_delta=-0.0801)),
        ]
        for expected, mutate in cases:
            with self.subTest(expected=expected):
                payload = _nightly_result()
                mutate(payload)
                result = validate_evaluation_gate(payload, gate="nightly-equivalence")
                self.assertIn(expected, result["error_codes"])

    def test_strategy_fingerprint_relation_is_enforced(self):
        same = validate_evaluation_gate(_nightly_result(distinct=False), gate="nightly-equivalence")
        different = validate_evaluation_gate(_nightly_result(distinct=True), gate="nightly-stability")
        self.assertIn("strategy_relation", same["error_codes"])
        self.assertIn("strategy_relation", different["error_codes"])

    def test_stability_requires_balanced_decision_diagnostics(self):
        payload = _nightly_result(distinct=False)
        payload["decision_diagnostics"]["by_strategy"]["delta"]["total"] = 1
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("decision_diagnostics_unbalanced", result["error_codes"])

    def test_strict_zero_tolerance_and_quick_warning(self):
        strict_payload = _nightly_result(distinct=False)
        strict_payload["observed"]["clean_games"] = 2799
        self.assertIn(
            "dirty_games",
            validate_evaluation_gate(strict_payload, gate="nightly-stability")["error_codes"],
        )
        quick = _nightly_result()
        quick["coverage"]["complete"] = False
        quick["coverage"]["missing_match_count"] = 1
        quick["observed"]["clean_games"] = 2799
        result = validate_evaluation_gate(quick, gate="quick")
        self.assertTrue(result["valid"])
        self.assertIn("coverage_incomplete", result["warning_codes"])
        self.assertIn("dirty_games", result["warning_codes"])
        self.assertNotIn("mirror_ci_below_floor", result["error_codes"])

    def test_latency_is_diagnostic_and_does_not_gate(self):
        values = {
            "A": {"decision": 9001.0, "cache": 1000.0, "turn": 15000.0},
            "B": {"decision": 9000.0, "cache": 1000.0, "turn": 15000.0},
        }
        result = validate_evaluation_gate(
            _nightly_result(distinct=False, side_values=values), gate="nightly-stability"
        )
        self.assertTrue(result["valid"], result["error_codes"])
        self.assertFalse(result["latency_gate_enabled"])
        self.assertNotIn("latency", " ".join(result["error_codes"]))

    def test_main_search_depth_checks_a_and_b_separately(self):
        payload = _nightly_result(distinct=False)
        _set_main_depth(payload, "A", reached=2)
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        shallow = [
            error
            for error in result["errors"]
            if error["code"] == "search_depth_incomplete"
        ]
        self.assertTrue(any(error["details"]["strategy"] == "A" for error in shallow))
        self.assertFalse(any(error["details"]["strategy"] == "B" for error in shallow))

    def test_configured_search_depth_cannot_be_lowered(self):
        payload = _nightly_result()
        _set_main_depth(payload, "A", requested=5, reached=5)
        result = validate_evaluation_gate(payload, gate="nightly-equivalence")
        self.assertIn("search_depth_requested_below_floor", result["error_codes"])

    def test_strict_gate_requires_reply_depth_three_or_exhaustion(self):
        payload = _nightly_result()
        for row in payload["matches"]:
            for sample in row["search_depth_samples_by_strategy"]["A"]:
                sample["reply_requested"] = 1
                sample["reply_completed"] = 1
        payload["search_depth"] = summarize_search_depth(
            payload["matches"], DECK_ORDER
        )
        result = validate_evaluation_gate(
            payload, gate="nightly-equivalence"
        )
        self.assertIn(
            "reply_depth_requested_mismatch", result["error_codes"]
        )

        exhausted = _nightly_result()
        for row in exhausted["matches"]:
            for sample in row["search_depth_samples_by_strategy"]["A"]:
                sample["reply_completed"] = 1
                sample["reply_completion_reason"] = "frontier_exhausted"
        exhausted["search_depth"] = summarize_search_depth(
            exhausted["matches"], DECK_ORDER
        )
        result = validate_evaluation_gate(
            exhausted, gate="nightly-equivalence"
        )
        self.assertNotIn("reply_depth_incomplete", result["error_codes"])
        self.assertNotIn(
            "reply_depth_requested_mismatch", result["error_codes"]
        )

    def test_reply_applicability_and_decision_accounting_tampering_fail(self):
        payload = _nightly_result(distinct=False)
        for row in payload["matches"]:
            for sample in row["search_depth_samples_by_strategy"]["A"]:
                sample["reply_applicable"] = False
                sample["reply_completed"] = 0
                sample["reply_completion_reason"] = "not_applicable"
        payload["search_depth"] = summarize_search_depth(
            payload["matches"], DECK_ORDER
        )
        result = validate_evaluation_gate(
            payload, gate="nightly-stability"
        )
        self.assertIn("reply_depth_evidence_missing", result["error_codes"])

        payload = _nightly_result(distinct=False)
        payload["matches"][0][
            "search_depth_decision_counts_by_strategy"
        ]["A"]["applicable"] = 0
        payload["search_depth"] = summarize_search_depth(
            payload["matches"], DECK_ORDER
        )
        result = validate_evaluation_gate(
            payload, gate="nightly-stability"
        )
        self.assertIn(
            "search_depth_decision_accounting", result["error_codes"]
        )

    def test_validator_rejects_stale_analysis_fingerprint(self):
        payload = _nightly_result(distinct=False)
        payload["analysis_fingerprint"] = "d" * 64
        payload["provenance"]["analysis_fingerprint"] = "d" * 64
        result = validate_evaluation_gate(
            payload, gate="nightly-stability"
        )
        self.assertIn("analysis_fingerprint_stale", result["error_codes"])

    def test_validator_recomputes_simulation_fingerprint(self):
        payload = _nightly_result(distinct=False)
        payload["provenance"]["product_version"] = "tampered"
        payload["provenance"]["simulation_fingerprint"] = "d" * 64
        payload["simulation_fingerprint"] = "d" * 64
        result = validate_evaluation_gate(
            payload, gate="nightly-stability"
        )
        self.assertIn(
            "simulation_fingerprint_mismatch",
            result["error_codes"],
        )

    def test_final_nightly_requires_complete_simulation_provenance(self):
        missing_config = _nightly_result(distinct=False)
        missing_config["provenance"].pop("simulation_config")
        result = validate_evaluation_gate(
            missing_config,
            gate="nightly-stability",
        )
        self.assertIn("simulation_config", result["error_codes"])
        self.assertIn("task_manifest", result["error_codes"])

        missing_field = _nightly_result(distinct=False)
        missing_field["provenance"]["simulation_config"].pop("profile")
        result = validate_evaluation_gate(
            missing_field,
            gate="nightly-stability",
        )
        self.assertIn("simulation_config", result["error_codes"])

        missing_godot_hash = _nightly_result(distinct=False)
        missing_godot_hash["provenance"].pop(
            "godot_executable_sha256"
        )
        result = validate_evaluation_gate(
            missing_godot_hash,
            gate="nightly-stability",
        )
        self.assertIn("godot_executable_hash", result["error_codes"])

    def test_simulation_provenance_tampering_is_rejected(self):
        schedule_tamper = _nightly_result(distinct=False)
        schedule_tamper["provenance"]["simulation_config"]["seed"] += 1
        result = validate_evaluation_gate(
            schedule_tamper,
            gate="nightly-stability",
        )
        self.assertIn("simulation_config", result["error_codes"])

        execution_tamper = _nightly_result(distinct=False)
        execution_tamper["execution_config"][
            "global_parallel_workers"
        ] += 1
        result = validate_evaluation_gate(
            execution_tamper,
            gate="nightly-stability",
        )
        self.assertIn("simulation_config", result["error_codes"])

        malformed_godot_hash = _nightly_result(distinct=False)
        malformed_godot_hash["provenance"][
            "godot_executable_sha256"
        ] = "not-a-sha256"
        result = validate_evaluation_gate(
            malformed_godot_hash,
            gate="nightly-stability",
        )
        self.assertIn("godot_executable_hash", result["error_codes"])

    def test_legacy_provenance_compatibility_is_non_nightly_only(self):
        payload = _nightly_result()
        payload["provenance"]["simulation_config"].pop("profile")
        payload["provenance"].pop("godot_executable_sha256")
        result = validate_evaluation_gate(
            payload,
            gate="deep-practical",
        )
        self.assertTrue(result["valid"], result["error_codes"])
        self.assertIn(
            "legacy_provenance_compatibility",
            result["warning_codes"],
        )

        tampered = _nightly_result()
        tampered["provenance"]["simulation_config"]["workers"] += 1
        result = validate_evaluation_gate(
            tampered,
            gate="deep-practical",
        )
        self.assertIn("simulation_config", result["error_codes"])

    def test_final_nightly_requires_complete_checkpoint_evidence(self):
        mutations = {}

        missing = _nightly_result(distinct=False)
        missing.pop("checkpoint_summary")
        mutations["missing"] = missing

        disabled = _nightly_result(distinct=False)
        disabled["checkpoint_summary"]["enabled"] = False
        mutations["disabled"] = disabled

        missing_shard = _nightly_result(distinct=False)
        missing_shard["checkpoint_summary"]["shards_enabled"] = 49
        mutations["missing_shard"] = missing_shard

        missing_unit = _nightly_result(distinct=False)
        missing_unit["checkpoint_summary"]["written_units"] = 949
        mutations["missing_unit"] = missing_unit

        pending = _nightly_result(distinct=False)
        pending["checkpoint_summary"]["pending_units"] = 1
        mutations["pending"] = pending

        wrong_unit_identity = _nightly_result(distinct=False)
        unit_ids = list(
            wrong_unit_identity["checkpoint_summary"][
                "completed_unit_ids"
            ]
        )
        unit_ids[0] = "mirror|colorless|999|999"
        unit_ids.sort()
        wrong_unit_identity["checkpoint_summary"][
            "completed_unit_ids"
        ] = unit_ids
        wrong_unit_identity["checkpoint_summary"][
            "completed_unit_ids_sha256"
        ] = evidence_unit_ids_sha256(unit_ids)
        mutations["unit_identity_mismatch"] = wrong_unit_identity

        wrong_unit_hash = _nightly_result(distinct=False)
        wrong_unit_hash["checkpoint_summary"][
            "completed_unit_ids_sha256"
        ] = "0" * 64
        mutations["unit_identity_hash"] = wrong_unit_hash

        for label, payload in mutations.items():
            with self.subTest(label=label):
                result = validate_evaluation_gate(
                    payload,
                    gate="nightly-stability",
                )
                self.assertIn(
                    "checkpoint_summary",
                    result["error_codes"],
                )

        compatible = _nightly_result()
        compatible["checkpoint_summary"] = {
            "enabled": False,
            "restored_units": 0,
            "written_units": 0,
            "pending_units": 0,
        }
        result = validate_evaluation_gate(
            compatible,
            gate="deep-practical",
        )
        self.assertNotIn(
            "checkpoint_summary",
            result["error_codes"],
        )

    def test_wall_clock_scope_and_value_must_be_paired(self):
        missing_scope = _nightly_result(distinct=False)
        missing_scope.pop("wall_clock_scope")

        unexpected_time = _nightly_result(distinct=False)
        unexpected_time["wall_clock_ms"] = 100.0

        missing_time = _nightly_result(distinct=False)
        missing_time["wall_clock_scope"] = "full_evidence_stage"

        invalid_time = _nightly_result(distinct=False)
        invalid_time["wall_clock_scope"] = "current_attempt_only"
        invalid_time["wall_clock_ms"] = -1.0

        for label, payload in {
            "missing_scope": missing_scope,
            "unexpected_time": unexpected_time,
            "missing_time": missing_time,
            "invalid_time": invalid_time,
        }.items():
            with self.subTest(label=label):
                result = validate_evaluation_gate(
                    payload,
                    gate="nightly-stability",
                )
                self.assertIn(
                    "wall_clock_metadata",
                    result["error_codes"],
                )

        recorded = _nightly_result(distinct=False)
        recorded["wall_clock_scope"] = "full_evidence_stage"
        recorded["wall_clock_ms"] = 1234.5
        result = validate_evaluation_gate(
            recorded,
            gate="nightly-stability",
        )
        self.assertNotIn(
            "wall_clock_metadata",
            result["error_codes"],
        )

    def test_optional_benchmark_does_not_gate(self):
        payload = _nightly_result(distinct=False)
        payload["performance"]["warmup_games"] = 18
        payload["performance"]["measured_games"] = 42
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"], result["error_codes"])
        self.assertIn("performance_benchmark_invalid", result["warning_codes"])
        payload = _nightly_result(distinct=False)
        payload["performance_benchmark"] = {
            "available": False,
            "reason": "performance_benchmark_not_requested",
        }
        payload["performance"] = payload["performance_benchmark"]
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"], result["error_codes"])

    def test_main_depth_summary_is_recomputed_and_gate_source_is_locked(self):
        payload = _nightly_result(distinct=False)
        payload["search_depth"]["by_strategy"]["A"]["overall"][
            "completed_depth_p50"
        ] = 7.0
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("search_depth_metrics", result["error_codes"])

        payload = _nightly_result(distinct=False)
        payload["gate_depth_source"] = "performance_benchmark"
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("gate_depth_source", result["error_codes"])

    def test_task_manifest_must_match_merged_config(self):
        payload = _nightly_result(distinct=False)
        payload.pop("task_manifest_id")
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("task_manifest", result["error_codes"])

        payload = _nightly_result(distinct=False)
        payload["execution_config"].pop("task_manifest_id")
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("task_manifest", result["error_codes"])

        payload = _nightly_result(distinct=False)
        payload["task_manifest_id"] = "different"
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("task_manifest", result["error_codes"])

        payload = _nightly_result(distinct=False)
        payload["task_manifest_id"] = "d" * 64
        payload["config"]["task_manifest_id"] = "d" * 64
        payload["provenance"]["simulation_config"] = {
            "task_manifest_id": "d" * 64
        }
        payload["execution_config"]["task_manifest_id"] = "d" * 64
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("task_manifest", result["error_codes"])

    def test_android_latency_is_also_diagnostic_only(self):
        values = {
            "A": {"decision": 1000.0, "cache": 200.0, "turn": 2000.0},
            "B": {"decision": 1000.0, "cache": 200.0, "turn": 2000.0},
        }
        payload = _nightly_result(distinct=False, side_values=values)
        payload["platform"] = "android"
        payload["config"]["platform"] = "android"
        payload["execution_config"]["platform"] = "android"
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"], result["error_codes"])
        values["B"]["turn"] = 2000.1
        payload["performance_benchmark"] = _performance_result(values)
        payload["performance"] = payload["performance_benchmark"]
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"], result["error_codes"])

    def test_deep_practical_uses_v5_dual_metric_and_zero_fallback(self):
        payload = _nightly_result()
        payload["eval_preset"] = "Custom"
        payload["config"]["eval_preset"] = "Custom"
        payload["provenance"]["simulation_config"]["eval_preset"] = "Custom"
        payload["execution_config"]["eval_preset"] = "Custom"
        payload["provenance"]["simulation_fingerprint"] = (
            simulation_fingerprint_from_provenance(payload["provenance"])
        )
        payload["simulation_fingerprint"] = payload["provenance"][
            "simulation_fingerprint"
        ]
        payload["strength"]["mirror"]["overall"]["ci95"]["lower"] = -0.04
        payload["strength"]["cross_role"]["overall"]["ci95"]["lower"] = -0.04
        for row in payload["strength"]["mirror"]["per_deck"].values():
            row["point_delta"] = -0.08
        self.assertTrue(validate_evaluation_gate(payload, gate="deep-practical")["valid"])
        payload["observed"]["deep_fallback_rate"] = 0.001
        self.assertIn(
            "deep_fallback_rate",
            validate_evaluation_gate(payload, gate="deep-practical")["error_codes"],
        )

    def test_deep_release_enforces_noninferiority_runtime_and_timeout(self):
        payload = _nightly_result()
        payload["strategies"]["A"].update(
            {"mode": "deep", "production_runtime": True}
        )
        payload["strategies"]["B"].update(
            {"mode": "challenge", "production_runtime": True}
        )
        payload["observed"]["deep_fallbacks"] = 0
        for row in payload["matches"]:
            action_counts = row["action_decisions_by_strategy"]
            row["decision_engine_counts_by_strategy"] = {
                "A": (
                    {"deep_root_ismcts_v1": action_counts["A"]}
                    if action_counts["A"]
                    else {}
                ),
                "B": (
                    {"turn_beam_v2": action_counts["B"]}
                    if action_counts["B"]
                    else {}
                ),
            }
        result = validate_evaluation_gate(payload, gate="deep-release")
        self.assertTrue(result["valid"], result["error_codes"])

        payload["matches"][0]["decision_ms_samples_by_strategy"]["A"][0] = 2000.1
        payload["matches"][0]["decision_ms_samples"][0] = 2000.1
        result = validate_evaluation_gate(payload, gate="deep-release")
        self.assertIn("deep_decision_timeout", result["error_codes"])

        payload["matches"][0]["decision_ms_samples_by_strategy"]["A"][0] = 10.0
        payload["matches"][0]["decision_ms_samples"][0] = 10.0
        payload["strength"]["mirror"]["overall"]["ci95"]["lower"] = -0.0201
        result = validate_evaluation_gate(payload, gate="deep-release")
        self.assertIn("mirror_ci_below_floor", result["error_codes"])


class ReportTests(unittest.TestCase):
    def test_report_has_structured_gate_dual_heatmaps_behavior_and_all_matches(self):
        payload = _nightly_result()
        validation = validate_evaluation_gate(payload, gate="nightly-equivalence")
        payload["matches"] = [
            {
                "matchup_kind": "mirror",
                "strategy_a_deck": "fire",
                "strategy_b_deck": "fire",
                "seed": index,
                "seed_block": index,
                "seat": index % 2,
                "forced_first_player": index % 2,
                "winner": "draw",
                "terminal_reason": "game_over",
                "terminal_message": "",
                "actions": 8,
                "elapsed_ms": 10,
            }
            for index in range(300)
        ]
        html = render_report(payload, validation)
        for text in (
            "通过等价性门禁",
            "这不等同于统计上显著更强",
            "公平调整视图",
            "原始对局视图（不参与强度门禁）",
            "A/B 行为画像",
            "Choice 请求覆盖",
            "搜索深度门禁",
            "延迟诊断（不参与门禁）",
            "协议、执行与恢复",
            PROTOCOL_ID,
            "main_matches",
            payload["task_manifest_id"][:16],
            "test-nightly",
            "evidence shards 50",
            "restored 0",
            "written 950",
            "not_recorded",
            "全部对局明细",
            "const matches=",
            '"seed":299',
        ):
            self.assertIn(text, html)
        self.assertNotIn("https://cdn", html)

    def test_failed_gate_reasons_are_rendered(self):
        payload = _nightly_result()
        payload["strength"]["mirror"]["overall"]["ci95"]["lower"] = -0.03
        validation = validate_evaluation_gate(payload, gate="nightly-equivalence")
        html = render_report(payload, validation)
        self.assertIn("mirror_ci_below_floor", html)
        self.assertIn("门禁未通过", evaluation_verdict(payload, validation))

    def test_report_and_validator_reject_v6(self):
        old = {"schema_version": 6, "artifact_kind": "ai_evaluation_result"}
        with self.assertRaisesRegex(ValueError, "schema v7"):
            render_report(old)
        validation = validate_evaluation_gate(old, gate="quick")
        self.assertIn("schema_version", validation["error_codes"])

    def test_render_file_accepts_validation_artifact(self):
        payload = _nightly_result()
        validation = validate_evaluation_gate(payload, gate="nightly-equivalence")
        with temp_dir() as directory:
            source = Path(directory) / "results.json"
            gate = Path(directory) / "validation.json"
            output = Path(directory) / "report.html"
            source.write_text(json.dumps(payload), encoding="utf-8")
            gate.write_text(json.dumps(validation), encoding="utf-8")
            render_file(source, output, gate)
            self.assertTrue(output.is_file())
            self.assertIn("AI 策略评测 v7", output.read_text(encoding="utf-8"))


class InterfaceAndProfileTests(unittest.TestCase):
    def test_provenance_has_deterministic_component_fingerprints(self):
        repo_root = Path(__file__).parents[2]
        first = build_provenance(repo_root, [], target_platform="windows")
        second = build_provenance(repo_root, [], target_platform="windows")
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        self.assertEqual(first["schema_version"], 7)
        self.assertEqual(first["protocol_id"], PROTOCOL_ID)
        self.assertEqual(len(first["simulation_fingerprint"]), 64)
        self.assertEqual(len(first["analysis_fingerprint"]), 64)
        self.assertEqual(first["product_version"], "0.6.0")
        self.assertEqual(first["release_ai_evaluation_schema"], 7)
        for component in (
            "rules",
            "ai",
            "card_data",
            "evaluation_tool",
            "analysis_tool",
        ):
            self.assertEqual(len(first["component_hashes"][component]), 64)
        self.assertIn("git_commit", first)
        self.assertIn("git_dirty", first)
        changed_execution = build_provenance(
            repo_root,
            [],
            target_platform="windows",
            simulation_config={"workers": 12},
        )
        self.assertNotEqual(
            first["simulation_fingerprint"],
            changed_execution["simulation_fingerprint"],
        )
        self.assertEqual(
            first["analysis_fingerprint"],
            changed_execution["analysis_fingerprint"],
        )
        self.assertEqual(
            first["simulation_fingerprint"],
            simulation_fingerprint_from_provenance(first),
        )
        irrelevant = copy.deepcopy(first)
        irrelevant["created_at_unix"] += 1
        self.assertEqual(
            first["simulation_fingerprint"],
            simulation_fingerprint_from_provenance(irrelevant),
        )

    def test_powershell_interface_uses_optional_performance_benchmark(self):
        script = (Path(__file__).parents[2] / "tools" / "evaluate_godot_ai.ps1").read_text(
            encoding="utf-8-sig"
        )
        self.assertNotIn("$Baseline", script)
        self.assertIn("$PerformanceBenchmarkOnly", script)
        self.assertIn("$PerformanceBenchmarkInput", script)
        self.assertIn("Alias('SearchDepthProbeOnly', 'PerformanceProbeOnly')", script)
        self.assertIn("Alias('SearchDepthProbeInput', 'PerformanceProbeInput')", script)
        self.assertIn("$PerformanceBenchmark", script)
        self.assertIn("Where-Object { $_ -ne '--profile' }", script)
        self.assertLess(script.index("validate_ai_evaluation.py"), script.index("render_ai_evaluation_report.py"))

    def test_runner_is_v7_raw_shard_with_behavior_and_provenance(self):
        source = (Path(__file__).parents[2] / "godot" / "tools" / "ai_evaluation_runner.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn("const SCHEMA_VERSION := 7", source)
        self.assertIn('const PROTOCOL_ID := "traditional_ai_evaluation_v7"', source)
        self.assertIn('"artifact_kind": "ai_evaluation_shard"', source)
        self.assertIn('"behavior_by_strategy"', source)
        self.assertIn('"search_depth_samples_by_strategy"', source)
        self.assertIn('"decision_semantic_hash"', source)
        self.assertIn('"completed_unit_ids"', source)
        self.assertIn('"provenance": provenance', source)

    def test_profile_helpers_use_schema_v7_observed_games(self):
        payload = _nightly_result()
        summary = summarize_profile(payload)
        self.assertTrue(summary["enabled"])
        self.assertEqual(summary["games"], 2800)
        candidate = copy.deepcopy(payload)
        candidate["performance_profile"]["segments_ms"]["runner_legal_actions_ms"] = 10.0
        comparison = compare_profiles(payload, candidate)
        self.assertTrue(comparison["same_match_results"])
        self.assertEqual(
            comparison["segments"]["runner_legal_actions_ms"]["ratio"], 0.5
        )

    def test_profile_comparison_ignores_timing_and_shard_provenance(self):
        baseline = _nightly_result()
        candidate = copy.deepcopy(baseline)
        baseline["elapsed_ms"] = 1000
        candidate["elapsed_ms"] = 800
        for index, row in enumerate(candidate["matches"]):
            row["elapsed_ms"] += 9000
            row["average_decision_ms"] = 987.0
            row["task_index"] = 1000 + index
            row["task_shard_index"] = 19
            row["task_shard_count"] = 50
            row["source_shard_index"] = 9
            row["evidence_shard_index"] = 49
            row["evidence_shard_count"] = 50
            for samples in row["search_depth_samples_by_strategy"].values():
                for sample in samples:
                    sample["planner_ms"] *= 0.75
        comparison = compare_profiles(baseline, candidate)
        self.assertTrue(comparison["same_match_results"])
        self.assertTrue(comparison["same_v2_search_traces"])
        self.assertTrue(comparison["equivalent"])
        self.assertAlmostEqual(
            comparison["planner_ms_per_node"]["reduction"], 0.25
        )
        self.assertAlmostEqual(comparison["wall_clock_ms"]["reduction"], 0.2)
        self.assertTrue(
            evaluate_gates(
                comparison,
                require_planner_reduction=0.25,
                require_wall_reduction=0.20,
            )["passed"]
        )

    def test_profile_comparison_fails_closed_on_result_or_trace_change(self):
        baseline = _nightly_result()
        changed_result = copy.deepcopy(baseline)
        changed_result["matches"][0]["winner"] = "A"
        comparison = compare_profiles(baseline, changed_result)
        self.assertFalse(comparison["same_match_results"])
        self.assertFalse(evaluate_gates(comparison)["passed"])

        changed_trace = copy.deepcopy(baseline)
        changed_trace["matches"][0]["search_depth_samples_by_strategy"]["A"][0][
            "nodes_expanded"
        ] += 1
        comparison = compare_profiles(baseline, changed_trace)
        self.assertTrue(comparison["same_match_results"])
        self.assertFalse(comparison["same_v2_search_traces"])
        self.assertFalse(evaluate_gates(comparison)["passed"])

    def test_profile_performance_gate_rejects_missing_planner_ms(self):
        baseline = _nightly_result()
        candidate = copy.deepcopy(baseline)
        baseline["elapsed_ms"] = 1000
        candidate["elapsed_ms"] = 700
        for row in baseline["matches"]:
            for samples in row["search_depth_samples_by_strategy"].values():
                for sample in samples:
                    sample.pop("planner_ms", None)
        comparison = compare_profiles(baseline, candidate)
        self.assertTrue(comparison["equivalent"])
        self.assertFalse(comparison["planner_ms_per_node"]["available"])
        gate = evaluate_gates(
            comparison,
            require_planner_reduction=0.25,
            require_wall_reduction=0.20,
        )
        self.assertFalse(gate["passed"])
        self.assertIn(
            "planner_metric_unavailable",
            [error["code"] for error in gate["errors"]],
        )

    def test_profile_comparison_cli_enforces_optional_reduction_gates(self):
        baseline = _nightly_result()
        candidate = copy.deepcopy(baseline)
        baseline["elapsed_ms"] = 1000
        candidate["elapsed_ms"] = 800
        for row in candidate["matches"]:
            for samples in row["search_depth_samples_by_strategy"].values():
                for sample in samples:
                    sample["planner_ms"] *= 0.75
        script = (
            Path(__file__).parents[1]
            / "scripts"
            / "compare_ai_evaluation_profiles.py"
        )
        with temp_dir() as directory:
            baseline_path = Path(directory) / "baseline.json"
            candidate_path = Path(directory) / "candidate.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            candidate_path.write_text(json.dumps(candidate), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--baseline",
                    str(baseline_path),
                    "--candidate",
                    str(candidate_path),
                    "--require-planner-reduction",
                    "0.25",
                    "--require-wall-reduction",
                    "0.20",
                    "--json",
                ],
                capture_output=True,
                check=False,
                encoding="utf-8",
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(json.loads(completed.stdout)["gate"]["passed"])


if __name__ == "__main__":
    unittest.main()

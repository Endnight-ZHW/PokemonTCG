import copy
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.ai_evaluation_v6 import (
    BOOTSTRAP_ITERATIONS,
    DECK_ORDER,
    MergeError,
    expected_match_identities,
    experimental_units,
    merge_payloads,
    summarize_behavior,
    summarize_observed,
    summarize_performance,
    summarize_search_depth,
    summarize_strength,
)
from scripts.compare_ai_evaluation_profiles import compare_profiles
from scripts.build_ai_evaluation_provenance import build_provenance
from scripts.render_ai_evaluation_report import (
    evaluation_verdict,
    render_file,
    render_report,
)
from scripts.summarize_ai_evaluation_profile import summarize_profile
from scripts.validate_ai_evaluation import validate_evaluation_gate
from tests.temp_utils import temp_dir


RULES = {"apply_type_matchups": False}
PROVENANCE = {
    "schema_version": 6,
    "fingerprint": "source-fingerprint",
    "source_hash": "abc123",
}


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
        "decision_ms_samples_by_strategy": {"A": [10.0], "B": [11.0]},
        "turn_plan_cache_hit_samples_by_strategy": {"A": [True], "B": [True]},
        "ai_turn_ms_samples_by_strategy": {"A": [20.0], "B": [21.0]},
        "decision_diagnostics": {},
        "decision_diagnostics_by_strategy": {"A": {}, "B": {}},
        "behavior_by_strategy": _behavior(),
        "search_depth_samples_by_strategy": {
            "A": [{
                "requested": 8,
                "reached": 8,
                "completed": 8,
                "max_path_depth": 8,
                "reply_completed": 3,
                "layers_completed": 8,
                "completion_reason": "depth_complete",
                "stop_reason": "depth_complete",
                "engine_id": "turn_beam_v2",
                "nodes_expanded": 1192,
                "trajectory_hash": "a" * 64,
            }],
            "B": [{
                "requested": 8,
                "reached": 8,
                "completed": 8,
                "max_path_depth": 8,
                "reply_completed": 3,
                "layers_completed": 8,
                "completion_reason": "depth_complete",
                "stop_reason": "depth_complete",
                "engine_id": "turn_beam_v2",
                "nodes_expanded": 1192,
                "trajectory_hash": "b" * 64,
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
    if rows is None:
        rows = [_row(identity) for identity in sorted(expected_match_identities(decks, config))]
    rows = copy.deepcopy(rows)
    for row in rows:
        row["task_shard_index"] = task_shard_index
        row["task_shard_count"] = task_shard_count
    return {
        "schema_version": 6,
        "artifact_kind": "ai_evaluation_shard",
        "platform": "windows",
        "provenance": copy.deepcopy(provenance or PROVENANCE),
        "self_check": fingerprint_a == fingerprint_b,
        "eval_preset": "Custom",
        "mode": mode.lower(),
        "matchup_mode": mode,
        "deck_keys": decks,
        "config": config,
        "strategies": {
            "A": {"id": fingerprint_a, "label": "Candidate A"},
            "B": {"id": fingerprint_b, "label": "Control B"},
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
        "source": "single_process_probe",
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


def _set_probe_depth(payload, strategy, *, requested=None, reached=None):
    performance = payload["performance"]
    for row in performance["matches"]:
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
    measured = [
        row for row in performance["matches"] if row["sample_phase"] == "measurement"
    ]
    performance["search_depth"] = summarize_search_depth(measured, DECK_ORDER)


def _nightly_result(*, distinct=True, side_values=None):
    pair_keys = [
        f"{left}_and_{right}"
        for index, left in enumerate(DECK_ORDER)
        for right in DECK_ORDER[index + 1 :]
    ]
    fingerprint_b = "strategy-b" if distinct else "strategy-a"
    return {
        "schema_version": 6,
        "artifact_kind": "ai_evaluation_result",
        "platform": "windows",
        "provenance": copy.deepcopy(PROVENANCE),
        "self_check": not distinct,
        "eval_preset": "Nightly",
        "matchup_mode": "Balanced",
        "deck_keys": list(DECK_ORDER),
        "config": {
            **_config(DECK_ORDER, seed_blocks=50, cross_blocks=10, mode="Balanced"),
            "eval_preset": "Nightly",
            "seed_block_count": 50,
        },
        "strategies": {"A": {"id": "strategy-a"}, "B": {"id": fingerprint_b}},
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
        "coverage": {
            "complete": True,
            "expected_games": 2800,
            "actual_games": 2800,
            "expected_mirror_units": 500,
            "complete_mirror_units": 500,
            "clean_mirror_units": 500,
            "expected_cross_units": 450,
            "complete_cross_units": 450,
            "clean_cross_units": 450,
            "missing_match_count": 0,
            "unexpected_match_count": 0,
            "structural_errors": [],
            "source_task_shard_indices": [0, 1],
            "source_task_shard_counts": [2],
        },
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
        "performance": _performance_result(side_values),
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
        "matches": [],
        "performance_profile": {
            "enabled": True,
            "segments_ms": {"runner_legal_actions_ms": 20.0},
            "counts": {"decisions": 100, "ai_simulations": 200},
        },
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
        right["provenance"]["fingerprint"] = "different"
        with self.assertRaisesRegex(MergeError, "provenance"):
            merge_payloads([left, right])
        right["provenance"] = copy.deepcopy(PROVENANCE)
        right["config"]["seed"] = 18
        with self.assertRaisesRegex(MergeError, "config:seed"):
            merge_payloads([left, right])

    def test_unknown_deck_and_pre_v6_results_are_rejected(self):
        unknown = _shard()
        unknown["deck_keys"] = ["missing"]
        with self.assertRaisesRegex(MergeError, "deck_keys"):
            merge_payloads([unknown])
        old = _shard()
        old["schema_version"] = 5
        with self.assertRaisesRegex(MergeError, "schema_version"):
            merge_payloads([old])

    def test_v6_match_schema_rejects_unaligned_latency_samples(self):
        shard = _shard()
        shard["matches"][0]["turn_plan_cache_hit_samples_by_strategy"]["A"] = []
        with self.assertRaisesRegex(MergeError, "invalid_latency_samples:A"):
            merge_payloads([shard])

    def test_v6_match_schema_requires_valid_search_depth_samples(self):
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
            "layers_completed"
        ] = 7
        with self.assertRaisesRegex(MergeError, "invalid_search_depth_sample"):
            merge_payloads([shard])

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

    def test_search_depth_probe_provenance_mismatch_fails(self):
        config, rows = _probe_rows()
        probe = _shard(
            decks=DECK_ORDER,
            seed_blocks=3,
            cross_blocks=0,
            mode="Mirror",
            rows=rows,
            provenance={"schema_version": 6, "fingerprint": "other"},
        )
        probe["config"] = config
        with self.assertRaisesRegex(MergeError, "search_depth_probe:provenance"):
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
        for row in payload["performance"]["matches"]:
            for sample in row["search_depth_samples_by_strategy"]["A"]:
                sample["engine_id"] = "turn_beam_v1"
        measured = [
            row
            for row in payload["performance"]["matches"]
            if row["sample_phase"] == "measurement"
        ]
        payload["performance"]["search_depth"] = summarize_search_depth(
            measured, DECK_ORDER
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

    def test_search_depth_probe_checks_a_and_b_separately(self):
        payload = _nightly_result(distinct=False)
        _set_probe_depth(payload, "A", reached=2)
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
        _set_probe_depth(payload, "A", requested=5, reached=5)
        result = validate_evaluation_gate(payload, gate="nightly-equivalence")
        self.assertIn("search_depth_requested_below_floor", result["error_codes"])

    def test_probe_requires_exact_20_warmup_and_40_measured(self):
        payload = _nightly_result(distinct=False)
        payload["performance"]["warmup_games"] = 18
        payload["performance"]["measured_games"] = 42
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("search_depth_probe_coverage", result["error_codes"])
        payload = _nightly_result(distinct=False)
        payload["performance"]["config"]["profile"] = True
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("search_depth_probe_coverage", result["error_codes"])

    def test_android_latency_is_also_diagnostic_only(self):
        values = {
            "A": {"decision": 1000.0, "cache": 200.0, "turn": 2000.0},
            "B": {"decision": 1000.0, "cache": 200.0, "turn": 2000.0},
        }
        payload = _nightly_result(distinct=False, side_values=values)
        payload["platform"] = "android"
        payload["config"]["platform"] = "android"
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"], result["error_codes"])
        values["B"]["turn"] = 2000.1
        payload["performance"] = _performance_result(values)
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertTrue(result["valid"], result["error_codes"])

    def test_deep_practical_uses_v5_dual_metric_and_zero_fallback(self):
        payload = _nightly_result()
        payload["eval_preset"] = "Custom"
        payload["config"]["eval_preset"] = "Custom"
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


class ReportTests(unittest.TestCase):
    def test_report_has_structured_gate_dual_heatmaps_behavior_and_all_matches(self):
        payload = _nightly_result()
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
        validation = validate_evaluation_gate(payload, gate="nightly-equivalence")
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

    def test_report_and_validator_reject_v4(self):
        old = {"schema_version": 4, "artifact_kind": "ai_evaluation_result"}
        with self.assertRaisesRegex(ValueError, "schema v6"):
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
            self.assertIn("AI 策略评测 v6", output.read_text(encoding="utf-8"))


class InterfaceAndProfileTests(unittest.TestCase):
    def test_provenance_has_deterministic_component_fingerprints(self):
        repo_root = Path(__file__).parents[2]
        first = build_provenance(repo_root, [], target_platform="windows")
        second = build_provenance(repo_root, [], target_platform="windows")
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        self.assertEqual(first["schema_version"], 6)
        self.assertEqual(first["product_version"], "0.6.0")
        self.assertEqual(first["release_ai_evaluation_schema"], 6)
        for component in ("rules", "ai", "card_data", "evaluation_tool"):
            self.assertEqual(len(first["component_hashes"][component]), 64)
        self.assertIn("git_commit", first)
        self.assertIn("git_dirty", first)

    def test_powershell_interface_uses_search_depth_probe_modes(self):
        script = (Path(__file__).parents[2] / "tools" / "evaluate_godot_ai.ps1").read_text(
            encoding="utf-8-sig"
        )
        self.assertNotIn("$Baseline", script)
        self.assertIn("$SearchDepthProbeOnly", script)
        self.assertIn("$SearchDepthProbeInput", script)
        self.assertIn("Alias('PerformanceProbeOnly')", script)
        self.assertIn("Alias('PerformanceProbeInput')", script)
        self.assertIn("Where-Object { $_ -ne '--profile' }", script)
        self.assertLess(script.index("validate_ai_evaluation.py"), script.index("render_ai_evaluation_report.py"))

    def test_runner_is_v5_raw_shard_with_behavior_and_provenance(self):
        source = (Path(__file__).parents[2] / "godot" / "tools" / "ai_evaluation_runner.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn("const SCHEMA_VERSION := 6", source)
        self.assertIn('"artifact_kind": "ai_evaluation_shard"', source)
        self.assertIn('"behavior_by_strategy"', source)
        self.assertIn('"search_depth_samples_by_strategy"', source)
        self.assertIn('"provenance": provenance', source)

    def test_profile_helpers_use_schema_v6_observed_games(self):
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


if __name__ == "__main__":
    unittest.main()

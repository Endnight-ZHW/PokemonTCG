import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.merge_ai_evaluation_shards import (
    MergeError,
    _summarize_role_crossover,
    merge_payloads,
)
from scripts.compare_ai_evaluation_profiles import compare_profiles
from scripts.render_ai_evaluation_report import (
    DECK_LABELS,
    evaluation_verdict,
    render_file,
    render_report,
)
from scripts.summarize_ai_evaluation_profile import summarize_profile
from scripts.validate_ai_evaluation import validate_evaluation_gate
from tests.temp_utils import temp_dir


def _schema2_payload(**summary_overrides):
    summary = {
        "games": 40,
        "wins": 22,
        "losses": 18,
        "draws": 0,
        "point_rate": 0.55,
        "win_rate": 0.55,
        "paired_pairs": 20,
        "paired_point_delta": 0.05,
        "paired_delta_ci95": {"lower": 0.02, "upper": 0.08, "samples": 400},
        "probability_a_better": 0.98,
        "max_action_exhaustion_rate": 0.0,
        "max_actions_exhaustions": 0,
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "decision_ms_p95": 12.0,
    }
    summary.update(summary_overrides)
    return {
        "schema_version": 2,
        "self_check": False,
        "eval_preset": "Nightly",
        "mode": "mirror",
        "deck_keys": ["fire", "water"],
        "strategy_fingerprint": {"A": "a", "B": "b", "equal": False},
        "strategies": {
            "A": {"id": "a", "label": "策略A"},
            "B": {"id": "b", "label": "策略B"},
        },
        "summary": summary,
        "per_deck": {
            "fire": {"point_rate": 0.55, "paired_point_delta": 0.04},
            "water": {"point_rate": 0.55, "paired_point_delta": 0.06},
        },
        "per_matchup": {
            "fire_vs_water": {"paired_point_delta": 0.04},
            "water_vs_fire": {"paired_point_delta": 0.06},
        },
        "decision_diagnostics": {
            "total": 0,
            "labels": {"missed_immediate_ko": 0},
        },
        "golden_scenarios": {"total": 1, "passed": 1, "failed": 0, "cases": []},
        "seat": {"seat_counts": {"a_player_0": 20, "a_player_1": 20}},
        "terminal_reasons": {"game_over": 40},
        "matches": [],
    }


def _match(
    deck: str,
    block: int,
    seat: int,
    winner: str,
    *,
    task_index: int | None = None,
    task_shard_index: int = 0,
    task_shard_count: int = 1,
) -> dict:
    if task_index is None:
        task_index = block
    return {
        "deck": deck,
        "strategy_a_deck": deck,
        "strategy_b_deck": deck,
        "player_decks": [deck, deck],
        "matchup_key": f"{deck}_vs_{deck}",
        "matchup_kind": "mirror",
        "task_index": task_index,
        "task_shard_index": task_shard_index,
        "task_shard_count": task_shard_count,
        "pair_key": f"{deck}:{deck}:{block}:{17 + block * 10007}",
        "seed": 17 + block * 10007,
        "seed_block": block,
        "seat": seat,
        "strategy_a_player": 0 if seat == 0 else 1,
        "forced_first_player": block % 2,
        "strategy_a_first": (0 if seat == 0 else 1) == block % 2,
        "winner": winner,
        "engine_winner": 0 if winner == "A" else 1,
        "score": 1000.0 if winner == "A" else -1000.0,
        "terminal_reason": "game_over",
        "terminal_message": "",
        "actions": 10,
        "turns": 3,
        "decisions": 10,
        "choices": 2,
        "average_decision_ms": 5.0,
        "decision_ms_samples": [5.0] * 12,
        "decision_ms_samples_by_strategy": {
            "A": [5.0] * 6,
            "B": [5.0] * 6,
        },
        "turn_plan_cache_hit_samples": [False, True] * 6,
        "turn_plan_cache_hit_samples_by_strategy": {
            "A": [False, True] * 3,
            "B": [False, True] * 3,
        },
        "ai_turn_ms_samples": [15.0, 20.0, 25.0],
        "ai_turn_ms_samples_by_strategy": {
            "A": [15.0, 20.0],
            "B": [25.0],
        },
        "elapsed_ms": 100,
        "decision_diagnostics": {"missed_immediate_ko": 0},
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "time_capped_decisions": 0,
        "max_actions_exhausted": False,
    }


def _shard(
    block: int,
    *,
    fingerprint: str = "same",
    seed: int = 17,
    task_shard_index: int = 0,
    task_shard_count: int = 1,
) -> dict:
    return {
        "schema_version": 4,
        "platform": "windows",
        "self_check": False,
        "eval_preset": "Smoke",
        "mode": "mirror",
        "matchup_mode": "Mirror",
        "deck_keys": ["fire"],
        "config": {
            "seed": seed,
            "seed_blocks_per_deck": 2,
            "cross_seed_blocks_per_matchup": 0,
            "seed_block_start": block,
            "seed_block_count": 1,
            "task_start": block,
            "task_count": 1,
            "task_shard_index": task_shard_index,
            "task_shard_count": task_shard_count,
            "task_candidates": 2,
            "task_pairs_run": 1,
            "max_actions": 80,
            "eval_preset": "Smoke",
            "matchup_mode": "Mirror",
            "skip_golden": False,
            "profile": True,
            "disable_ai_cache": False,
            "disable_native_math": False,
            "rules_options": {"apply_type_matchups": False},
            "decision_latency_sampling": "per_decision",
            "ai_turn_latency_sampling": "completed_turn_wall_clock",
            "platform": "windows",
        },
        "strategies": {"A": {"id": "a"}, "B": {"id": "b"}},
        "strategy_fingerprint": {
            "A": fingerprint,
            "B": fingerprint,
            "equal": True,
            "rules_options": {"apply_type_matchups": False},
        },
        "summary": {"games": 2},
        "per_deck": {},
        "per_matchup": {},
        "matrix": {},
        "paired": {},
        "seat": {},
        "decision_diagnostics": {"total": 0, "labels": {"missed_immediate_ko": 0}},
        "golden_scenarios": {
            "total": 1,
            "passed": 1,
            "failed": 0,
            "cases": [{"name": "immediate_ko", "passed": True}],
        },
        "performance_profile": {
            "enabled": True,
            "segments_ms": {
                "runner_setup_game_ms": 1.5,
                "ai_determinize_ms": 2.0,
            },
            "counts": {
                "matches": 2,
                "ai_simulations": 4,
            },
        },
        "terminal_reasons": {},
        "matches": [
            _match(
                "fire",
                block,
                0,
                "A",
                task_index=block,
                task_shard_index=task_shard_index,
                task_shard_count=task_shard_count,
            ),
            _match(
                "fire",
                block,
                1,
                "B",
                task_index=block,
                task_shard_index=task_shard_index,
                task_shard_count=task_shard_count,
            ),
        ],
    }


def _merged_latency_payload(
    *,
    decision_ms: float,
    cache_hit_ms: float,
    ai_turn_ms: float,
    decision_ms_b: float | None = None,
    cache_hit_ms_b: float | None = None,
    ai_turn_ms_b: float | None = None,
) -> dict:
    decision_b = decision_ms if decision_ms_b is None else decision_ms_b
    cache_hit_b = cache_hit_ms if cache_hit_ms_b is None else cache_hit_ms_b
    ai_turn_b = ai_turn_ms if ai_turn_ms_b is None else ai_turn_ms_b
    shard = _shard(0)
    for row in shard["matches"]:
        flags_by_strategy = {
            "A": [False, True] * 3,
            "B": [False, True] * 3,
        }
        decisions_by_strategy = {
            "A": [
                cache_hit_ms if cache_hit else decision_ms
                for cache_hit in flags_by_strategy["A"]
            ],
            "B": [
                cache_hit_b if cache_hit else decision_b
                for cache_hit in flags_by_strategy["B"]
            ],
        }
        turns_by_strategy = {
            "A": [ai_turn_ms] * 2,
            "B": [ai_turn_b],
        }
        row["decision_ms_samples_by_strategy"] = decisions_by_strategy
        row["turn_plan_cache_hit_samples_by_strategy"] = flags_by_strategy
        row["ai_turn_ms_samples_by_strategy"] = turns_by_strategy
        row["decision_ms_samples"] = (
            decisions_by_strategy["A"] + decisions_by_strategy["B"]
        )
        row["turn_plan_cache_hit_samples"] = (
            flags_by_strategy["A"] + flags_by_strategy["B"]
        )
        row["average_decision_ms"] = sum(row["decision_ms_samples"]) / len(
            row["decision_ms_samples"]
        )
        row["ai_turn_ms_samples"] = turns_by_strategy["A"] + turns_by_strategy["B"]
    return merge_payloads([shard])


class AIEvaluationReportTests(unittest.TestCase):
    def test_report_contains_release_decks_and_core_metrics(self):
        with temp_dir() as tmpdir:
            input_path = os.path.join(tmpdir, "results.json")
            output_path = os.path.join(tmpdir, "report.html")
            payload = {
                "schema_version": 1,
                "self_check": False,
                "mode": "mirror",
                "deck_keys": list(DECK_LABELS),
                "strategies": {
                    "A": {"id": "a", "label": "策略A"},
                    "B": {"id": "b", "label": "策略B"},
                },
                "summary": {
                    "games": 20,
                    "wins": 11,
                    "losses": 8,
                    "draws": 1,
                    "point_rate": 0.575,
                    "win_rate": 0.55,
                    "elo_delta": 52.5,
                    "average_decision_ms": 12.3,
                    "max_actions_exhaustions": 0,
                    "invalid_actions": 0,
                    "choice_failures": 0,
                    "rule_exceptions": 0,
                },
                "per_deck": {
                    deck: {
                        "games": 2,
                        "wins": 1,
                        "losses": 1,
                        "draws": 0,
                        "point_rate": 0.5,
                        "average_score": 0.0,
                        "average_decision_ms": 10.0,
                    }
                    for deck in DECK_LABELS
                },
                "seat": {
                    "seat_counts": {"a_player_0": 10, "a_player_1": 10},
                    "strategy_a_first": {
                        "wins": 5,
                        "draws": 0,
                        "losses": 5,
                        "point_rate": 0.5,
                        "average_score": 0.0,
                    },
                    "strategy_a_second": {
                        "wins": 6,
                        "draws": 1,
                        "losses": 3,
                        "point_rate": 0.65,
                        "average_score": 10.0,
                    },
                },
                "terminal_reasons": {"game_over": 20},
                "matches": [],
            }
            with open(input_path, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, ensure_ascii=False)

            render_file(input_path=Path(input_path), output_path=Path(output_path))

            with open(output_path, "r", encoding="utf-8") as fh:
                html = fh.read()
            self.assertIn("结论", html)
            self.assertIn("A 点数率", html)
            self.assertIn("缓存命中 P95", html)
            self.assertIn("完整 AI 回合 P95", html)
            self.assertIn("牌组结果矩阵", html)
            self.assertIn("对局明细", html)
            for deck_key, label in DECK_LABELS.items():
                self.assertIn(deck_key, html)
                self.assertIn(label, html)

    def test_verdict_suppresses_strength_when_strategies_match(self):
        payload = _schema2_payload()
        payload["strategy_fingerprint"] = {"A": "same", "B": "same", "equal": True}

        self.assertIn("无强度结论", evaluation_verdict(payload))

    def test_verdict_marks_max_action_exhaustion_unreliable(self):
        payload = _schema2_payload(
            max_action_exhaustion_rate=1.0,
            max_actions_exhaustions=40,
        )

        self.assertIn("评测不可靠", evaluation_verdict(payload))

    def test_verdict_uses_paired_confidence_for_clear_leaders(self):
        self.assertIn("策略 A 显著领先", evaluation_verdict(_schema2_payload()))

        payload = _schema2_payload(
            paired_point_delta=-0.05,
            paired_delta_ci95={"lower": -0.09, "upper": -0.02, "samples": 400},
            probability_a_better=0.02,
        )
        self.assertIn("策略 B 显著领先", evaluation_verdict(payload))

    def test_verdict_requires_enough_paired_samples(self):
        payload = _schema2_payload(games=10, paired_pairs=5)

        self.assertIn("样本不足", evaluation_verdict(payload))

    def test_nightly_gate_allows_legal_time_capped_decisions(self):
        payload = _schema2_payload(time_capped_decision_rate=0.01)

        result = validate_evaluation_gate(payload, gate="nightly")

        self.assertTrue(result["valid"])
        self.assertNotIn("time_capped_decision_rate", result["errors"])

    def test_nightly_alias_remains_stability_without_absolute_win_floor(self):
        payload = _schema2_payload(point_rate=0.10)
        payload["self_check"] = True
        payload["strategy_fingerprint"] = {"A": "same", "B": "same", "equal": True}
        for stats in payload["per_deck"].values():
            stats["point_rate"] = 0.10

        result = validate_evaluation_gate(payload, gate="nightly")

        self.assertTrue(result["valid"])
        self.assertEqual(result["gate"], "nightly-stability")
        self.assertNotIn("paired_delta_not_positive", result["errors"])

    def test_equivalence_gate_allows_statistical_ties(self):
        payload = _schema2_payload(
            paired_point_delta=-0.005,
            paired_delta_ci95={"lower": -0.02, "upper": 0.01, "samples": 400},
            probability_a_better=0.45,
        )
        payload["strategy_fingerprint"] = {"A": "same", "B": "same", "equal": True}

        result = validate_evaluation_gate(payload, gate="equivalence")

        self.assertTrue(result["valid"])
        self.assertEqual(result["gate"], "nightly-equivalence")

    def test_equivalence_gate_uses_strategy_diagnostic_delta(self):
        payload = _schema2_payload()
        payload["decision_diagnostics"] = {
            "total": 6,
            "labels": {"weak_attack_before_development": 6},
            "by_strategy": {
                "A": {"total": 2, "labels": {"weak_attack_before_development": 2}},
                "B": {"total": 4, "labels": {"weak_attack_before_development": 4}},
                "delta": {"total": -2, "labels": {"weak_attack_before_development": -2}},
            },
        }

        self.assertTrue(validate_evaluation_gate(payload, gate="equivalence")["valid"])

        payload["decision_diagnostics"]["by_strategy"]["delta"]["total"] = 1
        self.assertIn(
            "decision_diagnostics_regression",
            validate_evaluation_gate(payload, gate="equivalence")["errors"],
        )

    def test_old_schema_report_keeps_heuristic_verdict_and_overall_performance(self):
        payload = _schema2_payload()
        html = render_report(payload)

        self.assertIn("策略 A 显著领先", evaluation_verdict(payload))
        self.assertIn("P95 决策", html)
        self.assertIn("12.0 ms", html)
        self.assertNotIn("A-only", html)
        self.assertNotIn("正式 Nightly 强度验收", html)

    def test_equivalence_gate_rejects_statistical_regressions(self):
        payload = _schema2_payload(
            paired_delta_ci95={"lower": -0.021, "upper": 0.01, "samples": 400},
        )
        self.assertIn(
            "paired_delta_ci_below_equivalence_floor",
            validate_evaluation_gate(payload, gate="nightly-equivalence")["errors"],
        )

        weak_deck = _schema2_payload()
        weak_deck["per_deck"]["water"]["paired_point_delta"] = -0.041
        self.assertIn(
            "water:paired_delta_below_equivalence_floor",
            validate_evaluation_gate(weak_deck, gate="nightly-equivalence")["errors"],
        )

        weak_matchup = _schema2_payload()
        weak_matchup["per_matchup"]["fire_vs_water"]["paired_point_delta"] = -0.081
        self.assertIn(
            "fire_vs_water:paired_delta_below_equivalence_floor",
            validate_evaluation_gate(weak_matchup, gate="nightly-equivalence")["errors"],
        )

    def test_auto_gate_uses_stability_for_self_check(self):
        payload = _schema2_payload(
            paired_point_delta=0.0,
            probability_a_better=0.5,
            paired_delta_ci95={"lower": -0.1, "upper": 0.1, "samples": 400},
        )
        payload["self_check"] = True
        payload["strategy_fingerprint"] = {"A": "same", "B": "same", "equal": True}

        result = validate_evaluation_gate(payload, gate="auto")

        self.assertTrue(result["valid"])
        self.assertEqual(result["gate"], "nightly-stability")

    def test_auto_gate_uses_equivalence_for_distinct_current_strategies(self):
        payload = _schema2_payload(
            paired_point_delta=-0.005,
            paired_delta_ci95={"lower": -0.02, "upper": 0.01, "samples": 400},
        )
        payload["self_check"] = False
        payload["strategy_fingerprint"] = {
            "A": "current-a",
            "B": "current-b",
            "equal": False,
        }

        result = validate_evaluation_gate(payload, gate="auto")

        self.assertTrue(result["valid"])
        self.assertEqual(result["gate"], "nightly-equivalence")

    def test_role_crossover_summary_neutralizes_a_deck_sweep(self):
        rows = []
        for direction_index, (deck_a, deck_b) in enumerate(
            (("fire", "water"), ("water", "fire"))
        ):
            for seat in (0, 1):
                winner = "A" if deck_a == "water" else "B"
                row = _match(deck_a, 0, seat, winner, task_index=direction_index)
                strategy_a_player = int(row["strategy_a_player"])
                row.update(
                    {
                        "strategy_a_deck": deck_a,
                        "strategy_b_deck": deck_b,
                        "player_decks": (
                            [deck_a, deck_b]
                            if strategy_a_player == 0
                            else [deck_b, deck_a]
                        ),
                        "matchup_key": f"{deck_a}_vs_{deck_b}",
                        "matchup_kind": "cross",
                        "pair_key": f"{deck_a}:{deck_b}:0:50000017",
                        "role_crossover_block_key": "fire_and_water:0:50000017",
                        "seed": 50000017,
                        "forced_first_player": 0,
                        "strategy_a_first": strategy_a_player == 0,
                        "engine_winner": (
                            strategy_a_player
                            if winner == "A"
                            else 1 - strategy_a_player
                        ),
                    }
                )
                rows.append(row)

        summary = _summarize_role_crossover(rows)["overall"]

        self.assertEqual(summary["games"], 4)
        self.assertEqual(summary["complete_blocks"], 1)
        self.assertEqual(summary["clean_blocks"], 1)
        self.assertTrue(summary["role_balanced"])
        self.assertEqual(summary["role_crossover_adjusted_point_rate"], 0.5)

    def test_stability_gate_rejects_decision_and_golden_failures(self):
        payload = _schema2_payload()
        payload["decision_diagnostics"] = {
            "total": 1,
            "labels": {"missed_immediate_ko": 1},
        }
        self.assertIn(
            "decision_diagnostics_nonzero",
            validate_evaluation_gate(payload, gate="stability")["errors"],
        )

        payload = _schema2_payload()
        payload["golden_scenarios"] = {
            "total": 1,
            "passed": 0,
            "failed": 1,
            "cases": [{"name": "immediate_ko", "passed": False}],
        }
        self.assertIn(
            "golden_scenarios_failed",
            validate_evaluation_gate(payload, gate="stability")["errors"],
        )

    def test_self_check_stability_uses_paired_diagnostic_delta(self):
        payload = _schema2_payload()
        payload["self_check"] = True
        payload["strategy_fingerprint"] = {
            "A": "same",
            "B": "same",
            "equal": True,
        }
        payload["decision_diagnostics"] = {
            "total": 30,
            "labels": {"missed_immediate_ko": 10},
            "by_strategy": {
                "A": {"total": 15},
                "B": {"total": 15},
                "delta": {"total": 0},
            },
        }

        self.assertTrue(
            validate_evaluation_gate(payload, gate="stability")["valid"]
        )

    def test_merge_shards_recomputes_schema4_metrics(self):
        merged = merge_payloads([_shard(0), _shard(1)], workers=2)

        self.assertEqual(merged["schema_version"], 4)
        self.assertEqual(merged["platform"], "windows")
        self.assertEqual(merged["config"]["platform"], "windows")
        self.assertEqual(merged["summary"]["games"], 4)
        self.assertEqual(merged["summary"]["paired_pairs"], 2)
        self.assertEqual(merged["per_deck"]["fire"]["games"], 4)
        self.assertEqual(merged["per_matchup"]["fire_vs_fire"]["games"], 4)
        self.assertEqual(merged["matrix"]["fire"]["fire"]["games"], 4)
        self.assertEqual(merged["decision_diagnostics"]["total"], 0)
        self.assertEqual(merged["decision_diagnostics"]["by_strategy"]["delta"]["total"], 0)
        self.assertEqual(merged["golden_scenarios"]["failed"], 0)
        self.assertEqual(merged["seat"]["seat_counts"], {"a_player_0": 2, "a_player_1": 2})
        self.assertEqual(merged["terminal_reasons"], {"game_over": 4})
        self.assertEqual(merged["config"]["parallel_workers"], 2)
        self.assertEqual(merged["config"]["task_start"], 0)
        self.assertEqual(merged["config"]["task_count"], 0)
        self.assertEqual(merged["config"]["task_shard_count"], 1)
        self.assertEqual(merged["config"]["task_pairs_run"], 2)
        self.assertTrue(merged["performance_profile"]["enabled"])
        self.assertEqual(merged["performance_profile"]["segments_ms"]["runner_setup_game_ms"], 3.0)
        self.assertEqual(merged["performance_profile"]["counts"]["ai_simulations"], 8)
        self.assertTrue(merged["performance_by_strategy"]["available"])
        self.assertEqual(
            merged["performance_by_strategy"]["A"]["decision_ms_sample_count"],
            24,
        )
        self.assertEqual(
            merged["performance_by_strategy"]["B"]["ai_turn_ms_p95"],
            25.0,
        )

    def test_merge_task_shards_recomputes_task_metadata(self):
        merged = merge_payloads([
            _shard(0, task_shard_index=0, task_shard_count=2),
            _shard(1, task_shard_index=1, task_shard_count=2),
        ], workers=2)

        self.assertEqual(merged["summary"]["games"], 4)
        self.assertEqual(merged["config"]["source_task_shard_count"], 2)
        self.assertEqual(merged["config"]["task_shard_count"], 1)
        self.assertEqual(merged["config"]["task_pairs_run"], 2)

    def test_merge_uses_real_per_decision_latency_samples(self):
        shard = _shard(0)
        for row in shard["matches"]:
            row["decisions"] = 10
            row["choices"] = 0
            row["average_decision_ms"] = 10.9
            row["decision_ms_samples"] = [1.0] * 9 + [100.0]
            row["turn_plan_cache_hit_samples"] = [False] * 9 + [True]
            row["decision_ms_samples_by_strategy"] = {
                "A": [1.0] * 5,
                "B": [1.0] * 4 + [100.0],
            }
            row["turn_plan_cache_hit_samples_by_strategy"] = {
                "A": [False] * 5,
                "B": [False] * 4 + [True],
            }

        merged = merge_payloads([shard])

        self.assertEqual(merged["summary"]["decision_ms_sample_count"], 20)
        self.assertEqual(merged["summary"]["average_decision_ms"], 10.9)
        self.assertEqual(merged["summary"]["decision_ms_p95"], 100.0)
        self.assertEqual(merged["summary"]["cache_hit_decision_ms_sample_count"], 2)
        self.assertEqual(merged["summary"]["cache_hit_decision_ms_p95"], 100.0)
        self.assertEqual(merged["summary"]["ai_turn_ms_sample_count"], 6)
        self.assertEqual(merged["summary"]["ai_turn_ms_p95"], 25.0)

    def test_schema4_without_strategy_latency_remains_compatible(self):
        shard = _shard(0)
        for row in shard["matches"]:
            row.pop("decision_ms_samples_by_strategy")
            row.pop("turn_plan_cache_hit_samples_by_strategy")
            row.pop("ai_turn_ms_samples_by_strategy")

        merged = merge_payloads([shard])
        result = validate_evaluation_gate(merged, gate="nightly-stability")

        self.assertFalse(merged["performance_by_strategy"]["available"])
        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["performance_gate_scope"], "overall")

    def test_merge_rejects_rules_option_mismatch(self):
        first = _shard(0)
        second = _shard(1)
        second["config"]["rules_options"]["apply_type_matchups"] = True

        with self.assertRaisesRegex(MergeError, "config:rules_options"):
            merge_payloads([first, second])

    def test_schema4_gate_requires_official_ai_rules_options(self):
        payload = _shard(0)
        payload["config"]["rules_options"]["apply_type_matchups"] = True

        result = validate_evaluation_gate(payload, gate="nightly-stability")

        self.assertIn("rules_options", result["errors"])

    def test_schema4_windows_latency_gate_accepts_exact_thresholds(self):
        payload = _merged_latency_payload(
            decision_ms=900.0,
            cache_hit_ms=100.0,
            ai_turn_ms=1500.0,
        )

        result = validate_evaluation_gate(payload, gate="nightly-stability")

        self.assertTrue(result["valid"], result["errors"])
        self.assertEqual(result["platform"], "windows")
        self.assertEqual(result["latency_thresholds_ms"]["ai_turn_ms_p95"], 1500.0)

    def test_schema4_windows_latency_gate_rejects_each_p95_overage(self):
        cases = (
            (
                {"decision_ms": 901.0, "cache_hit_ms": 100.0, "ai_turn_ms": 1500.0},
                "decision_ms_p95_latency",
            ),
            (
                {"decision_ms": 900.0, "cache_hit_ms": 101.0, "ai_turn_ms": 1500.0},
                "cache_hit_decision_ms_p95_latency",
            ),
            (
                {"decision_ms": 900.0, "cache_hit_ms": 100.0, "ai_turn_ms": 1501.0},
                "ai_turn_ms_p95_latency",
            ),
        )
        for values, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                payload = _merged_latency_payload(**values)
                result = validate_evaluation_gate(payload, gate="nightly-stability")
                self.assertIn(expected_error, result["errors"])

    def test_schema4_android_latency_thresholds_are_available(self):
        payload = _merged_latency_payload(
            decision_ms=1000.0,
            cache_hit_ms=200.0,
            ai_turn_ms=2000.0,
        )
        payload["platform"] = "android"
        payload["config"]["platform"] = "android"

        android = validate_evaluation_gate(
            payload,
            gate="nightly-stability",
        )
        windows = validate_evaluation_gate(
            payload,
            gate="nightly-stability",
            platform="windows",
        )

        self.assertTrue(android["valid"], android["errors"])
        self.assertIn("decision_ms_p95_latency", windows["errors"])
        self.assertIn("cache_hit_decision_ms_p95_latency", windows["errors"])
        self.assertIn("ai_turn_ms_p95_latency", windows["errors"])

    def test_schema4_latency_gate_rejects_missing_real_samples_and_metrics(self):
        no_cache_hits = _shard(0)
        for row in no_cache_hits["matches"]:
            row["turn_plan_cache_hit_samples"] = [False] * len(row["decision_ms_samples"])
            row["turn_plan_cache_hit_samples_by_strategy"] = {
                "A": [False] * len(row["decision_ms_samples_by_strategy"]["A"]),
                "B": [False] * len(row["decision_ms_samples_by_strategy"]["B"]),
            }
        payload = merge_payloads([no_cache_hits])
        result = validate_evaluation_gate(payload, gate="nightly-stability")
        self.assertIn("cache_hit_decision_latency_samples_missing", result["errors"])

        missing_raw = _merged_latency_payload(
            decision_ms=10.0,
            cache_hit_ms=5.0,
            ai_turn_ms=30.0,
        )
        missing_raw["matches"][0].pop("ai_turn_ms_samples")
        result = validate_evaluation_gate(missing_raw, gate="nightly-stability")
        self.assertIn("ai_turn_latency_samples_missing", result["errors"])

        missing_metric = _merged_latency_payload(
            decision_ms=10.0,
            cache_hit_ms=5.0,
            ai_turn_ms=30.0,
        )
        missing_metric["summary"].pop("cache_hit_decision_ms_p95")
        result = validate_evaluation_gate(missing_metric, gate="nightly-stability")
        self.assertIn("cache_hit_decision_ms_p95_missing", result["errors"])

    def test_merge_rejects_unaligned_cache_hit_samples(self):
        shard = _shard(0)
        shard["matches"][0]["turn_plan_cache_hit_samples"].pop()

        with self.assertRaisesRegex(MergeError, "turn_plan_cache_hit_samples:length"):
            merge_payloads([shard])

    def test_profile_summary_reports_hot_path_candidates(self):
        merged = merge_payloads([_shard(0), _shard(1)], workers=2)

        summary = summarize_profile(merged, top=2)

        self.assertTrue(summary["enabled"])
        self.assertEqual(summary["simulations"], 8)
        self.assertEqual(summary["top_segments"][0]["segment"], "ai_determinize_ms")
        self.assertIn("determinization", summary["top_segments"][0]["candidate"])

    def test_profile_compare_checks_equivalence_and_ratios(self):
        baseline = merge_payloads([_shard(0), _shard(1)], workers=2)
        candidate = json.loads(json.dumps(baseline))
        baseline["elapsed_ms"] = 1000
        candidate["elapsed_ms"] = 500
        candidate["performance_profile"]["segments_ms"]["ai_determinize_ms"] = 2.0

        comparison = compare_profiles(baseline, candidate)

        self.assertTrue(comparison["same_match_results"])
        self.assertEqual(comparison["elapsed_ms"]["ratio"], 0.5)
        self.assertEqual(comparison["segments"]["ai_determinize_ms"]["ratio"], 0.5)

    def test_merge_shards_rejects_strategy_mismatch(self):
        with self.assertRaisesRegex(MergeError, "strategy_fingerprint"):
            merge_payloads([_shard(0, fingerprint="a"), _shard(1, fingerprint="b")], workers=2)

    def test_merge_shards_rejects_config_mismatch(self):
        with self.assertRaisesRegex(MergeError, "config:seed"):
            merge_payloads([_shard(0, seed=17), _shard(1, seed=99)], workers=2)


if __name__ == "__main__":
    unittest.main()

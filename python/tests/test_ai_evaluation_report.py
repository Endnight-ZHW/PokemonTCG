import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.merge_ai_evaluation_shards import MergeError, merge_payloads
from scripts.render_ai_evaluation_report import DECK_LABELS, evaluation_verdict, render_file
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
            "fire": {"paired_point_delta": 0.04},
            "water": {"paired_point_delta": 0.06},
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


def _match(deck: str, block: int, seat: int, winner: str) -> dict:
    return {
        "deck": deck,
        "strategy_a_deck": deck,
        "strategy_b_deck": deck,
        "player_decks": [deck, deck],
        "matchup_key": f"{deck}_vs_{deck}",
        "matchup_kind": "mirror",
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
        "elapsed_ms": 100,
        "decision_diagnostics": {"missed_immediate_ko": 0},
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "time_capped_decisions": 0,
        "max_actions_exhausted": False,
    }


def _shard(block: int, *, fingerprint: str = "same", seed: int = 17) -> dict:
    return {
        "schema_version": 3,
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
            "max_actions": 80,
            "eval_preset": "Smoke",
            "matchup_mode": "Mirror",
        },
        "strategies": {"A": {"id": "a"}, "B": {"id": "b"}},
        "strategy_fingerprint": {"A": fingerprint, "B": fingerprint, "equal": True},
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
        "terminal_reasons": {},
        "matches": [
            _match("fire", block, 0, "A"),
            _match("fire", block, 1, "B"),
        ],
    }


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

    def test_nightly_gate_rejects_regressions(self):
        payload = _schema2_payload()
        baseline = _schema2_payload(decision_ms_p95=10.0)

        self.assertTrue(validate_evaluation_gate(payload, gate="nightly", baseline=baseline)["valid"])

        diagnostics = _schema2_payload(invalid_actions=1)
        self.assertIn(
            "diagnostics_nonzero",
            validate_evaluation_gate(diagnostics, gate="nightly")["errors"],
        )
        choice_failure = _schema2_payload(choice_failures=1)
        self.assertIn(
            "diagnostics_nonzero",
            validate_evaluation_gate(choice_failure, gate="nightly")["errors"],
        )
        rule_exception = _schema2_payload(rule_exceptions=1)
        self.assertIn(
            "diagnostics_nonzero",
            validate_evaluation_gate(rule_exception, gate="nightly")["errors"],
        )

        truncated = _schema2_payload(max_action_exhaustion_rate=0.02)
        self.assertIn(
            "max_action_exhaustion_rate",
            validate_evaluation_gate(truncated, gate="nightly")["errors"],
        )

        weak_deck = _schema2_payload()
        weak_deck["per_deck"]["water"]["paired_point_delta"] = -0.04
        self.assertIn(
            "water:paired_delta_below_floor",
            validate_evaluation_gate(weak_deck, gate="nightly")["errors"],
        )

        slow = _schema2_payload(decision_ms_p95=13.0)
        self.assertIn(
            "decision_ms_p95_regression",
            validate_evaluation_gate(slow, gate="nightly", baseline=baseline)["errors"],
        )

    def test_nightly_gate_rejects_time_capped_decisions(self):
        payload = _schema2_payload(time_capped_decision_rate=0.01)

        self.assertIn(
            "time_capped_decision_rate",
            validate_evaluation_gate(payload, gate="nightly")["errors"],
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

    def test_strength_gate_rejects_matchup_floor_regression(self):
        payload = _schema2_payload()
        payload["per_matchup"]["fire_vs_water"]["paired_point_delta"] = -0.09

        self.assertIn(
            "fire_vs_water:paired_delta_below_floor",
            validate_evaluation_gate(payload, gate="strength")["errors"],
        )

    def test_merge_shards_recomputes_schema3_metrics(self):
        merged = merge_payloads([_shard(0), _shard(1)], workers=2)

        self.assertEqual(merged["schema_version"], 3)
        self.assertEqual(merged["summary"]["games"], 4)
        self.assertEqual(merged["summary"]["paired_pairs"], 2)
        self.assertEqual(merged["per_deck"]["fire"]["games"], 4)
        self.assertEqual(merged["per_matchup"]["fire_vs_fire"]["games"], 4)
        self.assertEqual(merged["matrix"]["fire"]["fire"]["games"], 4)
        self.assertEqual(merged["decision_diagnostics"]["total"], 0)
        self.assertEqual(merged["golden_scenarios"]["failed"], 0)
        self.assertEqual(merged["seat"]["seat_counts"], {"a_player_0": 2, "a_player_1": 2})
        self.assertEqual(merged["terminal_reasons"], {"game_over": 4})
        self.assertEqual(merged["config"]["parallel_workers"], 2)

    def test_merge_shards_rejects_strategy_mismatch(self):
        with self.assertRaisesRegex(MergeError, "strategy_fingerprint"):
            merge_payloads([_shard(0, fingerprint="a"), _shard(1, fingerprint="b")], workers=2)

    def test_merge_shards_rejects_config_mismatch(self):
        with self.assertRaisesRegex(MergeError, "config:seed"):
            merge_payloads([_shard(0, seed=17), _shard(1, seed=99)], workers=2)


if __name__ == "__main__":
    unittest.main()

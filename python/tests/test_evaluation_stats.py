from __future__ import annotations

import unittest

from engine.ai.dl.evaluation_stats import (
    empty_evaluation_stats,
    summarize_evaluation_rows,
)


class EvaluationStatsTests(unittest.TestCase):
    def test_empty_contract_is_stable(self):
        stats = empty_evaluation_stats(0)
        self.assertEqual(stats["games"], 0)
        self.assertEqual(stats["game_points"], [])
        self.assertEqual(stats["seat_win_rates"], {"0": 0.0, "1": 0.0})
        self.assertEqual(summarize_evaluation_rows([], 0), stats)

    def test_rows_aggregate_strength_reliability_and_seat_metrics(self):
        rows = [
            (0, 10.0, [], [], {
                "seat": 0,
                "actions": 4,
                "invalid_actions": 1,
                "no_target_actions": 1,
                "decision_seconds": 2.0,
            }),
            (1, -5.0, [], [], {
                "seat": 1,
                "actions": 6,
                "no_target_actions": 1,
                "rule_exceptions": 1,
                "decision_timeouts": 1,
                "decision_seconds": 3.0,
                "max_step_exhaustions": 1,
            }),
            (None, 0.0, [], [], {"seat": 0}),
        ]
        stats = summarize_evaluation_rows(rows, 3)

        self.assertEqual((stats["wins"], stats["losses"], stats["draws"]), (1, 1, 1))
        self.assertEqual(stats["game_points"], [1.0, 0.0, 0.5])
        self.assertEqual(stats["point_rate"], 0.5)
        self.assertEqual(stats["avg_score"], 1.667)
        self.assertEqual(stats["actions"], 10)
        self.assertEqual(stats["invalid_action_rate"], 0.1)
        self.assertEqual(stats["no_target_action_rate"], 0.2)
        self.assertEqual(stats["rule_exception_rate"], 0.1)
        self.assertEqual(stats["decision_timeout_rate"], 0.1)
        self.assertEqual(stats["average_decision_seconds"], 0.5)
        self.assertEqual(stats["max_step_exhaustion_rate"], 0.333333)
        self.assertEqual(stats["seat_win_rates"], {"0": 0.5, "1": 0.0})
        self.assertEqual(stats["seat_win_rate_gap"], 0.5)

    def test_requested_game_denominator_matches_existing_contract(self):
        stats = summarize_evaluation_rows([(0, 9.0, [], [], {})], 3)
        self.assertEqual(stats["games"], 3)
        self.assertEqual(stats["point_rate"], 0.333333)
        self.assertEqual(stats["avg_score"], 3.0)


if __name__ == "__main__":
    unittest.main()

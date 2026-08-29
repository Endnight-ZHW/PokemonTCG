from __future__ import annotations

import unittest

from deep_ai.challenge_arena_stats import (
    paired_bootstrap_interval,
    summarize_games,
)


def _game(
    task_id: str,
    block_id: str,
    score_x2: int,
    *,
    candidate_deck: str = "fire",
    baseline_deck: str = "water",
) -> dict:
    return {
        "task_id": task_id,
        "block_id": block_id,
        "candidate_deck": candidate_deck,
        "baseline_deck": baseline_deck,
        "game_seed": 17,
        "candidate_seat": 0,
        "first_player": 0,
        "candidate_score_x2": score_x2,
        "strength_eligible": True,
        "success": True,
        "terminal": True,
        "truncated": False,
        "turns": 9,
        "candidate_decision_us": 1000,
        "baseline_decision_us": 1000,
        "candidate_nodes": 10,
        "baseline_nodes": 10,
        "candidate_decision_samples_us": [1000],
        "baseline_decision_samples_us": [1000],
        "candidate_planner_samples_us": [900],
        "baseline_planner_samples_us": [900],
        "invalid_actions": 0,
        "illegal_choices": 0,
        "controller_failures": 0,
        "rule_exceptions": 0,
    }


class ChallengeArenaStatsTests(unittest.TestCase):
    def test_paired_bootstrap_is_deterministic_and_block_weighted(self) -> None:
        games = [
            *[_game(f"win-{index}", "large", 2) for index in range(8)],
            *[_game(f"loss-{index}", "small", 0) for index in range(4)],
        ]
        first = paired_bootstrap_interval(games, seed=41, samples=500)
        second = paired_bootstrap_interval(games, seed=41, samples=500)
        self.assertEqual(first, second)
        self.assertAlmostEqual(first["score_rate"], 8 / 12)
        self.assertEqual(first["blocks"], 2)

    def test_summary_emits_strength_performance_and_promotion_gate(self) -> None:
        games = [_game(f"game-{index}", f"block-{index // 4}", 2) for index in range(40)]
        summary = summarize_games(
            games,
            bootstrap_samples=200,
            min_deck_games=1,
        )
        self.assertEqual(summary["record"]["wins"], 40)
        self.assertEqual(summary["integrity"]["structural_errors"], 0)
        self.assertEqual(
            summary["performance"]["candidate"]["decision_ms_p95"],
            1.0,
        )
        self.assertTrue(summary["gates"]["regression"]["passed"])
        self.assertTrue(summary["gates"]["promotion"]["passed"])

    def test_illegal_action_forces_structural_gate_failure(self) -> None:
        game = _game("invalid", "block", 0)
        game.update({
            "success": False,
            "invalid_actions": 1,
            "offending_agent": 0,
        })
        summary = summarize_games([game], bootstrap_samples=20, min_deck_games=1)
        self.assertEqual(summary["integrity"]["structural_errors"], 1)
        self.assertFalse(summary["gates"]["regression"]["passed"])
        self.assertFalse(summary["gates"]["promotion"]["passed"])

    def test_infrastructure_failure_is_excluded_from_strength(self) -> None:
        game = _game("infra", "block", 1)
        game.update({
            "success": False,
            "terminal": False,
            "strength_eligible": False,
            "rule_exceptions": 1,
        })
        summary = summarize_games([game], bootstrap_samples=20)
        self.assertEqual(summary["games"], 1)
        self.assertEqual(summary["strength_games"], 0)
        self.assertIsNone(summary["paired_statistics"]["score_rate"])


if __name__ == "__main__":
    unittest.main()

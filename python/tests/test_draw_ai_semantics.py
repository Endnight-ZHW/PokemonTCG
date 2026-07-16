import unittest

from engine.ai.dl.training import _terminal_reward
from engine.ai.planner import terminal_outcome_value
from engine.ai.training import (
    _finalize_stats,
    _score_game,
    terminal_training_score,
)
from engine.game_state import GameState


class DrawAISemanticsTests(unittest.TestCase):
    def setUp(self):
        self.state = GameState()
        self.state.set_result(
            "DRAW",
            reason="EQUAL_RULE_CONDITIONS",
            conditions=[["NO_POKEMON"], ["NO_POKEMON"]],
        )

    def test_draw_has_no_planner_or_training_winner(self):
        self.assertEqual(self.state.winner, -1)
        self.assertEqual(terminal_outcome_value(self.state, 0), 0.0)
        self.assertEqual(terminal_outcome_value(self.state, 1), 0.0)
        self.assertEqual(terminal_training_score(self.state, 0), 0.0)
        self.assertEqual(terminal_training_score(self.state, 1), 0.0)
        self.assertEqual(_terminal_reward(None, 0.0), 0.0)

    def test_draw_is_half_a_point_without_score_penalty(self):
        score, stats = _score_game(-1, 0.0)
        self.assertEqual(score, 0.0)
        self.assertEqual(stats, {"wins": 0, "losses": 0, "draws": 1})
        aggregate = _finalize_stats(stats)
        self.assertEqual(aggregate["point_rate"], 0.5)


if __name__ == "__main__":
    unittest.main()

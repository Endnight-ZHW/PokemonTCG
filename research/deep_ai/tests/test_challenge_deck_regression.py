from __future__ import annotations

import copy
import unittest

from deep_ai.challenge_arena_stats import paired_deck_effects
from deep_ai.challenge_deck_regression import fixed_opponent_deck_effects


def games():
    treatment, controls = [], []
    for seed in range(10):
        for deck, other, wins_a, wins_b in (("fire", "water", 5, 6), ("water", "fire", 6, 4)):
            row = {"task_id": f"{seed}-{deck}", "block_id": f"pair-{seed}",
                "block_size": 2, "candidate_deck": deck, "baseline_deck": other,
                "game_seed": seed, "candidate_seat": 0, "first_player": 0,
                "max_decisions": 1024, "success": True, "terminal": True,
                "strength_eligible": True, "candidate_score_x2": 2 * int(seed < wins_a)}
            treatment.append(row)
            controls.append({**row, "candidate_score_x2": 2 * int(seed < wins_b)})
    return treatment, controls


class FixedOpponentDeckRegressionTests(unittest.TestCase):
    def test_stronger_other_decks_cannot_hide_a_deck_regression(self):
        treatment, control = games()
        relative = paired_deck_effects(treatment, seed=17, samples=100, alpha=0.05)
        fixed = fixed_opponent_deck_effects(treatment, control, seed=17, samples=100)
        self.assertAlmostEqual(relative["fire"]["score_delta"], 0.1)
        self.assertAlmostEqual(fixed["fire"]["score_delta"], -0.1)

    def test_identical_policies_have_zero_delta_even_for_a_weak_deck(self):
        _, control = games()
        fixed = fixed_opponent_deck_effects(control, copy.deepcopy(control), seed=17, samples=100)
        self.assertEqual(fixed["water"]["baseline_score_rate"], 0.4)
        self.assertEqual(fixed["water"]["score_delta"], 0)
        self.assertEqual(fixed["water"]["score_delta_ci"], [0, 0])

    def test_changed_seed_seat_or_opponent_is_not_a_pair(self):
        for key, value in (("game_seed", 999), ("candidate_seat", 1), ("baseline_deck", "grass")):
            treatment, control = games()
            control[0][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "conditions_do_not_match"):
                fixed_opponent_deck_effects(treatment, control, seed=17)

    def test_incomplete_or_unreliable_controls_cannot_pass(self):
        treatment, control = games()
        with self.assertRaisesRegex(ValueError, "complete_blocks"):
            fixed_opponent_deck_effects(treatment, control[1:], seed=17)
        control[0]["truncated"] = True
        with self.assertRaisesRegex(ValueError, "reliable_complete"):
            fixed_opponent_deck_effects(treatment, control, seed=17)


if __name__ == "__main__":
    unittest.main()

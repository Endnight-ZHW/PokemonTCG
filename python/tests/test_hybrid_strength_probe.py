from __future__ import annotations

import unittest

from scripts.monitor_hybrid_strength import (
    choose_probe_targets,
    paired_probe_stats,
)


class HybridStrengthProbeTests(unittest.TestCase):
    def test_paired_delta_and_interval_use_matching_game_points(self):
        result = paired_probe_stats(
            {"game_points": [1.0, 0.5, 0.0, 1.0]},
            {"game_points": [0.0, 0.5, 1.0, 0.0]},
        )
        self.assertEqual(result["games"], 4)
        self.assertEqual(result["candidate_point_rate"], 0.625)
        self.assertEqual(result["challenge_point_rate"], 0.375)
        self.assertEqual(result["point_delta"], 0.25)
        self.assertLessEqual(result["ci95"][0], result["point_delta"])
        self.assertGreaterEqual(result["ci95"][1], result["point_delta"])

    def test_teacher_probe_runs_first_seen_and_then_each_milestone(self):
        payload = {
            "stage": "teacher",
            "counters": {"teacher_games": {"fire": 120}},
        }
        first = choose_probe_targets(
            batch_id="teacher_fire_00120",
            payload=payload,
            history=[],
            decks=["fire", "water"],
            every_games=100,
        )
        self.assertEqual(first, [("fire", "teacher", 120, 120)])
        history = [
            {
                "checkpoint_batch": "teacher_fire_00120",
                "deck": "fire",
                "stage": "teacher",
                "completed": 120,
            }
        ]
        self.assertEqual(
            choose_probe_targets(
                batch_id="teacher_fire_00180",
                payload=payload,
                history=history,
                decks=["fire", "water"],
                every_games=100,
            ),
            [],
        )
        self.assertEqual(
            choose_probe_targets(
                batch_id="teacher_fire_00200",
                payload=payload,
                history=history,
                decks=["fire", "water"],
                every_games=100,
            ),
            [("fire", "teacher", 200, 200)],
        )

    def test_generation_boundary_probes_every_deck_once(self):
        history = [
            {
                "checkpoint_batch": "generation_2_complete",
                "deck": "fire",
                "stage": "population_generation_2",
            }
        ]
        targets = choose_probe_targets(
            batch_id="generation_2_complete",
            payload={"stage": "population_generation_2"},
            history=history,
            decks=["fire", "water"],
            every_games=100,
        )
        self.assertEqual(
            targets,
            [("water", "population_generation_2", 2, 2)],
        )


if __name__ == "__main__":
    unittest.main()

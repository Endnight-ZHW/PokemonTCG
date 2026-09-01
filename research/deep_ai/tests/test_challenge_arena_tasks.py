from __future__ import annotations

import unittest
from collections import Counter

from deep_ai.challenge_arena import (
    SEAT_FIRST_PLAYER_CLOSURES,
    ArenaAgentSpec,
    generate_tasks,
    pair_game_seed,
    validate_agent_identity,
    validate_equal_search_contract,
)


class ChallengeArenaTaskTests(unittest.TestCase):
    def test_preset_task_counts(self) -> None:
        self.assertEqual(len(generate_tasks("smoke")), 16)
        self.assertEqual(len(generate_tasks("pr")), 160)
        self.assertEqual(len(generate_tasks("nightly")), 12000)
        self.assertEqual(len(generate_tasks("release")), 20000)
        self.assertEqual(len(generate_tasks("calibration")), 8000)
        self.assertEqual(
            len(generate_tasks(
                "focused",
                candidate_decks=("fire", "water"),
                baseline_decks=("grass",),
                replicates=3,
            )),
            24,
        )

    def test_full_matrix_uses_ordered_matchups_and_paired_blocks(self) -> None:
        tasks = generate_tasks("nightly")
        ordered = {
            (task.candidate_deck, task.baseline_deck)
            for task in tasks
            if task.replicate == 0
        }
        self.assertEqual(len(ordered), 100)
        self.assertIn(("fire", "water"), ordered)
        self.assertIn(("water", "fire"), ordered)
        block_sizes = Counter(task.block_id for task in tasks)
        fire_water = next(
            task.block_id
            for task in tasks
            if task.replicate == 0
            and {task.candidate_deck, task.baseline_deck} == {"fire", "water"}
        )
        fire_mirror = next(
            task.block_id
            for task in tasks
            if task.replicate == 0
            and task.candidate_deck == task.baseline_deck == "fire"
        )
        self.assertEqual(block_sizes[fire_water], 8)
        self.assertEqual(block_sizes[fire_mirror], 4)

    def test_every_ordered_matchup_has_all_four_closures(self) -> None:
        tasks = generate_tasks("smoke")
        grouped: dict[tuple[str, str, int], set[tuple[int, int]]] = {}
        for task in tasks:
            grouped.setdefault(
                (task.candidate_deck, task.baseline_deck, task.game_seed),
                set(),
            ).add((task.candidate_seat, task.first_player))
        self.assertTrue(grouped)
        self.assertTrue(all(
            closures == set(SEAT_FIRST_PLAYER_CLOSURES)
            for closures in grouped.values()
        ))

    def test_mirror_only_balances_every_deck_without_cross_category_games(self) -> None:
        decks = (
            "fire", "water", "psychic", "lightning", "fighting",
            "colorless", "dragon", "grass", "steel", "darkness",
        )
        tasks = generate_tasks(
            "focused",
            candidate_decks=decks,
            baseline_decks=decks,
            replicates=10,
            mirror_only=True,
        )
        self.assertEqual(len(tasks), 400)
        self.assertTrue(all(
            task.candidate_deck == task.baseline_deck for task in tasks
        ))
        counts = Counter(task.candidate_deck for task in tasks)
        self.assertEqual(counts, Counter({deck: 40 for deck in decks}))

    def test_mirror_only_rejects_mismatched_deck_sets(self) -> None:
        with self.assertRaisesRegex(ValueError, "mirror_decks_must_match"):
            generate_tasks(
                "focused",
                candidate_decks=("fire", "water"),
                baseline_decks=("fire",),
                mirror_only=True,
            )

    def test_pair_seed_is_direction_symmetric_and_pair_specific(self) -> None:
        self.assertEqual(
            pair_game_seed(17, "fire", "water", 3),
            pair_game_seed(17, "water", "fire", 3),
        )
        self.assertNotEqual(
            pair_game_seed(17, "fire", "water", 3),
            pair_game_seed(17, "fire", "grass", 3),
        )
        self.assertNotEqual(
            pair_game_seed(17, "fire", "water", 3),
            pair_game_seed(17, "fire", "water", 4),
        )

    def test_fixed_search_contract_must_match(self) -> None:
        strategies = {"schema": "test"}
        candidate = ArenaAgentSpec(
            "candidate", "a", strategies, {"belief_samples": 1}
        )
        baseline = ArenaAgentSpec(
            "baseline", "b", strategies, {"belief_samples": 3}
        )
        with self.assertRaisesRegex(ValueError, "search_contract_mismatch"):
            validate_equal_search_contract(candidate, baseline)

    def test_identical_agents_require_explicit_self_play(self) -> None:
        strategies = {"schema": "test"}
        first = ArenaAgentSpec(
            "first", "a", strategies, {"belief_samples": 1},
            implementation_hash="same",
        )
        second = ArenaAgentSpec(
            "second", "b", strategies, {"belief_samples": 1},
            implementation_hash="same",
        )
        with self.assertRaisesRegex(ValueError, "arena_agents_are_identical"):
            validate_agent_identity(first, second, allow_self_play=False)
        validate_agent_identity(first, second, allow_self_play=True)


if __name__ == "__main__":
    unittest.main()

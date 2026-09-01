from __future__ import annotations

import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from deep_ai.deep_arena import (
    DEEP_ARENA_SCHEMA,
    arena_promotion_passed,
    deep_arena_rows,
    deep_arena_task_specs,
    summarize_deep_arena,
)
from deep_ai.evaluation_fairness import unordered_matchups
from deep_ai.trainer_v3 import AlphaZeroV3Config, AlphaZeroV3Trainer
from deep_ai.v3_contract import RELEASE_DECKS


class DeepArenaFairnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = AlphaZeroV3Config(
            output_dir="unused",
            preset="release",
            cycles=1,
        )

    def _specs(self, look_index: int = 0):
        return deep_arena_task_specs(
            unordered_pairs=unordered_matchups(RELEASE_DECKS),
            games_per_direction=4,
            base_seed=500_100_017,
            cycle=1,
            champion_version=0,
            look_index=look_index,
            max_decisions=512,
        )

    def test_complete_look_has_balanced_ordered_matrix(self) -> None:
        specs = self._specs()
        self.assertEqual(len(specs), 400)
        self.assertEqual(
            Counter(spec.candidate_deck for spec in specs),
            Counter({deck: 40 for deck in RELEASE_DECKS}),
        )
        blocks: dict[str, list] = defaultdict(list)
        for spec in specs:
            blocks[spec.block_id].append(spec)
        self.assertEqual(len(blocks), 55)
        self.assertTrue(all(
            len(values) == values[0].block_size
            and len({value.task.seed for value in values}) == 1
            for values in blocks.values()
        ))
        self.assertEqual(
            Counter(len(values) for values in blocks.values()),
            Counter({8: 45, 4: 10}),
        )

    def _rows(self, outcome: str) -> list[dict]:
        specs = self._specs()
        games = []
        by_block: dict[str, int] = defaultdict(int)
        for spec in specs:
            index = by_block[spec.block_id]
            by_block[spec.block_id] += 1
            if outcome == "win":
                winner = spec.task.seat_a
            elif outcome == "loss":
                winner = 1 - spec.task.seat_a
            else:
                winner = spec.task.seat_a if index % 2 == 0 else 1 - spec.task.seat_a
            games.append({
                "game_id": spec.task.game_id,
                "success": True,
                "terminal": True,
                "truncated": False,
                "error": "",
                "winner": winner,
                "decisions": 10,
            })
        return deep_arena_rows(games, specs)

    def test_sequential_strength_statuses(self) -> None:
        wins = summarize_deep_arena(
            self._rows("win"),
            bootstrap_seed=17,
            bootstrap_samples=100,
            confidence_alpha=0.05 / 3,
            promotion_score_rate=0.55,
            final_look=False,
        )
        losses = summarize_deep_arena(
            self._rows("loss"),
            bootstrap_seed=17,
            bootstrap_samples=100,
            confidence_alpha=0.05 / 3,
            promotion_score_rate=0.55,
            final_look=False,
        )
        balanced = summarize_deep_arena(
            self._rows("balanced"),
            bootstrap_seed=17,
            bootstrap_samples=100,
            confidence_alpha=0.05 / 3,
            promotion_score_rate=0.55,
            final_look=False,
        )
        final_balanced = summarize_deep_arena(
            self._rows("balanced"),
            bootstrap_seed=17,
            bootstrap_samples=100,
            confidence_alpha=0.05 / 3,
            promotion_score_rate=0.55,
            final_look=True,
        )
        self.assertEqual(wins["gate_status"], "pass")
        self.assertEqual(losses["gate_status"], "fail")
        self.assertEqual(balanced["gate_status"], "continue")
        self.assertEqual(final_balanced["gate_status"], "inconclusive")

    def test_truncation_excludes_whole_block_and_blocks_promotion(self) -> None:
        rows = self._rows("win")
        rows[0].update({
            "success": False,
            "terminal": False,
            "truncated": True,
            "error": "v3_actor_decision_cap",
            "strength_eligible": False,
        })
        summary = summarize_deep_arena(
            rows,
            bootstrap_seed=17,
            bootstrap_samples=50,
            confidence_alpha=0.05 / 3,
            promotion_score_rate=0.55,
            final_look=False,
        )
        self.assertEqual(summary["gate_status"], "fail")
        self.assertEqual(summary["strength_games"], 396)
        self.assertEqual(
            summary["integrity"]["strength_blocks"]["excluded_blocks"], 1
        )

    def test_new_and_legacy_promotion_contracts_are_dispatched_explicitly(self) -> None:
        self.assertTrue(arena_promotion_passed({
            "schema": DEEP_ARENA_SCHEMA,
            "gate_status": "pass",
        }, legacy_threshold=0.55))
        self.assertFalse(arena_promotion_passed({
            "schema": DEEP_ARENA_SCHEMA,
            "gate_status": "inconclusive",
            "score_rate": 0.9,
        }, legacy_threshold=0.55))
        self.assertTrue(arena_promotion_passed({
            "failed_games": 0,
            "score_rate": 0.55,
        }, legacy_threshold=0.55))
        self.assertFalse(arena_promotion_passed({
            "failed_games": 0,
            "score_rate": None,
        }, legacy_threshold=0.55))

    def test_inconclusive_arena_runs_all_three_looks(self) -> None:
        calls: list[int] = []

        class FakeActors:
            def __init__(self, *_args, **_kwargs) -> None:
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_args) -> None:
                return None

            def run(self, tasks):
                calls.append(len(tasks))
                games = []
                for task in tasks:
                    closure = int(task.game_id.rsplit("-c", 1)[1])
                    winner = task.seat_a if closure % 2 == 0 else 1 - task.seat_a
                    games.append({
                        "game_id": task.game_id,
                        "success": True,
                        "terminal": True,
                        "truncated": False,
                        "error": "",
                        "winner": winner,
                    })
                return {
                    "games": games,
                    "failed_games": 0,
                    "native": {},
                    "inference": {},
                }

        with tempfile.TemporaryDirectory() as directory:
            trainer = object.__new__(AlphaZeroV3Trainer)
            trainer.config = self.config
            trainer.champion = object()
            trainer.champion_version = 0
            trainer.learner = SimpleNamespace(model=object())
            trainer.control = None
            trainer.output_dir = Path(directory)
            with patch(
                "deep_ai.trainer_v3.NativeActorServiceV3", FakeActors
            ):
                arena = trainer._arena(1)
        self.assertEqual(calls, [400, 400, 400])
        self.assertEqual(arena["completed_looks"], 3)
        self.assertEqual(arena["games"], 1200)
        self.assertEqual(arena["gate_status"], "inconclusive")


if __name__ == "__main__":
    unittest.main()

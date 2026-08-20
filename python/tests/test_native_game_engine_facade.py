from __future__ import annotations

import unittest

from data.deck_definitions import DECK_SPECS, expand_deck
from engine.actions import GameAction
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.random_source import RandomSource


class NativeGameEngineFacadeTests(unittest.TestCase):
    def test_setup_query_and_apply_use_native_session(self):
        engine = GameEngine()
        state = GameState()
        rng = RandomSource(123456)
        started = engine.begin_game(
            state,
            expand_deck(DECK_SPECS["fire"]),
            expand_deck(DECK_SPECS["water"]),
            rng,
        )
        self.assertTrue(started.success, started)
        self.assertEqual(started.pending_choice.request_type, "choose_turn_order")
        chosen = engine.apply_choice(
            state,
            engine.choice_manager.default_choice_response(
                started.pending_choice, rng
            ),
            rng,
        )
        self.assertTrue(chosen.success, chosen)
        actor = state.setup_actor_idx
        actions = engine.legal_actions(state, actor)
        self.assertTrue(actions)
        before_revision = state.revision
        applied = engine.apply_action(state, actions[0], rng)
        self.assertTrue(applied.success, applied)
        self.assertEqual(state.revision, before_revision + 1)
        self.assertTrue(getattr(state, "_native_processed_action_ids", []))

    def test_illegal_action_is_fail_closed(self):
        engine = GameEngine()
        state = GameState()
        rng = RandomSource(9)
        started = engine.begin_game(
            state,
            expand_deck(DECK_SPECS["fire"]),
            expand_deck(DECK_SPECS["water"]),
            rng,
        )
        self.assertTrue(started.success)
        before_revision = state.revision
        before_rng = rng.get_native_state()
        rejected = engine.apply_action(
            state,
            GameAction("END_TURN", {}, actor=0),
            rng,
        )
        self.assertFalse(rejected.success)
        self.assertEqual(rejected.error_code, "illegal_action")
        self.assertEqual(state.revision, before_revision)
        self.assertEqual(rng.get_native_state(), before_rng)


if __name__ == "__main__":
    unittest.main()

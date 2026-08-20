from __future__ import annotations

import unittest

from data.deck_definitions import DECK_SPECS, expand_deck
from engine.actions import CardRef, ChoiceOption, ChoiceView
from engine.ai.challenge_ai import AIConfig, create_challenge_ai
from engine.enums import PlayerAction
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import GameState
from engine.random_source import RandomSource


class ChallengeAINativeSmokeTests(unittest.TestCase):
    def test_duplicate_choice_uses_public_maximum_not_option_count(self):
        ai = create_challenge_ai("fire", AIConfig(policy_path=None))
        request = ChoiceView(
            request_id="duplicate-choice",
            base_revision=0,
            request_type="select_cards",
            player=0,
            prompt="选择两次",
            options=(
                ChoiceOption(
                    "only-option",
                    "唯一选项",
                    CardRef(0, "hand", 0, "missing-card"),
                ),
            ),
            min_select=2,
            max_select=2,
            allow_duplicates=True,
        )
        response = ai.resolve_pending_action(GameState(), request)
        self.assertEqual(response.option_ids, ("only-option", "only-option"))

    def test_policy_selects_a_native_legal_action(self):
        state = GameState()
        rng = RandomSource(424242)
        started = DEFAULT_GAME_ENGINE.begin_game(
            state,
            expand_deck(DECK_SPECS["fire"]),
            expand_deck(DECK_SPECS["water"]),
            rng,
        )
        self.assertTrue(started.success, started)
        for _ in range(64):
            if state.setup_stage == "COMPLETE":
                break
            pending = DEFAULT_GAME_ENGINE.pending_choice(state)
            if pending is not None:
                step = DEFAULT_GAME_ENGINE.apply_choice(
                    state,
                    DEFAULT_GAME_ENGINE.choice_manager.default_choice_response(
                        pending, rng
                    ),
                    rng,
                )
            else:
                actor = state.setup_actor_idx
                legal = DEFAULT_GAME_ENGINE.legal_actions(state, actor)
                player = state.get_player(actor)
                selected = next(
                    (
                        action
                        for action in legal
                        if action.kind == PlayerAction.PLAY_BASIC
                        and action.target_slot() == "active"
                        and player.active is None
                    ),
                    next(
                        (
                            action
                            for action in legal
                            if action.kind_name == "SETUP_DONE"
                        ),
                        legal[0],
                    ),
                )
                step = DEFAULT_GAME_ENGINE.apply_action(state, selected, rng)
            self.assertTrue(step.success, step)
        self.assertEqual(state.setup_stage, "COMPLETE")

        actor = state.active_player_idx
        ai = create_challenge_ai(
            "fire" if actor == 0 else "water",
            AIConfig(
                thinking_time_seconds=0.05,
                deterministic_search=True,
                search_node_budget=8,
                planner_max_depth=3,
                policy_path=None,
            ),
        )
        legal = DEFAULT_GAME_ENGINE.legal_actions(state, actor)
        selected = ai.choose_action(state, actor)
        self.assertIn(selected.signature, {action.signature for action in legal})


if __name__ == "__main__":
    unittest.main()

"""Regression coverage for the CN 3.1.0 opening and trigger contracts."""
from __future__ import annotations

import unittest

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK, expand_deck
from engine.actions import ChoiceResponse
from engine.commands.attack_frames import FinalizeAttackKoChecks
from engine.commands.modifier_registration import register_pokemon_modifiers
from engine.commands.resolution_stack import ResolutionStack
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.random_source import RandomSource
from engine.snapshot import canonical_state_payload, state_from_payload


class CnSetupTurnFactsAndTriggersTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def test_turn_order_choice_precedes_hands_and_first_turn_draws(self):
        state = GameState()
        engine = GameEngine()
        rng = RandomSource(17)
        step = engine.begin_game(
            state,
            expand_deck(FIRE_DECK),
            expand_deck(WATER_DECK),
            rng,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.setup_stage, "TURN_ORDER")
        self.assertEqual((len(state.p1.hand), len(state.p2.hand)), (0, 0))
        self.assertEqual(step.pending_choice.request_type, "choose_turn_order")
        self.assertEqual(step.pending_choice.metadata["domain"], "setup")
        self.assertTrue(step.pending_choice.metadata["continuation_frame_id"])

        coin_winner = state.opening_coin_winner_idx
        request = step.pending_choice
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("turn_order:second",)),
            rng,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.first_player_idx, 1 - coin_winner)
        self.assertEqual(state.setup_stage, "INITIAL_PLACEMENT")
        self.assertEqual((len(state.p1.hand), len(state.p2.hand)), (7, 7))

        # Place only mandatory Active Pokemon, then take the maximum bonus.
        while state.setup_stage != "COMPLETE":
            pending = engine.pending_choice_request(state)
            if pending is not None:
                response = engine.choice_manager.default_choice_response(pending, rng)
                step = engine.apply_choice(state, pending, response, rng)
                self.assertTrue(step.success, step.message)
                continue
            actor = state.setup_actor_idx
            actions = engine.legal_actions(state, actor, validate_effects=False)
            active = next(
                (
                    action for action in actions
                    if action.action == PlayerAction.PLAY_BASIC
                    and action.params.get("target") == "active"
                ),
                None,
            )
            action = active or next(
                action for action in actions if action.action == "SETUP_DONE"
            )
            step = engine.apply_action(state, action, rng)
            self.assertTrue(step.success, step.message)

        self.assertEqual(state.phase, TurnPhase.MAIN)
        self.assertEqual(state.turn_number, 1)
        self.assertEqual(len(state.p1.prizes), 6)
        self.assertEqual(len(state.p2.prizes), 6)
        first = state.get_player(state.first_player_idx)
        # 7 opening cards - Active + the normal turn draw (+ optional bonus).
        self.assertGreaterEqual(len(first.hand), 7)

    def test_bonus_drawn_basic_is_bench_only_and_provenance_is_a_multiset(self):
        state = GameState()
        basic = CardRegistry.get("svi-chim")
        state.phase = TurnPhase.SETUP
        state.setup_stage = "BONUS_PLACEMENT"
        state.setup_actor_idx = 0
        state.p1.active = PokemonInPlay(basic)
        state.p1.hand = [basic, basic]
        state.setup_bonus_card_ids = ([basic.api_id], [])

        engine = GameEngine()
        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertFalse(any(action.params.get("target") == "active" for action in actions))
        playable = [action for action in actions if action.action == PlayerAction.PLAY_BASIC]
        self.assertTrue(playable)
        step = engine.apply_action(state, playable[0], RandomSource(1))
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.setup_bonus_card_ids[0], [])
        remaining = engine.legal_actions(state, 0, validate_effects=False)
        self.assertFalse(any(action.action == PlayerAction.PLAY_BASIC for action in remaining))

    def test_turn_fact_book_is_read_only_for_entire_response_turn_and_round_trips(self):
        state = GameState()
        state.turn_number = 3
        state.active_player_idx = 1
        state.begin_turn_fact_window(1, 3)
        state.record_knockout_fact(
            owner=0,
            cause="attack_damage",
            source_player=1,
            card_id="svi-chim",
            slot="active",
        )
        state.active_player_idx = 0
        state.turn_number = 4
        state.begin_turn_fact_window(0, 4)

        for _ in range(2):
            self.assertTrue(state.had_knockout_last_opponent_turn(0))
            self.assertTrue(state.had_knockout_last_opponent_turn(
                0,
                causes={"attack_damage"},
            ))
            self.assertFalse(state.had_knockout_last_opponent_turn(
                0,
                causes={"attack_effect"},
            ))

        restored = state_from_payload(canonical_state_payload(state))
        self.assertTrue(restored.had_knockout_last_opponent_turn(
            0,
            causes={"attack_damage"},
        ))
        self.assertEqual(
            restored.turn_fact_book["previous"]["knockouts"][0]["cause"],
            "attack_damage",
        )

    def test_multiple_exp_share_entities_choose_order_confirm_and_exact_energy(self):
        state = GameState()
        state.phase = TurnPhase.ATTACK
        state.active_player_idx = 1
        state.turn_number = 3
        basic = CardRegistry.get("svi-chim")
        opponent = CardRegistry.get("sv2-delib")
        tool = CardRegistry.get("svg2-exps")
        energies = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
        ]
        state.p1.active = PokemonInPlay(basic)
        state.p1.active.damage_counters = 99
        state.p1.active.pending_ko_cause = "attack_damage"
        state.p1.active.energy_cards = list(energies)
        state.p2.active = PokemonInPlay(opponent)
        state.p1.prizes = [basic] * 6
        state.p2.prizes = [basic] * 6
        for bench_idx in (0, 1):
            state.p1.bench[bench_idx] = PokemonInPlay(basic)
            state.p1.bench[bench_idx].attached_tool = tool
            register_pokemon_modifiers(
                state.p1.bench[bench_idx],
                0,
                f"bench_{bench_idx}",
                event_bus=state.event_bus,
            )

        stack = ResolutionStack(state)
        stack.push(FinalizeAttackKoChecks())
        result = stack.resolve_all(1, "active")
        self.assertEqual(result.pending_choice.request_type, "choose_trigger_order")
        engine = GameEngine()
        request = engine.choice_manager.choice_request(state, result.pending_choice)
        engine.transaction_manager.persist_pending_choice(state, request)

        # Prove the order request and remaining KO batch survive a snapshot.
        state = state_from_payload(canonical_state_payload(state))
        request = engine.pending_choice_request(state)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[1].option_id,)),
            RandomSource(5),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(step.pending_choice.request_type, "confirm_trigger")

        request = step.pending_choice
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
            RandomSource(5),
        )
        self.assertEqual(step.pending_choice.request_type, "select_attachment")
        request = step.pending_choice
        chosen = next(option for option in request.options if option.ref.card_id == energies[1].api_id)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (chosen.option_id,)),
            RandomSource(5),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.bench[1].energy_cards[0].api_id, energies[1].api_id)

    def test_three_entity_energy_cards_and_staryu_use_canonical_source_contracts(self):
        cobalion = CardRegistry.get("svm-cobalion")
        follow_up = cobalion.attacks[0].effects[0]
        self.assertTrue(follow_up.params["select_source"])
        self.assertEqual(follow_up.params["max_per_target"], 1)

        hawlucha = CardRegistry.get("svf-hawl")
        posture = hawlucha.attacks[0].effects[0]
        self.assertTrue(posture.params["select_source"])
        self.assertTrue(posture.params["same_target"])

        marnie = CardRegistry.get("svm-marnie-pride")
        self.assertEqual(marnie.name, "玛俐的自尊")
        self.assertTrue(marnie.trainer_effects[0].params["select_source"])

        staryu = CardRegistry.get("sv2-staryu")
        self.assertEqual(staryu.attacks[0].effects[0].effect_type, "attack_flags")


if __name__ == "__main__":
    unittest.main()

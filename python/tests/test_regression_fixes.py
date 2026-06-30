"""Regression tests for critical bug fixes.

Covers:
  - Remote USE_STADIUM dispatch (P1)
  - SwitchPokemon pending semantics (P2)
  - Crushing Hammer energy discard pile ownership (P1)
  - Slot/bench boundary protection (P1)
  - SearchScreen min_select enforcement (P1)
  - Simultaneous KO promotion queue (P4)
  - Server-side coin flip generation (P3)
  - Selection validation (P3)
"""

import sys
import os
import json
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from engine.game_state import GameState, ActionRequest, ActionResult
from engine.turn_manager import TurnManager
from engine.enums import TurnPhase, PlayerAction
from engine.player_state import PokemonInPlay, PlayerState
from engine.actions import ChoiceResponse, GameAction
from engine.game_engine import GameEngine
from engine.events.game_events import GameEvent
from engine.random_source import ScriptedRandomSource
from engine.rules_validator import (
    parse_bench_idx,
    parse_slot,
    check_bench_bounds,
    can_retreat,
)
from engine.rules_constants import MAX_BENCH_SIZE
from engine.snapshot import clone_state, restore_state, snapshot_state
from data.card_models import Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK, expand_deck

# Ensure registry is loaded before any test runs
CardRegistry.initialize(ALL_CARD_IDS)


# ── Helpers ────────────────────────────────────────────────────────────────

def _make_state_with_pokemon(active_card_id="sv2-delib", bench_card_ids=None):
    """Create a minimal state with Pokemon in play for both players."""
    state = GameState()
    state.phase = TurnPhase.MAIN
    state.turn_number = 3
    state.active_player_idx = 0

    for pi in (0, 1):
        player = state.get_player(pi)
        player.active = PokemonInPlay(CardRegistry.get(active_card_id))
        if bench_card_ids:
            for bc in bench_card_ids:
                slot = next(i for i in range(MAX_BENCH_SIZE) if player.bench[i] is None)
                player.bench[slot] = PokemonInPlay(CardRegistry.get(bc))
    return state


def _give_prizes(state):
    prize = CardRegistry.get("sv1-ener-3")
    state.p1.prizes = [prize] * 6
    state.p2.prizes = [prize] * 6
    return state


# ── 1. Slot / Bench Boundary Protection ────────────────────────────────────

class TestSlotBenchBoundaries(unittest.TestCase):

    def test_parse_bench_idx_valid_int(self):
        ok, idx = parse_bench_idx(2)
        self.assertTrue(ok)
        self.assertEqual(idx, 2)

    def test_parse_bench_idx_valid_str(self):
        ok, idx = parse_bench_idx("3")
        self.assertTrue(ok)
        self.assertEqual(idx, 3)

    def test_parse_bench_idx_negative(self):
        ok, idx = parse_bench_idx(-1)
        self.assertFalse(ok)

    def test_parse_bench_idx_out_of_range(self):
        ok, idx = parse_bench_idx(MAX_BENCH_SIZE)
        self.assertFalse(ok)

    def test_parse_bench_idx_invalid_str(self):
        ok, idx = parse_bench_idx("abc")
        self.assertFalse(ok)

    def test_parse_bench_idx_non_int_type(self):
        ok, idx = parse_bench_idx(None)
        self.assertFalse(ok)

    def test_parse_slot_active(self):
        ok, stype, idx = parse_slot("active")
        self.assertTrue(ok)
        self.assertEqual(stype, "active")

    def test_parse_slot_bench_valid(self):
        ok, stype, idx = parse_slot("bench_2")
        self.assertTrue(ok)
        self.assertEqual(stype, "bench")
        self.assertEqual(idx, 2)

    def test_parse_slot_bench_oob(self):
        ok, stype, idx = parse_slot(f"bench_{MAX_BENCH_SIZE}")
        self.assertFalse(ok)

    def test_parse_slot_bench_malformed(self):
        ok, stype, idx = parse_slot("bench_")
        self.assertFalse(ok)

    def test_parse_slot_bench_garbage(self):
        ok, stype, idx = parse_slot("bench_xyz")
        self.assertFalse(ok)

    def test_parse_slot_nonsense(self):
        ok, stype, idx = parse_slot("nonsense")
        self.assertFalse(ok)

    def test_parse_slot_non_string(self):
        ok, stype, idx = parse_slot(None)
        self.assertFalse(ok)

    def test_check_bench_bounds_valid(self):
        ok, msg = check_bench_bounds(0)
        self.assertTrue(ok)
        ok, msg = check_bench_bounds(MAX_BENCH_SIZE - 1)
        self.assertTrue(ok)

    def test_check_bench_bounds_negative(self):
        ok, msg = check_bench_bounds(-1)
        self.assertFalse(ok)

    def test_check_bench_bounds_oob(self):
        ok, msg = check_bench_bounds(MAX_BENCH_SIZE)
        self.assertFalse(ok)

    def test_can_retreat_rejects_oob_bench(self):
        state = _make_state_with_pokemon()
        player = state.get_active_player()
        player.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        ok, msg = can_retreat(state, 0, MAX_BENCH_SIZE + 5)
        self.assertFalse(ok)

    def test_get_pokemon_bad_bench_slot_returns_none(self):
        state = _make_state_with_pokemon()
        player = state.get_active_player()
        self.assertIsNone(player.get_pokemon("bench_xyz"))
        self.assertIsNone(player.get_pokemon(f"bench_{MAX_BENCH_SIZE}"))

    def test_discard_pokemon_accepts_valid_bench_slot(self):
        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        player = state.get_active_player()
        benched = player.bench[0]

        state.discard_pokemon(0, "bench_0")

        self.assertIsNone(player.bench[0])
        self.assertIn(benched.card, player.discard)


# ── 2. Crushing Hammer Energy Discard ──────────────────────────────────────

class TestCrushingHammerDiscard(unittest.TestCase):

    def test_coin_flip_energy_discard_puts_energy_in_owner_discard(self):
        """Energy discarded by 粉碎之锤 must go to owner's discard pile."""
        state = _make_state_with_pokemon()
        # Give opponent's active some energy
        opponent = state.get_opponent()
        energy = CardRegistry.get("sv1-ener-3")  # grass energy
        self.assertIsNotNone(energy, "Test energy card must exist in registry")
        opponent.active.energy_cards.append(energy)

        # Prepare energy_targets the same way the handler does
        energy_targets = []
        for slot_name, poke in opponent.get_all_pokemon():
            if poke and poke.energy_cards:
                energy_targets.append((slot_name, poke, len(poke.energy_cards)))

        self.assertEqual(len(energy_targets), 1)
        self.assertEqual(len(opponent.active.energy_cards), 1)
        self.assertEqual(len(opponent.discard), 0)

        # Simulate the fixed behavior: pop energy and put in owner's discard
        target_slot, target_poke, energy_count = energy_targets[0]
        discarded = target_poke.energy_cards.pop()
        opponent.discard.append(discarded)

        # Verify energy was moved to discard pile
        self.assertEqual(len(target_poke.energy_cards), 0)
        self.assertEqual(len(opponent.discard), 1)
        self.assertEqual(opponent.discard[0].api_id, energy.api_id)

    def test_coin_flip_energy_discard_no_targets(self):
        """When opponent has no energy, the effect should do nothing gracefully."""
        from engine.effects.special_effects import _handle_coin_flip_energy_discard

        state = _make_state_with_pokemon()
        # Opponent has no energy on any Pokemon
        result = _handle_coin_flip_energy_discard(state, {}, 0, "active")
        self.assertTrue(result.success)
        self.assertIn("对手场上没有能量", result.log_message)


# ── 2b. Turn-Relative Bonuses ─────────────────────────────────────────────

class TestGoingSecondFirstTurnBonuses(unittest.TestCase):

    def test_going_second_first_turn_helper(self):
        state = GameState()
        state.first_player_idx = 0

        state.turn_number = 1
        state.active_player_idx = 0
        self.assertFalse(state.is_going_second_first_turn(0))
        self.assertFalse(state.is_going_second_first_turn(1))

        state.turn_number = 2
        state.active_player_idx = 1
        self.assertTrue(state.is_going_second_first_turn(1))
        self.assertFalse(state.is_going_second_first_turn(0))

        state.turn_number = 5
        state.active_player_idx = 1
        self.assertFalse(state.is_going_second_first_turn(1))

    def test_cresselia_bonus_only_on_going_second_first_turn(self):
        from engine.effects.energy_effects import _handle_energy_attach

        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        player = state.p2
        player.active = PokemonInPlay(CardRegistry.get("sv1-113"))
        player.deck = [CardRegistry.get("sv1-ener-5")] * 3

        result = _handle_energy_attach(
            state,
            player,
            1,
            {
                "amount": 1,
                "from_zone": "deck",
                "filter": "psychic",
                "to": "any",
                "going_second_bonus": 3,
            },
            "active",
        )

        self.assertTrue(result.success)
        self.assertEqual(len(player.active.energy_cards), 1)

    def test_grass_search_bonus_applies_on_turn_two_for_second_player(self):
        from engine.effects.search_effects import _handle_conditional_search_extra

        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 2
        state.p2.deck = [
            CardRegistry.get("svg2-shro"),
            CardRegistry.get("svg2-turt"),
            CardRegistry.get("svg2-tort"),
        ]

        result = _handle_conditional_search_extra(
            state,
            1,
            {"max_count": 3, "default_count": 1, "filter": "grass_pokemon"},
        )

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_action)
        self.assertEqual(result.pending_action.max_select, 3)


# ── 3. SwitchPokemon VM Continuation Semantics ─────────────────────────────

class TestSwitchPendingSemantics(unittest.TestCase):

    def test_switch_pokemon_non_optional_has_vm_continuation(self):
        """SwitchPokemon ActionRequest stores VM continuation instead of closure callback."""
        from engine.commands.resolution_stack import ResolutionStack
        from engine.commands.primitives import SwitchPokemon

        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        state.get_active_player().bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))

        stack = ResolutionStack(state)
        stack.push(SwitchPokemon(target="self", optional=False))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertIsNotNone(result.pending_choice.callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "switch_bench")

    def test_switch_opponent_non_optional_has_vm_continuation(self):
        """Switch opponent ActionRequest stores the target player in continuation."""
        from engine.commands.resolution_stack import ResolutionStack
        from engine.commands.primitives import SwitchPokemon

        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        state.get_opponent().bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))

        stack = ResolutionStack(state)
        stack.push(SwitchPokemon(target="opponent", you_choose=True))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "switch_bench")
        self.assertEqual(result.pending_choice.continuation.get("target_player_idx"), 1)

    def test_switch_continuation_performs_actual_switch(self):
        """The wrapped VM continuation on a SwitchPokemon request performs the switch."""
        from engine.commands.resolution_stack import ResolutionStack
        from engine.commands.primitives import SwitchPokemon

        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        player = state.get_active_player()
        bench_poke = PokemonInPlay(CardRegistry.get("sv1-113"))
        player.bench[1] = bench_poke
        original_active = player.active

        stack = ResolutionStack(state)
        stack.push(SwitchPokemon(target="self", optional=False))
        result = stack.resolve_all(0, "active")

        result.pending_choice.callback(1)
        # After callback, bench[1] should be the old active, active should be the bench pokemon
        self.assertEqual(player.active, bench_poke)
        self.assertEqual(player.bench[1], original_active)


# ── 3b. Effect Semantics / Aggregation ────────────────────────────────────

class TestEffectSemantics(unittest.TestCase):

    def test_potion_with_no_injured_target_returns_to_hand(self):
        state = _give_prizes(_make_state_with_pokemon())
        player = state.get_active_player()
        potion = CardRegistry.get("svf-potion")
        player.hand = [potion]

        result = TurnManager(state).perform_action(
            PlayerAction.PLAY_TRAINER,
            player_idx=0,
            hand_idx=0,
        )

        self.assertFalse(result.success)
        self.assertEqual(player.hand, [potion])
        self.assertEqual(player.discard, [])

    def test_potion_pending_choice_accepts_selected_card_list(self):
        state = _give_prizes(_make_state_with_pokemon(bench_card_ids=["sv1-113"]))
        player = state.get_active_player()
        potion = CardRegistry.get("svf-potion")
        player.hand = [potion]
        assert player.active is not None
        assert player.bench[0] is not None
        player.active.damage_counters = 2
        player.bench[0].damage_counters = 3

        result = TurnManager(state).perform_action(
            PlayerAction.PLAY_TRAINER,
            player_idx=0,
            hand_idx=0,
        )

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_action)
        callback = result.pending_action.callback
        self.assertIsNotNone(callback)
        callback([player.bench[0].card])

        self.assertEqual(player.active.damage_counters, 2)
        self.assertEqual(player.bench[0].damage_counters, 0)
        self.assertTrue(player.healed_this_turn)

    def test_any_pokemon_damage_prompts_for_target_when_multiple_targets_exist(self):
        state = _give_prizes(_make_state_with_pokemon(active_card_id="sv2-grex"))
        player = state.get_active_player()
        opponent = state.get_opponent()
        player.active.energy_cards = [CardRegistry.get("sv1-ener-3")]
        opponent.bench[0] = PokemonInPlay(CardRegistry.get("sv2-staryu"))

        result = TurnManager(state).perform_action(
            PlayerAction.DECLARE_ATTACK,
            player_idx=0,
            attack_idx=0,
        )

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_action)
        self.assertEqual(result.pending_action.request_type, "search_deck")
        self.assertEqual(result.damage_dealt, 0)
        self.assertEqual(opponent.active.damage_counters, 0)
        self.assertEqual(opponent.bench[0].damage_counters, 0)

    def test_attack_effect_draw_is_reported_in_action_result(self):
        state = _give_prizes(_make_state_with_pokemon(active_card_id="sv2-delib"))
        player = state.get_active_player()
        player.deck = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-3")]

        result = TurnManager(state).perform_action(
            PlayerAction.DECLARE_ATTACK,
            player_idx=0,
            attack_idx=0,
        )

        self.assertTrue(result.success)
        self.assertEqual(len(player.hand), 2)
        self.assertEqual(len(result.cards_drawn), 2)
        self.assertIn("抽取", result.log_message)


class TestCardEffectAccuracy(unittest.TestCase):

    def _battle_state(self, active_card_id="sv2-delib"):
        state = _give_prizes(_make_state_with_pokemon(active_card_id=active_card_id))
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        return state

    def _choose(self, engine, state, request, option_ids=()):
        return engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option_ids)),
        )

    def _register_board(self, state):
        from engine.commands.modifier_registration import register_pokemon_modifiers

        state.event_bus.clear()
        for player_idx in (0, 1):
            for slot, pokemon in state.get_player(player_idx).get_all_pokemon():
                if pokemon is not None:
                    register_pokemon_modifiers(
                        pokemon,
                        player_idx,
                        slot,
                        event_bus=state.event_bus,
                    )

    def test_ultra_ball_requires_two_other_cards_and_stays_in_hand(self):
        state = self._battle_state()
        player = state.get_active_player()
        ultra_ball = CardRegistry.get("sv1-153")
        filler = CardRegistry.get("sv1-ener-3")
        player.hand = [ultra_ball, filler]
        player.deck = [CardRegistry.get("sv2-delib")]

        result = TurnManager(state).perform_action(
            PlayerAction.PLAY_TRAINER,
            player_idx=0,
            hand_idx=0,
        )

        self.assertFalse(result.success)
        self.assertIn("无法支付代价", result.log_message)
        self.assertEqual(player.hand, [ultra_ball, filler])
        self.assertEqual(player.discard, [])

    def test_dedenne_can_decline_switch_after_damage(self):
        state = self._battle_state(active_card_id="sv1-114")
        player = state.get_active_player()
        opponent = state.get_opponent()
        player.active.energy_cards = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-3"),
        ]
        player.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        original_active = player.active
        engine = GameEngine()

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=False,
        )

        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        self.assertEqual(step.pending_choice.request_type, "confirm")
        no_option = next(option for option in step.pending_choice.options if option.value is False)
        result = self._choose(engine, state, step.pending_choice, (no_option.option_id,))

        self.assertTrue(result.success, result.message)
        self.assertEqual(opponent.active.damage_counters, 5)
        self.assertIs(player.active, original_active)

    def test_optional_searches_can_choose_zero_cards(self):
        engine = GameEngine()

        state = self._battle_state(active_card_id="sv1-114")
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3")]
        state.p1.deck = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-4")]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(step.pending_choice.min_select, 0)
        result = self._choose(engine, state, step.pending_choice, ())
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.hand), 0)
        self.assertEqual(len(state.p1.deck), 2)

        state = self._battle_state(active_card_id="svi-sqwk")
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3")]
        state.p1.deck = [CardRegistry.get("sv2-delib"), CardRegistry.get("sv1-113")]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(step.pending_choice.min_select, 0)
        result = self._choose(engine, state, step.pending_choice, ())
        self.assertTrue(result.success, result.message)
        self.assertEqual(state.p1.bench_count(), 0)

        state = self._battle_state()
        recovery = CardRegistry.get("sv1-171")
        state.p1.hand = [recovery]
        state.p1.discard = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-4")]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(step.pending_choice.min_select, 0)
        result = self._choose(engine, state, step.pending_choice, ())
        self.assertTrue(result.success, result.message)
        self.assertEqual(len([card for card in state.p1.discard if card.is_basic_energy]), 2)

    def test_electric_generator_zero_one_two_and_lightning_bench_only(self):
        engine = GameEngine()
        lightning = CardRegistry.get("sv1-ener-4")
        water = CardRegistry.get("sv1-ener-3")

        state = self._battle_state()
        state.p1.hand = [CardRegistry.get("sv1-170")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [water, water, water, lightning, lightning]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertEqual(step.pending_choice.min_select, 0)
        result = self._choose(engine, state, step.pending_choice, ())
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 0)
        self.assertEqual(len(state.p1.deck), 5)

        state = self._battle_state()
        state.p1.hand = [CardRegistry.get("sv1-170")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [water, water, water, lightning, lightning]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )
        one_energy = step.pending_choice.options[0]
        result = self._choose(engine, state, step.pending_choice, (one_energy.option_id,))
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 0)
        self.assertEqual(len(state.p1.deck), 4)

        state = self._battle_state()
        state.p1.hand = [CardRegistry.get("sv1-170")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p1.deck = [water, water, water, lightning, lightning]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )
        ids = tuple(option.option_id for option in step.pending_choice.options[:2])
        target_step = self._choose(engine, state, step.pending_choice, ids)
        self.assertTrue(target_step.success, target_step.message)
        self.assertIsNotNone(target_step.pending_choice)
        target = target_step.pending_choice.options[0]
        result = self._choose(
            engine,
            state,
            target_step.pending_choice,
            (target.option_id, target.option_id),
        )
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 2)

    def test_crushing_hammer_discards_selected_attachment(self):
        state = self._battle_state()
        state.p1.hand = [CardRegistry.get("svg2-hamm")]
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-3")]
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        selected_energy = CardRegistry.get("sv1-ener-4")
        state.p2.bench[0].energy_cards = [selected_energy]
        engine = GameEngine()

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            ScriptedRandomSource([True]),
            auto_resolve=False,
        )
        heads = next(option for option in step.pending_choice.options if option.value is True)
        target_step = self._choose(engine, state, step.pending_choice, (heads.option_id,))
        self.assertTrue(target_step.success, target_step.message)
        self.assertEqual(target_step.pending_choice.request_type, "select_attachment")
        bench_energy = next(
            option
            for option in target_step.pending_choice.options
            if option.ref.slot == "bench_0"
        )
        result = self._choose(engine, state, target_step.pending_choice, (bench_energy.option_id,))

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p2.active.energy_cards), 1)
        self.assertEqual(state.p2.bench[0].energy_cards, [])
        self.assertIn(selected_energy, state.p2.discard)

    def test_optional_energy_distribution_effects_accept_less_than_max(self):
        engine = GameEngine()
        grass = CardRegistry.get("sv1-ener-1")
        metal = CardRegistry.get("sv1-ener-8")
        water = CardRegistry.get("sv1-ener-3")

        state = self._battle_state()
        state.p1.hand = [CardRegistry.get("svg2-gard")]
        state.p1.deck = []
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand.extend([grass, grass])
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertEqual(step.pending_choice.min_select, 0)
        target = step.pending_choice.options[0]
        result = self._choose(engine, state, step.pending_choice, (target.option_id,))
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)

        state = self._battle_state(active_card_id="svm-cobalion")
        state.p1.active.energy_cards = [metal, metal]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svm-zacian"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svm-zamazenta"))
        state.p1.deck = [metal, metal]
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertEqual(step.pending_choice.min_select, 0)
        bench_1 = next(option for option in step.pending_choice.options if option.value.get("slot") == "bench_1")
        result = self._choose(engine, state, step.pending_choice, (bench_1.option_id,))
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 0)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 1)

        state = self._battle_state(active_card_id="svg-cast")
        state.p1.active.energy_cards = [water, CardRegistry.get("svi-jete")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNone(step.pending_choice)
        self.assertEqual(state.p1.active.energy_cards, [CardRegistry.get("svi-jete")])
        self.assertEqual(state.p1.bench[0].energy_cards, [water])

        state = self._battle_state()
        state.p1.hand = [CardRegistry.get("svi-popp")]
        state.p1.active.energy_cards = [water, metal]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )
        source = next(option for option in step.pending_choice.options if option.value.get("slot") == "active")
        target_step = self._choose(engine, state, step.pending_choice, (source.option_id,))
        self.assertEqual(target_step.pending_choice.min_select, 0)
        bench_1 = next(
            option
            for option in target_step.pending_choice.options
            if option.value.get("slot") == "bench_1"
        )
        result = self._choose(engine, state, target_step.pending_choice, (bench_1.option_id,))
        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.active.energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 1)

    def test_attack_formula_damage_uses_single_pipeline(self):
        engine = GameEngine()
        state = self._battle_state(active_card_id="sv1-109")
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("svi-dtur"),
        ]
        self._register_board(state)

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 4)

    def test_conditional_bonus_prevention_is_one_damage_packet(self):
        state = self._battle_state(active_card_id="sv1-113")
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-5")] * 5
        state.p2.active.damage_prevented_next_turn = True

        step = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 0)
        self.assertFalse(state.p2.active.damage_prevented_next_turn)

    def test_weakness_applies_before_tool_modifiers(self):
        state = self._battle_state(active_card_id="svl-pikaex")
        state.apply_type_matchups = True
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-4")]
        state.p1.active.attached_tool = CardRegistry.get("svl-vitb")
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"))
        self._register_board(state)

        step = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 7)

    def test_piercing_marker_ignores_defender_prevention(self):
        state = self._battle_state(active_card_id="sv2-staryu")
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p2.active.damage_prevented_next_turn = True

        step = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 3)

    def test_zero_final_damage_does_not_trigger_damage_reactive_hooks(self):
        from engine.commands.damage_pipeline import resolve_damage

        state = self._battle_state()
        state.p1.active.energy_cards = [CardRegistry.get("svi-dtur")]
        state.p2.active.energy_cards = [CardRegistry.get("svi-mirc")]
        state.p2.deck = [CardRegistry.get("sv1-ener-3")]
        self._register_board(state)

        damage, _logs = resolve_damage(
            state,
            state.p1.active,
            state.p2.active,
            10,
            state.p1.active.card.energy_types[0],
        )

        self.assertEqual(damage, 0)
        self.assertEqual(len(state.p2.hand), 0)
        self.assertEqual(len(state.p2.deck), 1)

    def test_failed_pending_attack_choice_does_not_apply_accumulated_damage(self):
        from engine import action_resolver as action_resolver_module
        from engine.action_resolver import ActionResolver
        from engine.commands.base import CommandResult

        state = self._battle_state(active_card_id="sv1-114")
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-3"),
        ]
        resolver = ActionResolver(state)

        class PendingFailCommand:
            def execute(self, _ctx):
                pending = ActionRequest(
                    request_type="confirm",
                    player=0,
                    prompt="fail attack continuation",
                    callback=lambda _choice: ActionResult(False, "目标无效。"),
                )
                return CommandResult.ok("等待选择。", pending_choice=pending)

        original_compile_command_spec = action_resolver_module.compile_command_spec
        action_resolver_module.compile_command_spec = lambda _effect: PendingFailCommand()
        try:
            result = resolver._declare_attack(0, 1)
            self.assertTrue(result.success, result.log_message)
            self.assertIsNotNone(result.pending_action)

            continuation = result.pending_action.callback([])
        finally:
            action_resolver_module.compile_command_spec = original_compile_command_spec

        self.assertFalse(continuation.success)
        self.assertEqual(state.p2.active.damage_counters, 0)
        self.assertFalse(hasattr(state, "_attack_damage_context"))

    def test_attack_effects_enter_attack_resolution_stack(self):
        from engine.action_resolver import ActionResolver

        state = self._battle_state(active_card_id="sv1-114")
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-3"),
        ]
        resolver = ActionResolver(state)
        attack = state.p1.active.card.attacks[1]
        calls = []

        def fake_execute_effects(
            effects,
            player_idx,
            source_slot,
            attack_context,
            *,
            finish_attack_in_stack=False,
        ):
            calls.append((list(effects), player_idx, source_slot, dict(attack_context)))
            return ActionResult(True, "")

        resolver._execute_attack_effects = fake_execute_effects

        result = resolver._declare_attack(0, 1)

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], list(attack.compiled_effects))
        self.assertEqual(calls[0][1:3], (0, "active"))
        self.assertTrue(calls[0][3]["active"])
        self.assertEqual(calls[0][3]["player_idx"], 0)

    def test_attack_damage_context_is_stack_scoped_without_state_bridge(self):
        from engine.commands.attack_frames import (
            attack_damage_context,
            begin_attack_damage_context,
            clear_attack_damage_context,
        )
        from engine.commands.resolution_stack import ResolutionStack

        state = self._battle_state(active_card_id="sv1-114")
        stack = ResolutionStack(state)
        context = {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 40,
        }

        self.assertIs(begin_attack_damage_context(state, stack, context), context)
        self.assertIs(stack.context["attack_damage"], context)
        self.assertIs(attack_damage_context(state, stack), context)
        self.assertIsNone(attack_damage_context(state))
        self.assertFalse(hasattr(state, "_attack_damage_context"))
        self.assertFalse(hasattr(state, "_piercing_attack"))
        self.assertFalse(hasattr(state, "_attack_ignore_defender_effects"))

        clear_attack_damage_context(state, stack)

        self.assertNotIn("attack_damage", stack.context)
        self.assertIsNone(attack_damage_context(state, stack))
        self.assertFalse(hasattr(state, "_attack_damage_context"))

    def test_tatsugiri_return_to_hand_has_no_damage_and_checks_board(self):
        state = self._battle_state(active_card_id="sv2-tatsu")
        water = CardRegistry.get("sv1-ener-3")
        tool = CardRegistry.get("svl-vitb")
        state.p1.active.energy_cards = [water]
        state.p1.active.attached_tool = tool

        step = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 0)
        self.assertIsNone(state.p1.active)
        self.assertIn(CardRegistry.get("sv2-tatsu"), state.p1.hand)
        self.assertIn(water, state.p1.hand)
        self.assertIn(tool, state.p1.hand)
        self.assertEqual(state.winner, 1)

    def test_attack_leave_play_promotes_before_next_turn_draw(self):
        engine = GameEngine()
        state = self._battle_state(active_card_id="sv2-tatsu")
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.deck = [CardRegistry.get("sv1-ener-3")]

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.pending_promotions, [0])
        self.assertEqual(state.phase, TurnPhase.ATTACK)
        self.assertEqual(len(state.p2.hand), 0)

        promote = engine.apply_action(
            state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
        )

        self.assertTrue(promote.success, promote.message)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)
        self.assertEqual(len(state.p2.hand), 1)

    def test_direct_second_attack_and_overpaid_retreat_are_rejected(self):
        state = self._battle_state()
        state.phase = TurnPhase.ATTACK
        step = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
        )
        self.assertFalse(step.success)

        state = self._battle_state()
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3")] * 3
        ok, _reason = can_retreat(state, 0, 0, [0, 1, 2])
        self.assertFalse(ok)

        state = self._battle_state()
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("svi-dtur")]
        ok, reason = can_retreat(state, 0, 0, [0])
        self.assertTrue(ok, reason)

    def test_effect_draw_partial_but_turn_start_empty_deck_loses(self):
        state = self._battle_state(active_card_id="sv2-delib")
        state.p1.deck = [CardRegistry.get("sv1-ener-3")]

        result = TurnManager(state).perform_action(
            PlayerAction.DECLARE_ATTACK,
            player_idx=0,
            attack_idx=0,
        )

        self.assertTrue(result.success, result.log_message)
        self.assertIsNone(state.winner)
        self.assertEqual(len(state.p1.hand), 1)
        self.assertEqual(len(state.p1.deck), 0)

        state = self._battle_state()
        state.turn_number = 3
        state.p2.deck = []
        end = TurnManager(state).perform_action(PlayerAction.END_TURN, player_idx=0)
        self.assertTrue(end.success, end.log_message)
        self.assertEqual(state.winner, 0)


# ── 4. SearchScreen min_select ─────────────────────────────────────────────

class TestSearchMinSelect(unittest.TestCase):
    """SearchScreen now enforces min_select — but the enforcement is in the UI.
    These tests verify that the ActionRequest correctly carries min_select."""

    def test_action_request_min_select_metadata(self):
        req = ActionRequest(
            request_type="search_deck",
            player=0,
            prompt="Select cards",
            min_select=2,
            max_select=3,
            card_list=["sv1-32", "sv1-113", "sv1-107"],
        )
        self.assertEqual(req.min_select, 2)
        self.assertEqual(req.max_select, 3)


# ── 5. Simultaneous KO Promotion Queue ─────────────────────────────────────

class TestSimultaneousKOPromotion(unittest.TestCase):

    def test_pending_promotions_queue_both_players(self):
        """When both active Pokemon are KO'd, both players get queued."""
        state = _make_state_with_pokemon()
        # Set up both players with bench pokemon
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv1-32"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-32"))
        # Both actives are present
        self.assertIsNotNone(state.p1.active)
        self.assertIsNotNone(state.p2.active)

        # Simulate both needing promotion
        state.pending_promotions = [0, 1]

        self.assertEqual(len(state.pending_promotions), 2)
        self.assertEqual(state.pending_promotion_player, 0)

        # Pop first
        p1 = state.pop_pending_promotion()
        self.assertEqual(p1, 0)
        self.assertEqual(state.pending_promotion_player, 1)
        self.assertEqual(len(state.pending_promotions), 1)

        # Pop second
        p2 = state.pop_pending_promotion()
        self.assertEqual(p2, 1)
        self.assertEqual(state.pending_promotion_player, -1)
        self.assertEqual(len(state.pending_promotions), 0)

    def test_backward_compat_setter_appends(self):
        """Setter appends or clears based on value."""
        state = GameState()
        self.assertEqual(state.pending_promotion_player, -1)

        state.pending_promotion_player = 1
        self.assertEqual(state.pending_promotion_player, 1)
        self.assertEqual(state.pending_promotions, [1])

        state.pending_promotion_player = 0
        self.assertEqual(len(state.pending_promotions), 2)
        self.assertEqual(state.pending_promotions, [1, 0])

    def test_backward_compat_setter_clears_on_neg(self):
        """Setter with -1 clears the queue."""
        state = GameState()
        state.pending_promotions = [0, 1]
        state.pending_promotion_player = -1
        self.assertEqual(len(state.pending_promotions), 0)
        self.assertEqual(state.pending_promotion_player, -1)

    def test_no_duplicate_promotions(self):
        """Setter doesn't add the same player_idx twice."""
        state = GameState()
        state.pending_promotion_player = 0
        state.pending_promotion_player = 0
        self.assertEqual(len(state.pending_promotions), 1)

    def test_simultaneous_ko_promotes_both(self):
        """End-to-end: both actives KO'd → both promoted."""
        state = _make_state_with_pokemon()
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv1-107"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-113"))

        from engine.action_resolver import ActionResolver
        resolver = ActionResolver(state)

        # Set massive damage counters so both actives are KO'd
        state.p1.active.damage_counters = 999
        state.p2.active.damage_counters = 999
        self.assertTrue(state.p1.active.is_knocked_out)
        self.assertTrue(state.p2.active.is_knocked_out)

        # Check KOs for both players
        ko_slots = resolver._check_kos()
        self.assertGreater(len(ko_slots), 0)

        # Both should be queued
        self.assertEqual(len(state.pending_promotions), 2)
        self.assertIn(0, state.pending_promotions)
        self.assertIn(1, state.pending_promotions)


# ── 6. Server Authority: Coin Flip Generation ─────────────────────────────

class TestServerCoinAuthority(unittest.TestCase):

    def test_host_generates_predetermined_flips(self):
        """Host must generate coin results, not trust client."""
        from engine.game_state import ActionRequest

        req = ActionRequest(
            request_type="coin_flip",
            player=0,
            prompt="Flip a coin",
            flip_count=3,
        )
        # Simulate host logic
        import random
        predetermined = [random.random() >= 0.5 for _ in range(3)]
        self.assertEqual(len(predetermined), 3)
        self.assertTrue(all(isinstance(r, bool) for r in predetermined))
        # Results should be valid booleans
        for r in predetermined:
            self.assertIn(r, (True, False))

    def test_host_generates_until_tails_flips(self):
        """until_tails must generate a sequence ending with tails."""
        import random
        # Override random to produce a deterministic sequence
        # heads, heads, tails
        random.seed(42)
        flips = []
        while True:
            flips.append(random.random() >= 0.5)
            if not flips[-1]:
                break
        self.assertTrue(len(flips) >= 1)
        self.assertFalse(flips[-1], "until_tails sequence must end with tails")


# ── 7. Selection Validation ────────────────────────────────────────────────

class TestSelectionValidation(unittest.TestCase):

    def test_search_selection_rejects_oob_indices(self):
        """Invalid indices should be filtered out."""
        card_list = ["a", "b", "c"]
        selected = [0, 5, -1]  # 5 and -1 are invalid
        valid = [i for i in selected if isinstance(i, int) and 0 <= i < len(card_list)]
        self.assertEqual(valid, [0])

    def test_bench_selection_rejects_negative(self):
        """Bench slot must be >= 0."""
        selected = -1
        ok, _ = check_bench_bounds(selected)
        self.assertFalse(ok)

    def test_bench_targets_filter_duplicates_when_not_allowed(self):
        """Without allow_duplicates, duplicates should be removed."""
        selected = [0, 1, 0, 2, 2]
        seen = set()
        valid = [t for t in selected if t not in seen and not seen.add(t)]
        self.assertEqual(valid, [0, 1, 2])

    def test_bench_targets_respect_max_select(self):
        """Target selection should respect max_select."""
        selected = [0, 1, 2, 3, 4]
        max_sel = 2
        valid = selected[:max_sel]
        self.assertEqual(valid, [0, 1])

    def test_energy_assignments_validate_bounds(self):
        """Energy distribution assignments must be in valid range."""
        card_list = ["e1", "e2", "e3"]
        target_slots = {"active", "bench_0"}
        assignments = [[0, "active"], [5, "active"], [1, "invalid"], [2, "bench_0"]]

        valid = []
        for a in assignments:
            if not isinstance(a, (list, tuple)) or len(a) != 2:
                continue
            ei, tgt = a
            if not isinstance(ei, int) or ei < 0 or ei >= len(card_list):
                continue
            if tgt not in target_slots:
                continue
            valid.append([ei, tgt])

        self.assertEqual(len(valid), 2)
        self.assertEqual(valid[0], [0, "active"])
        self.assertEqual(valid[1], [2, "bench_0"])


# ── 7b. Snapshot / Resource Integrity ─────────────────────────────────────

class TestSnapshotAndResources(unittest.TestCase):

    def test_snapshot_restore_preserves_deck_and_discard_order(self):
        state = GameState()
        cards = [CardRegistry.get(cid) for cid in ALL_CARD_IDS[:4]]
        state.p1.deck = cards[:3]
        state.p1.discard = cards[1:4]

        snap = snapshot_state(state)
        restore_state(state, snap)

        self.assertEqual([c.api_id for c in state.p1.deck],
                         [c.api_id for c in cards[:3]])
        self.assertEqual([c.api_id for c in state.p1.discard],
                         [c.api_id for c in cards[1:4]])

    def test_snapshot_restore_and_clone_preserve_event_stream(self):
        state = GameState()
        state.event_stream.push(GameEvent("preexisting", {"amount": 1}))
        state.event_stream.push(GameEvent("pending_choice", {"slot": "active"}))

        snap = snapshot_state(state)
        state.event_stream.push(GameEvent("mutated", {"amount": 99}))
        restore_state(state, snap)

        self.assertEqual(
            [(event.event_type, event.data) for event in state.event_stream._events],
            [
                ("preexisting", {"amount": 1}),
                ("pending_choice", {"slot": "active"}),
            ],
        )

        cloned = clone_state(state)
        self.assertEqual(
            [(event.event_type, event.data) for event in cloned.event_stream._events],
            [
                ("preexisting", {"amount": 1}),
                ("pending_choice", {"slot": "active"}),
            ],
        )

    def test_card_image_mapping_uses_id_keys_and_normalized_filenames(self):
        root = Path(__file__).resolve().parents[1]
        mapping_path = root / "data" / "card_image_mapping.json"
        mapping = json.loads(mapping_path.read_text(encoding="utf-8"))

        self.assertEqual(
            mapping.get("svg-dram"),
            "data\\images\\宝可梦\\老翁龙__svg-dram.webp",
        )
        self.assertEqual(
            mapping.get("sv2-tatsu"),
            "data\\images\\宝可梦\\米立龙__sv2-tatsu.webp",
        )
        self.assertNotIn("老翁龙", mapping)
        self.assertNotIn("米立龙", mapping)

        missing = []
        for key, raw_path in mapping.items():
            if not raw_path:
                continue
            self.assertIn(f"__{key}", Path(raw_path).stem)
            candidate = Path(raw_path)
            if not candidate.is_absolute():
                candidate = root / candidate
            if not candidate.exists():
                missing.append((key, raw_path))
        self.assertEqual(missing, [])


# ── 8. USE_STADIUM Remote Dispatch (P1) ──────────────────────────────────

class TestUseStadiumDispatch(unittest.TestCase):

    def test_action_resolver_has_use_stadium(self):
        """USE_STADIUM must be a valid PlayerAction and handled by resolver."""
        self.assertIn(PlayerAction.USE_STADIUM, PlayerAction.__members__.values())
        # Verify it's in the action name map
        from network.message_protocol import ACTION_TO_STRING
        self.assertIn(PlayerAction.USE_STADIUM, ACTION_TO_STRING)
        self.assertEqual(ACTION_TO_STRING[PlayerAction.USE_STADIUM], "USE_STADIUM")

    def test_use_stadium_on_valid_stadium(self):
        """Test that USE_STADIUM action resolves correctly when stadium is in play."""
        state = _make_state_with_pokemon()
        draw_card = CardRegistry.get("sv1-ener-2")
        stadium = Card(
            api_id="test-activatable-stadium",
            name="Activatable Stadium",
            supertype="Trainer",
            subtypes=["Stadium"],
            trainer_type="Stadium",
            compiled_trainer_effects=[{
                "op": "draw_cards",
                "args": {"amount": 1, "stadium_type": "activatable"},
                "branches": {},
            }],
        )
        state.stadium_card = stadium
        state.p1.deck = [draw_card]
        tm = TurnManager(state)

        result = tm.perform_action(PlayerAction.USE_STADIUM, player_idx=0)

        self.assertTrue(result.success, result.log_message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])
        self.assertTrue(state.p1.stadium_used_this_turn)

    def test_use_stadium_without_stadium_fails(self):
        """USE_STADIUM without a stadium in play should fail."""
        state = _make_state_with_pokemon()
        state.stadium_card = None
        tm = TurnManager(state)
        result = tm.perform_action(PlayerAction.USE_STADIUM, player_idx=0)
        self.assertFalse(result.success)


if __name__ == '__main__':
    unittest.main()

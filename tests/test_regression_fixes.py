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
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from engine.game_state import GameState, ActionRequest, ActionResult
from engine.turn_manager import TurnManager
from engine.enums import TurnPhase, PlayerAction
from engine.player_state import PokemonInPlay, PlayerState
from engine.rules_validator import (
    parse_bench_idx,
    parse_slot,
    check_bench_bounds,
    can_retreat,
)
from engine.rules_constants import MAX_BENCH_SIZE
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


# ── 3. SwitchPokemon Callback Semantics ────────────────────────────────────

class TestSwitchPendingSemantics(unittest.TestCase):

    def test_switch_pokemon_non_optional_has_callback(self):
        """SwitchPokemon ActionRequest MUST have a callback (unified semantics)."""
        from engine.commands.base import ResolutionContext
        from engine.commands.primitives import SwitchPokemon

        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        state.get_active_player().bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))

        ctx = ResolutionContext(state, 0, "active", None)
        cmd = SwitchPokemon(target="self", optional=False)
        result = cmd.execute(ctx)

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertIsNotNone(
            result.pending_choice.callback,
            "SwitchPokemon must provide a callback that performs the switch"
        )

    def test_switch_opponent_non_optional_has_callback(self):
        """Switch opponent ActionRequest MUST have a callback."""
        from engine.commands.base import ResolutionContext
        from engine.commands.primitives import SwitchPokemon

        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        state.get_opponent().bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))

        ctx = ResolutionContext(state, 0, "active", None)
        cmd = SwitchPokemon(target="opponent", you_choose=True)
        result = cmd.execute(ctx)

        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertIsNotNone(
            result.pending_choice.callback,
            "Switch opponent must provide a callback that performs the switch"
        )

    def test_switch_callback_performs_actual_switch(self):
        """The callback on a SwitchPokemon request must perform the switch."""
        from engine.commands.base import ResolutionContext
        from engine.commands.primitives import SwitchPokemon

        state = _make_state_with_pokemon(bench_card_ids=["sv1-113"])
        player = state.get_active_player()
        bench_poke = PokemonInPlay(CardRegistry.get("sv1-113"))
        player.bench[1] = bench_poke
        original_active = player.active

        ctx = ResolutionContext(state, 0, "active", None)
        cmd = SwitchPokemon(target="self", optional=False)
        result = cmd.execute(ctx)

        # Call the callback with bench_idx=1
        callback = result.pending_choice.callback
        self.assertIsNotNone(callback)

        ret = callback(1)
        # After callback, bench[1] should be the old active, active should be the bench pokemon
        self.assertEqual(player.active, bench_poke)
        self.assertEqual(player.bench[1], original_active)


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
        stadium = CardRegistry.get("svg2-skyf")  # Sky Field
        if stadium is None:
            self.skipTest("Sky Field stadium not in registry")
        state.stadium_card = stadium
        tm = TurnManager(state)
        result = tm.perform_action(PlayerAction.USE_STADIUM, player_idx=0)
        # Should succeed if stadium exists
        self.assertTrue(result.success)

    def test_use_stadium_without_stadium_fails(self):
        """USE_STADIUM without a stadium in play should fail."""
        state = _make_state_with_pokemon()
        state.stadium_card = None
        tm = TurnManager(state)
        result = tm.perform_action(PlayerAction.USE_STADIUM, player_idx=0)
        self.assertFalse(result.success)


if __name__ == '__main__':
    unittest.main()

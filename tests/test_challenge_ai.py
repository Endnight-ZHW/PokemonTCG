"""Challenge AI unit tests."""
import os
import sys
import unittest

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data.card_models import AbilityDef, AttackDef, Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK, expand_deck
from engine.ai import AIAction, AIConfig, ChallengeAI
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import can_play_basic, can_play_stadium, can_use_ability
from engine.turn_manager import TurnManager


class ChallengeAITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS, use_api=False)

    def _started_game(self):
        state = GameState()
        state.setup_game(expand_deck(FIRE_DECK), expand_deck(WATER_DECK))
        tm = TurnManager(state)
        for pi in (0, 1):
            for _ in range(10):
                if tm.needs_mulligan(pi):
                    state.do_mulligan(pi)
                else:
                    break
            player = state.get_player(pi)
            basic_idx = next(i for i, c in enumerate(player.hand) if c.is_basic_pokemon)
            result = tm.setup_place_basic(pi, basic_idx, "active")
            self.assertTrue(result.success, result.log_message)
        result = tm.setup_finalize()
        self.assertTrue(result.success, result.log_message)
        return state

    def _simple_public_state(self):
        basic = CardRegistry.get("sv2-delib")
        energy = CardRegistry.get("sv1-ener-3")
        alt_basic = CardRegistry.get("svi-chim")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(basic)
        state.p2.active = PokemonInPlay(basic)
        state.p2.hand = [energy, alt_basic]
        state.p2.deck = [energy] * 10
        state.p1.hand = [alt_basic, energy, basic]
        state.p1.deck = [basic, energy, alt_basic] * 4
        state.p1.prizes = [basic] * 6
        state.p2.prizes = [basic] * 6
        return state

    def test_legal_actions_simulate_successfully(self):
        state = self._started_game()
        state.active_player_idx = 1
        state.phase = TurnPhase.MAIN
        state.turn_number = max(state.turn_number, 3)

        ai = ChallengeAI(AIConfig(
            thinking_time_seconds=0.05,
            beam_width=4,
            max_sequence_depth=2,
            max_turn_actions=10,
        ))
        actions = ai.legal_actions(state, 1)
        self.assertTrue(actions)
        self.assertFalse(any(
            action.action == PlayerAction.PLAY_BASIC
            and action.params.get("target") == "active"
            for action in actions
        ))

        for action in actions[:8]:
            with self.subTest(action=action):
                sim = ai._clone_state(state)
                result = ai._apply_action_for_sim(sim, 1, action)
                self.assertIsNotNone(result)
                self.assertTrue(result.success, result.log_message)

    def test_core_rules_reject_main_phase_active_basic_and_same_stadium(self):
        state = self._simple_public_state()
        basic = CardRegistry.get("svi-chim")
        state.p2.active = None
        state.p2.hand = [basic]

        ok, reason = can_play_basic(state, 1, basic, "active")
        self.assertFalse(ok)
        self.assertIn("主要阶段", reason)
        result = TurnManager(state).perform_action(
            PlayerAction.PLAY_BASIC, player_idx=1, hand_idx=0, target="active",
        )
        self.assertFalse(result.success)

        same_in_play = Card(api_id="stadium-a", name="Same Stadium",
                            supertype="Trainer", subtypes=["Stadium"])
        same_in_hand = Card(api_id="stadium-b", name="Same Stadium",
                            supertype="Trainer", subtypes=["Stadium"])
        CardRegistry._cards[same_in_play.api_id] = same_in_play
        CardRegistry._cards[same_in_hand.api_id] = same_in_hand
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.stadium_card = same_in_play
        state.p2.hand = [same_in_hand]
        ok, reason = can_play_stadium(state, 1, same_in_hand)
        self.assertFalse(ok)
        self.assertIn("同名", reason)
        actions = ChallengeAI(AIConfig(max_turn_actions=20)).legal_actions(state, 1)
        self.assertFalse(any(
            action.action == PlayerAction.PLAY_TRAINER
            and action.params.get("hand_idx") == 0
            for action in actions
        ))

    def test_manual_ability_once_per_turn_and_reset(self):
        base = CardRegistry.get("sv2-delib")
        ability_mon = Card(
            api_id="test-ability-mon",
            name="Ability Mon",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=90,
            energy_types=["Colorless"],
            abilities=[AbilityDef("Focus", "Once during your turn.", trigger="")],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(ability_mon)
        state.p2.active = PokemonInPlay(base)

        self.assertTrue(can_use_ability(state, 0, "active", "Focus")[0])
        result = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY, player_idx=0, slot="active", ability_name="Focus",
        )
        self.assertTrue(result.success, result.log_message)
        self.assertIn("Focus", state.p1.active.used_abilities)
        self.assertFalse(can_use_ability(state, 0, "active", "Focus")[0])
        repeat = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY, player_idx=0, slot="active", ability_name="Focus",
        )
        self.assertFalse(repeat.success)

        state.p1.reset_turn_flags()
        self.assertTrue(can_use_ability(state, 0, "active", "Focus")[0])

    def test_fairness_ignores_opponent_hidden_card_identities(self):
        base_state = self._simple_public_state()
        hidden_changed = ChallengeAI()._clone_state(base_state)
        replacement_a = CardRegistry.get("svi-ente")
        replacement_b = CardRegistry.get("sv1-ener-2")
        hidden_changed.p1.hand = [replacement_a, replacement_b, replacement_a]
        hidden_changed.p1.deck = [replacement_b, replacement_a, replacement_b] * 4

        config = AIConfig(
            thinking_time_seconds=0.05,
            beam_width=4,
            max_sequence_depth=2,
            max_turn_actions=8,
            random_seed=99,
        )
        action_a = ChallengeAI(config).choose_action(base_state, 1)
        action_b = ChallengeAI(config).choose_action(hidden_changed, 1)

        self.assertEqual(action_a.action, action_b.action)
        self.assertEqual(action_a.params, action_b.params)
        self.assertEqual(action_a.terminal, action_b.terminal)

    def test_pending_choice_strategies_cover_common_requests(self):
        state = self._simple_public_state()
        ai = ChallengeAI(AIConfig(random_seed=3))
        player = state.p2
        player.bench[0] = PokemonInPlay(CardRegistry.get("sv2-staryu"))
        player.bench[1] = PokemonInPlay(CardRegistry.get("sv2-keldeo"))

        search_req = ActionRequest(
            "search_deck", 1, "search", min_select=1, max_select=2,
            card_list=list(player.deck),
        )
        self.assertEqual(len(ai.resolve_pending_action(state, search_req).selected_cards), 2)

        discard_req = ActionRequest(
            "select_hand_to_discard", 1, "discard", min_select=1, max_select=1,
            card_list=list(player.hand),
        )
        self.assertEqual(len(ai.resolve_pending_action(state, discard_req).selected_cards), 1)

        bench_req = ActionRequest(
            "select_bench", 1, "bench", bench_indices=[0, 1],
        )
        self.assertIn(ai.resolve_pending_action(state, bench_req).selected_bench_slot, [0, 1])

        target_req = ActionRequest(
            "select_bench_targets", 1, "targets", min_select=1, max_select=1,
            target_player="self", bench_indices=[0, 1],
        )
        self.assertEqual(len(ai.resolve_pending_action(state, target_req).selected_bench_targets), 1)

        coin_req = ActionRequest("coin_flip", 1, "coin", flip_count=3)
        self.assertEqual(len(ai.resolve_pending_action(state, coin_req).coin_results), 3)
        sim_choice = ai._resolve_pending_for_sim(state, ActionRequest("coin_flip", 1, "coin", flip_count=4))
        self.assertIn(True, sim_choice.coin_results)
        self.assertIn(False, sim_choice.coin_results)

        energy_req = ActionRequest(
            "distribute_energy", 1, "energy",
            card_list=[CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-3")],
            target_info=[
                {"slot": "active", "name": player.active.card.name, "bench_idx": -1},
                {"slot": "bench_0", "name": player.bench[0].card.name, "bench_idx": 0},
            ],
            max_per_target=2,
        )
        self.assertTrue(ai.resolve_pending_action(state, energy_req).assignments)

    def test_attack_simulation_includes_forced_end_turn(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-ai-attacker",
            name="AI Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Tap", [], 10, "")],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(base)
        state.p2.active = PokemonInPlay(attacker)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        ai = ChallengeAI(AIConfig(max_sequence_depth=1, beam_width=2))
        result = ai._apply_action_for_sim(
            state, 1, AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True),
        )
        self.assertTrue(result.success, result.log_message)
        self.assertEqual(state.active_player_idx, 0)
        self.assertEqual(state.phase, TurnPhase.MAIN)


if __name__ == "__main__":
    unittest.main()

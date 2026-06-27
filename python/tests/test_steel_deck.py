import unittest
from dataclasses import replace

from data.card_models import Card, WeakRes
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, STEEL_DECK, expand_deck
from engine.actions import ChoiceResponse, GameAction
from engine.commands.modifier_registration import register_pokemon_modifiers
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import can_declare_attack, validate_deck
from engine.turn_manager import TurnManager


class SteelDeckRulesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        CardRegistry.initialize(ALL_CARD_IDS)

    def _card(self, card_id: str):
        card = CardRegistry.get(card_id)
        self.assertIsNotNone(card, card_id)
        return card

    def _energy(self, card_id: str = "sv1-ener-8"):
        return self._card(card_id)

    def _wall(self, api_id: str = "test-wall", hp: int = 400, types=None) -> Card:
        return Card(
            api_id=api_id,
            name=api_id,
            supertype="Pokémon",
            subtypes=["Basic"],
            hp=hp,
            energy_types=types or ["Colorless"],
        )

    def _state(self, attacker_id: str, defender_card: Card | None = None) -> GameState:
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(self._card(attacker_id))
        state.p2.active = PokemonInPlay(defender_card or self._wall())
        state.p1.prizes = [self._energy()] * 6
        state.p2.prizes = [self._energy()] * 6
        state.p1.deck = [self._energy()] * 12
        state.p2.deck = [self._energy()] * 12
        return state

    def _register_board(self, state: GameState) -> None:
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

    def _attack(self, state: GameState, attack_idx: int = 0):
        return GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": attack_idx}, actor=0),
            auto_resolve=True,
        )

    def test_steel_deck_loads_and_validates(self):
        expanded = expand_deck(STEEL_DECK)
        self.assertEqual(len(expanded), 60)
        self.assertEqual(len(set(expanded) & set(ALL_CARD_IDS)), len(set(expanded)))
        deck_cards = [self._card(card_id) for card_id in expanded]
        valid, reason = validate_deck(deck_cards, "steel")
        self.assertTrue(valid, reason)

    def test_zamazenta_metal_shield_and_revenge(self):
        zacian = self._card("svm-zacian")
        no_energy = self._state("svm-zacian", defender_card=self._card("svm-zamazenta"))
        no_energy.p1.active.energy_cards = [self._energy()] * 3
        self._register_board(no_energy)
        result = self._attack(no_energy, attack_idx=1)
        self.assertTrue(result.success, result.message)
        self.assertEqual(no_energy.p2.active.damage_counters, 10)

        shielded = self._state("svm-zacian", defender_card=self._card("svm-zamazenta"))
        shielded.p1.active = PokemonInPlay(zacian, energy_cards=[self._energy()] * 3)
        shielded.p2.active.energy_cards = [self._energy()]
        self._register_board(shielded)
        result = self._attack(shielded, attack_idx=1)
        self.assertTrue(result.success, result.message)
        self.assertEqual(shielded.p2.active.damage_counters, 7)

        revenge = self._state("svm-zamazenta", defender_card=self._wall())
        revenge.p1.active.energy_cards = [self._energy()] * 3
        revenge.p1.was_ko_by_attack = True
        self._register_board(revenge)
        result = self._attack(revenge, attack_idx=0)
        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 220)
        self.assertFalse(revenge.p1.was_ko_by_attack)

    def test_zacian_battle_legion_ignores_weakness_and_defender_effects(self):
        weak_zamazenta = replace(
            self._card("svm-zamazenta"),
            weaknesses=[WeakRes("Metal", "×2")],
        )
        state = self._state("svm-zacian", defender_card=weak_zamazenta)
        state.apply_type_matchups = True
        state.p1.active.energy_cards = [self._energy()]
        state.p1.bench[0] = PokemonInPlay(self._card("svm-smeargle"))
        state.p1.bench[1] = PokemonInPlay(self._card("svm-cobalion"))
        state.p2.active.energy_cards = [self._energy()]
        self._register_board(state)

        result = self._attack(state, attack_idx=0)

        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 40)
        self.assertEqual(state.p2.active.damage_counters, 4)

    def test_smeargle_look_top_attaches_basic_energies_to_one_pokemon(self):
        state = self._state("svm-smeargle")
        fire = self._card("sv1-ener-2")
        item = self._card("sv1-151")
        state.p1.active.energy_cards = [self._energy()]
        state.p1.bench[0] = PokemonInPlay(self._card("svm-zacian"))
        state.p1.deck = [
            self._card("sv2-catch"),
            item,
            self._energy(),
            fire,
            item,
            self._energy(),
        ]
        self._register_board(state)

        result = self._attack(state, attack_idx=0)

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.active.energy_cards), 4)
        self.assertEqual(sum(1 for card in state.p1.active.energy_cards if card.is_basic_energy), 4)

    def test_bronzong_metal_transfer_is_repeatable_and_metal_only(self):
        state = self._state("svm-bronzong")
        fire = self._card("sv1-ener-2")
        state.p1.bench[0] = PokemonInPlay(
            self._card("svm-zamazenta"),
            energy_cards=[self._energy(), fire],
        )
        state.p1.bench[1] = PokemonInPlay(self._card("svm-zacian"))
        self._register_board(state)
        engine = GameEngine()
        action = GameAction(
            PlayerAction.USE_ABILITY,
            {"slot": "active", "ability_name": "金属转移"},
            actor=0,
        )

        first = engine.apply_action(state, action, auto_resolve=True)
        second = engine.apply_action(state, action, auto_resolve=True)

        self.assertTrue(first.success, first.message)
        self.assertTrue(second.success, second.message)
        self.assertNotIn("金属转移", state.p1.active.used_abilities)
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-2", "sv1-ener-8"])
        self.assertEqual(state.p1.active.energy_cards, [])

    def test_orthworm_hp_boost_drops_and_triggers_ko(self):
        state = self._state("svm-orthworm")
        state.p1.active.energy_cards = [self._energy()] * 3
        state.p1.active.damage_counters = 14
        state.p1.bench[0] = PokemonInPlay(self._card("svm-bronzong"))
        state.p1.bench[1] = PokemonInPlay(self._card("svm-zacian"))
        self.assertEqual(state.p1.active.current_hp, 90)
        self._register_board(state)

        result = GameEngine().apply_action(
            state,
            GameAction(
                PlayerAction.USE_ABILITY,
                {"slot": "bench_0", "ability_name": "金属转移"},
                actor=0,
            ),
            auto_resolve=True,
        )

        self.assertTrue(result.success, result.message)
        self.assertIn("p0_active", result.action_result.pokemon_ko)
        self.assertIsNone(state.p1.active)
        self.assertEqual(state.pending_promotion_player, 0)

    def test_cobalion_aura_only_boosts_basic_attacks_into_darkness_active(self):
        darkness = self._wall("darkness-wall", hp=400, types=["Darkness"])
        state = self._state("svm-zacian", defender_card=darkness)
        state.p1.active.energy_cards = [self._energy()] * 3
        state.p1.bench[0] = PokemonInPlay(self._card("svm-cobalion"))
        self._register_board(state)
        boosted = self._attack(state, attack_idx=1)
        self.assertEqual(boosted.action_result.damage_dealt, 130)

        colorless = self._state("svm-zacian", defender_card=self._wall(types=["Colorless"]))
        colorless.p1.active.energy_cards = [self._energy()] * 3
        colorless.p1.bench[0] = PokemonInPlay(self._card("svm-cobalion"))
        self._register_board(colorless)
        unboosted = self._attack(colorless, attack_idx=1)
        self.assertEqual(unboosted.action_result.damage_dealt, 100)

        evolved = self._state("svm-bronzong", defender_card=darkness)
        evolved.p1.active.energy_cards = [self._energy()] * 3
        evolved.p1.bench[0] = PokemonInPlay(self._card("svm-cobalion"))
        self._register_board(evolved)
        stage_one = self._attack(evolved, attack_idx=0)
        self.assertEqual(stage_one.action_result.damage_dealt, 70)

    def test_cobalion_follow_up_limits_one_energy_per_bench_target(self):
        state = self._state("svm-cobalion")
        state.p1.active.energy_cards = [self._energy(), self._energy()]
        state.p1.bench[0] = PokemonInPlay(self._card("svm-zacian"))
        state.p1.bench[1] = PokemonInPlay(self._card("svm-zamazenta"))
        state.p1.deck = [self._energy(), self._energy(), self._card("sv1-151")]
        self._register_board(state)
        engine = GameEngine()

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )

        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        self.assertEqual(step.pending_choice.request_type, "distribute_energy")
        self.assertEqual(step.pending_choice.legacy_request.max_per_target, 1)
        bench_0 = next(
            option
            for option in step.pending_choice.options
            if option.value.get("slot") == "bench_0"
        )

        result = engine.apply_choice(
            state,
            step.pending_choice,
            ChoiceResponse(
                step.pending_choice.request_id,
                (bench_0.option_id, bench_0.option_id),
            ),
        )

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 0)
        self.assertEqual(sum(1 for card in state.p1.deck if card.api_id == "sv1-ener-8"), 1)

        single = self._state("svm-cobalion")
        single.p1.active.energy_cards = [self._energy(), self._energy()]
        single.p1.bench[0] = PokemonInPlay(self._card("svm-zacian"))
        single.p1.deck = [self._energy(), self._energy(), self._card("sv1-151")]
        self._register_board(single)

        result = self._attack(single, attack_idx=0)

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(single.p1.bench[0].energy_cards), 1)
        self.assertEqual(sum(1 for card in single.p1.deck if card.api_id == "sv1-ener-8"), 1)

    def test_skarmory_steel_blade_cannot_be_used_next_own_turn(self):
        state = self._state("svm-skarmory")
        state.p1.active.energy_cards = [self._energy()] * 3
        self._register_board(state)

        result = self._attack(state, attack_idx=1)
        self.assertTrue(result.success, result.message)
        self.assertEqual(state.active_player_idx, 1)
        TurnManager(state).perform_action(PlayerAction.END_TURN, player_idx=1)

        ok, reason = can_declare_attack(state, 0, 1)
        self.assertFalse(ok)
        self.assertIn("钢铁之刃", reason)

    def test_orthworm_pierce_hits_active_and_chosen_bench(self):
        state = self._state("svm-orthworm", defender_card=self._wall(hp=400))
        state.p1.active.energy_cards = [self._energy()] * 4
        state.p2.bench[0] = PokemonInPlay(self._wall("bench-wall", hp=100))
        self._register_board(state)

        result = self._attack(state, attack_idx=0)

        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 100)
        self.assertEqual(state.p2.active.damage_counters, 10)
        self.assertEqual(state.p2.bench[0].damage_counters, 3)


if __name__ == "__main__":
    unittest.main()

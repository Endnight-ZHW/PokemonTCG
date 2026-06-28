import unittest

from data.card_models import Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, DARKNESS_DECK, expand_deck
from engine.actions import GameAction
from engine.commands.modifier_registration import register_pokemon_modifiers
from engine.enums import PlayerAction, StatusType, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import validate_deck


class DarknessDeckRulesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        CardRegistry.initialize(ALL_CARD_IDS)

    def _card(self, card_id: str):
        card = CardRegistry.get(card_id)
        self.assertIsNotNone(card, card_id)
        return card

    def _energy(self):
        return self._card("sv1-ener-7")

    def _wall(self, api_id: str = "test-wall", hp: int = 500) -> Card:
        return Card(
            api_id=api_id,
            name=api_id,
            supertype="Pokémon",
            subtypes=["Basic"],
            hp=hp,
            energy_types=["Colorless"],
        )

    def _state(self, attacker_id: str, defender_card: Card | None = None) -> GameState:
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(self._card(attacker_id), placed_this_turn=False)
        state.p2.active = PokemonInPlay(defender_card or self._wall(), placed_this_turn=False)
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

    def _attack(self, state: GameState, attack_idx: int = 0, actor: int = 0):
        return GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": attack_idx}, actor=actor),
            auto_resolve=True,
        )

    def test_darkness_deck_loads_and_validates(self):
        expanded = expand_deck(DARKNESS_DECK)
        self.assertEqual(len(expanded), 60)
        self.assertEqual(len(set(expanded) & set(ALL_CARD_IDS)), len(set(expanded)))

        mabosstiff = self._card("svd-mabosstiff-ex")
        self.assertEqual(mabosstiff.evolves_from, "偶叫獒")
        self.assertEqual(mabosstiff.prize_value, 2)

        deck_cards = [self._card(card_id) for card_id in expanded]
        valid, reason = validate_deck(deck_cards, "darkness")
        self.assertTrue(valid, reason)

    def test_mabosstiff_intimidate_reduces_next_attack_then_expires(self):
        state = self._state("svd-mabosstiff-ex", defender_card=self._card("svd-maschiff"))
        state.p1.active.energy_cards = [self._energy(), self._energy(), self._energy()]
        state.p2.active.energy_cards = [self._energy(), self._energy()]
        self._register_board(state)

        first = self._attack(state, attack_idx=0, actor=0)
        self.assertTrue(first.success, first.message)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.p2.active.outgoing_damage_reduction_next_turn, 50)

        second = self._attack(state, attack_idx=0, actor=1)
        self.assertTrue(second.success, second.message)
        self.assertEqual(second.action_result.damage_dealt, 0)
        self.assertEqual(state.p1.active.damage_counters, 0)
        self.assertEqual(state.p2.active.outgoing_damage_reduction_next_turn, 0)

    def test_mabosstiff_pride_fang_bonus_checks_own_damaged_bench(self):
        state = self._state("svd-mabosstiff-ex")
        state.p1.active.energy_cards = [self._energy(), self._energy(), self._energy()]
        self._register_board(state)
        unboosted = self._attack(state, attack_idx=1)
        self.assertTrue(unboosted.success, unboosted.message)
        self.assertEqual(unboosted.action_result.damage_dealt, 100)

        boosted = self._state("svd-mabosstiff-ex")
        boosted.p1.active.energy_cards = [self._energy(), self._energy(), self._energy()]
        boosted.p1.bench[0] = PokemonInPlay(self._card("svd-doduo"), damage_counters=1)
        self._register_board(boosted)
        result = self._attack(boosted, attack_idx=1)
        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 220)

    def test_dodrio_ability_and_raging_beak(self):
        state = self._state("svd-dodrio")
        state.p1.active.energy_cards = [self._energy()]
        state.p1.deck = [self._card("sv1-151"), self._energy()]
        self._register_board(state)

        ability = GameEngine().apply_action(
            state,
            GameAction(
                PlayerAction.USE_ABILITY,
                {"slot": "active", "ability_name": "暴走抽取"},
                actor=0,
            ),
            auto_resolve=True,
        )
        self.assertTrue(ability.success, ability.message)
        self.assertEqual(state.p1.active.damage_counters, 1)
        self.assertEqual(len(state.p1.hand), 1)

        result = self._attack(state, attack_idx=0)
        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 40)

    def test_dark_patch_attaches_only_to_benched_darkness_pokemon(self):
        state = self._state("svd-absol")
        state.p1.hand = [self._card("svd-dark-patch")]
        state.p1.discard = [self._energy()]
        state.p1.bench[0] = PokemonInPlay(self._card("svd-maschiff"))
        state.p1.bench[1] = PokemonInPlay(self._card("svd-doduo"))
        self._register_board(state)

        result = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=True,
        )
        self.assertTrue(result.success, result.message)
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-7"])
        self.assertEqual(state.p1.bench[1].energy_cards, [])

        no_target = self._state("svd-absol")
        no_target.p1.hand = [self._card("svd-dark-patch")]
        no_target.p1.discard = [self._energy()]
        no_target.p1.bench[0] = PokemonInPlay(self._card("svd-doduo"))
        result = GameEngine().apply_action(
            no_target,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=True,
        )
        self.assertFalse(result.success, result.message)
        self.assertIn("没有合法目标", result.message)
        self.assertEqual([card.api_id for card in no_target.p1.hand], ["svd-dark-patch"])
        self.assertIn("sv1-ener-7", [card.api_id for card in no_target.p1.discard])
        self.assertEqual(no_target.p1.bench[0].energy_cards, [])

    def test_hard_belt_reduces_damage_only_on_stage_one_holder(self):
        state = self._state("svd-darkrai", defender_card=self._card("svd-mabosstiff-ex"))
        state.p1.active.energy_cards = [self._energy(), self._energy(), self._energy()]
        state.p2.active.attached_tool = self._card("svd-hard-belt")
        self._register_board(state)
        reduced = self._attack(state, attack_idx=1)
        self.assertTrue(reduced.success, reduced.message)
        self.assertEqual(reduced.action_result.damage_dealt, 100)

        basic = self._state("svd-darkrai", defender_card=self._card("svd-maschiff"))
        basic.p1.active.energy_cards = [self._energy(), self._energy(), self._energy()]
        basic.p2.active.attached_tool = self._card("svd-hard-belt")
        self._register_board(basic)
        unreduced = self._attack(basic, attack_idx=1)
        self.assertTrue(unreduced.success, unreduced.message)
        self.assertEqual(unreduced.action_result.damage_dealt, 130)

    def test_absol_darkrai_morpeko_and_seviper_rules(self):
        absol = self._state("svd-absol")
        absol.p1.active.energy_cards = [self._energy()]
        absol.p2.bench[0] = PokemonInPlay(self._wall("bench-a", hp=100))
        absol.p2.bench[1] = PokemonInPlay(self._wall("bench-b", hp=100))
        self._register_board(absol)
        result = self._attack(absol, attack_idx=0)
        self.assertTrue(result.success, result.message)
        self.assertEqual(absol.p2.active.damage_counters, 1)
        self.assertEqual(absol.p2.bench[0].damage_counters, 1)
        self.assertEqual(absol.p2.bench[1].damage_counters, 1)

        darkrai = self._state("svd-darkrai")
        darkrai.p1.active.energy_cards = [self._energy(), self._energy()]
        result = GameEngine().apply_action(
            darkrai,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_finish_attack=False,
        )
        self.assertTrue(result.success, result.message)
        self.assertIn(StatusType.ASLEEP, darkrai.p2.active.status_conditions)
        self.assertEqual(darkrai.p2.active.damage_counters, 3)

        morpeko = self._state("svd-morpeko")
        morpeko.p1.active.energy_cards = [self._energy()]
        morpeko.p1.hand = []
        result = self._attack(morpeko, attack_idx=1)
        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 110)

        recycle = self._state("svd-morpeko")
        recycle.p1.active.energy_cards = [self._energy()]
        recycle.p1.discard = [self._card("sv1-151")]
        result = self._attack(recycle, attack_idx=0)
        self.assertTrue(result.success, result.message)
        self.assertEqual([card.api_id for card in recycle.p1.hand], ["sv1-151"])

        seviper = self._state("svd-seviper", defender_card=self._card("svd-dodrio"))
        seviper.p1.active.energy_cards = [self._energy(), self._energy()]
        result = self._attack(seviper, attack_idx=1)
        self.assertTrue(result.success, result.message)
        self.assertEqual(result.action_result.damage_dealt, 100)


if __name__ == "__main__":
    unittest.main()

import unittest

from data.card_models import Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, expand_deck
from engine.game_state import GameState
from engine.enums import TurnPhase
from engine.rules_validator import can_play_stadium, validate_deck
from engine.snapshot import snapshot_state, state_from_snapshot


def _basic(card_id: str = "basic") -> Card:
    return Card(
        api_id=card_id,
        name="测试基础宝可梦",
        supertype="Pokémon",
        subtypes=["Basic"],
        hp=60,
    )


def _basic_energy(card_id: str = "energy") -> Card:
    return Card(
        api_id=card_id,
        name="测试基本能量",
        supertype="Energy",
        subtypes=["Basic"],
    )


class DeckContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def test_exact_size_basic_requirement_and_basic_energy_exception(self):
        valid, reason = validate_deck([_basic()] + [_basic_energy()] * 59)
        self.assertTrue(valid, reason)

        valid, reason = validate_deck([_basic_energy()] * 60)
        self.assertFalse(valid)
        self.assertIn("基础宝可梦", reason)

        valid, reason = validate_deck([_basic()] + [_basic_energy()] * 58)
        self.assertFalse(valid)
        self.assertIn("60", reason)

    def test_copy_limit_uses_printed_name_across_different_ids(self):
        duplicate_name_cards = [
            Card(
                api_id=f"trainer-{index}",
                name="同名训练家",
                supertype="Trainer",
                subtypes=["Item"],
            )
            for index in range(5)
        ]
        deck = [_basic(), *duplicate_name_cards, *([_basic_energy()] * 54)]
        valid, reason = validate_deck(deck)
        self.assertFalse(valid)
        self.assertIn("同名", reason)

    def test_special_card_limits_fail_closed(self):
        ace_cards = [
            Card(
                api_id=f"ace-{index}",
                name=f"ACE {index}",
                supertype="Trainer",
                subtypes=["Item", "ACE SPEC"],
            )
            for index in range(2)
        ]
        deck = [_basic(), *ace_cards, *([_basic_energy()] * 57)]
        valid, reason = validate_deck(deck)
        self.assertFalse(valid)
        self.assertIn("ACE SPEC", reason)

        radiant_cards = [
            Card(
                api_id=f"radiant-{index}",
                name=f"光辉测试 {index}",
                supertype="Pokémon",
                subtypes=["Basic", "Radiant"],
                hp=90,
            )
            for index in range(2)
        ]
        deck = [*radiant_cards, *([_basic_energy()] * 58)]
        valid, reason = validate_deck(deck)
        self.assertFalse(valid)
        self.assertIn("光辉", reason)

    def test_setup_reports_unknown_id_instead_of_silently_dropping_it(self):
        deck = expand_deck(FIRE_DECK)
        deck[0] = "unknown-release-card"
        with self.assertRaisesRegex(ValueError, "未知卡牌 ID"):
            GameState().setup_game(deck, expand_deck(FIRE_DECK))

    def test_stadium_owner_roundtrips_in_snapshot_v2(self):
        state = GameState()
        state.stadium_owner_idx = 1
        restored = state_from_snapshot(snapshot_state(state))
        self.assertEqual(restored.stadium_owner_idx, 1)

    def test_stadium_duplicate_check_uses_printed_name_not_id(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.stadium_card = Card(
            api_id="stadium-a",
            name="测试竞技场",
            supertype="Trainer",
            subtypes=["Stadium"],
        )
        same_name = Card(
            api_id="stadium-b",
            name="测试竞技场",
            supertype="Trainer",
            subtypes=["Stadium"],
        )
        valid, reason = can_play_stadium(state, 0, same_name)
        self.assertFalse(valid)
        self.assertIn("同名", reason)


if __name__ == "__main__":
    unittest.main()

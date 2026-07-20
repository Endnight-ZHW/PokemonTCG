import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from data.card_models import Card
from engine.commands.formula_ast import evaluate_formula_ast
from engine.energy_view import EnergyView
from engine.enums import TurnPhase
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import can_retreat


def _pokemon_card(*, retreat_cost: int = 0) -> Card:
    return Card(
        api_id=f"test-pokemon-{retreat_cost}",
        name="测试宝可梦",
        supertype="Pokémon",
        subtypes=["Basic"],
        hp=100,
        retreat_cost=retreat_cost,
    )


def _basic_energy(name: str) -> Card:
    return Card(
        api_id=f"test-basic-{name}",
        name=f"{name} Energy",
        supertype="Energy",
        subtypes=["Basic"],
    )


def _double_turbo() -> Card:
    return Card(
        api_id="svi-dtur",
        name="双重涡轮能量",
        supertype="Energy",
        subtypes=["Special"],
        energy_effects=[{
            "kind": "provide_energy",
            "types": ["Colorless", "Colorless"],
        }],
    )


def _luminous() -> Card:
    return Card(
        api_id="svg2-lume",
        name="夜光能量",
        supertype="Energy",
        subtypes=["Special"],
        energy_effects=[{
            "kind": "provide_energy",
            "types": ["Rainbow"],
            "downgrade_if_other_special": True,
        }],
    )


class EnergyViewTests(unittest.TestCase):
    def test_energy_semantics_follow_descriptor_not_card_id(self):
        clone_turbo = _double_turbo()
        clone_turbo.api_id = "clone-double-turbo"
        clone_luminous = _luminous()
        clone_luminous.api_id = "clone-luminous"

        self.assertEqual(EnergyView([clone_turbo]).available_types, [
            "Colorless", "Colorless",
        ])
        self.assertEqual(EnergyView([clone_luminous]).available_types, ["Rainbow"])
        self.assertEqual(
            EnergyView([clone_luminous, clone_turbo]).available_types,
            ["Colorless", "Colorless", "Colorless"],
        )

        legacy_id_without_descriptor = Card(
            api_id="svi-dtur",
            name="无描述符同名测试能量",
            supertype="Energy",
            subtypes=["Special"],
        )
        self.assertEqual(
            EnergyView([legacy_id_without_descriptor]).available_types,
            ["Colorless"],
        )

    def test_double_turbo_is_two_colorless_units_for_cost_and_count(self):
        view = EnergyView([_double_turbo()])

        self.assertEqual(view.available_types, ["Colorless", "Colorless"])
        self.assertEqual(view.total_units, 2)
        self.assertEqual(view.count("Colorless"), 2)
        self.assertTrue(view.can_pay(["Colorless", "Colorless"]))
        self.assertFalse(view.can_pay(["Fire"]))

    def test_luminous_alone_is_one_wildcard(self):
        view = EnergyView([_luminous()])

        self.assertEqual(view.available_types, ["Rainbow"])
        self.assertEqual(view.total_units, 1)
        self.assertEqual(view.count("Fire"), 1)
        self.assertEqual(view.count("Water"), 1)
        self.assertTrue(view.can_pay(["Lightning"]))

    def test_basic_energy_does_not_downgrade_luminous(self):
        view = EnergyView([_luminous(), _basic_energy("Fire")])

        self.assertEqual(view.available_types, ["Rainbow", "Fire"])
        self.assertTrue(view.can_pay(["Fire", "Water"]))
        self.assertTrue(view.can_pay(["Water", "Fire"]))

    def test_other_special_energy_downgrades_luminous_to_colorless(self):
        view = EnergyView([_luminous(), _double_turbo()])

        self.assertEqual(
            view.available_types,
            ["Colorless", "Colorless", "Colorless"],
        )
        self.assertEqual(view.total_units, 3)
        self.assertEqual(view.count("Grass"), 0)
        self.assertFalse(view.can_pay(["Grass"]))
        self.assertTrue(view.can_pay(["Colorless"] * 3))

    def test_second_copy_downgrades_both_luminous_even_for_shared_object(self):
        luminous = _luminous()
        view = EnergyView([luminous, luminous])

        self.assertEqual(view.available_types, ["Colorless", "Colorless"])
        self.assertEqual(view.count("Psychic"), 0)
        self.assertFalse(view.can_pay(["Psychic"]))
        self.assertTrue(view.can_pay(["Colorless", "Colorless"]))

    def test_with_card_recomputes_conditional_providers_and_missing_cost(self):
        view = EnergyView([_luminous()])

        self.assertEqual(view.missing_count(["Grass"]), 0)
        after_special = view.with_card(_double_turbo())
        self.assertEqual(after_special.missing_count(["Grass"]), 1)
        self.assertEqual(after_special.missing_count(["Colorless"] * 4), 1)

    def test_pokemon_and_formula_ast_share_effective_unit_view(self):
        pokemon = PokemonInPlay(_pokemon_card())
        pokemon.energy_cards = [_double_turbo()]
        player = SimpleNamespace(active=pokemon, get_pokemon=lambda slot: pokemon)
        opponent = SimpleNamespace(active=None)
        ctx = SimpleNamespace(player=player, opponent=opponent, source_slot="active")

        self.assertEqual(pokemon.available_energy, ["Colorless", "Colorless"])
        self.assertTrue(pokemon.has_enough_energy(["Colorless", "Colorless"]))
        self.assertEqual(
            evaluate_formula_ast(
                {"op": "energy_count", "scope": "self", "energy_type": "any"},
                ctx,
            ),
            2,
        )

    def test_retreat_payment_discards_one_double_turbo_for_two_unit_cost(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.p1.active = PokemonInPlay(_pokemon_card(retreat_cost=2))
        state.p1.active.energy_cards = [_double_turbo()]
        state.p1.bench[0] = PokemonInPlay(_pokemon_card())

        self.assertEqual(can_retreat(state, 0, 0, [0]), (True, ""))
        state.p1.pay_retreat_cost(2, [0])
        self.assertEqual(state.p1.active.energy_cards, [])
        self.assertEqual([card.api_id for card in state.p1.discard], ["svi-dtur"])


if __name__ == "__main__":
    unittest.main()

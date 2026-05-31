"""Tests for optional weakness/resistance match rules."""
import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pygame

from data.card_models import Card, WeakRes
from engine.commands.damage_pipeline import resolve_damage
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from network.state_serializer import deserialize_game_state, serialize_game_state
from ui.screens.deck_select import DeckSelectScreen


class TypeMatchupRuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pygame.init()

    def _pokemon(self, name: str, energy_type: str) -> PokemonInPlay:
        return PokemonInPlay(Card(
            api_id=f"test-{name}",
            name=name,
            supertype="Pokemon",
            subtypes=["Basic"],
            hp=100,
            energy_types=[energy_type],
        ))

    def test_damage_pipeline_skips_matchups_by_default(self):
        state = GameState()
        attacker = self._pokemon("attacker", "Fire")
        defender = self._pokemon("defender", "Water")
        defender.card.weaknesses = [WeakRes("Fire", "x2")]

        damage, _ = resolve_damage(state, attacker, defender, 50, "Fire")

        self.assertEqual(damage, 50)

    def test_damage_pipeline_applies_matchups_when_enabled(self):
        state = GameState()
        state.apply_type_matchups = True
        attacker = self._pokemon("attacker", "Fire")
        defender = self._pokemon("defender", "Water")
        defender.card.weaknesses = [WeakRes("Fire", "x2")]
        defender.card.resistances = [WeakRes("Water", "-30")]

        weak_damage, _ = resolve_damage(state, attacker, defender, 50, "Fire")
        resist_damage, _ = resolve_damage(state, attacker, defender, 50, "Water")

        self.assertEqual(weak_damage, 100)
        self.assertEqual(resist_damage, 20)

    def test_game_state_serialization_preserves_matchup_rule(self):
        state = GameState()
        state.apply_type_matchups = True

        restored = deserialize_game_state(
            serialize_game_state(state, for_player_idx=0),
            for_player_idx=0,
        )

        self.assertTrue(restored.apply_type_matchups)

    def test_challenge_deck_select_forces_matchups_off(self):
        class FakeManager:
            def __init__(self):
                self._app = SimpleNamespace(apply_type_matchups=True)
                self.replaced = None

            def replace_top(self, screen):
                self.replaced = screen

        class FakeGameState:
            instances = []

            def __init__(self):
                self.apply_type_matchups = None
                FakeGameState.instances.append(self)

            def setup_game(self, deck1, deck2):
                self.deck1 = deck1
                self.deck2 = deck2

        class FakeTurnManager:
            def __init__(self, state):
                self.state = state

        class FakeGameScreen:
            def __init__(self, *args, **kwargs):
                self.args = args
                self.kwargs = kwargs

        available_decks = {"fire": [("a", 1)], "water": [("b", 1)]}
        screen = DeckSelectScreen(FakeManager(), available_decks, mode="challenge")

        with patch("engine.game_state.GameState", FakeGameState), \
             patch("engine.turn_manager.TurnManager", FakeTurnManager), \
             patch("ui.screens.game_screen.GameScreen", FakeGameScreen), \
             patch("data.deck_definitions.expand_deck", lambda deck: [deck[0][0]]):
            screen._start_battle()

        self.assertFalse(FakeGameState.instances[-1].apply_type_matchups)


if __name__ == "__main__":
    unittest.main()

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

    def test_challenge_deck_select_forces_matchups_off(self):
        class FakeManager:
            def __init__(self):
                self._app = SimpleNamespace(apply_type_matchups=True)
                self.replaced = None

            def replace_top(self, screen):
                self.replaced = screen

        class FakeGameScreen:
            def __init__(self, *args, **kwargs):
                self.args = args
                self.kwargs = kwargs

        sessions = []

        def fake_session_create(deck1, deck2, *, apply_type_matchups=False):
            state = SimpleNamespace(
                apply_type_matchups=bool(apply_type_matchups),
                public_deck_keys=(None, None),
                deck1=deck1,
                deck2=deck2,
            )
            session = SimpleNamespace(state=state, turn_manager=object())
            sessions.append(session)
            return session

        available_decks = {"fire": [("a", 1)], "water": [("b", 1)]}
        screen = DeckSelectScreen(FakeManager(), available_decks, mode="challenge")

        with patch("ui.debug_match_session.DebugMatchSession.create",
                   side_effect=fake_session_create), \
             patch("ui.screens.game_screen.GameScreen", FakeGameScreen), \
             patch("data.deck_definitions.expand_deck", lambda deck: [deck[0][0]]):
            screen._start_battle()

        self.assertFalse(sessions[-1].state.apply_type_matchups)
        self.assertEqual(sessions[-1].state.public_deck_keys, ("fire", "water"))

    def test_local_deck_select_records_both_public_deck_keys(self):
        class FakeManager:
            def __init__(self):
                self._app = SimpleNamespace(apply_type_matchups=False)
                self.replaced = None

            def replace_top(self, screen):
                self.replaced = screen

        class FakeGameScreen:
            def __init__(self, *args, **kwargs):
                self.args = args
                self.kwargs = kwargs

        sessions = []

        def fake_session_create(deck1, deck2, *, apply_type_matchups=False):
            state = SimpleNamespace(
                apply_type_matchups=bool(apply_type_matchups),
                public_deck_keys=(None, None),
                deck1=deck1,
                deck2=deck2,
            )
            session = SimpleNamespace(state=state, turn_manager=object())
            sessions.append(session)
            return session

        manager = FakeManager()
        screen = DeckSelectScreen(
            manager,
            {"fire": [("a", 1)], "water": [("b", 1)]},
        )
        # Same-deck selection remains legal and must preserve both positions.
        screen.p2_idx = 0

        with patch("ui.debug_match_session.DebugMatchSession.create",
                   side_effect=fake_session_create), \
             patch("ui.screens.game_screen.GameScreen", FakeGameScreen), \
             patch("data.deck_definitions.expand_deck", lambda deck: [deck[0][0]]):
            screen._start_battle()

        state = sessions[-1].state
        self.assertEqual(state.public_deck_keys, ("fire", "fire"))
        self.assertEqual(state.deck1, ["a"])
        self.assertEqual(state.deck2, ["a"])


if __name__ == "__main__":
    unittest.main()

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from data.card_models import Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.random_source import RandomSource
from engine.snapshot import clone_state


EFFECT_ACTIONS = {
    PlayerAction.PLAY_TRAINER,
    PlayerAction.USE_ABILITY,
    PlayerAction.USE_STADIUM,
}


class LegalActionPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def _trainer_heavy_state(self) -> GameState:
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0

        basic = CardRegistry.get("sv2-delib")
        opponent = CardRegistry.get("svi-chim")
        water_energy = CardRegistry.get("sv1-ener-3")
        fire_energy = CardRegistry.get("sv1-ener-2")

        state.p1.active = PokemonInPlay(
            basic,
            damage_counters=2,
            energy_cards=[water_energy],
        )
        for bench_idx in range(len(state.p1.bench)):
            state.p1.bench[bench_idx] = PokemonInPlay(
                basic,
                damage_counters=1,
                energy_cards=[water_energy],
            )
        state.p2.active = PokemonInPlay(
            opponent,
            damage_counters=1,
            energy_cards=[water_energy],
        )
        for bench_idx in range(3):
            state.p2.bench[bench_idx] = PokemonInPlay(
                opponent,
                energy_cards=[water_energy],
            )

        state.p1.hand = [
            card
            for card in CardRegistry.all_cards().values()
            if card.is_trainer
        ]
        # Exercise Rare Candy's stricter continuation validation too. The
        # freshly placed Chimchar makes the raw target scan optimistic, so
        # this action must retain the clone-and-execute fallback.
        state.p1.bench[0] = PokemonInPlay(opponent)
        state.p1.hand.append(CardRegistry.get("svi-infr"))
        deck_pool = [
            water_energy,
            fire_energy,
            opponent,
            CardRegistry.get("svd-hard-belt"),
            CardRegistry.get("svf-potion"),
            CardRegistry.get("sv1-151"),
        ]
        state.p1.deck = deck_pool * 6
        state.p1.discard = [
            water_energy,
            fire_energy,
            basic,
            opponent,
            CardRegistry.get("svf-potion"),
        ]
        state.p2.deck = [water_energy] * 20
        state.p1.prizes = [water_energy] * 6
        state.p2.prizes = [water_energy] * 6
        state.p1.was_ko_by_attack = True
        return state

    @staticmethod
    def _simulation_baseline(
        engine: GameEngine,
        state: GameState,
        actor: int,
    ):
        """Reproduce legal_actions' pre-preflight validation path."""
        validated = []
        for action in engine.availability.enumerate_actions(state, actor):
            if action.action not in EFFECT_ACTIONS:
                validated.append(action)
                continue
            simulation = clone_state(state)
            result = engine.apply_action(
                simulation,
                action,
                RandomSource(0),
                auto_resolve=True,
                auto_finish_attack=True,
            )
            if result.success:
                validated.append(action)
        return tuple(validated)

    def test_release_actions_match_simulation_with_fourfold_clone_reduction(self):
        state = self._trainer_heavy_state()
        engine = GameEngine()
        expected = self._simulation_baseline(engine, state, 0)
        effect_action_count = sum(
            action.action in EFFECT_ACTIONS
            for action in engine.availability.enumerate_actions(state, 0)
        )

        with patch("engine.game_engine.clone_state", wraps=clone_state) as clone:
            actual = engine.legal_actions(state, 0, validate_effects=True)

        self.assertEqual(actual, expected)
        self.assertGreater(effect_action_count, 20)
        self.assertLessEqual(clone.call_count * 4, effect_action_count)

    def test_registered_single_effect_tool_needs_no_simulation(self):
        state = self._trainer_heavy_state()
        state.p1.hand = [CardRegistry.get("svd-hard-belt")]
        engine = GameEngine()

        with patch.object(
            engine,
            "apply_action",
            side_effect=AssertionError("static preflight unexpectedly simulated"),
        ):
            actions = engine.legal_actions(state, 0, validate_effects=True)

        tool_actions = [
            action
            for action in actions
            if action.action == PlayerAction.PLAY_TRAINER
        ]
        self.assertEqual(len(tool_actions), 1 + len(state.p1.bench))

    def test_dynamic_release_effect_retains_simulation_fallback(self):
        state = self._trainer_heavy_state()
        state.p1.hand = [CardRegistry.get("sv2-catch")]
        engine = GameEngine()

        with patch("engine.game_engine.clone_state", wraps=clone_state) as clone:
            actions = engine.legal_actions(state, 0, validate_effects=True)

        self.assertTrue(
            any(action.action == PlayerAction.PLAY_TRAINER for action in actions)
        )
        self.assertEqual(clone.call_count, 1)

    def test_houb_edge_case_retains_simulation_fallback(self):
        state = self._trainer_heavy_state()
        state.p1.hand = [
            CardRegistry.get("svf-houb"),
            CardRegistry.get("sv1-ener-3"),
        ]
        engine = GameEngine()
        raw = engine.legal_actions(state, 0, validate_effects=False)
        self.assertTrue(
            any(action.action == PlayerAction.PLAY_TRAINER for action in raw)
        )

        with patch("engine.game_engine.clone_state", wraps=clone_state) as clone:
            validated = engine.legal_actions(state, 0, validate_effects=True)

        self.assertFalse(
            any(action.action == PlayerAction.PLAY_TRAINER for action in validated)
        )
        self.assertEqual(clone.call_count, 1)

    def test_registered_single_effect_ability_needs_no_simulation(self):
        state = self._trainer_heavy_state()
        state.p1.active = PokemonInPlay(CardRegistry.get("svg2-grot"))
        state.p1.hand = []
        state.p1.deck = [CardRegistry.get("svg2-turt")]
        engine = GameEngine()

        with patch.object(
            engine,
            "apply_action",
            side_effect=AssertionError("static preflight unexpectedly simulated"),
        ):
            actions = engine.legal_actions(state, 0, validate_effects=True)

        self.assertTrue(
            any(action.action == PlayerAction.USE_ABILITY for action in actions)
        )

    def test_unregistered_effect_retains_authoritative_simulation(self):
        state = self._trainer_heavy_state()
        unknown_item = Card(
            api_id="test-unknown-item",
            name="Unknown Item",
            supertype="Trainer",
            subtypes=["Item"],
            compiled_trainer_effects=[{
                "op": "unknown_extension_op",
                "args": {},
                "branches": {},
            }],
        )
        state.p1.hand = [unknown_item]
        engine = GameEngine()
        raw = engine.legal_actions(state, 0, validate_effects=False)
        self.assertTrue(
            any(action.action == PlayerAction.PLAY_TRAINER for action in raw)
        )

        with patch.object(
            engine,
            "apply_action",
            wraps=engine.apply_action,
        ) as apply_action:
            validated = engine.legal_actions(state, 0, validate_effects=True)

        self.assertFalse(
            any(action.action == PlayerAction.PLAY_TRAINER for action in validated)
        )
        self.assertEqual(apply_action.call_count, 1)


if __name__ == "__main__":
    unittest.main()

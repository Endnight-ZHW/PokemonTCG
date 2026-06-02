"""Deep-learning AI integration tests."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data.card_models import AttackDef, Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK
from engine.ai import (
    AIConfig,
    ChallengeAI,
    DeepLearningAI,
    DeepLearningAIConfig,
    create_ai_controller,
)
from engine.ai.challenge_ai import AIAction
from engine.ai.dl.encoder import ACTION_NUMERIC_SIZE, STATE_CARD_SLOTS, STATE_NUMERIC_SIZE, ActionStateEncoder
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from engine.player_state import PokemonInPlay


class DeepAITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS, use_api=False)

    def _simple_state(self):
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
        state.p2.prizes = [basic] * 6
        state.p1.hand = [alt_basic, energy, basic]
        state.p1.deck = [basic, energy, alt_basic] * 4
        state.p1.prizes = [basic] * 6
        return state

    def test_factory_preserves_challenge_default_and_creates_dl_ai(self):
        self.assertIsInstance(create_ai_controller("challenge", "fire"), ChallengeAI)
        ai = create_ai_controller(
            "deep_learning",
            "fire",
            DeepLearningAIConfig(
                model_path=os.path.join("missing", "model.pt"),
                fallback_config=AIConfig(
                    thinking_time_seconds=0.0,
                    deterministic_search=True,
                    max_sequence_depth=1,
                    max_turn_actions=8,
                ),
            ),
        )
        self.assertIsInstance(ai, DeepLearningAI)
        self.assertFalse(ai.model_available)

    def test_dl_ai_fallback_returns_legal_action_without_torch_or_model(self):
        state = self._simple_state()
        ai = DeepLearningAI(
            "water",
            DeepLearningAIConfig(
                model_path=os.path.join("missing", "model.pt"),
                fallback_config=AIConfig(
                    thinking_time_seconds=0.0,
                    deterministic_search=True,
                    max_sequence_depth=1,
                    max_turn_actions=8,
                ),
            ),
        )
        action = ai.choose_action(state, 1)
        legal = ai.legal_actions(state, 1)
        self.assertIn(
            (action.action, action.params),
            [(candidate.action, candidate.params) for candidate in legal],
        )

    def test_encoder_outputs_stable_shapes_and_handles_new_card_id(self):
        state = self._simple_state()
        new_card = Card(
            api_id="future-set-001",
            name="Future Basic",
            supertype="Pok茅mon",
            subtypes=["Basic"],
            hp=90,
            energy_types=["Colorless"],
            attacks=[AttackDef("Tap", [], 10, "")],
        )
        state.p2.hand.insert(0, new_card)

        encoder = ActionStateEncoder()
        encoded_state = encoder.encode_state(state, 1, "water")
        encoded_action = encoder.encode_action(
            state,
            1,
            AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": 0, "target": "bench_0"}),
        )

        self.assertEqual(len(encoded_state.numeric), STATE_NUMERIC_SIZE)
        self.assertEqual(len(encoded_state.card_ids), STATE_CARD_SLOTS)
        self.assertEqual(len(encoded_action.numeric), ACTION_NUMERIC_SIZE)
        self.assertGreater(encoded_action.card_id, 0)

    def test_training_cli_help_and_missing_torch_behavior(self):
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        help_result = subprocess.run(
            [sys.executable, "scripts/train_deep_ai.py", "--help"],
            cwd=root,
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(help_result.returncode, 0, help_result.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            output = os.path.join(tmpdir, "model.pt")
            progress = os.path.join(tmpdir, "progress.jsonl")
            result = subprocess.run(
                [
                    sys.executable,
                    "scripts/train_deep_ai.py",
                    "--deck",
                    "fire",
                    "--games",
                    "0",
                    "--bootstrap-games",
                    "0",
                    "--eval-games",
                    "0",
                    "--output",
                    output,
                    "--progress-jsonl",
                    progress,
                ],
                cwd=root,
                text=True,
                capture_output=True,
                timeout=60,
            )
            if importlib.util.find_spec("torch") is None:
                self.assertEqual(result.returncode, 2)
                self.assertIn("PyTorch is not installed", result.stderr)
                self.assertFalse(os.path.exists(output))
                self.assertTrue(os.path.exists(progress))
                with open(progress, "r", encoding="utf-8") as fh:
                    events = [json.loads(line) for line in fh if line.strip()]
                self.assertEqual(events[-1]["type"], "error")
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(os.path.exists(output))
                self.assertTrue(os.path.exists(progress))
                with open(progress, "r", encoding="utf-8") as fh:
                    event_types = [json.loads(line)["type"] for line in fh if line.strip()]
                self.assertIn("run_started", event_types)
                self.assertIn("run_finished", event_types)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_deep_training_writes_progress_events_and_sidecar(self):
        from engine.ai.dl.training import DeepTrainingConfig, run_deep_training

        with tempfile.TemporaryDirectory() as tmpdir:
            output = os.path.join(tmpdir, "model.pt")
            progress = os.path.join(tmpdir, "progress.jsonl")
            payload = run_deep_training(
                DeepTrainingConfig(
                    deck="fire",
                    games=0,
                    bootstrap_games=0,
                    eval_games=0,
                    output=output,
                    progress_jsonl=progress,
                    device="cpu",
                    max_steps=20,
                )
            )

            self.assertEqual(payload["model_path"], output)
            self.assertTrue(os.path.exists(output))
            self.assertTrue(os.path.exists(os.path.splitext(output)[0] + ".json"))
            with open(progress, "r", encoding="utf-8") as fh:
                events = [json.loads(line) for line in fh if line.strip()]
            event_types = [event["type"] for event in events]
            self.assertEqual(event_types[0], "run_started")
            self.assertIn("bootstrap_finished", event_types)
            self.assertIn("train_phase_finished", event_types)
            self.assertIn("eval_finished", event_types)
            self.assertEqual(event_types[-1], "run_finished")
            train_event = next(event for event in events if event["type"] == "train_phase_finished")
            self.assertIn("policy_loss", train_event)
            self.assertIn("value_loss", train_event)
            self.assertIn("total_loss", train_event)
            self.assertIn("examples", train_event)

    def test_challenge_deck_screen_exposes_ai_kind_selector(self):
        import pygame
        from ui.screens.deck_select import DeckSelectScreen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

            def replace_top(self, screen):
                self.screen = screen

        screen = DeckSelectScreen(
            Manager(),
            {"fire": FIRE_DECK, "water": WATER_DECK},
            mode="challenge",
        )
        self.assertEqual(screen.ai_kind, "challenge")
        surface = pygame.Surface((1600, 1000))
        screen.draw(surface)
        self.assertEqual(
            [button["kind"] for button in screen.ai_kind_buttons],
            ["challenge", "deep_learning"],
        )


if __name__ == "__main__":
    unittest.main()

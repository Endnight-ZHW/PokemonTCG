"""Deep-learning AI integration tests."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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
from engine.ai.challenge_ai import AIAction, create_challenge_ai
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
                    thinking_time_seconds=0.01,
                    deterministic_search=False,
                    max_sequence_depth=0,
                    max_turn_actions=8,
                    search_algorithm="beam",
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
                    thinking_time_seconds=0.01,
                    deterministic_search=False,
                    max_sequence_depth=0,
                    max_turn_actions=8,
                    search_algorithm="beam",
                ),
            ),
        )
        action = ai.choose_action(state, 1)
        legal = ai.legal_actions(state, 1)
        self.assertIn(
            (action.action, action.params),
            [(candidate.action, candidate.params) for candidate in legal],
        )

    def test_dl_runtime_defaults_are_eval_stable(self):
        config = DeepLearningAIConfig()
        self.assertTrue(config.deterministic)
        self.assertLessEqual(config.temperature, 0.35)
        self.assertLessEqual(config.choice_confidence_threshold, 0.30)

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

    def test_encoder_adds_deck_profile_action_context(self):
        state = self._simple_state()
        action = AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": 1, "target": "bench_0"})

        fire_encoder = ActionStateEncoder()
        fire_encoder.encode_state(state, 1, "fire")
        fire_action = fire_encoder.encode_action(state, 1, action)

        water_encoder = ActionStateEncoder()
        water_encoder.encode_state(state, 1, "water")
        water_action = water_encoder.encode_action(state, 1, action)

        self.assertEqual(len(fire_action.numeric), ACTION_NUMERIC_SIZE)
        self.assertEqual(len(water_action.numeric), ACTION_NUMERIC_SIZE)
        self.assertNotEqual(fire_action.numeric, water_action.numeric)

    def test_encoder_does_not_read_exact_own_hidden_deck_composition(self):
        state = self._simple_state()
        encoder = ActionStateEncoder()
        first = encoder.encode_state(state, 1, "water")

        energy = CardRegistry.get("sv1-ener-3")
        unrelated_basic = CardRegistry.get("svi-chim")
        state.p2.deck = [unrelated_basic] * len(state.p2.deck)
        second = encoder.encode_state(state, 1, "water")
        state.p2.deck = [energy] * len(state.p2.deck)
        third = encoder.encode_state(state, 1, "water")

        self.assertEqual(first.numeric, second.numeric)
        self.assertEqual(second.numeric, third.numeric)
        self.assertEqual(first.card_ids, second.card_ids)

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
        self.assertIn("--rollout-batch-games", help_result.stdout)
        self.assertIn("--updates-per-rollout", help_result.stdout)
        self.assertIn("--teacher-search-preset", help_result.stdout)
        self.assertIn("--dagger-games", help_result.stdout)
        self.assertIn("--choice-head-enabled", help_result.stdout)
        self.assertIn("--acceptance-metric", help_result.stdout)
        self.assertIn("--min-win-delta", help_result.stdout)
        self.assertIn("--teacher-label-model-states", help_result.stdout)

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
                    "--dagger-games",
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
                    dagger_games=0,
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
            self.assertIn("torch_version", events[0])
            self.assertIn("requested_device", events[0])
            self.assertIn("bootstrap_finished", event_types)
            self.assertIn("train_phase_finished", event_types)
            self.assertIn("eval_finished", event_types)
            self.assertEqual(event_types[-1], "run_finished")
            train_event = next(event for event in events if event["type"] == "train_phase_finished")
            self.assertIn("policy_loss", train_event)
            self.assertIn("value_loss", train_event)
            self.assertIn("total_loss", train_event)
            self.assertIn("examples", train_event)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_deep_training_accepts_single_example_batch(self):
        from engine.ai.dl.encoder import EncodedAction, EncodedState
        from engine.ai.dl.model import create_model
        from engine.ai.dl.training import TrainingExample, _train_examples

        model = create_model()
        example = TrainingExample(
            EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS),
            [EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0)],
            0,
            source="teacher",
        )
        result = _train_examples(
            model,
            [example],
            device="cpu",
            learning_rate=1e-3,
            epochs=1,
            batch_size=64,
        )

        self.assertEqual(result["examples"], 1)
        self.assertEqual(getattr(model, "state_norm", ""), "layer")

    def test_self_play_returns_are_assigned_only_to_recorded_target_examples(self):
        from engine.ai.dl.training import TrainingExample, _finalize_episode_examples, _step_reward
        from engine.ai.dl.encoder import EncodedState

        before = {"prizes_taken": 0.0, "opp_prizes_taken": 0.0, "eval_score": 0.0, "bench_count": 1.0, "hand_count": 3.0}
        after = {"prizes_taken": 1.0, "opp_prizes_taken": 0.0, "eval_score": 500.0, "bench_count": 2.0, "hand_count": 4.0}
        reward = _step_reward(before, after)
        self.assertGreater(reward, 0.0)

        state = EncodedState([0.0], [0])
        examples = [
            TrainingExample(state, [], 0, source="self_play", reward=reward, value_target=0.1),
            TrainingExample(state, [], 0, source="dagger", value_target=0.7),
            TrainingExample(state, [], 0, source="self_play", reward=-0.2, value_target=-0.1),
        ]
        finalized = _finalize_episode_examples(examples, terminal_reward=1.0, gamma=0.5)
        self.assertIs(finalized, examples)
        self.assertEqual(len(finalized), 3)
        self.assertNotEqual(finalized[0].return_target, 0.0)
        self.assertEqual(finalized[1].return_target, 0.0)
        self.assertEqual(finalized[1].advantage, None)
        self.assertNotEqual(finalized[2].return_target, 0.0)
        self.assertIsNotNone(finalized[0].advantage)

    def test_candidate_same_wins_more_draws_is_rejected_by_default_gate(self):
        from engine.ai.dl.training import _accepts_candidate

        baseline = {"wins": 25, "losses": 64, "draws": 11, "avg_score": -394720.374, "games": 100}
        candidate = {"wins": 25, "losses": 59, "draws": 16, "avg_score": -344311.383, "games": 100}
        self.assertFalse(
            _accepts_candidate(
                candidate,
                baseline,
                None,
                acceptance_metric="wins",
                min_win_delta=1,
            )
        )
        improved = dict(candidate, wins=26, losses=58)
        self.assertTrue(
            _accepts_candidate(
                improved,
                baseline,
                None,
                acceptance_metric="wins",
                min_win_delta=1,
            )
        )

    def test_dagger_teacher_label_uses_teacher_target(self):
        from engine.ai.dl.training import _teacher_label_state

        state = self._simple_state()
        teacher = create_challenge_ai(
            "water",
            AIConfig(
                thinking_time_seconds=0.0,
                deterministic_search=True,
                max_sequence_depth=1,
                max_turn_actions=8,
                search_algorithm="beam",
            ),
        )
        example = _teacher_label_state(ActionStateEncoder(), state, 1, "water", teacher)
        self.assertIsNotNone(example)
        assert example is not None
        self.assertEqual(example.source, "dagger")
        self.assertEqual(example.teacher_target_index, example.target_index)
        self.assertGreater(len(example.actions), 0)

    def test_choice_training_example_encodes_search_discard_and_bench_candidates(self):
        from engine.ai.challenge_ai import AIChoice
        from engine.ai.dl.training import _choice_training_example
        from engine.game_state import ActionRequest

        state = self._simple_state()
        cards = list(state.p2.hand)
        discard_req = ActionRequest(
            request_type="select_hand_to_discard",
            player=1,
            prompt="Discard a card",
            min_select=1,
            max_select=1,
            card_list=cards,
        )
        discard_example = _choice_training_example(
            ActionStateEncoder(),
            state,
            discard_req,
            AIChoice(selected_cards=[cards[0]]),
            "water",
            source="teacher",
            phase_tag="bootstrap",
        )
        self.assertIsNotNone(discard_example)
        assert discard_example is not None
        self.assertEqual(discard_example.request_type, "select_hand_to_discard")
        self.assertEqual(discard_example.teacher_target_index, 0)
        self.assertEqual(len(discard_example.candidate_choices), len(cards))
        self.assertEqual(len(discard_example.candidate_choices[0].numeric), ACTION_NUMERIC_SIZE)

        deck_cards = [cards[0], cards[1]]
        search_req = ActionRequest(
            request_type="search_deck",
            player=1,
            prompt="Search deck",
            min_select=1,
            max_select=1,
            card_list=deck_cards,
        )
        search_example = _choice_training_example(
            ActionStateEncoder(),
            state,
            search_req,
            AIChoice(selected_cards=[deck_cards[1]]),
            "water",
            source="teacher",
            phase_tag="bootstrap",
        )
        self.assertIsNotNone(search_example)
        assert search_example is not None
        self.assertEqual(search_example.request_type, "search_deck")
        self.assertEqual(search_example.teacher_target_index, 1)

        state.p2.bench[0] = PokemonInPlay(cards[1])
        bench_req = ActionRequest(
            request_type="select_bench",
            player=1,
            prompt="Choose bench",
            min_select=1,
            max_select=1,
        )
        bench_example = _choice_training_example(
            ActionStateEncoder(),
            state,
            bench_req,
            AIChoice(selected_bench_slot=0),
            "water",
            source="teacher",
            phase_tag="bootstrap",
        )
        self.assertIsNotNone(bench_example)
        assert bench_example is not None
        self.assertEqual(bench_example.request_type, "select_bench")
        self.assertEqual(bench_example.teacher_target_index, 0)

    def test_workers_use_process_pool_for_model_game_tasks(self):
        from engine.ai.dl import training as dl_training

        calls = {"max_workers": None, "mapped": False}

        class FakeExecutor:
            def __init__(self, max_workers=None, initializer=None):
                calls["max_workers"] = max_workers
                self.initializer = initializer

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def map(self, fn, tasks):
                calls["mapped"] = True
                return [fn(task) for task in tasks]

        def fake_execute(task):
            return None, 0.0, [], []

        tasks = [
            dl_training.ModelGameTask("fire", 1, 20, False, {}, {}, "fast"),
            dl_training.ModelGameTask("fire", 2, 20, False, {}, {}, "fast"),
        ]
        with mock.patch.object(dl_training, "ProcessPoolExecutor", FakeExecutor), \
             mock.patch.object(dl_training, "_execute_model_game_task", fake_execute):
            rows = dl_training._run_model_game_tasks(tasks, workers=4)

        self.assertEqual(calls["max_workers"], 4)
        self.assertTrue(calls["mapped"])
        self.assertEqual(len(rows), 2)

    def test_training_screen_exit_terminates_process_tree(self):
        import pygame
        from ui.screens import ai_training_screen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

        class FakeProcess:
            pid = 12345

            def poll(self):
                return None

        calls = []
        screen = ai_training_screen.AITrainingScreen(Manager())
        screen.status = "running"
        screen.process = FakeProcess()
        with mock.patch.object(ai_training_screen, "terminate_process_tree", lambda proc, timeout=3.0: calls.append((proc, timeout))):
            screen.on_exit()

        self.assertEqual(len(calls), 1)
        self.assertIsNone(screen.process)
        self.assertEqual(screen.status, "cancelled")

    def test_rl_all_reset_does_not_delete_applied_models(self):
        import pygame
        from ui.screens.ai_training_screen import AITrainingScreen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

        with tempfile.TemporaryDirectory() as tmpdir:
            model_dir = os.path.join(tmpdir, "data", "ai_models")
            os.makedirs(model_dir, exist_ok=True)
            applied = os.path.join(model_dir, "fire.pt")
            candidate = os.path.join(model_dir, "candidate_fire.pt")
            with open(applied, "wb") as fh:
                fh.write(b"applied")
            with open(candidate, "wb") as fh:
                fh.write(b"candidate")

            screen = AITrainingScreen(Manager())
            screen.repo_root = tmpdir
            screen.training_kind = "rl"
            screen.selected_deck = "all"
            self.assertTrue(screen._reset_training_files())

            self.assertTrue(os.path.exists(applied))
            self.assertFalse(os.path.exists(candidate))

    def test_multi_deck_output_uses_per_deck_candidate_paths(self):
        from engine.ai.dl.training import DeepTrainingConfig, _candidate_output_path

        config = DeepTrainingConfig(output=os.path.join("data", "ai_models", "candidate_default.pt"))
        self.assertEqual(
            _candidate_output_path(config, "fire", True),
            os.path.join("data", "ai_models", "candidate_fire.pt"),
        )
        self.assertEqual(
            _candidate_output_path(config, "fire", False),
            os.path.join("data", "ai_models", "candidate_default.pt"),
        )

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_cuda_request_falls_back_to_cpu_when_cuda_unavailable(self):
        from engine.ai.dl import training as dl_training

        with tempfile.TemporaryDirectory() as tmpdir:
            output = os.path.join(tmpdir, "model.pt")
            progress = os.path.join(tmpdir, "progress.jsonl")
            events = []
            with mock.patch.object(dl_training.torch.cuda, "is_available", return_value=False):
                dl_training.run_deep_training(
                    dl_training.DeepTrainingConfig(
                        deck="fire",
                        games=0,
                        bootstrap_games=0,
                        dagger_games=0,
                        eval_games=0,
                        output=output,
                        progress_jsonl=progress,
                        device="cuda",
                        max_steps=20,
                    ),
                    progress_callback=events.append,
                )
            run_started = events[0]
            self.assertEqual(run_started["requested_device"], "cuda")
            self.assertEqual(run_started["device"], "cpu")
            self.assertFalse(run_started["cuda_available"])

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_v6_checkpoint_saves_and_legacy_v5_restores_choice_head(self):
        from engine.ai.dl.model import checkpoint_payload, create_model, load_checkpoint, save_checkpoint, torch

        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "model_v6.pt")
            model = create_model(choice_head_enabled=True)
            save_checkpoint(path, model, {"trainer": "test"})
            restored, payload = load_checkpoint(path, "cpu")

            legacy_path = os.path.join(tmpdir, "model_v5.pt")
            legacy_model = create_model(choice_head_enabled=True, state_norm="batch")
            legacy_payload = checkpoint_payload(legacy_model, {"trainer": "legacy"})
            legacy_payload["version"] = 5
            legacy_payload.get("model_config", {}).pop("state_norm", None)
            torch.save(legacy_payload, legacy_path)
            legacy_restored, legacy_loaded = load_checkpoint(legacy_path, "cpu")

        self.assertEqual(payload.get("version"), 6)
        self.assertTrue(payload.get("model_config", {}).get("choice_head_enabled"))
        self.assertEqual(payload.get("model_config", {}).get("state_norm"), "layer")
        self.assertTrue(getattr(restored, "choice_head_enabled", False))
        self.assertTrue(hasattr(restored, "choice_net"))
        self.assertTrue(hasattr(restored, "score_choices"))
        self.assertFalse(hasattr(restored, "choice_value_head"))
        self.assertTrue(getattr(restored, "use_attention", False))
        self.assertEqual(getattr(restored, "state_norm", ""), "layer")
        self.assertEqual(legacy_loaded.get("version"), 5)
        self.assertTrue(getattr(legacy_restored, "choice_head_enabled", False))
        self.assertEqual(getattr(legacy_restored, "state_norm", ""), "batch")

    def test_game_screen_deep_ai_uses_selected_fallback_search(self):
        import pygame
        from engine.turn_manager import TurnManager
        from ui.screens.game_screen import GameScreen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

        state = self._simple_state()
        screen = GameScreen(
            Manager(),
            state,
            TurnManager(state),
            challenge_mode=True,
            ai_deck_key="missing_deck",
            ai_kind="deep_learning",
            ai_search_algorithm="minimax",
        )

        self.assertEqual(screen.ai_controller.fallback.config.search_algorithm, "minimax")
        self.assertIn("fallback", screen._ai_runtime_label())

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
        self.assertEqual(screen.ai_search_algorithm, "hybrid")
        surface = pygame.Surface((1600, 1000))
        screen.draw(surface)
        self.assertEqual(
            [button["kind"] for button in screen.ai_kind_buttons],
            ["challenge", "deep_learning"],
        )
        self.assertEqual(screen.ai_search_buttons, [])
        self.assertIsNotNone(screen.challenge_detail_panel_rect)
        self.assertIsNotNone(screen.ai_config_panel_rect)
        assert screen.challenge_detail_panel_rect is not None
        assert screen.ai_config_panel_rect is not None
        self.assertLessEqual(
            screen.challenge_detail_panel_rect.bottom,
            screen.ai_config_panel_rect.y,
        )
        self.assertLessEqual(screen.ai_config_panel_rect.bottom, screen.start_button.y)
        self.assertFalse(screen.ai_config_panel_rect.colliderect(screen.start_button))


if __name__ == "__main__":
    unittest.main()

"""Deep-learning AI integration tests."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import unittest
import warnings
from unittest import mock

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data.card_models import AttackDef, Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai import (
    AIConfig,
    ChallengeAI,
    DeepLearningAI,
    DeepLearningAIConfig,
    create_ai_controller,
)
from engine.ai.challenge_ai import AIAction, create_challenge_ai
from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_SEMANTIC_SIZE,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
    ActionStateEncoder,
)
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from tests.temp_utils import supports_file_delete, temp_dir


class DeepAITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

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
        self.assertTrue(config.use_mcts)
        self.assertLessEqual(config.temperature, 0.35)
        self.assertLessEqual(config.choice_confidence_threshold, 0.30)

    def test_neural_backend_uses_heuristic_leaf_value(self):
        from engine.ai.planner import HeuristicBackend, NeuralBackend

        fallback = HeuristicBackend(
            priority=lambda _state, _actor, _action: 0.0,
            evaluator=lambda _state, _perspective: 250000.0,
        )
        backend = NeuralBackend(None, None, "cpu", fallback, "fire")

        self.assertEqual(backend.value(object(), 0), 0.25)

    def test_neural_prior_guard_preserves_clear_heuristic_choice(self):
        from engine.ai.planner import _guarded_neural_priors, _softmax

        priors = _softmax([500.0, 420.0])
        self.assertAlmostEqual(priors[0], 0.731058, places=5)
        guarded = _guarded_neural_priors(
            [0.80, 0.10, 0.10],
            [0.70, 0.20, 0.10],
        )
        self.assertGreater(guarded[0], 0.70)
        self.assertAlmostEqual(sum(guarded), 1.0, places=6)

        heuristic = [0.70, 0.20, 0.10]
        guarded = _guarded_neural_priors(
            [0.05, 0.85, 0.10],
            heuristic,
        )
        for actual, expected in zip(guarded, heuristic):
            self.assertAlmostEqual(actual, expected, places=12)

    def test_dl_ai_uses_mcts_when_model_is_available(self):
        state = self._simple_state()
        ai = DeepLearningAI("fire", DeepLearningAIConfig())
        selected = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        ai.model = object()

        with mock.patch("engine.ai.dl.controller.TORCH_AVAILABLE", True), \
             mock.patch.object(ai, "_choose_with_mcts", return_value=selected) as choose_mcts, \
             mock.patch.object(ai, "_choose_with_model", return_value=selected) as choose_model:
            action = ai.choose_action(state, 1)

        self.assertEqual(action, selected)
        choose_mcts.assert_called_once()
        choose_model.assert_not_called()

    def test_eval_zero_training_metadata_is_marked_unverified(self):
        from engine.ai.dl.training import _verification_metadata

        metadata = _verification_metadata(0, True)
        self.assertFalse(metadata["verified"])
        self.assertEqual(metadata["verification_status"], "unverified_no_eval")
        self.assertEqual(metadata["rules_version"], RULES_SCHEMA_VERSION)
        self.assertEqual(metadata["action_version"], ACTION_SCHEMA_VERSION)
        self.assertEqual(metadata["encoder_version"], ENCODER_SCHEMA_VERSION)

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

    def test_encoder_semantic_width_is_stable_for_known_and_missing_cards(self):
        from engine.ai.observation import Observation

        encoder = ActionStateEncoder()
        known = CardRegistry.get("sv2-delib")

        self.assertEqual(len(encoder._card_semantic_features(known)), CARD_SEMANTIC_SIZE)
        self.assertEqual(len(encoder._card_semantic_features(None)), CARD_SEMANTIC_SIZE)
        self.assertEqual(CARD_SEMANTIC_SIZE, 53)

        observation = Observation(
            perspective=0,
            turn_number=1,
            phase="MAIN",
            active_player=0,
            winner=None,
            own_hand=(),
            own_discard=(),
            own_deck_count=0,
            own_prize_count=0,
            opponent_hand_count=0,
            opponent_discard=(),
            opponent_deck_count=0,
            opponent_prize_count=0,
            board=(
                (0, "active", "", 0, (), (), ""),
                (0, "bench_0", "sv2-delib", 0, (), (), ""),
            ),
            stadium_id="",
            public_deck_keys=("water", "fire"),
            apply_type_matchups=False,
        )
        encoded = encoder.encode_observation(observation, "water")
        known_start = len(TurnPhase) + 13 + len(encoder.deck_keys)
        known_start += 7 + CARD_SEMANTIC_SIZE + 7
        self.assertEqual(
            encoded.numeric[known_start:known_start + CARD_SEMANTIC_SIZE],
            encoder._card_semantic_features(known),
        )

    def test_encoder_exposes_all_release_deck_profiles(self):
        encoder = ActionStateEncoder()

        self.assertEqual(
            encoder.deck_keys,
            (
                "fire",
                "water",
                "psychic",
                "lightning",
                "fighting",
                "colorless",
                "dragon",
                "grass",
                "steel",
                "darkness",
            ),
        )

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

    def test_encoder_exposes_nested_catcher_target_context(self):
        state = self._simple_state()
        state.p1.bench = [None] * len(state.p1.bench)
        state.p2.hand = [CardRegistry.get("sv2-catch")]
        action = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0})
        encoder = ActionStateEncoder()

        without_target = encoder.encode_action(state, 1, action)
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        with_target = encoder.encode_action(state, 1, action)

        self.assertEqual(len(without_target.numeric), ACTION_NUMERIC_SIZE)
        self.assertEqual(len(with_target.numeric), ACTION_NUMERIC_SIZE)
        self.assertNotEqual(without_target.numeric, with_target.numeric)

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
        self.assertIn("--trainer", help_result.stdout)
        self.assertIn("--updates-per-rollout", help_result.stdout)
        self.assertIn("--teacher-search-preset", help_result.stdout)
        self.assertIn("--dagger-games", help_result.stdout)
        self.assertIn("--model", help_result.stdout)
        self.assertIn("--choice-head-enabled", help_result.stdout)
        self.assertIn("--acceptance-metric", help_result.stdout)
        self.assertIn("--min-win-delta", help_result.stdout)
        self.assertIn("--teacher-label-model-states", help_result.stdout)
        self.assertIn("--replay-buffer-size", help_result.stdout)
        self.assertIn("--replay-sample-ratio", help_result.stdout)
        self.assertIn("--distill-dataset", help_result.stdout)
        self.assertIn("--distill-epochs", help_result.stdout)
        self.assertIn("--distill-val-split", help_result.stdout)
        self.assertIn("--league-dir", help_result.stdout)
        self.assertIn("--league-eval-games", help_result.stdout)
        self.assertIn("--league-use-mcts", help_result.stdout)
        self.assertIn("--min-elo-delta", help_result.stdout)
        self.assertIn("--min-score-rate", help_result.stdout)
        self.assertIn("--min-point-rate", help_result.stdout)
        self.assertIn("--max-step-exhaustion-rate", help_result.stdout)

        with temp_dir() as tmpdir:
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
                self.assertTrue(os.path.exists(os.path.splitext(output)[0] + ".rejected.pt"))
                self.assertTrue(os.path.exists(progress))
                with open(progress, "r", encoding="utf-8") as fh:
                    event_types = [json.loads(line)["type"] for line in fh if line.strip()]
                self.assertIn("run_started", event_types)
                self.assertIn("run_finished", event_types)

        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "water.pt")
            progress = os.path.join(tmpdir, "water.jsonl")
            result = subprocess.run(
                [
                    sys.executable,
                    "scripts/train_deep_ai.py",
                    "--trainer",
                    "alpha_zero_rl",
                    "--deck",
                    "water",
                    "--games",
                    "0",
                    "--league-eval-games",
                    "0",
                    "--no-warm-start",
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
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(os.path.exists(os.path.splitext(output)[0] + ".rejected.pt"))
                with open(progress, "r", encoding="utf-8") as fh:
                    events = [json.loads(line) for line in fh if line.strip()]
                self.assertEqual(events[0]["trainer"], "alpha_zero_rl")
                self.assertEqual(events[0]["deck_keys"], ["water"])

    def test_training_cli_resolves_repo_relative_paths(self):
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "repo_relative_model.pt")
            progress = os.path.join(tmpdir, "repo_relative_progress.jsonl")
            rel_output = os.path.relpath(output, repo_root)
            rel_progress = os.path.relpath(progress, repo_root)
            result = subprocess.run(
                [
                    sys.executable,
                    "python/scripts/train_deep_ai.py",
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
                    "--pure-rl-games",
                    "0",
                    "--replay-same-deal",
                    "0",
                    "--no-warm-start",
                    "--output",
                    rel_output,
                    "--progress-jsonl",
                    rel_progress,
                ],
                cwd=repo_root,
                text=True,
                capture_output=True,
                timeout=60,
            )
            if importlib.util.find_spec("torch") is None:
                self.assertEqual(result.returncode, 2)
                self.assertTrue(os.path.exists(progress))
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(os.path.exists(os.path.splitext(output)[0] + ".rejected.pt"))
                self.assertTrue(os.path.exists(progress))
                self.assertFalse(
                    os.path.exists(os.path.join(repo_root, "python", rel_output))
                )

    def test_distill_jsonl_loader_reads_action_and_choice_examples(self):
        from engine.ai.dl import training as dl_training

        action_row = {
            "kind": "action",
            "deck_key": "fire",
            "state_numeric": [0.25] * STATE_NUMERIC_SIZE,
            "state_card_ids": [1] * STATE_CARD_SLOTS,
            "candidate_action_numeric": [
                [0.1] * ACTION_NUMERIC_SIZE,
                [0.9] * ACTION_NUMERIC_SIZE,
            ],
            "candidate_action_cards": [3, 7],
            "target_index": 1,
            "teacher_score": 0.8,
            "seed": 1234,
            "seed_block": 2,
            "matchup_key": "fire_vs_water",
        }
        choice_row = {
            "kind": "choice",
            "deck_key": "fire",
            "request_type": "bench_selection",
            "state_numeric": [0.5] * STATE_NUMERIC_SIZE,
            "state_card_ids": [2] * STATE_CARD_SLOTS,
            "candidate_choice_numeric": [
                [0.2] * ACTION_NUMERIC_SIZE,
                [0.8] * ACTION_NUMERIC_SIZE,
            ],
            "candidate_choice_cards": [11, 13],
            "target_index": 0,
            "seed": 1234,
            "seed_block": 2,
            "matchup_key": "fire_vs_water",
        }
        other_row = dict(action_row)
        other_row["deck_key"] = "water"

        with temp_dir() as tmpdir:
            dataset = os.path.join(tmpdir, "distill.jsonl")
            with open(dataset, "w", encoding="utf-8") as fh:
                for row in (action_row, choice_row, other_row):
                    fh.write(json.dumps(row) + "\n")

            actions, choices, stats = dl_training._load_distill_examples([dataset], "fire")

        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0].target_index, 1)
        self.assertEqual(actions[0].source, "distill")
        self.assertEqual(len(actions[0].actions), 2)
        self.assertEqual(actions[0].actions[1].card_id, 7)
        self.assertEqual(actions[0].value_target, 0.8)
        self.assertEqual(actions[0].split_key, "fire_vs_water:2:1234")
        self.assertEqual(len(choices), 1)
        self.assertEqual(choices[0].teacher_target_index, 0)
        self.assertEqual(choices[0].source, "distill")
        self.assertEqual(choices[0].request_type, "bench_selection")
        self.assertEqual(choices[0].split_key, "fire_vs_water:2:1234")
        self.assertEqual(stats["rows"], 3)
        self.assertEqual(stats["wrong_deck"], 1)
        self.assertEqual(stats["action_examples"], 1)
        self.assertEqual(stats["choice_examples"], 1)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_train_examples_uses_episode_return_for_self_play_value_loss(self):
        from engine.ai.dl.encoder import EncodedAction, EncodedState
        from engine.ai.dl.model import torch
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.training import TrainingExample

        assert torch is not None

        class TinyModel(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.weight = torch.nn.Parameter(torch.tensor(0.1))
                self.state_numeric_size = STATE_NUMERIC_SIZE
                self.state_card_slots = STATE_CARD_SLOTS
                self.action_numeric_size = ACTION_NUMERIC_SIZE

        model = TinyModel()
        example = TrainingExample(
            EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS),
            [
                EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0),
                EncodedAction([1.0] * ACTION_NUMERIC_SIZE, 1),
            ],
            0,
            source="self_play",
            return_target=0.75,
            value_target=-0.5,
            advantage=1.0,
        )
        captured_targets = []

        def fake_forward_batch(model_arg, examples, device):
            batch = len(examples)
            logits = torch.stack([model_arg.weight, -model_arg.weight]).repeat(batch, 1)
            value = model_arg.weight.repeat(batch)
            mask = torch.ones(batch, 2, dtype=torch.bool)
            return logits, value, mask

        import torch.nn.functional as F

        original_mse_loss = F.mse_loss

        def capture_mse_loss(input_tensor, target_tensor, *args, **kwargs):
            captured_targets.extend(target_tensor.detach().cpu().tolist())
            return original_mse_loss(input_tensor, target_tensor, *args, **kwargs)

        with mock.patch.object(dl_training, "_forward_batch", fake_forward_batch), \
             mock.patch("torch.nn.functional.mse_loss", side_effect=capture_mse_loss):
            dl_training._train_examples(
                model,
                [example],
                device="cpu",
                learning_rate=1e-3,
                epochs=1,
                batch_size=1,
            )

        self.assertEqual(captured_targets, [0.75])

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_train_examples_uses_teacher_value_targets_for_dagger(self):
        from engine.ai.dl.encoder import EncodedAction, EncodedState
        from engine.ai.dl.model import torch
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.training import TrainingExample

        assert torch is not None

        class TinyModel(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.weight = torch.nn.Parameter(torch.tensor(0.1))
                self.state_numeric_size = STATE_NUMERIC_SIZE
                self.state_card_slots = STATE_CARD_SLOTS
                self.action_numeric_size = ACTION_NUMERIC_SIZE

        model = TinyModel()
        example = TrainingExample(
            EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS),
            [
                EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0),
                EncodedAction([1.0] * ACTION_NUMERIC_SIZE, 1),
            ],
            0,
            source="dagger",
            value_target=0.42,
            return_target=-0.75,
            teacher_target_index=0,
        )
        captured_targets = []

        def fake_forward_batch(model_arg, examples, device):
            batch = len(examples)
            logits = torch.stack([model_arg.weight, -model_arg.weight]).repeat(batch, 1)
            value = model_arg.weight.repeat(batch)
            mask = torch.ones(batch, 2, dtype=torch.bool)
            return logits, value, mask

        import torch.nn.functional as F

        original_mse_loss = F.mse_loss

        def capture_mse_loss(input_tensor, target_tensor, *args, **kwargs):
            captured_targets.extend(target_tensor.detach().cpu().tolist())
            return original_mse_loss(input_tensor, target_tensor, *args, **kwargs)

        with mock.patch.object(dl_training, "_forward_batch", fake_forward_batch), \
             mock.patch("torch.nn.functional.mse_loss", side_effect=capture_mse_loss):
            dl_training._train_examples(
                model,
                [example],
                device="cpu",
                learning_rate=1e-3,
                epochs=1,
                batch_size=1,
            )

        self.assertEqual(len(captured_targets), 1)
        self.assertAlmostEqual(captured_targets[0], 0.42, places=6)

    def test_supervised_example_weight_prioritizes_development_actions_only(self):
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.encoder import ACTION_TYPES, EncodedAction, EncodedState
        from engine.ai.dl.training import TrainingExample

        def action(action_name: str) -> EncodedAction:
            numeric = [0.0] * ACTION_NUMERIC_SIZE
            numeric[ACTION_TYPES.index(action_name)] = 1.0
            return EncodedAction(numeric, 0)

        state = EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS)
        trainer = TrainingExample(
            state,
            [action(PlayerAction.PLAY_TRAINER.name)],
            0,
            source="dagger",
        )
        attack = TrainingExample(
            state,
            [action(PlayerAction.DECLARE_ATTACK.name)],
            0,
            source="dagger",
        )
        self_play = TrainingExample(
            state,
            [action(PlayerAction.PLAY_TRAINER.name)],
            0,
            source="self_play",
        )

        self.assertGreater(dl_training._supervised_example_weight(trainer), 1.0)
        self.assertLess(dl_training._supervised_example_weight(attack), 1.0)
        self.assertEqual(dl_training._supervised_example_weight(self_play), 1.0)

    def test_deep_model_selection_uses_challenge_postprocessor(self):
        from engine.ai.dl.training import _postprocess_preferred_action

        attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0})
        trainer = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0})
        calls = []

        class FakeAI:
            def _validated_or_fallback_action(self, state, player_idx, preferred, actions):
                calls.append((player_idx, preferred, actions))
                return trainer

        selected = _postprocess_preferred_action(FakeAI(), object(), 1, attack, [attack, trainer])

        self.assertIs(selected, trainer)
        self.assertEqual(calls, [(1, attack, [attack, trainer])])

    def test_same_deal_replay_examples_are_trained_and_counted(self):
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.encoder import EncodedAction, EncodedState
        from engine.ai.dl.training import DeepTrainingConfig, TrainingExample

        example = TrainingExample(
            EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS),
            [EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0)],
            0,
            source="self_play",
            return_target=1.0,
            advantage=1.0,
        )

        def fake_play_model_game(*args, **kwargs):
            clone = TrainingExample(
                example.state,
                example.actions,
                example.target_index,
                source="self_play",
                return_target=1.0,
                advantage=1.0,
            )
            return 0, 100.0, [clone], [], {"actions": 1, "invalid_actions": 0, "no_target_actions": 0}

        def fake_train_examples(_model, examples, **_kwargs):
            return {
                "examples": len(examples),
                "loss": 0.0,
                "total_loss": 0.0,
                "policy_loss": 0.0,
                "value_loss": 0.0,
                "entropy": 0.0,
            }

        events = []
        with mock.patch.object(dl_training, "_collect_bootstrap_examples_parallel", return_value=[]), \
             mock.patch.object(dl_training, "_model_payload_for_worker", return_value=({}, {})), \
             mock.patch.object(dl_training, "_play_model_game", side_effect=fake_play_model_game), \
             mock.patch.object(dl_training, "_train_examples", side_effect=fake_train_examples), \
             mock.patch.object(dl_training, "_train_choice_examples", return_value={"choice_examples": 0, "choice_loss": 0.0}), \
             mock.patch.object(dl_training, "evaluate_model", return_value={"games": 0, "wins": 0, "losses": 0, "draws": 0, "avg_score": 0.0}):
            summary, _total_done = dl_training._train_deck_pipeline(
                object(),
                "fire",
                17,
                DeepTrainingConfig(
                    deck="fire",
                    games=0,
                    bootstrap_games=0,
                    dagger_games=0,
                    eval_games=0,
                    pure_rl_games=0,
                    replay_same_deal=1,
                    use_mcts_training=True,
                    mcts_simulations=1,
                    max_steps=20,
                ),
                events.append,
                0,
                3,
            )

        self.assertEqual(summary["self_play"]["examples"], 3)
        self.assertTrue(any(event.get("phase") == "same_deal_replay" for event in events))

    def test_model_game_task_passes_mcts_and_pure_rl_flags_to_worker(self):
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.training import ModelGameTask

        captured = {}

        def fake_play_model_game(*args, **kwargs):
            captured.update(kwargs)
            return None, 0.0, [], [], {"actions": 0, "invalid_actions": 0, "no_target_actions": 0}

        task = ModelGameTask(
            "fire",
            17,
            20,
            True,
            {},
            {},
            "fast",
            pure_rl=True,
            use_mcts=True,
            mcts_simulations=7,
            mcts_chance_nodes=False,
        )
        with mock.patch.object(dl_training, "_model_from_worker_payload", return_value=object()), \
             mock.patch.object(dl_training, "_play_model_game", side_effect=fake_play_model_game):
            dl_training._execute_model_game_task(task)

        self.assertTrue(captured["pure_rl"])
        self.assertTrue(captured["use_mcts"])
        self.assertEqual(captured["mcts_simulations"], 7)
        self.assertFalse(captured["mcts_chance_nodes"])

    def test_deep_training_task_runner_reuses_model_game_executor(self):
        from engine.ai.dl import training as dl_training

        calls = {"created": 0, "mapped": 0}

        class FakeExecutor:
            def __init__(self, max_workers=None, initializer=None):
                calls["created"] += 1
                self.max_workers = max_workers
                self.initializer = initializer

            def map(self, fn, tasks):
                calls["mapped"] += 1
                return [fn(task) for task in tasks]

            def shutdown(self, wait=True):
                calls["shutdown"] = wait

        def fake_execute(task):
            return None, 0.0, [], [], {}

        tasks = [
            dl_training.ModelGameTask("fire", 1, 20, False, {}, {}, "fast"),
            dl_training.ModelGameTask("fire", 2, 20, False, {}, {}, "fast"),
        ]
        with mock.patch.object(dl_training, "ProcessPoolExecutor", FakeExecutor), \
             mock.patch.object(dl_training, "_execute_model_game_task", fake_execute):
            with dl_training.DeepTrainingTaskRunner(workers=4) as runner:
                runner.run_model_game_tasks(tasks)
                runner.run_model_game_tasks(tasks)

        self.assertEqual(calls["created"], 1)
        self.assertEqual(calls["mapped"], 2)
        self.assertTrue(calls["shutdown"])

    def test_deep_model_acceptance_helper_requires_verified_accepted_metadata(self):
        from engine.ai.dl.controller import is_deep_model_accepted

        with temp_dir() as tmpdir:
            model_dir = os.path.join(tmpdir, "models")
            os.makedirs(model_dir)
            model_path = os.path.join(model_dir, "fire.pt")
            sidecar_path = os.path.join(model_dir, "fire.json")
            with open(model_path, "wb") as fh:
                fh.write(b"model")

            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({"metadata": {"accepted": True, "verified": False}}, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({"metadata": {"accepted": True, "verified": True}}, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({"metadata": {"accepted": True, "verified": True, "eval_games": 599}}, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "summary": {"fire": {"eval": {"games": 600, "invalid_action_rate": 0.1, "no_target_action_rate": 0.0}}},
                    }
                }, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "summary": {"fire": {"eval": {"games": 600, "invalid_action_rate": 0.0, "no_target_action_rate": 0.2}}},
                    }
                }, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": 3,
                        "action_version": 2,
                        "encoder_version": 2,
                        "planner_version": 1,
                        "seed": 17,
                        "summary": {"fire": {"eval": {"games": 600, "wins": 600, "invalid_action_rate": 0.0, "no_target_action_rate": 0.0}}},
                    }
                }, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "planner_version": 1,
                        "seed": 17,
                        "choice_head_enabled": True,
                        "summary": {"fire": {
                            "choice": {"choice_examples": 0},
                            "loaded_choice_examples": 12,
                            "eval": {"games": 600, "wins": 300, "draws": 0, "invalid_action_rate": 0.0, "no_target_action_rate": 0.0},
                        }},
                    }
                }, fh)
            self.assertTrue(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "planner_version": 1,
                        "seed": 17,
                        "summary": {"fire": {"eval": {"games": 600, "wins": 299, "draws": 0, "invalid_action_rate": 0.0, "no_target_action_rate": 0.0}}},
                    }
                }, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": 3,
                        "action_version": 2,
                        "encoder_version": 3,
                        "planner_version": 1,
                        "seed": 17,
                        "choice_head_enabled": True,
                        "summary": {"fire": {
                            "choice": {"choice_examples": 0},
                            "eval": {"games": 600, "wins": 300, "draws": 0, "invalid_action_rate": 0.0, "no_target_action_rate": 0.0},
                        }},
                    }
                }, fh)
            self.assertFalse(is_deep_model_accepted("fire", model_dir=model_dir))

            with open(sidecar_path, "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "planner_version": 1,
                        "seed": 17,
                        "summary": {"fire": {"eval": {
                            "games": 600,
                            "wins": 300,
                            "draws": 0,
                            "invalid_action_rate": 0.0,
                            "no_target_action_rate": 0.0,
                            "max_step_exhaustion_rate": 0.05,
                        }}},
                    }
                }, fh)
            self.assertTrue(is_deep_model_accepted("fire", model_dir=model_dir))

    def test_validate_ai_models_rejects_low_strength_and_untrained_choice_head(self):
        from scripts.validate_ai_models import validate_model

        with temp_dir() as tmpdir:
            model_dir = os.path.join(tmpdir, "models")
            os.makedirs(model_dir)
            with open(os.path.join(model_dir, "fire.pt"), "wb") as fh:
                fh.write(b"model")
            with open(os.path.join(model_dir, "fire.json"), "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "planner_version": 1,
                        "seed": 17,
                        "choice_head_enabled": True,
                        "summary": {"fire": {
                            "choice": {"choice_examples": 0},
                            "eval": {
                                "games": 600,
                                "wins": 126,
                                "losses": 474,
                                "draws": 0,
                                "invalid_action_rate": 0.0,
                                "no_target_action_rate": 0.0,
                                "rule_exception_rate": 0.0,
                                "decision_timeout_rate": 0.0,
                                "max_step_exhaustion_rate": 0.073333,
                            },
                        }},
                    }
                }, fh)

            row = validate_model(
                "fire",
                model_dir=model_dir,
                min_games=600,
                min_point_rate=0.50,
                min_delta_point_rate=0.0,
                max_step_exhaustion_rate=0.05,
            )

        self.assertFalse(row["valid"])
        self.assertIn("insufficient_point_rate", row["errors"])
        self.assertIn("max_step_exhaustion_rate", row["errors"])
        self.assertIn("choice_head_untrained", row["errors"])
        self.assertIn("missing_checkpoint_sha256", row["errors"])
        self.assertIn("invalid_checkpoint", row["errors"])

    @unittest.skipIf(importlib.util.find_spec("onnx") is None, "ONNX is not installed")
    @unittest.skipIf(importlib.util.find_spec("onnxruntime") is None, "ONNX Runtime is not installed")
    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_onnx_export_preflights_missing_release_checkpoints(self):
        from pathlib import Path
        from scripts.export_onnx_models import DECK_KEYS, export_all

        with temp_dir() as tmpdir:
            checkpoint_root = Path(tmpdir) / "models"
            output_root = Path(tmpdir) / "onnx"
            checkpoint_root.mkdir()
            for deck_key in DECK_KEYS:
                if deck_key != "steel":
                    (checkpoint_root / f"{deck_key}.pt").write_bytes(b"placeholder")

            with self.assertRaisesRegex(FileNotFoundError, "steel.pt"):
                export_all(output_root, checkpoint_root=checkpoint_root)

            self.assertFalse(output_root.exists())

    @unittest.skipIf(importlib.util.find_spec("onnx") is None, "ONNX is not installed")
    @unittest.skipIf(importlib.util.find_spec("onnxruntime") is None, "ONNX Runtime is not installed")
    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_onnx_export_preflight_rejects_old_checkpoint_schema_before_writes(self):
        from pathlib import Path
        from scripts import export_onnx_models

        def fake_load(path, _device):
            deck_key = Path(path).stem
            return object(), {
                "version": export_onnx_models.CHECKPOINT_VERSION - 1,
                "schema": {
                    "rules_version": export_onnx_models.RULES_SCHEMA_VERSION,
                    "action_version": export_onnx_models.ACTION_SCHEMA_VERSION,
                    "encoder_version": export_onnx_models.ENCODER_SCHEMA_VERSION,
                },
                "metadata": {
                    "deck": deck_key,
                    "accepted": True,
                    "verified": True,
                    "planner_version": export_onnx_models.PLANNER_SCHEMA_VERSION,
                },
            }

        with mock.patch.object(export_onnx_models, "load_checkpoint", side_effect=fake_load):
            with self.assertRaisesRegex(ValueError, "checkpoint_version"):
                export_onnx_models._preflight_release_checkpoints(Path("models"))

    @unittest.skipIf(importlib.util.find_spec("onnx") is None, "ONNX is not installed")
    @unittest.skipIf(importlib.util.find_spec("onnxruntime") is None, "ONNX Runtime is not installed")
    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_model_promotion_prepares_complete_set_and_normalizes_sidecars(self):
        from pathlib import Path
        from scripts import promote_ai_models

        with temp_dir() as tmpdir:
            source = Path(tmpdir) / "staged"
            destination = Path(tmpdir) / "release"
            source.mkdir()
            for deck_key in ("fire", "water"):
                (source / f"{deck_key}.pt").write_bytes(f"model-{deck_key}".encode())
                (source / f"{deck_key}.json").write_text(
                    json.dumps({
                        "model_path": str(source / f"{deck_key}.pt"),
                        "metadata": {"deck": deck_key, "accepted": True, "verified": True},
                    }),
                    encoding="utf-8",
                )

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", ("fire", "water")),
                mock.patch.object(promote_ai_models, "_validate_staged"),
            ):
                checksums = promote_ai_models.promote(source, destination)

            self.assertEqual(set(checksums), {"fire", "water"})
            for deck_key in ("fire", "water"):
                self.assertEqual(
                    (destination / f"{deck_key}.pt").read_bytes(),
                    f"model-{deck_key}".encode(),
                )
                sidecar = json.loads(
                    (destination / f"{deck_key}.json").read_text(encoding="utf-8")
                )
                self.assertEqual(
                    sidecar["model_path"],
                    os.path.join("data", "ai_models", f"{deck_key}.pt"),
                )

    @unittest.skipIf(importlib.util.find_spec("onnx") is None, "ONNX is not installed")
    @unittest.skipIf(importlib.util.find_spec("onnxruntime") is None, "ONNX Runtime is not installed")
    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_model_promotion_restores_previous_release_when_final_validation_fails(self):
        from pathlib import Path
        from scripts import promote_ai_models

        with temp_dir() as tmpdir:
            source = Path(tmpdir) / "staged"
            destination = Path(tmpdir) / "release"
            source.mkdir()
            destination.mkdir()
            for deck_key in ("fire", "water"):
                (source / f"{deck_key}.pt").write_bytes(f"new-{deck_key}".encode())
                (source / f"{deck_key}.json").write_text(
                    json.dumps({"metadata": {"deck": deck_key}}),
                    encoding="utf-8",
                )
                (destination / f"{deck_key}.pt").write_bytes(f"old-{deck_key}".encode())
                (destination / f"{deck_key}.json").write_text(
                    json.dumps({"metadata": {"deck": deck_key, "release": "old"}}),
                    encoding="utf-8",
                )

            def validate(path):
                if Path(path).resolve() == destination.resolve():
                    raise ValueError("simulated final validation failure")

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", ("fire", "water")),
                mock.patch.object(promote_ai_models, "_validate_staged", side_effect=validate),
            ):
                with self.assertRaisesRegex(ValueError, "simulated final validation failure"):
                    promote_ai_models.promote(source, destination)

            for deck_key in ("fire", "water"):
                self.assertEqual(
                    (destination / f"{deck_key}.pt").read_bytes(),
                    f"old-{deck_key}".encode(),
                )
                restored = json.loads(
                    (destination / f"{deck_key}.json").read_text(encoding="utf-8")
                )
                self.assertEqual(restored["metadata"]["release"], "old")

    @unittest.skipIf(importlib.util.find_spec("onnx") is None, "ONNX is not installed")
    @unittest.skipIf(importlib.util.find_spec("onnxruntime") is None, "ONNX Runtime is not installed")
    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_onnx_export_failure_leaves_live_runtime_bundle_unchanged(self):
        from pathlib import Path
        from scripts import export_onnx_models

        with temp_dir() as tmpdir:
            root = Path(tmpdir)
            checkpoints = root / "checkpoints"
            output_root = root / "data" / "ai_models"
            checkpoints.mkdir()
            output_root.mkdir(parents=True)
            for deck_key in ("fire", "water"):
                (checkpoints / f"{deck_key}.pt").write_bytes(f"checkpoint-{deck_key}".encode())
                (output_root / f"{deck_key}.onnx").write_bytes(f"old-{deck_key}".encode())
            manifest_path = output_root.parent / "ai_models_runtime.json"
            manifest_path.write_text('{"release":"old"}\n', encoding="utf-8")

            def fake_export(checkpoint, output, **_kwargs):
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(f"new-{checkpoint.stem}".encode())
                return {
                    "version": export_onnx_models.CHECKPOINT_VERSION,
                    "schema": {
                        "rules_version": export_onnx_models.RULES_SCHEMA_VERSION,
                        "action_version": export_onnx_models.ACTION_SCHEMA_VERSION,
                        "encoder_version": export_onnx_models.ENCODER_SCHEMA_VERSION,
                    },
                    "model_config": {"choice_head_enabled": True},
                }, object()

            def fake_verify(_wrapper, output, **_kwargs):
                if output.stem == "water":
                    raise RuntimeError("simulated parity failure")
                return {name: 0.0 for name in export_onnx_models.OUTPUT_NAMES}

            loaded = {deck_key: (object(), {}) for deck_key in ("fire", "water")}
            with (
                mock.patch.object(export_onnx_models, "DECK_KEYS", ("fire", "water")),
                mock.patch.object(export_onnx_models, "_preflight_release_checkpoints", return_value=loaded),
                mock.patch.object(export_onnx_models, "_export_one", side_effect=fake_export),
                mock.patch.object(export_onnx_models, "_verify_one", side_effect=fake_verify),
            ):
                with self.assertRaisesRegex(RuntimeError, "simulated parity failure"):
                    export_onnx_models.export_all(output_root, checkpoint_root=checkpoints)

            for deck_key in ("fire", "water"):
                self.assertEqual(
                    (output_root / f"{deck_key}.onnx").read_bytes(),
                    f"old-{deck_key}".encode(),
                )
            self.assertEqual(
                json.loads(manifest_path.read_text(encoding="utf-8")),
                {"release": "old"},
            )

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_regate_validates_staged_checkpoint_before_replacing_named_output(self):
        from pathlib import Path
        from scripts import regate_deep_checkpoint

        metadata = {
            "deck": "steel",
            "summary": {"steel": {"eval": {"games": 600}}},
        }
        payload = {"metadata": metadata}
        with temp_dir() as tmpdir:
            root = Path(tmpdir)
            source = root / "steel.rejected.pt"
            source.write_bytes(b"source")
            source.with_suffix(".json").write_text(
                json.dumps({"metadata": metadata}),
                encoding="utf-8",
            )
            output = root / "release-candidate.pt"
            output.write_bytes(b"old-output")
            output.with_suffix(".json").write_text('{"release":"old"}', encoding="utf-8")

            def fake_save(path, _model, _metadata):
                Path(path).write_bytes(b"regated-output")

            def fake_validate(deck_key, *, model_dir, **_kwargs):
                staged = Path(model_dir)
                self.assertNotEqual(staged.resolve(), root.resolve())
                self.assertTrue((staged / f"{deck_key}.pt").is_file())
                self.assertTrue((staged / f"{deck_key}.json").is_file())
                return {"deck": deck_key, "valid": True, "errors": [], "model_path": "staged"}

            with (
                mock.patch.object(regate_deep_checkpoint, "load_checkpoint", return_value=(object(), payload)),
                mock.patch.object(regate_deep_checkpoint, "save_checkpoint", side_effect=fake_save),
                mock.patch.object(regate_deep_checkpoint, "_verify_evidence"),
                mock.patch.object(regate_deep_checkpoint, "validate_model", side_effect=fake_validate),
            ):
                result = regate_deep_checkpoint.regate(source, output, deck_key="steel")

            self.assertEqual(output.read_bytes(), b"regated-output")
            self.assertEqual(result["model_path"], str(output.resolve()))
            sidecar = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
            self.assertEqual(sidecar["model_path"], str(output.resolve()))

    def test_release_gate_uses_paired_challenge_baseline_when_available(self):
        from engine.ai.dl.controller import is_deep_model_accepted
        from engine.ai.dl.training import _accepts_candidate
        from scripts.validate_ai_models import validate_model

        weak_baseline = {"games": 600, "wins": 180, "losses": 420, "draws": 0, "avg_score": -200.0}
        candidate = {
            "games": 600,
            "wins": 190,
            "losses": 410,
            "draws": 0,
            "avg_score": -150.0,
            "invalid_action_rate": 0.0,
            "no_target_action_rate": 0.0,
            "rule_exception_rate": 0.0,
            "decision_timeout_rate": 0.0,
            "max_step_exhaustion_rate": 0.0,
        }
        self.assertTrue(
            _accepts_candidate(
                candidate,
                weak_baseline,
                None,
                acceptance_metric="points",
                min_point_rate=0.50,
                min_delta_point_rate=0.0,
                max_step_exhaustion_rate=0.05,
            )
        )
        stronger_old_model = dict(candidate, wins=240, losses=360, avg_score=50.0)
        self.assertTrue(
            _accepts_candidate(
                candidate,
                weak_baseline,
                stronger_old_model,
                acceptance_metric="points",
                min_point_rate=0.50,
                min_delta_point_rate=0.0,
                max_step_exhaustion_rate=0.05,
            )
        )

        with temp_dir() as tmpdir:
            model_dir = os.path.join(tmpdir, "models")
            os.makedirs(model_dir)
            with open(os.path.join(model_dir, "fire.pt"), "wb") as fh:
                fh.write(b"model")
            with open(os.path.join(model_dir, "fire.json"), "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "planner_version": 1,
                        "seed": 17,
                        "choice_head_enabled": True,
                        "summary": {"fire": {
                            "challenge_baseline_eval": weak_baseline,
                            "choice": {"choice_examples": 0},
                            "loaded_choice_examples": 12,
                            "eval": candidate,
                        }},
                    }
                }, fh)

            with mock.patch(
                "scripts.validate_ai_models._checkpoint_identity_errors",
                return_value=[],
            ):
                row = validate_model(
                    "fire",
                    model_dir=model_dir,
                    min_games=600,
                    min_point_rate=0.50,
                    min_delta_point_rate=0.0,
                    max_step_exhaustion_rate=0.05,
                )

            self.assertTrue(row["valid"], row["errors"])
            self.assertGreaterEqual(row["delta_point_rate"], 0.0)
            self.assertTrue(is_deep_model_accepted("fire", model_dir=model_dir))

    def test_release_gate_pairs_long_game_reliability_with_challenge_baseline(self):
        from engine.ai.dl.controller import is_deep_model_accepted
        from engine.ai.dl.training import _accepts_candidate
        from scripts.validate_ai_models import validate_model

        baseline = {
            "games": 600,
            "wins": 323,
            "losses": 277,
            "draws": 0,
            "max_step_exhaustion_rate": 0.151667,
        }
        improved = {
            "games": 600,
            "wins": 326,
            "losses": 274,
            "draws": 0,
            "invalid_action_rate": 0.0,
            "no_target_action_rate": 0.0,
            "rule_exception_rate": 0.0,
            "decision_timeout_rate": 0.0,
            "max_step_exhaustion_rate": 0.123333,
        }
        regressed = dict(improved, max_step_exhaustion_rate=0.16)
        self.assertTrue(
            _accepts_candidate(
                improved,
                baseline,
                None,
                acceptance_metric="points",
                min_point_rate=0.50,
                min_delta_point_rate=0.0,
                max_step_exhaustion_rate=0.05,
            )
        )
        self.assertFalse(
            _accepts_candidate(
                regressed,
                baseline,
                None,
                acceptance_metric="points",
                min_point_rate=0.50,
                min_delta_point_rate=0.0,
                max_step_exhaustion_rate=0.05,
            )
        )

        with temp_dir() as tmpdir:
            model_dir = os.path.join(tmpdir, "models")
            os.makedirs(model_dir)
            with open(os.path.join(model_dir, "steel.pt"), "wb") as fh:
                fh.write(b"model")
            with open(os.path.join(model_dir, "steel.json"), "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "accepted": True,
                        "verified": True,
                        "eval_games": 600,
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "planner_version": 1,
                        "seed": 17,
                        "choice_head_enabled": True,
                        "summary": {"steel": {
                            "challenge_baseline_eval": baseline,
                            "loaded_choice_examples": 100,
                            "eval": improved,
                        }},
                    }
                }, fh)

            with mock.patch(
                "scripts.validate_ai_models._checkpoint_identity_errors",
                return_value=[],
            ):
                row = validate_model(
                    "steel",
                    model_dir=model_dir,
                    min_games=600,
                    min_point_rate=0.50,
                    min_delta_point_rate=0.0,
                    max_step_exhaustion_rate=0.05,
                )
            self.assertTrue(row["valid"], row["errors"])
            self.assertAlmostEqual(row["allowed_max_step_exhaustion_rate"], 0.151667)
            self.assertLess(row["delta_max_step_exhaustion_rate"], 0.0)
            self.assertTrue(is_deep_model_accepted("steel", model_dir=model_dir))

    def test_reused_challenge_baseline_progress_validates_run_identity(self):
        from scripts.train_deep_ai import _load_challenge_baseline_progress

        baseline = {
            "games": 2,
            "wins": 1,
            "losses": 1,
            "draws": 0,
            "game_points": [1.0, 0.0],
        }
        events = [
            {
                "type": "run_started",
                "deck": "steel",
                "seed": 29,
                "eval_games": 2,
                "max_steps": 160,
                "teacher_search_preset": "quality",
            },
            {
                "type": "dagger_game_finished",
                "deck": "steel",
                "choice_examples": 7,
            },
            {
                "type": "challenge_baseline_eval_finished",
                "deck": "steel",
                "training_seed": 29,
                "eval_seed": 900029,
                "eval": baseline,
            },
        ]
        with temp_dir() as tmpdir:
            progress_path = os.path.join(tmpdir, "steel.jsonl")
            with open(progress_path, "w", encoding="utf-8") as fh:
                for event in events:
                    fh.write(json.dumps(event) + "\n")
            loaded, recovered_choice_examples = _load_challenge_baseline_progress(
                progress_path,
                deck_key="steel",
                training_seed=29,
                asserted_source_seed=None,
                eval_games=2,
                max_steps=160,
                teacher_search_preset="quality",
            )
            self.assertEqual(loaded, baseline)
            self.assertEqual(recovered_choice_examples, 7)
            with self.assertRaisesRegex(ValueError, "seed mismatch"):
                _load_challenge_baseline_progress(
                    progress_path,
                    deck_key="steel",
                    training_seed=17,
                    asserted_source_seed=None,
                    eval_games=2,
                    max_steps=160,
                    teacher_search_preset="quality",
                )

    def test_validate_models_cli_path_is_relative_to_invocation_directory(self):
        from scripts import validate_ai_models

        with temp_dir() as tmpdir:
            with mock.patch.object(validate_ai_models, "INVOCATION_CWD", tmpdir):
                resolved = validate_ai_models._resolve_cli_path(os.path.join("build", "models"))

        self.assertEqual(
            resolved,
            os.path.abspath(os.path.join(tmpdir, "build", "models")),
        )

    def test_release_gate_rejects_paired_challenge_baseline_regression(self):
        from engine.ai.dl.training import _accepts_candidate

        baseline = {"games": 600, "wins": 180, "losses": 420, "draws": 0, "avg_score": -200.0}
        regressed = {
            "games": 600,
            "wins": 170,
            "losses": 430,
            "draws": 0,
            "avg_score": -180.0,
            "invalid_action_rate": 0.0,
            "no_target_action_rate": 0.0,
            "rule_exception_rate": 0.0,
            "decision_timeout_rate": 0.0,
            "max_step_exhaustion_rate": 0.0,
        }
        self.assertFalse(
            _accepts_candidate(
                regressed,
                baseline,
                None,
                acceptance_metric="points",
                min_point_rate=0.50,
                min_delta_point_rate=0.0,
                max_step_exhaustion_rate=0.05,
            )
        )

    def test_release_gate_uses_one_percent_paired_noninferiority_floor(self):
        from engine.ai.dl.release_gate import (
            DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
            has_strength_and_reliability_floor,
        )
        from engine.ai.dl.training import _accepts_candidate

        baseline = {
            "games": 600,
            "wins": 332,
            "losses": 268,
            "draws": 0,
            "max_step_exhaustion_rate": 0.118333,
        }
        boundary = {
            "games": 600,
            "wins": 326,
            "losses": 274,
            "draws": 0,
            "max_step_exhaustion_rate": 0.105,
        }
        below = dict(boundary, wins=325, losses=275)
        self.assertEqual(DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE, -0.01)
        self.assertTrue(
            has_strength_and_reliability_floor(
                boundary,
                min_point_rate=0.50,
                paired_baseline=baseline,
                min_delta_point_rate=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
            )
        )
        self.assertTrue(
            _accepts_candidate(
                boundary,
                baseline,
                None,
                acceptance_metric="points",
                min_point_rate=0.50,
                min_delta_point_rate=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
                max_step_exhaustion_rate=0.05,
            )
        )
        self.assertFalse(
            has_strength_and_reliability_floor(
                below,
                min_point_rate=0.50,
                paired_baseline=baseline,
                min_delta_point_rate=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
            )
        )

    def test_eval_stats_record_paired_game_points(self):
        from engine.ai.dl import training

        with mock.patch.object(
            training,
            "_play_model_game",
            side_effect=[
                (0, 10.0, [], [], {"actions": 1}),
                (1, -5.0, [], [], {"actions": 1}),
                (None, 0.0, [], [], {"actions": 1}),
            ],
        ):
            result = training.evaluate_model(
                object(),
                "fire",
                17,
                3,
                device="cpu",
                workers=1,
            )

        self.assertEqual(result["game_points"], [1.0, 0.0, 0.5])
        self.assertEqual(result["point_rate"], 0.5)

        with mock.patch.object(
            training,
            "_play_challenge_baseline_game",
            side_effect=[
                (1, -1.0, [], [], {"actions": 1}),
                (1, -2.0, [], [], {"actions": 1}),
                (1, -3.0, [], [], {"actions": 1}),
            ],
        ):
            baseline = training.evaluate_challenge_baseline(
                "fire",
                17,
                3,
                workers=1,
            )

        self.assertEqual(baseline["game_points"], [0.0, 0.0, 0.0])
        delta = training._evaluation_delta(result, baseline)
        self.assertEqual(delta["paired_delta_point_rate"], 0.5)

    def test_challenge_deck_screen_defaults_to_deep_when_accepted_model_available(self):
        import pygame
        from ui.screens import deck_select
        from ui.screens.deck_select import DeckSelectScreen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

        with mock.patch.object(deck_select, "is_deep_model_accepted", side_effect=lambda deck_key: deck_key == "water", create=True):
            screen = DeckSelectScreen(
                Manager(),
                {"fire": FIRE_DECK, "water": WATER_DECK},
                mode="challenge",
            )

        self.assertEqual(screen.ai_kind, "deep_learning")

    def test_mcts_search_receives_runtime_deadline(self):
        from engine.ai.dl import controller as dl_controller

        selected = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        captured = {}

        class FakeMCTS:
            def __init__(self, *args, **kwargs):
                pass

            def select_action(self, state, player_idx, deck_key, *, actions=None, deterministic=True, deadline=None):
                captured["deadline"] = deadline
                return selected

        state = self._simple_state()
        ai = DeepLearningAI(
            "fire",
            DeepLearningAIConfig(
                max_thinking_time_seconds=8.0,
                fallback_config=AIConfig(
                    thinking_time_seconds=0.01,
                    deterministic_search=True,
                    max_sequence_depth=0,
                    max_turn_actions=8,
                    search_algorithm="beam",
                ),
            ),
        )
        ai.model = object()

        with mock.patch.object(dl_controller.time, "perf_counter", return_value=100.0), \
             mock.patch("engine.ai.dl.mcts.MCTSGuidedSearch", FakeMCTS):
            action = ai._choose_with_mcts(state, 1, [selected])

        self.assertEqual(action, selected)
        self.assertEqual(captured["deadline"], 108.0)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_deep_training_total_games_includes_pure_rl_and_same_deal(self):
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.training import DeepTrainingConfig, run_deep_training

        events = []
        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "model.pt")

            def fake_train_deck_pipeline(_model, _deck_key, _deck_seed, _config, _emit, total_done, _total_training_games, old_eval=None):
                return {"accepted": True, "eval": {"games": 0}}, total_done

            with mock.patch.object(dl_training, "_train_deck_pipeline", side_effect=fake_train_deck_pipeline):
                run_deep_training(
                    DeepTrainingConfig(
                        trainer="teacher_dagger_rl",
                        deck="fire",
                        games=1,
                        bootstrap_games=2,
                        dagger_games=3,
                        eval_games=4,
                        pure_rl_games=5,
                        replay_same_deal=6,
                        output=output,
                        device="cpu",
                        max_steps=20,
                    ),
                    progress_callback=events.append,
                )

        self.assertEqual(events[0]["total_training_games"], 33)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_alpha_zero_training_uses_only_self_play_examples(self):
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.encoder import EncodedAction, EncodedState
        from engine.ai.dl.model import create_model
        from engine.ai.dl.training import DeepTrainingConfig, TrainingExample

        example = TrainingExample(
            EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS),
            [
                EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0),
                EncodedAction([1.0] * ACTION_NUMERIC_SIZE, 1),
            ],
            1,
            source="self_play",
            return_target=1.0,
            value_target=0.5,
            advantage=1.0,
            policy_target=[0.25, 0.75],
        )
        trained_sources = []
        trained_policy_targets = []

        def fake_collect(*args, **kwargs):
            self.assertTrue(kwargs["pure_rl"])
            self.assertTrue(kwargs["use_mcts"])
            self.assertTrue(kwargs["rule_only"])
            self.assertFalse(kwargs["teacher_label_model_states"])
            return [(0, 100.0, [example], [], {"actions": 1, "invalid_actions": 0, "no_target_actions": 0})]

        def fake_train(_model, examples, **_kwargs):
            trained_sources.extend(ex.source for ex in examples)
            trained_policy_targets.extend(ex.policy_target for ex in examples)
            return {
                "examples": len(examples),
                "loss": 0.0,
                "total_loss": 0.0,
                "policy_loss": 0.0,
                "value_loss": 0.0,
                "entropy": 0.0,
            }

        events = []
        with mock.patch.object(dl_training, "_collect_bootstrap_examples_parallel") as bootstrap, \
             mock.patch.object(dl_training, "_teacher_label_state") as teacher_label, \
             mock.patch.object(dl_training, "_collect_rollout_batch", side_effect=fake_collect), \
             mock.patch.object(dl_training, "_add_verified_league_snapshots", return_value=[]), \
             mock.patch.object(dl_training, "_train_examples", side_effect=fake_train):
            summary, total_done = dl_training._train_deck_alpha_zero_pipeline(
                create_model(),
                "fire",
                17,
                DeepTrainingConfig(
                    trainer="alpha_zero_rl",
                    deck="fire",
                    games=1,
                    league_eval_games=0,
                    bootstrap_games=999,
                    dagger_games=999,
                    max_steps=20,
                    mcts_simulations=1,
                ),
                events.append,
                0,
                1,
            )

        bootstrap.assert_not_called()
        teacher_label.assert_not_called()
        self.assertEqual(total_done, 1)
        self.assertEqual(summary["trainer"], "alpha_zero_rl_v1")
        self.assertEqual(summary["bootstrap"]["examples"], 0)
        self.assertEqual(summary["dagger"]["examples"], 0)
        self.assertEqual(trained_sources, ["self_play"])
        self.assertEqual(trained_policy_targets, [[0.25, 0.75]])
        self.assertTrue(any(event.get("phase") == "alpha_zero_self_play_batch" for event in events))

    def test_alpha_zero_examples_use_terminal_value_targets(self):
        from engine.ai.dl.encoder import EncodedAction, EncodedState
        from engine.ai.dl.training import TrainingExample, _finalize_episode_examples

        example = TrainingExample(
            EncodedState([0.0] * STATE_NUMERIC_SIZE, [0] * STATE_CARD_SLOTS),
            [EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0)],
            0,
            source="self_play",
            reward=0.25,
            value_target=0.4,
            return_target=0.4,
            policy_target=[1.0],
            phase_tag="alpha_zero",
        )

        _finalize_episode_examples([example], terminal_reward=-1.0)

        self.assertEqual(example.value_target, -1.0)
        self.assertEqual(example.return_target, -1.0)
        self.assertAlmostEqual(example.advantage, -1.4)

    def test_alpha_zero_league_acceptance_and_verified_filter(self):
        from engine.ai.dl import training as dl_training

        accepted = {
            "games": 100,
            "wins": 55,
            "draws": 0,
            "invalid_action_rate": 0.0,
            "no_target_action_rate": 0.0,
            "rule_exception_rate": 0.0,
            "decision_timeout_rate": 0.0,
            "score_rate": 0.55,
            "elo_delta": dl_training._elo_delta_from_score_rate(0.55),
        }
        self.assertTrue(
            dl_training._accepts_league_result(
                accepted,
                min_score_rate=0.53,
                min_elo_delta=25.0,
            )
        )
        rejected = dict(accepted, invalid_action_rate=0.01)
        self.assertFalse(
            dl_training._accepts_league_result(
                rejected,
                min_score_rate=0.53,
                min_elo_delta=25.0,
            )
        )

        with temp_dir() as tmpdir:
            model_path = os.path.join(tmpdir, "fire.pt")
            with open(model_path, "wb") as fh:
                fh.write(b"checkpoint")
            with open(os.path.splitext(model_path)[0] + ".json", "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "deck": "fire",
                        "accepted": True,
                        "verified": True,
                        "rules_version": dl_training.RULES_SCHEMA_VERSION,
                        "action_version": dl_training.ACTION_SCHEMA_VERSION,
                        "encoder_version": dl_training.ENCODER_SCHEMA_VERSION,
                        "summary": {
                            "fire": {
                                "eval": {
                                    "games": 600,
                                    "wins": 300,
                                    "losses": 300,
                                    "draws": 0,
                                    "invalid_action_rate": 0.0,
                                    "no_target_action_rate": 0.0,
                                    "rule_exception_rate": 0.0,
                                    "decision_timeout_rate": 0.0,
                                    "max_step_exhaustion_rate": 0.05,
                                }
                            }
                        },
                    }
                }, fh)
            self.assertTrue(dl_training._checkpoint_is_verified_for_league(model_path, "fire"))
            with open(os.path.splitext(model_path)[0] + ".json", "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "deck": "fire",
                        "accepted": True,
                        "verified": True,
                        "rules_version": dl_training.RULES_SCHEMA_VERSION,
                        "action_version": dl_training.ACTION_SCHEMA_VERSION,
                        "encoder_version": dl_training.ENCODER_SCHEMA_VERSION,
                        "summary": {
                            "fire": {
                                "challenge_baseline_eval": {
                                    "games": 600,
                                    "wins": 180,
                                    "losses": 420,
                                    "draws": 0,
                                },
                                "eval": {
                                    "games": 600,
                                    "wins": 190,
                                    "losses": 410,
                                    "draws": 0,
                                    "invalid_action_rate": 0.0,
                                    "no_target_action_rate": 0.0,
                                    "rule_exception_rate": 0.0,
                                    "decision_timeout_rate": 0.0,
                                    "max_step_exhaustion_rate": 0.05,
                                },
                            }
                        },
                    }
                }, fh)
            self.assertTrue(dl_training._checkpoint_is_verified_for_league(model_path, "fire"))
            with open(os.path.splitext(model_path)[0] + ".json", "w", encoding="utf-8") as fh:
                json.dump({"metadata": {"deck": "fire", "accepted": False, "verified": False}}, fh)
            self.assertFalse(dl_training._checkpoint_is_verified_for_league(model_path, "fire"))

            no_opponents = dl_training.evaluate_alpha_zero_league(
                object(),
                "fire",
                17,
                dl_training.DeepTrainingConfig(
                    trainer="alpha_zero_rl",
                    deck="fire",
                    model=os.path.join(tmpdir, "missing.pt"),
                    games=1,
                    league_dir=tmpdir,
                    league_eval_games=1,
                ),
                device="cpu",
                max_steps=20,
            )
            self.assertFalse(no_opponents["accepted"])
            self.assertEqual(no_opponents["rejection_reason"], "no_verified_league_opponents")

        calls = []

        def fake_play(*_args, **kwargs):
            calls.append(kwargs)
            return (0, 1.0, [], [], {
                "actions": 1,
                "invalid_actions": 0,
                "no_target_actions": 0,
                "rule_exceptions": 0,
                "decision_timeouts": 0,
            })

        with mock.patch.object(
            dl_training,
            "_league_checkpoint_paths",
            return_value=[("a", "a.pt"), ("b", "b.pt"), ("c", "c.pt")],
        ), mock.patch.object(
            dl_training,
            "load_checkpoint",
            return_value=(object(), {"metadata": {"trainer": "test"}}),
        ), mock.patch.object(dl_training, "_play_model_game", side_effect=fake_play):
            capped = dl_training.evaluate_alpha_zero_league(
                object(),
                "fire",
                17,
                dl_training.DeepTrainingConfig(
                    trainer="alpha_zero_rl",
                    deck="fire",
                    games=1,
                    league_eval_games=2,
                ),
                device="cpu",
                max_steps=20,
            )
        self.assertEqual(capped["games"], 2)
        self.assertEqual(len(calls), 2)
        self.assertEqual([row["games"] for row in capped["opponents"]], [1, 1, 0])

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_alpha_zero_zero_game_run_writes_sidecar_metadata(self):
        from engine.ai.dl.training import DeepTrainingConfig, run_deep_training

        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "alpha.pt")
            payload = run_deep_training(
                DeepTrainingConfig(
                    trainer="alpha_zero_rl",
                    deck="fire",
                    games=0,
                    league_eval_games=0,
                    warm_start=False,
                    output=output,
                    device="cpu",
                    max_steps=20,
                )
            )

            rejected_output = os.path.splitext(output)[0] + ".rejected.pt"
            self.assertEqual(payload["model_path"], rejected_output)
            with open(os.path.splitext(rejected_output)[0] + ".json", "r", encoding="utf-8") as fh:
                sidecar = json.load(fh)
            metadata = sidecar["metadata"]
            self.assertEqual(metadata["trainer"], "alpha_zero_rl_v1")
            self.assertEqual(metadata["trainer_mode"], "alpha_zero_rl")
            self.assertEqual(metadata["bootstrap_games"], 0)
            self.assertEqual(metadata["dagger_games"], 0)
            self.assertEqual(metadata["acceptance_metric"], "league_elo")
            self.assertFalse(metadata["teacher_label_model_states"])
            self.assertEqual(metadata["warm_start_source"], "none")
            self.assertEqual(metadata["warm_start_path"], "")
            self.assertFalse(metadata["accepted"])
            self.assertEqual(metadata["verification_status"], "unverified_no_eval")

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_deep_training_writes_progress_events_and_sidecar(self):
        from engine.ai.dl.training import DeepTrainingConfig, run_deep_training

        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "model.pt")
            progress = os.path.join(tmpdir, "progress.jsonl")
            payload = run_deep_training(
                DeepTrainingConfig(
                    trainer="teacher_dagger_rl",
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

            rejected_output = os.path.splitext(output)[0] + ".rejected.pt"
            self.assertEqual(payload["model_path"], rejected_output)
            self.assertTrue(os.path.exists(rejected_output))
            sidecar_path = os.path.splitext(rejected_output)[0] + ".json"
            self.assertTrue(os.path.exists(sidecar_path))
            with open(sidecar_path, "r", encoding="utf-8") as fh:
                sidecar = json.load(fh)
            self.assertFalse(sidecar["metadata"]["accepted"])
            self.assertFalse(sidecar["metadata"]["training_gate_accepted"])
            self.assertFalse(sidecar["metadata"]["verified"])
            self.assertEqual(sidecar["metadata"]["verification_status"], "unverified_no_eval")
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
    def test_explicit_model_reval_does_not_self_gate_or_drop_choice_head(self):
        from engine.ai.dl import training as dl_training
        from engine.ai.dl.training import DeepTrainingConfig, run_deep_training

        class DummyModel:
            choice_head_enabled = True

            def to(self, _device):
                return self

        with temp_dir() as tmpdir:
            explicit_model = os.path.join(tmpdir, "source.pt")
            output = os.path.join(tmpdir, "reval.pt")
            with open(explicit_model, "wb") as fh:
                fh.write(b"checkpoint")
            with open(os.path.splitext(explicit_model)[0] + ".json", "w", encoding="utf-8") as fh:
                json.dump({
                    "metadata": {
                        "rules_version": RULES_SCHEMA_VERSION,
                        "action_version": ACTION_SCHEMA_VERSION,
                        "encoder_version": ENCODER_SCHEMA_VERSION,
                        "summary": {
                            "fire": {
                                "choice": {"choice_examples": 12},
                                "distill_choice": {"choice_examples": 0},
                            }
                        },
                    }
                }, fh)

            old_eval_paths = []

            def fake_old_eval(path, *_args, **_kwargs):
                old_eval_paths.append(path)
                self.assertNotEqual(
                    os.path.normcase(os.path.abspath(path)),
                    os.path.normcase(os.path.abspath(explicit_model)),
                )
                return None

            def fake_train_deck_pipeline(_model, _deck_key, _deck_seed, _config, _emit, total_done, _total_training_games, old_eval=None):
                self.assertIsNone(old_eval)
                return {
                    "accepted": True,
                    "eval": {"games": 1, "wins": 1, "losses": 0, "draws": 0},
                    "choice": {"choice_examples": 0, "choice_loss": 0.0},
                    "distill_choice": {"choice_examples": 0, "choice_loss": 0.0},
                    "choice_head_enabled": True,
                }, total_done

            def fake_save_checkpoint(path, _model, _metadata):
                with open(path, "wb") as fh:
                    fh.write(b"checkpoint")

            with mock.patch.object(dl_training, "_load_or_create_model", return_value=DummyModel()), \
                 mock.patch.object(dl_training, "_load_old_eval", side_effect=fake_old_eval), \
                 mock.patch.object(dl_training, "_train_deck_pipeline", side_effect=fake_train_deck_pipeline), \
                 mock.patch.object(dl_training, "save_checkpoint", side_effect=fake_save_checkpoint):
                payload = run_deep_training(
                    DeepTrainingConfig(
                        trainer="teacher_dagger_rl",
                        deck="fire",
                        model=explicit_model,
                        output=output,
                        games=0,
                        bootstrap_games=0,
                        dagger_games=0,
                        eval_games=1,
                        device="cpu",
                        max_steps=20,
                    )
                )

            self.assertEqual(payload["model_path"], output)
            self.assertEqual(old_eval_paths, [os.path.join("data", "ai_models", "fire.pt")])
            with open(os.path.splitext(output)[0] + ".json", "r", encoding="utf-8") as fh:
                metadata = json.load(fh)["metadata"]
            deck_summary = metadata["summary"]["fire"]
            self.assertTrue(metadata["choice_head_enabled"])
            self.assertEqual(deck_summary["loaded_choice_examples"], 12)

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

        baseline = {"wins": 50, "losses": 40, "draws": 10, "avg_score": -394720.374, "games": 100}
        candidate = {"wins": 50, "losses": 35, "draws": 15, "avg_score": -344311.383, "games": 100}
        self.assertFalse(
            _accepts_candidate(
                candidate,
                baseline,
                None,
                acceptance_metric="wins",
                min_win_delta=1,
            )
        )
        improved = dict(candidate, wins=51, losses=34)
        self.assertTrue(
            _accepts_candidate(
                improved,
                baseline,
                None,
                acceptance_metric="wins",
                min_win_delta=1,
            )
        )

    def test_candidate_gate_compares_rates_when_game_counts_differ(self):
        from engine.ai.dl.training import _accepts_candidate

        baseline = {
            "wins": 50,
            "losses": 50,
            "draws": 0,
            "avg_score": -100.0,
            "games": 100,
        }
        regressed = {
            "wins": 290,
            "losses": 310,
            "draws": 0,
            "avg_score": -80.0,
            "games": 600,
        }
        improved = dict(regressed, wins=310, losses=290)

        self.assertFalse(
            _accepts_candidate(
                regressed,
                baseline,
                None,
                acceptance_metric="points",
            )
        )
        self.assertTrue(
            _accepts_candidate(
                improved,
                baseline,
                None,
                acceptance_metric="points",
            )
        )

    def test_candidate_with_invalid_or_no_target_actions_is_rejected(self):
        from engine.ai.dl.training import _accepts_candidate

        baseline = {"wins": 1, "losses": 1, "draws": 0, "avg_score": 0.0, "games": 2}
        improved = {"wins": 2, "losses": 0, "draws": 0, "avg_score": 100.0, "games": 2}

        self.assertFalse(
            _accepts_candidate(dict(improved, invalid_action_rate=0.01), baseline, None, acceptance_metric="score")
        )
        self.assertFalse(
            _accepts_candidate(dict(improved, no_target_action_rate=0.01), baseline, None, acceptance_metric="score")
        )
        self.assertTrue(
            _accepts_candidate(
                dict(improved, invalid_action_rate=0.0, no_target_action_rate=0.0),
                baseline,
                None,
                acceptance_metric="score",
            )
        )

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_learning_probe_improves_heldout_tactical_preference(self):
        from scripts.verify_ai_learning import run_learning_probe

        result = run_learning_probe(device="cpu", epochs=6, repeats=6, learning_rate=5e-3)

        self.assertTrue(result.passed)
        self.assertGreaterEqual(result.after_target_probability, 0.85)
        self.assertGreater(result.probability_gain, 0.25)
        self.assertGreater(result.margin_gain, 1.0)

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

    def test_encoder_effect_features_understand_compiled_ir(self):
        from engine.commands.ir import CommandSpec

        encoder = ActionStateEncoder()
        card = Card(
            api_id="test-compiled-effects",
            name="Compiled Effects",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[
                {"effect_type": "energy_discard", "params": {"amount": 9}},
            ],
            compiled_trainer_effects=[
                CommandSpec(
                    op="draw_cards",
                    args={"amount": 1},
                    branches={
                        "on_success": (
                            CommandSpec(op="search_cards", args={"count": 1}),
                        ),
                    },
                ),
                {"op": "discard_cards", "args": {"from": "hand", "amount": 2}},
                {
                    "op": "flip_coin",
                    "effect_type": "coin_flip",
                    "args": {},
                    "params": {
                        "on_heads": [
                            {"effect_type": "energy_attach", "params": {"amount": 9}},
                        ],
                    },
                    "branches": {
                        "on_heads": [
                            {"op": "discard_cards", "args": {"from_zone": "hand", "amount": 1}},
                        ],
                    },
                },
            ],
        )

        tokens = encoder._effect_tokens_for_action_card(card)
        self.assertIn("draw", tokens)
        self.assertIn("search", tokens)
        self.assertIn("coin", tokens)
        self.assertNotIn("energy", tokens)
        self.assertEqual(encoder._discard_cost_amount(card), 3)

    def test_training_target_filter_uses_compiled_trainer_ir(self):
        from engine.ai.dl.training import _action_has_no_available_target

        state = self._simple_state()
        compiled_effects = [{
            "op": "draw_cards",
            "args": {"amount": 1},
            "branches": {},
        }]
        card = Card(
            api_id="test-training-compiled-effects",
            name="Training Compiled Effects",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[
                {"effect_type": "energy_discard", "params": {"amount": 9}},
            ],
            compiled_trainer_effects=compiled_effects,
        )
        state.p2.hand = [card]

        class RecordingAI:
            seen_effects = None

            def _effects_have_available_value(self, _state, _player_idx, effects):
                self.seen_effects = effects
                return True

        ai = RecordingAI()
        filtered = _action_has_no_available_target(
            ai,
            state,
            1,
            AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}),
        )

        self.assertFalse(filtered)
        self.assertEqual(ai.seen_effects, compiled_effects)
        self.assertNotIn("energy_discard", json.dumps(ai.seen_effects))

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

    def test_model_game_batch_loads_shared_policy_once(self):
        from engine.ai.dl import training as dl_training

        shared_state = {"weight": object()}
        tasks = [
            dl_training.ModelGameTask("fire", 1, 20, False, shared_state, {}, "fast"),
            dl_training.ModelGameTask("fire", 2, 20, False, shared_state, {}, "fast"),
        ]
        loads = []

        def fake_load(state, config):
            loads.append((state, config))
            return object()

        empty_row = (None, 0.0, [], [], {"actions": 0, "invalid_actions": 0, "no_target_actions": 0})
        with mock.patch.object(dl_training, "_model_from_worker_payload", side_effect=fake_load), \
             mock.patch.object(dl_training, "_play_model_game", return_value=empty_row):
            rows = dl_training._execute_model_game_task_batch(tasks)

        self.assertEqual(len(rows), 2)
        self.assertEqual(len(loads), 1)

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
        if not supports_file_delete():
            self.skipTest("Current sandbox does not allow deleting test files")

        import pygame
        from ui.screens.ai_training_screen import AITrainingScreen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

        with temp_dir() as tmpdir:
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

        with temp_dir() as tmpdir:
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
    def test_load_checkpoint_uses_weights_only_without_futurewarning(self):
        from engine.ai.dl.model import create_model, load_checkpoint, save_checkpoint, torch

        with temp_dir() as tmpdir:
            path = os.path.join(tmpdir, "model.pt")
            model = create_model(choice_head_enabled=True)
            save_checkpoint(path, model, {"trainer": "test", "torch_version": torch.__version__})

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always", FutureWarning)
                restored, payload = load_checkpoint(path, "cpu")

        self.assertTrue(getattr(restored, "choice_head_enabled", False))
        self.assertEqual(payload.get("metadata", {}).get("trainer"), "test")
        self.assertFalse(
            any("weights_only=False" in str(item.message) for item in caught)
        )

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_dl_ai_loads_checkpoint_with_schema_metadata_split(self):
        from engine.ai.dl.model import create_model, save_checkpoint, torch

        with temp_dir() as tmpdir:
            path = os.path.join(tmpdir, "model.pt")
            model = create_model(choice_head_enabled=True)
            save_checkpoint(
                path,
                model,
                {
                    "planner_version": 1,
                    "seed": 17,
                    "trainer": "test",
                    "torch_version": torch.__version__,
                },
            )
            ai = DeepLearningAI(
                "fire",
                DeepLearningAIConfig(
                    model_path=path,
                    device="cpu",
                    use_mcts=False,
                    fallback_config=AIConfig(
                        thinking_time_seconds=0.01,
                        deterministic_search=False,
                        max_sequence_depth=0,
                        max_turn_actions=8,
                        search_algorithm="beam",
                    ),
                ),
            )

        self.assertTrue(ai.model_available)
        self.assertEqual(ai.model_metadata.get("planner_version"), 1)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_dl_ai_rejects_legacy_encoder_checkpoint(self):
        from engine.ai.dl.model import create_model, save_checkpoint, safe_torch_load, torch

        with temp_dir() as tmpdir:
            path = os.path.join(tmpdir, "legacy_v9_encoder_v2.pt")
            model = create_model(choice_head_enabled=True)
            save_checkpoint(
                path,
                model,
                {
                    "planner_version": 1,
                    "seed": 17,
                    "trainer": "legacy-test",
                    "torch_version": torch.__version__,
                },
            )
            payload = safe_torch_load(path, map_location="cpu")
            payload["version"] = 9
            payload["schema"]["encoder_version"] = 2
            payload["metadata"]["encoder_version"] = 2
            torch.save(payload, path)

            ai = DeepLearningAI(
                "fire",
                DeepLearningAIConfig(
                    model_path=path,
                    device="cpu",
                    use_mcts=False,
                    fallback_config=AIConfig(
                        thinking_time_seconds=0.01,
                        deterministic_search=False,
                        max_sequence_depth=0,
                        max_turn_actions=8,
                        search_algorithm="beam",
                    ),
                ),
            )

        self.assertFalse(ai.model_available)
        self.assertEqual(ai.model_metadata.get("encoder_version"), 2)

    @unittest.skipIf(importlib.util.find_spec("torch") is None, "PyTorch is not installed")
    def test_v10_checkpoint_saves_and_legacy_v5_restores_choice_head(self):
        from engine.ai.dl.model import checkpoint_payload, create_model, load_checkpoint, save_checkpoint, torch

        with temp_dir() as tmpdir:
            path = os.path.join(tmpdir, "model_v10.pt")
            model = create_model(choice_head_enabled=True)
            save_checkpoint(path, model, {"trainer": "test"})
            restored, payload = load_checkpoint(path, "cpu")

            legacy_path = os.path.join(tmpdir, "model_v5.pt")
            legacy_model = create_model(
                choice_head_enabled=True,
                state_norm="batch",
                use_slot_embeddings=False,
            )
            legacy_payload = checkpoint_payload(legacy_model, {"trainer": "legacy"})
            legacy_payload["version"] = 5
            legacy_payload.get("model_config", {}).pop("state_norm", None)
            legacy_payload.get("model_config", {}).pop("use_slot_embeddings", None)
            torch.save(legacy_payload, legacy_path)
            legacy_restored, legacy_loaded = load_checkpoint(legacy_path, "cpu")

        self.assertEqual(payload.get("version"), 10)
        self.assertTrue(payload.get("model_config", {}).get("choice_head_enabled"))
        self.assertEqual(payload.get("model_config", {}).get("state_norm"), "layer")
        self.assertEqual(payload.get("model_config", {}).get("state_numeric_size"), STATE_NUMERIC_SIZE)
        self.assertEqual(payload.get("model_config", {}).get("action_numeric_size"), ACTION_NUMERIC_SIZE)
        self.assertTrue(getattr(restored, "choice_head_enabled", False))
        self.assertTrue(hasattr(restored, "choice_net"))
        self.assertTrue(hasattr(restored, "score_choices"))
        self.assertFalse(hasattr(restored, "choice_value_head"))
        self.assertTrue(getattr(restored, "use_attention", False))
        self.assertTrue(getattr(restored, "use_slot_embeddings", False))
        self.assertEqual(getattr(restored, "state_norm", ""), "layer")
        self.assertEqual(legacy_loaded.get("version"), 5)
        self.assertTrue(getattr(legacy_restored, "choice_head_enabled", False))
        self.assertFalse(getattr(legacy_restored, "use_slot_embeddings", True))
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
        from ui.screens import deck_select
        from ui.screens.deck_select import DeckSelectScreen

        pygame.init()
        pygame.font.init()

        class Manager:
            _app = None

            def replace_top(self, screen):
                self.screen = screen

        with mock.patch.object(deck_select, "is_deep_model_accepted", return_value=False):
            screen = DeckSelectScreen(
                Manager(),
                {"fire": FIRE_DECK, "water": WATER_DECK},
                mode="challenge",
            )
            self.assertEqual(screen.ai_kind, "challenge")
            self.assertEqual(screen.ai_search_algorithm, "hybrid")
            status, _status_color = screen._ai_model_status()
            self.assertIn("专家混合搜索", status)
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

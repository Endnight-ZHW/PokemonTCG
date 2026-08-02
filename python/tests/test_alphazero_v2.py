from __future__ import annotations

import json
import tempfile
import threading
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from engine.actions import (
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
)
from engine.ai.challenge_ai import AIConfig
from engine.ai.dl.alphazero_v2 import (
    BOOTSTRAP_GENERATOR_VERSION,
    BOOTSTRAP_LEGACY_V5_GENERATOR_SHA256,
    BOOTSTRAP_LEGACY_V5_MONOLITHIC_SOURCE_SHA256,
    BOOTSTRAP_LEGACY_V5_PRIMITIVES_ENERGY_SHA256,
    BOOTSTRAP_PROTOCOL_BOUND_FIX_PRIMITIVES_ENERGY_SHA256,
    EVALUATION_EXTENDED_DECISION_CAP_MULTIPLIERS,
    SELF_PLAY_EXTENDED_DECISION_CAP_MULTIPLIERS,
    SELF_PLAY_TRUNCATION_RESEED_ATTEMPTS,
    TEACHER_CONFIG,
    AlphaZeroV2Config,
    AlphaZeroV2Trainer,
    GameResult,
    GameTask,
    _SeatEvaluator,
    _challenge_authoritative_action,
    _bootstrap_fingerprint_matches,
    _choice_candidate_for_response,
    _play_arena_with_extended_decision_caps,
    _play_league_with_extended_decision_caps,
    _prefetched_training_batches,
    _play_self_play_with_retries,
    _self_play_task_for_attempt,
    _split_teacher_results,
    _teacher_game,
    _teacher_task_for_attempt,
    _teacher_task_matches,
    final_league_tasks,
    generation_tasks,
    learning_rate_multiplier,
    load_bootstrap_splits,
    partition_game_tasks,
    play_self_play_game,
    play_model_vs_challenge_game,
    save_bootstrap_cache,
)
from engine.ai.dl.inference_v2 import (
    BatchedTorchEvaluator,
    PolicyValue,
    UniformEvaluator,
)
from engine.ai.dl.infoset_encoder import InformationSetEncoderV7
from engine.ai.dl.integrity_v2 import (
    is_recoverable_arena_truncation_event,
    is_retriable_self_play_truncation_event,
)
from engine.ai.dl.model_v2 import (
    CHECKPOINT_VERSION,
    create_model,
    load_checkpoint,
    save_checkpoint,
    torch,
)
from engine.ai.dl.native_bridge_v2 import (
    NativeBridgeError,
    native_training_bridge_available,
)
from engine.ai.dl.puct_v2 import (
    InformationSetPUCT,
    SearchCandidate,
    _choice_responses,
    information_set_key,
)
from engine.ai.dl.replay_v2 import AlphaZeroSample, ReplayStoreV2
from engine.ai.dl.v2_contract import (
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    MODEL_VARIANT,
    contract_dict,
    visit_temperature,
)
from engine.ai.observation import Observation


def _observation(actor: int = 0, marker: int = 0) -> Observation:
    return Observation(
        perspective=actor,
        turn_number=marker + 1,
        phase="MAIN",
        active_player=actor,
        winner=None,
        own_hand=("sv1-104",),
        own_discard=(),
        own_deck_count=52,
        own_prize_count=6,
        opponent_hand_count=7,
        opponent_discard=(),
        opponent_deck_count=47,
        opponent_prize_count=6,
        board=(),
        stadium_id="",
        public_deck_keys=("fire", "water"),
        apply_type_matchups=False,
    )


class _FakeState:
    def __init__(self, depth: int = 0, actor: int = 0, winner=None):
        self.depth = depth
        self.actor = actor
        self.winner = winner


class _FakeEnvironment:
    def clone_root(self, state, actor, seed):
        del actor, seed
        return _FakeState(state.depth, state.actor, state.winner)

    redeterminize = clone_root

    def actor(self, state):
        return state.actor

    def observation(self, state, actor):
        return _observation(actor, state.depth)

    def candidates(self, state, actor):
        del actor
        if state.depth >= 2:
            return []
        return [
            SearchCandidate("a", GameAction("A")),
            SearchCandidate("b", GameAction("B")),
        ]

    def apply(self, state, candidate, seed):
        del seed
        state.depth += 1
        state.actor = 1 - state.actor
        if state.depth == 2:
            state.winner = 0 if candidate.signature == "a" else 1

    def is_terminal(self, state):
        return state.winner is not None

    def terminal_value(self, state, actor):
        return 1.0 if state.winner == actor else -1.0

    def deck_key(self, state, actor):
        del state
        return ("fire", "water")[actor]


class _BiasedEvaluator:
    def evaluate(self, observation, candidates, actor_deck_key):
        del observation, actor_deck_key
        result = PolicyValue(
            np.asarray((0.9, 0.1), dtype=np.float32),
            np.asarray((0.5, 0.0, 0.5), dtype=np.float32),
        )
        result.validate(len(candidates))
        return result


@unittest.skipIf(torch is None, "PyTorch is not installed")
class AlphaZeroV2Tests(unittest.TestCase):
    def test_contract_versions_and_temperature_are_frozen(self):
        self.assertEqual(ENCODER_SCHEMA_VERSION, 7)
        self.assertEqual(CHECKPOINT_VERSION, 12)
        self.assertEqual(DEEP_PLANNER_VERSION, 2)
        self.assertEqual(contract_dict()["model_variant"], MODEL_VARIANT)
        self.assertEqual(visit_temperature(6), 1.0)
        self.assertEqual(visit_temperature(7), 0.5)
        self.assertEqual(visit_temperature(13), 0.1)

    def test_encoder_is_contiguous_and_privacy_scoped(self):
        encoder = InformationSetEncoderV7()
        encoded = encoder.encode_information_set(_observation())
        encoded.validate()
        self.assertEqual(encoded.state_global.shape, (128,))
        self.assertEqual(encoded.entity_numeric.shape, (128, 16))
        self.assertTrue(encoded.state_global.flags.c_contiguous)
        self.assertEqual(
            information_set_key(_observation(), 0),
            information_set_key(_observation(), 0),
        )
        with self.assertRaises(TypeError):
            information_set_key(object(), 0)

    def test_universal_model_shapes_mask_and_checkpoint(self):
        model = create_model()
        batch, candidates = 2, 4
        inputs = (
            torch.zeros(batch, 128),
            torch.zeros(batch, 128, 16),
            torch.zeros(batch, 128, dtype=torch.long),
            torch.zeros(batch, 128, 4, dtype=torch.long),
            torch.zeros(batch, candidates, 32),
            torch.zeros(batch, candidates, dtype=torch.long),
            torch.ones(batch, candidates, dtype=torch.long),
            torch.zeros(batch, candidates, 4, dtype=torch.long),
            torch.tensor(
                [[True, True, False, False], [True, True, True, False]]
            ),
            torch.zeros(batch, dtype=torch.long),
            torch.ones(batch, dtype=torch.long),
        )
        policy, wdl = model(*inputs)
        self.assertEqual(tuple(policy.shape), (batch, candidates))
        self.assertEqual(tuple(wdl.shape), (batch, 3))
        self.assertLess(policy[0, 2].item(), -1e20)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "universal.pt"
            save_checkpoint(str(path), model, {"generation": 0})
            loaded, payload = load_checkpoint(str(path))
            self.assertEqual(payload["version"], 12)
            self.assertEqual(loaded.variant, MODEL_VARIANT)

    def test_puct_expands_neural_leaves_and_backs_up_visits(self):
        search = InformationSetPUCT(
            _BiasedEvaluator(),
            _FakeEnvironment(),
            simulations=24,
            training=False,
            seed=7,
        )
        result = search.search(_FakeState(), 0, temperature=0.0)
        self.assertEqual(result.simulations, 24)
        self.assertEqual(sum(result.visits.values()), 23)
        self.assertEqual(result.selected.signature, "a")
        self.assertEqual(result.probabilities["a"], 1.0)

    def test_generation_schedule_has_55_matchups_and_closure(self):
        tasks = generation_tasks(1, 20, 4, 17)
        self.assertEqual(len(tasks), 1_100)
        self.assertEqual(sum(task.opponent_version < 0 for task in tasks), 220)
        first = tasks[:20]
        self.assertEqual({task.seat_a for task in first}, {0, 1})
        self.assertEqual({task.first_player for task in first}, {0, 1})
        self.assertEqual(
            [task.opponent_version for task in first[-4:]],
            [-1, -1, -1, -1],
        )
        self.assertEqual(
            {
                task.opponent_version
                for task in tasks[20:40][-4:]
            },
            {-2},
        )
        self.assertEqual(
            {
                task.opponent_version
                for task in tasks[40:60][-4:]
            },
            {-3},
        )
        for start in range(0, len(first), 4):
            self.assertEqual(
                len({task.seed for task in first[start:start + 4]}),
                1,
            )

    def test_self_play_partitions_are_disjoint_and_complete(self):
        tasks = generation_tasks(1, 20, 4, 17)
        partitions = [partition_game_tasks(tasks, index, 2) for index in range(2)]
        self.assertEqual([len(rows) for rows in partitions], [550, 550])
        left = {task.game_id for task in partitions[0]}
        right = {task.game_id for task in partitions[1]}
        self.assertFalse(left & right)
        self.assertEqual(left | right, {task.game_id for task in tasks})
        self.assertEqual(partitions[0][:3], tuple(tasks[0:6:2]))
        with self.assertRaisesRegex(ValueError, "invalid_self_play_partition"):
            partition_game_tasks(tasks, 2, 2)

    def test_truncated_games_are_integrity_errors(self):
        result = GameResult(
            task=generation_tasks(1, 1, 0, 17)[0],
            winner=None,
            samples=(),
            decisions=512,
            simulations=0,
            truncated=True,
        )
        self.assertEqual(result.structural_errors, 0)
        self.assertEqual(result.integrity_errors, 1)

    def test_task_integrity_failure_is_persisted_immediately(self):
        task = generation_tasks(1, 1, 0, 17)[0]
        failed = GameResult(
            task=task,
            winner=None,
            samples=(),
            decisions=7,
            simulations=896,
            rule_exceptions=1,
            truncated=True,
            error_details=("authoritative_apply_failed:test",),
        )
        with tempfile.TemporaryDirectory() as directory:
            trainer = AlphaZeroV2Trainer(
                AlphaZeroV2Config.smoke(
                    directory,
                    str(Path(directory) / "bootstrap.pt"),
                )
            )
            with patch(
                "engine.ai.dl.alphazero_v2.play_self_play_game",
                return_value=failed,
            ):
                results = trainer._run_tasks(
                    [task],
                    object(),
                    training=False,
                )
            events = [
                json.loads(line)
                for line in trainer.events_path.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
        self.assertEqual(results, [failed])
        failure = next(
            event
            for event in events
            if event["event"] == "task_integrity_failure"
        )
        self.assertEqual(failure["task"]["game_id"], task.game_id)
        self.assertEqual(failure["rule_exceptions"], 1)
        self.assertTrue(failure["truncated"])
        self.assertEqual(
            failure["error_details"],
            ["authoritative_apply_failed:test"],
        )

    def test_arena_terminal_result_keeps_base_decision_cap(self):
        task = generation_tasks(1, 1, 0, 17)[0]
        completed = GameResult(
            task=task,
            winner=0,
            samples=(),
            decisions=25,
            simulations=89_600,
        )
        with tempfile.TemporaryDirectory() as directory:
            trainer = AlphaZeroV2Trainer(
                AlphaZeroV2Config.smoke(
                    directory,
                    str(Path(directory) / "bootstrap.pt"),
                )
            )
            base_max_decisions = trainer.config.max_game_decisions
            with patch(
                "engine.ai.dl.alphazero_v2.play_self_play_game",
                return_value=completed,
            ) as run:
                results = trainer._run_tasks(
                    [task],
                    object(),
                    training=False,
                )
            events = [
                json.loads(line)
                for line in trainer.events_path.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]

        self.assertEqual(len(results), 1)
        self.assertFalse(results[0].truncated)
        self.assertEqual(results[0].truncation_retries, 0)
        self.assertEqual(
            [call.kwargs["max_decisions"] for call in run.call_args_list],
            [base_max_decisions],
        )
        self.assertFalse(any(
            event["event"] == "task_integrity_failure"
            for event in events
        ))
        self.assertFalse(any(
            event["event"] == "arena_task_truncated"
            for event in events
        ))

    def test_arena_clean_decision_cap_is_adjudicated_as_draw(self):
        task = generation_tasks(1, 1, 0, 17)[0]
        caps: list[int] = []

        def always_truncated(effective_task, _evaluator, **kwargs):
            caps.append(int(kwargs["max_decisions"]))
            return GameResult(
                task=effective_task,
                winner=None,
                samples=(),
                decisions=int(kwargs["max_decisions"]),
                simulations=0,
                truncated=True,
            )

        with tempfile.TemporaryDirectory() as directory:
            trainer = AlphaZeroV2Trainer(
                AlphaZeroV2Config.smoke(
                    directory,
                    str(Path(directory) / "bootstrap.pt"),
                )
            )
            base_max_decisions = trainer.config.max_game_decisions
            with patch(
                "engine.ai.dl.alphazero_v2.play_self_play_game",
                side_effect=always_truncated,
            ):
                results = trainer._run_tasks(
                    [task],
                    object(),
                    training=False,
                )
            events = [
                json.loads(line)
                for line in trainer.events_path.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]

        self.assertEqual(
            caps,
            [base_max_decisions],
        )
        self.assertFalse(results[0].truncated)
        self.assertIsNone(results[0].winner)
        self.assertEqual(results[0].truncation_retries, 0)
        self.assertIn(
            "evaluation_decision_cap_draw:",
            results[0].error_details[-1],
        )
        self.assertFalse(any(
            event["event"] in {
                "task_integrity_failure",
                "arena_task_truncated",
            }
            for event in events
        ))

    def test_final_league_uses_same_decision_cap_draw_policy(self):
        task = final_league_tasks(5, 1, 17)[0]
        caps: list[int] = []

        def reach_decision_cap(effective_task, _evaluator, **kwargs):
            caps.append(int(kwargs["max_decisions"]))
            return GameResult(
                task=effective_task,
                winner=None,
                samples=(),
                decisions=512,
                simulations=0,
                truncated=True,
            )

        with patch(
            "engine.ai.dl.alphazero_v2.play_model_vs_challenge_game",
            side_effect=reach_decision_cap,
        ):
            result = _play_league_with_extended_decision_caps(
                task,
                object(),
                simulations=128,
                c_puct=1.4,
                max_decisions=512,
            )

        self.assertEqual(caps, [512])
        self.assertFalse(result.truncated)
        self.assertIsNone(result.winner)
        self.assertEqual(result.truncation_retries, 0)
        self.assertEqual(
            result.error_details,
            ("evaluation_decision_cap_draw:512",),
        )

    def test_evaluation_truncation_cap_policy_is_explicit(self):
        self.assertEqual(
            EVALUATION_EXTENDED_DECISION_CAP_MULTIPLIERS,
            (),
        )

    def test_arena_truncation_policy_fails_closed(self):
        event = {
            "event": "task_integrity_failure",
            "phase": "arena",
            "truncated": True,
            "invalid_actions": 0,
            "illegal_choices": 0,
            "rule_exceptions": 0,
            "decision_timeouts": 0,
            "hidden_information_violations": 0,
            "error_details": [],
        }
        self.assertTrue(is_recoverable_arena_truncation_event(event))
        for field in (
            "invalid_actions",
            "illegal_choices",
            "rule_exceptions",
            "decision_timeouts",
            "hidden_information_violations",
        ):
            with self.subTest(field=field):
                changed = dict(event)
                changed[field] = 1
                self.assertFalse(
                    is_recoverable_arena_truncation_event(changed)
                )
        missing = dict(event)
        missing.pop("rule_exceptions")
        self.assertFalse(is_recoverable_arena_truncation_event(missing))
        diagnosed = dict(event, error_details=["unexpected"])
        self.assertFalse(is_recoverable_arena_truncation_event(diagnosed))

    def test_self_play_retry_recovery_policy_fails_closed(self):
        event = {
            "event": "task_integrity_failure",
            "phase": "self_play",
            "truncated": True,
            "invalid_actions": 0,
            "illegal_choices": 0,
            "rule_exceptions": 0,
            "decision_timeouts": 0,
            "hidden_information_violations": 0,
            "error_details": [
                "self_play_truncation_reseed_attempts_exhausted:9"
            ],
            "truncation_retries": 8,
            "decisions": 512,
            "simulations": 65_536,
        }
        self.assertTrue(is_retriable_self_play_truncation_event(
            event,
            exhausted_attempts=9,
        ))
        for field in (
            "invalid_actions",
            "illegal_choices",
            "rule_exceptions",
            "decision_timeouts",
            "hidden_information_violations",
        ):
            changed = dict(event, **{field: 1})
            self.assertFalse(is_retriable_self_play_truncation_event(
                changed,
                exhausted_attempts=9,
            ))
        diagnosed = dict(event, error_details=["different"])
        self.assertFalse(is_retriable_self_play_truncation_event(
            diagnosed,
            exhausted_attempts=9,
        ))

    def test_self_play_game_shards_resume_completed_games(self):
        tasks = generation_tasks(1, 2, 0, 17)[:2]
        calls: list[str] = []

        def completed(task, _evaluator, **_kwargs):
            calls.append(task.game_id)
            return GameResult(
                task=task,
                winner=0,
                samples=(),
                decisions=3,
                simulations=6,
            )

        with tempfile.TemporaryDirectory() as directory:
            trainer = AlphaZeroV2Trainer(
                AlphaZeroV2Config.smoke(
                    directory,
                    str(Path(directory) / "bootstrap.pt"),
                    concurrent_games=2,
                )
            )
            shard_dir = Path(directory) / "self_play" / "generation-001"
            with patch(
                "engine.ai.dl.alphazero_v2._play_self_play_with_retries",
                side_effect=completed,
            ):
                first = trainer._run_tasks(
                    tasks,
                    object(),
                    training=True,
                    shard_dir=shard_dir,
                    shard_fingerprint="fixed-model-fingerprint",
                )
            self.assertEqual(len(first), 2)
            self.assertEqual(len(list(shard_dir.glob("*.pt"))), 2)
            with patch(
                "engine.ai.dl.alphazero_v2._play_self_play_with_retries",
                side_effect=AssertionError("completed game reran"),
            ):
                resumed = trainer._run_tasks(
                    tasks,
                    object(),
                    training=True,
                    shard_dir=shard_dir,
                    shard_fingerprint="fixed-model-fingerprint",
                )
        self.assertEqual(sorted(calls), sorted(task.game_id for task in tasks))
        self.assertEqual(
            [result.task.game_id for result in resumed],
            [task.game_id for task in tasks],
        )

    def test_task_failure_stops_the_rolling_submission_window(self):
        tasks = generation_tasks(1, 4, 0, 17)[:4]
        second_started = threading.Event()
        calls: list[str] = []

        def play(task, _evaluator, **_kwargs):
            calls.append(task.game_id)
            if task.game_id == tasks[0].game_id:
                second_started.wait(timeout=1.0)
                raise RuntimeError("synthetic-game-failure")
            second_started.set()
            threading.Event().wait(0.05)
            return GameResult(
                task=task,
                winner=None,
                samples=(),
                decisions=1,
                simulations=2,
            )

        with tempfile.TemporaryDirectory() as directory:
            trainer = AlphaZeroV2Trainer(
                AlphaZeroV2Config.smoke(
                    directory,
                    str(Path(directory) / "bootstrap.pt"),
                    concurrent_games=2,
                )
            )
            with patch(
                "engine.ai.dl.alphazero_v2._play_self_play_with_retries",
                side_effect=play,
            ), self.assertRaisesRegex(
                RuntimeError,
                "synthetic-game-failure",
            ):
                trainer._run_tasks(
                    tasks,
                    object(),
                    training=True,
                    shard_dir=Path(directory) / "shards",
                    shard_fingerprint="fixed-model-fingerprint",
                )
        self.assertEqual(
            sorted(calls),
            sorted(task.game_id for task in tasks[:2]),
        )

    def test_self_play_truncation_reseed_is_deterministic_and_closed(self):
        task = generation_tasks(1, 20, 4, 17)[0]
        retry = _self_play_task_for_attempt(task, 1)
        self.assertNotEqual(retry.seed, task.seed)
        self.assertEqual(retry, _self_play_task_for_attempt(task, 1))
        self.assertEqual(retry.game_id, task.game_id)
        self.assertEqual(retry.deck_a, task.deck_a)
        self.assertEqual(retry.deck_b, task.deck_b)
        self.assertEqual(retry.seat_a, task.seat_a)
        self.assertEqual(retry.first_player, task.first_player)
        self.assertEqual(retry.opponent_version, task.opponent_version)

    def test_self_play_truncation_discards_attempt_and_reseeds(self):
        task = generation_tasks(1, 20, 4, 17)[0]
        retry = _self_play_task_for_attempt(task, 1)
        with patch(
            "engine.ai.dl.alphazero_v2.play_self_play_game",
            side_effect=(
                GameResult(
                    task,
                    None,
                    (),
                    512,
                    65_536,
                    truncated=True,
                ),
                GameResult(retry, 0, (), 80, 10_240),
            ),
        ) as run:
            result = _play_self_play_with_retries(
                task,
                object(),
                simulations=128,
                c_puct=1.4,
                max_decisions=512,
                training=True,
            )
        self.assertEqual(result.task, retry)
        self.assertFalse(result.truncated)
        self.assertEqual(result.truncation_retries, 1)
        self.assertEqual(
            [call.args[0] for call in run.call_args_list],
            [task, retry],
        )

    def test_self_play_truncation_retry_limit_is_explicit(self):
        self.assertEqual(SELF_PLAY_TRUNCATION_RESEED_ATTEMPTS, 8)
        self.assertEqual(SELF_PLAY_EXTENDED_DECISION_CAP_MULTIPLIERS, (2, 4))

    def test_self_play_truncation_extends_only_final_retry_caps(self):
        task = generation_tasks(1, 20, 4, 17)[0]
        caps: list[int] = []

        def truncate_then_finish(effective_task, _evaluator, **kwargs):
            caps.append(int(kwargs["max_decisions"]))
            if len(caps) <= SELF_PLAY_TRUNCATION_RESEED_ATTEMPTS + 1:
                return GameResult(
                    effective_task,
                    None,
                    (),
                    int(kwargs["max_decisions"]),
                    0,
                    truncated=True,
                )
            return GameResult(effective_task, 0, (), 700, 0)

        with patch(
            "engine.ai.dl.alphazero_v2.play_self_play_game",
            side_effect=truncate_then_finish,
        ):
            result = _play_self_play_with_retries(
                task,
                object(),
                simulations=128,
                c_puct=1.4,
                max_decisions=512,
                training=True,
            )

        self.assertFalse(result.truncated)
        self.assertEqual(result.truncation_retries, 9)
        self.assertEqual(caps, [512] * 9 + [1024])

    def test_bootstrap_split_keeps_complete_seed_groups_isolated(self):
        tasks = generation_tasks(0, 20, 0, 17)
        results = [
            GameResult(
                task=task,
                winner=None,
                samples=(),
                decisions=0,
                simulations=0,
            )
            for task in tasks
        ]
        train, validation, manifest = _split_teacher_results(results)
        self.assertEqual(train, [])
        self.assertEqual(validation, [])
        self.assertEqual(manifest["schema"], "game_seed_90_10_v1")
        self.assertEqual(len(manifest["train_games"]), 988)
        self.assertEqual(len(manifest["validation_games"]), 112)
        self.assertFalse(
            set(manifest["train_seeds"])
            & set(manifest["validation_seeds"])
        )
        self.assertEqual(len(manifest["game_seeds"]), 1_100)
        seed_by_game = {task.game_id: task.seed for task in tasks}
        self.assertEqual(
            {
                seed_by_game[game_id]
                for game_id in manifest["train_games"]
            },
            set(manifest["train_seeds"]),
        )
        self.assertEqual(
            {
                seed_by_game[game_id]
                for game_id in manifest["validation_games"]
            },
            set(manifest["validation_seeds"]),
        )

    def test_frozen_v5_cache_ignores_only_monolithic_training_changes(self):
        source_key = "python/engine/ai/dl/alphazero_v2.py"
        expected = {
            "format": "alphazero_v2_bootstrap",
            "generator": BOOTSTRAP_GENERATOR_VERSION,
            "generator_sha256": "new-training-only-hash",
            "teacher_config": {"search_node_budget": 180},
            "inputs": {
                source_key: "new-training-only-source-hash",
                "godot/data/cards.json": "cards-hash",
            },
        }
        observed = {
            **expected,
            "generator_sha256": BOOTSTRAP_LEGACY_V5_GENERATOR_SHA256,
            "inputs": {
                source_key:
                    BOOTSTRAP_LEGACY_V5_MONOLITHIC_SOURCE_SHA256,
                "godot/data/cards.json": "cards-hash",
            },
        }
        self.assertTrue(
            _bootstrap_fingerprint_matches(observed, expected)
        )
        changed_rules = {
            **expected,
            "inputs": {
                **expected["inputs"],
                "godot/data/cards.json": "changed-cards-hash",
            },
        }
        self.assertFalse(
            _bootstrap_fingerprint_matches(observed, changed_rules)
        )

    def test_frozen_v5_cache_accepts_only_pinned_protocol_migration(self):
        source_key = "python/engine/ai/dl/alphazero_v2.py"
        energy_key = "python/engine/commands/primitives_energy.py"
        expected = {
            "format": "alphazero_v2_bootstrap",
            "generator": BOOTSTRAP_GENERATOR_VERSION,
            "generator_sha256": "new-generator-hash",
            "teacher_config": {"search_node_budget": 180},
            "inputs": {
                source_key: "new-source-hash",
                energy_key:
                    BOOTSTRAP_PROTOCOL_BOUND_FIX_PRIMITIVES_ENERGY_SHA256,
                "godot/data/cards.json": "cards-hash",
            },
        }
        observed = {
            **expected,
            "generator_sha256": BOOTSTRAP_LEGACY_V5_GENERATOR_SHA256,
            "inputs": {
                source_key:
                    BOOTSTRAP_LEGACY_V5_MONOLITHIC_SOURCE_SHA256,
                energy_key:
                    BOOTSTRAP_LEGACY_V5_PRIMITIVES_ENERGY_SHA256,
                "godot/data/cards.json": "cards-hash",
            },
        }
        self.assertTrue(
            _bootstrap_fingerprint_matches(observed, expected)
        )

        future_energy_edit = {
            **expected,
            "inputs": {
                **expected["inputs"],
                energy_key: "future-energy-hash",
            },
        }
        self.assertFalse(
            _bootstrap_fingerprint_matches(observed, future_energy_edit)
        )

        unknown_old_energy = {
            **observed,
            "inputs": {
                **observed["inputs"],
                energy_key: "unknown-old-energy-hash",
            },
        }
        self.assertFalse(
            _bootstrap_fingerprint_matches(unknown_old_energy, expected)
        )

        changed_other_rule = {
            **expected,
            "inputs": {
                **expected["inputs"],
                "godot/data/cards.json": "changed-cards-hash",
            },
        }
        self.assertFalse(
            _bootstrap_fingerprint_matches(observed, changed_other_rule)
        )

    def test_teacher_truncation_reseed_is_deterministic_and_closed(self):
        task = generation_tasks(0, 20, 0, 17)[0]
        retry = _teacher_task_for_attempt(task, 1)
        self.assertNotEqual(retry.seed, task.seed)
        self.assertEqual(
            retry,
            _teacher_task_for_attempt(task, 1),
        )
        self.assertEqual(retry.game_id, task.game_id)
        self.assertEqual(retry.deck_a, task.deck_a)
        self.assertEqual(retry.deck_b, task.deck_b)
        self.assertEqual(retry.seat_a, task.seat_a)
        self.assertEqual(retry.first_player, task.first_player)
        self.assertTrue(_teacher_task_matches(retry, task))
        self.assertFalse(
            _teacher_task_matches(
                replace(retry, deck_b="psychic"),
                task,
            )
        )

    def test_teacher_config_contains_only_ai_config_fields(self):
        self.assertLessEqual(
            set(TEACHER_CONFIG),
            set(AIConfig.__dataclass_fields__),
        )

    def test_teacher_truncation_retries_with_derived_seed(self):
        task = generation_tasks(0, 20, 0, 17)[0]
        retry = _teacher_task_for_attempt(task, 1)
        with patch(
            "engine.ai.dl.alphazero_v2._teacher_game_once",
            side_effect=(
                GameResult(
                    task,
                    None,
                    (),
                    10,
                    0,
                    truncated=True,
                ),
                GameResult(retry, 0, (), 8, 0),
            ),
        ) as run:
            result = _teacher_game(task, 10)
        self.assertEqual(result.task, retry)
        self.assertFalse(result.truncated)
        self.assertEqual(
            [call.args for call in run.call_args_list],
            [(task, 10), (retry, 10)],
        )

    def test_teacher_choice_mapping_canonicalizes_unordered_multiselect(self):
        request = ChoiceRequest(
            "request",
            "search_deck",
            0,
            "choose",
            (
                ChoiceOption("card:a", "a"),
                ChoiceOption("card:b", "b"),
            ),
            2,
            2,
        )
        candidate = _choice_candidate_for_response(
            _choice_responses(request),
            ChoiceResponse(
                request.request_id,
                ("card:b", "card:a"),
            ),
        )
        self.assertIsNotNone(candidate)
        self.assertEqual(
            candidate.payload.option_ids,
            ("card:a", "card:b"),
        )

    def test_teacher_choice_mapping_retains_preferred_candidate_past_cap(self):
        request = ChoiceRequest(
            "large-request",
            "search_deck",
            0,
            "choose",
            tuple(
                ChoiceOption(f"card:{index:02d}", str(index))
                for index in range(17)
            ),
            3,
            3,
        )
        preferred = ChoiceResponse(
            request.request_id,
            ("card:16", "card:15", "card:14"),
        )
        candidates = _choice_responses(
            request,
            preferred_response=preferred,
        )
        candidate = _choice_candidate_for_response(
            candidates,
            preferred,
        )
        self.assertEqual(len(candidates), 256)
        self.assertIsNotNone(candidate)
        self.assertEqual(
            candidate.payload.option_ids,
            ("card:14", "card:15", "card:16"),
        )

    def test_challenge_forced_promotion_uses_authoritative_candidates(self):
        state = SimpleNamespace(
            get_player=lambda _actor: SimpleNamespace(
                bench=[1.0, 3.0, None, None, None]
            )
        )

        class Challenge:
            @staticmethod
            def _forced_promotion_value(
                _state,
                _actor,
                pokemon,
            ):
                return pokemon

            @staticmethod
            def choose_action(_state, _actor):
                return GameAction("END_TURN")

        actions = (
            GameAction("PROMOTE", {"bench_idx": 0}, actor=1),
            GameAction("PROMOTE", {"bench_idx": 1}, actor=1),
        )
        selected, proposal = _challenge_authoritative_action(
            state,
            1,
            Challenge(),
            actions,
        )
        self.assertIsNone(proposal)
        self.assertEqual(selected, actions[1])

    def test_final_league_has_6000_seed_closed_games(self):
        tasks = final_league_tasks(5, 600, 17)
        self.assertEqual(len(tasks), 6_000)
        for start in range(0, len(tasks), 60):
            matchup = tasks[start:start + 60]
            self.assertEqual({task.seat_a for task in matchup}, {0, 1})
            self.assertEqual(
                {task.first_player for task in matchup},
                {0, 1},
            )
            for closure_start in range(0, len(matchup), 4):
                closure = matchup[
                    closure_start:closure_start + 4
                ]
                self.assertEqual(
                    len({task.seed for task in closure}),
                    1,
                )

    def test_final_league_choice_uses_native_search(self):
        candidate = SearchCandidate(
            "choice:done",
            ChoiceResponse("request", ("done",)),
        )

        class State:
            public_deck_keys = ("fire", "water")
            result_status = "WIN"
            winner = 0

            def __init__(self):
                self.terminal = False

            def is_terminal(self):
                return self.terminal

        class Environment:
            @staticmethod
            def actor(_state):
                return 0

            @staticmethod
            def candidates(_state, _actor):
                return (candidate,)

            @staticmethod
            def apply(state, selected, _seed):
                if selected is not candidate:
                    raise AssertionError("unexpected_selected_candidate")
                state.terminal = True

        class Evaluator:
            choice_calls = 0
            action_calls = 0
            choice_arguments = None

            def search_choice(self, _state, actor, candidates, **kwargs):
                self.choice_calls += 1
                self.choice_arguments = (actor, tuple(candidates), kwargs)
                return SimpleNamespace(selected=candidate, simulations=128)

            def search_action(self, *_args, **_kwargs):
                self.action_calls += 1
                raise AssertionError("choice_must_not_use_search_action")

        state = State()
        environment = Environment()
        evaluator = Evaluator()
        task = GameTask(
            game_id="final-choice-native",
            generation=6,
            deck_a="fire",
            deck_b="water",
            seed=17,
            seat_a=0,
            first_player=0,
        )
        with (
            patch(
                "engine.ai.dl.alphazero_v2._setup_game",
                return_value=state,
            ),
            patch(
                "engine.ai.dl.alphazero_v2.PythonGameEnvironment",
                return_value=environment,
            ),
            patch(
                "engine.ai.dl.alphazero_v2._advance_nondecision_phase",
                return_value=False,
            ),
            patch(
                "engine.ai.dl.alphazero_v2.DEFAULT_GAME_ENGINE."
                "pending_choice_request",
                return_value=SimpleNamespace(),
            ),
        ):
            result = play_model_vs_challenge_game(
                task,
                evaluator,
                simulations=128,
                c_puct=1.4,
                max_decisions=2,
            )

        self.assertEqual(evaluator.choice_calls, 1)
        self.assertEqual(evaluator.action_calls, 0)
        actor, candidates, kwargs = evaluator.choice_arguments
        self.assertEqual(actor, 0)
        self.assertEqual(candidates, (candidate,))
        self.assertEqual(kwargs["simulations"], 128)
        self.assertEqual(result.decisions, 1)
        self.assertEqual(result.simulations, 128)
        self.assertFalse(result.truncated)

    def test_arena_decision_count_does_not_depend_on_training_samples(self):
        candidate = SimpleNamespace(signature=("action", "end"))

        class State:
            turn_number = 1
            result_status = "DRAW"
            winner = None
            public_deck_keys = ("fire", "water")

            def __init__(self):
                self.terminal = False

            def is_terminal(self):
                return self.terminal

        class Environment:
            @staticmethod
            def actor(_state):
                return 0

            @staticmethod
            def candidates(_state, _actor):
                return (candidate,)

            @staticmethod
            def observation(_state, _actor):
                return None

            @staticmethod
            def apply(state, _selected, _seed):
                state.terminal = True

        class Evaluator:
            @staticmethod
            def search_action(_state, _actor, _candidates, **_kwargs):
                return SimpleNamespace(selected=candidate, simulations=128)

        task = GameTask(
            game_id="arena-decision-count",
            generation=1,
            deck_a="fire",
            deck_b="water",
            seed=17,
            seat_a=0,
            first_player=0,
        )
        with (
            patch(
                "engine.ai.dl.alphazero_v2._setup_game",
                return_value=State(),
            ),
            patch(
                "engine.ai.dl.alphazero_v2.PythonGameEnvironment",
                return_value=Environment(),
            ),
            patch(
                "engine.ai.dl.alphazero_v2._advance_nondecision_phase",
                return_value=False,
            ),
            patch(
                "engine.ai.dl.alphazero_v2.DEFAULT_GAME_ENGINE."
                "pending_choice_request",
                return_value=None,
            ),
        ):
            result = play_self_play_game(
                task,
                Evaluator(),
                simulations=128,
                c_puct=1.4,
                max_decisions=2,
                training=False,
            )

        self.assertEqual(result.decisions, 1)
        self.assertEqual(result.simulations, 128)
        self.assertFalse(result.truncated)

    def test_learning_rate_warmup_and_cosine_share_global_horizon(self):
        warmup = 2_000
        total = 22_000
        self.assertAlmostEqual(
            learning_rate_multiplier(0, warmup, total),
            1.0 / warmup,
        )
        self.assertEqual(
            learning_rate_multiplier(warmup - 1, warmup, total),
            1.0,
        )
        self.assertEqual(
            learning_rate_multiplier(warmup, warmup, total),
            1.0,
        )
        middle = learning_rate_multiplier(12_000, warmup, total)
        self.assertGreater(middle, 0.0)
        self.assertLess(middle, 1.0)
        self.assertEqual(
            learning_rate_multiplier(total - 1, warmup, total),
            0.0,
        )

    def test_replay_round_trip_and_generation_window(self):
        encoder = InformationSetEncoderV7()
        observation = _observation()
        info = encoder.encode_information_set(observation)
        candidates = encoder.encode_actions(
            observation,
            [GameAction("END_TURN")],
        )
        sample = AlphaZeroSample(
            info,
            candidates,
            np.asarray((1.0,), dtype=np.float32),
            np.asarray((1.0, 0.0, 0.0), dtype=np.float32),
            0,
            "fire",
            "water",
            1,
            "game",
            0,
        )
        with tempfile.TemporaryDirectory() as directory:
            store = ReplayStoreV2(directory, capacity=10, keep_generations=3)
            store.add_generation(1, [sample])
            store.add_generation(2, [replace(
                sample,
                generation=2,
                game_id="future-game",
            )])
            loaded = ReplayStoreV2(directory, capacity=10, keep_generations=3)
            self.assertEqual(loaded.load(1), 1)
            self.assertEqual(loaded.samples[0].game_id, "game")
            self.assertEqual(loaded.load(2), 2)

    def test_training_batch_prefetch_preserves_order_without_revalidation(self):
        encoder = InformationSetEncoderV7()
        observation = _observation()
        sample = AlphaZeroSample(
            encoder.encode_information_set(observation),
            encoder.encode_actions(
                observation,
                [GameAction("END_TURN")],
            ),
            np.asarray((1.0,), dtype=np.float32),
            np.asarray((1.0, 0.0, 0.0), dtype=np.float32),
            0,
            "fire",
            "water",
            1,
            "first-game",
            0,
        )
        second = replace(
            sample,
            wdl_target=np.asarray((0.0, 0.0, 1.0), dtype=np.float32),
            game_id="second-game",
            ply=1,
        )
        with patch.object(
            AlphaZeroSample,
            "validate",
            side_effect=AssertionError("validated in hot path"),
        ):
            batches = list(_prefetched_training_batches(
                [sample, second],
                batch_size=1,
                device="cpu",
            ))
        self.assertEqual(len(batches), 2)
        np.testing.assert_array_equal(
            batches[0]["wdl_target"].numpy(),
            np.asarray(((1.0, 0.0, 0.0),), dtype=np.float32),
        )
        np.testing.assert_array_equal(
            batches[1]["wdl_target"].numpy(),
            np.asarray(((0.0, 0.0, 1.0),), dtype=np.float32),
        )

    def test_bootstrap_cache_round_trip_preserves_seed_split(self):
        encoder = InformationSetEncoderV7()
        observation = _observation()
        info = encoder.encode_information_set(observation)
        candidates = encoder.encode_actions(
            observation,
            [GameAction("END_TURN")],
        )
        sample = AlphaZeroSample(
            info,
            candidates,
            np.asarray((1.0,), dtype=np.float32),
            np.asarray((1.0, 0.0, 0.0), dtype=np.float32),
            0,
            "fire",
            "water",
            0,
            "train-game",
            0,
            source="challenge_bootstrap",
        )
        validation_sample = replace(
            sample,
            game_id="validation-game",
        )
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "bootstrap.pt"
            save_bootstrap_cache(
                cache,
                [sample],
                [validation_sample],
                repo_root=root,
                split_manifest={
                    "schema": "game_seed_90_10_v1",
                    "train_games": ["train-game"],
                    "validation_games": ["validation-game"],
                    "train_seeds": [101],
                    "validation_seeds": [202],
                },
            )
            train, validation = load_bootstrap_splits(
                cache,
                repo_root=root,
            )
        self.assertEqual(
            [row.game_id for row in train],
            ["train-game"],
        )
        self.assertEqual(
            [row.game_id for row in validation],
            ["validation-game"],
        )

    def test_smoke_preset_never_requires_native(self):
        config = AlphaZeroV2Config.smoke("out", "cache", device="cpu")
        self.assertFalse(config.require_native)
        self.assertEqual(config.generations, 1)

    def test_wall_clock_failure_is_recorded_without_stopping_pipeline(self):
        with tempfile.TemporaryDirectory() as directory:
            config = replace(
                AlphaZeroV2Config.smoke(
                    directory,
                    str(Path(directory) / "teacher"),
                    device="cpu",
                ),
                max_wall_seconds=1.0,
            )
            trainer = AlphaZeroV2Trainer(config)
            with patch.object(
                trainer,
                "_elapsed_seconds",
                return_value=2.0,
            ):
                self.assertFalse(trainer._check_wall_clock())
                self.assertFalse(trainer._check_wall_clock())

            events = [
                json.loads(line)
                for line in trainer.events_path.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            self.assertEqual(len(events), 1)
            self.assertEqual(
                events[0]["event"],
                "training_wall_clock_budget_exceeded",
            )
            self.assertEqual(
                events[0]["policy"],
                "continue_non_promotable",
            )
            self.assertEqual(events[0]["elapsed_seconds"], 2.0)
            self.assertEqual(events[0]["wall_clock_budget_seconds"], 1.0)

    def test_trainer_uses_shared_native_simulation_limiter(self):
        if not native_training_bridge_available():
            self.skipTest("native training bridge is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            config = AlphaZeroV2Config.smoke(
                directory,
                str(Path(directory) / "teacher"),
                device="cpu",
            )
            config = replace(
                config,
                actor_threads=3,
                concurrent_games=8,
            )
            trainer = AlphaZeroV2Trainer(config)
            limiter = trainer._native_simulation_limiter
            self.assertIsNotNone(limiter)
            self.assertEqual(limiter.capacity, 3)
            self.assertEqual(limiter.active, 0)

    def test_training_state_round_trip_rejects_config_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            config = AlphaZeroV2Config.smoke(
                directory,
                str(Path(directory) / "teacher"),
                device="cpu",
            )
            trainer = AlphaZeroV2Trainer(config)
            checkpoint = Path(directory) / "champion-g000.pt"
            save_checkpoint(
                str(checkpoint),
                create_model(),
                {"generation": 0, "accepted": True},
            )
            trainer._write_training_state(
                next_generation=1,
                global_step=7,
                accepted_checkpoints=[checkpoint.name],
                generation_rows=[],
            )
            loaded = AlphaZeroV2Trainer(config)._load_training_state()
            self.assertEqual(loaded["global_step"], 7)
            self.assertEqual(
                loaded["champion_checkpoint"],
                "champion-g000.pt",
            )

            drifted = replace(config, concurrent_games=3)
            with self.assertRaisesRegex(
                RuntimeError,
                "training_state_fingerprint_mismatch",
            ):
                AlphaZeroV2Trainer(drifted)._load_training_state()

    def test_batched_evaluator_coalesces_requests(self):
        model = create_model()
        evaluator = BatchedTorchEvaluator(
            model,
            device="cpu",
            target_batch_size=2,
            max_batch_size=4,
            coalesce_ms=50,
        )
        candidates = [
            SearchCandidate("a", GameAction("END_TURN")),
            SearchCandidate("b", GameAction("SETUP_DONE")),
        ]
        results = []

        def run():
            results.append(
                evaluator.evaluate(_observation(), candidates, "fire")
            )

        threads = [threading.Thread(target=run) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        evaluator.close()
        self.assertEqual(len(results), 2)
        self.assertGreaterEqual(evaluator.max_observed_batch, 2)

    def test_cross_actor_choice_uses_the_backend_holding_continuation(self):
        class MissingContext:
            def search_choice(self, *_args, **_kwargs):
                raise NativeBridgeError(
                    "native_choice_continuation_unavailable"
                )

        class ContextOwner:
            def search_choice(self, _state, actor, candidates, **_kwargs):
                return actor, candidates

        candidates = [SearchCandidate("choice", GameAction("END_TURN"))]
        evaluator = _SeatEvaluator(
            {0: ContextOwner(), 1: MissingContext()}
        )
        self.assertEqual(
            evaluator.search_choice(None, 1, candidates),
            (1, candidates),
        )


if __name__ == "__main__":
    unittest.main()

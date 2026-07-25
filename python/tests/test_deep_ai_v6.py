from __future__ import annotations

import json
import random
import tempfile
import time
import unittest
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from data.ai_card_vocab import (
    CARD_OOV_INDEX,
    CARD_PAD_INDEX,
    CARD_VOCAB_VERSION,
    card_vocab_index,
    card_vocab_sha256,
    card_vocab_size,
    load_card_vocab,
    validate_release_card_vocab,
)
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, DECK_SPECS, expand_deck
from engine.actions import GameAction
from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_VOCAB_SHA256,
    DISCARD_TOKEN_COUNT,
    ENCODER_SCHEMA_VERSION,
    OWN_DISCARD_TOKEN_START,
    OWN_HAND_TOKEN_START,
    OPPONENT_DISCARD_TOKEN_START,
    RESERVED_TOKEN_START,
    STADIUM_TOKEN_INDEX,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
    ActionStateEncoder,
    EncodedAction,
    EncodedState,
    _pad,
    _pad_ids,
    card_bucket,
    card_index,
)
from engine.ai.dl.hybrid_population import (
    CHOICE_REPLAY_CAPACITY_PER_DECK,
    CHOICE_VALIDATION_CAPACITY_PER_DECK,
    HybridPopulationTrainer,
    choice_drift_gate,
    split_choice_examples,
)
from engine.ai.dl.mcts import (
    _sample_distribution,
    _temperature_visit_distribution,
    _training_visit_temperature,
)
from engine.ai.dl.production_contract import (
    build_population_schedule,
    preset_for,
)
from engine.ai.dl.run_store import ReplayShardStore
from engine.ai.dl.training import ChoiceTrainingExample
from engine.ai.observation import Observation, _deck_prior, fair_search_clone
from engine.ai.planner import AnytimePlanner, PlannerConfig
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from scripts.update_ai_card_vocab import updated_payload
from scripts.evaluate_v6_ablation import (
    _select_winner,
    build_ablation_tasks,
)
from scripts.prepare_hybrid_candidate import (
    _deep_model_contract,
    prepare_candidate,
)
from scripts.validate_v6_research10 import paired_cluster_stats


REPO_ROOT = Path(__file__).resolve().parents[2]


class _PlannerBackend:
    def priors(self, _state, _actor, actions):
        return [0.8, 0.2][:len(actions)]

    def value(self, _state, _perspective):
        return 0.0

    def choose(self, _state, request):
        raise AssertionError(f"unexpected choice: {request}")


class _PlannerEngine:
    def legal_actions(self, _state, actor, **_kwargs):
        return [
            GameAction(PlayerAction.END_TURN, {}, True, actor),
            GameAction(PlayerAction.PLAY_BASIC, {}, False, actor),
        ]

    def apply_action(self, state, _action, _rng, **_kwargs):
        state.winner = 0
        return SimpleNamespace(success=True, terminal=True)


def _choice_example(split_key: str, request_type: str = "confirm"):
    state = EncodedState(
        [0.0] * STATE_NUMERIC_SIZE,
        [0] * STATE_CARD_SLOTS,
    )
    candidate = EncodedAction([0.0] * ACTION_NUMERIC_SIZE, 0)
    return ChoiceTrainingExample(
        state,
        request_type,
        [candidate, candidate],
        0,
        split_key=split_key,
    )


class DeepAIV6Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def test_vocab_is_collision_free_append_only_and_manifested(self):
        vocab = load_card_vocab()
        indices = list(vocab["entries"].values())
        self.assertEqual(CARD_PAD_INDEX, 0)
        self.assertEqual(CARD_OOV_INDEX, 1)
        self.assertEqual(vocab["format_version"], CARD_VOCAB_VERSION)
        self.assertEqual(len(indices), len(set(indices)))
        self.assertEqual(sorted(indices), list(range(2, max(indices) + 1)))
        self.assertEqual(card_vocab_size(), max(indices) + 1)
        self.assertEqual(card_vocab_sha256(), CARD_VOCAB_SHA256)
        self.assertEqual(card_vocab_index("not-a-release-card"), CARD_OOV_INDEX)
        self.assertEqual(card_index("svi-chim"), 92)
        self.assertEqual(card_bucket("svi-chim"), 3624)
        validate_release_card_vocab(tuple(ALL_CARD_IDS))

        release = json.loads(
            (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
        )
        godot_vocab = json.loads(
            (REPO_ROOT / "godot/data/ai_card_vocab.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(godot_vocab, vocab)
        self.assertEqual(
            release["deep_encoder"]["card_vocab_sha256"],
            card_vocab_sha256(),
        )
        self.assertEqual(
            release["deep_encoder"]["card_vocab_size"],
            card_vocab_size(),
        )

    def test_explicit_vocab_update_appends_and_retains_tombstones(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vocab.json"
            path.write_text(
                json.dumps(
                    {
                        "format_version": 1,
                        "pad_index": 0,
                        "oov_index": 1,
                        "entries": {"retired-card": 2},
                        "tombstones": [],
                    }
                ),
                encoding="utf-8",
            )
            payload, added = updated_payload(path)
        self.assertEqual(payload["entries"]["retired-card"], 2)
        self.assertIn("retired-card", payload["tombstones"])
        self.assertEqual(added, sorted(ALL_CARD_IDS))
        self.assertEqual(
            [payload["entries"][card_id] for card_id in added],
            list(range(3, 3 + len(added))),
        )

    def test_normal_export_rejects_unregistered_release_card(self):
        from scripts import export_godot_data

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            export_godot_data,
            "ALL_CARD_IDS",
            tuple(ALL_CARD_IDS) + ("future-unregistered-card",),
        ):
            with self.assertRaisesRegex(RuntimeError, "missing"):
                export_godot_data.export(
                    Path(directory),
                    copy_images=False,
                )
            self.assertFalse((Path(directory) / "data/cards.json").exists())

    def test_fixed_state_token_layout_and_overflow_are_stable(self):
        observation = Observation(
            perspective=1,
            turn_number=4,
            phase="MAIN",
            active_player=1,
            winner=None,
            own_hand=tuple(["svi-chim"] * 20),
            own_discard=tuple(["sv1-104"] * 2 + ["sv1-106"] * 12),
            own_deck_count=20,
            own_prize_count=4,
            opponent_hand_count=7,
            opponent_discard=tuple(["sv1-107"] * 15),
            opponent_deck_count=21,
            opponent_prize_count=5,
            board=(
                (0, "active", "sv2-delib", 1, (), (), ""),
                (
                    1,
                    "active",
                    "svi-chim",
                    2,
                    tuple(["sv1-ener-2"] * 6),
                    (),
                    "sv1-104",
                ),
            ),
            stadium_id="sv1-106",
            public_deck_keys=("fire", "water"),
            apply_type_matchups=False,
        )
        encoded = ActionStateEncoder().encode_observation(
            observation,
            "water",
        )
        self.assertEqual(len(encoded.card_ids), 128)
        self.assertEqual(encoded.card_ids[0], card_index("svi-chim"))
        self.assertEqual(
            encoded.card_ids[1:5],
            [card_index("sv1-ener-2")] * 4,
        )
        self.assertEqual(encoded.card_ids[5], card_index("sv1-104"))
        self.assertEqual(encoded.card_ids[6:36], [0] * 30)
        self.assertEqual(encoded.card_ids[36], card_index("sv2-delib"))
        self.assertEqual(
            encoded.card_ids[OWN_HAND_TOKEN_START],
            card_index("svi-chim"),
        )
        self.assertEqual(
            encoded.card_ids[
                OWN_DISCARD_TOKEN_START:
                OWN_DISCARD_TOKEN_START + DISCARD_TOKEN_COUNT
            ],
            [card_index("sv1-106")] * DISCARD_TOKEN_COUNT,
        )
        self.assertEqual(
            encoded.card_ids[
                OPPONENT_DISCARD_TOKEN_START:
                OPPONENT_DISCARD_TOKEN_START + DISCARD_TOKEN_COUNT
            ],
            [card_index("sv1-107")] * DISCARD_TOKEN_COUNT,
        )
        self.assertEqual(
            encoded.card_ids[STADIUM_TOKEN_INDEX],
            card_index("sv1-106"),
        )
        self.assertEqual(
            encoded.card_ids[RESERVED_TOKEN_START:],
            [0] * (STATE_CARD_SLOTS - RESERVED_TOKEN_START),
        )
        overflow_start = len(TurnPhase) + 13 + len(ActionStateEncoder.deck_keys)
        self.assertAlmostEqual(encoded.numeric[overflow_start], 0.2)
        self.assertAlmostEqual(encoded.numeric[overflow_start + 1], 2.0 / 60.0)
        self.assertAlmostEqual(encoded.numeric[overflow_start + 2], 3.0 / 60.0)
        board_start = overflow_start + 3
        self.assertAlmostEqual(encoded.numeric[board_start + 4], 1.0)

    def test_encoder_padding_rejects_global_silent_truncation(self):
        self.assertEqual(_pad([1.0, 2.0], 2), [1.0, 2.0])
        self.assertEqual(_pad_ids([1, 2], 2), [1, 2])
        with self.assertRaisesRegex(ValueError, "encoder_numeric_overflow"):
            _pad([1.0, 2.0, 3.0], 2)
        with self.assertRaisesRegex(ValueError, "encoder_card_slot_overflow"):
            _pad_ids([1, 2, 3], 2)

    def test_all_release_hidden_priors_and_unknown_placeholder(self):
        for deck, spec in DECK_SPECS.items():
            with self.subTest(deck=deck):
                self.assertEqual(
                    Counter(card.api_id for card in _deck_prior(deck)),
                    Counter(expand_deck(spec)),
                )
        self.assertEqual(_deck_prior("unknown-deck"), [])

        state_a = GameState()
        state_b = GameState()
        for state, hidden_id in (
            (state_a, "svi-chim"),
            (state_b, "sv2-delib"),
        ):
            hidden = CardRegistry.get(hidden_id)
            state.public_deck_keys = ("fire", "unknown-deck")
            state.p2.hand = [hidden] * 2
            state.p2.deck = [hidden] * 3
            state.p2.prizes = [hidden] * 2
        clone_a = fair_search_clone(state_a, 0, 991)
        clone_b = fair_search_clone(state_b, 0, 991)
        identities_a = [
            card.api_id
            for card in clone_a.p2.hand + clone_a.p2.deck + clone_a.p2.prizes
        ]
        identities_b = [
            card.api_id
            for card in clone_b.p2.hand + clone_b.p2.deck + clone_b.p2.prizes
        ]
        self.assertEqual(identities_a, identities_b)
        self.assertNotIn("svi-chim", identities_a)
        self.assertNotIn("sv2-delib", identities_a)

    def test_root_noise_is_local_reproducible_and_inference_can_disable_it(self):
        state = GameState()
        state.turn_number = 4
        actions = _PlannerEngine().legal_actions(state, 0)
        config = PlannerConfig(
            simulation_budget=2,
            thinking_time_seconds=1.0,
            match_seed=17,
            root_dirichlet_alpha=0.3,
            root_dirichlet_epsilon=0.25,
            decision_ordinal=3,
        )
        global_state = random.getstate()
        planners = [
            AnytimePlanner(_PlannerBackend(), config, _PlannerEngine())
            for _ in range(2)
        ]
        for planner in planners:
            planner.search(
                state,
                0,
                actions=actions,
                deadline=time.perf_counter() + 1.0,
            )
        self.assertEqual(random.getstate(), global_state)
        self.assertEqual(
            planners[0].last_result.noisy_priors,
            planners[1].last_result.noisy_priors,
        )
        self.assertNotEqual(
            planners[0].last_result.raw_priors,
            planners[0].last_result.noisy_priors,
        )

        inference = AnytimePlanner(
            _PlannerBackend(),
            PlannerConfig(
                simulation_budget=1,
                root_dirichlet_alpha=0.3,
                root_dirichlet_epsilon=0.0,
            ),
            _PlannerEngine(),
        )
        inference.search(
            state,
            0,
            actions=actions,
            deadline=time.perf_counter() + 1.0,
        )
        self.assertEqual(
            inference.last_result.raw_priors,
            inference.last_result.noisy_priors,
        )
        self.assertIsNone(inference.last_result.root_noise_seed)

    def test_temperature_targets_and_sampling_are_normalized(self):
        self.assertEqual(_training_visit_temperature(1), 1.0)
        self.assertEqual(_training_visit_temperature(6), 1.0)
        self.assertEqual(_training_visit_temperature(7), 0.5)
        self.assertEqual(_training_visit_temperature(12), 0.5)
        self.assertEqual(_training_visit_temperature(13), 0.1)
        visits = {0: 4, 1: 2, 2: 0}
        distribution = _temperature_visit_distribution(
            visits,
            0.5,
            fallback={0: 0.2, 1: 0.3, 2: 0.5},
            greedy_index=0,
        )
        self.assertAlmostEqual(sum(distribution.values()), 1.0)
        self.assertAlmostEqual(distribution[0], 0.8)
        self.assertAlmostEqual(distribution[1], 0.2)
        self.assertEqual(
            _sample_distribution(distribution, 123),
            _sample_distribution(distribution, 123),
        )
        self.assertEqual(
            _temperature_visit_distribution(
                visits,
                0.0,
                fallback={},
                greedy_index=0,
            ),
            {0: 1.0, 1: 0.0, 2: 0.0},
        )

    def test_choice_hash_split_and_drift_thresholds(self):
        examples = [
            _choice_example(f"dagger:steel:{index}")
            for index in range(100)
        ]
        train_a, validation_a = split_choice_examples(examples)
        train_b, validation_b = split_choice_examples(reversed(examples))
        self.assertEqual(
            {row.split_key for row in train_a},
            {row.split_key for row in train_b},
        )
        self.assertEqual(
            {row.split_key for row in validation_a},
            {row.split_key for row in validation_b},
        )
        self.assertFalse(
            {row.split_key for row in train_a}
            & {row.split_key for row in validation_a}
        )
        self.assertEqual(len(train_a) + len(validation_a), len(examples))

        baseline = {
            "overall": {"count": 100, "top1": 0.80},
            "request_types": {
                "confirm": {"count": 50, "top1": 0.80},
                "rare": {"count": 49, "top1": 0.90},
            },
        }
        passing = {
            "overall": {"count": 100, "top1": 0.78},
            "request_types": {
                "confirm": {"count": 50, "top1": 0.75},
                "rare": {"count": 49, "top1": 0.0},
            },
        }
        self.assertTrue(choice_drift_gate(baseline, passing)["passed"])
        passing["overall"]["top1"] = 0.779
        self.assertFalse(choice_drift_gate(baseline, passing)["passed"])
        passing["overall"]["top1"] = 0.80
        passing["request_types"]["confirm"]["top1"] = 0.749
        self.assertFalse(choice_drift_gate(baseline, passing)["passed"])

    def test_choice_shard_hash_restore_capacity_and_pool_isolation(self):
        try:
            import torch  # noqa: F401
        except ImportError:
            self.skipTest("PyTorch is not installed")
        train = _choice_example("dagger:steel:train")
        validation = _choice_example("dagger:steel:validation")
        schema = {
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "state_card_slots": STATE_CARD_SLOTS,
            "card_vocab_version": CARD_VOCAB_VERSION,
            "card_vocab_size": card_vocab_size(),
            "card_vocab_sha256": card_vocab_sha256(),
        }
        with tempfile.TemporaryDirectory() as directory:
            run_dir = Path(directory)
            store = ReplayShardStore(run_dir)
            row = store.write(
                "dagger_steel_choice",
                {
                    "data_schema": schema,
                    "teacher": {},
                    "replay": {},
                    "choice_train": {"steel": [train]},
                    "choice_replay": {"steel": [train]},
                    "choice_validation": {"steel": [validation]},
                },
            )
            self.assertEqual(
                store.rows(verify=True)[0]["sha256"],
                row["sha256"],
            )
            self.assertFalse(list((run_dir / "replay").glob("*.tmp")))

            trainer = HybridPopulationTrainer.__new__(
                HybridPopulationTrainer
            )
            trainer.run_dir = run_dir
            trainer.config = SimpleNamespace(decks=("steel",))
            trainer.replay_store = store
            trainer.teacher_pool = {"steel": []}
            trainer.replay_pool = {"steel": []}
            trainer.choice_train_pool = {"steel": []}
            trainer.choice_replay_pool = {"steel": []}
            trainer.choice_validation_pool = {"steel": []}
            trainer._load_replay_pools([row])
            replay_keys = {
                item.split_key
                for item in trainer.choice_replay_pool["steel"]
            }
            validation_keys = {
                item.split_key
                for item in trainer.choice_validation_pool["steel"]
            }
            self.assertEqual(replay_keys, {train.split_key})
            self.assertEqual(validation_keys, {validation.split_key})
            self.assertTrue(replay_keys.isdisjoint(validation_keys))

            trainer.choice_train_pool["steel"] = (
                [train] * (CHOICE_REPLAY_CAPACITY_PER_DECK + 3)
            )
            trainer.choice_replay_pool["steel"] = (
                [train] * (CHOICE_REPLAY_CAPACITY_PER_DECK + 5)
            )
            trainer.choice_validation_pool["steel"] = (
                [validation]
                * (CHOICE_VALIDATION_CAPACITY_PER_DECK + 7)
            )
            trainer._trim_pools()
            self.assertEqual(
                len(trainer.choice_train_pool["steel"]),
                CHOICE_REPLAY_CAPACITY_PER_DECK,
            )
            self.assertEqual(
                len(trainer.choice_replay_pool["steel"]),
                CHOICE_REPLAY_CAPACITY_PER_DECK,
            )
            self.assertEqual(
                len(trainer.choice_validation_pool["steel"]),
                CHOICE_VALIDATION_CAPACITY_PER_DECK,
            )

            shard_path = run_dir / "replay" / str(row["path"])
            shard_path.write_bytes(shard_path.read_bytes() + b"tamper")
            with self.assertRaisesRegex(RuntimeError, "hash mismatch"):
                store.rows(verify=True)

    def test_choice_generation_metrics_are_persisted_and_gated(self):
        baseline = {
            "overall": {
                "count": 60,
                "top1": 0.80,
                "nll": 0.5,
                "ece10": 0.1,
            },
            "request_types": {
                "confirm": {
                    "count": 60,
                    "top1": 0.80,
                    "nll": 0.5,
                    "ece10": 0.1,
                },
            },
        }
        passing = {
            "overall": {
                "count": 60,
                "top1": 0.79,
                "nll": 0.51,
                "ece10": 0.11,
            },
            "request_types": {
                "confirm": {
                    "count": 60,
                    "top1": 0.76,
                    "nll": 0.51,
                    "ece10": 0.11,
                },
            },
        }
        failing = json.loads(json.dumps(passing))
        failing["request_types"]["confirm"]["top1"] = 0.70
        with tempfile.TemporaryDirectory() as directory:
            trainer = HybridPopulationTrainer.__new__(
                HybridPopulationTrainer
            )
            trainer.config = SimpleNamespace(
                decks=("steel",),
                generations=2,
            )
            trainer.models = {"steel": object()}
            trainer.device = "cpu"
            trainer.choice_validation_pool = {
                "steel": [_choice_example("dagger:steel:validation")]
            }
            trainer.choice_baseline_metrics = {"steel": baseline}
            trainer.choice_metrics_history = []
            trainer.run_dir = Path(directory)
            trainer.events = SimpleNamespace(
                emit=lambda **_kwargs: None
            )
            with mock.patch(
                "engine.ai.dl.hybrid_population.evaluate_choice_metrics",
                return_value=passing,
            ):
                row = trainer._record_choice_generation_metrics(1)
            self.assertTrue(row["passed"])
            self.assertTrue(
                (
                    Path(directory)
                    / "evaluation"
                    / "choice_generation_1.json"
                ).is_file()
            )
            with mock.patch(
                "engine.ai.dl.hybrid_population.evaluate_choice_metrics",
                return_value=failing,
            ):
                with self.assertRaisesRegex(
                    RuntimeError,
                    "Choice validation drift gate failed",
                ):
                    trainer._record_choice_generation_metrics(2)
            self.assertEqual(
                [row["generation"] for row in trainer.choice_metrics_history],
                [1, 2],
            )

    def test_research_presets_are_exact_and_non_promotable(self):
        research2 = preset_for("research2")
        self.assertEqual(research2.decks, ("steel", "darkness"))
        self.assertEqual(
            (
                research2.teacher_games,
                research2.dagger_games,
                research2.generations,
                research2.games_per_matchup,
                research2.current_generation_games,
                research2.historical_games,
                research2.mcts_simulations,
                research2.rollout_workers,
            ),
            (200, 200, 2, 8, 4, 4, 64, 4),
        )
        self.assertFalse(research2.promotable)
        self.assertEqual(
            len(
                build_population_schedule(
                    generation=1,
                    decks=research2.decks,
                    games_per_matchup=8,
                    current_generation_games=4,
                    historical_games=4,
                )
            ),
            24,
        )
        research10 = preset_for("research10")
        self.assertEqual(len(research10.decks), 10)
        self.assertEqual(research10.rollout_workers, 10)
        self.assertFalse(research10.promotable)

    def test_ablation_cross_requires_the_complete_win_gate(self):
        winner, decision, passed = _select_winner(
            {
                "v6_pooled": True,
                "v6_cross_attention": True,
            },
            cross_statistical_gate=False,
        )
        self.assertEqual((winner, decision, passed), (
            "v6_pooled",
            "pooled_control_selected",
            False,
        ))
        winner, decision, passed = _select_winner(
            {
                "v6_pooled": False,
                "v6_cross_attention": True,
            },
            cross_statistical_gate=False,
        )
        self.assertEqual((winner, decision, passed), (
            None,
            "stop_no_qualified_variant",
            False,
        ))
        winner, decision, passed = _select_winner(
            {
                "v6_pooled": False,
                "v6_cross_attention": True,
            },
            cross_statistical_gate=True,
        )
        self.assertEqual((winner, decision, passed), (
            "v6_cross_attention",
            "cross_gate_passed",
            True,
        ))

        ablation_tasks, metadata = build_ablation_tasks(seed=17)
        self.assertEqual(len(ablation_tasks), 280)
        self.assertEqual(
            len({row["block_id"] for row in metadata.values()}),
            120,
        )
        self.assertEqual(
            sum(row["kind"] == "mirror" for row in metadata.values()),
            200,
        )
        self.assertEqual(
            sum(row["kind"] == "cross" for row in metadata.values()),
            80,
        )

    def test_research10_gate_uses_fixed_paired_cluster_schedule(self):
        matches = []
        for block in range(50):
            for game in range(2):
                matches.append({
                    "matchup_kind": "mirror",
                    "pair_key": f"mirror:{block}",
                    "winner": "A" if game == 0 else "B",
                })
        for block in range(45):
            for game in range(4):
                matches.append({
                    "matchup_kind": "cross",
                    "role_crossover_block_key": f"cross:{block}",
                    "winner": "A" if game % 2 == 0 else "B",
                })
        first = paired_cluster_stats(matches, seed=17)
        second = paired_cluster_stats(matches, seed=17)
        self.assertEqual(first, second)
        self.assertEqual(first["games"], 280)
        self.assertEqual(first["mirror_units"], 50)
        self.assertEqual(first["cross_units"], 45)
        self.assertEqual(first["point_rate_delta"], 0.0)
        self.assertEqual(first["ci95"]["iterations"], 10_000)

    def test_research_candidate_export_requires_explicit_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            run_dir = Path(directory)
            research = preset_for("research10")
            (run_dir / "run.json").write_text(
                json.dumps({
                    "run_id": "research-only",
                    "preset": "research10",
                    "status": "completed",
                    "promotable": False,
                    "config": {
                        "decks": list(research.decks),
                        "seed": 17,
                        "teacher_games": research.teacher_games,
                        "dagger_games": research.dagger_games,
                        "generations": research.generations,
                        "games_per_matchup": research.games_per_matchup,
                        "current_generation_games": (
                            research.current_generation_games
                        ),
                        "historical_games": research.historical_games,
                        "mcts_simulations": research.mcts_simulations,
                        "rollout_workers": research.rollout_workers,
                        "use_amp": research.use_amp,
                        "device": research.device,
                        "model_variant": "v6_pooled",
                    },
                }),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "allow-research"):
                prepare_candidate(run_dir)
            with self.assertRaisesRegex(RuntimeError, "artifact is missing"):
                prepare_candidate(run_dir, allow_research=True)

    def test_candidate_root_model_contract_matches_every_runtime_row(self):
        model_config = {
            "state_numeric_size": STATE_NUMERIC_SIZE,
            "state_card_slots": STATE_CARD_SLOTS,
            "action_numeric_size": ACTION_NUMERIC_SIZE,
            "card_bucket_count": card_vocab_size(),
            "card_embed_dim": 32,
            "hidden_size": 384,
            "choice_head_enabled": True,
            "use_attention": True,
            "use_slot_embeddings": True,
            "use_token_type_embeddings": True,
            "candidate_cross_attention": True,
            "attention_heads": 4,
            "candidate_cross_attention_heads": 4,
            "state_norm": "layer",
            "deck_embed_dim": 0,
            "num_decks": 10,
            "card_identity_mode": "vocab_v1",
        }
        runtime = {
            "card_vocab_version": CARD_VOCAB_VERSION,
            "card_vocab_size": card_vocab_size(),
            "card_vocab_sha256": card_vocab_sha256(),
            "models": {
                deck: {
                    "checkpoint_version": 11,
                    "encoder_version": ENCODER_SCHEMA_VERSION,
                    "model_config": dict(model_config),
                }
                for deck in ("steel", "darkness")
            },
        }
        contract = _deep_model_contract(
            {
                "config": {
                    "model_variant": "v6_cross_attention",
                },
            },
            runtime,
            ["steel", "darkness"],
        )
        self.assertEqual(contract["config"], model_config)
        self.assertEqual(contract["variant"], "v6_cross_attention")
        runtime["models"]["darkness"]["model_config"][
            "hidden_size"
        ] = 192
        with self.assertRaisesRegex(
            RuntimeError,
            "not identical",
        ):
            _deep_model_contract(
                {
                    "config": {
                        "model_variant": "v6_cross_attention",
                    },
                },
                runtime,
                ["steel", "darkness"],
            )

    def test_v11_checkpoint_rejects_vocab_sha_mismatch(self):
        try:
            import torch
        except ImportError:
            self.skipTest("PyTorch is not installed")
        from engine.ai.dl.model import create_model, load_checkpoint, save_checkpoint

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.pt"
            save_checkpoint(str(path), create_model())
            payload = torch.load(path, map_location="cpu", weights_only=False)
            payload["encoder_config"]["card_vocab_sha256"] = "0" * 64
            torch.save(payload, path)
            with self.assertRaisesRegex(ValueError, "card_vocab_sha256"):
                load_checkpoint(str(path))

    def test_v10_checkpoint_loads_read_only_and_cannot_be_resaved(self):
        try:
            import torch
        except ImportError:
            self.skipTest("PyTorch is not installed")
        from engine.ai.dl.model import (
            create_model,
            load_checkpoint,
            save_checkpoint,
        )

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "legacy.pt"
            destination = Path(directory) / "forbidden-v11.pt"
            save_checkpoint(str(source), create_model())
            payload = torch.load(
                source,
                map_location="cpu",
                weights_only=False,
            )
            payload["version"] = 10
            torch.save(payload, source)
            model, loaded = load_checkpoint(str(source))
            self.assertTrue(loaded["compatibility"]["read_only"])
            self.assertFalse(loaded["compatibility"]["runtime_compatible"])
            with self.assertRaisesRegex(ValueError, "read-only"):
                save_checkpoint(str(destination), model)
            self.assertFalse(destination.exists())

    def test_pooled_and_cross_models_handle_empty_dynamic_candidates(self):
        try:
            import torch
        except ImportError:
            self.skipTest("PyTorch is not installed")
        from engine.ai.dl.model import checkpoint_payload, create_model

        state_numeric = torch.zeros(1, STATE_NUMERIC_SIZE)
        state_cards = torch.zeros(1, STATE_CARD_SLOTS, dtype=torch.long)
        for cross_attention in (False, True):
            with self.subTest(cross_attention=cross_attention):
                model = create_model(
                    candidate_cross_attention=cross_attention,
                )
                action_numeric = torch.zeros(
                    1,
                    3,
                    ACTION_NUMERIC_SIZE,
                )
                action_cards = torch.zeros(1, 3, dtype=torch.long)
                choice_numeric = torch.zeros(
                    1,
                    5,
                    ACTION_NUMERIC_SIZE,
                )
                choice_cards = torch.zeros(1, 5, dtype=torch.long)
                with torch.no_grad():
                    logits, value = model(
                        state_numeric,
                        state_cards,
                        action_numeric,
                        action_cards,
                    )
                    choice_logits = model.score_choices(
                        state_numeric,
                        state_cards,
                        choice_numeric,
                        choice_cards,
                    )
                self.assertEqual(tuple(logits.shape), (1, 3))
                self.assertEqual(tuple(value.shape), (1,))
                self.assertEqual(tuple(choice_logits.shape), (1, 5))
                self.assertTrue(torch.isfinite(logits).all())
                self.assertTrue(torch.isfinite(value).all())
                self.assertTrue(torch.isfinite(choice_logits).all())
                expected_input = (
                    384 + ACTION_NUMERIC_SIZE + 32
                    + (32 if cross_attention else 0)
                )
                self.assertEqual(
                    model.action_net[0].in_features,
                    expected_input,
                )
                self.assertEqual(model.num_decks, 10)
                self.assertEqual(model.card_attn.num_heads, 4)
                if cross_attention:
                    self.assertEqual(model.action_cross_attn.num_heads, 4)
                    self.assertEqual(model.choice_cross_attn.num_heads, 4)
                self.assertEqual(
                    checkpoint_payload(model)["model_config"]["num_decks"],
                    10,
                )

    def test_encoder_and_checkpoint_versions_are_v6_v11(self):
        from engine.ai.dl.model import CHECKPOINT_VERSION

        self.assertEqual(ENCODER_SCHEMA_VERSION, 6)
        self.assertEqual(CHECKPOINT_VERSION, 11)
        self.assertEqual(STATE_CARD_SLOTS, 128)
        release = json.loads(
            (REPO_ROOT / "release_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        deep_model = release["deep_model"]
        self.assertEqual(
            deep_model["allowed_variants"],
            ["v6_pooled", "v6_cross_attention"],
        )
        self.assertEqual(
            deep_model["status"],
            "research_selection_pending",
        )
        self.assertEqual(
            deep_model["invariants"],
            {
                "state_numeric_size": 960,
                "state_card_slots": 128,
                "action_numeric_size": 178,
                "card_bucket_count": card_vocab_size(),
                "card_embed_dim": 32,
                "hidden_size": 384,
                "choice_head_enabled": True,
                "use_attention": True,
                "attention_heads": 4,
                "use_slot_embeddings": True,
                "use_token_type_embeddings": True,
                "candidate_cross_attention_heads": 4,
                "state_norm": "layer",
                "deck_embed_dim": 0,
                "num_decks": 10,
                "card_identity_mode": "vocab_v1",
            },
        )


if __name__ == "__main__":
    unittest.main()

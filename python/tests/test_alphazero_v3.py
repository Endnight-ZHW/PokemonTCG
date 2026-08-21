from __future__ import annotations

import copy
import concurrent.futures
import json
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

import numpy as np

from engine.ai.dl.encoder_v3 import InformationSetEncoderV8
from engine.ai.dl.learner_v3 import DeepLearnerV3, LearnerConfigV3
from engine.ai.dl.model_v3 import create_model
from engine.ai.dl.replay_v3 import ReplaySampleV3, ReplayStoreV3
from engine.ai.dl.run_control_v3 import RunControlV3, TrainingCancelled
from engine.ai.dl.trainer_v3 import AlphaZeroV3Trainer
from engine.ai.dl.v3_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    CHECKPOINT_VERSION,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    MODEL_VARIANT,
    STATE_GLOBAL_SIZE,
)
from engine.ai.dl.worker_v3 import AtomicWorkerExchangeV3


REPO_ROOT = Path(__file__).resolve().parents[2]


def _pokemon(card_id: str = "svi-chim") -> dict:
    return {
        "card_id": card_id,
        "damage_counters": 1,
        "energy_card_ids": ["sv1-ener-2"],
        "attached_tool_id": "",
        "status_conditions": [],
        "evolution_stack_ids": [],
        "can_evolve_this_turn": True,
        "placed_this_turn": False,
        "used_abilities": [],
        "damage_prevented": False,
        "all_prevented": False,
        "outgoing_damage_reduction": 0,
        "attack_locked": False,
        "dazzled": False,
        "healed_this_turn": False,
        "paralyzed_since_turn": 0,
        "modifiers": [],
        "max_hp_modifiers": [],
    }


def _player(*, own: bool) -> dict:
    return {
        "hand": ["svi-ente", "sv1-ener-2"] if own else ["__hidden_card__"] * 2,
        "discard": ["sv1-ener-2"],
        "deck": ["__hidden_card__"] * 45,
        "prizes": ["__hidden_prize__"] * 6,
        "active": _pokemon(),
        "bench": [],
        "supporter_played_this_turn": False,
        "energy_attached_this_turn": False,
        "retreated_this_turn": False,
        "stadium_played_this_turn": False,
        "stadium_used_this_turn": False,
        "healed_this_turn": False,
        "vstar_power_used": False,
        "was_ko_by_attack": False,
    }


def _observation() -> dict:
    return {
        "perspective": 0,
        "phase": "MAIN",
        "turn_number": 3,
        "active_player_idx": 0,
        "first_player_idx": 0,
        "winner": -1,
        "revision": 9,
        "apply_type_matchups": False,
        "setup_stage": "COMPLETE",
        "players": [_player(own=True), _player(own=False)],
        "public_deck_keys": ["fire", "water"],
        "pending_promotions": [],
        "turn_fact_book": {
            "previous_turn": {"knockouts": []},
            "current_turn": {"knockouts": []},
        },
        "stadium_card_id": "",
    }


def _action(index: int = 0) -> dict:
    return {
        "schema_version": 4,
        "action_id": f"test:v3:{index}",
        "base_revision": 9,
        "actor": 0,
        "kind": "END_TURN",
        "source": None,
        "target": None,
        "payload": {},
    }


def _sample(
    game_id: str,
    source: str = "self_play",
    *,
    game_seed: int | None = None,
    candidate_count: int = 1,
    cycle: int = 1,
    model_version: int = 1,
) -> ReplaySampleV3:
    encoder = InformationSetEncoderV8()
    info = encoder.encode_information_set(_observation())
    candidates = encoder.encode_actions(
        _observation(),
        [_action(index) for index in range(candidate_count)],
    )
    return ReplaySampleV3(
        info,
        candidates,
        np.full(candidate_count, 1.0 / candidate_count, dtype=np.float32),
        np.asarray((0.0, 1.0, 0.0), dtype=np.float32),
        game_id,
        17 + len(game_id) if game_seed is None else game_seed,
        0,
        0,
        0,
        1,
        model_version,
        cycle,
        0,
        source,
    )


class AlphaZeroV3ContractTests(unittest.TestCase):
    def test_contract_and_model_shapes(self):
        import torch

        self.assertEqual(ENCODER_SCHEMA_VERSION, 8)
        self.assertEqual(CHECKPOINT_VERSION, 13)
        self.assertEqual(MODEL_VARIANT, "universal_infoset_transformer_v3")
        model = create_model()
        batch, candidates = 2, 3
        outputs = model(
            torch.zeros(batch, STATE_GLOBAL_SIZE),
            torch.zeros(batch, ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
            torch.zeros(batch, ENTITY_SLOTS, dtype=torch.long),
            torch.zeros(batch, ENTITY_SLOTS, 4, dtype=torch.long),
            torch.ones(batch, ENTITY_SLOTS, dtype=torch.bool),
            torch.zeros(batch, candidates, CANDIDATE_NUMERIC_SIZE),
            torch.zeros(batch, candidates, dtype=torch.long),
            torch.ones(batch, candidates, dtype=torch.long),
            torch.zeros(batch, candidates, CANDIDATE_REF_FIELDS, dtype=torch.long),
            torch.ones(batch, candidates, dtype=torch.bool),
            torch.zeros(batch, dtype=torch.long),
            torch.ones(batch, dtype=torch.long),
        )
        self.assertEqual(tuple(outputs[0].shape), (batch, candidates))
        self.assertEqual(tuple(outputs[1].shape), (batch, 3))

    def test_encoder_rejects_hidden_identity_and_tracks_observable_status(self):
        encoder = InformationSetEncoderV8()
        baseline = encoder.encode_information_set(_observation())
        changed = _observation()
        changed["players"][0]["active"]["status_conditions"] = ["CONFUSED"]
        encoded_changed = encoder.encode_information_set(changed)
        self.assertFalse(
            np.array_equal(baseline.entity_numeric, encoded_changed.entity_numeric)
        )
        leaked = _observation()
        leaked["players"][1]["hand"][0] = "svi-ente"
        with self.assertRaisesRegex(ValueError, "v3_hidden_identity_exposed"):
            encoder.encode_information_set(leaked)

        reordered = _observation()
        reordered["players"][0]["hand"].reverse()
        np.testing.assert_array_equal(
            baseline.entity_numeric,
            encoder.encode_information_set(reordered).entity_numeric,
        )
        resource_changed = _observation()
        resource_changed["players"][0]["supporter_played_this_turn"] = True
        self.assertFalse(np.array_equal(
            baseline.state_global,
            encoder.encode_information_set(resource_changed).state_global,
        ))
        request_a = {
            "request_type": "select_card",
            "min_select": 0,
            "max_select": 2,
            "options": [{}, {}],
        }
        request_b = {**request_a, "min_select": 1}
        self.assertFalse(np.array_equal(
            encoder.encode_information_set(
                _observation(), request_a
            ).state_global,
            encoder.encode_information_set(
                _observation(), request_b
            ).state_global,
        ))

    def test_encoder_never_silently_truncates_visible_entities(self):
        encoder = InformationSetEncoderV8()
        observation = _observation()
        observation["players"][0]["hand"] = [
            f"synthetic-visible-{index}" for index in range(149)
        ]
        with self.assertRaisesRegex(ValueError, "v3_entity_overflow"):
            encoder.encode_information_set(observation)

    def test_python_and_native_v3_encoders_match(self):
        try:
            import ptcg_ai_core
        except ImportError:
            self.skipTest("native binding unavailable")
        if not hasattr(ptcg_ai_core, "NativeInformationSetEncoderV3"):
            self.skipTest("v3 native encoder unavailable")
        cards = json.loads(
            (REPO_ROOT / "godot" / "data" / "cards.json").read_text(
                encoding="utf-8"
            )
        )
        python = InformationSetEncoderV8()
        information = python.encode_information_set(_observation())
        candidates = python.encode_actions(_observation(), [_action()])
        native = ptcg_ai_core.NativeInformationSetEncoderV3(cards).encode_actions(
            _observation(), [_action()]
        )
        for name, expected in {
            "state_global": information.state_global,
            "entity_numeric": information.entity_numeric,
            "entity_card_ids": information.entity_card_ids,
            "entity_type_ids": information.entity_type_ids,
            "entity_mask": information.entity_mask,
            "candidate_numeric": candidates.numeric,
            "candidate_card_ids": candidates.card_ids,
            "candidate_type_ids": candidates.type_ids,
            "candidate_refs": candidates.refs,
        }.items():
            np.testing.assert_array_equal(native[name][0], expected)

        target_id = _observation()["players"][0]["active"]["card_id"]
        option_id = (
            "energy:0:sv1-ener-2->"
            f"pokemon:0:active:{target_id}"
        )
        request = {
            "request_type": "distribute_energy",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [{
                "option_id": option_id,
                "ref": {
                    "kind": "pokemon",
                    "player": 0,
                    "slot": "active",
                    "card_id": target_id,
                },
            }],
            "presentation": {"source_zone": "hand"},
        }
        choice_candidates = [{
            "kind": "choice",
            "selected_options": [option_id],
            "cancelled": False,
        }]
        python_choices = python.encode_choices(
            _observation(), request, choice_candidates
        )
        native_choices = ptcg_ai_core.NativeInformationSetEncoderV3(
            cards
        ).encode_choices(_observation(), request, choice_candidates)
        np.testing.assert_array_equal(
            native_choices["candidate_refs"][0],
            python_choices.refs,
        )
        np.testing.assert_array_equal(
            native_choices["candidate_card_ids"][0],
            python_choices.card_ids,
        )
        self.assertNotEqual(int(python_choices.refs[0, 0]), 0)
        self.assertNotEqual(int(python_choices.refs[0, 4]), 0)
        leaked = _observation()
        leaked["players"][1]["hand"][0] = "svi-ente"
        with self.assertRaisesRegex(ValueError, "v3_hidden_identity_exposed"):
            ptcg_ai_core.NativeInformationSetEncoderV3(cards).encode_actions(
                leaked, [_action()]
            )


class ReplayAndLearnerV3Tests(unittest.TestCase):
    def test_teacher_retention_selects_maximum_safe_learner_fraction(self):
        import torch

        class ScalarModel(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.weight = torch.nn.Parameter(torch.ones(()))

        class ScalarLearner:
            def __init__(self):
                self.model = ScalarModel()
                self.global_step = 37

            def evaluate(self, **_kwargs):
                loss = 1.0 + 2.0 * float(self.model.weight.detach())
                return {"total_loss": loss}

        trainer = object.__new__(AlphaZeroV3Trainer)
        trainer.config = SimpleNamespace(
            maximum_teacher_regression=0.10,
            teacher_retention_search_steps=10,
        )
        trainer.warmup_evidence = {"best_validation_total_loss": 1.0}
        trainer.learner = ScalarLearner()
        trainer._load_teacher_anchor = lambda: {"weight": torch.zeros(())}
        trainer._event = lambda *_args, **_kwargs: None

        evidence = trainer._enforce_teacher_retention()
        assert evidence is not None
        self.assertTrue(evidence["passed"])
        self.assertLessEqual(evidence["final"]["total_loss"], 1.1)
        self.assertGreater(evidence["selected_learner_fraction"], 0.049)
        self.assertLess(evidence["selected_learner_fraction"], 0.051)
        self.assertEqual(trainer.learner.global_step, 37)

    def test_pause_resume_and_cancel_control_are_cooperative(self):
        with tempfile.TemporaryDirectory() as directory:
            states: list[str] = []
            control = RunControlV3(directory, status_callback=states.append)
            control.pause_path.write_text("pause\n", encoding="utf-8")

            def resume() -> None:
                time.sleep(0.05)
                control.pause_path.unlink()

            worker = threading.Thread(target=resume)
            worker.start()
            control.checkpoint()
            worker.join()
            self.assertEqual(states, ["paused", "running"])
            control.cancel_path.write_text("cancel\n", encoding="utf-8")
            with self.assertRaisesRegex(TrainingCancelled, "v3_cancelled"):
                control.checkpoint()

    def test_safetensors_replay_round_trip_and_duplicate_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ReplayStoreV3(
                directory,
                capacity=10,
                byte_capacity=10_000_000,
                shard_samples=1,
            )
            sample = _sample("game-a")
            store.add(sample)
            self.assertEqual(store.verify()["samples"], 1)
            batch = store.collate(store.sample_entries(1))
            self.assertEqual(batch["state_global"].shape, (1, STATE_GLOBAL_SIZE))
            self.assertEqual(batch["candidate_refs"].shape, (1, 1, 8))
            with self.assertRaisesRegex(ValueError, "duplicate_v3_replay_sample"):
                store.add(sample)
            added, _path = store.add_if_missing(sample)
            self.assertFalse(added)

    def test_ragged_replay_corruption_seed_split_and_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            store = ReplayStoreV3(
                root / "ragged",
                capacity=3,
                byte_capacity=20_000_000,
                shard_samples=2,
            )
            first = _sample("ragged-a", candidate_count=1, game_seed=21)
            second = _sample("ragged-b", candidate_count=3, game_seed=22)
            store.add_many((first, second))
            entries = store.entries(split="all")
            batch = store.collate(entries)
            self.assertEqual(batch["candidate_numeric"].shape[:2], (2, 3))
            self.assertEqual(batch["candidate_mask"].sum(axis=1).tolist(), [1, 3])
            self.assertEqual(
                first.validation_split,
                _sample("same-seed", game_seed=21).validation_split,
            )
            manifest = store.manifest
            self.assertRegex(manifest["core_fingerprint"], r"^[0-9a-f]{64}$")
            self.assertRegex(manifest["card_fingerprint"], r"^[0-9a-f]{64}$")
            shard = manifest["shards"][0]
            self.assertEqual(shard["game_seeds"], [21, 22])
            self.assertEqual(shard["model_versions"], [1])
            self.assertEqual(shard["sources"], ["self_play"])

            shard_path = store.root / shard["path"]
            wire = bytearray(shard_path.read_bytes())
            wire[-1] ^= 1
            shard_path.write_bytes(wire)
            with self.assertRaisesRegex(ValueError, "shard_hash_mismatch"):
                store.verify()

        with tempfile.TemporaryDirectory() as directory:
            store = ReplayStoreV3(
                directory,
                capacity=2,
                byte_capacity=20_000_000,
                shard_samples=1,
            )
            store.add(_sample("teacher-fixed", "teacher"))
            store.add(_sample("self-old", cycle=1, model_version=1))
            store.add(_sample("self-new", cycle=3, model_version=3))
            store.flush()
            self.assertEqual(store.verify()["samples"], 2)
            self.assertTrue(any(row["teacher"] for row in store.manifest["shards"]))
            self.assertTrue(
                any(3 in row["model_versions"] for row in store.manifest["shards"])
            )

    def test_concurrent_replay_publication_and_worker_manifests(self):
        with tempfile.TemporaryDirectory() as directory:
            replay_root = Path(directory) / "replay"

            def publish(index: int) -> None:
                store = ReplayStoreV3(
                    replay_root,
                    capacity=20,
                    byte_capacity=50_000_000,
                    shard_samples=1,
                )
                store.add(_sample(f"concurrent-{index}"))
                store.flush()

            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(publish, range(8)))
            store = ReplayStoreV3(
                replay_root,
                capacity=20,
                byte_capacity=50_000_000,
                shard_samples=1,
            )
            self.assertEqual(store.verify()["samples"], 8)

            exchange = AtomicWorkerExchangeV3(Path(directory) / "workers")
            exchange.publish_task(
                "task-001",
                run_id="run-001",
                games=[{"game_id": "game-001", "seed": 17}],
            )
            claim = exchange.claim("worker-a")
            self.assertIsNotNone(claim)
            assert claim is not None
            self.assertIsNone(exchange.claim("worker-b"))
            exchange.publish_result(
                claim[0],
                worker_id="worker-a",
                games=[{"game_id": "game-001", "success": True}],
                replay_shards=store.manifest["shards"][:1],
            )
            results = exchange.read_results()
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["task_id"], "task-001")

            worker_replay = ReplayStoreV3(
                Path(directory) / "worker-replay",
                capacity=10,
                byte_capacity=20_000_000,
                shard_samples=1,
            )
            worker_replay.add(_sample("remote-worker-game"))
            worker_replay.flush()
            merged = ReplayStoreV3(
                Path(directory) / "merged-replay",
                capacity=10,
                byte_capacity=20_000_000,
                shard_samples=1,
            )
            self.assertEqual(merged.import_worker(worker_replay)["samples"], 1)
            self.assertEqual(merged.verify()["samples"], 1)

    def test_checkpoint_restores_optimizer_and_replay_rng(self):
        import torch

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            store = ReplayStoreV3(
                root / "replay",
                capacity=10,
                byte_capacity=20_000_000,
                shard_samples=1,
                seed=23,
            )
            store.add(_sample("teacher", "teacher"))
            store.add(_sample("self-play"))
            config = LearnerConfigV3(
                device="cpu",
                batch_size=2,
                optimizer_warmup_steps=1,
                schedule_total_steps=10,
                prefetch_batches=1,
                seed=31,
            )
            learner = DeepLearnerV3(store, root / "checkpoints", config=config)
            learner.train_steps(1)
            learner.save_checkpoint()
            expected_draw = [
                (row.path.name, row.local_index)
                for row in store.sample_entries(2)
            ]
            learner.load_latest()
            learner.train_steps(1)
            expected = {
                key: value.detach().clone()
                for key, value in learner.model.state_dict().items()
            }

            resumed_store = ReplayStoreV3(
                root / "replay",
                capacity=10,
                byte_capacity=20_000_000,
                shard_samples=1,
                seed=23,
            )
            resumed = DeepLearnerV3(
                resumed_store,
                root / "checkpoints",
                config=config,
            )
            resumed.load_latest()
            actual_draw = [
                (row.path.name, row.local_index)
                for row in resumed_store.sample_entries(2)
            ]
            self.assertEqual(actual_draw, expected_draw)
            resumed.load_latest()
            resumed.train_steps(1)
            self.assertEqual(resumed.global_step, 2)
            for key, value in resumed.model.state_dict().items():
                torch.testing.assert_close(value, expected[key], rtol=0, atol=0)


class NativeActorV3Tests(unittest.TestCase):
    def test_native_actor_crosses_action_and_choice_roots_without_bridge(self):
        try:
            import ptcg_ai_core  # noqa: F401
            import torch
        except ImportError:
            self.skipTest("native binding or torch unavailable")
        if not hasattr(ptcg_ai_core, "NativeActorPoolV3"):
            self.skipTest("v3 native actor unavailable")
        from engine.ai.dl.actor_v3 import (
            ActorConfigV3,
            GameTaskV3,
            NativeActorServiceV3,
        )

        class ZeroModel(torch.nn.Module):
            def forward(self, *inputs):
                batch, candidates = inputs[5].shape[:2]
                return (
                    torch.zeros((batch, candidates), device=inputs[5].device),
                    torch.zeros((batch, 3), device=inputs[5].device),
                )

        config = ActorConfigV3(
            concurrent_games=1,
            search_slots=1,
            simulations=2,
            max_depth=8,
            max_inflight_leaves=2,
            inference_target_batch=2,
            inference_max_batch=4,
            strict=False,
        )
        with NativeActorServiceV3({0: ZeroModel()}, device="cpu", config=config) as service:
            result = service.run([
                GameTaskV3(
                    "v3-native-continuous-smoke",
                    0,
                    "fire",
                    "water",
                    173,
                    0,
                    0,
                    max_decisions=32,
                )
            ])
        game = result["games"][0]
        self.assertEqual(game["error"], "v3_actor_decision_cap")
        self.assertGreater(game["decisions"], 20)
        self.assertNotIn("continuation", game["error"])
        self.assertEqual(result["inference"]["inference_requests"], game["simulations"])


if __name__ == "__main__":
    unittest.main()

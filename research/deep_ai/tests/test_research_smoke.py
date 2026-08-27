from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np

from deep_ai.encoder_v3 import InformationSetEncoderV8
from deep_ai.learner_v3 import DeepLearnerV3, LearnerConfigV3
from deep_ai.model_v3 import create_model
from deep_ai.replay_v3 import ReplaySampleV3, ReplayStoreV3
from deep_ai.teacher_v3 import TeacherTaskV3, _challenge_ai, setup_teacher_game
from deep_ai.v3_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
    ONNX_INPUT_NAMES,
    ONNX_OUTPUT_NAMES,
    STATE_GLOBAL_SIZE,
)
from engine.game_engine import DEFAULT_GAME_ENGINE


def _pokemon() -> dict:
    return {
        "card_id": "svi-chim",
        "damage_counters": 0,
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


def _player(own: bool) -> dict:
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
        "players": [_player(True), _player(False)],
        "public_deck_keys": ["fire", "water"],
        "pending_promotions": [],
        "turn_fact_book": {
            "previous_turn": {"knockouts": []},
            "current_turn": {"knockouts": []},
        },
        "stadium_card_id": "",
    }


def _action() -> dict:
    return {
        "schema_version": 4,
        "action_id": "research-smoke",
        "base_revision": 9,
        "actor": 0,
        "kind": "END_TURN",
        "source": None,
        "target": None,
        "payload": {},
    }


def _sample(game_id: str, source: str = "self_play") -> ReplaySampleV3:
    encoder = InformationSetEncoderV8()
    observation = _observation()
    return ReplaySampleV3(
        encoder.encode_information_set(observation),
        encoder.encode_actions(observation, [_action()]),
        np.asarray([1.0], dtype=np.float32),
        np.asarray([0.0, 1.0, 0.0], dtype=np.float32),
        game_id,
        17,
        0,
        0,
        0,
        1,
        1,
        1,
        0,
        source,
    )


class ResearchSmokeTests(unittest.TestCase):
    def test_shared_challenge_teacher_returns_a_legal_action(self) -> None:
        task = TeacherTaskV3("smoke", 0, "fire", "water", 17, 0, 0)
        state = setup_teacher_game(task)
        actor = int(state.active_player_idx)
        teacher = _challenge_ai(str(state.public_deck_keys[actor]), 48, {})
        action = teacher.choose_action(state, actor)
        legal = DEFAULT_GAME_ENGINE.legal_actions(state, actor)
        self.assertIn(action.signature, {row.signature for row in legal})
        self.assertTrue(teacher._controller.get_contract()["callback_free"])

    def test_replay_round_trip_and_one_training_step(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            replay = ReplayStoreV3(
                root / "replay",
                capacity=8,
                byte_capacity=20_000_000,
                shard_samples=1,
                seed=17,
            )
            replay.add(_sample("teacher-smoke", "teacher"))
            replay.add(_sample("self-play-smoke"))
            replay.flush()
            self.assertEqual(replay.verify()["samples"], 2)
            reopened = ReplayStoreV3(
                root / "replay",
                capacity=8,
                byte_capacity=20_000_000,
                shard_samples=1,
                seed=17,
            )
            learner = DeepLearnerV3(
                reopened,
                root / "checkpoints",
                config=LearnerConfigV3(
                    device="cpu",
                    batch_size=2,
                    optimizer_warmup_steps=1,
                    schedule_total_steps=2,
                    prefetch_batches=1,
                    seed=17,
                ),
            )
            metrics = learner.train_steps(1)
            self.assertEqual(learner.global_step, 1)
            self.assertTrue(np.isfinite(float(metrics["policy_loss"])))
            self.assertTrue(np.isfinite(float(metrics["wdl_loss"])))

    def test_onnx_export_matches_torch(self) -> None:
        import onnxruntime as ort
        import torch

        model = create_model().eval()
        batch, candidates = 1, 2
        inputs = (
            torch.zeros(batch, STATE_GLOBAL_SIZE),
            torch.zeros(batch, ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
            torch.zeros(batch, ENTITY_SLOTS, dtype=torch.long),
            torch.zeros(batch, ENTITY_SLOTS, ENTITY_TYPE_FIELDS, dtype=torch.long),
            torch.ones(batch, ENTITY_SLOTS, dtype=torch.bool),
            torch.zeros(batch, candidates, CANDIDATE_NUMERIC_SIZE),
            torch.zeros(batch, candidates, dtype=torch.long),
            torch.ones(batch, candidates, dtype=torch.long),
            torch.zeros(batch, candidates, CANDIDATE_REF_FIELDS, dtype=torch.long),
            torch.ones(batch, candidates, dtype=torch.bool),
            torch.zeros(batch, dtype=torch.long),
            torch.ones(batch, dtype=torch.long),
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "smoke.onnx"
            torch.onnx.export(
                model,
                inputs,
                str(output),
                input_names=list(ONNX_INPUT_NAMES),
                output_names=list(ONNX_OUTPUT_NAMES),
                opset_version=17,
            )
            session = ort.InferenceSession(
                str(output), providers=["CPUExecutionProvider"]
            )
            actual = session.run(
                list(ONNX_OUTPUT_NAMES),
                {
                    name: value.detach().cpu().numpy()
                    for name, value in zip(ONNX_INPUT_NAMES, inputs, strict=True)
                },
            )
            with torch.inference_mode():
                expected = [value.detach().cpu().numpy() for value in model(*inputs)]
            for left, right in zip(expected, actual, strict=True):
                np.testing.assert_allclose(left, right, rtol=1e-4, atol=1e-4)


if __name__ == "__main__":
    unittest.main()

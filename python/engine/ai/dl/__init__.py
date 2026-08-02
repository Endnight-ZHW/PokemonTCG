"""Universal information-set AlphaZero v2 Deep AI.

The package facade is intentionally lazy. Challenge teacher subprocesses
import modules below this package but do not need PyTorch or the runtime
controller; eagerly importing them reserved more than 1 GB per worker.
"""
from __future__ import annotations

from typing import Any


def __getattr__(name: str) -> Any:
    if name in {
        "CHECKPOINT_VERSION",
        "DEEP_PLANNER_VERSION",
        "ENCODER_SCHEMA_VERSION",
        "MODEL_VARIANT",
    }:
        from engine.ai.dl import v2_contract

        return getattr(v2_contract, name)
    if name in {
        "EncodedCandidates",
        "EncodedDecision",
        "EncodedInformationSet",
        "InformationSetEncoderV7",
    }:
        from engine.ai.dl import infoset_encoder

        return getattr(infoset_encoder, name)
    if name in {
        "TORCH_AVAILABLE",
        "UniversalInformationSetModel",
    }:
        from engine.ai.dl import model_v2

        return getattr(model_v2, name)
    if name == "NativeBatchTorchBroker":
        from engine.ai.dl.inference_v2 import NativeBatchTorchBroker

        return NativeBatchTorchBroker
    if name in {
        "NativeBridgeError",
        "NativeModelBackend",
        "NativeSearchService",
        "game_state_to_native_wire",
        "mask_native_snapshot",
        "native_training_bridge_available",
    }:
        from engine.ai.dl import native_bridge_v2

        return getattr(native_bridge_v2, name)
    if name in {
        "DeepLearningAI",
        "DeepLearningAIConfig",
        "is_deep_model_accepted",
    }:
        from engine.ai.dl import controller

        return getattr(controller, name)
    raise AttributeError(name)


__all__ = [
    "CHECKPOINT_VERSION",
    "DEEP_PLANNER_VERSION",
    "DeepLearningAI",
    "DeepLearningAIConfig",
    "ENCODER_SCHEMA_VERSION",
    "EncodedCandidates",
    "EncodedDecision",
    "EncodedInformationSet",
    "InformationSetEncoderV7",
    "MODEL_VARIANT",
    "NativeBatchTorchBroker",
    "NativeBridgeError",
    "NativeModelBackend",
    "NativeSearchService",
    "game_state_to_native_wire",
    "mask_native_snapshot",
    "native_training_bridge_available",
    "TORCH_AVAILABLE",
    "UniversalInformationSetModel",
    "is_deep_model_accepted",
]

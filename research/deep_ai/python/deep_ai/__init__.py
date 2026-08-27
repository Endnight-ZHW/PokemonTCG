"""Lazy public facade for Universal information-set Deep AI v3."""
from __future__ import annotations

from typing import Any


def __getattr__(name: str) -> Any:
    if name in {
        "CHECKPOINT_VERSION",
        "DEEP_PLANNER_VERSION",
        "ENCODER_SCHEMA_VERSION",
        "MODEL_VARIANT",
    }:
        from . import v3_contract

        return getattr(v3_contract, name)
    if name in {
        "EncodedCandidatesV3",
        "EncodedInformationSetV3",
        "InformationSetEncoderV8",
    }:
        from . import encoder_v3

        return getattr(encoder_v3, name)
    if name in {
        "TORCH_AVAILABLE",
        "UniversalInformationSetModelV3",
    }:
        from . import model_v3

        return getattr(model_v3, name)
    if name in {"ActorConfigV3", "GameTaskV3", "NativeActorServiceV3"}:
        from . import actor_v3

        return getattr(actor_v3, name)
    if name == "AtomicWorkerExchangeV3":
        from .worker_v3 import AtomicWorkerExchangeV3

        return AtomicWorkerExchangeV3
    raise AttributeError(name)


__all__ = [
    "CHECKPOINT_VERSION",
    "DEEP_PLANNER_VERSION",
    "ENCODER_SCHEMA_VERSION",
    "EncodedCandidatesV3",
    "EncodedInformationSetV3",
    "InformationSetEncoderV8",
    "MODEL_VARIANT",
    "NativeActorServiceV3",
    "ActorConfigV3",
    "AtomicWorkerExchangeV3",
    "GameTaskV3",
    "TORCH_AVAILABLE",
    "UniversalInformationSetModelV3",
]

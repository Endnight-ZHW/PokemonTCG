"""Challenge-mode AI public API with lazy Deep runtime imports."""
from __future__ import annotations

from typing import Any

from engine.ai.challenge_ai import (
    AIAction,
    AIConfig,
    ChallengeAI,
    create_challenge_ai,
)
from engine.ai.profiles import DECK_AI_PROFILES, DeckAIProfile


AI_KIND_CHALLENGE = "challenge"
AI_KIND_DEEP_LEARNING = "deep_learning"


def create_ai_controller(
    kind: str | None,
    deck_key: str | None,
    config: Any = None,
):
    # Importing the factory loads the optional PyTorch runtime. Keep Challenge
    # teacher processes lightweight until a caller actually requests a
    # controller through the mixed Challenge/Deep factory.
    from engine.ai.factory import create_ai_controller as create

    return create(kind, deck_key, config)


def __getattr__(name: str) -> Any:
    if name in {
        "DeepLearningAI",
        "DeepLearningAIConfig",
        "TORCH_AVAILABLE",
    }:
        from engine.ai.dl import (
            DeepLearningAI,
            DeepLearningAIConfig,
            TORCH_AVAILABLE,
        )

        values = {
            "DeepLearningAI": DeepLearningAI,
            "DeepLearningAIConfig": DeepLearningAIConfig,
            "TORCH_AVAILABLE": TORCH_AVAILABLE,
        }
        return values[name]
    raise AttributeError(name)


__all__ = [
    "AI_KIND_CHALLENGE",
    "AI_KIND_DEEP_LEARNING",
    "AIAction",
    "AIConfig",
    "ChallengeAI",
    "DeepLearningAI",
    "DeepLearningAIConfig",
    "DeckAIProfile",
    "DECK_AI_PROFILES",
    "TORCH_AVAILABLE",
    "create_ai_controller",
    "create_challenge_ai",
]

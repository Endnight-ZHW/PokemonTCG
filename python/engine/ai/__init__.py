"""Challenge-mode AI public API."""
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
    from engine.ai.factory import create_ai_controller as create

    return create(kind, deck_key, config)


__all__ = [
    "AI_KIND_CHALLENGE",
    "AI_KIND_DEEP_LEARNING",
    "AIAction",
    "AIConfig",
    "ChallengeAI",
    "DeckAIProfile",
    "DECK_AI_PROFILES",
    "create_ai_controller",
    "create_challenge_ai",
]

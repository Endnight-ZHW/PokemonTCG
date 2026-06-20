"""AI controller factory for challenge mode."""
from __future__ import annotations

from typing import Any

from engine.ai.challenge_ai import AIConfig, create_challenge_ai
from engine.ai.dl.controller import DeepLearningAI, DeepLearningAIConfig


AI_KIND_CHALLENGE = "challenge"
AI_KIND_DEEP_LEARNING = "deep_learning"


def create_ai_controller(kind: str | None, deck_key: str | None, config: Any = None):
    """Create an AI controller without changing existing ChallengeAI semantics."""
    normalized = (kind or AI_KIND_CHALLENGE).lower()
    if normalized in ("challenge", "rules", "rule", "search"):
        challenge_config = (
            config
            if isinstance(config, AIConfig)
            else AIConfig(use_unified_planner=True)
        )
        return create_challenge_ai(deck_key or "", challenge_config)
    if normalized in ("deep_learning", "deep", "dl"):
        if isinstance(config, DeepLearningAIConfig):
            dl_config = config
        elif isinstance(config, AIConfig):
            dl_config = DeepLearningAIConfig(fallback_config=config)
        else:
            dl_config = None
        return DeepLearningAI(deck_key, dl_config)
    raise ValueError(f"Unknown AI controller kind: {kind}")

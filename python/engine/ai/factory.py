"""AI controller factory for challenge mode."""
from __future__ import annotations

from typing import Any

from engine.ai.challenge_ai import AIConfig, create_challenge_ai


AI_KIND_CHALLENGE = "challenge"
AI_KIND_DEEP_LEARNING = "deep_learning"


def create_ai_controller(kind: str | None, deck_key: str | None, config: Any = None):
    """Create the Python rules AI.

    The released neural runtime lives in Godot/native.  Python callers that
    request Deep AI therefore receive the same explicit Challenge fallback as
    a runtime with no accepted model.
    """
    normalized = (kind or AI_KIND_CHALLENGE).lower()
    if normalized in (
        "challenge",
        "rules",
        "rule",
        "search",
        "deep_learning",
        "deep",
        "dl",
    ):
        challenge_config = (
            config
            if isinstance(config, AIConfig)
            else AIConfig(use_unified_planner=True)
        )
        return create_challenge_ai(deck_key or "", challenge_config)
    raise ValueError(f"Unknown AI controller kind: {kind}")

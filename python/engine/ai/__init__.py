"""Challenge-mode AI public API."""

from engine.ai.challenge_ai import AIAction, AIChoice, AIConfig, ChallengeAI, create_challenge_ai
from engine.ai.dl import DeepLearningAI, DeepLearningAIConfig, TORCH_AVAILABLE
from engine.ai.factory import AI_KIND_CHALLENGE, AI_KIND_DEEP_LEARNING, create_ai_controller
from engine.ai.profiles import DECK_AI_PROFILES, DeckAIProfile

__all__ = [
    "AI_KIND_CHALLENGE",
    "AI_KIND_DEEP_LEARNING",
    "AIAction",
    "AIChoice",
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

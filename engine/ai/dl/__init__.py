"""Optional deep-learning AI backend.

This package is intentionally importable without PyTorch.  The runtime game can
construct DeepLearningAI and fall back to ChallengeAI when no model/runtime is
available, while training scripts can require torch explicitly.
"""

from engine.ai.dl.controller import DeepLearningAI, DeepLearningAIConfig
from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
    ActionStateEncoder,
    EncodedAction,
    EncodedState,
)
from engine.ai.dl.model import TORCH_AVAILABLE

__all__ = [
    "ACTION_NUMERIC_SIZE",
    "STATE_CARD_SLOTS",
    "STATE_NUMERIC_SIZE",
    "ActionStateEncoder",
    "DeepLearningAI",
    "DeepLearningAIConfig",
    "EncodedAction",
    "EncodedState",
    "TORCH_AVAILABLE",
]

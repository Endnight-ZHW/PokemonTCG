"""Runtime controller for the optional deep-learning AI."""
from __future__ import annotations

import os
import random
from dataclasses import dataclass
from typing import Any

from engine.ai.challenge_ai import AIAction, AIConfig, ChallengeAI, create_challenge_ai
from engine.ai.dl.encoder import ActionStateEncoder
from engine.ai.dl.model import TORCH_AVAILABLE, load_checkpoint, torch
from engine.enums import PlayerAction, TurnPhase
from utils.logger import get_logger

_logger = get_logger(__name__)


DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")


@dataclass(frozen=True)
class DeepLearningAIConfig:
    model_path: str | None = None
    device: str = "cpu"
    temperature: float = 0.85
    deterministic: bool = False
    fallback_enabled: bool = True
    random_seed: int = 17
    fallback_config: AIConfig | None = None


class DeepLearningAI:
    """Legal-action scorer backed by a torch model with ChallengeAI fallback."""

    def __init__(self, deck_key: str | None = None, config: DeepLearningAIConfig | None = None):
        self.deck_key = deck_key
        self.config = config or DeepLearningAIConfig()
        fallback_config = self.config.fallback_config or AIConfig()
        self.fallback: ChallengeAI = create_challenge_ai(deck_key or "", fallback_config)
        self.encoder = ActionStateEncoder()
        self.random = random.Random(self.config.random_seed)
        self.model = None
        self.model_metadata: dict[str, Any] = {}
        self._load_model()

    @property
    def model_available(self) -> bool:
        return self.model is not None and TORCH_AVAILABLE

    def choose_action(self, state, player_idx: int) -> AIAction:
        if not self.model_available:
            return self._fallback_action(state, player_idx)

        actions = self.fallback.legal_actions(state, player_idx)
        if not actions:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)
        if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
            return self._fallback_action(state, player_idx)

        try:
            return self._choose_with_model(state, player_idx, actions)
        except Exception as exc:
            _logger.debug("deep-learning action selection failed, falling back: %s", exc)
            return self._fallback_action(state, player_idx)

    def resolve_pending_action(self, state, action_request):
        # First version keeps complex effect choices on the proven ChallengeAI policy.
        return self.fallback.resolve_pending_action(state, action_request)

    def apply_choice(self, state, action_request, choice=None):
        return self.fallback.apply_choice(state, action_request, choice)

    def legal_actions(self, state, player_idx: int) -> list[AIAction]:
        return self.fallback.legal_actions(state, player_idx)

    def _fallback_action(self, state, player_idx: int) -> AIAction:
        if self.config.fallback_enabled:
            return self.fallback.choose_action(state, player_idx)
        return AIAction(PlayerAction.END_TURN, {}, terminal=True)

    def _choose_with_model(self, state, player_idx: int, actions: list[AIAction]) -> AIAction:
        assert torch is not None
        encoded_state = self.encoder.encode_state(state, player_idx, self.deck_key)
        encoded_actions = [self.encoder.encode_action(state, player_idx, action) for action in actions]

        device = self.config.device
        with torch.no_grad():
            state_numeric = torch.tensor([encoded_state.numeric], dtype=torch.float32, device=device)
            state_cards = torch.tensor([encoded_state.card_ids], dtype=torch.long, device=device)
            action_numeric = torch.tensor([[a.numeric for a in encoded_actions]], dtype=torch.float32, device=device)
            action_cards = torch.tensor([[a.card_id for a in encoded_actions]], dtype=torch.long, device=device)
            logits, _ = self.model(state_numeric, state_cards, action_numeric, action_cards)
            logits = logits[0]
            temperature = max(0.05, float(self.config.temperature))
            if self.config.deterministic:
                idx = int(torch.argmax(logits).item())
            else:
                probs = torch.softmax(logits / temperature, dim=0)
                idx = int(torch.multinomial(probs, 1).item())
        return actions[max(0, min(idx, len(actions) - 1))]

    def _load_model(self) -> None:
        if not TORCH_AVAILABLE:
            return
        path = self.config.model_path or self._default_model_path()
        if not path or not os.path.exists(path):
            return
        try:
            self.model, payload = load_checkpoint(path, self.config.device)
            self.model_metadata = dict(payload.get("metadata") or {})
        except Exception as exc:
            _logger.warning("failed to load deep-learning AI model %s: %s", path, exc)
            self.model = None
            self.model_metadata = {}

    def _default_model_path(self) -> str:
        if self.deck_key:
            deck_path = os.path.join(DEFAULT_MODEL_DIR, f"{self.deck_key}.pt")
            if os.path.exists(deck_path):
                return deck_path
        return os.path.join(DEFAULT_MODEL_DIR, "default.pt")

"""Runtime controller for the optional deep-learning AI."""
from __future__ import annotations

import os
import random
from dataclasses import dataclass
from typing import Any

from engine.ai.challenge_ai import AIAction, AIChoice, AIConfig, ChallengeAI, create_challenge_ai
from engine.ai.dl.encoder import ActionStateEncoder
from engine.ai.dl.model import TORCH_AVAILABLE, load_checkpoint, torch
from engine.enums import PlayerAction, TurnPhase
from utils.logger import get_logger

_logger = get_logger(__name__)


DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")


def _fit_sequence(values: list, size: int, pad):
    if len(values) >= size:
        return values[:size]
    return values + [pad] * (size - len(values))


@dataclass(frozen=True)
class DeepLearningAIConfig:
    model_path: str | None = None
    device: str = "cpu"
    temperature: float = 0.35
    deterministic: bool = True
    fallback_enabled: bool = True
    random_seed: int = 17
    fallback_config: AIConfig | None = None
    choice_confidence_threshold: float = 0.30


class DeepLearningAI:
    """Legal-action scorer backed by a torch model with ChallengeAI fallback."""

    def __init__(self, deck_key: str | None = None, config: DeepLearningAIConfig | None = None):
        self.deck_key = deck_key
        self.config = config or DeepLearningAIConfig()
        fallback_config = self.config.fallback_config or AIConfig(
            thinking_time_seconds=0.0,
            deterministic_search=True,
            max_sequence_depth=3,
            max_turn_actions=128,
        )
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
        if self.model_available and bool(getattr(self.model, "choice_head_enabled", False)):
            try:
                choice = self._choose_pending_with_model(state, action_request)
                if choice is not None:
                    return choice
            except Exception as exc:
                _logger.debug("deep-learning pending choice failed, falling back: %s", exc)
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
        state_numeric_size = int(getattr(self.model, "state_numeric_size", len(encoded_state.numeric)))
        state_card_slots = int(getattr(self.model, "state_card_slots", len(encoded_state.card_ids)))
        action_numeric_size = int(getattr(self.model, "action_numeric_size", len(encoded_actions[0].numeric)))
        with torch.no_grad():
            state_numeric = torch.tensor(
                [_fit_sequence(encoded_state.numeric, state_numeric_size, 0.0)],
                dtype=torch.float32,
                device=device,
            )
            state_cards = torch.tensor(
                [_fit_sequence(encoded_state.card_ids, state_card_slots, 0)],
                dtype=torch.long,
                device=device,
            )
            action_numeric = torch.tensor(
                [[_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in encoded_actions]],
                dtype=torch.float32,
                device=device,
            )
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

    def _pending_choice_candidates(self, state, req) -> tuple[list[Any], str] | None:
        request_type = getattr(req, "request_type", "")
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        if request_type in ("search_deck", "select_hand_to_discard"):
            candidates = list(getattr(req, "card_list", []) or [])
            return (candidates, request_type) if candidates else None
        if request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            target_player = state.get_player(1 - player_idx) if request_type == "select_opponent_bench" else state.get_player(player_idx)
            candidates = [
                idx for idx in range(len(target_player.bench))
                if target_player.bench[idx] is not None
            ]
            return (candidates, request_type) if candidates else None
        if request_type == "select_bench_targets":
            target_player = state.get_player(1 - player_idx) if getattr(req, "target_player", "") == "opponent" else state.get_player(player_idx)
            candidates = [
                idx for idx in (getattr(req, "bench_indices", None) or range(len(target_player.bench)))
                if 0 <= idx < len(target_player.bench) and target_player.bench[idx] is not None
            ]
            return (candidates, request_type) if candidates else None
        if request_type == "confirm":
            return [True, False], request_type
        return None

    def _choose_pending_with_model(self, state, req) -> AIChoice | None:
        assert torch is not None
        candidate_info = self._pending_choice_candidates(state, req)
        if candidate_info is None:
            return None
        candidates, request_type = candidate_info
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        encoded_state = self.encoder.encode_state(state, player_idx, self.deck_key)
        encoded_choices = [
            self.encoder.encode_choice(state, player_idx, request_type, candidate, idx)
            for idx, candidate in enumerate(candidates)
        ]
        if not encoded_choices:
            return None

        device = self.config.device
        state_numeric_size = int(getattr(self.model, "state_numeric_size", len(encoded_state.numeric)))
        state_card_slots = int(getattr(self.model, "state_card_slots", len(encoded_state.card_ids)))
        action_numeric_size = int(getattr(self.model, "action_numeric_size", len(encoded_choices[0].numeric)))
        with torch.no_grad():
            state_numeric = torch.tensor(
                [_fit_sequence(encoded_state.numeric, state_numeric_size, 0.0)],
                dtype=torch.float32,
                device=device,
            )
            state_cards = torch.tensor(
                [_fit_sequence(encoded_state.card_ids, state_card_slots, 0)],
                dtype=torch.long,
                device=device,
            )
            choice_numeric = torch.tensor(
                [[_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in encoded_choices]],
                dtype=torch.float32,
                device=device,
            )
            choice_cards = torch.tensor([[a.card_id for a in encoded_choices]], dtype=torch.long, device=device)
            if hasattr(self.model, "score_choices"):
                logits = self.model.score_choices(state_numeric, state_cards, choice_numeric, choice_cards)
            else:
                logits, _ = self.model(state_numeric, state_cards, choice_numeric, choice_cards)
            probs = torch.softmax(logits[0] / max(0.05, float(self.config.temperature)), dim=0)
            ranked = torch.argsort(probs, descending=True).detach().cpu().tolist()
            confidence = float(probs[ranked[0]].detach().cpu().item()) if ranked else 0.0
        if confidence < float(self.config.choice_confidence_threshold):
            return None

        if request_type in ("search_deck", "select_hand_to_discard"):
            count = max(req.min_select, min(req.max_select, len(candidates)))
            return AIChoice(selected_cards=[candidates[idx] for idx in ranked[:count]])
        if request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            return AIChoice(selected_bench_slot=int(candidates[ranked[0]]))
        if request_type == "select_bench_targets":
            count = max(req.min_select, min(req.max_select, len(candidates)))
            return AIChoice(selected_bench_targets=[int(candidates[idx]) for idx in ranked[:count]])
        if request_type == "confirm":
            return AIChoice(confirmed=bool(candidates[ranked[0]]))
        return None

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

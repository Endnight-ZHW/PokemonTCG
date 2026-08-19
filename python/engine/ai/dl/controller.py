"""Runtime controller for the universal AlphaZero v2 model."""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from typing import Any

from engine.actions import ChoiceResponse, GameAction
from engine.ai.challenge_ai import AIConfig, ChallengeAI, create_challenge_ai
from engine.ai.dl.inference_v2 import BatchedTorchEvaluator
from engine.ai.dl.model_v2 import (
    TORCH_AVAILABLE,
    load_checkpoint,
)
from engine.ai.dl.puct_v2 import InformationSetPUCT, PythonGameEnvironment
from engine.enums import PlayerAction
from engine.snapshot import clone_state
from utils.logger import get_logger

from .v2_contract import (
    CHECKPOINT_VERSION,
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    MODEL_VARIANT,
    RELEASE_DECKS,
)


_logger = get_logger(__name__)
DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")


@dataclass(frozen=True)
class DeepLearningAIConfig:
    model_path: str | None = None
    device: str = "cpu"
    temperature: float = 0.0
    deterministic: bool = True
    fallback_enabled: bool = True
    random_seed: int = 17
    fallback_config: AIConfig | None = None
    mcts_simulations: int = 128
    mcts_c_puct: float = 1.4
    max_thinking_time_seconds: float = 2.0


def _universal_paths(model_dir: str) -> tuple[str, str]:
    checkpoint = os.path.join(model_dir, "universal.pt")
    return checkpoint, os.path.splitext(checkpoint)[0] + ".json"


def _release_gate_is_satisfied(metadata: dict[str, Any]) -> bool:
    final = metadata.get("final_league")
    if not isinstance(final, dict):
        final = (metadata.get("summary") or {}).get("final_league")
    if not isinstance(final, dict):
        return False
    deck_rates = final.get("deck_score_rates")
    return (
        bool(metadata.get("accepted"))
        and metadata.get("verification_status") == "verified_accepted"
        and str(metadata.get("model_variant")) == MODEL_VARIANT
        and int(metadata.get("encoder_version") or 0)
        == ENCODER_SCHEMA_VERSION
        and int(metadata.get("checkpoint_version") or 0)
        == CHECKPOINT_VERSION
        and int(metadata.get("planner_version") or 0)
        == DEEP_PLANNER_VERSION
        and float(final.get("overall_score_rate") or 0.0) >= 0.53
        and isinstance(deck_rates, dict)
        and all(
            float(deck_rates.get(deck) or 0.0) >= 0.50
            for deck in RELEASE_DECKS
        )
        and int(final.get("structural_errors") or 0) == 0
    )


def is_deep_model_accepted(
    deck_key: str | None,
    model_dir: str = DEFAULT_MODEL_DIR,
) -> bool:
    if deck_key not in RELEASE_DECKS:
        return False
    checkpoint, sidecar = _universal_paths(model_dir)
    if not os.path.isfile(checkpoint) or os.path.getsize(checkpoint) <= 0:
        return False
    try:
        with open(sidecar, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError, TypeError):
        return False
    metadata = payload.get("metadata") if isinstance(payload, dict) else None
    return isinstance(metadata, dict) and _release_gate_is_satisfied(metadata)


class DeepLearningAI:
    """AlphaZero v2 search with a structured Challenge fallback."""

    def __init__(
        self,
        deck_key: str | None = None,
        config: DeepLearningAIConfig | None = None,
    ) -> None:
        self.deck_key = deck_key
        self.config = config or DeepLearningAIConfig()
        fallback_config = self.config.fallback_config or AIConfig(
            deck_key=deck_key or "",
            random_seed=self.config.random_seed,
            use_unified_planner=True,
        )
        self.fallback: ChallengeAI = create_challenge_ai(
            deck_key or "",
            fallback_config,
        )
        self.model = None
        self.model_metadata: dict[str, Any] = {}
        self._evaluator: BatchedTorchEvaluator | None = None
        self._active_search: InformationSetPUCT | None = None
        self._load_model()

    @property
    def model_available(self) -> bool:
        return (
            TORCH_AVAILABLE
            and self.model is not None
            and self._evaluator is not None
        )

    def choose_action(self, state: Any, player_idx: int) -> GameAction:
        if not self.model_available:
            return self._fallback_action(state, player_idx)
        authoritative = list(self.fallback.legal_actions(state, player_idx))
        if not authoritative:
            return GameAction(
                PlayerAction.END_TURN,
                {},
                True,
                player_idx,
            )
        environment = PythonGameEnvironment()
        search = InformationSetPUCT(
            self._evaluator,
            environment,
            simulations=max(1, int(self.config.mcts_simulations)),
            c_puct=float(self.config.mcts_c_puct),
            training=not self.config.deterministic,
            seed=self.config.random_seed + int(getattr(state, "revision", 0)),
        )
        self._active_search = search
        try:
            deadline = time.perf_counter() + max(
                0.05,
                float(self.config.max_thinking_time_seconds) - 0.05,
            )
            result = search.search(
                state,
                player_idx,
                deadline=deadline,
                min_simulations=1,
                temperature=(
                    0.0
                    if self.config.deterministic
                    else self.config.temperature
                ),
            )
        except Exception as exc:
            _logger.debug("AlphaZero v2 search fallback: %s", exc)
            return self._fallback_action(state, player_idx)
        finally:
            self._active_search = None
        selected = result.selected.payload
        if not isinstance(selected, GameAction):
            return self._fallback_action(state, player_idx)
        action = next(
            (
                candidate
                for candidate in authoritative
                if candidate.signature == selected.signature
            ),
            None,
        )
        if action is None or not self._executes_on_clone(
            state,
            player_idx,
            action,
        ):
            return self._fallback_action(state, player_idx)
        return action

    def resolve_pending_action(self, state: Any, action_request: Any):
        # Python's legacy UI consumes AIChoice, while the v2 tree operates on
        # ChoiceResponse. Keep the authoritative Challenge codec at this UI
        # boundary; self-play and Godot runtime search choices natively.
        return self.fallback.resolve_pending_action(state, action_request)

    def apply_choice(self, state: Any, action_request: Any, choice: Any = None):
        return self.fallback.apply_choice(state, action_request, choice)

    def legal_actions(self, state: Any, player_idx: int):
        return self.fallback.legal_actions(state, player_idx)

    def cancel_search(self) -> None:
        self.fallback.cancel_search()
        if self._active_search is not None:
            self._active_search.cancel()

    def close(self) -> None:
        if self._evaluator is not None:
            self._evaluator.close()
            self._evaluator = None

    def _fallback_action(self, state: Any, player_idx: int) -> GameAction:
        if self.config.fallback_enabled:
            return self.fallback.choose_action(state, player_idx)
        return GameAction(PlayerAction.END_TURN, {}, True, player_idx)

    def _executes_on_clone(
        self,
        state: Any,
        player_idx: int,
        action: GameAction,
    ) -> bool:
        try:
            cloned = clone_state(state)
            result = self.fallback._apply_action_for_sim(
                cloned,
                player_idx,
                action,
            )
            return result is not None and bool(result.success)
        except Exception:
            return False

    def _load_model(self) -> None:
        if not TORCH_AVAILABLE:
            return
        path = self.config.model_path
        if path is None:
            if not is_deep_model_accepted(
                self.deck_key,
                DEFAULT_MODEL_DIR,
            ):
                return
            path = _universal_paths(DEFAULT_MODEL_DIR)[0]
        try:
            self.model, payload = load_checkpoint(
                path,
                self.config.device,
            )
            self.model_metadata = dict(payload.get("metadata") or {})
            self._evaluator = BatchedTorchEvaluator(
                self.model,
                device=self.config.device,
                target_batch_size=8,
                max_batch_size=8,
                coalesce_ms=1.0,
            )
        except Exception as exc:
            _logger.warning(
                "Unable to load universal AlphaZero v2 model: %s",
                exc,
            )
            self.model = None
            self.model_metadata = {}
            self._evaluator = None

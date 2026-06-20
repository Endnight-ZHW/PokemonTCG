"""Small coordination layers used by ChallengeAI."""
from __future__ import annotations

from typing import Any

from engine.ai.challenge.types import AIAction, AIChoice
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import ActionRequest, ActionResult, GameState


class ActionEnumerator:
    """Legal action generation layer for ChallengeAI."""

    def __init__(self, ai: Any):
        self.ai = ai

    def legal_actions(self, state: GameState, player_idx: int) -> list[AIAction]:
        return self.ai._legal_actions_impl(
            state,
            player_idx,
            list(DEFAULT_GAME_ENGINE.legal_actions(
                state,
                player_idx,
                validate_effects=False,
            )),
        )


class Simulator:
    """State transition and pending-choice resolution layer for ChallengeAI."""

    def __init__(self, ai: Any):
        self.ai = ai

    def apply_action(self, state: GameState, player_idx: int, action: AIAction) -> ActionResult | None:
        return self.ai._apply_action_for_sim_impl(state, player_idx, action)

    def apply_choice(
        self,
        state: GameState,
        action_request: ActionRequest,
        choice: AIChoice | None = None,
    ) -> ActionRequest | ActionResult | None:
        return self.ai._apply_choice_impl(state, action_request, choice)


class Evaluator:
    """Tactical state evaluation layer for ChallengeAI."""

    def __init__(self, ai: Any):
        self.ai = ai

    def evaluate_state(self, state: GameState, player_idx: int) -> float:
        return self.ai._evaluate_state_impl(state, player_idx)


class ChoicePolicy:
    """Context-aware choices for searches, discards, switches, and coin flips."""

    def __init__(self, ai: Any):
        self.ai = ai

    def resolve_pending_action(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        return self.ai._resolve_pending_action_impl(state, action_request)

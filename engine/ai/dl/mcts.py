"""Compatibility adapter from the old Deep MCTS API to the shared planner."""
from __future__ import annotations

import random
import time
from dataclasses import dataclass
from typing import Any

from engine.ai.planner import (
    AnytimePlanner,
    HeuristicBackend,
    NeuralBackend,
    PlannerConfig,
)
from engine.enums import PlayerAction


@dataclass
class _MCTSSearchResult:
    action_probs: dict[int, float]
    root_value: float
    best_action_idx: int


class MCTSGuidedSearch:
    """Legacy facade backed exclusively by the information-set PUCT planner."""

    def __init__(
        self,
        model: Any,
        encoder,
        legal_ai,
        *,
        num_simulations: int = 200,
        c_puct: float = 1.4,
        temperature: float = 1.0,
        use_chance_nodes: bool = False,
        chance_branch_limit: int = 4,
        device: str = "cpu",
        dirichlet_alpha: float = 0.3,
        dirichlet_epsilon: float = 0.25,
        add_dirichlet_noise: bool = True,
        max_depth: int = 48,
        use_unified_planner: bool = True,
    ):
        self.model = model
        self.encoder = encoder
        self.legal_ai = legal_ai
        self.num_simulations = max(1, int(num_simulations))
        self.c_puct = float(c_puct)
        self.temperature = max(0.05, float(temperature))
        self.device = device
        self.add_dirichlet_noise = bool(add_dirichlet_noise)
        self.max_depth = max(4, int(max_depth))
        self._active_planner: AnytimePlanner | None = None

    def cancel(self) -> None:
        if self._active_planner is not None:
            self._active_planner.cancel()

    def _planner(self, deck_key: str | None) -> AnytimePlanner:
        heuristic = HeuristicBackend(
            priority=self.legal_ai._quick_action_priority,
            evaluator=self.legal_ai.evaluate_state,
            choice_resolver=self.legal_ai.resolve_pending_action,
        )
        backend = NeuralBackend(
            self.model,
            self.encoder,
            self.device,
            heuristic,
            deck_key,
        )
        return AnytimePlanner(
            backend,
            PlannerConfig(
                thinking_time_seconds=8.0,
                simulation_budget=self.num_simulations,
                max_depth=self.max_depth,
                c_puct=self.c_puct,
                opponent_branch_limit=6,
                random_seed=getattr(self.legal_ai.config, "random_seed", 17),
            ),
        )

    def search(
        self,
        state,
        player_idx: int,
        deck_key: str | None = None,
        *,
        deadline: float | None = None,
        actions=None,
    ) -> _MCTSSearchResult:
        actions = list(actions or self.legal_ai.legal_actions(state, player_idx))
        if not actions:
            return _MCTSSearchResult({}, 0.0, -1)
        planner = self._planner(deck_key)
        self._active_planner = planner
        try:
            selected = planner.search(
                state,
                player_idx,
                actions=actions,
                deadline=deadline,
            )
        finally:
            self._active_planner = None

        result = planner.last_result
        visits = result.visits if result is not None else {}
        total = sum(max(0, visits.get(action.signature, 0)) for action in actions)
        if total <= 0:
            action_probs = {idx: 1.0 / len(actions) for idx in range(len(actions))}
        else:
            action_probs = {
                idx: max(0, visits.get(action.signature, 0)) / total
                for idx, action in enumerate(actions)
            }
        best_idx = next(
            (idx for idx, action in enumerate(actions) if action.signature == selected.signature),
            max(action_probs, key=action_probs.get),
        )
        root_value = 0.0
        if result is not None:
            root_value = float(result.values.get(actions[best_idx].signature, 0.0))
        return _MCTSSearchResult(action_probs, root_value, best_idx)

    def select_action(
        self,
        state,
        player_idx: int,
        deck_key: str | None = None,
        *,
        actions=None,
        deterministic: bool = True,
        deadline: float | None = None,
    ):
        actions = list(actions or self.legal_ai.legal_actions(state, player_idx))
        if not actions:
            from engine.ai.challenge_ai import AIAction

            return AIAction(PlayerAction.END_TURN, {}, terminal=True)
        result = self.search(
            state,
            player_idx,
            deck_key,
            actions=actions,
            deadline=deadline,
        )
        if deterministic:
            return actions[result.best_action_idx]
        roll = random.random()
        cumulative = 0.0
        for idx, probability in sorted(result.action_probs.items()):
            cumulative += probability
            if roll <= cumulative:
                return actions[idx]
        return actions[result.best_action_idx]

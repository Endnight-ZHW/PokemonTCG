"""Compatibility adapter from the old Deep MCTS API to the shared planner."""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

from engine.ai.planner import (
    AnytimePlanner,
    DeepRootBackend,
    HeuristicBackend,
    NeuralBackend,
    PlannerConfig,
)
from engine.ai.dl.production_contract import derive_training_decision_seed
from engine.enums import PlayerAction


@dataclass
class _MCTSSearchResult:
    action_probs: dict[int, float]
    root_value: float
    best_action_idx: int
    simulations: int
    selected_action_idx: int
    raw_priors: dict[int, float]
    noisy_priors: dict[int, float]
    visit_counts: dict[int, int]
    temperature: float
    sample_seed: int | None


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
        root_only_neural: bool = False,
        neural_prior_weight: float = 0.75,
        thinking_time_seconds: float = 2.0,
        match_seed: int = 0,
    ):
        self.model = model
        self.encoder = encoder
        self.legal_ai = legal_ai
        self.num_simulations = max(1, int(num_simulations))
        self.c_puct = float(c_puct)
        self.temperature = max(0.0, float(temperature))
        self.device = device
        self.dirichlet_alpha = max(0.0, float(dirichlet_alpha))
        self.dirichlet_epsilon = max(
            0.0,
            min(1.0, float(dirichlet_epsilon)),
        )
        self.add_dirichlet_noise = bool(add_dirichlet_noise)
        self.max_depth = max(4, int(max_depth))
        self.root_only_neural = bool(root_only_neural)
        self.neural_prior_weight = max(0.0, min(1.0, float(neural_prior_weight)))
        self.thinking_time_seconds = max(0.01, float(thinking_time_seconds))
        self.match_seed = int(match_seed)
        self._active_planner: AnytimePlanner | None = None
        self._decision_ordinal = 0

    def cancel(self) -> None:
        if self._active_planner is not None:
            self._active_planner.cancel()

    def _planner(
        self,
        deck_key: str | None,
        *,
        exploration: bool,
        decision_ordinal: int,
    ) -> AnytimePlanner:
        heuristic = HeuristicBackend(
            priority=self.legal_ai._quick_action_priority,
            evaluator=self.legal_ai.evaluate_state,
            choice_resolver=self.legal_ai.resolve_pending_action,
        )
        backend = (
            DeepRootBackend(
                self.model,
                self.encoder,
                self.device,
                heuristic,
                deck_key,
                neural_weight=self.neural_prior_weight,
            )
            if self.root_only_neural
            else NeuralBackend(
                self.model,
                self.encoder,
                self.device,
                heuristic,
                deck_key,
            )
        )
        return AnytimePlanner(
            backend,
            PlannerConfig(
                thinking_time_seconds=self.thinking_time_seconds,
                simulation_budget=self.num_simulations,
                max_depth=self.max_depth,
                c_puct=self.c_puct,
                opponent_branch_limit=6,
                random_seed=getattr(self.legal_ai.config, "random_seed", 17),
                match_seed=self.match_seed,
                deep_seed_contract=self.root_only_neural,
                root_dirichlet_alpha=(
                    self.dirichlet_alpha if exploration else 0.0
                ),
                root_dirichlet_epsilon=(
                    self.dirichlet_epsilon if exploration else 0.0
                ),
                root_noise_until_turn=12,
                decision_ordinal=decision_ordinal,
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
        exploration: bool | None = None,
    ) -> _MCTSSearchResult:
        actions = list(actions or self.legal_ai.legal_actions(state, player_idx))
        if not actions:
            return _MCTSSearchResult(
                {},
                0.0,
                -1,
                0,
                -1,
                {},
                {},
                {},
                0.0,
                None,
            )
        use_exploration = (
            self.add_dirichlet_noise
            if exploration is None
            else bool(exploration)
        )
        self._decision_ordinal += 1
        decision_ordinal = self._decision_ordinal
        planner = self._planner(
            deck_key,
            exploration=use_exploration,
            decision_ordinal=decision_ordinal,
        )
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
        visit_counts = {
            idx: max(0, int(visits.get(action.signature, 0)))
            for idx, action in enumerate(actions)
        }
        raw_priors = {
            idx: float(
                (result.raw_priors if result is not None else {}).get(
                    action.signature,
                    1.0 / len(actions),
                )
            )
            for idx, action in enumerate(actions)
        }
        noisy_priors = {
            idx: float(
                (result.noisy_priors if result is not None else {}).get(
                    action.signature,
                    raw_priors[idx],
                )
            )
            for idx, action in enumerate(actions)
        }
        best_idx = min(
            range(len(actions)),
            key=lambda idx: (
                -visit_counts[idx],
                -noisy_priors[idx],
                str(actions[idx].signature),
            ),
        )
        temperature = (
            _training_visit_temperature(int(getattr(state, "turn_number", 0)))
            if use_exploration
            else 0.0
        )
        action_probs = _temperature_visit_distribution(
            visit_counts,
            temperature,
            fallback=noisy_priors,
            greedy_index=best_idx,
        )
        sample_seed: int | None = None
        selected_idx = best_idx
        if temperature > 0.0:
            sample_seed = derive_training_decision_seed(
                self.match_seed,
                int(getattr(state, "revision", 0)),
                player_idx,
                decision_ordinal,
                "visit-sample",
            )
            selected_idx = _sample_distribution(action_probs, sample_seed)
        root_value = 0.0
        if result is not None:
            root_value = float(result.values.get(actions[best_idx].signature, 0.0))
        return _MCTSSearchResult(
            action_probs,
            root_value,
            best_idx,
            int(result.simulations) if result is not None else 0,
            selected_idx,
            raw_priors,
            noisy_priors,
            visit_counts,
            temperature,
            sample_seed,
        )

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
            exploration=False if deterministic else None,
        )
        selected_index = (
            result.best_action_idx
            if deterministic
            else result.selected_action_idx
        )
        return self._postprocess_preferred_action(
            state,
            player_idx,
            actions[selected_index],
            actions,
        )

    def _postprocess_preferred_action(self, state, player_idx: int, preferred, actions):
        postprocess = getattr(self.legal_ai, "_validated_or_fallback_action", None)
        if not callable(postprocess):
            return preferred
        try:
            selected = postprocess(state, player_idx, preferred, actions)
            return selected if selected is not None else preferred
        except Exception:
            return preferred


def _training_visit_temperature(turn_number: int) -> float:
    if turn_number <= 6:
        return 1.0
    if turn_number <= 12:
        return 0.5
    return 0.1


def _temperature_visit_distribution(
    visits: dict[int, int],
    temperature: float,
    *,
    fallback: dict[int, float],
    greedy_index: int,
) -> dict[int, float]:
    if not visits:
        return {}
    if temperature <= 0.0:
        return {
            index: 1.0 if index == greedy_index else 0.0
            for index in visits
        }
    exponent = 1.0 / max(1e-6, float(temperature))
    values = {
        index: float(max(0, count)) ** exponent
        for index, count in visits.items()
    }
    total = sum(values.values())
    if total <= 1e-30:
        values = {
            index: max(0.0, float(fallback.get(index, 0.0)))
            for index in visits
        }
        total = sum(values.values())
    if total <= 1e-30:
        return {index: 1.0 / len(visits) for index in visits}
    return {index: value / total for index, value in values.items()}


def _sample_distribution(probabilities: dict[int, float], seed: int) -> int:
    import random

    rng = random.Random(int(seed))
    roll = rng.random()
    cumulative = 0.0
    selected = min(probabilities)
    for index in sorted(probabilities):
        selected = index
        cumulative += max(0.0, float(probabilities[index]))
        if roll <= cumulative:
            return index
    return selected

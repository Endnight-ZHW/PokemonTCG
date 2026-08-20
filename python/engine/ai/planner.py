"""Shared anytime information-set planner for rules and neural AI backends."""
from __future__ import annotations

import math
import random
import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol

from engine.actions import ChoiceView, ChoiceResponse, GameAction
from engine.ai.observation import fair_search_clone
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import DEFAULT_GAME_ENGINE, GameEngine
from engine.random_source import SamplingRandomSource
from engine.ai.dl.production_contract import (
    derive_deep_decision_seed,
    derive_training_decision_seed,
)


HEURISTIC_PRIOR_TEMPERATURE = 80.0


def terminal_outcome_value(state, perspective: int) -> float:
    """Return a zero-sum terminal value without inventing a draw winner."""
    if getattr(state, "result_status", "") == "DRAW":
        return 0.0
    return 1.0 if state.winner == perspective else -1.0


class PolicyBackend(Protocol):
    def priors(self, state, actor: int, actions: list[GameAction]) -> list[float]: ...
    def value(self, state, perspective: int) -> float: ...
    def choose(self, state, request: ChoiceView) -> ChoiceResponse: ...


@dataclass
class PlannerConfig:
    thinking_time_seconds: float = 8.0
    simulation_budget: int = 2500
    max_depth: int = 16
    c_puct: float = 1.4
    opponent_branch_limit: int = 6
    random_seed: int = 17
    match_seed: int = 0
    deep_seed_contract: bool = False
    root_dirichlet_alpha: float = 0.0
    root_dirichlet_epsilon: float = 0.0
    root_noise_until_turn: int = 12
    decision_ordinal: int = 0


@dataclass
class _RootStat:
    action: GameAction
    prior: float
    visits: int = 0
    total_value: float = 0.0

    @property
    def q(self) -> float:
        return self.total_value / self.visits if self.visits else 0.0


@dataclass
class PlannerResult:
    action: GameAction
    simulations: int
    elapsed_seconds: float
    values: dict[tuple, float]
    visits: dict[tuple, int]
    raw_priors: dict[tuple, float]
    noisy_priors: dict[tuple, float]
    root_noise_seed: int | None


class HeuristicBackend:
    def __init__(
        self,
        *,
        priority: Callable[[Any, int, GameAction], float],
        evaluator: Callable[[Any, int], float],
        choice_resolver: Callable[[Any, Any], Any] | None = None,
    ):
        self._priority = priority
        self._evaluator = evaluator
        self._choice_resolver = choice_resolver

    def priors(self, state, actor: int, actions: list[GameAction]) -> list[float]:
        scores = [self._priority(state, actor, action) for action in actions]
        return _softmax(scores)

    def value(self, state, perspective: int) -> float:
        raw = float(self._evaluator(state, perspective))
        return max(-1.0, min(1.0, raw / 1_000_000.0))

    def choose(self, state, request: ChoiceView) -> ChoiceResponse:
        if self._choice_resolver is not None:
            response = self._choice_resolver(state, request)
            if isinstance(response, ChoiceResponse):
                return response
        count = min(len(request.options), max(request.min_select, request.max_select))
        return ChoiceResponse(
            request.request_id,
            tuple(option.option_id for option in request.options[:count]),
        )


class AnytimePlanner:
    """Root-ISMCTS planner with sampled chance outcomes and full-turn rollouts."""

    def __init__(
        self,
        backend: PolicyBackend,
        config: PlannerConfig | None = None,
        engine: GameEngine | None = None,
    ):
        self.backend = backend
        self.config = config or PlannerConfig()
        self.engine = engine or DEFAULT_GAME_ENGINE
        self.cancelled = False
        self.last_result: PlannerResult | None = None

    def cancel(self) -> None:
        self.cancelled = True

    def search(
        self,
        state,
        player_idx: int,
        *,
        actions: list[GameAction] | tuple[GameAction, ...] | None = None,
        deadline: float | None = None,
    ) -> GameAction:
        started = time.perf_counter()
        self.cancelled = False
        if deadline is None:
            deadline = started + max(0.01, self.config.thinking_time_seconds)
        root_actions = list(
            self.engine.legal_actions(state, player_idx)
            if actions is None
            else actions
        )
        if not root_actions:
            return GameAction(
                kind=PlayerAction.END_TURN,
                actor=player_idx,
                base_revision=int(getattr(state, "revision", -1)),
            )
        set_perspective = getattr(self.backend, "set_perspective", None)
        if callable(set_perspective):
            set_perspective(player_idx)

        priors = self.backend.priors(state, player_idx, root_actions)
        if len(priors) != len(root_actions):
            priors = [1.0 / len(root_actions)] * len(root_actions)
        raw_priors = _normalize_priors([float(value) for value in priors])
        noisy_priors = list(raw_priors)
        root_noise_seed: int | None = None
        epsilon = max(
            0.0,
            min(1.0, float(self.config.root_dirichlet_epsilon)),
        )
        alpha = float(self.config.root_dirichlet_alpha)
        turn_number = int(getattr(state, "turn_number", 0))
        if (
            epsilon > 0.0
            and alpha > 0.0
            and 1 <= turn_number <= int(self.config.root_noise_until_turn)
        ):
            root_noise_seed = derive_training_decision_seed(
                self.config.match_seed,
                int(getattr(state, "revision", 0)),
                player_idx,
                self.config.decision_ordinal,
                "root-dirichlet",
            )
            noise = _dirichlet(
                len(root_actions),
                alpha,
                random.Random(root_noise_seed),
            )
            noisy_priors = _normalize_priors([
                (1.0 - epsilon) * prior + epsilon * noise_value
                for prior, noise_value in zip(raw_priors, noise)
            ])
        stats = [
            _RootStat(action, max(1e-8, float(prior)))
            for action, prior in zip(root_actions, noisy_priors)
        ]

        simulations = 0
        while (
            simulations < max(1, self.config.simulation_budget)
            and time.perf_counter() < deadline
            and not self.cancelled
        ):
            total_visits = sum(item.visits for item in stats)
            selected = max(
                stats,
                key=lambda item: item.q + self.config.c_puct * item.prior
                * math.sqrt(total_visits + 1) / (1 + item.visits),
            )
            if self.config.deep_seed_contract:
                revision = int(getattr(state, "revision", 0))
                simulation_seed = derive_deep_decision_seed(
                    self.config.match_seed,
                    revision,
                    player_idx,
                    simulations + 1,
                )
                rollout_seed = derive_deep_decision_seed(
                    self.config.match_seed,
                    revision,
                    player_idx,
                    simulations + 1000,
                )
            else:
                simulation_seed = (
                    self.config.random_seed + simulations * 7919
                )
                rollout_seed = (
                    self.config.random_seed + simulations * 104729
                )
            simulation = fair_search_clone(
                state,
                player_idx,
                simulation_seed,
            )
            rng = SamplingRandomSource(rollout_seed)
            value = self._simulate(
                simulation,
                player_idx,
                selected.action,
                rng,
                deadline,
            )
            selected.visits += 1
            selected.total_value += value
            simulations += 1

        chosen = max(
            stats,
            key=lambda item: (item.visits, item.q, item.prior),
        ).action
        elapsed = time.perf_counter() - started
        self.last_result = PlannerResult(
            chosen,
            simulations,
            elapsed,
            {item.action.signature: item.q for item in stats},
            {item.action.signature: item.visits for item in stats},
            {
                action.signature: float(prior)
                for action, prior in zip(root_actions, raw_priors)
            },
            {
                action.signature: float(prior)
                for action, prior in zip(root_actions, noisy_priors)
            },
            root_noise_seed,
        )
        return chosen

    def _simulate(
        self,
        state,
        perspective: int,
        first_action: GameAction,
        rng: SamplingRandomSource,
        deadline: float,
    ) -> float:
        step = self.engine.apply_action(
            state,
            first_action,
            rng,
            auto_resolve=True,
            choice_policy=self.backend.choose,
            auto_finish_attack=True,
        )
        if not step.success:
            return -1.0
        if step.terminal:
            return terminal_outcome_value(state, perspective)

        depth = 1
        opponent_started = state.active_player_idx != perspective
        opponent_actions = 0
        while depth < self.config.max_depth and time.perf_counter() < deadline:
            actor = (
                int(state.pending_promotions[0])
                if state.pending_promotions
                else state.active_player_idx
            )
            actions = list(self.engine.legal_actions(
                state,
                actor,
                validate_effects=False,
            ))
            if not actions:
                break
            if actor == perspective:
                priors = self.backend.priors(state, actor, actions)
                action = actions[max(range(len(actions)), key=lambda idx: priors[idx])]
            else:
                opponent_started = True
                action = self._opponent_action(state, perspective, actions)
                opponent_actions += 1

            step = self.engine.apply_action(
                state,
                action,
                rng,
                auto_resolve=True,
                choice_policy=self.backend.choose,
                auto_finish_attack=True,
            )
            if not step.success:
                break
            if step.terminal:
                return terminal_outcome_value(state, perspective)
            depth += 1
            if opponent_started and opponent_actions > 0 and state.active_player_idx == perspective:
                break
        return self.backend.value(state, perspective)

    def _opponent_action(
        self,
        state,
        perspective: int,
        actions: list[GameAction],
    ) -> GameAction:
        priors = self.backend.priors(state, state.active_player_idx, actions)
        ranked = sorted(
            range(len(actions)),
            key=lambda index: priors[index],
            reverse=True,
        )[: max(1, self.config.opponent_branch_limit)]
        best_action = actions[ranked[0]]
        worst_value = float("inf")
        for index in ranked:
            candidate_state = fair_search_clone(
                state,
                perspective,
                self.config.random_seed + index * 3571,
            )
            candidate_rng = SamplingRandomSource(
                self.config.random_seed + index * 65537
            )
            result = self.engine.apply_action(
                candidate_state,
                actions[index],
                candidate_rng,
                auto_resolve=True,
                choice_policy=self.backend.choose,
                auto_finish_attack=True,
            )
            value = self.backend.value(candidate_state, perspective) if result.success else 1.0
            if value < worst_value:
                worst_value = value
                best_action = actions[index]
        return best_action


def _softmax(scores: list[float]) -> list[float]:
    if not scores:
        return []
    maximum = max(scores)
    scale = max(1e-6, float(HEURISTIC_PRIOR_TEMPERATURE))
    values = [math.exp(max(-60.0, min(60.0, (score - maximum) / scale))) for score in scores]
    total = sum(values) or 1.0
    return [value / total for value in values]


def _normalize_priors(priors: list[float]) -> list[float]:
    if not priors:
        return []
    values = [
        max(0.0, float(value))
        if math.isfinite(float(value)) else 0.0
        for value in priors
    ]
    total = sum(values)
    if total <= 1e-12:
        return [1.0 / len(values)] * len(values)
    return [value / total for value in values]


def _dirichlet(
    count: int,
    alpha: float,
    rng: random.Random,
) -> list[float]:
    """Sample a Dirichlet vector entirely from a caller-owned local RNG."""

    if count <= 0:
        return []
    values = [
        max(0.0, float(rng.gammavariate(float(alpha), 1.0)))
        for _ in range(count)
    ]
    total = sum(values)
    if total <= 1e-30:
        return [1.0 / count] * count
    return [value / total for value in values]

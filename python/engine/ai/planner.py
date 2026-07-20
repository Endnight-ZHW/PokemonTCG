"""Shared anytime information-set planner for rules and neural AI backends."""
from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol

from engine.actions import ChoiceRequest, ChoiceResponse, GameAction
from engine.ai.observation import Observation, fair_search_clone
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import DEFAULT_GAME_ENGINE, GameEngine
from engine.random_source import SamplingRandomSource


PLANNER_SCHEMA_VERSION = 1
HEURISTIC_PRIOR_TEMPERATURE = 80.0
NEURAL_PRIOR_BLEND = 0.15
NEURAL_PRIOR_MIN_TOP_PROB = 0.45
HEURISTIC_PRIOR_CLEAR_GAP = 0.12


def terminal_outcome_value(state, perspective: int) -> float:
    """Return a zero-sum terminal value without inventing a draw winner."""
    if getattr(state, "result_status", "") == "DRAW":
        return 0.0
    return 1.0 if state.winner == perspective else -1.0


class PolicyBackend(Protocol):
    def priors(self, state, actor: int, actions: list[GameAction]) -> list[float]: ...
    def value(self, state, perspective: int) -> float: ...
    def choose(self, state, request: ChoiceRequest) -> ChoiceResponse: ...


@dataclass
class PlannerConfig:
    thinking_time_seconds: float = 8.0
    simulation_budget: int = 2500
    max_depth: int = 16
    c_puct: float = 1.4
    opponent_branch_limit: int = 6
    random_seed: int = 17


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

    def choose(self, state, request: ChoiceRequest) -> ChoiceResponse:
        if self._choice_resolver is not None and request.legacy_request is not None:
            legacy_choice = self._choice_resolver(state, request.legacy_request)
            mapped = _map_legacy_choice(request, legacy_choice)
            if mapped is not None:
                return mapped
        count = min(len(request.options), max(request.min_select, request.max_select))
        return ChoiceResponse(
            request.request_id,
            tuple(option.option_id for option in request.options[:count]),
        )


class NeuralBackend(HeuristicBackend):
    def __init__(self, model, encoder, device: str, fallback: HeuristicBackend, deck_key: str | None):
        super().__init__(
            priority=fallback._priority,
            evaluator=fallback._evaluator,
            choice_resolver=fallback._choice_resolver,
        )
        self.model = model
        self.encoder = encoder
        self.device = device
        self.fallback = fallback
        self.deck_key = deck_key
        self.search_perspective: int | None = None
        self._value_cache: dict[tuple, float] = {}

    def set_perspective(self, perspective: int) -> None:
        self.search_perspective = perspective
        self._value_cache.clear()

    def priors(self, state, actor: int, actions: list[GameAction]) -> list[float]:
        if self.search_perspective is not None and actor != self.search_perspective:
            return self.fallback.priors(state, actor, actions)
        heuristic_priors = self.fallback.priors(state, actor, actions)
        try:
            from engine.ai.dl.model import TORCH_AVAILABLE, torch
            if not TORCH_AVAILABLE or torch is None or self.model is None:
                return heuristic_priors
            observation = Observation.from_state(state, actor)
            encoded_state = self.encoder.encode_observation(observation, self.deck_key)
            encoded_actions = [
                self.encoder.encode_game_action(observation, action)
                for action in actions
            ]
            state_numeric_size = int(getattr(self.model, "state_numeric_size", len(encoded_state.numeric)))
            state_card_slots = int(getattr(self.model, "state_card_slots", len(encoded_state.card_ids)))
            action_numeric_size = int(getattr(self.model, "action_numeric_size", len(encoded_actions[0].numeric)))
            with torch.no_grad():
                state_numeric = torch.tensor(
                    [_fit(encoded_state.numeric, state_numeric_size, 0.0)],
                    dtype=torch.float32,
                    device=self.device,
                )
                state_cards = torch.tensor(
                    [_fit(encoded_state.card_ids, state_card_slots, 0)],
                    dtype=torch.long,
                    device=self.device,
                )
                action_numeric = torch.tensor(
                    [[_fit(item.numeric, action_numeric_size, 0.0) for item in encoded_actions]],
                    dtype=torch.float32,
                    device=self.device,
                )
                action_cards = torch.tensor(
                    [[item.card_id for item in encoded_actions]],
                    dtype=torch.long,
                    device=self.device,
                )
                logits, model_value = self.model(
                    state_numeric,
                    state_cards,
                    action_numeric,
                    action_cards,
                )
                self._value_cache[observation.information_key] = float(
                    model_value.reshape(-1)[0].detach().cpu().item()
                )
                neural_priors = torch.softmax(logits[0], dim=0).detach().cpu().tolist()
                return _guarded_neural_priors(neural_priors, heuristic_priors)
        except Exception:
            return heuristic_priors

    def value(self, state, perspective: int) -> float:
        # Godot's production Deep AI uses neural priors inside the shared
        # planner but keeps the mature heuristic evaluator for leaf values.
        # Mirror that path here; the learned value head is still trained for
        # future use, but is not yet strong enough to gate release models.
        return self.fallback.value(state, perspective)


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
            return GameAction(PlayerAction.END_TURN, {}, True, player_idx)
        set_perspective = getattr(self.backend, "set_perspective", None)
        if callable(set_perspective):
            set_perspective(player_idx)

        priors = self.backend.priors(state, player_idx, root_actions)
        if len(priors) != len(root_actions):
            priors = [1.0 / len(root_actions)] * len(root_actions)
        stats = [
            _RootStat(action, max(1e-8, float(prior)))
            for action, prior in zip(root_actions, priors)
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
            simulation = fair_search_clone(
                state,
                player_idx,
                self.config.random_seed + simulations * 7919,
            )
            rng = SamplingRandomSource(self.config.random_seed + simulations * 104729)
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
                state.pending_promotion_player
                if state.pending_promotion_player >= 0
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


def _top_two(priors: list[float]) -> tuple[int, float, float]:
    if not priors:
        return -1, 0.0, 0.0
    top_idx = max(range(len(priors)), key=lambda idx: priors[idx])
    top = float(priors[top_idx])
    second = max(
        (float(value) for idx, value in enumerate(priors) if idx != top_idx),
        default=0.0,
    )
    return top_idx, top, second


def _guarded_neural_priors(
    neural_priors: list[float],
    heuristic_priors: list[float],
    *,
    blend: float = NEURAL_PRIOR_BLEND,
    min_top_prob: float = NEURAL_PRIOR_MIN_TOP_PROB,
    clear_gap: float = HEURISTIC_PRIOR_CLEAR_GAP,
) -> list[float]:
    """Use neural priors only as a guarded nudge over the mature heuristic prior."""
    heuristic = _normalize_priors(list(heuristic_priors))
    if len(neural_priors) != len(heuristic) or not heuristic:
        return heuristic
    neural = _normalize_priors(list(neural_priors))
    if len(neural) != len(heuristic):
        return heuristic
    neural_top, neural_peak, _ = _top_two(neural)
    heuristic_top, heuristic_peak, heuristic_second = _top_two(heuristic)
    if neural_peak < float(min_top_prob):
        return heuristic
    heuristic_gap = heuristic_peak - heuristic_second
    if neural_top != heuristic_top and heuristic_gap >= float(clear_gap):
        return heuristic
    effective_blend = max(0.0, min(1.0, float(blend)))
    if neural_top != heuristic_top:
        effective_blend *= 0.5
    return _normalize_priors([
        (1.0 - effective_blend) * heuristic[idx] + effective_blend * neural[idx]
        for idx in range(len(heuristic))
    ])


def _map_legacy_choice(request: ChoiceRequest, choice) -> ChoiceResponse | None:
    option_ids = list(getattr(choice, "option_ids", []) or [])
    if option_ids:
        return ChoiceResponse(request.request_id, tuple(option_ids), bool(getattr(choice, "cancelled", False)))
    if getattr(choice, "cancelled", False):
        return ChoiceResponse(request.request_id, (), True)
    if request.request_type == "coin_flip":
        # The command already consumed RNG and stored the result in its
        # continuation.  The public choice only acknowledges the display.
        return ChoiceResponse(request.request_id, ())
    if request.request_type in {"confirm", "confirm_trigger"}:
        option_id = "confirm:yes" if getattr(choice, "confirmed", False) else "confirm:no"
        return ChoiceResponse(request.request_id, (option_id,))
    selected_slot = getattr(choice, "selected_bench_slot", None)
    if selected_slot is not None:
        for option in request.options:
            if option.value == selected_slot:
                return ChoiceResponse(request.request_id, (option.option_id,))
    selected_targets = list(getattr(choice, "selected_bench_targets", []) or [])
    if selected_targets:
        ids = [
            option.option_id
            for target in selected_targets
            for option in request.options
            if option.value == target
        ]
        return ChoiceResponse(request.request_id, tuple(ids))
    assignments = list(getattr(choice, "assignments", []) or [])
    if assignments:
        ids = []
        for energy_idx, slot in assignments:
            match = next(
                (
                    option for option in request.options
                    if isinstance(option.value, dict)
                    and str(option.value.get("slot", "")) == str(slot)
                    and (
                        request.metadata.get("distribute_mode") == "source_select"
                        or int(option.value.get("energy_index", -1)) == int(energy_idx)
                    )
                ),
                None,
            )
            if match is not None:
                ids.append(match.option_id)
        if ids:
            return ChoiceResponse(request.request_id, tuple(ids))
    selected_cards = list(getattr(choice, "selected_cards", []) or [])
    if selected_cards:
        ids = []
        unused = list(request.options)
        for card in selected_cards:
            match = next(
                (
                    option for option in unused
                    if option.value is card
                    or getattr(option.value, "api_id", None) == getattr(card, "api_id", None)
                ),
                None,
            )
            if match is not None:
                ids.append(match.option_id)
                unused.remove(match)
        if ids:
            return ChoiceResponse(request.request_id, tuple(ids))
    return None


def _fit(values: list, size: int, pad):
    return values[:size] if len(values) >= size else values + [pad] * (size - len(values))

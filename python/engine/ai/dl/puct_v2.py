"""Re-determinizing information-set PUCT for AlphaZero v2."""
from __future__ import annotations

import hashlib
import itertools
import math
import random
import time
from dataclasses import dataclass, field
from typing import Any, Protocol, Sequence

import numpy as np

from engine.actions import (
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
)
from engine.ai.observation import Observation, fair_search_clone
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.random_source import RandomSource
from engine.snapshot import clone_state

from .inference_v2 import PolicyValueEvaluator
from .v2_contract import (
    DEFAULT_C_PUCT,
    DEFAULT_DIRICHLET_EPSILON,
    DEFAULT_TRAINING_SIMULATIONS,
    dirichlet_alpha,
    visit_temperature,
)


MAX_CHOICE_CANDIDATES = 256


@dataclass(frozen=True)
class SearchCandidate:
    signature: str
    payload: GameAction | ChoiceResponse
    choice_option: ChoiceOption | None = None
    request_type: str = ""


@dataclass
class SearchEdge:
    candidate: SearchCandidate
    prior: float
    visits: int = 0
    value_sum: float = 0.0

    @property
    def q(self) -> float:
        return self.value_sum / self.visits if self.visits else 0.0


@dataclass
class SearchNode:
    key: str
    actor: int
    expanded: bool = False
    edges: dict[str, SearchEdge] = field(default_factory=dict)


@dataclass(frozen=True)
class SearchResult:
    selected: SearchCandidate
    visits: dict[str, int]
    probabilities: dict[str, float]
    root_value: float
    simulations: int
    elapsed_seconds: float
    degraded_deadline: bool


class SearchEnvironment(Protocol):
    def clone_root(self, state: Any, actor: int, seed: int) -> Any: ...
    def redeterminize(self, state: Any, actor: int, seed: int) -> Any: ...
    def actor(self, state: Any) -> int: ...
    def observation(self, state: Any, actor: int) -> Observation: ...
    def candidates(self, state: Any, actor: int) -> Sequence[SearchCandidate]: ...
    def apply(
        self,
        state: Any,
        candidate: SearchCandidate,
        seed: int,
    ) -> None: ...
    def is_terminal(self, state: Any) -> bool: ...
    def terminal_value(self, state: Any, actor: int) -> float: ...
    def deck_key(self, state: Any, actor: int) -> str | None: ...


def _stable_signature(value: Any) -> str:
    raw = repr(value).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def information_set_key(observation: Observation, actor: int) -> str:
    """Hash only actor-visible state; never accept a GameState here."""
    if not isinstance(observation, Observation):
        raise TypeError("information_set_key_requires_observation")
    payload = (
        "infoset-v2",
        int(actor),
        observation.information_key,
    )
    return _stable_signature(payload)


def _choice_candidate_from_response(
    request: ChoiceRequest,
    response: ChoiceResponse,
) -> SearchCandidate | None:
    if response.request_id != request.request_id:
        return None
    if response.cancelled:
        if not request.can_cancel or response.option_ids:
            return None
        return SearchCandidate(
            signature=f"choice:{request.request_id}:cancel",
            payload=ChoiceResponse(request.request_id, (), True),
            choice_option=ChoiceOption(
                option_id=f"{request.request_id}:cancel",
                label="cancel",
            ),
            request_type=request.request_type,
        )

    requested_counts: dict[str, int] = {}
    for option_id in response.option_ids:
        requested_counts[option_id] = requested_counts.get(option_id, 0) + 1
    selected: list[ChoiceOption] = []
    for option in request.options:
        count = requested_counts.pop(option.option_id, 0)
        if count > 1 and not request.allow_duplicates:
            return None
        selected.extend([option] * count)
    if requested_counts:
        return None
    if not request.min_select <= len(selected) <= request.max_select:
        return None

    option_ids = tuple(option.option_id for option in selected)
    signature = "choice:" + request.request_id + ":" + "|".join(option_ids)
    synthetic = ChoiceOption(
        option_id=signature,
        label=" / ".join(option.label for option in selected),
        ref=selected[0].ref if selected else None,
        value=tuple(selected),
    )
    return SearchCandidate(
        signature=signature,
        payload=ChoiceResponse(request.request_id, option_ids),
        choice_option=synthetic,
        request_type=request.request_type,
    )


def _choice_responses(
    request: ChoiceRequest,
    preferred_response: ChoiceResponse | None = None,
) -> list[SearchCandidate]:
    options = tuple(request.options)
    candidates: list[SearchCandidate] = []
    combination_fn = (
        itertools.combinations_with_replacement
        if request.allow_duplicates
        else itertools.combinations
    )
    limit_reached = False
    for size in range(request.min_select, request.max_select + 1):
        for selected in combination_fn(options, size):
            option_ids = tuple(option.option_id for option in selected)
            signature = "choice:" + request.request_id + ":" + "|".join(option_ids)
            synthetic = ChoiceOption(
                option_id=signature,
                label=" / ".join(option.label for option in selected),
                ref=selected[0].ref if selected else None,
                value=selected,
            )
            candidates.append(
                SearchCandidate(
                    signature=signature,
                    payload=ChoiceResponse(request.request_id, option_ids),
                    choice_option=synthetic,
                    request_type=request.request_type,
                )
            )
            if len(candidates) >= MAX_CHOICE_CANDIDATES:
                limit_reached = True
                break
        if limit_reached:
            break
    if request.can_cancel and len(candidates) < MAX_CHOICE_CANDIDATES:
        candidates.append(
            SearchCandidate(
                signature=f"choice:{request.request_id}:cancel",
                payload=ChoiceResponse(request.request_id, (), True),
                choice_option=ChoiceOption(
                    option_id=f"{request.request_id}:cancel",
                    label="cancel",
                ),
                request_type=request.request_type,
            )
        )
    if preferred_response is not None:
        preferred = _choice_candidate_from_response(
            request,
            preferred_response,
        )
        if (
            preferred is not None
            and not any(
                candidate.signature == preferred.signature
                for candidate in candidates
            )
        ):
            if len(candidates) >= MAX_CHOICE_CANDIDATES:
                candidates[-1] = preferred
            else:
                candidates.append(preferred)
    return candidates


def _legal_choice_responses(
    state: Any,
    request: ChoiceRequest,
) -> list[SearchCandidate]:
    """Remove structurally valid combinations rejected by rule continuations."""
    seed = int.from_bytes(
        hashlib.sha256(
            ("choice-validation:" + request.request_id).encode("utf-8")
        ).digest()[:4],
        "little",
    )
    result: list[SearchCandidate] = []
    for candidate in _choice_responses(request):
        probe = clone_state(state)
        step = DEFAULT_GAME_ENGINE.apply_choice(
            probe,
            candidate.payload,
            RandomSource(seed),
        )
        if step.success:
            result.append(candidate)
    return result


class PythonGameEnvironment:
    """Correctness fallback; production training is expected to use native ABI."""

    def clone_root(self, state: Any, actor: int, seed: int) -> Any:
        return fair_search_clone(state, actor, seed)

    def redeterminize(self, state: Any, actor: int, seed: int) -> Any:
        return fair_search_clone(state, actor, seed)

    def actor(self, state: Any) -> int:
        request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        if request is not None:
            return int(request.player)
        promotion_actor = int(
            getattr(state, "pending_promotion_player", -1)
        )
        if promotion_actor in (0, 1):
            return promotion_actor
        return int(state.active_player_idx)

    def observation(self, state: Any, actor: int) -> Observation:
        return Observation.from_state(state, actor)

    def decision_key(
        self,
        state: Any,
        actor: int,
        observation: Observation,
    ) -> str:
        """Include the public decision role/request in the information key."""
        request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        if request is None:
            decision = ("action",)
        else:
            decision = (
                "choice",
                request.request_id,
                request.request_type,
                int(request.player),
                int(request.min_select),
                int(request.max_select),
                bool(request.allow_duplicates),
                bool(request.can_cancel),
                tuple(
                    (
                        option.option_id,
                        option.ref.ref_id
                        if option.ref is not None
                        else "",
                    )
                    for option in request.options
                ),
            )
        return _stable_signature(
            (
                "infoset-v2-decision",
                information_set_key(observation, actor),
                decision,
            )
        )

    def candidates(
        self,
        state: Any,
        actor: int,
    ) -> Sequence[SearchCandidate]:
        request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        if request is not None:
            return _legal_choice_responses(state, request)
        actions = DEFAULT_GAME_ENGINE.legal_actions(state, actor)
        return [
            SearchCandidate(
                signature="action:" + _stable_signature(action.signature),
                payload=action,
            )
            for action in actions
        ]

    def apply(
        self,
        state: Any,
        candidate: SearchCandidate,
        seed: int,
    ) -> None:
        rng = RandomSource(int(seed) & 0xFFFFFFFF)
        if isinstance(candidate.payload, ChoiceResponse):
            step = DEFAULT_GAME_ENGINE.apply_choice(
                state,
                candidate.payload,
                rng,
            )
        else:
            step = DEFAULT_GAME_ENGINE.apply_action(
                state,
                candidate.payload,
                rng,
                auto_resolve=False,
                auto_finish_attack=True,
            )
        if not step.success:
            raise RuntimeError(
                "search_transition_failed:"
                f"error_code={step.error_code or 'unknown'}:"
                f"message={step.message or ''}"
            )

    def is_terminal(self, state: Any) -> bool:
        return bool(state.is_terminal())

    def terminal_value(self, state: Any, actor: int) -> float:
        if state.winner is None:
            return 0.0
        return 1.0 if int(state.winner) == int(actor) else -1.0

    def deck_key(self, state: Any, actor: int) -> str | None:
        keys = tuple(getattr(state, "public_deck_keys", (None, None)))
        return str(keys[actor]) if actor < len(keys) and keys[actor] else None


class InformationSetPUCT:
    def __init__(
        self,
        evaluator: PolicyValueEvaluator,
        environment: SearchEnvironment | None = None,
        *,
        simulations: int = DEFAULT_TRAINING_SIMULATIONS,
        c_puct: float = DEFAULT_C_PUCT,
        dirichlet_epsilon: float = DEFAULT_DIRICHLET_EPSILON,
        training: bool = True,
        max_depth: int = 128,
        seed: int = 17,
    ) -> None:
        self.evaluator = evaluator
        self.environment = environment or PythonGameEnvironment()
        self.simulations = max(1, int(simulations))
        self.c_puct = float(c_puct)
        self.dirichlet_epsilon = max(
            0.0,
            min(1.0, float(dirichlet_epsilon)),
        )
        self.training = bool(training)
        self.max_depth = max(1, int(max_depth))
        self.seed = int(seed)
        self.nodes: dict[str, SearchNode] = {}
        self._cancelled = False

    def cancel(self) -> None:
        self._cancelled = True

    def search(
        self,
        root_state: Any,
        root_actor: int,
        *,
        deadline: float | None = None,
        min_simulations: int = 1,
        temperature: float | None = None,
    ) -> SearchResult:
        started = time.perf_counter()
        self._cancelled = False
        root_observation = self.environment.observation(root_state, root_actor)
        root_key = self._node_key(
            root_state,
            root_actor,
            root_observation,
        )
        completed = 0
        root_value = 0.0
        for simulation in range(self.simulations):
            if self._cancelled:
                break
            if deadline is not None and time.perf_counter() >= deadline:
                break
            world = self.environment.clone_root(
                root_state,
                root_actor,
                self._simulation_seed(simulation, 0, "root"),
            )
            value = self._simulate(
                world,
                root_actor,
                simulation,
                root_key,
                deadline,
            )
            if simulation == 0:
                root_value = value
            completed += 1

        node = self.nodes.get(root_key)
        if node is None or not node.edges:
            raise RuntimeError("puct_root_not_expanded")
        visits = {
            signature: edge.visits
            for signature, edge in node.edges.items()
        }
        chosen_temperature = (
            visit_temperature(int(root_observation.turn_number))
            if temperature is None and self.training
            else max(0.0, float(temperature or 0.0))
        )
        probabilities = self._visit_distribution(
            node,
            chosen_temperature,
        )
        selected_signature = self._sample_or_select(
            probabilities,
            simulation_ordinal=completed,
        )
        elapsed = time.perf_counter() - started
        return SearchResult(
            selected=node.edges[selected_signature].candidate,
            visits=visits,
            probabilities=probabilities,
            root_value=root_value,
            simulations=completed,
            elapsed_seconds=elapsed,
            degraded_deadline=completed < max(1, int(min_simulations)),
        )

    def _simulate(
        self,
        state: Any,
        root_actor: int,
        simulation: int,
        root_key: str,
        deadline: float | None,
    ) -> float:
        path: list[tuple[SearchEdge, int]] = []
        previous_actor = root_actor
        for depth in range(self.max_depth):
            if self._cancelled:
                return 0.0
            if deadline is not None and time.perf_counter() >= deadline:
                return 0.0
            actor = self.environment.actor(state)
            if depth > 0 and actor != previous_actor:
                state = self.environment.redeterminize(
                    state,
                    actor,
                    self._simulation_seed(
                        simulation,
                        depth,
                        "redeterminize",
                    ),
                )
            previous_actor = actor
            if self.environment.is_terminal(state):
                value = self.environment.terminal_value(state, actor)
                self._backup(path, value, actor)
                return value if actor == root_actor else -value

            observation = self.environment.observation(state, actor)
            key = (
                root_key
                if depth == 0
                else self._node_key(state, actor, observation)
            )
            node = self.nodes.setdefault(key, SearchNode(key, actor))
            candidates = list(self.environment.candidates(state, actor))
            if not candidates:
                self._backup(path, 0.0, actor)
                return 0.0
            if not node.expanded:
                evaluation = self.evaluator.evaluate(
                    observation,
                    candidates,
                    self.environment.deck_key(state, actor),
                )
                evaluation.validate(len(candidates))
                priors = evaluation.priors.astype(np.float64)
                if self.training and depth == 0:
                    priors = self._add_root_noise(priors, simulation)
                node.edges = {
                    candidate.signature: SearchEdge(
                        candidate,
                        float(prior),
                    )
                    for candidate, prior in zip(
                        candidates,
                        priors,
                        strict=True,
                    )
                }
                node.expanded = True
                value = evaluation.value
                self._backup(path, value, actor)
                return value if actor == root_actor else -value

            current = {
                candidate.signature: candidate
                for candidate in candidates
            }
            legal_edges = [
                edge
                for signature, edge in node.edges.items()
                if signature in current
            ]
            if not legal_edges:
                raise RuntimeError("tree_legal_set_diverged")
            edge = self._select_edge(node, legal_edges)
            edge.candidate = current[edge.candidate.signature]
            path.append((edge, actor))
            self.environment.apply(
                state,
                edge.candidate,
                self._simulation_seed(simulation, depth, "chance"),
            )

        self._backup(path, 0.0, self.environment.actor(state))
        return 0.0

    def _node_key(
        self,
        state: Any,
        actor: int,
        observation: Observation,
    ) -> str:
        decision_key = getattr(self.environment, "decision_key", None)
        if callable(decision_key):
            return str(decision_key(state, actor, observation))
        return information_set_key(observation, actor)

    def _select_edge(
        self,
        node: SearchNode,
        edges: Sequence[SearchEdge],
    ) -> SearchEdge:
        total = sum(edge.visits for edge in edges)
        sqrt_total = math.sqrt(max(1, total))
        return min(
            edges,
            key=lambda edge: (
                -(
                    edge.q
                    + self.c_puct
                    * edge.prior
                    * sqrt_total
                    / (1 + edge.visits)
                ),
                edge.candidate.signature,
            ),
        )

    @staticmethod
    def _backup(
        path: Sequence[tuple[SearchEdge, int]],
        value: float,
        value_actor: int,
    ) -> None:
        if not math.isfinite(value):
            raise ValueError("non_finite_leaf_value")
        for edge, edge_actor in reversed(path):
            edge.visits += 1
            edge.value_sum += value if edge_actor == value_actor else -value

    def _add_root_noise(
        self,
        priors: np.ndarray,
        simulation: int,
    ) -> np.ndarray:
        if simulation != 0 or self.dirichlet_epsilon <= 0.0:
            return priors
        rng = np.random.default_rng(
            self._simulation_seed(simulation, 0, "dirichlet")
        )
        noise = rng.dirichlet(
            np.full(len(priors), dirichlet_alpha(len(priors))),
        )
        mixed = (
            (1.0 - self.dirichlet_epsilon) * priors
            + self.dirichlet_epsilon * noise
        )
        return mixed / mixed.sum()

    @staticmethod
    def _visit_distribution(
        node: SearchNode,
        temperature: float,
    ) -> dict[str, float]:
        ordered = sorted(node.edges)
        if temperature <= 0.0:
            winner = min(
                ordered,
                key=lambda signature: (
                    -node.edges[signature].visits,
                    -node.edges[signature].prior,
                    signature,
                ),
            )
            return {
                signature: 1.0 if signature == winner else 0.0
                for signature in ordered
            }
        exponent = 1.0 / max(1e-6, temperature)
        weights = np.asarray(
            [float(node.edges[key].visits) ** exponent for key in ordered],
            dtype=np.float64,
        )
        if float(weights.sum()) <= 0.0:
            weights = np.asarray(
                [node.edges[key].prior for key in ordered],
                dtype=np.float64,
            )
        weights /= weights.sum()
        return {
            signature: float(probability)
            for signature, probability in zip(ordered, weights, strict=True)
        }

    def _sample_or_select(
        self,
        probabilities: dict[str, float],
        *,
        simulation_ordinal: int,
    ) -> str:
        ordered = sorted(probabilities)
        if not self.training:
            return min(
                ordered,
                key=lambda key: (-probabilities[key], key),
            )
        rng = random.Random(
            self._simulation_seed(
                simulation_ordinal,
                0,
                "visit-sample",
            )
        )
        roll = rng.random()
        cumulative = 0.0
        for signature in ordered:
            cumulative += probabilities[signature]
            if roll <= cumulative:
                return signature
        return ordered[-1]

    def _simulation_seed(
        self,
        simulation: int,
        depth: int,
        domain: str,
    ) -> int:
        digest = hashlib.blake2s(
            (
                f"{self.seed}|{simulation}|{depth}|{domain}"
            ).encode("utf-8"),
            digest_size=4,
        ).digest()
        return int.from_bytes(digest, "little")


def clone_for_tree_reuse(state: Any) -> Any:
    """Explicit helper used by runtimes that retain a matching subtree."""
    return clone_state(state)

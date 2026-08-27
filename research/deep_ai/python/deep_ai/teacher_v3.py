"""Deterministic replay generation using the shared C++ Challenge policy."""
from __future__ import annotations

import concurrent.futures
import hashlib
import itertools
import json
import multiprocessing
from collections import Counter
from dataclasses import dataclass, replace
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, DECK_SPECS, expand_deck
from engine.action_codec import (
    deserialize_choice_response,
    deserialize_game_action,
    serialize_choice_response,
    serialize_choice_view,
    serialize_game_action,
)
from engine.actions import ChoiceOption, ChoiceResponse, ChoiceView, GameAction
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import GameState
from engine.native_state_codec import mask_native_snapshot, native_catalog_payload, state_to_native_snapshot
from engine.random_source import RandomSource

from .encoder_v3 import InformationSetEncoderV8
from .replay_v3 import ReplaySampleV3, ReplayStoreV3
from .v3_contract import RELEASE_DECKS


MAX_CHOICE_CANDIDATES = 256
DEFAULT_V3_TEACHER_CONFIG = {
    "node_budget": 192,
    "belief_samples": 3,
}

RESEARCH_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[4]


@dataclass(frozen=True, slots=True)
class TeacherTaskV3:
    game_id: str
    generation: int
    deck_a: str
    deck_b: str
    seed: int
    seat_a: int
    first_player: int
    opponent_version: int = 0


@dataclass(frozen=True, slots=True)
class TeacherCandidateV3:
    signature: str
    payload: GameAction | ChoiceResponse
    choice_option: ChoiceOption | None = None
    request_type: str = ""


@dataclass(frozen=True, slots=True)
class TeacherGameResultV3:
    winner: int | None
    decisions: int
    invalid_actions: int = 0
    illegal_choices: int = 0
    rule_exceptions: int = 0
    truncated: bool = False
    error_details: tuple[str, ...] = ()

    @property
    def structural_errors(self) -> int:
        return self.invalid_actions + self.illegal_choices + self.rule_exceptions

    @property
    def integrity_errors(self) -> int:
        return self.structural_errors + int(self.truncated)


class _SetupAI:
    def choose_action(self, state: GameState, player_idx: int) -> GameAction:
        actions = DEFAULT_GAME_ENGINE.legal_actions(
            state,
            player_idx,
            validate_effects=False,
        )
        if actions:
            return sorted(actions, key=lambda row: str(row.signature))[0]
        return GameAction(
            kind=PlayerAction.END_TURN,
            actor=player_idx,
            base_revision=state.revision,
        )


def _initialize_cards() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS)


def _finish_setup(
    state: GameState,
    ais: Sequence[Any],
    rng: RandomSource,
) -> None:
    for _ in range(128):
        if state.setup_stage == "COMPLETE":
            return
        pending = DEFAULT_GAME_ENGINE.pending_choice(state)
        if pending is not None:
            response = DEFAULT_GAME_ENGINE.choice_manager.default_choice_response(
                pending,
                rng,
            )
            step = DEFAULT_GAME_ENGINE.apply_choice(state, response, rng)
            if not step.success:
                raise RuntimeError(f"teacher_setup_choice_failed:{step.message}")
            continue
        actor = int(getattr(state, "setup_actor_idx", -1))
        if actor not in (0, 1):
            raise RuntimeError(f"teacher_setup_actor_invalid:{actor}")
        action = ais[actor].choose_action(state, actor)
        step = DEFAULT_GAME_ENGINE.apply_action(state, action.with_actor(actor), rng)
        if not step.success:
            raise RuntimeError(f"teacher_setup_action_failed:{step.message}")
    raise RuntimeError("teacher_setup_step_limit")


def _force_end_turn(state: GameState, actor: int) -> None:
    if state.phase not in (TurnPhase.MAIN, TurnPhase.ATTACK):
        return
    action = next(
        (
            row
            for row in DEFAULT_GAME_ENGINE.legal_actions(
                state,
                actor,
                validate_effects=False,
            )
            if row.kind_name == "END_TURN"
        ),
        None,
    )
    if action is not None:
        DEFAULT_GAME_ENGINE.apply_action(
            state,
            action,
            RandomSource(getattr(state, "_native_rng_state", 1)),
        )


@lru_cache(maxsize=1)
def _challenge_payloads() -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    catalog = native_catalog_payload()
    decks = json.loads(
        (REPO_ROOT / "godot" / "data" / "decks.json").read_text(
            encoding="utf-8"
        )
    )
    strategies = json.loads(
        (REPO_ROOT / "godot" / "data" / "ai_strategies.json").read_text(
            encoding="utf-8"
        )
    )
    return catalog, decks, strategies


class _NativeChallengeTeacher:
    def __init__(
        self,
        deck_key: str,
        seed: int,
        overrides: dict[str, Any] | None,
    ) -> None:
        try:
            import ptcg_ai_core
        except ImportError as exc:
            raise RuntimeError(
                "shared Challenge binding is not built; run "
                "research/deep_ai/tools/build_native_binding.ps1"
            ) from exc
        self._controller = ptcg_ai_core.ChallengeController()
        catalog, decks, strategies = _challenge_payloads()
        configured = self._controller.configure(catalog, decks, strategies)
        if not configured.get("success", False):
            raise RuntimeError(
                "teacher_challenge_config_failed:"
                + str(configured.get("error", "unknown"))
            )
        self._deck_key = str(deck_key)
        self._seed = int(seed)
        self._generation = 0
        self._decision_index = 0
        config = {**DEFAULT_V3_TEACHER_CONFIG, **dict(overrides or {})}
        self._node_budget = int(
            config.get("node_budget", config.get("search_node_budget", 192))
        )
        self._belief_samples = int(config.get("belief_samples", 3))
        self._match_id = f"teacher:{self._deck_key}:{self._seed}"
        self._controller.reset_match(self._match_id)

    def _request_base(self, state: GameState, actor: int) -> dict[str, Any]:
        self._generation += 1
        self._decision_index += 1
        return {
            "actor": int(actor),
            "revision": int(state.revision),
            "request_id": f"{self._match_id}:{self._decision_index}",
            "state": mask_native_snapshot(state_to_native_snapshot(state), actor),
            "deck_key": self._deck_key,
            "match_seed": self._seed,
            "seed": self._seed + self._decision_index * 104729,
            "match_instance_id": self._match_id,
            "engine": "turn_beam_v2",
            "node_budget": self._node_budget,
            "belief_samples": self._belief_samples,
        }

    def choose_action(self, state: GameState, actor: int) -> GameAction:
        actions = list(DEFAULT_GAME_ENGINE.legal_actions(state, actor))
        request = self._request_base(state, actor)
        request["kind"] = "action"
        request["actions"] = [serialize_game_action(row) for row in actions]
        result = self._controller.decide(request, self._generation)
        if not result.get("success", False):
            raise RuntimeError(
                "teacher_challenge_action_failed:"
                + str(result.get("error", "unknown"))
            )
        return deserialize_game_action(dict(result["action"]))

    def resolve_pending_action(
        self,
        state: GameState,
        request: ChoiceView,
    ) -> ChoiceResponse:
        base = self._request_base(state, int(request.player))
        base["kind"] = "choice"
        base["request_id"] = request.request_id
        base["choice"] = serialize_choice_view(request)
        result = self._controller.decide(base, self._generation)
        if not result.get("success", False):
            raise RuntimeError(
                "teacher_challenge_choice_failed:"
                + str(result.get("error", "unknown"))
            )
        return deserialize_choice_response(dict(result["choice_response"]))


def setup_teacher_game(task: TeacherTaskV3) -> GameState:
    """Create the reproducible public root used by teacher and benchmarks."""
    _initialize_cards()
    state = GameState()
    deck_by_player = (
        (task.deck_a, task.deck_b)
        if task.seat_a == 0
        else (task.deck_b, task.deck_a)
    )
    rng = RandomSource(task.seed)
    step = DEFAULT_GAME_ENGINE.begin_game(
        state,
        expand_deck(DECK_SPECS[deck_by_player[0]]),
        expand_deck(DECK_SPECS[deck_by_player[1]]),
        rng,
    )
    if not step.success:
        raise RuntimeError("teacher_setup_failed:" + str(step.message))
    state.public_deck_keys = deck_by_player
    turn_order = DEFAULT_GAME_ENGINE.pending_choice(state)
    if turn_order is not None and turn_order.request_type == "choose_turn_order":
        coin_winner = int(state.opening_coin_winner_idx)
        desired = "first" if coin_winner == int(task.first_player) else "second"
        option = next(
            (
                row
                for row in turn_order.options
                if row.option_id == f"turn:{desired}"
            ),
            None,
        )
        if option is None:
            raise RuntimeError("teacher_turn_order_option_missing")
        choice_step = DEFAULT_GAME_ENGINE.apply_choice(
            state,
            ChoiceResponse(turn_order.request_id, (option.option_id,)),
            rng,
        )
        if not choice_step.success:
            raise RuntimeError(
                "teacher_turn_order_failed:" + str(choice_step.message)
            )
    with rng.bind_state(state):
        _finish_setup(state, [_SetupAI(), _SetupAI()], rng)
    if int(state.first_player_idx) != int(task.first_player):
        raise RuntimeError("teacher_first_player_closure_failed")
    return state


def _advance_nondecision_phase(state: GameState) -> bool:
    if state.is_terminal() or DEFAULT_GAME_ENGINE.pending_choice(state) is not None:
        return False
    actor = (
        int(state.pending_promotions[0])
        if state.pending_promotions
        else int(state.active_player_idx)
    )
    if DEFAULT_GAME_ENGINE.legal_actions(state, actor, validate_effects=False):
        return False
    if state.phase not in (TurnPhase.MAIN, TurnPhase.ATTACK):
        return False
    _force_end_turn(state, actor)
    return True


def _challenge_ai(
    deck_key: str,
    seed: int,
    overrides: dict[str, Any] | None,
) -> Any:
    return _NativeChallengeTeacher(deck_key, seed, overrides)


def _authoritative_action(
    state: GameState,
    actor: int,
    ai: Any,
    authoritative: Sequence[GameAction],
) -> tuple[GameAction | None, GameAction | None]:
    actions = tuple(authoritative)
    proposal = ai.choose_action(state, actor)
    selected = next(
        (row for row in actions if row.signature == proposal.signature),
        None,
    )
    return selected, proposal


def _candidate_from_response(
    request: ChoiceView,
    response: ChoiceResponse,
) -> TeacherCandidateV3 | None:
    if response.request_id != request.request_id:
        return None
    if response.cancelled:
        if not request.can_cancel or response.option_ids:
            return None
        return TeacherCandidateV3(
            f"choice:{request.request_id}:cancel",
            ChoiceResponse(request.request_id, (), True),
            ChoiceOption(f"{request.request_id}:cancel", "cancel"),
            request.request_type,
        )
    counts = Counter(response.option_ids)
    selected: list[ChoiceOption] = []
    for option in request.options:
        count = counts.pop(option.option_id, 0)
        if count > 1 and not request.allow_duplicates:
            return None
        selected.extend([option] * count)
    if counts or not request.min_select <= len(selected) <= request.max_select:
        return None
    option_ids = tuple(row.option_id for row in selected)
    signature = "choice:" + request.request_id + ":" + "|".join(option_ids)
    return TeacherCandidateV3(
        signature,
        ChoiceResponse(request.request_id, option_ids),
        ChoiceOption(
            signature,
            " / ".join(row.label for row in selected),
            selected[0].ref if selected else None,
        ),
        request.request_type,
    )


def _choice_candidates(
    request: ChoiceView,
    preferred: ChoiceResponse | None = None,
) -> list[TeacherCandidateV3]:
    rows: list[TeacherCandidateV3] = []
    combination = (
        itertools.combinations_with_replacement
        if request.allow_duplicates
        else itertools.combinations
    )
    for size in range(request.min_select, request.max_select + 1):
        for selected in combination(tuple(request.options), size):
            option_ids = tuple(row.option_id for row in selected)
            signature = (
                "choice:" + request.request_id + ":" + "|".join(option_ids)
            )
            rows.append(
                TeacherCandidateV3(
                    signature,
                    ChoiceResponse(request.request_id, option_ids),
                    ChoiceOption(
                        signature,
                        " / ".join(row.label for row in selected),
                        selected[0].ref if selected else None,
                    ),
                    request.request_type,
                )
            )
            if len(rows) >= MAX_CHOICE_CANDIDATES:
                break
        if len(rows) >= MAX_CHOICE_CANDIDATES:
            break
    if request.can_cancel and len(rows) < MAX_CHOICE_CANDIDATES:
        cancel = _candidate_from_response(
            request,
            ChoiceResponse(request.request_id, (), True),
        )
        if cancel is not None:
            rows.append(cancel)
    if preferred is not None:
        preferred_candidate = _candidate_from_response(request, preferred)
        if preferred_candidate is not None and all(
            row.signature != preferred_candidate.signature for row in rows
        ):
            if len(rows) >= MAX_CHOICE_CANDIDATES:
                rows[-1] = preferred_candidate
            else:
                rows.append(preferred_candidate)
    return rows


def _selected_choice(
    candidates: Sequence[TeacherCandidateV3],
    response: ChoiceResponse,
) -> TeacherCandidateV3 | None:
    expected = Counter(response.option_ids)
    matches = [
        row
        for row in candidates
        if isinstance(row.payload, ChoiceResponse)
        and row.payload.request_id == response.request_id
        and bool(row.payload.cancelled) == bool(response.cancelled)
        and Counter(row.payload.option_ids) == expected
    ]
    return matches[0] if len(matches) == 1 else None


def _teacher_game_once(
    task: TeacherTaskV3,
    max_decisions: int,
    observer: Any,
    challenge_config: dict[str, Any],
) -> TeacherGameResultV3:
    state = setup_teacher_game(task)
    ais = [
        _challenge_ai(
            str(state.public_deck_keys[player]),
            task.seed + 31 + player,
            challenge_config,
        )
        for player in (0, 1)
    ]
    invalid_actions = 0
    illegal_choices = 0
    rule_exceptions = 0
    observed_decisions = 0
    errors: list[str] = []
    for ply in range(max_decisions):
        while _advance_nondecision_phase(state):
            if state.is_terminal():
                break
        if state.is_terminal():
            break
        request = DEFAULT_GAME_ENGINE.pending_choice(state)
        actor = (
            int(request.player)
            if request is not None
            else (
                int(state.pending_promotions[0])
                if state.pending_promotions
                else int(state.active_player_idx)
            )
        )
        ai = ais[actor]
        if request is not None:
            response = ai.resolve_pending_action(state, request)
            if not isinstance(response, ChoiceResponse):
                response = DEFAULT_GAME_ENGINE.choice_manager.default_choice_response(
                    request,
                    RandomSource(task.seed + ply),
                )
            candidates = _choice_candidates(request, response)
            selected = _selected_choice(candidates, response)
            if selected is None:
                illegal_choices += 1
                errors.append(
                    f"ply={ply}:teacher_choice_not_mapped:"
                    f"request={request.request_id}:"
                    f"response={serialize_choice_response(response)}"
                )
                break
            probabilities = {
                row.signature: float(row.signature == selected.signature)
                for row in candidates
            }
            observer(state, actor, request, candidates, probabilities, ply)
            observed_decisions += 1
            step = DEFAULT_GAME_ENGINE.apply_choice(
                state,
                selected.payload,
                RandomSource(task.seed + ply),
            )
            if not step.success:
                illegal_choices += 1
                errors.append(
                    f"ply={ply}:teacher_choice_apply_failed:"
                    f"{step.error_code}:{step.message}"
                )
                break
            continue

        actions = list(DEFAULT_GAME_ENGINE.legal_actions(state, actor))
        if not actions:
            _force_end_turn(state, actor)
            continue
        selected_action, proposal = _authoritative_action(
            state,
            actor,
            ai,
            actions,
        )
        if selected_action is None:
            invalid_actions += 1
            errors.append(
                f"ply={ply}:teacher_action_not_legal:selected={proposal!r}:"
                f"legal={[serialize_game_action(row) for row in actions]}"
            )
            break
        target_index = actions.index(selected_action)
        candidates = [
            TeacherCandidateV3(
                "teacher-action:"
                + hashlib.sha256(repr(row.signature).encode("utf-8")).hexdigest(),
                row,
            )
            for row in actions
        ]
        probabilities = {
            row.signature: float(index == target_index)
            for index, row in enumerate(candidates)
        }
        observer(state, actor, None, candidates, probabilities, ply)
        observed_decisions += 1
        try:
            choice_ordinal = 0

            def choose_response(
                sim_state: GameState,
                structured_request: ChoiceView,
            ) -> ChoiceResponse:
                nonlocal choice_ordinal, observed_decisions
                choice_ordinal += 1
                response = ai.resolve_pending_action(sim_state, structured_request)
                if not isinstance(response, ChoiceResponse):
                    response = (
                        DEFAULT_GAME_ENGINE.choice_manager.default_choice_response(
                            structured_request,
                            RandomSource(task.seed + ply * 101 + choice_ordinal),
                        )
                    )
                choice_candidates = _choice_candidates(
                    structured_request,
                    response,
                )
                chosen = _selected_choice(choice_candidates, response)
                if chosen is None:
                    raise RuntimeError(
                        "teacher_choice_not_in_candidates:"
                        f"request={serialize_choice_view(structured_request)}:"
                        f"response={serialize_choice_response(response)}"
                    )
                choice_probabilities = {
                    row.signature: float(row.signature == chosen.signature)
                    for row in choice_candidates
                }
                observer(
                    sim_state,
                    actor,
                    structured_request,
                    choice_candidates,
                    choice_probabilities,
                    ply * 100 + choice_ordinal,
                )
                observed_decisions += 1
                return chosen.payload

            action = (
                selected_action.with_actor(actor)
                if selected_action.actor not in (0, 1)
                else selected_action
            )
            step = DEFAULT_GAME_ENGINE.apply_action(
                state,
                action,
                RandomSource(task.seed + ply * 104729),
                auto_resolve=True,
                choice_policy=choose_response,
                auto_finish_attack=True,
            )
            if not step.success:
                invalid_actions += 1
                errors.append(
                    f"ply={ply}:teacher_action_apply_failed:"
                    f"{step.error_code}:{step.message}:"
                    f"action={serialize_game_action(selected_action)}"
                )
                break
        except Exception as exc:
            rule_exceptions += 1
            errors.append(
                f"ply={ply}:teacher_rule_exception:"
                f"{type(exc).__name__}:{exc}"
            )
            break
    truncated = not state.is_terminal()
    winner = None if truncated or state.result_status == "DRAW" else state.winner
    return TeacherGameResultV3(
        winner=winner,
        decisions=observed_decisions,
        invalid_actions=invalid_actions,
        illegal_choices=illegal_choices,
        rule_exceptions=rule_exceptions,
        truncated=truncated,
        error_details=tuple(errors),
    )


def teacher_tasks_v3(
    *,
    games_per_matchup: int,
    seed: int = 17,
) -> list[TeacherTaskV3]:
    tasks: list[TeacherTaskV3] = []
    matchups = [
        (left, right)
        for left_index, left in enumerate(RELEASE_DECKS)
        for right in RELEASE_DECKS[left_index:]
    ]
    for matchup_index, (deck_a, deck_b) in enumerate(matchups):
        for game_index in range(int(games_per_matchup)):
            closure = game_index % 4
            tasks.append(
                TeacherTaskV3(
                    game_id=f"g00-{matchup_index:02d}-{game_index:03d}",
                    generation=0,
                    deck_a=deck_a,
                    deck_b=deck_b,
                    seed=int(seed) + matchup_index * 10_000 + (game_index // 4) * 101,
                    seat_a=closure & 1,
                    first_player=(closure >> 1) & 1,
                )
            )
    return tasks


def generate_teacher_replay_v3(
    tasks: Iterable[TeacherTaskV3],
    replay: ReplayStoreV3,
    *,
    max_decisions: int = 512,
    workers: int = 1,
    challenge_config: dict[str, Any] | None = None,
) -> dict[str, Any]:
    effective_config = {
        **DEFAULT_V3_TEACHER_CONFIG,
        **dict(challenge_config or {}),
    }
    task_rows = tuple(tasks)
    worker_count = min(max(1, int(workers)), max(1, len(task_rows)))
    if worker_count > 1:
        replay.flush()
        chunks = [task_rows[index::worker_count] for index in range(worker_count)]
        chunks = [chunk for chunk in chunks if chunk]
        context = multiprocessing.get_context("spawn")
        with concurrent.futures.ProcessPoolExecutor(
            max_workers=len(chunks),
            mp_context=context,
        ) as executor:
            rows = list(
                executor.map(
                    _teacher_process_chunk,
                    chunks,
                    (str(replay.root),) * len(chunks),
                    (int(max_decisions),) * len(chunks),
                    (replay.capacity,) * len(chunks),
                    (replay.byte_capacity,) * len(chunks),
                    (replay.shard_samples,) * len(chunks),
                    (effective_config,) * len(chunks),
                )
            )
        replay.verify()
        return {
            "games": sum(row["games"] for row in rows),
            "samples": sum(row["samples"] for row in rows),
            "challenge_config": effective_config,
        }
    try:
        import ptcg_ai_core
    except ImportError as exc:
        raise RuntimeError("v3_teacher_requires_native_projection") from exc
    encoder = InformationSetEncoderV8()
    games = 0
    samples = 0
    for task in task_rows:
        pending: list[ReplaySampleV3] = []

        def observe(
            state: GameState,
            actor: int,
            request: ChoiceView | None,
            candidates: Sequence[TeacherCandidateV3],
            probabilities: dict[str, float],
            ply: int,
        ) -> None:
            observation = ptcg_ai_core.project_information_set(
                state_to_native_snapshot(state),
                int(actor),
            )["observation"]
            native_request = (
                serialize_choice_view(request) if request is not None else None
            )
            native_candidates: list[dict[str, Any]] = []
            policy: list[float] = []
            for candidate in candidates:
                payload = candidate.payload
                if isinstance(payload, GameAction):
                    native_candidates.append(serialize_game_action(payload))
                elif isinstance(payload, ChoiceResponse):
                    native_candidates.append(
                        {
                            "kind": "choice",
                            "selected_options": list(payload.option_ids),
                            "cancelled": bool(payload.cancelled),
                        }
                    )
                else:  # pragma: no cover - closed union above.
                    raise TypeError("v3_teacher_candidate_type_invalid")
                policy.append(float(probabilities[candidate.signature]))
            information = encoder.encode_information_set(observation, native_request)
            encoded_candidates = (
                encoder.encode_choices(
                    observation,
                    native_request,
                    native_candidates,
                )
                if native_request is not None
                else encoder.encode_actions(observation, native_candidates)
            )
            pending.append(
                ReplaySampleV3(
                    information,
                    encoded_candidates,
                    np.ascontiguousarray(policy, dtype=np.float32),
                    np.asarray((0.0, 1.0, 0.0), dtype=np.float32),
                    task.game_id,
                    int(task.seed),
                    int(ply),
                    int(actor),
                    int(information.actor_deck_id),
                    int(information.opponent_deck_id),
                    0,
                    int(task.generation),
                    min(3, int(observation.get("turn_number", 0)) // 6),
                    "teacher",
                )
            )

        result = _teacher_game_once(
            task,
            int(max_decisions),
            observe,
            effective_config,
        )
        if result.integrity_errors:
            raise RuntimeError(
                "v3_teacher_game_failed:"
                f"{task.game_id}:errors={result.integrity_errors}:"
                f"truncated={result.truncated}:details={result.error_details}"
            )
        finalized: list[ReplaySampleV3] = []
        for sample in pending:
            if result.winner is None:
                target = np.asarray((0.0, 1.0, 0.0), dtype=np.float32)
            elif int(result.winner) == sample.actor:
                target = np.asarray((1.0, 0.0, 0.0), dtype=np.float32)
            else:
                target = np.asarray((0.0, 0.0, 1.0), dtype=np.float32)
            finalized.append(replace(sample, wdl_target=target))
        replay.add_many(finalized)
        games += 1
        samples += len(finalized)
    replay.flush()
    return {
        "games": games,
        "samples": samples,
        "challenge_config": effective_config,
    }


def _teacher_process_chunk(
    tasks: tuple[TeacherTaskV3, ...],
    replay_root: str,
    max_decisions: int,
    capacity: int,
    byte_capacity: int,
    shard_samples: int,
    challenge_config: dict[str, Any],
) -> dict[str, Any]:
    replay = ReplayStoreV3(
        replay_root,
        capacity=capacity,
        byte_capacity=byte_capacity,
        shard_samples=shard_samples,
    )
    return generate_teacher_replay_v3(
        tasks,
        replay,
        max_decisions=max_decisions,
        workers=1,
        challenge_config=challenge_config,
    )

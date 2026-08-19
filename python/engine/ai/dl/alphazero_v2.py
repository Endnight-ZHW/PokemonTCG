"""End-to-end information-set AlphaZero v2 training pipeline."""
from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import random
import shutil
import time
from collections import Counter, deque
from contextlib import ExitStack
from concurrent.futures import (
    FIRST_COMPLETED,
    ProcessPoolExecutor,
    ThreadPoolExecutor,
    as_completed,
    wait,
)
from concurrent.futures.process import BrokenProcessPool
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, DECK_SPECS, expand_deck
from engine.action_codec import (
    serialize_choice_request_internal,
    serialize_choice_response,
    serialize_game_action,
)
from engine.actions import ChoiceResponse, GameAction
from engine.ai.challenge_ai import AIConfig, create_challenge_ai
from engine.ai.dl.infoset_encoder import InformationSetEncoderV7
from engine.ai.dl.integrity_v2 import is_recoverable_arena_truncation_event
from engine.ai.dl.inference_v2 import BatchedTorchEvaluator
from engine.ai.dl.native_bridge_v2 import (
    NativeBridgeError,
    NativeModelBackend,
    native_training_bridge_available,
)
from engine.ai.dl.puct_v2 import (
    InformationSetPUCT,
    PythonGameEnvironment,
    SearchCandidate,
    _choice_responses,
)
from engine.ai.observation import Observation
from engine.ai.training import finish_setup, force_end_turn
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import GameState
from engine.random_source import RandomSource
from engine.turn_manager import TurnManager

from .replay_v2 import (
    AlphaZeroSample,
    ReplayStoreV2,
    _atomic_torch_save,
    collate_samples,
)
from .v2_contract import (
    CHECKPOINT_VERSION,
    DEFAULT_C_PUCT,
    DEFAULT_REPLAY_CAPACITY,
    DEFAULT_TRAINING_SIMULATIONS,
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    MODEL_VARIANT,
    RELEASE_DECKS,
    TRAINER_ID,
    visit_temperature,
)

BOOTSTRAP_GENERATOR_VERSION = 5
BOOTSTRAP_SPLIT_SCHEMA = "game_seed_90_10_v1"
BOOTSTRAP_SHARD_SCHEMA = "alphazero_v2_teacher_game_v1"
BOOTSTRAP_LEGACY_V5_GENERATOR_SHA256 = (
    "a049beb58cbb1f4a804f6f5bc6027fc665dc7ead80b3c0f10984ebe6e46f1785"
)
BOOTSTRAP_LEGACY_V5_MONOLITHIC_SOURCE_SHA256 = (
    "7d7cc87a5516eb97369965aabfd27a17c49eb5bf9dae9343abc71ea69c8cf7c0"
)
# The frozen v5 cache predates protocol-bound parity fixes for energy effects.
# They match Godot's fixed first-``amount`` source semantics whenever an
# effect does not ask the player to select the source, across hand/deck/discard
# zones, and retain only the multiplicity of identical source cards that can
# occur in one explicit-source response.  This removes duplicate physical-copy
# choices without changing the observable choice or resulting state
# distribution.  Keep the migration explicit and pinned at both ends so a
# future edit cannot silently reuse it.
BOOTSTRAP_LEGACY_V5_PRIMITIVES_ENERGY_SHA256 = (
    "e5f46214db27c04455336bc61fa68d3b6f86cae6d74fcb905baf22a193ddd443"
)
BOOTSTRAP_PROTOCOL_BOUND_FIX_PRIMITIVES_ENERGY_SHA256 = (
    "00697e92330747e9be57d85ffe9f5a486852d8ea8b9dc1bc7bf02b6e2532dd65"
)
BOOTSTRAP_MAX_INFLIGHT_MULTIPLIER = 2
BOOTSTRAP_MAX_POOL_RESTARTS = 20
BOOTSTRAP_TRUNCATION_RESEED_ATTEMPTS = 8
BOOTSTRAP_TRUNCATION_CONFIG = {
    "policy": "deterministic_reseed_until_terminal",
    "reseed_attempts": BOOTSTRAP_TRUNCATION_RESEED_ATTEMPTS,
}
SELF_PLAY_TRUNCATION_RESEED_ATTEMPTS = 8
SELF_PLAY_EXTENDED_DECISION_CAP_MULTIPLIERS = (2, 4)
SELF_PLAY_TRUNCATION_CONFIG = {
    "policy": (
        "discard_and_deterministically_reseed_until_terminal_with_"
        "extended_final_caps"
    ),
    "reseed_attempts": SELF_PLAY_TRUNCATION_RESEED_ATTEMPTS,
    "extended_decision_cap_multipliers": list(
        SELF_PLAY_EXTENDED_DECISION_CAP_MULTIPLIERS
    ),
}
EVALUATION_EXTENDED_DECISION_CAP_MULTIPLIERS: tuple[int, ...] = ()
EVALUATION_DECISION_CAP_DRAW_DETAIL = "evaluation_decision_cap_draw"
EVALUATION_TRUNCATION_CONFIG = {
    "policy": "deterministic_decision_cap_draw",
    "extended_decision_cap_multipliers": list(
        EVALUATION_EXTENDED_DECISION_CAP_MULTIPLIERS
    ),
}
TRAINING_STATE_FORMAT = "alphazero_v2_training_state_v1"
SELF_PLAY_GAME_SHARD_FORMAT = "alphazero_v2_self_play_game_v1"
TEACHER_CONFIG = {
    "policy_path": None,
    "thinking_time_seconds": 0.0,
    "deterministic_search": True,
    "use_unified_planner": True,
    "search_algorithm": "hybrid",
    "search_node_budget": 180,
    "planner_max_depth": 8,
}


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(
            payload,
            handle,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


@dataclass(frozen=True)
class AlphaZeroV2Config:
    output_dir: str
    bootstrap_cache: str
    device: str = "cuda"
    seed: int = 17
    generations: int = 5
    games_per_matchup: int = 20
    historical_games_per_matchup: int = 4
    arena_games_per_matchup: int = 4
    final_games_per_deck: int = 600
    simulations: int = DEFAULT_TRAINING_SIMULATIONS
    c_puct: float = DEFAULT_C_PUCT
    actor_threads: int = 16
    concurrent_games: int = 64
    inference_target_batch: int = 128
    inference_max_batch: int = 256
    inference_coalesce_ms: float = 2.0
    native_inflight_leaves: int = 8
    batch_size: int = 512
    warmup_epochs: int = 5
    replay_epochs: int = 2
    replay_capacity: int = DEFAULT_REPLAY_CAPACITY
    learning_rate: float = 3e-4
    optimizer_warmup_steps: int = 2_000
    weight_decay: float = 1e-4
    gradient_clip: float = 1.0
    promotion_score_rate: float = 0.55
    release_score_rate: float = 0.53
    release_deck_score_rate: float = 0.50
    max_game_decisions: int = 512
    max_wall_seconds: float = 24.0 * 60.0 * 60.0
    require_native: bool = True

    @classmethod
    def release(
        cls,
        output_dir: str,
        bootstrap_cache: str,
        **overrides: Any,
    ) -> "AlphaZeroV2Config":
        return cls(output_dir, bootstrap_cache, **overrides)

    @classmethod
    def smoke(
        cls,
        output_dir: str,
        bootstrap_cache: str,
        **overrides: Any,
    ) -> "AlphaZeroV2Config":
        values = {
            "generations": 1,
            "games_per_matchup": 1,
            "historical_games_per_matchup": 0,
            "arena_games_per_matchup": 1,
            "final_games_per_deck": 1,
            "simulations": 2,
            "actor_threads": 2,
            "concurrent_games": 2,
            "inference_target_batch": 2,
            "inference_max_batch": 4,
            "native_inflight_leaves": 2,
            "batch_size": 8,
            "warmup_epochs": 1,
            "replay_epochs": 1,
            "max_game_decisions": 24,
            "require_native": False,
        }
        values.update(overrides)
        return cls(output_dir, bootstrap_cache, **values)

    def validate(self) -> None:
        if self.generations <= 0:
            raise ValueError("generations_must_be_positive")
        if self.games_per_matchup <= 0:
            raise ValueError("games_per_matchup_must_be_positive")
        if not (
            0
            <= self.historical_games_per_matchup
            <= self.games_per_matchup
        ):
            raise ValueError("invalid_historical_game_count")
        if self.batch_size <= 0 or self.simulations <= 0:
            raise ValueError("invalid_training_batch_or_simulations")
        if self.actor_threads <= 0 or self.concurrent_games <= 0:
            raise ValueError("invalid_native_training_concurrency")
        if (
            self.inference_target_batch <= 0
            or self.inference_max_batch < self.inference_target_batch
            or not math.isfinite(self.inference_coalesce_ms)
            or self.inference_coalesce_ms < 0.0
        ):
            raise ValueError("invalid_inference_batch_config")
        if (
            self.native_inflight_leaves <= 0
            or self.native_inflight_leaves > self.simulations
        ):
            raise ValueError("invalid_native_inflight_leaf_count")
        if not 0.0 < self.promotion_score_rate <= 1.0:
            raise ValueError("invalid_promotion_score_rate")


@dataclass(frozen=True)
class GameTask:
    game_id: str
    generation: int
    deck_a: str
    deck_b: str
    seed: int
    seat_a: int
    first_player: int
    opponent_version: int = 0


@dataclass(frozen=True)
class GameResult:
    task: GameTask
    winner: int | None
    samples: tuple[AlphaZeroSample, ...]
    decisions: int
    simulations: int
    invalid_actions: int = 0
    illegal_choices: int = 0
    rule_exceptions: int = 0
    decision_timeouts: int = 0
    hidden_information_violations: int = 0
    truncated: bool = False
    error_details: tuple[str, ...] = ()
    truncation_retries: int = 0

    @property
    def structural_errors(self) -> int:
        return (
            self.invalid_actions
            + self.illegal_choices
            + self.rule_exceptions
            + self.decision_timeouts
            + self.hidden_information_violations
        )

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
        if not actions:
            return GameAction(PlayerAction.END_TURN, {}, True, player_idx)
        return sorted(actions, key=lambda row: str(row.signature))[0]


def _initialize_cards() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS)


def _setup_game(task: GameTask) -> GameState:
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
        raise RuntimeError("setup_failed:" + str(step.message))
    state.public_deck_keys = deck_by_player
    turn_order = DEFAULT_GAME_ENGINE.pending_choice_request(state)
    if (
        turn_order is not None
        and turn_order.request_type == "choose_turn_order"
    ):
        coin_winner = int(state.opening_coin_winner_idx)
        desired = (
            "first"
            if coin_winner == int(task.first_player)
            else "second"
        )
        option = next(
            (
                row
                for row in turn_order.options
                if str(row.value) == desired
            ),
            None,
        )
        if option is None:
            raise RuntimeError("setup_turn_order_option_missing")
        choice_step = DEFAULT_GAME_ENGINE.apply_choice(
            state,
            ChoiceResponse(turn_order.request_id, (option.option_id,)),
            rng,
        )
        if not choice_step.success:
            raise RuntimeError(
                "setup_turn_order_failed:" + str(choice_step.message)
            )
    with rng.bind_state(state):
        finish_setup(
            state,
            TurnManager(state),
            [_SetupAI(), _SetupAI()],
            rng,
        )
    if int(state.first_player_idx) != int(task.first_player):
        raise RuntimeError("setup_first_player_closure_failed")
    return state


def _advance_nondecision_phase(state: GameState) -> bool:
    if state.is_terminal():
        return False
    if DEFAULT_GAME_ENGINE.pending_choice_request(state) is not None:
        return False
    actor = (
        int(state.pending_promotion_player)
        if int(state.pending_promotion_player) >= 0
        else int(state.active_player_idx)
    )
    if DEFAULT_GAME_ENGINE.legal_actions(
        state,
        actor,
        validate_effects=False,
    ):
        return False
    if state.phase == TurnPhase.DRAW:
        TurnManager(state).advance_phase()
        return True
    if state.phase not in (TurnPhase.MAIN, TurnPhase.ATTACK):
        TurnManager(state).advance_phase()
        return True
    force_end_turn(state, actor)
    return True


def _sample_from_decision(
    encoder: InformationSetEncoderV7,
    observation: Observation,
    candidates: Sequence[SearchCandidate],
    probabilities: dict[str, float],
    *,
    actor: int,
    deck_key: str,
    opponent_deck_key: str,
    generation: int,
    game_id: str,
    ply: int,
    source: str,
) -> AlphaZeroSample:
    information_set = encoder.encode_information_set(
        observation,
        deck_key,
    )
    if all(candidate.choice_option is not None for candidate in candidates):
        encoded_candidates = encoder.encode_choices(
            observation,
            candidates[0].request_type,
            [
                candidate.choice_option
                for candidate in candidates
                if candidate.choice_option is not None
            ],
        )
    else:
        encoded_candidates = encoder.encode_actions(
            observation,
            [candidate.payload for candidate in candidates],
        )
    policy = np.asarray(
        [probabilities[candidate.signature] for candidate in candidates],
        dtype=np.float32,
    )
    policy /= policy.sum()
    sample = AlphaZeroSample(
        information_set=information_set,
        candidates=encoded_candidates,
        policy_target=np.ascontiguousarray(policy),
        wdl_target=np.asarray((0.0, 1.0, 0.0), dtype=np.float32),
        actor=actor,
        deck_key=deck_key,
        opponent_deck_key=opponent_deck_key,
        generation=generation,
        game_id=game_id,
        ply=ply,
        source=source,
    )
    sample.validate()
    return sample


def play_self_play_game(
    task: GameTask,
    evaluator: Any,
    *,
    simulations: int,
    c_puct: float,
    max_decisions: int,
    training: bool,
) -> GameResult:
    state = _setup_game(task)
    environment = PythonGameEnvironment()
    search = InformationSetPUCT(
        evaluator,
        environment,
        simulations=simulations,
        c_puct=c_puct,
        training=training,
        seed=task.seed,
    )
    encoder = InformationSetEncoderV7()
    samples: list[AlphaZeroSample] = []
    total_simulations = 0
    decision_count = 0
    invalid_actions = 0
    illegal_choices = 0
    rule_exceptions = 0
    error_details: list[str] = []
    for ply in range(max_decisions):
        while _advance_nondecision_phase(state):
            if state.is_terminal():
                break
        if state.is_terminal():
            break
        actor = environment.actor(state)
        candidates = list(environment.candidates(state, actor))
        if not candidates:
            force_end_turn(state, actor)
            continue
        decision_count += 1
        observation = environment.observation(state, actor)
        pending_choice = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        native_method = (
            getattr(evaluator, "search_choice", None)
            if pending_choice is not None
            else getattr(evaluator, "search_action", None)
        )
        if callable(native_method):
            try:
                result = native_method(
                    state,
                    actor,
                    candidates,
                    simulations=simulations,
                    c_puct=c_puct,
                    seed=task.seed + ply * 104729,
                    training=training,
                    temperature=(
                        visit_temperature(int(state.turn_number))
                        if training
                        else 0.0
                    ),
                )
            except Exception as exc:
                # Preserve the original exception type for the run store and
                # integrity guard while making an asynchronous native failure
                # exactly replayable.  Choice contents stay out of the note so
                # no hidden card identity is copied into diagnostics.
                exc.add_note(
                    "self_play_search_context:"
                    f"game_id={task.game_id}:seed={task.seed}:ply={ply}:"
                    f"actor={actor}:turn={int(state.turn_number)}:"
                    f"phase={state.phase.name}:"
                    f"pending_choice={pending_choice is not None}"
                )
                raise
        else:
            result = search.search(
                state,
                actor,
                min_simulations=simulations,
            )
        total_simulations += result.simulations
        keys = tuple(state.public_deck_keys)
        if training:
            samples.append(
                _sample_from_decision(
                    encoder,
                    observation,
                    candidates,
                    result.probabilities,
                    actor=actor,
                    deck_key=str(keys[actor]),
                    opponent_deck_key=str(keys[1 - actor]),
                    generation=task.generation,
                    game_id=task.game_id,
                    ply=ply,
                    source="self_play",
                )
            )
        legal_signatures = {candidate.signature for candidate in candidates}
        if result.selected.signature not in legal_signatures:
            invalid_actions += 1
            error_details.append(
                "invalid_selected_signature:"
                f"game_id={task.game_id}:seed={task.seed}:ply={ply}:"
                f"actor={actor}:signature={result.selected.signature}"
            )
            break
        try:
            environment.apply(
                state,
                result.selected,
                task.seed + ply * 104729,
            )
        except Exception as exc:
            error_details.append(
                "authoritative_apply_failed:"
                f"game_id={task.game_id}:seed={task.seed}:ply={ply}:"
                f"actor={actor}:signature={result.selected.signature}:"
                f"payload_type={type(result.selected.payload).__name__}:"
                f"payload={result.selected.payload!r}:"
                f"exception={type(exc).__name__}:{exc}"
            )
            if isinstance(result.selected.payload, ChoiceResponse):
                illegal_choices += 1
            else:
                rule_exceptions += 1
            break

    truncated = not state.is_terminal()
    winner = None if truncated or state.result_status == "DRAW" else state.winner
    finalized = tuple(sample.with_winner(winner) for sample in samples)
    return GameResult(
        task=task,
        winner=winner,
        samples=finalized,
        decisions=decision_count,
        simulations=total_simulations,
        invalid_actions=invalid_actions,
        illegal_choices=illegal_choices,
        rule_exceptions=rule_exceptions,
        truncated=truncated,
        error_details=tuple(error_details),
    )


def _self_play_task_for_attempt(
    task: GameTask,
    attempt: int,
) -> GameTask:
    if int(attempt) == 0:
        return task
    seed = int.from_bytes(
        hashlib.sha256(
            (
                "alphazero-v2-self-play-reseed:"
                f"{task.game_id}:{task.seed}:{int(attempt)}"
            ).encode("ascii")
        ).digest()[:4],
        "little",
    ) & 0x7FFF_FFFF
    return replace(task, seed=seed)


def _play_self_play_with_retries(
    task: GameTask,
    evaluator: Any,
    *,
    simulations: int,
    c_puct: float,
    max_decisions: int,
    training: bool,
) -> GameResult:
    last_result: GameResult | None = None
    base_attempts = SELF_PLAY_TRUNCATION_RESEED_ATTEMPTS + 1
    total_attempts = (
        base_attempts
        + len(SELF_PLAY_EXTENDED_DECISION_CAP_MULTIPLIERS)
    )
    for attempt in range(total_attempts):
        effective_task = _self_play_task_for_attempt(task, attempt)
        decision_multiplier = (
            1
            if attempt < base_attempts
            else SELF_PLAY_EXTENDED_DECISION_CAP_MULTIPLIERS[
                attempt - base_attempts
            ]
        )
        result = play_self_play_game(
            effective_task,
            evaluator,
            simulations=simulations,
            c_puct=c_puct,
            max_decisions=max_decisions * decision_multiplier,
            training=training,
        )
        if result.structural_errors or not result.truncated:
            return replace(result, truncation_retries=attempt)
        last_result = result
    assert last_result is not None
    return replace(
        last_result,
        error_details=(
            *last_result.error_details,
            "self_play_truncation_reseed_attempts_exhausted:"
            f"{total_attempts}",
        ),
        truncation_retries=total_attempts - 1,
    )


def _play_arena_with_extended_decision_caps(
    task: GameTask,
    evaluator: Any,
    *,
    simulations: int,
    c_puct: float,
    max_decisions: int,
    training: bool,
) -> GameResult:
    """Adjudicate a structurally valid evaluation cap as a WDL draw."""

    if training:
        raise ValueError("arena_extended_caps_require_evaluation_mode")
    result = play_self_play_game(
        task,
        evaluator,
        simulations=simulations,
        c_puct=c_puct,
        max_decisions=max_decisions,
        training=False,
    )
    if result.structural_errors or not result.truncated:
        return replace(result, truncation_retries=0)
    return replace(
        result,
        winner=None,
        truncated=False,
        error_details=(
            *result.error_details,
            f"{EVALUATION_DECISION_CAP_DRAW_DETAIL}:{int(max_decisions)}",
        ),
        truncation_retries=0,
    )


def _play_league_with_extended_decision_caps(
    task: GameTask,
    evaluator: Any,
    *,
    simulations: int,
    c_puct: float,
    max_decisions: int,
) -> GameResult:
    """Apply the same deterministic cap-draw policy to final league."""

    result = play_model_vs_challenge_game(
        task,
        evaluator,
        simulations=simulations,
        c_puct=c_puct,
        max_decisions=max_decisions,
    )
    if result.structural_errors or not result.truncated:
        return replace(result, truncation_retries=0)
    return replace(
        result,
        winner=None,
        truncated=False,
        error_details=(
            *result.error_details,
            f"{EVALUATION_DECISION_CAP_DRAW_DETAIL}:{int(max_decisions)}",
        ),
        truncation_retries=0,
    )


def _is_evaluation_decision_cap_draw(result: GameResult) -> bool:
    prefix = EVALUATION_DECISION_CAP_DRAW_DETAIL + ":"
    return any(detail.startswith(prefix) for detail in result.error_details)


class _SeatEvaluator:
    def __init__(self, by_player: dict[int, Any]) -> None:
        self.by_player = dict(by_player)

    def evaluate(
        self,
        observation: Observation,
        candidates: Sequence[SearchCandidate],
        actor_deck_key: str | None,
    ):
        evaluator = self.by_player.get(int(observation.perspective))
        if evaluator is None:
            raise RuntimeError("missing_player_evaluator")
        return evaluator.evaluate(
            observation,
            candidates,
            actor_deck_key,
        )

    def search_action(self, state: GameState, actor: int, candidates, **kwargs):
        evaluator = self.by_player.get(int(actor))
        if evaluator is None or not hasattr(evaluator, "search_action"):
            raise RuntimeError("missing_player_native_search")
        return evaluator.search_action(state, actor, candidates, **kwargs)

    def search_choice(self, state: GameState, actor: int, candidates, **kwargs):
        preferred = self.by_player.get(int(actor))
        ordered = [preferred]
        ordered.extend(
            evaluator
            for player, evaluator in self.by_player.items()
            if player != int(actor) and evaluator is not preferred
        )
        continuation_error: NativeBridgeError | None = None
        for evaluator in ordered:
            if evaluator is None or not hasattr(evaluator, "search_choice"):
                continue
            try:
                return evaluator.search_choice(
                    state,
                    actor,
                    candidates,
                    **kwargs,
                )
            except NativeBridgeError as exc:
                if str(exc) != "native_choice_continuation_unavailable":
                    raise
                continuation_error = exc
        if continuation_error is not None:
            raise continuation_error
        raise RuntimeError("missing_player_native_choice_search")


def _challenge_ai(deck_key: str, seed: int):
    return create_challenge_ai(
        deck_key,
        AIConfig(
            deck_key=deck_key,
            random_seed=seed,
            **TEACHER_CONFIG,
        ),
    )


def _apply_challenge_action(
    state: GameState,
    actor: int,
    ai: Any,
) -> bool:
    authoritative = DEFAULT_GAME_ENGINE.legal_actions(state, actor)
    action, _proposal = _challenge_authoritative_action(
        state,
        actor,
        ai,
        authoritative,
    )
    if action is None:
        return False
    result = ai._apply_action_for_sim(state, actor, action)
    return result is not None and bool(result.success)


def _challenge_authoritative_action(
    state: GameState,
    actor: int,
    ai: Any,
    authoritative: Sequence[GameAction],
) -> tuple[GameAction | None, GameAction | None]:
    actions = tuple(authoritative)
    promotion_actions = [
        action
        for action in actions
        if (
            action.action.name
            if isinstance(action.action, PlayerAction)
            else str(action.action)
        ) == "PROMOTE"
    ]
    if promotion_actions and len(promotion_actions) == len(actions):
        player = state.get_player(actor)

        def promotion_value(action: GameAction) -> float:
            bench_index = int(action.params.get("bench_idx", -1))
            if (
                bench_index < 0
                or bench_index >= len(player.bench)
                or player.bench[bench_index] is None
            ):
                return float("-inf")
            scorer = getattr(ai, "_forced_promotion_value", None)
            if callable(scorer):
                return float(
                    scorer(state, actor, player.bench[bench_index])
                )
            return 0.0

        return max(promotion_actions, key=promotion_value), None
    proposal = ai.choose_action(state, actor)
    selected = next(
        (
            action
            for action in actions
            if action.signature == proposal.signature
        ),
        None,
    )
    return selected, proposal


def play_model_vs_challenge_game(
    task: GameTask,
    evaluator: Any,
    *,
    simulations: int,
    c_puct: float,
    max_decisions: int,
) -> GameResult:
    """Evaluate deck_a's model against the unchanged Challenge policy."""
    state = _setup_game(task)
    model_player = int(task.seat_a)
    challenge_player = 1 - model_player
    challenge_deck = str(state.public_deck_keys[challenge_player])
    challenge = _challenge_ai(challenge_deck, task.seed + 7919)
    environment = PythonGameEnvironment()
    search = InformationSetPUCT(
        evaluator,
        environment,
        simulations=simulations,
        c_puct=c_puct,
        training=False,
        seed=task.seed,
    )
    decisions = 0
    simulations_completed = 0
    invalid_actions = 0
    illegal_choices = 0
    rule_exceptions = 0
    for ply in range(max_decisions):
        while _advance_nondecision_phase(state):
            if state.is_terminal():
                break
        if state.is_terminal():
            break
        actor = environment.actor(state)
        if actor == challenge_player:
            try:
                if DEFAULT_GAME_ENGINE.pending_choice_request(state) is not None:
                    # Challenge's normal simulated application consumes its
                    # own choice chain. A remaining request here can only have
                    # been created by the model, so use the authoritative
                    # deterministic default rather than foreign hidden data.
                    request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
                    response = (
                        DEFAULT_GAME_ENGINE.choice_manager
                        .default_choice_response(
                            request,
                            RandomSource(task.seed + ply),
                        )
                    )
                    step = DEFAULT_GAME_ENGINE.apply_choice(
                        state,
                        response,
                        RandomSource(task.seed + ply),
                    )
                    if not step.success:
                        illegal_choices += 1
                        break
                elif not _apply_challenge_action(
                    state,
                    actor,
                    challenge,
                ):
                    invalid_actions += 1
                    break
            except Exception:
                rule_exceptions += 1
                break
            continue

        candidates = list(environment.candidates(state, actor))
        if not candidates:
            force_end_turn(state, actor)
            continue
        pending_choice = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        native_method = (
            getattr(evaluator, "search_choice", None)
            if pending_choice is not None
            else getattr(evaluator, "search_action", None)
        )
        if callable(native_method):
            result = native_method(
                state,
                actor,
                candidates,
                simulations=simulations,
                c_puct=c_puct,
                seed=task.seed + ply * 104729,
                training=False,
                temperature=0.0,
            )
        else:
            result = search.search(
                state,
                actor,
                min_simulations=simulations,
                temperature=0.0,
            )
        decisions += 1
        simulations_completed += result.simulations
        if result.selected.signature not in {
            candidate.signature for candidate in candidates
        }:
            invalid_actions += 1
            break
        try:
            environment.apply(
                state,
                result.selected,
                task.seed + ply * 104729,
            )
        except Exception:
            if isinstance(result.selected.payload, ChoiceResponse):
                illegal_choices += 1
            else:
                rule_exceptions += 1
            break
    truncated = not state.is_terminal()
    winner = None if truncated or state.result_status == "DRAW" else state.winner
    return GameResult(
        task=task,
        winner=winner,
        samples=(),
        decisions=decisions,
        simulations=simulations_completed,
        invalid_actions=invalid_actions,
        illegal_choices=illegal_choices,
        rule_exceptions=rule_exceptions,
        truncated=truncated,
    )


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bootstrap_fingerprint(repo_root: Path) -> dict[str, Any]:
    paths = [
        repo_root / "godot" / "data" / "cards.json",
        repo_root / "godot" / "data" / "decks.json",
        repo_root / "godot" / "data" / "effects.json",
        repo_root / "godot" / "data" / "vm_command_descriptors.json",
        repo_root / "python" / "engine" / "action_resolver.py",
        repo_root / "python" / "engine" / "actions.py",
        repo_root / "python" / "engine" / "choice_manager.py",
        repo_root / "python" / "engine" / "game_engine.py",
        repo_root / "python" / "engine" / "game_state.py",
        repo_root / "python" / "engine" / "turn_manager.py",
        repo_root / "python" / "engine" / "ai" / "challenge_ai.py",
        repo_root / "python" / "engine" / "ai" / "planner.py",
        Path(__file__).resolve(),
    ]
    paths.extend(
        sorted(
            (
                repo_root
                / "python"
                / "engine"
                / "commands"
            ).rglob("*.py")
        )
    )
    input_hashes = {
        str(path.relative_to(repo_root)).replace("\\", "/"):
            _file_sha256(path)
        for path in paths
    }
    generator_payload = {
        "version": BOOTSTRAP_GENERATOR_VERSION,
        "teacher_config": TEACHER_CONFIG,
        "truncation_config": BOOTSTRAP_TRUNCATION_CONFIG,
        "inputs": input_hashes,
    }
    return {
        "format": "alphazero_v2_bootstrap",
        "generator": BOOTSTRAP_GENERATOR_VERSION,
        "generator_sha256": hashlib.sha256(
            json.dumps(
                generator_payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest(),
        "games": 1_100,
        "games_per_matchup": 20,
        "release_decks": list(RELEASE_DECKS),
        "split_schema": BOOTSTRAP_SPLIT_SCHEMA,
        "teacher_config": dict(TEACHER_CONFIG),
        "truncation_config": dict(BOOTSTRAP_TRUNCATION_CONFIG),
        "inputs": input_hashes,
    }


def _bootstrap_fingerprint_matches(
    observed: dict[str, Any],
    expected: dict[str, Any],
) -> bool:
    if observed == expected:
        return True
    # Generator v5 originally hashed this entire monolithic module.  Training
    # orchestration changes therefore changed the calculated fingerprint even
    # when every teacher function, teacher setting and rules input remained
    # byte-for-byte compatible.  Accept only the one frozen v5 dataset hash,
    # and still require every non-monolithic input and metadata field to match.
    # Any teacher change must increment BOOTSTRAP_GENERATOR_VERSION.
    if (
        observed.get("generator") != BOOTSTRAP_GENERATOR_VERSION
        or observed.get("generator_sha256")
        != BOOTSTRAP_LEGACY_V5_GENERATOR_SHA256
    ):
        return False
    source_key = "python/engine/ai/dl/alphazero_v2.py"
    observed_inputs = dict(observed.get("inputs") or {})
    expected_inputs = dict(expected.get("inputs") or {})
    if (
        observed_inputs.get(source_key)
        != BOOTSTRAP_LEGACY_V5_MONOLITHIC_SOURCE_SHA256
        or set(observed_inputs) != set(expected_inputs)
    ):
        return False
    energy_key = "python/engine/commands/primitives_energy.py"
    compatible_energy_migration = (
        energy_key in observed_inputs
        and observed_inputs[energy_key]
        == BOOTSTRAP_LEGACY_V5_PRIMITIVES_ENERGY_SHA256
        and expected_inputs[energy_key]
        == BOOTSTRAP_PROTOCOL_BOUND_FIX_PRIMITIVES_ENERGY_SHA256
    )
    ignored_input_keys = {source_key}
    if compatible_energy_migration:
        ignored_input_keys.add(energy_key)
    if any(
        observed_inputs[key] != expected_inputs[key]
        for key in observed_inputs
        if key not in ignored_input_keys
    ):
        return False
    observed_metadata = {
        key: value
        for key, value in observed.items()
        if key not in {"generator_sha256", "inputs"}
    }
    expected_metadata = {
        key: value
        for key, value in expected.items()
        if key not in {"generator_sha256", "inputs"}
    }
    return observed_metadata == expected_metadata


def save_bootstrap_cache(
    path: str | Path,
    train_samples: Sequence[AlphaZeroSample],
    validation_samples: Sequence[AlphaZeroSample],
    *,
    repo_root: Path,
    split_manifest: dict[str, Any],
) -> None:
    import torch

    for rows in (train_samples, validation_samples):
        for sample in rows:
            sample.validate()
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    torch.save(
        {
            "metadata": bootstrap_fingerprint(repo_root),
            "split": dict(split_manifest),
            "train_samples": list(train_samples),
            "validation_samples": list(validation_samples),
        },
        temporary,
    )
    os.replace(temporary, destination)


def _split_teacher_results(
    results: Sequence[GameResult],
) -> tuple[
    list[AlphaZeroSample],
    list[AlphaZeroSample],
    dict[str, Any],
]:
    by_seed: dict[int, list[GameResult]] = {}
    for result in results:
        by_seed.setdefault(int(result.task.seed), []).append(result)
    if not by_seed:
        raise ValueError("bootstrap_split_empty")
    ranked_seeds = sorted(
        by_seed,
        key=lambda value: hashlib.sha256(
            f"alphazero-v2-bootstrap-split:{value}".encode("ascii")
        ).hexdigest(),
    )
    validation_seed_count = max(
        1,
        int(round(len(ranked_seeds) * 0.10)),
    )
    validation_seeds = set(ranked_seeds[:validation_seed_count])
    train_results = sorted(
        (
            result
            for seed, rows in by_seed.items()
            if seed not in validation_seeds
            for result in rows
        ),
        key=lambda row: row.task.game_id,
    )
    validation_results = sorted(
        (
            result
            for seed, rows in by_seed.items()
            if seed in validation_seeds
            for result in rows
        ),
        key=lambda row: row.task.game_id,
    )
    train_samples = [
        sample
        for result in train_results
        for sample in result.samples
    ]
    validation_samples = [
        sample
        for result in validation_results
        for sample in result.samples
    ]
    manifest = {
        "schema": BOOTSTRAP_SPLIT_SCHEMA,
        "train_games": [
            result.task.game_id for result in train_results
        ],
        "validation_games": [
            result.task.game_id for result in validation_results
        ],
        "train_seeds": sorted(
            seed for seed in by_seed if seed not in validation_seeds
        ),
        "validation_seeds": sorted(validation_seeds),
        "game_seeds": {
            result.task.game_id: int(result.task.seed)
            for result in sorted(
                results,
                key=lambda row: row.task.game_id,
            )
        },
    }
    return train_samples, validation_samples, manifest


def _teacher_game_once(task: GameTask, max_decisions: int) -> GameResult:
    from engine.ai.planner import _map_legacy_choice

    state = _setup_game(task)
    ais = [
        _challenge_ai(str(state.public_deck_keys[player]), task.seed + 31 + player)
        for player in (0, 1)
    ]
    encoder = InformationSetEncoderV7()
    samples: list[AlphaZeroSample] = []
    rule_exceptions = 0
    invalid_actions = 0
    illegal_choices = 0
    error_details: list[str] = []
    for ply in range(max_decisions):
        while _advance_nondecision_phase(state):
            if state.is_terminal():
                break
        if state.is_terminal():
            break
        request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        actor = (
            int(request.player)
            if request is not None
            else (
                int(state.pending_promotion_player)
                if int(state.pending_promotion_player) >= 0
                else int(state.active_player_idx)
            )
        )
        ai = ais[actor]
        keys = tuple(state.public_deck_keys)
        if request is not None:
            legacy_choice = ai.resolve_pending_action(
                state,
                request.legacy_request,
            )
            response = _map_legacy_choice(request, legacy_choice)
            if response is None:
                response = (
                    DEFAULT_GAME_ENGINE.choice_manager
                    .default_choice_response(
                        request,
                        RandomSource(task.seed + ply),
                    )
                )
            candidates = _choice_responses(
                request,
                preferred_response=response,
            )
            if not candidates:
                illegal_choices += 1
                error_details.append(
                    f"ply={ply}:teacher_choice_candidates_empty:"
                    f"request={request.request_id}"
                )
                break
            selected = _choice_candidate_for_response(
                candidates,
                response,
            )
            if selected is None:
                illegal_choices += 1
                error_details.append(
                    f"ply={ply}:teacher_choice_not_mapped:"
                    f"request={request.request_id}:"
                    f"response={serialize_choice_response(response)}"
                )
                break
            response = selected.payload
            probabilities = {
                candidate.signature: (
                    1.0 if candidate.signature == selected.signature else 0.0
                )
                for candidate in candidates
            }
            samples.append(
                _sample_from_decision(
                    encoder,
                    Observation.from_state(state, actor),
                    candidates,
                    probabilities,
                    actor=actor,
                    deck_key=str(keys[actor]),
                    opponent_deck_key=str(keys[1 - actor]),
                    generation=0,
                    game_id=task.game_id,
                    ply=ply,
                    source="challenge_bootstrap",
                )
            )
            step = DEFAULT_GAME_ENGINE.apply_choice(
                state,
                response,
                RandomSource(task.seed + ply),
            )
            if not step.success:
                illegal_choices += 1
                error_details.append(
                    f"ply={ply}:teacher_choice_apply_failed:"
                    f"{step.error_code}:{step.message}"
                )
                break
            continue

        actions = list(DEFAULT_GAME_ENGINE.legal_actions(state, actor))
        if not actions:
            force_end_turn(state, actor)
            continue
        selected_action, teacher_action = (
            _challenge_authoritative_action(
                state,
                actor,
                ai,
                actions,
            )
        )
        if selected_action is None:
            invalid_actions += 1
            error_details.append(
                f"ply={ply}:teacher_action_not_legal:"
                f"selected={teacher_action!r}:"
                f"legal={[serialize_game_action(action) for action in actions]}"
            )
            break
        target_index = actions.index(selected_action)
        candidates = [
            SearchCandidate(
                signature=(
                    "teacher-action:"
                    + hashlib.sha256(
                        repr(action.signature).encode("utf-8")
                    ).hexdigest()
                ),
                payload=action,
            )
            for action in actions
        ]
        probabilities = {
            candidate.signature: (
                1.0 if index == target_index else 0.0
            )
            for index, candidate in enumerate(candidates)
        }
        samples.append(
            _sample_from_decision(
                encoder,
                Observation.from_state(state, actor),
                candidates,
                probabilities,
                actor=actor,
                deck_key=str(keys[actor]),
                opponent_deck_key=str(keys[1 - actor]),
                generation=0,
                game_id=task.game_id,
                ply=ply,
                source="challenge_bootstrap",
            )
        )
        try:
            choice_ordinal = 0

            def choose_response(
                sim_state: GameState,
                structured_request: Any,
            ) -> ChoiceResponse:
                nonlocal choice_ordinal
                choice_ordinal += 1
                legacy_choice = ai.resolve_pending_action(
                    sim_state,
                    structured_request.legacy_request,
                )
                response = _map_legacy_choice(
                    structured_request,
                    legacy_choice,
                )
                if response is None:
                    response = (
                        DEFAULT_GAME_ENGINE.choice_manager
                        .default_choice_response(
                            structured_request,
                            RandomSource(
                                task.seed + ply * 101 + choice_ordinal
                            ),
                            )
                        )
                choice_candidates = _choice_responses(
                    structured_request,
                    preferred_response=response,
                )
                chosen = _choice_candidate_for_response(
                    choice_candidates,
                    response,
                )
                if chosen is None:
                    raise RuntimeError(
                        "teacher_choice_not_in_candidates:"
                        f"request={serialize_choice_request_internal(structured_request)}:"
                        f"legacy={legacy_choice!r}:"
                        f"response={serialize_choice_response(response)}"
                    )
                response = chosen.payload
                choice_probabilities = {
                    candidate.signature: (
                        1.0
                        if candidate.signature == chosen.signature
                        else 0.0
                    )
                    for candidate in choice_candidates
                }
                samples.append(
                    _sample_from_decision(
                        encoder,
                        Observation.from_state(sim_state, actor),
                        choice_candidates,
                        choice_probabilities,
                        actor=actor,
                        deck_key=str(keys[actor]),
                        opponent_deck_key=str(keys[1 - actor]),
                        generation=0,
                        game_id=task.game_id,
                        ply=ply * 100 + choice_ordinal,
                        source="challenge_bootstrap",
                    )
                )
                return response

            step = DEFAULT_GAME_ENGINE.apply_action(
                state,
                (
                    selected_action.with_actor(actor)
                    if selected_action.actor is None
                    else selected_action
                ),
                RandomSource(task.seed + ply * 104729),
                auto_resolve=True,
                choice_policy=choose_response,
                auto_finish_attack=True,
            )
            if not step.success:
                invalid_actions += 1
                error_details.append(
                    f"ply={ply}:teacher_action_apply_failed:"
                    f"{step.error_code}:{step.message}:"
                    f"action={serialize_game_action(selected_action)}"
                )
                break
        except Exception as exc:
            rule_exceptions += 1
            error_details.append(
                f"ply={ply}:teacher_rule_exception:"
                f"{type(exc).__name__}:{exc}"
            )
            break
    truncated = not state.is_terminal()
    winner = None if truncated or state.result_status == "DRAW" else state.winner
    return GameResult(
        task=task,
        winner=winner,
        samples=tuple(sample.with_winner(winner) for sample in samples),
        decisions=len(samples),
        simulations=0,
        invalid_actions=invalid_actions,
        illegal_choices=illegal_choices,
        rule_exceptions=rule_exceptions,
        truncated=truncated,
        error_details=tuple(error_details),
    )


def _teacher_task_for_attempt(
    task: GameTask,
    attempt: int,
) -> GameTask:
    if int(attempt) == 0:
        return task
    seed = int.from_bytes(
        hashlib.sha256(
            (
                "alphazero-v2-teacher-reseed:"
                f"{task.game_id}:{task.seed}:{int(attempt)}"
            ).encode("ascii")
        ).digest()[:4],
        "little",
    ) & 0x7FFF_FFFF
    return replace(task, seed=seed)


def _teacher_task_matches(
    observed: GameTask,
    expected: GameTask,
) -> bool:
    return any(
        observed == _teacher_task_for_attempt(expected, attempt)
        for attempt in range(BOOTSTRAP_TRUNCATION_RESEED_ATTEMPTS + 1)
    )


def _teacher_game(task: GameTask, max_decisions: int) -> GameResult:
    last_result: GameResult | None = None
    for attempt in range(BOOTSTRAP_TRUNCATION_RESEED_ATTEMPTS + 1):
        effective_task = _teacher_task_for_attempt(task, attempt)
        result = _teacher_game_once(effective_task, max_decisions)
        if result.structural_errors or not result.truncated:
            return result
        last_result = result
    assert last_result is not None
    return replace(
        last_result,
        error_details=(
            *last_result.error_details,
            "teacher_truncation_reseed_attempts_exhausted:"
            f"{BOOTSTRAP_TRUNCATION_RESEED_ATTEMPTS + 1}",
        ),
    )


def _choice_candidate_for_response(
    candidates: Sequence[SearchCandidate],
    response: ChoiceResponse,
) -> SearchCandidate | None:
    expected_ids = Counter(response.option_ids)
    matches = [
        candidate
        for candidate in candidates
        if isinstance(candidate.payload, ChoiceResponse)
        and candidate.payload.request_id == response.request_id
        and bool(candidate.payload.cancelled)
            == bool(response.cancelled)
        and Counter(candidate.payload.option_ids) == expected_ids
    ]
    if len(matches) != 1:
        return None
    return matches[0]


def _bootstrap_run_metadata(
    *,
    repo_root: Path,
    tasks: Sequence[GameTask],
    seed: int,
    max_decisions: int,
) -> dict[str, Any]:
    return {
        "schema": BOOTSTRAP_SHARD_SCHEMA,
        "fingerprint": bootstrap_fingerprint(repo_root),
        "seed": int(seed),
        "max_decisions": int(max_decisions),
        "tasks": [asdict(task) for task in tasks],
    }


def _bootstrap_run_sha256(metadata: dict[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(
            metadata,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


def _bootstrap_shard_directory(
    destination: Path,
    run_sha256: str,
) -> Path:
    return (
        destination.parent
        / f"{destination.name}.parts"
        / run_sha256[:16]
    )


def _bootstrap_shard_path(
    shard_directory: Path,
    task_index: int,
    task: GameTask,
) -> Path:
    return shard_directory / f"{task_index:04d}-{task.game_id}.pt"


def _save_bootstrap_result_shard(
    path: Path,
    result: GameResult,
    *,
    run_sha256: str,
) -> None:
    import torch

    if result.integrity_errors:
        raise ValueError("bootstrap_result_shard_requires_clean_game")
    for sample in result.samples:
        sample.validate()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    torch.save(
        {
            "schema": BOOTSTRAP_SHARD_SCHEMA,
            "run_sha256": run_sha256,
            "game_id": result.task.game_id,
            "result": result,
        },
        temporary,
    )
    os.replace(temporary, path)


def _load_bootstrap_result_shard(
    path: Path,
    *,
    expected_task: GameTask,
    run_sha256: str,
) -> GameResult:
    import torch

    payload = torch.load(path, map_location="cpu", weights_only=False)
    if payload.get("schema") != BOOTSTRAP_SHARD_SCHEMA:
        raise ValueError(f"bootstrap_shard_schema_mismatch:{path}")
    if payload.get("run_sha256") != run_sha256:
        raise ValueError(f"bootstrap_shard_fingerprint_mismatch:{path}")
    if payload.get("game_id") != expected_task.game_id:
        raise ValueError(f"bootstrap_shard_game_id_mismatch:{path}")
    result = payload.get("result")
    if (
        not isinstance(result, GameResult)
        or not _teacher_task_matches(result.task, expected_task)
    ):
        raise ValueError(f"bootstrap_shard_task_mismatch:{path}")
    if result.integrity_errors:
        raise ValueError(f"bootstrap_shard_contains_invalid_game:{path}")
    for sample in result.samples:
        sample.validate()
    return result


def _bootstrap_failure(
    task: GameTask,
    *,
    result: GameResult | None = None,
    exception: BaseException | None = None,
) -> dict[str, Any]:
    details = list(result.error_details[:3]) if result is not None else []
    return {
        "game_id": task.game_id,
        "structural_errors": (
            int(result.structural_errors) if result is not None else 1
        ),
        "truncated": bool(result.truncated) if result is not None else False,
        "exception": (
            f"{type(exception).__name__}:{exception}"
            if exception is not None
            else ""
        )[:2_000],
        "details": [str(detail)[:2_000] for detail in details],
    }


def generate_bootstrap_cache(
    path: str | Path,
    *,
    repo_root: Path,
    workers: int = 16,
    seed: int = 17,
    max_decisions: int = 512,
) -> dict[str, Any]:
    """Generate the one-time 1,100-game frozen Challenge dataset."""
    tasks = generation_tasks(0, 20, 0, seed)
    destination = Path(path)
    run_metadata = _bootstrap_run_metadata(
        repo_root=repo_root,
        tasks=tasks,
        seed=seed,
        max_decisions=max_decisions,
    )
    run_sha256 = _bootstrap_run_sha256(run_metadata)
    shard_directory = _bootstrap_shard_directory(
        destination,
        run_sha256,
    )
    shard_directory.mkdir(parents=True, exist_ok=True)
    manifest_path = shard_directory / "manifest.json"
    manifest = {
        **run_metadata,
        "run_sha256": run_sha256,
        "destination": destination.name,
    }
    if manifest_path.exists():
        observed_manifest = json.loads(
            manifest_path.read_text(encoding="utf-8")
        )
        if observed_manifest != manifest:
            raise ValueError("bootstrap_shard_manifest_mismatch")
    else:
        _atomic_write_json(manifest_path, manifest)

    task_rows = list(enumerate(tasks))
    shard_paths = {
        task.game_id: _bootstrap_shard_path(
            shard_directory,
            task_index,
            task,
        )
        for task_index, task in task_rows
    }
    completed_ids: set[str] = set()
    completed_samples = 0
    completed_decisions = 0
    for _task_index, task in task_rows:
        shard_path = shard_paths[task.game_id]
        if not shard_path.exists():
            continue
        result = _load_bootstrap_result_shard(
            shard_path,
            expected_task=task,
            run_sha256=run_sha256,
        )
        completed_ids.add(task.game_id)
        completed_samples += len(result.samples)
        completed_decisions += int(result.decisions)

    failures: list[dict[str, Any]] = []
    pool_restarts = 0

    def publish_progress(status: str) -> None:
        _atomic_write_json(
            shard_directory / "progress.json",
            {
                "schema": BOOTSTRAP_SHARD_SCHEMA,
                "run_sha256": run_sha256,
                "status": status,
                "updated_at": time.time(),
                "completed_games": len(completed_ids),
                "total_games": len(tasks),
                "pending_games": len(tasks) - len(completed_ids),
                "completed_samples": completed_samples,
                "completed_decisions": completed_decisions,
                "failed_games": len(failures),
                "failures": failures[:20],
                "pool_restarts": pool_restarts,
            },
        )

    publish_progress("running")
    pending_tasks = [
        task for task in tasks if task.game_id not in completed_ids
    ]
    # Challenge teacher games execute the authoritative Python rules engine
    # and are CPU-bound.  Threads serialize behind the GIL (a 16-worker run
    # still occupied only one core), so isolate this one-time frozen-data
    # stage in processes.  Neural self-play below remains the shared native
    # thread/GPU-broker design and never creates per-process CPU models.
    if pending_tasks:
        worker_count = max(1, int(workers))
        max_inflight = (
            worker_count * BOOTSTRAP_MAX_INFLIGHT_MULTIPLIER
        )
        task_queue = deque(pending_tasks)
        while task_queue:
            executor = ProcessPoolExecutor(max_workers=worker_count)
            future_tasks: dict[Any, GameTask] = {}
            pool_broken = False
            interrupted_tasks: list[GameTask] = []

            def fill_inflight() -> None:
                nonlocal pool_broken
                while task_queue and len(future_tasks) < max_inflight:
                    task = task_queue.popleft()
                    try:
                        future = executor.submit(
                            _teacher_game,
                            task,
                            max_decisions,
                        )
                    except BrokenProcessPool:
                        task_queue.appendleft(task)
                        pool_broken = True
                        interrupted_tasks.extend(
                            future_tasks.values()
                        )
                        future_tasks.clear()
                        return
                    future_tasks[future] = task

            try:
                fill_inflight()
                while future_tasks and not pool_broken:
                    completed, _pending = wait(
                        tuple(future_tasks),
                        return_when=FIRST_COMPLETED,
                    )
                    for future in completed:
                        task = future_tasks.pop(future)
                        try:
                            result = future.result()
                        except BrokenProcessPool:
                            pool_broken = True
                            interrupted_tasks = [
                                task,
                                *future_tasks.values(),
                            ]
                            future_tasks.clear()
                            break
                        except Exception as exc:
                            failures.append(
                                _bootstrap_failure(
                                    task,
                                    exception=exc,
                                )
                            )
                            publish_progress("running")
                            continue
                        if not _teacher_task_matches(result.task, task):
                            failures.append(
                                _bootstrap_failure(
                                    task,
                                    exception=ValueError(
                                        "bootstrap_worker_task_mismatch"
                                    ),
                                )
                            )
                            publish_progress("running")
                            continue
                        if result.integrity_errors:
                            failures.append(
                                _bootstrap_failure(task, result=result)
                            )
                            publish_progress("running")
                            continue
                        _save_bootstrap_result_shard(
                            shard_paths[task.game_id],
                            result,
                            run_sha256=run_sha256,
                        )
                        completed_ids.add(task.game_id)
                        completed_samples += len(result.samples)
                        completed_decisions += int(result.decisions)
                        publish_progress("running")
                    if not pool_broken:
                        fill_inflight()
            finally:
                executor.shutdown(
                    wait=not pool_broken,
                    cancel_futures=pool_broken,
                )

            if pool_broken:
                pool_restarts += 1
                if pool_restarts > BOOTSTRAP_MAX_POOL_RESTARTS:
                    publish_progress("failed")
                    raise RuntimeError(
                        "bootstrap_process_pool_restart_limit:"
                        f"{pool_restarts}"
                    )
                for task in reversed(interrupted_tasks):
                    if task.game_id not in completed_ids:
                        task_queue.appendleft(task)
                publish_progress("running")

    if failures:
        publish_progress("failed")
        raise RuntimeError(
            f"bootstrap_game_failures:{len(failures)}:"
            + json.dumps(
                failures[:10],
                ensure_ascii=False,
                sort_keys=True,
            )
        )
    if len(completed_ids) != len(tasks):
        publish_progress("failed")
        raise RuntimeError(
            "bootstrap_shards_incomplete:"
            f"{len(completed_ids)}/{len(tasks)}"
        )

    results = [
        _load_bootstrap_result_shard(
            shard_paths[task.game_id],
            expected_task=task,
            run_sha256=run_sha256,
        )
        for task in tasks
    ]
    train_samples, validation_samples, split_manifest = (
        _split_teacher_results(results)
    )
    if not train_samples or not validation_samples:
        raise RuntimeError("bootstrap_split_contains_empty_partition")
    save_bootstrap_cache(
        path,
        train_samples,
        validation_samples,
        repo_root=repo_root,
        split_manifest=split_manifest,
    )
    publish_progress("complete")
    return {
        "games": len(results),
        "samples": len(train_samples) + len(validation_samples),
        "train_games": len(split_manifest["train_games"]),
        "validation_games": len(split_manifest["validation_games"]),
        "train_samples": len(train_samples),
        "validation_samples": len(validation_samples),
        "path": str(path),
        "shard_directory": str(shard_directory),
        "resumed_games": len(tasks) - len(pending_tasks),
        "fingerprint": bootstrap_fingerprint(repo_root),
    }


def load_bootstrap_splits(
    path: str | Path,
    *,
    repo_root: Path,
) -> tuple[list[AlphaZeroSample], list[AlphaZeroSample]]:
    import torch

    payload = torch.load(path, map_location="cpu", weights_only=False)
    expected = bootstrap_fingerprint(repo_root)
    if not _bootstrap_fingerprint_matches(
        dict(payload.get("metadata") or {}),
        expected,
    ):
        raise ValueError("bootstrap_cache_fingerprint_mismatch")
    split = dict(payload.get("split") or {})
    if split.get("schema") != BOOTSTRAP_SPLIT_SCHEMA:
        raise ValueError("bootstrap_cache_split_schema_mismatch")
    train_game_ids = set(split.get("train_games") or ())
    validation_game_ids = set(split.get("validation_games") or ())
    train_seeds = set(split.get("train_seeds") or ())
    validation_seeds = set(split.get("validation_seeds") or ())
    if (
        not train_game_ids
        or not validation_game_ids
        or train_game_ids & validation_game_ids
        or not train_seeds
        or not validation_seeds
        or train_seeds & validation_seeds
    ):
        raise ValueError("bootstrap_cache_split_invalid")
    partitions = (
        (
            list(payload.get("train_samples") or ()),
            train_game_ids,
            "train",
        ),
        (
            list(payload.get("validation_samples") or ()),
            validation_game_ids,
            "validation",
        ),
    )
    for samples, allowed_games, partition in partitions:
        if not samples:
            raise ValueError(
                f"bootstrap_cache_{partition}_samples_empty"
            )
        observed_games: set[str] = set()
        for sample in samples:
            sample.validate()
            if sample.source != "challenge_bootstrap":
                raise ValueError("bootstrap_cache_source_mismatch")
            if sample.game_id not in allowed_games:
                raise ValueError(
                    "bootstrap_cache_sample_split_mismatch"
                )
            observed_games.add(sample.game_id)
        if not observed_games:
            raise ValueError(
                f"bootstrap_cache_{partition}_games_empty"
            )
    return partitions[0][0], partitions[1][0]


def load_bootstrap_cache(
    path: str | Path,
    *,
    repo_root: Path,
    split: str = "train",
) -> list[AlphaZeroSample]:
    train_samples, validation_samples = load_bootstrap_splits(
        path,
        repo_root=repo_root,
    )
    if split == "train":
        return train_samples
    if split == "validation":
        return validation_samples
    raise ValueError(f"unknown_bootstrap_split:{split}")


def _matchups() -> list[tuple[str, str]]:
    return [
        (left, right)
        for left_index, left in enumerate(RELEASE_DECKS)
        for right in RELEASE_DECKS[left_index:]
    ]


def generation_tasks(
    generation: int,
    games_per_matchup: int,
    historical_games_per_matchup: int,
    seed: int,
) -> list[GameTask]:
    tasks: list[GameTask] = []
    current_games = games_per_matchup - historical_games_per_matchup
    for matchup_index, (deck_a, deck_b) in enumerate(_matchups()):
        for game_index in range(games_per_matchup):
            closure = game_index % 4
            task_seed = (
                int(seed)
                + generation * 10_000_000
                + matchup_index * 10_000
                + (game_index // 4) * 101
            )
            tasks.append(
                GameTask(
                    game_id=(
                        f"g{generation:02d}-{matchup_index:02d}-"
                        f"{game_index:03d}"
                    ),
                    generation=generation,
                    deck_a=deck_a,
                    deck_b=deck_b,
                    seed=task_seed,
                    seat_a=closure & 1,
                    first_player=(closure >> 1) & 1,
                    opponent_version=(
                        0
                        if game_index < current_games
                        else -1 - (matchup_index % 3)
                    ),
                )
            )
    return tasks


def partition_game_tasks(
    tasks: Sequence[GameTask],
    worker_index: int,
    worker_count: int,
) -> tuple[GameTask, ...]:
    if not 0 <= int(worker_index) < int(worker_count):
        raise ValueError("invalid_self_play_partition")
    return tuple(tasks[int(worker_index) :: int(worker_count)])


def final_league_tasks(
    generations: int,
    final_games_per_deck: int,
    seed: int,
) -> list[GameTask]:
    games_per_matchup = max(
        1,
        int(final_games_per_deck) // len(RELEASE_DECKS),
    )
    tasks: list[GameTask] = []
    for deck_index, deck in enumerate(RELEASE_DECKS):
        for opponent_index, opponent in enumerate(RELEASE_DECKS):
            for game_index in range(games_per_matchup):
                closure = game_index % 4
                tasks.append(
                    GameTask(
                        game_id=(
                            f"final-{deck_index:02d}-"
                            f"{opponent_index:02d}-{game_index:03d}"
                        ),
                        generation=int(generations) + 1,
                        deck_a=deck,
                        deck_b=opponent,
                        seed=(
                            int(seed)
                            + 900_000_000
                            + deck_index * 100_000
                            + opponent_index * 1_000
                            + (game_index // 4) * 101
                        ),
                        seat_a=closure & 1,
                        first_player=(closure >> 1) & 1,
                    )
                )
    return tasks


def _model_inputs(batch: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(
        batch[name]
        for name in (
            "state_global",
            "entity_numeric",
            "entity_card_ids",
            "entity_type_ids",
            "candidate_numeric",
            "candidate_card_ids",
            "candidate_type_ids",
            "candidate_refs",
            "candidate_mask",
            "actor_deck_id",
            "opponent_deck_id",
        )
    )


def learning_rate_multiplier(
    global_step: int,
    warmup_steps: int,
    total_steps: int,
) -> float:
    step = max(0, int(global_step))
    warmup = max(0, int(warmup_steps))
    horizon = max(warmup + 1, int(total_steps))
    if warmup > 0 and step < warmup:
        return (step + 1) / warmup
    progress = (step - warmup) / max(1, horizon - warmup - 1)
    progress = min(1.0, max(0.0, progress))
    return 0.5 * (1.0 + math.cos(math.pi * progress))


def _prefetched_training_batches(
    samples: Sequence[AlphaZeroSample],
    *,
    batch_size: int,
    device: str,
) -> Iterable[dict[str, Any]]:
    """Overlap replay collation/pinning with the preceding GPU step.

    Replay samples are validated when their shard is written and again when it
    is loaded.  Repeating the full array validation for every epoch needlessly
    scans the same samples, so the hot training path only collates them here.
    The single producer keeps at most one prepared batch ahead and therefore
    preserves batch order and the optimizer's exact update sequence.
    """

    starts = range(0, len(samples), int(batch_size))
    iterator = iter(starts)
    try:
        first_start = next(iterator)
    except StopIteration:
        return

    def prepare(start: int) -> dict[str, Any]:
        return collate_samples(
            samples[start:start + int(batch_size)],
            device=device,
            validate=False,
            move_to_device=False,
        )

    with ThreadPoolExecutor(
        max_workers=1,
        thread_name_prefix="replay-prefetch",
    ) as executor:
        pending = executor.submit(prepare, first_start)
        for next_start in iterator:
            batch = pending.result()
            pending = executor.submit(prepare, next_start)
            yield {
                name: value.to(device, non_blocking=True)
                for name, value in batch.items()
            }
        batch = pending.result()
        yield {
            name: value.to(device, non_blocking=True)
            for name, value in batch.items()
        }


def train_model(
    model: Any,
    samples: Sequence[AlphaZeroSample],
    config: AlphaZeroV2Config,
    *,
    epochs: int,
    optimizer: Any | None = None,
    global_step: int = 0,
    schedule_total_steps: int | None = None,
) -> tuple[dict[str, float], Any, int]:
    import torch
    import torch.nn.functional as functional

    if not samples:
        raise ValueError("training_samples_empty")
    optimizer = optimizer or torch.optim.AdamW(
        model.parameters(),
        lr=config.learning_rate,
        weight_decay=config.weight_decay,
    )
    model.train()
    scaler = torch.amp.GradScaler(
        "cuda",
        enabled=str(config.device).startswith("cuda"),
    )
    local_steps = (
        math.ceil(len(samples) / config.batch_size) * max(1, epochs)
    )
    total_steps = max(
        config.optimizer_warmup_steps + 1,
        int(
            schedule_total_steps
            if schedule_total_steps is not None
            else global_step + local_steps
        ),
    )
    policy_loss_sum = 0.0
    value_loss_sum = 0.0
    steps = 0
    final_learning_rate = 0.0
    rows = list(samples)
    rng = random.Random(config.seed + global_step)
    for _epoch in range(max(1, int(epochs))):
        rng.shuffle(rows)
        for batch in _prefetched_training_batches(
            rows,
            batch_size=config.batch_size,
            device=config.device,
        ):
            multiplier = learning_rate_multiplier(
                global_step,
                config.optimizer_warmup_steps,
                total_steps,
            )
            final_learning_rate = config.learning_rate * multiplier
            for group in optimizer.param_groups:
                group["lr"] = final_learning_rate

            optimizer.zero_grad(set_to_none=True)
            with torch.autocast(
                device_type=(
                    "cuda"
                    if str(config.device).startswith("cuda")
                    else "cpu"
                ),
                dtype=torch.float16,
                enabled=str(config.device).startswith("cuda"),
            ):
                policy_logits, wdl_logits = model(*_model_inputs(batch))
                log_policy = functional.log_softmax(
                    policy_logits.float(),
                    dim=-1,
                )
                policy_loss = -(
                    batch["policy_target"] * log_policy
                ).sum(dim=-1).mean()
                value_loss = -(
                    batch["wdl_target"]
                    * functional.log_softmax(wdl_logits.float(), dim=-1)
                ).sum(dim=-1).mean()
                loss = policy_loss + value_loss
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(
                model.parameters(),
                config.gradient_clip,
            )
            scaler.step(optimizer)
            scaler.update()
            policy_loss_sum += float(policy_loss.detach().cpu())
            value_loss_sum += float(value_loss.detach().cpu())
            steps += 1
            global_step += 1
    model.eval()
    return (
        {
            "policy_loss": policy_loss_sum / max(1, steps),
            "wdl_loss": value_loss_sum / max(1, steps),
            "steps": float(steps),
            "final_learning_rate": final_learning_rate,
            "schedule_total_steps": float(total_steps),
        },
        optimizer,
        global_step,
    )


def evaluate_model(
    model: Any,
    samples: Sequence[AlphaZeroSample],
    config: AlphaZeroV2Config,
) -> dict[str, float]:
    import torch
    import torch.nn.functional as functional

    if not samples:
        raise ValueError("validation_samples_empty")
    model.eval()
    policy_loss_sum = 0.0
    value_loss_sum = 0.0
    batches = 0
    with torch.no_grad():
        for start in range(0, len(samples), config.batch_size):
            batch = collate_samples(
                samples[start:start + config.batch_size],
                device=config.device,
            )
            with torch.autocast(
                device_type=(
                    "cuda"
                    if str(config.device).startswith("cuda")
                    else "cpu"
                ),
                dtype=torch.float16,
                enabled=str(config.device).startswith("cuda"),
            ):
                policy_logits, wdl_logits = model(
                    *_model_inputs(batch)
                )
                policy_loss = -(
                    batch["policy_target"]
                    * functional.log_softmax(
                        policy_logits.float(),
                        dim=-1,
                    )
                ).sum(dim=-1).mean()
                value_loss = -(
                    batch["wdl_target"]
                    * functional.log_softmax(
                        wdl_logits.float(),
                        dim=-1,
                    )
                ).sum(dim=-1).mean()
            policy_loss_sum += float(policy_loss.cpu())
            value_loss_sum += float(value_loss.cpu())
            batches += 1
    return {
        "policy_loss": policy_loss_sum / max(1, batches),
        "wdl_loss": value_loss_sum / max(1, batches),
        "samples": float(len(samples)),
    }


def _native_available() -> bool:
    return native_training_bridge_available()


def _native_production_ready() -> bool:
    try:
        import ptcg_ai_core  # type: ignore

        return bool(ptcg_ai_core.production_ready())
    except Exception:
        return False


def _native_blockers() -> tuple[str, ...]:
    try:
        import ptcg_ai_core  # type: ignore

        return tuple(str(item) for item in ptcg_ai_core.production_blockers())
    except Exception as exc:
        return (f"native_module_unavailable:{type(exc).__name__}",)


class AlphaZeroV2Trainer:
    def __init__(self, config: AlphaZeroV2Config) -> None:
        config.validate()
        self.config = config
        self.output_dir = Path(config.output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.events_path = self.output_dir / "events.jsonl"
        self.training_state_path = self.output_dir / "training_state.json"
        self.started = time.perf_counter()
        self._elapsed_before_resume = 0.0
        self._wall_clock_budget_exceeded = False
        self.global_step = 0
        fingerprint_config = asdict(config)
        fingerprint_config["output_dir"] = str(self.output_dir.resolve())
        fingerprint_config["bootstrap_cache"] = str(
            Path(config.bootstrap_cache).resolve()
        )
        self._training_fingerprint = hashlib.sha256(
            json.dumps(
                fingerprint_config,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        self._native_simulation_limiter = None
        if _native_available():
            import ptcg_ai_core  # type: ignore

            self._native_simulation_limiter = (
                ptcg_ai_core.NativeSearchLimiter(
                    max(1, int(config.actor_threads))
                )
            )

    def _resolve_training_checkpoint(self, relative: str) -> Path:
        candidate = Path(relative)
        if candidate.is_absolute():
            raise RuntimeError("training_state_checkpoint_must_be_relative")
        resolved = (self.output_dir / candidate).resolve()
        root = self.output_dir.resolve()
        if resolved != root and root not in resolved.parents:
            raise RuntimeError("training_state_checkpoint_outside_run")
        if not resolved.is_file():
            raise RuntimeError(
                "training_state_checkpoint_missing:" + str(candidate)
            )
        return resolved

    @staticmethod
    def _file_sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest()

    def _generation_shard_fingerprint(
        self,
        generation: int,
        accepted_checkpoints: Sequence[str],
    ) -> str:
        checkpoint_rows = []
        for relative in accepted_checkpoints:
            path = self._resolve_training_checkpoint(relative)
            checkpoint_rows.append({
                "path": str(relative),
                "sha256": self._file_sha256(path),
            })
        payload = {
            "training_fingerprint": self._training_fingerprint,
            "generation": int(generation),
            "accepted_checkpoints": checkpoint_rows,
        }
        return hashlib.sha256(
            json.dumps(
                payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()

    def _load_training_state(self) -> dict[str, Any] | None:
        if not self.training_state_path.is_file():
            return None
        payload = json.loads(
            self.training_state_path.read_text(encoding="utf-8")
        )
        if (
            not isinstance(payload, dict)
            or payload.get("format") != TRAINING_STATE_FORMAT
            or payload.get("training_fingerprint")
                != self._training_fingerprint
        ):
            raise RuntimeError("training_state_fingerprint_mismatch")
        next_generation = payload.get("next_generation")
        global_step = payload.get("global_step")
        accepted = payload.get("accepted_checkpoints")
        rows = payload.get("generation_rows")
        phase = payload.get("phase")
        elapsed_seconds = payload.get("elapsed_seconds")
        if (
            type(next_generation) is not int
            or not 1 <= next_generation <= self.config.generations + 1
            or type(global_step) is not int
            or global_step < 0
            or not isinstance(accepted, list)
            or not accepted
            or len(accepted) > 4
            or any(not isinstance(row, str) or not row for row in accepted)
            or not isinstance(rows, list)
            or len(rows) != next_generation - 1
            or any(not isinstance(row, dict) for row in rows)
            or phase not in {"self_play", "post_generations", "complete"}
            or type(elapsed_seconds) not in (int, float)
            or not math.isfinite(float(elapsed_seconds))
            or float(elapsed_seconds) < 0.0
        ):
            raise RuntimeError("training_state_invalid")
        for relative in accepted:
            self._resolve_training_checkpoint(relative)
        if payload.get("champion_checkpoint") != accepted[-1]:
            raise RuntimeError("training_state_champion_mismatch")
        return payload

    def _write_training_state(
        self,
        *,
        next_generation: int,
        global_step: int,
        accepted_checkpoints: Sequence[str],
        generation_rows: Sequence[dict[str, Any]],
        phase: str | None = None,
    ) -> None:
        chosen_phase = phase or (
            "post_generations"
            if int(next_generation) > self.config.generations
            else "self_play"
        )
        _atomic_write_json(
            self.training_state_path,
            {
                "format": TRAINING_STATE_FORMAT,
                "training_fingerprint": self._training_fingerprint,
                "phase": chosen_phase,
                "next_generation": int(next_generation),
                "global_step": int(global_step),
                "champion_checkpoint": str(accepted_checkpoints[-1]),
                "accepted_checkpoints": list(accepted_checkpoints[-4:]),
                "generation_rows": list(generation_rows),
                "elapsed_seconds": self._elapsed_seconds(),
            },
        )

    def _elapsed_seconds(self) -> float:
        return self._elapsed_before_resume + (
            time.perf_counter() - self.started
        )

    def run(self) -> dict[str, Any]:
        import torch
        from engine.ai.dl.model_v2 import (
            create_model,
            load_checkpoint,
            save_checkpoint,
        )

        if self.config.require_native and not _native_available():
            raise RuntimeError(
                "release_preset_requires_ptcg_ai_core;"
                + ",".join(_native_blockers())
            )
        if self.config.device.startswith("cuda") and not torch.cuda.is_available():
            raise RuntimeError("cuda_device_required_but_unavailable")
        repo_root = Path(__file__).resolve().parents[4]
        bootstrap, bootstrap_validation = load_bootstrap_splits(
            self.config.bootstrap_cache,
            repo_root=repo_root,
        )
        optimizer_schedule_steps = max(
            self.config.optimizer_warmup_steps + 1,
            (
                math.ceil(len(bootstrap) / self.config.batch_size)
                * self.config.warmup_epochs
            )
            + (
                math.ceil(
                    self.config.replay_capacity / self.config.batch_size
                )
                * self.config.replay_epochs
                * self.config.generations
            ),
        )
        training_state = self._load_training_state()
        if training_state is not None:
            self._elapsed_before_resume = float(
                training_state["elapsed_seconds"]
            )
            if training_state["phase"] == "complete":
                summary_path = self.output_dir / "summary.json"
                if not summary_path.is_file():
                    raise RuntimeError("completed_training_summary_missing")
                return json.loads(summary_path.read_text(encoding="utf-8"))
        self._event(
            "run_started",
            config=asdict(self.config),
            resumed=training_state is not None,
        )
        replay = ReplayStoreV2(
            self.output_dir / "replay",
            capacity=self.config.replay_capacity,
            keep_generations=3,
            seed=self.config.seed,
        )
        if training_state is None:
            model = create_model().to(self.config.device)
            metrics, _optimizer, self.global_step = train_model(
                model,
                bootstrap,
                self.config,
                epochs=self.config.warmup_epochs,
                global_step=self.global_step,
                schedule_total_steps=optimizer_schedule_steps,
            )
            validation_metrics = evaluate_model(
                model,
                bootstrap_validation,
                self.config,
            )
            self._event(
                "bootstrap_complete",
                **metrics,
                samples=len(bootstrap),
                validation={
                    **validation_metrics,
                    "samples": len(bootstrap_validation),
                },
            )
            initial_checkpoint = "champion-g000.pt"
            save_checkpoint(
                str(self.output_dir / initial_checkpoint),
                model,
                {"generation": 0, "accepted": True},
            )
            champion = model
            history: list[Any] = [copy.deepcopy(model).cpu()]
            accepted_checkpoints = [initial_checkpoint]
            generation_rows: list[dict[str, Any]] = []
            next_generation = 1
            self._write_training_state(
                next_generation=next_generation,
                global_step=self.global_step,
                accepted_checkpoints=accepted_checkpoints,
                generation_rows=generation_rows,
            )
        else:
            self.global_step = int(training_state["global_step"])
            accepted_checkpoints = list(
                training_state["accepted_checkpoints"]
            )
            generation_rows = list(training_state["generation_rows"])
            next_generation = int(training_state["next_generation"])
            champion, _payload = load_checkpoint(
                str(self._resolve_training_checkpoint(
                    str(training_state["champion_checkpoint"])
                )),
                device=self.config.device,
            )
            history = [
                load_checkpoint(
                    str(self._resolve_training_checkpoint(relative)),
                    device="cpu",
                )[0]
                for relative in accepted_checkpoints
            ]
            replay.load(current_generation=next_generation - 1)
            self._event(
                "run_resumed",
                next_generation=next_generation,
                global_step=self.global_step,
                accepted_checkpoints=accepted_checkpoints,
                replay_samples=len(replay),
            )

        for generation in range(
            next_generation,
            self.config.generations + 1,
        ):
            self._check_wall_clock()
            tasks = generation_tasks(
                generation,
                self.config.games_per_matchup,
                self.config.historical_games_per_matchup,
                self.config.seed,
            )
            shard_fingerprint = self._generation_shard_fingerprint(
                generation,
                accepted_checkpoints,
            )
            historical_models = [
                copy.deepcopy(model)
                for model in reversed(history[:-1][-3:])
            ]
            with ExitStack() as backend_stack:
                current_evaluator = backend_stack.enter_context(
                    self._model_backend(champion)
                )
                historical_evaluators = [
                    backend_stack.enter_context(
                        self._model_backend(model)
                    )
                    for model in historical_models
                ]

                def evaluator_for_task(task: GameTask):
                    if (
                        task.opponent_version >= 0
                        or not historical_evaluators
                    ):
                        return current_evaluator
                    history_index = (
                        -int(task.opponent_version) - 1
                    ) % len(historical_evaluators)
                    return _SeatEvaluator({
                        int(task.seat_a): current_evaluator,
                        1 - int(task.seat_a):
                            historical_evaluators[history_index],
                    })

                results = self._run_tasks(
                    tasks,
                    evaluator_for_task,
                    training=True,
                    shard_dir=(
                        self.output_dir
                        / "self_play"
                        / f"generation-{generation:03d}"
                    ),
                    shard_fingerprint=shard_fingerprint,
                )
                native_inference = self._native_metrics(
                    current_evaluator,
                    *historical_evaluators,
                )
                structural_errors = sum(
                    result.structural_errors for result in results
                )
                if structural_errors:
                    raise RuntimeError(
                        f"self_play_structural_errors:{structural_errors}"
                    )
                truncated_games = sum(
                    result.truncated for result in results
                )
                if truncated_games:
                    raise RuntimeError(
                        f"self_play_truncated_games:{truncated_games}"
                    )
                samples = [
                    sample
                    for result in results
                    for sample in result.samples
                ]
                replay.add_generation(generation, samples)

                candidate = copy.deepcopy(champion).to(self.config.device)
                metrics, _optimizer, self.global_step = train_model(
                    candidate,
                    replay.stratified_epoch(),
                    self.config,
                    epochs=self.config.replay_epochs,
                    optimizer=None,
                    global_step=self.global_step,
                    schedule_total_steps=optimizer_schedule_steps,
                )
                arena = self._arena(candidate, champion, generation)
                accepted = (
                    arena["score_rate"] >= self.config.promotion_score_rate
                    and arena["structural_errors"] == 0
                )
                if accepted:
                    champion = candidate
                    history.append(copy.deepcopy(champion).cpu())
                    # Keep the current champion plus the three most recent
                    # accepted predecessors used by historical self-play.
                    history = history[-4:]
                    checkpoint_name = f"champion-g{generation:03d}.pt"
                    save_checkpoint(
                        str(self.output_dir / checkpoint_name),
                        champion,
                        {
                            "generation": generation,
                            "accepted": True,
                            "arena": arena,
                        },
                    )
                    accepted_checkpoints.append(checkpoint_name)
                    accepted_checkpoints = accepted_checkpoints[-4:]
                row = {
                    "generation": generation,
                    "samples": len(samples),
                    "truncation_retry_games": sum(
                        int(result.truncation_retries > 0)
                        for result in results
                    ),
                    "truncation_retries": sum(
                        int(result.truncation_retries)
                        for result in results
                    ),
                    "accepted": accepted,
                    "arena": arena,
                    "native_inference": native_inference,
                    **metrics,
                }
                generation_rows.append(row)
                self._event("generation_complete", **row)
                self._write_training_state(
                    next_generation=generation + 1,
                    global_step=self.global_step,
                    accepted_checkpoints=accepted_checkpoints,
                    generation_rows=generation_rows,
                )

        universal_path = self.output_dir / "universal.pt"
        final = self._final_league(champion)
        elapsed_seconds = self._elapsed_seconds()
        wall_clock_budget_passed = self._check_wall_clock()
        accepted = (
            wall_clock_budget_passed
            and final["overall_score_rate"] >= self.config.release_score_rate
            and all(
                value >= self.config.release_deck_score_rate
                for value in final["deck_score_rates"].values()
            )
            and final["structural_errors"] == 0
        )
        universal_metadata = {
            "generation": self.config.generations,
            "accepted": accepted,
            "verification_status": (
                "verified_accepted"
                if accepted
                else "verified_rejected"
            ),
            "elapsed_seconds": elapsed_seconds,
            "wall_clock_budget_seconds": self.config.max_wall_seconds,
            "wall_clock_budget_passed": wall_clock_budget_passed,
            "final_league": final,
        }
        save_checkpoint(
            str(universal_path),
            champion,
            universal_metadata,
        )
        sidecar_metadata = {
            **universal_metadata,
            "trainer": TRAINER_ID,
            "model_variant": MODEL_VARIANT,
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "checkpoint_version": CHECKPOINT_VERSION,
            "planner_version": DEEP_PLANNER_VERSION,
        }
        (self.output_dir / "universal.json").write_text(
            json.dumps(
                {
                    "format_version": 3,
                    "checkpoint_sha256": hashlib.sha256(
                        universal_path.read_bytes()
                    ).hexdigest(),
                    "metadata": sidecar_metadata,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        summary = {
            "trainer": TRAINER_ID,
            "elapsed_seconds": self._elapsed_seconds(),
            "generations": generation_rows,
            "final_league": final,
            "accepted": accepted,
            "checkpoint": str(universal_path),
            "elapsed_seconds": elapsed_seconds,
            "wall_clock_budget_seconds": self.config.max_wall_seconds,
            "wall_clock_budget_passed": wall_clock_budget_passed,
        }
        evidence_path = self.output_dir / "release-evidence.json"
        evidence = {
            "schema": "alphazero_v2_training_evidence/1",
            "format_version": 1,
            "trainer": TRAINER_ID,
            "accepted": accepted,
            "native_core_required": self.config.require_native,
            "native_core_available": _native_available(),
            "native_core_ready": _native_production_ready(),
            "native_core_blockers": list(_native_blockers()),
            "elapsed_seconds": summary["elapsed_seconds"],
            "wall_clock_budget_seconds": self.config.max_wall_seconds,
            "wall_clock_budget_passed": wall_clock_budget_passed,
            "final_league": final,
            "structural_errors": final["structural_errors"],
        }
        evidence_path.write_text(
            json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        evidence_sha256 = hashlib.sha256(
            evidence_path.read_bytes()
        ).hexdigest()
        staging_root = self.output_dir / "release_staging"
        from scripts.export_onnx_models import export_universal

        runtime_manifest = export_universal(
            universal_path,
            staging_root / "godot" / "data" / "ai_models" / "universal.onnx",
            staging_root / "godot" / "data" / "ai_models_runtime.json",
            evidence_sha256=evidence_sha256,
        )
        candidate_release = json.loads(
            (repo_root / "release_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        # Training produces a staged candidate, never an enabled runtime.
        # Only finalize_release_evidence() has all independent rule, privacy,
        # performance, Windows and physical-Android evidence required to turn
        # this switch on.
        candidate_enabled = False
        candidate_release["deep_runtime_enabled"] = candidate_enabled
        candidate_release["model_count"] = 1 if candidate_enabled else 0
        candidate_release["native_ai"]["production_ready"] = bool(
            _native_production_ready()
        )
        candidate_release["deep_model"]["status"] = "candidate"
        candidate_release["deep_planner"][
            "evidence_sha256"
        ] = evidence_sha256
        candidate_release_path = (
            staging_root / "godot" / "data" / "release_manifest.json"
        )
        candidate_release_path.write_text(
            json.dumps(
                candidate_release,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        summary["evidence_path"] = str(evidence_path)
        summary["evidence_sha256"] = evidence_sha256
        summary["runtime_manifest"] = str(
            staging_root / "godot" / "data" / "ai_models_runtime.json"
        )
        summary["candidate_release_manifest"] = str(
            candidate_release_path
        )
        summary["onnx_parity_max_abs_error"] = dict(
            runtime_manifest["models"]["universal"]["parity_max_abs_error"]
        )
        summary["elapsed_seconds"] = self._elapsed_seconds()
        summary["wall_clock_budget_passed"] = self._check_wall_clock()
        _atomic_write_json(
            self.output_dir / "summary.json",
            summary,
        )
        self._write_training_state(
            next_generation=self.config.generations + 1,
            global_step=self.global_step,
            accepted_checkpoints=accepted_checkpoints,
            generation_rows=generation_rows,
            phase="complete",
        )
        self._event("run_complete", **summary)
        return summary

    def _run_tasks(
        self,
        tasks: Sequence[GameTask],
        evaluator_or_factory: Any,
        *,
        training: bool,
        shard_dir: Path | None = None,
        shard_fingerprint: str | None = None,
    ) -> list[GameResult]:
        ordered_tasks = list(tasks)
        task_by_game_id = {task.game_id: task for task in ordered_tasks}
        if len(task_by_game_id) != len(ordered_tasks):
            raise RuntimeError("duplicate_game_task_id")
        order = {
            task.game_id: index for index, task in enumerate(ordered_tasks)
        }
        results: list[GameResult] = []
        pending_tasks = list(ordered_tasks)
        if shard_dir is not None:
            if not training or not shard_fingerprint:
                raise RuntimeError("self_play_shard_contract_invalid")
            shard_dir.mkdir(parents=True, exist_ok=True)
            pending_tasks = []
            for task in ordered_tasks:
                if Path(task.game_id).name != task.game_id:
                    raise RuntimeError("unsafe_game_task_id")
                path = shard_dir / f"{task.game_id}.pt"
                if not path.is_file():
                    pending_tasks.append(task)
                    continue
                import torch

                payload = torch.load(
                    path,
                    map_location="cpu",
                    weights_only=False,
                )
                result = (
                    payload.get("result")
                    if isinstance(payload, dict)
                    else None
                )
                if (
                    not isinstance(payload, dict)
                    or payload.get("format")
                        != SELF_PLAY_GAME_SHARD_FORMAT
                    or payload.get("fingerprint") != shard_fingerprint
                    or payload.get("task") != asdict(task)
                    or not isinstance(result, GameResult)
                    or result.task.game_id != task.game_id
                    or result.integrity_errors
                ):
                    raise RuntimeError(
                        "self_play_game_shard_invalid:" + task.game_id
                    )
                results.append(result)
            if results:
                self._event(
                    "self_play_shards_reused",
                    shard_dir=str(shard_dir),
                    games=len(results),
                    pending_games=len(pending_tasks),
                )
        # Python is a correctness fallback. The release preset refuses to use
        # it; the native binding owns the 16-thread/64-game state machines.
        workers = (
            max(1, self.config.concurrent_games)
            if _native_available()
            else min(
                self.config.concurrent_games,
                max(1, self.config.actor_threads),
            )
        )
        with ThreadPoolExecutor(max_workers=workers) as executor:
            remaining = iter(pending_tasks)
            futures: dict[Any, GameTask] = {}
            first_failure: BaseException | None = None

            def submit_one(task: GameTask) -> None:
                evaluator = (
                    evaluator_or_factory(task)
                    if callable(evaluator_or_factory)
                    else evaluator_or_factory
                )
                future = executor.submit(
                    (
                        _play_self_play_with_retries
                        if training
                        else _play_arena_with_extended_decision_caps
                    ),
                    task,
                    evaluator,
                    simulations=self.config.simulations,
                    c_puct=self.config.c_puct,
                    max_decisions=self.config.max_game_decisions,
                    training=training,
                )
                futures[future] = task

            for _index in range(min(workers, len(pending_tasks))):
                submit_one(next(remaining))

            while futures:
                completed_futures, _waiting = wait(
                    tuple(futures),
                    return_when=FIRST_COMPLETED,
                )
                if first_failure is None:
                    for future in completed_futures:
                        if future.cancelled():
                            continue
                        exception = future.exception()
                        if exception is not None:
                            first_failure = exception
                            for waiting_future in futures:
                                if waiting_future not in completed_futures:
                                    waiting_future.cancel()
                            break
                for future in sorted(
                    completed_futures,
                    key=lambda row: order[futures[row].game_id],
                ):
                    original_task = futures.pop(future)
                    if future.cancelled():
                        continue
                    exception = future.exception()
                    if exception is not None:
                        if first_failure is None:
                            first_failure = exception
                        continue
                    result = future.result()
                    results.append(result)
                    if result.structural_errors or (
                        training and result.truncated
                    ):
                        self._event(
                            "task_integrity_failure",
                            phase="self_play" if training else "arena",
                            task=asdict(result.task),
                            decisions=int(result.decisions),
                            simulations=int(result.simulations),
                            invalid_actions=int(result.invalid_actions),
                            illegal_choices=int(result.illegal_choices),
                            rule_exceptions=int(result.rule_exceptions),
                            decision_timeouts=int(
                                result.decision_timeouts
                            ),
                            hidden_information_violations=int(
                                result.hidden_information_violations
                            ),
                            truncated=bool(result.truncated),
                            truncation_retries=int(
                                result.truncation_retries
                            ),
                            error_details=list(result.error_details),
                        )
                    elif result.truncated:
                        event = {
                            "event": "arena_task_truncated",
                            "phase": "arena",
                            "task": asdict(result.task),
                            "decisions": int(result.decisions),
                            "simulations": int(result.simulations),
                            "invalid_actions": int(result.invalid_actions),
                            "illegal_choices": int(result.illegal_choices),
                            "rule_exceptions": int(result.rule_exceptions),
                            "decision_timeouts": int(
                                result.decision_timeouts
                            ),
                            "hidden_information_violations": int(
                                result.hidden_information_violations
                            ),
                            "truncated": True,
                            "truncation_retries": int(
                                result.truncation_retries
                            ),
                            "error_details": list(result.error_details),
                        }
                        if not is_recoverable_arena_truncation_event(event):
                            raise RuntimeError(
                                "arena_truncation_event_policy_mismatch"
                            )
                        event.pop("event")
                        self._event("arena_task_truncated", **event)
                    elif shard_dir is not None:
                        _atomic_torch_save(
                            {
                                "format": SELF_PLAY_GAME_SHARD_FORMAT,
                                "fingerprint": shard_fingerprint,
                                "task": asdict(original_task),
                                "result": result,
                            },
                            shard_dir / f"{original_task.game_id}.pt",
                        )
                    completed_count = len(results)
                    if (
                        completed_count % 50 == 0
                        or completed_count == len(ordered_tasks)
                    ):
                        self._event(
                            "task_progress",
                            phase="self_play" if training else "arena",
                            generation=(
                                int(ordered_tasks[0].generation)
                                if ordered_tasks
                                else -1
                            ),
                            completed=completed_count,
                            tasks=len(ordered_tasks),
                            truncated=sum(
                                int(row.truncated) for row in results
                            ),
                            truncation_retry_games=sum(
                                int(row.truncation_retries > 0)
                                for row in results
                            ),
                            truncation_retries=sum(
                                int(row.truncation_retries)
                                for row in results
                            ),
                        )
                    if first_failure is None:
                        try:
                            submit_one(next(remaining))
                        except StopIteration:
                            pass
            if first_failure is not None:
                raise first_failure
        return sorted(results, key=lambda row: order[row.task.game_id])

    def run_self_play_partition(
        self,
        *,
        worker_index: int,
        worker_count: int,
        search_slots: int,
        target_batch_size: int,
        max_batch_size: int,
    ) -> dict[str, Any]:
        """Generate one disjoint partition of the active generation.

        The persisted training config remains the semantic cache identity.
        Worker count, search slots and inference batch sizes only control how
        independent games are scheduled; they do not change simulations,
        PUCT constants, temperature, RNG seeds or model checkpoints.
        """
        if not 0 <= int(worker_index) < int(worker_count):
            raise ValueError("invalid_self_play_partition")
        if int(search_slots) <= 0:
            raise ValueError("invalid_self_play_partition_search_slots")
        if (
            int(target_batch_size) <= 0
            or int(max_batch_size) < int(target_batch_size)
        ):
            raise ValueError("invalid_self_play_partition_batch")
        if not _native_available():
            raise RuntimeError("native_training_bridge_required")

        training_state = self._load_training_state()
        if training_state is None:
            raise RuntimeError("self_play_partition_training_state_missing")
        if training_state["phase"] != "self_play":
            raise RuntimeError("self_play_partition_phase_mismatch")
        generation = int(training_state["next_generation"])
        if generation > self.config.generations:
            raise RuntimeError("self_play_partition_generation_complete")

        accepted_checkpoints = list(
            training_state["accepted_checkpoints"]
        )
        tasks = generation_tasks(
            generation,
            self.config.games_per_matchup,
            self.config.historical_games_per_matchup,
            self.config.seed,
        )
        partition = partition_game_tasks(
            tasks,
            int(worker_index),
            int(worker_count),
        )
        if not partition:
            raise RuntimeError("self_play_partition_empty")
        shard_dir = (
            self.output_dir / "self_play" / f"generation-{generation:03d}"
        )
        existing_games = sum(
            int((shard_dir / f"{task.game_id}.pt").is_file())
            for task in partition
        )
        shard_fingerprint = self._generation_shard_fingerprint(
            generation,
            accepted_checkpoints,
        )

        from engine.ai.dl.model_v2 import load_checkpoint

        champion, _payload = load_checkpoint(
            str(self._resolve_training_checkpoint(
                str(training_state["champion_checkpoint"])
            )),
            device="cpu",
        )
        historical_models = [
            load_checkpoint(
                str(self._resolve_training_checkpoint(relative)),
                device="cpu",
            )[0]
            for relative in reversed(accepted_checkpoints[:-1][-3:])
        ]

        import ptcg_ai_core  # type: ignore

        limiter = ptcg_ai_core.NativeSearchLimiter(int(search_slots))

        def worker_backend(model: Any) -> NativeModelBackend:
            return NativeModelBackend(
                model,
                device=self.config.device,
                target_batch_size=int(target_batch_size),
                max_batch_size=int(max_batch_size),
                coalesce_ms=self.config.inference_coalesce_ms,
                simulation_limiter=limiter,
                max_inflight_leaves=self.config.native_inflight_leaves,
            )

        with ExitStack() as backend_stack:
            current_evaluator = backend_stack.enter_context(
                worker_backend(champion)
            )
            historical_evaluators = [
                backend_stack.enter_context(worker_backend(model))
                for model in historical_models
            ]

            def evaluator_for_task(task: GameTask):
                if task.opponent_version >= 0 or not historical_evaluators:
                    return current_evaluator
                history_index = (
                    -int(task.opponent_version) - 1
                ) % len(historical_evaluators)
                return _SeatEvaluator({
                    int(task.seat_a): current_evaluator,
                    1 - int(task.seat_a):
                        historical_evaluators[history_index],
                })

            results = self._run_tasks(
                partition,
                evaluator_for_task,
                training=True,
                shard_dir=shard_dir,
                shard_fingerprint=shard_fingerprint,
            )
            native_inference = self._native_metrics(
                current_evaluator,
                *historical_evaluators,
            )

        structural_errors = sum(
            result.structural_errors for result in results
        )
        truncated_games = sum(result.truncated for result in results)
        if structural_errors:
            raise RuntimeError(
                f"self_play_partition_structural_errors:{structural_errors}"
            )
        if truncated_games:
            raise RuntimeError(
                f"self_play_partition_truncated_games:{truncated_games}"
            )
        summary = {
            "generation": generation,
            "worker_index": int(worker_index),
            "worker_count": int(worker_count),
            "games": len(results),
            "existing_games": existing_games,
            "generated_games": len(results) - existing_games,
            "samples": sum(len(result.samples) for result in results),
            "structural_errors": structural_errors,
            "truncated_games": truncated_games,
            "shard_dir": str(shard_dir),
            "shard_fingerprint": shard_fingerprint,
            "native_inference": native_inference,
        }
        self._event("self_play_partition_complete", **summary)
        return summary

    def _arena(
        self,
        candidate: Any,
        champion: Any,
        generation: int,
    ) -> dict[str, Any]:
        tasks = generation_tasks(
            generation,
            self.config.arena_games_per_matchup,
            0,
            self.config.seed + 500_000_000,
        )
        with (
            self._model_backend(
                candidate,
            ) as candidate_evaluator,
            self._model_backend(
                champion,
            ) as champion_evaluator,
        ):
            results = self._run_tasks(
                tasks,
                lambda task: _SeatEvaluator({
                    int(task.seat_a): candidate_evaluator,
                    1 - int(task.seat_a): champion_evaluator,
                }),
                training=False,
            )
            native_inference = self._native_metrics(
                candidate_evaluator,
                champion_evaluator,
            )
        wins = sum(
            result.winner == result.task.seat_a
            for result in results
            if result.winner is not None
        )
        draws = sum(result.winner is None for result in results)
        return {
            "games": len(results),
            "score_rate": (wins + 0.5 * draws) / max(1, len(results)),
            "decision_cap_draws": sum(
                _is_evaluation_decision_cap_draw(result)
                for result in results
            ),
            "structural_errors": sum(
                result.integrity_errors for result in results
            ),
            "truncated_games": sum(
                result.truncated for result in results
            ),
            "native_inference": native_inference,
        }

    def _final_league(self, champion: Any) -> dict[str, Any]:
        tasks = final_league_tasks(
            self.config.generations,
            self.config.final_games_per_deck,
            self.config.seed,
        )
        with self._model_backend(
            champion,
        ) as evaluator:
            workers = (
                max(1, self.config.concurrent_games)
                if _native_available()
                else min(
                    self.config.concurrent_games,
                    max(1, self.config.actor_threads),
                )
            )
            results = []
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futures = [
                    executor.submit(
                        _play_league_with_extended_decision_caps,
                        task,
                        evaluator,
                        simulations=self.config.simulations,
                        c_puct=self.config.c_puct,
                        max_decisions=self.config.max_game_decisions,
                    )
                    for task in tasks
                ]
                for future in as_completed(futures):
                    results.append(future.result())
            native_inference = self._native_metrics(evaluator)
        deck_scores: dict[str, list[float]] = {
            deck: [] for deck in RELEASE_DECKS
        }
        for result in results:
            controlled_player = result.task.seat_a
            score = (
                0.5
                if result.winner is None
                else 1.0 if result.winner == controlled_player else 0.0
            )
            deck_scores[result.task.deck_a].append(score)
        rates = {
            deck: sum(values) / max(1, len(values))
            for deck, values in deck_scores.items()
        }
        return {
            "games": len(results),
            "overall_score_rate": (
                sum(sum(values) for values in deck_scores.values())
                / max(1, len(results))
            ),
            "deck_score_rates": rates,
            "decision_cap_draws": sum(
                _is_evaluation_decision_cap_draw(result)
                for result in results
            ),
            "structural_errors": sum(
                result.integrity_errors for result in results
            ),
            "truncated_games": sum(
                result.truncated for result in results
            ),
            "native_inference": native_inference,
        }

    def _event(self, event: str, **payload: Any) -> None:
        row = {
            "event": event,
            "time": time.time(),
            "elapsed_seconds": self._elapsed_seconds(),
            **payload,
        }
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(row, ensure_ascii=False, sort_keys=True)
                + "\n"
            )

    def _model_backend(self, model: Any):
        arguments = {
            "device": self.config.device,
            "target_batch_size": self.config.inference_target_batch,
            "max_batch_size": self.config.inference_max_batch,
            "coalesce_ms": self.config.inference_coalesce_ms,
            "max_inflight_leaves": self.config.native_inflight_leaves,
        }
        if _native_available():
            return NativeModelBackend(
                model,
                simulation_limiter=self._native_simulation_limiter,
                **arguments,
            )
        if self.config.require_native:
            raise RuntimeError("native_training_bridge_required")
        return BatchedTorchEvaluator(model, **arguments)

    @staticmethod
    def _native_metrics(*backends: Any) -> dict[str, float | int]:
        rows = [
            dict(backend.native_metrics)
            for backend in backends
            if hasattr(backend, "native_metrics")
        ]
        if not rows:
            return {}
        return {
            "inference_batches": sum(
                int(row.get("inference_batches", 0)) for row in rows
            ),
            "inference_requests": sum(
                int(row.get("inference_requests", 0)) for row in rows
            ),
            "max_inference_batch": max(
                int(row.get("max_inference_batch", 0)) for row in rows
            ),
            "max_inference_queue": max(
                int(row.get("max_inference_queue", 0)) for row in rows
            ),
            "simulation_thread_capacity": max(
                int(row.get("simulation_thread_capacity", 0))
                for row in rows
            ),
            "max_active_simulations": max(
                int(row.get("max_active_simulations", 0))
                for row in rows
            ),
            "inference_seconds": sum(
                float(row.get("inference_seconds", 0.0)) for row in rows
            ),
            "search_decisions": sum(
                int(row.get("search_decisions", 0)) for row in rows
            ),
            "search_simulations": sum(
                int(row.get("search_simulations", 0)) for row in rows
            ),
            "search_tree_nodes": sum(
                int(row.get("search_tree_nodes", 0)) for row in rows
            ),
            "search_chance_nodes": sum(
                int(row.get("search_chance_nodes", 0)) for row in rows
            ),
            "search_chance_edges": sum(
                int(row.get("search_chance_edges", 0)) for row in rows
            ),
            "search_determinization_microseconds": sum(
                int(row.get("search_determinization_microseconds", 0))
                for row in rows
            ),
            "search_projection_microseconds": sum(
                int(row.get("search_projection_microseconds", 0))
                for row in rows
            ),
            "search_candidate_generation_microseconds": sum(
                int(row.get("search_candidate_generation_microseconds", 0))
                for row in rows
            ),
            "search_apply_microseconds": sum(
                int(row.get("search_apply_microseconds", 0))
                for row in rows
            ),
            "search_encoding_microseconds": sum(
                int(row.get("search_encoding_microseconds", 0))
                for row in rows
            ),
            "search_inference_wait_microseconds": sum(
                int(row.get("search_inference_wait_microseconds", 0))
                for row in rows
            ),
            "search_max_pending_leaves": max(
                int(row.get("search_max_pending_leaves", 0))
                for row in rows
            ),
            "search_candidate_cache_hits": sum(
                int(row.get("search_candidate_cache_hits", 0))
                for row in rows
            ),
            "search_candidate_cache_misses": sum(
                int(row.get("search_candidate_cache_misses", 0))
                for row in rows
            ),
        }

    def _check_wall_clock(self) -> bool:
        elapsed_seconds = self._elapsed_seconds()
        passed = elapsed_seconds <= self.config.max_wall_seconds
        if not passed and not self._wall_clock_budget_exceeded:
            self._wall_clock_budget_exceeded = True
            self._event(
                "training_wall_clock_budget_exceeded",
                elapsed_seconds=elapsed_seconds,
                wall_clock_budget_seconds=self.config.max_wall_seconds,
                policy="continue_non_promotable",
            )
        return passed

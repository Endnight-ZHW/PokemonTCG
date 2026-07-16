"""Training helpers for the optional deep-learning AI."""
from __future__ import annotations

import copy
import gc
import hashlib
import json
import math
import os
import random
import time
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool
from dataclasses import dataclass, replace
from typing import Any, Callable


def _checkpoint_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, expand_deck
from engine.ai.challenge_ai import AIAction, AIConfig, create_challenge_ai
from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    ACTION_TYPES,
    CARD_SEMANTIC_SIZE,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
    ActionStateEncoder,
    EncodedAction,
    EncodedState,
)
from engine.ai.dl.model import TORCH_AVAILABLE, create_model, load_checkpoint, save_checkpoint, torch
from engine.ai.dl.release_gate import (
    DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
    DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    DEFAULT_MIN_ACCEPTED_POINT_RATE,
    has_strength_and_reliability_floor,
    max_step_exhaustion_rate as release_max_step_exhaustion_rate,
    paired_delta_point_rate as release_paired_delta_point_rate,
    point_rate as release_point_rate,
)
from engine.ai.dl.evaluation_stats import (
    empty_evaluation_stats,
    summarize_evaluation_rows,
)
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION, ChoiceRequest, ChoiceResponse, GameAction
from engine.random_source import RandomSource
from engine.ai.dl.opponent_pool import OpponentPool, save_opponent_pool, load_opponent_pool
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.ai.dl.replay import ReplayBuffer

from engine.ai.training import DECK_SPECS, _determine_soft_winner, finish_setup, force_end_turn, terminal_training_score
from engine.enums import PlayerAction, TurnPhase
from engine.effects.runtime_effects import trainer_runtime_effects
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import GameState
from engine.snapshot import snapshot_state, state_from_snapshot
from engine.turn_manager import TurnManager


DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")
TRAINER_ALPHA_ZERO = "alpha_zero_rl"
TRAINER_LEGACY = "teacher_dagger_rl"
ALPHA_ZERO_METADATA_TRAINER = "alpha_zero_rl_v1"
LEGACY_METADATA_TRAINER = "teacher_dagger_rl_v4"
PRODUCTION_MCTS_DECISION_SECONDS = 2.0
RL_EXAMPLE_SOURCES = {"self_play", "league_self_play"}
SUPERVISED_ACTION_TYPE_WEIGHTS = {
    PlayerAction.PLAY_TRAINER.name: 1.35,
    PlayerAction.ATTACH_ENERGY.name: 1.30,
    PlayerAction.PLAY_BASIC.name: 1.30,
    PlayerAction.EVOLVE.name: 1.15,
    PlayerAction.USE_ABILITY.name: 1.15,
    PlayerAction.USE_STADIUM.name: 1.10,
    PlayerAction.RETREAT.name: 1.10,
    PlayerAction.DECLARE_ATTACK.name: 0.95,
    PlayerAction.END_TURN.name: 0.90,
}


def _make_grad_scaler(enabled: bool):
    if not TORCH_AVAILABLE:
        return None
    amp_module = getattr(torch, "amp", None)
    grad_scaler_cls = getattr(amp_module, "GradScaler", None)
    if grad_scaler_cls is not None:
        try:
            return grad_scaler_cls("cuda", enabled=enabled)
        except TypeError:
            try:
                return grad_scaler_cls(device_type="cuda", enabled=enabled)
            except TypeError:
                pass
    cuda_amp_module = getattr(getattr(torch, "cuda", None), "amp", None)
    grad_scaler_cls = getattr(cuda_amp_module, "GradScaler", None)
    if grad_scaler_cls is None:
        return None
    return grad_scaler_cls(enabled=enabled)

FAST_TRAINING_AI_SEARCH = {
    "thinking_time_seconds": 0.0,
    "beam_width": 4,
    "max_sequence_depth": 2,
    "max_turn_actions": 96,
    "coin_sample_count": 2,
    "opponent_response_actions": 2,
    "opponent_response_weight": 0.25,
    "deterministic_search": True,
    "search_algorithm": "beam",
    "search_node_budget": 8,
    "planner_max_depth": 6,
}

QUALITY_TRAINING_AI_SEARCH = {
    "thinking_time_seconds": 0.0,
    "beam_width": 8,
    "max_sequence_depth": 4,
    "max_turn_actions": 128,
    "coin_sample_count": 4,
    "opponent_response_actions": 6,
    "opponent_response_weight": 0.45,
    "deterministic_search": True,
    "search_algorithm": "beam",
    "search_node_budget": 24,
    "planner_max_depth": 10,
}

TRAINING_AI_SEARCH = FAST_TRAINING_AI_SEARCH
MINIMAX_FAST_SEARCH = {
    "thinking_time_seconds": 0.0,
    "beam_width": 4,
    "max_sequence_depth": 2,
    "max_turn_actions": 96,
    "coin_sample_count": 2,
    "opponent_response_actions": 2,
    "opponent_response_weight": 0.25,
    "deterministic_search": True,
    "search_algorithm": "minimax",
    "minimax_max_depth": 1,
    "minimax_determinizations": 1,
    "search_node_budget": 12,
    "planner_max_depth": 6,
}

MINIMAX_QUALITY_SEARCH = {
    "thinking_time_seconds": 0.0,
    "beam_width": 6,
    "max_sequence_depth": 3,
    "max_turn_actions": 96,
    "coin_sample_count": 4,
    "opponent_response_actions": 4,
    "opponent_response_weight": 0.40,
    "deterministic_search": True,
    "search_algorithm": "minimax",
    "minimax_max_depth": 2,
    "minimax_determinizations": 2,
    "search_node_budget": 32,
    "planner_max_depth": 10,
}

HYBRID_QUALITY_SEARCH = dict(
    MINIMAX_QUALITY_SEARCH,
    search_algorithm="hybrid",
)

TEACHER_SEARCH_PRESETS = {
    "fast": FAST_TRAINING_AI_SEARCH,
    "quality": QUALITY_TRAINING_AI_SEARCH,
    "hybrid": HYBRID_QUALITY_SEARCH,
    "minimax_fast": MINIMAX_FAST_SEARCH,
    "minimax": MINIMAX_QUALITY_SEARCH,
}


@dataclass(frozen=True)
class DeepTrainingConfig:
    trainer: str = TRAINER_LEGACY
    deck: str = "all"
    games: int = 0
    seed: int = 17
    model: str | None = None
    warm_start: bool = True
    output: str | None = None
    device: str = "cpu"
    bootstrap_games: int = 1000
    dagger_games: int = 1000
    bootstrap_epochs: int = 20
    self_play_epochs: int = 10
    eval_games: int = 600
    workers: int = 1
    max_steps: int = 160
    learning_rate: float = 5e-4
    batch_size: int = 256
    use_amp: bool = True
    progress_jsonl: str | None = None
    rollout_batch_games: int = 16
    updates_per_rollout: int = 2
    teacher_search_preset: str = "quality"
    choice_head_enabled: bool = True
    acceptance_metric: str = "points"
    min_win_delta: int = 0
    teacher_label_model_states: bool = True
    # Pure RL and shared-planner settings (legacy mcts_* field names retained).
    pure_rl_games: int = 0
    mcts_simulations: int = 64
    mcts_chance_nodes: bool = False
    use_mcts_training: bool = True
    eval_use_mcts: bool = True
    teacher_warmup_ratio: float = 0.6
    # --- New: Curiosity exploration ---
    curiosity_beta: float = 0.05
    use_curiosity: bool = False
    # --- New: Same-deal replay ---
    replay_same_deal: int = 0
    # --- New: Fair evaluation ---
    eval_same_seeds: bool = True
    # --- New: Deck embedding ---
    deck_embed_dim: int = 0  # 0 = disabled, 16 = enabled
    replay_buffer_size: int = 50000
    replay_sample_ratio: float = 0.5
    distill_dataset: tuple[str, ...] = ()
    distill_epochs: int = 3
    distill_val_split: float = 0.1
    league_dir: str = os.path.join("data", "ai_league")
    league_eval_games: int = 600
    league_use_mcts: bool = False
    min_elo_delta: float = 25.0
    min_score_rate: float = 0.53
    min_point_rate: float = DEFAULT_MIN_ACCEPTED_POINT_RATE
    min_delta_point_rate: float = DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE
    max_step_exhaustion_rate: float = DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE
    challenge_baseline_eval: dict[str, Any] | None = None
    challenge_baseline_source: str | None = None
    recovered_choice_examples: int = 0


@dataclass
class TrainingExample:
    state: EncodedState
    actions: list[EncodedAction]
    target_index: int
    source: str = "teacher"
    reward: float = 0.0
    return_target: float = 0.0
    advantage: float | None = None
    behavior_log_prob: float | None = None
    value_target: float = 0.0
    policy_advantage: float | None = None
    teacher_target_index: int | None = None
    teacher_score: float = 0.0
    model_score: float = 0.0
    phase_tag: str = ""
    policy_target: list[float] | None = None
    split_key: str = ""


@dataclass
class ChoiceTrainingExample:
    state: EncodedState
    request_type: str
    candidate_choices: list[EncodedAction]
    teacher_target_index: int
    source: str = "teacher"
    phase_tag: str = ""
    split_key: str = ""


def _is_rl_example(ex: TrainingExample) -> bool:
    return str(ex.source) in RL_EXAMPLE_SOURCES


def _target_action_type(ex: TrainingExample) -> str:
    if ex.target_index < 0 or ex.target_index >= len(ex.actions):
        return ""
    numeric = list(ex.actions[ex.target_index].numeric or [])
    width = len(ACTION_TYPES)
    if len(numeric) < width:
        return ""
    best_idx = max(range(width), key=lambda idx: float(numeric[idx]))
    if float(numeric[best_idx]) <= 0.0:
        return ""
    return str(ACTION_TYPES[best_idx])


def _supervised_example_weight(ex: TrainingExample) -> float:
    if _is_rl_example(ex):
        return 1.0
    return float(SUPERVISED_ACTION_TYPE_WEIGHTS.get(_target_action_type(ex), 1.0))


@dataclass(frozen=True)
class BootstrapTask:
    deck_key: str
    seed: int
    game_start: int
    games: int
    max_steps: int
    teacher_search_preset: str


@dataclass(frozen=True)
class ModelGameTask:
    deck_key: str
    seed: int
    max_steps: int
    record: bool
    model_state: dict[str, Any]
    model_config: dict[str, Any]
    teacher_search_preset: str
    temperature: float = 0.9
    teacher_label_model_states: bool = True
    phase_tag: str = "rl"
    pure_rl: bool = False
    use_mcts: bool = False
    mcts_simulations: int = 0
    mcts_chance_nodes: bool = True
    opponent_model_state: dict[str, Any] | None = None
    opponent_model_config: dict[str, Any] | None = None
    opponent_deck_key: str | None = None
    rule_only: bool = False


ProgressCallback = Callable[[dict[str, Any]], None]


def is_torch_available() -> bool:
    return TORCH_AVAILABLE


def _ensure_cards_loaded() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS)


def _worker_init() -> None:
    _ensure_cards_loaded()
    if torch is not None:
        try:
            torch.set_num_threads(1)
        except Exception:
            pass


def _normalized_workers(workers: int | None) -> int:
    try:
        return max(1, int(workers or 1))
    except (TypeError, ValueError):
        return 1


def _normalized_trainer(trainer: str | None) -> str:
    value = str(trainer or TRAINER_LEGACY).strip().lower()
    aliases = {
        "alpha_zero": TRAINER_ALPHA_ZERO,
        "alphazero": TRAINER_ALPHA_ZERO,
        "az": TRAINER_ALPHA_ZERO,
        "rl": TRAINER_ALPHA_ZERO,
        "teacher": TRAINER_LEGACY,
        "legacy": TRAINER_LEGACY,
        "teacher_dagger": TRAINER_LEGACY,
        "teacher_dagger_rl_v4": TRAINER_LEGACY,
    }
    return aliases.get(value, value)


def _deck_keys(deck: str) -> list[str]:
    if deck == "all":
        return list(DECK_SPECS)
    if deck not in DECK_SPECS:
        raise ValueError(f"Unknown deck key: {deck}")
    return [deck]


def _output_path_for_deck(deck_key: str) -> str:
    return os.path.join(DEFAULT_MODEL_DIR, f"{deck_key}.pt")


def _candidate_output_path(config: DeepTrainingConfig, deck_key: str, multi_deck: bool) -> str:
    if not config.output:
        return _output_path_for_deck(deck_key)
    if not multi_deck:
        return config.output
    if "{deck}" in config.output:
        return config.output.format(deck=deck_key)
    root, ext = os.path.splitext(config.output)
    ext = ext or ".pt"
    directory = os.path.dirname(root)
    stem = os.path.basename(root)
    if stem.endswith("default"):
        stem = stem[: -len("default")] + deck_key
    elif deck_key not in stem:
        stem = f"{stem}_{deck_key}"
    return os.path.join(directory, f"{stem}{ext}") if directory else f"{stem}{ext}"


def _search_config(preset: str | None) -> dict[str, Any]:
    return dict(TEACHER_SEARCH_PRESETS.get(preset or "hybrid", HYBRID_QUALITY_SEARCH))


def _action_signature(action: AIAction) -> tuple:
    return action.signature + (bool(action.terminal),)


def _find_action_index(actions: list[AIAction], selected: AIAction) -> int | None:
    signature = _action_signature(selected)
    for idx, action in enumerate(actions):
        if _action_signature(action) == signature:
            return idx
    selected_name = selected.action.name if isinstance(selected.action, PlayerAction) else str(selected.action)
    for idx, action in enumerate(actions):
        action_name = action.action.name if isinstance(action.action, PlayerAction) else str(action.action)
        if action_name == selected_name and (action.params or {}) == (selected.params or {}):
            return idx
    return None


def _postprocess_preferred_action(legal_ai: Any, state, player_idx: int, preferred: AIAction, actions: list[AIAction]) -> AIAction:
    postprocess = getattr(legal_ai, "_validated_or_fallback_action", None)
    if not callable(postprocess):
        return preferred
    try:
        selected = postprocess(state, player_idx, preferred, actions)
        return selected if selected is not None else preferred
    except Exception:
        return preferred


def _as_float_list(values: Any) -> list[float] | None:
    if not isinstance(values, list):
        return None
    try:
        return [float(value) for value in values]
    except (TypeError, ValueError):
        return None


def _as_int_list(values: Any) -> list[int] | None:
    if not isinstance(values, list):
        return None
    try:
        return [int(value) for value in values]
    except (TypeError, ValueError):
        return None


def _matrix_rows(values: Any, *, row_size: int, row_count: int | None = None) -> list[list[float]] | None:
    if not isinstance(values, list):
        return None
    if not values:
        return []
    if all(isinstance(row, list) for row in values):
        rows: list[list[float]] = []
        for row in values:
            converted = _as_float_list(row)
            if converted is None:
                return None
            rows.append(converted)
        return rows
    flat = _as_float_list(values)
    if flat is None:
        return None
    if row_count is None:
        if len(flat) % row_size != 0:
            return None
        row_count = len(flat) // row_size
    if row_count < 0 or len(flat) < row_count * row_size:
        return None
    return [
        flat[index * row_size:(index + 1) * row_size]
        for index in range(row_count)
    ]


def _distill_state_from_row(row: dict[str, Any]) -> EncodedState | None:
    state_payload = row.get("state") if isinstance(row.get("state"), dict) else {}
    state_dict = dict(state_payload or {})
    numeric = _as_float_list(row.get("state_numeric", state_dict.get("numeric")))
    card_ids = _as_int_list(row.get("state_card_ids", state_dict.get("card_ids")))
    if numeric is None or card_ids is None:
        return None
    return EncodedState(
        _fit_sequence(numeric, STATE_NUMERIC_SIZE, 0.0),
        _fit_sequence(card_ids, STATE_CARD_SLOTS, 0),
    )


def _distill_candidates_from_row(
    row: dict[str, Any],
    *,
    numeric_keys: tuple[str, ...],
    card_keys: tuple[str, ...],
) -> list[EncodedAction] | None:
    card_values = None
    for key in card_keys:
        if key in row:
            card_values = row.get(key)
            break
    card_ids = _as_int_list(card_values)
    if card_ids is None:
        return None
    numeric_values = None
    for key in numeric_keys:
        if key in row:
            numeric_values = row.get(key)
            break
    numeric_rows = _matrix_rows(
        numeric_values,
        row_size=ACTION_NUMERIC_SIZE,
        row_count=len(card_ids),
    )
    if numeric_rows is None or len(numeric_rows) != len(card_ids):
        return None
    return [
        EncodedAction(
            _fit_sequence(numeric_rows[index], ACTION_NUMERIC_SIZE, 0.0),
            int(card_ids[index]),
        )
        for index in range(len(card_ids))
    ]


def _distill_target_index(row: dict[str, Any], candidate_count: int) -> int | None:
    raw = row.get("target_index", row.get("teacher_target_index"))
    try:
        index = int(raw)
    except (TypeError, ValueError):
        return None
    if index < 0 or index >= candidate_count:
        return None
    return index


def _distill_policy_target(row: dict[str, Any], candidate_count: int) -> list[float] | None:
    values = row.get("policy_target", row.get("action_policy"))
    target = _as_float_list(values)
    if target is None or len(target) != candidate_count:
        return None
    total = sum(max(0.0, float(value)) for value in target)
    if total <= 0.0:
        return None
    return [max(0.0, float(value)) / total for value in target]


def _distill_split_key(row: dict[str, Any]) -> str:
    seed = row.get("seed")
    if seed is None:
        return ""
    return "%s:%s:%s" % (
        row.get("matchup_key", ""),
        row.get("seed_block", ""),
        seed,
    )


def _distill_action_example(row: dict[str, Any]) -> TrainingExample | None:
    state = _distill_state_from_row(row)
    actions = _distill_candidates_from_row(
        row,
        numeric_keys=("candidate_action_numeric", "action_numeric", "candidate_numeric"),
        card_keys=("candidate_action_cards", "action_cards", "candidate_cards"),
    )
    if state is None or not actions:
        return None
    target_index = _distill_target_index(row, len(actions))
    if target_index is None:
        return None
    teacher_score = float(row.get("teacher_score", 0.0) or 0.0)
    value_target = float(row.get("value_target", teacher_score) or 0.0)
    return TrainingExample(
        state,
        actions,
        target_index,
        source="distill",
        value_target=value_target,
        teacher_target_index=target_index,
        teacher_score=teacher_score,
        phase_tag="distill",
        policy_target=_distill_policy_target(row, len(actions)),
        split_key=_distill_split_key(row),
    )


def _distill_choice_example(row: dict[str, Any]) -> ChoiceTrainingExample | None:
    state = _distill_state_from_row(row)
    choices = _distill_candidates_from_row(
        row,
        numeric_keys=("candidate_choice_numeric", "choice_numeric", "candidate_numeric"),
        card_keys=("candidate_choice_cards", "choice_cards", "candidate_cards"),
    )
    if state is None or not choices:
        return None
    target_index = _distill_target_index(row, len(choices))
    if target_index is None:
        return None
    return ChoiceTrainingExample(
        state,
        str(row.get("request_type", "")),
        choices,
        target_index,
        source="distill",
        phase_tag="distill",
        split_key=_distill_split_key(row),
    )


def _load_distill_examples(
    paths: tuple[str, ...],
    deck_key: str,
) -> tuple[list[TrainingExample], list[ChoiceTrainingExample], dict[str, int]]:
    actions: list[TrainingExample] = []
    choices: list[ChoiceTrainingExample] = []
    stats = {
        "files": 0,
        "rows": 0,
        "skipped": 0,
        "wrong_deck": 0,
        "action_examples": 0,
        "choice_examples": 0,
    }
    for raw_path in paths:
        path = os.fspath(raw_path)
        if not path or not os.path.exists(path):
            stats["skipped"] += 1
            continue
        stats["files"] += 1
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                if not line.strip():
                    continue
                stats["rows"] += 1
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    stats["skipped"] += 1
                    continue
                if not isinstance(row, dict):
                    stats["skipped"] += 1
                    continue
                row_deck = str(row.get("deck_key", row.get("deck", "")) or "")
                if row_deck and row_deck != deck_key:
                    stats["wrong_deck"] += 1
                    continue
                kind = str(row.get("kind", "action"))
                if kind == "choice":
                    example = _distill_choice_example(row)
                    if example is None:
                        stats["skipped"] += 1
                    else:
                        choices.append(example)
                        stats["choice_examples"] += 1
                else:
                    example = _distill_action_example(row)
                    if example is None:
                        stats["skipped"] += 1
                    else:
                        actions.append(example)
                        stats["action_examples"] += 1
    return actions, choices, stats


def _split_distill_examples(
    examples: list[Any],
    *,
    val_split: float,
    seed: int,
) -> tuple[list[Any], list[Any]]:
    rows = list(examples)
    if not rows:
        return [], []
    validation_count = int(len(rows) * max(0.0, min(0.9, float(val_split))))
    if validation_count <= 0:
        return rows, []
    groups: dict[str, list[Any]] = {}
    for index, example in enumerate(rows):
        split_key = str(getattr(example, "split_key", "") or f"row:{index}")
        groups.setdefault(split_key, []).append(example)
    rng = random.Random(seed)
    keys = list(groups)
    rng.shuffle(keys)
    train: list[Any] = []
    validation: list[Any] = []
    for key in keys:
        target = validation if len(validation) < validation_count else train
        target.extend(groups[key])
    return train, validation


def _card_key(card: Any) -> str:
    return str(getattr(card, "api_id", getattr(card, "name", id(card))))


def _find_card_index(cards: list[Any], selected: Any) -> int | None:
    selected_key = _card_key(selected)
    for idx, card in enumerate(cards):
        if card is selected or _card_key(card) == selected_key:
            return idx
    return None


def _choice_candidates_and_target(state, req, choice) -> tuple[list[Any], int] | None:
    request_type = getattr(req, "request_type", "")
    player_idx = req.player if req.player in (0, 1) else state.active_player_idx
    if request_type in ("search_deck", "select_hand_to_discard"):
        candidates = list(getattr(req, "card_list", []) or [])
        selected_cards = list(getattr(choice, "selected_cards", []) or [])
        if not candidates or not selected_cards:
            return None
        target_index = _find_card_index(candidates, selected_cards[0])
        if target_index is None:
            return None
        return candidates, target_index

    if request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
        target_player = state.get_player(1 - player_idx) if request_type == "select_opponent_bench" else state.get_player(player_idx)
        candidates = [
            idx for idx in range(len(target_player.bench))
            if target_player.bench[idx] is not None
        ]
        target_slot = getattr(choice, "selected_bench_slot", None)
        if target_slot not in candidates:
            return None
        return candidates, candidates.index(target_slot)

    if request_type == "select_bench_targets":
        target_player = state.get_player(1 - player_idx) if getattr(req, "target_player", "") == "opponent" else state.get_player(player_idx)
        candidates = [
            idx for idx in (getattr(req, "bench_indices", None) or range(len(target_player.bench)))
            if 0 <= idx < len(target_player.bench) and target_player.bench[idx] is not None
        ]
        targets = list(getattr(choice, "selected_bench_targets", []) or [])
        if not candidates or not targets or targets[0] not in candidates:
            return None
        return candidates, candidates.index(targets[0])

    if request_type == "confirm":
        candidates = [True, False]
        return candidates, 0 if bool(getattr(choice, "confirmed", True)) else 1

    return None


def _choice_training_example(
    encoder: ActionStateEncoder,
    state,
    req,
    choice,
    deck_key: str,
    *,
    source: str,
    phase_tag: str,
) -> ChoiceTrainingExample | None:
    player_idx = req.player if req.player in (0, 1) else state.active_player_idx
    candidate_info = _choice_candidates_and_target(state, req, choice)
    if candidate_info is None:
        return None
    candidates, target_index = candidate_info
    if not candidates or target_index < 0 or target_index >= len(candidates):
        return None
    request_type = getattr(req, "request_type", "")
    return ChoiceTrainingExample(
        state=encoder.encode_state(state, player_idx, deck_key),
        request_type=request_type,
        candidate_choices=[
            encoder.encode_choice(state, player_idx, request_type, candidate, idx)
            for idx, candidate in enumerate(candidates)
        ],
        teacher_target_index=target_index,
        source=source,
        phase_tag=phase_tag,
    )


def _opponent_for(deck_key: str, index: int) -> str:
    opponents = [key for key in DECK_SPECS if key != deck_key]
    return opponents[index % len(opponents)]


def _make_teacher(deck_key: str, seed: int, teacher_search_preset: str = "hybrid"):
    return create_challenge_ai(
        deck_key,
        AIConfig(**_search_config(teacher_search_preset), random_seed=seed, policy_path=None),
    )


def _setup_match(
    deck_key: str,
    opponent_key: str,
    seed: int,
    seat: int,
    teacher_search_preset: str = "hybrid",
    *,
    rule_only: bool = False,
):
    rng_state = random.getstate()
    random.seed(seed)
    try:
        deck_a_player_idx = 1 if seat == 1 else 0
        state = GameState()
        deck1_key = deck_key if deck_a_player_idx == 0 else opponent_key
        deck2_key = opponent_key if deck_a_player_idx == 0 else deck_key
        setup_rng = RandomSource(seed)
        setup_step = DEFAULT_GAME_ENGINE.begin_game(
            state,
            expand_deck(DECK_SPECS[deck1_key]),
            expand_deck(DECK_SPECS[deck2_key]),
            setup_rng,
        )
        if not setup_step.success:
            raise RuntimeError(setup_step.message)
        state.public_deck_keys = (deck1_key, deck2_key)
        tm = TurnManager(state)
        if rule_only:
            ai0 = _RuleOnlySimulationAI(deck1_key, seed + 11)
            ai1 = _RuleOnlySimulationAI(deck2_key, seed + 29)
        elif deck_a_player_idx == 0:
            ai0 = _make_teacher(deck_key, seed + 11, teacher_search_preset)
            ai1 = _make_teacher(opponent_key, seed + 29, teacher_search_preset)
        else:
            ai0 = _make_teacher(opponent_key, seed + 29, teacher_search_preset)
            ai1 = _make_teacher(deck_key, seed + 11, teacher_search_preset)
        with setup_rng.bind_state(state):
            finish_setup(state, tm, [ai0, ai1], setup_rng)
        return state, tm, [ai0, ai1], deck_a_player_idx, rng_state
    except Exception:
        random.setstate(rng_state)
        raise


def _restore_rng(rng_state) -> None:
    random.setstate(rng_state)


def _fit_sequence(values: list[Any], size: int, pad: Any) -> list[Any]:
    if len(values) >= size:
        return values[:size]
    return values + [pad] * (size - len(values))


def _state_numeric_size(model) -> int:
    return int(getattr(model, "state_numeric_size", ActionStateEncoder.state_numeric_size))


def _state_card_slots(model) -> int:
    return int(getattr(model, "state_card_slots", ActionStateEncoder.state_card_slots))


def _action_numeric_size(model) -> int:
    return int(getattr(model, "action_numeric_size", ACTION_NUMERIC_SIZE))


def _model_payload_for_worker(model) -> tuple[dict[str, Any], dict[str, Any]]:
    assert torch is not None
    state = {
        key: value.detach().cpu().clone()
        for key, value in model.state_dict().items()
    }
    config = {
        "state_numeric_size": int(getattr(model, "state_numeric_size", ActionStateEncoder.state_numeric_size)),
        "state_card_slots": int(getattr(model, "state_card_slots", ActionStateEncoder.state_card_slots)),
        "action_numeric_size": int(getattr(model, "action_numeric_size", ACTION_NUMERIC_SIZE)),
        "card_bucket_count": int(getattr(model, "card_bucket_count", ActionStateEncoder.card_bucket_count)),
        "card_embed_dim": int(getattr(model, "card_embed_dim", 32)),
        "hidden_size": int(getattr(model, "hidden_size", 384)),
        "choice_head_enabled": bool(getattr(model, "choice_head_enabled", True)),
        "use_attention": bool(getattr(model, "use_attention", True)),
        "use_slot_embeddings": bool(getattr(model, "use_slot_embeddings", False)),
        "state_norm": getattr(model, "state_norm", "layer"),
        "deck_embed_dim": int(getattr(model, "deck_embed_dim", 0)),
        "num_decks": (
            int(getattr(getattr(model, "deck_embedding", None), "num_embeddings", 8))
            if getattr(model, "deck_embedding", None) is not None else 8
        ),
    }
    return state, config


def _model_from_worker_payload(model_state: dict[str, Any], model_config: dict[str, Any]):
    assert torch is not None
    model = create_model(**(model_config or {}))
    model.load_state_dict(model_state)
    model.to("cpu")
    model.eval()
    return model


def _clone_model_from_state(model_state: dict[str, Any], model_config: dict[str, Any], device: str):
    assert torch is not None
    model = create_model(**(model_config or {}))
    model.load_state_dict(copy.deepcopy(model_state))
    model.to(device)
    model.eval()
    return model


def _torch_device_info(requested_device: str) -> dict[str, Any]:
    requested = requested_device or "cpu"
    effective = requested
    cuda_available = False
    cuda_version = None
    gpu_name = None
    fallback_reason = ""
    torch_version = None

    if torch is not None:
        torch_version = getattr(torch, "__version__", None)
        cuda_version = getattr(getattr(torch, "version", None), "cuda", None)
        try:
            cuda_available = bool(torch.cuda.is_available())
        except Exception:
            cuda_available = False
        if requested.startswith("cuda"):
            if cuda_available:
                try:
                    index = 0
                    if ":" in requested:
                        index = int(requested.split(":", 1)[1])
                    gpu_name = torch.cuda.get_device_name(index)
                except Exception:
                    gpu_name = None
            else:
                effective = "cpu"
                fallback_reason = "CUDA requested but torch.cuda.is_available() is false."

    return {
        "requested_device": requested,
        "device": effective,
        "torch_version": torch_version,
        "torch_cuda": cuda_version,
        "cuda_available": cuda_available,
        "gpu_name": gpu_name,
        "device_fallback_reason": fallback_reason,
    }


def collect_bootstrap_examples(
    deck_key: str,
    games: int,
    seed: int,
    *,
    max_steps: int = 250,
    encoder: ActionStateEncoder | None = None,
    game_offset: int = 0,
    teacher_search_preset: str = "hybrid",
) -> list[TrainingExample]:
    """Collect imitation examples from ChallengeAI self-play."""
    _ensure_cards_loaded()
    encoder = encoder or ActionStateEncoder()
    examples: list[TrainingExample] = []
    target_games = max(0, int(games))
    for local_game_idx in range(target_games):
        game_idx = game_offset + local_game_idx
        opponent_key = _opponent_for(deck_key, game_idx)
        seat = game_idx % 2
        state, _, ais, target_player_idx, rng_state = _setup_match(
            deck_key,
            opponent_key,
            seed + game_idx * 101,
            seat,
            teacher_search_preset,
        )
        try:
            failed_signatures: dict[int, set[tuple]] = {0: set(), 1: set()}
            for _ in range(max_steps):
                if state.is_terminal():
                    break
                if state.pending_promotion_player >= 0:
                    ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                    continue
                if state.phase == TurnPhase.DRAW:
                    TurnManager(state).advance_phase()
                    continue
                if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
                    TurnManager(state).advance_phase()
                    continue

                player_idx = state.active_player_idx if state.phase != TurnPhase.SETUP else target_player_idx
                ai = ais[player_idx]
                if player_idx == target_player_idx:
                    actions = ai.legal_actions(state, player_idx)
                    selected = ai.choose_action(state, player_idx)
                    target_index = _find_action_index(actions, selected)
                    if actions and target_index is not None:
                        examples.append(TrainingExample(
                            encoder.encode_state(state, player_idx, deck_key),
                            [encoder.encode_action(state, player_idx, action) for action in actions],
                            target_index,
                            source="teacher",
                            value_target=max(-1.0, min(1.0, ai.evaluate_state(state, player_idx) / 1_000_000.0)),
                            teacher_target_index=target_index,
                            teacher_score=float(ai.evaluate_state(state, player_idx)),
                            phase_tag="bootstrap",
                        ))
                    action = selected
                else:
                    action = ai.choose_action(state, player_idx)

                before = (state.turn_number, state.phase, state.active_player_idx, state.winner)
                result = ai._apply_action_for_sim(state, player_idx, action)
                after = (state.turn_number, state.phase, state.active_player_idx, state.winner)
                signature = _action_signature(action)
                if result is None or not result.success or before == after:
                    failed_signatures[player_idx].add(signature)
                    if len(failed_signatures[player_idx]) >= 3:
                        force_end_turn(state, player_idx)
                        failed_signatures[player_idx].clear()
                else:
                    failed_signatures[player_idx].clear()
        finally:
            _restore_rng(rng_state)
    return examples


def _execute_bootstrap_task(task: BootstrapTask) -> list[TrainingExample]:
    _ensure_cards_loaded()
    return collect_bootstrap_examples(
        task.deck_key,
        task.games,
        task.seed,
        max_steps=task.max_steps,
        game_offset=task.game_start,
        teacher_search_preset=task.teacher_search_preset,
    )


class DeepTrainingTaskRunner:
    """Reusable process-pool runner for deep-training rollout tasks."""

    def __init__(self, workers: int | None):
        self.worker_count = _normalized_workers(workers)
        self.executor: ProcessPoolExecutor | None = None
        self._broken = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.executor is not None:
            shutdown = getattr(self.executor, "shutdown", None)
            if callable(shutdown):
                shutdown(wait=True)
            self.executor = None
        return False

    def _ensure_executor(self, task_count: int) -> ProcessPoolExecutor | None:
        if self._broken or self.worker_count <= 1 or task_count <= 1:
            return None
        if self.executor is None:
            max_workers = max(1, self.worker_count)
            self.executor = ProcessPoolExecutor(max_workers=max_workers, initializer=_worker_init)
        return self.executor

    def run_bootstrap_tasks(self, tasks: list[BootstrapTask]) -> list[list[TrainingExample]]:
        executor = self._ensure_executor(len(tasks))
        if executor is None:
            return [_execute_bootstrap_task(task) for task in tasks]
        try:
            return list(executor.map(_execute_bootstrap_task, tasks))
        except BrokenProcessPool:
            self._broken = True
            return [_execute_bootstrap_task(task) for task in tasks]

    def run_model_game_tasks(
        self,
        tasks: list[ModelGameTask],
    ) -> list[tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, int]]]:
        executor = self._ensure_executor(len(tasks))
        if executor is None:
            return [_execute_model_game_task(task) for task in tasks]
        try:
            # Send a contiguous batch to each worker. Shared model tensors are
            # serialized once per batch and the worker loads the model once,
            # instead of once per game.
            chunk_size = max(1, (len(tasks) + self.worker_count - 1) // self.worker_count)
            batches = [
                tasks[start:start + chunk_size]
                for start in range(0, len(tasks), chunk_size)
            ]
            batch_rows = list(executor.map(_execute_model_game_task_batch, batches))
            return [row for rows in batch_rows for row in rows]
        except BrokenProcessPool:
            self._broken = True
            return [_execute_model_game_task(task) for task in tasks]
        except (MemoryError, RuntimeError) as exc:
            if "memory" not in str(exc).lower() and "alloc" not in str(exc).lower():
                raise
            self._broken = True
            if self.executor is not None:
                self.executor.shutdown(wait=True, cancel_futures=True)
                self.executor = None
            return _execute_model_game_task_batch(tasks)


def _run_bootstrap_tasks(tasks: list[BootstrapTask], workers: int | None) -> list[list[TrainingExample]]:
    worker_count = _normalized_workers(workers)
    with DeepTrainingTaskRunner(worker_count) as runner:
        return runner.run_bootstrap_tasks(tasks)


def _collect_bootstrap_examples_parallel(
    deck_key: str,
    games: int,
    seed: int,
    *,
    max_steps: int,
    workers: int,
    teacher_search_preset: str,
    task_runner: DeepTrainingTaskRunner | None = None,
) -> list[TrainingExample]:
    target_games = max(0, int(games))
    if target_games <= 0:
        return []
    worker_count = _normalized_workers(workers)
    chunk_size = max(1, (target_games + worker_count * 2 - 1) // (worker_count * 2))
    tasks = [
        BootstrapTask(deck_key, seed, start, min(chunk_size, target_games - start), max_steps, teacher_search_preset)
        for start in range(0, target_games, chunk_size)
    ]
    examples: list[TrainingExample] = []
    task_rows = (
        task_runner.run_bootstrap_tasks(tasks)
        if task_runner is not None
        else _run_bootstrap_tasks(tasks, worker_count)
    )
    for rows in task_rows:
        examples.extend(rows)
    return examples


def _forward_example(model, example: TrainingExample, device: str):
    """Single-example forward pass used during action selection."""
    assert torch is not None
    state_numeric_size = _state_numeric_size(model)
    state_card_slots = _state_card_slots(model)
    action_numeric_size = _action_numeric_size(model)
    state_numeric = torch.tensor(
        [_fit_sequence(example.state.numeric, state_numeric_size, 0.0)],
        dtype=torch.float32,
        device=device,
    )
    state_cards = torch.tensor(
        [_fit_sequence(example.state.card_ids, state_card_slots, 0)],
        dtype=torch.long,
        device=device,
    )
    action_numeric = torch.tensor(
        [[_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in example.actions]],
        dtype=torch.float32,
        device=device,
    )
    action_cards = torch.tensor([[a.card_id for a in example.actions]], dtype=torch.long, device=device)
    return model(state_numeric, state_cards, action_numeric, action_cards)


def _forward_batch(model, examples: list[TrainingExample], device: str):
    """Batched forward pass for mini-batch training."""
    assert torch is not None
    B = len(examples)
    if B == 0:
        return None, None, None

    state_numeric_size = _state_numeric_size(model)
    state_card_slots = _state_card_slots(model)
    action_numeric_size = _action_numeric_size(model)
    state_numeric = torch.tensor(
        [_fit_sequence(ex.state.numeric, state_numeric_size, 0.0) for ex in examples],
        dtype=torch.float32,
        device=device,
    )
    state_cards = torch.tensor(
        [_fit_sequence(ex.state.card_ids, state_card_slots, 0) for ex in examples],
        dtype=torch.long,
        device=device,
    )

    max_actions = max(1, max(len(ex.actions) for ex in examples))
    action_numeric_rows: list[list[list[float]]] = []
    action_card_rows: list[list[int]] = []
    action_mask_rows: list[list[bool]] = []
    for ex in examples:
        n = len(ex.actions)
        numeric_row = [
            _fit_sequence(a.numeric, action_numeric_size, 0.0)
            for a in ex.actions
        ]
        card_row = [a.card_id for a in ex.actions]
        mask_row = [True] * n
        if n < max_actions:
            numeric_row.extend([[0.0] * action_numeric_size for _ in range(max_actions - n)])
            card_row.extend([0] * (max_actions - n))
            mask_row.extend([False] * (max_actions - n))
        action_numeric_rows.append(numeric_row[:max_actions])
        action_card_rows.append(card_row[:max_actions])
        action_mask_rows.append(mask_row[:max_actions])

    action_numeric = torch.tensor(action_numeric_rows, dtype=torch.float32, device=device)
    action_cards = torch.tensor(action_card_rows, dtype=torch.long, device=device)
    action_mask = torch.tensor(action_mask_rows, dtype=torch.bool, device=device)

    logits, value = model(state_numeric, state_cards, action_numeric, action_cards, action_mask)
    return logits, value, action_mask


def _forward_choice_batch(model, examples: list[ChoiceTrainingExample], device: str):
    """Batched forward pass for pending ActionRequest choice examples."""
    assert torch is not None
    B = len(examples)
    if B == 0:
        return None, None

    state_numeric_size = _state_numeric_size(model)
    state_card_slots = _state_card_slots(model)
    action_numeric_size = _action_numeric_size(model)
    state_numeric = torch.tensor(
        [_fit_sequence(ex.state.numeric, state_numeric_size, 0.0) for ex in examples],
        dtype=torch.float32,
        device=device,
    )
    state_cards = torch.tensor(
        [_fit_sequence(ex.state.card_ids, state_card_slots, 0) for ex in examples],
        dtype=torch.long,
        device=device,
    )

    max_choices = max(1, max(len(ex.candidate_choices) for ex in examples))
    choice_numeric_rows: list[list[list[float]]] = []
    choice_card_rows: list[list[int]] = []
    choice_mask_rows: list[list[bool]] = []
    for ex in examples:
        n = len(ex.candidate_choices)
        numeric_row = [
            _fit_sequence(a.numeric, action_numeric_size, 0.0)
            for a in ex.candidate_choices
        ]
        card_row = [a.card_id for a in ex.candidate_choices]
        mask_row = [True] * n
        if n < max_choices:
            numeric_row.extend([[0.0] * action_numeric_size for _ in range(max_choices - n)])
            card_row.extend([0] * (max_choices - n))
            mask_row.extend([False] * (max_choices - n))
        choice_numeric_rows.append(numeric_row[:max_choices])
        choice_card_rows.append(card_row[:max_choices])
        choice_mask_rows.append(mask_row[:max_choices])

    choice_numeric = torch.tensor(choice_numeric_rows, dtype=torch.float32, device=device)
    choice_cards = torch.tensor(choice_card_rows, dtype=torch.long, device=device)
    choice_mask = torch.tensor(choice_mask_rows, dtype=torch.bool, device=device)

    if hasattr(model, "score_choices"):
        logits = model.score_choices(state_numeric, state_cards, choice_numeric, choice_cards, choice_mask)
    else:
        logits, _ = model(state_numeric, state_cards, choice_numeric, choice_cards, choice_mask)
    return logits, choice_mask


def _value_target_for(ex: TrainingExample) -> float:
    if _is_rl_example(ex):
        return float(ex.return_target)
    return float(ex.value_target)


def _has_value_target_for(ex: TrainingExample) -> bool:
    if _is_rl_example(ex):
        return True
    if ex.source in {"teacher", "dagger"} and ex.teacher_target_index is not None:
        return True
    if abs(float(ex.teacher_score or 0.0)) > 1e-12:
        return True
    return abs(float(ex.value_target or 0.0)) > 1e-12


def _advantage_for(ex: TrainingExample) -> float | None:
    if ex.advantage is not None:
        return float(ex.advantage)
    if ex.policy_advantage is not None:
        return float(ex.policy_advantage)
    return None


def _normalize_advantages(examples: list[TrainingExample]) -> None:
    values = [_advantage_for(ex) for ex in examples if _is_rl_example(ex) and _advantage_for(ex) is not None]
    values = [float(v) for v in values if v is not None]
    if not values:
        return
    mean = sum(values) / len(values)
    variance = sum((v - mean) ** 2 for v in values) / max(1, len(values))
    std = max(1e-6, variance ** 0.5)
    for ex in examples:
        if _is_rl_example(ex) and _advantage_for(ex) is not None:
            normalized = max(-3.0, min(3.0, (_advantage_for(ex) - mean) / std))
            ex.advantage = normalized
            ex.policy_advantage = normalized


def _train_examples(
    model,
    examples: list[TrainingExample],
    *,
    device: str,
    learning_rate: float,
    epochs: int = 1,
    batch_size: int = 64,
    entropy_coef: float = 0.02,
    ppo_clip: float = 0.15,
    optimizer=None,
    grad_scaler=None,
    use_amp: bool = False,
) -> dict[str, Any]:
    if not examples:
        return {
            "examples": 0,
            "loss": 0.0,
            "total_loss": 0.0,
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
        }
    assert torch is not None
    import torch.nn.functional as F

    _normalize_advantages(examples)
    model.train()
    owns_optimizer = optimizer is None
    if optimizer is None:
        optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate, weight_decay=1e-4)
    else:
        for group in optimizer.param_groups:
            group["lr"] = learning_rate
    bs = max(1, int(batch_size))
    total_steps = max(1, int(epochs)) * max(1, (len(examples) + bs - 1) // bs)
    scheduler = (
        torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer, T_max=total_steps, eta_min=learning_rate * 0.1,
        )
        if owns_optimizer else None
    )
    amp_enabled = bool(use_amp and str(device).startswith("cuda"))
    total_loss = 0.0
    total_policy_loss = 0.0
    total_value_loss = 0.0
    total_entropy = 0.0
    steps = 0

    for _ in range(max(1, int(epochs))):
        random.shuffle(examples)
        for batch_start in range(0, len(examples), bs):
            batch = examples[batch_start:batch_start + bs]
            with torch.autocast(
                device_type="cuda",
                dtype=torch.float16,
                enabled=amp_enabled,
            ):
                logits, value, action_mask = _forward_batch(model, batch, device)
                if logits is None:
                    continue

                batch_len = len(batch)
                value_indices = [i for i, ex in enumerate(batch) if _has_value_target_for(ex)]
                log_probs = F.log_softmax(logits.float(), dim=-1)
                probs = torch.softmax(logits.float(), dim=-1)
                entropy_per_ex = -(probs * log_probs).sum(dim=-1)

                action_counts = action_mask.sum(dim=-1)
                target_idx = torch.tensor(
                    [max(0, ex.target_index) for ex in batch], dtype=torch.long, device=device,
                )
                valid = action_counts > 0
                for i, ex in enumerate(batch):
                    if not ex.actions or ex.target_index >= int(action_counts[i].item()):
                        valid[i] = False

                selected_lp = log_probs[torch.arange(batch_len, device=device), target_idx]
                is_rl = torch.tensor([_is_rl_example(ex) for ex in batch], device=device)
                example_weights = torch.tensor(
                    [_supervised_example_weight(ex) for ex in batch],
                    dtype=torch.float32,
                    device=device,
                )
                has_adv = torch.tensor(
                    [_advantage_for(ex) is not None for ex in batch], device=device,
                )
                has_old_lp = torch.tensor(
                    [ex.behavior_log_prob is not None for ex in batch], device=device,
                )
                advs = torch.tensor(
                    [max(-3.0, min(3.0, float(_advantage_for(ex) or 0.0))) for ex in batch],
                    device=device,
                )
                old_lp = torch.tensor(
                    [float(ex.behavior_log_prob or 0.0) for ex in batch], device=device,
                )

                policy_targets = torch.zeros_like(log_probs)
                has_policy_target_rows: list[bool] = []
                for i, ex in enumerate(batch):
                    raw_target = list(ex.policy_target or [])
                    count = min(len(raw_target), int(action_counts[i].item()))
                    total = sum(max(0.0, float(v)) for v in raw_target[:count])
                    has_target = count > 0 and total > 0.0
                    has_policy_target_rows.append(has_target)
                    if has_target:
                        policy_targets[i, :count] = torch.tensor(
                            [max(0.0, float(v)) / total for v in raw_target[:count]],
                            dtype=log_probs.dtype,
                            device=device,
                        )
                has_policy_target = torch.tensor(has_policy_target_rows, device=device)

                loss_per_ex = torch.zeros(batch_len, device=device)
                loss_weights = torch.zeros(batch_len, device=device)

                # Preserve the full planner search signal rather than reducing it
                # to the one action sampled from the visit distribution.
                search_distill = valid & has_policy_target
                if search_distill.any():
                    distill_loss = -(policy_targets * log_probs).sum(dim=-1)
                    distill_weights = torch.where(is_rl, torch.ones_like(example_weights), example_weights)
                    loss_per_ex = loss_per_ex + distill_loss * search_distill.float() * distill_weights
                    loss_weights = loss_weights + search_distill.float() * distill_weights

                ppo = valid & is_rl & has_adv & has_old_lp & ~has_policy_target
                if ppo.any():
                    ratio = torch.exp(selected_lp - old_lp)
                    clipped_ratio = torch.clamp(ratio, 1.0 - ppo_clip, 1.0 + ppo_clip)
                    ppo_loss = -torch.minimum(ratio * advs, clipped_ratio * advs)
                    loss_per_ex = loss_per_ex + ppo_loss * ppo.float()
                    loss_weights = loss_weights + ppo.float()

                pg = valid & is_rl & has_adv & ~has_old_lp & ~has_policy_target
                if pg.any():
                    loss_per_ex = loss_per_ex + (-selected_lp * advs) * pg.float()
                    loss_weights = loss_weights + pg.float()

                sl = valid & ~is_rl & ~has_policy_target
                if sl.any():
                    loss_per_ex = loss_per_ex + (-selected_lp) * sl.float() * example_weights
                    loss_weights = loss_weights + sl.float() * example_weights

                divisor = max(1, int(valid.sum().item()))
                policy_divisor = loss_weights.sum().clamp_min(1.0)
                policy_loss = loss_per_ex.sum() / policy_divisor
                entropy = (entropy_per_ex * valid.float()).sum() / divisor
                if value_indices:
                    predicted_values = value[value_indices].float()
                    value_targets = torch.tensor(
                        [float(_value_target_for(ex)) for i, ex in enumerate(batch) if i in value_indices],
                        dtype=torch.float32,
                        device=device,
                    )
                    value_loss = F.mse_loss(predicted_values, value_targets)
                else:
                    value_loss = torch.tensor(0.0, device=device)
                loss = policy_loss + 0.5 * value_loss - entropy_coef * entropy

            optimizer.zero_grad(set_to_none=True)
            if grad_scaler is not None and amp_enabled:
                grad_scaler.scale(loss).backward()
                grad_scaler.unscale_(optimizer)
                torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
                grad_scaler.step(optimizer)
                grad_scaler.update()
            else:
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
                optimizer.step()
            if scheduler is not None:
                scheduler.step()

            total_loss += float(loss.detach().cpu().item())
            total_policy_loss += float(policy_loss.detach().cpu().item())
            total_value_loss += float(value_loss.detach().cpu().item())
            total_entropy += float(entropy.detach().cpu().item())
            steps += 1

    model.eval()
    avg_total = round(total_loss / max(1, steps), 6)
    return {
        "examples": len(examples),
        "loss": avg_total,
        "total_loss": avg_total,
        "policy_loss": round(total_policy_loss / max(1, steps), 6),
        "value_loss": round(total_value_loss / max(1, steps), 6),
        "entropy": round(total_entropy / max(1, steps), 6),
    }


def _train_choice_examples(
    model,
    examples: list[ChoiceTrainingExample],
    *,
    device: str,
    learning_rate: float,
    epochs: int = 1,
    batch_size: int = 64,
    optimizer=None,
    grad_scaler=None,
    use_amp: bool = False,
) -> dict[str, Any]:
    if not bool(getattr(model, "choice_head_enabled", True)):
        return {"choice_examples": 0, "choice_loss": 0.0}
    if not examples:
        return {"choice_examples": 0, "choice_loss": 0.0}
    assert torch is not None
    import torch.nn.functional as F

    model.train()
    owns_optimizer = optimizer is None
    if optimizer is None:
        optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate, weight_decay=1e-4)
    else:
        for group in optimizer.param_groups:
            group["lr"] = learning_rate
    bs = max(1, int(batch_size))
    total_steps = max(1, int(epochs)) * max(1, (len(examples) + bs - 1) // bs)
    scheduler = (
        torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer, T_max=total_steps, eta_min=learning_rate * 0.1,
        )
        if owns_optimizer else None
    )
    amp_enabled = bool(use_amp and str(device).startswith("cuda"))
    total_loss = 0.0
    steps = 0
    for _ in range(max(1, int(epochs))):
        random.shuffle(examples)
        for batch_start in range(0, len(examples), bs):
            batch = examples[batch_start:batch_start + bs]
            with torch.autocast(
                device_type="cuda",
                dtype=torch.float16,
                enabled=amp_enabled,
            ):
                logits, choice_mask = _forward_choice_batch(model, batch, device)
                if logits is None or choice_mask is None:
                    continue
                loss_total = torch.tensor(0.0, device=device)
                valid_examples = 0
                for i, ex in enumerate(batch):
                    choice_count = int(choice_mask[i].sum().item())
                    target_index = int(ex.teacher_target_index)
                    if not ex.candidate_choices or choice_count <= 0 or target_index >= choice_count:
                        continue
                    valid_examples += 1
                    loss_total = loss_total + F.cross_entropy(
                        logits[i, :choice_count].float().unsqueeze(0),
                        torch.tensor([target_index], device=device),
                    )
                if valid_examples <= 0:
                    continue
                loss = loss_total / valid_examples
            optimizer.zero_grad(set_to_none=True)
            if grad_scaler is not None and amp_enabled:
                grad_scaler.scale(loss).backward()
                grad_scaler.unscale_(optimizer)
                torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
                grad_scaler.step(optimizer)
                grad_scaler.update()
            else:
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
                optimizer.step()
            if scheduler is not None:
                scheduler.step()
            total_loss += float(loss.detach().cpu().item())
            steps += 1

    model.eval()
    return {
        "choice_examples": len(examples),
        "choice_loss": round(total_loss / max(1, steps), 6),
    }


def _select_model_action(
    model,
    encoder,
    state,
    player_idx: int,
    deck_key: str,
    legal_ai,
    device: str,
    temperature: float,
):
    assert torch is not None
    actions = legal_ai.legal_actions(state, player_idx)
    if not actions:
        return AIAction(PlayerAction.END_TURN, {}, terminal=True), None
    encoded_state = encoder.encode_state(state, player_idx, deck_key)
    encoded_actions = [encoder.encode_action(state, player_idx, action) for action in actions]
    with torch.no_grad():
        example = TrainingExample(encoded_state, encoded_actions, 0, source="self_play")
        logits, value = _forward_example(model, example, device)
        if temperature <= 0:
            probs = torch.softmax(logits[0], dim=0)
            candidate_indices = torch.argsort(logits[0], descending=True).detach().cpu().tolist()
        else:
            scaled_logits = logits[0] / max(0.05, temperature)
            probs = torch.softmax(scaled_logits, dim=0)
            candidate_indices = torch.multinomial(
                probs,
                num_samples=len(actions),
                replacement=False,
            ).detach().cpu().tolist()
        target_index = int(candidate_indices[0])
        found_executable = False
        for candidate_idx in candidate_indices:
            if _action_executes_on_clone(legal_ai, state, player_idx, actions[candidate_idx]):
                target_index = int(candidate_idx)
                found_executable = True
                break
        if not found_executable:
            target_index = next(
                (idx for idx, action in enumerate(actions) if action.action == PlayerAction.END_TURN),
                target_index,
            )
        selected_action = _postprocess_preferred_action(
            legal_ai,
            state,
            player_idx,
            actions[target_index],
            actions,
        )
        corrected_index = _find_action_index(actions, selected_action)
        if corrected_index is not None:
            target_index = int(corrected_index)
        log_probs = torch.log(probs.clamp_min(1e-7)).clamp(min=-10.0)
        predicted_value = float(value[0].detach().cpu().item())
        behavior_log_prob = float(log_probs[target_index].detach().cpu().item())
    return actions[target_index], TrainingExample(
        encoded_state,
        encoded_actions,
        target_index,
        source="self_play",
        value_target=predicted_value,
        behavior_log_prob=behavior_log_prob,
        model_score=predicted_value,
        phase_tag="rl",
    )


def _action_executes_on_clone(ai: Any, state, player_idx: int, action: AIAction) -> bool:
    """Validate the final selected action without mutating the live game."""
    if action.action not in {
        PlayerAction.PLAY_TRAINER,
        PlayerAction.USE_ABILITY,
        PlayerAction.USE_STADIUM,
        PlayerAction.RETREAT,
        PlayerAction.DECLARE_ATTACK,
    }:
        return True
    rng_state = random.getstate()
    try:
        cloned = state_from_snapshot(snapshot_state(state), rebuild_event_bus=True)
        result = ai._apply_action_for_sim(cloned, player_idx, action)
        return result is not None and bool(result.success)
    except Exception:
        return False
    finally:
        random.setstate(rng_state)


def _teacher_label_state(
    encoder: ActionStateEncoder,
    state,
    player_idx: int,
    deck_key: str,
    teacher_ai,
    *,
    source: str = "dagger",
    phase_tag: str = "dagger",
) -> TrainingExample | None:
    actions = teacher_ai.legal_actions(state, player_idx)
    if not actions:
        return None
    selected = teacher_ai.choose_action(state, player_idx)
    target_index = _find_action_index(actions, selected)
    if target_index is None:
        return None
    teacher_score = float(teacher_ai.evaluate_state(state, player_idx))
    return TrainingExample(
        encoder.encode_state(state, player_idx, deck_key),
        [encoder.encode_action(state, player_idx, action) for action in actions],
        target_index,
        source=source,
        value_target=max(-1.0, min(1.0, teacher_score / 1_000_000.0)),
        teacher_target_index=target_index,
        teacher_score=teacher_score,
        phase_tag=phase_tag,
    )


def _snapshot_metrics(state, player_idx: int, evaluator=None) -> dict[str, float]:
    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    eval_score = 0.0
    if evaluator is not None:
        eval_score = float(evaluator.evaluate_state(state, player_idx))
    own_pokemon = [p for _, p in player.get_all_pokemon() if p]
    opp_pokemon = [p for _, p in opponent.get_all_pokemon() if p]
    return {
        "prizes_taken": float(6 - len(player.prizes)),
        "opp_prizes_taken": float(6 - len(opponent.prizes)),
        "bench_count": float(player.bench_count()),
        "opp_bench_count": float(opponent.bench_count()),
        "hand_count": float(len(player.hand)),
        "opp_hand_count": float(opponent.hand_count),
        "eval_score": eval_score,
        "own_pokemon_count": float(len(own_pokemon)),
        "opp_pokemon_count": float(len(opp_pokemon)),
        "own_total_energy": float(sum(len(getattr(p, "energy_cards", []) or []) for p in own_pokemon)),
        "opp_active_damage": float(getattr(opponent.active, "damage_counters", 0) if opponent.active else 0),
    }


def _step_reward(before: dict[str, float], after: dict[str, float], *, invalid: bool = False) -> float:
    """Dense reward with intermediate signals: prizes, KOs, damage, energy."""
    reward = 0.0

    # Prize delta (boosted from 0.4 to 0.5)
    prize_delta = after.get("prizes_taken", 0.0) - before.get("prizes_taken", 0.0)
    opp_prize_delta = after.get("opp_prizes_taken", 0.0) - before.get("opp_prizes_taken", 0.0)
    reward += prize_delta * 0.5
    reward -= opp_prize_delta * 0.5

    # KO reward — pokemon-in-play count decrease means a KO happened
    opp_ko = max(0.0, before.get("opp_pokemon_count", 0.0) - after.get("opp_pokemon_count", 0.0))
    own_ko = max(0.0, before.get("own_pokemon_count", 0.0) - after.get("own_pokemon_count", 0.0))
    reward += opp_ko * 0.3
    reward -= own_ko * 0.3

    # Damage dealt to opponent active (damage counters increased)
    opp_damage_delta = after.get("opp_active_damage", 0.0) - before.get("opp_active_damage", 0.0)
    if opp_damage_delta > 0:
        reward += min(0.15, opp_damage_delta * 0.02)

    # Energy attached to own pokemon
    energy_delta = after.get("own_total_energy", 0.0) - before.get("own_total_energy", 0.0)
    if energy_delta > 0:
        reward += min(0.1, energy_delta * 0.05)

    # Teacher evaluation score delta
    score_delta = after.get("eval_score", 0.0) - before.get("eval_score", 0.0)
    reward += max(-0.25, min(0.25, score_delta / 2500.0))

    # Bench / hand deltas
    bench_delta = after.get("bench_count", 0.0) - before.get("bench_count", 0.0)
    hand_delta = after.get("hand_count", 0.0) - before.get("hand_count", 0.0)
    reward += max(-0.05, min(0.05, bench_delta * 0.03))
    reward += max(-0.04, min(0.04, hand_delta * 0.01))

    if invalid:
        reward -= 0.15
    return max(-1.0, min(1.0, float(reward)))


def _terminal_reward(logical_winner: int | None, score: float) -> float:
    terminal_reward = max(-1.0, min(1.0, float(score) / 1_000_000.0))
    if logical_winner == 0:
        return max(terminal_reward, 1.0)
    if logical_winner == 1:
        return min(terminal_reward, -1.0)
    return terminal_reward


def _finalize_episode_examples(
    examples: list[TrainingExample],
    terminal_reward: float,
    *,
    gamma: float = 0.99,
    gae_lambda: float = 0.95,
) -> list[TrainingExample]:
    """Compute GAE advantages and value targets for self-play examples.

    GAE: A_t = δ_t + γλ·A_{t+1}  where δ_t = r_t + γ·V(s_{t+1}) - V(s_t)
    value_target = A_t + V(s_t)
    """
    sp_indices = []
    sp_values = []
    for i, ex in enumerate(examples):
        if ex.source == "self_play":
            sp_indices.append(i)
            sp_values.append(float(ex.value_target))
    if not sp_indices:
        return examples
    sp_values.append(0.0)  # V(s_T) = 0

    n = len(sp_indices)
    last_gae = 0.0
    gae_advantages = []
    for i in range(n - 1, -1, -1):
        cur_v = sp_values[i]
        next_v = sp_values[i + 1]
        if i == n - 1:
            delta = terminal_reward - cur_v
        else:
            r = float(examples[sp_indices[i]].reward)
            delta = r + gamma * next_v - cur_v
        last_gae = delta + gamma * gae_lambda * last_gae
        gae_advantages.append(last_gae)

    gae_advantages.reverse()
    for value_idx, (idx, gae_adv) in enumerate(zip(sp_indices, gae_advantages)):
        ex = examples[idx]
        if ex.phase_tag == "alpha_zero":
            ex.value_target = float(terminal_reward)
            ex.return_target = float(terminal_reward)
            ex.advantage = float(terminal_reward) - float(sp_values[value_idx])
            ex.policy_advantage = ex.advantage
            continue
        ex.advantage = gae_adv
        ex.policy_advantage = gae_adv
        ex.value_target = gae_adv + float(ex.value_target)
        ex.return_target = ex.value_target
    return examples


class _RuleOnlySimulationAI:
    """Minimal rules-engine adapter for RL-only Deep AI training.

    It intentionally avoids ChallengeAI policy weights, action selection, and
    evaluator logic. The neural model supplies priors/value during MCTS; this
    class only gives the planner legal actions, rule execution, and a neutral
    fallback value when the model cannot score a state.
    """

    def __init__(self, deck_key: str, seed: int = 17):
        self.deck_key = deck_key
        self.random = random.Random(seed)
        self.engine = DEFAULT_GAME_ENGINE
        self.config = type(
            "RuleOnlyConfig",
            (),
            {"random_seed": int(seed), "deck_key": deck_key},
        )()

    def legal_actions(self, state, player_idx: int) -> list[GameAction]:
        return list(self.engine.legal_actions(state, player_idx))

    def choose_action(self, state, player_idx: int) -> GameAction:
        actions = self.legal_actions(state, player_idx)
        if not actions:
            return GameAction(PlayerAction.END_TURN, {}, True, player_idx)
        ranked = sorted(
            actions,
            key=lambda action: (
                self._quick_action_priority(state, player_idx, action),
                -len(str(action.signature)),
            ),
            reverse=True,
        )
        return ranked[0]

    def resolve_pending_action(self, state, request):
        if isinstance(request, ChoiceRequest):
            return self._choice_response(request)
        return None

    def _choice_response(self, *args) -> ChoiceResponse:
        request = args[-1]
        if request.can_cancel and not request.options and request.min_select <= 0:
            return ChoiceResponse(request.request_id, (), True)
        count = min(len(request.options), max(request.min_select, request.max_select))
        return ChoiceResponse(
            request.request_id,
            tuple(option.option_id for option in request.options[:count]),
        )

    def _apply_action_for_sim(self, state, player_idx, action):
        action = action.with_actor(player_idx) if getattr(action, "actor", None) is None else action
        return self.engine.apply_action(
            state,
            action,
            RandomSource(self.random.randrange(1 << 30)),
            auto_resolve=True,
            choice_policy=self._choice_response,
            auto_finish_attack=True,
        )

    def _auto_promote_for_sim(self, state):
        player_idx = int(getattr(state, "pending_promotion_player", -1))
        if player_idx < 0:
            return
        actions = [
            action for action in self.legal_actions(state, player_idx)
            if (action.action.name if isinstance(action.action, PlayerAction) else str(action.action)) == "PROMOTE"
        ]
        if actions:
            self._apply_action_for_sim(state, player_idx, actions[0])

    def evaluate_state(self, state, player_idx: int) -> float:
        if state.is_terminal():
            if getattr(state, "result_status", "") == "DRAW":
                return 0.0
            return 1_000_000.0 if state.winner == player_idx else -1_000_000.0
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        prize_delta = len(opponent.prizes) - len(player.prizes)
        own_hp = self._board_hp(player)
        opp_hp = self._board_hp(opponent)
        own_energy = self._board_energy(player)
        opp_energy = self._board_energy(opponent)
        opponent_hand = int(getattr(opponent, "hand_count", len(opponent.hand)))
        return (
            prize_delta * 220.0
            + (own_hp - opp_hp) * 0.20
            + (own_energy - opp_energy) * 25.0
            + (len(player.hand) - opponent_hand) * 4.0
            + (len(player.deck) - len(opponent.deck)) * 0.5
        )

    def _quick_action_priority(self, state, player_idx: int, action: GameAction) -> float:
        action_name = action.action.name if isinstance(action.action, PlayerAction) else str(action.action)
        priorities = {
            "SETUP_DONE": -10.0,
            PlayerAction.PLAY_BASIC.name: 80.0,
            PlayerAction.EVOLVE.name: 95.0,
            PlayerAction.ATTACH_ENERGY.name: 90.0,
            PlayerAction.PLAY_TRAINER.name: 70.0,
            PlayerAction.USE_ABILITY.name: 75.0,
            PlayerAction.USE_STADIUM.name: 50.0,
            PlayerAction.RETREAT.name: 35.0,
            PlayerAction.DECLARE_ATTACK.name: 120.0,
            PlayerAction.END_TURN.name: -25.0,
        }
        score = priorities.get(action_name, 0.0)
        params = dict(getattr(action, "params", {}) or {})
        if action_name == PlayerAction.PLAY_BASIC.name and params.get("target") == "active":
            score += 30.0
        if action_name == PlayerAction.DECLARE_ATTACK.name:
            player = state.get_player(player_idx)
            opponent = state.get_player(1 - player_idx)
            if player.active and opponent.active:
                attack_idx = params.get("attack_idx")
                attacks = getattr(player.active.card, "attacks", []) or []
                if isinstance(attack_idx, int) and 0 <= attack_idx < len(attacks):
                    damage = _damage_number(getattr(attacks[attack_idx], "damage", 0))
                    score += min(220.0, damage)
                    if damage >= opponent.active.current_hp:
                        score += 300.0
        return score

    def _board_hp(self, player) -> float:
        return float(sum(p.current_hp for _slot, p in player.get_all_pokemon() if p))

    def _board_energy(self, player) -> float:
        return float(sum(len(getattr(p, "energy_cards", []) or []) for _slot, p in player.get_all_pokemon() if p))


def _damage_number(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        digits = "".join(ch for ch in str(value) if ch.isdigit())
        return int(digits) if digits else 0


class _ModelOpponentActor:
    """Thin adapter that lets a PyTorch model act as an opponent in self-play."""

    def __init__(self, opponent_model, fallback_ai, device: str, deck_key: str):
        self._model = opponent_model
        self._fallback = fallback_ai
        self._device = device
        self._deck_key = deck_key
        self._encoder = ActionStateEncoder()

    def legal_actions(self, state, player_idx: int):
        return self._fallback.legal_actions(state, player_idx)

    def choose_action(self, state, player_idx: int):
        from engine.ai.dl.training import _select_model_action as _select

        try:
            action, _ = _select(
                self._model, self._encoder, state, player_idx,
                self._deck_key, self._fallback, self._device, temperature=0.5,
            )
            return action
        except Exception:
            return self._fallback.choose_action(state, player_idx)

    def _apply_action_for_sim(self, state, player_idx, action):
        return self._fallback._apply_action_for_sim(state, player_idx, action)

    def _auto_promote_for_sim(self, state):
        return self._fallback._auto_promote_for_sim(state)

    def evaluate_state(self, state, player_idx: int) -> float:
        return self._fallback.evaluate_state(state, player_idx)


def _action_has_no_available_target(ai: Any, state, player_idx: int, action: AIAction) -> bool:
    if action.action != PlayerAction.PLAY_TRAINER:
        return False
    if not hasattr(ai, "_effects_have_available_value"):
        return False
    try:
        player = state.get_player(player_idx)
        hand_idx = action.params.get("hand_idx")
        if not isinstance(hand_idx, int) or not (0 <= hand_idx < len(player.hand)):
            return True
        effects = trainer_runtime_effects(player.hand[hand_idx])
        return bool(effects) and not ai._effects_have_available_value(state, player_idx, effects)
    except Exception:
        return False


def _play_model_game(
    model,
    deck_key: str,
    seed: int,
    *,
    device: str,
    max_steps: int,
    record: bool,
    teacher_search_preset: str = "hybrid",
    temperature: float = 0.9,
    teacher_label_model_states: bool = True,
    phase_tag: str = "rl",
    opponent_model: Any = None,
    pure_rl: bool = False,
    use_mcts: bool = False,
    mcts_simulations: int = 200,
    mcts_chance_nodes: bool = True,
    curiosity_tracker: Any = None,
    opponent_deck_key: str | None = None,
    rule_only: bool = False,
) -> tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, Any]]:
    encoder = ActionStateEncoder()
    opponent_key = opponent_deck_key or _opponent_for(deck_key, seed)
    seat = seed % 2
    state, _, ais, target_player_idx, rng_state = _setup_match(
        deck_key, opponent_key, seed, seat, teacher_search_preset, rule_only=rule_only
    )
    # Replace opponent AI with model-based actor when self-play is requested
    opponent_idx = 1 - target_player_idx
    if opponent_model is not None:
        ais[opponent_idx] = _ModelOpponentActor(
            opponent_model,
            ais[opponent_idx],
            device,
            opponent_key,
        )
    examples: list[TrainingExample] = []
    choice_examples: list[ChoiceTrainingExample] = []
    diagnostics: dict[str, Any] = {
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "decision_seconds": 0.0,
        "max_step_exhaustions": 0,
        "seat": seat,
    }
    target_ai = ais[target_player_idx]
    original_choice_resolver = None

    # Set up the shared-planner compatibility adapter if enabled.
    mcts_searcher = None
    if use_mcts and model is not None:
        from engine.ai.dl.mcts import MCTSGuidedSearch
        mcts_searcher = MCTSGuidedSearch(
            model, encoder, target_ai,
            num_simulations=mcts_simulations,
            temperature=temperature,
            use_chance_nodes=mcts_chance_nodes,
            device=device,
            add_dirichlet_noise=True,
            dirichlet_epsilon=0.25,
        )

    try:
        if record and not pure_rl:
            original_choice_resolver = target_ai._resolve_pending_for_sim

            def record_choice(state_arg, req_arg):
                choice = original_choice_resolver(state_arg, req_arg)
                req_player = req_arg.player if req_arg.player in (0, 1) else target_player_idx
                if req_player == target_player_idx:
                    choice_example = _choice_training_example(
                        encoder,
                        state_arg,
                        req_arg,
                        choice,
                        deck_key,
                        source="teacher",
                        phase_tag=phase_tag,
                    )
                    if choice_example is not None:
                        choice_examples.append(choice_example)
                return choice

            target_ai._resolve_pending_for_sim = record_choice

        failed_signatures: dict[int, set[tuple]] = {0: set(), 1: set()}
        prev_player_idx: int | None = None
        for _ in range(max_steps):
            if state.is_terminal():
                break
            if state.pending_promotion_player >= 0:
                ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                continue
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).advance_phase()
                continue
            if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
                TurnManager(state).advance_phase()
                continue

            player_idx = state.active_player_idx if state.phase != TurnPhase.SETUP else target_player_idx
            if prev_player_idx is not None and player_idx != prev_player_idx:
                failed_signatures[player_idx].clear()
            prev_player_idx = player_idx
            example: TrainingExample | None = None
            before_metrics: dict[str, float] | None = None
            decision_started = time.perf_counter()
            if player_idx == target_player_idx:
                before_metrics = _snapshot_metrics(state, target_player_idx, target_ai) if record else None

                # Teacher labeling (skip in pure RL mode)
                if record and teacher_label_model_states and not pure_rl:
                    teacher_example = _teacher_label_state(
                        encoder,
                        state,
                        player_idx,
                        deck_key,
                        target_ai,
                        source="dagger",
                        phase_tag=phase_tag,
                    )
                    if teacher_example is not None:
                        examples.append(teacher_example)

                # Action selection: shared planner or direct model.
                if mcts_searcher is not None:
                    actions = target_ai.legal_actions(state, player_idx)
                    search_result = mcts_searcher.search(
                        state,
                        player_idx,
                        deck_key,
                        actions=actions,
                        deadline=(
                            decision_started + PRODUCTION_MCTS_DECISION_SECONDS
                            if temperature <= 0.05 else None
                        ),
                    )
                    if temperature <= 0.05:
                        candidate_indices = sorted(
                            range(len(actions)),
                            key=lambda idx: search_result.action_probs.get(idx, 0.0),
                            reverse=True,
                        )
                    else:
                        roll = random.random()
                        cumulative = 0.0
                        action_idx = search_result.best_action_idx
                        for idx in range(len(actions)):
                            cumulative += float(search_result.action_probs.get(idx, 0.0))
                            if roll <= cumulative:
                                action_idx = idx
                                break
                        candidate_indices = [action_idx] + sorted(
                            (idx for idx in range(len(actions)) if idx != action_idx),
                            key=lambda idx: search_result.action_probs.get(idx, 0.0),
                            reverse=True,
                        )
                    action_idx = max(0, min(candidate_indices[0], len(actions) - 1))
                    for candidate_idx in candidate_indices:
                        if _action_executes_on_clone(
                            target_ai,
                            state,
                            player_idx,
                            actions[candidate_idx],
                        ):
                            action_idx = candidate_idx
                            break
                    original_action_idx = int(action_idx)
                    action = _postprocess_preferred_action(
                        target_ai,
                        state,
                        player_idx,
                        actions[action_idx],
                        actions,
                    )
                    corrected_idx = _find_action_index(actions, action)
                    if corrected_idx is not None:
                        action_idx = int(corrected_idx)
                    encoded_state = encoder.encode_state(state, player_idx, deck_key)
                    encoded_actions = [encoder.encode_action(state, player_idx, a) for a in actions]
                    if actions:
                        with torch.no_grad():
                            logits, value = _forward_example(model, TrainingExample(encoded_state, encoded_actions, 0, source="self_play"), device)
                            predicted_value = float(value[0].detach().cpu().item())
                        policy_target = [
                            float(search_result.action_probs.get(idx, 0.0))
                            for idx in range(len(actions))
                        ]
                        if corrected_idx is not None and int(corrected_idx) != original_action_idx:
                            policy_target = [
                                1.0 if idx == int(corrected_idx) else 0.0
                                for idx in range(len(actions))
                            ]
                        example = TrainingExample(
                            encoded_state, encoded_actions, action_idx,
                            source="self_play",
                            value_target=predicted_value,
                            phase_tag=phase_tag,
                            policy_target=policy_target,
                        )
                else:
                    action, example = _select_model_action(
                        model, encoder, state, player_idx, deck_key, target_ai, device, temperature=temperature
                    )
                    if example is not None:
                        example.phase_tag = phase_tag
                ai = target_ai
            else:
                ai = ais[player_idx]
                action = ai.choose_action(state, player_idx)

            if player_idx == target_player_idx:
                diagnostics["actions"] += 1
                decision_elapsed = time.perf_counter() - decision_started
                diagnostics["decision_seconds"] += decision_elapsed
                if decision_elapsed > 8.0:
                    diagnostics["decision_timeouts"] += 1
                if _action_has_no_available_target(ai, state, player_idx, action):
                    diagnostics["no_target_actions"] += 1
            try:
                result = ai._apply_action_for_sim(state, player_idx, action)
            except Exception:
                result = None
                if player_idx == target_player_idx:
                    diagnostics["rule_exceptions"] += 1
            signature = _action_signature(action)
            invalid = result is None or not result.success
            if player_idx == target_player_idx and invalid:
                diagnostics["invalid_actions"] += 1
            if invalid:
                failed_signatures[player_idx].add(signature)
                if len(failed_signatures[player_idx]) >= 2:
                    force_end_turn(state, player_idx)
                    failed_signatures[player_idx].clear()
            else:
                failed_signatures[player_idx].clear()

            if record and example is not None and before_metrics is not None:
                after_metrics = _snapshot_metrics(state, target_player_idx, target_ai)
                step_r = _step_reward(before_metrics, after_metrics, invalid=invalid)

                # Add curiosity bonus if tracker is active
                if curiosity_tracker is not None:
                    curiosity_bonus = curiosity_tracker.bonus(state, target_player_idx)
                    step_r += curiosity_bonus

                example.reward = step_r
                examples.append(example)

        if state.is_terminal():
            logical_winner = (
                None
                if state.result_status == "DRAW"
                else 0 if state.winner == target_player_idx else 1
            )
            score = terminal_training_score(state, target_player_idx)
        else:
            diagnostics["max_step_exhaustions"] = 1
            soft_winner = _determine_soft_winner(state)
            state.winner = soft_winner
            logical_winner = 0 if soft_winner == target_player_idx else 1
            score = terminal_training_score(state, target_player_idx)
        _finalize_episode_examples(examples, _terminal_reward(logical_winner, score))
        return logical_winner, score, examples, choice_examples, diagnostics
    finally:
        if original_choice_resolver is not None:
            target_ai._resolve_pending_for_sim = original_choice_resolver
        _restore_rng(rng_state)


def _play_challenge_baseline_game(
    deck_key: str,
    seed: int,
    *,
    max_steps: int,
    teacher_search_preset: str,
) -> tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, Any]]:
    """Play ChallengeAI as the target deck against the same rotating ChallengeAI opponents."""
    _ensure_cards_loaded()
    opponent_key = _opponent_for(deck_key, seed)
    seat = seed % 2
    state, _, ais, target_player_idx, rng_state = _setup_match(
        deck_key,
        opponent_key,
        seed,
        seat,
        teacher_search_preset,
    )
    diagnostics: dict[str, Any] = {
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "decision_seconds": 0.0,
        "max_step_exhaustions": 0,
        "seat": seat,
    }
    try:
        failed_signatures: dict[int, set[tuple]] = {0: set(), 1: set()}
        prev_player_idx: int | None = None
        for _ in range(max_steps):
            if state.is_terminal():
                break
            if state.pending_promotion_player >= 0:
                ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                continue
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).advance_phase()
                continue
            if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
                TurnManager(state).advance_phase()
                continue

            player_idx = state.active_player_idx if state.phase != TurnPhase.SETUP else target_player_idx
            if prev_player_idx is not None and player_idx != prev_player_idx:
                failed_signatures[player_idx].clear()
            prev_player_idx = player_idx
            ai = ais[player_idx]
            decision_started = time.perf_counter()
            action = ai.choose_action(state, player_idx)
            if player_idx == target_player_idx:
                diagnostics["actions"] += 1
                decision_elapsed = time.perf_counter() - decision_started
                diagnostics["decision_seconds"] += decision_elapsed
                if decision_elapsed > 8.0:
                    diagnostics["decision_timeouts"] += 1
                if _action_has_no_available_target(ai, state, player_idx, action):
                    diagnostics["no_target_actions"] += 1
            try:
                result = ai._apply_action_for_sim(state, player_idx, action)
            except Exception:
                result = None
                if player_idx == target_player_idx:
                    diagnostics["rule_exceptions"] += 1
            signature = _action_signature(action)
            invalid = result is None or not result.success
            if player_idx == target_player_idx and invalid:
                diagnostics["invalid_actions"] += 1
            if invalid:
                failed_signatures[player_idx].add(signature)
                if len(failed_signatures[player_idx]) >= 2:
                    force_end_turn(state, player_idx)
                    failed_signatures[player_idx].clear()
            else:
                failed_signatures[player_idx].clear()

        if state.is_terminal():
            logical_winner = (
                None
                if state.result_status == "DRAW"
                else 0 if state.winner == target_player_idx else 1
            )
            score = terminal_training_score(state, target_player_idx)
        else:
            diagnostics["max_step_exhaustions"] = 1
            soft_winner = _determine_soft_winner(state)
            state.winner = soft_winner
            logical_winner = 0 if soft_winner == target_player_idx else 1
            score = terminal_training_score(state, target_player_idx)
        return logical_winner, score, [], [], diagnostics
    finally:
        _restore_rng(rng_state)


def _execute_model_game_task(task: ModelGameTask) -> tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, int]]:
    _ensure_cards_loaded()
    model = _model_from_worker_payload(task.model_state, task.model_config)
    opponent_model = None
    if task.opponent_model_state is not None:
        opponent_model = _model_from_worker_payload(task.opponent_model_state, task.opponent_model_config or {})
    return _play_model_game(
        model,
        task.deck_key,
        task.seed,
        device="cpu",
        max_steps=task.max_steps,
        record=task.record,
        teacher_search_preset=task.teacher_search_preset,
        temperature=task.temperature,
        teacher_label_model_states=task.teacher_label_model_states,
        phase_tag=task.phase_tag,
        opponent_model=opponent_model,
        pure_rl=bool(task.pure_rl),
        use_mcts=bool(task.use_mcts),
        mcts_simulations=max(1, int(task.mcts_simulations or 1)),
        mcts_chance_nodes=bool(task.mcts_chance_nodes),
        opponent_deck_key=task.opponent_deck_key,
        rule_only=bool(task.rule_only),
    )


def _execute_model_game_task_batch(
    tasks: list[ModelGameTask],
) -> list[tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, int]]]:
    """Execute several games while reusing the loaded policy model."""
    if not tasks:
        return []
    _ensure_cards_loaded()
    first = tasks[0]
    try:
        model = _model_from_worker_payload(first.model_state, first.model_config)
    except Exception:
        # Keeps compatibility with custom task executors/tests and provides a
        # safe fallback for malformed external tasks.
        return [_execute_model_game_task(task) for task in tasks]

    opponent_cache: dict[int, Any] = {}
    rows = []
    for task in tasks:
        if task.model_state is not first.model_state:
            model = _model_from_worker_payload(task.model_state, task.model_config)
            first = task
        opponent_model = None
        if task.opponent_model_state is not None:
            cache_key = id(task.opponent_model_state)
            opponent_model = opponent_cache.get(cache_key)
            if opponent_model is None:
                opponent_model = _model_from_worker_payload(
                    task.opponent_model_state,
                    task.opponent_model_config or {},
                )
                opponent_cache[cache_key] = opponent_model
        rows.append(_play_model_game(
            model,
            task.deck_key,
            task.seed,
            device="cpu",
            max_steps=task.max_steps,
            record=task.record,
            teacher_search_preset=task.teacher_search_preset,
            temperature=task.temperature,
            teacher_label_model_states=task.teacher_label_model_states,
            phase_tag=task.phase_tag,
            opponent_model=opponent_model,
            pure_rl=bool(task.pure_rl),
            use_mcts=bool(task.use_mcts),
            mcts_simulations=max(1, int(task.mcts_simulations or 1)),
            mcts_chance_nodes=bool(task.mcts_chance_nodes),
            opponent_deck_key=task.opponent_deck_key,
            rule_only=bool(task.rule_only),
        ))
    return rows


def _run_model_game_tasks(
    tasks: list[ModelGameTask],
    workers: int | None,
) -> list[tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, int]]]:
    worker_count = _normalized_workers(workers)
    with DeepTrainingTaskRunner(worker_count) as runner:
        return runner.run_model_game_tasks(tasks)


def _model_game_tasks(
    model,
    deck_key: str,
    seeds: list[int],
    *,
    max_steps: int,
    record: bool,
    teacher_search_preset: str,
    temperature: float = 0.9,
    teacher_label_model_states: bool = True,
    phase_tag: str = "rl",
    opponent_pool: Any = None,
    temperatures: list[float] | None = None,
    pure_rl: bool = False,
    use_mcts: bool = False,
    mcts_simulations: int = 0,
    mcts_chance_nodes: bool = True,
    opponent_deck_key: str | None = None,
    rule_only: bool = False,
) -> list[ModelGameTask]:
    model_state, model_config = _model_payload_for_worker(model)
    tasks = []
    for i, seed in enumerate(seeds):
        opp_state = None
        opp_config = None
        if opponent_pool is not None and len(opponent_pool) > 0 and (i % 2 == 1):
            sampled = opponent_pool.sample()
            if sampled is not None:
                opp_state, opp_config = sampled
        tasks.append(ModelGameTask(
            deck_key,
            seed,
            max_steps,
            record,
            model_state,
            model_config,
            teacher_search_preset,
            temperatures[i] if temperatures is not None and i < len(temperatures) else temperature,
            teacher_label_model_states,
            phase_tag,
            pure_rl,
            use_mcts,
            mcts_simulations,
            mcts_chance_nodes,
            opponent_model_state=opp_state,
            opponent_model_config=opp_config,
            opponent_deck_key=opponent_deck_key,
            rule_only=rule_only,
        ))
    return tasks


def evaluate_model(
    model,
    deck_key: str,
    seed: int,
    games: int,
    *,
    device: str,
    max_steps: int = 120,
    workers: int = 1,
    teacher_search_preset: str = "hybrid",
    task_runner: DeepTrainingTaskRunner | None = None,
    use_mcts: bool = False,
    mcts_simulations: int = 64,
    mcts_chance_nodes: bool = False,
) -> dict[str, Any]:
    if games <= 0:
        return empty_evaluation_stats(games)
    seeds = [seed + idx * 97 for idx in range(games)]
    if _normalized_workers(workers) <= 1:
        rows = [
            _play_model_game(
                model,
                deck_key,
                game_seed,
                device=device,
                max_steps=max_steps,
                record=False,
                teacher_search_preset=teacher_search_preset,
                temperature=0.0,
                teacher_label_model_states=False,
                use_mcts=bool(use_mcts),
                mcts_simulations=max(1, int(mcts_simulations)),
                mcts_chance_nodes=bool(mcts_chance_nodes),
            )
            for game_seed in seeds
        ]
    else:
        tasks = _model_game_tasks(
                model,
                deck_key,
                seeds,
                max_steps=max_steps,
                record=False,
                teacher_search_preset=teacher_search_preset,
                temperature=0.0,
                teacher_label_model_states=False,
                phase_tag="eval",
                use_mcts=bool(use_mcts),
                mcts_simulations=max(1, int(mcts_simulations)),
                mcts_chance_nodes=bool(mcts_chance_nodes),
        )
        rows = (
            task_runner.run_model_game_tasks(tasks)
            if task_runner is not None
            else _run_model_game_tasks(tasks, workers)
        )
    return summarize_evaluation_rows(rows, games)


def evaluate_challenge_baseline(
    deck_key: str,
    seed: int,
    games: int,
    *,
    max_steps: int = 120,
    workers: int = 1,
    teacher_search_preset: str = "hybrid",
) -> dict[str, Any]:
    if games <= 0:
        return empty_evaluation_stats(games)
    seeds = [seed + idx * 97 for idx in range(games)]
    worker_count = _normalized_workers(workers)
    if worker_count <= 1:
        rows = [
            _play_challenge_baseline_game(
                deck_key,
                game_seed,
                max_steps=max_steps,
                teacher_search_preset=teacher_search_preset,
            )
            for game_seed in seeds
        ]
    else:
        with ProcessPoolExecutor(max_workers=worker_count) as pool:
            futures = [
                pool.submit(
                    _play_challenge_baseline_game,
                    deck_key,
                    game_seed,
                    max_steps=max_steps,
                    teacher_search_preset=teacher_search_preset,
                )
                for game_seed in seeds
            ]
            rows = [future.result() for future in futures]
    return summarize_evaluation_rows(rows, games)


def _checkpoint_training_rank(path: str, deck_key: str) -> tuple[int, int, float, float]:
    """Rank existing checkpoints for warm-starting, including rejected candidates."""
    sidecar = os.path.splitext(path)[0] + ".json"
    try:
        with open(sidecar, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        metadata = payload.get("metadata") or {}
        if int(metadata.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION:
            return (0, 0, -1.0, -1e30)
        row = (metadata.get("summary") or {}).get(deck_key) or {}
        eval_row = row.get("eval") or {}
        games = int(eval_row.get("games") or metadata.get("eval_games") or 0)
        wins = int(eval_row.get("wins") or 0)
        losses = int(eval_row.get("losses") or 0)
        avg_score = float(eval_row.get("avg_score") or 0.0)
        point_rate = (wins - losses) / max(1, games)
        return (1 if games >= 600 else 0, min(games, 600), point_rate, avg_score)
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return (0, 0, -1.0, -1e30)


def _warm_start_path_for_deck(deck_key: str) -> str | None:
    candidates = [
        os.path.join(DEFAULT_MODEL_DIR, f"{deck_key}.pt"),
        os.path.join(DEFAULT_MODEL_DIR, f"{deck_key}.rejected.pt"),
        os.path.join(DEFAULT_MODEL_DIR, f"candidate_default_eval600_{deck_key}.pt"),
        os.path.join(DEFAULT_MODEL_DIR, f"candidate_default_eval600_{deck_key}.rejected.pt"),
    ]
    existing = [path for path in candidates if os.path.exists(path)]
    if not existing:
        return None
    best = max(existing, key=lambda path: _checkpoint_training_rank(path, deck_key))
    return best if _checkpoint_training_rank(best, deck_key)[2] >= 0.0 else None


def _load_or_create_model(config: DeepTrainingConfig, deck_key: str | None = None):
    assert torch is not None
    model_path = config.model
    if not model_path and config.warm_start and deck_key:
        model_path = _warm_start_path_for_deck(deck_key)
    if model_path and os.path.exists(model_path):
        model, payload = load_checkpoint(model_path, config.device)
        schema = dict(payload.get("schema") or payload.get("metadata") or {})
        if int(schema.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION:
            model = None
        if model is None:
            pass
        elif int(payload.get("version") or 0) >= 3:
            if not bool(getattr(model, "use_slot_embeddings", False)):
                upgraded_config = dict(payload.get("model_config") or {})
                upgraded_config["use_slot_embeddings"] = True
                upgraded_config["choice_head_enabled"] = bool(config.choice_head_enabled)
                upgraded = create_model(**upgraded_config)
                upgraded.load_state_dict(model.state_dict(), strict=False)
                upgraded.to(config.device)
                return upgraded
            return model
    model = create_model(
        choice_head_enabled=bool(config.choice_head_enabled),
        deck_embed_dim=max(0, int(config.deck_embed_dim)),
    )
    model.to(config.device)
    return model


def _open_progress_writer(path: str | None):
    if not path:
        return None
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    return open(path, "w", encoding="utf-8")


def _score_points(result: dict[str, Any] | None) -> tuple[int, float]:
    if not result:
        return 0, 0.0
    wins = int(result.get("wins", 0))
    losses = int(result.get("losses", 0))
    draws = int(result.get("draws", 0))
    return wins - losses, wins + draws * 0.5


def _choice_training_examples_from_deck_summary(deck_summary: Any) -> int:
    if not isinstance(deck_summary, dict):
        return 0
    choice_examples = int((deck_summary.get("choice") or {}).get("choice_examples") or 0)
    choice_examples += int((deck_summary.get("distill_choice") or {}).get("choice_examples") or 0)
    choice_examples += int(deck_summary.get("loaded_choice_examples") or 0)
    return max(0, choice_examples)


def _choice_training_examples_from_metadata(metadata: dict[str, Any], deck_key: str) -> int:
    summary = metadata.get("summary")
    if not isinstance(summary, dict):
        return 0
    deck_summary = summary.get(deck_key)
    if not isinstance(deck_summary, dict) and len(summary) == 1:
        only_summary = next(iter(summary.values()))
        deck_summary = only_summary if isinstance(only_summary, dict) else None
    return _choice_training_examples_from_deck_summary(deck_summary)


def _checkpoint_choice_training_examples(path: str | None, deck_key: str) -> int:
    if not path:
        return 0
    sidecar = os.path.splitext(path)[0] + ".json"
    try:
        with open(sidecar, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        metadata = payload.get("metadata") if isinstance(payload, dict) else {}
        if not isinstance(metadata, dict):
            return 0
        if (
            int(metadata.get("rules_version") or 0) != RULES_SCHEMA_VERSION
            or int(metadata.get("action_version") or 0) != ACTION_SCHEMA_VERSION
            or int(metadata.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION
        ):
            return 0
        return _choice_training_examples_from_metadata(metadata, deck_key)
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return 0


def _point_rate(result: dict[str, Any] | None) -> float:
    return release_point_rate(result)


def _paired_delta_point_rate(eval_result: dict[str, Any], baseline: dict[str, Any] | None) -> float | None:
    return release_paired_delta_point_rate(eval_result, baseline)


def _evaluation_delta(eval_result: dict[str, Any], baseline: dict[str, Any] | None) -> dict[str, Any]:
    if not baseline or int(baseline.get("games") or 0) <= 0:
        return {
            "delta_wins": None,
            "delta_win_rate": None,
            "delta_point_rate": None,
            "paired_delta_point_rate": None,
            "delta_avg_score": None,
        }
    candidate_games = max(1, int(eval_result.get("games") or 0))
    baseline_games = max(1, int(baseline.get("games") or 0))
    return {
        "delta_wins": int(eval_result.get("wins", 0)) - int(baseline.get("wins", 0)),
        "delta_win_rate": round(
            float(eval_result.get("wins", 0) or 0) / candidate_games
            - float(baseline.get("wins", 0) or 0) / baseline_games,
            4,
        ),
        "delta_point_rate": round(_point_rate(eval_result) - _point_rate(baseline), 4),
        "paired_delta_point_rate": (
            round(paired_delta, 4)
            if (paired_delta := _paired_delta_point_rate(eval_result, baseline)) is not None
            else None
        ),
        "delta_avg_score": round(float(eval_result.get("avg_score", 0.0)) - float(baseline.get("avg_score", 0.0)), 3),
    }


def _max_step_exhaustion_rate(result: dict[str, Any] | None) -> float:
    return release_max_step_exhaustion_rate(result)


def _has_strength_floor(
    result: dict[str, Any] | None,
    *,
    min_point_rate: float,
    paired_baseline: dict[str, Any] | None = None,
    min_delta_point_rate: float = DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    max_step_exhaustion_rate: float,
) -> bool:
    return has_strength_and_reliability_floor(
        result,
        min_point_rate=min_point_rate,
        paired_baseline=paired_baseline,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate_limit=max_step_exhaustion_rate,
    )


def _accepts_candidate(
    eval_result: dict[str, Any],
    baseline_eval: dict[str, Any] | None,
    old_eval: dict[str, Any] | None,
    *,
    acceptance_metric: str = "wins",
    min_win_delta: int = 1,
    min_point_rate: float = DEFAULT_MIN_ACCEPTED_POINT_RATE,
    min_delta_point_rate: float = DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    max_step_exhaustion_rate: float = DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
) -> bool:
    if int(eval_result.get("games") or 0) <= 0:
        return False
    if float(eval_result.get("invalid_action_rate", 0.0) or 0.0) > 0.0:
        return False
    if float(eval_result.get("no_target_action_rate", 0.0) or 0.0) > 0.0:
        return False
    if float(eval_result.get("rule_exception_rate", 0.0) or 0.0) > 0.0:
        return False
    if float(eval_result.get("decision_timeout_rate", 0.0) or 0.0) > 0.0:
        return False
    if not _has_strength_floor(
        eval_result,
        min_point_rate=min_point_rate,
        paired_baseline=baseline_eval,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate=max_step_exhaustion_rate,
    ):
        return False
    metric = acceptance_metric if acceptance_metric in ("wins", "points", "score") else "wins"
    # A paired Challenge evaluation is the production release gate for the
    # default points policy.  Do not compare points a second time: that used to
    # silently tighten the shared -1% practical non-inferiority floor back to
    # exact parity.  Explicit legacy ``wins``/``score`` policies remain
    # available as stricter opt-in criteria.
    if (
        metric == "points"
        and baseline_eval
        and int(baseline_eval.get("games") or 0) > 0
    ):
        return True
    if metric == "wins":
        required_delta = max(0, int(min_win_delta))
        candidate_games = max(1, int(eval_result.get("games") or 0))
        candidate_rate = float(eval_result.get("wins", 0)) / candidate_games
        comparison_baselines = (
            (baseline_eval,)
            if baseline_eval and int(baseline_eval.get("games") or 0) > 0
            else (old_eval,)
        )
        for baseline in comparison_baselines:
            if not baseline or int(baseline.get("games") or 0) <= 0:
                continue
            baseline_games = max(1, int(baseline.get("games") or 0))
            baseline_rate = float(baseline.get("wins", 0)) / baseline_games
            required_rate = baseline_rate + required_delta / candidate_games
            if candidate_rate + 1e-12 < required_rate:
                return False
        return True
    if metric == "score":
        candidate_score = float(eval_result.get("avg_score", 0.0))
        comparison_baselines = (
            (baseline_eval,)
            if baseline_eval and int(baseline_eval.get("games") or 0) > 0
            else (old_eval,)
        )
        for baseline in comparison_baselines:
            if not baseline or int(baseline.get("games") or 0) <= 0:
                continue
            if candidate_score <= float(baseline.get("avg_score", 0.0)):
                return False
        return True

    _, candidate_rate = _score_points(eval_result)
    candidate_rate /= max(1, int(eval_result.get("games") or 0))
    comparison_baselines = (
        (baseline_eval,)
        if baseline_eval and int(baseline_eval.get("games") or 0) > 0
        else (old_eval,)
    )
    for baseline in comparison_baselines:
        if not baseline or int(baseline.get("games") or 0) <= 0:
            continue
        _, baseline_rate = _score_points(baseline)
        baseline_rate /= max(1, int(baseline.get("games") or 0))
        if candidate_rate + 1e-12 < baseline_rate:
            return False
        if abs(candidate_rate - baseline_rate) <= 1e-12:
            if candidate_rate < baseline_rate:
                return False
            if float(eval_result.get("avg_score", 0.0)) < float(baseline.get("avg_score", 0.0)) - 25.0:
                return False
    return True


def _verification_metadata(eval_games: int, accepted: bool) -> dict[str, Any]:
    """Describe whether a trained checkpoint has real evaluation evidence."""
    schema = {
        "rules_version": RULES_SCHEMA_VERSION,
        "action_version": ACTION_SCHEMA_VERSION,
        "encoder_version": ENCODER_SCHEMA_VERSION,
    }
    if int(eval_games or 0) <= 0:
        return {
            **schema,
            "verified": False,
            "verification_status": "unverified_no_eval",
            "verification_note": "No evaluation games were run for this model.",
        }
    if accepted:
        return {
            **schema,
            "verified": True,
            "verification_status": "verified_accepted",
            "verification_note": "Evaluation gate accepted this model.",
        }
    return {
        **schema,
        "verified": False,
        "verification_status": "verified_rejected",
        "verification_note": "Evaluation gate rejected this model.",
    }


def _score_rate(result: dict[str, Any] | None) -> float:
    if not result:
        return 0.0
    games = max(1, int(result.get("games") or 0))
    wins = float(result.get("wins", 0) or 0)
    draws = float(result.get("draws", 0) or 0)
    return (wins + draws * 0.5) / games


def _elo_delta_from_score_rate(score_rate: float) -> float:
    bounded = max(0.01, min(0.99, float(score_rate)))
    return 400.0 * math.log10(bounded / (1.0 - bounded))


def _has_bad_eval_actions(result: dict[str, Any] | None) -> bool:
    if not result:
        return False
    return (
        float(result.get("invalid_action_rate", 0.0) or 0.0) > 0.0
        or float(result.get("no_target_action_rate", 0.0) or 0.0) > 0.0
        or float(result.get("rule_exception_rate", 0.0) or 0.0) > 0.0
        or float(result.get("decision_timeout_rate", 0.0) or 0.0) > 0.0
    )


def _accepts_league_result(
    result: dict[str, Any],
    *,
    min_score_rate: float,
    min_elo_delta: float,
    max_step_exhaustion_rate: float = DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
) -> bool:
    if int(result.get("games") or 0) <= 0:
        return False
    if _has_bad_eval_actions(result):
        return False
    if _max_step_exhaustion_rate(result) > float(max_step_exhaustion_rate) + 1e-12:
        return False
    return (
        float(result.get("score_rate", 0.0) or 0.0) + 1e-12 >= float(min_score_rate)
        and float(result.get("elo_delta", 0.0) or 0.0) + 1e-12 >= float(min_elo_delta)
    )


def _checkpoint_sidecar_metadata(path: str) -> dict[str, Any]:
    sidecar = os.path.splitext(path)[0] + ".json"
    try:
        with open(sidecar, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return {}
    metadata = payload.get("metadata") if isinstance(payload, dict) else {}
    return metadata if isinstance(metadata, dict) else {}


def _checkpoint_is_verified_for_league(path: str, deck_key: str) -> bool:
    if not path or not os.path.exists(path):
        return False
    metadata = _checkpoint_sidecar_metadata(path)
    if not metadata:
        return False
    if str(metadata.get("deck", deck_key)) != deck_key:
        return False
    if not bool(metadata.get("accepted")) or not bool(metadata.get("verified")):
        return False
    if int(metadata.get("rules_version") or 0) != RULES_SCHEMA_VERSION:
        return False
    if int(metadata.get("action_version") or 0) != ACTION_SCHEMA_VERSION:
        return False
    if int(metadata.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION:
        return False
    summary = metadata.get("summary")
    if isinstance(summary, dict):
        deck_summary = summary.get(deck_key)
        if isinstance(deck_summary, dict):
            eval_row = deck_summary.get("eval")
            release_baseline = (
                deck_summary.get("challenge_baseline_eval")
                or deck_summary.get("release_baseline_eval")
            )
            if _has_bad_eval_actions(eval_row):
                return False
            if not _has_strength_floor(
                eval_row,
                min_point_rate=DEFAULT_MIN_ACCEPTED_POINT_RATE,
                paired_baseline=release_baseline if isinstance(release_baseline, dict) else None,
                min_delta_point_rate=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
                max_step_exhaustion_rate=DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
            ):
                return False
    return True


def _league_checkpoint_paths(config: DeepTrainingConfig, deck_key: str) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    previous = config.model or _output_path_for_deck(deck_key)
    if _checkpoint_is_verified_for_league(previous, deck_key):
        rows.append(("previous", previous))
    league_dir = os.fspath(config.league_dir or "")
    if league_dir and os.path.isdir(league_dir):
        candidates: list[str] = []
        deck_dir = os.path.join(league_dir, deck_key)
        if os.path.isdir(deck_dir):
            candidates.extend(
                os.path.join(deck_dir, name)
                for name in os.listdir(deck_dir)
                if name.endswith(".pt")
            )
        candidates.extend(
            os.path.join(league_dir, name)
            for name in os.listdir(league_dir)
            if name.startswith(f"{deck_key}") and name.endswith(".pt")
        )
        seen = {os.path.abspath(path) for _name, path in rows}
        for path in sorted(candidates):
            absolute = os.path.abspath(path)
            if absolute in seen or not _checkpoint_is_verified_for_league(path, deck_key):
                continue
            seen.add(absolute)
            rows.append((f"league:{os.path.basename(path)}", path))
    return rows


def _add_verified_league_snapshots(pool: OpponentPool, config: DeepTrainingConfig, deck_key: str, device: str) -> list[dict[str, Any]]:
    loaded: list[dict[str, Any]] = []
    for label, path in _league_checkpoint_paths(config, deck_key):
        try:
            opponent, payload = load_checkpoint(path, device)
            state, model_config = _model_payload_for_worker(opponent)
            pool.add(state, model_config)
            loaded.append({
                "label": label,
                "path": path,
                "trainer": (payload.get("metadata") or {}).get("trainer", ""),
            })
        except Exception:
            continue
    return loaded


def _empty_league_result(reason: str, *, accepted: bool = False) -> dict[str, Any]:
    return {
        "games": 0,
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "score_rate": 0.0,
        "elo_delta": 0.0,
        "accepted": bool(accepted),
        "rejection_reason": reason,
        "opponents": [],
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "decision_seconds": 0.0,
        "invalid_action_rate": 0.0,
        "no_target_action_rate": 0.0,
        "rule_exception_rate": 0.0,
        "decision_timeout_rate": 0.0,
        "average_decision_seconds": 0.0,
    }


def evaluate_alpha_zero_league(
    model,
    deck_key: str,
    seed: int,
    config: DeepTrainingConfig,
    *,
    device: str,
    max_steps: int,
) -> dict[str, Any]:
    games = max(0, int(config.league_eval_games))
    if games <= 0:
        return _empty_league_result("no_league_eval_games")
    if model is None:
        return _empty_league_result("missing_candidate_model")
    opponents = _league_checkpoint_paths(config, deck_key)
    if not opponents:
        return _empty_league_result("no_verified_league_opponents", accepted=False)

    stats: dict[str, Any] = {
        "games": 0,
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "decision_seconds": 0.0,
        "opponents": [],
    }
    games_per_opponent = games // len(opponents)
    extra_games = games % len(opponents)
    game_counter = 0
    for opponent_idx, (label, path) in enumerate(opponents):
        try:
            opponent_model, payload = load_checkpoint(path, device)
        except Exception as exc:
            stats["opponents"].append({
                "label": label,
                "path": path,
                "games": 0,
                "error": str(exc),
            })
            continue
        target_games = games_per_opponent + (1 if opponent_idx < extra_games else 0)
        opponent_row = {
            "label": label,
            "path": path,
            "trainer": (payload.get("metadata") or {}).get("trainer", ""),
            "games": 0,
            "wins": 0,
            "losses": 0,
            "draws": 0,
        }
        for local_idx in range(target_games):
            winner, _score, _examples, _choices, diagnostics = _play_model_game(
                model,
                deck_key,
                seed + 950_000 + game_counter * 131,
                device=device,
                max_steps=max_steps,
                record=False,
                teacher_search_preset="hybrid",
                temperature=0.0,
                teacher_label_model_states=False,
                opponent_model=opponent_model,
                pure_rl=True,
                use_mcts=bool(config.league_use_mcts),
                mcts_simulations=max(1, int(config.mcts_simulations)),
                mcts_chance_nodes=bool(config.mcts_chance_nodes),
                opponent_deck_key=deck_key,
                rule_only=True,
            )
            game_counter += 1
            stats["games"] += 1
            opponent_row["games"] += 1
            if winner == 0:
                stats["wins"] += 1
                opponent_row["wins"] += 1
            elif winner == 1:
                stats["losses"] += 1
                opponent_row["losses"] += 1
            else:
                stats["draws"] += 1
                opponent_row["draws"] += 1
            diagnostics = diagnostics if isinstance(diagnostics, dict) else {}
            for key in ("actions", "invalid_actions", "no_target_actions", "rule_exceptions", "decision_timeouts"):
                stats[key] += int(diagnostics.get(key, 0) or 0)
            stats["decision_seconds"] += float(diagnostics.get("decision_seconds", 0.0) or 0.0)
        stats["opponents"].append(opponent_row)

    if int(stats["games"]) <= 0:
        stats["invalid_action_rate"] = 0.0
        stats["no_target_action_rate"] = 0.0
        stats["rule_exception_rate"] = 0.0
        stats["decision_timeout_rate"] = 0.0
        stats["average_decision_seconds"] = 0.0
        stats["score_rate"] = 0.0
        stats["elo_delta"] = 0.0
        stats["accepted"] = False
        stats["rejection_reason"] = "no_completed_league_games"
        return stats

    action_count = max(1, int(stats["actions"]))
    stats["invalid_action_rate"] = round(float(stats["invalid_actions"]) / action_count, 6)
    stats["no_target_action_rate"] = round(float(stats["no_target_actions"]) / action_count, 6)
    stats["rule_exception_rate"] = round(float(stats["rule_exceptions"]) / action_count, 6)
    stats["decision_timeout_rate"] = round(float(stats["decision_timeouts"]) / action_count, 6)
    stats["average_decision_seconds"] = round(float(stats["decision_seconds"]) / action_count, 6)
    stats["score_rate"] = round(_score_rate(stats), 6)
    stats["elo_delta"] = round(_elo_delta_from_score_rate(stats["score_rate"]), 3)
    accepted = _accepts_league_result(
        stats,
        min_score_rate=float(config.min_score_rate),
        min_elo_delta=float(config.min_elo_delta),
        max_step_exhaustion_rate=float(config.max_step_exhaustion_rate),
    )
    stats["accepted"] = accepted
    if _has_bad_eval_actions(stats):
        stats["rejection_reason"] = "bad_actions"
    elif _max_step_exhaustion_rate(stats) > float(config.max_step_exhaustion_rate) + 1e-12:
        stats["rejection_reason"] = "max_step_exhaustion"
    elif not accepted:
        stats["rejection_reason"] = "league_threshold"
    else:
        stats["rejection_reason"] = ""
    return stats


def _sample_teacher_examples(bootstrap: list[TrainingExample], target_size: int, rng: random.Random) -> list[TrainingExample]:
    if not bootstrap or target_size <= 0:
        return []
    if len(bootstrap) <= target_size:
        return list(bootstrap)
    return rng.sample(bootstrap, target_size)


def _sample_replay_examples(
    replay_buffer: ReplayBuffer,
    fresh_count: int,
    *,
    ratio: float,
    minimum: int = 0,
) -> list[TrainingExample]:
    if replay_buffer.size <= 0:
        return []
    try:
        replay_ratio = max(0.0, float(ratio))
    except (TypeError, ValueError):
        replay_ratio = 0.0
    if replay_ratio <= 0.0:
        return []
    target_size = int(max(0, fresh_count) * replay_ratio)
    if fresh_count > 0 and target_size <= 0:
        target_size = 1
    target_size = max(target_size, max(0, int(minimum)))
    if target_size <= 0:
        return []
    return replay_buffer.sample(min(replay_buffer.size, target_size))


def _aggregate_train_results(results: list[dict[str, Any]], total_examples: int) -> dict[str, Any]:
    if not results:
        return {
            "examples": total_examples,
            "loss": 0.0,
            "total_loss": 0.0,
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
        }
    keys = ("loss", "total_loss", "policy_loss", "value_loss", "entropy")
    return {
        "examples": total_examples,
        **{
            key: round(sum(float(row.get(key, 0.0)) for row in results) / len(results), 6)
            for key in keys
        },
    }


def _aggregate_choice_results(results: list[dict[str, Any]], total_examples: int) -> dict[str, Any]:
    if not results:
        return {"choice_examples": total_examples, "choice_loss": 0.0}
    return {
        "choice_examples": total_examples,
        "choice_loss": round(sum(float(row.get("choice_loss", 0.0)) for row in results) / len(results), 6),
    }


def _collect_rollout_batch(
    model,
    deck_key: str,
    seeds: list[int],
    *,
    device: str,
    max_steps: int,
    workers: int,
    teacher_search_preset: str,
    teacher_label_model_states: bool = True,
    phase_tag: str = "rl",
    opponent_pool: Any = None,
    task_runner: DeepTrainingTaskRunner | None = None,
    pure_rl: bool = False,
    use_mcts: bool = False,
    mcts_simulations: int = 0,
    mcts_chance_nodes: bool = True,
    opponent_deck_key: str | None = None,
    rule_only: bool = False,
) -> list[tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample], dict[str, int]]]:
    if not seeds:
        return []
    if _normalized_workers(workers) <= 1:
        pool = opponent_pool
        results = []
        for i, game_seed in enumerate(seeds):
            opp_model = None
            if pool is not None and len(pool) > 0 and (i % 2 == 1):
                sampled = pool.sample()
                if sampled is not None:
                    opp_state, opp_config = sampled
                    opp_model = _model_from_worker_payload(opp_state, opp_config)
            results.append(_play_model_game(
                model,
                deck_key,
                game_seed,
                device=device,
                max_steps=max_steps,
                record=True,
                teacher_search_preset=teacher_search_preset,
                teacher_label_model_states=teacher_label_model_states,
                phase_tag=phase_tag,
                opponent_model=opp_model,
                pure_rl=pure_rl,
                use_mcts=use_mcts,
                mcts_simulations=mcts_simulations,
                mcts_chance_nodes=mcts_chance_nodes,
                opponent_deck_key=opponent_deck_key,
                rule_only=rule_only,
            ))
        return results
    tasks = _model_game_tasks(
            model,
            deck_key,
            seeds,
            max_steps=max_steps,
            record=True,
            teacher_search_preset=teacher_search_preset,
            teacher_label_model_states=teacher_label_model_states,
            phase_tag=phase_tag,
            opponent_pool=opponent_pool,
            pure_rl=pure_rl,
            use_mcts=use_mcts,
            mcts_simulations=mcts_simulations,
            mcts_chance_nodes=mcts_chance_nodes,
            opponent_deck_key=opponent_deck_key,
            rule_only=rule_only,
    )
    return (
        task_runner.run_model_game_tasks(tasks)
        if task_runner is not None
        else _run_model_game_tasks(tasks, workers)
    )


def _validate_alpha_zero_examples(examples: list[TrainingExample]) -> None:
    invalid_sources = sorted({
        str(ex.source)
        for ex in examples
        if ex.source not in ("self_play", "league_self_play")
    })
    if invalid_sources:
        raise RuntimeError(
            "alpha_zero_rl received non-RL training examples: "
            + ", ".join(invalid_sources)
        )


def _train_deck_alpha_zero_pipeline(
    model,
    deck_key: str,
    deck_seed: int,
    config: DeepTrainingConfig,
    emit: Callable[[dict[str, Any]], None],
    total_done: int,
    total_training_games: int,
) -> tuple[dict[str, Any], int]:
    """Run AlphaZero-style neural-MCTS self-play and league-gated eval."""
    self_play_games = max(0, int(config.games))
    max_steps = max(20, int(config.max_steps))
    rollout_batch_games = max(1, int(config.rollout_batch_games))
    updates_per_rollout = max(1, int(config.updates_per_rollout))
    worker_count = _normalized_workers(config.workers)
    replay_buffer = ReplayBuffer(capacity=max(1, int(config.replay_buffer_size)), seed=deck_seed)
    replay_ratio = max(0.0, float(config.replay_sample_ratio))
    task_runner = DeepTrainingTaskRunner(worker_count)
    task_runner.__enter__()
    amp_enabled = bool(config.use_amp and str(config.device).startswith("cuda"))
    parameters_fn = getattr(model, "parameters", None)
    optimizer = (
        torch.optim.AdamW(parameters_fn(), lr=config.learning_rate, weight_decay=1e-4)
        if callable(parameters_fn) else None
    )
    grad_scaler = _make_grad_scaler(amp_enabled) if optimizer is not None else None
    opponent_pool = OpponentPool(max_snapshots=5)
    loaded_opponents = _add_verified_league_snapshots(opponent_pool, config, deck_key, config.device)
    current_state, current_config = _model_payload_for_worker(model)
    opponent_pool.add(current_state, current_config)

    emit({
        "type": "deck_started",
        "trainer": ALPHA_ZERO_METADATA_TRAINER,
        "deck": deck_key,
        "seed": deck_seed,
        "target_games": self_play_games,
        "bootstrap_games": 0,
        "dagger_games": 0,
        "league_eval_games": max(0, int(config.league_eval_games)),
        "league_use_mcts": bool(config.league_use_mcts),
        "min_score_rate": float(config.min_score_rate),
        "min_elo_delta": float(config.min_elo_delta),
        "max_step_exhaustion_rate": float(config.max_step_exhaustion_rate),
        "rollout_batch_games": rollout_batch_games,
        "updates_per_rollout": updates_per_rollout,
        "mcts_simulations": int(config.mcts_simulations),
        "opponent_pool_size": len(opponent_pool),
        "loaded_league_opponents": loaded_opponents,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    wins = losses = draws = 0
    score_total = 0.0
    total_examples = 0
    train_results: list[dict[str, Any]] = []
    rng = random.Random(deck_seed)

    for batch_start in range(0, self_play_games, rollout_batch_games):
        batch_count = min(rollout_batch_games, self_play_games - batch_start)
        seeds = [
            deck_seed + 600_000 + (batch_start + idx) * 127
            for idx in range(batch_count)
        ]
        rows = _collect_rollout_batch(
            model,
            deck_key,
            seeds,
            device=config.device,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset="hybrid",
            teacher_label_model_states=False,
            phase_tag="alpha_zero",
            opponent_pool=opponent_pool,
            task_runner=task_runner,
            pure_rl=True,
            use_mcts=bool(config.use_mcts_training),
            mcts_simulations=max(1, int(config.mcts_simulations)),
            mcts_chance_nodes=bool(config.mcts_chance_nodes),
            opponent_deck_key=deck_key,
            rule_only=True,
        )
        batch_examples: list[TrainingExample] = []
        for row_idx, (winner, score, examples, _choices, diagnostics) in enumerate(rows):
            sp_examples = [ex for ex in examples if ex.source == "self_play"]
            _validate_alpha_zero_examples(sp_examples)
            batch_examples.extend(sp_examples)
            score_total += score
            if winner == 0:
                wins += 1
            elif winner == 1:
                losses += 1
            else:
                draws += 1
            total_done += 1
            games_played = batch_start + row_idx + 1
            emit({
                "type": "self_play_game_finished",
                "trainer": ALPHA_ZERO_METADATA_TRAINER,
                "deck": deck_key,
                "game": games_played,
                "target_games": self_play_games,
                "winner": winner,
                "score": round(float(score), 3),
                "stats": {"wins": wins, "losses": losses, "draws": draws},
                "win_rate": round(wins / max(1, games_played), 4),
                "avg_score": round(score_total / max(1, games_played), 3),
                "examples": len(sp_examples),
                "policy_targets": sum(1 for ex in sp_examples if ex.policy_target),
                "diagnostics": diagnostics,
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })

        if batch_examples:
            _validate_alpha_zero_examples(batch_examples)
            replay_mix = _sample_replay_examples(
                replay_buffer,
                len(batch_examples),
                ratio=replay_ratio,
                minimum=config.batch_size if replay_buffer.size > 0 else 0,
            )
            _validate_alpha_zero_examples(replay_mix)
            train_rows = replay_mix + batch_examples
            train_result = _train_examples(
                model,
                train_rows,
                device=config.device,
                learning_rate=config.learning_rate,
                epochs=updates_per_rollout,
                batch_size=config.batch_size,
                optimizer=optimizer,
                grad_scaler=grad_scaler,
                use_amp=amp_enabled,
            )
            train_results.append(train_result)
            total_examples += len(batch_examples)
            replay_buffer.extend(batch_examples)
            snapshot_state, snapshot_config = _model_payload_for_worker(model)
            opponent_pool.add(snapshot_state, snapshot_config)
            emit({
                "type": "train_phase_finished",
                "trainer": ALPHA_ZERO_METADATA_TRAINER,
                "deck": deck_key,
                "phase": "alpha_zero_self_play_batch",
                "batch": (batch_start // rollout_batch_games) + 1,
                **train_result,
                "self_play_examples": len(batch_examples),
                "replay_examples": len(replay_mix),
                "opponent_pool_size": len(opponent_pool),
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })

    if self_play_games <= 0:
        empty_result = _train_examples(
            model,
            [],
            device=config.device,
            learning_rate=config.learning_rate,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
            optimizer=optimizer,
            grad_scaler=grad_scaler,
            use_amp=amp_enabled,
        )
        train_results.append(empty_result)
        emit({
            "type": "train_phase_finished",
            "trainer": ALPHA_ZERO_METADATA_TRAINER,
            "deck": deck_key,
            "phase": "alpha_zero_self_play",
            **empty_result,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    replay_buffer.clear()
    opponent_pool.clear()
    gc.collect()
    if str(config.device).startswith("cuda"):
        try:
            torch.cuda.empty_cache()
        except Exception:
            pass

    league_eval_games = max(0, int(config.league_eval_games)) if self_play_games > 0 else 0
    league_config = replace(config, league_eval_games=league_eval_games)
    league_result = evaluate_alpha_zero_league(
        model,
        deck_key,
        deck_seed,
        league_config,
        device=config.device,
        max_steps=max_steps,
    )
    total_done += int(league_result.get("games") or 0)
    accepted = bool(league_result.get("accepted", True))
    train_result = _aggregate_train_results(train_results, total_examples)
    summary = {
        "trainer": ALPHA_ZERO_METADATA_TRAINER,
        "bootstrap": {
            "examples": 0,
            "loss": 0.0,
            "total_loss": 0.0,
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
        },
        "dagger": {
            "examples": 0,
            "loss": 0.0,
            "total_loss": 0.0,
            "policy_loss": 0.0,
            "value_loss": 0.0,
            "entropy": 0.0,
        },
        "self_play": train_result,
        "self_play_stats": {"wins": wins, "losses": losses, "draws": draws},
        "choice": {"choice_examples": 0, "choice_loss": 0.0},
        "league": league_result,
        "eval": league_result,
        "accepted": accepted,
        "selected_stage": TRAINER_ALPHA_ZERO,
        "acceptance_metric": "league_elo",
        "min_score_rate": float(config.min_score_rate),
        "min_elo_delta": float(config.min_elo_delta),
        "max_step_exhaustion_rate": float(config.max_step_exhaustion_rate),
        "teacher_label_model_states": False,
        "teacher_search_preset": "",
    }
    emit({
        "type": "league_eval_finished",
        "trainer": ALPHA_ZERO_METADATA_TRAINER,
        "deck": deck_key,
        "league": league_result,
        "accepted": accepted,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    emit({
        "type": "deck_finished",
        "trainer": ALPHA_ZERO_METADATA_TRAINER,
        "deck": deck_key,
        "training_games": self_play_games,
        "stats": {"wins": wins, "losses": losses, "draws": draws},
        "eval": league_result,
        "accepted": accepted,
        "acceptance_metric": "league_elo",
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    task_runner.__exit__(None, None, None)
    return summary, total_done


def _train_deck_pipeline(
    model,
    deck_key: str,
    deck_seed: int,
    config: DeepTrainingConfig,
    emit: Callable[[dict[str, Any]], None],
    total_done: int,
    total_training_games: int,
    old_eval: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], int]:
    """Run teacher bootstrap + DAgger + batched RL fine-tune + gated eval for one deck."""
    bootstrap_games = max(0, int(config.bootstrap_games))
    dagger_games = max(0, int(config.dagger_games))
    self_play_games = max(0, int(config.games))
    eval_games = max(0, int(config.eval_games))
    max_steps = max(20, int(config.max_steps))
    rollout_batch_games = max(1, int(config.rollout_batch_games))
    updates_per_rollout = max(1, int(config.updates_per_rollout))
    worker_count = _normalized_workers(config.workers)
    teacher_search_preset = config.teacher_search_preset if config.teacher_search_preset in TEACHER_SEARCH_PRESETS else "hybrid"
    acceptance_metric = config.acceptance_metric if config.acceptance_metric in ("wins", "points", "score") else "wins"
    min_win_delta = max(0, int(config.min_win_delta))
    eval_seed = deck_seed + 900_000
    replay_buffer = ReplayBuffer(capacity=max(1, int(config.replay_buffer_size)), seed=deck_seed)
    replay_ratio = max(0.0, float(config.replay_sample_ratio))
    task_runner = DeepTrainingTaskRunner(worker_count)
    task_runner.__enter__()
    amp_enabled = bool(config.use_amp and str(config.device).startswith("cuda"))
    parameters_fn = getattr(model, "parameters", None)
    optimizer = (
        torch.optim.AdamW(
            parameters_fn(),
            lr=config.learning_rate,
            weight_decay=1e-4,
        )
        if callable(parameters_fn) else None
    )
    grad_scaler = _make_grad_scaler(amp_enabled) if optimizer is not None else None

    emit({
        "type": "deck_started",
        "deck": deck_key,
        "seed": deck_seed,
        "target_games": self_play_games,
        "bootstrap_games": bootstrap_games,
        "dagger_games": dagger_games,
        "eval_games": eval_games,
        "rollout_batch_games": rollout_batch_games,
        "updates_per_rollout": updates_per_rollout,
        "teacher_search_preset": teacher_search_preset,
        "eval_use_mcts": bool(config.eval_use_mcts),
        "mcts_simulations": int(config.mcts_simulations),
        "choice_head_enabled": bool(config.choice_head_enabled),
        "acceptance_metric": acceptance_metric,
        "min_win_delta": min_win_delta,
        "min_point_rate": float(config.min_point_rate),
        "min_delta_point_rate": float(config.min_delta_point_rate),
        "max_step_exhaustion_rate": float(config.max_step_exhaustion_rate),
        "teacher_label_model_states": bool(config.teacher_label_model_states),
        "distill_dataset": list(config.distill_dataset),
        "distill_epochs": int(config.distill_epochs),
        "distill_val_split": float(config.distill_val_split),
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    rng = random.Random(deck_seed)
    distill_stats: dict[str, Any] = {"action_examples": 0, "choice_examples": 0}
    distill_result = {
        "examples": 0,
        "loss": 0.0,
        "total_loss": 0.0,
        "policy_loss": 0.0,
        "value_loss": 0.0,
        "entropy": 0.0,
    }
    distill_choice_result = {"choice_examples": 0, "choice_loss": 0.0}
    distill_action_val_count = 0
    distill_choice_val_count = 0
    if config.distill_dataset:
        distill_actions, distill_choices, distill_stats = _load_distill_examples(
            tuple(config.distill_dataset),
            deck_key,
        )
        train_actions, val_actions = _split_distill_examples(
            distill_actions,
            val_split=float(config.distill_val_split),
            seed=deck_seed + 17,
        )
        train_choices, val_choices = _split_distill_examples(
            distill_choices,
            val_split=float(config.distill_val_split),
            seed=deck_seed + 29,
        )
        distill_action_val_count = len(val_actions)
        distill_choice_val_count = len(val_choices)
        replay_buffer.extend(train_actions)
        emit({
            "type": "distill_loaded",
            "deck": deck_key,
            **distill_stats,
            "train_action_examples": len(train_actions),
            "val_action_examples": distill_action_val_count,
            "train_choice_examples": len(train_choices),
            "val_choice_examples": distill_choice_val_count,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })
        if train_actions:
            distill_result = _train_examples(
                model,
                train_actions,
                device=config.device,
                learning_rate=config.learning_rate,
                epochs=max(1, int(config.distill_epochs)),
                batch_size=config.batch_size,
                entropy_coef=0.0,
                optimizer=optimizer,
                grad_scaler=grad_scaler,
                use_amp=amp_enabled,
            )
            emit({
                "type": "train_phase_finished",
                "deck": deck_key,
                "phase": "distill",
                **distill_result,
                "val_examples": distill_action_val_count,
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })
        if train_choices:
            distill_choice_result = _train_choice_examples(
                model,
                train_choices,
                device=config.device,
                learning_rate=config.learning_rate,
                epochs=max(1, int(config.distill_epochs)),
                batch_size=config.batch_size,
                optimizer=optimizer,
                grad_scaler=grad_scaler,
                use_amp=amp_enabled,
            )
            emit({
                "type": "choice_train_phase_finished",
                "deck": deck_key,
                "phase": "distill",
                **distill_choice_result,
                "val_choice_examples": distill_choice_val_count,
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })

    bootstrap = _collect_bootstrap_examples_parallel(
        deck_key,
        bootstrap_games,
        deck_seed,
        max_steps=max_steps,
        workers=worker_count,
        teacher_search_preset=teacher_search_preset,
        task_runner=task_runner,
    )
    replay_buffer.extend(bootstrap)
    total_done += bootstrap_games
    emit({
        "type": "bootstrap_finished",
        "deck": deck_key,
        "games_played": bootstrap_games,
        "examples": len(bootstrap),
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    bootstrap_result = _train_examples(
        model,
        list(bootstrap),
        device=config.device,
        learning_rate=config.learning_rate,
        epochs=config.bootstrap_epochs,
        batch_size=config.batch_size,
        entropy_coef=0.0,
        optimizer=optimizer,
        grad_scaler=grad_scaler,
        use_amp=amp_enabled,
    )
    emit({
        "type": "train_phase_finished",
        "deck": deck_key,
        "phase": "bootstrap",
        **bootstrap_result,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    bootstrap_model_state = (
        copy.deepcopy(model.state_dict())
        if callable(getattr(model, "state_dict", None))
        else None
    )

    baseline_eval = None
    comparison_eval_games = min(eval_games, 100)
    if eval_games > 0 and (dagger_games > 0 or self_play_games > 0):
        baseline_eval = evaluate_model(
            model,
            deck_key,
            eval_seed,
            comparison_eval_games,
            device=config.device,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset=teacher_search_preset,
            task_runner=task_runner,
            use_mcts=bool(config.eval_use_mcts),
            mcts_simulations=int(config.mcts_simulations),
            mcts_chance_nodes=bool(config.mcts_chance_nodes),
        )
        emit({
            "type": "baseline_eval_finished",
            "deck": deck_key,
            "eval": baseline_eval,
            "win_rate": round(
                float(baseline_eval.get("wins", 0)) / max(1, comparison_eval_games),
                4,
            ),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    dagger_wins = dagger_losses = dagger_draws = 0
    dagger_score_total = 0.0
    total_dagger_examples = 0
    total_choice_examples = 0
    dagger_train_results: list[dict[str, Any]] = []
    dagger_choice_results: list[dict[str, Any]] = []

    for batch_start in range(0, dagger_games, rollout_batch_games):
        batch_count = min(rollout_batch_games, dagger_games - batch_start)
        seeds = [
            deck_seed + 300_000 + (batch_start + idx) * 109
            for idx in range(batch_count)
        ]
        rows = _collect_rollout_batch(
            model,
            deck_key,
            seeds,
            device=config.device,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset=teacher_search_preset,
            teacher_label_model_states=True,
            phase_tag="dagger",
            task_runner=task_runner,
        )
        dagger_examples: list[TrainingExample] = []
        choice_batch_examples: list[ChoiceTrainingExample] = []
        for row_idx, (winner, score, examples, choices, _diagnostics) in enumerate(rows):
            labeled_examples = [ex for ex in examples if ex.source == "dagger"]
            dagger_examples.extend(labeled_examples)
            choice_batch_examples.extend(choices)
            dagger_score_total += score
            if winner == 0:
                dagger_wins += 1
            elif winner == 1:
                dagger_losses += 1
            else:
                dagger_draws += 1
            total_done += 1
            games_played = batch_start + row_idx + 1
            emit({
                "type": "dagger_game_finished",
                "deck": deck_key,
                "game": games_played,
                "target_games": dagger_games,
                "winner": winner,
                "score": round(float(score), 3),
                "stats": {"wins": dagger_wins, "losses": dagger_losses, "draws": dagger_draws},
                "win_rate": round(dagger_wins / max(1, games_played), 4),
                "avg_score": round(dagger_score_total / max(1, games_played), 3),
                "examples": len(labeled_examples),
                "choice_examples": len(choices),
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })

        total_dagger_examples += len(dagger_examples)
        total_choice_examples += len(choice_batch_examples)
        teacher_mix = _sample_teacher_examples(
            bootstrap,
            min(len(bootstrap), max(config.batch_size, len(dagger_examples))),
            rng,
        )
        replay_mix = _sample_replay_examples(
            replay_buffer,
            len(dagger_examples) + len(teacher_mix),
            ratio=replay_ratio,
        )
        train_rows = list(teacher_mix) + replay_mix + dagger_examples
        train_result = _train_examples(
            model,
            train_rows,
            device=config.device,
            learning_rate=config.learning_rate * 0.6,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
            entropy_coef=0.005,
            optimizer=optimizer,
            grad_scaler=grad_scaler,
            use_amp=amp_enabled,
        )
        choice_result = _train_choice_examples(
            model,
            choice_batch_examples,
            device=config.device,
            learning_rate=config.learning_rate * 0.6,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
            optimizer=optimizer,
            grad_scaler=grad_scaler,
            use_amp=amp_enabled,
        )
        dagger_train_results.append(train_result)
        dagger_choice_results.append(choice_result)
        replay_buffer.extend(dagger_examples)
        emit({
            "type": "train_phase_finished",
            "deck": deck_key,
            "phase": "dagger_batch",
            "batch": (batch_start // rollout_batch_games) + 1,
            **train_result,
            **choice_result,
            "dagger_examples": len(dagger_examples),
            "teacher_examples": len(teacher_mix),
            "replay_examples": len(replay_mix),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    wins = losses = draws = 0
    score_total = 0.0
    total_self_play_examples = 0
    self_play_train_results: list[dict[str, Any]] = []
    self_play_choice_results: list[dict[str, Any]] = []

    # Self-play opponent pool: model plays against past versions of itself
    opponent_pool = OpponentPool(max_snapshots=3)
    model_snapshot, model_snapshot_config = _model_payload_for_worker(model)
    opponent_pool.add(model_snapshot, model_snapshot_config)

    for batch_start in range(0, self_play_games, rollout_batch_games):
        batch_count = min(rollout_batch_games, self_play_games - batch_start)
        seeds = [
            deck_seed + 500_000 + (batch_start + idx) * 113
            for idx in range(batch_count)
        ]
        rows = _collect_rollout_batch(
            model,
            deck_key,
            seeds,
            device=config.device,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset=teacher_search_preset,
            teacher_label_model_states=bool(config.teacher_label_model_states),
            phase_tag="rl",
            opponent_pool=opponent_pool,
            task_runner=task_runner,
        )
        batch_examples: list[TrainingExample] = []
        batch_dagger_examples: list[TrainingExample] = []
        choice_batch_examples: list[ChoiceTrainingExample] = []
        for row_idx, (winner, score, examples, choices, _diagnostics) in enumerate(rows):
            self_play_examples = [ex for ex in examples if ex.source == "self_play"]
            dagger_examples = [ex for ex in examples if ex.source == "dagger"]
            batch_examples.extend(self_play_examples)
            batch_dagger_examples.extend(dagger_examples)
            choice_batch_examples.extend(choices)
            score_total += score
            if winner == 0:
                wins += 1
            elif winner == 1:
                losses += 1
            else:
                draws += 1
            total_done += 1
            games_played = batch_start + row_idx + 1
            emit({
                "type": "self_play_game_finished",
                "deck": deck_key,
                "game": games_played,
                "target_games": self_play_games,
                "winner": winner,
                "score": round(float(score), 3),
                "stats": {"wins": wins, "losses": losses, "draws": draws},
                "win_rate": round(wins / max(1, games_played), 4),
                "avg_score": round(score_total / max(1, games_played), 3),
                "examples": len(self_play_examples),
                "dagger_examples": len(dagger_examples),
                "choice_examples": len(choices),
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })

        total_self_play_examples += len(batch_examples)
        total_dagger_examples += len(batch_dagger_examples)
        total_choice_examples += len(choice_batch_examples)
        teacher_mix = _sample_teacher_examples(
            bootstrap,
            min(len(bootstrap), max(config.batch_size, len(batch_examples) - len(batch_dagger_examples), len(batch_examples) // 2)),
            rng,
        )
        replay_mix = _sample_replay_examples(
            replay_buffer,
            len(batch_dagger_examples) + len(batch_examples) + len(teacher_mix),
            ratio=replay_ratio,
        )
        train_rows = list(teacher_mix) + replay_mix + batch_dagger_examples + batch_examples
        train_result = _train_examples(
            model,
            train_rows,
            device=config.device,
            learning_rate=config.learning_rate * 0.35,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
            optimizer=optimizer,
            grad_scaler=grad_scaler,
            use_amp=amp_enabled,
        )
        choice_result = _train_choice_examples(
            model,
            choice_batch_examples,
            device=config.device,
            learning_rate=config.learning_rate * 0.35,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
            optimizer=optimizer,
            grad_scaler=grad_scaler,
            use_amp=amp_enabled,
        )
        self_play_train_results.append(train_result)
        self_play_choice_results.append(choice_result)
        replay_buffer.extend(batch_dagger_examples)
        replay_buffer.extend(batch_examples)

        # Update opponent pool with latest model snapshot for future self-play
        model_snapshot, model_snapshot_config = _model_payload_for_worker(model)
        opponent_pool.add(model_snapshot, model_snapshot_config)

        emit({
            "type": "train_phase_finished",
            "deck": deck_key,
            "phase": "self_play_batch",
            "batch": (batch_start // rollout_batch_games) + 1,
            **train_result,
            **choice_result,
            "self_play_examples": len(batch_examples),
            "dagger_examples": len(batch_dagger_examples),
            "teacher_examples": len(teacher_mix),
            "replay_examples": len(replay_mix),
            "opponent_pool_size": len(opponent_pool),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    if self_play_games <= 0:
        empty_result = _train_examples(
            model,
            [],
            device=config.device,
            learning_rate=config.learning_rate * 0.35,
            epochs=config.self_play_epochs,
            batch_size=config.batch_size,
            optimizer=optimizer,
            grad_scaler=grad_scaler,
            use_amp=amp_enabled,
        )
        self_play_train_results.append(empty_result)
        emit({
            "type": "train_phase_finished",
            "deck": deck_key,
            "phase": "self_play",
            **empty_result,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    # ------------------------------------------------------------------
    # Phase 5 [NEW]: Same-deal replay — fixed seeds, different strategies
    # ------------------------------------------------------------------
    same_deal_games = max(0, int(config.replay_same_deal))
    same_deal_examples: list[TrainingExample] = []
    if same_deal_games > 0:
        emit({
            "type": "phase_started",
            "deck": deck_key,
            "phase": "same_deal_replay",
            "target_games": same_deal_games,
        })
        same_deal_rows = []
        same_deal_game_indices: list[int] = []
        if config.use_mcts_training and model is not None:
            seeds: list[int] = []
            temps: list[float] = []
            for game_idx in range(same_deal_games):
                base_seed = deck_seed + 700_000 + game_idx * 113
                for temp in (0.0, 0.5, 0.9):
                    seeds.append(base_seed)
                    temps.append(temp)
                    same_deal_game_indices.append(game_idx)
            if worker_count > 1 and seeds:
                tasks = _model_game_tasks(
                    model,
                    deck_key,
                    seeds,
                    max_steps=max_steps,
                    record=True,
                    teacher_search_preset=teacher_search_preset,
                    temperatures=temps,
                    teacher_label_model_states=False,
                    phase_tag="same_deal",
                    pure_rl=True,
                    use_mcts=True,
                    mcts_simulations=int(config.mcts_simulations),
                    mcts_chance_nodes=bool(config.mcts_chance_nodes),
                )
                same_deal_rows = task_runner.run_model_game_tasks(tasks)
            else:
                for game_seed, temp in zip(seeds, temps):
                    same_deal_rows.append(_play_model_game(
                        model,
                        deck_key,
                        game_seed,
                        device=config.device,
                        max_steps=max_steps,
                        record=True,
                        teacher_search_preset=teacher_search_preset,
                        temperature=temp,
                        teacher_label_model_states=False,
                        phase_tag="same_deal",
                        use_mcts=True,
                        mcts_simulations=int(config.mcts_simulations),
                        mcts_chance_nodes=bool(config.mcts_chance_nodes),
                        pure_rl=True,
                    ))

        for row_idx, (_winner, _score, game_examples, _choices, _diagnostics) in enumerate(same_deal_rows):
            sp_examples = [ex for ex in game_examples if ex.source == "self_play"]
            for ex in sp_examples:
                ex.phase_tag = "same_deal"
            same_deal_examples.extend(sp_examples)
            total_done += 1
        for game_idx in range(same_deal_games):
            emit({
                "type": "same_deal_game_finished",
                "deck": deck_key,
                "game": game_idx + 1,
                "target_games": same_deal_games,
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })
        if same_deal_examples:
            replay_mix = _sample_replay_examples(
                replay_buffer,
                len(same_deal_examples),
                ratio=replay_ratio,
            )
            same_deal_train_result = _train_examples(
                model,
                replay_mix + same_deal_examples,
                device=config.device,
                learning_rate=config.learning_rate * 0.25,
                epochs=updates_per_rollout,
                batch_size=config.batch_size,
                optimizer=optimizer,
                grad_scaler=grad_scaler,
                use_amp=amp_enabled,
            )
            self_play_train_results.append(same_deal_train_result)
            total_self_play_examples += len(same_deal_examples)
            replay_buffer.extend(same_deal_examples)
            emit({
                "type": "train_phase_finished",
                "deck": deck_key,
                "phase": "same_deal_replay",
                **same_deal_train_result,
                "examples": len(same_deal_examples),
                "replay_examples": len(replay_mix),
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })
        emit({
            "type": "phase_finished",
            "deck": deck_key,
            "phase": "same_deal_replay",
            "examples": len(same_deal_examples),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    # ------------------------------------------------------------------
    # Phase 6: Pure RL exploration — no teacher, planner + curiosity.
    # ------------------------------------------------------------------
    pure_rl_games = max(0, int(config.pure_rl_games))
    pure_rl_examples: list[TrainingExample] = []
    pure_rl_choice_examples: list[ChoiceTrainingExample] = []
    pure_rl_wins = pure_rl_losses = pure_rl_draws = 0
    pure_rl_score_total = 0.0

    if pure_rl_games > 0:
        use_mcts_training = bool(config.use_mcts_training)
        use_curiosity = bool(config.use_curiosity)
        curiosity_tracker = None
        if use_curiosity:
            from engine.ai.dl.exploration import StateNoveltyTracker
            curiosity_tracker = StateNoveltyTracker(
                beta=float(config.curiosity_beta),
                beta_anneal_rate=0.9995,
                min_beta=0.005,
            )

        emit({
            "type": "phase_started",
            "deck": deck_key,
            "phase": "pure_rl",
            "target_games": pure_rl_games,
            "use_mcts": use_mcts_training,
            "use_curiosity": use_curiosity,
        })

        for batch_start in range(0, pure_rl_games, rollout_batch_games):
            batch_count = min(rollout_batch_games, pure_rl_games - batch_start)
            seeds = [
                deck_seed + 800_000 + (batch_start + idx) * 117
                for idx in range(batch_count)
            ]
            batch_examples: list[TrainingExample] = []
            batch_choices: list[ChoiceTrainingExample] = []

            if worker_count > 1 and curiosity_tracker is None:
                mcts_sims = int(config.mcts_simulations) if use_mcts_training else 0
                rows = task_runner.run_model_game_tasks(_model_game_tasks(
                    model,
                    deck_key,
                    seeds,
                    max_steps=max_steps,
                    record=True,
                    teacher_search_preset=teacher_search_preset,
                    temperature=0.7,
                    teacher_label_model_states=False,
                    phase_tag="pure_rl",
                    pure_rl=True,
                    use_mcts=use_mcts_training and mcts_sims > 0,
                    mcts_simulations=mcts_sims,
                    mcts_chance_nodes=bool(config.mcts_chance_nodes),
                ))
            else:
                rows = []
                for game_seed in seeds:
                    mcts_sims = int(config.mcts_simulations) if use_mcts_training else 0
                    rows.append(_play_model_game(
                        model,
                        deck_key,
                        game_seed,
                        device=config.device,
                        max_steps=max_steps,
                        record=True,
                        teacher_search_preset=teacher_search_preset,
                        temperature=0.7,
                        teacher_label_model_states=False,
                        phase_tag="pure_rl",
                        pure_rl=True,
                        use_mcts=use_mcts_training and mcts_sims > 0,
                        mcts_simulations=mcts_sims,
                        mcts_chance_nodes=bool(config.mcts_chance_nodes),
                        curiosity_tracker=curiosity_tracker,
                    ))

            for row_idx, (winner, score, game_examples, game_choices, _diagnostics) in enumerate(rows):
                sp_examples = [ex for ex in game_examples if ex.source == "self_play"]
                batch_examples.extend(sp_examples)
                batch_choices.extend(game_choices)
                pure_rl_score_total += score
                if winner == 0:
                    pure_rl_wins += 1
                elif winner == 1:
                    pure_rl_losses += 1
                else:
                    pure_rl_draws += 1
                total_done += 1

            pure_rl_examples.extend(batch_examples)
            pure_rl_choice_examples.extend(batch_choices)

            # Train on pure RL batch
            if batch_examples:
                replay_mix = _sample_replay_examples(
                    replay_buffer,
                    len(batch_examples),
                    ratio=replay_ratio,
                )
                train_result = _train_examples(
                    model, replay_mix + batch_examples,
                    device=config.device,
                    learning_rate=config.learning_rate * 0.25,
                    epochs=updates_per_rollout,
                    batch_size=config.batch_size,
                    optimizer=optimizer,
                    grad_scaler=grad_scaler,
                    use_amp=amp_enabled,
                )
                self_play_train_results.append(train_result)
                total_self_play_examples += len(batch_examples)
                replay_buffer.extend(batch_examples)
                emit({
                    "type": "train_phase_finished",
                    "deck": deck_key,
                    "phase": "pure_rl_batch",
                    "batch": (batch_start // rollout_batch_games) + 1,
                    **train_result,
                    "examples": len(batch_examples),
                    "replay_examples": len(replay_mix),
                    "total_games_played": total_done,
                    "total_training_games": total_training_games,
                })

        # Curiosity stats
        curiosity_stats = {}
        if curiosity_tracker is not None:
            curiosity_stats = curiosity_tracker.stats()

        emit({
            "type": "phase_finished",
            "deck": deck_key,
            "phase": "pure_rl",
            "examples": len(pure_rl_examples),
            "stats": {"wins": pure_rl_wins, "losses": pure_rl_losses, "draws": pure_rl_draws},
            "win_rate": round(pure_rl_wins / max(1, pure_rl_games), 4),
            "avg_score": round(pure_rl_score_total / max(1, pure_rl_games), 3),
            "curiosity": curiosity_stats,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    dagger_result = _aggregate_train_results(dagger_train_results, total_dagger_examples)
    choice_result = _aggregate_choice_results(dagger_choice_results + self_play_choice_results, total_choice_examples)
    self_play_result = _aggregate_train_results(self_play_train_results, total_self_play_examples)

    # Encoded examples are intentionally rich Python objects and can occupy
    # several GB after a long run. Release them before spawning the final
    # evaluation wave so Windows does not exhaust commit memory.
    replay_buffer.clear()
    bootstrap.clear()
    same_deal_examples.clear()
    pure_rl_examples.clear()
    pure_rl_choice_examples.clear()
    opponent_pool.clear()
    for name in (
        "dagger_examples",
        "choice_batch_examples",
        "batch_examples",
        "batch_dagger_examples",
        "batch_choices",
        "train_rows",
        "teacher_mix",
        "replay_mix",
        "distill_actions",
        "distill_choices",
        "train_actions",
        "val_actions",
        "train_choices",
        "val_choices",
    ):
        value = locals().get(name)
        if isinstance(value, list):
            value.clear()
    gc.collect()
    if str(config.device).startswith("cuda"):
        try:
            torch.cuda.empty_cache()
        except Exception:
            pass

    resume_path = os.path.join(DEFAULT_MODEL_DIR, f"resume_{deck_key}.pt")
    has_training_work = bool(config.distill_dataset) or any(
        int(value) > 0
        for value in (
            config.bootstrap_games,
            config.dagger_games,
            config.games,
            config.pure_rl_games,
            config.replay_same_deal,
        )
    )
    if has_training_work and callable(getattr(model, "state_dict", None)):
        save_checkpoint(
            resume_path,
            model,
            {
                "trainer": LEGACY_METADATA_TRAINER,
                "deck": deck_key,
                "phase": "pre_eval",
                "accepted": False,
                "verified": False,
                "total_games_played": total_done,
                "choice_head_enabled": bool(getattr(model, "choice_head_enabled", False)),
                "summary": {deck_key: {"choice": choice_result}},
            },
        )
        emit({
            "type": "checkpoint_saved",
            "deck": deck_key,
            "phase": "pre_eval",
            "model_path": resume_path,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    challenge_baseline_eval = None
    cached_challenge_baseline = config.challenge_baseline_eval
    if eval_games > 0 and cached_challenge_baseline is not None:
        challenge_baseline_eval = copy.deepcopy(cached_challenge_baseline)
        if int(challenge_baseline_eval.get("games") or 0) != eval_games:
            raise ValueError("Cached Challenge baseline game count does not match eval_games")
        cached_points = challenge_baseline_eval.get("game_points")
        if not isinstance(cached_points, list) or len(cached_points) != eval_games:
            raise ValueError("Cached Challenge baseline lacks complete ordered game_points")
        emit({
            "type": "challenge_baseline_eval_reused",
            "deck": deck_key,
            "training_seed": deck_seed,
            "eval_seed": eval_seed,
            "eval": challenge_baseline_eval,
            "source": config.challenge_baseline_source or "direct_config",
            "win_rate": round(
                float(challenge_baseline_eval.get("wins", 0)) / max(1, eval_games),
                4,
            ),
            "point_rate": round(_point_rate(challenge_baseline_eval), 4),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })
    elif eval_games > 0:
        challenge_baseline_eval = evaluate_challenge_baseline(
            deck_key,
            eval_seed,
            eval_games,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset=teacher_search_preset,
        )
        emit({
            "type": "challenge_baseline_eval_finished",
            "deck": deck_key,
            "training_seed": deck_seed,
            "eval_seed": eval_seed,
            "eval": challenge_baseline_eval,
            "win_rate": round(
                float(challenge_baseline_eval.get("wins", 0)) / max(1, eval_games),
                4,
            ),
            "point_rate": round(_point_rate(challenge_baseline_eval), 4),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    eval_result = evaluate_model(
        model,
        deck_key,
        eval_seed,
        eval_games,
        device=config.device,
        max_steps=max_steps,
        workers=worker_count,
        teacher_search_preset=teacher_search_preset,
        use_mcts=bool(config.eval_use_mcts),
        mcts_simulations=int(config.mcts_simulations),
        mcts_chance_nodes=bool(config.mcts_chance_nodes),
    )
    total_done += eval_games
    eval_win_rate = 0.0
    if eval_games > 0:
        eval_win_rate = round(float(eval_result.get("wins", 0)) / max(1, eval_games), 4)
    baseline_delta = _evaluation_delta(eval_result, challenge_baseline_eval)
    training_delta = _evaluation_delta(eval_result, baseline_eval)
    old_delta = _evaluation_delta(eval_result, old_eval)
    accepted = _accepts_candidate(
        eval_result,
        challenge_baseline_eval,
        old_eval,
        acceptance_metric=acceptance_metric,
        min_win_delta=min_win_delta,
        min_point_rate=float(config.min_point_rate),
        min_delta_point_rate=float(config.min_delta_point_rate),
        max_step_exhaustion_rate=float(config.max_step_exhaustion_rate),
    )
    selected_stage = "final"
    if (
        not accepted
        and bootstrap_model_state is not None
        and baseline_eval is not None
        and int(baseline_eval.get("games") or 0) > 0
    ):
        model.load_state_dict(bootstrap_model_state)
        bootstrap_final_eval = evaluate_model(
            model,
            deck_key,
            eval_seed,
            eval_games,
            device=config.device,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset=teacher_search_preset,
            use_mcts=bool(config.eval_use_mcts),
            mcts_simulations=int(config.mcts_simulations),
            mcts_chance_nodes=bool(config.mcts_chance_nodes),
        )
        total_done += eval_games
        bootstrap_accepted = _accepts_candidate(
            bootstrap_final_eval,
            challenge_baseline_eval,
            old_eval,
            acceptance_metric=acceptance_metric,
            min_win_delta=min_win_delta,
            min_point_rate=float(config.min_point_rate),
            min_delta_point_rate=float(config.min_delta_point_rate),
            max_step_exhaustion_rate=float(config.max_step_exhaustion_rate),
        )
        emit({
            "type": "fallback_eval_finished",
            "deck": deck_key,
            "stage": "bootstrap",
            "eval": bootstrap_final_eval,
            "accepted": bootstrap_accepted,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })
        if bootstrap_accepted:
            eval_result = bootstrap_final_eval
            accepted = True
            selected_stage = "bootstrap"
            eval_win_rate = round(
                float(eval_result.get("wins", 0)) / max(1, eval_games),
                4,
            )
            baseline_delta = _evaluation_delta(eval_result, challenge_baseline_eval)
            training_delta = _evaluation_delta(eval_result, baseline_eval)
            old_delta = _evaluation_delta(eval_result, old_eval)
    emit({
        "type": "eval_finished",
        "deck": deck_key,
        "eval": eval_result,
        "baseline_eval": baseline_eval,
        "challenge_baseline_eval": challenge_baseline_eval,
        "old_eval": old_eval,
        "accepted": accepted,
        "selected_stage": selected_stage,
        "acceptance_metric": acceptance_metric,
        "min_win_delta": min_win_delta,
        "min_point_rate": float(config.min_point_rate),
        "min_delta_point_rate": float(config.min_delta_point_rate),
        "max_step_exhaustion_rate": float(config.max_step_exhaustion_rate),
        "eval_use_mcts": bool(config.eval_use_mcts),
        "mcts_simulations": int(config.mcts_simulations),
        **baseline_delta,
        "training_delta_wins": training_delta.get("delta_wins"),
        "training_delta_win_rate": training_delta.get("delta_win_rate"),
        "training_delta_point_rate": training_delta.get("delta_point_rate"),
        "training_delta_avg_score": training_delta.get("delta_avg_score"),
        "old_delta_wins": old_delta.get("delta_wins"),
        "old_delta_win_rate": old_delta.get("delta_win_rate"),
        "old_delta_point_rate": old_delta.get("delta_point_rate"),
        "old_delta_avg_score": old_delta.get("delta_avg_score"),
        "win_rate": eval_win_rate,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    stats = {"wins": wins, "losses": losses, "draws": draws}
    summary = {
        "distill": {
            **distill_result,
            "loaded": distill_stats,
            "val_examples": distill_action_val_count,
        },
        "bootstrap": bootstrap_result,
        "baseline_eval": baseline_eval or {"games": 0},
        "challenge_baseline_eval": challenge_baseline_eval or {"games": 0},
        "challenge_baseline_source": config.challenge_baseline_source or "fresh_evaluation",
        "dagger": dagger_result,
        "choice": choice_result,
        "distill_choice": {
            **distill_choice_result,
            "val_choice_examples": distill_choice_val_count,
        },
        "self_play": self_play_result,
        "dagger_stats": {"wins": dagger_wins, "losses": dagger_losses, "draws": dagger_draws},
        "self_play_stats": stats,
        "eval": eval_result,
        "eval_seed": eval_seed,
        "old_eval": old_eval or {"games": 0},
        "accepted": accepted,
        "selected_stage": selected_stage,
        "acceptance_metric": acceptance_metric,
        "min_win_delta": min_win_delta,
        "min_delta_point_rate": float(config.min_delta_point_rate),
        "eval_use_mcts": bool(config.eval_use_mcts),
        "mcts_simulations": int(config.mcts_simulations),
        **baseline_delta,
        "training_delta_wins": training_delta.get("delta_wins"),
        "training_delta_win_rate": training_delta.get("delta_win_rate"),
        "training_delta_point_rate": training_delta.get("delta_point_rate"),
        "training_delta_avg_score": training_delta.get("delta_avg_score"),
        "rollout_batch_games": rollout_batch_games,
        "updates_per_rollout": updates_per_rollout,
        "teacher_search_preset": teacher_search_preset,
        "choice_head_enabled": bool(config.choice_head_enabled),
        "teacher_label_model_states": bool(config.teacher_label_model_states),
    }
    emit({
        "type": "deck_finished",
        "deck": deck_key,
        "training_games": self_play_games,
        "stats": stats,
        "eval": eval_result,
        "baseline_eval": baseline_eval,
        "challenge_baseline_eval": challenge_baseline_eval,
        "accepted": accepted,
        "acceptance_metric": acceptance_metric,
        "delta_wins": baseline_delta.get("delta_wins"),
        "delta_win_rate": baseline_delta.get("delta_win_rate"),
        "delta_point_rate": baseline_delta.get("delta_point_rate"),
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    task_runner.__exit__(None, None, None)
    return summary, total_done


def _rejected_output_path(path: str) -> str:
    root, ext = os.path.splitext(path)
    return f"{root}.rejected{ext or '.pt'}"


def _load_old_eval(
    output_path: str,
    deck_key: str,
    seed: int,
    eval_games: int,
    *,
    device: str,
    max_steps: int,
    workers: int,
    teacher_search_preset: str,
    use_mcts: bool = False,
    mcts_simulations: int = 64,
    mcts_chance_nodes: bool = False,
) -> dict[str, Any] | None:
    if eval_games <= 0 or not output_path or not os.path.exists(output_path):
        return None
    try:
        old_model, payload = load_checkpoint(output_path, device)
    except Exception:
        return None
    schema = dict(payload.get("schema") or payload.get("metadata") or {})
    if (
        int(schema.get("rules_version") or 0) != RULES_SCHEMA_VERSION
        or int(schema.get("action_version") or 0) != ACTION_SCHEMA_VERSION
        or int(schema.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION
    ):
        return None
    return evaluate_model(
        old_model,
        deck_key,
        seed,
        eval_games,
        device=device,
        max_steps=max_steps,
        workers=workers,
        teacher_search_preset=teacher_search_preset,
        use_mcts=bool(use_mcts),
        mcts_simulations=max(1, int(mcts_simulations)),
        mcts_chance_nodes=bool(mcts_chance_nodes),
    )


def run_deep_training(
    config: DeepTrainingConfig,
    progress_callback: ProgressCallback | None = None,
) -> dict[str, Any]:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for deep-learning AI training.")
    _ensure_cards_loaded()
    assert torch is not None

    trainer_mode = _normalized_trainer(config.trainer)
    if trainer_mode not in (TRAINER_ALPHA_ZERO, TRAINER_LEGACY):
        raise ValueError(f"Unknown deep AI trainer: {config.trainer}")
    device_info = _torch_device_info(config.device)
    effective_config = replace(config, device=str(device_info["device"]), trainer=trainer_mode)
    torch.manual_seed(int(effective_config.seed))
    if bool(device_info["cuda_available"]):
        torch.cuda.manual_seed_all(int(effective_config.seed))
        try:
            torch.set_float32_matmul_precision("high")
            torch.backends.cuda.matmul.allow_tf32 = True
            torch.backends.cudnn.allow_tf32 = True
            torch.backends.cudnn.benchmark = True
        except Exception:
            pass
    writer = _open_progress_writer(effective_config.progress_jsonl)

    def emit(event: dict[str, Any]) -> None:
        event = dict(event)
        event.setdefault("timestamp", time.time())
        if progress_callback:
            progress_callback(event)
        if writer:
            writer.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
            writer.flush()

    deck_keys = _deck_keys(effective_config.deck)
    if effective_config.challenge_baseline_eval is not None and len(deck_keys) != 1:
        raise ValueError("A cached Challenge baseline can only be reused for a single deck")
    started = time.time()
    train_summary: dict[str, Any] = {}
    bootstrap_games = 0 if trainer_mode == TRAINER_ALPHA_ZERO else max(0, int(effective_config.bootstrap_games))
    dagger_games = 0 if trainer_mode == TRAINER_ALPHA_ZERO else max(0, int(effective_config.dagger_games))
    self_play_games = max(0, int(effective_config.games))
    eval_games = 0 if trainer_mode == TRAINER_ALPHA_ZERO else max(0, int(effective_config.eval_games))
    pure_rl_games = 0 if trainer_mode == TRAINER_ALPHA_ZERO else max(0, int(effective_config.pure_rl_games))
    same_deal_trajectories = 0 if trainer_mode == TRAINER_ALPHA_ZERO else max(0, int(effective_config.replay_same_deal)) * 3
    distill_datasets = () if trainer_mode == TRAINER_ALPHA_ZERO else tuple(effective_config.distill_dataset or ())
    league_eval_games = (
        max(0, int(effective_config.league_eval_games))
        if trainer_mode == TRAINER_ALPHA_ZERO and self_play_games > 0
        else 0
    )
    if trainer_mode == TRAINER_ALPHA_ZERO:
        total_training_games = (self_play_games + league_eval_games) * len(deck_keys)
    else:
        total_training_games = (
            bootstrap_games
            + dagger_games
            + self_play_games
            + pure_rl_games
            + same_deal_trajectories
            + eval_games
        ) * len(deck_keys)
    total_done = 0
    model_paths: dict[str, str] = {}
    requested_model_paths: dict[str, str] = {}
    accepted: dict[str, bool] = {}
    warm_start_sources: dict[str, dict[str, str]] = {}
    metadata_acceptance_metric = "league_elo" if trainer_mode == TRAINER_ALPHA_ZERO else effective_config.acceptance_metric
    metadata_teacher_search_preset = "" if trainer_mode == TRAINER_ALPHA_ZERO else effective_config.teacher_search_preset
    metadata_teacher_label_model_states = (
        False if trainer_mode == TRAINER_ALPHA_ZERO else bool(effective_config.teacher_label_model_states)
    )
    metadata_min_win_delta = 0 if trainer_mode == TRAINER_ALPHA_ZERO else int(effective_config.min_win_delta)

    try:
        emit({
            "type": "run_started",
            "trainer": trainer_mode,
            "trainer_version": ALPHA_ZERO_METADATA_TRAINER if trainer_mode == TRAINER_ALPHA_ZERO else LEGACY_METADATA_TRAINER,
            "deck": effective_config.deck,
            "deck_keys": deck_keys,
            "seed": int(effective_config.seed),
            "games_per_deck": self_play_games,
            "bootstrap_games": bootstrap_games,
            "dagger_games": dagger_games,
            "eval_games": eval_games,
            "league_eval_games": league_eval_games,
            "league_use_mcts": bool(effective_config.league_use_mcts),
            "league_dir": effective_config.league_dir,
            "min_score_rate": float(effective_config.min_score_rate),
            "min_elo_delta": float(effective_config.min_elo_delta),
            "min_point_rate": float(effective_config.min_point_rate),
            "min_delta_point_rate": float(effective_config.min_delta_point_rate),
            "max_step_exhaustion_rate": float(effective_config.max_step_exhaustion_rate),
            "challenge_baseline_source": effective_config.challenge_baseline_source or "",
            "recovered_choice_examples": max(0, int(effective_config.recovered_choice_examples)),
            "eval_use_mcts": bool(effective_config.eval_use_mcts),
            "mcts_simulations": int(effective_config.mcts_simulations),
            "pure_rl_games": pure_rl_games,
            "replay_same_deal": 0 if trainer_mode == TRAINER_ALPHA_ZERO else int(effective_config.replay_same_deal),
            "same_deal_trajectories": same_deal_trajectories,
            "workers": int(effective_config.workers),
            "requested_device": device_info["requested_device"],
            "device": effective_config.device,
            "torch_version": device_info["torch_version"],
            "torch_cuda": device_info["torch_cuda"],
            "cuda_available": device_info["cuda_available"],
            "gpu_name": device_info["gpu_name"],
            "device_fallback_reason": device_info["device_fallback_reason"],
            "max_steps": max(20, int(effective_config.max_steps)),
            "rollout_batch_games": max(1, int(effective_config.rollout_batch_games)),
            "updates_per_rollout": max(1, int(effective_config.updates_per_rollout)),
            "teacher_search_preset": metadata_teacher_search_preset,
            "choice_head_enabled": bool(effective_config.choice_head_enabled),
            "acceptance_metric": metadata_acceptance_metric,
            "min_win_delta": metadata_min_win_delta,
            "teacher_label_model_states": metadata_teacher_label_model_states,
            "replay_buffer_size": int(effective_config.replay_buffer_size),
            "replay_sample_ratio": float(effective_config.replay_sample_ratio),
            "distill_dataset": list(distill_datasets),
            "distill_epochs": int(effective_config.distill_epochs),
            "distill_val_split": float(effective_config.distill_val_split),
            "total_training_games": total_training_games,
        })

        for offset, deck_key in enumerate(deck_keys):
            deck_seed = effective_config.seed + offset * 1009
            output_path = _candidate_output_path(effective_config, deck_key, len(deck_keys) > 1)
            old_model_path = _output_path_for_deck(deck_key)
            requested_model_paths[deck_key] = output_path
            warm_start_path = effective_config.model
            warm_start_source = "explicit_model" if warm_start_path else "none"
            if not warm_start_path and effective_config.warm_start:
                warm_start_path = _warm_start_path_for_deck(deck_key)
                warm_start_source = "deck_default" if warm_start_path else "none"
            if warm_start_path and not os.path.exists(warm_start_path):
                warm_start_source = "missing"
            warm_start_sources[deck_key] = {
                "source": warm_start_source,
                "path": warm_start_path or "",
            }
            loaded_choice_examples = max(
                _checkpoint_choice_training_examples(warm_start_path, deck_key),
                max(0, int(effective_config.recovered_choice_examples)),
            )
            old_eval = None
            if trainer_mode == TRAINER_LEGACY and effective_config.challenge_baseline_eval is None:
                old_eval = _load_old_eval(
                    old_model_path,
                    deck_key,
                    deck_seed + 900_000,
                    min(eval_games, 100),
                    device=effective_config.device,
                    max_steps=max(20, int(effective_config.max_steps)),
                    workers=_normalized_workers(effective_config.workers),
                    teacher_search_preset=effective_config.teacher_search_preset,
                    use_mcts=bool(effective_config.eval_use_mcts),
                    mcts_simulations=int(effective_config.mcts_simulations),
                    mcts_chance_nodes=bool(effective_config.mcts_chance_nodes),
                )

            model = _load_or_create_model(effective_config, deck_key)
            model.to(effective_config.device)

            if trainer_mode == TRAINER_ALPHA_ZERO:
                deck_summary, total_done = _train_deck_alpha_zero_pipeline(
                    model,
                    deck_key,
                    deck_seed,
                    effective_config,
                    emit,
                    total_done,
                    total_training_games,
                )
            else:
                deck_summary, total_done = _train_deck_pipeline(
                    model,
                    deck_key,
                    deck_seed,
                    effective_config,
                    emit,
                    total_done,
                    total_training_games,
                    old_eval=old_eval,
                )
            trained_choice_examples = int((deck_summary.get("choice") or {}).get("choice_examples") or 0)
            trained_choice_examples += int((deck_summary.get("distill_choice") or {}).get("choice_examples") or 0)
            if trained_choice_examples <= 0 and loaded_choice_examples > 0:
                deck_summary["loaded_choice_examples"] = int(loaded_choice_examples)
                trained_choice_examples = int(loaded_choice_examples)
            if trained_choice_examples <= 0 and bool(getattr(model, "choice_head_enabled", False)):
                model.choice_head_enabled = False
                deck_summary["choice_head_enabled"] = False
                emit({
                    "type": "choice_head_disabled",
                    "deck": deck_key,
                    "reason": "no_choice_training_examples",
                    "total_games_played": total_done,
                    "total_training_games": total_training_games,
                })
            train_summary[deck_key] = deck_summary
            deck_accepted = bool(deck_summary.get("accepted", True))
            evidence_games = (
                int((deck_summary.get("league") or {}).get("games") or 0)
                if trainer_mode == TRAINER_ALPHA_ZERO else eval_games
            )
            metadata_accepted = deck_accepted and evidence_games > 0
            accepted[deck_key] = metadata_accepted

            save_path = output_path
            preserved_existing = os.path.exists(output_path)
            if not deck_accepted:
                save_path = _rejected_output_path(output_path)

            metadata = {
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "deck": deck_key,
                "seed": deck_seed,
                "planner_version": PLANNER_SCHEMA_VERSION,
                "games": self_play_games,
                "bootstrap_games": bootstrap_games,
                "dagger_games": dagger_games,
                "eval_games": eval_games,
                "league_eval_games": league_eval_games,
                "league_use_mcts": bool(effective_config.league_use_mcts),
                "league_dir": effective_config.league_dir,
                "min_score_rate": float(effective_config.min_score_rate),
                "min_elo_delta": float(effective_config.min_elo_delta),
                "min_point_rate": float(effective_config.min_point_rate),
                "min_delta_point_rate": float(effective_config.min_delta_point_rate),
                "max_step_exhaustion_rate": float(effective_config.max_step_exhaustion_rate),
                "challenge_baseline_source": effective_config.challenge_baseline_source or "fresh_evaluation",
                "recovered_choice_examples": max(0, int(effective_config.recovered_choice_examples)),
                "eval_use_mcts": bool(effective_config.eval_use_mcts),
                "mcts_simulations": int(effective_config.mcts_simulations),
                "pure_rl_games": pure_rl_games,
                "replay_same_deal": 0 if trainer_mode == TRAINER_ALPHA_ZERO else int(effective_config.replay_same_deal),
                "workers": int(effective_config.workers),
                "requested_device": device_info["requested_device"],
                "device": effective_config.device,
                "torch_version": device_info["torch_version"],
                "torch_cuda": device_info["torch_cuda"],
                "cuda_available": device_info["cuda_available"],
                "gpu_name": device_info["gpu_name"],
                "trainer": ALPHA_ZERO_METADATA_TRAINER if trainer_mode == TRAINER_ALPHA_ZERO else LEGACY_METADATA_TRAINER,
                "trainer_mode": trainer_mode,
                "warm_start": bool(effective_config.warm_start),
                "warm_start_source": warm_start_source,
                "warm_start_path": warm_start_path or "",
                "accepted": metadata_accepted,
                "training_gate_accepted": deck_accepted,
                "preserved_existing": preserved_existing,
                "requested_output_path": output_path,
                "summary": {deck_key: deck_summary},
                "rollout_batch_games": effective_config.rollout_batch_games,
                "updates_per_rollout": effective_config.updates_per_rollout,
                "teacher_search_preset": metadata_teacher_search_preset,
                "choice_head_enabled": bool(getattr(model, "choice_head_enabled", False)),
                "acceptance_metric": metadata_acceptance_metric,
                "min_win_delta": metadata_min_win_delta,
                "teacher_label_model_states": metadata_teacher_label_model_states,
                "replay_buffer_size": int(effective_config.replay_buffer_size),
                "replay_sample_ratio": float(effective_config.replay_sample_ratio),
                "distill_dataset": list(distill_datasets),
                "distill_epochs": int(effective_config.distill_epochs),
                "distill_val_split": float(effective_config.distill_val_split),
                **_verification_metadata(evidence_games, metadata_accepted),
            }
            save_checkpoint(save_path, model, metadata)
            model_paths[deck_key] = save_path
            sidecar = os.path.splitext(save_path)[0] + ".json"
            with open(sidecar, "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "checkpoint_sha256": _checkpoint_sha256(save_path),
                        "model_path": save_path,
                        "metadata": metadata,
                    },
                    fh,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
            resume_path = os.path.join(DEFAULT_MODEL_DIR, f"resume_{deck_key}.pt")
            if (
                bootstrap_games
                + dagger_games
                + self_play_games
                + pure_rl_games
                + same_deal_trajectories > 0
                or bool(distill_datasets)
            ):
                try:
                    if os.path.exists(resume_path):
                        os.remove(resume_path)
                except OSError:
                    pass

        payload = {
            "model_paths": model_paths,
            "model_path": next(iter(model_paths.values())) if len(model_paths) == 1 else None,
            "requested_model_paths": requested_model_paths,
            "accepted": accepted,
            "metadata": {
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "deck": effective_config.deck,
                "seed": int(effective_config.seed),
                "planner_version": PLANNER_SCHEMA_VERSION,
                "deck_keys": deck_keys,
                "games": self_play_games,
                "bootstrap_games": bootstrap_games,
                "dagger_games": dagger_games,
                "eval_games": eval_games,
                "league_eval_games": league_eval_games,
                "league_use_mcts": bool(effective_config.league_use_mcts),
                "league_dir": effective_config.league_dir,
                "min_score_rate": float(effective_config.min_score_rate),
                "min_elo_delta": float(effective_config.min_elo_delta),
                "min_point_rate": float(effective_config.min_point_rate),
                "min_delta_point_rate": float(effective_config.min_delta_point_rate),
                "max_step_exhaustion_rate": float(effective_config.max_step_exhaustion_rate),
                "eval_use_mcts": bool(effective_config.eval_use_mcts),
                "mcts_simulations": int(effective_config.mcts_simulations),
                "pure_rl_games": pure_rl_games,
                "replay_same_deal": 0 if trainer_mode == TRAINER_ALPHA_ZERO else int(effective_config.replay_same_deal),
                "workers": int(effective_config.workers),
                "requested_device": device_info["requested_device"],
                "device": effective_config.device,
                "torch_version": device_info["torch_version"],
                "torch_cuda": device_info["torch_cuda"],
                "cuda_available": device_info["cuda_available"],
                "gpu_name": device_info["gpu_name"],
                "trainer": ALPHA_ZERO_METADATA_TRAINER if trainer_mode == TRAINER_ALPHA_ZERO else LEGACY_METADATA_TRAINER,
                "trainer_mode": trainer_mode,
                "warm_start_sources": warm_start_sources,
                "summary": train_summary,
                "rollout_batch_games": effective_config.rollout_batch_games,
                "updates_per_rollout": effective_config.updates_per_rollout,
                "teacher_search_preset": metadata_teacher_search_preset,
                "choice_head_enabled": bool(effective_config.choice_head_enabled),
                "acceptance_metric": metadata_acceptance_metric,
                "min_win_delta": metadata_min_win_delta,
                "teacher_label_model_states": metadata_teacher_label_model_states,
                "replay_buffer_size": int(effective_config.replay_buffer_size),
                "replay_sample_ratio": float(effective_config.replay_sample_ratio),
                "distill_dataset": list(distill_datasets),
                "distill_epochs": int(effective_config.distill_epochs),
                "distill_val_split": float(effective_config.distill_val_split),
                **_verification_metadata(
                    league_eval_games if trainer_mode == TRAINER_ALPHA_ZERO else eval_games,
                    all(accepted.values()) if accepted else False,
                ),
            },
        }
        emit({
            "type": "run_finished",
            "trainer": trainer_mode,
            "model_paths": model_paths,
            "model_count": len(deck_keys),
            "accepted": accepted,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
            "elapsed_seconds": round(time.time() - started, 3),
        })
        return payload
    except Exception as exc:
        emit({"type": "error", "message": str(exc)})
        raise
    finally:
        if writer:
            writer.close()

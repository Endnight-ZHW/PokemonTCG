"""Training helpers for the optional deep-learning AI."""
from __future__ import annotations

import copy
import json
import os
import random
import time
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool
from dataclasses import dataclass, replace
from typing import Any, Callable

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, expand_deck
from engine.ai.challenge_ai import AIAction, AIConfig, create_challenge_ai
from engine.ai.dl.encoder import ACTION_NUMERIC_SIZE, CARD_SEMANTIC_SIZE, ActionStateEncoder, EncodedAction, EncodedState
from engine.ai.dl.model import TORCH_AVAILABLE, create_model, load_checkpoint, save_checkpoint, torch
from engine.ai.dl.opponent_pool import OpponentPool, save_opponent_pool, load_opponent_pool

from engine.ai.training import DECK_SPECS, _determine_soft_winner, finish_setup, force_end_turn, terminal_training_score
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from engine.turn_manager import TurnManager


DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")

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
    deck: str = "all"
    games: int = 800
    seed: int = 17
    model: str | None = None
    output: str | None = None
    device: str = "cpu"
    bootstrap_games: int = 2000
    dagger_games: int = 500
    bootstrap_epochs: int = 10
    self_play_epochs: int = 10
    eval_games: int = 200
    workers: int = 1
    max_steps: int = 250
    learning_rate: float = 5e-4
    batch_size: int = 64
    progress_jsonl: str | None = None
    rollout_batch_games: int = 16
    updates_per_rollout: int = 2
    teacher_search_preset: str = "hybrid"
    choice_head_enabled: bool = True
    acceptance_metric: str = "score"
    min_win_delta: int = 0
    teacher_label_model_states: bool = True
    # --- New: Pure RL & MCTS settings ---
    pure_rl_games: int = 400
    mcts_simulations: int = 200
    mcts_chance_nodes: bool = True
    use_mcts_training: bool = True
    teacher_warmup_ratio: float = 0.6
    # --- New: Curiosity exploration ---
    curiosity_beta: float = 0.05
    use_curiosity: bool = False
    # --- New: Same-deal replay ---
    replay_same_deal: int = 50
    # --- New: Fair evaluation ---
    eval_same_seeds: bool = True
    # --- New: Deck embedding ---
    deck_embed_dim: int = 0  # 0 = disabled, 16 = enabled


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


@dataclass
class ChoiceTrainingExample:
    state: EncodedState
    request_type: str
    candidate_choices: list[EncodedAction]
    teacher_target_index: int
    source: str = "teacher"
    phase_tag: str = ""


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
    opponent_model_state: dict[str, Any] | None = None
    opponent_model_config: dict[str, Any] | None = None


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
    return (
        action.action.name if isinstance(action.action, PlayerAction) else str(action.action),
        tuple(sorted((action.params or {}).items())),
        bool(action.terminal),
    )


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


def _setup_match(deck_key: str, opponent_key: str, seed: int, seat: int, teacher_search_preset: str = "hybrid"):
    rng_state = random.getstate()
    random.seed(seed)
    try:
        deck_a_player_idx = 1 if seat == 1 else 0
        state = GameState()
        deck1_key = deck_key if deck_a_player_idx == 0 else opponent_key
        deck2_key = opponent_key if deck_a_player_idx == 0 else deck_key
        state.setup_game(expand_deck(DECK_SPECS[deck1_key]), expand_deck(DECK_SPECS[deck2_key]))
        tm = TurnManager(state)
        if deck_a_player_idx == 0:
            ai0 = _make_teacher(deck_key, seed + 11, teacher_search_preset)
            ai1 = _make_teacher(opponent_key, seed + 29, teacher_search_preset)
        else:
            ai0 = _make_teacher(opponent_key, seed + 29, teacher_search_preset)
            ai1 = _make_teacher(deck_key, seed + 11, teacher_search_preset)
        finish_setup(state, tm, [ai0, ai1])
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
        "state_norm": getattr(model, "state_norm", "layer"),
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
                if state.winner is not None or state.phase == TurnPhase.GAME_OVER:
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


def _run_bootstrap_tasks(tasks: list[BootstrapTask], workers: int | None) -> list[list[TrainingExample]]:
    worker_count = _normalized_workers(workers)
    if worker_count <= 1 or len(tasks) <= 1:
        return [_execute_bootstrap_task(task) for task in tasks]
    try:
        with ProcessPoolExecutor(max_workers=worker_count, initializer=_worker_init) as executor:
            return list(executor.map(_execute_bootstrap_task, tasks))
    except BrokenProcessPool:
        return [_execute_bootstrap_task(task) for task in tasks]


def _collect_bootstrap_examples_parallel(
    deck_key: str,
    games: int,
    seed: int,
    *,
    max_steps: int,
    workers: int,
    teacher_search_preset: str,
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
    for rows in _run_bootstrap_tasks(tasks, worker_count):
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

    max_actions = max(len(ex.actions) for ex in examples)
    action_numeric = torch.zeros(B, max_actions, action_numeric_size, dtype=torch.float32, device=device)
    action_cards = torch.zeros(B, max_actions, dtype=torch.long, device=device)
    action_mask = torch.zeros(B, max_actions, dtype=torch.bool, device=device)

    for i, ex in enumerate(examples):
        n = len(ex.actions)
        if n == 0:
            continue
        action_numeric[i, :n] = torch.tensor(
            [_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in ex.actions],
            dtype=torch.float32,
            device=device,
        )
        action_cards[i, :n] = torch.tensor([a.card_id for a in ex.actions], dtype=torch.long, device=device)
        action_mask[i, :n] = True

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

    max_choices = max(len(ex.candidate_choices) for ex in examples)
    choice_numeric = torch.zeros(B, max_choices, action_numeric_size, dtype=torch.float32, device=device)
    choice_cards = torch.zeros(B, max_choices, dtype=torch.long, device=device)
    choice_mask = torch.zeros(B, max_choices, dtype=torch.bool, device=device)

    for i, ex in enumerate(examples):
        n = len(ex.candidate_choices)
        if n == 0:
            continue
        choice_numeric[i, :n] = torch.tensor(
            [_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in ex.candidate_choices],
            dtype=torch.float32,
            device=device,
        )
        choice_cards[i, :n] = torch.tensor([a.card_id for a in ex.candidate_choices], dtype=torch.long, device=device)
        choice_mask[i, :n] = True

    if hasattr(model, "score_choices"):
        logits = model.score_choices(state_numeric, state_cards, choice_numeric, choice_cards, choice_mask)
    else:
        logits, _ = model(state_numeric, state_cards, choice_numeric, choice_cards, choice_mask)
    return logits, choice_mask


def _value_target_for(ex: TrainingExample) -> float:
    if ex.source == "self_play":
        return float(ex.return_target)
    return float(ex.value_target)


def _advantage_for(ex: TrainingExample) -> float | None:
    if ex.advantage is not None:
        return float(ex.advantage)
    if ex.policy_advantage is not None:
        return float(ex.policy_advantage)
    return None


def _normalize_advantages(examples: list[TrainingExample]) -> None:
    values = [_advantage_for(ex) for ex in examples if ex.source == "self_play" and _advantage_for(ex) is not None]
    values = [float(v) for v in values if v is not None]
    if not values:
        return
    mean = sum(values) / len(values)
    variance = sum((v - mean) ** 2 for v in values) / max(1, len(values))
    std = max(1e-6, variance ** 0.5)
    for ex in examples:
        if ex.source == "self_play" and _advantage_for(ex) is not None:
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
    optimizer = torch.optim.Adam(model.parameters(), lr=learning_rate)
    bs = max(1, int(batch_size))
    total_steps = max(1, int(epochs)) * max(1, (len(examples) + bs - 1) // bs)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=total_steps, eta_min=learning_rate * 0.1,
    )
    total_loss = 0.0
    total_policy_loss = 0.0
    total_value_loss = 0.0
    total_entropy = 0.0
    steps = 0

    for _ in range(max(1, int(epochs))):
        random.shuffle(examples)
        for batch_start in range(0, len(examples), bs):
            batch = examples[batch_start:batch_start + bs]
            logits, value, action_mask = _forward_batch(model, batch, device)
            if logits is None:
                continue

            B = len(batch)
            sp_indices = [i for i, ex in enumerate(batch) if ex.source == "self_play"]

            # Vectorized: compute log_softmax/softmax once for all examples
            # Masked (invalid) positions have logit=-1e9, so softmax≈0, log_softmax≈-1e9
            log_probs = F.log_softmax(logits, dim=-1)  # [B, max_actions]
            probs = torch.softmax(logits, dim=-1)

            # Per-example entropy (padded positions contribute ~0)
            entropy_per_ex = -(probs * log_probs).sum(dim=-1)

            # Build validity mask
            action_counts = action_mask.sum(dim=-1)
            target_idx = torch.tensor(
                [max(0, ex.target_index) for ex in batch], dtype=torch.long, device=device,
            )
            valid = action_counts > 0
            for i, ex in enumerate(batch):
                if not ex.actions or ex.target_index >= int(action_counts[i].item()):
                    valid[i] = False

            # Gather selected log probs
            selected_lp = log_probs[torch.arange(B, device=device), target_idx]

            # Mask tensors for loss type routing
            is_rl = torch.tensor([ex.source == "self_play" for ex in batch], device=device)
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

            loss_per_ex = torch.zeros(B, device=device)

            # PPO clipped loss: self_play + advantage + old log prob
            ppo = valid & is_rl & has_adv & has_old_lp
            if ppo.any():
                ratio = torch.exp(selected_lp - old_lp)
                clipped_ratio = torch.clamp(ratio, 1.0 - ppo_clip, 1.0 + ppo_clip)
                ppo_loss = -torch.minimum(ratio * advs, clipped_ratio * advs)
                loss_per_ex = loss_per_ex + ppo_loss * ppo.float()

            # Simple policy gradient: self_play + advantage, no old log prob
            pg = valid & is_rl & has_adv & ~has_old_lp
            if pg.any():
                loss_per_ex = loss_per_ex + (-selected_lp * advs) * pg.float()

            # Supervised (cross-entropy): teacher/dagger examples
            sl = valid & ~is_rl
            if sl.any():
                loss_per_ex = loss_per_ex + (-selected_lp) * sl.float()

            divisor = max(1, int(valid.sum().item()))
            policy_loss = loss_per_ex.sum() / divisor
            entropy = (entropy_per_ex * valid.float()).sum() / divisor
            if sp_indices:
                sp_value = value[sp_indices]
                sp_targets = torch.tensor([float(ex.value_target) for i, ex in enumerate(batch) if i in sp_indices], dtype=torch.float32, device=device)
                value_loss = F.mse_loss(sp_value, sp_targets)
            else:
                value_loss = torch.tensor(0.0, device=device)
            loss = policy_loss + 0.5 * value_loss - entropy_coef * entropy

            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
            optimizer.step()
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
) -> dict[str, Any]:
    if not bool(getattr(model, "choice_head_enabled", True)):
        return {"choice_examples": 0, "choice_loss": 0.0}
    if not examples:
        return {"choice_examples": 0, "choice_loss": 0.0}
    assert torch is not None
    import torch.nn.functional as F

    model.train()
    optimizer = torch.optim.Adam(model.parameters(), lr=learning_rate)
    bs = max(1, int(batch_size))
    total_steps = max(1, int(epochs)) * max(1, (len(examples) + bs - 1) // bs)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=total_steps, eta_min=learning_rate * 0.1,
    )
    total_loss = 0.0
    steps = 0
    for _ in range(max(1, int(epochs))):
        random.shuffle(examples)
        for batch_start in range(0, len(examples), bs):
            batch = examples[batch_start:batch_start + bs]
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
                    logits[i, :choice_count].unsqueeze(0),
                    torch.tensor([target_index], device=device),
                )
            if valid_examples <= 0:
                continue
            loss = loss_total / valid_examples
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
            optimizer.step()
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
            target_index = int(torch.argmax(logits[0]).item())
            probs = torch.softmax(logits[0], dim=0)
        else:
            scaled_logits = logits[0] / max(0.05, temperature)
            probs = torch.softmax(scaled_logits, dim=0)
            target_index = int(torch.multinomial(probs, 1).item())
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
    for idx, gae_adv in zip(sp_indices, gae_advantages):
        ex = examples[idx]
        ex.advantage = gae_adv
        ex.policy_advantage = gae_adv
        ex.value_target = gae_adv + float(ex.value_target)
        ex.return_target = ex.value_target
    return examples


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
) -> tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample]]:
    encoder = ActionStateEncoder()
    opponent_key = _opponent_for(deck_key, seed)
    seat = seed % 2
    state, _, ais, target_player_idx, rng_state = _setup_match(
        deck_key, opponent_key, seed, seat, teacher_search_preset
    )
    # Replace opponent AI with model-based actor when self-play is requested
    opponent_idx = 1 - target_player_idx
    if opponent_model is not None:
        ais[opponent_idx] = _ModelOpponentActor(opponent_model, ais[opponent_idx], device, deck_key)
    examples: list[TrainingExample] = []
    choice_examples: list[ChoiceTrainingExample] = []
    target_ai = ais[target_player_idx]
    original_choice_resolver = None

    # Set up MCTS searcher if enabled
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
            if state.winner is not None or state.phase == TurnPhase.GAME_OVER:
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

                # Action selection: MCTS or direct model
                if mcts_searcher is not None:
                    action = mcts_searcher.select_action(
                        state, player_idx, deck_key,
                        deterministic=(temperature <= 0.05),
                    )
                    # Create a self-play example from MCTS result
                    actions = target_ai.legal_actions(state, player_idx)
                    encoded_state = encoder.encode_state(state, player_idx, deck_key)
                    encoded_actions = [encoder.encode_action(state, player_idx, a) for a in actions]
                    action_idx = _find_action_index(actions, action)
                    if action_idx is not None:
                        with torch.no_grad():
                            logits, value = _forward_example(model, TrainingExample(encoded_state, encoded_actions, 0, source="self_play"), device)
                            predicted_value = float(value[0].detach().cpu().item())
                        example = TrainingExample(
                            encoded_state, encoded_actions, action_idx,
                            source="self_play",
                            value_target=predicted_value,
                            phase_tag=phase_tag,
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

            result = ai._apply_action_for_sim(state, player_idx, action)
            signature = _action_signature(action)
            invalid = result is None or not result.success
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

        if state.winner is not None:
            logical_winner = 0 if state.winner == target_player_idx else 1
            score = terminal_training_score(state, target_player_idx)
        else:
            soft_winner = _determine_soft_winner(state)
            state.winner = soft_winner
            logical_winner = 0 if soft_winner == target_player_idx else 1
            score = terminal_training_score(state, target_player_idx)
        _finalize_episode_examples(examples, _terminal_reward(logical_winner, score))
        return logical_winner, score, examples, choice_examples
    finally:
        if original_choice_resolver is not None:
            target_ai._resolve_pending_for_sim = original_choice_resolver
        _restore_rng(rng_state)


def _execute_model_game_task(task: ModelGameTask) -> tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample]]:
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
    )


def _run_model_game_tasks(
    tasks: list[ModelGameTask],
    workers: int | None,
) -> list[tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample]]]:
    worker_count = _normalized_workers(workers)
    if worker_count <= 1 or len(tasks) <= 1:
        return [_execute_model_game_task(task) for task in tasks]
    try:
        with ProcessPoolExecutor(max_workers=worker_count, initializer=_worker_init) as executor:
            return list(executor.map(_execute_model_game_task, tasks))
    except BrokenProcessPool:
        return [_execute_model_game_task(task) for task in tasks]


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
            temperature,
            teacher_label_model_states,
            phase_tag,
            opponent_model_state=opp_state,
            opponent_model_config=opp_config,
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
) -> dict[str, Any]:
    stats = {"wins": 0, "losses": 0, "draws": 0, "avg_score": 0.0, "games": max(0, int(games))}
    if games <= 0:
        return stats
    score_total = 0.0
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
            )
            for game_seed in seeds
        ]
    else:
        rows = _run_model_game_tasks(
            _model_game_tasks(
                model,
                deck_key,
                seeds,
                max_steps=max_steps,
                record=False,
                teacher_search_preset=teacher_search_preset,
                temperature=0.0,
                teacher_label_model_states=False,
                phase_tag="eval",
            ),
            workers,
        )
    for winner, score, _, _ in rows:
        score_total += score
        if winner == 0:
            stats["wins"] += 1
        elif winner == 1:
            stats["losses"] += 1
        else:
            stats["draws"] += 1
    stats["avg_score"] = round(score_total / max(1, games), 3)
    return stats


def _load_or_create_model(config: DeepTrainingConfig):
    assert torch is not None
    if config.model and os.path.exists(config.model):
        model, payload = load_checkpoint(config.model, config.device)
        if int(payload.get("version") or 0) >= 3:
            return model
    model = create_model(choice_head_enabled=bool(config.choice_head_enabled))
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
    return wins - losses, wins + draws * 0.25


def _point_rate(result: dict[str, Any] | None) -> float:
    if not result:
        return 0.0
    games = max(1, int(result.get("games") or 0))
    _, points = _score_points(result)
    return float(points) / games


def _evaluation_delta(eval_result: dict[str, Any], baseline: dict[str, Any] | None) -> dict[str, Any]:
    if not baseline or int(baseline.get("games") or 0) <= 0:
        return {"delta_wins": None, "delta_point_rate": None, "delta_avg_score": None}
    return {
        "delta_wins": int(eval_result.get("wins", 0)) - int(baseline.get("wins", 0)),
        "delta_point_rate": round(_point_rate(eval_result) - _point_rate(baseline), 4),
        "delta_avg_score": round(float(eval_result.get("avg_score", 0.0)) - float(baseline.get("avg_score", 0.0)), 3),
    }


def _accepts_candidate(
    eval_result: dict[str, Any],
    baseline_eval: dict[str, Any] | None,
    old_eval: dict[str, Any] | None,
    *,
    acceptance_metric: str = "wins",
    min_win_delta: int = 1,
) -> bool:
    if int(eval_result.get("games") or 0) <= 0:
        return True
    metric = acceptance_metric if acceptance_metric in ("wins", "points", "score") else "wins"
    if metric == "wins":
        required_delta = max(0, int(min_win_delta))
        candidate_wins = int(eval_result.get("wins", 0))
        for baseline in (baseline_eval, old_eval):
            if not baseline or int(baseline.get("games") or 0) <= 0:
                continue
            if candidate_wins < int(baseline.get("wins", 0)) + required_delta:
                return False
        return True
    if metric == "score":
        candidate_score = float(eval_result.get("avg_score", 0.0))
        for baseline in (baseline_eval, old_eval):
            if not baseline or int(baseline.get("games") or 0) <= 0:
                continue
            if candidate_score <= float(baseline.get("avg_score", 0.0)):
                return False
        return True

    candidate_points, candidate_rate = _score_points(eval_result)
    for baseline in (baseline_eval, old_eval):
        if not baseline or int(baseline.get("games") or 0) <= 0:
            continue
        baseline_points, baseline_rate = _score_points(baseline)
        if candidate_points < baseline_points:
            return False
        if candidate_points == baseline_points:
            if candidate_rate < baseline_rate:
                return False
            if float(eval_result.get("avg_score", 0.0)) < float(baseline.get("avg_score", 0.0)) - 25.0:
                return False
    return True


def _sample_teacher_examples(bootstrap: list[TrainingExample], target_size: int, rng: random.Random) -> list[TrainingExample]:
    if not bootstrap or target_size <= 0:
        return []
    if len(bootstrap) <= target_size:
        return list(bootstrap)
    return rng.sample(bootstrap, target_size)


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
) -> list[tuple[int | None, float, list[TrainingExample], list[ChoiceTrainingExample]]]:
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
            ))
        return results
    return _run_model_game_tasks(
        _model_game_tasks(
            model,
            deck_key,
            seeds,
            max_steps=max_steps,
            record=True,
            teacher_search_preset=teacher_search_preset,
            teacher_label_model_states=teacher_label_model_states,
            phase_tag=phase_tag,
            opponent_pool=opponent_pool,
        ),
        workers,
    )


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
        "choice_head_enabled": bool(config.choice_head_enabled),
        "acceptance_metric": acceptance_metric,
        "min_win_delta": min_win_delta,
        "teacher_label_model_states": bool(config.teacher_label_model_states),
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    rng = random.Random(deck_seed)

    bootstrap = _collect_bootstrap_examples_parallel(
        deck_key,
        bootstrap_games,
        deck_seed,
        max_steps=max_steps,
        workers=worker_count,
        teacher_search_preset=teacher_search_preset,
    )
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
    )
    emit({
        "type": "train_phase_finished",
        "deck": deck_key,
        "phase": "bootstrap",
        **bootstrap_result,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    baseline_eval = None
    if eval_games > 0 and (dagger_games > 0 or self_play_games > 0):
        baseline_eval = evaluate_model(
            model,
            deck_key,
            eval_seed,
            eval_games,
            device=config.device,
            max_steps=max_steps,
            workers=worker_count,
            teacher_search_preset=teacher_search_preset,
        )
        emit({
            "type": "baseline_eval_finished",
            "deck": deck_key,
            "eval": baseline_eval,
            "win_rate": round(float(baseline_eval.get("wins", 0)) / max(1, eval_games), 4),
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
        )
        dagger_examples: list[TrainingExample] = []
        choice_batch_examples: list[ChoiceTrainingExample] = []
        for row_idx, (winner, score, examples, choices) in enumerate(rows):
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
        train_rows = list(teacher_mix) + dagger_examples
        train_result = _train_examples(
            model,
            train_rows,
            device=config.device,
            learning_rate=config.learning_rate * 0.6,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
            entropy_coef=0.005,
        )
        choice_result = _train_choice_examples(
            model,
            choice_batch_examples,
            device=config.device,
            learning_rate=config.learning_rate * 0.6,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
        )
        dagger_train_results.append(train_result)
        dagger_choice_results.append(choice_result)
        emit({
            "type": "train_phase_finished",
            "deck": deck_key,
            "phase": "dagger_batch",
            "batch": (batch_start // rollout_batch_games) + 1,
            **train_result,
            **choice_result,
            "dagger_examples": len(dagger_examples),
            "teacher_examples": len(teacher_mix),
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
        )
        batch_examples: list[TrainingExample] = []
        batch_dagger_examples: list[TrainingExample] = []
        choice_batch_examples: list[ChoiceTrainingExample] = []
        for row_idx, (winner, score, examples, choices) in enumerate(rows):
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
        train_rows = list(teacher_mix) + batch_dagger_examples + batch_examples
        train_result = _train_examples(
            model,
            train_rows,
            device=config.device,
            learning_rate=config.learning_rate * 0.35,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
        )
        choice_result = _train_choice_examples(
            model,
            choice_batch_examples,
            device=config.device,
            learning_rate=config.learning_rate * 0.35,
            epochs=updates_per_rollout,
            batch_size=config.batch_size,
        )
        self_play_train_results.append(train_result)
        self_play_choice_results.append(choice_result)

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
        trajectories_per_game = 3
        for game_idx in range(same_deal_games):
            if config.use_mcts_training and model is not None:
                base_seed = deck_seed + 700_000 + game_idx * 113
                # Play 3 trajectories on the same seed with different temperatures
                for traj_idx, temp in enumerate([0.0, 0.5, 0.9]):
                    mcts_sims = int(config.mcts_simulations)
                    winner, score, game_examples, _ = _play_model_game(
                        model, deck_key, base_seed,
                        device=config.device, max_steps=max_steps, record=True,
                        teacher_search_preset=teacher_search_preset,
                        temperature=temp,
                        teacher_label_model_states=False,
                        phase_tag="same_deal",
                        use_mcts=True, mcts_simulations=mcts_sims,
                        mcts_chance_nodes=bool(config.mcts_chance_nodes),
                        pure_rl=True,
                    )
                    # Mark self-play examples
                    sp_examples = [ex for ex in game_examples if ex.source == "self_play"]
                    for ex in sp_examples:
                        ex.phase_tag = "same_deal"
                    same_deal_examples.extend(sp_examples)
                    total_done += 1
            emit({
                "type": "same_deal_game_finished",
                "deck": deck_key,
                "game": game_idx + 1,
                "target_games": same_deal_games,
                "total_games_played": total_done,
                "total_training_games": total_training_games,
            })
        emit({
            "type": "phase_finished",
            "deck": deck_key,
            "phase": "same_deal_replay",
            "examples": len(same_deal_examples),
            "total_games_played": total_done,
        })

    # ------------------------------------------------------------------
    # Phase 6 [NEW]: Pure RL exploration — no teacher, MCTS + curiosity
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

            for row_idx, game_seed in enumerate(seeds):
                mcts_sims = int(config.mcts_simulations) if use_mcts_training else 0
                winner, score, game_examples, game_choices = _play_model_game(
                    model, deck_key, game_seed,
                    device=config.device, max_steps=max_steps, record=True,
                    teacher_search_preset=teacher_search_preset,
                    temperature=0.7,
                    teacher_label_model_states=False,
                    phase_tag="pure_rl",
                    pure_rl=True,
                    use_mcts=use_mcts_training and mcts_sims > 0,
                    mcts_simulations=mcts_sims,
                    mcts_chance_nodes=bool(config.mcts_chance_nodes),
                    curiosity_tracker=curiosity_tracker,
                )
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
                train_result = _train_examples(
                    model, batch_examples,
                    device=config.device,
                    learning_rate=config.learning_rate * 0.25,
                    epochs=updates_per_rollout,
                    batch_size=config.batch_size,
                )
                self_play_train_results.append(train_result)
                emit({
                    "type": "train_phase_finished",
                    "deck": deck_key,
                    "phase": "pure_rl_batch",
                    "batch": (batch_start // rollout_batch_games) + 1,
                    **train_result,
                    "examples": len(batch_examples),
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
        })

    dagger_result = _aggregate_train_results(dagger_train_results, total_dagger_examples)
    choice_result = _aggregate_choice_results(dagger_choice_results + self_play_choice_results, total_choice_examples)
    self_play_result = _aggregate_train_results(self_play_train_results, total_self_play_examples)

    eval_result = evaluate_model(
        model,
        deck_key,
        eval_seed,
        eval_games,
        device=config.device,
        max_steps=max_steps,
        workers=worker_count,
        teacher_search_preset=teacher_search_preset,
    )
    total_done += eval_games
    eval_win_rate = 0.0
    if eval_games > 0:
        eval_win_rate = round(float(eval_result.get("wins", 0)) / max(1, eval_games), 4)
    baseline_delta = _evaluation_delta(eval_result, baseline_eval)
    old_delta = _evaluation_delta(eval_result, old_eval)
    accepted = _accepts_candidate(
        eval_result,
        baseline_eval,
        old_eval,
        acceptance_metric=acceptance_metric,
        min_win_delta=min_win_delta,
    )
    emit({
        "type": "eval_finished",
        "deck": deck_key,
        "eval": eval_result,
        "baseline_eval": baseline_eval,
        "old_eval": old_eval,
        "accepted": accepted,
        "acceptance_metric": acceptance_metric,
        "min_win_delta": min_win_delta,
        **baseline_delta,
        "old_delta_wins": old_delta.get("delta_wins"),
        "old_delta_point_rate": old_delta.get("delta_point_rate"),
        "old_delta_avg_score": old_delta.get("delta_avg_score"),
        "win_rate": eval_win_rate,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    stats = {"wins": wins, "losses": losses, "draws": draws}
    summary = {
        "bootstrap": bootstrap_result,
        "baseline_eval": baseline_eval or {"games": 0},
        "dagger": dagger_result,
        "choice": choice_result,
        "self_play": self_play_result,
        "dagger_stats": {"wins": dagger_wins, "losses": dagger_losses, "draws": dagger_draws},
        "self_play_stats": stats,
        "eval": eval_result,
        "eval_seed": eval_seed,
        "old_eval": old_eval or {"games": 0},
        "accepted": accepted,
        "acceptance_metric": acceptance_metric,
        "min_win_delta": min_win_delta,
        **baseline_delta,
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
        "accepted": accepted,
        "acceptance_metric": acceptance_metric,
        "delta_wins": baseline_delta.get("delta_wins"),
        "delta_point_rate": baseline_delta.get("delta_point_rate"),
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
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
) -> dict[str, Any] | None:
    if eval_games <= 0 or not output_path or not os.path.exists(output_path):
        return None
    try:
        old_model, _ = load_checkpoint(output_path, device)
    except Exception:
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
    )


def run_deep_training(
    config: DeepTrainingConfig,
    progress_callback: ProgressCallback | None = None,
) -> dict[str, Any]:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for deep-learning AI training.")
    _ensure_cards_loaded()
    assert torch is not None

    device_info = _torch_device_info(config.device)
    effective_config = replace(config, device=str(device_info["device"]))
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
    started = time.time()
    train_summary: dict[str, Any] = {}
    bootstrap_games = max(0, int(effective_config.bootstrap_games))
    dagger_games = max(0, int(effective_config.dagger_games))
    self_play_games = max(0, int(effective_config.games))
    eval_games = max(0, int(effective_config.eval_games))
    total_training_games = (bootstrap_games + dagger_games + self_play_games + eval_games) * len(deck_keys)
    total_done = 0
    model_paths: dict[str, str] = {}
    requested_model_paths: dict[str, str] = {}
    accepted: dict[str, bool] = {}

    try:
        emit({
            "type": "run_started",
            "trainer": "rl_ai",
            "deck": effective_config.deck,
            "deck_keys": deck_keys,
            "games_per_deck": self_play_games,
            "bootstrap_games": bootstrap_games,
            "dagger_games": dagger_games,
            "eval_games": eval_games,
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
            "teacher_search_preset": effective_config.teacher_search_preset,
            "choice_head_enabled": bool(effective_config.choice_head_enabled),
            "acceptance_metric": effective_config.acceptance_metric,
            "min_win_delta": int(effective_config.min_win_delta),
            "teacher_label_model_states": bool(effective_config.teacher_label_model_states),
            "total_training_games": total_training_games,
        })

        for offset, deck_key in enumerate(deck_keys):
            deck_seed = effective_config.seed + offset * 1009
            output_path = _candidate_output_path(effective_config, deck_key, len(deck_keys) > 1)
            old_model_path = effective_config.model or _output_path_for_deck(deck_key)
            requested_model_paths[deck_key] = output_path
            old_eval = _load_old_eval(
                old_model_path,
                deck_key,
                deck_seed + 900_000,
                eval_games,
                device=effective_config.device,
                max_steps=max(20, int(effective_config.max_steps)),
                workers=_normalized_workers(effective_config.workers),
                teacher_search_preset=effective_config.teacher_search_preset,
            )

            model = _load_or_create_model(effective_config)
            model.to(effective_config.device)

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
            train_summary[deck_key] = deck_summary
            deck_accepted = bool(deck_summary.get("accepted", True))
            accepted[deck_key] = deck_accepted

            save_path = output_path
            preserved_existing = os.path.exists(output_path)
            if not deck_accepted:
                save_path = _rejected_output_path(output_path)

            metadata = {
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "deck": deck_key,
                "games": self_play_games,
                "bootstrap_games": bootstrap_games,
                "dagger_games": dagger_games,
                "eval_games": eval_games,
                "workers": int(effective_config.workers),
                "requested_device": device_info["requested_device"],
                "device": effective_config.device,
                "torch_version": device_info["torch_version"],
                "torch_cuda": device_info["torch_cuda"],
                "cuda_available": device_info["cuda_available"],
                "gpu_name": device_info["gpu_name"],
                "trainer": "teacher_dagger_rl_v3",
                "accepted": deck_accepted,
                "preserved_existing": preserved_existing,
                "requested_output_path": output_path,
                "summary": {deck_key: deck_summary},
                "rollout_batch_games": effective_config.rollout_batch_games,
                "updates_per_rollout": effective_config.updates_per_rollout,
                "teacher_search_preset": effective_config.teacher_search_preset,
                "choice_head_enabled": bool(effective_config.choice_head_enabled),
                "acceptance_metric": effective_config.acceptance_metric,
                "min_win_delta": int(effective_config.min_win_delta),
                "teacher_label_model_states": bool(effective_config.teacher_label_model_states),
            }
            save_checkpoint(save_path, model, metadata)
            model_paths[deck_key] = save_path
            sidecar = os.path.splitext(save_path)[0] + ".json"
            with open(sidecar, "w", encoding="utf-8") as fh:
                json.dump({"model_path": save_path, "metadata": metadata},
                          fh, ensure_ascii=False, indent=2, sort_keys=True)

        payload = {
            "model_paths": model_paths,
            "model_path": next(iter(model_paths.values())) if len(model_paths) == 1 else None,
            "requested_model_paths": requested_model_paths,
            "accepted": accepted,
            "metadata": {
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "deck": effective_config.deck,
                "deck_keys": deck_keys,
                "games": self_play_games,
                "bootstrap_games": bootstrap_games,
                "dagger_games": dagger_games,
                "eval_games": eval_games,
                "workers": int(effective_config.workers),
                "requested_device": device_info["requested_device"],
                "device": effective_config.device,
                "torch_version": device_info["torch_version"],
                "torch_cuda": device_info["torch_cuda"],
                "cuda_available": device_info["cuda_available"],
                "gpu_name": device_info["gpu_name"],
                "trainer": "teacher_dagger_rl_v3",
                "summary": train_summary,
                "rollout_batch_games": effective_config.rollout_batch_games,
                "updates_per_rollout": effective_config.updates_per_rollout,
                "teacher_search_preset": effective_config.teacher_search_preset,
                "choice_head_enabled": bool(effective_config.choice_head_enabled),
                "acceptance_metric": effective_config.acceptance_metric,
                "min_win_delta": int(effective_config.min_win_delta),
                "teacher_label_model_states": bool(effective_config.teacher_label_model_states),
            },
        }
        emit({
            "type": "run_finished",
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

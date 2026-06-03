"""Offline self-play training helpers for challenge-mode AI policies."""
from __future__ import annotations

import json
import os
import random
import time
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool
from dataclasses import dataclass
from typing import Any, Callable

from data.card_registry import CardRegistry
from data.deck_definitions import (
    ALL_CARD_IDS,
    COLORLESS_DECK,
    DRAGON_DECK,
    FIGHTING_DECK,
    FIRE_DECK,
    GRASS_DECK,
    LIGHTNING_DECK,
    PSYCHIC_DECK_NATU,
    WATER_DECK,
    expand_deck,
)
from engine.ai.challenge_ai import AIConfig, create_challenge_ai
from engine.ai.profiles import (
    DEFAULT_POLICY_PATH,
    DECK_AI_PROFILES,
    POLICY_VERSION,
    load_policy_weights,
    merged_profile_weights,
)
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from engine.turn_manager import TurnManager


DECK_SPECS = {
    "fire": FIRE_DECK,
    "water": WATER_DECK,
    "psychic": PSYCHIC_DECK_NATU,
    "lightning": LIGHTNING_DECK,
    "fighting": FIGHTING_DECK,
    "colorless": COLORLESS_DECK,
    "dragon": DRAGON_DECK,
    "grass": GRASS_DECK,
}

TRAINABLE_KEYS = [
    "core_in_play",
    "core_in_hand",
    "engine_in_play",
    "engine_in_hand",
    "preferred_bench",
    "evolved_count",
    "matching_energy_attached",
    "matching_energy_hand",
    "trainer_in_hand",
    "damaged_self",
    "low_hp_targets",
    "ko_pressure",
    "hand_size",
    "bench_count",
]

DEFAULT_CANDIDATE_OUTPUT = os.path.join("data", "ai_policies_candidate.json")


def _default_worker_count() -> int:
    cpu_count = os.cpu_count() or 1
    return min(8, max(1, cpu_count - 1))


DEFAULT_WORKERS = _default_worker_count()

# Training is intentionally quality-biased.  It uses deterministic search so
# candidate comparisons are reproducible, but keeps the tactical budget close
# to challenge-mode play instead of using a tiny speed-only search.
TRAINING_AI_SEARCH = {
    "thinking_time_seconds": 0.0,
    "beam_width": 10,
    "max_sequence_depth": 5,
    "max_turn_actions": 24,
    "coin_sample_count": 4,
    "chance_branch_limit": 4,
    "opponent_response_actions": 8,
    "response_branch_limit": 4,
    "opponent_response_weight": 0.55,
    "deterministic_search": True,
    "search_algorithm": "beam",
    "skip_effect_dry_run": True,
}

TRAINING_AI_SEARCH_MINIMAX = {
    "thinking_time_seconds": 0.0,
    "beam_width": 8,
    "max_sequence_depth": 4,
    "max_turn_actions": 24,
    "coin_sample_count": 4,
    "chance_branch_limit": 3,
    "opponent_response_actions": 6,
    "response_branch_limit": 3,
    "opponent_response_weight": 0.45,
    "deterministic_search": True,
    "search_algorithm": "minimax",
    "minimax_max_depth": 2,
    "minimax_determinizations": 2,
    "search_node_budget": 1200,
    "skip_effect_dry_run": True,
}

TRAINING_AI_SEARCH_HYBRID = dict(
    TRAINING_AI_SEARCH_MINIMAX,
    search_algorithm="hybrid",
)

SEARCH_PRESETS = {
    "beam": TRAINING_AI_SEARCH,
    "hybrid": TRAINING_AI_SEARCH_HYBRID,
    "minimax": TRAINING_AI_SEARCH_MINIMAX,
}

FAST_SEARCH_PRESETS = {
    "beam": dict(
        TRAINING_AI_SEARCH,
        beam_width=8,
        max_sequence_depth=4,
        response_branch_limit=2,
        opponent_response_weight=0.35,
    ),
    "hybrid": dict(
        TRAINING_AI_SEARCH_HYBRID,
        beam_width=5,
        max_turn_actions=16,
        minimax_determinizations=1,
        search_node_budget=450,
        chance_branch_limit=2,
        response_branch_limit=2,
        opponent_response_weight=0.30,
    ),
    "minimax": dict(
        TRAINING_AI_SEARCH_MINIMAX,
        max_turn_actions=16,
        minimax_determinizations=1,
        search_node_budget=450,
        chance_branch_limit=2,
        response_branch_limit=2,
        opponent_response_weight=0.30,
    ),
}

WEIGHT_BOUNDS: dict[str, tuple[float, float]] = {
    "core_in_play": (20.0, 120.0),
    "core_in_hand": (-5.0, 55.0),
    "engine_in_play": (0.0, 90.0),
    "engine_in_hand": (-5.0, 45.0),
    "preferred_bench": (-5.0, 45.0),
    "evolved_count": (0.0, 95.0),
    "matching_energy_attached": (-5.0, 45.0),
    "matching_energy_hand": (-8.0, 32.0),
    "trainer_in_hand": (-8.0, 38.0),
    "damaged_self": (-1.5, 0.0),
    "low_hp_targets": (0.0, 80.0),
    "ko_pressure": (0.1, 3.0),
    "hand_size": (-8.0, 18.0),
    "bench_count": (-5.0, 36.0),
}

MUTATION_BASE_SCALE: dict[str, float] = {
    "core_in_play": 7.0,
    "core_in_hand": 4.0,
    "engine_in_play": 6.0,
    "engine_in_hand": 4.0,
    "preferred_bench": 4.0,
    "evolved_count": 6.0,
    "matching_energy_attached": 4.0,
    "matching_energy_hand": 3.0,
    "trainer_in_hand": 3.5,
    "damaged_self": 0.10,
    "low_hp_targets": 5.0,
    "ko_pressure": 0.18,
    "hand_size": 1.8,
    "bench_count": 3.0,
}

ProgressCallback = Callable[[dict[str, Any]], None]


@dataclass(frozen=True)
class TrainingConfig:
    deck: str = "all"
    games: int = 200
    seed: int = 17
    output: str = DEFAULT_CANDIDATE_OUTPUT
    eval_games: int = 20
    progress_jsonl: str | None = None
    workers: int = DEFAULT_WORKERS
    benchmark_games: int = 0
    search_preset: str = "hybrid"  # "hybrid", "beam", or "minimax"


@dataclass(frozen=True)
class PlayGameTask:
    deck_key: str
    weights: dict[str, float] | None
    opponent_key: str
    seed: int
    seat: int
    max_steps: int = 160
    search_preset: str = "hybrid"
    search_quality: str = "standard"


@dataclass(frozen=True)
class PlayMatchTask:
    deck_a: str
    weights_a: dict[str, float] | None
    deck_b: str
    weights_b: dict[str, float] | None
    seed: int
    seat: int
    max_steps: int = 160
    search_preset: str = "hybrid"
    search_quality: str = "standard"


def clamp_weight(key: str, value: float) -> float:
    """Clamp one trainable weight to its stable search range."""
    lower, upper = WEIGHT_BOUNDS.get(key, (-100.0, 140.0))
    return round(max(lower, min(upper, float(value))), 4)


def clamp_weights(weights: dict[str, float]) -> dict[str, float]:
    """Return a clamped copy containing all trainable keys."""
    return {key: clamp_weight(key, weights.get(key, 0.0)) for key in TRAINABLE_KEYS}


def _ensure_cards_loaded() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS, use_api=False)


def _worker_init() -> None:
    _ensure_cards_loaded()


def _normalized_workers(workers: int | None) -> int:
    if workers is None:
        return DEFAULT_WORKERS
    try:
        return max(1, int(workers))
    except (TypeError, ValueError):
        return DEFAULT_WORKERS


def _execute_play_game_task(task: PlayGameTask) -> tuple[int | None, float]:
    _ensure_cards_loaded()
    return play_game(
        task.deck_key,
        task.weights,
        task.opponent_key,
        task.seed,
        max_steps=task.max_steps,
        candidate_player_idx=task.seat,
        search_preset=task.search_preset,
        search_quality=task.search_quality,
    )


def _execute_play_match_task(task: PlayMatchTask) -> tuple[int | None, float]:
    _ensure_cards_loaded()
    return play_match(
        task.deck_a,
        task.weights_a,
        task.deck_b,
        task.weights_b,
        task.seed,
        seat=task.seat,
        max_steps=task.max_steps,
        search_preset=task.search_preset,
        search_quality=task.search_quality,
    )


class TrainingTaskRunner:
    """Reusable process-pool runner for a full training run."""

    def __init__(self, workers: int | None):
        self.worker_count = _normalized_workers(workers)
        self.executor: ProcessPoolExecutor | None = None
        self._broken = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.executor is not None:
            self.executor.shutdown(wait=True)
            self.executor = None
        return False

    def _ensure_executor(self, task_count: int) -> ProcessPoolExecutor | None:
        if self._broken or self.worker_count <= 1 or task_count <= 1:
            return None
        if self.executor is None:
            max_workers = max(1, min(self.worker_count, task_count))
            self.executor = ProcessPoolExecutor(max_workers=max_workers, initializer=_worker_init)
        return self.executor

    def run_play_game_tasks(self, tasks: list[PlayGameTask]) -> list[tuple[int | None, float]]:
        executor = self._ensure_executor(len(tasks))
        if executor is None:
            return [_execute_play_game_task(task) for task in tasks]
        try:
            return list(executor.map(_execute_play_game_task, tasks))
        except BrokenProcessPool:
            self._broken = True
            return [_execute_play_game_task(task) for task in tasks]

    def run_play_match_tasks(self, tasks: list[PlayMatchTask]) -> list[tuple[int | None, float]]:
        executor = self._ensure_executor(len(tasks))
        if executor is None:
            return [_execute_play_match_task(task) for task in tasks]
        try:
            return list(executor.map(_execute_play_match_task, tasks))
        except BrokenProcessPool:
            self._broken = True
            return [_execute_play_match_task(task) for task in tasks]


def _run_play_game_tasks(tasks: list[PlayGameTask], workers: int | None) -> list[tuple[int | None, float]]:
    worker_count = _normalized_workers(workers)
    with TrainingTaskRunner(min(worker_count, max(1, len(tasks)))) as runner:
        return runner.run_play_game_tasks(tasks)


def _run_play_match_tasks(tasks: list[PlayMatchTask], workers: int | None) -> list[tuple[int | None, float]]:
    worker_count = _normalized_workers(workers)
    with TrainingTaskRunner(min(worker_count, max(1, len(tasks)))) as runner:
        return runner.run_play_match_tasks(tasks)


def _make_ai(deck_key: str, weights: dict[str, float] | None, seed: int,
              search_preset: str = "hybrid", search_quality: str = "standard"):
    presets = FAST_SEARCH_PRESETS if search_quality == "fast" else SEARCH_PRESETS
    search_kwargs = presets.get(search_preset, TRAINING_AI_SEARCH_HYBRID)
    config = AIConfig(
        **search_kwargs,
        random_seed=seed,
        policy_path=None,
        policy_weights=weights,
    )
    return create_challenge_ai(deck_key, config)


def finish_setup(state: GameState, tm: TurnManager, ais: list[Any]) -> None:
    for player_idx, ai in enumerate(ais):
        for _ in range(10):
            if tm.needs_mulligan(player_idx):
                state.do_mulligan(player_idx)
            else:
                break
        for _ in range(8):
            action = ai.choose_action(state, player_idx)
            if action.action == "SETUP_DONE":
                break
            if action.action == PlayerAction.PLAY_BASIC:
                result = tm.setup_place_basic(player_idx, **action.params)
                if not result.success:
                    break
            else:
                break
    if state.p1.active is None:
        _force_setup_basic(tm, 0)
    if state.p2.active is None:
        _force_setup_basic(tm, 1)
    if state.p1.active is None or state.p2.active is None:
        raise RuntimeError(
            f"Setup failed: p1_active={state.p1.active is not None}, "
            f"p2_active={state.p2.active is not None}. "
            "Check deck definitions for basic Pokemon."
        )
    tm.setup_finalize()


def _force_setup_basic(tm: TurnManager, player_idx: int) -> None:
    player = tm.state.get_player(player_idx)
    for idx, card in enumerate(player.hand):
        if card.is_basic_pokemon:
            tm.setup_place_basic(player_idx, idx, "active")
            return


def force_end_turn(state: GameState, player_idx: int) -> None:
    if state.phase in (TurnPhase.MAIN, TurnPhase.ATTACK):
        TurnManager(state).perform_action(PlayerAction.END_TURN, player_idx=player_idx)


def play_game(
    deck_key: str,
    candidate_weights: dict[str, float] | None,
    opponent_key: str,
    seed: int,
    max_steps: int = 160,
    candidate_player_idx: int = 0,
    search_preset: str = "hybrid",
    search_quality: str = "standard",
) -> tuple[int | None, float]:
    return play_match(
        deck_key,
        candidate_weights,
        opponent_key,
        None,
        seed,
        seat=candidate_player_idx,
        max_steps=max_steps,
        search_preset=search_preset,
        search_quality=search_quality,
    )


def play_match(
    deck_a: str,
    weights_a: dict[str, float] | None,
    deck_b: str,
    weights_b: dict[str, float] | None,
    seed: int,
    *,
    seat: int = 0,
    max_steps: int = 160,
    search_preset: str = "hybrid",
    search_quality: str = "standard",
) -> tuple[int | None, float]:
    """Play two deck policies and score the result from deck_a's perspective."""
    rng_state = random.getstate()
    random.seed(seed)
    try:
        return _play_match_impl(
            deck_a,
            weights_a,
            deck_b,
            weights_b,
            seed,
            seat=seat,
            max_steps=max_steps,
            search_preset=search_preset,
            search_quality=search_quality,
        )
    finally:
        random.setstate(rng_state)


def _play_match_impl(
    deck_a: str,
    weights_a: dict[str, float] | None,
    deck_b: str,
    weights_b: dict[str, float] | None,
    seed: int,
    *,
    seat: int = 0,
    max_steps: int = 160,
    search_preset: str = "hybrid",
    search_quality: str = "standard",
) -> tuple[int | None, float]:
    deck_a_player_idx = 1 if seat == 1 else 0
    state = GameState()
    deck1_key = deck_a if deck_a_player_idx == 0 else deck_b
    deck2_key = deck_b if deck_a_player_idx == 0 else deck_a
    state.setup_game(expand_deck(DECK_SPECS[deck1_key]), expand_deck(DECK_SPECS[deck2_key]))
    tm = TurnManager(state)
    if deck_a_player_idx == 0:
        ai0 = _make_ai(deck_a, weights_a, seed + 11, search_preset, search_quality)
        ai1 = _make_ai(deck_b, weights_b, seed + 29, search_preset, search_quality)
    else:
        ai0 = _make_ai(deck_b, weights_b, seed + 29, search_preset, search_quality)
        ai1 = _make_ai(deck_a, weights_a, seed + 11, search_preset, search_quality)
    ais = [ai0, ai1]
    finish_setup(state, tm, ais)

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
        if state.phase not in (TurnPhase.MAIN, TurnPhase.ATTACK):
            TurnManager(state).advance_phase()
            continue

        player_idx = state.active_player_idx
        action = ais[player_idx].choose_action(state, player_idx)
        result = ais[player_idx]._apply_action_for_sim(state, player_idx, action)
        signature = (action.action, tuple(sorted(action.params.items())))
        if result is None or not result.success:
            failed_signatures[player_idx].add(signature)
            if len(failed_signatures[player_idx]) >= 3:
                force_end_turn(state, player_idx)
                failed_signatures[player_idx].clear()
        else:
            failed_signatures[player_idx].clear()

    deck_a_ai = ais[deck_a_player_idx]
    if state.winner is not None:
        logical_winner = 0 if state.winner == deck_a_player_idx else 1
        return logical_winner, terminal_training_score(state, deck_a_player_idx)
    return None, deck_a_ai.evaluate_state(state, deck_a_player_idx)


def terminal_training_score(state: GameState, candidate_player_idx: int) -> float:
    candidate = state.get_player(candidate_player_idx)
    opponent = state.get_player(1 - candidate_player_idx)
    candidate_won = state.winner == candidate_player_idx
    score = 1_000_000.0 if candidate_won else -1_000_000.0
    candidate_prizes_taken = 6 - len(candidate.prizes)
    opponent_prizes_taken = 6 - len(opponent.prizes)
    score += (candidate_prizes_taken - opponent_prizes_taken) * 2500.0
    score += (candidate.bench_count() - opponent.bench_count()) * 180.0
    score += (len(candidate.hand) - opponent.hand_count) * 70.0
    score += (len(candidate.deck) - len(opponent.deck)) * 18.0
    if candidate_won:
        score -= state.turn_number * 120.0
    else:
        score += state.turn_number * 60.0
    return score


def _stats() -> dict[str, int]:
    return {"wins": 0, "losses": 0, "draws": 0}


def _score_game(winner: int | None, eval_score: float) -> tuple[float, dict[str, int]]:
    local = _stats()
    score = float(eval_score)
    if winner == 0:
        local["wins"] = 1
        score += 10000.0
    elif winner == 1:
        local["losses"] = 1
        score -= 10000.0
    else:
        local["draws"] = 1
    return score, local


def _eval_accepts_trained(eval_info: dict[str, Any] | None) -> bool:
    if not eval_info or int(eval_info.get("games") or 0) <= 0:
        return True
    baseline = eval_info.get("baseline") or {}
    trained = eval_info.get("trained") or {}
    baseline_points = int(baseline.get("wins", 0)) - int(baseline.get("losses", 0))
    trained_points = int(trained.get("wins", 0)) - int(trained.get("losses", 0))
    baseline_score = float(baseline.get("avg_score", 0.0))
    trained_score = float(trained.get("avg_score", 0.0))
    return trained_points > baseline_points or (
        trained_points == baseline_points and trained_score > baseline_score + 25.0
    )


def _merge_stats(target: dict[str, Any], local: dict[str, int]) -> None:
    for key in ("wins", "losses", "draws"):
        target[key] += int(local.get(key, 0))


def _opponent_for(deck_key: str, game_idx: int, generation: int) -> str:
    opponents = [key for key in DECK_SPECS if key != deck_key]
    return opponents[(game_idx + generation) % len(opponents)]


def _mutate_weights(base: dict[str, float], rng: random.Random, generation: int) -> dict[str, float]:
    mutated = dict(base)
    cooling = max(0.28, 1.0 / ((generation + 1) ** 0.5))
    for key in TRAINABLE_KEYS:
        current = mutated.get(key, 0.0)
        scale = MUTATION_BASE_SCALE.get(key, 4.0) * cooling
        mutated[key] = clamp_weight(key, current + rng.gauss(0.0, scale))
    return mutated


def _average_weights(rows: list[tuple[float, dict[str, float], dict[str, int]]]) -> dict[str, float]:
    return {
        key: clamp_weight(key, sum(weights.get(key, 0.0) for _, weights, _ in rows) / len(rows))
        for key in TRAINABLE_KEYS
    }


def train_deck(
    deck_key: str,
    games: int,
    seed: int,
    *,
    eval_games: int = 0,
    workers: int = DEFAULT_WORKERS,
    progress_callback: ProgressCallback | None = None,
    total_offset: int = 0,
    total_training_games: int | None = None,
    search_preset: str = "hybrid",
    task_runner: TrainingTaskRunner | None = None,
) -> dict[str, Any]:
    """Train one deck for exactly ``games`` self-play candidate games."""
    if deck_key not in DECK_SPECS:
        raise ValueError(f"Unknown deck key: {deck_key}")

    target_games = max(1, int(games))
    rng = random.Random(seed)
    profile = DECK_AI_PROFILES[deck_key]
    base_weights = clamp_weights(merged_profile_weights(profile))
    population = max(1, min(10, target_games))
    games_played = 0
    generation = 0
    best_seen_weights = dict(base_weights)
    best_seen_score = float("-inf")
    current_center = dict(base_weights)
    stats = _stats()
    refinement_games = 0

    def run_game_tasks(tasks: list[PlayGameTask]) -> list[tuple[int | None, float]]:
        if task_runner is not None:
            return task_runner.run_play_game_tasks(tasks)
        return _run_play_game_tasks(tasks, workers)

    while games_played < target_games:
        generation += 1
        batch_start = games_played
        batch_size = min(population, target_games - games_played)
        candidates = [dict(best_seen_weights)]
        if batch_size > 1 and current_center != best_seen_weights:
            candidates.append(dict(current_center))
        while len(candidates) < batch_size:
            candidates.append(_mutate_weights(current_center, rng, generation))
        candidates = candidates[:batch_size]

        tasks: list[PlayGameTask] = []
        task_weights: list[dict[str, float]] = []
        for candidate_idx, weights in enumerate(candidates):
            game_idx = games_played + candidate_idx
            opponent_key = _opponent_for(deck_key, game_idx, generation)
            game_seed = seed + generation * 1009 + game_idx * 37 + candidate_idx
            seat = (generation + game_idx + candidate_idx) % 2
            tasks.append(PlayGameTask(deck_key, weights, opponent_key, game_seed, seat,
                                      search_preset=search_preset, search_quality="fast"))
            task_weights.append(weights)

        scored: list[tuple[float, dict[str, float], dict[str, int]]] = []
        for weights, (winner, eval_score) in zip(task_weights, run_game_tasks(tasks)):
            score, local = _score_game(winner, eval_score)
            scored.append((score, weights, local))
            _merge_stats(stats, local)
            games_played += 1

        scored.sort(key=lambda row: row[0], reverse=True)
        if search_preset in ("hybrid", "minimax") and len(scored) > 1:
            refine_count = max(1, min(len(scored), len(scored) // 3))
            refine_tasks: list[PlayGameTask] = []
            refine_rows = scored[:refine_count]
            for refine_idx, (_fast_score, weights, _local) in enumerate(refine_rows):
                refine_game_idx = batch_start + refine_idx
                opponent_key = _opponent_for(deck_key, refine_game_idx, generation + 97)
                game_seed = seed + 900_000 + generation * 1009 + refine_game_idx * 53 + refine_idx
                seat = (generation + refine_game_idx + refine_idx + 1) % 2
                refine_tasks.append(PlayGameTask(
                    deck_key,
                    weights,
                    opponent_key,
                    game_seed,
                    seat,
                    search_preset=search_preset,
                    search_quality="standard",
                ))
            refined: list[tuple[float, dict[str, float], dict[str, int]]] = []
            for row, (winner, eval_score) in zip(refine_rows, run_game_tasks(refine_tasks)):
                refine_score, _local = _score_game(winner, eval_score)
                combined_score = refine_score * 0.70 + row[0] * 0.30
                refined.append((combined_score, row[1], row[2]))
            refinement_games += len(refined)
            scored = refined + scored[refine_count:]
            scored.sort(key=lambda row: row[0], reverse=True)

        top_score, top_weights, _ = scored[0]
        if top_score > best_seen_score:
            best_seen_score = top_score
            best_seen_weights = dict(top_weights)

        elite_count = max(1, min(len(scored), max(1, len(scored) // 3)))
        current_center = _average_weights(scored[:elite_count])

        if progress_callback:
            progress_callback({
                "type": "generation_finished",
                "deck": deck_key,
                "generation": generation,
                "games_played": games_played,
                "target_games": target_games,
                "total_games_played": total_offset + games_played,
                "total_training_games": total_training_games or target_games,
                "stats": dict(stats),
                "win_rate": stats["wins"] / max(1, games_played),
                "best_score": round(float(best_seen_score), 3),
                "refinement_games": refinement_games,
            })

    trained_weights = clamp_weights(best_seen_weights)
    base_eval: dict[str, Any] | None = None
    if eval_games > 0:
        base_eval = evaluate_policy(
            deck_key,
            base_weights,
            trained_weights,
            seed + 500_000,
            eval_games,
            workers=workers,
            search_preset=search_preset,
            task_runner=task_runner,
        )
    accepted = _eval_accepts_trained(base_eval)

    return {
        "weights": trained_weights,
        "training_games": games_played,
        "stats": stats,
        "eval": base_eval or {"games": 0},
        "metadata": {
            "seed": seed,
            "best_score": round(float(best_seen_score), 3),
            "population": population,
            "generations": generation,
            "accepted": accepted,
            "refinement_games": refinement_games,
            "search": dict(SEARCH_PRESETS.get(search_preset, TRAINING_AI_SEARCH_HYBRID)),
            "fast_search": dict(FAST_SEARCH_PRESETS.get(search_preset, TRAINING_AI_SEARCH_HYBRID)),
            "workers": _normalized_workers(workers),
        },
    }


def evaluate_policy(
    deck_key: str,
    baseline_weights: dict[str, float],
    trained_weights: dict[str, float],
    seed: int,
    games: int,
    *,
    workers: int = DEFAULT_WORKERS,
    search_preset: str = "hybrid",
    task_runner: TrainingTaskRunner | None = None,
) -> dict[str, Any]:
    """Compare baseline and trained weights against the same holdout schedule."""
    target_games = max(0, int(games))
    result = {
        "games": target_games,
        "baseline": {"wins": 0, "losses": 0, "draws": 0, "avg_score": 0.0},
        "trained": {"wins": 0, "losses": 0, "draws": 0, "avg_score": 0.0},
    }
    if target_games <= 0:
        return result

    baseline_score = 0.0
    trained_score = 0.0
    baseline_tasks: list[PlayGameTask] = []
    trained_tasks: list[PlayGameTask] = []
    for idx in range(target_games):
        opponent_key = _opponent_for(deck_key, idx, 99)
        game_seed = seed + idx * 101
        seat = idx % 2
        baseline_tasks.append(PlayGameTask(deck_key, baseline_weights, opponent_key, game_seed, seat,
                                             search_preset=search_preset))
        trained_tasks.append(PlayGameTask(deck_key, trained_weights, opponent_key, game_seed, seat,
                                            search_preset=search_preset))

    run_game_tasks = (
        task_runner.run_play_game_tasks
        if task_runner is not None
        else lambda tasks: _run_play_game_tasks(tasks, workers)
    )

    for winner, eval_score in run_game_tasks(baseline_tasks):
        baseline_score += eval_score
        _, local = _score_game(winner, eval_score)
        _merge_stats(result["baseline"], local)

    for winner, eval_score in run_game_tasks(trained_tasks):
        trained_score += eval_score
        _, local = _score_game(winner, eval_score)
        _merge_stats(result["trained"], local)

    result["baseline"]["avg_score"] = round(baseline_score / target_games, 3)
    result["trained"]["avg_score"] = round(trained_score / target_games, 3)
    return result


def _policy_weights_for_benchmark(deck_key: str, policy: dict[str, Any]) -> dict[str, float]:
    weights = policy.get("weights") if isinstance(policy, dict) else {}
    return clamp_weights(weights or merged_profile_weights(DECK_AI_PROFILES[deck_key]))


def _official_or_profile_weights(deck_key: str) -> dict[str, float]:
    profile = DECK_AI_PROFILES[deck_key]
    return clamp_weights(merged_profile_weights(profile, load_policy_weights(deck_key, DEFAULT_POLICY_PATH)))


def _rate(stats: dict[str, Any], key: str = "wins") -> float:
    games = int(stats.get("games") or 0)
    if games <= 0:
        games = int(stats.get("wins", 0)) + int(stats.get("losses", 0)) + int(stats.get("draws", 0))
    if games <= 0:
        return 0.0
    if key == "points":
        points = int(stats.get("wins", 0)) + int(stats.get("draws", 0)) * 0.5
        return round(points / games, 4)
    return round(int(stats.get(key, 0)) / games, 4)


def _finalize_stats(stats: dict[str, Any], score_total: float = 0.0) -> dict[str, Any]:
    games = int(stats.get("wins", 0)) + int(stats.get("losses", 0)) + int(stats.get("draws", 0))
    result = {
        "wins": int(stats.get("wins", 0)),
        "losses": int(stats.get("losses", 0)),
        "draws": int(stats.get("draws", 0)),
        "games": games,
        "win_rate": 0.0,
        "point_rate": 0.0,
        "avg_score": 0.0,
    }
    if games > 0:
        result["win_rate"] = round(result["wins"] / games, 4)
        result["point_rate"] = round((result["wins"] + result["draws"] * 0.5) / games, 4)
        result["avg_score"] = round(score_total / games, 3)
    return result


def _before_after_benchmark(
    deck_keys: list[str],
    trained_weights: dict[str, dict[str, float]],
    seed: int,
    games_per_matchup: int,
    workers: int,
    search_preset: str = "hybrid",
    task_runner: TrainingTaskRunner | None = None,
) -> dict[str, Any]:
    before_after: dict[str, Any] = {}
    for idx, deck_key in enumerate(deck_keys):
        result = evaluate_policy(
            deck_key,
            _official_or_profile_weights(deck_key),
            trained_weights[deck_key],
            seed + idx * 3001,
            games_per_matchup,
            workers=workers,
            search_preset=search_preset,
            task_runner=task_runner,
        )
        before = dict(result.get("baseline") or {})
        after = dict(result.get("trained") or {})
        before["games"] = games_per_matchup
        after["games"] = games_per_matchup
        before.setdefault("win_rate", _rate(before))
        before.setdefault("point_rate", _rate(before, "points"))
        after.setdefault("win_rate", _rate(after))
        after.setdefault("point_rate", _rate(after, "points"))
        before_after[deck_key] = {
            "games": games_per_matchup,
            "before": before,
            "after": after,
            "delta_win_rate": round(float(after["win_rate"]) - float(before["win_rate"]), 4),
            "delta_point_rate": round(float(after["point_rate"]) - float(before["point_rate"]), 4),
        }
    return before_after


def benchmark_policies(
    policies: dict[str, Any],
    seed: int,
    games_per_matchup: int,
    *,
    workers: int = DEFAULT_WORKERS,
    progress_callback: ProgressCallback | None = None,
    search_preset: str = "hybrid",
    task_runner: TrainingTaskRunner | None = None,
) -> dict[str, Any]:
    """Run diagnostic policy benchmarks for UI visualization.

    These games are deliberately separate from training acceptance.  They never
    decide whether a candidate policy is accepted.
    """
    deck_keys = [key for key in policies if key in DECK_SPECS]
    target_games = max(0, int(games_per_matchup))
    worker_count = _normalized_workers(workers)
    benchmark: dict[str, Any] = {
        "games_per_matchup": target_games,
        "deck_keys": deck_keys,
        "before_after": {},
        "matrix": {},
        "rankings": [],
    }
    if not deck_keys or target_games <= 0:
        return benchmark

    if progress_callback:
        progress_callback({
            "type": "benchmark_started",
            "deck_keys": deck_keys,
            "games_per_matchup": target_games,
            "total_matchups": len(deck_keys) * max(0, len(deck_keys) - 1) // 2,
        })

    trained_weights = {
        deck_key: _policy_weights_for_benchmark(deck_key, policies[deck_key])
        for deck_key in deck_keys
    }
    benchmark["before_after"] = _before_after_benchmark(
        deck_keys,
        trained_weights,
        seed + 700_000,
        target_games,
        worker_count,
        search_preset,
        task_runner,
    )

    matrix: dict[str, dict[str, Any]] = {
        deck_key: {
            deck_key: {
                "wins": 0,
                "losses": 0,
                "draws": 0,
                "games": 0,
                "win_rate": None,
                "point_rate": None,
                "avg_score": 0.0,
            }
        }
        for deck_key in deck_keys
    }
    ranking_accum = {
        deck_key: {"wins": 0, "losses": 0, "draws": 0, "score_total": 0.0}
        for deck_key in deck_keys
    }

    for pair_idx, deck_a in enumerate(deck_keys):
        for deck_b in deck_keys[pair_idx + 1:]:
            tasks = [
                PlayMatchTask(
                    deck_a,
                    trained_weights[deck_a],
                    deck_b,
                    trained_weights[deck_b],
                    seed + 800_000 + pair_idx * 10007 + game_idx * 101,
                    game_idx % 2,
                    search_preset=search_preset,
                )
                for game_idx in range(target_games)
            ]
            a_stats = _stats()
            b_stats = _stats()
            a_score_total = 0.0
            b_score_total = 0.0
            if task_runner is not None:
                task_results = task_runner.run_play_match_tasks(tasks)
            else:
                task_results = _run_play_match_tasks(tasks, worker_count)
            for winner, eval_score in task_results:
                a_score_total += eval_score
                b_score_total -= eval_score
                if winner == 0:
                    a_stats["wins"] += 1
                    b_stats["losses"] += 1
                elif winner == 1:
                    a_stats["losses"] += 1
                    b_stats["wins"] += 1
                else:
                    a_stats["draws"] += 1
                    b_stats["draws"] += 1

            a_result = _finalize_stats(a_stats, a_score_total)
            b_result = _finalize_stats(b_stats, b_score_total)
            matrix.setdefault(deck_a, {})[deck_b] = a_result
            matrix.setdefault(deck_b, {})[deck_a] = b_result

            for key, stats, score_total in (
                (deck_a, a_stats, a_score_total),
                (deck_b, b_stats, b_score_total),
            ):
                _merge_stats(ranking_accum[key], stats)
                ranking_accum[key]["score_total"] += score_total

            if progress_callback:
                progress_callback({
                    "type": "matchup_finished",
                    "deck_a": deck_a,
                    "deck_b": deck_b,
                    "stats_a": a_result,
                    "stats_b": b_result,
                })

    rankings = []
    for deck_key, stats in ranking_accum.items():
        summary = _finalize_stats(stats, float(stats.get("score_total", 0.0)))
        summary["deck"] = deck_key
        rankings.append(summary)
    rankings.sort(
        key=lambda row: (
            float(row.get("point_rate", 0.0)),
            int(row.get("wins", 0)) - int(row.get("losses", 0)),
            float(row.get("avg_score", 0.0)),
        ),
        reverse=True,
    )
    for rank, row in enumerate(rankings, start=1):
        row["rank"] = rank

    benchmark["matrix"] = matrix
    benchmark["rankings"] = rankings
    if progress_callback:
        progress_callback({"type": "benchmark_finished", "benchmark": benchmark})
    return benchmark


def _open_progress_writer(path: str | None):
    if not path:
        return None
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    return open(path, "w", encoding="utf-8")


def run_training(config: TrainingConfig, progress_callback: ProgressCallback | None = None) -> dict[str, Any]:
    """Run a full training job and write the resulting policy payload."""
    writer = _open_progress_writer(config.progress_jsonl)

    def emit(event: dict[str, Any]) -> None:
        event = dict(event)
        event.setdefault("timestamp", time.time())
        if progress_callback:
            progress_callback(event)
        if writer:
            writer.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
            writer.flush()

    try:
        _ensure_cards_loaded()
        if config.deck == "all":
            deck_keys = list(DECK_SPECS)
        elif config.deck in DECK_SPECS:
            deck_keys = [config.deck]
        else:
            raise ValueError(f"Unknown deck key: {config.deck}")

        games_per_deck = max(1, int(config.games))
        worker_count = _normalized_workers(config.workers)
        benchmark_games = max(0, int(config.benchmark_games))
        total_training_games = games_per_deck * len(deck_keys)
        emit({
            "type": "run_started",
            "deck": config.deck,
            "deck_keys": deck_keys,
            "games_per_deck": games_per_deck,
            "eval_games": max(0, int(config.eval_games)),
            "benchmark_games": benchmark_games,
            "workers": worker_count,
            "total_training_games": total_training_games,
            "output": config.output,
        })

        policies: dict[str, Any] = {}
        total_done = 0
        total_refinement_games = 0
        started = time.time()
        with TrainingTaskRunner(worker_count) as task_runner:
            for offset, deck_key in enumerate(deck_keys):
                deck_seed = config.seed + offset * 1009
                emit({
                    "type": "deck_started",
                    "deck": deck_key,
                    "seed": deck_seed,
                    "target_games": games_per_deck,
                    "total_games_played": total_done,
                    "total_training_games": total_training_games,
                })
                policy = train_deck(
                    deck_key,
                    games_per_deck,
                    deck_seed,
                    eval_games=max(0, int(config.eval_games)),
                    workers=worker_count,
                    progress_callback=emit,
                    total_offset=total_done,
                    total_training_games=total_training_games,
                    search_preset=config.search_preset,
                    task_runner=task_runner,
                )
                policies[deck_key] = policy
                total_done += policy["training_games"]
                total_refinement_games += int((policy.get("metadata") or {}).get("refinement_games") or 0)
                emit({
                    "type": "deck_finished",
                    "deck": deck_key,
                    "training_games": policy["training_games"],
                    "refinement_games": (policy.get("metadata") or {}).get("refinement_games", 0),
                    "stats": policy["stats"],
                    "eval": policy.get("eval", {}),
                    "total_games_played": total_done,
                    "total_training_games": total_training_games,
                })

            benchmark = benchmark_policies(
                policies,
                config.seed,
                benchmark_games,
                workers=worker_count,
                search_preset=config.search_preset,
                progress_callback=emit,
                task_runner=task_runner,
            )

        payload = {
            "version": POLICY_VERSION,
            "seed": config.seed,
            "metadata": {
                "trainer": "cross_entropy_balanced_v2",
                "games_per_deck": games_per_deck,
                "eval_games": max(0, int(config.eval_games)),
                "benchmark_games": benchmark_games,
                "refinement_games": total_refinement_games,
                "workers": worker_count,
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "search": dict(SEARCH_PRESETS.get(config.search_preset, TRAINING_AI_SEARCH_HYBRID)),
                "fast_search": dict(FAST_SEARCH_PRESETS.get(config.search_preset, TRAINING_AI_SEARCH_HYBRID)),
            },
            "policies": policies,
            "benchmark": benchmark,
        }

        output_dir = os.path.dirname(config.output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        with open(config.output, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)

        emit({
            "type": "run_finished",
            "output": config.output,
            "policy_count": len(policies),
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

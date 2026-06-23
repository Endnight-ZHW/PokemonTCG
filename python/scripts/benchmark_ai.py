"""Small strength-guard benchmark for challenge AI changes."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from typing import Any

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.ai.training import DECK_SPECS, MatchDiagnostics, play_game


def _ensure_cards_loaded() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS)


def _deck_keys(selected: list[str] | None) -> list[str]:
    if not selected:
        return list(DECK_SPECS.keys())
    return [key for key in selected if key in DECK_SPECS]


def _opponent_for(deck_key: str, candidates: list[str]) -> str:
    for candidate in candidates:
        if candidate != deck_key:
            return candidate
    return deck_key


@dataclass(frozen=True)
class BenchmarkTask:
    deck_key: str
    opponent_key: str
    seed: int
    seat: int
    max_steps: int
    search_preset: str
    search_quality: str


def _execute_task(task: BenchmarkTask) -> MatchDiagnostics:
    _ensure_cards_loaded()
    diagnostic = play_game(
        task.deck_key,
        None,
        task.opponent_key,
        task.seed,
        max_steps=task.max_steps,
        candidate_player_idx=task.seat,
        search_preset=task.search_preset,
        search_quality=task.search_quality,
        return_diagnostics=True,
    )
    assert isinstance(diagnostic, MatchDiagnostics)
    return diagnostic


def run_benchmark(
    *,
    deck_keys: list[str] | None = None,
    games_per_matchup: int = 2,
    seed: int = 17,
    max_steps: int = 80,
    search_preset: str = "hybrid",
    search_quality: str = "fast",
    workers: int = 1,
    mirror: bool = False,
) -> dict[str, Any]:
    """Run a small deterministic AI-vs-AI benchmark and return aggregate metrics."""
    _ensure_cards_loaded()
    keys = _deck_keys(deck_keys)
    if not keys:
        raise ValueError("No valid deck keys selected for benchmark.")

    started = time.perf_counter()
    rows: list[dict[str, Any]] = []
    wins = losses = draws = 0
    invalid_actions = no_target_actions = rule_exceptions = 0
    decision_timeouts = max_step_exhaustions = 0
    decision_count = 0
    decision_seconds = 0.0
    seat_wins = {0: 0, 1: 0}
    seat_games = {0: 0, 1: 0}
    total_score = 0.0
    total_games = 0

    game_count = max(1, int(games_per_matchup))
    tasks: list[BenchmarkTask] = []
    for deck_key in keys:
        opponent_key = deck_key if mirror else _opponent_for(deck_key, keys)
        for game_idx in range(game_count):
            game_seed = int(seed) + len(tasks) * 101 + game_idx
            seat = game_idx % 2
            tasks.append(BenchmarkTask(
                deck_key,
                opponent_key,
                game_seed,
                seat,
                max(20, int(max_steps)),
                search_preset,
                search_quality,
            ))

    worker_count = max(1, int(workers))
    if worker_count == 1:
        diagnostics = [_execute_task(task) for task in tasks]
    else:
        with ProcessPoolExecutor(max_workers=worker_count) as executor:
            diagnostics = list(executor.map(_execute_task, tasks))

    for task, diagnostic in zip(tasks, diagnostics):
        deck_key = task.deck_key
        opponent_key = task.opponent_key
        game_seed = task.seed
        seat = task.seat
        winner, score = diagnostic.winner, diagnostic.score
        total_games += 1
        total_score += float(score)
        seat_games[seat] += 1
        if winner == 0:
            wins += 1
            seat_wins[seat] += 1
        elif winner == 1:
            losses += 1
        else:
            draws += 1
        invalid_actions += diagnostic.invalid_actions
        no_target_actions += diagnostic.no_target_actions
        rule_exceptions += diagnostic.rule_exceptions
        decision_timeouts += diagnostic.decision_timeouts
        decision_count += diagnostic.decision_count
        decision_seconds += diagnostic.decision_seconds
        if diagnostic.terminal_reason == "max_steps":
            max_step_exhaustions += 1
        rows.append({
            "deck": deck_key,
            "opponent": opponent_key,
            "seed": game_seed,
            "winner": winner,
            "score": round(float(score), 3),
            "seat": seat,
            "terminal_reason": diagnostic.terminal_reason,
            "invalid_actions": diagnostic.invalid_actions,
            "no_target_actions": diagnostic.no_target_actions,
            "rule_exceptions": diagnostic.rule_exceptions,
            "decision_timeouts": diagnostic.decision_timeouts,
            "average_decision_seconds": round(
                diagnostic.decision_seconds / max(1, diagnostic.decision_count),
                6,
            ),
        })

    elapsed = time.perf_counter() - started
    summary = {
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "average_score": round(total_score / max(1, total_games), 3),
        "invalid_actions": invalid_actions,
        "invalid_action_rate": round(invalid_actions / max(1, decision_count), 6),
        "no_target_actions": no_target_actions,
        "no_target_action_rate": round(no_target_actions / max(1, decision_count), 6),
        "rule_exceptions": rule_exceptions,
        "decision_timeouts": decision_timeouts,
        "decision_timeout_rate": round(decision_timeouts / max(1, decision_count), 6),
        # Compatibility alias. This now means decision deadline violations,
        # not games truncated by max_steps.
        "timeout_rate": round(decision_timeouts / max(1, decision_count), 6),
        "max_step_exhaustions": max_step_exhaustions,
        "max_step_exhaustion_rate": round(max_step_exhaustions / max(1, total_games), 6),
        "average_decision_seconds": round(decision_seconds / max(1, decision_count), 6),
        "seat_win_rates": {
            str(seat): round(seat_wins[seat] / max(1, seat_games[seat]), 6)
            for seat in (0, 1)
        },
        "seat_win_rate_gap": round(
            abs(
                seat_wins[0] / max(1, seat_games[0])
                - seat_wins[1] / max(1, seat_games[1])
            ),
            6,
        ),
        "elapsed_seconds": round(elapsed, 3),
    }
    return {
        "deck_keys": keys,
        "games": total_games,
        "games_per_matchup": game_count,
        "search_preset": search_preset,
        "search_quality": search_quality,
        "workers": worker_count,
        "mirror": bool(mirror),
        "max_steps": max_steps,
        "matchups": rows,
        "summary": summary,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a small ChallengeAI benchmark.")
    parser.add_argument("--deck", action="append", choices=list(DECK_SPECS.keys()))
    parser.add_argument("--games", type=int, default=2)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--max-steps", type=int, default=80)
    parser.add_argument(
        "--search-preset",
        default="hybrid",
        choices=["hybrid", "beam", "minimax"],
        help="Planner budget preset; legacy names are retained as CLI aliases.",
    )
    parser.add_argument("--search-quality", default="fast", choices=["fast", "standard"])
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--mirror", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()

    payload = run_benchmark(
        deck_keys=args.deck,
        games_per_matchup=max(1, args.games),
        seed=args.seed,
        max_steps=max(20, args.max_steps),
        search_preset=args.search_preset,
        search_quality=args.search_quality,
        workers=max(1, args.workers),
        mirror=bool(args.mirror),
    )
    rendered = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    if args.output:
        output_dir = os.path.dirname(args.output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(rendered)
            fh.write("\n")
    print(rendered)
    return 0


if __name__ == "__main__":
    os.chdir(PROJECT_ROOT)
    raise SystemExit(main())

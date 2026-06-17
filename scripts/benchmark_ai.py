"""Small strength-guard benchmark for challenge AI changes."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.ai.training import DECK_SPECS, play_game


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


def run_benchmark(
    *,
    deck_keys: list[str] | None = None,
    games_per_matchup: int = 2,
    seed: int = 17,
    max_steps: int = 80,
    search_preset: str = "hybrid",
    search_quality: str = "fast",
) -> dict[str, Any]:
    """Run a small deterministic AI-vs-AI benchmark and return aggregate metrics."""
    _ensure_cards_loaded()
    keys = _deck_keys(deck_keys)
    if not keys:
        raise ValueError("No valid deck keys selected for benchmark.")

    started = time.perf_counter()
    rows: list[dict[str, Any]] = []
    wins = losses = draws = timeouts = 0
    total_score = 0.0
    total_games = 0

    game_count = max(1, int(games_per_matchup))
    for deck_key in keys:
        opponent_key = _opponent_for(deck_key, keys)
        for game_idx in range(game_count):
            game_seed = int(seed) + len(rows) * 101 + game_idx
            winner, score = play_game(
                deck_key,
                None,
                opponent_key,
                game_seed,
                max_steps=max(20, int(max_steps)),
                search_preset=search_preset,
                search_quality=search_quality,
            )
            total_games += 1
            total_score += float(score)
            if winner == 0:
                wins += 1
            elif winner == 1:
                losses += 1
            else:
                draws += 1
                timeouts += 1
            rows.append({
                "deck": deck_key,
                "opponent": opponent_key,
                "seed": game_seed,
                "winner": winner,
                "score": round(float(score), 3),
            })

    elapsed = time.perf_counter() - started
    summary = {
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "average_score": round(total_score / max(1, total_games), 3),
        "invalid_action_rate": 0.0,
        "timeout_rate": round(timeouts / max(1, total_games), 6),
        "elapsed_seconds": round(elapsed, 3),
    }
    return {
        "deck_keys": keys,
        "games": total_games,
        "games_per_matchup": game_count,
        "search_preset": search_preset,
        "search_quality": search_quality,
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
    parser.add_argument("--search-preset", default="hybrid", choices=["hybrid", "beam", "minimax"])
    parser.add_argument("--search-quality", default="fast", choices=["fast", "standard"])
    args = parser.parse_args()

    payload = run_benchmark(
        deck_keys=args.deck,
        games_per_matchup=max(1, args.games),
        seed=args.seed,
        max_steps=max(20, args.max_steps),
        search_preset=args.search_preset,
        search_quality=args.search_quality,
    )
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

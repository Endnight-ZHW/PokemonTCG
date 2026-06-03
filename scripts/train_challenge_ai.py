"""Offline self-play trainer CLI for challenge-mode deck policies."""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from engine.ai.training import DEFAULT_CANDIDATE_OUTPUT, DEFAULT_WORKERS, DECK_SPECS, TrainingConfig, run_training


def main() -> None:
    parser = argparse.ArgumentParser(description="Train challenge AI policy weights via offline self-play.")
    parser.add_argument("--deck", default="all", choices=["all", *DECK_SPECS.keys()])
    parser.add_argument("--games", type=int, default=200)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--output", default=DEFAULT_CANDIDATE_OUTPUT)
    parser.add_argument("--eval-games", type=int, default=20)
    parser.add_argument("--progress-jsonl", default=None)
    parser.add_argument("--workers", type=int, default=None)
    parser.add_argument("--benchmark-games", type=int, default=0)
    parser.add_argument("--search-preset", default="hybrid", choices=["hybrid", "beam", "minimax"])
    args = parser.parse_args()

    config = TrainingConfig(
        deck=args.deck,
        games=max(1, args.games),
        seed=args.seed,
        output=args.output,
        eval_games=max(0, args.eval_games),
        progress_jsonl=args.progress_jsonl,
        workers=args.workers if args.workers is not None else DEFAULT_WORKERS,
        benchmark_games=max(0, args.benchmark_games),
        search_preset=args.search_preset,
    )
    payload = run_training(config)
    print(f"Wrote {args.output} with {len(payload['policies'])} trained deck policy set(s).")


if __name__ == "__main__":
    main()

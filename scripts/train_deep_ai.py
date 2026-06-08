"""Train the optional deep-learning challenge AI."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from engine.ai.dl.training import DeepTrainingConfig, is_torch_available, run_deep_training
from engine.ai.training import DECK_SPECS


def _write_error_progress(path: str | None, message: str) -> None:
    if not path:
        return
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "type": "error",
                "trainer": "rl_ai",
                "message": message,
                "timestamp": time.time(),
            },
            fh,
            ensure_ascii=False,
            sort_keys=True,
        )
        fh.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Train optional deep-learning AI via bootstrap + self-play. Each deck trains an independent model."
    )
    parser.add_argument("--deck", default="all", choices=["all", *DECK_SPECS.keys()])
    parser.add_argument("--games", type=int, default=800,
                        help="RL fine-tune self-play games per deck (default: 800).")
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--output", default=None, help="Output .pt checkpoint path (single-deck; ignored for --deck all).")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--bootstrap-games", type=int, default=2000,
                        help="Teacher imitation games per deck (default: 2000).")
    parser.add_argument("--dagger-games", type=int, default=500,
                        help="DAgger games where the model acts and teacher labels visited states (default: 500).")
    parser.add_argument("--bootstrap-epochs", type=int, default=10,
                        help="Epochs over bootstrap examples (default: 10).")
    parser.add_argument("--self-play-epochs", type=int, default=10,
                        help="Epochs over self-play examples (default: 10).")
    parser.add_argument("--eval-games", type=int, default=200,
                        help="Evaluation games per deck (default: 200).")
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--max-steps", type=int, default=120)
    parser.add_argument("--batch-size", type=int, default=64,
                        help="Mini-batch size for training (default: 64).")
    parser.add_argument("--rollout-batch-games", type=int, default=16,
                        help="Rollout games collected before each training update (default: 16).")
    parser.add_argument("--updates-per-rollout", type=int, default=2,
                        help="Training epochs after each rollout batch (default: 2).")
    parser.add_argument("--teacher-search-preset", default="hybrid",
                        choices=["hybrid", "fast", "quality", "minimax_fast", "minimax"],
                        help="ChallengeAI search config used for teacher/fallback (hybrid prunes with beam and scores with minimax).")
    parser.add_argument("--choice-head-enabled", action=argparse.BooleanOptionalAction, default=True,
                        help="Train and use the pending-choice scorer (default: enabled).")
    parser.add_argument("--acceptance-metric", default="score", choices=["wins", "points", "score"],
                        help="Metric used to decide whether the candidate replaces the previous model.")
    parser.add_argument("--min-win-delta", type=int, default=0,
                        help="Minimum candidate win improvement over each baseline when --acceptance-metric wins.")
    parser.add_argument("--teacher-label-model-states", action=argparse.BooleanOptionalAction, default=True,
                        help="Collect teacher labels for model-visited rollout states (default: enabled).")
    parser.add_argument("--progress-jsonl", default=None)
    args = parser.parse_args()

    if not is_torch_available():
        message = "PyTorch is not installed. Install torch in the DL environment before running deep AI training."
        _write_error_progress(args.progress_jsonl, message)
        print(message, file=sys.stderr)
        return 2

    config = DeepTrainingConfig(
        deck=args.deck,
        games=max(0, args.games),
        seed=args.seed,
        output=args.output,
        device=args.device,
        bootstrap_games=max(0, args.bootstrap_games),
        dagger_games=max(0, args.dagger_games),
        bootstrap_epochs=max(1, args.bootstrap_epochs),
        self_play_epochs=max(1, args.self_play_epochs),
        eval_games=max(0, args.eval_games),
        workers=max(1, args.workers),
        max_steps=max(20, args.max_steps),
        batch_size=max(1, args.batch_size),
        rollout_batch_games=max(1, args.rollout_batch_games),
        updates_per_rollout=max(1, args.updates_per_rollout),
        teacher_search_preset=args.teacher_search_preset,
        choice_head_enabled=bool(args.choice_head_enabled),
        acceptance_metric=args.acceptance_metric,
        min_win_delta=max(0, args.min_win_delta),
        teacher_label_model_states=bool(args.teacher_label_model_states),
        progress_jsonl=args.progress_jsonl,
    )
    payload = run_deep_training(config)
    if "model_paths" in payload:
        for deck_key, path in payload["model_paths"].items():
            print(f"[{deck_key}] Wrote {path}")
    else:
        print(f"Wrote {payload.get('model_path', 'unknown')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

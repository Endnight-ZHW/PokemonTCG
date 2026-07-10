"""Train the optional deep-learning challenge AI."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

PYTHON_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO_ROOT = os.path.abspath(os.path.join(PYTHON_ROOT, ".."))
INVOCATION_CWD = os.getcwd()
sys.path.insert(0, PYTHON_ROOT)

from engine.ai.dl.training import DeepTrainingConfig, is_torch_available, run_deep_training
from engine.ai.dl.release_gate import DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE
from engine.ai.training import DECK_SPECS


def _resolve_cli_path(path: str | None) -> str | None:
    """Resolve user-supplied paths before the script chdirs into python/."""
    if path is None:
        return None
    path = os.path.expandvars(os.path.expanduser(str(path)))
    if not path:
        return path
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.abspath(os.path.join(INVOCATION_CWD, path)))


def _repo_display_path(path: str | None) -> str | None:
    if not path:
        return path
    try:
        return os.path.relpath(path, REPO_ROOT)
    except ValueError:
        return path


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


def _load_challenge_baseline_progress(
    path: str,
    *,
    deck_key: str,
    training_seed: int,
    asserted_source_seed: int | None,
    eval_games: int,
    max_steps: int,
    teacher_search_preset: str,
) -> tuple[dict[str, Any], int]:
    """Load and verify a completed Challenge baseline from a prior run."""
    current_run: dict[str, Any] = {}
    selected_run: dict[str, Any] | None = None
    selected_event: dict[str, Any] | None = None
    current_choice_examples = 0
    selected_choice_examples = 0
    with open(path, "r", encoding="utf-8") as fh:
        for line_number, line in enumerate(fh, start=1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSONL at line {line_number}: {exc}") from exc
            if not isinstance(event, dict):
                continue
            if event.get("type") == "run_started":
                current_run = event
                current_choice_examples = 0
                continue
            if (
                event.get("type") in {
                    "dagger_game_finished",
                    "self_play_game_finished",
                    "pure_rl_game_finished",
                }
                and str(event.get("deck") or "") == deck_key
            ):
                current_choice_examples += max(0, int(event.get("choice_examples") or 0))
            if (
                event.get("type") == "challenge_baseline_eval_finished"
                and str(event.get("deck") or "") == deck_key
            ):
                selected_run = dict(current_run)
                selected_event = event
                selected_choice_examples = current_choice_examples

    if selected_event is None or selected_run is None:
        raise ValueError(f"No completed Challenge baseline for deck '{deck_key}' in {path}")

    expected_seed = int(training_seed)
    recorded_seed = selected_event.get("training_seed", selected_run.get("seed"))
    if recorded_seed is None:
        recorded_seed = asserted_source_seed
    if recorded_seed is None:
        raise ValueError(
            "Legacy baseline progress has no seed; pass --reuse-challenge-baseline-seed to assert its source seed"
        )
    if int(recorded_seed) != expected_seed:
        raise ValueError(
            f"Challenge baseline seed mismatch: expected {expected_seed}, got {recorded_seed}"
        )

    expected_eval_seed = expected_seed + 900_000
    recorded_eval_seed = selected_event.get("eval_seed")
    if recorded_eval_seed is not None and int(recorded_eval_seed) != expected_eval_seed:
        raise ValueError(
            f"Challenge baseline eval seed mismatch: expected {expected_eval_seed}, got {recorded_eval_seed}"
        )

    expected_config = {
        "eval_games": int(eval_games),
        "max_steps": max(20, int(max_steps)),
        "teacher_search_preset": str(teacher_search_preset),
    }
    for key, expected in expected_config.items():
        actual = selected_run.get(key)
        if actual != expected:
            raise ValueError(
                f"Challenge baseline {key} mismatch: expected {expected!r}, got {actual!r}"
            )

    baseline = selected_event.get("eval")
    if not isinstance(baseline, dict):
        raise ValueError("Challenge baseline event has no evaluation payload")
    baseline = dict(baseline)
    if int(baseline.get("games") or 0) != int(eval_games):
        raise ValueError("Challenge baseline game count does not match --eval-games")
    game_points = baseline.get("game_points")
    if not isinstance(game_points, list) or len(game_points) != int(eval_games):
        raise ValueError("Challenge baseline lacks complete ordered per-game point evidence")
    return baseline, selected_choice_examples


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Train optional deep-learning AI. teacher_dagger_rl is the production pipeline; alpha_zero_rl is experimental."
    )
    parser.add_argument("--trainer", default="teacher_dagger_rl", choices=["alpha_zero_rl", "teacher_dagger_rl"],
                        help="Training pipeline (default: teacher_dagger_rl).")
    parser.add_argument("--deck", default="fire", choices=["all", *DECK_SPECS.keys()])
    parser.add_argument("--games", type=int, default=0,
                        help="RL fine-tune self-play games per deck (default: 0 for production teacher/DAgger).")
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--model", default=None,
                        help="Checkpoint path to warm-start from instead of the per-deck default.")
    parser.add_argument("--output", default=None, help="Output .pt checkpoint path (single-deck; ignored for --deck all).")
    parser.add_argument("--warm-start", action=argparse.BooleanOptionalAction, default=True,
                        help="Initialize from the strongest evaluated checkpoint for the deck (default: enabled).")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--bootstrap-games", type=int, default=None,
                        help="Teacher imitation games per deck (default: 0 for alpha_zero_rl, 1000 for teacher_dagger_rl).")
    parser.add_argument("--dagger-games", type=int, default=None,
                        help="DAgger games where the model acts and teacher labels visited states (default: 0 for alpha_zero_rl, 1000 for teacher_dagger_rl).")
    parser.add_argument("--bootstrap-epochs", type=int, default=20,
                        help="Epochs over bootstrap examples (default: 20).")
    parser.add_argument("--self-play-epochs", type=int, default=10,
                        help="Epochs over self-play examples (default: 10).")
    parser.add_argument("--eval-games", type=int, default=600,
                        help="Evaluation games per deck (default: 600).")
    default_workers = max(1, min(12, (os.cpu_count() or 2) - 2))
    parser.add_argument("--workers", type=int, default=default_workers,
                        help=f"Parallel rollout workers (default: {default_workers}).")
    parser.add_argument("--max-steps", type=int, default=160)
    parser.add_argument("--batch-size", type=int, default=256,
                        help="Mini-batch size for training (default: 256).")
    parser.add_argument("--amp", action=argparse.BooleanOptionalAction, default=True,
                        help="Use CUDA automatic mixed precision when available (default: enabled).")
    parser.add_argument("--rollout-batch-games", type=int, default=16,
                        help="Rollout games collected before each training update (default: 16).")
    parser.add_argument("--updates-per-rollout", type=int, default=2,
                        help="Training epochs after each rollout batch (default: 2).")
    parser.add_argument("--teacher-search-preset", default="quality",
                        choices=["hybrid", "fast", "quality", "minimax_fast", "minimax"],
                        help="Rules-policy planner budget preset. Legacy names remain accepted as aliases.")
    parser.add_argument("--choice-head-enabled", action=argparse.BooleanOptionalAction, default=True,
                        help="Train and use the pending-choice scorer (default: enabled).")
    parser.add_argument("--acceptance-metric", default="points", choices=["wins", "points", "score"],
                        help="Metric used to decide whether the candidate replaces the previous model.")
    parser.add_argument("--min-win-delta", type=int, default=0,
                        help="Minimum candidate win improvement over each baseline when --acceptance-metric wins.")
    parser.add_argument("--teacher-label-model-states", action=argparse.BooleanOptionalAction, default=True,
                        help="Collect teacher labels for model-visited rollout states (default: enabled).")
    parser.add_argument("--pure-rl-games", type=int, default=None,
                        help="Pure RL exploration games per deck after self-play (default: 0).")
    parser.add_argument("--replay-same-deal", type=int, default=None,
                        help="Same-deal replay seeds per deck (default: 0).")
    parser.add_argument("--mcts-simulations", type=int, default=64,
                        help="Shared-planner simulations for guided training phases and production eval (default: 64).")
    parser.add_argument("--mcts-chance-nodes", action=argparse.BooleanOptionalAction, default=False,
                        help="Deprecated compatibility flag; chance is sampled by the shared rules engine.")
    parser.add_argument("--use-mcts-training", action=argparse.BooleanOptionalAction, default=True,
                        help="Use shared-planner-guided training where configured (default: enabled).")
    parser.add_argument("--eval-use-mcts", action=argparse.BooleanOptionalAction, default=True,
                        help="Evaluate teacher_dagger_rl candidates with production neural-MCTS search (default: enabled).")
    parser.add_argument("--replay-buffer-size", type=int, default=50000,
                        help="Per-deck replay buffer capacity for deep AI training (default: 50000).")
    parser.add_argument("--replay-sample-ratio", type=float, default=0.5,
                        help="Replay examples sampled per fresh example during updates (default: 0.5).")
    parser.add_argument("--distill-dataset", action="append", default=[],
                        help="JSONL teacher dataset exported by Godot. Can be passed multiple times.")
    parser.add_argument("--distill-epochs", type=int, default=3,
                        help="Epochs over distillation examples before online training (default: 3).")
    parser.add_argument("--distill-val-split", type=float, default=0.1,
                        help="Held-out fraction for distillation progress metadata (default: 0.1).")
    parser.add_argument("--league-dir", default=os.path.join("data", "ai_league"),
                        help="Directory containing verified Deep AI league checkpoints (default: data/ai_league).")
    parser.add_argument("--league-eval-games", type=int, default=600,
                        help="League evaluation games for alpha_zero_rl candidates (default: 600).")
    parser.add_argument("--league-use-mcts", action=argparse.BooleanOptionalAction, default=False,
                        help="Use neural MCTS during alpha_zero_rl league evaluation (default: disabled; self-play still uses MCTS).")
    parser.add_argument("--min-elo-delta", type=float, default=25.0,
                        help="Minimum league Elo delta required for alpha_zero_rl acceptance (default: 25).")
    parser.add_argument("--min-score-rate", type=float, default=0.53,
                        help="Minimum league score rate required for alpha_zero_rl acceptance (default: 0.53).")
    parser.add_argument("--min-point-rate", type=float, default=0.50,
                        help="Fallback minimum legacy evaluation point rate when no paired Challenge baseline is available (default: 0.50).")
    parser.add_argument("--min-delta-point-rate", type=float, default=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
                        help=f"Minimum point-rate delta versus the paired same-deck Challenge baseline (default: {DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE}).")
    parser.add_argument("--max-step-exhaustion-rate", type=float, default=0.05,
                        help="Absolute max-step exhaustion ceiling; a paired Challenge baseline may raise it only to its own rate (default: 0.05).")
    parser.add_argument("--reuse-challenge-baseline-progress", default=None,
                        help="Reuse a verified Challenge baseline from a prior training JSONL and run only candidate evaluation.")
    parser.add_argument("--reuse-challenge-baseline-seed", type=int, default=None,
                        help="Assert the source seed when reusing legacy progress that predates recorded evaluation seeds.")
    parser.add_argument("--progress-jsonl", default=None)
    args = parser.parse_args()
    resolved_model = _resolve_cli_path(args.model)
    resolved_output = _resolve_cli_path(args.output)
    resolved_progress = _resolve_cli_path(args.progress_jsonl)
    resolved_challenge_baseline_progress = _resolve_cli_path(args.reuse_challenge_baseline_progress)
    resolved_distill_datasets = tuple(
        path for path in (_resolve_cli_path(item) for item in (args.distill_dataset or ())) if path
    )
    resolved_league_dir = _resolve_cli_path(args.league_dir)

    if not is_torch_available():
        message = "PyTorch is not installed. Install torch in the DL environment before running deep AI training."
        _write_error_progress(resolved_progress, message)
        print(message, file=sys.stderr)
        return 2

    trainer = args.trainer
    bootstrap_games = (
        args.bootstrap_games
        if args.bootstrap_games is not None
        else (0 if trainer == "alpha_zero_rl" else 1000)
    )
    dagger_games = (
        args.dagger_games
        if args.dagger_games is not None
        else (0 if trainer == "alpha_zero_rl" else 1000)
    )
    if trainer == "alpha_zero_rl":
        pure_rl_games = args.pure_rl_games if args.pure_rl_games is not None else 0
        replay_same_deal = args.replay_same_deal if args.replay_same_deal is not None else 0
        resolved_distill_datasets = ()
    else:
        pure_rl_games = args.pure_rl_games if args.pure_rl_games is not None else 0
        replay_same_deal = args.replay_same_deal if args.replay_same_deal is not None else 0

    challenge_baseline_eval = None
    recovered_choice_examples = 0
    if resolved_challenge_baseline_progress:
        if args.deck == "all":
            parser.error("--reuse-challenge-baseline-progress requires a single --deck")
        try:
            challenge_baseline_eval, recovered_choice_examples = _load_challenge_baseline_progress(
                resolved_challenge_baseline_progress,
                deck_key=args.deck,
                training_seed=args.seed,
                asserted_source_seed=args.reuse_challenge_baseline_seed,
                eval_games=max(0, args.eval_games),
                max_steps=max(20, args.max_steps),
                teacher_search_preset=args.teacher_search_preset,
            )
        except (OSError, ValueError) as exc:
            parser.error(str(exc))

    config = DeepTrainingConfig(
        trainer=trainer,
        deck=args.deck,
        games=max(0, args.games),
        seed=args.seed,
        model=resolved_model,
        output=resolved_output,
        warm_start=bool(args.warm_start),
        device=args.device,
        bootstrap_games=max(0, bootstrap_games),
        dagger_games=max(0, dagger_games),
        bootstrap_epochs=max(1, args.bootstrap_epochs),
        self_play_epochs=max(1, args.self_play_epochs),
        eval_games=max(0, args.eval_games),
        workers=max(1, args.workers),
        max_steps=max(20, args.max_steps),
        batch_size=max(1, args.batch_size),
        use_amp=bool(args.amp),
        rollout_batch_games=max(1, args.rollout_batch_games),
        updates_per_rollout=max(1, args.updates_per_rollout),
        teacher_search_preset=args.teacher_search_preset,
        choice_head_enabled=bool(args.choice_head_enabled),
        acceptance_metric=args.acceptance_metric,
        min_win_delta=max(0, args.min_win_delta),
        teacher_label_model_states=bool(args.teacher_label_model_states),
        pure_rl_games=max(0, pure_rl_games),
        replay_same_deal=max(0, replay_same_deal),
        mcts_simulations=max(1, args.mcts_simulations),
        mcts_chance_nodes=bool(args.mcts_chance_nodes),
        use_mcts_training=bool(args.use_mcts_training),
        eval_use_mcts=bool(args.eval_use_mcts),
        replay_buffer_size=max(1, args.replay_buffer_size),
        replay_sample_ratio=max(0.0, args.replay_sample_ratio),
        distill_dataset=resolved_distill_datasets,
        distill_epochs=max(1, args.distill_epochs),
        distill_val_split=max(0.0, min(0.9, args.distill_val_split)),
        league_dir=resolved_league_dir or os.path.join("data", "ai_league"),
        league_eval_games=max(0, args.league_eval_games),
        league_use_mcts=bool(args.league_use_mcts),
        min_elo_delta=float(args.min_elo_delta),
        min_score_rate=max(0.0, min(1.0, float(args.min_score_rate))),
        min_point_rate=max(0.0, min(1.0, float(args.min_point_rate))),
        min_delta_point_rate=max(-1.0, min(1.0, float(args.min_delta_point_rate))),
        max_step_exhaustion_rate=max(0.0, min(1.0, float(args.max_step_exhaustion_rate))),
        challenge_baseline_eval=challenge_baseline_eval,
        challenge_baseline_source=resolved_challenge_baseline_progress,
        recovered_choice_examples=recovered_choice_examples,
        progress_jsonl=resolved_progress,
    )
    payload = run_deep_training(config)
    if "model_paths" in payload:
        for deck_key, path in payload["model_paths"].items():
            print(f"[{deck_key}] Wrote {_repo_display_path(path)}")
    else:
        print(f"Wrote {_repo_display_path(payload.get('model_path', 'unknown'))}")
    return 0


if __name__ == "__main__":
    os.chdir(PYTHON_ROOT)
    raise SystemExit(main())

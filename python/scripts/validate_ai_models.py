"""Validate deployed Deep AI checkpoints against the release gate."""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
INVOCATION_CWD = os.getcwd()
sys.path.insert(0, PROJECT_ROOT)

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai.dl.release_gate import (
    DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
    DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    DEFAULT_MIN_ACCEPTED_POINT_RATE,
    allowed_max_step_exhaustion_rate,
    max_step_exhaustion_rate as release_max_step_exhaustion_rate,
    paired_delta_point_rate,
    point_rate,
)
from engine.ai.dl.encoder import ENCODER_SCHEMA_VERSION
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.ai.training import DECK_SPECS


def _resolve_cli_path(path: str) -> str:
    path = os.path.expandvars(os.path.expanduser(str(path)))
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.abspath(os.path.join(INVOCATION_CWD, path)))


def _eval_row(metadata: dict[str, Any], deck_key: str) -> dict[str, Any]:
    summary = metadata.get("summary") or {}
    row = summary.get(deck_key) or {}
    return row.get("eval") or {}


def _challenge_baseline_row(metadata: dict[str, Any], deck_key: str) -> dict[str, Any]:
    summary = metadata.get("summary") or {}
    row = summary.get(deck_key) or {}
    return row.get("challenge_baseline_eval") or row.get("release_baseline_eval") or {}


def validate_model(
    deck_key: str,
    *,
    model_dir: str,
    min_games: int,
    min_point_rate: float,
    min_delta_point_rate: float,
    max_step_exhaustion_rate: float,
) -> dict[str, Any]:
    model_path = os.path.join(model_dir, f"{deck_key}.pt")
    sidecar_path = os.path.join(model_dir, f"{deck_key}.json")
    errors: list[str] = []
    metadata: dict[str, Any] = {}
    if not os.path.isfile(model_path) or os.path.getsize(model_path) <= 0:
        errors.append("missing_model")
    try:
        with open(sidecar_path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        metadata = dict(payload.get("metadata") or {})
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        errors.append("missing_or_invalid_sidecar")

    eval_row = _eval_row(metadata, deck_key)
    games = int(eval_row.get("games") or metadata.get("eval_games") or 0)
    if games < min_games:
        errors.append("insufficient_eval_games")
    if not bool(metadata.get("accepted")):
        errors.append("not_accepted")
    if not bool(metadata.get("verified")):
        errors.append("not_verified")
    if int(metadata.get("rules_version") or 0) != RULES_SCHEMA_VERSION:
        errors.append("rules_schema_mismatch")
    if int(metadata.get("action_version") or 0) != ACTION_SCHEMA_VERSION:
        errors.append("action_schema_mismatch")
    if int(metadata.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION:
        errors.append("encoder_schema_mismatch")
    if int(metadata.get("planner_version") or 0) != PLANNER_SCHEMA_VERSION:
        errors.append("planner_schema_mismatch")
    if not isinstance(metadata.get("seed"), int):
        errors.append("missing_training_seed")

    zero_metrics = (
        "invalid_action_rate",
        "no_target_action_rate",
        "rule_exception_rate",
        "decision_timeout_rate",
    )
    for metric in zero_metrics:
        if float(eval_row.get(metric, 0.0) or 0.0) > 0.0:
            errors.append(metric)
    wins = int(eval_row.get("wins") or 0)
    candidate_point_rate = point_rate(eval_row)
    challenge_baseline = _challenge_baseline_row(metadata, deck_key)
    challenge_baseline_games = int(challenge_baseline.get("games") or 0)
    challenge_baseline_point_rate = point_rate(challenge_baseline) if challenge_baseline_games > 0 else None
    delta_point_rate = (
        candidate_point_rate - challenge_baseline_point_rate
        if challenge_baseline_point_rate is not None else None
    )
    paired_delta_rate = (
        paired_delta_point_rate(eval_row, challenge_baseline)
        if challenge_baseline_games > 0 else None
    )
    release_delta_point_rate = (
        paired_delta_rate
        if paired_delta_rate is not None else delta_point_rate
    )
    if challenge_baseline_games > 0:
        if release_delta_point_rate is None or release_delta_point_rate + 1e-12 < float(min_delta_point_rate):
            errors.append("insufficient_delta_point_rate")
    elif candidate_point_rate + 1e-12 < float(min_point_rate):
        errors.append("insufficient_point_rate")
    exhaustion_rate = release_max_step_exhaustion_rate(eval_row)
    baseline_exhaustion_rate = (
        release_max_step_exhaustion_rate(challenge_baseline)
        if challenge_baseline_games > 0 else None
    )
    allowed_exhaustion_rate = allowed_max_step_exhaustion_rate(
        max_step_exhaustion_rate,
        challenge_baseline if challenge_baseline_games > 0 else None,
    )
    if exhaustion_rate > allowed_exhaustion_rate + 1e-12:
        errors.append("max_step_exhaustion_rate")
    if bool(metadata.get("choice_head_enabled")):
        summary = metadata.get("summary") if isinstance(metadata.get("summary"), dict) else {}
        deck_summary = summary.get(deck_key) if isinstance(summary, dict) else {}
        deck_summary = deck_summary if isinstance(deck_summary, dict) else {}
        choice_examples = int((deck_summary.get("choice") or {}).get("choice_examples") or 0)
        choice_examples += int((deck_summary.get("distill_choice") or {}).get("choice_examples") or 0)
        choice_examples += int(deck_summary.get("loaded_choice_examples") or 0)
        if choice_examples <= 0:
            errors.append("choice_head_untrained")

    return {
        "deck": deck_key,
        "valid": not errors,
        "errors": errors,
        "model_path": model_path,
        "eval_games": games,
        "wins": wins,
        "losses": int(eval_row.get("losses") or 0),
        "point_rate": candidate_point_rate,
        "challenge_baseline_games": challenge_baseline_games,
        "challenge_baseline_point_rate": challenge_baseline_point_rate,
        "delta_point_rate": delta_point_rate,
        "paired_delta_point_rate": paired_delta_rate,
        "max_step_exhaustion_rate": exhaustion_rate,
        "challenge_baseline_max_step_exhaustion_rate": baseline_exhaustion_rate,
        "allowed_max_step_exhaustion_rate": allowed_exhaustion_rate,
        "delta_max_step_exhaustion_rate": (
            exhaustion_rate - baseline_exhaustion_rate
            if baseline_exhaustion_rate is not None else None
        ),
        "average_decision_seconds": float(
            eval_row.get("average_decision_seconds", 0.0) or 0.0
        ),
        "seat_win_rate_gap": float(eval_row.get("seat_win_rate_gap", 0.0) or 0.0),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model-dir",
        default=os.path.join(PROJECT_ROOT, "data", "ai_models"),
    )
    parser.add_argument(
        "--min-games",
        type=int,
        default=DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    )
    parser.add_argument(
        "--min-point-rate",
        type=float,
        default=DEFAULT_MIN_ACCEPTED_POINT_RATE,
    )
    parser.add_argument(
        "--min-delta-point-rate",
        type=float,
        default=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    )
    parser.add_argument(
        "--max-step-exhaustion-rate",
        type=float,
        default=DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
        help="Absolute ceiling; paired Challenge evidence may raise it only to the baseline exhaustion rate.",
    )
    args = parser.parse_args()
    model_dir = _resolve_cli_path(args.model_dir)
    rows = [
        validate_model(
            deck_key,
            model_dir=model_dir,
            min_games=max(0, args.min_games),
            min_point_rate=max(0.0, min(1.0, args.min_point_rate)),
            min_delta_point_rate=max(-1.0, min(1.0, args.min_delta_point_rate)),
            max_step_exhaustion_rate=max(0.0, min(1.0, args.max_step_exhaustion_rate)),
        )
        for deck_key in DECK_SPECS
    ]
    payload = {
        "valid": all(row["valid"] for row in rows),
        "required_eval_games": max(0, args.min_games),
        "required_min_point_rate": max(0.0, min(1.0, args.min_point_rate)),
        "required_min_delta_point_rate": max(-1.0, min(1.0, args.min_delta_point_rate)),
        "required_max_step_exhaustion_rate": max(0.0, min(1.0, args.max_step_exhaustion_rate)),
        "models": rows,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if payload["valid"] else 1


if __name__ == "__main__":
    os.chdir(PROJECT_ROOT)
    raise SystemExit(main())

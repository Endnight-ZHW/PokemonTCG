"""Validate deployed Deep AI checkpoints against the release gate."""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai.dl.controller import DEFAULT_MIN_ACCEPTED_EVAL_GAMES
from engine.ai.dl.encoder import ENCODER_SCHEMA_VERSION
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.ai.training import DECK_SPECS


def _eval_row(metadata: dict[str, Any], deck_key: str) -> dict[str, Any]:
    summary = metadata.get("summary") or {}
    row = summary.get(deck_key) or {}
    return row.get("eval") or {}


def validate_model(
    deck_key: str,
    *,
    model_dir: str,
    min_games: int,
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

    return {
        "deck": deck_key,
        "valid": not errors,
        "errors": errors,
        "model_path": model_path,
        "eval_games": games,
        "wins": int(eval_row.get("wins") or 0),
        "losses": int(eval_row.get("losses") or 0),
        "max_step_exhaustion_rate": float(
            eval_row.get("max_step_exhaustion_rate", 0.0) or 0.0
        ),
        "average_decision_seconds": float(
            eval_row.get("average_decision_seconds", 0.0) or 0.0
        ),
        "seat_win_rate_gap": float(eval_row.get("seat_win_rate_gap", 0.0) or 0.0),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", default=os.path.join("data", "ai_models"))
    parser.add_argument(
        "--min-games",
        type=int,
        default=DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    )
    args = parser.parse_args()
    rows = [
        validate_model(
            deck_key,
            model_dir=args.model_dir,
            min_games=max(0, args.min_games),
        )
        for deck_key in DECK_SPECS
    ]
    payload = {
        "valid": all(row["valid"] for row in rows),
        "required_eval_games": max(0, args.min_games),
        "models": rows,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if payload["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

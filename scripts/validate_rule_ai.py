"""Validate the deployed rules-AI policy and its mirror benchmark."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai.profiles import POLICY_VERSION
from engine.ai.training import DECK_SPECS


def _load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", default="data/ai_policies.json")
    parser.add_argument("--benchmark", default="data/ai_rule_benchmark.json")
    parser.add_argument("--min-eval-games", type=int, default=100)
    parser.add_argument("--min-benchmark-games", type=int, default=800)
    args = parser.parse_args()

    errors: list[str] = []
    policy = _load(args.policy)
    benchmark = _load(args.benchmark)
    schema = policy.get("schema") or {}
    if int(policy.get("version") or 0) != POLICY_VERSION:
        errors.append("policy_version_mismatch")
    if int(schema.get("rules_version") or 0) != RULES_SCHEMA_VERSION:
        errors.append("rules_schema_mismatch")
    if int(schema.get("action_version") or 0) != ACTION_SCHEMA_VERSION:
        errors.append("action_schema_mismatch")

    rows = []
    policies = policy.get("policies") or {}
    for deck_key in DECK_SPECS:
        deck_policy = policies.get(deck_key) or {}
        metadata = deck_policy.get("metadata") or {}
        evaluation = deck_policy.get("eval") or {}
        deck_errors = []
        if not bool(metadata.get("accepted")):
            deck_errors.append("not_accepted")
        if not isinstance(metadata.get("seed"), int):
            deck_errors.append("missing_seed")
        if int(evaluation.get("games") or 0) < max(0, args.min_eval_games):
            deck_errors.append("insufficient_eval_games")
        if metadata.get("selected_stage") not in {"trained", "baseline"}:
            deck_errors.append("invalid_selected_stage")
        if deck_errors:
            errors.extend(f"{deck_key}:{error}" for error in deck_errors)
        rows.append({
            "deck": deck_key,
            "valid": not deck_errors,
            "selected_stage": metadata.get("selected_stage"),
            "eval_games": int(evaluation.get("games") or 0),
        })

    summary = benchmark.get("summary") or {}
    if not bool(benchmark.get("mirror")):
        errors.append("benchmark_not_mirrored")
    if int(benchmark.get("games") or 0) < max(0, args.min_benchmark_games):
        errors.append("insufficient_benchmark_games")
    for metric in (
        "invalid_actions",
        "no_target_actions",
        "rule_exceptions",
        "decision_timeouts",
    ):
        if int(summary.get(metric) or 0) != 0:
            errors.append(metric)

    payload = {
        "valid": not errors,
        "errors": errors,
        "policy_path": str(Path(args.policy)),
        "benchmark_path": str(Path(args.benchmark)),
        "benchmark_games": int(benchmark.get("games") or 0),
        "average_decision_seconds": float(
            summary.get("average_decision_seconds") or 0.0
        ),
        "max_step_exhaustion_rate": float(
            summary.get("max_step_exhaustion_rate") or 0.0
        ),
        "decks": rows,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if payload["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

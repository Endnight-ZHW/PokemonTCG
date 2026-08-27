"""Fail-closed differential gate for native traditional-AI migration corpora."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from verify_native_gameplay_profile import _match_semantics


IDENTITY_FIELDS = (
    "deck",
    "seed",
    "seed_block",
    "seat",
    "forced_first_player",
    "matchup_key",
    "matchup_kind",
    "pair_key",
    "player_decks",
    "strategy_a_deck",
    "strategy_b_deck",
)

STRUCTURAL_FIELDS = (
    "invalid_actions",
    "rule_exceptions",
    "choice_failures",
    "deep_fallbacks",
    "emergency_fallbacks",
    "time_capped_decisions",
)


def _read(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict) or not isinstance(value.get("matches"), list):
        raise ValueError(f"invalid evaluation result: {path}")
    return value


def _identity(match: dict[str, Any]) -> dict[str, Any]:
    return {field: match.get(field) for field in IDENTITY_FIELDS}


def verify(
    oracle: dict[str, Any],
    candidate: dict[str, Any],
    minimum_games: int,
    minimum_transitions: int,
) -> dict[str, Any]:
    oracle_matches = oracle["matches"]
    candidate_matches = candidate["matches"]
    for name, rows in (
        ("oracle.matches", oracle_matches),
        ("candidate.matches", candidate_matches),
    ):
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                raise ValueError(f"{name}[{index}] must be an object")
    same_game_count = len(oracle_matches) == len(candidate_matches)
    identity_differences: list[int] = []
    semantic_differences: list[int] = []
    if same_game_count:
        for index, (expected, actual) in enumerate(
            zip(oracle_matches, candidate_matches, strict=True)
        ):
            if _identity(expected) != _identity(actual):
                identity_differences.append(index)
            if _match_semantics(expected) != _match_semantics(actual):
                semantic_differences.append(index)

    totals = {
        "actions": sum(int(row.get("actions", 0)) for row in candidate_matches),
        "choices": sum(int(row.get("choices", 0)) for row in candidate_matches),
        "decisions": sum(int(row.get("decisions", 0)) for row in candidate_matches),
        "turns": sum(int(row.get("turns", 0)) for row in candidate_matches),
    }
    structural = {
        field: sum(int(row.get(field, 0)) for row in candidate_matches)
        for field in STRUCTURAL_FIELDS
    }
    max_actions_exhausted = sum(
        1 for row in candidate_matches if bool(row.get("max_actions_exhausted", False))
    )
    transitions = totals["actions"] + totals["choices"]
    exact = (
        same_game_count
        and not identity_differences
        and not semantic_differences
    )
    clean = all(value == 0 for value in structural.values()) \
        and max_actions_exhausted == 0
    required_games = max(0, minimum_games)
    required_transitions = max(0, minimum_transitions)
    coverage = (
        len(candidate_matches) >= required_games
        and transitions >= required_transitions
    )
    return {
        "schema": "ptcg_native_migration_corpus_gate/1",
        "passed": exact and clean and coverage,
        "exact": exact,
        "clean": clean,
        "coverage_satisfied": coverage,
        "games": len(candidate_matches),
        "minimum_games": required_games,
        "transitions": transitions,
        "minimum_transitions": required_transitions,
        "totals": totals,
        "structural_failures": structural,
        "max_actions_exhausted": max_actions_exhausted,
        "identity_difference_count": len(identity_differences),
        "identity_difference_indices": identity_differences[:20],
        "semantic_difference_count": len(semantic_differences),
        "semantic_difference_indices": semantic_differences[:20],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--minimum-games", type=int, default=0)
    parser.add_argument("--minimum-transitions", type=int, default=0)
    args = parser.parse_args()
    try:
        result = verify(
            _read(args.oracle),
            _read(args.candidate),
            max(0, args.minimum_games),
            max(0, args.minimum_transitions),
        )
    except (OSError, TypeError, ValueError) as error:
        print(json.dumps({"passed": False, "error": str(error)}, ensure_ascii=False))
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if bool(result["passed"]) else 1


if __name__ == "__main__":
    sys.exit(main())

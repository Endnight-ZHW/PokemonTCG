"""Fair learner-vs-champion scheduling and statistics for Deep AI v3."""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from typing import Any, Iterable, Sequence

from .actor_v3 import GameTaskV3
from .evaluation_fairness import (
    SEAT_FIRST_PLAYER_CLOSURES,
    block_id as fairness_block_id,
    block_kind,
    canonical_hash,
    complete_strength_blocks,
    expected_block_size,
    ordered_matchups,
    paired_block_bootstrap_interval,
    paired_seed,
    record,
    sequential_promotion_status,
    standard_breakdowns,
)


DEEP_ARENA_SCHEMA = "ptcg.deep_ai.arena_evaluation/1"


@dataclass(frozen=True, slots=True)
class DeepArenaTaskSpec:
    task: GameTaskV3
    candidate_deck: str
    baseline_deck: str
    block_id: str
    block_size: int
    block_kind: str
    replicate: int
    closure: int


def deep_arena_task_specs(
    *,
    unordered_pairs: Sequence[tuple[str, str]],
    games_per_direction: int,
    base_seed: int,
    cycle: int,
    champion_version: int,
    look_index: int,
    max_decisions: int,
) -> list[DeepArenaTaskSpec]:
    closure_replicates = max(1, math.ceil(int(games_per_direction) / 4))
    specs: list[DeepArenaTaskSpec] = []
    for matchup_index, unordered_pair in enumerate(unordered_pairs):
        directions = ordered_matchups((unordered_pair,))
        for local_replicate in range(closure_replicates):
            replicate = int(look_index) * closure_replicates + local_replicate
            game_seed = paired_seed(
                base_seed,
                unordered_pair[0],
                unordered_pair[1],
                replicate,
                namespace="ptcg.deep_ai.arena_pair_seed/1",
            )
            identifier = fairness_block_id(
                unordered_pair[0],
                unordered_pair[1],
                game_seed,
                replicate,
                prefix=f"deep-v3-cycle-{int(cycle)}",
            )
            remaining = int(games_per_direction) - local_replicate * 4
            closure_count = min(4, max(0, remaining))
            for direction, (candidate_deck, baseline_deck) in enumerate(directions):
                for closure, (candidate_seat, first_player) in enumerate(
                    SEAT_FIRST_PLAYER_CLOSURES[:closure_count]
                ):
                    model_slots = [1, 1]
                    model_versions = [int(champion_version), int(champion_version)]
                    model_slots[candidate_seat] = 0
                    model_versions[candidate_seat] = int(cycle)
                    task = GameTaskV3(
                        (
                            f"arena-{int(cycle):04d}-l{int(look_index) + 1}"
                            f"-u{matchup_index:02d}-r{replicate:02d}"
                            f"-d{direction}-c{closure}"
                        ),
                        int(cycle),
                        candidate_deck,
                        baseline_deck,
                        game_seed,
                        candidate_seat,
                        first_player,
                        tuple(model_slots),
                        tuple(model_versions),
                        int(max_decisions),
                    )
                    specs.append(DeepArenaTaskSpec(
                        task=task,
                        candidate_deck=candidate_deck,
                        baseline_deck=baseline_deck,
                        block_id=identifier,
                        block_size=expected_block_size(
                            unordered_pair[0], unordered_pair[1]
                        ),
                        block_kind=block_kind(
                            unordered_pair[0], unordered_pair[1]
                        ),
                        replicate=replicate,
                        closure=closure,
                    ))
    return specs


def deep_arena_rows(
    games: Iterable[dict[str, Any]],
    specs: Iterable[DeepArenaTaskSpec],
) -> list[dict[str, Any]]:
    by_id = {spec.task.game_id: spec for spec in specs}
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for game in games:
        game_id = str(game.get("game_id", ""))
        spec = by_id.get(game_id)
        if spec is None:
            raise RuntimeError(f"v3_arena_unknown_result:{game_id}")
        if game_id in seen:
            raise RuntimeError(f"v3_arena_duplicate_result:{game_id}")
        seen.add(game_id)
        winner = int(game.get("winner", -1))
        eligible = (
            bool(game.get("success", False))
            and bool(game.get("terminal", False))
            and not bool(game.get("truncated", False))
        )
        score_x2 = 1 if winner < 0 else (2 if winner == spec.task.seat_a else 0)
        row = {
            **dict(game),
            "task_id": game_id,
            "candidate_deck": spec.candidate_deck,
            "baseline_deck": spec.baseline_deck,
            "candidate_seat": spec.task.seat_a,
            "game_seed": spec.task.seed,
            "block_id": spec.block_id,
            "block_size": spec.block_size,
            "block_kind": spec.block_kind,
            "replicate": spec.replicate,
            "closure": spec.closure,
            "candidate_score_x2": score_x2,
            "strength_eligible": eligible,
        }
        row["result_hash"] = canonical_hash(row)
        rows.append(row)
    if seen != set(by_id):
        missing = sorted(set(by_id) - seen)
        raise RuntimeError(
            "v3_arena_result_count_mismatch:"
            f"expected={len(by_id)}:actual={len(seen)}:"
            f"first_missing={missing[0] if missing else ''}"
        )
    return sorted(rows, key=lambda row: str(row["task_id"]))


def summarize_deep_arena(
    rows: list[dict[str, Any]],
    *,
    bootstrap_seed: int,
    bootstrap_samples: int,
    confidence_alpha: float,
    promotion_score_rate: float,
    final_look: bool,
) -> dict[str, Any]:
    strength, block_selection = complete_strength_blocks(rows)
    paired = paired_block_bootstrap_interval(
        rows,
        seed=bootstrap_seed,
        samples=bootstrap_samples,
        alpha=confidence_alpha,
    )
    structural_rows = [
        row for row in rows
        if not bool(row.get("success", False))
        and str(row.get("error", "")) != "v3_actor_decision_cap"
    ]
    truncated_rows = [
        row for row in rows
        if bool(row.get("truncated", False))
        or str(row.get("error", "")) == "v3_actor_decision_cap"
    ]
    reliability_passed = not structural_rows and not truncated_rows
    strength_status = sequential_promotion_status(
        paired,
        point_threshold=float(promotion_score_rate),
        final_look=final_look,
    )
    status = strength_status if reliability_passed else "fail"
    return {
        "schema": DEEP_ARENA_SCHEMA,
        "gate_status": status,
        "games": len(rows),
        "strength_games": len(strength),
        "record": record(strength),
        "paired_statistics": paired,
        "integrity": {
            "failed_games": sum(
                not bool(row.get("success", False)) for row in rows
            ),
            "structural_errors": len(structural_rows),
            "truncated_games": len(truncated_rows),
            "strength_blocks": block_selection,
            "structural_task_ids": sorted(
                str(row["task_id"]) for row in structural_rows
            ),
            "truncated_task_ids": sorted(
                str(row["task_id"]) for row in truncated_rows
            ),
        },
        "reliability": {
            "passed": reliability_passed,
            "structural_errors": len(structural_rows),
            "truncated_games": len(truncated_rows),
        },
        "breakdowns": standard_breakdowns(strength),
        "promotion": {
            "point_threshold": float(promotion_score_rate),
            "superiority_threshold": 0.5,
            "strength_status": strength_status,
            "passed": status == "pass",
        },
    }


def arena_promotion_passed(
    arena: dict[str, Any],
    *,
    legacy_threshold: float,
) -> bool:
    if str(arena.get("schema", "")) == DEEP_ARENA_SCHEMA:
        return str(arena.get("gate_status", "")) == "pass"
    score_rate = arena.get("score_rate")
    return bool(
        int(arena.get("failed_games", 1)) == 0
        and score_rate is not None
        and float(score_rate) >= float(legacy_threshold)
    )


def deep_arena_schedule_payload(
    specs: Iterable[DeepArenaTaskSpec],
) -> list[dict[str, Any]]:
    return [
        {
            **asdict(spec.task),
            "block_id": spec.block_id,
            "block_size": spec.block_size,
            "block_kind": spec.block_kind,
            "replicate": spec.replicate,
            "closure": spec.closure,
        }
        for spec in specs
    ]

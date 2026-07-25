"""Stable contracts shared by production Deep AI training and runtime export.

The legacy trainers intentionally remain available.  This module defines the
new, independent population trainer and Deep planner contracts so neither one
is accidentally tied to the traditional ``turn_beam_v2`` schema.
"""
from __future__ import annotations

import hashlib
import itertools
import json
from dataclasses import asdict, dataclass
from typing import Any, Iterable

from engine.ai.training import DECK_SPECS


TRAINER_HYBRID_POPULATION = "hybrid_population_rl"
HYBRID_POPULATION_TRAINER_VERSION = 1

DEEP_PLANNER_ID = "deep_root_ismcts_v1"
DEEP_PLANNER_SCHEMA_VERSION = 1
DEEP_PLANNER_CONSTANTS: dict[str, Any] = {
    "root_inference_calls": 1,
    "neural_prior_weight": 0.75,
    "challenge_prior_weight": 0.25,
    "simulations": 64,
    "c_puct": 1.4,
    "max_depth": 16,
    "opponent_branch_limit": 6,
    "watchdog_seconds": 2.0,
    "value_head_mode": "diagnostic_only",
    "leaf_evaluator": "challenge",
    "visit_tiebreak": "visits_prior_signature",
}

TRAINING_EVENT_SCHEMA = "training_event_v1"
RUN_FORMAT_VERSION = 1
CHECKPOINT_FORMAT_VERSION = 1
EVIDENCE_FORMAT_VERSION = 1

RELEASE_DECKS: tuple[str, ...] = tuple(DECK_SPECS.keys())
AI_SEED_FALLBACK = 0x6D2B79F5


def derive_deep_decision_seed(
    match_seed: int,
    revision: int,
    actor: int,
    ordinal: int,
) -> int:
    """Match Godot ``AIDecisionSeed`` for Deep ISMCTS simulations."""

    result = 2166136261

    def mix_byte(current: int, value: int) -> int:
        return ((current ^ value) * 16777619) & 0xFFFFFFFF

    def mix_int(current: int, value: int) -> int:
        normalized = int(value) & 0xFFFFFFFF
        for shift in (0, 8, 16, 24):
            current = mix_byte(
                current, (normalized >> shift) & 0xFF
            )
        return mix_byte(current, 0xFF)

    def mix_string(current: int, value: str) -> int:
        for byte in str(value).encode("utf-8"):
            current = mix_byte(current, byte)
        return mix_byte(current, 0xFF)

    for value in (match_seed, revision, actor):
        result = mix_int(result, int(value))
    result = mix_string(result, DEEP_PLANNER_ID)
    result = mix_string(result, f"simulation:{int(ordinal)}")
    return result or AI_SEED_FALLBACK


def derive_training_decision_seed(
    task_seed: int,
    revision: int,
    actor: int,
    decision_ordinal: int,
    purpose: str,
) -> int:
    """Derive a local training RNG seed without touching global RNG state."""

    wire = "|".join(
        (
            "deep-training-v1",
            str(int(task_seed)),
            str(int(revision)),
            str(int(actor)),
            str(int(decision_ordinal)),
            str(purpose),
        )
    ).encode("utf-8")
    return (
        int.from_bytes(hashlib.sha256(wire).digest()[:8], "big")
        & 0xFFFFFFFF
    ) or AI_SEED_FALLBACK


@dataclass(frozen=True)
class PopulationPreset:
    name: str
    decks: tuple[str, ...]
    teacher_games: int
    dagger_games: int
    generations: int
    games_per_matchup: int
    current_generation_games: int
    historical_games: int
    mcts_simulations: int
    rollout_workers: int
    batch_size: int
    max_steps: int
    rollout_batch_games: int
    use_amp: bool
    device: str
    teacher_search_preset: str
    promotable: bool

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["decks"] = list(self.decks)
        return result


RELEASE_PRESET = PopulationPreset(
    name="release",
    decks=RELEASE_DECKS,
    teacher_games=1000,
    dagger_games=1000,
    generations=5,
    games_per_matchup=20,
    current_generation_games=16,
    historical_games=4,
    mcts_simulations=64,
    rollout_workers=10,
    batch_size=256,
    max_steps=160,
    rollout_batch_games=20,
    use_amp=True,
    device="cuda",
    teacher_search_preset="quality",
    promotable=True,
)

SMOKE_PRESET = PopulationPreset(
    name="smoke",
    decks=(RELEASE_DECKS[0],),
    teacher_games=2,
    dagger_games=2,
    generations=1,
    games_per_matchup=2,
    current_generation_games=2,
    historical_games=0,
    mcts_simulations=1,
    rollout_workers=1,
    batch_size=8,
    max_steps=160,
    rollout_batch_games=2,
    use_amp=False,
    device="cpu",
    teacher_search_preset="fast",
    promotable=False,
)

RESEARCH2_PRESET = PopulationPreset(
    name="research2",
    decks=("steel", "darkness"),
    teacher_games=200,
    dagger_games=200,
    generations=2,
    games_per_matchup=8,
    current_generation_games=4,
    historical_games=4,
    mcts_simulations=64,
    rollout_workers=4,
    batch_size=128,
    max_steps=160,
    rollout_batch_games=8,
    use_amp=True,
    device="cuda",
    teacher_search_preset="quality",
    promotable=False,
)

RESEARCH10_PRESET = PopulationPreset(
    name="research10",
    decks=RELEASE_DECKS,
    teacher_games=200,
    dagger_games=200,
    generations=2,
    games_per_matchup=8,
    current_generation_games=4,
    historical_games=4,
    mcts_simulations=64,
    rollout_workers=10,
    batch_size=256,
    max_steps=160,
    rollout_batch_games=8,
    use_amp=True,
    device="cuda",
    teacher_search_preset="quality",
    promotable=False,
)

PRESETS: dict[str, PopulationPreset] = {
    RELEASE_PRESET.name: RELEASE_PRESET,
    SMOKE_PRESET.name: SMOKE_PRESET,
    RESEARCH2_PRESET.name: RESEARCH2_PRESET,
    RESEARCH10_PRESET.name: RESEARCH10_PRESET,
}


def preset_for(name: str) -> PopulationPreset:
    key = str(name or "").strip().lower()
    if key not in PRESETS:
        raise ValueError(f"Unknown hybrid population preset: {name!r}")
    return PRESETS[key]


@dataclass(frozen=True)
class PopulationTask:
    """One deterministic, auditable population game."""

    task_id: str
    generation: int
    matchup_index: int
    deck_a: str
    deck_b: str
    game_index: int
    seed_block: int
    seed: int
    seat_a: int
    forced_first_player: int
    opponent_kind: str
    history_generation: int | None
    history_side: str | None

    @property
    def matchup_key(self) -> str:
        return f"{self.deck_a}__{self.deck_b}"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _stable_int_seed(*parts: Any) -> int:
    wire = "|".join(str(part) for part in parts).encode("utf-8")
    # Stay inside the positive signed 31-bit range used by both runtimes.
    return int.from_bytes(hashlib.sha256(wire).digest()[:8], "big") % 2_147_483_647 or 1


def _task_id(payload: dict[str, Any]) -> str:
    wire = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "population:" + hashlib.sha256(wire).hexdigest()[:24]


def build_population_schedule(
    *,
    generation: int,
    decks: Iterable[str] = RELEASE_DECKS,
    base_seed: int = 17,
    games_per_matchup: int = 20,
    current_generation_games: int = 16,
    historical_games: int = 4,
) -> list[PopulationTask]:
    """Build a closed mirror/cross-deck schedule.

    Each four-game seed block covers both physical seats and both forced first
    players.  The release schedule therefore contains 45 cross-deck groups and
    10 mirrors, each with four current-current blocks and one history block.
    History generations rotate by matchup while each four-game block remains
    internally paired.
    """

    deck_keys = tuple(str(deck) for deck in decks)
    if not deck_keys or len(deck_keys) != len(set(deck_keys)):
        raise ValueError("Population schedule decks must be unique and non-empty")
    unknown = [deck for deck in deck_keys if deck not in RELEASE_DECKS]
    if unknown:
        raise ValueError(f"Unknown population decks: {', '.join(unknown)}")
    total = int(games_per_matchup)
    current = int(current_generation_games)
    historical = int(historical_games)
    if total <= 0 or current < 0 or historical < 0 or current + historical != total:
        raise ValueError("Current and historical games must exactly fill each matchup")
    # Full release blocks are four games.  Smoke deliberately uses one
    # seat-swapped two-game mini block to keep the end-to-end check fast.
    if total not in (2,) and total % 4:
        raise ValueError("games_per_matchup must be 2 (Smoke) or divisible by 4")
    if total == 2 and historical:
        raise ValueError("The two-game Smoke schedule cannot include history")
    if generation < 1:
        raise ValueError("generation must be positive")

    tasks: list[PopulationTask] = []
    matchups = list(itertools.combinations_with_replacement(deck_keys, 2))
    for matchup_index, (deck_a, deck_b) in enumerate(matchups):
        # Generation zero is the post-DAgger population snapshot.  It gives the
        # first RL generation a real historical opponent instead of silently
        # converting the four anti-forgetting games into current-current games.
        available = min(3, generation)
        history_generation: int | None = (
            generation - 1 - (matchup_index % available)
            if historical > 0 and available > 0
            else None
        )
        for game_index in range(total):
            if total == 2:
                block_index = 0
                seat_a = game_index
                forced_first = game_index
            else:
                block_index = game_index // 4
                within_block = game_index % 4
                seat_a = within_block % 2
                forced_first = within_block // 2
            is_history = game_index >= current and history_generation is not None
            opponent_kind = "history" if is_history else "current"
            history_side: str | None = None
            if is_history:
                # Split each four-game historical block across both live
                # decks.  Games 0/1 train current A against historical B;
                # games 2/3 train current B against historical A.  Each live
                # side therefore occupies both physical seats and is first
                # once and second once.
                history_side = (
                    "b"
                    if (game_index - current) % 4 < 2
                    else "a"
                )
            seed = _stable_int_seed(
                "hybrid_population_rl",
                int(base_seed),
                int(generation),
                matchup_index,
                block_index,
                opponent_kind,
            )
            identity = {
                "generation": int(generation),
                "matchup_index": matchup_index,
                "deck_a": deck_a,
                "deck_b": deck_b,
                "game_index": game_index,
                "seed_block": block_index,
                "seed": seed,
                "seat_a": seat_a,
                "forced_first_player": forced_first,
                "opponent_kind": opponent_kind,
                "history_generation": history_generation if is_history else None,
                "history_side": history_side,
            }
            tasks.append(PopulationTask(task_id=_task_id(identity), **identity))
    return tasks


def validate_schedule_closure(
    tasks: Iterable[PopulationTask],
    *,
    expected_decks: Iterable[str] | None = None,
) -> dict[str, int]:
    """Validate matchup counts and paired seat/first-player closure."""

    rows = list(tasks)
    if not rows:
        raise ValueError("Population schedule is empty")
    by_matchup: dict[tuple[str, str], list[PopulationTask]] = {}
    task_ids: set[str] = set()
    for row in rows:
        if row.task_id in task_ids:
            raise ValueError(f"Duplicate population task ID: {row.task_id}")
        task_ids.add(row.task_id)
        by_matchup.setdefault((row.deck_a, row.deck_b), []).append(row)
    if expected_decks is not None:
        deck_keys = tuple(expected_decks)
        expected_groups = len(deck_keys) * (len(deck_keys) + 1) // 2
        if len(by_matchup) != expected_groups:
            raise ValueError(
                f"Expected {expected_groups} matchup groups, got {len(by_matchup)}"
            )
    for matchup, group in by_matchup.items():
        by_block: dict[tuple[int, str], list[PopulationTask]] = {}
        for row in group:
            by_block.setdefault((row.seed_block, row.opponent_kind), []).append(row)
        for block_key, block in by_block.items():
            seats = {row.seat_a for row in block}
            first_players = {row.forced_first_player for row in block}
            seeds = {row.seed for row in block}
            if len(seeds) != 1 or seats != {0, 1}:
                raise ValueError(f"Unclosed seat/seed block for {matchup} {block_key}")
            if len(block) == 4 and first_players != {0, 1}:
                raise ValueError(f"Unclosed first-player block for {matchup} {block_key}")
            if len(block) not in (2, 4):
                raise ValueError(f"Unexpected block size for {matchup} {block_key}: {len(block)}")
    mirrors = sum(1 for a, b in by_matchup if a == b)
    return {
        "tasks": len(rows),
        "matchups": len(by_matchup),
        "mirrors": mirrors,
        "cross_deck": len(by_matchup) - mirrors,
    }


def deep_planner_manifest(evidence_sha256: str = "") -> dict[str, Any]:
    result = {
        "schema_version": DEEP_PLANNER_SCHEMA_VERSION,
        "planner_id": DEEP_PLANNER_ID,
        **DEEP_PLANNER_CONSTANTS,
    }
    if evidence_sha256:
        result["evidence_sha256"] = str(evidence_sha256).lower()
    return result

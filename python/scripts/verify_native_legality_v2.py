#!/usr/bin/env python
"""Compare formal Python and native C++ legal actions on played states.

This is a fail-closed development/release evidence generator.  It advances
authoritative Python games, compares every action-root legal set with the C++
kernel, and resolves intervening choices through the formal engine.  Full
hidden state is intentionally used only by this offline parity tool; the
runtime training bridge keeps its stricter masked information-set boundary.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from collections import Counter
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import ptcg_ai_core

from engine.ai.dl.alphazero_v2 import (
    GameTask,
    _advance_nondecision_phase,
    _setup_game,
)
from engine.ai.dl.native_bridge_v2 import (
    _formal_action_key,
    _native_action_key,
    game_state_to_native_wire,
)
from engine.ai.dl.puct_v2 import PythonGameEnvironment, SearchCandidate
from engine.ai.dl.v2_contract import RELEASE_DECKS
from engine.ai.training import force_end_turn
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.snapshot import clone_state


def _key_text(key: tuple[Any, ...]) -> str:
    return repr(key)


def _apply_valid_choice(
    environment: PythonGameEnvironment,
    state: Any,
    rng: random.Random,
    seed: int,
) -> tuple[bool, str]:
    actor = environment.actor(state)
    candidates = list(environment.candidates(state, actor))
    rng.shuffle(candidates)
    errors: list[str] = []
    for candidate in candidates:
        probe = clone_state(state)
        try:
            environment.apply(probe, candidate, seed)
        except Exception as exc:
            if len(errors) < 3:
                errors.append(str(exc))
            continue
        environment.apply(state, candidate, seed)
        return True, ""
    return False, ";".join(errors)


def _task_for_game(index: int, seed: int, rng: random.Random) -> GameTask:
    first_index = rng.randrange(len(RELEASE_DECKS))
    second_index = rng.randrange(len(RELEASE_DECKS))
    return GameTask(
        game_id=f"native-legality-{index:05d}",
        generation=0,
        deck_a=RELEASE_DECKS[first_index],
        deck_b=RELEASE_DECKS[second_index],
        seed=seed + index * 104729,
        seat_a=index % 2,
        first_player=(index // 2) % 2,
    )


def audit(
    *,
    games: int,
    max_decisions: int,
    seed: int,
    detail_limit: int,
) -> dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[2]
    cards = json.loads(
        (repo_root / "godot" / "data" / "cards.json").read_text(
            encoding="utf-8"
        )
    )
    native = ptcg_ai_core.NativeGameKernel(cards)
    environment = PythonGameEnvironment()
    rng = random.Random(seed)
    mismatch_types: Counter[str] = Counter()
    states_by_deck: Counter[str] = Counter()
    details: list[dict[str, Any]] = []
    action_states = 0
    choices = 0
    completed_games = 0
    transition_errors = 0
    transition_error_details: list[dict[str, Any]] = []
    forced_turn_ends = 0

    for game_index in range(games):
        task = _task_for_game(game_index, seed, rng)
        state = _setup_game(task)
        for decision in range(max_decisions):
            while _advance_nondecision_phase(state):
                if state.is_terminal():
                    break
            if state.is_terminal():
                completed_games += 1
                break

            actor = environment.actor(state)
            request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
            decision_seed = task.seed + decision * 65537
            if request is not None:
                choices += 1
                applied, error = _apply_valid_choice(
                    environment,
                    state,
                    rng,
                    decision_seed,
                )
                if not applied:
                    transition_errors += 1
                    transition_error_details.append(
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "kind": "choice",
                            "request_type": request.request_type,
                            "request": repr(request),
                            "error": error,
                        }
                    )
                    break
                continue

            candidates = list(environment.candidates(state, actor))
            formal_by_key = {
                _formal_action_key(candidate.payload): candidate
                for candidate in candidates
            }
            wire = game_state_to_native_wire(state)
            native_by_key = {
                _native_action_key(row): row
                for row in native.legal_actions(wire, actor)
            }
            action_states += 1
            deck_key = str(state.public_deck_keys[actor])
            states_by_deck[deck_key] += 1

            missing = formal_by_key.keys() - native_by_key.keys()
            extra = native_by_key.keys() - formal_by_key.keys()
            for label, rows in (("missing", missing), ("extra", extra)):
                for key in rows:
                    mismatch_key = f"{label}:{_key_text(key)}"
                    mismatch_types[mismatch_key] += 1
                    if len(details) < detail_limit:
                        details.append(
                            {
                                "game_id": task.game_id,
                                "decision": decision,
                                "turn": int(state.turn_number),
                                "actor": actor,
                                "actor_deck": deck_key,
                                "opponent_deck": str(
                                    state.public_deck_keys[1 - actor]
                                ),
                                "difference": label,
                                "key": _key_text(key),
                                "formal": (
                                    repr(formal_by_key[key].payload)
                                    if key in formal_by_key
                                    else None
                                ),
                                "native": native_by_key.get(key),
                                "actor_state": wire["players"][actor],
                                "opponent_active": wire["players"][
                                    1 - actor
                                ]["active"],
                            }
                        )

            if not candidates:
                force_end_turn(state, actor)
                forced_turn_ends += 1
                continue
            selected: SearchCandidate = rng.choice(candidates)
            try:
                environment.apply(state, selected, decision_seed)
            except Exception as exc:
                transition_errors += 1
                transition_error_details.append(
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "kind": "action",
                        "candidate": repr(selected.payload),
                        "error": str(exc),
                    }
                )
                break

    return {
        "schema": "native_legality_v2_audit/1",
        "seed": seed,
        "requested_games": games,
        "completed_games": completed_games,
        "max_decisions": max_decisions,
        "action_states": action_states,
        "choice_states": choices,
        "states_by_deck": dict(sorted(states_by_deck.items())),
        "mismatch_occurrences": sum(mismatch_types.values()),
        "mismatch_type_count": len(mismatch_types),
        "mismatch_types": dict(mismatch_types.most_common()),
        "transition_errors": transition_errors,
        "transition_error_details": transition_error_details,
        "forced_turn_ends": forced_turn_ends,
        "details": details,
        "passed": not mismatch_types and transition_errors == 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--games", type=int, default=30)
    parser.add_argument("--max-decisions", type=int, default=64)
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--detail-limit", type=int, default=20)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.games <= 0 or args.max_decisions <= 0:
        parser.error("games and max-decisions must be positive")
    report = audit(
        games=args.games,
        max_decisions=args.max_decisions,
        seed=args.seed,
        detail_limit=max(0, args.detail_limit),
    )
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

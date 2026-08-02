#!/usr/bin/env python
"""Replay selected information-set audit roots with compact rule diagnostics."""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import ptcg_ai_core

from engine.ai.dl.alphazero_v2 import _advance_nondecision_phase, _setup_game
from engine.ai.dl.native_bridge_v2 import (
    _formal_action_key,
    _native_action_key,
    game_state_to_native_wire,
    mask_native_snapshot,
)
from engine.ai.dl.puct_v2 import PythonGameEnvironment
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.snapshot import clone_state
from scripts.verify_native_infoset_security_v2 import _runtime_root_wire, _task


def _parse_target(value: str) -> tuple[int, int]:
    game, separator, decision = value.partition(":")
    if not separator:
        raise argparse.ArgumentTypeError("target must be GAME:DECISION")
    return int(game), int(decision)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", action="append", type=_parse_target, required=True)
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--max-decisions", type=int, default=64)
    args = parser.parse_args()

    repo_root = PYTHON_ROOT.parent
    cards = json.loads(
        (repo_root / "godot/data/cards.json").read_text(encoding="utf-8")
    )
    decks = json.loads(
        (repo_root / "godot/data/decks.json").read_text(encoding="utf-8")
    )
    targets = set(args.target)
    last_game = max(game for game, _decision in targets)
    environment = PythonGameEnvironment()
    native_game = ptcg_ai_core.NativeGameKernel(cards)
    determinizer = ptcg_ai_core.NativeDeterminizer(decks)
    trajectory_rng = random.Random(args.seed)
    found: set[tuple[int, int]] = set()

    for game_index in range(last_game + 1):
        task = _task(game_index, args.seed)
        state = _setup_game(task)
        for decision in range(args.max_decisions):
            while _advance_nondecision_phase(state):
                if state.is_terminal():
                    break
            if state.is_terminal():
                break
            actor = environment.actor(state)
            formal_candidates = list(environment.candidates(state, actor))
            request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
            trajectory_seed = (task.seed + decision * 65537) & 0xFFFFFFFF

            if (game_index, decision) in targets:
                wire = game_state_to_native_wire(state)
                masked = mask_native_snapshot(_runtime_root_wire(wire), actor)
                determinization_seed = (
                    args.seed
                    ^ (game_index + 1) * 0x9E3779B9
                    ^ (decision + 1) * 0x85EBCA6B
                ) & 0xFFFFFFFF
                determined = determinizer.determinize(
                    masked,
                    actor,
                    determinization_seed,
                )
                formal_keys = sorted(
                    (
                        repr(_formal_action_key(candidate.payload))
                        for candidate in formal_candidates
                    )
                )
                native_rows = list(native_game.legal_actions(determined, actor))
                native_keys = sorted(
                    repr(_native_action_key(candidate))
                    for candidate in native_rows
                )
                owner = wire["players"][actor]
                determined_owner = determined["players"][actor]
                payload = {
                    "game": game_index,
                    "decision": decision,
                    "actor": actor,
                    "deck": state.public_deck_keys[actor],
                    "request_type": None if request is None else request.request_type,
                    "formal_keys": formal_keys,
                    "native_keys": native_keys,
                    "owner": {
                        "hand": owner.get("hand", []),
                        "active": owner.get("active"),
                        "bench": owner.get("bench", []),
                    },
                    "determined_owner": {
                        "hand": determined_owner.get("hand", []),
                        "active": determined_owner.get("active"),
                        "bench": determined_owner.get("bench", []),
                    },
                    "turn_number": wire.get("turn_number"),
                    "first_player_idx": wire.get("first_player_idx"),
                    "history_action_log": wire.get("action_log", [])[-16:],
                }
                print(json.dumps(payload, ensure_ascii=False, indent=2))
                found.add((game_index, decision))

            if request is not None:
                candidates = list(formal_candidates)
                trajectory_rng.shuffle(candidates)
                advanced = False
                for candidate in candidates:
                    probe = clone_state(state)
                    try:
                        environment.apply(probe, candidate, trajectory_seed)
                    except Exception:
                        continue
                    environment.apply(state, candidate, trajectory_seed)
                    advanced = True
                    break
                if not advanced:
                    break
            else:
                selected = trajectory_rng.choice(formal_candidates)
                try:
                    environment.apply(state, selected, trajectory_seed)
                except Exception:
                    break

    missing = sorted(targets - found)
    if missing:
        print(json.dumps({"missing": missing}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

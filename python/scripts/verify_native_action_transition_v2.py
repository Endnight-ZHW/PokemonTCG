#!/usr/bin/env python
"""Audit same-state, same-decision, same-xorshift Python/C++ transitions.

The audit covers action roots and every resulting native choice continuation.
It intentionally starts from full authoritative snapshots because it is an
offline rules-parity tool, not a runtime information-set boundary. Canonical
event payloads are compared at the Python/C++ boundary. Godot replay remains
separate release-gate work and is reported as incomplete rather than implied.
"""
from __future__ import annotations

import argparse
import copy
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

from engine.action_codec import serialize_choice_request
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
from engine.ai.dl.puct_v2 import PythonGameEnvironment
from engine.ai.dl.v2_contract import RELEASE_DECKS
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.random_source import PortableRandomSourceV1
from engine.snapshot import clone_state


_NON_SEMANTIC_STATE_FIELDS = (
    "action_log",
    "resolution_stack",
    "setup_ready",
    "processed_action_ids",
)


def _normalize_state(source: dict[str, Any]) -> dict[str, Any]:
    payload = copy.deepcopy(source)
    for field in _NON_SEMANTIC_STATE_FIELDS:
        payload.pop(field, None)
    for player in payload.get("players", []):
        pokemon_rows = [player.get("active"), *player.get("bench", [])]
        for pokemon in pokemon_rows:
            if not isinstance(pokemon, dict):
                continue
            pokemon.setdefault("modifiers", [])
            abilities = pokemon.get("used_abilities")
            if isinstance(abilities, dict):
                pokemon["used_abilities"] = sorted(abilities)
    return payload


def _board_debug_projection(
    state: dict[str, Any],
) -> dict[str, Any]:
    """Keep enough public board detail to diagnose transition mismatches."""
    players = []
    for player in state.get("players", []):
        def pokemon(row):
            if not isinstance(row, dict):
                return None
            return {
                "card_id": row.get("card_id", ""),
                "damage_counters": row.get("damage_counters", 0),
                "energy_card_ids": row.get("energy_card_ids", []),
                "attached_tool_id": row.get("attached_tool_id", ""),
                "status_conditions": row.get("status_conditions", []),
                "used_abilities": row.get("used_abilities", []),
                "paralyzed_since_turn": row.get(
                    "paralyzed_since_turn",
                    0,
                ),
                "modifiers": row.get("modifiers", []),
            }

        players.append({
            "hand": list(player.get("hand", [])),
            "active": pokemon(player.get("active")),
            "bench": [
                pokemon(row)
                for row in player.get("bench", [])
            ],
        })
    return {
        "turn_number": state.get("turn_number", 0),
        "active_player_idx": state.get("active_player_idx", -1),
        "phase": state.get("phase", ""),
        "players": players,
    }


def _option_key(
    option: dict[str, Any],
    *,
    default_player: int,
) -> tuple[Any, ...]:
    ref = option.get("ref")
    row = ref if isinstance(ref, dict) else option
    kind = str(row.get("kind", ""))
    option_id = str(
        row.get("option_id", option.get("option_id", ""))
    )
    if (
        option_id
        and not any(
            row.get(field)
            for field in (
                "zone",
                "slot",
                "attachment_type",
                "card_id",
            )
        )
        and int(row.get("index", -1)) < 0
    ):
        kind = "id"
    return (
        kind,
        int(row.get("player", default_player)),
        str(row.get("zone", "")),
        str(row.get("slot", "")),
        int(row.get("index", -1)),
        str(row.get("attachment_type", "")),
        str(row.get("card_id", "")),
        (
            option_id
            if kind not in {"card", "pokemon", "slot", "attachment"}
            else ""
        ),
    )


def _pending_projection(
    pending: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if not pending:
        return None
    player = int(pending.get("player", -1))
    options = pending.get("options", [])
    if not isinstance(options, list):
        options = []
    maximum = int(pending.get("max_select", 0))
    return {
        "player": player,
        "min_select": int(pending.get("min_select", 0)),
        "max_select": maximum,
        "allow_duplicates": (
            bool(pending.get("allow_duplicates", False))
            if maximum > 1
            else False
        ),
        "can_cancel": bool(pending.get("can_cancel", False)),
        "options": sorted(
            _option_key(option, default_player=player)
            for option in options
            if isinstance(option, dict)
        ),
    }


def _native_selected_options(
    formal_pending: dict[str, Any],
    native_pending: dict[str, Any],
    response: Any,
) -> list[dict[str, Any]]:
    if bool(response.cancelled):
        return []
    formal_options = {
        str(option.get("option_id", "")): option
        for option in formal_pending.get("options", [])
        if isinstance(option, dict)
    }
    available = [
        option
        for option in native_pending.get("options", [])
        if isinstance(option, dict)
    ]
    selected: list[dict[str, Any]] = []
    for option_id in response.option_ids:
        formal_option = formal_options.get(str(option_id))
        if formal_option is None:
            raise ValueError(
                f"formal_choice_option_missing:{option_id}"
            )
        wanted = _option_key(
            formal_option,
            default_player=int(formal_pending.get("player", -1)),
        )
        wanted_option_id = str(formal_option.get("option_id", ""))
        match_index = next(
            (
                index
                for index, option in enumerate(available)
                if (
                    wanted_option_id
                    and str(option.get("option_id", ""))
                        == wanted_option_id
                )
            ),
            -1,
        )
        if match_index < 0:
            match_index = next(
                (
                    index
                    for index, option in enumerate(available)
                    if _option_key(
                        option,
                        default_player=int(
                            native_pending.get("player", -1)
                        ),
                    ) == wanted
                ),
                -1,
            )
        if match_index < 0:
            raise ValueError(
                "native_choice_option_missing:"
                + repr(wanted)
            )
        selected.append(copy.deepcopy(available[match_index]))
        if not bool(formal_pending.get("allow_duplicates", False)):
            available.pop(match_index)
    return selected


def _first_difference(
    expected: Any,
    actual: Any,
    path: str = "",
) -> dict[str, Any] | None:
    if type(expected) is not type(actual):
        return {
            "path": path,
            "expected_type": type(expected).__name__,
            "actual_type": type(actual).__name__,
            "expected": expected,
            "actual": actual,
        }
    if isinstance(expected, dict):
        for key in sorted(set(expected) | set(actual)):
            child = f"{path}.{key}" if path else str(key)
            if key not in expected:
                return {
                    "path": child,
                    "expected": "<missing>",
                    "actual": actual[key],
                }
            if key not in actual:
                return {
                    "path": child,
                    "expected": expected[key],
                    "actual": "<missing>",
                }
            difference = _first_difference(
                expected[key],
                actual[key],
                child,
            )
            if difference is not None:
                return difference
        return None
    if isinstance(expected, list):
        if len(expected) != len(actual):
            return {
                "path": f"{path}.length",
                "expected": len(expected),
                "actual": len(actual),
            }
        for index, (left, right) in enumerate(zip(expected, actual)):
            difference = _first_difference(
                left,
                right,
                f"{path}[{index}]",
            )
            if difference is not None:
                return difference
        return None
    if expected != actual:
        return {
            "path": path,
            "expected": expected,
            "actual": actual,
        }
    return None


def _task(index: int, seed: int) -> GameTask:
    return GameTask(
        game_id=f"native-action-transition-{index:05d}",
        generation=0,
        deck_a=RELEASE_DECKS[index % len(RELEASE_DECKS)],
        deck_b=RELEASE_DECKS[(index + 3) % len(RELEASE_DECKS)],
        seed=seed + index * 104729,
        seat_a=index % 2,
        first_player=(index // 2) % 2,
    )


def _advance_formal_choice(
    environment: PythonGameEnvironment,
    state: Any,
    rng: random.Random,
    seed: int,
) -> tuple[bool, str]:
    candidates = list(environment.candidates(state, environment.actor(state)))
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


def audit(
    *,
    games: int,
    max_decisions: int,
    seed: int,
    detail_limit: int,
    start_index: int = 0,
) -> dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[2]
    cards = json.loads(
        (repo_root / "godot" / "data" / "cards.json").read_text(
            encoding="utf-8"
        )
    )
    native = ptcg_ai_core.NativeGameKernel(cards)
    environment = PythonGameEnvironment()
    trajectory_rng = random.Random(seed)

    action_states = 0
    transitions = 0
    pending_transitions = 0
    formal_choice_states = 0
    completed_games = 0
    decision_limit_trajectories = 0
    legality_mismatches = 0
    apply_mismatches = 0
    state_mismatches = 0
    rng_mismatches = 0
    pending_shape_mismatches = 0
    choice_transitions = 0
    choice_apply_mismatches = 0
    choice_state_mismatches = 0
    choice_rng_mismatches = 0
    choice_pending_shape_mismatches = 0
    choice_mapping_errors = 0
    choice_depth_exhaustions = 0
    action_event_payload_mismatches = 0
    choice_event_payload_mismatches = 0
    event_payload_transitions = 0
    trajectory_errors = 0
    states_by_deck: Counter[str] = Counter()
    actions_by_kind: Counter[str] = Counter()
    formal_events: Counter[str] = Counter()
    native_events: Counter[str] = Counter()
    native_canonical_events: Counter[str] = Counter()
    request_type_pairs: Counter[str] = Counter()
    details: list[dict[str, Any]] = []

    def record(kind: str, payload: dict[str, Any]) -> None:
        if len(details) < detail_limit:
            details.append({"kind": kind, **payload})

    def audit_choice_chain(
        *,
        formal_state: Any,
        native_result: dict[str, Any],
        formal_pending: dict[str, Any],
        native_pending: dict[str, Any],
        action_context: dict[str, Any],
        transition_seed: int,
        max_depth: int = 8,
    ) -> None:
        nonlocal choice_transitions
        nonlocal choice_apply_mismatches
        nonlocal choice_state_mismatches
        nonlocal choice_rng_mismatches
        nonlocal choice_pending_shape_mismatches
        nonlocal choice_mapping_errors
        nonlocal choice_depth_exhaustions
        nonlocal choice_event_payload_mismatches
        nonlocal event_payload_transitions

        current_formal_state = clone_state(formal_state)
        current_native_state = copy.deepcopy(native_result["state"])
        current_continuation = copy.deepcopy(
            native_result.get("continuation", {})
        )
        current_formal_pending = formal_pending
        current_native_pending = native_pending
        current_rng = int(native_result.get("rng_state", 0))

        for choice_depth in range(max_depth):
            request = DEFAULT_GAME_ENGINE.pending_choice_request(
                current_formal_state
            )
            if request is None:
                if current_native_pending:
                    choice_pending_shape_mismatches += 1
                    record(
                        "choice_pending_shape_mismatch",
                        {
                            **action_context,
                            "choice_depth": choice_depth,
                            "formal_projection": None,
                            "native_projection": _pending_projection(
                                current_native_pending
                            ),
                        },
                    )
                return
            if not current_native_pending:
                choice_pending_shape_mismatches += 1
                record(
                    "choice_pending_shape_mismatch",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "formal_projection": _pending_projection(
                            current_formal_pending
                        ),
                        "native_projection": None,
                    },
                )
                return

            candidates = list(
                environment.candidates(
                    current_formal_state,
                    int(request.player),
                )
            )
            if not candidates:
                choice_mapping_errors += 1
                record(
                    "choice_candidate_error",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "error": "no_formal_choice_candidate",
                    },
                )
                return
            offset = (
                transition_seed + choice_depth
            ) % len(candidates)
            candidates = candidates[offset:] + candidates[:offset]

            formal_step = None
            formal_next_state = None
            formal_rng = None
            response = None
            for candidate in candidates:
                probe = clone_state(current_formal_state)
                probe_rng = PortableRandomSourceV1(current_rng)
                step = DEFAULT_GAME_ENGINE.apply_choice(
                    probe,
                    candidate.payload,
                    probe_rng,
                )
                if step.success:
                    formal_step = step
                    formal_next_state = probe
                    formal_rng = probe_rng.get_state()
                    response = candidate.payload
                    break
            if (
                formal_step is None
                or formal_next_state is None
                or formal_rng is None
                or response is None
            ):
                choice_mapping_errors += 1
                record(
                    "choice_candidate_error",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "error": "no_portable_choice_candidate",
                    },
                )
                return

            try:
                selected_options = _native_selected_options(
                    current_formal_pending,
                    current_native_pending,
                    response,
                )
            except Exception as exc:
                choice_mapping_errors += 1
                record(
                    "choice_mapping_error",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "response": {
                            "option_ids": list(response.option_ids),
                            "cancelled": bool(response.cancelled),
                        },
                        "error": str(exc),
                        "formal_pending": current_formal_pending,
                        "native_pending": current_native_pending,
                    },
                )
                return

            resumed = native.resume_choice(
                current_native_state,
                current_continuation,
                selected_options,
                bool(response.cancelled),
                current_rng,
            )
            choice_transitions += 1
            native_success = bool(resumed.get("success", False))
            if not native_success:
                choice_apply_mismatches += 1
                record(
                    "choice_apply_mismatch",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "formal_success": True,
                        "native_success": False,
                        "native_error": resumed.get("error_code", ""),
                        "response": {
                            "option_ids": list(response.option_ids),
                            "cancelled": bool(response.cancelled),
                        },
                    },
                )
                return

            formal_event_payload = list(
                getattr(formal_step, "events", ())
            )
            native_event_payload = list(resumed.get("events", ()))
            event_payload_transitions += 1
            formal_events.update(
                str(row.get("event_type", ""))
                for row in formal_event_payload
                if isinstance(row, dict) and row.get("event_type")
            )
            native_events.update(resumed.get("event_types", ()))
            native_canonical_events.update(
                str(row.get("event_type", ""))
                for row in native_event_payload
                if isinstance(row, dict) and row.get("event_type")
            )
            event_difference = _first_difference(
                formal_event_payload,
                native_event_payload,
            )
            if event_difference is not None:
                choice_event_payload_mismatches += 1
                record(
                    "event_payload_mismatch",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "difference": event_difference,
                        "formal_events": formal_event_payload,
                        "native_events": native_event_payload,
                        "native_event_types": list(
                            resumed.get("event_types", ())
                        ),
                    },
                )

            native_rng = int(resumed.get("rng_state", -1))
            if formal_rng != native_rng:
                choice_rng_mismatches += 1
                record(
                    "choice_rng_mismatch",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "formal_rng": formal_rng,
                        "native_rng": native_rng,
                        "response_option_ids": list(
                            response.option_ids
                        ),
                        "native_selected_options": selected_options,
                        "formal_pending_before": current_formal_pending,
                    },
                )

            formal_wire = _normalize_state(
                game_state_to_native_wire(formal_next_state)
            )
            native_wire = _normalize_state(resumed["state"])
            difference = _first_difference(
                formal_wire,
                native_wire,
            )
            if difference is not None:
                choice_state_mismatches += 1
                record(
                    "choice_state_mismatch",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "difference": difference,
                        "response_option_ids": list(
                            response.option_ids
                        ),
                        "native_selected_options": selected_options,
                        "formal_pending_before": current_formal_pending,
                        "input_rng": current_rng,
                        "input_decks": [
                            list(player.get("deck", ()))
                            for player in current_native_state.get(
                                "players",
                                (),
                            )
                        ],
                        "input_hands": [
                            list(player.get("hand", ()))
                            for player in current_native_state.get(
                                "players",
                                (),
                            )
                        ],
                        "formal_decks": [
                            list(player.get("deck", ()))
                            for player in formal_wire.get("players", ())
                        ],
                        "native_decks": [
                            list(player.get("deck", ()))
                            for player in native_wire.get("players", ())
                        ],
                        "formal_hand_sizes": [
                            len(player.get("hand", ()))
                            for player in formal_wire.get("players", ())
                        ],
                        "native_hand_sizes": [
                            len(player.get("hand", ()))
                            for player in native_wire.get("players", ())
                        ],
                        "formal_hands": [
                            list(player.get("hand", ()))
                            for player in formal_wire.get("players", ())
                        ],
                        "native_hands": [
                            list(player.get("hand", ()))
                            for player in native_wire.get("players", ())
                        ],
                        "formal_events": list(
                            getattr(formal_step, "events", ())
                        ),
                        "native_continuation": current_continuation,
                        "native_event_types": list(
                            resumed.get("event_types", ())
                        ),
                        "formal_board": _board_debug_projection(
                            formal_wire
                        ),
                        "native_board": _board_debug_projection(
                            native_wire
                        ),
                    },
                )

            formal_request = (
                DEFAULT_GAME_ENGINE.pending_choice_request(
                    formal_next_state
                )
            )
            formal_next_pending = (
                serialize_choice_request(formal_request)
                if formal_request is not None
                else None
            )
            native_next_pending = resumed.get("pending") or None
            formal_projection = _pending_projection(
                formal_next_pending
            )
            native_projection = _pending_projection(
                native_next_pending
            )
            if formal_projection != native_projection:
                choice_pending_shape_mismatches += 1
                record(
                    "choice_pending_shape_mismatch",
                    {
                        **action_context,
                        "choice_depth": choice_depth,
                        "request_type": request.request_type,
                        "formal_projection": formal_projection,
                        "native_projection": native_projection,
                        "formal_pending": formal_next_pending,
                        "native_pending": native_next_pending,
                        "difference": _first_difference(
                            formal_projection,
                            native_projection,
                        ),
                    },
                )
                return
            if difference is not None or formal_rng != native_rng:
                return
            if formal_next_pending is None:
                return

            current_formal_state = formal_next_state
            current_native_state = copy.deepcopy(resumed["state"])
            current_continuation = copy.deepcopy(
                resumed.get("continuation", {})
            )
            current_formal_pending = formal_next_pending
            current_native_pending = native_next_pending
            current_rng = native_rng

        choice_depth_exhaustions += 1
        record(
            "choice_depth_exhaustion",
            {
                **action_context,
                "max_depth": max_depth,
                "request_type": current_formal_pending.get(
                    "request_type",
                    "",
                ),
            },
        )

    for local_game_index in range(games):
        game_index = start_index + local_game_index
        task = _task(game_index, seed)
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
            trajectory_seed = (
                task.seed + decision * 65537
            ) & 0xFFFFFFFF
            if request is not None:
                formal_choice_states += 1
                applied, error = _advance_formal_choice(
                    environment,
                    state,
                    trajectory_rng,
                    trajectory_seed,
                )
                if not applied:
                    trajectory_errors += 1
                    record(
                        "trajectory_choice_error",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "request_type": request.request_type,
                            "error": error,
                        },
                    )
                    break
                continue

            formal_candidates = list(environment.candidates(state, actor))
            formal_by_key = {
                _formal_action_key(candidate.payload): candidate
                for candidate in formal_candidates
            }
            wire = game_state_to_native_wire(state)
            native_by_key = {
                _native_action_key(row): row
                for row in native.legal_actions(wire, actor)
            }
            action_states += 1
            states_by_deck[str(state.public_deck_keys[actor])] += 1

            if formal_by_key.keys() != native_by_key.keys():
                missing = sorted(
                    formal_by_key.keys() - native_by_key.keys(),
                    key=repr,
                )
                extra = sorted(
                    native_by_key.keys() - formal_by_key.keys(),
                    key=repr,
                )
                legality_mismatches += len(missing) + len(extra)
                record(
                    "legality_mismatch",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                        "missing": [repr(row) for row in missing],
                        "extra": [repr(row) for row in extra],
                        "input_board": _board_debug_projection(
                            _normalize_state(wire)
                        ),
                    },
                )

            for action_index, key in enumerate(
                sorted(
                    formal_by_key.keys() & native_by_key.keys(),
                    key=repr,
                )
            ):
                actor_player = wire["players"][actor]
                active = actor_player.get("active") or {}
                action_context: dict[str, Any] = {
                    "game_id": task.game_id,
                    "decision": decision,
                    "actor": actor,
                    "actor_deck": str(state.public_deck_keys[actor]),
                    "active_card_id": str(active.get("card_id", "")),
                    "action": repr(key),
                }
                if key[0] == "PLAY_TRAINER":
                    hand_index = int(
                        formal_by_key[key].payload.params.get(
                            "hand_idx",
                            -1,
                        )
                    )
                    hand = actor_player.get("hand", [])
                    action_context["trainer_card_id"] = (
                        str(hand[hand_index])
                        if 0 <= hand_index < len(hand)
                        else ""
                    )
                elif key[0] == "DECLARE_ATTACK":
                    attack_index = int(
                        formal_by_key[key].payload.params.get(
                            "attack_idx",
                            -1,
                        )
                    )
                    definition = cards.get(
                        action_context["active_card_id"],
                        {},
                    )
                    attacks = definition.get("attacks", [])
                    action_context["attack_name"] = (
                        str(attacks[attack_index].get("name", ""))
                        if 0 <= attack_index < len(attacks)
                        else ""
                    )
                transition_seed = (
                    0x9E3779B9
                    + game_index * 99991
                    + decision * 257
                    + action_index
                ) & 0xFFFFFFFF
                formal_state = clone_state(state)
                portable_rng = PortableRandomSourceV1(transition_seed)
                formal_step = DEFAULT_GAME_ENGINE.apply_action(
                    formal_state,
                    formal_by_key[key].payload,
                    portable_rng,
                    auto_resolve=False,
                    auto_finish_attack=True,
                )
                native_result = native.apply_action(
                    wire,
                    native_by_key[key],
                    transition_seed,
                )
                transitions += 1
                action_kind = str(key[0])
                actions_by_kind[action_kind] += 1
                formal_events.update(
                    str(row.get("event_type", ""))
                    for row in formal_step.events
                    if row.get("event_type")
                )
                native_events.update(native_result.get("event_types", []))
                formal_event_payload = list(formal_step.events)
                native_event_payload = list(
                    native_result.get("events", ())
                )
                event_payload_transitions += 1
                native_canonical_events.update(
                    str(row.get("event_type", ""))
                    for row in native_event_payload
                    if isinstance(row, dict) and row.get("event_type")
                )
                event_difference = _first_difference(
                    formal_event_payload,
                    native_event_payload,
                )
                if event_difference is not None:
                    action_event_payload_mismatches += 1
                    record(
                        "event_payload_mismatch",
                        {
                            **action_context,
                            "difference": event_difference,
                            "formal_events": formal_event_payload,
                            "native_events": native_event_payload,
                            "native_event_types": list(
                                native_result.get("event_types", ())
                            ),
                        },
                    )

                native_success = bool(native_result.get("success", False))
                if bool(formal_step.success) != native_success:
                    apply_mismatches += 1
                    record(
                        "apply_mismatch",
                        {
                            **action_context,
                            "formal_success": bool(formal_step.success),
                            "formal_error": formal_step.error_code,
                            "native_success": native_success,
                            "native_error": native_result.get(
                                "error_code",
                                "",
                            ),
                        },
                    )
                    continue
                if not formal_step.success:
                    continue

                formal_rng = portable_rng.get_state()
                native_rng = int(native_result.get("rng_state", -1))
                if formal_rng != native_rng:
                    rng_mismatches += 1
                    record(
                        "rng_mismatch",
                        {
                            **action_context,
                            "seed": transition_seed,
                            "formal_rng": formal_rng,
                            "native_rng": native_rng,
                        },
                    )

                formal_wire = _normalize_state(
                    game_state_to_native_wire(formal_state)
                )
                native_wire = _normalize_state(native_result["state"])
                difference = _first_difference(formal_wire, native_wire)
                if difference is not None:
                    state_mismatches += 1
                    record(
                        "state_mismatch",
                        {
                            **action_context,
                            "difference": difference,
                            "input_board": _board_debug_projection(
                                _normalize_state(wire)
                            ),
                            "formal_board": _board_debug_projection(
                                formal_wire
                            ),
                            "native_board": _board_debug_projection(
                                native_wire
                            ),
                        },
                    )

                formal_pending_request = (
                    DEFAULT_GAME_ENGINE.pending_choice_request(
                        formal_state
                    )
                )
                formal_pending = (
                    serialize_choice_request(formal_pending_request)
                    if formal_pending_request is not None
                    else None
                )
                native_pending = native_result.get("pending") or None
                if formal_pending is not None or native_pending is not None:
                    pending_transitions += 1
                    request_type_pairs[
                        (
                            str(
                                formal_pending.get("request_type", "<none>")
                                if formal_pending
                                else "<none>"
                            )
                            + " -> "
                            + str(
                                native_pending.get(
                                    "request_type",
                                    "<none>",
                                )
                                if native_pending
                                else "<none>"
                            )
                        )
                    ] += 1
                formal_projection = _pending_projection(formal_pending)
                native_projection = _pending_projection(native_pending)
                if formal_projection != native_projection:
                    pending_shape_mismatches += 1
                    record(
                        "pending_shape_mismatch",
                        {
                            **action_context,
                            "formal_request_type": (
                                formal_pending.get("request_type")
                                if formal_pending
                                else None
                            ),
                            "native_request_type": (
                                native_pending.get("request_type")
                                if native_pending
                                else None
                            ),
                            "formal_projection": formal_projection,
                            "native_projection": native_projection,
                            "formal_pending": formal_pending,
                            "native_pending": native_pending,
                            "difference": _first_difference(
                                formal_projection,
                                native_projection,
                            ),
                            "input_board": _board_debug_projection(
                                _normalize_state(wire)
                            ),
                            "formal_board": _board_debug_projection(
                                formal_wire
                            ),
                            "native_board": _board_debug_projection(
                                native_wire
                            ),
                        },
                    )
                elif (
                    formal_pending is not None
                    and native_pending is not None
                    and difference is None
                    and formal_rng == native_rng
                ):
                    audit_choice_chain(
                        formal_state=formal_state,
                        native_result=native_result,
                        formal_pending=formal_pending,
                        native_pending=native_pending,
                        action_context=action_context,
                        transition_seed=transition_seed,
                    )

            if not formal_candidates:
                trajectory_errors += 1
                record(
                    "trajectory_no_action",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                        "actor_deck": str(state.public_deck_keys[actor]),
                        "active_card_id": str(
                            (
                                game_state_to_native_wire(state)[
                                    "players"
                                ][actor].get("active")
                                or {}
                            ).get("card_id", "")
                        ),
                        "phase": str(state.phase),
                        "active_player_idx": int(
                            state.active_player_idx
                        ),
                        "pending_promotion_player": int(
                            state.pending_promotion_player
                        ),
                        "pending_promotions": list(
                            game_state_to_native_wire(state).get(
                                "pending_promotions",
                                [],
                            )
                        ),
                        "winner": state.winner,
                        "result_status": str(state.result_status),
                    },
                )
                break
            selected = trajectory_rng.choice(formal_candidates)
            try:
                environment.apply(state, selected, trajectory_seed)
            except Exception as exc:
                trajectory_errors += 1
                record(
                    "trajectory_action_error",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "action": repr(selected.payload),
                        "error": str(exc),
                    },
                )
                break
        else:
            decision_limit_trajectories += 1

    action_scope_passed = not any(
        (
            legality_mismatches,
            apply_mismatches,
            state_mismatches,
            rng_mismatches,
            pending_shape_mismatches,
            action_event_payload_mismatches,
            trajectory_errors,
        )
    )
    choice_scope_passed = not any(
        (
            choice_apply_mismatches,
            choice_state_mismatches,
            choice_rng_mismatches,
            choice_pending_shape_mismatches,
            choice_mapping_errors,
            choice_depth_exhaustions,
            choice_event_payload_mismatches,
        )
    )
    scope_passed = action_scope_passed and choice_scope_passed
    return {
        "schema": "native_action_transition_v2_audit/3",
        "scope": "python_cpp_action_choice_event_roots",
        "seed": seed,
        "start_index": start_index,
        "requested_games": games,
        "completed_games": completed_games,
        "decision_limit_trajectories": decision_limit_trajectories,
        "max_decisions": max_decisions,
        "action_states": action_states,
        "transitions": transitions,
        "pending_transitions": pending_transitions,
        "formal_choice_states": formal_choice_states,
        "states_by_deck": dict(sorted(states_by_deck.items())),
        "actions_by_kind": dict(sorted(actions_by_kind.items())),
        "legality_mismatches": legality_mismatches,
        "apply_mismatches": apply_mismatches,
        "state_mismatches": state_mismatches,
        "rng_mismatches": rng_mismatches,
        "pending_shape_mismatches": pending_shape_mismatches,
        "choice_transitions": choice_transitions,
        "choice_apply_mismatches": choice_apply_mismatches,
        "choice_state_mismatches": choice_state_mismatches,
        "choice_rng_mismatches": choice_rng_mismatches,
        "choice_pending_shape_mismatches": (
            choice_pending_shape_mismatches
        ),
        "choice_mapping_errors": choice_mapping_errors,
        "choice_depth_exhaustions": choice_depth_exhaustions,
        "trajectory_errors": trajectory_errors,
        "request_type_pairs": dict(request_type_pairs.most_common()),
        "formal_event_types": dict(formal_events.most_common()),
        "native_event_types": dict(native_events.most_common()),
        "native_canonical_event_types": dict(
            native_canonical_events.most_common()
        ),
        "event_payload_transitions": event_payload_transitions,
        "action_event_payload_mismatches": (
            action_event_payload_mismatches
        ),
        "choice_event_payload_mismatches": (
            choice_event_payload_mismatches
        ),
        "event_payload_mismatches": (
            action_event_payload_mismatches
            + choice_event_payload_mismatches
        ),
        "event_contract_status": (
            "passed"
            if (
                action_event_payload_mismatches
                + choice_event_payload_mismatches
            ) == 0
            else "failed"
        ),
        "choice_continuation_status": (
            "passed" if choice_scope_passed else "failed"
        ),
        "godot_replay_status": "not_in_action_root_scope",
        "action_scope_passed": action_scope_passed,
        "choice_scope_passed": choice_scope_passed,
        "scope_passed": scope_passed,
        "release_gate_complete": False,
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--games", type=int, default=30)
    parser.add_argument("--max-decisions", type=int, default=64)
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--detail-limit", type=int, default=30)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="write the report without printing the full JSON payload",
    )
    args = parser.parse_args()
    if args.games <= 0 or args.max_decisions <= 0:
        parser.error("games and max-decisions must be positive")
    report = audit(
        games=args.games,
        max_decisions=args.max_decisions,
        seed=args.seed,
        detail_limit=max(0, args.detail_limit),
        start_index=max(0, args.start_index),
    )
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
    if not args.quiet:
        print(payload)
    return 0 if report["scope_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

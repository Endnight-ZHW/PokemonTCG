#!/usr/bin/env python
"""Audit AlphaZero v2 hidden-information invariance at the native boundary.

This is an information-set safety audit, not a rules-transition audit.  For
every sampled action or choice root it creates authoritative state variants
whose hidden card identities or ordering differ while the acting player's
observation remains unchanged.  The Python ABI mask, C++ information-set
projection, tree key, determinization, legal candidates and encoder tensors
must remain identical.
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

import numpy as np


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import ptcg_ai_core

from engine.action_codec import serialize_choice_view
from engine.ai.dl.alphazero_v2 import (
    GameTask,
    _advance_nondecision_phase,
    _setup_game,
)
from engine.ai.dl.native_bridge_v2 import (
    HIDDEN_CARD,
    HIDDEN_PRIZE,
    _formal_action_key,
    _native_action_key,
    _native_choice_view,
    game_state_to_native_wire,
    mask_native_snapshot,
)
from engine.ai.dl.puct_v2 import PythonGameEnvironment
from engine.ai.dl.v2_contract import RELEASE_DECKS
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.snapshot import clone_state


def _task(index: int, seed: int) -> GameTask:
    return GameTask(
        game_id=f"native-infoset-security-{index:05d}",
        generation=0,
        deck_a=RELEASE_DECKS[index % len(RELEASE_DECKS)],
        deck_b=RELEASE_DECKS[(index + 3) % len(RELEASE_DECKS)],
        seed=seed + index * 104729,
        seat_a=index % 2,
        first_player=(index // 2) % 2,
    )


def _expanded_deck_counter(
    decks: dict[str, Any],
    deck_key: str,
) -> Counter[str]:
    definition = decks[deck_key]
    if isinstance(definition, list):
        return Counter(str(card_id) for card_id in definition)
    result: Counter[str] = Counter()
    for row in definition.get("cards", []):
        result[str(row["card_id"])] += int(row["count"])
    return result


def _physical_inventory(
    wire: dict[str, Any],
    player_index: int,
) -> Counter[str]:
    player = wire["players"][player_index]
    result: Counter[str] = Counter()
    for zone in ("hand", "deck", "discard", "prizes"):
        result.update(str(card_id) for card_id in player.get(zone, []))
    for pokemon in [player.get("active"), *player.get("bench", [])]:
        if not isinstance(pokemon, dict):
            continue
        card_id = str(pokemon.get("card_id", ""))
        if card_id:
            result[card_id] += 1
        result.update(
            str(card_id)
            for card_id in pokemon.get("evolution_stack_ids", [])
        )
        result.update(
            str(card_id)
            for card_id in pokemon.get("energy_card_ids", [])
        )
        tool = str(pokemon.get("attached_tool_id", ""))
        if tool:
            result[tool] += 1
    if int(wire.get("stadium_owner_idx", -1)) == player_index:
        stadium = str(wire.get("stadium_card_id", ""))
        if stadium:
            result[stadium] += 1
    return result


def _runtime_root_wire(wire: dict[str, Any]) -> dict[str, Any]:
    """Mirror the choice-root stack clearing performed by NativeSearchService."""
    result = copy.deepcopy(wire)
    stack = result.get("resolution_stack")
    if isinstance(stack, dict):
        result["resolution_stack"] = {
            "schema_version": int(stack.get("schema_version", 3)),
            "frames": [],
            "pending_request": None,
            "sequence": int(stack.get("sequence", 0)),
            "context": {},
        }
    return result


def _hidden_zone_rows(
    wire: dict[str, Any],
    actor: int,
) -> list[tuple[int, str]]:
    return [
        (actor, "deck"),
        (actor, "prizes"),
        (1 - actor, "hand"),
        (1 - actor, "deck"),
        (1 - actor, "prizes"),
    ]


def _identity_variant(
    wire: dict[str, Any],
    actor: int,
    nonce: str,
) -> tuple[dict[str, Any], int]:
    result = copy.deepcopy(wire)
    changed = 0
    for player_index, zone in _hidden_zone_rows(result, actor):
        cards = list(result["players"][player_index].get(zone, []))
        replacements = [
            f"__audit_hidden_{nonce}_{player_index}_{zone}_{index}__"
            for index in range(len(cards))
        ]
        changed += sum(
            left != right
            for left, right in zip(cards, replacements, strict=True)
        )
        result["players"][player_index][zone] = replacements
    bonus_rows = result.get("setup_bonus_card_ids")
    if isinstance(bonus_rows, list) and len(bonus_rows) == 2:
        opponent = 1 - actor
        cards = list(bonus_rows[opponent])
        replacements = [
            f"__audit_hidden_{nonce}_{opponent}_bonus_{index}__"
            for index in range(len(cards))
        ]
        changed += sum(
            left != right
            for left, right in zip(cards, replacements, strict=True)
        )
        bonus_rows[opponent] = replacements
    return result, changed


def _order_variant(
    wire: dict[str, Any],
    actor: int,
) -> tuple[dict[str, Any], int]:
    result = copy.deepcopy(wire)
    changed = 0
    for player_index, zone in _hidden_zone_rows(result, actor):
        cards = list(result["players"][player_index].get(zone, []))
        if len(cards) > 1:
            reordered = cards[1:] + cards[:1]
            if reordered == cards:
                reordered = list(reversed(cards))
            changed += sum(
                left != right
                for left, right in zip(cards, reordered, strict=True)
            )
            result["players"][player_index][zone] = reordered
    bonus_rows = result.get("setup_bonus_card_ids")
    if isinstance(bonus_rows, list) and len(bonus_rows) == 2:
        opponent = 1 - actor
        cards = list(bonus_rows[opponent])
        if len(cards) > 1:
            reordered = cards[1:] + cards[:1]
            changed += sum(
                left != right
                for left, right in zip(cards, reordered, strict=True)
            )
            bonus_rows[opponent] = reordered
    return result, changed


def _masked_hidden_zones_valid(
    wire: dict[str, Any],
    actor: int,
) -> bool:
    players = wire.get("players")
    if not isinstance(players, list) or len(players) != 2:
        return False
    for player_index, player in enumerate(players):
        if not isinstance(player, dict):
            return False
        if any(card != HIDDEN_CARD for card in player.get("deck", [])):
            return False
        if any(card != HIDDEN_PRIZE for card in player.get("prizes", [])):
            return False
        if (
            player_index != actor
            and any(card != HIDDEN_CARD for card in player.get("hand", []))
        ):
            return False
    bonus_rows = wire.get("setup_bonus_card_ids", [[], []])
    return (
        isinstance(bonus_rows, list)
        and len(bonus_rows) == 2
        and all(card == HIDDEN_CARD for card in bonus_rows[1 - actor])
    )


def _has_unmasked_hidden_identity(
    wire: dict[str, Any],
    actor: int,
) -> bool:
    for player_index, zone in _hidden_zone_rows(wire, actor):
        placeholder = HIDDEN_PRIZE if zone == "prizes" else HIDDEN_CARD
        if any(
            isinstance(card, str) and card and card != placeholder
            for card in wire["players"][player_index].get(zone, [])
        ):
            return True
    bonus_rows = wire.get("setup_bonus_card_ids", [[], []])
    return (
        isinstance(bonus_rows, list)
        and len(bonus_rows) == 2
        and any(card != HIDDEN_CARD for card in bonus_rows[1 - actor])
    )


def _tensor_difference(
    expected: dict[str, np.ndarray],
    actual: dict[str, np.ndarray],
) -> dict[str, Any] | None:
    if expected.keys() != actual.keys():
        return {
            "kind": "keys",
            "expected": sorted(expected),
            "actual": sorted(actual),
        }
    for key in sorted(expected):
        left = np.asarray(expected[key])
        right = np.asarray(actual[key])
        if left.dtype != right.dtype or left.shape != right.shape:
            return {
                "kind": "shape_or_dtype",
                "tensor": key,
                "expected_shape": list(left.shape),
                "actual_shape": list(right.shape),
                "expected_dtype": str(left.dtype),
                "actual_dtype": str(right.dtype),
            }
        if not np.array_equal(left, right, equal_nan=True):
            different = np.argwhere(left != right)
            first = different[0].tolist() if different.size else []
            index = tuple(first)
            return {
                "kind": "value",
                "tensor": key,
                "index": first,
                "expected": (
                    left[index].item()
                    if first
                    else "<nan-difference>"
                ),
                "actual": (
                    right[index].item()
                    if first
                    else "<nan-difference>"
                ),
            }
    return None


def audit(
    *,
    games: int,
    max_decisions: int,
    seed: int,
    min_states_per_deck: int,
    detail_limit: int,
) -> dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[2]
    cards = json.loads(
        (repo_root / "godot" / "data" / "cards.json").read_text(
            encoding="utf-8"
        )
    )
    decks = json.loads(
        (repo_root / "godot" / "data" / "decks.json").read_text(
            encoding="utf-8"
        )
    )
    environment = PythonGameEnvironment()
    native_game = ptcg_ai_core.NativeGameKernel(cards)
    determinizer = ptcg_ai_core.NativeDeterminizer(decks)
    encoder = ptcg_ai_core.NativeInformationSetEncoder(cards)
    trajectory_rng = random.Random(seed)

    states = 0
    action_states = 0
    choice_states = 0
    completed_games = 0
    decision_limit_trajectories = 0
    variants_checked = 0
    identity_mutations = 0
    order_mutations = 0
    unmasked_rejection_missing = 0
    masked_boundary_errors = 0
    masked_placeholder_errors = 0
    mask_mismatches = 0
    observation_mismatches = 0
    hash_mismatches = 0
    determinization_mismatches = 0
    candidate_mismatches = 0
    tensor_mismatches = 0
    choice_reference_errors = 0
    inventory_mismatches = 0
    trajectory_errors = 0
    states_by_deck: Counter[str] = Counter()
    action_states_by_deck: Counter[str] = Counter()
    choice_states_by_deck: Counter[str] = Counter()
    order_mutations_by_deck: Counter[str] = Counter()
    request_types: Counter[str] = Counter()
    details: list[dict[str, Any]] = []

    def record(kind: str, payload: dict[str, Any]) -> None:
        if len(details) < detail_limit:
            details.append({"kind": kind, **payload})

    for game_index in range(games):
        task = _task(game_index, seed)
        state = _setup_game(task)
        trajectory_history: list[dict[str, Any]] = []
        for decision in range(max_decisions):
            while _advance_nondecision_phase(state):
                if state.is_terminal():
                    break
            if state.is_terminal():
                completed_games += 1
                break

            wire = game_state_to_native_wire(state)
            inventory_error = False
            for player_index in (0, 1):
                inventory = _physical_inventory(wire, player_index)
                expected = _expanded_deck_counter(
                    decks,
                    str(state.public_deck_keys[player_index]),
                )
                if inventory == expected:
                    continue
                inventory_mismatches += 1
                record(
                    "physical_inventory_mismatch",
                    {
                        "game_id": task.game_id,
                        "game_index": game_index,
                        "decision": decision,
                        "player": player_index,
                        "deck": str(
                            state.public_deck_keys[player_index]
                        ),
                        "missing": dict(expected - inventory),
                        "extra": dict(inventory - expected),
                        "history": trajectory_history[-16:],
                        "players": wire.get("players", []),
                    },
                )
                inventory_error = True
            if inventory_error:
                break

            actor = environment.actor(state)
            deck_key = str(state.public_deck_keys[actor])
            trajectory_seed = (
                task.seed + decision * 65537
            ) & 0xFFFFFFFF
            formal_candidates = list(environment.candidates(state, actor))
            if not formal_candidates:
                trajectory_errors += 1
                record(
                    "trajectory_no_candidate",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                        "deck": deck_key,
                    },
                )
                break

            runtime_wire = _runtime_root_wire(wire)
            try:
                masked = mask_native_snapshot(runtime_wire, actor)
            except Exception as exc:
                masked_boundary_errors += 1
                record(
                    "mask_failed",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                        "error": str(exc),
                    },
                )
                break
            boundary_error = str(
                ptcg_ai_core.validate_runtime_snapshot(masked, actor)
            )
            if boundary_error:
                masked_boundary_errors += 1
                record(
                    "masked_boundary_rejected",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                        "error": boundary_error,
                    },
                )
            if not _masked_hidden_zones_valid(masked, actor):
                masked_placeholder_errors += 1
                record(
                    "masked_hidden_zone_invalid",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                    },
                )
            if (
                _has_unmasked_hidden_identity(runtime_wire, actor)
                and not str(
                    ptcg_ai_core.validate_runtime_snapshot(
                        runtime_wire,
                        actor,
                    )
                )
            ):
                unmasked_rejection_missing += 1
                record(
                    "unmasked_boundary_accepted",
                    {
                        "game_id": task.game_id,
                        "decision": decision,
                        "actor": actor,
                    },
                )

            authoritative_projection = (
                ptcg_ai_core.project_information_set(wire, actor)
            )
            variants: list[tuple[str, dict[str, Any], int]] = []
            identity, identity_changed = _identity_variant(
                wire,
                actor,
                f"{game_index}_{decision}",
            )
            variants.append(("identity", identity, identity_changed))
            reordered, order_changed = _order_variant(wire, actor)
            variants.append(("order", reordered, order_changed))

            request = DEFAULT_GAME_ENGINE.pending_choice(state)
            native_pending: dict[str, Any] | None = None
            baseline_candidates: list[dict[str, Any]]
            baseline_tensors: dict[str, np.ndarray]
            determinization_seed = (
                seed
                ^ (game_index + 1) * 0x9E3779B9
                ^ (decision + 1) * 0x85EBCA6B
            ) & 0xFFFFFFFF
            try:
                baseline_determined = determinizer.determinize(
                    masked,
                    actor,
                    determinization_seed,
                )
            except Exception as exc:
                determinization_mismatches += 1
                record(
                    "baseline_determinization_error",
                    {
                        "game_id": task.game_id,
                        "game_index": game_index,
                        "decision": decision,
                        "actor": actor,
                        "deck": deck_key,
                        "error": str(exc),
                        "public_deck_keys": wire.get(
                            "public_deck_keys",
                            [],
                        ),
                        "players": wire.get("players", []),
                        "stadium_card_id": wire.get(
                            "stadium_card_id",
                            "",
                        ),
                        "stadium_owner_idx": wire.get(
                            "stadium_owner_idx",
                            -1,
                        ),
                    },
                )
                break
            baseline_search_projection = (
                ptcg_ai_core.project_information_set(
                    baseline_determined,
                    actor,
                )
            )

            if request is None:
                action_states += 1
                action_states_by_deck[deck_key] += 1
                baseline_candidates = list(
                    native_game.legal_actions(
                        baseline_determined,
                        actor,
                    )
                )
                formal_keys = {
                    _formal_action_key(candidate.payload)
                    for candidate in formal_candidates
                }
                native_keys = {
                    _native_action_key(candidate)
                    for candidate in baseline_candidates
                }
                if formal_keys != native_keys:
                    candidate_mismatches += 1
                    record(
                        "formal_native_candidate_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "missing": [
                                repr(row)
                                for row in sorted(
                                    formal_keys - native_keys,
                                    key=repr,
                                )
                            ],
                            "extra": [
                                repr(row)
                                for row in sorted(
                                    native_keys - formal_keys,
                                    key=repr,
                                )
                            ],
                        },
                    )
                baseline_tensors = encoder.encode_actions(
                    baseline_search_projection["observation"],
                    baseline_candidates,
                )
            else:
                choice_states += 1
                choice_states_by_deck[deck_key] += 1
                request_types[str(request.request_type)] += 1
                try:
                    native_pending = _native_choice_view(
                        serialize_choice_view(request),
                        formal_candidates,
                        actor,
                    )
                    baseline_candidates = list(
                        native_game.choice_candidates(native_pending)
                    )
                    baseline_tensors = encoder.encode_choices(
                        baseline_search_projection["observation"],
                        native_pending,
                        baseline_candidates,
                    )
                except Exception as exc:
                    choice_reference_errors += 1
                    record(
                        "choice_boundary_error",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "request_type": request.request_type,
                            "error": str(exc),
                        },
                    )
                    baseline_candidates = []
                    baseline_tensors = {}

            states += 1
            states_by_deck[deck_key] += 1
            identity_mutations += identity_changed
            order_mutations += order_changed
            if order_changed:
                order_mutations_by_deck[deck_key] += order_changed

            for variant_kind, variant, _changed in variants:
                variants_checked += 1
                variant_projection = (
                    ptcg_ai_core.project_information_set(variant, actor)
                )
                if (
                    authoritative_projection["observation"]
                    != variant_projection["observation"]
                ):
                    observation_mismatches += 1
                    record(
                        "observation_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                        },
                    )
                if any(
                    authoritative_projection[field]
                    != variant_projection[field]
                    for field in (
                        "public_hash",
                        "actor_private_hash",
                        "tree_key",
                    )
                ):
                    hash_mismatches += 1
                    record(
                        "infoset_hash_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                            "expected": {
                                field: authoritative_projection[field]
                                for field in (
                                    "public_hash",
                                    "actor_private_hash",
                                    "tree_key",
                                )
                            },
                            "actual": {
                                field: variant_projection[field]
                                for field in (
                                    "public_hash",
                                    "actor_private_hash",
                                    "tree_key",
                                )
                            },
                        },
                    )

                variant_runtime = _runtime_root_wire(variant)
                variant_masked = mask_native_snapshot(
                    variant_runtime,
                    actor,
                )
                if masked != variant_masked:
                    mask_mismatches += 1
                    record(
                        "runtime_mask_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                        },
                    )
                variant_boundary_error = str(
                    ptcg_ai_core.validate_runtime_snapshot(
                        variant_masked,
                        actor,
                    )
                )
                if variant_boundary_error:
                    masked_boundary_errors += 1
                    record(
                        "variant_masked_boundary_rejected",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                            "error": variant_boundary_error,
                        },
                    )
                try:
                    variant_determined = determinizer.determinize(
                        variant_masked,
                        actor,
                        determinization_seed,
                    )
                except Exception as exc:
                    determinization_mismatches += 1
                    record(
                        "variant_determinization_error",
                        {
                            "game_id": task.game_id,
                            "game_index": game_index,
                            "decision": decision,
                            "actor": actor,
                            "deck": deck_key,
                            "variant": variant_kind,
                            "error": str(exc),
                        },
                    )
                    continue
                if baseline_determined != variant_determined:
                    determinization_mismatches += 1
                    record(
                        "determinization_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                        },
                    )
                variant_search_projection = (
                    ptcg_ai_core.project_information_set(
                        variant_determined,
                        actor,
                    )
                )
                try:
                    if request is None:
                        variant_candidates = list(
                            native_game.legal_actions(
                                variant_determined,
                                actor,
                            )
                        )
                        variant_tensors = encoder.encode_actions(
                            variant_search_projection["observation"],
                            variant_candidates,
                        )
                    elif native_pending is not None:
                        variant_candidates = list(
                            native_game.choice_candidates(native_pending)
                        )
                        variant_tensors = encoder.encode_choices(
                            variant_search_projection["observation"],
                            native_pending,
                            variant_candidates,
                        )
                    else:
                        continue
                except Exception as exc:
                    if request is None:
                        tensor_mismatches += 1
                        error_kind = "variant_action_encoding_error"
                    else:
                        choice_reference_errors += 1
                        error_kind = "variant_choice_encoding_error"
                    record(
                        error_kind,
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                            "request_type": (
                                ""
                                if request is None
                                else request.request_type
                            ),
                            "error": str(exc),
                        },
                    )
                    continue
                if baseline_candidates != variant_candidates:
                    candidate_mismatches += 1
                    record(
                        "variant_candidate_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                        },
                    )
                tensor_difference = _tensor_difference(
                    baseline_tensors,
                    variant_tensors,
                )
                if tensor_difference is not None:
                    tensor_mismatches += 1
                    record(
                        "tensor_mismatch",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "variant": variant_kind,
                            "difference": tensor_difference,
                        },
                    )

            if request is not None:
                candidates = list(formal_candidates)
                trajectory_rng.shuffle(candidates)
                advanced = False
                errors: list[str] = []
                for candidate in candidates:
                    probe = clone_state(state)
                    try:
                        environment.apply(
                            probe,
                            candidate,
                            trajectory_seed,
                        )
                    except Exception as exc:
                        if len(errors) < 3:
                            errors.append(str(exc))
                        continue
                    environment.apply(
                        state,
                        candidate,
                        trajectory_seed,
                    )
                    trajectory_history.append({
                        "decision": decision,
                        "kind": "choice",
                        "actor": actor,
                        "request_type": request.request_type,
                        "candidate": repr(candidate.payload),
                        "seed": trajectory_seed,
                    })
                    advanced = True
                    break
                if not advanced:
                    trajectory_errors += 1
                    record(
                        "trajectory_choice_error",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "request_type": request.request_type,
                            "errors": errors,
                        },
                    )
                    break
            else:
                selected = trajectory_rng.choice(formal_candidates)
                trajectory_history.append({
                    "decision": decision,
                    "kind": "action",
                    "actor": actor,
                    "candidate": repr(selected.payload),
                    "seed": trajectory_seed,
                })
                try:
                    environment.apply(
                        state,
                        selected,
                        trajectory_seed,
                    )
                except Exception as exc:
                    trajectory_errors += 1
                    record(
                        "trajectory_action_error",
                        {
                            "game_id": task.game_id,
                            "decision": decision,
                            "actor": actor,
                            "action": repr(selected.payload),
                            "error": str(exc),
                        },
                    )
                    break
        else:
            decision_limit_trajectories += 1

    coverage_missing = {
        deck: max(0, min_states_per_deck - states_by_deck[deck])
        for deck in RELEASE_DECKS
        if states_by_deck[deck] < min_states_per_deck
    }
    invariance_passed = not any(
        (
            unmasked_rejection_missing,
            masked_boundary_errors,
            masked_placeholder_errors,
            mask_mismatches,
            observation_mismatches,
            hash_mismatches,
            determinization_mismatches,
            candidate_mismatches,
            tensor_mismatches,
            choice_reference_errors,
            inventory_mismatches,
            trajectory_errors,
        )
    )
    mutation_decks = (
        RELEASE_DECKS
        if min_states_per_deck > 0
        else tuple(states_by_deck)
    )
    mutation_coverage_passed = (
        identity_mutations > 0
        and order_mutations > 0
        and all(
            order_mutations_by_deck[deck] > 0
            for deck in mutation_decks
        )
    )
    coverage_passed = not coverage_missing
    scope_passed = (
        invariance_passed
        and mutation_coverage_passed
        and coverage_passed
    )
    return {
        "schema": "native_infoset_security_v2_audit/1",
        "scope": (
            "python_mask_cpp_projection_tree_key_determinization_"
            "candidate_encoder"
        ),
        "seed": seed,
        "requested_games": games,
        "completed_games": completed_games,
        "decision_limit_trajectories": decision_limit_trajectories,
        "max_decisions": max_decisions,
        "min_states_per_deck": min_states_per_deck,
        "states": states,
        "action_states": action_states,
        "choice_states": choice_states,
        "states_by_deck": dict(sorted(states_by_deck.items())),
        "action_states_by_deck": dict(
            sorted(action_states_by_deck.items())
        ),
        "choice_states_by_deck": dict(
            sorted(choice_states_by_deck.items())
        ),
        "variants_checked": variants_checked,
        "identity_mutations": identity_mutations,
        "order_mutations": order_mutations,
        "order_mutations_by_deck": dict(
            sorted(order_mutations_by_deck.items())
        ),
        "request_types": dict(request_types.most_common()),
        "unmasked_rejection_missing": unmasked_rejection_missing,
        "masked_boundary_errors": masked_boundary_errors,
        "masked_placeholder_errors": masked_placeholder_errors,
        "mask_mismatches": mask_mismatches,
        "observation_mismatches": observation_mismatches,
        "hash_mismatches": hash_mismatches,
        "determinization_mismatches": determinization_mismatches,
        "candidate_mismatches": candidate_mismatches,
        "tensor_mismatches": tensor_mismatches,
        "choice_reference_errors": choice_reference_errors,
        "inventory_mismatches": inventory_mismatches,
        "trajectory_errors": trajectory_errors,
        "coverage_missing": coverage_missing,
        "invariance_status": (
            "passed" if invariance_passed else "failed"
        ),
        "mutation_coverage_status": (
            "passed" if mutation_coverage_passed else "failed"
        ),
        "coverage_status": "passed" if coverage_passed else "failed",
        "scope_passed": scope_passed,
        "godot_runtime_status": "not_in_python_cpp_audit_scope",
        "release_gate_complete": False,
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--games", type=int, default=30)
    parser.add_argument("--max-decisions", type=int, default=64)
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--min-states-per-deck", type=int, default=0)
    parser.add_argument("--detail-limit", type=int, default=30)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if (
        args.games <= 0
        or args.max_decisions <= 0
        or args.min_states_per_deck < 0
    ):
        parser.error(
            "games/max-decisions must be positive and coverage non-negative"
        )
    report = audit(
        games=args.games,
        max_decisions=args.max_decisions,
        seed=args.seed,
        min_states_per_deck=args.min_states_per_deck,
        detail_limit=max(0, args.detail_limit),
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

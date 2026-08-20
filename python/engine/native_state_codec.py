"""DTO conversion for the authoritative C++ rules core.

This module contains no legality or settlement logic.  It only maps the
historical Python training objects to Snapshot 3 and adopts native snapshots
back into those mutable DTOs while training callers migrate to session handles.
"""
from __future__ import annotations

import copy
import json
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping

from data.card_registry import CardRegistry
from engine.enums import StatusType, TurnPhase
from engine.player_state import PokemonInPlay


REPO_ROOT = Path(__file__).resolve().parents[2]


@lru_cache(maxsize=1)
def native_catalog_payload() -> dict[str, Any]:
    cards = json.loads(
        (REPO_ROOT / "godot" / "data" / "cards.json").read_text(
            encoding="utf-8"
        )
    )
    card_ir = json.loads(
        (REPO_ROOT / "godot" / "data" / "card_ir_v3.json").read_text(
            encoding="utf-8"
        )
    )
    return {"cards": cards, "card_ir": card_ir}


def state_to_native_snapshot(state: Any) -> dict[str, Any]:
    # Keep the mature, strictly bounded DTO converter used by native search.
    # It has no execution dependency and remains the Actions-3 read adapter.
    from engine.ai.dl.native_bridge_v2 import game_state_to_native_wire

    payload = game_state_to_native_wire(state)
    payload["snapshot_version"] = 3
    payload["action_log"] = [
        str(value) for value in getattr(state, "action_log", ())
    ]
    payload["processed_action_ids"] = [
        str(value)
        for value in getattr(state, "_native_processed_action_ids", ())
    ]
    stack = payload.get("resolution_stack")
    if not isinstance(stack, dict):
        stack = {}
    payload["resolution_stack"] = {
        "schema_version": int(stack.get("schema_version", 3)),
        "frames": copy.deepcopy(list(stack.get("frames", ()) or ())),
        "pending_request": copy.deepcopy(stack.get("pending_request")),
        "sequence": int(stack.get("sequence", payload.get("choice_sequence", 0))),
        "context": copy.deepcopy(dict(stack.get("context", {}) or {})),
    }
    return payload


def adopt_native_snapshot(
    state: Any,
    payload: Mapping[str, Any],
    *,
    rng_state: int | None = None,
) -> None:
    """Replace one Python DTO in-place from an authoritative Snapshot/State."""
    _ensure_registry()
    players = payload.get("players")
    if not isinstance(players, list) or len(players) != 2:
        raise ValueError("invalid_native_players")
    _adopt_player(state.p1, players[0])
    _adopt_player(state.p2, players[1])

    state.active_player_idx = int(payload.get("active_player_idx", 0))
    phase_name = str(payload.get("phase", "SETUP"))
    state.phase = TurnPhase.__members__.get(phase_name, TurnPhase.SETUP)
    state.turn_number = int(payload.get("turn_number", 0))
    state.first_player_idx = int(payload.get("first_player_idx", 0))
    stadium_id = str(payload.get("stadium_card_id", "") or "")
    state.stadium_card = _card(stadium_id) if stadium_id else None
    state.stadium_owner_idx = int(payload.get("stadium_owner_idx", -1))
    winner = int(payload.get("winner", -1))
    state.winner = winner if winner in (0, 1) else None
    state.result_status = str(payload.get("result_status", "ONGOING"))
    state.result_reason = str(payload.get("result_reason", ""))
    state.result_conditions = copy.deepcopy(
        list(payload.get("result_conditions", [[], []]))
    )
    state.rules_profile_id = str(
        payload.get("rules_profile_id", "CN_MAINLAND_3_1_0")
    )
    state.rules_options = copy.deepcopy(
        dict(payload.get("rules_options", {}) or {})
    )
    state.apply_type_matchups = bool(
        payload.get(
            "apply_type_matchups",
            state.rules_options.get("apply_type_matchups", False),
        )
    )
    state.rules_options["apply_type_matchups"] = state.apply_type_matchups
    state.setup_stage = str(payload.get("setup_stage", "TURN_ORDER"))
    state.setup_actor_idx = int(payload.get("setup_actor_idx", -1))
    state.opening_coin_winner_idx = int(
        payload.get("opening_coin_winner_idx", -1)
    )
    maximum = int(payload.get("mulligan_bonus_max", 0))
    state.mulligan_bonus_max = (maximum, maximum)
    ready = list(payload.get("setup_ready", [False, False]))
    state.setup_initial_done = tuple(bool(value) for value in ready[:2])
    state.setup_bonus_card_ids = tuple(
        [str(card_id) for card_id in row]
        for row in list(payload.get("setup_bonus_card_ids", [[], []]))[:2]
    )
    state.revision = int(payload.get("revision", 0))
    state.choice_sequence = int(payload.get("choice_sequence", 0))
    keys = list(payload.get("public_deck_keys", ["", ""]))
    state.public_deck_keys = tuple(str(value or "") for value in keys[:2])
    state.action_log = [str(value) for value in payload.get("action_log", [])]
    counts = list(payload.get("mulligan_count", [0, 0]))
    state.mulligan_count = tuple(int(value) for value in counts[:2])
    extra = list(payload.get("extra_draws", [0, 0]))
    state.extra_draws = tuple(int(value) for value in extra[:2])
    state.pending_promotions = [
        int(value) for value in payload.get("pending_promotions", [])
    ]
    state.resolution_stack = copy.deepcopy(
        dict(payload.get("resolution_stack", {}) or {})
    )
    state._native_processed_action_ids = [
        str(value) for value in payload.get("processed_action_ids", [])
    ]
    if rng_state is not None:
        state._native_rng_state = int(rng_state) & 0xFFFFFFFF

    state.turn_fact_book = _python_turn_fact_book(
        payload.get("turn_fact_book"),
        state.turn_number,
        state.active_player_idx,
    )
    current = state.turn_fact_book.get("current", {})
    previous = state.turn_fact_book.get("previous", {})
    state.turn_knockout_facts = copy.deepcopy(
        list(previous.get("knockouts", []))
        + list(current.get("knockouts", []))
    )


def _adopt_player(player: Any, payload: Any) -> None:
    if not isinstance(payload, Mapping):
        raise ValueError("invalid_native_player")
    player.name = str(payload.get("name", "玩家"))
    player.deck = _cards(payload.get("deck", []))
    player.hand = _cards(payload.get("hand", []))
    player.discard = _cards(payload.get("discard", []))
    player.prizes = _cards(payload.get("prizes", []))
    player.active = _pokemon(payload.get("active"))
    bench = list(payload.get("bench", []))
    player.bench = [_pokemon(value) for value in bench[:5]]
    while len(player.bench) < 5:
        player.bench.append(None)
    player.supporter_played_this_turn = bool(
        payload.get("supporter_played_this_turn", False)
    )
    player.energy_attached_this_turn = bool(
        payload.get("energy_attached_this_turn", False)
    )
    player.retreated_this_turn = bool(
        payload.get("retreated_this_turn", False)
    )
    player.stadium_played_this_turn = bool(
        payload.get("stadium_played_this_turn", False)
    )
    player.stadium_used_this_turn = bool(
        payload.get("stadium_used_this_turn", False)
    )
    player.healed_this_turn = bool(payload.get("healed_this_turn", False))
    player.vstar_power_used = bool(payload.get("vstar_power_used", False))
    player.was_ko_by_attack = bool(payload.get("was_ko_by_attack", False))
    player.attack_locked_names = {
        str(name): int(expires)
        for name, expires in dict(
            payload.get("attack_locked_names", {}) or {}
        ).items()
    }


def _pokemon(payload: Any) -> PokemonInPlay | None:
    if payload is None:
        return None
    if not isinstance(payload, Mapping):
        raise ValueError("invalid_native_pokemon")
    pokemon = PokemonInPlay(_card(str(payload.get("card_id", ""))))
    pokemon.damage_counters = int(payload.get("damage_counters", 0))
    pokemon.energy_cards = _cards(payload.get("energy_card_ids", []))
    tool_id = str(payload.get("attached_tool_id", "") or "")
    pokemon.attached_tool = _card(tool_id) if tool_id else None
    pokemon.status_conditions = {
        StatusType[name]
        for name in payload.get("status_conditions", [])
        if str(name) in StatusType.__members__
    }
    pokemon.evolution_stack = _cards(payload.get("evolution_stack_ids", []))
    pokemon.can_evolve_this_turn = bool(
        payload.get("can_evolve_this_turn", True)
    )
    pokemon.placed_this_turn = bool(payload.get("placed_this_turn", True))
    pokemon.used_abilities = {
        str(value) for value in payload.get("used_abilities", [])
    }
    pokemon.damage_prevented_next_turn = bool(
        payload.get("damage_prevented", False)
    )
    pokemon.all_prevented_next_turn = bool(payload.get("all_prevented", False))
    pokemon.outgoing_damage_reduction_next_turn = int(
        payload.get("outgoing_damage_reduction", 0)
    )
    pokemon.attack_locked = bool(payload.get("attack_locked", False))
    pokemon.attack_locked_names = copy.deepcopy(
        dict(payload.get("attack_locked_names", {}) or {})
    )
    pokemon.dazzled = bool(payload.get("dazzled", False))
    pokemon.modifiers = copy.deepcopy(list(payload.get("modifiers", [])))
    pokemon.max_hp_modifiers = []
    pokemon.paralyzed_since_turn = int(payload.get("paralyzed_since_turn", 0))
    pokemon.healed_this_turn = bool(payload.get("healed_this_turn", False))
    return pokemon


def _python_turn_fact_book(
    value: Any,
    turn_number: int,
    active_player: int,
) -> dict[str, Any]:
    source = value if isinstance(value, Mapping) else {}

    def window(key: str, fallback_turn: int) -> dict[str, Any]:
        row = source.get(key, {})
        raw = row if isinstance(row, Mapping) else {}
        facts = [_python_knockout_fact(fact) for fact in raw.get("knockouts", [])]
        return {
            "turn_number": fallback_turn,
            "turn_player": active_player if key == "current_turn" else 1 - active_player,
            "knockouts": [fact for fact in facts if fact is not None],
        }

    return {
        "version": 1,
        "current": window("current_turn", turn_number),
        "previous": window("previous_turn", turn_number - 1),
    }


def _python_knockout_fact(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, Mapping):
        return None
    owner = int(value.get("defeated_player", value.get("owner", -1)))
    if owner not in (0, 1):
        return None
    cause = str(value.get("source_kind", value.get("cause", "rule")))
    return {
        "turn_number": int(value.get("turn", value.get("turn_number", 0))),
        "turn_player": value.get("turn_player"),
        "owner": owner,
        "cause": cause,
        "source_player": value.get("source_player"),
        "card_id": str(value.get("card_id", "")),
        "slot": str(value.get("slot", "")),
    }


def _ensure_registry() -> None:
    if CardRegistry.is_initialized():
        return
    from data.deck_definitions import ALL_CARD_IDS

    CardRegistry.initialize(ALL_CARD_IDS)


def _card(card_id: str):
    card = CardRegistry.get(card_id)
    if card is None:
        raise KeyError(f"unknown_native_card:{card_id}")
    return card


def _cards(values: Any) -> list[Any]:
    return [_card(str(value)) for value in list(values or [])]


__all__ = [
    "native_catalog_payload",
    "state_to_native_snapshot",
    "adopt_native_snapshot",
]

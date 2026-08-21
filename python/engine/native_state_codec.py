"""DTO conversion for the authoritative C++ rules core.

This module contains no legality or settlement logic. It maps Python rule DTOs
to Snapshot 3 and adopts native snapshots back into those mutable DTOs.
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
from engine.snapshot import canonical_state_payload


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
    snapshot = canonical_state_payload(state)
    rules_options = dict(snapshot.get("rules_options", {}))
    apply_type_matchups = bool(snapshot.get("apply_type_matchups", False))
    rules_options["apply_type_matchups"] = apply_type_matchups
    mulligan_value = snapshot.get("mulligan_bonus_max", (0, 0))
    mulligan_bonus_max = (
        max((int(value) for value in mulligan_value), default=0)
        if isinstance(mulligan_value, (list, tuple))
        else int(mulligan_value or 0)
    )
    payload = {
        "players": [
            _native_player_payload(snapshot["p1"]),
            _native_player_payload(snapshot["p2"]),
        ],
        "active_player_idx": int(snapshot["active_player_idx"]),
        "phase": str(snapshot["phase"]),
        "turn_number": int(snapshot["turn_number"]),
        "first_player_idx": int(snapshot["first_player_idx"]),
        "stadium_card_id": str(snapshot.get("stadium_card_id") or ""),
        "stadium_owner_idx": int(snapshot.get("stadium_owner_idx", -1)),
        "winner": (
            -1 if snapshot.get("winner") is None else int(snapshot["winner"])
        ),
        "result_status": str(snapshot.get("result_status", "ONGOING")),
        "result_reason": str(snapshot.get("result_reason", "")),
        "result_conditions": _json_value(
            snapshot.get("result_conditions", [[], []])
        ),
        "revision": int(snapshot.get("revision", 0)),
        "choice_sequence": int(snapshot.get("choice_sequence", 0)),
        "public_deck_keys": [
            str(value or "")
            for value in snapshot.get("public_deck_keys", ("", ""))
        ],
        "apply_type_matchups": apply_type_matchups,
        "rules_profile_id": str(
            snapshot.get("rules_profile_id", "CN_MAINLAND_3_1_0")
        ),
        "rules_options": _json_value(rules_options),
        "action_log": [str(value) for value in snapshot.get("action_log", [])],
        "mulligan_count": list(snapshot.get("mulligan_count", (0, 0))),
        "extra_draws": list(snapshot.get("extra_draws", (0, 0))),
        "setup_ready": [
            bool(value)
            for value in snapshot.get("setup_initial_done", (False, False))
        ],
        "setup_stage": str(snapshot.get("setup_stage", "TURN_ORDER")),
        "setup_actor_idx": int(snapshot.get("setup_actor_idx", -1)),
        "opening_coin_winner_idx": int(
            snapshot.get("opening_coin_winner_idx", -1)
        ),
        "mulligan_bonus_max": mulligan_bonus_max,
        "setup_bonus_card_ids": [
            list(row)
            for row in snapshot.get("setup_bonus_card_ids", ([], []))
        ],
        "pending_promotions": list(snapshot.get("pending_promotions", [])),
        "processed_action_ids": [
            str(value)
            for value in getattr(state, "_native_processed_action_ids", [])
        ],
        "resolution_stack": _json_value(snapshot.get("resolution_stack", {})),
        "turn_fact_book": _native_turn_fact_book(
            snapshot.get("turn_fact_book", {})
        ),
    }
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


def mask_native_snapshot(
    wire_state: Mapping[str, Any],
    actor: int,
) -> dict[str, Any]:
    """Remove private identities before a snapshot crosses the search ABI."""
    if actor not in (0, 1):
        raise ValueError("invalid_native_actor")
    result = copy.deepcopy(dict(wire_state))
    players = result.get("players")
    if not isinstance(players, list) or len(players) != 2:
        raise ValueError("invalid_native_players")
    for owner, player in enumerate(players):
        if not isinstance(player, dict):
            raise ValueError("invalid_native_player")
        deck = player.get("deck")
        hand = player.get("hand")
        prizes = player.get("prizes")
        if not all(isinstance(zone, list) for zone in (deck, hand, prizes)):
            raise ValueError("invalid_native_hidden_zone")
        player["deck"] = ["__hidden_card__"] * len(deck)
        player["prizes"] = ["__hidden_prize__"] * len(prizes)
        if owner != actor:
            player["hand"] = ["__hidden_card__"] * len(hand)
    return result


def _json_value(value: Any) -> Any:
    try:
        return json.loads(json.dumps(value, ensure_ascii=False, allow_nan=False))
    except (TypeError, ValueError) as exc:
        raise ValueError("native_state_is_not_json") from exc


def _native_pokemon_payload(
    snapshot: Mapping[str, Any] | None,
) -> dict[str, Any] | None:
    if snapshot is None:
        return None
    source_modifiers = [
        row for row in snapshot.get("modifiers", []) if isinstance(row, dict)
    ]
    represented_attack_locks = {
        str(
            operation.get("attack_name")
            or operation.get("reason")
            or "__all__"
        )
        for descriptor in source_modifiers
        if isinstance((operation := descriptor.get("operation")), dict)
        and str(operation.get("kind", "")) == "attack_lock"
    }
    payload: dict[str, Any] = {
        "card_id": str(snapshot.get("card_id", "")),
        "damage_counters": int(snapshot.get("damage_counters", 0)),
        "energy_card_ids": list(snapshot.get("energy_card_ids", [])),
        "attached_tool_id": str(snapshot.get("attached_tool_id") or ""),
        "status_conditions": sorted(snapshot.get("status_conditions", [])),
        "evolution_stack_ids": list(snapshot.get("evolution_stack_ids", [])),
        "can_evolve_this_turn": bool(
            snapshot.get("can_evolve_this_turn", True)
        ),
        "placed_this_turn": bool(snapshot.get("placed_this_turn", True)),
        "used_abilities": sorted(snapshot.get("used_abilities", [])),
        "damage_prevented": bool(snapshot.get("damage_prevented", False)),
        "all_prevented": bool(snapshot.get("all_prevented", False)),
        "outgoing_damage_reduction": int(
            snapshot.get("outgoing_damage_reduction", 0)
        ),
        "healed_this_turn": bool(snapshot.get("healed_this_turn", False)),
        "paralyzed_since_turn": int(snapshot.get("paralyzed_since_turn", 0)),
    }
    if bool(snapshot.get("attack_locked", False)) and (
        "__all__" not in represented_attack_locks
    ):
        payload["attack_locked"] = True
    attack_locked_names = _json_value(snapshot.get("attack_locked_names", {}))
    if isinstance(attack_locked_names, dict):
        remaining = {
            str(name): applied
            for name, applied in attack_locked_names.items()
            if str(name) not in represented_attack_locks
        }
        if remaining:
            payload["attack_locked_names"] = remaining
    elif attack_locked_names:
        payload["attack_locked_names"] = attack_locked_names
    modifiers = [_json_value(row) for row in source_modifiers]
    for row in snapshot.get("max_hp_modifiers", []):
        if not isinstance(row, dict):
            continue
        modifier_kind = str(
            row.get("modifier_kind", row.get("effect_type", ""))
        )
        if not modifier_kind:
            continue
        if modifier_kind == "conditional_hp_boost" and any(
            isinstance(existing, dict)
            and (existing.get("operation") or {}).get("kind") == "hp_delta"
            for existing in modifiers
        ):
            continue
        params = dict(row.get("params", {}))
        for key in ("energy_type", "threshold", "amount"):
            if key in row and key not in params:
                params[key] = row[key]
        modifiers.append({
            "source": str(row.get("source", modifier_kind)),
            "source_player": int(row.get("source_player", -1)),
            "source_slot": str(row.get("source_slot", "")),
            "source_card_id": str(
                row.get("source_card_id", snapshot.get("card_id", ""))
            ),
            "modifier_kind": modifier_kind,
            "params": _json_value(params),
        })
    if modifiers:
        payload["modifiers"] = modifiers
    return payload


def _native_player_payload(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    bench = [_native_pokemon_payload(row) for row in snapshot.get("bench", [])]
    bench.extend([None] * (5 - len(bench)))
    payload = {
        "name": str(snapshot.get("name", "")),
        "deck": list(snapshot.get("deck_ids", [])),
        "hand": list(snapshot.get("hand_ids", [])),
        "discard": list(snapshot.get("discard_ids", [])),
        "prizes": list(snapshot.get("prize_ids", [])),
        "active": _native_pokemon_payload(snapshot.get("active")),
        "bench": bench[:5],
        "supporter_played_this_turn": bool(snapshot.get("supporter_played", False)),
        "energy_attached_this_turn": bool(snapshot.get("energy_attached", False)),
        "retreated_this_turn": bool(snapshot.get("retreated", False)),
        "stadium_played_this_turn": bool(snapshot.get("stadium_played", False)),
        "stadium_used_this_turn": bool(snapshot.get("stadium_used", False)),
        "healed_this_turn": bool(snapshot.get("healed", False)),
        "vstar_power_used": bool(snapshot.get("vstar_used", False)),
        "was_ko_by_attack": bool(snapshot.get("was_ko_by_attack", False)),
    }
    attack_locked_names = {
        str(name): int(expires)
        for name, expires in dict(
            snapshot.get("attack_locked_names", {}) or {}
        ).items()
    }
    if attack_locked_names:
        payload["attack_locked_names"] = attack_locked_names
    return payload


def _native_knockout_fact(fact: Any) -> dict[str, Any] | None:
    if not isinstance(fact, dict):
        return None
    source_kind = str(fact.get("source_kind", fact.get("cause", "rule")))
    source_player_value = fact.get("source_player", -1)
    source_player = int(source_player_value) if source_player_value in (0, 1) else -1
    if source_kind == "attack_damage":
        cause_kind = "damage"
    elif source_kind == "direct_knockout":
        source_kind, cause_kind = "attack_effect", "direct_knockout"
    elif source_kind in {"damage_counter", "damage_counters"}:
        cause_kind = "damage_counters"
    elif source_kind == "special_condition":
        cause_kind = "special_condition"
    else:
        cause_kind = "effect"
    return {
        "defeated_player": int(
            fact.get("defeated_player", fact.get("owner", -1))
        ),
        "slot": str(fact.get("slot", "")),
        "card_id": str(fact.get("card_id", "")),
        "source_player": source_player,
        "source_kind": source_kind,
        "cause_kind": str(fact.get("cause_kind", cause_kind)),
        "cause_detail": _json_value(
            fact.get("cause_detail", fact.get("cause_details", ""))
        ),
        "turn": int(fact.get("turn", fact.get("turn_number", 0))),
    }


def _native_turn_fact_book(snapshot: Any) -> dict[str, Any]:
    source = snapshot if isinstance(snapshot, dict) else {}

    def window(primary: str, fallback: str) -> dict[str, Any]:
        raw = source.get(primary, source.get(fallback, {}))
        row = raw if isinstance(raw, dict) else {}
        facts = [
            mapped
            for fact in row.get("knockouts", [])
            if (mapped := _native_knockout_fact(fact)) is not None
        ]
        return {"knockouts": facts}

    return {
        "current_turn": window("current_turn", "current"),
        "previous_turn": window("previous_turn", "previous"),
    }


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

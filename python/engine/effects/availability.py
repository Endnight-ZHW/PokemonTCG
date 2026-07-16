"""Pre-play legality helpers for effect target/resource availability."""
from __future__ import annotations

from collections.abc import Iterable as IterableABC
from typing import Any

try:
    from engine.commands.ir import OP_BY_EFFECT_TYPE
except Exception:  # pragma: no cover - keep helper importable in data tools.
    OP_BY_EFFECT_TYPE = {}

from engine.effects.runtime_effects import (
    MISSING_COMPILED_OP,
    strict_attack_runtime_effects as attack_runtime_effects,
)


DAMAGE_EFFECT_TYPES = {
    "damage",
    "conditional_damage_bonus",
    "damage_per_discard_psychic",
    "damage_per_energy",
    "damage_per_evolved",
    "damage_per_hand_size",
    "damage_per_self_damage",
    "damage_per_self_energy",
    "damage_per_self_energy_type",
    "damage_plus_bench",
    "damage_self_penalty",
    "discard_fighting_energy_damage",
    "discard_hand_conditional_bonus",
    "mill_and_damage_per_energy",
    "attack_damage_formula",
}


OP_LEGACY_ALIASES = {
    op: effect_type
    for effect_type, op in OP_BY_EFFECT_TYPE.items()
}
OP_LEGACY_ALIASES.update({
    "deal_damage_per_self_damage": "damage_per_self_damage",
    "deal_damage_per_self_energy": "damage_per_self_energy",
    "discard_cards": "discard",
    "draw_cards": "draw",
    "flip_coin": "coin_flip",
    "flip_coin_repeat_damage": "coin_flip_triple",
    "flip_coin_then_discard_energy": "coin_flip_energy_discard",
    "flip_coin_then_ko": "coin_flip_double_ko",
    "flip_until_tails": "coin_flip_until_tails",
    "hand_to_bottom_draw_until": "houb",
    "hand_to_bottom_then_draw": "hand_to_bottom_draw",
    "heal_damage": "heal",
})


def _is_effect_like(value: Any) -> bool:
    if isinstance(value, dict):
        return bool(value.get("effect_type") or value.get("op"))
    return hasattr(value, "effect_type") or hasattr(value, "op")


def _as_effect_list(effects: Any) -> list[Any]:
    if effects is None:
        return []
    if _is_effect_like(effects):
        return [effects]
    if isinstance(effects, (list, tuple)):
        return list(effects)
    if isinstance(effects, IterableABC) and not isinstance(effects, (str, bytes, dict)):
        return list(effects)
    return [effects]


def effect_type(effect: Any) -> str:
    if isinstance(effect, dict):
        op = str(effect.get("op", "") or "")
        if op:
            if op == "switch_pokemon":
                target = str(effect_params(effect).get("target", "self") or "self")
                return "switch_opponent" if target == "opponent" else "switch_self"
            if op == "attach_energy":
                from_zone = str(effect_params(effect).get("from_zone", "") or "")
                return "attach_from_discard" if from_zone == "discard" else "energy_attach"
            return OP_LEGACY_ALIASES.get(op, op)
        return str(effect.get("effect_type", "") or "")
    op = str(getattr(effect, "op", "") or "")
    if op:
        params = effect_params(effect)
        if op == "switch_pokemon":
            target = str(params.get("target", "self") or "self")
            return "switch_opponent" if target == "opponent" else "switch_self"
        if op == "attach_energy":
            from_zone = str(params.get("from_zone", "") or "")
            return "attach_from_discard" if from_zone == "discard" else "energy_attach"
        return OP_LEGACY_ALIASES.get(op, op)
    return str(getattr(effect, "effect_type", "") or "")


def effect_params(effect: Any) -> dict[str, Any]:
    if isinstance(effect, dict):
        params: dict[str, Any] = {}
        raw_params = effect.get("params", {}) or {}
        if isinstance(raw_params, dict):
            params.update(raw_params)
        args = effect.get("args", {}) or {}
        if isinstance(args, dict):
            params.update(args)
        branches = effect.get("branches", {}) or {}
        if isinstance(branches, dict):
            for key, value in branches.items():
                params.setdefault(key, value)
    else:
        params = {}
        raw_params = getattr(effect, "params", {}) or {}
        if isinstance(raw_params, dict):
            params.update(raw_params)
        args = getattr(effect, "args", {}) or {}
        if isinstance(args, dict):
            params.update(args)
        branches = getattr(effect, "branches", {}) or {}
        if isinstance(branches, dict):
            for key, value in branches.items():
                params.setdefault(key, value)
    return dict(params) if isinstance(params, dict) else {}


def effects_have_legal_target(
    state,
    player_idx: int,
    effects: Any,
    *,
    source_slot: str | None = None,
    exclude_hand_index: int | None = None,
    _depth: int = 0,
) -> bool:
    """Return whether at least one effect can legally do something.

    This is intentionally a legality check, not an AI value check. Optional
    effects that allow selecting 0 still need at least one legal selectable
    card or target before the card/ability/attack can be used.
    """
    if _depth > 8:
        return False
    effects = _as_effect_list(effects)
    if not effects:
        return True

    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    saw_checked_effect = False

    for effect in effects:
        etype = effect_type(effect)
        params = effect_params(effect)
        if not etype:
            continue
        if etype == MISSING_COMPILED_OP:
            return False
        if etype in DAMAGE_EFFECT_TYPES:
            return opponent.active is not None
        if etype in {
            "draw",
            "shuffle_draw",
            "discard_draw",
            "discard_then_draw",
            "draw_until",
            "draw_until_more",
            "judge",
            "trekking_shoes",
            "return_to_hand",
            "self_attack_lock",
            "prevent_all",
            "prevent_damage",
            "prevent_effects",
            "attack_flags",
            "tool",
            "tool_exp_share",
            "aura_damage_reduction",
            "aura_damage_boost",
            "conditional_hp_boost",
            "conditional_zero_retreat",
            "reactive_thorns",
            "apply_outgoing_damage_reduction",
        }:
            return True
        if etype in {"hand_to_bottom_draw", "houb"}:
            saw_checked_effect = True
            if _available_hand_count(player, exclude_hand_index) > 0:
                return True
        elif etype == "zinnia_resolve":
            saw_checked_effect = True
            if _available_hand_count(player, exclude_hand_index) >= 2:
                return True
        elif etype == "search":
            saw_checked_effect = True
            if _search_has_target(state, player_idx, params, exclude_hand_index):
                return True
        elif etype == "look_top_deck":
            saw_checked_effect = True
            if _look_top_has_target(state, player_idx, params):
                return True
        elif etype in {"conditional_search_extra", "search_any_and_switch"}:
            saw_checked_effect = True
            search_params = dict(params)
            search_params.setdefault("from_zone", "deck")
            search_params.setdefault("destination", "hand")
            search_params.setdefault("filter", "grass_pokemon" if etype == "conditional_search_extra" else "any")
            if _search_has_target(state, player_idx, search_params, exclude_hand_index):
                return True
        elif etype == "look_top_attach_energy":
            saw_checked_effect = True
            if _look_top_attach_has_target(state, player_idx, params):
                return True
        elif etype == "arven":
            saw_checked_effect = True
            # Deck identities are hidden. A legal search may fail, so only the
            # public deck count participates in availability.
            if player.deck:
                return True
        elif etype == "shuffle_from_discard":
            saw_checked_effect = True
            if _zone_has_matching_cards(player.discard, params):
                return True
        elif etype == "clara":
            saw_checked_effect = True
            if any(getattr(card, "is_pokemon", False) or getattr(card, "is_basic_energy", False) for card in player.discard):
                return True
        elif etype == "energy_attach":
            saw_checked_effect = True
            if _energy_attach_has_target(state, player_idx, params, source_slot, exclude_hand_index):
                return True
        elif etype == "attach_from_discard":
            saw_checked_effect = True
            attach_params = dict(params)
            attach_params["from_zone"] = "discard"
            if _energy_attach_has_target(state, player_idx, attach_params, source_slot, exclude_hand_index):
                return True
        elif etype == "draw_and_attach_energy":
            saw_checked_effect = True
            attach_params = {
                "from_zone": "hand",
                "filter": params.get("energy_type", "Grass"),
                "amount": params.get("energy_count", 2),
                "to": "bench",
            }
            if _energy_attach_has_target(state, player_idx, attach_params, source_slot, exclude_hand_index, include_deck=True):
                return True
        elif etype == "energy_relocate":
            saw_checked_effect = True
            if _energy_relocate_has_target(state, player_idx, params, source_slot):
                return True
        elif etype == "switch_self":
            saw_checked_effect = True
            if player.active is not None and player.bench_count() > 0:
                return True
        elif etype == "switch_opponent":
            saw_checked_effect = True
            if opponent.active is not None and opponent.bench_count() > 0:
                return True
        elif etype == "heal":
            saw_checked_effect = True
            if _heal_has_target(player, params, source_slot):
                return True
        elif etype in {"heal_all", "potion_heal", "damage_and_self_heal", "conditional_damage_heal"}:
            saw_checked_effect = True
            if any(pokemon is not None and pokemon.damage_counters > 0 for _slot, pokemon in player.get_all_pokemon()):
                return True
            if etype in {"damage_and_self_heal", "conditional_damage_heal"} and opponent.active is not None:
                return True
        elif etype == "energy_discard":
            saw_checked_effect = True
            if _energy_discard_has_target(state, player_idx, params, source_slot):
                return True
        elif etype == "coin_flip_energy_discard":
            saw_checked_effect = True
            if any(pokemon is not None and pokemon.energy_cards for _slot, pokemon in opponent.get_all_pokemon()):
                return True
        elif etype in {"any_pokemon_damage", "place_counters_and_self_ko"}:
            saw_checked_effect = True
            if any(pokemon is not None for _slot, pokemon in opponent.get_all_pokemon()):
                return True
        elif etype == "bench_damage":
            saw_checked_effect = True
            if opponent.bench_count() > 0:
                return True
        elif etype in {"status", "conditional_status", "attack_lock_basic", "dazzling_beam"}:
            saw_checked_effect = True
            if opponent.active is not None:
                return True
        elif etype == "damage_counter_self":
            saw_checked_effect = True
            source = player.get_pokemon(source_slot or "active")
            amount = int(params.get("amount", 0) or 0)
            # Self-KO is permitted unless the card text explicitly forbids it.
            if source is not None:
                return True
        elif etype == "evolve_skip_stage":
            saw_checked_effect = True
            if _rare_candy_has_target(player, exclude_hand_index):
                return True
        elif etype == "ability_discard_revive":
            saw_checked_effect = True
            card_id = str(params.get("card_id", "") or "")
            if card_id and any(getattr(card, "api_id", "") == card_id for card in player.discard) and not player.hand and player.bench_has_space():
                return True
        elif etype == "conditional":
            saw_checked_effect = True
            if _conditional_has_target(state, player_idx, params, source_slot, exclude_hand_index, _depth):
                return True
        elif etype in {"coin_flip", "coin_flip_triple", "coin_flip_double_ko", "coin_flip_until_tails"}:
            saw_checked_effect = True
            if _coin_has_target(state, player_idx, params, source_slot, exclude_hand_index, _depth):
                return True
        else:
            return True

    return not saw_checked_effect


def effects_cost_is_payable(
    state,
    player_idx: int,
    effects: Any,
    *,
    exclude_hand_index: int | None = None,
) -> bool:
    """Return whether explicit discard costs in these effects can be paid."""
    for effect in _as_effect_list(effects):
        etype = effect_type(effect)
        params = effect_params(effect)
        if etype == MISSING_COMPILED_OP:
            return False
        if etype == "discard" and not _cost_is_payable(
            state,
            player_idx,
            effect,
            exclude_hand_index,
        ):
            return False
        if etype == "conditional":
            cost = params.get("cost")
            if cost and not _cost_is_payable(
                state,
                player_idx,
                cost,
                exclude_hand_index,
            ):
                return False
    return True


def attack_has_legal_target(state, player_idx: int, attack, source_slot: str = "active") -> bool:
    if getattr(attack, "damage", 0) > 0 and state.get_player(1 - player_idx).active is not None:
        return True
    return effects_have_legal_target(
        state,
        player_idx,
        attack_runtime_effects(attack),
        source_slot=source_slot,
    )


def _available_hand_count(player, exclude_hand_index: int | None) -> int:
    if exclude_hand_index is None:
        return len(player.hand)
    return max(0, len(player.hand) - 1)


def _zone_cards(state, player_idx: int, zone: str, exclude_hand_index: int | None = None):
    player = state.get_player(player_idx)
    if zone == "discard":
        return list(player.discard)
    if zone == "hand":
        return [card for idx, card in enumerate(player.hand) if idx != exclude_hand_index]
    return list(player.deck)


def _search_has_target(state, player_idx: int, params: dict[str, Any], exclude_hand_index: int | None) -> bool:
    player = state.get_player(player_idx)
    destination = str(params.get("destination", "hand") or "hand")
    if destination == "bench" and not player.bench_has_space():
        return False
    if destination == "bench_energy" and not _energy_effect_target_slots(state, player_idx, params, None):
        return False
    from_zone = str(params.get("from_zone", "deck") or "deck")
    if from_zone == "deck":
        return int(params.get("count", 1) or 0) > 0 and bool(player.deck)
    pool = _zone_cards(state, player_idx, from_zone, exclude_hand_index)
    return _zone_has_matching_cards(pool, params)


def _look_top_has_target(state, player_idx: int, params: dict[str, Any]) -> bool:
    player = state.get_player(player_idx)
    if str(params.get("destination", "hand") or "hand") == "bench_energy":
        if not _energy_effect_target_slots(state, player_idx, params, None):
            return False
    return int(params.get("count", 1) or 0) > 0 and bool(player.deck)


def _look_top_attach_has_target(state, player_idx: int, params: dict[str, Any]) -> bool:
    player = state.get_player(player_idx)
    if not any(pokemon is not None for _slot, pokemon in player.get_all_pokemon()):
        return False
    return int(params.get("count", 5) or 0) > 0 and bool(player.deck)


def _zone_has_matching_cards(cards, params: dict[str, Any]) -> bool:
    filter_type = str(params.get("filter", "any") or "any")
    filter_name = str(params.get("filter_name", "") or "")
    return any(_card_matches_filter(card, filter_type, filter_name) for card in cards)


def _card_matches_filter(card, filter_type: str, filter_name: str = "") -> bool:
    if filter_name:
        return getattr(card, "name", "") == filter_name
    normalized = filter_type.lower()
    if normalized in {"", "any"}:
        return True
    if normalized == "basic_pokemon":
        return bool(getattr(card, "is_basic_pokemon", False))
    if normalized == "pokemon":
        return bool(getattr(card, "is_pokemon", False))
    if normalized in {"basic_energy", "basic_energy_card"}:
        return bool(getattr(card, "is_basic_energy", False))
    if normalized in {"energy", "energy_card"}:
        return bool(getattr(card, "is_energy", False))
    if normalized == "supporter":
        return bool(getattr(card, "is_trainer_supporter", False))
    if normalized == "item":
        return bool(getattr(card, "is_trainer_item", False))
    if normalized == "item_or_tool":
        return bool(getattr(card, "is_trainer_item", False) or getattr(card, "is_trainer_tool", False))
    if normalized == "pokemon_and_energy":
        return bool(getattr(card, "is_pokemon", False) or getattr(card, "is_basic_energy", False))
    if normalized == "grass_pokemon":
        return bool(getattr(card, "is_pokemon", False) and "Grass" in getattr(card, "energy_types", []))
    if normalized == "water_pokemon_and_energy":
        return bool(
            (getattr(card, "is_pokemon", False) and "Water" in getattr(card, "energy_types", []))
            or _energy_matches(card, "water")
        )
    if normalized.endswith("_energy"):
        return _energy_matches(card, normalized)
    return True


def _energy_matches(card, filter_type: str) -> bool:
    if not getattr(card, "is_energy", False):
        return False
    normalized = str(filter_type or "any").lower()
    if normalized in {"", "any", "energy"}:
        return True
    if normalized in {"basic", "basic_energy"}:
        return bool(getattr(card, "is_basic_energy", False))
    if normalized.endswith("_energy"):
        normalized = normalized[:-7]
    if normalized == "basic":
        return bool(getattr(card, "is_basic_energy", False))
    return any(str(energy_type).lower() == normalized for energy_type in getattr(card, "provides_energy", []) or [])


def _energy_attach_has_target(
    state,
    player_idx: int,
    params: dict[str, Any],
    source_slot: str | None,
    exclude_hand_index: int | None,
    *,
    include_deck: bool = False,
) -> bool:
    player = state.get_player(player_idx)
    from_zone = str(params.get("from_zone", "deck") or "deck")
    filter_type = str(params.get("filter", params.get("energy_type", "any")) or "any")
    if not _energy_effect_target_slots(state, player_idx, params, source_slot):
        return False
    if from_zone == "deck":
        return bool(player.deck)
    if from_zone == "discard":
        source_cards = player.discard
    elif from_zone == "hand":
        source_cards = _zone_cards(state, player_idx, "hand", exclude_hand_index)
        if include_deck and player.deck:
            return True
    else:
        look_count = int(params.get("count", 0) or 0)
        source_cards = player.deck[-look_count:] if look_count > 0 else player.deck
    if not any(_energy_matches(card, filter_type) for card in source_cards):
        return False
    return True


def _energy_effect_target_slots(state, player_idx: int, params: dict[str, Any], source_slot: str | None) -> list[str]:
    player = state.get_player(player_idx)
    target_spec = str(params.get("to", params.get("target", "self")) or "self")
    if params.get("destination") == "bench_energy":
        target_spec = "bench"
    target_type = str(params.get("target_pokemon_type", "") or "")

    def matches_type(pokemon) -> bool:
        if not target_type:
            return True
        return any(str(card_type).lower() == target_type.lower() for card_type in getattr(pokemon.card, "energy_types", []) or [])

    if target_spec == "self":
        slot = source_slot or "active"
        pokemon = player.get_pokemon(slot)
        return [slot] if pokemon is not None and matches_type(pokemon) else []
    if target_spec == "bench":
        required_type = str(params.get("target_pokemon_type", "") or "")
        if params.get("destination") == "bench_energy":
            required_type = str(params.get("target_pokemon_type", "Lightning") or "Lightning")
        return [
            f"bench_{idx}"
            for idx, pokemon in enumerate(player.bench)
            if pokemon is not None
            and (not required_type or any(str(card_type).lower() == required_type.lower() for card_type in pokemon.card.energy_types))
        ]
    if target_spec in {"any", "self_or_bench"}:
        return [slot for slot, pokemon in player.get_all_pokemon() if pokemon is not None and matches_type(pokemon)]
    if target_spec == "self_basic":
        return [
            slot for slot, pokemon in player.get_all_pokemon()
            if pokemon is not None and pokemon.card.is_basic_pokemon and matches_type(pokemon)
        ]
    pokemon = player.get_pokemon(target_spec)
    return [target_spec] if pokemon is not None and matches_type(pokemon) else []


def _energy_relocate_has_target(state, player_idx: int, params: dict[str, Any], source_slot: str | None) -> bool:
    player = state.get_player(player_idx)
    energy_type = str(params.get("energy_type", params.get("filter", "any")) or "any")
    from_self = bool(params.get("from_self", False))
    if from_self:
        candidates = [(source_slot or "active", player.get_pokemon(source_slot or "active"))]
        target_slots = [slot for slot, pokemon in player.get_all_pokemon() if pokemon is not None and slot != (source_slot or "active")]
    else:
        candidates = [
            (slot, pokemon)
            for slot, pokemon in player.get_all_pokemon()
            if pokemon is not None
        ]
        target_slots = [slot for slot, pokemon in player.get_all_pokemon() if pokemon is not None]
    if not target_slots:
        return False
    for slot, pokemon in candidates:
        if pokemon is None or not any(_energy_matches(card, energy_type) for card in pokemon.energy_cards):
            continue
        if any(target_slot != slot for target_slot in target_slots):
            return True
    return False


def _heal_has_target(player, params: dict[str, Any], source_slot: str | None) -> bool:
    target = str(params.get("target", "self") or "self")
    if target == "self":
        pokemon = player.get_pokemon(source_slot or "active")
        return pokemon is not None and pokemon.damage_counters > 0
    if target == "all":
        return any(pokemon is not None and pokemon.damage_counters > 0 for _slot, pokemon in player.get_all_pokemon())
    pokemon = player.get_pokemon(target)
    return pokemon is not None and pokemon.damage_counters > 0


def _energy_discard_has_target(state, player_idx: int, params: dict[str, Any], source_slot: str | None) -> bool:
    from_target = str(params.get("from", "self") or "self")
    energy_type = str(params.get("filter", params.get("energy_type", "any")) or "any")
    owner = state.get_player(player_idx if from_target == "self" else 1 - player_idx)
    target = owner.get_pokemon(source_slot or "active") if from_target == "self" else owner.active
    if target is None:
        return False
    return any(_energy_matches(card, energy_type) for card in target.energy_cards)


def _rare_candy_has_target(player, exclude_hand_index: int | None) -> bool:
    stage2_cards = [
        card for idx, card in enumerate(player.hand)
        if idx != exclude_hand_index and getattr(card, "is_stage2", False)
    ]
    if not stage2_cards:
        return False
    basics = [pokemon for _slot, pokemon in player.get_all_pokemon() if pokemon is not None and pokemon.card.is_basic_pokemon]
    if not basics:
        return False
    return any(_stage2_can_evolve_from_basic(stage2, basic.card.name) for stage2 in stage2_cards for basic in basics)


def _stage2_can_evolve_from_basic(stage2_card, basic_name: str) -> bool:
    from data.card_registry import CardRegistry

    stage1_name = getattr(stage2_card, "evolves_from", "")
    if not stage1_name:
        return False
    for stage1 in CardRegistry.get_by_name(stage1_name) or []:
        if getattr(stage1, "evolves_from", "").lower() == basic_name.lower():
            return True
    return False


def _conditional_has_target(
    state,
    player_idx: int,
    params: dict[str, Any],
    source_slot: str | None,
    exclude_hand_index: int | None,
    depth: int,
) -> bool:
    player = state.get_player(player_idx)
    condition = str(params.get("condition", "") or "")
    if (
        condition in {"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn"}
        and not state.had_knockout_last_opponent_turn(
            player_idx,
            causes={"attack_damage"},
        )
    ):
        return False
    if (
        condition == "ko_last_opponent_turn"
        and not state.had_knockout_last_opponent_turn(player_idx)
    ):
        return False
    cost = params.get("cost")
    if cost and not _cost_is_payable(state, player_idx, cost, exclude_hand_index):
        return False
    on_pay = params.get("on_pay") or []
    return effects_have_legal_target(
        state,
        player_idx,
        on_pay,
        source_slot=source_slot,
        exclude_hand_index=exclude_hand_index,
        _depth=depth + 1,
    )


def _coin_has_target(
    state,
    player_idx: int,
    params: dict[str, Any],
    source_slot: str | None,
    exclude_hand_index: int | None,
    depth: int,
) -> bool:
    branch_found = False
    for key in ("on_heads", "on_tails", "on_success", "on_fail"):
        branch = params.get(key) or []
        if not branch:
            continue
        branch_found = True
        if effects_have_legal_target(
            state,
            player_idx,
            branch,
            source_slot=source_slot,
            exclude_hand_index=exclude_hand_index,
            _depth=depth + 1,
        ):
            return True
    return not branch_found


def _cost_is_payable(state, player_idx: int, cost: Any, exclude_hand_index: int | None) -> bool:
    costs = _as_effect_list(cost)
    player = state.get_player(player_idx)
    for item in costs:
        etype = effect_type(item)
        params = effect_params(item)
        if etype != "discard":
            continue
        from_zone = str(params.get("from", params.get("from_zone", "hand")) or "hand")
        amount = int(params.get("amount", 1) or 1)
        if from_zone == "hand":
            if _available_hand_count(player, exclude_hand_index) < amount:
                return False
        elif from_zone == "discard" and len(player.discard) < amount:
            return False
    return True

"""Python-authoritative descriptors for every published VM command.

Godot consumes the deterministic JSON export from this table. It must not
maintain a second hand-authored operation inventory or permissive schemas.
"""
from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
import json
from collections.abc import Iterator
from typing import Any, Mapping


DESCRIPTOR_SCHEMA_VERSION = 1
_ALL_CONTEXTS = ("ability", "attack", "trainer", "trigger")


def _field(
    field_type: str | tuple[str, ...],
    *,
    enum: tuple[Any, ...] = (),
    minimum: int | None = None,
    maximum: int | None = None,
    items: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "type": list(field_type) if isinstance(field_type, tuple) else field_type,
    }
    if enum:
        result["enum"] = list(enum)
    if minimum is not None:
        result["minimum"] = minimum
    if maximum is not None:
        result["maximum"] = maximum
    if items is not None:
        result["items"] = dict(items)
    return result


I = _field("integer")
NNI = _field("integer", minimum=0)
PI = _field("integer", minimum=0, maximum=1)
S = _field("string")
B = _field("boolean")
O = _field("object")
PLAYER = _field("string", enum=("self", "opponent"))
STRINGS = _field("array", items=_field("string"))
FORMULA = _field(("object", "integer", "number", "string"))


def _descriptor(
    *,
    args: Mapping[str, Mapping[str, Any]] | None = None,
    required: tuple[str, ...] = (),
    branches: tuple[str, ...] = (),
    semantic_kind: str,
    preflight: str,
    contexts: tuple[str, ...] = _ALL_CONTEXTS,
    attack_timing: str = "none",
    may_suspend: bool = False,
    replaces_base_damage: bool | str = False,
    internal: bool = False,
    implementation_kind: str = "atomic",
) -> dict[str, Any]:
    return {
        "args_schema": {
            "type": "object",
            "properties": {key: dict(value) for key, value in (args or {}).items()},
            "required": list(required),
            "additional_properties": False,
        },
        "branch_schema": {
            "type": "object",
            "allowed_keys": list(branches),
            "required": [],
            "additional_properties": False,
        },
        "semantic_kind": semantic_kind,
        "allowed_contexts": list(contexts),
        "attack_timing": attack_timing,
        "preflight_evaluator": preflight,
        "may_suspend": may_suspend,
        "replaces_base_damage": replaces_base_damage,
        "internal": internal,
        "implementation_kind": implementation_kind,
        "requires_boolean_success": True,
    }


# Every published op is explicit. Helpers only remove schema punctuation.
_DEFINITIONS: dict[str, dict[str, Any]] = {
    "apply_attack_lock_basic": _descriptor(args={"target": S}, semantic_kind="attack_lock_basic", preflight="opponent_active", attack_timing="post_damage"),
    "apply_dazzling_beam": _descriptor(args={"target": S}, semantic_kind="dazzling_beam", preflight="opponent_active", attack_timing="post_damage"),
    "apply_outgoing_damage_reduction": _descriptor(args={"amount": NNI, "target": S}, semantic_kind="apply_outgoing_damage_reduction", preflight="always", attack_timing="post_damage"),
    "apply_self_attack_lock": _descriptor(args={"attack_name": S, "scope": S}, semantic_kind="self_attack_lock", preflight="always", attack_timing="post_damage"),
    "apply_status": _descriptor(args={"status": S, "target": S, "condition": S}, semantic_kind="status", preflight="opponent_active", attack_timing="post_damage"),
    "attach_energy": _descriptor(args={"amount": NNI, "filter": S, "from_zone": S, "going_second_bonus": NNI, "max_per_target": NNI, "min_select": NNI, "optional": B, "select_source": B, "to": S}, semantic_kind="energy_attach", preflight="energy_attach", may_suspend=True),
    "attach_energy_from_discard": _descriptor(args={"amount": NNI, "energy_type": S, "filter": S, "min_select": NNI, "same_target": B, "select_source": B, "target": S, "target_pokemon_type": S}, semantic_kind="attach_from_discard", preflight="attach_from_discard", may_suspend=True),
    "choose_damage_target": _descriptor(args={"amount": NNI, "bench_skips_type_matchups": B, "piercing_on_bench": B, "player": PLAYER}, semantic_kind="any_pokemon_damage", preflight="opponent_pokemon", may_suspend=True),
    "choose_heal_damage": _descriptor(args={"amount": NNI, "player": PLAYER, "target_player": PLAYER}, semantic_kind="potion_heal", preflight="damaged_pokemon", may_suspend=True),
    "conditional": _descriptor(args={"condition": S}, branches=("cost", "on_pay"), semantic_kind="conditional", preflight="conditional", may_suspend=True, implementation_kind="control"),
    "conditional_damage": _descriptor(args={"bonus": I, "condition": S}, semantic_kind="conditional_damage_bonus", preflight="opponent_active", contexts=("attack",), attack_timing="damage", replaces_base_damage=False),
    "conditional_damage_then_heal": _descriptor(args={"base": NNI, "bonus": I}, semantic_kind="conditional_damage_heal", preflight="damage_or_heal", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "conditional_search": _descriptor(args={"default_count": NNI, "filter": S, "max_count": NNI}, semantic_kind="conditional_search_extra", preflight="search", may_suspend=True),
    "conditional_status": _descriptor(args={"condition": S, "status": S, "target": S}, semantic_kind="conditional_status", preflight="opponent_active", contexts=("attack",), attack_timing="post_damage"),
    "deal_bench_damage": _descriptor(args={"amount": NNI, "choose_targets": B, "count": NNI, "player": PLAYER}, semantic_kind="bench_damage", preflight="opponent_bench", attack_timing="damage", may_suspend=True),
    "deal_damage": _descriptor(args={"amount": NNI, "consume_condition": S, "formula_ast": FORMULA, "ignore_defender_damage_effects": B, "ignore_resistance": B, "ignore_weakness": B, "target": S}, semantic_kind="damage", preflight="opponent_active", attack_timing="damage", replaces_base_damage="when_formula_ast"),
    "deal_damage_per_discard_psychic": _descriptor(args={"base": NNI, "per_card": NNI}, semantic_kind="damage_per_discard_psychic", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_per_energy": _descriptor(args={"base": NNI, "count_from": S, "per_energy": NNI, "target": S}, semantic_kind="damage_per_energy", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_per_evolved": _descriptor(args={"per_evolved": NNI}, semantic_kind="damage_per_evolved", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_per_hand_size": _descriptor(args={"per": NNI}, semantic_kind="damage_per_hand_size", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_per_self_damage": _descriptor(args={"base": NNI, "per_counter": NNI}, semantic_kind="damage_per_self_damage", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_per_self_energy": _descriptor(args={"base": NNI, "energy_filter": S, "per_energy": NNI}, semantic_kind="damage_per_self_energy", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_per_self_energy_type": _descriptor(args={"base": NNI, "energy_type": S, "per_energy": NNI}, semantic_kind="damage_per_self_energy_type", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_plus_bench": _descriptor(args={"base": NNI, "count_own_bench": B, "per_bench": NNI}, semantic_kind="damage_plus_bench", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_then_heal": _descriptor(args={"damage": NNI, "heal": NNI}, semantic_kind="damage_and_self_heal", preflight="damage_or_heal", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "deal_damage_with_self_penalty": _descriptor(args={"base": NNI, "per_counter": NNI}, semantic_kind="damage_self_penalty", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "discard_cards": _descriptor(args={"amount": NNI, "from": S, "from_zone": S, "player": PLAYER}, semantic_kind="discard", preflight="discard_cost", may_suspend=True),
    "discard_energy": _descriptor(args={"amount": NNI, "filter": S, "from": S, "energy_type": S}, semantic_kind="energy_discard", preflight="energy_discard", may_suspend=True),
    "discard_energy_then_damage": _descriptor(args={"base": NNI, "per_energy": NNI}, semantic_kind="discard_fighting_energy_damage", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", may_suspend=True, replaces_base_damage=True),
    "discard_hand_then_damage": _descriptor(args={"base_damage": NNI, "bonus": I, "threshold": NNI}, semantic_kind="discard_hand_conditional_bonus", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", may_suspend=True, replaces_base_damage=True),
    "discard_then_draw_cards": _descriptor(args={"discard_amount": NNI, "discard_hand": B, "draw": NNI, "draw_amount": NNI}, semantic_kind="discard_then_draw", preflight="always", may_suspend=True),
    "discard_then_revive": _descriptor(args={"card_id": S, "discard_idx": I}, required=("card_id",), semantic_kind="ability_discard_revive", preflight="discard_revive", contexts=("ability",), may_suspend=True, implementation_kind="native_composite"),
    "draw_and_attach_energy": _descriptor(args={"energy_count": NNI, "energy_type": S, "min_select": NNI}, semantic_kind="draw_and_attach_energy", preflight="draw_attach", may_suspend=True, implementation_kind="native_composite"),
    "draw_cards": _descriptor(args={"amount": NNI, "count": NNI, "player": PLAYER, "stadium_type": S}, semantic_kind="draw", preflight="always"),
    "draw_until": _descriptor(args={"target_hand_size": NNI}, semantic_kind="draw_until", preflight="always"),
    "draw_until_more_than_opponent": _descriptor(args={"margin": NNI}, semantic_kind="draw_until_more", preflight="always"),
    "evolve_skip_stage": _descriptor(args={"skip_to": S}, semantic_kind="evolve_skip_stage", preflight="rare_candy", may_suspend=True, implementation_kind="native_composite"),
    "fail_attack": _descriptor(semantic_kind="attack_fail", preflight="always", contexts=("attack",), attack_timing="pre_damage"),
    "flip_coin": _descriptor(branches=("on_heads", "on_tails"), semantic_kind="coin_flip", preflight="coin_branches", attack_timing="pre_damage", may_suspend=True, implementation_kind="control"),
    "flip_coin_repeat_damage": _descriptor(args={"damage_per_head": NNI, "flips": NNI}, semantic_kind="coin_flip_triple", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", may_suspend=True, replaces_base_damage=True),
    "flip_coin_then_discard_energy": _descriptor(semantic_kind="coin_flip_energy_discard", preflight="opponent_energy", contexts=("trainer",), may_suspend=True),
    "flip_coin_then_ko": _descriptor(semantic_kind="coin_flip_double_ko", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", may_suspend=True),
    "flip_until_tails": _descriptor(args={"per_head": NNI}, semantic_kind="coin_flip_until_tails", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", may_suspend=True, replaces_base_damage=True),
    "hand_to_bottom_draw_until": _descriptor(args={"target_hand_size": NNI}, semantic_kind="houb", preflight="hand_nonempty", may_suspend=True, implementation_kind="native_composite"),
    "hand_to_bottom_then_draw": _descriptor(semantic_kind="hand_to_bottom_draw", preflight="hand_nonempty", may_suspend=True, implementation_kind="native_composite"),
    "heal_all": _descriptor(args={"amount": NNI}, semantic_kind="heal_all", preflight="damaged_pokemon"),
    "heal_damage": _descriptor(args={"amount": NNI, "target": S}, semantic_kind="heal", preflight="heal_target", may_suspend=True),
    "judge": _descriptor(args={"draw": NNI}, semantic_kind="judge", preflight="always", may_suspend=True, implementation_kind="native_composite"),
    "look_top_attach_energy": _descriptor(args={"count": NNI, "filter": S, "shuffle_rest": B, "take": NNI, "target": S}, semantic_kind="look_top_attach_energy", preflight="look_top_attach", may_suspend=True, implementation_kind="native_composite"),
    "look_top_deck": _descriptor(args={"count": NNI, "destination": S, "filter": S, "min_select": NNI, "rest_bottom": B, "shuffle_rest": B, "take": NNI, "target_pokemon_type": S}, semantic_kind="look_top_deck", preflight="look_top", may_suspend=True, implementation_kind="native_composite"),
    "mill_then_damage": _descriptor(args={"damage_per": NNI, "mill_count": NNI}, semantic_kind="mill_and_damage_per_energy", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True, implementation_kind="native_composite"),
    "place_counters_then_self_discard": _descriptor(args={"counters": NNI, "target": S, "target_player": PLAYER}, semantic_kind="place_counters_and_self_discard", preflight="opponent_pokemon", contexts=("ability",), may_suspend=True),
    "place_damage_counters": _descriptor(args={"amount": NNI, "damage_kind": S}, semantic_kind="damage_counter_self", preflight="self_survives_counter"),
    "prevent_all": _descriptor(semantic_kind="prevent_all", preflight="always", contexts=("attack",), attack_timing="post_damage"),
    "prevent_damage": _descriptor(semantic_kind="prevent_damage", preflight="always", contexts=("attack",), attack_timing="post_damage"),
    "prevent_effects": _descriptor(semantic_kind="prevent_effects", preflight="always", contexts=("attack",), attack_timing="post_damage"),
    "recover_clara": _descriptor(args={"energy_count": NNI, "pokemon_count": NNI}, semantic_kind="clara", preflight="clara", may_suspend=True, implementation_kind="native_composite"),
    "register_aura_damage_boost": _descriptor(args={"amount": I, "attacker_subtype": S, "defender_type": S, "priority": I}, semantic_kind="aura_damage_boost", preflight="always"),
    "register_aura_damage_reduction": _descriptor(args={"before_weakness": B, "priority": I, "reduction": NNI, "requires_active": B, "requires_attached_energy": B}, semantic_kind="aura_damage_reduction", preflight="always"),
    "register_conditional_hp_boost": _descriptor(args={"amount": I, "energy_type": S, "priority": I, "threshold": NNI}, semantic_kind="conditional_hp_boost", preflight="always"),
    "register_conditional_zero_retreat": _descriptor(args={"energy_type": S, "priority": I}, semantic_kind="conditional_zero_retreat", preflight="always"),
    "register_reactive_thorns": _descriptor(args={"filter_names": STRINGS, "per_pokemon": NNI, "priority": I}, semantic_kind="reactive_thorns", preflight="always"),
    "register_tool_exp_share": _descriptor(args={"priority": I}, semantic_kind="tool_exp_share", preflight="always"),
    "register_tool_modifier": _descriptor(args={"amount": I, "effect": S, "priority": I}, semantic_kind="tool", preflight="always"),
    "relocate_energy": _descriptor(args={"amount": NNI, "energy_type": S, "from_self": B, "min_select": NNI, "same_target": B}, semantic_kind="energy_relocate", preflight="energy_relocate", may_suspend=True),
    "return_to_hand": _descriptor(semantic_kind="return_to_hand", preflight="always", contexts=("attack",), attack_timing="post_damage"),
    "search_any_and_switch": _descriptor(args={"count": NNI, "min_select": NNI, "source_slot": S, "switch_optional": B}, semantic_kind="search_any_and_switch", preflight="search", may_suspend=True, implementation_kind="native_composite"),
    "search_cards": _descriptor(args={"count": NNI, "destination": S, "filter": S, "filter_name": S, "from_zone": S, "min_select": NNI, "reveal": B}, semantic_kind="search", preflight="search", may_suspend=True),
    "search_item_and_tool": _descriptor(semantic_kind="arven", preflight="deck_nonempty", may_suspend=True, implementation_kind="native_composite"),
    "set_attack_damage_formula": _descriptor(args={"base": NNI, "condition_bonus": O, "ignore_defender_damage_effects": B, "ignore_resistance": B, "ignore_weakness": B, "per_energy": NNI, "per_own_bench": NNI, "per_self_damage_counter": NNI, "per_self_energy_type": S}, semantic_kind="attack_damage_formula", preflight="opponent_active", contexts=("attack",), attack_timing="replace_damage", replaces_base_damage=True),
    "set_attack_flags": _descriptor(args={"ignore_defender_damage_effects": B, "ignore_effects": B, "ignore_resistance": B, "ignore_weakness": B}, semantic_kind="attack_flags", preflight="always", contexts=("attack",), attack_timing="pre_damage"),
    "shuffle_from_discard_to_deck": _descriptor(args={"count": NNI, "filter": S}, semantic_kind="shuffle_from_discard", preflight="discard_search", may_suspend=True),
    "shuffle_then_draw_cards": _descriptor(args={"affect": S, "draw": NNI, "amount": NNI, "shuffle_hand": B}, semantic_kind="shuffle_draw", preflight="always", may_suspend=True),
    "switch_pokemon": _descriptor(args={"optional": B, "target": _field("string", enum=("self", "opponent")), "you_choose": B}, semantic_kind="switch", preflight="switch", may_suspend=True),
    "trekking_shoes": _descriptor(semantic_kind="trekking_shoes", preflight="always", may_suspend=True, implementation_kind="native_composite"),
    "trigger_draw_cards": _descriptor(args={"amount": NNI, "player": PI, "source": S}, required=("amount", "player", "source"), semantic_kind="trigger_draw_cards", preflight="always", contexts=("trigger",), internal=True),
    "trigger_move_basic_energy": _descriptor(args={"from_player": PI, "from_slot": S, "optional": B, "select_source": B, "source": S, "target_tool_id": S, "to_player": PI, "to_slot": S}, required=("from_player", "from_slot", "source", "to_player", "to_slot"), semantic_kind="trigger_move_basic_energy", preflight="trigger_energy", contexts=("trigger",), may_suspend=True, internal=True),
    "trigger_place_damage_counters": _descriptor(args={"count": NNI, "player": PI, "presentation_phase": S, "slot": S, "source": S, "source_kind": S, "source_player": PI, "target_ref": O}, required=("count", "player", "slot", "source"), semantic_kind="trigger_place_damage_counters", preflight="trigger_target", contexts=("trigger",), internal=True),
    "trigger_switch_with_active": _descriptor(args={"bench_idx": NNI, "player": PI, "slot": S, "source": S}, required=("bench_idx", "player", "slot", "source"), semantic_kind="trigger_switch_with_active", preflight="trigger_target", contexts=("trigger",), internal=True),
    "zinnia_resolve": _descriptor(semantic_kind="zinnia_resolve", preflight="hand_two", may_suspend=True, implementation_kind="native_composite"),
}


def _published_descriptor(op: str, descriptor: Mapping[str, Any]) -> dict[str, Any]:
    payload = deepcopy(dict(descriptor))
    payload["op"] = op
    return payload


def _validate_definition(op: str, descriptor: Mapping[str, Any]) -> None:
    required_keys = {
        "args_schema",
        "branch_schema",
        "semantic_kind",
        "allowed_contexts",
        "attack_timing",
        "preflight_evaluator",
        "may_suspend",
        "replaces_base_damage",
        "internal",
        "implementation_kind",
        "requires_boolean_success",
    }
    if set(descriptor) != required_keys:
        raise RuntimeError(f"Invalid VM descriptor fields for {op}")
    args_schema = descriptor["args_schema"]
    branch_schema = descriptor["branch_schema"]
    if (
        args_schema.get("type") != "object"
        or not isinstance(args_schema.get("properties"), dict)
        or not isinstance(args_schema.get("required"), list)
        or args_schema.get("additional_properties") is not False
    ):
        raise RuntimeError(f"Invalid VM args schema for {op}")
    if set(args_schema["required"]) - set(args_schema["properties"]):
        raise RuntimeError(f"VM descriptor requires an unknown arg for {op}")
    if (
        branch_schema.get("type") != "object"
        or not isinstance(branch_schema.get("allowed_keys"), list)
        or not isinstance(branch_schema.get("required"), list)
        or branch_schema.get("additional_properties") is not False
    ):
        raise RuntimeError(f"Invalid VM branch schema for {op}")
    if not descriptor["semantic_kind"] or not descriptor["preflight_evaluator"]:
        raise RuntimeError(f"VM descriptor semantic/preflight kind is missing for {op}")
    if not descriptor["allowed_contexts"]:
        raise RuntimeError(f"VM descriptor contexts are missing for {op}")
    if descriptor["requires_boolean_success"] is not True:
        raise RuntimeError(f"VM descriptor result contract is invalid for {op}")


for _op, _definition in _DEFINITIONS.items():
    _validate_definition(_op, _definition)


class FrozenDescriptorRegistry(Mapping[str, Mapping[str, Any]]):
    """Read-only registry that never exposes its mutable nested storage."""

    def __init__(self, values: Mapping[str, Mapping[str, Any]]) -> None:
        self.__values = deepcopy(dict(values))

    def __getitem__(self, key: str) -> Mapping[str, Any]:
        return deepcopy(self.__values[key])

    def __iter__(self) -> Iterator[str]:
        return iter(self.__values)

    def __len__(self) -> int:
        return len(self.__values)


VM_COMMAND_DESCRIPTORS: Mapping[str, Mapping[str, Any]] = FrozenDescriptorRegistry({
    op: _published_descriptor(op, descriptor)
    for op, descriptor in sorted(_DEFINITIONS.items())
})


def command_descriptors_payload() -> dict[str, dict[str, Any]]:
    return {
        op: deepcopy(dict(descriptor))
        for op, descriptor in VM_COMMAND_DESCRIPTORS.items()
    }


def descriptor_export_payload(vm_ir_version: int) -> dict[str, Any]:
    descriptors = command_descriptors_payload()
    canonical = json.dumps(
        descriptors, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "descriptor_schema_version": DESCRIPTOR_SCHEMA_VERSION,
        "vm_ir_version": int(vm_ir_version),
        "digest_algorithm": "sha256",
        "descriptor_digest": sha256(canonical).hexdigest(),
        # The export pipeline generates one semantic golden for every frozen
        # descriptor. Shipping this inventory lets the Godot composition root
        # enforce the fourth side of descriptor/handler/preflight/golden 1:1
        # completeness without loading test fixtures at runtime.
        "golden_ops": sorted(descriptors),
        "descriptors": descriptors,
    }


if len(VM_COMMAND_DESCRIPTORS) != 80:
    raise RuntimeError(
        f"Published VM descriptor inventory must contain 80 ops, got "
        f"{len(VM_COMMAND_DESCRIPTORS)}"
    )


__all__ = [
    "DESCRIPTOR_SCHEMA_VERSION",
    "VM_COMMAND_DESCRIPTORS",
    "command_descriptors_payload",
    "descriptor_export_payload",
]

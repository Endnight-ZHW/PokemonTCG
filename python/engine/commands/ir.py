"""Serializable VM IR for card effects.

Release card data compiles to this stable command specification so Python,
Godot, AI, and export checks share one rule contract.
"""
from __future__ import annotations

from dataclasses import dataclass, field, is_dataclass, fields
from typing import Any, Iterable


@dataclass(frozen=True)
class CommandSpec:
    """A JSON-friendly VM instruction.

    ``op`` names the atomic operation or VM control frame. ``args`` contains
    serializable parameters. ``branches`` holds nested command lists such as
    coin-flip heads/tails or conditional cost/continuation blocks.
    """

    op: str
    args: dict[str, Any] = field(default_factory=dict)
    branches: dict[str, tuple["CommandSpec", ...]] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "op": self.op,
            "args": _json_safe(self.args),
            "branches": {
                key: [command.to_dict() for command in commands]
                for key, commands in sorted(self.branches.items())
            },
        }


BRANCH_KEYS = frozenset(
    {
        "cost",
        "on_heads",
        "on_tails",
        "on_pay",
        "on_success",
        "on_fail",
        "on_failure",
    }
)


OP_BY_EFFECT_TYPE: dict[str, str] = {
    "ability_discard_revive": "discard_then_revive",
    "any_pokemon_damage": "choose_damage_target",
    "apply_outgoing_damage_reduction": "apply_outgoing_damage_reduction",
    "arven": "search_item_and_tool",
    "attach_from_discard": "attach_energy_from_discard",
    "attack_damage_formula": "set_attack_damage_formula",
    "attack_fail": "fail_attack",
    "attack_lock_basic": "apply_attack_lock_basic",
    "aura_damage_boost": "register_aura_damage_boost",
    "aura_damage_reduction": "register_aura_damage_reduction",
    "bench_damage": "deal_bench_damage",
    "clara": "recover_clara",
    "coin_flip": "flip_coin",
    "coin_flip_double_ko": "flip_coin_then_ko",
    "coin_flip_energy_discard": "flip_coin_then_discard_energy",
    "coin_flip_triple": "flip_coin_repeat_damage",
    "coin_flip_until_tails": "flip_until_tails",
    "conditional": "conditional",
    "conditional_damage_bonus": "conditional_damage",
    "conditional_damage_heal": "conditional_damage_then_heal",
    "conditional_hp_boost": "register_conditional_hp_boost",
    "conditional_search_extra": "conditional_search",
    "conditional_status": "conditional_status",
    "conditional_zero_retreat": "register_conditional_zero_retreat",
    "damage": "deal_damage",
    "damage_and_self_heal": "deal_damage_then_heal",
    "damage_counter_self": "place_damage_counters",
    "damage_per_discard_psychic": "deal_damage",
    "damage_per_energy": "deal_damage",
    "damage_per_evolved": "deal_damage",
    "damage_per_hand_size": "deal_damage",
    "damage_per_self_damage": "deal_damage",
    "damage_per_self_energy": "deal_damage",
    "damage_per_self_energy_type": "deal_damage",
    "damage_plus_bench": "deal_damage",
    "damage_self_penalty": "deal_damage",
    "dazzling_beam": "apply_dazzling_beam",
    "discard": "discard_cards",
    "discard_draw": "discard_then_draw_cards",
    "discard_fighting_energy_damage": "discard_energy_then_damage",
    "discard_hand_conditional_bonus": "discard_hand_then_damage",
    "discard_then_draw": "discard_then_draw_cards",
    "draw": "draw_cards",
    "draw_and_attach_energy": "draw_and_attach_energy",
    "draw_until": "draw_until",
    "draw_until_more": "draw_until_more_than_opponent",
    "energy_attach": "attach_energy",
    "energy_discard": "discard_energy",
    "energy_relocate": "relocate_energy",
    "evolve_skip_stage": "evolve_skip_stage",
    "hand_to_bottom_draw": "hand_to_bottom_then_draw",
    "heal": "heal_damage",
    "heal_all": "heal_all",
    "houb": "hand_to_bottom_draw_until",
    "judge": "judge",
    "look_top_attach_energy": "look_top_attach_energy",
    "look_top_deck": "look_top_deck",
    "mill_and_damage_per_energy": "mill_then_damage",
    "attack_flags": "set_attack_flags",
    "place_counters_and_self_discard": "place_counters_then_self_discard",
    "potion_heal": "choose_heal_damage",
    "prevent_all": "prevent_all",
    "prevent_damage": "prevent_damage",
    "prevent_effects": "prevent_effects",
    "reactive_thorns": "register_reactive_thorns",
    "return_to_hand": "return_to_hand",
    "search": "search_cards",
    "search_any_and_switch": "search_any_and_switch",
    "self_attack_lock": "apply_self_attack_lock",
    "shuffle_draw": "shuffle_then_draw_cards",
    "shuffle_from_discard": "shuffle_from_discard_to_deck",
    "status": "apply_status",
    "switch_opponent": "switch_pokemon",
    "switch_self": "switch_pokemon",
    "tool": "register_tool_modifier",
    "tool_exp_share": "register_tool_exp_share",
    "trekking_shoes": "trekking_shoes",
    "zinnia_resolve": "zinnia_resolve",
}

SUPPORTED_EFFECT_TYPES = frozenset(OP_BY_EFFECT_TYPE)

EFFECT_TYPE_ARG_OPS = frozenset()


def compile_effect_to_spec(effect_def: Any) -> CommandSpec:
    """Compile one EffectDef/dict into serializable IR."""
    effect_type, params = _effect_parts(effect_def)
    formula_args = _formula_args_for_effect(effect_type, params)
    if formula_args is not None:
        return _validated_spec(CommandSpec(
            op="deal_damage", args=_json_safe(formula_args), branches={}
        ))

    op = OP_BY_EFFECT_TYPE.get(effect_type)
    if op is None:
        raise ValueError(f"No VM IR op registered for effect_type={effect_type!r}")

    branches: dict[str, tuple[CommandSpec, ...]] = {}
    args: dict[str, Any] = {"effect_type": effect_type} if op in EFFECT_TYPE_ARG_OPS else {}
    for key, value in params.items():
        if key in BRANCH_KEYS:
            compiled = tuple(compile_effect_to_spec(item) for item in _as_effect_list(value))
            if compiled:
                branches[key] = compiled
        else:
            args[key] = _json_safe(value)
    if op == "switch_pokemon" and "target" not in args:
        args["target"] = "opponent" if effect_type == "switch_opponent" else "self"
    return _validated_spec(CommandSpec(op=op, args=args, branches=branches))


def _validated_spec(spec: CommandSpec) -> CommandSpec:
    # Local imports avoid making the immutable IR dataclass depend on runtime
    # factory initialization while still enforcing the authoritative schema at
    # the DSL boundary.
    from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS
    from engine.commands.vm_contract import assert_command_spec

    assert_command_spec(
        spec.to_dict(),
        supported_ops=frozenset(VM_COMMAND_DESCRIPTORS),
    )
    return spec


def _formula_args_for_effect(effect_type: str, params: dict[str, Any]) -> dict[str, Any] | None:
    formula_ast = _formula_ast_for_effect(effect_type, params)
    if formula_ast is None:
        return None
    args: dict[str, Any] = {"formula_ast": formula_ast}
    if "target" in params:
        args["target"] = params["target"]
    if effect_type == "attack_damage_formula":
        if params.get("ignore_weakness", False):
            args["ignore_weakness"] = True
        if params.get("ignore_resistance", False):
            args["ignore_resistance"] = True
        if params.get("ignore_defender_damage_effects", False):
            args["ignore_defender_damage_effects"] = True
    return args


def _formula_ast_for_effect(effect_type: str, params: dict[str, Any]) -> dict[str, Any] | None:
    if effect_type == "attack_damage_formula":
        terms: list[Any] = [_const(params.get("base", 0))]
        per_own_bench = int(params.get("per_own_bench", 0) or 0)
        if per_own_bench:
            terms.append(_mul({"op": "bench_count", "player": "self"}, _const(per_own_bench)))
        per_counter = int(params.get("per_self_damage_counter", 0) or 0)
        if per_counter:
            terms.append(_mul({"op": "damage_counters", "target": "self"}, _const(per_counter)))
        energy_type = str(params.get("per_self_energy_type", "") or "")
        if energy_type:
            terms.append(_mul(
                {"op": "energy_count", "scope": "self", "energy_type": energy_type},
                _const(params.get("per_energy", 0)),
            ))
        condition_bonus = params.get("condition_bonus") or {}
        if isinstance(condition_bonus, dict):
            condition = str(condition_bonus.get("condition", "") or "")
            if condition:
                terms.append({
                    "op": "if",
                    "condition": condition,
                    "then": _const(condition_bonus.get("bonus", 0)),
                    "else": _const(0),
                })
        return terms[0] if len(terms) == 1 else _add(*terms)
    if effect_type == "damage_per_discard_psychic":
        return _add(
            _const(params.get("base", 80)),
            _mul(
                {
                    "op": "discard_count",
                    "player": "self",
                    "filter": {"card_type": "pokemon", "energy_type": "Psychic"},
                },
                _const(params.get("per_card", 10)),
            ),
        )
    if effect_type == "damage_per_energy":
        return _add(
            _const(params.get("base", 0)),
            _mul(
                {
                    "op": "energy_count",
                    "scope": str(params.get("count_from", "self") or "self"),
                    "energy_type": str(params.get("energy_filter", params.get("energy_type", "any")) or "any"),
                },
                _const(params.get("per_energy", 0)),
            ),
        )
    if effect_type == "damage_per_evolved":
        return _mul(
            {"op": "evolved_count", "player": "self"},
            _const(params.get("per_evolved", 50)),
        )
    if effect_type == "damage_per_hand_size":
        return _mul({"op": "hand_size", "player": "self"}, _const(params.get("per", 0)))
    if effect_type == "damage_per_self_damage":
        return _add(
            _const(params.get("base", 0)),
            _mul(
                {"op": "damage_counters", "target": "self"},
                _const(params.get("per_counter", 0)),
            ),
        )
    if effect_type == "damage_per_self_energy":
        return _add(
            _const(params.get("base", 60)),
            _mul(
                {
                    "op": "energy_count",
                    "scope": "self",
                    "energy_type": str(params.get("energy_filter", "fire") or "fire"),
                },
                _const(params.get("per_energy", 20)),
            ),
        )
    if effect_type == "damage_per_self_energy_type":
        return _add(
            _const(params.get("base", 60)),
            _mul(
                {
                    "op": "energy_count",
                    "scope": "self",
                    "energy_type": str(params.get("energy_type", "Grass") or "Grass"),
                },
                _const(params.get("per_energy", 20)),
            ),
        )
    if effect_type == "damage_plus_bench":
        return _add(
            _const(params.get("base", 0)),
            _mul({"op": "bench_count", "player": "self"}, _const(params.get("per_bench", 0))),
        )
    if effect_type == "damage_self_penalty":
        return _sub(
            _const(params.get("base", 0)),
            _mul(
                {"op": "damage_counters", "target": "self"},
                _const(params.get("per_counter", 0)),
            ),
        )
    return None


def _const(value: Any) -> dict[str, int]:
    return {"const": int(value or 0)}


def _add(*terms: Any) -> dict[str, Any]:
    return {"op": "add", "terms": list(terms)}


def _mul(*factors: Any) -> dict[str, Any]:
    return {"op": "mul", "factors": list(factors)}


def _sub(lhs: Any, rhs: Any) -> dict[str, Any]:
    return {"op": "sub", "lhs": lhs, "rhs": rhs}


def compile_effects_to_specs(effect_defs: Iterable[Any]) -> list[CommandSpec]:
    return [compile_effect_to_spec(effect_def) for effect_def in effect_defs or []]


def compile_effects_to_payload(effect_defs: Iterable[Any]) -> list[dict[str, Any]]:
    return [spec.to_dict() for spec in compile_effects_to_specs(effect_defs)]


def collect_effect_types(value: Any) -> set[str]:
    """Return all nested effect_type strings from raw card effect data."""
    found: set[str] = set()
    if isinstance(value, dict):
        effect_type = value.get("effect_type")
        if isinstance(effect_type, str) and effect_type:
            found.add(effect_type)
        for item in value.values():
            found.update(collect_effect_types(item))
    elif isinstance(value, (list, tuple)):
        for item in value:
            found.update(collect_effect_types(item))
    elif hasattr(value, "effect_type"):
        effect_type = getattr(value, "effect_type", "")
        if effect_type:
            found.add(str(effect_type))
        found.update(collect_effect_types(getattr(value, "params", {}) or {}))
    elif is_dataclass(value):
        for item in fields(value):
            found.update(collect_effect_types(getattr(value, item.name)))
    return found


def missing_ir_effect_types(value: Any) -> set[str]:
    return collect_effect_types(value) - SUPPORTED_EFFECT_TYPES


def _effect_parts(effect_def: Any) -> tuple[str, dict[str, Any]]:
    if hasattr(effect_def, "effect_type"):
        effect_type = str(getattr(effect_def, "effect_type", "") or "")
        params = dict(getattr(effect_def, "params", {}) or {})
    elif isinstance(effect_def, dict):
        effect_type = str(effect_def.get("effect_type", "") or "")
        params = dict(effect_def.get("params", {}) or {})
    else:
        raise ValueError(f"Invalid effect definition: {effect_def!r}")
    if not effect_type:
        raise ValueError(f"Effect definition is missing effect_type: {effect_def!r}")
    return effect_type, params


def _as_effect_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def _json_safe(value: Any) -> Any:
    if isinstance(value, CommandSpec):
        return value.to_dict()
    if hasattr(value, "effect_type"):
        effect_type, params = _effect_parts(value)
        return {"effect_type": effect_type, "params": _json_safe(params)}
    if is_dataclass(value):
        return {
            item.name: _json_safe(getattr(value, item.name))
            for item in fields(value)
        }
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if isinstance(value, set):
        return sorted(_json_safe(item) for item in value)
    return value

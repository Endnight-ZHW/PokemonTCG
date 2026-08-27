"""Effect metadata helpers shared by heuristic and learned AI.

The rules runtime is moving from raw ``effect_type`` data to VM command IR.
AI feature extraction should understand both shapes during the migration.
"""
from __future__ import annotations

from collections.abc import Iterable as IterableABC
from typing import Any, Iterable

try:
    from engine.commands.ir import OP_BY_EFFECT_TYPE
except Exception:  # pragma: no cover - AI helpers should still import in tools.
    OP_BY_EFFECT_TYPE = {}

BRANCH_KEYS = ("on_heads", "on_tails", "on_success", "on_fail", "on_pay")

OP_LEGACY_ALIASES = {
    op: legacy_type
    for legacy_type, op in OP_BY_EFFECT_TYPE.items()
}
OP_LEGACY_ALIASES.update({
    "apply_outgoing_damage_reduction": "apply_outgoing_damage_reduction",
    "apply_self_attack_lock": "self_attack_lock",
    "attach_energy": "energy_attach",
    "choose_heal_damage": "potion_heal",
    "deal_damage": "damage",
    "deal_damage_per_self_damage": "damage_per_self_damage",
    "deal_damage_per_self_energy": "damage_per_self_energy",
    "discard_cards": "discard",
    "discard_energy": "energy_discard",
    "discard_energy_then_damage": "discard_fighting_energy_damage",
    "discard_hand_then_damage": "discard_hand_conditional_bonus",
    "discard_then_draw_cards": "discard_then_draw",
    "draw_cards": "draw",
    "draw_until_more_than_opponent": "draw_until_more",
    "flip_coin": "coin_flip",
    "flip_coin_repeat_damage": "coin_flip_triple",
    "flip_coin_then_discard_energy": "coin_flip_energy_discard",
    "flip_coin_then_ko": "coin_flip_double_ko",
    "flip_until_tails": "coin_flip_until_tails",
    "hand_to_bottom_draw_until": "houb",
    "hand_to_bottom_then_draw": "hand_to_bottom_draw",
    "heal_damage": "heal",
    "look_top_attach_energy": "look_top_attach_energy",
    "place_counters_then_self_discard": "place_counters_and_self_discard",
    "register_tool_modifier": "tool",
    "relocate_energy": "energy_relocate",
    "search_cards": "search",
    "shuffle_from_discard_to_deck": "shuffle_from_discard",
    "shuffle_then_draw_cards": "shuffle_draw",
})

FULL_DAMAGE_EFFECT_TYPES = frozenset({
    "damage_per_self_damage",
    "damage_per_self_energy",
    "damage_per_self_energy_type",
    "damage_plus_bench",
    "damage_per_hand_size",
    "damage_per_energy",
    "damage_per_evolved",
    "damage_self_penalty",
    "damage_per_discard_psychic",
    "conditional_damage_heal",
    "damage_and_self_heal",
    "discard_fighting_energy_damage",
    "discard_hand_conditional_bonus",
    "coin_flip_triple",
    "coin_flip_until_tails",
    "mill_and_damage_per_energy",
    "attack_damage_formula",
})


def is_effect_like(value: Any) -> bool:
    if isinstance(value, dict):
        return bool(value.get("effect_type") or value.get("op"))
    return hasattr(value, "op") or hasattr(value, "effect_type")


def as_effect_list(effects: Any) -> list[Any]:
    if effects is None:
        return []
    if is_effect_like(effects):
        return [effects]
    if isinstance(effects, (list, tuple)):
        return list(effects)
    if isinstance(effects, IterableABC) and not isinstance(effects, (str, bytes, dict)):
        return list(effects)
    return [effects]


def effect_params(effect: Any) -> dict[str, Any]:
    params: dict[str, Any] = {}
    if _compiled_op(effect):
        args = _compiled_args(effect)
        if isinstance(args, dict):
            params.update(args)
        branches = _compiled_branches(effect)
        if isinstance(branches, dict):
            for key, value in branches.items():
                params.setdefault(key, value)
    elif isinstance(effect, dict):
        raw_params = effect.get("params")
        if isinstance(raw_params, dict):
            params.update(raw_params)
    else:
        params = getattr(effect, "params", {})
    return params if isinstance(params, dict) else {}


def effect_type(effect: Any) -> str:
    op = _compiled_op(effect)
    if op:
        if op == "deal_damage":
            formula_names = formula_ast_feature_names(effect_params(effect).get("formula_ast"))
            if formula_names:
                return formula_names[0]
        if op == "switch_pokemon":
            target = str(effect_params(effect).get("target", "self") or "self")
            return "switch_opponent" if target == "opponent" else "switch_self"
        if op == "attach_energy":
            from_zone = str(effect_params(effect).get("from_zone", "") or "")
            return "attach_from_discard" if from_zone == "discard" else "energy_attach"
        return OP_LEGACY_ALIASES.get(op, op)
    if isinstance(effect, dict):
        raw_type = str(effect.get("effect_type", "") or "")
        if raw_type:
            return raw_type
    return str(getattr(effect, "effect_type", effect) or "")


def effect_feature_names(effect: Any) -> tuple[str, ...]:
    names: list[str] = []
    alias = effect_type(effect)
    if alias:
        names.append(alias)
    if isinstance(effect, dict):
        op = str(effect.get("op", "") or "")
        if op:
            names.append(op)
        if op == "deal_damage":
            names.extend(formula_ast_feature_names(effect_params(effect).get("formula_ast")))
            if effect_params(effect).get("formula_ast") is not None:
                names.append("damage_formula")
                names.append("damage")
    return tuple(dict.fromkeys(names))


def effect_replaces_base_damage(effect: Any) -> bool:
    """AI metadata query; actual attack settlement remains in ptcg_core."""
    alias = effect_type(effect)
    if alias in FULL_DAMAGE_EFFECT_TYPES:
        return True
    op = _compiled_op(effect)
    return op == "deal_damage" and "formula_ast" in effect_params(effect)


def formula_ast_feature_names(formula_ast: Any) -> tuple[str, ...]:
    if formula_ast is None:
        return ()
    ops = set(_walk_formula_ops(formula_ast))
    names: list[str] = []
    if "discard_count" in ops:
        names.append("damage_per_discard_psychic")
    if "evolved_count" in ops:
        names.append("damage_per_evolved")
    if "hand_size" in ops:
        names.append("damage_per_hand_size")
    if "bench_count" in ops:
        names.append("damage_plus_bench")
    if "energy_count" in ops:
        scopes = {
            str(node.get("scope", node.get("target", "self")) or "self")
            for node in _walk_formula_nodes(formula_ast)
            if isinstance(node, dict)
            and str(node.get("op", node.get("type", "")) or "") == "energy_count"
        }
        if scopes and scopes <= {"self", "self_active", "source"}:
            names.append("damage_per_self_energy")
        else:
            names.append("damage_per_energy")
    if "damage_counters" in ops:
        root_op = (
            str(formula_ast.get("op", formula_ast.get("type", "")) or "")
            if isinstance(formula_ast, dict)
            else ""
        )
        names.append("damage_self_penalty" if root_op == "sub" else "damage_per_self_damage")
    return tuple(dict.fromkeys(names))


def _walk_formula_ops(node: Any):
    for child in _walk_formula_nodes(node):
        if isinstance(child, dict):
            op = str(child.get("op", child.get("type", "")) or "")
            if op:
                yield op
        elif isinstance(child, str):
            yield child


def _walk_formula_nodes(node: Any):
    yield node
    if isinstance(node, dict):
        for value in node.values():
            yield from _walk_formula_nodes(value)
    elif isinstance(node, (list, tuple)):
        for value in node:
            yield from _walk_formula_nodes(value)


def effect_branches(effect: Any) -> Iterable[Any]:
    for key in BRANCH_KEYS:
        yield from effect_branch(effect, key)


def effect_branch(effect: Any, key: str) -> list[Any]:
    branch: list[Any] = []
    if _compiled_op(effect):
        branches = _compiled_branches(effect)
        if isinstance(branches, dict) and key in branches:
            branch.extend(as_effect_list(branches.get(key)))
    elif isinstance(effect, dict):
        raw_params = effect.get("params")
        if isinstance(raw_params, dict):
            branch.extend(as_effect_list(raw_params.get(key)))
    else:
        params = getattr(effect, "params", {})
        if isinstance(params, dict):
            branch.extend(as_effect_list(params.get(key)))
    return branch


def _compiled_op(effect: Any) -> str:
    if isinstance(effect, dict):
        return str(effect.get("op", "") or "")
    return str(getattr(effect, "op", "") or "")


def _compiled_args(effect: Any) -> Any:
    if isinstance(effect, dict):
        return effect.get("args")
    return getattr(effect, "args", None)


def _compiled_branches(effect: Any) -> Any:
    if isinstance(effect, dict):
        return effect.get("branches")
    return getattr(effect, "branches", None)


def iter_effects_recursive(effects: Any):
    for effect in as_effect_list(effects):
        if effect is None:
            continue
        yield effect
        yield from iter_effects_recursive(effect_branches(effect))
        cost = effect_params(effect).get("cost")
        if cost:
            yield from iter_effects_recursive(cost)

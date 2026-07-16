"""Structured damage formula evaluator for VM command specs."""
from __future__ import annotations

from typing import Any, TYPE_CHECKING
from engine.energy_view import EnergyView

if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext


def evaluate_formula_ast(node: Any, ctx: ResolutionContext) -> int:
    """Evaluate a small arithmetic AST against a resolution context."""
    return max(0, int(_eval(node, ctx)))


def _eval(node: Any, ctx: ResolutionContext) -> int:
    if isinstance(node, bool):
        return int(node)
    if isinstance(node, (int, float)):
        return int(node)
    if isinstance(node, str):
        return _eval_variable(node, ctx, {})
    if not isinstance(node, dict):
        raise ValueError(f"Invalid formula AST node: {node!r}")

    if "const" in node:
        return int(node["const"] or 0)
    op = str(node.get("op", node.get("type", "")) or "")
    if op in {"const", "number"}:
        return int(node.get("value", 0) or 0)
    if op in {"add", "sum"}:
        return sum(_eval(child, ctx) for child in _node_children(node))
    if op == "sub":
        lhs, rhs = _binary_children(node)
        return _eval(lhs, ctx) - _eval(rhs, ctx)
    if op in {"mul", "product"}:
        total = 1
        for child in _node_children(node):
            total *= _eval(child, ctx)
        return total
    if op == "div":
        lhs, rhs = _binary_children(node)
        divisor = _eval(rhs, ctx)
        if divisor == 0:
            raise ValueError("Formula AST division by zero")
        return int(_eval(lhs, ctx) / divisor)
    if op == "neg":
        return -_eval(node.get("value", node.get("expr", 0)), ctx)
    if op in {"max", "min"}:
        values = [_eval(child, ctx) for child in _node_children(node)]
        if not values:
            return 0
        return max(values) if op == "max" else min(values)
    if op in {"if", "conditional"}:
        condition = str(node.get("condition", "") or "")
        selected = node.get("then", node.get("on_true", 0)) if condition_applies(condition, ctx) else node.get("else", node.get("on_false", 0))
        return _eval(selected, ctx)
    if op == "condition":
        return 1 if condition_applies(str(node.get("condition", "") or ""), ctx) else 0
    return _eval_variable(op, ctx, node)


def _node_children(node: dict[str, Any]) -> list[Any]:
    for key in ("terms", "factors", "values", "args"):
        value = node.get(key)
        if isinstance(value, list):
            return value
    if "lhs" in node and "rhs" in node:
        return [node["lhs"], node["rhs"]]
    if "left" in node and "right" in node:
        return [node["left"], node["right"]]
    value = node.get("value", 0)
    return value if isinstance(value, list) else [value]


def _binary_children(node: dict[str, Any]) -> tuple[Any, Any]:
    children = _node_children(node)
    if len(children) != 2:
        raise ValueError(f"Formula AST op requires two operands: {node!r}")
    return children[0], children[1]


def _eval_variable(op: str, ctx: ResolutionContext, node: dict[str, Any]) -> int:
    if op == "hand_size":
        return len(_player(ctx, node.get("player", "self")).hand)
    if op == "bench_count":
        return _player(ctx, node.get("player", "self")).bench_count()
    if op == "energy_count":
        return _energy_count(ctx, node)
    if op == "damage_counters":
        pokemon = _pokemon_target(ctx, node.get("target", "self"))
        return int(getattr(pokemon, "damage_counters", 0) or 0) if pokemon else 0
    if op == "discard_count":
        player = _player(ctx, node.get("player", "self"))
        filter_spec = node.get("filter", {})
        return sum(1 for card in player.discard if _card_matches(card, filter_spec))
    if op == "evolved_count":
        player = _player(ctx, node.get("player", "self"))
        return sum(
            1
            for _slot, pokemon in player.get_all_pokemon()
            if pokemon is not None and not pokemon.card.is_basic_pokemon
        )
    raise ValueError(f"Unknown formula AST op: {op!r}")


def condition_applies(condition: str, ctx: ResolutionContext) -> bool:
    condition = str(condition or "")
    if condition in {"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn"}:
        return ctx.state.had_knockout_last_opponent_turn(
            ctx.player_idx,
            causes={"attack_damage"},
        )
    if condition == "ko_last_opponent_turn":
        return ctx.state.had_knockout_last_opponent_turn(ctx.player_idx)
    if condition == "own_bench_damaged":
        return any(pokemon is not None and pokemon.damage_counters > 0 for pokemon in ctx.player.bench)
    if condition == "opponent_active_evolved":
        defender = ctx.opponent.active
        return defender is not None and not defender.card.is_basic_pokemon
    if condition == "opponent_active_damaged":
        defender = ctx.opponent.active
        return defender is not None and defender.damage_counters > 0
    if condition == "own_hand_empty":
        return len(ctx.player.hand) == 0
    return False


def _player(ctx: ResolutionContext, key: Any):
    return ctx.opponent if str(key or "self") == "opponent" else ctx.player


def _pokemon_target(ctx: ResolutionContext, target: Any):
    target_key = str(target or "self")
    if target_key in {"opponent", "opponent_active"}:
        return ctx.opponent.active
    if target_key in {"self", "self_active", "source"}:
        return ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
    return None


def _energy_count(ctx: ResolutionContext, node: dict[str, Any]) -> int:
    scope = str(node.get("scope", node.get("target", "self")) or "self")
    energy_type = str(node.get("energy_type", node.get("filter", "any")) or "any").lower()
    pokemons = []
    if scope in {"self", "self_active", "source"}:
        pokemons = [_pokemon_target(ctx, "self")]
    elif scope in {"opponent", "opponent_active"}:
        pokemons = [ctx.opponent.active]
    elif scope in {"all_self", "self_all"}:
        pokemons = [pokemon for _slot, pokemon in ctx.player.get_all_pokemon()]
    elif scope in {"all_opponent", "opponent_all"}:
        pokemons = [pokemon for _slot, pokemon in ctx.opponent.get_all_pokemon()]
    else:
        raise ValueError(f"Unknown energy_count scope: {scope!r}")
    return sum(_matching_energy_count(pokemon, energy_type) for pokemon in pokemons if pokemon)


def _matching_energy_count(pokemon, energy_type: str) -> int:
    return EnergyView.from_pokemon(pokemon).count(energy_type)


def _card_matches(card, filter_spec: Any) -> bool:
    if not isinstance(filter_spec, dict):
        return True
    card_type = str(filter_spec.get("card_type", "") or "").lower()
    if card_type == "pokemon" and not getattr(card, "is_pokemon", False):
        return False
    if card_type == "energy" and not getattr(card, "is_energy", False):
        return False
    energy_type = str(filter_spec.get("energy_type", "") or "")
    if energy_type:
        if energy_type not in getattr(card, "energy_types", []):
            return False
    return True

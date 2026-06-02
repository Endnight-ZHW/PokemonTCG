"""DSL Compiler — translates EffectDef data into atomic primitive Commands.

This is the bridge between existing card effect data (effect_type + params)
and the new atomic primitives. The compiler tries to map to primitives first;
if no mapping exists, it falls back to LegacyEffectCommand.
"""
from __future__ import annotations
from typing import Callable, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import ICommand
    from engine.commands.primitives import DealDamage

# Registry: effect_type -> factory(parsed_params) -> ICommand
_primitives_registry: dict[str, Callable] = {}


def register_primitive(effect_type: str, factory: Callable):
    """Register a primitive compiler for an effect type."""
    _primitives_registry[effect_type] = factory


def compile_effect(effect_def, **overrides) -> ICommand:
    """Compile a single EffectDef into an ICommand (primitive or legacy).

    Args:
        effect_def: EffectDef object or dict with effect_type + params
        **overrides: passed through to the command factory
    """
    from engine.commands.effects.legacy_adapter import LegacyEffectCommand

    if hasattr(effect_def, 'effect_type'):
        etype = effect_def.effect_type
        params = dict(effect_def.params)
    elif isinstance(effect_def, dict):
        etype = effect_def.get("effect_type", "")
        params = dict(effect_def.get("params", {}))
    else:
        raise ValueError(f"Invalid effect_def: {effect_def}")

    factory = _primitives_registry.get(etype)
    if factory is not None:
        return factory(params, **overrides)

    # Fallback to legacy adapter
    return LegacyEffectCommand(effect_type=etype, params=params)


def compile_effects(effect_defs: list, **overrides) -> list[ICommand]:
    """Compile a list of EffectDefs into ICommands."""
    return [compile_effect(e, **overrides) for e in effect_defs]


# ═══════════════════════════════════════════════════════
# Primitive Mappings
# ═══════════════════════════════════════════════════════

def _make_damage(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=params.get("amount", 0),
        target=params.get("target", "opponent_active"),
        piercing=params.get("piercing", False),
    )


def _make_damage_counter_self(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=params.get("amount", 0),
        target="self",
    )


def _make_bench_damage(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=params.get("amount", 0),
        target="opponent_bench",
        spread_count=params.get("count", 1),
    )


def _make_any_pokemon_damage(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=params.get("amount", 0),
        target="any_opponent",
        piercing=params.get("piercing_on_bench", False),
        spread_count=1,
    )


def _make_damage_per_hand_size(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=0,
        target="opponent_active",
        formula=f"hand_size * {params.get('per', 20)}",
    )


def _make_status(params: dict, **_kw):
    from engine.commands.primitives import ApplyStatus
    return ApplyStatus(
        status=params.get("status", ""),
        target=params.get("target", "opponent_active"),
    )


def _make_conditional_status(params: dict, **_kw):
    from engine.commands.primitives import ApplyStatus
    return ApplyStatus(
        status=params.get("status", ""),
        target=params.get("target", "opponent_active"),
        condition=params.get("condition", ""),
    )


def _make_draw(params: dict, **_kw):
    from engine.commands.primitives import DrawCards
    return DrawCards(
        count=params.get("amount", 1),
        player=params.get("player", "self"),
    )


def _make_discard_energy(params: dict, **_kw):
    from engine.commands.primitives import DiscardEnergy
    return DiscardEnergy(
        amount=params.get("amount", 1),
        from_target=params.get("from", "self"),
        energy_filter=params.get("filter", "any"),
    )


def _make_heal(params: dict, **_kw):
    from engine.commands.primitives import HealDamage
    return HealDamage(
        amount=params.get("amount", 0),
        target=params.get("target", "self"),
    )


def _make_heal_all(params: dict, **_kw):
    from engine.commands.primitives import HealDamage
    return HealDamage(
        amount=params.get("amount", 0),
        target="all",
    )


def _make_potion_heal(params: dict, **_kw):
    from engine.commands.primitives import HealDamage
    return HealDamage(
        amount=params.get("amount", 30),
        target="self",
    )


def _make_switch_self(params: dict, **_kw):
    from engine.commands.primitives import SwitchPokemon
    return SwitchPokemon(
        target="self",
        optional=params.get("optional", False),
    )


def _make_switch_opponent(params: dict, **_kw):
    from engine.commands.primitives import SwitchPokemon
    return SwitchPokemon(
        target="opponent",
        you_choose=params.get("you_choose", False),
    )


def _make_discard(params: dict, **_kw):
    from engine.commands.primitives import DiscardCards
    return DiscardCards(
        amount=params.get("amount", 1),
        from_zone=params.get("from", "hand"),
        player="self",
    )


# Register all primitive mappings
_EFFECT_TO_PRIMITIVE = {
    "damage": _make_damage,
    "damage_counter_self": _make_damage_counter_self,
    "bench_damage": _make_bench_damage,
    "any_pokemon_damage": _make_any_pokemon_damage,
    "damage_per_hand_size": _make_damage_per_hand_size,
    "status": _make_status,
    "conditional_status": _make_conditional_status,
    "draw": _make_draw,
    "energy_discard": _make_discard_energy,
    "heal": _make_heal,
    "heal_all": _make_heal_all,
    "potion_heal": _make_potion_heal,
    "switch_self": _make_switch_self,
    "switch_opponent": _make_switch_opponent,
    "discard": _make_discard,
}


for etype, factory in _EFFECT_TO_PRIMITIVE.items():
    register_primitive(etype, factory)

"""MAX_HP hook helpers for Pokemon in play."""
from __future__ import annotations

from engine.effects.availability import effect_params, effect_type
from engine.effects.modifier_manager import MAX_HP, ModifierManager
from engine.effects.runtime_effects import (
    strict_ability_runtime_effects as ability_runtime_effects,
    strict_trainer_runtime_effects as trainer_runtime_effects,
)
from engine.rules_constants import DAMAGE_PER_COUNTER, TOOL_HP_BOOST


def current_hp(pokemon) -> int:
    """Return remaining HP after MAX_HP modifiers and damage counters."""
    max_hp = int(getattr(pokemon.card, "hp", 0) or 0)
    manager = ModifierManager(None)
    _register_max_hp_hooks(manager, pokemon)
    for modifier in manager.emit(MAX_HP, pokemon=pokemon):
        if not isinstance(modifier, dict):
            continue
        if "set_hp" in modifier:
            max_hp = max(0, int(modifier.get("set_hp", max_hp) or 0))
        elif "delta" in modifier:
            max_hp = max(0, max_hp + int(modifier.get("delta", 0) or 0))
    return max(0, max_hp - pokemon.damage_counters * DAMAGE_PER_COUNTER)


def _register_max_hp_hooks(manager: ModifierManager, pokemon) -> None:
    if pokemon.attached_tool:
        for effect in trainer_runtime_effects(pokemon.attached_tool):
            if effect_params(effect).get("effect") != "hp_boost_basic":
                continue
            manager.register(
                MAX_HP,
                _tool_hp_boost_basic,
                source=getattr(pokemon.attached_tool, "api_id", "tool_hp_boost"),
                owner_player=-1,
            )

    for ability in pokemon.card.abilities or []:
        for effect in ability_runtime_effects(ability):
            if effect_type(effect) != "conditional_hp_boost":
                continue
            params = effect_params(effect)
            manager.register(
                MAX_HP,
                lambda data, params=params: _conditional_hp_boost(data["pokemon"], params),
                source="conditional_hp_boost",
                owner_player=-1,
            )

    for modifier in pokemon.max_hp_modifiers:
        modifier_kind = modifier.get("modifier_kind", modifier.get("effect_type"))
        if modifier_kind != "conditional_hp_boost":
            continue
        params = dict(modifier)
        manager.register(
            MAX_HP,
            lambda data, params=params: _conditional_hp_boost(data["pokemon"], params),
            source=str(modifier.get("source", "conditional_hp_boost")),
            owner_player=-1,
        )


def _tool_hp_boost_basic(data: dict) -> dict | None:
    pokemon = data["pokemon"]
    if pokemon.card.is_basic_pokemon:
        return {"delta": TOOL_HP_BOOST, "source": "hp_boost_basic"}
    return None


def _conditional_hp_boost(pokemon, params: dict) -> dict | None:
    energy_type = str(params.get("energy_type", "") or "").lower()
    threshold = int(params.get("threshold", 0) or 0)
    amount = int(params.get("amount", 0) or 0)
    matching = sum(
        1
        for card in pokemon.energy_cards
        if any(str(provided).lower() == energy_type for provided in card.provides_energy)
    )
    if matching >= threshold:
        return {"delta": amount, "source": "conditional_hp_boost"}
    return None

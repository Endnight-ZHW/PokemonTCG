"""CAN_RETREAT hook helpers for retreat-cost calculation."""
from __future__ import annotations

from engine.effects.availability import effect_params, effect_type
from engine.effects.modifier_manager import CAN_RETREAT
from engine.effects.runtime_effects import (
    strict_ability_runtime_effects as ability_runtime_effects,
    strict_trainer_runtime_effects as trainer_runtime_effects,
)
from engine.enums import EventType


def effective_retreat_cost(state, player) -> int:
    """Calculate active Pokemon retreat cost through CAN_RETREAT modifiers."""
    active = player.active
    if active is None:
        return 0

    retreat_cost = int(active.card.retreat_cost or 0)
    for modifier in _builtin_can_retreat_modifiers(state, player, active, retreat_cost):
        retreat_cost = _apply_retreat_modifier(retreat_cost, modifier)

    for modifier in _registered_can_retreat_modifiers(state, player, active, retreat_cost):
        retreat_cost = _apply_retreat_modifier(retreat_cost, modifier)

    return max(0, retreat_cost)


def _builtin_can_retreat_modifiers(state, player, active, retreat_cost: int) -> list[dict]:
    modifiers: list[dict] = []
    for ability in active.card.abilities or []:
        for effect in ability_runtime_effects(ability):
            if effect_type(effect) != "conditional_zero_retreat":
                continue
            energy_type = str(effect_params(effect).get("energy_type", "") or "")
            if _has_required_energy(active, energy_type):
                modifiers.append({
                    "set_cost": 0,
                    "source": "conditional_zero_retreat",
                })

    if state.stadium_card and active.card.is_basic_pokemon:
        for effect in trainer_runtime_effects(state.stadium_card):
            params = effect_params(effect)
            if (
                effect_type(effect) == "stadium"
                and params.get("effect") == "reduce_retreat_cost_basics"
            ):
                modifiers.append({
                    "delta": -1,
                    "source": getattr(state.stadium_card, "api_id", "stadium"),
                })
                break
    return modifiers


def _registered_can_retreat_modifiers(state, player, active, retreat_cost: int) -> list:
    payload = {
        "state": state,
        "player": player,
        "pokemon": active,
        "retreat_cost": retreat_cost,
    }
    manager = getattr(state, "modifier_manager", None)
    if manager is not None:
        return manager.emit(CAN_RETREAT, **payload)
    return state.event_bus.emit(EventType.CAN_RETREAT, **payload)


def _apply_retreat_modifier(retreat_cost: int, modifier) -> int:
    if not isinstance(modifier, dict):
        return retreat_cost
    if "set_cost" in modifier:
        return max(0, int(modifier.get("set_cost", retreat_cost) or 0))
    if "delta" in modifier:
        return max(0, retreat_cost + int(modifier.get("delta", 0) or 0))
    return retreat_cost


def _has_required_energy(pokemon, required_type: str) -> bool:
    required = required_type.lower()
    if not required:
        return True
    return any(
        any(str(provided).lower() == required for provided in card.provides_energy)
        for card in pokemon.energy_cards
    )

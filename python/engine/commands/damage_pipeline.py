"""Event-driven damage pipeline.

Replaces the hardcoded modifier chain in action_resolver._declare_attack.
Damage calculation flows through event emissions, allowing modifiers
(abilities, tools, special energy) to hook in via the EventBus.
"""
from __future__ import annotations
from typing import TYPE_CHECKING

from engine.enums import EventType

if TYPE_CHECKING:
    from engine.game_state import GameState
    from engine.player_state import PlayerState, PokemonInPlay


def resolve_damage(
    state: GameState,
    attacker: PokemonInPlay,
    defender: PokemonInPlay,
    base_damage: int,
    attacker_type: str,
    ignore_weakness: bool = False,
    ignore_resistance: bool = False,
    ignore_defender_damage_effects: bool = False,
    trigger_commands: list | None = None,
) -> tuple[int, list[str]]:
    """Run the official phased damage calculation."""
    logs: list[str] = []
    current = max(0, int(base_damage or 0))

    # Gather all hooks once, then apply their deltas in the phase declared by
    # the hook. This keeps defender reductions after Weakness/Resistance.
    mod_results = state.event_bus.emit(
        EventType.DAMAGE_ABOUT_TO_BE_DEALT,
        base_damage=current,
        attacker=attacker,
        defender=defender,
        state=state,
        ignore_defender_damage_effects=ignore_defender_damage_effects,
    )
    attacker_mods = [
        mod for mod in mod_results
        if isinstance(mod, dict) and str(mod.get("stage", "attacker")) != "defender"
    ]
    defender_mods = [
        mod for mod in mod_results
        if isinstance(mod, dict) and str(mod.get("stage", "attacker")) == "defender"
    ]

    outgoing_reduction = int(
        getattr(attacker, "outgoing_damage_reduction_next_turn", 0) or 0
    )
    if outgoing_reduction > 0:
        attacker_mods.append({"delta": -outgoing_reduction, "source": "恫吓"})
        attacker.outgoing_damage_reduction_next_turn = 0

    current = _apply_modifiers(current, attacker_mods, logs)

    if (getattr(state, "apply_type_matchups", False)
            and defender and defender.card):
        if not ignore_weakness:
            for weakness in defender.card.weaknesses or []:
                if weakness.energy_type == attacker_type:
                    if weakness.value in ("×2", "x2"):
                        current *= 2
                    break
            current = max(0, current)
        if not ignore_resistance:
            for resistance in defender.card.resistances or []:
                if resistance.energy_type == attacker_type:
                    try:
                        current -= abs(int(str(resistance.value).replace("-", "")))
                    except ValueError:
                        pass
                    break
            current = max(0, current)

    if not ignore_defender_damage_effects:
        current = _apply_modifiers(current, defender_mods, logs)
        if getattr(defender, "damage_prevented_next_turn", False):
            current = 0
            logs.append(f"{defender.card.name}免疫了所有伤害！")

    current = max(0, current)

    # Reactions are not defensive damage modifiers. Attacks that ignore
    # effects on the Defending Pokemon still allow Lucky Energy and similar
    # after-damage triggers to observe damage that actually landed.
    react_results = []
    if current > 0:
        react_results = state.event_bus.emit(
            EventType.DAMAGE_DEALT,
            final_damage=current,
            attacker=attacker,
            defender=defender,
            state=state,
            ignore_defender_damage_effects=ignore_defender_damage_effects,
        )
    for react in react_results:
        if isinstance(react, dict):
            msg = react.get("log", "")
            if msg:
                logs.append(msg)
    from engine.commands.trigger_commands import (
        command_specs_from_trigger_results,
        execute_trigger_commands,
    )

    commands = command_specs_from_trigger_results(react_results)
    if trigger_commands is not None:
        trigger_commands.extend(commands)
    elif commands:
        command_result = execute_trigger_commands(state, commands)
        if command_result.log_message:
            logs.append(command_result.log_message)
        if not command_result.success:
            raise ValueError(
                command_result.log_message
                or "Damage trigger settlement failed"
            )

    return current, logs


def _apply_modifiers(current: int, modifiers: list[dict], logs: list[str]) -> int:
    for mod in modifiers:
        delta = int(mod.get("delta", 0) or 0)
        source = str(mod.get("source", "") or "")
        if delta:
            current += delta
            logs.append(f"{source}效果：伤害{delta:+d}。")
    return max(0, current)

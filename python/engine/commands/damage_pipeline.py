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
    piercing: bool = False,
    ignore_defender_effects: bool = False,
) -> tuple[int, list[str]]:
    """Run the full damage pipeline and return (final_damage, log_messages).

    Pipeline:
    1. Apply weakness/resistance (unless piercing)
    2. Emit DAMAGE_ABOUT_TO_BE_DEALT — modifiers add/subtract afterward
    3. Emit DAMAGE_DEALT — reactive effects (draw, thorns, etc.)
    """
    logs: list[str] = []
    current = base_damage

    # Step 1: Weakness & resistance (unless piercing or disabled by match rules)
    if (not piercing and getattr(state, "apply_type_matchups", False)
            and defender and defender.card):
        for weakness in defender.card.weaknesses or []:
            if weakness.energy_type == attacker_type:
                if weakness.value in ("×2", "x2"):
                    current *= 2
                break
        for resistance in defender.card.resistances or []:
            if resistance.energy_type == attacker_type:
                try:
                    current -= abs(int(str(resistance.value).replace("-", "")))
                except ValueError:
                    pass
                break

    # Step 2: Modifier hooks
    mod_results = state.event_bus.emit(
        EventType.DAMAGE_ABOUT_TO_BE_DEALT,
        base_damage=current,
        attacker=attacker,
        defender=defender,
        state=state,
        ignore_defender_effects=ignore_defender_effects,
    )
    for mod in mod_results:
        if isinstance(mod, dict):
            delta = mod.get("delta", 0)
            source = mod.get("source", "")
            if delta != 0:
                current += delta
                logs.append(f"{source}效果：伤害{delta:+d}。")

    outgoing_reduction = int(
        getattr(attacker, "outgoing_damage_reduction_next_turn", 0) or 0
    )
    if outgoing_reduction > 0:
        current -= outgoing_reduction
        attacker.outgoing_damage_reduction_next_turn = 0
        logs.append(f"恫吓效果：伤害-{outgoing_reduction}。")

    current = max(0, current)

    # Step 3: Reactive hooks. "Took damage" effects only fire when damage
    # actually lands after all modifiers.
    react_results = []
    if current > 0:
        react_results = state.event_bus.emit(
            EventType.DAMAGE_DEALT,
            final_damage=current,
            attacker=attacker,
            defender=defender,
            state=state,
            ignore_defender_effects=ignore_defender_effects,
        )
    for react in react_results:
        if isinstance(react, dict):
            msg = react.get("log", "")
            if msg:
                logs.append(msg)

    return current, logs

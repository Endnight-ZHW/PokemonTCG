"""Register/unregister modifier event listeners when Pokemon enter/leave play.

Replaces the hardcoded api_id checks in action_resolver.py and
modifier_registry.py with dynamic event listener registration.
"""
from __future__ import annotations
from typing import TYPE_CHECKING

from engine.enums import EventType

if TYPE_CHECKING:
    from engine.player_state import PokemonInPlay


def register_pokemon_modifiers(pokemon: PokemonInPlay, player_idx: int,
                                slot: str = "active", event_bus=None):
    """Register all modifier listeners for a Pokemon entering play.

    Called when a Pokemon is placed (active or bench), evolves, or
    when equipment (tools/energy) is attached.
    """
    source_prefix = f"pokemon:{pokemon.card.api_id}:{slot}"

    # Register ability modifiers
    if pokemon.card.abilities:
        for ability in pokemon.card.abilities:
            _register_ability_modifier(ability, pokemon, player_idx, source_prefix, event_bus)

    # Register special energy modifiers
    for sc in pokemon.energy_cards:
        if sc.is_special_energy:
            _register_special_energy_modifier(sc, player_idx, source_prefix, event_bus)

    # Register tool modifiers
    if pokemon.attached_tool:
        _register_tool_modifier(pokemon.attached_tool, pokemon, player_idx, source_prefix, event_bus)


def unregister_pokemon_modifiers(card_api_id: str, slot: str = "active",
                                  event_bus=None):
    """Remove all modifier listeners for a Pokemon leaving play."""
    if event_bus is None:
        return
    source_prefix = f"pokemon:{card_api_id}:{slot}"
    event_bus.unregister_all_for_source(source_prefix)

    # Also unregister sub-sources (ability, energy, tool)
    for suffix in ["ability", "energy", "tool"]:
        event_bus.unregister_all_for_source(f"{source_prefix}:{suffix}")


# ═══════════════════════════════════════════════════════
# Internal: register specific modifier types
# ═══════════════════════════════════════════════════════

def _register_ability_modifier(ability, pokemon, player_idx: int,
                                source_prefix: str, event_bus):
    """Register an ability as a damage modifier if applicable."""
    ability_name = ability.name
    source = f"{source_prefix}:ability:{ability_name}"

    for effect in getattr(ability, "effects", []) or []:
        effect_type = getattr(effect, "effect_type", "")
        params = getattr(effect, "params", {}) or {}

        if effect_type == "aura_damage_reduction":
            reduction = int(params.get("reduction", 0) or 0)
            requires_attached_energy = bool(params.get("requires_attached_energy", False))

            def reduction_mod(data: dict, *, reduction=reduction,
                              requires_attached_energy=requires_attached_energy) -> dict | None:
                defender = data.get("defender")
                if defender is not pokemon:
                    return None
                if data.get("ignore_defender_effects"):
                    return None
                if requires_attached_energy and not pokemon.energy_cards:
                    return None
                return {"delta": -reduction, "source": ability_name}

            event_bus.register(EventType.DAMAGE_ABOUT_TO_BE_DEALT, reduction_mod,
                               source=source, owner_player=player_idx, priority=50)

        if effect_type == "aura_damage_boost":
            amount = int(params.get("amount", 0) or 0)
            attacker_subtype = str(params.get("attacker_subtype", "") or "")
            defender_type = str(params.get("defender_type", "") or "")

            def boost_mod(data: dict, *, amount=amount,
                          attacker_subtype=attacker_subtype,
                          defender_type=defender_type) -> dict | None:
                state = data.get("state")
                attacker = data.get("attacker")
                defender = data.get("defender")
                if not (state and attacker and defender):
                    return None
                owner = state.get_player(player_idx)
                if not any(poke is pokemon for _, poke in owner.get_all_pokemon() if poke):
                    return None
                if not any(poke is attacker for _, poke in owner.get_all_pokemon() if poke):
                    return None
                if attacker_subtype and attacker_subtype not in getattr(attacker.card, "subtypes", []):
                    return None
                if defender_type and defender_type not in getattr(defender.card, "energy_types", []):
                    return None
                return {"delta": amount, "source": ability_name}

            event_bus.register(EventType.DAMAGE_ABOUT_TO_BE_DEALT, boost_mod,
                               source=source, owner_player=player_idx, priority=45)

    # 团结一致 (Maushold ex): reactive thorns on damage
    if ability_name == "团结一致":
        def maus_reactive(data: dict) -> dict | None:
            defender = data.get("defender")
            attacker = data.get("attacker")
            state = data.get("state")
            if data.get("ignore_defender_effects") and defender is pokemon:
                return None
            if defender and attacker and state:
                if defender is pokemon:
                    # Count 一对鼠/一家鼠 on our field
                    maus_count = 0
                    owner = state.get_player(player_idx)
                    for _, poke in owner.get_all_pokemon():
                        if poke and poke.card and poke.card.name in ("一对鼠", "一家鼠ex", "一家鼠"):
                            maus_count += 1
                    if maus_count > 0:
                        thorn_dmg = maus_count * 3
                        attacker.damage_counters += thorn_dmg
                        return {"delta": 0, "source": "团结一致",
                                "log": f"一家鼠ex的团结一致：一对鼠/一家鼠共{maus_count}只，放置了{thorn_dmg}个伤害指示物！"}
            return None
        event_bus.register(EventType.DAMAGE_DEALT, maus_reactive,
                          source=source, owner_player=player_idx, priority=10)


def _register_special_energy_modifier(sc, player_idx: int, source_prefix: str,
                                       event_bus):
    """Register special energy card effects as event listeners."""
    source = f"{source_prefix}:energy:{sc.api_id}"

    # 双重涡轮能量 (Double Turbo Energy): -20 damage
    if sc.api_id == "svi-dtur":
        def dtur_mod(data: dict) -> dict | None:
            attacker = data.get("attacker")
            if attacker is not None and sc in getattr(attacker, "energy_cards", []):
                return {"delta": -20, "source": "双重涡轮能量"}
            return None
        event_bus.register(EventType.DAMAGE_ABOUT_TO_BE_DEALT, dtur_mod,
                          source=source, owner_player=player_idx, priority=30)

    # 奇迹能量 (Miracle Energy): draw 1 on taking damage
    if sc.api_id == "svi-mirc":
        def mirc_react(data: dict) -> dict | None:
            defender = data.get("defender")
            state = data.get("state")
            if data.get("ignore_defender_effects") and defender is not None and sc in getattr(defender, "energy_cards", []):
                return None
            if defender and state:
                # Check if this energy is attached to the defender
                for scc in defender.energy_cards:
                    if scc is sc:
                        owner = state.get_player(player_idx)
                        drawn = owner.draw_cards(1)
                        if drawn:
                            return {"delta": 0, "source": "奇迹能量",
                                    "log": f"奇迹能量效果：{owner.name}抽取了1张卡。"}
            return None
        event_bus.register(EventType.DAMAGE_DEALT, mirc_react,
                          source=source, owner_player=player_idx, priority=20)

    # 喷射能量 (Jet Energy): switch on attach to bench
    # Handled separately in energy attach flow — event-based registration
    # not needed since it's an on-attach trigger, not a damage modifier.


def _register_tool_modifier(tool_card, pokemon, player_idx: int,
                             source_prefix: str, event_bus):
    """Register tool card effects as event listeners."""
    if not hasattr(tool_card, 'trainer_effects'):
        return

    source = f"{source_prefix}:tool:{tool_card.api_id}"

    for eff in tool_card.trainer_effects:
        effect_name = eff.params.get("effect", "")

        # 反抗头带 / 不服输头带: +30 when behind on prizes
        if effect_name == "damage_boost_when_behind":
            def defiance_mod(data: dict) -> dict | None:
                state = data.get("state")
                attacker = data.get("attacker")
                if state and attacker is pokemon:
                    # owner is the attacker (attached tool affects outgoing damage)
                    player = state.get_player(player_idx)
                    opponent = state.get_player(1 - player_idx)
                    if len(player.prizes) > len(opponent.prizes):
                        return {"delta": 30, "source": "反抗头带"}
                return None
            event_bus.register(EventType.DAMAGE_ABOUT_TO_BE_DEALT, defiance_mod,
                              source=source, owner_player=player_idx, priority=40)

        # 活力头带: +10 unconditional
        if effect_name == "damage_boost_10":
            def vital_mod(data: dict) -> dict | None:
                if data.get("attacker") is pokemon:
                    return {"delta": 10, "source": "活力头带"}
                return None
            event_bus.register(EventType.DAMAGE_ABOUT_TO_BE_DEALT, vital_mod,
                              source=source, owner_player=player_idx, priority=35)

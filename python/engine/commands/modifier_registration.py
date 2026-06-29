"""Register/unregister MBF modifier hooks when Pokemon enter/leave play."""
from __future__ import annotations
from typing import TYPE_CHECKING

from engine.effects.availability import effect_params, effect_type
from engine.effects.modifier_manager import (
    AFTER_DAMAGE,
    CAN_RETREAT,
    MODIFY_DAMAGE,
    POKEMON_KO,
    ModifierManager,
)
from engine.effects.runtime_effects import (
    strict_ability_runtime_effects as ability_runtime_effects,
    strict_trainer_runtime_effects as trainer_runtime_effects,
)

if TYPE_CHECKING:
    from engine.player_state import PokemonInPlay


def _register_mbf_hook(
    event_bus,
    hook: str,
    callback,
    *,
    source: str,
    owner_player: int,
    priority: int = 0,
) -> None:
    """Register event-backed hooks through the MBF facade."""
    ModifierManager(event_bus).register(
        hook,
        callback,
        source=source,
        owner_player=owner_player,
        priority=priority,
    )


def register_pokemon_modifiers(pokemon: PokemonInPlay, player_idx: int,
                                slot: str = "active", event_bus=None):
    """Register all modifier listeners for a Pokemon entering play.

    Called when a Pokemon is placed (active or bench), evolves, or
    when equipment (tools/energy) is attached.
    """
    if event_bus is None:
        return
    source_prefix = f"pokemon:{player_idx}:{pokemon.card.api_id}:{slot}"
    event_bus.unregister_all_with_prefix(source_prefix)

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
                                  event_bus=None, player_idx: int | None = None):
    """Remove all modifier listeners for a Pokemon leaving play."""
    if event_bus is None:
        return
    if player_idx in (0, 1):
        event_bus.unregister_all_with_prefix(f"pokemon:{player_idx}:{card_api_id}:{slot}")
        return
    event_bus.unregister_all_with_prefix(f"pokemon:0:{card_api_id}:{slot}")
    event_bus.unregister_all_with_prefix(f"pokemon:1:{card_api_id}:{slot}")
    event_bus.unregister_all_with_prefix(f"pokemon:{card_api_id}:{slot}")


# ═══════════════════════════════════════════════════════
# Internal: register specific modifier types
# ═══════════════════════════════════════════════════════

def _register_ability_modifier(ability, pokemon, player_idx: int,
                                source_prefix: str, event_bus):
    """Register an ability as a damage modifier if applicable."""
    ability_name = ability.name
    source = f"{source_prefix}:ability:{ability_name}"

    for effect in ability_runtime_effects(ability):
        effect_kind = effect_type(effect)
        params = effect_params(effect)
        register_effect_modifier(
            effect_kind,
            params,
            pokemon,
            player_idx,
            source=source,
            event_bus=event_bus,
            source_name=ability_name,
        )


def register_effect_modifier(
    effect_type: str,
    params: dict,
    pokemon: PokemonInPlay,
    player_idx: int,
    *,
    source: str,
    event_bus,
    source_name: str = "",
) -> bool:
    """Register one data-defined modifier/trigger for a Pokemon."""
    if event_bus is None or pokemon is None:
        return False
    params = dict(params or {})
    source_name = source_name or getattr(getattr(pokemon, "card", None), "name", "") or effect_type
    event_bus.unregister_all_for_source(source)

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
            return {"delta": -reduction, "source": source_name}

        _register_mbf_hook(
            event_bus,
            MODIFY_DAMAGE,
            reduction_mod,
            source=source,
            owner_player=player_idx,
            priority=50,
        )
        return True

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
            return {"delta": amount, "source": source_name}

        _register_mbf_hook(
            event_bus,
            MODIFY_DAMAGE,
            boost_mod,
            source=source,
            owner_player=player_idx,
            priority=45,
        )
        return True

    if effect_type == "reactive_thorns":
        filter_names = set(params.get("filter_names", []) or [])
        per_pokemon = int(params.get("per_pokemon", 0) or 0)

        def reactive_thorns(data: dict, *, filter_names=filter_names,
                            per_pokemon=per_pokemon) -> dict | None:
            defender = data.get("defender")
            attacker = data.get("attacker")
            state = data.get("state")
            if data.get("ignore_defender_effects") and defender is pokemon:
                return None
            if not (defender is pokemon and attacker is not None and state is not None):
                return None
            owner = state.get_player(player_idx)
            matching_count = sum(
                1
                for _slot, poke in owner.get_all_pokemon()
                if poke and poke.card and poke.card.name in filter_names
            )
            thorn_counters = matching_count * per_pokemon
            if thorn_counters <= 0:
                return None
            from engine.commands.trigger_commands import (
                pokemon_ref_for_state,
                trigger_place_damage_counters_spec,
            )

            attacker_ref = pokemon_ref_for_state(state, attacker)
            if attacker_ref is None:
                return None

            return {
                "source": source_name,
                "command_specs": [
                    trigger_place_damage_counters_spec(
                        attacker_ref[0],
                        attacker_ref[1],
                        thorn_counters,
                        source_name,
                    )
                ],
            }

        _register_mbf_hook(
            event_bus,
            AFTER_DAMAGE,
            reactive_thorns,
            source=source,
            owner_player=player_idx,
            priority=10,
        )
        return True

    if effect_type == "conditional_zero_retreat":
        energy_type = str(params.get("energy_type", "") or "").lower()

        def zero_retreat(data: dict, *, energy_type=energy_type) -> dict | None:
            active = data.get("pokemon")
            if active is not pokemon:
                return None
            if any(
                any(str(provided).lower() == energy_type for provided in card.provides_energy)
                for card in pokemon.energy_cards
            ):
                return {"set_cost": 0, "source": source_name}
            return None

        _register_mbf_hook(
            event_bus,
            CAN_RETREAT,
            zero_retreat,
            source=source,
            owner_player=player_idx,
            priority=50,
        )
        return True

    if effect_type == "conditional_hp_boost":
        if ":ability:" in source:
            return False
        modifier = {
            "source": source,
            "modifier_kind": "conditional_hp_boost",
            "energy_type": str(params.get("energy_type", "") or ""),
            "threshold": int(params.get("threshold", 0) or 0),
            "amount": int(params.get("amount", 0) or 0),
        }
        pokemon.max_hp_modifiers = [
            existing
            for existing in getattr(pokemon, "max_hp_modifiers", [])
            if existing.get("source") != source
        ]
        pokemon.max_hp_modifiers.append(modifier)
        return True

    return False


def _register_special_energy_modifier(sc, player_idx: int, source_prefix: str,
                                       event_bus):
    """Register special energy card effects as event listeners."""
    source = f"{source_prefix}:energy:{sc.api_id}"

    for effect in getattr(sc, "energy_effects", []) or []:
        kind = effect.get("kind")
        hook = effect.get("hook")
        priority = int(effect.get("priority", 20) or 20)

        if kind == "modifier" and hook == MODIFY_DAMAGE:
            effect_data = effect.get("effect") or {}
            delta = int(effect_data.get("delta", 0) or 0)
            scope = str(effect.get("scope", "") or "")

            def energy_damage_mod(
                data: dict,
                *,
                delta=delta,
                scope=scope,
            ) -> dict | None:
                if scope == "attached_attacker":
                    holder = data.get("attacker")
                elif scope == "attached_defender":
                    holder = data.get("defender")
                    if data.get("ignore_defender_effects"):
                        return None
                else:
                    holder = data.get("attacker")
                if holder is not None and sc in getattr(holder, "energy_cards", []):
                    return {"delta": delta, "source": sc.name}
                return None

            _register_mbf_hook(
                event_bus,
                MODIFY_DAMAGE,
                energy_damage_mod,
                source=source,
                owner_player=player_idx,
                priority=priority,
            )

        if kind == "trigger" and hook == AFTER_DAMAGE:
            effect_data = effect.get("effect") or {}
            condition = effect.get("condition") or {}
            op = effect_data.get("op")
            amount = int(effect_data.get("amount", 0) or 0)
            min_damage = int(condition.get("min_damage", 1) or 1)
            scope = str(condition.get("scope", "") or "")

            if op != "draw_cards" or amount <= 0:
                continue

            def energy_after_damage(
                data: dict,
                *,
                amount=amount,
                min_damage=min_damage,
                scope=scope,
            ) -> dict | None:
                if int(data.get("final_damage", 0) or 0) < min_damage:
                    return None
                if scope == "attached_defender":
                    holder = data.get("defender")
                    if data.get("ignore_defender_effects"):
                        return None
                elif scope == "attached_attacker":
                    holder = data.get("attacker")
                else:
                    holder = data.get("defender")
                state = data.get("state")
                if not holder or not state or sc not in getattr(holder, "energy_cards", []):
                    return None
                from engine.commands.trigger_commands import trigger_draw_cards_spec

                return {
                    "source": sc.name,
                    "command_specs": [trigger_draw_cards_spec(player_idx, amount, sc.name)],
                }

            _register_mbf_hook(
                event_bus,
                AFTER_DAMAGE,
                energy_after_damage,
                source=source,
                owner_player=player_idx,
                priority=priority,
            )

    # Backward-compatible fallbacks for cards created outside CardRegistry.
    if sc.api_id == "svi-dtur" and not getattr(sc, "energy_effects", None):
        def dtur_mod(data: dict) -> dict | None:
            attacker = data.get("attacker")
            if attacker is not None and sc in getattr(attacker, "energy_cards", []):
                return {"delta": -20, "source": "双重涡轮能量"}
            return None
        _register_mbf_hook(
            event_bus,
            MODIFY_DAMAGE,
            dtur_mod,
            source=source,
            owner_player=player_idx,
            priority=30,
        )

    if sc.api_id == "svi-mirc" and not getattr(sc, "energy_effects", None):
        def mirc_react(data: dict) -> dict | None:
            defender = data.get("defender")
            state = data.get("state")
            if data.get("ignore_defender_effects") and defender is not None and sc in getattr(defender, "energy_cards", []):
                return None
            if defender and state:
                # Check if this energy is attached to the defender
                for scc in defender.energy_cards:
                    if scc is sc:
                        from engine.commands.trigger_commands import trigger_draw_cards_spec

                        return {
                            "source": "奇迹能量",
                            "command_specs": [trigger_draw_cards_spec(player_idx, 1, "奇迹能量")],
                        }
            return None
        _register_mbf_hook(
            event_bus,
            AFTER_DAMAGE,
            mirc_react,
            source=source,
            owner_player=player_idx,
            priority=20,
        )

    # 喷射能量 (Jet Energy): switch on attach to bench
    # Handled separately in energy attach flow — event-based registration
    # not needed since it's an on-attach trigger, not a damage modifier.


def _register_tool_modifier(tool_card, pokemon, player_idx: int,
                             source_prefix: str, event_bus):
    """Register tool card effects as event listeners."""
    effects = trainer_runtime_effects(tool_card)
    if not effects:
        return

    source = f"{source_prefix}:tool:{tool_card.api_id}"

    for eff in effects:
        params = effect_params(eff)
        effect_name = params.get("effect", "") or effect_type(eff)
        register_tool_effect_modifier(
            effect_name,
            params,
            pokemon,
            player_idx,
            source=f"{source}:{effect_name}",
            event_bus=event_bus,
            source_name=tool_card.name,
        )


def register_tool_effect_modifier(
    effect_name: str,
    params: dict,
    pokemon: PokemonInPlay,
    player_idx: int,
    *,
    source: str,
    event_bus,
    source_name: str = "",
) -> bool:
    """Register one tool-style modifier for a Pokemon."""
    if event_bus is None or pokemon is None:
        return False
    params = dict(params or {})
    source_name = source_name or effect_name or getattr(pokemon.card, "name", "")
    event_bus.unregister_all_for_source(source)

    # 反抗头带 / 不服输头带: +30 when behind on prizes
    if effect_name == "damage_boost_when_behind":
        def defiance_mod(data: dict) -> dict | None:
            state = data.get("state")
            attacker = data.get("attacker")
            if state and attacker is pokemon:
                player = state.get_player(player_idx)
                opponent = state.get_player(1 - player_idx)
                if len(player.prizes) > len(opponent.prizes):
                    return {"delta": 30, "source": source_name}
            return None

        _register_mbf_hook(
            event_bus,
            MODIFY_DAMAGE,
            defiance_mod,
            source=source,
            owner_player=player_idx,
            priority=40,
        )
        return True

    # 活力头带: +10 unconditional
    if effect_name == "damage_boost_10":
        def vital_mod(data: dict) -> dict | None:
            if data.get("attacker") is pokemon:
                return {"delta": 10, "source": source_name}
            return None

        _register_mbf_hook(
            event_bus,
            MODIFY_DAMAGE,
            vital_mod,
            source=source,
            owner_player=player_idx,
            priority=35,
        )
        return True

    # 坚硬束带: Stage 1 holder takes -30 attack damage.
    if effect_name == "damage_reduction_stage1":
        amount = int(params.get("amount", 30) or 30)

        def hard_belt_mod(data: dict, *, amount=amount) -> dict | None:
            defender = data.get("defender")
            if defender is not pokemon:
                return None
            if data.get("ignore_defender_effects"):
                return None
            if not getattr(pokemon.card, "is_stage1", False):
                return None
            return {"delta": -amount, "source": source_name}

        _register_mbf_hook(
            event_bus,
            MODIFY_DAMAGE,
            hard_belt_mod,
            source=source,
            owner_player=player_idx,
            priority=42,
        )
        return True

    if effect_name == "tool_exp_share":
        def exp_share(data: dict) -> dict | None:
            if not data.get("from_attack"):
                return None
            if int(data.get("player_idx", -1)) != player_idx:
                return None
            knocked_out = data.get("knocked_out")
            if knocked_out is None or knocked_out is pokemon:
                return None
            for card in list(getattr(knocked_out, "energy_cards", [])):
                if not getattr(card, "is_basic_energy", False):
                    continue
                state = data.get("state")
                from_player_idx = int(data.get("player_idx", player_idx))
                from_slot = str(data.get("slot", "active") or "active")
                from engine.commands.trigger_commands import (
                    pokemon_ref_for_state,
                    trigger_move_basic_energy_spec,
                )

                source_ref = None
                if state is not None:
                    source = state.get_player(from_player_idx).get_pokemon(from_slot)
                    if source is knocked_out:
                        source_ref = (from_player_idx, from_slot)
                    else:
                        source_ref = pokemon_ref_for_state(state, knocked_out)
                target_ref = pokemon_ref_for_state(state, pokemon)
                if source_ref is None or target_ref is None:
                    return None
                return {
                    "source": source_name,
                    "exclusive_group": "tool_exp_share",
                    "command_specs": [
                        trigger_move_basic_energy_spec(
                            source_ref[0],
                            source_ref[1],
                            target_ref[0],
                            target_ref[1],
                            source_name,
                        )
                    ],
                }
            return None

        _register_mbf_hook(
            event_bus,
            POKEMON_KO,
            exp_share,
            source=source,
            owner_player=player_idx,
            priority=30,
        )
        return True

    return False

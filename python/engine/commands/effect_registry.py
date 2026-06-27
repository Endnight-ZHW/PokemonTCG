"""Register all effect types as command factories.

Import this module to populate the command registry. Each effect_type
maps to a LegacyEffectCommand factory that delegates to the existing
handler functions. As handlers are ported to native ICommand subclasses,
their registrations here are replaced with the native factories.
"""
from engine.commands.registry import register_command
from engine.commands.effects.legacy_adapter import LegacyEffectCommand


def _make_legacy(effect_type: str):
    """Create a factory that builds a LegacyEffectCommand for the given type."""
    def factory(params: dict, **overrides) -> LegacyEffectCommand:
        return LegacyEffectCommand(effect_type=effect_type, params=params)
    return factory


# All currently-used effect types (after Phase 0 cleanup).
# These delegate to the existing handler functions in engine/effects/*.
EFFECT_TYPES = [
    "damage", "damage_counter_self", "damage_per_energy", "damage_per_hand_size",
    "damage_per_self_energy", "damage_per_discard_psychic", "any_pokemon_damage",
    "conditional_damage_bonus", "damage_plus_bench", "mill_and_damage_per_energy",
    "place_counters_and_self_ko", "discard_hand_conditional_bonus",
    "discard_fighting_energy_damage", "coin_flip_triple", "coin_flip_double_ko",
    "damage_per_self_damage", "damage_self_penalty", "conditional_damage_heal",
    "damage_per_evolved", "damage_per_self_energy_type", "damage_and_self_heal",
    "attack_damage_formula", "bench_damage",

    "status", "conditional_status", "attack_fail", "dazzling_beam",
    "attack_lock_basic", "self_attack_lock", "prevent_all",

    "draw", "draw_until", "discard_draw", "shuffle_draw", "discard_then_draw",
    "hand_to_bottom_draw", "judge", "houb", "shuffle_from_discard", "draw_until_more",

    "energy_attach", "energy_discard", "energy_relocate", "attach_from_discard",

    "search", "look_top_deck", "look_top_attach_energy", "search_any_and_switch", "conditional_search_extra",

    "heal", "potion_heal", "switch_self", "switch_opponent", "coin_flip",
    "conditional", "evolve_skip_stage", "discard", "return_to_hand",
    "piercing_marker", "clara", "arven", "zinnia_resolve", "trekking_shoes",
    "heal_all", "coin_flip_until_tails", "coin_flip_energy_discard",
    "ability_discard_revive", "tool_exp_share", "draw_and_attach_energy",

    # Passive / no-op effects
    "tool", "aura_damage_reduction", "aura_damage_boost",
    "conditional_hp_boost", "conditional_zero_retreat", "reactive_thorns",
]


def register_all():
    """Register all effect types. Call once at startup."""
    for etype in EFFECT_TYPES:
        register_command(etype, _make_legacy(etype))

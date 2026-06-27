"""Effect system - dispatches effect execution."""
from engine.game_state import GameState, ActionResult, ActionRequest
from data.card_models import EffectDef

from engine.effects.damage_effects import (
    _handle_damage,
    _handle_damage_counter_self,
    _handle_damage_per_energy,
    _handle_damage_per_hand_size,
    _handle_damage_per_self_energy,
    _handle_damage_per_discard_psychic,
    _handle_any_pokemon_damage,
    _handle_conditional_damage_bonus,
    _handle_damage_plus_bench,
    _handle_mill_and_damage_per_energy,
    _handle_place_counters_and_self_ko,
    _handle_discard_hand_conditional_bonus,
    _handle_discard_fighting_energy_damage,
    _handle_coin_flip_triple,
    _handle_coin_flip_double_ko,
    _handle_damage_per_self_damage,
    _handle_damage_self_penalty,
    _handle_conditional_damage_heal,
    _handle_damage_per_evolved,
    _handle_damage_per_self_energy_type,
    _handle_damage_and_self_heal,
    _handle_attack_damage_formula,
    _handle_bench_damage,
)
from engine.effects.status_effects import (
    _handle_status,
    _handle_conditional_status,
    _handle_attack_fail,
    _handle_dazzling_beam,
    _handle_attack_lock_basic,
    _handle_apply_outgoing_damage_reduction,
    _handle_self_attack_lock,
    _handle_prevent_all,
    _handle_prevent_damage,
    _handle_prevent_effects,
)
from engine.effects.draw_effects import (
    _handle_draw,
    _handle_draw_until,
    _handle_discard_draw,
    _handle_shuffle_draw,
    _handle_discard_then_draw,
    _handle_hand_to_bottom_draw,
    _handle_judge,
    _handle_houb,
    _handle_shuffle_from_discard,
    _handle_draw_until_more,
)
from engine.effects.energy_effects import (
    _handle_energy_attach,
    _handle_energy_discard,
    _handle_energy_relocate,
    _handle_attach_from_discard,
)
from engine.effects.search_effects import (
    _handle_search,
    _handle_look_top_deck,
    _handle_look_top_attach_energy,
    _handle_search_any_and_switch,
    _handle_conditional_search_extra,
)
from engine.effects.special_effects import (
    _handle_heal,
    _handle_potion_heal,
    _handle_switch_self,
    _handle_switch_opponent,
    _handle_coin_flip,
    _handle_conditional,
    _handle_evolve_skip,
    _handle_discard,
    _handle_return_to_hand,
    _handle_piercing_marker,
    _handle_clara,
    _handle_arven,
    _handle_zinnia_resolve,
    _handle_trekking_shoes,
    _handle_heal_all,
    _handle_coin_flip_until_tails,
    _handle_coin_flip_energy_discard,
    _handle_ability_discard_revive,
    _handle_tool_exp_share,
    _handle_draw_and_attach_energy,
)


def execute_effect(state: GameState, effect_def: dict | EffectDef,
                   player_idx: int, source_slot: str) -> ActionResult:
    """Execute a single effect by type. Returns ActionResult."""
    # Accept both dict and EffectDef
    if hasattr(effect_def, 'effect_type'):
        effect_type = effect_def.effect_type
        params = effect_def.params
    elif isinstance(effect_def, dict):
        effect_type = effect_def.get("effect_type", "")
        params = effect_def.get("params", {})
    else:
        return ActionResult(False, f"Invalid effect: {effect_def}")

    player = state.get_player(player_idx)
    opponent = state.get_opponent()

    if effect_type == "damage":
        return _handle_damage(state, player, opponent, params, source_slot)
    elif effect_type == "status":
        return _handle_status(state, player, opponent, params)
    elif effect_type == "draw":
        return _handle_draw(state, player, params)
    elif effect_type == "heal":
        return _handle_heal(state, player, params)
    elif effect_type == "switch_self":
        return _handle_switch_self(state, player, params, player_idx)
    elif effect_type == "switch_opponent":
        opponent_idx = 1 - player_idx
        return _handle_switch_opponent(state, opponent, params, opponent_idx, player_idx)
    elif effect_type == "energy_attach":
        return _handle_energy_attach(state, player, player_idx, params, source_slot)
    elif effect_type == "energy_discard":
        return _handle_energy_discard(state, player, opponent, params, source_slot)
    elif effect_type == "coin_flip":
        return _handle_coin_flip(state, params, player_idx, source_slot)
    elif effect_type == "discard_draw":
        return _handle_discard_draw(state, player, params)
    elif effect_type == "draw_until":
        return _handle_draw_until(state, player, params)
    elif effect_type == "damage_counter_self":
        return _handle_damage_counter_self(state, player, params, source_slot)
    elif effect_type == "attack_damage_formula":
        return _handle_attack_damage_formula(state, player, opponent, params, source_slot)
    elif effect_type == "conditional":
        return _handle_conditional(state, params, player_idx, source_slot)
    elif effect_type == "search":
        return _handle_search(state, player_idx, params)
    elif effect_type == "shuffle_from_discard":
        return _handle_shuffle_from_discard(state, player, player_idx, params)
    elif effect_type == "discard":
        return _handle_discard(state, player, params)
    elif effect_type == "evolve_skip_stage":
        return _handle_evolve_skip(state, player, params)
    elif effect_type == "look_top_deck":
        return _handle_look_top_deck(state, player_idx, params)
    elif effect_type == "look_top_attach_energy":
        return _handle_look_top_attach_energy(state, player_idx, params)
    elif effect_type == "damage_per_energy":
        return _handle_damage_per_energy(state, player, opponent, params)
    elif effect_type == "attach_from_discard":
        return _handle_attach_from_discard(state, player, player_idx, params, source_slot)
    elif effect_type == "judge":
        return _handle_judge(state, player_idx, params)
    elif effect_type == "tool":
        return ActionResult(True, "道具效果已注册。")
    elif effect_type == "any_pokemon_damage":
        return _handle_any_pokemon_damage(state, player, opponent, params)
    elif effect_type == "bench_damage":
        return _handle_bench_damage(state, player, opponent, params)
    elif effect_type == "conditional_damage_bonus":
        return _handle_conditional_damage_bonus(state, player, opponent, params)
    elif effect_type == "mill_and_damage_per_energy":
        return _handle_mill_and_damage_per_energy(state, player, opponent, params)
    elif effect_type == "damage_per_self_energy":
        return _handle_damage_per_self_energy(state, player, opponent, params)
    elif effect_type == "prevent_damage":
        return _handle_prevent_damage(state, player, params, source_slot)
    elif effect_type == "prevent_all":
        return _handle_prevent_all(state, player, params, source_slot)
    elif effect_type == "prevent_effects":
        return _handle_prevent_effects(state, player, params, source_slot)
    elif effect_type in {"aura_damage_reduction", "aura_damage_boost", "conditional_hp_boost", "reactive_thorns"}:
        # Passive aura abilities like 炎帝 压迫感 — handled automatically
        # in action_resolver._declare_attack, no manual execution needed
        return ActionResult(True, "")
    elif effect_type == "damage_plus_bench":
        return _handle_damage_plus_bench(state, player, opponent, params)
    elif effect_type == "attack_lock_basic":
        return _handle_attack_lock_basic(state, opponent, params)
    elif effect_type == "apply_outgoing_damage_reduction":
        return _handle_apply_outgoing_damage_reduction(state, player, opponent, params)
    elif effect_type == "return_to_hand":
        return _handle_return_to_hand(state, player_idx, params, source_slot)
    elif effect_type == "piercing_marker":
        return _handle_piercing_marker(state, params)
    elif effect_type == "place_counters_and_self_ko":
        return _handle_place_counters_and_self_ko(state, player_idx, opponent, params, source_slot)
    elif effect_type == "shuffle_draw":
        return _handle_shuffle_draw(state, player, params)
    elif effect_type == "conditional_status":
        return _handle_conditional_status(state, player, opponent, params)
    elif effect_type == "damage_per_hand_size":
        return _handle_damage_per_hand_size(state, player, opponent, params)
    elif effect_type == "discard_hand_conditional_bonus":
        return _handle_discard_hand_conditional_bonus(state, player, opponent, params, source_slot)
    elif effect_type == "hand_to_bottom_draw":
        return _handle_hand_to_bottom_draw(state, player, params)
    elif effect_type == "energy_relocate":
        return _handle_energy_relocate(state, player, player_idx, params)
    elif effect_type == "coin_flip_triple":
        return _handle_coin_flip_triple(state, player, opponent, params)
    elif effect_type == "discard_then_draw":
        return _handle_discard_then_draw(state, player, player_idx, params)
    elif effect_type == "conditional_zero_retreat":
        return ActionResult(True, "薄雾飘浮: 条件0撤退已注册。")
    elif effect_type == "damage_per_discard_psychic":
        return _handle_damage_per_discard_psychic(state, player, opponent, params)
    elif effect_type == "clara":
        return _handle_clara(state, player_idx, params)
    elif effect_type == "arven":
        return _handle_arven(state, player_idx, params)
    elif effect_type == "attack_fail":
        return _handle_attack_fail(state, params)
    elif effect_type == "dazzling_beam":
        return _handle_dazzling_beam(state, opponent, params)
    elif effect_type == "trekking_shoes":
        return _handle_trekking_shoes(state, player, player_idx, params)
    elif effect_type == "zinnia_resolve":
        return _handle_zinnia_resolve(state, player, opponent, player_idx, params)
    elif effect_type == "coin_flip_double_ko":
        return _handle_coin_flip_double_ko(state, player, opponent, player_idx, source_slot)
    elif effect_type == "discard_fighting_energy_damage":
        return _handle_discard_fighting_energy_damage(state, player, opponent, params)
    elif effect_type == "potion_heal":
        return _handle_potion_heal(state, player, player_idx, params)
    elif effect_type == "houb":
        return _handle_houb(state, player, params)
    elif effect_type == "self_attack_lock":
        return _handle_self_attack_lock(state, player, params, source_slot)
    elif effect_type == "heal_all":
        return _handle_heal_all(state, player, params)
    elif effect_type == "coin_flip_until_tails":
        return _handle_coin_flip_until_tails(state, params, player_idx, source_slot)
    elif effect_type == "coin_flip_energy_discard":
        return _handle_coin_flip_energy_discard(state, params, player_idx, source_slot)
    elif effect_type == "ability_discard_revive":
        return _handle_ability_discard_revive(state, player, params, player_idx)
    elif effect_type == "tool_exp_share":
        return _handle_tool_exp_share(state, player, params, player_idx)
    elif effect_type == "draw_and_attach_energy":
        return _handle_draw_and_attach_energy(state, player, params, player_idx)
    elif effect_type == "damage_per_self_damage":
        return _handle_damage_per_self_damage(state, player, opponent, params)
    elif effect_type == "damage_self_penalty":
        return _handle_damage_self_penalty(state, player, opponent, params)
    elif effect_type == "conditional_damage_heal":
        return _handle_conditional_damage_heal(state, player, opponent, params)
    elif effect_type == "damage_per_evolved":
        return _handle_damage_per_evolved(state, player, opponent, params)
    elif effect_type == "damage_per_self_energy_type":
        return _handle_damage_per_self_energy_type(state, player, opponent, params)
    elif effect_type == "damage_and_self_heal":
        return _handle_damage_and_self_heal(state, player, opponent, params)
    elif effect_type == "search_any_and_switch":
        return _handle_search_any_and_switch(state, player_idx, params)
    elif effect_type == "conditional_search_extra":
        return _handle_conditional_search_extra(state, player_idx, params)
    elif effect_type == "draw_until_more":
        return _handle_draw_until_more(state, player, params)
    else:
        return ActionResult(False, f"未知效果类型: {effect_type}")

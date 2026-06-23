"""Generic damage modifier lookup for special energy, tools, and abilities.

This module provides generic query functions so that action_resolver.py
does not need hardcoded card-api_id checks. All card-specific logic is
derived from structured data in card_data/card_effects.py.
"""


def get_ability_damage_modifier(ability, card) -> int | None:
    """Return a damage delta from a Pokemon ability, or None if no modifier.

    Currently handles:
    - 压迫感 (Entei): -20 damage
    """
    if not hasattr(ability, 'name'):
        return None

    # 炎帝 压迫感: -20 damage from defender's ability
    if ability.name == "压迫感":
        return -20

    return None


def get_special_energy_damage_modifier(sc) -> int | None:
    """Return a damage delta from an attached special energy card, or None.

    Currently handles:
    - Double Turbo Energy (svi-dtur): -20 damage
    """
    # 双重涡轮能量: -20
    if sc.api_id == "svi-dtur":
        return -20

    return None


def get_tool_damage_modifier(tool_card, state, player, opponent) -> int | None:
    """Return a damage delta from an attached tool card, or None.

    Currently handles:
    - 反抗头带/不服输头带: +30 when behind on prizes
    - 活力头带: +10 unconditional
    """
    if not hasattr(tool_card, 'trainer_effects'):
        return None

    for eff in tool_card.trainer_effects:
        effect_name = eff.params.get("effect", "")

        if effect_name == "damage_boost_when_behind":
            my_prizes = len(player.prizes)
            opp_prizes = len(opponent.prizes)
            if my_prizes > opp_prizes:
                return 30
            return None

        if effect_name == "damage_boost_10":
            return 10

    return None


def get_special_energy_attach_effect(card, player, target_slot):
    """Handle special energy on-attach effects. Returns (should_switch, switch_message).

    Currently handles:
    - 喷射能量 (svi-jete): auto-switch when attached to bench
    """
    if card.is_special_energy and card.api_id == "svi-jete" and target_slot != "active":
        if player.active:
            return True, "喷射能量效果：切换了战斗宝可梦。"
    return False, ""

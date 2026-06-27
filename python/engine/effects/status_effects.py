"""Status-condition effect handlers."""
from engine.enums import StatusType
from engine.game_state import GameState, ActionResult


def _handle_status(state, player, opponent, params):
    status_str = params.get("status", "")
    target_str = params.get("target", "opponent_active")

    from engine.enums import StatusType
    status_map = {
        "poisoned": StatusType.POISONED,
        "burned": StatusType.BURNED,
        "asleep": StatusType.ASLEEP,
        "paralyzed": StatusType.PARALYZED,
        "confused": StatusType.CONFUSED,
    }

    status = status_map.get(status_str.lower())
    if status is None:
        return ActionResult(False, f"未知状态: {status_str}")

    target_pokemon = None
    if target_str == "opponent_active":
        target_pokemon = opponent.active
    elif target_str == "self":
        target_pokemon = player.active

    if target_pokemon:
        # Check if target is immune to all effects (prevent_all)
        if getattr(target_pokemon, 'all_prevented_next_turn', False):
            state._log(f"{target_pokemon.card.name}免疫了所有效果！")
            return ActionResult(True, "免疫了效果。")

        # Mutual exclusion: Asleep, Paralyzed, Confused replace each other
        if status in (StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED):
            target_pokemon.status_conditions -= {
                StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED
            }
        target_pokemon.status_conditions.add(status)
        if status == StatusType.PARALYZED:
            target_pokemon.paralyzed_since_turn = state.turn_number
        status_cn_map = {"poisoned": "中毒", "burned": "灼伤", "asleep": "睡眠",
                         "paralyzed": "麻痹", "confused": "混乱"}
        cn_status = status_cn_map.get(status_str, status_str)
        msg = f"{target_pokemon.card.name}陷入了{cn_status}状态！"
        state._log(msg)
        return ActionResult(True, msg, status_applied=[status_str])
    return ActionResult(False, "没有状态效果的目标。")


def _handle_conditional_status(state, player, opponent, params):
    """Apply status if a condition is met (e.g. 愤怒冷冻: if own Pokemon was KO'd by attack last turn)."""
    status_str = params.get("status", "")
    target_str = params.get("target", "opponent_active")
    condition = params.get("condition", "")

    if condition == "ko_by_attack_last_turn":
        if not player.was_ko_by_attack:
            state._log(f"上个对手回合没有宝可梦因招式伤害昏厥，{status_str}效果不触发。")
            return ActionResult(True, "条件未满足，不触发麻痹。")
        player.was_ko_by_attack = False  # Consume the flag

    from engine.enums import StatusType
    status_map = {
        "poisoned": StatusType.POISONED,
        "burned": StatusType.BURNED,
        "asleep": StatusType.ASLEEP,
        "paralyzed": StatusType.PARALYZED,
        "confused": StatusType.CONFUSED,
    }
    status = status_map.get(status_str.lower())
    if status is None:
        return ActionResult(False, f"未知状态: {status_str}")

    target_pokemon = None
    if target_str == "opponent_active":
        target_pokemon = opponent.active
    elif target_str == "self":
        target_pokemon = player.active

    if target_pokemon:
        if getattr(target_pokemon, 'all_prevented_next_turn', False):
            state._log(f"{target_pokemon.card.name}免疫了效果！")
            return ActionResult(True, "免疫了效果。")
        if status in (StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED):
            target_pokemon.status_conditions -= {
                StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED
            }
        target_pokemon.status_conditions.add(status)
        if status == StatusType.PARALYZED:
            target_pokemon.paralyzed_since_turn = state.turn_number
        status_cn = {"poisoned": "中毒", "burned": "灼伤", "asleep": "睡眠",
                     "paralyzed": "麻痹", "confused": "混乱"}
        cn_status = status_cn.get(status_str, status_str)
        msg = f"{target_pokemon.card.name}陷入了{cn_status}状态！"
        state._log(msg)
        return ActionResult(True, msg, status_applied=[status_str])
    return ActionResult(False, "没有状态效果的目标。")


def _handle_attack_fail(state, params):
    """Mark the current attack as failed. Used by 跳一下 on coin flip tails."""
    result = ActionResult(True, "招式失败了！")
    result.attack_failed = True
    state._log("招式失败了！")
    return result


def _handle_dazzling_beam(state, opponent, params):
    """炫目光束: mark opponent's active Pokemon with dazzled status.
    Next turn when that Pokemon attacks, flip a coin; tails = attack fails."""
    if opponent.active:
        if getattr(opponent.active, 'all_prevented_next_turn', False):
            opponent.active.all_prevented_next_turn = False
            state._log(f"{opponent.active.card.name}免疫了炫目光束的效果！")
            return ActionResult(True, "免疫了效果。")
        opponent.active.dazzled = True
        state._log(f"{opponent.active.card.name}被炫目光束命中！下次使用招式时将掷硬币。")
        return ActionResult(True, f"{opponent.active.card.name}被炫目光束命中。")
    return ActionResult(True, "没有目标。")


def _handle_attack_lock_basic(state, opponent, params):
    """Lock the opponent's active Pokemon from attacking next turn
    if it is a basic Pokemon."""
    target_poke = opponent.active
    if target_poke is None:
        return ActionResult(True, "没有目标。")

    if getattr(target_poke, 'all_prevented_next_turn', False):
        target_poke.all_prevented_next_turn = False
        state._log(f"{target_poke.card.name}免疫了攻击封锁的效果！")
        return ActionResult(True, "免疫了效果。")

    if target_poke.card.is_basic_pokemon:
        target_poke.attack_locked = True
        state._log(f"{target_poke.card.name}在下一个回合无法使用招式！")
        return ActionResult(True, f"{target_poke.card.name}被封锁了招式。")

    state._log(f"{target_poke.card.name}不是基础宝可梦，冻结无效。")
    return ActionResult(True, "目标不是基础宝可梦，冻结无效。")


def _handle_apply_outgoing_damage_reduction(state, player, opponent, params):
    """Mark a Pokemon so its next attack deals less damage."""
    target_str = params.get("target", "opponent_active")
    amount = int(params.get("amount", 0) or 0)
    target = opponent.active if target_str == "opponent_active" else player.active
    if target is None or amount <= 0:
        return ActionResult(True, "没有目标。")

    if getattr(target, "all_prevented_next_turn", False):
        target.all_prevented_next_turn = False
        state._log(f"{target.card.name}免疫了恫吓的效果！")
        return ActionResult(True, "免疫了效果。")

    target.outgoing_damage_reduction_next_turn = max(
        int(getattr(target, "outgoing_damage_reduction_next_turn", 0) or 0),
        amount,
    )
    state._log(f"{target.card.name}下次使用招式的伤害-{amount}。")
    return ActionResult(True, f"{target.card.name}被恫吓。")


def _handle_self_attack_lock(state, player, params, source_slot):
    """Lock a specific attack from being used consecutively.
    Used by 岩窟冲撞: can't use on consecutive turns."""
    attack_name = params.get("attack_name", "")
    target = player.get_pokemon(source_slot)
    if target and attack_name:
        target.attack_locked_names[attack_name] = state.turn_number
        state._log(f"{target.card.name}下回合无法使用「{attack_name}」。")
    return ActionResult(True, f"「{attack_name}」已锁定，下回合无法使用。")


def _handle_prevent_damage(state, player, params, source_slot):
    target = player.get_pokemon(source_slot)
    if target:
        target.damage_prevented_next_turn = True
        state._log(f"{target.card.name}下回合将免疫所有伤害。")
    return ActionResult(True, "已设置伤害免疫。")


def _handle_prevent_effects(state, player, params, source_slot):
    """Set immunity to attack effects (NOT base damage) next turn.
    Used by 七夕青鸟ex 光之波动."""
    target = player.get_pokemon(source_slot)
    if target:
        target.all_prevented_next_turn = True
        state._log(f"{target.card.name}下回合将免疫招式的附加效果！")
    return ActionResult(True, "已设置效果免疫。")


def _handle_prevent_all(state, player, params, source_slot):
    """Set immunity to all damage and effects next turn.
    Used by 怒鹦哥 飞翔 (heads result)."""
    target = player.get_pokemon(source_slot)
    if target:
        target.damage_prevented_next_turn = True
        target.all_prevented_next_turn = True
        state._log(f"{target.card.name}下回合将免疫所有伤害和效果！")
    return ActionResult(True, "已设置全部免疫。")

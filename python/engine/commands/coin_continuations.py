"""Coin and attachment pending-choice continuation handlers."""
from __future__ import annotations


def register_coin_continuations(registry, stack) -> None:
    registry.register(
        "flip_coin_branch",
        lambda _req, cont, choice, player_idx, slot:
            continue_flip_coin_branch(stack, cont, choice, player_idx, slot),
    )
    registry.register(
        "coin_special",
        lambda _req, cont, choice, player_idx, _slot:
            resolve_coin_special(stack, cont, choice, player_idx),
    )
    registry.register(
        "coin_energy_discard",
        lambda _req, _cont, choice, player_idx, _slot:
            resolve_coin_energy_discard(stack, choice, player_idx),
    )
    registry.register(
        "discard_attachment",
        lambda _req, _cont, choice, _player_idx, _slot:
            resolve_discard_attachment(stack, choice),
    )


def continue_flip_coin_branch(
    stack,
    continuation: dict,
    choice,
    _player_idx: int,
    _source_slot: str,
):
    from engine.game_state import ActionResult

    results = [bool(item) for item in (choice or [])]
    is_heads = bool(results and results[0])
    cn = "正面" if is_heads else "反面"
    stack.state._log(f"掷硬币: {cn}!")
    branch_items = list(
        continuation.get("on_heads" if is_heads else "on_tails", [])
        or []
    )
    if branch_items:
        try:
            from engine.commands.primitives_coin import _build_branch_command

            stack.push_many([
                _build_branch_command(item)
                for item in branch_items
            ])
        except Exception as exc:
            return ActionResult(False, str(exc))
    return ActionResult(True, f"硬币: {cn}.")


def resolve_coin_special(
    stack,
    continuation: dict,
    choice,
    player_idx: int,
):
    from engine.game_state import ActionResult
    from engine.rules_constants import DAMAGE_PER_COUNTER
    from engine.commands.primitives_combat import (
        _consume_effect_damage_prevention,
        _queue_or_apply_opponent_active_damage,
    )

    results = [bool(item) for item in (choice or [])]
    heads = sum(1 for result in results if result)
    coin_kind = str(continuation.get("coin_kind", "repeat_damage") or "repeat_damage")
    params = dict(continuation.get("params", {}) or {})
    player = stack.state.get_player(player_idx)
    opponent = stack.state.get_player(1 - player_idx)

    if coin_kind == "double_ko":
        if len(results) >= 2 and results[0] and results[1]:
            target = opponent.active
            if target is None:
                return ActionResult(True, "没有对手宝可梦。")
            if _consume_effect_damage_prevention(stack.state, target):
                return ActionResult(True, "击倒效果被免疫。")
            remaining = target.current_hp
            counters = max(1, (remaining + DAMAGE_PER_COUNTER - 1) // DAMAGE_PER_COUNTER)
            target.damage_counters += counters
            stack.state._log(f"{target.card.name}被大树切割击倒！")
            return ActionResult(True, f"{target.card.name}被击倒！", pokemon_ko=["opponent_active"])
        stack.state._log("大树切割失败。")
        return ActionResult(True, "大树切割失败。")

    damage_per = int(
        params.get(
            "per_head",
            params.get("damage_per_head", 10 if coin_kind == "repeat_damage" else 20),
        )
        or 0
    )
    total = heads * damage_per
    stack.state._log(f"掷硬币结果: {heads}次正面，造成{total}点伤害。")
    if total > 0 and opponent.active:
        result = _queue_or_apply_opponent_active_damage(
            stack.state,
            player_idx,
            player,
            opponent,
            total,
            "",
            f"硬币伤害: {total}。",
        )
        if result is not None:
            return result
    return ActionResult(True, f"硬币伤害: {total}。", damage_dealt=total)


def resolve_coin_energy_discard(
    stack,
    choice,
    player_idx: int,
):
    from engine.game_state import ActionRequest, ActionResult

    results = [bool(item) for item in (choice or [])]
    is_heads = bool(results and results[0])
    cn = "正面" if is_heads else "反面"
    stack.state._log(f"掷硬币: {cn}!")
    if not is_heads:
        return ActionResult(True, f"硬币: {cn}。没有丢弃能量。")

    opponent_idx = 1 - player_idx
    opponent = stack.state.get_player(opponent_idx)
    attachment_options = []
    for slot_name, pokemon in opponent.get_all_pokemon():
        if not pokemon:
            continue
        for index, energy in enumerate(pokemon.energy_cards):
            attachment_options.append({
                "player": opponent_idx,
                "slot": slot_name,
                "attachment_type": "energy",
                "index": index,
                "card_id": energy.api_id,
                "label": f"{pokemon.card.name} - {energy.name}",
            })
    if not attachment_options:
        return ActionResult(True, "对手场上没有能量可丢弃。")

    return ActionRequest(
        request_type="select_attachment",
        player=player_idx,
        prompt="选择对手场上的1个能量丢弃。",
        min_select=1,
        max_select=1,
        target_player="opponent",
        target_info=attachment_options,
        continuation={"kind": "discard_attachment"},
    )


def resolve_discard_attachment(stack, choice):
    from engine.game_state import ActionResult
    from engine.actions import AttachmentRef

    selected_refs = list(choice or [])
    ref = selected_refs[0] if selected_refs else None
    if not isinstance(ref, AttachmentRef):
        return ActionResult(False, "没有选择有效能量。")
    target_poke = stack.state.get_player(ref.player).get_pokemon(ref.slot)
    if (
        target_poke is None
        or ref.index < 0
        or ref.index >= len(target_poke.energy_cards)
        or target_poke.energy_cards[ref.index].api_id != ref.card_id
    ):
        return ActionResult(False, "选择的能量已不存在。")
    discarded_energy = target_poke.energy_cards.pop(ref.index)
    stack.state.get_player(ref.player).discard.append(discarded_energy)
    stack.state._log(f"从{target_poke.card.name}身上丢弃了{discarded_energy.name}。")
    return ActionResult(True, f"粉碎之锤：丢弃了{target_poke.card.name}的1个能量。")

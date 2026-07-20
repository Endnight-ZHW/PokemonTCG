"""Serializable prize-card choice continuations.

Prize identities remain authoritative and hidden.  The first choice exposes
only face-down positions; Treasure Energy is held in the prize zone until its
optional attachment target is resolved, so snapshot recovery never needs an
unowned loose Card object.
"""
from __future__ import annotations


def register_prize_continuations(registry, stack) -> None:
    registry.register(
        "select_prize",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_select_prize(stack, cont, choice),
    )
    registry.register(
        "treasure_prize_target",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_treasure_prize_target(stack, cont, choice),
    )


def resolve_select_prize(stack, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    player_idx = int(continuation.get("player_idx", -1))
    if player_idx not in (0, 1):
        return ActionResult(False, "奖赏卡选择玩家无效。")
    # ``select_prize`` is a single-value legacy bridge: position zero is a
    # valid scalar choice and must not be collapsed by truthiness handling.
    selected = [choice] if type(choice) is int else list(choice or [])
    if len(selected) != 1 or type(selected[0]) is not int:
        return ActionResult(False, "必须选择1张奖赏卡。")
    prize_idx = selected[0]
    player = stack.state.get_player(player_idx)
    if not (0 <= prize_idx < len(player.prizes)):
        return ActionResult(False, "所选奖赏卡位置已失效。")
    card = player.prizes[prize_idx]

    trigger = _prize_attachment_trigger(card)
    if trigger is not None:
        targets = [
            (slot, pokemon)
            for slot, pokemon in player.get_all_pokemon()
            if pokemon is not None and str(slot).startswith("bench_")
        ]
        if targets:
            card_name = str(getattr(card, "name", "奖赏能量") or "奖赏能量")
            return ActionRequest(
                request_type="select_prize_energy_target",
                player=player_idx,
                prompt=f"可将{card_name}附着于自己的1只备战宝可梦；也可以放弃。",
                min_select=0,
                max_select=1,
                can_cancel=True,
                from_zone="board",
                target_player="self",
                card_list=[pokemon.card for _slot, pokemon in targets],
                continuation={
                    "kind": "treasure_prize_target",
                    "domain": "prize",
                    "player_idx": player_idx,
                    "prize_index": prize_idx,
                    "card_id": str(getattr(card, "api_id", "") or ""),
                    "trigger_hook": str(trigger.get("hook", "")),
                    "trigger_op": str((trigger.get("effect") or {}).get("op", "")),
                },
            )

    player.take_prize(prize_idx)
    stack.state._log(f"{player.name}获得了奖赏卡！（剩余{len(player.prizes)}张）")
    return ActionResult(True, "已拿取奖赏卡。", prize_taken=True)


def resolve_treasure_prize_target(stack, continuation: dict, choice):
    from engine.actions import PokemonRef, resolve_pokemon_ref
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", -1))
    prize_idx = int(continuation.get("prize_index", -1))
    expected_id = str(continuation.get("card_id", "") or "")
    if player_idx not in (0, 1):
        return ActionResult(False, "宝藏能量选择玩家无效。")
    player = stack.state.get_player(player_idx)
    if not (0 <= prize_idx < len(player.prizes)):
        return ActionResult(False, "宝藏能量的奖赏卡位置已失效。")
    card = player.prizes[prize_idx]
    trigger = _prize_attachment_trigger(card)
    if (
        getattr(card, "api_id", "") != expected_id
        or trigger is None
        or str(trigger.get("hook", "")) != str(continuation.get("trigger_hook", ""))
        or str((trigger.get("effect") or {}).get("op", ""))
        != str(continuation.get("trigger_op", ""))
    ):
        return ActionResult(False, "奖赏能量实体或触发描述符已失效。")

    selected = list(choice or [])
    target = None
    if selected:
        if len(selected) != 1 or not isinstance(selected[0], PokemonRef):
            return ActionResult(False, "宝藏能量附着目标无效。")
        if selected[0].player != player_idx:
            return ActionResult(False, "宝藏能量只能附着于自己的宝可梦。")
        target = resolve_pokemon_ref(stack.state, selected[0])
        if target is None:
            return ActionResult(False, "宝藏能量附着目标已失效。")

    player.prizes.pop(prize_idx)
    if target is None:
        player.hand.append(card)
        message = f"{player.name}获得了奖赏卡。（宝藏能量加入手牌）"
    else:
        target.energy_cards.append(card)
        message = f"{player.name}将奖赏卡中的宝藏能量附着于{target.card.name}。"
    stack.state._log(f"{message}（剩余{len(player.prizes)}张）")
    return ActionResult(True, message, prize_taken=True)


def _prize_attachment_trigger(card) -> dict | None:
    """Return the authoritative data-defined prize attachment trigger.

    Card identity is intentionally irrelevant: cloned cards with the same
    descriptor have identical rules behavior, while a familiar ID without the
    descriptor receives no privileged path.
    """
    for value in getattr(card, "energy_effects", ()) or ():
        if not isinstance(value, dict):
            continue
        effect = value.get("effect") or {}
        condition = value.get("condition") or {}
        if (
            value.get("kind") == "trigger"
            and value.get("hook") == "ON_PRIZE_REVEALED"
            and condition.get("source_zone") == "prizes"
            and isinstance(effect, dict)
            and effect.get("op") == "attach_to_benched_pokemon"
        ):
            return dict(value)
    return None


__all__ = [
    "register_prize_continuations",
    "resolve_select_prize",
    "resolve_treasure_prize_target",
]

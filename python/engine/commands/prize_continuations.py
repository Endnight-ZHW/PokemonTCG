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

    if getattr(card, "api_id", "") == "svi-trea":
        targets = [
            (slot, pokemon)
            for slot, pokemon in player.get_all_pokemon()
            if pokemon is not None
        ]
        if targets:
            return ActionRequest(
                request_type="select_prize_energy_target",
                player=player_idx,
                prompt="可将宝藏能量附着于自己的1只宝可梦；也可以放弃。",
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
                    "card_id": "svi-trea",
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
    if getattr(card, "api_id", "") != expected_id or expected_id != "svi-trea":
        return ActionResult(False, "宝藏能量实体已失效。")

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


__all__ = [
    "register_prize_continuations",
    "resolve_select_prize",
    "resolve_treasure_prize_target",
]

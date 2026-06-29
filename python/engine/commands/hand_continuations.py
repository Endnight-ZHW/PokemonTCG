"""Hand mutation pending-choice continuation handlers."""
from __future__ import annotations

from engine.commands.choice_helpers import take_selected_cards_from_zone


def register_hand_continuations(registry, stack) -> None:
    registry.register(
        "discard_hand_cards",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_discard_hand_cards(stack, cont, choice),
    )
    registry.register(
        "discard_hand_then_draw",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_discard_hand_then_draw(stack, cont, choice),
    )
    registry.register(
        "hand_to_bottom_then_draw",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_hand_to_bottom_then_draw(stack, cont, choice),
    )
    registry.register(
        "hand_to_bottom_draw_until",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_hand_to_bottom_draw_until(stack, cont, choice),
    )
    registry.register(
        "zinnia_resolve",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_zinnia(stack, cont, choice),
    )


def resolve_discard_hand_cards(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    amount = int(continuation.get("amount", 0) or 0)
    player = stack.state.get_player(player_idx)
    indices_to_discard = hand_indices_for_selected_cards(
        player,
        choice,
        amount,
    )
    discarded = player.discard_from_hand(indices_to_discard)
    stack.state._log(f"从手牌丢弃了{len(discarded)}张卡。")
    return ActionResult(
        True,
        f"丢弃了{len(discarded)}张手牌。",
        cards_discarded=len(discarded),
    )


def resolve_discard_hand_then_draw(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    discard_amount = int(continuation.get("discard_amount", 0) or 0)
    draw_amount = int(continuation.get("draw_amount", 0) or 0)
    player = stack.state.get_player(player_idx)
    indices_to_discard = hand_indices_for_selected_cards(
        player,
        choice,
        discard_amount,
    )
    discarded = player.discard_from_hand(indices_to_discard)
    drawn = player.draw_cards(draw_amount)
    stack.state._log(
        f"{player.name}丢弃了{len(discarded)}张手牌并抽取了{len(drawn)}张卡。"
    )
    return ActionResult(
        True,
        f"丢弃{len(discarded)}张手牌并抽取了{len(drawn)}张。",
        cards_drawn=drawn,
        cards_discarded=len(discarded),
    )


def hand_indices_for_selected_cards(player, choice, limit: int) -> list[int]:
    from collections import Counter

    selected_cards = list(choice or [])[: max(0, int(limit or 0))]
    target_counts = Counter(
        getattr(card, "api_id", "")
        for card in selected_cards
    )
    indices_to_discard = []
    for index, hand_card in enumerate(player.hand):
        api_id = getattr(hand_card, "api_id", "")
        if target_counts.get(api_id, 0) > 0:
            indices_to_discard.append(index)
            target_counts[api_id] -= 1
    return indices_to_discard


def resolve_hand_to_bottom_then_draw(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    selected = take_selected_cards_from_zone(
        player,
        "hand",
        choice,
        len(list(choice or [])),
    )
    for card in selected:
        player.deck.insert(0, card)
    stack.state._log(f"{player.name}将{len(selected)}张手牌放回牌库底。")
    drawn = player.draw_cards(len(selected))
    stack.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
    return ActionResult(
        True,
        f"放回{len(selected)}张并抽取了{len(drawn)}张。",
        cards_drawn=drawn,
    )


def resolve_hand_to_bottom_draw_until(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    target = int(continuation.get("target_hand_size", 5) or 5)
    player = stack.state.get_player(player_idx)
    selected = take_selected_cards_from_zone(player, "hand", choice, 1)
    if selected:
        player.deck.insert(0, selected[0])
    to_draw = max(0, target - len(player.hand))
    drawn = player.draw_cards(to_draw)
    if selected:
        stack.state._log(
            f"{player.name}将1张手牌放回牌库底，抽取了{len(drawn)}张。"
        )
    return ActionResult(
        True,
        f"抽取了{len(drawn)}张卡。",
        cards_drawn=drawn,
    )


def resolve_zinnia(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    discard_count = int(continuation.get("discard_count", 2) or 2)
    draw_amount = int(continuation.get("draw_amount", 0) or 0)
    player = stack.state.get_player(player_idx)
    discarded = take_selected_cards_from_zone(
        player,
        "hand",
        choice,
        discard_count,
    )
    player.discard.extend(discarded)
    stack.state._log(f"{player.name}丢弃了{len(discarded)}张手牌（希嘉娜的决心）。")
    drawn = player.draw_cards(draw_amount)
    stack.state._log(
        f"{player.name}抽取了{len(drawn)}张卡（对手场上有{draw_amount}只宝可梦）。"
    )
    return ActionResult(
        True,
        f"丢弃{len(discarded)}张手牌，抽取了{len(drawn)}张。",
        cards_drawn=drawn,
        cards_discarded=len(discarded),
    )

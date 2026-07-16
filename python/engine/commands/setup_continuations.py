"""Serializable continuations for the official opening procedure.

The authoritative state always contains real card identities.  These
continuations expose only turn-order and bonus-count decisions; player-facing
state projection is responsible for replacing face-down cards with strict
hidden placeholders until ``setup_stage == 'COMPLETE'``.
"""
from __future__ import annotations

from collections import Counter

from engine.enums import TurnPhase
from engine.game_state import ActionRequest, ActionResult
from engine.rules_constants import HAND_SIZE_INITIAL


SETUP_STAGES = frozenset({
    "TURN_ORDER",
    "INITIAL_PLACEMENT",
    "BONUS_DRAW",
    "BONUS_PLACEMENT",
    "COMPLETE",
})


def _replace_pair(pair, index: int, value):
    values = list(pair)
    values[index] = value
    return tuple(values)


def _bind_direct_callback(state, request: ActionRequest) -> ActionRequest:
    """Keep the transitional callback API usable before VM persistence.

    Once restored from a snapshot, ``pending_continuation`` binds the same
    continuation kind through the registry instead of retaining this closure.
    """
    kind = str(request.continuation.get("kind", "") or "")
    if kind == "choose_turn_order":
        request.callback = lambda choice: resolve_choose_turn_order(state, choice)
    elif kind == "choose_mulligan_draw_count":
        request.callback = lambda choice: resolve_choose_mulligan_draw_count(
            state,
            request.continuation,
            choice,
        )
    return request


def make_turn_order_request(state) -> ActionRequest:
    winner = int(state.opening_coin_winner_idx)
    if winner not in (0, 1):
        raise ValueError("开局硬币胜者无效。")
    return _bind_direct_callback(
        state,
        ActionRequest(
            request_type="choose_turn_order",
            player=winner,
            prompt="请选择先攻或后攻。",
            min_select=1,
            max_select=1,
            continuation={
                "kind": "choose_turn_order",
                "domain": "setup",
                "frame_id": "setup:turn_order",
                "opening_coin_winner_idx": winner,
            },
        ),
    )


def make_mulligan_bonus_request(state, player_idx: int) -> ActionRequest:
    maximum = int(state.mulligan_bonus_max[player_idx])
    return _bind_direct_callback(
        state,
        ActionRequest(
            request_type="choose_mulligan_draw_count",
            player=player_idx,
            prompt=f"对手再战，选择额外抽取0至{maximum}张卡。",
            min_select=1,
            max_select=1,
            continuation={
                "kind": "choose_mulligan_draw_count",
                "domain": "setup",
                "frame_id": f"setup:mulligan_bonus:{player_idx}",
                "player_idx": player_idx,
                "maximum": maximum,
            },
        ),
    )


def register_setup_continuations(registry, stack) -> None:
    registry.register(
        "choose_turn_order",
        lambda _req, _cont, choice, _player_idx, _slot:
            resolve_choose_turn_order(stack.state, choice),
    )
    registry.register(
        "choose_mulligan_draw_count",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_choose_mulligan_draw_count(stack.state, cont, choice),
    )


def resolve_choose_turn_order(state, choice):
    if state.phase != TurnPhase.SETUP or state.setup_stage != "TURN_ORDER":
        return ActionResult(False, "当前不能选择先后攻。")
    winner = int(state.opening_coin_winner_idx)
    if winner not in (0, 1) or state.setup_actor_idx != winner:
        return ActionResult(False, "开局硬币选择状态无效。")

    selected = choice[0] if isinstance(choice, (list, tuple)) and choice else choice
    selected = str(selected or "").lower()
    if selected not in {"first", "second"}:
        return ActionResult(False, "必须选择先攻或后攻。")

    state.first_player_idx = winner if selected == "first" else 1 - winner
    state.active_player_idx = state.first_player_idx
    state.turn_number = 1
    _draw_opening_hands_and_resolve_mulligans(state)
    state.setup_stage = "INITIAL_PLACEMENT"
    state.setup_actor_idx = state.first_player_idx
    state._log(
        f"{state.get_player(winner).name}选择"
        f"{'先攻' if selected == 'first' else '后攻'}；"
        f"{state.get_player(state.first_player_idx).name}先放置宝可梦。"
    )
    return ActionResult(True, "已选择先后攻，开始初始放置。")


def _draw_opening_hands_and_resolve_mulligans(state) -> None:
    """Draw legal seven-card hands using simultaneous mulligan rounds."""
    for player_idx in (0, 1):
        player = state.get_player(player_idx)
        if player.hand:
            player.deck.extend(player.hand)
            player.hand.clear()
            player.shuffle_deck()
        player.draw_cards(HAND_SIZE_INITIAL)

    counts = [0, 0]
    bonus = [0, 0]
    for _round in range(10_000):
        missing = [
            not any(card.is_basic_pokemon for card in state.get_player(idx).hand)
            for idx in (0, 1)
        ]
        if not any(missing):
            state.mulligan_count = tuple(counts)
            state.mulligan_bonus_max = tuple(bonus)
            state.extra_draws = tuple(bonus)
            return

        for idx in (0, 1):
            if missing[idx]:
                counts[idx] += 1

        if missing[0] and missing[1]:
            state._log("双方本轮均无基础宝可梦，同时再战；本轮奖励相抵。")
        else:
            loser = 0 if missing[0] else 1
            bonus[1 - loser] += 1
            state._log(
                f"{state.get_player(loser).name}本轮再战；"
                f"{state.get_player(1 - loser).name}获得1次奖励抽牌额度。"
            )

        for idx in (0, 1):
            if not missing[idx]:
                continue
            player = state.get_player(idx)
            player.deck.extend(player.hand)
            player.hand.clear()
            player.shuffle_deck()
            player.draw_cards(HAND_SIZE_INITIAL)

    raise RuntimeError("再战轮次超过安全上限，请检查牌组或随机源。")


def finish_initial_placement(state) -> ActionRequest | None:
    """Set prizes, then begin the optional post-prize bonus draw."""
    if not all(state.setup_initial_done):
        return None
    if state.p1.active is None or state.p2.active is None:
        raise ValueError("双方都必须放置战斗宝可梦。")
    if state.p1.prizes or state.p2.prizes:
        raise ValueError("奖赏卡已设置，不能重复执行开局结算。")

    state.set_prizes()
    state.setup_bonus_draw_done = tuple(
        int(state.mulligan_bonus_max[idx]) <= 0 for idx in (0, 1)
    )
    state.setup_bonus_placement_done = tuple(
        int(state.mulligan_bonus_max[idx]) <= 0 for idx in (0, 1)
    )
    return advance_bonus_setup(state)


def advance_bonus_setup(state) -> ActionRequest | None:
    """Request the next bonus count or atomically reveal/start turn one."""
    order = (state.first_player_idx, 1 - state.first_player_idx)
    for player_idx in order:
        if not state.setup_bonus_draw_done[player_idx]:
            state.setup_stage = "BONUS_DRAW"
            state.setup_actor_idx = player_idx
            return make_mulligan_bonus_request(state, player_idx)
        if not state.setup_bonus_placement_done[player_idx]:
            state.setup_stage = "BONUS_PLACEMENT"
            state.setup_actor_idx = player_idx
            return None

    complete_setup(state)
    return None


def resolve_choose_mulligan_draw_count(state, continuation: dict, choice):
    if state.phase != TurnPhase.SETUP or state.setup_stage != "BONUS_DRAW":
        return ActionResult(False, "当前不能选择再战奖励抽牌数。")
    player_idx = int(continuation.get("player_idx", -1))
    maximum = int(continuation.get("maximum", -1))
    if player_idx not in (0, 1) or state.setup_actor_idx != player_idx:
        return ActionResult(False, "再战奖励选择玩家无效。")
    if maximum != int(state.mulligan_bonus_max[player_idx]) or maximum < 0:
        return ActionResult(False, "再战奖励上限已失效。")

    selected = choice[0] if isinstance(choice, (list, tuple)) and choice else choice
    if type(selected) is not int or not (0 <= selected <= maximum):
        return ActionResult(False, f"奖励抽牌数必须在0至{maximum}之间。")

    player = state.get_player(player_idx)
    drawn = player.draw_cards(selected)
    state.setup_bonus_card_ids[player_idx].extend(
        str(getattr(card, "api_id", "") or "") for card in drawn
    )
    state.setup_bonus_draw_count = _replace_pair(
        state.setup_bonus_draw_count,
        player_idx,
        len(drawn),
    )
    state.setup_bonus_draw_done = _replace_pair(
        state.setup_bonus_draw_done,
        player_idx,
        True,
    )
    state._log(f"{player.name}选择额外抽取{len(drawn)}张卡。")

    eligible = Counter(state.setup_bonus_card_ids[player_idx])
    can_place = player.bench_has_space() and any(
        card.is_basic_pokemon and eligible.get(str(card.api_id), 0) > 0
        for card in player.hand
    )
    if can_place:
        state.setup_stage = "BONUS_PLACEMENT"
        state.setup_actor_idx = player_idx
        return ActionResult(True, "可将奖励抽到的基础宝可梦追加到备战区。")

    state.setup_bonus_placement_done = _replace_pair(
        state.setup_bonus_placement_done,
        player_idx,
        True,
    )
    state.setup_bonus_card_ids[player_idx].clear()
    pending = advance_bonus_setup(state)
    return ActionResult(
        True,
        "奖励抽牌完成。",
        cards_drawn=list(drawn),
        pending_action=pending,
    )


def finish_bonus_placement(state, player_idx: int) -> ActionRequest | None:
    if state.setup_stage != "BONUS_PLACEMENT" or state.setup_actor_idx != player_idx:
        raise ValueError("当前不能结束奖励宝可梦放置。")
    state.setup_bonus_placement_done = _replace_pair(
        state.setup_bonus_placement_done,
        player_idx,
        True,
    )
    state.setup_bonus_card_ids[player_idx].clear()
    return advance_bonus_setup(state)


def complete_setup(state) -> None:
    """Flip both fields together and begin turn one with the normal draw."""
    state.setup_stage = "COMPLETE"
    state.setup_actor_idx = -1
    state.active_player_idx = state.first_player_idx
    state.phase = TurnPhase.DRAW
    state.begin_turn_fact_window(state.first_player_idx, state.turn_number)
    state._log(
        f"准备完成，双方同时翻开宝可梦。"
        f"{state.get_active_player().name}的第1回合开始。"
    )
    from engine.turn_manager import TurnManager

    TurnManager(state)._handle_draw_phase()


__all__ = [
    "SETUP_STAGES",
    "advance_bonus_setup",
    "complete_setup",
    "finish_bonus_placement",
    "finish_initial_placement",
    "make_mulligan_bonus_request",
    "make_turn_order_request",
    "register_setup_continuations",
    "resolve_choose_mulligan_draw_count",
    "resolve_choose_turn_order",
]

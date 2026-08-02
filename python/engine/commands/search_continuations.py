"""Search and top-deck pending-choice continuation handlers."""
from __future__ import annotations

from engine.commands.energy_continuations import (
    normalize_energy_assignments,
    resolve_source_card,
)
from engine.commands.choice_helpers import (
    attach_lightning_energy_to_bench,
    find_selected_card_in_zone,
    partition_top_cards,
    peek_expected_top_cards,
    pop_expected_top_cards,
    resolve_board_choice,
    return_top_cards,
    selected_top_positions_from_request,
    take_selected_cards_from_zone,
)


def register_search_continuations(registry, stack) -> None:
    registry.register(
        "search_cards",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_search_cards(stack, cont, choice),
    )
    registry.register(
        "search_item_and_tool",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_search_item_and_tool(stack, cont, choice),
    )
    registry.register(
        "trekking_shoes",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_trekking_shoes(stack, cont, choice),
    )
    registry.register(
        "look_top_deck",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_look_top_deck(stack, req, cont, choice),
    )
    registry.register(
        "detached_energy_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_detached_energy_distribution(stack, req, cont, choice),
    )
    registry.register(
        "look_top_bench_energy_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_look_top_bench_energy_distribution(stack, req, cont, choice),
    )
    registry.register(
        "look_top_attach_energy",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_look_top_attach_energy(stack, req, cont, choice),
    )
    registry.register(
        "look_top_attach_target",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_look_top_attach_target(stack, cont, choice),
    )
    registry.register(
        "search_any_and_switch",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_search_any_and_switch(stack, cont, choice),
    )
    registry.register(
        "search_any_switch_confirm",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_search_any_switch_confirm(stack, cont, choice),
    )
    registry.register(
        "search_any_switch_bench",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_search_any_switch_bench(stack, cont, choice),
    )


def resolve_search_cards(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    from_zone = str(continuation.get("from_zone", "deck") or "deck")
    destination = str(continuation.get("destination", "hand") or "hand")
    count = int(continuation.get("count", 1) or 1)
    player = stack.state.get_player(player_idx)
    if destination == "bench":
        count = min(
            count,
            sum(1 for pokemon in player.bench if pokemon is None),
        )
    selected = take_selected_cards_from_zone(
        player,
        from_zone,
        choice,
        count,
    )
    moved = 0
    for card in selected:
        if destination == "hand":
            player.hand.append(card)
            moved += 1
            continue
        if destination == "bench":
            slot = player.find_empty_bench_slot()
            if slot is None:
                continue
            pokemon = player.place_bench(card, slot)
            if pokemon is not None:
                pokemon.placed_this_turn = True
                moved += 1
    if from_zone == "deck":
        player.shuffle_deck()
    stack.state._log(f"{player.name}从{from_zone}选择了{moved}张卡。")
    return ActionResult(True, f"选择了{moved}张卡。")


def resolve_search_item_and_tool(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    item_taken = False
    tool_taken = False
    moved = 0
    for selected in list(choice or []):
        card = find_selected_card_in_zone(player, "deck", selected)
        if card is None:
            continue
        if getattr(card, "is_trainer_item", False) and not item_taken:
            player.deck.remove(card)
            player.hand.append(card)
            item_taken = True
            moved += 1
            continue
        if getattr(card, "is_trainer_tool", False) and not tool_taken:
            player.deck.remove(card)
            player.hand.append(card)
            tool_taken = True
            moved += 1
    player.shuffle_deck()
    stack.state._log(f"{player.name}从牌库选择了{moved}张卡（派帕）。")
    return ActionResult(True, f"选择了{moved}张卡。")


def resolve_trekking_shoes(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    confirmed = bool(choice)
    top_card = player.deck[-1] if player.deck else None
    expected_id = str(continuation.get("top_card_id", "") or "")
    if top_card is not None and expected_id:
        if getattr(top_card, "api_id", "") != expected_id:
            return ActionResult(False, "牌库顶卡已变化，无法继续结算。")

    top_name = str(continuation.get("top_card_name", "") or "")
    if confirmed:
        if player.deck:
            source_index = len(player.deck) - 1
            card = player.deck.pop()
            target_index = len(player.hand)
            player.hand.append(card)
            _emit_zone_event(
                stack.state,
                "card_moved",
                actor=player_idx,
                visibility="owner",
                card_id=getattr(card, "api_id", ""),
                source={"player": player_idx, "zone": "deck", "index": source_index},
                target={"player": player_idx, "zone": "hand", "index": target_index},
                amount=1,
                player=player_idx,
                card_ids=[getattr(card, "api_id", "")],
                count=1,
                source_zone="deck",
                source_index=source_index,
                target_zone="hand",
                target_index=target_index,
            )
            stack.state._log(f"{player.name}将牌库顶的「{card.name}」加入了手牌。")
        return ActionResult(True, "将牌库顶卡加入手牌。")

    if player.deck:
        source_index = len(player.deck) - 1
        card = player.deck.pop()
        target_index = len(player.discard)
        player.discard.append(card)
        _emit_zone_event(
            stack.state,
            "cards_discarded",
            actor=player_idx,
            visibility="public",
            card_id=getattr(card, "api_id", ""),
            source={"player": player_idx, "zone": "deck", "index": source_index},
            target={"player": player_idx, "zone": "discard", "index": target_index},
            amount=1,
            player=player_idx,
            card_ids=[getattr(card, "api_id", "")],
            count=1,
            source_zone="deck",
            source_index=source_index,
            target_zone="discard",
            target_index=target_index,
        )
        stack.state._log(
            f"{player.name}丢弃了牌库顶的「{getattr(card, 'name', top_name)}」。"
        )
    drawn = player.draw_cards(1)
    if drawn:
        _emit_zone_event(
            stack.state,
            "cards_drawn",
            actor=player_idx,
            visibility="owner",
            source={"player": player_idx, "zone": "deck"},
            target={"player": player_idx, "zone": "hand"},
            amount=len(drawn),
            player=player_idx,
            card_ids=[getattr(card, "api_id", "") for card in drawn],
            count=len(drawn),
            source_zone="deck",
            target_zone="hand",
        )
        stack.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
    return ActionResult(
        True,
        f"丢弃牌库顶并抽取了{len(drawn)}张。",
        cards_drawn=drawn,
    )


def resolve_look_top_deck(stack, req, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    take = int(continuation.get("take", 1) or 1)
    destination = str(continuation.get("destination", "hand") or "hand")
    selected_positions = selected_top_positions_from_request(
        req,
        continuation,
        choice,
        take,
        deck_size=len(player.deck),
    )

    if destination == "bench_energy":
        top_cards, error = peek_expected_top_cards(player, continuation)
        if error:
            return ActionResult(False, error)
        selected_cards = [
            top_cards[index]
            for index in selected_positions
            if 0 <= index < len(top_cards)
        ]
        bench_pokes = [
            (index, pokemon)
            for index, pokemon in enumerate(player.bench)
            if pokemon is not None
            and getattr(pokemon.card, "energy_types", None)
            and "Lightning" in pokemon.card.energy_types
        ]
        if selected_cards and not (
            len(bench_pokes) == 1 and len(selected_cards) <= 1
        ) and bench_pokes:
            targets_info = [
                {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                for index, pokemon in bench_pokes
            ]
            return ActionRequest(
                request_type="distribute_energy",
                player=player_idx,
                prompt="分配能量 — 电气发生器",
                card_list=selected_cards,
                target_info=targets_info,
                distribute_mode="distribute",
                min_select=len(selected_cards),
                max_select=len(selected_cards),
                source_name="电气发生器",
                continuation={
                    "kind": "look_top_bench_energy_distribution",
                    "player_idx": player_idx,
                    "top_card_ids": list(continuation.get("top_card_ids", []) or []),
                    "selected_top_positions": selected_positions,
                    "rest_bottom": bool(continuation.get("rest_bottom", True)),
                    "shuffle_rest": bool(continuation.get("shuffle_rest", False)),
                },
            )

        top_cards, error = pop_expected_top_cards(player, continuation)
        if error:
            return ActionResult(False, error)
        selected_cards, rest = partition_top_cards(top_cards, selected_positions)
        stack.state._log(
            f"{player.name}查看了牌库顶{len(top_cards)}张卡，选择了{len(selected_cards)}张。"
        )
        if selected_cards and not bench_pokes:
            return_top_cards(
                player,
                top_cards,
                rest_bottom=bool(continuation.get("rest_bottom", True)),
                shuffle_rest=bool(continuation.get("shuffle_rest", False)),
            )
            return ActionResult(True, "备战区没有雷属性宝可梦可附着能量。")
        result = attach_lightning_energy_to_bench(
            stack.state,
            player_idx,
            selected_cards,
        )
        return_top_cards(
            player,
            rest,
            rest_bottom=bool(continuation.get("rest_bottom", True)),
            shuffle_rest=bool(continuation.get("shuffle_rest", False)),
        )
        return result

    top_cards, error = pop_expected_top_cards(player, continuation)
    if error:
        return ActionResult(False, error)
    selected_cards, rest = partition_top_cards(top_cards, selected_positions)
    for card in selected_cards:
        player.hand.append(card)
        stack.state._log(f"{player.name}将{card.name}加入手牌。")
    return_top_cards(
        player,
        rest,
        rest_bottom=bool(continuation.get("rest_bottom", True)),
        shuffle_rest=bool(continuation.get("shuffle_rest", False)),
    )
    stack.state._log(
        f"{player.name}查看了牌库顶{len(top_cards)}张卡，选择了{len(selected_cards)}张。"
    )
    return ActionResult(True, f"选择了{len(selected_cards)}张卡。")


def resolve_detached_energy_distribution(stack, req, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    source_cards = list(getattr(req, "card_list", []) or [])
    assignments = normalize_energy_assignments(choice)
    attached = 0
    for energy_index, target_slot in assignments:
        if energy_index < 0 or energy_index >= len(source_cards):
            continue
        target = player.get_pokemon(target_slot)
        if target is None:
            continue
        card = source_cards[energy_index]
        target.energy_cards.append(card)
        attached += 1
        stack.state._log(f"将{card.name}附着于备战区{target.card.name}。")
    return ActionResult(True, f"附着了{attached}张能量。")


def resolve_look_top_bench_energy_distribution(stack, req, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    top_cards, error = pop_expected_top_cards(player, continuation)
    if error:
        return ActionResult(False, error)
    selected_positions = [
        int(index)
        for index in continuation.get("selected_top_positions", []) or []
    ]
    selected_cards, rest = partition_top_cards(top_cards, selected_positions)
    source_cards = list(getattr(req, "card_list", []) or selected_cards)
    assignments = normalize_energy_assignments(choice)
    attached = 0
    for energy_index, target_slot in assignments:
        if energy_index < 0 or energy_index >= len(source_cards):
            continue
        card = resolve_source_card(selected_cards, source_cards[energy_index])
        if card is None:
            continue
        target = player.get_pokemon(target_slot)
        if target is None:
            continue
        target.energy_cards.append(card)
        selected_cards.remove(card)
        attached += 1
        stack.state._log(f"将{card.name}附着于备战区{target.card.name}。")
    # Invalid or omitted assignments return the detached cards to the deck;
    # only successfully attached cards stay out of it.
    rest.extend(selected_cards)
    return_top_cards(
        player,
        rest,
        rest_bottom=bool(continuation.get("rest_bottom", True)),
        shuffle_rest=bool(continuation.get("shuffle_rest", False)),
    )
    return ActionResult(True, f"附着了{attached}张能量。")


def resolve_look_top_attach_energy(stack, req, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    take = int(continuation.get("take", 99) or 99)
    selected_positions = selected_top_positions_from_request(
        req,
        continuation,
        choice,
        take,
        deck_size=len(player.deck),
    )
    targets = [
        (slot, pokemon)
        for slot, pokemon in player.get_all_pokemon()
        if pokemon is not None
    ]
    if selected_positions and len(targets) > 1:
        return ActionRequest(
            request_type="search_deck",
            player=player_idx,
            prompt=f"选择1只宝可梦附着{len(selected_positions)}张能量。",
            min_select=1,
            max_select=1,
            from_zone="board",
            target_player="self",
            card_list=[pokemon.card for _slot, pokemon in targets],
            continuation={
                "kind": "look_top_attach_target",
                "player_idx": player_idx,
                "top_card_ids": list(continuation.get("top_card_ids", []) or []),
                "selected_top_positions": selected_positions,
            },
        )

    top_cards, error = pop_expected_top_cards(player, continuation)
    if error:
        return ActionResult(False, error)
    selected_cards, rest = partition_top_cards(top_cards, selected_positions)
    if not selected_cards:
        return_top_cards(player, rest, rest_bottom=False, shuffle_rest=True)
        stack.state._log(f"{player.name}查看了牌库顶{len(top_cards)}张卡，没有选择能量。")
        return ActionResult(True, "未选择能量。")
    if not targets:
        return_top_cards(player, top_cards, rest_bottom=False, shuffle_rest=True)
        return ActionResult(True, "没有宝可梦可附着能量。")
    target = targets[0][1]
    for card in selected_cards:
        target.energy_cards.append(card)
    return_top_cards(player, rest, rest_bottom=False, shuffle_rest=True)
    stack.state._log(f"将{len(selected_cards)}张能量附着于{target.card.name}。")
    return ActionResult(True, f"附着了{len(selected_cards)}张能量。")


def resolve_look_top_attach_target(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    _slot_name, target = resolve_board_choice(stack.state, player_idx, choice)
    if target is None:
        return ActionResult(False, "没有有效附着目标。")

    top_cards, error = pop_expected_top_cards(player, continuation)
    if error:
        return ActionResult(False, error)
    selected_positions = [
        int(index)
        for index in continuation.get("selected_top_positions", []) or []
    ]
    selected_cards, rest = partition_top_cards(top_cards, selected_positions)
    for card in selected_cards:
        target.energy_cards.append(card)
    return_top_cards(player, rest, rest_bottom=False, shuffle_rest=True)
    stack.state._log(f"将{len(selected_cards)}张能量附着于{target.card.name}。")
    return ActionResult(True, f"附着了{len(selected_cards)}张能量。")


def _emit_zone_event(state, event_type: str, **data) -> None:
    from engine.events.game_events import GameEvent

    state.event_stream.push(GameEvent(event_type, data))


def resolve_search_any_and_switch(stack, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    count = int(continuation.get("count", 2) or 2)
    player = stack.state.get_player(player_idx)
    selected = take_selected_cards_from_zone(player, "deck", choice, count)
    for card in selected:
        player.hand.append(card)
    player.shuffle_deck()
    stack.state._log(f"{player.name}从牌库选择了{len(selected)}张卡。")
    if not bool(continuation.get("switch_optional", True)):
        return ActionResult(True, f"选择了{len(selected)}张卡。")
    bench_indices = [
        index
        for index, pokemon in enumerate(player.bench)
        if pokemon is not None
    ]
    if not bench_indices:
        return ActionResult(True, f"选择了{len(selected)}张卡。")
    return ActionRequest(
        request_type="confirm",
        player=player_idx,
        prompt="是否替换战斗宝可梦？",
        continuation={
            "kind": "search_any_switch_confirm",
            "player_idx": player_idx,
            "bench_indices": bench_indices,
        },
    )


def resolve_search_any_switch_confirm(stack, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    if not bool(choice):
        return ActionResult(True, "未替换宝可梦。")
    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    bench_indices = []
    for index in continuation.get("bench_indices", []) or []:
        try:
            bench_idx = int(index)
        except (TypeError, ValueError):
            continue
        if 0 <= bench_idx < len(player.bench) and player.bench[bench_idx] is not None:
            bench_indices.append(bench_idx)
    if not bench_indices:
        return ActionResult(True, "没有备战宝可梦可替换。")
    if len(bench_indices) == 1:
        player.switch_active_to_bench(bench_indices[0])
        return ActionResult(True, "替换了战斗宝可梦。")
    return ActionRequest(
        request_type="select_bench",
        player=player_idx,
        prompt="选择替换战斗区的宝可梦。",
        min_select=1,
        max_select=1,
        bench_indices=bench_indices,
        continuation={
            "kind": "search_any_switch_bench",
            "player_idx": player_idx,
            "bench_indices": bench_indices,
        },
    )


def resolve_search_any_switch_bench(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    try:
        bench_idx = int(choice)
    except (TypeError, ValueError):
        return ActionResult(False, "没有选择有效的备战宝可梦。")
    allowed = {
        int(index)
        for index in continuation.get("bench_indices", []) or []
    }
    if allowed and bench_idx not in allowed:
        return ActionResult(False, "选择的备战宝可梦不在可用范围内。")
    player = stack.state.get_player(player_idx)
    if bench_idx < 0 or bench_idx >= len(player.bench) or player.bench[bench_idx] is None:
        return ActionResult(False, "选择的备战宝可梦已不存在。")
    player.switch_active_to_bench(bench_idx)
    return ActionResult(True, "替换了战斗宝可梦。")

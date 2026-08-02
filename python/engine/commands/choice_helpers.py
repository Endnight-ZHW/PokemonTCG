"""Shared helpers for pending-choice resolution."""
from __future__ import annotations


def selected_top_positions_from_request(
    req,
    continuation: dict,
    choice,
    limit: int,
    *,
    deck_size: int,
) -> list[int]:
    display_positions = [
        int(index)
        for index in continuation.get("display_top_positions", []) or []
    ]
    selected_items = list(choice or [])[: max(0, int(limit or 0))]
    if selected_items and all(
        getattr(item, "zone", "") == "deck"
        and type(getattr(item, "index", None)) is int
        for item in selected_items
    ):
        selected_positions = []
        for item in selected_items:
            top_position = int(deck_size) - 1 - int(item.index)
            if top_position in display_positions:
                selected_positions.append(top_position)
        return selected_positions
    request_indices = selected_card_indices_from_request(
        list(getattr(req, "card_list", []) or []),
        selected_items,
        limit,
    )
    selected_positions = []
    for request_index in request_indices:
        if 0 <= request_index < len(display_positions):
            selected_positions.append(display_positions[request_index])
    return selected_positions


def selected_card_indices_from_request(
    available: list,
    choice,
    limit: int,
) -> list[int]:
    selected_items = list(choice or [])[: max(0, int(limit or 0))]
    used: set[int] = set()
    indices = []
    for selected in selected_items:
        matched = -1
        for index, candidate in enumerate(available):
            if index in used:
                continue
            if candidate is selected:
                matched = index
                break
        if matched < 0:
            selected_id = getattr(selected, "api_id", "")
            if selected_id:
                for index, candidate in enumerate(available):
                    if index in used:
                        continue
                    if getattr(candidate, "api_id", "") == selected_id:
                        matched = index
                        break
        if matched >= 0:
            used.add(matched)
            indices.append(matched)
    return indices


def peek_expected_top_cards(player, continuation: dict):
    expected_ids = [
        str(card_id)
        for card_id in continuation.get("top_card_ids", []) or []
    ]
    count = len(expected_ids) or int(continuation.get("count", 0) or 0)
    if len(player.deck) < count:
        return [], "牌库顶卡已变化，无法继续结算。"
    top_cards = [player.deck[-1 - index] for index in range(count)]
    if expected_ids and [
        getattr(card, "api_id", "")
        for card in top_cards
    ] != expected_ids:
        return [], "牌库顶卡已变化，无法继续结算。"
    return top_cards, ""


def pop_expected_top_cards(player, continuation: dict):
    top_cards, error = peek_expected_top_cards(player, continuation)
    if error:
        return [], error
    for _card in top_cards:
        player.deck.pop()
    return top_cards, ""


def return_top_cards_except_selected(
    player,
    top_cards: list,
    selected_positions: list[int],
    *,
    rest_bottom: bool,
    shuffle_rest: bool,
) -> list:
    selected_cards, rest = partition_top_cards(top_cards, selected_positions)
    return_top_cards(
        player,
        rest,
        rest_bottom=rest_bottom,
        shuffle_rest=shuffle_rest,
    )
    return selected_cards


def partition_top_cards(top_cards: list, selected_positions: list[int]):
    from collections import Counter

    selected_counter = Counter(int(index) for index in selected_positions)
    selected_cards = []
    rest = []
    for index, card in enumerate(top_cards):
        if selected_counter.get(index, 0) > 0:
            selected_counter[index] -= 1
            selected_cards.append(card)
        else:
            rest.append(card)
    return selected_cards, rest


def return_top_cards(
    player,
    rest: list,
    *,
    rest_bottom: bool,
    shuffle_rest: bool,
) -> None:
    if shuffle_rest:
        player.deck.extend(rest)
        player.shuffle_deck()
    elif rest_bottom:
        for card in rest:
            player.deck.insert(0, card)
    else:
        # ``rest`` is ordered from the former top down. Append in the opposite
        # order to preserve the original top order.
        player.deck.extend(reversed(rest))


def attach_lightning_energy_to_bench(state, player_idx: int, selected_cards: list):
    from engine.game_state import ActionResult

    player = state.get_player(player_idx)
    if not selected_cards:
        return ActionResult(True, "未选择能量。")
    bench_pokes = [
        (index, pokemon)
        for index, pokemon in enumerate(player.bench)
        if pokemon is not None
        and getattr(pokemon.card, "energy_types", None)
        and "Lightning" in pokemon.card.energy_types
    ]
    if not bench_pokes:
        player.deck.extend(selected_cards)
        player.shuffle_deck()
        state._log("备战区没有雷属性宝可梦可附着能量。")
        return ActionResult(True, "备战区没有雷属性宝可梦可附着能量。")
    _index, bench_pokemon = bench_pokes[0]
    for card in selected_cards:
        bench_pokemon.energy_cards.append(card)
    state._log(f"将{len(selected_cards)}张能量附着于备战区{bench_pokemon.card.name}。")
    return ActionResult(True, f"附着了{len(selected_cards)}张能量。")


def take_selected_cards_from_zone(player, zone_name: str, choice, limit: int) -> list:
    taken = []
    for selected in list(choice or [])[: max(0, int(limit or 0))]:
        card = take_one_selected_card_from_zone(player, zone_name, selected)
        if card is not None:
            taken.append(card)
    return taken


def take_one_selected_card_from_zone(player, zone_name: str, selected):
    card = find_selected_card_in_zone(player, zone_name, selected)
    if card is None:
        return None
    getattr(player, zone_name).remove(card)
    return card


def find_selected_card_in_zone(player, zone_name: str, selected):
    zone = getattr(player, zone_name, None)
    if not isinstance(zone, list):
        return None
    if selected in zone:
        return selected
    selected_id = getattr(selected, "api_id", "")
    if not selected_id:
        return None
    for card in zone:
        if getattr(card, "api_id", "") == selected_id:
            return card
    return None


def resolve_board_choice(state, player_idx: int, choice):
    from engine.actions import PokemonRef, resolve_pokemon_ref

    player = state.get_player(player_idx)
    for item in list(choice or []):
        if isinstance(item, PokemonRef):
            pokemon = resolve_pokemon_ref(state, item)
            if pokemon is not None and item.player == player_idx:
                return item.slot, pokemon
            continue
        selected_id = getattr(item, "api_id", "")
        if not selected_id:
            continue
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon is None:
                continue
            if getattr(pokemon.card, "api_id", "") == selected_id:
                return slot_name, pokemon
    return "", None

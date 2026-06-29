"""Discard recovery pending-choice continuation handlers."""
from __future__ import annotations

from engine.commands.choice_helpers import (
    find_selected_card_in_zone,
    take_selected_cards_from_zone,
)


def register_recovery_continuations(registry, stack) -> None:
    registry.register(
        "recover_from_discard_to_deck",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_recover_from_discard_to_deck(stack, cont, choice),
    )
    registry.register(
        "recover_clara",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_recover_clara(stack, cont, choice),
    )


def resolve_recover_from_discard_to_deck(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    count = int(continuation.get("count", 0) or 0)
    player = stack.state.get_player(player_idx)
    selected = take_selected_cards_from_zone(player, "discard", choice, count)
    if not selected:
        stack.state._log(f"{player.name}没有从弃牌区选择卡牌。")
        return ActionResult(True, "没有选择卡牌。")
    player.deck.extend(selected)
    player.shuffle_deck()
    stack.state._log(f"{player.name}将{len(selected)}张卡从弃牌区洗回牌库。")
    return ActionResult(True, f"将{len(selected)}张卡洗回牌库。")


def resolve_recover_clara(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    pokemon_limit = int(continuation.get("pokemon_count", 0) or 0)
    energy_limit = int(continuation.get("energy_count", 0) or 0)
    player = stack.state.get_player(player_idx)
    selected = list(choice or [])
    pokemon_taken = 0
    energy_taken = 0
    for card in selected:
        candidate = find_selected_card_in_zone(
            player,
            "discard",
            card,
        )
        if candidate is None:
            continue
        if getattr(candidate, "is_pokemon", False) and pokemon_taken < pokemon_limit:
            player.discard.remove(candidate)
            player.hand.append(candidate)
            pokemon_taken += 1
            continue
        if getattr(candidate, "is_basic_energy", False) and energy_taken < energy_limit:
            player.discard.remove(candidate)
            player.hand.append(candidate)
            energy_taken += 1
            continue
    stack.state._log(
        f"{player.name}从弃牌区回收了{pokemon_taken}只宝可梦和{energy_taken}张基本能量。"
    )
    return ActionResult(
        True,
        f"回收了{pokemon_taken}只宝可梦和{energy_taken}张基本能量。",
    )

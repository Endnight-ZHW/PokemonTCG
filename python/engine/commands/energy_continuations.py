"""Energy pending-choice continuation handlers for ResolutionStack."""
from __future__ import annotations

from engine.commands.choice_helpers import resolve_board_choice


def register_energy_continuations(registry, stack) -> None:
    registry.register(
        "draw_and_attach_energy_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_draw_and_attach_energy_distribution(stack, req, cont, choice),
    )
    registry.register(
        "energy_attach_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_attach_energy_distribution(stack, req, cont, choice),
    )
    registry.register(
        "attach_energy_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_attach_energy_distribution(stack, req, cont, choice),
    )
    registry.register(
        "attach_energy_to_bench",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_attach_energy_to_bench(stack, cont, choice),
    )
    registry.register(
        "attach_energy_to_board",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_attach_energy_to_board(stack, cont, choice),
    )
    registry.register(
        "attach_discard_energy_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_attach_discard_energy_distribution(stack, req, cont, choice),
    )
    registry.register(
        "attach_discard_energy_to_bench",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_attach_discard_energy_to_bench(stack, cont, choice),
    )
    registry.register(
        "attach_discard_energy_to_board",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_attach_discard_energy_to_board(stack, cont, choice),
    )
    registry.register(
        "energy_relocate_source",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_energy_relocate_source(stack, cont, choice),
    )
    registry.register(
        "energy_relocate_distribution",
        lambda req, cont, choice, _player_idx, _slot:
            resolve_energy_relocate_distribution(stack, req, cont, choice),
    )


def resolve_draw_and_attach_energy_distribution(stack, req, continuation: dict, choice):
    return _resolve_energy_distribution(
        stack,
        player_idx=int(continuation.get("player_idx", 0) or 0),
        source_zone="hand",
        source_cards=list(getattr(req, "card_list", []) or []),
        choice=choice,
        max_per_target=int(continuation.get("max_per_target", 99) or 99),
        same_target=bool(continuation.get("same_target", True)),
        zone_name="手牌",
    )


def resolve_attach_energy_distribution(stack, req, continuation: dict, choice):
    source_zone = str(continuation.get("source_zone", "hand") or "hand")
    zone_name = str(
        continuation.get("zone_name", "")
        or ("手牌" if source_zone == "hand" else "牌库")
    )
    return _resolve_energy_distribution(
        stack,
        player_idx=int(continuation.get("player_idx", 0) or 0),
        source_zone=source_zone,
        source_cards=list(getattr(req, "card_list", []) or []),
        choice=choice,
        max_per_target=int(continuation.get("max_per_target", 99) or 99),
        same_target=bool(continuation.get("same_target", False)),
        zone_name=zone_name,
    )


def resolve_attach_energy_to_bench(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    if choice is None:
        return ActionResult(True, "未选择附能目标。")
    try:
        bench_idx = int(choice)
    except (TypeError, ValueError):
        return ActionResult(False, "没有有效附能目标。")

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    target = player.get_pokemon(f"bench_{bench_idx}")
    return _attach_energy_to_target(
        stack,
        player_idx=player_idx,
        source_zone=str(continuation.get("source_zone", "hand") or "hand"),
        zone_name=str(continuation.get("zone_name", "") or "手牌"),
        filter_type=str(continuation.get("filter_type", "any") or "any"),
        amount=int(continuation.get("amount", 1) or 1),
        target=target,
        optional=bool(continuation.get("optional", False)),
    )


def resolve_attach_energy_to_board(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    _slot_name, target = resolve_board_choice(stack.state, player_idx, choice)
    if target is None:
        return ActionResult(False, "没有有效附能目标。")
    return _attach_energy_to_target(
        stack,
        player_idx=player_idx,
        source_zone=str(continuation.get("source_zone", "hand") or "hand"),
        zone_name=str(continuation.get("zone_name", "") or "手牌"),
        filter_type=str(continuation.get("filter_type", "any") or "any"),
        amount=int(continuation.get("amount", 1) or 1),
        target=target,
        optional=bool(continuation.get("optional", False)),
    )


def resolve_attach_discard_energy_distribution(stack, req, continuation: dict, choice):
    return _resolve_energy_distribution(
        stack,
        player_idx=int(continuation.get("player_idx", 0) or 0),
        source_zone="discard",
        source_cards=list(getattr(req, "card_list", []) or []),
        choice=choice,
        max_per_target=int(continuation.get("max_per_target", 99) or 99),
        same_target=bool(continuation.get("same_target", False)),
        zone_name="弃牌区",
    )


def resolve_attach_discard_energy_to_bench(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    if choice is None:
        return ActionResult(True, "未选择附能目标。")
    try:
        bench_idx = int(choice)
    except (TypeError, ValueError):
        return ActionResult(True, "未选择有效目标。")

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    target = player.get_pokemon(f"bench_{bench_idx}")
    if target is None:
        return ActionResult(True, "未选择有效目标。")
    return _attach_discard_energy_to_target(
        stack,
        player_idx=player_idx,
        count=int(continuation.get("count", 1) or 1),
        target=target,
        energy_type=str(continuation.get("energy_type", "any") or "any"),
    )


def resolve_attach_discard_energy_to_board(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    _slot_name, target = resolve_board_choice(stack.state, player_idx, choice)
    if target is None:
        return ActionResult(False, "没有有效附能目标。")
    return _attach_discard_energy_to_target(
        stack,
        player_idx=player_idx,
        count=int(continuation.get("count", 1) or 1),
        target=target,
        energy_type=str(continuation.get("energy_type", "any") or "any"),
    )


def resolve_energy_relocate_source(stack, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    assignments = normalize_energy_assignments(choice)
    if not assignments:
        return ActionResult(True, "未选择来源宝可梦。")
    _energy_index, source_slot = assignments[0]
    source = player.get_pokemon(source_slot)
    energy_type = str(continuation.get("energy_type", "any") or "any")
    matching_source = (
        [
            card
            for card in source.energy_cards
            if _energy_card_matches(card, energy_type)
        ]
        if source is not None else []
    )
    if source is None or not matching_source:
        return ActionResult(True, "来源宝可梦没有可转附能量。")

    amount = int(continuation.get("amount", 1) or 1)
    move_count = min(amount, len(matching_source))
    optional_count = bool(continuation.get("optional_count", False))
    raw_min_select = continuation.get("min_select", None)
    if raw_min_select is None:
        min_move = 0 if optional_count else move_count
    else:
        min_move = int(raw_min_select or 0)
    min_move = min(move_count, max(0, min_move))
    targets_info = []
    for slot_name, pokemon in player.get_all_pokemon():
        if pokemon is not None and pokemon is not source:
            targets_info.append({
                "slot": slot_name,
                "name": pokemon.card.name,
                "bench_idx": int(slot_name.split("_")[1]) if slot_name.startswith("bench_") else -1,
            })
    if not targets_info:
        return ActionResult(True, "没有目标宝可梦可转附能量。")
    return ActionRequest(
        request_type="distribute_energy",
        player=player_idx,
        prompt=f"分配能量 — {source.card.name}",
        card_list=list(matching_source[:move_count]),
        target_info=targets_info,
        distribute_mode="paired",
        min_select=min_move,
        max_select=move_count,
        max_per_target=move_count,
        source_name=source.card.name,
        continuation={
            "kind": "energy_relocate_distribution",
            "player_idx": player_idx,
            "source_slot": source_slot,
            "max_per_target": move_count,
            "same_target": bool(continuation.get("same_target", False)),
        },
    )


def resolve_energy_relocate_distribution(stack, req, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    source_slot = str(continuation.get("source_slot", "") or "")
    source = player.get_pokemon(source_slot)
    if source is None:
        return ActionResult(False, "来源宝可梦已不存在。")
    source_cards = list(getattr(req, "card_list", []) or [])
    assignments = normalize_energy_assignments(choice)
    forced_slot = assignments[0][1] if bool(continuation.get("same_target", False)) and assignments else ""
    moved = 0
    for energy_index, target_slot in assignments:
        if energy_index < 0 or energy_index >= len(source_cards):
            continue
        card = resolve_source_card(source.energy_cards, source_cards[energy_index])
        if card is None:
            continue
        target = player.get_pokemon(forced_slot or target_slot)
        if target is None:
            continue
        source.energy_cards.remove(card)
        target.energy_cards.append(card)
        moved += 1
    stack.state._log(f"将{moved}个能量从{source.card.name}转附。")
    return ActionResult(True, f"转附了{moved}个能量。")


def _resolve_energy_distribution(
    stack,
    *,
    player_idx: int,
    source_zone: str,
    source_cards: list,
    choice,
    max_per_target: int,
    same_target: bool,
    zone_name: str,
):
    from engine.game_state import ActionResult

    player = stack.state.get_player(player_idx)
    source_pool = _energy_source_pool(player, source_zone)
    assignments = normalize_energy_assignments(choice)
    forced_slot = assignments[0][1] if same_target and assignments else ""
    attached_count = 0
    per_target: dict[str, int] = {}
    trigger_specs = []

    for energy_index, target_slot in assignments:
        if energy_index < 0 or energy_index >= len(source_cards):
            continue
        final_slot = forced_slot or target_slot
        if not final_slot or per_target.get(final_slot, 0) >= max_per_target:
            continue
        target = player.get_pokemon(final_slot)
        if target is None:
            continue
        card = resolve_source_card(source_pool, source_cards[energy_index])
        if card is None:
            continue
        source_pool.remove(card)
        target.energy_cards.append(card)
        per_target[final_slot] = per_target.get(final_slot, 0) + 1
        attached_count += 1
        from engine.commands.trigger_commands import collect_on_attach_command_specs

        trigger_specs.extend(
            collect_on_attach_command_specs(
                card,
                player_idx,
                final_slot,
                source_zone,
            )
        )

    if source_zone != "hand" and source_zone != "discard":
        player.shuffle_deck()
    stack.state._log(f"从{zone_name}附着了{attached_count}个能量。")
    if trigger_specs:
        from engine.commands.trigger_commands import push_trigger_command_specs

        push_trigger_command_specs(stack, trigger_specs)
    return ActionResult(True, f"附着了{attached_count}个能量。")


def _attach_energy_to_target(
    stack,
    *,
    player_idx: int,
    source_zone: str,
    zone_name: str,
    filter_type: str,
    amount: int,
    target,
    optional: bool,
):
    from engine.game_state import ActionResult

    if target is None:
        return (
            ActionResult(True, "无目标宝可梦。")
            if optional
            else ActionResult(False, "没有目标宝可梦。")
        )
    player = stack.state.get_player(player_idx)
    source_pool = _energy_source_pool(player, source_zone)
    matching = [
        card
        for card in source_pool
        if _energy_card_matches(card, filter_type)
    ]
    if not matching and optional:
        return ActionResult(True, f"{zone_name}中无匹配的能量。")

    attached = 0
    trigger_specs = []
    for card in list(matching[: min(amount, len(matching))]):
        if card in source_pool:
            source_pool.remove(card)
            target.energy_cards.append(card)
            attached += 1
            target_slot = _slot_for_pokemon(player, target)
            if target_slot:
                from engine.commands.trigger_commands import collect_on_attach_command_specs

                trigger_specs.extend(
                    collect_on_attach_command_specs(
                        card,
                        player_idx,
                        target_slot,
                        source_zone,
                    )
                )
    if source_zone != "hand" and source_zone != "discard":
        player.shuffle_deck()
    stack.state._log(f"从{zone_name}向{target.card.name}附着了{attached}个能量。")
    if trigger_specs:
        from engine.commands.trigger_commands import push_trigger_command_specs

        push_trigger_command_specs(stack, trigger_specs)
    return ActionResult(True, f"Attached {attached} energy from {source_zone}.")


def _attach_discard_energy_to_target(
    stack,
    *,
    player_idx: int,
    count: int,
    target,
    energy_type: str,
):
    from engine.game_state import ActionResult

    player = stack.state.get_player(player_idx)
    matching = _matching_discard_energy(player.discard, energy_type)
    attached = 0
    for card in list(matching[:count]):
        if card in player.discard:
            player.discard.remove(card)
            target.energy_cards.append(card)
            attached += 1
    stack.state._log(f"从弃牌区将{attached}个{energy_type}能量附着于{target.card.name}。")
    return ActionResult(True, f"从弃牌区附着了{attached}个能量。")


def _energy_source_pool(player, source_zone: str):
    if source_zone == "hand":
        return player.hand
    if source_zone == "discard":
        return player.discard
    return player.deck


def _slot_for_pokemon(player, target_pokemon) -> str:
    for slot_name, pokemon in player.get_all_pokemon():
        if pokemon is target_pokemon:
            return slot_name
    return ""


def normalize_energy_assignments(choice) -> list[tuple[int, str]]:
    assignments: list[tuple[int, str]] = []
    for fallback_index, item in enumerate(list(choice or [])):
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            try:
                energy_index = int(item[0])
            except (TypeError, ValueError):
                continue
            assignments.append((energy_index, str(item[1] or "")))
            continue
        slot = str(getattr(item, "slot", "") or "")
        if not slot and isinstance(item, dict):
            slot = str(item.get("slot", "") or "")
        if slot:
            assignments.append((fallback_index, slot))
    return assignments


def resolve_source_card(source_pool: list, selected):
    if selected in source_pool:
        return selected
    selected_id = getattr(selected, "api_id", "")
    if not selected_id:
        return None
    for card in source_pool:
        if getattr(card, "api_id", "") == selected_id:
            return card
    return None


def _energy_card_matches(card, energy_type: str) -> bool:
    normalized = str(energy_type or "any").lower()
    if not getattr(card, "is_energy", False):
        return False
    if normalized in {"any", "energy"}:
        return True
    if normalized in {"basic", "basic_energy"}:
        return bool(getattr(card, "is_basic_energy", False))
    return any(
        str(provided).lower() == normalized
        for provided in getattr(card, "provides_energy", [])
    )


def _matching_discard_energy(discard: list, energy_type: str) -> list:
    normalized = str(energy_type or "any").lower()
    return [
        card
        for card in discard
        if getattr(card, "is_basic_energy", False)
        and (
            normalized in {"any", "basic", "basic_energy"}
            or any(
                str(provided).lower() == normalized
                for provided in getattr(card, "provides_energy", [])
            )
        )
    ]

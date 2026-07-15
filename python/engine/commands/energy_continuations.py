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
        "discard_energy_attachments",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_discard_energy_attachments(stack, cont, choice),
    )
    registry.register(
        "energy_relocate_source",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_energy_relocate_source(stack, cont, choice),
    )
    registry.register(
        "energy_relocate_attachments",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_energy_relocate_attachments(stack, cont, choice),
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


def resolve_discard_energy_attachments(stack, continuation: dict, choice):
    from engine.actions import AttachmentRef
    from engine.game_state import ActionResult
    from engine.commands.primitives_board import discard_energy_attachment_refs

    refs = [ref for ref in list(choice or []) if isinstance(ref, AttachmentRef)]
    expected = int(continuation.get("amount", 0) or 0)
    if len(refs) != expected:
        return ActionResult(False, "选择的能量数量无效。")
    success, message, discarded = discard_energy_attachment_refs(
        stack.state,
        actor_idx=int(continuation.get("player_idx", 0) or 0),
        owner_idx=int(continuation.get("owner_idx", -1)),
        source_slot=str(continuation.get("source_slot", "") or ""),
        refs=refs,
    )
    if not success:
        return ActionResult(False, message)
    return ActionResult(
        True,
        f"丢弃了{discarded}张能量。",
        cards_discarded=discarded,
    )


def resolve_energy_relocate_source(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    assignments = normalize_energy_assignments(choice)
    if not assignments:
        return ActionResult(True, "未选择来源宝可梦。")
    _energy_index, source_slot = assignments[0]
    request = _energy_relocation_attachment_or_target_request(
        stack,
        player_idx=player_idx,
        source_slot=source_slot,
        amount=int(continuation.get("amount", 1) or 1),
        energy_type=str(continuation.get("energy_type", "any") or "any"),
        optional_count=bool(continuation.get("optional_count", False)),
        min_select=continuation.get("min_select", None),
        same_target=bool(continuation.get("same_target", False)),
    )
    return request if request is not None else ActionResult(True, "没有可转附的能量。")


def resolve_energy_relocate_attachments(stack, continuation: dict, choice):
    from engine.actions import AttachmentRef
    from engine.game_state import ActionResult

    refs = [ref for ref in list(choice or []) if isinstance(ref, AttachmentRef)]
    if not refs:
        return ActionResult(True, "未选择要转附的能量。")
    player_idx = int(continuation.get("player_idx", 0) or 0)
    source_slot = str(continuation.get("source_slot", "") or "")
    source = stack.state.get_player(player_idx).get_pokemon(source_slot)
    valid, message, cards = _validate_relocation_refs(
        source,
        refs,
        player_idx=player_idx,
        source_slot=source_slot,
        energy_type=str(continuation.get("energy_type", "any") or "any"),
    )
    if not valid:
        return ActionResult(False, message)
    return _energy_relocation_target_request(
        stack,
        player_idx=player_idx,
        source_slot=source_slot,
        source=source,
        cards=cards,
        refs=refs,
        same_target=bool(continuation.get("same_target", False)),
    )


def resolve_energy_relocate_distribution(stack, req, continuation: dict, choice):
    from engine.actions import AttachmentRef
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    player = stack.state.get_player(player_idx)
    source_slot = str(continuation.get("source_slot", "") or "")
    source = player.get_pokemon(source_slot)
    if source is None:
        return ActionResult(False, "来源宝可梦已不存在。")
    raw_refs = list(continuation.get("attachment_refs", []) or [])
    refs = [
        AttachmentRef(
            ref.get("player", -1),
            str(ref.get("slot", "") or ""),
            str(ref.get("attachment_type", "") or ""),
            ref.get("index", -1),
            str(ref.get("card_id", "") or ""),
        )
        for ref in raw_refs
        if isinstance(ref, dict)
    ]
    if not raw_refs or len(refs) != len(raw_refs):
        return ActionResult(False, "能量引用无效。")
    valid, message, cards = _validate_relocation_refs(
        source,
        refs,
        player_idx=player_idx,
        source_slot=source_slot,
        energy_type="any",
    )
    if not valid:
        return ActionResult(False, message)
    assignments = normalize_relocation_target_assignments(req, choice)
    if len(assignments) != len(refs):
        return ActionResult(False, "能量转移数量无效。")
    forced_slot = (
        str(assignments[0][1].get("slot", "") or "")
        if bool(continuation.get("same_target", False)) and assignments
        else ""
    )
    plan = []
    max_per_target = int(continuation.get("max_per_target", len(refs)) or 0)
    per_target = {}
    for ordinal, (energy_index, target_ref) in enumerate(assignments):
        if energy_index != ordinal or energy_index < 0 or energy_index >= len(refs):
            return ActionResult(False, "能量转移顺序无效。")
        selected_target_slot = str(target_ref.get("slot", "") or "")
        target_slot = forced_slot or selected_target_slot
        if forced_slot and selected_target_slot != forced_slot:
            return ActionResult(False, "转附的能量必须选择同一目标。")
        final_slot = target_slot
        target = player.get_pokemon(final_slot)
        target_player = target_ref.get("player", player_idx)
        target_card_id = target_ref.get(
            "card_id",
            getattr(getattr(target, "card", None), "api_id", ""),
        )
        if (
            target is None
            or final_slot == source_slot
            or type(target_player) is not int
            or target_player != player_idx
            or not isinstance(target_card_id, str)
            or target_card_id != getattr(target.card, "api_id", "")
        ):
            return ActionResult(False, "能量转移目标已失效。")
        per_target[final_slot] = per_target.get(final_slot, 0) + 1
        if per_target[final_slot] > max_per_target:
            return ActionResult(False, "能量转移目标超出上限。")
        plan.append((refs[ordinal], cards[ordinal], target))

    # Validate the complete plan before the first mutation, then preserve
    # original indices by detaching from highest to lowest.
    for ref, _card, _target in sorted(plan, key=lambda row: row[0].index, reverse=True):
        source.energy_cards.pop(ref.index)
    for _ref, card, target in plan:
        target.energy_cards.append(card)
    moved = len(plan)
    stack.state._log(f"将{moved}个能量从{source.card.name}转附。")
    return ActionResult(True, f"转附了{moved}个能量。")


def _energy_relocation_attachment_or_target_request(
    stack,
    *,
    player_idx: int,
    source_slot: str,
    amount: int,
    energy_type: str,
    optional_count: bool,
    min_select,
    same_target: bool,
):
    from engine.actions import AttachmentRef
    from engine.game_state import ActionRequest

    player = stack.state.get_player(player_idx)
    source = player.get_pokemon(source_slot)
    if source is None:
        return None
    matching = [
        (index, card)
        for index, card in enumerate(source.energy_cards)
        if _energy_card_matches(card, energy_type)
    ]
    move_count = min(max(0, int(amount)), len(matching))
    if move_count <= 0:
        return None
    if min_select is None:
        request_min = 0 if optional_count else move_count
    else:
        request_min = min(move_count, max(0, int(min_select or 0)))
    refs = [
        AttachmentRef(
            player_idx,
            source_slot,
            "energy",
            index,
            str(getattr(card, "api_id", "") or ""),
        )
        for index, card in matching
    ]
    exact_choice_required = request_min < move_count or len(refs) > move_count
    if exact_choice_required:
        return ActionRequest(
            request_type="select_attachment",
            player=player_idx,
            prompt=f"选择从{source.card.name}转附的能量。",
            min_select=request_min,
            max_select=move_count,
            can_cancel=request_min <= 0,
            target_info=[
                {
                    "player": ref.player,
                    "slot": ref.slot,
                    "attachment_type": ref.attachment_type,
                    "index": ref.index,
                    "card_id": ref.card_id,
                    "label": f"{source.card.name} - {getattr(card, 'name', ref.card_id)}",
                }
                for ref, (_index, card) in zip(refs, matching)
            ],
            continuation={
                "kind": "energy_relocate_attachments",
                "purpose": "relocate_energy",
                "player_idx": player_idx,
                "source_player": player_idx,
                "source_zone": "field",
                "source_slot": source_slot,
                "amount": move_count,
                "energy_type": energy_type,
                "same_source": True,
                "same_target": same_target,
                "max_per_target": move_count,
            },
        )
    return _energy_relocation_target_request(
        stack,
        player_idx=player_idx,
        source_slot=source_slot,
        source=source,
        cards=[card for _index, card in matching[:move_count]],
        refs=refs[:move_count],
        same_target=same_target,
    )


def _energy_relocation_target_request(
    stack,
    *,
    player_idx: int,
    source_slot: str,
    source,
    cards,
    refs,
    same_target: bool,
):
    from engine.game_state import ActionRequest, ActionResult

    targets_info = [
        {
            "player": player_idx,
            "slot": slot_name,
            "name": pokemon.card.name,
            "card_id": pokemon.card.api_id,
            "bench_idx": int(slot_name.split("_", 1)[1]) if slot_name.startswith("bench_") else -1,
        }
        for slot_name, pokemon in stack.state.get_player(player_idx).get_all_pokemon()
        if pokemon is not None and slot_name != source_slot
    ]
    if not targets_info:
        return ActionResult(True, "没有目标宝可梦可转附能量。")
    serialized_refs = [
        {
            "kind": "attachment",
            "player": ref.player,
            "zone": "field",
            "slot": ref.slot,
            "index": ref.index,
            "attachment_type": ref.attachment_type,
            "card_id": ref.card_id,
        }
        for ref in refs
    ]
    return ActionRequest(
        request_type="distribute_energy",
        player=player_idx,
        prompt=f"分配能量 — {source.card.name}",
        card_list=list(cards),
        target_info=targets_info,
        distribute_mode="paired",
        min_select=len(refs),
        max_select=len(refs),
        max_per_target=len(refs),
        source_name=source.card.name,
        continuation={
            "kind": "energy_relocate_distribution",
            "purpose": "relocate_energy_target",
            "player_idx": player_idx,
            "source_player": player_idx,
            "source_zone": "field",
            "source_slot": source_slot,
            "attachment_refs": serialized_refs,
            "card_ids": [ref.card_id for ref in refs],
            "same_source": True,
            "same_target": same_target,
            "max_per_target": len(refs),
        },
    )


def _validate_relocation_refs(
    source,
    refs,
    *,
    player_idx: int,
    source_slot: str,
    energy_type: str,
):
    if source is None:
        return False, "来源宝可梦已不存在。", []
    cards = []
    seen_indices = set()
    for ref in refs:
        if (
            type(ref.player) is not int
            or ref.player != player_idx
            or ref.slot != source_slot
            or ref.attachment_type != "energy"
            or type(ref.index) is not int
            or ref.index < 0
            or ref.index >= len(source.energy_cards)
            or ref.index in seen_indices
            or getattr(source.energy_cards[ref.index], "api_id", "") != ref.card_id
            or not _energy_card_matches(source.energy_cards[ref.index], energy_type)
        ):
            return False, "选择的能量已不存在。", []
        seen_indices.add(ref.index)
        cards.append(source.energy_cards[ref.index])
    return True, "", cards


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
        if source_zone not in {"hand", "discard"}:
            player.shuffle_deck()
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


def normalize_relocation_target_assignments(req, choice) -> list[tuple[int, dict]]:
    """Preserve target identity while accepting legacy slot-only payloads."""
    from engine.actions import PokemonRef

    snapshots_by_slot = {
        str(target.get("slot", "") or ""): dict(target)
        for target in list(getattr(req, "target_info", []) or [])
        if isinstance(target, dict) and str(target.get("slot", "") or "")
    }
    assignments: list[tuple[int, dict]] = []
    for fallback_index, item in enumerate(list(choice or [])):
        energy_index = fallback_index
        target_value = item
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            try:
                energy_index = int(item[0])
            except (TypeError, ValueError):
                continue
            target_value = item[1]

        if isinstance(target_value, PokemonRef):
            target_ref = {
                "player": target_value.player,
                "slot": target_value.slot,
                "card_id": target_value.card_id,
            }
        elif isinstance(target_value, dict):
            target_ref = dict(target_value)
        else:
            slot = str(target_value or "")
            target_ref = dict(snapshots_by_slot.get(slot, {}))
            target_ref.setdefault("slot", slot)
        if str(target_ref.get("slot", "") or ""):
            assignments.append((energy_index, target_ref))
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

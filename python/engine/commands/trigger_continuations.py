"""Serializable player decisions for queued entity triggers."""
from __future__ import annotations


def register_trigger_continuations(registry, stack) -> None:
    registry.register(
        "choose_trigger_order",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_choose_trigger_order(stack, cont, choice),
    )
    registry.register(
        "confirm_exp_share_trigger",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_confirm_exp_share_trigger(stack, cont, choice),
    )
    registry.register(
        "select_exp_share_energy",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_select_exp_share_energy(stack, cont, choice),
    )


def resolve_choose_trigger_order(stack, continuation: dict, choice):
    from engine.commands.trigger_commands import (
        TriggerOrderFrame,
        _compile_trigger_command_items,
        _require_trigger_command_spec,
    )
    from engine.game_state import ActionResult

    specs = continuation.get("specs", [])
    if not isinstance(specs, list) or not specs:
        return ActionResult(False, "触发顺序队列无效。")
    selected = choice[0] if isinstance(choice, (list, tuple)) and choice else choice
    if type(selected) is not int or not (0 <= selected < len(specs)):
        return ActionResult(False, "必须选择一个有效的触发效果。")
    try:
        normalized = [_require_trigger_command_spec(dict(spec)) for spec in specs]
        chosen = _compile_trigger_command_items([normalized[selected]])[0]
    except (KeyError, TypeError, ValueError) as exc:
        return ActionResult(False, str(exc))
    remaining = normalized[:selected] + normalized[selected + 1:]
    commands = [chosen]
    if remaining:
        commands.append(TriggerOrderFrame(remaining))
    stack.push_many(commands)
    return ActionResult(True, "已选择下一个触发效果。")


def _resolve_exp_share_pokemon(state, continuation: dict):
    from_player = int(continuation.get("from_player", -1))
    to_player = int(continuation.get("to_player", -1))
    from_slot = str(continuation.get("from_slot", "") or "")
    to_slot = str(continuation.get("to_slot", "") or "")
    if from_player not in (0, 1) or to_player not in (0, 1):
        return None, None
    source = state.get_player(from_player).get_pokemon(from_slot)
    target = state.get_player(to_player).get_pokemon(to_slot)
    if source is None or target is None:
        return None, None
    if str(getattr(source.card, "api_id", "") or "") != str(
        continuation.get("from_card_id", "") or ""
    ):
        return None, None
    if str(getattr(target.card, "api_id", "") or "") != str(
        continuation.get("to_card_id", "") or ""
    ):
        return None, None
    expected_tool = str(continuation.get("target_tool_id", "") or "")
    if expected_tool and str(getattr(getattr(target, "attached_tool", None), "api_id", "") or "") != expected_tool:
        return None, None
    return source, target


def resolve_confirm_exp_share_trigger(stack, continuation: dict, choice):
    from engine.game_state import ActionRequest, ActionResult

    confirmed = bool(choice)
    if not confirmed:
        return ActionResult(True, "放弃使用学习装置。")
    source, target = _resolve_exp_share_pokemon(stack.state, continuation)
    if source is None or target is None:
        return ActionResult(False, "学习装置的来源或目标实体已失效。")

    from_player = int(continuation["from_player"])
    from_slot = str(continuation["from_slot"])
    energies = [
        (index, card)
        for index, card in enumerate(list(source.energy_cards))
        if getattr(card, "is_basic_energy", False)
    ]
    if not energies:
        return ActionResult(True, "没有可由学习装置转附的基本能量。")
    next_continuation = dict(continuation)
    next_continuation.update({
        "kind": "select_exp_share_energy",
        "frame_id": str(continuation.get("frame_id", "trigger:exp_share")) + ":energy",
    })
    return ActionRequest(
        request_type="select_attachment",
        player=int(continuation["to_player"]),
        prompt="选择要由学习装置转附的1张基本能量。",
        min_select=1,
        max_select=1,
        from_zone="field",
        target_info=[
            {
                "player": from_player,
                "slot": from_slot,
                "attachment_type": "energy",
                "index": index,
                "card_id": str(getattr(card, "api_id", "") or ""),
                "label": str(getattr(card, "name", "基本能量")),
            }
            for index, card in energies
        ],
        continuation=next_continuation,
    )


def resolve_select_exp_share_energy(stack, continuation: dict, choice):
    from engine.actions import AttachmentRef
    from engine.game_state import ActionResult

    selected = list(choice or [])
    if len(selected) != 1 or not isinstance(selected[0], AttachmentRef):
        return ActionResult(False, "必须选择1张具体的基本能量。")
    ref = selected[0]
    source, target = _resolve_exp_share_pokemon(stack.state, continuation)
    if source is None or target is None:
        return ActionResult(False, "学习装置的来源或目标实体已失效。")
    if (
        ref.player != int(continuation["from_player"])
        or ref.slot != str(continuation["from_slot"])
        or ref.attachment_type != "energy"
        or not (0 <= ref.index < len(source.energy_cards))
    ):
        return ActionResult(False, "所选能量实体已失效。")
    card = source.energy_cards[ref.index]
    if str(getattr(card, "api_id", "") or "") != ref.card_id:
        return ActionResult(False, "所选能量实体已变化。")
    if not getattr(card, "is_basic_energy", False):
        return ActionResult(False, "学习装置只能转附基本能量。")

    source.energy_cards.pop(ref.index)
    target.energy_cards.append(card)
    source_name = str(continuation.get("source_name", "学习装置") or "学习装置")
    message = f"{source_name}：将{card.name}转附给{target.card.name}。"
    stack.state._log(message)
    return ActionResult(True, message)


__all__ = [
    "register_trigger_continuations",
    "resolve_choose_trigger_order",
    "resolve_confirm_exp_share_trigger",
    "resolve_select_exp_share_energy",
]

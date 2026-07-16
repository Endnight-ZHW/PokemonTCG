"""Rebuild pending choices from the canonical serialized state payload.

The public ``ChoiceRequest`` is deliberately serializable, while the legacy
``ActionRequest`` historically carried an in-memory callback.  VM effects use
stable continuation ``kind`` + payload dictionaries, so a restored snapshot
can rebuild that callback against the restored ``GameState`` instead of
retaining a closure over the old state.
"""
from __future__ import annotations

import copy
from typing import Any

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    PokemonRef,
)
from engine.game_state import ActionRequest, GameState


class PendingContinuationError(ValueError):
    """A serialized pending continuation cannot be safely reconstructed."""

    def __init__(self, message: str, *, error_code: str = "missing_continuation"):
        super().__init__(message)
        self.error_code = error_code


def validate_resume_required_domain(metadata: dict[str, Any]) -> None:
    """Fail closed when a prize/trigger pause loses its remaining VM frames."""
    continuation = metadata.get("continuation", {})
    if not isinstance(continuation, dict):
        return
    kind = str(continuation.get("kind", "") or "")
    domain = str(continuation.get("domain", "") or "")
    if not kind or domain not in {"prize", "trigger"}:
        return
    resume = continuation.get("_resume")
    if not isinstance(resume, dict) or "version" not in resume:
        raise PendingContinuationError(
            "奖赏或触发选择缺少完整的 VM 恢复状态。",
            error_code="unsupported_continuation_state",
        )


def rebuild_choice_request(
    state: GameState,
    payload: dict[str, Any],
) -> ChoiceRequest:
    """Rebuild a choice and its VM callback from a serialized state payload.

    Legacy requests without a continuation are returned for display, but have
    no callback.  They can only be resolved while their explicitly retained
    live runtime request is still present; snapshots never serialize closures.
    """
    if not isinstance(payload, dict):
        raise PendingContinuationError("待处理选择格式无效。", error_code="invalid_pending_choice")

    request_id = payload.get("request_id", "")
    request_type = payload.get("request_type", "")
    prompt = payload.get("prompt", "")
    allow_duplicates = payload.get("allow_duplicates", False)
    can_cancel = payload.get("can_cancel", False)
    if (
        not isinstance(request_id, str)
        or not request_id
        or not isinstance(request_type, str)
        or not request_type
        or not isinstance(prompt, str)
        or type(allow_duplicates) is not bool
        or type(can_cancel) is not bool
    ):
        raise PendingContinuationError(
            "待处理选择字段无效。",
            error_code="invalid_pending_choice",
        )

    metadata = payload.get("metadata", {})
    if not isinstance(metadata, dict):
        raise PendingContinuationError("待处理选择元数据无效。", error_code="invalid_pending_choice")
    metadata = copy.deepcopy(metadata)
    if "revision" in metadata and type(metadata["revision"]) is not int:
        raise PendingContinuationError(
            "待处理选择 revision 无效。",
            error_code="invalid_pending_choice",
        )
    validate_resume_required_domain(metadata)

    options_payload = payload.get("options", [])
    if not isinstance(options_payload, list):
        raise PendingContinuationError("待处理选择选项无效。", error_code="invalid_pending_choice")
    options = tuple(
        _choice_option_from_dict(state, option)
        for option in options_payload
    )
    option_ids = [option.option_id for option in options]
    if len(set(option_ids)) != len(option_ids):
        raise PendingContinuationError(
            "待处理选择包含重复选项标识。",
            error_code="invalid_pending_choice",
        )

    raw_player = payload.get("player", -1)
    raw_min_select = payload.get("min_select", 1)
    raw_max_select = payload.get("max_select", 1)
    if any(
        type(value) is not int
        for value in (raw_player, raw_min_select, raw_max_select)
    ):
        raise PendingContinuationError(
            "待处理选择数值字段无效。",
            error_code="invalid_pending_choice",
        )
    player = raw_player
    min_select = raw_min_select
    max_select = raw_max_select
    if player not in (0, 1) or min_select < 0 or max_select < min_select:
        raise PendingContinuationError("待处理选择边界无效。", error_code="invalid_pending_choice")

    legacy = _legacy_request_from_payload(
        state,
        payload,
        metadata,
        options,
        player=player,
        min_select=min_select,
        max_select=max_select,
    )
    request = ChoiceRequest(
        request_id=request_id,
        request_type=request_type,
        player=player,
        prompt=prompt,
        options=options,
        min_select=min_select,
        max_select=max_select,
        allow_duplicates=allow_duplicates,
        can_cancel=can_cancel,
        metadata=metadata,
        legacy_request=legacy,
    )

    continuation = metadata.get("continuation", {})
    if not isinstance(continuation, dict):
        raise PendingContinuationError(
            "待处理 continuation 格式无效。",
            error_code="invalid_continuation",
        )
    raw_kind = continuation.get("kind", "")
    if not isinstance(raw_kind, str):
        raise PendingContinuationError(
            "待处理 continuation 类型无效。",
            error_code="invalid_continuation",
        )
    kind = raw_kind
    if not kind:
        return request

    from engine.commands.resolution_stack import ResolutionStack

    stack = ResolutionStack(state)
    if not stack.continuation_registry.supports(kind):
        raise PendingContinuationError(
            f"Unknown VM continuation: {kind}",
            error_code="unknown_continuation",
        )
    raw_resume = continuation.get("_resume")
    if raw_resume is not None and not isinstance(raw_resume, dict):
        raise PendingContinuationError(
            "待处理 continuation 的恢复状态无效。",
            error_code="unsupported_continuation_state",
        )
    resume = raw_resume if isinstance(raw_resume, dict) else {}
    finish_attack_actor = metadata.get("finish_attack_actor")
    if "finish_attack_actor" in metadata and (
        type(finish_attack_actor) is not int or finish_attack_actor not in (0, 1)
    ):
        raise PendingContinuationError(
            "待处理攻击选择的玩家无效。",
            error_code="invalid_pending_choice",
        )
    if type(finish_attack_actor) is int and finish_attack_actor in (0, 1) and "version" not in resume:
        # Without the serialized remaining attack frames, resolving only the
        # choice continuation would strand the restored game in ATTACK phase
        # and could skip damage, KO settlement, or end-turn lifecycle work.
        raise PendingContinuationError(
            "攻击选择缺少完整的 VM 恢复状态。",
            error_code="unsupported_continuation_state",
        )
    resume_player = resume.get("player_idx", player)
    if type(resume_player) is not int or resume_player not in (0, 1):
        raise PendingContinuationError(
            "待处理 continuation 的玩家无效。",
            error_code="invalid_continuation",
        )
    source_slot = resume.get("source_slot", "active")
    if not isinstance(source_slot, str) or not source_slot:
        raise PendingContinuationError(
            "待处理 continuation 的来源位置无效。",
            error_code="invalid_continuation",
        )
    if "version" in resume:
        from engine.commands.continuation_state import (
            ContinuationStateError,
            restore_resolution_stack,
        )

        try:
            restore_resolution_stack(stack, resume)
        except ContinuationStateError as exc:
            raise PendingContinuationError(
                str(exc),
                error_code="unsupported_continuation_state",
            ) from exc
        except Exception as exc:
            # Compiler/registry validation may raise ValueError or KeyError
            # for a corrupt serialized frame.  Serialized input must fail
            # closed instead of escaping the public rules API.
            raise PendingContinuationError(
                f"无法恢复 VM continuation：{exc}",
                error_code="unsupported_continuation_state",
            ) from exc
    request.legacy_request = stack.vm_interpreter.wrap_pending_choice(
        stack,
        legacy,
        resume_player,
        source_slot,
    )
    return request


def _legacy_request_from_payload(
    state: GameState,
    payload: dict[str, Any],
    metadata: dict[str, Any],
    options: tuple[ChoiceOption, ...],
    *,
    player: int,
    min_select: int,
    max_select: int,
) -> ActionRequest:
    target_info = metadata.get("target_info", [])
    if not isinstance(target_info, list):
        target_info = []
    if not target_info:
        target_info = [
            copy.deepcopy(option.value)
            for option in options
            if isinstance(option.value, dict)
        ]

    bench_indices = metadata.get("bench_indices", [])
    if not isinstance(bench_indices, list):
        bench_indices = []
    if not bench_indices:
        bench_indices = [
            index
            for option in options
            if isinstance(option.ref, PokemonRef)
            for index in [_bench_index(option.ref.slot)]
            if index >= 0
        ]

    card_list = []
    card_list_ids = metadata.get("card_list_ids", [])
    if isinstance(card_list_ids, list):
        for card_id in card_list_ids:
            card = _lookup_card_for_choice(state, player, "", -1, str(card_id or ""))
            if card is not None:
                card_list.append(card)
    if not card_list:
        card_list = [
            option.value
            for option in options
            if isinstance(option.ref, CardRef) and option.value is not None
        ]

    pending_card = None
    pending_card_id = str(metadata.get("pending_card_id", "") or "")
    if pending_card_id:
        pending_card = _lookup_card_for_choice(state, player, "", -1, pending_card_id)

    continuation = metadata.get("continuation", {})
    return ActionRequest(
        request_type=str(payload.get("request_type", "")),
        player=player,
        prompt=str(payload.get("prompt", "")),
        min_select=min_select,
        max_select=max_select,
        from_zone=str(metadata.get("from_zone", "") or ""),
        card_list=card_list,
        target_player=str(metadata.get("target_player", "") or ""),
        bench_indices=bench_indices,
        allow_duplicates=bool(payload.get("allow_duplicates", False)),
        flip_count=_safe_int(metadata.get("flip_count", 1), 1),
        until_tails=bool(metadata.get("until_tails", False)),
        pending_card=pending_card,
        distribute_mode=str(metadata.get("distribute_mode", "") or ""),
        target_info=target_info,
        max_per_target=_safe_int(metadata.get("max_per_target", 99), 99),
        source_name=str(metadata.get("source_name", "") or ""),
        request_id=str(payload.get("request_id", "")),
        can_cancel=bool(payload.get("can_cancel", False)),
        continuation=copy.deepcopy(continuation) if isinstance(continuation, dict) else {},
    )


def _choice_option_from_dict(state: GameState, payload: Any) -> ChoiceOption:
    if not isinstance(payload, dict):
        raise PendingContinuationError("待处理选择项格式无效。", error_code="invalid_pending_choice")
    option_id = payload.get("option_id", "")
    label = payload.get("label", "")
    if not isinstance(option_id, str) or not option_id or not isinstance(label, str):
        raise PendingContinuationError(
            "待处理选择项字段无效。",
            error_code="invalid_pending_choice",
        )
    ref = _entity_ref_from_dict(payload.get("ref"))
    value = copy.deepcopy(payload.get("value"))
    if isinstance(ref, CardRef):
        value = _lookup_card_for_choice(
            state,
            ref.player,
            ref.zone,
            ref.index,
            ref.card_id,
        )
    return ChoiceOption(
        option_id=option_id,
        label=label,
        ref=ref,
        value=value,
    )


def _entity_ref_from_dict(payload: Any):
    if payload is None:
        return None
    if not isinstance(payload, dict):
        raise PendingContinuationError("选择引用格式无效。", error_code="invalid_pending_choice")
    kind = payload.get("kind", "")
    if not isinstance(kind, str):
        raise PendingContinuationError(
            "选择引用类型无效。",
            error_code="invalid_pending_choice",
        )
    player = payload.get("player", -1)
    index = payload.get("index", -1)
    if type(player) is not int or type(index) is not int:
        raise PendingContinuationError(
            "选择引用数值无效。",
            error_code="invalid_pending_choice",
        )
    if player not in (0, 1):
        raise PendingContinuationError("选择引用玩家无效。", error_code="invalid_pending_choice")
    card_id = payload.get("card_id", "")
    if not isinstance(card_id, str):
        raise PendingContinuationError(
            "选择引用卡牌标识无效。",
            error_code="invalid_pending_choice",
        )
    if kind == "card":
        zone = payload.get("zone", "")
        if not isinstance(zone, str):
            raise PendingContinuationError(
                "选择引用区域无效。",
                error_code="invalid_pending_choice",
            )
        return CardRef(player, zone, index, card_id)
    if kind == "pokemon":
        slot = payload.get("slot", "")
        if not isinstance(slot, str):
            raise PendingContinuationError(
                "选择引用位置无效。",
                error_code="invalid_pending_choice",
            )
        return PokemonRef(player, slot, card_id)
    if kind == "attachment":
        slot = payload.get("slot", "")
        attachment_type = payload.get("attachment_type", "")
        if not isinstance(slot, str) or not isinstance(attachment_type, str):
            raise PendingContinuationError(
                "选择附着卡引用无效。",
                error_code="invalid_pending_choice",
            )
        return AttachmentRef(
            player,
            slot,
            attachment_type,
            index,
            card_id,
        )
    raise PendingContinuationError(
        f"未知选择引用类型：{kind}",
        error_code="invalid_pending_choice",
    )


def _lookup_card_for_choice(
    state: GameState,
    player_idx: int,
    zone_name: str,
    index: int,
    card_id: str,
):
    if player_idx in (0, 1):
        player = state.get_player(player_idx)
        normalized_zone = "prizes" if zone_name == "prize" else zone_name
        zone = getattr(player, normalized_zone, None)
        if isinstance(zone, list):
            if 0 <= index < len(zone):
                candidate = zone[index]
                if not card_id or getattr(candidate, "api_id", "") == card_id:
                    return candidate
            for candidate in zone:
                if getattr(candidate, "api_id", "") == card_id:
                    return candidate
    if card_id:
        from data.card_registry import CardRegistry

        return CardRegistry.get(card_id)
    return None


def _bench_index(slot: str) -> int:
    if not str(slot).startswith("bench_"):
        return -1
    return _safe_int(str(slot).split("_", 1)[1], -1)


def _safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

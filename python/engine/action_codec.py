"""Strict JSON codecs for the Python rules/tooling boundary.

The public choice contract deliberately omits ``ChoiceOption.value``.  That
field is authoritative VM state, not something a caller must echo back when it
submits a :class:`~engine.actions.ChoiceResponse`.  Pending choices use the
separate internal codec below so snapshots retain the values required to resume
their continuations.
"""
from __future__ import annotations

import math
from typing import Any

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
    PokemonRef,
    SlotRef,
)
from engine.enums import PlayerAction


MAX_IDENTIFIER_BYTES = 128
MAX_TEXT_BYTES = 2048
MAX_DECK_CARDS = 60
MAX_BENCH_SIZE = 5
MAX_CHOICE_OPTIONS = 60
MAX_GENERIC_CONTAINER_ITEMS = 512
MAX_JSON_DEPTH = 12

PUBLIC_GAME_ACTIONS = frozenset(
    {member.name for member in PlayerAction}
    | {"PROMOTE", "SETUP_DONE"}
)

_ACTION_FIELDS = frozenset({
    "action", "params", "terminal", "actor", "source", "target", "action_id",
})
_REF_FIELDS = frozenset({
    "kind", "player", "zone", "slot", "index", "attachment_type", "card_id",
})
_CHOICE_REQUEST_FIELDS = frozenset({
    "request_id", "request_type", "player", "prompt", "options", "min_select",
    "max_select", "allow_duplicates", "can_cancel", "metadata",
})
_PUBLIC_CHOICE_OPTION_FIELDS = frozenset({"option_id", "label", "ref"})
_INTERNAL_CHOICE_OPTION_FIELDS = frozenset({"option_id", "label", "ref", "value"})
_CHOICE_RESPONSE_FIELDS = frozenset({"request_id", "option_ids", "cancelled"})


def _require_exact_object(data: Any, fields: frozenset[str], label: str) -> dict:
    if not isinstance(data, dict):
        raise ValueError(f"{label} must be an object")
    if not all(isinstance(key, str) for key in data):
        raise ValueError(f"{label} keys must be strings")
    keys = set(data)
    missing = fields - keys
    unknown = keys - fields
    if missing:
        raise ValueError(f"{label} is missing fields: {sorted(missing)}")
    if unknown:
        raise ValueError(f"{label} has unknown fields: {sorted(unknown)}")
    return data


def _bounded_string(
    value: Any,
    label: str,
    *,
    maximum: int = MAX_IDENTIFIER_BYTES,
    allow_empty: bool = True,
) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    if not allow_empty and not value:
        raise ValueError(f"{label} must not be empty")
    if len(value.encode("utf-8")) > maximum:
        raise ValueError(f"{label} exceeds {maximum} UTF-8 bytes")
    return value


def _bounded_int(value: Any, label: str, minimum: int, maximum: int) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{label} must be an integer in [{minimum}, {maximum}]")
    return value


def _canonical_json(value: Any, *, depth: int = 0, allow_api_id: bool = False):
    """Return a deep JSON value while enforcing the protocol-v4 bounds."""
    if depth > MAX_JSON_DEPTH:
        raise ValueError("JSON value exceeds the maximum nesting depth")
    if allow_api_id and hasattr(value, "api_id"):
        return _bounded_string(
            str(getattr(value, "api_id", "") or ""),
            "entity api_id",
        )
    if value is None or type(value) is bool or type(value) is int:
        return value
    if type(value) is float:
        if not math.isfinite(value):
            raise ValueError("JSON numbers must be finite")
        return value
    if isinstance(value, str):
        return _bounded_string(
            value,
            "JSON string",
            maximum=MAX_TEXT_BYTES * 4,
        )
    if isinstance(value, (list, tuple)):
        if len(value) > MAX_GENERIC_CONTAINER_ITEMS:
            raise ValueError("JSON array exceeds the item limit")
        return [
            _canonical_json(item, depth=depth + 1, allow_api_id=allow_api_id)
            for item in value
        ]
    if isinstance(value, dict):
        if len(value) > MAX_GENERIC_CONTAINER_ITEMS:
            raise ValueError("JSON object exceeds the item limit")
        result: dict[str, Any] = {}
        for key, item in value.items():
            key = _bounded_string(key, "JSON object key")
            result[key] = _canonical_json(
                item,
                depth=depth + 1,
                allow_api_id=allow_api_id,
            )
        return result
    raise ValueError(f"unsupported JSON value: {type(value).__name__}")


def serialize_entity_ref(ref) -> dict | None:
    """Encode a reference using the complete Godot ``EntityRef`` shape."""
    if ref is None:
        return None
    if isinstance(ref, CardRef):
        payload = {
            "kind": "card",
            "player": ref.player,
            "zone": ref.zone,
            "slot": "",
            "index": ref.index,
            "attachment_type": "",
            "card_id": ref.card_id,
        }
    elif isinstance(ref, PokemonRef):
        payload = {
            "kind": "pokemon",
            "player": ref.player,
            "zone": "",
            "slot": ref.slot,
            "index": -1,
            "attachment_type": "",
            "card_id": ref.card_id,
        }
    elif isinstance(ref, SlotRef):
        payload = {
            "kind": "slot",
            "player": ref.player,
            "zone": "",
            "slot": ref.slot,
            "index": -1,
            "attachment_type": "",
            "card_id": "",
        }
    elif isinstance(ref, AttachmentRef):
        payload = {
            "kind": "attachment",
            "player": ref.player,
            "zone": "",
            "slot": ref.slot,
            "attachment_type": ref.attachment_type,
            "index": ref.index,
            "card_id": ref.card_id,
        }
    else:
        raise ValueError("reference has an unsupported type")
    # Run the same validator used by untrusted decoder input.
    deserialize_entity_ref(payload)
    return payload


def deserialize_entity_ref(data: dict | None):
    if data is None:
        return None
    data = _require_exact_object(data, _REF_FIELDS, "reference")
    kind = _bounded_string(data["kind"], "reference kind", maximum=32, allow_empty=False)
    if type(data["player"]) is not int or data["player"] not in (0, 1):
        raise ValueError("reference player is invalid")
    player = data["player"]
    zone = _bounded_string(data["zone"], "reference zone", maximum=32)
    slot = _bounded_string(data["slot"], "reference slot", maximum=32)
    index = _bounded_int(data["index"], "reference index", -1, MAX_DECK_CARDS)
    attachment_type = _bounded_string(
        data["attachment_type"],
        "reference attachment_type",
        maximum=32,
    )
    card_id = _bounded_string(data["card_id"], "reference card_id")
    if kind == "card":
        if not zone or slot or attachment_type or index < 0:
            raise ValueError("card reference is invalid")
        return CardRef(player, zone, index, card_id)
    if kind == "pokemon":
        if zone or not slot or index != -1 or attachment_type:
            raise ValueError("pokemon reference is invalid")
        return PokemonRef(player, slot, card_id)
    if kind == "slot":
        if zone or not slot or index != -1 or attachment_type or card_id:
            raise ValueError("slot reference is invalid")
        return SlotRef(player, slot)
    if kind == "attachment":
        if zone or not slot or not attachment_type or index < 0:
            raise ValueError("attachment reference is invalid")
        return AttachmentRef(player, slot, attachment_type, index, card_id)
    raise ValueError(f"unsupported reference kind: {kind!r}")


# Backward-compatible private aliases retained for callers which imported the
# old helpers during the v2 transition.
_serialize_ref = serialize_entity_ref
_deserialize_ref = deserialize_entity_ref


def _validate_action_params(params: dict[str, Any]) -> dict[str, Any]:
    canonical = _canonical_json(params)
    for field, maximum in (("hand_idx", 59), ("bench_idx", 4), ("attack_idx", 31)):
        if field in canonical:
            _bounded_int(canonical[field], f"action params.{field}", 0, maximum)
    for field in ("slot", "target", "target_slot", "ability_name"):
        if field in canonical:
            _bounded_string(canonical[field], f"action params.{field}")
    if "energy_indices" in canonical:
        indices = canonical["energy_indices"]
        if not isinstance(indices, list) or len(indices) > MAX_DECK_CARDS:
            raise ValueError("action params.energy_indices is invalid")
        for index in indices:
            _bounded_int(index, "action params.energy_indices item", 0, 59)
    return canonical


def serialize_game_action(action: GameAction) -> dict:
    """Return the complete action-schema-v3 envelope."""
    if not isinstance(action, GameAction):
        raise ValueError("action must be a GameAction")
    action_name = (
        action.action.name
        if isinstance(action.action, PlayerAction)
        else str(action.action)
    )
    if action_name not in PUBLIC_GAME_ACTIONS:
        raise ValueError(f"unsupported public game action: {action_name!r}")
    actor = _bounded_int(action.actor, "action actor", 0, 1)
    if type(action.terminal) is not bool:
        raise ValueError("action terminal must be a bool")
    action_id = _bounded_string(action.action_id, "action action_id")
    return {
        "action": action_name,
        "params": _validate_action_params(action.params),
        "terminal": action.terminal,
        "actor": actor,
        "source": serialize_entity_ref(action.source),
        "target": serialize_entity_ref(action.target),
        "action_id": action_id,
    }


def deserialize_game_action(data: dict) -> GameAction:
    """Restore a validated :class:`GameAction` from a strict v3 envelope."""
    data = _require_exact_object(data, _ACTION_FIELDS, "action")
    action_name = _bounded_string(data["action"], "action name", maximum=64, allow_empty=False)
    if action_name not in PUBLIC_GAME_ACTIONS:
        raise ValueError(f"unsupported public game action: {action_name!r}")
    params = data["params"]
    if not isinstance(params, dict):
        raise ValueError("action params must be an object")
    terminal = data["terminal"]
    if type(terminal) is not bool:
        raise ValueError("action terminal must be a bool")
    actor = _bounded_int(data["actor"], "action actor", 0, 1)
    action_id = _bounded_string(data["action_id"], "action action_id")
    action = PlayerAction.__members__.get(action_name, action_name)
    return GameAction(
        action=action,
        params=_validate_action_params(params),
        terminal=terminal,
        actor=actor,
        source=deserialize_entity_ref(data["source"]),
        target=deserialize_entity_ref(data["target"]),
        action_id=action_id,
    )


def serialize_choice_request(request: ChoiceRequest) -> dict:
    """Return the public request shape without authoritative option values."""
    return _serialize_choice_request(request, internal=False)


def serialize_choice_request_internal(request: ChoiceRequest) -> dict:
    """Serialize a state-owned pending request, including continuation values."""
    return _serialize_choice_request(request, internal=True)


def serialize_choice_option_internal(option: ChoiceOption) -> dict:
    """Encode one state-owned option for pending-choice persistence."""
    return _serialize_choice_option(option, internal=True)


def canonical_internal_json(value: Any):
    """Expose the bounded internal JSON canonicalizer to snapshot code."""
    return _canonical_json(value, allow_api_id=True)


def _serialize_choice_request(request: ChoiceRequest, *, internal: bool) -> dict:
    if not isinstance(request, ChoiceRequest):
        raise ValueError("choice request must be a ChoiceRequest")
    request_id = _bounded_string(
        request.request_id,
        "choice request_id",
        allow_empty=False,
    )
    request_type = _bounded_string(
        request.request_type,
        "choice request_type",
        maximum=64,
        allow_empty=False,
    )
    player = _bounded_int(request.player, "choice player", 0, 1)
    prompt = _bounded_string(
        request.prompt,
        "choice prompt",
        maximum=MAX_TEXT_BYTES,
    )
    if not isinstance(request.options, (tuple, list)):
        raise ValueError("choice options must be a sequence")
    if len(request.options) > MAX_CHOICE_OPTIONS:
        raise ValueError("choice options exceed the item limit")
    min_select = _bounded_int(request.min_select, "choice min_select", 0, MAX_CHOICE_OPTIONS)
    max_select = _bounded_int(request.max_select, "choice max_select", 0, MAX_CHOICE_OPTIONS)
    if min_select > max_select:
        raise ValueError("choice selection bounds are invalid")
    if type(request.allow_duplicates) is not bool or type(request.can_cancel) is not bool:
        raise ValueError("choice boolean fields are invalid")
    options = [
        _serialize_choice_option(option, internal=internal)
        for option in request.options
    ]
    option_ids = [option["option_id"] for option in options]
    if len(set(option_ids)) != len(option_ids):
        raise ValueError("choice option IDs must be unique")
    if not isinstance(request.metadata, dict):
        raise ValueError("choice metadata must be an object")
    return {
        "request_id": request_id,
        "request_type": request_type,
        "player": player,
        "prompt": prompt,
        "options": options,
        "min_select": min_select,
        "max_select": max_select,
        "allow_duplicates": request.allow_duplicates,
        "can_cancel": request.can_cancel,
        "metadata": _canonical_json(request.metadata, allow_api_id=internal),
    }


def _serialize_choice_option(option: ChoiceOption, *, internal: bool) -> dict:
    if not isinstance(option, ChoiceOption):
        raise ValueError("choice option must be a ChoiceOption")
    result = {
        "option_id": _bounded_string(
            option.option_id,
            "choice option_id",
            allow_empty=False,
        ),
        "label": _bounded_string(
            option.label,
            "choice label",
            maximum=MAX_TEXT_BYTES,
        ),
        "ref": serialize_entity_ref(option.ref),
    }
    if internal:
        result["value"] = _canonical_json(option.value, allow_api_id=True)
    return result


def deserialize_choice_request(data: dict) -> ChoiceRequest:
    """Restore a strictly validated public choice request."""
    data = _require_exact_object(data, _CHOICE_REQUEST_FIELDS, "choice request")
    options_data = data["options"]
    if not isinstance(options_data, list) or len(options_data) > MAX_CHOICE_OPTIONS:
        raise ValueError("choice options are invalid")
    options: list[ChoiceOption] = []
    for raw_option in options_data:
        option = _require_exact_object(
            raw_option,
            _PUBLIC_CHOICE_OPTION_FIELDS,
            "choice option",
        )
        options.append(ChoiceOption(
            _bounded_string(option["option_id"], "choice option_id", allow_empty=False),
            _bounded_string(option["label"], "choice label", maximum=MAX_TEXT_BYTES),
            deserialize_entity_ref(option["ref"]),
        ))
    metadata = data["metadata"]
    if not isinstance(metadata, dict):
        raise ValueError("choice metadata must be an object")
    request = ChoiceRequest(
        request_id=_bounded_string(data["request_id"], "choice request_id", allow_empty=False),
        request_type=_bounded_string(
            data["request_type"], "choice request_type", maximum=64, allow_empty=False
        ),
        player=_bounded_int(data["player"], "choice player", 0, 1),
        prompt=_bounded_string(data["prompt"], "choice prompt", maximum=MAX_TEXT_BYTES),
        options=tuple(options),
        min_select=_bounded_int(data["min_select"], "choice min_select", 0, MAX_CHOICE_OPTIONS),
        max_select=_bounded_int(data["max_select"], "choice max_select", 0, MAX_CHOICE_OPTIONS),
        allow_duplicates=data["allow_duplicates"],
        can_cancel=data["can_cancel"],
        metadata=_canonical_json(metadata),
    )
    # Reuse serializer validation for cross-field and duplicate-ID checks.
    serialize_choice_request(request)
    return request


def serialize_choice_response(response: ChoiceResponse) -> dict:
    if not isinstance(response, ChoiceResponse):
        raise ValueError("choice response must be a ChoiceResponse")
    request_id = _bounded_string(
        response.request_id,
        "choice response request_id",
        allow_empty=False,
    )
    if not isinstance(response.option_ids, (tuple, list)):
        raise ValueError("choice response option_ids must be a sequence")
    if len(response.option_ids) > MAX_CHOICE_OPTIONS:
        raise ValueError("choice response option_ids exceed the item limit")
    option_ids = [
        _bounded_string(option_id, "choice response option_id", allow_empty=False)
        for option_id in response.option_ids
    ]
    if type(response.cancelled) is not bool:
        raise ValueError("choice response cancelled must be a bool")
    return {
        "request_id": request_id,
        "option_ids": option_ids,
        "cancelled": response.cancelled,
    }


def deserialize_choice_response(data: dict) -> ChoiceResponse:
    data = _require_exact_object(data, _CHOICE_RESPONSE_FIELDS, "choice response")
    option_ids = data["option_ids"]
    if not isinstance(option_ids, list) or len(option_ids) > MAX_CHOICE_OPTIONS:
        raise ValueError("choice response option_ids are invalid")
    cancelled = data["cancelled"]
    if type(cancelled) is not bool:
        raise ValueError("choice response cancelled must be a bool")
    response = ChoiceResponse(
        request_id=_bounded_string(
            data["request_id"],
            "choice response request_id",
            allow_empty=False,
        ),
        option_ids=tuple(
            _bounded_string(value, "choice response option_id", allow_empty=False)
            for value in option_ids
        ),
        cancelled=cancelled,
    )
    serialize_choice_response(response)
    return response

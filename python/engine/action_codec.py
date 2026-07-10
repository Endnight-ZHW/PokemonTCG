"""Canonical JSON-compatible codecs for engine actions and choices.

These codecs belong to the rules/tooling boundary.  They intentionally contain
no transport, lobby, hidden-information, or client networking behaviour.
"""
from __future__ import annotations

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
    PokemonRef,
)
from engine.enums import PlayerAction


def _serialize_ref(ref) -> dict | None:
    if isinstance(ref, CardRef):
        return {
            "kind": "card",
            "player": ref.player,
            "zone": ref.zone,
            "index": ref.index,
            "card_id": ref.card_id,
        }
    if isinstance(ref, PokemonRef):
        return {
            "kind": "pokemon",
            "player": ref.player,
            "slot": ref.slot,
            "card_id": ref.card_id,
        }
    if isinstance(ref, AttachmentRef):
        return {
            "kind": "attachment",
            "player": ref.player,
            "slot": ref.slot,
            "attachment_type": ref.attachment_type,
            "index": ref.index,
            "card_id": ref.card_id,
        }
    return None


def _deserialize_ref(data: dict | None):
    if not data:
        return None
    if not isinstance(data, dict):
        raise ValueError("reference must be an object")
    kind = data.get("kind")
    player = data.get("player")
    card_id = data.get("card_id", "")
    if type(player) is not int or player not in (0, 1):
        raise ValueError("reference player is invalid")
    if not isinstance(card_id, str):
        raise ValueError("reference card_id is invalid")
    if kind == "card":
        zone = data.get("zone")
        index = data.get("index")
        if not isinstance(zone, str) or type(index) is not int:
            raise ValueError("card reference is invalid")
        return CardRef(
            player,
            zone,
            index,
            card_id,
        )
    if kind == "pokemon":
        slot = data.get("slot")
        if not isinstance(slot, str):
            raise ValueError("pokemon reference is invalid")
        return PokemonRef(
            player,
            slot,
            card_id,
        )
    if kind == "attachment":
        slot = data.get("slot")
        attachment_type = data.get("attachment_type")
        index = data.get("index")
        if (
            not isinstance(slot, str)
            or not isinstance(attachment_type, str)
            or type(index) is not int
        ):
            raise ValueError("attachment reference is invalid")
        return AttachmentRef(
            player,
            slot,
            attachment_type,
            index,
            card_id,
        )
    raise ValueError(f"unsupported reference kind: {kind!r}")


def serialize_game_action(action: GameAction) -> dict:
    """Return a stable, JSON-compatible representation of ``action``."""
    action_name = (
        action.action.name
        if isinstance(action.action, PlayerAction)
        else str(action.action)
    )
    return {
        "action": action_name,
        "params": dict(action.params),
        "terminal": action.terminal,
        "actor": action.actor,
        "source": _serialize_ref(action.source),
        "target": _serialize_ref(action.target),
        "action_id": action.action_id,
    }


def deserialize_game_action(data: dict) -> GameAction:
    """Restore a :class:`GameAction` from canonical codec data."""
    action_name = str(data["action"])
    action = PlayerAction.__members__.get(action_name, action_name)
    return GameAction(
        action=action,
        params=dict(data.get("params") or {}),
        terminal=bool(data.get("terminal", False)),
        actor=data.get("actor"),
        source=_deserialize_ref(data.get("source")),
        target=_deserialize_ref(data.get("target")),
        action_id=str(data.get("action_id", "")),
    )


def serialize_choice_request(request: ChoiceRequest) -> dict:
    """Return the transport-independent public shape of a choice request."""
    return {
        "request_id": request.request_id,
        "request_type": request.request_type,
        "player": request.player,
        "prompt": request.prompt,
        "options": [
            {
                "option_id": option.option_id,
                "label": option.label,
                "ref": _serialize_ref(option.ref),
            }
            for option in request.options
        ],
        "min_select": request.min_select,
        "max_select": request.max_select,
        "allow_duplicates": request.allow_duplicates,
        "can_cancel": request.can_cancel,
        "metadata": dict(request.metadata),
    }


def deserialize_choice_request(data: dict) -> ChoiceRequest:
    """Restore a choice request from canonical codec data."""
    return ChoiceRequest(
        request_id=str(data["request_id"]),
        request_type=str(data["request_type"]),
        player=int(data.get("player", 0)),
        prompt=str(data.get("prompt", "")),
        options=tuple(
            ChoiceOption(
                str(option["option_id"]),
                str(option.get("label", "")),
                _deserialize_ref(option.get("ref")),
            )
            for option in data.get("options", [])
        ),
        min_select=int(data.get("min_select", 1)),
        max_select=int(data.get("max_select", 1)),
        allow_duplicates=bool(data.get("allow_duplicates", False)),
        can_cancel=bool(data.get("can_cancel", False)),
        metadata=dict(data.get("metadata") or {}),
    )


def serialize_choice_response(response: ChoiceResponse) -> dict:
    return {
        "request_id": response.request_id,
        "option_ids": list(response.option_ids),
        "cancelled": response.cancelled,
    }


def deserialize_choice_response(data: dict) -> ChoiceResponse:
    return ChoiceResponse(
        request_id=str(data["request_id"]),
        option_ids=tuple(str(value) for value in data.get("option_ids", [])),
        cancelled=bool(data.get("cancelled", False)),
    )

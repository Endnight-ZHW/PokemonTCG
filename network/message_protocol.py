"""Network protocol constants and helpers for multiplayer v2."""
from __future__ import annotations

import time

from engine.enums import PlayerAction

# Protocol envelope
PROTOCOL_VERSION = 2
MSG_VERSION_FIELD = "version"
MSG_SEQ_FIELD = "seq"
MSG_SENT_AT_FIELD = "sent_at"

# Message type constants
MSG_ACTION = "action"
MSG_SETUP_DONE = "setup_done"
MSG_DECK_SELECTED = "deck_selected"
MSG_RESOLVE_PENDING = "resolve_pending"
MSG_CHOICE_RESPONSE = "choice_response"
MSG_STATE_SYNC = "state_sync"
MSG_STATE_UPDATE = "state_update"
MSG_ACTION_RESULT = "action_result"
MSG_GAME_STARTING = "game_starting"
MSG_GAME_OVER = "game_over"
MSG_ERROR = "error"
MSG_CONNECTED = "connected"
MSG_OPPONENT_DISCONNECTED = "opponent_disconnected"
MSG_CONNECTION_FAILED = "connection_failed"

# Relay control messages
MSG_CREATE_ROOM = "create_room"
MSG_ROOM_CREATED = "room_created"
MSG_JOIN_ROOM = "join_room"
MSG_ROOM_JOINED = "room_joined"
MSG_OPPONENT_JOINED = "opponent_joined"

# Transport heartbeat messages
MSG_PING = "ping"
MSG_PONG = "pong"

# Message types where only the newest queued copy matters.
COALESCABLE_MESSAGES = {MSG_STATE_UPDATE}

# v1 payload types are rejected even when wrapped by a v2 envelope.
LEGACY_MESSAGE_TYPES = {MSG_RESOLVE_PENDING, MSG_STATE_SYNC, MSG_ACTION_RESULT}


def next_seq(current: int) -> int:
    """Return the next positive protocol sequence number."""
    return current + 1


def envelope_message(message: dict, seq: int) -> dict:
    """Return a v2 protocol envelope for an outgoing message."""
    wrapped = dict(message)
    wrapped[MSG_VERSION_FIELD] = PROTOCOL_VERSION
    wrapped[MSG_SEQ_FIELD] = seq
    wrapped.setdefault(MSG_SENT_AT_FIELD, time.time())
    if wrapped.get("type") == MSG_ACTION:
        wrapped.setdefault("action_id", f"act-{seq}")
    return wrapped


def is_protocol_message(message: dict) -> bool:
    """True when a dict carries protocol envelope fields."""
    return message.get(MSG_VERSION_FIELD) is not None


def is_protocol_compatible(message: dict) -> bool:
    """Return whether a wire message is compatible with this client."""
    return message.get(MSG_VERSION_FIELD) == PROTOCOL_VERSION


def is_newer_sequence(message: dict, last_seq: int) -> bool:
    """Return True when a message should be accepted for the peer stream."""
    seq = message.get(MSG_SEQ_FIELD)
    if not isinstance(seq, int):
        return True
    return seq > last_seq


# PlayerAction <-> string mapping
ACTION_TO_STRING = {
    PlayerAction.PLAY_BASIC: "PLAY_BASIC",
    PlayerAction.EVOLVE: "EVOLVE",
    PlayerAction.ATTACH_ENERGY: "ATTACH_ENERGY",
    PlayerAction.PLAY_TRAINER: "PLAY_TRAINER",
    PlayerAction.USE_ABILITY: "USE_ABILITY",
    PlayerAction.USE_STADIUM: "USE_STADIUM",
    PlayerAction.RETREAT: "RETREAT",
    PlayerAction.DECLARE_ATTACK: "DECLARE_ATTACK",
    PlayerAction.END_TURN: "END_TURN",
}

STRING_TO_ACTION = {v: k for k, v in ACTION_TO_STRING.items()}

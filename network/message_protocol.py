"""Message type constants and PlayerAction string mappings."""
from engine.enums import PlayerAction

# Message type constants
MSG_ACTION = "action"
MSG_SETUP_DONE = "setup_done"
MSG_DECK_SELECTED = "deck_selected"
MSG_RESOLVE_PENDING = "resolve_pending"
MSG_STATE_SYNC = "state_sync"
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

# PlayerAction ↔ string mapping
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

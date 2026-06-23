"""Compatibility exports for the game board layout.

New rendering code should prefer ``gs.layout`` / ``GameBoardLayout``.  The
constants below remain for older component imports while the UI is migrated.
"""
from config import CARD_WIDTH, CARD_HEIGHT
from ui.layout_model import DEFAULT_GAME_LAYOUT, GameBoardLayout

_L = DEFAULT_GAME_LAYOUT

# Log panel
LOG_W = _L.side_panel.w
LOG_X = _L.side_panel.x
PLAY_AREA_W = _L.board.w

# Field card dimensions (same for both players)
FIELD_ACTIVE_W, FIELD_ACTIVE_H = _L.active_size
FIELD_BENCH_W, FIELD_BENCH_H = _L.bench_size

# Opponent side (top) — bench behind, active facing center
OPP_INFO_Y = _L.opponent_info.y
OPP_BENCH_Y = _L.opponent_bench.y
OPP_ACTIVE_Y = _L.opponent_active.y

# Divider
DIVIDER_Y = _L.divider.y
DIVIDER_H = _L.divider.h

# Player side (bottom) — active facing center, bench behind
PLAYER_ACTIVE_Y = _L.player_active.y
PLAYER_BENCH_Y = _L.player_bench.y
PLAYER_INFO_Y = _L.player_info.y

# Hand cards
HAND_Y = _L.hand.y

# Action buttons — now live in the right action panel
BTN_W = 142
BTN_H = 32
BTN_GAP = 8
BTN_ROW1_Y = _L.action_panel.y + 42
BTN_ROW2_Y = BTN_ROW1_Y + BTN_H + 6

# Deck and discard zones (right side of play area)
DECK_ZONE_W = _L.player_deck.w
DECK_ZONE_H = _L.player_deck.h
DECK_DISCARD_GAP = 12

# Opponent deck/discard (top-right)
OPP_DECK_ZONE_X = _L.opponent_deck.x
OPP_DECK_ZONE_Y = _L.opponent_deck.y
OPP_DISCARD_ZONE_X = _L.opponent_discard.x
OPP_DISCARD_ZONE_Y = _L.opponent_discard.y

# Player deck/discard (bottom-right, near hand area)
PLAYER_DECK_ZONE_X = _L.player_deck.x
PLAYER_DECK_ZONE_Y = _L.player_deck.y
PLAYER_DISCARD_ZONE_X = _L.player_discard.x
PLAYER_DISCARD_ZONE_Y = _L.player_discard.y

# Stadium card position (top-right, left of log panel)
STADIUM_X = _L.stadium.x
STADIUM_Y = _L.stadium.y

# ── Slot key constants for animation triggers ──────────────────
SLOT_OPP_ACTIVE = "opp_active"
SLOT_PLAYER_ACTIVE = "player_active"

def opp_bench_slot(idx: int) -> str:
    return f"opp_bench_{idx}"

def player_bench_slot(idx: int) -> str:
    return f"player_bench_{idx}"

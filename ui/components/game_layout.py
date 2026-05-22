"""Layout constants for the game board — symmetric two-row field for both players."""
from config import (
    SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT,
)

# Log panel
LOG_W = 250
LOG_X = SCREEN_WIDTH - LOG_W - 8
PLAY_AREA_W = SCREEN_WIDTH - LOG_W - 16  # usable width left of log

# Field card dimensions (same for both players)
FIELD_ACTIVE_W = 138
FIELD_ACTIVE_H = 178
FIELD_BENCH_W = 104
FIELD_BENCH_H = 138

# Opponent side (top) — bench behind, active facing center
OPP_INFO_Y = 5
OPP_BENCH_Y = 24
OPP_ACTIVE_Y = OPP_BENCH_Y + FIELD_BENCH_H + 8

# Divider
DIVIDER_Y = OPP_ACTIVE_Y + FIELD_ACTIVE_H + 14
DIVIDER_H = 34

# Player side (bottom) — active facing center, bench behind
PLAYER_ACTIVE_Y = DIVIDER_Y + DIVIDER_H + 12
PLAYER_BENCH_Y = PLAYER_ACTIVE_Y + FIELD_ACTIVE_H + 8
PLAYER_INFO_Y = PLAYER_BENCH_Y + FIELD_BENCH_H + 4

# Hand cards
HAND_Y = PLAYER_INFO_Y + 22

# Action buttons — placed below hand
BTN_W = 128
BTN_H = 28
BTN_GAP = 6
BTN_ROW1_Y = HAND_Y + CARD_HEIGHT + 10
BTN_ROW2_Y = BTN_ROW1_Y + BTN_H + 2

# Deck and discard zones (right side of play area)
DECK_ZONE_W = 110
DECK_ZONE_H = 155
DECK_DISCARD_GAP = 12

# Opponent deck/discard (top-right)
OPP_DECK_ZONE_X = 1100
OPP_DECK_ZONE_Y = 10
OPP_DISCARD_ZONE_X = 1100
OPP_DISCARD_ZONE_Y = OPP_DECK_ZONE_Y + DECK_ZONE_H + DECK_DISCARD_GAP

# Player deck/discard (bottom-right, near hand area)
PLAYER_DECK_ZONE_X = 1100
PLAYER_DECK_ZONE_Y = HAND_Y - 10
PLAYER_DISCARD_ZONE_X = 1100
PLAYER_DISCARD_ZONE_Y = PLAYER_DECK_ZONE_Y - DECK_ZONE_H - DECK_DISCARD_GAP

# Stadium card position (top-right, left of log panel)
STADIUM_X = SCREEN_WIDTH - LOG_W - CARD_WIDTH - 16
STADIUM_Y = 10

# ── Slot key constants for animation triggers ──────────────────
SLOT_OPP_ACTIVE = "opp_active"
SLOT_PLAYER_ACTIVE = "player_active"

def opp_bench_slot(idx: int) -> str:
    return f"opp_bench_{idx}"

def player_bench_slot(idx: int) -> str:
    return f"player_bench_{idx}"

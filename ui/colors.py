"""Color constants for the game UI."""

# Card type colors (backgrounds)
TYPE_COLORS = {
    "Grass": (75, 175, 80),
    "Fire": (240, 90, 50),
    "Water": (50, 140, 220),
    "Lightning": (248, 210, 50),
    "Psychic": (180, 80, 160),
    "Fighting": (180, 110, 60),
    "Darkness": (60, 50, 70),
    "Metal": (170, 170, 180),
    "Dragon": (200, 160, 40),
    "Colorless": (210, 210, 200),
    "Trainer": (140, 180, 200),
    "Energy": (230, 230, 220),
}

# Energy icon colors
ENERGY_COLORS = {
    "Grass": (75, 185, 80),
    "Fire": (245, 100, 55),
    "Water": (55, 150, 230),
    "Lightning": (250, 215, 55),
    "Psychic": (185, 85, 165),
    "Fighting": (185, 115, 65),
    "Darkness": (65, 55, 75),
    "Metal": (175, 175, 185),
    "Dragon": (205, 165, 45),
    "Colorless": (220, 220, 210),
}

# Status colors
STATUS_COLORS = {
    "poisoned": (160, 60, 200),   # Purple
    "burned": (240, 80, 30),      # Red-orange
    "asleep": (100, 140, 200),    # Light blue
    "paralyzed": (220, 200, 30),  # Yellow
    "confused": (200, 120, 40),   # Orange
}

# UI theme colors
UI_BG_DARK = (20, 20, 40)
UI_BG_MEDIUM = (35, 35, 60)
UI_BG_LIGHT = (50, 50, 80)
UI_BG_BOARD = (30, 40, 30)
UI_BORDER = (100, 100, 140)
UI_TEXT_PRIMARY = (240, 240, 250)
UI_TEXT_SECONDARY = (170, 170, 190)
UI_TEXT_DARK = (30, 30, 45)
UI_HIGHLIGHT = (255, 215, 0)
UI_HIGHLIGHT_SOFT = (100, 200, 100)
UI_BUTTON = (60, 80, 140)
UI_BUTTON_HOVER = (80, 100, 170)
UI_BUTTON_ACTIVE = (50, 120, 80)
UI_BUTTON_DISABLED = (60, 60, 70)
UI_DANGER = (200, 60, 60)
UI_SUCCESS = (60, 200, 80)

# Card back color
CARD_BACK = (40, 60, 140)
CARD_BACK_ACCENT = (200, 180, 60)

# Player colors
PLAYER1_COLOR = (70, 130, 200)   # Blue
PLAYER2_COLOR = (220, 80, 70)    # Red

# Board background
BOARD_GRADIENT_CENTER = (35, 50, 35)
BOARD_GRADIENT_EDGE = (20, 28, 20)
BOARD_GRID_COLOR = (50, 65, 50, 40)
BOARD_OPPONENT_TINT = (40, 50, 60, 20)
BOARD_PLAYER_TINT = (50, 45, 35, 20)

# Card enhancement
CARD_SHADOW_COLOR = (0, 0, 0, 60)
CARD_HOVER_GLOW = (255, 215, 0, 40)
CARD_HOVER_LIFT = 4

# Button gradient
BTN_GRADIENT_TOP = (80, 100, 160)
BTN_GRADIENT_BOT = (50, 65, 120)
BTN_ATTACK_GRADIENT_TOP = (200, 70, 50)
BTN_ATTACK_GRADIENT_BOT = (160, 40, 30)

# Victory effects
VICTORY_GOLD_LIGHT = (255, 220, 80)
VICTORY_GOLD_DARK = (180, 130, 20)

# Deck zone
DECK_ZONE_BG = (25, 35, 65)
DECK_ZONE_BORDER = (80, 100, 160)
DECK_ZONE_HIGHLIGHT = (140, 160, 220)
DECK_COUNT_BADGE = (40, 60, 140)

# Discard zone
DISCARD_ZONE_BG = (30, 28, 35)
DISCARD_ZONE_EMPTY = (25, 22, 30)
DISCARD_ZONE_BORDER = (100, 90, 120)
DISCARD_ZONE_HIGHLIGHT = (160, 140, 180)

# Connection status indicator
CONNECTION_GOOD = (80, 220, 80)
CONNECTION_SLOW = (220, 200, 60)
CONNECTION_BAD = (220, 60, 60)

# Waiting indicator
WAITING_DOT_COLOR = (255, 215, 0)
WAITING_BG = (10, 10, 25, 180)

# Zone label text
ZONE_LABEL_COLOR = (180, 190, 210)

# Pass screen
PASS_PLAYER1_BAR = (50, 100, 180, 30)
PASS_PLAYER2_BAR = (200, 60, 50, 30)

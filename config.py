"""Game configuration constants."""
import sys
import os


def _get_base_path():
    """Return the application's root directory.

    When running from a PyInstaller bundle, sys._MEIPASS points to the
    directory containing bundled data files. In development this falls
    back to the current working directory.
    """
    if getattr(sys, 'frozen', False):
        return getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    return os.path.abspath(".")


_BASE_PATH = _get_base_path()

# Display
SCREEN_WIDTH = 1600
SCREEN_HEIGHT = 1000
FPS = 60
CARD_WIDTH = 120
CARD_HEIGHT = 170
TITLE = "宝可梦卡牌对战"

# API
POKEMON_TCG_API_KEY = ""  # Get free key at https://dev.pokemontcg.io
POKEMON_TCG_API_URL = "https://api.pokemontcg.io/v2"
IMAGE_CACHE_DIR = os.path.join(_BASE_PATH, "data", "images")

# Cache
CARD_CACHE_FILE = os.path.join(_BASE_PATH, "data", "card_db.json")
CARD_IMAGE_MAPPING_FILE = os.path.join(_BASE_PATH, "data", "card_image_mapping.json")

# Game rules
DECK_SIZE = 60
HAND_SIZE_INITIAL = 7
MAX_BENCH_SIZE = 5
PRIZE_CARDS = 6
MAX_COPIES_PER_CARD = 4

# Damage
DAMAGE_PER_COUNTER = 10

# Coin flip / RNG
COIN_FLIP_THRESHOLD = 0.5

# Tool bonuses
TOOL_HP_BOOST = 50  # HP boost for tools like Courage Charm

# ── Localization / display name maps ─────────────────────────────

# Energy type name mappings (English → Chinese)
ENERGY_NAME_CN = {
    "Fire": "火", "Water": "水", "Grass": "草", "Lightning": "雷",
    "Psychic": "超", "Fighting": "斗", "Darkness": "恶", "Metal": "钢",
    "Dragon": "龙", "Colorless": "无",
}

# Subtype name mappings (card_registry.py, card_image_screen.py)
SUBTYPE_CN = {
    "Basic": "基础", "Stage 1": "1阶进化", "Stage 2": "2阶进化",
    "Item": "物品", "Supporter": "支援者", "Stadium": "竞技场", "Tool": "宝可梦道具",
    "Special": "特殊",
}

# Status names — full form for action log messages
STATUS_NAME_CN = {
    "poisoned": "中毒",
    "burned": "灼伤",
    "asleep": "睡眠",
    "paralyzed": "麻痹",
    "confused": "混乱",
}

# Status names — short form for card display overlays
STATUS_SHORT_CN = {
    "poisoned": "毒",
    "burned": "灼",
    "asleep": "眠",
    "paralyzed": "麻",
    "confused": "乱",
}

# Turn phase display names
PHASE_CN = {
    "SETUP": "准备阶段 - 放置基础宝可梦",
    "DRAW": "抽牌阶段",
    "MAIN": "主要阶段",
    "ATTACK": "攻击阶段",
    "POKEMON_CHECKUP": "宝可梦检测",
    "GAME_OVER": "游戏结束",
}

# Card text-based rendering font sizes
FONT_CARD_NAME = 14
FONT_CARD_BODY = 11
FONT_CARD_SMALL = 9
FONT_UI_NORMAL = 18
FONT_UI_LARGE = 28
FONT_UI_TITLE = 48

# ── Card rendering ───────────────────────────────────────────────
CARD_BORDER_RADIUS = 10
BENCH_CARD_BORDER_RADIUS = 7
HAND_CARD_BORDER_RADIUS = 8
CARD_TEXT_MARGIN = 8
MAX_ENERGY_DISPLAY = 7
MAX_ATTACK_DISPLAY = 3

# ── HP bar colors ────────────────────────────────────────────────
HP_BAR_HEALTHY = (80, 200, 80)
HP_BAR_CAUTION = (220, 180, 40)
HP_BAR_DANGER = (220, 60, 60)
HP_THRESHOLD_CAUTION = 0.5
HP_THRESHOLD_DANGER = 0.25

# ── HP text colors ───────────────────────────────────────────────
HP_TEXT_HEALTHY = (255, 255, 255)
HP_TEXT_CAUTION = (255, 220, 60)
HP_TEXT_DANGER = (255, 80, 80)

# ── Action buttons ───────────────────────────────────────────────
BTN_W = 128
BTN_H = 28
BTN_GAP = 6
BTNS_PER_ROW = 5

# ── Tooltip ──────────────────────────────────────────────────────
TOOLTIP_W = 310
TOOLTIP_LINE_H = 16
TOOLTIP_MAX_CHARS = 28

# ── Action log ───────────────────────────────────────────────────
LOG_MAX_ENTRIES = 50
LOG_MAX_CHARS_PER_LINE = 55

# ── Animation ────────────────────────────────────────────────────
ANIM_CARD_PLAY_DURATION = 0.3
ANIM_DAMAGE_FLASH_DURATION = 0.3
ANIM_KO_FADE_DURATION = 0.8
ANIM_PHASE_BANNER_DURATION = 1.5
ANIM_SHAKE_DURATION = 0.25
ANIM_SHAKE_INTENSITY = 4
ANIM_EVOLVE_DURATION = 0.3

# ── Game speed ──────────────────────────────────────────────────
GAME_SPEED = 1.0
GAME_SPEED_OPTIONS = [0.5, 1.0, 2.0]

# ── Sound ──────────────────────────────────────────────────────
SFX_ENABLED = True
SFX_VOLUME = 0.5

# ── Network ────────────────────────────────────────────────────
NETWORK_PORT = 8765
NETWORK_TIMEOUT = 60  # seconds before disconnect considered dead (heartbeat keeps alive)

# ── Relay server ───────────────────────────────────────────────
RELAY_SERVER_HOST = os.environ.get("RELAY_SERVER_HOST", "52.78.231.177")  # 中继服务器地址，通过环境变量或UI输入框可覆盖
RELAY_SERVER_PORT = 8766               # 与游戏端口 8765 区分

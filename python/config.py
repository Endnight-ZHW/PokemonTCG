"""Game configuration constants."""
import sys
import os


def _get_base_path():
    """Return the application's root directory.

    When running from a PyInstaller bundle, sys._MEIPASS points to the
    directory containing bundled data files. In development this uses
    the directory containing this config file (project root).
    """
    if getattr(sys, 'frozen', False):
        return getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


_BASE_PATH = _get_base_path()

# Display
SCREEN_WIDTH = 1600
SCREEN_HEIGHT = 1000
FPS = 60
CARD_WIDTH = 120
CARD_HEIGHT = 170

# Assets
IMAGE_CACHE_DIR = os.path.join(_BASE_PATH, "data", "images")
CARD_IMAGE_MAPPING_FILE = os.path.join(_BASE_PATH, "data", "card_image_mapping.json")

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

# ── Game speed ──────────────────────────────────────────────────
GAME_SPEED = 1.0
GAME_SPEED_OPTIONS = [0.5, 1.0, 2.0]

# ── Sound ──────────────────────────────────────────────────────
SFX_ENABLED = True
SFX_VOLUME = 0.5

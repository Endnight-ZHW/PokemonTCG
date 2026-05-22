"""Shared font manager — platform-aware Chinese font loading and caching."""
import os
import sys
from typing import Optional

import pygame

# Standard font size keys — semantic aliases for get_font()
FONT_SIZE = {
    "title_xl": 64,
    "title": 56,
    "title_md": 52,
    "title_sm": 36,
    "subtitle": 32,
    "heading": 30,
    "body_lg": 28,
    "body": 26,
    "body_md": 22,
    "body_sm": 20,
    "info": 20,
    "normal": 18,
    "small": 17,
    "smaller": 16,
    "card_name": 15,
    "action": 16,
    "caption": 14,
    "card_body": 12,
    "tiny": 11,
    "card_tiny": 10,
}

# ── Platform font fallback chain ──

_FONT_CANDIDATES: list[tuple[str, bool]] = []  # (path, is_bold)


def _build_candidates():
    """Build a platform-aware list of Chinese font candidates."""
    _FONT_CANDIDATES.clear()

    if sys.platform == "win32":
        windir = os.environ.get("WINDIR", "C:/Windows")
        fonts_dir = os.path.join(windir, "Fonts")
        candidates = [
            ("msyh.ttc", False),     # 微软雅黑 (regular weight from .ttc)
            ("msyhbd.ttc", True),    # 微软雅黑 Bold
            ("simhei.ttf", True),    # 黑体 (bold appearance)
            ("simsun.ttc", False),   # 宋体
            ("simkai.ttf", False),   # 楷体
        ]
        for name, bold in candidates:
            path = os.path.join(fonts_dir, name)
            if os.path.exists(path):
                _FONT_CANDIDATES.append((path, bold))

    elif sys.platform == "darwin":
        candidates = [
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/STHeiti Light.ttc",
            "/System/Library/Fonts/STHeiti Medium.ttc",
            "/Library/Fonts/Arial Unicode.ttf",
        ]
        for path in candidates:
            if os.path.exists(path):
                _FONT_CANDIDATES.append((path, False))

    else:  # Linux / other
        candidates = [
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
            "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
        ]
        for path in candidates:
            if os.path.exists(path):
                _FONT_CANDIDATES.append((path, False))


_build_candidates()

# ── Font cache ──

_font_cache: dict[tuple[int, bool], pygame.font.Font] = {}
_default_path: Optional[str] = _FONT_CANDIDATES[0][0] if _FONT_CANDIDATES else None
_bold_path: Optional[str] = None

# Find a bold variant
for _path, _bold in _FONT_CANDIDATES:
    if _bold:
        _bold_path = _path
        break
if _bold_path is None:
    _bold_path = _default_path


def _get_font_path(bold: bool) -> Optional[str]:
    if bold and _bold_path:
        return _bold_path
    return _default_path


def get_font(size_key: str) -> pygame.font.Font:
    """Get a cached font by size key (e.g., 'body', 'card_name')."""
    if size_key not in FONT_SIZE:
        raise KeyError(f"Unknown font size key: {size_key}")
    return get_font_size(FONT_SIZE[size_key])


def get_font_size(size: int, bold: bool = False) -> pygame.font.Font:
    """Get a cached font at a specific point size."""
    cache_key = (size, bold)
    if cache_key in _font_cache:
        return _font_cache[cache_key]

    path = _get_font_path(bold)
    if path:
        try:
            font = pygame.font.Font(path, size)
        except (pygame.error, FileNotFoundError):
            font = pygame.font.Font(None, size)
    else:
        font = pygame.font.Font(None, size)

    _font_cache[cache_key] = font
    return font


def get_bold_font(size_key: str) -> pygame.font.Font:
    """Get a cached bold font by size key."""
    if size_key not in FONT_SIZE:
        raise KeyError(f"Unknown font size key: {size_key}")
    return get_font_size(FONT_SIZE[size_key], bold=True)


def get_default_font_path() -> Optional[str]:
    """Return the path of the primary Chinese font, or None."""
    return _default_path


def reload_fonts():
    """Re-scan for fonts and clear the cache. Useful after adding fonts at runtime."""
    _font_cache.clear()
    global _default_path, _bold_path
    _build_candidates()
    _default_path = _FONT_CANDIDATES[0][0] if _FONT_CANDIDATES else None
    _bold_path = None
    for _path, _bold in _FONT_CANDIDATES:
        if _bold:
            _bold_path = _path
            break
    if _bold_path is None:
        _bold_path = _default_path

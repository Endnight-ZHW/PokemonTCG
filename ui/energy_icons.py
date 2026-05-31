"""Reusable energy icon rendering helpers for battle UI surfaces."""
from __future__ import annotations

from typing import Any

import pygame

from config import ENERGY_NAME_CN as ENERGY_CN
from ui.colors import ENERGY_COLORS, UI_HIGHLIGHT


_BASIC_ENERGY_IMAGE_NAMES = {
    "Grass": "草能量",
    "Fire": "火能量",
    "Water": "水能量",
    "Lightning": "雷能量",
    "Psychic": "超能量",
    "Fighting": "斗能量",
    "Metal": "钢能量",
}

_EXTRA_ENERGY_COLORS = {
    "Rainbow": (230, 110, 220),
    "Any": (230, 110, 220),
    "Darkness": (65, 55, 75),
    "Dragon": (205, 165, 45),
}

_ICON_CACHE: dict[tuple[str, int], pygame.Surface] = {}


def _safe_convert_alpha(surface: pygame.Surface) -> pygame.Surface:
    try:
        return surface.convert_alpha()
    except pygame.error:
        return surface


def _cache_key(card_or_type: Any, size: int) -> tuple[str, int]:
    api_id = getattr(card_or_type, "api_id", "")
    name = getattr(card_or_type, "name", "")
    if api_id:
        return (f"card:{api_id}", size)
    if name:
        return (f"name:{name}", size)
    return (f"type:{card_or_type}", size)


def _provided_type(card_or_type: Any) -> str:
    if isinstance(card_or_type, str):
        return card_or_type
    provided = getattr(card_or_type, "provides_energy", None)
    if provided:
        return provided[0] if provided else "Colorless"
    energy_types = getattr(card_or_type, "energy_types", None)
    if energy_types:
        return energy_types[0]
    return "Colorless"


def _source_image(image_mgr, card_or_type: Any) -> pygame.Surface | None:
    name = getattr(card_or_type, "name", "")
    api_id = getattr(card_or_type, "api_id", "")
    if name or api_id:
        img = image_mgr.get_card_image(name, api_id)
        if img is not None:
            return img

    energy_type = _provided_type(card_or_type)
    fallback_name = _BASIC_ENERGY_IMAGE_NAMES.get(energy_type)
    if fallback_name:
        img = image_mgr.get_card_image(fallback_name, "")
        if img is not None:
            return img
    return None


def _crop_center_square(source: pygame.Surface) -> pygame.Surface:
    w, h = source.get_size()
    side = min(w, h)
    crop = pygame.Rect((w - side) // 2, (h - side) // 2, side, side)
    square = pygame.Surface((side, side), pygame.SRCALPHA)
    square.blit(source, (0, 0), crop)
    return square


def _fallback_icon(card_or_type: Any, size: int, font: pygame.font.Font | None = None) -> pygame.Surface:
    energy_type = _provided_type(card_or_type)
    color = ENERGY_COLORS.get(energy_type, _EXTRA_ENERGY_COLORS.get(energy_type, (210, 210, 205)))
    surf = pygame.Surface((size, size), pygame.SRCALPHA)
    center = size // 2
    radius = max(3, size // 2 - 2)

    pygame.draw.circle(surf, (0, 0, 0, 80), (center + 1, center + 2), radius)
    pygame.draw.circle(surf, color, (center, center), radius)
    pygame.draw.circle(surf, (255, 255, 255, 90), (center - radius // 3, center - radius // 3), max(1, radius // 3))
    pygame.draw.circle(surf, (22, 24, 30), (center, center), radius, 1)

    if font is not None and size >= 14:
        label = ENERGY_CN.get(energy_type, energy_type[:1])
        txt = font.render(label, True, (15, 15, 18))
        surf.blit(txt, txt.get_rect(center=(center, center)))
    return _safe_convert_alpha(surf)


def get_energy_icon_surface(image_mgr, card_or_type: Any, size: int) -> pygame.Surface:
    """Return a cached circular icon for an attached energy card or type."""
    size = max(8, int(size))
    key = _cache_key(card_or_type, size)
    if key in _ICON_CACHE:
        return _ICON_CACHE[key]

    img = _source_image(image_mgr, card_or_type)
    if img is None:
        icon = _fallback_icon(card_or_type, size)
        _ICON_CACHE[key] = icon
        return icon

    square = _crop_center_square(img)
    scaled = pygame.transform.smoothscale(square, (size, size))
    icon = pygame.Surface((size, size), pygame.SRCALPHA)

    mask = pygame.Surface((size, size), pygame.SRCALPHA)
    pygame.draw.circle(mask, (255, 255, 255, 255), (size // 2, size // 2), size // 2 - 1)
    icon.blit(scaled, (0, 0))
    icon.blit(mask, (0, 0), special_flags=pygame.BLEND_RGBA_MULT)

    pygame.draw.circle(icon, (255, 255, 255, 110), (size // 2 - size // 5, size // 2 - size // 5), max(1, size // 5))
    pygame.draw.circle(icon, (14, 16, 22), (size // 2, size // 2), size // 2 - 1, 1)
    pygame.draw.circle(icon, UI_HIGHLIGHT, (size // 2, size // 2), size // 2 - 2, 1)

    icon = _safe_convert_alpha(icon)
    _ICON_CACHE[key] = icon
    return icon


def draw_energy_icon(surface: pygame.Surface, image_mgr, card_or_type: Any,
                     center: tuple[int, int], size: int,
                     font: pygame.font.Font | None = None) -> pygame.Rect:
    """Draw one energy icon centered at ``center`` and return its rect."""
    icon = get_energy_icon_surface(image_mgr, card_or_type, size)
    rect = icon.get_rect(center=(int(center[0]), int(center[1])))

    shadow = pygame.Surface((size + 4, size + 4), pygame.SRCALPHA)
    pygame.draw.circle(shadow, (0, 0, 0, 90), (size // 2 + 3, size // 2 + 3), size // 2)
    surface.blit(shadow, (rect.x - 2, rect.y - 2))
    surface.blit(icon, rect)
    return rect


def draw_energy_stack(surface: pygame.Surface, image_mgr, energy_cards: list,
                      rect: pygame.Rect, font: pygame.font.Font,
                      max_icons: int, compact: bool = False) -> pygame.Rect | None:
    """Draw a row of real energy icons inside rect."""
    if not energy_cards:
        return None

    count = min(len(energy_cards), max_icons)
    size = 15 if compact else 18
    overlap = 5 if compact else 4
    step = max(8, size - overlap)
    total_w = size + (count - 1) * step
    has_more = len(energy_cards) > max_icons
    more_w = font.size(f"+{len(energy_cards) - max_icons}")[0] + 4 if has_more else 0
    total_w += more_w

    start_x = rect.centerx - total_w // 2
    center_y = rect.centery
    last_rect = None
    for idx, card in enumerate(energy_cards[:count]):
        cx = start_x + size // 2 + idx * step
        last_rect = draw_energy_icon(surface, image_mgr, card, (cx, center_y), size, font)

    if has_more:
        text = f"+{len(energy_cards) - max_icons}"
        txt = font.render(text, True, (250, 235, 150))
        tx = start_x + size + (count - 1) * step + 4
        ty = center_y - txt.get_height() // 2
        outline = font.render(text, True, (0, 0, 0))
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            surface.blit(outline, (tx + dx, ty + dy))
        surface.blit(txt, (tx, ty))
        last_rect = pygame.Rect(tx, ty, txt.get_width(), txt.get_height())
    return last_rect

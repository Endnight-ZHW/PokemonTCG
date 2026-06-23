"""Shared UI theme helpers for the PTCG interface."""
from __future__ import annotations

from dataclasses import dataclass
import pygame

from ui.colors import (
    UI_BG_DARK, UI_BG_MEDIUM, UI_BORDER, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
    UI_HIGHLIGHT, UI_BUTTON, UI_BUTTON_HOVER, UI_BUTTON_ACTIVE,
    UI_BUTTON_DISABLED, UI_DANGER, UI_SUCCESS,
)


RADIUS = 8
PANEL_BG = (18, 21, 34)
PANEL_BG_ALT = (24, 28, 44)
PANEL_EDGE = (62, 72, 104)
SURFACE_BG = (28, 34, 50)
SURFACE_BG_HOVER = (38, 48, 72)
TEXT_MUTED = UI_TEXT_SECONDARY
ACCENT_BLUE = (92, 152, 230)
ACCENT_GOLD = UI_HIGHLIGHT
ACCENT_RED = UI_DANGER
ACCENT_GREEN = UI_SUCCESS


@dataclass(frozen=True)
class ButtonStyle:
    top: tuple[int, int, int]
    bottom: tuple[int, int, int]
    border: tuple[int, int, int]
    text: tuple[int, int, int] = UI_TEXT_PRIMARY


BUTTON_NORMAL = ButtonStyle((54, 71, 118), (37, 49, 86), (86, 104, 154))
BUTTON_HOVER = ButtonStyle((72, 93, 148), (50, 68, 118), UI_HIGHLIGHT)
BUTTON_ACTIVE = ButtonStyle((50, 125, 87), (35, 92, 65), (115, 230, 150))
BUTTON_DISABLED = ButtonStyle((48, 50, 62), (35, 37, 48), (72, 76, 92), UI_TEXT_SECONDARY)
BUTTON_DANGER = ButtonStyle((174, 62, 64), (120, 40, 46), (230, 112, 116))
BUTTON_ATTACK = ButtonStyle((188, 72, 50), (136, 42, 32), (245, 136, 96))


def draw_panel(surface: pygame.Surface, rect: pygame.Rect,
               title: str | None = None, font: pygame.font.Font | None = None,
               *, fill: tuple[int, int, int] = PANEL_BG,
               border: tuple[int, int, int] = PANEL_EDGE,
               radius: int = RADIUS) -> pygame.Rect:
    """Draw a quiet framed panel and return its inner content rect."""
    pygame.draw.rect(surface, fill, rect, border_radius=radius)
    pygame.draw.rect(surface, border, rect, 1, border_radius=radius)
    inner = rect.inflate(-18, -18)
    if title and font:
        txt = font.render(title, True, UI_HIGHLIGHT)
        surface.blit(txt, (inner.x, inner.y - 2))
        pygame.draw.line(surface, (50, 58, 84), (inner.x, inner.y + 24),
                         (inner.right, inner.y + 24), 1)
        inner.y += 32
        inner.h -= 32
    return inner


def draw_gradient_rect(surface: pygame.Surface, rect: pygame.Rect,
                       top: tuple[int, int, int], bottom: tuple[int, int, int],
                       *, radius: int = RADIUS) -> None:
    temp = pygame.Surface(rect.size, pygame.SRCALPHA)
    for y in range(rect.h):
        t = y / max(1, rect.h - 1)
        color = (
            int(top[0] + (bottom[0] - top[0]) * t),
            int(top[1] + (bottom[1] - top[1]) * t),
            int(top[2] + (bottom[2] - top[2]) * t),
        )
        pygame.draw.line(temp, color, (0, y), (rect.w, y))
    mask = pygame.Surface(rect.size, pygame.SRCALPHA)
    pygame.draw.rect(mask, (255, 255, 255, 255), mask.get_rect(),
                     border_radius=radius)
    temp.blit(mask, (0, 0), special_flags=pygame.BLEND_RGBA_MULT)
    surface.blit(temp, rect.topleft)


def draw_button(surface: pygame.Surface, rect: pygame.Rect, text: str,
                font: pygame.font.Font, *, hovered: bool = False,
                selected: bool = False, enabled: bool = True,
                danger: bool = False, attack: bool = False,
                align: str = "center") -> None:
    if not enabled:
        style = BUTTON_DISABLED
    elif selected:
        style = BUTTON_ACTIVE
    elif danger:
        style = BUTTON_DANGER if hovered else BUTTON_DANGER
    elif attack:
        style = BUTTON_ATTACK if hovered else BUTTON_ATTACK
    else:
        style = BUTTON_HOVER if hovered else BUTTON_NORMAL

    draw_gradient_rect(surface, rect, style.top, style.bottom, radius=RADIUS)
    pygame.draw.rect(surface, style.border, rect, 1, border_radius=RADIUS)
    hl = (min(255, style.top[0] + 45), min(255, style.top[1] + 45),
          min(255, style.top[2] + 45))
    pygame.draw.line(surface, hl, (rect.x + 6, rect.y + 1),
                     (rect.right - 6, rect.y + 1), 1)

    label = font.render(text, True, style.text)
    if align == "left":
        surface.blit(label, (rect.x + 12, rect.centery - label.get_height() // 2))
    else:
        surface.blit(label, label.get_rect(center=rect.center))


def draw_badge(surface: pygame.Surface, rect: pygame.Rect, text: str,
               font: pygame.font.Font,
               *, fill: tuple[int, int, int] = SURFACE_BG,
               text_color: tuple[int, int, int] = UI_TEXT_PRIMARY,
               border: tuple[int, int, int] | None = None) -> None:
    pygame.draw.rect(surface, fill, rect, border_radius=RADIUS)
    if border:
        pygame.draw.rect(surface, border, rect, 1, border_radius=RADIUS)
    label = font.render(text, True, text_color)
    surface.blit(label, label.get_rect(center=rect.center))


def draw_text_fit(surface: pygame.Surface, font: pygame.font.Font, text: str,
                  color: tuple[int, int, int], rect: pygame.Rect,
                  *, align: str = "left") -> None:
    """Draw text clipped to rect with a simple ellipsis if it is too wide."""
    display = text
    ellipsis = "..."
    while display and font.size(display)[0] > rect.w:
        display = display[:-1]
    if display != text and len(display) > len(ellipsis):
        display = display[:-len(ellipsis)] + ellipsis
    txt = font.render(display, True, color)
    if align == "center":
        pos = txt.get_rect(center=rect.center)
    else:
        pos = (rect.x, rect.y + (rect.h - txt.get_height()) // 2)
    surface.blit(txt, pos)


def tint(surface: pygame.Surface, rect: pygame.Rect,
         color: tuple[int, int, int, int], *, radius: int = RADIUS) -> None:
    layer = pygame.Surface(rect.size, pygame.SRCALPHA)
    pygame.draw.rect(layer, color, layer.get_rect(), border_radius=radius)
    surface.blit(layer, rect.topleft)

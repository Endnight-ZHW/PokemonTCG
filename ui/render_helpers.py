"""Shared rendering utilities extracted from game_screen.py."""
from contextlib import contextmanager
import pygame
from ui.colors import ENERGY_COLORS


# ── HP bar color ─────────────────────────────────────────────────

def get_hp_bar_color(ratio: float) -> tuple[int, int, int]:
    """Unified HP bar color based on health ratio.
    Green (>50%), Yellow (>25%), Red (<=25%).
    """
    if ratio > 0.5:
        return (80, 200, 80)
    elif ratio > 0.25:
        return (220, 180, 40)
    return (220, 60, 60)


def get_hp_text_color(ratio: float) -> tuple[int, int, int]:
    """Unified HP text color based on health ratio.
    White (>50%), Yellow (>25%), Red (<=25%).
    """
    if ratio > 0.5:
        return (255, 255, 255)
    elif ratio > 0.25:
        return (255, 220, 60)
    return (255, 80, 80)


# ── Text with outline ────────────────────────────────────────────

def draw_text_with_outline(surface: pygame.Surface, font: pygame.font.Font,
                           text: str, color: tuple[int, int, int],
                           x: int, y: int,
                           outline_color: tuple[int, int, int] = (0, 0, 0),
                           center: bool = False):
    """Draw text with a 4-directional dark outline for readability on any background."""
    shadow = font.render(text, True, outline_color)
    if center:
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            rect = shadow.get_rect(center=(x + dx, y + dy))
            surface.blit(shadow, rect)
        main = font.render(text, True, color)
        surface.blit(main, main.get_rect(center=(x, y)))
    else:
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            surface.blit(shadow, (x + dx, y + dy))
        main = font.render(text, True, color)
        surface.blit(main, (x, y))


# ── Energy circle ────────────────────────────────────────────────

def draw_energy_circle(surface: pygame.Surface, font: pygame.font.Font,
                       center_x: int, center_y: int, radius: int,
                       energy_type: str, label_map: dict[str, str],
                       with_label: bool = True, dark_text: bool = True):
    """Draw a colored energy circle with optional Chinese label.

    Args:
        dark_text: if True, text is black (for light backgrounds).
                   if False, text is white with black outline (for cards with images).
    """
    ec = ENERGY_COLORS.get(energy_type, (200, 200, 200))
    pygame.draw.circle(surface, ec, (center_x, center_y), radius)
    pygame.draw.circle(surface, (0, 0, 0), (center_x, center_y), radius, 1)

    if with_label:
        label = label_map.get(energy_type, energy_type[:1])
        if dark_text:
            txt = font.render(label, True, (0, 0, 0))
            surface.blit(txt, txt.get_rect(center=(center_x, center_y)))
        else:
            draw_text_with_outline(
                surface, font, label, (255, 255, 255),
                center_x, center_y, (0, 0, 0), center=True
            )


# ── Card border ──────────────────────────────────────────────────

def draw_card_border(surface: pygame.Surface, rect: pygame.Rect,
                     hovered: bool = False, selected: bool = False,
                     border_radius: int = 10,
                     hover_color: tuple[int, int, int] = None,
                     selected_color: tuple[int, int, int] = None,
                     normal_color: tuple[int, int, int] = None):
    """Draw a card border with state-aware color and thickness.

    Uses UI_HIGHLIGHT for hovered, gold for selected, UI_BORDER for normal.
    """
    if hover_color is None:
        hover_color = (255, 215, 0)  # UI_HIGHLIGHT
    if selected_color is None:
        selected_color = (255, 200, 60)  # gold
    if normal_color is None:
        normal_color = (100, 100, 140)  # UI_BORDER

    if selected:
        color, width = selected_color, 3
    elif hovered:
        color, width = hover_color, 2
    else:
        color, width = normal_color, 1

    pygame.draw.rect(surface, color, rect, width, border_radius=border_radius)


# ── Status badges on image-backed cards ──────────────────────────

def draw_status_badges_on_image(surface: pygame.Surface, font: pygame.font.Font,
                                x: int, y: int, conditions,
                                status_cn: dict, status_colors: dict,
                                horizontal: bool = True):
    """Draw status badges with colored background and white text on image-backed cards."""
    cur_x, cur_y = x, y
    for status in conditions:
        cn = status_cn.get(status, status.name)
        sc = status_colors.get(status.name.lower(), (200, 200, 200))
        bg_c = tuple(max(0, c - 40) for c in sc)
        badge_w, badge_h = 18, 14
        bg_rect = pygame.Rect(cur_x, cur_y, badge_w, badge_h)
        pygame.draw.rect(surface, bg_c, bg_rect, border_radius=3)
        txt = font.render(cn, True, (255, 255, 255))
        surface.blit(txt, (cur_x + 3, cur_y + 1))
        if horizontal:
            cur_x += badge_w + 1
        else:
            cur_y += badge_h + 2


def draw_small_badge(surface: pygame.Surface, font: pygame.font.Font,
                     text: str, x: int, y: int, bg_color: tuple[int, int, int],
                     text_color: tuple[int, int, int] = (255, 255, 255),
                     radius: int = 3, with_outline: bool = False):
    """Draw a small rectangular badge with text, with optional black outline."""
    txt_surf = font.render(text, True, text_color)
    tw = txt_surf.get_width() + 8
    th = txt_surf.get_height() + 1
    bg_rect = pygame.Rect(x, y, tw, th)
    pygame.draw.rect(surface, bg_color, bg_rect, border_radius=radius)
    if with_outline:
        shadow = font.render(text, True, (0, 0, 0))
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            surface.blit(shadow, (x + 4 + dx, y + dy))
    surface.blit(txt_surf, (x + 4, y))
    return tw


# ── Alpha surface helpers ────────────────────────────────────────

def draw_rect_alpha(surface: pygame.Surface, color: tuple, rect: pygame.Rect,
                    border_radius: int = 0):
    """Draw a rectangle with alpha transparency.

    Works around pygame.draw.rect not supporting RGBA tuples.
    """
    alpha_surf = pygame.Surface(rect.size, pygame.SRCALPHA)
    if border_radius:
        pygame.draw.rect(alpha_surf, color, alpha_surf.get_rect(),
                         border_radius=border_radius)
    else:
        alpha_surf.fill(color)
    surface.blit(alpha_surf, rect.topleft)


# ── Gradient button ──────────────────────────────────────────────

def draw_gradient_button(surface: pygame.Surface, rect: pygame.Rect,
                         hovered: bool = False,
                         top_color: tuple = (60, 80, 140),
                         bot_color: tuple = (40, 55, 110),
                         hover_top_color: tuple = (80, 100, 170),
                         hover_bot_color: tuple = (60, 80, 150),
                         border_color: tuple = None,
                         hover_border_color: tuple = None,
                         border_radius: int = 10,
                         border_width: int = 2,
                         highlight: bool = True):
    """Draw a button with vertical gradient fill and border.

    Shared by TitleScreen, EndScreen, and LobbyScreen.
    """
    if hovered:
        tc, bc = hover_top_color, hover_bot_color
        bc_final = hover_border_color or (255, 215, 0)
    else:
        tc, bc = top_color, bot_color
        bc_final = border_color or (240, 240, 250)

    # Draw to temp surface then blit to keep rounded corners clean
    temp = pygame.Surface(rect.size, pygame.SRCALPHA)
    for i in range(rect.h):
        t_val = i / rect.h
        r = int(tc[0] + (bc[0] - tc[0]) * t_val)
        g = int(tc[1] + (bc[1] - tc[1]) * t_val)
        b = int(tc[2] + (bc[2] - tc[2]) * t_val)
        pygame.draw.line(temp, (r, g, b), (0, i), (rect.w - 1, i))

    # Mask to rounded rect
    mask = pygame.Surface(rect.size, pygame.SRCALPHA)
    pygame.draw.rect(mask, (255, 255, 255, 255), mask.get_rect(),
                     border_radius=border_radius)
    temp.blit(mask, (0, 0), special_flags=pygame.BLEND_RGBA_MULT)
    surface.blit(temp, rect.topleft)

    pygame.draw.rect(surface, bc_final, rect, border_width, border_radius=border_radius)

    if highlight:
        hl_y = rect.y + 1
        hl_color = (min(255, tc[0] + 60), min(255, tc[1] + 60), min(255, tc[2] + 60))
        pygame.draw.line(surface, hl_color, (rect.x + 6, hl_y), (rect.x + rect.w - 6, hl_y), 1)


# ── Clipping context manager ─────────────────────────────────────

@contextmanager
def clipped(surface: pygame.Surface, rect: pygame.Rect):
    """Context manager for safe pygame surface clipping.

    Restores clip state even if an exception occurs during drawing.
    """
    try:
        surface.set_clip(rect)
        yield
    finally:
        surface.set_clip(None)

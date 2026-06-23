"""Action log panel rendering."""
import pygame
from config import SCREEN_WIDTH, SCREEN_HEIGHT
from ui.colors import (
    UI_BG_DARK, UI_BORDER, UI_TEXT_SECONDARY, UI_HIGHLIGHT,
    PLAYER1_COLOR, PLAYER2_COLOR,
)
from ui.components.game_layout import (
    LOG_W, LOG_X,
)
from ui.layout_model import DEFAULT_GAME_LAYOUT
from ui.ui_theme import draw_panel, draw_text_fit

def draw_action_log(gs, surface):

    layout = getattr(gs, "layout", DEFAULT_GAME_LAYOUT)
    panel_rect = layout.log_panel
    inner = draw_panel(surface, panel_rect, "行动日志", gs.font_small)
    log_y = inner.y
    log_h = inner.h

    # Clamp scroll offset
    all_logs = gs.state.action_log
    total_lines = len(all_logs)
    max_visible = max(1, log_h // 17)
    max_scroll = max(0, total_lines - max_visible)
    gs._log_scroll_offset = max(0, min(gs._log_scroll_offset, max_scroll))

    # Detect new entries for fade-in (uses per-instance state)
    last_count = getattr(gs, '_log_panel_last_count', 0)
    new_entry_count = total_lines - last_count
    gs._log_panel_last_count = total_lines

    y = log_y
    start_idx = total_lines - max_visible - gs._log_scroll_offset
    start_idx = max(0, start_idx)
    visible_logs = all_logs[start_idx:start_idx + max_visible]
    for i, entry in enumerate(visible_logs):
        actual_idx = start_idx + i

        # Alternating row background
        if i % 2 == 0:
            row_surf = pygame.Surface((inner.w, 16), pygame.SRCALPHA)
            row_surf.fill((40, 40, 60, 40))
            surface.blit(row_surf, (inner.x, y - 1))

        # Player color indicator dot
        if "玩家1" in entry:
            dot_color = PLAYER1_COLOR
        elif "玩家2" in entry:
            dot_color = PLAYER2_COLOR
        else:
            dot_color = None

        if dot_color:
            pygame.draw.circle(surface, dot_color, (inner.x + 6, y + 7), 3)

        # Last entry is slightly brighter (fade-in for new entries)
        is_newest = actual_idx == total_lines - 1 and new_entry_count > 0
        text_color = UI_TEXT_SECONDARY
        if is_newest:
            bright = min(255, 170 + new_entry_count * 40)
            text_color = (bright, bright, bright)

        text_rect = pygame.Rect(inner.x + (16 if dot_color else 2), y,
                                inner.w - (22 if dot_color else 8), 16)
        draw_text_fit(surface, gs.font_card_tiny, entry, text_color, text_rect)
        y += 17

    # Scroll bar
    if total_lines > max_visible:
        bar_h = max(20, int(max_visible / total_lines * log_h))
        bar_y_pos = log_y + int(gs._log_scroll_offset / max_scroll * max(1, log_h - bar_h))
        pygame.draw.rect(surface, UI_BORDER,
                         (inner.right - 6, bar_y_pos, 5, bar_h), border_radius=2)

    # Floating text overlay (not in the log panel area, rendered on game screen now)
    # gs.floating_text.draw(surface, gs.font_small)

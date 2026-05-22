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

def draw_action_log(gs, surface):

    log_y = 8
    log_h = SCREEN_HEIGHT - 16

    # Panel background with subtle gradient
    panel_rect = pygame.Rect(LOG_X, log_y, LOG_W, log_h)
    for gy in range(log_h):
        t = gy / log_h
        r = int(UI_BG_DARK[0] + 3 * t)
        g = int(UI_BG_DARK[1] + 3 * t)
        b = int(UI_BG_DARK[2] + 5 * t)
        pygame.draw.line(surface, (r, g, b),
                        (LOG_X, log_y + gy), (LOG_X + LOG_W, log_y + gy))
    pygame.draw.rect(surface, UI_BORDER, panel_rect, 1, border_radius=5)

    txt = gs.font_small.render("— 行动日志 —", True, UI_HIGHLIGHT)
    surface.blit(txt, (LOG_X + 8, log_y + 6))

    # Clamp scroll offset
    all_logs = gs.state.action_log
    total_lines = len(all_logs)
    max_visible = (log_h - 32) // 16
    max_scroll = max(0, total_lines - max_visible)
    gs._log_scroll_offset = max(0, min(gs._log_scroll_offset, max_scroll))

    # Detect new entries for fade-in (uses per-instance state)
    last_count = getattr(gs, '_log_panel_last_count', 0)
    new_entry_count = total_lines - last_count
    gs._log_panel_last_count = total_lines

    y = log_y + 28
    start_idx = total_lines - max_visible - gs._log_scroll_offset
    start_idx = max(0, start_idx)
    visible_logs = all_logs[start_idx:start_idx + max_visible]
    for i, entry in enumerate(visible_logs):
        actual_idx = start_idx + i

        # Alternating row background
        if i % 2 == 0:
            row_surf = pygame.Surface((LOG_W - 4, 15), pygame.SRCALPHA)
            row_surf.fill((40, 40, 60, 40))
            surface.blit(row_surf, (LOG_X + 2, y - 1))

        # Player color indicator dot
        if "玩家1" in entry:
            dot_color = PLAYER1_COLOR
        elif "玩家2" in entry:
            dot_color = PLAYER2_COLOR
        else:
            dot_color = None

        if dot_color:
            pygame.draw.circle(surface, dot_color, (LOG_X + 8, y + 7), 3)

        # Last entry is slightly brighter (fade-in for new entries)
        is_newest = actual_idx == total_lines - 1 and new_entry_count > 0
        text_color = UI_TEXT_SECONDARY
        if is_newest:
            bright = min(255, 170 + new_entry_count * 40)
            text_color = (bright, bright, bright)

        line_txt = gs.font_card_tiny.render(entry[:55], True, text_color)
        surface.blit(line_txt, (LOG_X + (16 if dot_color else 4), y))
        y += 16

    # Scroll bar
    if total_lines > max_visible:
        bar_h = max(20, int(max_visible / total_lines * (log_h - 32)))
        bar_y_pos = log_y + 28 + int(gs._log_scroll_offset / max_scroll * (log_h - 40 - bar_h))
        pygame.draw.rect(surface, UI_BORDER,
                         (LOG_X + LOG_W - 8, bar_y_pos, 5, bar_h), border_radius=2)

    # Floating text overlay (not in the log panel area, rendered on game screen now)
    # gs.floating_text.draw(surface, gs.font_small)

"""回合交替画面——热座模式下隐藏棋盘."""
import math
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_BG_DARK, UI_TEXT_SECONDARY,
    PLAYER1_COLOR, PLAYER2_COLOR,
)
from ui.font_manager import get_font
from ui.ui_theme import draw_panel, draw_button
from config import SCREEN_WIDTH, SCREEN_HEIGHT


class PassScreen(Screen):
    """回合间全屏遮罩，隐藏棋盘防止对手偷看."""

    def __init__(self, manager: ScreenManager, next_player: int,
                 on_continue: callable, game_state=None, turn_number: int = 0):
        super().__init__(manager)
        self.next_player = next_player
        self.on_continue = on_continue
        self.game_state = game_state
        self.turn_number = turn_number
        self.font_title = get_font("title_md")
        self.font_body = get_font("body_lg")
        self.font_small = get_font("body_sm")
        self.pulse = 0.0

        # Sidebars
        self.sidebar_w = 60
        self.player_color = PLAYER1_COLOR if next_player == 0 else PLAYER2_COLOR

    def handle_event(self, event: pygame.event.Event):
        if event.type == pygame.KEYDOWN and event.key == pygame.K_SPACE:
            self.on_continue()
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self.on_continue()

    def update(self, dt: float):
        self.pulse += dt

    def draw(self, surface: pygame.Surface):
        surface.fill(UI_BG_DARK)

        # Side bars with player color
        pc = self.player_color
        sidebar = pygame.Surface((self.sidebar_w, SCREEN_HEIGHT), pygame.SRCALPHA)
        for i in range(SCREEN_HEIGHT):
            t = i / SCREEN_HEIGHT
            alpha = int(30 + 15 * math.sin(t * math.pi))
            r, g, b = pc
            pygame.draw.line(sidebar, (r, g, b, alpha), (0, i), (self.sidebar_w, i))
        surface.blit(sidebar, (0, 0))
        surface.blit(sidebar, (SCREEN_WIDTH - self.sidebar_w, 0))

        # Side bar accent lines
        bar_alpha = int(80 + 40 * math.sin(self.pulse * 2.0))
        bar_color = (*pc, bar_alpha)
        accent_surf = pygame.Surface((4, SCREEN_HEIGHT), pygame.SRCALPHA)
        accent_surf.fill(bar_color)
        surface.blit(accent_surf, (self.sidebar_w, 0))
        surface.blit(accent_surf, (SCREEN_WIDTH - self.sidebar_w - 4, 0))

        panel_rect = pygame.Rect(SCREEN_WIDTH // 2 - 380, SCREEN_HEIGHT // 2 - 210, 760, 420)
        draw_panel(surface, panel_rect)

        # Main turn banner
        player_name = f"玩家{self.next_player + 1}"
        player_color_text = PLAYER1_COLOR if self.next_player == 0 else PLAYER2_COLOR

        turn_str = f"第{self.turn_number}回合 — {player_name}的回合开始"
        title_txt = self.font_title.render(turn_str, True, player_color_text)
        title_rect = title_txt.get_rect(center=(SCREEN_WIDTH // 2, panel_rect.y + 78))
        surface.blit(title_txt, title_rect)

        # Decorative line under title
        line_w = min(300, title_txt.get_width())
        line_y = title_rect.bottom + 18
        line_alpha = int(100 + 80 * math.sin(self.pulse * 2.5))
        line_color = (*player_color_text, min(255, line_alpha))
        line_surf = pygame.Surface((line_w, 2), pygame.SRCALPHA)
        line_surf.fill(line_color)
        surface.blit(line_surf, (SCREEN_WIDTH // 2 - line_w // 2, line_y))

        # Player icon/indicator
        icon_size = 50
        icon_y = panel_rect.y + 150
        icon_surf = pygame.Surface((icon_size, icon_size), pygame.SRCALPHA)
        pygame.draw.circle(icon_surf, (*pc, 180), (icon_size // 2, icon_size // 2), icon_size // 2)
        pygame.draw.circle(icon_surf, (255, 255, 255, 200), (icon_size // 2, icon_size // 2), icon_size // 2, 2)
        num_txt = self.font_title.render(str(self.next_player + 1), True, (255, 255, 255))
        surface.blit(icon_surf, (SCREEN_WIDTH // 2 - icon_size // 2, icon_y))
        surface.blit(num_txt, num_txt.get_rect(center=(SCREEN_WIDTH // 2, icon_y + icon_size // 2)))

        prompt_text = "点击屏幕或按空格键开始"
        prompt_rect = pygame.Rect(SCREEN_WIDTH // 2 - 180, panel_rect.y + 245, 360, 42)
        draw_button(surface, prompt_rect, prompt_text, self.font_body,
                    hovered=True, enabled=True)

        reminder_text = "对手操作时请移开视线，避免看到对方的棋盘信息"
        reminder = self.font_small.render(reminder_text, True, UI_TEXT_SECONDARY)
        reminder_rect = reminder.get_rect(
            center=(SCREEN_WIDTH // 2, panel_rect.bottom - 62)
        )
        surface.blit(reminder, reminder_rect)

"""Help / game rules overlay screen."""
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_BG_DARK, UI_TEXT_PRIMARY, UI_HIGHLIGHT,
    PLAYER1_COLOR, PLAYER2_COLOR,
)
from ui.font_manager import get_font
from config import SCREEN_WIDTH, SCREEN_HEIGHT
from ui.transitions import SlideTransition
from ui.ui_theme import draw_panel, draw_button


class HelpScreen(Screen):
    """Overlay showing game rules and controls."""

    def __init__(self, manager: ScreenManager):
        super().__init__(manager)
        self.font_title = get_font("heading")
        self.font_body = get_font("body_sm")
        self.font_small = get_font("normal")

        self.back_btn = pygame.Rect(SCREEN_WIDTH // 2 - 100, SCREEN_HEIGHT - 80, 200, 45)
        self.back_hover = False

        self._sections = [
            ("游戏目标",
             ["击败对手的所有宝可梦，或获得6张奖品卡即可获胜。"]),
            ("牌组构成",
             ["一副牌组包含60张卡牌，同名牌最多4张。"]),
            ("游戏流程",
             ["1. 准备阶段: 放置基础宝可梦到战斗区和备战区",
              "2. 抽牌阶段: 从牌库抽1张卡",
              "3. 主要阶段: 打出宝可梦、附着能量、使用训练家卡",
              "4. 攻击阶段: 使用招式攻击对手",
              "5. 宝可梦检测: 检查状态和击倒"]),
            ("属性克制/抵抗",
             ["默认关闭；可在主页面开关中开启。",
              "联机对战按主机设置；AI挑战固定关闭。"]),
            ("快捷键",
             ["1-9: 选手牌   A: 攻击   E: 结束回合",
              "R: 撤退   Space: 确认   Esc: 取消",
              "Ctrl+Z: 撤销   Tab: 切换速度   Q: 退出"]),
        ]

    def handle_event(self, event):
        if event.type == pygame.MOUSEMOTION:
            self.back_hover = self.back_btn.collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self.back_hover:
                self.manager.pop_screen(SlideTransition(0.3, "left"))
        elif event.type == pygame.KEYDOWN:
            if event.key in (pygame.K_ESCAPE, pygame.K_BACKSPACE):
                self.manager.pop_screen(SlideTransition(0.3, "left"))

    def update(self, dt: float):
        pass

    def draw(self, surface):
        # Semi-transparent overlay background
        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((10, 10, 30, 230))
        surface.blit(overlay, (0, 0))
        draw_panel(surface, pygame.Rect(SCREEN_WIDTH // 2 - 330, 28, 660, SCREEN_HEIGHT - 120))

        # Title
        title = self.font_title.render("游戏规则", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(SCREEN_WIDTH // 2, 50)))

        # Decorative line under title
        line_w = 200
        line_y = 72
        pygame.draw.line(surface, UI_HIGHLIGHT, (SCREEN_WIDTH // 2 - line_w // 2, line_y),
                         (SCREEN_WIDTH // 2 + line_w // 2, line_y), 2)

        # Sections
        y = 100
        for heading, lines in self._sections:
            h = self.font_body.render(heading, True, UI_HIGHLIGHT)
            surface.blit(h, (SCREEN_WIDTH // 2 - 280, y))
            y += 32
            for line in lines:
                t = self.font_small.render(line, True, UI_TEXT_PRIMARY)
                surface.blit(t, (SCREEN_WIDTH // 2 - 260, y))
                y += 22
            y += 12

        # Back button
        draw_button(surface, self.back_btn, "返回", self.font_body,
                    hovered=self.back_hover)

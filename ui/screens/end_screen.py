"""结束画面——显示胜负结果."""
import math
import random
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_BG_DARK, UI_TEXT_PRIMARY, UI_HIGHLIGHT, UI_BUTTON, UI_BUTTON_HOVER,
    PLAYER1_COLOR, PLAYER2_COLOR, VICTORY_GOLD_LIGHT, VICTORY_GOLD_DARK,
)
from ui.font_manager import get_font, get_font_size
from ui.render_helpers import draw_gradient_button
from config import SCREEN_WIDTH, SCREEN_HEIGHT


class EndScreen(Screen):
    """游戏结束画面."""

    def __init__(self, manager: ScreenManager, winner_idx: int,
                 win_reason: str, prizes_taken: tuple[int, int],
                 network_manager=None, is_remote: bool = False):
        super().__init__(manager)
        self.winner_idx = winner_idx
        self.win_reason = win_reason
        self.prizes_taken = prizes_taken
        self.network_manager = network_manager
        self.is_remote = is_remote
        self.font_title = get_font("title_xl")
        self.font_body = get_font("subtitle")
        self.font_small = get_font("body_md")

        btn_w, btn_h = 250, 55
        self.rematch_btn = pygame.Rect(
            SCREEN_WIDTH // 2 - btn_w - 20, SCREEN_HEIGHT // 2 + 80, btn_w, btn_h
        )
        self.quit_btn = pygame.Rect(
            SCREEN_WIDTH // 2 + 20, SCREEN_HEIGHT // 2 + 80, btn_w, btn_h
        )
        self.rematch_hover = False
        self.quit_hover = False

        self._time = 0.0
        self.winner_color = PLAYER1_COLOR if winner_idx == 0 else PLAYER2_COLOR

        # Victory confetti particles (simple golden dots)
        self._particles = []
        for _ in range(40):
            self._particles.append({
                "x": random.uniform(0, SCREEN_WIDTH),
                "y": random.uniform(-SCREEN_HEIGHT, 0),
                "vx": random.uniform(-60, 60),
                "vy": random.uniform(40, 120),
                "size": random.uniform(2, 6),
                "color": random.choice([
                    VICTORY_GOLD_LIGHT, VICTORY_GOLD_DARK,
                    (255, 255, 255), (255, 200, 80),
                    (*PLAYER1_COLOR,), (*PLAYER2_COLOR,),
                ]),
                "phase": random.uniform(0, math.pi * 2),
            })

    def handle_event(self, event: pygame.event.Event):
        if event.type == pygame.MOUSEMOTION:
            self.rematch_hover = self.rematch_btn.collidepoint(event.pos)
            self.quit_hover = self.quit_btn.collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self.rematch_hover:
                self._rematch()
            elif self.quit_hover:
                self._quit_to_title()

    def _rematch(self):
        if self.network_manager:
            self.network_manager.stop()
        from ui.screens.title_screen import TitleScreen
        self.manager.clear_to(TitleScreen(self.manager))

    def _quit_to_title(self):
        if self.network_manager:
            self.network_manager.stop()
        from ui.screens.title_screen import TitleScreen
        self.manager.clear_to(TitleScreen(self.manager))

    def update(self, dt: float):
        self._time += dt
        for p in self._particles:
            p["x"] += p["vx"] * dt
            p["y"] += p["vy"] * dt
            p["vy"] += 30 * dt  # gravity
            if p["y"] > SCREEN_HEIGHT + 20:
                p["y"] = -20
                p["x"] = random.uniform(0, SCREEN_WIDTH)

    def draw(self, surface: pygame.Surface):
        # Golden gradient background
        for y in range(SCREEN_HEIGHT):
            t = y / SCREEN_HEIGHT
            r = int(VICTORY_GOLD_DARK[0] + (UI_BG_DARK[0] - VICTORY_GOLD_DARK[0]) * t)
            g = int(VICTORY_GOLD_DARK[1] + (UI_BG_DARK[1] - VICTORY_GOLD_DARK[1]) * t)
            b = int(VICTORY_GOLD_DARK[2] + (UI_BG_DARK[2] - VICTORY_GOLD_DARK[2]) * t)
            pygame.draw.line(surface, (r, g, b), (0, y), (SCREEN_WIDTH, y))

        # Victory confetti
        for p in self._particles:
            alpha = int(150 + 80 * math.sin(self._time * 4.0 + p["phase"]))
            alpha = max(0, min(255, alpha))
            color = (*p["color"][:3], alpha) if len(p["color"]) == 3 else p["color"]
            p_surf = pygame.Surface((int(p["size"] * 2), int(p["size"] * 2)), pygame.SRCALPHA)
            if random.random() < 0.3:
                # Rectangular confetti pieces
                pygame.draw.rect(p_surf, color, (0, 0, int(p["size"] * 2), int(p["size"])))
            else:
                # Circular confetti
                pygame.draw.circle(p_surf, color, (int(p["size"]), int(p["size"])), int(p["size"]))
            surface.blit(p_surf, (int(p["x"]), int(p["y"])))

        # Winner crown / accent line
        crown_y = SCREEN_HEIGHT // 3 - 50
        crown_alpha = int(100 + 60 * math.sin(self._time * 2.0))
        pygame.draw.line(
            surface, (*VICTORY_GOLD_LIGHT, crown_alpha),
            (SCREEN_WIDTH // 2 - 200, crown_y),
            (SCREEN_WIDTH // 2 + 200, crown_y), 2
        )

        # Winner text with scale bounce effect
        bounce_scale = 1.0 + 0.05 * math.sin(self._time * 3.0)
        winner_text = f"玩家{self.winner_idx + 1} 获胜！"
        title_font_size = int(64 * bounce_scale)
        try:
            title_font = get_font_size(title_font_size, bold=True)
        except Exception:
            title_font = self.font_title  # fallback
        title_txt = title_font.render(winner_text, True, self.winner_color)
        title_rect = title_txt.get_rect(center=(SCREEN_WIDTH // 2, SCREEN_HEIGHT // 3))
        surface.blit(title_txt, title_rect)

        # Glow effect behind title
        glow_alpha = int(30 + 25 * math.sin(self._time * 2.0))
        glow_surf = title_font.render(winner_text, True, VICTORY_GOLD_LIGHT)
        glow_surf.set_alpha(glow_alpha)
        for dx, dy in [(-3, 0), (3, 0), (0, -3), (0, 3), (-2, -2), (2, 2)]:
            surface.blit(glow_surf, glow_surf.get_rect(center=(SCREEN_WIDTH // 2 + dx, SCREEN_HEIGHT // 3 + dy)))

        reason_txt = self.font_body.render(
            f"胜利方式: {self.win_reason}", True, UI_TEXT_PRIMARY
        )
        reason_rect = reason_txt.get_rect(center=(SCREEN_WIDTH // 2, SCREEN_HEIGHT // 3 + 60))
        surface.blit(reason_txt, reason_rect)

        prizes_txt = self.font_small.render(
            f"奖品卡获得 - 玩家1: {self.prizes_taken[0]}张 | 玩家2: {self.prizes_taken[1]}张",
            True, UI_TEXT_PRIMARY
        )
        prizes_rect = prizes_txt.get_rect(center=(SCREEN_WIDTH // 2, SCREEN_HEIGHT // 3 + 100))
        surface.blit(prizes_txt, prizes_rect)

        # Rematch button with gradient
        draw_gradient_button(surface, self.rematch_btn, self.rematch_hover)
        rt = self.font_body.render("再来一局", True, UI_TEXT_PRIMARY)
        surface.blit(rt, rt.get_rect(center=self.rematch_btn.center))

        # Quit button with gradient
        draw_gradient_button(surface, self.quit_btn, self.quit_hover)
        qt = self.font_body.render("返回标题", True, UI_TEXT_PRIMARY)
        surface.blit(qt, qt.get_rect(center=self.quit_btn.center))


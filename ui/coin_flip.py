"""Coin flip animation for PTCG card effects — supports sequential multi-flip."""
import math
import random
import pygame
from config import SCREEN_WIDTH, SCREEN_HEIGHT
from ui.colors import UI_TEXT_PRIMARY, UI_HIGHLIGHT, VICTORY_GOLD_LIGHT


class CoinFlipAnimation:
    """Visual coin flip sequence with 3D rotation illusion and sparkle effects.
    Supports multiple sequential flips (e.g. 三连突刺 flips 3 coins).
    """

    def __init__(self):
        self.active = False
        self.flip_count = 1
        self.flip_index = 0
        self.results: list[bool] = []
        self.on_result: callable = None
        self.until_tails = False  # Continue flipping until tails appears

        # Single flip state
        self.phase = "idle"  # idle -> flipping -> showing -> (next flip or done)
        self.elapsed = 0.0
        self.result: bool | None = None
        self.flip_duration = 0.7
        self.show_duration = 0.6
        self.coin_radius = 50
        self.center_x = SCREEN_WIDTH // 2
        self.center_y = SCREEN_HEIGHT // 2 - 50

        self._sparkles: list[dict] = []

    def start(self, flip_count: int = 1, on_result: callable = None,
              until_tails: bool = False):
        """Begin a coin flip sequence.
        If until_tails is True, keeps flipping until tails appears (min 1 flip)."""
        self.active = True
        self.until_tails = until_tails
        self.flip_count = flip_count  # Initial count, may be extended if until_tails
        self.flip_index = 0
        self.results = []
        self.on_result = on_result
        self._start_flip()

    def _start_flip(self):
        """Begin the current coin flip animation."""
        self.result = random.random() >= 0.5
        self.phase = "flipping"
        self.elapsed = 0.0
        self._sparkles.clear()

        for _ in range(20):
            angle = random.uniform(0, math.pi * 2)
            dist = random.uniform(30, 80)
            self._sparkles.append({
                "x": self.center_x + math.cos(angle) * dist,
                "y": self.center_y + math.sin(angle) * dist,
                "target_x": self.center_x + math.cos(angle) * (dist + 60),
                "target_y": self.center_y + math.sin(angle) * (dist + 60) - 120,
                "size": random.uniform(2, 5),
                "alpha": random.randint(180, 255),
                "speed": random.uniform(0.8, 1.5),
            })

    def skip(self):
        """Skip current flip animation, jump to result."""
        if self.phase == "flipping":
            self.phase = "showing"
            self.elapsed = 0.0
        elif self.phase == "showing":
            self._on_flip_done()

    def _on_flip_done(self):
        """Called when current flip animation finishes."""
        self.results.append(self.result)
        self.flip_index += 1
        if self.until_tails and self.result:
            # Got heads, flip again
            self._start_flip()
        elif self.flip_index < self.flip_count:
            self._start_flip()
        else:
            # All flips done
            self.phase = "done"
            self.active = False
            if self.on_result:
                cb = self.on_result
                self.on_result = None
                cb(self.results)

    def update(self, dt: float):
        if not self.active:
            return
        self.elapsed += dt

        if self.phase == "flipping":
            if self.elapsed >= self.flip_duration:
                self.phase = "showing"
                self.elapsed = 0.0
        elif self.phase == "showing":
            if self.elapsed >= self.show_duration:
                self._on_flip_done()

    def handle_event(self, event: pygame.event.Event) -> bool:
        if not self.active:
            return False
        return True

    def draw(self, surface: pygame.Surface, font: pygame.font.Font):
        if not self.active:
            return

        # Dim background overlay
        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((0, 0, 0, 120))
        surface.blit(overlay, (0, 0))

        cx, cy = self.center_x, self.center_y

        # Flip counter indicator
        if self.flip_count > 1:
            counter_str = f"第 {self.flip_index + 1}/{self.flip_count} 次"
            counter_txt = font.render(counter_str, True, UI_HIGHLIGHT)
            surface.blit(counter_txt, counter_txt.get_rect(center=(cx, cy - 120)))

        if self.phase == "flipping":
            flip_t = self.elapsed / self.flip_duration
            arc_height = 120
            y_offset = -arc_height * 4 * flip_t * (1 - flip_t)
            h_scale = abs(math.cos(flip_t * math.pi * 3))
            h_scale = 0.15 + h_scale * 0.85

            coin_w = int(self.coin_radius * 2 * h_scale)
            coin_h = self.coin_radius * 2

            coin_surf = pygame.Surface((coin_w + 4, coin_h + 4), pygame.SRCALPHA)
            if coin_w > 1:
                pygame.draw.ellipse(coin_surf, VICTORY_GOLD_LIGHT,
                                  (2, 2, coin_w, coin_h))
                pygame.draw.ellipse(coin_surf, (180, 140, 20),
                                  (2, 2, coin_w, coin_h), 2)
                if h_scale > 0.4:
                    inner_w = int(coin_w * 0.7)
                    inner_h = int(coin_h * 0.7)
                    inner_x = (coin_w - inner_w) // 2 + 2
                    inner_y = (coin_h - inner_h) // 2 + 2
                    pygame.draw.ellipse(coin_surf, (200, 170, 40),
                                      (inner_x, inner_y, inner_w, inner_h), 1)

            coin_rect = coin_surf.get_rect(center=(cx, cy + y_offset))
            surface.blit(coin_surf, coin_rect)

            label = font.render("掷硬币中...", True, UI_TEXT_PRIMARY)
            surface.blit(label, label.get_rect(center=(cx, cy + 80)))

        elif self.phase == "showing":
            show_t = min(1.0, self.elapsed / 0.3)
            bounce = 1.0 + 0.15 * (1 - show_t) * math.cos(show_t * math.pi * 2)

            # Draw coin face with distinct heads/tails design
            coin_color_bg = (240, 200, 60) if self.result else (180, 170, 160)
            coin_color_rim = (180, 140, 20) if self.result else (130, 120, 110)
            coin_color_inner = (255, 220, 80) if self.result else (200, 190, 180)

            pygame.draw.circle(surface, coin_color_bg, (cx, cy), self.coin_radius)
            pygame.draw.circle(surface, coin_color_rim, (cx, cy), self.coin_radius, 2)
            pygame.draw.circle(surface, coin_color_inner, (cx, cy), int(self.coin_radius * 0.75), 1)

            if self.result:
                # Heads: gold coin with a star/sunburst
                inner_r = int(self.coin_radius * 0.4)
                for i in range(8):
                    angle = i * math.pi / 4
                    sx = cx + int(math.cos(angle) * inner_r)
                    sy = cy + int(math.sin(angle) * inner_r)
                    ex = cx + int(math.cos(angle) * self.coin_radius * 0.85)
                    ey = cy + int(math.sin(angle) * self.coin_radius * 0.85)
                    pygame.draw.line(surface, (200, 150, 30), (sx, sy), (ex, ey), 2)
                pygame.draw.circle(surface, (240, 200, 50), (cx, cy), inner_r)
                pygame.draw.circle(surface, (200, 150, 30), (cx, cy), inner_r, 1)
                result_str = "正面！"
                result_color = VICTORY_GOLD_LIGHT
            else:
                # Tails: silver coin with concentric circles
                for r_ratio in (0.3, 0.5, 0.7):
                    r = int(self.coin_radius * r_ratio)
                    pygame.draw.circle(surface, (150, 140, 130), (cx, cy), r, 1)
                # Cross pattern
                pygame.draw.line(surface, (150, 140, 130),
                               (cx - int(self.coin_radius * 0.6), cy),
                               (cx + int(self.coin_radius * 0.6), cy), 1)
                pygame.draw.line(surface, (150, 140, 130),
                               (cx, cy - int(self.coin_radius * 0.6)),
                               (cx, cy + int(self.coin_radius * 0.6)), 1)
                result_str = "反面..."
                result_color = (160, 160, 180)

            result_font_size = int(36 * bounce)
            result_txt = font.render(result_str, True, result_color)
            result_rect = result_txt.get_rect(center=(cx, cy))
            surface.blit(result_txt, result_rect)

            # Sparkle particles
            for sp in self._sparkles:
                t = min(1.0, self.elapsed / sp["speed"])
                spx = sp["x"] + (sp["target_x"] - sp["x"]) * t
                spy = sp["y"] + (sp["target_y"] - sp["y"]) * t
                alpha = int(sp["alpha"] * (1 - t))
                if alpha > 0 and sp["size"] > 0.5:
                    sp_surf = pygame.Surface((int(sp["size"] * 2), int(sp["size"] * 2)), pygame.SRCALPHA)
                    pygame.draw.circle(sp_surf, (*VICTORY_GOLD_LIGHT, alpha),
                                     (int(sp["size"]), int(sp["size"])), int(sp["size"]))
                    surface.blit(sp_surf, (int(spx), int(spy)))


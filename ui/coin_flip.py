"""Coin flip animation for PTCG card effects."""
from __future__ import annotations

import math
import random

import pygame

from config import SCREEN_WIDTH, SCREEN_HEIGHT
from ui.colors import UI_TEXT_PRIMARY, UI_TEXT_SECONDARY, UI_HIGHLIGHT, VICTORY_GOLD_LIGHT


def _ease_out_cubic(t: float) -> float:
    return 1 - (1 - t) ** 3


class CoinFlipAnimation:
    """Sequential coin flip animation with a callback-compatible API."""

    def __init__(self):
        self.active = False
        self.flip_count = 1
        self.flip_index = 0
        self.results: list[bool] = []
        self.on_result: callable | None = None
        self.until_tails = False

        self.phase = "idle"  # idle -> flipping -> showing -> summary -> done
        self.elapsed = 0.0
        self.result: bool | None = None
        self.flip_duration = 0.95
        self.show_duration = 0.78
        self.summary_duration = 0.55
        self.coin_radius = 56
        self.center_x = SCREEN_WIDTH // 2
        self.center_y = SCREEN_HEIGHT // 2 - 50

        self._sparkles: list[dict] = []
        self._trail: list[dict] = []
        self._spin_dir = 1
        self._wobble_phase = 0.0

    def start(self, flip_count: int = 1, on_result: callable = None,
              until_tails: bool = False, predetermined: list[bool] | None = None):
        """Begin a coin flip sequence.

        If *predetermined* is provided, the sequence uses those results
        instead of generating random ones. This lets the host decide coin
        outcomes so that a cheating client cannot force favorable flips.
        """
        self.active = True
        self.until_tails = until_tails
        self._predetermined = list(predetermined) if predetermined else None
        if predetermined:
            self.flip_count = len(predetermined)
        else:
            self.flip_count = max(1, flip_count)
        self.flip_index = 0
        self.results = []
        self.on_result = on_result
        self._start_flip()

    def _start_flip(self):
        if self._predetermined and self.flip_index < len(self._predetermined):
            self.result = self._predetermined[self.flip_index]
        else:
            self.result = random.random() >= 0.5
        self.phase = "flipping"
        self.elapsed = 0.0
        self._sparkles.clear()
        self._trail.clear()
        self._spin_dir = 1 if random.random() >= 0.5 else -1
        self._wobble_phase = random.uniform(0, math.pi * 2)

    def skip(self):
        """Advance the current visual phase without changing the result."""
        if self.phase == "flipping":
            self.phase = "showing"
            self.elapsed = 0.0
            self._spawn_result_burst()
        elif self.phase == "showing":
            self._finish_current_flip()
        elif self.phase == "summary":
            self._finish_sequence()

    def _spawn_result_burst(self):
        self._sparkles.clear()
        color = VICTORY_GOLD_LIGHT if self.result else (190, 205, 235)
        for _ in range(34):
            angle = random.uniform(0, math.pi * 2)
            speed = random.uniform(55, 155)
            self._sparkles.append({
                "angle": angle,
                "speed": speed,
                "size": random.uniform(2.0, 5.0),
                "life": random.uniform(0.45, 0.95),
                "color": color,
                "drift": random.uniform(-25, 25),
            })

    def _finish_current_flip(self):
        self.results.append(bool(self.result))
        self.flip_index += 1
        if self.until_tails and self.result:
            self._start_flip()
        elif self.flip_index < self.flip_count:
            self._start_flip()
        else:
            self.phase = "summary"
            self.elapsed = 0.0

    def _finish_sequence(self):
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
            self._record_trail()
            if self.elapsed >= self.flip_duration:
                self.phase = "showing"
                self.elapsed = 0.0
                self._spawn_result_burst()
        elif self.phase == "showing":
            if self.elapsed >= self.show_duration:
                self._finish_current_flip()
        elif self.phase == "summary":
            if self.elapsed >= self.summary_duration:
                self._finish_sequence()

    def handle_event(self, event: pygame.event.Event) -> bool:
        if not self.active:
            return False
        if event.type in (pygame.MOUSEBUTTONDOWN, pygame.KEYDOWN):
            self.skip()
        return True

    def _flip_state(self, t: float) -> tuple[int, int, float, float]:
        t = max(0.0, min(1.0, t))
        lift = -148 * math.sin(math.pi * t)
        settle = 22 * _ease_out_cubic(max(0.0, t - 0.72) / 0.28)
        wobble = math.sin(t * math.pi * 2 + self._wobble_phase) * 18 * (1 - t)
        cx = int(self.center_x + wobble)
        cy = int(self.center_y + lift + settle)
        spin = t * math.pi * 8.5 * self._spin_dir
        scale_x = 0.12 + abs(math.cos(spin)) * 0.88
        tilt = math.sin(spin) * 0.18
        return cx, cy, scale_x, tilt

    def _record_trail(self):
        t = min(1.0, self.elapsed / self.flip_duration)
        cx, cy, scale_x, _ = self._flip_state(t)
        self._trail.append({
            "x": cx,
            "y": cy,
            "scale_x": scale_x,
            "age": 0.0,
        })
        if len(self._trail) > 9:
            self._trail.pop(0)
        for item in self._trail:
            item["age"] += 1 / 60

    def _draw_coin(self, surface: pygame.Surface, cx: int, cy: int,
                   radius: int, scale_x: float, result: bool | None,
                   alpha: int = 255):
        w = max(8, int(radius * 2 * scale_x))
        h = max(8, radius * 2)
        coin = pygame.Surface((w + 8, h + 8), pygame.SRCALPHA)
        rect = pygame.Rect(4, 4, w, h)

        heads = bool(result)
        bg = (244, 203, 68) if heads else (186, 190, 200)
        rim = (168, 116, 24) if heads else (104, 112, 128)
        inner = (255, 229, 112) if heads else (220, 226, 236)

        pygame.draw.ellipse(coin, (*bg, alpha), rect)
        pygame.draw.ellipse(coin, (*rim, alpha), rect, 3)
        inset = rect.inflate(-max(4, w // 5), -max(4, h // 5))
        if inset.w > 2 and inset.h > 2:
            pygame.draw.ellipse(coin, (*inner, int(alpha * 0.65)), inset, 2)

        shine = pygame.Surface((w + 8, h + 8), pygame.SRCALPHA)
        pygame.draw.ellipse(shine, (255, 255, 255, int(alpha * 0.22)),
                            pygame.Rect(7, 8, max(4, w // 2), max(4, h // 3)))
        coin.blit(shine, (0, 0))

        if scale_x > 0.35:
            if heads:
                points = []
                for i in range(10):
                    angle = -math.pi / 2 + i * math.pi / 5
                    rr = radius * (0.34 if i % 2 == 0 else 0.16)
                    points.append((w // 2 + 4 + math.cos(angle) * rr * scale_x,
                                   h // 2 + 4 + math.sin(angle) * rr))
                pygame.draw.polygon(coin, (164, 110, 25, alpha), points, 2)
            else:
                for ratio in (0.28, 0.48, 0.68):
                    r = int(radius * ratio)
                    pygame.draw.ellipse(
                        coin, (112, 122, 142, alpha),
                        pygame.Rect(w // 2 + 4 - int(r * scale_x), h // 2 + 4 - r,
                                    max(2, int(r * 2 * scale_x)), r * 2),
                        1,
                    )

        coin.set_alpha(alpha)
        surface.blit(coin, coin.get_rect(center=(cx, cy)))

    def _draw_shadow(self, surface: pygame.Surface, cx: int, cy: int,
                     scale_x: float, intensity: float):
        shadow_w = int(116 * (0.55 + scale_x * 0.45))
        shadow_h = int(24 * intensity)
        if shadow_h <= 1:
            return
        shadow = pygame.Surface((shadow_w, shadow_h), pygame.SRCALPHA)
        pygame.draw.ellipse(shadow, (0, 0, 0, int(105 * intensity)), shadow.get_rect())
        surface.blit(shadow, shadow.get_rect(center=(cx, self.center_y + 74)))

    def _draw_sparkles(self, surface: pygame.Surface):
        if not self._sparkles:
            return
        for sp in self._sparkles:
            t = min(1.0, self.elapsed / sp["life"])
            if t >= 1.0:
                continue
            ease = _ease_out_cubic(t)
            dist = sp["speed"] * ease
            x = self.center_x + math.cos(sp["angle"]) * dist + sp["drift"] * t
            y = self.center_y + math.sin(sp["angle"]) * dist - 34 * t
            alpha = int(230 * (1 - t))
            size = max(1, int(sp["size"] * (1 - t * 0.4)))
            dot = pygame.Surface((size * 2 + 2, size * 2 + 2), pygame.SRCALPHA)
            pygame.draw.circle(dot, (*sp["color"], alpha), (size + 1, size + 1), size)
            surface.blit(dot, (int(x - size), int(y - size)))

    def _draw_result_history(self, surface: pygame.Surface, font: pygame.font.Font):
        if not self.results:
            return
        size = 26
        gap = 8
        total = len(self.results) * size + (len(self.results) - 1) * gap
        start_x = self.center_x - total // 2
        y = self.center_y + 116
        for idx, res in enumerate(self.results):
            cx = start_x + idx * (size + gap) + size // 2
            self._draw_coin(surface, cx, y, size // 2, 1.0, res, 230)
        heads = sum(1 for item in self.results if item)
        summary = font.render(f"{heads}/{len(self.results)}", True, UI_TEXT_SECONDARY)
        surface.blit(summary, summary.get_rect(center=(self.center_x, y + 30)))

    def draw(self, surface: pygame.Surface, font: pygame.font.Font):
        if not self.active:
            return

        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((4, 6, 12, 172))
        surface.blit(overlay, (0, 0))

        panel = pygame.Surface((480, 300), pygame.SRCALPHA)
        pygame.draw.rect(panel, (12, 15, 26, 215), panel.get_rect(), border_radius=16)
        pygame.draw.rect(panel, (92, 108, 150, 160), panel.get_rect(), 1, border_radius=16)
        surface.blit(panel, panel.get_rect(center=(self.center_x, self.center_y + 22)))

        if self.flip_count > 1 or self.until_tails:
            total = "∞" if self.until_tails else str(self.flip_count)
            counter = font.render(f"{self.flip_index + 1}/{total}", True, UI_HIGHLIGHT)
            surface.blit(counter, counter.get_rect(center=(self.center_x, self.center_y - 146)))

        if self.phase == "flipping":
            t = min(1.0, self.elapsed / self.flip_duration)
            cx, cy, scale_x, _ = self._flip_state(t)
            shadow_intensity = 0.25 + 0.75 * _ease_out_cubic(t)
            self._draw_shadow(surface, cx, cy, scale_x, shadow_intensity)

            for idx, item in enumerate(self._trail[:-1]):
                alpha = int(48 * (idx + 1) / max(1, len(self._trail)))
                self._draw_coin(surface, int(item["x"]), int(item["y"]),
                                self.coin_radius, item["scale_x"],
                                self.result if idx % 2 else not self.result,
                                alpha)

            face = self.result if math.cos(t * math.pi * 8.5 * self._spin_dir) >= 0 else not self.result
            self._draw_coin(surface, cx, cy, self.coin_radius, scale_x, face)
            label = font.render("掷硬币中...", True, UI_TEXT_PRIMARY)
            surface.blit(label, label.get_rect(center=(self.center_x, self.center_y + 86)))

        elif self.phase == "showing":
            t = min(1.0, self.elapsed / self.show_duration)
            pop = 1.0 + 0.18 * math.sin(min(1.0, t * 2.5) * math.pi) * (1 - t * 0.25)
            bounce_y = int(20 * (1 - min(1.0, t * 2.2)) * math.cos(t * math.pi * 5))
            self._draw_shadow(surface, self.center_x, self.center_y + bounce_y, 1.0, 0.8)
            self._draw_coin(surface, self.center_x, self.center_y + bounce_y,
                            int(self.coin_radius * pop), 1.0, self.result)
            self._draw_sparkles(surface)

            result_str = "正面" if self.result else "反面"
            result_color = VICTORY_GOLD_LIGHT if self.result else (192, 204, 226)
            text = font.render(result_str, True, result_color)
            scale = 1.0 + 0.12 * (1 - min(1.0, t * 2))
            text = pygame.transform.smoothscale(
                text,
                (max(1, int(text.get_width() * scale)),
                 max(1, int(text.get_height() * scale))),
            )
            surface.blit(text, text.get_rect(center=(self.center_x, self.center_y + 88)))

        elif self.phase == "summary":
            t = min(1.0, self.elapsed / self.summary_duration)
            scale = 1.0 + 0.1 * (1 - t) * math.sin(t * math.pi * 3)
            final = self.results[-1] if self.results else self.result
            self._draw_shadow(surface, self.center_x, self.center_y, 1.0, 0.7)
            self._draw_coin(surface, self.center_x, self.center_y,
                            int(self.coin_radius * scale), 1.0, final)
            label = font.render("结果", True, UI_HIGHLIGHT)
            surface.blit(label, label.get_rect(center=(self.center_x, self.center_y + 86)))

        self._draw_result_history(surface, font)

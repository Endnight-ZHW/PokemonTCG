"""Lightweight animation/tween system for the game UI."""
from dataclasses import dataclass, field
from typing import Optional, Callable
import math
import random
import pygame
from config import CARD_WIDTH, CARD_HEIGHT


# ── Easing functions ─────────────────────────────────────────────

def _ease_out_cubic(t: float) -> float:
    return 1 - (1 - t) ** 3


def _ease_in_out_cubic(t: float) -> float:
    if t < 0.5:
        return 4 * t ** 3
    return 1 - (-2 * t + 2) ** 3 / 2


def _ease_out_quad(t: float) -> float:
    return 1 - (1 - t) ** 2


EASING = {
    "linear": lambda t: t,
    "ease_out": _ease_out_cubic,
    "ease_out_quad": _ease_out_quad,
    "ease_in_out": _ease_in_out_cubic,
}


# ── Animation ────────────────────────────────────────────────────

@dataclass
class Animation:
    """A single floating-point property tween."""
    start_value: float
    end_value: float
    duration: float  # seconds
    elapsed: float = 0.0
    easing: str = "ease_out"
    on_complete: Optional[Callable] = None
    completed: bool = False

    @property
    def progress(self) -> float:
        if self.duration <= 0:
            return 1.0
        return min(1.0, self.elapsed / self.duration)

    @property
    def value(self) -> float:
        t = self.progress
        fn = EASING.get(self.easing, _ease_out_cubic)
        t = fn(t)
        return self.start_value + (self.end_value - self.start_value) * t


# ── Animation Manager ────────────────────────────────────────────

class AnimationManager:
    """Central manager for all visual animations."""

    def __init__(self):
        self.active: list[Animation] = []

    def update(self, dt: float):
        still_active = []
        for anim in self.active:
            anim.elapsed += dt
            if anim.elapsed >= anim.duration:
                anim.elapsed = anim.duration
                anim.completed = True
                if anim.on_complete:
                    anim.on_complete()
            else:
                still_active.append(anim)
        self.active = still_active

    def play(self, animation: Animation):
        self.active.append(animation)

    def clear(self):
        self.active.clear()

    @property
    def is_empty(self) -> bool:
        return len(self.active) == 0


# ── Visual effect helpers ────────────────────────────────────────

class DamageFlash:
    """Manages damage flash effects on Pokemon slots."""

    def __init__(self):
        self._flashes: dict[str, float] = {}  # slot_key -> remaining_time

    def trigger(self, slot_key: str, duration: float = 0.3):
        self._flashes[slot_key] = duration

    def update(self, dt: float):
        for key in list(self._flashes):
            self._flashes[key] -= dt
            if self._flashes[key] <= 0:
                del self._flashes[key]

    def get_alpha(self, slot_key: str) -> int:
        """Returns 0-255 alpha for the flash overlay, or 0 if not flashing."""
        remaining = self._flashes.get(slot_key, 0)
        if remaining <= 0:
            return 0
        ratio = remaining / 0.3
        # Pulse effect using sin
        pulse = abs(math.sin(remaining * 30))
        return int(pulse * 120 * ratio)


class KOFade:
    """Manages KO fade-out effects on Pokemon slots."""

    def __init__(self):
        self._fades: dict[str, float] = {}  # slot_key -> elapsed time

    def trigger(self, slot_key: str):
        self._fades[slot_key] = 0.0

    def update(self, dt: float):
        for key in list(self._fades):
            self._fades[key] += dt
            if self._fades[key] > 0.8:
                del self._fades[key]

    def get_alpha(self, slot_key: str) -> int:
        """Returns 0-255 for the fade alpha (255=fully visible, 0=fully faded)."""
        elapsed = self._fades.get(slot_key, -1)
        if elapsed < 0:
            return 255
        progress = elapsed / 0.8
        return int(255 * (1 - progress))


class AttackShake:
    """Manages attack shake animation on attacking Pokemon. Supports
    multiple simultaneous shakes keyed by slot (e.g. both player and
    opponent active can shake independently)."""

    def __init__(self):
        self._shakes: dict[str, dict] = {}

    def trigger(self, slot_key: str, duration: float = 0.25, intensity: float = 4.0):
        self._shakes[slot_key] = {
            "elapsed": 0.0,
            "duration": duration,
            "intensity": intensity,
        }

    def update(self, dt: float):
        expired = [k for k, s in self._shakes.items()
                   if s["elapsed"] >= s["duration"]]
        for k in expired:
            del self._shakes[k]
        for s in self._shakes.values():
            s["elapsed"] += dt

    def get_offset(self, slot_key: str) -> tuple[int, int]:
        """Returns (dx, dy) offset for the shake effect."""
        shake = self._shakes.get(slot_key)
        if not shake:
            return (0, 0)
        progress = shake["elapsed"] / max(shake["duration"], 0.001)
        freq = 25.0
        amplitude = shake["intensity"] * (1 - progress)
        return (int(math.sin(shake["elapsed"] * freq) * amplitude), 0)


class FloatingText:
    """A floating status message that rises and fades out."""

    def __init__(self):
        self.active: list[dict] = []

    def show(self, text: str, x: int, y: int,
             color: tuple[int, int, int] = (255, 215, 0), duration: float = 1.2):
        self.active.append({
            "text": text,
            "x": x, "y": y,
            "start_y": y,
            "color": color,
            "elapsed": 0.0,
            "duration": duration,
        })

    def update(self, dt: float):
        still_active = []
        for item in self.active:
            item["elapsed"] += dt
            if item["elapsed"] < item["duration"]:
                still_active.append(item)
        self.active = still_active

    def get_state(self, item: dict) -> tuple[str, int, int, int]:
        """Returns (text, x, y, alpha) for rendering."""
        progress = item["elapsed"] / item["duration"]
        alpha = int(255 * (1 - progress))
        y_offset = int(40 * progress)
        return (item["text"], item["x"],
                item["start_y"] - y_offset, max(0, alpha))

    def draw(self, surface: pygame.Surface, font: pygame.font.Font):
        for item in self.active:
            text, x, y, alpha = self.get_state(item)
            txt = font.render(text, True, item["color"])
            txt.set_alpha(alpha)
            surface.blit(txt, (x - txt.get_width() // 2, y))


# ── Card Fly Animation ──────────────────────────────────────────

class CardFlyAnimation:
    """Animate a card image flying from one position to another along a bezier curve."""

    def __init__(self):
        self.active: list[dict] = []

    def _add_fly(self, card_surface: pygame.Surface,
                 start_x: float, start_y: float,
                 end_x: float, end_y: float,
                 duration: float, arc_style: str,
                 on_complete: Optional[Callable] = None):
        """Internal: queue a card fly animation."""
        self.active.append({
            "surface": card_surface.copy(),
            "start_x": start_x, "start_y": start_y,
            "end_x": end_x, "end_y": end_y,
            "elapsed": 0.0,
            "duration": duration,
            "arc_style": arc_style,
            "on_complete": on_complete,
        })

    def fly(self, card_surface: pygame.Surface,
            start_x: float, start_y: float,
            end_x: float, end_y: float,
            duration: float = 0.35,
            on_complete: Optional[Callable] = None):
        """Standard card fly with a high upward arc."""
        self._add_fly(card_surface, start_x, start_y, end_x, end_y,
                      duration, "high", on_complete)

    def fly_from_deck(self, card_surface: pygame.Surface,
                      deck_x: float, deck_y: float,
                      target_x: float, target_y: float,
                      duration: float = 0.45,
                      on_complete: Optional[Callable] = None):
        """Card flies from deck position with a lower arc (for draws)."""
        self._add_fly(card_surface, deck_x, deck_y, target_x, target_y,
                      duration, "low", on_complete)

    def fly_to_discard(self, card_surface: pygame.Surface,
                       start_x: float, start_y: float,
                       discard_x: float, discard_y: float,
                       duration: float = 0.4,
                       on_complete: Optional[Callable] = None):
        """Card flies from play area to discard pile with a downward arc."""
        self._add_fly(card_surface, start_x, start_y, discard_x, discard_y,
                      duration, "down", on_complete)

    def update(self, dt: float):
        still_active = []
        for item in self.active:
            item["elapsed"] += dt
            if item["elapsed"] >= item["duration"]:
                if item["on_complete"]:
                    item["on_complete"]()
            else:
                still_active.append(item)
        self.active = still_active

    def _bezier_point(self, p0, p1, p2, t: float) -> tuple[float, float]:
        """Quadratic bezier: (1-t)^2*P0 + 2(1-t)t*P1 + t^2*P2"""
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        return (x, y)

    def _get_control_point(self, p0, p2, arc_style: str):
        """Compute bezier control point for a visually pleasing arc.

        "high" arcs bulge upward on screen (toward y=0), "low" arcs bulge
        downward, and "down" arcs bulge strongly downward. A small horizontal
        offset perpendicular to the flight direction adds visual variety.
        """
        mid_x = (p0[0] + p2[0]) / 2
        mid_y = (p0[1] + p2[1]) / 2

        dx = p2[0] - p0[0]
        dy = p2[1] - p0[1]
        length = math.sqrt(dx * dx + dy * dy) or 1.0

        # Small horizontal offset perpendicular to flight direction
        perp_x = (dy / length) * 30

        if arc_style == "high":
            vert_offset = -80  # screen-up (toward top)
        elif arc_style == "low":
            vert_offset = 50   # screen-down (toward bottom)
        else:  # "down"
            vert_offset = -50  # slight upward arc into discard

        return (mid_x + perp_x, mid_y + vert_offset)

    def draw(self, surface: pygame.Surface):
        for item in self.active:
            t = item["elapsed"] / max(item["duration"], 0.001)
            t = min(1.0, t)
            t_eased = 1 - (1 - t) ** 3  # ease out cubic

            p0 = (item["start_x"], item["start_y"])
            p2 = (item["end_x"], item["end_y"])
            p1 = self._get_control_point(p0, p2, item.get("arc_style", "high"))

            x, y = self._bezier_point(p0, p1, p2, t_eased)

            scale = 1.0 - t * 0.3
            card_w = int(item["surface"].get_width() * scale)
            card_h = int(item["surface"].get_height() * scale)
            if card_w > 0 and card_h > 0:
                scaled = pygame.transform.smoothscale(item["surface"], (card_w, card_h))
                alpha = 255 if t < 0.8 else int(255 * (1 - (t - 0.8) / 0.2))
                scaled.set_alpha(max(0, alpha))
                surface.blit(scaled, (int(x - card_w // 2), int(y - card_h // 2)))


# ── Heal Flash ────────────────────────────────────────────────

class HealFlash:
    """Green flash overlay for healing effects."""

    def __init__(self):
        self._flashes: dict[str, float] = {}

    def trigger(self, slot_key: str, duration: float = 0.3):
        self._flashes[slot_key] = duration

    def update(self, dt: float):
        for key in list(self._flashes):
            self._flashes[key] -= dt
            if self._flashes[key] <= 0:
                del self._flashes[key]

    def get_alpha(self, slot_key: str) -> int:
        remaining = self._flashes.get(slot_key, 0)
        if remaining <= 0:
            return 0
        ratio = remaining / 0.3
        pulse = abs(math.sin(remaining * 30))
        return int(pulse * 100 * ratio)


# ── Draw Card Flash ───────────────────────────────────────────

class DrawCardFlash:
    """Brief blue pulse on the deck area when a card is drawn."""

    def __init__(self):
        self._flash: float = 0.0

    def trigger(self, duration: float = 0.2):
        self._flash = duration

    def update(self, dt: float):
        if self._flash > 0:
            self._flash = max(0, self._flash - dt)

    def get_alpha(self) -> int:
        if self._flash <= 0:
            return 0
        ratio = self._flash / 0.2
        return int(ratio * 100)


# ── Enhanced DamageFlash with ripple ──────────────────────────

class DamageRipple:
    """Expanding ring effect that pulses outward from center of a card during damage."""

    def __init__(self):
        self._ripples: dict[str, float] = {}

    def trigger(self, slot_key: str, duration: float = 0.4):
        self._ripples[slot_key] = duration

    def update(self, dt: float):
        for key in list(self._ripples):
            self._ripples[key] -= dt
            if self._ripples[key] <= 0:
                del self._ripples[key]

    def get_ring_state(self, slot_key: str) -> tuple[float, int]:
        """Returns (ring_radius_ratio, alpha). ring_radius_ratio goes from 0 to 1.2."""
        remaining = self._ripples.get(slot_key, 0)
        if remaining <= 0:
            return (0, 0)
        progress = 1 - remaining / 0.4
        radius_ratio = progress * 1.2
        alpha = int(100 * (1 - progress))
        return (radius_ratio, alpha)


# ── Waiting Indicator (online play) ─────────────────────────────

class WaitingIndicator:
    """Animated dots showing 'waiting for opponent' state."""

    def __init__(self):
        self._active = False
        self._elapsed = 0.0
        self._message = "等待对手操作"

    def show(self, message="等待对手操作"):
        self._active = True
        if not self._elapsed:
            self._elapsed = 0.0
        self._message = message

    def hide(self):
        self._active = False
        self._elapsed = 0.0

    @property
    def is_active(self) -> bool:
        return self._active

    def update(self, dt: float):
        if self._active:
            self._elapsed += dt

    def draw(self, surface: pygame.Surface, font: pygame.font.Font,
             center_x: int, center_y: int):
        """Draw waiting message with three animated dots."""
        if not self._active:
            return

        # Semi-transparent backdrop
        bg_w = 320
        bg_h = 50
        bg_surf = pygame.Surface((bg_w, bg_h), pygame.SRCALPHA)
        bg_surf.fill((10, 10, 25, 160))
        surface.blit(bg_surf, (center_x - bg_w // 2, center_y - bg_h // 2))

        # Message text
        msg_txt = font.render(self._message, True, (255, 215, 0))
        msg_x = center_x - msg_txt.get_width() // 2 - 24
        msg_y = center_y - msg_txt.get_height() // 2
        surface.blit(msg_txt, (msg_x, msg_y))

        # Three pulsing dots
        dot_cycle = 0.75  # full cycle in seconds
        dot_x = msg_x + msg_txt.get_width() + 10
        dot_y = center_y - 3
        for i in range(3):
            phase = (self._elapsed + i * 0.2) % dot_cycle
            alpha = int(255 * abs(math.sin(phase / dot_cycle * math.pi)))
            color = (255, 215, 0, alpha) if alpha > 20 else (255, 215, 0, 20)
            dot_surf = pygame.Surface((12, 12), pygame.SRCALPHA)
            pygame.draw.circle(dot_surf, color, (6, 6), 4)
            surface.blit(dot_surf, (dot_x + i * 16, dot_y))


# ── Shuffle Animation ──────────────────────────────────────────

class ShuffleAnimation:
    """Deck shuffle: provides per-layer shake offsets to animate the actual deck rendering.

    Instead of drawing its own particles, this feeds offsets to
    _draw_card_stack_with_count so the deck card-back layers themselves shake.
    """

    DURATION = 0.7

    def __init__(self):
        self._active: dict[str, float] = {}

    def trigger(self, zone_key: str):
        """Start shuffle for a deck zone."""
        self._active[zone_key] = self.DURATION

    def update(self, dt: float):
        for key in list(self._active):
            self._active[key] -= dt
            if self._active[key] <= 0:
                del self._active[key]

    @property
    def is_active(self) -> bool:
        return len(self._active) > 0

    def get_offsets(self, zone_key: str, layer: int) -> tuple[float, float, float]:
        """Returns (dx, dy, rotation_degrees) for a deck layer during shuffle.

        Uses a seeded hash of zone_key + layer so each layer shakes differently
        but deterministically (no per-frame randomness).
        """
        if zone_key not in self._active:
            return (0.0, 0.0, 0.0)

        remaining = self._active[zone_key]
        t = 1.0 - remaining / self.DURATION

        # Use a hash to give each layer a unique phase, amplitude, and sign
        seed = hash(f"{zone_key}_{layer}") % 1000 / 1000.0

        # Intensity ramps up then down (bell-shaped)
        if t < 0.5:
            intensity = t / 0.5
        else:
            intensity = (1.0 - t) / 0.5

        # Deterministic jitter for this layer
        amp_x = 3.0 + seed * 8.0          # 3-11px horizontal shake
        amp_y = 1.0 + (1 - seed) * 4.0    # 1-5px vertical
        freq = 18.0 + seed * 20.0         # 18-38 Hz
        phase = seed * math.pi * 2

        dx = math.sin(self._active[zone_key] * freq + phase) * amp_x * intensity
        dy = math.cos(self._active[zone_key] * freq * 1.3 + phase) * amp_y * intensity
        rot = math.sin(self._active[zone_key] * freq * 0.7) * (3.0 + seed * 5.0) * intensity

        return (dx, dy, rot)

    def is_zone_active(self, zone_key: str) -> bool:
        return zone_key in self._active

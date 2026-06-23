"""Lightweight particle system for visual effects."""
import math
import random
from dataclasses import dataclass, field
from typing import Callable
import pygame

from ui.colors import ENERGY_COLORS, TYPE_COLORS


@dataclass
class Particle:
    x: float
    y: float
    vx: float
    vy: float
    size: float
    color: tuple[int, int, int, int]  # RGBA
    lifetime: float
    elapsed: float = 0.0
    gravity: tuple[float, float] = (0, 0)
    size_decay: bool = True
    alpha_decay: bool = True

    @property
    def alpha(self) -> int:
        if not self.alpha_decay:
            return self.color[3]
        progress = self.elapsed / max(self.lifetime, 0.001)
        return int(self.color[3] * (1 - progress))

    @property
    def current_size(self) -> float:
        if not self.size_decay:
            return self.size
        progress = self.elapsed / max(self.lifetime, 0.001)
        return max(0.5, self.size * (1 - progress * 0.5))

    @property
    def alive(self) -> bool:
        return self.elapsed < self.lifetime


class ParticleEmitter:
    """Emits particles with configurable parameters."""

    def __init__(self,
                 emission_rate: float = 0,  # particles per second (0 = burst only)
                 spread: float = math.pi * 2,
                 speed_range: tuple[float, float] = (50, 150),
                 lifetime_range: tuple[float, float] = (0.3, 0.6),
                 color: tuple = (255, 255, 255, 255),
                 color_range: tuple | None = None,
                 size_range: tuple[float, float] = (2, 5),
                 gravity: tuple[float, float] = (0, 0),
                 size_decay: bool = True,
                 alpha_decay: bool = True,
                 ):
        self.emission_rate = emission_rate
        self.spread = spread
        self.speed_range = speed_range
        self.lifetime_range = lifetime_range
        self.color = color
        self.color_range = color_range
        self.size_range = size_range
        self.gravity = gravity
        self.size_decay = size_decay
        self.alpha_decay = alpha_decay
        self._accumulator = 0.0

    def update(self, dt: float):
        self._accumulator += dt

    def should_emit(self) -> bool:
        if self.emission_rate <= 0:
            return False
        count = int(self._accumulator * self.emission_rate)
        if count > 0:
            self._accumulator -= count / self.emission_rate
            return True
        return False

    def _random_color(self) -> tuple:
        if self.color_range:
            r = max(0, min(255, self.color[0] + random.randint(-self.color_range[0], self.color_range[0])))
            g = max(0, min(255, self.color[1] + random.randint(-self.color_range[1], self.color_range[1])))
            b = max(0, min(255, self.color[2] + random.randint(-self.color_range[2], self.color_range[2])))
            a = self.color[3]
            return (r, g, b, a)
        return self.color

    def emit(self, x: float, y: float, count: int = 1) -> list[Particle]:
        particles = []
        for _ in range(count):
            angle = random.uniform(-self.spread / 2, self.spread / 2)
            speed = random.uniform(*self.speed_range)
            vx = math.cos(angle) * speed
            vy = math.sin(angle) * speed
            size = random.uniform(*self.size_range)
            lifetime = random.uniform(*self.lifetime_range)
            color = self._random_color()
            p = Particle(
                x=x, y=y, vx=vx, vy=vy,
                size=size, color=color, lifetime=lifetime,
                gravity=self.gravity, size_decay=self.size_decay,
                alpha_decay=self.alpha_decay,
            )
            particles.append(p)
        return particles

    def burst(self, x: float, y: float, count: int) -> list[Particle]:
        return self.emit(x, y, count)


class ParticleManager:
    """Central manager for all particle effects."""
    MAX_PARTICLES = 500

    def __init__(self):
        self.particles: list[Particle] = []
        self.emitters: list[ParticleEmitter] = []
        self._spawn_queue: list[Particle] = []

    def add_emitter(self, emitter: ParticleEmitter):
        self.emitters.append(emitter)

    def remove_emitter(self, emitter: ParticleEmitter):
        if emitter in self.emitters:
            self.emitters.remove(emitter)

    def spawn_particles(self, particles: list[Particle]):
        if len(self.particles) + len(self._spawn_queue) < self.MAX_PARTICLES:
            self._spawn_queue.extend(particles)

    def burst(self, x: float, y: float, count: int,
              color: tuple = (255, 255, 255, 255),
              spread: float = math.pi * 2,
              speed_range: tuple = (50, 150),
              lifetime_range: tuple = (0.3, 0.6),
              size_range: tuple = (2, 5),
              gravity: tuple = (0, 0)):
        """Quick one-shot burst without creating a persistent emitter."""
        emitter = ParticleEmitter(
            spread=spread, speed_range=speed_range,
            lifetime_range=lifetime_range, color=color,
            size_range=size_range, gravity=gravity,
        )
        particles = emitter.burst(x, y, count)
        self.spawn_particles(particles)

    def update(self, dt: float):
        # Update emitters
        for emitter in self.emitters:
            emitter.update(dt)

        # Add queued particles
        self.particles.extend(self._spawn_queue)
        self._spawn_queue.clear()

        # Cap total particles
        if len(self.particles) > self.MAX_PARTICLES:
            self.particles = self.particles[-self.MAX_PARTICLES:]

        # Update particles — filter dead ones
        alive = []
        for p in self.particles:
            p.elapsed += dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            p.vx += p.gravity[0] * dt
            p.vy += p.gravity[1] * dt
            if p.alive:
                alive.append(p)
        self.particles = alive

    def draw(self, surface: pygame.Surface):
        for p in self.particles:
            if p.current_size < 0.5:
                continue
            alpha = p.alpha
            if alpha <= 0:
                continue
            color = (*p.color[:3], alpha)
            size = int(p.current_size)
            if size <= 1:
                surface.set_at((int(p.x), int(p.y)), color[:3])
            else:
                part_surf = self._cached_circle(size, color)
                surface.blit(part_surf, (int(p.x) - size, int(p.y) - size))

    # Cache of pre-rendered circle surfaces, keyed by (size, rgba)
    _circle_cache: dict[tuple, pygame.Surface] = {}

    @classmethod
    def _cached_circle(cls, size: int, color: tuple) -> pygame.Surface:
        key = (size, color)
        if key not in cls._circle_cache:
            surf = pygame.Surface((size * 2, size * 2), pygame.SRCALPHA)
            pygame.draw.circle(surf, color, (size, size), size)
            cls._circle_cache[key] = surf
            # Limit cache size to prevent memory leaks from unique colors
            if len(cls._circle_cache) > 200:
                cls._circle_cache.pop(next(iter(cls._circle_cache)))
        return cls._circle_cache[key]

    def clear(self):
        self.particles.clear()
        self.emitters.clear()
        self._spawn_queue.clear()


# ── Preset effect factories ──────────────────────────────────

def energy_spark(x: float, y: float, energy_type: str = "Colorless") -> list[Particle]:
    """Burst of sparks when energy is attached."""
    ec = ENERGY_COLORS.get(energy_type, (220, 220, 210))
    color = (*ec, 255)
    emitter = ParticleEmitter(
        spread=math.pi * 2, speed_range=(60, 180),
        lifetime_range=(0.2, 0.5), color=color,
        color_range=(30, 30, 30, 0),
        size_range=(2, 5), gravity=(0, 80),
    )
    return emitter.burst(x, y, random.randint(8, 15))


def attack_impact(x: float, y: float) -> list[Particle]:
    """Burst of particles on attack hit."""
    particles = []
    # White/yellow core burst
    emitter1 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(100, 250),
        lifetime_range=(0.2, 0.5), color=(255, 255, 200, 255),
        color_range=(0, 0, 55, 0),
        size_range=(3, 7), gravity=(0, 60),
    )
    particles.extend(emitter1.burst(x, y, 15))
    # Red/orange outer burst
    emitter2 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(60, 160),
        lifetime_range=(0.3, 0.6), color=(255, 100, 30, 220),
        color_range=(0, 40, 20, 0),
        size_range=(2, 5), gravity=(0, 40),
    )
    particles.extend(emitter2.burst(x, y, 10))
    return particles


def evolution_glow(x: float, y: float) -> list[Particle]:
    """Expanding ring of particles for evolution."""
    particles = []
    # White core flash
    emitter1 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(30, 80),
        lifetime_range=(0.3, 0.6), color=(255, 255, 255, 200),
        size_range=(4, 8), gravity=(0, -20),
    )
    particles.extend(emitter1.burst(x, y, 12))
    # Blue/gold ring
    emitter2 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(50, 120),
        lifetime_range=(0.4, 0.8), color=(100, 180, 255, 180),
        color_range=(30, 30, 30, 0),
        size_range=(2, 5), gravity=(0, -30),
        alpha_decay=True,
    )
    particles.extend(emitter2.burst(x, y, 20))
    # Gold sparkles
    emitter3 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(40, 100),
        lifetime_range=(0.3, 0.7), color=(255, 215, 0, 200),
        size_range=(1, 3), gravity=(0, -10),
    )
    particles.extend(emitter3.burst(x, y, 10))
    return particles


def heal_sparkle(x: float, y: float) -> list[Particle]:
    """Green rising sparkles for healing."""
    emitter = ParticleEmitter(
        spread=math.pi * 0.6, speed_range=(20, 80),
        lifetime_range=(0.4, 0.8), color=(100, 255, 100, 200),
        color_range=(30, 0, 30, 0),
        size_range=(1, 4), gravity=(0, -50),
    )
    return emitter.burst(x, y, random.randint(8, 12))


def ko_burst(x: float, y: float) -> list[Particle]:
    """Dark purple explosion burst for KO."""
    particles = []
    # Dark core
    emitter1 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(80, 200),
        lifetime_range=(0.3, 0.6), color=(80, 20, 100, 220),
        color_range=(30, 10, 30, 0),
        size_range=(3, 7), gravity=(0, 100),
    )
    particles.extend(emitter1.burst(x, y, 15))
    # Purple outer ring
    emitter2 = ParticleEmitter(
        spread=math.pi * 2, speed_range=(50, 150),
        lifetime_range=(0.4, 0.7), color=(150, 50, 200, 180),
        size_range=(2, 5), gravity=(0, 60),
    )
    particles.extend(emitter2.burst(x, y, 20))
    return particles


def card_play_trail(start_x: float, start_y: float, end_x: float, end_y: float,
                    color: tuple = (200, 200, 220, 180)) -> list[Particle]:
    """Trail particles along a card movement path."""
    dist = math.sqrt((end_x - start_x) ** 2 + (end_y - start_y) ** 2)
    count = max(3, int(dist / 30))
    particles = []
    for i in range(count):
        t = i / max(count - 1, 1)
        px = start_x + (end_x - start_x) * t
        py = start_y + (end_y - start_y) * t
        p = Particle(
            x=px, y=py, vx=random.uniform(-20, 20), vy=random.uniform(-20, 20),
            size=random.uniform(1, 3), color=color,
            lifetime=random.uniform(0.2, 0.4),
            gravity=(0, 30), alpha_decay=True, size_decay=True,
        )
        particles.append(p)
    return particles


def victory_confetti(screen_width: float, screen_height: float) -> list[Particle]:
    """Sustained confetti burst for victory screen."""
    colors = [
        (255, 220, 80, 255), (255, 100, 100, 255),
        (100, 200, 255, 255), (100, 255, 100, 255),
        (255, 150, 200, 255), (200, 180, 255, 255),
    ]
    particles = []
    for _ in range(30):
        x = random.uniform(0, screen_width)
        y = random.uniform(-screen_height * 0.3, 0)
        color = random.choice(colors)
        p = Particle(
            x=x, y=y,
            vx=random.uniform(-30, 30),
            vy=random.uniform(40, 100),
            size=random.uniform(2, 6),
            color=color,
            lifetime=random.uniform(1.5, 3.0),
            gravity=(0, 20),
            size_decay=False,
            alpha_decay=True,
        )
        particles.append(p)
    return particles

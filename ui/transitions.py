"""Screen transition effects for smooth screen changes."""
import pygame
from config import SCREEN_WIDTH, SCREEN_HEIGHT


class ScreenTransition:
    """Base class for screen transitions."""

    def __init__(self, duration: float = 0.4):
        self.duration = duration
        self.elapsed: float = 0.0
        self.completed: bool = False

    def update(self, dt: float):
        if not self.completed:
            self.elapsed += dt
            if self.elapsed >= self.duration:
                self.elapsed = self.duration
                self.completed = True

    @property
    def progress(self) -> float:
        """Returns 0.0 to 1.0."""
        return min(1.0, self.elapsed / max(self.duration, 0.001))

    @property
    def is_complete(self) -> bool:
        return self.completed

    def draw(self, surface: pygame.Surface, from_surface: pygame.Surface,
             to_surface: pygame.Surface):
        """Default: just show the new screen (instant)."""
        surface.blit(to_surface, (0, 0))


class FadeTransition(ScreenTransition):
    """Cross-fade between two screens."""

    def draw(self, surface, from_surface, to_surface):
        p = self.progress
        # Fade out old, fade in new
        from_surface.set_alpha(int(255 * (1 - p)))
        to_surface.set_alpha(int(255 * p))
        surface.blit(from_surface, (0, 0))
        surface.blit(to_surface, (0, 0))
        # Restore alpha
        from_surface.set_alpha(255)
        to_surface.set_alpha(255)


class SlideTransition(ScreenTransition):
    """Slide old screen out and new screen in from a direction."""

    def __init__(self, duration: float = 0.35, direction: str = "left"):
        super().__init__(duration)
        self.direction = direction  # "left", "right", "up", "down"

    def draw(self, surface, from_surface, to_surface):
        p = self.progress
        p_eased = 1 - (1 - p) ** 3  # ease out

        if self.direction == "left":
            # Old slides left, new slides in from right
            old_x = -SCREEN_WIDTH * p_eased
            new_x = SCREEN_WIDTH * (1 - p_eased)
            surface.blit(from_surface, (old_x, 0))
            surface.blit(to_surface, (new_x, 0))
        elif self.direction == "right":
            old_x = SCREEN_WIDTH * p_eased
            new_x = -SCREEN_WIDTH * (1 - p_eased)
            surface.blit(from_surface, (old_x, 0))
            surface.blit(to_surface, (new_x, 0))
        elif self.direction == "up":
            old_y = -SCREEN_HEIGHT * p_eased
            new_y = SCREEN_HEIGHT * (1 - p_eased)
            surface.blit(from_surface, (0, old_y))
            surface.blit(to_surface, (0, new_y))
        elif self.direction == "down":
            old_y = SCREEN_HEIGHT * p_eased
            new_y = -SCREEN_HEIGHT * (1 - p_eased)
            surface.blit(from_surface, (0, old_y))
            surface.blit(to_surface, (0, new_y))


class ZoomTransition(ScreenTransition):
    """Zoom out old screen while zooming in new screen."""

    def __init__(self, duration: float = 0.35):
        super().__init__(duration)

    def draw(self, surface, from_surface, to_surface):
        p = self.progress
        # Old zooms out (scale 1.0 -> 0.7) and fades
        old_scale = 1.0 - p * 0.3
        old_w = int(SCREEN_WIDTH * old_scale)
        old_h = int(SCREEN_HEIGHT * old_scale)
        old_scaled = pygame.transform.smoothscale(from_surface, (old_w, old_h))
        old_scaled.set_alpha(int(255 * (1 - p)))
        old_x = (SCREEN_WIDTH - old_w) // 2
        old_y = (SCREEN_HEIGHT - old_h) // 2
        surface.blit(old_scaled, (old_x, old_y))

        # New zooms in (scale 1.3 -> 1.0)
        if p > 0.1:  # wait a bit before showing new
            new_p = (p - 0.1) / 0.9
            new_scale = 1.3 - new_p * 0.3
            new_w = int(SCREEN_WIDTH * new_scale)
            new_h = int(SCREEN_HEIGHT * new_scale)
            new_scaled = pygame.transform.smoothscale(to_surface, (new_w, new_h))
            new_scaled.set_alpha(int(255 * new_p))
            new_x = (SCREEN_WIDTH - new_w) // 2
            new_y = (SCREEN_HEIGHT - new_h) // 2
            surface.blit(new_scaled, (new_x, new_y))

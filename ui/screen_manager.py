"""Stack-based screen manager for game screen transitions."""
from typing import Optional
import pygame
from config import SCREEN_WIDTH, SCREEN_HEIGHT


class Screen:
    """Base class for all game screens."""

    def __init__(self, screen_manager: "ScreenManager"):
        self.manager = screen_manager
        self.visible = True

    def on_enter(self):
        """Called when screen becomes the active top of stack."""

    def on_exit(self):
        """Called when screen is popped or covered."""

    def handle_event(self, event: pygame.event.Event):
        """Process a pygame event."""

    def update(self, dt: float):
        """Update logic. dt in seconds."""

    def draw(self, surface: pygame.Surface):
        """Render to the given surface."""


class ScreenManager:
    """Stack-based screen management. Top of stack is the active screen."""

    def __init__(self):
        self._screens: list[Screen] = []
        self._transition = None
        self._from_surface: Optional[pygame.Surface] = None
        self._to_surface: Optional[pygame.Surface] = None
        self._old_top: Optional[Screen] = None

    @property
    def top(self) -> Optional[Screen]:
        return self._screens[-1] if self._screens else None

    @property
    def stack_size(self) -> int:
        return len(self._screens)

    @property
    def in_transition(self) -> bool:
        return self._transition is not None and not self._transition.is_complete

    def push_screen(self, screen: Screen, transition=None):
        """Push a new screen onto the stack, making it active."""
        if self.top:
            # Capture current screen for transition
            if transition:
                self._from_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
                self.top.draw(self._from_surface)
            self.top.on_exit()

        self._screens.append(screen)
        screen.on_enter()

        if transition and self._from_surface:
            self._transition = transition
            self._to_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
            screen.draw(self._to_surface)

    def pop_screen(self, transition=None):
        """Remove the top screen. Returns to previous screen if any."""
        if not self._screens:
            return
        if transition and self.top:
            self._from_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
            self.top.draw(self._from_surface)

        old = self._screens.pop()
        old.on_exit()

        if self.top:
            self.top.on_enter()
            if transition and self._from_surface:
                self._transition = transition
                self._to_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
                self.top.draw(self._to_surface)

    def replace_top(self, screen: Screen, transition=None):
        """Replace the current top screen with a new one."""
        if self._screens:
            if transition and self.top:
                self._from_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
                self.top.draw(self._from_surface)
            old = self._screens.pop()
            old.on_exit()
        self._screens.append(screen)
        screen.on_enter()

        if transition and self._from_surface:
            self._transition = transition
            self._to_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
            screen.draw(self._to_surface)

    def clear_to(self, screen: Screen, transition=None):
        """Clear all screens and set one new screen."""
        if transition and self._screens:
            self._from_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
            self.top.draw(self._from_surface)

        while self._screens:
            self._screens.pop().on_exit()

        self._screens.append(screen)
        screen.on_enter()

        if transition and self._from_surface:
            self._transition = transition
            self._to_surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
            screen.draw(self._to_surface)

    def shutdown(self):
        """Run cleanup hooks for every screen before the app exits."""
        while self._screens:
            screen = self._screens.pop()
            try:
                screen.on_exit()
            except Exception:
                pass
        self._transition = None
        self._from_surface = None
        self._to_surface = None
        self._old_top = None

    def handle_event(self, event: pygame.event.Event):
        if not self.in_transition and self.top:
            self.top.handle_event(event)

    def update(self, dt: float):
        if self.in_transition:
            self._transition.update(dt)
            if self._transition.is_complete:
                self._transition = None
                self._from_surface = None
                self._to_surface = None
            return
        if self.top:
            self.top.update(dt)

    def draw(self, surface: pygame.Surface):
        if self.in_transition and self._from_surface and self._to_surface:
            self._transition.draw(surface, self._from_surface, self._to_surface)
        else:
            # Draw bottom-to-top so top is visible
            for screen in self._screens:
                if screen.visible:
                    screen.draw(surface)

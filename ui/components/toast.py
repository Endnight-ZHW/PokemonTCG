"""Toast notification system — non-blocking slide-in notifications."""
import pygame
from ui.font_manager import get_font
from ui.colors import UI_TEXT_PRIMARY, UI_HIGHLIGHT, UI_SUCCESS, UI_DANGER


TYPE_COLORS = {
    "info": UI_HIGHLIGHT,
    "success": UI_SUCCESS,
    "error": UI_DANGER,
    "warning": (255, 180, 40),
}

TYPE_ICONS = {
    "info": "i",
    "success": "✓",
    "error": "!",
    "warning": "⚠",
}


class ToastManager:
    """Manages a stack of toast notifications with slide-in/slide-out animation."""

    def __init__(self, x: int = 0, y_offset: int = 20):
        self._toasts: list[dict] = []
        self._font = get_font("body_sm")
        self._icon_font = get_font("body_md")
        self._x = x  # Right edge of toast area (toasts slide in from right)
        self._y_offset = y_offset  # Top Y offset
        self._max_visible = 4
        self._toast_w = 340
        self._toast_h = 42
        self._gap = 8

    def show(self, message: str, toast_type: str = "info", duration: float = 3.0):
        """Show a toast notification."""
        toast = {
            "message": message,
            "type": toast_type,
            "duration": duration,
            "elapsed": 0.0,
            "slide_progress": 0.0,
        }
        self._toasts.insert(0, toast)
        # Trim excess
        if len(self._toasts) > self._max_visible + 2:
            self._toasts = self._toasts[:self._max_visible + 2]

    def update(self, dt: float):
        expired = []
        for i, toast in enumerate(self._toasts):
            toast["elapsed"] += dt
            # Slide in
            if toast["slide_progress"] < 1.0:
                toast["slide_progress"] = min(1.0, toast["slide_progress"] + dt / 0.3)
            # Mark expired
            if toast["elapsed"] >= toast["duration"]:
                expired.append(i)
        # Remove expired from end (oldest toasts fade out first)
        for i in reversed(expired):
            if i < len(self._toasts):
                self._toasts.pop(i)

    def draw(self, surface: pygame.Surface):
        screen_w = surface.get_width()
        toast_rx = screen_w - 30 if self._x == 0 else self._x

        for i, toast in enumerate(self._toasts):
            if i >= self._max_visible:
                break

            # Animation: slide from right
            sp = toast["slide_progress"]
            # ease_out_cubic
            eased = 1 - (1 - sp) ** 3

            target_y = self._y_offset + i * (self._toast_h + self._gap)
            # Start from right (off-screen)
            start_x = toast_rx + self._toast_w + 50
            current_x = toast_rx - int((toast_rx - (toast_rx - self._toast_w)) * eased)
            # Simplified: x stays at toast_rx - toast_w, slide from right
            slide_x = int(start_x + ((toast_rx - self._toast_w) - start_x) * eased)

            # Alpha fade for last 0.5 sec
            remaining = toast["duration"] - toast["elapsed"]
            alpha = 255
            if remaining < 0.5:
                alpha = int(255 * max(0, remaining / 0.5))

            toast_rect = pygame.Rect(slide_x, target_y, self._toast_w, self._toast_h)
            accent_color = TYPE_COLORS.get(toast["type"], UI_HIGHLIGHT)

            # Background (semi-transparent dark)
            bg = pygame.Surface((self._toast_w, self._toast_h), pygame.SRCALPHA)
            bg.fill((20, 20, 40, min(alpha, 230)))
            # Accent left stripe
            stripe = pygame.Surface((4, self._toast_h), pygame.SRCALPHA)
            stripe.fill((*accent_color, min(alpha, 255)))
            bg.blit(stripe, (0, 0))
            surface.blit(bg, toast_rect.topleft)

            # Border
            border_surf = pygame.Surface((self._toast_w, self._toast_h), pygame.SRCALPHA)
            pygame.draw.rect(border_surf, (*accent_color, min(alpha // 2, 80)),
                             border_surf.get_rect(), 1, border_radius=8)
            surface.blit(border_surf, toast_rect.topleft)

            # Icon
            icon_text = TYPE_ICONS.get(toast["type"], "i")
            icon_surf = self._icon_font.render(icon_text, True, accent_color)
            icon_surf.set_alpha(alpha)
            surface.blit(icon_surf, (toast_rect.x + 14, toast_rect.centery - icon_surf.get_height() // 2))

            # Message text
            msg_surf = self._font.render(toast["message"], True, UI_TEXT_PRIMARY)
            msg_surf.set_alpha(alpha)
            surface.blit(msg_surf, (toast_rect.x + 36, toast_rect.centery - msg_surf.get_height() // 2))

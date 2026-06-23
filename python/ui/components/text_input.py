"""Text input widget with cursor, selection, clipboard, and IME support."""
import math
import subprocess
import sys
import pygame
from ui.render_helpers import draw_rect_alpha
from ui.colors import UI_TEXT_PRIMARY, UI_HIGHLIGHT, UI_DANGER

# Shared clipboard fallback (class-level so copy/paste works across instances)
_last_copied_text: str = ""


def _get_clipboard_text() -> str:
    """Get text from system clipboard. Tries pygame.scrap first, then platform CLI."""
    try:
        if pygame.scrap.get_init():
            text = pygame.scrap.get(pygame.SCRAP_TEXT)
            if text:
                return text.decode("utf-8", errors="replace")
    except Exception:
        pass
    return _platform_clipboard_get()


def _set_clipboard_text(text: str):
    """Set text to system clipboard and internal fallback."""
    global _last_copied_text
    _last_copied_text = text
    try:
        if pygame.scrap.get_init():
            pygame.scrap.put(pygame.SCRAP_TEXT, text.encode("utf-8"))
            return
    except Exception:
        pass
    _platform_clipboard_set(text)


def _platform_clipboard_get() -> str:
    try:
        if sys.platform == "win32":
            result = subprocess.run(
                ["powershell", "-Command", "Get-Clipboard"],
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0:
                return result.stdout
        elif sys.platform == "darwin":
            result = subprocess.run(
                ["pbpaste"], capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0:
                return result.stdout
        else:
            result = subprocess.run(
                ["xclip", "-selection", "clipboard", "-o"],
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0:
                return result.stdout
    except Exception:
        pass
    return ""


def _platform_clipboard_set(text: str):
    try:
        if sys.platform == "win32":
            subprocess.run(
                ["powershell", "-Command", f"Set-Clipboard -Value '{text}'"],
                capture_output=True, timeout=2,
            )
        elif sys.platform == "darwin":
            subprocess.run(
                ["pbcopy"], input=text, capture_output=True, text=True, timeout=2,
            )
        else:
            subprocess.run(
                ["xclip", "-selection", "clipboard"],
                input=text, capture_output=True, text=True, timeout=2,
            )
    except Exception:
        pass


# Initialize pygame scrap on import if available
try:
    pygame.scrap.init()
except Exception:
    pass


class TextInput:
    """A text input widget with full editing capabilities.

    Supports: cursor movement, text selection, clipboard (Ctrl+C/V/X),
    IME composition, placeholder text, max length, validators, and submit callback.
    """

    def __init__(self, rect: pygame.Rect, font: pygame.font.Font,
                 placeholder: str = "", max_length: int = 0,
                 validator=None, on_submit=None):
        self.rect = rect
        self.font = font
        self.placeholder = placeholder
        self.max_length = max_length
        self.validator = validator  # Callable[[str], bool] or None
        self.on_submit = on_submit  # Callable[[str], None] or None

        self._text: str = ""
        self._cursor_pos: int = 0
        self._sel_start: int | None = None  # None = no selection
        self._focused: bool = False
        self._cursor_blink: float = 0.0
        self._composition: str = ""  # Current IME composing text
        self._composition_cursor: int = 0
        self._scroll_offset: int = 0  # Horizontal scroll for long text

        # Error shake animation
        self._shaking: bool = False
        self._shake_elapsed: float = 0.0
        self._shake_duration: float = 0.35

    # ── Properties ─────────────────────────────────────────────────

    @property
    def text(self) -> str:
        return self._text

    @text.setter
    def text(self, value: str):
        self._text = value
        self._cursor_pos = min(self._cursor_pos, len(value))
        self._sel_start = None
        self._scroll_offset = 0

    @property
    def focused(self) -> bool:
        return self._focused

    def focus(self):
        self._focused = True
        self._cursor_blink = 0.0

    def blur(self):
        self._focused = False
        self._sel_start = None
        self._composition = ""

    def shake(self):
        """Trigger a brief red-border shake animation (for validation errors)."""
        self._shaking = True
        self._shake_elapsed = 0.0

    # ── Event handling ─────────────────────────────────────────────

    def handle_event(self, event: pygame.event.Event) -> bool:
        """Handle a pygame event. Returns True if the event was consumed."""
        if not self._focused:
            if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                if self.rect.collidepoint(event.pos):
                    self.focus()
                    # Set cursor position based on click
                    rx = event.pos[0] - self.rect.x - 8 + self._scroll_offset
                    self._cursor_pos = self._get_pos_from_x(rx)
                    self._sel_start = None
                    self._cursor_blink = 0.0
                    self._composition = ""
                    return True
            return False

        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            # Click outside loses focus
            if not self.rect.collidepoint(event.pos):
                self.blur()
                return False
            # Click inside sets cursor
            rx = event.pos[0] - self.rect.x - 8 + self._scroll_offset
            self._cursor_pos = self._get_pos_from_x(rx)
            self._sel_start = None
            self._cursor_blink = 0.0
            self._composition = ""
            return True

        if event.type == pygame.KEYDOWN:
            return self._handle_keydown(event)

        if event.type == pygame.TEXTEDITING:
            self._composition = event.text if event.text else ""
            self._composition_cursor = event.start if hasattr(event, 'start') else 0
            return True

        if event.type == pygame.TEXTINPUT:
            self._commit_text(event.text)
            return True

        return False

    def _handle_keydown(self, event: pygame.event.Event) -> bool:
        """Handle KEYDOWN events. Returns True if consumed."""
        shift = event.mod & pygame.KMOD_SHIFT
        ctrl = event.mod & pygame.KMOD_CTRL

        if event.key == pygame.K_BACKSPACE:
            if self._has_selection():
                self._delete_selection()
            elif self._cursor_pos > 0:
                self._cursor_pos -= 1
                self._text = self._text[:self._cursor_pos] + self._text[self._cursor_pos + 1:]
            self._composition = ""
            self._cursor_blink = 0.0
            return True

        if event.key == pygame.K_DELETE:
            if self._has_selection():
                self._delete_selection()
            elif self._cursor_pos < len(self._text):
                self._text = self._text[:self._cursor_pos] + self._text[self._cursor_pos + 1:]
            self._composition = ""
            self._cursor_blink = 0.0
            return True

        if ctrl and event.key == pygame.K_a:
            self._select_all()
            return True

        if ctrl and event.key == pygame.K_c:
            self._copy()
            return True

        if ctrl and event.key == pygame.K_v:
            self._paste()
            self._composition = ""
            return True

        if ctrl and event.key == pygame.K_x:
            self._copy()
            self._delete_selection()
            self._composition = ""
            return True

        if event.key == pygame.K_LEFT:
            if self._has_selection() and not shift:
                self._cursor_pos = self._sel_min()
            else:
                self._cursor_pos = max(0, self._cursor_pos - 1)
            if shift:
                self._extend_selection()
            else:
                self._sel_start = None
            self._cursor_blink = 0.0
            return True

        if event.key == pygame.K_RIGHT:
            if self._has_selection() and not shift:
                self._cursor_pos = self._sel_max()
            else:
                self._cursor_pos = min(len(self._text), self._cursor_pos + 1)
            if shift:
                self._extend_selection()
            else:
                self._sel_start = None
            self._cursor_blink = 0.0
            return True

        if event.key == pygame.K_HOME:
            self._cursor_pos = 0
            if shift:
                self._extend_selection()
            else:
                self._sel_start = None
            self._cursor_blink = 0.0
            return True

        if event.key == pygame.K_END:
            self._cursor_pos = len(self._text)
            if shift:
                self._extend_selection()
            else:
                self._sel_start = None
            self._cursor_blink = 0.0
            return True

        if event.key == pygame.K_RETURN or event.key == pygame.K_KP_ENTER:
            if self.on_submit:
                self.on_submit(self._text)
            return True

        if event.key == pygame.K_ESCAPE:
            self.blur()
            return True

        return False

    def _commit_text(self, text: str):
        """Commit finalized text (from TEXTINPUT or KEYDOWN fallback)."""
        if self._has_selection():
            self._delete_selection()
        if self.max_length > 0 and len(self._text) + len(text) > self.max_length:
            return
        if self.validator:
            new_text = self._text[:self._cursor_pos] + text + self._text[self._cursor_pos:]
            if not self.validator(new_text):
                self.shake()
                return
        self._text = (self._text[:self._cursor_pos] + text +
                      self._text[self._cursor_pos:])
        self._cursor_pos += len(text)
        self._sel_start = None
        self._composition = ""
        self._cursor_blink = 0.0

    # ── Selection helpers ─────────────────────────────────────────

    def _has_selection(self) -> bool:
        return self._sel_start is not None and self._sel_start != self._cursor_pos

    def _sel_min(self) -> int:
        return min(self._sel_start or 0, self._cursor_pos)

    def _sel_max(self) -> int:
        return max(self._sel_start or 0, self._cursor_pos)

    def _delete_selection(self):
        if self._has_selection():
            lo, hi = self._sel_min(), self._sel_max()
            self._text = self._text[:lo] + self._text[hi:]
            self._cursor_pos = lo
            self._sel_start = None

    def _extend_selection(self):
        if self._sel_start is None:
            self._sel_start = self._cursor_pos

    def _select_all(self):
        self._sel_start = 0
        self._cursor_pos = len(self._text)
        self._cursor_blink = 0.0

    def _copy(self):
        if self._has_selection():
            selected = self._text[self._sel_min():self._sel_max()]
            _set_clipboard_text(selected)

    def _paste(self):
        clipboard_text = _get_clipboard_text()
        if not clipboard_text:
            clipboard_text = _last_copied_text
        if clipboard_text:
            clean = clipboard_text.replace("\n", "").replace("\r", "")
            for ch in clean:
                if not ch.isprintable():
                    continue
                if self._has_selection():
                    self._delete_selection()
                if self.max_length > 0 and len(self._text) >= self.max_length:
                    break
                if self.validator:
                    new_text = (self._text[:self._cursor_pos] + ch +
                                self._text[self._cursor_pos:])
                    if not self.validator(new_text):
                        continue
                self._text = (self._text[:self._cursor_pos] + ch +
                              self._text[self._cursor_pos:])
                self._cursor_pos += 1
            self._sel_start = None

    # ── Cursor helpers ─────────────────────────────────────────────

    def _get_pos_from_x(self, x: int) -> int:
        """Convert pixel x offset to character position."""
        best = 0
        best_dist = abs(x)
        for i in range(len(self._text) + 1):
            w = self.font.size(self._text[:i])[0]
            dist = abs(w - x)
            if dist < best_dist:
                best_dist = dist
                best = i
        return best

    def _cursor_x_in_text(self, pos: int) -> int:
        return self.font.size(self._text[:pos])[0]

    # ── Update ─────────────────────────────────────────────────────

    def update(self, dt: float):
        self._cursor_blink += dt
        if self._shaking:
            self._shake_elapsed += dt
            if self._shake_elapsed >= self._shake_duration:
                self._shaking = False
                self._shake_elapsed = 0.0

    # ── Drawing ────────────────────────────────────────────────────

    def draw(self, surface: pygame.Surface):
        rect = self.rect

        # Shake offset
        shake_x = 0
        if self._shaking:
            progress = self._shake_elapsed / self._shake_duration
            shake_x = int(math.sin(progress * math.pi * 4) * 3 * (1 - progress))

        draw_rect = rect.move(shake_x, 0)

        # Background
        pygame.draw.rect(surface, (25, 25, 45), draw_rect, border_radius=6)

        # Border
        if self._shaking:
            border_color = UI_DANGER
        elif self._focused:
            border_color = UI_HIGHLIGHT
        else:
            border_color = (120, 120, 160)
        pygame.draw.rect(surface, border_color, draw_rect, 2, border_radius=6)

        # Clip to prevent text overflow
        inner_rect = draw_rect.inflate(-12, -4)
        surface.set_clip(inner_rect)

        cx = draw_rect.x + 8
        cy = draw_rect.centery

        display_text = self._text
        if self._composition:
            # Insert IME composition at cursor position
            pos = self._cursor_pos
            display_text = (self._text[:pos] + self._composition +
                            self._text[pos:])

        if display_text:
            # Determine selection range in display coordinates
            sel_lo = self._sel_min() if self._has_selection() else 0
            sel_hi = self._sel_max() if self._has_selection() else 0

            # Draw selection highlight
            if self._has_selection() and self._focused:
                x1 = cx + self._cursor_x_in_text(sel_lo)
                x2 = cx + self._cursor_x_in_text(sel_hi)
                sel_rect = pygame.Rect(x1, draw_rect.y + 4, x2 - x1, draw_rect.h - 8)
                draw_rect_alpha(surface, (*UI_HIGHLIGHT, 50), sel_rect, border_radius=3)

            # Draw text
            txt_surf = self.font.render(display_text, True, UI_TEXT_PRIMARY)
            surface.blit(txt_surf, (cx, cy - txt_surf.get_height() // 2))

            # Draw IME composition underline
            if self._composition and self._focused:
                comp_start = self._cursor_pos
                sx = cx + self._cursor_x_in_text(comp_start)
                ex = sx + self.font.size(self._composition)[0]
                uy = cy + txt_surf.get_height() // 2 + 2
                # Dotted underline for composition
                for px in range(int(sx), int(ex), 4):
                    pygame.draw.line(surface, UI_HIGHLIGHT,
                                     (px, uy), (px + 2, uy), 1)

            # Draw cursor
            if self._focused and int(self._cursor_blink * 2) % 2 == 0:
                if self._composition:
                    # Cursor within composition
                    cursor_x = cx + self._cursor_x_in_text(
                        self._cursor_pos + self._composition_cursor)
                else:
                    cursor_x = cx + self._cursor_x_in_text(self._cursor_pos)
                cursor_x = min(cursor_x, draw_rect.right - 4)
                pygame.draw.line(surface, UI_HIGHLIGHT,
                                 (cursor_x, draw_rect.y + 6),
                                 (cursor_x, draw_rect.y + draw_rect.h - 6), 2)
        else:
            # Draw placeholder
            if self.placeholder and not self._focused:
                ph_surf = self.font.render(self.placeholder, True, (70, 70, 100))
                surface.blit(ph_surf, (cx, cy - ph_surf.get_height() // 2))
            # Cursor at position 0 when empty
            if self._focused and int(self._cursor_blink * 2) % 2 == 0:
                pygame.draw.line(surface, UI_HIGHLIGHT,
                                 (cx, draw_rect.y + 6),
                                 (cx, draw_rect.y + draw_rect.h - 6), 2)

        surface.set_clip(None)

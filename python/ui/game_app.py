"""Main Pygame application with game loop and proportional letterbox scaling."""
import pygame
import sys
from config import SCREEN_WIDTH, SCREEN_HEIGHT, FPS
from ui.screen_manager import ScreenManager
from ui.screens.title_screen import TitleScreen


class GameApp:
    """Main application singleton managing the Pygame window and screen stack."""

    def _initial_window_size(self) -> tuple[int, int]:
        """Choose a first window size that fits the current desktop."""
        try:
            desktop_w, desktop_h = pygame.display.get_desktop_sizes()[0]
        except (pygame.error, IndexError, AttributeError):
            info = pygame.display.Info()
            desktop_w, desktop_h = info.current_w, info.current_h

        if desktop_w <= 0 or desktop_h <= 0:
            return SCREEN_WIDTH, SCREEN_HEIGHT

        max_w = max(320, desktop_w - 80)
        max_h = max(240, desktop_h - 120)
        scale = min(1.0, max_w / SCREEN_WIDTH, max_h / SCREEN_HEIGHT)
        return max(1, int(SCREEN_WIDTH * scale)), max(1, int(SCREEN_HEIGHT * scale))

    def __init__(self):
        # Ensure drag-and-drop events are enabled (SDL2 may disable by default on some builds)
        pygame.init()
        try:
            pygame.event.set_allowed([
                pygame.DROPFILE, pygame.DROPTEXT,
                pygame.DROPBEGIN, pygame.DROPCOMPLETE,
            ])
        except (AttributeError, pygame.error):
            pass  # Drop events not available on this platform

        pygame.display.set_caption("宝可梦卡牌对战 - Pokemon TCG Battle")
        self.win_w, self.win_h = self._initial_window_size()
        self.screen = pygame.display.set_mode(
            (self.win_w, self.win_h),
            pygame.RESIZABLE
        )
        # Virtual surface at design resolution — display-compatible format
        self.virtual = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT)).convert()
        # Letterbox state (computed each frame)
        self._lb_scale = 1.0
        self._lb_ox = 0
        self._lb_oy = 0

        self.clock = pygame.time.Clock()
        self.running = True
        self.screen_manager = ScreenManager()
        self.screen_manager._app = self  # For screens to access GameApp
        self.debug_session = None
        self.game_state = None
        self.turn_manager = None
        self.apply_type_matchups = False

        self.screen_manager.push_screen(TitleScreen(self.screen_manager))

        # Initialize audio
        from ui.audio_manager import get_audio
        get_audio().init()

    def _to_virtual(self, wx: float, wy: float) -> tuple[float, float]:
        """Convert window-pixel coordinates to virtual design coordinates."""
        vx = (wx - self._lb_ox) / self._lb_scale
        vy = (wy - self._lb_oy) / self._lb_scale
        return (vx, vy)

    def run(self):
        """Main game loop."""
        try:
            while self.running:
                dt = self.clock.tick(FPS) / 1000.0

                for event in pygame.event.get():
                    if event.type == pygame.QUIT:
                        self.running = False

                    elif event.type == pygame.VIDEORESIZE:
                        self.win_w, self.win_h = event.w, event.h
                        self.screen = pygame.display.set_mode(
                            (event.w, event.h), pygame.RESIZABLE
                        )

                    elif event.type == pygame.MOUSEMOTION:
                        vx, vy = self._to_virtual(*event.pos)
                        event = pygame.event.Event(event.type, {
                            'pos': (vx, vy), 'rel': event.rel,
                            'buttons': event.buttons,
                        })

                    elif event.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP):
                        vx, vy = self._to_virtual(*event.pos)
                        event = pygame.event.Event(event.type, {
                            'pos': (vx, vy), 'button': event.button,
                        })

                    elif event.type == pygame.MOUSEWHEEL:
                        mx, my = pygame.mouse.get_pos()
                        vx, vy = self._to_virtual(mx, my)
                        event = pygame.event.Event(event.type, {
                            'pos': (vx, vy), 'x': event.x, 'y': event.y,
                            'flipped': getattr(event, 'flipped', False),
                        })

                    self.screen_manager.handle_event(event)

                # Update
                self.screen_manager.update(dt)

                # Draw to virtual surface at design resolution
                self.screen_manager.draw(self.virtual)

                # Compute letterbox: scale to fit, preserve aspect ratio
                scale = min(self.win_w / SCREEN_WIDTH, self.win_h / SCREEN_HEIGHT)
                self._lb_scale = scale
                sw = int(SCREEN_WIDTH * scale)
                sh = int(SCREEN_HEIGHT * scale)
                self._lb_ox = (self.win_w - sw) // 2
                self._lb_oy = (self.win_h - sh) // 2

                # Scale and center on screen (smoothscale for quality at any window size)
                if sw == SCREEN_WIDTH and sh == SCREEN_HEIGHT:
                    scaled = self.virtual
                else:
                    scaled = pygame.transform.smoothscale(self.virtual, (sw, sh))
                self.screen.fill((0, 0, 0))
                self.screen.blit(scaled, (self._lb_ox, self._lb_oy))
                pygame.display.flip()
        except KeyboardInterrupt:
            pass  # User pressed Ctrl+C — clean exit, no traceback
        finally:
            self.screen_manager.shutdown()
            pygame.quit()
        sys.exit()

    def start_game(self, deck1_cards: list[str], deck2_cards: list[str]):
        """Initialize a local-only debugging match."""
        from ui.debug_match_session import DebugMatchSession
        from ui.screens.game_screen import GameScreen

        self.debug_session = DebugMatchSession.create(
            deck1_cards,
            deck2_cards,
            apply_type_matchups=self.apply_type_matchups,
        )
        self.game_state = self.debug_session.state
        self.turn_manager = self.debug_session.turn_manager
        game_screen = GameScreen(self.screen_manager, self.game_state, self.turn_manager)
        self.screen_manager.push_screen(game_screen)

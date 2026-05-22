"""Main Pygame application with game loop and proportional letterbox scaling."""
import pygame
import sys
from config import SCREEN_WIDTH, SCREEN_HEIGHT, FPS, TITLE, NETWORK_PORT
from ui.screen_manager import ScreenManager
from ui.screens.title_screen import TitleScreen


class GameApp:
    """Main application singleton managing the Pygame window and screen stack."""

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
        self.screen = pygame.display.set_mode(
            (SCREEN_WIDTH, SCREEN_HEIGHT),
            pygame.RESIZABLE | pygame.SCALED
        )
        # Virtual surface at design resolution — display-compatible format
        self.virtual = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT)).convert()
        self.win_w = SCREEN_WIDTH
        self.win_h = SCREEN_HEIGHT
        # Letterbox state (computed each frame)
        self._lb_scale = 1.0
        self._lb_ox = 0
        self._lb_oy = 0

        self.clock = pygame.time.Clock()
        self.running = True
        self.screen_manager = ScreenManager()
        self.screen_manager._app = self  # For screens to access GameApp
        self.game_state = None
        self.turn_manager = None
        self.network_manager = None
        self.is_remote_host = False
        self.is_remote_client = False

        # Auto-connect support (set by main.py CLI args before run())
        self.auto_connect: str | None = None       # "host", "client", or "relay"
        self.auto_host_port: int = NETWORK_PORT
        self.auto_client_ip: str = "localhost"
        self.auto_client_port: int = NETWORK_PORT
        self.auto_relay_host: str = ""
        self.auto_relay_port: int = 8766
        self.auto_relay_room: str | None = None

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

        pygame.quit()
        sys.exit()

    def start_game(self, deck1_cards: list[str], deck2_cards: list[str]):
        """Initialize game state and start a new match."""
        from engine.game_state import GameState
        from engine.turn_manager import TurnManager
        from ui.screens.game_screen import GameScreen

        self.game_state = GameState()
        self.game_state.setup_game(deck1_cards, deck2_cards)
        self.turn_manager = TurnManager(self.game_state)
        game_screen = GameScreen(self.screen_manager, self.game_state, self.turn_manager)
        self.screen_manager.push_screen(game_screen)

    def start_remote_host(self, port: int):
        """Start hosting a remote game."""
        from network.network_manager import NetworkManager
        self.network_manager = NetworkManager()
        self.network_manager.start_host(port)
        self.is_remote_host = True
        self.is_remote_client = False

    def start_remote_client(self, host: str, port: int):
        """Connect to a remote host."""
        from network.network_manager import NetworkManager
        self.network_manager = NetworkManager()
        self.network_manager.connect_to_host(host, port)
        self.is_remote_host = False
        self.is_remote_client = True

    def start_relay_host(self, server_host: str, server_port: int):
        """通过中继服务器创建房间（房主角色）."""
        from network.network_manager import NetworkManager
        self.network_manager = NetworkManager()
        self.network_manager.connect_to_relay(server_host, server_port, is_host=True)
        self.is_remote_host = True
        self.is_remote_client = False

    def start_relay_client(self, server_host: str, server_port: int, room_code: str):
        """通过中继服务器加入房间（挑战者角色）."""
        from network.network_manager import NetworkManager
        self.network_manager = NetworkManager()
        self.network_manager.connect_to_relay(
            server_host, server_port, is_host=False, room_code=room_code
        )
        self.is_remote_host = False
        self.is_remote_client = True

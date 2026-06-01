"""Title screen — main menu."""
import math
import random
import pygame
from utils.logger import get_logger

logger = get_logger(__name__)
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_TEXT_PRIMARY, UI_BUTTON, UI_BUTTON_HOVER, UI_HIGHLIGHT,
)
from ui.ui_theme import draw_button
from ui.font_manager import get_font, get_font_size
from config import SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT


class TitleScreen(Screen):
    """Main title screen."""

    def __init__(self, manager: ScreenManager):
        super().__init__(manager)
        self.font_title = get_font("title")
        self.font_body = get_font("body")
        self.font_small = get_font("normal")

        btn_w, btn_h = 300, 54
        btn_gap = 12
        btn_x = (SCREEN_WIDTH - btn_w) // 2
        btn_y = SCREEN_HEIGHT // 2 + 20
        self.start_button = pygame.Rect(btn_x, btn_y, btn_w, btn_h)
        self.start_hover = False

        challenge_btn_y = btn_y + btn_h + btn_gap
        self.challenge_button = pygame.Rect(btn_x, challenge_btn_y, btn_w, btn_h)
        self.challenge_hover = False

        training_btn_y = challenge_btn_y + btn_h + btn_gap
        self.training_button = pygame.Rect(btn_x, training_btn_y, btn_w, btn_h)
        self.training_hover = False

        remote_btn_y = training_btn_y + btn_h + btn_gap
        self.remote_button = pygame.Rect(btn_x, remote_btn_y, btn_w, btn_h)
        self.remote_hover = False

        img_btn_y = remote_btn_y + btn_h + btn_gap
        self.cardimg_button = pygame.Rect(btn_x, img_btn_y, btn_w, btn_h)
        self.cardimg_hover = False

        toggle_y = img_btn_y + btn_h + 16
        self.matchup_toggle = pygame.Rect(btn_x, toggle_y, btn_w, 44)
        self.matchup_hover = False

        # Help button (small "?" in top-right corner)
        help_size = 36
        self.help_button = pygame.Rect(
            SCREEN_WIDTH - help_size - 20, 20, help_size, help_size
        )
        self.help_hover = False

        # Animated floating card backs
        self._bg_time = 0.0
        self._bg_cards = []
        for _ in range(6):
            self._bg_cards.append({
                "x": random.randint(80, SCREEN_WIDTH - 80),
                "y": random.randint(80, SCREEN_HEIGHT - 80),
                "angle": random.uniform(0, 360),
                "rot_speed": random.uniform(-10, 10),
                "phase": random.uniform(0, math.pi * 2),
                "alpha": random.randint(10, 25),
            })

        # Load card back image
        from ui.image_manager import get_image_manager
        self._card_back_img = get_image_manager().get_card_back("卡背.webp")

        # Button entrance animation
        self._entrance_time = 0.0
        self._entrance_done = False

        # Featured card showcase (cards from existing decks)
        self._featured_surfs = []
        self._featured_timer = 0.0
        self._load_featured_cards()

        # Pre-rendered playmat background
        self._bg_surface = self._create_playmat_background()

    def _load_featured_cards(self):
        """Pick random cards from the deck pool for background showcase."""
        from data.deck_definitions import ALL_CARD_IDS
        from data.card_registry import CardRegistry
        from ui.image_manager import get_image_manager
        import random as _random

        if not CardRegistry.is_initialized():
            try:
                CardRegistry.initialize(ALL_CARD_IDS, use_api=False)
            except Exception:
                return

        img_mgr = get_image_manager()
        fw, fh = CARD_WIDTH * 2, CARD_HEIGHT * 2

        # Pick up to 5 random Pokemon cards from the pool
        candidates = []
        for cid in ALL_CARD_IDS:
            card = CardRegistry.get(cid)
            if card and card.is_pokemon:
                candidates.append((cid, card.name))

        _random.shuffle(candidates)
        for cid, name in candidates[:5]:
            surf = img_mgr.get_card_image(name, cid)
            if surf:
                surf = pygame.transform.smoothscale(surf, (fw, fh))
                self._featured_surfs.append(surf)

    def _create_playmat_background(self) -> pygame.Surface:
        """Create a textured playmat-style background."""
        bg = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))

        # Dark gradient from top to bottom
        for y in range(SCREEN_HEIGHT):
            t = y / SCREEN_HEIGHT
            r = int(12 + 10 * t)
            g = int(14 + 14 * t)
            b = int(28 + 20 * t)
            pygame.draw.line(bg, (r, g, b), (0, y), (SCREEN_WIDTH, y))

        # Subtle grid lines (playmat feel)
        grid_color = (28, 28, 48, 25)
        for x in range(0, SCREEN_WIDTH, 80):
            s = pygame.Surface((1, SCREEN_HEIGHT), pygame.SRCALPHA)
            s.fill(grid_color)
            bg.blit(s, (x, 0))
        for y in range(0, SCREEN_HEIGHT, 80):
            s = pygame.Surface((SCREEN_WIDTH, 1), pygame.SRCALPHA)
            s.fill(grid_color)
            bg.blit(s, (0, y))

        return bg

    def handle_event(self, event: pygame.event.Event):
        if event.type == pygame.MOUSEMOTION:
            self.start_hover = self.start_button.collidepoint(event.pos)
            self.challenge_hover = self.challenge_button.collidepoint(event.pos)
            self.training_hover = self.training_button.collidepoint(event.pos)
            self.remote_hover = self.remote_button.collidepoint(event.pos)
            self.cardimg_hover = self.cardimg_button.collidepoint(event.pos)
            self.matchup_hover = self.matchup_toggle.collidepoint(event.pos)
            self.help_hover = self.help_button.collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self.start_hover:
                self._start_game()
            elif self.challenge_hover:
                self._start_challenge()
            elif self.training_hover:
                self._open_ai_training()
            elif self.remote_hover:
                self._start_remote_game()
            elif self.cardimg_hover:
                self._open_card_image_manager()
            elif self.matchup_hover:
                app = getattr(self.manager, "_app", None)
                if app:
                    app.apply_type_matchups = not app.apply_type_matchups
            elif self.help_hover:
                self._show_help()

    def _open_card_image_manager(self):
        from data.deck_definitions import ALL_CARD_IDS
        from data.card_registry import CardRegistry
        if not CardRegistry.is_initialized():
            try:
                CardRegistry.initialize(ALL_CARD_IDS, use_api=False)
            except Exception:
                pass
        from ui.screens.card_image_screen import CardImageScreen
        self.manager.push_screen(CardImageScreen(self.manager))

    def _load_available_decks(self):
        from data.deck_definitions import (FIRE_DECK, WATER_DECK, PSYCHIC_DECK_NATU,
                                            LIGHTNING_DECK, FIGHTING_DECK, COLORLESS_DECK,
                                            DRAGON_DECK, GRASS_DECK, ALL_CARD_IDS)
        from data.card_registry import CardRegistry

        if not CardRegistry.is_initialized():
            try:
                CardRegistry.initialize(ALL_CARD_IDS, use_api=True)
            except Exception as e:
                logger.error("card loading error: %s", e)
                CardRegistry.initialize(ALL_CARD_IDS, use_api=False)

        if len(CardRegistry._cards) == 0:
            from data.card_registry import create_offline_cards
            create_offline_cards(ALL_CARD_IDS)

        available_decks = {
            "fire": FIRE_DECK,
            "water": WATER_DECK,
            "psychic": PSYCHIC_DECK_NATU,
            "lightning": LIGHTNING_DECK,
            "fighting": FIGHTING_DECK,
            "colorless": COLORLESS_DECK,
            "dragon": DRAGON_DECK,
            "grass": GRASS_DECK,
        }

        return available_decks

    def _start_game(self):
        available_decks = self._load_available_decks()

        from ui.screens.deck_select import DeckSelectScreen
        self.manager.push_screen(DeckSelectScreen(self.manager, available_decks))

    def _start_challenge(self):
        available_decks = self._load_available_decks()

        from ui.screens.deck_select import DeckSelectScreen
        self.manager.push_screen(
            DeckSelectScreen(self.manager, available_decks, mode="challenge")
        )

    def _open_ai_training(self):
        from ui.screens.ai_training_screen import AITrainingScreen
        self.manager.push_screen(AITrainingScreen(self.manager))

    def _show_help(self):
        """Show a help overlay with game rules."""
        from ui.screens.help_screen import HelpScreen
        from ui.transitions import SlideTransition
        self.manager.push_screen(HelpScreen(self.manager), SlideTransition(0.3, "right"))

    def _start_remote_game(self):
        """Navigate to the remote battle lobby."""
        from ui.screens.lobby_screen import LobbyScreen
        self.manager.push_screen(LobbyScreen(self.manager))

    def _do_auto_connect(self):
        """Auto-start network and go to lobby with auto-connect enabled."""
        app = getattr(self.manager, '_app', None)
        if not app:
            return

        from data.deck_definitions import ALL_CARD_IDS
        from data.card_registry import CardRegistry
        if not CardRegistry.is_initialized():
            try:
                CardRegistry.initialize(ALL_CARD_IDS, use_api=False)
            except Exception:
                pass

        if app.auto_connect == "relay":
            from config import RELAY_SERVER_HOST, RELAY_SERVER_PORT
            host = app.auto_relay_host or RELAY_SERVER_HOST
            port = app.auto_relay_port or RELAY_SERVER_PORT
            if app.auto_relay_room:
                app.start_relay_client(host, port, app.auto_relay_room)
            else:
                app.start_relay_host(host, port)
        elif app.auto_connect == "host":
            app.start_remote_host(app.auto_host_port)
        elif app.auto_connect == "client":
            app.start_remote_client(app.auto_client_ip, app.auto_client_port)

        from ui.screens.lobby_screen import LobbyScreen
        lobby = LobbyScreen(self.manager)
        if app.auto_connect == "relay":
            if app.auto_relay_room:
                lobby.auto_mode = "relay_client"
                if lobby._room_code_input:
                    lobby._room_code_input.text = app.auto_relay_room
            else:
                lobby.auto_mode = "relay_host"
            if lobby._relay_host_input:
                lobby._relay_host_input.text = host
        else:
            lobby.auto_mode = app.auto_connect
        app.auto_connect = None
        self.manager.push_screen(lobby)

    def on_enter(self):
        """Check for auto-connect CLI flags and skip to lobby if set."""
        app = getattr(self.manager, '_app', None)
        if app and app.auto_connect:
            self._auto_connect_delay = 0.3

    def update(self, dt: float):
        self._bg_time += dt
        if not self._entrance_done:
            self._entrance_time += dt
            if self._entrance_time >= 0.6:
                self._entrance_done = True
        self._featured_timer += dt

        if hasattr(self, '_auto_connect_delay') and self._auto_connect_delay > 0:
            self._auto_connect_delay -= dt
            if self._auto_connect_delay <= 0:
                self._do_auto_connect()

    def draw(self, surface: pygame.Surface):
        # Playmat background
        surface.blit(self._bg_surface, (0, 0))

        # Featured card showcase — two cards side by side
        if len(self._featured_surfs) >= 2:
            cycle = 5.0
            base_idx = int(self._featured_timer / cycle) % len(self._featured_surfs)
            idx2 = (base_idx + 1) % len(self._featured_surfs)
            alpha = int(20 + 10 * math.sin(self._bg_time * 0.5))
            angle_L = math.sin(self._bg_time * 0.3) * 3
            angle_R = math.sin(self._bg_time * 0.3 + 0.5) * 3
            gap = 40
            center_x = SCREEN_WIDTH // 2
            center_y = SCREEN_HEIGHT // 2 - 60
            for idx, angle in ((base_idx, angle_L), (idx2, angle_R)):
                surf = self._featured_surfs[idx]
                s = pygame.Surface(surf.get_size(), pygame.SRCALPHA)
                s.blit(surf, (0, 0))
                rotated = pygame.transform.rotate(s, angle)
                rotated.set_alpha(alpha)
                rw, rh = rotated.get_width(), rotated.get_height()
                if idx == base_idx:
                    x = center_x - gap - rw
                else:
                    x = center_x + gap
                y = center_y - rh // 2
                surface.blit(rotated, (x, y))

        # Floating card backs
        for c in self._bg_cards:
            cx, cy = c["x"], c["y"]
            angle = c["angle"] + c["rot_speed"] * self._bg_time
            alpha = int(c["alpha"] + 10 * math.sin(self._bg_time * 0.8 + c["phase"]))
            alpha = max(8, min(50, alpha))

            card_w, card_h = 70, 98
            if self._card_back_img:
                scaled = pygame.transform.smoothscale(self._card_back_img, (card_w, card_h))
                alpha_surf = pygame.Surface((card_w, card_h), pygame.SRCALPHA)
                alpha_surf.blit(scaled, (0, 0))
                alpha_surf.set_alpha(alpha)
                rotated = pygame.transform.rotate(alpha_surf, angle)
            else:
                card_surf = pygame.Surface((card_w, card_h), pygame.SRCALPHA)
                pygame.draw.rect(card_surf, (40, 60, 140, alpha), card_surf.get_rect(), border_radius=6)
                pygame.draw.rect(card_surf, (200, 180, 60, alpha),
                               card_surf.get_rect(), 2, border_radius=6)
                inner = pygame.Rect(5, 5, card_w - 10, card_h - 10)
                pygame.draw.rect(card_surf, (40, 60, 140, alpha // 2), inner, 1, border_radius=3)
                rotated = pygame.transform.rotate(card_surf, angle)
            surface.blit(rotated, rotated.get_rect(center=(cx, cy)))

        # Title with a restrained glow
        glow_alpha = int(18 + 8 * math.sin(self._bg_time * 1.1))
        title_txt = self.font_title.render("宝可梦卡牌对战", True, UI_HIGHLIGHT)
        title_glow = self.font_title.render("宝可梦卡牌对战", True, (255, 230, 100))
        title_rect = title_txt.get_rect(center=(SCREEN_WIDTH // 2, SCREEN_HEIGHT // 3))

        for dx, dy in [(-2, 0), (2, 0), (0, -2), (0, 2)]:
            glow_surf = title_glow.copy()
            glow_surf.set_alpha(glow_alpha)
            surface.blit(glow_surf, glow_surf.get_rect(
                center=(SCREEN_WIDTH // 2 + dx, SCREEN_HEIGHT // 3 + dy)))
        surface.blit(title_txt, title_rect)

        sub_txt = self.font_body.render("双人对战", True, UI_TEXT_PRIMARY)
        sub_rect = sub_txt.get_rect(center=(SCREEN_WIDTH // 2, SCREEN_HEIGHT // 3 + 55))
        surface.blit(sub_txt, sub_rect)

        # Button entrance animation offset
        if not self._entrance_done:
            t = min(1.0, self._entrance_time / 0.6)
            ease = 1 - (1 - t) ** 3
            entry_offset = int((1 - ease) * 90)
        else:
            entry_offset = 0

        # Draw buttons with staggered entrance
        # Start button (slides first)
        start_rect = self.start_button.move(0, entry_offset // 3)
        draw_button(surface, start_rect, "开始游戏", self.font_body,
                    hovered=self.start_hover)

        # Remote button (slides second)
        challenge_rect = self.challenge_button.move(0, entry_offset // 2)
        draw_button(surface, challenge_rect, "挑战 AI", self.font_body,
                    hovered=self.challenge_hover)

        training_rect = self.training_button.move(0, entry_offset * 3 // 5)
        draw_button(surface, training_rect, "AI训练", self.font_body,
                    hovered=self.training_hover)

        remote_rect = self.remote_button.move(0, entry_offset * 2 // 3)
        draw_button(surface, remote_rect, "远程对战", self.font_body,
                    hovered=self.remote_hover)

        # Card image button (slides third)
        cardimg_rect = self.cardimg_button.move(0, entry_offset)
        draw_button(surface, cardimg_rect, "卡图管理", self.font_body,
                    hovered=self.cardimg_hover)

        app = getattr(self.manager, "_app", None)
        matchup_enabled = bool(getattr(app, "apply_type_matchups", False))
        toggle_rect = self.matchup_toggle.move(0, entry_offset)
        bg = UI_BUTTON_HOVER if self.matchup_hover else UI_BUTTON
        border = UI_HIGHLIGHT if matchup_enabled else UI_TEXT_PRIMARY
        pygame.draw.rect(surface, bg, toggle_rect, border_radius=8)
        pygame.draw.rect(surface, border, toggle_rect, 1, border_radius=8)
        knob_rect = pygame.Rect(
            toggle_rect.right - 54 if matchup_enabled else toggle_rect.x + 12,
            toggle_rect.y + 8,
            42,
            toggle_rect.h - 16,
        )
        pygame.draw.rect(
            surface,
            UI_HIGHLIGHT if matchup_enabled else (110, 116, 138),
            knob_rect,
            border_radius=7,
        )
        label = f"属性克制/抵抗：{'开' if matchup_enabled else '关'}"
        label_surf = self.font_small.render(label, True, UI_TEXT_PRIMARY)
        surface.blit(label_surf, label_surf.get_rect(center=toggle_rect.center))

        # Help button
        help_rect = self.help_button.move(0, entry_offset // 4)
        help_color = UI_BUTTON_HOVER if self.help_hover else UI_BUTTON
        pygame.draw.circle(surface, help_color, help_rect.center, help_rect.w // 2)
        pygame.draw.circle(surface, UI_TEXT_PRIMARY, help_rect.center, help_rect.w // 2, 2)
        help_txt = self.font_body.render("?", True, UI_TEXT_PRIMARY)
        surface.blit(help_txt, help_txt.get_rect(center=help_rect.center))

        # Version (bottom-left, doesn't overlap with help button)
        version_txt = self.font_small.render("v1.0 — Pokemon TCG Battle", True, (100, 100, 130))
        surface.blit(version_txt, (12, 8))

        # Footer
        footer_txt = self.font_small.render(
            "数据来源 pokemontcg.io API — 仅供学习交流",
            True, (120, 120, 150)
        )
        footer_rect = footer_txt.get_rect(center=(SCREEN_WIDTH // 2, SCREEN_HEIGHT - 30))
        surface.blit(footer_txt, footer_rect)

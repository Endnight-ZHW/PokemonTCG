"""联机大厅 — 支持局域网/服务器联机、对战前聊天."""
import math
import random
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_TEXT_PRIMARY, UI_BUTTON, UI_BUTTON_HOVER, UI_HIGHLIGHT,
    UI_SUCCESS, UI_DANGER, ENERGY_COLORS,
)
from ui.font_manager import get_font, get_font_size
from ui.render_helpers import draw_gradient_button, draw_rect_alpha, draw_energy_circle
from ui.components.text_input import TextInput
from ui.components.toast import ToastManager
from config import SCREEN_WIDTH, SCREEN_HEIGHT, NETWORK_PORT


# ── State machine ─────────────────────────────────────────────────

class LobbyState:
    MODE_SELECT = 0       # 选择联机方式
    LAN_HOST = 1          # 创建局域网房间
    LAN_CLIENT = 2        # 加入局域网房间
    RELAY_HOST = 3        # 创建服务器房间
    RELAY_CLIENT = 4      # 加入服务器房间
    RELAY_CONNECTED = 5   # 对手已加入，等待开始
    CONNECTING = 6        # 正在连接中


# ── Layout constants ──────────────────────────────────────────────

CARD_W, CARD_H = 720, 440
CARD_X = (SCREEN_WIDTH - CARD_W) // 2
CARD_Y = 150

STATUS_Y = CARD_Y + CARD_H + 28

# Mode select: two columns, each with create/join buttons
COL_W = 320
COL_GAP = 40
COLS_TOTAL = COL_W * 2 + COL_GAP
COL1_X = CARD_X + (CARD_W - COLS_TOTAL) // 2
COL2_X = COL1_X + COL_W + COL_GAP

BTN_W, BTN_H = 220, 50
SMALL_BTN_W, SMALL_BTN_H = 140, 40
INPUT_W = 280
INPUT_H = 38


class LobbyScreen(Screen):
    """远程对战大厅."""

    def __init__(self, manager: ScreenManager):
        super().__init__(manager)
        self.font_title = get_font("title_sm")
        self.font_subtitle = get_font("body_md")
        self.font_body = get_font("body")
        self.font_small = get_font("body_sm")
        self.font_code = get_font("title")
        self.font_chat_name = get_font_size(16)
        self.font_chat_msg = get_font_size(18)
        self.font_hint = get_font("normal")

        self.toasts = ToastManager()

        # ── State ──────────────────────────────────────────────────
        self._state = LobbyState.MODE_SELECT

        self.status_text: str = ""
        self.error_text: str = ""
        self.connected: bool = False
        self._is_host: bool = False

        # Auto-connect (CLI flags)
        self.auto_mode: str | None = None
        self._auto_relay_connect = False
        self._auto_connect_pending = False
        self._auto_connect_delay: float = 0.0

        # ── Network ────────────────────────────────────────────────
        self._nm = None
        self._connection_started = False
        self._pulse: float = 0.0
        self.host_port: int = NETWORK_PORT
        self.room_code_display: str = ""
        self._connect_origin_state: int = LobbyState.MODE_SELECT

        # ── Input fields ───────────────────────────────────────────
        self._ip_input: TextInput | None = None
        self._port_input: TextInput | None = None
        self._room_code_input: TextInput | None = None
        self._relay_host_input: TextInput | None = None

        # ── Chat ───────────────────────────────────────────────────
        self._chat_messages: list[dict] = []
        self._chat_input: TextInput | None = None
        self._chat_send_cooldown: float = 0.0

        # ── Background (pre-rendered for performance) ──────────────
        self._bg_gradient: pygame.Surface | None = None
        self._bg_energy: list[dict] = []
        self._energy_dot_cache: dict[tuple, pygame.Surface] = {}
        for _ in range(8):
            self._bg_energy.append({
                "x": random.uniform(0, SCREEN_WIDTH),
                "y": random.uniform(0, SCREEN_HEIGHT),
                "vx": random.uniform(-15, 15),
                "vy": random.uniform(-10, 10),
                "radius": random.randint(20, 50),
                "type": random.choice(list(ENERGY_COLORS)),
                "alpha": random.randint(5, 15),
                "phase": random.uniform(0, math.pi * 2),
            })

        # ── Button press / error ───────────────────────────────────
        self._pressing_btn: str | None = None
        self._press_anim: float = 0.0
        self._error_shake: float = 1.0  # Start > 0.35 = not shaking

        # ── Controls ───────────────────────────────────────────────
        self._controls: list[dict] = []
        self._init_widgets()

        # Back button
        self.back_btn = pygame.Rect(24, 16, 100, 36)
        self.back_hover = False
        self._mouse_pos = (-1, -1)

    # ── Helpers ────────────────────────────────────────────────────

    @property
    def network_manager(self):
        return self._nm

    @network_manager.setter
    def network_manager(self, nm):
        self._nm = nm

    def _get_app(self):
        return getattr(self.manager, '_app', None)

    def _init_widgets(self):
        """Create TextInput widgets."""
        # Chat input
        chat_rect = pygame.Rect(CARD_X + 20, CARD_Y + CARD_H - 50, CARD_W - 130, 34)
        self._chat_input = TextInput(chat_rect, get_font_size(18),
                                     placeholder="输入消息...", max_length=80)

        # IP input (LAN client)
        ip_rect = pygame.Rect(CARD_X + CARD_W // 2 - INPUT_W // 2 + 70,
                               CARD_Y + 110, INPUT_W - 70, INPUT_H)
        self._ip_input = TextInput(ip_rect, get_font_size(20),
                                   placeholder="请输入IP地址", max_length=15)

        # Port input (LAN client)
        port_rect = pygame.Rect(CARD_X + CARD_W // 2 - INPUT_W // 2 + 70,
                                 CARD_Y + 165, 100, INPUT_H)
        self._port_input = TextInput(port_rect, get_font_size(20),
                                     placeholder="8765", max_length=5)
        self._port_input.text = str(NETWORK_PORT)

        # Room code input (relay client)
        code_rect = pygame.Rect(CARD_X + (CARD_W - 260) // 2,
                                 CARD_Y + 140, 260, 56)
        self._room_code_input = TextInput(code_rect, get_font_size(32),
                                          placeholder="", max_length=4,
                                          validator=lambda s: s == "" or (s.isdigit() and len(s) <= 4))

        # Relay server host input (relay host/client)
        from config import RELAY_SERVER_HOST
        relay_host_rect = pygame.Rect(CARD_X + CARD_W // 2 - INPUT_W // 2,
                                       CARD_Y + 78, INPUT_W, INPUT_H)
        self._relay_host_input = TextInput(relay_host_rect, get_font_size(18),
                                           placeholder="输入服务器地址", max_length=40)
        self._relay_host_input.text = RELAY_SERVER_HOST

    # ── State management ──────────────────────────────────────────

    def _transition_to(self, new_state: int):
        if new_state == self._state:
            return
        self._state = new_state
        self.status_text = ""
        self.error_text = ""
        self._blur_inputs()

    def _blur_inputs(self):
        for w in (self._chat_input, self._ip_input, self._port_input,
                  self._room_code_input, self._relay_host_input):
            if w:
                w.blur()

    def _stop_network(self):
        nm = self._nm
        if nm:
            nm.stop()
        self._nm = None
        app = self._get_app()
        if app and getattr(app, "network_manager", None) is nm:
            app.network_manager = None
            app.is_remote_host = False
            app.is_remote_client = False

    def _is_hovered(self, rect: pygame.Rect) -> bool:
        return rect.collidepoint(self._mouse_pos)

    def _go_back(self):
        if self._state == LobbyState.CONNECTING:
            self._stop_network()
            self._connection_started = False
            self.connected = False
            self._transition_to(self._connect_origin_state)
            self.status_text = "已取消连接"
            return
        if self._state in (LobbyState.LAN_HOST, LobbyState.LAN_CLIENT,
                           LobbyState.RELAY_HOST, LobbyState.RELAY_CLIENT,
                           LobbyState.RELAY_CONNECTED):
            self._connection_started = False
            self.connected = False
            self.room_code_display = ""
            self._stop_network()
            self._transition_to(LobbyState.MODE_SELECT)
        else:
            self._stop_network()
            self.manager.pop_screen()

    # ── Event handling ─────────────────────────────────────────────

    def handle_event(self, event: pygame.event.Event):
        if event.type in (pygame.MOUSEMOTION, pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP):
            self._mouse_pos = event.pos

        # Global keyboard actions should work even while a text field is focused.
        if event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                self._go_back()
                return
            if event.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                self._on_enter_key()
                return

        # TextInput widgets consume events first
        if self._chat_input and self._state == LobbyState.RELAY_CONNECTED:
            if self._chat_input.handle_event(event):
                return
        if self._ip_input and self._state == LobbyState.LAN_CLIENT:
            if self._ip_input.handle_event(event):
                return
        if self._port_input and self._state == LobbyState.LAN_CLIENT:
            if self._port_input.handle_event(event):
                return
        if self._room_code_input and self._state == LobbyState.RELAY_CLIENT:
            if self._room_code_input.handle_event(event):
                return
        if self._relay_host_input and self._state in (LobbyState.RELAY_HOST, LobbyState.RELAY_CLIENT):
            if self._relay_host_input.handle_event(event):
                return

        if self._state == LobbyState.CONNECTING:
            return

        if event.type == pygame.MOUSEMOTION:
            self.back_hover = self._is_hovered(self.back_btn)

        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            pos = event.pos
            if self._is_hovered(self.back_btn):
                self._go_back()
                return
            for ctrl in self._controls:
                if ctrl.get("rect") and ctrl["rect"].collidepoint(pos):
                    self._pressing_btn = ctrl["name"]
                    self._press_anim = 0.0
                    self._handle_button(ctrl["name"])
                    return

    def _handle_button(self, name: str):
        if self._connection_started:
            return
        if name == "lan_create":
            self._transition_to(LobbyState.LAN_HOST)
            self.status_text = "点击「开始等待」创建房间，等待对手连接..."
        elif name == "lan_join":
            self._transition_to(LobbyState.LAN_CLIENT)
            self.status_text = "输入对手的 IP 地址和端口号，然后点击「连接」"
        elif name == "relay_create":
            self._transition_to(LobbyState.RELAY_HOST)
            self.status_text = "点击「创建房间」通过服务器联机..."
        elif name == "relay_join":
            self._transition_to(LobbyState.RELAY_CLIENT)
            self.status_text = "输入4位房间号，点击「加入房间」"
        elif name in ("lan_start_btn", "lan_connect_btn"):
            self._do_connect()
        elif name in ("relay_start_btn", "relay_join_btn"):
            self._do_relay_connect()
        elif name == "relay_chat_send_btn":
            self._send_chat()
        elif name == "relay_start_game_btn":
            self._start_network_game()
        elif name in ("lan_back_btn", "relay_back_btn"):
            self._go_back()

    def _on_enter_key(self):
        if self._connection_started:
            return
        if self._state in (LobbyState.LAN_HOST, LobbyState.LAN_CLIENT):
            self._do_connect()
        elif self._state in (LobbyState.RELAY_HOST, LobbyState.RELAY_CLIENT):
            self._do_relay_connect()
        elif self._state == LobbyState.RELAY_CONNECTED:
            self._send_chat()

    # ── Connection ─────────────────────────────────────────────────

    def _do_connect(self):
        if self._connection_started:
            return
        app = self._get_app()

        if self._state == LobbyState.LAN_HOST:
            self._is_host = True
            self._connection_started = True
            self._connect_origin_state = self._state
            self._state = LobbyState.CONNECTING
            self.status_text = f"等待对手连接... (端口: {self.host_port})"
            self.error_text = ""
            self.toasts.show(f"开始监听端口 {self.host_port}...", "info", 3.0)
            if app:
                app.start_remote_host(self.host_port)
                self._nm = app.network_manager

        elif self._state == LobbyState.LAN_CLIENT:
            ip_text = self._ip_input.text if self._ip_input else ""
            port_text = self._port_input.text if self._port_input else str(NETWORK_PORT)
            if not ip_text.strip():
                self.error_text = "请输入对手的 IP 地址"
                self._trigger_error_shake()
                self.toasts.show("请输入对手的 IP 地址", "error", 3.0)
                return
            try:
                port = int(port_text)
                if port < 1 or port > 65535:
                    raise ValueError
            except ValueError:
                self.error_text = "端口号无效（1-65535）"
                self._trigger_error_shake()
                self.toasts.show("端口号无效", "error", 3.0)
                return
            self._is_host = False
            self._connection_started = True
            self._connect_origin_state = self._state
            self._state = LobbyState.CONNECTING
            self.status_text = f"正在连接到 {ip_text}:{port}..."
            self.error_text = ""
            self.toasts.show(f"正在连接 {ip_text}:{port}...", "info", 5.0)
            if app:
                app.start_remote_client(ip_text.strip(), port)
                self._nm = app.network_manager

    def _do_relay_connect(self):
        if self._connection_started:
            return
        app = self._get_app()
        from config import RELAY_SERVER_HOST, RELAY_SERVER_PORT

        relay_host = self._relay_host_input.text.strip() if self._relay_host_input else ""
        if not relay_host:
            relay_host = RELAY_SERVER_HOST
        if not relay_host:
            self.error_text = "请输入服务器地址"
            self._trigger_error_shake()
            self.toasts.show("请输入服务器地址", "error", 3.0)
            return

        if self._state == LobbyState.RELAY_HOST:
            self._is_host = True
            self._connection_started = True
            self._connect_origin_state = self._state
            self._state = LobbyState.CONNECTING
            self.status_text = "正在连接中继服务器并创建房间..."
            self.error_text = ""
            self.toasts.show("正在连接服务器...", "info", 5.0)
            if app:
                app.start_relay_host(relay_host, RELAY_SERVER_PORT)
                self._nm = app.network_manager

        elif self._state == LobbyState.RELAY_CLIENT:
            room_code = self._room_code_input.text if self._room_code_input else ""
            if len(room_code) != 4 or not room_code.isdigit():
                self.error_text = "请输入4位数字房间号"
                self._trigger_error_shake()
                self.toasts.show("请输入4位数字房间号", "error", 3.0)
                return
            self._is_host = False
            self._connection_started = True
            self._connect_origin_state = self._state
            self._state = LobbyState.CONNECTING
            self.status_text = f"正在连接中继服务器并加入房间 {room_code}..."
            self.error_text = ""
            self.toasts.show(f"正在加入房间 {room_code}...", "info", 5.0)
            if app:
                app.start_relay_client(relay_host, RELAY_SERVER_PORT, room_code)
                self._nm = app.network_manager

    def _trigger_error_shake(self):
        self._error_shake = 0.0

    # ── Chat ───────────────────────────────────────────────────────

    def _send_chat(self):
        if not self._chat_input or not self._nm:
            return
        text = self._chat_input.text.strip()
        if not text:
            return
        if self._chat_send_cooldown > 0:
            return
        self._chat_messages.append({"sender": "me", "text": text})
        self._nm.send({"type": "lobby_chat", "text": text})
        self._chat_input.text = ""
        self._chat_send_cooldown = 0.5

    # ── Update ─────────────────────────────────────────────────────

    def update(self, dt: float):
        self._pulse += dt

        if self._pressing_btn:
            self._press_anim += dt
            if self._press_anim >= 0.1:
                self._pressing_btn = None
                self._press_anim = 0.0

        if self._error_shake <= 0.35:
            self._error_shake += dt

        if self._chat_send_cooldown > 0:
            self._chat_send_cooldown = max(0, self._chat_send_cooldown - dt)

        for w in (self._chat_input, self._ip_input, self._port_input, self._room_code_input, self._relay_host_input):
            if w:
                w.update(dt)

        self.toasts.update(dt)

        # Background animation
        for e in self._bg_energy:
            e["x"] += e["vx"] * dt
            e["y"] += e["vy"] * dt
            if e["x"] < -60:
                e["x"] = SCREEN_WIDTH + 40
            if e["x"] > SCREEN_WIDTH + 60:
                e["x"] = -40
            if e["y"] < -60:
                e["y"] = SCREEN_HEIGHT + 40
            if e["y"] > SCREEN_HEIGHT + 60:
                e["y"] = -40

        # Auto-connect
        if self._auto_connect_pending:
            self._auto_connect_delay -= dt
            if self._auto_connect_delay <= 0:
                self._auto_connect_pending = False
                self._execute_auto_connect()

        if self.auto_mode and not self._connection_started:
            mapping = {
                "host": (LobbyState.LAN_HOST, True),
                "client": (LobbyState.LAN_CLIENT, False),
                "relay_host": (LobbyState.RELAY_HOST, True),
                "relay_client": (LobbyState.RELAY_CLIENT, False),
            }
            pair = mapping.get(self.auto_mode)
            if pair:
                self._state, self._is_host = pair
                self._connection_started = True
                self._connect_origin_state = self._state
                app = self._get_app()
                if app:
                    self._nm = app.network_manager
                self.auto_mode = None
                if self._state == LobbyState.LAN_HOST:
                    self.status_text = f"等待对手连接... (端口: {self.host_port})"
                elif self._state == LobbyState.LAN_CLIENT:
                    ip = getattr(app, "auto_client_ip", "") if app else ""
                    port = getattr(app, "auto_client_port", NETWORK_PORT) if app else NETWORK_PORT
                    self.status_text = f"正在连接到 {ip}:{port}..."
                elif self._state == LobbyState.RELAY_HOST:
                    self.status_text = "正在连接中继服务器并创建房间..."
                elif self._state == LobbyState.RELAY_CLIENT:
                    room_code = self._room_code_input.text if self._room_code_input else ""
                    self.status_text = f"正在连接中继服务器并加入房间 {room_code}..."

        if self._auto_relay_connect and not self._connection_started:
            self._auto_relay_connect = False
            app = self._get_app()
            if app and getattr(app, "network_manager", None):
                self.auto_mode = ("relay_client" if self._room_code_input
                                  and self._room_code_input.text else "relay_host")
            else:
                self._do_relay_connect()

        # Poll network. Also poll during RELAY_HOST / RELAY_CONNECTED states
        # because _connection_started is set to False after room_created/opponent_joined,
        # but we still need to receive chat messages and disconnection events.
        should_poll = (self._connection_started or
                       self._state in (LobbyState.RELAY_HOST, LobbyState.RELAY_CONNECTED))
        if should_poll and self._nm:
            for msg in self._nm.poll():
                msg_type = msg.get("type", "")
                if msg_type == "room_created":
                    self.room_code_display = msg.get("room_id", "")
                    self.status_text = f"房间已创建！房间号: {self.room_code_display}"
                    self._state = LobbyState.RELAY_HOST
                    self._connection_started = False
                    self.toasts.show(f"房间号 {self.room_code_display}", "success", 5.0)
                elif msg_type == "opponent_joined":
                    self._state = LobbyState.RELAY_CONNECTED
                    self._connection_started = False
                    self.connected = True
                    self.status_text = "对手已加入！你们可以聊天或开始对战"
                    self.toasts.show("对手已加入!", "success", 3.0)
                elif msg_type == "connection_failed":
                    self.error_text = f"连接失败: {msg.get('error', '连接错误')}"
                    self.status_text = ""
                    self._connection_started = False
                    self._state = LobbyState.MODE_SELECT
                    self.toasts.show(f"连接失败: {msg.get('error', '未知错误')}", "error", 5.0)
                    if self._nm:
                        self._nm.stop()
                elif msg_type == "lobby_chat":
                    self._chat_messages.append({
                        "sender": "opponent",
                        "text": msg.get("text", "")
                    })

            if self._nm.is_connected:
                if not self.connected:
                    self.connected = True
                    self.status_text = "连接成功！正在进入对战..."
                    self.toasts.show("连接成功!", "success", 2.0)
                    if self._state == LobbyState.CONNECTING and not self._nm.is_relay:
                        self._start_network_game()
            elif self._nm.last_error:
                self.error_text = f"连接失败: {self._nm.last_error}"
                self.status_text = ""
                self._connection_started = False
                self._state = LobbyState.MODE_SELECT
                self.toasts.show(f"连接失败: {self._nm.last_error}", "error", 5.0)
                if self._nm:
                    self._nm.stop()

    def _execute_auto_connect(self):
        if self._is_host and self._state in (LobbyState.LAN_HOST,):
            self._do_connect()
        elif self._state in (LobbyState.RELAY_HOST, LobbyState.RELAY_CLIENT):
            self._do_relay_connect()

    def _start_network_game(self):
        from data.deck_definitions import (
            FIRE_DECK, WATER_DECK, PSYCHIC_DECK_NATU,
            LIGHTNING_DECK, FIGHTING_DECK, COLORLESS_DECK,
            DRAGON_DECK, GRASS_DECK, ALL_CARD_IDS,
        )
        from data.card_registry import CardRegistry
        from ui.screens.deck_select import DeckSelectScreen

        if not CardRegistry.is_initialized():
            try:
                CardRegistry.initialize(ALL_CARD_IDS, use_api=True)
            except Exception:
                from data.card_registry import create_offline_cards
                CardRegistry.initialize(ALL_CARD_IDS, use_api=False)
                create_offline_cards(ALL_CARD_IDS)

        available_decks = {
            "fire": FIRE_DECK, "water": WATER_DECK,
            "psychic": PSYCHIC_DECK_NATU, "lightning": LIGHTNING_DECK,
            "fighting": FIGHTING_DECK, "colorless": COLORLESS_DECK,
            "dragon": DRAGON_DECK, "grass": GRASS_DECK,
        }

        deck_screen = DeckSelectScreen(
            self.manager, available_decks,
            is_remote=True, network_manager=self._nm,
            my_player_idx=0 if self._is_host else 1,
        )
        from ui.transitions import SlideTransition
        self.manager.replace_top(deck_screen, transition=SlideTransition(0.35, "left"))

    # ═══════════════════════════════════════════════════════════════
    # Drawing
    # ═══════════════════════════════════════════════════════════════

    def draw(self, surface: pygame.Surface):
        self._controls.clear()
        self._draw_background(surface)
        self._draw_top_bar(surface)
        self._draw_content_card(surface)
        self._draw_status_area(surface)
        self.toasts.draw(surface)

    def _draw_background(self, surface: pygame.Surface):
        if self._bg_gradient is None:
            self._bg_gradient = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
            # Fill entire surface with gradient using 4px-tall rects
            for i in range(0, SCREEN_HEIGHT, 4):
                t = i / SCREEN_HEIGHT
                r = int(20 + (15 - 20) * t)
                g = int(20 + (15 - 20) * t)
                b = int(40 + (32 - 40) * t)
                h = min(4, SCREEN_HEIGHT - i)
                pygame.draw.rect(self._bg_gradient, (r, g, b), (0, i, SCREEN_WIDTH, h))
        surface.blit(self._bg_gradient, (0, 0))

        # Energy circles with cached dot surfaces
        for e in self._bg_energy:
            cache_key = (e["type"], e["radius"])
            if cache_key not in self._energy_dot_cache:
                color = ENERGY_COLORS.get(e["type"], (200, 200, 200))
                dot = pygame.Surface((e["radius"] * 2, e["radius"] * 2), pygame.SRCALPHA)
                # Pre-render at full alpha, modulate at blit time
                pygame.draw.circle(dot, (*color, 255), (e["radius"], e["radius"]), e["radius"])
                self._energy_dot_cache[cache_key] = dot
            dot = self._energy_dot_cache[cache_key]
            alpha = int(e["alpha"] * (0.7 + 0.3 * math.sin(self._pulse * 0.5 + e["phase"])))
            dot.set_alpha(alpha)
            surface.blit(dot, (int(e["x"] - e["radius"]), int(e["y"] - e["radius"])))

    def _draw_top_bar(self, surface: pygame.Surface):
        self.back_hover = self._is_hovered(self.back_btn)
        bc = UI_BUTTON_HOVER if self.back_hover else UI_BUTTON
        pygame.draw.rect(surface, bc, self.back_btn, border_radius=8)
        pygame.draw.rect(surface, UI_TEXT_PRIMARY, self.back_btn, 1, border_radius=8)
        bt = self.font_small.render("← 返回", True, UI_TEXT_PRIMARY)
        surface.blit(bt, bt.get_rect(center=self.back_btn.center))

        tt = self.font_title.render("远程联机对战", True, UI_HIGHLIGHT)
        surface.blit(tt, tt.get_rect(center=(SCREEN_WIDTH // 2, 45)))
        st = self.font_small.render("通过局域网或服务器与远程玩家对战", True, (140, 140, 170))
        surface.blit(st, st.get_rect(center=(SCREEN_WIDTH // 2, 85)))

    # ── Content card ───────────────────────────────────────────────

    def _draw_content_card(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        border_color = (60, 65, 95)
        draw_rect = card_rect

        if self._error_shake <= 0.35:
            progress = self._error_shake / 0.35
            border_color = UI_DANGER
            shake_x = int(math.sin(progress * math.pi * 4) * 3 * (1 - progress))
            draw_rect = card_rect.move(shake_x, 0)

        pygame.draw.rect(surface, (22, 25, 48), draw_rect, border_radius=8)
        pygame.draw.rect(surface, border_color, draw_rect, 2, border_radius=8)
        self._draw_content_for_state(surface, self._state)

    def _draw_content_for_state(self, surface: pygame.Surface, state: int):
        methods = {
            LobbyState.MODE_SELECT: self._draw_mode_select,
            LobbyState.LAN_HOST: self._draw_lan_host,
            LobbyState.LAN_CLIENT: self._draw_lan_client,
            LobbyState.RELAY_HOST: self._draw_relay_host,
            LobbyState.RELAY_CLIENT: self._draw_relay_client,
            LobbyState.RELAY_CONNECTED: self._draw_relay_connected,
            LobbyState.CONNECTING: self._draw_connecting,
        }
        method = methods.get(state)
        if method:
            method(surface)

    # ── MODE_SELECT — 两个联机方式，各自有创建/加入 ────────────────

    def _draw_mode_select(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        title = self.font_subtitle.render("选择联机方式", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(cx, card_rect.y + 36)))

        # Two columns
        for col_type, col_title, col_sub, energy_type, col_x in [
            ("lan", "局域网对战", "同一网络下直连 · 低延迟", "Lightning", COL1_X),
            ("relay", "服务器联机", "云服务器中转 · 跨网络联机", "Fire", COL2_X),
        ]:
            col_rect = pygame.Rect(col_x, card_rect.y + 70, COL_W, 340)
            is_hover = self._is_hovered(col_rect)

            # Column background
            bg = (28, 32, 55) if is_hover else (20, 23, 42)
            border = UI_HIGHLIGHT if is_hover else (45, 50, 75)
            pygame.draw.rect(surface, bg, col_rect, border_radius=14)
            pygame.draw.rect(surface, border, col_rect, 1, border_radius=14)

            if is_hover:
                draw_rect_alpha(surface, (*UI_HIGHLIGHT, 15),
                                col_rect.inflate(4, 4), border_radius=8)

            # Energy icon
            ec = ENERGY_COLORS.get(energy_type, (200, 200, 200))
            draw_energy_circle(surface, get_font("body_sm"),
                               col_rect.centerx, col_rect.y + 40, 22,
                               energy_type, {}, dark_text=True)

            # Column title
            ct = self.font_body.render(col_title, True, UI_TEXT_PRIMARY)
            surface.blit(ct, ct.get_rect(center=(col_rect.centerx, col_rect.y + 78)))

            # Subtitle
            cs = self.font_hint.render(col_sub, True, (140, 140, 170))
            surface.blit(cs, cs.get_rect(center=(col_rect.centerx, col_rect.y + 105)))

            # Divider line
            div_y = col_rect.y + 130
            pygame.draw.line(surface, (50, 55, 80),
                             (col_rect.x + 40, div_y), (col_rect.x + COL_W - 40, div_y), 1)

            # "创建房间" button
            create_btn = pygame.Rect(col_rect.centerx - SMALL_BTN_W // 2,
                                      col_rect.y + 148, SMALL_BTN_W, SMALL_BTN_H)
            self._add_ctrl(f"{col_type}_create", "button", create_btn)
            create_hover = self._is_hovered(create_btn)
            is_press = self._pressing_btn == f"{col_type}_create"
            draw_gradient_button(surface, create_btn, create_hover or is_press,
                                 top_color=(60, 130, 80), bot_color=(40, 100, 60),
                                 hover_top_color=(80, 160, 100),
                                 hover_bot_color=(60, 130, 80))
            create_label = self.font_small.render("创建房间", True, UI_TEXT_PRIMARY)
            surface.blit(create_label, create_label.get_rect(center=create_btn.center))

            # "加入房间" button
            join_btn = pygame.Rect(col_rect.centerx - SMALL_BTN_W // 2,
                                    col_rect.y + 210, SMALL_BTN_W, SMALL_BTN_H)
            self._add_ctrl(f"{col_type}_join", "button", join_btn)
            join_hover = self._is_hovered(join_btn)
            is_press_j = self._pressing_btn == f"{col_type}_join"
            draw_gradient_button(surface, join_btn, join_hover or is_press_j,
                                 top_color=(60, 100, 180), bot_color=(40, 70, 140),
                                 hover_top_color=(80, 130, 210),
                                 hover_bot_color=(60, 100, 180))
            join_label = self.font_small.render("加入房间", True, UI_TEXT_PRIMARY)
            surface.blit(join_label, join_label.get_rect(center=join_btn.center))

            # Hint at bottom
            hint_text = ("房主创建后告诉对手IP和端口" if col_type == "lan"
                        else "房主创建后告诉对手4位房间号")
            hint = self.font_hint.render(hint_text, True, (110, 110, 140))
            surface.blit(hint, hint.get_rect(center=(col_rect.centerx, col_rect.y + 310)))

    # ── LAN Host ───────────────────────────────────────────────────

    def _draw_lan_host(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        title = self.font_subtitle.render("局域网联机 · 创建房间", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(cx, card_rect.y + 40)))

        port_label = self.font_small.render(f"监听端口: {self.host_port}", True, (160, 160, 190))
        surface.blit(port_label, port_label.get_rect(center=(cx, card_rect.y + 100)))

        info = self.font_small.render("等待同一局域网内的对手连接到此端口...", True, (140, 140, 170))
        surface.blit(info, info.get_rect(center=(cx, card_rect.y + 150)))

        btn_rect = pygame.Rect(cx - BTN_W // 2, card_rect.y + 210, BTN_W, BTN_H)
        btn_hover = self._is_hovered(btn_rect)
        is_press = self._pressing_btn == "lan_start_btn"
        draw_gradient_button(surface, btn_rect, btn_hover or is_press,
                             top_color=(60, 130, 80), bot_color=(40, 100, 60),
                             hover_top_color=(80, 160, 100), hover_bot_color=(60, 130, 80))
        btn_label = self.font_body.render("开始等待", True, UI_TEXT_PRIMARY)
        surface.blit(btn_label, btn_label.get_rect(center=btn_rect.center))
        self._add_ctrl("lan_start_btn", "button", btn_rect)

        hint = self.font_hint.render("提示: 告诉对手你的 IP 地址和端口号", True, (120, 120, 150))
        surface.blit(hint, hint.get_rect(center=(cx, card_rect.y + 290)))

        back_btn = pygame.Rect(cx - 60, card_rect.y + 350, 120, 30)
        back_hover = self._is_hovered(back_btn)
        bc = UI_BUTTON_HOVER if back_hover else UI_BUTTON
        pygame.draw.rect(surface, bc, back_btn, border_radius=6)
        back_label = self.font_small.render("← 返回", True, UI_TEXT_PRIMARY)
        surface.blit(back_label, back_label.get_rect(center=back_btn.center))
        self._add_ctrl("lan_back_btn", "button", back_btn)

    # ── LAN Client ─────────────────────────────────────────────────

    def _draw_lan_client(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        title = self.font_subtitle.render("局域网联机 · 加入房间", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(cx, card_rect.y + 40)))

        label_x = cx - 160
        ip_label = self.font_small.render("对手 IP:", True, UI_TEXT_PRIMARY)
        surface.blit(ip_label, (label_x, card_rect.y + 115))
        if self._ip_input:
            self._ip_input.draw(surface)

        port_label = self.font_small.render("端口:", True, UI_TEXT_PRIMARY)
        surface.blit(port_label, (label_x, card_rect.y + 170))
        if self._port_input:
            self._port_input.draw(surface)

        btn_rect = pygame.Rect(cx - BTN_W // 2, card_rect.y + 240, BTN_W, BTN_H)
        btn_hover = self._is_hovered(btn_rect)
        is_press = self._pressing_btn == "lan_connect_btn"
        draw_gradient_button(surface, btn_rect, btn_hover or is_press,
                             top_color=(60, 130, 80), bot_color=(40, 100, 60),
                             hover_top_color=(80, 160, 100), hover_bot_color=(60, 130, 80))
        btn_label = self.font_body.render("连接", True, UI_TEXT_PRIMARY)
        surface.blit(btn_label, btn_label.get_rect(center=btn_rect.center))
        self._add_ctrl("lan_connect_btn", "button", btn_rect)

        hint = self.font_hint.render("提示: 输入房主的局域网 IP 地址和端口号后点击连接", True,
                                     (120, 120, 150))
        surface.blit(hint, hint.get_rect(center=(cx, card_rect.y + 320)))

        back_btn = pygame.Rect(cx - 60, card_rect.y + 370, 120, 30)
        back_hover = self._is_hovered(back_btn)
        bc = UI_BUTTON_HOVER if back_hover else UI_BUTTON
        pygame.draw.rect(surface, bc, back_btn, border_radius=6)
        back_label = self.font_small.render("← 返回", True, UI_TEXT_PRIMARY)
        surface.blit(back_label, back_label.get_rect(center=back_btn.center))
        self._add_ctrl("lan_back_btn", "button", back_btn)

    # ── Relay Host ─────────────────────────────────────────────────

    def _draw_relay_host(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        title = self.font_subtitle.render("服务器联机 · 创建房间", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(cx, card_rect.y + 40)))

        # Server address input (centered)
        server_label = self.font_small.render("服务器:", True, (140, 140, 170))
        total_w = server_label.get_width() + 8 + 280
        label_x = cx - total_w // 2
        surface.blit(server_label, (label_x, card_rect.y + 78))
        if self._relay_host_input:
            self._relay_host_input.rect = pygame.Rect(
                label_x + server_label.get_width() + 8, card_rect.y + 72, 280, INPUT_H)
            self._relay_host_input.draw(surface)

        if self.room_code_display:
            code_label = self.font_small.render("房间号 (告诉对手):", True, (140, 140, 170))
            surface.blit(code_label, code_label.get_rect(center=(cx, card_rect.y + 125)))

            digit_size, digit_gap = 60, 12
            total_w = digit_size * 4 + digit_gap * 3
            start_x = cx - total_w // 2
            for i, ch in enumerate(self.room_code_display):
                dx = start_x + i * (digit_size + digit_gap)
                d_rect = pygame.Rect(dx, card_rect.y + 150, digit_size, digit_size)
                pygame.draw.rect(surface, (15, 15, 35), d_rect, border_radius=10)
                pygame.draw.rect(surface, UI_HIGHLIGHT, d_rect, 2, border_radius=10)
                d_surf = self.font_code.render(ch, True, UI_HIGHLIGHT)
                surface.blit(d_surf, d_surf.get_rect(center=d_rect.center))

            wait_text = self.font_small.render("等待对手加入...", True, (140, 140, 170))
            surface.blit(wait_text, wait_text.get_rect(center=(cx, card_rect.y + 245)))

            for i in range(3):
                dot_alpha = int(100 + 100 * math.sin(self._pulse * 3.0 - i * 1.0))
                dot_color = (*UI_HIGHLIGHT, dot_alpha)
                dot = pygame.Surface((10, 10), pygame.SRCALPHA)
                pygame.draw.circle(dot, dot_color, (5, 5), 4)
                surface.blit(dot, (cx - 25 + i * 25, card_rect.y + 275))
        else:
            info = self.font_small.render("在云端服务器上创建对战房间", True, (140, 140, 170))
            surface.blit(info, info.get_rect(center=(cx, card_rect.y + 125)))

            btn_rect = pygame.Rect(cx - BTN_W // 2, card_rect.y + 190, BTN_W, BTN_H)
            btn_hover = self._is_hovered(btn_rect)
            is_press = self._pressing_btn == "relay_start_btn"
            draw_gradient_button(surface, btn_rect, btn_hover or is_press,
                                 top_color=(200, 80, 40), bot_color=(160, 50, 20),
                                 hover_top_color=(230, 100, 55),
                                 hover_bot_color=(190, 70, 35))
            btn_label = self.font_body.render("创建房间", True, UI_TEXT_PRIMARY)
            surface.blit(btn_label, btn_label.get_rect(center=btn_rect.center))
            self._add_ctrl("relay_start_btn", "button", btn_rect)

            hint = self.font_hint.render("创建后获得4位房间号，告诉对手即可联机", True, (120, 120, 150))
            surface.blit(hint, hint.get_rect(center=(cx, card_rect.y + 260)))

        back_btn = pygame.Rect(cx - 60, card_rect.y + 370, 120, 30)
        back_hover = self._is_hovered(back_btn)
        bc = UI_BUTTON_HOVER if back_hover else UI_BUTTON
        pygame.draw.rect(surface, bc, back_btn, border_radius=6)
        back_label = self.font_small.render("← 返回", True, UI_TEXT_PRIMARY)
        surface.blit(back_label, back_label.get_rect(center=back_btn.center))
        self._add_ctrl("relay_back_btn", "button", back_btn)

    # ── Relay Client ───────────────────────────────────────────────

    def _draw_relay_client(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        title = self.font_subtitle.render("服务器联机 · 加入房间", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(cx, card_rect.y + 40)))

        # Server address input (centered)
        server_label = self.font_small.render("服务器:", True, (140, 140, 170))
        total_w = server_label.get_width() + 8 + 280
        label_x = cx - total_w // 2
        surface.blit(server_label, (label_x, card_rect.y + 78))
        if self._relay_host_input:
            self._relay_host_input.rect = pygame.Rect(
                label_x + server_label.get_width() + 8, card_rect.y + 72, 280, INPUT_H)
            self._relay_host_input.draw(surface)

        code_label = self.font_small.render("输入对手给出的4位房间号:", True, UI_TEXT_PRIMARY)
        surface.blit(code_label, code_label.get_rect(center=(cx, card_rect.y + 140)))

        # 4 digit boxes
        digit_size, digit_gap = 56, 14
        total_w = digit_size * 4 + digit_gap * 3
        start_x = cx - total_w // 2
        box_y = card_rect.y + 170

        code_text = self._room_code_input.text if self._room_code_input else ""
        focused = self._room_code_input is not None and self._room_code_input.focused
        for i in range(4):
            dx = start_x + i * (digit_size + digit_gap)
            d_rect = pygame.Rect(dx, box_y, digit_size, digit_size)
            border = UI_HIGHLIGHT if focused else (100, 100, 150)
            pygame.draw.rect(surface, (22, 25, 48), d_rect, border_radius=10)
            pygame.draw.rect(surface, border, d_rect, 2, border_radius=10)
            if i < len(code_text):
                d_surf = self.font_code.render(code_text[i], True, UI_HIGHLIGHT)
                surface.blit(d_surf, d_surf.get_rect(center=d_rect.center))
            else:
                ph = self.font_code.render("_", True, (60, 60, 90))
                surface.blit(ph, ph.get_rect(center=d_rect.center))
            if focused and i == len(code_text) and int(self._pulse * 4) % 2 == 0:
                cursor_x = d_rect.centerx
                pygame.draw.line(surface, UI_HIGHLIGHT,
                                 (cursor_x - 8, d_rect.y + 12),
                                 (cursor_x - 8, d_rect.y + d_rect.h - 12), 2)

        if self._room_code_input:
            self._room_code_input.rect = pygame.Rect(start_x, box_y, total_w, digit_size)

        btn_rect = pygame.Rect(cx - BTN_W // 2, card_rect.y + 265, BTN_W, BTN_H)
        btn_hover = self._is_hovered(btn_rect)
        is_press = self._pressing_btn == "relay_join_btn"
        draw_gradient_button(surface, btn_rect, btn_hover or is_press,
                             top_color=(200, 80, 40), bot_color=(160, 50, 20),
                             hover_top_color=(230, 100, 55),
                             hover_bot_color=(190, 70, 35))
        btn_label = self.font_body.render("加入房间", True, UI_TEXT_PRIMARY)
        surface.blit(btn_label, btn_label.get_rect(center=btn_rect.center))
        self._add_ctrl("relay_join_btn", "button", btn_rect)

        hint = self.font_hint.render("4位数字房间号由房主提供", True, (120, 120, 150))
        surface.blit(hint, hint.get_rect(center=(cx, card_rect.y + 330)))

        back_btn = pygame.Rect(cx - 60, card_rect.y + 380, 120, 30)
        back_hover = self._is_hovered(back_btn)
        bc = UI_BUTTON_HOVER if back_hover else UI_BUTTON
        pygame.draw.rect(surface, bc, back_btn, border_radius=6)
        back_label = self.font_small.render("← 返回", True, UI_TEXT_PRIMARY)
        surface.blit(back_label, back_label.get_rect(center=back_btn.center))
        self._add_ctrl("relay_back_btn", "button", back_btn)

    # ── Relay Connected ────────────────────────────────────────────

    def _draw_relay_connected(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        header = self.font_body.render("对手已加入!", True, UI_SUCCESS)
        surface.blit(header, header.get_rect(center=(cx, card_rect.y + 28)))

        if self.room_code_display:
            code_line = self.font_small.render(
                f"房间号: {self.room_code_display}", True, (140, 140, 170))
            surface.blit(code_line, code_line.get_rect(center=(cx, card_rect.y + 58)))

        # Chat panel
        chat_bg = pygame.Rect(card_rect.x + 16, card_rect.y + 80,
                               CARD_W - 32, CARD_H - 195)
        pygame.draw.rect(surface, (18, 20, 38), chat_bg, border_radius=10)
        pygame.draw.rect(surface, (50, 55, 80), chat_bg, 1, border_radius=10)

        chat_clip = chat_bg.inflate(-16, -12)
        surface.set_clip(chat_clip)
        msg_y = chat_bg.y + 8
        for msg in self._chat_messages[-8:]:
            is_me = msg["sender"] == "me"
            prefix = "[你]" if is_me else "[对手]"
            prefix_color = (100, 180, 255) if is_me else (255, 160, 100)
            p_surf = self.font_chat_name.render(prefix, True, prefix_color)
            surface.blit(p_surf, (chat_bg.x + 14, msg_y))
            t_surf = self.font_chat_msg.render(msg["text"], True, UI_TEXT_PRIMARY)
            surface.blit(t_surf, (chat_bg.x + 14 + p_surf.get_width() + 6, msg_y))
            msg_y += 24
        surface.set_clip(None)

        # Chat input
        if self._chat_input:
            input_bg = pygame.Rect(card_rect.x + 16, card_rect.y + CARD_H - 64,
                                    CARD_W - 32, 40)
            pygame.draw.rect(surface, (22, 25, 45), input_bg, border_radius=8)
            self._chat_input.rect = pygame.Rect(
                card_rect.x + 22, card_rect.y + CARD_H - 60,
                CARD_W - 150, 32)
            self._chat_input.draw(surface)

            send_btn = pygame.Rect(card_rect.x + CARD_W - 116,
                                    card_rect.y + CARD_H - 64, 96, 40)
            send_hover = self._is_hovered(send_btn)
            is_press = self._pressing_btn == "relay_chat_send_btn"
            draw_gradient_button(surface, send_btn, send_hover or is_press,
                                 top_color=(60, 100, 160), bot_color=(40, 70, 120))
            send_label = self.font_small.render("发送", True, UI_TEXT_PRIMARY)
            surface.blit(send_label, send_label.get_rect(center=send_btn.center))
            self._add_ctrl("relay_chat_send_btn", "button", send_btn)

        # Start battle button
        start_btn = pygame.Rect(cx - BTN_W // 2, card_rect.y + CARD_H - 118,
                                BTN_W, BTN_H)
        start_hover = self._is_hovered(start_btn)
        is_press = self._pressing_btn == "relay_start_game_btn"
        draw_gradient_button(surface, start_btn, start_hover or is_press,
                             top_color=(60, 180, 80), bot_color=(30, 140, 60),
                             hover_top_color=(80, 210, 100),
                             hover_bot_color=(50, 170, 80))
        start_label = self.font_body.render("开始对战！", True, UI_TEXT_PRIMARY)
        surface.blit(start_label, start_label.get_rect(center=start_btn.center))
        self._add_ctrl("relay_start_game_btn", "button", start_btn)

    # ── Connecting ─────────────────────────────────────────────────

    def _draw_connecting(self, surface: pygame.Surface):
        card_rect = pygame.Rect(CARD_X, CARD_Y, CARD_W, CARD_H)
        cx = card_rect.centerx

        title = self.font_subtitle.render("正在连接...", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(cx, card_rect.y + 80)))

        self._draw_spinner(surface, cx, card_rect.y + 180)

        if self.status_text:
            stxt = self.font_body.render(self.status_text, True, UI_TEXT_PRIMARY)
            surface.blit(stxt, stxt.get_rect(center=(cx, card_rect.y + 250)))

        if self.error_text:
            etxt = self.font_body.render(self.error_text, True, UI_DANGER)
            surface.blit(etxt, etxt.get_rect(center=(cx, card_rect.y + 300)))

    # ── Status area ────────────────────────────────────────────────

    def _draw_status_area(self, surface: pygame.Surface):
        sy = STATUS_Y

        if self._state == LobbyState.CONNECTING and self._connection_started:
            self._draw_spinner(surface, SCREEN_WIDTH // 2, sy)

        if self.status_text and self._state != LobbyState.CONNECTING:
            color = (UI_SUCCESS if ("成功" in self.status_text or "已创建" in self.status_text
                                    or "已加入" in self.status_text)
                     else UI_HIGHLIGHT)
            stxt = self.font_body.render(self.status_text, True, color)
            surface.blit(stxt, stxt.get_rect(center=(SCREEN_WIDTH // 2, sy)))

        if self.error_text:
            etxt = self.font_body.render(self.error_text, True, UI_DANGER)
            surface.blit(etxt, etxt.get_rect(center=(SCREEN_WIDTH // 2, sy + 32)))

    # Cached spinner dot surface
    _spinner_dot: pygame.Surface | None = None

    def _draw_spinner(self, surface, cx, cy):
        if LobbyScreen._spinner_dot is None:
            LobbyScreen._spinner_dot = pygame.Surface((8, 8), pygame.SRCALPHA)
            pygame.draw.circle(LobbyScreen._spinner_dot, (*UI_HIGHLIGHT, 255), (4, 4), 3)
        dot = LobbyScreen._spinner_dot
        radius = 14
        for i in range(8):
            angle = (i / 8) * math.pi * 2 + self._pulse * 4.0
            alpha = int(100 + 155 * ((i + 1) / 8))
            dot.set_alpha(alpha)
            dx = math.cos(angle) * radius
            dy = math.sin(angle) * radius
            surface.blit(dot, (cx + dx - 4, cy + dy - 4))

    # ── Control tracking ───────────────────────────────────────────

    def _add_ctrl(self, name, kind, rect):
        self._controls = [c for c in self._controls if c["name"] != name]
        self._controls.append({"name": name, "kind": kind, "rect": rect})

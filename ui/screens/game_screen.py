"""Main game screen - board display and player interaction."""
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_BG_DARK, UI_BG_BOARD, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
    UI_HIGHLIGHT, UI_BUTTON, UI_BUTTON_HOVER, UI_BUTTON_ACTIVE,
    UI_BUTTON_DISABLED, TYPE_COLORS, ENERGY_COLORS, STATUS_COLORS,
    PLAYER1_COLOR, PLAYER2_COLOR, CARD_BACK, UI_BORDER,
    UI_SUCCESS, UI_DANGER, CARD_HOVER_LIFT,
)
from ui.image_manager import get_image_manager
from ui.font_manager import get_font, get_font_size
from ui.animation import (
    AnimationManager, DamageFlash, KOFade, AttackShake, FloatingText,
    CardFlyAnimation, HealFlash, DrawCardFlash, DamageRipple,
    WaitingIndicator, ShuffleAnimation,
)
from ui.particles import ParticleManager, attack_impact, energy_spark, evolution_glow, heal_sparkle, ko_burst, card_play_trail
from ui.transitions import FadeTransition, SlideTransition
from ui.audio_manager import get_audio
from ui.coin_flip import CoinFlipAnimation
from config import (
    SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT,
    STATUS_SHORT_CN, PHASE_CN as _PHASE_CN_STR, ENERGY_NAME_CN as ENERGY_CN,
    GAME_SPEED, GAME_SPEED_OPTIONS,
)
from engine.enums import TurnPhase, PlayerAction, StatusType
from engine.game_state import GameState, ActionRequest
from engine.turn_manager import TurnManager

# Component imports — extracted rendering functions
from ui.components.game_layout import *
from ui.components.board_renderer import (
    draw_opponent_side, draw_player_side, draw_divider, draw_setup_status,
    draw_field_pokemon, draw_bench_card, draw_field_tooltips, draw_stadium,
    stadium_is_activatable, stadium_btn_rect, get_card_image_surface,
    create_board_background, _draw_card_shadow,
    draw_opponent_deck, draw_opponent_discard,
    draw_player_deck, draw_player_discard,
)
from ui.components.hand_display import draw_hand, draw_hand_card, get_hand_layout
from ui.components.action_menu import draw_action_buttons, draw_attack_menu, draw_ability_menu, build_action_buttons
from ui.components.log_panel import draw_action_log
from ui.components.card_detail import (
    draw_magnified_card, draw_card_tooltip, draw_tooltip_box,
    pokemon_extra_info, get_hovered_card_with_image,
)

# Adapter: StatusType enum → short Chinese status name
_STATUS_KEY_MAP = {
    StatusType.POISONED: "poisoned",
    StatusType.BURNED: "burned",
    StatusType.ASLEEP: "asleep",
    StatusType.PARALYZED: "paralyzed",
    StatusType.CONFUSED: "confused",
}
STATUS_CN = {k: STATUS_SHORT_CN[v] for k, v in _STATUS_KEY_MAP.items()}

# Adapter: TurnPhase enum → Chinese phase name
_PHASE_KEY_MAP = {
    TurnPhase.SETUP: "SETUP",
    TurnPhase.DRAW: "DRAW",
    TurnPhase.MAIN: "MAIN",
    TurnPhase.ATTACK: "ATTACK",
    TurnPhase.POKEMON_CHECKUP: "POKEMON_CHECKUP",
    TurnPhase.GAME_OVER: "GAME_OVER",
}
PHASE_CN = {k: _PHASE_CN_STR[v] for k, v in _PHASE_KEY_MAP.items()}


def _wrap_text(text: str, chars_per_line: int) -> list[str]:
    """Split long text into lines of at most chars_per_line characters."""
    if len(text) <= chars_per_line:
        return [text]
    return [text[i:i + chars_per_line] for i in range(0, len(text), chars_per_line)]

# Layout constants — imported from ui.components.game_layout
# (LOG_W, LOG_X, PLAY_AREA_W, FIELD_ACTIVE_W, FIELD_ACTIVE_H,
#  FIELD_BENCH_W, FIELD_BENCH_H, OPP_INFO_Y, OPP_BENCH_Y,
#  OPP_ACTIVE_Y, DIVIDER_Y, DIVIDER_H, PLAYER_ACTIVE_Y,
#  PLAYER_BENCH_Y, PLAYER_INFO_Y, HAND_Y, BTN_W, BTN_H,
#  BTN_GAP, BTN_ROW1_Y, BTN_ROW2_Y)


class GameScreen(Screen):
    """Main game board screen."""

    def __init__(self, manager: ScreenManager, game_state: GameState | None,
                 turn_manager: TurnManager | None,
                 network_manager=None, my_player_idx: int | None = None,
                 initial_state: GameState | None = None):
        super().__init__(manager)
        self.state = game_state if game_state is not None else initial_state
        self.tm = turn_manager
        self.network_manager = network_manager
        self.my_player_idx = my_player_idx
        self._is_remote_host = network_manager is not None and turn_manager is not None
        self._is_remote_client = network_manager is not None and turn_manager is None
        self._waiting_remote: bool = False  # Host waiting for remote player action
        self._pending_remote_action = None  # ActionRequest pending from remote player (for resolution)
        self._pending_bench_select_client: bool = False
        self._bench_target_handler_is_client: bool = False
        self._state_sync_just_arrived: bool = False  # Suppress _detect_state_changes for 1 frame
        self._suppress_action_particles: bool = False  # Suppress duplicate particles from action_result
        self._resolving_remote_pending: bool = False  # Client resolving a remote pending action

        self.font_info = get_font("info")
        self.font_body = get_font("small")
        self.font_small = get_font("caption")
        self.font_card_name = get_font_size(15, bold=True)
        self.font_card_body = get_font("card_body")
        self.font_card_tiny = get_font("card_tiny")
        self.font_action = get_font_size(16, bold=True)

        self.selected_hand_idx: int | None = None
        self.selected_action = None
        self.action_buttons: list[tuple[pygame.Rect, str, object]] = []
        self._build_action_buttons()

        self.hovered_button: int | None = None
        self.hovered_hand: int | None = None
        self.hovered_bench: int | None = None

        # Deck/discard zone hover state
        self.hovered_opp_deck = False
        self.hovered_opp_discard_zone = False
        self.hovered_player_deck = False
        self.hovered_player_discard_zone = False

        # Discard view buttons (deprecated — clicking discard zone now opens view)
        self.opp_discard_btn_rect: pygame.Rect | None = None
        self.player_discard_btn_rect: pygame.Rect | None = None
        self.hovered_opp_discard = False
        self.hovered_player_discard = False

        self.hovered_active: bool = False
        self.hovered_opp_bench: int | None = None
        self.hovered_opp_active: bool = False
        self.hovered_stadium_btn: bool = False
        self.hovered_quit_btn: bool = False
        self.hovered_concede_btn: bool = False

        # Quit and concede buttons in the divider bar area
        btn_size = 26
        self.concede_btn_rect = pygame.Rect(
            SCREEN_WIDTH - LOG_W - btn_size * 2 - 24,
            DIVIDER_Y + (DIVIDER_H - btn_size) // 2,
            btn_size, btn_size,
        )
        self.quit_btn_rect = pygame.Rect(
            SCREEN_WIDTH - LOG_W - btn_size - 16,
            DIVIDER_Y + (DIVIDER_H - btn_size) // 2,
            btn_size, btn_size,
        )

        self.setup_player_idx: int = 0
        self.setup_pass_done: dict[int, bool] = {0: False, 1: False}
        self._end_turn_warned: bool = False

        self.image_mgr = get_image_manager()

        self._attack_menu_open: bool = False
        self._attack_menu_attacks: list = []
        self._attack_menu_hover: int | None = None
        self._attack_menu_damage_previews: dict = {}
        self._ability_menu_open: bool = False
        self._ability_menu_abilities: list = []
        self._ability_menu_hover: int | None = None
        self._ability_menu_slot: str = ""
        self._ability_menu_player_idx: int = 0
        self._setup_initialized: bool = False
        self._awaiting_promotion: bool = False
        self._pending_bench_select = None
        self._pending_tool_card = None  # (player_idx, hand_idx, card) for tool attachment
        self._selecting_bench_targets = None  # ActionRequest for bench target selection
        self._selected_bench_targets: list[int] = []  # tracking player's bench clicks

        # Animation system
        self.anim_mgr = AnimationManager()
        self.damage_flash = DamageFlash()
        self.ko_fade = KOFade()
        self.attack_shake = AttackShake()
        self.floating_text = FloatingText()
        self.card_fly = CardFlyAnimation()
        self.heal_flash = HealFlash()
        self.draw_flash = DrawCardFlash()
        self.damage_ripple = DamageRipple()

        # Particle system
        self.particles = ParticleManager()

        # Coin flip
        self.coin_flip = CoinFlipAnimation()

        # Card back image (load from data/images/)
        self.card_back_img = self.image_mgr.get_card_back("卡背.webp")

        # Waiting indicator (online play)
        self.waiting_indicator = WaitingIndicator()

        # Shuffle animation
        self.shuffle_anim = ShuffleAnimation()

        # Track state changes for animation triggers
        self._last_hand_counts: dict[int, int] = {}
        self._last_discard_counts: dict[int, int] = {}
        self._last_deck_counts: dict[int, int] = {}
        self._last_field_state: dict = {}  # For detecting field changes across state_sync
        self._state_sync_fade: float = 0.0

        # Hand card lift animation (smooth transition)
        self._card_lift_offset: dict[int, float] = {}

        # Interaction state
        self._log_panel_last_count: int = 0
        self._log_scroll_offset: int = 0
        self._confirm_end_turn: bool = False
        self._confirm_dialog: dict | None = None
        self._undo_state: dict | None = None
        self._feedback_text: dict | None = None
        self._pending_turn_end: float = 0.0  # delay timer before turn switch (for animations)
        self._turn_ending: bool = False  # guard against rapid End Turn clicks
        # Animation action deferral (play animation before game logic)
        self._animating_action: bool = False
        self._animating_hand_idx: int | None = None
        self._last_action_source: tuple[float, float] | None = None  # For discard animation direction
        self._pending_trainer_card = None  # Trainer card awaiting pending action resolution
        self._last_action_card_name: str | None = None  # Card name for deferred discard animation
        self._last_action_card_obj = None  # Card object for deferred discard animation

        # Cards temporarily hidden from rendering during animations (index-based)
        self._hidden_hand_idx: int | None = None  # Hand index hidden during draw anim
        self._hidden_discard_idx: int | None = None  # Discard index hidden during discard anim

        # Shortcuts and speed
        self._show_shortcuts: bool = True  # auto-show first few turns
        self._speed_idx: int = 1  # index into GAME_SPEED_OPTIONS (1 = 1.0x)
        self._speed_value: float = GAME_SPEED_OPTIONS[1]

    def _build_action_buttons(self):
        """Build action buttons in 2 rows below player info."""
        build_action_buttons(self)

    def on_enter(self):
        self._build_action_buttons()
        # Initialize state tracking counts for animation detection
        self._sync_tracking_counts()
        self._setup_shuffle_callbacks()
        if self.state.phase == TurnPhase.SETUP and not self._setup_initialized:
            if not self._is_remote_client:
                self._init_setup()

    def _setup_shuffle_callbacks(self):
        """Wire shuffle animation triggers to player state."""
        if self.state:
            self.state.p1.on_shuffle = lambda: self._trigger_shuffle(0)
            self.state.p2.on_shuffle = lambda: self._trigger_shuffle(1)

    def _trigger_shuffle(self, player_idx: int):
        """Trigger shuffle animation for a player's deck."""
        zone_key = f"shuffle_{player_idx}"
        self.shuffle_anim.trigger(zone_key)

    def _sync_tracking_counts(self):
        """Snapshot current hand/discard/deck counts for all players."""
        if not self.state:
            return
        for pi in [0, 1]:
            player = self.state.get_player(pi)
            if player:
                self._last_hand_counts[pi] = len(player.hand)
                self._last_discard_counts[pi] = len(player.discard)
                self._last_deck_counts[pi] = len(player.deck)

    def _snapshot_field_state(self) -> dict:
        """Capture current field state for change detection."""
        if not self.state:
            return {}
        snap = {}
        for pi in [0, 1]:
            player = self.state.get_player(pi)
            key = f"p{pi}"
            snap[key] = {
                "active_id": player.active.card.api_id if player.active else None,
                "active_dmg": player.active.damage_counters if player.active else 0,
                "active_energy": len(player.active.energy_cards) if player.active else 0,
                "bench_ids": [p.card.api_id if p else None for p in player.bench],
                "bench_energy": [len(p.energy_cards) if p else 0 for p in player.bench],
            }
        return snap

    def _detect_field_changes(self, prev_snap: dict):
        """Detect field changes since previous snapshot and trigger animations."""
        if not self.state or not prev_snap:
            return
        curr = self._snapshot_field_state()
        for pi in [0, 1]:
            pk = f"p{pi}"
            prev = prev_snap.get(pk)
            cur = curr.get(pk)
            if not prev or not cur:
                continue
            is_self = (
                (self._is_remote_host and pi == self.my_player_idx) or
                (self._is_remote_client and pi == self.my_player_idx) or
                (not self._is_remote_host and not self._is_remote_client and
                 pi == self.state.active_player_idx)
            )
            # Active Pokemon evolution: same slot, different card
            if (prev["active_id"] and cur["active_id"] and
                    prev["active_id"] != cur["active_id"]):
                rect = (self._player_active_rect() if is_self
                        else self._opp_active_rect())
                if rect:
                    self.particles.spawn_particles(
                        evolution_glow(rect.x + rect.w // 2, rect.y + rect.h // 2))
                    get_audio().play("evolution")
            # New bench Pokemon placed
            for i in range(5):
                prev_id = prev["bench_ids"][i] if i < len(prev["bench_ids"]) else None
                cur_id = cur["bench_ids"][i] if i < len(cur["bench_ids"]) else None
                if prev_id is None and cur_id is not None:
                    get_audio().play("card_place")
                    break  # One sound per batch
            # Energy attached to active
            if cur["active_id"] and cur["active_energy"] > prev["active_energy"]:
                rect = (self._player_active_rect() if is_self
                        else self._opp_active_rect())
                if rect:
                    self.particles.spawn_particles(
                        energy_spark(rect.x + rect.w // 2, rect.y + rect.h // 2))
            # Energy attached to bench
            for i in range(5):
                p_e = prev["bench_energy"][i] if i < len(prev["bench_energy"]) else 0
                c_e = cur["bench_energy"][i] if i < len(cur["bench_energy"]) else 0
                c_ids = cur.get("bench_ids", [])
                if c_e > p_e and i < len(c_ids) and c_ids[i] is not None:
                    rect = (self._player_bench_rect(i) if is_self
                            else self._opp_bench_rect(i))
                    if rect:
                        self.particles.spawn_particles(
                            energy_spark(rect.x + rect.w // 2, rect.y + rect.h // 2))
            # Healing detected (damage counters decreased)
            if cur["active_id"] and cur["active_dmg"] < prev["active_dmg"]:
                rect = (self._player_active_rect() if is_self
                        else self._opp_active_rect())
                if rect:
                    self.particles.spawn_particles(
                        heal_sparkle(rect.x + rect.w // 2, rect.y + rect.h // 2))
                    slot_key = SLOT_PLAYER_ACTIVE if is_self else SLOT_OPP_ACTIVE
                    self.heal_flash.trigger(slot_key)

    def _init_setup(self):
        self._setup_initialized = True
        self.setup_player_idx = 0
        self.setup_pass_done = {0: False, 1: False}

        first = self.state.first_player_idx
        second = 1 - first
        for pi in [first, second]:
            mulligan_count = 0
            player = self.state.get_player(pi)
            opponent = self.state.get_player(1 - pi)
            for _ in range(10):
                if self.tm.needs_mulligan(pi):
                    mulligan_count += 1
                    self.state.do_mulligan(pi)
                    if mulligan_count == 1:
                        self.state._log(f"{player.name}的手牌中没有基础宝可梦，展示手牌后洗回牌库重抽7张！")
                    self.state._log(f"{opponent.name}可选择多抽1张卡。")
                else:
                    break
            if mulligan_count > 0:
                self.state._log(f"{player.name}共再战{mulligan_count}次，{opponent.name}多抽1张。")

        self._build_action_buttons()
        self.state._log("准备阶段开始！玩家1请放置基础宝可梦到战斗区。")

    # ── Event Handling ──────────────────────────────────────────

    def handle_event(self, event: pygame.event.Event):
        if self.state.phase == TurnPhase.GAME_OVER:
            self._show_end_screen()
            return

        # Coin flip animation
        if self.coin_flip.active:
            if self.coin_flip.handle_event(event):
                return

        # Confirm dialog
        if self._confirm_dialog is not None:
            self._handle_confirm_dialog_event(event)
            return

        # Block input while post-attack animations are playing
        if self._pending_turn_end > 0:
            return

        # Block input while card fly animation is playing (action deferred)
        if self._animating_action:
            return

        # Remote mode: block input when it's not this player's turn
        if self._is_remote_client or self._is_remote_host:
            if self._should_block_remote_input():
                # Only allow scroll wheel for log
                if event.type == pygame.MOUSEWHEEL:
                    log_x = SCREEN_WIDTH - LOG_W - 8
                    if log_x <= event.pos[0] <= log_x + LOG_W:
                        self._log_scroll_offset = max(0, self._log_scroll_offset - event.y)
                return

        if self._attack_menu_open:
            if event.type == pygame.MOUSEMOTION:
                self._attack_menu_hover = self._get_attack_menu_hover(event.pos)
            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                self._handle_attack_menu_click(event.pos)
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                self._attack_menu_open = False
            return

        if self._ability_menu_open:
            if event.type == pygame.MOUSEMOTION:
                self._ability_menu_hover = self._get_ability_menu_hover(event.pos)
            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                self._handle_ability_menu_click(event.pos)
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                self._ability_menu_open = False
            return

        player_idx = (
            self.setup_player_idx
            if self.state.phase == TurnPhase.SETUP
            else self.state.active_player_idx
        )

        if event.type == pygame.MOUSEMOTION:
            self._update_hover(event.pos, player_idx)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._handle_click(event.pos, player_idx)
        elif event.type == pygame.MOUSEWHEEL:
            # Scroll action log
            log_x = SCREEN_WIDTH - LOG_W - 8
            if log_x <= event.pos[0] <= log_x + LOG_W:
                self._log_scroll_offset = max(0, self._log_scroll_offset - event.y)
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                if self._attack_menu_open:
                    self._attack_menu_open = False
                elif self._ability_menu_open:
                    self._ability_menu_open = False
                elif self.selected_hand_idx is not None or self.selected_action is not None:
                    self._clear_selection()
                else:
                    self._confirm_quit_game()
            elif event.key == pygame.K_e:
                # End turn
                if self.state.phase == TurnPhase.MAIN:
                    self._execute_action(PlayerAction.END_TURN, player_idx)
            elif event.key == pygame.K_a:
                # Open attack menu
                if self.state.phase == TurnPhase.MAIN and self.selected_action is None:
                    self._show_attack_menu(player_idx)
            elif event.key == pygame.K_r:
                # Retreat mode
                if self.state.phase == TurnPhase.MAIN:
                    self._execute_action(PlayerAction.RETREAT, player_idx)
            elif event.key == pygame.K_SPACE:
                # Confirm / close menu
                if self._attack_menu_open:
                    self._handle_attack_menu_click(pygame.mouse.get_pos())
                elif self._ability_menu_open:
                    self._handle_ability_menu_click(pygame.mouse.get_pos())
            elif event.key == pygame.K_z and (pygame.key.get_mods() & pygame.KMOD_CTRL):
                # Undo last action
                self._do_undo()
            elif event.key == pygame.K_1:
                self._select_hand_key(0)
            elif event.key == pygame.K_2:
                self._select_hand_key(1)
            elif event.key == pygame.K_3:
                self._select_hand_key(2)
            elif event.key == pygame.K_4:
                self._select_hand_key(3)
            elif event.key == pygame.K_5:
                self._select_hand_key(4)
            elif event.key == pygame.K_6:
                self._select_hand_key(5)
            elif event.key == pygame.K_7:
                self._select_hand_key(6)
            elif event.key == pygame.K_8:
                self._select_hand_key(7)
            elif event.key == pygame.K_9:
                self._select_hand_key(8)
            elif event.key == pygame.K_q and not (pygame.key.get_mods() & pygame.KMOD_CTRL):
                self._confirm_quit_game()
            elif event.key == pygame.K_F1:
                self._show_shortcuts = not self._show_shortcuts
                self.floating_text.show(
                    f"快捷键提示: {'开' if self._show_shortcuts else '关'}",
                    400, SCREEN_HEIGHT - 60, color=UI_SUCCESS)
            elif event.key == pygame.K_TAB:
                self._speed_idx = (self._speed_idx + 1) % len(GAME_SPEED_OPTIONS)
                self._speed_value = GAME_SPEED_OPTIONS[self._speed_idx]
                self.floating_text.show(
                    f"游戏速度: {self._speed_value}x",
                    400, SCREEN_HEIGHT - 60, color=UI_HIGHLIGHT)
            elif event.key == pygame.K_c and not (pygame.key.get_mods() & pygame.KMOD_CTRL):
                # Test coin flip animation (3 flips demo)
                self._start_coin_flip(flip_count=3, on_result=lambda results: self.state._log(
                    f"硬币结果: {sum(1 for r in results if r)}正面, {sum(1 for r in results if not r)}反面"))

    def _get_display_player(self):
        """Get the player whose hand/board should be displayed at bottom.
        In remote mode, always show the local player (not opponent)."""
        if self._is_remote_host:
            return self.state.get_player(self.my_player_idx)
        if self._is_remote_client:
            return self.state.get_player(self.my_player_idx)
        if self.state.phase == TurnPhase.SETUP:
            return self.state.get_player(self.setup_player_idx)
        return self.state.get_active_player()

    def _get_opponent(self):
        """Get the opponent for UI rendering.
        In remote mode, opponent is always the other player regardless of turn."""
        if self._is_remote_host or self._is_remote_client:
            return self.state.get_player(1 - self.my_player_idx)
        if self.state.phase == TurnPhase.SETUP:
            other_idx = 1 - self.setup_player_idx
            return self.state.get_player(other_idx)
        return self.state.get_opponent()

    # ── Position helpers ────────────────────────────────────────

    def _active_x(self):
        """Center the active card in the play area."""
        return (PLAY_AREA_W - FIELD_ACTIVE_W) // 2

    def _bench_row_x(self):
        """Starting X for a row of 5 bench cards, centered in play area."""
        total_w = 5 * FIELD_BENCH_W + 4 * 8
        return (PLAY_AREA_W - total_w) // 2

    def _opp_active_rect(self):
        if not self._get_opponent().active:
            return None
        return pygame.Rect(self._active_x(), OPP_ACTIVE_Y, FIELD_ACTIVE_W, FIELD_ACTIVE_H)

    def _opp_bench_rect(self, idx):
        x = self._bench_row_x() + idx * (FIELD_BENCH_W + 8)
        return pygame.Rect(x, OPP_BENCH_Y, FIELD_BENCH_W, FIELD_BENCH_H)

    def _player_active_rect(self):
        return pygame.Rect(self._active_x(), PLAYER_ACTIVE_Y, FIELD_ACTIVE_W, FIELD_ACTIVE_H)

    def _player_bench_rect(self, idx):
        x = self._bench_row_x() + idx * (FIELD_BENCH_W + 8)
        return pygame.Rect(x, PLAYER_BENCH_Y, FIELD_BENCH_W, FIELD_BENCH_H)

    def _get_hand_layout(self):
        """Calculate hand card positions at the bottom of the screen."""
        return get_hand_layout(self)

    # ── Hover detection ─────────────────────────────────────────

    def _update_hover(self, pos, player_idx=None):
        """Update all hover states. Hand cards checked first for UI priority."""
        self.hovered_button = None
        self.hovered_hand = None
        self.hovered_bench = None
        self.hovered_active = False
        self.hovered_opp_bench = None
        self.hovered_opp_active = False
        self.hovered_opp_deck = False
        self.hovered_opp_discard_zone = False
        self.hovered_player_deck = False
        self.hovered_player_discard_zone = False

        # Action buttons (top priority — drawn on top of hand)
        for i, (rect, _, _) in enumerate(self.action_buttons):
            if rect.collidepoint(pos):
                self.hovered_button = i
                return

        # Hand
        layout = self._get_hand_layout()
        for i in range(len(layout) - 1, -1, -1):
            _, _, rect = layout[i]
            if rect.collidepoint(pos):
                self.hovered_hand = i
                return

        # Player bench
        for i in range(5):
            if self._player_bench_rect(i).collidepoint(pos):
                self.hovered_bench = i
                return

        # Player active
        rect = self._player_active_rect()
        if rect and rect.collidepoint(pos):
            self.hovered_active = True
            return

        # Opponent bench
        for i in range(5):
            if self._opp_bench_rect(i).collidepoint(pos):
                self.hovered_opp_bench = i
                return

        # Opponent active
        rect = self._opp_active_rect()
        if rect and rect.collidepoint(pos):
            self.hovered_opp_active = True
            return

        # Deck/discard zones
        opp_deck_rect = pygame.Rect(OPP_DECK_ZONE_X, OPP_DECK_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H)
        if opp_deck_rect.collidepoint(pos):
            self.hovered_opp_deck = True
            return

        opp_disc_rect = pygame.Rect(OPP_DISCARD_ZONE_X, OPP_DISCARD_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H)
        if opp_disc_rect.collidepoint(pos):
            self.hovered_opp_discard_zone = True
            return

        player_deck_rect = pygame.Rect(PLAYER_DECK_ZONE_X, PLAYER_DECK_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H)
        if player_deck_rect.collidepoint(pos):
            self.hovered_player_deck = True
            return

        player_disc_rect = pygame.Rect(PLAYER_DISCARD_ZONE_X, PLAYER_DISCARD_ZONE_Y, DECK_ZONE_W, DECK_ZONE_H)
        if player_disc_rect.collidepoint(pos):
            self.hovered_player_discard_zone = True
            return

        # Stadium button (if activatable)
        self.hovered_stadium_btn = False
        if self._stadium_is_activatable():
            btn = self._stadium_btn_rect()
            if btn and btn.collidepoint(pos):
                self.hovered_stadium_btn = True

        # Quit and concede buttons
        self.hovered_quit_btn = self.quit_btn_rect.collidepoint(pos)
        self.hovered_concede_btn = self.concede_btn_rect.collidepoint(pos)

    # ── Click handling ──────────────────────────────────────────

    def _handle_click(self, pos, player_idx):
        # Bench target selection mode (for bench-damage attacks etc.)
        if self._selecting_bench_targets is not None:
            req = self._selecting_bench_targets
            is_opponent = req.target_player == "opponent"
            hovered = self.hovered_opp_bench if is_opponent else self.hovered_bench
            if hovered is not None and hovered in req.bench_indices:
                if req.allow_duplicates or hovered not in self._selected_bench_targets:
                    self._selected_bench_targets.append(hovered)
                if len(self._selected_bench_targets) >= req.max_select:
                    if self._bench_target_handler_is_client:
                        self._resolving_remote_pending = False
                        self.network_manager.send({
                            "type": "resolve_pending",
                            "selected_bench_targets": list(self._selected_bench_targets),
                        })
                        self._bench_target_handler_is_client = False
                    elif req.callback:
                        req.callback(self._selected_bench_targets)
                    self._selecting_bench_targets = None
                    self._selected_bench_targets = []
            return

        if self._pending_tool_card is not None:
            tool_player_idx, hand_idx, _ = self._pending_tool_card
            target_clicked = False
            if self.hovered_active:
                self._do_play_trainer_tool(tool_player_idx, hand_idx, "active")
                target_clicked = True
            elif self.hovered_bench is not None:
                self._do_play_trainer_tool(tool_player_idx, hand_idx, f"bench_{self.hovered_bench}")
                target_clicked = True
            if target_clicked:
                self._pending_tool_card = None
            else:
                self.state._log("请点击目标宝可梦（战斗区或备战区）。")
            return

        if self._awaiting_promotion:
            if self.hovered_bench is not None:
                self._do_bench_promotion(player_idx, self.hovered_bench)
            else:
                self.state._log("请点击备战区宝可梦，选择要提升至战斗区的宝可梦。")
            return

        if self._pending_bench_select is not None:
            if self._pending_bench_select.request_type == "select_opponent_bench":
                if self.hovered_opp_bench is not None:
                    self._do_bench_select(self.hovered_opp_bench)
                else:
                    self.state._log("请点击对手的备战区宝可梦。")
            else:
                if self.hovered_bench is not None:
                    self._do_bench_select(self.hovered_bench)
                else:
                    self.state._log("请点击备战区宝可梦。")
            return

        if self.hovered_button is not None:
            _, label, action = self.action_buttons[self.hovered_button]
            self.selected_action = action
            self._execute_action(action, player_idx)
            return

        if self.hovered_opp_discard_zone:
            self._show_discard_view(is_opponent=True)
            return
        if self.hovered_player_discard_zone:
            self._show_discard_view(is_opponent=False)
            return

        if self.hovered_opp_deck:
            opponent = self._get_opponent()
            self.floating_text.show(f"对手牌库: {len(opponent.deck)}张",
                                     OPP_DECK_ZONE_X + DECK_ZONE_W // 2,
                                     OPP_DECK_ZONE_Y + DECK_ZONE_H + 10,
                                     color=UI_HIGHLIGHT, duration=1.0)
            return
        if self.hovered_player_deck:
            player = self._get_display_player()
            self.floating_text.show(f"牌库: {len(player.deck)}张",
                                     PLAYER_DECK_ZONE_X + DECK_ZONE_W // 2,
                                     PLAYER_DECK_ZONE_Y + DECK_ZONE_H + 10,
                                     color=UI_HIGHLIGHT, duration=1.0)
            return

        if self.hovered_stadium_btn:
            self._execute_action(PlayerAction.USE_STADIUM, player_idx)
            return

        if self.hovered_quit_btn:
            self._confirm_quit_game()
            return
        if self.hovered_concede_btn:
            self._confirm_concede()
            return

        if self.hovered_hand is not None:
            self.selected_hand_idx = self.hovered_hand
            self._handle_hand_selection(player_idx)
            return

        if self.hovered_bench is not None:
            self._handle_bench_click(player_idx, self.hovered_bench)
            return

        if self.hovered_active:
            self._handle_active_click(player_idx)

    def _handle_hand_selection(self, player_idx):
        if self.selected_hand_idx is None:
            return

        actual_player = (
            self.setup_player_idx
            if self.state.phase == TurnPhase.SETUP
            else player_idx
        )
        player = self.state.get_player(actual_player)
        if self.selected_hand_idx >= len(player.hand):
            return

        card = player.hand[self.selected_hand_idx]

        if self.state.phase == TurnPhase.SETUP:
            if not card.is_basic_pokemon:
                self.state._log(f"{card.name}不是基础宝可梦，准备阶段只能放置基础宝可梦。")
                self._clear_selection()
                return
            if self.selected_action == "PLACE_ACTIVE":
                self._setup_place(actual_player, "active")
            elif self.selected_action == "PLACE_BENCH":
                self._setup_place(actual_player, "bench")
            else:
                if player.active is None:
                    self.selected_action = "PLACE_ACTIVE"
                    self._setup_place(actual_player, "active")
                else:
                    self.selected_action = "PLACE_BENCH"
                    self._setup_place(actual_player, "bench")
            return

        if self.selected_action == PlayerAction.PLAY_BASIC and card.is_basic_pokemon:
            self._place_basic(player_idx)
        elif self.selected_action == PlayerAction.EVOLVE and (card.is_stage1 or card.is_stage2):
            self.state._log(f"已选择{card.name}，请点击要进化的宝可梦（战斗区或备战区）。")
            return
        elif self.selected_action == PlayerAction.ATTACH_ENERGY and card.is_energy:
            self.state._log(f"已选择{card.name}，请点击目标宝可梦（战斗区或备战区）。")
            return
        elif self.selected_action == PlayerAction.PLAY_TRAINER and card.is_trainer:
            if card.is_trainer_tool:
                self._pending_tool_card = (player_idx, self.selected_hand_idx, card)
                self.state._log(f"已选择{card.name}，请点击目标宝可梦（战斗区或备战区）。")
            else:
                self._play_trainer(player_idx)
        else:
            if card.is_basic_pokemon:
                self.selected_action = PlayerAction.PLAY_BASIC
                self._place_basic(player_idx)
            elif card.is_energy:
                self.selected_action = PlayerAction.ATTACH_ENERGY
                self.state._log(f"已选择{card.name}，请点击目标宝可梦（战斗区或备战区）。")
            elif card.is_trainer:
                if card.is_trainer_tool:
                    self._pending_tool_card = (player_idx, self.selected_hand_idx, card)
                    self.state._log(f"已选择{card.name}，请点击目标宝可梦（战斗区或备战区）。")
                else:
                    self.selected_action = PlayerAction.PLAY_TRAINER
                    self._play_trainer(player_idx)

    # ── Setup Phase ─────────────────────────────────────────────

    def _setup_place(self, player_idx, zone="active"):
        if self.selected_hand_idx is None:
            return
        player = self.state.get_player(player_idx)
        if self.selected_hand_idx >= len(player.hand):
            return

        if self._is_remote_client:
            if zone == "active":
                target = "active"
            else:
                empty = player.find_empty_bench_slot()
                if empty is None:
                    self.state._log("备战区已满（最多5只）。")
                    self._clear_selection()
                    return
                target = f"bench_{empty}"

            # Send to host immediately, play fly animation in parallel
            self.network_manager.send({
                "type": "action",
                "action": "PLAY_BASIC",
                "params": {"hand_idx": self.selected_hand_idx, "target": target,
                           "player_idx": player_idx},
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            rect = (self._player_active_rect() if target == "active"
                    else self._player_bench_rect(int(target.split("_")[1])))
            if rect:
                card_name = player.hand[self.selected_hand_idx].name if self.selected_hand_idx < len(player.hand) else None
                self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                         card_name, on_complete=on_anim_done)
            else:
                on_anim_done()

            self._clear_selection()
            return

        if zone == "active":
            if player.active is not None:
                self.state._log("战斗区已有宝可梦，请先将其移到备战区或完成准备。")
                self._clear_selection()
                return
            target = "active"
        else:
            empty = player.find_empty_bench_slot()
            if empty is None:
                self.state._log("备战区已满（最多5只）。")
                self._clear_selection()
                return
            target = f"bench_{empty}"

        captured_hand_idx = self.selected_hand_idx
        captured_target = target
        captured_player_idx = player_idx

        self._animating_action = True
        self._animating_hand_idx = self.selected_hand_idx

        def on_animation_done():
            result = self.tm.setup_place_basic(captured_player_idx, captured_hand_idx, captured_target)
            if not result.success:
                self.state._log(f"放置失败: {result.log_message}")
            self._clear_selection()
            self._animating_action = False
            self._animating_hand_idx = None
            self._sync_tracking_counts()
            if self._is_remote_host:
                self._broadcast_state()

        # Fly animation from hand to target
        rect = (self._player_active_rect() if captured_target == "active"
                else self._player_bench_rect(int(captured_target.split("_")[1])))
        if rect:
            card_name = player.hand[captured_hand_idx].name if captured_hand_idx < len(player.hand) else None
            self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                     card_name, on_complete=on_animation_done)
        else:
            on_animation_done()

    def _setup_done(self, player_idx):
        player = self.state.get_player(player_idx)
        if player.active is None:
            self.state._log("请先放置一只基础宝可梦到战斗区！")
            return

        if self._is_remote_client:
            self.network_manager.send({
                "type": "action",
                "action": "SETUP_DONE",
                "params": {"player_idx": player_idx},
            })
            self._clear_selection()
            self.selected_action = None
            return

        self.setup_pass_done[player_idx] = True
        self.state._log(f"玩家{player_idx + 1}准备好了。")

        if self.setup_pass_done[0] and self.setup_pass_done[1]:
            result = self.tm.setup_finalize()
            if result.success:
                self.state._log(result.log_message)
                self._build_action_buttons()
                if self._is_remote_host:
                    self._waiting_remote = (self.state.active_player_idx != self.my_player_idx)
                    self._broadcast_state()
        else:
            other = 1 - player_idx
            self.setup_player_idx = other
            self._clear_selection()
            if self._is_remote_host:
                # Remote player's turn during setup - broadcast state and wait
                self._broadcast_state()
                self._waiting_remote = True
                self.state._log(f"等待玩家{other + 1}放置基础宝可梦...")
            else:
                from ui.screens.pass_screen import PassScreen
                pass_screen = PassScreen(
                    self.manager, other,
                    on_continue=lambda: self.manager.pop_screen(SlideTransition(0.35, "right")),
                    game_state=self.state, turn_number=0
                )
                self.manager.push_screen(pass_screen)

    def _handle_bench_click(self, player_idx, bench_idx):
        if self._awaiting_promotion:
            self._do_bench_promotion(player_idx, bench_idx)
            return

        if self.selected_action == PlayerAction.PLAY_BASIC:
            self._place_basic(player_idx, target=f"bench_{bench_idx}")
        elif self.selected_action == PlayerAction.EVOLVE and self.selected_hand_idx is not None:
            self._evolve_pokemon(player_idx, slot=f"bench_{bench_idx}")
        elif self.selected_action == PlayerAction.ATTACH_ENERGY and self.selected_hand_idx is not None:
            self._attach_energy(player_idx, target=f"bench_{bench_idx}")
        elif self.selected_action == PlayerAction.USE_ABILITY:
            self._try_use_ability(player_idx, f"bench_{bench_idx}")
        elif self.selected_action == PlayerAction.RETREAT:
            self._retreat_to_bench(player_idx, bench_idx)

    def _handle_active_click(self, player_idx):
        if self.selected_action == PlayerAction.ATTACH_ENERGY and self.selected_hand_idx is not None:
            self._attach_energy(player_idx, target="active")
        elif self.selected_action == PlayerAction.EVOLVE and self.selected_hand_idx is not None:
            self._evolve_pokemon(player_idx, slot="active")
        elif self.selected_action == PlayerAction.USE_ABILITY:
            self._try_use_ability(player_idx, "active")
        elif self.selected_action == PlayerAction.DECLARE_ATTACK:
            self._show_attack_menu(player_idx)

    # ── Action Execution ────────────────────────────────────────

    def _fly_card_from_hand(self, target_x: float, target_y: float, card_name: str = None,
                            on_complete: callable = None):
        """Trigger a card fly animation from the hand position to a target."""
        hand_layout = self._get_hand_layout()
        hand_idx = self.selected_hand_idx
        if hand_idx is None or hand_idx >= len(hand_layout):
            if on_complete:
                on_complete()
            return
        start_x, start_y, _ = hand_layout[hand_idx]
        # Create a card surface to animate
        from ui.components.board_renderer import get_card_image_surface
        card_surf = get_card_image_surface(self, card_name, CARD_WIDTH, CARD_HEIGHT)
        if card_surf is None:
            # Create a visible fallback card surface
            card_surf = pygame.Surface((CARD_WIDTH, CARD_HEIGHT), pygame.SRCALPHA)
            card_surf.fill((80, 100, 180, 220))
            pygame.draw.rect(card_surf, (255, 255, 255, 180),
                           (2, 2, CARD_WIDTH - 4, CARD_HEIGHT - 4), 1, border_radius=6)

        def _on_fly_finish():
            get_audio().play("card_place")
            if on_complete:
                on_complete()

        self.card_fly.fly(
            card_surf,
            start_x + CARD_WIDTH // 2, start_y + CARD_HEIGHT // 2,
            target_x, target_y,
            duration=0.5,  # longer duration for visibility
            on_complete=_on_fly_finish,
        )

    def _place_basic(self, player_idx, target="bench_0"):
        if self.selected_hand_idx is None:
            return
        if self._is_remote_client:
            captured_hand_idx = self.selected_hand_idx

            # Find a valid target (same fallback logic as local path)
            player = self.state.get_player(player_idx)
            if target == "active":
                if player.active is not None:
                    empty = player.find_empty_bench_slot()
                    if empty is not None:
                        target = f"bench_{empty}"
            elif target.startswith("bench_"):
                bench_idx = int(target.split("_")[1])
                if player.bench[bench_idx] is not None:
                    empty = player.find_empty_bench_slot()
                    if empty is not None:
                        target = f"bench_{empty}"
            else:
                if player.active is None:
                    target = "active"
                else:
                    empty = player.find_empty_bench_slot()
                    if empty is not None:
                        target = f"bench_{empty}"
            # Send to host immediately, play fly animation in parallel
            self.network_manager.send({
                "type": "action",
                "action": "PLAY_BASIC",
                "params": {"hand_idx": self.selected_hand_idx, "target": target,
                           "player_idx": player_idx},
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            rect = (self._player_active_rect() if target == "active"
                    else self._player_bench_rect(int(target.split("_")[1])))
            if rect:
                card_name = player.hand[self.selected_hand_idx].name if self.selected_hand_idx < len(player.hand) else None
                self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                         card_name, on_complete=on_anim_done)
            else:
                on_anim_done()

            self._clear_selection()
            return
        player = self.state.get_player(player_idx)
        # Respect the target parameter if it specifies a valid slot
        if target == "active":
            if player.active is not None:
                empty = player.find_empty_bench_slot()
                if empty is not None:
                    target = f"bench_{empty}"
        elif target.startswith("bench_"):
            bench_idx = int(target.split("_")[1])
            if player.bench[bench_idx] is not None:
                empty = player.find_empty_bench_slot()
                if empty is not None:
                    target = f"bench_{empty}"
        else:
            if player.active is None:
                target = "active"
            else:
                empty = player.find_empty_bench_slot()
                if empty is not None:
                    target = f"bench_{empty}"

        # Defer game logic until card fly animation completes
        captured_hand_idx = self.selected_hand_idx
        captured_target = target
        captured_player_idx = player_idx

        self._animating_action = True
        self._animating_hand_idx = self.selected_hand_idx

        def on_animation_done():
            result = self.tm.perform_action(
                PlayerAction.PLAY_BASIC, player_idx=captured_player_idx,
                hand_idx=captured_hand_idx, target=captured_target,
            )
            self._show_result(result)
            self._clear_selection()
            self._animating_action = False
            self._animating_hand_idx = None
            self._sync_tracking_counts()

        # Card fly animation: from hand to target slot
        rect = self._player_active_rect() if captured_target == "active" else \
               self._player_bench_rect(int(captured_target.split("_")[1])
                                       if captured_target.startswith("bench_") else 0)
        if rect:
            card_name = player.hand[captured_hand_idx].name if captured_hand_idx < len(player.hand) else None
            self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                     card_name, on_complete=on_animation_done)
        else:
            on_animation_done()

    def _evolve_pokemon(self, player_idx, slot="active"):
        if self.selected_hand_idx is None:
            return
        if self._is_remote_client:
            player = self.state.get_player(player_idx)

            # Send to host immediately, play fly animation in parallel
            self.network_manager.send({
                "type": "action",
                "action": "EVOLVE",
                "params": {"hand_idx": self.selected_hand_idx, "slot": slot, "player_idx": player_idx},
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            rect = (self._player_active_rect() if slot == "active"
                    else self._player_bench_rect(int(slot.split("_")[1])))
            if rect:
                card_name = player.hand[self.selected_hand_idx].name if self.selected_hand_idx < len(player.hand) else None
                self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                         card_name, on_complete=on_anim_done)
            else:
                on_anim_done()

            self._clear_selection()
            return

        captured_hand_idx = self.selected_hand_idx
        captured_slot = slot
        captured_player_idx = player_idx

        self._animating_action = True
        self._animating_hand_idx = self.selected_hand_idx

        def on_animation_done():
            result = self.tm.perform_action(
                PlayerAction.EVOLVE, player_idx=captured_player_idx,
                hand_idx=captured_hand_idx, slot=captured_slot,
            )
            self._show_result(result)
            if result.success:
                get_audio().play("evolution")
                self._save_undo("evolve", captured_player_idx, slot=captured_slot)
                player = self.state.get_player(captured_player_idx)
                pokemon = player.get_pokemon(captured_slot)
                if pokemon:
                    rect = (self._player_active_rect() if captured_slot == "active"
                            else self._player_bench_rect(int(captured_slot.split("_")[1])))
                    if rect:
                        self.particles.spawn_particles(
                            evolution_glow(rect.x + rect.w // 2, rect.y + rect.h // 2))
            self._clear_selection()
            self._animating_action = False
            self._animating_hand_idx = None
            self._sync_tracking_counts()

        rect = (self._player_active_rect() if captured_slot == "active"
                else self._player_bench_rect(int(captured_slot.split("_")[1])))
        if rect:
            player = self.state.get_player(captured_player_idx)
            card_name = player.hand[captured_hand_idx].name if captured_hand_idx < len(player.hand) else None
            self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                     card_name, on_complete=on_animation_done)
        else:
            on_animation_done()

    def _attach_energy(self, player_idx, target="active"):
        if self.selected_hand_idx is None:
            return
        if self._is_remote_client:
            player = self.state.get_player(player_idx)

            # Send to host immediately, play fly animation in parallel
            self.network_manager.send({
                "type": "action",
                "action": "ATTACH_ENERGY",
                "params": {"hand_idx": self.selected_hand_idx, "target_slot": target,
                           "player_idx": player_idx},
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            rect = (self._player_active_rect() if target == "active"
                    else self._player_bench_rect(int(target.split("_")[1])))
            if rect:
                card_name = player.hand[self.selected_hand_idx].name if self.selected_hand_idx < len(player.hand) else None
                self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                         card_name, on_complete=on_anim_done)
            else:
                on_anim_done()

            self._clear_selection()
            return

        captured_hand_idx = self.selected_hand_idx
        captured_target = target
        captured_player_idx = player_idx

        self._animating_action = True
        self._animating_hand_idx = self.selected_hand_idx

        def on_animation_done():
            result = self.tm.perform_action(
                PlayerAction.ATTACH_ENERGY, player_idx=captured_player_idx,
                hand_idx=captured_hand_idx, target_slot=captured_target,
            )
            self._show_result(result)
            self._clear_selection()
            self._animating_action = False
            self._animating_hand_idx = None
            self._sync_tracking_counts()

        rect = (self._player_active_rect() if captured_target == "active"
                else self._player_bench_rect(int(captured_target.split("_")[1])))
        if rect:
            player = self.state.get_player(captured_player_idx)
            card_name = player.hand[captured_hand_idx].name if captured_hand_idx < len(player.hand) else None
            self._fly_card_from_hand(rect.x + rect.w // 2, rect.y + rect.h // 2,
                                     card_name, on_complete=on_animation_done)
        else:
            on_animation_done()

    def _play_trainer(self, player_idx):
        if self.selected_hand_idx is None:
            return
        if self._is_remote_client:
            captured_hand_idx = self.selected_hand_idx
            captured_player_idx = player_idx
            player = self.state.get_player(captured_player_idx)

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx

            # Send to host immediately, play fly animation in parallel
            self.network_manager.send({
                "type": "action",
                "action": "PLAY_TRAINER",
                "params": {"hand_idx": self.selected_hand_idx, "player_idx": player_idx},
            })

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            # Fly card from hand to center (generic play animation).
            # Record the target position as discard animation source so the
            # card visually flies from "played" position → discard pile.
            target_x = PLAY_AREA_W // 2
            target_y = HAND_Y + CARD_HEIGHT // 2
            self._last_action_source = (target_x, target_y)
            card_name = player.hand[self.selected_hand_idx].name if self.selected_hand_idx < len(player.hand) else None
            self._last_action_card_name = card_name
            self._last_action_card_obj = player.hand[self.selected_hand_idx] if self.selected_hand_idx < len(player.hand) else None
            self._fly_card_from_hand(target_x, target_y, card_name, on_complete=on_anim_done)

            self._clear_selection()
            return

        captured_hand_idx = self.selected_hand_idx
        captured_player_idx = player_idx
        player = self.state.get_player(captured_player_idx)
        card = player.hand[captured_hand_idx] if captured_hand_idx < len(player.hand) else None

        if card is None:
            self._clear_selection()
            return

        # Hide card from hand during action
        self._animating_action = True
        self._animating_hand_idx = self.selected_hand_idx

        # Record source position and card info for potential discard animation
        hand_layout = self._get_hand_layout()
        if captured_hand_idx < len(hand_layout):
            sx, sy, _ = hand_layout[captured_hand_idx]
            self._last_action_source = (sx + CARD_WIDTH // 2, sy + CARD_HEIGHT // 2)
            self._last_action_card_name = card.name
            self._last_action_card_obj = card

        result = self.tm.perform_action(
            PlayerAction.PLAY_TRAINER, player_idx=captured_player_idx,
            hand_idx=captured_hand_idx,
        )

        # If there's a pending action, store the card locally for cancel support
        if result.pending_action and card.is_trainer:
            self._pending_trainer_card = card
            # Don't clear animation state yet - pending action UI is about to show
        else:
            # No pending action: directly trigger discard animation
            saved_hand_idx = self._animating_hand_idx
            self._animating_action = False
            self._animating_hand_idx = None
            if result.success:
                src_x = self._last_action_source[0] if self._last_action_source else PLAY_AREA_W // 2
                src_y = self._last_action_source[1] if self._last_action_source else HAND_Y + CARD_HEIGHT // 2
                src_slot = f"hand_{saved_hand_idx}" if saved_hand_idx is not None else None
                self._last_action_source = None
                self._last_action_card_name = None
                self._last_action_card_obj = None
                self._animate_discard(captured_player_idx, src_x, src_y, card.name, card, source_slot=src_slot)

        self._show_result(result)
        self._clear_selection()

        # Don't sync — let _detect_state_changes trigger discard animation

    def _do_play_trainer_tool(self, player_idx, hand_idx, target_slot):
        """Play a tool card with explicit target_slot."""
        if self._is_remote_client:
            player = self.state.get_player(player_idx)

            # Send to host immediately, play fly animation in parallel
            self.network_manager.send({
                "type": "action",
                "action": "PLAY_TRAINER",
                "params": {"hand_idx": hand_idx, "target_slot": target_slot, "player_idx": player_idx},
            })

            self._animating_action = True
            self._animating_hand_idx = hand_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            target_x = PLAY_AREA_W // 2
            target_y = HAND_Y + CARD_HEIGHT // 2
            # Record play position and card info as discard animation source so
            # the card flies from the "played" position to the discard pile.
            self._last_action_source = (target_x, target_y)
            card_name = player.hand[hand_idx].name if hand_idx < len(player.hand) else None
            self._last_action_card_name = card_name
            self._last_action_card_obj = player.hand[hand_idx] if hand_idx < len(player.hand) else None
            self._fly_card_from_hand(target_x, target_y, card_name, on_complete=on_anim_done)

            self._clear_selection()
            return
        result = self.tm.perform_action(
            PlayerAction.PLAY_TRAINER, player_idx=player_idx,
            hand_idx=hand_idx, target_slot=target_slot,
        )
        self._show_result(result)
        self._clear_selection()

    def _retreat_to_bench(self, player_idx, bench_idx):
        if self._is_remote_client:
            self.network_manager.send({
                "type": "action",
                "action": "RETREAT",
                "params": {"bench_idx": bench_idx, "player_idx": player_idx},
            })
            self._clear_selection()
            return
        result = self.tm.perform_action(
            PlayerAction.RETREAT, player_idx=player_idx,
            bench_idx=bench_idx,
        )
        self._show_result(result)
        self._clear_selection()

    def _show_attack_menu(self, player_idx):
        player = self.state.get_active_player()
        if player.active is None:
            return

        attacks = player.active.card.attacks
        valid_attacks = [
            (i, atk) for i, atk in enumerate(attacks)
            if player.active.has_enough_energy(atk.cost)
        ]

        if not valid_attacks:
            self.state._log("没有足够的能量使用任何招式！请先附着能量。")
            self._clear_selection()
            return

        # Pre-calculate damage against opponent's active
        opponent = self.state.get_opponent()
        damage_previews = {}
        if opponent.active:
            from engine.damage_calculator import calculate_damage
            attacker = player.active
            defender = opponent.active
            for i, atk in valid_attacks:
                if atk.damage > 0:
                    atk_type = attacker.card.energy_types[0] if attacker.card.energy_types else "Colorless"
                    dmg = calculate_damage(
                        atk.damage, atk_type,
                        defender.card,
                        defender.card.weaknesses or [],
                        defender.card.resistances or [],
                    )
                    # Check if weakness/resistance applies
                    has_weakness = any(
                        w.energy_type == atk_type for w in (defender.card.weaknesses or [])
                    )
                    has_resistance = any(
                        r.energy_type == atk_type for r in (defender.card.resistances or [])
                    )
                    damage_previews[i] = {
                        "damage": dmg,
                        "weakness": has_weakness,
                        "resistance": has_resistance,
                        "will_ko": dmg >= defender.current_hp,
                    }

        # Build attack menu items with damage preview
        self._attack_menu_damage_previews = damage_previews

        # Only auto-execute when the Pokemon has exactly one attack total.
        # If there are multiple attacks, always show the menu so the player
        # can choose — even if only one has enough energy right now.
        if len(valid_attacks) == 1 and len(attacks) == 1:
            i, attack = valid_attacks[0]
            if self._is_remote_client:
                self.network_manager.send({
                    "type": "action",
                    "action": "DECLARE_ATTACK",
                    "params": {"attack_idx": i, "player_idx": player_idx},
                })
                self._clear_selection()
                return
            result = self.tm.declare_attack(player_idx, i)
            self._show_result(result)
            if result.success:
                self._build_action_buttons()
            elif result.pending_action:
                self._handle_pending_action(result.pending_action)
        elif valid_attacks:
            self._attack_menu_open = True
            self._attack_menu_attacks = valid_attacks
        self._clear_selection()

    @staticmethod
    def _has_manual_ability(pokemon) -> bool:
        """Check if a Pokemon has at least one manually-activatable ability."""
        if not pokemon or not pokemon.card.abilities:
            return False
        for ab in pokemon.card.abilities:
            if getattr(ab, 'trigger', '') not in ('on_enter_play', 'passive'):
                return True
        return False

    def _select_ability_target(self, player_idx):
        """Prompt the player to select a Pokemon, then select an ability.
        Excludes 'on_enter_play' abilities (auto-triggered on evolve/place)."""
        player = self.state.get_active_player()
        pokemon_with_abilities = []
        if player.active and self._has_manual_ability(player.active):
            pokemon_with_abilities.append(("active", player.active))
        for i, p in enumerate(player.bench):
            if p and self._has_manual_ability(p):
                pokemon_with_abilities.append((f"bench_{i}", p))

        if not pokemon_with_abilities:
            self.state._log("场上没有可手动发动的特性。")
            return

        if len(pokemon_with_abilities) == 1:
            slot, _ = pokemon_with_abilities[0]
            self._try_use_ability(player_idx, slot)
        else:
            self.selected_action = PlayerAction.USE_ABILITY
            self.state._log("请点击具有特性的宝可梦（战斗区或备战区）以使用其特性。")

    def _try_use_ability(self, player_idx, slot):
        """Show ability menu if Pokemon has multiple manually-usable abilities."""
        player = self.state.get_player(player_idx)
        pokemon = player.get_pokemon(slot)
        if pokemon is None or not pokemon.card.abilities:
            self.state._log(f"该宝可梦没有特性。")
            return

        # Exclude on-enter-play and passive abilities
        abilities = [ab for ab in pokemon.card.abilities
                     if getattr(ab, 'trigger', '') not in ('on_enter_play', 'passive')]
        if not abilities:
            self.state._log(f"{pokemon.card.name}的特性只能在出场时发动。")
            return

        if len(abilities) == 1:
            if self._is_remote_client:
                self.network_manager.send({
                    "type": "action",
                    "action": "USE_ABILITY",
                    "params": {"slot": slot, "ability_name": abilities[0].name, "player_idx": player_idx},
                })
                self._clear_selection()
                return
            self._do_use_ability(player_idx, slot, abilities[0].name)
        else:
            if self._is_remote_client:
                self._ability_menu_open = True
                self._ability_menu_abilities = abilities
                self._ability_menu_hover = None
                self._ability_menu_slot = slot
                self._ability_menu_player_idx = player_idx
                return
            self._ability_menu_open = True
            self._ability_menu_abilities = abilities
            self._ability_menu_hover = None
            self._ability_menu_slot = slot
            self._ability_menu_player_idx = player_idx

    def _do_use_ability(self, player_idx, slot, ability_name=""):
        """Use a specific manually-usable ability."""
        player = self.state.get_player(player_idx)
        pokemon = player.get_pokemon(slot)
        if pokemon is None or not pokemon.card.abilities:
            self.state._log(f"该宝可梦没有特性。")
            return
        if not ability_name:
            ability_name = pokemon.card.abilities[0].name
        # Reject on-enter-play and passive abilities
        for ab in pokemon.card.abilities:
            if ab.name == ability_name and getattr(ab, 'trigger', '') in ('on_enter_play', 'passive'):
                self.state._log(f"「{ab.name}」是持续生效的特性，不能手动使用。")
                return
        result = self.tm.perform_action(
            PlayerAction.USE_ABILITY, player_idx=player_idx,
            slot=slot, ability_name=ability_name,
        )
        self._show_result(result)
        self._clear_selection()

    def _get_ability_menu_hover(self, pos):
        mx = SCREEN_WIDTH // 2 - 240
        num_abs = len(self._ability_menu_abilities)
        item_h = 48
        total_h = num_abs * (item_h + 8) - 8
        my = SCREEN_HEIGHT // 2 - total_h // 2 - 20
        for i in range(len(self._ability_menu_abilities)):
            rect = pygame.Rect(mx, my + i * (item_h + 8), 480, item_h)
            if rect.collidepoint(pos):
                return i
        return None

    def _handle_ability_menu_click(self, pos):
        if self._ability_menu_hover is not None:
            ab = self._ability_menu_abilities[self._ability_menu_hover]
            self._ability_menu_open = False
            if self._is_remote_client:
                self.network_manager.send({
                    "type": "action",
                    "action": "USE_ABILITY",
                    "params": {
                        "slot": self._ability_menu_slot,
                        "ability_name": ab.name,
                        "player_idx": self._ability_menu_player_idx,
                    },
                })
                self._clear_selection()
                return
            self._do_use_ability(
                self._ability_menu_player_idx,
                self._ability_menu_slot,
                ab.name,
            )
        else:
            self._ability_menu_open = False

    def _activate_stadium(self, player_idx):
        """Activate the stadium card's per-turn effect."""
        if self._is_remote_client:
            self.network_manager.send({
                "type": "action",
                "action": "USE_STADIUM",
                "params": {"player_idx": player_idx},
            })
            return
        result = self.tm.perform_action(
            PlayerAction.USE_STADIUM, player_idx=player_idx,
        )
        self._show_result(result)
        if result.success:
            self._build_action_buttons()

    def _end_turn(self, player_idx):
        player = self.state.get_active_player()
        can_attack_now = False
        if player.active and self.state.phase == TurnPhase.MAIN:
            if not (self.state.is_first_turn()
                    and self.state.active_player_idx == self.state.first_player_idx
                    and player_idx == self.state.first_player_idx):
                for atk in player.active.card.attacks:
                    if player.active.has_enough_energy(atk.cost):
                        can_attack_now = True
                        break

        if can_attack_now and not self._end_turn_warned:
            self._end_turn_warned = True
            self._confirm_dialog = {
                "title": "确认结束回合",
                "message": "你还有可用的招式！确定要结束回合吗？",
                "confirm_label": "确定结束",
                "cancel_label": "返回",
                "on_confirm": self._do_end_turn,
                "on_cancel": self._cancel_end_turn,
            }
            return

        self._do_end_turn()

    def _draw_shortcut_hints(self, surface):
        """Draw a compact keyboard shortcut hints panel."""
        if not self._show_shortcuts:
            # Auto-hide after first few turns
            if self.state.turn_number > 3:
                return
        if self._confirm_dialog is not None:
            return

        hints = [
            ("1-9", "选手牌"),
            ("A", "攻击"),
            ("E", "结束"),
            ("R", "撤退"),
            ("Space", "确认"),
            ("Esc", "取消/退出"),
            ("Q", "退出"),
            ("Ctrl+Z", "撤销"),
            ("Tab", f"{self._speed_value}x速"),
            ("F1", "隐藏"),
        ]

        panel_w = 135
        panel_h = len(hints) * 18 + 10
        panel_x = SCREEN_WIDTH - panel_w - 10
        panel_y = SCREEN_HEIGHT - panel_h - 30

        # Semi-transparent panel
        panel = pygame.Surface((panel_w, panel_h), pygame.SRCALPHA)
        panel.fill((10, 10, 30, 160))
        surface.blit(panel, (panel_x, panel_y))
        pygame.draw.rect(surface, (60, 60, 100), (panel_x, panel_y, panel_w, panel_h), 1, border_radius=5)

        for i, (key, desc) in enumerate(hints):
            by = panel_y + 6 + i * 18
            # Key badge
            key_txt = self.font_card_tiny.render(key, True, UI_HIGHLIGHT)
            surface.blit(key_txt, (panel_x + 6, by))
            # Description
            desc_txt = self.font_card_tiny.render(desc, True, UI_TEXT_SECONDARY)
            surface.blit(desc_txt, (panel_x + 44, by))

    def _start_coin_flip(self, flip_count: int = 1, on_result: callable = None,
                         until_tails: bool = False):
        """Start the coin flip animation with N flips and result callback."""
        if not self.coin_flip.active:
            self.coin_flip.start(flip_count=flip_count, on_result=on_result,
                                until_tails=until_tails)

    def _draw_confirm_dialog(self, surface):
        """Draw a modal confirmation dialog."""
        if self._confirm_dialog is None:
            return

        d = self._confirm_dialog

        # Semi-transparent overlay
        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((0, 0, 0, 150))
        surface.blit(overlay, (0, 0))

        # Dialog box
        dw, dh = 440, 180
        dx = (SCREEN_WIDTH - dw) // 2
        dy = (SCREEN_HEIGHT - dh) // 2
        dialog_rect = pygame.Rect(dx, dy, dw, dh)
        pygame.draw.rect(surface, UI_BG_DARK, dialog_rect, border_radius=12)
        pygame.draw.rect(surface, UI_HIGHLIGHT, dialog_rect, 2, border_radius=12)

        # Title
        title_txt = self.font_info.render(d.get("title", "确认"), True, UI_HIGHLIGHT)
        surface.blit(title_txt, title_txt.get_rect(center=(SCREEN_WIDTH // 2, dy + 28)))

        # Message
        msg_txt = self.font_body.render(d.get("message", ""), True, UI_TEXT_PRIMARY)
        surface.blit(msg_txt, msg_txt.get_rect(center=(SCREEN_WIDTH // 2, dy + 72)))

        # Confirm button
        btn_w, btn_h = 140, 38
        confirm_x = SCREEN_WIDTH // 2 - btn_w - 20
        confirm_y = dy + dh - btn_h - 20
        confirm_rect = pygame.Rect(confirm_x, confirm_y, btn_w, btn_h)
        d["confirm_rect"] = confirm_rect
        confirm_color = UI_BUTTON_HOVER if d.get("confirm_hover") else UI_DANGER
        pygame.draw.rect(surface, confirm_color, confirm_rect, border_radius=8)
        pygame.draw.rect(surface, UI_TEXT_PRIMARY, confirm_rect, 1, border_radius=8)
        confirm_txt = self.font_action.render(d.get("confirm_label", "确认"), True, UI_TEXT_PRIMARY)
        surface.blit(confirm_txt, confirm_txt.get_rect(center=confirm_rect.center))

        # Cancel button
        cancel_x = SCREEN_WIDTH // 2 + 20
        cancel_y = confirm_y
        cancel_rect = pygame.Rect(cancel_x, cancel_y, btn_w, btn_h)
        d["cancel_rect"] = cancel_rect
        cancel_color = UI_BUTTON_HOVER if d.get("cancel_hover") else UI_BUTTON
        pygame.draw.rect(surface, cancel_color, cancel_rect, border_radius=8)
        pygame.draw.rect(surface, UI_TEXT_PRIMARY, cancel_rect, 1, border_radius=8)
        cancel_txt = self.font_action.render(d.get("cancel_label", "取消"), True, UI_TEXT_PRIMARY)
        surface.blit(cancel_txt, cancel_txt.get_rect(center=cancel_rect.center))

    def _cancel_end_turn(self):
        self._end_turn_warned = False
        self._confirm_dialog = None
        self.state._log("已取消结束回合。")

    def _handle_confirm_dialog_event(self, event):
        """Handle events when the confirm dialog is shown."""
        if event.type == pygame.MOUSEMOTION:
            d = self._confirm_dialog
            d["confirm_hover"] = d.get("confirm_rect", pygame.Rect(0, 0, 0, 0)).collidepoint(event.pos)
            d["cancel_hover"] = d.get("cancel_rect", pygame.Rect(0, 0, 0, 0)).collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            d = self._confirm_dialog
            if d.get("confirm_rect", pygame.Rect(0, 0, 0, 0)).collidepoint(event.pos):
                d["on_confirm"]()
            elif d.get("cancel_rect", pygame.Rect(0, 0, 0, 0)).collidepoint(event.pos):
                d["on_cancel"]()
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                self._confirm_dialog["on_cancel"]()
            elif event.key == pygame.K_SPACE or event.key == pygame.K_RETURN:
                self._confirm_dialog["on_confirm"]()

    def _after_pending_trainer_resolve(self, action_req):
        """Discard the pending trainer card and clear animation lock."""
        if not self._pending_trainer_card:
            return
        card = self._pending_trainer_card
        player = self.state.get_player(action_req.player)
        if card.is_trainer_supporter:
            player.discard.append(card)
        elif card.is_trainer_item:
            player.discard.append(card)
        self._pending_trainer_card = None
        self._animating_action = False
        self._animating_hand_idx = None

    def _do_confirm_yes(self, action_req):
        """Handle a confirm dialog 'yes' response."""
        self._confirm_dialog = None
        if action_req.callback:
            chain_result = action_req.callback(True)
            if chain_result is not None:
                self._handle_pending_action(chain_result)

    def _do_confirm_no(self, action_req):
        """Handle a confirm dialog 'no' response."""
        self._confirm_dialog = None
        if action_req.callback:
            action_req.callback(False)

    def _do_end_turn(self) -> None:
        if self._turn_ending:
            return  # Already processing end turn
        self._turn_ending = True
        self._end_turn_warned = False
        self._confirm_dialog = None
        if self._is_remote_client:
            self._waiting_remote = True  # Block input until state_sync arrives
            self.network_manager.send({
                "type": "action",
                "action": "END_TURN",
                "params": {"player_idx": self.state.active_player_idx},
            })
            self._clear_selection()
            return
        was_attack = self.state.phase == TurnPhase.ATTACK
        result = self.tm.perform_action(
            PlayerAction.END_TURN, player_idx=self.state.active_player_idx,
        )
        self._show_result(result)
        if result.success:
            if self._is_remote_host:
                pass  # _show_result already broadcasts internally
            # After attack, delay turn switch so KO/prize animations play
            if was_attack:
                self._pending_turn_end = 0.3
            # For local hot-seat: push PassScreen immediately to hide opponent's hand
            is_local = not self._is_remote_host and not self._is_remote_client
            if is_local:
                self._handle_turn_end()
            elif self._pending_turn_end <= 0:
                self._handle_turn_end()
        self._clear_selection()

    def _get_attack_menu_hover(self, pos):
        mx = SCREEN_WIDTH // 2 - 240
        num_atks = len(self._attack_menu_attacks)
        item_h = 56
        total_h = num_atks * (item_h + 10) - 10
        my = SCREEN_HEIGHT // 2 - total_h // 2 - 20
        for i in range(len(self._attack_menu_attacks)):
            rect = pygame.Rect(mx, my + i * (item_h + 10), 480, item_h)
            if rect.collidepoint(pos):
                return i
        return None

    def _handle_attack_menu_click(self, pos):
        if self._attack_menu_hover is not None:
            player_idx = self.state.active_player_idx
            i, attack = self._attack_menu_attacks[self._attack_menu_hover]
            if self._is_remote_client:
                self.network_manager.send({
                    "type": "action",
                    "action": "DECLARE_ATTACK",
                    "params": {"attack_idx": i, "player_idx": player_idx},
                })
                self._attack_menu_open = False
                self._clear_selection()
                return
            result = self.tm.declare_attack(player_idx, i)
            self._show_result(result)
            self._attack_menu_open = False
            if result.success:
                # After attack, show only "结束回合" button — player must click it
                self._build_action_buttons()
                self._clear_selection()
            if self._is_remote_host:
                # _show_result already broadcasts internally with attacker_player_idx
                pass
        else:
            self._attack_menu_open = False

    def _handle_turn_end(self) -> None:
        self._turn_ending = False  # Allow next End Turn
        if self.state.phase == TurnPhase.GAME_OVER:
            self._show_end_screen()
            return

        next_player = self.state.active_player_idx

        if self._is_remote_host:
            if self.state.pending_promotion_player >= 0:
                self._check_promotion_needed()
            self._broadcast_state()
            # If the next player is remote, wait
            if next_player == self.my_player_idx:
                # Local player's turn — clear waiting state
                self._waiting_remote = False
                self._build_action_buttons()
            else:
                self._waiting_remote = True
                self._build_action_buttons()
                self.state._log(f"等待玩家{next_player + 1}操作...")
            return

        if self._is_remote_client:
            # Client doesn't manage turn end - state_sync handles it
            return

        # Local mode: show PassScreen. Draw happens on dismiss so animation
        # plays after PassScreen is gone.
        from ui.screens.pass_screen import PassScreen

        def on_continue():
            self._sync_tracking_counts()
            player = self.state.get_active_player()
            # Skip draw animation when promotion is pending — the draw hasn't
            # happened yet. _detect_state_changes will pick it up after promotion.
            if player and player.hand and self.state.pending_promotion_player < 0:
                last_card = player.hand[-1]
                self._animate_draw(self.state.active_player_idx, last_card.name, last_card)
            self.manager.pop_screen(SlideTransition(0.35, "right"))
            self._build_action_buttons()
            if self.state.pending_promotion_player >= 0:
                self._check_promotion_needed()

        pass_screen = PassScreen(
            self.manager, next_player,
            on_continue=on_continue,
            game_state=self.state,
            turn_number=self.state.turn_number
        )
        self.manager.push_screen(pass_screen, SlideTransition(0.35, "left"))

    def _show_end_screen(self, custom_reason: str = None):
        from ui.screens.end_screen import EndScreen
        winner = self.state.winner
        if winner is None:
            return
        if custom_reason:
            reason = custom_reason
        elif not self.state.get_player(1 - winner).has_any_pokemon_in_play():
            reason = "对手场上没有宝可梦"
        elif not self.state.get_player(1 - winner).deck:
            reason = "对手无法抽牌"
        else:
            reason = "全部奖品卡获取完毕"
        prizes1 = 6 - len(self.state.p1.prizes)
        prizes2 = 6 - len(self.state.p2.prizes)

        if self._is_remote_host:
            self.network_manager.send({
                "type": "game_over",
                "winner": winner,
                "reason": reason,
                "prizes_taken": (prizes1, prizes2),
            })

        end_screen = EndScreen(
            self.manager, winner, reason, (prizes1, prizes2),
            network_manager=self.network_manager,
            is_remote=self._is_remote_host or self._is_remote_client,
        )
        self.manager.replace_top(end_screen, FadeTransition(0.6))

    def _execute_action(self, action, player_idx):
        # Setup-phase UI actions — handle before remote client guard
        if action == "PLACE_ACTIVE":
            self.selected_action = "PLACE_ACTIVE"
            self.state._log("请从手牌选择一只基础宝可梦放到战斗区。")
            return
        elif action == "PLACE_BENCH":
            self.selected_action = "PLACE_BENCH"
            self.state._log("请从手牌选择一只基础宝可梦放到备战区。")
            return
        elif action == "SETUP_DONE":
            self._setup_done(player_idx)
            return

        # Actions that need local UI before sending to host
        if self._is_remote_client and action not in (
            PlayerAction.DECLARE_ATTACK,
            PlayerAction.USE_ABILITY,
            PlayerAction.RETREAT,
            PlayerAction.ATTACH_ENERGY,
            PlayerAction.EVOLVE,
            PlayerAction.PLAY_TRAINER,
            PlayerAction.PLAY_BASIC,
        ):
            self._send_action_to_host(action, player_idx)
            return

        if action == PlayerAction.USE_STADIUM:
            if self._is_remote_client:
                self._send_action_to_host(action, player_idx)
            else:
                self._activate_stadium(player_idx)
            return

        if action == PlayerAction.END_TURN:
            self._end_turn(player_idx)
        else:
            self._end_turn_warned = False

        if action == PlayerAction.ATTACH_ENERGY:
            self.state._log("请从手牌选择一张能量卡，然后点击目标宝可梦。")
        elif action == PlayerAction.EVOLVE:
            self.state._log("请从手牌选择一张进化卡，然后点击要进化的宝可梦。")
        elif action == PlayerAction.PLAY_TRAINER:
            self.state._log("请从手牌选择一张训练家卡使用。")
        elif action == PlayerAction.USE_ABILITY:
            self._select_ability_target(player_idx)
        elif action == PlayerAction.DECLARE_ATTACK:
            self._show_attack_menu(player_idx)
        elif action == PlayerAction.RETREAT:
            self.state._log("请点击备战区的宝可梦以进行撤退。")
            self.selected_action = PlayerAction.RETREAT

    def _send_action_to_host(self, action, player_idx):
        """Client mode: serialize action and send to host."""
        from network.message_protocol import ACTION_TO_STRING

        # Guard against rapid End Turn — only one END_TURN may be in flight
        if action == PlayerAction.END_TURN:
            if self._turn_ending:
                return
            self._turn_ending = True
            self._waiting_remote = True

        params = {}
        if self.selected_hand_idx is not None:
            params["hand_idx"] = self.selected_hand_idx
        if isinstance(action, str):
            action_str = action
        else:
            action_str = ACTION_TO_STRING.get(action, str(action))
        params["player_idx"] = player_idx

        self.network_manager.send({
            "type": "action",
            "action": action_str,
            "params": params,
        })

        # For actions that need more context (target, slot, etc.)
        if action_str == "SETUP_DONE":
            self.selected_action = None
            self.selected_hand_idx = None
        elif action_str == "ATTACH_ENERGY":
            self.state._log("请从手牌选择一张能量卡，然后点击目标宝可梦。")
        elif action_str == "EVOLVE":
            self.state._log("请从手牌选择一张进化卡，然后点击要进化的宝可梦。")
        elif action_str == "PLAY_TRAINER":
            self.state._log("请从手牌选择一张训练家卡使用。")
        elif action_str == "RETREAT":
            self.state._log("请点击备战区的宝可梦以进行撤退。")
            self.selected_action = PlayerAction.RETREAT

    def _show_result(self, result: "ActionResult", attacker_player_idx: int | None = None,
                     action=None) -> None:
        if not result.success:
            self.state._log(f"错误: {result.log_message}")
        elif result.pending_action:
            # If the current active player is remote, defer to client
            if self._is_remote_host and self.state.active_player_idx != self.my_player_idx:
                self._pending_remote_action = result.pending_action
                # Will be broadcast by _broadcast_result at end of this method
            else:
                self._handle_pending_action(result.pending_action)
                result.pending_action = None  # Handled locally, don't broadcast
        else:
            # Determine animation slot keys based on who performed the action
            is_self_attacker = (attacker_player_idx is None or
                                attacker_player_idx == self.my_player_idx)
            if is_self_attacker:
                damage_slot = SLOT_OPP_ACTIVE  # Opponent takes damage
                shake_slot = SLOT_PLAYER_ACTIVE  # We attacked
                damage_rect = self._opp_active_rect()
                attacker_rect = self._player_active_rect()
            else:
                damage_slot = SLOT_PLAYER_ACTIVE  # We take damage
                shake_slot = SLOT_OPP_ACTIVE  # Opponent attacked
                damage_rect = self._player_active_rect()
                attacker_rect = self._opp_active_rect()

            # Trigger animations and particles on success
            if result.damage_dealt > 0:
                self.damage_flash.trigger(damage_slot)
                self.attack_shake.trigger(shake_slot)
                get_audio().play("attack_hit")
                # Attack impact particles on the target
                if damage_rect:
                    cx = damage_rect.x + damage_rect.w // 2
                    cy = damage_rect.y + damage_rect.h // 2
                    self.particles.spawn_particles(attack_impact(cx, cy))
            if result.pokemon_ko:
                self.ko_fade.trigger(damage_slot)
                get_audio().play("pokemon_ko")
                # KO burst particles on the KO'd Pokemon
                if damage_rect:
                    cx = damage_rect.x + damage_rect.w // 2
                    cy = damage_rect.y + damage_rect.h // 2
                    self.particles.spawn_particles(ko_burst(cx, cy))

            # Draw animation trigger
            if result.cards_drawn:
                for card in result.cards_drawn:
                    card_name = card.name if hasattr(card, 'name') else None
                    self._animate_draw(self.state.active_player_idx, card_name)
                # Sync counts after draw to prevent double-detection
                self._sync_tracking_counts()
            if self.selected_action == PlayerAction.ATTACH_ENERGY and self.selected_hand_idx is not None:
                self._save_undo("attach_energy", self.state.active_player_idx,
                                target_slot="active")
                # Energy spark on player's active
                rect = self._player_active_rect()
                if rect:
                    self.particles.spawn_particles(
                        energy_spark(rect.x + rect.w // 2, rect.y + rect.h // 2))
            elif self.selected_action == "PLACE_BENCH":
                self._save_undo("place_bench", self.state.active_player_idx,
                                target="last_bench")

        # Broadcast state to remote player after every action in host mode
        if self._is_remote_host and result.success:
            self._broadcast_state()
            self._broadcast_result(result, action=action, attacker_player_idx=attacker_player_idx)

        # Defer promotion check if PassScreen should come first
        if self.state.pending_promotion_player < 0:
            self._check_promotion_needed()

    def _check_promotion_needed(self) -> None:
        if self.state.phase == TurnPhase.GAME_OVER:
            return
        player = self._get_display_player()
        if player.active is None:
            bench_pokes = [(i, p) for i, p in enumerate(player.bench) if p is not None]
            if not bench_pokes:
                return
            if len(bench_pokes) == 1:
                player.promote_from_bench(bench_pokes[0][0])
                self.state._log(f"{player.name}将{player.active.card.name}提升至战斗区。")
                self._awaiting_promotion = False
                if self.state.pending_promotion_player >= 0:
                    self.tm.continue_after_promotion()
                return
            elif len(bench_pokes) > 1:
                self._awaiting_promotion = True
                self.state._log("请点击备战区宝可梦，选择要提升至战斗区的宝可梦。")
                return

    def _do_bench_select(self, bench_idx):
        action_req = self._pending_bench_select
        self._pending_bench_select = None
        if action_req is None:
            return
        if getattr(self, '_pending_bench_select_client', False):
            self._pending_bench_select_client = False
            self.network_manager.send({
                "type": "resolve_pending",
                "selected_bench_slot": bench_idx,
            })
            return
        if action_req.request_type == "select_own_bench_energy":
            # Energy attach to bench: call the callback with selected index
            if action_req.callback:
                call_result = action_req.callback(bench_idx)
                if self._is_remote_host and call_result:
                    self._show_result(call_result)
            return
        # Use explicit player index from ActionRequest if valid, otherwise fall back
        # to the active player (for self-switch) or opponent (for opponent-switch)
        if hasattr(action_req, 'player') and action_req.player >= 0:
            player = self.state.get_player(action_req.player)
        elif action_req.request_type == "select_bench":
            player = self.state.get_active_player()
        else:
            player = self.state.get_opponent()
        if player.bench[bench_idx] is None:
            self.state._log("该位置没有宝可梦。")
            return
        player.switch_active_to_bench(bench_idx)
        self.state._log(f"{player.name}的战斗宝可梦被替换了。")
        if action_req.callback:
            action_req.callback(bench_idx)
        if self._is_remote_host:
            self._broadcast_state()

    def _do_bench_promotion(self, player_idx, bench_idx):
        player = self._get_display_player()
        if player.bench[bench_idx] is None:
            self.state._log("该位置没有宝可梦。")
            return
        player.promote_from_bench(bench_idx)
        self.state._log(f"{player.name}将{player.active.card.name}提升至战斗区。")
        self._awaiting_promotion = False
        self._clear_selection()
        if self.state.pending_promotion_player >= 0:
            self.tm.continue_after_promotion()

    def _show_energy_distribution(self, action_req):
        """Open the energy distribution screen."""
        from ui.screens.energy_distribution_screen import EnergyDistributionScreen

        def on_distribution_complete(assignments):
            # assignments: list of (energy_idx, target_slot)
            if action_req.callback:
                action_req.callback(assignments)

        screen = EnergyDistributionScreen(
            self.manager, {
                "energy_cards": action_req.card_list,
                "targets": getattr(action_req, 'target_info', []),
                "mode": getattr(action_req, 'distribute_mode', 'distribute'),
                "max_per_target": getattr(action_req, 'max_per_target', 99),
                "source_name": getattr(action_req, 'source_name', ''),
            },
            on_distribution_complete,
        )
        self.manager.push_screen(screen)

    def _show_discard_view(self, is_opponent: bool):
        """Open a read-only search screen showing a player's discard pile."""
        from ui.screens.search_screen import SearchScreen
        player = self._get_opponent() if is_opponent else self._get_display_player()
        label = "对手弃牌区" if is_opponent else "我方弃牌区"
        if not player.discard:
            self.state._log(f"{label}为空。")
            return
        request = ActionRequest(
            request_type="search_deck",
            player=0,  # not used for read-only
            prompt=f"{label}（只读查看）",
            min_select=0,
            max_select=0,
            from_zone="discard",
            card_list=list(player.discard),
            callback=None,
        )
        search_screen = SearchScreen(
            self.manager, request,
            on_complete=lambda cards: None,
            chain_handler=self._handle_pending_action,
        )
        self.manager.push_screen(search_screen)

    def _handle_pending_action(self, action_req):
        # In client mode, intercept and send results back to host
        if self._is_remote_client:
            self._handle_pending_action_client(action_req)
            return

        if action_req.request_type in ("search_deck", "select_hand_to_discard"):
            from ui.screens.search_screen import SearchScreen
            original_callback = action_req.callback or (lambda cards: None)
            def wrapped_callback(selected_cards):
                call_result = original_callback(selected_cards)
                # Discard the consumed trainer card after successful resolution
                if self._pending_trainer_card:
                    card = self._pending_trainer_card
                    player = self.state.get_player(action_req.player)
                    player.discard.append(card)
                    saved_hand_idx = self._animating_hand_idx
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    # Trigger discard animation from hand position
                    src_x = self._last_action_source[0] if self._last_action_source else PLAY_AREA_W // 2
                    src_y = self._last_action_source[1] if self._last_action_source else HAND_Y + CARD_HEIGHT // 2
                    src_slot = f"hand_{saved_hand_idx}" if saved_hand_idx is not None else None
                    self._last_action_source = None
                    self._last_action_card_name = None
                    self._last_action_card_obj = None
                    self._animate_discard(action_req.player, src_x, src_y, card.name, card, source_slot=src_slot)
                # Broadcast updated state after resolving pending action
                if self._is_remote_host:
                    if isinstance(call_result, ActionRequest):
                        # Chained pending action (e.g. Ultra Ball: discard → search).
                        # Wrap its callback so the host broadcasts after the chain completes,
                        # then return it so _confirm_selection reuses this screen via
                        # _reinit_with_request (instead of pushing a new screen that
                        # _confirm_selection would then accidentally pop).
                        raw_cb = call_result.callback
                        def chain_broadcast_wrapper(selected):
                            cb_result = raw_cb(selected) if raw_cb else None
                            if cb_result is not None:
                                self._show_result(cb_result)
                            else:
                                self._broadcast_state()
                            return cb_result
                        call_result.callback = chain_broadcast_wrapper
                    elif call_result is not None:
                        self._show_result(call_result)
                    else:
                        self._broadcast_state()
                return call_result
            def on_cancel():
                if self._pending_trainer_card:
                    player = self.state.get_player(action_req.player)
                    card = self._pending_trainer_card
                    player.hand.append(card)
                    if card.is_trainer_supporter:
                        player.supporter_played_this_turn = False
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    self.state._log("操作已取消，卡牌返回手牌。")
            search_screen = SearchScreen(
                self.manager, action_req,
                on_complete=wrapped_callback,
                chain_handler=self._handle_pending_action,
                on_cancel=on_cancel,
            )
            self.manager.push_screen(search_screen)
        elif action_req.request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            # Wrap the callback to handle pending_card discard on success
            if self._pending_trainer_card:
                orig_cb = action_req.callback
                def bench_cb_with_discard(bench_idx):
                    call_result = orig_cb(bench_idx) if orig_cb else None
                    card = self._pending_trainer_card
                    player = self.state.get_player(action_req.player)
                    player.discard.append(card)
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    src_x = self._last_action_source[0] if self._last_action_source else PLAY_AREA_W // 2
                    src_y = self._last_action_source[1] if self._last_action_source else HAND_Y + CARD_HEIGHT // 2
                    self._last_action_source = None
                    self._last_action_card_name = None
                    self._last_action_card_obj = None
                    self._animate_discard(action_req.player, src_x, src_y, card.name, card)
                    # Broadcast updated state
                    if self._is_remote_host:
                        from engine.game_state import ActionRequest as AR
                        if isinstance(call_result, AR):
                            self._handle_pending_action(call_result)
                        elif call_result is not None:
                            self._show_result(call_result)
                        else:
                            self._broadcast_state()
                action_req.callback = bench_cb_with_discard
            self._handle_bench_select_prompt(action_req)
        elif action_req.request_type == "coin_flip":
            def on_flip_done(results):
                chain_result = action_req.callback(results) if action_req.callback else None
                # Discard pending card on coin flip resolution
                if self._pending_trainer_card and chain_result and chain_result.success:
                    player = self.state.get_player(action_req.player)
                    player.discard.append(self._pending_trainer_card)
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    # Don't sync — let _detect_state_changes handle discard animation
                if chain_result and chain_result.pending_action:
                    self._handle_pending_action(chain_result.pending_action)
                elif chain_result:
                    self._show_result(chain_result)
            self._start_coin_flip(
                flip_count=getattr(action_req, 'flip_count', 1),
                on_result=on_flip_done,
                until_tails=getattr(action_req, 'until_tails', False),
            )
        elif action_req.request_type == "confirm":
            # Wrap callbacks to handle pending trainer card discard
            def _confirm_yes():
                self._confirm_dialog = None
                if action_req.callback:
                    chain_result = action_req.callback(True)
                    self._after_pending_trainer_resolve(action_req)
                    if chain_result is not None:
                        self._handle_pending_action(chain_result)

            def _confirm_no():
                self._confirm_dialog = None
                # Cancel: return pending card to hand
                if self._pending_trainer_card:
                    card = self._pending_trainer_card
                    player = self.state.get_player(action_req.player)
                    player.hand.append(card)
                    if card.is_trainer_supporter:
                        player.supporter_played_this_turn = False
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    self.state._log("操作已取消，卡牌返回手牌。")
                elif action_req.callback:
                    action_req.callback(False)

            self._confirm_dialog = {
                "title": "确认",
                "message": action_req.prompt,
                "confirm_label": "是",
                "cancel_label": "否",
                "on_confirm": _confirm_yes,
                "on_cancel": _confirm_no,
            }
        elif action_req.request_type == "distribute_energy":
            self._show_energy_distribution(action_req)
        elif action_req.request_type == "select_bench_targets":
            self._selecting_bench_targets = action_req
            self._selected_bench_targets = []
            self.state._log(action_req.prompt)
        else:
            self.state._log(f"待处理: {action_req.prompt}")

    def _handle_pending_action_client(self, action_req):
        """Client mode: intercept pending action and send results to host."""
        nm = self.network_manager
        if action_req.request_type in ("search_deck", "select_hand_to_discard"):
            from ui.screens.search_screen import SearchScreen
            def on_complete(cards):
                # Get indices of selected cards in the full card_list
                card_ids = [getattr(c, 'api_id', c) if hasattr(c, 'api_id') else c for c in cards]
                indices = []
                for cid in card_ids:
                    for i, item in enumerate(action_req.card_list):
                        item_id = item.api_id if hasattr(item, 'api_id') else item
                        if item_id == cid or str(item_id) == str(cid):
                            indices.append(i)
                            break
                self._resolving_remote_pending = False
                nm.send({
                    "type": "resolve_pending",
                    "selected_indices": indices,
                })
            def on_cancel_client():
                self._resolving_remote_pending = False
                nm.send({
                    "type": "resolve_pending",
                    "cancelled": True,
                })
            search_screen = SearchScreen(
                self.manager, action_req,
                on_complete=on_complete,
                chain_handler=self._handle_pending_action_client,
                on_cancel=on_cancel_client,
            )
            self.manager.push_screen(search_screen)
        elif action_req.request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            # For bench selection, use local handling but send result back
            self._handle_bench_select_prompt_client(action_req)
        elif action_req.request_type == "coin_flip":
            def on_flip_done(results):
                self._resolving_remote_pending = False
                nm.send({
                    "type": "resolve_pending",
                    "coin_results": results,
                })
            self._start_coin_flip(
                flip_count=getattr(action_req, 'flip_count', 1),
                on_result=on_flip_done,
                until_tails=getattr(action_req, 'until_tails', False),
            )
        elif action_req.request_type == "select_bench_targets":
            self._selecting_bench_targets = action_req
            self._selected_bench_targets = []
            self.state._log(action_req.prompt)
            # Override the bench target selection handler to send to network
            self._bench_target_handler_is_client = True
        else:
            self.state._log(f"待处理: {action_req.prompt}")

    def _handle_bench_select_prompt_client(self, action_req):
        """Client mode bench selection: choose locally, send result to host."""
        if action_req.request_type == "select_opponent_bench":
            player = self.state.get_opponent()
            is_opponent = True
        else:
            player = self.state.get_active_player()
            is_opponent = False
        bench_with_pokemon = [
            i for i, p in enumerate(player.bench) if p is not None
        ]
        if not bench_with_pokemon:
            self.state._log("备战区没有宝可梦可选。")
            return
        if len(bench_with_pokemon) == 1:
            self._resolving_remote_pending = False
            self.network_manager.send({
                "type": "resolve_pending",
                "selected_bench_slot": bench_with_pokemon[0],
            })
        else:
            # Store for click handling
            self._animating_action = False
            self._animating_hand_idx = None
            self._pending_bench_select = action_req
            self._pending_bench_select_client = True
            if action_req.request_type == "select_bench":
                self.state._log("请点击自己的备战区宝可梦进行替换。")
            else:
                self.state._log("请点击对手的备战区宝可梦进行替换。")

    def _handle_bench_select_prompt(self, action_req):
        if action_req.request_type == "select_opponent_bench":
            player = self.state.get_opponent()
        elif getattr(action_req, 'target_player', '') == "opponent":
            player = self.state.get_opponent()
        elif getattr(action_req, 'player', -1) >= 0:
            player = self.state.get_player(action_req.player)
        else:
            player = self.state.get_active_player()
        bench_with_pokemon = [
            i for i, p in enumerate(player.bench) if p is not None
        ]
        if not bench_with_pokemon:
            self.state._log("备战区没有宝可梦可选。")
            if action_req.callback:
                action_req.callback(None)
            return
        if action_req.request_type == "select_own_bench_energy":
            # Energy attach to bench: always let player choose (don't auto)
            self._animating_action = False
            self._animating_hand_idx = None
            self._pending_bench_select = action_req
            self.state._log("请点击备战区宝可梦选择附着目标。")
        elif len(bench_with_pokemon) == 1:
            bench_idx = bench_with_pokemon[0]
            player.switch_active_to_bench(bench_idx)
            self.state._log(f"{player.name}的战斗宝可梦被替换了。")
            if action_req.callback:
                action_req.callback(bench_idx)
        else:
            self._animating_action = False
            self._animating_hand_idx = None
            self._pending_bench_select = action_req
            if action_req.request_type == "select_bench":
                self.state._log("请点击自己的备战区宝可梦进行替换。")
            else:
                self.state._log("请点击对手的备战区宝可梦进行替换。")

    def update(self, dt: float) -> None:
        """Update animations and visual effects."""
        # Apply game speed multiplier
        sdt = dt * self._speed_value

        # Network polling
        if self.network_manager:
            for msg in self.network_manager.poll():
                self._process_network_message(msg)
            if self.network_manager.is_connected and self.network_manager.is_stale:
                if not hasattr(self, '_stale_warn_timer'):
                    self._stale_warn_timer = 0.0
                self._stale_warn_timer += dt
                if self._stale_warn_timer > 5.0:
                    self._stale_warn_timer = 0.0
                    self.state._log("警告: 对手连接超时，可能已断开。")

        self.anim_mgr.update(sdt)
        self.damage_flash.update(sdt)
        self.ko_fade.update(sdt)
        self.attack_shake.update(sdt)
        self.floating_text.update(sdt)
        self.card_fly.update(sdt)
        self.heal_flash.update(sdt)
        self.draw_flash.update(sdt)
        self.damage_ripple.update(sdt)
        self.particles.update(sdt)
        self.coin_flip.update(sdt)
        self.shuffle_anim.update(sdt)

        # Waiting indicator (online play)
        if self.network_manager:
            if self._is_remote_client and self._should_block_remote_input():
                self.waiting_indicator.show("等待对手操作...")
            elif self._is_remote_client and self._resolving_remote_pending:
                self.waiting_indicator.show("等待对手确认...")
            elif self._is_remote_host and self._should_block_remote_input():
                self.waiting_indicator.show("等待对手操作...")
            elif self._waiting_remote:
                self.waiting_indicator.show("等待对手操作...")
            else:
                self.waiting_indicator.hide()
        else:
            self.waiting_indicator.hide()
        self.waiting_indicator.update(sdt)

        # State sync fade decay (use sdt for speed multiplier consistency)
        if self._state_sync_fade > 0:
            self._state_sync_fade = max(0, self._state_sync_fade - sdt)

        # Detect state changes for discard/mill animations
        self._detect_state_changes()

        # Smooth hand card lift animation
        LIFT_SMOOTH_FACTOR = 20.0
        player = self._get_display_player()
        if player and player.hand:
            for i in range(len(player.hand)):
                target = CARD_HOVER_LIFT if self.hovered_hand == i else 0
                current = self._card_lift_offset.get(i, 0.0)
                self._card_lift_offset[i] = current + (target - current) * min(1.0, sdt * LIFT_SMOOTH_FACTOR)

        # Delayed turn end (let attack/damage animations play first)
        if self._pending_turn_end > 0:
            self._pending_turn_end -= sdt
            if self._pending_turn_end <= 0:
                self._pending_turn_end = 0
                if self._is_remote_host or self._is_remote_client:
                    self._handle_turn_end()

    def _clear_selection(self):
        self.selected_hand_idx = None
        self.selected_action = None
        self._confirm_end_turn = False

    def _should_block_remote_input(self) -> bool:
        """Check if the local player should be blocked from interacting."""
        if self._is_remote_client:
            # Client can only act when it's their turn
            if self.state.phase == TurnPhase.SETUP:
                return self.setup_player_idx != self.my_player_idx
            return self.state.active_player_idx != self.my_player_idx
        if self._is_remote_host:
            # Host can only act when it's their turn (not remote player's)
            if self.state.phase == TurnPhase.SETUP:
                return self.setup_player_idx != self.my_player_idx
            return self.state.active_player_idx != self.my_player_idx
        return False

    # ── Network methods ──────────────────────────────────────────

    def _broadcast_state(self):
        """Send current game state to the remote player."""
        if not self.network_manager or not self._is_remote_host:
            return
        from network.state_serializer import serialize_game_state
        remote_idx = 1 - self.my_player_idx
        state_data = serialize_game_state(self.state, for_player_idx=remote_idx)
        msg = {
            "type": "state_sync",
            "state": state_data,
            "setup_player_idx": getattr(self, 'setup_player_idx', 0),
        }
        self.network_manager.send(msg)

    def _broadcast_result(self, result, action=None, attacker_player_idx=None):
        """Send action result to the remote player."""
        if not self.network_manager or not self._is_remote_host:
            return
        from network.state_serializer import serialize_action_request
        from network.message_protocol import ACTION_TO_STRING
        msg = {
            "type": "action_result",
            "success": result.success,
            "log_message": result.log_message,
            "damage_dealt": result.damage_dealt,
            "pokemon_ko": result.pokemon_ko,
            "status_applied": result.status_applied,
            "prize_taken": result.prize_taken,
            "cards_drawn": len(result.cards_drawn),
            "cards_discarded": result.cards_discarded,
        }
        if attacker_player_idx is not None:
            msg["attacker_player_idx"] = attacker_player_idx
        if action is not None:
            msg["action"] = ACTION_TO_STRING.get(action, str(action))
        if result.success:
            desc = self._build_action_desc(result)
            if desc:
                msg["action_desc"] = desc
        if result.pending_action:
            msg["pending_action"] = serialize_action_request(result.pending_action)
        self.network_manager.send(msg)

    def _process_network_message(self, msg: dict):
        """Handle a message from the network."""
        msg_type = msg.get("type", "")

        if msg_type == "state_sync":
            # Client mode: update local state from host
            if not self._is_remote_client:
                return
            from network.state_serializer import deserialize_game_state

            # Save old counts for local player before state replacement
            old_player = self.state.get_player(self.my_player_idx)
            old_hand = len(old_player.hand) if old_player else 0
            old_discard = len(old_player.discard) if old_player else 0
            old_deck = len(old_player.deck) if old_player else 0

            prev_snap = self._snapshot_field_state()
            new_state = deserialize_game_state(
                msg["state"], for_player_idx=self.my_player_idx
            )
            self.state = new_state
            if "setup_player_idx" in msg:
                self.setup_player_idx = msg["setup_player_idx"]
            self._build_action_buttons()
            self._turn_ending = False
            self._waiting_remote = False
            self._resolving_remote_pending = False
            self._state_sync_fade = 0.15

            # Detect draw/discard for local player from state diff
            new_player = self.state.get_player(self.my_player_idx)
            new_hand = len(new_player.hand) if new_player else 0
            new_discard = len(new_player.discard) if new_player else 0
            new_deck = len(new_player.deck) if new_player else 0

            if new_hand > old_hand and new_deck < old_deck:
                drawn = min(new_hand - old_hand, old_deck - new_deck)
                for _ in range(drawn):
                    self._animate_draw(self.my_player_idx)

            # Detect trainer card discard. Two cases:
            # 1. Immediate discard (e.g. Professor's Research): hand AND discard changed
            # 2. Deferred discard (e.g. Nest Ball search): only discard changed,
            #    because the hand was refilled by the search. _last_action_source
            #    signals that a trainer card was recently played.
            if new_discard > old_discard:
                if self._last_action_source:
                    # Trainer card was played recently — use its play position
                    # and stored card info for correct card image in animation
                    discarded = new_discard - old_discard
                    src_x, src_y = self._last_action_source
                    self._last_action_source = None
                    card_name = self._last_action_card_name
                    card_obj = self._last_action_card_obj
                    self._last_action_card_name = None
                    self._last_action_card_obj = None
                    for _ in range(discarded):
                        self._animate_discard(self.my_player_idx, src_x, src_y,
                                             card_name, card_obj)
                elif new_hand < old_hand:
                    # Generic discard from hand (forced discard effects etc.)
                    discarded = min(new_discard - old_discard, old_hand - new_hand)
                    src_x = PLAY_AREA_W // 2
                    src_y = HAND_Y + CARD_HEIGHT // 2
                    for _ in range(discarded):
                        self._animate_discard(self.my_player_idx, src_x, src_y)

            # Sync tracking to new baseline and suppress next frame detection
            self._sync_tracking_counts()
            self._state_sync_just_arrived = True

            # Trigger animations for field changes.
            # Set flag to suppress duplicate particles from the action_result
            # that follows (state_sync always arrives before action_result).
            self._suppress_action_particles = True
            self._detect_field_changes(prev_snap)

        elif msg_type == "action_result":
            # Client mode: receive result of an action the host performed
            msg_pending = msg.get("pending_action")
            if msg_pending:
                from network.state_serializer import deserialize_action_request
                self._resolving_remote_pending = True
                pending = deserialize_action_request(msg_pending)
                self._handle_pending_action(pending)
            else:
                # Determine slot keys based on who performed the action
                msg_attacker = msg.get("attacker_player_idx")
                is_self_action = (msg_attacker is not None and msg_attacker == self.my_player_idx)
                if is_self_action:
                    damage_slot = SLOT_OPP_ACTIVE
                    shake_slot = SLOT_PLAYER_ACTIVE
                    damage_rect = self._opp_active_rect()
                    action_rect = self._player_active_rect()
                else:
                    damage_slot = SLOT_PLAYER_ACTIVE
                    shake_slot = SLOT_OPP_ACTIVE
                    damage_rect = self._player_active_rect()
                    action_rect = self._opp_active_rect()

                if msg.get("damage_dealt", 0) > 0:
                    self.damage_flash.trigger(damage_slot)
                    self.attack_shake.trigger(shake_slot)
                    get_audio().play("attack_hit")
                    if damage_rect:
                        self.particles.spawn_particles(
                            attack_impact(damage_rect.x + damage_rect.w // 2,
                                         damage_rect.y + damage_rect.h // 2))
                if msg.get("pokemon_ko"):
                    self.ko_fade.trigger(damage_slot)
                    get_audio().play("pokemon_ko")
                    if damage_rect:
                        self.particles.spawn_particles(
                            ko_burst(damage_rect.x + damage_rect.w // 2,
                                    damage_rect.y + damage_rect.h // 2))

                # Trigger basic visual feedback based on action type.
                # Skip particle effects if state_sync already triggered them
                # (state_sync always arrives before action_result).
                action_str = msg.get("action", "")
                if not self._suppress_action_particles:
                    if action_str == "EVOLVE":
                        if action_rect:
                            self.particles.spawn_particles(
                                evolution_glow(action_rect.x + action_rect.w // 2,
                                              action_rect.y + action_rect.h // 2))
                        get_audio().play("evolution")
                    elif action_str == "ATTACH_ENERGY":
                        if action_rect:
                            self.particles.spawn_particles(
                                energy_spark(action_rect.x + action_rect.w // 2,
                                            action_rect.y + action_rect.h // 2))
                self._suppress_action_particles = False
            # Draw animations handled by _detect_state_changes
            # Show opponent action description
            action_desc = msg.get("action_desc", "")
            if action_desc:
                self.floating_text.show(action_desc,
                    SCREEN_WIDTH // 2, OPP_ACTIVE_Y + FIELD_ACTIVE_H // 2,
                    color=UI_HIGHLIGHT, duration=1.5)

        elif msg_type == "action":
            # Host mode: receive an action from the remote player
            if not self._is_remote_host or not self.tm:
                return
            self._waiting_remote = False  # Remote player acted; no longer waiting
            action_str = msg.get("action", "")
            params = msg.get("params", {})

            from network.message_protocol import STRING_TO_ACTION
            action = STRING_TO_ACTION.get(action_str, action_str)

            if action == "SETUP_DONE":
                self._remote_setup_done(params.get("player_idx", 1))
                return

            prev_snap = self._snapshot_field_state()
            remote_idx = params.get("player_idx", self.state.active_player_idx)

            # Reject actions from non-active player (defense-in-depth)
            if self.state.phase != TurnPhase.SETUP and remote_idx != self.state.active_player_idx:
                self.state._log(f"忽略非当前回合玩家的操作。")
                return

            if action == PlayerAction.END_TURN:
                result = self.tm.perform_action(
                    PlayerAction.END_TURN,
                    player_idx=remote_idx,
                )
            elif action == PlayerAction.DECLARE_ATTACK:
                attack_idx = params.get("attack_idx", 0)
                result = self.tm.declare_attack(remote_idx, attack_idx)
            elif action == PlayerAction.RETREAT:
                result = self.tm.perform_action(
                    PlayerAction.RETREAT,
                    player_idx=remote_idx,
                    bench_idx=params.get("bench_idx", 0),
                )
            elif action == PlayerAction.PLAY_BASIC:
                result = self.tm.perform_action(
                    PlayerAction.PLAY_BASIC,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    target=params.get("target", "bench_0"),
                )
            elif action == PlayerAction.EVOLVE:
                result = self.tm.perform_action(
                    PlayerAction.EVOLVE,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    slot=params.get("slot", "active"),
                )
            elif action == PlayerAction.ATTACH_ENERGY:
                result = self.tm.perform_action(
                    PlayerAction.ATTACH_ENERGY,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    target_slot=params.get("target_slot", "active"),
                )
            elif action == PlayerAction.PLAY_TRAINER:
                result = self.tm.perform_action(
                    PlayerAction.PLAY_TRAINER,
                    player_idx=remote_idx,
                    hand_idx=params.get("hand_idx", 0),
                    target_slot=params.get("target_slot"),
                )
            elif action == PlayerAction.USE_ABILITY:
                result = self.tm.perform_action(
                    PlayerAction.USE_ABILITY,
                    player_idx=remote_idx,
                    slot=params.get("slot", "active"),
                    ability_name=params.get("ability_name", ""),
                )
            else:
                return

            self._show_result(result, attacker_player_idx=remote_idx, action=action)

            # Track pending trainer card for remote actions (needed for discard/cancel flow)
            if (action == PlayerAction.PLAY_TRAINER and result.success
                    and result.pending_action):
                self._pending_trainer_card = result.pending_action.pending_card
            elif action == PlayerAction.PLAY_TRAINER and not result.pending_action:
                self._pending_trainer_card = None

            if result.success and action == PlayerAction.END_TURN:
                self._handle_turn_end()
            self._clear_selection()
            if result.success:
                self._detect_field_changes(prev_snap)

        elif msg_type == "resolve_pending":
            # Host receives resolution of a pending action from client
            if not self._is_remote_host:
                return
            self._resolve_remote_pending(msg)

        elif msg_type == "game_over":
            self.state.winner = msg.get("winner")
            self.state.phase = TurnPhase.GAME_OVER
            self._show_end_screen(custom_reason=msg.get("reason"))

        elif msg_type == "opponent_disconnected":
            self.state._log("对手断开连接！")
            self._waiting_remote = False
            # Return to title after showing message
            from ui.screens.title_screen import TitleScreen
            self.manager.clear_to(TitleScreen(self.manager))

        elif msg_type == "connection_failed":
            self.state._log(f"连接失败: {msg.get('error', '未知错误')}")
            from ui.screens.title_screen import TitleScreen
            self.manager.clear_to(TitleScreen(self.manager))

    def _remote_setup_done(self, player_idx: int):
        """Handle remote player completing setup."""
        if not self._is_remote_host:
            return
        player = self.state.get_player(player_idx)
        if player.active is None:
            return

        self.setup_pass_done[player_idx] = True
        self.state._log(f"玩家{player_idx + 1}准备好了。")

        if self.setup_pass_done[0] and self.setup_pass_done[1]:
            result = self.tm.setup_finalize()
            if result.success:
                self.state._log(result.log_message)
                self._build_action_buttons()
                self._waiting_remote = (self.state.active_player_idx != self.my_player_idx)
                self._broadcast_state()
        else:
            # Switch to the other player's setup
            other = 1 - player_idx
            self.setup_player_idx = other
            self._clear_selection()
            self._waiting_remote = False  # It's now the host's turn to place
            self._broadcast_state()

    def _resolve_remote_pending(self, msg: dict):
        """Handle a remote client's response to a pending action."""
        if not self._pending_remote_action:
            return
        pending = self._pending_remote_action
        self._pending_remote_action = None

        # Handle cancellation: return pending card to hand
        if msg.get("cancelled"):
            if self._pending_trainer_card:
                player = self.state.get_player(pending.player)
                card = self._pending_trainer_card
                player.hand.append(card)
                if card.is_trainer_supporter:
                    player.supporter_played_this_turn = False
                self._pending_trainer_card = None
                self._animating_action = False
                self._animating_hand_idx = None
                self.state._log("对手取消了操作，卡牌返回手牌。")
            self._broadcast_state()
            return

        callback = pending.callback
        if callback is None:
            return

        if pending.request_type in ("search_deck", "select_hand_to_discard"):
            selected = msg.get("selected_indices", [])
            # Reconstruct card list from stored pending action
            cards = [pending.card_list[i] for i in selected if i < len(pending.card_list)]
            # Convert card ids back to Card objects
            from data.card_registry import CardRegistry
            card_objects = [CardRegistry.get(c) if isinstance(c, str) else c for c in cards]
            result = callback(card_objects)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            selected = msg.get("selected_bench_slot", 0)
            result = callback(selected)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type == "coin_flip":
            results = msg.get("coin_results", [])
            result = callback(results)
            self._handle_remote_resolve_result(result, pending)
        elif pending.request_type == "select_bench_targets":
            selected = msg.get("selected_bench_targets", [])
            result = callback(selected)
            self._handle_remote_resolve_result(result, pending)

        self._broadcast_state()

    def _handle_remote_resolve_result(self, result, pending):
        """Handle a callback result from remote pending resolution.

        The callback may return:
        - None: nothing to do (operation completed successfully)
        - ActionRequest: a chained pending action → send to remote client
        - ActionResult:
            - with pending_action → chain to remote client
            - without → final result, handle locally and broadcast
        """
        if result is None:
            # Operation completed successfully with no chained actions.
            # Discard the pending trainer card now — it was held pending
            # the remote resolution and must be moved to discard here.
            if self._pending_trainer_card:
                player = self.state.get_player(pending.player)
                player.discard.append(self._pending_trainer_card)
                self._pending_trainer_card = None
                self._animating_action = False
                self._animating_hand_idx = None
            return

        from engine.game_state import ActionRequest as AR
        from network.state_serializer import serialize_action_request

        # Determine if we need to send a pending_action to the remote client
        chain_pending = None
        if isinstance(result, AR):
            chain_pending = result
        elif hasattr(result, 'pending_action') and result.pending_action:
            chain_pending = result.pending_action

        if chain_pending:
            # Defer to remote client for resolution
            self._pending_remote_action = chain_pending
            self.network_manager.send({
                "type": "action_result",
                "success": True,
                "log_message": chain_pending.prompt,
                "pending_action": serialize_action_request(chain_pending),
            })
            return

        # Final result (no chained action) — handle locally
        self._show_result(result)

        # Discard pending trainer card on successful resolution
        if self._pending_trainer_card:
            player = self.state.get_player(pending.player)
            player.discard.append(self._pending_trainer_card)
            self._pending_trainer_card = None
            self._animating_action = False
            self._animating_hand_idx = None

    def _select_hand_key(self, hand_idx: int):
        """Select hand card by keyboard number key."""
        player = self._get_display_player()
        if hand_idx < len(player.hand):
            self.selected_hand_idx = hand_idx
            self.floating_text.show(f"选中: {player.hand[hand_idx].name}", 400, SCREEN_HEIGHT - 80)

    def _do_undo(self):
        """Undo the last reversible action (energy attach, bench placement, evolution)."""
        if not self._undo_state:
            self.floating_text.show("没有可撤销的操作", 400, SCREEN_HEIGHT - 80,
                                    color=UI_DANGER)
            return
        undo = self._undo_state
        player = self.state.get_player(undo["player_idx"])
        action = undo["action"]

        if action == "attach_energy":
            target = player.get_pokemon(undo["target_slot"])
            if target and target.energy_cards:
                card = target.energy_cards.pop()
                player.hand.append(card)
            player.energy_attached_this_turn = False
            self.floating_text.show("已撤销: 附着能量", 400, SCREEN_HEIGHT - 80,
                                    color=UI_SUCCESS)
        elif action == "evolve":
            slot = undo.get("slot", "active")
            target = player.active if slot == "active" else player.bench[int(slot.split("_")[1])]
            if target and target.evolution_stack:
                # Return the evolution card to hand first
                player.hand.append(target.card)
                # Pop the previous form from the stack and restore it
                old = target.evolution_stack.pop()
                target.card = old
                target.can_evolve_this_turn = True
            self.floating_text.show("已撤销: 进化", 400, SCREEN_HEIGHT - 80,
                                    color=UI_SUCCESS)
        elif action == "place_bench":
            # Find the last occupied bench slot and remove it
            for i in range(len(player.bench) - 1, -1, -1):
                if player.bench[i] is not None:
                    player.hand.append(player.bench[i].card)
                    player.bench[i] = None
                    break
            self.floating_text.show("已撤销: 放置备战宝可梦", 400, SCREEN_HEIGHT - 80,
                                    color=UI_SUCCESS)
        self._undo_state = None

    def _save_undo(self, action: str, player_idx: int, **kwargs):
        """Save undo state for the last action."""
        self._undo_state = {"action": action, "player_idx": player_idx, **kwargs}

    # ── Animation Triggers ──────────────────────────────────────

    def _get_deck_pos(self, player_idx: int) -> tuple[int, int]:
        """Get the deck zone center for a given player."""
        player = self.state.get_player(player_idx)
        if player is self._get_opponent():
            return (OPP_DECK_ZONE_X + DECK_ZONE_W // 2,
                    OPP_DECK_ZONE_Y + DECK_ZONE_H // 2)
        return (PLAYER_DECK_ZONE_X + DECK_ZONE_W // 2,
                PLAYER_DECK_ZONE_Y + DECK_ZONE_H // 2)

    def _get_discard_pos(self, player_idx: int) -> tuple[int, int]:
        """Get the discard zone center for a given player."""
        player = self.state.get_player(player_idx)
        if player is self._get_opponent():
            return (OPP_DISCARD_ZONE_X + DECK_ZONE_W // 2,
                    OPP_DISCARD_ZONE_Y + DECK_ZONE_H // 2)
        return (PLAYER_DISCARD_ZONE_X + DECK_ZONE_W // 2,
                PLAYER_DISCARD_ZONE_Y + DECK_ZONE_H // 2)

    def _get_card_screen_pos(self, player_idx: int, slot: str) -> tuple[int, int] | None:
        """Get the screen-space center position of a card in a given slot.

        Args:
            player_idx: 0 or 1
            slot: "active", "bench_0" through "bench_4", or "hand_N"

        Returns (center_x, center_y) or None.
        """
        is_opponent_view = (
            player_idx == (1 - self.my_player_idx) if (self._is_remote_host or self._is_remote_client)
            else player_idx != (self.setup_player_idx if self.state.phase == TurnPhase.SETUP else self.state.active_player_idx)
        )
        if slot == "active":
            rect = self._opp_active_rect() if is_opponent_view else self._player_active_rect()
            if rect:
                return (rect.x + rect.w // 2, rect.y + rect.h // 2)
        elif slot.startswith("bench_"):
            idx = int(slot.split("_")[1])
            rect = self._opp_bench_rect(idx) if is_opponent_view else self._player_bench_rect(idx)
            if rect:
                return (rect.x + rect.w // 2, rect.y + rect.h // 2)
        elif slot.startswith("hand_"):
            idx = int(slot.split("_")[1])
            layout = self._get_hand_layout()
            if idx < len(layout):
                x, y, _ = layout[idx]
                return (x + CARD_WIDTH // 2, y + CARD_HEIGHT // 2)
        return None

    def _animate_draw(self, player_idx: int, card_name: str = None, card_obj=None):
        """Animate a card being drawn from deck to hand."""
        # In remote mode, skip draw animation for opponent (hand is hidden)
        if (self._is_remote_client or self._is_remote_host) and player_idx != self.my_player_idx:
            return

        deck_x, deck_y = self._get_deck_pos(player_idx)

        # Compute actual target: where the card will appear in the hand
        player = self.state.get_player(player_idx)
        if not player or not player.hand:
            return

        hand_count = len(player.hand)
        last_idx = hand_count - 1
        self._hidden_hand_idx = last_idx

        layout = self._get_hand_layout()
        if last_idx < len(layout):
            target_x, target_y, _ = layout[last_idx]
            target_x += CARD_WIDTH // 2
            target_y += CARD_HEIGHT // 2
        else:
            target_x = PLAY_AREA_W // 2
            target_y = HAND_Y + CARD_HEIGHT // 2

        w, h = CARD_WIDTH * 3 // 4, CARD_HEIGHT * 3 // 4
        if card_name:
            card_surf = get_card_image_surface(self, card_name, w, h)
        else:
            card_surf = None
        if card_surf is None and self.card_back_img:
            card_surf = pygame.transform.smoothscale(self.card_back_img, (w, h))
        if card_surf is None:
            card_surf = pygame.Surface((w, h), pygame.SRCALPHA)
            card_surf.fill((80, 100, 180, 240))

        def on_complete():
            self._hidden_hand_idx = None
            if get_audio():
                get_audio().play("card_place")

        self.card_fly.fly_from_deck(
            card_surf, deck_x, deck_y, target_x, target_y,
            duration=0.55,
            on_complete=on_complete,
        )
        self.draw_flash.trigger(duration=0.25)

    def _animate_discard(self, player_idx: int, source_x: int, source_y: int,
                         card_name: str = None, card_obj=None,
                         source_slot: str = None, on_complete=None):
        """Animate a card flying from play area to discard pile.

        If source_slot is provided, the actual screen position is used
        instead of source_x/source_y for better accuracy.
        """
        disc_x, disc_y = self._get_discard_pos(player_idx)

        if source_slot:
            pos = self._get_card_screen_pos(player_idx, source_slot)
            if pos:
                source_x, source_y = pos

        # Hide the last card in discard (just discarded) by index until animation complete
        player = self.state.get_player(player_idx)
        if player and player.discard:
            self._hidden_discard_idx = len(player.discard) - 1

        w, h = CARD_WIDTH * 3 // 4, CARD_HEIGHT * 3 // 4
        if card_name:
            card_surf = get_card_image_surface(self, card_name, w, h)
        else:
            card_surf = None
        if card_surf is None:
            card_surf = pygame.Surface((w, h), pygame.SRCALPHA)
            card_surf.fill((120, 90, 160, 240))

        def inner_on_complete():
            self._hidden_discard_idx = None
            if on_complete:
                on_complete()

        self.card_fly.fly_to_discard(
            card_surf, source_x, source_y, disc_x, disc_y,
            duration=0.5, on_complete=inner_on_complete,
        )

    def _animate_mill(self, player_idx: int):
        """Animate a card being milled from deck directly to discard."""
        deck_x, deck_y = self._get_deck_pos(player_idx)
        disc_x, disc_y = self._get_discard_pos(player_idx)

        card_back_small = None
        if self.card_back_img:
            card_back_small = pygame.transform.smoothscale(
                self.card_back_img, (CARD_WIDTH // 2, CARD_HEIGHT // 2))
        if card_back_small is None:
            card_back_small = pygame.Surface((CARD_WIDTH // 2, CARD_HEIGHT // 2), pygame.SRCALPHA)
            card_back_small.fill((40, 60, 140, 200))

        self.card_fly.fly_to_discard(
            card_back_small, deck_x, deck_y, disc_x, disc_y,
            duration=0.3,
        )

    def _build_action_desc(self, result) -> str:
        """Build a human-readable action description for the opponent."""
        if result.damage_dealt > 0:
            return f"对手造成{result.damage_dealt}点伤害！"
        if result.pokemon_ko:
            return "对手击倒了宝可梦！"
        if result.cards_drawn:
            return f"对手抽了{len(result.cards_drawn)}张卡"
        if result.prize_taken:
            return "对手拿取了奖品卡"
        if result.status_applied:
            return f"对手施加了状态:{','.join(result.status_applied)}"
        if result.log_message:
            short = result.log_message[:30]
            return f"对手: {short}"
        return ""

    def _detect_state_changes(self) -> None:
        """Detect discard/mill/draw count changes and trigger animations.

        Handles the combo case (discard-then-draw, e.g. Professor's Research)
        by chaining: discards animate first, draws fire after all discards complete.
        """
        if not self.state:
            return

        # After a state_sync, the changes were already handled in the sync handler.
        # Skip this frame to avoid double-animating from stale tracking counts.
        if self._state_sync_just_arrived:
            self._state_sync_just_arrived = False
            return

        is_remote = self._is_remote_host or self._is_remote_client

        for pi in [0, 1]:
            player = self.state.get_player(pi)
            if player is None:
                continue

            hc = len(player.hand)
            dc = len(player.discard)
            mc = len(player.deck)

            last_hc = self._last_hand_counts.get(pi, hc)
            last_dc = self._last_discard_counts.get(pi, dc)
            last_mc = self._last_deck_counts.get(pi, mc)

            # Detect discard-from-hand: discard increased AND hand decreased.
            # Also detect deferred discard (e.g. Nest Ball search): only discard
            # increased, _last_action_source signals a trainer card was played.
            discarded = 0
            if dc > last_dc and hc < last_hc:
                discarded = min(dc - last_dc, last_hc - hc)
            elif dc > last_dc and self._last_action_source and not is_remote:
                discarded = dc - last_dc

            # Detect draw: hand increased AND deck decreased
            drawn = 0
            if hc > last_hc and mc < last_mc:
                drawn = min(hc - last_hc, last_mc - mc)

            # Detect mill: discard increased AND deck decreased AND no hand decrease
            milled = 0
            if dc > last_dc and mc < last_mc and hc >= last_hc:
                milled = min(dc - last_dc, last_mc - mc)

            # Skip opponent animations in remote mode (hand/field position would be wrong)
            if is_remote and pi != self.my_player_idx:
                drawn = 0
                discarded = 0
                milled = 0

            if discarded and drawn:
                # Combo: discard from hand, then draw (e.g. Professor's Research).
                # Animate discards first, chain draws after.
                src_x = PLAY_AREA_W // 2
                src_y = HAND_Y + CARD_HEIGHT // 2
                if self._last_action_source:
                    src_x, src_y = self._last_action_source
                    self._last_action_source = None

                pending_draws = [drawn]  # mutable container for closure capture
                pending_player = pi

                def make_discard_callback(idx):
                    def cb():
                        # On last discard complete, fire all draws
                        if idx == 0 and pending_draws[0] > 0:
                            for _ in range(pending_draws[0]):
                                p = self.state.get_player(pending_player)
                                card_name = p.hand[-1].name if p and p.hand else None
                                self._animate_draw(pending_player, card_name)
                    return cb

                for i in range(discarded):
                    self._animate_discard(pi, src_x, src_y,
                                         self._last_action_card_name,
                                         self._last_action_card_obj,
                                         on_complete=make_discard_callback(i))
                self._last_action_card_name = None
                self._last_action_card_obj = None
            else:
                if drawn:
                    for _ in range(drawn):
                        card_name = player.hand[-1].name if player.hand else None
                        self._animate_draw(pi, card_name)
                if discarded:
                    src_x = PLAY_AREA_W // 2
                    src_y = HAND_Y + CARD_HEIGHT // 2
                    card_name = None
                    card_obj = None
                    if self._last_action_source:
                        src_x, src_y = self._last_action_source
                        self._last_action_source = None
                        card_name = self._last_action_card_name
                        card_obj = self._last_action_card_obj
                        self._last_action_card_name = None
                        self._last_action_card_obj = None
                    for _ in range(discarded):
                        self._animate_discard(pi, src_x, src_y, card_name, card_obj)
                if milled:
                    for _ in range(milled):
                        self._animate_mill(pi)

            self._last_hand_counts[pi] = hc
            self._last_discard_counts[pi] = dc
            self._last_deck_counts[pi] = mc

    # ── Connection Status ────────────────────────────────────────

    def _draw_connection_status(self, surface):
        """Draw connection status indicator for online play."""
        if not self.network_manager:
            return

        dot_x = SCREEN_WIDTH - LOG_W - 18
        dot_y = DIVIDER_Y + DIVIDER_H // 2

        if not self.network_manager.is_connected:
            color = (220, 60, 60)
            label = "断开"
        elif self.network_manager.is_stale:
            color = (220, 200, 60)
            label = "延迟"
        else:
            color = (80, 220, 80)
            label = "已连接"

        # Small glow behind dot
        glow_surf = pygame.Surface((14, 14), pygame.SRCALPHA)
        pygame.draw.circle(glow_surf, (*color, 30), (7, 7), 6)
        surface.blit(glow_surf, (dot_x - 7, dot_y - 7))
        pygame.draw.circle(surface, color, (dot_x, dot_y), 4)

        label_txt = self.font_card_tiny.render(label, True, color)
        surface.blit(label_txt, (dot_x + 10, dot_y - 6))

    def _draw_quit_buttons(self, surface):
        """Draw the quit-to-menu and concede buttons in the divider bar."""
        # Concede button
        r = self.concede_btn_rect
        bg = (180, 50, 50) if self.hovered_concede_btn else (70, 50, 50)
        pygame.draw.rect(surface, bg, r, border_radius=5)
        pygame.draw.rect(surface, UI_TEXT_PRIMARY, r, 1, border_radius=5)
        txt = self.font_small.render("降", True, UI_TEXT_PRIMARY)
        surface.blit(txt, txt.get_rect(center=r.center))
        if self.hovered_concede_btn:
            tip = self.font_card_tiny.render("认输", True, (255, 80, 80))
            surface.blit(tip, (r.x - tip.get_width() - 4, r.y))

        # Quit button
        r = self.quit_btn_rect
        bg = UI_BUTTON_HOVER if self.hovered_quit_btn else UI_BUTTON
        pygame.draw.rect(surface, bg, r, border_radius=5)
        pygame.draw.rect(surface, UI_TEXT_PRIMARY, r, 1, border_radius=5)
        txt = self.font_small.render("菜", True, UI_TEXT_PRIMARY)
        surface.blit(txt, txt.get_rect(center=r.center))
        if self.hovered_quit_btn:
            tip = self.font_card_tiny.render("返回主菜单 (Q)", True, UI_HIGHLIGHT)
            surface.blit(tip, (r.x - tip.get_width() - 4, r.y))

    def _quit_game(self):
        from ui.screens.title_screen import TitleScreen
        self.manager.clear_to(TitleScreen(self.manager))

    def _confirm_quit_game(self):
        """Show confirmation dialog before quitting to title."""
        def do_quit():
            if self.network_manager:
                self.network_manager.stop()
            self._confirm_dialog = None
            self._quit_game()

        self._confirm_dialog = {
            "title": "退出游戏",
            "message": "确定要退出游戏并返回主菜单吗？\n当前对战进度将丢失。",
            "confirm_label": "退出",
            "cancel_label": "返回",
            "on_confirm": do_quit,
            "on_cancel": lambda: setattr(self, '_confirm_dialog', None),
        }

    def _confirm_concede(self):
        """Show confirmation dialog before conceding."""
        def do_concede():
            self._confirm_dialog = None
            if self._is_remote_host or self._is_remote_client:
                conceder = self.my_player_idx
            elif self.state.phase == TurnPhase.SETUP:
                conceder = self.setup_player_idx
            else:
                conceder = self.state.active_player_idx
            self.state.winner = 1 - conceder

            # Client: notify host before showing end screen locally
            if self._is_remote_client:
                self.network_manager.send({
                    "type": "game_over",
                    "winner": self.state.winner,
                    "reason": "对手认输",
                    "prizes_taken": (
                        6 - len(self.state.p1.prizes),
                        6 - len(self.state.p2.prizes),
                    ),
                })

            self._show_end_screen(custom_reason="对手认输")

        self._confirm_dialog = {
            "title": "认输",
            "message": "确定要认输吗？",
            "confirm_label": "认输",
            "cancel_label": "返回",
            "on_confirm": do_concede,
            "on_cancel": lambda: setattr(self, '_confirm_dialog', None),
        }

    # ═══════════════════════════════════════════════════════════
    #  RENDERING
    # ═══════════════════════════════════════════════════════════

    def draw(self, surface: pygame.Surface) -> None:
        # State sync fade overlay (online client mode)
        if self._state_sync_fade > 0:
            alpha = int(self._state_sync_fade / 0.15 * 80)
            overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
            overlay.fill((0, 0, 0, alpha))
            surface.blit(overlay, (0, 0))

        # Pre-rendered gradient background
        bg = create_board_background()
        surface.blit(bg, (0, 0))

        self._draw_opponent_side(surface)
        self._draw_opponent_deck(surface)
        self._draw_opponent_discard(surface)
        self._draw_player_side(surface)
        self._draw_player_deck(surface)
        self._draw_player_discard(surface)
        self._draw_divider(surface)
        self._draw_connection_status(surface)
        self._draw_quit_buttons(surface)
        self._draw_stadium(surface)
        self._draw_setup_status(surface)
        self._draw_hand(surface, self._get_display_player())
        self._draw_action_buttons(surface)  # on top of hand
        self._draw_action_log(surface)
        self._draw_attack_menu(surface)
        self._draw_ability_menu(surface)
        self._draw_field_tooltips(surface)
        self._draw_magnified_card(surface)

        # Card fly animations (drawn above game elements)
        self.card_fly.draw(surface)

        # Particle effects
        self.particles.draw(surface)

        # Coin flip animation
        self.coin_flip.draw(surface, self.font_info)

        # Waiting indicator (online play)
        if self.waiting_indicator.is_active:
            self.waiting_indicator.draw(
                surface, self.font_small,
                SCREEN_WIDTH // 2, DIVIDER_Y + DIVIDER_H // 2)

        # Confirm dialog overlay
        self._draw_confirm_dialog(surface)

        # Keyboard shortcut hints
        self._draw_shortcut_hints(surface)

        # Floating text overlay (rendered last, on top of everything)
        self.floating_text.draw(surface, self.font_body)

    # ── Opponent Side ───────────────────────────────────────────

    def _draw_opponent_side(self, surface):
        hide_cards = (self.state.phase == TurnPhase.SETUP)
        draw_opponent_side(self, surface, hide_cards=hide_cards)

    def _draw_opponent_deck(self, surface):
        draw_opponent_deck(self, surface)

    def _draw_opponent_discard(self, surface):
        draw_opponent_discard(self, surface)

    # ── Player Side ─────────────────────────────────────────────

    def _draw_player_side(self, surface):
        draw_player_side(self, surface)

    def _draw_player_deck(self, surface):
        draw_player_deck(self, surface)

    def _draw_player_discard(self, surface):
        draw_player_discard(self, surface)

    # ── Divider ─────────────────────────────────────────────────

    def _draw_divider(self, surface):
        draw_divider(self, surface)

    # ── Stadium ─────────────────────────────────────────────────

    def _stadium_is_activatable(self) -> bool:
        """Check if the current stadium has an activatable effect."""
        return stadium_is_activatable(self)

    def _stadium_btn_rect(self) -> pygame.Rect | None:
        """Return the activation button rect on the stadium card, if applicable."""
        return stadium_btn_rect(self)

    def _draw_stadium(self, surface):
        draw_stadium(self, surface)

    # ── Setup Status Overlay ────────────────────────────────────

    def _draw_setup_status(self, surface):
        """Show setup progress (only during SETUP phase)."""
        draw_setup_status(self, surface)

    # ── Helper ────────────────────────────────────────────────────

    def _get_card_image_surface(self, card_name: str, target_w: int, target_h: int):
        """Get scaled card image surface, or None if unavailable."""
        return get_card_image_surface(self, card_name, target_w, target_h)

    # ── Field Pokemon Card (Active, large) ──────────────────────

    def _draw_field_pokemon(self, surface, x, y, pokemon, is_opponent=False, hovered=False):
        """Draw a Pokemon in the battle zone with detailed info."""
        draw_field_pokemon(self, surface, x, y, pokemon, is_opponent, hovered)

    # ── Bench Pokemon Card ──────────────────────────────────────

    def _draw_bench_card(self, surface, x, y, pokemon, hovered=False, selected=False):
        """Draw a compact bench Pokemon card with key info."""
        draw_bench_card(self, surface, x, y, pokemon, hovered, selected)

    # ── Hand Cards ──────────────────────────────────────────────

    def _draw_hand(self, surface, player):
        """Draw hand cards at the bottom of the screen."""
        draw_hand(self, surface, player)

    def _draw_hand_card(self, surface, x, y, card, highlight=False):
        """Draw a single hand card."""
        draw_hand_card(self, surface, x, y, card, highlight)

    # ── Action Buttons ──────────────────────────────────────────

    def _draw_action_buttons(self, surface):
        draw_action_buttons(self, surface)

    # ── Action Log ──────────────────────────────────────────────

    def _draw_action_log(self, surface):
        draw_action_log(self, surface)

    # ── Attack Menu ─────────────────────────────────────────────

    def _draw_attack_menu(self, surface):
        """Draw attack selection overlay with effect descriptions."""
        draw_attack_menu(self, surface)

    # ── Ability Menu ─────────────────────────────────────────

    def _draw_ability_menu(self, surface):
        """Draw ability selection overlay when Pokemon has multiple abilities."""
        draw_ability_menu(self, surface)

    # ── Field Tooltips ──────────────────────────────────────────

    def _draw_field_tooltips(self, surface):
        """Show detailed tooltips when hovering over field Pokemon or hand cards."""
        draw_field_tooltips(self, surface)

    # ── Magnified Card Preview ──────────────────────────────────

    MAGNIFY_H = 340
    MAGNIFY_X = 10
    MAGNIFY_Y = 26

    def _get_hovered_card_with_image(self):
        """Return the Card object if a card with a real image is being hovered, else None."""
        return get_hovered_card_with_image(self)

    def _draw_magnified_card(self, surface):
        """Show magnified card image in top-left when hovering a card with a real image."""
        draw_magnified_card(self, surface)

    def _pokemon_extra_info(self, pokemon) -> list[str]:
        """Build extra info lines for a Pokemon in play."""
        return pokemon_extra_info(self, pokemon)

    def _draw_tooltip_box(self, surface, card, tx, ty, extra_info=None):
        """Draw a detailed card tooltip at the given position."""
        draw_tooltip_box(self, surface, card, tx, ty, extra_info)

    # ── Legacy: original tooltip (hand) — kept for compatibility ──

    def _draw_card_tooltip(self, surface):
        """Deprecated: tooltips are now handled by _draw_field_tooltips."""
        draw_card_tooltip(self, surface)

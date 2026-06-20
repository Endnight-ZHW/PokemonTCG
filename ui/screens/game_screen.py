"""Main game screen - board display and player interaction."""
from concurrent.futures import Future

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
from ui.layout_model import GameBoardLayout
from config import (
    SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT,
    STATUS_SHORT_CN, PHASE_CN as _PHASE_CN_STR, ENERGY_NAME_CN as ENERGY_CN,
    GAME_SPEED, GAME_SPEED_OPTIONS,
)
from engine.enums import TurnPhase, PlayerAction, StatusType
from engine.actions import GameAction
from engine.ai import ChallengeAI, DeepLearningAIConfig, create_ai_controller
from engine.game_state import GameState, ActionRequest, ActionResult
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.turn_manager import TurnManager
from engine.rules_validator import (
    can_declare_attack,
    can_play_item,
    can_play_stadium,
    can_play_supporter,
    can_use_ability,
)
# Component imports
from ui.components.game_layout import *
from ui.components.action_menu import build_action_buttons
from ui.screens.game_screen_ai import GameScreenAIMixin
from ui.screens.game_screen_animation import GameScreenAnimationMixin
from ui.screens.game_screen_layout import GameScreenLayoutMixin
from ui.screens.game_screen_network import GameScreenNetworkMixin
from ui.screens.game_screen_rendering import GameScreenRenderingMixin
from ui.ui_theme import draw_text_fit

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


class GameScreen(
    GameScreenAIMixin,
    GameScreenAnimationMixin,
    GameScreenLayoutMixin,
    GameScreenNetworkMixin,
    GameScreenRenderingMixin,
    Screen,
):
    """Main game board screen."""

    def __init__(self, manager: ScreenManager, game_state: GameState | None,
                 turn_manager: TurnManager | None,
                 network_manager=None, my_player_idx: int | None = None,
                 initial_state: GameState | None = None,
                 challenge_mode: bool = False,
                 human_player_idx: int = 0,
                 ai_player_idx: int = 1,
                 ai_deck_key: str | None = None,
                 ai_kind: str = "challenge",
                 ai_search_algorithm: str = "hybrid",
                 ai_controller: ChallengeAI | None = None):
        super().__init__(manager)
        self.state = game_state if game_state is not None else initial_state
        self.tm = turn_manager
        self.network_manager = network_manager
        self.my_player_idx = my_player_idx
        self.challenge_mode = challenge_mode
        self.game_engine = DEFAULT_GAME_ENGINE
        self.human_player_idx = human_player_idx
        self.ai_player_idx = ai_player_idx
        self.ai_kind = ai_kind
        self.ai_search_algorithm = ai_search_algorithm
        if ai_controller is not None:
            self.ai_controller = ai_controller
        elif challenge_mode:
            from engine.ai.challenge_ai import AIConfig
            fallback_config = AIConfig(
                deck_key=ai_deck_key or "",
                search_algorithm=ai_search_algorithm,
                use_unified_planner=True,
            )
            config = (
                DeepLearningAIConfig(fallback_config=fallback_config)
                if ai_kind == "deep_learning"
                else fallback_config
            )
            self.ai_controller = create_ai_controller(ai_kind, ai_deck_key, config)
        else:
            self.ai_controller = None
        self._ai_action_delay = 0.25
        self._ai_thinking_timer = 0.0
        self._ai_pending_action: ActionRequest | None = None
        self._ai_failed_actions: set[tuple] = set()
        self._ai_executor = None
        self._ai_action_future: Future | None = None
        self._ai_action_job_key: tuple | None = None
        self._ai_shutdown = False
        self.setup_player_idx: int = 0
        self.setup_pass_done: dict[int, bool] = {0: False, 1: False}
        self._is_remote_host = network_manager is not None and turn_manager is not None
        self._is_remote_client = network_manager is not None and turn_manager is None
        self._waiting_remote: bool = False  # Host waiting for remote player action
        self._pending_remote_action = None  # ActionRequest pending from remote player (for resolution)
        self._pending_bench_select_client: bool = False
        self._bench_target_handler_is_client: bool = False
        self._remote_update_just_arrived: bool = False  # Suppress _detect_state_changes for 1 frame
        self._suppress_action_particles: bool = False  # Suppress duplicate particles from result payloads
        self._suppress_result_draw_anim: bool = False
        self._resolving_remote_pending: bool = False  # Client resolving a remote pending action
        self._last_state_update_seq: int = 0
        self._remote_request_counter: int = 0

        self.font_info = get_font("info")
        self.font_body = get_font("small")
        self.font_small = get_font("caption")
        self.font_card_name = get_font_size(15, bold=True)
        self.font_card_body = get_font("card_body")
        self.font_card_tiny = get_font("card_tiny")
        self.font_action = get_font_size(16, bold=True)

        self.selected_hand_idx: int | None = None
        self.selected_action = None
        self.layout = GameBoardLayout.build(SCREEN_WIDTH, SCREEN_HEIGHT)
        self.action_buttons: list[dict] = []
        self.phase_buttons: list[dict] = self.action_buttons
        self.card_action_menu: list[dict] = []
        self.card_action_menu_rects: list[pygame.Rect] = []
        self.card_action_menu_anchor: pygame.Rect | None = None
        self.hovered_card_action: int | None = None
        self._build_action_buttons()

        self.hovered_button: int | None = None
        self.hovered_hand: int | None = None
        self.hovered_bench: int | None = None

        # Deck/discard zone hover state
        self.hovered_opp_deck = False
        self.hovered_opp_discard_zone = False
        self.hovered_player_deck = False
        self.hovered_player_discard_zone = False
        self.hovered_stadium_card = False
        self.hovered_stadium_btn = False
        self.hovered_quit_btn = False
        self.hovered_concede_btn = False

        # Discard view buttons (deprecated — clicking discard zone now opens view)
        self.opp_discard_btn_rect: pygame.Rect | None = None
        self.player_discard_btn_rect: pygame.Rect | None = None
        self.hovered_opp_discard = False
        self.hovered_player_discard = False

        self.hovered_active: bool = False
        self.hovered_opp_bench: int | None = None
        self.hovered_opp_active: bool = False
        self.hovered_stadium_card: bool = False
        self.hovered_stadium_btn: bool = False
        self.hovered_quit_btn: bool = False
        self.hovered_concede_btn: bool = False

        # Quit and concede buttons in the divider bar area
        self.concede_btn_rect = self.layout.concede_button.copy()
        self.quit_btn_rect = self.layout.quit_button.copy()

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
        self._last_field_state: dict = {}  # For detecting field changes across remote state updates
        self._remote_update_fade: float = 0.0

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
        self._has_attacked: bool = False  # prevent double-attack in ATTACK phase
        # Animation action deferral (play animation before game logic)
        self._animating_action: bool = False
        self._animating_hand_idx: int | None = None
        self._animating_hand_idx_player: int | None = None
        self._last_action_source: tuple[float, float] | None = None  # For discard animation direction
        self._last_action_player_idx: int | None = None
        self._pending_trainer_card = None  # Trainer card awaiting pending action resolution
        self._last_action_card_name: str | None = None  # Card name for deferred discard animation
        self._last_action_card_obj = None  # Card object for deferred discard animation

        # Cards temporarily hidden from rendering during animations (index-based)
        self._hidden_hand_idx: int | None = None  # Hand index hidden during draw anim
        self._hidden_discard_idx: int | None = None  # Discard index hidden during discard anim
        self._hidden_hand_idx_player: int | None = None
        self._hidden_discard_idx_player: int | None = None
        self._hidden_hand_indices: set[int] = set()
        self._hidden_discard_indices: set[int] = set()
        self._hidden_hand_indices_by_player: dict[int, set[int]] = {0: set(), 1: set()}
        self._hidden_discard_indices_by_player: dict[int, set[int]] = {0: set(), 1: set()}

        # Shortcuts and speed
        self._show_shortcuts: bool = True  # auto-show first few turns
        self._speed_idx: int = 1  # index into GAME_SPEED_OPTIONS (1 = 1.0x)
        self._speed_value: float = GAME_SPEED_OPTIONS[1]

    def _build_action_buttons(self):
        """Build action buttons in 2 rows below player info."""
        build_action_buttons(self)
        self.phase_buttons = self.action_buttons

    def _set_last_action_context(self, player_idx: int, source: tuple[float, float],
                                 card_name: str | None = None, card_obj=None) -> None:
        self._last_action_source = source
        self._last_action_player_idx = player_idx
        self._last_action_card_name = card_name
        self._last_action_card_obj = card_obj

    def _clear_last_action_context(self) -> None:
        self._last_action_source = None
        self._last_action_player_idx = None
        self._last_action_card_name = None
        self._last_action_card_obj = None

    def _last_action_source_for(self, player_idx: int) -> tuple[float, float] | None:
        if self._last_action_player_idx == player_idx:
            return self._last_action_source
        return None

    def _should_animate_hand_for_player(self, player_idx: int) -> bool:
        if self.challenge_mode and player_idx == self.ai_player_idx:
            return False
        if (self._is_remote_client or self._is_remote_host) and player_idx != self.my_player_idx:
            return False
        return True

    def _hidden_hand_indices_for(self, player_idx: int) -> set[int]:
        return self._hidden_hand_indices_by_player.setdefault(player_idx, set())

    def _hidden_discard_indices_for(self, player_idx: int) -> set[int]:
        return self._hidden_discard_indices_by_player.setdefault(player_idx, set())

    def _hide_hand_index(self, player_idx: int, hand_idx: int) -> None:
        self._hidden_hand_idx = None
        self._hidden_hand_idx_player = None
        self._hidden_hand_indices_for(player_idx).add(hand_idx)

    def _unhide_hand_index(self, player_idx: int, hand_idx: int) -> None:
        self._hidden_hand_indices_for(player_idx).discard(hand_idx)

    def _hide_discard_index(self, player_idx: int, discard_idx: int) -> None:
        self._hidden_discard_idx = None
        self._hidden_discard_idx_player = None
        self._hidden_discard_indices_for(player_idx).add(discard_idx)

    def _unhide_discard_index(self, player_idx: int, discard_idx: int) -> None:
        self._hidden_discard_indices_for(player_idx).discard(discard_idx)

    def _refresh_interaction_controls(self):
        """Recompute cached controls after state changes outside normal actions."""
        self._build_action_buttons()
        self.hovered_button = None
        self.hovered_card_action = None

    def on_enter(self):
        self._ensure_ai_executor()
        self._build_action_buttons()
        self._has_attacked = False
        # Initialize state tracking counts for animation detection
        self._sync_tracking_counts()
        self._setup_shuffle_callbacks()
        if self.state.phase == TurnPhase.SETUP and not self._setup_initialized:
            if not self._is_remote_client:
                self._init_setup()

    def on_exit(self):
        # ScreenManager calls on_exit both when this screen is covered and when
        # it is removed.  Keep the AI worker alive for temporary overlays.
        if self.manager.top is self:
            return
        self._shutdown_ai_executor()

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
            if self.challenge_mode:
                is_self = (pi == self.human_player_idx)
            else:
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

        if self._should_block_challenge_input():
            if event.type == pygame.MOUSEWHEEL:
                mx, _ = pygame.mouse.get_pos()
                log_x = SCREEN_WIDTH - LOG_W - 8
                if log_x <= mx <= log_x + LOG_W:
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
                if self.state.phase == TurnPhase.MAIN and self.selected_action is None:
                    self._execute_action("ENTER_ATTACK", player_idx)
                elif self.state.phase == TurnPhase.ATTACK and not self._has_attacked:
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

    # ---- Context card action menu ----

    def _close_card_action_menu(self):
        self.card_action_menu = []
        self.card_action_menu_rects = []
        self.card_action_menu_anchor = None
        self.hovered_card_action = None

    def _open_card_action_menu(self, anchor: pygame.Rect, items: list[dict]):
        self.card_action_menu = items
        self.card_action_menu_anchor = anchor.copy()
        self.hovered_card_action = None
        self.card_action_menu_rects = []
        if not items:
            return

        width = 156
        item_h = 30
        gap = 4
        total_h = len(items) * item_h + (len(items) - 1) * gap + 12
        x = anchor.right + 10
        if x + width > SCREEN_WIDTH - 12:
            x = anchor.left - width - 10
        x = max(12, min(x, SCREEN_WIDTH - width - 12))
        y = max(12, min(anchor.y, SCREEN_HEIGHT - total_h - 12))
        for idx in range(len(items)):
            rect = pygame.Rect(x + 6, y + 6 + idx * (item_h + gap),
                               width - 12, item_h)
            self.card_action_menu_rects.append(rect)

    def _pokemon_attached_cards(self, pokemon) -> dict[str, list]:
        """Return public cards placed under or attached to a Pokemon in play."""
        if not pokemon:
            return {"退化卡": [], "能量卡": [], "道具卡": []}
        tool_cards = [pokemon.attached_tool] if pokemon.attached_tool else []
        return {
            "退化卡": list(getattr(pokemon, "evolution_stack", [])),
            "能量卡": list(getattr(pokemon, "energy_cards", [])),
            "道具卡": tool_cards,
        }

    def _show_attached_cards_view(self, owner_label: str, slot_label: str, pokemon):
        """Open the read-only attached-card viewer for a field Pokemon."""
        if not pokemon:
            return
        from ui.screens.attached_cards_screen import AttachedCardsScreen

        sections = list(self._pokemon_attached_cards(pokemon).items())
        title = f"{owner_label} {slot_label} 附属卡"
        pokemon_name = getattr(getattr(pokemon, "card", None), "name", "")
        screen = AttachedCardsScreen(self.manager, title, pokemon_name, sections)
        self.manager.push_screen(screen)

    def _attached_cards_menu_item(self, owner_label: str, slot_label: str, pokemon) -> dict:
        return {
            "label": "查看附属卡",
            "action": "view_attached_cards",
            "enabled": True,
            "reason": "",
            "params": {
                "owner_label": owner_label,
                "slot_label": slot_label,
                "pokemon": pokemon,
            },
        }

    def _manual_ability_slot_available(self, player_idx: int, slot: str) -> bool:
        player = self.state.get_player(player_idx)
        pokemon = player.get_pokemon(slot)
        return bool(pokemon and self._has_manual_ability(pokemon))

    def _valid_evolution_slots(self, player_idx: int, card) -> list[str]:
        return [
            action.params["slot"]
            for action in self.game_engine.legal_actions(self.state, player_idx, validate_effects=False)
            if action.action == PlayerAction.EVOLVE
            and action.source is not None
            and getattr(action.source, "card_id", "") == card.api_id
        ]

    def _valid_energy_slots(self, player_idx: int, card) -> list[str]:
        return [
            action.params["target_slot"]
            for action in self.game_engine.legal_actions(self.state, player_idx, validate_effects=False)
            if action.action == PlayerAction.ATTACH_ENERGY
            and action.source is not None
            and getattr(action.source, "card_id", "") == card.api_id
        ]

    def _valid_tool_slots(self, player_idx: int, card) -> list[str]:
        return [
            action.params["target_slot"]
            for action in self.game_engine.legal_actions(self.state, player_idx, validate_effects=False)
            if action.action == PlayerAction.PLAY_TRAINER
            and action.source is not None
            and getattr(action.source, "card_id", "") == card.api_id
            and "target_slot" in action.params
        ]

    def _valid_retreat_targets(self, player_idx: int) -> list[int]:
        return sorted({
            int(action.params["bench_idx"])
            for action in self.game_engine.legal_actions(self.state, player_idx, validate_effects=False)
            if action.action == PlayerAction.RETREAT
        })

    def _has_attack_option(self, player_idx: int) -> tuple[bool, str]:
        player = self.state.get_player(player_idx)
        if not player.active:
            return False, "没有战斗宝可梦"
        if any(
            action.action == PlayerAction.DECLARE_ATTACK
            for action in self.game_engine.legal_actions(
                self.state,
                player_idx,
                validate_effects=False,
            )
        ):
            return True, ""
        reasons = []
        for idx, _ in enumerate(player.active.card.attacks):
            ok, reason = can_declare_attack(self.state, player_idx, idx)
            if not ok and reason:
                reasons.append(reason)
        return False, reasons[0] if reasons else "没有可用招式"

    def _show_hand_card_actions(self, player_idx: int, hand_idx: int):
        player = self.state.get_player(player_idx)
        if not (0 <= hand_idx < len(player.hand)):
            return
        card = player.hand[hand_idx]
        layout = self._get_hand_layout()
        anchor = layout[hand_idx][2] if hand_idx < len(layout) else self.layout.hand
        items: list[dict] = []

        if self.state.phase == TurnPhase.SETUP:
            if card.is_basic_pokemon:
                items.append({
                    "label": "放到战斗区",
                    "action": "setup_place_active",
                    "enabled": player.active is None,
                    "reason": "战斗区已有宝可梦",
                    "params": {"hand_idx": hand_idx},
                })
                items.append({
                    "label": "放到备战区",
                    "action": "setup_select_bench",
                    "enabled": player.active is not None and player.bench_has_space(),
                    "reason": "请先设置战斗宝可梦" if player.active is None else "备战区已满",
                    "params": {"hand_idx": hand_idx},
                })
            else:
                items.append({
                    "label": "准备阶段只能放基础",
                    "action": "noop",
                    "enabled": False,
                    "reason": "准备阶段只能设置基础宝可梦",
                    "params": {},
                })
            self._open_card_action_menu(anchor, items)
            return

        if self.state.phase != TurnPhase.MAIN:
            return

        if card.is_basic_pokemon:
            items.append({
                "label": "放到备战区",
                "action": "play_basic_select_bench",
                "enabled": player.bench_has_space(),
                "reason": "备战区已满",
                "params": {"hand_idx": hand_idx},
            })
        elif card.is_stage1 or card.is_stage2:
            slots = self._valid_evolution_slots(player_idx, card)
            items.append({
                "label": "进化",
                "action": "evolve_select",
                "enabled": bool(slots),
                "reason": "没有可进化目标",
                "params": {"hand_idx": hand_idx},
            })
        elif card.is_energy:
            slots = self._valid_energy_slots(player_idx, card)
            items.append({
                "label": "附加能量",
                "action": "attach_energy_select",
                "enabled": bool(slots),
                "reason": "本回合已附能或没有目标",
                "params": {"hand_idx": hand_idx},
            })
        elif card.is_trainer:
            if card.is_trainer_tool:
                slots = self._valid_tool_slots(player_idx, card)
                items.append({
                    "label": "附加道具",
                    "action": "tool_select",
                    "enabled": bool(slots),
                    "reason": "没有可附加道具的目标",
                    "params": {"hand_idx": hand_idx},
                })
            elif card.is_trainer_supporter:
                ok, reason = can_play_supporter(self.state, player_idx)
                items.append({
                    "label": "使用支援者",
                    "action": "play_trainer",
                    "enabled": ok,
                    "reason": reason,
                    "params": {"hand_idx": hand_idx},
                })
            elif card.is_trainer_stadium:
                ok, reason = can_play_stadium(self.state, player_idx, card)
                items.append({
                    "label": "打出竞技场",
                    "action": "play_trainer",
                    "enabled": ok,
                    "reason": reason,
                    "params": {"hand_idx": hand_idx},
                })
            else:
                ok, reason = can_play_item(self.state, player_idx)
                items.append({
                    "label": "使用物品",
                    "action": "play_trainer",
                    "enabled": ok,
                    "reason": reason,
                    "params": {"hand_idx": hand_idx},
                })

        self._open_card_action_menu(anchor, items)

    def _show_active_card_actions(self, player_idx: int):
        player = self.state.get_player(player_idx)
        pokemon = player.active
        if not pokemon:
            return

        if self.state.phase == TurnPhase.MAIN:
            anchor = self._player_active_rect()
            retreat_targets = self._valid_retreat_targets(player_idx)
            items = [
                {
                    "label": "撤退",
                    "action": "retreat_select",
                    "enabled": bool(retreat_targets),
                    "reason": "无法撤退或没有备战宝可梦",
                    "params": {},
                },
            ]
            if self._manual_ability_slot_available(player_idx, "active"):
                items.append({
                    "label": "使用特性",
                    "action": "use_ability",
                    "enabled": True,
                    "reason": "",
                    "params": {"slot": "active"},
                })
            items.append(self._attached_cards_menu_item("我方", "战斗区", pokemon))
            if items:
                self._open_card_action_menu(anchor, items)
        elif self.state.phase == TurnPhase.ATTACK:
            if self._has_attacked:
                anchor = self._player_active_rect()
                items = [self._attached_cards_menu_item("我方", "战斗区", pokemon)]
                self._open_card_action_menu(anchor, items)
                return
            can_attack, attack_reason = self._has_attack_option(player_idx)
            if not can_attack:
                anchor = self._player_active_rect()
                items = [self._attached_cards_menu_item("我方", "战斗区", pokemon)]
                self._open_card_action_menu(anchor, items)
                return
            anchor = self._player_active_rect()
            items = [
                {
                    "label": "攻击",
                    "action": "attack",
                    "enabled": can_attack,
                    "reason": attack_reason,
                    "params": {},
                },
            ]
            items.append(self._attached_cards_menu_item("我方", "战斗区", pokemon))
            self._open_card_action_menu(anchor, items)
        else:
            items = [self._attached_cards_menu_item("我方", "战斗区", pokemon)]
            self._open_card_action_menu(self._player_active_rect(), items)

    def _show_bench_card_actions(self, player_idx: int, bench_idx: int):
        if not (0 <= bench_idx < 5):
            return
        player = self.state.get_player(player_idx)
        pokemon = player.bench[bench_idx]
        if pokemon is None:
            return
        slot = f"bench_{bench_idx}"
        items = []
        if self.state.phase == TurnPhase.MAIN and self._manual_ability_slot_available(player_idx, slot):
            items.append({
                "label": "使用特性",
                "action": "use_ability",
                "enabled": True,
                "reason": "",
                "params": {"slot": slot},
            })
        items.append(self._attached_cards_menu_item("我方", f"备战区 {bench_idx + 1}", pokemon))
        self._open_card_action_menu(self._player_bench_rect(bench_idx), items)

    def _show_opponent_field_card_actions(self, is_active: bool, bench_idx: int | None = None):
        opponent = self._get_opponent()
        if is_active:
            pokemon = opponent.active
            anchor = self._opp_active_rect()
            slot_label = "战斗区"
        else:
            if bench_idx is None or not (0 <= bench_idx < len(opponent.bench)):
                return
            pokemon = opponent.bench[bench_idx]
            anchor = self._opp_bench_rect(bench_idx)
            slot_label = f"备战区 {bench_idx + 1}"
        if not pokemon or anchor is None:
            return
        items = [self._attached_cards_menu_item("对手", slot_label, pokemon)]
        self._open_card_action_menu(anchor, items)

    def _show_stadium_card_actions(self, player_idx: int):
        if self.state.phase != TurnPhase.MAIN or not self.state.stadium_card:
            return
        player = self.state.get_player(player_idx)
        items = [{
            "label": "发动竞技场",
            "action": "use_stadium",
            "enabled": self._stadium_is_activatable()
            and not player.stadium_used_this_turn,
            "reason": "本回合已发动或该竞技场无需手动发动",
            "params": {},
        }]
        self._open_card_action_menu(self.layout.stadium, items)

    def _execute_card_action_item(self, item: dict, player_idx: int) -> bool:
        if not item.get("enabled", True):
            reason = item.get("reason") or "当前不能执行"
            anchor = self.card_action_menu_anchor or self.layout.action_panel
            self.floating_text.show(reason, anchor.centerx, anchor.y,
                                    color=UI_TEXT_SECONDARY, duration=1.1)
            return True

        action = item.get("action")
        params = item.get("params", {})
        hand_idx = params.get("hand_idx")
        if hand_idx is not None:
            self.selected_hand_idx = hand_idx

        self._close_card_action_menu()

        if action == "view_attached_cards":
            self._show_attached_cards_view(
                params.get("owner_label", ""),
                params.get("slot_label", ""),
                params.get("pokemon"),
            )
        elif action == "setup_place_active":
            self.selected_action = "PLACE_ACTIVE"
            self._setup_place(player_idx, "active")
        elif action == "setup_select_bench":
            self.selected_action = "PLACE_BENCH"
            self.state._log("请选择一个备战区位置。")
        elif action == "play_basic_active":
            self.selected_action = PlayerAction.PLAY_BASIC
            self._place_basic(player_idx, target="active")
        elif action == "play_basic_select_bench":
            self.selected_action = PlayerAction.PLAY_BASIC
            self.state._log("请选择一个备战区位置。")
        elif action == "evolve_select":
            self.selected_action = PlayerAction.EVOLVE
            self.state._log("请选择要进化的宝可梦。")
        elif action == "attach_energy_select":
            self.selected_action = PlayerAction.ATTACH_ENERGY
            self.state._log("请选择要附加能量的宝可梦。")
        elif action == "tool_select":
            player = self.state.get_player(player_idx)
            card = player.hand[hand_idx] if hand_idx is not None and hand_idx < len(player.hand) else None
            self.selected_action = PlayerAction.PLAY_TRAINER
            self._pending_tool_card = (player_idx, hand_idx, card)
            self.state._log("请选择要附加道具的宝可梦。")
        elif action == "play_trainer":
            self.selected_action = PlayerAction.PLAY_TRAINER
            self._play_trainer(player_idx)
        elif action == "attack":
            self.selected_action = PlayerAction.DECLARE_ATTACK
            self._show_attack_menu(player_idx)
        elif action == "retreat_select":
            self.selected_action = PlayerAction.RETREAT
            self.state._log("请选择要交换到战斗区的备战宝可梦。")
        elif action == "use_ability":
            self.selected_action = PlayerAction.USE_ABILITY
            self._try_use_ability(player_idx, params.get("slot", "active"))
        elif action == "use_stadium":
            self._execute_action(PlayerAction.USE_STADIUM, player_idx)
        return True

    def _handle_card_action_menu_click(self, pos, player_idx) -> bool:
        if not self.card_action_menu:
            return False
        for idx, rect in enumerate(self.card_action_menu_rects):
            if rect.collidepoint(pos):
                return self._execute_card_action_item(
                    self.card_action_menu[idx], player_idx
                )
        self._close_card_action_menu()
        return False

    def _draw_card_action_menu(self, surface):
        if not self.card_action_menu or not self.card_action_menu_rects:
            return
        outer = self.card_action_menu_rects[0].unionall(self.card_action_menu_rects)
        outer.inflate_ip(12, 12)
        shadow = pygame.Surface((outer.w + 8, outer.h + 8), pygame.SRCALPHA)
        pygame.draw.rect(shadow, (0, 0, 0, 90), shadow.get_rect(),
                         border_radius=8)
        surface.blit(shadow, (outer.x - 2, outer.y + 3))
        pygame.draw.rect(surface, UI_BG_DARK, outer, border_radius=8)
        pygame.draw.rect(surface, UI_BORDER, outer, 1, border_radius=8)

        for idx, (item, rect) in enumerate(zip(self.card_action_menu,
                                              self.card_action_menu_rects)):
            enabled = item.get("enabled", True)
            hovered = idx == self.hovered_card_action
            if not enabled:
                bg = UI_BUTTON_DISABLED
                text_color = UI_TEXT_SECONDARY
            elif hovered:
                bg = UI_BUTTON_HOVER
                text_color = UI_TEXT_PRIMARY
            else:
                bg = UI_BUTTON
                text_color = UI_TEXT_PRIMARY
            pygame.draw.rect(surface, bg, rect, border_radius=6)
            pygame.draw.rect(surface, UI_HIGHLIGHT if hovered else UI_BORDER,
                             rect, 1, border_radius=6)
            draw_text_fit(surface, self.font_action, item.get("label", ""),
                          text_color, rect.inflate(-10, 0))

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
        self.hovered_stadium_card = False
        self.hovered_stadium_btn = False
        self.hovered_card_action = None

        for i, rect in enumerate(self.card_action_menu_rects):
            if rect.collidepoint(pos):
                self.hovered_card_action = i
                return

        for i, item in enumerate(self.action_buttons):
            rect = item["rect"]
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
        opp_deck_rect = self.layout.opponent_deck
        if opp_deck_rect.collidepoint(pos):
            self.hovered_opp_deck = True
            return

        opp_disc_rect = self.layout.opponent_discard
        if opp_disc_rect.collidepoint(pos):
            self.hovered_opp_discard_zone = True
            return

        player_deck_rect = self.layout.player_deck
        if player_deck_rect.collidepoint(pos):
            self.hovered_player_deck = True
            return

        player_disc_rect = self.layout.player_discard
        if player_disc_rect.collidepoint(pos):
            self.hovered_player_discard_zone = True
            return

        # Stadium button (if activatable)
        if self._stadium_is_activatable():
            btn = self._stadium_btn_rect()
            if btn and btn.collidepoint(pos):
                self.hovered_stadium_btn = True
                return

        if self.state.stadium_card and self.layout.stadium.collidepoint(pos):
            self.hovered_stadium_card = True
            return

        # Quit and concede buttons
        self.hovered_quit_btn = self.quit_btn_rect.collidepoint(pos)
        self.hovered_concede_btn = self.concede_btn_rect.collidepoint(pos)

    # ── Click handling ──────────────────────────────────────────

    def _handle_click(self, pos, player_idx):
        self._update_hover(pos, player_idx)
        # Bench target selection mode (for bench-damage attacks etc.)
        if self._selecting_bench_targets is not None:
            req = self._selecting_bench_targets
            is_opponent = req.target_player == "opponent"
            hovered = self.hovered_opp_bench if is_opponent else self.hovered_bench
            if hovered is not None and hovered in req.bench_indices:
                if req.allow_duplicates or hovered not in self._selected_bench_targets:
                    self._selected_bench_targets.append(hovered)
                if len(self._selected_bench_targets) >= req.max_select:
                    selected_targets = list(self._selected_bench_targets)
                    self._selecting_bench_targets = None
                    self._selected_bench_targets = []
                    if self._bench_target_handler_is_client:
                        self._resolving_remote_pending = False
                        self._send_choice_response({
                            "request_id": getattr(req, "request_id", ""),
                            "selected_bench_targets": selected_targets,
                        })
                        self._bench_target_handler_is_client = False
                    else:
                        self._dispatch_choice_result(
                            self._resolve_structured_pending(req, selected_targets)
                        )
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

        if self.card_action_menu:
            if self._handle_card_action_menu_click(pos, player_idx):
                return

        if self.hovered_button is not None:
            item = self.action_buttons[self.hovered_button]
            action = item["action"]
            if not item.get("enabled", True):
                reason = item.get("reason") or "当前不能执行该操作。"
                self.floating_text.show(reason, self.layout.action_panel.centerx,
                                        self.layout.action_panel.bottom - 26,
                                        color=UI_TEXT_SECONDARY, duration=1.0)
                return
            self.selected_action = action
            self._execute_action(action, player_idx)
            return

        if self.selected_action is None and self.hovered_opp_bench is not None:
            self._show_opponent_field_card_actions(False, self.hovered_opp_bench)
            return
        if self.selected_action is None and self.hovered_opp_active:
            self._show_opponent_field_card_actions(True)
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
        if self.hovered_stadium_card:
            self._show_stadium_card_actions(player_idx)
            return

        if self.hovered_quit_btn:
            self._confirm_quit_game()
            return
        if self.hovered_concede_btn:
            self._confirm_concede()
            return

        if self.hovered_hand is not None:
            self.selected_hand_idx = self.hovered_hand
            self._show_hand_card_actions(player_idx, self.hovered_hand)
            return

        if self.hovered_bench is not None:
            if self.selected_action is not None:
                self._handle_bench_click(player_idx, self.hovered_bench)
            else:
                self._show_bench_card_actions(player_idx, self.hovered_bench)
            return

        if self.hovered_active:
            if self.selected_action is not None:
                self._handle_active_click(player_idx)
            else:
                self._show_active_card_actions(player_idx)

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
            elif isinstance(zone, str) and zone.startswith("bench_"):
                bench_idx = int(zone.split("_")[1])
                if player.bench[bench_idx] is not None:
                    self.state._log("该备战区已有宝可梦。")
                    self._clear_selection()
                    return
                target = zone
            else:
                empty = player.find_empty_bench_slot()
                if empty is None:
                    self.state._log("备战区已满（最多5只）。")
                    self._clear_selection()
                    return
                target = f"bench_{empty}"

            # Send to host immediately, play fly animation in parallel
            self._send_client_action("PLAY_BASIC", {
                "hand_idx": self.selected_hand_idx,
                "target": target,
                "player_idx": player_idx,
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx
            self._animating_hand_idx_player = player_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()
                self._refresh_interaction_controls()

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
        elif isinstance(zone, str) and zone.startswith("bench_"):
            bench_idx = int(zone.split("_")[1])
            if player.bench[bench_idx] is not None:
                self.state._log("该备战区已有宝可梦。")
                self._clear_selection()
                return
            target = zone
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
        self._animating_hand_idx_player = captured_player_idx

        def on_animation_done():
            result = self.tm.setup_place_basic(captured_player_idx, captured_hand_idx, captured_target)
            if not result.success:
                self.state._log(f"放置失败: {result.log_message}")
            self._clear_selection()
            self._animating_action = False
            self._animating_hand_idx = None
            self._sync_tracking_counts()
            self._refresh_interaction_controls()
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
            self._send_client_action("SETUP_DONE", {"player_idx": player_idx})
            self._clear_selection()
            self.selected_action = None
            return

        self.setup_pass_done[player_idx] = True
        self.state._log(f"玩家{player_idx + 1}准备好了。")

        if self.setup_pass_done[0] and self.setup_pass_done[1]:
            result = self.tm.setup_finalize()
            if result.success:
                self.state._log(result.log_message)
                self._refresh_interaction_controls()
                if self._is_remote_host:
                    self._waiting_remote = (self.state.active_player_idx != self.my_player_idx)
                    self._broadcast_state()
        else:
            other = 1 - player_idx
            self.setup_player_idx = other
            self._clear_selection()
            self._refresh_interaction_controls()
            if self.challenge_mode:
                self._ai_thinking_timer = self._ai_action_delay
                return
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

        if self.state.phase == TurnPhase.SETUP:
            if self.selected_action == "PLACE_BENCH" and self.selected_hand_idx is not None:
                self._setup_place(player_idx, f"bench_{bench_idx}")
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
        if self.state.phase == TurnPhase.SETUP:
            if self.selected_action == "PLACE_ACTIVE" and self.selected_hand_idx is not None:
                self._setup_place(player_idx, "active")
            return

        if self.selected_action == PlayerAction.PLAY_BASIC and self.selected_hand_idx is not None:
            self.state._log("主要阶段不能从手牌将基础宝可梦放到战斗区。")
            self._clear_selection()
        elif self.selected_action == PlayerAction.ATTACH_ENERGY and self.selected_hand_idx is not None:
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
        player = self._get_display_player()
        card = player.hand[hand_idx] if player and hand_idx < len(player.hand) else None
        card_id = getattr(card, "api_id", "")
        if card_name is None and card is not None:
            card_name = card.name
        # Create a card surface to animate
        from ui.components.board_renderer import get_card_image_surface
        card_surf = get_card_image_surface(self, card_name, CARD_WIDTH, CARD_HEIGHT, card_id)
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
        if target == "active" and self.state.phase != TurnPhase.SETUP:
            self.state._log("主要阶段不能从手牌将基础宝可梦放到战斗区。")
            self._clear_selection()
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
            self._send_client_action("PLAY_BASIC", {
                "hand_idx": self.selected_hand_idx,
                "target": target,
                "player_idx": player_idx,
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx
            self._animating_hand_idx_player = player_idx

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
        self._animating_hand_idx_player = captured_player_idx

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
            self._build_action_buttons()

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
            self._send_client_action("EVOLVE", {
                "hand_idx": self.selected_hand_idx,
                "slot": slot,
                "player_idx": player_idx,
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx
            self._animating_hand_idx_player = player_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()
                self._build_action_buttons()

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
        self._animating_hand_idx_player = captured_player_idx

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
            self._build_action_buttons()

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
            self._send_client_action("ATTACH_ENERGY", {
                "hand_idx": self.selected_hand_idx,
                "target_slot": target,
                "player_idx": player_idx,
            })

            self._animating_action = True
            self._animating_hand_idx = self.selected_hand_idx
            self._animating_hand_idx_player = player_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()
                self._build_action_buttons()

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
        self._animating_hand_idx_player = captured_player_idx

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
            self._build_action_buttons()

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
            self._animating_hand_idx_player = captured_player_idx

            # Send to host immediately, play fly animation in parallel
            self._send_client_action("PLAY_TRAINER", {
                "hand_idx": self.selected_hand_idx,
                "player_idx": player_idx,
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
            card_name = player.hand[self.selected_hand_idx].name if self.selected_hand_idx < len(player.hand) else None
            card_obj = player.hand[self.selected_hand_idx] if self.selected_hand_idx < len(player.hand) else None
            self._set_last_action_context(captured_player_idx, (target_x, target_y), card_name, card_obj)
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

        before_hand = list(player.hand)
        before_layout = list(self._get_hand_layout())
        before_discard_count = len(player.discard)
        before_deck_count = len(player.deck)

        # Hide card from hand during action
        self._animating_action = True
        self._animating_hand_idx = self.selected_hand_idx
        self._animating_hand_idx_player = captured_player_idx

        # Record source position and card info for potential discard animation
        hand_layout = self._get_hand_layout()
        if captured_hand_idx < len(hand_layout):
            sx, sy, _ = hand_layout[captured_hand_idx]
            self._set_last_action_context(
                captured_player_idx,
                (sx + CARD_WIDTH // 2, sy + CARD_HEIGHT // 2),
                card.name,
                card,
            )

        result = self.tm.perform_action(
            PlayerAction.PLAY_TRAINER, player_idx=captured_player_idx,
            hand_idx=captured_hand_idx,
        )

        # If there's a pending action, store the card locally for cancel support
        if result.pending_action and card.is_trainer:
            self._pending_trainer_card = card
            # Don't clear animation state yet - pending action UI is about to show
        else:
            # No pending action: animate the actual zone changes once.
            saved_hand_idx = self._animating_hand_idx
            self._animating_action = False
            self._animating_hand_idx = None
            if result.success:
                action_source = self._last_action_source_for(captured_player_idx)
                fallback = (
                    action_source[0] if action_source else PLAY_AREA_W // 2,
                    action_source[1] if action_source else HAND_Y + CARD_HEIGHT // 2,
                )
                discard_cards = list(player.discard[before_discard_count:])
                drawn_cards = self._result_draw_cards(result, player, before_deck_count)
                source_positions = self._discard_source_positions(
                    discard_cards, before_hand, before_layout,
                    played_card=card, played_idx=saved_hand_idx, fallback=fallback,
                )
                self._clear_last_action_context()
                self._suppress_result_draw_anim = bool(drawn_cards)
                self._animate_discard_draw_sequence(
                    captured_player_idx,
                    discard_cards,
                    drawn_cards,
                    source_positions=source_positions,
                    discard_start_idx=before_discard_count,
                    draw_start_idx=max(0, len(player.hand) - len(drawn_cards)),
                )
                self._sync_tracking_counts()
            else:
                self._clear_last_action_context()

        self._show_result(result)
        self._clear_selection()

        # Don't sync — let _detect_state_changes trigger discard animation

    def _do_play_trainer_tool(self, player_idx, hand_idx, target_slot):
        """Play a tool card with explicit target_slot."""
        if self._is_remote_client:
            player = self.state.get_player(player_idx)

            # Send to host immediately, play fly animation in parallel
            self._send_client_action("PLAY_TRAINER", {
                "hand_idx": hand_idx,
                "target_slot": target_slot,
                "player_idx": player_idx,
            })

            self._animating_action = True
            self._animating_hand_idx = hand_idx
            self._animating_hand_idx_player = player_idx

            def on_anim_done():
                self._animating_action = False
                self._animating_hand_idx = None
                self._sync_tracking_counts()

            target_x = PLAY_AREA_W // 2
            target_y = HAND_Y + CARD_HEIGHT // 2
            # Record play position and card info as discard animation source so
            # the card flies from the "played" position to the discard pile.
            card_name = player.hand[hand_idx].name if hand_idx < len(player.hand) else None
            card_obj = player.hand[hand_idx] if hand_idx < len(player.hand) else None
            self._set_last_action_context(player_idx, (target_x, target_y), card_name, card_obj)
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
            self._send_client_action("RETREAT", {
                "bench_idx": bench_idx,
                "player_idx": player_idx,
            })
            self._clear_selection()
            return
        result = self.tm.perform_action(
            PlayerAction.RETREAT, player_idx=player_idx,
            bench_idx=bench_idx,
        )
        self._show_result(result)
        self._clear_selection()
        self._build_action_buttons()

    def _show_attack_menu(self, player_idx):
        player = self.state.get_player(player_idx)
        if player.active is None:
            return

        attacks = player.active.card.attacks
        valid_attacks = []
        blocked_reasons = []
        for i, atk in enumerate(attacks):
            ok, reason = can_declare_attack(self.state, player_idx, i)
            if ok:
                valid_attacks.append((i, atk))
            elif reason:
                blocked_reasons.append(reason)

        if not valid_attacks:
            reason = blocked_reasons[0] if blocked_reasons else "没有可用招式。"
            self.state._log(reason)
            self._clear_selection()
            return

        # Pre-calculate damage against opponent's active
        opponent = self.state.get_player(1 - player_idx)
        damage_previews = {}
        if opponent.active:
            from engine.damage_calculator import calculate_damage
            attacker = player.active
            defender = opponent.active
            apply_matchups = getattr(self.state, "apply_type_matchups", False)
            for i, atk in valid_attacks:
                if atk.damage > 0:
                    atk_type = attacker.card.energy_types[0] if attacker.card.energy_types else "Colorless"
                    if apply_matchups:
                        dmg = calculate_damage(
                            atk.damage, atk_type,
                            defender.card,
                            defender.card.weaknesses or [],
                            defender.card.resistances or [],
                        )
                    else:
                        dmg = atk.damage
                    # Check if weakness/resistance applies
                    has_weakness = apply_matchups and any(
                        w.energy_type == atk_type for w in (defender.card.weaknesses or [])
                    )
                    has_resistance = apply_matchups and any(
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

        if valid_attacks:
            self._attack_menu_open = True
            self._attack_menu_attacks = valid_attacks
            self._attack_menu_hover = None
        self._clear_selection()

    @staticmethod
    def _has_manual_ability(pokemon) -> bool:
        """Check if a Pokemon has at least one manually-activatable ability."""
        if not pokemon or not pokemon.card.abilities:
            return False
        for ab in pokemon.card.abilities:
            if getattr(ab, 'trigger', '') in ('', 'on_turn'):
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

        # Exclude passive/triggered abilities and already-used once-per-turn abilities.
        abilities = [ab for ab in pokemon.card.abilities
                     if getattr(ab, 'trigger', '') in ('', 'on_turn')
                     and can_use_ability(self.state, player_idx, slot, ab.name)[0]]
        if not abilities:
            self.state._log(f"{pokemon.card.name}没有当前可手动发动的特性。")
            return

        if len(abilities) == 1:
            if self._is_remote_client:
                self._send_client_action("USE_ABILITY", {
                    "slot": slot,
                    "ability_name": abilities[0].name,
                    "player_idx": player_idx,
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
        # Reject passive and triggered abilities.
        for ab in pokemon.card.abilities:
            if ab.name == ability_name and getattr(ab, 'trigger', '') not in ('', 'on_turn'):
                self.state._log(f"「{ab.name}」不是可手动发动的特性。")
                return
        result = self.tm.perform_action(
            PlayerAction.USE_ABILITY, player_idx=player_idx,
            slot=slot, ability_name=ability_name,
        )
        self._show_result(result)
        self._clear_selection()
        self._build_action_buttons()

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
                self._send_client_action("USE_ABILITY", {
                    "slot": self._ability_menu_slot,
                    "ability_name": ab.name,
                    "player_idx": self._ability_menu_player_idx,
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
            self._send_client_action("USE_STADIUM", {"player_idx": player_idx})
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
            for attack_idx, _ in enumerate(player.active.card.attacks):
                ok, _ = can_declare_attack(self.state, player_idx, attack_idx)
                if ok:
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
        if self.challenge_mode:
            algo_short = "信息集 PUCT"
            hints.append(("", f"搜索: {algo_short}"))

        panel_w = 170
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
                         until_tails: bool = False, predetermined: list | None = None):
        """Start the coin flip animation with N flips and result callback."""
        if not self.coin_flip.active:
            self.coin_flip.start(flip_count=flip_count, on_result=on_result,
                                until_tails=until_tails, predetermined=predetermined)

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
        """Clear the UI lock after the engine consumes the pending trainer."""
        if not self._pending_trainer_card:
            return
        self._pending_trainer_card = None
        self._animating_action = False
        self._animating_hand_idx = None

    def _do_confirm_yes(self, action_req):
        """Handle a confirm dialog 'yes' response."""
        self._confirm_dialog = None
        self._dispatch_choice_result(
            self._resolve_structured_pending(action_req, True)
        )

    def _do_confirm_no(self, action_req):
        """Handle a confirm dialog 'no' response."""
        self._confirm_dialog = None
        self._dispatch_choice_result(
            self._resolve_structured_pending(action_req, False)
        )

    def _do_end_turn(self) -> None:
        if self._turn_ending:
            return  # Already processing end turn
        self._turn_ending = True
        self._end_turn_warned = False
        self._confirm_dialog = None
        if self._is_remote_client:
            self._waiting_remote = True  # Block input until the authoritative state arrives
            self._send_client_action("END_TURN", {"player_idx": self.state.active_player_idx})
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
            is_local = (
                not self._is_remote_host
                and not self._is_remote_client
                and not self.challenge_mode
            )
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
        if self._attack_menu_hover is not None and self._attack_menu_hover < len(self._attack_menu_attacks):
            player_idx = self.state.active_player_idx
            i, attack = self._attack_menu_attacks[self._attack_menu_hover]
            if self._is_remote_client:
                self._send_client_action("DECLARE_ATTACK", {
                    "attack_idx": i,
                    "player_idx": player_idx,
                })
                self._attack_menu_open = False
                self._clear_selection()
                return
            step = self.game_engine.apply_action(
                self.state,
                GameAction(
                    PlayerAction.DECLARE_ATTACK,
                    {"attack_idx": i},
                    terminal=True,
                    actor=player_idx,
                ),
                auto_resolve=False,
                auto_finish_attack=True,
            )
            result = step.action_result or ActionResult(step.success, step.message)
            self._show_result(result)
            self._attack_menu_open = False
            if result.success:
                self._has_attacked = True
                if step.pending_choice is None:
                    self._pending_turn_end = max(self._pending_turn_end, 0.3)
                self._build_action_buttons()
                self._clear_selection()
            if self._is_remote_host:
                # _show_result already broadcasts internally with attacker_player_idx
                pass
        else:
            self._attack_menu_open = False

    def _handle_turn_end(self) -> None:
        self._turn_ending = False  # Allow next End Turn
        self._has_attacked = False  # Reset for the new turn
        if self.state.phase == TurnPhase.GAME_OVER:
            self._show_end_screen()
            return

        next_player = self.state.active_player_idx

        if self._is_remote_host:
            if self.state.pending_promotion_player >= 0:
                self._check_promotion_needed()
                if self.state.pending_promotion_player >= 0:
                    return
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
            # Client doesn't manage turn end - the authoritative state handles it
            return

        if self.challenge_mode:
            if self.state.pending_promotion_player >= 0:
                self._check_promotion_needed()
                if self.state.pending_promotion_player >= 0:
                    return
            self._sync_tracking_counts()
            self._build_action_buttons()
            self._clear_selection()
            self._ai_thinking_timer = self._ai_action_delay
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
        elif action == "ENTER_ATTACK":
            self.state.phase = TurnPhase.ATTACK
            self.state._log("进入攻击阶段。请点击战斗宝可梦选择招式。")
            self._build_action_buttons()
            self._clear_selection()
            if self._is_remote_host:
                self._broadcast_state()
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

        self._send_client_action(action_str, params)

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
        suppress_draw_anim = self._suppress_result_draw_anim
        self._suppress_result_draw_anim = False
        if not result.success:
            self.state._log(f"错误: {result.log_message}")
        elif result.pending_action:
            if self.challenge_mode and self._is_ai_pending_request(result.pending_action):
                self._queue_ai_pending_action(result.pending_action)
                result.pending_action = None
            # If the current active player is remote, defer to client
            elif self._is_remote_host and self.state.active_player_idx != self.my_player_idx:
                self._pending_remote_action = result.pending_action
                # Will be broadcast by _broadcast_result at end of this method
            else:
                self._handle_pending_action(result.pending_action)
                result.pending_action = None  # Handled locally, don't broadcast
        else:
            # Determine animation slot keys based on who performed the action
            if self.challenge_mode:
                is_self_attacker = (
                    attacker_player_idx is None
                    or attacker_player_idx == self.human_player_idx
                )
            else:
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
                self.damage_ripple.trigger(damage_slot)
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
            if result.cards_drawn and not suppress_draw_anim:
                draw_player_idx = self.state.active_player_idx
                player = self.state.get_player(draw_player_idx)
                draw_cards = list(result.cards_drawn)
                start = max(0, len(player.hand) - len(draw_cards)) if player else 0
                for offset, card in enumerate(draw_cards):
                    card_obj = card if hasattr(card, "api_id") else None
                    card_name = self._card_anim_name(card)
                    self._animate_draw(draw_player_idx, card_name, card_obj, start + offset)
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
            self._broadcast_update(
                result, action=action, attacker_player_idx=attacker_player_idx
            )

        if result.success and (
            self.state.winner is not None
            or self.state.phase == TurnPhase.GAME_OVER
        ):
            if self.state.winner is not None:
                self.state.phase = TurnPhase.GAME_OVER
            self._show_end_screen()
            return

        # Challenge mode has no PassScreen; handle KO promotion immediately.
        if self.challenge_mode and self.state.pending_promotion_player >= 0:
            self._check_promotion_needed()
        # Defer promotion check if PassScreen should come first
        elif self.state.pending_promotion_player < 0:
            self._check_promotion_needed()

    def _finish_promotion_flow(self) -> None:
        if self.state.pending_promotion_player < 0:
            return
        self._awaiting_promotion = False
        if self.state.phase == TurnPhase.DRAW and self.tm is not None:
            self.tm.continue_after_promotion()  # Pops one, handles remaining queue
        else:
            self.state.pop_pending_promotion()  # Pop just this one

    def _check_promotion_needed(self) -> None:
        if self.state.phase == TurnPhase.GAME_OVER:
            return
        if self._awaiting_promotion:
            return  # Already waiting for user to pick a bench Pokemon
        player_idx = self.state.pending_promotion_player
        if player_idx < 0:
            player_idx = self.my_player_idx if (self._is_remote_host or self._is_remote_client) else (
                self.setup_player_idx if self.state.phase == TurnPhase.SETUP else self.state.active_player_idx
            )
        # In challenge mode, KO promotion must resolve immediately after the
        # attack, even though the affected player is usually not the active
        # turn owner. Otherwise pending AI promotion blocks both players.
        if self.state.phase not in (TurnPhase.SETUP, TurnPhase.DRAW):
            if player_idx != self.state.active_player_idx and not self.challenge_mode:
                return
        player = self.state.get_player(player_idx)
        if player.active is None:
            bench_pokes = [(i, p) for i, p in enumerate(player.bench) if p is not None]
            if not bench_pokes:
                return
            if len(bench_pokes) == 1:
                player.promote_from_bench(bench_pokes[0][0])
                self.state._log(f"{player.name}将{player.active.card.name}提升至战斗区。")
                self._awaiting_promotion = False
                self._finish_promotion_flow()
                if self._is_remote_host:
                    self._broadcast_state()
                return
            elif len(bench_pokes) > 1:
                if self.challenge_mode and player_idx == self.ai_player_idx:
                    req = ActionRequest(
                        request_type="select_bench",
                        player=player_idx,
                        prompt="AI promotion",
                        min_select=1,
                        max_select=1,
                        bench_indices=[i for i, _ in bench_pokes],
                    )
                    choice = self.ai_controller.resolve_pending_action(self.state, req)
                    bench_idx = choice.selected_bench_slot
                    if bench_idx is None:
                        bench_idx = bench_pokes[0][0]
                    player.promote_from_bench(bench_idx)
                    self.state._log(f"AI 将 {player.active.card.name} 提升至战斗区。")
                    self._awaiting_promotion = False
                    self._finish_promotion_flow()
                    self._build_action_buttons()
                    self._ai_thinking_timer = self._ai_action_delay
                    return
                if self._is_remote_host and player_idx != self.my_player_idx:
                    def on_remote_promote(bench_idx):
                        if bench_idx is None:
                            return None
                        remote_player = self.state.get_player(player_idx)
                        if 0 <= bench_idx < len(remote_player.bench) and remote_player.bench[bench_idx]:
                            remote_player.promote_from_bench(bench_idx)
                            self.state._log(
                                f"{remote_player.name}将{remote_player.active.card.name}提升至战斗区。"
                            )
                            self._finish_promotion_flow()
                        return None

                    req = ActionRequest(
                        request_type="select_bench",
                        player=player_idx,
                        prompt="请选择要提升至战斗区的宝可梦。",
                        min_select=1,
                        max_select=1,
                        bench_indices=[i for i, _ in bench_pokes],
                        callback=on_remote_promote,
                    )
                    self._pending_remote_action = req
                    self._waiting_remote = True
                    self._broadcast_update(pending_action=req)
                    return
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
            self._send_choice_response({
                "request_id": getattr(action_req, "request_id", ""),
                "selected_bench_slot": bench_idx,
            })
            return
        if action_req.request_type == "select_own_bench_energy":
            call_result = self._resolve_structured_pending(action_req, bench_idx)
            self._dispatch_choice_result(call_result)
            return
        # Use explicit player index from ActionRequest if valid, otherwise fall back
        # to the active player (for self-switch) or opponent (for opponent-switch)
        if action_req.request_type == "select_opponent_bench":
            player = self.state.get_opponent()
        elif hasattr(action_req, 'player') and action_req.player >= 0:
            player = self.state.get_player(action_req.player)
        elif action_req.request_type == "select_bench":
            player = self.state.get_active_player()
        else:
            player = self.state.get_opponent()
        if player.bench[bench_idx] is None:
            self.state._log("该位置没有宝可梦。")
            return
        call_result = self._resolve_structured_pending(action_req, bench_idx)
        self._dispatch_choice_result(call_result)
        if call_result is not None and getattr(call_result, "success", True):
            self.state._log(f"{player.name}的战斗宝可梦被替换了。")
        if self._is_remote_host:
            self._broadcast_state()

    def _do_bench_promotion(self, player_idx, bench_idx):
        player = self.state.get_player(player_idx)
        if player.bench[bench_idx] is None:
            self.state._log("该位置没有宝可梦。")
            return
        if player.active is not None:
            player.switch_active_to_bench(bench_idx)
            self.state._log(f"{player.name}将战斗宝可梦与备战宝可梦互换。")
        else:
            player.promote_from_bench(bench_idx)
            self.state._log(f"{player.name}将{player.active.card.name}提升至战斗区。")
        self._awaiting_promotion = False
        self._clear_selection()
        self._finish_promotion_flow()
        if self._is_remote_host:
            self._broadcast_state()

    def _show_energy_distribution(self, action_req):
        """Open the energy distribution screen."""
        from ui.screens.energy_distribution_screen import EnergyDistributionScreen

        def on_distribution_complete(assignments):
            # assignments: list of (energy_idx, target_slot)
            self._dispatch_choice_result(
                self._resolve_structured_pending(action_req, assignments)
            )

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

    def _resolve_structured_pending(self, action_req: ActionRequest, payload):
        """Resolve one UI choice through the authoritative choice contract."""
        structured = self.game_engine.choice_request(self.state, action_req)
        response = self.game_engine.choice_response_from_legacy(
            structured,
            payload,
        )
        step = self.game_engine.apply_choice(
            self.state,
            structured,
            response,
        )
        result = step.action_result or ActionResult(step.success, step.message)
        if result.pending_action:
            return result.pending_action
        return result

    def _dispatch_choice_result(self, result) -> None:
        """Route a structured choice result without calling legacy callbacks."""
        if isinstance(result, ActionRequest):
            self._handle_pending_action(result)
        elif result is not None:
            self._show_result(result)
            if self._has_attacked and self.state.phase != TurnPhase.ATTACK:
                self._pending_turn_end = max(self._pending_turn_end, 0.3)

    def _handle_pending_action(self, action_req):
        if self.challenge_mode and self._is_ai_pending_request(action_req):
            self._handle_ai_pending_action(action_req)
            return

        # In client mode, intercept and send results back to host
        if self._is_remote_client:
            self._handle_pending_action_client(action_req)
            return

        if action_req.request_type in ("search_deck", "select_hand_to_discard"):
            from ui.screens.search_screen import SearchScreen
            def wrapped_callback(selected_cards):
                player = self.state.get_player(action_req.player)
                before_hand = list(player.hand) if player else []
                before_layout = list(self._get_hand_layout()) if player else []
                before_discard_count = len(player.discard) if player else 0
                before_deck_count = len(player.deck) if player else 0
                call_result = self._resolve_structured_pending(action_req, selected_cards)
                # The engine consumes pending_card; the UI only owns animation state.
                if self._pending_trainer_card:
                    card = self._pending_trainer_card
                    player = self.state.get_player(action_req.player)
                    saved_hand_idx = self._animating_hand_idx
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    # Trigger discard animation from hand position
                    source = self._last_action_source_for(action_req.player)
                    src_x = source[0] if source else PLAY_AREA_W // 2
                    src_y = source[1] if source else HAND_Y + CARD_HEIGHT // 2
                    src_slot = f"hand_{saved_hand_idx}" if saved_hand_idx is not None else None
                    self._clear_last_action_context()
                    discard_cards = list(player.discard[before_discard_count:])
                    drawn_cards = (
                        self._result_draw_cards(call_result, player, before_deck_count)
                        if call_result is not None and getattr(call_result, "success", False)
                        else []
                    )
                    if drawn_cards:
                        self._suppress_result_draw_anim = True
                        source_positions = [
                            (src_x + (i % 3 - 1) * 10, src_y + (i % 2) * 8)
                            for i in range(len(discard_cards))
                        ]
                        self._animate_discard_draw_sequence(
                            action_req.player,
                            discard_cards,
                            drawn_cards,
                            source_positions=source_positions,
                            discard_start_idx=before_discard_count,
                            draw_start_idx=max(0, len(player.hand) - len(drawn_cards)),
                        )
                        self._sync_tracking_counts()
                    else:
                        self._animate_discard(
                            action_req.player, src_x, src_y, card.name, card,
                            source_slot=src_slot, discard_idx=len(player.discard) - 1,
                        )
                    if (call_result is not None
                            and getattr(call_result, "success", False)
                            and not self._is_remote_host):
                        self._show_result(call_result)
                elif call_result is not None and getattr(call_result, "success", False):
                    player = self.state.get_player(action_req.player)
                    discard_cards = list(player.discard[before_discard_count:])
                    drawn_cards = self._result_draw_cards(call_result, player, before_deck_count)
                    if discard_cards or drawn_cards:
                        source_positions = self._discard_source_positions(
                            discard_cards,
                            before_hand,
                            before_layout,
                            fallback=(PLAY_AREA_W // 2, HAND_Y + CARD_HEIGHT // 2),
                        )
                        self._suppress_result_draw_anim = bool(drawn_cards)
                        self._animate_discard_draw_sequence(
                            action_req.player,
                            discard_cards,
                            drawn_cards,
                            source_positions=source_positions,
                            discard_start_idx=before_discard_count,
                            draw_start_idx=max(0, len(player.hand) - len(drawn_cards)),
                        )
                        self._sync_tracking_counts()
                    if not self._is_remote_host:
                        self._show_result(call_result)
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
                choice_resolver=self._resolve_structured_pending,
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
                    source = self._last_action_source_for(action_req.player)
                    src_x = source[0] if source else PLAY_AREA_W // 2
                    src_y = source[1] if source else HAND_Y + CARD_HEIGHT // 2
                    self._clear_last_action_context()
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
                chain_result = self._resolve_structured_pending(action_req, results)
                # The engine consumes pending_card; clear only the UI lock here.
                if self._pending_trainer_card and chain_result is not None:
                    self._pending_trainer_card = None
                    self._animating_action = False
                    self._animating_hand_idx = None
                    # Don't sync — let _detect_state_changes handle discard animation
                self._dispatch_choice_result(chain_result)
            self._start_coin_flip(
                flip_count=getattr(action_req, 'flip_count', 1),
                on_result=on_flip_done,
                until_tails=getattr(action_req, 'until_tails', False),
            )
        elif action_req.request_type == "confirm":
            # Wrap callbacks to handle pending trainer card discard
            def _confirm_yes():
                self._confirm_dialog = None
                chain_result = self._resolve_structured_pending(action_req, True)
                self._after_pending_trainer_resolve(action_req)
                self._dispatch_choice_result(chain_result)

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
                else:
                    self._resolve_structured_pending(action_req, False)
                self.state._log("操作已取消，卡牌返回手牌。")

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
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
                    "selected_indices": indices,
                })
            def on_cancel_client():
                self._resolving_remote_pending = False
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
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
            # Use predetermined results from host if available (server authority)
            predetermined = getattr(action_req, 'predetermined_flips', None)
            def on_flip_done(results):
                self._resolving_remote_pending = False
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
                    "coin_results": results,
                })
            self._start_coin_flip(
                flip_count=getattr(action_req, 'flip_count', 1),
                on_result=on_flip_done,
                until_tails=getattr(action_req, 'until_tails', False),
                predetermined=predetermined,
            )
        elif action_req.request_type == "select_bench_targets":
            self._selecting_bench_targets = action_req
            self._selected_bench_targets = []
            self.state._log(action_req.prompt)
            # Override the bench target selection handler to send to network
            self._bench_target_handler_is_client = True
        elif action_req.request_type == "confirm":
            def _confirm_yes_client():
                self._confirm_dialog = None
                self._resolving_remote_pending = False
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
                    "confirmed": True,
                })

            def _confirm_no_client():
                self._confirm_dialog = None
                self._resolving_remote_pending = False
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
                    "confirmed": False,
                })

            self._confirm_dialog = {
                "title": "确认",
                "message": action_req.prompt,
                "confirm_label": "是",
                "cancel_label": "否",
                "on_confirm": _confirm_yes_client,
                "on_cancel": _confirm_no_client,
            }
        elif action_req.request_type == "distribute_energy":
            from ui.screens.energy_distribution_screen import EnergyDistributionScreen

            def on_distribution_complete(assignments):
                self._resolving_remote_pending = False
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
                    "assignments": assignments,
                })

            def on_distribution_cancel():
                self._resolving_remote_pending = False
                self._send_choice_response({
                    "request_id": getattr(action_req, "request_id", ""),
                    "cancelled": True,
                })

            screen = EnergyDistributionScreen(
                self.manager, {
                    "energy_cards": action_req.card_list,
                    "targets": getattr(action_req, 'target_info', []),
                    "mode": getattr(action_req, 'distribute_mode', 'distribute'),
                    "max_per_target": getattr(action_req, 'max_per_target', 99),
                    "source_name": getattr(action_req, 'source_name', ''),
                },
                on_distribution_complete,
                on_cancel=on_distribution_cancel,
            )
            self.manager.push_screen(screen)
        else:
            self.state._log(f"待处理: {action_req.prompt}")

    def _handle_bench_select_prompt_client(self, action_req):
        """Client mode bench selection: choose locally, send result to host."""
        if action_req.request_type == "select_opponent_bench":
            player = self.state.get_opponent()
            is_opponent = True
        elif getattr(action_req, 'target_player', '') == "opponent":
            player = self.state.get_opponent()
            is_opponent = True
        elif getattr(action_req, 'player', -1) >= 0:
            player = self.state.get_player(action_req.player)
            is_opponent = action_req.player != self.my_player_idx
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
            self._send_choice_response({
                "request_id": getattr(action_req, "request_id", ""),
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
            return
        if action_req.request_type == "select_own_bench_energy":
            # Energy attach to bench: always let player choose (don't auto)
            self._animating_action = False
            self._animating_hand_idx = None
            self._pending_bench_select = action_req
            self.state._log("请点击备战区宝可梦选择附着目标。")
        elif len(bench_with_pokemon) == 1:
            bench_idx = bench_with_pokemon[0]
            call_result = self._resolve_structured_pending(action_req, bench_idx)
            self._dispatch_choice_result(call_result)
            if call_result is not None and getattr(call_result, "success", True):
                self.state._log(f"{player.name}的战斗宝可梦被替换了。")
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
            for msg in self.network_manager.poll(max_messages=32):
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
        elif self._is_ai_turn_context():
            algo_label = "信息集 PUCT"
            ai_label = self._ai_runtime_label()
            self.waiting_indicator.show(f"{ai_label} 思考中 ({algo_label})...")
        else:
            self.waiting_indicator.hide()
        self.waiting_indicator.update(sdt)

        # State sync fade decay (use sdt for speed multiplier consistency)
        if self._remote_update_fade > 0:
            self._remote_update_fade = max(0, self._remote_update_fade - sdt)

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
                if self._is_remote_host or self._is_remote_client or self.challenge_mode:
                    self._handle_turn_end()

        if self.challenge_mode:
            self._update_challenge_ai(sdt)

    def _clear_selection(self):
        self.selected_hand_idx = None
        self.selected_action = None
        self._confirm_end_turn = False
        self._close_card_action_menu()

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

    # ── Connection Status ────────────────────────────────────────

    def _draw_connection_status(self, surface):
        """Draw connection status indicator for online play."""
        if not self.network_manager:
            return

        dot_x = self.layout.divider.right - 136
        dot_y = self.layout.divider.centery

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


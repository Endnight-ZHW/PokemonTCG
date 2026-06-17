"""Challenge-mode AI scheduling for GameScreen."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import pygame

from config import CARD_WIDTH, CARD_HEIGHT
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, ActionResult
from ui.components.game_layout import PLAY_AREA_W


class GameScreenAIMixin:
    """Owns AI turn detection, background search, and pending choice resolution."""

    def _ensure_ai_executor(self) -> None:
        if self._ai_executor is None:
            self._ai_executor = ThreadPoolExecutor(
                max_workers=1,
                thread_name_prefix="challenge-ai",
            )
        self._ai_shutdown = False

    def _shutdown_ai_executor(self) -> None:
        self._ai_shutdown = True
        if self._ai_action_future is not None:
            self._ai_action_future.cancel()
            self._ai_action_future = None
            self._ai_action_job_key = None
        if self._ai_executor is not None:
            self._ai_executor.shutdown(wait=False, cancel_futures=True)
            self._ai_executor = None

    def _should_block_challenge_input(self) -> bool:
        if not self.challenge_mode:
            return False
        if self._pending_bench_select is not None and not self._is_ai_pending_request(self._pending_bench_select):
            return False
        if self._selecting_bench_targets is not None and not self._is_ai_pending_request(self._selecting_bench_targets):
            return False
        if self._awaiting_promotion and self.state.pending_promotion_player == self.human_player_idx:
            return False
        if self._confirm_dialog is not None:
            return False
        return self._is_ai_turn_context()

    def _is_ai_turn_context(self) -> bool:
        if not self.challenge_mode or self.state.phase == TurnPhase.GAME_OVER:
            return False
        if self._ai_pending_action is not None:
            return True
        if self.state.pending_promotion_player == self.ai_player_idx:
            return True
        if self.state.phase == TurnPhase.SETUP:
            return self.setup_player_idx == self.ai_player_idx
        return self.state.active_player_idx == self.ai_player_idx

    def _ai_runtime_label(self) -> str:
        if self.ai_kind != "deep_learning":
            return "专家规则 AI"
        if self.ai_controller is not None and getattr(self.ai_controller, "model_available", False):
            return "Deep AI 模型 + MCTS"
        return "Deep AI 未训练，专家规则 AI fallback"

    def _is_ai_pending_request(self, action_req: ActionRequest | None) -> bool:
        if not self.challenge_mode or action_req is None:
            return False
        if action_req.player == self.ai_player_idx:
            return True
        return (
            self.state.active_player_idx == self.ai_player_idx
            and action_req.player not in (self.human_player_idx, 1 - self.ai_player_idx)
        )

    def _ai_state_job_key(self) -> tuple:
        return (
            self.state.turn_number,
            self.state.phase,
            self.state.active_player_idx,
            self.setup_player_idx,
            self.state.pending_promotion_player,
        )

    def _ai_animation_busy(self) -> bool:
        return (
            self._pending_turn_end > 0
            or self._animating_action
            or self.coin_flip.active
            or bool(self.card_fly.active)
        )

    def _start_ai_action_search(self) -> None:
        if self._ai_action_future is not None:
            return
        self._ensure_ai_executor()
        if self._ai_executor is None or self.ai_controller is None:
            return
        self._ai_action_job_key = self._ai_state_job_key()
        self._ai_action_future = self._ai_executor.submit(
            self.ai_controller.choose_action,
            self.state,
            self.ai_player_idx,
        )

    def _finish_ai_action_search(self) -> None:
        future = self._ai_action_future
        job_key = self._ai_action_job_key
        self._ai_action_future = None
        self._ai_action_job_key = None
        if future is None:
            return
        if future.cancelled() or self._ai_shutdown:
            return
        if not self._is_ai_turn_context() or job_key != self._ai_state_job_key():
            self._ai_thinking_timer = 0.0
            return
        try:
            action = future.result()
        except Exception as exc:
            self.state._log(f"AI思考失败: {exc}")
            self._ai_thinking_timer = self._ai_action_delay
            return
        self._execute_ai_action(action)

    def _update_challenge_ai(self, dt: float) -> None:
        if self._ai_action_future is not None:
            if self.state.winner is not None or self.state.phase == TurnPhase.GAME_OVER:
                self._ai_action_future.cancel()
                self._ai_action_future = None
                self._ai_action_job_key = None
                return
            if self._ai_action_future.done() and not self._ai_animation_busy():
                self._finish_ai_action_search()
            return
        if not self._is_ai_turn_context() or self.tm is None or self.ai_controller is None:
            return
        if self.state.winner is not None or self.state.phase == TurnPhase.GAME_OVER:
            return
        if self._ai_animation_busy():
            return
        if self._ai_pending_action is not None:
            self._ai_thinking_timer -= dt
            if self._ai_thinking_timer <= 0:
                self._ai_thinking_timer = self._ai_action_delay
                self._resolve_next_ai_pending_action()
            return
        if self._confirm_dialog is not None or self._attack_menu_open or self._ability_menu_open:
            return
        if self._pending_bench_select is not None or self._selecting_bench_targets is not None:
            return

        if self.state.pending_promotion_player == self.ai_player_idx:
            self._check_promotion_needed()
            return

        self._ai_thinking_timer -= dt
        if self._ai_thinking_timer > 0:
            return
        self._ai_thinking_timer = self._ai_action_delay
        self._start_ai_action_search()

    def _execute_ai_action(self, ai_action) -> None:
        if self.tm is None:
            return
        action = ai_action.action
        params = dict(ai_action.params)

        if action == "NOOP":
            return
        if action == "SETUP_DONE":
            self._setup_done(self.ai_player_idx)
            return
        if action == PlayerAction.END_TURN:
            self._do_end_turn()
            return

        prev_snap = self._snapshot_field_state()
        self._sync_tracking_counts()
        self._animate_ai_hand_action(ai_action)

        if self.state.phase == TurnPhase.SETUP:
            if action != PlayerAction.PLAY_BASIC:
                self._setup_done(self.ai_player_idx)
                return
            result = self.tm.setup_place_basic(
                self.ai_player_idx,
                params.get("hand_idx", 0),
                params.get("target", "active"),
            )
            self._show_result(result, action=PlayerAction.PLAY_BASIC)
            self._detect_field_changes(prev_snap)
            self._detect_state_changes()
            if not result.success:
                self._ai_failed_actions.add(self._ai_action_signature(ai_action))
            else:
                self._ai_failed_actions.clear()
            self._refresh_interaction_controls()
            return

        if action == PlayerAction.DECLARE_ATTACK:
            result = self.tm.declare_attack(
                self.ai_player_idx,
                params.get("attack_idx", 0),
            )
            self._show_result(
                result,
                attacker_player_idx=self.ai_player_idx,
                action=PlayerAction.DECLARE_ATTACK,
            )
            self._detect_field_changes(prev_snap)
            self._detect_state_changes()
            if result.success:
                self._has_attacked = True
                self._ai_failed_actions.clear()
                self._ai_thinking_timer = max(self._ai_thinking_timer, 0.65)
            else:
                self._ai_failed_actions.add(self._ai_action_signature(ai_action))
            self._refresh_interaction_controls()
            return

        result = self.tm.perform_action(action, player_idx=self.ai_player_idx, **params)
        self._show_result(result, attacker_player_idx=self.ai_player_idx, action=action)
        self._detect_field_changes(prev_snap)
        self._detect_state_changes()
        if result.success:
            self._ai_failed_actions.clear()
        else:
            self._ai_failed_actions.add(self._ai_action_signature(ai_action))
            if len(self._ai_failed_actions) >= 3:
                self._do_end_turn()
        self._refresh_interaction_controls()

    def _queue_ai_pending_action(self, action_req: ActionRequest) -> None:
        self._ai_pending_action = action_req
        self._pending_bench_select = None
        self._selecting_bench_targets = None
        self._confirm_dialog = None
        self._ai_thinking_timer = max(self._ai_thinking_timer, self._ai_action_delay)

    def _resolve_next_ai_pending_action(self) -> None:
        if not self.ai_controller or self._ai_pending_action is None:
            return
        pending = self._ai_pending_action
        self._ai_pending_action = None
        prev_snap = self._snapshot_field_state()
        self._sync_tracking_counts()
        choice = self.ai_controller.resolve_pending_action(self.state, pending)
        result = self.ai_controller.apply_choice(self.state, pending, choice)

        if isinstance(result, ActionRequest):
            self._queue_ai_pending_action(result)
        elif isinstance(result, ActionResult):
            self._show_result(result, attacker_player_idx=self.ai_player_idx)
            if result.pending_action:
                self._queue_ai_pending_action(result.pending_action)

        self._pending_bench_select = None
        self._selecting_bench_targets = None
        self._confirm_dialog = None
        self._animating_action = False
        self._animating_hand_idx = None
        self._detect_field_changes(prev_snap)
        self._detect_state_changes()
        self._refresh_interaction_controls()
        if self._ai_pending_action is None:
            self._check_promotion_needed()

    def _handle_ai_pending_action(self, action_req: ActionRequest) -> None:
        self._queue_ai_pending_action(action_req)

    def _ai_card_back_surface(self) -> pygame.Surface:
        w, h = CARD_WIDTH * 3 // 4, CARD_HEIGHT * 3 // 4
        if self.card_back_img:
            return pygame.transform.smoothscale(self.card_back_img, (w, h))
        surf = pygame.Surface((w, h), pygame.SRCALPHA)
        surf.fill((40, 60, 140, 230))
        pygame.draw.rect(surf, (230, 235, 255, 180), surf.get_rect(), 1, border_radius=6)
        return surf

    def _animate_ai_hand_action(self, ai_action) -> None:
        if "hand_idx" not in ai_action.params:
            return
        source = (
            self.layout.opponent_info.centerx,
            self.layout.opponent_info.centery,
        )
        target = (PLAY_AREA_W // 2, self.layout.divider.centery)
        action = ai_action.action
        params = ai_action.params
        if action == PlayerAction.PLAY_BASIC:
            target = self._get_card_screen_pos(self.ai_player_idx, params.get("target", "active")) or target
        elif action == PlayerAction.EVOLVE:
            target = self._get_card_screen_pos(self.ai_player_idx, params.get("slot", "active")) or target
        elif action == PlayerAction.ATTACH_ENERGY:
            target = self._get_card_screen_pos(self.ai_player_idx, params.get("target_slot", "active")) or target
        elif action == PlayerAction.PLAY_TRAINER:
            player = self.state.get_player(self.ai_player_idx)
            hand_idx = params.get("hand_idx", -1)
            card = player.hand[hand_idx] if 0 <= hand_idx < len(player.hand) else None
            if params.get("target_slot"):
                target = self._get_card_screen_pos(self.ai_player_idx, params["target_slot"]) or target
            elif card is not None and getattr(card, "is_trainer_stadium", False):
                target = self.layout.stadium.center
            self._set_last_action_context(self.ai_player_idx, target)

        self.card_fly.fly(
            self._ai_card_back_surface(),
            source[0],
            source[1],
            target[0],
            target[1],
            duration=0.35,
        )

    def _ai_action_signature(self, ai_action) -> tuple:
        return (
            ai_action.action,
            tuple(sorted(ai_action.params.items())),
        )

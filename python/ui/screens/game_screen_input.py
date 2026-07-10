"""Input and overlay routing for :class:`GameScreen`.

This mixin deliberately owns only event dispatch. The concrete screen keeps
the commands that mutate match state, which makes input precedence testable
without coupling it to rendering or the rules engine.
"""
from __future__ import annotations

import pygame

from config import GAME_SPEED_OPTIONS, SCREEN_HEIGHT, SCREEN_WIDTH
from engine.enums import PlayerAction, TurnPhase
from ui.colors import UI_HIGHLIGHT, UI_SUCCESS
from ui.components.game_layout import LOG_W


class GameScreenInputMixin:
    """Route Pygame events to the active GameScreen interaction layer."""

    def handle_event(self, event: pygame.event.Event) -> None:
        if self.state.phase == TurnPhase.GAME_OVER:
            self._show_end_screen()
            return

        # Modal layers are ordered from most to least exclusive. Keep this
        # order stable: it is part of the GameScreen input contract.
        if self.coin_flip.active and self.coin_flip.handle_event(event):
            return

        if self._confirm_dialog is not None:
            self._handle_confirm_dialog_event(event)
            return

        if self._pending_turn_end > 0 or self._animating_action:
            return

        if self._should_block_challenge_input():
            self._handle_blocked_challenge_event(event)
            return

        if self._attack_menu_open:
            self._handle_attack_menu_event(event)
            return

        if self._ability_menu_open:
            self._handle_ability_menu_event(event)
            return

        player_idx = (
            self.setup_player_idx
            if self.state.phase == TurnPhase.SETUP
            else self.state.active_player_idx
        )
        self._handle_board_event(event, player_idx)

    def _handle_blocked_challenge_event(self, event: pygame.event.Event) -> None:
        """Allow log scrolling while the Challenge AI owns interaction."""
        if event.type != pygame.MOUSEWHEEL:
            return
        mouse_pos = getattr(event, "pos", None)
        if mouse_pos is None:
            mouse_pos = pygame.mouse.get_pos()
        mx, _ = mouse_pos
        log_x = SCREEN_WIDTH - LOG_W - 8
        if log_x <= mx <= log_x + LOG_W:
            self._log_scroll_offset = max(0, self._log_scroll_offset - event.y)

    def _handle_attack_menu_event(self, event: pygame.event.Event) -> None:
        if event.type == pygame.MOUSEMOTION:
            self._attack_menu_hover = self._get_attack_menu_hover(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._handle_attack_menu_click(event.pos)
        elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
            self._attack_menu_open = False

    def _handle_ability_menu_event(self, event: pygame.event.Event) -> None:
        if event.type == pygame.MOUSEMOTION:
            self._ability_menu_hover = self._get_ability_menu_hover(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._handle_ability_menu_click(event.pos)
        elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
            self._ability_menu_open = False

    def _handle_board_event(self, event: pygame.event.Event, player_idx: int) -> None:
        if event.type == pygame.MOUSEMOTION:
            self._update_hover(event.pos, player_idx)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._handle_click(event.pos, player_idx)
        elif event.type == pygame.MOUSEWHEEL:
            mouse_pos = getattr(event, "pos", None)
            if mouse_pos is None:
                mouse_pos = pygame.mouse.get_pos()
            mx, _ = mouse_pos
            log_x = SCREEN_WIDTH - LOG_W - 8
            if log_x <= mx <= log_x + LOG_W:
                self._log_scroll_offset = max(0, self._log_scroll_offset - event.y)
        elif event.type == pygame.KEYDOWN:
            self._handle_game_keydown(event, player_idx)

    def _handle_game_keydown(self, event: pygame.event.Event, player_idx: int) -> None:
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
            if self.state.phase == TurnPhase.MAIN:
                self._execute_action(PlayerAction.END_TURN, player_idx)
        elif event.key == pygame.K_a:
            if self.state.phase == TurnPhase.MAIN and self.selected_action is None:
                self._execute_action("ENTER_ATTACK", player_idx)
            elif self.state.phase == TurnPhase.ATTACK and not self._has_attacked:
                self._show_attack_menu(player_idx)
        elif event.key == pygame.K_r:
            if self.state.phase == TurnPhase.MAIN:
                self._execute_action(PlayerAction.RETREAT, player_idx)
        elif event.key == pygame.K_SPACE:
            if self._attack_menu_open:
                self._handle_attack_menu_click(pygame.mouse.get_pos())
            elif self._ability_menu_open:
                self._handle_ability_menu_click(pygame.mouse.get_pos())
        elif event.key == pygame.K_z and (pygame.key.get_mods() & pygame.KMOD_CTRL):
            self._do_undo()
        elif pygame.K_1 <= event.key <= pygame.K_9:
            self._select_hand_key(event.key - pygame.K_1)
        elif event.key == pygame.K_q and not (pygame.key.get_mods() & pygame.KMOD_CTRL):
            self._confirm_quit_game()
        elif event.key == pygame.K_F1:
            self._show_shortcuts = not self._show_shortcuts
            self.floating_text.show(
                f"快捷键提示: {'开' if self._show_shortcuts else '关'}",
                400, SCREEN_HEIGHT - 60, color=UI_SUCCESS,
            )
        elif event.key == pygame.K_TAB:
            self._speed_idx = (self._speed_idx + 1) % len(GAME_SPEED_OPTIONS)
            self._speed_value = GAME_SPEED_OPTIONS[self._speed_idx]
            self.floating_text.show(
                f"游戏速度: {self._speed_value}x",
                400, SCREEN_HEIGHT - 60, color=UI_HIGHLIGHT,
            )
        elif event.key == pygame.K_c and not (pygame.key.get_mods() & pygame.KMOD_CTRL):
            self._start_coin_flip(
                flip_count=3,
                on_result=lambda results: self.state._log(
                    f"硬币结果: {sum(1 for result in results if result)}正面, "
                    f"{sum(1 for result in results if not result)}反面"
                ),
            )

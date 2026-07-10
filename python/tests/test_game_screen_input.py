"""Contract tests for GameScreen's extracted input router."""
from __future__ import annotations

import os
import sys
import unittest
from unittest import mock
from types import SimpleNamespace

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pygame

from config import SCREEN_WIDTH
from engine.enums import PlayerAction, TurnPhase
from ui.components.game_layout import LOG_W
from ui.screens.game_screen import GameScreen
from ui.screens.game_screen_input import GameScreenInputMixin


class _CoinFlipStub:
    def __init__(self) -> None:
        self.active = False
        self.events: list[pygame.event.Event] = []

    def handle_event(self, event: pygame.event.Event) -> bool:
        self.events.append(event)
        return True


class _InputHarness(GameScreenInputMixin):
    """Small host that exposes every dispatch destination as a call record."""

    def __init__(self) -> None:
        self.state = SimpleNamespace(
            phase=TurnPhase.MAIN,
            active_player_idx=1,
            _log=lambda _message: None,
        )
        self.coin_flip = _CoinFlipStub()
        self._confirm_dialog = None
        self._pending_turn_end = 0.0
        self._animating_action = False
        self._attack_menu_open = False
        self._attack_menu_hover = None
        self._ability_menu_open = False
        self._ability_menu_hover = None
        self.setup_player_idx = 0
        self.selected_hand_idx = None
        self.selected_action = None
        self._has_attacked = False
        self._log_scroll_offset = 0
        self.challenge_blocked = False
        self.calls: list[tuple] = []

    def _show_end_screen(self) -> None:
        self.calls.append(("end_screen",))

    def _handle_confirm_dialog_event(self, event) -> None:
        self.calls.append(("confirm", event.type))

    def _should_block_challenge_input(self) -> bool:
        return self.challenge_blocked

    def _get_attack_menu_hover(self, pos) -> int:
        self.calls.append(("attack_hover", pos))
        return 2

    def _handle_attack_menu_click(self, pos) -> None:
        self.calls.append(("attack_click", pos))

    def _get_ability_menu_hover(self, pos) -> int:
        self.calls.append(("ability_hover", pos))
        return 3

    def _handle_ability_menu_click(self, pos) -> None:
        self.calls.append(("ability_click", pos))

    def _update_hover(self, pos, player_idx) -> None:
        self.calls.append(("board_hover", pos, player_idx))

    def _handle_click(self, pos, player_idx) -> None:
        self.calls.append(("board_click", pos, player_idx))

    def _execute_action(self, action, player_idx) -> None:
        self.calls.append(("action", action, player_idx))


class GameScreenInputContractTests(unittest.TestCase):
    def test_game_screen_exposes_mixin_handle_event_unchanged(self):
        self.assertTrue(issubclass(GameScreen, GameScreenInputMixin))
        self.assertIs(GameScreen.handle_event, GameScreenInputMixin.handle_event)

    def test_game_over_preempts_every_modal_layer(self):
        screen = _InputHarness()
        screen.state.phase = TurnPhase.GAME_OVER
        screen.coin_flip.active = True
        screen._confirm_dialog = {"open": True}

        screen.handle_event(pygame.event.Event(pygame.KEYDOWN, {"key": pygame.K_ESCAPE}))

        self.assertEqual(screen.calls, [("end_screen",)])
        self.assertEqual(screen.coin_flip.events, [])

    def test_confirm_dialog_preempts_board_input(self):
        screen = _InputHarness()
        screen._confirm_dialog = {"open": True}
        event = pygame.event.Event(pygame.MOUSEBUTTONDOWN, {"button": 1, "pos": (20, 30)})

        screen.handle_event(event)

        self.assertEqual(screen.calls, [("confirm", pygame.MOUSEBUTTONDOWN)])

    def test_attack_menu_routes_motion_without_touching_board(self):
        screen = _InputHarness()
        screen._attack_menu_open = True

        screen.handle_event(pygame.event.Event(pygame.MOUSEMOTION, {"pos": (45, 60)}))

        self.assertEqual(screen._attack_menu_hover, 2)
        self.assertEqual(screen.calls, [("attack_hover", (45, 60))])

    def test_board_uses_setup_player_then_active_player(self):
        screen = _InputHarness()
        screen.state.phase = TurnPhase.SETUP
        screen.handle_event(pygame.event.Event(pygame.MOUSEMOTION, {"pos": (1, 2)}))

        screen.state.phase = TurnPhase.MAIN
        screen.handle_event(pygame.event.Event(pygame.MOUSEMOTION, {"pos": (3, 4)}))

        self.assertEqual(
            screen.calls,
            [("board_hover", (1, 2), 0), ("board_hover", (3, 4), 1)],
        )

    def test_end_turn_shortcut_keeps_existing_action_contract(self):
        screen = _InputHarness()

        screen.handle_event(pygame.event.Event(pygame.KEYDOWN, {"key": pygame.K_e}))

        self.assertEqual(screen.calls, [("action", PlayerAction.END_TURN, 1)])

    def test_mouse_wheel_uses_live_mouse_position_without_event_pos(self):
        screen = _InputHarness()
        event = pygame.event.Event(pygame.MOUSEWHEEL, {"x": 0, "y": -1})

        with mock.patch(
            "pygame.mouse.get_pos",
            return_value=(SCREEN_WIDTH - LOG_W, 20),
        ):
            screen.handle_event(event)

        self.assertEqual(screen._log_scroll_offset, 1)

    def test_mouse_wheel_prefers_virtual_position_added_by_game_app(self):
        screen = _InputHarness()
        screen._log_scroll_offset = 4
        event = pygame.event.Event(
            pygame.MOUSEWHEEL,
            {
                "x": 0,
                "y": 1,
                "pos": (SCREEN_WIDTH - LOG_W, 20),
            },
        )

        with mock.patch("pygame.mouse.get_pos", return_value=(0, 0)) as get_pos:
            screen.handle_event(event)

        get_pos.assert_not_called()
        self.assertEqual(screen._log_scroll_offset, 3)


if __name__ == "__main__":
    unittest.main()

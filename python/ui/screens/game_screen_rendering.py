"""Rendering dispatch for GameScreen."""
from __future__ import annotations

import pygame

from config import SCREEN_WIDTH, SCREEN_HEIGHT
from engine.enums import TurnPhase
from ui.components.action_menu import draw_ability_menu, draw_action_buttons, draw_attack_menu
from ui.components.board_renderer import (
    create_board_background,
    draw_bench_card,
    draw_divider,
    draw_field_pokemon,
    draw_field_tooltips,
    draw_opponent_deck,
    draw_opponent_discard,
    draw_opponent_side,
    draw_player_deck,
    draw_player_discard,
    draw_player_side,
    draw_setup_status,
    draw_stadium,
    get_card_image_surface,
    stadium_btn_rect,
    stadium_is_activatable,
)
from ui.components.game_layout import DIVIDER_H, DIVIDER_Y
from ui.components.hand_display import draw_hand, draw_hand_card
from ui.components.log_panel import draw_action_log


class GameScreenRenderingMixin:
    """Draw the board and route rendering calls to component modules."""

    def draw(self, surface: pygame.Surface) -> None:
        bg = create_board_background()
        surface.blit(bg, (0, 0))
        pygame.draw.rect(surface, (13, 16, 27), self.layout.side_panel, border_radius=8)
        pygame.draw.rect(surface, (54, 62, 88), self.layout.side_panel, 1, border_radius=8)

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
        self._draw_action_buttons(surface)
        self._draw_action_log(surface)
        self._draw_field_tooltips(surface)
        self._draw_card_action_menu(surface)

        self.card_fly.draw(surface)
        self.particles.draw(surface)

        if self._remote_update_fade > 0:
            alpha = int(self._remote_update_fade / 0.15 * 80)
            overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
            overlay.fill((0, 0, 0, alpha))
            surface.blit(overlay, (0, 0))

        self.coin_flip.draw(surface, self.font_info)

        if self.waiting_indicator.is_active:
            self.waiting_indicator.draw(
                surface,
                self.font_small,
                SCREEN_WIDTH // 2,
                DIVIDER_Y + DIVIDER_H // 2,
            )

        self._draw_shortcut_hints(surface)
        self.floating_text.draw(surface, self.font_body)
        self._draw_attack_menu(surface)
        self._draw_ability_menu(surface)
        self._draw_confirm_dialog(surface)

    def _draw_opponent_side(self, surface):
        hide_cards = self.state.phase == TurnPhase.SETUP
        draw_opponent_side(self, surface, hide_cards=hide_cards)

    def _draw_opponent_deck(self, surface):
        draw_opponent_deck(self, surface)

    def _draw_opponent_discard(self, surface):
        draw_opponent_discard(self, surface)

    def _draw_player_side(self, surface):
        draw_player_side(self, surface)

    def _draw_player_deck(self, surface):
        draw_player_deck(self, surface)

    def _draw_player_discard(self, surface):
        draw_player_discard(self, surface)

    def _draw_divider(self, surface):
        draw_divider(self, surface)

    def _stadium_is_activatable(self) -> bool:
        return stadium_is_activatable(self)

    def _stadium_btn_rect(self) -> pygame.Rect | None:
        return stadium_btn_rect(self)

    def _draw_stadium(self, surface):
        draw_stadium(self, surface)

    def _draw_setup_status(self, surface):
        draw_setup_status(self, surface)

    def _get_card_image_surface(
        self,
        card_name: str,
        target_w: int,
        target_h: int,
        card_id: str = "",
    ):
        return get_card_image_surface(self, card_name, target_w, target_h, card_id)

    def _draw_field_pokemon(self, surface, x, y, pokemon, is_opponent=False, hovered=False):
        draw_field_pokemon(self, surface, x, y, pokemon, is_opponent, hovered)

    def _draw_bench_card(self, surface, x, y, pokemon, hovered=False, selected=False):
        draw_bench_card(self, surface, x, y, pokemon, hovered, selected)

    def _draw_hand(self, surface, player):
        draw_hand(self, surface, player)

    def _draw_hand_card(self, surface, x, y, card, highlight=False):
        draw_hand_card(self, surface, x, y, card, highlight)

    def _draw_action_buttons(self, surface):
        draw_action_buttons(self, surface)

    def _draw_action_log(self, surface):
        draw_action_log(self, surface)

    def _draw_attack_menu(self, surface):
        draw_attack_menu(self, surface)

    def _draw_ability_menu(self, surface):
        draw_ability_menu(self, surface)

    def _draw_field_tooltips(self, surface):
        draw_field_tooltips(self, surface)

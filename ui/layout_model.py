"""Declarative layout model for the main battle board."""
from __future__ import annotations

from dataclasses import dataclass
import pygame

from config import SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT


@dataclass(frozen=True)
class GameBoardLayout:
    screen: pygame.Rect
    board: pygame.Rect
    side_panel: pygame.Rect
    action_panel: pygame.Rect
    detail_panel: pygame.Rect
    log_panel: pygame.Rect
    opponent_info: pygame.Rect
    opponent_bench: pygame.Rect
    opponent_active: pygame.Rect
    divider: pygame.Rect
    player_active: pygame.Rect
    player_bench: pygame.Rect
    player_info: pygame.Rect
    hand: pygame.Rect
    opponent_deck: pygame.Rect
    opponent_discard: pygame.Rect
    player_deck: pygame.Rect
    player_discard: pygame.Rect
    stadium: pygame.Rect
    concede_button: pygame.Rect
    quit_button: pygame.Rect

    active_size: tuple[int, int]
    bench_size: tuple[int, int]

    @classmethod
    def build(cls, width: int = SCREEN_WIDTH, height: int = SCREEN_HEIGHT) -> "GameBoardLayout":
        outer = pygame.Rect(0, 0, width, height)
        margin = 12
        side_w = 330
        gap = 10

        side = pygame.Rect(width - side_w - margin, margin, side_w, height - margin * 2)
        board = pygame.Rect(margin, margin, side.x - margin - gap, height - margin * 2)

        action_panel = pygame.Rect(side.x, side.y, side.w, 246)
        detail_panel = pygame.Rect(side.x, action_panel.bottom + 10, side.w, 300)
        log_panel = pygame.Rect(side.x, detail_panel.bottom + 10, side.w, side.bottom - detail_panel.bottom - 10)

        active_w, active_h = 138, 178
        bench_w, bench_h = 104, 138
        zone_w, zone_h = 104, 146

        info_h = 24
        bench_gap = 8
        active_gap = 9
        divider_h = 42
        hand_h = CARD_HEIGHT + 26

        opp_info = pygame.Rect(board.x + 12, board.y + 8, board.w - 24, info_h)
        opp_bench = pygame.Rect(board.x + 160, opp_info.bottom + 4, board.w - 320, bench_h)
        opp_active = pygame.Rect(board.centerx - active_w // 2, opp_bench.bottom + active_gap,
                                 active_w, active_h)
        divider_y = opp_active.bottom + 13
        divider = pygame.Rect(board.x + 6, divider_y, board.w - 12, divider_h)
        player_active = pygame.Rect(board.centerx - active_w // 2, divider.bottom + 13,
                                    active_w, active_h)
        player_bench = pygame.Rect(board.x + 160, player_active.bottom + active_gap,
                                   board.w - 320, bench_h)
        player_info = pygame.Rect(board.x + 12, player_bench.bottom + 4, board.w - 24, info_h)
        hand_y = min(height - margin - hand_h, player_info.bottom + 8)
        hand = pygame.Rect(board.x + 12, hand_y, board.w - 24, hand_h)

        left_zone_x = board.x + 24
        right_zone_x = board.right - zone_w - 24
        opp_deck = pygame.Rect(right_zone_x, opp_info.bottom + 6, zone_w, zone_h)
        opp_discard = pygame.Rect(right_zone_x, opp_deck.bottom + 10, zone_w, zone_h)
        player_discard = pygame.Rect(right_zone_x, player_active.y, zone_w, zone_h)
        player_deck = pygame.Rect(right_zone_x, player_discard.bottom + 10, zone_w, zone_h)
        stadium = pygame.Rect(left_zone_x, divider.y - CARD_HEIGHT // 2 + divider.h // 2,
                              CARD_WIDTH, CARD_HEIGHT)

        btn_size = 28
        quit_btn = pygame.Rect(divider.right - btn_size - 12,
                               divider.centery - btn_size // 2, btn_size, btn_size)
        concede_btn = pygame.Rect(quit_btn.x - btn_size - 8,
                                  quit_btn.y, btn_size, btn_size)

        return cls(
            screen=outer, board=board, side_panel=side,
            action_panel=action_panel, detail_panel=detail_panel, log_panel=log_panel,
            opponent_info=opp_info, opponent_bench=opp_bench, opponent_active=opp_active,
            divider=divider, player_active=player_active, player_bench=player_bench,
            player_info=player_info, hand=hand,
            opponent_deck=opp_deck, opponent_discard=opp_discard,
            player_deck=player_deck, player_discard=player_discard,
            stadium=stadium, concede_button=concede_btn, quit_button=quit_btn,
            active_size=(active_w, active_h), bench_size=(bench_w, bench_h),
        )

    def bench_slot(self, owner: str, idx: int) -> pygame.Rect:
        row = self.player_bench if owner == "player" else self.opponent_bench
        bench_w, bench_h = self.bench_size
        gap = 8
        total = 5 * bench_w + 4 * gap
        x0 = row.centerx - total // 2
        return pygame.Rect(x0 + idx * (bench_w + gap), row.y, bench_w, bench_h)

    def active_rect(self, owner: str) -> pygame.Rect:
        return self.player_active.copy() if owner == "player" else self.opponent_active.copy()


DEFAULT_GAME_LAYOUT = GameBoardLayout.build()

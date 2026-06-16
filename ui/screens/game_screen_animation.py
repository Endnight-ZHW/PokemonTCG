"""Card movement animation helpers for GameScreen."""
from __future__ import annotations

import pygame

from config import CARD_HEIGHT, CARD_WIDTH
from engine.enums import TurnPhase
from ui.audio_manager import get_audio
from ui.components.board_renderer import get_card_image_surface
from ui.components.game_layout import HAND_Y, PLAY_AREA_W


class GameScreenAnimationMixin:
    """Owns card draw/discard/mill animation triggers and change detection."""

    def _get_deck_pos(self, player_idx: int) -> tuple[int, int]:
        """Get the deck zone center for a given player."""
        player = self.state.get_player(player_idx)
        rect = self.layout.opponent_deck if player is self._get_opponent() else self.layout.player_deck
        return rect.center

    def _get_discard_pos(self, player_idx: int) -> tuple[int, int]:
        """Get the discard zone center for a given player."""
        player = self.state.get_player(player_idx)
        rect = self.layout.opponent_discard if player is self._get_opponent() else self.layout.player_discard
        return rect.center

    def _get_card_screen_pos(self, player_idx: int, slot: str) -> tuple[int, int] | None:
        """Get the screen-space center position of a card in a given slot."""
        if self.challenge_mode:
            is_opponent_view = player_idx == self.ai_player_idx
        else:
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

    @staticmethod
    def _same_card_ref(a, b) -> bool:
        """Compare cards by id when available, otherwise by normal equality."""
        if a is b:
            return True
        aid = getattr(a, "api_id", None)
        bid = getattr(b, "api_id", None)
        if aid and bid:
            return aid == bid
        return a == b

    @staticmethod
    def _card_anim_name(card) -> str | None:
        return card.name if hasattr(card, "name") else (str(card) if card else None)

    def _result_draw_cards(self, result, player, before_deck_count: int) -> list:
        """Return concrete drawn cards for animation, falling back to deck delta."""
        cards = list(getattr(result, "cards_drawn", None) or [])
        if cards:
            return cards
        deck_delta = max(0, before_deck_count - len(player.deck))
        if deck_delta <= 0 or not player.hand:
            return []
        draw_count = min(deck_delta, len(player.hand))
        return list(player.hand[-draw_count:])

    def _discard_source_positions(
        self,
        discard_cards: list,
        before_hand: list,
        before_layout: list,
        played_card=None,
        played_idx: int | None = None,
        fallback: tuple[float, float] | None = None,
    ) -> list[tuple[float, float]]:
        """Map discarded cards back to their pre-action hand positions."""
        fallback = fallback or (PLAY_AREA_W // 2, HAND_Y + CARD_HEIGHT // 2)
        used: set[int] = set()
        positions: list[tuple[float, float]] = []
        last_idx = len(discard_cards) - 1

        def center_for(idx: int) -> tuple[float, float] | None:
            if 0 <= idx < len(before_layout):
                x, y, _ = before_layout[idx]
                return (x + CARD_WIDTH // 2, y + CARD_HEIGHT // 2)
            return None

        for i, card in enumerate(discard_cards):
            source_idx = None
            is_played_card = (
                played_card is not None
                and played_idx is not None
                and i == last_idx
                and self._same_card_ref(card, played_card)
            )
            if is_played_card and played_idx not in used:
                source_idx = played_idx
                used.add(played_idx)

            if source_idx is None:
                for hand_idx, hand_card in enumerate(before_hand):
                    if hand_idx in used:
                        continue
                    if hand_idx == played_idx and i != last_idx:
                        continue
                    if self._same_card_ref(hand_card, card):
                        source_idx = hand_idx
                        used.add(hand_idx)
                        break

            center = center_for(source_idx) if source_idx is not None else None
            if center is None:
                center = (fallback[0] + (i % 3 - 1) * 10, fallback[1] + (i % 2) * 8)
            positions.append(center)
        return positions

    def _animate_discard_draw_sequence(
        self,
        player_idx: int,
        discard_cards: list,
        draw_cards: list,
        source_positions: list[tuple[float, float]] | None = None,
        discard_start_idx: int | None = None,
        draw_start_idx: int | None = None,
    ) -> None:
        """Animate discard(s) first, then the resulting draw(s)."""
        discard_cards = list(discard_cards or [])
        draw_cards = list(draw_cards or [])
        source_positions = source_positions or []
        animate_hand = self._should_animate_hand_for_player(player_idx)
        if animate_hand and discard_cards and draw_cards and draw_start_idx is not None:
            player = self.state.get_player(player_idx)
            hand_count = len(player.hand) if player else 0
            for offset in range(len(draw_cards)):
                idx = draw_start_idx + offset
                if 0 <= idx < hand_count:
                    self._hide_hand_index(player_idx, idx)

        def start_draws():
            for offset, draw_card in enumerate(draw_cards):
                hand_idx = draw_start_idx + offset if draw_start_idx is not None else None
                card_obj = draw_card if hasattr(draw_card, "api_id") else None
                self._animate_draw(
                    player_idx,
                    self._card_anim_name(draw_card),
                    card_obj,
                    hand_idx,
                )

        if not discard_cards:
            start_draws()
            return

        last_idx = len(discard_cards) - 1
        for i, discard_card in enumerate(discard_cards):
            if i < len(source_positions):
                src_x, src_y = source_positions[i]
            else:
                src_x, src_y = PLAY_AREA_W // 2, HAND_Y + CARD_HEIGHT // 2
            card_obj = discard_card if hasattr(discard_card, "api_id") else None
            discard_idx = discard_start_idx + i if discard_start_idx is not None else None
            self._animate_discard(
                player_idx,
                src_x,
                src_y,
                self._card_anim_name(discard_card),
                card_obj,
                on_complete=start_draws if i == last_idx else None,
                discard_idx=discard_idx,
            )

    def _animate_draw(
        self,
        player_idx: int,
        card_name: str = None,
        card_obj=None,
        hand_idx: int | None = None,
    ):
        """Animate a card being drawn from deck to hand."""
        if not self._should_animate_hand_for_player(player_idx):
            return

        deck_x, deck_y = self._get_deck_pos(player_idx)
        player = self.state.get_player(player_idx)
        if not player or not player.hand:
            return

        hand_count = len(player.hand)
        target_idx = hand_idx if hand_idx is not None else hand_count - 1
        if target_idx < 0 or target_idx >= hand_count:
            target_idx = hand_count - 1
        drawn_card = card_obj or player.hand[target_idx]
        if card_name is None and drawn_card is not None:
            card_name = drawn_card.name
        self._hide_hand_index(player_idx, target_idx)

        layout = self._get_hand_layout()
        if target_idx < len(layout):
            target_x, target_y, _ = layout[target_idx]
            target_x += CARD_WIDTH // 2
            target_y += CARD_HEIGHT // 2
        else:
            target_x = PLAY_AREA_W // 2
            target_y = HAND_Y + CARD_HEIGHT // 2

        w, h = CARD_WIDTH * 3 // 4, CARD_HEIGHT * 3 // 4
        if card_name:
            card_surf = get_card_image_surface(
                self, card_name, w, h, getattr(drawn_card, "api_id", "")
            )
        else:
            card_surf = None
        if card_surf is None and self.card_back_img:
            card_surf = pygame.transform.smoothscale(self.card_back_img, (w, h))
        if card_surf is None:
            card_surf = pygame.Surface((w, h), pygame.SRCALPHA)
            card_surf.fill((80, 100, 180, 240))

        def on_complete():
            self._unhide_hand_index(player_idx, target_idx)
            if get_audio():
                get_audio().play("card_place")

        delay = min(0.24, 0.06 * len(self.card_fly.active))
        self.card_fly.fly_from_deck(
            card_surf, deck_x, deck_y, target_x, target_y,
            duration=0.55,
            delay=delay,
            on_complete=on_complete,
        )
        self.draw_flash.trigger(duration=0.25)

    def _animate_discard(
        self,
        player_idx: int,
        source_x: int,
        source_y: int,
        card_name: str = None,
        card_obj=None,
        source_slot: str = None,
        on_complete=None,
        discard_idx: int | None = None,
    ):
        """Animate a card flying from play area to discard pile."""
        disc_x, disc_y = self._get_discard_pos(player_idx)

        if source_slot:
            pos = self._get_card_screen_pos(player_idx, source_slot)
            if pos:
                source_x, source_y = pos

        player = self.state.get_player(player_idx)
        hidden_idx = None
        if player and player.discard:
            hidden_idx = discard_idx if discard_idx is not None else len(player.discard) - 1
            if hidden_idx < 0 or hidden_idx >= len(player.discard):
                hidden_idx = len(player.discard) - 1
            self._hide_discard_index(player_idx, hidden_idx)

        w, h = CARD_WIDTH * 3 // 4, CARD_HEIGHT * 3 // 4
        if card_name:
            card_surf = get_card_image_surface(
                self, card_name, w, h, getattr(card_obj, "api_id", "")
            )
        else:
            card_surf = None
        if card_surf is None:
            card_surf = pygame.Surface((w, h), pygame.SRCALPHA)
            card_surf.fill((120, 90, 160, 240))

        def inner_on_complete():
            if hidden_idx is not None:
                self._unhide_discard_index(player_idx, hidden_idx)
            if on_complete:
                on_complete()

        delay = min(0.24, 0.06 * len(self.card_fly.active))
        self.card_fly.fly_to_discard(
            card_surf, source_x, source_y, disc_x, disc_y,
            duration=0.5, delay=delay, on_complete=inner_on_complete,
        )

    def _animate_mill(self, player_idx: int):
        """Animate a card being milled from deck directly to discard."""
        deck_x, deck_y = self._get_deck_pos(player_idx)
        disc_x, disc_y = self._get_discard_pos(player_idx)

        card_back_small = None
        if self.card_back_img:
            card_back_small = pygame.transform.smoothscale(
                self.card_back_img, (CARD_WIDTH // 2, CARD_HEIGHT // 2)
            )
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
        """Detect discard/mill/draw count changes and trigger animations."""
        if not self.state:
            return

        if self._remote_update_just_arrived:
            self._remote_update_just_arrived = False
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

            discard_delta = max(0, dc - last_dc)
            deck_delta = max(0, last_mc - mc)
            hand_delta = hc - last_hc
            action_source = self._last_action_source_for(pi)

            discarded = 0
            drawn = 0
            milled = 0

            looks_like_mill = (
                discard_delta > 0
                and deck_delta > 0
                and hand_delta == 0
                and discard_delta == deck_delta
                and not action_source
            )
            if looks_like_mill:
                milled = min(discard_delta, deck_delta)
            else:
                if deck_delta > 0 and (hand_delta > 0 or discard_delta > 0):
                    drawn = min(deck_delta, hc)
                if discard_delta > 0 and (hand_delta < 0 or drawn > 0 or action_source):
                    discarded = discard_delta

            if is_remote and pi != self.my_player_idx:
                drawn = 0
                discarded = 0
                milled = 0

            if discarded and drawn:
                src_x = PLAY_AREA_W // 2
                src_y = HAND_Y + CARD_HEIGHT // 2
                if action_source:
                    src_x, src_y = action_source
                    self._clear_last_action_context()

                discard_cards = list(player.discard[last_dc:dc])
                draw_start = max(0, len(player.hand) - drawn)
                draw_cards = list(player.hand[draw_start:])
                source_positions = [
                    (src_x + (i % 3 - 1) * 10, src_y + (i % 2) * 8)
                    for i in range(len(discard_cards))
                ]
                self._animate_discard_draw_sequence(
                    pi,
                    discard_cards,
                    draw_cards,
                    source_positions=source_positions,
                    discard_start_idx=last_dc,
                    draw_start_idx=draw_start,
                )
                self._last_action_card_name = None
                self._last_action_card_obj = None
            else:
                if drawn:
                    start = max(0, len(player.hand) - drawn)
                    for target_idx, card in enumerate(player.hand[start:], start):
                        self._animate_draw(pi, card.name, card, target_idx)
                if discarded:
                    src_x = PLAY_AREA_W // 2
                    src_y = HAND_Y + CARD_HEIGHT // 2
                    card_name = None
                    card_obj = None
                    if action_source:
                        src_x, src_y = action_source
                        card_name = self._last_action_card_name
                        card_obj = self._last_action_card_obj
                        self._clear_last_action_context()
                    discard_cards = list(player.discard[last_dc:dc])
                    for i, discard_card in enumerate(discard_cards):
                        anim_name = card_name or self._card_anim_name(discard_card)
                        anim_obj = card_obj or (discard_card if hasattr(discard_card, "api_id") else None)
                        self._animate_discard(
                            pi, src_x, src_y, anim_name, anim_obj,
                            discard_idx=last_dc + i,
                        )
                if milled:
                    for _ in range(milled):
                        self._animate_mill(pi)

            self._last_hand_counts[pi] = hc
            self._last_discard_counts[pi] = dc
            self._last_deck_counts[pi] = mc

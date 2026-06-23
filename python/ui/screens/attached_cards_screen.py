"""Read-only viewer for cards attached under a Pokemon in play."""
from __future__ import annotations

import pygame

from config import CARD_HEIGHT, CARD_WIDTH, SCREEN_HEIGHT, SCREEN_WIDTH
from ui.colors import (
    TYPE_COLORS,
    UI_BG_DARK,
    UI_BORDER,
    UI_HIGHLIGHT,
    UI_TEXT_PRIMARY,
    UI_TEXT_SECONDARY,
)
from ui.font_manager import get_font
from ui.image_manager import get_image_manager
from ui.screen_manager import Screen, ScreenManager
from ui.ui_theme import draw_button, draw_panel, draw_text_fit


class AttachedCardsScreen(Screen):
    """Read-only view of a Pokemon's evolution stack, energy, and tool cards."""

    CARD_GAP = 16
    COLS = 5

    def __init__(
        self,
        manager: ScreenManager,
        title: str,
        pokemon_name: str,
        sections: list[tuple[str, list]],
    ):
        super().__init__(manager)
        self.title = title
        self.pokemon_name = pokemon_name
        self.sections = sections
        self.image_mgr = get_image_manager()

        self.font_title = get_font("heading")
        self.font_body = get_font("info")
        self.font_small = get_font("card_name")
        self.font_caption = get_font("caption")

        btn_w, btn_h = 180, 42
        self.close_btn = pygame.Rect(
            (SCREEN_WIDTH - btn_w) // 2,
            SCREEN_HEIGHT - 78,
            btn_w,
            btn_h,
        )
        self.close_hover = False
        self.hovered_card = None
        self.scroll_offset = 0
        self._card_positions: list[tuple[pygame.Rect, object]] = []

    def handle_event(self, event: pygame.event.Event):
        if event.type == pygame.MOUSEMOTION:
            self.close_hover = self.close_btn.collidepoint(event.pos)
            self._update_card_hover(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self.close_btn.collidepoint(event.pos):
                self.manager.pop_screen()
        elif event.type == pygame.MOUSEWHEEL:
            self.scroll_offset = max(0, self.scroll_offset - event.y * 36)
        elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
            self.manager.pop_screen()

    def update(self, dt: float):
        pass

    def draw(self, surface: pygame.Surface):
        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((6, 8, 16, 220))
        surface.blit(overlay, (0, 0))

        panel_rect = pygame.Rect(30, 24, SCREEN_WIDTH - 60, SCREEN_HEIGHT - 48)
        inner = draw_panel(surface, panel_rect)

        title = self.font_title.render(self.title, True, UI_HIGHLIGHT)
        surface.blit(title, (inner.x, inner.y))
        name_rect = pygame.Rect(inner.x, inner.y + 34, inner.w - 220, 24)
        draw_text_fit(
            surface,
            self.font_body,
            self.pokemon_name,
            UI_TEXT_PRIMARY,
            name_rect,
        )
        hint = self.font_small.render("只读查看 | ESC关闭", True, UI_TEXT_SECONDARY)
        surface.blit(hint, (inner.right - hint.get_width(), inner.y + 40))

        content_rect = pygame.Rect(inner.x, inner.y + 72, inner.w, inner.h - 122)
        self._draw_sections(surface, content_rect)

        if self.hovered_card is not None:
            self._draw_magnified_card(surface, self.hovered_card)

        draw_button(
            surface,
            self.close_btn,
            "关闭",
            self.font_body,
            hovered=self.close_hover,
        )

    def _draw_sections(self, surface: pygame.Surface, content_rect: pygame.Rect):
        self._card_positions = []
        y = content_rect.y - self.scroll_offset
        any_cards = any(cards for _, cards in self.sections)

        if not any_cards:
            empty_rect = pygame.Rect(
                content_rect.x + 32,
                content_rect.y + 70,
                content_rect.w - 64,
                120,
            )
            pygame.draw.rect(surface, (26, 30, 46), empty_rect, border_radius=8)
            pygame.draw.rect(surface, UI_BORDER, empty_rect, 1, border_radius=8)
            empty = self.font_body.render("没有附属卡", True, UI_TEXT_SECONDARY)
            surface.blit(empty, empty.get_rect(center=empty_rect.center))
            return

        viewport = content_rect.inflate(0, 8)
        for label, cards in self.sections:
            header_rect = pygame.Rect(content_rect.x, y, content_rect.w, 28)
            if header_rect.bottom >= content_rect.y and header_rect.y <= content_rect.bottom:
                count = self.font_small.render(f"{label} ({len(cards)})", True, UI_HIGHLIGHT)
                surface.blit(count, (header_rect.x, header_rect.y + 4))
                pygame.draw.line(
                    surface,
                    (52, 60, 88),
                    (header_rect.x, header_rect.bottom),
                    (header_rect.right, header_rect.bottom),
                    1,
                )
            y += 38

            if not cards:
                note_rect = pygame.Rect(content_rect.x + 6, y, content_rect.w - 12, 28)
                if note_rect.colliderect(viewport):
                    note = self.font_caption.render("无", True, UI_TEXT_SECONDARY)
                    surface.blit(note, (note_rect.x, note_rect.y + 5))
                y += 42
                continue

            rows = (len(cards) + self.COLS - 1) // self.COLS
            for idx, card in enumerate(cards):
                col = idx % self.COLS
                row = idx // self.COLS
                x = content_rect.x + col * (CARD_WIDTH + self.CARD_GAP)
                card_y = y + row * (CARD_HEIGHT + self.CARD_GAP)
                rect = pygame.Rect(x, card_y, CARD_WIDTH, CARD_HEIGHT)
                if rect.colliderect(viewport):
                    is_hover = self.hovered_card is card
                    self._draw_mini_card(surface, rect, card, is_hover)
                    self._card_positions.append((rect, card))
            y += rows * (CARD_HEIGHT + self.CARD_GAP) + 28

    def _update_card_hover(self, pos):
        self.hovered_card = None
        for rect, card in self._card_positions:
            if rect.collidepoint(pos):
                self.hovered_card = card
                return

    def _resolve_card(self, card):
        if isinstance(card, str):
            from data.card_registry import CardRegistry

            resolved = CardRegistry.get(card)
            return resolved or card
        return card

    def _draw_mini_card(self, surface: pygame.Surface, rect: pygame.Rect, card, hover: bool):
        card = self._resolve_card(card)
        card_name = getattr(card, "name", str(card))
        card_id = getattr(card, "api_id", "")
        img = self.image_mgr.get_card_image(card_name, card_id)

        lift = 5 if hover else 0
        draw_rect = rect.move(0, -lift)
        shadow = draw_rect.move(3, 5)
        pygame.draw.rect(surface, (0, 0, 0, 80), shadow, border_radius=6)

        if img is not None:
            scaled = pygame.transform.smoothscale(img, draw_rect.size)
            pygame.draw.rect(surface, (18, 20, 28), draw_rect, border_radius=6)
            surface.blit(scaled, draw_rect.topleft)
        else:
            color = self._fallback_color(card)
            pygame.draw.rect(surface, color, draw_rect, border_radius=6)
            label_rect = draw_rect.inflate(-10, -10)
            draw_text_fit(surface, self.font_small, card_name, UI_TEXT_PRIMARY, label_rect)

        border = UI_HIGHLIGHT if hover else UI_BORDER
        pygame.draw.rect(surface, border, draw_rect, 2 if hover else 1, border_radius=6)

    def _draw_magnified_card(self, surface: pygame.Surface, card):
        card = self._resolve_card(card)
        card_name = getattr(card, "name", str(card))
        card_id = getattr(card, "api_id", "")
        panel_w = 330
        panel_rect = pygame.Rect(SCREEN_WIDTH - panel_w - 42, 92, panel_w, SCREEN_HEIGHT - 178)
        inner = draw_panel(surface, panel_rect)

        img = self.image_mgr.get_card_image(card_name, card_id)
        if img is not None:
            iw, ih = img.get_size()
            target_h = min(330, inner.h - 82)
            scale = target_h / max(1, ih)
            target_w = int(iw * scale)
            image_rect = pygame.Rect(
                inner.centerx - target_w // 2,
                inner.y,
                target_w,
                target_h,
            )
            scaled = pygame.transform.smoothscale(img, image_rect.size)
            pygame.draw.rect(surface, (18, 20, 28), image_rect.inflate(6, 6), border_radius=8)
            surface.blit(scaled, image_rect.topleft)
            pygame.draw.rect(surface, UI_HIGHLIGHT, image_rect, 2, border_radius=6)
            text_y = image_rect.bottom + 14
        else:
            image_rect = pygame.Rect(inner.centerx - 92, inner.y, 184, 252)
            pygame.draw.rect(surface, self._fallback_color(card), image_rect, border_radius=8)
            pygame.draw.rect(surface, UI_HIGHLIGHT, image_rect, 2, border_radius=8)
            text_y = image_rect.bottom + 14

        name_rect = pygame.Rect(inner.x, text_y, inner.w, 28)
        draw_text_fit(surface, self.font_body, card_name, UI_HIGHLIGHT, name_rect, align="center")

        details = self._card_details(card)
        y = text_y + 36
        for line in details[:6]:
            line_rect = pygame.Rect(inner.x, y, inner.w, 20)
            draw_text_fit(surface, self.font_caption, line, UI_TEXT_SECONDARY, line_rect)
            y += 21

    def _card_details(self, card) -> list[str]:
        details = []
        supertype = getattr(card, "supertype", "")
        subtypes = getattr(card, "subtypes", [])
        if supertype:
            details.append(supertype)
        if subtypes:
            details.append(" / ".join(subtypes))
        if getattr(card, "is_pokemon", False) and getattr(card, "hp", 0):
            details.append(f"HP {card.hp}")
        if getattr(card, "is_energy", False) and hasattr(card, "provides_energy"):
            details.append("提供: " + ", ".join(card.provides_energy))
        trainer_text = getattr(card, "trainer_text", "")
        if trainer_text:
            details.append(trainer_text)
        return details

    def _fallback_color(self, card) -> tuple[int, int, int]:
        if getattr(card, "is_pokemon", False):
            energy_types = getattr(card, "energy_types", [])
            return TYPE_COLORS.get(energy_types[0] if energy_types else "Colorless", TYPE_COLORS["Colorless"])
        if getattr(card, "is_trainer", False):
            return TYPE_COLORS["Trainer"]
        if getattr(card, "is_energy", False):
            return TYPE_COLORS["Energy"]
        return UI_BG_DARK

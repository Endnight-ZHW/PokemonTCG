"""Energy distribution screen — energy cards on top, target Pokemon below.

Shows source Pokemon's energy cards as clickable mini-cards in a horizontal
row at the top. Target Pokemon are shown below. Player clicks an energy card
to select it, then clicks a target Pokemon to assign it there.

Supports two modes:
- 'distribute': all energy must be distributed (代欧奇希斯)
- 'paired': select energy then target, one pair at a time (波琵)
"""
from __future__ import annotations
import pygame
from typing import Optional, Callable

from ui.screen_manager import Screen
from ui.colors import (
    UI_BG_DARK, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
    UI_HIGHLIGHT, UI_BORDER,
    TYPE_COLORS,
)
from ui.image_manager import get_image_manager
from ui.energy_icons import draw_energy_icon
from ui.font_manager import get_font
from ui.ui_theme import draw_panel, draw_button
from config import SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT
from data.card_models import Card


class EnergyDistributionScreen(Screen):
    """Modal screen for distributing energy cards to Pokemon."""

    def __init__(self, manager, request, on_complete: Callable,
                 on_cancel: Optional[Callable] = None):
        super().__init__(manager)
        self.request = request
        self.on_complete = on_complete
        self.on_cancel = on_cancel
        self.image_mgr = get_image_manager()
        self.font_title = get_font("heading")
        self.font_body = get_font("info")
        self.font_small = get_font("card_name")

        # Energy cards to distribute
        self.energy_cards: list[Card] = list(request.get("energy_cards", []))
        # Target Pokemon: list of (slot_name, card_name, bench_index)
        self.targets: list[dict] = request.get("targets", [])
        # Mode: 'distribute' (all energy) or 'paired' (select N, assign to 1 target)
        self.mode: str = request.get("mode", "distribute")
        self.max_per_target: int = request.get("max_per_target", 99)
        self.source_name: str = request.get("source_name", "")

        # Selection state
        self.selected_energy_idx: int | None = None
        self._assigned: list[tuple[int, int]] = []  # [(energy_idx, target_idx), ...]
        self._hovered_energy: int | None = None
        self._hovered_target: int | None = None

        # Layout computed in draw
        self._energy_rects: list[pygame.Rect] = []
        self._target_rects: list[pygame.Rect] = []

        # Buttons
        btn_w, btn_h = 160, 42
        self.confirm_btn = pygame.Rect(
            SCREEN_WIDTH // 2 - btn_w - 20, SCREEN_HEIGHT - 100, btn_w, btn_h
        )
        self.cancel_btn = pygame.Rect(
            SCREEN_WIDTH // 2 + 20, SCREEN_HEIGHT - 100, btn_w, btn_h
        )
        self._confirm_hover = False
        self._cancel_hover = False

    # ── Event handling ──────────────────────────────────────

    def handle_event(self, event: pygame.event.Event):
        is_source_select = (self.mode == "source_select")

        if event.type == pygame.MOUSEMOTION:
            self._confirm_hover = self.confirm_btn.collidepoint(event.pos)
            self._cancel_hover = self.cancel_btn.collidepoint(event.pos)
            self._update_hover(event.pos)

        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            pos = event.pos
            if self._confirm_hover:
                self._confirm()
            elif self._cancel_hover:
                self._cancel()
            elif is_source_select and self._hovered_target is not None:
                # Source select mode: clicking a target selects it and confirms
                self._assigned = [(0, self._hovered_target)]
                self._confirm()
            elif self._hovered_energy is not None:
                if self.selected_energy_idx == self._hovered_energy:
                    self.selected_energy_idx = None
                else:
                    self.selected_energy_idx = self._hovered_energy
            elif self._hovered_target is not None and self.selected_energy_idx is not None:
                self._assign(self.selected_energy_idx, self._hovered_target)
                self.selected_energy_idx = None

        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                self._cancel()
            elif event.key == pygame.K_RETURN:
                self._confirm()

    def update(self, dt: float):
        pass

    # ── Layout & hover ──────────────────────────────────────

    def _update_hover(self, pos):
        self._hovered_energy = None
        self._hovered_target = None
        for i, r in enumerate(self._energy_rects):
            if r.collidepoint(pos):
                self._hovered_energy = i
                return
        for i, r in enumerate(self._target_rects):
            if r.collidepoint(pos):
                self._hovered_target = i
                return

    def _assign(self, energy_idx: int, target_idx: int):
        """Assign an energy card to a target Pokemon."""
        # Check limit per target (for paired mode)
        if self.mode == "paired":
            count_for_target = sum(1 for _, ti in self._assigned if ti == target_idx)
            if count_for_target >= self.max_per_target:
                return
        self._assigned.append((energy_idx, target_idx))

    def _confirm(self):
        """Finish distribution and call on_complete."""
        # Build result: list of (energy_card_index, target_slot_name)
        result = []
        for ei, ti in self._assigned:
            target_info = self.targets[ti] if ti < len(self.targets) else None
            if target_info:
                result.append((ei, target_info["slot"]))
        self.manager.pop_screen()
        self.on_complete(result)

    def _cancel(self):
        self.manager.pop_screen()
        if self.on_cancel:
            self.on_cancel()

    # ── Drawing ─────────────────────────────────────────────

    def draw(self, surface: pygame.Surface):
        # Dark overlay
        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((8, 10, 18, 220))
        surface.blit(overlay, (0, 0))
        draw_panel(surface, pygame.Rect(28, 22, SCREEN_WIDTH - 56, SCREEN_HEIGHT - 44))

        # Title
        title_txt = self.font_title.render(
            f"分配能量 — {self.source_name}", True, UI_HIGHLIGHT
        )
        surface.blit(title_txt, (40, 20))

        is_source_select = (self.mode == "source_select")

        # Prompt
        if is_source_select:
            prompt = "点击有能量的宝可梦选择来源"
        elif self.selected_energy_idx is not None:
            card = self.energy_cards[self.selected_energy_idx]
            etype = "/".join(card.provides_energy) if card.provides_energy else "?"
            prompt = f"已选择: {card.name}({etype}) — 点击下方宝可梦分配"
        else:
            unassigned = len(self.energy_cards) - len(self._assigned)
            prompt = f"点击能量卡选择，再点击宝可梦分配（剩余 {unassigned}）"
        prompt_txt = self.font_body.render(prompt, True, UI_TEXT_SECONDARY)
        surface.blit(prompt_txt, (40, 56))

        # ═══ Energy cards row (top) — hidden in source_select mode ═══
        self._energy_rects.clear()
        if not is_source_select:
            ey = 90
            energy_label = self.font_small.render("▼ 待分配的能量卡 ▼", True, (180, 180, 200))
            surface.blit(energy_label, (40, ey))
            ey += 22

            assigned_set = set(ei for ei, _ in self._assigned)
            for i, card in enumerate(self.energy_cards):
                ex = 50 + i * (CARD_WIDTH + 14)
                rect = pygame.Rect(ex, ey, CARD_WIDTH, CARD_HEIGHT)
                self._energy_rects.append(rect)

                is_assigned = i in assigned_set
                is_selected = i == self.selected_energy_idx
                is_hover = i == self._hovered_energy
                self._draw_energy_card(surface, rect, card, is_assigned, is_selected, is_hover)
        else:
            ey = 55

        # ═══ Target Pokemon row (bottom) ═══
        self._target_rects.clear()
        ty = ey + CARD_HEIGHT + 30
        target_label_text = "▼ 选择宝可梦 ▼" if is_source_select else "▼ 目标宝可梦 ▼"
        target_label = self.font_small.render(target_label_text, True, (180, 180, 200))
        surface.blit(target_label, (40, ty))
        ty += 24

        for i, tgt in enumerate(self.targets):
            tx = 50 + i * (CARD_WIDTH + 14)
            rect = pygame.Rect(tx, ty, CARD_WIDTH, CARD_HEIGHT)
            self._target_rects.append(rect)

            count = sum(1 for _, ti in self._assigned if ti == i)
            is_hover = i == self._hovered_target
            self._draw_target_card(surface, rect, tgt["name"], count, is_hover)

        # ═══ Buttons ═══
        draw_button(surface, self.confirm_btn, "确认", self.font_body,
                    hovered=self._confirm_hover)

        draw_button(surface, self.cancel_btn, "取消", self.font_body,
                    hovered=self._cancel_hover, danger=True)

    def _draw_energy_card(self, surface, rect, card, assigned, selected, hover):
        """Draw a single energy card in the distribution row."""
        draw_rect = rect.copy()
        if selected:
            draw_rect.y -= 8
        elif hover:
            draw_rect.y -= 3

        x, y, w, h = draw_rect

        shadow = pygame.Surface((w + 8, h + 8), pygame.SRCALPHA)
        pygame.draw.rect(shadow, (0, 0, 0, 95), shadow.get_rect(), border_radius=8)
        surface.blit(shadow, (x - 2, y + 4))

        # Try card image
        img = self.image_mgr.get_card_image(card.name, card.api_id)
        if img:
            scaled = pygame.transform.smoothscale(img, (w, h))
            surface.blit(scaled, (x, y))
        else:
            # Fallback colored rect
            bg = TYPE_COLORS["Energy"]
            pygame.draw.rect(surface, bg, rect, border_radius=6)
            name = self.font_small.render(card.name[:6], True, (255, 255, 255))
            surface.blit(name, (x + 3, y + 3))
            etype = "/".join(card.provides_energy[:2]) if card.provides_energy else ""
            if etype:
                et = self.font_small.render(etype, True, (220, 220, 220))
                surface.blit(et, (x + 3, y + 22))

        if assigned:
            alpha_surf = pygame.Surface((w, h), pygame.SRCALPHA)
            alpha_surf.fill((8, 10, 18, 165))
            surface.blit(alpha_surf, (x, y))
            name = self.font_small.render("已分配", True, (180, 180, 190))
            surface.blit(name, name.get_rect(center=draw_rect.center))

        icon_center = (draw_rect.right - 18, draw_rect.bottom - 18)
        draw_energy_icon(surface, self.image_mgr, card, icon_center, 28, self.font_small)

        # Border
        if selected:
            border_c = UI_HIGHLIGHT
            border_w = 3
        elif hover:
            border_c = (200, 200, 100)
            border_w = 2
        else:
            border_c = UI_BORDER
            border_w = 1
        pygame.draw.rect(surface, border_c, draw_rect, border_w, border_radius=6)

    def _draw_target_card(self, surface, rect, name, assigned_count, hover):
        """Draw a target Pokemon card."""
        x, y, w, h = rect

        # Try to get card image by name
        from data.card_registry import CardRegistry
        cards = CardRegistry.get_by_name(name)
        img = None
        if cards:
            img = self.image_mgr.get_card_image(cards[0].name, cards[0].api_id)

        if img:
            scaled = pygame.transform.smoothscale(img, (w, h))
            surface.blit(scaled, (x, y))
        else:
            bg = TYPE_COLORS["Colorless"]
            pygame.draw.rect(surface, bg, rect, border_radius=6)
            nt = self.font_small.render(name[:6], True, (255, 255, 255))
            surface.blit(nt, (x + 3, y + 3))

        # Assigned count badge
        if assigned_count > 0:
            badge = self.font_small.render(f"+{assigned_count}", True, UI_HIGHLIGHT)
            bx = x + w - badge.get_width() - 6
            by = y + h - badge.get_height() - 6
            pygame.draw.rect(surface, (20, 20, 30),
                             (bx - 2, by - 2, badge.get_width() + 4, badge.get_height() + 4),
                             border_radius=3)
            surface.blit(badge, (bx, by))

        # Border
        border_c = UI_HIGHLIGHT if hover else UI_BORDER
        border_w = 3 if hover else 1
        pygame.draw.rect(surface, border_c, rect, border_w, border_radius=6)

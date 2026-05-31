"""搜索画面——卡组/弃牌区浏览器."""
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_BG_DARK, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
    UI_HIGHLIGHT, UI_BORDER, TYPE_COLORS,
)
from ui.image_manager import get_image_manager
from ui.font_manager import get_font, get_font_size
from ui.ui_theme import draw_panel, draw_button
from config import SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT
from engine.game_state import ActionRequest


class SearchScreen(Screen):
    """搜索卡组/弃牌区并选择卡牌的叠加画面."""

    def __init__(self, manager: ScreenManager, request: ActionRequest,
                 on_complete: callable, chain_handler: callable = None,
                 on_cancel: callable = None):
        super().__init__(manager)
        self.request = request
        self.on_complete = on_complete
        self.chain_handler = chain_handler  # For forwarding non-search actions to game_screen
        self.on_cancel = on_cancel
        self.font_title = get_font("heading")
        self.font_body = get_font("info")
        self.font_small = get_font("card_name")

        self.selected_indices: list[int] = []
        self.hovered_idx: int | None = None
        self.scroll_offset = 0

        btn_w, btn_h = 200, 45
        self.confirm_btn = pygame.Rect(
            (SCREEN_WIDTH - btn_w) // 2, SCREEN_HEIGHT - 100, btn_w, btn_h
        )
        self.cancel_btn = pygame.Rect(
            (SCREEN_WIDTH - btn_w) // 2, SCREEN_HEIGHT - 150, btn_w, btn_h
        )
        self.confirm_hover = False
        self.cancel_hover = False

        self.image_mgr = get_image_manager()

    def handle_event(self, event: pygame.event.Event):
        is_readonly = self.request.max_select <= 0
        if event.type == pygame.MOUSEMOTION:
            self.confirm_hover = self.confirm_btn.collidepoint(event.pos)
            self.cancel_hover = self.cancel_btn.collidepoint(event.pos)
            self._update_card_hover(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            pos = event.pos
            if is_readonly and self.confirm_hover:
                self.manager.pop_screen()
            elif self.confirm_hover:
                self._confirm_selection()
            elif self.cancel_hover:
                if self.on_cancel:
                    self.on_cancel()
                self.manager.pop_screen()
            else:
                self._handle_card_click(pos)
        elif event.type == pygame.MOUSEWHEEL:
            self.scroll_offset = max(0, self.scroll_offset - event.y * 30)
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                if self.on_cancel:
                    self.on_cancel()
                self.manager.pop_screen()

    def _update_card_hover(self, pos):
        self.hovered_idx = None
        x_start = 50
        y_start = 120
        cols = 5
        for i, card in enumerate(self.request.card_list):
            col = i % cols
            row = i // cols
            card_x = x_start + col * (CARD_WIDTH + 15)
            card_y = y_start + row * (CARD_HEIGHT + 15) - self.scroll_offset
            rect = pygame.Rect(card_x, card_y, CARD_WIDTH, CARD_HEIGHT)
            if rect.collidepoint(pos):
                self.hovered_idx = i
                return

    def _handle_card_click(self, pos):
        if self.hovered_idx is None:
            return
        # Read-only mode: no selection
        if self.request.max_select <= 0:
            return
        idx = self.hovered_idx
        if idx in self.selected_indices:
            self.selected_indices.remove(idx)
        else:
            max_sel = self.request.max_select
            if len(self.selected_indices) >= max_sel:
                self.selected_indices.pop(0)
            self.selected_indices.append(idx)

    def _confirm_selection(self):
        selected_cards = [
            self.request.card_list[i]
            for i in self.selected_indices
            if i < len(self.request.card_list)
        ]
        result = self.on_complete(selected_cards)
        # If callback returns a new ActionRequest, chain into it
        if result is not None and isinstance(result, ActionRequest):
            if result.request_type in ("search_deck", "select_hand_to_discard"):
                self._reinit_with_request(result)
            elif self.chain_handler:
                self.manager.pop_screen()
                self.chain_handler(result)
            else:
                self.manager.pop_screen()
        else:
            self.manager.pop_screen()

    def _reinit_with_request(self, request: ActionRequest):
        """Re-initialize this screen with a new search request (chained effects)."""
        self.request = request
        self.selected_indices.clear()
        self.hovered_idx = None
        self.scroll_offset = 0
        self.on_complete = request.callback or (lambda cards: None)

    def update(self, dt: float):
        pass

    def draw(self, surface: pygame.Surface):
        overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        overlay.fill((8, 10, 18, 225))
        surface.blit(overlay, (0, 0))
        content_rect = pygame.Rect(28, 22, SCREEN_WIDTH - 56, SCREEN_HEIGHT - 44)
        draw_panel(surface, content_rect)

        title_txt = self.font_title.render(self.request.prompt, True, UI_HIGHLIGHT)
        surface.blit(title_txt, (50, 30))

        is_readonly = self.request.max_select <= 0
        if is_readonly:
            sub_txt = self.font_small.render(
                "只读查看 | ESC关闭",
                True, UI_TEXT_SECONDARY
            )
        else:
            sub_txt = self.font_small.render(
                f"已选择: {len(self.selected_indices)}/{self.request.max_select}  "
                f"| ESC取消 | 点击卡牌选择",
                True, UI_TEXT_SECONDARY
            )
        surface.blit(sub_txt, (50, 70))

        cols = 5
        for i, card in enumerate(self.request.card_list):
            col = i % cols
            row = i // cols
            card_x = 50 + col * (CARD_WIDTH + 15)
            card_y = 120 + row * (CARD_HEIGHT + 15) - self.scroll_offset

            if card_y + CARD_HEIGHT < 80 or card_y > SCREEN_HEIGHT - 120:
                continue

            is_selected = i in self.selected_indices
            is_hover = i == self.hovered_idx
            self._draw_mini_card(surface, card_x, card_y, card, is_selected, is_hover)

        # Confirm button (hidden in read-only mode)
        if not is_readonly:
            draw_button(surface, self.confirm_btn, "确认", self.font_body,
                        hovered=self.confirm_hover)

        # Magnified card preview on hover
        if self.hovered_idx is not None and self.hovered_idx < len(self.request.card_list):
            self._draw_magnified_card(surface, self.request.card_list[self.hovered_idx])

        # Close / Cancel button
        close_rect = self.cancel_btn
        if is_readonly:
            # Center the close button where confirm button would be
            close_rect = self.confirm_btn
        label = "关 闭" if is_readonly else "取 消"
        draw_button(surface, close_rect, label, self.font_body,
                    hovered=(self.confirm_hover if is_readonly else self.cancel_hover),
                    danger=not is_readonly)

    def _draw_mini_card(self, surface, x, y, card, selected=False, hover=False):
        # Resolve string card IDs from network deserialization first
        if isinstance(card, str):
            from data.card_registry import CardRegistry
            resolved = CardRegistry.get(card)
            if resolved:
                card = resolved

        card_name = card.name if hasattr(card, 'name') else str(card)
        card_id = card.api_id if hasattr(card, 'api_id') else ""
        img = self.image_mgr.get_card_image(card_name, card_id)
        if img is not None:
            scaled = pygame.transform.smoothscale(img, (CARD_WIDTH, CARD_HEIGHT))
            # Dark backdrop to prevent green board bleed-through at edges
            pygame.draw.rect(surface, (20, 20, 30), pygame.Rect(x, y, CARD_WIDTH, CARD_HEIGHT), border_radius=6)
            surface.blit(scaled, (x, y))
            border_c = UI_HIGHLIGHT if selected else (UI_HIGHLIGHT if hover else UI_BORDER)
            border_w = 3 if (selected or hover) else 1
            pygame.draw.rect(surface, border_c, pygame.Rect(x, y, CARD_WIDTH, CARD_HEIGHT), border_w, border_radius=6)
            return

        if hasattr(card, 'is_pokemon') and card.is_pokemon and card.energy_types:
            bg = TYPE_COLORS.get(card.energy_types[0], TYPE_COLORS["Colorless"])
        elif hasattr(card, 'is_trainer') and card.is_trainer:
            bg = TYPE_COLORS["Trainer"]
        else:
            bg = TYPE_COLORS["Energy"]

        rect = pygame.Rect(x, y, CARD_WIDTH, CARD_HEIGHT)
        pygame.draw.rect(surface, bg, rect, border_radius=6)

        border_c = UI_HIGHLIGHT if selected else (UI_HIGHLIGHT if hover else UI_BORDER)
        border_w = 3 if (selected or hover) else 1
        pygame.draw.rect(surface, border_c, rect, border_w, border_radius=6)

        display_name = card_name[:8]
        name_txt = self.font_small.render(display_name, True, (255, 255, 255))
        surface.blit(name_txt, (x + 3, y + 3))

        if hasattr(card, 'is_pokemon') and card.is_pokemon:
            hp_txt = self.font_small.render(f"HP{card.hp}", True, (255, 255, 255))
            surface.blit(hp_txt, (x + CARD_WIDTH - 45, y + 3))

            if hasattr(card, 'subtypes') and card.subtypes:
                sub_cn = {"Basic": "基础", "Stage 1": "1阶", "Stage 2": "2阶"}
                subtype_name = card.subtypes[0] if card.subtypes else ""
                st = sub_cn.get(subtype_name, subtype_name)
                subtype_txt = self.font_small.render(st, True, (220, 220, 220))
                surface.blit(subtype_txt, (x + 3, y + 20))
        elif hasattr(card, 'is_trainer') and card.is_trainer:
            sub_cn2 = {"Item": "物品", "Supporter": "支援者", "Stadium": "竞技场", "Tool": "道具"}
            if hasattr(card, 'subtypes') and card.subtypes:
                st2 = sub_cn2.get(card.subtypes[0], card.subtypes[0])
            else:
                st2 = "训练家"
            sub_txt = self.font_small.render(st2, True, (60, 60, 80))
            surface.blit(sub_txt, (x + 3, y + 25))

    def _draw_magnified_card(self, surface, card):
        """Draw a larger card preview and details on the right side of the screen."""
        if isinstance(card, str):
            from data.card_registry import CardRegistry
            resolved = CardRegistry.get(card)
            if resolved:
                card = resolved

        card_name = card.name if hasattr(card, 'name') else str(card)
        card_id = card.api_id if hasattr(card, 'api_id') else ""

        # Position panel: leave 40px right margin
        MAG_H = 260
        PANEL_W = 400
        MAG_X = SCREEN_WIDTH - PANEL_W - 40
        MAG_Y = 80

        # Dark backdrop for the whole detail panel
        panel_rect = pygame.Rect(MAG_X - 8, MAG_Y - 8, PANEL_W + 16, SCREEN_HEIGHT - MAG_Y - 40)
        draw_panel(surface, panel_rect)

        # Card image
        img = self.image_mgr.get_card_image(card_name, card_id)
        if img is not None:
            iw, ih = img.get_size()
            scale = MAG_H / ih
            mw, mh = int(iw * scale), MAG_H
            try:
                scaled = pygame.transform.smoothscale(img, (mw, mh))
            except Exception:
                scaled = None
            if scaled:
                # Center image within panel
                img_x = MAG_X + (PANEL_W - mw) // 2
                pygame.draw.rect(surface, (20, 20, 30),
                                 (img_x - 3, MAG_Y - 3, mw + 6, mh + 6), border_radius=6)
                surface.blit(scaled, (img_x, MAG_Y))
                pygame.draw.rect(surface, (255, 255, 255),
                                 (img_x, MAG_Y, mw, mh), 2, border_radius=6)
                details_y = MAG_Y + mh + 8
        else:
            # Fallback: colored placeholder
            placeholder_w, placeholder_h = 180, 240
            img_x = MAG_X + (PANEL_W - placeholder_w) // 2
            rect = pygame.Rect(img_x, MAG_Y, placeholder_w, placeholder_h)
            if hasattr(card, 'is_pokemon') and card.is_pokemon:
                bg_color = TYPE_COLORS.get(card.energy_types[0] if card.energy_types else "Colorless",
                                           TYPE_COLORS["Colorless"])
            elif hasattr(card, 'is_trainer') and card.is_trainer:
                bg_color = TYPE_COLORS["Trainer"]
            else:
                bg_color = TYPE_COLORS["Energy"]
            pygame.draw.rect(surface, bg_color, rect, border_radius=8)
            pygame.draw.rect(surface, (255, 255, 255), rect, 2, border_radius=8)
            name_surf = self.font_body.render(card_name, True, (255, 255, 255))
            surface.blit(name_surf, (img_x + 8, MAG_Y + 8))
            details_y = MAG_Y + placeholder_h + 8

        # Card name above details
        name_surf = self.font_body.render(card_name, True, UI_HIGHLIGHT)
        surface.blit(name_surf, (MAG_X + 4, details_y))
        details_y += 24

        # Divider
        pygame.draw.line(surface, (100, 100, 120),
                         (MAG_X, details_y), (MAG_X + PANEL_W, details_y), 1)
        details_y += 6

        self._draw_card_details(surface, card, MAG_X + 4, details_y, PANEL_W - 8)

    def _draw_card_details(self, surface, card, x, y, max_width):
        """Draw card text details with width-constrained wrapping."""
        lines = []
        line_color = (200, 200, 210)

        if hasattr(card, 'is_pokemon') and card.is_pokemon:
            if hasattr(card, 'hp') and card.hp:
                lines.append(f"HP {card.hp}")
            if hasattr(card, 'subtypes') and card.subtypes:
                sub_cn = {"Basic": "基础宝可梦", "Stage 1": "1阶进化", "Stage 2": "2阶进化"}
                st = sub_cn.get(card.subtypes[0], card.subtypes[0])
                if len(card.subtypes) > 1 and card.subtypes[1] == "ex":
                    st += " ex"
                lines.append(st)
            if hasattr(card, 'evolves_from') and card.evolves_from:
                lines.append(f"进化自: {card.evolves_from}")

            if hasattr(card, 'abilities') and card.abilities:
                for ab in card.abilities:
                    ab_text = getattr(ab, 'text', '') or ''
                    lines.append(f"【特性】{ab.name}")
                    if ab_text:
                        lines.append(f"  {ab_text}")

            if hasattr(card, 'attacks') and card.attacks:
                for atk in card.attacks:
                    cost_str = "".join(atk.cost) if atk.cost else "无费用"
                    dmg = atk.damage if atk.damage else 0
                    lines.append(f"【{cost_str}】{atk.name}  {dmg}伤害")
                    if hasattr(atk, 'text') and atk.text:
                        lines.append(f"  {atk.text}")

            if hasattr(card, 'weaknesses') and card.weaknesses:
                ws = "、".join(f"{w.energy_type}{w.value}" for w in card.weaknesses)
                lines.append(f"弱点: {ws}")
            if hasattr(card, 'resistances') and card.resistances:
                rs = "、".join(f"{r.energy_type}{r.value}" for r in card.resistances)
                lines.append(f"抗性: {rs}")
            if hasattr(card, 'retreat_cost'):
                lines.append(f"撤退费用: {card.retreat_cost}")

        elif hasattr(card, 'is_trainer') and card.is_trainer:
            subtypes = getattr(card, 'subtypes', [])
            sub_cn = {"Item": "物品", "Supporter": "支援者", "Stadium": "竞技场", "Tool": "宝可梦道具"}
            st = sub_cn.get(subtypes[0] if subtypes else "", "训练家")
            lines.append(st)
            if hasattr(card, 'rules') and card.rules:
                for rule in card.rules:
                    lines.append(rule)

        elif hasattr(card, 'is_energy') and card.is_energy:
            if getattr(card, 'is_special_energy', False):
                lines.append("特殊能量")
            else:
                lines.append("基本能量")
            if hasattr(card, 'provides_energy'):
                lines.append(f"提供: {'、'.join(card.provides_energy)}")

        # Render with wrapping
        font = self.font_small
        line_h = 18
        for raw_line in lines:
            wrapped = self._wrap_text(raw_line, font, max_width)
            for wl in wrapped:
                txt = font.render(wl, True, line_color)
                surface.blit(txt, (x, y))
                y += line_h
                if y > SCREEN_HEIGHT - 40:
                    return

    @staticmethod
    def _wrap_text(text: str, font, max_width: int) -> list[str]:
        """Wrap a single line of text to fit within max_width pixels."""
        if not text:
            return [""]
        # Check if the whole line fits
        if font.size(text)[0] <= max_width:
            return [text]
        wrapped = []
        current = ""
        for char in text:
            test = current + char
            if font.size(test)[0] > max_width:
                if current:
                    wrapped.append(current)
                current = char
            else:
                current = test
        if current:
            wrapped.append(current)
        return wrapped

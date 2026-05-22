"""Card image management tool - browse cards and assign images."""
import os
import tempfile
import pygame
from ui.screen_manager import Screen, ScreenManager
from ui.colors import (
    UI_BG_DARK, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY, UI_BUTTON, UI_BUTTON_HOVER,
    UI_HIGHLIGHT, UI_BORDER, UI_SUCCESS, UI_DANGER, TYPE_COLORS,
)
from ui.image_manager import get_image_manager
from ui.font_manager import get_font, get_font_size
from config import SCREEN_WIDTH, SCREEN_HEIGHT, CARD_WIDTH, CARD_HEIGHT, ENERGY_NAME_CN as ENERGY_CN, SUBTYPE_CN

# ── Layout constants ──
HEADER_H = 44
FILTER_H = 44
PREVIEW_Y = HEADER_H + FILTER_H  # 88
PREVIEW_H = 170
DROP_ZONE_H = 32
PANEL_TOP = PREVIEW_Y + PREVIEW_H + DROP_ZONE_H  # 290
BOTTOM_BAR_H = 56
PANEL_BOTTOM = SCREEN_HEIGHT - BOTTOM_BAR_H  # 944
PANEL_H = PANEL_BOTTOM - PANEL_TOP  # 654

LEFT_PANEL_W = int(SCREEN_WIDTH * 0.52)  # 832
RIGHT_PANEL_X = LEFT_PANEL_W + 12
RIGHT_PANEL_W = SCREEN_WIDTH - RIGHT_PANEL_X - 12

ROW_H = 28
GROUP_HEADER_H = 26

PREVIEW_BOX_W = 220
SEARCH_BOX_W = 220
SEARCH_BOX_H = 30
TYPE_TAB_W = 70
TYPE_TAB_H = 30

# Card type -> image subdirectory mapping
TYPE_TO_SUBDIR = {
    "Pokemon": "宝可梦",
    "Trainer": None,
}
TRAINER_TO_SUBDIR = {
    "Item": "物品",
    "Supporter": "支援者",
    "Stadium": "竞技场",
    "Tool": "宝可梦道具",
}


def _detect_image_ext(file_path: str) -> str | None:
    """Detect image format from file header magic bytes."""
    signatures = {
        b"\x89PNG\r\n\x1a\n": ".png",
        b"\xff\xd8\xff": ".jpg",
        b"RIFF": ".webp",
        b"GIF8": ".gif",
        b"BM": ".bmp",
    }
    try:
        with open(file_path, "rb") as f:
            header = f.read(12)
        for magic, ext in signatures.items():
            if header.startswith(magic):
                if magic == b"RIFF" and header[8:12] != b"WEBP":
                    continue
                return ext
    except OSError:
        return None
    return None


def _get_subdir_for_card(card) -> str:
    """Determine the image subdirectory for a card based on its type."""
    if card.is_pokemon:
        return "宝可梦"
    if card.is_trainer:
        return TRAINER_TO_SUBDIR.get(card.trainer_type, "物品")
    if card.is_energy:
        return "能量"
    return "物品"


class CardEntry:
    """Lightweight struct for card list entries with cached type info."""
    __slots__ = ('card_id', 'name', 'card', 'has_image')

    def __init__(self, card_id: str, name: str, card, has_image: bool):
        self.card_id = card_id
        self.name = name
        self.card = card
        self.has_image = has_image


class CardImageScreen(Screen):
    """Modal screen for managing card face images."""

    def __init__(self, manager: ScreenManager):
        super().__init__(manager)
        self.image_mgr = get_image_manager()

        self.font_title = get_font("body_lg")
        self.font_body = get_font("small")
        self.font_small = get_font("caption")
        self.font_tiny = get_font("tiny")
        self.font_search = get_font("normal")

        # Build master card list with full Card references
        from data.card_registry import CardRegistry
        self._all_cards: list[CardEntry] = []
        for card_id, card in CardRegistry._cards.items():
            has_img = self.image_mgr.has_image(card_id) or self.image_mgr.has_image(card.name)
            self._all_cards.append(CardEntry(card_id, card.name, card, has_img))
        self._all_cards.sort(key=lambda e: e.name)

        # Filter/sort state
        self.filter_type = "all"
        self.search_query = ""
        self.sort_mode = "name"

        # Scroll state (float for smooth scrolling)
        self.card_scroll: float = 0.0
        self.image_scroll: float = 0.0

        # Selection state
        self.selected_card: CardEntry | None = None
        self._selected_index: int = -1
        self.hovered_card_idx: int | None = None
        self.hovered_image_key: tuple | None = None
        self.hovered_button: str | None = None
        self.hovered_image_preview: str | None = None

        self.display_cards: list[CardEntry] = []
        self._apply_filter_and_sort()

        # Keyboard focus state
        self._focus_left: bool = True
        self._search_active: bool = False
        self._cursor_blink: float = 0.0

        # Drag state
        self._drag_active: bool = False

        # Toast
        self._toast_text: str | None = None
        self._toast_timer: float = 0.0

        # Confirmation dialog
        self._confirm_action: str | None = None
        self._confirm_hover_yes: bool = False
        self._confirm_hover_no: bool = False

        # Available images grouped by subdirectory
        self.image_groups: list[tuple[str, list[str], dict[str, bool]]] = []
        self._build_image_groups()

    # ── Data building ──

    def _refresh_card_image_status(self):
        """Refresh has_image status on all cached CardEntry objects."""
        for entry in self._all_cards:
            entry.has_image = (
                self.image_mgr.has_image(entry.card_id)
                or self.image_mgr.has_image(entry.name)
            )

    def _build_image_groups(self):
        """Group available images by parent directory with assignment status."""
        groups: dict[str, list[str]] = {}
        assigned = set(self.image_mgr._custom_map.keys())

        for name in self.image_mgr.get_available_images():
            path = self.image_mgr.get_available_image_path(name)
            if path is None:
                continue
            group_name = os.path.basename(os.path.dirname(path))
            if group_name not in groups:
                groups[group_name] = []
            groups[group_name].append(name)
        for g in groups:
            groups[g].sort()

        result = []
        for group_name, names in sorted(groups.items(), key=lambda x: x[0]):
            status_map = {n: n in assigned for n in names}
            result.append((group_name, names, status_map))
        self.image_groups = result

    def _apply_filter_and_sort(self):
        """Rebuild display_cards based on current filter, search, and sort settings."""
        result = list(self._all_cards)

        # Type filter
        if self.filter_type == "pokemon":
            result = [e for e in result if e.card.is_pokemon]
        elif self.filter_type == "trainer":
            result = [e for e in result if e.card.is_trainer]
        elif self.filter_type == "energy":
            result = [e for e in result if e.card.is_energy]

        # Text search
        if self.search_query:
            q = self.search_query.lower()
            result = [e for e in result if q in e.name.lower()]

        # Sort
        if self.sort_mode == "name":
            result.sort(key=lambda e: e.name)
        elif self.sort_mode == "type":
            def _type_order(e: CardEntry) -> tuple:
                order = {"Pokémon": 0, "Trainer": 1, "Energy": 2}
                return (order.get(e.card.supertype, 9), e.name)
            result.sort(key=_type_order)
        elif self.sort_mode == "status":
            result.sort(key=lambda e: (0 if not e.has_image else 1, e.name))

        # Update has_image (may have changed)
        for e in result:
            e.has_image = self.image_mgr.has_image(e.card_id) or self.image_mgr.has_image(e.name)

        self.display_cards = result

        # Clamp selection
        if self._selected_index >= len(self.display_cards):
            self._selected_index = len(self.display_cards) - 1
        if self._selected_index >= 0 and self.display_cards:
            self.selected_card = self.display_cards[self._selected_index]
        elif not self.display_cards:
            self._selected_index = -1
            self.selected_card = None

    def _get_target_subdir(self) -> str:
        """Determine the target image subdirectory for the currently selected card."""
        if self.selected_card is None:
            return "宝可梦"
        return _get_subdir_for_card(self.selected_card.card)

    def _get_subtype_label(self, card) -> str:
        """Return a short type/subtype label for display."""
        if card.is_pokemon:
            energy = card.energy_types[0] if card.energy_types else "Colorless"
            cn = ENERGY_CN.get(energy, energy)
            sub = card.subtypes[0] if card.subtypes else ""
            sub_cn = SUBTYPE_CN.get(sub, sub)
            return f"{cn} · {sub_cn}"
        elif card.is_trainer:
            sub = card.subtypes[0] if card.subtypes else "Trainer"
            return SUBTYPE_CN.get(sub, sub)
        else:
            return "基本能量" if card.is_basic_energy else "特殊能量"

    # ── Button rects ──

    def _get_button_rects(self) -> dict[str, pygame.Rect]:
        btn_w, btn_h = 110, 36
        gap = 8
        btn_names = ["paste", "rescan", "clear", "return"]
        total_w = len(btn_names) * btn_w + (len(btn_names) - 1) * gap
        start_x = (SCREEN_WIDTH - total_w) // 2
        y = SCREEN_HEIGHT - btn_h - 12
        return {
            name: pygame.Rect(start_x + i * (btn_w + gap), y, btn_w, btn_h)
            for i, name in enumerate(btn_names)
        }

    # ── Event handling ──

    def handle_event(self, event: pygame.event.Event):
        # ── Confirm dialog mode ──
        if self._confirm_action:
            return self._handle_confirm_event(event)

        # ── Search input mode ──
        if self._search_active:
            if event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self._search_active = False
                    return
                if event.key == pygame.K_RETURN:
                    self._search_active = False
                    return
                if event.key == pygame.K_BACKSPACE:
                    self.search_query = self.search_query[:-1]
                    self._apply_filter_and_sort()
                    self.card_scroll = 0.0
                    self._selected_index = 0 if self.display_cards else -1
                    self.selected_card = self.display_cards[0] if self.display_cards else None
                    return
                if event.unicode and event.unicode.isprintable():
                    self.search_query += event.unicode
                    self._apply_filter_and_sort()
                    self.card_scroll = 0.0
                    self._selected_index = 0 if self.display_cards else -1
                    self.selected_card = self.display_cards[0] if self.display_cards else None
                    return
            # Allow mouse events while search is active
            if event.type == pygame.MOUSEMOTION:
                self._hover(event.pos)
            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                self._click(event.pos)
            elif event.type == pygame.MOUSEWHEEL:
                self._handle_wheel(event)
            return

        # ── Keyboard shortcuts ──
        if event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                self.manager.pop_screen()
                return
            if event.key == pygame.K_v and (pygame.key.get_mods() & pygame.KMOD_CTRL):
                self._paste_from_clipboard()
                return
            if event.key == pygame.K_f and (pygame.key.get_mods() & pygame.KMOD_CTRL):
                self._search_active = True
                self.search_query = ""
                self._apply_filter_and_sort()
                return

            # Card panel navigation (left panel focus)
            if self._focus_left and self.display_cards:
                if event.key == pygame.K_UP:
                    self._selected_index = max(0, self._selected_index - 1)
                    self._update_selection_from_index()
                    self._scroll_to_selected()
                    return
                if event.key == pygame.K_DOWN:
                    self._selected_index = min(
                        len(self.display_cards) - 1, self._selected_index + 1)
                    self._update_selection_from_index()
                    self._scroll_to_selected()
                    return
                if event.key == pygame.K_PAGEUP:
                    page = max(1, int(PANEL_H // ROW_H) - 2)
                    self._selected_index = max(0, self._selected_index - page)
                    self._update_selection_from_index()
                    self._scroll_to_selected()
                    return
                if event.key == pygame.K_PAGEDOWN:
                    page = max(1, int(PANEL_H // ROW_H) - 2)
                    self._selected_index = min(
                        len(self.display_cards) - 1, self._selected_index + page)
                    self._update_selection_from_index()
                    self._scroll_to_selected()
                    return
                if event.key == pygame.K_HOME:
                    self._selected_index = 0
                    self._update_selection_from_index()
                    self._scroll_to_selected()
                    return
                if event.key == pygame.K_END:
                    self._selected_index = len(self.display_cards) - 1
                    self._update_selection_from_index()
                    self._scroll_to_selected()
                    return
                if event.key == pygame.K_RETURN and self.selected_card and self.hovered_image_key:
                    self._bind_hovered_image()
                    return
                if event.key == pygame.K_TAB:
                    self._focus_left = False
                    return

        # ── Drag-and-drop ──
        if event.type == getattr(pygame, "DROPBEGIN", 0):
            self._drag_active = True
            return
        if event.type == getattr(pygame, "DROPCOMPLETE", 0):
            self._drag_active = False
            return
        if event.type == getattr(pygame, "DROPFILE", 0):
            self._drag_active = False
            self._handle_file_drop(event.file)
            return
        if event.type == getattr(pygame, "DROPTEXT", 0):
            self._drag_active = False
            self._handle_text_drop(event.text)
            return

        # ── Mouse ──
        if event.type == pygame.MOUSEMOTION:
            self._hover(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._click(event.pos)
        elif event.type == pygame.MOUSEWHEEL:
            self._handle_wheel(event)

    def _handle_wheel(self, event):
        mx = event.pos[0] if hasattr(event, 'pos') else 0
        delta = event.y * (ROW_H * 0.7)
        if mx < LEFT_PANEL_W:
            self.card_scroll -= delta
        else:
            self.image_scroll -= delta

    def _scroll_to_selected(self):
        if self._selected_index < 0:
            return
        row_top = self._selected_index * ROW_H
        row_bottom = row_top + ROW_H
        if row_top < self.card_scroll:
            self.card_scroll = row_top
        elif row_bottom > self.card_scroll + PANEL_H:
            self.card_scroll = row_bottom - PANEL_H

    def _update_selection_from_index(self):
        if 0 <= self._selected_index < len(self.display_cards):
            self.selected_card = self.display_cards[self._selected_index]
        else:
            self.selected_card = None

    def _bind_hovered_image(self):
        """Bind the currently hovered image to the selected card."""
        if self.hovered_image_key is None or self.selected_card is None:
            return
        _, image_name = self.hovered_image_key
        source_path = self.image_mgr.get_available_image_path(image_name)
        if source_path:
            target_subdir = self._get_target_subdir()
            ok = self.image_mgr.assign_card_image(
                self.selected_card.name, source_path, target_subdir,
                self.selected_card.card_id)
            if ok:
                self._refresh_card_image_status()
                self._build_image_groups()
                self._apply_filter_and_sort()
                self._toast_text = f"已为「{self.selected_card.name}」绑定卡图"
                self._toast_timer = 3.0

    def _hover(self, pos):
        mx, my = pos
        self.hovered_card_idx = None
        self.hovered_image_key = None
        self.hovered_button = None
        self.hovered_image_preview = None

        # Card panel hover
        if 12 <= mx <= LEFT_PANEL_W - 4:
            visible_start = max(0, int(self.card_scroll // ROW_H))
            for i in range(visible_start, min(len(self.display_cards),
                                              visible_start + int(PANEL_H // ROW_H) + 2)):
                ry = PANEL_TOP + i * ROW_H - self.card_scroll
                if ry + ROW_H > PANEL_BOTTOM:
                    break
                row_rect = pygame.Rect(16, ry, LEFT_PANEL_W - 32, ROW_H)
                if row_rect.collidepoint(pos):
                    self.hovered_card_idx = i
                    break

        # Image panel hover
        if RIGHT_PANEL_X <= mx <= RIGHT_PANEL_X + RIGHT_PANEL_W:
            img_y = PANEL_TOP - self.image_scroll
            for group_name, names, _status in self.image_groups:
                if img_y > PANEL_BOTTOM:
                    break
                img_y += GROUP_HEADER_H
                for name in names:
                    if img_y > PANEL_BOTTOM:
                        break
                    if img_y + ROW_H >= PANEL_TOP:
                        row_rect = pygame.Rect(RIGHT_PANEL_X + 4, img_y, RIGHT_PANEL_W - 8, ROW_H)
                        if row_rect.collidepoint(pos):
                            self.hovered_image_key = (group_name, name)
                            self.hovered_image_preview = name
                            return
                    img_y += ROW_H

        # Bottom buttons
        for btn_name, rect in self._get_button_rects().items():
            if rect.collidepoint(pos):
                self.hovered_button = btn_name
                break

    def _click(self, pos):
        mx, my = pos

        # Search box click
        search_rect = pygame.Rect(24, HEADER_H + 7, SEARCH_BOX_W, SEARCH_BOX_H)
        if search_rect.collidepoint(pos):
            self._search_active = True
            return

        # Click in search area to deactivate
        if self._search_active and mx > search_rect.right + 10:
            self._search_active = False

        # Type tabs
        tab_x = search_rect.right + 20
        tab_keys = ["all", "pokemon", "trainer", "energy"]
        for key in tab_keys:
            tab_rect = pygame.Rect(tab_x, HEADER_H + 7, TYPE_TAB_W, TYPE_TAB_H)
            if tab_rect.collidepoint(pos):
                self.filter_type = key
                self._apply_filter_and_sort()
                self.card_scroll = 0.0
                self._selected_index = 0 if self.display_cards else -1
                self.selected_card = self.display_cards[0] if self.display_cards else None
                return
            tab_x += TYPE_TAB_W + 8

        # Sort button
        sort_rect = pygame.Rect(SCREEN_WIDTH - 120, HEADER_H + 7, 100, TYPE_TAB_H)
        if sort_rect.collidepoint(pos):
            modes = {"name": "type", "type": "status", "status": "name"}
            self.sort_mode = modes[self.sort_mode]
            self._apply_filter_and_sort()
            self.card_scroll = 0.0
            self._selected_index = 0 if self.display_cards else -1
            self.selected_card = self.display_cards[0] if self.display_cards else None
            return

        # Card list click
        if self.hovered_card_idx is not None:
            self._selected_index = self.hovered_card_idx
            self._update_selection_from_index()
            self._focus_left = True
            return

        # Image list click
        if self.hovered_image_key is not None and self.selected_card is not None:
            self._bind_hovered_image()
            return

        # Bottom buttons
        if self.hovered_button == "paste":
            self._paste_from_clipboard()
        elif self.hovered_button == "rescan":
            self.image_mgr.reload()
            self._build_image_groups()
            self._apply_filter_and_sort()
            self._toast_text = "已重新扫描图像目录"
            self._toast_timer = 2.5
        elif self.hovered_button == "clear":
            self._confirm_action = "clear_all"
        elif self.hovered_button == "return":
            self.manager.pop_screen()

    # ── Confirm dialog ──

    def _handle_confirm_event(self, event):
        if event.type == pygame.MOUSEMOTION:
            self._hover_confirm(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self._confirm_hover_yes:
                if self._confirm_action == "clear_all":
                    count = self.image_mgr.clear_all_custom_mappings()
                    self._build_image_groups()
                    self._apply_filter_and_sort()
                    self._toast_text = f"已清除 {count} 个自定义绑定"
                    self._toast_timer = 3.0
                self._confirm_action = None
            elif self._confirm_hover_no:
                self._confirm_action = None
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                self._confirm_action = None
            elif event.key == pygame.K_RETURN:
                if self._confirm_action == "clear_all":
                    count = self.image_mgr.clear_all_custom_mappings()
                    self._build_image_groups()
                    self._apply_filter_and_sort()
                    self._toast_text = f"已清除 {count} 个自定义绑定"
                    self._toast_timer = 3.0
                self._confirm_action = None

    def _hover_confirm(self, pos):
        self._confirm_hover_yes = False
        self._confirm_hover_no = False
        dialog_rect = self._confirm_dialog_rect()
        yes_rect = pygame.Rect(dialog_rect.x + 100, dialog_rect.y + 110, 80, 36)
        no_rect = pygame.Rect(dialog_rect.x + 220, dialog_rect.y + 110, 80, 36)
        if yes_rect.collidepoint(pos):
            self._confirm_hover_yes = True
        elif no_rect.collidepoint(pos):
            self._confirm_hover_no = True

    def _confirm_dialog_rect(self) -> pygame.Rect:
        w, h = 400, 180
        return pygame.Rect((SCREEN_WIDTH - w) // 2, (SCREEN_HEIGHT - h) // 2, w, h)

    # ── Drop / paste / download handlers ──

    def _handle_file_drop(self, file_path: str):
        if not os.path.isfile(file_path):
            self._toast_text = f"找不到文件: {os.path.basename(file_path)}"
            self._toast_timer = 2.5
            return

        ext = os.path.splitext(file_path)[1].lower()
        valid_exts = (".webp", ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff")

        if ext not in valid_exts:
            detected_ext = _detect_image_ext(file_path)
            if detected_ext:
                ext = detected_ext
            else:
                self._toast_text = f"无法识别图片格式: {ext or '无后缀'}，请使用 .png/.jpg/.webp 等格式"
                self._toast_timer = 3.0
                return

        if self.selected_card is None:
            self._toast_text = "请先在左侧选择一张卡牌，再拖入卡图文件"
            self._toast_timer = 2.5
            return

        target_subdir = self._get_target_subdir()
        ok = self.image_mgr.assign_card_image(
            self.selected_card.name, file_path, target_subdir,
            self.selected_card.card_id)
        if ok:
            self._refresh_card_image_status()
            self._build_image_groups()
            self._apply_filter_and_sort()
            self._toast_text = (
                f"已为「{self.selected_card.name}」绑定拖入的卡图 "
                f"-> {target_subdir}/{self.selected_card.name}{os.path.splitext(file_path)[1]}"
            )
            self._toast_timer = 3.0
        else:
            self._toast_text = "卡图绑定失败，请检查文件是否可读取"
            self._toast_timer = 2.5

    def _handle_text_drop(self, text: str):
        text = text.strip()

        if text.startswith(("http://", "https://")):
            if self.selected_card is None:
                self._toast_text = "请先在左侧选择一张卡牌，再拖入卡图文件"
                self._toast_timer = 2.5
                return
            self._toast_text = "正在下载卡图..."
            self._toast_timer = 999.0
            self._download_image(text)
            return

        if os.path.isfile(text):
            self._handle_file_drop(text)
            return

        if text.startswith("data:image/"):
            if self.selected_card is None:
                self._toast_text = "请先在左侧选择一张卡牌，再拖入卡图文件"
                self._toast_timer = 2.5
                return
            self._toast_text = "正在解析图像数据..."
            self._toast_timer = 999.0
            self._download_data_url(text)
            return

        self._toast_text = f"无法识别拖入的内容: {text[:40]}{'...' if len(text) > 40 else ''}"
        self._toast_timer = 3.0

    def _download_image(self, url: str):
        try:
            import requests
            resp = requests.get(url, timeout=10, headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            })
            resp.raise_for_status()
            content = resp.content
            ct = resp.headers.get("Content-Type", "")
            ext = ".webp"
            if "png" in ct:
                ext = ".png"
            elif "jpeg" in ct or "jpg" in ct:
                ext = ".jpg"
            elif "gif" in ct:
                ext = ".gif"
            elif "bmp" in ct:
                ext = ".bmp"
            self._save_dropped_bytes(content, ext)
        except Exception as e:
            self._toast_text = f"下载失败: {e}"
            self._toast_timer = 3.0

    def _download_data_url(self, data_url: str):
        try:
            import base64
            header, encoded = data_url.split(",", 1)
            ext = ".png"
            if "image/" in header:
                mime_type = header.split("image/")[1].split(";")[0]
                ext = "." + mime_type if mime_type != "jpeg" else ".jpg"
            content = base64.b64decode(encoded)
            self._save_dropped_bytes(content, ext)
        except Exception as e:
            self._toast_text = f"解析图片数据失败: {e}"
            self._toast_timer = 3.0

    def _save_dropped_bytes(self, content: bytes, ext: str):
        if self.selected_card is None:
            return

        target_subdir = self._get_target_subdir()

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            f.write(content)
            temp_path = f.name

        ok = self.image_mgr.assign_card_image(
            self.selected_card.name, temp_path, target_subdir,
            self.selected_card.card_id)
        if ok:
            self._refresh_card_image_status()
            self._build_image_groups()
            self._apply_filter_and_sort()
            self._toast_text = (
                f"已为「{self.selected_card.name}」绑定下载的卡图 "
                f"-> {target_subdir}/{self.selected_card.name}{ext}"
            )
            self._toast_timer = 3.0
        else:
            self._toast_text = "卡图绑定失败，请检查文件权限"
            self._toast_timer = 2.5

    def _paste_from_clipboard(self):
        if self.selected_card is None:
            self._toast_text = "请先在左侧选择一张卡牌"
            self._toast_timer = 2.0
            return

        try:
            from PIL import ImageGrab
        except ImportError:
            self._toast_text = "需要 Pillow 库支持剪贴板粘贴"
            self._toast_timer = 2.5
            return

        try:
            img = ImageGrab.grabclipboard()
        except Exception:
            img = None

        if img is None:
            self._toast_text = "剪贴板中没有图片，请先在浏览器中右键复制图片"
            self._toast_timer = 3.0
            return

        target_subdir = self._get_target_subdir()

        try:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
                img.save(f, format="PNG")
                temp_path = f.name

            ok = self.image_mgr.assign_card_image(
                self.selected_card.name, temp_path, target_subdir,
                self.selected_card.card_id)
            if ok:
                self._refresh_card_image_status()
                self._build_image_groups()
                self._apply_filter_and_sort()
                self._toast_text = (
                    f"已为「{self.selected_card.name}」粘贴剪贴板卡图 "
                    f"-> {target_subdir}/{self.selected_card.name}.png"
                )
                self._toast_timer = 3.0
            else:
                self._toast_text = "卡图绑定失败，请检查文件权限"
                self._toast_timer = 2.5
        except Exception as e:
            self._toast_text = f"粘贴失败: {e}"
            self._toast_timer = 3.0

    # ── Update ──

    def update(self, dt: float):
        if self._toast_timer > 0:
            self._toast_timer -= dt
            if self._toast_timer <= 0:
                self._toast_text = None

        # Cursor blink
        if self._search_active:
            self._cursor_blink += dt
            if self._cursor_blink > 1.0:
                self._cursor_blink -= 1.0

        # Clamp scroll
        card_content_h = len(self.display_cards) * ROW_H
        self.card_scroll = max(0.0, min(self.card_scroll, max(0.0, card_content_h - PANEL_H)))

        img_content_h = sum(
            GROUP_HEADER_H + len(names) * ROW_H
            for _, names, _ in self.image_groups
        )
        self.image_scroll = max(0.0, min(self.image_scroll, max(0.0, img_content_h - PANEL_H)))

    # ── Drawing ──

    def draw(self, surface: pygame.Surface):
        surface.fill(UI_BG_DARK)

        self._draw_header(surface)
        self._draw_filter_bar(surface)
        self._draw_preview_area(surface)
        self._draw_card_panel(surface)
        self._draw_image_panel(surface)
        self._draw_bottom_bar(surface)
        self._draw_toast(surface)
        if self._confirm_action:
            self._draw_confirm_dialog(surface)

    # ── Header ──

    def _draw_header(self, surface):
        title = self.font_title.render("卡牌图像管理", True, UI_HIGHLIGHT)
        surface.blit(title, (16, 6))

        # Keyboard shortcuts hint (center)
        hint = self.font_tiny.render(
            "↑↓导航 | Enter确认 | PgUp/PgDn翻页 | Home/End首尾 | Ctrl+F搜索 | Ctrl+V粘贴 | ESC返回",
            True, UI_TEXT_SECONDARY,
        )
        hint_x = (SCREEN_WIDTH - hint.get_width()) // 2
        surface.blit(hint, (hint_x, 22))

        # Statistics (right) — count from card list, not image pool
        total = len(self._all_cards)
        mapped = sum(1 for e in self._all_cards if e.has_image)
        pct = int(mapped / total * 100) if total > 0 else 0
        if pct >= 50:
            stats_color = (80, 220, 80)
        elif pct >= 25:
            stats_color = (220, 180, 80)
        else:
            stats_color = (200, 100, 80)
        stats = self.font_small.render(
            f"{mapped}/{total} 张有图像 ({pct}%)", True, stats_color,
        )
        x = SCREEN_WIDTH - stats.get_width() - 16
        surface.blit(stats, (x, 10))

    # ── Filter bar ──

    def _draw_filter_bar(self, surface):
        bar_y = HEADER_H
        bar_rect = pygame.Rect(12, bar_y, SCREEN_WIDTH - 24, FILTER_H - 4)
        pygame.draw.rect(surface, (18, 22, 36), bar_rect, border_radius=6)
        pygame.draw.rect(surface, UI_BORDER, bar_rect, 1, border_radius=6)

        # Search box
        search_rect = pygame.Rect(24, bar_y + 7, SEARCH_BOX_W, SEARCH_BOX_H)
        search_bg = (40, 50, 80) if self._search_active else (28, 33, 46)
        pygame.draw.rect(surface, search_bg, search_rect, border_radius=4)
        border_color = UI_HIGHLIGHT if self._search_active else UI_BORDER
        pygame.draw.rect(surface, border_color, search_rect, 2 if self._search_active else 1, border_radius=4)

        if self.search_query:
            txt = self.font_search.render(self.search_query, True, UI_TEXT_PRIMARY)
        else:
            txt = self.font_search.render("搜索卡牌名称...", True, (80, 80, 100))
        surface.blit(txt, (search_rect.x + 8, search_rect.y + 4))

        # Blinking cursor when search active
        if self._search_active and int(self._cursor_blink * 2) % 2 == 0:
            cursor_x = search_rect.x + 8 + (txt.get_width() if self.search_query else 0) + 2
            pygame.draw.line(surface, UI_HIGHLIGHT,
                             (cursor_x, search_rect.y + 5),
                             (cursor_x, search_rect.y + SEARCH_BOX_H - 5), 2)

        # Type filter tabs
        tab_x = search_rect.right + 20
        tab_defs = [
            ("all", "全部", (100, 100, 120)),
            ("pokemon", "宝可梦", TYPE_COLORS.get("Grass", (80, 160, 80))),
            ("trainer", "训练家", TYPE_COLORS.get("Trainer", (140, 180, 200))),
            ("energy", "能量", TYPE_COLORS.get("Colorless", (210, 210, 200))),
        ]
        for key, label, color in tab_defs:
            tab_rect = pygame.Rect(tab_x, bar_y + 7, TYPE_TAB_W, TYPE_TAB_H)
            is_active = (self.filter_type == key)
            bg = color if is_active else (35, 38, 50)
            pygame.draw.rect(surface, bg, tab_rect, border_radius=4)
            if is_active:
                pygame.draw.rect(surface, UI_HIGHLIGHT, tab_rect, 2, border_radius=4)
            tab_txt = self.font_small.render(label, True,
                (255, 255, 255) if is_active else UI_TEXT_SECONDARY)
            surface.blit(tab_txt, tab_txt.get_rect(center=tab_rect.center))
            tab_x += TYPE_TAB_W + 8

        # Sort button
        sort_labels = {"name": "按名称", "type": "按类型", "status": "缺图优先"}
        sort_label = sort_labels.get(self.sort_mode, "排序")
        sort_rect = pygame.Rect(SCREEN_WIDTH - 120, bar_y + 7, 100, TYPE_TAB_H)
        pygame.draw.rect(surface, (50, 55, 70), sort_rect, border_radius=4)
        pygame.draw.rect(surface, UI_BORDER, sort_rect, 1, border_radius=4)
        sort_txt = self.font_small.render(sort_label, True, UI_TEXT_PRIMARY)
        surface.blit(sort_txt, sort_txt.get_rect(center=sort_rect.center))

    # ── Preview area ──

    def _draw_preview_area(self, surface):
        py = PREVIEW_Y + 4
        ph = PREVIEW_H - 12

        # ── Left: Card Image Preview ──
        left_rect = pygame.Rect(20, py, PREVIEW_BOX_W, ph)
        pygame.draw.rect(surface, (20, 25, 40), left_rect, border_radius=8)
        pygame.draw.rect(surface, UI_BORDER, left_rect, 1, border_radius=8)
        lbl = self.font_tiny.render("卡牌预览", True, UI_TEXT_SECONDARY)
        surface.blit(lbl, (left_rect.x + 4, left_rect.y + 2))

        if self.selected_card:
            img = self.image_mgr.get_card_image(self.selected_card.name, self.selected_card.card_id)
            if img is not None:
                iw, ih = img.get_size()
                scale = min((PREVIEW_BOX_W - 20) / iw, (ph - 20) / ih)
                sw, sh = int(iw * scale), int(ih * scale)
                try:
                    scaled = pygame.transform.smoothscale(img, (sw, sh))
                    surface.blit(scaled, (20 + (PREVIEW_BOX_W - sw) // 2, py + (ph - sh) // 2))
                except Exception:
                    pass
            else:
                self._draw_card_placeholder(surface, left_rect, self.selected_card.card)
        else:
            hint = self.font_body.render("请选择卡牌", True, (100, 100, 100))
            surface.blit(hint, hint.get_rect(center=left_rect.center))

        # ── Center: Card Detail Info ──
        detail_x = left_rect.right + 16
        detail_w = SCREEN_WIDTH - PREVIEW_BOX_W - 20 - detail_x - PREVIEW_BOX_W - 16
        if self.selected_card:
            self._draw_card_detail(surface, detail_x, py, detail_w, ph, self.selected_card)

        # ── Right: Hovered Image Preview ──
        rpx = SCREEN_WIDTH - PREVIEW_BOX_W - 20
        right_rect = pygame.Rect(rpx, py, PREVIEW_BOX_W, ph)
        pygame.draw.rect(surface, (20, 25, 40), right_rect, border_radius=8)
        pygame.draw.rect(surface, UI_BORDER, right_rect, 1, border_radius=8)
        rlbl = self.font_tiny.render("悬停图像预览", True, UI_TEXT_SECONDARY)
        surface.blit(rlbl, (rpx + 4, py + 2))

        if self.hovered_image_preview:
            img = self.image_mgr.get_card_image(self.hovered_image_preview)
            if img is not None:
                iw, ih = img.get_size()
                scale = min((PREVIEW_BOX_W - 20) / iw, (ph - 20) / ih)
                sw, sh = int(iw * scale), int(ih * scale)
                try:
                    scaled = pygame.transform.smoothscale(img, (sw, sh))
                    surface.blit(scaled, (rpx + (PREVIEW_BOX_W - sw) // 2, py + (ph - sh) // 2))
                except Exception:
                    pass
            pname_txt = self.font_small.render(self.hovered_image_preview, True, UI_TEXT_PRIMARY)
            surface.blit(pname_txt, (rpx, py + ph + 2))

        # ── Drop zone ──
        drop_y = PREVIEW_Y + PREVIEW_H
        drop_zone = pygame.Rect(20, drop_y, SCREEN_WIDTH - 40, DROP_ZONE_H - 4)
        if self._drag_active:
            drop_color = (60, 120, 200)
            drop_text = "▼ 释放文件以绑定卡图 ▼"
            drop_text_color = (200, 220, 255)
        else:
            drop_color = (30, 35, 50)
            drop_text = "拖放图片文件到此处可快速绑定 | Ctrl+V 粘贴剪贴板 | 也可在右侧面板点击现有图像"
            drop_text_color = (120, 130, 150)
        pygame.draw.rect(surface, drop_color, drop_zone, border_radius=4)
        if self._drag_active:
            pygame.draw.rect(surface, (100, 160, 240), drop_zone, 1, border_radius=4)
        drop_txt = self.font_tiny.render(drop_text, True, drop_text_color)
        surface.blit(drop_txt, drop_txt.get_rect(center=drop_zone.center))

    def _draw_card_detail(self, surface, x, y, w, h, entry: CardEntry):
        """Draw card detail information in the center preview zone."""
        card = entry.card
        bottom = y + h
        col2_x = x + int(w * 0.48)

        # ── Row 1: Card name + HP ──
        name_txt = self.font_title.render(card.name, True, (255, 220, 100))
        surface.blit(name_txt, (x, y))
        row1_y = y

        hp_str = f"HP {card.hp}" if card.is_pokemon else ""
        if hp_str:
            hp_txt = self.font_body.render(hp_str, True, UI_TEXT_PRIMARY)
            surface.blit(hp_txt, (x + name_txt.get_width() + 20, y + 4))

        # ── Row 2: Type badge + stage + image status ──
        row2_y = y + name_txt.get_height() + 4
        badge_color = self._get_card_type_color(card)
        badge_text = self.font_small.render(self._get_subtype_label(card), True, (255, 255, 255))
        bw, bh = badge_text.get_width() + 12, badge_text.get_height() + 4
        badge_rect = pygame.Rect(x, row2_y, bw, bh)
        pygame.draw.rect(surface, badge_color, badge_rect, border_radius=4)
        surface.blit(badge_text, badge_text.get_rect(center=badge_rect.center))

        has = self.image_mgr.has_image(card.api_id) or self.image_mgr.has_image(card.name)
        status = "✓已有卡图" if has else "✗暂无卡图"
        status_color = (80, 220, 80) if has else (180, 120, 80)
        st_txt = self.font_tiny.render(status, True, status_color)
        surface.blit(st_txt, (badge_rect.right + 10, row2_y + 2))

        info_y = row2_y + bh + 4

        # ── Pokemon detail ──
        if card.is_pokemon:
            # Left column: stats
            ly = info_y
            # Evolves from
            if card.evolves_from:
                evo_txt = self.font_tiny.render(f"进化自: {card.evolves_from}", True, UI_TEXT_SECONDARY)
                surface.blit(evo_txt, (x, ly))
                ly += evo_txt.get_height() + 1

            # Weakness / Resistance / Retreat
            stats_parts = []
            if card.weaknesses:
                wk = card.weaknesses[0]
                stats_parts.append(f"弱点:{ENERGY_CN.get(wk.energy_type, wk.energy_type)}{wk.value}")
            if card.resistances:
                rs = card.resistances[0]
                stats_parts.append(f"抵抗:{ENERGY_CN.get(rs.energy_type, rs.energy_type)}{rs.value}")
            stats_parts.append(f"撤退:{card.retreat_cost}")
            stats_line = "  ".join(stats_parts)
            stats_txt = self.font_tiny.render(stats_line, True, UI_TEXT_SECONDARY)
            surface.blit(stats_txt, (x, ly))
            ly += stats_txt.get_height() + 2

            # Rules (ex/V rule boxes)
            for rule in card.rules:
                rule_txt = self.font_tiny.render(rule, True, (220, 200, 140))
                surface.blit(rule_txt, (x, ly))
                ly += rule_txt.get_height()

            # Right column: abilities + attacks
            ry = info_y

            # Abilities
            for ab in card.abilities:
                if ry + 28 > bottom:
                    break
                ab_name = self.font_small.render(f"【{ab.name}】", True, (255, 140, 100))
                surface.blit(ab_name, (col2_x, ry))
                ry += ab_name.get_height()
                # Wrap ability text
                ry = self._draw_wrapped_text(surface, ab.text, col2_x + 8, ry,
                                             w - (col2_x - x) - 8, bottom, self.font_tiny,
                                             UI_TEXT_PRIMARY)
                ry += 2

            # Attacks
            for atk in card.attacks[:3]:
                if ry + 20 > bottom:
                    break
                cost_str = "".join(ENERGY_CN.get(c, c[:1]) for c in atk.cost[:4])
                dmg = str(atk.damage) if atk.damage else "-"
                atk_header = f"[{cost_str}] {atk.name}  {dmg}"
                atk_hdr_txt = self.font_small.render(atk_header, True, UI_TEXT_PRIMARY)
                surface.blit(atk_hdr_txt, (col2_x, ry))
                ry += atk_hdr_txt.get_height()
                # Attack effect text
                if atk.text:
                    ry = self._draw_wrapped_text(surface, atk.text, col2_x + 8, ry,
                                                 w - (col2_x - x) - 8, bottom, self.font_tiny,
                                                 UI_TEXT_SECONDARY)
                ry += 1

        # ── Trainer detail ──
        elif card.is_trainer:
            trainer_type = card.trainer_type if card.trainer_type else "训练家"
            tt_txt = self.font_small.render(f"类型: {trainer_type}", True, UI_TEXT_PRIMARY)
            surface.blit(tt_txt, (x, info_y))
            info_y += tt_txt.get_height() + 2

            # Trainer rules
            for rule in card.rules:
                if info_y > bottom - 10:
                    break
                rule_txt = self.font_tiny.render(rule, True, (220, 200, 140))
                surface.blit(rule_txt, (x, info_y))
                info_y += rule_txt.get_height()

            # Full trainer text with wrapping
            if card.trainer_text:
                info_y = self._draw_wrapped_text(surface, card.trainer_text, x, info_y,
                                                 w, bottom, self.font_tiny, UI_TEXT_PRIMARY)

        # ── Energy detail ──
        elif card.is_energy:
            etype = "基本能量" if card.is_basic_energy else "特殊能量"
            et_txt = self.font_small.render(etype, True, UI_TEXT_PRIMARY)
            surface.blit(et_txt, (x, info_y))
            info_y += et_txt.get_height() + 2

            for rule in card.rules:
                if info_y > bottom - 10:
                    break
                rule_txt = self.font_tiny.render(rule, True, (220, 200, 140))
                surface.blit(rule_txt, (x, info_y))
                info_y += rule_txt.get_height()

            if card.trainer_text:
                info_y = self._draw_wrapped_text(surface, card.trainer_text, x, info_y,
                                                 w, bottom, self.font_tiny, UI_TEXT_PRIMARY)

    def _draw_wrapped_text(self, surface, text, x, y, max_w, max_y, font, color) -> int:
        """Draw text with word wrapping. Returns new y position."""
        if not text:
            return y
        chars_per_line = max(10, int(max_w / (font.size("测")[0] or 7)))
        while text and y < max_y - 8:
            chunk = text[:chars_per_line]
            text = text[chars_per_line:]
            line_txt = font.render(chunk, True, color)
            surface.blit(line_txt, (x, y))
            y += line_txt.get_height() + 1
        return y

    def _draw_card_placeholder(self, surface, rect, card):
        """Draw a type-colored placeholder when no card image exists."""
        color = self._get_card_type_color(card)
        inner = rect.inflate(-10, -10)
        pygame.draw.rect(surface, color, inner, border_radius=6)
        pygame.draw.rect(surface, UI_BORDER, inner, 1, border_radius=6)

        name_txt = self.font_small.render(card.name, True, (255, 255, 255))
        name_rect = name_txt.get_rect(center=inner.center)
        surface.blit(name_txt, name_rect)

        sub_txt = self.font_tiny.render(self._get_subtype_label(card), True, (240, 240, 240))
        sub_rect = sub_txt.get_rect(center=(inner.centerx, inner.centery + 20))
        surface.blit(sub_txt, sub_rect)

    def _get_card_type_color(self, card) -> tuple:
        """Get a representative color for the card type."""
        if card.is_pokemon:
            if card.energy_types:
                return TYPE_COLORS.get(card.energy_types[0], TYPE_COLORS["Colorless"])
            return TYPE_COLORS["Colorless"]
        elif card.is_trainer:
            return TYPE_COLORS["Trainer"]
        else:
            return TYPE_COLORS["Energy"]

    # ── Card panel (left) ──

    def _draw_card_panel(self, surface):
        panel_rect = pygame.Rect(12, PANEL_TOP, LEFT_PANEL_W - 16, PANEL_H)
        pygame.draw.rect(surface, (18, 22, 36), panel_rect, border_radius=8)
        pygame.draw.rect(surface, UI_BORDER, panel_rect, 1, border_radius=8)

        surface.set_clip(panel_rect)

        if not self.display_cards:
            msg = self.font_body.render(
                f'未找到匹配 "{self.search_query}" 的卡牌' if self.search_query
                else "没有卡牌数据",
                True, UI_TEXT_SECONDARY,
            )
            surface.blit(msg, msg.get_rect(center=panel_rect.center))
            surface.set_clip(None)
            return

        visible_start = max(0, int(self.card_scroll // ROW_H))
        visible_end = min(len(self.display_cards), visible_start + int(PANEL_H // ROW_H) + 2)

        for i in range(visible_start, visible_end):
            entry = self.display_cards[i]
            row_y = PANEL_TOP + i * ROW_H - self.card_scroll

            is_selected = (i == self._selected_index)
            is_hovered = (i == self.hovered_card_idx)
            if is_selected:
                row_color = (50, 80, 130)
            elif is_hovered:
                row_color = (40, 50, 70)
            else:
                row_color = (28, 33, 46) if i % 2 == 0 else (23, 28, 41)

            pygame.draw.rect(surface, row_color, (16, row_y, LEFT_PANEL_W - 36, ROW_H - 1), border_radius=3)

            # Selection border
            if is_selected:
                pygame.draw.rect(surface, UI_HIGHLIGHT,
                                 (16, row_y, LEFT_PANEL_W - 36, ROW_H - 1), 2, border_radius=3)

            # Status icon
            icon_color = (80, 220, 80) if entry.has_image else (120, 120, 120)
            icon = self.font_small.render("✓" if entry.has_image else "✗", True, icon_color)
            surface.blit(icon, (20, row_y + 4))

            # Type badge
            self._draw_type_badge(surface, 40, row_y + 6, entry.card)

            # Card name
            name_txt = self.font_small.render(entry.name, True,
                UI_HIGHLIGHT if is_selected else UI_TEXT_PRIMARY)
            surface.blit(name_txt, (62, row_y + 4))

            # Subtype label (right-aligned)
            sub_label = self._get_subtype_label(entry.card)
            sub_txt = self.font_tiny.render(sub_label, True, UI_TEXT_SECONDARY)
            sub_x = LEFT_PANEL_W - 28 - sub_txt.get_width()
            surface.blit(sub_txt, (sub_x, row_y + 6))

        # Scrollbar
        content_h = len(self.display_cards) * ROW_H
        if content_h > PANEL_H:
            bar_h = max(30, int(PANEL_H * PANEL_H / content_h))
            bar_y = PANEL_TOP + int(self.card_scroll * PANEL_H / content_h)
            pygame.draw.rect(surface, (80, 80, 100),
                             (LEFT_PANEL_W - 16, bar_y, 6, bar_h), border_radius=3)

        surface.set_clip(None)

    def _draw_type_badge(self, surface, x, y, card):
        """Draw a small colored square representing the card type."""
        size = 14
        color = self._get_card_type_color(card)
        pygame.draw.rect(surface, color, (x, y, size, size), border_radius=3)
        pygame.draw.rect(surface, (255, 255, 255, 80), (x, y, size, size), 1, border_radius=3)

    # ── Image panel (right) ──

    def _draw_image_panel(self, surface):
        panel_rect = pygame.Rect(RIGHT_PANEL_X, PANEL_TOP, RIGHT_PANEL_W, PANEL_H)
        pygame.draw.rect(surface, (18, 22, 36), panel_rect, border_radius=8)
        pygame.draw.rect(surface, UI_BORDER, panel_rect, 1, border_radius=8)

        surface.set_clip(panel_rect)
        img_y = PANEL_TOP - self.image_scroll

        for group_name, names, status_map in self.image_groups:
            if img_y > PANEL_BOTTOM:
                break
            # Group header
            if img_y + GROUP_HEADER_H >= PANEL_TOP:
                header_bg = pygame.Rect(RIGHT_PANEL_X + 4, img_y, RIGHT_PANEL_W - 8, GROUP_HEADER_H)
                pygame.draw.rect(surface, (40, 50, 80), header_bg, border_radius=3)
                count = len(names)
                grp_txt = self.font_small.render(f"{group_name} ({count})", True, (180, 200, 240))
                surface.blit(grp_txt, (RIGHT_PANEL_X + 12, img_y + 3))
            img_y += GROUP_HEADER_H

            for name in names:
                if img_y > PANEL_BOTTOM:
                    break
                if img_y + ROW_H >= PANEL_TOP:
                    is_hovered = (self.hovered_image_key == (group_name, name))
                    is_assigned = status_map.get(name, False)
                    row_color = (40, 60, 90) if is_hovered else (26, 30, 42)
                    pygame.draw.rect(surface, row_color,
                                     (RIGHT_PANEL_X + 8, img_y, RIGHT_PANEL_W - 16, ROW_H - 1), border_radius=3)
                    name_txt = self.font_small.render(name, True, UI_TEXT_PRIMARY)
                    surface.blit(name_txt, (RIGHT_PANEL_X + 16, img_y + 3))

                    # Assignment indicator
                    if is_assigned:
                        assigned_txt = self.font_tiny.render("已分配", True, (120, 200, 120))
                        ax = RIGHT_PANEL_X + RIGHT_PANEL_W - assigned_txt.get_width() - 20
                        surface.blit(assigned_txt, (ax, img_y + 6))
                img_y += ROW_H

        # Scrollbar
        content_h = sum(GROUP_HEADER_H + len(names) * ROW_H for _, names, _ in self.image_groups)
        if content_h > PANEL_H:
            bar_h = max(30, int(PANEL_H * PANEL_H / content_h))
            bar_y = PANEL_TOP + int(self.image_scroll * PANEL_H / content_h)
            pygame.draw.rect(surface, (80, 80, 100),
                             (RIGHT_PANEL_X + RIGHT_PANEL_W - 12, bar_y, 6, bar_h), border_radius=3)

        surface.set_clip(None)

    # ── Bottom bar ──

    def _draw_bottom_bar(self, surface):
        buttons = self._get_button_rects()
        labels = {
            "paste": "从剪贴板粘贴",
            "rescan": "重新扫描",
            "clear": "清除绑定",
            "return": "返回",
        }
        colors = {
            "paste": (40, 140, 80),
            "rescan": (60, 120, 200),
            "clear": (200, 80, 80),
            "return": (120, 120, 120),
        }

        for btn_name, rect in buttons.items():
            is_hovered = (self.hovered_button == btn_name)
            base = colors[btn_name]
            if is_hovered:
                r, g, b = base
                base = (min(r + 40, 255), min(g + 40, 255), min(b + 40, 255))
            pygame.draw.rect(surface, base, rect, border_radius=6)
            pygame.draw.rect(surface, UI_HIGHLIGHT, rect, 1, border_radius=6)
            lbl_txt = self.font_small.render(labels[btn_name], True, (255, 255, 255))
            surface.blit(lbl_txt, lbl_txt.get_rect(center=rect.center))

        if self.selected_card:
            sel_txt = self.font_small.render(f"已选中: {self.selected_card.name}", True, (255, 220, 100))
            surface.blit(sel_txt, (20, SCREEN_HEIGHT - 52))

    # ── Toast ──

    def _draw_toast(self, surface):
        if self._toast_text is None:
            return
        toast = self.font_small.render(self._toast_text, True, (50, 50, 50))
        tw, th = toast.get_size()
        bg_rect = pygame.Rect(
            (SCREEN_WIDTH - tw) // 2 - 16, SCREEN_HEIGHT - 100, tw + 32, th + 16,
        )
        # Fade out in last 0.5 seconds
        alpha = 255
        if self._toast_timer < 0.5:
            alpha = int(255 * (self._toast_timer / 0.5))
        toast_surf = pygame.Surface((bg_rect.w, bg_rect.h), pygame.SRCALPHA)
        toast_surf.fill((200, 220, 140, min(alpha, 220)))
        pygame.draw.rect(toast_surf, (120, 160, 60, alpha), toast_surf.get_rect(), 1, border_radius=6)
        surface.blit(toast_surf, (bg_rect.x, bg_rect.y))
        surface.blit(toast, ((SCREEN_WIDTH - tw) // 2, SCREEN_HEIGHT - 92))

    # ── Confirm dialog ──

    def _draw_confirm_dialog(self, surface):
        # Dim background
        dim = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 160))
        surface.blit(dim, (0, 0))

        rect = self._confirm_dialog_rect()
        pygame.draw.rect(surface, (30, 35, 55), rect, border_radius=10)
        pygame.draw.rect(surface, UI_BORDER, rect, 2, border_radius=10)

        title = self.font_body.render("确认清除", True, UI_HIGHLIGHT)
        surface.blit(title, (rect.x + 24, rect.y + 20))

        body = self.font_small.render(
            "确定要清除所有自定义图像绑定吗？", True, UI_TEXT_PRIMARY)
        surface.blit(body, (rect.x + 24, rect.y + 56))
        body2 = self.font_small.render(
            "此操作不会删除图像文件，仅移除绑定关系。", True, UI_TEXT_SECONDARY)
        surface.blit(body2, (rect.x + 24, rect.y + 80))

        # Yes button
        yes_rect = pygame.Rect(rect.x + 100, rect.y + 120, 80, 36)
        yes_color = (200, 70, 70) if not self._confirm_hover_yes else (230, 90, 90)
        pygame.draw.rect(surface, yes_color, yes_rect, border_radius=6)
        yes_txt = self.font_small.render("确认", True, (255, 255, 255))
        surface.blit(yes_txt, yes_txt.get_rect(center=yes_rect.center))

        # No button
        no_rect = pygame.Rect(rect.x + 220, rect.y + 120, 80, 36)
        no_color = (100, 100, 120) if not self._confirm_hover_no else (130, 130, 150)
        pygame.draw.rect(surface, no_color, no_rect, border_radius=6)
        no_txt = self.font_small.render("取消", True, (255, 255, 255))
        surface.blit(no_txt, no_txt.get_rect(center=no_rect.center))

"""Card image workbench - browse cards, normalize assets, and bind images."""
from __future__ import annotations

from dataclasses import dataclass
import base64
import os
import queue
import tempfile
import threading
from urllib.parse import urlparse

import pygame

from config import SCREEN_WIDTH, SCREEN_HEIGHT, ENERGY_NAME_CN as ENERGY_CN, SUBTYPE_CN
from ui.colors import (
    TYPE_COLORS, UI_BG_DARK, UI_BORDER, UI_DANGER, UI_HIGHLIGHT,
    UI_SUCCESS, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY,
)
from ui.font_manager import get_font
from ui.image_manager import ImageCandidate, get_image_manager
from ui.screen_manager import Screen, ScreenManager
from ui.ui_theme import draw_button, draw_panel, draw_text_fit


HEADER_H = 44
FILTER_H = 48
BOTTOM_BAR_H = 58
WORK_TOP = HEADER_H + FILTER_H + 8
WORK_BOTTOM = SCREEN_HEIGHT - BOTTOM_BAR_H - 8
WORK_H = WORK_BOTTOM - WORK_TOP

LEFT_X = 12
LEFT_W = 420
CENTER_X = LEFT_X + LEFT_W + 12
CENTER_W = 610
RIGHT_X = CENTER_X + CENTER_W + 12
RIGHT_W = SCREEN_WIDTH - RIGHT_X - 12

ROW_H = 34
CANDIDATE_ROW_H = 32
TAB_H = 30
SEARCH_BOX_W = 270
SEARCH_BOX_H = 30

VALID_IMAGE_EXTS = (".webp", ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff")


@dataclass
class CardEntry:
    card_id: str
    name: str
    card: object
    has_image: bool
    is_duplicate_name: bool


@dataclass
class PendingImage:
    path: str
    label: str
    source: str
    is_temp: bool = False


def _detect_image_ext(file_path: str) -> str | None:
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
    except OSError:
        return None
    for magic, ext in signatures.items():
        if header.startswith(magic):
            if magic == b"RIFF" and header[8:12] != b"WEBP":
                continue
            return ext
    return None


def _load_preview(path: str) -> pygame.Surface | None:
    try:
        return pygame.image.load(path).convert_alpha()
    except Exception:
        pass
    try:
        from PIL import Image
        img = Image.open(path).convert("RGBA")
        raw = img.tobytes("raw", "RGBA")
        return pygame.image.frombuffer(raw, img.size, "RGBA").convert_alpha()
    except Exception:
        return None


class CardImageScreen(Screen):
    """Three-column card image management workbench."""

    def __init__(self, manager: ScreenManager):
        super().__init__(manager)
        self.image_mgr = get_image_manager()

        self.font_title = get_font("body_lg")
        self.font_body = get_font("small")
        self.font_small = get_font("caption")
        self.font_tiny = get_font("tiny")
        self.font_search = get_font("normal")

        from data.card_registry import CardRegistry

        name_counts: dict[str, int] = {}
        for card in CardRegistry.all_cards().values():
            name_counts[card.name] = name_counts.get(card.name, 0) + 1

        self._all_cards: list[CardEntry] = []
        for card_id, card in CardRegistry.all_cards().items():
            self._all_cards.append(CardEntry(
                card_id=card_id,
                name=card.name,
                card=card,
                has_image=self.image_mgr.has_card_image(card),
                is_duplicate_name=name_counts.get(card.name, 0) > 1,
            ))
        self._all_cards.sort(key=lambda e: (e.name, e.card_id))

        self.filter_type = "missing"
        self.search_query = ""
        self.sort_mode = "status"
        self.display_cards: list[CardEntry] = []
        self.selected_card: CardEntry | None = None
        self._selected_index = -1

        self.card_scroll = 0.0
        self.candidate_scroll = 0.0
        self.hovered_card_idx: int | None = None
        self.hovered_candidate_idx: int | None = None
        self.hovered_button: str | None = None

        self.pending_image: PendingImage | None = None
        self._preview_cache_key: str | None = None
        self._preview_cache_surface: pygame.Surface | None = None

        self._search_active = False
        self._url_active = False
        self.url_query = ""
        self._cursor_blink = 0.0
        self._drag_active = False

        self._toast_text: str | None = None
        self._toast_timer = 0.0
        self._confirm_action: str | None = None
        self._confirm_message = ""
        self._confirm_hover_yes = False
        self._confirm_hover_no = False

        self._download_queue: queue.Queue = queue.Queue()
        self._download_thread: threading.Thread | None = None
        self._download_active = False

        self.image_candidates: list[ImageCandidate] = []
        self._apply_filter_and_sort()
        self._build_image_candidates()

    # ── Data ──

    def _refresh_card_image_status(self):
        for entry in self._all_cards:
            entry.has_image = self.image_mgr.has_card_image(entry.card)

    def _apply_filter_and_sort(self):
        self._refresh_card_image_status()
        cards = list(self._all_cards)

        if self.filter_type == "missing":
            cards = [e for e in cards if not e.has_image]
        elif self.filter_type == "mapped":
            cards = [e for e in cards if e.has_image]
        elif self.filter_type == "duplicates":
            cards = [e for e in cards if e.is_duplicate_name]
        elif self.filter_type == "orphans":
            cards = []

        if self.search_query:
            q = self.search_query.lower()
            cards = [
                e for e in cards
                if q in e.name.lower()
                or q in e.card_id.lower()
                or q in self._subtype_label(e.card).lower()
            ]

        if self.sort_mode == "name":
            cards.sort(key=lambda e: (e.name, e.card_id))
        elif self.sort_mode == "type":
            order = {"Pokémon": 0, "Trainer": 1, "Energy": 2}
            cards.sort(key=lambda e: (order.get(e.card.supertype, 9), e.name, e.card_id))
        else:
            cards.sort(key=lambda e: (0 if not e.has_image else 1, e.name, e.card_id))

        self.display_cards = cards
        if not cards:
            self._selected_index = -1
            self.selected_card = None
            return

        if self.selected_card in cards:
            self._selected_index = cards.index(self.selected_card)
        elif self._selected_index < 0 or self._selected_index >= len(cards):
            self._selected_index = 0
            self.selected_card = cards[0]
        else:
            self.selected_card = cards[self._selected_index]

    def _build_image_candidates(self):
        candidates: list[ImageCandidate] = []
        seen_paths: set[str] = set()

        for cand in self.image_mgr.get_unreferenced_images():
            key = os.path.normcase(cand.path)
            if key not in seen_paths:
                candidates.append(cand)
                seen_paths.add(key)

        if self.selected_card:
            selected_name = self.selected_card.name
            selected_id = self.selected_card.card_id
            for stem in self.image_mgr.get_available_images():
                path = self.image_mgr.get_available_image_path(stem)
                if not path:
                    continue
                if selected_name not in stem and selected_id not in stem:
                    continue
                key = os.path.normcase(path)
                if key in seen_paths:
                    continue
                candidates.insert(0, ImageCandidate(
                    name=stem,
                    path=path,
                    rel_path=self.image_mgr._rel_path(path),
                    group=os.path.basename(os.path.dirname(path)),
                    assigned=True,
                    size_bytes=os.path.getsize(path) if os.path.exists(path) else 0,
                ))
                seen_paths.add(key)

        self.image_candidates = candidates

    def _selected_record(self):
        if not self.selected_card:
            return None
        return self.image_mgr.get_card_image_record(self.selected_card.card)

    def _subtype_label(self, card) -> str:
        if card.is_pokemon:
            energy = card.energy_types[0] if card.energy_types else "Colorless"
            cn = ENERGY_CN.get(energy, energy)
            sub = card.subtypes[0] if card.subtypes else ""
            sub_cn = SUBTYPE_CN.get(sub, sub)
            return f"{cn} · {sub_cn}"
        if card.is_trainer:
            sub = card.subtypes[0] if card.subtypes else "Trainer"
            return SUBTYPE_CN.get(sub, sub)
        return "基本能量" if card.is_basic_energy else "特殊能量"

    def _type_color(self, card) -> tuple[int, int, int]:
        if card.is_pokemon and card.energy_types:
            return TYPE_COLORS.get(card.energy_types[0], TYPE_COLORS["Colorless"])
        if card.is_trainer:
            return TYPE_COLORS["Trainer"]
        if card.is_energy:
            return TYPE_COLORS["Energy"]
        return TYPE_COLORS["Colorless"]

    def _set_toast(self, text: str, seconds: float = 3.0):
        self._toast_text = text
        self._toast_timer = seconds

    # ── Controls ──

    def _filter_tabs(self) -> list[tuple[str, str]]:
        return [
            ("missing", "缺图"),
            ("mapped", "已有图"),
            ("all", "全部"),
            ("duplicates", "同名卡"),
            ("orphans", "未引用图"),
        ]

    def _button_rects(self) -> dict[str, pygame.Rect]:
        names = ["paste", "url", "bind", "delete", "normalize", "rescan", "return"]
        btn_w, btn_h, gap = 108, 36, 8
        total = len(names) * btn_w + (len(names) - 1) * gap
        start_x = (SCREEN_WIDTH - total) // 2
        y = SCREEN_HEIGHT - btn_h - 12
        return {
            name: pygame.Rect(start_x + i * (btn_w + gap), y, btn_w, btn_h)
            for i, name in enumerate(names)
        }

    def _search_rect(self) -> pygame.Rect:
        return pygame.Rect(24, HEADER_H + 9, SEARCH_BOX_W, SEARCH_BOX_H)

    def _url_rect(self) -> pygame.Rect:
        return pygame.Rect(CENTER_X + 12, WORK_BOTTOM - 42, CENTER_W - 24, 30)

    @staticmethod
    def _panel_list_inner_rect(x: int, w: int) -> pygame.Rect:
        rect = pygame.Rect(x, WORK_TOP, w, WORK_H).inflate(-18, -56)
        rect.y += 34
        return rect

    def _card_list_inner_rect(self) -> pygame.Rect:
        return self._panel_list_inner_rect(LEFT_X, LEFT_W)

    def _candidate_list_inner_rect(self) -> pygame.Rect:
        return self._panel_list_inner_rect(RIGHT_X, RIGHT_W)

    # ── Events ──

    def handle_event(self, event: pygame.event.Event):
        if self._confirm_action:
            self._handle_confirm_event(event)
            return

        if event.type == pygame.KEYDOWN:
            if self._handle_text_input(event):
                return
            if event.key == pygame.K_ESCAPE:
                self.manager.pop_screen()
                return
            if event.key == pygame.K_v and (pygame.key.get_mods() & pygame.KMOD_CTRL):
                self._paste_from_clipboard()
                return
            if event.key == pygame.K_f and (pygame.key.get_mods() & pygame.KMOD_CTRL):
                self._search_active = True
                self._url_active = False
                self.search_query = ""
                self._apply_filter_and_sort()
                return
            if event.key == pygame.K_u and (pygame.key.get_mods() & pygame.KMOD_CTRL):
                self._url_active = True
                self._search_active = False
                return
            if event.key in (pygame.K_DELETE, pygame.K_BACKSPACE) and not self._search_active:
                self._request_delete_selected()
                return
            if event.key == pygame.K_RETURN and self.pending_image:
                self._bind_pending_image()
                return
            self._handle_navigation(event)
            return

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

        if event.type == pygame.MOUSEMOTION:
            self._hover(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._click(event.pos)
        elif event.type == pygame.MOUSEWHEEL:
            self._handle_wheel(event)

    def _handle_text_input(self, event) -> bool:
        if self._search_active:
            if event.key == pygame.K_ESCAPE:
                self._search_active = False
                return True
            if event.key == pygame.K_RETURN:
                self._search_active = False
                return True
            if event.key == pygame.K_BACKSPACE:
                self.search_query = self.search_query[:-1]
            elif event.unicode and event.unicode.isprintable():
                self.search_query += event.unicode
            else:
                return False
            self.card_scroll = 0.0
            self._apply_filter_and_sort()
            self._build_image_candidates()
            return True

        if self._url_active:
            if event.key == pygame.K_ESCAPE:
                self._url_active = False
                return True
            if event.key == pygame.K_RETURN:
                self._url_active = False
                if self.url_query.strip():
                    self._start_download(self.url_query.strip())
                return True
            if event.key == pygame.K_BACKSPACE:
                self.url_query = self.url_query[:-1]
            elif event.unicode and event.unicode.isprintable():
                self.url_query += event.unicode
            else:
                return False
            return True
        return False

    def _handle_navigation(self, event):
        if not self.display_cards:
            return
        page = max(1, int(self._card_list_inner_rect().h // ROW_H) - 2)
        if event.key == pygame.K_UP:
            self._selected_index = max(0, self._selected_index - 1)
        elif event.key == pygame.K_DOWN:
            self._selected_index = min(len(self.display_cards) - 1, self._selected_index + 1)
        elif event.key == pygame.K_PAGEUP:
            self._selected_index = max(0, self._selected_index - page)
        elif event.key == pygame.K_PAGEDOWN:
            self._selected_index = min(len(self.display_cards) - 1, self._selected_index + page)
        elif event.key == pygame.K_HOME:
            self._selected_index = 0
        elif event.key == pygame.K_END:
            self._selected_index = len(self.display_cards) - 1
        else:
            return
        self.selected_card = self.display_cards[self._selected_index]
        self._scroll_to_selected()
        self._build_image_candidates()

    def _handle_wheel(self, event):
        mx = event.pos[0] if hasattr(event, "pos") else 0
        if mx < CENTER_X:
            self.card_scroll -= event.y * ROW_H * 0.8
        else:
            self.candidate_scroll -= event.y * CANDIDATE_ROW_H * 0.8

    def _scroll_to_selected(self):
        visible_h = self._card_list_inner_rect().h
        row_top = max(0, self._selected_index) * ROW_H
        row_bottom = row_top + ROW_H
        if row_top < self.card_scroll:
            self.card_scroll = row_top
        elif row_bottom > self.card_scroll + visible_h:
            self.card_scroll = row_bottom - visible_h

    def _hover(self, pos):
        mx, my = pos
        self.hovered_card_idx = None
        self.hovered_candidate_idx = None
        self.hovered_button = None

        card_inner = self._card_list_inner_rect()
        if card_inner.collidepoint(pos):
            idx = int((my - card_inner.y + self.card_scroll) // ROW_H)
            if 0 <= idx < len(self.display_cards):
                self.hovered_card_idx = idx

        candidate_inner = self._candidate_list_inner_rect()
        if candidate_inner.collidepoint(pos):
            idx = int((my - candidate_inner.y + self.candidate_scroll) // CANDIDATE_ROW_H)
            if 0 <= idx < len(self.image_candidates):
                self.hovered_candidate_idx = idx

        for name, rect in self._button_rects().items():
            if rect.collidepoint(pos):
                self.hovered_button = name
                break

    def _click(self, pos):
        self._hover(pos)
        if self._search_rect().collidepoint(pos):
            self._search_active = True
            self._url_active = False
            return
        if self._url_rect().collidepoint(pos):
            self._url_active = True
            self._search_active = False
            return

        tab_x = self._search_rect().right + 18
        for key, _label in self._filter_tabs():
            tab_rect = pygame.Rect(tab_x, HEADER_H + 9, 82, TAB_H)
            if tab_rect.collidepoint(pos):
                self.filter_type = key
                self.card_scroll = 0.0
                self._apply_filter_and_sort()
                self._build_image_candidates()
                return
            tab_x += 90

        sort_rect = pygame.Rect(SCREEN_WIDTH - 124, HEADER_H + 9, 104, TAB_H)
        if sort_rect.collidepoint(pos):
            self.sort_mode = {"status": "name", "name": "type", "type": "status"}[self.sort_mode]
            self._apply_filter_and_sort()
            return

        if self.hovered_card_idx is not None:
            self._selected_index = self.hovered_card_idx
            self.selected_card = self.display_cards[self._selected_index]
            self._build_image_candidates()
            return

        if self.hovered_candidate_idx is not None:
            cand = self.image_candidates[self.hovered_candidate_idx]
            self.pending_image = PendingImage(cand.path, cand.name, cand.group, is_temp=False)
            self._set_toast(f"已选择候选图: {cand.name}", 2.0)
            return

        self._handle_button_click()

    def _handle_button_click(self):
        if self.hovered_button == "paste":
            self._paste_from_clipboard()
        elif self.hovered_button == "url":
            self._url_active = True
            self._search_active = False
        elif self.hovered_button == "bind":
            self._bind_pending_image()
        elif self.hovered_button == "delete":
            self._request_delete_selected()
        elif self.hovered_button == "normalize":
            self._confirm_action = "normalize"
            self._confirm_message = "将现有映射规范化为 api_id -> 卡名__api_id.ext？"
        elif self.hovered_button == "rescan":
            self.image_mgr.reload()
            self._apply_filter_and_sort()
            self._build_image_candidates()
            self._set_toast("已重新扫描图片目录", 2.0)
        elif self.hovered_button == "return":
            self.manager.pop_screen()

    # ── Image input ──

    def _handle_file_drop(self, file_path: str):
        if not self.selected_card:
            self._set_toast("请先选择一张卡牌", 2.5)
            return
        if not os.path.isfile(file_path):
            self._set_toast(f"找不到文件: {os.path.basename(file_path)}", 2.5)
            return
        ext = os.path.splitext(file_path)[1].lower()
        if ext not in VALID_IMAGE_EXTS and not _detect_image_ext(file_path):
            self._set_toast("无法识别图片格式，请使用 png/jpg/webp 等图片", 3.0)
            return
        self.pending_image = PendingImage(file_path, os.path.basename(file_path), "拖入文件")
        self._set_toast("已载入候选图，点击“绑定候选”确认", 2.5)

    def _handle_text_drop(self, text: str):
        text = text.strip()
        if text.startswith(("http://", "https://")):
            self._start_download(text)
        elif text.startswith("data:image/"):
            self._load_data_url(text)
        elif os.path.isfile(text):
            self._handle_file_drop(text)
        else:
            self._set_toast(f"无法识别拖入内容: {text[:36]}", 3.0)

    def _start_download(self, url: str):
        if not self.selected_card:
            self._set_toast("请先选择一张卡牌", 2.5)
            return
        if self._download_active:
            self._set_toast("已有下载任务进行中", 2.0)
            return
        self._download_active = True
        self._set_toast("正在后台下载卡图...", 999.0)

        def worker():
            try:
                import requests
                resp = requests.get(url, timeout=15, headers={
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
                })
                resp.raise_for_status()
                ext = self._extension_from_response(url, resp.headers.get("Content-Type", ""))
                with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
                    f.write(resp.content)
                    temp_path = f.name
                self._download_queue.put(("ok", temp_path, os.path.basename(urlparse(url).path) or url))
            except Exception as e:
                self._download_queue.put(("error", str(e), ""))

        self._download_thread = threading.Thread(target=worker, daemon=True, name="card-image-download")
        self._download_thread.start()

    @staticmethod
    def _extension_from_response(url: str, content_type: str) -> str:
        lowered = content_type.lower()
        if "png" in lowered:
            return ".png"
        if "jpeg" in lowered or "jpg" in lowered:
            return ".jpg"
        if "gif" in lowered:
            return ".gif"
        if "bmp" in lowered:
            return ".bmp"
        if "webp" in lowered:
            return ".webp"
        ext = os.path.splitext(urlparse(url).path)[1].lower()
        return ext if ext in VALID_IMAGE_EXTS else ".webp"

    def _load_data_url(self, data_url: str):
        if not self.selected_card:
            self._set_toast("请先选择一张卡牌", 2.5)
            return
        try:
            header, encoded = data_url.split(",", 1)
            mime_type = header.split("image/")[1].split(";")[0]
            ext = ".jpg" if mime_type == "jpeg" else f".{mime_type}"
            content = base64.b64decode(encoded)
            with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
                f.write(content)
                temp_path = f.name
            self.pending_image = PendingImage(temp_path, f"剪贴图像{ext}", "data URL", is_temp=True)
            self._set_toast("已载入候选图，点击“绑定候选”确认", 2.5)
        except Exception as e:
            self._set_toast(f"解析图片数据失败: {e}", 3.0)

    def _paste_from_clipboard(self):
        if not self.selected_card:
            self._set_toast("请先选择一张卡牌", 2.0)
            return
        try:
            from PIL import ImageGrab
            img = ImageGrab.grabclipboard()
        except Exception:
            img = None
        if img is None:
            self._set_toast("剪贴板中没有图片", 2.5)
            return
        try:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
                img.save(f, format="PNG")
                temp_path = f.name
            self.pending_image = PendingImage(temp_path, "剪贴板图片.png", "剪贴板", is_temp=True)
            self._set_toast("已载入候选图，点击“绑定候选”确认", 2.5)
        except Exception as e:
            self._set_toast(f"粘贴失败: {e}", 3.0)

    def _bind_pending_image(self):
        if not self.selected_card:
            self._set_toast("请先选择一张卡牌", 2.0)
            return
        if not self.pending_image:
            self._set_toast("还没有候选图", 2.0)
            return
        ok = self.image_mgr.assign_card_image_for_card(self.selected_card.card, self.pending_image.path)
        if not ok:
            self._set_toast("绑定失败，请检查文件权限或格式", 3.0)
            return
        if self.pending_image.is_temp:
            try:
                os.remove(self.pending_image.path)
            except OSError:
                pass
        target_name = self.image_mgr.generate_card_filename(
            self.selected_card.card,
            os.path.splitext(self.pending_image.path)[1] or ".webp",
        )
        self.pending_image = None
        self.image_mgr.reload()
        self._apply_filter_and_sort()
        self._build_image_candidates()
        self._set_toast(f"已绑定: {target_name}", 3.0)
        self._advance_to_next_missing()

    def _advance_to_next_missing(self):
        if self.filter_type != "missing":
            return
        self._apply_filter_and_sort()
        if self.display_cards:
            self._selected_index = min(self._selected_index, len(self.display_cards) - 1)
            self.selected_card = self.display_cards[self._selected_index]
            self._scroll_to_selected()

    def _request_delete_selected(self):
        if not self.selected_card:
            self._set_toast("请先选择一张卡牌", 2.0)
            return
        record = self._selected_record()
        if not record:
            self._set_toast("当前卡牌没有可删除的卡图", 2.5)
            return
        self._confirm_action = "delete_card"
        self._confirm_message = f"确认删除「{self.selected_card.name}」的卡图文件？"

    # ── Confirm dialog ──

    def _handle_confirm_event(self, event):
        if event.type == pygame.MOUSEMOTION:
            self._hover_confirm(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self._confirm_hover_yes:
                self._run_confirmed_action()
            elif self._confirm_hover_no:
                self._confirm_action = None
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                self._confirm_action = None
            elif event.key == pygame.K_RETURN:
                self._run_confirmed_action()

    def _run_confirmed_action(self):
        action = self._confirm_action
        self._confirm_action = None
        if action == "normalize":
            report = self.image_mgr.normalize_card_image_library([e.card for e in self._all_cards])
            self.image_mgr.reload()
            self._apply_filter_and_sort()
            self._build_image_candidates()
            self._set_toast(report.message, 4.0)
        elif action == "delete_card" and self.selected_card:
            result = self.image_mgr.delete_card_image_for_card(self.selected_card.card)
            self.image_mgr.reload()
            self._apply_filter_and_sort()
            self._build_image_candidates()
            self._set_toast(result.message, 3.5)

    def _hover_confirm(self, pos):
        self._confirm_hover_yes = False
        self._confirm_hover_no = False
        rect = self._confirm_rect()
        yes = pygame.Rect(rect.x + 112, rect.y + 128, 86, 36)
        no = pygame.Rect(rect.x + 242, rect.y + 128, 86, 36)
        self._confirm_hover_yes = yes.collidepoint(pos)
        self._confirm_hover_no = no.collidepoint(pos)

    @staticmethod
    def _confirm_rect() -> pygame.Rect:
        return pygame.Rect((SCREEN_WIDTH - 460) // 2, (SCREEN_HEIGHT - 210) // 2, 460, 210)

    # ── Update / Draw ──

    def update(self, dt: float):
        if self._toast_timer > 0:
            self._toast_timer -= dt
            if self._toast_timer <= 0:
                self._toast_text = None

        if self._search_active or self._url_active:
            self._cursor_blink = (self._cursor_blink + dt) % 1.0

        self._poll_download()
        self._clamp_scroll()

    def _poll_download(self):
        try:
            status, value, label = self._download_queue.get_nowait()
        except queue.Empty:
            return
        self._download_active = False
        if status == "ok":
            self.pending_image = PendingImage(value, label, "URL 下载", is_temp=True)
            self._set_toast("下载完成，点击“绑定候选”确认", 3.0)
        else:
            self._set_toast(f"下载失败: {value}", 4.0)

    def _clamp_scroll(self):
        card_h = len(self.display_cards) * ROW_H
        cand_h = len(self.image_candidates) * CANDIDATE_ROW_H
        self.card_scroll = max(0.0, min(
            self.card_scroll,
            max(0.0, card_h - self._card_list_inner_rect().h),
        ))
        self.candidate_scroll = max(0.0, min(
            self.candidate_scroll,
            max(0.0, cand_h - self._candidate_list_inner_rect().h),
        ))

    def draw(self, surface: pygame.Surface):
        surface.fill(UI_BG_DARK)
        self._draw_header(surface)
        self._draw_filter_bar(surface)
        self._draw_card_queue(surface)
        self._draw_current_card(surface)
        self._draw_candidate_panel(surface)
        self._draw_bottom_bar(surface)
        self._draw_toast(surface)
        if self._confirm_action:
            self._draw_confirm_dialog(surface)

    def _draw_header(self, surface):
        title = self.font_title.render("卡图管理工作台", True, UI_HIGHLIGHT)
        surface.blit(title, (16, 7))
        total = len(self._all_cards)
        mapped = sum(1 for e in self._all_cards if e.has_image)
        missing = total - mapped
        duplicates = sum(1 for e in self._all_cards if e.is_duplicate_name)
        stats = self.font_small.render(
            f"已绑定 {mapped}/{total} · 缺图 {missing} · 同名卡 {duplicates}",
            True,
            UI_SUCCESS if missing == 0 else UI_TEXT_SECONDARY,
        )
        surface.blit(stats, (SCREEN_WIDTH - stats.get_width() - 16, 12))

        hint = self.font_tiny.render(
            "Ctrl+F 搜索 · Ctrl+U 输入URL · Ctrl+V 粘贴 · Enter 绑定候选 · Del 删除 · ESC 返回",
            True,
            UI_TEXT_SECONDARY,
        )
        surface.blit(hint, hint.get_rect(center=(SCREEN_WIDTH // 2, 29)))

    def _draw_filter_bar(self, surface):
        rect = pygame.Rect(12, HEADER_H, SCREEN_WIDTH - 24, FILTER_H - 4)
        draw_panel(surface, rect)

        search = self._search_rect()
        pygame.draw.rect(surface, (40, 50, 80) if self._search_active else (28, 33, 46),
                         search, border_radius=4)
        pygame.draw.rect(surface, UI_HIGHLIGHT if self._search_active else UI_BORDER,
                         search, 2 if self._search_active else 1, border_radius=4)
        query = self.search_query if self.search_query else "搜索卡名 / api_id / 类型..."
        color = UI_TEXT_PRIMARY if self.search_query else (95, 100, 120)
        txt = self.font_search.render(query, True, color)
        surface.blit(txt, (search.x + 8, search.y + 4))
        if self._search_active and self._cursor_blink < 0.5:
            x = min(search.right - 8, search.x + 10 + txt.get_width())
            pygame.draw.line(surface, UI_HIGHLIGHT, (x, search.y + 5), (x, search.bottom - 5), 2)

        tab_x = search.right + 18
        for key, label in self._filter_tabs():
            tab = pygame.Rect(tab_x, HEADER_H + 9, 82, TAB_H)
            active = self.filter_type == key
            bg = (60, 82, 128) if active else (35, 38, 50)
            pygame.draw.rect(surface, bg, tab, border_radius=4)
            pygame.draw.rect(surface, UI_HIGHLIGHT if active else UI_BORDER, tab, 1, border_radius=4)
            text = self.font_small.render(label, True, UI_TEXT_PRIMARY if active else UI_TEXT_SECONDARY)
            surface.blit(text, text.get_rect(center=tab.center))
            tab_x += 90

        sort_labels = {"status": "缺图优先", "name": "按名称", "type": "按类型"}
        sort = pygame.Rect(SCREEN_WIDTH - 124, HEADER_H + 9, 104, TAB_H)
        draw_button(surface, sort, sort_labels[self.sort_mode], self.font_small)

    def _draw_card_queue(self, surface):
        panel = pygame.Rect(LEFT_X, WORK_TOP, LEFT_W, WORK_H)
        draw_panel(surface, panel, "卡牌队列", self.font_body)
        inner = self._card_list_inner_rect()
        surface.set_clip(inner)

        if not self.display_cards:
            message = "未引用图片请看右侧列表" if self.filter_type == "orphans" else "没有符合条件的卡牌"
            txt = self.font_body.render(message, True, UI_TEXT_SECONDARY)
            surface.blit(txt, txt.get_rect(center=inner.center))
            surface.set_clip(None)
            return

        start = max(0, int(self.card_scroll // ROW_H))
        end = min(len(self.display_cards), start + int(inner.h // ROW_H) + 2)
        for idx in range(start, end):
            entry = self.display_cards[idx]
            row_y = inner.y + idx * ROW_H - self.card_scroll
            row = pygame.Rect(inner.x, row_y, inner.w, ROW_H - 2)
            selected = idx == self._selected_index
            hovered = idx == self.hovered_card_idx
            bg = (50, 80, 130) if selected else ((40, 50, 70) if hovered else (25, 30, 44))
            pygame.draw.rect(surface, bg, row, border_radius=4)
            if selected:
                pygame.draw.rect(surface, UI_HIGHLIGHT, row, 2, border_radius=4)

            status_color = UI_SUCCESS if entry.has_image else (160, 130, 90)
            status = self.font_small.render("✓" if entry.has_image else "!", True, status_color)
            surface.blit(status, (row.x + 7, row.y + 7))
            pygame.draw.rect(surface, self._type_color(entry.card),
                             (row.x + 28, row.y + 10, 12, 12), border_radius=3)
            name_rect = pygame.Rect(row.x + 48, row.y + 2, row.w - 170, 17)
            draw_text_fit(surface, self.font_small, entry.name,
                          UI_HIGHLIGHT if selected else UI_TEXT_PRIMARY, name_rect)
            id_color = (230, 190, 90) if entry.is_duplicate_name else UI_TEXT_SECONDARY
            id_rect = pygame.Rect(row.x + 48, row.y + 17, row.w - 170, 14)
            draw_text_fit(surface, self.font_tiny, entry.card_id, id_color, id_rect)
            sub = self.font_tiny.render(self._subtype_label(entry.card), True, UI_TEXT_SECONDARY)
            surface.blit(sub, (row.right - sub.get_width() - 8, row.y + 9))

        self._draw_scrollbar(surface, inner, len(self.display_cards) * ROW_H, self.card_scroll)
        surface.set_clip(None)

    def _draw_current_card(self, surface):
        panel = pygame.Rect(CENTER_X, WORK_TOP, CENTER_W, WORK_H)
        draw_panel(surface, panel, "当前卡牌", self.font_body)
        inner = panel.inflate(-22, -56)
        inner.y += 34

        if not self.selected_card:
            txt = self.font_body.render("从左侧选择一张卡牌", True, UI_TEXT_SECONDARY)
            surface.blit(txt, txt.get_rect(center=inner.center))
            self._draw_url_box(surface)
            return

        entry = self.selected_card
        preview = pygame.Rect(inner.x, inner.y, 210, 294)
        self._draw_card_preview(surface, preview, entry)

        info_x = preview.right + 18
        title_rect = pygame.Rect(info_x, inner.y, inner.right - info_x, 28)
        draw_text_fit(surface, self.font_title, entry.name, UI_HIGHLIGHT, title_rect)
        meta_lines = [
            f"api_id: {entry.card_id}",
            f"类型: {self._subtype_label(entry.card)}",
        ]
        if entry.is_duplicate_name:
            meta_lines.append("同名卡: 请使用 api_id 区分")
        if getattr(entry.card, "hp", 0):
            meta_lines.append(f"HP: {entry.card.hp}")
        if getattr(entry.card, "attacks", None):
            attacks = " / ".join(atk.name for atk in entry.card.attacks[:2])
            meta_lines.append(f"招式: {attacks}")
        y = title_rect.bottom + 8
        for line in meta_lines:
            draw_text_fit(surface, self.font_small, line, UI_TEXT_SECONDARY,
                          pygame.Rect(info_x, y, inner.right - info_x, 20))
            y += 22

        record = self._selected_record()
        box_y = preview.bottom + 18
        current_box = pygame.Rect(inner.x, box_y, inner.w, 96)
        pygame.draw.rect(surface, (24, 30, 44), current_box, border_radius=6)
        pygame.draw.rect(surface, UI_BORDER, current_box, 1, border_radius=6)
        header = "当前绑定" if record else "当前绑定"
        surface.blit(self.font_small.render(header, True, UI_HIGHLIGHT), (current_box.x + 10, current_box.y + 8))
        if record:
            lines = [
                f"文件: {record.filename}",
                f"路径: {record.rel_path}",
            ]
        else:
            lines = ["暂无卡图，可拖入图片、粘贴剪贴板、输入 URL 或从右侧候选选择。"]
        ly = current_box.y + 32
        for line in lines:
            draw_text_fit(surface, self.font_tiny, line, UI_TEXT_SECONDARY,
                          pygame.Rect(current_box.x + 10, ly, current_box.w - 20, 17))
            ly += 18

        candidate_box = pygame.Rect(inner.x, current_box.bottom + 12, inner.w, 118)
        pygame.draw.rect(surface, (24, 30, 44), candidate_box, border_radius=6)
        pygame.draw.rect(surface, UI_HIGHLIGHT if self.pending_image else UI_BORDER,
                         candidate_box, 1, border_radius=6)
        surface.blit(self.font_small.render("候选图", True, UI_HIGHLIGHT), (candidate_box.x + 10, candidate_box.y + 8))
        if self.pending_image:
            lines = [
                f"来源: {self.pending_image.source}",
                f"文件: {self.pending_image.label}",
                f"目标: {self.image_mgr.generate_card_filename(entry.card, os.path.splitext(self.pending_image.path)[1])}",
            ]
        else:
            lines = ["右侧点击图片、拖入文件、Ctrl+V 粘贴或 Ctrl+U 输入 URL 后在这里确认。"]
        ly = candidate_box.y + 34
        for line in lines:
            draw_text_fit(surface, self.font_tiny, line, UI_TEXT_SECONDARY,
                          pygame.Rect(candidate_box.x + 10, ly, candidate_box.w - 20, 17))
            ly += 19

        self._draw_drop_zone(surface, pygame.Rect(inner.x, candidate_box.bottom + 12, inner.w, 34))
        self._draw_url_box(surface)

    def _draw_card_preview(self, surface, rect, entry: CardEntry):
        pygame.draw.rect(surface, (20, 24, 36), rect, border_radius=8)
        pygame.draw.rect(surface, UI_BORDER, rect, 1, border_radius=8)
        img = self.image_mgr.get_card_image(entry.name, entry.card_id)
        if img:
            try:
                scaled = pygame.transform.smoothscale(img, rect.size)
                surface.blit(scaled, rect.topleft)
                return
            except Exception:
                pass
        pygame.draw.rect(surface, self._type_color(entry.card), rect.inflate(-18, -18), border_radius=7)
        name = self.font_body.render(entry.name, True, UI_TEXT_PRIMARY)
        surface.blit(name, name.get_rect(center=(rect.centerx, rect.centery - 8)))
        sub = self.font_tiny.render(self._subtype_label(entry.card), True, UI_TEXT_PRIMARY)
        surface.blit(sub, sub.get_rect(center=(rect.centerx, rect.centery + 20)))

    def _draw_drop_zone(self, surface, rect):
        color = (54, 88, 140) if self._drag_active else (26, 33, 48)
        text = "释放文件以设为候选图" if self._drag_active else "拖入图片到窗口任意位置，或点击右侧候选图"
        pygame.draw.rect(surface, color, rect, border_radius=5)
        pygame.draw.rect(surface, (90, 140, 210) if self._drag_active else UI_BORDER, rect, 1, border_radius=5)
        txt = self.font_tiny.render(text, True, UI_TEXT_SECONDARY)
        surface.blit(txt, txt.get_rect(center=rect.center))

    def _draw_url_box(self, surface):
        rect = self._url_rect()
        pygame.draw.rect(surface, (40, 50, 80) if self._url_active else (26, 33, 48),
                         rect, border_radius=5)
        pygame.draw.rect(surface, UI_HIGHLIGHT if self._url_active else UI_BORDER,
                         rect, 2 if self._url_active else 1, border_radius=5)
        text = self.url_query or "Ctrl+U 后粘贴图片 URL，Enter 后台下载"
        color = UI_TEXT_PRIMARY if self.url_query else UI_TEXT_SECONDARY
        draw_text_fit(surface, self.font_small, text, color, rect.inflate(-16, -4))

    def _draw_candidate_panel(self, surface):
        panel = pygame.Rect(RIGHT_X, WORK_TOP, RIGHT_W, WORK_H)
        title = "未引用/候选图片"
        draw_panel(surface, panel, title, self.font_body)
        inner = self._candidate_list_inner_rect()
        surface.set_clip(inner)
        if not self.image_candidates:
            msg = self.font_body.render("没有未引用候选图", True, UI_TEXT_SECONDARY)
            surface.blit(msg, msg.get_rect(center=inner.center))
            surface.set_clip(None)
            return

        start = max(0, int(self.candidate_scroll // CANDIDATE_ROW_H))
        end = min(len(self.image_candidates), start + int(inner.h // CANDIDATE_ROW_H) + 2)
        for idx in range(start, end):
            cand = self.image_candidates[idx]
            row_y = inner.y + idx * CANDIDATE_ROW_H - self.candidate_scroll
            row = pygame.Rect(inner.x, row_y, inner.w, CANDIDATE_ROW_H - 2)
            hovered = idx == self.hovered_candidate_idx
            pygame.draw.rect(surface, (40, 56, 82) if hovered else (25, 30, 44), row, border_radius=4)
            draw_text_fit(surface, self.font_small, cand.name, UI_TEXT_PRIMARY,
                          pygame.Rect(row.x + 8, row.y + 2, row.w - 116, 17))
            subtitle = f"{cand.group} · {cand.size_bytes // 1024} KB"
            draw_text_fit(surface, self.font_tiny, subtitle, UI_TEXT_SECONDARY,
                          pygame.Rect(row.x + 8, row.y + 17, row.w - 116, 13))
            label = "已引用" if cand.assigned else "未引用"
            color = UI_SUCCESS if cand.assigned else (210, 160, 90)
            tag = self.font_tiny.render(label, True, color)
            surface.blit(tag, (row.right - tag.get_width() - 8, row.y + 9))

        self._draw_scrollbar(surface, inner, len(self.image_candidates) * CANDIDATE_ROW_H,
                             self.candidate_scroll)
        surface.set_clip(None)

    def _draw_bottom_bar(self, surface):
        labels = {
            "paste": "粘贴",
            "url": "URL",
            "bind": "绑定候选",
            "delete": "删除卡图",
            "normalize": "规范化",
            "rescan": "重扫",
            "return": "返回",
        }
        for name, rect in self._button_rects().items():
            enabled = True
            if name == "bind":
                enabled = self.pending_image is not None and self.selected_card is not None
            if name == "delete":
                enabled = self._selected_record() is not None
            draw_button(
                surface,
                rect,
                labels[name],
                self.font_small,
                hovered=self.hovered_button == name,
                selected=name in ("bind", "normalize") and enabled,
                danger=name == "delete",
                enabled=enabled,
            )

        if self.selected_card:
            selected = self.font_small.render(
                f"已选中: {self.selected_card.name}  [{self.selected_card.card_id}]",
                True,
                UI_HIGHLIGHT,
            )
            surface.blit(selected, (20, SCREEN_HEIGHT - 48))

    def _draw_scrollbar(self, surface, rect, content_h: float, scroll: float):
        if content_h <= rect.h:
            return
        bar_h = max(32, int(rect.h * rect.h / content_h))
        bar_y = rect.y + int(scroll * rect.h / content_h)
        pygame.draw.rect(surface, (80, 86, 110), (rect.right - 6, bar_y, 5, bar_h), border_radius=3)

    def _draw_toast(self, surface):
        if not self._toast_text:
            return
        toast = self.font_small.render(self._toast_text, True, (35, 38, 45))
        bg = pygame.Rect((SCREEN_WIDTH - toast.get_width()) // 2 - 16,
                         SCREEN_HEIGHT - 112, toast.get_width() + 32, toast.get_height() + 16)
        alpha = 220 if self._toast_timer > 0.5 else max(0, int(220 * self._toast_timer / 0.5))
        layer = pygame.Surface(bg.size, pygame.SRCALPHA)
        layer.fill((220, 228, 155, alpha))
        pygame.draw.rect(layer, (130, 160, 70, alpha), layer.get_rect(), 1, border_radius=6)
        surface.blit(layer, bg.topleft)
        surface.blit(toast, (bg.x + 16, bg.y + 8))

    def _draw_confirm_dialog(self, surface):
        dim = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 165))
        surface.blit(dim, (0, 0))
        rect = self._confirm_rect()
        draw_panel(surface, rect, "确认操作", self.font_body)
        lines = [self._confirm_message, "此操作会改动本地图片或映射文件。"]
        y = rect.y + 70
        for line in lines:
            draw_text_fit(surface, self.font_small, line, UI_TEXT_PRIMARY,
                          pygame.Rect(rect.x + 28, y, rect.w - 56, 22))
            y += 28
        yes = pygame.Rect(rect.x + 112, rect.y + 128, 86, 36)
        no = pygame.Rect(rect.x + 242, rect.y + 128, 86, 36)
        draw_button(surface, yes, "确认", self.font_small, hovered=self._confirm_hover_yes, danger=True)
        draw_button(surface, no, "取消", self.font_small, hovered=self._confirm_hover_no)

"""In-app visual runner for challenge AI policy training."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from typing import Any

import pygame

from config import SCREEN_HEIGHT, SCREEN_WIDTH
from engine.ai.training import DEFAULT_CANDIDATE_OUTPUT, DEFAULT_WORKERS, DECK_SPECS, TRAINABLE_KEYS
from ui.colors import UI_DANGER, UI_HIGHLIGHT, UI_SUCCESS, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY
from ui.font_manager import get_font
from ui.screen_manager import Screen, ScreenManager
from ui.ui_theme import draw_button, draw_panel, draw_text_fit


DECK_LABELS = {
    "all": "全部",
    "fire": "火",
    "water": "水",
    "psychic": "超",
    "lightning": "雷",
    "fighting": "斗",
    "colorless": "无色",
    "dragon": "龙",
    "grass": "草",
}

WEIGHT_LABELS = {
    "core_in_play": "核心在场",
    "core_in_hand": "核心手牌",
    "engine_in_play": "引擎在场",
    "engine_in_hand": "引擎手牌",
    "preferred_bench": "理想备战",
    "evolved_count": "进化价值",
    "matching_energy_attached": "已贴能量",
    "matching_energy_hand": "手牌能量",
    "trainer_in_hand": "训练家手牌",
    "damaged_self": "受伤惩罚",
    "low_hp_targets": "低血目标",
    "ko_pressure": "击倒压力",
    "hand_size": "手牌规模",
    "bench_count": "备战数量",
}


class AITrainingScreen(Screen):
    """Pygame screen that runs the trainer in a background subprocess."""

    def __init__(
        self,
        manager: ScreenManager,
        *,
        output_path: str = DEFAULT_CANDIDATE_OUTPUT,
        policy_path: str = os.path.join("data", "ai_policies.json"),
        progress_path: str = os.path.join("data", "ai_training_progress.jsonl"),
    ):
        super().__init__(manager)
        self.font_title = get_font("title_sm")
        self.font_body = get_font("body_md")
        self.font_small = get_font("small")
        self.font_tiny = get_font("caption")

        self.repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        self.output_path = output_path
        self.policy_path = policy_path
        self.progress_path = progress_path

        self.deck_keys = ["all", *DECK_SPECS.keys()]
        self.selected_deck = "all"
        self.games = 120
        self.seed = 17
        self.eval_games = 20
        self.workers = DEFAULT_WORKERS
        self.benchmark_games = 2
        self.result_view = "matrix"

        self.status = "idle"
        self.status_message = "配置参数后开始训练。"
        self.process: subprocess.Popen | None = None
        self.started_at: float | None = None
        self.elapsed_seconds = 0.0
        self.total_training_games = 0
        self.total_games_played = 0
        self.current_deck = ""
        self.current_stats = {"wins": 0, "losses": 0, "draws": 0}
        self.deck_results: dict[str, dict[str, Any]] = {}
        self.benchmark_results: dict[str, Any] = {}
        self.events: list[dict[str, Any]] = []
        self._progress_offset = 0

        self._controls: list[dict[str, Any]] = []
        self._hover_name: str | None = None
        self._candidate_payload: dict[str, Any] | None = None

        self._bg_surface = self._create_background()

    def _abs_path(self, path: str) -> str:
        if os.path.isabs(path):
            return path
        return os.path.join(self.repo_root, path)

    def _create_background(self) -> pygame.Surface:
        bg = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT))
        for y in range(SCREEN_HEIGHT):
            t = y / SCREEN_HEIGHT
            color = (
                int(12 + 12 * t),
                int(17 + 16 * t),
                int(30 + 18 * t),
            )
            pygame.draw.line(bg, color, (0, y), (SCREEN_WIDTH, y))
        for x in range(0, SCREEN_WIDTH, 80):
            pygame.draw.line(bg, (32, 40, 58), (x, 0), (x, SCREEN_HEIGHT), 1)
        for y in range(0, SCREEN_HEIGHT, 80):
            pygame.draw.line(bg, (32, 40, 58), (0, y), (SCREEN_WIDTH, y), 1)
        return bg

    def handle_event(self, event: pygame.event.Event):
        if event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
            if self.status == "running":
                self._cancel_training()
            else:
                self.manager.pop_screen()
            return

        if event.type == pygame.MOUSEMOTION:
            self._hover_name = None
            for control in self._controls:
                if control["rect"].collidepoint(event.pos):
                    self._hover_name = control["name"]
                    break
            return

        if event.type != pygame.MOUSEBUTTONDOWN or event.button != 1:
            return

        clicked = None
        for control in self._controls:
            if control["rect"].collidepoint(event.pos):
                clicked = control
                break
        if not clicked:
            return
        if not clicked.get("enabled", True):
            return

        name = clicked["name"]
        if name.startswith("deck:") and self.status != "running":
            self.selected_deck = name.split(":", 1)[1]
        elif name.startswith("view:"):
            self.result_view = name.split(":", 1)[1]
        elif name == "games_minus" and self.status != "running":
            self.games = max(1, self.games - 20)
        elif name == "games_plus" and self.status != "running":
            self.games = min(2000, self.games + 20)
        elif name == "seed_minus" and self.status != "running":
            self.seed = max(1, self.seed - 1)
        elif name == "seed_plus" and self.status != "running":
            self.seed += 1
        elif name == "eval_minus" and self.status != "running":
            self.eval_games = max(0, self.eval_games - 1)
        elif name == "eval_plus" and self.status != "running":
            self.eval_games = min(50, self.eval_games + 1)
        elif name == "workers_minus" and self.status != "running":
            self.workers = max(1, self.workers - 1)
        elif name == "workers_plus" and self.status != "running":
            self.workers = min(16, self.workers + 1)
        elif name == "benchmark_minus" and self.status != "running":
            self.benchmark_games = max(0, self.benchmark_games - 1)
        elif name == "benchmark_plus" and self.status != "running":
            self.benchmark_games = min(20, self.benchmark_games + 1)
        elif name == "start" and self.status != "running":
            self._start_training()
        elif name == "cancel" and self.status == "running":
            self._cancel_training()
        elif name == "apply" and self._can_apply():
            self._apply_candidate_policy()
        elif name == "back" and self.status != "running":
            self.manager.pop_screen()

    def update(self, dt: float):
        if self.status == "running" and self.started_at is not None:
            self.elapsed_seconds = time.time() - self.started_at
            self._read_progress_events()
            if self.process and self.process.poll() is not None:
                self._read_progress_events()
                if self.process.returncode == 0:
                    if self.status == "running":
                        self.status = "completed"
                        self.status_message = "训练完成，可预览并应用候选策略。"
                    self._load_candidate_payload()
                elif self.status not in ("cancelled", "error"):
                    self.status = "error"
                    self.status_message = f"训练进程退出码 {self.process.returncode}"
                self.process = None

    def draw(self, surface: pygame.Surface):
        surface.blit(self._bg_surface, (0, 0))
        self._controls.clear()

        title = self.font_title.render("AI 训练", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(SCREEN_WIDTH // 2, 44)))

        self._draw_config_panel(surface)
        self._draw_progress_panel(surface)
        self._draw_results_panel(surface)
        self._draw_events_panel(surface)

    def _draw_config_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(42, 90, 420, 820)
        inner = draw_panel(surface, panel, "训练设置", self.font_body)

        draw_text_fit(surface, self.font_small, "卡组", UI_TEXT_SECONDARY,
                      pygame.Rect(inner.x, inner.y, inner.w, 24))
        y = inner.y + 34
        for idx, key in enumerate(self.deck_keys):
            col = idx % 3
            row = idx // 3
            rect = pygame.Rect(inner.x + col * 126, y + row * 42, 116, 34)
            self._add_button(surface, rect, f"deck:{key}", DECK_LABELS[key],
                             selected=self.selected_deck == key,
                             enabled=self.status != "running")

        y += 142
        self._draw_stepper(surface, "训练局数", self.games, "games_minus", "games_plus", inner.x, y)
        y += 74
        self._draw_stepper(surface, "随机种子", self.seed, "seed_minus", "seed_plus", inner.x, y)
        y += 74
        self._draw_stepper(surface, "评估局数", self.eval_games, "eval_minus", "eval_plus", inner.x, y)

        y += 74
        self._draw_stepper(surface, "并行进程", self.workers, "workers_minus", "workers_plus", inner.x, y)
        y += 74
        self._draw_stepper(surface, "基准赛局", self.benchmark_games, "benchmark_minus", "benchmark_plus", inner.x, y)

        y += 74
        start_rect = pygame.Rect(inner.x, y, 178, 46)
        cancel_rect = pygame.Rect(inner.x + 190, y, 178, 46)
        self._add_button(surface, start_rect, "start", "开始训练",
                         enabled=self.status != "running", attack=True)
        self._add_button(surface, cancel_rect, "cancel", "取消",
                         enabled=self.status == "running", danger=True)

        y += 64
        apply_rect = pygame.Rect(inner.x, y, 178, 46)
        back_rect = pygame.Rect(inner.x + 190, y, 178, 46)
        self._add_button(surface, apply_rect, "apply", "应用候选",
                         enabled=self._can_apply(), selected=self.status == "applied")
        self._add_button(surface, back_rect, "back", "返回",
                         enabled=self.status != "running")

        y += 60
        for line in [
            f"候选文件: {self.output_path}",
            f"正式策略: {self.policy_path}",
            "训练完成前不会覆盖正式策略。",
        ]:
            draw_text_fit(surface, self.font_tiny, line, UI_TEXT_SECONDARY,
                          pygame.Rect(inner.x, y, inner.w, 20))
            y += 22

    def _draw_stepper(
        self,
        surface: pygame.Surface,
        label: str,
        value: int,
        minus_name: str,
        plus_name: str,
        x: int,
        y: int,
    ):
        draw_text_fit(surface, self.font_small, label, UI_TEXT_SECONDARY, pygame.Rect(x, y, 180, 24))
        rect = pygame.Rect(x, y + 30, 368, 42)
        pygame.draw.rect(surface, (24, 30, 46), rect, border_radius=8)
        pygame.draw.rect(surface, (64, 74, 104), rect, 1, border_radius=8)
        self._add_button(surface, pygame.Rect(rect.x + 8, rect.y + 6, 44, 30),
                         minus_name, "-", enabled=self.status != "running")
        self._add_button(surface, pygame.Rect(rect.right - 52, rect.y + 6, 44, 30),
                         plus_name, "+", enabled=self.status != "running")
        value_surf = self.font_body.render(str(value), True, UI_TEXT_PRIMARY)
        surface.blit(value_surf, value_surf.get_rect(center=rect.center))

    def _draw_progress_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(500, 90, 1058, 236)
        inner = draw_panel(surface, panel, "训练进度", self.font_body)

        status_color = {
            "completed": UI_SUCCESS,
            "applied": UI_SUCCESS,
            "error": UI_DANGER,
            "cancelled": UI_DANGER,
            "running": UI_HIGHLIGHT,
        }.get(self.status, UI_TEXT_SECONDARY)
        status_line = f"{self.status.upper()} - {self.status_message}"
        draw_text_fit(surface, self.font_small, status_line, status_color,
                      pygame.Rect(inner.x, inner.y, inner.w, 28))

        progress_rect = pygame.Rect(inner.x, inner.y + 48, inner.w, 30)
        pygame.draw.rect(surface, (24, 30, 46), progress_rect, border_radius=8)
        pygame.draw.rect(surface, (70, 82, 116), progress_rect, 1, border_radius=8)
        ratio = self._progress_ratio()
        fill = progress_rect.copy()
        fill.w = int(progress_rect.w * ratio)
        if fill.w > 0:
            pygame.draw.rect(surface, (68, 158, 116), fill, border_radius=8)
        label = f"{self.total_games_played}/{self.total_training_games or self._planned_training_games()} 局"
        label_surf = self.font_small.render(label, True, UI_TEXT_PRIMARY)
        surface.blit(label_surf, label_surf.get_rect(center=progress_rect.center))

        metric_y = inner.y + 102
        metrics = [
            ("当前卡组", self.current_deck or "-"),
            ("用时", self._format_seconds(self.elapsed_seconds)),
            ("ETA", self._format_seconds(self._eta_seconds())),
            ("胜/负/平", self._stats_text(self.current_stats)),
        ]
        for idx, (name, value) in enumerate(metrics):
            box = pygame.Rect(inner.x + idx * 252, metric_y, 236, 64)
            pygame.draw.rect(surface, (24, 30, 46), box, border_radius=8)
            pygame.draw.rect(surface, (54, 66, 96), box, 1, border_radius=8)
            draw_text_fit(surface, self.font_tiny, name, UI_TEXT_SECONDARY,
                          pygame.Rect(box.x + 10, box.y + 8, box.w - 20, 18))
            draw_text_fit(surface, self.font_small, str(value), UI_TEXT_PRIMARY,
                          pygame.Rect(box.x + 10, box.y + 30, box.w - 20, 24))

    def _draw_results_panel_legacy(self, surface: pygame.Surface):
        panel = pygame.Rect(500, 350, 512, 560)
        inner = draw_panel(surface, panel, "训练效果", self.font_body)

        if not self.deck_results and not self._candidate_payload:
            lines = ["等待训练事件。", "完成后这里会显示候选策略的评估表现。"]
            y = inner.y + 4
            for line in lines:
                draw_text_fit(surface, self.font_small, line, UI_TEXT_SECONDARY,
                              pygame.Rect(inner.x, y, inner.w, 24))
                y += 28
            return

        payload = self._candidate_payload or {}
        policies = payload.get("policies") or {}
        keys = list(policies) or list(self.deck_results)
        y = inner.y
        for deck_key in keys[:8]:
            result = policies.get(deck_key) or self.deck_results.get(deck_key) or {}
            stats = result.get("stats", {})
            eval_data = result.get("eval", {})
            header = f"{DECK_LABELS.get(deck_key, deck_key)}  训练: {self._stats_text(stats)}"
            draw_text_fit(surface, self.font_small, header, UI_TEXT_PRIMARY,
                          pygame.Rect(inner.x, y, inner.w, 24))
            y += 26
            trained = (eval_data.get("trained") or {})
            baseline = (eval_data.get("baseline") or {})
            eval_line = (
                f"评估: 训练 {self._stats_text(trained)} "
                f"基线 {self._stats_text(baseline)}"
            )
            draw_text_fit(surface, self.font_tiny, eval_line, UI_TEXT_SECONDARY,
                          pygame.Rect(inner.x + 8, y, inner.w - 8, 22))
            y += 30
            if y > inner.bottom - 42:
                break

        y += 10
        self._draw_weight_delta(surface, pygame.Rect(inner.x, y, inner.w, inner.bottom - y))

    def _draw_weight_delta(self, surface: pygame.Surface, rect: pygame.Rect):
        deltas = self._weight_deltas()
        if not deltas:
            draw_text_fit(surface, self.font_tiny, "暂无权重变化可预览。", UI_TEXT_SECONDARY, rect)
            return
        draw_text_fit(surface, self.font_small, "主要权重变化", UI_HIGHLIGHT,
                      pygame.Rect(rect.x, rect.y, rect.w, 24))
        y = rect.y + 30
        for key, old, new, delta in deltas[:6]:
            color = UI_SUCCESS if delta >= 0 else UI_DANGER
            line = f"{WEIGHT_LABELS.get(key, key)}: {old:.2f} -> {new:.2f} ({delta:+.2f})"
            draw_text_fit(surface, self.font_tiny, line, color,
                          pygame.Rect(rect.x + 8, y, rect.w - 8, 22))
            y += 24

    def _draw_results_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(500, 350, 512, 560)
        inner = draw_panel(surface, panel, "AI 表现", self.font_body)

        if not self.deck_results and not self._candidate_payload:
            lines = ["等待训练事件。", "完成后这里会显示胜率矩阵、前后对比和排行。"]
            y = inner.y + 4
            for line in lines:
                draw_text_fit(surface, self.font_small, line, UI_TEXT_SECONDARY,
                              pygame.Rect(inner.x, y, inner.w, 24))
                y += 28
            return

        tabs = [
            ("matrix", "矩阵"),
            ("before", "前后"),
            ("ranking", "排行"),
            ("weights", "权重"),
        ]
        tab_w = max(72, (inner.w - 12) // len(tabs))
        for idx, (key, label) in enumerate(tabs):
            rect = pygame.Rect(inner.x + idx * (tab_w + 4), inner.y, tab_w, 30)
            self._add_button(surface, rect, f"view:{key}", label, selected=self.result_view == key)

        content = pygame.Rect(inner.x, inner.y + 42, inner.w, inner.h - 42)
        if self.result_view == "matrix":
            self._draw_matrix_view(surface, content)
        elif self.result_view == "before":
            self._draw_before_after_view(surface, content)
        elif self.result_view == "ranking":
            self._draw_ranking_view(surface, content)
        else:
            self._draw_weight_delta(surface, content)

    def _benchmark_payload(self) -> dict[str, Any]:
        if self._candidate_payload is None:
            self._load_candidate_payload()
        payload = self._candidate_payload or {}
        return payload.get("benchmark") or self.benchmark_results or {}

    def _draw_matrix_view(self, surface: pygame.Surface, rect: pygame.Rect):
        benchmark = self._benchmark_payload()
        matrix = benchmark.get("matrix") or {}
        deck_keys = list(benchmark.get("deck_keys") or matrix.keys())
        if not deck_keys:
            draw_text_fit(surface, self.font_tiny, "暂无胜率矩阵。基准赛局数设为 0 时不会生成。", UI_TEXT_SECONDARY, rect)
            return

        label_w = 74
        cell = min(46, max(28, (rect.w - label_w) // max(1, len(deck_keys))))
        y0 = rect.y + 28
        for col, deck_key in enumerate(deck_keys):
            x = rect.x + label_w + col * cell
            draw_text_fit(surface, self.font_tiny, DECK_LABELS.get(deck_key, deck_key),
                          UI_TEXT_SECONDARY, pygame.Rect(x, rect.y, cell, 22))
        for row, deck_a in enumerate(deck_keys):
            y = y0 + row * cell
            draw_text_fit(surface, self.font_tiny, DECK_LABELS.get(deck_a, deck_a),
                          UI_TEXT_SECONDARY, pygame.Rect(rect.x, y + 8, label_w - 6, 20))
            for col, deck_b in enumerate(deck_keys):
                x = rect.x + label_w + col * cell
                value = 0.5 if deck_a == deck_b else (matrix.get(deck_a) or {}).get(deck_b, {}).get("win_rate")
                if value is None:
                    color = (34, 42, 58)
                    text = "-"
                else:
                    value = max(0.0, min(1.0, float(value)))
                    color = (
                        int(68 + value * 90),
                        int(72 + value * 120),
                        int(102 - value * 42),
                    )
                    text = f"{value:.0%}"
                box = pygame.Rect(x, y, cell - 3, cell - 3)
                pygame.draw.rect(surface, color, box, border_radius=6)
                pygame.draw.rect(surface, (68, 78, 108), box, 1, border_radius=6)
                draw_text_fit(surface, self.font_tiny, text, UI_TEXT_PRIMARY, box.inflate(-6, -8))

    def _draw_before_after_view(self, surface: pygame.Surface, rect: pygame.Rect):
        before_after = self._benchmark_payload().get("before_after") or {}
        if not before_after:
            draw_text_fit(surface, self.font_tiny, "暂无训练前后胜率对比。", UI_TEXT_SECONDARY, rect)
            return
        y = rect.y
        for deck_key, row in list(before_after.items())[:8]:
            before = float((row.get("before") or {}).get("win_rate") or 0.0)
            after = float((row.get("after") or {}).get("win_rate") or 0.0)
            delta = after - before
            draw_text_fit(surface, self.font_tiny, DECK_LABELS.get(deck_key, deck_key),
                          UI_TEXT_PRIMARY, pygame.Rect(rect.x, y, 70, 20))
            bar = pygame.Rect(rect.x + 76, y + 2, rect.w - 166, 16)
            pygame.draw.rect(surface, (28, 34, 48), bar, border_radius=5)
            before_w = int(bar.w * max(0.0, min(1.0, before)))
            after_w = int(bar.w * max(0.0, min(1.0, after)))
            if before_w:
                pygame.draw.rect(surface, (88, 102, 134), pygame.Rect(bar.x, bar.y, before_w, bar.h), border_radius=5)
            if after_w:
                pygame.draw.rect(surface, UI_SUCCESS, pygame.Rect(bar.x, bar.y + 5, after_w, max(4, bar.h - 10)), border_radius=4)
            pygame.draw.rect(surface, (68, 78, 108), bar, 1, border_radius=5)
            color = UI_SUCCESS if delta >= 0 else UI_DANGER
            draw_text_fit(surface, self.font_tiny, f"{before:.0%}->{after:.0%} {delta:+.0%}",
                          color, pygame.Rect(bar.right + 8, y, 82, 20))
            y += 34
            if y > rect.bottom - 24:
                break

    def _draw_ranking_view(self, surface: pygame.Surface, rect: pygame.Rect):
        rankings = list(self._benchmark_payload().get("rankings") or [])
        if not rankings:
            draw_text_fit(surface, self.font_tiny, "暂无卡组 AI 强度排行。", UI_TEXT_SECONDARY, rect)
            return
        y = rect.y
        max_rate = max((float(row.get("point_rate") or 0.0) for row in rankings), default=1.0)
        max_rate = max(0.01, max_rate)
        for row in rankings[:10]:
            deck_key = str(row.get("deck") or "")
            rank = int(row.get("rank") or 0)
            point_rate = float(row.get("point_rate") or 0.0)
            draw_text_fit(surface, self.font_tiny, f"{rank}. {DECK_LABELS.get(deck_key, deck_key)}",
                          UI_TEXT_PRIMARY, pygame.Rect(rect.x, y, 92, 20))
            bar = pygame.Rect(rect.x + 98, y + 3, rect.w - 188, 14)
            pygame.draw.rect(surface, (28, 34, 48), bar, border_radius=5)
            fill = bar.copy()
            fill.w = int(bar.w * point_rate / max_rate)
            if fill.w:
                pygame.draw.rect(surface, UI_HIGHLIGHT, fill, border_radius=5)
            pygame.draw.rect(surface, (68, 78, 108), bar, 1, border_radius=5)
            draw_text_fit(surface, self.font_tiny, f"{point_rate:.0%} {self._stats_text(row)}",
                          UI_TEXT_SECONDARY, pygame.Rect(bar.right + 8, y, 82, 20))
            y += 32
            if y > rect.bottom - 24:
                break

    def _draw_events_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(1046, 350, 512, 560)
        inner = draw_panel(surface, panel, "事件日志", self.font_body)
        y = inner.y
        for event in self.events[-18:]:
            line = self._event_line(event)
            draw_text_fit(surface, self.font_tiny, line, UI_TEXT_SECONDARY,
                          pygame.Rect(inner.x, y, inner.w, 22))
            y += 24

    def _add_button(
        self,
        surface: pygame.Surface,
        rect: pygame.Rect,
        name: str,
        label: str,
        *,
        enabled: bool = True,
        selected: bool = False,
        danger: bool = False,
        attack: bool = False,
    ):
        self._controls.append({"name": name, "rect": rect, "enabled": enabled})
        draw_button(
            surface,
            rect,
            label,
            self.font_small,
            hovered=self._hover_name == name,
            selected=selected,
            enabled=enabled,
            danger=danger,
            attack=attack,
        )

    def _planned_training_games(self) -> int:
        decks = len(DECK_SPECS) if self.selected_deck == "all" else 1
        return max(1, self.games) * decks

    def _progress_ratio(self) -> float:
        total = self.total_training_games or self._planned_training_games()
        return max(0.0, min(1.0, self.total_games_played / max(1, total)))

    def _eta_seconds(self) -> float:
        ratio = self._progress_ratio()
        if self.status != "running" or ratio <= 0:
            return 0.0
        return max(0.0, self.elapsed_seconds * (1.0 / ratio - 1.0))

    def _can_apply(self) -> bool:
        if self.status not in ("completed", "applied"):
            return False
        if not os.path.exists(self._abs_path(self.output_path)):
            return False
        if self._candidate_payload is None:
            self._load_candidate_payload()
        if not isinstance(self._candidate_payload, dict):
            return False
        policies = self._candidate_payload.get("policies")
        return self._candidate_payload.get("version") == 1 and isinstance(policies, dict) and bool(policies)

    def _start_training(self):
        if self.process is not None:
            return
        if not self._reset_training_files():
            return
        self.status = "running"
        self.status_message = "训练进程已启动。"
        self.started_at = time.time()
        self.elapsed_seconds = 0.0
        self.total_training_games = self._planned_training_games()
        self.total_games_played = 0
        self.current_deck = ""
        self.current_stats = {"wins": 0, "losses": 0, "draws": 0}
        self.deck_results.clear()
        self.benchmark_results.clear()
        self.events.clear()
        self._candidate_payload = None
        self._progress_offset = 0

        progress_abs = self._abs_path(self.progress_path)
        progress_dir = os.path.dirname(progress_abs)
        if progress_dir:
            os.makedirs(progress_dir, exist_ok=True)

        script = os.path.join(self.repo_root, "scripts", "train_challenge_ai.py")
        cmd = [
            sys.executable,
            "-B",
            script,
            "--deck",
            self.selected_deck,
            "--games",
            str(max(1, self.games)),
            "--seed",
            str(self.seed),
            "--eval-games",
            str(max(0, self.eval_games)),
            "--output",
            self.output_path,
            "--progress-jsonl",
            self.progress_path,
            "--workers",
            str(max(1, self.workers)),
            "--benchmark-games",
            str(max(0, self.benchmark_games)),
        ]
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            self.process = subprocess.Popen(
                cmd,
                cwd=self.repo_root,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=creationflags,
            )
        except OSError as exc:
            self.process = None
            self.status = "error"
            self.status_message = str(exc)

    def _reset_training_files(self) -> bool:
        for path in (self._abs_path(self.progress_path), self._abs_path(self.output_path)):
            try:
                if os.path.exists(path):
                    os.unlink(path)
            except OSError as exc:
                self.status = "error"
                self.status_message = f"无法清理旧训练文件: {exc}"
                return False
        return True

    def _cancel_training(self):
        if self.process and self.process.poll() is None:
            try:
                self.process.terminate()
                self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1.0)
            except OSError:
                pass
        self.status = "cancelled"
        self.status_message = "训练已取消。"
        self.process = None

    def _apply_candidate_policy(self):
        try:
            src = self._abs_path(self.output_path)
            dst = self._abs_path(self.policy_path)
            dst_dir = os.path.dirname(dst)
            if dst_dir:
                os.makedirs(dst_dir, exist_ok=True)
            shutil.copyfile(src, dst)
        except OSError as exc:
            self.status = "error"
            self.status_message = f"应用失败: {exc}"
            return
        self.status = "applied"
        self.status_message = "候选策略已应用到正式策略文件。"

    def _read_progress_events(self):
        progress_abs = self._abs_path(self.progress_path)
        if not os.path.exists(progress_abs):
            return
        try:
            if os.path.getsize(progress_abs) < self._progress_offset:
                self._progress_offset = 0
            with open(progress_abs, "r", encoding="utf-8") as fh:
                fh.seek(self._progress_offset)
                while True:
                    line = fh.readline()
                    if not line:
                        break
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        self._apply_progress_event(json.loads(line))
                    except json.JSONDecodeError:
                        continue
                self._progress_offset = fh.tell()
        except OSError:
            return

    def _apply_progress_event(self, event: dict[str, Any]):
        self.events.append(event)
        self.events = self.events[-120:]
        etype = event.get("type")
        if etype == "run_started":
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
            self.workers = int(event.get("workers") or self.workers)
            self.benchmark_games = int(event.get("benchmark_games") or self.benchmark_games)
            self.status_message = "正在训练候选策略。"
        elif etype == "deck_started":
            self.current_deck = str(event.get("deck") or "")
            self.current_stats = {"wins": 0, "losses": 0, "draws": 0}
        elif etype == "generation_finished":
            self.current_deck = str(event.get("deck") or self.current_deck)
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
            stats = event.get("stats") or {}
            self.current_stats = {
                "wins": int(stats.get("wins", 0)),
                "losses": int(stats.get("losses", 0)),
                "draws": int(stats.get("draws", 0)),
            }
        elif etype == "deck_finished":
            deck = str(event.get("deck") or "")
            if deck:
                self.deck_results[deck] = {
                    "stats": event.get("stats") or {},
                    "eval": event.get("eval") or {},
                    "training_games": event.get("training_games", 0),
                }
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
        elif etype == "benchmark_started":
            self.status_message = "正在运行基准赛和胜率矩阵..."
            self.benchmark_results = {
                "games_per_matchup": int(event.get("games_per_matchup") or 0),
                "deck_keys": event.get("deck_keys") or [],
                "before_after": {},
                "matrix": {},
                "rankings": [],
            }
        elif etype == "matchup_finished":
            deck_a = str(event.get("deck_a") or "")
            deck_b = str(event.get("deck_b") or "")
            if deck_a and deck_b:
                matrix = self.benchmark_results.setdefault("matrix", {})
                matrix.setdefault(deck_a, {})[deck_b] = event.get("stats_a") or {}
                matrix.setdefault(deck_b, {})[deck_a] = event.get("stats_b") or {}
        elif etype == "benchmark_finished":
            self.benchmark_results = event.get("benchmark") or self.benchmark_results
            self.status_message = "基准赛完成，正在写入候选策略..."
        elif etype == "run_finished":
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.elapsed_seconds = float(event.get("elapsed_seconds") or self.elapsed_seconds)
            self.status = "completed"
            self.status_message = "训练完成，可预览并应用候选策略。"
            self._load_candidate_payload()
        elif etype == "error":
            self.status = "error"
            self.status_message = str(event.get("message") or "训练失败。")

    def _load_candidate_payload(self):
        try:
            with open(self._abs_path(self.output_path), "r", encoding="utf-8") as fh:
                self._candidate_payload = json.load(fh)
            self.benchmark_results = self._candidate_payload.get("benchmark") or self.benchmark_results
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            self._candidate_payload = None

    def _load_policy_payload(self) -> dict[str, Any]:
        try:
            with open(self._abs_path(self.policy_path), "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            return {}

    def _weight_deltas(self) -> list[tuple[str, float, float, float]]:
        if self._candidate_payload is None:
            self._load_candidate_payload()
        candidate = self._candidate_payload or {}
        official = self._load_policy_payload()
        candidate_policies = candidate.get("policies") or {}
        official_policies = official.get("policies") or {}
        if not candidate_policies:
            return []
        deck_key = self.current_deck if self.current_deck in candidate_policies else next(iter(candidate_policies))
        new_weights = ((candidate_policies.get(deck_key) or {}).get("weights") or {})
        old_weights = ((official_policies.get(deck_key) or {}).get("weights") or {})
        rows = []
        for key in TRAINABLE_KEYS:
            new = float(new_weights.get(key, 0.0))
            old = float(old_weights.get(key, 0.0))
            rows.append((key, old, new, new - old))
        rows.sort(key=lambda row: abs(row[3]), reverse=True)
        return rows

    def _event_line(self, event: dict[str, Any]) -> str:
        etype = event.get("type", "")
        deck = event.get("deck", "")
        if etype == "generation_finished":
            return (
                f"{deck} gen {event.get('generation')} "
                f"{event.get('games_played')}/{event.get('target_games')} "
                f"win {event.get('win_rate', 0):.0%}"
            )
        if etype == "deck_finished":
            return f"{deck} 完成 {self._stats_text(event.get('stats') or {})}"
        if etype == "benchmark_started":
            return f"benchmark {event.get('games_per_matchup', 0)} games/matchup"
        if etype == "matchup_finished":
            return f"{event.get('deck_a')} vs {event.get('deck_b')} matrix done"
        if etype == "benchmark_finished":
            return "benchmark finished"
        if etype == "run_finished":
            return f"全部完成，用时 {self._format_seconds(float(event.get('elapsed_seconds') or 0))}"
        if etype == "error":
            return f"错误: {event.get('message', '')}"
        return f"{etype} {deck}".strip()

    @staticmethod
    def _stats_text(stats: dict[str, Any]) -> str:
        return f"{int(stats.get('wins', 0))}/{int(stats.get('losses', 0))}/{int(stats.get('draws', 0))}"

    @staticmethod
    def _format_seconds(value: float) -> str:
        seconds = max(0, int(value))
        minutes, sec = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        if hours:
            return f"{hours}h {minutes:02d}m"
        if minutes:
            return f"{minutes}m {sec:02d}s"
        return f"{sec}s"

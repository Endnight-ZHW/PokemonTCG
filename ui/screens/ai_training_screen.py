"""In-app visual runner for challenge AI policy training."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any

import pygame

from config import SCREEN_HEIGHT, SCREEN_WIDTH
from engine.ai.training import DEFAULT_CANDIDATE_OUTPUT, DEFAULT_WORKERS, DECK_SPECS, TRAINABLE_KEYS
from ui.colors import UI_DANGER, UI_HIGHLIGHT, UI_SUCCESS, UI_TEXT_PRIMARY, UI_TEXT_SECONDARY
from ui.font_manager import get_font
from ui.process_utils import terminate_process_tree
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

        self.training_kind = "rules"
        self.deck_keys = ["all", *DECK_SPECS.keys()]
        self.selected_deck = "all"
        self.games = 300
        self.bootstrap_games = 800
        self.dagger_games = 300
        self.bootstrap_epochs = 10
        self.self_play_epochs = 10
        self.seed = 17
        self.eval_games = 100
        self.workers = DEFAULT_WORKERS
        self.benchmark_games = 2
        self.max_steps = 250
        self.batch_size = 64
        self.rollout_batch_games = 16
        self.updates_per_rollout = 2
        self.teacher_search_preset = "hybrid"
        self.search_preset = "hybrid"
        self.choice_head_enabled = True
        self.acceptance_metric = "wins"
        self.min_win_delta = 1
        self.teacher_label_model_states = True
        self.rl_device = "cuda"
        self.result_view = "matrix"

        self.status = "idle"
        self.status_message = "配置参数后开始训练。"
        self.process: subprocess.Popen | None = None
        self._stderr_file: str | None = None
        self.started_at: float | None = None
        self.elapsed_seconds = 0.0
        self.total_training_games = 0
        self.total_games_played = 0
        self.current_deck = ""
        self.current_stats = {"wins": 0, "losses": 0, "draws": 0}
        self.deck_results: dict[str, dict[str, Any]] = {}
        self.benchmark_results: dict[str, Any] = {}
        self.rl_phase = ""
        self.rl_examples = 0
        self.rl_avg_score = 0.0
        self.rl_history: list[dict[str, Any]] = []
        self.rl_loss_history: list[dict[str, Any]] = []
        self.rl_eval_results: dict[str, Any] = {}
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

    def on_exit(self):
        if self.status == "running":
            self._cancel_training()

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
        if name.startswith("kind:") and self.status != "running":
            self.training_kind = name.split(":", 1)[1]
            self.result_view = "matrix" if self.training_kind == "rules" else "curve"
        elif name.startswith("deck:") and self.status != "running":
            self.selected_deck = name.split(":", 1)[1]
        elif name.startswith("view:"):
            self.result_view = name.split(":", 1)[1]
        elif name == "games_minus" and self.status != "running":
            step = 1 if self.training_kind == "rl" else 20
            self.games = max(0 if self.training_kind == "rl" else 1, self.games - step)
        elif name == "games_plus" and self.status != "running":
            step = 1 if self.training_kind == "rl" else 20
            self.games = min(2000, self.games + step)
        elif name == "bootstrap_minus" and self.status != "running":
            self.bootstrap_games = max(0, self.bootstrap_games - 10)
        elif name == "bootstrap_plus" and self.status != "running":
            self.bootstrap_games = min(1000, self.bootstrap_games + 10)
        elif name == "bootstrap_epochs_minus" and self.status != "running":
            self.bootstrap_epochs = max(1, self.bootstrap_epochs - 1)
        elif name == "bootstrap_epochs_plus" and self.status != "running":
            self.bootstrap_epochs = min(100, self.bootstrap_epochs + 1)
        elif name == "self_play_epochs_minus" and self.status != "running":
            self.self_play_epochs = max(1, self.self_play_epochs - 1)
        elif name == "self_play_epochs_plus" and self.status != "running":
            self.self_play_epochs = min(100, self.self_play_epochs + 1)
        elif name == "seed_minus" and self.status != "running":
            self.seed = max(1, self.seed - 1)
        elif name == "seed_plus" and self.status != "running":
            self.seed += 1
        elif name == "eval_minus" and self.status != "running":
            step = 10 if self.training_kind == "rl" else 1
            self.eval_games = max(0, self.eval_games - step)
        elif name == "eval_plus" and self.status != "running":
            step = 10 if self.training_kind == "rl" else 1
            self.eval_games = min(500 if self.training_kind == "rl" else 50, self.eval_games + step)
        elif name == "steps_minus" and self.status != "running":
            self.max_steps = max(20, self.max_steps - 20)
        elif name == "steps_plus" and self.status != "running":
            self.max_steps = min(400, self.max_steps + 20)
        elif name == "batch_minus" and self.status != "running":
            self.batch_size = max(8, self.batch_size - 8)
        elif name == "batch_plus" and self.status != "running":
            self.batch_size = min(512, self.batch_size + 8)
        elif name == "device:cpu" and self.status != "running":
            self.rl_device = "cpu"
        elif name == "device:cuda" and self.status != "running":
            self.rl_device = "cuda"
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

    def draw(self, surface: pygame.Surface):
        surface.blit(self._bg_surface, (0, 0))
        self._controls.clear()

        title = self.font_title.render("AI 训练", True, UI_HIGHLIGHT)
        surface.blit(title, title.get_rect(center=(SCREEN_WIDTH // 2, 44)))

        self._draw_config_panel(surface)
        self._draw_progress_panel(surface)
        self._draw_results_panel(surface)
        self._draw_events_panel(surface)

    def _draw_stepper(
        self,
        surface: pygame.Surface,
        label: str,
        value: int,
        minus_name: str,
        plus_name: str,
        x: int,
        y: int,
        w: int = 368,
    ):
        draw_text_fit(surface, self.font_small, label, UI_TEXT_SECONDARY, pygame.Rect(x, y, w, 24))
        rect = pygame.Rect(x, y + 30, w, 42)
        pygame.draw.rect(surface, (24, 30, 46), rect, border_radius=8)
        pygame.draw.rect(surface, (64, 74, 104), rect, 1, border_radius=8)
        self._add_button(surface, pygame.Rect(rect.x + 8, rect.y + 6, 44, 30),
                         minus_name, "-", enabled=self.status != "running")
        self._add_button(surface, pygame.Rect(rect.right - 52, rect.y + 6, 44, 30),
                         plus_name, "+", enabled=self.status != "running")
        value_surf = self.font_body.render(str(value), True, UI_TEXT_PRIMARY)
        surface.blit(value_surf, value_surf.get_rect(center=rect.center))

    @staticmethod
    def _stepper_row_height() -> int:
        return 76

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

    def _progress_ratio(self) -> float:
        total = self.total_training_games or self._planned_training_games()
        return max(0.0, min(1.0, self.total_games_played / max(1, total)))

    def _eta_seconds(self) -> float:
        ratio = self._progress_ratio()
        if self.status != "running" or ratio <= 0:
            return 0.0
        return max(0.0, self.elapsed_seconds * (1.0 / ratio - 1.0))

    def _cancel_training(self):
        if self.process is not None:
            terminate_process_tree(self.process, timeout=3.0)
        self.status = "cancelled"
        self.status_message = "训练已取消。"
        self.process = None
        self._cleanup_stderr()

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
                    pos_before = fh.tell()
                    line = fh.readline()
                    if not line:
                        break
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        self._apply_progress_event(json.loads(line))
                    except json.JSONDecodeError:
                        # Partial write — rewind and retry next tick
                        fh.seek(pos_before)
                        break
                self._progress_offset = fh.tell()
        except OSError:
            return

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

    def _read_stderr(self) -> str:
        if not self._stderr_file:
            return ""
        try:
            with open(self._stderr_file, "r", encoding="utf-8", errors="replace") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    def _cleanup_stderr(self):
        if self._stderr_file is not None:
            self._discard_training_file(self._stderr_file)
            self._stderr_file = None

    def _is_rl_mode(self) -> bool:
        return self.training_kind == "rl"

    def _effective_teacher_preset(self) -> str:
        return "hybrid"

    def _rl_candidate_model_path(self, deck_key: str | None = None) -> str:
        deck = deck_key or ("default" if self.selected_deck == "all" else self.selected_deck)
        return os.path.join("data", "ai_models", f"candidate_{deck}.pt")

    def _rl_candidate_model_paths(self) -> list[str]:
        if self.selected_deck == "all":
            return [self._rl_candidate_model_path(k) for k in DECK_SPECS]
        return [self._rl_candidate_model_path(self.selected_deck)]

    def _rl_deck_model_path(self, deck_key: str) -> str:
        return os.path.join("data", "ai_models", f"{deck_key}.pt")

    def _rl_default_model_path(self) -> str:
        deck = "default" if self.selected_deck == "all" else self.selected_deck
        return os.path.join("data", "ai_models", f"{deck}.pt")

    def _rl_model_paths(self) -> list[str]:
        """Return the list of per-deck model paths this training run will produce."""
        if self.selected_deck == "all":
            return [self._rl_deck_model_path(k) for k in DECK_SPECS]
        return [self._rl_deck_model_path(self.selected_deck)]

    def _active_output_path(self) -> str:
        return self._rl_candidate_model_path() if self._is_rl_mode() else self.output_path

    def _active_sidecar_path(self) -> str:
        return os.path.splitext(self._active_output_path())[0] + ".json"

    def update(self, dt: float):
        if self.status != "running" or self.started_at is None:
            return
        self.elapsed_seconds = time.time() - self.started_at
        self._read_progress_events()
        if self.process and self.process.poll() is not None:
            self._read_progress_events()
            if self.process.returncode == 0:
                if self.status == "running":
                    self.status = "completed"
                    if self._is_rl_mode():
                        self.rl_phase = "finished"
                        self.status_message = "训练完成，可预览并应用模型。"
                    else:
                        self.status_message = "训练完成，可预览并应用候选策略。"
                self._load_candidate_payload()
            elif self.status not in ("cancelled", "error"):
                self.status = "error"
                msg = f"Training process exited with code {self.process.returncode}"
                stderr_text = self._read_stderr()
                if stderr_text:
                    msg += f"\n{stderr_text[-500:]}"
                self.status_message = msg
            self.process = None
            self._cleanup_stderr()

    def _draw_config_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(42, 6, 420, 936)
        inner = draw_panel(surface, panel, "训练设置", self.font_body)
        is_rl = self._is_rl_mode()
        ROW = 74
        HW = (inner.w - 16) // 2

        draw_text_fit(surface, self.font_small, "训练类型", UI_TEXT_SECONDARY,
                      pygame.Rect(inner.x, inner.y, inner.w, 22))
        y = inner.y + 28
        self._add_button(surface, pygame.Rect(inner.x, y, 178, 34), "kind:rules", "规则 AI",
                         selected=not is_rl, enabled=self.status != "running")
        self._add_button(surface, pygame.Rect(inner.x + 190, y, 178, 34), "kind:rl", "强化 AI",
                         selected=is_rl, enabled=self.status != "running")

        y += 54
        draw_text_fit(surface, self.font_small, "卡组", UI_TEXT_SECONDARY,
                      pygame.Rect(inner.x, y, inner.w, 22))
        y += 28
        for idx, key in enumerate(self.deck_keys):
            col = idx % 3
            row = idx // 3
            rect = pygame.Rect(inner.x + col * 126, y + row * 38, 116, 32)
            label = "全部" if key == "all" else DECK_LABELS.get(key, key)
            self._add_button(surface, rect, f"deck:{key}", label,
                             selected=self.selected_deck == key,
                             enabled=self.status != "running")

        y += 120
        draw_text_fit(surface, self.font_small, "搜索策略", UI_TEXT_SECONDARY,
                      pygame.Rect(inner.x, y, inner.w, 22))
        y += 28
        draw_text_fit(surface, self.font_small, "自动混合（Beam 裁剪 + Minimax 评估）", UI_TEXT_PRIMARY,
                      pygame.Rect(inner.x, y, inner.w, 26))
        y += 44

        self._draw_stepper(surface, "训练局数", self.games,
                           "games_minus", "games_plus", inner.x, y)
        y += ROW

        if is_rl:
            self._draw_stepper(surface, "引导局数", self.bootstrap_games,
                               "bootstrap_minus", "bootstrap_plus", inner.x, y)
            y += ROW

            self._draw_stepper(surface, "引导 Epochs", self.bootstrap_epochs,
                               "bootstrap_epochs_minus", "bootstrap_epochs_plus",
                               inner.x, y, HW)
            self._draw_stepper(surface, "自对弈 Epochs", self.self_play_epochs,
                               "self_play_epochs_minus", "self_play_epochs_plus",
                               inner.x + HW + 16, y, HW)
            y += ROW

            self._draw_stepper(surface, "评估局数", self.eval_games,
                               "eval_minus", "eval_plus", inner.x, y)
            y += ROW

            self._draw_stepper(surface, "最大步数", self.max_steps,
                               "steps_minus", "steps_plus", inner.x, y, HW)
            self._draw_stepper(surface, "批次大小", self.batch_size,
                               "batch_minus", "batch_plus",
                               inner.x + HW + 16, y, HW)
            y += ROW

            draw_text_fit(surface, self.font_small, "设备", UI_TEXT_SECONDARY,
                          pygame.Rect(inner.x, y, inner.w, 22))
            y += 30
            self._add_button(surface, pygame.Rect(inner.x, y, 178, 34), "device:cuda", "CUDA",
                             selected=self.rl_device == "cuda", enabled=self.status != "running")
            self._add_button(surface, pygame.Rect(inner.x + 190, y, 178, 34), "device:cpu", "CPU",
                             selected=self.rl_device == "cpu", enabled=self.status != "running")
            y += 54
        else:
            self._draw_stepper(surface, "随机种子", self.seed,
                               "seed_minus", "seed_plus", inner.x, y)
            y += ROW
            self._draw_stepper(surface, "评估局数", self.eval_games,
                               "eval_minus", "eval_plus", inner.x, y)
            y += ROW
            self._draw_stepper(surface, "并行进程", self.workers,
                               "workers_minus", "workers_plus", inner.x, y)
            y += ROW
            self._draw_stepper(surface, "基准赛局", self.benchmark_games,
                               "benchmark_minus", "benchmark_plus", inner.x, y)
            y += ROW

        start_rect = pygame.Rect(inner.x, y, 178, 42)
        cancel_rect = pygame.Rect(inner.x + 190, y, 178, 42)
        self._add_button(surface, start_rect, "start", "开始训练",
                         enabled=self.status != "running", attack=True)
        self._add_button(surface, cancel_rect, "cancel", "取消",
                         enabled=self.status == "running", danger=True)

        y += 56
        apply_rect = pygame.Rect(inner.x, y, 178, 42)
        back_rect = pygame.Rect(inner.x + 190, y, 178, 42)
        self._add_button(surface, apply_rect, "apply",
                         "应用模型" if is_rl else "应用候选",
                         enabled=self._can_apply(), selected=self.status == "applied")
        self._add_button(surface, back_rect, "back", "返回",
                         enabled=self.status != "running")

        y += 54
        if is_rl:
            lines = [
                f"卡组: {self.selected_deck}",
                f"模型路径: data/ai_models/{{deck}}.pt",
                "各卡组独立模型，不会写入 data/ai_policies.json。",
            ]
        else:
            lines = [
                f"候选文件: {self.output_path}",
                f"正式策略: {self.policy_path}",
                "训练完成前不会覆盖正式策略。",
            ]
        for line in lines:
            draw_text_fit(surface, self.font_tiny, line, UI_TEXT_SECONDARY,
                          pygame.Rect(inner.x, y, inner.w, 20))
            y += 22

    def _draw_progress_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(500, 90, 1058, 236)
        inner = draw_panel(surface, panel, "Training Progress", self.font_body)

        status_color = {
            "completed": UI_SUCCESS,
            "applied": UI_SUCCESS,
            "error": UI_DANGER,
            "cancelled": UI_DANGER,
            "running": UI_HIGHLIGHT,
        }.get(self.status, UI_TEXT_SECONDARY)
        mode = "强化 AI" if self._is_rl_mode() else "规则 AI"
        status_line = f"{mode} | {self.status.upper()} - {self.status_message}"
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
        total = self.total_training_games or self._planned_training_games()
        label = f"{self.total_games_played}/{total} 局"
        label_surf = self.font_small.render(label, True, UI_TEXT_PRIMARY)
        surface.blit(label_surf, label_surf.get_rect(center=progress_rect.center))

        if self._is_rl_mode():
            stats_value = self._stats_text(self.current_stats)
            win_rate = 0.0
            played = sum(int(self.current_stats.get(k, 0)) for k in ("wins", "losses", "draws"))
            if played:
                win_rate = int(self.current_stats.get("wins", 0)) / played
            metrics = [
                ("阶段", self.rl_phase or "-"),
                ("卡组", self.current_deck or "-"),
                ("胜率", f"{win_rate:.0%} {stats_value}"),
                ("样本数", str(self.rl_examples)),
            ]
        else:
            metrics = [
                ("卡组", self.current_deck or "-"),
                ("已用时间", self._format_seconds(self.elapsed_seconds)),
                ("预计剩余", self._format_seconds(self._eta_seconds())),
                ("胜/负/平", self._stats_text(self.current_stats)),
            ]

        metric_y = inner.y + 102
        for idx, (name, value) in enumerate(metrics):
            box = pygame.Rect(inner.x + idx * 252, metric_y, 236, 64)
            pygame.draw.rect(surface, (24, 30, 46), box, border_radius=8)
            pygame.draw.rect(surface, (54, 66, 96), box, 1, border_radius=8)
            draw_text_fit(surface, self.font_tiny, name, UI_TEXT_SECONDARY,
                          pygame.Rect(box.x + 10, box.y + 8, box.w - 20, 18))
            draw_text_fit(surface, self.font_small, str(value), UI_TEXT_PRIMARY,
                          pygame.Rect(box.x + 10, box.y + 30, box.w - 20, 24))

    def _planned_training_games(self) -> int:
        decks = len(DECK_SPECS) if self.selected_deck == "all" else 1
        if self._is_rl_mode():
            return max(1, (
                max(0, self.games)
                + max(0, self.bootstrap_games)
                + max(0, self.dagger_games)
                + max(0, self.eval_games)
            ) * decks)
        return max(1, self.games) * decks

    def _can_apply(self) -> bool:
        if self.status not in ("completed", "applied"):
            return False
        if self._is_rl_mode():
            for model_path in self._rl_candidate_model_paths():
                path = self._abs_path(model_path)
                if not os.path.exists(path) or os.path.getsize(path) <= 0:
                    return False
            return True
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
        if getattr(sys, "frozen", False):
            self.status = "error"
            self.status_message = "AI 训练仅支持源码环境，打包版不可用。"
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
        self.rl_phase = ""
        self.rl_examples = 0
        self.rl_avg_score = 0.0
        self.rl_history.clear()
        self.rl_loss_history.clear()
        self.rl_eval_results.clear()
        self.events.clear()
        self._candidate_payload = None
        self._progress_offset = 0

        progress_abs = self._abs_path(self.progress_path)
        progress_dir = os.path.dirname(progress_abs)
        if progress_dir:
            os.makedirs(progress_dir, exist_ok=True)

        if self._is_rl_mode():
            output_path = self._rl_candidate_model_path()
            output_abs = self._abs_path(output_path)
            output_dir = os.path.dirname(output_abs)
            if output_dir:
                os.makedirs(output_dir, exist_ok=True)
            script = os.path.join(self.repo_root, "scripts", "train_deep_ai.py")
            cmd = [
                "conda",
                "run",
                "-n",
                "DL",
                "python",
                "-B",
                script,
                "--deck",
                self.selected_deck,
                "--games",
                str(max(0, self.games)),
                "--seed",
                str(self.seed),
                "--eval-games",
                str(max(0, self.eval_games)),
                "--bootstrap-games",
                str(max(0, self.bootstrap_games)),
                "--dagger-games",
                str(max(0, self.dagger_games)),
                "--bootstrap-epochs",
                str(max(1, self.bootstrap_epochs)),
                "--self-play-epochs",
                str(max(1, self.self_play_epochs)),
                "--batch-size",
                str(max(8, self.batch_size)),
                "--rollout-batch-games",
                str(max(1, self.rollout_batch_games)),
                "--updates-per-rollout",
                str(max(1, self.updates_per_rollout)),
                "--teacher-search-preset",
                self._effective_teacher_preset(),
                "--choice-head-enabled" if self.choice_head_enabled else "--no-choice-head-enabled",
                "--acceptance-metric",
                self.acceptance_metric,
                "--min-win-delta",
                str(max(1, self.min_win_delta)),
                "--teacher-label-model-states" if self.teacher_label_model_states else "--no-teacher-label-model-states",
                "--output",
                output_path,
                "--device",
                self.rl_device,
                "--workers",
                str(max(1, self.workers)),
                "--max-steps",
                str(max(20, self.max_steps)),
                "--progress-jsonl",
                self.progress_path,
            ]
        else:
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
                "--search-preset",
                self.search_preset,
            ]

        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        if os.name == "nt":
            creationflags |= getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        data_dir = self._abs_path("data")
        os.makedirs(data_dir, exist_ok=True)
        stderr_fd, stderr_path = tempfile.mkstemp(suffix=".log", prefix="ai_train_", dir=data_dir)
        popen_kwargs: dict[str, Any] = {}
        if os.name != "nt":
            popen_kwargs["preexec_fn"] = os.setsid
        try:
            self.process = subprocess.Popen(
                cmd,
                cwd=self.repo_root,
                stdout=subprocess.DEVNULL,
                stderr=stderr_fd,
                creationflags=creationflags,
                **popen_kwargs,
            )
        except OSError as exc:
            os.close(stderr_fd)
            self._discard_training_file(stderr_path)
            self._stderr_file = None
            self.process = None
            self.status = "error"
            self.status_message = str(exc)
        else:
            os.close(stderr_fd)
            self._stderr_file = stderr_path

    def _discard_training_file(self, path: str) -> bool:
        """Remove a stale training file, or truncate it if removal is blocked."""
        if not os.path.exists(path):
            return True
        try:
            os.unlink(path)
            return True
        except OSError:
            try:
                with open(path, "wb"):
                    pass
                return True
            except OSError:
                return False

    def _reset_training_files(self) -> bool:
        paths = [self._abs_path(self.progress_path)]
        if self._is_rl_mode():
            for candidate_path in self._rl_candidate_model_paths():
                paths.append(self._abs_path(candidate_path))
                paths.append(self._abs_path(os.path.splitext(candidate_path)[0] + ".json"))
                rejected = os.path.splitext(candidate_path)[0] + ".rejected.pt"
                paths.append(self._abs_path(rejected))
                paths.append(self._abs_path(os.path.splitext(rejected)[0] + ".json"))
        else:
            paths.append(self._abs_path(self._active_output_path()))
        for path in paths:
            if not self._discard_training_file(path):
                self.status = "error"
                self.status_message = f"无法清理旧训练文件: {path}"
                return False
        return True

    def _apply_candidate_policy(self):
        if self._is_rl_mode():
            try:
                if self.selected_deck == "all":
                    applied = []
                    for deck_key in DECK_SPECS:
                        src = self._abs_path(self._rl_candidate_model_path(deck_key))
                        dst = self._abs_path(self._rl_deck_model_path(deck_key))
                        dst_dir = os.path.dirname(dst)
                        if dst_dir:
                            os.makedirs(dst_dir, exist_ok=True)
                        shutil.copyfile(src, dst)
                        src_meta = os.path.splitext(src)[0] + ".json"
                        dst_meta = os.path.splitext(dst)[0] + ".json"
                        if os.path.exists(src_meta):
                            shutil.copyfile(src_meta, dst_meta)
                        applied.append(dst)
                else:
                    src = self._abs_path(self._rl_candidate_model_path())
                    dst = self._abs_path(self._rl_default_model_path())
                    dst_dir = os.path.dirname(dst)
                    if dst_dir:
                        os.makedirs(dst_dir, exist_ok=True)
                    shutil.copyfile(src, dst)
                    src_meta = os.path.splitext(src)[0] + ".json"
                    dst_meta = os.path.splitext(dst)[0] + ".json"
                    if os.path.exists(src_meta):
                        shutil.copyfile(src_meta, dst_meta)
                    applied = [dst]
            except OSError as exc:
                self.status = "error"
                self.status_message = f"应用失败: {exc}"
                return
            self.status = "applied"
            paths_text = ", ".join(applied)
            self.status_message = f"RL 模型已应用至 {paths_text}。"
            return

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
        self.status_message = "候选策略已复制到正式策略文件。"

    def _apply_progress_event(self, event: dict[str, Any]):
        self.events.append(event)
        self.events = self.events[-120:]
        etype = event.get("type")
        trainer = str(event.get("trainer") or "")
        if trainer == "rl_ai":
            self.training_kind = "rl"
            if self.result_view not in ("curve", "loss", "eval", "summary"):
                self.result_view = "curve"

        if etype == "run_started":
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
            self.workers = int(event.get("workers") or self.workers)
            if self._is_rl_mode():
                self.rl_phase = "starting"
                self.rl_device = str(event.get("device") or self.rl_device)
                self.max_steps = int(event.get("max_steps") or self.max_steps)
                self.status_message = "正在运行 RL 引导/自我对弈训练。"
            else:
                self.benchmark_games = int(event.get("benchmark_games") or self.benchmark_games)
                self.status_message = "正在训练候选策略。"
        elif etype == "deck_started":
            self.current_deck = str(event.get("deck") or "")
            self.current_stats = {"wins": 0, "losses": 0, "draws": 0}
            if self._is_rl_mode():
                self.rl_phase = "deck"
        elif etype == "bootstrap_finished":
            self.current_deck = str(event.get("deck") or self.current_deck)
            self.rl_phase = "bootstrap"
            self.rl_examples = int(event.get("examples") or self.rl_examples)
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
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
        elif etype in ("self_play_game_finished", "dagger_game_finished"):
            self.current_deck = str(event.get("deck") or self.current_deck)
            self.rl_phase = "dagger" if etype == "dagger_game_finished" else "self-play"
            stats = event.get("stats") or {}
            self.current_stats = {
                "wins": int(stats.get("wins", 0)),
                "losses": int(stats.get("losses", 0)),
                "draws": int(stats.get("draws", 0)),
            }
            self.rl_examples = int(event.get("examples") or self.rl_examples)
            self.rl_avg_score = float(event.get("avg_score") or self.rl_avg_score)
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
            self.rl_history.append(dict(event))
            self.rl_history = self.rl_history[-500:]
        elif etype == "train_phase_finished":
            self.current_deck = str(event.get("deck") or self.current_deck)
            self.rl_phase = str(event.get("phase") or "train")
            self.rl_examples = int(event.get("examples") or self.rl_examples)
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
            self.rl_loss_history.append(dict(event))
            self.rl_loss_history = self.rl_loss_history[-500:]
        elif etype == "eval_finished":
            self.current_deck = str(event.get("deck") or self.current_deck)
            self.rl_phase = "eval"
            deck = self.current_deck or str(event.get("deck") or "")
            if deck:
                self.rl_eval_results[deck] = event.get("eval") or {}
                self.rl_eval_results[deck]["win_rate"] = float(event.get("win_rate") or 0.0)
                self.rl_eval_results[deck]["baseline_eval"] = event.get("baseline_eval")
                self.rl_eval_results[deck]["accepted"] = bool(event.get("accepted", True))
                self.rl_eval_results[deck]["delta_wins"] = event.get("delta_wins")
                self.rl_eval_results[deck]["delta_point_rate"] = event.get("delta_point_rate")
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
        elif etype == "deck_finished":
            deck = str(event.get("deck") or "")
            if deck:
                self.deck_results[deck] = {
                    "stats": event.get("stats") or {},
                    "eval": event.get("eval") or {},
                    "baseline_eval": event.get("baseline_eval"),
                    "accepted": bool(event.get("accepted", True)),
                    "delta_wins": event.get("delta_wins"),
                    "delta_point_rate": event.get("delta_point_rate"),
                    "training_games": event.get("training_games", 0),
                }
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
        elif etype == "benchmark_started":
            self.status_message = "正在运行基准测试。"
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
            self.status_message = "基准测试完成；正在写入候选策略。"
        elif etype == "run_finished":
            self.total_games_played = int(event.get("total_games_played") or self.total_games_played)
            self.total_training_games = int(event.get("total_training_games") or self.total_training_games)
            self.elapsed_seconds = float(event.get("elapsed_seconds") or self.elapsed_seconds)
            self.status = "completed"
            self.status_message = "训练完成，可预览并应用候选。"
            if self._is_rl_mode():
                self.rl_phase = "finished"
            self._load_candidate_payload()
        elif etype == "error":
            self.status = "error"
            self.status_message = str(event.get("message") or "训练失败。")

    def _load_candidate_payload(self):
        try:
            if self._is_rl_mode() and self.selected_deck == "all":
                # Per-deck models: load summary from first available sidecar.
                for deck_key in DECK_SPECS:
                    sidecar = os.path.splitext(self._rl_candidate_model_path(deck_key))[0] + ".json"
                    spath = self._abs_path(sidecar)
                    if os.path.exists(spath):
                        with open(spath, "r", encoding="utf-8") as fh:
                            self._candidate_payload = json.load(fh)
                        metadata = (self._candidate_payload or {}).get("metadata") or {}
                        summary = metadata.get("summary") or {}
                        for deck, row in summary.items():
                            eval_data = dict(row.get("eval") or {})
                            games = int(eval_data.get("games") or 0)
                            wins = int(eval_data.get("wins") or 0)
                            eval_data["win_rate"] = wins / max(1, games) if games else 0.0
                            self.rl_eval_results.setdefault(deck, eval_data)
                        return
                self._candidate_payload = None
                return

            path = self._active_sidecar_path() if self._is_rl_mode() else self.output_path
            with open(self._abs_path(path), "r", encoding="utf-8") as fh:
                self._candidate_payload = json.load(fh)
            if self._is_rl_mode():
                metadata = (self._candidate_payload or {}).get("metadata") or {}
                summary = metadata.get("summary") or {}
                for deck, row in summary.items():
                    eval_data = dict(row.get("eval") or {})
                    games = int(eval_data.get("games") or 0)
                    wins = int(eval_data.get("wins") or 0)
                    eval_data["win_rate"] = wins / max(1, games) if games else 0.0
                    self.rl_eval_results.setdefault(deck, eval_data)
            else:
                self.benchmark_results = self._candidate_payload.get("benchmark") or self.benchmark_results
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            self._candidate_payload = None

    def _draw_results_panel(self, surface: pygame.Surface):
        if self._is_rl_mode():
            self._draw_rl_results_panel(surface)
            return

        panel = pygame.Rect(500, 350, 512, 560)
        inner = draw_panel(surface, panel, "规则 AI 结果", self.font_body)

        if not self.deck_results and not self._candidate_payload:
            lines = ["Waiting for training events.", "After completion this panel shows matrix, rankings, and weights."]
            y = inner.y + 4
            for line in lines:
                draw_text_fit(surface, self.font_small, line, UI_TEXT_SECONDARY,
                              pygame.Rect(inner.x, y, inner.w, 24))
                y += 28
            return

        tabs = [
            ("matrix", "矩阵"),
            ("before", "前后对比"),
            ("ranking", "排名"),
            ("weights", "权重"),
        ]
        if self.result_view not in {key for key, _ in tabs}:
            self.result_view = "matrix"
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

    def _draw_rl_results_panel(self, surface: pygame.Surface):
        panel = pygame.Rect(500, 350, 512, 560)
        inner = draw_panel(surface, panel, "强化 AI 结果", self.font_body)
        tabs = [
            ("curve", "胜率"),
            ("loss", "损失"),
            ("eval", "评估"),
            ("summary", "摘要"),
        ]
        if self.result_view not in {key for key, _ in tabs}:
            self.result_view = "curve"
        tab_w = max(72, (inner.w - 12) // len(tabs))
        for idx, (key, label) in enumerate(tabs):
            rect = pygame.Rect(inner.x + idx * (tab_w + 4), inner.y, tab_w, 30)
            self._add_button(surface, rect, f"view:{key}", label, selected=self.result_view == key)

        content = pygame.Rect(inner.x, inner.y + 44, inner.w, inner.h - 44)
        if self.result_view == "curve":
            self._draw_line_chart(
                surface,
                content,
                [float(row.get("win_rate") or 0.0) for row in self.rl_history],
                1.0,
                "Rolling self-play win rate",
            )
        elif self.result_view == "loss":
            losses = [float(row.get("total_loss", row.get("loss", 0.0)) or 0.0) for row in self.rl_loss_history]
            max_loss = max(losses, default=1.0)
            self._draw_line_chart(surface, content, losses, max(0.01, max_loss), "Training loss")
        elif self.result_view == "eval":
            self._draw_rl_eval_view(surface, content)
        else:
            self._draw_rl_summary_view(surface, content)

    def _draw_line_chart(self, surface: pygame.Surface, rect: pygame.Rect, values: list[float], max_value: float, title: str):
        draw_text_fit(surface, self.font_small, title, UI_TEXT_PRIMARY,
                      pygame.Rect(rect.x, rect.y, rect.w, 24))
        chart = pygame.Rect(rect.x, rect.y + 34, rect.w, rect.h - 70)
        pygame.draw.rect(surface, (24, 30, 46), chart, border_radius=8)
        pygame.draw.rect(surface, (64, 74, 104), chart, 1, border_radius=8)
        for i in range(1, 4):
            y = chart.y + int(chart.h * i / 4)
            pygame.draw.line(surface, (38, 46, 64), (chart.x + 8, y), (chart.right - 8, y), 1)
        if not values:
            draw_text_fit(surface, self.font_small, "Waiting for RL progress events.",
                          UI_TEXT_SECONDARY, chart.inflate(-24, -24))
            return
        max_value = max(0.0001, max_value)
        points = []
        for idx, value in enumerate(values):
            x = chart.x + 14 if len(values) == 1 else chart.x + 14 + int((chart.w - 28) * idx / (len(values) - 1))
            normalized = max(0.0, min(1.0, value / max_value))
            y = chart.bottom - 14 - int((chart.h - 28) * normalized)
            points.append((x, y))
        if len(points) >= 2:
            pygame.draw.lines(surface, UI_HIGHLIGHT, False, points, 3)
        for point in points[-20:]:
            pygame.draw.circle(surface, UI_SUCCESS, point, 4)
        last = values[-1]
        draw_text_fit(surface, self.font_tiny, f"latest {last:.4f} | samples {len(values)}",
                      UI_TEXT_SECONDARY, pygame.Rect(rect.x, chart.bottom + 10, rect.w, 22))

    def _draw_rl_eval_view(self, surface: pygame.Surface, rect: pygame.Rect):
        if not self.rl_eval_results:
            self._load_candidate_payload()
        if not self.rl_eval_results:
            draw_text_fit(surface, self.font_small, "Waiting for eval results.",
                          UI_TEXT_SECONDARY, rect)
            return
        y = rect.y
        for deck, result in list(self.rl_eval_results.items())[:10]:
            games = int(result.get("games") or 0)
            wins = int(result.get("wins") or 0)
            losses = int(result.get("losses") or 0)
            draws = int(result.get("draws") or 0)
            win_rate = float(result.get("win_rate") or (wins / max(1, games) if games else 0.0))
            draw_text_fit(surface, self.font_tiny, f"{deck.title()} eval {wins}/{losses}/{draws}",
                          UI_TEXT_PRIMARY, pygame.Rect(rect.x, y, 150, 22))
            bar = pygame.Rect(rect.x + 156, y + 4, rect.w - 250, 14)
            pygame.draw.rect(surface, (28, 34, 48), bar, border_radius=5)
            fill = bar.copy()
            fill.w = int(bar.w * max(0.0, min(1.0, win_rate)))
            if fill.w:
                pygame.draw.rect(surface, UI_SUCCESS, fill, border_radius=5)
            pygame.draw.rect(surface, (68, 78, 108), bar, 1, border_radius=5)
            draw_text_fit(surface, self.font_tiny, f"{win_rate:.0%}",
                          UI_TEXT_SECONDARY, pygame.Rect(bar.right + 8, y, 82, 22))
            y += 34
            if y > rect.bottom - 24:
                break

    def _draw_rl_summary_view(self, surface: pygame.Surface, rect: pygame.Rect):
        lines = [
            f"Phase: {self.rl_phase or '-'}",
            f"Deck: {self.current_deck or self.selected_deck}",
            f"Self-play: {self._stats_text(self.current_stats)}",
            f"Examples: {self.rl_examples}",
            f"Average score: {self.rl_avg_score:.2f}",
            f"Candidate: {self._rl_candidate_model_path()}",
            f"Default target: {self._rl_default_model_path()}",
        ]
        payload = self._candidate_payload or {}
        metadata = payload.get("metadata") or {}
        if metadata:
            lines.append(f"Trainer: {metadata.get('trainer', '-')}")
        eval_result = self.rl_eval_results.get(self.current_deck or self.selected_deck) or {}
        if eval_result:
            baseline = eval_result.get("baseline_eval") or {}
            if baseline:
                lines.append(
                    f"Baseline/Candidate wins: {baseline.get('wins', 0)} -> {eval_result.get('wins', 0)}"
                )
            if eval_result.get("delta_wins") is not None:
                lines.append(
                    f"Delta wins: {eval_result.get('delta_wins')} | accepted: {bool(eval_result.get('accepted', True))}"
                )
        y = rect.y
        for line in lines:
            draw_text_fit(surface, self.font_small, line, UI_TEXT_SECONDARY,
                          pygame.Rect(rect.x, y, rect.w, 24))
            y += 30

    def _event_line(self, event: dict[str, Any]) -> str:
        etype = event.get("type", "")
        deck = event.get("deck", "")
        if etype == "bootstrap_finished":
            return f"{deck} bootstrap {event.get('games_played', 0)} games, {event.get('examples', 0)} examples"
        if etype in ("self_play_game_finished", "dagger_game_finished"):
            stats = self._stats_text(event.get("stats") or {})
            label = "dagger" if etype == "dagger_game_finished" else "self-play"
            return (
                f"{deck} {label} {event.get('game')}/{event.get('target_games')} "
                f"win {float(event.get('win_rate') or 0.0):.0%} {stats}"
            )
        if etype == "train_phase_finished":
            loss = event.get("total_loss", event.get("loss", 0.0))
            return f"{deck} {event.get('phase', 'train')} loss {float(loss or 0.0):.4f} ex {event.get('examples', 0)}"
        if etype == "eval_finished":
            delta = event.get("delta_wins")
            accepted = bool(event.get("accepted", True))
            suffix = f" delta wins {delta} accepted {accepted}" if delta is not None else ""
            return f"{deck} eval win {float(event.get('win_rate') or 0.0):.0%}{suffix}"
        if etype == "generation_finished":
            return (
                f"{deck} gen {event.get('generation')} "
                f"{event.get('games_played')}/{event.get('target_games')} "
                f"win {float(event.get('win_rate') or 0.0):.0%}"
            )
        if etype == "deck_finished":
            return f"{deck} finished {self._stats_text(event.get('stats') or {})}"
        if etype == "benchmark_started":
            return f"benchmark {event.get('games_per_matchup', 0)} games/matchup"
        if etype == "matchup_finished":
            return f"{event.get('deck_a')} vs {event.get('deck_b')} matrix done"
        if etype == "benchmark_finished":
            return "benchmark finished"
        if etype == "run_finished":
            return f"run finished in {self._format_seconds(float(event.get('elapsed_seconds') or 0))}"
        if etype == "error":
            return f"error: {event.get('message', '')}"
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

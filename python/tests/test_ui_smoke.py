"""UI smoke tests for the Pygame screens.

Run with:
    python -B tests/test_ui_smoke.py
"""
import os
import json
import sys
import time
import unittest
from unittest.mock import patch

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pygame

from config import SCREEN_WIDTH, SCREEN_HEIGHT
from data.card_models import AttackDef, Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK, expand_deck
from engine.actions import ChoiceResponse, GameAction
from engine.ai import AIAction, AIConfig, ChallengeAI
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import ActionRequest, GameState
from engine.player_state import PokemonInPlay
from engine.random_source import RandomSource
from engine.rules_validator import (
    can_declare_attack,
    can_evolve,
    can_play_supporter,
)
from engine.turn_manager import TurnManager
from ui.screen_manager import ScreenManager
from ui.components import board_renderer, hand_display
from ui.components.game_layout import SLOT_OPP_ACTIVE, SLOT_PLAYER_ACTIVE
from ui.screens.deck_select import DeckSelectScreen
from ui.screens.end_screen import EndScreen
from ui.screens.attached_cards_screen import AttachedCardsScreen
from ui.screens.ai_training_screen import AITrainingScreen
from ui.screens.card_image_screen import CardImageScreen, PendingImage
from ui.screens.card_image_screen import (
    CANDIDATE_ROW_H, LEFT_W, LEFT_X, RIGHT_W, RIGHT_X, ROW_H, WORK_H, WORK_TOP,
)
from ui.screens.energy_distribution_screen import EnergyDistributionScreen
from ui.screens.game_screen import GameScreen
from ui.screens.help_screen import HelpScreen
from ui.screens.pass_screen import PassScreen
from ui.screens.search_screen import SearchScreen
from ui.screens.title_screen import TitleScreen
from ui.coin_flip import CoinFlipAnimation
from ui.energy_icons import get_energy_icon_surface
from tests.temp_utils import supports_file_delete, temp_dir


class UiSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pygame.init()
        pygame.display.set_mode((1, 1))
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)
        cls.available_decks = {
            "fire": FIRE_DECK,
            "water": WATER_DECK,
        }
        cls.surface = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT)).convert()

    @classmethod
    def tearDownClass(cls):
        pygame.quit()

    def _manager(self):
        return ScreenManager()

    def _begin_official_setup(self, *, first_player_idx=0):
        """Enter INITIAL_PLACEMENT through the public setup contract."""
        state = GameState()
        rng = RandomSource(20260716)
        step = DEFAULT_GAME_ENGINE.begin_game(
            state,
            expand_deck(FIRE_DECK),
            expand_deck(WATER_DECK),
            rng,
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        winner = state.opening_coin_winner_idx
        order = "first" if winner == first_player_idx else "second"
        response = ChoiceResponse(
            step.pending_choice.request_id,
            (f"turn_order:{order}",),
        )
        step = DEFAULT_GAME_ENGINE.apply_choice(
            state,
            step.pending_choice,
            response,
            rng,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.setup_stage, "INITIAL_PLACEMENT")
        self.assertEqual(state.setup_actor_idx, first_player_idx)
        return state, TurnManager(state), rng

    def _game(self):
        """Build a playable game using the official serialized setup flow."""
        state, tm, rng = self._begin_official_setup(first_player_idx=0)
        guard = 0
        while state.phase == TurnPhase.SETUP and guard < 16:
            guard += 1
            if state.setup_stage == "INITIAL_PLACEMENT":
                actor = state.setup_actor_idx
                actions = DEFAULT_GAME_ENGINE.legal_actions(state, actor)
                place = next(
                    action for action in actions
                    if action.action == PlayerAction.PLAY_BASIC
                    and action.params.get("target") == "active"
                )
                step = DEFAULT_GAME_ENGINE.apply_action(state, place, rng)
                self.assertTrue(step.success, step.message)
                step = DEFAULT_GAME_ENGINE.apply_action(
                    state,
                    GameAction("SETUP_DONE", {}, terminal=True, actor=actor),
                    rng,
                )
                self.assertTrue(step.success, step.message)
                continue
            if state.setup_stage == "BONUS_DRAW":
                request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
                self.assertIsNotNone(request)
                # UI fixtures keep their board shape stable by declining the
                # optional mulligan bonus. The real client exposes 0..N.
                step = DEFAULT_GAME_ENGINE.apply_choice(
                    state,
                    request,
                    ChoiceResponse(request.request_id, ("mulligan_draw:0",)),
                    rng,
                )
                self.assertTrue(step.success, step.message)
                continue
            if state.setup_stage == "BONUS_PLACEMENT":
                actor = state.setup_actor_idx
                step = DEFAULT_GAME_ENGINE.apply_action(
                    state,
                    GameAction("SETUP_DONE", {}, terminal=True, actor=actor),
                    rng,
                )
                self.assertTrue(step.success, step.message)
                continue
            self.fail(f"unexpected setup stage: {state.setup_stage}")
        self.assertLess(guard, 16)
        self.assertEqual(state.setup_stage, "COMPLETE")
        self.assertEqual(state.phase, TurnPhase.MAIN)
        return state, TurnManager(state)

    def _setup_game(self):
        state, tm, _rng = self._begin_official_setup(first_player_idx=0)
        return state, tm

    def _finish_fly_immediately(self, *args, **kwargs):
        callback = kwargs.get("on_complete")
        if callback:
            callback()

    def _pump_until(self, screen, predicate, frames=80, dt=0.2):
        for _ in range(frames):
            screen.update(dt)
            if predicate():
                return
            if getattr(screen, "_ai_action_future", None) is not None:
                time.sleep(0.005)
        self.fail("condition was not reached while pumping screen updates")

    def _phase_button(self, screen, action):
        return next(item for item in screen.action_buttons
                    if item["action"] == action)

    def _attach_public_cards(self, pokemon):
        pokemon.evolution_stack.append(CardRegistry.get("sv2-38"))
        pokemon.energy_cards.extend([
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("svi-jete"),
        ])
        pokemon.attached_tool = CardRegistry.get("svl-vitb")

    def test_screens_draw_one_frame(self):
        state, tm = self._game()
        cards = list(state.get_active_player().hand[:6])
        target = state.get_active_player().active

        screens = [
            TitleScreen(self._manager()),
            AITrainingScreen(self._manager()),
            DeckSelectScreen(self._manager(), self.available_decks),
            DeckSelectScreen(self._manager(), self.available_decks, mode="challenge"),
            GameScreen(self._manager(), state, tm),
            SearchScreen(
                self._manager(),
                ActionRequest("search_deck", 0, "测试搜索", min_select=0, max_select=0,
                              card_list=cards),
                lambda selected: None,
            ),
            AttachedCardsScreen(
                self._manager(),
                "测试附属卡",
                target.card.name,
                [
                    ("退化卡", [CardRegistry.get("sv2-38")]),
                    ("能量卡", [CardRegistry.get("sv1-ener-2")]),
                    ("道具卡", [CardRegistry.get("svl-vitb")]),
                ],
            ),
            EnergyDistributionScreen(
                self._manager(),
                {
                    "energy_cards": [c for c in cards if c.is_energy],
                    "targets": [{"slot": "active", "name": target.card.name, "bench_idx": -1}],
                    "source_name": target.card.name,
                },
                lambda assignments: None,
            ),
            HelpScreen(self._manager()),
            PassScreen(self._manager(), 1, lambda: None, state, state.turn_number),
            EndScreen(self._manager(), 0, "测试胜利", (1, 0)),
            EndScreen(
                self._manager(), -1, "双方同时满足胜利条件", (6, 6),
                result_status="DRAW",
            ),
        ]

        for screen in screens:
            with self.subTest(screen=screen.__class__.__name__):
                screen.update(1 / 60)
                screen.draw(self.surface)

    def test_card_image_manager_workbench_filters_searches_and_draws(self):
        screen = CardImageScreen(self._manager())
        screen.filter_type = "missing"
        screen._apply_filter_and_sort()
        screen.draw(self.surface)

        screen.search_query = "sv2-tatsu"
        screen.filter_type = "all"
        screen._apply_filter_and_sort()

        self.assertEqual(len(screen.display_cards), 1)
        self.assertEqual(screen.display_cards[0].card_id, "sv2-tatsu")

        screen.filter_type = "duplicates"
        screen.search_query = ""
        screen._apply_filter_and_sort()
        duplicate_ids = {entry.card_id for entry in screen.display_cards}

        self.assertIn("svg-tatsu", duplicate_ids)
        self.assertIn("sv2-tatsu", duplicate_ids)
        screen.draw(self.surface)

    def test_card_image_manager_search_accepts_text_input_and_clipboard_paste(self):
        screen = CardImageScreen(self._manager())
        screen.filter_type = "all"
        screen._apply_filter_and_sort()
        screen._activate_search_input()

        screen.handle_event(pygame.event.Event(pygame.TEXTEDITING, {"text": "皮", "start": 0, "length": 1}))
        self.assertEqual(screen._composition_text, "皮")
        screen.handle_event(pygame.event.Event(pygame.TEXTINPUT, {"text": "皮卡丘"}))
        self.assertEqual(screen._composition_text, "")
        self.assertEqual(screen.search_query, "皮卡丘")
        screen.search_query = ""

        screen.manager._app = type("FakeApp", (), {
            "_lb_scale": 0.5,
            "_lb_ox": 10,
            "_lb_oy": 20,
        })()
        self.assertEqual(
            screen._window_rect(pygame.Rect(100, 50, 20, 10)),
            pygame.Rect(60, 45, 10, 5),
        )

        screen.handle_event(pygame.event.Event(
            pygame.KEYDOWN,
            {"key": pygame.K_s, "unicode": "s", "mod": 0},
        ))
        screen.handle_event(pygame.event.Event(pygame.TEXTINPUT, {"text": "s"}))
        self.assertEqual(screen.search_query, "s")
        screen.search_query = ""

        screen.handle_event(pygame.event.Event(pygame.TEXTINPUT, {"text": "sv2-"}))
        with patch("ui.screens.card_image_screen._get_clipboard_text", return_value="tatsu\n"):
            with patch.object(screen, "_paste_from_clipboard") as paste_image:
                screen.handle_event(pygame.event.Event(
                    pygame.KEYDOWN,
                    {"key": pygame.K_v, "mod": pygame.KMOD_CTRL},
                ))

        self.assertEqual(screen.search_query, "sv2-tatsu")
        self.assertEqual(len(screen.display_cards), 1)
        self.assertEqual(screen.display_cards[0].card_id, "sv2-tatsu")
        paste_image.assert_not_called()

    def test_card_image_manager_draws_pending_image_preview(self):
        screen = CardImageScreen(self._manager())
        with temp_dir() as tmp:
            image_path = os.path.join(tmp, "pending.png")
            image = pygame.Surface((24, 36), pygame.SRCALPHA)
            image.fill((220, 40, 80, 255))
            pygame.image.save(image, image_path)

            screen.pending_image = PendingImage(image_path, "pending.png", "剪贴板", is_temp=True)
            screen.image_candidates = []
            screen.draw(self.surface)

            self.assertEqual(screen._preview_cache_key, image_path)
            self.assertIsNotNone(screen._preview_cache_surface)

    def test_card_image_manager_godot_sync_button_runs_export(self):
        screen = CardImageScreen(self._manager())
        self.assertIn("sync_godot", screen._button_rects())

        with patch.object(screen, "_run_godot_sync_command", return_value=(True, "export ok")) as run_sync:
            screen._start_godot_sync()
            self._pump_until(screen, lambda: not screen._sync_active, frames=20, dt=0.05)

        run_sync.assert_called_once()
        self.assertIn("Godot同步完成", screen._toast_text)

    def test_card_image_manager_treats_card_back_as_missing(self):
        real = Card(api_id="test-real-image", name="真实卡图", supertype="Pokémon",
                    subtypes=["Basic"], energy_types=["Fire"])
        placeholder = Card(api_id="test-card-back", name="卡背占位", supertype="Pokémon",
                           subtypes=["Basic"], energy_types=["Water"])
        missing = Card(api_id="test-no-image", name="无卡图", supertype="Trainer",
                       subtypes=["Item"], trainer_type="Item")
        cards = {
            real.api_id: real,
            placeholder.api_id: placeholder,
            missing.api_id: missing,
        }

        class FakeImageManager:
            def has_card_image(self, card):
                return card.api_id in {real.api_id, placeholder.api_id}

            def has_real_card_image(self, card):
                return card.api_id == real.api_id

            def card_uses_card_back(self, card):
                return card.api_id == placeholder.api_id

            def get_unreferenced_images(self):
                return []

            def get_available_images(self):
                return []

        with patch("ui.screens.card_image_screen.get_image_manager", return_value=FakeImageManager()), \
                patch.object(CardRegistry, "all_cards", return_value=cards):
            screen = CardImageScreen(self._manager())

        missing_ids = {entry.card_id for entry in screen.display_cards}
        self.assertEqual(missing_ids, {placeholder.api_id, missing.api_id})

        screen.filter_type = "mapped"
        screen._apply_filter_and_sort()
        mapped_ids = {entry.card_id for entry in screen.display_cards}
        self.assertEqual(mapped_ids, {real.api_id})

    def test_card_image_manager_mouse_hit_targets_match_visible_rows(self):
        screen = CardImageScreen(self._manager())
        screen.filter_type = "all"
        screen.search_query = ""
        screen._apply_filter_and_sort()

        card_inner = pygame.Rect(LEFT_X, WORK_TOP, LEFT_W, WORK_H).inflate(-18, -56)
        card_inner.y += 34
        first_card_pos = (card_inner.x + 20, card_inner.y + ROW_H // 2)

        screen._hover(first_card_pos)
        self.assertEqual(screen.hovered_card_idx, 0)

        from ui.image_manager import ImageCandidate
        screen.image_candidates = [
            ImageCandidate("候选A", "a.png", "a.png", "宝可梦"),
            ImageCandidate("候选B", "b.png", "b.png", "宝可梦"),
        ]
        candidate_inner = pygame.Rect(RIGHT_X, WORK_TOP, RIGHT_W, WORK_H).inflate(-18, -56)
        candidate_inner.y += 34
        first_candidate_pos = (
            candidate_inner.x + 20,
            candidate_inner.y + CANDIDATE_ROW_H // 2,
        )

        screen._hover(first_candidate_pos)
        self.assertEqual(screen.hovered_candidate_idx, 0)

    def test_ai_training_screen_progress_states_draw(self):
        with temp_dir() as tmpdir:
            candidate = os.path.join(tmpdir, "candidate.json")
            policy = os.path.join(tmpdir, "policy.json")
            progress = os.path.join(tmpdir, "progress.jsonl")
            old_payload = {
                "version": 1,
                "policies": {
                    "fire": {
                        "weights": {
                            "core_in_play": 70.0,
                            "damaged_self": -0.18,
                            "ko_pressure": 0.9,
                        }
                    }
                },
            }
            new_payload = {
                "version": 1,
                "policies": {
                    "fire": {
                        "stats": {"wins": 2, "losses": 1, "draws": 0},
                        "eval": {
                            "games": 2,
                            "trained": {"wins": 1, "losses": 1, "draws": 0},
                            "baseline": {"wins": 0, "losses": 2, "draws": 0},
                        },
                        "weights": {
                            "core_in_play": 86.0,
                            "damaged_self": -0.42,
                            "ko_pressure": 1.6,
                        },
                    }
                },
                "benchmark": {
                    "games_per_matchup": 2,
                    "deck_keys": ["fire", "water"],
                    "before_after": {
                        "fire": {
                            "before": {"wins": 0, "losses": 2, "draws": 0, "win_rate": 0.0},
                            "after": {"wins": 1, "losses": 1, "draws": 0, "win_rate": 0.5},
                            "delta_win_rate": 0.5,
                        }
                    },
                    "matrix": {
                        "fire": {"water": {"wins": 1, "losses": 1, "draws": 0, "win_rate": 0.5}},
                        "water": {"fire": {"wins": 1, "losses": 1, "draws": 0, "win_rate": 0.5}},
                    },
                    "rankings": [
                        {"rank": 1, "deck": "fire", "wins": 1, "losses": 1, "draws": 0, "point_rate": 0.5},
                        {"rank": 2, "deck": "water", "wins": 1, "losses": 1, "draws": 0, "point_rate": 0.5},
                    ],
                },
            }
            with open(policy, "w", encoding="utf-8") as fh:
                json.dump(old_payload, fh)
            with open(candidate, "w", encoding="utf-8") as fh:
                json.dump(new_payload, fh)

            screen = AITrainingScreen(
                self._manager(),
                output_path=candidate,
                policy_path=policy,
                progress_path=progress,
            )
            screen._apply_progress_event({
                "type": "run_started",
                "total_training_games": 3,
                "games_per_deck": 3,
            })
            screen.status = "running"
            screen._apply_progress_event({
                "type": "deck_started",
                "deck": "fire",
                "target_games": 3,
            })
            screen._apply_progress_event({
                "type": "generation_finished",
                "deck": "fire",
                "generation": 1,
                "games_played": 3,
                "target_games": 3,
                "total_games_played": 3,
                "total_training_games": 3,
                "stats": {"wins": 2, "losses": 1, "draws": 0},
                "win_rate": 2 / 3,
            })
            screen._apply_progress_event({
                "type": "benchmark_started",
                "deck_keys": ["fire", "water"],
                "games_per_matchup": 2,
            })
            screen._apply_progress_event({
                "type": "matchup_finished",
                "deck_a": "fire",
                "deck_b": "water",
                "stats_a": {"wins": 1, "losses": 1, "draws": 0, "win_rate": 0.5},
                "stats_b": {"wins": 1, "losses": 1, "draws": 0, "win_rate": 0.5},
            })
            screen.draw(self.surface)

            screen._apply_progress_event({
                "type": "benchmark_finished",
                "benchmark": new_payload["benchmark"],
            })
            for view in ("matrix", "before", "ranking", "weights"):
                screen.result_view = view
                screen.draw(self.surface)

            screen._apply_progress_event({
                "type": "run_finished",
                "output": candidate,
                "policy_count": 1,
                "total_games_played": 3,
                "total_training_games": 3,
                "elapsed_seconds": 4.0,
            })
            screen.draw(self.surface)
            self.assertTrue(screen._can_apply())
            self.assertEqual(screen.status, "completed")

    def test_ai_training_screen_clears_stale_run_files_and_validates_apply(self):
        if not supports_file_delete():
            self.skipTest("Current sandbox does not allow deleting test files")

        class FakeProcess:
            def poll(self):
                return None

        with temp_dir() as tmpdir:
            candidate = os.path.join(tmpdir, "candidate.json")
            progress = os.path.join(tmpdir, "progress.jsonl")
            with open(candidate, "w", encoding="utf-8") as fh:
                json.dump({"version": 1, "policies": {"fire": {"weights": {}}}}, fh)
            with open(progress, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({
                    "type": "generation_finished",
                    "total_games_played": 99,
                    "total_training_games": 99,
                }) + "\n")

            screen = AITrainingScreen(
                self._manager(),
                output_path=candidate,
                policy_path=os.path.join(tmpdir, "policy.json"),
                progress_path=progress,
            )
            with patch("ui.screens.ai_training_screen.subprocess.Popen",
                       return_value=FakeProcess()) as popen_mock:
                screen._start_training()

            self.assertEqual(screen.status, "running")
            cmd = popen_mock.call_args.args[0]
            self.assertIn("--workers", cmd)
            self.assertIn(str(screen.workers), cmd)
            self.assertIn("--benchmark-games", cmd)
            self.assertIn(str(screen.benchmark_games), cmd)
            self.assertFalse(os.path.exists(candidate))
            self.assertFalse(os.path.exists(progress))
            screen._read_progress_events()
            self.assertEqual(screen.total_games_played, 0)

            with open(candidate, "w", encoding="utf-8") as fh:
                fh.write("{bad json")
            screen.status = "completed"
            screen._candidate_payload = None
            self.assertFalse(screen._can_apply())

    def test_ai_training_screen_rl_mode_command_progress_and_apply(self):
        if not supports_file_delete():
            self.skipTest("Current sandbox does not allow deleting test files")

        class FakeProcess:
            def poll(self):
                return None

        with temp_dir() as tmpdir:
            screen = AITrainingScreen(
                self._manager(),
                policy_path=os.path.join("data", "ai_policies.json"),
                progress_path=os.path.join("data", "ai_training_progress.jsonl"),
            )
            screen.repo_root = tmpdir
            screen.training_kind = "rl"
            screen.result_view = "curve"
            screen.selected_deck = "fire"
            screen.games = 1
            screen.bootstrap_games = 1
            screen.eval_games = 1
            screen.max_steps = 40
            screen.rl_device = "cuda"

            stale_model = screen._abs_path(screen._rl_candidate_model_path())
            stale_meta = os.path.splitext(stale_model)[0] + ".json"
            progress = screen._abs_path(screen.progress_path)
            os.makedirs(os.path.dirname(stale_model), exist_ok=True)
            os.makedirs(os.path.dirname(progress), exist_ok=True)
            with open(stale_model, "w", encoding="utf-8") as fh:
                fh.write("stale")
            with open(stale_meta, "w", encoding="utf-8") as fh:
                json.dump({"stale": True}, fh)
            with open(progress, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"type": "old"}) + "\n")

            with patch("ui.screens.ai_training_screen.subprocess.Popen",
                       return_value=FakeProcess()) as popen_mock:
                screen._start_training()

            self.assertEqual(screen.status, "running")
            cmd = popen_mock.call_args.args[0]
            self.assertEqual(cmd[:4], ["conda", "run", "-n", "DL"])
            self.assertIn("train_deep_ai.py", cmd[6])
            self.assertIn("--progress-jsonl", cmd)
            self.assertIn("--max-steps", cmd)
            self.assertIn(screen._rl_candidate_model_path(), cmd)
            self.assertFalse(os.path.exists(stale_model))
            self.assertFalse(os.path.exists(stale_meta))
            self.assertFalse(os.path.exists(progress))

            screen._apply_progress_event({
                "type": "run_started",
                "trainer": "rl_ai",
                "deck": "fire",
                "total_training_games": 3,
                "device": "cuda",
                "max_steps": 40,
            })
            screen._apply_progress_event({
                "type": "bootstrap_finished",
                "deck": "fire",
                "games_played": 1,
                "examples": 2,
                "total_games_played": 1,
                "total_training_games": 3,
            })
            screen._apply_progress_event({
                "type": "self_play_game_finished",
                "deck": "fire",
                "game": 1,
                "target_games": 1,
                "stats": {"wins": 1, "losses": 0, "draws": 0},
                "win_rate": 1.0,
                "avg_score": 42.0,
                "examples": 3,
                "total_games_played": 2,
                "total_training_games": 3,
            })
            screen._apply_progress_event({
                "type": "train_phase_finished",
                "deck": "fire",
                "phase": "self_play",
                "policy_loss": 0.4,
                "value_loss": 0.1,
                "total_loss": 0.5,
                "examples": 3,
                "total_games_played": 2,
                "total_training_games": 3,
            })
            screen._apply_progress_event({
                "type": "eval_finished",
                "deck": "fire",
                "eval": {"games": 1, "wins": 1, "losses": 0, "draws": 0},
                "win_rate": 1.0,
                "total_games_played": 3,
                "total_training_games": 3,
            })

            with open(stale_model, "w", encoding="utf-8") as fh:
                fh.write("model")
            with open(stale_meta, "w", encoding="utf-8") as fh:
                json.dump({"metadata": {"trainer": "test", "summary": {"fire": {"eval": {"games": 1, "wins": 1}}}}}, fh)

            screen._apply_progress_event({
                "type": "run_finished",
                "trainer": "rl_ai",
                "output": screen._rl_candidate_model_path(),
                "sidecar": screen._active_sidecar_path(),
                "total_games_played": 3,
                "total_training_games": 3,
                "elapsed_seconds": 2.0,
            })

            for view in ("curve", "loss", "eval", "summary"):
                screen.result_view = view
                screen.draw(self.surface)

            self.assertTrue(screen._can_apply())
            screen._apply_candidate_policy()
            self.assertEqual(screen.status, "applied")
            self.assertTrue(os.path.exists(os.path.join(tmpdir, "data", "ai_models", "fire.pt")))
            self.assertTrue(os.path.exists(os.path.join(tmpdir, "data", "ai_models", "fire.json")))
            self.assertFalse(os.path.exists(os.path.join(tmpdir, "data", "ai_policies.json")))

    def test_ai_training_screen_apply_supports_root_relative_policy_path(self):
        with temp_dir() as tmpdir:
            candidate = os.path.join(tmpdir, "candidate.json")
            payload = {
                "version": 1,
                "policies": {"fire": {"weights": {"core_in_play": 80.0}}},
            }
            with open(candidate, "w", encoding="utf-8") as fh:
                json.dump(payload, fh)

            screen = AITrainingScreen(
                self._manager(),
                output_path=candidate,
                policy_path="policy.json",
                progress_path=os.path.join(tmpdir, "progress.jsonl"),
            )
            screen.repo_root = tmpdir
            screen.status = "completed"
            screen._load_candidate_payload()
            self.assertTrue(screen._can_apply())
            screen._apply_candidate_policy()

            self.assertEqual(screen.status, "applied")
            with open(os.path.join(tmpdir, "policy.json"), "r", encoding="utf-8") as fh:
                self.assertEqual(json.load(fh), payload)

    def test_game_layout_bounds_and_non_overlap(self):
        state, tm = self._game()
        screen = GameScreen(self._manager(), state, tm)
        layout = screen.layout
        bounds = pygame.Rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT)

        for name in (
            "board", "side_panel", "action_panel", "detail_panel", "log_panel",
            "opponent_deck", "opponent_discard", "player_deck", "player_discard",
            "stadium", "hand", "divider",
        ):
            rect = getattr(layout, name)
            self.assertTrue(bounds.contains(rect), name)

        self.assertFalse(layout.hand.colliderect(layout.action_panel))
        self.assertFalse(layout.action_panel.colliderect(layout.detail_panel))
        self.assertFalse(layout.detail_panel.colliderect(layout.log_panel))

        screen._build_action_buttons()
        for item in screen.action_buttons:
            self.assertTrue(layout.action_panel.contains(item["rect"]), item["label"])

    def test_energy_icons_render_real_and_fallback_surfaces(self):
        state, tm = self._game()
        screen = GameScreen(self._manager(), state, tm)
        basic = CardRegistry.get("sv1-ener-3")
        special = CardRegistry.get("svi-jete")
        missing = Card(api_id="missing-energy-icon", name="Missing Energy",
                       supertype="Energy", subtypes=["Special"])

        for card in (basic, special, missing):
            with self.subTest(card=card.api_id):
                icon = get_energy_icon_surface(screen.image_mgr, card, 28)
                self.assertEqual(icon.get_size(), (28, 28))
                self.assertGreater(icon.get_at((14, 14)).a, 0)

    def test_field_energy_icons_draw_for_active_and_bench(self):
        state, tm = self._game()
        player = state.get_active_player()
        energies = [
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("svi-jete"),
            CardRegistry.get("svi-dtur"),
        ]
        player.active.energy_cards.extend(energies)
        player.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        player.bench[0].energy_cards.extend(energies[:3])

        screen = GameScreen(self._manager(), state, tm)
        screen.draw(self.surface)

    def test_energy_distribution_selection_states_draw(self):
        state, _ = self._game()
        player = state.get_active_player()
        energies = [CardRegistry.get("sv1-ener-2"), CardRegistry.get("svi-jete")]
        screen = EnergyDistributionScreen(
            self._manager(),
            {
                "energy_cards": energies,
                "targets": [{"slot": "active", "name": player.active.card.name, "bench_idx": -1}],
                "source_name": player.active.card.name,
            },
            lambda assignments: None,
        )
        screen.selected_energy_idx = 0
        screen._assigned = [(1, 0)]
        screen.draw(self.surface)

    def test_attached_cards_screen_draws_sections_and_empty_state(self):
        state, _ = self._game()
        pokemon = state.get_active_player().active
        self._attach_public_cards(pokemon)
        screen = AttachedCardsScreen(
            self._manager(),
            "我方 战斗区 附属卡",
            pokemon.card.name,
            [
                ("退化卡", list(pokemon.evolution_stack)),
                ("能量卡", list(pokemon.energy_cards)),
                ("道具卡", [pokemon.attached_tool]),
            ],
        )
        screen.draw(self.surface)

        empty = AttachedCardsScreen(
            self._manager(),
            "我方 战斗区 附属卡",
            pokemon.card.name,
            [("退化卡", []), ("能量卡", []), ("道具卡", [])],
        )
        empty.draw(self.surface)

    def test_attached_cards_menu_entries_for_own_field(self):
        state, tm = self._game()
        player_idx = state.active_player_idx
        player = state.get_player(player_idx)
        player.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        self._attach_public_cards(player.active)
        self._attach_public_cards(player.bench[0])
        manager = self._manager()
        screen = GameScreen(manager, state, tm)

        screen._show_active_card_actions(player_idx)
        active_item = next(item for item in screen.card_action_menu
                           if item["action"] == "view_attached_cards")
        self.assertEqual(active_item["label"], "查看附属卡")
        self.assertIs(active_item["params"]["pokemon"], player.active)

        screen._show_bench_card_actions(player_idx, 0)
        bench_item = next(item for item in screen.card_action_menu
                          if item["action"] == "view_attached_cards")
        self.assertEqual(bench_item["label"], "查看附属卡")
        self.assertIs(bench_item["params"]["pokemon"], player.bench[0])

        screen._execute_card_action_item(bench_item, player_idx)
        self.assertIsInstance(manager.top, AttachedCardsScreen)
        manager.top.draw(self.surface)

    def test_attached_cards_menu_entries_for_opponent_field(self):
        state, tm = self._game()
        opponent = state.get_opponent()
        opponent.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        self._attach_public_cards(opponent.active)
        self._attach_public_cards(opponent.bench[0])
        manager = self._manager()
        screen = GameScreen(manager, state, tm)

        screen._handle_click(screen._opp_active_rect().center, state.active_player_idx)
        self.assertEqual(len(screen.card_action_menu), 1)
        active_item = screen.card_action_menu[0]
        self.assertEqual(active_item["action"], "view_attached_cards")
        self.assertEqual(active_item["label"], "查看附属卡")

        screen._execute_card_action_item(active_item, state.active_player_idx)
        self.assertIsInstance(manager.top, AttachedCardsScreen)
        manager.pop_screen()

        screen._handle_click(screen._opp_bench_rect(0).center, state.active_player_idx)
        self.assertEqual(len(screen.card_action_menu), 1)
        bench_item = screen.card_action_menu[0]
        self.assertEqual(bench_item["action"], "view_attached_cards")
        self.assertIs(bench_item["params"]["pokemon"], opponent.bench[0])

    def test_coin_flip_draws_phases_and_calls_back_once(self):
        callbacks = []
        font = pygame.font.Font(None, 24)
        anim = CoinFlipAnimation()
        anim.start(flip_count=1, on_result=lambda results: callbacks.append(results))

        anim.draw(self.surface, font)
        self.assertEqual(anim.phase, "flipping")

        anim.update(anim.flip_duration + 0.01)
        self.assertEqual(anim.phase, "showing")
        anim.draw(self.surface, font)

        anim.update(anim.show_duration + 0.01)
        self.assertEqual(anim.phase, "summary")
        anim.draw(self.surface, font)
        self.assertEqual(callbacks, [])

        anim.update(anim.summary_duration + 0.01)
        self.assertFalse(anim.active)
        self.assertEqual(len(callbacks), 1)
        self.assertEqual(callbacks[0], anim.results)

    def test_attack_button_uses_turn_rules(self):
        state = GameState()
        active = CardRegistry.get("sv2-delib")
        state.p1.active = PokemonInPlay(active)
        state.p2.active = PokemonInPlay(active)
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 1
        screen = GameScreen(self._manager(), state, TurnManager(state))

        ok, reason = can_declare_attack(state, 0, 0)
        self.assertFalse(ok)
        self.assertIn("先攻", reason)
        first_btn = next(i for i in screen.action_buttons
                         if i["action"] == "ENTER_ATTACK")
        self.assertFalse(first_btn["enabled"])

        state.active_player_idx = 1
        state.turn_number = 2
        screen._build_action_buttons()
        ok, reason = can_declare_attack(state, 1, 0)
        self.assertTrue(ok, reason)
        second_btn = next(i for i in screen.action_buttons
                          if i["action"] == "ENTER_ATTACK")
        self.assertTrue(second_btn["enabled"])

        screen._execute_action("ENTER_ATTACK", 1)
        screen._show_attack_menu(1)
        self.assertTrue(screen._attack_menu_open)
        self.assertEqual([idx for idx, _ in screen._attack_menu_attacks], [0])

    def test_phase_panel_removes_generic_action_buttons(self):
        state, tm = self._game()
        screen = GameScreen(self._manager(), state, tm)
        generic = {
            PlayerAction.PLAY_BASIC,
            PlayerAction.EVOLVE,
            PlayerAction.ATTACH_ENERGY,
            PlayerAction.PLAY_TRAINER,
            PlayerAction.USE_ABILITY,
            PlayerAction.RETREAT,
        }
        self.assertFalse(any(item["action"] in generic for item in screen.action_buttons))
        self.assertTrue(any(item["action"] == PlayerAction.END_TURN
                            for item in screen.phase_buttons))

    def test_setup_done_enables_after_active_context_place(self):
        state, tm = self._setup_game()
        screen = GameScreen(self._manager(), state, tm)
        screen._fly_card_from_hand = self._finish_fly_immediately
        player_idx = screen.setup_player_idx
        player = state.get_player(player_idx)
        basic_idx = next(i for i, c in enumerate(player.hand)
                         if c.is_basic_pokemon)

        self.assertFalse(self._phase_button(screen, "SETUP_DONE")["enabled"])
        screen._show_hand_card_actions(player_idx, basic_idx)
        item = next(i for i in screen.card_action_menu
                    if i["action"] == "setup_place_active")
        screen._execute_card_action_item(item, player_idx)

        self.assertIsNotNone(player.active)
        self.assertTrue(self._phase_button(screen, "SETUP_DONE")["enabled"])

    def test_setup_done_refreshes_when_setup_player_changes(self):
        state, tm = self._setup_game()
        screen = GameScreen(self._manager(), state, tm)
        screen._fly_card_from_hand = self._finish_fly_immediately
        player_idx = screen.setup_player_idx
        player = state.get_player(player_idx)
        basic_idx = next(i for i, c in enumerate(player.hand)
                         if c.is_basic_pokemon)
        screen.selected_hand_idx = basic_idx
        screen._setup_place(player_idx, "active")

        self.assertTrue(self._phase_button(screen, "SETUP_DONE")["enabled"])
        screen._setup_done(player_idx)

        self.assertEqual(screen.setup_player_idx, 1 - player_idx)
        self.assertFalse(self._phase_button(screen, "SETUP_DONE")["enabled"])

    def test_challenge_mode_keeps_human_bottom_and_ai_runs_setup(self):
        state, tm = self._setup_game()
        screen = GameScreen(
            self._manager(), state, tm,
            challenge_mode=True,
            human_player_idx=0,
            ai_player_idx=1,
            ai_controller=ChallengeAI(AIConfig(
                thinking_time_seconds=0.01,
                beam_width=2,
                max_sequence_depth=1,
                max_turn_actions=5,
            )),
        )
        player = state.p1
        basic_idx = next(i for i, c in enumerate(player.hand) if c.is_basic_pokemon)
        result = tm.setup_place_basic(0, basic_idx, "active")
        self.assertTrue(result.success, result.log_message)
        screen._setup_done(0)

        self._pump_until(
            screen,
            lambda: state.p2.active is not None and state.phase != TurnPhase.SETUP,
        )

        self.assertIs(screen._get_display_player(), state.p1)
        self.assertIs(screen._get_opponent(), state.p2)
        self.assertIsNotNone(state.p2.active)
        self.assertNotEqual(state.phase, TurnPhase.SETUP)
        screen.draw(self.surface)

    def test_debug_client_deterministically_resolves_new_choice_domains(self):
        state, tm = self._game()
        screen = GameScreen(self._manager(), state, tm)
        player_idx = state.active_player_idx
        player = state.get_player(player_idx)
        energy = CardRegistry.get("sv1-ener-3")
        player.active.energy_cards.append(energy)
        payloads = {}

        requests = [
            ActionRequest(
                "choose_trigger_order",
                player_idx,
                "选择触发顺序",
                target_info=[
                    {"index": 0, "label": "学习装置 A"},
                    {"index": 1, "label": "学习装置 B"},
                ],
                callback=lambda value: payloads.__setitem__("order", value),
            ),
            ActionRequest(
                "confirm_trigger",
                player_idx,
                "是否使用触发效果？",
                callback=lambda value: payloads.__setitem__("confirm", value),
            ),
            ActionRequest(
                "select_attachment",
                player_idx,
                "选择具体能量实体",
                from_zone="field",
                target_info=[{
                    "player": player_idx,
                    "slot": "active",
                    "attachment_type": "energy",
                    "index": 0,
                    "card_id": energy.api_id,
                    "label": energy.name,
                }],
                callback=lambda value: payloads.__setitem__("attachment", value),
            ),
            ActionRequest(
                "select_prize_energy_target",
                player_idx,
                "选择宝藏能量附着目标",
                min_select=0,
                max_select=1,
                from_zone="board",
                target_player="self",
                card_list=[player.active.card],
                callback=lambda value: payloads.__setitem__("treasure", value),
            ),
        ]

        for request in requests:
            with self.subTest(request_type=request.request_type):
                result = screen._resolve_deterministic_pending(request)
                self.assertTrue(result.success, result.log_message)

        self.assertEqual(payloads["order"], 0)
        self.assertTrue(payloads["confirm"])
        self.assertEqual(payloads["attachment"][0].index, 0)
        self.assertEqual(payloads["attachment"][0].card_id, energy.api_id)
        self.assertEqual(payloads["treasure"][0].slot, "active")

    def test_draw_result_opens_draw_end_screen_without_winner(self):
        state, tm = self._game()
        state.set_result(
            "DRAW",
            winner=-1,
            reason="双方同时满足相同数量的胜利条件",
            conditions=[["NO_POKEMON"], ["NO_POKEMON"]],
        )
        manager = self._manager()
        screen = GameScreen(manager, state, tm)
        manager.push_screen(screen)

        screen._show_end_screen()

        self.assertIsInstance(manager.top, EndScreen)
        self.assertEqual(manager.top.result_status, "DRAW")
        self.assertEqual(manager.top.winner_idx, -1)

    def test_challenge_ai_attack_animates_correct_side_and_auto_ends(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-challenge-ai-attacker",
            name="Challenge AI Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Tap", [], 10, "")],
        )
        defender = Card(
            api_id="test-challenge-human-defender",
            name="Challenge Human Defender",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(defender)
        state.p2.active = PokemonInPlay(attacker)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        class ScriptedAI:
            def choose_action(self, game_state, player_idx):
                if game_state.phase == TurnPhase.MAIN:
                    return AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
                return AIAction(PlayerAction.END_TURN, {}, terminal=True)

            def resolve_pending_action(self, game_state, action_request):
                return ChallengeAI().resolve_pending_action(game_state, action_request)

            def apply_choice(self, game_state, action_request, choice):
                return ChallengeAI().apply_choice(game_state, action_request, choice)

        screen = GameScreen(
            self._manager(), state, TurnManager(state),
            challenge_mode=True,
            human_player_idx=0,
            ai_player_idx=1,
            ai_controller=ScriptedAI(),
        )
        screen._sync_tracking_counts()

        self._pump_until(
            screen,
            lambda: state.active_player_idx == 0 and state.phase == TurnPhase.MAIN,
        )
        self.assertIn(SLOT_PLAYER_ACTIVE, screen.damage_flash._flashes)
        self.assertIn(SLOT_OPP_ACTIVE, screen.attack_shake._shakes)
        self.assertEqual(state.active_player_idx, 0)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_challenge_ai_final_ko_shows_end_screen(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-challenge-ai-final-ko-attacker",
            name="Challenge AI Final KO Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Finish", [], 120, "")],
        )
        defender = Card(
            api_id="test-challenge-human-final-ko-defender",
            name="Challenge Human Final KO Defender",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=60,
            energy_types=["Colorless"],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(defender)
        state.p2.active = PokemonInPlay(attacker)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        class ScriptedAI:
            def choose_action(self, game_state, player_idx):
                return AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)

            def resolve_pending_action(self, game_state, action_request):
                return ChallengeAI().resolve_pending_action(game_state, action_request)

            def apply_choice(self, game_state, action_request, choice):
                return ChallengeAI().apply_choice(game_state, action_request, choice)

        manager = self._manager()
        screen = GameScreen(
            manager, state, TurnManager(state),
            challenge_mode=True,
            human_player_idx=0,
            ai_player_idx=1,
            ai_controller=ScriptedAI(),
        )
        manager.push_screen(screen)

        self._pump_until(
            screen,
            lambda: state.winner == 1 and isinstance(manager.top, EndScreen),
        )

        self.assertEqual(state.winner, 1)
        self.assertEqual(state.phase, TurnPhase.GAME_OVER)
        self.assertIsInstance(manager.top, EndScreen)

    def test_challenge_ai_search_does_not_block_update_loop(self):
        base = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(base)
        state.p2.active = PokemonInPlay(base)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        class SlowAI:
            def choose_action(self, game_state, player_idx):
                time.sleep(0.2)
                return AIAction(PlayerAction.END_TURN, {}, terminal=True)

            def resolve_pending_action(self, game_state, action_request):
                return ChallengeAI().resolve_pending_action(game_state, action_request)

            def apply_choice(self, game_state, action_request, choice):
                return ChallengeAI().apply_choice(game_state, action_request, choice)

        screen = GameScreen(
            self._manager(), state, TurnManager(state),
            challenge_mode=True,
            human_player_idx=0,
            ai_player_idx=1,
            ai_controller=SlowAI(),
        )

        started = time.perf_counter()
        screen.update(1.0)
        elapsed = time.perf_counter() - started

        self.assertLess(elapsed, 0.1)
        self.assertIsNotNone(screen._ai_action_future)
        self.assertEqual(state.active_player_idx, 1)

        self._pump_until(
            screen,
            lambda: state.active_player_idx == 0 and state.phase == TurnPhase.MAIN,
            frames=120,
        )

    def test_challenge_human_ko_ai_promotes_without_blocking(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-human-ko-attacker",
            name="Human KO Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Knock Out", [], 120, "")],
        )
        ai_active = Card(
            api_id="test-ai-ko-defender",
            name="AI KO Defender",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=60,
            energy_types=["Colorless"],
        )
        ai_bench = Card(
            api_id="test-ai-promotion-bench",
            name="AI Promotion Bench",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=90,
            energy_types=["Colorless"],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(attacker)
        state.p2.active = PokemonInPlay(ai_active)
        state.p2.bench[0] = PokemonInPlay(ai_bench)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        screen = GameScreen(
            self._manager(), state, TurnManager(state),
            challenge_mode=True,
            human_player_idx=0,
            ai_player_idx=1,
        )
        result = screen.tm.declare_attack(0, 0)
        self.assertTrue(result.success, result.log_message)
        self.assertGreaterEqual(state.pending_promotion_player, 0)

        screen._show_result(result, attacker_player_idx=0, action=PlayerAction.DECLARE_ATTACK)

        self.assertEqual(state.pending_promotion_player, -1)
        self.assertEqual(state.phase, TurnPhase.ATTACK)
        self.assertEqual(state.p2.active.card.api_id, "test-ai-promotion-bench")
        self.assertFalse(screen._should_block_challenge_input())

    def test_challenge_ai_animation_state_does_not_hide_human_hand_or_discard(self):
        base = CardRegistry.get("sv2-delib")
        energy = CardRegistry.get("sv1-ener-3")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(base)
        state.p2.active = PokemonInPlay(base)
        state.p1.hand = [base, energy]
        state.p2.hand = [base, energy]
        state.p1.discard = [base, energy]
        state.p2.discard = [base, energy]
        screen = GameScreen(
            self._manager(), state, TurnManager(state),
            challenge_mode=True,
            human_player_idx=0,
            ai_player_idx=1,
        )

        screen._hide_hand_index(1, 0)
        with patch.object(hand_display, "draw_hand_card") as draw_card:
            hand_display.draw_hand(screen, self.surface, state.p1)
        self.assertEqual(draw_card.call_count, len(state.p1.hand))

        screen._hide_discard_index(1, 1)
        captured = {}

        def capture_stack(*args, **kwargs):
            captured["count"] = args[7]
            captured["top_card_name"] = kwargs.get("top_card_name")

        with patch.object(board_renderer, "_draw_card_stack_with_count",
                          side_effect=capture_stack):
            board_renderer.draw_player_discard(screen, self.surface)
        self.assertEqual(captured["count"], len(state.p1.discard))
        self.assertEqual(captured["top_card_name"], energy.name)

        with patch.object(board_renderer, "_draw_card_stack_with_count",
                          side_effect=capture_stack):
            board_renderer.draw_opponent_discard(screen, self.surface)
        self.assertEqual(captured["count"], 1)
        self.assertEqual(captured["top_card_name"], base.name)

        screen._sync_tracking_counts()
        screen._set_last_action_context(1, (123, 45), energy.name, energy)
        state.p1.deck = [energy]
        screen._last_deck_counts[0] = 1
        state.p1.deck.pop()
        state.p1.hand.append(energy)
        screen._detect_state_changes()
        self.assertEqual(screen._last_action_player_idx, 1)

    def test_hand_card_context_menu_builds_card_actions(self):
        state, tm = self._game()
        player_idx = state.active_player_idx
        player = state.get_player(player_idx)
        player.hand.append(CardRegistry.get("sv2-delib"))
        player.hand.append(CardRegistry.get("sv1-ener-3"))
        screen = GameScreen(self._manager(), state, tm)

        basic_idx = len(player.hand) - 2
        screen._show_hand_card_actions(player_idx, basic_idx)
        self.assertEqual(
            {"play_basic_select_bench"},
            {item["action"] for item in screen.card_action_menu},
        )

        energy_idx = len(player.hand) - 1
        screen._show_hand_card_actions(player_idx, energy_idx)
        attach = next(item for item in screen.card_action_menu
                      if item["action"] == "attach_energy_select")
        self.assertTrue(attach["enabled"])
        screen._execute_card_action_item(attach, player_idx)
        self.assertEqual(screen.selected_action, PlayerAction.ATTACH_ENERGY)

    def test_supporter_and_stadium_context_menu_limits(self):
        active = CardRegistry.get("sv2-delib")
        state = GameState()
        state.p1.active = PokemonInPlay(active)
        state.p2.active = PokemonInPlay(active)
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 1
        professor = CardRegistry.get("sv1-189")
        stadium = Card(api_id="test-stadium", name="Test Stadium",
                       supertype="Trainer", subtypes=["Stadium"])
        state.p1.hand = [professor, stadium]
        screen = GameScreen(self._manager(), state, TurnManager(state))

        self.assertFalse(can_play_supporter(state, 0)[0])
        screen._show_hand_card_actions(0, 0)
        supporter_item = next(item for item in screen.card_action_menu
                              if item["action"] == "play_trainer")
        self.assertFalse(supporter_item["enabled"])

        state.p1.stadium_played_this_turn = True
        screen._show_hand_card_actions(0, 1)
        stadium_item = next(item for item in screen.card_action_menu
                            if item["action"] == "play_trainer")
        self.assertFalse(stadium_item["enabled"])

    def test_first_turn_draw_and_evolution_rules(self):
        state, _tm = self._game()
        first = state.first_player_idx
        # Seven-card opening hand, one Active placement, then the normal turn
        # one draw: the first player has seven cards again. The second player
        # has not drawn for their first turn yet.
        self.assertEqual(len(state.get_player(first).hand), 7)
        self.assertEqual(len(state.get_player(1 - first).hand), 6)

        froakie = CardRegistry.get("sv2-38")
        frogadier = CardRegistry.get("sv2-39")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 2
        state.p2.active = PokemonInPlay(froakie)
        state.p2.active.placed_this_turn = False
        ok, reason = can_evolve(state, 1, "active", frogadier)
        self.assertFalse(ok)
        self.assertIn("First-turn", reason)

    def test_stadium_play_once_per_turn(self):
        active = CardRegistry.get("sv2-delib")
        stadium1 = Card(api_id="stadium-1", name="Stadium 1",
                        supertype="Trainer", subtypes=["Stadium"])
        stadium2 = Card(api_id="stadium-2", name="Stadium 2",
                        supertype="Trainer", subtypes=["Stadium"])
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(active)
        state.p2.active = PokemonInPlay(active)
        state.p1.hand = [stadium1, stadium2]
        tm = TurnManager(state)

        first = tm.perform_action(PlayerAction.PLAY_TRAINER, player_idx=0, hand_idx=0)
        self.assertTrue(first.success, first.log_message)
        self.assertTrue(state.p1.stadium_played_this_turn)
        second = tm.perform_action(PlayerAction.PLAY_TRAINER, player_idx=0, hand_idx=0)
        self.assertFalse(second.success)

    def test_attack_ends_turn_atomically(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-attacker",
            name="Test Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Tap", [], 0, "")],
        )
        defender = Card(
            api_id="test-defender",
            name="Test Defender",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(attacker)
        state.p2.active = PokemonInPlay(defender)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6
        manager = self._manager()
        screen = GameScreen(manager, state, TurnManager(state))

        screen._execute_action("ENTER_ATTACK", 0)
        screen._show_attack_menu(0)
        screen._attack_menu_hover = 0
        screen._handle_attack_menu_click((0, 0))

        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)
        self.assertFalse(screen._attack_menu_open)
        self.assertGreater(screen._pending_turn_end, 0)

        screen.update(1.0)
        self.assertIsInstance(manager.top, PassScreen)

    def test_professor_research_animates_discard_then_draw_once(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 1
        state.active_player_idx = 0
        state.turn_number = 2
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        professor = CardRegistry.get("sv1-189")
        filler = CardRegistry.get("sv2-delib")
        energy = CardRegistry.get("sv1-ener-3")
        state.p1.hand = [professor, filler, energy]
        state.p1.deck = [energy] * 10

        screen = GameScreen(self._manager(), state, TurnManager(state))
        screen._sync_tracking_counts()
        screen.selected_hand_idx = 0
        screen._play_trainer(0)

        self.assertEqual(len(state.p1.hand), 7)
        self.assertEqual(len(state.p1.discard), 3)
        self.assertEqual(screen._last_hand_counts[0], len(state.p1.hand))
        self.assertEqual(screen._last_discard_counts[0], len(state.p1.discard))
        self.assertGreaterEqual(len(screen.card_fly.active), 3)


if __name__ == "__main__":
    unittest.main()

"""UI smoke tests for the Pygame screens.

Run with:
    python -B tests/test_ui_smoke.py
"""
import os
import json
import sys
import tempfile
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
from engine.ai import AIAction, AIConfig, ChallengeAI
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import (
    can_declare_attack,
    can_evolve,
    can_play_supporter,
)
from engine.turn_manager import TurnManager
from network.state_serializer import (
    serialize_action_request,
    serialize_game_state,
    deserialize_game_state,
)
from ui.screen_manager import ScreenManager
from ui.components import board_renderer, hand_display
from ui.components.game_layout import SLOT_OPP_ACTIVE, SLOT_PLAYER_ACTIVE
from ui.screens.deck_select import DeckSelectScreen
from ui.screens.end_screen import EndScreen
from ui.screens.attached_cards_screen import AttachedCardsScreen
from ui.screens.ai_training_screen import AITrainingScreen
from ui.screens.energy_distribution_screen import EnergyDistributionScreen
from ui.screens.game_screen import GameScreen
from ui.screens.help_screen import HelpScreen
from ui.screens.lobby_screen import LobbyScreen, LobbyState
from ui.screens.pass_screen import PassScreen
from ui.screens.search_screen import SearchScreen
from ui.screens.title_screen import TitleScreen
from ui.coin_flip import CoinFlipAnimation
from ui.energy_icons import get_energy_icon_surface


class UiSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pygame.init()
        pygame.display.set_mode((1, 1))
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS, use_api=False)
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

    def _game(self):
        state = GameState()
        state.setup_game(expand_deck(FIRE_DECK), expand_deck(WATER_DECK))
        tm = TurnManager(state)
        for pi in (0, 1):
            for _ in range(10):
                if tm.needs_mulligan(pi):
                    state.do_mulligan(pi)
                else:
                    break
            player = state.get_player(pi)
            basic_idx = next(i for i, c in enumerate(player.hand) if c.is_basic_pokemon)
            tm.setup_place_basic(pi, basic_idx, "active")
        tm.setup_finalize()
        return state, tm

    def _setup_game(self):
        state = GameState()
        state.setup_game(expand_deck(FIRE_DECK), expand_deck(WATER_DECK))
        tm = TurnManager(state)
        for pi in (0, 1):
            for _ in range(10):
                if tm.needs_mulligan(pi):
                    state.do_mulligan(pi)
                else:
                    break
        return state, tm

    def _finish_fly_immediately(self, *args, **kwargs):
        callback = kwargs.get("on_complete")
        if callback:
            callback()

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

    class _FakeNetwork:
        def __init__(self):
            self.sent = []
            self.is_connected = True
            self.is_stale = False
            self.last_error = None
            self.stopped = False

        def send(self, message):
            self.sent.append(message)

        def poll(self, max_messages=None):
            return []

        def stop(self):
            self.stopped = True

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
        ]

        for screen in screens:
            with self.subTest(screen=screen.__class__.__name__):
                screen.update(1 / 60)
                screen.draw(self.surface)

    def test_ai_training_screen_progress_states_draw(self):
        with tempfile.TemporaryDirectory() as tmpdir:
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
        class FakeProcess:
            def poll(self):
                return None

        with tempfile.TemporaryDirectory() as tmpdir:
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

    def test_ai_training_screen_apply_supports_root_relative_policy_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
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
        state.first_player_idx = 1
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

        for _ in range(12):
            screen.update(1.0)

        self.assertIs(screen._get_display_player(), state.p1)
        self.assertIs(screen._get_opponent(), state.p2)
        self.assertIsNotNone(state.p2.active)
        self.assertNotEqual(state.phase, TurnPhase.SETUP)
        screen.draw(self.surface)

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

        screen.update(1.0)
        self.assertEqual(state.phase, TurnPhase.ATTACK)
        self.assertIn(SLOT_PLAYER_ACTIVE, screen.damage_flash._flashes)
        self.assertIn(SLOT_OPP_ACTIVE, screen.attack_shake._shakes)

        screen.update(1.0)
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

        screen.update(1.0)

        self.assertEqual(state.winner, 1)
        self.assertEqual(state.phase, TurnPhase.GAME_OVER)
        self.assertIsInstance(manager.top, EndScreen)

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
        state = GameState()
        state.setup_game(expand_deck(FIRE_DECK), expand_deck(WATER_DECK))
        tm = TurnManager(state)
        for pi in (0, 1):
            for _ in range(10):
                if tm.needs_mulligan(pi):
                    state.do_mulligan(pi)
                else:
                    break
            player = state.get_player(pi)
            basic_idx = next(i for i, c in enumerate(player.hand) if c.is_basic_pokemon)
            tm.setup_place_basic(pi, basic_idx, "active")
        first = state.first_player_idx
        before = len(state.get_player(first).hand)
        tm.setup_finalize()
        self.assertEqual(len(state.get_player(first).hand), before)

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

    def test_attack_waits_for_manual_end_turn(self):
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
        screen = GameScreen(self._manager(), state, TurnManager(state))

        screen._execute_action("ENTER_ATTACK", 0)
        screen._show_attack_menu(0)
        screen._attack_menu_hover = 0
        screen._handle_attack_menu_click((0, 0))

        self.assertEqual(state.active_player_idx, 0)
        self.assertEqual(state.phase, TurnPhase.ATTACK)
        self.assertFalse(screen._attack_menu_open)
        self.assertTrue(self._phase_button(screen, PlayerAction.END_TURN)["enabled"])

        screen._do_end_turn()
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_remote_attack_waits_for_remote_end_turn(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-remote-attacker",
            name="Remote Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Tap", [], 0, "")],
        )
        defender = Card(
            api_id="test-remote-defender",
            name="Remote Defender",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 4
        state.p1.active = PokemonInPlay(defender)
        state.p2.active = PokemonInPlay(attacker)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6
        network = self._FakeNetwork()
        screen = GameScreen(
            self._manager(), state, TurnManager(state),
            network_manager=network, my_player_idx=0,
        )

        screen._process_network_message({
            "type": "action",
            "action": "DECLARE_ATTACK",
            "params": {"attack_idx": 0, "player_idx": 1},
        })

        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.ATTACK)
        self.assertTrue(screen._waiting_remote)
        self.assertTrue(self._phase_button(screen, PlayerAction.END_TURN)["enabled"])
        self.assertTrue(network.sent)
        self.assertFalse(any(msg.get("action") == "END_TURN" for msg in network.sent))

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

    def test_remote_state_update_opens_confirm_and_sends_choice_response(self):
        state, _ = self._game()
        manager = self._manager()
        fake_network = self._FakeNetwork()
        client_state = deserialize_game_state(
            serialize_game_state(state, for_player_idx=1),
            for_player_idx=1,
        )
        screen = GameScreen(
            manager, None, None,
            network_manager=fake_network,
            my_player_idx=1,
            initial_state=client_state,
        )

        pending = ActionRequest(
            "confirm", 1, "是否替换战斗宝可梦？",
            request_id="req-confirm-1",
        )
        screen._process_network_message({
            "type": "state_update",
            "seq": 1,
            "state": serialize_game_state(state, for_player_idx=1),
            "pending_action": serialize_action_request(pending),
        })

        self.assertIsNotNone(screen._confirm_dialog)
        screen._confirm_dialog["on_confirm"]()
        self.assertEqual(fake_network.sent[-1]["type"], "choice_response")
        self.assertEqual(fake_network.sent[-1]["request_id"], "req-confirm-1")
        self.assertTrue(fake_network.sent[-1]["confirmed"])

    def test_lobby_enter_and_escape_work_when_input_is_focused(self):
        screen = LobbyScreen(self._manager())
        screen._transition_to(LobbyState.LAN_CLIENT)
        screen._ip_input.text = "127.0.0.1"
        screen._ip_input.focus()

        calls = []
        screen._do_connect = lambda: calls.append("connect")
        screen.handle_event(pygame.event.Event(
            pygame.KEYDOWN, {"key": pygame.K_RETURN, "mod": 0}
        ))
        self.assertEqual(calls, ["connect"])

        screen._ip_input.focus()
        screen.handle_event(pygame.event.Event(
            pygame.KEYDOWN, {"key": pygame.K_ESCAPE, "mod": 0}
        ))
        self.assertEqual(screen._state, LobbyState.MODE_SELECT)

    def test_lobby_back_click_does_not_depend_on_hover_state(self):
        screen = LobbyScreen(self._manager())
        screen._transition_to(LobbyState.LAN_CLIENT)

        screen.handle_event(pygame.event.Event(
            pygame.MOUSEBUTTONDOWN,
            {"button": 1, "pos": screen.back_btn.center},
        ))
        self.assertEqual(screen._state, LobbyState.MODE_SELECT)

    def test_lobby_hover_uses_virtual_mouse_position(self):
        screen = LobbyScreen(self._manager())
        cold = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT)).convert()
        hot = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT)).convert()

        with patch("pygame.mouse.get_pos", return_value=(-9999, -9999)):
            screen._mouse_pos = (-9999, -9999)
            screen.draw(cold)
            create_rect = next(
                ctrl["rect"] for ctrl in screen._controls
                if ctrl["name"] == "lan_create"
            )
            sample_pos = (create_rect.x + 12, create_rect.y + 12)

            screen._mouse_pos = create_rect.center
            screen.draw(hot)

        self.assertNotEqual(cold.get_at(sample_pos), hot.get_at(sample_pos))

    def test_lobby_cancel_connecting_stops_network(self):
        manager = self._manager()
        network = self._FakeNetwork()
        network.is_connected = False
        app = type("App", (), {
            "network_manager": network,
            "is_remote_host": True,
            "is_remote_client": False,
        })()
        manager._app = app
        screen = LobbyScreen(manager)
        screen._nm = network
        screen._state = LobbyState.CONNECTING
        screen._connect_origin_state = LobbyState.LAN_HOST
        screen._connection_started = True

        screen.handle_event(pygame.event.Event(
            pygame.KEYDOWN, {"key": pygame.K_ESCAPE, "mod": 0}
        ))
        self.assertTrue(network.stopped)
        self.assertIsNone(app.network_manager)
        self.assertEqual(screen._state, LobbyState.LAN_HOST)
        self.assertFalse(screen._connection_started)

    def test_lobby_relay_auto_mode_attaches_existing_connection(self):
        manager = self._manager()
        network = self._FakeNetwork()
        network.is_connected = False
        app = type("App", (), {
            "network_manager": network,
            "is_remote_host": False,
            "is_remote_client": True,
            "auto_client_ip": "127.0.0.1",
            "auto_client_port": 8765,
        })()
        manager._app = app
        screen = LobbyScreen(manager)
        screen.auto_mode = "relay_client"
        screen._room_code_input.text = "1234"

        screen.update(1 / 60)
        self.assertIs(screen.network_manager, network)
        self.assertEqual(screen._state, LobbyState.RELAY_CLIENT)
        self.assertTrue(screen._connection_started)
        self.assertIn("1234", screen.status_text)

    def test_title_auto_relay_sets_lobby_state_used_by_lobby_screen(self):
        manager = self._manager()

        class FakeApp:
            auto_connect = "relay"
            auto_relay_host = "relay.example.test"
            auto_relay_port = 9999
            auto_relay_room = "4321"
            started = None

            def start_relay_client(self, host, port, room_code):
                self.started = ("client", host, port, room_code)

            def start_relay_host(self, host, port):
                self.started = ("host", host, port)

        app = FakeApp()
        manager._app = app
        title = TitleScreen(manager)

        title._do_auto_connect()

        self.assertEqual(app.started, ("client", "relay.example.test", 9999, "4321"))
        self.assertIsInstance(manager.top, LobbyScreen)
        self.assertEqual(manager.top.auto_mode, "relay_client")
        self.assertEqual(manager.top._room_code_input.text, "4321")
        self.assertEqual(manager.top._relay_host_input.text, "relay.example.test")
        self.assertIsNone(app.auto_connect)


if __name__ == "__main__":
    unittest.main()

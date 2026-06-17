"""Challenge AI unit tests."""
import json
import os
import subprocess
import sys
import time
import unittest
from concurrent.futures.process import BrokenProcessPool
from types import SimpleNamespace
from unittest.mock import patch

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data.card_models import AbilityDef, AttackDef, Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK, expand_deck
from engine.ai import AIAction, AIChoice, AIConfig, ChallengeAI, create_challenge_ai, DECK_AI_PROFILES
from engine.ai.profiles import load_policy_weights
from engine.ai.training import (
    PlayGameTask,
    TrainingTaskRunner,
    TrainingConfig,
    _run_play_game_tasks,
    apply_benchmark_acceptance_guard,
    benchmark_policies,
    clamp_weight,
    evaluate_policy,
    play_game,
    play_match,
    _make_ai,
    run_training,
    train_deck,
)
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import can_play_basic, can_play_stadium, can_use_ability
from engine.snapshot import snapshot_state
from engine.turn_manager import TurnManager
from tests.temp_utils import best_effort_unlink, temp_dir, temp_file_path


class ChallengeAITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def _started_game(self):
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
            result = tm.setup_place_basic(pi, basic_idx, "active")
            self.assertTrue(result.success, result.log_message)
        result = tm.setup_finalize()
        self.assertTrue(result.success, result.log_message)
        return state

    def _simple_public_state(self):
        basic = CardRegistry.get("sv2-delib")
        energy = CardRegistry.get("sv1-ener-3")
        alt_basic = CardRegistry.get("svi-chim")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(basic)
        state.p2.active = PokemonInPlay(basic)
        state.p2.hand = [energy, alt_basic]
        state.p2.deck = [energy] * 10
        state.p1.hand = [alt_basic, energy, basic]
        state.p1.deck = [basic, energy, alt_basic] * 4
        state.p1.prizes = [basic] * 6
        state.p2.prizes = [basic] * 6
        return state

    def test_legal_actions_simulate_successfully(self):
        state = self._started_game()
        state.active_player_idx = 1
        state.phase = TurnPhase.MAIN
        state.turn_number = max(state.turn_number, 3)

        ai = ChallengeAI(AIConfig(
            thinking_time_seconds=0.05,
            beam_width=4,
            max_sequence_depth=2,
            max_turn_actions=10,
        ))
        actions = ai.legal_actions(state, 1)
        self.assertTrue(actions)
        self.assertFalse(any(
            action.action == PlayerAction.PLAY_BASIC
            and action.params.get("target") == "active"
            for action in actions
        ))

        for action in actions[:8]:
            with self.subTest(action=action):
                sim = ai._clone_state(state)
                result = ai._apply_action_for_sim(sim, 1, action)
                self.assertIsNotNone(result)
                self.assertTrue(result.success, result.log_message)

    def test_deck_specific_ai_factory_covers_all_profiles(self):
        for deck_key in DECK_AI_PROFILES:
            with self.subTest(deck_key=deck_key):
                ai = create_challenge_ai(deck_key, AIConfig(policy_path=None))
                self.assertEqual(ai.profile.key, deck_key)
                self.assertGreater(ai.config.thinking_time_seconds, 5.0)

    def test_ai_layers_are_present_and_delegate(self):
        state = self._simple_public_state()
        ai = create_challenge_ai("water", AIConfig(policy_path=None, max_turn_actions=8))

        self.assertIs(ai.enumerator.ai, ai)
        self.assertIs(ai.simulator.ai, ai)
        self.assertIs(ai.evaluator.ai, ai)
        self.assertIs(ai.choice_policy.ai, ai)
        self.assertEqual(ai.legal_actions(state, 1), ai.enumerator.legal_actions(state, 1))
        self.assertEqual(ai.evaluate_state(state, 1), ai.evaluator.evaluate_state(state, 1))

    def test_ai_config_defaults_to_expert_hybrid_budget(self):
        config = AIConfig(policy_path=None)

        self.assertEqual(config.search_algorithm, "hybrid")
        self.assertGreaterEqual(config.thinking_time_seconds, 8.0)
        self.assertGreaterEqual(config.beam_width, 24)
        self.assertGreaterEqual(config.max_sequence_depth, 10)
        self.assertGreaterEqual(config.max_turn_actions, 40)
        self.assertGreaterEqual(config.minimax_max_depth, 4)
        self.assertGreaterEqual(config.minimax_determinizations, 3)
        self.assertGreaterEqual(config.chance_branch_limit, 6)
        self.assertGreaterEqual(config.search_node_budget, 2500)

    def test_challenge_ai_exposes_extracted_expert_helpers(self):
        from engine.ai.challenge.choices import ExpertChoiceMixin
        from engine.ai.challenge.sequencing import ExpertSequencingMixin
        from engine.ai.challenge.tactics import ExpertTacticsMixin

        ai = ChallengeAI(AIConfig(policy_path=None))

        self.assertIsInstance(ai, ExpertTacticsMixin)
        self.assertIsInstance(ai, ExpertSequencingMixin)
        self.assertIsInstance(ai, ExpertChoiceMixin)
        self.assertTrue(callable(getattr(ai, "_expert_terminal_action_value", None)))
        self.assertTrue(callable(getattr(ai, "_expert_action_order_bonus", None)))
        self.assertTrue(callable(getattr(ai, "_expert_choice_card_value", None)))

    def test_deck_profiles_change_card_priorities(self):
        state = self._simple_public_state()
        pikachu = CardRegistry.get("svl-pikaex")
        greninja = CardRegistry.get("sv2-grex")
        lightning_ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        water_ai = create_challenge_ai("water", AIConfig(policy_path=None))

        self.assertGreater(
            lightning_ai._card_value(state, 1, pikachu),
            water_ai._card_value(state, 1, pikachu),
        )
        self.assertGreater(
            water_ai._card_value(state, 1, greninja),
            lightning_ai._card_value(state, 1, greninja),
        )

    def test_lightning_setup_keeps_pikachu_on_bench_when_pivot_available(self):
        state = GameState()
        state.phase = TurnPhase.SETUP
        state.p1.hand = [
            CardRegistry.get("svl-pikaex"),
            CardRegistry.get("svl-thun"),
            CardRegistry.get("svl-emol"),
        ]

        action = create_challenge_ai("lightning", AIConfig(policy_path=None))._choose_setup_action(state, 0)

        self.assertNotEqual(action.params.get("hand_idx"), 0)
        self.assertEqual(action.params.get("target"), "active")

    def test_fighting_setup_keeps_riolu_on_bench_when_pivot_available(self):
        state = GameState()
        state.phase = TurnPhase.SETUP
        state.p1.hand = [
            CardRegistry.get("svf-rio"),
            CardRegistry.get("svf-farf"),
            CardRegistry.get("svf-hawl"),
        ]

        action = create_challenge_ai("fighting", AIConfig(policy_path=None))._choose_setup_action(state, 0)

        self.assertNotEqual(action.params.get("hand_idx"), 0)
        self.assertEqual(action.params.get("target"), "active")

    def test_psychic_setup_keeps_natu_and_latios_on_bench_when_pivot_available(self):
        state = GameState()
        state.phase = TurnPhase.SETUP
        state.p1.hand = [
            CardRegistry.get("sv1-107"),
            CardRegistry.get("sv1-111"),
            CardRegistry.get("sv1-113"),
        ]

        action = create_challenge_ai("psychic", AIConfig(policy_path=None))._choose_setup_action(state, 0)

        self.assertEqual(action.params.get("hand_idx"), 2)
        self.assertEqual(action.params.get("target"), "active")

    def test_policy_file_failures_fall_back_to_profile_weights(self):
        policy_path = temp_file_path(prefix="policy", suffix=".json")
        with open(policy_path, "w", encoding="utf-8") as fh:
            fh.write("{bad json")
        try:
            ai = create_challenge_ai("fire", AIConfig(policy_path=policy_path))
            self.assertEqual(ai.profile.key, "fire")
            self.assertIn("core_in_play", ai.policy_weights)
        finally:
            best_effort_unlink(policy_path)

    def test_policy_loader_rejects_bad_eval_candidate(self):
        payload = {
            "version": 1,
            "policies": {
                "water": {
                    "weights": {"core_in_play": 120.0},
                    "eval": {
                        "games": 4,
                        "baseline": {"wins": 3, "losses": 1, "draws": 0, "avg_score": 500.0},
                        "trained": {"wins": 1, "losses": 3, "draws": 0, "avg_score": -500.0},
                    },
                },
                "fire": {
                    "weights": {"core_in_play": 111.0},
                    "eval": {
                        "games": 4,
                        "baseline": {"wins": 1, "losses": 3, "draws": 0, "avg_score": -500.0},
                        "trained": {"wins": 3, "losses": 1, "draws": 0, "avg_score": 500.0},
                    },
                },
            },
        }
        policy_path = temp_file_path(prefix="policy", suffix=".json")
        with open(policy_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        try:
            self.assertEqual(load_policy_weights("water", policy_path), {})
            self.assertEqual(load_policy_weights("fire", policy_path)["core_in_play"], 111.0)
        finally:
            best_effort_unlink(policy_path)

    def test_policy_loader_rejects_benchmark_regression(self):
        payload = {
            "version": 1,
            "policies": {
                "lightning": {
                    "weights": {"core_in_play": 120.0},
                    "eval": {
                        "games": 4,
                        "baseline": {"wins": 1, "losses": 3, "draws": 0, "avg_score": -500.0},
                        "trained": {"wins": 3, "losses": 1, "draws": 0, "avg_score": 500.0},
                    },
                    "metadata": {"accepted": True},
                },
            },
            "benchmark": {
                "before_after": {
                    "lightning": {
                        "games": 4,
                        "delta_win_rate": -0.25,
                        "delta_point_rate": -0.25,
                    },
                },
            },
        }
        policy_path = temp_file_path(prefix="policy", suffix=".json")
        with open(policy_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        try:
            self.assertEqual(load_policy_weights("lightning", policy_path), {})
        finally:
            best_effort_unlink(policy_path)

    def test_policy_loader_rejects_low_global_benchmark_without_gain(self):
        payload = {
            "version": 1,
            "policies": {
                "lightning": {
                    "weights": {"core_in_play": 120.0},
                    "eval": {
                        "games": 4,
                        "baseline": {"wins": 1, "losses": 3, "draws": 0, "avg_score": -500.0},
                        "trained": {"wins": 3, "losses": 1, "draws": 0, "avg_score": 500.0},
                    },
                    "metadata": {"accepted": True},
                },
            },
            "benchmark": {
                "before_after": {
                    "lightning": {
                        "games": 4,
                        "delta_win_rate": 0.0,
                        "delta_point_rate": 0.0,
                    },
                },
                "rankings": [
                    {
                        "deck": "lightning",
                        "games": 28,
                        "point_rate": 0.25,
                    },
                ],
            },
        }
        policy_path = temp_file_path(prefix="policy", suffix=".json")
        with open(policy_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        try:
            self.assertEqual(load_policy_weights("lightning", policy_path), {})
        finally:
            best_effort_unlink(policy_path)

    def test_benchmark_acceptance_guard_rejects_low_global_rate(self):
        policies = {
            "colorless": {
                "weights": {"core_in_play": 80.0},
                "metadata": {"accepted": True},
            },
        }
        benchmark = {
            "before_after": {
                "colorless": {
                    "games": 4,
                    "delta_win_rate": 0.0,
                    "delta_point_rate": 0.0,
                },
            },
            "rankings": [
                {
                    "deck": "colorless",
                    "games": 28,
                    "point_rate": 0.25,
                },
            ],
        }

        apply_benchmark_acceptance_guard(policies, benchmark)

        metadata = policies["colorless"]["metadata"]
        self.assertFalse(metadata["accepted"])
        self.assertEqual(metadata["rejection_reason"], "benchmark_low_global_rate")

    def test_hand_cost_selection_avoids_core_cards(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(CardRegistry.get("svf-rio"))
        lucario = CardRegistry.get("svf-luca")
        potion = CardRegistry.get("svf-potion")
        off_plan = CardRegistry.get("sv2-delib")
        state.p1.hand = [lucario, potion, off_plan]
        req = ActionRequest(
            request_type="search_deck",
            player=0,
            prompt="选择1张手牌放回牌库底部，然后抽到5张（凰檗）",
            min_select=1,
            max_select=1,
            from_zone="hand",
            card_list=list(state.p1.hand),
        )

        choice = create_challenge_ai("fighting", AIConfig(policy_path=None)).resolve_pending_action(state, req)

        self.assertEqual(len(choice.selected_cards), 1)
        self.assertNotEqual(choice.selected_cards[0].api_id, lucario.api_id)

    def test_energy_switch_moves_from_single_source_to_better_target(self):
        energy_switch = CardRegistry.get("svf-ensw2")
        energy = CardRegistry.get("sv1-ener-6")
        passimian = CardRegistry.get("svf-pass")
        lucario = CardRegistry.get("svf-luca")
        opponent = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.first_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(passimian)
        state.p1.active.energy_cards = [energy]
        state.p1.bench[0] = PokemonInPlay(lucario)
        state.p1.hand = [energy_switch]
        state.p1.deck = [energy] * 5
        state.p2.active = PokemonInPlay(opponent)
        state.p2.deck = [opponent] * 5
        state.p1.prizes = [opponent] * 6
        state.p2.prizes = [opponent] * 6

        ai = create_challenge_ai("fighting", AIConfig(policy_path=None))
        result = ai._apply_action_for_sim(
            state,
            0,
            AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}),
        )

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(len(state.p1.active.energy_cards), 0)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)

    def test_search_fallback_takes_available_ko_before_ending_turn(self):
        energy = CardRegistry.get("sv1-ener-6")
        passimian = CardRegistry.get("svf-pass")
        opponent = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.first_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(passimian)
        state.p1.active.energy_cards = [energy, energy]
        state.p2.active = PokemonInPlay(opponent)
        state.p2.active.damage_counters = 2
        state.p1.prizes = [opponent] * 6
        state.p2.prizes = [opponent] * 6
        ai = create_challenge_ai("fighting", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 0)

        selected = ai._validated_or_fallback_action(
            state,
            0,
            AIAction(PlayerAction.END_TURN, {}, terminal=True),
            actions,
        )

        self.assertEqual(selected.action, PlayerAction.DECLARE_ATTACK)
        self.assertEqual(selected.params.get("attack_idx"), 0)

    def test_search_fallback_uses_productive_draw_attack_before_ending_turn(self):
        energy = CardRegistry.get("svi-jete")
        indeedee = CardRegistry.get("svi-inde")
        opponent = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.first_player_idx = 1
        state.turn_number = 4
        state.p1.active = PokemonInPlay(indeedee)
        state.p1.active.energy_cards = [energy]
        state.p1.hand = []
        state.p1.deck = [opponent] * 6
        state.p2.active = PokemonInPlay(opponent)
        state.p1.prizes = [opponent] * 6
        state.p2.prizes = [opponent] * 6
        ai = create_challenge_ai("colorless", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 0)

        selected = ai._validated_or_fallback_action(
            state,
            0,
            AIAction(PlayerAction.END_TURN, {}, terminal=True),
            actions,
        )

        self.assertEqual(selected.action, PlayerAction.DECLARE_ATTACK)
        self.assertEqual(selected.params.get("attack_idx"), 0)

    def test_colorless_search_prioritizes_tandemaus_for_maushold_line(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-skwv"))
        state.p1.deck = [
            CardRegistry.get("svi-inde"),
            CardRegistry.get("svi-aipo"),
            CardRegistry.get("svi-tand"),
        ]
        req = ActionRequest(
            request_type="search_deck",
            player=0,
            prompt="search basic pokemon",
            min_select=1,
            max_select=1,
            card_list=list(state.p1.deck),
        )

        choice = create_challenge_ai("colorless", AIConfig(policy_path=None)).resolve_pending_action(state, req)

        self.assertEqual(choice.selected_cards[0].api_id, "svi-tand")

    def test_basic_energy_discard_attach_matches_any_basic_energy(self):
        energy = CardRegistry.get("sv1-ener-6")
        hawlucha = CardRegistry.get("svf-hawl")
        lucario = CardRegistry.get("svf-luca")
        opponent = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.first_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(hawlucha)
        state.p1.active.energy_cards = [energy]
        state.p1.bench[0] = PokemonInPlay(lucario)
        state.p1.discard = [energy, energy]
        state.p1.deck = [energy] * 5
        state.p2.active = PokemonInPlay(opponent)
        state.p2.deck = [opponent] * 5
        state.p1.prizes = [opponent] * 6
        state.p2.prizes = [opponent] * 6

        ai = create_challenge_ai("fighting", AIConfig(policy_path=None))
        result = ai._apply_action_for_sim(
            state,
            0,
            AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True),
        )

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 2)

    def test_training_script_small_run_writes_policy_json(self):
        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "ai_policies.json")
            result = subprocess.run(
                [
                    sys.executable,
                    "scripts/train_challenge_ai.py",
                    "--deck",
                    "fire",
                    "--games",
                    "1",
                    "--eval-games",
                    "0",
                    "--search-preset",
                    "beam",
                    "--output",
                    output,
                ],
                cwd=os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
                text=True,
                capture_output=True,
                timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(output, "r", encoding="utf-8") as fh:
                payload = json.load(fh)
            self.assertEqual(payload["version"], 1)
            self.assertIn("fire", payload["policies"])
            self.assertIn("weights", payload["policies"]["fire"])
            self.assertEqual(payload["policies"]["fire"]["training_games"], 1)

    def test_training_exact_game_budget_and_weight_clamps(self):
        calls = []

        def fake_play(deck_key, weights, opponent_key, seed, max_steps=160,
                      candidate_player_idx=0, search_preset="beam",
                      search_quality="standard"):
            calls.append((deck_key, opponent_key, seed, candidate_player_idx))
            winner = 0 if len(calls) % 3 else 1
            return winner, float(len(calls))

        with patch("engine.ai.training.play_game", side_effect=fake_play):
            result = train_deck("fire", 1, 123, workers=1, search_preset="beam")
            self.assertEqual(result["training_games"], 1)
            self.assertEqual(len(calls), 1)

            calls.clear()
            result = train_deck("fire", 200, 123, workers=1, search_preset="beam")
            self.assertEqual(result["training_games"], 200)
            self.assertEqual(len(calls), 200)

        self.assertEqual(clamp_weight("damaged_self", 12.0), 0.0)
        self.assertEqual(clamp_weight("damaged_self", -9.0), -1.5)
        self.assertEqual(clamp_weight("ko_pressure", 99.0), 3.0)
        self.assertEqual(clamp_weight("ko_pressure", -4.0), 0.1)

    def test_training_parallel_scheduling_preserves_task_order(self):
        seen = []

        def fake_runner(tasks, workers):
            rows = []
            for task in tasks:
                seen.append((workers, task.deck_key, task.opponent_key, task.seed, task.seat))
                winner = 0 if task.seed % 2 == 0 else 1
                rows.append((winner, float(task.seed % 100)))
            return rows

        with patch("engine.ai.training._run_play_game_tasks", side_effect=fake_runner):
            train_deck("fire", 12, 123, workers=1)
            single_worker_seen = list(seen)
            seen.clear()
            train_deck("fire", 12, 123, workers=4)
            multi_worker_seen = list(seen)

        self.assertEqual(
            [row[1:] for row in single_worker_seen],
            [row[1:] for row in multi_worker_seen],
        )
        self.assertTrue(all(row[0] == 1 for row in single_worker_seen))
        self.assertTrue(all(row[0] == 4 for row in multi_worker_seen))

    def test_parallel_game_tasks_fall_back_to_serial_on_broken_pool(self):
        class BrokenExecutor:
            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def map(self, func, tasks):
                raise BrokenProcessPool("worker terminated")

        tasks = [PlayGameTask("fire", None, "water", 17, 0)]
        with patch("engine.ai.training.ProcessPoolExecutor", BrokenExecutor), \
             patch("engine.ai.training._execute_play_game_task", return_value=(0, 12.0)) as execute:
            self.assertEqual(_run_play_game_tasks(tasks, workers=4), [(0, 12.0)])
        execute.assert_called_once_with(tasks[0])

    def test_training_play_game_is_seed_deterministic(self):
        first = play_game("fire", None, "water", 2025, max_steps=8, search_preset="beam")
        second = play_game("fire", None, "water", 2025, max_steps=8, search_preset="beam")
        self.assertEqual(first, second)

    def test_play_match_accepts_custom_weights(self):
        weights = {"core_in_play": 72.0, "ko_pressure": 1.1}
        result = play_match("fire", weights, "water", None, 2026, seat=1, max_steps=8, search_preset="beam")
        self.assertEqual(len(result), 2)
        self.assertIn(result[0], (0, 1, None))

    def test_training_progress_jsonl_and_candidate_policy_are_loadable(self):
        def fake_play(deck_key, weights, opponent_key, seed, max_steps=160,
                      candidate_player_idx=0, search_preset="beam",
                      search_quality="standard"):
            winner = 0 if seed % 2 == 0 else 1
            return winner, float(seed % 100)

        with temp_dir() as tmpdir:
            output = os.path.join(tmpdir, "candidate.json")
            progress = os.path.join(tmpdir, "progress.jsonl")
            config = TrainingConfig(
                deck="fire",
                games=3,
                seed=7,
                output=output,
                eval_games=0,
                progress_jsonl=progress,
                workers=1,
            )
            with patch("engine.ai.training.play_game", side_effect=fake_play):
                payload = run_training(config)

            self.assertEqual(payload["policies"]["fire"]["training_games"], 3)
            with open(progress, "r", encoding="utf-8") as fh:
                events = [json.loads(line) for line in fh if line.strip()]
            self.assertEqual(events[0]["type"], "run_started")
            self.assertEqual(events[-1]["type"], "run_finished")
            totals = [
                event["total_games_played"]
                for event in events
                if "total_games_played" in event
            ]
            self.assertEqual(totals, sorted(totals))

            loaded = load_policy_weights("fire", output)
            self.assertIn("core_in_play", loaded)
            self.assertIn("damaged_self", loaded)

    def test_training_eval_games_preserve_search_preset(self):
        for preset in ("beam", "hybrid", "minimax"):
            seen_presets = []

            def fake_runner(tasks, workers):
                seen_presets.extend(task.search_preset for task in tasks)
                return [(0, 1.0) for _ in tasks]

            with patch("engine.ai.training._run_play_game_tasks", side_effect=fake_runner):
                policy = train_deck(
                    "fire",
                    1,
                    123,
                    eval_games=1,
                    workers=1,
                    search_preset=preset,
                )

            self.assertTrue(seen_presets)
            self.assertTrue(all(value == preset for value in seen_presets))
            self.assertEqual(
                policy["metadata"]["search"].get("search_algorithm", "beam"),
                preset,
            )

    def test_evaluate_policy_uses_selected_search_preset(self):
        seen_batches = []

        def fake_runner(tasks, workers):
            seen_batches.append([task.search_preset for task in tasks])
            return [(None, 0.0) for _ in tasks]

        with patch("engine.ai.training._run_play_game_tasks", side_effect=fake_runner):
            evaluate_policy("fire", {}, {}, 17, 2, workers=1, search_preset="minimax")

        self.assertEqual(seen_batches, [["minimax", "minimax"], ["minimax", "minimax"]])

    def test_training_fast_hybrid_matches_debuggable_search_quality(self):
        ai = _make_ai("lightning", {}, 17, search_preset="hybrid", search_quality="fast")

        self.assertEqual(ai.config.deck_key, "lightning")
        self.assertEqual(ai.config.search_algorithm, "hybrid")
        self.assertEqual(ai.config.beam_width, 6)
        self.assertEqual(ai.config.max_turn_actions, 18)
        self.assertEqual(ai.config.max_sequence_depth, 8)
        self.assertEqual(ai.config.coin_sample_count, 8)
        self.assertEqual(ai.config.opponent_response_actions, 8)
        self.assertEqual(ai.config.response_branch_limit, 0)
        self.assertEqual(ai.config.opponent_response_weight, 0.55)
        self.assertEqual(ai.config.chance_branch_limit, 4)
        self.assertFalse(ai.config.skip_effect_dry_run)

    def test_benchmark_smoke_reports_strength_guard_metrics(self):
        from scripts.benchmark_ai import run_benchmark

        payload = run_benchmark(
            deck_keys=["fire"],
            games_per_matchup=1,
            seed=23,
            max_steps=30,
            search_preset="hybrid",
        )

        self.assertEqual(payload["games"], 1)
        self.assertIn("matchups", payload)
        self.assertIn("summary", payload)
        self.assertIn("invalid_action_rate", payload["summary"])
        self.assertIn("timeout_rate", payload["summary"])
        self.assertIn("average_score", payload["summary"])

    def test_benchmark_cli_initializes_card_registry(self):
        result = subprocess.run(
            [
                sys.executable,
                "scripts/benchmark_ai.py",
                "--deck",
                "fire",
                "--games",
                "1",
                "--max-steps",
                "30",
            ],
            cwd=os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
            capture_output=True,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["games"], 1)

    def test_beam_coin_branches_are_deterministic_and_weighted(self):
        ai = ChallengeAI(AIConfig(policy_path=None, chance_branch_limit=4))
        branches = ai._coin_outcome_branches(1, False)
        self.assertEqual(len(branches), 2)
        self.assertAlmostEqual(sum(weight for _results, weight in branches), 1.0)
        self.assertEqual({tuple(results) for results, _weight in branches}, {(False,), (True,)})

        state = self._simple_public_state()
        action = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        calls = []

        def fake_apply(sim, player_idx, action, coin_results):
            calls.append(tuple(coin_results))
            return ActionResult(True, "")

        with patch.object(ai, "_action_coin_profile", return_value=(1, False)), \
                patch.object(ai, "_apply_action_for_sim_with_coin_results", side_effect=fake_apply):
            outcomes = ai._simulate_action_outcomes(state, 1, action)

        self.assertEqual(len(outcomes), 2)
        self.assertAlmostEqual(sum(weight for _sim, _result, weight in outcomes), 1.0)
        self.assertEqual(set(calls), {(False,), (True,)})

    def test_minimax_chance_executes_each_coin_branch_once(self):
        from engine.ai.minimax import MinimaxSearcher

        state = self._simple_public_state()
        action = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        ai = ChallengeAI(AIConfig(policy_path=None, chance_branch_limit=2, search_node_budget=10))
        searcher = MinimaxSearcher(ai)
        searcher.max_turn_depth = 1
        searcher.node_budget = 10
        searcher.nodes_searched = 0
        calls = []

        def fake_apply(sim, player_idx, action, coin_results):
            calls.append(tuple(coin_results))
            sim.winner = player_idx if coin_results[0] else 1 - player_idx
            sim.phase = TurnPhase.GAME_OVER
            return ActionResult(True, "")

        with patch.object(ai, "_action_coin_branches", return_value=[([True], 0.5), ([False], 0.5)]), \
                patch.object(ai, "_apply_action_for_sim_with_coin_results", side_effect=fake_apply):
            value = searcher._chance_value(state, 1, 1, action, 0, 0, -float("inf"), float("inf"), float("inf"))

        self.assertEqual(calls, [(True,), (False,)])
        self.assertEqual(value, 0.0)

    def test_minimax_iterative_deepening_uses_deepest_complete_result(self):
        from engine.ai.minimax import MinimaxSearcher

        state = self._simple_public_state()
        shallow = AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": 0, "target": "bench_0"})
        deep = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        ai = ChallengeAI(AIConfig(policy_path=None, deterministic_search=True))
        searcher = MinimaxSearcher(ai)
        seen_node_counts = []

        def fake_depth(self, state, player_idx, root_actions, max_depth, deadline, determinizations):
            seen_node_counts.append(self.nodes_searched)
            self.nodes_searched = 99
            if max_depth == 1:
                return SimpleNamespace(action=shallow, score=1000.0, complete=True)
            return SimpleNamespace(action=deep, score=-100.0, complete=True)

        with patch.object(MinimaxSearcher, "_search_at_depth", new=fake_depth):
            result = searcher.search(
                state,
                1,
                float("inf"),
                max_depth=2,
                determinizations=1,
                root_actions=[shallow, deep],
            )

        self.assertIs(result, deep)
        self.assertEqual(seen_node_counts, [0, 0])

    def test_minimax_uses_partial_result_when_first_depth_is_incomplete(self):
        from engine.ai.minimax import MinimaxSearcher

        state = self._simple_public_state()
        partial = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "active"})
        end_turn = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        ai = ChallengeAI(AIConfig(policy_path=None, deterministic_search=True))

        def fake_depth(self, state, player_idx, root_actions, max_depth, deadline, determinizations):
            return SimpleNamespace(action=partial, score=10.0, complete=False)

        with patch.object(MinimaxSearcher, "_search_at_depth", new=fake_depth):
            result = MinimaxSearcher(ai).search(
                state,
                1,
                float("inf"),
                max_depth=2,
                determinizations=1,
                root_actions=[partial, end_turn],
            )

        self.assertIs(result, partial)

    def test_minimax_budget_exhaustion_falls_back_to_best_ordered_action(self):
        from engine.ai.minimax import MinimaxSearcher

        state = self._simple_public_state()
        attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "active"})
        end_turn = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        ai = ChallengeAI(AIConfig(policy_path=None))

        result = MinimaxSearcher(ai).search(
            state,
            1,
            time.perf_counter() - 1.0,
            max_depth=2,
            determinizations=1,
            root_actions=[attach, end_turn],
        )

        self.assertIs(result, attach)

    def test_minimax_min_node_orders_opponent_threats_first(self):
        from engine.ai.minimax import MinimaxSearcher

        state = self._simple_public_state()
        ai = ChallengeAI(AIConfig(policy_path=None))
        actions = [
            AIAction(PlayerAction.END_TURN, {}, terminal=True),
            AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True),
            AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": 0, "target": "bench_0"}),
        ]

        ordered = [action for _idx, action in MinimaxSearcher(ai)._order_actions_min(state, 1, actions)]

        self.assertEqual(ordered[0].action, PlayerAction.DECLARE_ATTACK)
        self.assertEqual(ordered[-1].action, PlayerAction.END_TURN)

    def test_minimax_rejects_failed_root_action(self):
        from engine.ai.minimax import MinimaxSearcher

        state = self._simple_public_state()
        bad = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 99})
        good = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        ai = ChallengeAI(AIConfig(policy_path=None, deterministic_search=True))

        def fake_apply(sim, player_idx, action):
            if action is bad:
                return ActionResult(False, "bad action")
            sim.winner = player_idx
            sim.phase = TurnPhase.GAME_OVER
            return ActionResult(True, "ok")

        with patch.object(ai, "_apply_action_for_sim", side_effect=fake_apply):
            result = MinimaxSearcher(ai).search(
                state,
                1,
                float("inf"),
                max_depth=1,
                determinizations=1,
                root_actions=[bad, good],
            )

        self.assertIs(result, good)

    def test_hybrid_choose_action_does_not_mutate_real_state(self):
        state = self._simple_public_state()
        before = snapshot_state(state)
        ai = ChallengeAI(AIConfig(
            policy_path=None,
            deterministic_search=True,
            search_algorithm="hybrid",
            beam_width=4,
            max_turn_actions=8,
            minimax_max_depth=2,
            minimax_determinizations=1,
            search_node_budget=30,
            skip_effect_dry_run=True,
        ))

        action = ai.choose_action(state, 1)

        self.assertIsInstance(action, AIAction)
        self.assertEqual(before, snapshot_state(state))

    def test_budgeted_hybrid_search_returns_quickly(self):
        state = self._simple_public_state()
        ai = ChallengeAI(AIConfig(
            policy_path=None,
            deterministic_search=True,
            search_algorithm="hybrid",
            beam_width=4,
            max_turn_actions=8,
            minimax_max_depth=2,
            minimax_determinizations=1,
            search_node_budget=20,
            skip_effect_dry_run=True,
        ))
        started = time.perf_counter()
        action = ai.choose_action(state, 1)
        elapsed = time.perf_counter() - started
        self.assertIsInstance(action, AIAction)
        self.assertLess(elapsed, 5.0)

    def test_training_task_runner_reuses_executor(self):
        class CountingExecutor:
            created = 0

            def __init__(self, *args, **kwargs):
                CountingExecutor.created += 1

            def map(self, func, tasks):
                return [func(task) for task in tasks]

            def shutdown(self, wait=True):
                pass

        tasks_a = [
            PlayGameTask("fire", None, "water", 17, 0),
            PlayGameTask("fire", None, "water", 18, 1),
        ]
        tasks_b = [
            PlayGameTask("water", None, "fire", 19, 0),
            PlayGameTask("water", None, "fire", 20, 1),
        ]

        with patch("engine.ai.training.ProcessPoolExecutor", CountingExecutor), \
                patch("engine.ai.training._execute_play_game_task",
                      side_effect=lambda task: (0, float(task.seed))):
            with TrainingTaskRunner(4) as runner:
                self.assertEqual(len(runner.run_play_game_tasks(tasks_a)), 2)
                self.assertEqual(len(runner.run_play_game_tasks(tasks_b)), 2)

        self.assertEqual(CountingExecutor.created, 1)

    def test_hybrid_search_prunes_root_actions_then_uses_minimax(self):
        from engine.ai.challenge_ai import AIAction, AIConfig, ChallengeAI
        from engine.enums import PlayerAction

        ai = ChallengeAI(AIConfig(beam_width=2, policy_path=None, deterministic_search=True))
        actions = [
            AIAction(PlayerAction.PLAY_BASIC, {"slot": "active"}),
            AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0}),
            AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}),
            AIAction(PlayerAction.END_TURN, {}, terminal=True),
        ]
        captured = {}

        def fake_search(self, state, player_idx, deadline, max_depth=3,
                        determinizations=3, root_actions=None):
            captured["root_actions"] = root_actions
            return root_actions[0]

        with patch.object(ai, "legal_actions", return_value=actions), \
                patch.object(ai, "_action_executes_successfully", return_value=True), \
                patch("engine.ai.minimax.MinimaxSearcher.search", new=fake_search):
            result = ai._hybrid_search_action(object(), 0, float("inf"))

        self.assertIs(result, actions[0])
        self.assertEqual(captured["root_actions"], [actions[0], actions[1], actions[3]])

    def test_benchmark_payload_contains_matrix_before_after_and_ranking(self):
        policies = {
            "fire": {"weights": {"core_in_play": 80.0}},
            "water": {"weights": {"core_in_play": 75.0}},
        }

        def fake_game_runner(tasks, workers):
            return [(0 if task.seed % 2 == 0 else 1, float(task.seed % 10)) for task in tasks]

        def fake_match_runner(tasks, workers):
            return [(0 if task.seed % 2 == 0 else 1, float(task.seed % 10)) for task in tasks]

        with patch("engine.ai.training._run_play_game_tasks", side_effect=fake_game_runner), \
             patch("engine.ai.training._run_play_match_tasks", side_effect=fake_match_runner):
            payload = benchmark_policies(policies, 17, 2, workers=4)

        self.assertEqual(payload["games_per_matchup"], 2)
        self.assertIn("fire", payload["before_after"])
        self.assertIn("fire", payload["matrix"])
        self.assertIn("water", payload["matrix"]["fire"])
        self.assertEqual([row["rank"] for row in payload["rankings"]], [1, 2])

    def test_core_rules_reject_main_phase_active_basic_and_same_stadium(self):
        state = self._simple_public_state()
        basic = CardRegistry.get("svi-chim")
        state.p2.active = None
        state.p2.hand = [basic]

        ok, reason = can_play_basic(state, 1, basic, "active")
        self.assertFalse(ok)
        self.assertIn("主要阶段", reason)
        result = TurnManager(state).perform_action(
            PlayerAction.PLAY_BASIC, player_idx=1, hand_idx=0, target="active",
        )
        self.assertFalse(result.success)

        same_in_play = Card(api_id="stadium-a", name="Same Stadium",
                            supertype="Trainer", subtypes=["Stadium"])
        same_in_hand = Card(api_id="stadium-b", name="Same Stadium",
                            supertype="Trainer", subtypes=["Stadium"])
        CardRegistry._cards[same_in_play.api_id] = same_in_play
        CardRegistry._cards[same_in_hand.api_id] = same_in_hand
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.stadium_card = same_in_play
        state.p2.hand = [same_in_hand]
        ok, reason = can_play_stadium(state, 1, same_in_hand)
        self.assertFalse(ok)
        self.assertIn("同名", reason)
        actions = ChallengeAI(AIConfig(max_turn_actions=20)).legal_actions(state, 1)
        self.assertFalse(any(
            action.action == PlayerAction.PLAY_TRAINER
            and action.params.get("hand_idx") == 0
            for action in actions
        ))

    def test_manual_ability_once_per_turn_and_reset(self):
        base = CardRegistry.get("sv2-delib")
        ability_mon = Card(
            api_id="test-ability-mon",
            name="Ability Mon",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=90,
            energy_types=["Colorless"],
            abilities=[AbilityDef("Focus", "Once during your turn.", trigger="")],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(ability_mon)
        state.p2.active = PokemonInPlay(base)

        self.assertTrue(can_use_ability(state, 0, "active", "Focus")[0])
        result = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY, player_idx=0, slot="active", ability_name="Focus",
        )
        self.assertTrue(result.success, result.log_message)
        self.assertIn("Focus", state.p1.active.used_abilities)
        self.assertFalse(can_use_ability(state, 0, "active", "Focus")[0])
        repeat = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY, player_idx=0, slot="active", ability_name="Focus",
        )
        self.assertFalse(repeat.success)

        state.p1.reset_turn_flags()
        self.assertTrue(can_use_ability(state, 0, "active", "Focus")[0])

    def test_bench_self_damage_ability_targets_source_pokemon(self):
        riolu = CardRegistry.get("svf-rio")
        lucario = CardRegistry.get("svf-luca")
        energy = CardRegistry.get("sv1-ener-6")
        base = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(riolu)
        state.p1.bench[0] = PokemonInPlay(lucario)
        state.p1.deck = [energy]
        state.p1.prizes = [base] * 6
        state.p2.active = PokemonInPlay(base)
        state.p2.prizes = [base] * 6

        result = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY,
            player_idx=0,
            slot="bench_0",
            ability_name="旺盛斗气",
        )

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(state.p1.active.damage_counters, 0)
        self.assertEqual(state.p1.bench[0].damage_counters, 2)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)

    def test_fairness_ignores_opponent_hidden_card_identities(self):
        base_state = self._simple_public_state()
        hidden_changed = ChallengeAI()._clone_state(base_state)
        replacement_a = CardRegistry.get("svi-ente")
        replacement_b = CardRegistry.get("sv1-ener-2")
        hidden_changed.p1.hand = [replacement_a, replacement_b, replacement_a]
        hidden_changed.p1.deck = [replacement_b, replacement_a, replacement_b] * 4

        config = AIConfig(
            thinking_time_seconds=0.05,
            beam_width=4,
            max_sequence_depth=2,
            max_turn_actions=8,
            random_seed=99,
            search_algorithm="beam",
        )
        action_a = ChallengeAI(config).choose_action(base_state, 1)
        action_b = ChallengeAI(config).choose_action(hidden_changed, 1)

        self.assertEqual(action_a.action, action_b.action)
        self.assertEqual(action_a.params, action_b.params)
        self.assertEqual(action_a.terminal, action_b.terminal)

    def test_fow_placeholders_survive_repeated_masking_and_clone(self):
        state = self._simple_public_state()
        special_energy = CardRegistry.get("svi-dte") or CardRegistry.get("svg2-lume")
        if special_energy is None:
            self.skipTest("No special energy card available")
        state.p1.hand = [special_energy]
        state.p1.deck = [special_energy] * 3

        ai = ChallengeAI(AIConfig(policy_path=None))
        first_masked = ai._masked_clone_for_eval(state, 1)
        second_masked = ai._masked_clone_for_eval(state, 1)

        self.assertTrue(second_masked.p1.hand[0].api_id.startswith("_fow_"))
        cloned_first = ai._clone_state(first_masked)
        self.assertTrue(cloned_first.p1.hand[0].api_id.startswith("_fow_"))

    def test_pending_choice_strategies_cover_common_requests(self):
        state = self._simple_public_state()
        ai = ChallengeAI(AIConfig(random_seed=3))
        player = state.p2
        player.bench[0] = PokemonInPlay(CardRegistry.get("sv2-staryu"))
        player.bench[1] = PokemonInPlay(CardRegistry.get("sv2-keldeo"))

        search_req = ActionRequest(
            "search_deck", 1, "search", min_select=1, max_select=2,
            card_list=list(player.deck),
        )
        self.assertEqual(len(ai.resolve_pending_action(state, search_req).selected_cards), 2)

        discard_req = ActionRequest(
            "select_hand_to_discard", 1, "discard", min_select=1, max_select=1,
            card_list=list(player.hand),
        )
        self.assertEqual(len(ai.resolve_pending_action(state, discard_req).selected_cards), 1)

        bench_req = ActionRequest(
            "select_bench", 1, "bench", bench_indices=[0, 1],
        )
        self.assertIn(ai.resolve_pending_action(state, bench_req).selected_bench_slot, [0, 1])

        target_req = ActionRequest(
            "select_bench_targets", 1, "targets", min_select=1, max_select=1,
            target_player="self", bench_indices=[0, 1],
        )
        self.assertEqual(len(ai.resolve_pending_action(state, target_req).selected_bench_targets), 1)

        coin_req = ActionRequest("coin_flip", 1, "coin", flip_count=3)
        self.assertEqual(len(ai.resolve_pending_action(state, coin_req).coin_results), 3)
        sim_choice = ai._resolve_pending_for_sim(state, ActionRequest("coin_flip", 1, "coin", flip_count=20))
        self.assertEqual(len(sim_choice.coin_results), 20)
        self.assertIn(True, sim_choice.coin_results)
        self.assertIn(False, sim_choice.coin_results)

        energy_req = ActionRequest(
            "distribute_energy", 1, "energy",
            card_list=[CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-3")],
            target_info=[
                {"slot": "active", "name": player.active.card.name, "bench_idx": -1},
                {"slot": "bench_0", "name": player.bench[0].card.name, "bench_idx": 0},
            ],
            max_per_target=2,
        )
        self.assertTrue(ai.resolve_pending_action(state, energy_req).assignments)

    def test_tactical_damage_estimation_covers_dynamic_effects(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-dynamic-attacker",
            name="Dynamic Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[
                AttackDef(
                    "Hand Burst",
                    [],
                    0,
                    "",
                    effects=[{"effect_type": "damage_per_hand_size", "params": {"per": 20}}],
                ),
                AttackDef(
                    "Energy Punish",
                    [],
                    0,
                    "",
                    effects=[{"effect_type": "damage_per_energy", "params": {"count_from": "opponent_active", "per_energy": 30}}],
                ),
            ],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(base)
        state.p2.active = PokemonInPlay(attacker)
        state.p2.hand = [base, base, base, base]
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-3")]

        ai = ChallengeAI(AIConfig(policy_path=None))
        self.assertEqual(ai._estimated_attack_damage(state, 1, 0), 80)
        self.assertEqual(ai._estimated_attack_damage(state, 1, 1), 60)

    def test_attach_priority_favors_active_attack_readiness(self):
        base = CardRegistry.get("sv2-delib")
        energy = CardRegistry.get("sv1-ener-6")
        attacker = Card(
            api_id="test-ready-attacker",
            name="Ready Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Fighting"],
            attacks=[AttackDef("Punch", ["Fighting"], 40, "")],
        )
        bench_attacker = Card(
            api_id="test-bench-attacker",
            name="Bench Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=130,
            energy_types=["Fighting"],
            attacks=[AttackDef("Bench Punch", ["Fighting"], 50, "")],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(base)
        state.p2.active = PokemonInPlay(attacker)
        state.p2.bench[0] = PokemonInPlay(bench_attacker)
        state.p2.hand = [energy]

        ai = ChallengeAI(AIConfig(policy_path=None))
        active_attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "active"})
        bench_attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "bench_0"})

        self.assertGreater(
            ai._quick_action_priority(state, 1, active_attach),
            ai._quick_action_priority(state, 1, bench_attach),
        )

    def test_lightning_core_attacker_gets_second_energy_over_small_ready_bench(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-4")]
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svl-mare2"))
        state.p2.hand = [CardRegistry.get("sv1-ener-4")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        active_attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "active"})
        bench_attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "bench_0"})

        self.assertGreater(
            ai._quick_action_priority(state, 1, active_attach),
            ai._quick_action_priority(state, 1, bench_attach),
        )

    def test_weak_attack_waits_for_obvious_core_energy_development(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-4")]
        state.p2.hand = [CardRegistry.get("sv1-ener-4")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        weak_attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "active"})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, weak_attack, [weak_attack, attach, end])

        self.assertEqual(selected.action, PlayerAction.ATTACH_ENERGY)
        self.assertEqual(selected.params["target_slot"], "active")

    def test_weak_attack_waits_for_productive_draw_trainer(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-5")]
        state.p2.hand = [CardRegistry.get("sv1-180")]
        state.p2.deck = [CardRegistry.get("sv1-ener-5")] * 5
        state.p1.deck = [CardRegistry.get("sv1-ener-5")] * 5
        state.p1.prizes = [CardRegistry.get("sv1-ener-5")] * 6
        state.p2.prizes = [CardRegistry.get("sv1-ener-5")] * 6

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        weak_attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        draw = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, weak_attack, [weak_attack, draw, end])

        self.assertEqual(selected.action, PlayerAction.PLAY_TRAINER)

    def test_attach_from_discard_ability_requires_matching_discard_energy(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-emol"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("svl-flaa2"))

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)
        self.assertFalse(
            any(action.action == PlayerAction.USE_ABILITY for action in actions)
        )

        state.p2.discard = [CardRegistry.get("sv1-ener-4")]
        actions = ai.legal_actions(state, 1)
        self.assertTrue(
            any(action.action == PlayerAction.USE_ABILITY for action in actions)
        )

    def test_discard_search_trainer_requires_matching_discard_resource(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"))
        state.p2.hand = [CardRegistry.get("sv1-171")]

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)
        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

        state.p2.discard = [CardRegistry.get("sv1-ener-5")]
        actions = ai.legal_actions(state, 1)
        self.assertTrue(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_catcher_requires_opponent_bench_target(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-emol"))
        state.p2.hand = [CardRegistry.get("sv2-catch")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)

        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))
        trace = ai.explain_legal_actions(state, 1)
        self.assertTrue(
            any(row.get("reason") == "effect_has_no_available_value" for row in trace["rejected"])
        )

    def test_catcher_with_opponent_bench_switches_on_forced_heads(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-emol"))
        state.p2.hand = [CardRegistry.get("sv2-catch")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)
        catcher = next(action for action in actions if action.action == PlayerAction.PLAY_TRAINER)
        sim = ai._clone_state(state)

        result = ai._apply_action_for_sim_with_coin_results(sim, 1, catcher, [True])

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(sim.p1.active.card.api_id, "sv2-delib")
        self.assertEqual(sim.p1.bench[0].card.api_id, "svg-dram")

    def test_pending_coin_branch_failure_propagates_to_simulation(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-emol"))
        state.p2.hand = [CardRegistry.get("sv2-catch")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        action = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0})
        sim = ai._clone_state(state)

        result = ai._apply_action_for_sim_with_coin_results(sim, 1, action, [True])

        self.assertFalse(result.success)
        self.assertIn("对手备战区没有宝可梦", result.log_message)

    def test_single_bench_energy_choice_prefers_core_attack_plan(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-emol"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("svl-flaa2"))

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        req = ActionRequest(
            "select_own_bench_energy",
            1,
            "attach to bench",
            bench_indices=[0, 1],
        )

        self.assertEqual(ai.resolve_pending_action(state, req).selected_bench_slot, 0)

    def test_psychic_bench_energy_choice_prefers_attacker_over_xatu_engine(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-108"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-111"))

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        req = ActionRequest(
            "select_own_bench_energy",
            1,
            "attach to bench",
            bench_indices=[0, 1],
        )

        self.assertEqual(ai.resolve_pending_action(state, req).selected_bench_slot, 1)

    def test_end_turn_fallback_uses_productive_ability(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-108"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-111"))
        state.p2.hand = [CardRegistry.get("sv1-ener-5")]
        state.p2.deck = [CardRegistry.get("sv1-180")] * 5

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        ability = AIAction(PlayerAction.USE_ABILITY, {"slot": "bench_0", "ability_name": "以太感知"})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, end, [ability, end])

        self.assertEqual(selected.action, PlayerAction.USE_ABILITY)

    def test_pending_effect_chain_resumes_after_xatu_energy_choice(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-108"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-111"))
        state.p2.hand = [CardRegistry.get("sv1-ener-5")]
        state.p2.deck = [CardRegistry.get("sv1-180"), CardRegistry.get("sv1-189")]

        result = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY,
            player_idx=1,
            slot="bench_0",
            ability_name="以太感知",
        )
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_action)

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        followup = ai.apply_choice(
            state,
            result.pending_action,
            AIChoice(selected_bench_slot=1),
        )

        self.assertIsInstance(followup, ActionResult)
        self.assertEqual(len(followup.cards_drawn), 2)
        self.assertEqual(len(state.p2.hand), 2)
        self.assertEqual(len(state.p2.bench[1].energy_cards), 1)

    def test_major_draw_waits_for_xatu_energy_ability(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-108"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-111"))
        state.p2.hand = [CardRegistry.get("sv1-ener-5"), CardRegistry.get("sv1-189")]
        state.p2.deck = [CardRegistry.get("sv1-180")] * 5

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        ability = AIAction(PlayerAction.USE_ABILITY, {"slot": "bench_0", "ability_name": "以太感知"})
        draw = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 1})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, draw, [draw, ability, end])

        self.assertEqual(selected.action, PlayerAction.USE_ABILITY)

    def test_major_draw_waits_for_manual_energy_attachment(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"))
        state.p2.hand = [CardRegistry.get("sv1-ener-5"), CardRegistry.get("sv1-189")]
        state.p2.deck = [CardRegistry.get("sv1-180")] * 5

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        attach = AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": 0, "target_slot": "active"})
        draw = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 1})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, draw, [draw, attach, end])

        self.assertEqual(selected.action, PlayerAction.ATTACH_ENERGY)

    def test_low_deck_filters_xatu_draw_ability(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 9
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-108"))
        state.p2.deck = [CardRegistry.get("sv1-180"), CardRegistry.get("sv1-189")]

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)

        self.assertFalse(any(action.action == PlayerAction.USE_ABILITY for action in actions))

    def test_low_deck_filters_large_draw_trainer(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 9
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.hand = [CardRegistry.get("sv1-180")]
        state.p2.deck = [CardRegistry.get("sv1-ener-5")] * 3

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)

        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_low_deck_filters_search_trainer(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 9
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.hand = [CardRegistry.get("svl-ensw")]
        state.p2.deck = [CardRegistry.get("sv1-ener-5")] * 5

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)

        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_low_deck_filters_arven_search_trainer(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 9
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.hand = [CardRegistry.get("sv1-204")]
        state.p2.deck = [
            CardRegistry.get("sv1-151"),
            CardRegistry.get("svl-vitb"),
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-5"),
        ]

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)

        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_arven_without_item_or_tool_targets_is_not_productive(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.hand = [CardRegistry.get("sv1-204")]
        state.p2.deck = [CardRegistry.get("sv1-ener-5")] * 12

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        actions = ai.legal_actions(state, 1)

        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_low_deck_avoids_draw_attack(self):
        base = CardRegistry.get("sv2-delib")
        draw_attacker = Card(
            api_id="test-low-deck-draw-attacker",
            name="Low Deck Draw Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Cycle", [], 0, "", effects=[{"effect_type": "draw", "params": {"amount": 2}}])],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 9
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(draw_attacker)
        state.p2.deck = [CardRegistry.get("sv1-ener-5")] * 2

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, attack, [attack, end])

        self.assertEqual(selected.action, PlayerAction.END_TURN)

    def test_weak_attack_does_not_feed_dangerous_outrage_retaliation(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-8")]
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-zera"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-4"), CardRegistry.get("sv1-ener-4")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, attack, [attack, end])

        self.assertEqual(selected.action, PlayerAction.END_TURN)

        selected = ai._validated_or_fallback_action(state, 1, end, [attack, end])

        self.assertEqual(selected.action, PlayerAction.END_TURN)

    def test_outrage_dynamic_damage_does_not_double_count_base_damage(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-8")]
        state.p1.active.damage_counters = 3
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))

        result = TurnManager(state).perform_action(PlayerAction.DECLARE_ATTACK, player_idx=0, attack_idx=0)

        self.assertTrue(result.success)
        self.assertEqual(result.damage_dealt, 90)
        self.assertEqual(state.p2.active.current_hp, 100)

    def test_cresselia_field_energy_bonus_is_estimated_for_attack_and_promotion(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        psychic_energy = CardRegistry.get("sv1-ener-5")
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-keldeo"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-107"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p2.bench[0].energy_cards = [psychic_energy, psychic_energy]
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-108"))
        state.p2.bench[1].energy_cards = [psychic_energy, psychic_energy, psychic_energy]

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        original_active = state.p2.active
        state.p2.active = state.p2.bench[0]
        try:
            damage = ai._estimated_attack_damage(state, 1, 1)
        finally:
            state.p2.active = original_active

        self.assertEqual(damage, 120)
        self.assertGreater(
            ai._promotion_value_for_state(state, 1, state.p2.bench[0]),
            ai._promotion_value_for_state(state, 1, state.p2.bench[1]),
        )

    def test_houndstone_estimate_counts_discarded_psychic_pokemon_not_energy(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-keldeo"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-5"), CardRegistry.get("sv1-ener-5")]
        state.p2.discard = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-107"),
            CardRegistry.get("sv1-109"),
        ]

        damage = create_challenge_ai("psychic", AIConfig(policy_path=None))._estimated_attack_damage(state, 1, 0)

        self.assertEqual(damage, 100)

    def test_forced_promotion_preserves_unready_core_attacker_under_ko_pressure(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-grex"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-3")]
        state.p2.active = None
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p2.bench[0].energy_cards = [CardRegistry.get("sv1-ener-5")]
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-107"))
        state.pending_promotion_player = 1

        create_challenge_ai("psychic", AIConfig(policy_path=None))._auto_promote_for_sim(state)

        self.assertEqual(state.p2.active.card.api_id, "sv1-107")
        self.assertIsNotNone(state.p2.bench[0])
        self.assertEqual(state.p2.bench[0].card.api_id, "sv1-113")

    def test_pikachu_punch_does_not_charge_drampa_outrage(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-8")]
        state.p1.active.damage_counters = 1
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-4")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, attack, [attack, end])

        self.assertEqual(selected.action, PlayerAction.END_TURN)

    def test_weak_attack_respects_next_turn_outrage_attachment(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-8")]
        state.p1.hand = [CardRegistry.get("sv1-ener-3")]
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-4"), CardRegistry.get("sv1-ener-4")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        attack = AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True)
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, attack, [attack, end])

        self.assertEqual(selected.action, PlayerAction.END_TURN)

    def test_retreat_waits_for_energy_acceleration_item(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.bench[0].energy_cards = [CardRegistry.get("sv1-ener-4")]
        state.p2.hand = [CardRegistry.get("sv1-170")]
        state.p2.deck = [CardRegistry.get("sv1-151")] * 5 + [CardRegistry.get("sv1-ener-4")] * 5

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        retreat = AIAction(PlayerAction.RETREAT, {"bench_idx": 0})
        generator = AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)

        selected = ai._validated_or_fallback_action(state, 1, retreat, [retreat, generator, end])

        self.assertEqual(selected.action, PlayerAction.PLAY_TRAINER)

    def test_retreat_avoids_promoting_target_that_current_attacker_can_ko(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-8")]
        state.p1.active.damage_counters = 6
        state.p2.active = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svl-zera"))
        state.p2.bench[0].energy_cards = [CardRegistry.get("sv1-ener-4")]

        ai = create_challenge_ai("lightning", AIConfig(policy_path=None))
        retreat = AIAction(PlayerAction.RETREAT, {"bench_idx": 0})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        actions = ai._filter_strategically_relevant_actions(state, 1, [retreat, end])

        self.assertFalse(any(action.action == PlayerAction.RETREAT for action in actions))

    def test_retreat_keeps_healthy_attacker_over_weak_engine_pivot(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 5
        state.p1.active = PokemonInPlay(CardRegistry.get("svf-hawl"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-110"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-5")]
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-107"))
        state.p2.bench[0].energy_cards = [CardRegistry.get("sv1-ener-5")]

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        retreat = AIAction(PlayerAction.RETREAT, {"bench_idx": 0})
        end = AIAction(PlayerAction.END_TURN, {}, terminal=True)
        actions = ai._filter_strategically_relevant_actions(state, 1, [retreat, end])

        self.assertFalse(any(action.action == PlayerAction.RETREAT for action in actions))

    def test_switch_confirmation_keeps_unready_engine_on_bench(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 1
        state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-107"))
        state.p2.hand = [CardRegistry.get("sv1-150")]

        ai = create_challenge_ai("psychic", AIConfig(policy_path=None))
        req = ActionRequest("confirm", 1, "switch active with bench")

        self.assertFalse(ai._confirm_pending(state, 1, req))
        actions = ai.legal_actions(state, 1)
        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_final_ko_attack_preserves_game_over_phase(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-final-ko-attacker",
            name="Final KO Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Finish", [], 120, "")],
        )
        defender = Card(
            api_id="test-final-ko-defender",
            name="Final KO Defender",
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

        result = TurnManager(state).declare_attack(1, 0)

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(state.winner, 1)
        self.assertEqual(state.phase, TurnPhase.GAME_OVER)
        self.assertFalse(state.p1.has_any_pokemon_in_play())

    def test_self_discard_ability_requires_active_promotion(self):
        starmie = CardRegistry.get("sv2-starm")
        base = CardRegistry.get("sv2-delib")
        benched = CardRegistry.get("svi-chim")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 3
        state.p1.active = PokemonInPlay(starmie)
        state.p1.bench[0] = PokemonInPlay(benched)
        state.p2.active = PokemonInPlay(base)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        result = TurnManager(state).perform_action(
            PlayerAction.USE_ABILITY,
            player_idx=0,
            slot="active",
            ability_name="神秘彗星",
        )

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(state.p2.active.damage_counters, 2)
        self.assertIsNone(state.p1.active)
        self.assertEqual(state.pending_promotion_player, 0)

        ChallengeAI(AIConfig(policy_path=None))._auto_promote_for_sim(state)

        self.assertIsNotNone(state.p1.active)
        self.assertEqual(state.p1.active.card.api_id, benched.api_id)
        self.assertEqual(state.pending_promotion_player, -1)

    def test_auto_promotion_prefers_ready_dynamic_attacker(self):
        lucario = CardRegistry.get("svf-luca")
        kleavor = CardRegistry.get("svf-klea")
        energy = CardRegistry.get("sv1-ener-6")
        base = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.DRAW
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.turn_number = 5
        state.pending_promotion_player = 0
        state.p1.bench[0] = PokemonInPlay(kleavor)
        state.p1.bench[1] = PokemonInPlay(lucario)
        state.p1.bench[1].energy_cards = [energy, energy, energy]
        state.p2.active = PokemonInPlay(base)

        ChallengeAI(AIConfig(deck_key="fighting", policy_path=None))._auto_promote_for_sim(state)

        self.assertIsNotNone(state.p1.active)
        self.assertEqual(state.p1.active.card.api_id, lucario.api_id)
        self.assertEqual(state.pending_promotion_player, -1)

    def test_attack_simulation_includes_forced_end_turn(self):
        base = CardRegistry.get("sv2-delib")
        attacker = Card(
            api_id="test-ai-attacker",
            name="AI Attacker",
            supertype=base.supertype,
            subtypes=["Basic"],
            hp=100,
            energy_types=["Colorless"],
            attacks=[AttackDef("Tap", [], 10, "")],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 3
        state.p1.active = PokemonInPlay(base)
        state.p2.active = PokemonInPlay(attacker)
        state.p1.deck = [base]
        state.p2.deck = [base]
        state.p1.prizes = [base] * 6
        state.p2.prizes = [base] * 6

        ai = ChallengeAI(AIConfig(max_sequence_depth=1, beam_width=2))
        result = ai._apply_action_for_sim(
            state, 1, AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, terminal=True),
        )
        self.assertTrue(result.success, result.log_message)
        self.assertEqual(state.active_player_idx, 0)
        self.assertEqual(state.phase, TurnPhase.MAIN)


if __name__ == "__main__":
    unittest.main()

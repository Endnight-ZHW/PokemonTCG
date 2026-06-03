"""Challenge AI unit tests."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures.process import BrokenProcessPool
from unittest.mock import patch

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data.card_models import AbilityDef, AttackDef, Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, FIRE_DECK, WATER_DECK, expand_deck
from engine.ai import AIAction, AIConfig, ChallengeAI, create_challenge_ai, DECK_AI_PROFILES
from engine.ai.profiles import load_policy_weights
from engine.ai.training import (
    PlayGameTask,
    TrainingConfig,
    _run_play_game_tasks,
    benchmark_policies,
    clamp_weight,
    evaluate_policy,
    play_game,
    play_match,
    run_training,
    train_deck,
)
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, GameState
from engine.player_state import PokemonInPlay
from engine.rules_validator import can_play_basic, can_play_stadium, can_use_ability
from engine.turn_manager import TurnManager


class ChallengeAITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS, use_api=False)

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

    def test_policy_file_failures_fall_back_to_profile_weights(self):
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as fh:
            fh.write("{bad json")
            policy_path = fh.name
        try:
            ai = create_challenge_ai("fire", AIConfig(policy_path=policy_path))
            self.assertEqual(ai.profile.key, "fire")
            self.assertIn("core_in_play", ai.policy_weights)
        finally:
            os.unlink(policy_path)

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
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as fh:
            json.dump(payload, fh)
            policy_path = fh.name
        try:
            self.assertEqual(load_policy_weights("water", policy_path), {})
            self.assertEqual(load_policy_weights("fire", policy_path)["core_in_play"], 111.0)
        finally:
            os.unlink(policy_path)

    def test_training_script_small_run_writes_policy_json(self):
        with tempfile.TemporaryDirectory() as tmpdir:
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
                      candidate_player_idx=0, search_preset="beam"):
            calls.append((deck_key, opponent_key, seed, candidate_player_idx))
            winner = 0 if len(calls) % 3 else 1
            return winner, float(len(calls))

        with patch("engine.ai.training.play_game", side_effect=fake_play):
            result = train_deck("fire", 1, 123, workers=1)
            self.assertEqual(result["training_games"], 1)
            self.assertEqual(len(calls), 1)

            calls.clear()
            result = train_deck("fire", 200, 123, workers=1)
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
                      candidate_player_idx=0, search_preset="beam"):
            winner = 0 if seed % 2 == 0 else 1
            return winner, float(seed % 100)

        with tempfile.TemporaryDirectory() as tmpdir:
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

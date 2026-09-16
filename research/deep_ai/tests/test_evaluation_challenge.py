from __future__ import annotations
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch
from deep_ai.challenge_arena import (ArenaAgentSpec, NativeChallengeArena, load_product_payloads,
    validate_agent_identity, validate_equal_search_contract, with_preset_contract)
from deep_ai.evaluation import evaluate
from deep_ai.evaluation_challenge import ChallengeEvaluationBackend
from deep_ai.evaluation_protocol import GameEvidence
from tests.test_evaluation import protocol
try:
    import ptcg_ai_core
except ImportError:
    ptcg_ai_core = None


class ChallengeContractTests(unittest.TestCase):
    def test_unfrozen_agent_tracks_the_product_engine(self):
        from deep_ai.challenge_arena import load_agent_spec, product_engine_id
        self.assertEqual(load_agent_spec("current-test").evaluation_options["engine"], product_engine_id())

    def test_fixed_search_contract_must_match(self) -> None:
        strategies = {"schema": "test"}
        candidate = ArenaAgentSpec(
            "candidate", "a", strategies, {"belief_samples": 1}
        )
        baseline = ArenaAgentSpec(
            "baseline", "b", strategies, {"belief_samples": 3}
        )
        with self.assertRaisesRegex(ValueError, "search_contract_mismatch"):
            validate_equal_search_contract(candidate, baseline)

    def test_engine_ab_keeps_equal_work_budget(self) -> None:
        strategies = {"schema": "test"}
        candidate = ArenaAgentSpec(
            "candidate", "a", strategies,
            {"engine": "strategic_intent_v3", "node_budget": 192,
             "belief_samples": 3},
        )
        baseline = ArenaAgentSpec(
            "baseline", "b", strategies,
            {"engine": "turn_beam_v2", "node_budget": 192,
             "belief_samples": 3},
        )
        validate_equal_search_contract(candidate, baseline)

    def test_deck_inspection_ab_keeps_equal_work_budget(self) -> None:
        strategies = {"schema": "test"}
        candidate = ArenaAgentSpec(
            "candidate", "a", strategies,
            {"engine": "turn_beam_v2", "node_budget": 192,
             "belief_samples": 3, "use_deck_inspection": True},
        )
        baseline = ArenaAgentSpec(
            "baseline", "b", strategies,
            {"engine": "turn_beam_v2", "node_budget": 192,
             "belief_samples": 3, "use_deck_inspection": False},
        )
        validate_equal_search_contract(candidate, baseline)

    def test_strategy_optimization_ab_keeps_equal_work_budget(self) -> None:
        strategies = {"schema": "test"}
        candidate = ArenaAgentSpec(
            "candidate", "a", strategies,
            {"engine": "strategic_intent_v3", "node_budget": 192,
             "belief_samples": 3, "use_deck_inspection": True,
             "use_strategy_optimization": True},
        )
        baseline = ArenaAgentSpec(
            "baseline", "b", strategies,
            {"engine": "strategic_intent_v3", "node_budget": 192,
             "belief_samples": 3, "use_deck_inspection": True,
             "use_strategy_optimization": False},
        )
        validate_equal_search_contract(candidate, baseline)

    def test_watchdog_must_be_equal_but_is_not_a_search_budget(self) -> None:
        strategies = {"schema": "test"}
        candidate = ArenaAgentSpec(
            "candidate", "a", strategies, {},
            decision_timeout_milliseconds=1000,
        )
        baseline = ArenaAgentSpec(
            "baseline", "b", strategies, {},
            decision_timeout_milliseconds=2000,
        )
        with self.assertRaisesRegex(ValueError, "watchdog_mismatch"):
            validate_equal_search_contract(candidate, baseline)

    def test_identical_agents_require_explicit_self_play(self) -> None:
        strategies = {"schema": "test"}
        first = ArenaAgentSpec(
            "first", "a", strategies, {"belief_samples": 1},
            implementation_hash="same",
        )
        second = ArenaAgentSpec(
            "second", "b", strategies, {"belief_samples": 1},
            implementation_hash="same",
        )
        with self.assertRaisesRegex(ValueError, "arena_agents_are_identical"):
            validate_agent_identity(first, second, allow_self_play=False)
        validate_agent_identity(first, second, allow_self_play=True)


    def test_evaluation_rejects_wall_clock_search_and_inner_concurrency(self):
        a = ArenaAgentSpec("candidate", "a", {"schema": "test"})
        for options in ({"time_budget_ms": 1}, {"search_worker_mode": "gameplay"}):
            with self.assertRaisesRegex(ValueError, "evaluation_requires_"):
                validate_equal_search_contract(a, replace(a, evaluation_options=options))


@unittest.skipUnless(ptcg_ai_core is not None, "native research binding is not built")
class ChallengeExecutionTests(unittest.TestCase):
    def test_resume_preserves_completed_evidence(self):
        catalog, decks, strategies = load_product_payloads()
        agent = with_preset_contract(ArenaAgentSpec("self", "test", strategies), "smoke")
        p = protocol(decks=("fire",), max_decisions=1024)
        def backend():
            return ChallengeEvaluationBackend(agents=dict.fromkeys(("candidate", "champion", "anchor"), agent),
                catalog=catalog, decks=decks, workers=1)
        original = NativeChallengeArena.run
        def interrupt(arena, tasks, *, on_games):
            original(arena, tasks[:1], on_games=on_games)
            raise InterruptedError("interrupted")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(NativeChallengeArena, "run", interrupt):
                with self.assertRaises(InterruptedError):
                    evaluate(p, backend(), output=output)
            shard = next((output / "shards").glob("*.jsonl"))
            before = shard.read_bytes()
            report = evaluate(p, backend(), output=output)
            self.assertEqual(report.summary["gate_status"], "pass")
            self.assertEqual(len(report.games), 4)
            self.assertEqual(shard.read_bytes(), before)
            self.assertEqual(report.summary["performance_advisory"]["played_games"], 3)


    def test_one_worker_and_many_workers_have_identical_semantics(self) -> None:
        catalog, decks, strategies = load_product_payloads()
        agent = with_preset_contract(ArenaAgentSpec(
            "self",
            "determinism-test",
            strategies,
            {
                "engine": "deck_planner_v1",
                "node_budget": 32,
                "belief_samples": 1,
            },
        ), "smoke")
        tasks = protocol(max_decisions=32).tasks("ac", 0)

        def run(workers: int) -> list[dict]:
            arena = NativeChallengeArena(
                catalog,
                decks,
                agent,
                agent,
                workers=workers,
                capture_failure_trace=False,
                trace_all=True,
            )
            with arena:
                return arena.run(tasks)["games"]

        serial = run(1)
        parallel = run(4)
        self.assertEqual(
            [(row["task_id"], row["semantic_result_hash"]) for row in serial],
            [(row["task_id"], row["semantic_result_hash"]) for row in parallel],
        )
        self.assertEqual(
            sum(
                int(row[key])
                for row in serial
                for key in (
                    "invalid_actions",
                    "illegal_choices",
                    "controller_failures",
                    "rule_exceptions",
                )
            ),
            0,
        )
        public_states = [
            (int(trace["actor"]), trace["public_state"])
            for game in serial
            for trace in game["decision_trace"]
        ]
        self.assertTrue(public_states)
        for actor, state in public_states:
            self.assertNotIn("your", state)
            self.assertNotIn("opponent", state)
            for private in (
                "resolution_stack",
                "processed_action_ids",
                "choice_sequence",
                "setup_bonus_card_ids",
            ):
                self.assertNotIn(private, state)
            for player in state["players"]:
                self.assertTrue(all(
                    card == "__hidden_card__" for card in player["deck"]
                ))
                self.assertTrue(all(
                    card == "__hidden_prize__" for card in player["prizes"]
                ))
            self.assertTrue(all(
                card == "__hidden_card__"
                for card in state["players"][1 - actor]["hand"]
            ))
        renamed_candidate = ArenaAgentSpec(
            "candidate-label-only",
            "candidate-build-label-only",
            strategies,
            agent.evaluation_options,
        )
        renamed_baseline = ArenaAgentSpec(
            "baseline-label-only",
            "baseline-build-label-only",
            strategies,
            agent.evaluation_options,
        )
        with NativeChallengeArena(
            catalog,
            decks,
            renamed_candidate,
            renamed_baseline,
            workers=4,
            capture_failure_trace=False,
        ) as arena:
            renamed = arena.run(tasks)["games"]
        self.assertEqual(
            [row["semantic_result_hash"] for row in serial],
            [row["semantic_result_hash"] for row in renamed],
        )
        self.assertNotEqual(
            [row["full_result_hash"] for row in serial],
            [row["full_result_hash"] for row in renamed],
        )
        self.assertTrue(all(
            row["candidate_agent_id"] == "candidate-label-only"
            and row["baseline_agent_id"] == "baseline-label-only"
            for row in renamed
        ))


    def test_both_agent_configuration_failures_are_infrastructure(self) -> None:
        catalog, decks, strategies = load_product_payloads()
        invalid = {
            "agent_id": "invalid",
            "build_id": "invalid",
            "backend": "in_process",
            "implementation_hash": "invalid",
            "strategies": {
                "schema": "ptcg.ai_strategy_catalog/1",
                "strategies": {},
            },
            "evaluation_options": {},
        }
        pool = ptcg_ai_core.NativeChallengeArenaPool(
            catalog,
            decks,
            invalid,
            invalid,
            {"concurrent_games": 1},
        )
        pool.start([{
            "task_id": "both-invalid",
            "candidate_deck": "fire",
            "baseline_deck": "water",
            "game_seed": 17,
            "candidate_seat": 0,
            "first_player": 0,
            "max_decisions": 1,
        }])
        pool.wait()
        game = pool.drain_games()[0]
        self.assertEqual(game["failure_kind"], "both_agents_configuration_failed")
        self.assertFalse(game["strength_eligible"])
        self.assertEqual(game["offending_agent"], -1)

        valid = ArenaAgentSpec(
            "valid", "valid", strategies, {}, implementation_hash="valid"
        ).native_payload()
        one_sided = ptcg_ai_core.NativeChallengeArenaPool(
            catalog,
            decks,
            invalid,
            valid,
            {"concurrent_games": 1},
        )
        one_sided.start([{
            "task_id": "candidate-invalid",
            "candidate_deck": "fire",
            "baseline_deck": "water",
            "game_seed": 17,
            "candidate_seat": 0,
            "first_player": 0,
            "max_decisions": 1,
        }])
        one_sided.wait()
        candidate_failure = one_sided.drain_games()[0]
        self.assertEqual(candidate_failure["failure_kind"], "candidate_configuration")
        self.assertEqual(candidate_failure["offending_agent"], 0)
        self.assertIsNone(candidate_failure["candidate_score_x2"])
        self.assertFalse(candidate_failure["terminal"])
        self.assertEqual(candidate_failure["winner_seat"], -1)
        p = protocol(max_decisions=1)
        task = p.tasks("ac", 0)[0]
        checked = GameEvidence.from_result(p, task, {**candidate_failure, **task.to_dict()}).row
        self.assertFalse(checked["strength_eligible"])
        self.assertIsNone(checked["candidate_score_x2"])


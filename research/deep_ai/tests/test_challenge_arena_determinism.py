from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
NATIVE_ROOT = RESEARCH_ROOT / "build" / "native"
if str(NATIVE_ROOT) not in sys.path:
    sys.path.insert(0, str(NATIVE_ROOT))
try:
    import ptcg_ai_core  # noqa: F401
except ImportError:
    ptcg_ai_core = None

from deep_ai.challenge_arena import (  # noqa: E402
    ArenaAgentSpec,
    aggregate_native_metrics,
    NativeChallengeArena,
    generate_tasks,
    load_product_payloads,
    run_arena,
    with_preset_contract,
)


@unittest.skipUnless(ptcg_ai_core is not None, "native research binding is not built")
class ChallengeArenaDeterminismTests(unittest.TestCase):
    def test_resume_finishes_a_partially_written_seat_block(self):
        _, _, strategies = load_product_payloads()
        agent = ArenaAgentSpec("resume", "resume", strategies,
            {"engine": "turn_beam_v2", "node_budget": 32, "belief_samples": 1,
             "internal_evaluation_smoke": True})
        original_run = NativeChallengeArena.run
        completed = []

        def interrupt_after_first_game(arena, tasks, *, on_games=None, **kwargs):
            result = original_run(arena, tasks[:1], on_games=on_games,
                                  require_complete_matrix=False)
            completed.extend(result["games"])
            raise InterruptedError("simulated_process_interruption")

        with tempfile.TemporaryDirectory() as directory:
            arguments = dict(preset="focused", candidate=agent, baseline=agent,
                workers=1, output=Path(directory), seed=123, replicates=1,
                max_decisions=1, candidate_decks=("fire",), baseline_decks=("water",),
                allow_self_play=True, comparison_mode="same-binary-strategy",
                bootstrap_samples=50)
            with patch.object(NativeChallengeArena, "run", interrupt_after_first_game):
                with self.assertRaisesRegex(InterruptedError, "simulated_process_interruption"):
                    run_arena(**arguments)
            self.assertEqual(len(completed), 1)
            shard = next((Path(directory) / "shards").glob("*.jsonl"))
            durable_bytes = shard.read_bytes()
            durable_game = json.loads(durable_bytes)
            resumed_tasks = []

            def record_resume(arena, tasks, **kwargs):
                resumed_tasks.extend(tasks)
                return original_run(arena, tasks, **kwargs)

            with patch.object(NativeChallengeArena, "run", record_resume):
                result = run_arena(**arguments)
            self.assertEqual(len(resumed_tasks), 3)
            self.assertNotIn(completed[0]["task_id"], {t.task_id for t in resumed_tasks})
            self.assertEqual(len(result["games"]), 4)
            restored = next(g for g in result["games"] if g["task_id"] == completed[0]["task_id"])
            self.assertEqual(shard.read_bytes(), durable_bytes)
            self.assertEqual(restored, durable_game)

    def test_wall_clock_and_gameplay_workers_reach_the_controller(self):
        catalog, decks, strategies = load_product_payloads()
        for smoke in (False, True):
            with self.subTest(smoke=smoke):
                agent = ArenaAgentSpec("timed", "timed-contract", strategies,
                    {"engine": "strategic_intent_v3", "node_budget": 192, "belief_samples": 3,
                     "time_budget_ms": 1, "search_worker_mode": "gameplay", "internal_evaluation_smoke": smoke})
                tasks = generate_tasks("focused", candidate_decks=("fire",), baseline_decks=("water",), max_decisions=12)
                result = NativeChallengeArena(catalog, decks, agent, agent, workers=1, trace_all=True).run(tasks)
                traces = [trace for game in result["games"] for trace in game["decision_trace"]]
                self.assertTrue(traces)
                self.assertTrue(all(trace["time_budget_ms"] == 1 for trace in traces))
                expected = 1 if smoke else ptcg_ai_core.ChallengeController().get_contract()["search_worker_count"]
                actions = [trace for trace in traces if trace["kind"] == "action"]
                self.assertTrue(actions)
                self.assertTrue(all(trace["controller_result"]["native_performance_counters"]["search_worker_count"] == expected
                                    for trace in actions))
                self.assertTrue(all(game["controller_failures"] == 0 and game["invalid_actions"] == 0
                                    and game["illegal_choices"] == 0 for game in result["games"]))
                metrics = aggregate_native_metrics(result["games"], agent, agent)
                self.assertFalse(metrics["deterministic"])
                self.assertEqual(metrics["inner_search_workers"], expected)

    def test_one_worker_and_many_workers_have_identical_semantics(self) -> None:
        catalog, decks, strategies = load_product_payloads()
        agent = with_preset_contract(ArenaAgentSpec(
            "self",
            "determinism-test",
            strategies,
            {
                "engine": "turn_beam_v2",
                "node_budget": 32,
                "belief_samples": 1,
            },
        ), "smoke")
        tasks = generate_tasks(
            "focused",
            candidate_decks=("fire",),
            baseline_decks=("water",),
            max_decisions=64,
        )

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
        renamed = NativeChallengeArena(
            catalog,
            decks,
            renamed_candidate,
            renamed_baseline,
            workers=4,
            capture_failure_trace=False,
        ).run(tasks)["games"]
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
        self.assertEqual(candidate_failure["candidate_score_x2"], 0)
        self.assertTrue(candidate_failure["strength_eligible"])


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import sys
import unittest
from pathlib import Path


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
    NativeChallengeArena,
    generate_tasks,
    load_product_payloads,
    with_preset_contract,
)


@unittest.skipUnless(ptcg_ai_core is not None, "native research binding is not built")
class ChallengeArenaDeterminismTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()

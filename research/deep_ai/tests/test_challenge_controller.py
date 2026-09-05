"""Full native controller regressions; no heuristic or rules mocks."""
from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

RESEARCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RESEARCH_ROOT / "build" / "native"))
try:
    import ptcg_ai_core as native
except ImportError:
    native = None

from deep_ai.challenge_arena import load_product_payloads
from engine.game_engine import _flatten_native_rows


@unittest.skipUnless(native is not None, "native research binding is not built")
class ChallengeControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog, cls.decks, cls.strategies = load_product_payloads()
        cards = [row["card_id"] for row in cls.decks["fire"]["cards"]
                 for _ in range(row["count"])]
        session = native.NativeRulesSession()
        assert session.create(cls.catalog, [cards, cards],
                              {"public_deck_keys": ["fire", "fire"]}, 17)["success"]
        for step in range(40):
            state = session.snapshot()
            if state["phase"] == "MAIN":
                break
            pending = next((session.pending_choice(actor) for actor in (0, 1)
                            if session.pending_choice(actor)), None)
            if pending:
                result = session.apply_choice({"request_id": pending["request_id"],
                    "option_ids": [pending["options"][0]["option_id"]], "cancelled": False})
            else:
                actions = _flatten_native_rows(session.legal_actions(state["setup_actor_idx"]))
                action = next((row for row in actions if row["kind"] == "SETUP_DONE"), actions[0])
                result = session.apply_action({**action, "action_id": f"setup:{step}"})
            assert result["success"], result
        cls.state = session.snapshot()
        assert cls.state["phase"] == "MAIN"
        pokemon = copy.deepcopy(cls.state["players"][0]["active"])
        for actor in (0, 1):
            player = cls.state["players"][actor]
            player["active"] = {**pokemon, "card_id": "svi-chim",
                                "damage_counters": 2 if actor else 0,
                                "energy_card_ids": [], "evolution_stack_ids": [],
                                "placed_this_turn": False}
            player["bench"] = [None] * 5
            player["hand"] = ["sv1-151"] if actor else ["sv1-ener-2"]
            player["prizes"] = ["sv1-ener-2"]
            for flag in ("energy_attached_this_turn", "supporter_played_this_turn", "retreated_this_turn"):
                player[flag] = False
        cls.state.update(active_player_idx=0, first_player_idx=1, turn_number=4, revision=100)

    def setUp(self):
        self.session = native.NativeRulesSession()
        self.session.set_catalog(self.catalog)
        self.assertTrue(self.session.restore(copy.deepcopy(self.state), 17)["success"])
        self.controller = self.make_controller()

    def make_controller(self):
        result = native.ChallengeController()
        self.assertTrue(result.configure(self.catalog, self.decks, self.strategies)["success"])
        result.reset_match("controller-test")
        return result

    def request(self, **changes):
        observation = self.session.ai_observation_for(0)
        return {"kind": "action", "actor": 0, "state": observation,
                "public_snapshot": observation, "revision": self.session.revision,
                "request_id": f"test:{self.session.revision}", "match_instance_id": "controller-test",
                "seed": 17, "match_seed": 17, "engine": "strategic_intent_v3",
                "actions": _flatten_native_rows(self.session.legal_actions(0)),
                "internal_evaluation_batch": True, "belief_samples": 3, **changes}

    def decide(self, **changes):
        result = self.controller.decide(self.request(**changes), 1000)
        self.assertTrue(result.get("success"), result)
        return result

    def prime_plan(self):
        planned = self.decide()
        self.assertFalse(planned["strategic_fallback"])
        self.assertEqual([row["kind"] for row in planned["sequence"]],
                         ["ATTACH_ENERGY", "DECLARE_ATTACK"])
        self.assertTrue(planned["strategic_plan_memory"])
        self.assertTrue(self.session.apply_action({**planned["action"], "action_id": "attach"})["success"])

    def test_winning_plan_cache_skips_legacy_and_ranking(self):
        self.prime_plan()
        result = self.decide()
        self.assertTrue(result["turn_plan_cache_hit"])
        self.assertEqual(result["action"]["kind"], "DECLARE_ATTACK")
        self.assertFalse(result["strategic_shadow_legacy"])
        self.assertEqual(result["strategic_shadow_nodes"], 0)
        self.assertEqual(result["nodes_expanded"], 0)
        self.assertEqual(result["native_performance_counters"]["ranked_action_queries"], 0)
        self.assertTrue(self.session.apply_action({**result["action"], "action_id": "attack"})["success"])
        # Actual attack/discard choices must agree with the simulated continuation.
        for _ in range(4):
            pending = self.session.pending_choice(0)
            if not pending:
                break
            choice = self.decide(kind="choice", choice=pending, request_id=pending["request_id"])
            self.assertTrue(self.session.apply_choice(choice["choice_response"])["success"])
        self.assertEqual(self.session.snapshot()["winner"], 0)

    def test_unique_action_does_not_request_legacy(self):
        state = self.session.snapshot()
        state["players"][0]["hand"] = []
        self.assertTrue(self.session.restore(state, 17)["success"])
        result = self.decide()
        self.assertEqual(result["strategic_completion_reason"], "dominance_unique_action")
        self.assertFalse(result["strategic_shadow_legacy"])

    def test_immediate_win_does_not_request_legacy(self):
        state = self.session.snapshot()
        state["players"][0]["hand"] = []
        state["players"][0]["active"]["energy_card_ids"] = ["sv1-ener-2"]
        self.assertTrue(self.session.restore(state, 17)["success"])
        result = self.decide()
        self.assertEqual(result["strategic_completion_reason"], "dominance_immediate_win")
        self.assertFalse(result["strategic_shadow_legacy"])

    def test_changed_public_state_invalidates_plan(self):
        self.prime_plan()
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        self.assertFalse(self.decide()["turn_plan_cache_hit"])

    def test_newly_known_opponent_hand_invalidates_plan(self):
        self.prime_plan()
        result = self.decide(public_history=[{
            "event_type": "cards_selected", "visibility": "public", "actor": 1,
            "source": {"player": 1, "zone": "deck"},
            "target": {"player": 1, "zone": "hand"},
            "data": {"player": 1, "card_ids": ["sv1-151"]},
        }])
        self.assertEqual(result["native_performance_counters"]["known_opponent_hand_count"], 1)
        self.assertFalse(result["turn_plan_cache_hit"])

    def test_nonadvancing_revision_does_not_consume_next_action(self):
        self.prime_plan()
        result = self.decide(revision=100)
        self.assertFalse(result["turn_plan_cache_hit"])
        self.assertEqual(result["action"]["kind"], "DECLARE_ATTACK")

    def test_cancelled_generation_keeps_unconsumed_plan(self):
        self.prime_plan()
        self.controller.cancel(1000)
        result = self.controller.decide(self.request(), 1000)
        self.assertTrue(result.get("cancelled"))
        resumed = self.controller.decide(self.request(), 1001)
        self.assertTrue(resumed["success"])
        self.assertTrue(resumed["turn_plan_cache_hit"])
        self.assertFalse(resumed["strategic_shadow_legacy"])

    def test_reset_match_discards_previous_plan(self):
        self.prime_plan()
        self.controller.reset_match("next-match")
        self.assertFalse(self.decide(match_instance_id="next-match")["turn_plan_cache_hit"])

    def test_fallback_keeps_the_legacy_selection(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        legacy = self.make_controller()
        strategic = self.decide()
        frozen = legacy.decide(self.request(engine="turn_beam_v2"), 1000)
        self.assertTrue(strategic["strategic_fallback"])
        self.assertEqual(strategic["action"], frozen["action"])
        self.assertTrue(self.session.apply_action({**strategic["action"], "action_id": "fallback"})["success"])
        self.assertEqual(self.decide()["action"],
                         legacy.decide(self.request(engine="turn_beam_v2"), 1000)["action"])

    def test_shadow_fallback_still_records_no_progress_cycles(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        first = self.decide(shadow_probe=True)
        self.assertTrue(first["strategic_fallback"])
        self.assertEqual(first["action"]["kind"], "ATTACH_ENERGY")
        # A newer revision with no board progress must block the same action,
        # including a fallback requested through the diagnostic shadow entry.
        state["revision"] += 1
        self.assertTrue(self.session.restore(state, 17)["success"])
        second = self.decide(shadow_probe=True)
        self.assertEqual(second["action"]["kind"], "END_TURN")
        self.assertEqual(second["native_performance_counters"]["root_actions_filtered"], 1)


if __name__ == "__main__":
    unittest.main()

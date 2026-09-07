"""Full native controller regressions; no heuristic or rules mocks."""
from __future__ import annotations

import copy
import json
import sys
import time
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

    def test_policy_change_invalidates_the_continuation(self):
        for policy in ("use_strategy_optimization", "use_deck_inspection", "internal_anytime_search",
                       "internal_dual_guidance"):
            with self.subTest(policy=policy):
                self.setUp()
                self.prime_plan()
                self.assertFalse(self.decide(**{policy: False})["turn_plan_cache_hit"])

    def test_fallback_keeps_the_legacy_selection(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        legacy = self.make_controller()
        # Insufficient compilation work must fall back transactionally. The
        # improved planner may now prove this line at its normal budget.
        strategic = self.decide(node_budget=1)
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
        first = self.decide(shadow_probe=True, node_budget=1)
        self.assertTrue(first["strategic_fallback"])
        self.assertEqual(first["action"]["kind"], "ATTACH_ENERGY")
        # A newer revision with no board progress must block the same action,
        # including a fallback requested through the diagnostic shadow entry.
        state["revision"] += 1
        self.assertTrue(self.session.restore(state, 17)["success"])
        second = self.decide(shadow_probe=True, node_budget=1)
        self.assertEqual(second["action"]["kind"], "END_TURN")
        self.assertEqual(second["native_performance_counters"]["root_actions_filtered"], 1)

    def known_opponent_card(self, card_id):
        state = self.session.snapshot()
        state["players"][1]["hand"] = [card_id]
        state["players"][1]["deck"] = []
        self.assertTrue(self.session.restore(state, 17)["success"])
        return self.decide(public_history=[{
            "event_type": "cards_selected", "visibility": "public", "actor": 1,
            "source": {"player": 1, "zone": "deck"},
            "target": {"player": 1, "zone": "hand"},
            "data": {"player": 1, "card_ids": [card_id]},
        }])["strategic_facts"]["belief"]

    def test_empty_bench_does_not_prevent_board_out(self):
        state = self.session.snapshot()
        state["players"][0]["active"]["damage_counters"] = (
            self.catalog["cards"]["svi-chim"]["hp"] // 10 - 1)
        state["players"][1]["active"]["energy_card_ids"] = ["sv1-ener-2"]
        for player in state["players"]:
            player["prizes"] = ["sv1-ener-2"] * 6
        self.assertTrue(self.session.restore(state, 17)["success"])
        facts = self.decide()["strategic_facts"]
        self.assertFalse(facts["has_backup"])
        self.assertTrue(facts["threats"]["board_loss_threat"])
        self.assertEqual(facts["threats"]["catastrophe_probability"], 1.0)

    def test_known_judge_is_a_hand_disruption_out(self):
        self.assertEqual(self.known_opponent_card("sv1-176")["p_has_hand_disruption"], 1.0)

    def test_pokemon_only_search_is_not_an_energy_out(self):
        self.assertEqual(self.known_opponent_card("sv1-151")["p_has_energy_out"], 0.0)

    def combat_position(self, deck, active_id, *, energies=(), hand=(), bench=(), type_matchups=False):
        state = copy.deepcopy(self.state)
        state["apply_type_matchups"] = type_matchups
        state["rules_options"]["apply_type_matchups"] = type_matchups
        state["public_deck_keys"][0] = deck
        owner = state["players"][0]
        template = {**owner["active"], "damage_counters": 0,
                    "energy_card_ids": [], "evolution_stack_ids": [],
                    "placed_this_turn": False, "used_abilities": [],
                    "status_conditions": [], "modifiers": []}
        owner["active"] = {**copy.deepcopy(template), "card_id": active_id,
                           "energy_card_ids": list(energies)}
        owner["bench"] = [{**copy.deepcopy(template), "card_id": cid} for cid in bench]
        owner["bench"] += [None] * (5 - len(bench))
        owner["hand"] = list(hand)
        owner["discard"] = []
        pool = [row["card_id"] for row in self.decks[deck]["cards"] for _ in range(row["count"])]
        for cid in [active_id, *energies, *hand, *bench]:
            pool.remove(cid)
        owner["prizes"] = [pool.pop() for _ in range(6)]
        owner["deck"] = pool
        state["players"][1]["prizes"] = ["sv1-ener-2"] * 6
        self.assertTrue(self.session.restore(state, 17)["success"])
        return self.decide(internal_full_diagnostics=True)["strategic_facts"]

    def test_small_attack_does_not_mean_burst_attack_is_ready(self):
        facts = self.combat_position("lightning", "svl-pikaex", energies=["sv1-ener-4"])
        attacker = facts["own_attackers"]["attackers"][0]
        self.assertTrue(facts["active_can_attack"])
        self.assertGreater(attacker["missing_energy"], 0)
        self.assertGreater(attacker["max_relevant_damage"], attacker["expected_damage"])
        self.assertLess(attacker["readiness_probability"], 1)

    def test_time_budget_returns_a_legal_action_without_cancellation(self):
        started = time.perf_counter()
        result = self.decide(time_budget_ms=1)
        self.assertLess(time.perf_counter() - started, 0.5)
        self.assertFalse(result.get("cancelled", False))
        self.assertTrue(result["native_performance_counters"]["time_budget_exhausted"])
        self.assertTrue(self.session.apply_action({**result["action"], "action_id": "deadline"})["success"])

    def test_unique_action_avoids_optional_combat_analysis(self):
        request = self.request()
        request["actions"] = [next(a for a in request["actions"] if a["kind"] == "END_TURN")]
        result = self.controller.decide(request, 1000)
        self.assertTrue(result["success"])
        self.assertFalse(result["strategic_shadow_legacy"])
        self.assertEqual(result["native_performance_counters"]["memo_pipeline_computations"], 0)

    def test_expired_request_does_not_publish_a_continuation(self):
        result = self.decide(time_budget_ms=1)
        self.assertTrue(result["native_performance_counters"]["time_budget_exhausted"])
        self.assertTrue(self.session.apply_action({**result["action"], "action_id": "expired"})["success"])
        resumed = self.decide(time_budget_ms=5000)
        self.assertFalse(resumed["turn_plan_cache_hit"])

    def test_initial_search_candidates_are_reused_as_complete_plans(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        result = self.decide(time_budget_ms=0)
        self.assertGreaterEqual(result["native_performance_counters"]["reused_initial_plans"], 2)

    def test_fixed_work_parallel_samples_keep_the_same_decision(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        sequential = self.make_controller().decide(self.request(time_budget_ms=0), 1000)
        parallel = self.make_controller().decide(self.request(time_budget_ms=0, internal_evaluation_batch=False), 1000)
        semantic = lambda action: {key: value for key, value in action.items() if key != "action_id"}
        self.assertTrue(sequential["success"] and parallel["success"])
        self.assertEqual(semantic(sequential["action"]), semantic(parallel["action"]))
        self.assertEqual(sequential["score_milli"], parallel["score_milli"])

    def test_completed_winning_incumbent_can_be_cached(self):
        result = self.decide(time_budget_ms=5000)
        self.assertFalse(result["strategic_fallback"])
        self.assertTrue(result["strategic_plan_memory"])
        self.assertEqual(result["strategic_explanation"]["confidence"], "terminal_win")
        self.assertGreater(result["native_performance_counters"]["rule_action_applications"], 0)

    def test_dual_guidance_leaves_the_independent_v2_entry_unchanged(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        results = [self.make_controller().decide(self.request(
            engine="turn_beam_v2", internal_dual_guidance=enabled, time_budget_ms=0), 1000)
            for enabled in (False, True)]
        for result in results:
            self.assertTrue(result["success"])
            self.assertEqual(result["native_performance_counters"]["classic_routes_retained"], 0)
        for key in ("action", "sequence", "score_milli", "worst_score_milli"):
            self.assertEqual(results[0].get(key), results[1].get(key))

    def test_guided_complete_candidates_replay_to_a_turn_boundary(self):
        state = self.session.snapshot()
        state["players"][0]["bench"][0] = copy.deepcopy(state["players"][0]["active"])
        state["players"][1]["active"].update(card_id="sv1-113", damage_counters=0)
        for player in state["players"]:
            player["prizes"] = ["sv1-ener-2"] * 6
        self.assertTrue(self.session.restore(state, 17)["success"])
        result = self.decide(time_budget_ms=0, internal_full_diagnostics=True)
        candidates = result["strategic_explanation"]["candidate_plans"]
        self.assertGreater(len(candidates), 1)
        for candidate in candidates:
            with self.subTest(sequence=candidate["sequence"]):
                self.assertIsInstance(candidate["classic_score_milli"], int)
                replay = native.NativeRulesSession()
                replay.set_catalog(self.catalog)
                self.assertTrue(replay.restore(state, 17)["success"])
                for step, action in enumerate(candidate["sequence"]):
                    self.assertTrue(replay.apply_action({**action, "action_id": f"guided:{step}"})["success"])
                    for actor in (0, 1):
                        pending = replay.pending_choice(actor)
                        if pending:
                            self.assertEqual(len(pending["options"]), 1)
                            self.assertTrue(replay.apply_choice({"request_id": pending["request_id"],
                                "option_ids": [pending["options"][0]["option_id"]], "cancelled": False})["success"])
                self.assertIn(candidate["sequence"][-1]["kind"], ("DECLARE_ATTACK", "END_TURN"))
                self.assertNotEqual(replay.snapshot()["active_player_idx"], 0)

    def test_unfinished_development_is_not_overridden_by_direct_end_turn(self):
        state = self.session.snapshot()
        state["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(state, 17)["success"])
        result = self.decide(internal_evaluation_smoke=True, node_budget=32)
        self.assertEqual(result["action"]["kind"], "ATTACH_ENERGY")
        self.assertTrue(result["strategic_fallback"])

    def test_xatu_cannot_attach_a_trainer_as_energy(self):
        facts = self.combat_position("psychic", "sv1-113", energies=["sv1-ener-5"],
                                     hand=["sv1-176"], bench=["sv1-108", "sv1-111"])
        latios = next(row for row in facts["own_attackers"]["attackers"] if row["card_id"] == "sv1-111")
        self.assertGreaterEqual(latios["earliest_ready_turn"], latios["missing_energy"])

    def test_one_energy_is_not_spent_by_two_xatu_and_manual_attachment(self):
        facts = self.combat_position("psychic", "sv1-113", energies=["sv1-ener-5"],
                                     hand=["sv1-ener-5"], bench=["sv1-108", "sv1-108", "sv1-111"])
        latios = next(row for row in facts["own_attackers"]["attackers"] if row["card_id"] == "sv1-111")
        self.assertGreaterEqual(latios["earliest_ready_turn"], latios["missing_energy"] - 1)

    def test_real_metal_transfer_cycle_reaches_turn_boundary(self):
        path = RESEARCH_ROOT.parents[1] / "native/challenge_core/tests/fixtures/steel_transfer_cycle.json"
        fixture = json.loads(path.read_text(encoding="utf-8"))
        self.assertTrue(self.session.restore(fixture["snapshot"], fixture["rng_state"])["success"])
        turn = self.session.snapshot()["turn_number"]
        for step in range(40):
            if self.session.snapshot()["turn_number"] != turn:
                break
            pending = self.session.pending_choice(0)
            observation = self.session.ai_observation_for(0)
            request = self.request(seed=fixture["rng_state"])
            if pending:
                request.update(kind="choice", choice=pending, state=observation,
                               public_snapshot=observation)
            result = self.controller.decide(request, step + 1)
            self.assertTrue(result.get("success"), result)
            applied = self.session.apply_choice(result["choice_response"]) if pending else self.session.apply_action(
                {**result["action"], "action_id": f"transfer-cycle:{step}"})
            self.assertTrue(applied["success"], applied)
        self.assertGreater(self.session.snapshot()["turn_number"], turn)

    def test_cycle_guard_blocks_a_return_to_an_earlier_position(self):
        original = self.session.snapshot()
        original["players"][1]["active"]["damage_counters"] = 0
        self.assertTrue(self.session.restore(original, 17)["success"])
        first = self.decide(node_budget=1)
        self.assertEqual(first["action"]["kind"], "ATTACH_ENERGY")
        intermediate = copy.deepcopy(original)
        intermediate["revision"] += 1
        intermediate["players"][0]["active"]["damage_counters"] += 1
        self.assertTrue(self.session.restore(intermediate, 17)["success"])
        self.decide(node_budget=1)
        original["revision"] += 2
        self.assertTrue(self.session.restore(original, 17)["success"])
        returned = self.decide(node_budget=1)
        self.assertNotEqual(returned["action"]["kind"], "ATTACH_ENERGY")
        self.assertGreater(returned["native_performance_counters"]["root_actions_filtered"], 0)

    def test_ultra_ball_cost_keeps_a_live_candy_evolution_pair(self):
        self.combat_position("water", "sv2-tatsu", energies=["sv1-ener-3"],
            hand=["sv1-153", "sv1-152", "sv2-grex", "sv2-young", "sv1-180"],
            bench=["sv2-38"])
        actions = _flatten_native_rows(self.session.legal_actions(0))
        ball = next(action for action in actions if action["kind"] == "PLAY_TRAINER"
                    and action["source"]["card_id"] == "sv1-153")
        self.assertTrue(self.session.apply_action({**ball, "action_id": "combo-ball"})["success"])
        pending = self.session.pending_choice(0)
        self.assertIsNotNone(pending)
        result = self.controller.decide(self.request(kind="choice", choice=pending), 2000)
        self.assertTrue(result["success"], result)
        ids = result["choice_response"]["option_ids"]
        removed = [row["ref"]["card_id"] for row in pending["options"] if row["option_id"] in ids]
        self.assertNotIn("sv1-152", removed)
        self.assertNotIn("sv2-grex", removed)
        self.assertTrue(self.session.apply_choice(result["choice_response"])["success"])

    def test_coin_attack_is_not_a_certain_knockout(self):
        state = self.session.snapshot()
        state["players"][0]["active"]["damage_counters"] = self.catalog["cards"]["svi-chim"]["hp"] // 10 - 1
        opponent = state["players"][1]
        opponent["active"].update(card_id="sv2-38", energy_card_ids=["sv1-ener-3"], damage_counters=0)
        state["public_deck_keys"][1] = "water"
        self.assertTrue(self.session.restore(state, 17)["success"])
        facts = self.decide()["strategic_facts"]
        self.assertEqual(facts["belief"]["p_can_ko_active"], 0.5)

    def test_damage_forecast_respects_the_match_type_option(self):
        self.combat_position("lightning", "svl-pikaex", energies=["sv1-ener-4"])
        state = self.session.snapshot()
        state["players"][1]["active"].update(card_id="sv2-38", damage_counters=0, energy_card_ids=[])
        state["public_deck_keys"][1] = "water"
        damage = []
        for enabled in (False, True):
            state["apply_type_matchups"] = enabled
            state["rules_options"]["apply_type_matchups"] = enabled
            self.assertTrue(self.session.restore(state, 17)["success"])
            self.controller = self.make_controller()
            damage.append(self.decide()["strategic_facts"]["own_attackers"]["attackers"][0]["expected_damage"])
        self.assertEqual(damage, [30, 60])

    def test_support_evolution_is_not_the_next_combat_attacker(self):
        facts = self.combat_position("psychic", "sv1-113", bench=["sv1-107"], hand=["sv1-108"])
        self.assertTrue(facts["has_backup"])
        self.assertEqual(facts["own_attackers"]["next_slot"], "")

    def test_choices_remain_legal_with_type_matchups_enabled(self):
        self.combat_position("water", "sv2-tatsu", hand=["sv1-153", "sv2-young", "sv1-180"], type_matchups=True)
        ball = next(action for action in _flatten_native_rows(self.session.legal_actions(0))
                    if action["kind"] == "PLAY_TRAINER" and action["source"]["card_id"] == "sv1-153")
        self.assertTrue(self.session.apply_action({**ball, "action_id": "typed-ball"})["success"])
        result = self.controller.decide(self.request(kind="choice", choice=self.session.pending_choice(0)), 2000)
        self.assertTrue(result["success"], result)
        self.assertTrue(result["type_matchups"])
        self.assertTrue(self.session.apply_choice(result["choice_response"])["success"])

    def test_candy_in_deck_does_not_make_a_hand_evolution_certain(self):
        facts = self.combat_position("water", "sv2-tatsu", hand=["sv2-grex"], bench=["sv2-38"])
        froakie = next(row for row in facts["own_attackers"]["attackers"] if row["card_id"] == "sv2-38")
        self.assertLess(froakie["access_probability"], 1.0)

    def test_special_energy_counts_units_and_its_damage_reduction(self):
        facts = self.combat_position("colorless", "svi-maus", energies=["svi-dtur"])
        attacker = facts["own_attackers"]["attackers"][0]
        self.assertEqual(attacker["missing_energy"], 0)
        self.assertEqual(attacker["expected_damage"], 100)
        self.assertEqual(attacker["max_relevant_damage"], 100)

    def test_replacing_a_slot_occupant_discards_its_attacker_commitment(self):
        self.combat_position("psychic", "sv1-113", bench=["sv1-111"])
        before = self.decide(internal_full_diagnostics=True)["strategic_match_plan"]
        self.assertEqual(before["next_attacker_slot"], "bench_0")
        state = self.session.snapshot()
        # The same slot now holds a support engine, not the previous attacker.
        state["players"][0]["bench"][0]["card_id"] = "sv1-108"
        state["revision"] += 1
        self.assertTrue(self.session.restore(state, 17)["success"])
        after = self.decide(internal_full_diagnostics=True)["strategic_match_plan"]
        self.assertEqual(after["next_attacker_slot"], "")
        self.assertEqual(after["next_attacker_card_id"], "")

    def test_legacy_replay_action_survives_replacing_its_rules_session(self):
        path = RESEARCH_ROOT.parents[1] / "native/challenge_core/tests/fixtures/legacy_replay_lifetime.json"
        fixture = json.loads(path.read_text(encoding="utf-8"))
        self.assertTrue(self.session.restore(fixture["snapshot"], fixture["rng_state"])["success"])
        self.assertEqual(self.session.state_hash, fixture["state_hash"])
        self.controller.reset_match(fixture["request"]["match_instance_id"])
        result = self.controller.decide(fixture["request"], fixture["request"]["revision"] + 1)
        self.assertTrue(result.get("success"), result)
        self.assertTrue(result["strategic_shadow_legacy"])
        self.assertGreater(result["nodes_expanded"], 0)
        self.assertTrue(self.session.apply_action({**result["action"], "action_id": "lifetime-regression"})["success"])

    def test_mandatory_attack_keeps_its_catalog_definition_alive(self):
        path = RESEARCH_ROOT.parents[1] / "native/challenge_core/tests/fixtures/mandatory_attack_lifetime.json"
        request = json.loads(path.read_text(encoding="utf-8"))["request"]
        self.controller.reset_match(request["match_instance_id"])
        result = self.controller.decide(request, request["revision"] + 1)
        self.assertTrue(result.get("success"), result)
        self.assertTrue(result["strategic_shadow_legacy"])
        self.assertGreater(result["strategic_shadow_nodes"], 0)
        semantics = lambda action: {key: value for key, value in action.items() if key != "action_id"}
        self.assertIn(semantics(result["action"]), [semantics(action) for action in request["actions"]])


if __name__ == "__main__":
    unittest.main()

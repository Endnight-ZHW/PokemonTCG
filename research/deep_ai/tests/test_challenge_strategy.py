"""Strategy failures reproduced from Arena positions through the real rules."""
from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

RESEARCH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RESEARCH_ROOT / "build/native"))
try:
    import ptcg_ai_core as native
except ImportError:
    native = None

from deep_ai.challenge_arena import load_product_payloads
from engine.game_engine import _flatten_native_rows


@unittest.skipUnless(native is not None, "native research binding is not built")
class ChallengeStrategyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog, cls.decks, cls.strategies = load_product_payloads()

    def position(self, name):
        fixture_path = RESEARCH_ROOT.parents[1] / "native/challenge_core/tests/fixtures" / (name + ".json")
        self.fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        self.actor = self.fixture["actor"]
        self.session = native.NativeRulesSession()
        self.session.set_catalog(self.catalog)
        self.assertTrue(self.session.restore(self.fixture["snapshot"], self.fixture["rng_state"])["success"])
        self.controller = native.ChallengeController()
        self.assertTrue(self.controller.configure(self.catalog, self.decks, self.strategies)["success"])
        self.controller.reset_match(name)
        self.match = name

    def decide(self, *, reverse_options=False):
        pending = self.session.pending_choice(self.actor)
        observation = self.session.ai_observation_for(self.actor)
        request = {"kind": "choice" if pending else "action", "actor": self.actor,
                   "state": observation, "public_snapshot": observation, "revision": self.session.revision,
                   "request_id": pending["request_id"] if pending else str(self.session.revision),
                   "match_instance_id": self.match, "seed": self.fixture["decision_seed"],
                   "match_seed": self.fixture["match_seed"], "engine": "deck_planner_v1",
                   "internal_evaluation_batch": True, "node_budget": 192, "belief_samples": 3,
                   "time_budget_ms": 0}
        if pending:
            request["choice"] = copy.deepcopy(pending)
            if reverse_options:
                request["choice"]["options"].reverse()
        else:
            request["actions"] = _flatten_native_rows(self.session.legal_actions(self.actor))
        result = self.controller.decide(request, self.session.revision + 1)
        self.assertTrue(result["success"], result)
        applied = (self.session.apply_choice(result["choice_response"]) if pending else
                   self.session.apply_action({**result["action"], "action_id": "strategy:" + str(self.session.revision)}))
        self.assertTrue(applied["success"], applied)
        return pending, result

    def test_grotle_search_starts_a_live_backup_instead_of_an_unusable_evolution(self):
        self.position("grass_search_setup")
        pending, result = self.decide()
        ids = result["choice_response"]["option_ids"]
        selected = [option["ref"]["card_id"] for option in pending["options"] if option["option_id"] in ids]
        self.assertEqual(len(selected), 1)
        self.assertIn(selected[0], {"svg2-turt", "svg2-shro"})
        basic = next(action for action in _flatten_native_rows(self.session.legal_actions(self.actor))
                     if action["kind"] == "PLAY_BASIC" and action["source"]["card_id"] == selected[0])
        self.assertTrue(self.session.apply_action({**basic, "action_id": "plant-backup"})["success"])
        self.assertTrue(any(p and p["card_id"] == selected[0]
                            for p in self.session.snapshot()["players"][self.actor]["bench"]))

    def test_clara_recovers_two_distinct_energy_cards_even_after_high_value_pokemon(self):
        for reverse in (False, True):
            with self.subTest(reverse_option_order=reverse):
                self.position("psychic_clara_resources")
                before = self.session.snapshot()["players"][self.actor]
                pending, result = self.decide(reverse_options=reverse)
                ids = result["choice_response"]["option_ids"]
                selected = [option["ref"]["card_id"] for option in pending["options"] if option["option_id"] in ids]
                self.assertEqual(len(ids), len(set(ids)))
                self.assertEqual(len(selected), 4)
                self.assertEqual(selected.count("sv1-ener-5"), 2)
                after = self.session.snapshot()["players"][self.actor]
                self.assertEqual(after["hand"].count("sv1-ener-5") - before["hand"].count("sv1-ener-5"), 2)
                self.assertEqual(before["discard"].count("sv1-ener-5") - after["discard"].count("sv1-ener-5"), 2)
                self.assertTrue(any(action["kind"] == "USE_ABILITY" and action["source"]["card_id"] == "sv1-108"
                                    for action in _flatten_native_rows(self.session.legal_actions(self.actor))))

    def test_grass_evolves_and_develops_a_backup_before_its_next_turn(self):
        self.position("grass_evolution_engine")
        turn = self.session.snapshot()["turn_number"]
        for _ in range(24):
            if self.session.snapshot()["turn_number"] != turn:
                break
            self.decide()
        owner = self.session.snapshot()["players"][self.actor]
        self.assertNotEqual(self.session.snapshot()["turn_number"], turn)
        self.assertEqual(owner["active"]["card_id"], "svg2-grot")
        self.assertTrue(any(pokemon for pokemon in owner["bench"]))
        self.assertIn("svg2-tort", owner["hand"])

    def test_fighting_manual_attachment_preserves_energy_switch_for_a_later_turn(self):
        self.position("fighting_manual_attachment")
        turn = self.session.snapshot()["turn_number"]
        for _ in range(12):
            if self.session.snapshot()["turn_number"] != turn:
                break
            self.decide()
        owner = self.session.snapshot()["players"][self.actor]
        self.assertNotEqual(self.session.snapshot()["turn_number"], turn)
        self.assertEqual(owner["active"]["card_id"], "svf-scyt")
        self.assertEqual(owner["active"]["energy_card_ids"], ["sv1-ener-6"])
        self.assertIn("svf-ensw2", owner["hand"])
        self.assertNotIn("svf-ensw2", owner["discard"])

    def test_fighting_spends_reserved_energy_switch_to_finish_the_game(self):
        self.position("fighting_energy_switch_finish")
        for _ in range(12):
            if self.session.snapshot()["phase"] == "GAME_OVER":
                break
            self.decide()
        state = self.session.snapshot()
        self.assertEqual(state["phase"], "GAME_OVER")
        self.assertEqual(state["winner"], self.actor)
        self.assertIn("svf-ensw2", state["players"][self.actor]["discard"])

    def test_arven_ball_choices_keep_the_energy_needed_to_start_xatu(self):
        self.position("psychic_arven_engine")
        pending, result = self.decide()
        selected = [o["ref"]["card_id"] for o in pending["options"]
                    if o["option_id"] in result["choice_response"]["option_ids"]]
        self.assertIn("sv1-153", selected)

        def play(kind, card):
            action = next(a for a in _flatten_native_rows(self.session.legal_actions(self.actor))
                          if a["kind"] == kind and a["source"]["card_id"] == card)
            self.assertTrue(self.session.apply_action({**action, "action_id": kind + card})["success"])

        # Exercise this resource combination with live choices and real costs.
        play("PLAY_TRAINER", "sv1-153")
        self.decide()
        self.assertIn("sv1-ener-5", self.session.snapshot()["players"][self.actor]["hand"])
        self.decide()
        self.assertIn("sv1-108", self.session.snapshot()["players"][self.actor]["hand"])
        play("EVOLVE", "sv1-108")
        before = self.session.snapshot()["players"][self.actor]
        play("USE_ABILITY", "sv1-108")
        self.decide()
        after = self.session.snapshot()["players"][self.actor]
        energies = lambda player: sum(len(p["energy_card_ids"]) for p in [player["active"], *player["bench"]] if p)
        self.assertEqual(energies(after) - energies(before), 1)
        self.assertEqual(len(after["hand"]) - len(before["hand"]), 1)


if __name__ == "__main__":
    unittest.main()

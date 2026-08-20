from __future__ import annotations

import copy
import json
import runpy
import sys
import time
import unittest
from pathlib import Path

import numpy as np

PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.inference_v2 import NativeBatchTorchBroker
from engine.ai.dl.native_bridge_v2 import (
    NativeBridgeError,
    NativeModelBackend,
    NativeSearchService,
    _native_choice_view,
    _public_native_bench_damage_continuation,
    _public_native_exp_share_continuation,
    _public_native_exp_share_order_continuation,
    _public_native_prize_continuation,
    _public_native_trigger_continuation,
    _public_native_vm_continuation,
    game_state_to_native_wire,
    mask_native_snapshot,
)

try:
    import ptcg_ai_core
except ImportError:
    try:
        from python import ptcg_ai_core
    except ImportError:
        ptcg_ai_core = None


@unittest.skipIf(ptcg_ai_core is None, "native AI extension is not built")
class NativeAICoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.cards = json.loads(
            (root / "godot" / "data" / "cards.json").read_text(
                encoding="utf-8"
            )
        )
        cls.vm_fixture = json.loads(
            (
                root
                / "godot"
                / "tests"
                / "fixtures"
                / "vm_native_golden.json"
            ).read_text(encoding="utf-8")
        )
        cls.rules = ptcg_ai_core.NativeRulesKernel(cls.cards)
        cls.rules_fixture = json.loads(
            (
                root
                / "godot"
                / "tests"
                / "fixtures"
                / "rules_golden.json"
            ).read_text(encoding="utf-8")
        )
        cls.game_cards = copy.deepcopy(cls.cards)
        cls.game_cards.update(cls.rules_fixture.get("test_cards", {}))
        cls.game = ptcg_ai_core.NativeGameKernel(cls.game_cards)

    def _native_search_fixture(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["public_deck_keys"] = ["mini-a", "mini-b"]
        state["players"][0]["hand"] = ["svi-chim"]
        state["players"][0]["deck"] = ["a-hidden-0", "a-hidden-1"]
        state["players"][0]["prizes"] = ["a-hidden-2"]
        state["players"][1]["hand"] = ["b-hidden-0"]
        state["players"][1]["deck"] = ["b-hidden-1", "b-hidden-2"]
        state["players"][1]["prizes"] = ["b-hidden-3"]
        decks = {
            "mini-a": [
                state["players"][0]["active"]["card_id"],
                "svi-chim",
                "a-hidden-0",
                "a-hidden-1",
                "a-hidden-2",
            ],
            "mini-b": [
                state["players"][1]["active"]["card_id"],
                "b-hidden-0",
                "b-hidden-1",
                "b-hidden-2",
                "b-hidden-3",
            ],
        }
        return state, decks

    @staticmethod
    def _submitted_decks(state):
        result = {}
        for player_index in (0, 1):
            player = state["players"][player_index]
            cards = [
                *player["hand"],
                *player["deck"],
                *player["discard"],
                *player["prizes"],
            ]
            for pokemon in [player["active"], *player["bench"]]:
                if not isinstance(pokemon, dict):
                    continue
                cards.append(pokemon["card_id"])
                cards.extend(pokemon.get("evolution_stack_ids", []))
                cards.extend(pokemon.get("energy_card_ids", []))
                tool = pokemon.get("attached_tool_id")
                if tool:
                    cards.append(tool)
            if state.get("stadium_owner_idx") == player_index:
                stadium = state.get("stadium_card_id")
                if stadium:
                    cards.append(stadium)
            result[state["public_deck_keys"][player_index]] = cards
        return result

    def _serve_uniform_inference(self, batch, jobs):
        deadline = time.monotonic() + 10.0
        while not all(job.finished for job in jobs):
            self.assertLess(time.monotonic(), deadline)
            tensors = batch.poll_inference(64, 50)
            request_ids = tensors["request_ids"]
            if request_ids.size == 0:
                continue
            batch.submit_inference(
                request_ids,
                np.zeros(tensors["candidate_mask"].shape, np.float32),
                np.zeros((request_ids.size, 3), np.float32),
                tensors["candidate_mask"],
            )

    def test_native_legality_honors_authoritative_attack_lock_fields(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        active = state["players"][0]["active"]
        active["card_id"] = "svm-cobalion"
        active["energy_card_ids"] = ["sv1-ener-8", "sv1-ener-8"]
        active["attack_locked"] = True
        active["attack_locked_names"] = {}
        active["modifiers"] = []
        self.assertFalse(
            any(
                row["kind"] == "DECLARE_ATTACK"
                for row in self.game.legal_actions(state, 0)
            )
        )

        active["attack_locked"] = False
        active["attack_locked_names"] = {"跟进": 2}
        self.assertFalse(
            any(
                row["kind"] == "DECLARE_ATTACK"
                for row in self.game.legal_actions(state, 0)
            )
        )

        active["card_id"] = "sv1-108"
        active["attack_locked"] = False
        active["attack_locked_names"] = {}
        active["energy_card_ids"] = []
        active["used_abilities"] = []
        state["players"][0]["hand"] = ["sv1-ener-5"]
        state["players"][0]["deck"] = ["sv1-ener-5", "sv1-ener-5"]
        state["players"][0]["bench"] = [None, None, None, None, None]
        # Clairvoyant Sense requires a Basic Psychic Energy attachment; its
        # later draw does not make a missing public source legal.
        state["players"][0]["hand"] = ["sv1-189"]
        self.assertFalse(
            any(
                row["kind"] == "USE_ABILITY"
                and row["payload"]["ability_name"] == "以太感知"
                for row in self.game.legal_actions(state, 0)
            )
        )
        state["players"][0]["hand"] = ["svg2-lume"]
        self.assertFalse(
            any(
                row["kind"] == "USE_ABILITY"
                and row["payload"]["ability_name"] == "以太感知"
                for row in self.game.legal_actions(state, 0)
            )
        )
        # A matching Basic Energy still needs a Benched target.
        state["players"][0]["hand"] = ["sv1-ener-5"]
        self.assertFalse(
            any(
                row["kind"] == "USE_ABILITY"
                and row["payload"]["ability_name"] == "以太感知"
                for row in self.game.legal_actions(state, 0)
            )
        )
        state["players"][0]["bench"][0] = copy.deepcopy(active)
        self.assertTrue(
            any(
                row["kind"] == "USE_ABILITY"
                and row["payload"]["ability_name"] == "以太感知"
                for row in self.game.legal_actions(state, 0)
            )
        )

    def test_native_luminous_energy_downgrades_with_other_special_energy(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        active = state["players"][0]["active"]
        active["card_id"] = "svg2-shro"
        active["energy_card_ids"] = ["svg2-lume"]
        active["modifiers"] = []
        self.assertTrue(
            any(
                row["kind"] == "DECLARE_ATTACK"
                for row in self.game.legal_actions(state, 0)
            )
        )
        active["energy_card_ids"] = ["svg2-lume", "svg2-lume"]
        self.assertFalse(
            any(
                row["kind"] == "DECLARE_ATTACK"
                for row in self.game.legal_actions(state, 0)
            )
        )

        active.update(
            card_id="svf-luca",
            damage_counters=0,
            energy_card_ids=["svg2-lume", "sv1-ener-6"],
            evolution_stack_ids=["svf-rio"],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        state["players"][1]["active"].update(
            card_id="svd-mabosstiff-ex",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        state["players"][0]["discard"] = []
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        result = self.game.apply_action(state, action, 0x1A11E5CE)
        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            13,
        )
        self.assertEqual(
            result["state"]["players"][0]["active"]["energy_card_ids"],
            [],
        )
        self.assertCountEqual(
            result["state"]["players"][0]["discard"],
            ["svg2-lume", "sv1-ener-6"],
        )

        relocate_state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        relocate_state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        bronzong = relocate_state["players"][0]["active"]
        bronzong.update(
            card_id="svm-bronzong",
            energy_card_ids=["svg2-lume"],
            evolution_stack_ids=["svm-bronzor"],
            used_abilities=[],
            modifiers=[],
        )
        target = copy.deepcopy(bronzong)
        target.update(card_id="svm-zacian", energy_card_ids=[])
        relocate_state["players"][0]["bench"] = [
            target,
            None,
            None,
            None,
            None,
        ]
        self.assertTrue(
            any(
                row["kind"] == "USE_ABILITY"
                for row in self.game.legal_actions(relocate_state, 0)
            )
        )
        bronzong["energy_card_ids"] = ["svg2-lume", "svi-dtur"]
        self.assertFalse(
            any(
                row["kind"] == "USE_ABILITY"
                for row in self.game.legal_actions(relocate_state, 0)
            )
        )

    def test_native_sub_formula_and_conditional_tool_damage(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        attacker = state["players"][0]["active"]
        defender = state["players"][1]["active"]
        attacker.update({
            "card_id": "svg-ceti",
            "damage_counters": 3,
            "energy_card_ids": [
                "sv1-ener-3",
                "sv1-ener-3",
                "sv1-ener-3",
            ],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "modifiers": [],
        })
        defender.update({
            "card_id": "svg2-tort",
            "damage_counters": 0,
            "energy_card_ids": [],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "modifiers": [],
        })
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        result = self.game.apply_action(state, action, 0x5A8F0101)
        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            14,
        )

        def tool_state(actor_prizes, opponent_prizes):
            candidate = copy.deepcopy(
                next(iter(self.rules_fixture["cases"].values()))[
                    "initial_state"
                ]
            )
            candidate["phase"] = "MAIN"
            candidate["turn_number"] = 3
            candidate["first_player_idx"] = 1
            candidate["active_player_idx"] = 0
            candidate["players"][0]["prizes"] = list(actor_prizes)
            candidate["players"][1]["prizes"] = list(opponent_prizes)
            source = candidate["players"][0]["active"]
            source.update({
                "card_id": "sv1-111",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-5"],
                "evolution_stack_ids": [],
                "attached_tool_id": "sv1-201",
                "modifiers": [{
                    "hook": "MODIFY_DAMAGE",
                    "layer": "attacker_adjust",
                    "priority": 0,
                    "controller": 0,
                    "source_ref": {
                        "kind": "pokemon",
                        "player": 0,
                        "slot": "active",
                        "card_id": "sv1-111",
                    },
                    "scope": "attached_attacker",
                    "duration": "until_leave_play",
                    "stacking": "replace_same_source",
                    "conflict_policy": "commutative",
                    "condition": {"behind_on_prizes": True},
                    "operation": {
                        "kind": "damage_delta",
                        "amount": 30,
                    },
                }],
            })
            target = candidate["players"][1]["active"]
            target.update({
                "card_id": "svg2-tort",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "modifiers": [],
            })
            return candidate

        tied = tool_state(range(6), range(6))
        tied_action = next(
            row
            for row in self.game.legal_actions(tied, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        tied_result = self.game.apply_action(
            tied,
            tied_action,
            0x5A8F0102,
        )
        self.assertEqual(
            tied_result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            2,
        )

        behind = tool_state(range(6), range(5))
        behind_action = next(
            row
            for row in self.game.legal_actions(behind, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        behind_result = self.game.apply_action(
            behind,
            behind_action,
            0x5A8F0103,
        )
        self.assertEqual(
            behind_result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            5,
        )

    @staticmethod
    def _state_projection(source):
        payload = copy.deepcopy(source)
        for key in (
            "action_log",
            "resolution_stack",
            "setup_ready",
            "processed_action_ids",
        ):
            payload.pop(key, None)
        for player in payload.get("players", []):
            pokemon_rows = [player.get("active"), *player.get("bench", [])]
            for pokemon in pokemon_rows:
                if not isinstance(pokemon, dict):
                    continue
                pokemon.pop("modifiers", None)
                for legacy_key in (
                    "damage_prevented",
                    "all_prevented",
                    "outgoing_damage_reduction",
                    "attack_locked",
                    "attack_locked_names",
                    "dazzled",
                ):
                    pokemon.pop(legacy_key, None)
                if isinstance(pokemon.get("used_abilities"), dict):
                    pokemon["used_abilities"] = sorted(
                        pokemon["used_abilities"]
                    )
        return payload

    @classmethod
    def _result_projection(cls, result):
        return {
            "success": result["success"],
            "error_code": result["error_code"],
            "revision": result["state"].get("revision", 0),
            "rng_state": result["rng_state"],
            "event_types": result["event_types"],
            "pending": result["pending"],
            "state": cls._state_projection(result["state"]),
            "context": result["context"],
            "modifier": result["modifier"],
        }

    @staticmethod
    def _rule_state_projection(source):
        payload = copy.deepcopy(source)
        for key in (
            "action_log",
            "resolution_stack",
            "setup_ready",
            "processed_action_ids",
        ):
            payload.pop(key, None)
        for player in payload.get("players", []):
            pokemon_rows = [player.get("active"), *player.get("bench", [])]
            for pokemon in pokemon_rows:
                if not isinstance(pokemon, dict):
                    continue
                for legacy_key in (
                    "damage_prevented",
                    "all_prevented",
                    "outgoing_damage_reduction",
                    "attack_locked",
                    "attack_locked_names",
                    "dazzled",
                ):
                    pokemon.pop(legacy_key, None)
        return payload

    @staticmethod
    def _rule_pending_projection(source):
        payload = copy.deepcopy(source)
        payload.pop("continuation_operations", None)
        payload.pop("frame_kinds", None)
        metadata = payload.get("metadata")
        if isinstance(metadata, dict):
            metadata.pop("required_units", None)
        return payload

    def test_rng_replay_and_apply_undo_are_deterministic(self):
        first = ptcg_ai_core.XorShift32(17)
        second = ptcg_ai_core.XorShift32(17)
        self.assertEqual(
            [first.next_u32() for _ in range(16)],
            [second.next_u32() for _ in range(16)],
        )

        state = ptcg_ai_core.CompactState(8)
        root = state.mark()
        state.set(2, 40)
        branch = state.mark()
        state.set(2, 90)
        state.set(6, -3)
        state.undo(branch)
        self.assertEqual(state.words(), [0, 0, 40, 0, 0, 0, 0, 0])
        state.undo(root)
        self.assertEqual(state.words(), [0] * 8)

    def test_information_set_hash_excludes_unpassed_hidden_identity(self):
        public = [1, 2, 3, 4]
        private = [11, 12]
        baseline = ptcg_ai_core.information_set_hash(public, private, 0)
        self.assertEqual(
            baseline,
            ptcg_ai_core.information_set_hash(public, private, 0),
        )
        self.assertNotEqual(
            baseline,
            ptcg_ai_core.information_set_hash(public, [11, 13], 0),
        )
        self.assertNotEqual(
            baseline,
            ptcg_ai_core.information_set_hash(public, private, 1),
        )

    def test_native_infoset_projection_removes_hidden_identities(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["players"][0]["hand"] = ["own-visible-a", "own-visible-b"]
        state["players"][0]["deck"] = ["own-deck-a", "own-deck-b"]
        state["players"][0]["prizes"] = ["own-prize-a"]
        state["players"][1]["hand"] = ["opponent-hand-a"]
        state["players"][1]["deck"] = [
            "opponent-deck-a",
            "opponent-deck-b",
        ]
        state["players"][1]["prizes"] = ["opponent-prize-a"]

        baseline = ptcg_ai_core.project_information_set(state, 0)
        observation = baseline["observation"]
        self.assertEqual(
            observation["players"][0]["hand"],
            ["own-visible-a", "own-visible-b"],
        )
        self.assertEqual(
            observation["players"][0]["deck"],
            ["__hidden_card__", "__hidden_card__"],
        )
        self.assertEqual(
            observation["players"][1]["hand"],
            ["__hidden_card__"],
        )
        self.assertNotIn("resolution_stack", observation)
        self.assertNotIn("action_log", observation)

        hidden_variant = copy.deepcopy(state)
        hidden_variant["players"][0]["deck"] = [
            "changed-own-deck-b",
            "changed-own-deck-a",
        ]
        hidden_variant["players"][0]["prizes"] = ["changed-own-prize"]
        hidden_variant["players"][1]["hand"] = ["changed-opponent-hand"]
        hidden_variant["players"][1]["deck"] = [
            "changed-opponent-deck-b",
            "changed-opponent-deck-a",
        ]
        hidden_variant["players"][1]["prizes"] = [
            "changed-opponent-prize"
        ]
        projected_variant = ptcg_ai_core.project_information_set(
            hidden_variant,
            0,
        )
        self.assertEqual(
            baseline["observation"],
            projected_variant["observation"],
        )
        self.assertEqual(
            baseline["public_hash"],
            projected_variant["public_hash"],
        )
        self.assertEqual(
            baseline["actor_private_hash"],
            projected_variant["actor_private_hash"],
        )
        self.assertEqual(
            baseline["tree_key"],
            projected_variant["tree_key"],
        )

        own_hand_variant = copy.deepcopy(hidden_variant)
        own_hand_variant["players"][0]["hand"] = [
            "own-visible-a",
            "changed-own-visible",
        ]
        own_projected = ptcg_ai_core.project_information_set(
            own_hand_variant,
            0,
        )
        self.assertEqual(
            baseline["public_hash"],
            own_projected["public_hash"],
        )
        self.assertNotEqual(
            baseline["actor_private_hash"],
            own_projected["actor_private_hash"],
        )
        self.assertNotEqual(
            baseline["tree_key"],
            own_projected["tree_key"],
        )

    def test_native_runtime_boundary_rejects_hidden_identity_leaks(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        for player_index, player in enumerate(state["players"]):
            player["deck"] = ["__hidden_card__"] * len(player["deck"])
            player["prizes"] = [
                "__hidden_prize__"
            ] * len(player["prizes"])
            if player_index != 0:
                player["hand"] = [
                    "__hidden_card__"
                ] * len(player["hand"])
        state.pop("resolution_stack", None)
        self.assertEqual(
            ptcg_ai_core.validate_runtime_snapshot(state, 0),
            "",
        )

        opponent_hand_leak = copy.deepcopy(state)
        opponent_hand_leak["players"][1]["hand"] = ["secret-card-id"]
        self.assertEqual(
            ptcg_ai_core.validate_runtime_snapshot(
                opponent_hand_leak,
                0,
            ),
            "hidden_identity_exposed:players[1].hand",
        )

        own_deck_leak = copy.deepcopy(state)
        own_deck_leak["players"][0]["deck"][0] = "secret-deck-card"
        self.assertEqual(
            ptcg_ai_core.validate_runtime_snapshot(own_deck_leak, 0),
            "hidden_identity_exposed:players[0].deck",
        )

    def test_native_infoset_security_audit_smoke(self):
        script = (
            Path(__file__).resolve().parents[1]
            / "scripts"
            / "verify_native_infoset_security_v2.py"
        )
        audit = runpy.run_path(str(script))["audit"]
        report = audit(
            games=2,
            max_decisions=8,
            seed=1701,
            min_states_per_deck=0,
            detail_limit=10,
        )
        self.assertTrue(report["scope_passed"], report)
        self.assertEqual(report["states"], 16)
        self.assertEqual(report["variants_checked"], 32)
        self.assertEqual(report["details"], [])
        self.assertEqual(report["invariance_status"], "passed")
        self.assertEqual(report["mutation_coverage_status"], "passed")
        self.assertFalse(report["release_gate_complete"])

    def test_native_determinizer_samples_only_from_public_deck_prior(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["public_deck_keys"] = ["mini-a", "mini-b"]
        state["players"][0]["hand"] = ["a-hand"]
        state["players"][0]["deck"] = [
            "leaked-a-deck-0",
            "leaked-a-deck-1",
        ]
        state["players"][0]["prizes"] = ["leaked-a-prize"]
        state["players"][1]["hand"] = [
            "leaked-b-hand-0",
            "leaked-b-hand-1",
        ]
        state["players"][1]["deck"] = [
            "leaked-b-deck-0",
            "leaked-b-deck-1",
        ]
        state["players"][1]["prizes"] = ["leaked-b-prize"]
        a_active = state["players"][0]["active"]["card_id"]
        b_active = state["players"][1]["active"]["card_id"]
        decks = {
            "mini-a": [
                a_active,
                "a-hand",
                "a-hidden-0",
                "a-hidden-1",
                "a-hidden-2",
            ],
            "mini-b": [
                b_active,
                "b-hidden-0",
                "b-hidden-1",
                "b-hidden-2",
                "b-hidden-3",
                "b-hidden-4",
            ],
        }
        determinizer = ptcg_ai_core.NativeDeterminizer(decks)
        baseline = determinizer.determinize(state, 0, 81)
        hidden_variant = copy.deepcopy(state)
        hidden_variant["players"][0]["deck"] = ["x", "y"]
        hidden_variant["players"][0]["prizes"] = ["z"]
        hidden_variant["players"][1]["hand"] = ["p", "q"]
        hidden_variant["players"][1]["deck"] = ["r", "s"]
        hidden_variant["players"][1]["prizes"] = ["t"]
        changed = determinizer.determinize(hidden_variant, 0, 81)
        self.assertEqual(baseline, changed)
        self.assertEqual(baseline["players"][0]["hand"], ["a-hand"])
        self.assertEqual(
            sorted(
                baseline["players"][0]["deck"]
                + baseline["players"][0]["prizes"]
            ),
            ["a-hidden-0", "a-hidden-1", "a-hidden-2"],
        )
        self.assertEqual(
            sorted(
                baseline["players"][1]["hand"]
                + baseline["players"][1]["deck"]
                + baseline["players"][1]["prizes"]
            ),
            [
                "b-hidden-0",
                "b-hidden-1",
                "b-hidden-2",
                "b-hidden-3",
                "b-hidden-4",
            ],
        )
        opponent_view = determinizer.determinize(baseline, 1, 99)
        self.assertEqual(
            opponent_view["players"][1]["hand"],
            baseline["players"][1]["hand"],
        )
        self.assertEqual(
            len(opponent_view["players"][0]["hand"]),
            len(baseline["players"][0]["hand"]),
        )

    def test_native_search_jobs_batch_leaf_inference_and_backup_visits(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["public_deck_keys"] = ["mini-a", "mini-b"]
        state["players"][0]["hand"] = ["svi-chim"]
        state["players"][0]["deck"] = ["a-hidden-0", "a-hidden-1"]
        state["players"][0]["prizes"] = ["a-hidden-2"]
        state["players"][1]["hand"] = ["b-hidden-0"]
        state["players"][1]["deck"] = ["b-hidden-1", "b-hidden-2"]
        state["players"][1]["prizes"] = ["b-hidden-3"]
        decks = {
            "mini-a": [
                state["players"][0]["active"]["card_id"],
                "svi-chim",
                "a-hidden-0",
                "a-hidden-1",
                "a-hidden-2",
            ],
            "mini-b": [
                state["players"][1]["active"]["card_id"],
                "b-hidden-0",
                "b-hidden-1",
                "b-hidden-2",
                "b-hidden-3",
            ],
        }
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        limiter = ptcg_ai_core.NativeSearchLimiter(2)
        jobs = [
            ptcg_ai_core.NativeSearchJob(
                self.game_cards,
                decks,
                batch,
                limiter,
            )
            for _ in range(4)
        ]
        for index, job in enumerate(jobs):
            job.start(
                state,
                0,
                100 + index,
                {
                    "simulations": 12,
                    "max_depth": 16,
                    "c_puct": 1.4,
                    "dirichlet_epsilon": 0.0,
                    "temperature": 0.0,
                    "training": False,
                    "inference_wait_milliseconds": 25,
                },
            )

        time.sleep(0.01)
        max_batch = 0
        deadline = time.monotonic() + 15.0
        while not all(job.finished for job in jobs):
            self.assertLess(time.monotonic(), deadline)
            tensors = batch.poll_inference(64, 50)
            request_ids = tensors["request_ids"]
            if request_ids.size == 0:
                continue
            max_batch = max(max_batch, int(request_ids.size))
            batch.submit_inference(
                request_ids,
                np.zeros(
                    tensors["candidate_mask"].shape,
                    dtype=np.float32,
                ),
                np.zeros((request_ids.size, 3), dtype=np.float32),
                tensors["candidate_mask"],
            )
        results = [job.wait() for job in jobs]
        self.assertGreaterEqual(max_batch, 2)
        self.assertEqual(limiter.capacity, 2)
        self.assertEqual(limiter.active, 0)
        self.assertEqual(limiter.max_active, 2)
        legal = self.game.legal_actions(state, 0)
        self.assertGreater(len(legal), 1)
        for result in results:
            self.assertTrue(result["success"], result)
            self.assertFalse(result["cancelled"])
            self.assertEqual(result["simulations"], 12)
            self.assertEqual(sum(result["visits"]), 11)
            self.assertAlmostEqual(
                sum(result["probabilities"]),
                1.0,
                places=5,
            )
            self.assertIn(result["selected"], legal)
            self.assertEqual(len(result["candidates"]), len(legal))
            self.assertEqual(
                len(result["candidates"]),
                len(result["probabilities"]),
            )
            self.assertGreaterEqual(result["tree_nodes"], 1)

    def test_native_search_single_job_pipelines_multiple_leaves_deterministically(
        self,
    ):
        state, decks = self._native_search_fixture()

        def run_once():
            batch = ptcg_ai_core.NativeSelfPlayBatch()
            job = ptcg_ai_core.NativeSearchJob(
                self.game_cards,
                decks,
                batch,
            )
            job.start(
                state,
                0,
                0x1EAFF00D,
                {
                    "simulations": 16,
                    "max_depth": 16,
                    "c_puct": 1.4,
                    "dirichlet_epsilon": 0.0,
                    "temperature": 0.0,
                    "training": False,
                    "inference_wait_milliseconds": 25,
                    "max_inflight_leaves": 4,
                },
            )
            max_batch = 0
            deadline = time.monotonic() + 10.0
            while not job.finished:
                self.assertLess(time.monotonic(), deadline)
                tensors = batch.poll_inference(8, 50, 4, 10)
                request_ids = tensors["request_ids"]
                if request_ids.size == 0:
                    continue
                max_batch = max(max_batch, int(request_ids.size))
                batch.submit_inference(
                    request_ids,
                    np.zeros(
                        tensors["candidate_mask"].shape,
                        dtype=np.float32,
                    ),
                    np.zeros(
                        (request_ids.size, 3),
                        dtype=np.float32,
                    ),
                    tensors["candidate_mask"],
                )
            return job.wait(), max_batch

        first, first_max_batch = run_once()
        second, second_max_batch = run_once()
        for result in (first, second):
            self.assertTrue(result["success"], result)
            self.assertEqual(result["simulations"], 16)
            self.assertEqual(sum(result["visits"]), 15)
            self.assertGreaterEqual(result["max_pending_leaves"], 2)
        self.assertGreaterEqual(first_max_batch, 2)
        self.assertGreaterEqual(second_max_batch, 2)
        self.assertEqual(first["visits"], second["visits"])
        self.assertEqual(first["value_sums"], second["value_sums"])
        self.assertEqual(first["selected"], second["selected"])

    def test_python_training_bridge_masks_hidden_ids_and_searches_action_root(
        self,
    ):
        try:
            import torch
        except ImportError:
            self.skipTest("torch is unavailable")
        from engine.ai.dl.alphazero_v2 import (
            GameTask,
            _advance_nondecision_phase,
            _setup_game,
        )
        from engine.ai.dl.puct_v2 import PythonGameEnvironment

        class ZeroModel(torch.nn.Module):
            def forward(self, *inputs):
                candidate_numeric = inputs[4]
                batch_size, candidate_count = candidate_numeric.shape[:2]
                return (
                    torch.zeros(
                        (batch_size, candidate_count),
                        device=candidate_numeric.device,
                    ),
                    torch.zeros(
                        (batch_size, 3),
                        device=candidate_numeric.device,
                    ),
                )

        state = _setup_game(
            GameTask(
                "native-bridge-contract",
                1,
                "fire",
                "water",
                173,
                0,
                0,
            )
        )
        while _advance_nondecision_phase(state):
            pass
        environment = PythonGameEnvironment()
        actor = environment.actor(state)
        candidates = list(environment.candidates(state, actor))
        self.assertGreater(len(candidates), 1)
        full_wire = game_state_to_native_wire(state)
        masked = mask_native_snapshot(full_wire, actor)
        changed = copy.deepcopy(full_wire)
        for player_index, player in enumerate(changed["players"]):
            player["deck"] = [
                f"changed-deck-{player_index}-{index}"
                for index in range(len(player["deck"]))
            ]
            player["prizes"] = [
                f"changed-prize-{player_index}-{index}"
                for index in range(len(player["prizes"]))
            ]
            if player_index != actor:
                player["hand"] = [
                    f"changed-hand-{index}"
                    for index in range(len(player["hand"]))
                ]
        self.assertEqual(masked, mask_native_snapshot(changed, actor))
        promotion = copy.deepcopy(full_wire)
        promotion["phase"] = "ATTACK"
        promotion["pending_promotions"] = [actor]
        promotion["resolution_stack"]["context"] = {
            "finish_attack_after_promotions": actor,
        }
        promotion_masked = mask_native_snapshot(promotion, actor)
        self.assertEqual(
            promotion_masked["resolution_stack"]["context"],
            {},
        )
        private_context = copy.deepcopy(promotion)
        private_context["resolution_stack"]["context"][
            "private_continuation"
        ] = "must-not-cross"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_root_choice_continuation_unavailable",
        ):
            mask_native_snapshot(private_context, actor)
        self.assertEqual(
            ptcg_ai_core.validate_runtime_snapshot(masked, actor),
            "",
        )
        with NativeSearchService(
            ZeroModel(),
            device="cpu",
            target_batch_size=4,
            max_batch_size=8,
            coalesce_ms=2,
        ) as service:
            result = service.search_action(
                state,
                actor,
                candidates,
                simulations=4,
                c_puct=1.4,
                seed=173,
                training=False,
                temperature=0.0,
                max_depth=8,
            )
        self.assertEqual(result.simulations, 4)
        self.assertIn(result.selected, candidates)
        self.assertEqual(sum(result.visits.values()), 3)
        self.assertAlmostEqual(
            sum(result.probabilities.values()),
            1.0,
            places=6,
        )

    def test_native_backend_advances_through_action_and_choice_roots(self):
        try:
            import torch
        except ImportError:
            self.skipTest("torch is unavailable")
        from engine.ai.dl.alphazero_v2 import (
            GameTask,
            play_self_play_game,
        )

        class ZeroModel(torch.nn.Module):
            def forward(self, *inputs):
                candidate_numeric = inputs[4]
                batch_size, candidate_count = candidate_numeric.shape[:2]
                return (
                    torch.zeros(
                        (batch_size, candidate_count),
                        device=candidate_numeric.device,
                    ),
                    torch.zeros(
                        (batch_size, 3),
                        device=candidate_numeric.device,
                    ),
                )

        with NativeModelBackend(
            ZeroModel(),
            device="cpu",
            target_batch_size=2,
            max_batch_size=4,
            coalesce_ms=1,
        ) as backend:
            result = play_self_play_game(
                GameTask(
                    "native-continuous-smoke",
                    0,
                    "fire",
                    "water",
                    173,
                    0,
                    0,
                ),
                backend,
                simulations=2,
                c_puct=1.4,
                max_decisions=32,
                training=True,
            )
            metrics = backend.native_metrics

        self.assertEqual(result.decisions, 32)
        self.assertGreaterEqual(result.simulations, 60)
        self.assertEqual(result.invalid_actions, 0)
        self.assertEqual(result.illegal_choices, 0)
        self.assertEqual(result.rule_exceptions, 0)
        self.assertTrue(result.truncated)
        # Every decision, including the intervening search/deck choices,
        # reached the native inference queue for both simulations.
        self.assertEqual(metrics["inference_requests"], result.simulations)
        self.assertGreaterEqual(metrics["search_decisions"], 30)
        self.assertLessEqual(metrics["search_decisions"], result.decisions)
        self.assertEqual(metrics["search_simulations"], result.simulations)

    def test_native_search_flips_wdl_when_actor_changes(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["public_deck_keys"] = ["flip-a", "flip-b"]
        state["players"][0]["hand"] = []
        state["players"][1]["hand"] = []
        state["players"][0]["active"]["card_id"] = "svi-chim"
        state["players"][1]["active"]["card_id"] = "svi-chim"
        decks = {}
        for player_index, deck_key in enumerate(
            state["public_deck_keys"]
        ):
            player = state["players"][player_index]
            hidden_count = len(player["deck"]) + len(player["prizes"])
            player["deck"] = [
                f"{deck_key}-deck-{index}"
                for index in range(len(player["deck"]))
            ]
            player["prizes"] = [
                f"{deck_key}-prize-{index}"
                for index in range(len(player["prizes"]))
            ]
            decks[deck_key] = [
                player["active"]["card_id"],
                *[
                    f"{deck_key}-hidden-{index}"
                    for index in range(hidden_count)
                ],
            ]
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            991,
            {
                "simulations": 2,
                "max_depth": 4,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 25,
            },
        )
        deadline = time.monotonic() + 5.0
        while not job.finished:
            self.assertLess(time.monotonic(), deadline)
            tensors = batch.poll_inference(8, 50)
            request_ids = tensors["request_ids"]
            if request_ids.size == 0:
                continue
            wdl_logits = np.tile(
                np.asarray((20.0, 0.0, -20.0), np.float32),
                (request_ids.size, 1),
            )
            batch.submit_inference(
                request_ids,
                np.zeros(
                    tensors["candidate_mask"].shape,
                    dtype=np.float32,
                ),
                wdl_logits,
                tensors["candidate_mask"],
            )
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertEqual(result["simulations"], 2)
        self.assertEqual(result["visits"], [1])
        self.assertLess(result["value_sums"][0], -0.999)
        self.assertGreater(result["root_value"], 0.999)
        self.assertEqual(result["selected"]["kind"], "END_TURN")

    def test_native_search_depth_limit_backs_up_one_visit_per_simulation(self):
        state, decks = self._native_search_fixture()
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            731,
            {
                "simulations": 5,
                "max_depth": 1,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertEqual(result["simulations"], 5)
        # The first simulation expands the root; every later simulation
        # selects one root edge and must back up the depth-limit draw.
        self.assertEqual(sum(result["visits"]), 4)
        self.assertAlmostEqual(sum(result["value_sums"]), 0.0, places=6)

    def test_native_search_root_action_allowlist_filters_determinization_extras(
        self,
    ):
        state, decks = self._native_search_fixture()
        end_turn = next(
            action
            for action in self.game.legal_actions(state, 0)
            if action["kind"] == "END_TURN"
        )
        state["_native_root_allowed_actions"] = [copy.deepcopy(end_turn)]
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            0xA110CA7E,
            {
                "simulations": 3,
                "max_depth": 1,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "verify_candidate_cache": True,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertEqual(result["candidates"], [end_turn])
        self.assertEqual(result["selected"], end_turn)
        self.assertEqual(result["visits"], [2])

    def test_native_search_cancel_discards_late_inference_response(self):
        state, decks = self._native_search_fixture()
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            919,
            {
                "simulations": 8,
                "max_depth": 8,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        tensors = batch.poll_inference(8, 1000)
        self.assertEqual(tensors["request_ids"].size, 1)
        job.cancel()
        result = job.wait()
        self.assertFalse(result["success"])
        self.assertTrue(result["cancelled"], result)
        # The request was already removed from the pending queue. A device
        # worker can still finish it; submission must be safely ignored.
        batch.submit_inference(
            tensors["request_ids"],
            np.zeros(tensors["candidate_mask"].shape, np.float32),
            np.zeros((1, 3), np.float32),
            tensors["candidate_mask"],
        )

    def test_native_search_cancel_discards_multiple_pipelined_responses(self):
        state, decks = self._native_search_fixture()
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            0xCA11CE1,
            {
                "simulations": 16,
                "max_depth": 16,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
                "max_inflight_leaves": 4,
            },
        )
        root = batch.poll_inference(8, 1000, 4, 25)
        self.assertEqual(root["request_ids"].size, 1)
        batch.submit_inference(
            root["request_ids"],
            np.zeros(root["candidate_mask"].shape, np.float32),
            np.zeros((1, 3), np.float32),
            root["candidate_mask"],
        )
        leaves = batch.poll_inference(8, 1000, 4, 100)
        self.assertGreaterEqual(leaves["request_ids"].size, 2)
        job.cancel()
        result = job.wait()
        self.assertFalse(result["success"])
        self.assertTrue(result["cancelled"], result)
        batch.submit_inference(
            leaves["request_ids"],
            np.zeros(leaves["candidate_mask"].shape, np.float32),
            np.zeros(
                (leaves["request_ids"].size, 3),
                np.float32,
            ),
            leaves["candidate_mask"],
        )

    def test_puct_visits_and_contiguous_inference_queue(self):
        tree = ptcg_ai_core.PuctTree()
        node = tree.node(123, 0)
        node.expand([30, 10], [0.25, 0.75])
        self.assertEqual(node.select(1.4), 1)
        node.backup(1, 0.5)
        edge = node.edge(1)
        self.assertEqual(edge["visits"], 1)
        self.assertAlmostEqual(edge["q"], 0.5)

        virtual = tree.node(456, 0)
        virtual.expand([10, 20], [0.5, 0.5])
        self.assertEqual(virtual.select(1.4), 0)
        virtual.reserve(0)
        self.assertEqual(virtual.edge(0)["in_flight"], 1)
        self.assertEqual(virtual.edge(0)["visits"], 0)
        self.assertAlmostEqual(virtual.edge(0)["q"], 0.0)
        self.assertEqual(virtual.select(1.4), 1)
        virtual.release(0)
        self.assertEqual(virtual.select(1.4), 0)
        with self.assertRaises(RuntimeError):
            virtual.release(0)

        zeros_f = np.zeros
        zeros_i = np.zeros
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        request_id = batch.enqueue(
            zeros_f(128, np.float32),
            zeros_f((128, 16), np.float32),
            zeros_i(128, np.int64),
            zeros_i((128, 4), np.int64),
            zeros_f((3, 32), np.float32),
            zeros_i(3, np.int64),
            zeros_i(3, np.int64),
            zeros_i((3, 4), np.int64),
            2,
            7,
        )
        tensors = batch.poll_inference(8)
        self.assertTrue(all(value.flags.c_contiguous for value in tensors.values()))
        self.assertEqual(tensors["candidate_mask"].dtype, np.bool_)
        batch.submit_inference(
            tensors["request_ids"],
            np.zeros((1, 3), np.float32),
            np.zeros((1, 3), np.float32),
            tensors["candidate_mask"],
        )
        policy, wdl = batch.take_response(request_id)
        self.assertAlmostEqual(sum(policy), 1.0, places=6)
        self.assertAlmostEqual(sum(wdl), 1.0, places=6)
        batch.append_sample(
            zeros_f(128, np.float32),
            zeros_f((128, 16), np.float32),
            zeros_i(128, np.int64),
            zeros_i((128, 4), np.int64),
            zeros_f((3, 32), np.float32),
            zeros_i(3, np.int64),
            zeros_i(3, np.int64),
            zeros_i((3, 4), np.int64),
            2,
            7,
            np.asarray((0.2, 0.3, 0.5), np.float32),
            np.asarray((1.0, 0.0, 0.0), np.float32),
            4,
            1,
        )
        samples = batch.drain_samples()
        self.assertEqual(samples["policy_target"].shape, (1, 3))
        self.assertEqual(samples["wdl_target"].shape, (1, 3))
        self.assertEqual(samples["generation"].tolist(), [4])
        self.assertEqual(samples["actor"].tolist(), [1])
        self.assertTrue(
            all(value.flags.c_contiguous for value in samples.values())
        )

    def test_native_torch_broker_coalesces_contiguous_leaf_batches(self):
        try:
            import torch
        except ImportError:
            self.skipTest("torch is unavailable")

        class ZeroModel(torch.nn.Module):
            def forward(self, *inputs):
                candidates = inputs[4]
                batch_size, candidate_count = candidates.shape[:2]
                return (
                    torch.zeros(
                        (batch_size, candidate_count),
                        device=candidates.device,
                    ),
                    torch.zeros((batch_size, 3), device=candidates.device),
                )

        zeros_f = np.zeros
        zeros_i = np.zeros
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        with NativeBatchTorchBroker(
            batch,
            ZeroModel(),
            device="cpu",
            target_batch_size=4,
            max_batch_size=8,
            poll_wait_ms=50,
            amp=False,
        ) as broker:
            request_ids = [
                batch.enqueue(
                    zeros_f(128, np.float32),
                    zeros_f((128, 16), np.float32),
                    zeros_i(128, np.int64),
                    zeros_i((128, 4), np.int64),
                    zeros_f((3, 32), np.float32),
                    zeros_i(3, np.int64),
                    zeros_i(3, np.int64),
                    zeros_i((3, 4), np.int64),
                    2,
                    7,
                )
                for _ in range(4)
            ]
            deadline = time.monotonic() + 5.0
            responses = {}
            while len(responses) < len(request_ids):
                self.assertLess(time.monotonic(), deadline)
                for request_id in request_ids:
                    if request_id in responses:
                        continue
                    response = batch.take_response(request_id)
                    if response is not None:
                        responses[request_id] = response
                time.sleep(0.001)
            self.assertEqual(broker.request_count, 4)
            self.assertEqual(broker.max_observed_batch, 4)
            for policy, wdl in responses.values():
                self.assertAlmostEqual(sum(policy), 1.0, places=6)
                self.assertAlmostEqual(sum(wdl), 1.0, places=6)

    def test_all_80_vm_operations_match_frozen_direct_golden(self):
        fixture = self.vm_fixture
        cases = fixture["cases"]
        self.assertEqual(len(cases), 80)
        self.assertEqual(self.rules.card_count, len(self.cards))
        self.assertEqual(self.rules.implemented_op_count, 80)
        self.assertEqual(self.rules.required_op_count, 80)
        self.assertEqual(
            set(self.rules.implemented_ops),
            set(fixture["registered_ops"]),
        )

        for operation, row in cases.items():
            with self.subTest(operation=operation):
                result = self.rules.execute(
                    row["initial_state"],
                    row["command_spec"],
                    row["actor"],
                    row["source_slot"],
                    row["portable_seed"],
                    row["context_mode"],
                )
                actual = self._result_projection(result)
                for field, expected in row["expected"].items():
                    self.assertEqual(
                        actual[field],
                        expected,
                        f"{operation}.{field}",
                    )

    def test_all_33_vm_choice_rounds_match_frozen_golden(self):
        choice_rounds = 0
        continued_operations = 0
        for operation, row in self.vm_fixture["cases"].items():
            traces = row.get("choice_trace", [])
            if traces:
                continued_operations += 1
            result = self.rules.execute(
                row["initial_state"],
                row["command_spec"],
                row["actor"],
                row["source_slot"],
                row["portable_seed"],
                row["context_mode"],
            )
            for choice_index, trace in enumerate(traces):
                choice_rounds += 1
                with self.subTest(
                    operation=operation,
                    choice_index=choice_index,
                    phase="request",
                ):
                    self.assertEqual(result["pending"], trace["request"])
                response = trace["response"]
                result = self.rules.resume(
                    result["state"],
                    result["context"],
                    result["continuation"],
                    response["selected_options"],
                    response.get("cancelled", False),
                    result["rng_state"],
                )
                actual = self._result_projection(result)
                for field, expected in trace["expected"].items():
                    with self.subTest(
                        operation=operation,
                        choice_index=choice_index,
                        field=field,
                    ):
                        self.assertEqual(
                            actual[field],
                            expected,
                            f"{operation}[{choice_index}].{field}",
                        )
        self.assertEqual(continued_operations, 27)
        self.assertEqual(choice_rounds, 33)

    def test_native_grouped_card_choices_enforce_category_limits(self):
        arven_row = self.vm_fixture["cases"]["search_item_and_tool"]
        arven = self.rules.execute(
            arven_row["initial_state"],
            arven_row["command_spec"],
            arven_row["actor"],
            arven_row["source_slot"],
            arven_row["portable_seed"],
            arven_row["context_mode"],
        )
        self.assertTrue(arven["success"], arven)
        self.assertEqual(
            arven["pending"]["metadata"]["category_limits"],
            {"item": 1, "tool": 1},
        )
        arven_options = arven["pending"]["options"]

        two_items = [arven_options[0], arven_options[1]]
        rejected_arven = self.rules.resume(
            arven["state"],
            arven["context"],
            arven["continuation"],
            two_items,
            False,
            arven["rng_state"],
        )
        self.assertFalse(rejected_arven["success"])
        self.assertEqual(
            rejected_arven["error_code"],
            "arven_category_limit_exceeded",
        )

        mismatched = copy.deepcopy(arven_options[0])
        mismatched["card_id"] = arven_options[2]["card_id"]
        rejected_identity = self.rules.resume(
            arven["state"],
            arven["context"],
            arven["continuation"],
            [mismatched],
            False,
            arven["rng_state"],
        )
        self.assertFalse(rejected_identity["success"])
        self.assertEqual(
            rejected_identity["error_code"],
            "selected_card_identity_mismatch",
        )

        valid_arven = self.rules.resume(
            arven["state"],
            arven["context"],
            arven["continuation"],
            [arven_options[0], arven_options[2]],
            False,
            arven["rng_state"],
        )
        self.assertTrue(valid_arven["success"], valid_arven)
        self.assertIn("sv1-150", valid_arven["state"]["players"][0]["hand"])
        self.assertIn("sv1-201", valid_arven["state"]["players"][0]["hand"])

        clara_row = self.vm_fixture["cases"]["recover_clara"]
        clara_state = copy.deepcopy(clara_row["initial_state"])
        clara_state["players"][0]["discard"].append("svg2-lume")
        clara = self.rules.execute(
            clara_state,
            clara_row["command_spec"],
            clara_row["actor"],
            clara_row["source_slot"],
            clara_row["portable_seed"],
            clara_row["context_mode"],
        )
        self.assertTrue(clara["success"], clara)
        self.assertEqual(
            clara["pending"]["metadata"]["category_limits"],
            {"energy": 2, "pokemon": 2},
        )
        clara_options = clara["pending"]["options"]

        rejected_clara = self.rules.resume(
            clara["state"],
            clara["context"],
            clara["continuation"],
            clara_options[:3],
            False,
            clara["rng_state"],
        )
        self.assertFalse(rejected_clara["success"])
        self.assertEqual(
            rejected_clara["error_code"],
            "clara_category_limit_exceeded",
        )

        forged_special_energy = {
            "card_id": "svg2-lume",
            "index": len(clara_state["players"][0]["discard"]) - 1,
            "kind": "card",
            "player": 0,
            "zone": "discard",
        }
        rejected_special_energy = self.rules.resume(
            clara["state"],
            clara["context"],
            clara["continuation"],
            [forged_special_energy],
            False,
            clara["rng_state"],
        )
        self.assertFalse(rejected_special_energy["success"])
        self.assertEqual(
            rejected_special_energy["error_code"],
            "clara_selection_category_invalid",
        )

        valid_clara = self.rules.resume(
            clara["state"],
            clara["context"],
            clara["continuation"],
            [
                clara_options[0],
                clara_options[1],
                clara_options[3],
                clara_options[4],
            ],
            False,
            clara["rng_state"],
        )
        self.assertTrue(valid_clara["success"], valid_clara)
        recovered = valid_clara["state"]["players"][0]["hand"][-4:]
        self.assertEqual(
            recovered,
            ["sv1-ener-1", "sv1-ener-5", "sv1-104", "svg2-empo"],
        )

    def test_all_23_rule_action_goldens_match_native_game_kernel(self):
        fixture = self.rules_fixture
        self.assertEqual(fixture["fixture_version"], 3)
        self.assertEqual(len(fixture["cases"]), 23)
        self.assertEqual(self.game.card_count, len(self.game_cards))

        for case_name, row in fixture["cases"].items():
            with self.subTest(case=case_name):
                state = row["initial_state"]
                rng_state = row["portable_seed"]
                trace_index = 0
                last_result = None

                for action_index, action in enumerate(row.get("actions", [])):
                    result = self.game.apply_action(
                        state,
                        action,
                        rng_state,
                    )
                    last_result = result
                    trace = row["trace"][trace_index]
                    self.assertTrue(
                        result["success"],
                        (
                            f"{case_name}[{action_index}]: "
                            f"{result['error_code']}"
                        ),
                    )
                    self.assertEqual(
                        self._rule_state_projection(result["state"]),
                        trace["expected"],
                    )
                    self.assertEqual(
                        result["event_types"],
                        trace["event_types"],
                    )
                    self.assertEqual(
                        self._rule_pending_projection(result["pending"]),
                        self._rule_pending_projection(
                            trace.get("pending", {})
                        ),
                    )
                    self.assertEqual(
                        result["rng_state"],
                        trace["rng_state"],
                    )
                    state = result["state"]
                    rng_state = result["rng_state"]
                    trace_index += 1

                pending = row.get("pending_after_action", {})
                if pending:
                    self.assertIsNotNone(last_result)
                    self.assertEqual(
                        self._rule_pending_projection(last_result["pending"]),
                        self._rule_pending_projection(pending["request"]),
                    )
                    response = row["choice_response"]
                    result = self.game.resume_choice(
                        state,
                        last_result["continuation"],
                        response.get("selected_options", []),
                        response.get("cancelled", False),
                        rng_state,
                    )
                    trace = row["trace"][trace_index]
                    self.assertTrue(
                        result["success"],
                        f"{case_name}.choice: {result['error_code']}",
                    )
                    self.assertEqual(
                        self._rule_state_projection(result["state"]),
                        trace["expected"],
                    )
                    self.assertEqual(
                        result["event_types"],
                        trace["event_types"],
                    )
                    self.assertEqual(
                        self._rule_pending_projection(result["pending"]),
                        self._rule_pending_projection(
                            trace.get("pending", {})
                        ),
                    )
                    self.assertEqual(
                        result["rng_state"],
                        trace["rng_state"],
                    )
                    state = result["state"]
                    rng_state = result["rng_state"]
                    trace_index += 1

                for followup_index, action in enumerate(
                    row.get("followup_actions", [])
                ):
                    result = self.game.apply_action(
                        state,
                        action,
                        rng_state,
                    )
                    trace = row["trace"][trace_index]
                    self.assertTrue(
                        result["success"],
                        (
                            f"{case_name}.followup[{followup_index}]: "
                            f"{result['error_code']}"
                        ),
                    )
                    self.assertEqual(
                        self._rule_state_projection(result["state"]),
                        trace["expected"],
                    )
                    self.assertEqual(
                        result["event_types"],
                        trace["event_types"],
                    )
                    self.assertEqual(
                        result["rng_state"],
                        trace["rng_state"],
                    )
                    state = result["state"]
                    rng_state = result["rng_state"]
                    trace_index += 1

                self.assertEqual(trace_index, len(row["trace"]))
                self.assertEqual(
                    self._rule_state_projection(state),
                    row["expected"],
                )
                self.assertEqual(rng_state, row["expected_rng_state"])

    def test_native_effect_availability_and_zero_cost_retreat_match_rules(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]

        def pokemon(card_id, *, damage=0, energy=()):
            row = copy.deepcopy(owner["active"])
            row.update(
                {
                    "card_id": card_id,
                    "damage_counters": damage,
                    "energy_card_ids": list(energy),
                    "evolution_stack_ids": [],
                    "placed_this_turn": False,
                    "can_evolve_this_turn": True,
                    "used_abilities": [],
                    "status_conditions": [],
                }
            )
            return row

        owner["active"] = pokemon(
            "sv1-110",
            energy=("sv1-ener-5",),
        )
        owner["bench"] = [
            pokemon("sv1-104"),
            None,
            None,
            None,
            None,
        ]
        owner["hand"] = []
        owner["discard"] = []
        retreat = next(
            action
            for action in self.game.legal_actions(state, 0)
            if action["kind"] == "RETREAT"
        )
        retreated = self.game.apply_action(state, retreat, 71)
        self.assertTrue(retreated["success"], retreated)
        self.assertEqual(retreated["pending"], {})
        self.assertEqual(
            retreated["state"]["players"][0]["active"]["card_id"],
            "sv1-104",
        )
        self.assertEqual(
            retreated["state"]["players"][0]["bench"][0][
                "energy_card_ids"
            ],
            ["sv1-ener-5"],
        )

        owner["active"] = pokemon("svl-pikaex")
        owner["bench"] = [None, None, None, None, None]
        owner["hand"] = ["sv1-170"]
        self.assertFalse(
            any(
                action["kind"] == "PLAY_TRAINER"
                for action in self.game.legal_actions(state, 0)
            )
        )
        owner["bench"][0] = pokemon("svl-pikaex")
        self.assertTrue(
            any(
                action["kind"] == "PLAY_TRAINER"
                for action in self.game.legal_actions(state, 0)
            )
        )

        owner["active"] = pokemon("svl-flaa2")
        owner["bench"] = [
            pokemon("svl-pikaex"),
            None,
            None,
            None,
            None,
        ]
        owner["hand"] = []
        owner["discard"] = ["sv1-151"]
        self.assertFalse(
            any(
                action["kind"] == "USE_ABILITY"
                for action in self.game.legal_actions(state, 0)
            )
        )
        owner["discard"].append("sv1-ener-4")
        self.assertTrue(
            any(
                action["kind"] == "USE_ABILITY"
                for action in self.game.legal_actions(state, 0)
            )
        )

        owner["active"] = pokemon(
            "svf-hawl",
            energy=("sv1-ener-6",),
        )
        owner["bench"] = [
            pokemon("svf-rio"),
            None,
            None,
            None,
            None,
        ]
        owner["discard"] = ["sv1-151"]
        # An attack can still be declared when its search/attachment effect
        # will find no matching card; the effect then resolves as far as it can.
        self.assertTrue(
            any(
                action["kind"] == "DECLARE_ATTACK"
                and action["payload"]["attack_index"] == 0
                for action in self.game.legal_actions(state, 0)
            )
        )
        owner["discard"].append("sv1-ener-6")
        self.assertTrue(
            any(
                action["kind"] == "DECLARE_ATTACK"
                and action["payload"]["attack_index"] == 0
                for action in self.game.legal_actions(state, 0)
            )
        )

        owner["active"] = pokemon(
            "svd-morpeko",
            energy=("sv1-ener-7",),
        )
        owner["discard"] = []
        self.assertTrue(
            any(
                action["kind"] == "DECLARE_ATTACK"
                and action["payload"]["attack_index"] == 0
                for action in self.game.legal_actions(state, 0)
            )
        )

        owner["active"] = pokemon("svg-alt")
        owner["bench"] = [
            pokemon("svg-tatsu"),
            None,
            None,
            None,
            None,
        ]
        owner["discard"] = []
        self.assertFalse(
            any(
                action["kind"] == "USE_ABILITY"
                for action in self.game.legal_actions(state, 0)
            )
        )
        owner["bench"][0]["damage_counters"] = 1
        self.assertTrue(
            any(
                action["kind"] == "USE_ABILITY"
                for action in self.game.legal_actions(state, 0)
            )
        )

    def test_native_choice_candidates_cover_combinations_and_cancel(self):
        candidates = self.game.choice_candidates(
            {
                "request_id": "choice-17",
                "min_select": 1,
                "max_select": 2,
                "allow_duplicates": False,
                "can_cancel": True,
                "options": [
                    {"option_id": "a"},
                    {"option_id": "b"},
                    {"option_id": "c"},
                ],
            }
        )
        self.assertEqual(len(candidates), 7)
        self.assertEqual(
            [row["signature"] for row in candidates],
            [
                "choice:choice-17:a",
                "choice:choice-17:b",
                "choice:choice-17:c",
                "choice:choice-17:a|b",
                "choice:choice-17:a|c",
                "choice:choice-17:b|c",
                "choice:choice-17:cancel",
            ],
        )
        duplicate_candidates = self.game.choice_candidates(
            {
                "request_id": "choice-repeat",
                "min_select": 2,
                "max_select": 2,
                "allow_duplicates": True,
                "can_cancel": False,
                "options": [
                    {"option_id": "a"},
                    {"option_id": "b"},
                ],
            }
        )
        self.assertEqual(
            [row["selected_options"] for row in duplicate_candidates],
            [["a", "a"], ["a", "b"], ["b", "b"]],
        )

        energy_options = [
            {
                "option_id": (
                    f"energy:{energy_index}:sv1-ener-3"
                    f"->pokemon:0:{slot}:sv2-tatsu"
                ),
                "kind": "pokemon",
                "player": 0,
                "slot": slot,
                "card_id": "sv2-tatsu",
            }
            for slot in ("active", "bench_0")
            for energy_index in (0, 1)
        ]
        same_target_candidates = self.game.choice_candidates({
            "request_id": "choice-energy-same",
            "request_type": "distribute_energy",
            "min_select": 2,
            "max_select": 2,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": energy_options,
            "metadata": {"same_target": True, "max_per_target": 2},
        })
        self.assertEqual(len(same_target_candidates), 2)
        for candidate in same_target_candidates:
            selected = candidate["selected_options"]
            self.assertEqual(len(selected), 2)
            self.assertEqual(
                len({
                    option_id.split("->pokemon:0:", 1)[1].split(":", 1)[0]
                    for option_id in selected
                }),
                1,
            )
            self.assertEqual(
                {option_id.split(":", 2)[1] for option_id in selected},
                {"0", "1"},
            )

        distinct_target_candidates = self.game.choice_candidates({
            "request_id": "choice-energy-distinct",
            "request_type": "distribute_energy",
            "min_select": 2,
            "max_select": 2,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": energy_options,
            "metadata": {"same_target": False, "max_per_target": 1},
        })
        self.assertEqual(len(distinct_target_candidates), 2)

    def test_native_ultra_ball_auto_pays_the_only_legal_cost(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = [
            "sv1-153",
            "sv1-ener-1",
            "sv1-ener-2",
        ]
        owner["deck"] = ["sv1-104", "sv1-ener-3"]
        owner["discard"] = []

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-153"
        )
        result = self.game.apply_action(state, action, 0xA13F09C7)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "search_move")
        self.assertEqual(result["pending"]["min_select"], 0)
        self.assertEqual(result["pending"]["max_select"], 1)
        self.assertEqual(len(result["pending"]["options"]), 1)
        self.assertEqual(
            result["state"]["players"][0]["hand"],
            [],
        )
        self.assertEqual(
            result["state"]["players"][0]["discard"],
            ["sv1-ener-2", "sv1-ener-1", "sv1-153"],
        )
        self.assertEqual(
            result["event_types"],
            ["trainer_played", "cards_discarded"],
        )
        self.assertEqual(
            result["state"]["choice_sequence"],
            state["choice_sequence"] + 1,
        )

    def test_native_named_discard_search_only_exposes_matching_cards(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = ["svi-nemb"]
        owner["discard"] = ["sv1-151", "sv1-180", "sv1-180"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svi-nemb"
        )
        result = self.game.apply_action(state, action, 0x4E454D4F)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "search_move")
        self.assertEqual(result["pending"]["min_select"], 0)
        self.assertEqual(result["pending"]["max_select"], 2)
        self.assertEqual(
            [
                (option["card_id"], option["index"])
                for option in result["pending"]["options"]
            ],
            [("sv1-180", 1), ("sv1-180", 2)],
        )

    def test_native_empty_deck_search_shuffles_without_pending_choice(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = ["sv1-151"]
        owner["deck"] = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
        owner["discard"] = []

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-151"
        )
        result = self.game.apply_action(state, action, 0x00012345)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(result["state"]["choice_sequence"], 0)
        self.assertEqual(
            sorted(result["state"]["players"][0]["deck"]),
            ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"],
        )
        self.assertIn("deck_shuffled", result["event_types"])

    def test_native_paid_hidden_search_can_find_zero_matching_cards(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["hand"] = ["sv1-153", "sv1-ener-2", "sv1-ener-2"]
        owner["deck"] = ["sv1-ener-2"]
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-153"
        )
        result = self.game.apply_action(state, action, 0x5A45524F)
        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(result["state"]["players"][0]["hand"], [])
        self.assertEqual(
            result["state"]["players"][0]["discard"].count("sv1-ener-2"),
            2,
        )
        self.assertIn("sv1-153", result["state"]["players"][0]["discard"])
        self.assertIn("deck_shuffled", result["event_types"])

    def test_native_discard_then_draw_attack_suspends_and_resumes(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update({
            "card_id": "svl-chat",
            "damage_counters": 0,
            "energy_card_ids": ["sv1-ener-1"],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "status_conditions": [],
        })
        owner["hand"] = ["sv1-151", "sv1-180", "sv1-ener-1"]
        owner["deck"] = ["sv1-150", "sv1-153", "sv1-ener-1"]
        owner["discard"] = []

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        suspended = self.game.apply_action(state, action, 0x00000017)

        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(suspended["pending"]["request_type"], "search_move")
        self.assertEqual(suspended["pending"]["min_select"], 1)
        self.assertEqual(suspended["pending"]["max_select"], 1)
        self.assertFalse(suspended["pending"]["can_cancel"])
        self.assertEqual(suspended["state"]["active_player_idx"], 0)

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [suspended["pending"]["options"][1]],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(resumed["pending"], {})
        self.assertEqual(resumed["state"]["active_player_idx"], 1)
        self.assertEqual(
            resumed["state"]["players"][0]["discard"],
            ["sv1-180"],
        )
        self.assertEqual(
            resumed["state"]["players"][0]["hand"],
            ["sv1-151", "sv1-ener-1", "sv1-ener-1", "sv1-153"],
        )

    def test_native_houb_accepts_one_other_card_and_only_auto_selects_it(self):
        base = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        base.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = base["players"][0]
        owner["supporter_played_this_turn"] = False
        owner["deck"] = ["sv1-ener-1"] * 8
        owner["hand"] = ["svf-houb", "svi-chim"]

        action = next(
            row
            for row in self.game.legal_actions(base, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svf-houb"
        )
        auto = self.game.apply_action(base, action, 0x484F5542)
        self.assertTrue(auto["success"], auto)
        self.assertEqual(auto["pending"], {})
        self.assertEqual(len(auto["state"]["players"][0]["hand"]), 5)
        self.assertIn("card_moved", auto["event_types"])
        moved = next(
            event
            for event in auto["events"]
            if event["event_type"] == "card_moved"
        )
        self.assertEqual(moved["data"]["card_ids"], ["svi-chim"])

        selectable = copy.deepcopy(base)
        selectable["players"][0]["hand"] = [
            "svf-houb",
            "svi-chim",
            "sv1-151",
        ]
        selectable_action = next(
            row
            for row in self.game.legal_actions(selectable, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svf-houb"
        )
        suspended = self.game.apply_action(
            selectable,
            selectable_action,
            0x484F5543,
        )
        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(suspended["pending"]["request_type"], "houb")
        self.assertEqual(len(suspended["pending"]["options"]), 2)

    def test_native_draw_supporter_preflight_uses_post_play_hand(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["supporter_played_this_turn"] = False
        owner["deck"] = ["sv1-ener-1"] * 4
        opponent["hand"] = ["sv1-151"]

        # After Beri itself leaves the hand, two cards already equal the
        # required opponent+1 target, so the Supporter would do nothing.
        owner["hand"] = ["svg-beri", "sv1-151", "sv1-150"]
        self.assertFalse(any(
            row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svg-beri"
            for row in self.game.legal_actions(state, 0)
        ))

        owner["hand"] = ["svg-beri"]
        self.assertTrue(any(
            row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svg-beri"
            for row in self.game.legal_actions(state, 0)
        ))
        owner["deck"] = []
        self.assertFalse(any(
            row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svg-beri"
            for row in self.game.legal_actions(state, 0)
        ))

    def test_native_required_discard_energy_attach_cannot_cancel(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = ["svm-marnie-pride"]
        owner["discard"] = ["sv1-ener-8"]
        target = copy.deepcopy(owner["active"])
        owner["bench"] = [
            target,
            copy.deepcopy(target),
            None,
            None,
            None,
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svm-marnie-pride"
        )
        result = self.game.apply_action(state, action, 0x4D41524E)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "distribute_energy")
        self.assertEqual(result["pending"]["min_select"], 1)
        self.assertEqual(result["pending"]["max_select"], 1)
        self.assertFalse(result["pending"]["can_cancel"])

    def test_native_energy_discard_rejects_duplicate_or_stale_attachments(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        active = state["players"][0]["active"]
        active.update({
            "card_id": "sv1-111",
            "damage_counters": 0,
            "energy_card_ids": ["sv1-ener-5"] * 4,
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "status_conditions": [],
            "modifiers": [],
        })
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        suspended = self.game.apply_action(state, action, 0x4C415449)
        self.assertTrue(suspended["success"], suspended)
        options = suspended["pending"]["options"]
        self.assertEqual(len(options), 4)

        duplicate = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [options[0], options[0], options[1]],
            False,
            suspended["rng_state"],
        )
        self.assertFalse(duplicate["success"])
        self.assertEqual(
            duplicate["error_code"],
            "duplicate_energy_discard_selection",
        )

        stale = copy.deepcopy(options[:3])
        stale[0]["card_id"] = "sv1-ener-1"
        rejected_stale = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            stale,
            False,
            suspended["rng_state"],
        )
        self.assertFalse(rejected_stale["success"])
        self.assertEqual(
            rejected_stale["error_code"],
            "energy_discard_selection_invalid",
        )

        resolved = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            options[:3],
            False,
            suspended["rng_state"],
        )
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(
            resolved["state"]["players"][0]["active"]["energy_card_ids"],
            ["sv1-ener-5"],
        )

    def test_native_marnie_single_target_still_selects_discard_source(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = ["svm-marnie-pride"]
        owner["discard"] = ["sv1-ener-8", "sv1-ener-1"]
        target = copy.deepcopy(owner["active"])
        owner["bench"] = [target, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svm-marnie-pride"
        )
        result = self.game.apply_action(state, action, 0x4D41524F)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "distribute_energy")
        self.assertEqual(result["pending"]["min_select"], 1)
        self.assertEqual(result["pending"]["max_select"], 1)
        self.assertEqual(len(result["pending"]["options"]), 2)
        self.assertEqual(
            {
                option["option_id"].split(":", 2)[2].split("->", 1)[0]
                for option in result["pending"]["options"]
            },
            {"sv1-ener-8", "sv1-ener-1"},
        )

    def test_native_conditional_search_is_optional_on_second_players_first_turn(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 2
        state["first_player_idx"] = 0
        state["active_player_idx"] = 1
        owner = state["players"][1]
        owner["active"].update(
            {
                "card_id": "svg2-zaru",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-1"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        owner["deck"] = [
            "sv1-151",
            "svg2-zaru",
            "sv1-ener-1",
            "svg2-zaru",
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 1)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x5A415255)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "search_move")
        self.assertEqual(result["pending"]["min_select"], 0)
        self.assertEqual(result["pending"]["max_select"], 2)
        self.assertTrue(result["pending"]["can_cancel"])
        self.assertEqual(
            [option["card_id"] for option in result["pending"]["options"]],
            ["svg2-zaru", "svg2-zaru"],
        )

    def test_native_bench_search_caps_duplicate_cards_to_open_slots(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svi-sqwk",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-1"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
                "modifiers": [],
            }
        )
        bench_card = copy.deepcopy(owner["active"])
        bench_card["card_id"] = "sv2-delib"
        bench_card["energy_card_ids"] = []
        owner["bench"] = [
            copy.deepcopy(bench_card),
            copy.deepcopy(bench_card),
            copy.deepcopy(bench_card),
            copy.deepcopy(bench_card),
            None,
        ]
        owner["deck"] = ["svi-chim", "svi-chim", "sv1-ener-2"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        suspended = self.game.apply_action(state, action, 0x5351574B)

        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(suspended["pending"]["request_type"], "search_move")
        self.assertEqual(suspended["pending"]["max_select"], 1)
        self.assertEqual(len(suspended["pending"]["options"]), 2)
        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [suspended["pending"]["options"][1]],
            False,
            suspended["rng_state"],
        )
        self.assertTrue(resumed["success"], resumed)
        player = resumed["state"]["players"][0]
        self.assertEqual(player["bench"][4]["card_id"], "svi-chim")
        self.assertEqual(player["deck"].count("svi-chim"), 1)
        self.assertEqual(
            player["deck"].count("svi-chim")
            + sum(
                pokemon is not None
                and pokemon.get("card_id") == "svi-chim"
                for pokemon in player["bench"]
            ),
            2,
        )

    def test_native_shuffle_recovery_excludes_special_energy(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = ["sv3-134"]
        owner["discard"] = ["svg2-zaru", "sv1-ener-1", "svi-dtur"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv3-134"
        )
        result = self.game.apply_action(state, action, 0x53563134)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            {option["card_id"] for option in result["pending"]["options"]},
            {"svg2-zaru", "sv1-ener-1"},
        )
        self.assertNotIn(
            "svi-dtur",
            [option["card_id"] for option in result["pending"]["options"]],
        )

    def test_native_optional_attack_attach_accepts_empty_selection(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svl-thun",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-4"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        target = copy.deepcopy(owner["active"])
        target["energy_card_ids"] = []
        owner["bench"] = [target, None, None, None, None]
        owner["hand"] = [
            "sv1-ener-4",
            "sv1-ener-4",
            "sv1-ener-4",
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        suspended = self.game.apply_action(state, action, 0x5448554E)
        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(
            suspended["pending"]["request_type"],
            "distribute_energy",
        )
        self.assertEqual(suspended["pending"]["min_select"], 0)
        self.assertEqual(len(suspended["pending"]["options"]), 1)

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(resumed["pending"], {})
        self.assertEqual(
            resumed["state"]["players"][0]["hand"],
            ["sv1-ener-4", "sv1-ener-4", "sv1-ener-4"],
        )
        self.assertEqual(
            resumed["state"]["players"][0]["bench"][0]["energy_card_ids"],
            [],
        )
        self.assertEqual(resumed["state"]["active_player_idx"], 1)

    def test_native_starmie_single_target_auto_resolves_ability(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "sv2-starm",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": ["sv2-star"],
                "attached_tool_id": "",
                "status_conditions": [],
                "used_abilities": [],
            }
        )
        owner["bench"] = [
            copy.deepcopy(owner["active"]),
            None,
            None,
            None,
            None,
        ]
        opponent["bench"] = [None, None, None, None, None]
        before = opponent["active"]["damage_counters"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "USE_ABILITY"
            and row["source"]["card_id"] == "sv2-starm"
        )
        result = self.game.apply_action(state, action, 0x53544152)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertIsNone(result["state"]["players"][0]["active"])
        self.assertEqual(result["state"]["pending_promotions"], [0])
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            before + 2,
        )

    def test_native_gardenia_attaches_all_selected_energy_to_first_target(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        first_target = copy.deepcopy(owner["active"])
        second_target = copy.deepcopy(owner["active"])
        first_target["energy_card_ids"] = []
        second_target["energy_card_ids"] = []
        owner["bench"] = [
            first_target,
            second_target,
            None,
            None,
            None,
        ]
        owner["hand"] = ["svg2-gard"]
        owner["deck"] = ["sv1-151", "sv1-ener-1", "sv1-ener-1"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svg2-gard"
        )
        suspended = self.game.apply_action(state, action, 0x47415244)
        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(
            suspended["pending"]["request_type"],
            "distribute_energy",
        )
        self.assertTrue(suspended["pending"]["metadata"]["same_target"])
        self.assertEqual(
            suspended["pending"]["metadata"]["max_per_target"],
            2,
        )
        mismatched = [
            next(
                option
                for option in suspended["pending"]["options"]
                if option["slot"] == "bench_0"
                and option["option_id"].startswith("energy:0:")
            ),
            next(
                option
                for option in suspended["pending"]["options"]
                if option["slot"] == "bench_1"
                and option["option_id"].startswith("energy:1:")
            ),
        ]
        rejected = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            mismatched,
            False,
            suspended["rng_state"],
        )
        self.assertFalse(rejected["success"])
        self.assertEqual(
            rejected["error_code"],
            "energy_distribution_target_mismatch",
        )
        selected = [
            next(
                option
                for option in suspended["pending"]["options"]
                if option["slot"] == "bench_0"
                and option["option_id"].startswith("energy:0:")
            ),
            next(
                option
                for option in suspended["pending"]["options"]
                if option["slot"] == "bench_0"
                and option["option_id"].startswith("energy:1:")
            ),
        ]

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            selected,
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(
            resumed["state"]["players"][0]["bench"][0]["energy_card_ids"],
            ["sv1-ener-1", "sv1-ener-1"],
        )
        self.assertEqual(
            resumed["state"]["players"][0]["bench"][1]["energy_card_ids"],
            [],
        )

    def test_native_gardenia_draw_is_legal_without_a_bench(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["hand"] = ["svg2-gard"]
        owner["deck"] = ["sv1-151", "sv1-ener-1"]
        owner["bench"] = [None, None, None, None, None]
        owner["supporter_played_this_turn"] = False

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svg2-gard"
        )
        resolved = self.game.apply_action(state, action, 0x47415245)
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(resolved["pending"], {})
        self.assertEqual(
            resolved["state"]["players"][0]["hand"],
            ["sv1-ener-1", "sv1-151"],
        )
        self.assertEqual(
            resolved["event_types"],
            ["trainer_played", "cards_drawn"],
        )

        empty_deck = copy.deepcopy(state)
        empty_deck["players"][0]["deck"] = []
        empty_deck["players"][0]["bench"][0] = copy.deepcopy(
            empty_deck["players"][0]["active"]
        )
        empty_deck["players"][0]["hand"] = [
            "svg2-gard",
            "sv1-ener-1",
        ]
        self.assertFalse(any(
            row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svg2-gard"
            for row in self.game.legal_actions(empty_deck, 0)
        ))

    def test_native_chi_yu_attaches_all_discard_energy_to_first_target(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svi-chiy",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-2"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        target = copy.deepcopy(owner["active"])
        target["energy_card_ids"] = []
        owner["bench"] = [target, None, None, None, None]
        owner["discard"] = ["sv1-ener-2", "sv1-ener-2"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        suspended = self.game.apply_action(state, action, 0x43484959)
        self.assertTrue(suspended["success"], suspended)
        selected = [
            next(
                option
                for option in suspended["pending"]["options"]
                if option["slot"] == "active"
                and option["option_id"].startswith("energy:0:")
            ),
            next(
                option
                for option in suspended["pending"]["options"]
                if option["slot"] == "active"
                and option["option_id"].startswith("energy:1:")
            ),
        ]

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            selected,
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(
            resumed["state"]["players"][0]["active"]["energy_card_ids"],
            ["sv1-ener-2", "sv1-ener-2", "sv1-ener-2"],
        )
        self.assertEqual(
            resumed["state"]["players"][0]["bench"][0]["energy_card_ids"],
            [],
        )

    def test_native_discard_zone_ability_revives_source_and_draws(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = []
        owner["discard"] = ["sv1-151", "svg2-empo"]
        owner["deck"] = ["sv1-150", "sv1-153", "sv1-176"]
        owner["bench"] = [None, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "USE_ABILITY"
            and row["source"]["card_id"] == "svg2-empo"
            and row["source"]["zone"] == "discard"
        )
        result = self.game.apply_action(state, action, 0x454D504F)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["state"]["players"][0]["deck"], [])
        self.assertEqual(
            result["state"]["players"][0]["hand"],
            ["sv1-176", "sv1-153", "sv1-150"],
        )
        self.assertEqual(
            result["state"]["players"][0]["discard"],
            ["sv1-151"],
        )
        revived = result["state"]["players"][0]["bench"][0]
        self.assertEqual(revived["card_id"], "svg2-empo")
        self.assertEqual(len(revived["used_abilities"]), 1)

    def test_native_returning_attacker_queues_both_required_promotions(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "sv2-tatsu",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-3"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        owner_bench = copy.deepcopy(owner["active"])
        owner_bench["card_id"] = "sv1-104"
        owner_bench["energy_card_ids"] = []
        owner["bench"] = [owner_bench, None, None, None, None]
        opponent["active"]["damage_counters"] = 999
        opponent_bench = copy.deepcopy(opponent["active"])
        opponent_bench["damage_counters"] = 0
        opponent["bench"] = [
            opponent_bench,
            None,
            None,
            None,
            None,
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        result = self.game.apply_action(state, action, 0x54415453)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "select_prize")
        self.assertIsNone(result["state"]["players"][0]["active"])
        self.assertIsNone(result["state"]["players"][1]["active"])
        self.assertEqual(result["state"]["pending_promotions"], [1, 0])

    def test_native_tatsugiri_energy_distribution_is_protocol_bounded(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"].update(
            card_id="sv2-tatsu",
            damage_counters=0,
            energy_card_ids=["sv1-ener-3"],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
        )
        owner["bench"] = []
        for _index in range(5):
            bench = copy.deepcopy(owner["active"])
            bench["energy_card_ids"] = []
            owner["bench"].append(bench)
        owner["deck"] = ["sv1-ener-3"] * 20
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )

        result = self.game.apply_action(state, action, 17)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "distribute_energy")
        self.assertEqual(result["pending"]["min_select"], 0)
        self.assertEqual(result["pending"]["max_select"], 2)
        self.assertEqual(len(result["pending"]["options"]), 12)
        metadata = result["pending"]["metadata"]
        self.assertTrue(metadata["same_target"])
        self.assertEqual(metadata["max_per_target"], 2)
        self.assertEqual(metadata["source_zone"], "deck")
        self.assertEqual(metadata["card_ids"], ["sv1-ener-3"] * 2)

        same_target = [
            option
            for option in result["pending"]["options"]
            if option["slot"] == "bench_0"
        ][:2]
        resolved = self.game.resume_choice(
            result["state"],
            result["continuation"],
            same_target,
            False,
            result["rng_state"],
        )
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(
            resolved["state"]["players"][0]["bench"][0][
                "energy_card_ids"
            ],
            ["sv1-ener-3", "sv1-ener-3"],
        )

        first_source_two_targets = [
            next(
                option
                for option in result["pending"]["options"]
                if option["slot"] == slot
                and option["option_id"].startswith("energy:0:")
            )
            for slot in ("bench_0", "bench_1")
        ]
        duplicate_source = self.game.resume_choice(
            result["state"],
            result["continuation"],
            first_source_two_targets,
            False,
            result["rng_state"],
        )
        self.assertFalse(duplicate_source["success"])
        self.assertEqual(
            duplicate_source["error_code"],
            "energy_distribution_selection_invalid",
        )

        mismatched_targets = [
            next(
                option
                for option in result["pending"]["options"]
                if option["slot"] == slot
                and option["option_id"].startswith(f"energy:{index}:")
            )
            for index, slot in enumerate(("bench_0", "bench_1"))
        ]
        mismatched = self.game.resume_choice(
            result["state"],
            result["continuation"],
            mismatched_targets,
            False,
            result["rng_state"],
        )
        self.assertFalse(mismatched["success"])
        self.assertEqual(
            mismatched["error_code"],
            "energy_distribution_target_mismatch",
        )

    def test_native_chi_yu_discard_distribution_is_protocol_bounded(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"].update(
            card_id="svi-chiy",
            damage_counters=0,
            energy_card_ids=["sv1-ener-2"],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
        )
        owner["bench"] = []
        for _index in range(5):
            bench = copy.deepcopy(owner["active"])
            bench["card_id"] = "svi-chim"
            bench["energy_card_ids"] = []
            owner["bench"].append(bench)
        owner["discard"] = ["sv1-ener-2"] * 20
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )

        result = self.game.apply_action(state, action, 17)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "distribute_energy")
        self.assertEqual(result["pending"]["min_select"], 0)
        self.assertEqual(result["pending"]["max_select"], 2)
        self.assertEqual(len(result["pending"]["options"]), 12)

    def test_native_source_select_deduplicates_physical_energy_copies(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"].update(
            card_id="svm-cobalion",
            damage_counters=0,
            energy_card_ids=["sv1-ener-8", "sv1-ener-8"],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
        )
        owner["bench"] = []
        for _index in range(5):
            bench = copy.deepcopy(owner["active"])
            bench["card_id"] = "svm-zacian"
            bench["energy_card_ids"] = []
            owner["bench"].append(bench)
        owner["deck"] = ["sv1-ener-8"] * 20
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )

        result = self.game.apply_action(state, action, 17)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "distribute_energy")
        self.assertEqual(result["pending"]["min_select"], 0)
        self.assertEqual(result["pending"]["max_select"], 2)
        self.assertEqual(len(result["pending"]["options"]), 10)
        metadata = result["pending"]["metadata"]
        self.assertFalse(metadata["same_target"])
        self.assertEqual(metadata["max_per_target"], 1)
        self.assertEqual(metadata["source_zone"], "deck")
        self.assertEqual(metadata["card_ids"], ["sv1-ener-8"] * 2)
        same_target = [
            option
            for option in result["pending"]["options"]
            if option["slot"] == "bench_0"
        ][:2]
        rejected = self.game.resume_choice(
            result["state"],
            result["continuation"],
            same_target,
            False,
            result["rng_state"],
        )
        self.assertFalse(rejected["success"])
        self.assertEqual(
            rejected["error_code"],
            "energy_distribution_target_capacity_exceeded",
        )

    def test_native_mela_executes_condition_branch_without_discard_cost(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["hand"] = ["svi-mela"]
        owner["discard"] = ["sv1-ener-2"]
        owner["supporter_played_this_turn"] = False
        state["turn_fact_book"] = {
            "previous_turn": {
                "knockouts": [{
                    "defeated_player": 0,
                    "source_player": 1,
                    "source_kind": "attack_damage",
                }],
            },
            "current_turn": {"knockouts": []},
        }
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
        )

        result = self.game.apply_action(state, action, 17)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertIn(
            "sv1-ener-2",
            result["state"]["players"][0]["active"]["energy_card_ids"],
        )
        self.assertNotIn(
            "sv1-ener-2",
            result["state"]["players"][0]["discard"],
        )
        self.assertIn("svi-mela", result["state"]["players"][0]["discard"])
        self.assertIn("energy_attached", result["event_types"])
        self.assertIn("cards_drawn", result["event_types"])

        missing_source = copy.deepcopy(state)
        missing_source["players"][0]["discard"] = []
        self.assertFalse(any(
            row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "svi-mela"
            for row in self.game.legal_actions(missing_source, 0)
        ))

    def test_native_targeted_damage_consumes_outgoing_reduction(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        attacker = state["players"][0]["active"]
        attacker.update(
            card_id="sv2-grex",
            energy_card_ids=["sv1-ener-3"],
            damage_counters=0,
            outgoing_damage_reduction=30,
        )
        state["players"][1]["active"]["damage_counters"] = 0
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        suspended = self.game.apply_action(state, action, 17)
        selected = next(
            option
            for option in suspended["pending"]["options"]
            if option.get("slot") == "active"
        )

        result = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [selected],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            1,
        )
        self.assertEqual(
            result["state"]["players"][0]["active"][
                "outgoing_damage_reduction"
            ],
            0,
        )

    def test_native_search_any_switch_skips_confirm_without_bench(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"].update(
            card_id="svg-tatsu",
            energy_card_ids=["sv1-ener-5", "sv1-ener-5"],
            damage_counters=0,
        )
        owner["bench"] = [None] * 5
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        suspended = self.game.apply_action(state, action, 17)
        self.assertEqual(
            suspended["pending"]["request_type"],
            "search_any_switch",
        )
        search_candidates = self.game.choice_candidates(
            suspended["pending"]
        )
        encoded = ptcg_ai_core.NativeInformationSetEncoder(
            self.game_cards
        ).encode_choices(
            ptcg_ai_core.project_information_set(
                suspended["state"],
                0,
            )["observation"],
            suspended["pending"],
            search_candidates,
        )
        self.assertEqual(
            encoded["candidate_numeric"].shape[1],
            len(search_candidates),
        )

        result = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [suspended["pending"]["options"][0]],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(result["state"]["active_player_idx"], 1)

    def test_native_ability_effect_ko_awards_prize_after_self_discard(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"].update(
            card_id="sv2-starm",
            energy_card_ids=[],
            damage_counters=0,
            used_abilities=[],
        )
        owner["bench"] = [
            {
                **copy.deepcopy(owner["active"]),
                "card_id": "sv2-staryu",
            },
            None,
            None,
            None,
            None,
        ]
        opponent = state["players"][1]
        opponent["active"]["damage_counters"] = 999
        opponent["bench"] = [None] * 5
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "USE_ABILITY"
        )

        result = self.game.apply_action(state, action, 17)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["pending"]["request_type"],
            "select_prize",
        )
        self.assertIsNone(result["state"]["players"][0]["active"])
        self.assertIsNone(result["state"]["players"][1]["active"])
        self.assertEqual(result["state"]["pending_promotions"], [0])

    def test_native_ex_knockout_queues_both_prize_choices(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"].update(
            card_id="svd-dodrio",
            energy_card_ids=["sv1-ener-5"],
            damage_counters=0,
        )
        opponent = state["players"][1]
        opponent["active"].update(
            card_id="sv2-grex",
            damage_counters=29,
        )
        opponent["bench"] = [
            {
                **copy.deepcopy(opponent["active"]),
                "card_id": "sv2-staryu",
                "damage_counters": 0,
            },
            None,
            None,
            None,
            None,
        ]
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        first = self.game.apply_action(state, action, 17)

        second = self.game.resume_choice(
            first["state"],
            first["continuation"],
            [first["pending"]["options"][0]],
            False,
            first["rng_state"],
        )

        self.assertTrue(second["success"], second)
        self.assertEqual(first["pending"]["request_type"], "select_prize")
        self.assertEqual(second["pending"]["request_type"], "select_prize")
        self.assertEqual(
            second["continuation"]["remaining_prize_players"],
            [],
        )

    def test_native_direct_ko_without_bench_has_no_phantom_promotion(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["players"][1]["bench"] = [None] * 5
        command = {
            "op": "flip_coin_then_ko",
            "args": {},
            "branches": {},
        }
        suspended = self.rules.execute(
            state,
            command,
            0,
            "active",
            2,
            "attack",
        )
        self.assertEqual(suspended["continuation"]["flips"], [True, True])

        result = self.rules.resume(
            suspended["state"],
            suspended["context"],
            suspended["continuation"],
            [],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(result["state"]["pending_promotions"], [])
        self.assertEqual(result["pending"]["request_type"], "select_prize")

    def test_native_resumed_prevent_all_has_two_canonical_modifiers(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svi-sqwk",
                "damage_counters": 0,
                "energy_card_ids": ["svi-dtur"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
                "modifiers": [],
            }
        )

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        suspended = self.game.apply_action(state, action, 2)
        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(suspended["pending"]["request_type"], "coin_flip")

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        modifiers = resumed["state"]["players"][0]["active"]["modifiers"]
        self.assertEqual(
            {entry["hook"] for entry in modifiers},
            {"MODIFY_DAMAGE", "PREVENT_EFFECTS"},
        )
        self.assertTrue(all("native_op" not in entry for entry in modifiers))
        protected = resumed["state"]["players"][0]["active"]
        self.assertTrue(protected["damage_prevented"])
        self.assertTrue(protected["all_prevented"])

    def test_native_prevent_effects_blocks_status_and_direct_knockout(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        protected = state["players"][1]["active"]
        protected["all_prevented"] = False
        protected["modifiers"] = [{
            "hook": "PREVENT_EFFECTS",
            "operation": {"kind": "prevent_effects"},
            "duration": "until_end_of_opponents_next_turn",
            "condition": {"expires_after_turn": 4},
        }]
        status = self.rules.execute(
            state,
            {
                "op": "apply_status",
                "args": {"status": "asleep", "target": "opponent_active"},
                "branches": {},
            },
            0,
            "active",
            0x53544154,
            "attack",
        )
        self.assertTrue(status["success"], status)
        self.assertEqual(
            status["state"]["players"][1]["active"]["status_conditions"],
            [],
        )
        self.assertNotIn("status_applied", status["event_types"])

        suspended = self.rules.execute(
            state,
            {"op": "flip_coin_then_ko", "args": {}, "branches": {}},
            0,
            "active",
            2,
            "attack",
        )
        self.assertEqual(suspended["continuation"]["flips"], [True, True])
        direct_ko = self.rules.resume(
            suspended["state"],
            suspended["context"],
            suspended["continuation"],
            [],
            False,
            suspended["rng_state"],
        )
        self.assertTrue(direct_ko["success"], direct_ko)
        self.assertIsNotNone(direct_ko["state"]["players"][1]["active"])
        self.assertNotIn("pokemon_ko", direct_ko["event_types"])

    def test_native_type_matchups_apply_only_to_active_attack_damage(self):
        cards = copy.deepcopy(self.game_cards)
        cards["audit-fire"] = {
            "name": "Audit Fire",
            "supertype": "Pokémon",
            "subtypes": ["Basic"],
            "energy_types": ["Fire"],
            "hp": 120,
            "attacks": [
                {
                    "name": "Weakness Hit",
                    "damage": 30,
                    "cost": [],
                    "compiled_effects": [],
                },
                {
                    "name": "Bench Hit",
                    "damage": 0,
                    "cost": [],
                    "compiled_effects": [{
                        "op": "choose_damage_target",
                        "args": {
                            "amount": 30,
                            "player": "opponent",
                            "bench_skips_type_matchups": True,
                        },
                        "branches": {},
                    }],
                },
            ],
            "abilities": [],
            "weaknesses": [],
            "resistances": [],
            "prize_value": 1,
        }
        cards["audit-weak"] = {
            "name": "Audit Weak",
            "supertype": "Pokémon",
            "subtypes": ["Basic"],
            "energy_types": ["Grass"],
            "hp": 200,
            "attacks": [],
            "abilities": [],
            "weaknesses": [{"energy_type": "Fire", "value": "×2"}],
            "resistances": [],
            "prize_value": 1,
        }
        game = ptcg_ai_core.NativeGameKernel(cards)
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
            apply_type_matchups=True,
        )
        state["rules_options"]["apply_type_matchups"] = True
        state["players"][0]["active"].update(
            card_id="audit-fire",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
        )
        state["players"][1]["active"].update(
            card_id="audit-weak",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
        )
        weak_action = next(
            row
            for row in game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        weak_result = game.apply_action(state, weak_action, 0x5745414B)
        self.assertTrue(weak_result["success"], weak_result)
        self.assertEqual(
            weak_result["state"]["players"][1]["active"]["damage_counters"],
            6,
        )

        bench_state = copy.deepcopy(state)
        bench_target = copy.deepcopy(bench_state["players"][1]["active"])
        bench_state["players"][1]["bench"] = [
            bench_target,
            None,
            None,
            None,
            None,
        ]
        bench_action = next(
            row
            for row in game.legal_actions(bench_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        suspended_bench = game.apply_action(
            bench_state, bench_action, 0x42454E43)
        self.assertTrue(suspended_bench["success"], suspended_bench)
        selected_bench = next(
            option
            for option in suspended_bench["pending"]["options"]
            if option.get("slot") == "bench_0"
        )
        bench_result = game.resume_choice(
            suspended_bench["state"],
            suspended_bench["continuation"],
            [selected_bench],
            False,
            suspended_bench["rng_state"],
        )
        self.assertTrue(bench_result["success"], bench_result)
        self.assertEqual(
            bench_result["state"]["players"][1]["bench"][0][
                "damage_counters"
            ],
            3,
        )

    def test_native_zero_damage_attack_is_not_raised_by_tool_modifier(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "svl-chat",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-4"],
                "evolution_stack_ids": [],
                "attached_tool_id": "svl-vitb",
                "status_conditions": [],
                "modifiers": [
                    {
                        "hook": "MODIFY_DAMAGE",
                        "layer": "attacker_adjust",
                        "scope": "attached_attacker",
                        "operation": {
                            "kind": "damage_delta",
                            "amount": 10,
                        },
                    }
                ],
            }
        )
        owner["hand"] = ["sv1-151"]
        before = opponent["active"]["damage_counters"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x5A45524F)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            before,
        )

    def test_native_paralysis_expires_at_end_of_affected_players_turn(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["players"][0]["active"]["status_conditions"] = [
            "PARALYZED"
        ]
        state["players"][0]["active"]["paralyzed_since_turn"] = 2

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "END_TURN"
        )
        result = self.game.apply_action(state, action, 0x50415241)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][0]["active"]["status_conditions"],
            [],
        )
        self.assertEqual(
            result["state"]["players"][0]["active"][
                "paralyzed_since_turn"
            ],
            2,
        )

    def test_native_reactive_thorns_knocks_out_attacker_before_turn_end(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "sv1-104",
                "damage_counters": 2,
                "energy_card_ids": ["sv1-ener-5"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        opponent["active"].update(
            {
                "card_id": "svi-maus",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": ["svi-tand"],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        second_mouse = copy.deepcopy(opponent["active"])
        opponent["bench"] = [
            second_mouse,
            None,
            None,
            None,
            None,
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x4D415553)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "select_prize")
        self.assertEqual(result["pending"]["player"], 1)
        self.assertIsNone(result["state"]["players"][0]["active"])
        self.assertEqual(result["state"]["active_player_idx"], 0)
        thorns_fact = result["state"]["turn_fact_book"]["current_turn"][
            "knockouts"
        ][-1]
        self.assertEqual(thorns_fact["cause_kind"], "damage_counters")
        self.assertEqual(thorns_fact["source_kind"], "damage_counters")
        self.assertFalse(result["state"]["players"][0]["was_ko_by_attack"])

    def test_native_attack_waits_for_defender_promotion_after_prize_choice(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "svf-klea",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-6", "sv1-ener-6"],
                "evolution_stack_ids": ["svf-scyt"],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        promoted = copy.deepcopy(opponent["active"])
        promoted["damage_counters"] = 0
        opponent["bench"] = [promoted, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        coin = self.game.apply_action(state, action, 2)
        self.assertTrue(coin["success"], coin)
        self.assertEqual(coin["pending"]["request_type"], "coin_flip")

        prize = self.game.resume_choice(
            coin["state"],
            coin["continuation"],
            [],
            False,
            coin["rng_state"],
        )
        self.assertTrue(prize["success"], prize)
        self.assertEqual(prize["pending"]["request_type"], "select_prize")

        resolved = self.game.resume_choice(
            prize["state"],
            prize["continuation"],
            [prize["pending"]["options"][0]],
            False,
            prize["rng_state"],
        )
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(resolved["pending"], {})
        self.assertEqual(resolved["state"]["phase"], "ATTACK")
        self.assertEqual(resolved["state"]["active_player_idx"], 0)
        self.assertEqual(resolved["state"]["pending_promotions"], [1])

        promotion = next(
            row
            for row in self.game.legal_actions(resolved["state"], 1)
            if row["kind"] == "PROMOTE"
        )
        completed = self.game.apply_action(
            resolved["state"],
            promotion,
            resolved["rng_state"],
        )
        self.assertTrue(completed["success"], completed)
        self.assertEqual(completed["state"]["phase"], "MAIN")
        self.assertEqual(completed["state"]["active_player_idx"], 1)
        self.assertEqual(completed["state"]["pending_promotions"], [])

    def test_native_direct_knockout_uses_prize_trigger_pipeline(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            card_id="svf-klea",
            damage_counters=0,
            energy_card_ids=["sv1-ener-6", "sv1-ener-6"],
            evolution_stack_ids=["svf-scyt"],
            attached_tool_id="",
            status_conditions=[],
        )
        prize_target = copy.deepcopy(owner["active"])
        prize_target.update(
            card_id="svf-rio",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
        )
        owner["bench"] = [prize_target, None, None, None, None]
        owner["prizes"] = ["svi-trea", "sv1-ener-3"]
        promoted = copy.deepcopy(opponent["active"])
        promoted["damage_counters"] = 0
        opponent["bench"] = [promoted, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        coin = self.game.apply_action(state, action, 2)
        self.assertTrue(coin["success"], coin)
        prize = self.game.resume_choice(
            coin["state"],
            coin["continuation"],
            [],
            False,
            coin["rng_state"],
        )
        self.assertTrue(prize["success"], prize)
        self.assertEqual(prize["pending"]["request_type"], "select_prize")
        treasure_option = next(
            option
            for option in prize["pending"]["options"]
            if option["option_id"] == "prize:0"
        )
        treasure = self.game.resume_choice(
            prize["state"],
            prize["continuation"],
            [treasure_option],
            False,
            prize["rng_state"],
        )
        self.assertTrue(treasure["success"], treasure)
        self.assertEqual(
            treasure["pending"]["request_type"],
            "select_prize_energy_target",
        )
        attached = self.game.resume_choice(
            treasure["state"],
            treasure["continuation"],
            [treasure["pending"]["options"][0]],
            False,
            treasure["rng_state"],
        )
        self.assertTrue(attached["success"], attached)
        self.assertIn(
            "svi-trea",
            attached["state"]["players"][0]["bench"][0][
                "energy_card_ids"
            ],
        )
        self.assertNotIn("svi-trea", attached["state"]["players"][0]["hand"])
        self.assertEqual(attached["state"]["pending_promotions"], [1])

    def test_native_targeted_bench_knockout_queues_prize_and_finishes_attack(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "sv2-grex",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-3"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        target = copy.deepcopy(opponent["active"])
        target.update(
            {
                "card_id": "svf-luca",
                "damage_counters": 8,
                "energy_card_ids": [],
                "evolution_stack_ids": ["svf-rio"],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        opponent["bench"] = [target, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        targeted = self.game.apply_action(state, action, 0x4752454E)
        self.assertTrue(targeted["success"], targeted)
        self.assertEqual(targeted["pending"]["request_type"], "damage_target")
        self.assertEqual(
            targeted["events"],
            [
                {
                    "event_type": "attack_declared",
                    "data": {
                        "player": 0,
                        "card_id": "sv2-grex",
                        "attack_idx": 0,
                        "attack_name": self.cards["sv2-grex"][
                            "attacks"
                        ][0]["name"],
                    },
                }
            ],
        )
        selected = next(
            option
            for option in targeted["pending"]["options"]
            if option.get("slot") == "bench_0"
        )
        prize = self.game.resume_choice(
            targeted["state"],
            targeted["continuation"],
            [selected],
            False,
            targeted["rng_state"],
        )
        self.assertTrue(prize["success"], prize)
        self.assertEqual(prize["pending"]["request_type"], "select_prize")
        self.assertEqual(prize["pending"]["player"], 0)
        self.assertIsNone(prize["state"]["players"][1]["bench"][0])
        fact = prize["state"]["turn_fact_book"]["current_turn"][
            "knockouts"
        ][-1]
        self.assertEqual(fact["slot"], "bench_0")
        self.assertEqual(fact["cause_kind"], "damage")
        self.assertEqual(fact["source_kind"], "attack_damage")

        completed = self.game.resume_choice(
            prize["state"],
            prize["continuation"],
            [prize["pending"]["options"][0]],
            False,
            prize["rng_state"],
        )
        self.assertTrue(completed["success"], completed)
        self.assertEqual(completed["pending"], {})
        self.assertEqual(completed["state"]["phase"], "MAIN")
        self.assertEqual(completed["state"]["active_player_idx"], 1)

    def test_native_ability_self_knockout_completes_effects_before_ko(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        lucario = copy.deepcopy(owner["active"])
        lucario.update(
            {
                "card_id": "svf-luca",
                "damage_counters": 10,
                "energy_card_ids": ["sv1-ener-6"],
                "evolution_stack_ids": ["svf-riol"],
                "attached_tool_id": "",
                "status_conditions": [],
                "used_abilities": [],
            }
        )
        owner["bench"] = [lucario, None, None, None, None]
        owner["deck"] = ["sv1-151", "sv1-ener-6"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "USE_ABILITY"
            and row["source"]["card_id"] == "svf-luca"
        )
        result = self.game.apply_action(state, action, 0x4C554341)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"]["request_type"], "select_prize")
        self.assertEqual(result["pending"]["player"], 1)
        self.assertIsNone(result["state"]["players"][0]["bench"][0])
        self.assertEqual(len(result["state"]["players"][0]["deck"]), 1)
        self.assertIn(
            "sv1-ener-6",
            result["state"]["players"][0]["discard"],
        )
        knockout = result["state"]["turn_fact_book"]["current_turn"][
            "knockouts"
        ][-1]
        self.assertEqual(knockout["cause_kind"], "damage_counters")
        self.assertEqual(knockout["source_kind"], "damage_counters")

    def test_native_exp_share_trigger_resolves_before_attack_knockout(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 11
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "svi-ente",
                "damage_counters": 3,
                "energy_card_ids": [
                    "sv1-ener-2",
                    "sv1-ener-2",
                    "sv1-ener-2",
                ],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        opponent["active"].update(
            {
                "card_id": "svg2-tort",
                "damage_counters": 12,
                "energy_card_ids": [
                    "sv1-ener-1",
                    "sv1-ener-1",
                ],
                "evolution_stack_ids": ["svg2-grot", "svg2-turt"],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        exp_share_target = copy.deepcopy(opponent["active"])
        exp_share_target.update(
            {
                "card_id": "svg2-shro",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-1"],
                "evolution_stack_ids": [],
                "attached_tool_id": "svg2-exps",
            }
        )
        opponent["bench"] = [
            exp_share_target,
            None,
            None,
            None,
            None,
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        triggered = self.game.apply_action(state, action, 0x45585053)
        self.assertTrue(triggered["success"], triggered)
        self.assertEqual(
            triggered["pending"]["request_type"],
            "confirm_trigger",
        )
        self.assertEqual(triggered["pending"]["player"], 1)
        self.assertIsNotNone(triggered["state"]["players"][1]["active"])
        self.assertEqual(triggered["state"]["pending_promotions"], [])

        chained_continuation = copy.deepcopy(
            triggered["continuation"]
        )
        chained_continuation["remaining_exp_share_triggers"] = 1
        skipped_once = self.game.resume_choice(
            triggered["state"],
            chained_continuation,
            [
                next(
                    option
                    for option in triggered["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            triggered["rng_state"],
        )
        self.assertTrue(skipped_once["success"], skipped_once)
        self.assertEqual(
            skipped_once["pending"]["request_type"],
            "confirm_trigger",
        )
        self.assertEqual(
            skipped_once["continuation"][
                "remaining_exp_share_triggers"
            ],
            0,
        )
        skipped_twice = self.game.resume_choice(
            skipped_once["state"],
            skipped_once["continuation"],
            [
                next(
                    option
                    for option in skipped_once["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            skipped_once["rng_state"],
        )
        self.assertTrue(skipped_twice["success"], skipped_twice)
        self.assertEqual(
            skipped_twice["pending"]["request_type"],
            "select_prize",
        )
        self.assertTrue(
            skipped_twice["continuation"][
                "finish_attack_after_prizes"
            ]
        )

        ordered_continuation = copy.deepcopy(
            triggered["continuation"]
        )
        ordered_continuation["remaining_exp_share_triggers"] = 2
        ordered_continuation[
            "remaining_exp_share_requires_order"
        ] = True
        ordered = self.game.resume_choice(
            triggered["state"],
            ordered_continuation,
            [
                next(
                    option
                    for option in triggered["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            triggered["rng_state"],
        )
        self.assertTrue(ordered["success"], ordered)
        self.assertEqual(
            ordered["pending"]["request_type"],
            "choose_trigger_order",
        )
        self.assertEqual(len(ordered["pending"]["options"]), 2)
        ordered_choice = self.game.resume_choice(
            ordered["state"],
            ordered["continuation"],
            [ordered["pending"]["options"][1]],
            False,
            ordered["rng_state"],
        )
        self.assertTrue(ordered_choice["success"], ordered_choice)
        self.assertEqual(
            ordered_choice["pending"]["request_type"],
            "confirm_trigger",
        )
        self.assertEqual(
            ordered_choice["continuation"][
                "remaining_exp_share_triggers"
            ],
            1,
        )
        self.assertFalse(
            ordered_choice["continuation"][
                "remaining_exp_share_requires_order"
            ]
        )

        confirmed = self.game.resume_choice(
            triggered["state"],
            triggered["continuation"],
            [
                next(
                    option
                    for option in triggered["pending"]["options"]
                    if option["option_id"] == "confirm:yes"
                )
            ],
            False,
            triggered["rng_state"],
        )
        self.assertTrue(confirmed["success"], confirmed)
        self.assertEqual(
            confirmed["pending"]["request_type"],
            "select_attachment",
        )
        self.assertEqual(len(confirmed["pending"]["options"]), 2)

        resolved = self.game.resume_choice(
            confirmed["state"],
            confirmed["continuation"],
            [confirmed["pending"]["options"][1]],
            False,
            confirmed["rng_state"],
        )

        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(
            resolved["pending"]["request_type"],
            "select_prize",
        )
        self.assertEqual(resolved["pending"]["player"], 0)
        self.assertIsNone(resolved["state"]["players"][1]["active"])
        self.assertEqual(resolved["state"]["pending_promotions"], [1])
        self.assertEqual(
            resolved["state"]["players"][1]["bench"][0][
                "energy_card_ids"
            ],
            ["sv1-ener-1", "sv1-ener-1"],
        )

        double_state = copy.deepcopy(triggered["state"])
        double_state["players"][0]["active"]["damage_counters"] = 99
        double_continuation = copy.deepcopy(
            triggered["continuation"]
        )
        double_continuation["knockout_entries"] = [
            {
                "player_idx": 0,
                "slot": "active",
                "card_id": double_state["players"][0]["active"][
                    "card_id"
                ],
                "prize_count": 1,
            },
            {
                "player_idx": 1,
                "slot": "active",
                "card_id": double_state["players"][1]["active"][
                    "card_id"
                ],
                "prize_count": 1,
            },
        ]
        double_resolved = self.game.resume_choice(
            double_state,
            double_continuation,
            [
                next(
                    option
                    for option in triggered["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            triggered["rng_state"],
        )
        self.assertTrue(double_resolved["success"], double_resolved)
        self.assertIsNone(
            double_resolved["state"]["players"][0]["active"]
        )
        self.assertIsNone(
            double_resolved["state"]["players"][1]["active"]
        )
        self.assertEqual(
            double_resolved["pending"]["request_type"],
            "select_prize",
        )
        self.assertEqual(double_resolved["pending"]["player"], 1)
        self.assertEqual(
            double_resolved["continuation"][
                "remaining_prize_players"
            ],
            [0],
        )
        self.assertTrue(
            double_resolved["continuation"][
                "finish_attack_after_prizes"
            ]
        )
        self.assertIn(
            1,
            double_resolved["state"]["pending_promotions"],
        )

    def test_native_multiple_exp_share_triggers_are_ordered_and_all_resolved(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=11,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            card_id="svi-ente",
            damage_counters=0,
            energy_card_ids=["sv1-ener-2"] * 3,
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
        )
        opponent["active"].update(
            card_id="svg2-tort",
            damage_counters=12,
            energy_card_ids=["sv1-ener-1", "sv1-ener-1"],
            evolution_stack_ids=["svg2-grot", "svg2-turt"],
            attached_tool_id="",
            status_conditions=[],
        )
        first_target = copy.deepcopy(opponent["active"])
        first_target.update(
            card_id="svg2-shro",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="svg2-exps",
        )
        second_target = copy.deepcopy(first_target)
        opponent["bench"] = [
            first_target,
            second_target,
            None,
            None,
            None,
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        ordered = self.game.apply_action(state, action, 0x4D554C54)
        self.assertTrue(ordered["success"], ordered)
        self.assertEqual(
            ordered["pending"]["request_type"],
            "choose_trigger_order",
        )
        self.assertEqual(len(ordered["pending"]["options"]), 2)
        self.assertIsNotNone(ordered["state"]["players"][1]["active"])

        first = self.game.resume_choice(
            ordered["state"],
            ordered["continuation"],
            [ordered["pending"]["options"][1]],
            False,
            ordered["rng_state"],
        )
        self.assertTrue(first["success"], first)
        self.assertEqual(first["pending"]["request_type"], "confirm_trigger")
        first_declined = self.game.resume_choice(
            first["state"],
            first["continuation"],
            [
                next(
                    option
                    for option in first["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            first["rng_state"],
        )
        self.assertTrue(first_declined["success"], first_declined)
        self.assertEqual(
            first_declined["pending"]["request_type"],
            "confirm_trigger",
        )
        second_declined = self.game.resume_choice(
            first_declined["state"],
            first_declined["continuation"],
            [
                next(
                    option
                    for option in first_declined["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            first_declined["rng_state"],
        )
        self.assertTrue(second_declined["success"], second_declined)
        self.assertEqual(
            second_declined["pending"]["request_type"],
            "select_prize",
        )
        self.assertIsNone(second_declined["state"]["players"][1]["active"])
        self.assertEqual(
            second_declined["state"]["pending_promotions"],
            [1],
        )

    def test_native_returning_attacker_waits_for_exp_share_before_promotions(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=11,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "sv2-tatsu",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-3"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        owner_bench = copy.deepcopy(owner["active"])
        owner_bench.update(
            card_id="sv1-104",
            energy_card_ids=[],
        )
        owner["bench"] = [owner_bench, None, None, None, None]
        opponent["active"].update(
            damage_counters=999,
            energy_card_ids=["sv1-ener-1"],
        )
        exp_share_target = copy.deepcopy(opponent["active"])
        exp_share_target.update(
            {
                "card_id": "svg2-shro",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": [],
                "attached_tool_id": "svg2-exps",
            }
        )
        opponent["bench"] = [
            exp_share_target,
            None,
            None,
            None,
            None,
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        triggered = self.game.apply_action(state, action, 0x45585254)

        self.assertTrue(triggered["success"], triggered)
        self.assertEqual(
            triggered["pending"]["request_type"],
            "confirm_trigger",
        )
        self.assertEqual(triggered["pending"]["player"], 1)
        self.assertIsNone(triggered["state"]["players"][0]["active"])
        self.assertIsNotNone(triggered["state"]["players"][1]["active"])
        self.assertEqual(triggered["state"]["pending_promotions"], [])

        declined = self.game.resume_choice(
            triggered["state"],
            triggered["continuation"],
            [
                next(
                    option
                    for option in triggered["pending"]["options"]
                    if option["option_id"] == "confirm:no"
                )
            ],
            False,
            triggered["rng_state"],
        )
        self.assertTrue(declined["success"], declined)
        self.assertEqual(
            declined["pending"]["request_type"],
            "select_prize",
        )
        self.assertEqual(
            declined["state"]["pending_promotions"],
            [1, 0],
        )

    def test_native_mill_damage_replaces_printed_attack_damage(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        attacker = copy.deepcopy(owner["active"])
        attacker.update(
            {
                "card_id": "svi-infr",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-2"],
                "evolution_stack_ids": ["svi-chim"],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        defender = copy.deepcopy(opponent["active"])
        defender.update(
            {
                "card_id": "svl-zera",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        owner["active"] = attacker
        owner["deck"] = [
            "sv1-151",
            "sv1-150",
            "sv2-catch",
            "sv1-202",
            "sv1-ener-2",
        ]
        owner["discard"] = []
        opponent["active"] = defender

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0xE671A927)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            8,
        )
        self.assertEqual(result["state"]["active_player_idx"], 1)
        self.assertEqual(result["state"]["turn_number"], 4)
        self.assertNotIn("pokemon_ko", result["event_types"])

    def test_native_switch_auto_resolves_a_single_bench_target(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        previous_active = copy.deepcopy(owner["active"])
        only_bench = copy.deepcopy(owner["active"])
        only_bench["card_id"] = "sv2-38"
        owner["hand"] = ["sv1-150"]
        owner["bench"] = [only_bench, None, None, None, None]
        choice_sequence = state["choice_sequence"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-150"
        )
        result = self.game.apply_action(state, action, 0x0E3F711D)

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(
            result["state"]["players"][0]["active"]["card_id"],
            "sv2-38",
        )
        self.assertEqual(
            result["state"]["players"][0]["bench"][0]["card_id"],
            previous_active["card_id"],
        )
        self.assertEqual(
            result["state"]["choice_sequence"],
            choice_sequence,
        )
        self.assertEqual(
            result["event_types"],
            ["trainer_played", "switched"],
        )

    def test_native_lucky_energy_draws_after_post_hit_choice_before_turn_draw(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update({
            "card_id": "sv1-114",
            "damage_counters": 0,
            "energy_card_ids": ["sv1-ener-5", "sv1-ener-3"],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "status_conditions": [],
        })
        bench = copy.deepcopy(owner["active"])
        bench["card_id"] = "sv1-113"
        bench["energy_card_ids"] = []
        owner["bench"] = [bench, None, None, None, None]
        opponent["active"].update({
            "card_id": "svi-gree",
            "damage_counters": 0,
            "energy_card_ids": ["svi-mirc"],
            "evolution_stack_ids": ["svi-skwv"],
            "attached_tool_id": "",
            "status_conditions": [],
        })
        opponent["hand"] = []
        opponent["deck"] = ["sv1-150", "sv1-151", "sv1-153"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        suspended = self.game.apply_action(state, action, 0x0E3F711E)

        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(suspended["pending"]["request_type"], "confirm")
        self.assertEqual(opponent["hand"], [])
        decline = next(
            option
            for option in suspended["pending"]["options"]
            if option.get("option_id") == "confirm:no"
        )
        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [decline],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(
            resumed["state"]["players"][1]["hand"],
            ["sv1-153", "sv1-151"],
        )
        self.assertEqual(
            resumed["state"]["players"][1]["deck"],
            ["sv1-150"],
        )
        self.assertEqual(
            resumed["event_types"].count("cards_drawn"),
            2,
        )

    def test_native_choice_resume_preserves_wire_shape_and_bench_self_discard(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["hand"] = ["sv1-151"]
        owner["deck"] = ["svi-chim"]
        owner["bench"] = [None, None, None, None, None]

        nest_ball = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-151"
        )
        suspended = self.game.apply_action(
            state,
            nest_ball,
            0x0A11CE06,
        )
        self.assertTrue(suspended["success"], suspended)
        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [suspended["pending"]["options"][0]],
            False,
            suspended["rng_state"],
        )
        self.assertTrue(resumed["success"], resumed)
        placed = resumed["state"]["players"][0]["bench"][0]
        self.assertEqual(placed["card_id"], "svi-chim")
        self.assertNotIn("modifiers", placed)

        ability_state = copy.deepcopy(state)
        ability_owner = ability_state["players"][0]
        starmie = copy.deepcopy(ability_owner["active"])
        starmie.update({
            "card_id": "sv2-starm",
            "damage_counters": 0,
            "energy_card_ids": [],
            "evolution_stack_ids": ["sv2-staryu"],
            "used_abilities": [],
        })
        ability_owner["bench"] = [
            starmie,
            None,
            None,
            None,
            None,
        ]
        ability_owner["hand"] = []
        ability_owner["deck"] = []
        ability_state["players"][1]["active"]["damage_counters"] = 0
        ability_state["players"][1]["bench"] = [
            copy.deepcopy(ability_state["players"][1]["active"]),
            None,
            None,
            None,
            None,
        ]

        ability = next(
            row
            for row in self.game.legal_actions(ability_state, 0)
            if row["kind"] == "USE_ABILITY"
            and row["source"]["card_id"] == "sv2-starm"
        )
        ability_suspended = self.game.apply_action(
            ability_state,
            ability,
            0x0A11CE07,
        )
        self.assertTrue(ability_suspended["success"], ability_suspended)
        ability_resumed = self.game.resume_choice(
            ability_suspended["state"],
            ability_suspended["continuation"],
            [ability_suspended["pending"]["options"][0]],
            False,
            ability_suspended["rng_state"],
        )
        self.assertTrue(ability_resumed["success"], ability_resumed)
        self.assertIsNone(
            ability_resumed["state"]["players"][0]["bench"][0]
        )
        self.assertEqual(
            ability_resumed["state"]["pending_promotions"],
            [],
        )

    def test_native_ability_resumes_remaining_effects_after_choice(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        active = copy.deepcopy(owner["active"])
        active.update(
            {
                "card_id": "sv1-108",
                "energy_card_ids": [],
                "evolution_stack_ids": ["sv1-107"],
                "used_abilities": [],
            }
        )
        first_bench = copy.deepcopy(owner["active"])
        first_bench["card_id"] = "sv1-110"
        second_bench = copy.deepcopy(owner["active"])
        second_bench["card_id"] = "sv1-104"
        owner["active"] = active
        owner["bench"] = [
            first_bench,
            second_bench,
            None,
            None,
            None,
        ]
        owner["hand"] = ["sv1-ener-5"]
        owner["deck"] = ["sv1-151", "sv1-150"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "USE_ABILITY"
            and row["source"]["card_id"] == "sv1-108"
        )
        suspended = self.game.apply_action(state, action, 0x4B3F9911)

        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(
            suspended["pending"]["request_type"],
            "select_own_bench_energy",
        )
        self.assertEqual(
            suspended["state"]["players"][0]["hand"],
            ["sv1-ener-5"],
        )
        self.assertEqual(
            suspended["state"]["players"][0]["deck"],
            ["sv1-151", "sv1-150"],
        )

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [suspended["pending"]["options"][0]],
            False,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(resumed["pending"], {})
        self.assertEqual(
            resumed["state"]["players"][0]["bench"][0][
                "energy_card_ids"
            ],
            ["sv1-ener-5"],
        )
        self.assertEqual(
            resumed["state"]["players"][0]["hand"],
            ["sv1-150", "sv1-151"],
        )
        self.assertEqual(resumed["state"]["players"][0]["deck"], [])
        self.assertEqual(
            resumed["event_types"],
            ["energy_attached", "cards_drawn"],
        )

    def test_native_jet_energy_switches_the_attached_bench(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        previous_active = copy.deepcopy(owner["active"])
        previous_active["status_conditions"] = ["PARALYZED"]
        previous_active["paralyzed_since_turn"] = 2
        owner["active"] = copy.deepcopy(previous_active)
        target = copy.deepcopy(owner["active"])
        target["card_id"] = "svi-inde"
        target["energy_card_ids"] = []
        owner["hand"] = ["svi-jete"]
        owner["bench"] = [target, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "ATTACH_ENERGY"
            and row["target"]["slot"] == "bench_0"
        )
        result = self.game.apply_action(state, action, 0xE19A7213)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][0]["active"]["card_id"],
            "svi-inde",
        )
        self.assertEqual(
            result["state"]["players"][0]["active"]["energy_card_ids"],
            ["svi-jete"],
        )
        self.assertEqual(
            result["state"]["players"][0]["bench"][0]["card_id"],
            previous_active["card_id"],
        )
        self.assertEqual(
            result["state"]["players"][0]["bench"][0][
                "status_conditions"
            ],
            [],
        )
        self.assertEqual(
            result["state"]["players"][0]["bench"][0][
                "paralyzed_since_turn"
            ],
            0,
        )
        self.assertEqual(
            result["event_types"],
            ["energy_attached", "switched"],
        )

    def test_native_smeargle_empty_selection_skips_target_and_shuffles(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svm-smeargle",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-8"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        owner["bench"] = [None, None, None, None, None]
        owner["deck"] = [
            "sv1-150",
            "sv1-151",
            "sv1-ener-8",
            "sv1-180",
            "sv1-ener-8",
        ]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        suspended = self.game.apply_action(state, action, 0x534D4541)
        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(
            suspended["pending"]["request_type"],
            "look_top_attach_energy",
        )
        from engine.random_source import PortableRandomSourceV1

        expected_deck = list(suspended["state"]["players"][0]["deck"])
        top_count = min(5, len(expected_deck))
        expected_deck[-top_count:] = reversed(expected_deck[-top_count:])
        expected_rng = PortableRandomSourceV1(suspended["rng_state"])
        expected_rng.shuffle(expected_deck)

        resumed = self.game.resume_choice(
            suspended["state"],
            suspended["continuation"],
            [],
            True,
            suspended["rng_state"],
        )

        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(resumed["pending"], {})
        self.assertEqual(resumed["state"]["active_player_idx"], 1)
        self.assertNotEqual(resumed["rng_state"], suspended["rng_state"])
        self.assertEqual(
            resumed["state"]["players"][0]["deck"],
            expected_deck,
        )
        self.assertIn("deck_shuffled", resumed["event_types"])

    def test_native_search_any_switch_auto_switches_single_bench_target(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svg-tatsu",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-3", "sv1-ener-3"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        replacement = copy.deepcopy(owner["active"])
        replacement.update(
            {
                "card_id": "svg-swa",
                "energy_card_ids": [],
            }
        )
        owner["bench"] = [replacement, None, None, None, None]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        search = self.game.apply_action(state, action, 0x53555256)
        self.assertTrue(search["success"], search)

        confirm = self.game.resume_choice(
            search["state"],
            search["continuation"],
            [],
            True,
            search["rng_state"],
        )
        self.assertTrue(confirm["success"], confirm)
        self.assertEqual(confirm["pending"]["request_type"], "confirm")

        resolved = self.game.resume_choice(
            confirm["state"],
            confirm["continuation"],
            [
                next(
                    option
                    for option in confirm["pending"]["options"]
                    if option["option_id"] == "confirm:yes"
                )
            ],
            False,
            confirm["rng_state"],
        )
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(resolved["pending"], {})
        self.assertEqual(
            resolved["state"]["players"][0]["active"]["card_id"],
            "svg-swa",
        )
        self.assertEqual(resolved["state"]["active_player_idx"], 1)

    def test_native_discard_count_formula_counts_matching_pokemon(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["active"].update(
            {
                "card_id": "sv1-106",
                "damage_counters": 0,
                "energy_card_ids": [
                    "sv1-ener-5",
                    "sv1-ener-5",
                ],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )
        owner["discard"] = [
            "sv1-104",
            "sv1-107",
            "sv1-ener-5",
        ]
        opponent["active"].update(
            {
                "card_id": "svg2-tort",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": ["svg2-grot", "svg2-turt"],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x44495343)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            10,
        )

    def test_native_sleep_checkup_consumes_rng_and_can_wake(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svd-darkrai",
                "damage_counters": 0,
                "energy_card_ids": [
                    "sv1-ener-7",
                    "sv1-ener-7",
                ],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
            }
        )

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 1)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"][
                "status_conditions"
            ],
            [],
        )
        self.assertNotEqual(result["rng_state"], 1)

    def test_native_dazzling_gate_is_consumed_on_attack_attempt(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 6
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["active"].update(
            {
                "card_id": "svg-swa",
                "damage_counters": 0,
                "energy_card_ids": ["sv1-ener-3"],
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
                "modifiers": [
                    {
                        "hook": "CAN_ATTACK",
                        "layer": "gate",
                        "priority": 0,
                        "controller": 0,
                        "source_ref": {
                            "kind": "pokemon",
                            "player": 1,
                            "slot": "active",
                            "card_id": "svl-lant",
                        },
                        "scope": "self",
                        "duration": "until_next_attack",
                        "stacking": "replace_same_source",
                        "conflict_policy": "commutative",
                        "condition": {"expires_after_turn": 6},
                        "operation": {
                            "kind": "attack_gate_coin",
                            "reason": "dazzled",
                        },
                    }
                ],
            }
        )

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 2)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][0]["active"]["modifiers"],
            [],
        )

    def test_native_double_turbo_damage_modifier_floors_at_zero(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        attacker = copy.deepcopy(owner["active"])
        attacker.update(
            {
                "card_id": "svi-tand",
                "energy_card_ids": ["svi-dtur"],
                "evolution_stack_ids": [],
            }
        )
        defender = copy.deepcopy(opponent["active"])
        defender.update(
            {
                "card_id": "svm-orthworm",
                "damage_counters": 0,
                "energy_card_ids": [],
                "evolution_stack_ids": [],
            }
        )
        owner["active"] = attacker
        opponent["active"] = defender

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x75A19C03)

        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            0,
        )
        self.assertNotIn("damage_dealt", result["event_types"])

    def test_native_judge_draws_for_an_opponent_with_no_hand(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        opponent = state["players"][1]
        owner["hand"] = ["sv1-176", "sv1-151"]
        owner["deck"] = [
            "sv1-150",
            "sv1-ener-1",
            "sv1-ener-2",
            "sv1-ener-3",
        ]
        opponent["hand"] = []
        opponent_deck = list(opponent["deck"])

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
            and row["source"]["card_id"] == "sv1-176"
        )
        result = self.game.apply_action(state, action, 0x1138F00D)

        self.assertTrue(result["success"], result)
        expected_draw = min(4, len(opponent_deck))
        self.assertEqual(
            len(result["state"]["players"][1]["hand"]),
            expected_draw,
        )
        self.assertEqual(
            len(result["state"]["players"][1]["deck"]),
            len(opponent_deck) - expected_draw,
        )
        opponent_draw = next(
            event
            for event in result["events"]
            if event["event_type"] == "cards_drawn"
            and event["data"]["player"] == 1
        )
        self.assertEqual(opponent_draw["data"]["count"], expected_draw)

    def test_native_search_can_start_from_choice_root(self):
        state, _unused_decks = self._native_search_fixture()
        owner = state["players"][0]
        owner["active"]["card_id"] = "sv2-delib"
        owner["active"]["energy_card_ids"] = ["sv1-ener-3"]
        bench = copy.deepcopy(owner["active"])
        bench["card_id"] = "sv2-tatsu"
        bench["energy_card_ids"] = []
        owner["bench"] = [bench, None, None, None, None]
        owner["retreated_this_turn"] = False

        def submitted_deck(player_index):
            player = state["players"][player_index]
            cards = [
                *player["hand"],
                *player["deck"],
                *player["discard"],
                *player["prizes"],
            ]
            for pokemon in [player["active"], *player["bench"]]:
                if not isinstance(pokemon, dict):
                    continue
                cards.append(pokemon["card_id"])
                cards.extend(pokemon.get("evolution_stack_ids", []))
                cards.extend(pokemon.get("energy_card_ids", []))
                tool = pokemon.get("attached_tool_id")
                if tool:
                    cards.append(tool)
            if state.get("stadium_owner_idx") == player_index:
                stadium = state.get("stadium_card_id")
                if stadium:
                    cards.append(stadium)
            return cards

        decks = {
            state["public_deck_keys"][player_index]:
                submitted_deck(player_index)
            for player_index in (0, 1)
        }
        retreat = next(
            action
            for action in self.game.legal_actions(state, 0)
            if action["kind"] == "RETREAT"
        )
        suspended = self.game.apply_action(state, retreat, 991)
        self.assertTrue(suspended["success"], suspended)
        self.assertEqual(
            suspended["pending"]["request_type"],
            "select_retreat_payment",
        )

        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start_choice(
            suspended["state"],
            0,
            suspended["pending"],
            suspended["continuation"],
            991,
            {
                "simulations": 4,
                "max_depth": 8,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertEqual(result["simulations"], 4)
        self.assertGreater(result["apply_undo_journal_entries"], 0)
        self.assertEqual(
            result["apply_undo_operations"],
            result["apply_undo_journal_entries"],
        )
        self.assertEqual(len(result["candidates"]), 2)
        self.assertEqual(
            {
                tuple(row["selected_options"])
                for row in result["candidates"]
                if not row["cancelled"]
            },
            {("retreat:energy:0",)},
        )
        self.assertEqual(
            sum(result["visits"]),
            result["simulations"] - 1,
        )

    def test_native_search_records_coin_results_as_chance_edges(self):
        state, decks = self._native_search_fixture()
        pending = {
            "request_id": "choice:coin",
            "request_type": "coin_flip",
            "player": 0,
            "min_select": 0,
            "max_select": 0,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [],
            "metadata": {"continuation_kind": "coin"},
        }
        continuation = {
            "kind": "vm",
            "actor": 0,
            "finish_attack": False,
            "context": {},
            "vm": {
                "op": "flip_coin_repeat_damage",
                "command_spec": {
                    "op": "flip_coin_repeat_damage",
                    "args": {
                        "flips": 3,
                        "damage_per_head": 10,
                    },
                    "branches": {},
                },
                "actor": 0,
                "source_slot": "active",
                "stage": 0,
                "flips": [True, False, True],
            },
        }
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start_choice(
            state,
            0,
            pending,
            continuation,
            1709,
            {
                "simulations": 4,
                "max_depth": 8,
                "c_puct": 1.4,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertEqual(result["chance_nodes"], 1)
        self.assertEqual(sum(result["visits"]), result["simulations"])
        self.assertEqual(
            result["selected"]["chance_outcome"],
            [True, False, True],
        )
        self.assertAlmostEqual(
            result["selected"]["chance_probability"],
            0.125,
        )

    def test_native_search_records_confusion_as_explicit_chance_node(self):
        state, _unused_decks = self._native_search_fixture()
        owner = state["players"][0]
        owner["active"]["card_id"] = "svi-chim"
        owner["active"]["energy_card_ids"] = ["sv1-ener-2"]
        owner["active"]["status_conditions"] = ["CONFUSED"]
        owner["hand"] = []
        decks = self._submitted_decks(state)

        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            2719,
            {
                "simulations": 32,
                "max_depth": 2,
                "c_puct": 1.4,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertGreaterEqual(result["chance_nodes"], 1)
        self.assertEqual(result["chance_edges"], 2)

    def test_native_search_records_checkup_status_coin_as_chance_node(self):
        state, _unused_decks = self._native_search_fixture()
        state["players"][0]["active"]["status_conditions"] = ["BURNED"]
        end_turn = next(
            action
            for action in self.game.legal_actions(state, 0)
            if action["kind"] == "END_TURN"
        )
        state["_native_root_allowed_actions"] = [end_turn]
        decks = self._submitted_decks(state)

        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            0x4255524E,
            {
                "simulations": 32,
                "max_depth": 2,
                "c_puct": 1.4,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()

        self.assertTrue(result["success"], result)
        self.assertEqual(len(result["candidates"]), 1)
        self.assertEqual(result["selected"]["kind"], "END_TURN")
        self.assertGreaterEqual(result["chance_nodes"], 1)
        self.assertGreaterEqual(result["chance_edges"], 1)

    def test_native_search_records_hidden_shuffle_as_chance_node(self):
        state, _unused_decks = self._native_search_fixture()
        state["players"][0]["hand"] = ["sv1-176"]
        state["players"][0]["supporter_played_this_turn"] = False
        decks = self._submitted_decks(state)

        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start(
            state,
            0,
            3251,
            {
                "simulations": 32,
                "max_depth": 8,
                "c_puct": 1.4,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()
        self.assertTrue(result["success"], result)
        self.assertGreaterEqual(result["chance_nodes"], 1)
        self.assertGreaterEqual(result["chance_edges"], 1)
        serialized = json.dumps(result, sort_keys=True)
        for hidden_id in (
            "b-hidden-0",
            "b-hidden-1",
            "b-hidden-2",
            "b-hidden-3",
        ):
            self.assertNotIn(hidden_id, serialized)

    def test_cow_search_matches_legacy_recursive_state_copy(self):
        state, decks = self._native_search_fixture()

        def run(force_deep_state_copy):
            batch = ptcg_ai_core.NativeSelfPlayBatch()
            job = ptcg_ai_core.NativeSearchJob(
                self.game_cards,
                decks,
                batch,
            )
            job.start(
                state,
                0,
                3907,
                {
                    "simulations": 24,
                    "max_depth": 8,
                    "c_puct": 1.4,
                    "dirichlet_epsilon": 0.0,
                    "temperature": 0.0,
                    "training": False,
                    "force_deep_state_copy": force_deep_state_copy,
                    "verify_candidate_cache": force_deep_state_copy,
                    "inference_wait_milliseconds": 10,
                },
            )
            self._serve_uniform_inference(batch, [job])
            return job.wait()

        cow = run(False)
        recursive = run(True)
        self.assertTrue(cow["success"], cow)
        self.assertTrue(recursive["success"], recursive)
        for field in (
            "selected",
            "candidates",
            "visits",
            "value_sums",
            "probabilities",
            "root_value",
            "simulations",
            "tree_nodes",
            "chance_nodes",
            "chance_edges",
        ):
            with self.subTest(field=field):
                self.assertEqual(cow[field], recursive[field])
        self.assertGreater(cow["candidate_cache_hits"], 0)
        self.assertGreater(recursive["candidate_cache_hits"], 0)
        self.assertEqual(
            cow["candidate_cache_misses"],
            recursive["candidate_cache_misses"],
        )

    def test_native_choice_boundary_keeps_only_revealed_context(self):
        from engine.actions import ChoiceResponse
        from engine.ai.dl.puct_v2 import SearchCandidate

        pending = {
            "request_id": "choice:visible",
            "request_type": "search_deck",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [
                {
                    "option_id": "card:0:deck:3:sv2-tatsu",
                    "label": "Tatsugiri",
                    "ref": {
                        "kind": "card",
                        "player": 0,
                        "zone": "deck",
                        "index": 3,
                        "card_id": "sv2-tatsu",
                    },
                    "value": "sv2-tatsu",
                }
            ],
            "metadata": {
                "continuation": {
                    "kind": "look_top_deck",
                    "top_card_ids": ["sv2-tatsu", "sv1-ener-3"],
                    "_resume": {
                        "context": {
                            "must_not_cross": "opponent-hidden-card",
                        }
                    },
                }
            },
        }
        response = ChoiceResponse(
            "choice:visible",
            ("card:0:deck:3:sv2-tatsu",),
        )
        native = _native_choice_view(
            pending,
            [SearchCandidate("choice:visible:only", response)],
            0,
        )
        self.assertEqual(
            native["metadata"],
            {
                "continuation": {
                    "top_card_ids": [
                        "sv2-tatsu",
                        "sv1-ener-3",
                    ]
                }
            },
        )
        self.assertNotIn("must_not_cross", repr(native))

        leaked = copy.deepcopy(pending)
        leaked["options"][0]["ref"]["player"] = 1
        leaked["options"][0]["ref"]["zone"] = "hand"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "opponent_hidden_choice_reference_rejected",
        ):
            _native_choice_view(
                leaked,
                [SearchCandidate("choice:leaked", response)],
                0,
            )

    def test_native_bridge_auto_resolves_forced_choice_without_context(self):
        from engine.actions import ChoiceResponse
        from engine.ai.dl.puct_v2 import SearchCandidate

        response = ChoiceResponse(
            "choice:forced",
            ("bench:opponent:0",),
        )
        candidate = SearchCandidate("choice:forced:only", response)
        service = NativeSearchService.__new__(NativeSearchService)

        result = service.search_choice(
            object(),
            0,
            [candidate],
            simulations=128,
            c_puct=1.4,
            seed=17,
            training=True,
            temperature=1.0,
        )

        self.assertIs(result.selected, candidate)
        self.assertEqual(result.visits, {candidate.signature: 1})
        self.assertEqual(result.probabilities, {candidate.signature: 1.0})
        self.assertEqual(result.simulations, 0)

    def test_native_bridge_rebuilds_only_public_prize_control_state(self):
        resume = {
            "version": 1,
            "player_idx": 1,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 1},
                {"kind": "finalize_knockout_batch"},
                {"kind": "prize_selection", "player_idx": 1},
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {
                    "must_not_cross": "opponent-hidden-card",
                },
            },
            "attack_failed": False,
        }
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 1,
            "players": [
                {"prizes": ["opponent-hidden-card"]},
                {"prizes": ["svi-trea", "sv1-ener-3"]},
            ],
        }
        pending = {
            "request_id": "choice:77:1:select_prize:9",
            "request_type": "select_prize",
            "player": 1,
            "options": [
                {"option_id": "prize:0"},
                {"option_id": "prize:1"},
            ],
            "metadata": {
                "finish_attack_actor": 1,
                "continuation": {
                    "kind": "select_prize",
                    "domain": "prize",
                    "player_idx": 1,
                    "_resume": resume,
                },
            },
        }

        native = _public_native_prize_continuation(wire, pending, 1)

        self.assertEqual(native, {
            "kind": "select_prize",
            "actor": 1,
            "remaining_prize_players": [1],
            "finish_attack_after_prizes": True,
            "resume_attack_actor": 1,
        })
        self.assertNotIn("opponent-hidden-card", repr(native))

        treasure = copy.deepcopy(pending)
        treasure["request_type"] = "select_prize_energy_target"
        treasure["metadata"]["continuation"] = {
            "kind": "treasure_prize_target",
            "domain": "prize",
            "player_idx": 1,
            "prize_index": 0,
            "card_id": "svi-trea",
            "trigger_hook": "ON_PRIZE_REVEALED",
            "trigger_op": "attach_to_benched_pokemon",
            "_resume": copy.deepcopy(resume),
        }
        native_treasure = _public_native_prize_continuation(
            wire,
            treasure,
            1,
        )
        self.assertEqual(native_treasure["prize_index"], 0)
        self.assertEqual(native_treasure["prize_card_id"], "svi-trea")
        self.assertNotIn("opponent-hidden-card", repr(native_treasure))

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["_resume"]["frames"][0][
            "private"
        ] = "opponent-hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_prize_continuation_invalid",
        ):
            _public_native_prize_continuation(wire, malformed, 1)

    def test_native_public_prize_resume_finishes_attack_after_queue(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["players"][0]["prizes"] = [
            "sv1-ener-3",
            "sv1-ener-4",
            "sv1-ener-5",
        ]
        continuation = {
            "kind": "select_prize",
            "actor": 0,
            "remaining_prize_players": [0],
            "finish_attack_after_prizes": True,
            "resume_attack_actor": 0,
        }

        first = self.game.resume_choice(
            state,
            continuation,
            [{"option_id": "prize:0"}],
            False,
            0x5052495A,
        )
        self.assertTrue(first["success"], first)
        self.assertEqual(
            first["pending"]["request_type"],
            "select_prize",
        )
        self.assertTrue(
            first["continuation"]["finish_attack_after_prizes"]
        )

        second = self.game.resume_choice(
            first["state"],
            first["continuation"],
            [{"option_id": "prize:0"}],
            False,
            first["rng_state"],
        )
        self.assertTrue(second["success"], second)
        self.assertEqual(second["pending"], {})
        self.assertEqual(second["state"]["active_player_idx"], 1)
        self.assertEqual(second["state"]["phase"], "MAIN")

    def test_native_bridge_rebuilds_visible_look_top_vm_continuation(self):
        top_card_ids = [
            "sv1-ener-3",
            "svi-chim",
            "sv1-ener-4",
        ]
        wire = {
            "players": [
                {"deck": []},
                {
                    "deck": [
                        "sv1-ener-5",
                        *reversed(top_card_ids),
                    ],
                },
            ],
        }
        pending = {
            "request_id": "choice:30:1:search_deck:4",
            "request_type": "search_deck",
            "player": 1,
            "options": [],
            "metadata": {
                "continuation": {
                    "kind": "look_top_deck",
                    "player_idx": 1,
                    "count": 3,
                    "take": 2,
                    "rest_bottom": True,
                    "shuffle_rest": False,
                    "destination": "hand",
                    "top_card_ids": top_card_ids,
                    "display_top_positions": [0, 2],
                    "_resume": {
                        "version": 1,
                        "player_idx": 1,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [],
                        "unsupported_frames": [],
                        "context": {},
                        "attack_failed": False,
                    },
                },
            },
        }

        native = _public_native_vm_continuation(wire, pending, 1)

        self.assertEqual(native["kind"], "vm")
        self.assertEqual(native["actor"], 1)
        self.assertFalse(native["finish_attack"])
        self.assertEqual(
            native["vm"]["command_spec"],
            {
                "op": "look_top_deck",
                "args": {
                    "count": 3,
                    "take": 2,
                    "rest_bottom": True,
                    "shuffle_rest": False,
                    "destination": "hand",
                },
            },
        )
        self.assertNotIn("top_card_ids", repr(native))

        take_all = copy.deepcopy(pending)
        take_all["metadata"]["continuation"]["take"] = 99
        take_all_native = _public_native_vm_continuation(
            wire,
            take_all,
            1,
        )
        self.assertEqual(
            take_all_native["vm"]["command_spec"]["args"]["take"],
            99,
        )

        unsupported_take = copy.deepcopy(pending)
        unsupported_take["metadata"]["continuation"]["take"] = 65
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(wire, unsupported_take, 1)

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["_resume"]["frames"] = [{
            "kind": "command_spec",
            "spec": {"op": "must_not_cross"},
        }]
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(wire, malformed, 1)

    def test_native_bridge_rebuilds_public_attack_switch_confirmation(self):
        wire = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        wire["phase"] = "ATTACK"
        wire["turn_number"] = 3
        wire["first_player_idx"] = 1
        wire["active_player_idx"] = 0
        active = wire["players"][0]["active"]
        active["card_id"] = "sv1-114"
        target = copy.deepcopy(active)
        target.update({
            "card_id": "sv2-delib",
            "damage_counters": 0,
            "energy_card_ids": [],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "modifiers": [],
        })
        wire["players"][0]["bench"] = [target, None, None, None, None]
        wire["players"][1]["hand"] = ["opponent-hidden-card"]
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {"active": True, "player_idx": 0},
                "pending_after_damage_trigger_specs": [],
            },
            "attack_failed": False,
        }
        pending = {
            "request_id": "choice:7:0:confirm:1",
            "request_type": "confirm",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [
                {
                    "option_id": "confirm:yes",
                    "label": "yes",
                    "ref": None,
                    "value": True,
                },
                {
                    "option_id": "confirm:no",
                    "label": "no",
                    "ref": None,
                    "value": False,
                },
            ],
            "metadata": {
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "switch_confirm",
                    "target_player_idx": 0,
                    "chooser_idx": 0,
                    "request_type": "select_bench",
                    "request_target_player": "self",
                    "bench_indices": [0],
                    "_resume": resume,
                },
            },
        }

        native = _public_native_vm_continuation(wire, pending, 0)

        self.assertEqual(native["kind"], "vm")
        self.assertTrue(native["finish_attack"])
        self.assertEqual(native["vm"], {
            "op": "switch_pokemon",
            "command_spec": {
                "op": "switch_pokemon",
                "args": {"target": "self", "optional": True},
            },
            "actor": 0,
            "source_slot": "active",
            "stage": 0,
        })
        self.assertNotIn("opponent-hidden-card", repr(native))

        switched = self.game.resume_choice(
            wire,
            native,
            [{"option_id": "confirm:yes"}],
            False,
            17,
        )
        self.assertTrue(switched["success"], switched)
        self.assertEqual(
            switched["state"]["players"][0]["active"]["card_id"],
            "sv2-delib",
        )
        self.assertEqual(switched["state"]["active_player_idx"], 1)

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["bench_indices"] = [1]
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(wire, malformed, 0)

    def test_native_bridge_rebuilds_visible_search_cards_vm(self):
        own_deck = [
            "svg-ceto",
            "sv1-ener-8",
            "sv1-ener-8",
            "sv1-ener-8",
            "svg-tatsu",
        ]
        wire = {
            "phase": "MAIN",
            "active_player_idx": 1,
            "players": [
                {
                    "deck": ["opponent-hidden-card"],
                    "discard": [],
                },
                {
                    "deck": own_deck,
                    "discard": [],
                    "bench": [None, None, None, None, None],
                },
            ],
        }
        pending = {
            "request_id": "choice:142:1:search_deck:1",
            "request_type": "search_deck",
            "player": 1,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [
                {
                    "option_id": "card:1:deck:0:svg-ceto",
                    "label": "Cetoddle",
                    "ref": {
                        "kind": "card",
                        "player": 1,
                        "zone": "deck",
                        "slot": "",
                        "index": 0,
                        "attachment_type": "",
                        "card_id": "svg-ceto",
                    },
                    "value": "svg-ceto",
                },
                {
                    "option_id": "card:1:deck:4:svg-tatsu",
                    "label": "Tatsugiri",
                    "ref": {
                        "kind": "card",
                        "player": 1,
                        "zone": "deck",
                        "slot": "",
                        "index": 4,
                        "attachment_type": "",
                        "card_id": "svg-tatsu",
                    },
                    "value": "svg-tatsu",
                },
            ],
            "metadata": {
                "continuation": {
                    "kind": "search_cards",
                    "player_idx": 1,
                    "from_zone": "deck",
                    "destination": "hand",
                    "count": 1,
                    "_resume": {
                        "version": 1,
                        "player_idx": 1,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [],
                        "unsupported_frames": [],
                        "context": {},
                        "attack_failed": False,
                    },
                },
            },
        }

        native = _public_native_vm_continuation(wire, pending, 1)

        self.assertEqual(native, {
            "kind": "vm",
            "actor": 1,
            "finish_attack": False,
            "vm": {
                "op": "search_cards",
                "command_spec": {
                    "op": "search_cards",
                    "args": {
                        "from_zone": "deck",
                        "destination": "hand",
                        "count": 1,
                    },
                },
                "actor": 1,
                "source_slot": "active",
                "stage": 0,
            },
            "context": {},
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "",
        })
        self.assertNotIn("opponent-hidden-card", repr(native))
        self.assertNotIn("svg-ceto", repr(native))
        self.assertNotIn("svg-tatsu", repr(native))

        attack_wire = copy.deepcopy(wire)
        attack_wire["phase"] = "ATTACK"
        attack_pending = copy.deepcopy(pending)
        attack_pending["metadata"]["finish_attack_actor"] = 1
        attack_pending["metadata"]["continuation"]["_resume"].update({
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 1},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 1,
                },
                "pending_after_damage_trigger_specs": [],
            },
        })
        attack_native = _public_native_vm_continuation(
            attack_wire,
            attack_pending,
            1,
        )
        self.assertTrue(attack_native["finish_attack"])
        self.assertEqual(attack_native["context_mode"], "attack")
        self.assertEqual(attack_native["context"], {
            "damage_applied": True,
            "after_damage_triggers_applied": True,
            "reactive_thorns_applied": True,
        })

        bench_wire = copy.deepcopy(attack_wire)
        bench_wire["players"][1]["bench"] = [
            {"card_id": "occupied-0"},
            {"card_id": "occupied-1"},
            None,
            {"card_id": "occupied-3"},
            {"card_id": "occupied-4"},
        ]
        bench_pending = copy.deepcopy(attack_pending)
        bench_continuation = bench_pending["metadata"]["continuation"]
        bench_continuation["destination"] = "bench"
        bench_continuation["count"] = 2
        bench_pending["max_select"] = 1
        bench_native = _public_native_vm_continuation(
            bench_wire,
            bench_pending,
            1,
        )
        self.assertEqual(
            bench_native["vm"]["command_spec"]["args"],
            {
                "from_zone": "deck",
                "destination": "bench",
                "count": 2,
            },
        )

        malformed = copy.deepcopy(pending)
        malformed["options"][0]["ref"]["player"] = 0
        malformed["options"][0]["ref"]["card_id"] = (
            "opponent-hidden-card"
        )
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(wire, malformed, 1)

    def test_native_bridge_rebuilds_discard_hand_then_draw_vm(self):
        wire = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        wire["phase"] = "MAIN"
        wire["turn_number"] = 3
        wire["first_player_idx"] = 1
        wire["active_player_idx"] = 0
        own = wire["players"][0]
        own["hand"] = [
            "sv1-ener-3",
            "sv1-ener-4",
            "sv1-ener-5",
        ]
        own["deck"] = ["sv1-ener-1", "sv1-ener-2"]
        own["discard"] = []
        wire["players"][1]["hand"] = ["opponent-hidden-card"]

        options = []
        for index, card_id in enumerate(own["hand"]):
            options.append({
                "option_id": f"card:0:hand:{index}:{card_id}",
                "label": card_id,
                "ref": {
                    "kind": "card",
                    "player": 0,
                    "zone": "hand",
                    "slot": "",
                    "index": index,
                    "attachment_type": "",
                    "card_id": card_id,
                },
                "value": card_id,
            })
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [],
            "unsupported_frames": [],
            "context": {},
            "attack_failed": False,
        }
        pending = {
            "request_id": "choice:146:0:search_deck:4",
            "request_type": "search_deck",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": options,
            "metadata": {
                "domain": "search_deck",
                "from_zone": "hand",
                "target_player": "",
                "continuation": {
                    "kind": "discard_hand_then_draw",
                    "player_idx": 0,
                    "discard_amount": 1,
                    "draw_amount": 1,
                    "_resume": resume,
                },
            },
        }

        native = _public_native_vm_continuation(wire, pending, 0)

        self.assertEqual(native, {
            "kind": "vm",
            "actor": 0,
            "finish_attack": False,
            "vm": {
                "op": "discard_then_draw_cards",
                "command_spec": {
                    "op": "discard_then_draw_cards",
                    "args": {
                        "discard_amount": 1,
                        "draw_amount": 1,
                    },
                },
                "actor": 0,
                "source_slot": "active",
                "stage": 0,
            },
            "context": {},
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "",
        })
        self.assertNotIn("opponent-hidden-card", repr(native))
        resumed = self.game.resume_choice(
            wire,
            native,
            [options[0]["ref"]],
            False,
            17,
        )
        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(
            resumed["state"]["players"][0]["discard"],
            ["sv1-ener-3"],
        )
        self.assertEqual(
            resumed["state"]["players"][0]["hand"],
            ["sv1-ener-4", "sv1-ener-5", "sv1-ener-2"],
        )

        attack_wire = copy.deepcopy(wire)
        attack_wire["phase"] = "ATTACK"
        attack_pending = copy.deepcopy(pending)
        attack_pending["metadata"]["finish_attack_actor"] = 0
        attack_pending["metadata"]["continuation"]["_resume"].update({
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 0,
                },
                "pending_after_damage_trigger_specs": [],
            },
        })
        attack_native = _public_native_vm_continuation(
            attack_wire,
            attack_pending,
            0,
        )
        self.assertTrue(attack_native["finish_attack"])
        self.assertEqual(attack_native["context_mode"], "attack")

        changed_opponent = copy.deepcopy(wire)
        changed_opponent["players"][1]["hand"] = [
            "different-hidden-card",
            "another-hidden-card",
        ]
        self.assertEqual(
            _public_native_vm_continuation(
                changed_opponent,
                pending,
                0,
            ),
            native,
        )

        malformed = copy.deepcopy(pending)
        malformed["options"][0]["ref"]["card_id"] = (
            "opponent-hidden-card"
        )
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(wire, malformed, 0)

    def test_native_bridge_rebuilds_visible_item_and_tool_search_vm(self):
        wire = {
            "phase": "MAIN",
            "active_player_idx": 1,
            "players": [
                {
                    "deck": ["opponent-hidden-card"],
                    "discard": [],
                },
                {
                    "deck": [
                        "sv1-150",
                        "sv1-150",
                        "sv1-ener-8",
                        "sv1-201",
                    ],
                    "discard": [],
                    "bench": [None, None, None, None, None],
                },
            ],
        }
        options = []
        for index, card_id, label in (
            (0, "sv1-150", "Switch"),
            (1, "sv1-150", "Switch"),
            (3, "sv1-201", "Defiance Band"),
        ):
            options.append({
                "option_id": f"card:1:deck:{index}:{card_id}",
                "label": label,
                "ref": {
                    "kind": "card",
                    "player": 1,
                    "zone": "deck",
                    "slot": "",
                    "index": index,
                    "attachment_type": "",
                    "card_id": card_id,
                },
                "value": card_id,
            })
        pending = {
            "request_id": "choice:105:1:search_deck:1",
            "request_type": "search_deck",
            "player": 1,
            "min_select": 1,
            "max_select": 2,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": options,
            "metadata": {
                "continuation": {
                    "kind": "search_item_and_tool",
                    "player_idx": 1,
                    "_resume": {
                        "version": 1,
                        "player_idx": 1,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [],
                        "unsupported_frames": [],
                        "context": {},
                        "attack_failed": False,
                    },
                },
            },
        }
        card_definitions = {
            "sv1-150": {"trainer_type": "Item"},
            "sv1-201": {"trainer_type": "Tool"},
            "sv1-ener-8": {"trainer_type": ""},
        }

        native = _public_native_vm_continuation(
            wire,
            pending,
            1,
            card_definitions,
        )

        self.assertEqual(native, {
            "kind": "vm",
            "actor": 1,
            "finish_attack": False,
            "vm": {
                "op": "search_item_and_tool",
                "command_spec": {
                    "op": "search_item_and_tool",
                    "args": {},
                },
                "actor": 1,
                "source_slot": "active",
                "stage": 0,
            },
            "context": {},
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "",
        })
        self.assertNotIn("opponent-hidden-card", repr(native))
        self.assertNotIn("sv1-150", repr(native))
        self.assertNotIn("sv1-201", repr(native))

        changed_opponent = copy.deepcopy(wire)
        changed_opponent["players"][0]["deck"] = [
            "different-hidden-card",
            "another-hidden-card",
        ]
        self.assertEqual(
            _public_native_vm_continuation(
                changed_opponent,
                pending,
                1,
                card_definitions,
            ),
            native,
        )

        missing_option = copy.deepcopy(pending)
        missing_option["options"].pop()
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(
                wire,
                missing_option,
                1,
                card_definitions,
            )

        wrong_category = copy.deepcopy(card_definitions)
        wrong_category["sv1-201"] = {"trainer_type": "Supporter"}
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(
                wire,
                pending,
                1,
                wrong_category,
            )

    def test_native_bridge_rebuilds_attack_energy_distribution_vm(self):
        energy_id = "sv1-ener-3"
        targets = [
            ("active", "sv2-tatsu", "Tatsugiri"),
            ("bench_0", "sv2-delib", "Delibird"),
            ("bench_2", "sv2-glast", "Glastrier"),
            ("bench_4", "sv2-staryu", "Staryu"),
        ]
        owner = {
            "deck": ["sv1-ener-5", energy_id],
            "hand": [],
            "active": {"card_id": targets[0][1]},
            "bench": [
                {"card_id": targets[1][1]},
                None,
                {"card_id": targets[2][1]},
                None,
                {"card_id": targets[3][1]},
            ],
        }
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 0,
            "players": [
                owner,
                {
                    "deck": ["opponent-hidden-card"],
                    "hand": [],
                    "active": {"card_id": "opponent-active"},
                    "bench": [None, None, None, None, None],
                },
            ],
        }
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 0,
                },
                "pending_after_damage_trigger_specs": [],
            },
            "attack_failed": False,
        }
        options = []
        for slot, card_id, name in targets:
            ref = {
                "kind": "pokemon",
                "player": 0,
                "zone": "",
                "slot": slot,
                "index": -1,
                "attachment_type": "",
                "card_id": card_id,
            }
            options.append({
                "option_id": (
                    f"energy:0:{energy_id}"
                    f"->pokemon:0:{slot}:{card_id}"
                ),
                "label": f"Water Energy -> {name}",
                "ref": ref,
                "value": {
                    "slot": slot,
                    "name": name,
                    "energy_index": 0,
                    "energy_card_id": energy_id,
                },
            })
        pending = {
            "request_id": "choice:82:0:distribute_energy:1",
            "request_type": "distribute_energy",
            "player": 0,
            "min_select": 0,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": True,
            "options": options,
            "metadata": {
                "domain": "distribute_energy",
                "distribute_mode": "distribute",
                "max_per_target": 2,
                "same_target": True,
                "source_player": 0,
                "source_zone": "deck",
                "purpose": "energy_attach_distribution",
                "pending_card_id": "",
                "card_ids": [energy_id],
                "card_list_ids": [energy_id],
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "energy_attach_distribution",
                    "player_idx": 0,
                    "source_zone": "deck",
                    "zone_name": "牌库",
                    "max_per_target": 2,
                    "same_target": True,
                    "_resume": resume,
                },
            },
        }
        definitions = {
            energy_id: {
                "supertype": "Energy",
                "energy_effects": [],
            },
        }

        native = _public_native_vm_continuation(
            wire,
            pending,
            0,
            definitions,
        )

        self.assertEqual(native, {
            "kind": "vm",
            "actor": 0,
            "finish_attack": True,
            "vm": {
                "op": "attach_energy",
                "command_spec": {
                    "op": "attach_energy",
                    "args": {
                        "amount": 1,
                        "from_zone": "deck",
                        "filter": "any",
                        "to": "any",
                        "optional": True,
                        "select_source": True,
                        "min_select": 0,
                        "same_target": True,
                        "max_per_target": 2,
                    },
                },
                "actor": 0,
                "source_slot": "active",
                "stage": 0,
                "effective_amount": 1,
                "distribution": True,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "attack",
        })
        self.assertNotIn(energy_id, repr(native))
        self.assertNotIn("opponent-hidden-card", repr(native))

        reactive_pending = copy.deepcopy(pending)
        reactive_pending["metadata"]["continuation"]["_resume"][
            "context"
        ]["pending_after_damage_trigger_specs"] = [{
            "op": "trigger_place_damage_counters",
            "args": {
                "player": 0,
                "slot": "active",
                "count": 6,
                "source": "团结一致",
                "target_ref": {
                    "kind": "pokemon",
                    "player": 0,
                    "slot": "active",
                    "card_id": targets[0][1],
                },
            },
            "branches": {},
        }]
        reactive_native = _public_native_vm_continuation(
            wire,
            reactive_pending,
            0,
            definitions,
        )
        self.assertEqual(reactive_native["post_vm_trigger_groups"], [{
            "owner": 0,
            "specs": [{
                "op": "trigger_place_damage_counters",
                "args": {
                    "player": 0,
                    "slot": "active",
                    "count": 6,
                    "target_card_id": targets[0][1],
                },
            }],
        }])
        self.assertNotIn("团结一致", repr(reactive_native))

        wrong_reactive_target = copy.deepcopy(reactive_pending)
        wrong_reactive_target["metadata"]["continuation"]["_resume"][
            "context"
        ]["pending_after_damage_trigger_specs"][0]["args"][
            "target_ref"
        ]["card_id"] = "opponent-hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_trigger_queue_invalid",
        ):
            _public_native_vm_continuation(
                wire,
                wrong_reactive_target,
                0,
                definitions,
            )

        hand_wire = copy.deepcopy(wire)
        hand_wire["players"][0]["deck"] = ["sv1-ener-5"]
        hand_wire["players"][0]["hand"] = [energy_id]
        hand_pending = copy.deepcopy(pending)
        hand_pending["options"] = [
            copy.deepcopy(options[1]),
        ]
        hand_pending["options"][0]["value"]["bench_idx"] = 0
        hand_metadata = hand_pending["metadata"]
        hand_metadata["source_zone"] = "hand"
        hand_metadata["max_per_target"] = 99
        hand_formal = hand_metadata["continuation"]
        hand_formal["source_zone"] = "hand"
        hand_formal["zone_name"] = "手牌"
        hand_formal["max_per_target"] = 99
        hand_native = _public_native_vm_continuation(
            hand_wire,
            hand_pending,
            0,
            definitions,
        )
        hand_args = hand_native["vm"]["command_spec"]["args"]
        self.assertEqual(hand_args["from_zone"], "hand")
        self.assertEqual(hand_args["to"], "bench")
        self.assertEqual(hand_args["max_per_target"], 99)

        triggered = copy.deepcopy(definitions)
        triggered[energy_id]["energy_effects"] = [{
            "trigger": "ON_ATTACH",
        }]
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(
                wire,
                pending,
                0,
                triggered,
            )

    def test_native_bridge_rebuilds_attack_attach_energy_board_vm(self):
        energy_id = "sv1-ener-5"
        active_id = "sv1-113"
        bench_id = "sv1-111"
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 0,
            "players": [
                {
                    "deck": [energy_id, "svi-rese"],
                    "hand": [],
                    "active": {"card_id": active_id},
                    "bench": [
                        {"card_id": bench_id},
                        None,
                        None,
                        None,
                        None,
                    ],
                },
                {
                    "deck": ["opponent-hidden-card"],
                    "hand": [],
                    "active": {"card_id": "opponent-active"},
                    "bench": [None, None, None, None, None],
                },
            ],
        }
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 0,
                },
                "pending_after_damage_trigger_specs": [],
            },
            "attack_failed": False,
        }

        def target_option(slot, card_id):
            return {
                "option_id": f"pokemon:0:{slot}:{card_id}",
                "label": card_id,
                "ref": {
                    "kind": "pokemon",
                    "player": 0,
                    "zone": "",
                    "slot": slot,
                    "index": -1,
                    "attachment_type": "",
                    "card_id": card_id,
                },
                "value": card_id,
            }

        pending = {
            "request_id": "choice:116:0:search_deck:1",
            "request_type": "search_deck",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [
                target_option("active", active_id),
                target_option("bench_0", bench_id),
            ],
            "metadata": {
                "from_zone": "board",
                "target_player": "self",
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "attach_energy_to_board",
                    "player_idx": 0,
                    "source_zone": "deck",
                    "zone_name": "牌库",
                    "filter_type": "any",
                    "amount": 1,
                    "optional": False,
                    "_resume": resume,
                },
            },
        }
        definitions = {
            energy_id: {
                "supertype": "Energy",
                "subtypes": ["Basic"],
                "provides_energy": ["Psychic"],
                "energy_effects": [],
            },
            "svi-rese": {
                "supertype": "Trainer",
                "energy_effects": [],
            },
        }

        native = _public_native_vm_continuation(
            wire,
            pending,
            0,
            definitions,
        )

        self.assertEqual(native, {
            "kind": "vm",
            "actor": 0,
            "finish_attack": True,
            "vm": {
                "op": "attach_energy",
                "command_spec": {
                    "op": "attach_energy",
                    "args": {
                        "amount": 1,
                        "from_zone": "deck",
                        "filter": "any",
                        "to": "any",
                        "optional": False,
                    },
                },
                "actor": 0,
                "source_slot": "active",
                "stage": 0,
                "effective_amount": 1,
                "distribution": False,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "attack",
        })
        self.assertNotIn(energy_id, repr(native))
        self.assertNotIn("opponent-hidden-card", repr(native))

        triggered = copy.deepcopy(definitions)
        triggered[energy_id]["energy_effects"] = [{
            "trigger": "ON_ATTACH",
        }]
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(
                wire,
                pending,
                0,
                triggered,
            )

    def test_native_bridge_rebuilds_attack_look_top_attach_vm(self):
        top_card_ids = [
            "sv3-134",
            "sv1-ener-8",
            "sv1-180",
            "svm-zamazenta",
            "sv1-ener-8",
        ]
        deck = [
            "sv1-ener-5",
            *reversed(top_card_ids),
        ]
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 0,
                },
                "pending_after_damage_trigger_specs": [],
            },
            "attack_failed": False,
        }
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 0,
            "players": [
                {"deck": deck},
                {"deck": ["opponent-hidden-card"]},
            ],
        }
        pending = {
            "request_id": "choice:82:0:search_deck:1",
            "request_type": "search_deck",
            "player": 0,
            "min_select": 0,
            "max_select": 2,
            "allow_duplicates": False,
            "can_cancel": True,
            "options": [
                {
                    "option_id": "card:0:deck:4:sv1-ener-8",
                    "label": "energy 1",
                    "ref": {
                        "kind": "card",
                        "player": 0,
                        "zone": "deck",
                        "slot": "",
                        "index": 4,
                        "attachment_type": "",
                        "card_id": "sv1-ener-8",
                    },
                    "value": "sv1-ener-8",
                },
                {
                    "option_id": "card:0:deck:1:sv1-ener-8",
                    "label": "energy 2",
                    "ref": {
                        "kind": "card",
                        "player": 0,
                        "zone": "deck",
                        "slot": "",
                        "index": 1,
                        "attachment_type": "",
                        "card_id": "sv1-ener-8",
                    },
                    "value": "sv1-ener-8",
                },
            ],
            "metadata": {
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "look_top_attach_energy",
                    "player_idx": 0,
                    "count": 5,
                    "take": 99,
                    "top_card_ids": top_card_ids,
                    "display_top_positions": [1, 4],
                    "_resume": resume,
                },
            },
        }

        native = _public_native_vm_continuation(wire, pending, 0)

        self.assertEqual(native, {
            "kind": "vm",
            "actor": 0,
            "finish_attack": True,
            "vm": {
                "op": "look_top_attach_energy",
                "command_spec": {
                    "op": "look_top_attach_energy",
                    "args": {
                        "count": 5,
                        "take": 99,
                        "shuffle_rest": True,
                        "target": "self_or_bench",
                    },
                },
                "actor": 0,
                "source_slot": "active",
                "stage": 0,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "attack",
        })
        self.assertNotIn("top_card_ids", repr(native))
        self.assertNotIn("opponent-hidden-card", repr(native))

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["_resume"]["context"][
            "pending_after_damage_trigger_specs"
        ] = [{
            "op": "must_not_cross",
            "args": {"private_card_id": "opponent-hidden-card"},
            "branches": {},
        }]
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(wire, malformed, 0)

    def test_native_bridge_rebuilds_draw_attach_with_public_cancel_delta(self):
        state, _decks = self._native_search_fixture()
        owner = state["players"][0]
        target = owner["bench"][0]
        if not isinstance(target, dict):
            target = copy.deepcopy(owner["active"])
            target["card_id"] = "sv2-delib"
            target["energy_card_ids"] = []
            owner["bench"][0] = target
        owner["hand"] = [
            "sv1-ener-1",
            "sv1-ener-3",
            "sv1-ener-3",
        ]
        owner["deck"] = ["a-hidden-0", "a-hidden-1"]
        owner["discard"] = ["svg2-gard"]
        owner["supporter_played_this_turn"] = True
        state["revision"] = 1
        state["choice_sequence"] = 1
        state["resolution_stack"] = {
            "schema_version": 3,
            "frames": [],
            "pending_request": None,
            "sequence": 1,
            "context": {
                "cancel_action_checkpoint": {
                    "state": {
                        "phase": "MAIN",
                        "active_player_idx": 0,
                        "revision": 0,
                        "choice_sequence": 0,
                        "p1": {
                            "hand_ids": [
                                "svg2-gard",
                                "sv1-ener-1",
                            ],
                            "deck_ids": [
                                "a-hidden-0",
                                "a-hidden-1",
                                "sv1-ener-3",
                                "sv1-ener-3",
                            ],
                            "discard_ids": [],
                            "supporter_played": False,
                        },
                        "p2": {
                            "hand_ids": ["must-not-cross-opponent-hand"],
                            "deck_ids": ["must-not-cross-opponent-deck"],
                            "discard_ids": [],
                            "supporter_played": False,
                        },
                    },
                    "rng_state": ["must-not-cross-rng"],
                    "action_log": ["must-not-cross-action-log"],
                    "events": [{"must-not-cross": True}],
                },
            },
        }
        option = {
            "option_id": (
                "energy:0:sv1-ener-1->"
                f"pokemon:0:bench_0:{target['card_id']}"
            ),
            "label": "Grass Energy",
            "ref": {
                "kind": "pokemon",
                "player": 0,
                "zone": "",
                "slot": "bench_0",
                "index": -1,
                "attachment_type": "",
                "card_id": target["card_id"],
            },
            "value": {
                "slot": "bench_0",
                "name": "target",
                "bench_idx": 0,
                "energy_index": 0,
                "energy_card_id": "sv1-ener-1",
            },
        }
        pending = {
            "request_id": "choice:1:0:distribute_energy:0",
            "request_type": "distribute_energy",
            "player": 0,
            "options": [option],
            "min_select": 0,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": True,
            "metadata": {
                "domain": "distribute_energy",
                "distribute_mode": "distribute",
                "max_per_target": 1,
                "pending_card_id": "",
                "card_ids": ["sv1-ener-1"],
                "card_list_ids": ["sv1-ener-1"],
                "purpose": "draw_and_attach_energy_distribution",
                "source_player": 0,
                "source_zone": "",
                "same_target": True,
                "continuation": {
                    "kind": "draw_and_attach_energy_distribution",
                    "player_idx": 0,
                    "max_per_target": 1,
                    "same_target": True,
                    "energy_type": "Grass",
                    "_resume": {
                        "version": 1,
                        "player_idx": 0,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [],
                        "unsupported_frames": [],
                        "context": {},
                        "attack_failed": False,
                    },
                },
            },
        }

        continuation = _public_native_vm_continuation(
            state,
            pending,
            0,
        )

        self.assertEqual(continuation["kind"], "vm")
        self.assertEqual(
            continuation["vm"]["command_spec"],
            {
                "op": "draw_and_attach_energy",
                "args": {
                    "energy_count": 1,
                    "energy_type": "Grass",
                    "min_select": 0,
                },
            },
        )
        self.assertEqual(
            continuation["cancel_rollback"],
            {
                "hand_before": ["svg2-gard", "sv1-ener-1"],
                "discard_before": [],
                "deck_top_before": [
                    "sv1-ener-3",
                    "sv1-ener-3",
                ],
                "expected_current_deck_count": 2,
                "supporter_played_before": False,
                "choice_sequence_before": 0,
            },
        )
        self.assertNotIn("must-not-cross", repr(continuation))

        cancelled = self.game.resume_choice(
            state,
            continuation,
            [],
            True,
            991,
        )
        self.assertTrue(cancelled["success"], cancelled)
        restored = cancelled["state"]
        self.assertEqual(
            restored["players"][0]["hand"],
            ["svg2-gard", "sv1-ener-1"],
        )
        self.assertEqual(restored["players"][0]["discard"], [])
        self.assertEqual(
            restored["players"][0]["deck"],
            [
                "a-hidden-0",
                "a-hidden-1",
                "sv1-ener-3",
                "sv1-ener-3",
            ],
        )
        self.assertFalse(
            restored["players"][0]["supporter_played_this_turn"]
        )
        self.assertEqual(restored["choice_sequence"], 0)
        self.assertEqual(restored["revision"], 2)

        flattened = {
            **option["value"],
            **option["ref"],
            "option_id": option["option_id"],
        }
        attached = self.game.resume_choice(
            state,
            continuation,
            [flattened],
            False,
            991,
        )
        self.assertTrue(attached["success"], attached)
        self.assertEqual(
            attached["state"]["players"][0]["hand"],
            ["sv1-ener-3", "sv1-ener-3"],
        )
        self.assertEqual(
            attached["state"]["players"][0]["bench"][0][
                "energy_card_ids"
            ][-1],
            "sv1-ener-1",
        )

    def test_native_bridge_rebuilds_only_public_draw_trigger_queue(self):
        specs = [
            {
                "op": "trigger_draw_cards",
                "args": {
                    "player": 1,
                    "amount": 1,
                    "source": f"public-source-{index}",
                },
                "branches": {},
            }
            for index in range(3)
        ]
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 0,
                },
            },
            "attack_failed": False,
        }
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 0,
            "players": [
                {
                    "active": {"card_id": "public-active-0"},
                    "bench": [],
                },
                {
                    "active": {"card_id": "public-active-1"},
                    "bench": [],
                },
            ],
        }
        pending = {
            "request_id": "choice:60:1:choose_trigger_order:8",
            "request_type": "choose_trigger_order",
            "player": 1,
            "metadata": {
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "choose_trigger_order",
                    "domain": "trigger",
                    "frame_id": "trigger:order",
                    "specs": specs,
                    "chooser": 1,
                    "_resume": resume,
                },
            },
        }

        native = _public_native_trigger_continuation(
            wire,
            pending,
            1,
        )

        self.assertEqual(native, {
            "kind": "public_trigger_order",
            "actor": 1,
            "attack_actor": 0,
            "trigger_owner": 1,
            "trigger_specs": [
                {
                    "op": "trigger_draw_cards",
                    "args": {"player": 1, "amount": 1},
                },
                {
                    "op": "trigger_draw_cards",
                    "args": {"player": 1, "amount": 1},
                },
                {
                    "op": "trigger_draw_cards",
                    "args": {"player": 1, "amount": 1},
                },
            ],
            "remaining_trigger_groups": [],
            "attack_context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
        })
        self.assertNotIn("public-source", repr(native))

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["specs"][0]["args"][
            "private_card_id"
        ] = "opponent-hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_trigger_continuation_invalid",
        ):
            _public_native_trigger_continuation(
                wire,
                malformed,
                1,
            )

    def test_native_bridge_rebuilds_public_any_damage_pause(self):
        state, _decks = self._native_search_fixture()
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        defender = state["players"][1]["active"]
        defender["damage_counters"] = 0
        bench_target = copy.deepcopy(defender)
        bench_target["damage_counters"] = 0
        state["players"][1]["bench"] = [
            bench_target,
            None,
            None,
            None,
            None,
        ]
        active_id = defender["card_id"]
        bench_id = bench_target["card_id"]
        active_option_id = f"pokemon:1:active:{active_id}"
        bench_option_id = f"pokemon:1:bench_0:{bench_id}"
        pending = {
            "request_id": "choice:97:0:search_deck:1",
            "request_type": "search_deck",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [
                {
                    "option_id": active_option_id,
                    "label": "active",
                    "ref": {
                        "kind": "pokemon",
                        "player": 1,
                        "zone": "",
                        "slot": "active",
                        "index": -1,
                        "attachment_type": "",
                        "card_id": active_id,
                    },
                    "value": active_id,
                },
                {
                    "option_id": bench_option_id,
                    "label": "bench 0",
                    "ref": {
                        "kind": "pokemon",
                        "player": 1,
                        "zone": "",
                        "slot": "bench_0",
                        "index": -1,
                        "attachment_type": "",
                        "card_id": bench_id,
                    },
                    "value": bench_id,
                },
            ],
            "metadata": {
                "domain": "search_deck",
                "from_zone": "board",
                "target_player": "opponent",
                "card_list_ids": [active_id, bench_id],
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "choose_damage_target",
                    "target_player_idx": 1,
                    "amount": 40,
                    "_resume": {
                        "version": 1,
                        "player_idx": 0,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [
                            {
                                "kind": "finalize_attack_turn",
                                "actor": 0,
                            },
                            {"kind": "finalize_attack_ko_checks"},
                            {
                                "kind":
                                    "finalize_after_damage_triggers",
                            },
                            {"kind": "finalize_attack_damage"},
                        ],
                        "unsupported_frames": [],
                        "context": {
                            "attack_damage": {
                                "active": True,
                                "player_idx": 0,
                                "base_damage": 0,
                                "attacker_type": "Water",
                                "ignore_weakness": False,
                                "ignore_resistance": False,
                                "ignore_defender_damage_effects": False,
                                "attacker_ref": {
                                    "player": 0,
                                    "slot": "active",
                                    "card_id": state["players"][0][
                                        "active"
                                    ]["card_id"],
                                },
                            },
                            "attack_resolution": {
                                "active": True,
                                "player_idx": 0,
                            },
                        },
                        "attack_failed": False,
                    },
                },
            },
        }

        continuation = _public_native_vm_continuation(
            state,
            pending,
            0,
        )

        self.assertEqual(continuation["kind"], "vm")
        self.assertEqual(
            continuation["vm"]["command_spec"],
            {
                "op": "choose_damage_target",
                "args": {"amount": 40, "player": "opponent"},
            },
        )
        resumed = self.game.resume_choice(
            state,
            continuation,
            [{
                "option_id": bench_option_id,
                "kind": "pokemon",
                "player": 1,
                "slot": "bench_0",
                "card_id": bench_id,
            }],
            False,
            0x44414D47,
        )
        self.assertTrue(resumed["success"], resumed)
        self.assertEqual(
            resumed["state"]["players"][1]["active"][
                "damage_counters"
            ],
            0,
        )
        self.assertEqual(
            resumed["state"]["players"][1]["bench"][0][
                "damage_counters"
            ],
            4,
        )

        hidden = copy.deepcopy(pending)
        hidden["options"][1]["ref"]["card_id"] = "hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_vm_continuation_invalid",
        ):
            _public_native_vm_continuation(state, hidden, 0)

    def test_native_bridge_rebuilds_public_bench_damage_pause(self):
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 0,
            "players": [
                {
                    "active": {"card_id": "public-attacker"},
                    "bench": [None, None, None, None, None],
                },
                {
                    "active": {"card_id": "public-defender"},
                    "bench": [
                        None,
                        None,
                        {"card_id": "public-bench-2"},
                        None,
                        {"card_id": "public-bench-4"},
                    ],
                },
            ],
        }
        trigger_spec = {
            "op": "trigger_draw_cards",
            "args": {
                "player": 1,
                "amount": 1,
                "source": "must-not-cross",
            },
            "branches": {},
        }
        pending = {
            "request_id": "choice:69:0:select_bench_targets:1",
            "request_type": "select_bench_targets",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": False,
            "options": [
                {
                    "option_id": (
                        "pokemon:1:bench_2:public-bench-2"
                    ),
                    "label": "bench 2",
                    "ref": {
                        "kind": "pokemon",
                        "player": 1,
                        "zone": "",
                        "slot": "bench_2",
                        "index": -1,
                        "attachment_type": "",
                        "card_id": "public-bench-2",
                    },
                    "value": 2,
                },
                {
                    "option_id": (
                        "pokemon:1:bench_4:public-bench-4"
                    ),
                    "label": "bench 4",
                    "ref": {
                        "kind": "pokemon",
                        "player": 1,
                        "zone": "",
                        "slot": "bench_4",
                        "index": -1,
                        "attachment_type": "",
                        "card_id": "public-bench-4",
                    },
                    "value": 4,
                },
            ],
            "metadata": {
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "bench_damage_targets",
                    "target_player_idx": 1,
                    "amount": 30,
                    "count": 1,
                    "bench_indices": [2, 4],
                    "_resume": {
                        "version": 1,
                        "player_idx": 0,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [
                            {
                                "kind": "finalize_attack_turn",
                                "actor": 0,
                            },
                            {"kind": "finalize_attack_ko_checks"},
                            {
                                "kind":
                                    "finalize_after_damage_triggers",
                            },
                        ],
                        "unsupported_frames": [],
                        "context": {
                            "attack_resolution": {
                                "active": True,
                                "player_idx": 0,
                            },
                            "pending_after_damage_trigger_specs": [
                                trigger_spec
                            ],
                        },
                        "attack_failed": False,
                    },
                },
            },
        }

        native = _public_native_bench_damage_continuation(
            wire,
            pending,
            0,
        )

        self.assertEqual(native, {
            "kind": "public_bench_damage_targets",
            "actor": 0,
            "attack_actor": 0,
            "target_player": 1,
            "amount": 30,
            "count": 1,
            "allowed_targets": [
                {
                    "option_id": (
                        "pokemon:1:bench_2:public-bench-2"
                    ),
                    "target_slot": "bench_2",
                    "target_card_id": "public-bench-2",
                },
                {
                    "option_id": (
                        "pokemon:1:bench_4:public-bench-4"
                    ),
                    "target_slot": "bench_4",
                    "target_card_id": "public-bench-4",
                },
            ],
            "trigger_groups": [{
                "owner": 1,
                "specs": [{
                    "op": "trigger_draw_cards",
                    "args": {"player": 1, "amount": 1},
                }],
            }],
        })
        self.assertNotIn("must-not-cross", repr(native))

        hidden = copy.deepcopy(pending)
        hidden["metadata"]["continuation"]["_resume"]["context"][
            "private_card_id"
        ] = "opponent-hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_bench_damage_continuation_invalid",
        ):
            _public_native_bench_damage_continuation(
                wire,
                hidden,
                0,
            )

    def test_native_vm_resume_consumes_public_post_damage_trigger(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["turn_number"] = 13
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        attacker = state["players"][0]["active"]
        attacker["card_id"] = "svm-cobalion"
        attacker["damage_counters"] = 0
        attacker["energy_card_ids"] = []
        state["players"][0]["deck"] = [
            "sv1-ener-5",
            "sv1-ener-3",
        ]
        continuation = {
            "kind": "vm",
            "actor": 0,
            "finish_attack": True,
            "vm": {
                "op": "attach_energy",
                "command_spec": {
                    "op": "attach_energy",
                    "args": {
                        "amount": 1,
                        "from_zone": "deck",
                        "filter": "any",
                        "to": "any",
                        "optional": True,
                        "select_source": True,
                        "min_select": 0,
                        "same_target": True,
                        "max_per_target": 2,
                    },
                },
                "actor": 0,
                "source_slot": "active",
                "stage": 0,
                "effective_amount": 1,
                "distribution": True,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "attack",
            "post_vm_trigger_groups": [{
                "owner": 0,
                "specs": [{
                    "op": "trigger_place_damage_counters",
                    "args": {
                        "player": 0,
                        "slot": "active",
                        "count": 6,
                        "target_card_id": "svm-cobalion",
                    },
                }],
            }],
        }
        selected = [{
            "option_id": (
                "energy:0:sv1-ener-3"
                "->pokemon:0:active:svm-cobalion"
            ),
            "slot": "active",
            "energy_index": 0,
            "energy_card_id": "sv1-ener-3",
        }]

        result = self.game.resume_choice(
            state,
            continuation,
            selected,
            False,
            0x434F4241,
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertIn(
            "sv1-ener-3",
            result["state"]["players"][0]["active"][
                "energy_card_ids"
            ],
        )
        self.assertEqual(
            result["state"]["players"][0]["active"][
                "damage_counters"
            ],
            6,
        )
        self.assertEqual(result["state"]["active_player_idx"], 1)
        self.assertEqual(result["state"]["phase"], "MAIN")

        invalid = copy.deepcopy(continuation)
        invalid["post_vm_trigger_groups"][0]["specs"][0]["args"][
            "target_card_id"
        ] = "opponent-hidden-card"
        rejected = self.game.resume_choice(
            state,
            invalid,
            selected,
            False,
            0x434F4241,
        )
        self.assertFalse(rejected["success"])
        self.assertEqual(
            rejected["error_code"],
            "public_trigger_target_mismatch",
        )

    def test_native_public_bench_damage_resume_is_post_hit_only(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["players"][0]["active"]["modifiers"] = []
        state["players"][0]["active"]["outgoing_damage_reduction"] = 0
        defender = state["players"][1]["active"]
        defender["damage_counters"] = 2
        defender["modifiers"] = []
        bench_2 = copy.deepcopy(defender)
        bench_2["damage_counters"] = 0
        bench_4 = copy.deepcopy(defender)
        bench_4["damage_counters"] = 0
        state["players"][1]["bench"] = [
            None,
            None,
            bench_2,
            None,
            bench_4,
        ]
        card_id = defender["card_id"]
        continuation = {
            "kind": "public_bench_damage_targets",
            "actor": 0,
            "attack_actor": 0,
            "target_player": 1,
            "amount": 30,
            "count": 1,
            "allowed_targets": [
                {
                    "option_id": f"pokemon:1:bench_2:{card_id}",
                    "target_slot": "bench_2",
                    "target_card_id": card_id,
                },
                {
                    "option_id": f"pokemon:1:bench_4:{card_id}",
                    "target_slot": "bench_4",
                    "target_card_id": card_id,
                },
            ],
            "trigger_groups": [],
        }

        result = self.game.resume_choice(
            state,
            continuation,
            [{"option_id": f"pokemon:1:bench_2:{card_id}"}],
            False,
            0x42454E43,
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(
            result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            2,
        )
        self.assertEqual(
            result["state"]["players"][1]["bench"][2][
                "damage_counters"
            ],
            3,
        )
        self.assertEqual(
            result["state"]["players"][1]["bench"][4][
                "damage_counters"
            ],
            0,
        )
        self.assertEqual(result["state"]["active_player_idx"], 1)
        self.assertEqual(result["state"]["phase"], "MAIN")

    def test_native_bridge_rebuilds_public_exp_share_chain(self):
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 1,
            "players": [
                {
                    "active": {"card_id": "svg2-tort"},
                    "bench": [{
                        "card_id": "svg2-shro",
                        "attached_tool_id": "svg2-exps",
                    }],
                },
                {
                    "active": {"card_id": "svi-ente"},
                    "bench": [],
                },
            ],
        }
        exp_share_spec = {
            "op": "trigger_move_basic_energy",
            "args": {
                "from_player": 0,
                "from_slot": "active",
                "to_player": 0,
                "to_slot": "bench_0",
                "source": "public-exp-share",
                "select_source": True,
                "optional": True,
                "target_tool_id": "svg2-exps",
            },
            "branches": {},
        }
        pending = {
            "request_id": "choice:101:0:confirm_trigger:7",
            "request_type": "confirm_trigger",
            "player": 0,
            "metadata": {
                "finish_attack_actor": 1,
                "continuation": {
                    "kind": "confirm_exp_share_trigger",
                    "domain": "trigger",
                    "frame_id": (
                        "trigger:exp_share:0:active:0:bench_0"
                    ),
                    "from_player": 0,
                    "from_slot": "active",
                    "from_card_id": "svg2-tort",
                    "to_player": 0,
                    "to_slot": "bench_0",
                    "to_card_id": "svg2-shro",
                    "source_name": "学习装置",
                    "target_tool_id": "svg2-exps",
                    "_resume": {
                        "version": 1,
                        "player_idx": 1,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [
                            {
                                "kind": "finalize_attack_turn",
                                "actor": 1,
                            },
                            {
                                "kind": "discard_knockout_batch",
                                "entries": [{
                                    "player_idx": 0,
                                    "slot": "active",
                                    "card_id": "svg2-tort",
                                    "prize_count": 1,
                                }],
                            },
                            {
                                "kind": "trigger_order",
                                "specs": [exp_share_spec],
                            },
                        ],
                        "unsupported_frames": [],
                        "context": {
                            "attack_resolution": {
                                "active": True,
                                "player_idx": 1,
                            },
                        },
                        "attack_failed": False,
                    },
                },
            },
        }

        native = _public_native_exp_share_continuation(
            wire,
            pending,
            0,
        )

        self.assertEqual(native, {
            "kind": "confirm_exp_share_trigger",
            "actor": 0,
            "attack_actor": 1,
            "from_player": 0,
            "from_slot": "active",
            "from_card_id": "svg2-tort",
            "to_player": 0,
            "to_slot": "bench_0",
            "to_card_id": "svg2-shro",
            "target_tool_id": "svg2-exps",
            "knockout_entries": [{
                "player_idx": 0,
                "slot": "active",
                "card_id": "svg2-tort",
                "prize_count": 1,
            }],
            "remaining_exp_share_triggers": 1,
            "remaining_exp_share_requires_order": False,
        })
        self.assertNotIn("public-exp-share", repr(native))

        double_ko = copy.deepcopy(pending)
        double_entries = double_ko["metadata"]["continuation"][
            "_resume"
        ]["frames"][1]["entries"]
        double_entries.insert(0, {
            "player_idx": 1,
            "slot": "active",
            "card_id": "svi-ente",
            "prize_count": 1,
        })
        double_native = _public_native_exp_share_continuation(
            wire,
            double_ko,
            0,
        )
        self.assertEqual(
            double_native["knockout_entries"],
            double_entries,
        )

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["to_card_id"] = (
            "opponent-hidden-card"
        )
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_exp_share_continuation_invalid",
        ):
            _public_native_exp_share_continuation(
                wire,
                malformed,
                0,
            )

    def test_native_bridge_rebuilds_public_exp_share_trigger_order(self):
        wire = {
            "phase": "ATTACK",
            "active_player_idx": 1,
            "players": [
                {
                    "active": {"card_id": "svg2-tort"},
                    "bench": [
                        {
                            "card_id": "svg2-shro",
                            "attached_tool_id": "svg2-exps",
                        },
                        {
                            "card_id": "svg2-venu",
                            "attached_tool_id": "svg2-exps",
                        },
                    ],
                },
                {
                    "active": {"card_id": "svi-ente"},
                    "bench": [],
                },
            ],
        }
        resume = {
            "version": 1,
            "player_idx": 1,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 1},
                {
                    "kind": "discard_knockout_batch",
                    "entries": [{
                        "player_idx": 0,
                        "slot": "active",
                        "card_id": "svg2-tort",
                        "prize_count": 1,
                    }],
                },
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {"active": True, "player_idx": 1},
            },
            "attack_failed": False,
        }

        def spec(slot: str, source: str) -> dict:
            return {
                "op": "trigger_move_basic_energy",
                "args": {
                    "from_player": 0,
                    "from_slot": "active",
                    "to_player": 0,
                    "to_slot": slot,
                    "source": source,
                    "select_source": True,
                    "optional": True,
                    "target_tool_id": "svg2-exps",
                },
                "branches": {},
            }

        pending = {
            "request_id": "choice:80:0:choose_trigger_order:19",
            "request_type": "choose_trigger_order",
            "player": 0,
            "metadata": {
                "finish_attack_actor": 1,
                "continuation": {
                    "kind": "choose_trigger_order",
                    "domain": "trigger",
                    "frame_id": "trigger:order",
                    "specs": [
                        spec("bench_0", "first-public-source"),
                        spec("bench_1", "second-public-source"),
                    ],
                    "chooser": 0,
                    "_resume": resume,
                },
            },
        }

        native = _public_native_exp_share_order_continuation(
            wire,
            pending,
            0,
        )

        self.assertEqual(native["kind"], "public_exp_share_spec_order")
        self.assertEqual(native["attack_actor"], 1)
        self.assertEqual(
            [row["to_slot"] for row in native["exp_share_trigger_specs"]],
            ["bench_0", "bench_1"],
        )
        self.assertNotIn("first-public-source", repr(native))
        self.assertNotIn("second-public-source", repr(native))

        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["active_player_idx"] = 1
        owner = state["players"][0]
        owner["active"]["card_id"] = "svg2-tort"
        owner["active"]["energy_card_ids"] = ["sv1-ener-5"]
        while len(owner["bench"]) < 2:
            owner["bench"].append(None)
        owner["bench"][0] = {
            **copy.deepcopy(owner["active"]),
            "card_id": "svg2-shro",
            "energy_card_ids": [],
            "attached_tool_id": "svg2-exps",
        }
        owner["bench"][1] = {
            **copy.deepcopy(owner["active"]),
            "card_id": "svg2-venu",
            "energy_card_ids": [],
            "attached_tool_id": "svg2-exps",
        }
        ordered = self.game.resume_choice(
            state,
            native,
            [{"option_id": "trigger:1"}],
            False,
            17,
        )
        self.assertTrue(ordered["success"], ordered)
        self.assertEqual(ordered["pending"]["request_type"], "confirm_trigger")
        self.assertEqual(ordered["continuation"]["to_slot"], "bench_1")
        skipped = self.game.resume_choice(
            ordered["state"],
            ordered["continuation"],
            [{"option_id": "confirm:no"}],
            False,
            ordered["rng_state"],
        )
        self.assertTrue(skipped["success"], skipped)
        self.assertEqual(skipped["pending"]["request_type"], "confirm_trigger")
        self.assertEqual(skipped["continuation"]["to_slot"], "bench_0")

        malformed = copy.deepcopy(pending)
        malformed["metadata"]["continuation"]["specs"][0]["args"][
            "target_tool_id"
        ] = "opponent-hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_exp_share_order_continuation_invalid",
        ):
            _public_native_exp_share_order_continuation(
                wire,
                malformed,
                0,
            )

    def test_native_bridge_rebuilds_public_damage_trigger_groups(self):
        def damage_spec(player: int, card_id: str) -> dict:
            return {
                "op": "trigger_place_damage_counters",
                "args": {
                    "player": player,
                    "slot": "active",
                    "count": 6,
                    "source": "public-source",
                    "target_ref": {
                        "kind": "pokemon",
                        "player": player,
                        "slot": "active",
                        "card_id": card_id,
                    },
                },
                "branches": {},
            }

        wire = {
            "phase": "ATTACK",
            "active_player_idx": 0,
            "players": [
                {
                    "active": {"card_id": "public-active-0"},
                    "bench": [],
                },
                {
                    "active": {"card_id": "public-active-1"},
                    "bench": [],
                },
            ],
        }
        resume = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [
                {"kind": "finalize_attack_turn", "actor": 0},
                {"kind": "finalize_attack_ko_checks"},
                {
                    "kind": "trigger_order",
                    "specs": [
                        {
                            "op": "trigger_draw_cards",
                            "args": {
                                "player": 1,
                                "amount": 1,
                                "source": "public-draw",
                            },
                            "branches": {},
                        },
                    ],
                },
            ],
            "unsupported_frames": [],
            "context": {
                "attack_resolution": {
                    "active": True,
                    "player_idx": 0,
                },
            },
            "attack_failed": False,
        }
        pending = {
            "request_id": "choice:105:0:choose_trigger_order:1",
            "request_type": "choose_trigger_order",
            "player": 0,
            "metadata": {
                "finish_attack_actor": 0,
                "continuation": {
                    "kind": "choose_trigger_order",
                    "domain": "trigger",
                    "frame_id": "trigger:order",
                    "specs": [
                        damage_spec(0, "public-active-0"),
                        damage_spec(0, "public-active-0"),
                    ],
                    "chooser": 0,
                    "_resume": resume,
                },
            },
        }

        native = _public_native_trigger_continuation(
            wire,
            pending,
            0,
        )

        self.assertEqual(native["kind"], "public_trigger_order")
        self.assertEqual(
            native["trigger_specs"][0],
            {
                "op": "trigger_place_damage_counters",
                "args": {
                    "player": 0,
                    "slot": "active",
                    "count": 6,
                    "target_card_id": "public-active-0",
                },
            },
        )
        self.assertEqual(native["remaining_trigger_groups"], [{
            "owner": 1,
            "specs": [{
                "op": "trigger_draw_cards",
                "args": {"player": 1, "amount": 1},
            }],
        }])
        self.assertNotIn("public-source", repr(native))

        wrong_target = copy.deepcopy(pending)
        wrong_target["metadata"]["continuation"]["specs"][0]["args"][
            "target_ref"
        ]["card_id"] = "opponent-hidden-card"
        with self.assertRaisesRegex(
            NativeBridgeError,
            "native_public_trigger_continuation_invalid",
        ):
            _public_native_trigger_continuation(
                wire,
                wrong_target,
                0,
            )

    def test_native_public_draw_trigger_queue_preserves_choice_nodes(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["players"][1]["hand"] = []
        state["players"][1]["deck"] = [
            "sv1-ener-3",
            "sv1-ener-4",
            "sv1-ener-5",
            "sv1-ener-6",
        ]
        continuation = {
            "kind": "after_damage_trigger_order",
            "actor": 1,
            "attack_actor": 0,
            "trigger_owner": 1,
            "trigger_count": 3,
            "remaining_trigger_groups": [],
            "attack_context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
        }

        first = self.game.resume_choice(
            state,
            continuation,
            [{"option_id": "trigger:2"}],
            False,
            0x54524752,
        )

        self.assertTrue(first["success"], first)
        self.assertEqual(
            first["pending"]["request_type"],
            "choose_trigger_order",
        )
        self.assertEqual(
            first["continuation"]["trigger_count"],
            2,
        )
        self.assertEqual(len(first["state"]["players"][1]["hand"]), 1)

        second = self.game.resume_choice(
            first["state"],
            first["continuation"],
            [{"option_id": "trigger:0"}],
            False,
            first["rng_state"],
        )

        self.assertTrue(second["success"], second)
        self.assertEqual(second["pending"], {})
        # Three trigger draws plus the mandatory next-turn draw.
        self.assertEqual(len(second["state"]["players"][1]["hand"]), 4)
        self.assertEqual(second["state"]["active_player_idx"], 1)
        self.assertEqual(second["state"]["phase"], "MAIN")

        invalid = self.game.resume_choice(
            state,
            continuation,
            [{"option_id": "trigger:3"}],
            False,
            0x54524752,
        )
        self.assertFalse(invalid["success"])
        self.assertEqual(
            invalid["error_code"],
            "trigger_order_selection_invalid",
        )

    def test_native_public_trigger_queue_runs_remaining_owner_group(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["players"][1]["hand"] = []
        state["players"][1]["deck"] = [
            "sv1-ener-3",
            "sv1-ener-4",
            "sv1-ener-5",
        ]
        active = state["players"][0]["active"]
        active_id = active["card_id"]
        initial_damage = active["damage_counters"]
        damage_spec = {
            "op": "trigger_place_damage_counters",
            "args": {
                "player": 0,
                "slot": "active",
                "count": 1,
                "target_card_id": active_id,
            },
        }
        draw_spec = {
            "op": "trigger_draw_cards",
            "args": {"player": 1, "amount": 1},
        }
        continuation = {
            "kind": "public_trigger_order",
            "actor": 0,
            "attack_actor": 0,
            "trigger_owner": 0,
            "trigger_specs": [
                copy.deepcopy(damage_spec),
                copy.deepcopy(damage_spec),
            ],
            "remaining_trigger_groups": [{
                "owner": 1,
                "specs": [
                    copy.deepcopy(draw_spec),
                    copy.deepcopy(draw_spec),
                ],
            }],
            "attack_context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
        }

        first = self.game.resume_choice(
            state,
            continuation,
            [{"option_id": "trigger:1"}],
            False,
            0x50554254,
        )

        self.assertTrue(first["success"], first)
        self.assertEqual(first["pending"]["player"], 1)
        self.assertEqual(
            first["continuation"]["kind"],
            "public_trigger_order",
        )
        self.assertEqual(
            first["state"]["players"][0]["active"][
                "damage_counters"
            ],
            initial_damage + 2,
        )

        second = self.game.resume_choice(
            first["state"],
            first["continuation"],
            [{"option_id": "trigger:0"}],
            False,
            first["rng_state"],
        )

        self.assertTrue(second["success"], second)
        self.assertEqual(second["pending"], {})
        # Two trigger draws plus the mandatory next-turn draw.
        self.assertEqual(len(second["state"]["players"][1]["hand"]), 3)
        self.assertEqual(second["state"]["active_player_idx"], 1)
        self.assertEqual(second["state"]["phase"], "MAIN")

    def test_native_public_prize_resume_finishes_checkup(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "POKEMON_CHECKUP"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["players"][0]["prizes"] = [
            "sv1-ener-3",
            "sv1-ener-4",
        ]
        result = self.game.resume_choice(
            state,
            {
                "kind": "select_prize",
                "actor": 0,
                "remaining_prize_players": [],
                "finish_checkup_after_prizes": True,
                "resume_checkup_actor": 0,
            },
            [{"option_id": "prize:0"}],
            False,
            0x43484B50,
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(result["state"]["active_player_idx"], 1)
        self.assertEqual(result["state"]["phase"], "MAIN")

    def test_native_choice_search_pins_revealed_treasure_prize(self):
        state, _unused_decks = self._native_search_fixture()
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["deck"] = ["sv1-ener-4", "sv1-ener-5"]
        owner["prizes"] = ["svi-trea", "sv1-ener-3"]
        bench = copy.deepcopy(owner["active"])
        bench["card_id"] = "svi-chim"
        bench["energy_card_ids"] = []
        owner["bench"] = [bench, None, None, None, None]
        decks = self._submitted_decks(state)
        wire = mask_native_snapshot(copy.deepcopy(state), 0)
        pending = {
            "request_id": "choice:treasure:0",
            "request_type": "select_prize_energy_target",
            "player": 0,
            "min_select": 0,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": True,
            "options": [{
                "option_id": "pokemon:0:bench_0:svi-chim",
                "ref": {
                    "kind": "pokemon",
                    "player": 0,
                    "zone": "field",
                    "slot": "bench_0",
                    "card_id": "svi-chim",
                },
            }],
            "metadata": {"continuation": {}},
        }
        continuation = {
            "kind": "treasure_prize_target",
            "actor": 0,
            "prize_index": 0,
            "prize_card_id": "svi-trea",
            "remaining_prize_players": [],
            "finish_attack_after_prizes": True,
            "resume_attack_actor": 0,
        }
        batch = ptcg_ai_core.NativeSelfPlayBatch()
        job = ptcg_ai_core.NativeSearchJob(
            self.game_cards,
            decks,
            batch,
        )
        job.start_choice(
            wire,
            0,
            pending,
            continuation,
            0x54524541,
            {
                "simulations": 8,
                "max_depth": 16,
                "dirichlet_epsilon": 0.0,
                "temperature": 0.0,
                "training": False,
                "inference_wait_milliseconds": 10,
            },
        )
        self._serve_uniform_inference(batch, [job])
        result = job.wait()

        self.assertTrue(result["success"], result)
        self.assertEqual(result["simulations"], 8)
        self.assertGreaterEqual(len(result["candidates"]), 2)
        self.assertIn(
            ("pokemon:0:bench_0:svi-chim",),
            {
                tuple(row["selected_options"])
                for row in result["candidates"]
            },
        )

    def test_native_treasure_prize_accepts_authoritative_active_target(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "ATTACK"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        owner = state["players"][0]
        owner["prizes"] = ["svi-trea", "sv1-ener-3"]
        active_id = owner["active"]["card_id"]
        initial_energy = len(owner["active"]["energy_card_ids"])

        result = self.game.resume_choice(
            state,
            {
                "kind": "treasure_prize_target",
                "actor": 0,
                "prize_index": 0,
                "prize_card_id": "svi-trea",
                "remaining_prize_players": [],
                "finish_attack_after_prizes": True,
                "resume_attack_actor": 0,
            },
            [{
                "option_id": f"pokemon:0:active:{active_id}",
                "kind": "pokemon",
                "player": 0,
                "slot": "active",
                "card_id": active_id,
            }],
            False,
            0x54524541,
        )

        self.assertTrue(result["success"], result)
        self.assertEqual(result["pending"], {})
        self.assertEqual(result["state"]["players"][0]["prizes"], [
            "sv1-ener-3",
        ])
        self.assertEqual(
            len(
                result["state"]["players"][0]["active"][
                    "energy_card_ids"
                ]
            ),
            initial_energy + 1,
        )
        self.assertIn(
            "svi-trea",
            result["state"]["players"][0]["active"][
                "energy_card_ids"
            ],
        )

    def test_native_encoder_v7_matches_python_contract(self):
        from data.card_registry import CardRegistry
        from data.deck_definitions import ALL_CARD_IDS
        from engine.actions import (
            AttachmentRef,
            CardRef,
            ChoiceOption,
            ChoiceView,
            GameAction,
            PokemonRef,
            SlotRef,
        )
        from engine.ai.dl.infoset_encoder import InformationSetEncoderV7
        from engine.ai.dl.puct_v2 import _choice_responses
        from engine.ai.observation import Observation

        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        state["public_deck_keys"] = ["psychic", "water"]
        state["players"][0]["hand"] = [
            "sv1-ener-3",
            "svi-chim",
            "sv2-cand",
        ]
        projection = ptcg_ai_core.project_information_set(state, 0)
        observation_state = projection["observation"]
        native_encoder = ptcg_ai_core.NativeInformationSetEncoder(
            self.game_cards
        )
        actions = self.game.legal_actions(state, 0)
        self.assertGreater(len(actions), 1)
        actual = native_encoder.encode_actions(
            observation_state,
            actions,
        )

        def ref_from_dict(row):
            if not isinstance(row, dict):
                return None
            if row["kind"] == "card":
                return CardRef(
                    row["player"],
                    row["zone"],
                    row["index"],
                    row["card_id"],
                )
            if row["kind"] == "pokemon":
                return PokemonRef(
                    row["player"],
                    row["slot"],
                    row["card_id"],
                )
            if row["kind"] == "slot":
                return SlotRef(row["player"], row["slot"])
            if row["kind"] == "attachment":
                return AttachmentRef(
                    row["player"],
                    row["slot"],
                    row["attachment_type"],
                    row["index"],
                    row["card_id"],
                )
            raise AssertionError(row["kind"])

        players = observation_state["players"]
        board = []
        for player_index, player in enumerate(players):
            for slot_index, pokemon in enumerate(
                [player["active"], *player["bench"]]
            ):
                slot = "active" if slot_index == 0 else (
                    f"bench_{slot_index - 1}"
                )
                if not isinstance(pokemon, dict):
                    board.append(
                        (player_index, slot, "", 0, (), (), "")
                    )
                    continue
                board.append(
                    (
                        player_index,
                        slot,
                        pokemon["card_id"],
                        pokemon["damage_counters"],
                        tuple(pokemon["energy_card_ids"]),
                        tuple(pokemon["status_conditions"]),
                        pokemon["attached_tool_id"],
                    )
                )
        python_observation = Observation(
            perspective=0,
            turn_number=observation_state["turn_number"],
            phase=observation_state["phase"],
            active_player=observation_state["active_player_idx"],
            winner=(
                None
                if observation_state["winner"] == -1
                else observation_state["winner"]
            ),
            own_hand=tuple(players[0]["hand"]),
            own_discard=tuple(players[0]["discard"]),
            own_deck_count=len(players[0]["deck"]),
            own_prize_count=len(players[0]["prizes"]),
            opponent_hand_count=len(players[1]["hand"]),
            opponent_discard=tuple(players[1]["discard"]),
            opponent_deck_count=len(players[1]["deck"]),
            opponent_prize_count=len(players[1]["prizes"]),
            board=tuple(board),
            stadium_id=observation_state["stadium_card_id"],
            public_deck_keys=tuple(
                observation_state["public_deck_keys"]
            ),
            apply_type_matchups=observation_state[
                "apply_type_matchups"
            ],
        )
        python_actions = [
            GameAction(
                kind=row["kind"],
                payload=row["payload"],
                actor=row["actor"],
                source=ref_from_dict(row["source"]),
                target=ref_from_dict(row["target"]),
                base_revision=row["base_revision"],
            )
            for row in actions
        ]
        encoder = InformationSetEncoderV7()
        expected_info = encoder.encode_information_set(
            python_observation,
            "psychic",
        )
        expected_candidates = encoder.encode_actions(
            python_observation,
            python_actions,
        )
        comparisons = {
            "state_global": expected_info.state_global,
            "entity_numeric": expected_info.entity_numeric,
            "entity_card_ids": expected_info.entity_card_ids,
            "entity_type_ids": expected_info.entity_type_ids,
            "candidate_numeric": expected_candidates.numeric,
            "candidate_card_ids": expected_candidates.card_ids,
            "candidate_type_ids": expected_candidates.type_ids,
            "candidate_refs": expected_candidates.refs,
        }
        for field, expected in comparisons.items():
            with self.subTest(field=field):
                self.assertTrue(
                    np.array_equal(actual[field][0], expected),
                    (
                        f"{field}: actual={actual[field][0].tolist()} "
                        f"expected={expected.tolist()}"
                    ),
                )
        self.assertEqual(
            actual["actor_deck_id"].tolist(),
            [int(expected_info.actor_deck_id)],
        )
        self.assertEqual(
            actual["opponent_deck_id"].tolist(),
            [int(expected_info.opponent_deck_id)],
        )

        native_choice_request = {
            "request_id": "encoder-choice",
            "request_type": "select_heal_target",
            "player": 0,
            "min_select": 1,
            "max_select": 1,
            "allow_duplicates": False,
            "can_cancel": True,
            "options": [
                {
                    "option_id": "pokemon:0:active:svd-dodrio",
                    "label": "active",
                    "ref": {
                        "kind": "pokemon",
                        "player": 0,
                        "slot": "active",
                        "card_id": "svd-dodrio",
                    },
                },
                {
                    "option_id": "card:0:hand:1:svi-chim",
                    "label": "hand",
                    "ref": {
                        "kind": "card",
                        "player": 0,
                        "zone": "hand",
                        "index": 1,
                        "card_id": "svi-chim",
                    },
                },
            ],
        }
        native_choice_candidates = self.game.choice_candidates(
            native_choice_request
        )
        actual_choices = native_encoder.encode_choices(
            observation_state,
            native_choice_request,
            native_choice_candidates,
        )
        python_choice_request = ChoiceView(
            request_id="encoder-choice",
            base_revision=0,
            request_type="select_heal_target",
            player=0,
            prompt="",
            options=tuple(
                ChoiceOption(
                    row["option_id"],
                    row["label"],
                    ref_from_dict(row["ref"]),
                )
                for row in native_choice_request["options"]
            ),
            min_select=1,
            max_select=1,
            allow_duplicates=False,
            can_cancel=True,
        )
        search_candidates = _choice_responses(python_choice_request)
        expected_choices = encoder.encode_choices(
            python_observation,
            python_choice_request.request_type,
            [candidate.choice_option for candidate in search_candidates],
        )
        choice_comparisons = {
            "candidate_numeric": expected_choices.numeric,
            "candidate_card_ids": expected_choices.card_ids,
            "candidate_type_ids": expected_choices.type_ids,
            "candidate_refs": expected_choices.refs,
        }
        for field, expected in choice_comparisons.items():
            with self.subTest(choice_field=field):
                self.assertTrue(
                    np.array_equal(actual_choices[field][0], expected),
                    (
                        f"{field}: "
                        f"actual={actual_choices[field][0].tolist()} "
                        f"expected={expected.tolist()}"
                    ),
                )

        prize_native_request = {
            **native_choice_request,
            "request_id": "encoder-prize-energy-target",
            "request_type": "select_prize_energy_target",
        }
        prize_native_candidates = self.game.choice_candidates(
            prize_native_request
        )
        actual_prize_choices = native_encoder.encode_choices(
            observation_state,
            prize_native_request,
            prize_native_candidates,
        )
        prize_python_request = ChoiceView(
            request_id="encoder-prize-energy-target",
            base_revision=0,
            request_type="select_prize_energy_target",
            player=0,
            prompt="",
            options=python_choice_request.options,
            min_select=1,
            max_select=1,
            allow_duplicates=False,
            can_cancel=True,
        )
        prize_search_candidates = _choice_responses(prize_python_request)
        expected_prize_choices = encoder.encode_choices(
            python_observation,
            prize_python_request.request_type,
            [
                candidate.choice_option
                for candidate in prize_search_candidates
            ],
        )
        for field, expected in {
            "candidate_numeric": expected_prize_choices.numeric,
            "candidate_card_ids": expected_prize_choices.card_ids,
            "candidate_type_ids": expected_prize_choices.type_ids,
            "candidate_refs": expected_prize_choices.refs,
        }.items():
            with self.subTest(prize_choice_field=field):
                self.assertTrue(
                    np.array_equal(
                        actual_prize_choices[field][0],
                        expected,
                    )
                )

    def test_native_attack_formula_post_damage_choice_and_aura_reduction(
        self,
    ):
        def battle_state(active_card_id, energy_ids):
            state = copy.deepcopy(
                next(iter(self.rules_fixture["cases"].values()))[
                    "initial_state"
                ]
            )
            state["phase"] = "MAIN"
            state["turn_number"] = 3
            state["first_player_idx"] = 1
            state["active_player_idx"] = 0
            owner = state["players"][0]
            active = copy.deepcopy(owner["active"])
            active.update({
                "card_id": active_card_id,
                "damage_counters": 0,
                "energy_card_ids": list(energy_ids),
                "evolution_stack_ids": [],
                "attached_tool_id": "",
                "status_conditions": [],
                "modifiers": [],
            })
            owner["active"] = active
            state["players"][1]["active"]["damage_counters"] = 0
            state["players"][1]["active"]["modifiers"] = []
            return state

        formula_state = battle_state(
            "svm-zacian",
            ("sv1-ener-8",),
        )
        formula_state["players"][0]["bench"] = [
            copy.deepcopy(formula_state["players"][0]["active"]),
            copy.deepcopy(formula_state["players"][0]["active"]),
            None,
            None,
            None,
        ]
        formula_action = next(
            row
            for row in self.game.legal_actions(formula_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        formula_result = self.game.apply_action(
            formula_state,
            formula_action,
            0x0A11CE01,
        )
        self.assertTrue(formula_result["success"], formula_result)
        self.assertEqual(
            formula_result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            4,
        )

        choice_state = battle_state(
            "svm-cobalion",
            ("sv1-ener-8", "sv1-ener-8"),
        )
        owner = choice_state["players"][0]
        first_target = copy.deepcopy(owner["active"])
        first_target["card_id"] = "svm-zacian"
        first_target["energy_card_ids"] = []
        second_target = copy.deepcopy(owner["active"])
        second_target["card_id"] = "svm-zamazenta"
        second_target["energy_card_ids"] = []
        owner["bench"] = [
            first_target,
            second_target,
            None,
            None,
            None,
        ]
        owner["deck"] = ["sv1-ener-8", "sv1-ener-8"]
        before_damage = choice_state["players"][1]["active"][
            "damage_counters"
        ]
        choice_action = next(
            row
            for row in self.game.legal_actions(choice_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        choice_result = self.game.apply_action(
            choice_state,
            choice_action,
            0x0A11CE02,
        )
        self.assertTrue(choice_result["success"], choice_result)
        self.assertEqual(
            choice_result["pending"]["request_type"],
            "distribute_energy",
        )
        self.assertEqual(choice_result["pending"]["min_select"], 0)
        self.assertEqual(choice_result["pending"]["max_select"], 2)
        self.assertEqual(len(choice_result["pending"]["options"]), 4)
        self.assertEqual(
            choice_result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            before_damage + 3,
        )

        aura_state = battle_state(
            "svg2-shro",
            ("sv1-ener-1",),
        )
        aura_state["players"][0]["active"]["damage_counters"] = 2
        aura_state["players"][1]["active"]["card_id"] = "svi-ente"
        aura_state["players"][1]["active"]["damage_counters"] = 0
        aura_action = next(
            row
            for row in self.game.legal_actions(aura_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        aura_result = self.game.apply_action(
            aura_state,
            aura_action,
            0x0A11CE03,
        )
        self.assertTrue(aura_result["success"], aura_result)
        self.assertEqual(
            aura_result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            0,
        )
        self.assertEqual(
            aura_result["state"]["players"][0]["active"][
                "damage_counters"
            ],
            1,
        )

    def test_native_zacian_formula_preserves_attack_flags(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        attacker = state["players"][0]["active"]
        attacker.update(
            card_id="svm-zacian",
            damage_counters=0,
            energy_card_ids=["sv1-ener-8"],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        bench_copy = copy.deepcopy(attacker)
        bench_copy["energy_card_ids"] = []
        state["players"][0]["bench"] = [
            copy.deepcopy(bench_copy),
            copy.deepcopy(bench_copy),
            None,
            None,
            None,
        ]
        defender = state["players"][1]["active"]
        defender.update(
            card_id="sv1-114",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[{
                "hook": "MODIFY_DAMAGE",
                "operation": {"kind": "prevent_damage"},
            }],
        )

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x5A414349)

        self.assertTrue(result["success"], result)
        # Battle Legion is 20 + 2 * 10. Dedenne's Metal Weakness and its
        # temporary damage-prevention effect must both be ignored.
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            4,
        )

    def test_native_cobalion_aura_stacks_and_orthworm_hp_is_dynamic(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        attacker = state["players"][0]["active"]
        attacker.update(
            card_id="svm-zacian",
            damage_counters=0,
            energy_card_ids=["sv1-ener-8"],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        cobalion = copy.deepcopy(attacker)
        cobalion.update(card_id="svm-cobalion", energy_card_ids=[])
        state["players"][0]["bench"] = [
            copy.deepcopy(cobalion),
            copy.deepcopy(cobalion),
            None,
            None,
            None,
        ]
        state["players"][1]["active"].update(
            card_id="svd-mabosstiff-ex",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        result = self.game.apply_action(state, action, 0x434F4241)
        self.assertTrue(result["success"], result)
        # 20 + two Benched Pokémon * 10 + two Justified Law * 30.
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            10,
        )

        orthworm = copy.deepcopy(attacker)
        orthworm.update(
            card_id="svm-orthworm",
            damage_counters=5,
            energy_card_ids=[
                "sv1-ener-8",
                "sv1-ener-8",
                "sv1-ener-8",
            ],
            modifiers=[],
        )
        self.assertEqual(self.game.pokemon_max_hp(orthworm), 230)
        self.assertEqual(self.game.pokemon_current_hp(orthworm), 180)
        orthworm["energy_card_ids"].pop()
        self.assertEqual(self.game.pokemon_max_hp(orthworm), 130)
        self.assertEqual(self.game.pokemon_current_hp(orthworm), 80)

    def test_native_heal_bonus_and_previous_turn_ko_use_correct_owner(self):
        def state_for(card_id, energy_ids):
            state = copy.deepcopy(
                next(iter(self.rules_fixture["cases"].values()))[
                    "initial_state"
                ]
            )
            state.update(
                phase="MAIN",
                turn_number=3,
                first_player_idx=1,
                active_player_idx=0,
            )
            state["players"][0]["active"].update(
                card_id=card_id,
                damage_counters=0,
                energy_card_ids=list(energy_ids),
                evolution_stack_ids=[],
                attached_tool_id="",
                status_conditions=[],
                modifiers=[],
                healed_this_turn=False,
            )
            state["players"][1]["active"].update(
                card_id="sv2-grex",
                damage_counters=0,
                energy_card_ids=[],
                evolution_stack_ids=[],
                attached_tool_id="",
                status_conditions=[],
                modifiers=[],
                healed_this_turn=False,
            )
            return state

        miltank = state_for(
            "svg-milt",
            ["sv1-ener-1", "sv1-ener-1", "sv1-ener-1"],
        )
        miltank["players"][0]["active"]["healed_this_turn"] = True
        miltank_attack = next(
            row
            for row in self.game.legal_actions(miltank, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        boosted = self.game.apply_action(miltank, miltank_attack, 0x4845414C)
        self.assertTrue(boosted["success"], boosted)
        self.assertEqual(
            boosted["state"]["players"][1]["active"]["damage_counters"],
            15,
        )

        wrong_owner = state_for(
            "svg-milt",
            ["sv1-ener-1", "sv1-ener-1", "sv1-ener-1"],
        )
        wrong_owner["players"][1]["active"]["healed_this_turn"] = True
        normal = self.game.apply_action(
            wrong_owner,
            next(
                row
                for row in self.game.legal_actions(wrong_owner, 0)
                if row["kind"] == "DECLARE_ATTACK"
            ),
            0x4F574E52,
        )
        self.assertEqual(
            normal["state"]["players"][1]["active"]["damage_counters"],
            6,
        )

        zamazenta = state_for(
            "svm-zamazenta",
            ["sv1-ener-8", "sv1-ener-8", "sv1-ener-8"],
        )
        zamazenta["turn_fact_book"]["previous_turn"]["knockouts"] = [{
            "card_id": "svd-doduo",
            "cause_kind": "damage_counters",
            "defeated_player": 0,
            "slot": "bench_0",
            "source_kind": "damage_counters",
            "source_player": 1,
            "turn": 2,
        }]
        zamazenta["players"][0]["was_ko_by_attack"] = False
        revenge = self.game.apply_action(
            zamazenta,
            next(
                row
                for row in self.game.legal_actions(zamazenta, 0)
                if row["kind"] == "DECLARE_ATTACK"
            ),
            0x4B4F4641,
        )
        self.assertTrue(revenge["success"], revenge)
        self.assertEqual(
            revenge["state"]["players"][1]["active"]["damage_counters"],
            22,
        )

        checkup_ko = state_for(
            "svm-zamazenta",
            ["sv1-ener-8", "sv1-ener-8", "sv1-ener-8"],
        )
        checkup_ko["turn_fact_book"]["previous_turn"]["knockouts"] = [{
            "card_id": "svd-doduo",
            "cause_kind": "special_condition",
            "defeated_player": 0,
            "slot": "active",
            "source_kind": "special_condition",
            "source_player": -1,
            "turn": 2,
        }]
        no_revenge = self.game.apply_action(
            checkup_ko,
            next(
                row
                for row in self.game.legal_actions(checkup_ko, 0)
                if row["kind"] == "DECLARE_ATTACK"
            ),
            0x43484B55,
        )
        self.assertTrue(no_revenge["success"], no_revenge)
        self.assertEqual(
            no_revenge["state"]["players"][1]["active"]["damage_counters"],
            10,
        )

    def test_native_entei_pressure_applies_before_weakness_and_to_bench(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
            apply_type_matchups=True,
        )
        state["rules_options"] = {"apply_type_matchups": True}
        state["players"][0]["active"].update(
            card_id="sv2-39",
            damage_counters=0,
            energy_card_ids=["sv1-ener-3", "sv1-ener-3"],
            evolution_stack_ids=["sv2-38"],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        state["players"][0]["bench"] = [None] * 5
        state["players"][1]["active"].update(
            card_id="svi-ente",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        result = self.game.apply_action(
            state,
            next(
                row
                for row in self.game.legal_actions(state, 0)
                if row["kind"] == "DECLARE_ATTACK"
            ),
            0x50524553,
        )
        self.assertTrue(result["success"], result)
        # Pressure is applied before Entei's Water Weakness: (40 - 20) * 2.
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            4,
        )

        bench_state = copy.deepcopy(state)
        bench_state["apply_type_matchups"] = False
        bench_state["rules_options"] = {"apply_type_matchups": False}
        bench_state["players"][0]["active"].update(
            card_id="svm-orthworm",
            energy_card_ids=["sv1-ener-8"] * 4,
            evolution_stack_ids=[],
        )
        bench_target = copy.deepcopy(bench_state["players"][1]["active"])
        bench_target.update(card_id="sv2-grex", damage_counters=0)
        bench_state["players"][1]["bench"] = [
            bench_target,
            None,
            None,
            None,
            None,
        ]
        bench_result = self.game.apply_action(
            bench_state,
            next(
                row
                for row in self.game.legal_actions(bench_state, 0)
                if row["kind"] == "DECLARE_ATTACK"
            ),
            0x42454E50,
        )
        self.assertTrue(bench_result["success"], bench_result)
        self.assertEqual(
            bench_result["state"]["players"][1]["active"][
                "damage_counters"
            ],
            8,
        )
        self.assertEqual(
            bench_result["state"]["players"][1]["bench"][0][
                "damage_counters"
            ],
            1,
        )

    def test_native_recoil_damage_and_ability_counters_keep_distinct_events(
        self,
    ):
        def state_for(card_id, energy_ids):
            state = copy.deepcopy(
                next(iter(self.rules_fixture["cases"].values()))[
                    "initial_state"
                ]
            )
            state.update(
                phase="MAIN",
                turn_number=3,
                first_player_idx=1,
                active_player_idx=0,
            )
            state["players"][0]["active"].update(
                card_id=card_id,
                damage_counters=0,
                energy_card_ids=list(energy_ids),
                evolution_stack_ids=[],
                attached_tool_id="",
                status_conditions=[],
                modifiers=[],
                used_abilities=[],
            )
            state["players"][1]["active"].update(
                card_id="svd-mabosstiff-ex",
                damage_counters=0,
                energy_card_ids=[],
                evolution_stack_ids=[],
                attached_tool_id="",
                status_conditions=[],
                modifiers=[],
            )
            return state

        recoil_state = state_for("svd-doduo", ["sv1-ener-7"])
        attack = next(
            row
            for row in self.game.legal_actions(recoil_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        recoil = self.game.apply_action(recoil_state, attack, 0x5245434F)
        self.assertTrue(recoil["success"], recoil)
        damage_events = [
            event
            for event in recoil["events"]
            if event["event_type"] == "damage_dealt"
        ]
        self.assertEqual(
            [
                (
                    event["data"]["target_player"],
                    event["data"]["amount"],
                    event["data"]["damage_kind"],
                )
                for event in damage_events
            ],
            [(1, 30, "attack_damage"), (0, 10, "damage")],
        )

        ability_state = state_for("svd-dodrio", [])
        ability_state["players"][0]["deck"] = ["sv1-ener-1"]
        ability = next(
            row
            for row in self.game.legal_actions(ability_state, 0)
            if row["kind"] == "USE_ABILITY"
        )
        ability_result = self.game.apply_action(
            ability_state,
            ability,
            0x434F554E,
        )
        self.assertTrue(ability_result["success"], ability_result)
        counter_event = next(
            event
            for event in ability_result["events"]
            if event["event_type"] == "damage_counters_placed"
        )
        self.assertEqual(counter_event["data"]["target_player"], 0)
        self.assertEqual(counter_event["data"]["counter_count"], 1)
        self.assertEqual(counter_event["data"]["damage_kind"], "damage_counters")

    def test_native_coin_branch_post_damage_order_is_ptcg_order(self):
        def state_for(card_id, energy_ids):
            state = copy.deepcopy(
                next(iter(self.rules_fixture["cases"].values()))[
                    "initial_state"
                ]
            )
            state.update(
                phase="MAIN",
                turn_number=3,
                first_player_idx=1,
                active_player_idx=0,
            )
            state["players"][0]["active"].update(
                card_id=card_id,
                damage_counters=0,
                energy_card_ids=list(energy_ids),
                evolution_stack_ids=[],
                attached_tool_id="",
                status_conditions=[],
                modifiers=[],
            )
            state["players"][1]["active"].update(
                card_id="svd-mabosstiff-ex",
                damage_counters=0,
                energy_card_ids=[],
                evolution_stack_ids=[],
                attached_tool_id="",
                status_conditions=[],
                modifiers=[],
            )
            return state

        pikachu_state = state_for(
            "svl-pikaex",
            ["sv1-ener-4", "sv1-ener-4", "svi-dtur"],
        )
        pikachu_attack = next(
            row
            for row in self.game.legal_actions(pikachu_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        flipped = self.game.apply_action(pikachu_state, pikachu_attack, 1)
        self.assertTrue(flipped["success"], flipped)
        resolved = self.game.resume_choice(
            flipped["state"],
            flipped["continuation"],
            [],
            False,
            flipped["rng_state"],
        )
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(
            resolved["state"]["players"][1]["active"]["damage_counters"],
            20,
        )
        self.assertEqual(
            resolved["state"]["players"][0]["active"]["energy_card_ids"],
            [],
        )
        self.assertLess(
            resolved["event_types"].index("damage_dealt"),
            resolved["event_types"].index("cards_discarded"),
        )

        status_state = state_for("svl-emol", ["sv1-ener-4"])
        status_attack = next(
            row
            for row in self.game.legal_actions(status_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        status_flip = self.game.apply_action(status_state, status_attack, 2)
        status_result = self.game.resume_choice(
            status_flip["state"],
            status_flip["continuation"],
            [],
            False,
            status_flip["rng_state"],
        )
        self.assertTrue(status_result["success"], status_result)
        self.assertLess(
            status_result["event_types"].index("damage_dealt"),
            status_result["event_types"].index("status_applied"),
        )
        self.assertIn(
            "PARALYZED",
            status_result["state"]["players"][1]["active"][
                "status_conditions"
            ],
        )

    def test_native_active_only_modifiers_do_not_leak_to_bench_damage(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        attacker = state["players"][0]["active"]
        attacker.update(
            card_id="svm-orthworm",
            damage_counters=0,
            energy_card_ids=["sv1-ener-8"] * 4,
            evolution_stack_ids=[],
            attached_tool_id="svl-vitb",
            status_conditions=[],
            modifiers=[{
                "condition": {"target_active": True},
                "hook": "MODIFY_DAMAGE",
                "layer": "attacker_adjust",
                "scope": "attached_attacker",
                "operation": {"kind": "damage_delta", "amount": 10},
            }],
        )
        state["players"][1]["active"].update(
            card_id="sv2-grex",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        bench_target = copy.deepcopy(state["players"][1]["active"])
        bench_target.update(card_id="svi-ente", modifiers=[])
        state["players"][1]["bench"] = [
            bench_target,
            copy.deepcopy(state["players"][1]["active"]),
            None,
            None,
            None,
        ]
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        targeted = self.game.apply_action(state, action, 0x42454E43)
        self.assertTrue(targeted["success"], targeted)
        selected = next(
            option
            for option in targeted["pending"]["options"]
            if option.get("slot") == "bench_0"
        )
        result = self.game.resume_choice(
            targeted["state"],
            targeted["continuation"],
            [selected],
            False,
            targeted["rng_state"],
        )
        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][1]["active"]["damage_counters"],
            11,
        )
        # Vitality Band only boosts damage to the Active Pokémon, and Entei's
        # Pressure only works while Entei itself is Active.
        self.assertEqual(
            result["state"]["players"][1]["bench"][0]["damage_counters"],
            3,
        )

    def test_native_poppy_moves_selected_energy_to_one_other_pokemon(self):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        owner = state["players"][0]
        owner["active"]["energy_card_ids"] = [
            "sv1-ener-1",
            "sv1-ener-2",
        ]
        first = copy.deepcopy(owner["active"])
        first["energy_card_ids"] = []
        second = copy.deepcopy(owner["active"])
        second["energy_card_ids"] = []
        owner["bench"] = [first, second, None, None, None]
        owner["hand"] = ["svi-popp"]

        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "PLAY_TRAINER"
        )
        attachments = self.game.apply_action(state, action, 0x504F5050)
        self.assertTrue(attachments["success"], attachments)
        self.assertEqual(
            attachments["pending"]["request_type"],
            "select_attachment",
        )
        target = self.game.resume_choice(
            attachments["state"],
            attachments["continuation"],
            attachments["pending"]["options"][:2],
            False,
            attachments["rng_state"],
        )
        self.assertTrue(target["success"], target)
        self.assertEqual(target["pending"]["request_type"], "select_energy_target")
        self.assertEqual(target["pending"]["min_select"], 1)
        self.assertEqual(target["pending"]["max_select"], 1)
        bench_one = next(
            option
            for option in target["pending"]["options"]
            if option.get("slot") == "bench_1"
        )
        resolved = self.game.resume_choice(
            target["state"],
            target["continuation"],
            [bench_one],
            False,
            target["rng_state"],
        )
        self.assertTrue(resolved["success"], resolved)
        self.assertEqual(
            resolved["state"]["players"][0]["active"]["energy_card_ids"],
            [],
        )
        self.assertEqual(
            resolved["state"]["players"][0]["bench"][0]["energy_card_ids"],
            [],
        )
        self.assertCountEqual(
            resolved["state"]["players"][0]["bench"][1]["energy_card_ids"],
            ["sv1-ener-1", "sv1-ener-2"],
        )

    def test_native_youngster_draw_event_reports_five_cards(self):
        case = self.rules_fixture["cases"]["shuffle_draw_supporter"]
        result = self.game.apply_action(
            copy.deepcopy(case["initial_state"]),
            copy.deepcopy(case["actions"][0]),
            case["portable_seed"],
        )
        self.assertTrue(result["success"], result)
        drawn = next(
            event
            for event in result["events"]
            if event["event_type"] == "cards_drawn"
        )
        self.assertEqual(drawn["data"]["count"], 5)
        self.assertEqual(len(drawn["data"]["card_ids"]), 5)
        self.assertEqual(len(result["state"]["players"][0]["hand"]), 5)

    def test_native_named_attack_lock_survives_switch_but_instance_lock_does_not(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state.update(
            phase="MAIN",
            turn_number=3,
            first_player_idx=1,
            active_player_idx=0,
        )
        terrakion = state["players"][0]["active"]
        terrakion.update(
            card_id="svf-terr",
            damage_counters=0,
            energy_card_ids=["sv1-ener-6"] * 3,
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        state["players"][1]["active"].update(
            card_id="svd-mabosstiff-ex",
            damage_counters=0,
            energy_card_ids=[],
            evolution_stack_ids=[],
            attached_tool_id="",
            status_conditions=[],
            modifiers=[],
        )
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
        )
        result = self.game.apply_action(state, action, 0x7E22A510)
        self.assertTrue(result["success"], result)
        self.assertEqual(
            result["state"]["players"][0]["attack_locked_names"],
            {"岩窟冲撞": 5},
        )

        # A switch, evolution, or copied attack must not evade Cavern Tackle's
        # player-level "one of your Pokémon used this attack" restriction.
        next_own_turn = copy.deepcopy(result["state"])
        next_own_turn.update(
            phase="MAIN",
            turn_number=5,
            active_player_idx=0,
        )
        replacement = copy.deepcopy(terrakion)
        replacement["modifiers"] = []
        next_own_turn["players"][0]["active"] = replacement
        self.assertFalse(
            any(
                row["kind"] == "DECLARE_ATTACK"
                for row in self.game.legal_actions(next_own_turn, 0)
            )
        )

        # Darkrai's Blade lock is explicitly attached to "this Pokémon" and
        # therefore remains an instance modifier, not a player-wide marker.
        darkrai_state = copy.deepcopy(state)
        darkrai = darkrai_state["players"][0]["active"]
        darkrai.update(
            card_id="svd-darkrai",
            energy_card_ids=["sv1-ener-7"] * 3,
            modifiers=[],
        )
        darkrai_action = next(
            row
            for row in self.game.legal_actions(darkrai_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        darkrai_result = self.game.apply_action(
            darkrai_state,
            darkrai_action,
            0xDA4B1A1,
        )
        self.assertTrue(darkrai_result["success"], darkrai_result)
        self.assertNotIn(
            "attack_locked_names",
            darkrai_result["state"]["players"][0],
        )
        active_modifiers = darkrai_result["state"]["players"][0]["active"][
            "modifiers"
        ]
        self.assertTrue(
            any(
                modifier.get("operation", {}).get("kind") == "attack_lock"
                for modifier in active_modifiers
            )
        )

        skarmory_state = copy.deepcopy(state)
        skarmory = skarmory_state["players"][0]["active"]
        skarmory.update(
            card_id="svm-skarmory",
            energy_card_ids=["sv1-ener-8"] * 3,
            modifiers=[],
        )
        skarmory_action = next(
            row
            for row in self.game.legal_actions(skarmory_state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 1
        )
        skarmory_result = self.game.apply_action(
            skarmory_state,
            skarmory_action,
            0x5CA4A0F1,
        )
        self.assertTrue(skarmory_result["success"], skarmory_result)
        self.assertNotIn(
            "attack_locked_names",
            skarmory_result["state"]["players"][0],
        )
        named_lock = next(
            modifier
            for modifier in skarmory_result["state"]["players"][0][
                "active"
            ]["modifiers"]
            if modifier.get("operation", {}).get("kind") == "attack_lock"
        )
        self.assertEqual(
            named_lock["operation"]["attack_name"],
            "钢铁之刃",
        )

    def test_native_timed_outgoing_reduction_replaces_and_expires(
        self,
    ):
        state = copy.deepcopy(
            next(iter(self.rules_fixture["cases"].values()))[
                "initial_state"
            ]
        )
        state["phase"] = "MAIN"
        state["turn_number"] = 3
        state["first_player_idx"] = 1
        state["active_player_idx"] = 0
        attacker = state["players"][0]["active"]
        attacker.update({
            "card_id": "svd-mabosstiff-ex",
            "energy_card_ids": ["sv1-ener-7", "sv1-ener-7"],
            "evolution_stack_ids": [],
            "attached_tool_id": "",
            "modifiers": [],
        })
        defender = state["players"][1]["active"]
        defender.update({
            "card_id": "sv1-114",
            "damage_counters": 0,
            "energy_card_ids": [],
            "evolution_stack_ids": [],
            "attached_tool_id": "sv1-201",
            "modifiers": [{
                "hook": "MODIFY_DAMAGE",
                "layer": "attacker_adjust",
                "priority": 0,
                "controller": 1,
                "source_ref": {
                    "kind": "pokemon",
                    "player": 1,
                    "slot": "active",
                    "card_id": "sv1-114",
                },
                "scope": "attached_attacker",
                "duration": "until_leave_play",
                "stacking": "replace_same_source",
                "conflict_policy": "commutative",
                "condition": {"behind_on_prizes": True},
                "operation": {
                    "kind": "damage_delta",
                    "amount": 30,
                },
            }],
        })
        action = next(
            row
            for row in self.game.legal_actions(state, 0)
            if row["kind"] == "DECLARE_ATTACK"
            and row["payload"]["attack_index"] == 0
        )
        attacked = self.game.apply_action(state, action, 0x0A11CE04)

        self.assertTrue(attacked["success"], attacked)
        target = attacked["state"]["players"][1]["active"]
        self.assertEqual(target["damage_counters"], 3)
        self.assertEqual(len(target["modifiers"]), 1)
        self.assertEqual(
            target["modifiers"][0]["operation"],
            {"amount": -50, "kind": "damage_delta"},
        )
        self.assertEqual(target["outgoing_damage_reduction"], 50)

        end_turn = next(
            row
            for row in self.game.legal_actions(attacked["state"], 1)
            if row["kind"] == "END_TURN"
        )
        expired = self.game.apply_action(
            attacked["state"],
            end_turn,
            attacked["rng_state"],
        )
        self.assertTrue(expired["success"], expired)
        self.assertEqual(
            expired["state"]["players"][1]["active"].get(
                "modifiers",
                [],
            ),
            [],
        )
        self.assertEqual(
            expired["state"]["players"][1]["active"][
                "outgoing_damage_reduction"
            ],
            0,
        )

    def test_native_technical_gate_is_complete(self):
        self.assertEqual(ptcg_ai_core.abi_version(), 2)
        self.assertEqual(self.rules.implemented_op_count, 80)
        self.assertTrue(ptcg_ai_core.production_ready())
        self.assertEqual(ptcg_ai_core.production_blockers(), [])


if __name__ == "__main__":
    unittest.main()

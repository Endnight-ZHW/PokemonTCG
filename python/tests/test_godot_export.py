import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from data.deck_definitions import ALL_CARD_IDS
from scripts.export_godot_data import export
from scripts.godot_export.resources import (
    exported_image_errors,
    image_hashes,
    load_image_mapping,
)
from engine.commands.descriptors import descriptor_export_payload
from engine.commands.vm_contract import VM_IR_VERSION


class GodotDataExportTests(unittest.TestCase):
    def test_canonical_card_images_cover_release_ids(self):
        repo_root = Path(__file__).resolve().parents[2]
        mapping = load_image_mapping(repo_root, ALL_CARD_IDS)
        self.assertEqual(len(mapping), 137)
        self.assertEqual(mapping["svi-chim"], "svi-chim.webp")
        self.assertEqual(len(image_hashes(repo_root, mapping)), 137)
        self.assertEqual(exported_image_errors(repo_root / "godot", mapping), [])

    def test_export_is_complete_and_deterministic(self):
        with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
            first = Path(first_dir)
            second = Path(second_dir)
            first_contract = export(first, copy_images=False)
            second_contract = export(second, copy_images=False)

            self.assertEqual(first_contract, second_contract)
            self.assertEqual(first_contract["counts"]["cards"], 137)
            self.assertEqual(first_contract["counts"]["decks"], 10)
            self.assertEqual(len(first_contract["effect_types"]), 77)
            self.assertEqual(len(first_contract["effect_examples"]), 77)
            self.assertEqual(len(first_contract["compiled_effect_examples"]), 77)
            self.assertTrue(all(size == 60 for size in first_contract["deck_sizes"].values()))
            first_descriptors = json.loads(
                (first / "data" / "vm_command_descriptors.json").read_text(
                    encoding="utf-8"
                )
            )
            second_descriptors = json.loads(
                (second / "data" / "vm_command_descriptors.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(first_descriptors, second_descriptors)
            self.assertEqual(
                first_descriptors,
                descriptor_export_payload(VM_IR_VERSION),
            )
            self.assertEqual(len(first_descriptors["descriptors"]), 80)
            self.assertEqual(len(first_descriptors["descriptor_digest"]), 64)
            rules = json.loads(
                (first / "tests" / "fixtures" / "rules_golden.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(rules["fixture_version"], 3)
            self.assertEqual(rules["rng_algorithm"], "xorshift32-v1")
            self.assertEqual(
                rules["event_contract"]["name"],
                "canonical-state-transition-events-v1",
            )
            self.assertEqual(
                rules["pending_contract"]["name"],
                "canonical-pending-semantics-v1",
            )
            self.assertEqual(len(rules["cases"]), 23)
            self.assertTrue(
                all("expected_rng_state" in row for row in rules["cases"].values())
            )
            self.assertTrue(
                all(row.get("trace") for row in rules["cases"].values())
            )
            self.assertTrue(
                rules["cases"]["pending_attack_choice_cancel"]["choice_response"]["cancelled"]
            )
            coverage = json.loads(
                (first / "tests" / "fixtures" / "rules_coverage.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(coverage["coverage_version"], 3)
            descriptor_contract = coverage["vm_descriptor_contract"]
            self.assertEqual(
                descriptor_contract["descriptor_digest"],
                first_descriptors["descriptor_digest"],
            )
            self.assertEqual(
                descriptor_contract["descriptor_ops"],
                descriptor_contract["handler_ops"],
            )
            self.assertEqual(
                descriptor_contract["descriptor_ops"],
                descriptor_contract["preflight_ops"],
            )
            self.assertEqual(
                descriptor_contract["descriptor_ops"],
                descriptor_contract["golden_ops"],
            )
            self.assertEqual(
                descriptor_contract["descriptor_ops"],
                descriptor_contract["executed_ops"],
            )
            self.assertEqual(
                coverage["counts"],
                {
                    "release_effect_types": 77,
                    "registered_effect_types": 78,
                    "mapped_registered_effect_types": 78,
                    "registered_vm_ops": 80,
                    "mapped_registered_vm_ops": 80,
                    "public_player_actions": 9,
                    "traced_public_player_actions": 9,
                    "semantic_release_effect_types": 16,
                    "semantic_registered_vm_ops": 80,
                },
            )
            semantic_inventory = coverage["semantic_trace_inventory"]
            self.assertEqual(semantic_inventory["case_count"], 23)
            self.assertEqual(semantic_inventory["transaction_step_count"], 32)
            self.assertEqual(semantic_inventory["native_vm_case_count"], 80)
            self.assertEqual(
                semantic_inventory["native_vm_fixture"],
                "vm_native_golden.json",
            )
            self.assertEqual(
                len(semantic_inventory["release_effect_types_not_executed"]),
                61,
            )
            self.assertEqual(
                len(semantic_inventory["registered_vm_ops_not_executed"]),
                0,
            )
            self.assertEqual(
                len(semantic_inventory["registered_vm_ops_executed"]),
                80,
            )
            self.assertEqual(
                semantic_inventory["registered_vm_ops_executed"],
                sorted(semantic_inventory["registered_vm_ops_executed"]),
            )
            semantic_gaps = semantic_inventory[
                "known_cross_runtime_semantic_gaps"
            ]
            self.assertEqual(len(semantic_gaps), 1)
            self.assertEqual(
                (semantic_gaps[0]["op"], semantic_gaps[0]["field"]),
                ("attach_energy_from_discard", "pending"),
            )
            self.assertEqual(
                semantic_inventory["release_effect_types_executed"],
                [
                    "attack_damage_formula",
                    "conditional_damage_heal",
                    "conditional_status",
                    "damage_and_self_heal",
                    "damage_counter_self",
                    "draw",
                    "energy_attach",
                    "energy_discard",
                    "heal",
                    "heal_all",
                    "potion_heal",
                    "prevent_damage",
                    "prevent_effects",
                    "search",
                    "self_attack_lock",
                    "shuffle_draw",
                ],
            )
            self.assertEqual(
                set(coverage["mapping_inventory"]["action_to_trace_cases"]),
                {
                    "PLAY_BASIC",
                    "EVOLVE",
                    "ATTACH_ENERGY",
                    "PLAY_TRAINER",
                    "USE_ABILITY",
                    "USE_STADIUM",
                    "RETREAT",
                    "DECLARE_ATTACK",
                    "END_TURN",
                },
            )
            self.assertEqual(
                coverage["semantic_trace_inventory"]["explicitly_not_claimed"],
                ["all_release_effect_semantics"],
            )
            native_vm = json.loads(
                (first / "tests" / "fixtures" / "vm_native_golden.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(native_vm["fixture_version"], 2)
            self.assertEqual(
                native_vm["contract"]["name"],
                "native-vm-semantic-parity-v2",
            )
            self.assertEqual(
                native_vm["counts"],
                {
                    "registered_ops": 80,
                    "executed_ops": 80,
                    "successful_ops": 80,
                    "pending_ops": 28,
                    "continued_ops": 27,
                    "choice_rounds": 33,
                },
            )
            self.assertEqual(len(native_vm["cases"]), 80)
            self.assertEqual(native_vm["registered_ops"], native_vm["executed_ops"])
            self.assertEqual(
                native_vm["executed_ops"],
                semantic_inventory["registered_vm_ops_executed"],
            )
            self.assertEqual(
                native_vm["known_cross_runtime_semantic_gaps"],
                semantic_gaps,
            )
            for op, vm_case in native_vm["cases"].items():
                self.assertEqual(vm_case["command_spec"]["op"], op)
                self.assertEqual(vm_case["descriptor"]["op"], op)
                self.assertTrue(vm_case["expected"]["success"])
            potion_case = rules["cases"]["potion_heal_choice"]
            self.assertEqual(
                potion_case["trace"][0]["expected"]["players"][0]["discard"],
                ["svf-potion"],
            )
            self.assertEqual(
                potion_case["pending_after_action"]["request"]["request_type"],
                "select_heal_target",
            )
            self.assertEqual(
                rules["cases"]["search_energy_attack"]["pending_after_action"]
                ["request"]["request_type"],
                "search_move",
            )

            first_cards = json.loads((first / "data" / "cards.json").read_text(encoding="utf-8"))
            second_cards = json.loads((second / "data" / "cards.json").read_text(encoding="utf-8"))
            self.assertEqual(first_cards, second_cards)
            self.assertEqual(len(first_cards), 137)
            self.assertNotIn("ai_card_index", first_cards["svi-chim"])
            self.assertNotIn("ai_semantic_features", first_cards["svi-chim"])
            self.assertIn("compiled_effects", first_cards["svi-chim"]["attacks"][0])
            compiled_dump = json.dumps(first_cards, sort_keys=True)
            legacy_formula_ops = (
                "deal_damage_per_hand_size",
                "deal_damage_per_self_damage",
                "deal_damage_plus_bench",
                "deal_damage_with_self_penalty",
                "set_attack_damage_formula",
            )
            for op in legacy_formula_ops:
                self.assertNotIn(f'"op": "{op}"', compiled_dump)
            self.assertEqual(first_cards["sv2-tatsu"]["attacks"][1]["damage"], 30)
            self.assertEqual(first_cards["sv2-tatsu"]["attacks"][1]["damage_text"], "30")
            self.assertEqual(first_cards["svi-sqwk"]["attacks"][1]["damage_text"], "60")
            self.assertEqual(first_cards["sv1-107"]["attacks"][0]["damage_text"], "10×")
            self.assertEqual(first_cards["svi-gree"]["attacks"][1]["damage_text"], "60+")
            self.assertEqual(first_cards["svg-ceti"]["attacks"][1]["damage_text"], "200-")
            self.assertEqual(first_cards["sv2-tatsu"]["attacks"][0]["damage_text"], "")
            self.assertEqual(first_cards["svg2-empo"]["attacks"][0]["damage_text"], "")
            self.assertEqual(
                first_cards["svi-chim"]["image_path"],
                "res://assets/cards/svi-chim.webp",
            )

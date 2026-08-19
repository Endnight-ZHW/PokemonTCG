import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.export_godot_data import (
    _export_images,
    _exported_image_errors,
    _godot_mulligan_bonus_max,
    _godot_pokemon_payload,
    _godot_turn_fact_book_payload,
    _image_hashes,
    _parse_image_mapping,
    _state_payload,
    _validate_image_mapping,
    export,
)
from engine.actions import ChoiceOption
from engine.ai.dl.encoder import ActionStateEncoder, card_index
from engine.ai.observation import Observation
from engine.game_state import GameState
from engine.commands.descriptors import descriptor_export_payload
from engine.commands.vm_contract import VM_IR_VERSION


class GodotDataExportTests(unittest.TestCase):
    def test_choice_encoder_uses_only_choice_view_v2_public_identity(self):
        observation = Observation(
            perspective=1,
            turn_number=1,
            phase="MAIN",
            active_player=1,
            winner=None,
            own_hand=(),
            own_discard=(),
            own_deck_count=0,
            own_prize_count=0,
            opponent_hand_count=0,
            opponent_discard=(),
            opponent_deck_count=0,
            opponent_prize_count=0,
            board=(),
            stadium_id="",
            public_deck_keys=(None, None),
            apply_type_matchups=False,
        )
        encoder = ActionStateEncoder()
        known_card = object()

        def lookup(card_id):
            return known_card if card_id == "sv2-cand" else None

        with mock.patch(
            "engine.ai.dl.encoder.CardRegistry.get",
            side_effect=lookup,
        ):
            private_value = encoder.encode_choice_option(
                observation,
                "select_card",
                ChoiceOption(
                    "opaque-option",
                    "private value must stay private",
                    value={"card_id": "sv2-cand"},
                ),
            )
            malformed_ref = encoder.encode_choice_option(
                observation,
                "select_pokemon",
                ChoiceOption(
                    "opaque-ref",
                    "legacy seven-field ref",
                    ref={
                        "kind": "pokemon",
                        "player": 1,
                        "zone": "",
                        "slot": "bench_0",
                        "index": -1,
                        "attachment_type": "",
                        "card_id": "sv2-cand",
                    },
                ),
            )
            option_id_fallback = encoder.encode_choice_option(
                observation,
                "select_card",
                ChoiceOption("card:hand:1:sv2-cand", "known public ID"),
            )

        self.assertEqual(private_value.card_id, 0)
        self.assertEqual(malformed_ref.card_id, 0)
        self.assertEqual(option_id_fallback.card_id, card_index("sv2-cand"))

    def test_state_adapter_covers_rules_v4_and_snapshot_v2_fields(self):
        state = GameState()
        state.stadium_owner_idx = 1
        state.result_status = "DRAW"
        state.result_reason = "EQUAL_RULE_CONDITIONS"
        state.result_conditions = [["PRIZES"], ["PRIZES"]]
        state.rules_options = {"apply_type_matchups": True}
        state.apply_type_matchups = True
        state.setup_stage = "BONUS_PLACEMENT"
        state.setup_actor_idx = 1
        state.opening_coin_winner_idx = 0
        state.mulligan_bonus_max = (0, 2)
        state.setup_initial_done = (True, True)
        state.setup_bonus_card_ids = ([], ["private-basic"])
        state.pending_promotions = [1, 0]
        state.turn_fact_book = {
            "version": 1,
            "current": {
                "turn_number": 4,
                "turn_player": 0,
                "knockouts": [{
                    "turn_number": 4,
                    "owner": 1,
                    "cause": "attack_damage",
                    "source_player": 0,
                    "card_id": "knocked-out",
                    "slot": "active",
                }],
            },
            "previous": {
                "turn_number": 3,
                "turn_player": 1,
                "knockouts": [],
            },
        }

        payload = _state_payload(state)

        self.assertEqual(payload["stadium_owner_idx"], 1)
        self.assertEqual(payload["winner"], -1)
        self.assertEqual(payload["result_status"], "DRAW")
        self.assertEqual(payload["result_conditions"], [["PRIZES"], ["PRIZES"]])
        self.assertEqual(payload["rules_profile_id"], "CN_MAINLAND_3_1_0")
        self.assertTrue(payload["rules_options"]["apply_type_matchups"])
        self.assertEqual(payload["setup_ready"], [True, True])
        self.assertEqual(payload["setup_stage"], "BONUS_PLACEMENT")
        self.assertEqual(payload["setup_actor_idx"], 1)
        self.assertEqual(payload["opening_coin_winner_idx"], 0)
        self.assertEqual(payload["mulligan_bonus_max"], 2)
        self.assertEqual(payload["setup_bonus_card_ids"], [[], ["private-basic"]])
        self.assertEqual(payload["pending_promotions"], [1, 0])
        self.assertEqual(
            payload["turn_fact_book"]["current_turn"]["knockouts"][0],
            {
                "defeated_player": 1,
                "slot": "active",
                "card_id": "knocked-out",
                "source_player": 0,
                "source_kind": "attack_damage",
                "cause_kind": "damage",
                "cause_detail": "",
                "turn": 4,
            },
        )

        pokemon = _godot_pokemon_payload({
            "card_id": "healer",
            "healed_this_turn": True,
            "max_hp_modifiers": [{
                "source": "boost",
                "modifier_kind": "conditional_hp_boost",
                "energy_type": "Water",
                "threshold": 3,
                "amount": 50,
            }],
        })
        self.assertTrue(pokemon["healed_this_turn"])
        self.assertEqual(
            pokemon["modifiers"][0]["params"],
            {"energy_type": "Water", "threshold": 3, "amount": 50},
        )
        self.assertEqual(_godot_mulligan_bonus_max({"mulligan_bonus_max": [3, 0]}), 3)
        self.assertEqual(
            _godot_turn_fact_book_payload({}),
            {
                "current_turn": {"knockouts": []},
                "previous_turn": {"knockouts": []},
            },
        )

    def test_image_mapping_rejects_missing_duplicate_source_and_escape(self):
        with self.assertRaisesRegex(ValueError, "JSON object"):
            _parse_image_mapping(
                '[["card-1", "data/images/a.webp"]]'
            )
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            _parse_image_mapping(
                '{"card-1":"data/images/a.webp","card-1":"data/images/b.webp"}'
            )
        with tempfile.TemporaryDirectory() as root_dir:
            root = Path(root_dir)
            images = root / "data" / "images"
            images.mkdir(parents=True)
            (images / "one.webp").write_bytes(b"one")
            with self.assertRaisesRegex(ValueError, "Missing card image mappings"):
                _validate_image_mapping({}, python_root=root, card_ids=["card-1"])
            with self.assertRaisesRegex(FileNotFoundError, "Missing card image source"):
                _validate_image_mapping(
                    {"card-1": "data/images/missing.webp"},
                    python_root=root,
                    card_ids=["card-1"],
                )
            (root / "outside.webp").write_bytes(b"outside")
            with self.assertRaisesRegex(ValueError, "escapes data/images"):
                _validate_image_mapping(
                    {"card-1": "outside.webp"},
                    python_root=root,
                    card_ids=["card-1"],
                )
            with self.assertRaisesRegex(ValueError, "Unsafe card ID"):
                _validate_image_mapping(
                    {"../outside": "data/images/one.webp"},
                    python_root=root,
                    card_ids=["../outside"],
                )

    def test_exported_image_hashes_change_with_source_bytes(self):
        from scripts import export_godot_data

        with tempfile.TemporaryDirectory() as root_dir:
            root = Path(root_dir)
            image = root / "data" / "images" / "one.webp"
            image.parent.mkdir(parents=True)
            image.write_bytes(b"one")
            mapping = {"card-1": "data/images/one.webp"}
            with mock.patch.object(export_godot_data, "PYTHON_ROOT", root), mock.patch.object(
                export_godot_data, "ALL_CARD_IDS", ["card-1"]
            ):
                first = _image_hashes(mapping)
                image.write_bytes(b"two")
                second = _image_hashes(mapping)
            self.assertNotEqual(first["card-1"], second["card-1"])

    def test_exported_image_check_detects_stale_target_and_missing_card_back(self):
        from scripts import export_godot_data

        with tempfile.TemporaryDirectory() as root_dir, tempfile.TemporaryDirectory() as output_dir:
            root = Path(root_dir)
            output = Path(output_dir)
            images = root / "data" / "images"
            images.mkdir(parents=True)
            (images / "one.webp").write_bytes(b"one")
            card_back = images / "卡背.webp"
            card_back.write_bytes(b"back")
            mapping = {"card-1": "data/images/one.webp"}
            with mock.patch.object(export_godot_data, "PYTHON_ROOT", root), mock.patch.object(
                export_godot_data, "ALL_CARD_IDS", ["card-1"]
            ):
                _export_images(output, mapping)
                self.assertEqual(_exported_image_errors(output, mapping), [])
                (output / "assets" / "cards" / "card-1.webp").write_bytes(b"stale")
                self.assertIn("hash:card-1.webp", _exported_image_errors(output, mapping))
                stale_import = output / "assets" / "cards" / "old-card.webp.import"
                stale_import.write_text("stale", encoding="utf-8")
                self.assertIn(
                    "obsolete:old-card.webp.import",
                    _exported_image_errors(output, mapping),
                )
                card_back.unlink()
                with self.assertRaisesRegex(FileNotFoundError, "card back"):
                    _export_images(output, mapping)

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
            self.assertEqual(first_cards["svi-chim"]["ai_card_index"], 92)
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
            self.assertEqual(len(first_cards["svi-chim"]["ai_semantic_features"]), 53)
            self.assertEqual(first_cards["sv2-tatsu"]["attacks"][1]["damage"], 30)
            self.assertEqual(first_cards["sv2-tatsu"]["attacks"][1]["damage_text"], "30")
            self.assertEqual(first_cards["svi-sqwk"]["attacks"][1]["damage_text"], "60")
            self.assertEqual(first_cards["sv1-107"]["attacks"][0]["damage_text"], "10×")
            self.assertEqual(first_cards["svi-gree"]["attacks"][1]["damage_text"], "60+")
            self.assertEqual(first_cards["svg-ceti"]["attacks"][1]["damage_text"], "200-")
            self.assertEqual(first_cards["sv2-tatsu"]["attacks"][0]["damage_text"], "")
            self.assertEqual(first_cards["svg2-empo"]["attacks"][0]["damage_text"], "")
            encoder_fixture = json.loads(
                (first / "tests" / "fixtures" / "ai_encoder_golden.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(encoder_fixture["fixture_version"], 2)
            choice_view = encoder_fixture["choice"]
            self.assertEqual(
                set(choice_view),
                {
                    "schema_version",
                    "request_id",
                    "base_revision",
                    "player",
                    "request_type",
                    "prompt",
                    "options",
                    "min_select",
                    "max_select",
                    "allow_duplicates",
                    "can_cancel",
                    "presentation",
                },
            )
            self.assertEqual(choice_view["schema_version"], 2)
            self.assertGreaterEqual(choice_view["base_revision"], 0)
            for option in choice_view["options"]:
                self.assertNotIn("value", option)
                ref = option.get("ref")
                if ref is None:
                    continue
                expected_ref_fields = {
                    "card": {"kind", "player", "zone", "index", "card_id"},
                    "pokemon": {"kind", "player", "slot", "card_id"},
                    "slot": {"kind", "player", "slot"},
                    "attachment": {
                        "kind",
                        "player",
                        "slot",
                        "attachment_type",
                        "index",
                        "card_id",
                    },
                }
                self.assertEqual(set(ref), expected_ref_fields[ref["kind"]])
            self.assertEqual(len(encoder_fixture["expected"]["state_numeric"]), 960)
            self.assertEqual(len(encoder_fixture["expected"]["state_cards"]), 128)
            self.assertTrue(
                all(
                    len(row["numeric"]) == 178
                    for row in encoder_fixture["expected"]["actions"]
                )
            )
            self.assertEqual(
                first_cards["svi-chim"]["image_path"],
                "res://assets/cards/svi-chim.webp",
            )

    def test_export_removes_obsolete_card_assets(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output = Path(output_dir)
            target_root = output / "assets" / "cards"
            target_root.mkdir(parents=True)
            stale_image = target_root / "stale-card.png"
            stale_import = target_root / "stale-card.png.import"
            unrelated = target_root / "notes.txt"
            stale_image.write_bytes(b"stale")
            stale_import.write_text("stale import", encoding="utf-8")
            unrelated.write_text("keep", encoding="utf-8")

            export(output, copy_images=True)
            card_images = json.loads((output / "data" / "card_images.json").read_text(encoding="utf-8"))
            first_image = Path(next(iter(card_images.values()))).name

            self.assertFalse(stale_image.exists())
            self.assertFalse(stale_import.exists())
            self.assertTrue(unrelated.exists())
            self.assertTrue((target_root / "card_back.webp").exists())
            self.assertTrue((target_root / first_image).exists())

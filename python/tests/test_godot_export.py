import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.export_godot_data import (
    _image_hashes,
    _parse_image_mapping,
    _validate_image_mapping,
    export,
)


class GodotDataExportTests(unittest.TestCase):
    def test_image_mapping_rejects_missing_duplicate_source_and_escape(self):
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
            rules = json.loads(
                (first / "tests" / "fixtures" / "rules_golden.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(rules["fixture_version"], 2)
            self.assertEqual(rules["rng_algorithm"], "xorshift32-v1")
            self.assertEqual(len(rules["cases"]), 5)
            self.assertTrue(
                all("expected_rng_state" in row for row in rules["cases"].values())
            )
            self.assertTrue(
                rules["cases"]["pending_attack_choice_cancel"]["choice_response"]["cancelled"]
            )

            first_cards = json.loads((first / "data" / "cards.json").read_text(encoding="utf-8"))
            second_cards = json.loads((second / "data" / "cards.json").read_text(encoding="utf-8"))
            self.assertEqual(first_cards, second_cards)
            self.assertEqual(len(first_cards), 137)
            self.assertEqual(first_cards["svi-chim"]["card_bucket"], 3624)
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
            self.assertEqual(len(encoder_fixture["expected"]["state_numeric"]), 960)
            self.assertEqual(len(encoder_fixture["expected"]["state_cards"]), 96)
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

    def test_model_manifest_covers_all_release_decks(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output = Path(output_dir)
            export(output, copy_images=False)
            manifest = json.loads((output / "data" / "ai_models.json").read_text(encoding="utf-8"))

            self.assertEqual(manifest["state_numeric_size"], 960)
            self.assertEqual(manifest["state_card_slots"], 96)
            self.assertEqual(manifest["action_numeric_size"], 178)
            self.assertEqual(manifest["search_simulations"], 64)
            self.assertEqual(
                set(manifest["models"]),
                {
                    "fire",
                    "water",
                    "psychic",
                    "lightning",
                    "fighting",
                    "colorless",
                    "dragon",
                    "grass",
                    "steel",
                    "darkness",
                },
            )
            existing_release_checkpoints = {
                key
                for key, row in manifest["models"].items()
                if bool(row["checkpoint_exists"])
            }
            self.assertTrue(
                {
                    "fire",
                    "water",
                    "psychic",
                    "lightning",
                    "fighting",
                    "colorless",
                    "dragon",
                    "grass",
                }.issubset(existing_release_checkpoints)
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

import json
import tempfile
import unittest
from pathlib import Path

from scripts.export_godot_data import export


class GodotDataExportTests(unittest.TestCase):
    def test_export_is_complete_and_deterministic(self):
        with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
            first = Path(first_dir)
            second = Path(second_dir)
            first_contract = export(first, copy_images=False)
            second_contract = export(second, copy_images=False)

            self.assertEqual(first_contract, second_contract)
            self.assertEqual(first_contract["counts"]["cards"], 137)
            self.assertEqual(first_contract["counts"]["decks"], 10)
            self.assertEqual(len(first_contract["effect_types"]), 78)
            self.assertEqual(len(first_contract["effect_examples"]), 78)
            self.assertEqual(len(first_contract["compiled_effect_examples"]), 78)
            self.assertTrue(all(size == 60 for size in first_contract["deck_sizes"].values()))
            rules = json.loads(
                (first / "tests" / "fixtures" / "rules_golden.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(len(rules["cases"]), 3)

            first_cards = json.loads((first / "data" / "cards.json").read_text(encoding="utf-8"))
            second_cards = json.loads((second / "data" / "cards.json").read_text(encoding="utf-8"))
            self.assertEqual(first_cards, second_cards)
            self.assertEqual(len(first_cards), 137)
            self.assertEqual(first_cards["svi-chim"]["card_bucket"], 3624)
            self.assertIn("compiled_effects", first_cards["svi-chim"]["attacks"][0])
            self.assertEqual(len(first_cards["svi-chim"]["ai_semantic_features"]), 53)
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
            self.assertEqual(manifest["search_simulations"], 256)
            self.assertEqual(len(manifest["models"]), 8)
            self.assertTrue(all(row["checkpoint_exists"] for row in manifest["models"].values()))

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

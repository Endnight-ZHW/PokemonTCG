"""Tests for the card image resource manager."""
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data.card_models import Card
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from tests.temp_utils import supports_file_delete, temp_dir
from ui.image_manager import ImageManager


CardRegistry.initialize(ALL_CARD_IDS)


def _write_file(path: Path, content: bytes = b"image") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


class CardImageManagerTests(unittest.TestCase):

    def _manager(self, root: Path) -> ImageManager:
        return ImageManager(
            image_cache_dir=str(root / "data" / "images"),
            mapping_file=str(root / "data" / "card_image_mapping.json"),
        )

    def test_generate_card_filename_uses_name_and_api_id_with_windows_safe_chars(self):
        card = Card(api_id="sv1/001:bad", name="皮卡丘 ex:*?", supertype="Pokémon")
        mgr = ImageManager(initialize=False)

        self.assertEqual(
            mgr.generate_card_filename(card, ".PNG"),
            "皮卡丘 ex____sv1_001_bad.png",
        )

    def test_resolve_card_image_does_not_use_generic_name_for_same_name_cards(self):
        with temp_dir() as tmp:
            root = Path(tmp)
            generic = root / "data" / "images" / "宝可梦" / "米立龙.png"
            specific = root / "data" / "images" / "宝可梦" / "米立龙__sv2-tatsu.png"
            _write_file(generic)
            _write_file(specific)
            mapping = {
                "米立龙": "data/images/宝可梦/米立龙.png",
                "sv2-tatsu": "data/images/宝可梦/米立龙__sv2-tatsu.png",
            }
            mapping_path = root / "data" / "card_image_mapping.json"
            mapping_path.parent.mkdir(parents=True, exist_ok=True)
            mapping_path.write_text(json.dumps(mapping, ensure_ascii=False), encoding="utf-8")

            mgr = self._manager(root)
            dragon_tatsugiri = CardRegistry.get("svg-tatsu")
            water_tatsugiri = CardRegistry.get("sv2-tatsu")

            self.assertIsNone(mgr.resolve_card_image(dragon_tatsugiri))
            self.assertEqual(mgr.resolve_card_image(water_tatsugiri), str(specific))

    def test_normalize_card_image_library_writes_id_mapping_and_copies_shared_files(self):
        with temp_dir() as tmp:
            root = Path(tmp)
            shared = root / "data" / "images" / "宝可梦" / "米立龙.png"
            water = root / "data" / "images" / "宝可梦" / "sv2-tatsu.png"
            orphan = root / "data" / "images" / "宝可梦" / "孤立图片.png"
            card_back = root / "data" / "images" / "卡背.webp"
            _write_file(shared, b"dragon")
            _write_file(water, b"water")
            _write_file(orphan, b"orphan")
            _write_file(card_back, b"back")
            mapping_path = root / "data" / "card_image_mapping.json"
            mapping_path.parent.mkdir(parents=True, exist_ok=True)
            mapping_path.write_text(json.dumps({
                "米立龙": "data/images/宝可梦/米立龙.png",
                "svg-tatsu": "data/images/宝可梦/米立龙.png",
                "sv2-tatsu": "data/images/宝可梦/sv2-tatsu.png",
                "孤立图片": "data/images/宝可梦/孤立图片.png",
            }, ensure_ascii=False), encoding="utf-8")

            mgr = self._manager(root)
            report = mgr.normalize_card_image_library([
                CardRegistry.get("svg-tatsu"),
                CardRegistry.get("sv2-tatsu"),
            ])
            normalized_mapping = json.loads(mapping_path.read_text(encoding="utf-8"))

            self.assertGreaterEqual(report.normalized_count, 2)
            self.assertEqual(set(normalized_mapping), {"svg-tatsu", "sv2-tatsu"})
            self.assertTrue((root / normalized_mapping["svg-tatsu"]).exists())
            self.assertTrue((root / normalized_mapping["sv2-tatsu"]).exists())
            self.assertEqual(Path(normalized_mapping["svg-tatsu"]).name, "米立龙__svg-tatsu.png")
            self.assertEqual(Path(normalized_mapping["sv2-tatsu"]).name, "米立龙__sv2-tatsu.png")
            self.assertTrue(orphan.exists())
            self.assertTrue(card_back.exists())

    def test_delete_card_image_removes_current_card_file_and_mapping(self):
        if not supports_file_delete():
            self.skipTest("Current sandbox does not allow deleting test files")

        with temp_dir() as tmp:
            root = Path(tmp)
            image = root / "data" / "images" / "宝可梦" / "米立龙__sv2-tatsu.png"
            _write_file(image)
            mapping_path = root / "data" / "card_image_mapping.json"
            mapping_path.parent.mkdir(parents=True, exist_ok=True)
            mapping_path.write_text(json.dumps({
                "sv2-tatsu": "data/images/宝可梦/米立龙__sv2-tatsu.png",
            }, ensure_ascii=False), encoding="utf-8")

            mgr = self._manager(root)
            result = mgr.delete_card_image_for_card(CardRegistry.get("sv2-tatsu"))
            normalized_mapping = json.loads(mapping_path.read_text(encoding="utf-8"))

            self.assertTrue(result.deleted, result.message)
            self.assertFalse(image.exists())
            self.assertEqual(normalized_mapping, {})

    def test_delete_card_image_blocks_shared_referenced_file(self):
        if not supports_file_delete():
            self.skipTest("Current sandbox does not allow deleting test files")

        with temp_dir() as tmp:
            root = Path(tmp)
            image = root / "data" / "images" / "宝可梦" / "shared.png"
            _write_file(image)
            mapping_path = root / "data" / "card_image_mapping.json"
            mapping_path.parent.mkdir(parents=True, exist_ok=True)
            mapping_path.write_text(json.dumps({
                "svg-tatsu": "data/images/宝可梦/shared.png",
                "sv2-tatsu": "data/images/宝可梦/shared.png",
            }, ensure_ascii=False), encoding="utf-8")

            mgr = self._manager(root)
            result = mgr.delete_card_image_for_card(CardRegistry.get("sv2-tatsu"))

            self.assertFalse(result.deleted)
            self.assertIn("仍被", result.message)
            self.assertTrue(image.exists())


if __name__ == "__main__":
    unittest.main()

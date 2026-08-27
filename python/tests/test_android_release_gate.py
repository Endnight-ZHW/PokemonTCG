from __future__ import annotations

import configparser
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class AndroidReleaseGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.parser = configparser.ConfigParser(interpolation=None)
        cls.parser.optionxform = str
        cls.parser.read(
            REPO_ROOT / "godot" / "export_presets.cfg", encoding="utf-8"
        )
        cls.by_name = {
            cls.parser.get(section, "name").strip('"'): section
            for section in cls.parser.sections()
            if section.startswith("preset.") and not section.endswith(".options")
        }

    def test_only_product_export_presets_remain(self):
        self.assertEqual(
            set(self.by_name),
            {"Windows Desktop", "Android ARM64", "Android ARM64 Release Smoke"},
        )
        for name, section in self.by_name.items():
            with self.subTest(name=name):
                excluded = self.parser.get(section, "exclude_filter").strip('"')
                self.assertIn("tests/*", excluded)
                self.assertIn("tools/*", excluded)
                self.assertNotIn("onnx", excluded.lower())
                self.assertNotIn("deep", name.lower())

    def test_smoke_preset_only_adds_release_smoke_flag(self):
        release = self.by_name["Android ARM64"]
        smoke = self.by_name["Android ARM64 Release Smoke"]
        release_values = dict(self.parser.items(f"{release}.options"))
        smoke_values = dict(self.parser.items(f"{smoke}.options"))
        self.assertEqual(
            release_values.pop("command_line/extra_args").strip('"'), ""
        )
        self.assertEqual(
            smoke_values.pop("command_line/extra_args").strip('"'),
            "-- --phase6-release-smoke",
        )
        self.assertEqual(release_values, smoke_values)

    def test_android_runtime_is_self_contained_and_onnx_free(self):
        android_bin = REPO_ROOT / "godot" / "bin" / "android"
        for name in (
            "libpokemon_ai.android.template_debug.arm64.so",
            "libpokemon_ai.android.template_release.arm64.so",
        ):
            self.assertTrue((android_bin / name).is_file(), name)
        self.assertFalse((android_bin / "libonnxruntime.so").exists())
        descriptor = (REPO_ROOT / "godot" / "bin" / "pokemon_ai.gdextension").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("onnxruntime", descriptor.lower())


if __name__ == "__main__":
    unittest.main()

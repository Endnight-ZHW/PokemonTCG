from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from scripts.export_godot_data import DECKS


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleaseManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(
            (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
        )

    def test_generated_manifest_and_release_set_are_exact(self):
        generated = json.loads(
            (REPO_ROOT / "godot" / "data" / "release_manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(generated, self.manifest)
        decks = self.manifest["release_decks"]
        self.assertEqual(len(decks), self.manifest["model_count"])
        self.assertEqual(len(decks), len(set(decks)))
        self.assertEqual(set(decks), set(DECKS))
        model_root = REPO_ROOT / "godot" / "data" / "ai_models"
        self.assertEqual(
            sorted(path.stem for path in model_root.glob("*.onnx")),
            sorted(decks),
        )

    def test_schema_and_android_metadata_match_runtime(self):
        schemas = self.manifest["schemas"]
        self.assertEqual(schemas["python_rules"], RULES_SCHEMA_VERSION)
        self.assertEqual(schemas["python_actions"], ACTION_SCHEMA_VERSION)
        app_state = (REPO_ROOT / "godot" / "autoload" / "app_state.gd").read_text(
            encoding="utf-8"
        )
        self.assertRegex(
            app_state,
            rf"RULES_SCHEMA_VERSION\s*:=\s*{int(schemas['godot_rules'])}\b",
        )
        self.assertRegex(
            app_state,
            rf"ACTION_SCHEMA_VERSION\s*:=\s*{int(schemas['godot_actions'])}\b",
        )
        presets = (REPO_ROOT / "godot" / "export_presets.cfg").read_text(
            encoding="utf-8"
        )
        self.assertRegex(
            presets,
            rf"(?m)^version/code={int(self.manifest['android_version_code'])}$",
        )
        self.assertRegex(
            presets,
            rf'(?m)^version/name="{re.escape(str(self.manifest["version"]))}"$',
        )


if __name__ == "__main__":
    unittest.main()

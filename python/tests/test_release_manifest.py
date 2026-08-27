from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "godot" / "data" / "release_manifest.json"


class ReleaseManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_godot_manifest_is_the_only_release_manifest(self):
        self.assertTrue(MANIFEST_PATH.is_file())
        self.assertFalse((REPO_ROOT / "release_manifest.json").exists())

    def test_player_visible_versions_are_frozen(self):
        manifest = self.manifest
        self.assertEqual(manifest["version"], "0.7.0")
        self.assertEqual(manifest["android_version_code"], 8)
        self.assertEqual(manifest["schemas"]["godot_actions"], 4)
        self.assertEqual(manifest["schemas"]["choice_view"], 2)
        self.assertEqual(manifest["schemas"]["protocol"], 6)
        self.assertEqual(manifest["schemas"]["snapshot"], 3)
        self.assertEqual(manifest["schemas"]["journal"], 1)
        self.assertEqual(manifest["schemas"]["rng"], 2)
        self.assertEqual(len(manifest["release_decks"]), 10)
        self.assertTrue(manifest["native_challenge"]["production_ready"])

    def test_product_manifest_has_no_research_runtime_fields(self):
        encoded = json.dumps(self.manifest, sort_keys=True).lower()
        for retired in (
            "deep_",
            "onnx",
            "model_count",
            "checkpoint",
            "card_vocab",
            "ai_evaluation",
        ):
            self.assertNotIn(retired, encoded)

    def test_product_tree_has_no_onnx_or_deep_runtime_assets(self):
        forbidden = [
            REPO_ROOT / "godot" / "bin" / "windows" / "onnxruntime.dll",
            REPO_ROOT / "godot" / "bin" / "android" / "libonnxruntime.so",
            REPO_ROOT / "godot" / "data" / "ai_models_runtime.json",
            REPO_ROOT / "godot" / "ai" / "deep_ai_runtime.gd",
            REPO_ROOT / "godot" / "ai" / "information_set_puct.gd",
        ]
        self.assertTrue(all(not path.exists() for path in forbidden))

    def test_runtime_strategy_payload_excludes_test_and_hook_data(self):
        payload = json.loads(
            (REPO_ROOT / "godot" / "data" / "ai_strategies.json").read_text(
                encoding="utf-8"
            )
        )
        for strategy in payload["strategies"].values():
            self.assertNotIn("golden_scenarios", strategy)
            self.assertNotIn("runtime_hook_hash", strategy)

    def test_real_exporter_check_passes(self):
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(REPO_ROOT / "python" / "scripts" / "export_godot_data.py"),
                "--check",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

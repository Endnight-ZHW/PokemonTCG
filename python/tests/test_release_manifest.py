from __future__ import annotations

import configparser
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
        parsed_presets = configparser.ConfigParser(interpolation=None)
        parsed_presets.optionxform = str
        parsed_presets.read_string(presets)
        android_presets = [
            section
            for section in parsed_presets.sections()
            if re.fullmatch(r"preset\.\d+", section)
            and parsed_presets.get(section, "platform", fallback="").strip('"')
            == "Android"
        ]
        self.assertTrue(android_presets, "No Android export presets found")
        for preset in android_presets:
            options = f"{preset}.options"
            preset_name = parsed_presets.get(preset, "name", fallback=preset)
            self.assertTrue(parsed_presets.has_section(options), preset_name)
            self.assertEqual(
                parsed_presets.getint(options, "version/code"),
                int(self.manifest["android_version_code"]),
                preset_name,
            )
            self.assertEqual(
                parsed_presets.get(options, "version/name").strip('"'),
                str(self.manifest["version"]),
                preset_name,
            )

    def test_godot_runtime_release_metadata_is_manifest_driven(self):
        app_state = (REPO_ROOT / "godot" / "autoload" / "app_state.gd").read_text(
            encoding="utf-8"
        )
        self.assertIn('"res://data/release_manifest.json"', app_state)
        self.assertIn('.get("version", "")', app_state)
        self.assertNotIn(str(self.manifest["version"]), app_state)
        self.assertNotRegex(app_state, r"const\s+APP_VERSION\s*:=")

        ai_regression = (
            REPO_ROOT / "godot" / "tests" / "ai_regression.gd"
        ).read_text(encoding="utf-8")
        self.assertIn('"res://data/release_manifest.json"', ai_regression)
        self.assertIn('manifest.get("release_decks", null)', ai_regression)
        self.assertIn('manifest.get("model_count", -1)', ai_regression)
        self.assertNotIn("DEEP_DECK_KEYS", ai_regression)
        self.assertNotIn("CHALLENGE_DECK_KEYS", ai_regression)

    def test_gpu_lock_matches_release_toolchain_versions(self):
        locked_toolchain = json.loads(
            (REPO_ROOT / "tools" / "toolchain.lock.json").read_text(encoding="utf-8")
        )
        toolchain = locked_toolchain["python"]
        self.assertEqual(
            str(self.manifest["godot_version"]),
            str(locked_toolchain["godot"]["full_config"]),
        )
        environment = (REPO_ROOT / "python" / "environment.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(f"python={toolchain['version']}", environment)
        self.assertIn("-r requirements-ai-gpu.lock.txt", environment)
        self.assertIn('PYTHONNOUSERSITE: "1"', environment)

        rows = {}
        lock_text = (
            REPO_ROOT / "python" / "requirements-ai-gpu.lock.txt"
        ).read_text(encoding="utf-8")
        for raw_line in lock_text.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or line.startswith("--"):
                continue
            name, separator, version = line.partition("==")
            self.assertEqual(separator, "==", line)
            rows[name.lower()] = version
        self.assertEqual(rows["numpy"], toolchain["numpy"])
        self.assertEqual(rows["onnx"], toolchain["onnx"])
        self.assertEqual(rows["onnxruntime"], toolchain["onnxruntime"])
        self.assertEqual(rows["torch"].split("+", 1)[0], toolchain["torch"])
        expected_cuda_tag = "cu" + str(toolchain["cuda"]).replace(".", "")
        self.assertEqual(rows["torch"].split("+", 1)[1], expected_cuda_tag)

    def test_godot_tool_paths_are_derived_from_the_toolchain_lock(self):
        common = (
            REPO_ROOT / "tools" / "toolchain_common.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("function Get-GodotToolchainPaths", common)
        scripts = (
            "setup_godot_toolchain.ps1",
            "build_godot.ps1",
            "test_godot.ps1",
            "test_godot_ai.ps1",
            "test_godot_network.ps1",
            "evaluate_godot_ai.ps1",
        )
        for name in scripts:
            source = (REPO_ROOT / "tools" / name).read_text(encoding="utf-8")
            self.assertIn("Get-GodotToolchainPaths", source, name)
            self.assertNotRegex(
                source,
                r"godot-4\.7|Godot_v4\.7|editor_settings-4\.7|export_templates\\4\.7",
                name,
            )

    def test_deep_ai_pipeline_reads_release_decks_from_manifest(self):
        source = (
            REPO_ROOT / "tools" / "train_deep_ai_v10.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("Get-ReleaseManifest -RepoRoot $repoRoot", source)
        self.assertIn("$release.release_decks", source)
        self.assertNotRegex(
            source,
            r"\$releaseDecks\s*=\s*@\(\s*['\"]fire['\"]",
        )

    def test_release_schema_consumers_do_not_redeclare_manifest_versions(self):
        deep_runtime = (
            REPO_ROOT / "godot" / "ai" / "deep_ai_runtime.gd"
        ).read_text(encoding="utf-8")
        self.assertIn('"res://data/release_manifest.json"', deep_runtime)
        self.assertIn('schemas.get("python_rules", 0)', deep_runtime)
        self.assertIn('schemas.get("python_actions", 0)', deep_runtime)
        self.assertIn('schemas.get("encoder", 0)', deep_runtime)
        self.assertIn('onnx.get("opset", 0)', deep_runtime)
        self.assertIn('onnx.get("runtime_version", "")', deep_runtime)
        self.assertNotIn("EXPECTED_PYTHON_ENCODER_VERSION", deep_runtime)
        self.assertNotRegex(
            deep_runtime,
            r'bridge\.get\("python_(?:rules|action)_version", 0\)\)\s*!=\s*2',
        )

        train = (
            REPO_ROOT / "tools" / "train_deep_ai_v10.ps1"
        ).read_text(encoding="utf-8")
        for field in (
            "python_rules",
            "python_actions",
            "encoder",
            "planner",
        ):
            self.assertIn(f"$release.schemas.{field}", train)
        self.assertIn("[string]$metadata.deck -ceq $DeckKey", train)
        self.assertIn("-DeckKey $deck", train)
        self.assertNotRegex(train, r"metadata\.encoder_version\s+-eq\s+3\b")

        onnx_export = (
            REPO_ROOT / "python" / "scripts" / "export_onnx_models.py"
        ).read_text(encoding="utf-8")
        self.assertIn('RELEASE_MANIFEST["schemas"]["godot_rules"]', onnx_export)
        self.assertIn('RELEASE_MANIFEST["schemas"]["godot_actions"]', onnx_export)
        self.assertNotRegex(onnx_export, r'"godot_(?:rules|action)_version":\s*3\b')

        godot_export = (
            REPO_ROOT / "python" / "scripts" / "export_godot_data.py"
        ).read_text(encoding="utf-8")
        self.assertIn('release_schemas["godot_rules"]', godot_export)
        self.assertIn('release_schemas["godot_actions"]', godot_export)
        self.assertIn('release_schemas["protocol"]', godot_export)


if __name__ == "__main__":
    unittest.main()

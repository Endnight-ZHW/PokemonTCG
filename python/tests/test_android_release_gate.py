from __future__ import annotations

import configparser
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class AndroidReleaseGateTests(unittest.TestCase):
    def test_smoke_preset_only_adds_the_phase_six_startup_flag(self):
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read(REPO_ROOT / "godot" / "export_presets.cfg", encoding="utf-8")
        by_name = {
            parser.get(section, "name").strip('"'): section
            for section in parser.sections()
            if section.startswith("preset.") and not section.endswith(".options")
        }
        release_section = by_name["Android ARM64"]
        smoke_section = by_name["Android ARM64 Release Smoke"]
        release_options = f"{release_section}.options"
        smoke_options = f"{smoke_section}.options"

        release_preset = dict(parser.items(release_section))
        smoke_preset = dict(parser.items(smoke_section))
        for expected_difference in ("name", "export_path", "runnable"):
            release_preset.pop(expected_difference)
            smoke_preset.pop(expected_difference)
        self.assertEqual(release_preset, smoke_preset)

        self.assertEqual(
            parser.get(release_options, "command_line/extra_args").strip('"'), ""
        )
        self.assertEqual(
            parser.get(smoke_options, "command_line/extra_args").strip('"'),
            "-- --phase6-release-smoke",
        )
        release_values = dict(parser.items(release_options))
        smoke_values = dict(parser.items(smoke_options))
        release_values.pop("command_line/extra_args")
        smoke_values.pop("command_line/extra_args")
        self.assertEqual(release_values, smoke_values)

    def test_runtime_gate_requires_native_arm64_and_matching_payloads(self):
        source = (REPO_ROOT / "tools" / "test_android_runtime.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Get-ApkRuntimeHashes", source)
        self.assertIn("Get-ApkIdentity", source)
        self.assertIn("Get-ApkSignerDigests", source)
        self.assertIn("ANDROID_SMOKE_IDENTITY_MATCH", source)
        self.assertIn("ANDROID_APK_SOURCE_MATCH", source)
        self.assertIn("godot\\data\\ai_models_runtime.json", source)
        self.assertIn("godot\\bin\\android\\libonnxruntime.so", source)
        self.assertIn("ro.product.cpu.abi", source)
        self.assertIn("ro.dalvik.vm.native.bridge", source)
        self.assertIn("ANDROID_SMOKE_PAYLOAD_MATCH", source)
        self.assertIn("ANDROID_RELEASE_AI_OK", source)
        self.assertIn("compatible_models=$ExpectedModels", source)
        self.assertIn("onnx_assets=0", source)
        self.assertIn("Assert-ReleaseDeepFallbackContract", source)
        self.assertIn("ExpectedModels does not match release_manifest", source)
        self.assertNotIn("ExpectedModels must be positive", source)
        self.assertNotIn("--esa command_line_params", source)

    def test_disabled_deep_release_excludes_onnx_from_every_export(self):
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read(REPO_ROOT / "godot" / "export_presets.cfg", encoding="utf-8")
        presets = [
            section
            for section in parser.sections()
            if section.startswith("preset.") and not section.endswith(".options")
        ]
        self.assertGreaterEqual(len(presets), 3)
        for preset in presets:
            with self.subTest(preset=parser.get(preset, "name")):
                self.assertNotIn(
                    "data/ai_models/*.onnx",
                    parser.get(preset, "include_filter").strip('"'),
                )
                self.assertIn(
                    "data/ai_models/*.onnx",
                    parser.get(preset, "exclude_filter").strip('"'),
                )

        smoke_runner = (
            REPO_ROOT / "godot" / "scenes" / "main" / "export_smoke_runner.gd"
        ).read_text(encoding="utf-8")
        self.assertIn("_legacy_onnx_assets_absent", smoke_runner)
        self.assertIn("onnx_assets=0", smoke_runner)
        self.assertIn('FileAccess.file_exists("res://data/ai_models/%s.onnx"', smoke_runner)

    def test_build_and_release_paths_include_the_smoke_artifact(self):
        build = (REPO_ROOT / "tools" / "build_godot.ps1").read_text(
            encoding="utf-8"
        )
        package = (REPO_ROOT / "tools" / "package_release.ps1").read_text(
            encoding="utf-8"
        )
        release_test = (REPO_ROOT / "tools" / "test_release.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("[bool]$IncludeAndroidRuntimeSmoke = $true", build)
        self.assertIn("Android ARM64 Release Smoke", build)
        self.assertIn("-IncludeAndroidRuntimeSmoke:", package)
        self.assertIn("PokemonTCG-smoke.apk", release_test)
        self.assertIn("-SmokeApkPath $smokeApkPath", release_test)
        self.assertIn("WaitForExit(180000)", package)
        self.assertIn("WaitForExit(180000)", release_test)
        self.assertIn("$expectedManifestFiles", release_test)
        self.assertIn("Sort-Object -Unique", release_test)
        self.assertIn("Checksum manifest file set is missing", release_test)
        self.assertIn("'.onnx'", release_test)
        self.assertIn("deep_runtime_enabled", package)
        self.assertIn("deep_fallback", package)
        self.assertIn("Windows release staging contains legacy ONNX", package)

    def test_nightly_ci_builds_then_verifies_the_release_pair(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "verify.yml").read_text(
            encoding="utf-8"
        )
        for required in (
            "conda-incubator/setup-miniconda@v3",
            ".\\tools\\setup_ai_toolchain.ps1",
            ".\\tools\\setup_android_toolchain.ps1",
            ".\\tools\\setup_native_ai_deps.ps1",
            ".\\tools\\package_release.ps1 -AndroidSigning test",
            ".\\tools\\test_release.ps1",
        ):
            self.assertIn(required, workflow)
        self.assertLess(
            workflow.index("package_release.ps1"),
            workflow.index("test_release.ps1"),
        )


if __name__ == "__main__":
    unittest.main()

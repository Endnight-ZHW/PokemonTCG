from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

from deep_ai import challenge_arena_build as build


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = RESEARCH_ROOT.parents[1]
BASELINE_COMMIT = "d4f20ee9775b7e8c80a1994e5c9aa5f1e11c9864"


def _latest_manifest(agent_id: str) -> Path | None:
    values = list((
        RESEARCH_ROOT / "build" / "arena-agents" / agent_id
    ).glob("*/agent.build.json"))
    return max(values, key=lambda path: path.stat().st_mtime) if values else None


class ChallengeArenaBuildTests(unittest.TestCase):
    def test_nested_and_common_headers_invalidate_agent_and_binding(self) -> None:
        original_agent = build.agent_input_manifest(REPO_ROOT, REPO_ROOT, compiler="msvc")
        original_binding = build.binding_input_manifest(REPO_ROOT, compiler="msvc")
        real_sha256 = build.sha256_file
        for filename in ("strategic_types.hpp", "ptcg_sha256.hpp", "ptcg_json_string.hpp"):
            with self.subTest(header=filename):
                def changed(path: Path) -> str:
                    return "0" * 64 if path.name == filename else real_sha256(path)
                with mock.patch.object(build, "sha256_file", side_effect=changed):
                    modified = build.agent_input_manifest(REPO_ROOT, REPO_ROOT, compiler="msvc")
                    binding = build.binding_input_manifest(REPO_ROOT, compiler="msvc")
                self.assertNotEqual(original_agent["implementation_hash"], modified["implementation_hash"])
                self.assertNotEqual(original_agent["build_input_hash"], modified["build_input_hash"])
                self.assertNotEqual(original_binding["input_hash"], binding["input_hash"])

    @unittest.skipUnless(
        (RESEARCH_ROOT / "build" / "native" / "ptcg_ai_core.pyd").is_file(),
        "Arena binding is not built",
    )
    def test_binding_sidecar_covers_current_pyd_and_component_inputs(self) -> None:
        binding = RESEARCH_ROOT / "build" / "native" / "ptcg_ai_core.pyd"
        manifest = build.load_and_verify_binding(
            REPO_ROOT,
            binding,
            binding.with_name("ptcg_ai_core.build.json"),
        )
        self.assertEqual(Path(manifest["binding_path"]), binding.resolve())
        self.assertTrue(manifest["compiler"])
        self.assertIn("rules_source_hash", manifest["inputs"])
        self.assertIn("challenge_source_hash", manifest["inputs"])
        self.assertIn("arena_source_hash", manifest["inputs"])

    def test_source_change_alters_implementation_and_cache_hash(self) -> None:
        original = build.agent_input_manifest(REPO_ROOT, REPO_ROOT, compiler="msvc")
        real_sha256 = build.sha256_file

        def changed(path: Path) -> str:
            digest = real_sha256(path)
            if path.name == "ptcg_challenge_agent_main.cpp":
                return "0" * 64 if digest != "0" * 64 else "1" * 64
            return digest

        with mock.patch.object(build, "sha256_file", side_effect=changed):
            modified = build.agent_input_manifest(
                REPO_ROOT, REPO_ROOT, compiler="msvc"
            )
        self.assertNotEqual(
            original["implementation_hash"], modified["implementation_hash"]
        )
        self.assertNotEqual(original["build_input_hash"], modified["build_input_hash"])

    @unittest.skipUnless(
        _latest_manifest("challenge_next") is not None,
        "Current Arena Agent is not built",
    )
    def test_current_agent_sidecar_matches_all_build_inputs(self) -> None:
        manifest = build.load_and_verify_agent(_latest_manifest("challenge_next"))
        expected = build.agent_input_manifest(
            REPO_ROOT,
            REPO_ROOT,
            compiler=str(manifest["compiler"]),
        )
        self.assertEqual(manifest["implementation_hash"], expected["implementation_hash"])
        self.assertEqual(manifest["build_input_hash"], expected["build_input_hash"])
        self.assertTrue(manifest["compiler"])
        self.assertIn("rules_source_hash", manifest["inputs"])
        self.assertIn("challenge_source_hash", manifest["inputs"])
        self.assertIn("driver_source_hash", manifest["inputs"])
        self.assertIn("build_tool_source_hash", manifest["inputs"])

    @unittest.skipUnless(
        _latest_manifest("challenge_release_v1") is not None,
        "Frozen baseline Arena Agent is not built",
    )
    def test_frozen_baseline_sidecar_pins_full_commit(self) -> None:
        manifest = build.load_and_verify_agent(
            _latest_manifest("challenge_release_v1")
        )
        self.assertEqual(manifest["git_ref"], BASELINE_COMMIT)
        self.assertEqual(manifest["source_git"]["commit"], BASELINE_COMMIT)
        self.assertFalse(manifest["source_git"]["dirty"])


if __name__ == "__main__":
    unittest.main()

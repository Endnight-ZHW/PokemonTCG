from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "verify_native_gameplay_profile.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_native_gameplay_profile", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def _match() -> dict[str, object]:
    return {
        "actions": 4,
        "choices": 2,
        "decisions": 4,
        "turns": 2,
        "winner": 0,
        "engine_winner": 0,
        "score": 1,
        "terminal_reason": "game_over",
        "terminal_message": "",
        "invalid_actions": 0,
        "rule_exceptions": 0,
        "choice_failures": 0,
        "deep_fallbacks": 0,
        "emergency_fallbacks": 0,
        "max_actions_exhausted": False,
        "time_capped_decisions": 0,
        "search_depth_samples_by_strategy": {},
        "elapsed_ms": 90.0,
    }


def _counts() -> dict[str, int]:
    return {
        "actions": 4,
        "choices": 2,
        "decisions": 4,
        "matches": 1,
        "ai_planner_nodes": 100,
        "ai_root_action_count": 8,
        "ai_simulated_action_score_calls": 3,
        "ai_turn_plan_cache_hits": 1,
        "ai_turn_plan_cache_misses": 1,
        "ai_no_progress_actions_blocked": 0,
    }


class NativeGameplayProfileGateTests(unittest.TestCase):
    def _fixture(self) -> tuple[Path, Path, Path, tempfile.TemporaryDirectory[str]]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        baseline = {
            "matches": [_match()],
            "performance_profile": {"counts": _counts()},
        }
        baseline_path = root / "baseline.json"
        baseline_path.write_text(
            json.dumps(baseline, sort_keys=True) + "\n", encoding="utf-8")
        baseline_hash = hashlib.sha256(baseline_path.read_bytes()).hexdigest()
        contract = {
            "source_result": {
                "path": baseline_path.name,
                "sha256": baseline_hash,
            },
            "observed": {
                "planner_ms_per_node": 2.0,
                "match_wall_ms": 100.0,
            },
            "acceptance": {
                "maximum_planner_ms_per_node": 1.5,
                "maximum_match_wall_ms": 95.0,
                "maximum_peak_rss_ratio": 1.1,
            },
        }
        contract_path = root / "contract.json"
        contract_path.write_text(json.dumps(contract), encoding="utf-8")
        candidate = {
            "matches": [_match()],
            "performance_profile": {
                "counts": _counts(),
                "segments_ms": {"ai_turn_planner_ms": 100.0},
            },
        }
        candidate_path = root / "candidate.json"
        candidate_path.write_text(json.dumps(candidate), encoding="utf-8")
        self.addCleanup(temporary.cleanup)
        return root, contract_path, candidate_path, temporary

    def test_accepts_exact_faster_candidate(self) -> None:
        root, contract, candidate, _temporary = self._fixture()
        observed = MODULE.verify(root, contract, candidate)
        self.assertTrue(observed["passed"])
        self.assertTrue(observed["exact_match_semantics"])
        self.assertTrue(observed["exact_search_work"])

    def test_rejects_tampered_baseline(self) -> None:
        root, contract, candidate, _temporary = self._fixture()
        (root / "baseline.json").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "baseline semantics hash mismatch"):
            MODULE.verify(root, contract, candidate)


if __name__ == "__main__":
    unittest.main()

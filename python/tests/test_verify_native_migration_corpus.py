from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "verify_native_migration_corpus.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_native_migration_corpus", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPT.parent))
try:
    SPEC.loader.exec_module(MODULE)
finally:
    sys.path.remove(str(SCRIPT.parent))


def _match(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "actions": 8,
        "choices": 3,
        "decisions": 8,
        "turns": 4,
        "invalid_actions": 0,
        "rule_exceptions": 0,
        "choice_failures": 0,
        "deep_fallbacks": 0,
        "emergency_fallbacks": 0,
        "time_capped_decisions": 0,
        "max_actions_exhausted": False,
        "search_depth_samples_by_strategy": {},
    }
    row.update(overrides)
    return row


class NativeMigrationCorpusGateTests(unittest.TestCase):
    def test_accepts_exact_clean_coverage(self) -> None:
        oracle = {"matches": [_match()]}
        candidate = {"matches": [_match()]}
        observed = MODULE.verify(oracle, candidate, 1, 11)
        self.assertTrue(observed["passed"])
        self.assertEqual(observed["transitions"], 11)

    def test_rejects_semantic_difference(self) -> None:
        observed = MODULE.verify(
            {"matches": [_match()]},
            {"matches": [_match(actions=7)]},
            1,
            0,
        )
        self.assertFalse(observed["passed"])
        self.assertEqual(observed["semantic_difference_count"], 1)

    def test_rejects_malformed_row_even_when_counts_differ(self) -> None:
        with self.assertRaisesRegex(ValueError, "candidate.matches\\[1\\]"):
            MODULE.verify(
                {"matches": [_match()]},
                {"matches": [_match(), "not-an-object"]},
                0,
                0,
            )


if __name__ == "__main__":
    unittest.main()

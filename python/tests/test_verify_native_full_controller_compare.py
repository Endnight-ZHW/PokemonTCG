from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "verify_native_full_controller_compare.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_native_full_controller_compare", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def _match(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "actions": 10,
        "choices": 3,
        "decisions": 10,
        "turns": 5,
        "invalid_actions": 0,
        "rule_exceptions": 0,
        "choice_failures": 0,
        "deep_fallbacks": 0,
        "emergency_fallbacks": 0,
        "max_actions_exhausted": False,
        "terminal_reason": "game_over",
    }
    row.update(overrides)
    return row


def _golden_difference() -> dict[str, object]:
    return {
        "request_id": "golden-ko",
        "kind": "action",
        "differences": {
            "error": {
                "native": None,
                "oracle": "invalid_authoritative_legal_action:0:invalid_schema",
            }
        },
    }


class NativeFullControllerCompareGateTests(unittest.TestCase):
    def _fixture(
        self,
        logs: list[list[str]],
        matches: list[dict[str, object]] | None = None,
    ) -> tuple[dict[str, object], Path, tempfile.TemporaryDirectory[str]]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for index, lines in enumerate(logs):
            shard = root / f"shard-{index:03d}"
            shard.mkdir(parents=True)
            (shard / "stdout.log").write_text(
                "\n".join(lines) + "\n", encoding="utf-8")
        result: dict[str, object] = {
            "matches": matches if matches is not None else [_match(), _match()],
            "shards": [{"index": index} for index in range(len(logs))],
        }
        return result, root, temporary

    def test_accepts_clean_exact_logs_without_differences(self) -> None:
        results, root, temporary = self._fixture([
            [MODULE.SUCCESS_MARKER + "{}"],
            [MODULE.SUCCESS_MARKER + "{}"],
        ])
        self.addCleanup(temporary.cleanup)
        observed = MODULE.verify(results, root, 2, 0)
        self.assertTrue(observed["passed"])
        self.assertEqual(observed["unexpected_difference_count"], 0)
        self.assertEqual(observed["comparison_difference_count"], 0)

    def test_rejects_unexpected_native_oracle_difference(self) -> None:
        unexpected = MODULE.COMPARE_PREFIX + json.dumps({
            "request_id": "ai:7:1",
            "kind": "action",
            "differences": {"nodes_expanded": {"native": 8, "oracle": 9}},
        })
        results, root, temporary = self._fixture([
            [
                MODULE.COMPARE_PREFIX + json.dumps(_golden_difference()),
                unexpected,
                MODULE.SUCCESS_MARKER + "{}",
            ]
        ], [_match()])
        self.addCleanup(temporary.cleanup)
        observed = MODULE.verify(results, root, 1, 1)
        self.assertFalse(observed["passed"])
        self.assertEqual(observed["unexpected_difference_count"], 1)

    def test_rejects_missing_shard_log(self) -> None:
        results, root, temporary = self._fixture([
            [MODULE.SUCCESS_MARKER + "{}"]
        ], [_match()])
        self.addCleanup(temporary.cleanup)
        results["shards"] = [{"index": 0}, {"index": 1}]
        observed = MODULE.verify(results, root, 1, 0)
        self.assertFalse(observed["passed"])
        self.assertFalse(observed["shard_logs_complete"])

    def test_rejects_wrong_shard_log_with_same_total_count(self) -> None:
        results, root, temporary = self._fixture([
            [MODULE.SUCCESS_MARKER + "{}"],
            [MODULE.SUCCESS_MARKER + "{}"],
        ])
        self.addCleanup(temporary.cleanup)
        (root / "shard-001").rename(root / "shard-999")
        observed = MODULE.verify(results, root, 2, 0)
        self.assertFalse(observed["passed"])
        self.assertFalse(observed["shard_logs_complete"])
        self.assertEqual(len(observed["missing_shard_logs"]), 1)
        self.assertEqual(len(observed["unexpected_shard_logs"]), 1)

    def test_requires_one_success_marker_per_shard(self) -> None:
        results, root, temporary = self._fixture([
            [MODULE.SUCCESS_MARKER + "{}", MODULE.SUCCESS_MARKER + "{}"],
            [],
        ])
        self.addCleanup(temporary.cleanup)
        observed = MODULE.verify(results, root, 2, 0)
        self.assertFalse(observed["passed"])
        self.assertFalse(observed["shard_logs_complete"])
        self.assertEqual(observed["success_markers"], 2)

    def test_rejects_structural_failure(self) -> None:
        results, root, temporary = self._fixture([
            [MODULE.SUCCESS_MARKER + "{}"]
        ], [_match(rule_exceptions=1)])
        self.addCleanup(temporary.cleanup)
        observed = MODULE.verify(results, root, 1, 0)
        self.assertFalse(observed["passed"])
        self.assertFalse(observed["clean"])
        self.assertEqual(observed["structural_failures"]["rule_exceptions"], 1)


if __name__ == "__main__":
    unittest.main()

"""Fail-closed gate for NativeTraditionalAI full-controller comparisons.

The evaluation result proves match coverage and structural health.  The shard
logs carry the field-by-field NativeTraditionalAI/GDScript-oracle comparison;
an absent or malformed shard log therefore fails the gate instead of being
treated as an empty (and seemingly exact) comparison.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


COMPARE_PREFIX = "PTCG_NATIVE_FULL_COMPARE "
FAILURE_PREFIX = "PTCG_NATIVE_FULL_FAILURE "
SUCCESS_MARKER = "AI_EVALUATION_OK "
EXPECTED_GOLDEN_REQUEST_ID = "golden-ko"
EXPECTED_GOLDEN_ORACLE_ERROR = (
    "invalid_authoritative_legal_action:0:invalid_schema"
)
STRUCTURAL_FIELDS = (
    "invalid_actions",
    "rule_exceptions",
    "choice_failures",
    "deep_fallbacks",
    "emergency_fallbacks",
)


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _expected_golden_difference(payload: dict[str, Any]) -> bool:
    differences = payload.get("differences")
    if not isinstance(differences, dict):
        return False
    error = differences.get("error")
    return (
        payload.get("request_id") == EXPECTED_GOLDEN_REQUEST_ID
        and payload.get("kind") == "action"
        and isinstance(error, dict)
        and error.get("oracle") == EXPECTED_GOLDEN_ORACLE_ERROR
    )


def verify(
    results: dict[str, Any],
    log_root: Path,
    minimum_games: int,
    expected_golden_differences: int,
) -> dict[str, Any]:
    matches = results.get("matches")
    shards = results.get("shards")
    if not isinstance(matches, list):
        raise ValueError("results.matches must be an array")
    if not isinstance(shards, list) or not shards:
        raise ValueError("results.shards must be a non-empty array")
    if not log_root.is_dir():
        raise ValueError(f"log root is not a directory: {log_root}")

    log_paths = sorted(log_root.rglob("stdout.log"))
    expected_log_paths: set[Path] = set()
    for shard in shards:
        if not isinstance(shard, dict) or not isinstance(shard.get("index"), int):
            raise ValueError("each results.shards row must contain an integer index")
        index = int(shard["index"])
        if index < 0:
            raise ValueError("results.shards index must be non-negative")
        expected = (log_root / f"shard-{index:03d}" / "stdout.log").resolve()
        if expected in expected_log_paths:
            raise ValueError(f"duplicate results.shards index: {index}")
        expected_log_paths.add(expected)
    actual_log_paths = {path.resolve() for path in log_paths}
    missing_log_paths = sorted(expected_log_paths - actual_log_paths)
    unexpected_log_paths = sorted(actual_log_paths - expected_log_paths)
    comparison_rows: list[dict[str, Any]] = []
    malformed_comparisons: list[dict[str, str]] = []
    native_failure_lines: list[dict[str, str]] = []
    runtime_error_lines: list[dict[str, str]] = []
    success_markers = 0
    success_markers_by_log: dict[Path, int] = {}
    for path in log_paths:
        resolved_path = path.resolve()
        success_markers_by_log[resolved_path] = 0
        with path.open("r", encoding="utf-8-sig") as stream:
            for line_number, raw_line in enumerate(stream, start=1):
                line = raw_line.rstrip("\r\n")
                if line.startswith(COMPARE_PREFIX):
                    try:
                        payload = json.loads(line[len(COMPARE_PREFIX):])
                    except (json.JSONDecodeError, TypeError) as error:
                        malformed_comparisons.append({
                            "path": str(path),
                            "line": str(line_number),
                            "error": str(error),
                        })
                        continue
                    if not isinstance(payload, dict):
                        malformed_comparisons.append({
                            "path": str(path),
                            "line": str(line_number),
                            "error": "comparison payload is not an object",
                        })
                        continue
                    comparison_rows.append(payload)
                elif line.startswith(FAILURE_PREFIX):
                    native_failure_lines.append({
                        "path": str(path),
                        "line": str(line_number),
                    })
                elif line.startswith("SCRIPT ERROR") or line.startswith("ERROR:"):
                    runtime_error_lines.append({
                        "path": str(path),
                        "line": str(line_number),
                        "text": line[:500],
                    })
                elif line.startswith(SUCCESS_MARKER):
                    success_markers += 1
                    success_markers_by_log[resolved_path] += 1

    expected_rows = [
        row for row in comparison_rows if _expected_golden_difference(row)
    ]
    unexpected_rows = [
        row for row in comparison_rows if not _expected_golden_difference(row)
    ]
    structural_failures = {
        field: sum(
            int(row.get(field, 0))
            for row in matches
            if isinstance(row, dict)
        )
        for field in STRUCTURAL_FIELDS
    }
    malformed_matches = sum(1 for row in matches if not isinstance(row, dict))
    max_actions_exhausted = sum(
        1
        for row in matches
        if isinstance(row, dict) and bool(row.get("max_actions_exhausted", False))
    )
    non_game_over = sum(
        1
        for row in matches
        if not isinstance(row, dict) or row.get("terminal_reason") != "game_over"
    )
    totals = {
        field: sum(
            int(row.get(field, 0))
            for row in matches
            if isinstance(row, dict)
        )
        for field in ("actions", "choices", "decisions", "turns")
    }

    coverage_satisfied = len(matches) >= max(0, minimum_games)
    shard_logs_complete = (
        not missing_log_paths
        and not unexpected_log_paths
        and all(
            success_markers_by_log.get(path, 0) == 1
            for path in expected_log_paths
        )
    )
    clean = (
        malformed_matches == 0
        and all(value == 0 for value in structural_failures.values())
        and max_actions_exhausted == 0
        and non_game_over == 0
        and not native_failure_lines
        and not runtime_error_lines
    )
    exact = (
        not malformed_comparisons
        and not unexpected_rows
        and len(expected_rows) == max(0, expected_golden_differences)
    )
    passed = coverage_satisfied and shard_logs_complete and clean and exact
    return {
        "schema": "ptcg_native_full_controller_compare_gate/1",
        "passed": passed,
        "exact": exact,
        "clean": clean,
        "coverage_satisfied": coverage_satisfied,
        "shard_logs_complete": shard_logs_complete,
        "games": len(matches),
        "minimum_games": max(0, minimum_games),
        "shards": len(shards),
        "stdout_logs": len(log_paths),
        "success_markers": success_markers,
        "missing_shard_logs": [str(path) for path in missing_log_paths[:5]],
        "unexpected_shard_logs": [
            str(path) for path in unexpected_log_paths[:5]],
        "totals": totals,
        "structural_failures": structural_failures,
        "malformed_matches": malformed_matches,
        "max_actions_exhausted": max_actions_exhausted,
        "non_game_over": non_game_over,
        "comparison_difference_count": len(comparison_rows),
        "expected_golden_difference_count": len(expected_rows),
        "required_expected_golden_differences": max(
            0, expected_golden_differences),
        "unexpected_difference_count": len(unexpected_rows),
        "unexpected_differences": unexpected_rows[:5],
        "malformed_comparison_count": len(malformed_comparisons),
        "malformed_comparisons": malformed_comparisons[:5],
        "native_failure_line_count": len(native_failure_lines),
        "native_failure_lines": native_failure_lines[:5],
        "runtime_error_line_count": len(runtime_error_lines),
        "runtime_error_lines": runtime_error_lines[:5],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--log-root", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--minimum-games", type=int, default=560)
    # The Action v4 boundary now rejects the historical malformed `golden-ko`
    # request identically on both paths. Exact production validation therefore
    # requires zero differences unless a targeted legacy fixture opts in.
    parser.add_argument("--expected-golden-differences", type=int, default=0)
    args = parser.parse_args()
    try:
        result = verify(
            _read_json(args.results),
            args.log_root,
            args.minimum_games,
            args.expected_golden_differences,
        )
    except (OSError, TypeError, ValueError) as error:
        result = {
            "schema": "ptcg_native_full_controller_compare_gate/1",
            "passed": False,
            "error": str(error),
        }
        exit_code = 2
    else:
        exit_code = 0 if bool(result["passed"]) else 1
    encoded = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

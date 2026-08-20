"""Fail closed until the Native ABI 2 default-switch evidence is complete."""
from __future__ import annotations

import argparse
from datetime import date
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_EVIDENCE = REPO_ROOT / "contracts" / "native_rules_migration_evidence.json"


def _iso_date(value: Any) -> date | None:
    try:
        return date.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


def cutover_errors(payload: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if int(payload.get("native_abi_version", 0)) != 2:
        errors.append("native_abi_version")
    for name, status in dict(payload.get("builds") or {}).items():
        if status != "passed":
            errors.append(f"build:{name}")
    tests = dict(payload.get("tests") or {})
    for name in (
        "dependency_free_cpp",
        "fast_gate",
        "godot_contracts",
        "lan_regression",
        "relay_regression",
        "standard_gate",
    ):
        if tests.get(name) != "passed":
            errors.append(f"test:{name}")
    performance = dict(payload.get("performance") or {})
    if float(performance.get("native_throughput_retained_ratio", 0.0)) < float(
        performance.get("retained_ratio_gate", 0.95)
    ):
        errors.append("performance:retained_ratio")
    if float(performance.get("native_vs_python_speedup", 0.0)) < float(
        performance.get("speedup_gate", 10.0)
    ):
        errors.append("performance:native_vs_python")

    deletion = dict(payload.get("deletion_gate") or {})
    candidates_gate = dict(deletion.get("two_release_candidates") or {})
    candidates = list(candidates_gate.get("candidates") or [])
    required_candidates = int(candidates_gate.get("required", 2))
    valid_candidate_ids: list[str] = []
    for candidate in candidates:
        row = dict(candidate or {})
        candidate_id = str(row.get("id", ""))
        valid = (
            bool(candidate_id)
            and _iso_date(row.get("built_on")) is not None
            and int(row.get("differential_mismatches", -1)) == 0
            and row.get("standard_gate") == "passed"
            and row.get("windows_build") == "passed"
            and row.get("android_build") == "passed"
        )
        if not valid:
            errors.append(f"release_candidate:{candidate_id or 'unnamed'}")
        elif candidate_id in valid_candidate_ids:
            errors.append(f"release_candidate:duplicate:{candidate_id}")
        else:
            valid_candidate_ids.append(candidate_id)
    if (
        candidates_gate.get("status") != "passed"
        or len(valid_candidate_ids) < required_candidates
    ):
        errors.append("release_candidates:incomplete")

    internal = dict(deletion.get("fourteen_day_internal_run") or {})
    started = _iso_date(internal.get("started_on"))
    completed = _iso_date(internal.get("completed_on"))
    required_days = int(internal.get("required_days", 14))
    observed_ids = {str(value) for value in internal.get("candidate_ids", [])}
    internal_waived = (
        internal.get("status") == "waived"
        and internal.get("waived_by_user") is True
        and _iso_date(internal.get("waived_on")) is not None
    )
    if not internal_waived:
        if (
            internal.get("status") != "passed"
            or started is None
            or completed is None
            or (completed - started).days < required_days
            or int(internal.get("differential_mismatches", -1)) != 0
            or not set(valid_candidate_ids).issubset(observed_ids)
        ):
            errors.append("internal_run:incomplete")
    return sorted(set(errors))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    payload = json.loads(args.evidence.read_text(encoding="utf-8"))
    errors = cutover_errors(payload)
    if errors:
        raise SystemExit("NATIVE_RULES_CUTOVER_BLOCKED\n" + "\n".join(errors))
    print("NATIVE_RULES_CUTOVER_READY")


if __name__ == "__main__":
    main()

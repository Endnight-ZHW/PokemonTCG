#!/usr/bin/env python
"""Merge independent native action-audit shards without weakening gates."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from collections import Counter
from pathlib import Path
from typing import Any


SCHEMA = "native_action_transition_v2_audit/3"
SCOPE = "python_cpp_action_choice_event_roots"
ADDITIVE_FIELDS = (
    "requested_games",
    "completed_games",
    "decision_limit_trajectories",
    "action_states",
    "transitions",
    "pending_transitions",
    "formal_choice_states",
    "legality_mismatches",
    "apply_mismatches",
    "state_mismatches",
    "rng_mismatches",
    "pending_shape_mismatches",
    "choice_transitions",
    "choice_apply_mismatches",
    "choice_state_mismatches",
    "choice_rng_mismatches",
    "choice_pending_shape_mismatches",
    "choice_mapping_errors",
    "choice_depth_exhaustions",
    "trajectory_errors",
    "event_payload_transitions",
    "action_event_payload_mismatches",
    "choice_event_payload_mismatches",
    "event_payload_mismatches",
)
COUNTER_FIELDS = (
    "states_by_deck",
    "actions_by_kind",
    "request_type_pairs",
    "formal_event_types",
    "native_event_types",
    "native_canonical_event_types",
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict):
        raise ValueError(f"audit_not_object:{path}")
    if payload.get("schema") != SCHEMA:
        raise ValueError(f"audit_schema_mismatch:{path}")
    if payload.get("scope") != SCOPE:
        raise ValueError(f"audit_scope_mismatch:{path}")
    return payload


def merge(
    paths: list[Path],
    *,
    detail_limit: int = 100,
) -> dict[str, Any]:
    if not paths:
        raise ValueError("audit_shards_missing")
    resolved_paths = [path.resolve() for path in paths]
    if len(set(resolved_paths)) != len(resolved_paths):
        raise ValueError("audit_shard_path_duplicate")
    reports = [_load(path) for path in paths]
    seeds = [int(report.get("seed", 0)) for report in reports]
    if len(set(seeds)) != len(seeds):
        raise ValueError("audit_shard_seed_duplicate")
    max_decisions = int(reports[0].get("max_decisions", 0))
    if max_decisions <= 0:
        raise ValueError("audit_max_decisions_invalid")
    if any(
        int(report.get("max_decisions", 0)) != max_decisions
        for report in reports
    ):
        raise ValueError("audit_max_decisions_mismatch")

    merged: dict[str, Any] = {
        "schema": SCHEMA,
        "scope": SCOPE,
        "seed": int(reports[0].get("seed", 0)),
        "audit_shards": [
            {
                "path": str(path),
                "sha256": _sha256(path),
                "seed": int(report.get("seed", 0)),
                "requested_games": int(
                    report.get("requested_games", 0)
                ),
            }
            for path, report in zip(paths, reports, strict=True)
        ],
        "max_decisions": max_decisions,
    }
    for field in ADDITIVE_FIELDS:
        merged[field] = sum(
            int(report.get(field, 0))
            for report in reports
        )
    for field in COUNTER_FIELDS:
        counter: Counter[str] = Counter()
        for report in reports:
            counter.update(
                {
                    str(key): int(value)
                    for key, value in dict(
                        report.get(field) or {}
                    ).items()
                }
            )
        merged[field] = dict(sorted(counter.items()))

    action_scope_passed = all(
        report.get("action_scope_passed") is True
        for report in reports
    )
    choice_scope_passed = all(
        report.get("choice_scope_passed") is True
        for report in reports
    )
    event_contract_passed = all(
        report.get("event_contract_status") == "passed"
        for report in reports
    )
    merged.update(
        {
            "event_contract_status": (
                "passed" if event_contract_passed else "failed"
            ),
            "choice_continuation_status": (
                "passed" if choice_scope_passed else "failed"
            ),
            "godot_replay_status": "not_in_action_root_scope",
            "action_scope_passed": action_scope_passed,
            "choice_scope_passed": choice_scope_passed,
            "scope_passed": (
                action_scope_passed
                and choice_scope_passed
                and event_contract_passed
            ),
            "release_gate_complete": False,
        }
    )
    details: list[dict[str, Any]] = []
    for path, report in zip(paths, reports, strict=True):
        for row in report.get("details") or ():
            if len(details) >= detail_limit:
                break
            details.append(
                {
                    "audit_shard": str(path),
                    **dict(row),
                }
            )
    merged["details"] = details
    return merged


def _write_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--detail-limit", type=int, default=100)
    args = parser.parse_args()
    if args.detail_limit < 0:
        parser.error("detail-limit must be non-negative")
    payload = merge(
        args.inputs,
        detail_limit=args.detail_limit,
    )
    _write_atomic(args.output, payload)
    print(
        json.dumps(
            {
                "schema": payload["schema"],
                "shards": len(payload["audit_shards"]),
                "requested_games": payload["requested_games"],
                "action_states": payload["action_states"],
                "scope_passed": payload["scope_passed"],
                "output": str(args.output),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if payload["scope_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python
"""Seal release-scale native audits with independently executed Godot proof."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any, Mapping


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.v2_contract import RELEASE_DECKS  # noqa: E402


RULE_ZERO_FIELDS = (
    "legality_mismatches",
    "apply_mismatches",
    "state_mismatches",
    "rng_mismatches",
    "pending_shape_mismatches",
    "choice_apply_mismatches",
    "choice_state_mismatches",
    "choice_rng_mismatches",
    "choice_pending_shape_mismatches",
    "choice_mapping_errors",
    "choice_depth_exhaustions",
    "event_payload_mismatches",
    "trajectory_errors",
)
INFOSET_ZERO_FIELDS = (
    "unmasked_rejection_missing",
    "masked_boundary_errors",
    "masked_placeholder_errors",
    "mask_mismatches",
    "observation_mismatches",
    "hash_mismatches",
    "determinization_mismatches",
    "candidate_mismatches",
    "tensor_mismatches",
    "choice_reference_errors",
    "inventory_mismatches",
    "trajectory_errors",
)
GODOT_HASH_PATHS = {
    "debug_gdextension_sha256": (
        "godot/bin/windows/"
        "libpokemon_ai.windows.template_debug.x86_64.dll"
    ),
    "release_gdextension_sha256": (
        "godot/bin/windows/"
        "libpokemon_ai.windows.template_release.x86_64.dll"
    ),
    "vm_golden_sha256": (
        "godot/tests/fixtures/vm_native_golden.json"
    ),
    "rules_golden_sha256": (
        "godot/tests/fixtures/rules_golden.json"
    ),
    "native_search_source_sha256": (
        "godot/native/onnx_ai/src/ptcg_search.cpp"
    ),
    "native_game_source_sha256": (
        "godot/native/ptcg_core/src/ptcg_game.cpp"
    ),
}
REQUIRED_GODOT_CONTRACTS = {
    "80-op Python/Godot native VM semantic golden",
    "23-case C++ native game action semantic golden",
    "Native ABI 2 stateful rules session, privacy, rollback, Snapshot and journal contract",
    "Native/Godot stable action signature contract",
    "Native information-set privacy and tree-key contract",
    "Native ONNX action/choice search and deadline contract",
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict):
        raise ValueError(f"evidence_not_object:{path}")
    return payload


def _require(condition: bool, code: str) -> None:
    if not condition:
        raise ValueError(code)


def _validate_coverage(
    payload: Mapping[str, Any],
    *,
    minimum: int,
    prefix: str,
) -> None:
    rows = dict(payload.get("states_by_deck") or {})
    _require(
        set(rows) == set(RELEASE_DECKS),
        f"{prefix}_deck_set_mismatch",
    )
    for deck in RELEASE_DECKS:
        _require(
            int(rows.get(deck, 0)) >= minimum,
            f"{prefix}_deck_coverage_below_{minimum}:{deck}",
        )


def _validate_zero_fields(
    payload: Mapping[str, Any],
    fields: tuple[str, ...],
    *,
    prefix: str,
) -> None:
    for field in fields:
        _require(
            int(payload.get(field, -1)) == 0,
            f"{prefix}_{field}_nonzero",
        )


def _validate_godot(
    payload: Mapping[str, Any],
    *,
    repo_root: Path,
) -> None:
    _require(
        payload.get("schema")
        == "alphazero_v2_godot_native_evidence/1",
        "godot_evidence_schema_mismatch",
    )
    for field in (
        "all_contracts_passed",
        "production_ready",
        "compact_apply_undo_gate_complete",
        "native_effect_legality_gate_complete",
    ):
        _require(payload.get(field) is True, f"godot_{field}_failed")
    _require(
        payload.get("rules_replay_status") == "passed",
        "godot_rules_replay_failed",
    )
    _require(
        payload.get("infoset_runtime_status") == "passed",
        "godot_infoset_runtime_failed",
    )
    _require(
        int(payload.get("vm_golden_cases", 0)) == 80,
        "godot_vm_golden_count_mismatch",
    )
    _require(
        int(payload.get("rule_action_golden_cases", 0)) == 23,
        "godot_rule_golden_count_mismatch",
    )
    contracts = set(payload.get("contracts") or ())
    _require(
        REQUIRED_GODOT_CONTRACTS <= contracts,
        "godot_required_contract_missing",
    )
    hashes = dict(payload.get("hashes") or {})
    _require(
        set(hashes) == set(GODOT_HASH_PATHS),
        "godot_hash_set_mismatch",
    )
    for field, relative in GODOT_HASH_PATHS.items():
        target = repo_root / relative
        _require(target.is_file(), f"godot_hashed_file_missing:{relative}")
        _require(
            str(hashes.get(field, "")).lower() == _sha256(target),
            f"godot_hash_mismatch:{field}",
        )


def seal(
    *,
    rules_path: Path,
    infoset_path: Path,
    godot_path: Path,
    rules_output: Path,
    infoset_output: Path,
    repo_root: Path = REPO_ROOT,
    minimum_states_per_deck: int = 10_000,
) -> dict[str, Any]:
    rules = _load(rules_path)
    infoset = _load(infoset_path)
    godot = _load(godot_path)
    _validate_godot(godot, repo_root=repo_root)

    _require(
        rules.get("schema") == "native_action_transition_v2_audit/3",
        "rules_schema_mismatch",
    )
    _require(rules.get("scope_passed") is True, "rules_scope_failed")
    _require(
        rules.get("event_contract_status") == "passed",
        "rules_event_contract_failed",
    )
    _validate_coverage(
        rules,
        minimum=minimum_states_per_deck,
        prefix="rules",
    )
    _validate_zero_fields(rules, RULE_ZERO_FIELDS, prefix="rules")

    _require(
        infoset.get("schema")
        == "native_infoset_security_v2_audit/1",
        "infoset_schema_mismatch",
    )
    _require(
        infoset.get("scope_passed") is True,
        "infoset_scope_failed",
    )
    _validate_coverage(
        infoset,
        minimum=minimum_states_per_deck,
        prefix="infoset",
    )
    _validate_zero_fields(
        infoset,
        INFOSET_ZERO_FIELDS,
        prefix="infoset",
    )

    godot_binding = {
        "schema": godot["schema"],
        "sha256": _sha256(godot_path),
        "godot_version": godot["godot_version"],
        "vm_golden_cases": godot["vm_golden_cases"],
        "rule_action_golden_cases": godot[
            "rule_action_golden_cases"
        ],
        "hashes": godot["hashes"],
    }
    sealed_rules = {
        **rules,
        "godot_replay_status": "passed",
        "godot_evidence": godot_binding,
        "minimum_states_per_deck": minimum_states_per_deck,
        "release_gate_complete": True,
    }
    sealed_infoset = {
        **infoset,
        "godot_runtime_status": "passed",
        "godot_evidence": godot_binding,
        "minimum_states_per_deck": minimum_states_per_deck,
        "release_gate_complete": True,
    }
    _write_atomic(rules_output, sealed_rules)
    _write_atomic(infoset_output, sealed_infoset)
    return {
        "rules_output": str(rules_output),
        "rules_sha256": _sha256(rules_output),
        "infoset_output": str(infoset_output),
        "infoset_sha256": _sha256(infoset_output),
        "godot_evidence": str(godot_path),
        "godot_evidence_sha256": _sha256(godot_path),
        "minimum_states_per_deck": minimum_states_per_deck,
        "release_gate_complete": True,
    }


def _write_atomic(path: Path, payload: Mapping[str, Any]) -> None:
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
    parser.add_argument("--rules", type=Path, required=True)
    parser.add_argument("--infoset", type=Path, required=True)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--rules-output", type=Path, required=True)
    parser.add_argument("--infoset-output", type=Path, required=True)
    parser.add_argument(
        "--minimum-states-per-deck",
        type=int,
        default=10_000,
    )
    args = parser.parse_args()
    if args.minimum_states_per_deck <= 0:
        parser.error("minimum-states-per-deck must be positive")
    summary = seal(
        rules_path=args.rules,
        infoset_path=args.infoset,
        godot_path=args.godot,
        rules_output=args.rules_output,
        infoset_output=args.infoset_output,
        minimum_states_per_deck=args.minimum_states_per_deck,
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

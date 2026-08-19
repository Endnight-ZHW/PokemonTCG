"""Fail-closed AlphaZero v2 release-evidence aggregation.

Native code reports only technical kernel readiness.  This module owns the
external rule-parity, information-security, performance, device and strength
evidence that a native library cannot discover by itself.
"""
from __future__ import annotations

import hashlib
import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .run_store import atomic_write_json, read_json, update_run
from .v2_contract import RELEASE_DECKS, TRAINER_ID, contract_dict


EVIDENCE_SCHEMA = "alphazero_v2_release_evidence/2"
INPUT_DIRECTORY = Path("evidence") / "release_inputs"
FINAL_EVIDENCE_NAME = "release-evidence.final.json"
REQUIRED_INPUTS = (
    "rules_parity",
    "infoset_security",
    "performance",
    "windows_runtime",
    "android_runtime",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def native_technical_status() -> dict[str, Any]:
    try:
        import ptcg_ai_core  # type: ignore

        return {
            "available": True,
            "abi_version": int(ptcg_ai_core.abi_version()),
            "ready": bool(ptcg_ai_core.production_ready()),
            "blockers": [
                str(value)
                for value in ptcg_ai_core.production_blockers()
            ],
        }
    except Exception as exc:
        return {
            "available": False,
            "abi_version": 0,
            "ready": False,
            "blockers": [
                f"native_module_unavailable:{type(exc).__name__}"
            ],
        }


@dataclass
class _Gate:
    checks: dict[str, bool]
    blockers: list[str]

    def check(self, name: str, passed: Any) -> None:
        value = bool(passed)
        self.checks[name] = value
        if not value:
            self.blockers.append(name)


def _zero_fields(
    gate: _Gate,
    prefix: str,
    payload: Mapping[str, Any],
    fields: tuple[str, ...],
) -> None:
    for field in fields:
        gate.check(
            f"{prefix}.{field}_zero",
            int(payload.get(field, -1)) == 0,
        )


def _deck_coverage(
    gate: _Gate,
    prefix: str,
    payload: Mapping[str, Any],
    minimum: int,
) -> None:
    rows = dict(payload.get("states_by_deck") or {})
    gate.check(
        f"{prefix}.deck_set",
        set(rows) == set(RELEASE_DECKS),
    )
    for deck in RELEASE_DECKS:
        gate.check(
            f"{prefix}.deck_{deck}_coverage",
            int(rows.get(deck, 0)) >= minimum,
        )


def _validate_rules(
    gate: _Gate,
    payload: Mapping[str, Any],
) -> None:
    prefix = "rules_parity"
    gate.check(
        f"{prefix}.schema",
        payload.get("schema") == "native_action_transition_v2_audit/3",
    )
    gate.check(f"{prefix}.scope", payload.get("scope_passed") is True)
    gate.check(
        f"{prefix}.event_contract",
        payload.get("event_contract_status") == "passed",
    )
    gate.check(
        f"{prefix}.godot_replay",
        payload.get("godot_replay_status") == "passed",
    )
    gate.check(
        f"{prefix}.release_scale",
        payload.get("release_gate_complete") is True,
    )
    _deck_coverage(gate, prefix, payload, 10_000)
    _zero_fields(
        gate,
        prefix,
        payload,
        (
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
        ),
    )


def _validate_infoset(
    gate: _Gate,
    payload: Mapping[str, Any],
) -> None:
    prefix = "infoset_security"
    gate.check(
        f"{prefix}.schema",
        payload.get("schema") == "native_infoset_security_v2_audit/1",
    )
    gate.check(f"{prefix}.scope", payload.get("scope_passed") is True)
    gate.check(
        f"{prefix}.godot_runtime",
        payload.get("godot_runtime_status") == "passed",
    )
    gate.check(
        f"{prefix}.release_scale",
        payload.get("release_gate_complete") is True,
    )
    _deck_coverage(gate, prefix, payload, 10_000)
    _zero_fields(
        gate,
        prefix,
        payload,
        (
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
        ),
    )


def _validate_performance(
    gate: _Gate,
    payload: Mapping[str, Any],
) -> None:
    prefix = "performance"
    gate.check(
        f"{prefix}.schema",
        payload.get("schema")
        == "native_vs_python_infoset_puct_benchmark/1",
    )
    gate.check(
        f"{prefix}.same_work",
        payload.get("same_seed_and_simulation_count") is True,
    )
    gate.check(
        f"{prefix}.speedup",
        float(payload.get("throughput_speedup", 0.0)) >= 10.0,
    )


def _validate_windows(
    gate: _Gate,
    payload: Mapping[str, Any],
) -> None:
    prefix = "windows_runtime"
    gate.check(
        f"{prefix}.kind",
        payload.get("kind") == "candidate_runtime_inference_v2",
    )
    gate.check(f"{prefix}.passed", payload.get("passed") is True)
    gate.check(
        f"{prefix}.platform",
        str(payload.get("platform", "")).lower() == "windows",
    )
    gate.check(
        f"{prefix}.native_extension",
        payload.get("native_extension") is True,
    )
    gate.check(
        f"{prefix}.encoder",
        payload.get("encoder_golden_passed") is True,
    )
    gate.check(f"{prefix}.model_count", int(payload.get("model_count", 0)) == 1)
    gate.check(
        f"{prefix}.route_count",
        int(payload.get("route_count", 0)) == len(RELEASE_DECKS),
    )
    rows = dict(payload.get("models") or {})
    gate.check(f"{prefix}.deck_set", set(rows) == set(RELEASE_DECKS))
    for deck in RELEASE_DECKS:
        row = dict(rows.get(deck) or {})
        scenarios = list(row.get("scenarios") or ())
        gate.check(f"{prefix}.{deck}.loaded", row.get("loaded") is True)
        gate.check(
            f"{prefix}.{deck}.hash",
            row.get("hash_matches") is True,
        )
        gate.check(
            f"{prefix}.{deck}.inference",
            len(scenarios) >= 2
            and all(
                isinstance(scenario, dict)
                and scenario.get("passed") is True
                and scenario.get("execution_provider")
                == "CPUExecutionProvider"
                for scenario in scenarios
            ),
        )
    gate.check(
        f"{prefix}.deadline",
        payload.get("search_deadline_passed") is True,
    )
    gate.check(
        f"{prefix}.minimum_simulations",
        payload.get("minimum_simulations_passed") is True,
    )
    gate.check(
        f"{prefix}.fallback_path",
        payload.get("fallback_path_passed") is True,
    )
    _zero_fields(
        gate,
        prefix,
        payload,
        ("illegal_actions", "timeouts", "degraded", "fallbacks"),
    )


def _validate_android(
    gate: _Gate,
    payload: Mapping[str, Any],
) -> None:
    prefix = "android_runtime"
    gate.check(
        f"{prefix}.schema",
        payload.get("schema") == "alphazero_v2_android_runtime/1",
    )
    gate.check(f"{prefix}.passed", payload.get("passed") is True)
    gate.check(
        f"{prefix}.physical_device",
        payload.get("physical_device") is True,
    )
    gate.check(
        f"{prefix}.abi",
        payload.get("abi") == "arm64-v8a",
    )
    gate.check(
        f"{prefix}.native_bridge",
        payload.get("native_bridge") in (False, "", "0", 0, None),
    )
    gate.check(f"{prefix}.model_count", int(payload.get("model_count", 0)) == 1)
    for field in (
        "onnx_load_passed",
        "inference_passed",
        "search_deadline_passed",
        "minimum_simulations_passed",
        "fallback_path_passed",
    ):
        gate.check(f"{prefix}.{field}", payload.get(field) is True)
    _zero_fields(
        gate,
        prefix,
        payload,
        (
            "illegal_actions",
            "timeouts",
            "degraded",
            "fallbacks",
            "crashes",
        ),
    )


def _validate_training(
    gate: _Gate,
    payload: Mapping[str, Any],
) -> None:
    prefix = "training"
    gate.check(
        f"{prefix}.schema",
        payload.get("schema") == "alphazero_v2_training_evidence/1",
    )
    gate.check(f"{prefix}.trainer", payload.get("trainer") == TRAINER_ID)
    gate.check(f"{prefix}.accepted", payload.get("accepted") is True)
    gate.check(
        f"{prefix}.native_required",
        payload.get("native_core_required") is True,
    )
    gate.check(
        f"{prefix}.native_available",
        payload.get("native_core_available") is True,
    )
    elapsed = float(payload.get("elapsed_seconds", float("inf")))
    budget = float(payload.get("wall_clock_budget_seconds", 0.0))
    gate.check(
        f"{prefix}.wall_clock",
        0.0 < elapsed <= budget <= 24.0 * 60.0 * 60.0,
    )
    final = dict(payload.get("final_league") or {})
    gate.check(f"{prefix}.league_games", int(final.get("games", 0)) == 6_000)
    gate.check(
        f"{prefix}.overall_score",
        float(final.get("overall_score_rate", 0.0)) >= 0.53,
    )
    rates = dict(final.get("deck_score_rates") or {})
    gate.check(f"{prefix}.deck_set", set(rates) == set(RELEASE_DECKS))
    for deck in RELEASE_DECKS:
        gate.check(
            f"{prefix}.{deck}_score",
            float(rates.get(deck, 0.0)) >= 0.50,
        )
    _zero_fields(
        gate,
        prefix,
        final,
        ("structural_errors", "truncated_games"),
    )
    native = dict(final.get("native_inference") or {})
    gate.check(
        f"{prefix}.native_search_used",
        int(native.get("search_decisions", 0)) > 0
        and int(native.get("search_simulations", 0)) > 0,
    )


_VALIDATORS = {
    "rules_parity": _validate_rules,
    "infoset_security": _validate_infoset,
    "performance": _validate_performance,
    "windows_runtime": _validate_windows,
    "android_runtime": _validate_android,
    "training": _validate_training,
}


def _resolved_under(root: Path, relative: str) -> Path:
    root = root.resolve()
    target = (root / relative).resolve()
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"evidence_path_outside_run:{relative}") from exc
    return target


def evaluate_release_evidence(
    evidence: Mapping[str, Any],
    *,
    run_dir: Path,
    native_status: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    gate = _Gate({}, [])
    gate.check("evidence.schema", evidence.get("schema") == EVIDENCE_SCHEMA)
    gate.check(
        "evidence.contract",
        dict(evidence.get("contract") or {}) == contract_dict(),
    )
    inputs = dict(evidence.get("inputs") or {})
    gate.check(
        "evidence.input_set",
        set(inputs) == set((*REQUIRED_INPUTS, "training")),
    )
    for name in (*REQUIRED_INPUTS, "training"):
        row = dict(inputs.get(name) or {})
        relative = str(row.get("path", ""))
        expected_hash = str(row.get("sha256", "")).lower()
        try:
            path = _resolved_under(run_dir, relative)
            exists = path.is_file()
            actual_hash = sha256_file(path) if exists else ""
            payload = read_json(path) if exists else {}
        except Exception:
            exists = False
            actual_hash = ""
            payload = {}
        gate.check(f"{name}.file", exists)
        gate.check(
            f"{name}.sha256",
            len(expected_hash) == 64 and actual_hash == expected_hash,
        )
        validator = _VALIDATORS[name]
        validator(gate, payload)

    status = dict(native_status or native_technical_status())
    gate.check("native.available", status.get("available") is True)
    gate.check("native.abi", int(status.get("abi_version", 0)) == 1)
    gate.check("native.ready", status.get("ready") is True)
    gate.check("native.blockers", not list(status.get("blockers") or ()))

    model = dict(evidence.get("model") or {})
    for name, relative in (
        ("checkpoint", "universal.pt"),
        ("sidecar", "universal.json"),
        (
            "onnx",
            "release_staging/godot/data/ai_models/universal.onnx",
        ),
    ):
        path = _resolved_under(run_dir, relative)
        expected = str(model.get(f"{name}_sha256", "")).lower()
        gate.check(f"model.{name}_file", path.is_file())
        gate.check(
            f"model.{name}_sha256",
            path.is_file()
            and len(expected) == 64
            and sha256_file(path) == expected,
        )
    return {
        "passed": not gate.blockers,
        "checks": gate.checks,
        "blockers": gate.blockers,
        "native_technical_status": status,
    }


def _copy_input(source: Path, target: Path) -> None:
    source = source.resolve()
    target = target.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    if source == target:
        return
    shutil.copy2(source, target)


def build_release_evidence(
    run_dir: Path,
    *,
    inputs: Mapping[str, Path],
    native_status: Mapping[str, Any] | None = None,
) -> tuple[Path, dict[str, Any], str]:
    run_dir = run_dir.resolve()
    training = run_dir / "release-evidence.json"
    if not training.is_file():
        raise FileNotFoundError(training)
    missing = set(REQUIRED_INPUTS) - set(inputs)
    extra = set(inputs) - set(REQUIRED_INPUTS)
    if missing or extra:
        raise ValueError(
            f"release_evidence_input_set:missing={sorted(missing)}:"
            f"extra={sorted(extra)}"
        )
    copied: dict[str, dict[str, str]] = {}
    for name in REQUIRED_INPUTS:
        source = Path(inputs[name])
        if not source.is_file():
            raise FileNotFoundError(source)
        relative = INPUT_DIRECTORY / f"{name}.json"
        target = run_dir / relative
        _copy_input(source, target)
        copied[name] = {
            "path": relative.as_posix(),
            "sha256": sha256_file(target),
        }
    training_relative = INPUT_DIRECTORY / "training.json"
    training_target = run_dir / training_relative
    _copy_input(training, training_target)
    copied["training"] = {
        "path": training_relative.as_posix(),
        "sha256": sha256_file(training_target),
    }

    checkpoint = run_dir / "universal.pt"
    sidecar = run_dir / "universal.json"
    onnx = (
        run_dir
        / "release_staging"
        / "godot"
        / "data"
        / "ai_models"
        / "universal.onnx"
    )
    for path in (checkpoint, sidecar, onnx):
        if not path.is_file():
            raise FileNotFoundError(path)
    evidence: dict[str, Any] = {
        "schema": EVIDENCE_SCHEMA,
        "format_version": 2,
        "contract": contract_dict(),
        "inputs": copied,
        "model": {
            "checkpoint_sha256": sha256_file(checkpoint),
            "sidecar_sha256": sha256_file(sidecar),
            "onnx_sha256": sha256_file(onnx),
        },
    }
    result = evaluate_release_evidence(
        evidence,
        run_dir=run_dir,
        native_status=native_status,
    )
    evidence["gate"] = result
    output = run_dir / FINAL_EVIDENCE_NAME
    atomic_write_json(output, evidence)
    evidence_hash = sha256_file(output)
    return output, result, evidence_hash


def finalize_release_evidence(
    run_dir: Path,
    *,
    inputs: Mapping[str, Path],
    native_status: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    output, gate, evidence_hash = build_release_evidence(
        run_dir,
        inputs=inputs,
        native_status=native_status,
    )
    run_json = run_dir / "run.json"
    if not gate["passed"]:
        if run_json.is_file():
            update_run(
                run_dir,
                promotable=False,
                gate={
                    "status": "rejected",
                    "evidence_path": output.name,
                    "evidence_sha256": evidence_hash,
                    "blockers": gate["blockers"],
                },
            )
        return {
            "passed": False,
            "evidence_path": str(output),
            "evidence_sha256": evidence_hash,
            "blockers": gate["blockers"],
        }

    runtime_path = (
        run_dir
        / "release_staging"
        / "godot"
        / "data"
        / "ai_models_runtime.json"
    )
    release_path = (
        run_dir
        / "release_staging"
        / "godot"
        / "data"
        / "release_manifest.json"
    )
    runtime = read_json(runtime_path)
    release = read_json(release_path)
    runtime["deep_planner"]["evidence_sha256"] = evidence_hash
    release["deep_planner"]["evidence_sha256"] = evidence_hash
    release["deep_runtime_enabled"] = True
    release["model_count"] = 1
    release["native_ai"]["production_ready"] = True
    release["deep_model"]["status"] = "candidate"
    atomic_write_json(runtime_path, runtime)
    atomic_write_json(release_path, release)
    if run_json.is_file():
        update_run(
            run_dir,
            promotable=True,
            gate={
                "status": "passed",
                "evidence_path": output.name,
                "evidence_sha256": evidence_hash,
                "blockers": [],
            },
        )
    return {
        "passed": True,
        "evidence_path": str(output),
        "evidence_sha256": evidence_hash,
        "blockers": [],
    }


def validate_release_evidence_file(
    path: Path,
    *,
    run_dir: Path,
    native_status: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    evidence = read_json(path)
    recorded = dict(evidence.get("gate") or {})
    evaluated = evaluate_release_evidence(
        evidence,
        run_dir=run_dir,
        native_status=native_status,
    )
    if (
        recorded.get("passed") is not evaluated["passed"]
        or dict(recorded.get("checks") or {}) != evaluated["checks"]
        or list(recorded.get("blockers") or ()) != evaluated["blockers"]
    ):
        return {
            **evaluated,
            "passed": False,
            "blockers": [
                *evaluated["blockers"],
                "evidence.recorded_gate_mismatch",
            ],
        }
    return evaluated


__all__ = [
    "EVIDENCE_SCHEMA",
    "FINAL_EVIDENCE_NAME",
    "REQUIRED_INPUTS",
    "build_release_evidence",
    "evaluate_release_evidence",
    "finalize_release_evidence",
    "native_technical_status",
    "sha256_file",
    "validate_release_evidence_file",
]

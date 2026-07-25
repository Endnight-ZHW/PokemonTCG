"""Seal authoritative Godot/platform evidence for a hybrid Release candidate."""
from __future__ import annotations

import argparse
import copy
import json
import os
import sys
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.model import CHECKPOINT_VERSION, safe_torch_load  # noqa: E402
from engine.ai.dl.production_contract import (  # noqa: E402
    DEEP_PLANNER_SCHEMA_VERSION,
    TRAINER_HYBRID_POPULATION,
    deep_planner_manifest,
)
from engine.ai.dl.run_store import (  # noqa: E402
    _atomic_torch_save,
    atomic_write_json,
    read_json,
    resolve_within,
    sha256_file,
    update_run,
    utc_now,
)
from engine.ai.dl.encoder import (  # noqa: E402
    ACTION_NUMERIC_SIZE,
    CARD_IDENTITY_MODE,
    CARD_SEMANTIC_SIZE,
    CARD_VOCAB_SHA256,
    CARD_VOCAB_SIZE,
    CARD_VOCAB_VERSION,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
)
from engine.ai.planner import PLANNER_SCHEMA_VERSION  # noqa: E402
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION  # noqa: E402
from scripts.export_godot_data import _ai_encoder_fixture  # noqa: E402
from scripts.validate_ai_evaluation import (  # noqa: E402
    validate_evaluation_gate,
)

PARITY_SCENARIOS = {
    "ordinary_1x1",
    "ordinary_3x5",
    "ordinary_17x11",
    "empty_state_slots_1x1",
}
ANDROID_ARCHITECTURES = {"arm64", "arm64-v8a", "aarch64"}


def _checked_file(run_dir: Path, value: str, label: str) -> Path:
    path = resolve_within(run_dir, value)
    if not path.is_file():
        raise RuntimeError(f"{label} is missing: {path}")
    return path


def _candidate_files_valid(
    run_dir: Path,
    candidate: dict[str, Any],
) -> None:
    files = candidate.get("files")
    if not isinstance(files, dict) or not files:
        raise RuntimeError("Candidate artifact ledger is missing")
    for relative, expected_value in files.items():
        expected = dict(expected_value or {})
        path = _checked_file(run_dir, str(relative), "candidate artifact")
        if (
            sha256_file(path) != str(expected.get("sha256", "")).lower()
            or path.stat().st_size != int(expected.get("size", -1))
        ):
            raise RuntimeError(f"Candidate artifact changed: {relative}")


def _python_encoder_golden_valid() -> bool:
    fixture_path = REPO_ROOT / "godot" / "tests" / "fixtures" / "ai_encoder_golden.json"
    fixture = read_json(fixture_path)
    return _ai_encoder_fixture() == fixture


def _runtime_manifest_valid(
    run_dir: Path,
    runtime: dict[str, Any],
    decks: list[str],
) -> dict[str, Any]:
    bridge = dict(runtime.get("compatibility_bridge") or {})
    planner = dict(runtime.get("deep_planner") or {})
    models = runtime.get("models")
    semantic_sizes = dict(runtime.get("semantic_feature_sizes") or {})
    if (
        int(bridge.get("python_rules_version", 0)) != RULES_SCHEMA_VERSION
        or int(bridge.get("python_action_version", 0)) != ACTION_SCHEMA_VERSION
        or int(bridge.get("python_encoder_version", 0))
        != ENCODER_SCHEMA_VERSION
        or int(planner.get("schema_version", 0))
        != DEEP_PLANNER_SCHEMA_VERSION
        or str(planner.get("planner_id", "")) != "deep_root_ismcts_v1"
        or int(runtime.get("state_numeric_size", 0)) != STATE_NUMERIC_SIZE
        or int(runtime.get("state_card_slots", 0)) != STATE_CARD_SLOTS
        or int(runtime.get("action_numeric_size", 0)) != ACTION_NUMERIC_SIZE
        or str(runtime.get("card_identity_mode", ""))
        != CARD_IDENTITY_MODE
        or int(runtime.get("card_vocab_version", 0))
        != CARD_VOCAB_VERSION
        or int(runtime.get("card_vocab_size", 0)) != CARD_VOCAB_SIZE
        or str(runtime.get("card_vocab_sha256", ""))
        != CARD_VOCAB_SHA256
        or int(semantic_sizes.get("known_card", 0))
        != CARD_SEMANTIC_SIZE
        or not isinstance(models, dict)
        or set(models) != set(decks)
    ):
        raise RuntimeError("Candidate runtime schema is incompatible")
    model_configs: list[dict[str, Any]] = []
    checkpoint_versions: set[int] = set()
    encoder_versions: set[int] = set()
    for deck in decks:
        row = dict(models[deck])
        onnx_path = _checked_file(
            run_dir,
            f"staging/godot/data/ai_models/{deck}.onnx",
            f"{deck} ONNX",
        )
        maxima = dict(row.get("parity_max_abs_error") or {})
        performance = dict(
            row.get("performance_32_action_16_choice") or {}
        )
        model_config = dict(row.get("model_config") or {})
        if (
            str(row.get("deck_key", "")) != deck
            or int(row.get("checkpoint_version", 0))
            != CHECKPOINT_VERSION
            or int(row.get("rules_version", 0)) != RULES_SCHEMA_VERSION
            or int(row.get("action_version", 0)) != ACTION_SCHEMA_VERSION
            or int(row.get("encoder_version", 0))
            != ENCODER_SCHEMA_VERSION
            or int(row.get("deep_planner_version", 0))
            != DEEP_PLANNER_SCHEMA_VERSION
            or int(row.get("card_vocab_version", 0))
            != CARD_VOCAB_VERSION
            or int(row.get("card_vocab_size", 0)) != CARD_VOCAB_SIZE
            or str(row.get("card_vocab_sha256", ""))
            != CARD_VOCAB_SHA256
            or int(model_config.get("state_numeric_size", 0))
            != STATE_NUMERIC_SIZE
            or int(model_config.get("state_card_slots", 0))
            != STATE_CARD_SLOTS
            or int(model_config.get("action_numeric_size", 0))
            != ACTION_NUMERIC_SIZE
            or int(model_config.get("card_bucket_count", 0))
            != CARD_VOCAB_SIZE
            or int(model_config.get("card_embed_dim", 0)) != 32
            or int(model_config.get("hidden_size", 0)) != 384
            or int(model_config.get("attention_heads", 0)) != 4
            or int(
                model_config.get(
                    "candidate_cross_attention_heads",
                    0,
                )
            )
            != 4
            or not bool(model_config.get("choice_head_enabled"))
            or not bool(model_config.get("use_attention"))
            or not bool(model_config.get("use_slot_embeddings"))
            or not bool(model_config.get("use_token_type_embeddings"))
            or str(model_config.get("state_norm", "")) != "layer"
            or int(model_config.get("deck_embed_dim", -1)) != 0
            or int(model_config.get("num_decks", 0)) != 10
            or str(model_config.get("card_identity_mode", ""))
            != CARD_IDENTITY_MODE
            or sha256_file(onnx_path)
            != str(row.get("onnx_sha256", "")).lower()
            or int(row.get("onnx_size", -1)) != onnx_path.stat().st_size
            or set(row.get("parity_scenarios") or []) != PARITY_SCENARIOS
            or set(maxima) != {
                "action_logits",
                "state_value",
                "choice_logits",
            }
            or any(float(value) > 1e-4 for value in maxima.values())
            or not bool(performance.get("passed"))
            or float(performance.get("median_ms", float("inf"))) > 0.64
            or float(performance.get("p95_ms", float("inf"))) > 2.0
        ):
            raise RuntimeError(f"{deck} ONNX/schema/parity evidence is invalid")
        model_configs.append(model_config)
        checkpoint_versions.add(int(row.get("checkpoint_version", 0)))
        encoder_versions.add(int(row.get("encoder_version", 0)))
    if (
        not model_configs
        or any(config != model_configs[0] for config in model_configs[1:])
        or checkpoint_versions != {CHECKPOINT_VERSION}
        or encoder_versions != {ENCODER_SCHEMA_VERSION}
    ):
        raise RuntimeError("Candidate model configurations are inconsistent")
    model_config = model_configs[0]
    return {
        "variant": (
            "v6_cross_attention"
            if bool(model_config.get("candidate_cross_attention"))
            else "v6_pooled"
        ),
        "checkpoint_version": CHECKPOINT_VERSION,
        "encoder_version": ENCODER_SCHEMA_VERSION,
        "card_vocab_version": CARD_VOCAB_VERSION,
        "card_vocab_size": CARD_VOCAB_SIZE,
        "card_vocab_sha256": CARD_VOCAB_SHA256,
        "config": model_config,
    }


def _platform_runtime_valid(
    payload: dict[str, Any],
    *,
    platform: str,
    candidate_sha: str,
    runtime: dict[str, Any],
    decks: list[str],
) -> None:
    actual_platform = str(payload.get("platform", "")).lower()
    architecture = str(payload.get("architecture", "")).lower()
    models = payload.get("models")
    if (
        int(payload.get("format_version", 0)) != 1
        or str(payload.get("kind", ""))
        != "candidate_runtime_inference_v1"
        or not bool(payload.get("passed"))
        or not bool(payload.get("native_extension"))
        or not bool(payload.get("encoder_golden_passed"))
        or str(payload.get("candidate_manifest_sha256", "")).lower()
        != candidate_sha
        or actual_platform != platform
        or (
            platform == "android"
            and architecture not in ANDROID_ARCHITECTURES
        )
        or not isinstance(models, dict)
        or set(models) != set(decks)
        or int(payload.get("model_count", -1)) != len(decks)
        or payload.get("errors") not in ([], None)
    ):
        raise RuntimeError(f"{platform} runtime evidence contract is invalid")
    expected_models = dict(runtime["models"])
    for deck in decks:
        row = dict(models[deck])
        expected = dict(expected_models[deck])
        scenarios = row.get("scenarios")
        scenario_names = {
            str(item.get("name", ""))
            for item in scenarios or []
            if isinstance(item, dict) and bool(item.get("passed"))
        }
        if (
            not bool(row.get("loaded"))
            or not bool(row.get("hash_matches"))
            or str(row.get("onnx_sha256", "")).lower()
            != str(expected.get("onnx_sha256", "")).lower()
            or scenario_names != {"ordinary", "empty_slots"}
        ):
            raise RuntimeError(
                f"{platform} did not load and infer {deck} correctly"
            )


def _artifact_rows(run_dir: Path, paths: list[Path]) -> dict[str, Any]:
    return {
        str(path.relative_to(run_dir).as_posix()): {
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
        }
        for path in paths
    }


def _research10_lineage(
    run: dict[str, Any],
) -> tuple[Path, str]:
    row = dict(
        dict(run.get("stage_lineage") or {}).get(
            "research10_gate"
        )
        or {}
    )
    path = Path(str(row.get("path", ""))).resolve()
    expected_sha = str(row.get("sha256", "")).lower()
    if (
        not path.is_file()
        or len(expected_sha) != 64
        or sha256_file(path) != expected_sha
    ):
        raise RuntimeError(
            "Full candidate lacks hash-verified research10 gate lineage"
        )
    evidence = json.loads(path.read_text(encoding="utf-8-sig"))
    evidence_run = dict(evidence.get("run") or {})
    model_variant = str((run.get("config") or {}).get("model_variant", ""))
    if (
        str(evidence.get("schema", ""))
        != "deep_ai_v6_research10_gate_v1"
        or not bool(evidence.get("valid"))
        or bool(evidence.get("promotable"))
        or str(evidence_run.get("model_variant", "")) != model_variant
        or str(row.get("model_variant", "")) != model_variant
    ):
        raise RuntimeError(
            "research10 gate lineage does not authorize this model variant"
        )
    return path, expected_sha


def finalize_evidence(
    run_dir: Path,
    *,
    evaluation_path: Path | None = None,
    windows_runtime_path: Path | None = None,
    android_runtime_path: Path | None = None,
) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    run = read_json(run_dir / "run.json")
    if (
        str(run.get("preset", "")) != "release"
        or not bool(run.get("promotable"))
    ):
        raise RuntimeError("Only a fixed Release run can pass this gate")
    research10_path, research10_sha = _research10_lineage(run)
    candidate_path = _checked_file(
        run_dir, "staging/candidate_manifest.json", "candidate manifest"
    )
    candidate = read_json(candidate_path)
    if (
        str(candidate.get("kind", "")) != "hybrid_candidate_bundle_v1"
        or str(candidate.get("run_id", "")) != str(run.get("run_id", ""))
    ):
        raise RuntimeError("Candidate manifest belongs to another run")
    candidate_sha = sha256_file(candidate_path)
    expected_candidate_sha = str(
        dict(run.get("candidate_stage") or {}).get(
            "manifest_sha256", ""
        )
    ).lower()
    if candidate_sha != expected_candidate_sha:
        raise RuntimeError("Candidate manifest hash no longer matches the run")
    _candidate_files_valid(run_dir, candidate)
    decks = [str(value) for value in candidate.get("release_decks") or []]
    release = read_json(REPO_ROOT / "release_manifest.json")
    if (
        decks != [str(value) for value in release.get("release_decks") or []]
        or len(decks) != int(release.get("model_count", 0))
        or len(decks) != 10
    ):
        raise RuntimeError("Candidate is not the complete ten-deck release set")

    provisional_runtime_path = _checked_file(
        run_dir,
        "staging/godot/data/ai_models_runtime.json",
        "candidate runtime manifest",
    )
    provisional_release_path = _checked_file(
        run_dir,
        "staging/godot/data/release_manifest.json",
        "candidate release manifest",
    )
    provisional_runtime = read_json(provisional_runtime_path)
    deep_model = _runtime_manifest_valid(
        run_dir,
        provisional_runtime,
        decks,
    )
    provisional_release = read_json(provisional_release_path)
    run_variant = str((run.get("config") or {}).get("model_variant", ""))
    if (
        dict(provisional_release.get("deep_model") or {}) != deep_model
        or str(deep_model.get("variant", "")) != run_variant
        or int(
            dict(provisional_release.get("schemas") or {}).get(
                "checkpoint",
                0,
            )
        )
        != CHECKPOINT_VERSION
        or int(
            dict(provisional_release.get("schemas") or {}).get(
                "encoder",
                0,
            )
        )
        != ENCODER_SCHEMA_VERSION
        or int(
            dict(provisional_release.get("schemas") or {}).get(
                "card_vocab",
                0,
            )
        )
        != CARD_VOCAB_VERSION
    ):
        raise RuntimeError(
            "Candidate root/runtime model contracts are inconsistent"
        )

    evaluation_path = (
        evaluation_path.resolve()
        if evaluation_path is not None
        else run_dir / "evaluation" / "godot_windows" / "results.json"
    )
    windows_runtime_path = (
        windows_runtime_path.resolve()
        if windows_runtime_path is not None
        else run_dir / "evaluation" / "windows_runtime.json"
    )
    android_runtime_path = (
        android_runtime_path.resolve()
        if android_runtime_path is not None
        else run_dir / "evaluation" / "android_runtime.json"
    )
    for path, label in (
        (evaluation_path, "Godot evaluation"),
        (windows_runtime_path, "Windows runtime evidence"),
        (android_runtime_path, "Android runtime evidence"),
    ):
        try:
            path.relative_to(run_dir)
        except ValueError as exc:
            raise RuntimeError(f"{label} must be inside the run directory") from exc
        if not path.is_file():
            raise RuntimeError(f"{label} is missing: {path}")

    evaluation = read_json(evaluation_path)
    validation = validate_evaluation_gate(
        evaluation, gate="deep-release", platform="windows"
    )
    validation_path = run_dir / "evaluation" / "deep_release_validation.json"
    atomic_write_json(validation_path, validation)
    if not bool(validation.get("valid")):
        raise RuntimeError(
            "Godot deep-release gate failed: "
            + ",".join(str(value) for value in validation.get("error_codes") or [])
        )
    if not _python_encoder_golden_valid():
        raise RuntimeError("Python encoder no longer matches the golden fixture")

    windows_runtime = read_json(windows_runtime_path)
    android_runtime = read_json(android_runtime_path)
    _platform_runtime_valid(
        windows_runtime,
        platform="windows",
        candidate_sha=candidate_sha,
        runtime=provisional_runtime,
        decks=decks,
    )
    _platform_runtime_valid(
        android_runtime,
        platform="android",
        candidate_sha=candidate_sha,
        runtime=provisional_runtime,
        decks=decks,
    )

    evidence = {
        "format_version": 1,
        "kind": "hybrid_release_evidence_v1",
        "run_id": str(run["run_id"]),
        "created_at": utc_now(),
        "gate": "deep-release",
        "candidate_manifest_sha256": candidate_sha,
        "inputs": {
            "research10_gate_path": str(research10_path),
            "research10_gate_sha256": research10_sha,
            "candidate_runtime_manifest_sha256": sha256_file(
                provisional_runtime_path
            ),
            "candidate_release_manifest_sha256": sha256_file(
                provisional_release_path
            ),
            "godot_evaluation_sha256": sha256_file(evaluation_path),
            "godot_validation_sha256": sha256_file(validation_path),
            "windows_runtime_sha256": sha256_file(windows_runtime_path),
            "android_runtime_sha256": sha256_file(android_runtime_path),
        },
        "checks": {
            "godot_2800_deep_release_gate": True,
            "python_encoder_golden": True,
            "godot_encoder_golden_windows": True,
            "godot_encoder_golden_android": True,
            "pytorch_onnx_ordinary_and_empty_parity": True,
            "windows_x86_64_load_infer": True,
            "android_arm64_load_infer": True,
            "complete_schema_and_hash_set": True,
            "research10_winner_lineage": True,
        },
        "metrics": dict(validation.get("metrics") or {}),
        "deep_planner": deep_planner_manifest(),
        "deep_model": deep_model,
        "release_decks": decks,
    }
    evidence_path = run_dir / "evaluation" / "evidence.json"
    atomic_write_json(evidence_path, evidence)
    evidence_sha = sha256_file(evidence_path)

    final_root = run_dir / "staging" / "final"
    final_model_root = final_root / "python" / "data" / "ai_models"
    final_runtime_path = (
        final_root / "godot" / "data" / "ai_models_runtime.json"
    )
    final_ai_models_path = (
        final_root / "godot" / "data" / "ai_models.json"
    )
    final_godot_release_path = (
        final_root / "godot" / "data" / "release_manifest.json"
    )
    final_root_release_path = final_root / "release_manifest.json"
    final_paths: list[Path] = []
    final_runtime = copy.deepcopy(provisional_runtime)
    final_runtime["candidate_evaluation"] = False
    final_runtime["deep_planner"] = deep_planner_manifest(evidence_sha)
    final_ai_models = {
        "format_version": 1,
        "inference_format": "onnx-fp32",
        "search_simulations": int(
            final_runtime.get("search_simulations", 64)
        ),
        "state_numeric_size": int(
            final_runtime.get("state_numeric_size", 0)
        ),
        "state_card_slots": int(
            final_runtime.get("state_card_slots", 0)
        ),
        "action_numeric_size": int(
            final_runtime.get("action_numeric_size", 0)
        ),
        "card_bucket_count": int(
            final_runtime.get("card_bucket_count", 0)
        ),
        "card_identity_mode": str(
            final_runtime.get("card_identity_mode", "")
        ),
        "card_vocab_version": int(
            final_runtime.get("card_vocab_version", 0)
        ),
        "card_vocab_size": int(
            final_runtime.get("card_vocab_size", 0)
        ),
        "card_vocab_sha256": str(
            final_runtime.get("card_vocab_sha256", "")
        ),
        "semantic_feature_sizes": dict(
            final_runtime.get("semantic_feature_sizes") or {}
        ),
        "models": {},
    }
    for deck in decks:
        source_payload = safe_torch_load(
            run_dir / "models" / f"{deck}.pt",
            map_location="cpu",
        )
        if not isinstance(source_payload, dict):
            raise RuntimeError(f"{deck} candidate checkpoint is invalid")
        payload = copy.deepcopy(source_payload)
        metadata = dict(payload.get("metadata") or {})
        if (
            str(metadata.get("trainer", "")) != TRAINER_HYBRID_POPULATION
            or str(metadata.get("deck", "")) != deck
        ):
            raise RuntimeError(f"{deck} checkpoint provenance is invalid")
        metadata.update(
            {
                "accepted": True,
                "verified": True,
                "verification_status": "godot_deep_release_gate_passed",
                "evidence_sha256": evidence_sha,
                "planner_version": PLANNER_SCHEMA_VERSION,
                "deep_planner_version": DEEP_PLANNER_SCHEMA_VERSION,
            }
        )
        payload["metadata"] = metadata
        pt_path = final_model_root / f"{deck}.pt"
        _atomic_torch_save(pt_path, payload)
        sidecar = {
            "format_version": 1,
            "path": pt_path.name,
            "sha256": sha256_file(pt_path),
            "metadata": metadata,
            "schema": payload.get("schema") or {},
            "model_config": payload.get("model_config") or {},
        }
        sidecar_path = final_model_root / f"{deck}.json"
        atomic_write_json(sidecar_path, sidecar)
        runtime_row = dict(final_runtime["models"][deck])
        runtime_row["checkpoint_sha256"] = sha256_file(pt_path)
        runtime_row["evidence_sha256"] = evidence_sha
        runtime_row["onnx_path"] = f"res://data/ai_models/{deck}.onnx"
        final_runtime["models"][deck] = runtime_row
        final_ai_models["models"][deck] = {
            "deck_key": deck,
            "source_checkpoint": (
                f"python/data/ai_models/{deck}.pt"
            ),
            "onnx_path": f"res://data/ai_models/{deck}.onnx",
            "checkpoint_exists": True,
            "checkpoint_size": pt_path.stat().st_size,
            "checkpoint_sha256": sha256_file(pt_path),
            "checkpoint_version": int(payload.get("version", 0)),
            "accepted": True,
            "verified": True,
            "rules_version": int(metadata.get("rules_version", 0)),
            "action_version": int(metadata.get("action_version", 0)),
            "encoder_version": int(metadata.get("encoder_version", 0)),
            "card_vocab_version": int(
                metadata.get("card_vocab_version", 0)
            ),
            "card_vocab_size": int(
                metadata.get("card_vocab_size", 0)
            ),
            "card_vocab_sha256": str(
                metadata.get("card_vocab_sha256", "")
            ),
            "model_config": dict(payload.get("model_config") or {}),
            "planner_version": int(metadata.get("planner_version", 0)),
        }
        final_paths.extend((pt_path, sidecar_path))

    atomic_write_json(final_runtime_path, final_runtime)
    atomic_write_json(final_ai_models_path, final_ai_models)
    final_paths.extend((final_runtime_path, final_ai_models_path))
    final_release = copy.deepcopy(provisional_release)
    final_release["deep_runtime_enabled"] = True
    final_release["compatible_model_count"] = len(decks)
    final_release["legacy_model_count"] = 0
    final_release["candidate_evaluation"] = False
    final_release["deep_planner"] = deep_planner_manifest(evidence_sha)
    final_release["deep_model"] = deep_model
    atomic_write_json(final_root_release_path, final_release)
    atomic_write_json(final_godot_release_path, final_release)
    final_paths.extend((final_root_release_path, final_godot_release_path))
    onnx_paths = [
        run_dir / "staging" / "godot" / "data" / "ai_models" / f"{deck}.onnx"
        for deck in decks
    ]
    final_manifest = {
        "format_version": 1,
        "kind": "hybrid_promotion_bundle_v1",
        "run_id": str(run["run_id"]),
        "created_at": utc_now(),
        "evidence_path": str(evidence_path.relative_to(run_dir).as_posix()),
        "evidence_sha256": evidence_sha,
        "release_decks": decks,
        "deep_planner": deep_planner_manifest(evidence_sha),
        "deep_model": deep_model,
        "files": _artifact_rows(run_dir, final_paths + onnx_paths),
    }
    final_manifest_path = final_root / "promotion_manifest.json"
    atomic_write_json(final_manifest_path, final_manifest)
    final_manifest_sha = sha256_file(final_manifest_path)
    gate_checks = dict(evidence["checks"])
    update_run(
        run_dir,
        status="verified_candidate",
        matchup_matrix=(
            evaluation.get("fair_adjusted_matrix")
            or evaluation.get("matrix")
            or {}
        ),
        gate={
            "status": "passed",
            "gate": "deep-release",
            "passed_at": utc_now(),
            "evidence_path": str(evidence_path.relative_to(run_dir).as_posix()),
            "evidence_sha256": evidence_sha,
            "checks": gate_checks,
            "metrics": evidence["metrics"],
        },
        candidate_stage={
            **dict(run.get("candidate_stage") or {}),
            "status": "verified_candidate",
            "promotion_manifest_path": str(
                final_manifest_path.relative_to(run_dir).as_posix()
            ),
            "promotion_manifest_sha256": final_manifest_sha,
            "evidence_sha256": evidence_sha,
        },
    )
    return {
        "run_id": run["run_id"],
        "gate": "deep-release",
        "evidence": str(evidence_path),
        "evidence_sha256": evidence_sha,
        "promotion_manifest": str(final_manifest_path),
        "promotion_manifest_sha256": final_manifest_sha,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--evaluation", type=Path)
    parser.add_argument("--windows-runtime", type=Path)
    parser.add_argument("--android-runtime", type=Path)
    args = parser.parse_args()
    result = finalize_evidence(
        args.run_dir,
        evaluation_path=args.evaluation,
        windows_runtime_path=args.windows_runtime,
        android_runtime_path=args.android_runtime,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    os.chdir(PYTHON_ROOT)
    raise SystemExit(main())

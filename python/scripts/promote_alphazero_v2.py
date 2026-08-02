"""Atomically promote a verified AlphaZero v2 universal model bundle."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.run_store import (  # noqa: E402
    atomic_write_json,
    read_json,
    update_run,
    validate_run_id,
)
from engine.ai.dl.release_evidence_v2 import (  # noqa: E402
    validate_release_evidence_file,
)
from engine.ai.dl.v2_contract import (  # noqa: E402
    RELEASE_DECKS,
    contract_dict,
)


JOURNAL_KIND = "alphazero_v2_promotion_transaction_v1"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_file(path: Path, sha256: str | None = None) -> None:
    if not path.is_file():
        raise FileNotFoundError(path)
    if sha256 is not None and _sha256(path) != sha256.lower():
        raise ValueError(f"artifact_hash_mismatch:{path.name}")


def _release_payload(
    source: dict[str, Any],
    evidence_sha256: str,
) -> dict[str, Any]:
    result = json.loads(json.dumps(source))
    result["deep_runtime_enabled"] = True
    result["model_count"] = 1
    result["compatible_model_count"] = 1
    result["legacy_model_count"] = 0
    result["native_ai"]["production_ready"] = True
    result["deep_model"]["status"] = "released"
    result["deep_planner"]["evidence_sha256"] = evidence_sha256
    return result


def _validate_bundle(
    run_dir: Path,
    evidence_sha256: str,
) -> tuple[Path, Path, Path, Path, dict[str, Any]]:
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
    runtime_manifest = (
        run_dir
        / "release_staging"
        / "godot"
        / "data"
        / "ai_models_runtime.json"
    )
    _require_file(checkpoint)
    _require_file(sidecar)
    _require_file(onnx)
    _require_file(runtime_manifest)
    manifest = read_json(runtime_manifest)
    if int(manifest.get("format_version", 0)) != 3:
        raise ValueError("runtime_manifest_format_mismatch")
    if dict(manifest.get("contract") or {}) != contract_dict():
        raise ValueError("runtime_contract_mismatch")
    models = dict(manifest.get("models") or {})
    universal = dict(models.get("universal") or {})
    if set(models) != {"universal"}:
        raise ValueError("runtime_model_set_mismatch")
    if str(universal.get("checkpoint_sha256", "")).lower() != _sha256(
        checkpoint
    ):
        raise ValueError("runtime_checkpoint_hash_mismatch")
    sidecar_payload = read_json(sidecar)
    if str(sidecar_payload.get("checkpoint_sha256", "")).lower() != _sha256(
        checkpoint
    ):
        raise ValueError("sidecar_checkpoint_hash_mismatch")
    if str(universal.get("onnx_sha256", "")).lower() != _sha256(onnx):
        raise ValueError("runtime_onnx_hash_mismatch")
    routes = dict(manifest.get("deck_routes") or {})
    if routes != {deck: "universal" for deck in RELEASE_DECKS}:
        raise ValueError("runtime_deck_routes_mismatch")
    planner = dict(manifest.get("deep_planner") or {})
    if str(planner.get("evidence_sha256", "")).lower() != evidence_sha256:
        raise ValueError("runtime_evidence_hash_mismatch")
    return checkpoint, sidecar, onnx, runtime_manifest, manifest


def promote(
    run_dir: Path,
    *,
    evidence_sha256: str,
    confirm_run_id: str,
    repo_root: Path = REPO_ROOT,
) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    run = read_json(run_dir / "run.json")
    run_id = validate_run_id(str(run.get("run_id", "")))
    if confirm_run_id != run_id:
        raise ValueError("promotion_confirmation_mismatch")
    gate = dict(run.get("gate") or {})
    if (
        str(gate.get("status", "")) != "passed"
        or str(gate.get("evidence_sha256", "")).lower()
        != evidence_sha256.lower()
    ):
        raise ValueError("release_gate_not_passed")
    evidence = run_dir / str(gate.get("evidence_path", ""))
    _require_file(evidence, evidence_sha256)
    release_gate = validate_release_evidence_file(
        evidence,
        run_dir=run_dir,
    )
    if not release_gate["passed"]:
        raise RuntimeError(
            "release_evidence_not_passed:"
            + ",".join(release_gate["blockers"])
        )
    checkpoint, sidecar, onnx, runtime_source, runtime = _validate_bundle(
        run_dir,
        evidence_sha256.lower(),
    )

    transaction = (
        run_dir
        / "staging"
        / "promotion_transactions"
        / f"{int(time.time() * 1000)}"
    )
    prepared = transaction / "prepared"
    backup = transaction / "backup"
    prepared.mkdir(parents=True)
    backup.mkdir()
    targets = [
        (
            "checkpoint",
            checkpoint,
            repo_root / "python" / "data" / "ai_models" / "universal.pt",
        ),
        (
            "checkpoint_sidecar",
            sidecar,
            repo_root / "python" / "data" / "ai_models" / "universal.json",
        ),
        (
            "onnx",
            onnx,
            repo_root / "godot" / "data" / "ai_models" / "universal.onnx",
        ),
        (
            "runtime_manifest",
            runtime_source,
            repo_root / "godot" / "data" / "ai_models_runtime.json",
        ),
    ]
    root_release = read_json(repo_root / "release_manifest.json")
    promoted_release = _release_payload(
        root_release,
        evidence_sha256.lower(),
    )
    staged_root_release = prepared / "release_manifest.json"
    staged_godot_release = prepared / "godot.release_manifest.json"
    atomic_write_json(staged_root_release, promoted_release)
    atomic_write_json(staged_godot_release, promoted_release)
    targets.extend([
        (
            "release_manifest",
            staged_root_release,
            repo_root / "release_manifest.json",
        ),
        (
            "godot_release_manifest",
            staged_godot_release,
            repo_root / "godot" / "data" / "release_manifest.json",
        ),
    ])

    entries: list[dict[str, Any]] = []
    for ordinal, (kind, source, target) in enumerate(targets):
        staged = prepared / f"{ordinal:02d}-{target.name}"
        if source != staged_root_release and source != staged_godot_release:
            shutil.copy2(source, staged)
        else:
            staged = source
        entries.append({
            "kind": kind,
            "staged": str(staged),
            "target": str(target),
            "backup": str(backup / f"{ordinal:02d}-{target.name}"),
            "sha256": _sha256(staged),
            "had_target": target.is_file(),
            "installed": False,
        })
    journal = {
        "kind": JOURNAL_KIND,
        "run_id": run_id,
        "state": "prepared",
        "evidence_sha256": evidence_sha256.lower(),
        "runtime_manifest_sha256": _sha256(runtime_source),
        "entries": entries,
    }
    atomic_write_json(transaction / "journal.json", journal)
    try:
        for row in entries:
            target = Path(row["target"])
            staged = Path(row["staged"])
            backup_path = Path(row["backup"])
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_file():
                backup_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, backup_path)
            temporary = target.with_name(f".{target.name}.{run_id}.tmp")
            shutil.copy2(staged, temporary)
            os.replace(temporary, target)
            row["installed"] = True
            journal["state"] = "installing"
            atomic_write_json(transaction / "journal.json", journal)
        for row in entries:
            _require_file(Path(row["target"]), str(row["sha256"]))
        # Runtime manifest is copied verbatim; the release manifests carry the
        # same evidence hash and flip the feature gate only in this final step.
        if str(runtime["deep_planner"]["evidence_sha256"]) != evidence_sha256:
            raise ValueError("post_install_evidence_mismatch")
        journal["state"] = "committed"
        atomic_write_json(transaction / "journal.json", journal)
        update_run(
            run_dir,
            status="promoted",
            pid=0,
            promotable=False,
            promotion={
                "status": "committed",
                "journal": str(
                    (transaction / "journal.json").relative_to(
                        run_dir
                    ).as_posix()
                ),
                "evidence_sha256": evidence_sha256.lower(),
            },
        )
        return journal
    except Exception:
        for row in reversed(entries):
            if not row["installed"]:
                continue
            target = Path(row["target"])
            backup_path = Path(row["backup"])
            if backup_path.is_file():
                os.replace(backup_path, target)
            elif target.is_file():
                target.unlink()
        journal["state"] = "rolled_back"
        atomic_write_json(transaction / "journal.json", journal)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--evidence-sha256", required=True)
    parser.add_argument("--confirm-run-id", required=True)
    args = parser.parse_args(argv)
    result = promote(
        args.run_dir,
        evidence_sha256=str(args.evidence_sha256).lower(),
        confirm_run_id=str(args.confirm_run_id),
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

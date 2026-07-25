"""Atomically promote a fully evidenced ten-deck hybrid candidate."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.model import safe_torch_load  # noqa: E402
from engine.ai.dl.production_contract import (  # noqa: E402
    DEEP_PLANNER_SCHEMA_VERSION,
    TRAINER_HYBRID_POPULATION,
)
from engine.ai.dl.run_store import (  # noqa: E402
    atomic_write_json,
    read_json,
    resolve_within,
    sha256_file,
    update_run,
    utc_now,
)
from engine.ai.dl.encoder import ENCODER_SCHEMA_VERSION  # noqa: E402
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION  # noqa: E402

JOURNAL_FORMAT_VERSION = 1


def _copy_fsync(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as input_handle, target.open("wb") as output_handle:
        shutil.copyfileobj(input_handle, output_handle, 1024 * 1024)
        output_handle.flush()
        os.fsync(output_handle.fileno())


def _atomic_install(source: Path, target: Path, token: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / f".{target.name}.{token}.tmp"
    if temporary.exists():
        temporary.unlink()
    _copy_fsync(source, temporary)
    if sha256_file(temporary) != sha256_file(source):
        temporary.unlink(missing_ok=True)
        raise OSError(f"Prepared copy hash mismatch: {target}")
    os.replace(temporary, target)


def _expected_sources(run_dir: Path, decks: list[str]) -> dict[Path, Path]:
    final_root = run_dir / "staging" / "final"
    result: dict[Path, Path] = {}
    for deck in decks:
        result[
            final_root / "python" / "data" / "ai_models" / f"{deck}.pt"
        ] = REPO_ROOT / "python" / "data" / "ai_models" / f"{deck}.pt"
        result[
            final_root / "python" / "data" / "ai_models" / f"{deck}.json"
        ] = REPO_ROOT / "python" / "data" / "ai_models" / f"{deck}.json"
        result[
            run_dir / "staging" / "godot" / "data" / "ai_models" / f"{deck}.onnx"
        ] = REPO_ROOT / "godot" / "data" / "ai_models" / f"{deck}.onnx"
    result[
        final_root / "godot" / "data" / "ai_models_runtime.json"
    ] = REPO_ROOT / "godot" / "data" / "ai_models_runtime.json"
    result[
        final_root / "godot" / "data" / "ai_models.json"
    ] = REPO_ROOT / "godot" / "data" / "ai_models.json"
    result[
        final_root / "release_manifest.json"
    ] = REPO_ROOT / "release_manifest.json"
    result[
        final_root / "godot" / "data" / "release_manifest.json"
    ] = REPO_ROOT / "godot" / "data" / "release_manifest.json"
    return result


def _validate_bundle(
    run_dir: Path,
    evidence_sha: str,
) -> tuple[dict[str, Any], dict[Path, Path]]:
    run = read_json(run_dir / "run.json")
    run_id = str(run.get("run_id", ""))
    gate = dict(run.get("gate") or {})
    if (
        str(run.get("preset", "")) != "release"
        or not bool(run.get("promotable"))
        or str(gate.get("status", "")) != "passed"
        or str(gate.get("evidence_sha256", "")).lower() != evidence_sha
    ):
        raise RuntimeError("Run has not passed the authoritative Release gate")
    evidence_path = resolve_within(
        run_dir, str(gate.get("evidence_path", ""))
    )
    if not evidence_path.is_file() or sha256_file(evidence_path) != evidence_sha:
        raise RuntimeError("Evidence file hash does not match the confirmed hash")
    evidence = read_json(evidence_path)
    if (
        str(evidence.get("kind", "")) != "hybrid_release_evidence_v1"
        or str(evidence.get("run_id", "")) != run_id
        or not all(bool(value) for value in dict(evidence.get("checks") or {}).values())
    ):
        raise RuntimeError("Release evidence is incomplete")

    candidate_stage = dict(run.get("candidate_stage") or {})
    promotion_manifest_path = resolve_within(
        run_dir,
        str(candidate_stage.get("promotion_manifest_path", "")),
    )
    expected_manifest_sha = str(
        candidate_stage.get("promotion_manifest_sha256", "")
    ).lower()
    if (
        not promotion_manifest_path.is_file()
        or sha256_file(promotion_manifest_path) != expected_manifest_sha
    ):
        raise RuntimeError("Promotion manifest hash mismatch")
    manifest = read_json(promotion_manifest_path)
    decks = [str(value) for value in manifest.get("release_decks") or []]
    release = read_json(REPO_ROOT / "release_manifest.json")
    if (
        str(manifest.get("kind", "")) != "hybrid_promotion_bundle_v1"
        or str(manifest.get("run_id", "")) != run_id
        or str(manifest.get("evidence_sha256", "")).lower() != evidence_sha
        or decks != [str(value) for value in release.get("release_decks") or []]
        or len(decks) != 10
    ):
        raise RuntimeError("Promotion manifest contract is invalid")
    sources = _expected_sources(run_dir, decks)
    file_rows = manifest.get("files")
    if not isinstance(file_rows, dict):
        raise RuntimeError("Promotion file ledger is missing")
    expected_relatives = {
        str(source.relative_to(run_dir).as_posix()) for source in sources
    }
    if set(file_rows) != expected_relatives:
        raise RuntimeError("Promotion file ledger has an unexpected target set")
    for source in sources:
        relative = str(source.relative_to(run_dir).as_posix())
        row = dict(file_rows[relative] or {})
        if (
            not source.is_file()
            or sha256_file(source) != str(row.get("sha256", "")).lower()
            or source.stat().st_size != int(row.get("size", -1))
        ):
            raise RuntimeError(f"Promotion artifact changed: {relative}")

    final_root = run_dir / "staging" / "final"
    runtime = read_json(
        final_root / "godot" / "data" / "ai_models_runtime.json"
    )
    exported_models = read_json(
        final_root / "godot" / "data" / "ai_models.json"
    )
    root_release = read_json(final_root / "release_manifest.json")
    godot_release = read_json(
        final_root / "godot" / "data" / "release_manifest.json"
    )
    planner = dict(runtime.get("deep_planner") or {})
    deep_model = dict(root_release.get("deep_model") or {})
    manifest_deep_model = dict(manifest.get("deep_model") or {})
    models = runtime.get("models")
    if (
        root_release != godot_release
        or not bool(root_release.get("deep_runtime_enabled"))
        or int(root_release.get("compatible_model_count", -1)) != 10
        or int(root_release.get("legacy_model_count", -1)) != 0
        or bool(runtime.get("candidate_evaluation", True))
        or int(planner.get("schema_version", 0))
        != DEEP_PLANNER_SCHEMA_VERSION
        or str(planner.get("evidence_sha256", "")).lower() != evidence_sha
        or dict(root_release.get("deep_planner") or {}) != planner
        or not deep_model
        or deep_model != manifest_deep_model
        or not isinstance(models, dict)
        or set(models) != set(decks)
        or set(dict(exported_models.get("models") or {})) != set(decks)
    ):
        raise RuntimeError("Final runtime/release manifests are invalid")
    for deck in decks:
        pt_path = final_root / "python" / "data" / "ai_models" / f"{deck}.pt"
        sidecar_path = (
            final_root / "python" / "data" / "ai_models" / f"{deck}.json"
        )
        onnx_path = (
            run_dir
            / "staging"
            / "godot"
            / "data"
            / "ai_models"
            / f"{deck}.onnx"
        )
        payload = safe_torch_load(str(pt_path), map_location="cpu")
        sidecar = read_json(sidecar_path)
        metadata = dict(payload.get("metadata") or {})
        schema = dict(payload.get("schema") or {})
        row = dict(models[deck])
        exported_row = dict(exported_models["models"][deck])
        expected_model_config = dict(deep_model.get("config") or {})
        if (
            str(metadata.get("trainer", "")) != TRAINER_HYBRID_POPULATION
            or str(metadata.get("deck", "")) != deck
            or not bool(metadata.get("accepted"))
            or not bool(metadata.get("verified"))
            or str(metadata.get("evidence_sha256", "")).lower()
            != evidence_sha
            or int(schema.get("rules_version", 0)) != RULES_SCHEMA_VERSION
            or int(schema.get("action_version", 0)) != ACTION_SCHEMA_VERSION
            or int(schema.get("encoder_version", 0))
            != ENCODER_SCHEMA_VERSION
            or str(sidecar.get("sha256", "")).lower() != sha256_file(pt_path)
            or str(row.get("checkpoint_sha256", "")).lower()
            != sha256_file(pt_path)
            or str(row.get("onnx_sha256", "")).lower()
            != sha256_file(onnx_path)
            or str(row.get("onnx_path", ""))
            != f"res://data/ai_models/{deck}.onnx"
            or str(row.get("evidence_sha256", "")).lower()
            != evidence_sha
            or not bool(exported_row.get("accepted"))
            or not bool(exported_row.get("verified"))
            or str(exported_row.get("checkpoint_sha256", "")).lower()
            != sha256_file(pt_path)
            or int(exported_row.get("rules_version", 0))
            != RULES_SCHEMA_VERSION
            or int(exported_row.get("action_version", 0))
            != ACTION_SCHEMA_VERSION
            or int(exported_row.get("encoder_version", 0))
            != ENCODER_SCHEMA_VERSION
            or dict(row.get("model_config") or {})
            != expected_model_config
            or dict(exported_row.get("model_config") or {})
            != expected_model_config
        ):
            raise RuntimeError(f"Final model contract is invalid: {deck}")
    return run, sources


def _allowed_targets(sources: dict[Path, Path]) -> set[Path]:
    return {path.resolve() for path in sources.values()}


def _recover_incomplete_transactions(
    transaction_parent: Path,
    allowed_targets: set[Path],
) -> None:
    if not transaction_parent.is_dir():
        return
    transaction_parent = transaction_parent.resolve()
    for journal_path in sorted(transaction_parent.glob("*/journal.json")):
        journal_path = journal_path.resolve()
        try:
            journal_path.relative_to(transaction_parent)
        except ValueError as exc:
            raise OSError(
                f"Unsafe promotion journal path: {journal_path}"
            ) from exc
        journal = read_json(journal_path)
        state = str(journal.get("state", ""))
        if state not in {"applying", "prepared", "backing_up"}:
            continue
        entries = list(journal.get("entries") or [])
        if any(
            Path(str(entry.get("target", ""))).resolve()
            not in allowed_targets
            for entry in entries
        ):
            raise OSError(
                f"Unsafe target in incomplete promotion journal: {journal_path}"
            )
        backup_root = (journal_path.parent / "backup").resolve()
        for entry in entries:
            backup = Path(str(entry.get("backup", ""))).resolve()
            try:
                backup.relative_to(backup_root)
            except ValueError as exc:
                raise OSError(
                    "Unsafe backup in incomplete promotion journal: "
                    f"{journal_path}"
                ) from exc
        if state == "applying":
            rollback_errors: list[str] = []
            for entry in reversed(entries):
                target = Path(str(entry["target"])).resolve()
                backup = Path(str(entry["backup"])).resolve()
                try:
                    if bool(entry.get("existed")):
                        if (
                            not backup.is_file()
                            or sha256_file(backup)
                            != str(entry.get("backup_sha256", ""))
                        ):
                            raise OSError("backup_missing_or_changed")
                        _atomic_install(backup, target, "recovery")
                    elif target.exists():
                        target.unlink()
                except OSError as exc:
                    rollback_errors.append(f"{target}:{exc}")
            if rollback_errors:
                journal["state"] = "rollback_failed"
                journal["rollback_errors"] = rollback_errors
                atomic_write_json(journal_path, journal)
                raise OSError(
                    "Incomplete promotion rollback failed: "
                    + "; ".join(rollback_errors)
                )
        journal["state"] = "rolled_back"
        journal["recovered_at"] = utc_now()
        atomic_write_json(journal_path, journal)


def promote(
    run_dir: Path,
    *,
    evidence_sha256: str,
    confirm_run_id: str,
) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    evidence_sha = evidence_sha256.strip().lower()
    if len(evidence_sha) != 64 or any(
        value not in "0123456789abcdef" for value in evidence_sha
    ):
        raise RuntimeError("Evidence SHA-256 is invalid")
    run = read_json(run_dir / "run.json")
    if str(run.get("run_id", "")) != confirm_run_id:
        raise RuntimeError("Explicit run confirmation does not match")
    run, sources = _validate_bundle(run_dir, evidence_sha)
    allowed_targets = _allowed_targets(sources)
    transaction_parent = run_dir / "staging" / "promotion_transactions"
    _recover_incomplete_transactions(transaction_parent, allowed_targets)

    attempt = (
        datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
        + f"-{os.getpid()}"
    )
    transaction_root = transaction_parent / attempt
    prepared_root = transaction_root / "prepared"
    backup_root = transaction_root / "backup"
    entries: list[dict[str, Any]] = []
    for index, (source, target) in enumerate(sources.items()):
        prepared = prepared_root / f"{index:02d}" / target.name
        backup = backup_root / f"{index:02d}" / target.name
        entries.append(
            {
                "source": str(source.resolve()),
                "source_sha256": sha256_file(source),
                "prepared": str(prepared.resolve()),
                "target": str(target.resolve()),
                "backup": str(backup.resolve()),
                "existed": target.exists(),
                "backup_sha256": "",
                "installed": False,
            }
        )
    journal_path = transaction_root / "journal.json"
    journal = {
        "format_version": JOURNAL_FORMAT_VERSION,
        "kind": "hybrid_model_promotion_transaction_v1",
        "run_id": str(run["run_id"]),
        "evidence_sha256": evidence_sha,
        "created_at": utc_now(),
        "state": "backing_up",
        "entries": entries,
    }
    atomic_write_json(journal_path, journal)
    try:
        for entry in entries:
            source = Path(entry["source"])
            prepared = Path(entry["prepared"])
            _copy_fsync(source, prepared)
            if sha256_file(prepared) != entry["source_sha256"]:
                raise OSError(f"Prepared artifact changed: {prepared}")
            target = Path(entry["target"])
            if bool(entry["existed"]):
                backup = Path(entry["backup"])
                _copy_fsync(target, backup)
                entry["backup_sha256"] = sha256_file(backup)
        journal["state"] = "prepared"
        atomic_write_json(journal_path, journal)
        journal["state"] = "applying"
        journal["applying_at"] = utc_now()
        atomic_write_json(journal_path, journal)
        for entry in entries:
            prepared = Path(entry["prepared"])
            target = Path(entry["target"])
            _atomic_install(prepared, target, attempt)
            if sha256_file(target) != entry["source_sha256"]:
                raise OSError(f"Installed artifact hash mismatch: {target}")
            entry["installed"] = True
            atomic_write_json(journal_path, journal)
        # Re-run the complete semantic/hash validation against the now-live
        # targets by comparing every installed byte to its immutable source.
        for source, target in sources.items():
            if sha256_file(source) != sha256_file(target):
                raise OSError(f"Post-install verification failed: {target}")
    except Exception as exc:
        rollback_errors: list[str] = []
        for entry in reversed(entries):
            target = Path(entry["target"])
            backup = Path(entry["backup"])
            try:
                if bool(entry["existed"]):
                    if (
                        not backup.is_file()
                        or sha256_file(backup)
                        != str(entry.get("backup_sha256", ""))
                    ):
                        raise OSError("backup_missing_or_changed")
                    _atomic_install(backup, target, attempt + "-rollback")
                elif target.exists():
                    target.unlink()
            except OSError as rollback_exc:
                rollback_errors.append(f"{target}:{rollback_exc}")
        journal["state"] = (
            "rollback_failed" if rollback_errors else "rolled_back"
        )
        journal["failed_at"] = utc_now()
        journal["error"] = f"{type(exc).__name__}:{exc}"
        journal["rollback_errors"] = rollback_errors
        atomic_write_json(journal_path, journal)
        update_run(
            run_dir,
            status="failed",
            pid=0,
            promotion={
                "status": journal["state"],
                "journal": str(journal_path.relative_to(run_dir).as_posix()),
                "error": journal["error"],
                "rollback_errors": rollback_errors,
            },
        )
        if rollback_errors:
            raise OSError(
                f"Promotion failed and rollback was incomplete: {exc}; "
                + "; ".join(rollback_errors)
            ) from exc
        raise

    journal["state"] = "committed"
    journal["committed_at"] = utc_now()
    atomic_write_json(journal_path, journal)
    update_run(
        run_dir,
        status="promoted",
        pid=0,
        completed_at=run.get("completed_at") or utc_now(),
        promotion={
            "status": "committed",
            "promoted_at": journal["committed_at"],
            "journal": str(journal_path.relative_to(run_dir).as_posix()),
            "evidence_sha256": evidence_sha,
            "artifact_count": len(entries),
        },
    )
    return {
        "run_id": run["run_id"],
        "status": "promoted",
        "evidence_sha256": evidence_sha,
        "journal": str(journal_path),
        "artifact_count": len(entries),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--evidence-sha256", required=True)
    parser.add_argument("--confirm-run-id", required=True)
    args = parser.parse_args()
    result = promote(
        args.run_dir,
        evidence_sha256=args.evidence_sha256,
        confirm_run_id=args.confirm_run_id,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    os.chdir(REPO_ROOT)
    raise SystemExit(main())

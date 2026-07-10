"""Promote a fully verified staged Deep AI release into python/data/ai_models."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
INVOCATION_CWD = Path.cwd()
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

RELEASE_MANIFEST = json.loads(
    (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
)
DECK_KEYS = tuple(str(key) for key in RELEASE_MANIFEST["release_decks"])
if (
    len(DECK_KEYS) != int(RELEASE_MANIFEST["model_count"])
    or len(set(DECK_KEYS)) != len(DECK_KEYS)
):
    raise RuntimeError("release_manifest.json has an invalid release model set")

RUNTIME_MANIFEST_NAME = "ai_models_runtime.json"
TRANSACTION_FORMAT_VERSION = 2
TRANSACTION_MARKER_NAME = ".pokemontcg-ai-model-promotion"
TRANSACTION_MARKER_CONTENT = "PokemonTCG AI model promotion transaction v1\n"


def _resolve(path: Path) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(os.fspath(path))))
    return path.resolve() if path.is_absolute() else (INVOCATION_CWD / path).resolve()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_staged(source: Path) -> None:
    # Keep the transaction/recovery module importable in the lightweight test
    # environment.  Model libraries are needed only for the release gate.
    from scripts.export_onnx_models import _preflight_release_checkpoints
    from scripts.validate_ai_models import (
        DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
        DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
        DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
        DEFAULT_MIN_ACCEPTED_POINT_RATE,
        validate_model,
    )

    invalid = []
    for deck_key in DECK_KEYS:
        row = validate_model(
            deck_key,
            model_dir=str(source),
            min_games=DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
            min_point_rate=DEFAULT_MIN_ACCEPTED_POINT_RATE,
            min_delta_point_rate=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
            max_step_exhaustion_rate=DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
        )
        if not row["valid"]:
            invalid.append(f"{deck_key}:{','.join(row['errors'])}")
    if invalid:
        raise ValueError("Staged release validation failed: " + "; ".join(invalid))
    _preflight_release_checkpoints(source)


def _validate_runtime_bundle(
    checkpoint_root: Path,
    runtime_root: Path,
    manifest_path: Path,
) -> dict[str, Any]:
    if not manifest_path.is_file():
        raise ValueError(f"Staged runtime manifest is missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("Staged runtime manifest must be a JSON object")
    errors: list[str] = []
    if int(manifest.get("format_version") or 0) != 2:
        errors.append(f"format_version={int(manifest.get('format_version') or 0)}")
    if int(manifest.get("opset") or 0) != int(RELEASE_MANIFEST["onnx"]["opset"]):
        errors.append(f"opset={int(manifest.get('opset') or 0)}")
    if str(manifest.get("onnx_runtime_version") or "") != str(
        RELEASE_MANIFEST["onnx"]["runtime_version"]
    ):
        errors.append(
            "onnx_runtime_version="
            + str(manifest.get("onnx_runtime_version") or "")
        )
    models = manifest.get("models")
    if not isinstance(models, dict):
        models = {}
        errors.append("models_not_object")
    expected = set(DECK_KEYS)
    if set(models) != expected:
        errors.append(
            "model_keys=" + ",".join(sorted(str(key) for key in models))
        )
    actual_onnx = {path.stem for path in runtime_root.glob("*.onnx") if path.is_file()}
    if actual_onnx != expected:
        errors.append("onnx_files=" + ",".join(sorted(actual_onnx)))
    for deck_key in DECK_KEYS:
        checkpoint = checkpoint_root / f"{deck_key}.pt"
        onnx_path = runtime_root / f"{deck_key}.onnx"
        row = models.get(deck_key)
        if not checkpoint.is_file():
            errors.append(f"{deck_key}:missing_checkpoint")
            continue
        if not isinstance(row, dict):
            errors.append(f"{deck_key}:missing_manifest_row")
            continue
        if str(row.get("deck_key") or "") != deck_key:
            errors.append(f"{deck_key}:deck_key")
        if str(row.get("onnx_path") or "") != f"res://data/ai_models/{deck_key}.onnx":
            errors.append(f"{deck_key}:onnx_path")
        if str(row.get("checkpoint_sha256") or "").lower() != _sha256(checkpoint):
            errors.append(f"{deck_key}:checkpoint_sha256")
        if not onnx_path.is_file():
            errors.append(f"{deck_key}:missing_onnx")
            continue
        if int(row.get("onnx_size") or -1) != onnx_path.stat().st_size:
            errors.append(f"{deck_key}:onnx_size")
        if str(row.get("onnx_sha256") or "").lower() != _sha256(onnx_path):
            errors.append(f"{deck_key}:onnx_sha256")
    if errors:
        raise ValueError("Staged runtime validation failed: " + "; ".join(errors))
    return manifest


def _write_journal(active_root: Path, journal: dict[str, Any]) -> None:
    path = active_root / "journal.json"
    temporary = active_root / "journal.json.tmp"
    serialized = json.dumps(
        journal,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(serialized)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    if os.name != "nt":
        directory_fd = os.open(active_root, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)


def _move(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    os.replace(source, target)


def _transaction_root(destination: Path, requested: Path | None) -> Path:
    if requested is not None:
        return _resolve(requested)
    return destination.parent / ".ai_models_promotion"


def _paths_overlap(left: Path, right: Path) -> bool:
    left = left.resolve()
    right = right.resolve()
    return left == right or left in right.parents or right in left.parents


def _ensure_transaction_marker(root: Path, *, create: bool) -> None:
    marker = root / TRANSACTION_MARKER_NAME
    if create:
        root.mkdir(parents=True, exist_ok=True)
        if not marker.exists():
            with marker.open("x", encoding="utf-8", newline="\n") as handle:
                handle.write(TRANSACTION_MARKER_CONTENT)
                handle.flush()
                os.fsync(handle.fileno())
    if (
        not marker.is_file()
        or marker.read_text(encoding="utf-8") != TRANSACTION_MARKER_CONTENT
    ):
        raise OSError(f"Refusing unmarked AI model transaction directory: {root}")


def _require_path_under(path: Path, root: Path, label: str) -> None:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        raise OSError(f"Unsafe promotion journal {label} path: {path}") from None


def _journal_destination_root(
    destination_roots: dict[str, Any],
    key: str,
) -> Path:
    raw_root = destination_roots.get(key)
    if not isinstance(raw_root, str) or not raw_root:
        raise OSError(
            f"AI model promotion journal has no {key} destination root"
        )
    root = Path(raw_root)
    if not root.is_absolute():
        raise OSError(
            f"Unsafe promotion journal {key} destination root: {root}"
        )
    return root.resolve()


def _validate_journal_paths(active_root: Path, journal: dict[str, Any]) -> None:
    if int(journal.get("format_version") or 0) != TRANSACTION_FORMAT_VERSION:
        raise OSError("Cannot recover unknown AI model promotion transaction format")
    entries = list(journal.get("entries") or [])
    if not entries:
        raise OSError("AI model promotion journal has no artifact entries")
    destination_roots_value = journal.get("destination_roots")
    if not isinstance(destination_roots_value, dict):
        raise OSError("AI model promotion journal has no destination roots")
    destination_roots: dict[str, Any] = destination_roots_value
    checkpoint_root = _journal_destination_root(
        destination_roots,
        "checkpoints",
    )
    runtime_root = (
        _journal_destination_root(destination_roots, "runtime")
        if "runtime" in destination_roots
        else None
    )
    runtime_manifest_root = (
        _journal_destination_root(destination_roots, "runtime_manifest")
        if "runtime_manifest" in destination_roots
        else None
    )
    for label, destination_root in (
        ("checkpoints", checkpoint_root),
        ("runtime", runtime_root),
        ("runtime_manifest", runtime_manifest_root),
    ):
        if destination_root is not None and _paths_overlap(
            active_root.parent,
            destination_root,
        ):
            raise OSError(
                f"Unsafe promotion journal {label} destination root overlaps "
                "the transaction directory"
            )
    transaction_decks = tuple(str(key) for key in journal.get("deck_keys") or [])
    if not transaction_decks or len(set(transaction_decks)) != len(transaction_decks):
        raise OSError("AI model promotion journal has an invalid deck set")
    checkpoint_names = {
        f"{deck_key}{suffix}"
        for deck_key in transaction_decks
        for suffix in (".pt", ".json")
    }
    onnx_names = {f"{deck_key}.onnx" for deck_key in transaction_decks}
    seen_targets: set[Path] = set()
    seen_checkpoint_names: set[str] = set()
    seen_onnx_names: set[str] = set()
    checkpoint_parents: set[Path] = set()
    runtime_parents: set[Path] = set()
    manifest_targets: list[Path] = []
    for row in entries:
        kind = str(row.get("kind") or "")
        staged = Path(str(row.get("staged") or "")).resolve()
        target = Path(str(row.get("target") or "")).resolve()
        backup = Path(str(row.get("backup") or "")).resolve()
        _require_path_under(staged, active_root / "prepared", "staged")
        _require_path_under(backup, active_root / "backup", "backup")
        if target in seen_targets:
            raise OSError(f"Duplicate promotion journal target: {target}")
        seen_targets.add(target)
        if staged.name != target.name or backup.name != target.name:
            raise OSError(f"Promotion journal artifact names differ: {target}")
        if kind == "checkpoint" and target.name in checkpoint_names:
            if target.parent != checkpoint_root:
                raise OSError(
                    "Unsafe promotion journal checkpoint target outside "
                    f"destination root: {target}"
                )
            seen_checkpoint_names.add(target.name)
            checkpoint_parents.add(target.parent)
        elif kind == "onnx" and target.name in onnx_names:
            if runtime_root is None or target.parent != runtime_root:
                raise OSError(
                    "Unsafe promotion journal ONNX target outside "
                    f"destination root: {target}"
                )
            seen_onnx_names.add(target.name)
            runtime_parents.add(target.parent)
        elif kind == "runtime_manifest" and target.name == RUNTIME_MANIFEST_NAME:
            if (
                runtime_manifest_root is None
                or target.parent != runtime_manifest_root
            ):
                raise OSError(
                    "Unsafe promotion journal runtime manifest target outside "
                    f"destination root: {target}"
                )
            manifest_targets.append(target)
        else:
            raise OSError(f"Unexpected promotion journal artifact: {kind}:{target.name}")
    if seen_checkpoint_names != checkpoint_names or len(checkpoint_parents) != 1:
        raise OSError("Promotion journal checkpoint target set is incomplete or split")
    runtime_present = bool(seen_onnx_names or manifest_targets)
    expected_root_keys = {"checkpoints"}
    if runtime_present:
        expected_root_keys.update(("runtime", "runtime_manifest"))
    if set(destination_roots) != expected_root_keys:
        raise OSError("AI model promotion journal has an invalid destination root set")
    runtime_roots_are_consistent = (
        runtime_root is not None
        and runtime_manifest_root is not None
        and runtime_manifest_root == runtime_root.parent
    )
    if runtime_present and (
        seen_onnx_names != onnx_names
        or len(runtime_parents) != 1
        or len(manifest_targets) != 1
        or manifest_targets[0].parent != next(iter(runtime_parents)).parent
        or not runtime_roots_are_consistent
    ):
        raise OSError("Promotion journal runtime target set is incomplete or split")


def _rollback_active(active_root: Path) -> bool:
    if not active_root.exists():
        return False
    _ensure_transaction_marker(active_root.parent, create=False)
    journal_path = active_root / "journal.json"
    if not journal_path.is_file():
        shutil.rmtree(active_root)
        return True
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    _validate_journal_paths(active_root, journal)
    if str(journal.get("phase") or "") == "committed":
        # Commit is irreversible once durably recorded.  A process interruption
        # while deleting backups must only finish cleanup, never restore a
        # subset of the old release over the committed bundle.
        shutil.rmtree(active_root)
        return True
    rollback_errors: list[str] = []
    for row in reversed(list(journal.get("entries") or [])):
        target = Path(str(row["target"]))
        backup = Path(str(row["backup"]))
        staged = Path(str(row["staged"]))
        try:
            if backup.exists():
                target.unlink(missing_ok=True)
                _move(backup, target)
            elif not bool(row.get("had_target")) and (
                bool(row.get("installed")) or not staged.exists()
            ):
                target.unlink(missing_ok=True)
        except OSError as exc:
            rollback_errors.append(f"{target}:{exc}")
    if rollback_errors:
        raise OSError(
            "Promotion rollback was incomplete: " + "; ".join(rollback_errors)
        )
    shutil.rmtree(active_root)
    return True


def rollback_promotion(transaction_root: Path) -> bool:
    root = _resolve(transaction_root)
    return _rollback_active(root / "active")


def commit_promotion(transaction_root: Path) -> bool:
    root = _resolve(transaction_root)
    active_root = root / "active"
    if not active_root.exists():
        return False
    _ensure_transaction_marker(root, create=False)
    journal_path = active_root / "journal.json"
    if not journal_path.is_file():
        raise OSError("AI model promotion transaction has no recovery journal")
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    _validate_journal_paths(active_root, journal)
    if str(journal.get("phase") or "") != "installed":
        raise OSError("AI model promotion transaction is not ready to commit")
    for row in journal.get("entries") or []:
        target = Path(str(row["target"]))
        expected_hash = str(row.get("sha256") or "")
        if not target.is_file() or _sha256(target) != expected_hash:
            raise OSError(f"Installed promotion artifact changed before commit: {target}")
    journal["phase"] = "committed"
    _write_journal(active_root, journal)
    shutil.rmtree(active_root)
    return True


def _prepare_checkpoints(
    source: Path,
    prepared: Path,
) -> dict[str, str]:
    prepared.mkdir(parents=True)
    checksums: dict[str, str] = {}
    for deck_key in DECK_KEYS:
        source_model = source / f"{deck_key}.pt"
        source_sidecar = source / f"{deck_key}.json"
        prepared_model = prepared / source_model.name
        prepared_sidecar = prepared / source_sidecar.name
        shutil.copy2(source_model, prepared_model)
        payload = json.loads(source_sidecar.read_text(encoding="utf-8"))
        payload["model_path"] = os.path.join(
            "data", "ai_models", f"{deck_key}.pt"
        )
        source_hash = _sha256(source_model)
        payload["checkpoint_sha256"] = source_hash
        prepared_sidecar.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        if _sha256(prepared_model) != source_hash:
            raise OSError(f"Checkpoint copy verification failed: {deck_key}")
        checksums[deck_key] = source_hash
    _validate_staged(prepared)
    return checksums


def _prepare_runtime(
    runtime_source: Path,
    manifest_source: Path,
    prepared_runtime: Path,
    prepared_manifest: Path,
) -> None:
    prepared_runtime.mkdir(parents=True)
    for deck_key in DECK_KEYS:
        shutil.copy2(
            runtime_source / f"{deck_key}.onnx",
            prepared_runtime / f"{deck_key}.onnx",
        )
    shutil.copy2(manifest_source, prepared_manifest)


def promote(
    source: Path,
    destination: Path,
    *,
    runtime_source: Path | None = None,
    runtime_destination: Path | None = None,
    runtime_manifest_source: Path | None = None,
    runtime_manifest_destination: Path | None = None,
    transaction_root: Path | None = None,
    defer_commit: bool = False,
) -> dict[str, str]:
    source = _resolve(source)
    destination = _resolve(destination)
    runtime_enabled = any(
        value is not None
        for value in (
            runtime_source,
            runtime_destination,
            runtime_manifest_source,
            runtime_manifest_destination,
        )
    )
    if runtime_enabled and (runtime_source is None or runtime_destination is None):
        raise ValueError(
            "runtime_source and runtime_destination are both required for combined promotion"
        )
    resolved_runtime_source = _resolve(runtime_source) if runtime_source else None
    resolved_runtime_destination = (
        _resolve(runtime_destination) if runtime_destination else None
    )
    resolved_manifest_source = None
    resolved_manifest_destination = None
    if runtime_enabled:
        resolved_manifest_source = _resolve(runtime_manifest_source or (
            resolved_runtime_source.parent / RUNTIME_MANIFEST_NAME
        ))
        resolved_manifest_destination = _resolve(runtime_manifest_destination or (
            resolved_runtime_destination.parent / RUNTIME_MANIFEST_NAME
        ))

    root = _transaction_root(destination, transaction_root)
    protected_roots = [("checkpoint source/destination", source, destination)]
    if runtime_enabled:
        protected_roots.append((
            "runtime source/destination",
            resolved_runtime_source,
            resolved_runtime_destination,
        ))
    for label, left, right in protected_roots:
        if _paths_overlap(left, right):
            raise ValueError(f"Promotion {label} paths must be disjoint")
    for label, artifact_root in (
        ("checkpoint source", source),
        ("checkpoint destination", destination),
        ("runtime source", resolved_runtime_source),
        ("runtime destination", resolved_runtime_destination),
    ):
        if artifact_root is not None and _paths_overlap(root, artifact_root):
            raise ValueError(f"Promotion transaction root overlaps {label}")

    _validate_staged(source)
    if runtime_enabled:
        _validate_runtime_bundle(
            source,
            resolved_runtime_source,
            resolved_manifest_source,
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    active_root = root / "active"
    if active_root.exists():
        raise OSError(
            f"Unfinished AI model promotion exists at {active_root}; "
            "commit or roll it back before starting another promotion"
        )
    _ensure_transaction_marker(root, create=True)
    active_root.mkdir()
    prepared_checkpoints = active_root / "prepared" / "checkpoints"
    prepared_runtime = active_root / "prepared" / "runtime"
    prepared_manifest = active_root / "prepared" / RUNTIME_MANIFEST_NAME
    backup_root = active_root / "backup"
    backup_root.mkdir(parents=True)
    journal: dict[str, Any] | None = None
    try:
        checksums = _prepare_checkpoints(source, prepared_checkpoints)
        if runtime_enabled:
            _prepare_runtime(
                resolved_runtime_source,
                resolved_manifest_source,
                prepared_runtime,
                prepared_manifest,
            )
            _validate_runtime_bundle(
                prepared_checkpoints,
                prepared_runtime,
                prepared_manifest,
            )

        destination.mkdir(parents=True, exist_ok=True)
        checkpoint_names = [
            f"{deck_key}{suffix}"
            for deck_key in DECK_KEYS
            for suffix in (".pt", ".json")
        ]
        entries: list[dict[str, Any]] = []
        for name in checkpoint_names:
            target = destination / name
            entries.append({
                "kind": "checkpoint",
                "staged": str((prepared_checkpoints / name).resolve()),
                "target": str(target.resolve()),
                "backup": str((backup_root / "checkpoints" / name).resolve()),
                "sha256": _sha256(prepared_checkpoints / name),
                "had_target": target.exists(),
                "backed_up": False,
                "installed": False,
            })
        if runtime_enabled:
            resolved_runtime_destination.mkdir(parents=True, exist_ok=True)
            for deck_key in DECK_KEYS:
                name = f"{deck_key}.onnx"
                target = resolved_runtime_destination / name
                entries.append({
                    "kind": "onnx",
                    "staged": str((prepared_runtime / name).resolve()),
                    "target": str(target.resolve()),
                    "backup": str((backup_root / "runtime" / name).resolve()),
                    "sha256": _sha256(prepared_runtime / name),
                    "had_target": target.exists(),
                    "backed_up": False,
                    "installed": False,
                })
            entries.append({
                "kind": "runtime_manifest",
                "staged": str(prepared_manifest.resolve()),
                "target": str(resolved_manifest_destination.resolve()),
                "backup": str((backup_root / RUNTIME_MANIFEST_NAME).resolve()),
                "sha256": _sha256(prepared_manifest),
                "had_target": resolved_manifest_destination.exists(),
                "backed_up": False,
                "installed": False,
            })
        destination_roots = {
            "checkpoints": str(destination.resolve()),
        }
        if runtime_enabled:
            destination_roots.update({
                "runtime": str(resolved_runtime_destination.resolve()),
                "runtime_manifest": str(
                    resolved_manifest_destination.parent.resolve()
                ),
            })
        journal = {
            "format_version": TRANSACTION_FORMAT_VERSION,
            "deck_keys": list(DECK_KEYS),
            "destination_roots": destination_roots,
            "phase": "installing",
            "entries": entries,
        }
        _validate_journal_paths(active_root, journal)
        _write_journal(active_root, journal)

        for row in entries:
            target = Path(row["target"])
            if bool(row["had_target"]):
                _move(target, Path(row["backup"]))
                row["backed_up"] = True
            _write_journal(active_root, journal)
        for row in entries:
            _move(Path(row["staged"]), Path(row["target"]))
            row["installed"] = True
            _write_journal(active_root, journal)

        _validate_staged(destination)
        if runtime_enabled:
            _validate_runtime_bundle(
                destination,
                resolved_runtime_destination,
                resolved_manifest_destination,
            )
        journal["phase"] = "installed"
        _write_journal(active_root, journal)
        if not defer_commit:
            commit_promotion(root)
        return checksums
    except Exception:
        try:
            _rollback_active(active_root)
        except Exception as rollback_exc:
            if journal is not None:
                raise OSError(
                    "Promotion failed and rollback was incomplete: "
                    f"{rollback_exc}"
                ) from None
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=REPO_ROOT / "build" / "ai_training" / "v10_v3" / "models",
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=PYTHON_ROOT / "data" / "ai_models",
    )
    parser.add_argument("--runtime-source", type=Path)
    parser.add_argument(
        "--runtime-destination",
        type=Path,
        default=REPO_ROOT / "godot" / "data" / "ai_models",
    )
    parser.add_argument("--runtime-manifest-source", type=Path)
    parser.add_argument("--runtime-manifest-destination", type=Path)
    parser.add_argument("--transaction-root", type=Path)
    parser.add_argument("--defer-commit", action="store_true")
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--commit", action="store_true")
    operation.add_argument("--rollback", action="store_true")
    args = parser.parse_args()
    transaction_root = _transaction_root(
        _resolve(args.destination),
        args.transaction_root,
    )
    if args.commit:
        try:
            committed = commit_promotion(transaction_root)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise SystemExit(str(exc)) from None
        print(json.dumps({"committed": committed}))
        return 0
    if args.rollback:
        try:
            rolled_back = rollback_promotion(transaction_root)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise SystemExit(str(exc)) from None
        print(json.dumps({"rolled_back": rolled_back}))
        return 0
    if args.runtime_source is None:
        raise SystemExit(
            "--runtime-source is required for safe combined promotion"
        )
    try:
        checksums = promote(
            args.source,
            args.destination,
            runtime_source=args.runtime_source,
            runtime_destination=(
                args.runtime_destination if args.runtime_source is not None else None
            ),
            runtime_manifest_source=args.runtime_manifest_source,
            runtime_manifest_destination=args.runtime_manifest_destination,
            transaction_root=transaction_root,
            defer_commit=args.defer_commit,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from None
    print(json.dumps({
        "promoted": list(DECK_KEYS),
        "sha256": checksums,
        "transaction_pending": bool(args.defer_commit),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

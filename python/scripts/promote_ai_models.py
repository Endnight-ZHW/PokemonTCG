"""Promote a fully verified staged Deep AI release into python/data/ai_models."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
INVOCATION_CWD = Path.cwd()
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from scripts.export_onnx_models import DECK_KEYS, _preflight_release_checkpoints
from scripts.validate_ai_models import (
    DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
    DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    DEFAULT_MIN_ACCEPTED_POINT_RATE,
    validate_model,
)


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


def promote(source: Path, destination: Path) -> dict[str, str]:
    source = _resolve(source)
    destination = _resolve(destination)
    _validate_staged(source)
    destination.parent.mkdir(parents=True, exist_ok=True)

    checksums: dict[str, str] = {}
    with tempfile.TemporaryDirectory(
        prefix=".ai_models_promote-",
        dir=destination.parent,
    ) as temp_dir:
        transaction_root = Path(temp_dir)
        prepared = transaction_root / "prepared"
        backup = transaction_root / "backup"
        prepared.mkdir()
        backup.mkdir()
        for deck_key in DECK_KEYS:
            source_model = source / f"{deck_key}.pt"
            source_sidecar = source / f"{deck_key}.json"
            prepared_model = prepared / source_model.name
            prepared_sidecar = prepared / source_sidecar.name
            shutil.copy2(source_model, prepared_model)
            payload = json.loads(source_sidecar.read_text(encoding="utf-8"))
            payload["model_path"] = os.path.join("data", "ai_models", f"{deck_key}.pt")
            source_hash = _sha256(source_model)
            payload["checkpoint_sha256"] = source_hash
            prepared_sidecar.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            if _sha256(prepared_model) != source_hash:
                raise OSError(f"Checkpoint copy verification failed: {deck_key}")
            checksums[deck_key] = source_hash

        # Validate the normalized copies before touching the live release.
        _validate_staged(prepared)
        destination.mkdir(parents=True, exist_ok=True)
        names = [
            f"{deck_key}{suffix}"
            for deck_key in DECK_KEYS
            for suffix in (".pt", ".json")
        ]
        backed_up: list[str] = []
        installed: list[str] = []
        try:
            for name in names:
                target = destination / name
                if target.exists():
                    os.replace(target, backup / name)
                    backed_up.append(name)
            for name in names:
                os.replace(prepared / name, destination / name)
                installed.append(name)
            _validate_staged(destination)
        except Exception:
            # Restore the previous complete release on ordinary copy or
            # validation failures so callers never continue with a mixed set.
            for name in reversed(installed):
                try:
                    (destination / name).unlink(missing_ok=True)
                except OSError:
                    pass
            rollback_errors: list[str] = []
            for name in reversed(backed_up):
                try:
                    os.replace(backup / name, destination / name)
                except OSError as exc:
                    rollback_errors.append(f"{name}:{exc}")
            if rollback_errors:
                raise OSError(
                    "Promotion failed and rollback was incomplete: "
                    + "; ".join(rollback_errors)
                ) from None
            raise
    return checksums


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
    args = parser.parse_args()
    try:
        checksums = promote(args.source, args.destination)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from None
    print(json.dumps({"promoted": list(DECK_KEYS), "sha256": checksums}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

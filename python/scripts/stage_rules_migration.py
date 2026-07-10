"""Stage an all-or-nothing Deep AI rules-schema migration.

Every release deck must have valid, pinned, 600-game paired evidence.  The
command writes a new staging directory and never mutates the published model
directory or release manifest.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.actions import RULES_SCHEMA_VERSION
from engine.ai.dl.model import safe_torch_load
from engine.ai.dl.rules_migration import (
    migrated_checkpoint_payload,
    rules_source_fingerprint,
    sha256_file,
    validate_release_evidence_set,
)


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return payload


def _load_release_decks(manifest_path: Path) -> list[str]:
    manifest = _read_json(manifest_path)
    decks = manifest.get("release_decks")
    if not isinstance(decks, list) or not all(isinstance(deck, str) for deck in decks):
        raise ValueError("Invalid release deck list")
    if len(decks) != int(manifest.get("model_count") or 0) or len(set(decks)) != len(decks):
        raise ValueError("Release deck/model count mismatch")
    return list(decks)


def _source_contract(model_dir: Path, deck: str) -> tuple[Path, dict[str, Any], str]:
    model_path = model_dir / f"{deck}.pt"
    sidecar_path = model_dir / f"{deck}.json"
    if not model_path.is_file() or not sidecar_path.is_file():
        raise FileNotFoundError(f"Missing source checkpoint for {deck}")
    source_hash = sha256_file(model_path)
    sidecar = _read_json(sidecar_path)
    if str(sidecar.get("checkpoint_sha256") or "") != source_hash:
        raise ValueError(f"Source sidecar hash mismatch for {deck}")
    checkpoint = safe_torch_load(str(model_path), map_location="cpu")
    if not isinstance(checkpoint, dict) or "model_state" not in checkpoint:
        raise ValueError(f"Unsupported checkpoint payload for {deck}")
    if dict(checkpoint.get("metadata") or {}) != dict(sidecar.get("metadata") or {}):
        raise ValueError(f"Embedded metadata mismatch for {deck}")
    return model_path, checkpoint, source_hash


def stage(
    *,
    model_dir: Path,
    evidence_dir: Path,
    output_dir: Path,
    manifest_path: Path,
    target_rules_version: int,
    min_games: int,
) -> dict[str, Any]:
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError("PyTorch is required to stage checkpoints") from exc

    if output_dir.exists():
        raise FileExistsError(f"Refusing to replace existing staging directory: {output_dir}")
    release_decks = _load_release_decks(manifest_path)
    source_rows: dict[str, tuple[Path, dict[str, Any], str]] = {}
    evidence_rows: list[dict[str, Any]] = []
    evidence_paths: dict[str, Path] = {}
    for deck in release_decks:
        source_rows[deck] = _source_contract(model_dir, deck)
        evidence_path = evidence_dir / f"{deck}.json"
        if evidence_path.is_file():
            evidence_rows.append(_read_json(evidence_path))
            evidence_paths[deck] = evidence_path

    fingerprint = rules_source_fingerprint(PYTHON_ROOT)
    errors = validate_release_evidence_set(
        evidence_rows,
        release_decks=release_decks,
        model_hashes={deck: row[2] for deck, row in source_rows.items()},
        target_rules_version=target_rules_version,
        rules_fingerprint=str(fingerprint["sha256"]),
        min_games=min_games,
    )
    if errors:
        raise ValueError("Rules migration evidence failed: " + json.dumps(errors, sort_keys=True))

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    transaction_dir = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent)
    )
    staged_rows: dict[str, Any] = {}
    try:
        evidence_by_deck = {str(row["deck"]): row for row in evidence_rows}
        for deck in release_decks:
            source_path, checkpoint, source_hash = source_rows[deck]
            evidence = evidence_by_deck[deck]
            evidence_hash = sha256_file(evidence_paths[deck])
            migrated = migrated_checkpoint_payload(
                checkpoint,
                evidence,
                deck_key=deck,
                target_rules_version=target_rules_version,
                evidence_sha256=evidence_hash,
            )
            staged_model = transaction_dir / f"{deck}.pt"
            staged_sidecar = transaction_dir / f"{deck}.json"
            torch.save(migrated, staged_model)
            staged_hash = sha256_file(staged_model)
            staged_sidecar.write_text(
                json.dumps(
                    {
                        "checkpoint_sha256": staged_hash,
                        "model_path": str((output_dir / f"{deck}.pt").resolve()),
                        "metadata": migrated["metadata"],
                    },
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            reloaded = safe_torch_load(str(staged_model), map_location="cpu")
            if int((reloaded.get("schema") or {}).get("rules_version") or 0) != target_rules_version:
                raise ValueError(f"Staged schema verification failed for {deck}")
            if dict(reloaded.get("metadata") or {}) != dict(
                _read_json(staged_sidecar).get("metadata") or {}
            ):
                raise ValueError(f"Staged sidecar verification failed for {deck}")
            staged_rows[deck] = {
                "source_path": str(source_path.resolve()),
                "source_sha256": source_hash,
                "evidence_path": str(evidence_paths[deck].resolve()),
                "evidence_sha256": evidence_hash,
                "staged_sha256": staged_hash,
            }
        migration_manifest = {
            "format_version": 1,
            "source_rules_version": RULES_SCHEMA_VERSION,
            "target_rules_version": target_rules_version,
            "rules_source": fingerprint,
            "release_decks": release_decks,
            "models": staged_rows,
            "promotion_ready": True,
        }
        (transaction_dir / "migration_manifest.json").write_text(
            json.dumps(migration_manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(transaction_dir, output_dir)
        return migration_manifest
    except Exception:
        shutil.rmtree(transaction_dir, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=PYTHON_ROOT / "data" / "ai_models")
    parser.add_argument("--evidence-dir", type=Path, default=REPO_ROOT / "build" / "rules_v3_evidence")
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "build" / "rules_v3_staging")
    parser.add_argument("--manifest", type=Path, default=REPO_ROOT / "release_manifest.json")
    parser.add_argument("--target-rules-version", type=int, default=RULES_SCHEMA_VERSION + 1)
    parser.add_argument("--min-games", type=int, default=600)
    args = parser.parse_args()
    if args.target_rules_version <= RULES_SCHEMA_VERSION:
        parser.error("target rules version must be newer than the current schema")
    try:
        result = stage(
            model_dir=args.model_dir.resolve(),
            evidence_dir=args.evidence_dir.resolve(),
            output_dir=args.output_dir.resolve(),
            manifest_path=args.manifest.resolve(),
            target_rules_version=int(args.target_rules_version),
            min_games=max(1, int(args.min_games)),
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from None
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

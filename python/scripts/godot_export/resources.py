from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Iterable


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_image_mapping(repo_root: Path, card_ids: Iterable[str]) -> dict[str, str]:
    """Derive the card-image map from the canonical Godot filenames."""
    asset_root = repo_root / "godot" / "assets" / "cards"
    release_ids = sorted(set(card_ids))
    mapping = {card_id: f"{card_id}.webp" for card_id in release_ids}
    missing = [name for name in mapping.values() if not (asset_root / name).is_file()]
    if missing:
        raise FileNotFoundError("Missing canonical card images: " + ", ".join(missing))
    if not (asset_root / "card_back.webp").is_file():
        raise FileNotFoundError("Missing canonical card back: card_back.webp")
    return mapping


def image_paths(mapping: dict[str, str]) -> dict[str, str]:
    return {
        card_id: f"res://assets/cards/{file_name}"
        for card_id, file_name in sorted(mapping.items())
    }


def image_hashes(repo_root: Path, mapping: dict[str, str]) -> dict[str, str]:
    asset_root = repo_root / "godot" / "assets" / "cards"
    return {
        card_id: sha256(asset_root / file_name)
        for card_id, file_name in sorted(mapping.items())
    }


def exported_image_errors(output: Path, mapping: dict[str, str]) -> list[str]:
    target_root = output / "assets" / "cards"
    expected_names = set(mapping.values()) | {"card_back.webp"}
    if not target_root.is_dir():
        return ["missing:assets/cards"]
    actual_names = {path.name for path in target_root.glob("*.webp") if path.is_file()}
    return [
        f"missing:{name}" for name in sorted(expected_names - actual_names)
    ] + [
        f"obsolete:{name}" for name in sorted(actual_names - expected_names)
    ]

"""Append-only card identity vocabulary used by Deep AI encoder v6."""
from __future__ import annotations

import hashlib
import json
from functools import lru_cache
from pathlib import Path
from typing import Any


CARD_VOCAB_VERSION = 1
CARD_PAD_INDEX = 0
CARD_OOV_INDEX = 1
CARD_VOCAB_PATH = Path(__file__).with_name("ai_card_vocab.json")


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


@lru_cache(maxsize=1)
def load_card_vocab() -> dict[str, Any]:
    payload = json.loads(CARD_VOCAB_PATH.read_text(encoding="utf-8"))
    if int(payload.get("format_version", 0)) != CARD_VOCAB_VERSION:
        raise RuntimeError("Unsupported AI card vocabulary version")
    if int(payload.get("pad_index", -1)) != CARD_PAD_INDEX:
        raise RuntimeError("AI card vocabulary pad index must be 0")
    if int(payload.get("oov_index", -1)) != CARD_OOV_INDEX:
        raise RuntimeError("AI card vocabulary OOV index must be 1")
    entries = {
        str(card_id): int(index)
        for card_id, index in dict(payload.get("entries") or {}).items()
    }
    tombstones = sorted(
        {str(card_id) for card_id in payload.get("tombstones") or []}
    )
    indices = list(entries.values())
    if any(index < 2 for index in indices):
        raise RuntimeError("AI card vocabulary entries must start at index 2")
    if len(indices) != len(set(indices)):
        raise RuntimeError("AI card vocabulary indices must be unique")
    expected_indices = list(range(2, max([1, *indices]) + 1))
    if sorted(indices) != expected_indices:
        raise RuntimeError(
            "AI card vocabulary indices must be contiguous and append-only"
        )
    unknown_tombstones = sorted(set(tombstones) - set(entries))
    if unknown_tombstones:
        raise RuntimeError(
            "AI card vocabulary tombstones have no retained entry: "
            + ", ".join(unknown_tombstones)
        )
    return {
        "format_version": CARD_VOCAB_VERSION,
        "pad_index": CARD_PAD_INDEX,
        "oov_index": CARD_OOV_INDEX,
        "entries": entries,
        "tombstones": tombstones,
    }


def card_vocab_index(card_or_id: Any) -> int:
    if card_or_id is None:
        return CARD_PAD_INDEX
    card_id = getattr(card_or_id, "api_id", card_or_id)
    if not card_id:
        return CARD_PAD_INDEX
    return int(
        load_card_vocab()["entries"].get(str(card_id), CARD_OOV_INDEX)
    )


def card_vocab_size() -> int:
    entries = load_card_vocab()["entries"]
    return max([CARD_OOV_INDEX, *entries.values()]) + 1


def card_vocab_sha256() -> str:
    return hashlib.sha256(canonical_json_bytes(load_card_vocab())).hexdigest()


def validate_release_card_vocab(card_ids: list[str] | tuple[str, ...]) -> None:
    entries = load_card_vocab()["entries"]
    missing = sorted({str(card_id) for card_id in card_ids} - set(entries))
    if missing:
        raise RuntimeError(
            "Release cards are missing from the append-only AI vocabulary: "
            + ", ".join(missing)
        )

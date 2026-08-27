"""Explicitly append release cards to Deep AI's immutable identity vocabulary.

Normal data export deliberately refuses unknown release cards.  This command
is the only supported path for assigning new indices: it preserves every
existing mapping, appends missing IDs in lexical order, and retains removed
cards as tombstones so an index is never reused.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = RESEARCH_ROOT / "python"
PRODUCT_PYTHON_ROOT = REPO_ROOT / "python"
for import_root in (PYTHON_ROOT, PRODUCT_PYTHON_ROOT):
    if str(import_root) not in sys.path:
        sys.path.insert(0, str(import_root))

from deep_ai.card_vocab import (  # noqa: E402
    CARD_OOV_INDEX,
    CARD_PAD_INDEX,
    CARD_VOCAB_PATH,
    CARD_VOCAB_VERSION,
    canonical_json_bytes,
)
from data.deck_definitions import ALL_CARD_IDS  # noqa: E402


def updated_payload(path: Path = CARD_VOCAB_PATH) -> tuple[dict, list[str]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if int(raw.get("format_version", 0)) != CARD_VOCAB_VERSION:
        raise RuntimeError("Refusing to update an unsupported card vocabulary")
    entries = {
        str(card_id): int(index)
        for card_id, index in dict(raw.get("entries") or {}).items()
    }
    if int(raw.get("pad_index", -1)) != CARD_PAD_INDEX:
        raise RuntimeError("Refusing to change the vocabulary pad index")
    if int(raw.get("oov_index", -1)) != CARD_OOV_INDEX:
        raise RuntimeError("Refusing to change the vocabulary OOV index")
    indices = sorted(entries.values())
    if (
        len(indices) != len(set(indices))
        or any(index < 2 for index in indices)
        or indices != list(range(2, max([1, *indices]) + 1))
    ):
        raise RuntimeError(
            "Refusing to update a non-contiguous or colliding vocabulary"
        )
    old_entries = dict(entries)
    next_index = max([CARD_OOV_INDEX, *entries.values()]) + 1
    added: list[str] = []
    for card_id in sorted(set(ALL_CARD_IDS) - set(entries)):
        entries[card_id] = next_index
        next_index += 1
        added.append(card_id)
    if any(entries[key] != value for key, value in old_entries.items()):
        raise RuntimeError("Existing card vocabulary indices must never change")
    release_ids = set(ALL_CARD_IDS)
    tombstones = sorted(set(entries) - release_ids)
    return {
        "format_version": CARD_VOCAB_VERSION,
        "pad_index": CARD_PAD_INDEX,
        "oov_index": CARD_OOV_INDEX,
        "entries": entries,
        "tombstones": tombstones,
    }, added


def atomic_write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(
                json.dumps(
                    payload,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                ).encode("utf-8")
                + b"\n"
            )
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    payload, added = updated_payload()
    current = json.loads(CARD_VOCAB_PATH.read_text(encoding="utf-8"))
    if canonical_json_bytes(current) == canonical_json_bytes(payload):
        print("AI card vocabulary is current; no indices appended.")
        return
    if args.check:
        raise SystemExit(
            "AI card vocabulary requires explicit update; missing release cards: "
            + ", ".join(added)
        )
    atomic_write(CARD_VOCAB_PATH, payload)
    print(
        f"Updated {CARD_VOCAB_PATH}: appended {len(added)} card(s), "
        f"retained {len(payload['tombstones'])} tombstone(s)."
    )


if __name__ == "__main__":
    main()

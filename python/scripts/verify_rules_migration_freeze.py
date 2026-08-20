"""Fail when frozen migration content changes without updating the baseline."""
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINE_PATH = REPO_ROOT / "contracts" / "rules_migration_baseline.json"


def _file_sha256(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def main() -> None:
    baseline = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    expected = baseline["fingerprints"]
    actual = {
        "cards_json_sha256": _file_sha256(REPO_ROOT / "godot/data/cards.json"),
        "decks_json_sha256": _file_sha256(REPO_ROOT / "godot/data/decks.json"),
        "vm_descriptors_json_sha256": _file_sha256(
            REPO_ROOT / "godot/data/vm_command_descriptors.json"
        ),
    }
    card_ir = json.loads(
        (REPO_ROOT / "godot/data/card_ir_v3.json").read_text(encoding="utf-8")
    )
    actual["vm_descriptor_digest"] = str(card_ir.get("descriptor_digest", ""))
    actual["card_ir_content_fingerprint"] = str(
        card_ir.get("content_fingerprint", "")
    )
    actual["card_ir_contract_fingerprint"] = str(
        card_ir.get("contract_fingerprint", "")
    )
    errors = [
        f"{key}: expected {expected.get(key)} got {value}"
        for key, value in actual.items()
        if expected.get(key) != value
    ]
    counts = baseline["counts"]
    cards = json.loads((REPO_ROOT / "godot/data/cards.json").read_text(encoding="utf-8"))
    decks = json.loads((REPO_ROOT / "godot/data/decks.json").read_text(encoding="utf-8"))
    if len(cards) != int(counts["cards"]):
        errors.append(f"cards: expected {counts['cards']} got {len(cards)}")
    if len(decks) != int(counts["decks"]):
        errors.append(f"decks: expected {counts['decks']} got {len(decks)}")
    if int(card_ir.get("effect_count", -1)) != int(counts["author_effects"]):
        errors.append("author effect count changed")
    if errors:
        raise SystemExit("Rules migration freeze violation:\n" + "\n".join(errors))
    print("RULES_MIGRATION_FREEZE_OK")


if __name__ == "__main__":
    main()

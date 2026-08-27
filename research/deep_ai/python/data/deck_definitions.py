"""Research deck catalog loaded from the product's generated Godot JSON."""
from __future__ import annotations

import json
import random
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
DECKS_PATH = REPO_ROOT / "godot" / "data" / "decks.json"
with DECKS_PATH.open("r", encoding="utf-8") as handle:
    _DECK_ROWS = json.load(handle)
if not isinstance(_DECK_ROWS, dict):
    raise ValueError("invalid_godot_deck_catalog")

DECK_SPECS: dict[str, list[tuple[str, int]]] = {
    str(deck_key): [
        (str(row["card_id"]), int(row["count"]))
        for row in deck.get("cards", [])
    ]
    for deck_key, deck in _DECK_ROWS.items()
}
ALL_CARD_IDS = sorted({card_id for deck in DECK_SPECS.values() for card_id, _ in deck})
BASIC_ENERGY_IDS = {
    "Fire": "sv1-ener-2",
    "Water": "sv1-ener-3",
    "Grass": "sv1-ener-1",
    "Lightning": "sv1-ener-4",
    "Psychic": "sv1-ener-5",
    "Fighting": "sv1-ener-6",
    "Darkness": "sv1-ener-7",
    "Metal": "sv1-ener-8",
}


def expand_deck(deck_spec: list[tuple[str, int]]) -> list[str]:
    return [card_id for card_id, count in deck_spec for _ in range(count)]


def verify_deck_size(deck: list[str]) -> bool:
    return len(deck) == 60


def shuffle_deck(deck: list[str]) -> list[str]:
    result = list(deck)
    random.shuffle(result)
    return result

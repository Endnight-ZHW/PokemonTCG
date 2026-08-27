from __future__ import annotations

import dataclasses
from typing import Any

from data.card_registry import CardRegistry
from data.deck_definitions import (
    ALL_CARD_IDS,
    COLORLESS_DECK,
    DARKNESS_DECK,
    DRAGON_DECK,
    FIGHTING_DECK,
    FIRE_DECK,
    GRASS_DECK,
    LIGHTNING_DECK,
    PSYCHIC_DECK_NATU,
    STEEL_DECK,
    WATER_DECK,
)
from engine.commands.ir import compile_effects_to_payload


DECKS = {
    "fire": {"name": "烈焰猴", "energy_type": "Fire", "cards": FIRE_DECK},
    "water": {"name": "甲贺忍蛙ex", "energy_type": "Water", "cards": WATER_DECK},
    "psychic": {"name": "天然鸟", "energy_type": "Psychic", "cards": PSYCHIC_DECK_NATU},
    "lightning": {"name": "皮卡丘ex", "energy_type": "Lightning", "cards": LIGHTNING_DECK},
    "fighting": {"name": "路卡利欧", "energy_type": "Fighting", "cards": FIGHTING_DECK},
    "colorless": {"name": "一家鼠ex", "energy_type": "Colorless", "cards": COLORLESS_DECK},
    "dragon": {"name": "七夕青鸟ex", "energy_type": "Dragon", "cards": DRAGON_DECK},
    "grass": {"name": "土台龟", "energy_type": "Grass", "cards": GRASS_DECK},
    "steel": {"name": "苍响·藏玛然特", "energy_type": "Metal", "cards": STEEL_DECK},
    "darkness": {"name": "獒教父ex", "energy_type": "Darkness", "cards": DARKNESS_DECK},
}


def json_value(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return {
            field.name: json_value(getattr(value, field.name))
            for field in dataclasses.fields(value)
        }
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(item) for item in value]
    if isinstance(value, set):
        return sorted(json_value(item) for item in value)
    return value


def build_card_payload(image_paths: dict[str, str]) -> dict[str, dict[str, Any]]:
    release_ids = sorted(set(ALL_CARD_IDS))
    CardRegistry.initialize(release_ids)
    cards: dict[str, dict[str, Any]] = {}
    for card_id in release_ids:
        card = CardRegistry.get(card_id)
        if card is None:
            raise ValueError(f"Release card is missing from CardRegistry: {card_id}")
        payload = json_value(card)
        add_compiled_effects(payload)
        payload.update({
            "image_path": image_paths.get(card_id, ""),
            "prize_value": card.prize_value,
            "provides_energy": card.provides_energy,
        })
        cards[card_id] = payload
    return cards


def add_compiled_effects(payload: dict[str, Any]) -> None:
    for attack in payload.get("attacks", []):
        attack["compiled_effects"] = compile_effects_to_payload(
            attack.get("effects", [])
        )
    for ability in payload.get("abilities", []):
        ability["compiled_effects"] = compile_effects_to_payload(
            ability.get("effects", [])
        )
    payload["compiled_trainer_effects"] = compile_effects_to_payload(
        payload.get("trainer_effects", [])
    )
    for descriptor in payload.get("energy_effects", []):
        if not isinstance(descriptor, dict) or descriptor.get("kind") != "trigger":
            continue
        effect = descriptor.get("effect") or {}
        if (
            descriptor.get("hook") == "ON_PRIZE_REVEALED"
            and isinstance(effect, dict)
            and effect.get("op") == "attach_to_benched_pokemon"
        ):
            descriptor["compiled_commands"] = [{
                "op": "attach_energy",
                "args": {"amount": 1, "from_zone": "prizes", "to": "any"},
                "branches": {},
            }]


def build_deck_payload() -> dict[str, dict[str, Any]]:
    payload: dict[str, dict[str, Any]] = {}
    for key, definition in DECKS.items():
        rows = [
            {"card_id": card_id, "count": int(count)}
            for card_id, count in definition["cards"]
        ]
        payload[key] = {
            "key": key,
            "name": definition["name"],
            "energy_type": definition["energy_type"],
            "card_count": sum(row["count"] for row in rows),
            "cards": rows,
        }
    return payload

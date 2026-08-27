"""Load Deep AI card objects from the product's generated Godot catalog."""
from __future__ import annotations

import json
from pathlib import Path

from data.card_models import AbilityDef, AttackDef, Card, EffectDef, WeakRes


REPO_ROOT = Path(__file__).resolve().parents[4]
CARDS_PATH = REPO_ROOT / "godot" / "data" / "cards.json"


def _effects(rows) -> list[EffectDef]:
    result: list[EffectDef] = []
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        params = dict(row.get("params") or {})
        for key in ("on_heads", "on_tails", "on_success", "on_fail", "on_pay"):
            if isinstance(params.get(key), list):
                params[key] = _effects(params[key])
        result.append(EffectDef(str(row.get("effect_type", "")), params))
    return result


def _card(card_id: str, row: dict) -> Card:
    return Card(
        api_id=card_id,
        name=str(row.get("name", "")),
        supertype=str(row.get("supertype", "")),
        subtypes=list(row.get("subtypes") or []),
        hp=int(row.get("hp", 0) or 0),
        energy_types=list(row.get("energy_types") or []),
        evolves_from=str(row.get("evolves_from", "")),
        evolves_to=list(row.get("evolves_to") or []),
        abilities=[
            AbilityDef(
                name=str(value.get("name", "")),
                text=str(value.get("text", "")),
                ability_type=str(value.get("ability_type", "Ability")),
                trigger=str(value.get("trigger", "")),
                effects=_effects(value.get("effects")),
                compiled_effects=list(value.get("compiled_effects") or []),
            )
            for value in row.get("abilities") or []
            if isinstance(value, dict)
        ],
        attacks=[
            AttackDef(
                name=str(value.get("name", "")),
                cost=list(value.get("cost") or []),
                damage=int(value.get("damage", 0) or 0),
                text=str(value.get("text", "")),
                damage_text=str(value.get("damage_text", "")),
                effects=_effects(value.get("effects")),
                converted_energy_cost=int(value.get("converted_energy_cost", 0) or 0),
                compiled_effects=list(value.get("compiled_effects") or []),
            )
            for value in row.get("attacks") or []
            if isinstance(value, dict)
        ],
        weaknesses=[WeakRes(str(value.get("energy_type", "")), str(value.get("value", "")))
                    for value in row.get("weaknesses") or [] if isinstance(value, dict)],
        resistances=[WeakRes(str(value.get("energy_type", "")), str(value.get("value", "")))
                     for value in row.get("resistances") or [] if isinstance(value, dict)],
        retreat_cost=int(row.get("retreat_cost", 0) or 0),
        rules=list(row.get("rules") or []),
        regulation_mark=str(row.get("regulation_mark", "")),
        rarity=str(row.get("rarity", "")),
        image_url_small=str(row.get("image_url_small", "")),
        image_url_large=str(row.get("image_url_large", "")),
        set_name=str(row.get("set_name", "")),
        set_id=str(row.get("set_id", "")),
        number=str(row.get("number", "")),
        artist=str(row.get("artist", "")),
        flavor_text=str(row.get("flavor_text", "")),
        trainer_type=str(row.get("trainer_type", "")),
        trainer_text=str(row.get("trainer_text", "")),
        trainer_effects=_effects(row.get("trainer_effects")),
        energy_effects=list(row.get("energy_effects") or []),
        compiled_trainer_effects=list(row.get("compiled_trainer_effects") or []),
        provides_energy=list(row.get("provides_energy") or []),
        prize_value=int(row.get("prize_value", 0) or 0),
    )


class CardRegistry:
    _cards: dict[str, Card] = {}
    _by_name: dict[str, list[str]] = {}
    _initialized = False
    _catalog: dict[str, dict] | None = None

    @classmethod
    def initialize(cls, card_ids: list[str]) -> None:
        if cls._catalog is None:
            with CARDS_PATH.open("r", encoding="utf-8") as handle:
                loaded = json.load(handle)
            if not isinstance(loaded, dict):
                raise ValueError("invalid_godot_card_catalog")
            cls._catalog = loaded
        for card_id in card_ids:
            row = cls._catalog.get(card_id)
            if not isinstance(row, dict) or card_id in cls._cards:
                continue
            card = _card(card_id, row)
            cls._cards[card_id] = card
            cls._by_name.setdefault(card.name.lower(), []).append(card_id)
        cls._initialized = True

    @classmethod
    def get(cls, api_id: str) -> Card | None:
        return cls._cards.get(api_id)

    @classmethod
    def get_by_name(cls, name: str) -> list[Card]:
        return [cls._cards[card_id] for card_id in cls._by_name.get(name.lower(), [])]

    @classmethod
    def all_cards(cls) -> dict[str, Card]:
        return cls._cards

    @classmethod
    def all_ids(cls) -> list[str]:
        return list(cls._cards)

    @classmethod
    def is_initialized(cls) -> bool:
        return cls._initialized

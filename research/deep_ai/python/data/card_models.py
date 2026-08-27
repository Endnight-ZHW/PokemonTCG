"""Small card objects used by the Deep AI research compatibility runtime."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(slots=True)
class EffectDef:
    effect_type: str = ""
    params: dict = field(default_factory=dict)


@dataclass(slots=True)
class AttackDef:
    name: str = ""
    cost: list[str] = field(default_factory=list)
    damage: int = 0
    text: str = ""
    damage_text: str = ""
    effects: list[EffectDef] = field(default_factory=list)
    converted_energy_cost: int = 0
    compiled_effects: list[dict] = field(default_factory=list)


@dataclass(slots=True)
class AbilityDef:
    name: str = ""
    text: str = ""
    ability_type: str = "Ability"
    trigger: str = ""
    effects: list[EffectDef] = field(default_factory=list)
    compiled_effects: list[dict] = field(default_factory=list)


@dataclass(slots=True)
class WeakRes:
    energy_type: str = ""
    value: str = ""


@dataclass(slots=True)
class Card:
    api_id: str = ""
    name: str = ""
    supertype: str = ""
    subtypes: list[str] = field(default_factory=list)
    hp: int = 0
    energy_types: list[str] = field(default_factory=list)
    evolves_from: str = ""
    evolves_to: list[str] = field(default_factory=list)
    abilities: list[AbilityDef] = field(default_factory=list)
    attacks: list[AttackDef] = field(default_factory=list)
    weaknesses: list[WeakRes] = field(default_factory=list)
    resistances: list[WeakRes] = field(default_factory=list)
    retreat_cost: int = 0
    rules: list[str] = field(default_factory=list)
    regulation_mark: str = ""
    rarity: str = ""
    image_url_small: str = ""
    image_url_large: str = ""
    set_name: str = ""
    set_id: str = ""
    number: str = ""
    artist: str = ""
    flavor_text: str = ""
    trainer_type: str = ""
    trainer_text: str = ""
    trainer_effects: list[EffectDef] = field(default_factory=list)
    energy_effects: list[dict] = field(default_factory=list)
    compiled_trainer_effects: list[dict] = field(default_factory=list)
    provides_energy: list[str] = field(default_factory=list)
    prize_value: int = 0

    @property
    def is_basic_pokemon(self) -> bool:
        return self.supertype == "Pokémon" and "Basic" in self.subtypes

    @property
    def is_stage1(self) -> bool:
        return self.supertype == "Pokémon" and "Stage 1" in self.subtypes

    @property
    def is_stage2(self) -> bool:
        return self.supertype == "Pokémon" and "Stage 2" in self.subtypes

    @property
    def is_pokemon(self) -> bool:
        return self.supertype == "Pokémon"

    @property
    def is_trainer(self) -> bool:
        return self.supertype == "Trainer"

    @property
    def is_trainer_item(self) -> bool:
        return self.is_trainer and "Item" in self.subtypes

    @property
    def is_trainer_supporter(self) -> bool:
        return self.is_trainer and "Supporter" in self.subtypes

    @property
    def is_trainer_stadium(self) -> bool:
        return self.is_trainer and "Stadium" in self.subtypes

    @property
    def is_trainer_tool(self) -> bool:
        return self.is_trainer and "Tool" in self.subtypes

    @property
    def is_energy(self) -> bool:
        return self.supertype == "Energy"

    @property
    def is_basic_energy(self) -> bool:
        return self.is_energy and "Basic" in self.subtypes

    @property
    def is_special_energy(self) -> bool:
        return self.is_energy and "Special" in self.subtypes

    def __hash__(self) -> int:
        return hash(self.api_id)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Card) and self.api_id == other.api_id

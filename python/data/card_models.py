"""Card data models - dataclasses for all card types."""
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class EffectDef:
    """A structured game effect definition."""
    effect_type: str  # damage, status, draw, search, heal, switch_self, etc.
    params: dict = field(default_factory=dict)


@dataclass
class AttackDef:
    """A Pokemon attack definition."""
    name: str
    cost: list[str]           # e.g. ["Fire", "Colorless"]
    damage: int               # Base damage, 0 if non-damaging
    text: str                 # Raw card text for display
    effects: list[EffectDef] = field(default_factory=list)
    converted_energy_cost: int = 0


@dataclass
class AbilityDef:
    """A Pokemon ability definition."""
    name: str
    text: str
    ability_type: str = "Ability"  # Ability, Poke-Power, Poke-Body, VSTAR Power
    trigger: str = ""             # Event trigger: on_enter_play, on_turn_start, static, etc.
    effects: list[EffectDef] = field(default_factory=list)


@dataclass
class WeakRes:
    """Weakness or Resistance definition."""
    energy_type: str
    value: str  # "×2", "-30", etc.


@dataclass
class Card:
    """A complete card object combining API data with curated effects."""
    api_id: str = ""
    name: str = ""
    supertype: str = ""          # Pokémon, Trainer, Energy
    subtypes: list[str] = field(default_factory=list)  # ["Basic"], ["Stage 1"], ["Item"], etc.
    hp: int = 0
    energy_types: list[str] = field(default_factory=list)  # ["Fire"], ["Water"], etc.
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
    # Trainer-specific
    trainer_type: str = ""  # Item, Supporter, Stadium, Tool
    trainer_text: str = ""
    trainer_effects: list[EffectDef] = field(default_factory=list)

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
    def is_trainer_item(self) -> bool:
        return self.supertype == "Trainer" and "Item" in self.subtypes

    @property
    def is_trainer_supporter(self) -> bool:
        return self.supertype == "Trainer" and "Supporter" in self.subtypes

    @property
    def is_trainer_stadium(self) -> bool:
        return self.supertype == "Trainer" and "Stadium" in self.subtypes

    @property
    def is_trainer_tool(self) -> bool:
        return self.supertype == "Trainer" and "Tool" in self.subtypes

    @property
    def is_trainer(self) -> bool:
        return self.supertype == "Trainer"

    @property
    def is_energy(self) -> bool:
        return self.supertype == "Energy"

    @property
    def is_basic_energy(self) -> bool:
        return self.is_energy and "Basic" in self.subtypes

    @property
    def is_special_energy(self) -> bool:
        return self.is_energy and "Special" in self.subtypes

    @property
    def provides_energy(self) -> list[str]:
        """What energy types this card provides when attached."""
        if self.is_basic_energy:
            # Map Chinese energy names to their English type
            name = self.name
            energy_map = {
                "火能量": "Fire", "水能量": "Water", "草能量": "Grass",
                "雷能量": "Lightning", "超能量": "Psychic", "斗能量": "Fighting",
                "恶能量": "Darkness", "钢能量": "Metal", "龙能量": "Dragon",
                "Fire Energy": "Fire", "Water Energy": "Water", "Grass Energy": "Grass",
                "Lightning Energy": "Lightning", "Psychic Energy": "Psychic",
                "Fighting Energy": "Fighting", "Darkness Energy": "Darkness",
                "Metal Energy": "Metal",
            }
            for key, value in energy_map.items():
                if key in name or key == name:
                    return [value]
            # Fallback: strip " Energy" or "能量"
            name_stripped = name.replace(" Energy", "").replace("能量", "")
            return [name_stripped]
        elif self.is_special_energy:
            if self.api_id == "svi-dtur":
                return ["Colorless", "Colorless"]  # 双重涡轮能量 provides 2C
            if self.api_id == "svg2-lume":
                return ["Rainbow"]  # 夜光能量: 1个全属性能量
            return ["Colorless"]
        return []

    @property
    def prize_value(self) -> int:
        """How many prize cards this Pokemon is worth when KO'd."""
        if not self.is_pokemon:
            return 0
        subtypes_upper = [s.upper() for s in self.subtypes]
        if "VMAX" in subtypes_upper or "TAG TEAM" in subtypes_upper:
            return 3
        if "EX" in subtypes_upper or "GX" in subtypes_upper or "V" in subtypes_upper or "ex" in subtypes_upper:
            return 2
        return 1

    def __hash__(self):
        return hash(self.api_id)

    def __eq__(self, other):
        if isinstance(other, Card):
            return self.api_id == other.api_id
        return False

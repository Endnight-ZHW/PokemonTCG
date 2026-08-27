"""Single-source card definitions grouped by printed energy/type family."""

from .colorless import CARDS as COLORLESS_CARDS
from .darkness import CARDS as DARKNESS_CARDS
from .dragon import CARDS as DRAGON_CARDS
from .energy import CARDS as ENERGY_CARDS
from .fighting import CARDS as FIGHTING_CARDS
from .fire import CARDS as FIRE_CARDS
from .grass import CARDS as GRASS_CARDS
from .lightning import CARDS as LIGHTNING_CARDS
from .metal import CARDS as METAL_CARDS
from .psychic import CARDS as PSYCHIC_CARDS
from .trainer import CARDS as TRAINER_CARDS
from .water import CARDS as WATER_CARDS

from card_data.authoring_dsl import card_specs_from_mappings


CARD_DEFINITIONS: dict[str, dict] = {}
for group in (
    COLORLESS_CARDS,
    DARKNESS_CARDS,
    DRAGON_CARDS,
    ENERGY_CARDS,
    FIGHTING_CARDS,
    FIRE_CARDS,
    GRASS_CARDS,
    LIGHTNING_CARDS,
    METAL_CARDS,
    PSYCHIC_CARDS,
    TRAINER_CARDS,
    WATER_CARDS,
):
    overlap = set(CARD_DEFINITIONS).intersection(group)
    if overlap:
        raise ValueError("Duplicate card definitions: " + ", ".join(sorted(overlap)))
    CARD_DEFINITIONS.update(group)

CARD_EFFECT_DEFINITIONS = {
    card_id: dict(definition.get("_effects", {}))
    for card_id, definition in CARD_DEFINITIONS.items()
}
CARD_EFFECT_SPECS = card_specs_from_mappings(CARD_EFFECT_DEFINITIONS)

__all__ = [
    "CARD_DEFINITIONS",
    "CARD_EFFECT_DEFINITIONS",
    "CARD_EFFECT_SPECS",
]

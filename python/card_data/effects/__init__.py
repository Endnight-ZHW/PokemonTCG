"""Aggregated built-in card effects."""

from .colorless import EFFECTS as COLORLESS_EFFECTS
from .darkness import EFFECTS as DARKNESS_EFFECTS
from .dragon import EFFECTS as DRAGON_EFFECTS
from .energy import EFFECTS as ENERGY_EFFECTS
from .fighting import EFFECTS as FIGHTING_EFFECTS
from .fire import EFFECTS as FIRE_EFFECTS
from .grass import EFFECTS as GRASS_EFFECTS
from .lightning import EFFECTS as LIGHTNING_EFFECTS
from .metal import EFFECTS as METAL_EFFECTS
from .psychic import EFFECTS as PSYCHIC_EFFECTS
from .trainer import EFFECTS as TRAINER_EFFECTS
from .water import EFFECTS as WATER_EFFECTS

CARD_EFFECT_DEFINITIONS: dict[str, dict] = {}
CARD_EFFECT_DEFINITIONS.update(COLORLESS_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(DARKNESS_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(DRAGON_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(ENERGY_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(FIGHTING_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(FIRE_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(GRASS_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(LIGHTNING_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(METAL_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(PSYCHIC_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(TRAINER_EFFECTS)
CARD_EFFECT_DEFINITIONS.update(WATER_EFFECTS)

# The module-local mappings are normalized once; runtime/export consumers use
# only immutable CardEffectSpec values from this point onward.
from card_data.authoring_dsl import card_specs_from_mappings

CARD_EFFECT_SPECS = card_specs_from_mappings(CARD_EFFECT_DEFINITIONS)

__all__ = ["CARD_EFFECT_DEFINITIONS", "CARD_EFFECT_SPECS"]

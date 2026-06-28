"""Card registry - singleton holding all known Card objects."""
from collections import defaultdict
from utils.logger import get_logger

logger = get_logger(__name__)
from data.card_models import Card, AttackDef, AbilityDef, WeakRes, EffectDef

class CardRegistry:
    """Singleton global card database, keyed by api_id."""

    _cards: dict[str, Card] = {}
    _by_name: dict[str, list[str]] = {}
    _initialized: bool = False

    @classmethod
    def initialize(cls, card_ids: list[str]):
        """Load cards from built-in templates."""

        for card_id in card_ids:
            template = OFFLINE_CARD_TEMPLATES.get(card_id)
            if template is None:
                logger.warning("no template for: %s", card_id)
                continue
            card = cls._build_card(template, card_id)
            cls._cards[card_id] = card
            name_key = card.name.lower()
            if name_key not in cls._by_name:
                cls._by_name[name_key] = []
            if card_id not in cls._by_name[name_key]:
                cls._by_name[name_key].append(card_id)

        cls._initialized = True
        logger.info("%s cards loaded.", len(cls._cards))

    @classmethod
    def _build_card(cls, raw: dict, card_id: str, effects_lookup: dict = None) -> Card:
        """Convert raw template data + effects to a Card object."""
        if effects_lookup is None:
            from card_data.card_effects import CARD_EFFECTS
            effects_lookup = CARD_EFFECTS
        effects_data = effects_lookup.get(card_id, {})

        def _make_effects(eff_list: list) -> list[EffectDef]:
            """Convert raw effect dicts to EffectDef objects."""
            result = []
            for e in eff_list:
                if isinstance(e, EffectDef):
                    result.append(e)
                elif isinstance(e, dict):
                    # Handle nested dicts in coin_flip on_heads/on_tails
                    params = dict(e.get("params", {}))
                    for key in ("on_heads", "on_tails"):
                        if key in params and isinstance(params[key], list):
                            params[key] = _make_effects(params[key])
                    result.append(EffectDef(
                        effect_type=e.get("effect_type", ""),
                        params=params,
                    ))
            return result

        # Parse attacks
        attacks = []
        raw_attacks = raw.get("attacks", [])
        for i, atk in enumerate(raw_attacks):
            atk_name = atk.get("name", "")
            curated = effects_data.get("attacks", {}).get(atk_name, {})
            cost = atk.get("cost", [])
            attacks.append(AttackDef(
                name=atk_name,
                cost=cost,
                damage=cls._parse_damage(atk.get("damage", "0")),
                text=atk.get("text", ""),
                effects=_make_effects(curated.get("effects", [])),
                converted_energy_cost=atk.get("convertedEnergyCost", len(cost)),
            ))

        # Parse abilities
        abilities = []
        raw_abilities = raw.get("abilities", [])
        for ab in raw_abilities:
            ab_name = ab.get("name", "")
            ab_type = ab.get("type", "Ability")
            curated = effects_data.get("abilities", {}).get(ab_name, {})
            abilities.append(AbilityDef(
                name=ab_name,
                text=ab.get("text", ""),
                ability_type=ab_type,
                trigger=curated.get("trigger", ""),
                effects=_make_effects(curated.get("effects", [])),
            ))

        # Parse weaknesses
        weaknesses = [
            WeakRes(energy_type=w["type"], value=w["value"])
            for w in raw.get("weaknesses", [])
        ]

        # Parse resistances
        resistances = [
            WeakRes(energy_type=r["type"], value=r["value"])
            for r in raw.get("resistances", [])
        ]

        # Retreat cost
        retreat_count = raw.get("convertedRetreatCost", len(raw.get("retreatCost", [])))

        # Images
        images = raw.get("images", {})
        set_info = raw.get("set", {})

        # Trainer effects
        trainer_effects = effects_data.get("trainer_effect", {})
        if trainer_effects and not isinstance(trainer_effects, list):
            trainer_effects = [EffectDef(
                effect_type=trainer_effects.get("effect_type", ""),
                params=trainer_effects.get("params", {}),
            )]

        energy_effects = [
            dict(effect)
            for effect in effects_data.get("energy_effects", [])
            if isinstance(effect, dict)
        ]

        # Build trainer_type string
        subtypes = raw.get("subtypes", [])
        trainer_type = ""
        if raw.get("supertype") == "Trainer":
            trainer_type = subtypes[0] if subtypes else ""

        return Card(
            api_id=card_id,
            name=raw.get("name", ""),
            supertype=raw.get("supertype", ""),
            subtypes=subtypes,
            hp=int(raw.get("hp", "0") or "0"),
            energy_types=raw.get("types", []),
            evolves_from=raw.get("evolvesFrom", ""),
            evolves_to=raw.get("evolvesTo", []),
            abilities=abilities,
            attacks=attacks,
            weaknesses=weaknesses,
            resistances=resistances,
            retreat_cost=retreat_count,
            rules=raw.get("rules", []),
            regulation_mark=raw.get("regulationMark", ""),
            rarity=raw.get("rarity", ""),
            image_url_small=images.get("small", ""),
            image_url_large=images.get("large", ""),
            set_name=set_info.get("name", ""),
            set_id=set_info.get("id", ""),
            number=raw.get("number", ""),
            artist=raw.get("artist", ""),
            flavor_text=raw.get("flavorText", ""),
            trainer_type=trainer_type,
            trainer_effects=trainer_effects,
            energy_effects=energy_effects,
        )

    @staticmethod
    def _parse_damage(damage_str: str) -> int:
        """Parse damage string like '60', '30+', '100-' to int base."""
        if not damage_str:
            return 0
        d = damage_str.replace("+", "").replace("-", "").replace("×", "")
        try:
            return int(d)
        except ValueError:
            return 0

    @classmethod
    def get(cls, api_id: str) -> Card | None:
        return cls._cards.get(api_id)

    @classmethod
    def get_by_name(cls, name: str) -> list[Card]:
        ids = cls._by_name.get(name.lower(), [])
        return [cls._cards[cid] for cid in ids if cid in cls._cards]

    @classmethod
    def all_cards(cls) -> dict[str, Card]:
        return cls._cards

    @classmethod
    def all_ids(cls) -> list[str]:
        return list(cls._cards.keys())

    @classmethod
    def is_initialized(cls) -> bool:
        return cls._initialized

# ============================================================
# OFFLINE CARD TEMPLATES - Real Pokemon TCG card data
# ============================================================
# Card IDs are from pokemontcg.io API v2 format (e.g., 'sv1-26').
# All card effects are in card_data/card_effects.py matching the attack/ability names.

from card_data.templates import OFFLINE_CARD_TEMPLATES

"""Card registry - singleton holding all known Card objects."""
from collections import defaultdict
from utils.logger import get_logger

logger = get_logger(__name__)
from data.card_models import Card, AttackDef, AbilityDef, WeakRes, EffectDef
from data.cache_manager import CacheManager
from data.api_client import ApiClient

class CardRegistry:
    """Singleton global card database, keyed by api_id."""

    _cards: dict[str, Card] = {}
    _by_name: dict[str, list[str]] = {}
    _initialized: bool = False

    @classmethod
    def initialize(cls, card_ids: list[str], use_api: bool = True):
        """Load cards from hardcoded templates."""

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
# OFFILINE CARD TEMPLATES - Real Pokemon TCG card data
# ============================================================
# Card IDs are from pokemontcg.io API v2 format (e.g., 'sv1-26').
# All card effects are in card_data/card_effects.py matching the attack/ability names.

OFFLINE_CARD_TEMPLATES = {

    # ============================================================
    # 💧 WATER DECK - Greninja + Golduck archetype
    # ============================================================

    # 呱呱泡蛙 Froakie (sv2-38) - Paldea Evolved
    "sv2-38": {
        "name": "呱呱泡蛙", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Water"], "evolvesFrom": "",
        "attacks": [
            {"name": "跳一下", "cost": ["Water"], "damage": "30",
             "text": "抛掷1次硬币如果为反面，则这个招式失败。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 呱头蛙 Frogadier (sv2-39) - Paldea Evolved
    "sv2-39": {
        "name": "呱头蛙", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 90, "types": ["Water"], "evolvesFrom": "呱呱泡蛙",
        "attacks": [
            {"name": "折返瞬击", "cost": ["Water", "Water"], "damage": "40",
             "text": "若希望，可将这只宝可梦与备战宝可梦互换。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 拉普拉斯 Lapras (sv1-49) - Scarlet & Violet base
    "sv1-49": {
        "name": "拉普拉斯", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 130, "types": ["Water"], "evolvesFrom": "",
        "attacks": [
            {"name": "愤怒冷冻", "cost": ["Water", "Water", "Colorless"], "damage": "110",
             "text": "在上一个对手的回合，如果因为招式的伤害，而导致自己的宝可梦昏厥的话，则使对手的战斗宝可梦陷入麻痹状态。"},
        ],
        "weaknesses": [{"type": "Metal", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # ============================================================
    # 💧 WATER DECK NEW POKEMON - 甲贺忍蛙ex archetype
    # ============================================================

    # 甲贺忍蛙ex Greninja ex (sv2-grex) - Custom
    "sv2-grex": {
        "name": "甲贺忍蛙ex", "supertype": "Pokémon", "subtypes": ["Stage 2", "ex"],
        "hp": 300, "types": ["Water"], "evolvesFrom": "呱头蛙",
        "rules": ["宝可梦ex规则：当你的宝可梦ex被击倒时，对手获得2张奖品卡。"],
        "abilities": [],
        "attacks": [
            {"name": "隐蔽手里剑", "cost": ["Colorless"], "damage": "0",
             "text": "对对手的1只宝可梦造成40点伤害。（对备战宝可梦不计算弱点·抗性）"},
            {"name": "激流斩", "cost": ["Water", "Water"], "damage": "120",
             "text": "如果对手的战斗宝可梦身上有伤害指示物，则追加造成120点伤害。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 凯路迪欧 Keldeo (sv2-keldeo) - Custom
    "sv2-keldeo": {
        "name": "凯路迪欧", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Water"], "evolvesFrom": "",
        "abilities": [],
        "attacks": [
            {"name": "踢飞", "cost": ["Colorless"], "damage": "20", "text": ""},
            {"name": "队列之力", "cost": ["Water", "Colorless"], "damage": "0",
             "text": "追加造成自己备战宝可梦数量×20点伤害。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 雪暴马 Glastrier (sv2-glast) - Custom
    "sv2-glast": {
        "name": "雪暴马", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 130, "types": ["Water"], "evolvesFrom": "",
        "abilities": [],
        "attacks": [
            {"name": "冻结", "cost": ["Water", "Colorless"], "damage": "40",
             "text": "在下一个对手的回合，受到这个招式影响的基础宝可梦，无法使用招式。"},
            {"name": "疯狂冲撞", "cost": ["Water", "Water", "Colorless"], "damage": "130",
             "text": "给这只宝可梦也造成30点伤害。"},
        ],
        "weaknesses": [{"type": "Metal", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 米立龙 Tatsugiri (sv2-tatsu) - Custom
    "sv2-tatsu": {
        "name": "米立龙", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Water"], "evolvesFrom": "",
        "abilities": [],
        "attacks": [
            {"name": "预先准备", "cost": ["Water"], "damage": "0",
             "text": "选择自己牌库中最多2张「基本水能量」，附着于自己的1只基础宝可梦身上，并重洗牌库。"},
            {"name": "上弓折返", "cost": ["Water"], "damage": "0",
             "text": "将这只宝可梦，以及放于其身上的所有卡牌，放回手牌。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 信使鸟 Delibird (sv2-delib) - Custom
    "sv2-delib": {
        "name": "信使鸟", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 60, "types": ["Water"], "evolvesFrom": "",
        "abilities": [],
        "attacks": [
            {"name": "双重抽取", "cost": [], "damage": "0",
             "text": "从自己牌库上方抽取2张卡牌。"},
            {"name": "冰之翼", "cost": ["Water", "Colorless"], "damage": "30", "text": ""},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 海星星 Staryu (sv2-staryu) - Custom
    "sv2-staryu": {
        "name": "海星星", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 60, "types": ["Water"], "evolvesFrom": "",
        "abilities": [],
        "attacks": [
            {"name": "高速星星", "cost": ["Water", "Colorless"], "damage": "30",
             "text": "这个招式的伤害，不计算弱点、抗性以及对手战斗宝可梦身上所附加的效果。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 宝石海星 Starmie (sv2-starm) - Custom
    "sv2-starm": {
        "name": "宝石海星", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 90, "types": ["Water"], "evolvesFrom": "海星星",
        "abilities": [
            {"name": "神秘彗星", "text": "在自己的回合可以使用1次。给对手的1只宝可梦身上，放置2个伤害指示物。然后，将这只宝可梦，以及放于其身上的所有卡牌，放于弃牌区。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "高速攻击", "cost": ["Water", "Colorless"], "damage": "50", "text": ""},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # ============================================================
    # 🔮 PSYCHIC DECK - Gardevoir ex archetype (Scarlet & Violet base)
    # ============================================================

    # 墓仔狗 Greavard (sv1-104) - Scarlet & Violet base 
    "sv1-104": {
        "name": "墓仔狗", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "啃咬", "cost": ["Psychic"], "damage": "10", "text": ""},
            {"name": "幽魂射击", "cost": ["Psychic", "Colorless"], "damage": "20", "text": ""},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 墓扬犬 Houndstone (sv1-106) - Scarlet & Violet base 
    "sv1-106": {
        "name": "墓扬犬", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 140, "types": ["Psychic"], "evolvesFrom": "墓仔狗",
        "attacks": [
            {"name": "扫墓", "cost": ["Psychic", "Psychic"], "damage": "80",
             "text": "追加造成自己弃牌区中超宝可梦的张数×10伤害。"},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless", "Colorless", "Colorless"], "convertedRetreatCost": 3,
    },

    # 咚咚鼠 Dedenne (sv1-114) - Scarlet & Violet base (Psychic type)
    "sv1-114": {
        "name": "咚咚鼠", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "小使者", "cost": ["Colorless"], "damage": "0",
             "text": "从自己的牌库中选择最多2张基本能量卡，展示后加入手牌。然后重洗牌库。"},
            {"name": "旋转折返", "cost": ["Psychic", "Colorless"], "damage": "50",
             "text": "若希望，可将这只宝可梦与备战宝可梦互换。"},
        ],
        "weaknesses": [{"type": "Metal", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # ============================================================
    # 👊 斗系新卡组 — 路卡利欧核心 (用户自定义)
    # ============================================================

    # 利欧路 Riolu (svf-rio)
    "svf-rio": {
        "name": "利欧路", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Fighting"], "evolvesFrom": "",
        "attacks": [
            {"name": "重拳", "cost": ["Fighting"], "damage": "10", "text": ""},
            {"name": "突击", "cost": ["Fighting", "Colorless"], "damage": "50",
             "text": "给这只宝可梦也造成20点伤害。"},
        ],
        "weaknesses": [{"type": "Psychic", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 路卡利欧 Lucario (svf-luca)
    "svf-luca": {
        "name": "路卡利欧", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 120, "types": ["Fighting"], "evolvesFrom": "利欧路",
        "abilities": [
            {"name": "旺盛斗气", "text": "在自己的回合可以使用1次。给这只宝可梦身上放置2个伤害指示物。然后，选择自己牌库中的1张斗能量卡，附着于这只宝可梦身上。并重洗牌库。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "连续波导弹", "cost": ["Fighting", "Fighting"], "damage": "10+",
             "text": "将附着于这只宝可梦身上的斗能量全部放于弃牌区，追加造成其张数×60点伤害。"},
        ],
        "weaknesses": [{"type": "Psychic", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 飞天螳螂 Scyther (svf-scyt)
    "svf-scyt": {
        "name": "飞天螳螂", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 90, "types": ["Grass"], "evolvesFrom": "",
        "attacks": [
            {"name": "高速镰刀", "cost": ["Colorless"], "damage": "20", "text": ""},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 劈斧螳螂 Kleavor (svf-klea)
    "svf-klea": {
        "name": "劈斧螳螂", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 140, "types": ["Fighting"], "evolvesFrom": "飞天螳螂",
        "attacks": [
            {"name": "大树切割", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "抛掷2次硬币，如果全部都是正面，则使对手的战斗宝可梦昏厥。"},
            {"name": "暴走冲撞", "cost": ["Fighting", "Fighting"], "damage": "120",
             "text": "给这只宝可梦也造成30点伤害。"},
        ],
        "weaknesses": [{"type": "Psychic", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 投掷猴 Passimian (svf-pass)
    "svf-pass": {
        "name": "投掷猴", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Fighting"], "evolvesFrom": "",
        "attacks": [
            {"name": "辅助传递", "cost": ["Fighting", "Fighting"], "damage": "70",
             "text": "选择这只宝可梦身上附着的1个能量，转附于备战宝可梦身上。"},
        ],
        "weaknesses": [{"type": "Psychic", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 大葱鸭 Farfetch'd (svf-farf)
    "svf-farf": {
        "name": "大葱鸭", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 90, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "背来", "cost": ["Colorless"], "damage": "0",
             "text": "从自己牌库上方抽取2张卡牌。"},
            {"name": "甩葱殴打", "cost": ["Colorless"], "damage": "30", "text": ""},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 代拉基翁 Terrakion (svf-terr)
    "svf-terr": {
        "name": "代拉基翁", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 130, "types": ["Fighting"], "evolvesFrom": "",
        "attacks": [
            {"name": "岩窟冲撞", "cost": ["Fighting", "Fighting", "Colorless"], "damage": "120",
             "text": "在下一个对手的回合，这只宝可梦不会受到招式的伤害。在上一个自己的回合，如果自己的宝可梦使用了「岩窟冲撞」的话，则无法使用这个招式。"},
        ],
        "weaknesses": [{"type": "Grass", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless", "Colorless"], "convertedRetreatCost": 3,
    },

    # 摔跤鹰人 Hawlucha (svf-hawl) — 无色版
    "svf-hawl": {
        "name": "摔跤鹰人", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "展示姿态", "cost": ["Colorless"], "damage": "0",
             "text": "选择自己弃牌区中最多2张基本能量，附着于1只备战宝可梦身上。"},
            {"name": "挥落", "cost": ["Colorless"], "damage": "30+",
             "text": "如果对手的战斗宝可梦为进化宝可梦的话，则追加造成30点伤害。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 伤药 Potion (svf-potion)
    "svf-potion": {
        "name": "伤药", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["选择自己1只宝可梦回复「30」HP。"],
        "trainer_type": "Item",
    },

    # 能量转移 Energy Switch (svf-ensw2)
    "svf-ensw2": {
        "name": "能量转移", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["选择自己场上宝可梦身上附着的1个基本能量，转附于自己其他宝可梦身上。"],
        "trainer_type": "Item",
    },

    # 凰檗 Houb (svf-houb)
    "svf-houb": {
        "name": "凰檗", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["选择自己的1张手牌，放回牌库下方。然后，从牌库上方抽取卡牌，直到自己的手牌变为5张为止。",
                  "（如果自己的手牌仅有这1张卡牌的话，则无法使用这张卡牌。）"],
        "trainer_type": "Supporter",
    },

    # ============================================================
    # 🃏 TRAINER CARDS - Standard format staples
    # ============================================================

    # -------- Supporters --------

    # 博士的研究 Professor's Research (sv1-189) - Discard hand, draw 7
    "sv1-189": {
        "name": "博士的研究", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["将自己的所有手牌丢弃，然后从牌库上方抽取7张卡。"],
        "trainer_type": "Supporter",
    },

    # 裁判 Judge (sv1-176) - Both players shuffle hand, draw 4
    "sv1-176": {
        "name": "裁判", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["双方玩家将所有手牌放回牌库并洗牌。然后，双方玩家各从牌库上方抽取4张卡。"],
        "trainer_type": "Supporter",
    },

    # 妮莫 Nemona (sv1-180) - Draw 3
    "sv1-180": {
        "name": "妮莫", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["从自己的牌库上方抽取3张卡。"],
        "trainer_type": "Supporter",
    },

    # 米莉亚姆 Miriam (sv1-179) - Heal + shuffle Pokemon from discard
    # -------- Items --------

    # 宝可梦交替 Switch (sv1-150)
    "sv1-150": {
        "name": "宝可梦交替", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["将自己的战斗宝可梦与1只备战宝可梦互换。"],
        "trainer_type": "Item",
    },

    # 巢穴球 Nest Ball (sv1-151)
    "sv1-151": {
        "name": "巢穴球", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["从自己的牌库中选择1张基础宝可梦卡，放置于备战区。然后重洗牌库。"],
        "trainer_type": "Item",
    },

    # 神奇糖果 Rare Candy (sv1-152)
    "sv1-152": {
        "name": "神奇糖果", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["选择自己场上的1只基础宝可梦。若手牌中有从那宝可梦进化而来的2阶进化卡，则将其置于该基础宝可梦身上完成进化。"],
        "trainer_type": "Item",
    },

    # 高级球 Ultra Ball (sv1-153)
    "sv1-153": {
        "name": "高级球", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["从自己的手牌丢弃2张卡。若如此做，从自己的牌库中选择1张宝可梦卡，展示后加入手牌。然后重洗牌库。"],
        "trainer_type": "Item",
    },

    # 厉害钓竿 Super Rod (sv3-134)
    "sv3-134": {
        "name": "厉害钓竿", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["从自己的弃牌区选择宝可梦卡与基本能量卡合计最多3张，放回牌库并重洗。"],
        "trainer_type": "Item",
    },

    # 电气发生器 Electric Generator (sv1-170) - Scarlet & Violet base
    "sv1-170": {
        "name": "电气发生器", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["查看自己牌库上方的5张卡，从中选择最多2张基本雷能量卡，以任意方式附于备战区的雷宝可梦身上。将其他卡放回牌库并重洗。"],
        "trainer_type": "Item",
    },

    # 能量回收 Energy Retrieval (sv1-171) - Scarlet & Violet base
    "sv1-171": {
        "name": "能量回收", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["从自己的弃牌区中选择最多2张基本能量卡加入手牌。"],
        "trainer_type": "Item",
    },

    # 短裤小子 Youngster (sv2-young) - Custom
    "sv2-young": {
        "name": "短裤小子", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["将自己的手牌全部放回牌库并重洗牌库。然后，从牌库上方抽取5张卡牌。"],
        "trainer_type": "Supporter",
    },

    # 小菘 Candice (sv2-cand) - Custom
    "sv2-cand": {
        "name": "小菘", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["查看自己牌库上方7张卡牌，选择其中任意数量的水宝可梦和水能量，在给对手看过之后，加入手牌。将剩余的卡牌放回牌库并重洗牌库。"],
        "trainer_type": "Supporter",
    },

    # 宝可梦捕捉器 Pokemon Catcher (sv2-catch) - Custom
    "sv2-catch": {
        "name": "宝可梦捕捉器", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["抛掷1次硬币如果为正面，则选择对手的1只备战宝可梦，将其与战斗宝可梦互换。"],
        "trainer_type": "Item",
    },

    # ============================================================
    # ⚡ ENERGY CARDS - All 8 basic types
    # ============================================================

    "sv1-ener-1": {
        "name": "草能量", "supertype": "Energy", "subtypes": ["Basic"],
    },
    "sv1-ener-2": {
        "name": "火能量", "supertype": "Energy", "subtypes": ["Basic"],
    },
    "sv1-ener-3": {
        "name": "水能量", "supertype": "Energy", "subtypes": ["Basic"],
    },
    "sv1-ener-4": {
        "name": "雷能量", "supertype": "Energy", "subtypes": ["Basic"],
    },
    "sv1-ener-5": {
        "name": "超能量", "supertype": "Energy", "subtypes": ["Basic"],
    },
    "sv1-ener-6": {
        "name": "斗能量", "supertype": "Energy", "subtypes": ["Basic"],
    },
    "sv1-ener-8": {
        "name": "钢能量", "supertype": "Energy", "subtypes": ["Basic"],
    },

    # ============================================================
    # 🔥 火系新卡组 - 烈焰猴核心 (用户自定义)
    # ============================================================

    # 小火焰猴 Chimchar (svi-chim)
    "svi-chim": {
        "name": "小火焰猴", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 50, "types": ["Fire"], "evolvesFrom": "",
        "attacks": [
            {"name": "火花", "cost": ["Fire"], "damage": "30",
             "text": "选择附着于这只宝可梦身上的1个能量，放于弃牌区。"},
        ],
        "weaknesses": [{"type": "Water", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 猛火猴 Monferno (svi-monf)
    "svi-monf": {
        "name": "猛火猴", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 80, "types": ["Fire"], "evolvesFrom": "小火焰猴",
        "attacks": [
            {"name": "火焰", "cost": ["Fire"], "damage": "30", "text": ""},
            {"name": "喷射火焰", "cost": ["Fire", "Colorless"], "damage": "50",
             "text": "选择附着于这只宝可梦身上的1个能量，放于弃牌区。"},
        ],
        "weaknesses": [{"type": "Water", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 烈焰猴 Infernape (svi-infr)
    "svi-infr": {
        "name": "烈焰猴", "supertype": "Pokémon", "subtypes": ["Stage 2"],
        "hp": 150, "types": ["Fire"], "evolvesFrom": "猛火猴",
        "attacks": [
            {"name": "螺旋业火", "cost": ["Fire"], "damage": "0",
             "text": "将自己牌库上方5张翻到正面。造成其中能量张数×80伤害。正面朝上的能量放于弃牌区，剩余卡牌放回牌库并重洗。"},
            {"name": "燃烧踢", "cost": ["Fire", "Colorless"], "damage": "160",
             "text": "将附着于这只宝可梦身上的能量全部放于弃牌区。"},
        ],
        "weaknesses": [{"type": "Water", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 炎帝 Entei (svi-ente)
    "svi-ente": {
        "name": "炎帝", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 130, "types": ["Fire"], "evolvesFrom": "",
        "abilities": [
            {"name": "压迫感", "text": "只要这只宝可梦在战斗场上，对手战斗宝可梦使用的招式伤害「-20」。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "火焰之球", "cost": ["Colorless", "Colorless", "Colorless"], "damage": "60",
             "text": "追加这只宝可梦身上附着的火能量数量×20伤害。"},
        ],
        "weaknesses": [{"type": "Water", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 加热洛托姆 Heat Rotom (svi-hrot)
    "svi-hrot": {
        "name": "加热洛托姆", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 90, "types": ["Fire"], "evolvesFrom": "",
        "attacks": [
            {"name": "高温冲撞", "cost": ["Fire", "Fire"], "damage": "100",
             "text": "给这只宝可梦也造成40伤害。"},
        ],
        "weaknesses": [{"type": "Water", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 古玉鱼 Chi-Yu (svi-chiy)
    "svi-chiy": {
        "name": "古玉鱼", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Fire"], "evolvesFrom": "",
        "attacks": [
            {"name": "闪焰生成", "cost": ["Fire"], "damage": "0",
             "text": "选择自己弃牌区中最多2张基本火能量，附着于自己的1只宝可梦身上。"},
            {"name": "嫉妒业火", "cost": ["Fire", "Fire"], "damage": "50",
             "text": "在上一个对手的回合，如果因为招式的伤害而导致自己的宝可梦昏厥的话，则追加造成90伤害。"},
        ],
        "weaknesses": [{"type": "Water", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 怒鹦哥 Squawkabilly (svi-sqwk)
    "svi-sqwk": {
        "name": "怒鹦哥", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "呼朋引伴", "cost": ["Colorless"], "damage": "0",
             "text": "选择自己牌库中最多2张基础宝可梦，放于备战区。并重洗牌库。"},
            {"name": "飞翔", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "抛掷1次硬币如果为反面，则这个招式失败。如果为正面，则在下一个对手的回合，这只宝可梦不受到招式的伤害和效果影响。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 梅洛可 Meloco (svi-mela)
    "svi-mela": {
        "name": "梅洛可", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["这张卡牌，只有在上一个对手的回合，自己的宝可梦昏厥时才可使用。",
                  "选择自己弃牌区中的1张「基本火能量」，附着于自己的宝可梦身上。然后，从牌库上方抽取卡牌，直到自己的手牌变为6张为止。"],
        "trainer_type": "Supporter",
    },

    # 能量再利用 Energy Recycler (svi-erec)
    "svi-erec": {
        "name": "能量再利用", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["选择自己弃牌区中最多5张基本能量，在给对手看过之后，放回牌库并重洗牌库。"],
        "trainer_type": "Item",
    },

    # ============================================================
    # ⚪ 无色卡组 - 一家鼠ex核心 (用户自定义)
    # ============================================================

    # 长尾怪手 Aipom (svi-aipo)
    "svi-aipo": {
        "name": "长尾怪手", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 60, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "骗取", "cost": ["Colorless"], "damage": "0",
             "text": "从自己牌库上方抽取1张卡牌。"},
            {"name": "掌击", "cost": ["Colorless", "Colorless"], "damage": "20", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 双尾怪手 Ambipom (svi-ambi)
    "svi-ambi": {
        "name": "双尾怪手", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 100, "types": ["Colorless"], "evolvesFrom": "长尾怪手",
        "attacks": [
            {"name": "招来", "cost": ["Colorless"], "damage": "0",
             "text": "从自己牌库上方抽取2张卡牌。"},
            {"name": "长手抛掷", "cost": ["Colorless", "Colorless", "Colorless"], "damage": "0",
             "text": "造成自己手牌张数×20伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 惊角鹿 Stantler (svi-stan)
    "svi-stan": {
        "name": "惊角鹿", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "后踢", "cost": ["Colorless"], "damage": "20", "text": ""},
            {"name": "疯狂俯冲", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "造成对手战斗宝可梦身上附有的能量数量×30点伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 贪心栗鼠 Skwovet (svi-skwv)
    "svi-skwv": {
        "name": "贪心栗鼠", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 60, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "啃咬", "cost": ["Colorless"], "damage": "20", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 藏饱栗鼠 Greedent (svi-gree)
    "svi-gree": {
        "name": "藏饱栗鼠", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 130, "types": ["Colorless"], "evolvesFrom": "贪心栗鼠",
        "attacks": [
            {"name": "招来", "cost": ["Colorless"], "damage": "0",
             "text": "从自己的牌库上方抽取2张卡牌。"},
            {"name": "倾倒一空", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "将自己的手牌全部放于弃牌区。如果将5张以上放于弃牌区，则追加造成150点伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless", "Colorless"], "convertedRetreatCost": 3,
    },

    # 爱管侍 Indeedee (svi-inde) — 无色版
    "svi-inde": {
        "name": "爱管侍", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 90, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "招来", "cost": ["Colorless"], "damage": "0",
             "text": "从自己的牌库上方抽取2张卡牌。"},
            {"name": "妙手强念", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "造成自己手牌张数×10点伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 一对鼠 Tandemaus (svi-tand)
    "svi-tand": {
        "name": "一对鼠", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 40, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "紧贴", "cost": ["Colorless"], "damage": "10", "text": ""},
            {"name": "踢飞", "cost": ["Colorless", "Colorless"], "damage": "20", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 一家鼠ex Maushold ex (svi-maus)
    "svi-maus": {
        "name": "一家鼠ex", "supertype": "Pokémon", "subtypes": ["Stage 1", "ex"],
        "hp": 230, "types": ["Colorless"], "evolvesFrom": "一对鼠",
        "rules": ["宝可梦ex规则：当你的宝可梦ex被击倒时，对手获得2张奖品卡。"],
        "abilities": [
            {"name": "团结一致", "text": "当这只宝可梦在战斗场上受到对手宝可梦的招式的伤害时，将自己场上「一对鼠」和「一家鼠」的数量×3个伤害指示物，放置于使用了招式的宝可梦身上。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "贪婪门牙", "cost": ["Colorless", "Colorless"], "damage": "120",
             "text": "从自己牌库上方抽取2张卡牌。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": [], "convertedRetreatCost": 0,
    },

    # 缠红鹤 Flamigo (svi-flam)
    "svi-flam": {
        "name": "缠红鹤", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "振翅", "cost": ["Colorless"], "damage": "30", "text": ""},
            {"name": "俯冲", "cost": ["Colorless", "Colorless", "Colorless"], "damage": "110",
             "text": "给这只宝可梦也造成20伤害。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 能量签 Energy Sticker (svi-enst)
    "svi-enst": {
        "name": "能量签", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["查看自己牌库上方7张卡牌。选择其中1张能量，在给对手看过之后，加入手牌。将剩余的卡牌放回牌库并重洗牌库。"],
        "trainer_type": "Item",
    },

    # 妮莫的背包 Nemona's Backpack (svi-nemb)
    "svi-nemb": {
        "name": "妮莫的背包", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["选择自己弃牌区中最多2张「妮莫」，在给对手看过之后，加入手牌。"],
        "trainer_type": "Item",
    },

    # 嘉德丽雅 Caitlin (svi-cait)
    "svi-cait": {
        "name": "嘉德丽雅", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["选择自己任意数量的手牌，以任意顺序重新排列，放回牌库下方。然后，从牌库上方抽取与放回牌库的卡牌数量相同张数的卡牌。"],
        "trainer_type": "Supporter",
    },

    # 波琵 Poppy (svi-popp)
    "svi-popp": {
        "name": "波琵", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["选择自己场上1只宝可梦身上附着的最多2个能量，转附于自己的1只其他宝可梦身上。"],
        "trainer_type": "Supporter",
    },

    # 喷射能量 Jet Energy (svi-jete)
    "svi-jete": {
        "name": "喷射能量", "supertype": "Energy", "subtypes": ["Special"],
        "rules": ["只要这张卡牌被附着于宝可梦身上，就被视作1个[C]能量。",
                  "当将这张卡牌从手牌附着于备战宝可梦身上时，将该宝可梦与战斗宝可梦互换。"],
    },

    # 双重涡轮能量 Double Turbo Energy (svi-dtur)
    "svi-dtur": {
        "name": "双重涡轮能量", "supertype": "Energy", "subtypes": ["Special"],
        "rules": ["只要这张卡牌被附着于宝可梦身上，就被视作2个[C]能量。",
                  "身上附有这张卡牌的宝可梦所使用的招式，给对手的宝可梦造成的伤害「-20」。"],
    },

    # 宝藏能量 Treasure Energy (svi-trea)
    "svi-trea": {
        "name": "宝藏能量", "supertype": "Energy", "subtypes": ["Special"],
        "rules": ["只要这张卡牌被附着于宝可梦身上，就被视作1个[C]能量。",
                  "在自己的回合，当从反面朝上的自己的奖赏卡中拿取了这张卡牌时，在加入手牌前，可将这张卡牌附着于自己的宝可梦身上。"],
    },

    # 奇迹能量 Miracle Energy (svi-mirc)
    "svi-mirc": {
        "name": "奇迹能量", "supertype": "Energy", "subtypes": ["Special"],
        "rules": ["只要这张卡牌被附着于宝可梦身上，就被视作1个[C]能量。",
                  "身上附有这张卡牌的宝可梦，在战斗场上受到对手宝可梦的招式的伤害时，从自己的牌库上方抽取1张卡牌。"],
    },

    # ============================================================
    # 🔮 超系新卡组 — 天然雀/天然鸟核心 (用户自定义)
    # ============================================================

    # 天然雀 Natu (sv1-107)
    "sv1-107": {
        "name": "天然雀", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 50, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "三连突刺", "cost": ["Psychic"], "damage": "0",
             "text": "抛掷3次硬币，造成正面次数×10伤害。"},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 天然鸟 Xatu (sv1-108)
    "sv1-108": {
        "name": "天然鸟", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 100, "types": ["Psychic"], "evolvesFrom": "天然雀",
        "abilities": [
            {"name": "以太感知", "text": "在自己的回合可以使用1次。选择自己手牌中的1张「基本超能量」，附着于备战宝可梦身上。然后，从自己牌库上方抽取2张卡牌。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "超念力", "cost": ["Psychic", "Colorless", "Colorless"], "damage": "80", "text": ""},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 月石 Lunatone (sv1-109)
    "sv1-109": {
        "name": "月石", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 90, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "循环抽取", "cost": ["Psychic"], "damage": "0",
             "text": "将自己的1张手牌放于弃牌区。然后，从自己牌库上方抽取3张卡牌。"},
            {"name": "月亮强念", "cost": ["Colorless", "Colorless", "Colorless"], "damage": "30+",
             "text": "追加造成这只宝可梦身上附有的超能量数量×30点伤害。"},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 拉帝亚斯 Latias (sv1-110)
    "sv1-110": {
        "name": "拉帝亚斯", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Psychic"], "evolvesFrom": "",
        "abilities": [
            {"name": "薄雾飘浮", "text": "如果这只宝可梦身上附着了超能量的话，则这只宝可梦撤退所需能量全部消除。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "念动弹", "cost": ["Psychic", "Psychic", "Colorless"], "damage": "100", "text": ""},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 拉帝欧斯 Latios (sv1-111)
    "sv1-111": {
        "name": "拉帝欧斯", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 110, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "滑翔", "cost": ["Colorless"], "damage": "20", "text": ""},
            {"name": "洁净光芒", "cost": ["Psychic", "Psychic", "Colorless"], "damage": "180",
             "text": "选择这只宝可梦身上附着的3个能量，放于弃牌区。"},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 代欧奇希斯 Deoxys (sv1-112)
    "sv1-112": {
        "name": "代欧奇希斯", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 120, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "精神拳", "cost": ["Psychic"], "damage": "30", "text": ""},
            {"name": "基因螺旋", "cost": ["Psychic", "Psychic", "Psychic"], "damage": "120",
             "text": "将这只宝可梦身上附着的所有能量，以任意方式转附于备战宝可梦身上。"},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 克雷色利亚 Cresselia (sv1-113)
    "sv1-113": {
        "name": "克雷色利亚", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 120, "types": ["Psychic"], "evolvesFrom": "",
        "attacks": [
            {"name": "新月生长", "cost": ["Psychic"], "damage": "0",
             "text": "选择自己牌库中的1张超能量，附着于自己的宝可梦身上。并重洗牌库。如果是后攻玩家的最初回合的话，则可附着的张数变为最多3张，附着于自己的1只宝可梦身上。"},
            {"name": "光子镭射", "cost": ["Psychic", "Psychic"], "damage": "30+",
             "text": "如果自己场上有5个以上（包含5个）能量的话，则追加造成90点伤害。"},
        ],
        "weaknesses": [{"type": "Darkness", "value": "×2"}], "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # -------- New Trainers --------

    # 不服输头带 Defiant Band (sv1-201)
    "sv1-201": {
        "name": "不服输头带", "supertype": "Trainer", "subtypes": ["Tool"],
        "rules": ["如果自己的剩余奖赏卡张数，比对手的剩余奖赏卡张数多的话，则身上放有这张卡牌的宝可梦所使用的招式，给对手的战斗宝可梦造成的伤害「+30」。"],
        "trainer_type": "Tool",
    },

    # 勇气护符 Bravery Charm (sv1-202)
    "sv1-202": {
        "name": "勇气护符", "supertype": "Trainer", "subtypes": ["Tool"],
        "rules": ["身上放有这张卡牌的基础宝可梦的最大HP「+50」。"],
        "trainer_type": "Tool",
    },

    # 克拉拉 Clara (sv1-203)
    "sv1-203": {
        "name": "克拉拉", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["选择自己弃牌区中最多2张宝可梦，和最多2张基本能量，在给对手看过之后，加入手牌。（可只选择宝可梦或只选择基本能量。）"],
        "trainer_type": "Supporter",
    },

    # 派帕 Arven (sv1-204)
    "sv1-204": {
        "name": "派帕", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["选择自己牌库中「物品」和「宝可梦道具」各1张，在给对手看过之后，加入手牌。并重洗牌库。"],
        "trainer_type": "Supporter",
    },

    # ============================================================
    # ⚡ 雷系新卡组 — 皮卡丘ex核心 (用户自定义)
    # ============================================================

    # 皮卡丘ex Pikachu ex (svl-pikaex)
    "svl-pikaex": {
        "name": "皮卡丘ex", "supertype": "Pokémon", "subtypes": ["Basic", "ex"],
        "hp": 190, "types": ["Lightning"], "evolvesFrom": "",
        "rules": ["宝可梦ex规则：当你的宝可梦ex被击倒时，对手获得2张奖品卡。"],
        "attacks": [
            {"name": "皮卡拳", "cost": ["Colorless"], "damage": "30", "text": ""},
            {"name": "强劲伏特", "cost": ["Lightning", "Lightning", "Colorless"], "damage": "220",
             "text": "抛掷1次硬币。如果是反面，则将这只宝可梦身上附着的能量全部放于弃牌区。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": [], "convertedRetreatCost": 0,
    },

    # 灯笼鱼 Chinchou (svl-chin)
    "svl-chin": {
        "name": "灯笼鱼", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Lightning"], "evolvesFrom": "",
        "attacks": [
            {"name": "电球", "cost": ["Lightning"], "damage": "10", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 电灯怪 Lanturn (svl-lant)
    "svl-lant": {
        "name": "电灯怪", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 120, "types": ["Lightning"], "evolvesFrom": "灯笼鱼",
        "attacks": [
            {"name": "炫目光束", "cost": ["Lightning", "Colorless"], "damage": "40",
             "text": "在下一个对手的回合，受到这个招式影响的宝可梦在使用招式时，对手将抛掷1次硬币。如果为反面则那个招式失败。"},
            {"name": "电球", "cost": ["Lightning", "Lightning", "Colorless"], "damage": "120", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 咩利羊 Mareep (svl-mare2) — 新版本
    "svl-mare2": {
        "name": "咩利羊", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 60, "types": ["Lightning"], "evolvesFrom": "",
        "attacks": [
            {"name": "后踢", "cost": ["Colorless"], "damage": "10", "text": ""},
            {"name": "电球", "cost": ["Lightning", "Colorless"], "damage": "30", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 茸茸羊 Flaaffy (svl-flaa2) — 新版本
    "svl-flaa2": {
        "name": "茸茸羊", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 90, "types": ["Lightning"], "evolvesFrom": "咩利羊",
        "abilities": [
            {"name": "电气发电机", "text": "在自己的回合可使用1次。选择自己弃牌区中的1张雷能量卡，附着于备战宝可梦身上。", "type": "Ability"},
        ],
        "attacks": [
            {"name": "电球", "cost": ["Lightning", "Lightning", "Colorless"], "damage": "50", "text": ""},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 电飞鼠 Emolga (svl-emol)
    "svl-emol": {
        "name": "电飞鼠", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Lightning"], "evolvesFrom": "",
        "attacks": [
            {"name": "电击", "cost": ["Lightning"], "damage": "30",
             "text": "抛掷1次硬币如果为正面，则使对手的战斗宝可梦陷入麻痹状态。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": [], "convertedRetreatCost": 0,
    },

    # 雷电云 Thundurus (svl-thun)
    "svl-thun": {
        "name": "雷电云", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 120, "types": ["Lightning"], "evolvesFrom": "",
        "attacks": [
            {"name": "辅助电光", "cost": ["Lightning"], "damage": "30",
             "text": "若希望，可选择自己手牌中的1张雷能量卡，附着于备战宝可梦身上。"},
            {"name": "打雷", "cost": ["Lightning", "Lightning", "Colorless"], "damage": "130",
             "text": "给这只宝可梦也造成30点伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 捷拉奥拉 Zeraora (svl-zera)
    "svl-zera": {
        "name": "捷拉奥拉", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 120, "types": ["Lightning"], "evolvesFrom": "",
        "attacks": [
            {"name": "疯狂伏特", "cost": ["Lightning", "Colorless"], "damage": "70",
             "text": "给这只宝可梦也造成20点伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 聒噪鸟 Chatot (svl-chat)
    "svl-chat": {
        "name": "聒噪鸟", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "循环抽取", "cost": ["Colorless"], "damage": "0",
             "text": "将自己的1张手牌放于弃牌区。然后，从自己牌库上方抽取2张卡牌。"},
            {"name": "振翅", "cost": ["Colorless"], "damage": "10", "text": ""},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": [], "convertedRetreatCost": 0,
    },

    # 能量输送 Energy Transfer (svl-ensw)
    "svl-ensw": {
        "name": "能量输送", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["选择自己牌库中的1张基本能量，在给对手看过之后，加入手牌。并重洗牌库。"],
        "trainer_type": "Item",
    },

    # 健行鞋 Trekking Shoes (svl-trks)
    "svl-trks": {
        "name": "健行鞋", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["查看自己牌库上方1张卡牌，将那张卡牌加入手牌。或者，将那张卡牌放于弃牌区，从自己牌库上方抽取1张卡牌。"],
        "trainer_type": "Item",
    },

    # 活力头带 Vitality Band (svl-vitb)
    "svl-vitb": {
        "name": "活力头带", "supertype": "Trainer", "subtypes": ["Tool"],
        "rules": ["身上放有这张卡牌的宝可梦所使用的招式，给对手的战斗宝可梦造成的伤害「+10」。"],
        "trainer_type": "Tool",
    },

    # 希嘉娜的决心 Zinnia's Resolve (svl-zinn)
    "svl-zinn": {
        "name": "希嘉娜的决心", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["这张卡牌，只有将自己的2张手牌放于弃牌区后才可使用。",
                  "从自己的牌库上方抽取与对手场上宝可梦数量相同张数的卡牌。"],
        "trainer_type": "Supporter",
    },

    # ============================================================
    # 套牌1 — 七夕青鸟ex核心（龙/水）新卡
    # ============================================================

    # 青绵鸟 Swablu (svg-swa)
    "svg-swa": {
        "name": "青绵鸟", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 50, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "连续旋转", "cost": ["Colorless"], "damage": "0",
             "text": "抛掷硬币直到出现反面，造成正面次数×20点伤害。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 七夕青鸟ex Altaria ex (svg-alt) — Stage 1 ex, evolves from 青绵鸟
    "svg-alt": {
        "name": "七夕青鸟ex", "supertype": "Pokémon", "subtypes": ["Stage 1", "ex"],
        "hp": 260, "types": ["Dragon"], "evolvesFrom": "青绵鸟",
        "rules": ["宝可梦ex规则：当你的宝可梦ex被击倒时，对手获得2张奖品卡。"],
        "abilities": [
            {"name": "哼唱治愈", "text": "在自己的回合可以使用1次。将自己所有宝可梦的HP，各回复「20」。",
             "type": "Ability"},
        ],
        "attacks": [
            {"name": "光之波动", "cost": ["Water", "Metal"], "damage": "140",
             "text": "在下一个对手的回合，这只宝可梦不受到对手宝可梦所使用招式的效果影响。"},
        ],
        "weaknesses": [], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 老翁龙 Drampa (svg-dram)
    "svg-dram": {
        "name": "老翁龙", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 120, "types": ["Dragon"], "evolvesFrom": "",
        "attacks": [
            {"name": "逆鳞", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "追加造成这只宝可梦身上放置的伤害指示物数量×10伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 米立龙 Tatsugiri Dragon型 (svg-tatsu)
    "svg-tatsu": {
        "name": "米立龙", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Dragon"], "evolvesFrom": "",
        "attacks": [
            {"name": "水枪", "cost": ["Water"], "damage": "20", "text": ""},
            {"name": "生存战略", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "选择自己牌库中任意卡牌最多2张，加入手牌。并重洗牌库。若希望，可将这只宝可梦与备战宝可梦互换。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 大奶罐 Miltank (svg-milt)
    "svg-milt": {
        "name": "大奶罐", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 120, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "活泼冲撞", "cost": ["Colorless", "Colorless"], "damage": "0",
             "text": "在这个回合，如果回复了这只宝可梦的HP的话，则追加造成90伤害。"},
        ],
        "weaknesses": [{"type": "Fighting", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 飘浮泡泡 Castform (svg-cast)
    "svg-cast": {
        "name": "飘浮泡泡", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 70, "types": ["Colorless"], "evolvesFrom": "",
        "attacks": [
            {"name": "双重抽取", "cost": ["Colorless"], "damage": "0",
             "text": "从自己的牌库上方抽取2张卡牌。"},
            {"name": "暴风", "cost": ["Colorless"], "damage": "30",
             "text": "选择附着于这只宝可梦身上的1个基本能量，转附于备战宝可梦身上。"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}],
        "resistances": [{"type": "Fighting", "value": "-30"}],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 走鲸 Cetoddle (svg-ceto)
    "svg-ceto": {
        "name": "走鲸", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 80, "types": ["Water"], "evolvesFrom": "",
        "attacks": [
            {"name": "撞击", "cost": ["Colorless", "Colorless"], "damage": "30", "text": ""},
        ],
        "weaknesses": [{"type": "Metal", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 浩大鲸 Cetitan (svg-ceti) — Stage 1, evolves from 走鲸
    "svg-ceti": {
        "name": "浩大鲸", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 180, "types": ["Water"], "evolvesFrom": "走鲸",
        "attacks": [
            {"name": "头突", "cost": ["Colorless", "Colorless"], "damage": "50", "text": ""},
            {"name": "扫除冲撞", "cost": ["Water", "Colorless", "Colorless"], "damage": "0",
             "text": "这个招式的伤害，会被减少相当于这只宝可梦身上放置的伤害指示物数量×20的数值。"},
        ],
        "weaknesses": [{"type": "Metal", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless", "Colorless"], "convertedRetreatCost": 3,
    },

    # 西餐厨师 Chef (svg-chef)
    "svg-chef": {
        "name": "西餐厨师", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["回复自己的战斗宝可梦「70」点HP。"],
        "trainer_type": "Supporter",
    },

    # 贝里菈 Beri (svg-beri)
    "svg-beri": {
        "name": "贝里菈", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["从自己的牌库上方抽取卡牌，直到自己的手牌张数比对手的手牌张数多1张为止。"],
        "trainer_type": "Supporter",
    },

    # ============================================================
    # 套牌2 — 土台龟核心（草）新卡
    # ============================================================

    # 草苗龟 Turtwig (svg2-turt)
    "svg2-turt": {
        "name": "草苗龟", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 80, "types": ["Grass"], "evolvesFrom": "",
        "attacks": [
            {"name": "咬住", "cost": ["Grass"], "damage": "10", "text": ""},
            {"name": "鲁莽头击", "cost": ["Grass", "Colorless"], "damage": "20", "text": ""},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 树林龟 Grotle (svg2-grot) — Stage 1, evolves from 草苗龟
    "svg2-grot": {
        "name": "树林龟", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 100, "types": ["Grass"], "evolvesFrom": "草苗龟",
        "abilities": [
            {"name": "日光甲壳", "text": "在自己的回合可以使用1次。选择自己牌库中的1张G宝可梦，在给对手看过之后，加入手牌。并重洗牌库。",
             "type": "Ability"},
        ],
        "attacks": [
            {"name": "飞叶快刀", "cost": ["Grass", "Colorless", "Colorless"], "damage": "50", "text": ""},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless", "Colorless"], "convertedRetreatCost": 3,
    },

    # 土台龟 Torterra (svg2-tort) — Stage 2, evolves from 树林龟
    "svg2-tort": {
        "name": "土台龟", "supertype": "Pokémon", "subtypes": ["Stage 2"],
        "hp": 190, "types": ["Grass"], "evolvesFrom": "树林龟",
        "attacks": [
            {"name": "进化压制", "cost": ["Grass", "Colorless"], "damage": "0",
             "text": "造成自己场上进化宝可梦数量×50点伤害。"},
            {"name": "头突", "cost": ["Grass", "Colorless", "Colorless", "Colorless"], "damage": "160", "text": ""},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless", "Colorless", "Colorless"], "convertedRetreatCost": 4,
    },

    # 蘑蘑菇 Shroomish (svg2-shro)
    "svg2-shro": {
        "name": "蘑蘑菇", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 60, "types": ["Grass"], "evolvesFrom": "",
        "attacks": [
            {"name": "吸取", "cost": ["Grass"], "damage": "0",
             "text": "回复这只宝可梦「10」HP。"},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 斗笠菇 Breloom (svg2-brel) — Stage 1, evolves from 蘑蘑菇
    "svg2-brel": {
        "name": "斗笠菇", "supertype": "Pokémon", "subtypes": ["Stage 1"],
        "hp": 110, "types": ["Grass"], "evolvesFrom": "蘑蘑菇",
        "attacks": [
            {"name": "音速直击", "cost": ["Grass"], "damage": "60", "text": ""},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless"], "convertedRetreatCost": 1,
    },

    # 萨戮德 Zarude (svg2-zaru)
    "svg2-zaru": {
        "name": "萨戮德", "supertype": "Pokémon", "subtypes": ["Basic"],
        "hp": 130, "types": ["Grass"], "evolvesFrom": "",
        "attacks": [
            {"name": "唤群之歌", "cost": ["Grass"], "damage": "0",
             "text": "选择自己牌库中的1张G宝可梦，在给对手看过之后，加入手牌。并重洗牌库。如果是后攻玩家的最初回合的话，则可加入手牌的G宝可梦的张数变为最多3张。"},
            {"name": "反复鞭挞", "cost": ["Colorless", "Colorless", "Colorless"], "damage": "0",
             "text": "追加造成这只宝可梦身上附有的G能量数量×20点伤害。"},
        ],
        "weaknesses": [{"type": "Fire", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 帝王拿波 Empoleon (svg2-empo) — Stage 2, evolves from 波皇子
    "svg2-empo": {
        "name": "帝王拿波", "supertype": "Pokémon", "subtypes": ["Stage 2"],
        "hp": 160, "types": ["Water"], "evolvesFrom": "波皇子",
        "abilities": [
            {"name": "紧急上浮", "text": "在自己的回合，如果这张卡牌在弃牌区，且自己没有手牌的话，则可使用1次。将这张卡牌放于备战区。然后，从自己的牌库上方抽取3张卡牌。",
             "type": "Ability"},
        ],
        "attacks": [
            {"name": "水之矢", "cost": ["Water"], "damage": "0",
             "text": "给对手的1只宝可梦，造成60点伤害。[备战宝可梦不计算弱点、抗性。]"},
        ],
        "weaknesses": [{"type": "Lightning", "value": "×2"}], "resistances": [],
        "retreatCost": ["Colorless", "Colorless"], "convertedRetreatCost": 2,
    },

    # 粉碎之锤 Crushing Hammer (svg2-hamm)
    "svg2-hamm": {
        "name": "粉碎之锤", "supertype": "Trainer", "subtypes": ["Item"],
        "rules": ["抛掷1次硬币如果为正面，则选择对手场上宝可梦身上附着的1个能量，放于弃牌区。"],
        "trainer_type": "Item",
    },

    # 学习装置 Exp. Share (svg2-exps)
    "svg2-exps": {
        "name": "学习装置", "supertype": "Trainer", "subtypes": ["Tool"],
        "rules": ["每当自己的战斗宝可梦，受到对手宝可梦的招式的伤害而昏厥时，可选择该战斗宝可梦身上附着的1张基本能量，转附于身上放有这张卡牌的宝可梦身上。"],
        "trainer_type": "Tool",
    },

    # 菜种的活力 Gardenia's Vigor (svg2-gard)
    "svg2-gard": {
        "name": "菜种的活力", "supertype": "Trainer", "subtypes": ["Supporter"],
        "rules": ["从自己牌库上方抽取2张卡牌。然后，选择自己手牌中最多2张G能量，附着于1只备战宝可梦身上。"],
        "trainer_type": "Supporter",
    },

    # 夜光能量 Luminous Energy (svg2-lume)
    "svg2-lume": {
        "name": "夜光能量", "supertype": "Energy", "subtypes": ["Special"],
        "rules": ["只要这张卡牌，被附着于宝可梦身上，就被视作1个所有属性的能量。",
                  "如果身上附着了这张卡牌的宝可梦，身上还附着了除这张卡牌以外的特殊能量的话，则这张卡牌被视作1个普通能量。"],
    },
}

def create_offline_cards(card_ids: list[str]):
    """Create Card objects from offline templates when API is unavailable."""
    from data.card_registry import CardRegistry
    from card_data.card_effects import CARD_EFFECTS

    for card_id in card_ids:
        template = OFFLINE_CARD_TEMPLATES.get(card_id)
        if template is None:
            logger.warning("no offline template for: %s", card_id)
            continue

        # Build Card object
        card = CardRegistry._build_card(template, card_id)
        CardRegistry._cards[card_id] = card
        name_key = card.name.lower()
        if name_key not in CardRegistry._by_name:
            CardRegistry._by_name[name_key] = []
        if card_id not in CardRegistry._by_name[name_key]:
            CardRegistry._by_name[name_key].append(card_id)

    CardRegistry._initialized = True
    logger.info("created %s cards from offline templates.", len(CardRegistry._cards))

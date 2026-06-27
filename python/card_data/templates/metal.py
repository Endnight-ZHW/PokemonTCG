"""Built-in card templates: metal."""

TEMPLATES = {
    "svm-zamazenta": {
        "name": "藏玛然特",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 130,
        "types": ["Metal"],
        "evolvesFrom": "",
        "abilities": [
            {
                "name": "金属之盾",
                "text": "如果这只宝可梦身上附有能量的话，则这只宝可梦所受到的招式的伤害「-30」。",
                "type": "Ability",
            }
        ],
        "attacks": [
            {
                "name": "报仇",
                "cost": ["Metal", "Metal", "Colorless"],
                "damage": "100+",
                "text": "在上一个对手的回合，如果自己的宝可梦昏厥的话，则追加造成120点伤害。",
            }
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless", "Colorless"],
        "convertedRetreatCost": 2,
    },
    "svm-zacian": {
        "name": "苍响",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 130,
        "types": ["Metal"],
        "evolvesFrom": "",
        "attacks": [
            {
                "name": "战斗军团",
                "cost": ["Metal"],
                "damage": "20+",
                "text": "追加造成自己备战宝可梦数量×10点伤害。这个招式的伤害，不计算弱点、以及对手战斗宝可梦身上所附加的效果。",
            },
            {
                "name": "薄片利刃",
                "cost": ["Metal", "Colorless", "Colorless"],
                "damage": "100",
                "text": "",
            },
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless", "Colorless"],
        "convertedRetreatCost": 2,
    },
    "svm-smeargle": {
        "name": "图图犬",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 70,
        "types": ["Colorless"],
        "evolvesFrom": "",
        "attacks": [
            {
                "name": "多彩调色盘",
                "cost": ["Colorless"],
                "damage": "0",
                "text": "查看自己牌库上方5张卡牌，选择其中任意数量的基本能量，附着于自己的1只宝可梦身上。将剩余的卡牌放回牌库并重洗牌库。",
            },
            {
                "name": "冲撞",
                "cost": ["Colorless", "Colorless"],
                "damage": "30",
                "text": "",
            },
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless"],
        "convertedRetreatCost": 1,
    },
    "svm-bronzor": {
        "name": "铜镜怪",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 60,
        "types": ["Metal"],
        "evolvesFrom": "",
        "attacks": [
            {
                "name": "金属压制",
                "cost": ["Metal", "Colorless"],
                "damage": "20",
                "text": "抛掷1次硬币如果为正面，则使对手的战斗宝可梦陷入麻痹状态。",
            }
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless"],
        "convertedRetreatCost": 1,
    },
    "svm-bronzong": {
        "name": "青铜钟",
        "supertype": "Pokémon",
        "subtypes": ["Stage 1"],
        "hp": 110,
        "types": ["Metal"],
        "evolvesFrom": "铜镜怪",
        "abilities": [
            {
                "name": "金属转移",
                "text": "在自己的回合可以使用任意次。选择附着于自己场上宝可梦身上的1个M能量，转附于自己其他宝可梦身上。",
                "type": "Ability",
            }
        ],
        "attacks": [
            {
                "name": "意念头锤",
                "cost": ["Metal", "Colorless", "Colorless"],
                "damage": "70",
                "text": "",
            }
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless", "Colorless", "Colorless"],
        "convertedRetreatCost": 3,
    },
    "svm-skarmory": {
        "name": "盔甲鸟",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 120,
        "types": ["Metal"],
        "evolvesFrom": "",
        "attacks": [
            {"name": "啄", "cost": ["Colorless"], "damage": "20", "text": ""},
            {
                "name": "钢铁之刃",
                "cost": ["Metal", "Metal", "Colorless"],
                "damage": "120",
                "text": "在下一个自己的回合，这只宝可梦无法使用「钢铁之刃」。",
            },
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless"],
        "convertedRetreatCost": 1,
    },
    "svm-cobalion": {
        "name": "勾帕路翁",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 120,
        "types": ["Metal"],
        "evolvesFrom": "",
        "abilities": [
            {
                "name": "正义法则",
                "text": "只要这只宝可梦在场上，自己的基础宝可梦使用的招式，给对手战斗场上的D宝可梦造成的伤害「+30」。",
                "type": "Ability",
            }
        ],
        "attacks": [
            {
                "name": "跟进",
                "cost": ["Colorless", "Colorless"],
                "damage": "30",
                "text": "选择自己最多2只备战宝可梦，各附着1张牌库中的基本能量。并重洗牌库。",
            }
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless", "Colorless"],
        "convertedRetreatCost": 2,
    },
    "svm-dialga": {
        "name": "帝牙卢卡",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 130,
        "types": ["Metal"],
        "evolvesFrom": "",
        "attacks": [
            {
                "name": "时之逆流",
                "cost": ["Metal"],
                "damage": "0",
                "text": "选择自己弃牌区中任意1张卡牌，在给对手看过之后，加入手牌。",
            },
            {
                "name": "金属爆破",
                "cost": ["Colorless", "Colorless", "Colorless"],
                "damage": "60+",
                "text": "追加造成这只宝可梦身上附有的M能量数量×20点伤害。",
            },
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless", "Colorless"],
        "convertedRetreatCost": 2,
    },
    "svm-klefki": {
        "name": "钥圈儿",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 70,
        "types": ["Metal"],
        "evolvesFrom": "",
        "attacks": [
            {
                "name": "解锁",
                "cost": ["Colorless"],
                "damage": "10",
                "text": "从自己的牌库上方抽取2张卡牌。",
            }
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless"],
        "convertedRetreatCost": 1,
    },
    "svm-orthworm": {
        "name": "拖拖蚓",
        "supertype": "Pokémon",
        "subtypes": ["Basic"],
        "hp": 130,
        "types": ["Metal"],
        "evolvesFrom": "",
        "abilities": [
            {
                "name": "营养铁质",
                "text": "如果这只宝可梦身上附着了3个及以上M能量的话，则这只宝可梦的最大HP「+100」。",
                "type": "Ability",
            }
        ],
        "attacks": [
            {
                "name": "刺穿",
                "cost": ["Colorless", "Colorless", "Colorless", "Colorless"],
                "damage": "100",
                "text": "给对手的1只备战宝可梦，也造成30伤害。[备战宝可梦不计算弱点、抗性。]",
            }
        ],
        "weaknesses": [],
        "resistances": [],
        "retreatCost": ["Colorless", "Colorless"],
        "convertedRetreatCost": 2,
    },
}

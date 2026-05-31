"""Manual effect definitions for each card in the pool.
Maps card API ID -> attack/ability/trainer effect specifications.
Attack names are in Chinese to match the card registry templates.

IMPORTANT: Base damage is handled by action_resolver._declare_attack
using the attack's damage value from the card template. Effects here should
ONLY define ADDITIONAL effects beyond base damage (status, coin flips,
energy manipulation, bench damage, etc.).

Cards are based on real Pokemon TCG Scarlet & Violet era data.
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CARD_EFFECTS: dict[str, dict] = {}

# ============================================================
# 💧 水系卡组宝可梦 - Water Deck Pokemon
# ============================================================

# 拉普拉斯 Lapras (sv1-49) - 愤怒冷冻: conditional paralyze
CARD_EFFECTS["sv1-49"] = {
    "attacks": {
        "愤怒冷冻": {
            "effects": [
                {"effect_type": "conditional_status",
                 "params": {"status": "paralyzed", "target": "opponent_active",
                           "condition": "ko_by_attack_last_turn"}},
            ]
        },
    }
}

# 甲贺忍蛙ex Greninja ex (sv2-grex)
CARD_EFFECTS["sv2-grex"] = {
    "attacks": {
        "隐蔽手里剑": {
            "effects": [
                {"effect_type": "any_pokemon_damage",
                 "params": {"amount": 40, "player": "opponent", "piercing_on_bench": True}},
            ]
        },
        "激流斩": {
            "effects": [
                {"effect_type": "conditional_damage_bonus",
                 "params": {"bonus": 120, "condition": "opponent_active_damaged"}},
            ]
        },
    }
}

# 凯路迪欧 Keldeo (sv2-keldeo)
CARD_EFFECTS["sv2-keldeo"] = {
    "attacks": {
        "踢飞": {"effects": []},
        "队列之力": {
            "effects": [
                {"effect_type": "damage_plus_bench",
                 "params": {"base": 10, "per_bench": 20, "count_own_bench": True}},
            ]
        },
    }
}

# 雪暴马 Glastrier (sv2-glast)
CARD_EFFECTS["sv2-glast"] = {
    "attacks": {
        "冻结": {
            "effects": [
                {"effect_type": "attack_lock_basic",
                 "params": {"target": "opponent_active"}},
            ]
        },
        "疯狂冲撞": {
            "effects": [
                {"effect_type": "damage_counter_self", "params": {"amount": 30}},
            ]
        },
    }
}

# 米立龙 Tatsugiri (sv2-tatsu)
CARD_EFFECTS["sv2-tatsu"] = {
    "attacks": {
        "预先准备": {
            "effects": [
                {"effect_type": "energy_attach",
                 "params": {"amount": 2, "from_zone": "deck", "filter": "water", "to": "self_basic"}},
            ]
        },
        "上弓折返": {
            "effects": [
                {"effect_type": "return_to_hand",
                 "params": {}},
            ]
        },
    }
}

# 信使鸟 Delibird (sv2-delib)
CARD_EFFECTS["sv2-delib"] = {
    "attacks": {
        "双重抽取": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
        "冰之翼": {"effects": []},
    }
}

# 海星星 Staryu (sv2-staryu)
CARD_EFFECTS["sv2-staryu"] = {
    "attacks": {
        "高速星星": {
            "effects": [
                {"effect_type": "piercing_marker", "params": {"ignore_weakness": True, "ignore_resistance": True, "ignore_effects": True}},
            ]
        },
    }
}

# 宝石海星 Starmie (sv2-starm)
CARD_EFFECTS["sv2-starm"] = {
    "abilities": {
        "神秘彗星": {
            "trigger": "",
            "effects": [
                {"effect_type": "place_counters_and_self_ko",
                 "params": {"counters": 2, "target": "opponent_any"}},
            ]
        },
    },
    "attacks": {
        "高速攻击": {"effects": []},
    }
}

# 短裤小子 Youngster (sv2-young) - Supporter: shuffle hand into deck, draw 5
CARD_EFFECTS["sv2-young"] = {
    "trainer_effect": {
        "effect_type": "shuffle_draw",
        "params": {"shuffle_hand": True, "draw": 5, "affect": "self_only"}
    }
}

# 小菘 Candice (sv2-cand) - Supporter: look top 7, take water pokemon + water energy
CARD_EFFECTS["sv2-cand"] = {
    "trainer_effect": {
        "effect_type": "look_top_deck",
        "params": {"count": 7, "take": 99, "rest_bottom": True,
                   "filter": "water_pokemon_and_energy"}
    }
}

# 宝可梦捕捉器 Pokemon Catcher (sv2-catch) - Item: coin flip -> switch opponent
CARD_EFFECTS["sv2-catch"] = {
    "trainer_effect": {
        "effect_type": "coin_flip",
        "params": {
            "on_heads": [{"effect_type": "switch_opponent",
                        "params": {"you_choose": True}}],
            "on_tails": [],
        }
    }
}

# ============================================================
# 🔮 超系卡组宝可梦 - Psychic Deck Pokemon (Gardevoir ex)
# ============================================================

# 墓仔狗 Greavard (sv1-104)
CARD_EFFECTS["sv1-104"] = {
    "attacks": {
        "啃咬": {"effects": []},
        "幽魂射击": {"effects": []},
    }
}

# 墓扬犬 Houndstone (sv1-106)
CARD_EFFECTS["sv1-106"] = {
    "attacks": {
        "扫墓": {
            "effects": [
                {"effect_type": "damage_per_discard_psychic",
                 "params": {"base": 80, "per_card": 10}},
            ]
        },
    }
}


# ============================================================
# 🃏 训练家卡 - Trainer Cards
# ============================================================

# 博士的研究 Professor's Research (sv1-189) - Discard hand, draw 7
CARD_EFFECTS["sv1-189"] = {
    "trainer_effect": {
        "effect_type": "discard_draw",
        "params": {"discard_hand": True, "draw": 7}
    }
}

# 裁判 Judge (sv1-176) - Both players shuffle hand into deck, draw 4
CARD_EFFECTS["sv1-176"] = {
    "trainer_effect": {
        "effect_type": "judge",
        "params": {"draw": 4}
    }
}

# 妮莫 Nemona (sv1-180) - Draw 3
CARD_EFFECTS["sv1-180"] = {
    "trainer_effect": {
        "effect_type": "draw",
        "params": {"amount": 3, "player": "self"}
    }
}

# 宝可梦交替 Switch (sv1-150) - Switch self active with bench
CARD_EFFECTS["sv1-150"] = {
    "trainer_effect": {
        "effect_type": "switch_self",
        "params": {}
    }
}

# 巢穴球 Nest Ball (sv1-151) - Search basic Pokemon to bench
CARD_EFFECTS["sv1-151"] = {
    "trainer_effect": {
        "effect_type": "search",
        "params": {"from_zone": "deck", "filter": "basic_pokemon",
                    "destination": "bench", "reveal": True, "count": 1}
    }
}

# 神奇糖果 Rare Candy (sv1-152) - Evolve Basic to Stage 2
CARD_EFFECTS["sv1-152"] = {
    "trainer_effect": {
        "effect_type": "evolve_skip_stage",
        "params": {"skip_to": "stage2"}
    }
}

# 高级球 Ultra Ball (sv1-153) - Discard 2, search Pokemon to hand
CARD_EFFECTS["sv1-153"] = {
    "trainer_effect": {
        "effect_type": "conditional",
        "params": {
            "cost": {"effect_type": "discard", "params": {"amount": 2, "from": "hand"}},
            "on_pay": {"effect_type": "search",
                       "params": {"from_zone": "deck", "filter": "pokemon",
                                  "destination": "hand", "reveal": True, "count": 1}}
        }
    }
}

# 厉害钓竿 Super Rod (sv3-134) - Choose up to 3 Pokemon+Energy from discard, shuffle to deck
CARD_EFFECTS["sv3-134"] = {
    "trainer_effect": {
        "effect_type": "shuffle_from_discard",
        "params": {"count": 3, "filter": "pokemon_and_energy"}
    }
}

# 电气发生器 Electric Generator (sv1-170) - Look top 5, attach up to 2 lightning energy to bench
CARD_EFFECTS["sv1-170"] = {
    "trainer_effect": {
        "effect_type": "look_top_deck",
        "params": {"count": 5, "take": 2, "rest_bottom": True,
                   "filter": "lightning_energy", "destination": "bench_energy"}
    }
}

# 能量回收 Energy Retrieval (sv1-171) - Get up to 2 basic energy from discard to hand
CARD_EFFECTS["sv1-171"] = {
    "trainer_effect": {
        "effect_type": "search",
        "params": {"from_zone": "discard", "filter": "basic_energy",
                    "destination": "hand", "count": 2, "reveal": True}
    }
}

# ============================================================
# ⚡ 基本能量卡 - Basic Energy Cards
# ============================================================

for energy_id in [
    "sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4",
    "sv1-ener-5", "sv1-ener-6", "sv1-ener-8",
]:
    CARD_EFFECTS[energy_id] = {}

# ============================================================
# 🔥 火系新卡组 - 烈焰猴核心 (用户自定义)
# ============================================================

# 小火焰猴 Chimchar (svi-chim) - 火花: 30 damage, discard 1 energy from self
CARD_EFFECTS["svi-chim"] = {
    "attacks": {
        "火花": {
            "effects": [
                {"effect_type": "energy_discard",
                 "params": {"amount": 1, "from": "self", "filter": "any"}},
            ]
        },
    }
}

# 猛火猴 Monferno (svi-monf) - 火焰: 30, no effect. 喷射火焰: 50, discard 1 energy
CARD_EFFECTS["svi-monf"] = {
    "attacks": {
        "火焰": {"effects": []},
        "喷射火焰": {
            "effects": [
                {"effect_type": "energy_discard",
                 "params": {"amount": 1, "from": "self", "filter": "any"}},
            ]
        },
    }
}

# 烈焰猴 Infernape (svi-infr) - 螺旋业火: mill 5, 80× per energy. 燃烧踢: 160, discard all energy
CARD_EFFECTS["svi-infr"] = {
    "attacks": {
        "螺旋业火": {
            "effects": [
                {"effect_type": "mill_and_damage_per_energy",
                 "params": {"mill_count": 5, "damage_per": 80}},
            ]
        },
        "燃烧踢": {
            "effects": [
                {"effect_type": "energy_discard",
                 "params": {"amount": 99, "from": "self", "filter": "any"}},
            ]
        },
    }
}

# 炎帝 Entei (svi-ente) - 压迫感: aura -20 (handled in action_resolver). 火焰之球: 60+ per fire energy
CARD_EFFECTS["svi-ente"] = {
    "abilities": {
        "压迫感": {
            "trigger": "passive",
            "text": "只要这只宝可梦在战斗场上，对手战斗宝可梦使用的招式伤害「-20」。",
            "effects": [
                {"effect_type": "aura_damage_reduction",
                 "params": {"reduction": 20}},
            ]
        },
    },
    "attacks": {
        "火焰之球": {
            "effects": [
                {"effect_type": "damage_per_self_energy",
                 "params": {"base": 60, "per_energy": 20, "energy_filter": "fire"}},
            ]
        },
    }
}

# 加热洛托姆 Heat Rotom (svi-hrot) - 高温冲撞: 100, self 40 damage
CARD_EFFECTS["svi-hrot"] = {
    "attacks": {
        "高温冲撞": {
            "effects": [
                {"effect_type": "damage_counter_self",
                 "params": {"amount": 40}},
            ]
        },
    }
}

# 古玉鱼 Chi-Yu (svi-chiy) - 闪焰生成: attach 2 fire from discard. 嫉妒业火: 50 + 90 if KO'd last turn
CARD_EFFECTS["svi-chiy"] = {
    "attacks": {
        "闪焰生成": {
            "effects": [
                {"effect_type": "attach_from_discard",
                 "params": {"amount": 2, "energy_type": "fire", "target": "self_or_bench"}},
            ]
        },
        "嫉妒业火": {
            "effects": [
                {"effect_type": "conditional_damage_bonus",
                 "params": {"bonus": 90, "condition": "ko_by_attack_last_turn"}},
            ]
        },
    }
}

# 怒鹦哥 Squawkabilly (svi-sqwk) - 呼朋引伴: search 2 basics to bench. 飞翔: coin flip -> prevent_all or fail
CARD_EFFECTS["svi-sqwk"] = {
    "attacks": {
        "呼朋引伴": {
            "effects": [
                {"effect_type": "search",
                 "params": {"from_zone": "deck", "filter": "basic_pokemon",
                           "destination": "bench", "reveal": True, "count": 2}},
            ]
        },
        "飞翔": {
            "effects": [
                {"effect_type": "coin_flip",
                 "params": {
                     "on_heads": [
                         {"effect_type": "damage", "params": {"amount": 60, "target": "opponent_active"}},
                         {"effect_type": "prevent_all", "params": {}},
                     ],
                     "on_tails": [{"effect_type": "attack_fail", "params": {}}],
                 }},
            ]
        },
    }
}

# 梅洛可 Meloco (svi-mela) - 条件：上回被击倒→弃牌区附1火能+抽到6张
CARD_EFFECTS["svi-mela"] = {
    "trainer_effect": {
        "effect_type": "conditional",
        "params": {
            "condition": "ko_by_attack_last_turn",
            "cost": None,
            "on_pay": [
                {"effect_type": "attach_from_discard",
                 "params": {"amount": 1, "energy_type": "fire", "target": "self_or_bench"}},
                {"effect_type": "draw_until",
                 "params": {"target_hand_size": 6}},
            ]
        }
    }
}

# 能量再利用 Energy Recycler (svi-erec) - shuffle up to 5 basic energy from discard to deck
CARD_EFFECTS["svi-erec"] = {
    "trainer_effect": {
        "effect_type": "shuffle_from_discard",
        "params": {"count": 5, "filter": "basic_energy"}
    }
}

# ============================================================
# ⚪ 无色卡组 - 一家鼠ex核心 (用户自定义)
# ============================================================

# 长尾怪手 Aipom (svi-aipo) - 骗取: draw 1, 掌击: 20 no effect
CARD_EFFECTS["svi-aipo"] = {
    "attacks": {
        "骗取": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 1, "player": "self"}},
            ]
        },
        "掌击": {"effects": []},
    }
}

# 双尾怪手 Ambipom (svi-ambi) - 招来: draw 2, 长手抛掷: hand_size ×20
CARD_EFFECTS["svi-ambi"] = {
    "attacks": {
        "招来": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
        "长手抛掷": {
            "effects": [
                {"effect_type": "damage_per_hand_size",
                 "params": {"per": 20}},
            ]
        },
    }
}

# 惊角鹿 Stantler (svi-stan) - 后踢: 20 no effect, 疯狂俯冲: opponent active energy ×30
CARD_EFFECTS["svi-stan"] = {
    "attacks": {
        "后踢": {"effects": []},
        "疯狂俯冲": {
            "effects": [
                {"effect_type": "damage_per_energy",
                 "params": {"base": 0, "per_energy": 30, "count_from": "opponent_active",
                           "target": "opponent_active"}},
            ]
        },
    }
}

# 贪心栗鼠 Skwovet (svi-skwv) - 啃咬: 20 no effect
CARD_EFFECTS["svi-skwv"] = {
    "attacks": {
        "啃咬": {"effects": []},
    }
}

# 藏饱栗鼠 Greedent (svi-gree) - 招来: draw 2, 倾倒一空: discard all hand → 60 + 150 if ≥5
CARD_EFFECTS["svi-gree"] = {
    "attacks": {
        "招来": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
        "倾倒一空": {
            "effects": [
                {"effect_type": "discard_hand_conditional_bonus",
                 "params": {"threshold": 5, "base_damage": 60, "bonus": 150}},
            ]
        },
    }
}

# 爱管侍 Indeedee (svi-inde) - 招来: draw 2, 妙手强念: hand_size ×10
CARD_EFFECTS["svi-inde"] = {
    "attacks": {
        "招来": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
        "妙手强念": {
            "effects": [
                {"effect_type": "damage_per_hand_size",
                 "params": {"per": 10}},
            ]
        },
    }
}

# 一对鼠 Tandemaus (svi-tand) - 紧贴: 10, 踢飞: 20
CARD_EFFECTS["svi-tand"] = {
    "attacks": {
        "紧贴": {"effects": []},
        "踢飞": {"effects": []},
    }
}

# 一家鼠ex Maushold ex (svi-maus) - 团结一致: reactive thorns (handled in action_resolver)
# 贪婪门牙: 120 + draw 2
CARD_EFFECTS["svi-maus"] = {
    "abilities": {
        "团结一致": {
            "trigger": "on_damaged",
            "effects": [
                {"effect_type": "reactive_thorns",
                 "params": {"filter_names": ["一对鼠", "一家鼠ex", "一家鼠"], "per_pokemon": 3}},
            ]
        },
    },
    "attacks": {
        "贪婪门牙": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
    }
}

# 缠红鹤 Flamigo (svi-flam) - 振翅: 30, 俯冲: 110 + self 20 damage
CARD_EFFECTS["svi-flam"] = {
    "attacks": {
        "振翅": {"effects": []},
        "俯冲": {
            "effects": [
                {"effect_type": "damage_counter_self",
                 "params": {"amount": 20}},
            ]
        },
    }
}

# 能量签 Energy Sticker (svi-enst) - look top 7, take 1 energy, shuffle rest back
CARD_EFFECTS["svi-enst"] = {
    "trainer_effect": {
        "effect_type": "look_top_deck",
        "params": {"count": 7, "take": 1, "filter": "energy",
                   "destination": "hand", "shuffle_rest": True}
    }
}

# 妮莫的背包 Nemona's Backpack (svi-nemb) - search discard for up to 2 妮莫
CARD_EFFECTS["svi-nemb"] = {
    "trainer_effect": {
        "effect_type": "search",
        "params": {"from_zone": "discard", "filter": "any", "filter_name": "妮莫",
                  "destination": "hand", "reveal": True, "count": 2}
    }
}

# 嘉德丽雅 Caitlin (svi-cait) - put any hand cards to bottom, draw equal
CARD_EFFECTS["svi-cait"] = {
    "trainer_effect": {
        "effect_type": "hand_to_bottom_draw",
        "params": {}
    }
}

# 波琵 Poppy (svi-popp) - move up to 2 energy from one Pokemon to another
CARD_EFFECTS["svi-popp"] = {
    "trainer_effect": {
        "effect_type": "energy_relocate",
        "params": {"amount": 2}
    }
}

# 喷射能量 Jet Energy (svi-jete) - 1C, switch on attach to bench (handled in action_resolver)
CARD_EFFECTS["svi-jete"] = {}

# 双重涡轮能量 Double Turbo Energy (svi-dtur) - 2C, damage -20 (handled in action_resolver)
CARD_EFFECTS["svi-dtur"] = {}

# 宝藏能量 Treasure Energy (svi-trea) - 1C, on prize take attach (MVP: basic energy effect)
CARD_EFFECTS["svi-trea"] = {}

# 奇迹能量 Miracle Energy (svi-mirc) - 1C, draw on taking damage (handled in action_resolver)
CARD_EFFECTS["svi-mirc"] = {}

# ============================================================
# 🔮 超系新卡组 — 天然雀/天然鸟核心 (用户自定义)
# ============================================================

# 天然雀 Natu (sv1-107) - 三连突刺: 3 coin flips, 10×heads
CARD_EFFECTS["sv1-107"] = {
    "attacks": {
        "三连突刺": {
            "effects": [
                {"effect_type": "coin_flip_triple",
                 "params": {"flips": 3, "damage_per_head": 10}},
            ]
        },
    }
}

# 天然鸟 Xatu (sv1-108) - 以太感知: attach 1 basic Psychic energy from hand to bench + draw 2
CARD_EFFECTS["sv1-108"] = {
    "abilities": {
        "以太感知": {
            "trigger": "",
            "effects": [
                {"effect_type": "energy_attach",
                 "params": {"amount": 1, "from_zone": "hand", "filter": "psychic", "to": "bench"}},
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
    },
    "attacks": {
        "超念力": {"effects": []},
    }
}

# 月石 Lunatone (sv1-109) - 循环抽取: discard 1 hand, draw 3. 月亮强念: 30 + psychic energy ×30
CARD_EFFECTS["sv1-109"] = {
    "attacks": {
        "循环抽取": {
            "effects": [
                {"effect_type": "discard_then_draw",
                 "params": {"discard_amount": 1, "draw_amount": 3}},
            ]
        },
        "月亮强念": {
            "effects": [
                {"effect_type": "damage_per_self_energy",
                 "params": {"base": 30, "per_energy": 30, "energy_filter": "psychic"}},
            ]
        },
    }
}

# 拉帝亚斯 Latias (sv1-110) - 薄雾飘浮: 0 retreat if Psychic energy attached
CARD_EFFECTS["sv1-110"] = {
    "abilities": {
        "薄雾飘浮": {
            "trigger": "passive",
            "text": "如果这只宝可梦身上附着了超能量的话，则这只宝可梦撤退所需能量全部消除。",
            "effects": [
                {"effect_type": "conditional_zero_retreat",
                 "params": {"energy_type": "psychic"}},
            ]
        },
    },
    "attacks": {
        "念动弹": {"effects": []},
    }
}

# 拉帝欧斯 Latios (sv1-111) - 洁净光芒: 180, discard 3 energy from self
CARD_EFFECTS["sv1-111"] = {
    "attacks": {
        "滑翔": {"effects": []},
        "洁净光芒": {
            "effects": [
                {"effect_type": "energy_discard",
                 "params": {"amount": 3, "from": "self", "filter": "any"}},
            ]
        },
    }
}

# 代欧奇希斯 Deoxys (sv1-112) - 基因螺旋: 120, move all energy to bench
CARD_EFFECTS["sv1-112"] = {
    "attacks": {
        "精神拳": {"effects": []},
        "基因螺旋": {
            "effects": [
                {"effect_type": "energy_relocate",
                 "params": {"amount": 99, "from_self": True}},
            ]
        },
    }
}

# 克雷色利亚 Cresselia (sv1-113) - 新月生长: search deck for P energy, attach
# 后攻最初回合可最多3张。光子镭射: 30 + 90 if 5+ energy on field
CARD_EFFECTS["sv1-113"] = {
    "attacks": {
        "新月生长": {
            "effects": [
                {"effect_type": "energy_attach",
                 "params": {"amount": 1, "from_zone": "deck", "filter": "psychic", "to": "any",
                           "going_second_bonus": 3}},
            ]
        },
        "光子镭射": {
            "effects": [
                {"effect_type": "conditional_damage_bonus",
                 "params": {"bonus": 90, "condition": "field_energy_ge_5"}},
            ]
        },
    }
}

# 咚咚鼠 Dedenne (sv1-114) - 小使者: search deck for up to 2 basic energy. 旋转折返: 50 + switch self
CARD_EFFECTS["sv1-114"] = {
    "attacks": {
        "小使者": {
            "effects": [
                {"effect_type": "search",
                 "params": {"from_zone": "deck", "filter": "basic_energy",
                           "destination": "hand", "count": 2, "reveal": True}},
            ]
        },
        "旋转折返": {
            "effects": [
                {"effect_type": "switch_self",
                 "params": {}},
            ]
        },
    }
}

# 不服输头带 Defiant Band (sv1-201) - 复用反抗头巾效果
CARD_EFFECTS["sv1-201"] = {
    "trainer_effect": {
        "effect_type": "tool",
        "params": {"effect": "damage_boost_when_behind"}
    }
}

# 勇气护符 Bravery Charm (sv1-202) - 基础宝可梦HP+50
CARD_EFFECTS["sv1-202"] = {
    "trainer_effect": {
        "effect_type": "tool",
        "params": {"effect": "hp_boost_basic"}
    }
}

# 克拉拉 Clara (sv1-203) - 从弃牌区回收最多2张宝可梦+最多2张基本能量到手中
CARD_EFFECTS["sv1-203"] = {
    "trainer_effect": {
        "effect_type": "clara",
        "params": {"pokemon_count": 2, "energy_count": 2}
    }
}

# 派帕 Arven (sv1-204) - 从牌库搜索1张物品+1张道具加入手牌
CARD_EFFECTS["sv1-204"] = {
    "trainer_effect": {
        "effect_type": "arven",
        "params": {}
    }
}

# ============================================================
# ⚡ 雷系新卡组 — 皮卡丘ex核心 (用户自定义)
# ============================================================

# 皮卡丘ex Pikachu ex (svl-pikaex) - 皮卡拳: 30 no effect. 强劲伏特: 220, coin flip tails→discard all energy
CARD_EFFECTS["svl-pikaex"] = {
    "attacks": {
        "皮卡拳": {"effects": []},
        "强劲伏特": {
            "effects": [
                {"effect_type": "coin_flip",
                 "params": {
                     "on_heads": [],
                     "on_tails": [{"effect_type": "energy_discard",
                                  "params": {"amount": 99, "from": "self", "filter": "any"}}],
                 }},
            ]
        },
    }
}

# 灯笼鱼 Chinchou (svl-chin) - 电球: 10 no effect
CARD_EFFECTS["svl-chin"] = {
    "attacks": {
        "电球": {"effects": []},
    }
}

# 电灯怪 Lanturn (svl-lant) - 炫目光束: 40 + dazzling marker on opponent. 电球: 120 no effect
CARD_EFFECTS["svl-lant"] = {
    "attacks": {
        "炫目光束": {
            "effects": [
                {"effect_type": "dazzling_beam",
                 "params": {"target": "opponent_active"}},
            ]
        },
        "电球": {"effects": []},
    }
}

# 咩利羊 Mareep (svl-mare2) - 后踢: 10 no effect. 电球: 30 no effect
CARD_EFFECTS["svl-mare2"] = {
    "attacks": {
        "后踢": {"effects": []},
        "电球": {"effects": []},
    }
}

# 茸茸羊 Flaaffy (svl-flaa2) - 电气发电机 ability: attach 1 lightning from discard to bench
CARD_EFFECTS["svl-flaa2"] = {
    "abilities": {
        "电气发电机": {
            "trigger": "",
            "effects": [
                {"effect_type": "attach_from_discard",
                 "params": {"amount": 1, "energy_type": "lightning", "target": "bench"}},
            ]
        },
    },
    "attacks": {
        "电球": {"effects": []},
    }
}

# 电飞鼠 Emolga (svl-emol) - 电击: 30 + coin flip → paralysis
CARD_EFFECTS["svl-emol"] = {
    "attacks": {
        "电击": {
            "effects": [
                {"effect_type": "coin_flip",
                 "params": {
                     "on_heads": [{"effect_type": "status",
                                  "params": {"status": "paralyzed", "target": "opponent_active"}}],
                     "on_tails": [],
                 }},
            ]
        },
    }
}

# 雷电云 Thundurus (svl-thun) - 辅助电光: 30 + optional attach L from hand to bench. 打雷: 130 + self 30
CARD_EFFECTS["svl-thun"] = {
    "attacks": {
        "辅助电光": {
            "effects": [
                {"effect_type": "energy_attach",
                 "params": {"amount": 1, "from_zone": "hand", "filter": "lightning", "to": "bench", "optional": True}},
            ]
        },
        "打雷": {
            "effects": [
                {"effect_type": "damage_counter_self", "params": {"amount": 30}},
            ]
        },
    }
}

# 捷拉奥拉 Zeraora (svl-zera) - 疯狂伏特: 70 + self 20 damage
CARD_EFFECTS["svl-zera"] = {
    "attacks": {
        "疯狂伏特": {
            "effects": [
                {"effect_type": "damage_counter_self", "params": {"amount": 20}},
            ]
        },
    }
}

# 聒噪鸟 Chatot (svl-chat) - 循环抽取: discard 1 draw 2. 振翅: 10 no effect
CARD_EFFECTS["svl-chat"] = {
    "attacks": {
        "循环抽取": {
            "effects": [
                {"effect_type": "discard_then_draw",
                 "params": {"discard_amount": 1, "draw_amount": 2}},
            ]
        },
        "振翅": {"effects": []},
    }
}

# 能量输送 Energy Transfer (svl-ensw) - search deck for 1 basic energy, reveal, add to hand
CARD_EFFECTS["svl-ensw"] = {
    "trainer_effect": {
        "effect_type": "search",
        "params": {"from_zone": "deck", "filter": "basic_energy",
                    "destination": "hand", "count": 1, "reveal": True}
    }
}

# 健行鞋 Trekking Shoes (svl-trks) - look top 1, choice: add to hand OR discard and draw 1
CARD_EFFECTS["svl-trks"] = {
    "trainer_effect": {
        "effect_type": "trekking_shoes",
        "params": {}
    }
}

# 活力头带 Vitality Band (svl-vitb) - attached Pokemon's attacks do +10 damage
CARD_EFFECTS["svl-vitb"] = {
    "trainer_effect": {
        "effect_type": "tool",
        "params": {"effect": "damage_boost_10"}
    }
}

# 希嘉娜的决心 Zinnia's Resolve (svl-zinn) - discard 2, draw = opponent's Pokemon count
CARD_EFFECTS["svl-zinn"] = {
    "trainer_effect": {
        "effect_type": "zinnia_resolve",
        "params": {}
    }
}

# ============================================================
# 💧 水系卡牌效果更新
# ============================================================

# 呱呱泡蛙 Froakie (sv2-38) - 跳一下: 30, coin flip tails→attack fails
CARD_EFFECTS["sv2-38"] = {
    "attacks": {
        "跳一下": {
            "effects": [
                {"effect_type": "coin_flip",
                 "params": {
                     "on_heads": [],
                     "on_tails": [{"effect_type": "attack_fail", "params": {}}],
                 }},
            ]
        },
    }
}

# 呱头蛙 Frogadier (sv2-39) - 折返瞬击: 40 + optional switch self
CARD_EFFECTS["sv2-39"] = {
    "attacks": {
        "折返瞬击": {
            "effects": [
                {"effect_type": "switch_self",
                 "params": {"optional": True}},
            ]
        },
    }
}

# ============================================================
# 👊 斗系新卡组 — 路卡利欧核心 (用户自定义)
# ============================================================

# 利欧路 Riolu (svf-rio) - 重拳: 10 no effect. 突击: 50 + self 20
CARD_EFFECTS["svf-rio"] = {
    "attacks": {
        "重拳": {"effects": []},
        "突击": {
            "effects": [
                {"effect_type": "damage_counter_self", "params": {"amount": 20}},
            ]
        },
    }
}

# 路卡利欧 Lucario (svf-luca) - 旺盛斗气: self 20 dmg + attach 1 fighting from deck to self
# 连续波导弹: discard all fighting energy, +60×count
CARD_EFFECTS["svf-luca"] = {
    "abilities": {
        "旺盛斗气": {
            "trigger": "",
            "effects": [
                {"effect_type": "damage_counter_self", "params": {"amount": 20}},
                {"effect_type": "energy_attach",
                 "params": {"amount": 1, "from_zone": "deck", "filter": "fighting", "to": "self"}},
            ]
        },
    },
    "attacks": {
        "连续波导弹": {
            "effects": [
                {"effect_type": "discard_fighting_energy_damage",
                 "params": {"base": 10, "per_energy": 60}},
            ]
        },
    }
}

# 飞天螳螂 Scyther (svf-scyt) - 高速镰刀: 20 no effect
CARD_EFFECTS["svf-scyt"] = {
    "attacks": {
        "高速镰刀": {"effects": []},
    }
}

# 劈斧螳螂 Kleavor (svf-klea) - 大树切割: 2 coin flips, both heads = KO opponent active
# 暴走冲撞: 120 + self 30
CARD_EFFECTS["svf-klea"] = {
    "attacks": {
        "大树切割": {
            "effects": [
                {"effect_type": "coin_flip_double_ko",
                 "params": {}},
            ]
        },
        "暴走冲撞": {
            "effects": [
                {"effect_type": "damage_counter_self", "params": {"amount": 30}},
            ]
        },
    }
}

# 投掷猴 Passimian (svf-pass) - 辅助传递: 70 + move 1 energy from self to bench
CARD_EFFECTS["svf-pass"] = {
    "attacks": {
        "辅助传递": {
            "effects": [
                {"effect_type": "energy_relocate",
                 "params": {"amount": 1, "from_self": True}},
            ]
        },
    }
}

# 大葱鸭 Farfetch'd (svf-farf) - 背来: draw 2. 甩葱殴打: 30 no effect
CARD_EFFECTS["svf-farf"] = {
    "attacks": {
        "背来": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2, "player": "self"}},
            ]
        },
        "甩葱殴打": {"effects": []},
    }
}

# 代拉基翁 Terrakion (svf-terr) - 岩窟冲撞: 120 + prevent_all next turn + can't use consecutively
CARD_EFFECTS["svf-terr"] = {
    "attacks": {
        "岩窟冲撞": {
            "effects": [
                {"effect_type": "prevent_all", "params": {}},
                {"effect_type": "self_attack_lock", "params": {"attack_name": "岩窟冲撞"}},
            ]
        },
    }
}

# 摔角鹰人 Hawlucha (svf-hawl) - 展示姿态: attach up to 2 basic energy from discard to bench
# 挥落: 30 + 30 if opponent active is evolved
CARD_EFFECTS["svf-hawl"] = {
    "attacks": {
        "展示姿态": {
            "effects": [
                {"effect_type": "attach_from_discard",
                 "params": {"amount": 2, "energy_type": "basic", "target": "bench"}},
            ]
        },
        "挥落": {
            "effects": [
                {"effect_type": "conditional_damage_bonus",
                 "params": {"bonus": 30, "condition": "opponent_active_evolved"}},
            ]
        },
    }
}

# 伤药 Potion (svf-potion) - Heal 30 HP from 1 of your Pokemon
CARD_EFFECTS["svf-potion"] = {
    "trainer_effect": {
        "effect_type": "potion_heal",
        "params": {"amount": 30}
    }
}

# 能量转移 Energy Switch (svf-ensw2) - Move 1 basic energy between your Pokemon
CARD_EFFECTS["svf-ensw2"] = {
    "trainer_effect": {
        "effect_type": "energy_relocate",
        "params": {"amount": 1}
    }
}

# 凰檗 Houb (svf-houb) - Put 1 card from hand to bottom of deck, draw until hand = 5
CARD_EFFECTS["svf-houb"] = {
    "trainer_effect": {
        "effect_type": "houb",
        "params": {"target_hand_size": 5}
    }
}

# ============================================================
# 套牌1 — 七夕青鸟ex核心（龙/水）新卡效果
# ============================================================

# 青绵鸟 Swablu (svg-swa) - 连续旋转: coin flip until tails, 20× heads
CARD_EFFECTS["svg-swa"] = {
    "attacks": {
        "连续旋转": {
            "effects": [
                {"effect_type": "coin_flip_until_tails",
                 "params": {"per_head": 20}},
            ]
        },
    }
}

# 七夕青鸟ex Altaria ex (svg-alt) - 哼唱治愈: heal 20 all / 光之波动: 140 + prevent_all
CARD_EFFECTS["svg-alt"] = {
    "abilities": {
        "哼唱治愈": {
            "trigger": "on_turn",
            "effects": [
                {"effect_type": "heal_all",
                 "params": {"amount": 20}},
            ]
        },
    },
    "attacks": {
        "光之波动": {
            "effects": [
                {"effect_type": "prevent_all", "params": {}},
            ]
        },
    }
}

# 老翁龙 Drampa (svg-dram) - 逆鳞: 60 + self damage counters × 10
CARD_EFFECTS["svg-dram"] = {
    "attacks": {
        "逆鳞": {
            "effects": [
                {"effect_type": "damage_per_self_damage",
                 "params": {"base": 60, "per_counter": 10}},
            ]
        },
    }
}

# 米立龙 Tatsugiri Dragon型 (svg-tatsu) - 水枪: 无效果 / 生存战略: search any 2 + optional switch
CARD_EFFECTS["svg-tatsu"] = {
    "attacks": {
        "水枪": {"effects": []},
        "生存战略": {
            "effects": [
                {"effect_type": "search_any_and_switch",
                 "params": {"count": 2, "switch_optional": True, "source_slot": "active"}},
            ]
        },
    }
}

# 大奶罐 Miltank (svg-milt) - 活泼冲撞: 60 + 90 if healed this turn
CARD_EFFECTS["svg-milt"] = {
    "attacks": {
        "活泼冲撞": {
            "effects": [
                {"effect_type": "conditional_damage_heal",
                 "params": {"base": 60, "bonus": 90}},
            ]
        },
    }
}

# 飘浮泡泡 Castform (svg-cast) - 双重抽取: draw 2 / 暴风: 30 + energy_relocate 1
CARD_EFFECTS["svg-cast"] = {
    "attacks": {
        "双重抽取": {
            "effects": [
                {"effect_type": "draw", "params": {"amount": 2}},
            ]
        },
        "暴风": {
            "effects": [
                {"effect_type": "energy_relocate",
                 "params": {"amount": 1}},
            ]
        },
    }
}

# 走鲸 Cetoddle (svg-ceto) - 撞击: 无效果
CARD_EFFECTS["svg-ceto"] = {
    "attacks": {
        "撞击": {"effects": []},
    }
}

# 浩大鲸 Cetitan (svg-ceti) - 头突: 无效果 / 扫除冲撞: 200 - self damage counters × 20
CARD_EFFECTS["svg-ceti"] = {
    "attacks": {
        "头突": {"effects": []},
        "扫除冲撞": {
            "effects": [
                {"effect_type": "damage_self_penalty",
                 "params": {"base": 200, "per_counter": 20}},
            ]
        },
    }
}

# 西餐厨师 Chef (svg-chef) - Heal active Pokemon 70 HP
CARD_EFFECTS["svg-chef"] = {
    "trainer_effect": {
        "effect_type": "heal",
        "params": {"amount": 70, "target": "self"}
    }
}

# 贝里菈 Beri (svg-beri) - Draw until hand > opponent by 1
CARD_EFFECTS["svg-beri"] = {
    "trainer_effect": {
        "effect_type": "draw_until_more",
        "params": {}
    }
}

# ============================================================
# 套牌2 — 土台龟核心（草）新卡效果
# ============================================================

# 草苗龟 Turtwig (svg2-turt) - 咬住/鲁莽头击: 无效果
CARD_EFFECTS["svg2-turt"] = {
    "attacks": {
        "咬住": {"effects": []},
        "鲁莽头击": {"effects": []},
    }
}

# 树林龟 Grotle (svg2-grot) - 日光甲壳: search 1 Grass Pokemon / 飞叶快刀: 无效果
CARD_EFFECTS["svg2-grot"] = {
    "abilities": {
        "日光甲壳": {
            "trigger": "on_turn",
            "effects": [
                {"effect_type": "search",
                 "params": {"from_zone": "deck", "filter": "grass_pokemon",
                           "destination": "hand", "reveal": True, "count": 1}},
            ]
        },
    },
    "attacks": {
        "飞叶快刀": {"effects": []},
    }
}

# 土台龟 Torterra (svg2-tort) - 进化压制: 50× evolved count / 头突: 无效果
CARD_EFFECTS["svg2-tort"] = {
    "attacks": {
        "进化压制": {
            "effects": [
                {"effect_type": "damage_per_evolved",
                 "params": {"per_evolved": 50}},
            ]
        },
        "头突": {"effects": []},
    }
}

# 蘑蘑菇 Shroomish (svg2-shro) - 吸取: 10 damage + 10 self heal
CARD_EFFECTS["svg2-shro"] = {
    "attacks": {
        "吸取": {
            "effects": [
                {"effect_type": "damage_and_self_heal",
                 "params": {"damage": 10, "heal": 10}},
            ]
        },
    }
}

# 斗笠菇 Breloom (svg2-brel) - 音速直击: 无效果
CARD_EFFECTS["svg2-brel"] = {
    "attacks": {
        "音速直击": {"effects": []},
    }
}

# 萨戮德 Zarude (svg2-zaru) - 唤群之歌: conditional search G Pokemon / 反复鞭挞: 60+ G energy ×20
CARD_EFFECTS["svg2-zaru"] = {
    "attacks": {
        "唤群之歌": {
            "effects": [
                {"effect_type": "conditional_search_extra",
                 "params": {"filter": "grass_pokemon", "max_count": 3, "default_count": 1}},
            ]
        },
        "反复鞭挞": {
            "effects": [
                {"effect_type": "damage_per_self_energy_type",
                 "params": {"base": 60, "per_energy": 20, "energy_type": "Grass"}},
            ]
        },
    }
}

# 帝王拿波 Empoleon (svg2-empo) - 紧急上浮: discard revive / 水之矢: any_pokemon_damage 60
CARD_EFFECTS["svg2-empo"] = {
    "abilities": {
        "紧急上浮": {
            "trigger": "on_turn",
            "effects": [
                {"effect_type": "ability_discard_revive",
                 "params": {"card_id": "svg2-empo"}},
            ]
        },
    },
    "attacks": {
        "水之矢": {
            "effects": [
                {"effect_type": "any_pokemon_damage",
                 "params": {"amount": 60, "piercing_on_bench": True}},
            ]
        },
    }
}

# 粉碎之锤 Crushing Hammer (svg2-hamm) - Coin flip: heads → discard 1 opponent energy
CARD_EFFECTS["svg2-hamm"] = {
    "trainer_effect": {
        "effect_type": "coin_flip_energy_discard",
        "params": {}
    }
}

# 学习装置 Exp. Share (svg2-exps) - Tool: when active KO'd, transfer 1 basic energy
CARD_EFFECTS["svg2-exps"] = {
    "trainer_effect": {
        "effect_type": "tool_exp_share",
        "params": {}
    }
}

# 菜种的活力 Gardenia's Vigor (svg2-gard) - Draw 2 + attach up to 2 G energy
CARD_EFFECTS["svg2-gard"] = {
    "trainer_effect": {
        "effect_type": "draw_and_attach_energy",
        "params": {"energy_count": 2, "energy_type": "Grass"}
    }
}

# 夜光能量 Luminous Energy (svg2-lume) - Special energy handled in card_models.py provides_energy
CARD_EFFECTS["svg2-lume"] = {}

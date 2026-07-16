"""Built-in card effects: metal."""

EFFECTS = {
    "svm-zamazenta": {
        "abilities": {
            "金属之盾": {
                "trigger": "passive",
                "effects": [
                    {
                        "effect_type": "aura_damage_reduction",
                        "params": {"reduction": 30, "requires_attached_energy": True},
                    }
                ],
            }
        },
        "attacks": {
            "报仇": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 100,
                            "condition_bonus": {
                                "condition": "ko_last_opponent_turn",
                                "bonus": 120,
                            },
                        },
                    }
                ]
            }
        },
    },
    "svm-zacian": {
        "attacks": {
            "战斗军团": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 20,
                            "per_own_bench": 10,
                            "ignore_weakness": True,
                            "ignore_resistance": False,
                            "ignore_defender_damage_effects": True,
                        },
                    }
                ]
            },
            "薄片利刃": {"effects": []},
        }
    },
    "svm-smeargle": {
        "attacks": {
            "多彩调色盘": {
                "effects": [
                    {
                        "effect_type": "look_top_attach_energy",
                        "params": {
                            "count": 5,
                            "take": 99,
                            "filter": "basic_energy",
                            "target": "self_or_bench",
                            "shuffle_rest": True,
                        },
                    }
                ]
            },
            "冲撞": {"effects": []},
        }
    },
    "svm-bronzor": {
        "attacks": {
            "金属压制": {
                "effects": [
                    {
                        "effect_type": "coin_flip",
                        "params": {
                            "on_heads": [
                                {
                                    "effect_type": "status",
                                    "params": {
                                        "status": "paralyzed",
                                        "target": "opponent_active",
                                    },
                                }
                            ],
                            "on_tails": [],
                        },
                    }
                ]
            }
        }
    },
    "svm-bronzong": {
        "abilities": {
            "金属转移": {
                "trigger": "repeatable",
                "effects": [
                    {
                        "effect_type": "energy_relocate",
                        "params": {"amount": 1, "energy_type": "Metal"},
                    }
                ],
            }
        },
        "attacks": {"意念头锤": {"effects": []}},
    },
    "svm-skarmory": {
        "attacks": {
            "啄": {"effects": []},
            "钢铁之刃": {
                "effects": [
                    {
                        "effect_type": "self_attack_lock",
                        "params": {"attack_name": "钢铁之刃"},
                    }
                ]
            },
        }
    },
    "svm-cobalion": {
        "abilities": {
            "正义法则": {
                "trigger": "passive",
                "effects": [
                    {
                        "effect_type": "aura_damage_boost",
                        "params": {
                            "amount": 30,
                            "attacker_subtype": "Basic",
                            "defender_type": "Darkness",
                        },
                    }
                ],
            }
        },
        "attacks": {
            "跟进": {
                "effects": [
                    {
                        "effect_type": "energy_attach",
                        "params": {
                            "amount": 2,
                            "from_zone": "deck",
                            "filter": "basic_energy",
                            "to": "bench",
                            "max_per_target": 1,
                            "min_select": 0,
                            "select_source": True,
                        },
                    }
                ]
            }
        },
    },
    "svm-dialga": {
        "attacks": {
            "时之逆流": {
                "effects": [
                    {
                        "effect_type": "search",
                        "params": {
                            "from_zone": "discard",
                            "filter": "any",
                            "destination": "hand",
                            "reveal": True,
                            "count": 1,
                        },
                    }
                ]
            },
            "金属爆破": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 60,
                            "per_self_energy_type": "Metal",
                            "per_energy": 20,
                        },
                    }
                ]
            },
        }
    },
    "svm-klefki": {
        "attacks": {"解锁": {"effects": [{"effect_type": "draw", "params": {"amount": 2, "player": "self"}}]}}
    },
    "svm-orthworm": {
        "abilities": {
            "营养铁质": {
                "trigger": "passive",
                "effects": [
                    {
                        "effect_type": "conditional_hp_boost",
                        "params": {"energy_type": "Metal", "threshold": 3, "amount": 100},
                    }
                ],
            }
        },
        "attacks": {
            "刺穿": {
                "effects": [
                    {
                        "effect_type": "bench_damage",
                        "params": {
                            "amount": 30,
                            "count": 1,
                            "player": "opponent",
                            "choose_targets": True,
                        },
                    }
                ]
            }
        },
    },
}

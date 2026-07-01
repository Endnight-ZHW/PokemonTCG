"""Built-in card effects: darkness."""

EFFECTS = {
    "svd-mabosstiff-ex": {
        "attacks": {
            "恫吓": {
                "effects": [
                    {
                        "effect_type": "apply_outgoing_damage_reduction",
                        "params": {"amount": 50, "target": "opponent_active"},
                    }
                ]
            },
            "自尊獠牙": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 100,
                            "condition_bonus": {
                                "condition": "own_bench_damaged",
                                "bonus": 120,
                                "consume": False,
                            },
                        },
                    }
                ]
            },
        }
    },
    "svd-maschiff": {
        "attacks": {
            "踢飞": {"effects": []},
            "锐利之牙": {"effects": []},
        }
    },
    "svd-dodrio": {
        "abilities": {
            "暴走抽取": {
                "trigger": "on_turn",
                "effects": [
                    {"effect_type": "damage_counter_self", "params": {"amount": 10}},
                    {"effect_type": "draw", "params": {"amount": 1, "player": "self"}},
                ],
            }
        },
        "attacks": {
            "愤怒之喙": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {"base": 10, "per_self_damage_counter": 30},
                    }
                ]
            }
        },
    },
    "svd-doduo": {
        "attacks": {
            "突击": {
                "effects": [
                    {"effect_type": "damage_counter_self", "params": {"amount": 10}}
                ]
            }
        }
    },
    "svd-seviper": {
        "attacks": {
            "锐利之牙": {"effects": []},
            "挥落": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 50,
                            "condition_bonus": {
                                "condition": "opponent_active_evolved",
                                "bonus": 50,
                                "consume": False,
                            },
                        },
                    }
                ]
            },
        }
    },
    "svd-absol": {
        "attacks": {
            "漩涡灾祸": {
                "effects": [
                    {
                        "effect_type": "bench_damage",
                        "params": {
                            "amount": 10,
                            "count": 5,
                            "player": "opponent",
                            "choose_targets": False,
                        },
                    }
                ]
            },
            "深挖伤口": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 50,
                            "condition_bonus": {
                                "condition": "opponent_active_damaged",
                                "bonus": 70,
                                "consume": False,
                            },
                        },
                    }
                ]
            },
        }
    },
    "svd-darkrai": {
        "attacks": {
            "恶梦": {
                "effects": [
                    {
                        "effect_type": "status",
                        "params": {"status": "asleep", "target": "opponent_active"},
                    }
                ]
            },
            "漆黑之刃": {
                "effects": [
                    {
                        "effect_type": "self_attack_lock",
                        "params": {"attack_name": "漆黑之刃", "scope": "all"},
                    }
                ]
            },
        }
    },
    "svd-morpeko": {
        "attacks": {
            "捡食": {
                "effects": [
                    {
                        "effect_type": "search",
                        "params": {
                            "from_zone": "discard",
                            "filter": "item",
                            "destination": "hand",
                            "reveal": True,
                            "count": 1,
                        },
                    }
                ]
            },
            "空腹撞击": {
                "effects": [
                    {
                        "effect_type": "attack_damage_formula",
                        "params": {
                            "base": 20,
                            "condition_bonus": {
                                "condition": "own_hand_empty",
                                "bonus": 90,
                                "consume": False,
                            },
                        },
                    }
                ]
            },
        }
    },
    "svd-dark-patch": {
        "trainer_effect": {
            "effect_type": "attach_from_discard",
            "params": {
                "amount": 1,
                "energy_type": "Darkness",
                "target": "bench",
                "target_pokemon_type": "Darkness",
            },
        }
    },
    "svd-hard-belt": {
        "trainer_effect": {
            "effect_type": "tool",
            "params": {"effect": "damage_reduction_stage1", "amount": 30},
        }
    },
}

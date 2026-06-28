"""Built-in card effects: dragon."""

EFFECTS = {'svg-alt': {'abilities': {'哼唱治愈': {'trigger': 'on_turn',
                                    'effects': [{'effect_type': 'heal_all', 'params': {'amount': 20}}]}},
             'attacks': {'光之波动': {'effects': [{'effect_type': 'prevent_effects', 'params': {}}]}}},
 'svg-dram': {'attacks': {'逆鳞': {'effects': [{'effect_type': 'damage_per_self_damage',
                                              'params': {'base': 60, 'per_counter': 10}}]}}},
 'svg-tatsu': {'attacks': {'水枪': {'effects': []},
                           '生存战略': {'effects': [{'effect_type': 'search_any_and_switch',
                                                 'params': {'count': 2,
                                                            'min_select': 0,
                                                            'switch_optional': True,
                                                            'source_slot': 'active'}}]}}}}

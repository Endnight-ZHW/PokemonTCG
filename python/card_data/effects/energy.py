"""Built-in card effects: energy."""

EFFECTS = {
    "sv1-ener-1": {},
    "sv1-ener-2": {},
    "sv1-ener-3": {},
    "sv1-ener-4": {},
    "sv1-ener-5": {},
    "sv1-ener-6": {},
    "sv1-ener-7": {},
    "sv1-ener-8": {},
    "svi-jete": {
        "energy_effects": [
            {"kind": "provide_energy", "types": ["Colorless"]},
            {
                "kind": "trigger",
                "hook": "ON_ATTACH",
                "condition": {"target": "bench", "from_zone": "hand"},
                "effect": {"op": "switch_with_active"},
                "priority": 20,
            },
        ],
    },
    "svi-dtur": {
        "energy_effects": [
            {"kind": "provide_energy", "types": ["Colorless", "Colorless"]},
            {
                "kind": "modifier",
                "hook": "MODIFY_DAMAGE",
                "scope": "attached_attacker",
                "effect": {"delta": -20},
                "priority": 30,
            },
        ],
    },
    "svi-trea": {
        "energy_effects": [
            {"kind": "provide_energy", "types": ["Colorless"]},
            {
                "kind": "trigger",
                "hook": "ON_PRIZE_REVEALED",
                "condition": {"source_zone": "prizes"},
                "effect": {"op": "attach_to_benched_pokemon"},
                "priority": 20,
            },
        ],
    },
    "svi-mirc": {
        "energy_effects": [
            {"kind": "provide_energy", "types": ["Colorless"]},
            {
                "kind": "trigger",
                "hook": "AFTER_DAMAGE",
                "condition": {"scope": "attached_defender", "min_damage": 10},
                "effect": {"op": "draw_cards", "amount": 1},
                "priority": 20,
            },
        ],
    },
    "svg2-lume": {
        "energy_effects": [
            {
                "kind": "provide_energy",
                "types": ["Rainbow"],
                "downgrade_if_other_special": True,
            },
        ],
    },
}

"""Declarative Challenge strategy data consumed by the shared C++ core."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import math
from typing import Any, Mapping


CATALOG_SCHEMA = "ptcg.ai_strategy_catalog"
STRATEGY_SCHEMA = "ptcg.ai_deck_strategy"
CATALOG_VERSION = 1
STRATEGY_VERSION = 1
BASE_WEIGHTS: dict[str, float] = {
    "play_setup": 14.0,
    "play_engine": 18.0,
    "evolve": 20.0,
    "evolve_core": 30.0,
    "attach_primary": 18.0,
    "attach_secondary": 9.0,
    "play_search": 8.0,
    "play_draw": 6.0,
    "play_acceleration": 20.0,
    "play_recovery": 10.0,
    "play_switch": 4.0,
    "play_disruption": 5.0,
    "use_engine_ability": 22.0,
    "attack_primary": 24.0,
    "attack_secondary": 10.0,
    "choice_primary": 22.0,
    "choice_engine": 15.0,
    "choice_setup": 10.0,
    "choice_evolution": 14.0,
    "choice_resource": 4.0,
    "choice_energy": 7.0,
    "discard_synergy": 16.0,
    "board_primary": 28.0,
    "board_engine": 16.0,
    "hand_size": 1.5,
    "damage_pressure": 0.08,
    "closeout": 20.0,
    "search_top_k": 6.0,
    "stage_action_bonus": 7.0,
    "stage_state_progress": 3.0,
    "candidate_primary": 6.0,
    "candidate_engine": 4.0,
}

BASE_MATCHUP_WEIGHTS: dict[str, float] = {
    "ability_engine": 3.0,
    "burst": 2.5,
    "discard_recovery": 2.0,
    "durability": 2.0,
    "energy_acceleration": 3.0,
    "energy_mobility": 2.5,
    "evolution": 2.0,
    "hand_engine": 2.0,
    "healing": 2.5,
    "target_control": 2.5,
    "wide_board": 2.0,
}

DECK_ARCHETYPES: dict[str, list[str]] = {
    "fire": ["evolution", "discard_recovery"],
    "water": ["evolution", "target_control"],
    "psychic": ["ability_engine", "energy_acceleration"],
    "lightning": ["burst", "energy_acceleration"],
    "fighting": ["ability_engine", "energy_acceleration"],
    "colorless": ["wide_board", "hand_engine"],
    "dragon": ["healing", "durability"],
    "grass": ["wide_board", "evolution"],
    "steel": ["ability_engine", "energy_mobility"],
    "darkness": ["ability_engine", "discard_recovery"],
}


def _weights(**overrides: float) -> dict[str, float]:
    result = dict(BASE_WEIGHTS)
    result.update(overrides)
    return result


def _matchup_weights(**overrides: float) -> dict[str, float]:
    result = dict(BASE_MATCHUP_WEIGHTS)
    result.update(overrides)
    return result


def _goal(
    goal_id: str,
    priority: int,
    description: str,
    targets: Mapping[str, int],
) -> dict[str, Any]:
    return {
        "id": goal_id,
        "priority": priority,
        "description": description,
        "targets": dict(targets),
    }


def _strategy(
    deck_key: str,
    strategy_id: str,
    card_roles: Mapping[str, list[str]],
    stage_goals: list[dict[str, Any]],
    weights: Mapping[str, float],
    matchup_weights: Mapping[str, float] | None = None,
) -> dict[str, Any]:
    return {
        "schema": STRATEGY_SCHEMA,
        "version": STRATEGY_VERSION,
        "strategy_id": strategy_id,
        "deck_key": deck_key,
        "card_roles": {key: list(value) for key, value in card_roles.items()},
        "stage_goals": deepcopy(stage_goals),
        "weights": dict(weights),
        "matchup_weights": _matchup_weights(**dict(matchup_weights or {})),
    }


AI_STRATEGIES: dict[str, dict[str, Any]] = {
    "fire": _strategy(
        "fire",
        "fire_infernape_v1",
        {
            "primary_attacker": ["svi-infr"],
            "secondary_attacker": ["svi-ente", "svi-chiy", "svi-hrot"],
            "setup_basic": ["svi-chim", "svi-ente", "svi-hrot", "svi-chiy", "svi-sqwk"],
            "bench_engine": ["svi-chim", "svi-chiy", "svi-sqwk"],
            "evolution": ["svi-monf", "svi-infr"],
            "search": ["sv1-151", "sv1-153", "sv1-152"],
            "draw": ["svi-sqwk", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "energy_acceleration": ["svi-chiy", "svi-mela"],
            "recovery": ["svi-erec", "sv3-134", "svi-mela"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "energy": ["sv1-ener-2"],
            "discard_synergy": ["sv1-ener-2"],
        },
        [
            _goal("establish_chain", 100, "Bench Chimchar and protect an evolution route.", {"setup_basic": 2, "evolution": 1}),
            _goal("ignite_engine", 80, "Bring Infernape online with renewable Fire Energy.", {"primary_attacker": 1, "energy_acceleration": 1}),
            _goal("closeout", 60, "Keep an attacker supplied while converting knockouts.", {"primary_attacker": 1, "recovery": 1}),
        ],
        _weights(
            evolve_core=42.0,
            attach_primary=23.0,
            play_acceleration=27.0,
            play_recovery=17.0,
            fire_chain=28.0,
            recycle_energy=21.0,
            rare_candy=24.0,
            chimchar_bench=70.0,
            squawk_call_family=70.0,
            squawk_opening=55.0,
            chiyu_acceleration=35.0,
            chiyu_opening=95.0,
            infernape_attack=31.0,
            infernape_spiral=28.0,
            infernape_burning_kick=18.0,
            burning_kick_energy_cost=7.0,
            chiyu_revenge=20.0,
        ),
    ),
    "water": _strategy(
        "water",
        "water_greninja_v1",
        {
            "primary_attacker": ["sv2-grex"],
            "secondary_attacker": ["sv2-starm", "sv1-49", "sv2-keldeo", "sv2-glast"],
            "setup_basic": ["sv2-38", "sv2-staryu", "sv1-49", "sv2-keldeo", "sv2-glast", "sv2-tatsu", "sv2-delib"],
            "bench_engine": ["sv2-38", "sv2-staryu", "sv2-tatsu", "sv2-delib"],
            "evolution": ["sv2-39", "sv2-grex", "sv2-starm"],
            "search": ["sv1-151", "sv1-153", "sv1-152", "sv2-cand"],
            "draw": ["sv2-delib", "sv2-young", "sv1-180", "sv1-189", "sv1-176"],
            "energy_acceleration": ["sv2-cand"],
            "recovery": ["sv3-134"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "energy": ["sv1-ener-3"],
        },
        [
            _goal("establish_board", 100, "Develop Froakie and Staryu lines together.", {"setup_basic": 3, "evolution": 1}),
            _goal("enable_shuriken", 80, "Ready Greninja ex and retain Water Energy access.", {"primary_attacker": 1, "energy": 2}),
            _goal("take_multi_prize", 60, "Use public damage windows to finish efficient targets.", {"primary_attacker": 1, "secondary_attacker": 1}),
        ],
        _weights(
            evolve_core=40.0,
            play_search=12.0,
            attack_primary=31.0,
            choice_primary=28.0,
            greninja_attack=34.0,
            bench_target_pressure=19.0,
            torrent_setup=22.0,
            greninja_energy=8.0,
            tatsugiri_opening=125.0,
            staryu_opening_penalty=80.0,
            froakie_bench=55.0,
            froakie_backup_search=95.0,
            staryu_duplicate_penalty=85.0,
            tatsugiri_prepare=90.0,
            tatsugiri_prepare_attachment=145.0,
            candice=18.0,
            rare_candy_greninja=110.0,
            greninja_shuriken=20.0,
            greninja_torrent=34.0,
            starmie_comet_combo=145.0,
            starmie_material_cost=35.0,
            starmie_attachment_cost=8.0,
            starmie_no_backup_penalty=120.0,
            starmie_unexecutable_penalty=55.0,
        ),
    ),
    "psychic": _strategy(
        "psychic",
        "psychic_xatu_v1",
        {
            "primary_attacker": ["sv1-106", "sv1-111", "sv1-112", "sv1-113"],
            "secondary_attacker": ["sv1-109", "sv1-110", "sv1-114", "sv1-104"],
            "setup_basic": ["sv1-107", "sv1-109", "sv1-110", "sv1-111", "sv1-112", "sv1-113", "sv1-114", "sv1-104"],
            "bench_engine": ["sv1-107", "sv1-108"],
            "evolution": ["sv1-108", "sv1-106"],
            "natu_setup": ["sv1-107"],
            "xatu_engine": ["sv1-108"],
            "search": ["sv1-151", "sv1-153", "sv1-204"],
            "draw": ["sv1-108", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "energy_acceleration": ["sv1-108", "sv1-113"],
            "recovery": ["sv1-171", "sv1-203"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "tool": ["sv1-201", "sv1-202", "sv1-204"],
            "energy": ["sv1-ener-5"],
            "psychic_pokemon": [
                "sv1-107", "sv1-108", "sv1-109", "sv1-110", "sv1-111",
                "sv1-112", "sv1-113", "sv1-114", "sv1-104", "sv1-106",
            ],
            "discard_synergy": ["sv1-104", "sv1-109", "sv1-114"],
        },
        [
            _goal("build_xatu_engine", 100, "Bench Natu and evolve a stable Xatu engine.", {"natu_setup": 1, "xatu_engine": 1}),
            _goal("accelerate_energy", 80, "Turn Psychic Energy in hand into board tempo.", {"energy_acceleration": 1, "energy": 2}),
            _goal("scale_attackers", 60, "Distribute Energy across the best public attack lines.", {"primary_attacker": 2, "bench_engine": 1}),
        ],
        _weights(
            play_engine=24.0,
            use_engine_ability=34.0,
            choice_engine=25.0,
            xatu_engine=35.0,
            first_xatu_priority=95.0,
            houndstone_before_xatu_penalty=90.0,
            attacker_before_xatu_search_penalty=110.0,
            psychic_energy_hand=6.0,
            cresselia_active_opening=115.0,
            cresselia_opening_route=130.0,
            natu_bench=65.0,
            cresselia_growth=55.0,
            cresselia_first_turn_growth=100.0,
            graveyard_scaling=15.0,
            latios_glide=3.0,
            latios_clean_light=25.0,
        ),
    ),
    "lightning": _strategy(
        "lightning",
        "lightning_pikachu_v1",
        {
            "primary_attacker": ["svl-pikaex"],
            "secondary_attacker": ["svl-lant", "svl-thun", "svl-zera", "svl-emol"],
            "setup_basic": ["svl-pikaex", "svl-chin", "svl-mare2", "svl-emol", "svl-thun", "svl-zera", "svl-chat"],
            "bench_engine": ["svl-mare2", "svl-flaa2", "svl-chin"],
            "evolution": ["svl-flaa2", "svl-lant"],
            "search": ["svl-ensw", "sv1-151", "sv1-153"],
            "draw": ["svl-chat", "svl-trks", "sv1-176", "sv2-young", "sv1-180", "sv1-189", "svl-zinn"],
            "energy_acceleration": ["svl-flaa2", "sv1-170"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "tool": ["svl-vitb"],
            "energy": ["sv1-ener-4"],
            "discard_synergy": ["sv1-ener-4"],
        },
        [
            _goal("charge_bench", 100, "Establish Mareep and a Lightning target on the Bench.", {"bench_engine": 2, "setup_basic": 2}),
            _goal("prepare_pikachu", 80, "Accelerate enough Energy for Pikachu ex.", {"primary_attacker": 1, "energy_acceleration": 1}),
            _goal("burst_finish", 60, "Preserve an energized attacker for the final prizes.", {"primary_attacker": 1, "secondary_attacker": 1}),
        ],
        _weights(
            play_acceleration=31.0,
            attach_primary=25.0,
            attack_primary=34.0,
            generator=29.0,
            pikachu_burst=38.0,
            flaaffy_engine=30.0,
            pikachu_jab=3.0,
            pikachu_strong_volt=34.0,
            strong_volt_energy_risk=6.0,
            frontline_opening=70.0,
            bench_engine_active_penalty=120.0,
        ),
    ),
    "fighting": _strategy(
        "fighting",
        "fighting_lucario_v1",
        {
            "primary_attacker": ["svf-luca", "svf-klea"],
            "secondary_attacker": ["svf-pass", "svf-farf", "svf-terr", "svf-hawl"],
            "setup_basic": ["svf-rio", "svf-scyt", "svf-pass", "svf-farf", "svf-terr", "svf-hawl"],
            "bench_engine": ["svf-rio", "svf-luca", "svf-scyt"],
            "evolution": ["svf-luca", "svf-klea"],
            "search": ["sv1-151", "sv1-153"],
            "draw": ["svf-farf", "svf-houb", "sv1-180", "sv1-176", "sv2-young", "sv1-189"],
            "energy_acceleration": ["svf-luca"],
            "energy_mobility": ["svf-ensw2"],
            "recovery": ["svf-potion", "sv3-134", "svi-erec"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "energy": ["sv1-ener-6"],
        },
        [
            _goal("build_lucario", 100, "Develop Riolu and Scyther evolution lines.", {"setup_basic": 3, "evolution": 1}),
            _goal("stack_fighting_energy", 80, "Use acceleration while keeping a safe second attacker.", {"energy_acceleration": 1, "primary_attacker": 2}),
            _goal("aura_burst", 60, "Convert the prepared Energy board into knockouts.", {"primary_attacker": 1, "recovery": 1}),
        ],
        _weights(
            evolve_core=38.0,
            play_acceleration=30.0,
            use_engine_ability=32.0,
            lucario_engine=34.0,
            fighting_stack=8.0,
            kleavor=22.0,
            kleavor_guillotine=20.0,
            kleavor_rampage=18.0,
            lucario_self_ko_penalty=120.0,
            lucario_low_hp_penalty=32.0,
        ),
    ),
    "colorless": _strategy(
        "colorless",
        "colorless_maushold_v1",
        {
            "primary_attacker": ["svi-maus"],
            "secondary_attacker": ["svi-ambi", "svi-gree", "svi-stan", "svi-flam"],
            "setup_basic": ["svi-aipo", "svi-stan", "svi-skwv", "svi-inde", "svi-tand", "svi-flam"],
            "bench_engine": ["svi-tand", "svi-aipo", "svi-skwv", "svi-inde"],
            "evolution": ["svi-ambi", "svi-gree", "svi-maus"],
            "search": ["svi-enst", "sv1-151", "sv1-153"],
            "draw": ["svi-ambi", "svi-gree", "svi-nemb", "svi-cait", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "energy_acceleration": ["svi-popp"],
            "recovery": ["sv3-134"],
            "switch": ["sv1-150", "svi-jete"],
            "disruption": ["sv2-catch", "sv1-176"],
            "energy": ["svi-jete", "svi-dtur", "svi-trea", "svi-mirc"],
            "family": ["svi-tand", "svi-maus"],
        },
        [
            _goal("fill_bench", 100, "Develop Tandemaus and supporting Basics without clogging slots.", {"setup_basic": 3, "bench_engine": 2}),
            _goal("grow_hand", 80, "Preserve draw resources and build a useful hand.", {"draw": 2, "primary_attacker": 1}),
            _goal("family_pressure", 60, "Keep Maushold ex active with flexible Special Energy.", {"primary_attacker": 1, "energy": 2}),
        ],
        _weights(
            play_setup=19.0,
            play_draw=10.0,
            hand_size=3.5,
            family_board=9.0,
            hand_preservation=18.0,
            special_energy=13.0,
            ambipom_call=6.0,
            ambipom_hand_attack=5.0,
            greedent_call=6.0,
            greedent_dump=28.0,
        ),
    ),
    "dragon": _strategy(
        "dragon",
        "dragon_altaria_v1",
        {
            "primary_attacker": ["svg-alt", "svg-ceti"],
            "secondary_attacker": ["svg-dram", "svg-milt", "svg-tatsu", "svg-cast", "svf-hawl"],
            "setup_basic": ["svg-swa", "svg-dram", "svg-tatsu", "svg-milt", "svg-cast", "svf-hawl", "svg-ceto"],
            "bench_engine": ["svg-swa", "svg-ceto", "svg-tatsu"],
            "evolution": ["svg-alt", "svg-ceti"],
            "search": ["svl-ensw", "sv1-151", "sv1-153"],
            "draw": ["svg-beri", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "healing": ["svg-alt", "svf-potion", "svg-chef"],
            "recovery": ["sv3-134"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "energy": ["sv1-ener-3", "sv1-ener-8"],
        },
        [
            _goal("build_healing_core", 100, "Evolve Altaria ex and keep a second line available.", {"bench_engine": 2, "evolution": 1}),
            _goal("balance_energy", 80, "Place both required Energy colors without stranding attackers.", {"primary_attacker": 1, "energy": 2}),
            _goal("healing_lock", 60, "Use healing to preserve the developed multi-attacker board.", {"healing": 1, "primary_attacker": 2}),
        ],
        _weights(
            evolve_core=40.0,
            board_primary=33.0,
            healing=0.16,
            dual_energy_balance=18.0,
            altaria_lock=31.0,
            cetitan_headbutt=3.0,
            cetitan_sweeping=30.0,
            cetitan_damage_penalty=0.25,
            miltank_healed_attack=24.0,
        ),
    ),
    "grass": _strategy(
        "grass",
        "grass_torterra_v1",
        {
            "primary_attacker": ["svg2-tort"],
            "secondary_attacker": ["svg2-brel", "svg2-zaru", "svg2-empo"],
            "setup_basic": ["svg2-turt", "svg2-shro", "svg2-zaru"],
            "bench_engine": ["svg2-grot"],
            "evolution": ["svg2-grot", "svg2-tort", "svg2-brel", "svg2-empo"],
            "search": ["sv1-151", "sv1-153", "sv1-152", "svg2-zaru"],
            "draw": ["svg2-gard", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "energy_acceleration": ["svg2-gard"],
            "recovery": ["sv3-134", "svg2-exps", "svg2-empo"],
            "switch": ["sv1-150"],
            "disruption": ["svg2-hamm", "sv2-catch", "sv1-176"],
            "energy": ["svg2-lume", "sv1-ener-1"],
            "discard_synergy": ["svg2-empo"],
        },
        [
            _goal("fill_evolution_board", 100, "Bench multiple evolution lines before committing resources.", {"setup_basic": 3, "bench_engine": 1}),
            _goal("evolve_swarm", 80, "Maximize evolved Pokemon for Torterra's pressure.", {"evolution": 3, "primary_attacker": 1}),
            _goal("evolution_pressure", 60, "Maintain a full evolved board and take efficient attacks.", {"evolution": 4, "secondary_attacker": 1}),
        ],
        _weights(
            play_setup=22.0,
            evolve=24.0,
            evolve_core=32.0,
            evolved_board=14.0,
            gardenia=27.0,
            rare_candy=25.0,
            turtwig_setup=18.0,
            torterra_evolution_pressure=28.0,
            torterra_headbutt=14.0,
            empoleon_revival=35.0,
            zarude_opening_search=22.0,
        ),
    ),
    "steel": _strategy(
        "steel",
        "steel_zacian_zamazenta_v1",
        {
            "primary_attacker": ["svm-zacian", "svm-zamazenta", "svm-orthworm"],
            "secondary_attacker": ["svm-skarmory", "svm-cobalion", "svm-dialga", "svm-klefki"],
            "setup_basic": ["svm-zamazenta", "svm-zacian", "svm-smeargle", "svm-bronzor", "svm-skarmory", "svm-cobalion", "svm-dialga", "svm-klefki", "svm-orthworm"],
            "bench_engine": ["svm-bronzor", "svm-bronzong", "svm-smeargle", "svm-cobalion"],
            "evolution": ["svm-bronzong"],
            "search": ["sv1-151", "sv1-153"],
            "draw": ["svm-smeargle", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "energy_acceleration": ["svm-bronzong", "svm-marnie-pride"],
            "recovery": ["sv3-134", "svg2-exps"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "tool": ["svg2-exps", "svl-vitb"],
            "energy": ["sv1-ener-8"],
            "discard_synergy": ["sv1-ener-8"],
        },
        [
            _goal("build_metal_board", 100, "Bench Bronzor and multiple useful attackers.", {"bench_engine": 2, "primary_attacker": 2}),
            _goal("enable_transfer", 80, "Evolve Bronzong and keep Metal Energy movable.", {"evolution": 1, "energy_acceleration": 1}),
            _goal("fortress_pressure", 60, "Move Energy to the best public attacker each turn.", {"primary_attacker": 2, "energy": 3}),
        ],
        _weights(
            play_engine=24.0,
            use_engine_ability=36.0,
            attach_primary=22.0,
            metal_transfer=36.0,
            metal_board=11.0,
            revenge=24.0,
            zacian_battle_legion=5.0,
            zacian_blade=18.0,
            orthworm_threshold=28.0,
        ),
    ),
    "darkness": _strategy(
        "darkness",
        "darkness_mabosstiff_v1",
        {
            "primary_attacker": ["svd-mabosstiff-ex", "svd-dodrio"],
            "secondary_attacker": ["svd-seviper", "svd-absol", "svd-darkrai", "svd-morpeko"],
            "setup_basic": ["svd-maschiff", "svd-doduo", "svd-seviper", "svd-absol", "svd-darkrai", "svd-morpeko", "svl-chat"],
            "bench_engine": ["svd-maschiff", "svd-doduo", "svd-dodrio", "svl-chat"],
            "evolution": ["svd-mabosstiff-ex", "svd-dodrio"],
            "search": ["sv1-151", "sv1-153", "sv1-204"],
            "draw": ["svd-dodrio", "svl-chat", "sv1-176", "sv2-young", "sv1-180", "sv1-189"],
            "energy_acceleration": ["svd-dark-patch"],
            "recovery": ["sv3-134", "svd-dark-patch"],
            "switch": ["sv1-150"],
            "disruption": ["sv2-catch", "sv1-176"],
            "tool": ["svd-hard-belt", "sv1-204"],
            "energy": ["sv1-ener-7"],
            "discard_synergy": ["sv1-ener-7"],
        },
        [
            _goal("build_dual_lines", 100, "Develop Maschiff and Doduo without exposing both engines.", {"bench_engine": 3, "evolution": 1}),
            _goal("prime_damage_engine", 80, "Use Dodrio's public damage state while accelerating Energy.", {"primary_attacker": 2, "energy_acceleration": 1}),
            _goal("pride_finish", 60, "Keep Mabosstiff ex charged for the closing attacks.", {"primary_attacker": 1, "tool": 1}),
        ],
        _weights(
            play_engine=23.0,
            use_engine_ability=31.0,
            play_acceleration=32.0,
            damage_engine=0.22,
            dark_patch=30.0,
            damaged_dodrio=27.0,
            mabosstiff_evolution=52.0,
            mabosstiff_intimidate=14.0,
            mabosstiff_pride=34.0,
            dodrio_safety_penalty=60.0,
        ),
    ),
}


FALLBACK_STRATEGY: dict[str, Any] = _strategy(
    "generic",
    "generic_balanced_v1",
    {},
    [
        _goal("setup", 100, "Establish a legal active Pokemon and a safe Bench.", {}),
        _goal("develop", 80, "Improve board options and attach Energy efficiently.", {}),
        _goal("closeout", 60, "Prefer safe prize-taking actions.", {}),
    ],
    _weights(),
)


def _with_content_hash(strategy: Mapping[str, Any]) -> dict[str, Any]:
    payload = deepcopy(dict(strategy))
    payload.pop("content_hash", None)
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    payload["content_hash"] = hashlib.sha256(canonical).hexdigest()
    return payload


def _exported_strategy(strategy: Mapping[str, Any]) -> dict[str, Any]:
    return _with_content_hash(strategy)


def _deck_card_ids(definition: Any) -> set[str]:
    rows = definition.get("cards", []) if isinstance(definition, Mapping) else definition
    result: set[str] = set()
    for row in rows:
        if isinstance(row, Mapping):
            card_id = row.get("card_id")
        else:
            card_id = row[0] if isinstance(row, (list, tuple)) and row else None
        if isinstance(card_id, str) and card_id:
            result.add(card_id)
    return result


def _declared_card_ids(value: Any) -> set[str]:
    """Collect explicitly identified cards without treating labels as IDs."""
    result: set[str] = set()
    if isinstance(value, Mapping):
        for key, nested in value.items():
            if key in {"card_id", "source_card_id", "target_card_id"}:
                if isinstance(nested, str) and nested:
                    result.add(nested)
            elif key in {"card_ids", "energy_card_ids", "evolution_stack_ids"}:
                if isinstance(nested, (list, tuple)):
                    result.update(
                        card_id for card_id in nested
                        if isinstance(card_id, str) and card_id
                    )
            else:
                result.update(_declared_card_ids(nested))
    elif isinstance(value, (list, tuple)):
        for nested in value:
            result.update(_declared_card_ids(nested))
    return result


def _validate_strategy(
    deck_key: str,
    strategy: Mapping[str, Any],
    deck_card_ids: set[str],
) -> list[str]:
    errors: list[str] = []
    if strategy.get("schema") != STRATEGY_SCHEMA:
        errors.append(f"{deck_key}: invalid strategy schema")
    if strategy.get("version") != STRATEGY_VERSION:
        errors.append(f"{deck_key}: invalid strategy version")
    if strategy.get("deck_key") != deck_key:
        errors.append(f"{deck_key}: embedded deck_key does not match")
    if not isinstance(strategy.get("strategy_id"), str) or not strategy["strategy_id"]:
        errors.append(f"{deck_key}: strategy_id must be non-empty")

    roles = strategy.get("card_roles")
    if not isinstance(roles, Mapping) or not roles:
        errors.append(f"{deck_key}: card_roles must be a non-empty mapping")
        roles = {}
    assigned_card_ids: set[str] = set()
    for role, card_ids in roles.items():
        if not isinstance(role, str) or not role:
            errors.append(f"{deck_key}: card role names must be non-empty strings")
            continue
        if not isinstance(card_ids, list) or not card_ids:
            errors.append(f"{deck_key}.{role}: role must contain card IDs")
            continue
        if len(card_ids) != len(set(card_ids)):
            errors.append(f"{deck_key}.{role}: duplicate card ID")
        invalid = sorted(set(card_ids) - deck_card_ids)
        if invalid:
            errors.append(f"{deck_key}.{role}: cards not in deck: {', '.join(invalid)}")
        assigned_card_ids.update(card_ids)
    unassigned = sorted(deck_card_ids - assigned_card_ids)
    if unassigned:
        errors.append(f"{deck_key}: cards without a role: {', '.join(unassigned)}")

    goals = strategy.get("stage_goals")
    if not isinstance(goals, list) or not goals:
        errors.append(f"{deck_key}: stage_goals must be a non-empty list")
        goals = []
    goal_ids: set[str] = set()
    for index, goal in enumerate(goals):
        if not isinstance(goal, Mapping):
            errors.append(f"{deck_key}.stage_goals[{index}]: must be an object")
            continue
        goal_id = goal.get("id")
        if not isinstance(goal_id, str) or not goal_id or goal_id in goal_ids:
            errors.append(f"{deck_key}.stage_goals[{index}]: invalid or duplicate id")
        else:
            goal_ids.add(goal_id)
        if not isinstance(goal.get("priority"), int):
            errors.append(f"{deck_key}.{goal_id}: priority must be an integer")
        targets = goal.get("targets")
        if not isinstance(targets, Mapping):
            errors.append(f"{deck_key}.{goal_id}: targets must be an object")
            continue
        for role, count in targets.items():
            if role not in roles:
                errors.append(f"{deck_key}.{goal_id}: unknown target role {role}")
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                errors.append(f"{deck_key}.{goal_id}.{role}: target must be a non-negative integer")

    for field_name in ("weights", "matchup_weights"):
        weights = strategy.get(field_name)
        if not isinstance(weights, Mapping) or not weights:
            errors.append(f"{deck_key}: {field_name} must be a non-empty mapping")
            continue
        for name, value in weights.items():
            if not isinstance(name, str) or not name:
                errors.append(f"{deck_key}: {field_name} names must be non-empty strings")
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                errors.append(f"{deck_key}.{field_name}.{name}: value must be finite")
    return errors


def build_ai_strategy_catalog(
    deck_definitions: Mapping[str, Any],
) -> dict[str, Any]:
    """Validate release membership and return a deterministic export payload."""
    expected_keys = set(deck_definitions)
    strategy_keys = set(AI_STRATEGIES)
    errors: list[str] = []
    if strategy_keys != expected_keys:
        missing = sorted(expected_keys - strategy_keys)
        extra = sorted(strategy_keys - expected_keys)
        if missing:
            errors.append("missing deck strategies: " + ", ".join(missing))
        if extra:
            errors.append("unknown deck strategies: " + ", ".join(extra))

    strategy_ids: set[str] = set()
    for deck_key in sorted(expected_keys & strategy_keys):
        strategy = AI_STRATEGIES[deck_key]
        errors.extend(
            _validate_strategy(
                deck_key,
                strategy,
                _deck_card_ids(deck_definitions[deck_key]),
            )
        )
        strategy_id = str(strategy.get("strategy_id", ""))
        if strategy_id in strategy_ids:
            errors.append(f"duplicate strategy_id: {strategy_id}")
        strategy_ids.add(strategy_id)

    if errors:
        raise ValueError("Invalid AI strategy definitions: " + "; ".join(errors))
    if set(DECK_ARCHETYPES) != expected_keys:
        raise ValueError("AI strategy archetype keys do not match release decks")
    for deck_key, tags in DECK_ARCHETYPES.items():
        if not tags or len(tags) != len(set(tags)):
            raise ValueError(f"AI strategy archetypes are invalid for {deck_key}")
        unknown_tags = sorted(set(tags) - set(BASE_MATCHUP_WEIGHTS))
        if unknown_tags:
            raise ValueError(
                f"AI strategy archetypes are unknown for {deck_key}: "
                + ", ".join(unknown_tags)
            )
    payload = {
        "schema": CATALOG_SCHEMA,
        "version": CATALOG_VERSION,
        "deck_archetypes": deepcopy(DECK_ARCHETYPES),
        "fallback": _exported_strategy(FALLBACK_STRATEGY),
        "strategies": {
            key: _exported_strategy(AI_STRATEGIES[key])
            for key in sorted(AI_STRATEGIES)
        },
    }
    return _with_content_hash(payload)

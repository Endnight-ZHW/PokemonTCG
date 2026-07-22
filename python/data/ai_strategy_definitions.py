"""Authoritative deck-strategy definitions exported to the Godot client.

Keep declarative card roles and tuning data here. Runtime-only tactical hooks live
under ``godot/ai/strategies`` and are selected by ``strategy_id``.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Mapping


CATALOG_SCHEMA = "ptcg.ai_strategy_catalog"
STRATEGY_SCHEMA = "ptcg.ai_deck_strategy"
CATALOG_VERSION = 1
STRATEGY_VERSION = 1
REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_STRATEGY_ROOT = REPO_ROOT / "godot" / "ai" / "strategies"
RUNTIME_HOOK_FILES: dict[str, str] = {
    "fire": "fire_strategy.gd",
    "water": "water_strategy.gd",
    "psychic": "psychic_strategy.gd",
    "lightning": "lightning_strategy.gd",
    "fighting": "fighting_strategy.gd",
    "colorless": "colorless_strategy.gd",
    "dragon": "dragon_strategy.gd",
    "grass": "grass_strategy.gd",
    "steel": "steel_strategy.gd",
    "darkness": "darkness_strategy.gd",
    "generic": "generic_strategy.gd",
}
GOLDEN_CATEGORIES = frozenset({
    "setup",
    "evolution",
    "search",
    "switch",
    "attack",
    "prize_route",
    "resource_preservation",
    "loss_avoidance",
})


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


def _pokemon(
    card_id: str,
    *,
    damage: int = 0,
    energy: tuple[str, ...] = (),
    status: tuple[str, ...] = (),
    healed: bool = False,
) -> dict[str, Any]:
    """Build a public strategy row; ``damage`` is expressed in HP, not counters."""
    if damage < 0 or damage % 10 != 0:
        raise ValueError("golden Pokemon damage must be a non-negative multiple of 10 HP")
    return {
        "card_id": card_id,
        "damage_counters": damage // 10,
        "energy_card_ids": list(energy),
        "status_conditions": list(status),
        "healed_this_turn": healed,
    }


def _public_context(
    *,
    turn: int = 3,
    active: Mapping[str, Any] | None = None,
    bench: tuple[Mapping[str, Any], ...] = (),
    hand: tuple[str, ...] = (),
    discard: tuple[str, ...] = (),
    own_prizes: int = 6,
    opponent_active: Mapping[str, Any] | None = None,
    opponent_bench: tuple[Mapping[str, Any], ...] = (),
    opponent_prizes: int = 6,
    previous_knockouts: tuple[Mapping[str, Any], ...] = (),
) -> dict[str, Any]:
    """Build only information visible to the acting player."""
    return {
        "perspective": 0,
        "turn_number": turn,
        "own_prize_count": own_prizes,
        "opponent_prize_count": opponent_prizes,
        "own": {
            "active": deepcopy(dict(active)) if active is not None else {},
            "bench": [deepcopy(dict(row)) for row in bench],
            "hand": list(hand),
            "discard": list(discard),
            "prizes_remaining": own_prizes,
        },
        "opponent": {
            "active": (
                deepcopy(dict(opponent_active))
                if opponent_active is not None
                else {}
            ),
            "bench": [deepcopy(dict(row)) for row in opponent_bench],
            "hand_count": 0,
            "discard": [],
            "prizes_remaining": opponent_prizes,
        },
        "turn_fact_book": {
            "previous_turn": {"knockouts": [deepcopy(dict(row)) for row in previous_knockouts]},
        },
    }


def _action(
    kind: str,
    card_id: str = "",
    *,
    target_card_id: str = "",
    target_slot: str = "",
    attack_index: int | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {"kind": kind}
    if card_id:
        result["card_id"] = card_id
    if target_card_id:
        result["target_card_id"] = target_card_id
    if target_slot:
        result["target"] = {"slot": target_slot}
    if attack_index is not None:
        result["attack_index"] = attack_index
    return result


def _golden_action(
    scenario_id: str,
    category: str,
    stage: str,
    context: Mapping[str, Any],
    preferred: Mapping[str, Any],
    over: Mapping[str, Any],
) -> dict[str, Any]:
    return {
        "id": scenario_id,
        "category": category,
        "surface": "action",
        "stage": stage,
        "context": deepcopy(dict(context)),
        "preferred": deepcopy(dict(preferred)),
        "over": deepcopy(dict(over)),
        "expected": "higher",
    }


def _golden_choice(
    scenario_id: str,
    category: str,
    stage: str,
    context: Mapping[str, Any],
    choice_context: Mapping[str, Any],
    preferred_card_id: str,
    over_card_id: str,
) -> dict[str, Any]:
    return {
        "id": scenario_id,
        "category": category,
        "surface": "choice",
        "stage": stage,
        "context": deepcopy(dict(context)),
        "choice_context": deepcopy(dict(choice_context)),
        "preferred": {"card_id": preferred_card_id},
        "over": {"card_id": over_card_id},
        "expected": "higher",
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


_SEARCH_CHOICE = {
    "request_type": "search_deck",
    "presentation": {"purpose": "search"},
}
_DISCARD_CHOICE = {
    "request_type": "select_card",
    "presentation": {"purpose": "discard_cards"},
}
_END_TURN = _action("END_TURN")


def _build_golden_scenarios() -> dict[str, list[dict[str, Any]]]:
    fire_setup = _public_context(turn=1, active=_pokemon("svi-ente"))
    fire_engine = _public_context(
        active=_pokemon("svi-infr", energy=("sv1-ener-2",) * 4),
    )
    fire_close = _public_context(
        active=_pokemon("svi-chiy", energy=("sv1-ener-2",) * 2),
        own_prizes=1,
        previous_knockouts=({
            "defeated_player": 0,
            "source_player": 1,
            "source_kind": "attack_damage",
            "cause_kind": "damage",
        },),
    )
    fire_discard = _public_context(
        active=_pokemon("svi-ente"),
        discard=("sv1-ener-2", "sv1-ener-2", "sv1-ener-2"),
    )

    water_setup = _public_context(turn=1, active=_pokemon("sv2-keldeo"))
    water_torrent = _public_context(
        active=_pokemon("sv2-grex", energy=("sv1-ener-3",) * 3),
        opponent_active=_pokemon("sv2-glast", damage=20),
    )
    water_wide = _public_context(
        active=_pokemon("sv2-grex", energy=("sv1-ener-3",) * 3),
        opponent_active=_pokemon("sv2-glast"),
        opponent_bench=(
            _pokemon("sv2-staryu"),
            _pokemon("sv2-keldeo"),
            _pokemon("sv2-tatsu"),
            _pokemon("sv2-delib"),
        ),
    )
    water_close = _public_context(
        active=_pokemon("sv2-grex", energy=("sv1-ener-3",) * 3),
        own_prizes=1,
    )
    water_starmie_risk = _public_context(
        active=_pokemon("sv2-starm", energy=("sv1-ener-3",)),
    )
    water_starmie_combo = _public_context(
        active=_pokemon("sv2-grex", energy=("sv1-ener-3",) * 2),
        bench=(_pokemon("sv2-starm"),),
        opponent_active=_pokemon("sv2-glast"),
        own_prizes=6,
        opponent_prizes=1,
    )
    water_damaged_without_backup = _public_context(
        active=_pokemon("sv2-grex", damage=100, energy=("sv1-ener-3",) * 2),
        bench=(_pokemon("sv2-staryu"),),
    )

    psychic_setup = _public_context(turn=1, active=_pokemon("sv1-109"))
    psychic_engine = _public_context(
        active=_pokemon("sv1-111"),
        bench=(_pokemon("sv1-108"),),
        hand=("sv1-ener-5", "sv1-ener-5"),
    )
    psychic_graveyard = _public_context(
        active=_pokemon("sv1-106", energy=("sv1-ener-5",) * 3),
        bench=(_pokemon("sv1-108"),),
        discard=("sv1-104", "sv1-109", "sv1-114"),
    )

    result: dict[str, list[dict[str, Any]]] = {
        "fire": [
            _golden_action("fire_setup_chain", "setup", "establish_chain", fire_setup,
                           _action("PLAY_BASIC", "svi-chim"), _action("PLAY_BASIC", "svi-ente")),
            _golden_action("fire_bench_chimchar_chain", "setup", "establish_chain",
                           _public_context(turn=1),
                           _action("PLAY_BASIC", "svi-chim", target_slot="bench_0"),
                           _action("PLAY_BASIC", "svi-chim", target_slot="active")),
            _golden_action("fire_core_evolution", "evolution", "establish_chain", fire_setup,
                           _action("EVOLVE", "svi-infr"), _action("EVOLVE", "svi-monf")),
            _golden_choice("fire_search_infernape", "search", "establish_chain", fire_setup,
                           _SEARCH_CHOICE, "svi-infr", "sv1-ener-2"),
            _golden_action("fire_status_switch", "switch", "establish_chain",
                           _public_context(active=_pokemon("svi-ente", status=("paralyzed",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("fire_spiral_preserves_energy", "attack", "ignite_engine", fire_engine,
                           _action("DECLARE_ATTACK", "svi-infr", attack_index=0),
                           _action("DECLARE_ATTACK", "svi-infr", attack_index=1)),
            _golden_action("fire_chiyu_revenge_route", "prize_route", "closeout", fire_close,
                           _action("DECLARE_ATTACK", "svi-chiy", attack_index=1),
                           _action("DECLARE_ATTACK", "svi-chiy", attack_index=0)),
            _golden_choice("fire_discard_recyclable_energy", "resource_preservation",
                           "establish_chain", fire_discard, _DISCARD_CHOICE,
                           "sv1-ener-2", "svi-infr"),
            _golden_choice("fire_keep_squawk_engine", "loss_avoidance", "establish_chain",
                           fire_discard, _DISCARD_CHOICE, "sv1-ener-2", "svi-sqwk"),
            _golden_action("fire_recover_three_energy", "resource_preservation",
                           "establish_chain", fire_discard,
                           _action("PLAY_TRAINER", "svi-mela"), _END_TURN),
            _golden_action("fire_closeout_infernape", "attack", "closeout",
                           _public_context(active=_pokemon("svi-infr"), own_prizes=1),
                           _action("DECLARE_ATTACK", "svi-infr", attack_index=0), _END_TURN),
            _golden_action("fire_squawk_opening_search", "setup", "establish_chain",
                           _public_context(turn=2, active=_pokemon("svi-sqwk")),
                           _action("DECLARE_ATTACK", "svi-sqwk", attack_index=0),
                           _action("DECLARE_ATTACK", "svi-sqwk", attack_index=1)),
        ],
        "water": [
            _golden_action("water_avoid_duplicate_staryu", "setup", "enable_shuriken",
                           water_damaged_without_backup,
                           _action("PLAY_BASIC", "sv2-38", target_slot="bench_1"),
                           _action("PLAY_BASIC", "sv2-staryu", target_slot="bench_1")),
            _golden_action("water_open_with_tatsugiri", "setup", "establish_board",
                           _public_context(turn=1, hand=("sv2-tatsu", "sv2-staryu")),
                           _action("PLAY_BASIC", "sv2-tatsu", target_slot="active"),
                           _action("PLAY_BASIC", "sv2-staryu", target_slot="active")),
            _golden_action("water_evolve_greninja", "evolution", "establish_board", water_setup,
                           _action("EVOLVE", "sv2-grex"), _action("EVOLVE", "sv2-39")),
            _golden_choice("water_search_froakie_backup", "search", "enable_shuriken",
                           water_damaged_without_backup, _SEARCH_CHOICE,
                           "sv2-38", "sv2-staryu"),
            _golden_action("water_status_switch", "switch", "establish_board",
                           _public_context(active=_pokemon("sv2-keldeo", status=("asleep",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("water_torrent_damaged_active", "attack", "take_multi_prize", water_torrent,
                           _action("DECLARE_ATTACK", "sv2-grex", attack_index=1),
                           _action("DECLARE_ATTACK", "sv2-grex", attack_index=0)),
            _golden_choice("water_discard_energy_not_core", "resource_preservation",
                           "establish_board", water_setup, _DISCARD_CHOICE,
                           "sv1-ener-3", "sv2-grex"),
            _golden_action("water_avoid_starmie_no_backup", "loss_avoidance",
                           "establish_board", water_starmie_risk,
                           _action("DECLARE_ATTACK", "sv2-grex", attack_index=0),
                           _action("USE_ABILITY", "sv2-starm")),
            _golden_action("water_starmie_enables_torrent", "prize_route",
                           "enable_shuriken", water_starmie_combo,
                           _action("USE_ABILITY", "sv2-starm"),
                           _END_TURN),
            _golden_action("water_shuriken_wide_board", "attack", "enable_shuriken", water_wide,
                           _action("DECLARE_ATTACK", "sv2-grex", attack_index=0),
                           _action("DECLARE_ATTACK", "sv2-grex", attack_index=1)),
            _golden_action("water_candice_search", "search", "establish_board", water_setup,
                           _action("PLAY_TRAINER", "sv2-cand"), _END_TURN),
            _golden_action("water_tatsugiri_opening_acceleration", "attack",
                           "establish_board",
                           _public_context(turn=2,
                                           active=_pokemon("sv2-tatsu", energy=("sv1-ener-3",)),
                                           bench=(_pokemon("sv2-38"),)),
                           _action("DECLARE_ATTACK", "sv2-tatsu", attack_index=0),
                           _action("DECLARE_ATTACK", "sv2-tatsu", attack_index=1)),
        ],
        "psychic": [
            _golden_action("psychic_setup_natu", "setup", "build_xatu_engine", psychic_setup,
                           _action("PLAY_BASIC", "sv1-107"), _action("PLAY_BASIC", "sv1-109")),
            _golden_action("psychic_open_with_cresselia", "setup", "build_xatu_engine",
                           _public_context(turn=1),
                           _action("PLAY_BASIC", "sv1-113", target_slot="active"),
                           _action("PLAY_BASIC", "sv1-109", target_slot="active")),
            _golden_action("psychic_evolve_xatu", "evolution", "build_xatu_engine", psychic_setup,
                           _action("EVOLVE", "sv1-108"), _action("EVOLVE", "sv1-106")),
            _golden_choice("psychic_search_xatu", "search", "build_xatu_engine",
                           _public_context(active=_pokemon("sv1-109"),
                                           bench=(_pokemon("sv1-107"),)),
                           _SEARCH_CHOICE, "sv1-108", "sv1-ener-5"),
            _golden_action("psychic_status_switch", "switch", "build_xatu_engine",
                           _public_context(active=_pokemon("sv1-109", status=("confused",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("psychic_latios_clean_light", "attack", "scale_attackers",
                           _public_context(active=_pokemon("sv1-111"), bench=(_pokemon("sv1-108"),)),
                           _action("DECLARE_ATTACK", "sv1-111", attack_index=1),
                           _action("DECLARE_ATTACK", "sv1-111", attack_index=0)),
            _golden_action("psychic_houndstone_graveyard", "prize_route", "scale_attackers",
                           psychic_graveyard,
                           _action("DECLARE_ATTACK", "sv1-106", attack_index=0),
                           _action("DECLARE_ATTACK", "sv1-111", attack_index=0)),
            _golden_choice("psychic_discard_scaling_pokemon", "resource_preservation",
                           "scale_attackers", psychic_graveyard, _DISCARD_CHOICE,
                           "sv1-104", "sv1-108"),
            _golden_choice("psychic_keep_xatu_engine", "loss_avoidance", "build_xatu_engine",
                           psychic_setup, _DISCARD_CHOICE, "sv1-109", "sv1-108"),
            _golden_action("psychic_xatu_acceleration", "setup", "accelerate_energy",
                           psychic_engine, _action("USE_ABILITY", "sv1-108"), _END_TURN),
            _golden_action("psychic_closeout_clean_light", "attack", "scale_attackers",
                           _public_context(active=_pokemon("sv1-111"), bench=(_pokemon("sv1-108"),),
                                           own_prizes=1),
                           _action("DECLARE_ATTACK", "sv1-111", attack_index=1), _END_TURN),
            _golden_action("psychic_first_turn_cresselia_growth", "setup",
                           "build_xatu_engine",
                           _public_context(turn=2,
                                           active=_pokemon("sv1-113", energy=("sv1-ener-5",)),
                                           bench=(_pokemon("sv1-107"),)),
                           _action("DECLARE_ATTACK", "sv1-113", attack_index=0), _END_TURN),
        ],
    }

    lightning_setup = _public_context(turn=1, active=_pokemon("svl-thun"))
    lightning_ready = _public_context(
        active=_pokemon("svl-pikaex", energy=("sv1-ener-4",) * 3),
        bench=(_pokemon("svl-flaa2"),),
    )
    lightning_risk = _public_context(
        active=_pokemon("svl-pikaex", energy=("sv1-ener-4",) * 6),
    )
    lightning_opening = _public_context(
        turn=1,
        hand=("svl-mare2", "svl-zera"),
    )

    fighting_setup = _public_context(turn=1, active=_pokemon("svf-terr"))
    fighting_ready = _public_context(
        active=_pokemon("svf-luca", energy=("sv1-ener-6",) * 3),
        bench=(_pokemon("svf-klea"),),
    )
    fighting_risk = _public_context(
        active=_pokemon("svf-luca", damage=100, energy=("sv1-ener-6",) * 2),
        bench=(_pokemon("svf-klea"),),
    )

    colorless_setup = _public_context(turn=1, active=_pokemon("svi-stan"))
    colorless_grow = _public_context(
        active=_pokemon("svi-maus", energy=("svi-dtur",)),
        bench=(_pokemon("svi-tand"),),
        hand=("svi-nemb", "sv1-151"),
    )
    colorless_full = _public_context(
        active=_pokemon("svi-ambi", energy=("svi-dtur",)),
        bench=(_pokemon("svi-maus"), _pokemon("svi-tand"), _pokemon("svi-tand")),
        hand=("svi-nemb", "svi-cait", "sv1-151", "sv1-153", "sv1-176", "sv1-189"),
    )
    colorless_low_hand = _public_context(
        active=_pokemon("svi-gree", energy=("svi-dtur",) * 3),
        bench=(_pokemon("svi-maus"),),
        hand=("sv1-151", "sv1-153"),
    )

    result.update({
        "lightning": [
            _golden_action("lightning_setup_mareep", "setup", "charge_bench", lightning_setup,
                           _action("PLAY_BASIC", "svl-mare2"), _action("PLAY_BASIC", "svl-thun")),
            _golden_action("lightning_evolve_flaaffy", "evolution", "charge_bench", lightning_setup,
                           _action("EVOLVE", "svl-flaa2"), _action("EVOLVE", "svl-lant")),
            _golden_choice("lightning_search_pikachu", "search", "charge_bench", lightning_setup,
                           _SEARCH_CHOICE, "svl-pikaex", "sv1-ener-4"),
            _golden_action("lightning_status_switch", "switch", "charge_bench",
                           _public_context(active=_pokemon("svl-thun", status=("paralyzed",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("lightning_strong_volt_ready", "attack", "prepare_pikachu",
                           lightning_ready,
                           _action("DECLARE_ATTACK", "svl-pikaex", attack_index=1),
                           _action("DECLARE_ATTACK", "svl-pikaex", attack_index=0)),
            _golden_action("lightning_burst_last_prize", "prize_route", "burst_finish",
                           _public_context(active=_pokemon("svl-pikaex", energy=("sv1-ener-4",) * 3),
                                           bench=(_pokemon("svl-flaa2"),), own_prizes=1),
                           _action("DECLARE_ATTACK", "svl-pikaex", attack_index=1), _END_TURN),
            _golden_choice("lightning_discard_acceleration_energy", "resource_preservation",
                           "charge_bench", lightning_setup, _DISCARD_CHOICE,
                           "sv1-ener-4", "svl-pikaex"),
            _golden_action("lightning_avoid_overcommitted_volt", "loss_avoidance",
                           "charge_bench", lightning_risk,
                           _action("DECLARE_ATTACK", "svl-pikaex", attack_index=0),
                           _action("DECLARE_ATTACK", "svl-pikaex", attack_index=1)),
            _golden_action("lightning_generator_setup", "setup", "charge_bench", lightning_setup,
                           _action("PLAY_TRAINER", "sv1-170"), _END_TURN),
            _golden_action("lightning_flaaffy_engine", "resource_preservation",
                           "prepare_pikachu", lightning_ready,
                           _action("USE_ABILITY", "svl-flaa2"), _END_TURN),
            _golden_action("lightning_frontline_over_bench_engine", "setup",
                           "charge_bench", lightning_opening,
                           _action("PLAY_BASIC", "svl-zera", target_slot="active"),
                           _action("PLAY_BASIC", "svl-mare2", target_slot="active")),
        ],
        "fighting": [
            _golden_action("fighting_setup_riolu", "setup", "build_lucario", fighting_setup,
                           _action("PLAY_BASIC", "svf-rio"), _action("PLAY_BASIC", "svf-terr")),
            _golden_action("fighting_evolve_lucario", "evolution", "build_lucario", fighting_setup,
                           _action("EVOLVE", "svf-luca"), _action("EVOLVE", "svf-klea")),
            _golden_choice("fighting_search_lucario", "search", "build_lucario", fighting_setup,
                           _SEARCH_CHOICE, "svf-luca", "sv1-ener-6"),
            _golden_action("fighting_status_switch", "switch", "build_lucario",
                           _public_context(active=_pokemon("svf-terr", status=("asleep",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("fighting_kleavor_guillotine", "attack", "build_lucario", fighting_setup,
                           _action("DECLARE_ATTACK", "svf-klea", attack_index=0),
                           _action("DECLARE_ATTACK", "svf-klea", attack_index=1)),
            _golden_action("fighting_lucario_prize_route", "prize_route", "aura_burst",
                           _public_context(active=_pokemon("svf-luca", energy=("sv1-ener-6",) * 6),
                                           own_prizes=1),
                           _action("DECLARE_ATTACK", "svf-luca", attack_index=0), _END_TURN),
            _golden_choice("fighting_discard_energy_not_lucario", "resource_preservation",
                           "build_lucario", fighting_setup, _DISCARD_CHOICE,
                           "sv1-ener-6", "svf-luca"),
            _golden_action("fighting_avoid_lucario_self_ko", "loss_avoidance", "aura_burst",
                           fighting_risk,
                           _action("DECLARE_ATTACK", "svf-luca", attack_index=0),
                           _action("USE_ABILITY", "svf-luca")),
            _golden_action("fighting_safe_lucario_engine", "setup", "stack_fighting_energy",
                           _public_context(active=_pokemon("svf-luca"), bench=(_pokemon("svf-klea"),)),
                           _action("USE_ABILITY", "svf-luca"), _END_TURN),
            _golden_action("fighting_aura_attack", "attack", "aura_burst", fighting_ready,
                           _action("DECLARE_ATTACK", "svf-luca", attack_index=0), _END_TURN),
        ],
        "colorless": [
            _golden_action("colorless_setup_tandemaus", "setup", "fill_bench", colorless_setup,
                           _action("PLAY_BASIC", "svi-tand"), _action("PLAY_BASIC", "svi-stan")),
            _golden_action("colorless_evolve_maushold", "evolution", "fill_bench", colorless_setup,
                           _action("EVOLVE", "svi-maus"), _action("EVOLVE", "svi-ambi")),
            _golden_choice("colorless_search_maushold", "search", "fill_bench", colorless_setup,
                           _SEARCH_CHOICE, "svi-maus", "svi-dtur"),
            _golden_action("colorless_status_switch", "switch", "fill_bench",
                           _public_context(active=_pokemon("svi-stan", status=("confused",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("colorless_ambipom_large_hand", "attack", "family_pressure",
                           colorless_full,
                           _action("DECLARE_ATTACK", "svi-ambi", attack_index=1),
                           _action("DECLARE_ATTACK", "svi-ambi", attack_index=0)),
            _golden_action("colorless_family_prize_route", "prize_route", "family_pressure",
                           _public_context(active=_pokemon("svi-maus", energy=("svi-dtur",) * 2),
                                           bench=(_pokemon("svi-tand"), _pokemon("svi-maus")),
                                           hand=("svi-nemb",) * 6, own_prizes=1),
                           _action("DECLARE_ATTACK", "svi-maus", attack_index=0), _END_TURN),
            _golden_choice("colorless_discard_non_family", "resource_preservation", "fill_bench",
                           colorless_setup, _DISCARD_CHOICE, "svi-stan", "svi-maus"),
            _golden_action("colorless_avoid_greedent_dump", "loss_avoidance", "grow_hand",
                           colorless_low_hand,
                           _action("DECLARE_ATTACK", "svi-gree", attack_index=0),
                           _action("DECLARE_ATTACK", "svi-gree", attack_index=1)),
            _golden_action("colorless_greedent_full_hand", "attack", "family_pressure",
                           colorless_full,
                           _action("DECLARE_ATTACK", "svi-gree", attack_index=1),
                           _action("DECLARE_ATTACK", "svi-gree", attack_index=0)),
            _golden_action("colorless_special_energy_maushold", "resource_preservation",
                           "grow_hand", colorless_grow,
                           _action("ATTACH_ENERGY", "svi-dtur", target_card_id="svi-maus"),
                           _action("ATTACH_ENERGY", "svi-dtur", target_card_id="svi-ambi")),
        ],
    })

    dragon_setup = _public_context(turn=1, active=_pokemon("svg-dram"))
    dragon_search_ready = _public_context(
        turn=1, active=_pokemon("svg-dram"), bench=(_pokemon("svg-swa"),),
    )
    dragon_balance = _public_context(
        active=_pokemon("svg-alt", energy=("sv1-ener-3",)),
        bench=(_pokemon("svg-ceto"),),
    )
    dragon_ready = _public_context(
        active=_pokemon("svg-ceti", energy=("sv1-ener-3",) * 3),
        bench=(_pokemon("svg-alt", energy=("sv1-ener-3", "sv1-ener-8")),),
    )
    dragon_damaged = _public_context(
        active=_pokemon("svg-ceti", damage=140, energy=("sv1-ener-3",) * 3),
        bench=(_pokemon("svg-alt", energy=("sv1-ener-3", "sv1-ener-8")),),
    )
    dragon_healed = _public_context(
        active=_pokemon("svg-milt", healed=True, energy=("sv1-ener-3",) * 2),
        bench=(_pokemon("svg-alt", energy=("sv1-ener-3", "sv1-ener-8")),),
        own_prizes=1,
    )

    grass_setup = _public_context(turn=1, active=_pokemon("svg2-zaru"))
    grass_search_ready = _public_context(
        turn=1, active=_pokemon("svg2-zaru"), bench=(_pokemon("svg2-grot"),),
    )
    grass_evolve = _public_context(
        active=_pokemon("svg2-turt"),
        bench=(_pokemon("svg2-grot"), _pokemon("svg2-shro"), _pokemon("svg2-zaru")),
    )
    grass_pressure = _public_context(
        active=_pokemon("svg2-tort", energy=("sv1-ener-1",) * 3),
        bench=(_pokemon("svg2-grot"), _pokemon("svg2-brel"), _pokemon("svg2-empo")),
    )
    grass_revival = _public_context(
        active=_pokemon("svg2-tort"),
        bench=(_pokemon("svg2-brel"), _pokemon("svg2-zaru")),
        discard=("svg2-empo",),
    )

    steel_setup = _public_context(turn=1, active=_pokemon("svm-skarmory"))
    steel_transfer = _public_context(
        active=_pokemon("svm-zamazenta", energy=("sv1-ener-8",) * 3),
        bench=(_pokemon("svm-bronzong"), _pokemon("svm-zacian")),
    )
    steel_revenge = _public_context(
        active=_pokemon("svm-zamazenta", energy=("sv1-ener-8",) * 3),
        bench=(_pokemon("svm-bronzong"),),
        own_prizes=1,
        previous_knockouts=({
            "defeated_player": 0,
            "source_player": 1,
            "source_kind": "attack_damage",
            "cause_kind": "damage",
        },),
    )
    steel_threshold = _public_context(
        active=_pokemon("svm-zamazenta"),
        bench=(
            _pokemon("svm-bronzong"),
            _pokemon("svm-orthworm", energy=("sv1-ener-8", "sv1-ener-8")),
            _pokemon("svm-zacian"),
        ),
    )
    steel_wide = _public_context(
        active=_pokemon("svm-zacian", energy=("sv1-ener-8",) * 3),
        bench=(
            _pokemon("svm-bronzong"), _pokemon("svm-zamazenta"),
            _pokemon("svm-orthworm"), _pokemon("svm-skarmory"), _pokemon("svm-cobalion"),
        ),
    )

    darkness_setup = _public_context(turn=1, active=_pokemon("svd-seviper"))
    darkness_prime = _public_context(
        active=_pokemon("svd-mabosstiff-ex", energy=("sv1-ener-7",) * 3),
        bench=(_pokemon("svd-dodrio"),),
    )
    darkness_pride = _public_context(
        active=_pokemon("svd-mabosstiff-ex", energy=("sv1-ener-7",) * 3),
        bench=(_pokemon("svd-dodrio", damage=20),),
        own_prizes=1,
    )
    darkness_dodrio_risk = _public_context(
        active=_pokemon("svd-mabosstiff-ex", energy=("sv1-ener-7",) * 3),
        bench=(_pokemon("svd-dodrio", damage=90),),
    )
    darkness_patch = _public_context(
        active=_pokemon("svd-mabosstiff-ex"),
        bench=(_pokemon("svd-dodrio"),),
        discard=("sv1-ener-7", "sv1-ener-7"),
    )

    result.update({
        "dragon": [
            _golden_action("dragon_setup_swablu", "setup", "build_healing_core", dragon_setup,
                           _action("PLAY_BASIC", "svg-swa"), _action("PLAY_BASIC", "svg-dram")),
            _golden_action("dragon_evolve_altaria", "evolution", "build_healing_core", dragon_setup,
                           _action("EVOLVE", "svg-alt"), _action("EVOLVE", "svg-ceti")),
            _golden_choice("dragon_search_altaria", "search", "build_healing_core", dragon_search_ready,
                           _SEARCH_CHOICE, "svg-alt", "sv1-ener-3"),
            _golden_choice("dragon_search_swablu_without_prerequisite", "search",
                           "build_healing_core", dragon_setup,
                           _SEARCH_CHOICE, "svg-swa", "svg-alt"),
            _golden_action("dragon_status_switch", "switch", "build_healing_core",
                           _public_context(active=_pokemon("svg-dram", status=("asleep",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("dragon_cetitan_full_power", "attack", "healing_lock", dragon_ready,
                           _action("DECLARE_ATTACK", "svg-ceti", attack_index=1),
                           _action("DECLARE_ATTACK", "svg-ceti", attack_index=0)),
            _golden_action("dragon_miltank_healed_route", "prize_route", "healing_lock",
                           dragon_healed,
                           _action("DECLARE_ATTACK", "svg-milt", attack_index=0),
                           _action("DECLARE_ATTACK", "svg-dram", attack_index=0)),
            _golden_choice("dragon_discard_energy_not_altaria", "resource_preservation",
                           "build_healing_core", dragon_setup, _DISCARD_CHOICE,
                           "sv1-ener-3", "svg-alt"),
            _golden_action("dragon_avoid_damaged_sweeping", "loss_avoidance", "healing_lock",
                           dragon_damaged,
                           _action("DECLARE_ATTACK", "svg-ceti", attack_index=0),
                           _action("DECLARE_ATTACK", "svg-ceti", attack_index=1)),
            _golden_action("dragon_heal_damaged_board", "resource_preservation", "balance_energy",
                           _public_context(active=_pokemon("svg-alt", damage=80,
                                                          energy=("sv1-ener-3",))),
                           _action("USE_ABILITY", "svg-alt"), _END_TURN),
            _golden_action("dragon_balance_second_energy", "setup", "balance_energy",
                           dragon_balance,
                           _action("ATTACH_ENERGY", "sv1-ener-8", target_card_id="svg-alt"),
                           _action("ATTACH_ENERGY", "sv1-ener-3", target_card_id="svg-alt")),
        ],
        "grass": [
            _golden_action("grass_setup_turtwig", "setup", "fill_evolution_board", grass_setup,
                           _action("PLAY_BASIC", "svg2-turt"), _action("PLAY_BASIC", "svg2-zaru")),
            _golden_action("grass_evolve_torterra", "evolution", "evolve_swarm", grass_evolve,
                           _action("EVOLVE", "svg2-tort"), _action("EVOLVE", "svg2-brel")),
            _golden_choice("grass_search_torterra", "search", "fill_evolution_board", grass_search_ready,
                           _SEARCH_CHOICE, "svg2-tort", "sv1-ener-1"),
            _golden_choice("grass_search_turtwig_without_prerequisite", "search",
                           "fill_evolution_board", grass_setup,
                           _SEARCH_CHOICE, "svg2-turt", "svg2-tort"),
            _golden_action("grass_status_switch", "switch", "fill_evolution_board",
                           _public_context(active=_pokemon("svg2-zaru", status=("confused",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("grass_torterra_evolved_board", "attack", "evolution_pressure",
                           grass_pressure,
                           _action("DECLARE_ATTACK", "svg2-tort", attack_index=0),
                           _action("DECLARE_ATTACK", "svg2-tort", attack_index=1)),
            _golden_action("grass_torterra_prize_route", "prize_route", "evolution_pressure",
                           _public_context(active=_pokemon("svg2-tort"),
                                           bench=(_pokemon("svg2-grot"), _pokemon("svg2-brel"),
                                                  _pokemon("svg2-empo")), own_prizes=1),
                           _action("DECLARE_ATTACK", "svg2-tort", attack_index=0), _END_TURN),
            _golden_choice("grass_discard_empoleon", "resource_preservation",
                           "fill_evolution_board", grass_search_ready, _DISCARD_CHOICE,
                           "svg2-empo", "svg2-tort"),
            _golden_action("grass_retreat_special_condition", "loss_avoidance",
                           "fill_evolution_board",
                           _public_context(active=_pokemon("svg2-zaru", status=("paralyzed",))),
                           _action("RETREAT", "svg2-zaru"), _END_TURN),
            _golden_action("grass_empoleon_empty_hand_revival", "setup",
                           "evolve_swarm", grass_revival,
                           _action("USE_ABILITY", "svg2-empo"), _END_TURN),
            _golden_action("grass_zarude_opening_search", "search", "fill_evolution_board",
                           grass_setup,
                           _action("DECLARE_ATTACK", "svg2-zaru", attack_index=0),
                           _action("DECLARE_ATTACK", "svg2-zaru", attack_index=1)),
        ],
        "steel": [
            _golden_action("steel_setup_bronzor", "setup", "build_metal_board", steel_setup,
                           _action("PLAY_BASIC", "svm-bronzor"),
                           _action("PLAY_BASIC", "svm-skarmory")),
            _golden_action("steel_evolve_bronzong", "evolution", "enable_transfer",
                           _public_context(active=_pokemon("svm-zamazenta"),
                                           bench=(_pokemon("svm-bronzor"),)),
                           _action("EVOLVE", "svm-bronzong"),
                           _action("PLAY_BASIC", "svm-bronzor")),
            _golden_choice("steel_search_zacian", "search", "build_metal_board", steel_setup,
                           _SEARCH_CHOICE, "svm-zacian", "sv1-ener-8"),
            _golden_action("steel_status_switch", "switch", "build_metal_board",
                           _public_context(active=_pokemon("svm-skarmory", status=("asleep",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("steel_zacian_blade_empty_bench", "attack", "build_metal_board",
                           _public_context(active=_pokemon("svm-zacian")),
                           _action("DECLARE_ATTACK", "svm-zacian", attack_index=1),
                           _action("DECLARE_ATTACK", "svm-zacian", attack_index=0)),
            _golden_action("steel_zamazenta_revenge", "prize_route", "fortress_pressure",
                           steel_revenge,
                           _action("DECLARE_ATTACK", "svm-zamazenta", attack_index=0),
                           _action("DECLARE_ATTACK", "svm-zacian", attack_index=1)),
            _golden_choice("steel_discard_metal_for_recovery", "resource_preservation",
                           "build_metal_board", steel_setup, _DISCARD_CHOICE,
                           "sv1-ener-8", "svm-zacian"),
            _golden_action("steel_retreat_special_condition", "loss_avoidance",
                           "build_metal_board",
                           _public_context(active=_pokemon("svm-skarmory", status=("paralyzed",))),
                           _action("RETREAT", "svm-skarmory"), _END_TURN),
            _golden_action("steel_orthworm_third_energy", "resource_preservation",
                           "fortress_pressure", steel_threshold,
                           _action("ATTACH_ENERGY", "sv1-ener-8", target_card_id="svm-orthworm"),
                           _action("ATTACH_ENERGY", "sv1-ener-8", target_card_id="svm-zacian")),
            _golden_action("steel_zacian_wide_legion", "attack", "fortress_pressure", steel_wide,
                           _action("DECLARE_ATTACK", "svm-zacian", attack_index=0),
                           _action("DECLARE_ATTACK", "svm-zacian", attack_index=1)),
        ],
        "darkness": [
            _golden_action("darkness_setup_maschiff", "setup", "build_dual_lines", darkness_setup,
                           _action("PLAY_BASIC", "svd-maschiff"),
                           _action("PLAY_BASIC", "svd-seviper")),
            _golden_action("darkness_evolve_mabosstiff", "evolution", "build_dual_lines",
                           darkness_setup,
                           _action("EVOLVE", "svd-mabosstiff-ex"),
                           _action("EVOLVE", "svd-dodrio")),
            _golden_choice("darkness_search_mabosstiff", "search", "build_dual_lines",
                           darkness_setup, _SEARCH_CHOICE,
                           "svd-mabosstiff-ex", "sv1-ener-7"),
            _golden_action("darkness_status_switch", "switch", "build_dual_lines",
                           _public_context(active=_pokemon("svd-seviper", status=("confused",))),
                           _action("PLAY_TRAINER", "sv1-150"), _END_TURN),
            _golden_action("darkness_pride_damaged_bench", "attack", "pride_finish",
                           darkness_pride,
                           _action("DECLARE_ATTACK", "svd-mabosstiff-ex", attack_index=1),
                           _action("DECLARE_ATTACK", "svd-mabosstiff-ex", attack_index=0)),
            _golden_action("darkness_pride_prize_route", "prize_route", "pride_finish",
                           darkness_pride,
                           _action("DECLARE_ATTACK", "svd-mabosstiff-ex", attack_index=1),
                           _END_TURN),
            _golden_choice("darkness_discard_patch_energy", "resource_preservation",
                           "build_dual_lines", darkness_setup, _DISCARD_CHOICE,
                           "sv1-ener-7", "svd-mabosstiff-ex"),
            _golden_action("darkness_avoid_dodrio_self_ko", "loss_avoidance",
                           "pride_finish", darkness_dodrio_risk,
                           _action("DECLARE_ATTACK", "svd-mabosstiff-ex", attack_index=1),
                           _action("USE_ABILITY", "svd-dodrio")),
            _golden_action("darkness_patch_live_resource", "setup", "prime_damage_engine",
                           darkness_patch,
                           _action("PLAY_TRAINER", "svd-dark-patch"), _END_TURN),
            _golden_action("darkness_intimidate_without_damage", "attack",
                           "prime_damage_engine", darkness_prime,
                           _action("DECLARE_ATTACK", "svd-mabosstiff-ex", attack_index=0),
                           _action("DECLARE_ATTACK", "svd-mabosstiff-ex", attack_index=1)),
        ],
    })

    return result


GOLDEN_SCENARIOS = _build_golden_scenarios()
for _deck_key, _scenarios in GOLDEN_SCENARIOS.items():
    AI_STRATEGIES[_deck_key]["golden_scenarios"] = deepcopy(_scenarios)


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


def runtime_hook_hash(deck_key: str) -> str:
    """Hash the shared strategy contract together with one runtime hook."""
    hook_name = RUNTIME_HOOK_FILES.get(deck_key)
    if hook_name is None:
        raise ValueError(f"Unknown runtime strategy hook: {deck_key}")
    digest = hashlib.sha256()
    for file_name in ("deck_strategy.gd", hook_name):
        path = RUNTIME_STRATEGY_ROOT / file_name
        if not path.is_file():
            raise FileNotFoundError(f"Missing runtime strategy hook: {path}")
        digest.update(file_name.encode("utf-8"))
        digest.update(b"\0")
        normalized_source = (
            path.read_text(encoding="utf-8")
            .replace("\r\n", "\n")
            .replace("\r", "\n")
        )
        digest.update(normalized_source.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def _exported_strategy(deck_key: str, strategy: Mapping[str, Any]) -> dict[str, Any]:
    payload = deepcopy(dict(strategy))
    payload["runtime_hook_hash"] = runtime_hook_hash(deck_key)
    return _with_content_hash(payload)


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

    golden_scenarios = strategy.get("golden_scenarios")
    if (
        not isinstance(golden_scenarios, list)
        or not 8 <= len(golden_scenarios) <= 12
    ):
        errors.append(f"{deck_key}: golden_scenarios must contain 8-12 cases")
        golden_scenarios = []
    scenario_ids: set[str] = set()
    scenario_categories: set[str] = set()
    for index, scenario in enumerate(golden_scenarios):
        prefix = f"{deck_key}.golden_scenarios[{index}]"
        if not isinstance(scenario, Mapping):
            errors.append(f"{prefix}: must be an object")
            continue
        scenario_id = scenario.get("id")
        if (
            not isinstance(scenario_id, str)
            or not scenario_id
            or scenario_id in scenario_ids
        ):
            errors.append(f"{prefix}: invalid or duplicate id")
        else:
            scenario_ids.add(scenario_id)
        category = scenario.get("category")
        if not isinstance(category, str) or category not in GOLDEN_CATEGORIES:
            errors.append(f"{prefix}: unknown category {category}")
        else:
            scenario_categories.add(category)
        if scenario.get("expected") != "higher":
            errors.append(f"{prefix}: expected must be higher")
        if scenario.get("stage") not in goal_ids:
            errors.append(f"{prefix}: stage must name a declared stage goal")
        if not isinstance(scenario.get("context"), Mapping):
            errors.append(f"{prefix}: public context must be an object")
        preferred = scenario.get("preferred")
        over = scenario.get("over")
        if not isinstance(preferred, Mapping) or not isinstance(over, Mapping):
            errors.append(f"{prefix}: preferred and over must be objects")
        surface = scenario.get("surface")
        if surface == "action":
            if (
                not isinstance(preferred, Mapping)
                or not isinstance(preferred.get("kind"), str)
                or not preferred.get("kind")
                or not isinstance(over, Mapping)
                or not isinstance(over.get("kind"), str)
                or not over.get("kind")
            ):
                errors.append(f"{prefix}: action comparisons require two kinds")
        elif surface == "choice":
            if not isinstance(scenario.get("choice_context"), Mapping):
                errors.append(f"{prefix}: choice comparison requires choice_context")
        else:
            errors.append(f"{prefix}: surface must be action or choice")
        invalid_cards = sorted(_declared_card_ids(scenario) - deck_card_ids)
        if invalid_cards:
            errors.append(f"{prefix}: cards not in deck: {', '.join(invalid_cards)}")
    missing_categories = sorted(GOLDEN_CATEGORIES - scenario_categories)
    if missing_categories:
        errors.append(
            f"{deck_key}: golden scenarios miss categories: "
            + ", ".join(missing_categories)
        )

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
    golden_total = 0
    for deck_key in sorted(expected_keys & strategy_keys):
        strategy = AI_STRATEGIES[deck_key]
        golden_total += len(strategy.get("golden_scenarios", []))
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

    if golden_total < 100:
        errors.append("release strategies must declare at least 100 golden scenarios")

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
        "fallback": _exported_strategy("generic", FALLBACK_STRATEGY),
        "strategies": {
            key: _exported_strategy(key, AI_STRATEGIES[key])
            for key in sorted(AI_STRATEGIES)
        },
    }
    return _with_content_hash(payload)

"""Deck-specific strategy profiles for challenge-mode AI."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any

POLICY_VERSION = 1
DEFAULT_POLICY_PATH = os.path.join("data", "ai_policies.json")


@dataclass(frozen=True)
class DeckAIProfile:
    key: str
    name: str
    core_cards: set[str] = field(default_factory=set)
    engine_cards: set[str] = field(default_factory=set)
    setup_active: set[str] = field(default_factory=set)
    preferred_bench: set[str] = field(default_factory=set)
    evolution_cards: set[str] = field(default_factory=set)
    energy_types: set[str] = field(default_factory=set)
    trainer_cards: set[str] = field(default_factory=set)
    attack_keywords: tuple[str, ...] = ()
    weights: dict[str, float] = field(default_factory=dict)


BASE_WEIGHTS: dict[str, float] = {
    "core_in_play": 70.0,
    "core_in_hand": 24.0,
    "engine_in_play": 42.0,
    "engine_in_hand": 18.0,
    "preferred_bench": 18.0,
    "evolved_count": 34.0,
    "matching_energy_attached": 18.0,
    "matching_energy_hand": 8.0,
    "trainer_in_hand": 10.0,
    "damaged_self": -0.18,
    "low_hp_targets": 24.0,
    "ko_pressure": 0.9,
    "hand_size": 3.0,
    "bench_count": 10.0,
}


def _weights(**overrides: float) -> dict[str, float]:
    result = dict(BASE_WEIGHTS)
    result.update(overrides)
    return result


DECK_AI_PROFILES: dict[str, DeckAIProfile] = {
    "fire": DeckAIProfile(
        key="fire",
        name="Infernape burn engine",
        core_cards={"svi-infr"},
        engine_cards={"svi-chim", "svi-monf", "svi-chiy", "svi-erec", "sv3-134"},
        setup_active={"svi-chim", "svi-ente", "svi-hrot"},
        preferred_bench={"svi-chim", "svi-sqwk", "svi-chiy"},
        evolution_cards={"svi-monf", "svi-infr"},
        energy_types={"Fire"},
        trainer_cards={"sv1-152", "sv1-153", "svi-erec", "svi-mela"},
        attack_keywords=("discard", "mill", "energy"),
        weights=_weights(core_in_play=90, evolved_count=48, matching_energy_attached=22, ko_pressure=1.1),
    ),
    "water": DeckAIProfile(
        key="water",
        name="Greninja ex snipe",
        core_cards={"sv2-grex", "sv2-starm"},
        engine_cards={"sv2-38", "sv2-39", "sv2-staryu", "sv2-cand"},
        setup_active={"sv2-38", "sv2-staryu", "sv2-keldeo", "sv1-49"},
        preferred_bench={"sv2-38", "sv2-staryu", "sv2-tatsu", "sv2-delib"},
        evolution_cards={"sv2-39", "sv2-grex", "sv2-starm"},
        energy_types={"Water"},
        trainer_cards={"sv2-cand", "sv1-152", "sv1-153", "sv2-catch"},
        attack_keywords=("bench", "snipe", "damage"),
        weights=_weights(low_hp_targets=58, ko_pressure=1.25, core_in_play=82, preferred_bench=25),
    ),
    "psychic": DeckAIProfile(
        key="psychic",
        name="Xatu psychic acceleration",
        core_cards={"sv1-108", "sv1-111", "sv1-113"},
        engine_cards={"sv1-107", "sv1-109", "sv1-114", "sv1-171"},
        setup_active={"sv1-107", "sv1-109", "sv1-111", "sv1-113"},
        preferred_bench={"sv1-107", "sv1-113", "sv1-114", "sv1-104"},
        evolution_cards={"sv1-108", "sv1-106"},
        energy_types={"Psychic"},
        trainer_cards={"sv1-171", "sv1-204", "sv1-153"},
        attack_keywords=("attach", "draw", "energy"),
        weights=_weights(engine_in_play=60, matching_energy_hand=18, hand_size=5, bench_count=14),
    ),
    "lightning": DeckAIProfile(
        key="lightning",
        name="Pikachu ex tempo",
        core_cards={"svl-pikaex", "svl-flaa2"},
        engine_cards={"svl-mare2", "svl-ensw", "sv1-170", "svl-trks"},
        setup_active={"svl-pikaex", "svl-mare2", "svl-chin", "svl-emol"},
        preferred_bench={"svl-pikaex", "svl-mare2", "svl-chin"},
        evolution_cards={"svl-flaa2", "svl-lant"},
        energy_types={"Lightning"},
        trainer_cards={"sv1-170", "svl-ensw", "svl-vitb", "svl-zinn"},
        attack_keywords=("220", "discard", "energy"),
        weights=_weights(ko_pressure=1.45, matching_energy_attached=26, core_in_play=86, low_hp_targets=36),
    ),
    "fighting": DeckAIProfile(
        key="fighting",
        name="Lucario fighting burst",
        core_cards={"svf-luca", "svf-klea"},
        engine_cards={"svf-rio", "svf-pass", "svf-farf", "svf-hawl", "svf-ensw2"},
        setup_active={"svf-rio", "svf-scyt", "svf-pass", "svf-terr"},
        preferred_bench={"svf-rio", "svf-scyt", "svf-farf"},
        evolution_cards={"svf-luca", "svf-klea"},
        energy_types={"Fighting"},
        trainer_cards={"svf-ensw2", "svf-potion", "svi-erec", "svf-houb"},
        attack_keywords=("discard", "fighting", "self"),
        weights=_weights(evolved_count=48, matching_energy_attached=28, damaged_self=-0.05, ko_pressure=1.3),
    ),
    "colorless": DeckAIProfile(
        key="colorless",
        name="Maushold hand-size pressure",
        core_cards={"svi-maus", "svi-ambi", "svi-gree"},
        engine_cards={"svi-tand", "svi-aipo", "svi-skwv", "svi-inde", "svi-cait"},
        setup_active={"svi-tand", "svi-aipo", "svi-skwv", "svi-inde"},
        preferred_bench={"svi-tand", "svi-aipo", "svi-skwv", "svi-inde"},
        evolution_cards={"svi-maus", "svi-ambi", "svi-gree"},
        energy_types={"Colorless"},
        trainer_cards={"svi-enst", "svi-nemb", "svi-cait", "svi-popp"},
        attack_keywords=("hand", "draw", "special"),
        weights=_weights(hand_size=9, core_in_hand=34, preferred_bench=28, matching_energy_attached=14),
    ),
    "dragon": DeckAIProfile(
        key="dragon",
        name="Altaria ex healing control",
        core_cards={"svg-alt", "svg-ceti"},
        engine_cards={"svg-swa", "svg-dram", "svg-milt", "svg-beri", "svg-chef"},
        setup_active={"svg-swa", "svg-dram", "svg-milt", "svg-ceto"},
        preferred_bench={"svg-swa", "svg-ceto", "svg-milt", "svg-tatsu"},
        evolution_cards={"svg-alt", "svg-ceti"},
        energy_types={"Water", "Metal"},
        trainer_cards={"svg-chef", "svg-beri", "svf-potion", "svl-ensw"},
        attack_keywords=("heal", "prevent", "immune"),
        weights=_weights(damaged_self=-0.32, core_in_play=88, evolved_count=44, bench_count=12),
    ),
    "grass": DeckAIProfile(
        key="grass",
        name="Torterra evolution swarm",
        core_cards={"svg2-tort", "svg2-brel", "svg2-empo"},
        engine_cards={"svg2-turt", "svg2-grot", "svg2-shro", "svg2-zaru", "svg2-gard"},
        setup_active={"svg2-turt", "svg2-shro", "svg2-zaru"},
        preferred_bench={"svg2-turt", "svg2-shro", "svg2-zaru"},
        evolution_cards={"svg2-grot", "svg2-tort", "svg2-brel", "svg2-empo"},
        energy_types={"Grass", "Rainbow"},
        trainer_cards={"sv1-152", "svg2-gard", "svg2-exps", "sv1-153"},
        attack_keywords=("evolved", "evolution", "bench"),
        weights=_weights(evolved_count=70, bench_count=22, core_in_play=80, preferred_bench=34),
    ),
}


def get_deck_ai_profile(deck_key: str | None) -> DeckAIProfile:
    if deck_key and deck_key in DECK_AI_PROFILES:
        return DECK_AI_PROFILES[deck_key]
    return DeckAIProfile(key=deck_key or "generic", name="Generic challenge AI", weights=dict(BASE_WEIGHTS))


def load_policy_weights(deck_key: str | None, policy_path: str | None = DEFAULT_POLICY_PATH) -> dict[str, float]:
    """Load trained policy weights for a deck, returning an empty dict on any problem."""
    if not deck_key or not policy_path:
        return {}
    try:
        with open(policy_path, "r", encoding="utf-8") as fh:
            payload: dict[str, Any] = json.load(fh)
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return {}
    if payload.get("version") != POLICY_VERSION:
        return {}
    policy = ((payload.get("policies") or {}).get(deck_key) or {})
    if not _policy_eval_passes(policy):
        return {}
    weights = policy.get("weights") or {}
    if not isinstance(weights, dict):
        return {}
    loaded: dict[str, float] = {}
    for key, value in weights.items():
        try:
            loaded[str(key)] = float(value)
        except (TypeError, ValueError):
                continue
    return loaded


def _policy_eval_passes(policy: dict[str, Any]) -> bool:
    """Reject candidate policies that evaluated worse than their profile baseline."""
    if not isinstance(policy, dict):
        return False
    metadata = policy.get("metadata") or {}
    if metadata.get("accepted") is False:
        return False
    eval_info = policy.get("eval") or {}
    try:
        games = int(eval_info.get("games") or 0)
    except (TypeError, ValueError):
        games = 0
    if games <= 0:
        return True

    baseline = eval_info.get("baseline") or {}
    trained = eval_info.get("trained") or {}
    try:
        baseline_wins = int(baseline.get("wins", 0))
        trained_wins = int(trained.get("wins", 0))
        baseline_losses = int(baseline.get("losses", 0))
        trained_losses = int(trained.get("losses", 0))
        baseline_score = float(baseline.get("avg_score", 0.0))
        trained_score = float(trained.get("avg_score", 0.0))
    except (TypeError, ValueError):
        return False

    baseline_points = baseline_wins - baseline_losses
    trained_points = trained_wins - trained_losses
    if trained_points > baseline_points:
        return True
    if trained_points == baseline_points and trained_score > baseline_score + 25.0:
        return True
    return False


def merged_profile_weights(
    profile: DeckAIProfile, policy_weights: dict[str, float] | None = None
) -> dict[str, float]:
    weights = dict(profile.weights or BASE_WEIGHTS)
    if policy_weights:
        weights.update(policy_weights)
    return weights

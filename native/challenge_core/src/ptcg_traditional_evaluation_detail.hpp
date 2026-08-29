#pragma once

#include "ptcg_traditional_card.hpp"
#include "ptcg_traditional_trusted.hpp"
#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai::traditional_trusted_detail {

using traditional_value::array_contains;
using traditional_value::array_field;
using traditional_value::bool_field;
using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::lower_ascii;
using traditional_value::string_field;
using traditional_card::active;
using traditional_card::bench_count;
using traditional_card::card;
using traditional_card::downgrades_rainbow;
using traditional_card::energy_type_count;
using traditional_card::energy_unit_count;
using traditional_card::energy_units;
using traditional_card::has_subtype;
using traditional_card::is_basic_energy;
using traditional_card::is_basic_pokemon;
using traditional_card::is_energy;
using traditional_card::is_pokemon;
using traditional_card::is_special_energy;
using traditional_card::is_stage1;
using traditional_card::is_stage2;
using traditional_card::is_trainer;
using traditional_card::missing_energy;
using traditional_card::player;

struct DeckProfile {
    const Value *value = nullptr;

    const Value::Array &cards(const char *role) const;
    bool contains(const char *role, const std::string &card_id) const;
    std::int64_t high_impact_damage_floor() const;
};

DeckProfile profile(const Value &catalog, const std::string &deck_key);

bool contains(const std::vector<std::string> &values, const std::string &needle);

std::vector<const Value *> board(const Value &state, std::int32_t actor);

bool had_knockout(const Value &state, std::int32_t defeated, bool attack_only);

void append_flattened_effect(
    const Value &effect,
    std::vector<const Value *> &result
);

std::vector<const Value *> flatten_effects(const Value::Array &effects);

bool branch_has_effect(const Value *branch, const std::string &kind);

bool condition_applies(
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const Value &cards
);

std::int64_t effect_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    const Value &cards
);

std::int64_t branch_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value *branch,
    const Value &cards
);

std::int64_t effect_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    const Value &cards
);

bool modifier_kind(
    const Value *pokemon,
    const std::string &kind,
    const std::string &text = {}
);

std::int64_t reference_modified_attack_damage(
    const Value &state,
    std::int32_t actor,
    const Value &attacker,
    const Value &defender,
    std::int64_t base_damage,
    const Value &cards,
    bool ignore_defender_damage_effects
);

std::int64_t estimated_attack_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::size_t attack_index,
    const Value &cards
);

std::int64_t best_available_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

std::int64_t best_ready_damage_for_pokemon(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const Value &cards
);

std::int64_t best_missing(const Value &cards, const Value *pokemon);

std::int64_t printed_best_damage(const Value &cards, const Value *pokemon);

std::int64_t action_strength_damage(
    const Value &cards,
    const Value &definition,
    const Value *pokemon,
    std::int64_t energy_count
);

const Value *pokemon_at(const Value &owner, const std::string &slot);

bool modifier_kind(const Value *pokemon, const std::string &kind, const std::string &text);

std::int64_t modifier_sum(const Value *pokemon, const std::string &kind);

double deck_pressure(const Value &owner);

std::string deck_key(const Value &state, std::int32_t actor);

bool energy_matches_profile(
    const Value &cards,
    const std::string &card_id,
    const std::string &key
);

std::int64_t energy_profile_match_count(
    const Value &cards,
    const std::string &card_id,
    const std::string &key
);

double card_priority(const Value &cards, const std::string &card_id, const std::string &key);

Value pokemon_with_extra_energy(
    const Value &pokemon,
    const std::string &energy_card_id
);

std::int64_t best_missing_with_extra(
    const Value &cards,
    const Value *pokemon,
    const std::string &energy_card_id
);

bool place_candidate_in_active(
    Value &simulation,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot
);

std::int64_t estimated_damage_for_pokemon(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    std::size_t attack_index,
    const Value &cards
);

std::int64_t pokemon_attack_damage_ceiling(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    std::size_t attack_index,
    const Value &cards
);

std::int64_t best_pokemon_damage_for_state(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const Value &cards
);

struct HighImpactPlan {
    std::int64_t damage = 0;
    std::int64_t missing = 99;
    double impact = -std::numeric_limits<double>::infinity();
};

HighImpactPlan high_impact_attack_plan(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &energy_card_id,
    const Value &cards
);

std::int64_t high_impact_missing_energy(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &energy_card_id,
    const Value &cards
);

bool commands_require_belief_sampling(const Value &commands);

std::int64_t best_deterministic_available_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

bool has_public_tatsugiri_acceleration_target(
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

double energy_plan_target_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &energy_card_id,
    const std::string &key,
    const Value &cards
);

bool has_better_bench_energy_plan(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &energy_card_id,
    const std::string &key,
    const Value &cards
);

Value::Array expand_deck(const Value &decks, const std::string &key);

std::vector<std::string> pre_evolution_ids(
    const Value &cards,
    const Value &decks,
    const std::string &card_id,
    const std::string &key
);

struct LineParts {
    std::vector<std::string> stage1;
    std::vector<std::string> basic;
};

LineParts line_parts(
    const Value &cards,
    const Value &decks,
    const std::string &core,
    const std::string &key
);

bool zone_has(const Value::Array &zone, const std::vector<std::string> &ids);

bool in_play(const Value &state, std::int32_t actor, const std::vector<std::string> &ids);

std::string primary_core(
    const Value &cards,
    const Value &decks,
    const std::string &key
);

double active_evolve_blocking_penalty(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &evolve_target,
    const std::string &evolved_card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double promotion_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &key,
    const Value &cards
);

bool redundant_same_pokemon_retreat(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &active_pokemon,
    const Value &target,
    const std::string &target_slot,
    const std::string &key,
    const Value &cards
);

bool retreat_has_good_target(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &active_pokemon,
    const Value &target,
    const std::string &target_slot,
    const std::string &key,
    const Value &cards
);

double focus_multiplier(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks,
    const std::string &core,
    const std::string &key
);

double core_line_value(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks,
    const std::string &key
);

double active_prize_threat(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

double ready_attackers(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &key
);

double active_ko_risk(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &key
);

bool has_energy_target(const Value &state, std::int32_t actor, const Value &cards);

double resource_outs(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks,
    const std::string &key
);

std::int64_t count_in_play(
    const Value &state,
    std::int32_t actor,
    const std::vector<std::string> &ids
);

std::int64_t count_in_zone(
    const Value::Array &zone,
    const std::string &card_id
);

double core_evolution_line_card_bonus(
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks,
    bool removing_one
);

bool energy_improves_attack_readiness(
    const Value &state,
    std::int32_t actor,
    const std::string &energy_card_id,
    const Value &cards
);

std::int64_t helpful_hand_energy_count(
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

double lone_active_backup_search_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

bool has_core_basic_out_in_deck(
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards
);

double bench_setup_search_card_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards
);

double card_keep_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks,
    bool removing_one = false
);

double deck_outs_quality(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double hand_size_plan(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &deck_key
);

double semantic_draw_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t amount,
    bool refresh,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

bool card_matches_filter(
    const Value &cards,
    const std::string &card_id,
    const std::string &filter
);

Value::Array filter_cards(
    const Value::Array &zone,
    const std::string &filter,
    const Value &cards
);

double semantic_search_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

Value::Array public_unseen_deck_pool(
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double semantic_look_top_deck_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double semantic_houb_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t target_hand_size,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double clara_recovery_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double tactical_target_priority(
    const RulesSession &position,
    const Value &pokemon,
    const Value &cards
);

double semantic_energy_accel_value(
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards
);

double semantic_healing_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

double semantic_switch_self_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &key,
    const Value &cards
);

double semantic_switch_opponent_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

double semantic_energy_disruption_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

bool energy_card_matches_type_at(
    const Value &cards,
    const Value::Array &attached,
    std::size_t card_index,
    std::string energy_type
);

double energy_relocate_value(
    const Value &state,
    std::int32_t actor,
    const Value &params,
    const Value &cards
);

double self_energy_discard_cost(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    std::int64_t requested_amount,
    const Value &cards
);

double self_fighting_energy_discard_cost(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    const Value &cards
);

double expected_self_energy_discard_cost(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value::Array &effects,
    const std::string &source_slot,
    const Value &cards,
    double probability = 1.0
);

double semantic_hand_disruption_value(
    const Value &state,
    std::int32_t actor
);

double semantic_status_effect_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &effect_type,
    const Value &params,
    const Value &cards
);

double self_discard_source_cost(
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    const Value &cards
);

double semantic_best_bench_damage_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t damage,
    const Value &cards
);

double semantic_damage_effect_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    const std::string &source_slot,
    const Value &cards
);

std::optional<double> simple_effects_tactical_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value::Array &effects,
    const std::string &source_slot,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double starmie_torrent_followup_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &source_slot,
    const Value &cards
);

bool attack_draw_pressure_is_unsafe(
    const Value &state,
    std::int32_t actor,
    const Value::Array &effects
);

std::int64_t best_potential_retaliation_damage(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

bool attack_feeds_dangerous_retaliation(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int64_t damage,
    const Value &cards
);

double hand_size_plan(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &deck_key
);

// _hand_size_attack_plan_value is a narrow public-state heuristic. The exact
// implementation is below after its helper declarations.
double hand_size_plan(
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const std::string &deck_key
);

double status_lock(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value *pokemon,
    const Value &cards
);

double protection(
    const RulesSession &position,
    const Value *pokemon
);

double player_score(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks
);

Value player_score_components(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards,
    const Value &decks
);

std::string choice_option_card_id(
    const Value &option,
    const Value &cards
);

std::string choice_option_slot(const Value &option);

std::int32_t choice_option_player(
    const Value &option,
    std::int32_t fallback
);

bool choice_option_is_hand_card(const Value &option);

std::string choice_energy_card_id(
    const Value &presentation,
    const Value &cards
);

std::string choice_option_energy_card_id(
    const Value &option,
    const Value &cards
);

std::string choice_score_mode(
    const Value &choice,
    std::int32_t actor
);

bool discard_fuels_damage_plan(
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const Value &cards
);

double discard_choice_score(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &card_id,
    const std::string &key,
    const Value &cards,
    const Value &decks,
    bool removing_from_hand
);

double energy_choice_target_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &slot,
    const std::string &energy_card_id,
    const std::string &key,
    const Value &cards
);

double energy_source_choice_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const std::string &slot,
    const Value &presentation,
    const std::string &key,
    const Value &cards
);

double switch_opponent_attack_route_bonus(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    std::int32_t target_player,
    const Value &target,
    std::string target_slot,
    const Value &cards
);

double target_choice_value(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &choice,
    std::int32_t target_player,
    const Value &pokemon,
    const std::string &slot,
    const Value &presentation,
    const Value &cards
);

std::optional<double> base_choice_option_score(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &choice,
    const Value &option,
    const Value &cards,
    const Value &decks
);

std::vector<std::string> energy_plan_evolution_descendants(
    const Value &cards,
    const Value &decks,
    const std::string &source_card_id,
    const std::string &key
);

double energy_attack_plan_for_card(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &source,
    const std::string &slot,
    const std::string &card_id,
    std::int64_t opponent_hp,
    std::int64_t opponent_prizes,
    const Value &cards
);

double energy_attack_plan_utility(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &pokemon,
    const std::string &slot,
    const std::string &key,
    const Value &cards,
    const Value &decks
);

double public_energy_distribution_board_utility(
    const RulesSession &position,
    const Value &state,
    std::int32_t actor,
    const Value &cards
);

} // namespace ptcg::ai::traditional_trusted_detail

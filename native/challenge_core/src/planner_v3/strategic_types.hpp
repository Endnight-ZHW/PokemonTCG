#pragma once

#include "ptcg_value.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <set>
#include <string>
#include <vector>

namespace ptcg::ai::planner_v3 {

inline constexpr int STRATEGIC_INTENT_SEARCH_VERSION = 3;
inline constexpr const char *STRATEGIC_INTENT_ENGINE_ID =
    "strategic_intent_v3";

enum class IntentKind {
    WinNow,
    TakePrizeSafely,
    PreventImmediateLoss,
    PrepareNextAttacker,
    AdvanceAttackerLine,
    EstablishEngine,
    ImproveHand,
    DisruptOpponent,
    RecoverResources,
    EndTurnSafely,
};

enum class RiskMode {
    LowVariance,
    Balanced,
    SeekUpside,
};

enum class DeliberationLevel : std::int32_t {
    D0 = 0,
    D1 = 1,
    D2 = 2,
    D3 = 3,
};

inline const char *intent_name(IntentKind value) noexcept {
    switch (value) {
        case IntentKind::WinNow: return "WIN_NOW";
        case IntentKind::TakePrizeSafely: return "TAKE_PRIZE_SAFELY";
        case IntentKind::PreventImmediateLoss: return "PREVENT_IMMEDIATE_LOSS";
        case IntentKind::PrepareNextAttacker: return "PREPARE_NEXT_ATTACKER";
        case IntentKind::AdvanceAttackerLine: return "ADVANCE_ATTACKER_LINE";
        case IntentKind::EstablishEngine: return "ESTABLISH_ENGINE";
        case IntentKind::ImproveHand: return "IMPROVE_HAND";
        case IntentKind::DisruptOpponent: return "DISRUPT_OPPONENT";
        case IntentKind::RecoverResources: return "RECOVER_RESOURCES";
        case IntentKind::EndTurnSafely: return "END_TURN_SAFELY";
    }
    return "END_TURN_SAFELY";
}

inline const char *risk_mode_name(RiskMode value) noexcept {
    switch (value) {
        case RiskMode::LowVariance: return "low_variance";
        case RiskMode::Balanced: return "balanced";
        case RiskMode::SeekUpside: return "seek_high_upside";
    }
    return "balanced";
}

inline const char *deliberation_name(DeliberationLevel value) noexcept {
    switch (value) {
        case DeliberationLevel::D0: return "D0";
        case DeliberationLevel::D1: return "D1";
        case DeliberationLevel::D2: return "D2";
        case DeliberationLevel::D3: return "D3";
    }
    return "D1";
}

struct BeliefSummary {
    double p_has_gust = 0.0;
    double p_has_energy_out = 0.0;
    double p_has_switch = 0.0;
    double p_has_hand_disruption = 0.0;
    double p_can_ko_active = 0.0;
    double p_can_ko_bench_target = 0.0;
    std::size_t known_hand_count = 0;
    std::size_t unknown_hand_count = 0;
    std::size_t remaining_pool_count = 0;
};

struct PrizeRace {
    std::int64_t own_prizes_remaining = 6;
    std::int64_t opponent_prizes_remaining = 6;
    double own_turns_to_win = 6.0;
    double opponent_turns_to_win = 6.0;
    double clock_margin = 0.0;
    std::int64_t active_target_prizes = 1;
    std::int64_t own_active_prizes_exposed = 1;
};

struct AttackerClock {
    std::string slot;
    std::string card_id;
    std::size_t earliest_ready_turn = 0;
    std::int64_t expected_damage = 0;
    std::int64_t max_relevant_damage = 0;
    std::size_t prizes_exposed = 1;
    std::size_t missing_energy = 0;
    std::size_t missing_evolution_steps = 0;
    double readiness_probability = 0.0;
    bool primary_role = false;
    bool secondary_role = false;
    bool engine_role = false;
};

struct AttackerPipeline {
    std::vector<AttackerClock> attackers;
    std::string current_slot;
    std::string next_slot;
    std::string backup_slot;
    double current_readiness = 0.0;
    double next_readiness = 0.0;
    double backup_readiness = 0.0;
};

struct EnergySchedule {
    bool attachment_available = true;
    std::string priority_slot;
    std::size_t priority_missing_energy = 0;
    std::size_t total_missing_energy = 0;
    std::size_t ready_attackers = 0;
};

struct ThreatMap {
    std::int64_t active_retaliation_damage = 0;
    std::int64_t own_active_hp = 0;
    bool active_ko_threat = false;
    bool board_loss_threat = false;
    double catastrophe_probability = 0.0;
};

struct ResourceLedger {
    std::size_t hand_size = 0;
    std::size_t deck_size = 0;
    std::size_t bench_count = 0;
    std::size_t bench_slots_free = 5;
    std::size_t energy_in_hand = 0;
    std::size_t switch_outs_visible = 0;
    std::size_t recovery_outs_visible = 0;
    double flexibility = 0.0;
};

struct StrategicFacts {
    PrizeRace prize_race;
    AttackerPipeline own_attackers;
    AttackerPipeline opponent_attackers;
    EnergySchedule energy_schedule;
    ResourceLedger resources;
    ThreatMap threats;
    BeliefSummary belief;
    RiskMode risk_mode = RiskMode::Balanced;
    std::int32_t actor = -1;
    std::int64_t turn_number = 0;
    std::int64_t winner = -1;
    std::size_t opponent_deck_size = 0;
    bool terminal = false;
    bool active_can_attack = false;
    bool active_can_take_prize = false;
    bool has_backup = false;
    std::string state_fingerprint;
};

struct MatchPlan {
    std::string match_id;
    std::int32_t actor = -1;
    std::string primary_attacker_slot;
    std::string next_attacker_slot;
    std::string backup_attacker_slot;
    std::string prize_route_target = "opponent_active";
    std::size_t reserved_switch_outs = 1;
    std::size_t reserved_recovery_outs = 1;
    RiskMode risk_mode = RiskMode::Balanced;
    IntentKind current_intent = IntentKind::EndTurnSafely;
    std::int64_t updated_turn = 0;
};

struct TurnIntent {
    IntentKind kind = IntentKind::EndTurnSafely;
    std::string target_slot;
    std::int64_t required_damage = 0;
    double minimum_survival_probability = 0.0;
    bool preserve_next_attacker = true;
    std::int32_t priority = 0;
};

struct ActionFootprint {
    std::set<std::string> reads;
    std::set<std::string> writes;
    std::set<std::string> consumes;
    std::set<std::string> produces;
    bool reveals_information = false;
    bool random = false;
    bool irreversible = false;
    bool terminal = false;
    std::string canonical_key;
};

inline bool set_intersects(
    const std::set<std::string> &left,
    const std::set<std::string> &right
) {
    const std::set<std::string> *small = &left;
    const std::set<std::string> *large = &right;
    if (small->size() > large->size()) std::swap(small, large);
    for (const std::string &entry : *small) {
        if (large->count(entry) != 0) return true;
    }
    return false;
}

inline bool footprints_commute(
    const ActionFootprint &left,
    const ActionFootprint &right
) {
    if (left.random || right.random || left.reveals_information
        || right.reveals_information || left.terminal || right.terminal) {
        return false;
    }
    if (set_intersects(left.writes, right.reads)
        || set_intersects(right.writes, left.reads)
        || set_intersects(left.writes, right.writes)
        || set_intersects(left.consumes, right.consumes)
        || set_intersects(left.consumes, right.produces)
        || set_intersects(right.consumes, left.produces)) {
        return false;
    }
    return true;
}

struct PlanScore {
    // Ordered lexicographically. Higher is better except catastrophe/variance.
    std::int32_t terminal_rank = 1;
    double catastrophe_probability = 0.0;
    double prize_clock_margin = 0.0;
    double guaranteed_prize_value = 0.0;
    double next_attacker_readiness = 0.0;
    double resource_flexibility = 0.0;
    double strategic_progress = 0.0;
    double variance = 0.0;
};

inline int compare_double(double left, double right, double epsilon = 1e-9) {
    if (left > right + epsilon) return 1;
    if (right > left + epsilon) return -1;
    return 0;
}

inline int compare_plan_score(const PlanScore &left, const PlanScore &right) {
    if (left.terminal_rank != right.terminal_rank) {
        return left.terminal_rank > right.terminal_rank ? 1 : -1;
    }
    int compared = compare_double(
        right.catastrophe_probability, left.catastrophe_probability);
    if (compared != 0) return compared;
    compared = compare_double(left.prize_clock_margin, right.prize_clock_margin);
    if (compared != 0) return compared;
    compared = compare_double(
        left.guaranteed_prize_value, right.guaranteed_prize_value);
    if (compared != 0) return compared;
    compared = compare_double(
        left.next_attacker_readiness, right.next_attacker_readiness);
    if (compared != 0) return compared;
    compared = compare_double(
        left.resource_flexibility, right.resource_flexibility);
    if (compared != 0) return compared;
    compared = compare_double(left.strategic_progress, right.strategic_progress);
    if (compared != 0) return compared;
    return compare_double(right.variance, left.variance);
}

inline bool plan_score_better(const PlanScore &left, const PlanScore &right) {
    return compare_plan_score(left, right) > 0;
}

inline double plan_score_utility(const PlanScore &score) {
    // Used only to aggregate equal-plan outcomes across belief scenarios; final
    // ranking still applies the lexicographic comparator above.
    return static_cast<double>(score.terminal_rank) * 1'000'000.0
        - score.catastrophe_probability * 100'000.0
        + score.prize_clock_margin * 10'000.0
        + score.guaranteed_prize_value * 2'000.0
        + score.next_attacker_readiness * 500.0
        + score.resource_flexibility * 20.0
        + score.strategic_progress * 10.0
        - score.variance * 50.0;
}

inline double estimate_turns_to_win(
    std::int64_t prizes_remaining,
    std::int64_t prizes_per_attack,
    std::size_t readiness_delay
) {
    if (prizes_remaining <= 0) return 0.0;
    const std::int64_t yield = std::max<std::int64_t>(1, prizes_per_attack);
    return static_cast<double>(readiness_delay)
        + std::ceil(static_cast<double>(prizes_remaining)
            / static_cast<double>(yield));
}

inline long double combination_ratio_no_out(
    std::size_t population,
    std::size_t outs,
    std::size_t draws
) {
    if (draws == 0 || outs == 0) return 1.0L;
    if (population == 0 || outs >= population || draws > population - outs) {
        return 0.0L;
    }
    long double ratio = 1.0L;
    for (std::size_t index = 0; index < draws; ++index) {
        ratio *= static_cast<long double>(population - outs - index)
            / static_cast<long double>(population - index);
    }
    return std::max(0.0L, std::min(1.0L, ratio));
}

inline double at_least_one_out_probability(
    std::size_t population,
    std::size_t outs,
    std::size_t draws
) {
    if (population == 0 || outs == 0 || draws == 0) return 0.0;
    draws = std::min(draws, population);
    outs = std::min(outs, population);
    return static_cast<double>(1.0L - combination_ratio_no_out(
        population, outs, draws));
}

inline double match_loss_probability(
    double active_ko_probability,
    bool loses_last_pokemon,
    bool concedes_final_prizes
) {
    if (!loses_last_pokemon && !concedes_final_prizes) return 0.0;
    return std::max(0.0, std::min(1.0, active_ko_probability));
}

} // namespace ptcg::ai::planner_v3

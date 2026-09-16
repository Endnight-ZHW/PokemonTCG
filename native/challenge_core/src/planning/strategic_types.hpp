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

namespace ptcg::ai::planning {

enum class RiskMode {
    LowVariance,
    Balanced,
    SeekUpside,
};

inline const char *risk_mode_name(RiskMode value) noexcept {
    switch (value) {
    case RiskMode::LowVariance:
        return "low_variance";
    case RiskMode::Balanced:
        return "balanced";
    case RiskMode::SeekUpside:
        return "seek_high_upside";
    }
    return "balanced";
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
    std::size_t attack_index = 0;
    std::string planned_card_id;
    double reload_turns = 0.0;
    double access_probability = 1.0;
    double ready_ko_probability = 0.0;
    double planned_ko_probability = 0.0;
    std::size_t promotion_delay = 0;
    Value forecast_pokemon;
    Value forecast_owner;
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
    std::size_t disruption_outs_visible = 0;
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

inline double estimate_turns_to_win(std::int64_t prizes_remaining, std::int64_t prizes_per_attack,
                                    std::size_t readiness_delay) {
    if (prizes_remaining <= 0)
        return 0.0;
    const std::int64_t yield = std::max<std::int64_t>(1, prizes_per_attack);
    return static_cast<double>(readiness_delay) +
           std::ceil(static_cast<double>(prizes_remaining) / static_cast<double>(yield));
}

inline long double combination_ratio_no_out(std::size_t population, std::size_t outs,
                                            std::size_t draws) {
    if (draws == 0 || outs == 0)
        return 1.0L;
    if (population == 0 || outs >= population || draws > population - outs) {
        return 0.0L;
    }
    long double ratio = 1.0L;
    for (std::size_t index = 0; index < draws; ++index) {
        ratio *= static_cast<long double>(population - outs - index) /
                 static_cast<long double>(population - index);
    }
    return std::max(0.0L, std::min(1.0L, ratio));
}

inline double at_least_one_out_probability(std::size_t population, std::size_t outs,
                                           std::size_t draws) {
    if (population == 0 || outs == 0 || draws == 0)
        return 0.0;
    draws = std::min(draws, population);
    outs = std::min(outs, population);
    return static_cast<double>(1.0L - combination_ratio_no_out(population, outs, draws));
}

inline double match_loss_probability(double active_ko_probability, bool loses_last_pokemon,
                                     bool concedes_final_prizes) {
    if (!loses_last_pokemon && !concedes_final_prizes)
        return 0.0;
    return std::max(0.0, std::min(1.0, active_ko_probability));
}

} // namespace ptcg::ai::planning

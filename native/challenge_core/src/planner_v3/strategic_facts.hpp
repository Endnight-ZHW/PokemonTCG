#pragma once

#include "planner_v3/strategic_types.hpp"
#include "ptcg_rules_session.hpp"
#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_strategy.hpp"

#include <cstdint>
#include <map>
#include <string>

namespace ptcg::ai::planner_v3 {

struct CardSemanticProfile {
    bool search = false;
    bool draw = false;
    bool gust = false;
    bool self_switch = false;
    bool heal = false;
    bool prevent_damage = false;
    bool hand_disruption = false;
    bool energy_denial = false;
    bool bench_damage = false;
    bool recovery = false;
    bool acceleration = false;
    bool random = false;
    bool reveals_information = false;
    bool irreversible = false;
};

class CardSemanticModel {
public:
    explicit CardSemanticModel(Value catalog);

    CardSemanticProfile profile(const std::string &card_id) const;
    ActionFootprint action_footprint(const Value &action) const;

private:
    Value cards_ = Value::make_object();
    mutable std::map<std::string, CardSemanticProfile> profile_cache_;
};

class BeliefTracker {
public:
    BeliefTracker(
        Value catalog,
        const TraditionalStrategyCatalog &strategies
    );

    BeliefSummary summarize(
        const TraditionalInformationSet &information,
        const Value &public_state,
        std::int32_t actor
    ) const;

private:
    Value cards_ = Value::make_object();
    const TraditionalStrategyCatalog &strategies_;
    CardSemanticModel semantics_;
};

class StrategicAnalyzer {
public:
    StrategicAnalyzer(
        Value catalog,
        Value decks,
        const TraditionalStrategyCatalog &strategies
    );

    StrategicFacts analyze(
        const RulesSession &position,
        const BeliefSummary &belief,
        std::int32_t actor
    ) const;

    void set_strategy_optimization(bool enabled) noexcept;

private:
    AttackerPipeline attacker_pipeline(
        const RulesSession &position,
        const Value &state,
        std::int32_t actor
    ) const;
    AttackerClock attacker_clock(
        const RulesSession &position,
        const Value &state,
        std::int32_t actor,
        const Value &pokemon,
        const std::string &slot
    ) const;
    std::size_t missing_evolution_steps(
        const Value &state,
        std::int32_t actor,
        const std::string &card_id
    ) const;

    Value catalog_ = Value::make_object();
    Value cards_ = Value::make_object();
    Value decks_ = Value::make_object();
    const TraditionalStrategyCatalog &strategies_;
    std::map<std::string, std::string> evolves_from_by_name_;
    bool strategy_optimization_ = true;
};

Value belief_summary_value(const BeliefSummary &belief);
Value strategic_facts_value(const StrategicFacts &facts);
Value match_plan_value(const MatchPlan &plan);
Value plan_score_value(const PlanScore &score);

} // namespace ptcg::ai::planner_v3

#pragma once

#include "planner_v3/safety_validator.hpp"
#include "planner_v3/strategic_facts.hpp"
#include "ptcg_traditional_search.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace ptcg::ai::planner_v3 {

struct StrategicPlannerConfig {
    std::size_t belief_samples = 3;
    std::uint64_t node_budget = 192;
    bool evaluation_smoke = false;
    bool strategy_optimization = true;
    // Full turn_beam_v2 output for this exact public state.  During migration
    // a strategic plan may only take control after it dominates this action,
    // rather than the much weaker ranked_actions().front() proxy.
    Value legacy_action = Value::make_object();
    Value::Array legacy_sequence;
    // Internal C++ supplier, evaluated only after cache/dominance exits.
    // It never calls a binding or recurses into the controller entry point.
    std::function<const Value &()> legacy_decision;
};

struct StrategicPlannerResult {
    TraditionalSearchResult plan;
    bool fallback_requested = false;
    std::string fallback_reason;
    bool dominance_resolved = false;
    bool cacheable = false;
    IntentKind intent = IntentKind::EndTurnSafely;
    DeliberationLevel deliberation = DeliberationLevel::D1;
    Value strategic_facts = Value::make_object();
    Value match_plan = Value::make_object();
    Value plan_score = Value::make_object();
    Value explanation = Value::make_object();
};

class HorizonPlanner {
public:
    MatchPlan update_plan(
        const StrategicFacts &facts,
        const std::string &match_id,
        const std::optional<MatchPlan> &previous
    ) const;

    std::vector<TurnIntent> propose_intents(
        const StrategicFacts &facts,
        const MatchPlan &plan
    ) const;
};

class DeliberationGate {
public:
    DeliberationLevel select(
        const StrategicFacts &facts,
        const std::vector<TurnIntent> &intents,
        std::size_t legal_action_count
    ) const;
};

class StrategicIntentPlanner {
public:
    StrategicIntentPlanner(
        Value catalog,
        Value decks,
        const TraditionalStrategyCatalog &strategies
    );

    StrategicPlannerResult decide(
        const std::string &match_id,
        const TraditionalInformationSet &information,
        TraditionalSearchProvider &provider,
        std::int32_t actor,
        std::uint32_t seed,
        const Value &root_actions,
        StrategicPlannerConfig config,
        const std::atomic<bool> *cancel_requested = nullptr
    );

    void reset_match(const std::string &match_id);

private:
    std::string memory_key(
        const std::string &match_id,
        std::int32_t actor
    ) const;

    Value catalog_ = Value::make_object();
    Value decks_ = Value::make_object();
    const TraditionalStrategyCatalog &strategies_;
    CardSemanticModel semantics_;
    BeliefTracker belief_tracker_;
    StrategicAnalyzer analyzer_;
    HorizonPlanner horizon_planner_;
    DeliberationGate deliberation_gate_;
    SafetyValidator safety_validator_;
    std::map<std::string, MatchPlan> match_plans_;
    std::map<std::string, std::int64_t> turn_compilation_attempts_;
    std::string active_match_id_;
};

} // namespace ptcg::ai::planner_v3

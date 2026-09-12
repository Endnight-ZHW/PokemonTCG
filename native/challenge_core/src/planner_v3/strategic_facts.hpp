#pragma once

#include "planner_v3/strategic_types.hpp"
#include "ptcg_rules_session.hpp"
#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "decision_search_context.hpp"

#include <cstdint>
#include <map>
#include <string>

namespace ptcg::ai::planner_v3 {

struct CardSemanticProfile {
    bool supporter = false;
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
    bool energy_search = false;
    bool discard_energy_source = false;
    bool random = false;
    bool reveals_information = false;
    bool irreversible = false;
    std::string pure_transfer_ability;
};

class CardSemanticModel {
public:
    using Profiles = std::map<std::string, CardSemanticProfile>;
    explicit CardSemanticModel(Value catalog, std::shared_ptr<const Profiles> profiles = {});
    const std::shared_ptr<const Profiles> &profiles() const { return profiles_; }

    CardSemanticProfile profile(const std::string &card_id) const;
    ActionFootprint action_footprint(const Value &action) const;
    bool pure_energy_transfer(const Value &action) const;

private:
    std::shared_ptr<const Profiles> profiles_;
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
    struct EvolutionOption {
        std::string id;
        std::string previous_name;
        bool direct = false;
    };
    struct Knowledge {
        explicit Knowledge(const Value &catalog);
        std::map<std::string, std::string> evolves_from_by_name;
        std::map<std::string, std::vector<std::string>> cards_by_name;
        std::map<std::string, std::vector<EvolutionOption>> evolutions;
        std::shared_ptr<const CardSemanticModel::Profiles> semantic_profiles;
    };

    StrategicAnalyzer(
        Value catalog,
        Value decks,
        const TraditionalStrategyCatalog &strategies,
        std::shared_ptr<const Knowledge> knowledge = {}
    );

    void set_search_context(std::shared_ptr<DecisionSearchContext> context) {
        context_ = std::move(context);
    }
    const std::shared_ptr<const Knowledge> &knowledge() const { return knowledge_; }

    StrategicFacts analyze(
        const RulesSession &position,
        const BeliefSummary &belief,
        std::int32_t actor
    ) const;

    void set_strategy_optimization(bool enabled) noexcept;
    // A choice changes accessible zones, not board rules. Score that resource
    // projection without repeatedly rebuilding the same RulesSession.
    double resource_value(const RulesSession &position, const Value &state,
        std::int32_t actor) const;
    double readiness_value(const RulesSession &position, const Value &state,
        std::int32_t actor) const;

private:
    AttackerPipeline compute_attacker_pipeline(const RulesSession &position,
        const Value &state, std::int32_t actor) const;
    double compute_resource_value(const RulesSession &position,
        const Value &state, std::int32_t actor) const;
    AttackerPipeline attacker_pipeline(
        const RulesSession &position,
        const Value &state,
        std::int32_t actor
    ) const;
    AttackerClock combat_clock(const RulesSession &position, const Value &state,
        std::int32_t actor, const Value &pokemon, const std::string &slot) const;
    double prize_route(const RulesSession &position, const Value &state,
        std::int32_t actor, const AttackerPipeline &pipeline, double gust_probability) const;
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
    std::shared_ptr<const Knowledge> knowledge_;
    std::weak_ptr<DecisionSearchContext> context_;
    CardSemanticModel semantics_;
    bool strategy_optimization_ = true;
};

Value belief_summary_value(const BeliefSummary &belief);
Value strategic_facts_value(const StrategicFacts &facts);
Value match_plan_value(const MatchPlan &plan);
Value plan_score_value(const PlanScore &score);

} // namespace ptcg::ai::planner_v3

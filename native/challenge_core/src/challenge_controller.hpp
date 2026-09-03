#pragma once

#include "ptcg_traditional_search.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_trusted.hpp"
#include "ptcg_value.hpp"
#include "planner_v3/strategic_intent_planner.hpp"

#include <atomic>
#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace ptcg::ai {

// Dependency-free Challenge policy boundary shared by Godot and research.
class ChallengeController {
public:
    Value configure(Value catalog, Value decks, Value strategies);
    Value decide(const Value &request, std::int64_t generation = 1);
    void cancel(std::int64_t generation) noexcept;
    void reset_match(const std::string &match_instance_id);
    Value get_contract() const;

private:
    struct ActionCycleEntry {
        std::string last_state_fingerprint;
        std::string last_action_signature;
        std::int64_t last_revision = -1;
        std::map<std::string, std::set<std::string>> blocked_by_state;
    };
    struct CachedPlanStep {
        Value action = Value::make_object();
        Value precondition = Value::make_object();
        std::string signature;
    };
    struct CachedPlanEntry {
        std::vector<CachedPlanStep> steps;
        std::int64_t last_revision = -1;
    };
    struct DeckInspectionMemory {
        Value::Array prize_cards;
        std::string match_instance_id;
        std::int64_t learned_revision = -1;
        bool valid = false;
    };

    Value decide_action(const Value &request, std::int64_t generation);
    Value decide_choice(const Value &request, std::int64_t generation);
    Value filter_root_actions(
        const Value &request,
        const Value &public_state,
        const Value &actions
    );
    void record_action_cycle_selection(
        const Value &request,
        const Value &public_state,
        const Value &action
    );
    std::string turn_plan_cache_key(
        const Value &request,
        const class TraditionalInformationSet &information_set
    ) const;
    Value take_cached_turn_action(
        const std::string &cache_key,
        std::int64_t revision,
        const Value &actions,
        const Value &precondition,
        std::int32_t actor
    );
    void store_turn_plan(
        const std::string &cache_key,
        std::int64_t revision,
        const TraditionalSearchResult &result
    );
    bool apply_deck_inspection_memory(
        const Value &request,
        class TraditionalInformationSet &information_set
    );
    void remember_deck_inspection(
        const Value &request,
        const TraditionalInformationSet &information_set
    );

    Value catalog_ = Value::make_object();
    Value decks_ = Value::make_object();
    Value strategies_ = Value::make_object();
    std::unique_ptr<TraditionalStrategyCatalog> strategy_catalog_;
    std::unique_ptr<TraditionalTrustedEvaluator> trusted_evaluator_;
    std::unique_ptr<planner_v3::StrategicIntentPlanner> strategic_planner_;
    std::string active_match_instance_id_;
    std::atomic<std::int64_t> cancelled_through_generation_{0};
    std::atomic<std::int64_t> active_generation_{0};
    std::atomic<bool> cancel_requested_{false};
    std::map<std::string, ActionCycleEntry> action_cycle_ledger_;
    std::vector<std::string> action_cycle_order_;
    std::map<std::string, CachedPlanEntry> turn_plan_cache_;
    std::vector<std::string> turn_plan_cache_order_;
    std::array<DeckInspectionMemory, 2> deck_inspection_memory_{};
    bool configured_ = false;
};

} // namespace ptcg::ai

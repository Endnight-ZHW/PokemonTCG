#pragma once
#include "search_types.hpp"
#include "information_set.hpp"
#include "deck_policy_registry.hpp"
#include <array>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace ptcg::ai {
// Match-scoped information and validated continuations; no sampled positions.
class MatchMemory {
  public:
    struct ActionCycleEntry {
        std::string last_state_fingerprint;
        std::string last_action_signature;
        std::int64_t last_revision = -1;
        std::map<std::string, std::set<std::string>> blocked_by_state;
        std::map<std::string, std::set<std::string>> chosen_by_state;
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
    struct PlanCacheUpdate {
        std::string key;
        std::optional<CachedPlanEntry> entry;
    };
    struct DeckInspectionMemory {
        Value::Array prize_cards;
        std::string match_instance_id;
        bool valid = false;
    };

    Value filter_root_actions(const Value &request, const Value &public_state,
                              const Value &actions);
    void record_action_cycle_selection(const Value &request, const Value &public_state,
                                       const Value &action);
    std::string turn_plan_cache_key(const Value &request,
                                    const class InformationSet &information_set) const;
    Value probe_cached_turn_action(const std::string &cache_key, std::int64_t revision,
                                   const Value &actions, const Value &precondition,
                                   std::int32_t actor, PlanCacheUpdate &update) const;
    PlanCacheUpdate prepare_turn_plan(const std::string &cache_key, std::int64_t revision,
                                      const SearchResult &result) const;
    void commit_plan_cache_update(PlanCacheUpdate update);
    bool apply_deck_inspection_memory(const Value &request, class InformationSet &information_set);
    void remember_deck_inspection(const Value &request, const InformationSet &information_set);

    void configure(Value catalog, std::shared_ptr<const DeckPolicyRegistry> policies) {
        catalog_ = std::move(catalog);
        policies_ = std::move(policies);
        reset();
    }
    void reset();

  private:
    Value catalog_;
    std::shared_ptr<const DeckPolicyRegistry> policies_;
    std::map<std::string, ActionCycleEntry> action_cycle_ledger_;
    std::vector<std::string> action_cycle_order_;
    std::map<std::string, CachedPlanEntry> turn_plan_cache_;
    std::vector<std::string> turn_plan_cache_order_;
    std::array<DeckInspectionMemory, 2> deck_inspection_memory_{};
};
} // namespace ptcg::ai

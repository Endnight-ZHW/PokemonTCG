#pragma once

#include "search_types.hpp"
#include "deck_policy_registry.hpp"
#include "ptcg_value.hpp"
#include "turn_planner.hpp"
#include "match_memory.hpp"
#include "planning/strategic_facts.hpp"

#include <atomic>
#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
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
    Value decide_action(const Value &request, std::int64_t generation);
    Value decide_choice(const Value &request, std::int64_t generation);
    Value catalog_ = Value::make_object();
    Value decks_ = Value::make_object();
    Value strategies_ = Value::make_object();
    std::shared_ptr<const DeckPolicyRegistry> strategy_catalog_;
    std::shared_ptr<const planning::StrategicAnalyzer::Knowledge> knowledge_;
    std::string active_match_instance_id_;
    std::atomic<std::int64_t> cancelled_through_generation_{0};
    std::atomic<std::int64_t> active_generation_{0};
    std::atomic<bool> cancel_requested_{false};
    MatchMemory memory_;
    bool configured_ = false;
};

} // namespace ptcg::ai

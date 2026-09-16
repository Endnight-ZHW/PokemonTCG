#pragma once

#include "ptcg_rules_session.hpp"
#include "ptcg_value.hpp"

#include <cstdint>
#include <optional>
#include <string>

namespace ptcg::ai {

class DeckPolicyRegistry;

// Native equivalent of NativeChallengeAI._traditional_leaf_score and its
// deterministic strategic-evaluation dependency graph.
class CardEvaluator {
  public:
    CardEvaluator(Value catalog, Value decks, const DeckPolicyRegistry &strategies);

    double leaf_score(const RulesSession &position, std::int32_t perspective) const;
    std::optional<double> action_score(const RulesSession &position, std::int32_t actor,
                                       const Value &action) const;
    std::optional<double> choice_option_score(const RulesSession &position, std::int32_t actor,
                                              const Value &choice_view, const Value &option) const;
    std::optional<bool> confirm_choice(const RulesSession &position, std::int32_t actor,
                                       const Value &choice_view) const;
    Value energy_target_prefix_plan(const RulesSession &position, std::int32_t actor,
                                    const Value &choice_view, const Value &option,
                                    std::int64_t max_count) const;
    double energy_distribution_board_utility(const RulesSession &position,
                                             std::int32_t actor) const;

    static std::int64_t quantize(double score) noexcept;
    static std::int64_t default_action_score_milli(const Value &action, const Value &catalog);
    std::int64_t base_state_score_milli(const RulesSession &position, std::int32_t actor) const;

  private:
    std::optional<double> semantic_action_score(const RulesSession &position, std::int32_t actor,
                                                const Value &action) const;
    const DeckPolicyRegistry &policies_;
    Value cards_ = Value::make_object();
    Value decks_ = Value::make_object();
};

} // namespace ptcg::ai

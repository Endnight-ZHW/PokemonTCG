#pragma once

#include "ptcg_rules_session.hpp"
#include "ptcg_value.hpp"

#include <cstdint>
#include <optional>
#include <string>

namespace ptcg::ai {

// Native equivalent of NativeChallengeAI._traditional_leaf_score and its
// deterministic strategic-evaluation dependency graph.
class TraditionalTrustedEvaluator {
public:
    TraditionalTrustedEvaluator(Value catalog, Value decks);

    double leaf_score(
        const RulesSession &position,
        std::int32_t perspective
    ) const;
    std::optional<double> action_score(
        const RulesSession &position,
        std::int32_t actor,
        const Value &action
    ) const;
    double raw_evaluation(
        const RulesSession &position,
        std::int32_t actor
    ) const;
    std::optional<double> development_action_value(
        const RulesSession &position,
        std::int32_t actor,
        const Value &action
    ) const;
    std::int64_t action_estimated_damage(
        const RulesSession &position,
        std::int32_t actor,
        const Value &action
    ) const;
    std::int64_t active_missing_energy(
        const RulesSession &position,
        std::int32_t actor
    ) const;
    bool deck_profile_contains(
        const RulesSession &position,
        std::int32_t actor,
        const std::string &role,
        const std::string &card_id
    ) const;
    bool attack_tactically_unsafe(
        const RulesSession &position,
        std::int32_t actor,
        const Value &action
    ) const;
    std::optional<double> productive_attack_value(
        const RulesSession &position,
        std::int32_t actor,
        const Value &action
    ) const;
    bool retreat_action_has_good_target(
        const RulesSession &position,
        std::int32_t actor,
        const Value &action
    ) const;
    std::optional<double> choice_option_score(
        const RulesSession &position,
        std::int32_t actor,
        const Value &choice_view,
        const Value &option
    ) const;
    std::optional<bool> confirm_choice(
        const RulesSession &position,
        std::int32_t actor,
        const Value &choice_view
    ) const;
    Value energy_target_prefix_plan(
        const RulesSession &position,
        std::int32_t actor,
        const Value &choice_view,
        const Value &option,
        std::int64_t max_count
    ) const;
    double energy_distribution_board_utility(
        const RulesSession &position,
        std::int32_t actor
    ) const;
    Value debug_components(
        const RulesSession &position,
        std::int32_t perspective
    ) const;

private:
    Value cards_ = Value::make_object();
    Value decks_ = Value::make_object();
};

} // namespace ptcg::ai

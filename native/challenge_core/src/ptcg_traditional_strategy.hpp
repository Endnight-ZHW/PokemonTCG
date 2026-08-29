#pragma once

#include "ptcg_value.hpp"

#include <cstdint>
#include <string>

namespace ptcg::ai {

// Precompiled, data-backed implementation of DeckStrategy plus all ten release
// specialization hooks. It reads only the public/determinized state supplied
// to the acting player and never creates legal actions.
class TraditionalStrategyCatalog {
public:
    TraditionalStrategyCatalog(Value strategies, Value catalog);

    bool valid() const noexcept;
    std::string strategy_id(const std::string &deck_key) const;
    std::int64_t strategy_version(const std::string &deck_key) const;
    std::string strategy_content_hash(const std::string &deck_key) const;
    double action_score(
        const Value &state,
        std::int32_t actor,
        const Value &action
    ) const;
    double choice_score(
        const Value &state,
        std::int32_t actor,
        const Value &choice_view,
        const Value &option
    ) const;
    double state_score(const Value &state, std::int32_t actor) const;
    Value turn_goals(const Value &state, std::int32_t actor) const;
    // Normalized, immutable deck knowledge derived from card_roles. Trusted
    // evaluation consumes this snapshot instead of maintaining its own card IDs.
    const Value &deck_plan_profiles() const noexcept;
    bool card_has_role(
        const Value &state,
        std::int32_t actor,
        const std::string &card_id,
        const std::string &role
    ) const;

private:
    Value strategies_ = Value::make_object();
    Value archetypes_ = Value::make_object();
    Value cards_ = Value::make_object();
    Value deck_plan_profiles_ = Value::make_object();
    bool valid_ = false;
};

} // namespace ptcg::ai

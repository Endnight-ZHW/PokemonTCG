#pragma once

#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_search.hpp"

#include <cstdint>
#include <memory>

namespace ptcg::ai {

// Callback-free semantic provider used by both the product binding and the
// research teacher. It consumes only Value, RulesSession and Challenge data.
class ChallengeSearchProvider : public TraditionalSearchProvider {
public:
    virtual bool select_choice(
        const RulesSession &position,
        const Value &pending,
        Value &response
    ) = 0;
    virtual Value post_plan_tactical_guard(
        const RulesSession &position,
        std::int32_t actor,
        const Value &preferred,
        const Value &actions,
        std::uint32_t seed,
        bool &changed
    ) = 0;
    virtual Value performance_counters() const = 0;
};

std::unique_ptr<ChallengeSearchProvider> make_challenge_search_provider(
    Value catalog,
    Value decks,
    Value strategies,
    std::int32_t root_actor,
    const TraditionalInformationSet *information_set,
    bool strategy_optimization = true
);

} // namespace ptcg::ai

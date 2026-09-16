#pragma once

#include "information_set.hpp"
#include "search_types.hpp"
#include "planning/strategic_facts.hpp"

#include <cstdint>
#include <memory>

namespace ptcg::ai {

// Callback-free semantic provider used by both the product binding and the
// research teacher. It consumes only Value, RulesSession and Challenge data.
class ChallengeSearchProvider : public SearchProvider {
  public:
    virtual bool select_choice(const RulesSession &position, const Value &pending,
                               Value &response) = 0;
    virtual Value performance_counters() const = 0;
};

std::unique_ptr<ChallengeSearchProvider> make_challenge_search_provider(
    Value catalog, Value decks, std::shared_ptr<const DeckPolicyRegistry> policies,
    std::int32_t root_actor, const InformationSet *information_set,
    std::shared_ptr<const planning::StrategicAnalyzer::Knowledge> knowledge = {});

} // namespace ptcg::ai

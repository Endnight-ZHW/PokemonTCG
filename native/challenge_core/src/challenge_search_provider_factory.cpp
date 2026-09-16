#include "challenge_search_provider_internal.hpp"

namespace ptcg::ai {

std::unique_ptr<ChallengeSearchProvider> make_challenge_search_provider(
    ptcg::ai::Value catalog, ptcg::ai::Value decks,
    std::shared_ptr<const DeckPolicyRegistry> policies, std::int32_t root_actor,
    const ptcg::ai::InformationSet *information_set,
    std::shared_ptr<const planning::StrategicAnalyzer::Knowledge> knowledge) {
    return std::make_unique<challenge_detail::ChallengeSearchProviderImpl>(
        std::move(catalog), std::move(decks), std::move(policies), root_actor, information_set,
        std::move(knowledge));
}

} // namespace ptcg::ai

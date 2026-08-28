#include "challenge_search_provider_internal.hpp"

namespace ptcg::ai {

std::unique_ptr<ChallengeSearchProvider> make_challenge_search_provider(
    ptcg::ai::Value catalog,
    ptcg::ai::Value decks,
    ptcg::ai::Value strategies,
    std::int32_t root_actor,
    const ptcg::ai::TraditionalInformationSet *information_set
) {
    return std::make_unique<challenge_detail::ChallengeSearchProviderImpl>(
        std::move(catalog),
        std::move(decks),
        std::move(strategies),
        root_actor,
        information_set
    );
}

} // namespace ptcg::ai

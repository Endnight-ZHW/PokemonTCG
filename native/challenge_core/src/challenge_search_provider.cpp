#include "challenge_search_provider_internal.hpp"


#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>
namespace ptcg::ai::challenge_detail {

using namespace challenge;

    ChallengeSearchProviderImpl::ChallengeSearchProviderImpl(
        ptcg::ai::Value catalog,
        ptcg::ai::Value decks,
        ptcg::ai::Value strategies,
        std::int32_t root_actor,
        const ptcg::ai::TraditionalInformationSet *information_set,
        bool strategy_optimization,
        std::shared_ptr<const planner_v3::StrategicAnalyzer::Knowledge> knowledge
    ) : catalog_(std::move(catalog)),
        decks_(std::move(decks)), evaluator_(catalog_),
        strategy_catalog_(std::move(strategies), catalog_),
        trusted_evaluator_(catalog_, decks_, strategy_catalog_),
        resource_analyzer_(catalog_, decks_, strategy_catalog_, std::move(knowledge)),
        information_set_(information_set), root_actor_(root_actor),
        strategy_optimization_(strategy_optimization) {
        resource_analyzer_.set_search_context(search_context());
        const ptcg::ai::Value *cards = catalog_.find("cards");
        cards_ = cards != nullptr && cards->is_object() ? *cards : catalog_;
    }


    Value ChallengeSearchProviderImpl::performance_counters() const {
        Value counters = search_context()->counters();
        counters["determinizations"] = static_cast<int64_t>(
            determinizations_.load(std::memory_order_relaxed));
        counters["ranked_action_queries"] = static_cast<int64_t>(
            ranked_queries_.load(std::memory_order_relaxed));
        counters["state_score_queries"] = static_cast<int64_t>(
            state_score_queries_.load(std::memory_order_relaxed));
        counters["choice_resolutions"] = static_cast<int64_t>(
            choice_resolutions_.load(std::memory_order_relaxed));
        counters["native_forced_choice_resolutions"] = static_cast<int64_t>(
            native_forced_choice_resolutions_.load(std::memory_order_relaxed));
        counters["native_choice_resolutions"] = static_cast<int64_t>(
            native_choice_resolutions_.load(std::memory_order_relaxed));
        counters["native_trusted_action_scores"] = static_cast<int64_t>(
            native_trusted_action_scores_.load(std::memory_order_relaxed));
        counters["known_reply_actions_promoted"] = static_cast<int64_t>(
            known_reply_actions_promoted_.load(std::memory_order_relaxed));
        counters["simulated_action_score_calls"] = static_cast<int64_t>(
            simulated_action_score_calls_.load(std::memory_order_relaxed));
        counters["prize_aware_choice_adjustments"] = static_cast<int64_t>(
            prize_aware_choice_adjustments_.load(std::memory_order_relaxed));
        counters["strategy_optimization_enabled"] = strategy_optimization_;
        counters["time_budget_exhausted"] = time_budget_exhausted();
        counters["choice_bundle_evaluations"] = static_cast<int64_t>(choice_bundle_evaluations_.load());
        counters["choice_bundle_changes"] = static_cast<int64_t>(choice_bundle_changes_.load());
        counters["choice_bundle_cache_hits"] = static_cast<int64_t>(choice_bundle_cache_hits_.load());
        return counters;
    }


    bool ChallengeSearchProviderImpl::select_choice(
        const ptcg::ai::RulesSession &position,
        const ptcg::ai::Value &pending,
        ptcg::ai::Value &response
    ) {
        const auto strings = std::make_shared<
            ptcg::ai::typed::CardStringTable>(cards_);
        const ptcg::ai::typed::StateCodec codec(strings);
        ptcg::ai::typed::ChoiceView typed_pending;
        std::string error;
        if (!codec.decode_choice_view(pending, typed_pending, &error)) return false;
        return select_choice(position, pending, typed_pending, response);
    }

    bool ChallengeSearchProviderImpl::select_choice(
        const RulesSession &position,
        const Value &pending,
        const typed::ChoiceView &typed_pending,
        Value &response
    ) {
        ++choice_resolutions_;
        if (arven_choice_response(position, pending, typed_pending, response)
            || confirm_choice_response(position, pending, typed_pending, response)
            || duplicate_energy_choice_response(
                position, pending, typed_pending, response)
            || single_choice_response(position, pending, typed_pending, response)) {
            ++native_choice_resolutions_;
            if (strategy_optimization_ && !time_budget_exhausted()) {
                improve_choice_bundle(position, pending, typed_pending, response);
            }
            return true;
        }
        if (forced_choice_response(
            position.search_state(), pending, typed_pending, response)) {
            ++native_forced_choice_resolutions_;
            return true;
        }
        return false;
    }


} // namespace ptcg::ai::challenge_detail

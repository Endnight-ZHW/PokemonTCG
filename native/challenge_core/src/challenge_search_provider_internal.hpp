#pragma once
#include "challenge_search_provider.hpp"

#include "challenge_support.hpp"
#include "ptcg_traditional_value.hpp"
#include "card_evaluator.hpp"
#include "ptcg_traditional_policy.hpp"
#include "deck_policy_registry.hpp"
#include "planning/strategic_facts.hpp"

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
using traditional_value::bool_field;
using traditional_value::integer_field;
using traditional_value::string_field;

class ChallengeSearchProviderImpl final : public ChallengeSearchProvider {
  public:
    ChallengeSearchProviderImpl(
        ptcg::ai::Value catalog, ptcg::ai::Value decks,
        std::shared_ptr<const DeckPolicyRegistry> policies, std::int32_t root_actor,
        const ptcg::ai::InformationSet *information_set,
        std::shared_ptr<const planning::StrategicAnalyzer::Knowledge> knowledge);
    Value performance_counters() const override;
    bool preserve_best_action(const RulesSession &position, std::int32_t actor) override {
        return policies_->policy_for(deck_key_for_actor(position, actor)).preserve_best_action();
    }
    bool select_choice(const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending,
                       ptcg::ai::Value &response);
    std::unique_ptr<ptcg::ai::RulesSession> determinize(std::size_t sample_index,
                                                        std::uint32_t seed) override;
    std::vector<ptcg::ai::RankedAction> ranked_actions(const ptcg::ai::RulesSession &position,
                                                       std::int32_t actor,
                                                       const ptcg::ai::Value &supplied_actions,
                                                       std::size_t limit) override;
    std::int64_t state_score_milli(const ptcg::ai::RulesSession &position,
                                   std::int32_t root_actor) override;
    bool resolve_pending(ptcg::ai::RulesSession &position, std::int32_t decision_player,
                         std::uint64_t &nodes_expanded, ptcg::ai::ChoiceTrace &trace) override;
    std::int32_t decision_actor(const ptcg::ai::RulesSession &position) override;
    bool terminal(const ptcg::ai::RulesSession &position) override;
    std::string state_fingerprint(const ptcg::ai::RulesSession &position) override;
    bool action_ends_turn(const ptcg::ai::Value &action) override;
    ptcg::ai::Value bind_action(const ptcg::ai::Value &candidate,
                                const ptcg::ai::RulesSession &position, std::int32_t actor,
                                const std::string &action_id) override;
    std::string sha256_text(const std::string &value) override;
    std::string deck_key_for_actor(const ptcg::ai::RulesSession &position,
                                   std::int32_t actor) override;
    std::string strategy_id_for_actor(const ptcg::ai::RulesSession &position,
                                      std::int32_t actor) override;
    ptcg::ai::Value cache_precondition(const ptcg::ai::RulesSession &position,
                                       std::int32_t actor) override;

  private:
    std::unique_ptr<RulesSession> reply_information_view(const RulesSession &position,
                                                         std::int32_t actor,
                                                         std::uint32_t seed) override;
    std::int64_t compute_state_score(const RulesSession &position, std::int32_t actor);
    Value compute_cache_precondition(const RulesSession &position, std::int32_t actor);
    void improve_choice_bundle(const RulesSession &position, const Value &pending,
                               const typed::ChoiceView &choice, Value &response);
    bool select_choice(const RulesSession &position, const Value &pending,
                       const typed::ChoiceView &choice, Value &response);
    bool duplicate_energy_choice_response(const ptcg::ai::RulesSession &position,
                                          const ptcg::ai::Value &pending,
                                          const ptcg::ai::typed::ChoiceView &choice,
                                          ptcg::ai::Value &response) const;
    bool confirm_choice_response(const ptcg::ai::RulesSession &position,
                                 const ptcg::ai::Value &pending,
                                 const ptcg::ai::typed::ChoiceView &choice,
                                 ptcg::ai::Value &response) const;
    std::string resolved_option_card_id(const ptcg::ai::Value &option) const;
    bool arven_choice_response(const ptcg::ai::RulesSession &position,
                               const ptcg::ai::Value &pending,
                               const ptcg::ai::typed::ChoiceView &choice,
                               ptcg::ai::Value &response) const;
    bool sequential_discard_response(const ptcg::ai::RulesSession &position,
                                     const ptcg::ai::Value &pending,
                                     const ptcg::ai::typed::ChoiceView &choice,
                                     ptcg::ai::Value &response) const;
    bool single_choice_response(const ptcg::ai::RulesSession &position,
                                const ptcg::ai::Value &pending,
                                const ptcg::ai::typed::ChoiceView &choice,
                                ptcg::ai::Value &response) const;
    double prize_aware_search_choice_score(const ptcg::ai::RulesSession &position,
                                           std::int32_t actor, const ptcg::ai::Value &pending,
                                           const ptcg::ai::Value &option) const;
    bool forced_choice_response(const ptcg::ai::Value &state, const ptcg::ai::Value &pending,
                                const ptcg::ai::typed::ChoiceView &choice,
                                ptcg::ai::Value &response) const;
    bool retreat_payment_response(const ptcg::ai::Value &state, const ptcg::ai::Value &pending,
                                  ptcg::ai::Value &response) const;
    std::int64_t energy_units_provided_by_card(const ptcg::ai::Value::Array &attached,
                                               std::size_t index) const;
    ptcg::ai::Value catalog_;
    ptcg::ai::Value cards_ = ptcg::ai::Value::make_object();
    ptcg::ai::Value decks_;
    std::shared_ptr<const DeckPolicyRegistry> policies_;
    const DeckPolicyRegistry &strategy_catalog_;
    ptcg::ai::CardEvaluator card_evaluator_;
    planning::StrategicAnalyzer resource_analyzer_;
    const ptcg::ai::InformationSet *information_set_ = nullptr;
    std::int32_t root_actor_ = -1;
    std::atomic<std::uint64_t> determinizations_{0};
    std::atomic<std::uint64_t> ranked_queries_{0};
    std::atomic<std::uint64_t> state_score_queries_{0};
    std::atomic<std::uint64_t> choice_resolutions_{0};
    std::atomic<std::uint64_t> native_forced_choice_resolutions_{0};
    std::atomic<std::uint64_t> native_choice_resolutions_{0};
    std::atomic<std::uint64_t> native_trusted_action_scores_{0};
    mutable std::atomic<std::uint64_t> prize_aware_choice_adjustments_{0};
    std::atomic<std::uint64_t> choice_bundle_evaluations_{0};
    std::atomic<std::uint64_t> choice_bundle_changes_{0};
    std::atomic<std::uint64_t> choice_bundle_cache_hits_{0};
    std::mutex choice_bundle_cache_mutex_;
    std::map<std::string, Value::Array> choice_bundle_cache_;
};

} // namespace ptcg::ai::challenge_detail

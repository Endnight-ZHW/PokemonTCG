#pragma once
#include "challenge_search_provider.hpp"

#include "challenge_support.hpp"
#include "ptcg_traditional_evaluator.hpp"
#include "ptcg_traditional_mandatory.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_trusted.hpp"

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

class ChallengeSearchProviderImpl final : public ChallengeSearchProvider {
public:
ChallengeSearchProviderImpl( ptcg::ai::Value catalog, ptcg::ai::Value decks, ptcg::ai::Value strategies, std::int32_t root_actor, const ptcg::ai::TraditionalInformationSet *information_set );
Value performance_counters() const override;
bool select_choice( const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending, ptcg::ai::Value &response );
ptcg::ai::Value post_plan_tactical_guard( const ptcg::ai::RulesSession &position, std::int32_t actor, const ptcg::ai::Value &preferred, const ptcg::ai::Value &actions, std::uint32_t seed, bool &changed );
std::unique_ptr<ptcg::ai::RulesSession> determinize( std::size_t sample_index, std::uint32_t seed ) override;
std::vector<ptcg::ai::TraditionalRankedAction> ranked_actions( const ptcg::ai::RulesSession &position, std::int32_t actor, const ptcg::ai::Value &supplied_actions, std::size_t limit ) override;
std::int64_t state_score_milli( const ptcg::ai::RulesSession &position, std::int32_t root_actor ) override;
bool resolve_pending( ptcg::ai::RulesSession &position, std::int32_t decision_player, std::uint64_t &nodes_expanded, ptcg::ai::TraditionalChoiceTrace &trace ) override;
std::int32_t decision_actor( const ptcg::ai::RulesSession &position ) override;
bool terminal(const ptcg::ai::RulesSession &position) override;
std::string state_fingerprint( const ptcg::ai::RulesSession &position ) override;
bool action_ends_turn(const ptcg::ai::Value &action) override;
ptcg::ai::Value bind_action( const ptcg::ai::Value &candidate, const ptcg::ai::RulesSession &position, std::int32_t actor, const std::string &action_id ) override;
std::uint32_t branch_seed( std::uint32_t base_seed, std::size_t depth, const std::string &root_signature, const std::string &sequence_signature, std::size_t action_index ) override;
std::string trace_seed() override;
std::string trace_event( const std::string &previous_hash, const std::string &event ) override;
std::string sha256_text(const std::string &value) override;
std::string deck_key_for_actor( const ptcg::ai::RulesSession &position, std::int32_t actor ) override;
std::string strategy_id_for_actor( const ptcg::ai::RulesSession &position, std::int32_t actor ) override;
ptcg::ai::Value cache_precondition( const ptcg::ai::RulesSession &position, std::int32_t actor ) override;
private:
bool duplicate_energy_choice_response( const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending, const ptcg::ai::typed::ChoiceView &choice, ptcg::ai::Value &response ) const;
bool confirm_choice_response( const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending, const ptcg::ai::typed::ChoiceView &choice, ptcg::ai::Value &response ) const;
std::string resolved_option_card_id( const ptcg::ai::Value &option ) const;
bool arven_choice_response( const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending, const ptcg::ai::typed::ChoiceView &choice, ptcg::ai::Value &response ) const;
bool sequential_discard_response( const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending, const ptcg::ai::typed::ChoiceView &choice, ptcg::ai::Value &response ) const;
bool single_choice_response( const ptcg::ai::RulesSession &position, const ptcg::ai::Value &pending, const ptcg::ai::typed::ChoiceView &choice, ptcg::ai::Value &response ) const;
bool forced_choice_response( const ptcg::ai::Value &state, const ptcg::ai::Value &pending, const ptcg::ai::typed::ChoiceView &choice, ptcg::ai::Value &response ) const;
bool retreat_payment_response( const ptcg::ai::Value &state, const ptcg::ai::Value &pending, ptcg::ai::Value &response ) const;
std::int64_t energy_units_provided_by_card( const ptcg::ai::Value::Array &attached, std::size_t index ) const;
static std::string string_field( const ptcg::ai::Value &value, const char *key, const std::string &fallback = {} );
static std::int64_t integer_field( const ptcg::ai::Value &value, const char *key, std::int64_t fallback = 0 );
static bool bool_field( const ptcg::ai::Value &value, const char *key, bool fallback = false );
ptcg::ai::Value catalog_;
ptcg::ai::Value cards_ = ptcg::ai::Value::make_object();
ptcg::ai::Value decks_;
ptcg::ai::TraditionalPositionEvaluator evaluator_;
ptcg::ai::TraditionalStrategyCatalog strategy_catalog_;
ptcg::ai::TraditionalTrustedEvaluator trusted_evaluator_;
const ptcg::ai::TraditionalInformationSet *information_set_ = nullptr;
std::int32_t root_actor_ = -1;
std::atomic<std::uint64_t> determinizations_{0};
std::atomic<std::uint64_t> ranked_queries_{0};
std::atomic<std::uint64_t> state_score_queries_{0};
std::atomic<std::uint64_t> choice_resolutions_{0};
std::atomic<std::uint64_t> native_forced_choice_resolutions_{0};
std::atomic<std::uint64_t> native_choice_resolutions_{0};
    std::atomic<std::uint64_t> native_trusted_action_scores_{0};
    std::atomic<std::uint64_t> known_reply_actions_promoted_{0};
    std::atomic<std::uint64_t> simulated_action_score_calls_{0};
};

} // namespace ptcg::ai::challenge_detail

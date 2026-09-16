#include "challenge_search_support.hpp"
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
using traditional_value::field;

std::unique_ptr<ptcg::ai::RulesSession>
ChallengeSearchProviderImpl::determinize(std::size_t sample_index, std::uint32_t seed) {
    ++determinizations_;
    return search_context()->sample(sample_index, seed, [&]() -> std::unique_ptr<RulesSession> {
        if (information_set_ == nullptr || !information_set_->valid())
            return {};
        Value snapshot = information_set_->sample_state(seed);
        if (!snapshot.is_object())
            return {};
        auto session = std::make_unique<RulesSession>(catalog_);
        std::string error;
        if (!session->restore(snapshot, seed, &error))
            return {};
        return session;
    });
}

std::unique_ptr<RulesSession>
ChallengeSearchProviderImpl::reply_information_view(const RulesSession &position,
                                                    std::int32_t actor, std::uint32_t seed) {
    InformationSet view;
    std::string error;
    if (!view.capture(position.ai_observation_for(actor), actor, catalog_, decks_,
                      Value::make_array(), Value::make_array(), seed, &error))
        return {};
    Value sample = view.sample_state(seed);
    // Keep this world's actor-owned hidden zones and random stream coupled to
    // the original branch. Only the information unavailable to that actor is
    // resampled; an extra forecast must not buy a different future prize/draw.
    auto &owner = sample["players"].as_array()[static_cast<std::size_t>(actor)];
    const auto &original =
        position.search_state().find("players")->as_array()[static_cast<std::size_t>(actor)];
    for (const auto *zone : {"deck", "prizes"})
        owner[zone] = *original.find(zone);
    auto reply = std::make_unique<RulesSession>(catalog_);
    if (!reply->restore(sample, position.rng_state(), &error))
        return {};
    return reply->fork_for_reply_search();
}

std::vector<ptcg::ai::RankedAction> ChallengeSearchProviderImpl::ranked_actions(
    const ptcg::ai::RulesSession &position, std::int32_t actor,
    const ptcg::ai::Value &supplied_actions, std::size_t limit) {
    ++ranked_queries_;
    if (search_stopped())
        return {};
    const Value &effective_actions =
        supplied_actions.is_array() && !supplied_actions.as_array().empty()
            ? supplied_actions
            : position.search_legal_action_candidates(actor);
    if (!effective_actions.is_array())
        return {};
    const auto compute = [&]() -> std::vector<RankedAction> {
        const auto &actions = effective_actions.as_array();
        search_context()->ranked_input_actions += actions.size();
        std::vector<RankedAction> rows;
        std::vector<std::int64_t> adjustments;
        rows.reserve(actions.size());
        adjustments.reserve(actions.size());
        for (std::size_t index = 0; index < actions.size(); ++index) {
            if (search_stopped())
                return {};
            const Value &action = actions[index];
            auto adjustment =
                std::clamp<std::int64_t>(CardEvaluator::quantize(strategy_catalog_.action_score(
                                             position.search_state(), actor, action)),
                                         -250000, 250000);
            adjustments.push_back(adjustment);
            rows.push_back({action,
                            CardEvaluator::default_action_score_milli(action, cards_) + adjustment,
                            value_action_signature(action),
                            traditional_semantic_bucket(action, stable_value_signature),
                            traditional_action_purpose(action), index});
        }
        traditional_sort_ranked_actions(rows);
        std::set<std::string> detailed;
        if (search_context()->shortlist_enabled && actor == root_actor_ && rows.size() > 16) {
            for (std::size_t index = 0; index < 16; ++index)
                detailed.insert(rows[index].signature);
            std::set<std::string> protected_routes;
            const std::string incumbent =
                value_action_signature(search_context()->incumbent_action());
            for (const auto &row : rows) {
                const auto kind = string_field(row.action, "kind");
                const auto *target = field(row.action, "target");
                const auto slot = target ? string_field(*target, "slot") : std::string{};
                const std::string route = row.purpose_bucket + "|" + slot;
                if (traditional_action_is_terminal(row.action) || row.signature == incumbent ||
                    protected_routes.insert(route).second)
                    detailed.insert(row.signature);
            }
            rows.erase(
                std::remove_if(rows.begin(), rows.end(),
                               [&](const auto &row) { return !detailed.count(row.signature); }),
                rows.end());
        }
        for (auto &row : rows) {
            if (search_stopped())
                return {};
            {
                ++search_context()->detailed_action_scores;
                const auto trusted = card_evaluator_.action_score(position, actor, row.action);
                if (trusted) {
                    row.score_milli =
                        CardEvaluator::quantize(*trusted) + adjustments[row.source_index];
                    ++native_trusted_action_scores_;
                }
            }
        }
        if (search_stopped())
            return {};
        traditional_sort_ranked_actions(rows);
        (void)
            limit; // Traversals retain terminal/diversity selection within the detailed shortlist.
        return rows;
    };
    // The legal-action array is part of the key, so a filtered root cannot
    // reuse an unfiltered ranking. Changing the protected incumbent also
    // changes the ranking policy epoch before the next worker batch starts.
    return search_context()->memoize_values<std::vector<RankedAction>>(
        SearchMemo::Ranking, effective_actions, position.search_state(), position.rng_state(),
        actor, search_context()->ranking_policy(), compute);
}

std::int64_t ChallengeSearchProviderImpl::state_score_milli(const RulesSession &position,
                                                            std::int32_t actor) {
    ++state_score_queries_;
    return search_context()->memoize<std::int64_t>(
        SearchMemo::StateScore, position, position.search_state(), actor, 1,
        [&] { return compute_state_score(position, actor); });
}

std::int64_t
ChallengeSearchProviderImpl::compute_state_score(const ptcg::ai::RulesSession &position,
                                                 std::int32_t root_actor) {
    const ptcg::ai::Value &state = position.search_state();
    if (string_field(state, "result_status", "ONGOING") != "ONGOING" ||
        string_field(state, "phase") == "GAME_OVER") {
        return card_evaluator_.base_state_score_milli(position, root_actor);
    }
    PositionFeatures facts;
    facts.material = card_evaluator_.base_state_score_milli(position, root_actor) / 1000.0;
    facts.tactical = card_evaluator_.leaf_score(position, root_actor);
    facts.readiness = resource_analyzer_.readiness_value(position, state, root_actor) -
                      resource_analyzer_.readiness_value(position, state, 1 - root_actor);
    if (strategy_catalog_.policy_for(deck_key_for_actor(position, root_actor)).specialized()) {
        // Resource value is readiness minus twenty points per forecast turn to
        // finish the prize route. Keep the two facts separate for deck policies.
        const auto resources = resource_analyzer_.resource_value(position, state, root_actor) -
                               resource_analyzer_.resource_value(position, state, 1 - root_actor);
        facts.prize_clock_margin = (resources - facts.readiness) / 20.0;
    }
    return CardEvaluator::quantize(strategy_catalog_.position_value(state, root_actor, facts));
}

bool ChallengeSearchProviderImpl::resolve_pending(ptcg::ai::RulesSession &position,
                                                  std::int32_t decision_player,
                                                  std::uint64_t &nodes_expanded,
                                                  ptcg::ai::ChoiceTrace &trace) {
    (void)nodes_expanded;
    (void)decision_player;
    for (std::size_t guard = 0; guard < 32; ++guard) {
        if (search_stopped())
            return false;
        const ptcg::ai::Value *pending = &position.search_pending_choice(0);
        std::int32_t pending_player = 0;
        if (pending->is_null()) {
            pending = &position.search_pending_choice(1);
            pending_player = 1;
        }
        if (pending->is_null())
            return true;
        const ptcg::ai::typed::ChoiceView *typed_pending =
            position.typed_search_pending_choice(pending_player);
        if (typed_pending == nullptr)
            return false;
        trace.had_choice = true;
        ptcg::ai::Value response;
        if (!select_choice(position, *pending, *typed_pending, response))
            return false;
        const ptcg::ai::RulesSessionResult applied = position.apply_choice(response);
        ++search_context()->rule_choices;
        if (!applied.success) {
            ++search_context()->rejected_rule_choices;
            return false;
        }
        trace.unpredictable =
            trace.unpredictable ||
            std::any_of(applied.events.begin(), applied.events.end(), event_is_unpredictable);
    }
    return false;
}

std::int32_t ChallengeSearchProviderImpl::decision_actor(const ptcg::ai::RulesSession &position) {
    const ptcg::ai::Value &snapshot = position.search_state();
    const ptcg::ai::Value *promotions = snapshot.find("pending_promotions");
    if (promotions != nullptr && promotions->is_array() && !promotions->as_array().empty()) {
        return static_cast<std::int32_t>(promotions->as_array().front().as_integer(-1));
    }
    if (string_field(snapshot, "phase") == "SETUP") {
        return static_cast<std::int32_t>(integer_field(snapshot, "setup_actor_idx", -1));
    }
    return static_cast<std::int32_t>(integer_field(snapshot, "active_player_idx", -1));
}

bool ChallengeSearchProviderImpl::terminal(const ptcg::ai::RulesSession &position) {
    const ptcg::ai::Value &snapshot = position.search_state();
    return string_field(snapshot, "result_status", "ONGOING") != "ONGOING" ||
           string_field(snapshot, "phase") == "GAME_OVER";
}

std::string ChallengeSearchProviderImpl::state_fingerprint(const ptcg::ai::RulesSession &position) {
    return search_context()->memoize<std::string>(
        SearchMemo::Fingerprint, position, position.search_state(), -1, 0,
        [&] { return traditional_state_fingerprint(position); });
}

bool ChallengeSearchProviderImpl::action_ends_turn(const ptcg::ai::Value &action) {
    const std::string kind = string_field(action, "kind");
    return kind == "DECLARE_ATTACK" || kind == "END_TURN" || kind == "SETUP_DONE";
}

ptcg::ai::Value ChallengeSearchProviderImpl::bind_action(const ptcg::ai::Value &candidate,
                                                         const ptcg::ai::RulesSession &position,
                                                         std::int32_t actor,
                                                         const std::string &action_id) {
    ptcg::ai::Value result = candidate;
    result["schema_version"] = ptcg::ai::Value(4);
    result["action_id"] = ptcg::ai::Value(action_id);
    result["base_revision"] = ptcg::ai::Value(position.revision());
    result["actor"] = ptcg::ai::Value(actor);
    return result;
}

std::string ChallengeSearchProviderImpl::sha256_text(const std::string &value) {
    return challenge::sha256_text(value);
}

std::string ChallengeSearchProviderImpl::deck_key_for_actor(const ptcg::ai::RulesSession &position,
                                                            std::int32_t actor) {
    const ptcg::ai::Value &snapshot = position.search_state();
    const ptcg::ai::Value *keys = snapshot.find("public_deck_keys");
    if (keys == nullptr || !keys->is_array() || actor < 0 ||
        static_cast<std::size_t>(actor) >= keys->as_array().size()) {
        return {};
    }
    return keys->as_array()[static_cast<std::size_t>(actor)].string_or();
}

std::string
ChallengeSearchProviderImpl::strategy_id_for_actor(const ptcg::ai::RulesSession &position,
                                                   std::int32_t actor) {
    return strategy_catalog_.strategy_id(deck_key_for_actor(position, actor));
}

Value ChallengeSearchProviderImpl::cache_precondition(const RulesSession &position,
                                                      std::int32_t actor) {
    return search_context()->memoize<Value>(
        SearchMemo::Preconditions, position, position.search_state(), actor, 0,
        [&] { return compute_cache_precondition(position, actor); });
}

ptcg::ai::Value
ChallengeSearchProviderImpl::compute_cache_precondition(const ptcg::ai::RulesSession &position,
                                                        std::int32_t actor) {
    ptcg::ai::InformationSet information;
    std::string error;
    if (!information.capture(position.search_state(), actor, catalog_, decks_,
                             ptcg::ai::Value::make_array(), ptcg::ai::Value::make_array(), 0,
                             &error)) {
        return ptcg::ai::Value::make_object();
    }
    ptcg::ai::Value payload = information.public_snapshot();
    for (const char *key : {
             "legal_actions",
             "public_history",
             "perspective",
             "match_seed",
         })
        payload.erase(key);
    const std::string fingerprint = sha256_text(information_value_signature(payload));
    std::string known_hand_wire;
    if (information_set_ != nullptr && information_set_->valid() && (actor == 0 || actor == 1)) {
        std::vector<std::string> known_ids;
        for (const ptcg::ai::Value &entry : information_set_->known_hand(1 - actor)) {
            known_ids.push_back(entry.string_or());
        }
        std::sort(known_ids.begin(), known_ids.end());
        for (const std::string &card_id : known_ids) {
            known_hand_wire += std::to_string(card_id.size()) + ":" + card_id + "|";
        }
    }
    const std::string known_hand_fingerprint =
        sha256_text("known-opponent-hand:v1|" + known_hand_wire);
    std::string known_prize_wire;
    if (information_set_ != nullptr && information_set_->valid() &&
        information_set_->has_exact_hidden_zones(actor)) {
        std::vector<std::string> known_ids;
        for (const ptcg::ai::Value &entry : information_set_->known_prizes(actor)) {
            known_ids.push_back(entry.string_or());
        }
        std::sort(known_ids.begin(), known_ids.end());
        for (const std::string &card_id : known_ids) {
            known_prize_wire += std::to_string(card_id.size()) + ":" + card_id + "|";
        }
    }
    const std::string known_prize_fingerprint =
        sha256_text("known-own-prizes:v1|" + known_prize_wire);
    const ptcg::ai::Value *observed_actor = information.public_snapshot().find("actor");
    const ptcg::ai::Value *phase = information.public_snapshot().find("phase");
    return ptcg::ai::Value(ptcg::ai::Value::Object{
        {"expected_public_fingerprint", ptcg::ai::Value("public:" + fingerprint)},
        {"expected_known_hand_fingerprint", ptcg::ai::Value("known:" + known_hand_fingerprint)},
        {"expected_known_prize_fingerprint", ptcg::ai::Value("known:" + known_prize_fingerprint)},
        {"expected_actor", observed_actor == nullptr ? ptcg::ai::Value(-1) : *observed_actor},
        {"expected_phase", phase == nullptr ? ptcg::ai::Value("") : *phase},
    });
}

} // namespace ptcg::ai::challenge_detail

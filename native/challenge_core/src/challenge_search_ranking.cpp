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

    std::unique_ptr<ptcg::ai::RulesSession> ChallengeSearchProviderImpl::determinize(
        std::size_t sample_index,
        std::uint32_t seed
    ) {
        (void)sample_index;
        ++determinizations_;
        if (information_set_ != nullptr && information_set_->valid()) {
            ptcg::ai::Value snapshot = information_set_->sample_state(seed);
            if (!snapshot.is_object()) return {};
            auto session = std::make_unique<ptcg::ai::RulesSession>(catalog_);
            std::string error;
            if (!session->restore(snapshot, seed, &error)) return {};
            return session;
        }
        return {};
    }


    std::vector<ptcg::ai::TraditionalRankedAction> ChallengeSearchProviderImpl::ranked_actions(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const ptcg::ai::Value &supplied_actions,
        std::size_t limit
    ) {
        ++ranked_queries_;
        const ptcg::ai::Value &effective_actions = supplied_actions.is_array()
            && !supplied_actions.as_array().empty()
            ? supplied_actions
            : position.search_legal_action_candidates(actor);
        if (!effective_actions.is_array()) return {};

        const ptcg::ai::Value::Array &actions = effective_actions.as_array();
        std::vector<ptcg::ai::TraditionalRankedAction> output;
        output.reserve(actions.size());
        for (std::size_t index = 0; index < actions.size(); ++index) {
            std::int64_t score = evaluator_.default_action_score_milli(actions[index]);
            const std::optional<double> trusted_score = actor == root_actor_
                ? trusted_evaluator_.action_score(position, actor, actions[index])
                : std::nullopt;
            if (trusted_score.has_value()) {
                score = ptcg::ai::TraditionalPositionEvaluator::quantize(
                    *trusted_score);
                ++native_trusted_action_scores_;
            }
            const double native_strategy = strategy_catalog_.action_score(
                position.search_state(), actor, actions[index]);
            score += std::max<std::int64_t>(-250000, std::min<std::int64_t>(
                250000,
                ptcg::ai::TraditionalPositionEvaluator::quantize(native_strategy)));
            output.push_back(ptcg::ai::TraditionalRankedAction{
                actions[index],
                score,
                {},
                {},
                {},
                index,
            });
        }
        const auto stable = [](const ptcg::ai::Value &value) {
            return stable_value_signature(value);
        };
        const auto sha = [](const std::string &value) {
            return challenge::sha256_text(value);
        };
        for (auto &row : output) {
            row.signature = ptcg::ai::traditional_action_signature(
                row.action, stable, sha);
            row.semantic_bucket = ptcg::ai::traditional_semantic_bucket(
                row.action, stable);
            row.purpose_bucket = ptcg::ai::traditional_action_purpose(row.action);
        }
        ptcg::ai::traditional_sort_ranked_actions(output);
        (void)limit;
        // The traversal owns diversity selection. Returning the full stable
        // ranking preserves TraditionalTurnPlanner's two-stage contract:
        // freeze a root set once, then re-filter/re-diversify it per belief.
        return output;
    }


    std::int64_t ChallengeSearchProviderImpl::state_score_milli(
        const ptcg::ai::RulesSession &position,
        std::int32_t root_actor
    ) {
        ++state_score_queries_;
        const ptcg::ai::Value &state = position.search_state();
        if (
            string_field(state, "result_status", "ONGOING") != "ONGOING"
            || string_field(state, "phase") == "GAME_OVER"
        ) {
            return evaluator_.base_state_score_milli(position, root_actor);
        }
        const std::int64_t base_score = evaluator_.base_state_score_milli(
            position, root_actor);
        std::int64_t score = base_score;
        const std::int64_t trusted_score = std::max<std::int64_t>(
            -210000, std::min<std::int64_t>(
                210000,
                ptcg::ai::TraditionalPositionEvaluator::quantize(
                    trusted_evaluator_.leaf_score(position, root_actor) * 0.35)));
        score += trusted_score;
        const double native_strategy = strategy_catalog_.state_score(
            position.search_state(), root_actor);
        const std::int64_t strategy_score = std::max<std::int64_t>(
            -300000, std::min<std::int64_t>(
            300000,
            ptcg::ai::TraditionalPositionEvaluator::quantize(native_strategy)));
        score += strategy_score;
        return score;
    }


    bool ChallengeSearchProviderImpl::resolve_pending(
        ptcg::ai::RulesSession &position,
        std::int32_t decision_player,
        std::uint64_t &nodes_expanded,
        ptcg::ai::TraditionalChoiceTrace &trace
    ) {
        (void)nodes_expanded;
        (void)decision_player;
        for (std::size_t guard = 0; guard < 32; ++guard) {
            const ptcg::ai::Value *pending = &position.search_pending_choice(0);
            std::int32_t pending_player = 0;
            if (pending->is_null()) {
                pending = &position.search_pending_choice(1);
                pending_player = 1;
            }
            if (pending->is_null()) return true;
            const ptcg::ai::typed::ChoiceView *typed_pending =
                position.typed_search_pending_choice(pending_player);
            if (typed_pending == nullptr) return false;
            trace.had_choice = true;
            ++choice_resolutions_;
            ptcg::ai::Value response;
            if (arven_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
            } else if (confirm_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
            } else if (duplicate_energy_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
            } else if (single_choice_response(
                position, *pending, *typed_pending, response)) {
                ++native_choice_resolutions_;
            } else if (forced_choice_response(
                position.search_state(), *pending, *typed_pending, response)) {
                ++native_forced_choice_resolutions_;
            } else {
                return false;
            }
            const ptcg::ai::RulesSessionResult applied = position.apply_choice(
                response);
            if (!applied.success) return false;
            for (const ptcg::ai::Value &event : applied.events) {
                const ptcg::ai::Value *event_type = event.find("event_type");
                const std::string type = event_type == nullptr
                    ? std::string{} : event_type->string_or();
                if (type == "coin_flip"
                    || type.find("shuffle") != std::string::npos
                    || type.find("draw") != std::string::npos
                    || type.find("random") != std::string::npos) {
                    trace.unpredictable = true;
                }
            }
        }
        return false;
    }


    std::int32_t ChallengeSearchProviderImpl::decision_actor(
        const ptcg::ai::RulesSession &position
    ) {
        const ptcg::ai::Value &snapshot = position.search_state();
        const ptcg::ai::Value *promotions = snapshot.find("pending_promotions");
        if (
            promotions != nullptr && promotions->is_array()
            && !promotions->as_array().empty()
        ) {
            return static_cast<std::int32_t>(
                promotions->as_array().front().as_integer(-1));
        }
        if (string_field(snapshot, "phase") == "SETUP") {
            return static_cast<std::int32_t>(integer_field(
                snapshot, "setup_actor_idx", -1));
        }
        return static_cast<std::int32_t>(integer_field(
            snapshot, "active_player_idx", -1));
    }


    bool ChallengeSearchProviderImpl::terminal(const ptcg::ai::RulesSession &position) {
        const ptcg::ai::Value &snapshot = position.search_state();
        return string_field(snapshot, "result_status", "ONGOING") != "ONGOING"
            || string_field(snapshot, "phase") == "GAME_OVER";
    }


    std::string ChallengeSearchProviderImpl::state_fingerprint(
        const ptcg::ai::RulesSession &position
    ) {
        return traditional_state_fingerprint(position);
    }


    bool ChallengeSearchProviderImpl::action_ends_turn(const ptcg::ai::Value &action) {
        const std::string kind = string_field(action, "kind");
        return kind == "DECLARE_ATTACK" || kind == "END_TURN"
            || kind == "SETUP_DONE";
    }


    ptcg::ai::Value ChallengeSearchProviderImpl::bind_action(
        const ptcg::ai::Value &candidate,
        const ptcg::ai::RulesSession &position,
        std::int32_t actor,
        const std::string &action_id
    ) {
        ptcg::ai::Value result = candidate;
        result["schema_version"] = ptcg::ai::Value(4);
        result["action_id"] = ptcg::ai::Value(action_id);
        result["base_revision"] = ptcg::ai::Value(position.revision());
        result["actor"] = ptcg::ai::Value(actor);
        return result;
    }


    std::uint32_t ChallengeSearchProviderImpl::branch_seed(
        std::uint32_t base_seed,
        std::size_t depth,
        const std::string &root_signature,
        const std::string &sequence_signature,
        std::size_t action_index
    ) {
        const int64_t mixed = static_cast<int64_t>(base_seed)
            ^ static_cast<int64_t>(string_hash32(root_signature))
            ^ static_cast<int64_t>(string_hash32(sequence_signature))
            ^ static_cast<int64_t>(depth * 32452843ULL)
            ^ static_cast<int64_t>((action_index + 1ULL) * 49979687ULL);
        const std::uint64_t magnitude = mixed < 0
            ? static_cast<std::uint64_t>(-(mixed + 1)) + 1ULL
            : static_cast<std::uint64_t>(mixed);
        return static_cast<std::uint32_t>(magnitude + 1ULL);
    }


    std::string ChallengeSearchProviderImpl::trace_seed() {
        return sha256_text("turn_beam_v2:trajectory:v1");
    }


    std::string ChallengeSearchProviderImpl::trace_event(
        const std::string &previous_hash,
        const std::string &event
    ) {
        return sha256_text(previous_hash + "\n" + event);
    }


    std::string ChallengeSearchProviderImpl::sha256_text(const std::string &value) {
        return challenge::sha256_text(value);
    }


    std::string ChallengeSearchProviderImpl::deck_key_for_actor(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor
    ) {
        const ptcg::ai::Value &snapshot = position.search_state();
        const ptcg::ai::Value *keys = snapshot.find("public_deck_keys");
        if (
            keys == nullptr || !keys->is_array() || actor < 0
            || static_cast<std::size_t>(actor) >= keys->as_array().size()
        ) {
            return {};
        }
        return keys->as_array()[static_cast<std::size_t>(actor)].string_or();
    }


    std::string ChallengeSearchProviderImpl::strategy_id_for_actor(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor
    ) {
        return strategy_catalog_.strategy_id(
            deck_key_for_actor(position, actor));
    }


    ptcg::ai::Value ChallengeSearchProviderImpl::cache_precondition(
        const ptcg::ai::RulesSession &position,
        std::int32_t actor
    ) {
        ptcg::ai::TraditionalInformationSet information;
        std::string error;
        if (!information.capture(
            position.search_state(), actor, catalog_, decks_,
            ptcg::ai::Value::make_array(),
            ptcg::ai::Value::make_array(),
            0,
            &error
        )) {
            return ptcg::ai::Value::make_object();
        }
        ptcg::ai::Value payload = information.public_snapshot();
        for (const char *key : {
            "legal_actions", "public_history", "perspective", "match_seed",
        }) payload.erase(key);
        const std::string fingerprint = sha256_text(
            information_value_signature(payload));
        const ptcg::ai::Value *observed_actor = information.public_snapshot().find("actor");
        const ptcg::ai::Value *phase = information.public_snapshot().find("phase");
        return ptcg::ai::Value(ptcg::ai::Value::Object{
            {"expected_public_fingerprint", ptcg::ai::Value(
                "public:" + fingerprint)},
            {"expected_actor", observed_actor == nullptr
                ? ptcg::ai::Value(-1) : *observed_actor},
            {"expected_phase", phase == nullptr
                ? ptcg::ai::Value("") : *phase},
        });
    }


} // namespace ptcg::ai::challenge_detail

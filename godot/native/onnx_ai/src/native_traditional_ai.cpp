#include "native_traditional_ai.hpp"
#include "native_traditional_search_provider.hpp"
#include "native_traditional_support.hpp"

#include "ptcg_godot_value.hpp"
#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_mandatory.hpp"
#include "ptcg_traditional_evaluator.hpp"
#include "ptcg_traditional_policy.hpp"
#include "ptcg_traditional_search.hpp"
#include "ptcg_traditional_strategy.hpp"
#include "ptcg_traditional_trusted.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <utility>
#include <vector>

namespace godot {

using namespace native_traditional;

void NativeTraditionalAI::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("configure", "catalog", "decks", "strategies"),
        &NativeTraditionalAI::configure);
#ifdef DEBUG_ENABLED
    ClassDB::bind_method(
        D_METHOD(
            "debug_decide_with_provider", "request", "generation", "provider"),
        &NativeTraditionalAI::debug_decide_with_provider);
    ClassDB::bind_method(
        D_METHOD(
            "debug_determinize", "public_state", "actor", "seed", "match_seed"),
        &NativeTraditionalAI::debug_determinize,
        DEFVAL(0));
    ClassDB::bind_method(
        D_METHOD("debug_strategy_scores", "state", "actor", "actions"),
        &NativeTraditionalAI::debug_strategy_scores);
    ClassDB::bind_method(
        D_METHOD(
            "debug_strategy_choice_scores",
            "state", "actor", "choice_view", "options"),
        &NativeTraditionalAI::debug_strategy_choice_scores);
    ClassDB::bind_method(
        D_METHOD("debug_trusted_leaf_score", "snapshot", "actor", "rng_state"),
        &NativeTraditionalAI::debug_trusted_leaf_score,
        DEFVAL(1));
    ClassDB::bind_method(
        D_METHOD(
            "debug_trusted_action_scores",
            "snapshot", "actor", "actions", "rng_state"),
        &NativeTraditionalAI::debug_trusted_action_scores,
        DEFVAL(1));
    ClassDB::bind_method(
        D_METHOD(
            "debug_tactical_candidates",
            "public_state", "actor", "actions", "sample_seed",
            "candidate_seed", "match_seed"),
        &NativeTraditionalAI::debug_tactical_candidates,
        DEFVAL(0));
    ClassDB::bind_method(
        D_METHOD(
            "debug_mandatory_tactics",
            "public_state", "actor", "actions", "seed", "match_seed", "node_budget"),
        &NativeTraditionalAI::debug_mandatory_tactics,
        DEFVAL(1), DEFVAL(0), DEFVAL(192));
#endif
    ClassDB::bind_method(
        D_METHOD("decide", "request", "generation"),
        &NativeTraditionalAI::decide,
        DEFVAL(1));
    ClassDB::bind_method(
        D_METHOD("cancel", "generation"),
        &NativeTraditionalAI::cancel);
    ClassDB::bind_method(
        D_METHOD("reset_match", "match_instance_id"),
        &NativeTraditionalAI::reset_match);
    ClassDB::bind_method(
        D_METHOD("get_contract"),
        &NativeTraditionalAI::get_contract);
    ClassDB::bind_method(
        D_METHOD("is_configured"),
        &NativeTraditionalAI::is_configured);
}

Dictionary NativeTraditionalAI::configure(
    const Dictionary &catalog,
    const Dictionary &decks,
    const Dictionary &strategies
) {
    Dictionary result;
    if (catalog.is_empty() || decks.is_empty() || strategies.is_empty()) {
        configured_ = false;
        result["success"] = false;
        result["error"] = "native_traditional_configuration_missing";
        return result;
    }
    catalog_ = catalog.duplicate(true);
    catalog_value_ = ptcg::ai::value_from_godot(catalog_);
    decks_ = decks.duplicate(true);
    decks_value_ = ptcg::ai::value_from_godot(decks_);
    strategies_ = strategies.duplicate(true);
    strategies_value_ = ptcg::ai::value_from_godot(strategies_);
    strategy_catalog_ = std::make_unique<ptcg::ai::TraditionalStrategyCatalog>(
        strategies_value_, catalog_value_);
    trusted_evaluator_ = std::make_unique<ptcg::ai::TraditionalTrustedEvaluator>(
        catalog_value_, decks_value_);
    configured_ = true;
    result["success"] = true;
    result["error"] = "";
    result["card_count"] = catalog_.size();
    result["deck_count"] = decks_.size();
    result["strategy_count"] = strategies_.size();
    return result;
}

ptcg::ai::Value NativeTraditionalAI::filter_root_actions(
    const Dictionary &request,
    const ptcg::ai::Value &public_state,
    const ptcg::ai::Value &actions
) {
    const std::int32_t actor = static_cast<std::int32_t>(
        int64_t(request.get("actor", -1)));
    ptcg::ai::Value filtered = filter_exhausted_repeatable_abilities(
        public_state, actor, actions, catalog_value_);
    if (!filtered.is_array()
        || String(request.get("engine", "turn_beam_v2")) != "turn_beam_v2") {
        return filtered;
    }
    const std::string match_id = godot_string_utf8(String(
        request.get("match_instance_id", "")));
    if (match_id.empty()) return filtered;
    const std::string ledger_key = match_id + "|" + std::to_string(actor)
        + "|" + std::to_string(value_integer_field(
            public_state, "turn_number", 0));
    const auto found = action_cycle_ledger_.find(ledger_key);
    if (found == action_cycle_ledger_.end()) return filtered;
    ActionCycleEntry &entry = found->second;
    const std::string fingerprint = action_cycle_state_fingerprint(public_state);
    const std::int64_t revision = int64_t(request.get(
        "revision", value_integer_field(public_state, "revision", 0)));
    if (entry.last_state_fingerprint == fingerprint
        && revision > entry.last_revision
        && !entry.last_action_signature.empty()) {
        entry.blocked_by_state[fingerprint].insert(entry.last_action_signature);
    }
    const auto blocked_entry = entry.blocked_by_state.find(fingerprint);
    if (blocked_entry == entry.blocked_by_state.end()
        || blocked_entry->second.empty()) return filtered;
    ptcg::ai::Value::Array result;
    ptcg::ai::Value::Array terminal;
    for (const ptcg::ai::Value &action : filtered.as_array()) {
        if (ptcg::ai::traditional_action_is_terminal(action)) {
            terminal.push_back(action);
        }
        if (blocked_entry->second.count(value_action_signature(action)) == 0) {
            result.push_back(action);
        }
    }
    if (!result.empty()) return ptcg::ai::Value(std::move(result));
    if (!terminal.empty()) return ptcg::ai::Value(std::move(terminal));
    return filtered;
}

void NativeTraditionalAI::record_action_cycle_selection(
    const Dictionary &request,
    const ptcg::ai::Value &public_state,
    const ptcg::ai::Value &action
) {
    if (String(request.get("engine", "turn_beam_v2")) != "turn_beam_v2") return;
    const std::string match_id = godot_string_utf8(String(
        request.get("match_instance_id", "")));
    if (match_id.empty() || !action.is_object()) return;
    const std::int32_t actor = static_cast<std::int32_t>(
        int64_t(request.get("actor", -1)));
    const std::string ledger_key = match_id + "|" + std::to_string(actor)
        + "|" + std::to_string(value_integer_field(
            public_state, "turn_number", 0));
    const bool inserted = action_cycle_ledger_.find(ledger_key)
        == action_cycle_ledger_.end();
    ActionCycleEntry &entry = action_cycle_ledger_[ledger_key];
    entry.last_state_fingerprint = action_cycle_state_fingerprint(public_state);
    entry.last_action_signature = value_action_signature(action);
    entry.last_revision = int64_t(request.get(
        "revision", value_integer_field(public_state, "revision", 0)));
    if (inserted) action_cycle_order_.push_back(ledger_key);
    while (action_cycle_order_.size() > 64) {
        action_cycle_ledger_.erase(action_cycle_order_.front());
        action_cycle_order_.erase(action_cycle_order_.begin());
    }
}

std::string NativeTraditionalAI::turn_plan_cache_key(
    const Dictionary &request,
    const ptcg::ai::TraditionalInformationSet &information_set
) const {
    const std::string match_id = godot_string_utf8(String(
        request.get("match_instance_id", "")));
    if (match_id.empty() || !information_set.valid()) return {};
    const std::int32_t actor = information_set.perspective();
    const ptcg::ai::Value &state = information_set.public_snapshot();
    const ptcg::ai::Value *keys = state.find("public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && actor >= 0
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    return match_id + "|" + std::to_string(actor) + "|"
        + std::to_string(value_integer_field(state, "turn_number", 0))
        + "|" + deck_key;
}

ptcg::ai::Value NativeTraditionalAI::take_cached_turn_action(
    const std::string &cache_key,
    std::int64_t revision,
    const ptcg::ai::Value &actions,
    const ptcg::ai::Value &precondition,
    std::int32_t actor
) {
    const auto erase_entry = [this](const std::string &key) {
        turn_plan_cache_.erase(key);
        turn_plan_cache_order_.erase(std::remove(
            turn_plan_cache_order_.begin(), turn_plan_cache_order_.end(), key),
            turn_plan_cache_order_.end());
    };
    const auto found = turn_plan_cache_.find(cache_key);
    if (cache_key.empty() || found == turn_plan_cache_.end()) return {};
    CachedPlanEntry &entry = found->second;
    if (revision <= entry.last_revision || entry.steps.empty()
        || !actions.is_array() || !precondition.is_object()) {
        erase_entry(cache_key);
        return {};
    }
    const CachedPlanStep &next = entry.steps.front();
    const auto same_string = [&next, &precondition](const char *key) {
        return value_string_field(next.precondition, key)
            == value_string_field(precondition, key);
    };
    if (!same_string("expected_public_fingerprint")
        || value_integer_field(next.precondition, "expected_actor", -1)
            != value_integer_field(precondition, "expected_actor", -1)
        || !same_string("expected_phase")
        || value_integer_field(next.action, "actor", -1) != actor) {
        erase_entry(cache_key);
        return {};
    }
    const ptcg::ai::Value *matched = nullptr;
    for (const ptcg::ai::Value &action : actions.as_array()) {
        if (value_action_signature(action) == next.signature) {
            matched = &action;
            break;
        }
    }
    if (matched == nullptr) {
        erase_entry(cache_key);
        return {};
    }
    ptcg::ai::Value result = *matched;
    entry.steps.erase(entry.steps.begin());
    if (entry.steps.empty()) erase_entry(cache_key);
    else entry.last_revision = revision;
    return result;
}

void NativeTraditionalAI::store_turn_plan(
    const std::string &cache_key,
    std::int64_t revision,
    const ptcg::ai::TraditionalSearchResult &result
) {
    const auto erase_entry = [this](const std::string &key) {
        turn_plan_cache_.erase(key);
        turn_plan_cache_order_.erase(std::remove(
            turn_plan_cache_order_.begin(), turn_plan_cache_order_.end(), key),
            turn_plan_cache_order_.end());
    };
    if (cache_key.empty() || !result.success || !result.selected.is_object()) return;
    if (ptcg::ai::traditional_action_is_terminal(result.selected)) {
        erase_entry(cache_key);
        return;
    }
    const std::string selected_signature = value_action_signature(result.selected);
    bool removed_selected = false;
    std::vector<CachedPlanStep> steps;
    const std::size_t count = std::min(
        result.sequence.size(), result.cache_preconditions.size());
    steps.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        const std::string signature = value_action_signature(result.sequence[index]);
        if (!removed_selected && signature == selected_signature) {
            removed_selected = true;
            continue;
        }
        steps.push_back(CachedPlanStep{
            result.sequence[index], result.cache_preconditions[index], signature});
    }
    if (steps.empty()) {
        erase_entry(cache_key);
        return;
    }
    const bool inserted = turn_plan_cache_.find(cache_key) == turn_plan_cache_.end();
    turn_plan_cache_[cache_key] = CachedPlanEntry{std::move(steps), revision};
    if (inserted) turn_plan_cache_order_.push_back(cache_key);
    while (turn_plan_cache_order_.size() > 8) {
        turn_plan_cache_.erase(turn_plan_cache_order_.front());
        turn_plan_cache_order_.erase(turn_plan_cache_order_.begin());
    }
}

#ifdef DEBUG_ENABLED
Dictionary NativeTraditionalAI::debug_decide_with_provider(
    const Dictionary &request,
    int64_t generation,
    const Callable &provider
) {
    return decide_controller(request, generation, provider, false);
}
#endif

Dictionary NativeTraditionalAI::decide_controller(
    const Dictionary &request,
    int64_t generation,
    const Callable &provider,
    bool require_native_choices
) {
    Dictionary output;
    if (!configured_) {
        output["success"] = false;
        output["error"] = "native_traditional_not_configured";
        return output;
    }
    if (!provider.is_valid() && !require_native_choices) {
        output["success"] = false;
        output["error"] = "native_traditional_provider_missing";
        return output;
    }
    if (
        generation <= cancelled_through_generation_.load(
            std::memory_order_acquire)
    ) {
        output["success"] = false;
        output["cancelled"] = true;
        output["error"] = "cancelled";
        return output;
    }
    const Variant submitted_actions_variant = request.get("actions", Variant());
    if (submitted_actions_variant.get_type() != Variant::ARRAY) {
        output["success"] = false;
        output["error"] = "native_traditional_root_actions_missing";
        return output;
    }
    active_generation_.store(generation, std::memory_order_release);
    cancel_requested_.store(false, std::memory_order_release);
    ptcg::ai::TraditionalInformationSet native_information_set;
    const ptcg::ai::TraditionalInformationSet *information_set_ptr = nullptr;
    const Variant public_state_variant = request.get(
        "public_snapshot", request.get("state", Variant()));
    const ptcg::ai::Value public_state_value =
        public_state_variant.get_type() == Variant::DICTIONARY
        ? ptcg::ai::value_from_godot(public_state_variant)
        : ptcg::ai::Value::make_object();
    const ptcg::ai::Value filtered_actions = filter_root_actions(
        request,
        public_state_value,
        ptcg::ai::value_from_godot(submitted_actions_variant));
    if (!filtered_actions.is_array() || filtered_actions.as_array().empty()) {
        output["success"] = false;
        output["error"] = "no_bounded_legal_action";
        active_generation_.store(0, std::memory_order_release);
        return output;
    }
    const Variant actions_variant = ptcg::ai::value_to_godot(filtered_actions);
    if (public_state_variant.get_type() == Variant::DICTIONARY) {
        std::string information_error;
        if (!native_information_set.capture(
            ptcg::ai::value_from_godot(public_state_variant),
            static_cast<std::int32_t>(int64_t(request.get("actor", -1))),
            catalog_value_,
            decks_value_,
            ptcg::ai::value_from_godot(actions_variant),
            ptcg::ai::value_from_godot(request.get("public_history", Array())),
            int64_t(request.get("match_seed", request.get("seed", 0))),
            &information_error
        )) {
            output["success"] = false;
            output["error"] = String::utf8(information_error.c_str());
            active_generation_.store(0, std::memory_order_release);
            return output;
        }
        information_set_ptr = &native_information_set;
    }
    auto bridge_owner = make_native_traditional_search_provider(
        provider, catalog_value_, decks_value_, strategies_value_,
        static_cast<std::int32_t>(int64_t(request.get("actor", -1))),
        information_set_ptr,
        bool(request.get("internal_debug_trajectory", false)),
        require_native_choices);
    NativeTraditionalSearchProvider &bridge = *bridge_owner;
#if defined(__ANDROID__)
    constexpr std::size_t platform_search_workers = 2;
#elif defined(_WIN32)
    constexpr std::size_t platform_search_workers = 3;
#else
    constexpr std::size_t platform_search_workers = 1;
#endif
    const bool force_single_search_worker = bool(request.get(
        "internal_evaluation_batch", false))
        || bool(request.get("internal_evaluation_smoke", false))
        || provider.is_valid()
        || bool(request.get("internal_debug_trajectory", false));
    const std::size_t search_worker_count = force_single_search_worker
        ? 1 : platform_search_workers;
    const auto native_performance_counters = [&]() {
        Dictionary performance = bridge.performance_counters();
        const int64_t root_actions_input = Array(
            submitted_actions_variant).size();
        const int64_t root_actions_effective = static_cast<int64_t>(
            filtered_actions.as_array().size());
        performance["root_actions_input"] = root_actions_input;
        performance["root_actions_effective"] = root_actions_effective;
        performance["root_actions_filtered"] =
            root_actions_input - root_actions_effective;
        performance["search_worker_count"] = static_cast<int64_t>(
            search_worker_count);
        return performance;
    };
    const std::string plan_cache_key = information_set_ptr == nullptr
        ? std::string{} : turn_plan_cache_key(request, *information_set_ptr);
    const std::int64_t request_revision = int64_t(request.get(
        "revision", value_integer_field(public_state_value, "revision", 0)));
    std::uint64_t mandatory_nodes = 0;
    std::string mandatory_reason = "skipped";
    std::string mandatory_debug_error;
    ptcg::ai::Value mandatory_debug_state = ptcg::ai::Value::make_object();
    if (!bool(request.get("skip_mandatory", false))
        && information_set_ptr != nullptr
        && strategy_catalog_ != nullptr
        && trusted_evaluator_ != nullptr) {
        const std::uint32_t mandatory_seed = static_cast<std::uint32_t>(
            int64_t(request.get("seed", 1)));
        const ptcg::ai::Value sampled = information_set_ptr->sample_state(
            mandatory_seed);
        ptcg::ai::RulesSession mandatory_position(catalog_value_);
        std::string mandatory_error;
        if (!sampled.is_object() || !mandatory_position.restore(
            sampled, mandatory_seed, &mandatory_error
        )) {
            output["success"] = false;
            output["error"] = mandatory_error.empty()
                ? "native_mandatory_determinization_failed"
                : String::utf8(mandatory_error.c_str());
            active_generation_.store(0, std::memory_order_release);
            return output;
        }
        const std::int32_t mandatory_actor = static_cast<std::int32_t>(
            int64_t(request.get("actor", -1)));
        const ptcg::ai::Value mandatory_actions = ptcg::ai::value_from_godot(
            actions_variant);
        ptcg::ai::TraditionalMandatoryResult forced;
        const ptcg::ai::Value &mandatory_state = mandatory_position.search_state();
        const bool setup_public_policy =
            value_string_field(mandatory_state, "phase") == "SETUP"
            && value_string_field(mandatory_state, "setup_stage") != "COMPLETE"
            && mandatory_actions.is_array()
            && mandatory_actions.as_array().size() > 1;
        bool plan_cache_hit = false;
        bool plan_cache_guarded = false;
        if (setup_public_policy) {
            const auto ranked = bridge.ranked_actions(
                mandatory_position,
                mandatory_actor,
                mandatory_actions,
                mandatory_actions.as_array().size());
            if (ranked.empty()) {
                output["success"] = false;
                output["error"] = "no_ranked_setup_action";
                active_generation_.store(0, std::memory_order_release);
                return output;
            }
            forced.resolved = true;
            forced.action = ranked.front().action;
            forced.reason = "setup_public_policy";
        } else {
            const ptcg::ai::TraditionalMandatoryTactics tactics(
                catalog_value_, *strategy_catalog_, *trusted_evaluator_);
            forced = tactics.resolve(
                *information_set_ptr,
                mandatory_position,
                mandatory_actor,
                mandatory_actions,
                bridge,
                mandatory_seed,
                static_cast<std::uint64_t>(std::max<int64_t>(
                    0, int64_t(request.get("node_budget", 192)))),
                &cancel_requested_);
        }
        mandatory_nodes = forced.nodes_expanded;
        mandatory_reason = forced.reason;
        mandatory_debug_error = forced.debug_last_step_error;
        mandatory_debug_state = forced.debug_last_state;
        if (forced.cancelled || cancel_requested_.load(std::memory_order_acquire)) {
            output["success"] = false;
            output["cancelled"] = true;
            output["error"] = "cancelled";
            active_generation_.store(0, std::memory_order_release);
            return output;
        }
        if (!forced.resolved && !plan_cache_key.empty()) {
            ptcg::ai::Value cached = take_cached_turn_action(
                plan_cache_key,
                request_revision,
                mandatory_actions,
                bridge.cache_precondition(mandatory_position, mandatory_actor),
                mandatory_actor);
            if (cached.is_object() && !cached.as_object().empty()) {
                const std::string cached_kind = value_string_field(cached, "kind");
                if (bool(request.get("apply_tactical_guard", false))
                    && (cached_kind == "DECLARE_ATTACK" || cached_kind == "RETREAT"
                        || cached_kind == "END_TURN")) {
                    bool changed = false;
                    const ptcg::ai::Value guarded = bridge.post_plan_tactical_guard(
                        mandatory_position,
                        mandatory_actor,
                        cached,
                        mandatory_actions,
                        mandatory_seed + 700001U,
                        changed);
                    if (changed) {
                        cached = guarded;
                        plan_cache_guarded = true;
                        turn_plan_cache_.erase(plan_cache_key);
                        turn_plan_cache_order_.erase(std::remove(
                            turn_plan_cache_order_.begin(),
                            turn_plan_cache_order_.end(),
                            plan_cache_key), turn_plan_cache_order_.end());
                    }
                }
                forced.resolved = true;
                forced.action = cached;
                forced.reason = plan_cache_guarded
                    ? "plan_cache_guard" : "plan_cache";
                forced.nodes_expanded = mandatory_nodes;
                plan_cache_hit = true;
            }
        }
        if (forced.resolved) {
            active_generation_.store(0, std::memory_order_release);
            const ptcg::ai::TraditionalStableSignature stable = [](
                const ptcg::ai::Value &value
            ) {
                return godot_string_utf8(stable_value_signature(value));
            };
            const std::function<std::string(const std::string &)> sha = [](
                const std::string &value
            ) {
                return godot_string_utf8(
                    String::utf8(value.c_str()).sha256_text());
            };
            const std::string signature =
                ptcg::ai::traditional_action_signature(forced.action, stable, sha);
            const std::string completion_reason = plan_cache_hit
                ? "cache_hit" : "forced_tactic";
            const std::string trajectory = sha(
                std::string("turn_beam_v2|") + completion_reason + "|" + signature);
            ptcg::ai::Value::Array sequence{forced.action};
            ptcg::ai::Value::Array preconditions{
                bridge.cache_precondition(
                    mandatory_position,
                    static_cast<std::int32_t>(int64_t(request.get("actor", -1))))};
            output["success"] = true;
            output["cancelled"] = false;
            output["error"] = "";
            output["action"] = ptcg::ai::value_to_godot(forced.action);
            output["sequence"] = ptcg::ai::value_to_godot(
                ptcg::ai::Value(sequence));
            output["cache_preconditions"] = ptcg::ai::value_to_godot(
                ptcg::ai::Value(preconditions));
            output["root_candidates"] = Array();
            output["score_milli"] = 0;
            output["worst_score_milli"] = 0;
            output["nodes_expanded"] = static_cast<int64_t>(forced.nodes_expanded);
            output["completed_depth"] = 0;
            output["max_path_depth"] = 0;
            output["reply_completed_depth"] = 0;
            output["reply_depth_applicable"] = false;
            output["completion_reason"] = String::utf8(
                completion_reason.c_str());
            output["forced_tactic"] = plan_cache_guarded
                ? Variant("post_plan_tactical_guard")
                : plan_cache_hit
                ? Variant("") : Variant(String::utf8(forced.reason.c_str()));
            output["stop_reason"] = String::utf8(forced.reason.c_str());
            output["trajectory_hash"] = String::utf8(trajectory.c_str());
            output["trajectory_events"] = 0;
            output["belief_samples"] = 0;
            output["belief_consensus"] = 0;
            output["root_signatures_attempted"] = Array();
            output["root_sample_counts"] = Dictionary();
            output["belief_seed_hash"] = "";
            // Forced/cache results in the frozen Challenge dictionary do not
            // report a searched opponent strategy.
            output["opponent_strategy_id"] = "";
            output["layers_completed"] = 0;
            output["reply_completion_reasons"] = Array();
            output["reply_completion_reason"] = "not_applicable";
            output["requested_depth"] = 8;
            output["reply_requested_depth"] = 3;
            output["search_depth_applicable"] = false;
            output["search_depth_requested"] = 8;
            output["search_depth_reached"] = 0;
            output["search_depth_completed"] = 0;
            output["search_depth_stop_reason"] = String::utf8(
                completion_reason.c_str());
            output["native_determinization"] = true;
            output["native_mandatory_tactics"] = true;
            output["native_setup_public_policy"] = setup_public_policy;
            output["native_turn_plan_cache_hit"] = plan_cache_hit;
            output["planner_ms"] = 0.0;
            output["native_mandatory_nodes"] = static_cast<int64_t>(
                forced.nodes_expanded);
            if (!mandatory_debug_error.empty()) {
                output["native_mandatory_debug_error"] = String::utf8(
                    mandatory_debug_error.c_str());
            }
            if (mandatory_debug_state.is_object()
                && !mandatory_debug_state.as_object().empty()) {
                output["native_mandatory_debug_state"] =
                    ptcg::ai::value_to_godot(mandatory_debug_state);
            }
            output["native_trusted_leaf_mismatches"] = 0;
            output["native_trusted_leaf_enabled"] = bridge.trusted_leaf_enabled();
            output["native_performance_counters"] =
                native_performance_counters();
            record_action_cycle_selection(
                request, public_state_value, forced.action);
            return output;
        }
    }
    ptcg::ai::TraditionalSearchConfig config;
    config.worker_count = search_worker_count;
    config.belief_samples = static_cast<std::size_t>(std::max<int64_t>(
        1, std::min<int64_t>(3, int64_t(request.get("belief_samples", 3)))));
    if (bool(request.get("internal_evaluation_smoke", false))) {
        config.root_actions = 2;
        config.per_root_width = 1;
        config.max_depth = 1;
        config.actions_per_node = 2;
        config.reply_depth = 1;
        config.reply_width = 2;
        config.reply_actions_per_node = 2;
        config.belief_samples = 1;
    }
    ptcg::ai::TraditionalTurnBeamSearch search(bridge, config);
    const auto planner_started = std::chrono::steady_clock::now();
    auto result = search.search(
        static_cast<std::int32_t>(int64_t(request.get("actor", -1))),
        static_cast<std::uint32_t>(int64_t(request.get("seed", 1))),
        ptcg::ai::value_from_godot(actions_variant),
        &cancel_requested_
    );
    const double planner_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - planner_started).count();
    const ptcg::ai::Value pre_guard_selected = result.selected;
    bool post_plan_guarded = false;
    if (result.success && bool(request.get("apply_tactical_guard", false))
        && information_set_ptr != nullptr) {
        const std::uint32_t guard_seed = static_cast<std::uint32_t>(
            int64_t(request.get("seed", 1)));
        const ptcg::ai::Value guard_sample = information_set_ptr->sample_state(
            guard_seed);
        ptcg::ai::RulesSession guard_position(catalog_value_);
        std::string guard_error;
        if (guard_sample.is_object() && guard_position.restore(
            guard_sample, guard_seed, &guard_error
        )) {
            bool changed = false;
            const ptcg::ai::Value guarded = bridge.post_plan_tactical_guard(
                guard_position,
                static_cast<std::int32_t>(int64_t(request.get("actor", -1))),
                result.selected,
                ptcg::ai::value_from_godot(actions_variant),
                guard_seed + 700001U,
                changed);
            if (changed) {
                result.selected = guarded;
                result.sequence = {guarded};
                result.cache_preconditions = {bridge.cache_precondition(
                    guard_position,
                    static_cast<std::int32_t>(int64_t(request.get("actor", -1))))};
                post_plan_guarded = true;
            }
        }
    }
    if (result.success) {
        store_turn_plan(plan_cache_key, request_revision, result);
    }
    active_generation_.store(0, std::memory_order_release);
    output["success"] = result.success;
    output["cancelled"] = result.cancelled;
    output["error"] = String::utf8(result.error.c_str());
    output["action"] = ptcg::ai::value_to_godot(result.selected);
    output["sequence"] = ptcg::ai::value_to_godot(
        ptcg::ai::Value(result.sequence));
    output["cache_preconditions"] = ptcg::ai::value_to_godot(
        ptcg::ai::Value(result.cache_preconditions));
    output["root_candidates"] = ptcg::ai::value_to_godot(
        ptcg::ai::Value(result.root_candidates));
    output["score_milli"] = result.score_milli;
    output["worst_score_milli"] = result.worst_score_milli;
    output["nodes_expanded"] = static_cast<int64_t>(result.nodes_expanded);
    output["planner_ms"] = planner_ms;
    output["completed_depth"] = static_cast<int64_t>(result.completed_depth);
    output["max_path_depth"] = static_cast<int64_t>(result.max_path_depth);
    output["reply_completed_depth"] = static_cast<int64_t>(
        result.reply_completed_depth);
    output["reply_depth_applicable"] = result.reply_depth_applicable;
    output["completion_reason"] = String::utf8(
        result.completion_reason.c_str());
    output["forced_tactic"] = post_plan_guarded
        ? Variant("post_plan_tactical_guard") : Variant("");
    if (bool(request.get("internal_debug_decision_payload", false))) {
        output["native_debug_pre_guard_action"] =
            ptcg::ai::value_to_godot(pre_guard_selected);
    }
    output["trajectory_hash"] = String::utf8(
        result.trajectory_hash.c_str());
    output["trajectory_events"] = static_cast<int64_t>(
        result.trajectory_events);
    output["belief_samples"] = static_cast<int64_t>(result.belief_samples);
    output["belief_consensus"] = static_cast<int64_t>(result.belief_consensus);
    Array attempted_roots;
    for (const std::string &signature : result.root_signatures_attempted) {
        attempted_roots.push_back(String::utf8(signature.c_str()));
    }
    output["root_signatures_attempted"] = attempted_roots;
    Dictionary root_sample_counts;
    for (const auto &[signature, count] : result.root_sample_counts) {
        root_sample_counts[String::utf8(signature.c_str())] =
            static_cast<int64_t>(count);
    }
    output["root_sample_counts"] = root_sample_counts;
    output["belief_seed_hash"] = String::utf8(
        result.belief_seed_hash.c_str());
    output["opponent_strategy_id"] = String::utf8(
        result.opponent_strategy_id.c_str());
    output["layers_completed"] = static_cast<int64_t>(
        result.layers_completed);
    Array reply_reasons;
    for (const std::string &reason : result.reply_completion_reasons) {
        reply_reasons.push_back(String::utf8(reason.c_str()));
    }
    output["reply_completion_reasons"] = reply_reasons;
    output["reply_completion_reason"] = String::utf8(
        result.reply_completion_reason.c_str());
    output["requested_depth"] = static_cast<int64_t>(config.max_depth);
    output["reply_requested_depth"] = static_cast<int64_t>(config.reply_depth);
    output["search_depth_applicable"] = true;
    output["search_depth_requested"] = static_cast<int64_t>(config.max_depth);
    output["search_depth_reached"] = static_cast<int64_t>(
        result.max_path_depth);
    output["search_depth_completed"] = static_cast<int64_t>(
        result.completed_depth);
    output["search_depth_stop_reason"] = String::utf8(
        result.completion_reason.c_str());
    output["native_determinization"] = information_set_ptr != nullptr;
    output["native_trusted_leaf_mismatches"] = 0;
    output["native_trusted_leaf_enabled"] = bridge.trusted_leaf_enabled();
    output["native_performance_counters"] = native_performance_counters();
    output["native_mandatory_tactics"] = !bool(request.get(
        "skip_mandatory", false));
    output["native_mandatory_nodes"] = static_cast<int64_t>(mandatory_nodes);
    output["native_mandatory_reason"] = String::utf8(mandatory_reason.c_str());
    if (!mandatory_debug_error.empty()) {
        output["native_mandatory_debug_error"] = String::utf8(
            mandatory_debug_error.c_str());
    }
    if (mandatory_debug_state.is_object()
        && !mandatory_debug_state.as_object().empty()) {
        output["native_mandatory_debug_state"] =
            ptcg::ai::value_to_godot(mandatory_debug_state);
    }
    output["native_turn_plan_cache_hit"] = false;
    if (bool(request.get("internal_debug_trajectory", false))) {
        Array debug_events;
        for (const std::string &event : bridge.debug_trajectory_events()) {
            debug_events.push_back(String::utf8(event.c_str()));
        }
        output["debug_trajectory_events"] = debug_events;
        if (!bridge.first_rank_mismatch().is_empty()) {
            output["first_rank_mismatch"] = bridge.first_rank_mismatch();
        }
        if (!bridge.first_state_score_mismatch().is_empty()) {
            output["first_state_score_mismatch"] =
                bridge.first_state_score_mismatch();
        }
        if (!bridge.first_choice_mismatch().is_empty()) {
            output["first_choice_mismatch"] = bridge.first_choice_mismatch();
        }
        output["debug_actions_by_signature"] =
            bridge.debug_actions_by_signature();
        output["debug_states_by_fingerprint"] =
            bridge.debug_states_by_fingerprint();
    }
    if (result.success) {
        record_action_cycle_selection(
            request, public_state_value, result.selected);
    }
    return output;
}

Dictionary NativeTraditionalAI::decide_choice(
    const Dictionary &request,
    int64_t generation
) {
    Dictionary output;
    if (!configured_ || strategy_catalog_ == nullptr) {
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = "native_traditional_not_configured";
        return output;
    }
    if (generation <= cancelled_through_generation_.load(
            std::memory_order_acquire)) {
        output["success"] = false;
        output["kind"] = "choice";
        output["cancelled"] = true;
        output["error"] = "cancelled";
        return output;
    }
    const Variant state_variant = request.get("state", Variant());
    const Variant choice_variant = request.get("choice", Variant());
    if (state_variant.get_type() != Variant::DICTIONARY
        || choice_variant.get_type() != Variant::DICTIONARY) {
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = "invalid_choice_request";
        return output;
    }
    const ptcg::ai::Value public_state = ptcg::ai::value_from_godot(state_variant);
    const ptcg::ai::Value choice = ptcg::ai::value_from_godot(choice_variant);
    const std::int64_t revision = int64_t(request.get("revision", -1));
    if (revision < 0 || revision != value_integer_field(public_state, "revision", -2)
        || revision != value_integer_field(choice, "base_revision", -3)) {
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = "stale_choice_revision";
        return output;
    }
    const std::int32_t fallback_actor = static_cast<std::int32_t>(
        int64_t(request.get("actor", -1)));
    const std::int32_t choice_actor = static_cast<std::int32_t>(
        value_integer_field(choice, "player", fallback_actor));
    if (choice_actor < 0 || choice_actor > 1) {
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = "invalid_actor";
        return output;
    }
    active_generation_.store(generation, std::memory_order_release);
    cancel_requested_.store(false, std::memory_order_release);
    ptcg::ai::TraditionalInformationSet information_set;
    std::string error;
    if (!information_set.capture(
        public_state,
        choice_actor,
        catalog_value_, decks_value_,
        ptcg::ai::Value::make_array(), ptcg::ai::Value::make_array(),
        int64_t(request.get("match_seed", request.get("seed", 0))),
        &error
    )) {
        active_generation_.store(0, std::memory_order_release);
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = String::utf8(error.c_str());
        return output;
    }
    const std::uint32_t seed = static_cast<std::uint32_t>(
        int64_t(request.get("seed", 17)));
    const ptcg::ai::Value sampled = information_set.sample_state(seed);
    ptcg::ai::RulesSession position(catalog_value_);
    if (!sampled.is_object() || !position.restore(sampled, seed, &error)) {
        active_generation_.store(0, std::memory_order_release);
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = error.empty()
            ? "choice_determinization_failed" : String::utf8(error.c_str());
        return output;
    }
    auto bridge_owner = make_native_traditional_search_provider(
        Callable(), catalog_value_, decks_value_, strategies_value_,
        choice_actor, &information_set, false, true);
    NativeTraditionalSearchProvider &bridge = *bridge_owner;
    ptcg::ai::Value response;
    const ptcg::ai::Value *options = choice.find("options");
    if (options != nullptr && options->is_array() && options->as_array().empty()) {
        const bool cancelled = value_integer_field(choice, "min_select", 0) <= 0
            && choice.find("can_cancel") != nullptr
            && choice.find("can_cancel")->as_bool(false);
        response = ptcg::ai::Value(ptcg::ai::Value::Object{
            {"request_id", ptcg::ai::Value(value_string_field(
                choice, "request_id"))},
            {"option_ids", ptcg::ai::Value::make_array()},
            {"cancelled", ptcg::ai::Value(cancelled)},
        });
    } else if (!bridge.select_external_choice(position, choice, response)) {
        active_generation_.store(0, std::memory_order_release);
        output["success"] = false;
        output["kind"] = "choice";
        output["error"] = "choice_response_constraints_unsatisfied";
        output["native_performance_counters"] = bridge.performance_counters();
        return output;
    }
    if (cancel_requested_.load(std::memory_order_acquire)) {
        active_generation_.store(0, std::memory_order_release);
        output["success"] = false;
        output["kind"] = "choice";
        output["cancelled"] = true;
        output["error"] = "cancelled";
        return output;
    }
    active_generation_.store(0, std::memory_order_release);
    const std::string deck_key = [&]() {
        const ptcg::ai::Value *keys = position.search_state().find(
            "public_deck_keys");
        return keys != nullptr && keys->is_array()
            && static_cast<std::size_t>(choice_actor) < keys->as_array().size()
            ? keys->as_array()[static_cast<std::size_t>(choice_actor)].string_or()
            : std::string{};
    }();
    const std::string strategy_id = strategy_catalog_->strategy_id(deck_key);
    const std::string strategy_hash = strategy_catalog_->strategy_content_hash(
        deck_key);
    const String engine_id = String(request.get("engine", "turn_beam_v2"));
    output["success"] = true;
    output["kind"] = "choice";
    output["choice_response"] = ptcg::ai::value_to_godot(response);
    output["simulations"] = 0;
    output["deep_fallback"] = String(request.get("mode", "challenge")) == "deep";
    output["fallback_reason"] = bool(output["deep_fallback"])
        ? Variant("runtime_unavailable") : Variant("");
    output["strategy_id"] = String::utf8(strategy_id.c_str());
    output["strategy_version"] = strategy_catalog_->strategy_version(deck_key);
    output["strategy_hash"] = String::utf8(strategy_hash.c_str());
    output["engine_id"] = engine_id;
    output["planner"] = engine_id;
    output["completion_reason"] = "forced_tactic";
    output["decision_origin"] = "choice_policy";
    output["failure_stage"] = "";
    output["type_matchups"] = false;
    output["revision"] = revision;
    output["request_id"] = request.get("request_id", "");
    output["heuristic_variant"] = "semantic_v2";
    output["native_performance_counters"] = bridge.performance_counters();
    return output;
}

Dictionary NativeTraditionalAI::decide(
    const Dictionary &request,
    int64_t generation
) {
    const auto decision_started = std::chrono::steady_clock::now();
    if (String(request.get("kind", "action")) == "choice") {
        Dictionary choice_result = decide_choice(request, generation);
        choice_result["elapsed_ms"] = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - decision_started).count();
        return choice_result;
    }
    Dictionary native_request = request.duplicate(true);
    native_request["internal_debug_trajectory"] = false;
    native_request["apply_tactical_guard"] = true;
    Dictionary planner_result = decide_controller(
        native_request, generation, Callable(), true);
    const double elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - decision_started).count();
    if (!bool(planner_result.get("success", false))) {
        planner_result["kind"] = "action";
        planner_result["decision_origin"] = "failure";
        planner_result["failure_stage"] = "search";
        planner_result["revision"] = request.get("revision", -1);
        planner_result["request_id"] = request.get("request_id", "");
        planner_result["elapsed_ms"] = elapsed_ms;
        planner_result["heuristic_variant"] = "semantic_v2";
        return planner_result;
    }
    const Dictionary counters = planner_result.get(
        "native_performance_counters", Dictionary());
    const Variant action_variant = planner_result.get("action", Variant());
    if (action_variant.get_type() != Variant::DICTIONARY) {
        planner_result["success"] = false;
        planner_result["kind"] = "action";
        planner_result["error"] = "native_traditional_missing_action";
        planner_result["decision_origin"] = "failure";
        planner_result["failure_stage"] = "search";
        return planner_result;
    }
    planner_result["engine_id"] = String(request.get(
        "engine", "turn_beam_v2"));
    const ptcg::ai::Value selected = ptcg::ai::value_from_godot(action_variant);
    const ptcg::ai::Value sequence = ptcg::ai::value_from_godot(
        planner_result.get("sequence", Array()));
    ptcg::ai::Value preconditions = ptcg::ai::value_from_godot(
        planner_result.get("cache_preconditions", Array()));
    const bool cache_hit = bool(planner_result.get(
        "native_turn_plan_cache_hit", false));
    const bool cache_guarded = cache_hit
        && !String(planner_result.get("forced_tactic", "")).is_empty();
    ptcg::ai::Value turn_plan = ptcg::ai::Value::make_array();
    if ((!cache_hit || cache_guarded)
        && sequence.is_array() && preconditions.is_array()) {
        const std::size_t count = std::min(
            sequence.as_array().size(), preconditions.as_array().size());
        turn_plan.as_array().reserve(count);
        for (std::size_t index = 0; index < count; ++index) {
            turn_plan.as_array().push_back(action_intent(
                sequence.as_array()[index], &preconditions.as_array()[index]));
        }
    }
    ptcg::ai::Value planner_value = ptcg::ai::value_from_godot(planner_result);
    planner_value["turn_plan"] = turn_plan;
    if (cache_hit && !cache_guarded) {
        planner_value["cache_preconditions"] = ptcg::ai::Value::make_array();
    }
    const std::string semantic_completion = value_string_field(
        planner_value, "completion_reason");
    // The frozen Challenge wrapper reports preflight nodes publicly, but its
    // forced/cache planner payload has no nodes_expanded member. Preserve that
    // distinction in decision_semantic_hash.
    if (semantic_completion == "forced_tactic" || semantic_completion == "cache_hit") {
        planner_value["nodes_expanded"] = ptcg::ai::Value(0);
    }
    ptcg::ai::Value semantic_payload = ptcg::ai::Value::make_object();
    const bool debug_decision_payload = bool(request.get(
        "internal_debug_decision_payload", false));
    const std::string semantic_hash = traditional_decision_semantic_hash(
        selected,
        planner_value,
        turn_plan,
        debug_decision_payload ? &semantic_payload : nullptr);
    const std::int32_t actor = static_cast<std::int32_t>(
        int64_t(request.get("actor", -1)));
    const Variant public_state_variant = request.get(
        "public_snapshot", request.get("state", Variant()));
    const ptcg::ai::Value public_state =
        public_state_variant.get_type() == Variant::DICTIONARY
        ? ptcg::ai::value_from_godot(public_state_variant)
        : ptcg::ai::Value::make_object();
    const ptcg::ai::Value *keys = public_state.find("public_deck_keys");
    const std::string inferred_deck_key = keys != nullptr && keys->is_array()
        && actor >= 0 && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    const std::string requested_deck_key = godot_string_utf8(String(
        request.get("deck_key", "")));
    const std::string deck_key = requested_deck_key.empty()
        ? inferred_deck_key : requested_deck_key;
    const std::string strategy_id = strategy_catalog_ == nullptr
        ? "generic_balanced_v1" : strategy_catalog_->strategy_id(deck_key);
    const std::int64_t strategy_version = strategy_catalog_ == nullptr
        ? 0 : strategy_catalog_->strategy_version(deck_key);
    const std::string strategy_hash = strategy_catalog_ == nullptr
        ? std::string{} : strategy_catalog_->strategy_content_hash(deck_key);
    const String engine_id = String(planner_result.get(
        "engine_id", "turn_beam_v2"));
    const String completion_reason = String(planner_result.get(
        "completion_reason", ""));
    const String forced_tactic = String(planner_result.get(
        "forced_tactic", ""));
    Dictionary output;
    output["success"] = true;
    output["kind"] = "action";
    output["action"] = action_variant;
    output["engine_id"] = engine_id;
    output["simulations"] = planner_result.get("nodes_expanded", 0);
    output["nodes_expanded"] = planner_result.get("nodes_expanded", 0);
    output["planner_ms"] = planner_result.get("planner_ms", 0.0);
    output["trajectory_hash"] = planner_result.get("trajectory_hash", "");
    output["decision_semantic_hash"] = String::utf8(semantic_hash.c_str());
    const bool deep_fallback = String(request.get("mode", "challenge")) == "deep";
    output["deep_fallback"] = deep_fallback;
    output["fallback_reason"] = deep_fallback ? "runtime_unavailable" : "";
    output["planner"] = engine_id;
    output["decision_origin"] = cache_hit ? "cache"
        : (completion_reason == "forced_tactic" || !forced_tactic.is_empty())
        ? "forced_tactic" : "search";
    output["failure_stage"] = "";
    const int64_t score_milli = int64_t(planner_result.get("score_milli", 0));
    output["planner_score"] = static_cast<double>(score_milli) / 1000.0;
    output["planner_score_milli"] = score_milli;
    output["belief_samples"] = planner_result.get("belief_samples", 0);
    output["belief_consensus"] = planner_result.get("belief_consensus", 0);
    output["forced_tactic"] = forced_tactic;
    output["turn_plan_size"] = static_cast<int64_t>(turn_plan.as_array().size());
    output["turn_plan_cache_hit"] = cache_hit;
    for (const char *key : {
        "requested_depth", "completed_depth", "max_path_depth",
        "reply_completed_depth", "reply_depth_applicable",
        "reply_requested_depth", "reply_completion_reason",
        "opponent_strategy_id", "layers_completed", "search_depth_applicable",
        "search_depth_requested", "search_depth_reached",
        "search_depth_completed", "search_depth_stop_reason",
    }) output[key] = planner_result.get(key, Variant());
    output["completion_reason"] = completion_reason;
    output["planner_error"] = planner_result.get("error", "");
    output["strategy_id"] = String::utf8(strategy_id.c_str());
    output["strategy_version"] = strategy_version;
    output["strategy_hash"] = String::utf8(strategy_hash.c_str());
    output["turn_goal"] = strategy_catalog_ == nullptr
        ? Variant(Dictionary())
        : ptcg::ai::value_to_godot(
            strategy_catalog_->turn_goals(public_state, actor));
    output["type_matchups"] = false;
    output["revision"] = request.get("revision", -1);
    output["request_id"] = request.get("request_id", "");
    output["elapsed_ms"] = elapsed_ms;
    output["heuristic_variant"] = "semantic_v2";
    output["native_performance_counters"] = counters;
    for (const Variant &key : planner_result.keys()) {
        const String name = String(key);
        if (name.begins_with("native_")) output[key] = planner_result[key];
    }
    if (bool(request.get("internal_debug_decision_payload", false))) {
        Dictionary debug;
        debug["turn_plan"] = ptcg::ai::value_to_godot(turn_plan);
        debug["cache_preconditions"] = planner_result.get(
            "cache_preconditions", Array());
        debug["root_signatures_attempted"] = planner_result.get(
            "root_signatures_attempted", Array());
        debug["root_sample_counts"] = planner_result.get(
            "root_sample_counts", Dictionary());
        debug["belief_seed_hash"] = planner_result.get("belief_seed_hash", "");
        debug["score_milli"] = planner_result.get("score_milli", 0);
        debug["semantic_payload"] = ptcg::ai::value_to_godot(semantic_payload);
        output["internal_debug_decision_payload"] = debug;
    }
    return output;
}

#ifdef DEBUG_ENABLED
Dictionary NativeTraditionalAI::debug_determinize(
    const Dictionary &public_state,
    int64_t actor,
    int64_t seed,
    int64_t match_seed
) const {
    Dictionary output;
    if (!configured_) {
        output["success"] = false;
        output["error"] = "native_traditional_not_configured";
        return output;
    }
    ptcg::ai::TraditionalInformationSet information_set;
    std::string error;
    if (!information_set.capture(
        ptcg::ai::value_from_godot(public_state),
        static_cast<std::int32_t>(actor),
        catalog_value_, decks_value_,
        ptcg::ai::Value::make_array(),
        ptcg::ai::Value::make_array(),
        match_seed,
        &error
    )) {
        output["success"] = false;
        output["error"] = String::utf8(error.c_str());
        return output;
    }
    const ptcg::ai::Value snapshot = information_set.sample_state(
        static_cast<std::uint32_t>(seed));
    output["success"] = snapshot.is_object();
    output["error"] = snapshot.is_object() ? "" : "determinization_failed";
    output["snapshot"] = ptcg::ai::value_to_godot(snapshot);
    output["rng_state"] = seed;
    return output;
}

Dictionary NativeTraditionalAI::debug_strategy_scores(
    const Dictionary &state,
    int64_t actor,
    const Array &actions
) const {
    Dictionary output;
    if (!configured_ || strategy_catalog_ == nullptr
        || !strategy_catalog_->valid()) {
        output["success"] = false;
        output["error"] = "native_strategy_catalog_unavailable";
        return output;
    }
    const ptcg::ai::Value state_value = ptcg::ai::value_from_godot(state);
    output["success"] = true;
    output["error"] = "";
    output["state_score"] = strategy_catalog_->state_score(
        state_value, static_cast<std::int32_t>(actor));
    Array scores;
    for (int64_t index = 0; index < actions.size(); ++index) {
        scores.push_back(strategy_catalog_->action_score(
            state_value,
            static_cast<std::int32_t>(actor),
            ptcg::ai::value_from_godot(actions[index])));
    }
    output["action_scores"] = scores;
    return output;
}

Dictionary NativeTraditionalAI::debug_strategy_choice_scores(
    const Dictionary &state,
    int64_t actor,
    const Dictionary &choice_view,
    const Array &options
) const {
    Dictionary output;
    if (!configured_ || strategy_catalog_ == nullptr
        || !strategy_catalog_->valid()) {
        output["success"] = false;
        output["error"] = "native_strategy_catalog_unavailable";
        return output;
    }
    const ptcg::ai::Value state_value = ptcg::ai::value_from_godot(state);
    const ptcg::ai::Value choice_value = ptcg::ai::value_from_godot(choice_view);
    Array scores;
    for (int64_t index = 0; index < options.size(); ++index) {
        scores.push_back(strategy_catalog_->choice_score(
            state_value,
            static_cast<std::int32_t>(actor),
            choice_value,
            ptcg::ai::value_from_godot(options[index])));
    }
    output["success"] = true;
    output["error"] = "";
    output["choice_scores"] = scores;
    return output;
}

Dictionary NativeTraditionalAI::debug_trusted_leaf_score(
    const Dictionary &snapshot,
    int64_t actor,
    int64_t rng_state
) const {
    Dictionary output;
    if (!configured_ || trusted_evaluator_ == nullptr) {
        output["success"] = false;
        output["error"] = "native_trusted_evaluator_unavailable";
        return output;
    }
    ptcg::ai::RulesSession position(catalog_value_);
    std::string error;
    if (!position.restore(
        ptcg::ai::value_from_godot(snapshot),
        static_cast<std::uint32_t>(rng_state),
        &error
    )) {
        output["success"] = false;
        output["error"] = String::utf8(error.c_str());
        return output;
    }
    output["success"] = true;
    output["error"] = "";
    output["score"] = trusted_evaluator_->leaf_score(
        position, static_cast<std::int32_t>(actor));
    return output;
}

Dictionary NativeTraditionalAI::debug_trusted_action_scores(
    const Dictionary &snapshot,
    int64_t actor,
    const Array &actions,
    int64_t rng_state
) const {
    Dictionary output;
    if (!configured_ || trusted_evaluator_ == nullptr) {
        output["success"] = false;
        output["error"] = "native_trusted_evaluator_unavailable";
        return output;
    }
    ptcg::ai::RulesSession position(catalog_value_);
    std::string error;
    if (!position.restore(
        ptcg::ai::value_from_godot(snapshot),
        static_cast<std::uint32_t>(rng_state),
        &error
    )) {
        output["success"] = false;
        output["error"] = String::utf8(error.c_str());
        return output;
    }
    Array rows;
    rows.resize(actions.size());
    for (int64_t index = 0; index < actions.size(); ++index) {
        Dictionary row;
        const std::optional<double> score = trusted_evaluator_->action_score(
            position,
            static_cast<std::int32_t>(actor),
            ptcg::ai::value_from_godot(actions[index]));
        row["supported"] = score.has_value();
        row["score"] = score.value_or(0.0);
        rows[index] = row;
    }
    output["success"] = true;
    output["error"] = "";
    output["rows"] = rows;
    return output;
}

Dictionary NativeTraditionalAI::debug_tactical_candidates(
    const Dictionary &public_state,
    int64_t actor,
    const Array &actions,
    int64_t sample_seed,
    int64_t candidate_seed,
    int64_t match_seed
) const {
    Dictionary output;
    if (!configured_ || trusted_evaluator_ == nullptr
        || strategy_catalog_ == nullptr || actor < 0 || actor > 1) {
        output["success"] = false;
        output["error"] = "native_tactical_debug_unavailable";
        return output;
    }
    const ptcg::ai::Value action_value = ptcg::ai::value_from_godot(actions);
    ptcg::ai::TraditionalInformationSet information_set;
    std::string error;
    if (!information_set.capture(
        ptcg::ai::value_from_godot(public_state),
        static_cast<std::int32_t>(actor),
        catalog_value_, decks_value_, action_value,
        ptcg::ai::Value::make_array(), match_seed, &error
    )) {
        output["success"] = false;
        output["error"] = String::utf8(error.c_str());
        return output;
    }
    const ptcg::ai::Value sample = information_set.sample_state(
        static_cast<std::uint32_t>(sample_seed));
    ptcg::ai::RulesSession position(catalog_value_);
    if (!sample.is_object() || !position.restore(
        sample, static_cast<std::uint32_t>(sample_seed), &error
    )) {
        output["success"] = false;
        output["error"] = error.empty()
            ? "native_tactical_debug_restore_failed"
            : String::utf8(error.c_str());
        return output;
    }
    auto bridge_owner = make_native_traditional_search_provider(
        Callable(), catalog_value_, decks_value_, strategies_value_,
        static_cast<std::int32_t>(actor), &information_set, false, true);
    NativeTraditionalSearchProvider &bridge = *bridge_owner;
    const double base_raw = trusted_evaluator_->raw_evaluation(
        position, static_cast<std::int32_t>(actor));
    Array rows;
    rows.resize(actions.size());
    for (int64_t index = 0; index < actions.size(); ++index) {
        const ptcg::ai::Value action = ptcg::ai::value_from_godot(actions[index]);
        Dictionary row;
        row["action"] = actions[index];
        const std::optional<double> trusted = trusted_evaluator_->action_score(
            position, static_cast<std::int32_t>(actor), action);
        const std::optional<double> development =
            trusted_evaluator_->development_action_value(
                position, static_cast<std::int32_t>(actor), action);
        const double strategy = strategy_catalog_->action_score(
            position.search_state(), static_cast<std::int32_t>(actor), action);
        const std::int64_t canonical =
            ptcg::ai::TraditionalPositionEvaluator::quantize(
                trusted.value_or(0.0))
            + std::max<std::int64_t>(-250000, std::min<std::int64_t>(
                250000,
                ptcg::ai::TraditionalPositionEvaluator::quantize(strategy)));
        row["trusted_supported"] = trusted.has_value();
        row["trusted"] = trusted.value_or(0.0);
        row["development_supported"] = development.has_value();
        row["development"] = development.value_or(0.0);
        row["strategy"] = strategy;
        row["canonical_milli"] = canonical;
        row["estimated_damage"] = trusted_evaluator_->action_estimated_damage(
            position, static_cast<std::int32_t>(actor), action);
        row["attack_tactically_unsafe"] =
            trusted_evaluator_->attack_tactically_unsafe(
                position, static_cast<std::int32_t>(actor), action);
        const std::uint32_t action_seed = static_cast<std::uint32_t>(
            candidate_seed + index * 7919);
        std::unique_ptr<ptcg::ai::RulesSession> simulation =
            position.fork_for_search(action_seed);
        bool simulation_success = false;
        double simulated_raw = 0.0;
        if (simulation) {
            const ptcg::ai::Value bound = bridge.bind_action(
                action, *simulation, static_cast<std::int32_t>(actor),
                "debug_tactical_" + std::to_string(index));
            const ptcg::ai::RulesSessionResult applied =
                simulation->apply_action(bound);
            std::uint64_t nodes = 0;
            ptcg::ai::TraditionalChoiceTrace trace;
            simulation_success = applied.success && bridge.resolve_pending(
                *simulation, static_cast<std::int32_t>(actor), nodes, trace);
            if (simulation_success) {
                simulated_raw = trusted_evaluator_->raw_evaluation(
                    *simulation, static_cast<std::int32_t>(actor));
            }
        }
        row["simulation_success"] = simulation_success;
        row["simulated_raw"] = simulated_raw;
        row["delta"] = simulation_success ? simulated_raw - base_raw : 0.0;
        double value = development.value_or(0.0)
            + (simulation_success ? simulated_raw - base_raw : 0.0) * 0.45
            + static_cast<double>(canonical) / 1000.0 * 0.04;
        const std::string kind = value_string_field(action, "kind");
        if (kind == "PLAY_BASIC") {
            const ptcg::ai::Value &owner = value_player(
                position.search_state(), static_cast<std::int32_t>(actor));
            const ptcg::ai::Value *bench = owner.find("bench");
            const std::size_t bench_count = bench != nullptr && bench->is_array()
                ? static_cast<std::size_t>(std::count_if(
                    bench->as_array().begin(), bench->as_array().end(),
                    [](const ptcg::ai::Value &entry) { return entry.is_object(); }))
                : 0;
            if (bench_count < 2) value += 45.0;
        }
        if (kind == "EVOLVE") value += 35.0;
        else if (kind == "ATTACH_ENERGY") value += 30.0;
        row["productive_value"] = value;
        rows[index] = row;
    }
    output["success"] = true;
    output["error"] = "";
    output["base_raw"] = base_raw;
    output["active_missing_energy"] =
        trusted_evaluator_->active_missing_energy(
            position, static_cast<std::int32_t>(actor));
    output["sample_seed"] = sample_seed;
    output["candidate_seed"] = candidate_seed;
    output["sample_hash"] = stable_value_signature(sample).sha256_text();
    output["sample"] = ptcg::ai::value_to_godot(sample);
    output["rows"] = rows;
    return output;
}

Dictionary NativeTraditionalAI::debug_mandatory_tactics(
    const Dictionary &public_state,
    int64_t actor,
    const Array &actions,
    int64_t seed,
    int64_t match_seed,
    int64_t node_budget
) const {
    Dictionary output;
    if (!configured_ || strategy_catalog_ == nullptr
        || trusted_evaluator_ == nullptr) {
        output["success"] = false;
        output["error"] = "native_mandatory_tactics_unavailable";
        return output;
    }
    ptcg::ai::TraditionalInformationSet information_set;
    std::string error;
    const ptcg::ai::Value action_value = ptcg::ai::value_from_godot(actions);
    if (!information_set.capture(
        ptcg::ai::value_from_godot(public_state),
        static_cast<std::int32_t>(actor),
        catalog_value_, decks_value_, action_value,
        ptcg::ai::Value::make_array(), match_seed, &error
    )) {
        output["success"] = false;
        output["error"] = String::utf8(error.c_str());
        return output;
    }
    const ptcg::ai::Value sample = information_set.sample_state(
        static_cast<std::uint32_t>(seed));
    ptcg::ai::RulesSession position(catalog_value_);
    if (!sample.is_object() || !position.restore(
        sample, static_cast<std::uint32_t>(seed), &error
    )) {
        output["success"] = false;
        output["error"] = error.empty()
            ? "native_mandatory_determinization_failed"
            : String::utf8(error.c_str());
        return output;
    }
    auto bridge_owner = make_native_traditional_search_provider(
        Callable(), catalog_value_, decks_value_, strategies_value_,
        static_cast<std::int32_t>(actor), &information_set, false, true);
    NativeTraditionalSearchProvider &bridge = *bridge_owner;
    const ptcg::ai::TraditionalMandatoryTactics tactics(
        catalog_value_, *strategy_catalog_, *trusted_evaluator_);
    const ptcg::ai::TraditionalMandatoryResult result = tactics.resolve(
        information_set, position, static_cast<std::int32_t>(actor), action_value,
        bridge, static_cast<std::uint32_t>(seed),
        static_cast<std::uint64_t>(std::max<int64_t>(0, node_budget)));
    output["success"] = true;
    output["error"] = "";
    output["resolved"] = result.resolved;
    output["cancelled"] = result.cancelled;
    output["reason"] = String::utf8(result.reason.c_str());
    output["nodes_expanded"] = static_cast<int64_t>(result.nodes_expanded);
    output["action"] = result.resolved
        ? ptcg::ai::value_to_godot(result.action) : Variant();
    output["native_performance_counters"] = bridge.performance_counters();
    if (!result.debug_last_step_error.empty()) {
        output["debug_last_step_error"] = String::utf8(
            result.debug_last_step_error.c_str());
    }
    if (result.debug_last_state.is_object()
        && !result.debug_last_state.as_object().empty()) {
        output["debug_last_state"] = ptcg::ai::value_to_godot(
            result.debug_last_state);
    }
    return output;
}
#endif

void NativeTraditionalAI::cancel(int64_t generation) noexcept {
    int64_t observed = cancelled_through_generation_.load(
        std::memory_order_relaxed);
    while (
        observed < generation
        && !cancelled_through_generation_.compare_exchange_weak(
            observed,
            generation,
            std::memory_order_release,
            std::memory_order_relaxed)
    ) {}
    const int64_t active = active_generation_.load(std::memory_order_acquire);
    if (active > 0 && active <= generation) {
        cancel_requested_.store(true, std::memory_order_release);
    }
}

void NativeTraditionalAI::reset_match(const String &match_instance_id) {
    if (active_match_instance_id_ != match_instance_id) {
        action_cycle_ledger_.clear();
        action_cycle_order_.clear();
        turn_plan_cache_.clear();
        turn_plan_cache_order_.clear();
    }
    active_match_instance_id_ = match_instance_id;
}

Dictionary NativeTraditionalAI::get_contract() const {
    Dictionary result;
    result["schema"] = "ptcg_native_traditional_ai/1";
    result["search_version"] =
        ptcg::ai::NATIVE_TRADITIONAL_SEARCH_VERSION;
    result["engine_id"] = "turn_beam_v2";
    result["action_schema_version"] = 4;
    result["choice_view_schema_version"] = 2;
    result["snapshot_schema_version"] = 3;
    result["max_depth"] = 8;
    result["belief_samples"] = 3;
    result["reply_depth"] = 3;
    result["atomic_generation_cancellation"] = true;
    result["callback_free"] = true;
    result["typed_core_state_cache"] = true;
    result["typed_authoritative_core"] = true;
    result["typed_vm_ir"] = true;
    result["native_information_set"] = true;
    result["native_action_policy"] = true;
    result["native_position_evaluator"] = true;
    result["native_strategy_hooks"] = true;
    result["native_trusted_leaf_evaluator"] = true;
    result["native_trusted_action_evaluator"] = true;
    result["native_choice_policy"] = true;
    result["native_mandatory_tactics"] = true;
    result["native_setup_public_policy"] = true;
    result["native_repeatable_ability_guard"] = true;
    result["native_no_progress_loop_guard"] = true;
    result["native_turn_plan_cache"] = true;
#if defined(__ANDROID__)
    result["search_worker_count"] = 2;
    result["parallel_belief_samples"] = true;
#elif defined(_WIN32)
    result["search_worker_count"] = 3;
    result["parallel_belief_samples"] = true;
#else
    result["search_worker_count"] = 1;
    result["parallel_belief_samples"] = false;
#endif
    result["performance_counters"] = true;
    result["production_ready"] = true;
    return result;
}

bool NativeTraditionalAI::is_configured() const noexcept {
    return configured_;
}

} // namespace godot

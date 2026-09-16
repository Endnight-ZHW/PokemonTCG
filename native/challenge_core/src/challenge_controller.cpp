#include "challenge_controller.hpp"

#include "challenge_search_provider.hpp"
#include "challenge_search_support.hpp"
#include "ptcg_traditional_value.hpp"
#include "information_set.hpp"
#include "ptcg_traditional_policy.hpp"
#include "card_evaluator.hpp"

#include <algorithm>
#include <chrono>
#include <functional>
#include <limits>
#include <optional>
#include <utility>

namespace ptcg::ai {
namespace {

using namespace challenge;

using traditional_value::bool_field;
using traditional_value::field;
using traditional_value::integer_field;
using traditional_value::string_field;

Value value_or(const Value &value, const char *key, Value fallback = {}) {
    const Value *entry = field(value, key);
    return entry == nullptr ? std::move(fallback) : *entry;
}

struct ActiveRequest {
    std::atomic<std::int64_t> &generation;
    ~ActiveRequest() { generation.store(0, std::memory_order_release); }
};

Value error_result(const std::string &error, bool cancelled = false) {
    return Value(Value::Object{
        {"success", Value(false)},
        {"cancelled", Value(cancelled)},
        {"error", Value(error)},
    });
}

Value strings_value(const std::vector<std::string> &values) {
    Value::Array result;
    result.reserve(values.size());
    for (const std::string &value : values)
        result.emplace_back(value);
    return Value(std::move(result));
}

Value search_result_value(const SearchResult &result, std::size_t requested_depth,
                          std::size_t reply_depth) {
    Value root_counts = Value::make_object();
    for (const auto &[signature, count] : result.root_sample_counts) {
        root_counts[signature] = Value(static_cast<std::int64_t>(count));
    }
    Value output = Value::make_object();
    output["success"] = Value(result.success);
    output["cancelled"] = Value(result.cancelled);
    output["error"] = Value(result.error);
    output["action"] = result.selected;
    output["sequence"] = Value(result.sequence);
    output["cache_preconditions"] = Value(result.cache_preconditions);
    output["root_candidates"] = Value(result.root_candidates);
    output["root_evaluations"] = Value(result.root_evaluations);
    output["score_milli"] = Value(result.score_milli);
    output["worst_score_milli"] = Value(result.worst_score_milli);
    output["nodes_expanded"] = Value(static_cast<std::int64_t>(result.nodes_expanded));
    output["planner_ms"] = Value(0.0);
    output["completed_depth"] = Value(static_cast<std::int64_t>(result.completed_depth));
    output["max_path_depth"] = Value(static_cast<std::int64_t>(result.max_path_depth));
    output["reply_completed_depth"] =
        Value(static_cast<std::int64_t>(result.reply_completed_depth));
    output["reply_depth_applicable"] = Value(result.reply_depth_applicable);
    output["completion_reason"] = Value(result.completion_reason);
    output["trajectory_hash"] = Value(result.trajectory_hash);
    output["belief_samples"] = Value(static_cast<std::int64_t>(result.belief_samples));
    output["belief_consensus"] = Value(static_cast<std::int64_t>(result.belief_consensus));
    output["root_signatures_attempted"] = strings_value(result.root_signatures_attempted);
    output["root_sample_counts"] = std::move(root_counts);
    output["belief_seed_hash"] = Value(result.belief_seed_hash);
    output["opponent_strategy_id"] = Value(result.opponent_strategy_id);
    output["layers_completed"] = Value(static_cast<std::int64_t>(result.layers_completed));
    output["reply_completion_reasons"] = strings_value(result.reply_completion_reasons);
    output["reply_completion_reason"] = Value(result.reply_completion_reason);
    output["requested_depth"] = Value(static_cast<std::int64_t>(requested_depth));
    output["reply_requested_depth"] = Value(static_cast<std::int64_t>(reply_depth));
    output["search_depth_applicable"] = Value(true);
    output["search_depth_requested"] = Value(static_cast<std::int64_t>(requested_depth));
    output["search_depth_reached"] = Value(static_cast<std::int64_t>(result.max_path_depth));
    output["search_depth_completed"] = Value(static_cast<std::int64_t>(result.completed_depth));
    output["search_depth_stop_reason"] = Value(result.completion_reason);
    output["native_determinization"] = Value(true);
    return output;
}

} // namespace

Value ChallengeController::configure(Value catalog, Value decks, Value strategies) {
    Value result = Value::make_object();
    if (!catalog.is_object() || catalog.as_object().empty() || !decks.is_object() ||
        decks.as_object().empty() || !strategies.is_object() || strategies.as_object().empty()) {
        configured_ = false;
        result["success"] = Value(false);
        result["error"] = Value("native_challenge_configuration_missing");
        return result;
    }
    catalog_ = std::move(catalog);
    decks_ = std::move(decks);
    strategies_ = std::move(strategies);
    strategy_catalog_ = std::make_shared<const DeckPolicyRegistry>(strategies_, catalog_);
    knowledge_ = std::make_shared<const planning::StrategicAnalyzer::Knowledge>(catalog_);
    memory_.configure(catalog_, strategy_catalog_);
    configured_ = strategy_catalog_->valid();
    const Value *profiles = strategies_.find("strategies");
    for (const auto &[key, deck] : decks_.as_object()) {
        if (strategy_catalog_->policy_for(key).specialized() &&
            (profiles == nullptr || !profiles->is_object() || profiles->find(key) == nullptr)) {
            configured_ = false;
        }
    }
    result["success"] = Value(configured_);
    result["error"] = Value(configured_ ? "" : "invalid_strategy_catalog");
    const Value *cards = catalog_.find("cards");
    result["card_count"] = Value(static_cast<std::int64_t>(cards != nullptr && cards->is_object()
                                                               ? cards->as_object().size()
                                                               : catalog_.as_object().size()));
    result["deck_count"] = Value(static_cast<std::int64_t>(decks_.as_object().size()));
    result["strategy_count"] = Value(static_cast<std::int64_t>(strategies_.as_object().size()));
    return result;
}

Value ChallengeController::decide_action(const Value &request, std::int64_t generation) {
    const auto decision_started = std::chrono::steady_clock::now();
    if (!configured_)
        return error_result("native_challenge_not_configured");
    if (generation <= cancelled_through_generation_.load(std::memory_order_acquire)) {
        return error_result("cancelled", true);
    }
    const Value actions = value_or(request, "actions", Value());
    const Value public_state =
        value_or(request, "public_snapshot", value_or(request, "state", Value()));
    const std::int32_t actor = static_cast<std::int32_t>(integer_field(request, "actor", -1));
    if (!actions.is_array()) {
        return error_result("native_challenge_root_actions_missing");
    }
    if (!public_state.is_object() || actor < 0 || actor > 1) {
        return error_result("invalid_runtime_state");
    }

    active_generation_.store(generation, std::memory_order_release);
    const ActiveRequest active_request{active_generation_};
    cancel_requested_.store(false, std::memory_order_release);
    if (generation <= cancelled_through_generation_.load(std::memory_order_acquire))
        return error_result("cancelled", true);
    const Value filtered_actions = memory_.filter_root_actions(request, public_state, actions);
    if (!filtered_actions.is_array() || filtered_actions.as_array().empty()) {
        return error_result("no_bounded_legal_action");
    }

    InformationSet information_set;
    std::string information_error;
    const Value public_history = value_or(request, "public_history", Value::make_array());
    if (!information_set.capture(
            public_state, actor, catalog_, decks_, filtered_actions, public_history,
            integer_field(request, "match_seed", integer_field(request, "seed", 0)),
            &information_error)) {
        return error_result(information_error.empty() ? "information_set_capture_failed"
                                                      : information_error);
    }
    const bool deck_inspection_memory_applied =
        memory_.apply_deck_inspection_memory(request, information_set);
    auto provider_owner = make_challenge_search_provider(catalog_, decks_, strategy_catalog_, actor,
                                                         &information_set, knowledge_);
    auto &provider = *provider_owner;
    const auto time_budget =
        std::clamp<std::int64_t>(integer_field(request, "time_budget_ms", 0), 0, 60000);
    provider.search_context()->budget =
        std::make_shared<DecisionBudget>(decision_started, time_budget, &cancel_requested_);
    provider.search_context()->memoization_enabled =
        bool_field(request, "internal_search_memoization", true);
    provider.search_context()->shortlist_enabled = true;
    const auto seed = static_cast<std::uint32_t>(integer_field(request, "seed", 1));
    const auto revision = integer_field(request, "revision", -1);
    const auto cache_key = memory_.turn_plan_cache_key(request, information_set);
    MatchMemory::PlanCacheUpdate cache_update;
    SearchResult plan;
    bool cache_hit = false;
    bool forced = filtered_actions.as_array().size() == 1;
    // This cheap legal incumbent is available even if optional analysis expires.
    plan.selected = filtered_actions.as_array().front();
    double prior = -std::numeric_limits<double>::infinity();
    for (const auto &action : filtered_actions.as_array()) {
        const double score = strategy_catalog_->action_score(public_state, actor, action) +
                             CardEvaluator::default_action_score_milli(action, catalog_) / 1000.0;
        if (score > prior || (score == prior && value_action_signature(action) <
                                                    value_action_signature(plan.selected))) {
            prior = score;
            plan.selected = action;
        }
    }
    provider.search_context()->set_incumbent(plan.selected);
    plan.success = true;
    plan.sequence = {plan.selected};
    plan.completion_reason = "legal_incumbent";
    auto position = provider.determinize(0, seed);
    if (!position)
        return error_result("determinization_failed");
    const auto precondition = provider.cache_precondition(*position, actor);
    if (!cache_key.empty()) {
        const Value cached = memory_.probe_cached_turn_action(cache_key, revision, filtered_actions,
                                                              precondition, actor, cache_update);
        if (cached.is_object() && !cached.as_object().empty()) {
            cache_hit = true;
            plan.selected = cached;
            plan.sequence = {cached};
            plan.completion_reason = "cache_hit";
        }
    }
    const Value *keys = public_state.find("public_deck_keys");
    const std::string deck =
        keys && keys->is_array() && static_cast<std::size_t>(actor) < keys->as_array().size()
            ? keys->as_array()[actor].string_or()
            : "";
    TurnPlannerConfig config;
    config.node_budget = static_cast<std::size_t>(
        std::clamp<std::int64_t>(integer_field(request, "node_budget", 192), 1, 4096));
    config.belief_samples = information_set.recommended_belief_samples(
        1 - actor, static_cast<std::size_t>(std::clamp<std::int64_t>(
                       integer_field(request, "belief_samples", 3), 1, 3)));
    config.shallow = !strategy_catalog_->policy_for(deck).specialized() ||
                     bool_field(request, "internal_evaluation_smoke");
#if defined(__ANDROID__)
    config.worker_count = 2;
#elif defined(_WIN32)
    config.worker_count = 3;
#endif
    if (bool_field(request, "internal_evaluation_batch") ||
        bool_field(request, "internal_evaluation_smoke"))
        config.worker_count = 1;
    provider.search_context()->worker_count = config.worker_count;
    if (!cache_hit && !forced && !provider.time_budget_exhausted()) {
        TurnPlanner planner(provider, config);
        auto searched = planner.decide(actor, seed, filtered_actions, &cancel_requested_);
        if (searched.cancelled)
            return error_result("cancelled", true);
        if (searched.success)
            plan = std::move(searched);
        else
            plan.nodes_expanded = searched.nodes_expanded;
        if (!provider.time_budget_exhausted() && plan.cache_preconditions.size() > 1)
            cache_update = memory_.prepare_turn_plan(cache_key, revision, plan);
    }
    if (forced) {
        plan.completion_reason = "forced_tactic";
        plan.cache_preconditions = {precondition};
    }
    if (provider.time_budget_exhausted() && !cache_hit) {
        plan.completion_reason = "time_budget_exhausted";
        plan.cache_preconditions.clear();
    }
    if (cancel_requested_.load(std::memory_order_acquire) ||
        generation <= cancelled_through_generation_.load(std::memory_order_acquire))
        return error_result("cancelled", true);
    memory_.commit_plan_cache_update(std::move(cache_update));
    memory_.record_action_cycle_selection(request, public_state, plan.selected);
    Value output = search_result_value(plan, forced || cache_hit ? 0 : config.max_depth,
                                       plan.reply_depth_applicable ? 6 : 0);
    output["native_turn_plan_cache_hit"] = Value(cache_hit);
    output["search_depth_applicable"] = Value(!forced && !cache_hit);
    output["forced_tactic"] = Value(forced ? "unique_legal_action" : "");
    output["policy_id"] = Value(strategy_catalog_->strategy_id(deck));
    output["policy_fallback"] = Value(!strategy_catalog_->policy_for(deck).specialized());
    output["plan_reason"] = Value(cache_hit ? "validated_continuation"
                                  : forced  ? "unique_legal_action"
                                            : "highest_policy_utility");
    output["plan_memory"] = Value(cache_hit || plan.cache_preconditions.size() > 1);
    output["planner_ms"] = Value(std::chrono::duration<double, std::milli>(
                                     std::chrono::steady_clock::now() - decision_started)
                                     .count());
    Value counters = provider.performance_counters();
    counters["root_actions_input"] = Value(static_cast<std::int64_t>(actions.as_array().size()));
    counters["root_actions_effective"] =
        Value(static_cast<std::int64_t>(filtered_actions.as_array().size()));
    counters["root_actions_filtered"] = Value(
        static_cast<std::int64_t>(actions.as_array().size() - filtered_actions.as_array().size()));
    counters["search_worker_count"] = Value(static_cast<std::int64_t>(config.worker_count));
    counters["known_opponent_hand_count"] =
        Value(static_cast<std::int64_t>(information_set.known_hand(1 - actor).size()));
    counters["unknown_opponent_hand_count"] =
        Value(static_cast<std::int64_t>(information_set.unknown_hand_count(1 - actor)));
    counters["deck_inspection_memory_applied"] = Value(deck_inspection_memory_applied);
    counters["known_prize_identity_count"] =
        Value(static_cast<std::int64_t>(information_set.known_prizes(actor).size()));
    output["native_performance_counters"] = std::move(counters);
    if (bool_field(request, "internal_full_diagnostics") && !provider.search_stopped()) {
        planning::StrategicAnalyzer analyzer(catalog_, decks_, *strategy_catalog_, knowledge_);
        analyzer.set_search_context(provider.search_context());
        planning::BeliefTracker tracker(catalog_, *strategy_catalog_);
        const auto facts = provider.evaluate([&] {
            return analyzer.analyze(*position,
                                    tracker.summarize(information_set, public_state, actor), actor);
        });
        if (facts)
            output["position_facts"] = planning::strategic_facts_value(*facts.value);
    }
    return output;
}

Value ChallengeController::decide_choice(const Value &request, std::int64_t generation) {
    const auto decision_started = std::chrono::steady_clock::now();
    if (!configured_ || strategy_catalog_ == nullptr) {
        Value result = error_result("native_challenge_not_configured");
        result["kind"] = Value("choice");
        return result;
    }
    if (generation <= cancelled_through_generation_.load(std::memory_order_acquire)) {
        Value result = error_result("cancelled", true);
        result["kind"] = Value("choice");
        return result;
    }
    const Value state = value_or(request, "state", Value());
    const Value choice = value_or(request, "choice", Value());
    if (!state.is_object() || !choice.is_object()) {
        Value result = error_result("invalid_choice_request");
        result["kind"] = Value("choice");
        return result;
    }
    const std::int64_t revision = integer_field(request, "revision", -1);
    if (revision < 0 || revision != value_integer_field(state, "revision", -2) ||
        revision != value_integer_field(choice, "base_revision", -3)) {
        Value result = error_result("stale_choice_revision");
        result["kind"] = Value("choice");
        return result;
    }
    const std::int32_t actor = static_cast<std::int32_t>(
        value_integer_field(choice, "player", integer_field(request, "actor", -1)));
    if (actor < 0 || actor > 1) {
        Value result = error_result("invalid_actor");
        result["kind"] = Value("choice");
        return result;
    }

    active_generation_.store(generation, std::memory_order_release);
    cancel_requested_.store(false, std::memory_order_release);
    if (generation <= cancelled_through_generation_.load(std::memory_order_acquire))
        return error_result("cancelled", true);
    InformationSet information_set;
    std::string error;
    const Value public_history = value_or(request, "public_history", Value::make_array());
    if (!information_set.capture(
            state, actor, catalog_, decks_, Value::make_array(), public_history,
            integer_field(request, "match_seed", integer_field(request, "seed", 0)), &error)) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result(error.empty() ? "choice_information_set_failed" : error);
        result["kind"] = Value("choice");
        return result;
    }
    const bool deck_inspection_enabled = bool_field(request, "use_deck_inspection", true);
    const bool deck_inspection_memory_applied =
        memory_.apply_deck_inspection_memory(request, information_set);
    bool deck_inspection_applied = false;
    const Value *presentation = choice.find("presentation");
    const Value *browse_refs = presentation != nullptr && presentation->is_object()
                                   ? presentation->find("browse_card_refs")
                                   : nullptr;
    if (deck_inspection_enabled && browse_refs != nullptr) {
        if (!information_set.apply_deck_inspection(choice, &error)) {
            active_generation_.store(0, std::memory_order_release);
            Value result = error_result(error.empty() ? "invalid_deck_inspection" : error);
            result["kind"] = Value("choice");
            return result;
        }
        deck_inspection_applied = true;
    }
    const std::uint32_t seed = static_cast<std::uint32_t>(integer_field(request, "seed", 17));
    const Value sampled = information_set.sample_state(seed);
    RulesSession position(catalog_);
    if (!sampled.is_object() || !position.restore(sampled, seed, &error)) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result(error.empty() ? "choice_determinization_failed" : error);
        result["kind"] = Value("choice");
        return result;
    }
    auto provider = make_challenge_search_provider(catalog_, decks_, strategy_catalog_, actor,
                                                   &information_set, knowledge_);
    const auto time_budget =
        std::clamp<std::int64_t>(integer_field(request, "time_budget_ms", 0), 0, 60000);
    provider->search_context()->budget =
        std::make_shared<DecisionBudget>(decision_started, time_budget, &cancel_requested_);
    provider->search_context()->memoization_enabled =
        bool_field(request, "internal_search_memoization", true);
    Value response;
    const Value *options = choice.find("options");
    if (options != nullptr && options->is_array() && options->as_array().empty()) {
        const bool cancelled =
            value_integer_field(choice, "min_select", 0) <= 0 && bool_field(choice, "can_cancel");
        response = Value(Value::Object{
            {"request_id", Value(value_string_field(choice, "request_id"))},
            {"option_ids", Value::make_array()},
            {"cancelled", Value(cancelled)},
        });
    } else if (!provider->select_choice(position, choice, response)) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result("choice_response_constraints_unsatisfied");
        result["kind"] = Value("choice");
        result["native_performance_counters"] = provider->performance_counters();
        return result;
    }
    if (cancel_requested_.load(std::memory_order_acquire) ||
        generation <= cancelled_through_generation_.load(std::memory_order_acquire)) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result("cancelled", true);
        result["kind"] = Value("choice");
        return result;
    }
    if (deck_inspection_applied)
        memory_.remember_deck_inspection(request, information_set);
    active_generation_.store(0, std::memory_order_release);
    const Value *keys = position.search_state().find("public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array() &&
                                         static_cast<std::size_t>(actor) < keys->as_array().size()
                                     ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
                                     : std::string{};
    Value output = Value::make_object();
    output["success"] = Value(true);
    output["kind"] = Value("choice");
    output["error"] = Value("");
    output["choice_response"] = response;
    output["simulations"] = Value(0);
    output["strategy_id"] = Value(strategy_catalog_->strategy_id(deck_key));
    output["strategy_version"] = Value(strategy_catalog_->strategy_version(deck_key));
    output["strategy_hash"] = Value(strategy_catalog_->strategy_content_hash(deck_key));
    output["engine_id"] = Value(string_field(request, "engine", "deck_planner_v1"));
    output["planner"] = output["engine_id"];
    output["completion_reason"] =
        Value(provider->time_budget_exhausted() ? "time_budget_exhausted" : "choice_selected");
    output["plan_reason"] = Value("policy_resource_selection");
    output["decision_origin"] = Value("choice_policy");
    output["failure_stage"] = Value("");
    output["type_matchups"] = Value(bool_field(state, "apply_type_matchups"));
    output["revision"] = Value(revision);
    output["request_id"] = value_or(request, "request_id", Value(""));
    output["policy_id"] = Value(strategy_catalog_->strategy_id(deck_key));
    output["policy_version"] = Value(strategy_catalog_->strategy_version(deck_key));
    output["policy_fallback"] = Value(!strategy_catalog_->policy_for(deck_key).specialized());
    output["turn_goal"] = strategy_catalog_->turn_goals(state, actor);
    output["heuristic_variant"] = Value("deck_policy_v1");
    Value counters = provider->performance_counters();
    counters["deck_inspection_knowledge_enabled"] = Value(deck_inspection_enabled);
    counters["deck_inspection_applied"] = Value(deck_inspection_applied);
    counters["deck_inspection_memory_applied"] = Value(deck_inspection_memory_applied);
    counters["known_prize_identity_count"] =
        Value(information_set.has_exact_hidden_zones(actor)
                  ? static_cast<std::int64_t>(information_set.known_prizes(actor).size())
                  : 0);
    output["deck_inspection_applied"] = Value(deck_inspection_applied);
    output["deck_inspection_memory_applied"] = Value(deck_inspection_memory_applied);
    output["native_performance_counters"] = std::move(counters);
    return output;
}

Value ChallengeController::decide(const Value &request, std::int64_t generation) {
    const auto started = std::chrono::steady_clock::now();
    if (!request.is_object())
        return error_result("invalid_request");
    if (string_field(request, "engine", DECK_PLANNER_ENGINE_ID) != DECK_PLANNER_ENGINE_ID)
        return error_result("unsupported_engine");
    const std::string kind = string_field(request, "kind", "action");
    if (kind != "action" && kind != "choice")
        return error_result("invalid_request_kind");
    if (string_field(request, "kind", "action") == "choice") {
        Value result = decide_choice(request, generation);
        result["elapsed_ms"] = Value(
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started)
                .count());
        return result;
    }
    Value planner = decide_action(request, generation);
    const double elapsed_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started)
            .count();
    if (!bool_field(planner, "success")) {
        planner["kind"] = Value("action");
        planner["decision_origin"] = Value("failure");
        planner["failure_stage"] = Value("search");
        planner["revision"] = value_or(request, "revision", Value(-1));
        planner["request_id"] = value_or(request, "request_id", Value(""));
        planner["elapsed_ms"] = Value(elapsed_ms);
        planner["heuristic_variant"] = Value("deck_policy_v1");
        return planner;
    }
    const Value selected = value_or(planner, "action", Value());
    if (!selected.is_object()) {
        planner["success"] = Value(false);
        planner["kind"] = Value("action");
        planner["error"] = Value("native_challenge_missing_action");
        planner["decision_origin"] = Value("failure");
        planner["failure_stage"] = Value("search");
        return planner;
    }
    const Value sequence = value_or(planner, "sequence", Value::make_array());
    Value preconditions = value_or(planner, "cache_preconditions", Value::make_array());
    const bool cache_hit = bool_field(planner, "native_turn_plan_cache_hit");
    const bool cache_guarded = cache_hit && !string_field(planner, "forced_tactic").empty();
    Value turn_plan = Value::make_array();
    if ((!cache_hit || cache_guarded) && sequence.is_array() && preconditions.is_array()) {
        const std::size_t count =
            std::min(sequence.as_array().size(), preconditions.as_array().size());
        for (std::size_t index = 0; index < count; ++index) {
            turn_plan.as_array().push_back(
                action_intent(sequence.as_array()[index], &preconditions.as_array()[index]));
        }
    }
    Value semantic_planner = planner;
    const std::string effective_engine = string_field(request, "engine", "deck_planner_v1");
    semantic_planner["engine_id"] = Value(effective_engine);
    semantic_planner["turn_plan"] = turn_plan;
    if (cache_hit && !cache_guarded) {
        semantic_planner["cache_preconditions"] = Value::make_array();
    }
    const std::string semantic_completion =
        value_string_field(semantic_planner, "completion_reason");
    if (semantic_completion == "forced_tactic" || semantic_completion == "cache_hit") {
        semantic_planner["nodes_expanded"] = Value(0);
    }
    const std::string semantic_hash =
        traditional_decision_semantic_hash(selected, semantic_planner, turn_plan);
    const std::int32_t actor = static_cast<std::int32_t>(integer_field(request, "actor", -1));
    const Value state =
        value_or(request, "public_snapshot", value_or(request, "state", Value::make_object()));
    const Value *keys = state.find("public_deck_keys");
    const std::string inferred_deck =
        keys != nullptr && keys->is_array() && actor >= 0 &&
                static_cast<std::size_t>(actor) < keys->as_array().size()
            ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
            : std::string{};
    const std::string requested_deck = string_field(request, "deck_key");
    const std::string deck_key = requested_deck.empty() ? inferred_deck : requested_deck;
    const std::string completion = string_field(planner, "completion_reason");
    const std::string forced = string_field(planner, "forced_tactic");
    const std::int64_t score_milli = integer_field(planner, "score_milli", 0);

    Value output = planner;
    output["success"] = Value(true);
    output["kind"] = Value("action");
    output["engine_id"] = Value(effective_engine);
    output["simulations"] = value_or(planner, "nodes_expanded", Value(0));
    output["decision_semantic_hash"] = Value(semantic_hash);
    output["planner"] = output["engine_id"];
    output["decision_origin"] =
        Value(cache_hit                                            ? "cache"
              : (completion == "forced_tactic" || !forced.empty()) ? "forced_tactic"
                                                                   : "search");
    output["failure_stage"] = Value("");
    output["planner_score"] = Value(static_cast<double>(score_milli) / 1000.0);
    output["planner_score_milli"] = Value(score_milli);
    output["turn_plan_size"] = Value(static_cast<std::int64_t>(turn_plan.as_array().size()));
    output["turn_plan_cache_hit"] = Value(cache_hit);
    output["planner_error"] = value_or(planner, "error", Value(""));
    output["strategy_id"] =
        Value(strategy_catalog_ == nullptr ? "generic_balanced_v1"
                                           : strategy_catalog_->strategy_id(deck_key));
    output["strategy_version"] =
        Value(strategy_catalog_ == nullptr ? 0 : strategy_catalog_->strategy_version(deck_key));
    output["strategy_hash"] = Value(
        strategy_catalog_ == nullptr ? "" : strategy_catalog_->strategy_content_hash(deck_key));
    output["turn_goal"] = strategy_catalog_ == nullptr
                              ? Value::make_object()
                              : strategy_catalog_->turn_goals(state, actor);
    output["type_matchups"] = Value(bool_field(state, "apply_type_matchups"));
    output["revision"] = value_or(request, "revision", Value(-1));
    output["request_id"] = value_or(request, "request_id", Value(""));
    output["elapsed_ms"] = Value(elapsed_ms);
    output["heuristic_variant"] = Value("deck_policy_v1");
    return output;
}

void ChallengeController::cancel(std::int64_t generation) noexcept {
    std::int64_t observed = cancelled_through_generation_.load(std::memory_order_relaxed);
    while (observed < generation &&
           !cancelled_through_generation_.compare_exchange_weak(
               observed, generation, std::memory_order_release, std::memory_order_relaxed)) {
    }
    const std::int64_t active = active_generation_.load(std::memory_order_acquire);
    if (active > 0 && active <= generation) {
        cancel_requested_.store(true, std::memory_order_release);
    }
}

void ChallengeController::reset_match(const std::string &match_instance_id) {
    if (active_match_instance_id_ == match_instance_id)
        return;
    active_match_instance_id_ = match_instance_id;
    memory_.reset();
}

Value ChallengeController::get_contract() const {
#if defined(__ANDROID__)
    constexpr std::int64_t workers = 2;
#elif defined(_WIN32)
    constexpr std::int64_t workers = 3;
#else
    constexpr std::int64_t workers = 1;
#endif
    return Value(Value::Object{
        {"schema", Value("ptcg.native_challenge_ai/1")},
        {"engine_id", Value(DECK_PLANNER_ENGINE_ID)},
        {"supported_engines", Value(Value::Array{Value(DECK_PLANNER_ENGINE_ID)})},
        {"search_version", Value(1)},
        {"action_schema_version", Value(4)},
        {"choice_view_schema_version", Value(2)},
        {"snapshot_schema_version", Value(3)},
        {"max_depth", Value(10)},
        {"belief_samples", Value(3)},
        {"reply_depth", Value(6)},
        {"search_worker_count", Value(workers)},
        {"parallel_belief_samples", Value(workers > 1)},
        {"atomic_generation_cancellation", Value(true)},
        {"callback_free", Value(true)},
        {"typed_authoritative_core", Value(true)},
        {"native_information_set", Value(true)},
        {"native_action_policy", Value(true)},
        {"native_position_evaluator", Value(true)},
        {"native_strategy_catalog", Value(true)},
        {"native_choice_policy", Value(true)},
        {"native_no_progress_loop_guard", Value(true)},
        {"native_turn_plan_cache", Value(true)},
        {"owner_deck_inspection_knowledge", Value(true)},
        {"deck_inspection_prize_memory", Value(true)},
        {"shared_decision_budget", Value(true)},
        {"performance_counters", Value(true)},
        {"deck_policies", Value(10)},
        {"generic_policy", Value(true)},
        {"production_ready", Value(true)},
    });
}
} // namespace ptcg::ai

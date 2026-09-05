#include "challenge_controller.hpp"

#include "challenge_search_provider.hpp"
#include "challenge_search_support.hpp"
#include "ptcg_traditional_value.hpp"
#include "ptcg_traditional_infoset.hpp"
#include "ptcg_traditional_mandatory.hpp"
#include "ptcg_traditional_policy.hpp"

#include <algorithm>
#include <chrono>
#include <functional>
#include <limits>
#include <optional>
#include <utility>

namespace ptcg::ai {
namespace {

using namespace challenge;

using traditional_value::field;
using traditional_value::string_field;
using traditional_value::integer_field;
using traditional_value::bool_field;

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
    for (const std::string &value : values) result.emplace_back(value);
    return Value(std::move(result));
}

Value search_result_value(
    const TraditionalSearchResult &result,
    std::size_t requested_depth,
    std::size_t reply_depth
) {
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
    output["score_milli"] = Value(result.score_milli);
    output["worst_score_milli"] = Value(result.worst_score_milli);
    output["nodes_expanded"] = Value(static_cast<std::int64_t>(
        result.nodes_expanded));
    output["planner_ms"] = Value(0.0);
    output["completed_depth"] = Value(static_cast<std::int64_t>(
        result.completed_depth));
    output["max_path_depth"] = Value(static_cast<std::int64_t>(
        result.max_path_depth));
    output["reply_completed_depth"] = Value(static_cast<std::int64_t>(
        result.reply_completed_depth));
    output["reply_depth_applicable"] = Value(result.reply_depth_applicable);
    output["completion_reason"] = Value(result.completion_reason);
    output["trajectory_hash"] = Value(result.trajectory_hash);
    output["trajectory_events"] = Value(static_cast<std::int64_t>(
        result.trajectory_events));
    output["belief_samples"] = Value(static_cast<std::int64_t>(
        result.belief_samples));
    output["belief_consensus"] = Value(static_cast<std::int64_t>(
        result.belief_consensus));
    output["root_signatures_attempted"] = strings_value(
        result.root_signatures_attempted);
    output["root_sample_counts"] = std::move(root_counts);
    output["belief_seed_hash"] = Value(result.belief_seed_hash);
    output["opponent_strategy_id"] = Value(result.opponent_strategy_id);
    output["layers_completed"] = Value(static_cast<std::int64_t>(
        result.layers_completed));
    output["reply_completion_reasons"] = strings_value(
        result.reply_completion_reasons);
    output["reply_completion_reason"] = Value(result.reply_completion_reason);
    output["requested_depth"] = Value(static_cast<std::int64_t>(requested_depth));
    output["reply_requested_depth"] = Value(static_cast<std::int64_t>(
        reply_depth));
    output["search_depth_applicable"] = Value(true);
    output["search_depth_requested"] = Value(static_cast<std::int64_t>(
        requested_depth));
    output["search_depth_reached"] = Value(static_cast<std::int64_t>(
        result.max_path_depth));
    output["search_depth_completed"] = Value(static_cast<std::int64_t>(
        result.completed_depth));
    output["search_depth_stop_reason"] = Value(result.completion_reason);
    output["native_determinization"] = Value(true);
    return output;
}

} // namespace

Value ChallengeController::configure(
    Value catalog,
    Value decks,
    Value strategies
) {
    Value result = Value::make_object();
    if (!catalog.is_object() || catalog.as_object().empty()
        || !decks.is_object() || decks.as_object().empty()
        || !strategies.is_object() || strategies.as_object().empty()) {
        configured_ = false;
        result["success"] = Value(false);
        result["error"] = Value("native_challenge_configuration_missing");
        return result;
    }
    catalog_ = std::move(catalog);
    decks_ = std::move(decks);
    strategies_ = std::move(strategies);
    strategy_catalog_ = std::make_unique<TraditionalStrategyCatalog>(
        strategies_, catalog_);
    trusted_evaluator_ = std::make_unique<TraditionalTrustedEvaluator>(
        catalog_, decks_, *strategy_catalog_);
    strategic_planner_ = std::make_unique<
        planner_v3::StrategicIntentPlanner>(
            catalog_, decks_, *strategy_catalog_);
    configured_ = strategy_catalog_->valid();
    result["success"] = Value(configured_);
    result["error"] = Value(configured_ ? "" : "invalid_strategy_catalog");
    const Value *cards = catalog_.find("cards");
    result["card_count"] = Value(static_cast<std::int64_t>(
        cards != nullptr && cards->is_object()
            ? cards->as_object().size() : catalog_.as_object().size()));
    result["deck_count"] = Value(static_cast<std::int64_t>(
        decks_.as_object().size()));
    result["strategy_count"] = Value(static_cast<std::int64_t>(
        strategies_.as_object().size()));
    return result;
}

Value ChallengeController::filter_root_actions(
    const Value &request,
    const Value &public_state,
    const Value &actions
) {
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(request, "actor", -1));
    Value filtered = filter_exhausted_repeatable_abilities(
        public_state, actor, actions, catalog_);
    const std::string engine = string_field(request, "engine", "turn_beam_v2");
    if (!filtered.is_array()
        || (engine != "turn_beam_v2"
            && engine != planner_v3::STRATEGIC_INTENT_ENGINE_ID)) {
        return filtered;
    }
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty()) return filtered;
    const std::string ledger_key = match_id + "|" + std::to_string(actor)
        + "|" + std::to_string(value_integer_field(
            public_state, "turn_number", 0));
    const auto found = action_cycle_ledger_.find(ledger_key);
    if (found == action_cycle_ledger_.end()) return filtered;
    ActionCycleEntry &entry = found->second;
    const std::string fingerprint = action_cycle_state_fingerprint(public_state);
    const std::int64_t revision = integer_field(
        request, "revision", value_integer_field(public_state, "revision", 0));
    if (entry.last_state_fingerprint == fingerprint
        && revision > entry.last_revision
        && !entry.last_action_signature.empty()) {
        entry.blocked_by_state[fingerprint].insert(entry.last_action_signature);
    }
    const auto blocked = entry.blocked_by_state.find(fingerprint);
    if (blocked == entry.blocked_by_state.end() || blocked->second.empty()) {
        return filtered;
    }
    Value::Array result;
    Value::Array terminal;
    for (const Value &action : filtered.as_array()) {
        if (traditional_action_is_terminal(action)) terminal.push_back(action);
        if (blocked->second.count(value_action_signature(action)) == 0) {
            result.push_back(action);
        }
    }
    if (!result.empty()) return Value(std::move(result));
    if (!terminal.empty()) return Value(std::move(terminal));
    return filtered;
}

bool ChallengeController::apply_deck_inspection_memory(
    const Value &request,
    TraditionalInformationSet &information_set
) {
    if (!bool_field(request, "use_deck_inspection", true)
        || !information_set.valid()) {
        return false;
    }
    const std::int32_t actor = information_set.perspective();
    if (actor < 0 || actor > 1) return false;
    DeckInspectionMemory &memory = deck_inspection_memory_[
        static_cast<std::size_t>(actor)];
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty() || !memory.valid
        || memory.match_instance_id != match_id) return false;
    std::string ignored;
    if (information_set.apply_known_prizes(memory.prize_cards, &ignored)) {
        return true;
    }
    // Prize count or hidden-zone composition changed.  Forget rather than
    // carrying an inference beyond the point where it is provably exact.
    memory = DeckInspectionMemory{};
    return false;
}

void ChallengeController::remember_deck_inspection(
    const Value &request,
    const TraditionalInformationSet &information_set
) {
    const std::int32_t actor = information_set.perspective();
    const std::string match_id = string_field(request, "match_instance_id");
    if (actor < 0 || actor > 1
        || match_id.empty()
        || !information_set.has_exact_hidden_zones(actor)) {
        return;
    }
    DeckInspectionMemory &memory = deck_inspection_memory_[
        static_cast<std::size_t>(actor)];
    memory.prize_cards = information_set.known_prizes(actor);
    memory.match_instance_id = match_id;
    memory.valid = true;
}

void ChallengeController::record_action_cycle_selection(
    const Value &request,
    const Value &public_state,
    const Value &action,
    bool commit_shadow
) {
    if (bool_field(request, "shadow_probe") && !commit_shadow) return;
    const std::string engine = string_field(request, "engine", "turn_beam_v2");
    if (engine != "turn_beam_v2"
        && engine != planner_v3::STRATEGIC_INTENT_ENGINE_ID) return;
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty() || !action.is_object()) return;
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(request, "actor", -1));
    const std::string ledger_key = match_id + "|" + std::to_string(actor)
        + "|" + std::to_string(value_integer_field(
            public_state, "turn_number", 0));
    const bool inserted = action_cycle_ledger_.find(ledger_key)
        == action_cycle_ledger_.end();
    ActionCycleEntry &entry = action_cycle_ledger_[ledger_key];
    entry.last_state_fingerprint = action_cycle_state_fingerprint(public_state);
    entry.last_action_signature = value_action_signature(action);
    entry.last_revision = integer_field(
        request, "revision", value_integer_field(public_state, "revision", 0));
    if (inserted) action_cycle_order_.push_back(ledger_key);
    while (action_cycle_order_.size() > 64) {
        action_cycle_ledger_.erase(action_cycle_order_.front());
        action_cycle_order_.erase(action_cycle_order_.begin());
    }
}

std::string ChallengeController::turn_plan_cache_key(
    const Value &request,
    const TraditionalInformationSet &information_set
) const {
    const std::string match_id = string_field(request, "match_instance_id");
    if (match_id.empty() || !information_set.valid()) return {};
    const std::int32_t actor = information_set.perspective();
    const Value &state = information_set.public_snapshot();
    const Value *keys = state.find("public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && actor >= 0 && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    return match_id + "|" + string_field(request, "engine", "turn_beam_v2")
        + "|" + std::to_string(actor) + "|"
        + std::to_string(value_integer_field(state, "turn_number", 0))
        + "|" + deck_key;
}

Value ChallengeController::probe_cached_turn_action(
    const std::string &cache_key,
    std::int64_t revision,
    const Value &actions,
    const Value &precondition,
    std::int32_t actor,
    PlanCacheUpdate &update
) const {
    const auto found = turn_plan_cache_.find(cache_key);
    if (cache_key.empty() || found == turn_plan_cache_.end()) return {};
    update = {cache_key, std::nullopt};
    const CachedPlanEntry &entry = found->second;
    if (revision <= entry.last_revision || entry.steps.empty()
        || !actions.is_array() || !precondition.is_object()) return {};
    const CachedPlanStep &next = entry.steps.front();
    const auto same = [&next, &precondition](const char *key) {
        return value_string_field(next.precondition, key)
            == value_string_field(precondition, key);
    };
    if (!same("expected_public_fingerprint")
        || !same("expected_known_hand_fingerprint")
        || !same("expected_known_prize_fingerprint")
        || value_integer_field(next.precondition, "expected_actor", -1)
            != value_integer_field(precondition, "expected_actor", -1)
        || !same("expected_phase")
        || value_integer_field(next.action, "actor", -1) != actor) return {};
    const Value *matched = find_action_by_signature(actions, next.signature);
    if (matched == nullptr) return {};
    if (entry.steps.size() > 1) {
        update.entry = CachedPlanEntry{
            std::vector<CachedPlanStep>(entry.steps.begin() + 1, entry.steps.end()),
            revision};
    }
    return *matched;
}

ChallengeController::PlanCacheUpdate ChallengeController::prepare_turn_plan(
    const std::string &cache_key,
    std::int64_t revision,
    const TraditionalSearchResult &result
) const {
    if (cache_key.empty() || !result.success || !result.selected.is_object()) return {};
    PlanCacheUpdate update{cache_key, std::nullopt};
    if (traditional_action_is_terminal(result.selected)) return update;
    const std::string selected_signature = value_action_signature(result.selected);
    bool removed_selected = false;
    std::vector<CachedPlanStep> steps;
    const std::size_t count = std::min(
        result.sequence.size(), result.cache_preconditions.size());
    for (std::size_t index = 0; index < count; ++index) {
        const std::string signature = value_action_signature(result.sequence[index]);
        if (!removed_selected && signature == selected_signature) {
            removed_selected = true;
            continue;
        }
        steps.push_back({
            result.sequence[index], result.cache_preconditions[index], signature});
    }
    if (!steps.empty()) update.entry = CachedPlanEntry{std::move(steps), revision};
    return update;
}

void ChallengeController::commit_plan_cache_update(PlanCacheUpdate update) {
    if (update.key.empty()) return;
    if (!update.entry.has_value()) {
        turn_plan_cache_.erase(update.key);
        turn_plan_cache_order_.erase(std::remove(
            turn_plan_cache_order_.begin(), turn_plan_cache_order_.end(), update.key),
            turn_plan_cache_order_.end());
        return;
    }
    if (turn_plan_cache_.find(update.key) == turn_plan_cache_.end()) {
        turn_plan_cache_order_.push_back(update.key);
    }
    turn_plan_cache_[update.key] = std::move(*update.entry);
    while (turn_plan_cache_order_.size() > 8) {
        turn_plan_cache_.erase(turn_plan_cache_order_.front());
        turn_plan_cache_order_.erase(turn_plan_cache_order_.begin());
    }
}

Value ChallengeController::decide_action(
    const Value &request,
    std::int64_t generation
) {
    if (!configured_) return error_result("native_challenge_not_configured");
    if (generation <= cancelled_through_generation_.load(
            std::memory_order_acquire)) {
        return error_result("cancelled", true);
    }
    const Value actions = value_or(request, "actions", Value());
    const Value public_state = value_or(
        request, "public_snapshot", value_or(request, "state", Value()));
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(request, "actor", -1));
    if (!actions.is_array()) {
        return error_result("native_challenge_root_actions_missing");
    }
    if (!public_state.is_object() || actor < 0 || actor > 1) {
        return error_result("invalid_runtime_state");
    }

    active_generation_.store(generation, std::memory_order_release);
    const ActiveRequest active_request{active_generation_};
    cancel_requested_.store(false, std::memory_order_release);
    const Value filtered_actions = filter_root_actions(
        request, public_state, actions);
    if (!filtered_actions.is_array() || filtered_actions.as_array().empty()) {
        return error_result("no_bounded_legal_action");
    }

    TraditionalInformationSet information_set;
    std::string information_error;
    const Value public_history = value_or(
        request, "public_history", Value::make_array());
    if (!information_set.capture(
        public_state,
        actor,
        catalog_,
        decks_,
        filtered_actions,
        public_history,
        integer_field(request, "match_seed", integer_field(request, "seed", 0)),
        &information_error
    )) {
        return error_result(information_error.empty()
            ? "information_set_capture_failed" : information_error);
    }
    // Exact owner deck/prize identities are authoritative for real search
    // choices. Most deck plans also benefit from the exact split during
    // action search, but the Psychic discard/engine plan is measurably more
    // robust when its fixed rollout budget continues to sample hidden draws.
    // An explicit request override remains available for evaluation.
    bool default_deck_inspection_action_search = true;
    const Value *public_deck_keys = public_state.find("public_deck_keys");
    if (public_deck_keys != nullptr && public_deck_keys->is_array()
        && actor >= 0
        && static_cast<std::size_t>(actor)
            < public_deck_keys->as_array().size()) {
        default_deck_inspection_action_search =
            public_deck_keys->as_array()[static_cast<std::size_t>(actor)]
                .string_or() != "psychic";
    }
    const bool deck_inspection_action_search_enabled = bool_field(
        request, "use_deck_inspection_action_search",
        default_deck_inspection_action_search);
    const bool deck_inspection_memory_applied =
        deck_inspection_action_search_enabled
        && apply_deck_inspection_memory(request, information_set);

    auto provider_owner = make_challenge_search_provider(
        catalog_, decks_, strategies_, actor, &information_set,
        bool_field(request, "use_strategy_optimization", true));
    ChallengeSearchProvider &provider = *provider_owner;
    const std::int32_t opponent = 1 - actor;
    const std::size_t requested_belief_samples = static_cast<std::size_t>(
        std::max<std::int64_t>(1, std::min<std::int64_t>(
            3, integer_field(request, "belief_samples", 3))));
    const std::size_t adaptive_belief_samples =
        information_set.recommended_belief_samples(
            opponent, requested_belief_samples);
#if defined(__ANDROID__)
    constexpr std::size_t platform_search_workers = 2;
#elif defined(_WIN32)
    constexpr std::size_t platform_search_workers = 3;
#else
    constexpr std::size_t platform_search_workers = 1;
#endif
    const bool evaluation_request = bool_field(request, "internal_evaluation_batch")
        || bool_field(request, "internal_evaluation_smoke");
    const std::size_t search_worker_count = evaluation_request
        ? 1 : platform_search_workers;
    const auto performance = [&]() {
        Value counters = provider.performance_counters();
        counters["root_actions_input"] = Value(static_cast<std::int64_t>(
            actions.as_array().size()));
        counters["root_actions_effective"] = Value(static_cast<std::int64_t>(
            filtered_actions.as_array().size()));
        counters["root_actions_filtered"] = Value(static_cast<std::int64_t>(
            actions.as_array().size() - filtered_actions.as_array().size()));
        counters["search_worker_count"] = Value(static_cast<std::int64_t>(
            search_worker_count));
        counters["known_opponent_hand_count"] = Value(
            static_cast<std::int64_t>(information_set.known_hand(opponent).size()));
        counters["unknown_opponent_hand_count"] = Value(
            static_cast<std::int64_t>(information_set.unknown_hand_count(opponent)));
        counters["belief_samples_requested"] = Value(
            static_cast<std::int64_t>(requested_belief_samples));
        counters["belief_samples_effective"] = Value(
            static_cast<std::int64_t>(adaptive_belief_samples));
        counters["deck_inspection_knowledge_enabled"] = Value(
            bool_field(request, "use_deck_inspection", true));
        counters["deck_inspection_action_search_enabled"] = Value(
            deck_inspection_action_search_enabled);
        counters["deck_inspection_memory_applied"] = Value(
            deck_inspection_memory_applied);
        counters["known_prize_identity_count"] = Value(
            information_set.has_exact_hidden_zones(actor)
                ? static_cast<std::int64_t>(
                    information_set.known_prizes(actor).size())
                : 0);
        return counters;
    };

    const bool shadow_probe = bool_field(request, "shadow_probe");
    const std::string cache_key = shadow_probe
        ? std::string{} : turn_plan_cache_key(request, information_set);
    const std::int64_t revision = integer_field(
        request, "revision", value_integer_field(public_state, "revision", 0));
    std::uint64_t mandatory_nodes = 0;
    std::string mandatory_reason = "skipped";

    const bool strategic_engine = string_field(request, "engine", "turn_beam_v2")
        == planner_v3::STRATEGIC_INTENT_ENGINE_ID && strategic_planner_ != nullptr;
    PlanCacheUpdate legacy_update;
    const auto run_legacy = [&]() -> Value {
        Value legacy_request = request;
        legacy_request["engine"] = Value("turn_beam_v2");
        const std::string cache_key = shadow_probe && !strategic_engine
            ? std::string{} : turn_plan_cache_key(legacy_request, information_set);
        if (!bool_field(request, "skip_mandatory")
            && strategy_catalog_ != nullptr && trusted_evaluator_ != nullptr) {
            const std::uint32_t mandatory_seed = static_cast<std::uint32_t>(
                integer_field(request, "seed", 1));
            const Value sampled = information_set.sample_state(mandatory_seed);
            RulesSession mandatory_position(catalog_);
            std::string restore_error;
            if (!sampled.is_object() || !mandatory_position.restore(
                    sampled, mandatory_seed, &restore_error)) {
                return error_result(restore_error.empty()
                    ? "native_mandatory_determinization_failed" : restore_error);
            }

            TraditionalMandatoryResult forced;
            const Value &mandatory_state = mandatory_position.search_state();
            const bool setup_public_policy =
                value_string_field(mandatory_state, "phase") == "SETUP"
                && value_string_field(mandatory_state, "setup_stage") != "COMPLETE"
                && filtered_actions.as_array().size() > 1;
            bool cache_hit = false;
            bool cache_guarded = false;
            if (setup_public_policy) {
                const auto ranked = provider.ranked_actions(
                    mandatory_position, actor, filtered_actions,
                    filtered_actions.as_array().size());
                if (ranked.empty()) {
                    return error_result("no_ranked_setup_action");
                }
                forced.resolved = true;
                forced.action = ranked.front().action;
                forced.reason = "setup_public_policy";
            } else {
                const TraditionalMandatoryTactics tactics(
                    catalog_, *strategy_catalog_, *trusted_evaluator_);
                forced = tactics.resolve(
                    information_set,
                    mandatory_position,
                    actor,
                    filtered_actions,
                    provider,
                    mandatory_seed,
                    static_cast<std::uint64_t>(std::max<std::int64_t>(
                        0, integer_field(request, "node_budget", 192))),
                    &cancel_requested_);
            }
            mandatory_nodes = forced.nodes_expanded;
            mandatory_reason = forced.reason;
            if (forced.cancelled || cancel_requested_.load(std::memory_order_acquire)) {
                return error_result("cancelled", true);
            }

            if (!forced.resolved && !cache_key.empty()) {
                Value cached = probe_cached_turn_action(
                    cache_key,
                    revision,
                    filtered_actions,
                    provider.cache_precondition(mandatory_position, actor),
                    actor, legacy_update);
                if (cached.is_object() && !cached.as_object().empty()) {
                    const std::string kind = value_string_field(cached, "kind");
                    if ((kind == "DECLARE_ATTACK" || kind == "RETREAT"
                            || kind == "END_TURN")) {
                        bool changed = false;
                        const Value guarded = provider.post_plan_tactical_guard(
                            mandatory_position,
                            actor,
                            cached,
                            filtered_actions,
                            mandatory_seed + 700001U,
                            changed);
                        if (changed) {
                            cached = guarded;
                            cache_guarded = true;
                            legacy_update = {cache_key, std::nullopt};
                        }
                    }
                    forced.resolved = true;
                    forced.action = cached;
                    forced.reason = cache_guarded ? "plan_cache_guard" : "plan_cache";
                    forced.nodes_expanded = mandatory_nodes;
                    cache_hit = true;
                }
            }

            if (forced.resolved) {
                const std::string signature = value_action_signature(forced.action);
                const std::string completion = cache_hit
                    ? "cache_hit" : "forced_tactic";
                const std::string trajectory = sha256_text(
                    "turn_beam_v2|" + completion + "|" + signature);
                TraditionalSearchResult result;
            result.success = true;
            result.selected = forced.action;
            result.sequence = {forced.action};
            result.cache_preconditions = {provider.cache_precondition(mandatory_position, actor)};
            result.nodes_expanded = forced.nodes_expanded;
            result.completion_reason = completion;
            result.trajectory_hash = trajectory;
            Value output = search_result_value(result, 8, 3);
                output["forced_tactic"] = Value(cache_guarded
                    ? "post_plan_tactical_guard"
                    : (cache_hit ? "" : forced.reason));
                output["stop_reason"] = Value(forced.reason);
                output["search_depth_applicable"] = Value(false);
                output["native_mandatory_tactics"] = Value(true);
                output["native_setup_public_policy"] = Value(setup_public_policy);
                output["native_turn_plan_cache_hit"] = Value(cache_hit);
                output["native_mandatory_nodes"] = Value(static_cast<std::int64_t>(
                    forced.nodes_expanded));
                output["native_performance_counters"] = performance();
                return output;
            }
        }

        TraditionalSearchConfig config;
        config.worker_count = search_worker_count;
        config.belief_samples = adaptive_belief_samples;
        if (bool_field(request, "internal_evaluation_smoke")) {
            config.root_actions = 2;
            config.per_root_width = 1;
            config.max_depth = 1;
            config.actions_per_node = 2;
            config.reply_depth = 1;
            config.reply_width = 2;
            config.reply_actions_per_node = 2;
            config.belief_samples = 1;
        }
        TraditionalTurnBeamSearch search(provider, config);
        const auto planner_started = std::chrono::steady_clock::now();
        TraditionalSearchResult result = search.search(
            actor,
            static_cast<std::uint32_t>(integer_field(request, "seed", 1)),
            filtered_actions,
            &cancel_requested_);
        const double planner_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - planner_started).count();

        bool post_plan_guarded = false;
        if (result.success) {
            const std::uint32_t seed = static_cast<std::uint32_t>(
                integer_field(request, "seed", 1));
            const Value sample = information_set.sample_state(seed);
            RulesSession guard_position(catalog_);
            std::string guard_error;
            if (sample.is_object() && guard_position.restore(
                    sample, seed, &guard_error)) {
                bool changed = false;
                const Value guarded = provider.post_plan_tactical_guard(
                    guard_position,
                    actor,
                    result.selected,
                    filtered_actions,
                    seed + 700001U,
                    changed);
                if (changed) {
                    result.selected = guarded;
                    result.sequence = {guarded};
                    result.cache_preconditions = {
                        provider.cache_precondition(guard_position, actor)};
                    post_plan_guarded = true;
                }
            }
        }
        if (result.success) legacy_update = prepare_turn_plan(cache_key, revision, result);

        Value output = search_result_value(result, config.max_depth, config.reply_depth);
        output["planner_ms"] = Value(planner_ms);
        output["forced_tactic"] = Value(post_plan_guarded ? "post_plan_tactical_guard" : "");
        output["native_mandatory_tactics"] = Value(!bool_field(request, "skip_mandatory"));
        output["native_mandatory_nodes"] = Value(static_cast<std::int64_t>(
            mandatory_nodes));
        output["native_mandatory_reason"] = Value(mandatory_reason);
        output["native_turn_plan_cache_hit"] = Value(false);
        output["native_performance_counters"] = performance();
        return output;
    };
    const auto finish = [&](Value output, PlanCacheUpdate update, bool legacy_selected = false) {
        if (cancel_requested_.load(std::memory_order_acquire)
            || generation <= cancelled_through_generation_.load(std::memory_order_acquire)) {
            return error_result("cancelled", true);
        }
        // Invalid cache entries must also be discarded on an unsuccessful search.
        commit_plan_cache_update(std::move(update));
        if (bool_field(output, "success")) {
            // The legacy fallback historically commits its own non-shadow
            // cycle record, even when the strategic caller is a diagnostic probe.
            record_action_cycle_selection(request, public_state, value_or(output, "action"),
                legacy_selected && strategic_engine);
        }
        return output;
    };

    if (strategic_engine) {
        const std::uint32_t strategic_seed = static_cast<std::uint32_t>(
            integer_field(request, "seed", 1));
        std::optional<Value> legacy_shadow;
        double legacy_ms = 0.0;
        const auto get_legacy = [&]() -> const Value & {
            if (!legacy_shadow.has_value()) {
                const auto started = std::chrono::steady_clock::now();
                legacy_shadow = run_legacy();
                legacy_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - started).count();
            }
            return *legacy_shadow;
        };
        const auto emit_strategic = [&](const planner_v3::StrategicPlannerResult &row,
                                        bool cache_hit) {
            const TraditionalSearchResult &result = row.plan;
            const std::int64_t legacy_shadow_nodes = legacy_shadow.has_value()
                ? integer_field(*legacy_shadow, "nodes_expanded", 0) : 0;
            const Value legacy_shadow_action = legacy_shadow.has_value()
                ? value_or(*legacy_shadow, "action", Value::make_object())
                : Value::make_object();
            const bool forced = row.dominance_resolved;
            const std::size_t requested_depth = row.deliberation
                    == planner_v3::DeliberationLevel::D0
                ? 0 : (row.deliberation == planner_v3::DeliberationLevel::D1
                    ? 2 : (row.deliberation
                            == planner_v3::DeliberationLevel::D2 ? 4 : 5));
            Value counters = performance();
            counters["strategic_intent_decisions"] = Value(1);
            counters["strategic_deliberation_level"] = Value(
                planner_v3::deliberation_name(row.deliberation));
            counters["strategic_fallback"] = Value(false);
            counters["strategic_shadow_nodes"] = Value(legacy_shadow_nodes);
            Value output = search_result_value(result, requested_depth, 0);
            output["nodes_expanded"] = Value(static_cast<std::int64_t>(
                result.nodes_expanded) + legacy_shadow_nodes);
            output["completion_reason"] = Value(cache_hit
                ? "cache_hit" : (forced ? "forced_tactic"
                    : result.completion_reason));
            output["strategic_completion_reason"] = Value(
                result.completion_reason);
            output["forced_tactic"] = Value(forced
                ? "dominance_solver" : "");
            output["stop_reason"] = Value(cache_hit
                ? "plan_memory" : (forced ? "dominance_solver"
                    : "intent_compiled"));
            output["reply_completion_reason"] = Value(
                row.deliberation == planner_v3::DeliberationLevel::D3
                    ? "threat_scenarios" : "not_applicable");
            output["search_depth_applicable"] = Value(!forced && !cache_hit);
            output["search_depth_stop_reason"] = Value(cache_hit
                ? "plan_memory" : result.completion_reason);
            output["native_mandatory_tactics"] = Value(false);
            output["native_mandatory_nodes"] = Value(0);
            output["native_mandatory_reason"] = Value("replaced_by_dominance");
            output["native_turn_plan_cache_hit"] = Value(cache_hit);
            output["native_performance_counters"] = std::move(counters);
            output["engine_id"] = Value(
                planner_v3::STRATEGIC_INTENT_ENGINE_ID);
            output["strategic_intent"] = Value(
                planner_v3::intent_name(row.intent));
            output["strategic_deliberation"] = Value(
                planner_v3::deliberation_name(row.deliberation));
            output["strategic_facts"] = row.strategic_facts;
            output["strategic_match_plan"] = row.match_plan;
            output["strategic_plan_score"] = row.plan_score;
            output["strategic_explanation"] = row.explanation;
            output["strategic_fallback"] = Value(false);
            output["strategic_safety_validator"] = Value(true);
            output["strategic_plan_memory"] = Value(cache_hit || row.cacheable);
            output["strategic_shadow_legacy"] = Value(legacy_shadow.has_value());
            output["strategic_shadow_nodes"] = Value(legacy_shadow_nodes);
            output["strategic_shadow_ms"] = Value(legacy_ms);
            output["strategic_legacy_action"] = legacy_shadow_action;
            return output;
        };

        // A validated continuation never needs a second policy to rediscover it.
        PlanCacheUpdate strategic_update;
        if (!cache_key.empty()) {
            auto cache_position = provider.determinize(0, strategic_seed);
            if (cache_position != nullptr) {
                const Value precondition = provider.cache_precondition(*cache_position, actor);
                const Value cached = probe_cached_turn_action(
                    cache_key, revision, filtered_actions, precondition, actor,
                    strategic_update);
                if (cached.is_object() && !cached.as_object().empty()) {
                    planner_v3::StrategicPlannerResult cached_result;
                    auto &plan = cached_result.plan;
                    plan.success = true;
                    plan.selected = cached;
                    plan.sequence = Value::Array{cached};
                    plan.cache_preconditions = Value::Array{precondition};
                    plan.root_candidates = Value::Array{cached};
                    plan.completion_reason = "plan_memory_hit";
                    const std::string signature = value_action_signature(cached);
                    plan.trajectory_hash = sha256_text(
                        "strategic_intent_v3|plan_memory|" + signature);
                    plan.belief_samples = plan.belief_consensus = 1;
                    plan.root_signatures_attempted = {signature};
                    plan.root_sample_counts[signature] = 1;
                    cached_result.explanation = Value(Value::Object{
                        {"plan_memory", Value("preconditions_validated")},
                    });
                    return finish(emit_strategic(cached_result, true), std::move(strategic_update));
                }
            }
        }

        const auto strategic_started = std::chrono::steady_clock::now();
        planner_v3::StrategicPlannerConfig strategic_config;
        strategic_config.belief_samples = adaptive_belief_samples;
        strategic_config.node_budget = static_cast<std::uint64_t>(
            std::max<std::int64_t>(1, integer_field(request, "node_budget", 192)));
        strategic_config.evaluation_smoke = bool_field(
            request, "internal_evaluation_smoke");
        strategic_config.strategy_optimization = bool_field(
            request, "use_strategy_optimization", true);
        strategic_config.legacy_decision = get_legacy;
        planner_v3::StrategicPlannerResult strategic = strategic_planner_->decide(
            string_field(request, "match_instance_id"),
            information_set,
            provider,
            actor,
            strategic_seed,
            filtered_actions,
            strategic_config,
            &cancel_requested_);
        const double strategic_ms = std::max(0.0,
            std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - strategic_started).count() - legacy_ms);
        if (strategic.plan.cancelled
            || cancel_requested_.load(std::memory_order_acquire)) {
            return error_result("cancelled", true);
        }
        if (strategic.fallback_requested || !strategic.plan.success) {
            Value legacy = get_legacy();
            const std::int64_t legacy_nodes = integer_field(
                legacy, "nodes_expanded", 0);
            legacy["nodes_expanded"] = Value(legacy_nodes
                + static_cast<std::int64_t>(strategic.plan.nodes_expanded));
            legacy["strategic_probe_nodes"] = Value(
                static_cast<std::int64_t>(strategic.plan.nodes_expanded));
            legacy["strategic_probe_ms"] = Value(strategic_ms);
            legacy["strategic_shadow_legacy"] = Value(true);
            legacy["strategic_shadow_nodes"] = Value(legacy_nodes);
            legacy["strategic_shadow_ms"] = Value(legacy_ms);
            legacy["strategic_legacy_action"] = value_or(legacy, "action", Value::make_object());
            legacy["strategic_fallback"] = Value(true);
            legacy["strategic_fallback_reason"] = Value(
                strategic.fallback_reason);
            legacy["strategic_facts"] = strategic.strategic_facts;
            legacy["strategic_match_plan"] = strategic.match_plan;
            legacy["strategic_explanation"] = strategic.explanation;
            legacy["engine_id"] = Value(
                planner_v3::STRATEGIC_INTENT_ENGINE_ID);
            legacy["native_performance_counters"] = performance();
            Value &final_counters = legacy["native_performance_counters"];
            final_counters["strategic_intent_decisions"] = Value(1);
            final_counters["strategic_fallback"] = Value(true);
            final_counters["strategic_probe_nodes"] = Value(
                static_cast<std::int64_t>(strategic.plan.nodes_expanded));
            if (!cancel_requested_.load(std::memory_order_acquire)) {
                commit_plan_cache_update(std::move(strategic_update));
            }
            return finish(std::move(legacy), std::move(legacy_update), true);
        }
        if (strategic.cacheable) {
            strategic_update = prepare_turn_plan(cache_key, revision, strategic.plan);
        }
        Value strategic_output = emit_strategic(strategic, false);
        strategic_output["planner_ms"] = Value(strategic_ms);
        return finish(std::move(strategic_output), std::move(strategic_update));
    }

    Value output = run_legacy();
    return finish(std::move(output), std::move(legacy_update));
}

Value ChallengeController::decide_choice(
    const Value &request,
    std::int64_t generation
) {
    if (!configured_ || strategy_catalog_ == nullptr) {
        Value result = error_result("native_challenge_not_configured");
        result["kind"] = Value("choice");
        return result;
    }
    if (generation <= cancelled_through_generation_.load(
            std::memory_order_acquire)) {
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
    if (revision < 0
        || revision != value_integer_field(state, "revision", -2)
        || revision != value_integer_field(choice, "base_revision", -3)) {
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
    TraditionalInformationSet information_set;
    std::string error;
    const Value public_history = value_or(
        request, "public_history", Value::make_array());
    if (!information_set.capture(
        state,
        actor,
        catalog_,
        decks_,
        Value::make_array(),
        public_history,
        integer_field(request, "match_seed", integer_field(request, "seed", 0)),
        &error
    )) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result(error.empty()
            ? "choice_information_set_failed" : error);
        result["kind"] = Value("choice");
        return result;
    }
    const bool deck_inspection_enabled = bool_field(
        request, "use_deck_inspection", true);
    const bool deck_inspection_memory_applied =
        apply_deck_inspection_memory(request, information_set);
    bool deck_inspection_applied = false;
    const Value *presentation = choice.find("presentation");
    const Value *browse_refs = presentation != nullptr
        && presentation->is_object()
        ? presentation->find("browse_card_refs") : nullptr;
    if (deck_inspection_enabled && browse_refs != nullptr) {
        if (!information_set.apply_deck_inspection(choice, &error)) {
            active_generation_.store(0, std::memory_order_release);
            Value result = error_result(error.empty()
                ? "invalid_deck_inspection" : error);
            result["kind"] = Value("choice");
            return result;
        }
        deck_inspection_applied = true;
        remember_deck_inspection(request, information_set);
    }
    const std::uint32_t seed = static_cast<std::uint32_t>(
        integer_field(request, "seed", 17));
    const Value sampled = information_set.sample_state(seed);
    RulesSession position(catalog_);
    if (!sampled.is_object() || !position.restore(sampled, seed, &error)) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result(error.empty()
            ? "choice_determinization_failed" : error);
        result["kind"] = Value("choice");
        return result;
    }
    auto provider = make_challenge_search_provider(
        catalog_, decks_, strategies_, actor, &information_set,
        bool_field(request, "use_strategy_optimization", true));
    Value response;
    const Value *options = choice.find("options");
    if (options != nullptr && options->is_array() && options->as_array().empty()) {
        const bool cancelled = value_integer_field(choice, "min_select", 0) <= 0
            && bool_field(choice, "can_cancel");
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
    if (cancel_requested_.load(std::memory_order_acquire)) {
        active_generation_.store(0, std::memory_order_release);
        Value result = error_result("cancelled", true);
        result["kind"] = Value("choice");
        return result;
    }
    active_generation_.store(0, std::memory_order_release);
    const Value *keys = position.search_state().find("public_deck_keys");
    const std::string deck_key = keys != nullptr && keys->is_array()
        && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    Value output = Value::make_object();
    output["success"] = Value(true);
    output["kind"] = Value("choice");
    output["error"] = Value("");
    output["choice_response"] = response;
    output["simulations"] = Value(0);
    output["strategy_id"] = Value(strategy_catalog_->strategy_id(deck_key));
    output["strategy_version"] = Value(
        strategy_catalog_->strategy_version(deck_key));
    output["strategy_hash"] = Value(
        strategy_catalog_->strategy_content_hash(deck_key));
    output["engine_id"] = Value(string_field(request, "engine", "turn_beam_v2"));
    output["planner"] = output["engine_id"];
    output["completion_reason"] = Value("forced_tactic");
    output["decision_origin"] = Value("choice_policy");
    output["failure_stage"] = Value("");
    output["type_matchups"] = Value(false);
    output["revision"] = Value(revision);
    output["request_id"] = value_or(request, "request_id", Value(""));
    output["heuristic_variant"] = Value(
        string_field(request, "engine", "turn_beam_v2")
                == planner_v3::STRATEGIC_INTENT_ENGINE_ID
            ? "strategic_semantic_v3" : "semantic_v2");
    Value counters = provider->performance_counters();
    counters["deck_inspection_knowledge_enabled"] = Value(
        deck_inspection_enabled);
    counters["deck_inspection_applied"] = Value(deck_inspection_applied);
    counters["deck_inspection_memory_applied"] = Value(
        deck_inspection_memory_applied);
    counters["known_prize_identity_count"] = Value(
        information_set.has_exact_hidden_zones(actor)
            ? static_cast<std::int64_t>(
                information_set.known_prizes(actor).size())
            : 0);
    output["deck_inspection_applied"] = Value(deck_inspection_applied);
    output["deck_inspection_memory_applied"] = Value(
        deck_inspection_memory_applied);
    output["native_performance_counters"] = std::move(counters);
    return output;
}

Value ChallengeController::decide(
    const Value &request,
    std::int64_t generation
) {
    const auto started = std::chrono::steady_clock::now();
    if (!request.is_object()) return error_result("invalid_request");
    if (string_field(request, "kind", "action") == "choice") {
        Value result = decide_choice(request, generation);
        result["elapsed_ms"] = Value(std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count());
        return result;
    }
    Value planner = decide_action(request, generation);
    const double elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    if (!bool_field(planner, "success")) {
        planner["kind"] = Value("action");
        planner["decision_origin"] = Value("failure");
        planner["failure_stage"] = Value("search");
        planner["revision"] = value_or(request, "revision", Value(-1));
        planner["request_id"] = value_or(request, "request_id", Value(""));
        planner["elapsed_ms"] = Value(elapsed_ms);
        planner["heuristic_variant"] = Value("semantic_v2");
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
    Value preconditions = value_or(
        planner, "cache_preconditions", Value::make_array());
    const bool cache_hit = bool_field(planner, "native_turn_plan_cache_hit");
    const bool cache_guarded = cache_hit
        && !string_field(planner, "forced_tactic").empty();
    Value turn_plan = Value::make_array();
    if ((!cache_hit || cache_guarded)
        && sequence.is_array() && preconditions.is_array()) {
        const std::size_t count = std::min(
            sequence.as_array().size(), preconditions.as_array().size());
        for (std::size_t index = 0; index < count; ++index) {
            turn_plan.as_array().push_back(action_intent(
                sequence.as_array()[index], &preconditions.as_array()[index]));
        }
    }
    Value semantic_planner = planner;
    const std::string effective_engine = string_field(
        request, "engine", "turn_beam_v2");
    semantic_planner["engine_id"] = Value(effective_engine);
    semantic_planner["turn_plan"] = turn_plan;
    if (cache_hit && !cache_guarded) {
        semantic_planner["cache_preconditions"] = Value::make_array();
    }
    const std::string semantic_completion = value_string_field(
        semantic_planner, "completion_reason");
    if (semantic_completion == "forced_tactic"
        || semantic_completion == "cache_hit") {
        semantic_planner["nodes_expanded"] = Value(0);
    }
    const std::string semantic_hash = traditional_decision_semantic_hash(
        selected, semantic_planner, turn_plan);
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(request, "actor", -1));
    const Value state = value_or(
        request, "public_snapshot", value_or(request, "state", Value::make_object()));
    const Value *keys = state.find("public_deck_keys");
    const std::string inferred_deck = keys != nullptr && keys->is_array()
        && actor >= 0 && static_cast<std::size_t>(actor) < keys->as_array().size()
        ? keys->as_array()[static_cast<std::size_t>(actor)].string_or()
        : std::string{};
    const std::string requested_deck = string_field(request, "deck_key");
    const std::string deck_key = requested_deck.empty()
        ? inferred_deck : requested_deck;
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
    output["decision_origin"] = Value(cache_hit ? "cache"
        : (completion == "forced_tactic" || !forced.empty())
            ? "forced_tactic" : "search");
    output["failure_stage"] = Value("");
    output["planner_score"] = Value(static_cast<double>(score_milli) / 1000.0);
    output["planner_score_milli"] = Value(score_milli);
    output["turn_plan_size"] = Value(static_cast<std::int64_t>(
        turn_plan.as_array().size()));
    output["turn_plan_cache_hit"] = Value(cache_hit);
    output["planner_error"] = value_or(planner, "error", Value(""));
    output["strategy_id"] = Value(strategy_catalog_ == nullptr
        ? "generic_balanced_v1" : strategy_catalog_->strategy_id(deck_key));
    output["strategy_version"] = Value(strategy_catalog_ == nullptr
        ? 0 : strategy_catalog_->strategy_version(deck_key));
    output["strategy_hash"] = Value(strategy_catalog_ == nullptr
        ? "" : strategy_catalog_->strategy_content_hash(deck_key));
    output["turn_goal"] = strategy_catalog_ == nullptr
        ? Value::make_object() : strategy_catalog_->turn_goals(state, actor);
    output["type_matchups"] = Value(false);
    output["revision"] = value_or(request, "revision", Value(-1));
    output["request_id"] = value_or(request, "request_id", Value(""));
    output["elapsed_ms"] = Value(elapsed_ms);
    output["heuristic_variant"] = Value(
        effective_engine == planner_v3::STRATEGIC_INTENT_ENGINE_ID
            ? "strategic_semantic_v3" : "semantic_v2");
    return output;
}

void ChallengeController::cancel(std::int64_t generation) noexcept {
    std::int64_t observed = cancelled_through_generation_.load(
        std::memory_order_relaxed);
    while (observed < generation
        && !cancelled_through_generation_.compare_exchange_weak(
            observed,
            generation,
            std::memory_order_release,
            std::memory_order_relaxed)) {}
    const std::int64_t active = active_generation_.load(std::memory_order_acquire);
    if (active > 0 && active <= generation) {
        cancel_requested_.store(true, std::memory_order_release);
    }
}

void ChallengeController::reset_match(const std::string &match_instance_id) {
    if (active_match_instance_id_ != match_instance_id) {
        action_cycle_ledger_.clear();
        action_cycle_order_.clear();
        turn_plan_cache_.clear();
        turn_plan_cache_order_.clear();
        deck_inspection_memory_ = {};
    }
    if (strategic_planner_ != nullptr) {
        strategic_planner_->reset_match(match_instance_id);
    }
    active_match_instance_id_ = match_instance_id;
}

Value ChallengeController::get_contract() const {
#if defined(__ANDROID__)
    constexpr std::int64_t worker_count = 2;
#elif defined(_WIN32)
    constexpr std::int64_t worker_count = 3;
#else
    constexpr std::int64_t worker_count = 1;
#endif
    return Value(Value::Object{
        {"schema", Value("ptcg.native_challenge_ai/1")},
        {"search_version", Value(NATIVE_TRADITIONAL_SEARCH_VERSION)},
        {"engine_id", Value("turn_beam_v2")},
        {"strategic_search_version", Value(
            planner_v3::STRATEGIC_INTENT_SEARCH_VERSION)},
        {"strategic_engine_status", Value("experimental_not_promoted")},
        {"supported_engines", Value(Value::Array{
            Value(planner_v3::STRATEGIC_INTENT_ENGINE_ID),
            Value("turn_beam_v2"),
        })},
        {"legacy_search_version", Value(NATIVE_TRADITIONAL_SEARCH_VERSION)},
        {"action_schema_version", Value(4)},
        {"choice_view_schema_version", Value(2)},
        {"snapshot_schema_version", Value(3)},
        {"max_depth", Value(8)},
        {"belief_samples", Value(3)},
        {"adaptive_belief_samples", Value(true)},
        {"reply_depth", Value(3)},
        {"atomic_generation_cancellation", Value(true)},
        {"callback_free", Value(true)},
        {"typed_authoritative_core", Value(true)},
        {"native_information_set", Value(true)},
        {"native_action_policy", Value(true)},
        {"native_position_evaluator", Value(true)},
        {"native_strategy_catalog", Value(true)},
        {"native_choice_policy", Value(true)},
        {"native_mandatory_tactics", Value(true)},
        {"native_no_progress_loop_guard", Value(true)},
        {"native_turn_plan_cache", Value(true)},
        {"owner_deck_inspection_knowledge", Value(true)},
        {"deck_inspection_prize_memory", Value(true)},
        {"strategic_facts", Value(true)},
        {"strategic_match_plan", Value(true)},
        {"strategic_intent_compiler", Value(true)},
        {"strategic_threat_scenarios", Value(true)},
        {"strategic_partial_order_reduction", Value(true)},
        {"strategic_safety_validator", Value(true)},
        {"legacy_fallback", Value(true)},
        {"search_worker_count", Value(worker_count)},
        {"parallel_belief_samples", Value(worker_count > 1)},
        {"performance_counters", Value(true)},
        {"production_ready", Value(true)},
    });
}

} // namespace ptcg::ai

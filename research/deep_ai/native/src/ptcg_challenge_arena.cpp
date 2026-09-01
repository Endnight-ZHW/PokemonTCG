#include "ptcg_challenge_arena.hpp"

#include "challenge_support.hpp"
#include "ptcg_rules_session.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>
#include <unordered_set>
#include <utility>

namespace ptcg::ai {
namespace {

using Array = Value::Array;
using Object = Value::Object;
using Clock = std::chrono::steady_clock;

const Value *field(const Value &value, const char *key) {
    return value.is_object() ? value.find(key) : nullptr;
}

std::string string_field(
    const Value &value,
    const char *key,
    std::string fallback = {}
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? std::move(fallback)
                            : entry->string_or(std::move(fallback));
}

std::int64_t integer_field(
    const Value &value,
    const char *key,
    std::int64_t fallback = 0
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_integer(fallback);
}

double number_field(
    const Value &value,
    const char *key,
    double fallback = 0.0
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_number(fallback);
}

bool bool_field(const Value &value, const char *key, bool fallback = false) {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_bool(fallback);
}

bool nonempty_object(const Value &value) {
    return value.is_object() && !value.as_object().empty();
}

std::int32_t history_visibility_owner(const Value &event) {
    const std::int32_t explicit_owner = static_cast<std::int32_t>(
        integer_field(event, "visibility_owner", -1));
    if (explicit_owner == 0 || explicit_owner == 1) return explicit_owner;
    const Value *data = field(event, "data");
    if (data != nullptr && data->is_object()) {
        for (const char *key : {"visibility_owner", "owner", "player"}) {
            const std::int32_t owner = static_cast<std::int32_t>(
                integer_field(*data, key, -1));
            if (owner == 0 || owner == 1) return owner;
        }
    }
    for (const char *key : {"source", "target"}) {
        const Value *endpoint = field(event, key);
        if (endpoint != nullptr && endpoint->is_object()) {
            const std::int32_t owner = static_cast<std::int32_t>(
                integer_field(*endpoint, "player", -1));
            if (owner == 0 || owner == 1) return owner;
        }
    }
    return static_cast<std::int32_t>(integer_field(event, "actor", -1));
}

Value normalized_history_endpoint(
    const Value &event,
    const Value &data,
    const char *key,
    std::int32_t actor
) {
    const bool source = std::string(key) == "source";
    const Value *explicit_endpoint = field(event, key);
    Value endpoint = explicit_endpoint != nullptr
        && explicit_endpoint->is_object()
        ? explicit_endpoint->deep_clone()
        : Value::make_object();
    const char *player_key = source ? "source_player" : "target_player";
    const char *zone_key = source ? "source_zone" : "target_zone";
    const char *slot_key = source ? "source_slot" : "target_slot";
    const char *index_key = source ? "source_index" : "target_index";
    if (integer_field(endpoint, "player", -1) < 0) {
        endpoint["player"] = Value(integer_field(
            data, player_key, integer_field(data, "player", actor)));
    }
    if (field(endpoint, "zone") == nullptr) {
        endpoint["zone"] = Value(string_field(data, zone_key));
    }
    if (field(endpoint, "slot") == nullptr) {
        endpoint["slot"] = Value(string_field(
            data, slot_key, source ? std::string{} : string_field(data, "slot")));
    }
    if (field(endpoint, "index") == nullptr) {
        endpoint["index"] = Value(integer_field(data, index_key, -1));
    }
    return endpoint;
}

Value normalized_history_event(const Value &raw_event) {
    Value event = raw_event.deep_clone();
    const Value *raw_data = field(event, "data");
    Value data = raw_data != nullptr && raw_data->is_object()
        ? raw_data->deep_clone() : Value::make_object();
    const std::int32_t actor = static_cast<std::int32_t>(integer_field(
        event, "actor", integer_field(data, "player", -1)));
    event["actor"] = Value(actor);
    event["data"] = data;
    event["source"] = normalized_history_endpoint(
        event, data, "source", actor);
    event["target"] = normalized_history_endpoint(
        event, data, "target", actor);
    if (field(event, "card_id") == nullptr) {
        event["card_id"] = Value(string_field(data, "card_id"));
    }
    if (field(event, "visibility") == nullptr) {
        const std::string event_type = string_field(event, "event_type");
        const std::string fallback = event_type == "cards_drawn"
                || event_type == "cards_selected"
                || event_type == "prize_taken"
            ? "owner" : "public";
        event["visibility"] = Value(string_field(
            data, "visibility", fallback));
    }
    const std::string visibility = string_field(event, "visibility", "public");
    if (visibility != "public"
        && field(data, "visibility_owner") == nullptr) {
        const std::int32_t owner = history_visibility_owner(event);
        if (owner == 0 || owner == 1) {
            data["visibility_owner"] = Value(owner);
            event["data"] = data;
        }
    }
    return event;
}

void strip_history_card_identity(Value &event) {
    event["card_id"] = Value("");
    Value *data = event.find("data");
    if (data != nullptr && data->is_object()) {
        for (const char *key : {
            "card_id", "source_card_id", "target_card_id",
        }) {
            if (data->find(key) != nullptr) (*data)[key] = Value("");
        }
        for (const char *key : {
            "card_ids", "cards", "selected_card_ids",
        }) {
            if (data->find(key) != nullptr) {
                (*data)[key] = Value::make_array();
            }
        }
        for (const char *key : {"source_index", "target_index"}) {
            if (data->find(key) != nullptr) (*data)[key] = Value(-1);
        }
        for (const char *key : {"source_indices", "target_indices"}) {
            if (data->find(key) != nullptr) {
                (*data)[key] = Value::make_array();
            }
        }
    }
    for (const char *key : {"source", "target"}) {
        Value *endpoint = event.find(key);
        if (endpoint != nullptr && endpoint->is_object()) {
            (*endpoint)["index"] = Value(-1);
        }
    }
}

void append_public_history(
    std::array<Array, 2> &histories,
    const std::vector<Value> &events
) {
    constexpr std::size_t maximum_history = 4096;
    for (const Value &raw_event : events) {
        if (!raw_event.is_object()) continue;
        const Value event = normalized_history_event(raw_event);
        const std::string visibility = string_field(
            event, "visibility", "public");
        const std::int32_t owner = history_visibility_owner(event);
        for (std::int32_t viewer = 0; viewer < 2; ++viewer) {
            if (visibility == "private" && owner != viewer) continue;
            Value projected = event.deep_clone();
            if (visibility == "owner" && owner != viewer) {
                strip_history_card_identity(projected);
            }
            Array &history = histories[static_cast<std::size_t>(viewer)];
            history.push_back(std::move(projected));
            if (history.size() > maximum_history) history.erase(history.begin());
        }
    }
}

std::uint64_t elapsed_us(const Clock::time_point &started) {
    return static_cast<std::uint64_t>(std::max<std::int64_t>(
        0,
        std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - started).count()));
}

bool terminal_state(const Value &state) {
    const std::string status = string_field(state, "result_status");
    return status == "WIN" || status == "DRAW"
        || string_field(state, "phase") == "GAME_OVER";
}

std::int32_t state_actor(const Value &state) {
    const Value *promotions = field(state, "pending_promotions");
    if (promotions != nullptr && promotions->is_array()
        && !promotions->as_array().empty()) {
        const std::int32_t actor = static_cast<std::int32_t>(
            promotions->as_array().front().as_integer(-1));
        if (actor == 0 || actor == 1) return actor;
    }
    if (string_field(state, "setup_stage") != "COMPLETE") {
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_field(state, "setup_actor_idx", -1));
        if (actor == 0 || actor == 1) return actor;
    }
    return static_cast<std::int32_t>(
        integer_field(state, "active_player_idx", -1));
}

std::vector<std::string> expand_deck(
    const Value &decks,
    const std::string &deck_key
) {
    const Value *definition = decks.find(deck_key);
    if (definition == nullptr) {
        throw std::invalid_argument("challenge_arena_unknown_deck:" + deck_key);
    }
    const Value *rows = definition;
    if (definition->is_object()) rows = definition->find("cards");
    if (rows == nullptr || !rows->is_array()) {
        throw std::invalid_argument("challenge_arena_invalid_deck:" + deck_key);
    }
    std::vector<std::string> result;
    for (const Value &row : rows->as_array()) {
        if (row.is_string()) {
            result.push_back(row.string_or());
            continue;
        }
        if (!row.is_object()) {
            throw std::invalid_argument("challenge_arena_invalid_deck_row");
        }
        const std::string card_id = string_field(row, "card_id");
        const std::int64_t count = integer_field(row, "count", 0);
        if (card_id.empty() || count <= 0 || count > 60) {
            throw std::invalid_argument("challenge_arena_invalid_deck_entry");
        }
        result.insert(result.end(), static_cast<std::size_t>(count), card_id);
    }
    if (result.size() != 60) {
        throw std::invalid_argument(
            "challenge_arena_deck_must_have_60_cards:" + deck_key);
    }
    return result;
}

Value deck_value(const std::vector<std::string> &cards) {
    Array result;
    result.reserve(cards.size());
    for (const std::string &card : cards) result.emplace_back(card);
    return Value(std::move(result));
}

Value forced_turn_order_response(
    const Value &pending,
    std::int32_t first_player
) {
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_field(pending, "player", -1));
    Array selected;
    selected.emplace_back(actor == first_player ? "turn:first" : "turn:second");
    return Value(Object{
        {"request_id", Value(string_field(pending, "request_id"))},
        {"option_ids", Value(std::move(selected))},
        {"cancelled", Value(false)},
    });
}

std::uint32_t mix32(std::uint32_t value) noexcept {
    value ^= value >> 16U;
    value *= 0x7feb352dU;
    value ^= value >> 15U;
    value *= 0x846ca68bU;
    value ^= value >> 16U;
    return value;
}

std::uint32_t decision_seed(
    const ChallengeArenaTask &task,
    const RulesSession &session,
    std::int32_t actor,
    bool choice
) noexcept {
    std::uint32_t seed = mix32(task.game_seed ^ 0x9e3779b9U);
    seed ^= mix32(static_cast<std::uint32_t>(session.revision()) + 0x85ebca6bU);
    seed ^= mix32(static_cast<std::uint32_t>(actor + 1) * 0xc2b2ae35U);
    seed ^= choice ? 0x27d4eb2fU : 0x165667b1U;
    seed = mix32(seed);
    return seed == 0 ? 17U : seed;
}

ChallengeArenaGameResult task_result(const ChallengeArenaTask &task) {
    ChallengeArenaGameResult result;
    result.task_id = task.task_id;
    result.candidate_deck = task.candidate_deck;
    result.baseline_deck = task.baseline_deck;
    result.game_seed = task.game_seed;
    result.candidate_seat = task.candidate_seat;
    result.first_player = task.first_player;
    result.max_decisions = task.max_decisions;
    return result;
}

std::int32_t agent_for_seat(
    const ChallengeArenaGameResult &result,
    std::int32_t seat
) {
    if (seat != 0 && seat != 1) return -1;
    return seat == result.candidate_seat ? 0 : 1;
}

std::int32_t seat_for_agent(
    const ChallengeArenaGameResult &result,
    std::int32_t agent
) {
    if (agent == 0) return result.candidate_seat;
    if (agent == 1) return 1 - result.candidate_seat;
    return -1;
}

void set_winner(
    ChallengeArenaGameResult &result,
    std::int32_t winner_seat
) {
    result.winner_seat = winner_seat;
    result.winner_agent = agent_for_seat(result, winner_seat);
    result.candidate_score_x2 = result.winner_agent < 0
        ? 1 : (result.winner_agent == 0 ? 2 : 0);
}

void adjudicate_agent_failure(
    ChallengeArenaGameResult &result,
    std::int32_t offending_agent,
    std::string kind,
    std::string error
) {
    result.success = false;
    result.terminal = true;
    result.strength_eligible = true;
    result.offending_agent = offending_agent;
    result.failure_kind = std::move(kind);
    result.error = std::move(error);
    set_winner(result, 1 - seat_for_agent(result, offending_agent));
}

void infrastructure_failure(
    ChallengeArenaGameResult &result,
    std::string kind,
    std::string error
) {
    result.success = false;
    result.terminal = false;
    result.strength_eligible = false;
    result.failure_kind = std::move(kind);
    result.error = std::move(error);
    result.candidate_score_x2 = 1;
    ++result.rule_exceptions;
}

void cancellation_failure(ChallengeArenaGameResult &result) {
    result.success = false;
    result.terminal = false;
    result.strength_eligible = false;
    result.failure_kind = "cancelled";
    result.error = "challenge_arena_cancelled";
    result.candidate_score_x2 = 1;
}

Value legal_signatures(const Value &actions) {
    Array result;
    if (!actions.is_array()) return Value(std::move(result));
    result.reserve(actions.as_array().size());
    for (const Value &action : actions.as_array()) {
        Value normalized = action;
        normalized.erase("action_id");
        result.emplace_back("arena-action:" + challenge::sha256_text(
            challenge::stable_value_signature(normalized)));
    }
    return Value(std::move(result));
}

std::string authoritative_action_signature(const Value &action) {
    if (!action.is_object()) return {};
    Value normalized = action;
    // action_id is transport idempotency metadata generated by the Arena host;
    // every other Action v4 field remains part of the authoritative identity.
    normalized.erase("action_id");
    return "arena-action:" + challenge::sha256_text(
        challenge::stable_value_signature(normalized));
}

const Value *unique_action_match(
    const Value &actions,
    const Value &returned_action,
    std::string *signature
) {
    if (!actions.is_array() || !returned_action.is_object()) return nullptr;
    const std::string expected = authoritative_action_signature(returned_action);
    if (signature != nullptr) *signature = expected;
    const Value *match = nullptr;
    std::size_t count = 0;
    for (const Value &action : actions.as_array()) {
        if (authoritative_action_signature(action) != expected) continue;
        match = &action;
        ++count;
    }
    return count == 1 ? match : nullptr;
}

bool validate_choice_response(
    const Value &choice,
    const Value &response,
    std::string *error
) {
    const auto fail = [error](const char *message) {
        if (error != nullptr) *error = message;
        return false;
    };
    if (!choice.is_object() || !response.is_object()) {
        return fail("invalid_choice_response_shape");
    }
    const Value *request_id = field(response, "request_id");
    const Value *cancelled_field = field(response, "cancelled");
    if (request_id == nullptr || !request_id->is_string()
        || cancelled_field == nullptr || !cancelled_field->is_bool()) {
        return fail("invalid_choice_response_shape");
    }
    if (string_field(response, "request_id")
        != string_field(choice, "request_id")) {
        return fail("choice_request_id_mismatch");
    }
    const Value *selected = field(response, "option_ids");
    if (selected == nullptr || !selected->is_array()) {
        return fail("choice_option_ids_missing");
    }
    const bool cancelled = bool_field(response, "cancelled");
    if (cancelled) {
        if (!bool_field(choice, "can_cancel") || !selected->as_array().empty()) {
            return fail("choice_cancel_not_allowed");
        }
        if (error != nullptr) error->clear();
        return true;
    }
    const std::size_t count = selected->as_array().size();
    const std::int64_t minimum = integer_field(choice, "min_select", 0);
    const std::int64_t maximum = integer_field(choice, "max_select", minimum);
    if (count < static_cast<std::size_t>(std::max<std::int64_t>(0, minimum))
        || count > static_cast<std::size_t>(std::max<std::int64_t>(0, maximum))) {
        return fail("choice_selection_count_invalid");
    }
    const Value *options = field(choice, "options");
    if (options == nullptr || !options->is_array()) {
        return fail("choice_options_missing");
    }
    std::unordered_set<std::string> allowed;
    for (const Value &option : options->as_array()) {
        const std::string option_id = string_field(option, "option_id");
        if (!option_id.empty()) allowed.insert(option_id);
    }
    std::unordered_set<std::string> seen;
    for (const Value &entry : selected->as_array()) {
        if (!entry.is_string() || entry.string_or().empty()
            || allowed.count(entry.string_or()) == 0) {
            return fail("choice_unknown_option");
        }
        if (!bool_field(choice, "allow_duplicates")
            && !seen.insert(entry.string_or()).second) {
            return fail("choice_duplicate_option");
        }
    }
    if (error != nullptr) error->clear();
    return true;
}

void add_evaluation_options(Value &request, const Value &options) {
    if (options.is_object()) {
        for (const char *key : {
            "engine", "node_budget", "belief_samples", "skip_mandatory",
            "internal_evaluation_smoke",
        }) {
            const Value *entry = options.find(key);
            if (entry != nullptr) request[key] = *entry;
        }
    }
    if (field(request, "engine") == nullptr) {
        request["engine"] = Value("turn_beam_v2");
    }
    // This flag is not caller-overridable: it is the native contract that
    // prevents nested Challenge search pools from oversubscribing the host.
    request["internal_evaluation_batch"] = Value(true);
}

void add_agent_metrics(
    ChallengeArenaGameResult &summary,
    bool candidate,
    const Value &decision,
    std::uint64_t decision_microseconds
) {
    const std::uint64_t nodes = static_cast<std::uint64_t>(
        std::max<std::int64_t>(0, integer_field(
            decision, "nodes_expanded",
            integer_field(decision, "simulations", 0))));
    const std::uint64_t planner_us = static_cast<std::uint64_t>(std::max(
        0.0, std::round(number_field(decision, "planner_ms", 0.0) * 1000.0)));
    const bool forced = string_field(decision, "decision_origin")
        == "forced_tactic";
    const bool cache_hit = bool_field(decision, "turn_plan_cache_hit")
        || bool_field(decision, "native_turn_plan_cache_hit");
    const bool action_decision = string_field(decision, "kind") == "action";
    const bool choice_decision = string_field(decision, "kind") == "choice";
    const bool search_decision = action_decision
        && bool_field(decision, "search_depth_applicable");
    const std::uint64_t completed_depth = static_cast<std::uint64_t>(
        std::max<std::int64_t>(0, integer_field(decision, "completed_depth", 0)));
    const std::uint64_t reply_depth = static_cast<std::uint64_t>(
        std::max<std::int64_t>(0, integer_field(
            decision, "reply_completed_depth", 0)));
    const std::uint64_t belief_samples = static_cast<std::uint64_t>(
        std::max<std::int64_t>(0, integer_field(decision, "belief_samples", 0)));
    if (candidate) {
        summary.candidate_decision_us += decision_microseconds;
        summary.candidate_nodes += nodes;
        summary.candidate_decision_samples_us.push_back(decision_microseconds);
        if (field(decision, "planner_ms") != nullptr) {
            summary.candidate_planner_samples_us.push_back(planner_us);
        }
        summary.candidate_action_decisions += action_decision ? 1U : 0U;
        summary.candidate_choice_decisions += choice_decision ? 1U : 0U;
        summary.candidate_search_decisions += search_decision ? 1U : 0U;
        summary.candidate_forced_tactics += forced ? 1U : 0U;
        summary.candidate_plan_cache_hits += cache_hit ? 1U : 0U;
        summary.candidate_completed_depth += completed_depth;
        summary.candidate_reply_depth += reply_depth;
        summary.candidate_belief_samples += belief_samples;
    } else {
        summary.baseline_decision_us += decision_microseconds;
        summary.baseline_nodes += nodes;
        summary.baseline_decision_samples_us.push_back(decision_microseconds);
        if (field(decision, "planner_ms") != nullptr) {
            summary.baseline_planner_samples_us.push_back(planner_us);
        }
        summary.baseline_action_decisions += action_decision ? 1U : 0U;
        summary.baseline_choice_decisions += choice_decision ? 1U : 0U;
        summary.baseline_search_decisions += search_decision ? 1U : 0U;
        summary.baseline_forced_tactics += forced ? 1U : 0U;
        summary.baseline_plan_cache_hits += cache_hit ? 1U : 0U;
        summary.baseline_completed_depth += completed_depth;
        summary.baseline_reply_depth += reply_depth;
        summary.baseline_belief_samples += belief_samples;
    }
}

void finalize_semantic_hash(ChallengeArenaGameResult &result) {
    const Value payload(Object{
        {"schema", Value("ptcg.challenge_arena.game_semantics/1")},
        {"task_id", Value(result.task_id)},
        {"candidate_deck", Value(result.candidate_deck)},
        {"baseline_deck", Value(result.baseline_deck)},
        {"game_seed", Value(static_cast<std::int64_t>(result.game_seed))},
        {"candidate_seat", Value(result.candidate_seat)},
        {"first_player", Value(result.first_player)},
        {"success", Value(result.success)},
        {"terminal", Value(result.terminal)},
        {"truncated", Value(result.truncated)},
        {"strength_eligible", Value(result.strength_eligible)},
        {"winner_seat", Value(result.winner_seat)},
        {"winner_agent", Value(result.winner_agent)},
        {"candidate_score_x2", Value(result.candidate_score_x2)},
        {"offending_agent", Value(result.offending_agent)},
        {"decisions", Value(static_cast<std::int64_t>(result.decisions))},
        {"turns", Value(static_cast<std::int64_t>(result.turns))},
        {"invalid_actions", Value(static_cast<std::int64_t>(
            result.invalid_actions))},
        {"illegal_choices", Value(static_cast<std::int64_t>(
            result.illegal_choices))},
        {"controller_failures", Value(static_cast<std::int64_t>(
            result.controller_failures))},
        {"rule_exceptions", Value(static_cast<std::int64_t>(
            result.rule_exceptions))},
        {"failure_kind", Value(result.failure_kind)},
        {"error", Value(result.error)},
        {"final_state_hash", Value(result.final_state_hash)},
    });
    result.semantic_result_hash = challenge::sha256_text(
        challenge::stable_value_signature(payload));
}

void finalize_from_session(
    ChallengeArenaGameResult &result,
    const RulesSession &session
) {
    if (session.initialized()) {
        const Value final_state = session.snapshot();
        result.turns = static_cast<std::uint32_t>(std::max<std::int64_t>(
            0, integer_field(final_state, "turn_number", 0)));
        result.final_state_hash = session.state_hash();
    }
    finalize_semantic_hash(result);
}

Value failure_trace(
    const RulesSession &session,
    Value detail,
    bool enabled
) {
    if (!enabled) return Value::make_object();
    if (!detail.is_object()) detail = Value::make_object();
    if (session.initialized()) {
        detail["journal"] = session.journal();
        detail["final_snapshot"] = session.snapshot();
        detail["final_state_hash"] = Value(session.state_hash());
    }
    return detail;
}

} // namespace

NativeChallengeArenaPool::NativeChallengeArenaPool(
    Value catalog,
    Value decks,
    ChallengeArenaAgentSpec candidate,
    ChallengeArenaAgentSpec baseline,
    ChallengeArenaPoolConfig config
) :
    catalog_(std::move(catalog)),
    decks_(std::move(decks)),
    candidate_(std::move(candidate)),
    baseline_(std::move(baseline)),
    config_(config) {
    if (!catalog_.is_object() || catalog_.as_object().empty()
        || !decks_.is_object() || decks_.as_object().empty()
        || candidate_.agent_id.empty() || baseline_.agent_id.empty()
        || !candidate_.strategies.is_object()
        || candidate_.strategies.as_object().empty()
        || !baseline_.strategies.is_object()
        || baseline_.strategies.as_object().empty()
        || (candidate_.backend != "in_process"
            && candidate_.backend != "external_process")
        || (baseline_.backend != "in_process"
            && baseline_.backend != "external_process")
        || candidate_.decision_timeout_milliseconds == 0
        || baseline_.decision_timeout_milliseconds == 0
        || config_.concurrent_games == 0
        || config_.inner_search_workers != 1
        || !config_.deterministic) {
        throw std::invalid_argument("invalid_challenge_arena_configuration");
    }
}

NativeChallengeArenaPool::~NativeChallengeArenaPool() {
    cancel();
    wait();
}

void NativeChallengeArenaPool::start(std::vector<ChallengeArenaTask> tasks) {
    if (running_.exchange(true) || !workers_.empty()) {
        running_ = true;
        throw std::logic_error("challenge_arena_already_started");
    }
    if (tasks.empty()) {
        running_ = false;
        throw std::invalid_argument("challenge_arena_tasks_empty");
    }
    std::set<std::string> task_ids;
    for (const ChallengeArenaTask &task : tasks) {
        if (task.task_id.empty() || task.candidate_deck.empty()
            || task.baseline_deck.empty()
            || task.candidate_seat < 0 || task.candidate_seat > 1
            || task.first_player < 0 || task.first_player > 1
            || task.max_decisions == 0) {
            running_ = false;
            throw std::invalid_argument("invalid_challenge_arena_task");
        }
        if (!task_ids.insert(task.task_id).second) {
            running_ = false;
            throw std::invalid_argument("duplicate_challenge_arena_task_id");
        }
    }
    tasks_ = std::move(tasks);
    next_task_ = 0;
    cancelled_ = false;
    paused_ = false;
    finished_ = false;
    const std::size_t count = std::min<std::size_t>(
        config_.concurrent_games, tasks_.size());
    active_workers_ = count;
    workers_.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        workers_.emplace_back(&NativeChallengeArenaPool::worker, this);
    }
}

void NativeChallengeArenaPool::pause() noexcept {
    paused_ = true;
}

void NativeChallengeArenaPool::resume() noexcept {
    paused_ = false;
    pause_ready_.notify_all();
}

void NativeChallengeArenaPool::cancel() noexcept {
    cancelled_ = true;
    paused_ = false;
    pause_ready_.notify_all();
    std::lock_guard<std::mutex> lock(controllers_mutex_);
    for (ChallengeArenaAgent *agent : active_agents_) {
        if (agent != nullptr) {
            agent->cancel(std::numeric_limits<std::int64_t>::max());
        }
    }
}

void NativeChallengeArenaPool::wait() {
    for (std::thread &worker_thread : workers_) {
        if (worker_thread.joinable()) worker_thread.join();
    }
    workers_.clear();
    running_ = false;
    finished_ = true;
}

bool NativeChallengeArenaPool::wait_for(std::uint32_t timeout_milliseconds) {
    if (finished_) return true;
    std::unique_lock<std::mutex> lock(completion_mutex_);
    return completion_ready_.wait_for(
        lock,
        std::chrono::milliseconds(timeout_milliseconds),
        [this]() { return finished_.load(); });
}

bool NativeChallengeArenaPool::running() const noexcept {
    return running_;
}

bool NativeChallengeArenaPool::finished() const noexcept {
    return finished_;
}

std::vector<ChallengeArenaGameResult> NativeChallengeArenaPool::drain_games() {
    std::lock_guard<std::mutex> lock(results_mutex_);
    std::vector<ChallengeArenaGameResult> result;
    result.swap(results_);
    return result;
}

Value NativeChallengeArenaPool::metrics() const {
    return Value(Object{
        {"schema", Value("ptcg.native_challenge_arena.metrics/1")},
        {"tasks", Value(static_cast<std::int64_t>(tasks_.size()))},
        {"completed_games", Value(static_cast<std::int64_t>(
            completed_games_.load()))},
        {"failed_games", Value(static_cast<std::int64_t>(
            failed_games_.load()))},
        {"decisions", Value(static_cast<std::int64_t>(decisions_.load()))},
        {"invalid_actions", Value(static_cast<std::int64_t>(
            invalid_actions_.load()))},
        {"illegal_choices", Value(static_cast<std::int64_t>(
            illegal_choices_.load()))},
        {"controller_failures", Value(static_cast<std::int64_t>(
            controller_failures_.load()))},
        {"rule_exceptions", Value(static_cast<std::int64_t>(
            rule_exceptions_.load()))},
        {"truncated_games", Value(static_cast<std::int64_t>(
            truncated_games_.load()))},
        {"candidate_decision_us", Value(static_cast<std::int64_t>(
            candidate_decision_us_.load()))},
        {"baseline_decision_us", Value(static_cast<std::int64_t>(
            baseline_decision_us_.load()))},
        {"candidate_nodes", Value(static_cast<std::int64_t>(
            candidate_nodes_.load()))},
        {"baseline_nodes", Value(static_cast<std::int64_t>(
            baseline_nodes_.load()))},
        {"projection_us", Value(static_cast<std::int64_t>(
            projection_us_.load()))},
        {"legal_actions_us", Value(static_cast<std::int64_t>(
            legal_actions_us_.load()))},
        {"apply_us", Value(static_cast<std::int64_t>(apply_us_.load()))},
        {"candidate_agent_id", Value(candidate_.agent_id)},
        {"candidate_build_id", Value(candidate_.build_id)},
        {"candidate_backend", Value(candidate_.backend)},
        {"candidate_implementation_hash", Value(
            candidate_.implementation_hash)},
        {"baseline_agent_id", Value(baseline_.agent_id)},
        {"baseline_build_id", Value(baseline_.build_id)},
        {"baseline_backend", Value(baseline_.backend)},
        {"baseline_implementation_hash", Value(
            baseline_.implementation_hash)},
        {"deterministic", Value(config_.deterministic)},
        {"inner_search_workers", Value(static_cast<std::int64_t>(
            config_.inner_search_workers))},
        {"running", Value(running_.load())},
        {"finished", Value(finished_.load())},
        {"paused", Value(paused_.load())},
        {"cancelled", Value(cancelled_.load())},
    });
}

void NativeChallengeArenaPool::wait_if_paused() {
    if (!paused_) return;
    std::unique_lock<std::mutex> lock(pause_mutex_);
    pause_ready_.wait(lock, [this]() {
        return !paused_.load() || cancelled_.load();
    });
}

void NativeChallengeArenaPool::worker() {
    // A worker owns and reuses exactly one backend per agent. Controller match
    // ledgers, child processes and plan caches are never shared concurrently.
    std::unique_ptr<ChallengeArenaAgent> candidate_agent =
        make_challenge_arena_agent(candidate_, catalog_, decks_);
    std::unique_ptr<ChallengeArenaAgent> baseline_agent =
        make_challenge_arena_agent(baseline_, catalog_, decks_);
    {
        std::lock_guard<std::mutex> lock(controllers_mutex_);
        active_agents_.push_back(candidate_agent.get());
        active_agents_.push_back(baseline_agent.get());
    }

    while (!cancelled_) {
        wait_if_paused();
        if (cancelled_) break;
        const std::size_t index = next_task_.fetch_add(1);
        if (index >= tasks_.size()) break;
        ChallengeArenaGameResult result;
        try {
            const bool candidate_ok = candidate_agent->ready();
            const bool baseline_ok = baseline_agent->ready();
            if (!candidate_ok && !baseline_ok) {
                result = task_result(tasks_[index]);
                infrastructure_failure(
                    result,
                    "both_agents_configuration_failed",
                    "candidate=" + candidate_agent->configuration_error()
                        + ";baseline=" + baseline_agent->configuration_error());
                finalize_semantic_hash(result);
            } else if (!candidate_ok) {
                result = task_result(tasks_[index]);
                ++result.controller_failures;
                adjudicate_agent_failure(
                    result, 0, "candidate_configuration",
                    candidate_agent->configuration_error());
                finalize_semantic_hash(result);
            } else if (!baseline_ok) {
                result = task_result(tasks_[index]);
                ++result.controller_failures;
                adjudicate_agent_failure(
                    result, 1, "baseline_configuration",
                    baseline_agent->configuration_error());
                finalize_semantic_hash(result);
            } else {
                result = run_game(
                    tasks_[index], *candidate_agent, *baseline_agent);
            }
        } catch (const std::exception &error) {
            result = task_result(tasks_[index]);
            infrastructure_failure(
                result, "rule_exception", error.what());
            finalize_semantic_hash(result);
        } catch (...) {
            result = task_result(tasks_[index]);
            infrastructure_failure(
                result, "rule_exception", "unknown_challenge_arena_error");
            finalize_semantic_hash(result);
        }
        if (result.success) ++completed_games_;
        else ++failed_games_;
        decisions_ += result.decisions;
        invalid_actions_ += result.invalid_actions;
        illegal_choices_ += result.illegal_choices;
        controller_failures_ += result.controller_failures;
        rule_exceptions_ += result.rule_exceptions;
        truncated_games_ += result.truncated ? 1U : 0U;
        candidate_decision_us_ += result.candidate_decision_us;
        baseline_decision_us_ += result.baseline_decision_us;
        candidate_nodes_ += result.candidate_nodes;
        baseline_nodes_ += result.baseline_nodes;
        projection_us_ += result.projection_us;
        legal_actions_us_ += result.legal_actions_us;
        apply_us_ += result.apply_us;
        std::lock_guard<std::mutex> lock(results_mutex_);
        results_.push_back(std::move(result));
    }
    {
        std::lock_guard<std::mutex> lock(controllers_mutex_);
        active_agents_.erase(std::remove(
            active_agents_.begin(), active_agents_.end(),
            candidate_agent.get()), active_agents_.end());
        active_agents_.erase(std::remove(
            active_agents_.begin(), active_agents_.end(),
            baseline_agent.get()), active_agents_.end());
    }
    if (active_workers_.fetch_sub(1) == 1) {
        running_ = false;
        finished_ = true;
        completion_ready_.notify_all();
    }
}

ChallengeArenaGameResult NativeChallengeArenaPool::run_game(
    const ChallengeArenaTask &task,
    ChallengeArenaAgent &candidate_agent,
    ChallengeArenaAgent &baseline_agent
) {
    ChallengeArenaGameResult summary = task_result(task);
    const std::vector<std::string> candidate_deck = expand_deck(
        decks_, task.candidate_deck);
    const std::vector<std::string> baseline_deck = expand_deck(
        decks_, task.baseline_deck);
    Array seat_decks(2);
    Array deck_keys(2);
    seat_decks[static_cast<std::size_t>(task.candidate_seat)] =
        deck_value(candidate_deck);
    seat_decks[static_cast<std::size_t>(1 - task.candidate_seat)] =
        deck_value(baseline_deck);
    deck_keys[static_cast<std::size_t>(task.candidate_seat)] =
        Value(task.candidate_deck);
    deck_keys[static_cast<std::size_t>(1 - task.candidate_seat)] =
        Value(task.baseline_deck);

    RulesSession session;
    std::array<Array, 2> public_histories{};
    const RulesSessionResult created = session.create(
        catalog_,
        Value(std::move(seat_decks)),
        Value(Object{
            {"public_deck_keys", Value(std::move(deck_keys))},
            {"player_names", Value(Array{
                Value("Arena-Seat-0"), Value("Arena-Seat-1"),
            })},
            {"rules_profile_id", Value("CN_MAINLAND_3_1_0")},
            {"rules_options", Value(Object{
                {"apply_type_matchups", Value(false)},
            })},
        }),
        task.game_seed);
    if (!created.success) {
        infrastructure_failure(
            summary, "rules_create",
            "challenge_arena_create_failed:" + created.error_code);
        summary.failure_trace = failure_trace(
            session,
            Value(Object{{"error_code", Value(created.error_code)}}),
            config_.capture_failure_trace);
        finalize_from_session(summary, session);
        return summary;
    }
    append_public_history(public_histories, created.events);

    const std::string match_id = "challenge-arena:" + task.task_id;
    const Value candidate_reset = candidate_agent.reset_match(match_id);
    const Value baseline_reset = baseline_agent.reset_match(match_id);
    const bool candidate_reset_ok = bool_field(candidate_reset, "success");
    const bool baseline_reset_ok = bool_field(baseline_reset, "success");
    if (!candidate_reset_ok && !baseline_reset_ok) {
        infrastructure_failure(
            summary,
            "both_agents_reset_failed",
            "candidate=" + string_field(candidate_reset, "error")
                + ";baseline=" + string_field(baseline_reset, "error"));
        finalize_from_session(summary, session);
        return summary;
    }
    if (!candidate_reset_ok || !baseline_reset_ok) {
        ++summary.controller_failures;
        const std::int32_t offending = candidate_reset_ok ? 1 : 0;
        const Value &failed = candidate_reset_ok ? baseline_reset : candidate_reset;
        adjudicate_agent_failure(
            summary,
            offending,
            "agent_reset_failed",
            string_field(failed, "error", "agent_reset_failed"));
        finalize_from_session(summary, session);
        return summary;
    }

    for (std::uint32_t step = 0; step < task.max_decisions; ++step) {
        if (cancelled_) {
            cancellation_failure(summary);
            summary.failure_trace = failure_trace(
                session, Value(Object{{"step", Value(static_cast<std::int64_t>(
                    step))}}),
                config_.capture_failure_trace);
            finalize_from_session(summary, session);
            return summary;
        }
        wait_if_paused();

        const Value state = session.snapshot();
        if (terminal_state(state)) {
            summary.success = true;
            summary.terminal = true;
            set_winner(summary, static_cast<std::int32_t>(
                integer_field(state, "winner", -1)));
            finalize_from_session(summary, session);
            return summary;
        }

        Value pending;
        std::int32_t actor = -1;
        for (std::int32_t seat = 0; seat < 2; ++seat) {
            pending = session.pending_choice(seat);
            if (nonempty_object(pending)) {
                actor = seat;
                break;
            }
        }
        if (actor < 0) actor = state_actor(state);
        if (actor < 0 || actor > 1) {
            infrastructure_failure(
                summary, "decision_actor",
                "challenge_arena_invalid_decision_actor");
            summary.failure_trace = failure_trace(
                session,
                Value(Object{{"state", state}}),
                config_.capture_failure_trace);
            finalize_from_session(summary, session);
            return summary;
        }

        if (string_field(pending, "request_type") == "choose_turn_order") {
            const auto apply_started = Clock::now();
            const RulesSessionResult applied = session.apply_choice(
                forced_turn_order_response(pending, task.first_player));
            summary.apply_us += elapsed_us(apply_started);
            if (!applied.success) {
                infrastructure_failure(
                    summary, "turn_order",
                    "challenge_arena_turn_order_failed:" + applied.error_code);
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"choice", pending},
                        {"error_code", Value(applied.error_code)},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
            append_public_history(public_histories, applied.events);
            const Value turn_order_state = session.snapshot();
            if (integer_field(turn_order_state, "first_player_idx", -1)
                != task.first_player) {
                infrastructure_failure(
                    summary, "turn_order",
                    "challenge_arena_first_player_closure_failed");
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"expected_first_player", Value(task.first_player)},
                        {"actual_first_player", Value(integer_field(
                            turn_order_state, "first_player_idx", -1))},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
            continue;
        }

        const bool choice = nonempty_object(pending);
        const bool candidate_turn = actor == task.candidate_seat;
        ChallengeArenaAgent &controller = candidate_turn
            ? candidate_agent : baseline_agent;
        const ChallengeArenaAgentSpec &agent = candidate_turn
            ? candidate_ : baseline_;

        const auto projection_started = Clock::now();
        Value observation = session.ai_observation_for(actor);
        if (!observation.is_object() || observation.as_object().empty()) {
            throw std::runtime_error("challenge_arena_public_view_unavailable");
        }
        summary.projection_us += elapsed_us(projection_started);
        const std::uint32_t seed = decision_seed(task, session, actor, choice);
        const std::string request_id = match_id + ":"
            + std::to_string(session.revision()) + (choice ? ":choice" : ":action");
        Value request(Object{
            {"kind", Value(choice ? "choice" : "action")},
            {"actor", Value(actor)},
            {"revision", Value(session.revision())},
            {"request_id", Value(request_id)},
            {"state", observation},
            {"public_snapshot", observation},
            {"public_history", Value(public_histories[
                static_cast<std::size_t>(actor)])},
            {"deck_key", Value(candidate_turn
                ? task.candidate_deck : task.baseline_deck)},
            {"match_seed", Value(static_cast<std::int64_t>(task.game_seed))},
            {"seed", Value(static_cast<std::int64_t>(seed))},
            {"match_instance_id", Value(match_id)},
        });
        add_evaluation_options(request, agent.evaluation_options);

        Value authoritative_actions;
        if (choice) {
            request["choice"] = pending;
            // Choice request IDs are authoritative protocol IDs, not Arena
            // correlation IDs.
            request["request_id"] = Value(string_field(pending, "request_id"));
        } else {
            const auto legal_started = Clock::now();
            authoritative_actions =
                session.search_legal_action_candidates(actor).deep_clone();
            summary.legal_actions_us += elapsed_us(legal_started);
            if (!authoritative_actions.is_array()
                || authoritative_actions.as_array().empty()) {
                infrastructure_failure(
                    summary, "legal_actions",
                    "challenge_arena_authoritative_actions_empty");
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"public_state", observation},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
            request["actions"] = authoritative_actions;
        }

        const auto decide_started = Clock::now();
        const Value decision = controller.decide(
            request, session.revision() + 1);
        const std::uint64_t decide_us = elapsed_us(decide_started);
        ++summary.decisions;
        add_agent_metrics(summary, candidate_turn, decision, decide_us);

        if (!bool_field(decision, "success")) {
            if (cancelled_ && bool_field(decision, "cancelled")) {
                cancellation_failure(summary);
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"controller_result", decision},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
            ++summary.controller_failures;
            const std::int32_t offending = candidate_turn ? 0 : 1;
            adjudicate_agent_failure(
                summary, offending, "controller_failure",
                string_field(decision, "error", "challenge_controller_failed"));
            summary.failure_trace = failure_trace(
                session,
                Value(Object{
                    {"actor", Value(actor)},
                    {"offending_agent", Value(offending)},
                    {"request", request},
                    {"controller_result", decision},
                    {"public_state_hash", Value(canonical_value_hash(observation))},
                }),
                config_.capture_failure_trace);
            finalize_from_session(summary, session);
            return summary;
        }
        if (!choice) {
            const Value *performance = field(
                decision, "native_performance_counters");
            if (performance == nullptr || !performance->is_object()
                || integer_field(*performance, "search_worker_count", -1) != 1) {
                infrastructure_failure(
                    summary, "search_contract",
                    "challenge_arena_inner_search_worker_contract_failed");
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"controller_result", decision},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
        }

        Value trace_row(Object{
            {"step", Value(static_cast<std::int64_t>(step))},
            {"revision", Value(session.revision())},
            {"actor", Value(actor)},
            {"agent", Value(candidate_turn ? 0 : 1)},
            {"kind", Value(choice ? "choice" : "action")},
            {"decision_seed", Value(static_cast<std::int64_t>(seed))},
            {"decision_us", Value(static_cast<std::int64_t>(decide_us))},
            {"nodes", Value(integer_field(
                decision, "nodes_expanded",
                integer_field(decision, "simulations", 0)))},
            {"public_state_hash", Value(canonical_value_hash(observation))},
        });
        if (config_.capture_all_decisions) {
            trace_row["public_state"] = observation;
            trace_row["controller_result"] = decision;
        }

        RulesSessionResult applied;
        if (choice) {
            const Value *response = field(decision, "choice_response");
            std::string validation_error;
            if (response == nullptr || !validate_choice_response(
                    pending, *response, &validation_error)) {
                ++summary.illegal_choices;
                const std::int32_t offending = candidate_turn ? 0 : 1;
                adjudicate_agent_failure(
                    summary, offending, "illegal_choice",
                    validation_error.empty()
                        ? "challenge_choice_response_missing"
                        : validation_error);
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"offending_agent", Value(offending)},
                        {"choice", pending},
                        {"returned_response", response == nullptr
                            ? Value() : *response},
                        {"public_state_hash", Value(
                            canonical_value_hash(observation))},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
            trace_row["choice_response"] = *response;
            const auto apply_started = Clock::now();
            applied = session.apply_choice(*response);
            summary.apply_us += elapsed_us(apply_started);
            if (!applied.success) {
                ++summary.illegal_choices;
                const std::int32_t offending = candidate_turn ? 0 : 1;
                adjudicate_agent_failure(
                    summary, offending, "illegal_choice",
                    "authoritative_choice_rejected:" + applied.error_code);
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"offending_agent", Value(offending)},
                        {"choice", pending},
                        {"returned_response", *response},
                        {"error_code", Value(applied.error_code)},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
        } else {
            const Value *returned_action = field(decision, "action");
            std::string returned_signature;
            const Value *matched = returned_action == nullptr ? nullptr
                : unique_action_match(
                    authoritative_actions, *returned_action, &returned_signature);
            if (matched == nullptr) {
                ++summary.invalid_actions;
                const std::int32_t offending = candidate_turn ? 0 : 1;
                adjudicate_agent_failure(
                    summary, offending, "invalid_action",
                    "challenge_action_not_uniquely_legal");
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"offending_agent", Value(offending)},
                        {"returned_action", returned_action == nullptr
                            ? Value() : *returned_action},
                        {"returned_signature", Value(returned_signature)},
                        {"legal_action_signatures", legal_signatures(
                            authoritative_actions)},
                        {"public_state_hash", Value(
                            canonical_value_hash(observation))},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
            trace_row["action_signature"] = Value(returned_signature);
            Value authoritative_action = *matched;
            authoritative_action["action_id"] = Value(
                "challenge-arena:" + task.task_id + ":"
                + std::to_string(session.revision()));
            authoritative_action["base_revision"] = Value(session.revision());
            const auto apply_started = Clock::now();
            applied = session.apply_action(authoritative_action);
            summary.apply_us += elapsed_us(apply_started);
            if (!applied.success) {
                infrastructure_failure(
                    summary, "authoritative_apply",
                    "matched_action_rejected:" + applied.error_code);
                summary.failure_trace = failure_trace(
                    session,
                    Value(Object{
                        {"actor", Value(actor)},
                        {"matched_action", authoritative_action},
                        {"error_code", Value(applied.error_code)},
                        {"legal_action_signatures", legal_signatures(
                            authoritative_actions)},
                    }),
                    config_.capture_failure_trace);
                finalize_from_session(summary, session);
                return summary;
            }
        }
        append_public_history(public_histories, applied.events);
        if (config_.capture_all_decisions) {
            summary.decision_trace.as_array().push_back(std::move(trace_row));
        }
    }

    const Value final_state = session.snapshot();
    if (terminal_state(final_state)) {
        summary.success = true;
        summary.terminal = true;
        set_winner(summary, static_cast<std::int32_t>(
            integer_field(final_state, "winner", -1)));
    } else {
        summary.success = true;
        summary.terminal = false;
        summary.truncated = true;
        summary.strength_eligible = false;
        summary.candidate_score_x2 = 1;
        summary.failure_kind = "truncated";
        summary.error = "challenge_arena_decision_cap";
        summary.failure_trace = failure_trace(
            session,
            Value(Object{
                {"max_decisions", Value(static_cast<std::int64_t>(
                    task.max_decisions))},
            }),
            config_.capture_failure_trace);
    }
    finalize_from_session(summary, session);
    return summary;
}

} // namespace ptcg::ai

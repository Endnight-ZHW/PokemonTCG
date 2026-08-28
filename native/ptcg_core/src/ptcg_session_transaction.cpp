#include "ptcg_rules_session.hpp"
#include "ptcg_session_internal.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <unordered_map>
#include <utility>


namespace ptcg::ai {

using namespace session_detail;

RulesSessionResult RulesSession::apply_action(const Value &submitted_action) {
    return apply_action_impl(submitted_action, false);
}

RulesSessionResult RulesSession::apply_action_for_search(
    const Value &submitted_action
) {
    if (!search_mode_) {
        return result(
            false,
            "search_action_requires_search_fork",
            "search_action_requires_search_fork"
        );
    }
    return apply_action_impl(submitted_action, true);
}

RulesSessionResult RulesSession::apply_action_impl(
    const Value &submitted_action,
    bool use_search_candidate_cache
) {
    if (!initialized_) {
        return result(false, "not_started", "not_started");
    }
    if (!pending_.is_null()) {
        return result(false, "pending_choice", "pending_choice");
    }
    const std::string shape_error = validate_action_shape(submitted_action);
    if (!shape_error.empty()) {
        return result(false, shape_error, shape_error);
    }
    const std::int64_t revision_before = revision();
    Value action = submitted_action.deep_clone();
    const std::string action_id = string_field(action, "action_id");
    const Value *processed = state_.find("processed_action_ids");
    if (
        processed != nullptr && processed->is_array()
        && std::any_of(
            processed->as_array().begin(), processed->as_array().end(),
            [&action_id](const Value &entry) {
                return entry.string_or() == action_id;
            })
    ) {
        return result(false, "duplicate_action", "duplicate_action");
    }
    if (integer_field(submitted_action, "base_revision", -1) != revision_before) {
        return result(false, "stale_revision", "stale_revision");
    }
    const std::int32_t action_actor = static_cast<std::int32_t>(
        integer_field(action, "actor", -1));
    bool legal = false;
    if (
        use_search_candidate_cache
        && legal_cache_revision_ == revision_before
        && legal_cache_actor_ == action_actor
        && legal_cache_candidates_.is_array()
        && typed_legal_cache_
    ) {
        typed::Action typed_action;
        std::string typed_error;
        if (catalog_->state_codec.decode_action(
            action, typed_action, &typed_error)
        ) {
            const auto matched = std::find_if(
                typed_legal_cache_->begin(), typed_legal_cache_->end(),
                [&typed_action](const typed::Action &candidate) {
                    return typed_action_equivalent(typed_action, candidate);
                });
            const std::size_t index = static_cast<std::size_t>(
                std::distance(typed_legal_cache_->begin(), matched));
            legal = matched != typed_legal_cache_->end()
                && index < legal_cache_candidates_.as_array().size()
                && action_equivalent(
                    action, legal_cache_candidates_.as_array()[index]);
        }
    } else {
        const Value candidates = game().legal_actions(state_, action_actor);
        legal = candidates.is_array()
            && std::any_of(
                candidates.as_array().begin(), candidates.as_array().end(),
                [&action](const Value &candidate) {
                    return action_equivalent(action, candidate);
                });
    }
    if (!legal) {
        return result(false, "illegal_action", "illegal_action");
    }

    if (string_field(action, "kind") == "SETUP_DONE") {
        const Value previous_state = state_;
        const auto previous_authoritative_state = authoritative_state_;
        Value next = state_;
        next["revision"] = Value(revision_before + 1);
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_field(action, "actor", -1));
        std::vector<Value> events;
        const std::string stage = string_field(next, "setup_stage");
        if (stage == "BONUS_PLACEMENT") {
            finish_setup(next, events);
        } else if (stage == "INITIAL_PLACEMENT") {
            Value &ready = required(next, "setup_ready");
            ready.as_array()[static_cast<std::size_t>(actor)] = Value(true);
            if (
                !ready.as_array()[0].as_bool()
                || !ready.as_array()[1].as_bool()
            ) {
                next["setup_actor_idx"] = Value(1 - actor);
            } else {
                set_prizes(next);
                const Array &mulligans = required(next, "mulligan_count").as_array();
                std::int32_t bonus_player = -1;
                if (mulligans[1].as_integer() > mulligans[0].as_integer()) {
                    bonus_player = 0;
                } else if (mulligans[0].as_integer() > mulligans[1].as_integer()) {
                    bonus_player = 1;
                }
                if (
                    bonus_player >= 0
                    && integer_field(next, "mulligan_bonus_max") > 0
                ) {
                    next["setup_stage"] = Value("BONUS_DRAW");
                    next["setup_actor_idx"] = Value(bonus_player);
                } else {
                    finish_setup(next, events);
                }
            }
        } else {
            return result(false, "invalid_setup_stage", "invalid_setup_stage");
        }
        state_ = std::move(next);
        Array &ids = required(state_, "processed_action_ids").as_array();
        ids.emplace_back(action_id);
        if (ids.size() > 256) {
            ids.erase(ids.begin());
        }
        if (string_field(state_, "setup_stage") == "BONUS_DRAW") {
            const std::int32_t bonus_player = static_cast<std::int32_t>(
                integer_field(state_, "setup_actor_idx"));
            Array options;
            for (
                std::int64_t count = 0;
                count <= integer_field(state_, "mulligan_bonus_max");
                ++count
            ) {
                options.emplace_back(Object{
                    {"option_id", Value("draw:" + std::to_string(count))},
                    {"label", Value("抽" + std::to_string(count) + "张")},
                });
            }
            pending_ = setup_choice(
                state_, bonus_player, "choose_mulligan_draw_count",
                "请选择再战奖励抽牌数。", options,
                "choose_mulligan_draw_count");
            pending_raw_ = pending_;
            continuation_ = Value(Object{
                {"kind", Value("setup_mulligan_draw")},
                {"actor", Value(bonus_player)},
                {"max_draw", Value(integer_field(state_, "mulligan_bonus_max"))},
            });
            materialize_resolution_stack();
        } else {
            clear_resolution_stack();
        }
        append_submitted_action_log(
            state_, cards(), previous_state, action);
        append_public_event_logs(
            state_, cards(), previous_state, events);
        std::string typed_error;
        if (!commit_authoritative_state(&typed_error)) {
            state_ = previous_state;
            authoritative_state_ = previous_authoritative_state;
            pending_ = Value();
            pending_raw_ = Value();
            continuation_ = Value();
            return result(false, typed_error, typed_error);
        }
        append_journal_entry("action", action, revision_before, events);
        return result(true, {}, "action_applied", std::move(events));
    }

    // Value is recursively copy-on-write. Passing a shallow branch here keeps
    // the parent immutable while cloning only paths the rule actually mutates.
    GameExecutionResult native_result = game().apply_action(
        state_, action, rng_state_);
    if (native_result.success) {
        Value &ids = required(native_result.state, "processed_action_ids");
        ids.as_array().emplace_back(action_id);
        if (ids.as_array().size() > 256) {
            ids.as_array().erase(ids.as_array().begin());
        }
        if (
            string_field(state_, "setup_stage") == "BONUS_PLACEMENT"
            && string_field(action, "kind") == "PLAY_BASIC"
        ) {
            const std::int32_t actor = static_cast<std::int32_t>(
                integer_field(action, "actor"));
            const Value *source = action.find("source");
            const std::string card_id = source == nullptr
                ? std::string{} : string_field(*source, "card_id");
            Value &bonus_rows = required(native_result.state, "setup_bonus_card_ids");
            Array &bonus = bonus_rows.as_array()[static_cast<std::size_t>(actor)].as_array();
            const auto found = std::find_if(
                bonus.begin(), bonus.end(),
                [&card_id](const Value &entry) {
                    return entry.string_or() == card_id;
                });
            if (found != bonus.end()) {
                bonus.erase(found);
            }
        }
        if (
            string_field(state_, "setup_stage") != "COMPLETE"
            && string_field(action, "kind") == "PLAY_BASIC"
        ) {
            const std::int32_t actor = static_cast<std::int32_t>(
                integer_field(action, "actor", -1));
            const std::string name = actor >= 0 && actor <= 1
                ? string_field(player(native_result.state, actor), "name")
                : std::string("玩家");
            required(native_result.state, "action_log").as_array().emplace_back(
                name + " 暗置宝可梦。"
            );
        }
        if (
            (string_field(action, "kind") == "PLAY_TRAINER"
                || string_field(action, "kind") == "RETREAT")
            && native_result.pending.is_object()
            && !native_result.pending.as_object().empty()
            && bool_field(native_result.pending, "can_cancel")
        ) {
            if (
                !native_result.continuation.is_object()
                || native_result.continuation.as_object().empty()
            ) {
                native_result.success = false;
                native_result.error_code = "missing_cancel_continuation";
            } else {
                Value *metadata = native_result.pending.find("metadata");
                if (metadata == nullptr || !metadata->is_object()) {
                    native_result.pending["metadata"] = Value::make_object();
                    metadata = native_result.pending.find("metadata");
                }
                (*metadata)["cancels_action"] = Value(true);
                const std::vector<Value> deferred_events = canonical_events(
                    native_result,
                    &state_,
                    &native_result.state,
                    &action,
                    static_cast<std::int32_t>(integer_field(
                        action, "actor", -1))
                );
                native_result.continuation["session_transaction"] = Value(Object{
                    {"state", state_},
                    {"rng_state", Value(static_cast<std::int64_t>(rng_state_))},
                    {"deferred_events", Value(deferred_events)},
                    {"action", action.deep_clone()},
                });
                native_result.events.clear();
                native_result.event_types.clear();
            }
        }
    }
    return commit_game_result(
        native_result, "action", action, revision_before);
}

RulesSessionResult RulesSession::apply_choice(const Value &response) {
    if (!initialized_) {
        return result(false, "not_started", "not_started");
    }
    if (pending_.is_null()) {
        return result(false, "stale_choice", "stale_choice");
    }
    const std::string response_shape_error = validate_choice_response_shape(
        response);
    if (!response_shape_error.empty()) {
        return result(false, response_shape_error, response_shape_error);
    }
    if (
        string_field(response, "request_id")
            != string_field(pending_, "request_id")
        || integer_field(pending_, "base_revision", -1) != revision()
    ) {
        return result(false, "stale_choice", "stale_choice");
    }
    const bool cancelled = bool_field(response, "cancelled");
    const Value *selected_value = response.find("option_ids");
    if (selected_value == nullptr || !selected_value->is_array()) {
        return result(false, "invalid_choice", "invalid_choice");
    }
    const Array &selected_ids = selected_value->as_array();
    if (cancelled && !bool_field(pending_, "can_cancel")) {
        return result(
            false,
            "choice_not_cancellable",
            "choice_not_cancellable"
        );
    }
    if (!bool_field(pending_, "allow_duplicates")) {
        std::unordered_set<std::string> unique;
        for (const Value &selected_id : selected_ids) {
            if (!unique.insert(selected_id.string_or()).second) {
                return result(false, "duplicate_choice", "duplicate_choice");
            }
        }
    }
    if (
        !cancelled && (
            selected_ids.size() < static_cast<std::size_t>(
                std::max<std::int64_t>(0, integer_field(pending_, "min_select")))
            || selected_ids.size() > static_cast<std::size_t>(
                std::max<std::int64_t>(0, integer_field(pending_, "max_select")))
        )
    ) {
        return result(false, "choice_count", "choice_count");
    }
    Array raw_selected;
    if (!cancelled) {
        const Array &public_options = required(pending_, "options").as_array();
        const Array &raw_options = required(pending_raw_, "options").as_array();
        for (const Value &selected_id_value : selected_ids) {
            const std::string selected_id = selected_id_value.string_or();
            std::size_t matched = public_options.size();
            for (std::size_t index = 0; index < public_options.size(); ++index) {
                if (string_field(public_options[index], "option_id") == selected_id) {
                    matched = index;
                    break;
                }
            }
            if (matched >= public_options.size() || matched >= raw_options.size()) {
                return result(false, "invalid_choice", "invalid_choice");
            }
            raw_selected.push_back(raw_options[matched]);
        }
    }
    const std::int64_t revision_before = revision();
    const std::string continuation_kind = string_field(continuation_, "kind");
    if (continuation_kind == "setup_turn_order") {
        const Value previous_state = state_;
        const Value previous_pending = pending_;
        const Value previous_pending_raw = pending_raw_;
        const Value previous_continuation = continuation_;
        const auto previous_authoritative_state = authoritative_state_;
        if (cancelled || selected_ids.size() != 1) {
            return result(false, "choice_count", "choice_count");
        }
        const std::string selected = selected_ids.front().string_or();
        if (selected != "turn:first" && selected != "turn:second") {
            return result(false, "invalid_choice", "invalid_choice");
        }
        Value next = state_;
        const std::int32_t coin_winner = static_cast<std::int32_t>(
            integer_field(next, "opening_coin_winner_idx"));
        const std::int32_t first = selected == "turn:first"
            ? coin_winner : 1 - coin_winner;
        next["revision"] = Value(revision_before + 1);
        next["first_player_idx"] = Value(first);
        next["active_player_idx"] = Value(first);
        std::vector<Value> events{
            event("turn_order_chosen", coin_winner, Value(Object{
                {"coin_winner", Value(coin_winner)},
                {"first_player", Value(first)},
            }))
        };
        XorShift32 rng(rng_state_);
        const std::string opening_error = prepare_opening_hands(
            cards(), next, rng, events);
        if (!opening_error.empty()) {
            return result(false, opening_error, opening_error);
        }
        state_ = std::move(next);
        rng_state_ = rng.state();
        pending_ = Value();
        pending_raw_ = Value();
        continuation_ = Value();
        clear_resolution_stack();
        append_choice_action_log(
            state_, previous_state, previous_pending, response);
        append_public_event_logs(
            state_, cards(), previous_state, events);
        std::string typed_error;
        if (!commit_authoritative_state(&typed_error)) {
            state_ = previous_state;
            pending_ = previous_pending;
            pending_raw_ = previous_pending_raw;
            continuation_ = previous_continuation;
            authoritative_state_ = previous_authoritative_state;
            return result(false, typed_error, typed_error);
        }
        append_journal_entry("choice", response, revision_before, events);
        return result(true, {}, "choice_applied", std::move(events));
    }
    if (continuation_kind == "setup_mulligan_draw") {
        const Value previous_state = state_;
        const Value previous_pending = pending_;
        const Value previous_pending_raw = pending_raw_;
        const Value previous_continuation = continuation_;
        const auto previous_authoritative_state = authoritative_state_;
        if (cancelled || selected_ids.size() != 1) {
            return result(false, "choice_count", "choice_count");
        }
        const std::string selected = selected_ids.front().string_or();
        if (selected.rfind("draw:", 0) != 0) {
            return result(false, "invalid_choice", "invalid_choice");
        }
        const std::string amount_text = selected.substr(5);
        if (
            amount_text.empty()
            || std::any_of(amount_text.begin(), amount_text.end(), [](char value) {
                return !std::isdigit(static_cast<unsigned char>(value));
            })
        ) {
            return result(false, "invalid_choice", "invalid_choice");
        }
        const std::int64_t amount = std::stoll(amount_text);
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_field(continuation_, "actor", -1));
        if (
            actor < 0 || actor > 1 || amount < 0
            || amount > integer_field(continuation_, "max_draw")
        ) {
            return result(false, "invalid_choice", "invalid_choice");
        }
        Value next = state_;
        next["revision"] = Value(revision_before + 1);
        Array drawn = draw_cards(player(next, actor), static_cast<std::size_t>(amount));
        required(next, "extra_draws").as_array()[static_cast<std::size_t>(actor)] =
            Value(static_cast<std::int64_t>(drawn.size()));
        required(next, "setup_bonus_card_ids").as_array()[
            static_cast<std::size_t>(actor)] = Value(drawn);
        std::vector<Value> events;
        if (!drawn.empty()) {
            events.push_back(event(
                "cards_drawn", actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                    {"card_ids", Value(drawn)},
                    {"purpose", Value("mulligan_bonus")},
                }),
                "owner"
            ));
        }
        bool placeable = false;
        const Array &bench = required(player(next, actor), "bench").as_array();
        const bool bench_space = std::any_of(
            bench.begin(), bench.end(), [](const Value &entry) {
                return entry.is_null();
            });
        if (bench_space) {
            placeable = std::any_of(
                drawn.begin(), drawn.end(),
                [this](const Value &entry) {
                    return is_basic_pokemon(cards(), entry.string_or());
                });
        }
        if (placeable) {
            next["setup_stage"] = Value("BONUS_PLACEMENT");
            next["setup_actor_idx"] = Value(actor);
        } else {
            finish_setup(next, events);
        }
        state_ = std::move(next);
        pending_ = Value();
        pending_raw_ = Value();
        continuation_ = Value();
        clear_resolution_stack();
        append_choice_action_log(
            state_, previous_state, previous_pending, response);
        append_public_event_logs(
            state_, cards(), previous_state, events);
        std::string typed_error;
        if (!commit_authoritative_state(&typed_error)) {
            state_ = previous_state;
            pending_ = previous_pending;
            pending_raw_ = previous_pending_raw;
            continuation_ = previous_continuation;
            authoritative_state_ = previous_authoritative_state;
            return result(false, typed_error, typed_error);
        }
        append_journal_entry("choice", response, revision_before, events);
        return result(true, {}, "choice_applied", std::move(events));
    }

    const Value *session_transaction = continuation_.find(
        "session_transaction");
    if (cancelled && session_transaction != nullptr) {
        const Value previous_state = state_;
        const Value previous_pending = pending_;
        const Value previous_pending_raw = pending_raw_;
        const Value previous_continuation = continuation_;
        const auto previous_authoritative_state = authoritative_state_;
        const Value *checkpoint_state = session_transaction->find("state");
        const Value *checkpoint_rng = session_transaction->find("rng_state");
        if (
            !session_transaction->is_object()
            || checkpoint_state == nullptr || !checkpoint_state->is_object()
            || checkpoint_rng == nullptr || !checkpoint_rng->is_number()
        ) {
            return result(
                false,
                "invalid_cancel_checkpoint",
                "invalid_cancel_checkpoint"
            );
        }
        const Value *stored_action = session_transaction->find("action");
        const Value transaction_action = stored_action != nullptr
            ? stored_action->deep_clone() : Value();
        Value restored = checkpoint_state->deep_clone();
        restored["revision"] = Value(revision_before + 1);
        state_ = std::move(restored);
        rng_state_ = static_cast<std::uint32_t>(checkpoint_rng->as_integer());
        pending_ = Value();
        pending_raw_ = Value();
        continuation_ = Value();
        clear_resolution_stack();
        std::vector<Value> events;
        if (
            transaction_action.is_object()
            && string_field(transaction_action, "kind") == "PLAY_TRAINER"
        ) {
            const Value *source = transaction_action.find("source");
            const std::int32_t actor = static_cast<std::int32_t>(
                integer_field(transaction_action, "actor", -1));
            const std::string card_id = source != nullptr && source->is_object()
                ? string_field(*source, "card_id") : std::string{};
            events.push_back(event(
                "card_moved",
                actor,
                Value(Object{
                    {"player", Value(actor)},
                    {"card_id", Value(card_id)},
                    {"card_ids", Value(Array{Value(card_id)})},
                    {"source_zone", Value("discard")},
                    {"target_zone", Value("hand")},
                    {"target_index", Value(source != nullptr
                        ? integer_field(*source, "index", -1) : -1)},
                    {"cause", Value("cancelled_trainer")},
                }),
                "private"
            ));
        }
        append_public_event_logs(
            state_, cards(), previous_state, events);
        std::string typed_error;
        if (!commit_authoritative_state(&typed_error)) {
            state_ = previous_state;
            pending_ = previous_pending;
            pending_raw_ = previous_pending_raw;
            continuation_ = previous_continuation;
            authoritative_state_ = previous_authoritative_state;
            return result(false, typed_error, typed_error);
        }
        append_journal_entry("choice", response, revision_before, events);
        return result(true, {}, "action_cancelled", events);
    }

    Value kernel_state = state_;
    kernel_state["resolution_stack"] = empty_resolution_stack();
    GameExecutionResult native_result = game().resume_choice(
        std::move(kernel_state), continuation_, Value(raw_selected),
        cancelled, rng_state_);
    if (native_result.success && session_transaction != nullptr) {
        const Value *deferred_value = session_transaction->find(
            "deferred_events");
        if (deferred_value == nullptr || !deferred_value->is_array()) {
            return result(
                false,
                "invalid_cancel_checkpoint",
                "invalid_cancel_checkpoint"
            );
        }
        std::vector<Value> combined = deferred_value->as_array();
        const std::vector<Value> choice_events = canonical_events(
            native_result,
            &state_,
            &native_result.state,
            &response,
            static_cast<std::int32_t>(integer_field(
                pending_, "player", -1))
        );
        combined.insert(
            combined.end(), choice_events.begin(), choice_events.end());
        if (
            native_result.pending.is_object()
            && !native_result.pending.as_object().empty()
        ) {
            if (
                !native_result.continuation.is_object()
                || native_result.continuation.as_object().empty()
            ) {
                return result(
                    false,
                    "missing_cancel_continuation",
                    "missing_cancel_continuation"
                );
            }
            Value transaction = session_transaction->deep_clone();
            transaction["deferred_events"] = Value(combined);
            native_result.continuation["session_transaction"] = std::move(
                transaction);
            Value *metadata = native_result.pending.find("metadata");
            if (metadata == nullptr || !metadata->is_object()) {
                native_result.pending["metadata"] = Value::make_object();
                metadata = native_result.pending.find("metadata");
            }
            (*metadata)["cancels_action"] = Value(true);
            native_result.events.clear();
            native_result.event_types.clear();
        } else {
            native_result.events = std::move(combined);
            native_result.event_types.clear();
        }
    }
    return commit_game_result(
        native_result, "choice", response, revision_before);
}

RulesSessionResult RulesSession::concede(std::int32_t actor) {
    if (!initialized_) {
        return result(false, "not_started", "not_started");
    }
    if (actor < 0 || actor > 1) {
        return result(false, "invalid_actor", "invalid_actor");
    }
    if (terminal_from_state(state_)) {
        return result(false, "game_over", "game_over");
    }
    const std::int64_t revision_before = revision();
    const Value previous_state = state_;
    const Value previous_pending = pending_;
    const Value previous_pending_raw = pending_raw_;
    const Value previous_continuation = continuation_;
    const auto previous_authoritative_state = authoritative_state_;
    const std::int32_t winner = 1 - actor;
    state_["revision"] = Value(revision_before + 1);
    state_["winner"] = Value(winner);
    state_["result_status"] = Value("WIN");
    state_["result_reason"] = Value("surrender");
    state_["result_conditions"] = Value(Array{
        Value(winner == 0 ? Array{Value("opponent_surrendered")} : Array{}),
        Value(winner == 1 ? Array{Value("opponent_surrendered")} : Array{}),
    });
    state_["phase"] = Value("GAME_OVER");
    pending_ = Value();
    pending_raw_ = Value();
    continuation_ = Value();
    clear_resolution_stack();
    std::vector<Value> events{event(
        "game_over",
        winner,
        Value(Object{
            {"winner", Value(winner)},
            {"reason", Value("surrender")},
            {"surrendered_player", Value(actor)},
        }),
        "public"
    )};
    const Value input(Object{
        {"command", Value("surrender")},
        {"actor", Value(actor)},
    });
    append_action_log_line(
        state_, public_player_name(previous_state, actor) + " 放弃了对战。");
    append_public_event_logs(
        state_, cards(), previous_state, events);
    std::string typed_error;
    if (!commit_authoritative_state(&typed_error)) {
        state_ = previous_state;
        pending_ = previous_pending;
        pending_raw_ = previous_pending_raw;
        continuation_ = previous_continuation;
        authoritative_state_ = previous_authoritative_state;
        return result(false, typed_error, typed_error);
    }
    append_journal_entry("command", input, revision_before, events);
    return result(true, {}, "player_surrendered", std::move(events));
}
RulesSessionResult RulesSession::commit_game_result(
    const GameExecutionResult &native_result,
    const std::string &entry_kind,
    const Value &input,
    std::int64_t revision_before
) {
    if (!native_result.success) {
        return result(
            false,
            native_result.error_code.empty()
                ? "native_rule_error" : native_result.error_code,
            native_result.error_code.empty()
                ? "native_rule_error" : native_result.error_code
        );
    }
    const Value previous_state = state_;
    const Value previous_pending = pending_;
    const Value previous_pending_raw = pending_raw_;
    const Value previous_continuation = continuation_;
    const Value previous_journal = journal_entries_;
    const auto previous_authoritative_state = authoritative_state_;
    const std::uint32_t previous_rng = rng_state_;
    try {
        const std::int32_t actor_hint = entry_kind == "action"
            ? static_cast<std::int32_t>(integer_field(input, "actor", -1))
            : static_cast<std::int32_t>(integer_field(
                pending_, "player", -1));
        std::vector<Value> events = canonical_events(
            native_result,
            &state_,
            &native_result.state,
            &input,
            actor_hint
        );
        state_ = native_result.state;
        rng_state_ = native_result.rng_state;
        set_pending(native_result.pending, native_result.continuation);
        if (entry_kind == "action") {
            append_submitted_action_log(
                state_, cards(), previous_state, input);
        } else if (entry_kind == "choice") {
            append_choice_action_log(
                state_, previous_state, previous_pending, input);
        }
        append_public_event_logs(
            state_, cards(), previous_state, events);
        std::string typed_error;
        if (!commit_authoritative_state(&typed_error)) {
            throw std::runtime_error(typed_error.empty()
                ? "typed_state_commit_failed" : typed_error);
        }
        append_journal_entry(entry_kind, input, revision_before, events);
        return result(true, {}, entry_kind + "_applied", std::move(events));
    } catch (const std::exception &error) {
        state_ = previous_state;
        pending_ = previous_pending;
        pending_raw_ = previous_pending_raw;
        continuation_ = previous_continuation;
        journal_entries_ = previous_journal;
        authoritative_state_ = previous_authoritative_state;
        rng_state_ = previous_rng;
        const std::string detail = error.what();
        const std::string code = detail.find("typed_") != std::string::npos
            ? detail : "invalid_native_continuation";
        return result(false, code, code);
    }
}

RulesSessionResult RulesSession::result(
    bool success,
    std::string error_code,
    std::string message_key,
    std::vector<Value> events
) const {
    RulesSessionResult output;
    output.success = success;
    output.error_code = std::move(error_code);
    output.message_key = std::move(message_key);
    output.state = initialized_ && authoritative_state_ != nullptr && catalog_
        ? (search_mode_
            ? state_
            : catalog_->state_codec.encode_state(*authoritative_state_))
        : Value::make_object();
    output.pending = success
        ? (search_mode_ ? pending_ : pending_.deep_clone())
        : Value();
    output.events = std::move(events);
    output.rng_state = rng_state_;
    output.winner = initialized_ && authoritative_state_ != nullptr
        ? authoritative_state_->winner : -1;
    output.terminal = initialized_ && authoritative_state_ != nullptr
        && (authoritative_state_->result_status != "ONGOING"
            || authoritative_state_->winner >= 0);
    return output;
}

void RulesSession::materialize_resolution_stack() {
    if (!initialized_) {
        return;
    }
    Array frames;
    if (!continuation_.is_null()) {
        frames.emplace_back(Object{
            {"kind", Value("continuation")},
            {"operation", Value("native_rules_session")},
            {"data", Value(Object{
                {"continuation", continuation_.deep_clone()},
                {"raw_pending", pending_raw_.deep_clone()},
            })},
        });
    }
    state_["resolution_stack"] = Value(Object{
        {"schema_version", Value(3)},
        {"frames", Value(std::move(frames))},
        {"pending_request", pending_.deep_clone()},
        {"sequence", Value(integer_field(state_, "choice_sequence"))},
        {"context", Value::make_object()},
    });
}

void RulesSession::clear_resolution_stack() {
    if (initialized_) {
        state_["resolution_stack"] = empty_resolution_stack();
    }
}

void RulesSession::set_pending(Value pending, Value continuation) {
    typed_pending_cache_.reset();
    typed_pending_cache_revision_ = -1;
    typed_pending_cache_request_id_.clear();
    pending_ = Value();
    pending_raw_ = Value();
    continuation_ = Value();
    const bool has_pending = (
        pending.is_object() && !pending.as_object().empty()
    );
    const bool has_continuation = (
        continuation.is_object() && !continuation.as_object().empty()
    );
    if (has_pending != has_continuation) {
        throw std::invalid_argument("pending_continuation_mismatch");
    }
    if (has_pending) {
        pending_raw_ = pending.deep_clone();
        pending_ = public_choice(state_, pending_raw_);
        const Value *options = pending_.find("options");
        const std::int64_t minimum = integer_field(pending_, "min_select", -1);
        const std::int64_t maximum = integer_field(pending_, "max_select", -1);
        if (
            integer_field(pending_, "schema_version", -1) != 2
            || string_field(pending_, "request_id").empty()
            || integer_field(pending_, "base_revision", -1) != revision()
            || integer_field(pending_, "player", -1) < 0
            || integer_field(pending_, "player", -1) > 1
            || string_field(pending_, "request_type").empty()
            || options == nullptr || !options->is_array()
            || options->as_array().size() > 256
            || minimum < 0 || maximum < minimum || maximum > 256
        ) {
            throw std::invalid_argument("invalid_pending_choice");
        }
        std::unordered_set<std::string> option_ids;
        for (const Value &option : options->as_array()) {
            const std::string option_id = string_field(option, "option_id");
            if (option_id.empty() || !option_ids.insert(option_id).second) {
                throw std::invalid_argument("invalid_pending_options");
            }
        }
        continuation_ = std::move(continuation);
        const Value *vm = continuation_.find("vm");
        if (vm != nullptr && vm->is_object()) {
            const std::string op = string_field(*vm, "op");
            const std::int64_t stage = integer_field(*vm, "stage", -1);
            const std::string request_type = string_field(
                pending_, "request_type"
            );
            const bool reveals_selected_deck_cards = stage == 1 && (
                (op == "look_top_attach_energy"
                    && request_type == "select_energy_target")
                || (op == "look_top_deck"
                    && request_type == "distribute_energy")
            );
            if (reveals_selected_deck_cards) {
                const Value *selected = vm->find("selected_cards");
                const std::int32_t actor = static_cast<std::int32_t>(
                    integer_field(pending_, "player", -1)
                );
                if (
                    selected == nullptr || !selected->is_array()
                    || selected->as_array().empty()
                    || selected->as_array().size() > 64
                ) {
                    throw std::invalid_argument(
                        "invalid_revealed_selected_cards"
                    );
                }
                Array revealed;
                revealed.reserve(selected->as_array().size());
                for (const Value &card : selected->as_array()) {
                    const std::string card_id = string_field(card, "card_id");
                    if (
                        !card.is_object()
                        || string_field(card, "kind") != "card"
                        || integer_field(card, "player", -1) != actor
                        || string_field(card, "zone") != "deck"
                        || integer_field(card, "index", -1) < 0
                        || card_id.empty()
                    ) {
                        throw std::invalid_argument(
                            "invalid_revealed_selected_card"
                        );
                    }
                    revealed.emplace_back(card_id);
                }
                Value *presentation = pending_.find("presentation");
                if (presentation == nullptr || !presentation->is_object()) {
                    throw std::invalid_argument(
                        "invalid_choice_presentation"
                    );
                }
                (*presentation)["revealed_card_ids"] = Value(
                    std::move(revealed)
                );
                (*presentation)["source_zone"] = Value("deck");
            }
        }
        if (string_field(pending_, "request_type") == "coin_flip") {
            const Value *vm = continuation_.find("vm");
            const Value *flips = vm != nullptr && vm->is_object()
                ? vm->find("flips") : nullptr;
            Value *presentation = pending_.find("presentation");
            if (
                flips != nullptr && flips->is_array()
                && presentation != nullptr && presentation->is_object()
            ) {
                (*presentation)["predetermined_flips"] = flips->deep_clone();
            }
        }
        materialize_resolution_stack();
    } else {
        clear_resolution_stack();
    }
}

} // namespace ptcg::ai

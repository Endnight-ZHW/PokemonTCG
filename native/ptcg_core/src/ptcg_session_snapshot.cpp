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

Value RulesSession::snapshot() const {
    if (!initialized_ || authoritative_state_ == nullptr || !catalog_) {
        return Value::make_object();
    }
    Value result = catalog_->state_codec.encode_state(*authoritative_state_);
    result["snapshot_version"] = Value(SNAPSHOT_SCHEMA_VERSION);
    return result;
}

bool RulesSession::restore(
    const Value &snapshot_value,
    std::uint32_t rng_state,
    std::string *error
) {
    const auto fail = [error](const std::string &message) {
        if (error != nullptr) {
            *error = message;
        }
        return false;
    };
    if (!cards().is_object() || cards().as_object().empty()) {
        return fail("card_catalog_missing");
    }
    if (!snapshot_value.is_object()) {
        return fail("invalid_snapshot");
    }
    if (integer_field(snapshot_value, "snapshot_version", -1)
        != SNAPSHOT_SCHEMA_VERSION) {
        return fail("incompatible_snapshot");
    }
    const std::string payload_error = validate_snapshot_payload(
        snapshot_value, cards());
    if (!payload_error.empty()) {
        return fail(payload_error);
    }
    const Value *players = snapshot_value.find("players");
    if (players == nullptr || !players->is_array() || players->as_array().size() != 2) {
        return fail("invalid_snapshot_players");
    }
    Value next_state = snapshot_value.deep_clone();
    next_state.erase("snapshot_version");
    Value next_pending;
    Value next_pending_raw;
    Value next_continuation;
    const Value *stack = next_state.find("resolution_stack");
    if (stack != nullptr && stack->is_object()) {
        const Value *pending = stack->find("pending_request");
        const Value *frames = stack->find("frames");
        const Value *context = stack->find("context");
        const bool has_pending_request = pending != nullptr && pending->is_object();
        if (
            frames == nullptr || !frames->is_array()
            || frames->as_array().size() != (has_pending_request ? 1U : 0U)
            || context == nullptr || !context->is_object()
            || !context->as_object().empty()
        ) {
            return fail("unsupported_legacy_continuation");
        }
        if (pending != nullptr && pending->is_object()) {
            next_pending_raw = pending->deep_clone();
            next_pending = public_choice(
                next_state,
                *pending,
                string_field(*pending, "request_id")
            );
        }
        if (frames != nullptr && frames->is_array() && !frames->as_array().empty()) {
            const Value &frame = frames->as_array().back();
            if (
                string_field(frame, "kind") != "continuation"
                || string_field(frame, "operation") != "native_rules_session"
            ) {
                return fail("unsupported_legacy_continuation");
            }
            const Value *data = frame.find("data");
            if (data == nullptr || !data->is_object()) {
                return fail("invalid_native_continuation");
            }
            const Value *raw = data->find("raw_pending");
            const Value *continuation = data->find("continuation");
            if (raw != nullptr) {
                next_pending_raw = raw->deep_clone();
            }
            if (continuation != nullptr) {
                next_continuation = continuation->deep_clone();
            }
        }
    }
    if (
        !next_pending.is_null()
        && (
            !next_pending_raw.is_object()
            || !next_continuation.is_object()
            || next_pending_raw.as_object().empty()
            || next_continuation.as_object().empty()
            || next_pending_raw.find("options") == nullptr
            || !next_pending_raw.find("options")->is_array()
            || next_pending_raw.find("options")->as_array().size()
                != next_pending.find("options")->as_array().size()
        )
    ) {
        return fail("invalid_native_continuation");
    }
    if (
        !next_pending.is_null()
        && (
            integer_field(next_pending, "schema_version", -1) != 2
            || string_field(next_pending, "request_id").empty()
            || integer_field(next_pending, "player", -1) < 0
            || integer_field(next_pending, "player", -1) > 1
            || integer_field(next_pending, "base_revision", -1)
                != integer_field(next_state, "revision", -2)
            || next_pending.find("options") == nullptr
            || !next_pending.find("options")->is_array()
        )
    ) {
        return fail("invalid_choice_view");
    }
    const Value *session_transaction = next_continuation.is_object()
        ? next_continuation.find("session_transaction") : nullptr;
    if (session_transaction != nullptr) {
        const Value *checkpoint = session_transaction->find("state");
        const Value *checkpoint_rng = session_transaction->find("rng_state");
        const Value *deferred = session_transaction->find("deferred_events");
        const Value *checkpoint_action = session_transaction->find("action");
        if (
            next_pending.is_null()
            || !session_transaction->is_object()
            || session_transaction->as_object().size() != 4
            || checkpoint == nullptr || !checkpoint->is_object()
            || checkpoint_rng == nullptr || !checkpoint_rng->is_number()
            || checkpoint_rng->as_integer() <= 0
            || checkpoint_rng->as_integer()
                > static_cast<std::int64_t>(std::numeric_limits<std::uint32_t>::max())
            || deferred == nullptr || !deferred->is_array()
            || deferred->as_array().size() > 4096
            || checkpoint_action == nullptr
            || !validate_action_shape(*checkpoint_action).empty()
        ) {
            return fail("invalid_cancel_checkpoint");
        }
        Value checkpoint_snapshot = checkpoint->deep_clone();
        checkpoint_snapshot["snapshot_version"] = Value(SNAPSHOT_SCHEMA_VERSION);
        const std::string checkpoint_error = validate_snapshot_payload(
            checkpoint_snapshot, cards());
        if (!checkpoint_error.empty()) {
            return fail("invalid_cancel_checkpoint");
        }
        for (const Value &deferred_event : deferred->as_array()) {
            if (!deferred_event.is_object()) {
                return fail("invalid_cancel_checkpoint");
            }
        }
    }
    const Value previous_state = state_;
    const auto previous_authoritative_state = authoritative_state_;
    const bool previous_initialized = initialized_;
    state_ = std::move(next_state);
    pending_ = std::move(next_pending);
    pending_raw_ = std::move(next_pending_raw);
    continuation_ = std::move(next_continuation);
    rng_state_ = rng_state == 0 ? 0x6D2B79F5U : rng_state;
    initialized_ = true;
    std::string typed_error;
    if (!commit_authoritative_state(&typed_error)) {
        state_ = previous_state;
        authoritative_state_ = previous_authoritative_state;
        initialized_ = previous_initialized;
        return fail(typed_error.empty()
            ? "typed_state_decode_failed" : typed_error);
    }
    typed_pending_cache_.reset();
    typed_pending_cache_revision_ = -1;
    typed_pending_cache_request_id_.clear();
    return true;
}

} // namespace ptcg::ai

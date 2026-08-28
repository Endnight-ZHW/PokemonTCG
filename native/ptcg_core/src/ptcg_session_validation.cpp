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


namespace ptcg::ai::session_detail {

using Array = Value::Array;
using Object = Value::Object;

bool action_equivalent(const Value &submitted, const Value &candidate) {
    static const std::array<const char *, 6> keys = {
        "schema_version", "base_revision", "actor", "kind", "source", "target",
    };
    for (const char *key : keys) {
        const Value *left = submitted.find(key);
        const Value *right = candidate.find(key);
        if (left == nullptr || right == nullptr || !(*left == *right)) {
            return false;
        }
    }
    const Value *left_payload = submitted.find("payload");
    const Value *right_payload = candidate.find("payload");
    return left_payload != nullptr && right_payload != nullptr
        && *left_payload == *right_payload;
}

std::string validate_action_shape(const Value &action) {
    if (!action.is_object()) {
        return "invalid_schema";
    }
    static const std::unordered_set<std::string> allowed = {
        "schema_version", "action_id", "base_revision", "actor",
        "kind", "source", "target", "payload",
    };
    if (action.as_object().size() != allowed.size()) {
        return "invalid_schema";
    }
    for (const auto &[key, value] : action.as_object()) {
        (void)value;
        if (allowed.find(key) == allowed.end()) {
            return "invalid_schema";
        }
    }
    const Value *schema_version = action.find("schema_version");
    const Value *action_id = action.find("action_id");
    const Value *base_revision = action.find("base_revision");
    const Value *actor = action.find("actor");
    const Value *kind = action.find("kind");
    const Value *payload = action.find("payload");
    const auto wire_integer = [](const Value *value) {
        if (value == nullptr || !value->is_number()) {
            return false;
        }
        const double number = value->as_number();
        return number >= static_cast<double>(
                std::numeric_limits<std::int32_t>::min())
            && number <= static_cast<double>(
                std::numeric_limits<std::int32_t>::max())
            && number == static_cast<double>(value->as_integer());
    };
    if (
        !wire_integer(schema_version)
        || schema_version->as_integer() != 4
        || action_id == nullptr || !action_id->is_string()
        || action_id->as_string().empty() || action_id->as_string().size() > 128
        || !wire_integer(base_revision)
        || base_revision->as_integer() < 0
        || !wire_integer(actor)
        || actor->as_integer() < 0 || actor->as_integer() > 1
        || kind == nullptr || !kind->is_string()
        || kind->as_string().empty() || kind->as_string().size() > 64
        || payload == nullptr || !payload->is_object()
    ) {
        return "invalid_schema";
    }
    const Value *source = action.find("source");
    const Value *target = action.find("target");
    if (
        source == nullptr || target == nullptr
        || (!source->is_null() && !source->is_object())
        || (!target->is_null() && !target->is_object())
    ) {
        return "invalid_schema";
    }
    return {};
}

std::string validate_choice_response_shape(const Value &response) {
    if (!response.is_object() || response.as_object().size() != 3) {
        return "invalid_choice";
    }
    static const std::array<const char *, 3> required_fields = {
        "request_id", "option_ids", "cancelled",
    };
    for (const char *key : required_fields) {
        if (response.find(key) == nullptr) {
            return "invalid_choice";
        }
    }
    const Value *request_id = response.find("request_id");
    const Value *option_ids = response.find("option_ids");
    const Value *cancelled = response.find("cancelled");
    if (
        !request_id->is_string() || request_id->as_string().empty()
        || request_id->as_string().size() > 128
        || !option_ids->is_array() || option_ids->as_array().size() > 60
        || !cancelled->is_bool()
    ) {
        return "invalid_choice";
    }
    for (const Value &option_id : option_ids->as_array()) {
        if (
            !option_id.is_string() || option_id.as_string().empty()
            || option_id.as_string().size() > 128
        ) {
            return "invalid_choice";
        }
    }
    return {};
}


} // namespace ptcg::ai::session_detail

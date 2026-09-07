#pragma once

#include "ptcg_value.hpp"

#include <string>

namespace ptcg::ai::planner_v3 {

// This equivalence is only a dominance check for a consecutive run of pure
// energy transfers which consumed no randomness and revealed no information.
// It must never key evaluation caches: the ignored log is a policy dependency.
inline bool same_energy_transfer_position(const Value &left, const Value &right) {
    if (!left.is_object() || !right.is_object()) return false;
    const auto bookkeeping = [](const std::string &key) {
        return key == "revision" || key == "choice_sequence"
            || key == "processed_action_ids" || key == "action_log";
    };
    const auto empty_resolution = [](const Value &stack) {
        if (!stack.is_object()) return false;
        const auto *frames = stack.find("frames");
        const auto *pending = stack.find("pending_request");
        return frames && frames->is_array() && frames->as_array().empty()
            && pending && pending->is_null();
    };
    const auto *left_stack = left.find("resolution_stack");
    const auto *right_stack = right.find("resolution_stack");
    if (!left_stack || !right_stack || !empty_resolution(*left_stack) || !empty_resolution(*right_stack)) return false;
    for (const auto &[key, value] : left.as_object()) {
        if (bookkeeping(key)) continue;
        const auto *other = right.find(key);
        if (!other) return false;
        if (key == "resolution_stack") {
            if (!empty_resolution(value) || !empty_resolution(*other)) return false;
            for (const auto &[field, entry] : value.as_object()) {
                if (field == "sequence") continue;
                const auto *counterpart = other->find(field);
                if (!counterpart || !(entry == *counterpart)) return false;
            }
            for (const auto &[field, entry] : other->as_object()) {
                if (field != "sequence" && !value.find(field)) return false;
            }
        } else if (!(value == *other)) return false;
    }
    for (const auto &[key, value] : right.as_object()) {
        if (!bookkeeping(key) && !left.find(key)) return false;
    }
    return true;
}

} // namespace ptcg::ai::planner_v3

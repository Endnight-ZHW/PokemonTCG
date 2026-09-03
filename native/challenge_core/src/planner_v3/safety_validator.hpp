#pragma once

#include "ptcg_traditional_search.hpp"

#include <cstdint>
#include <string>

namespace ptcg::ai::planner_v3 {

struct ValidationResult {
    bool valid = false;
    std::string reason;
};

// This validator is deliberately not a second policy. It proves that a
// compiled plan remains legal end-to-end and does not give up a deterministic
// prize/attack outcome already secured by the shadow legacy plan.
class SafetyValidator {
public:
    ValidationResult validate(
        const Value::Array &sequence,
        const Value::Array &legacy_sequence,
        const Value &authoritative_actions,
        const RulesSession &position,
        std::int32_t actor,
        std::uint32_t seed,
        TraditionalSearchProvider &provider,
        bool require_terminal_win = false
    ) const;
};

} // namespace ptcg::ai::planner_v3

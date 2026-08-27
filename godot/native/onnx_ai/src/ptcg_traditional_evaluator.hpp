#pragma once

#include "ptcg_rules_session.hpp"
#include "ptcg_value.hpp"

#include <cstdint>

namespace ptcg::ai {

// Native implementation of AIPositionEvaluator's rules-derived base score.
// Trusted Challenge tactics and deck hooks are deliberately separate additive
// components so each can be differentially replaced without perturbing the
// quantization order.
class TraditionalPositionEvaluator {
public:
    explicit TraditionalPositionEvaluator(Value catalog);

    std::int64_t base_state_score_milli(
        const RulesSession &position,
        std::int32_t actor
    ) const;
    std::int64_t default_action_score_milli(const Value &action) const;

    static std::int64_t quantize(double score) noexcept;

private:
    Value cards_ = Value::make_object();
};

} // namespace ptcg::ai

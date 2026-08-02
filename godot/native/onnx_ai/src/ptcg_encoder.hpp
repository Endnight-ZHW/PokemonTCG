#pragma once

#include "ptcg_ai_core.hpp"
#include "ptcg_value.hpp"

#include <cstdint>

namespace ptcg::ai {

inline constexpr int NATIVE_ENCODER_VERSION = 7;

class NativeInformationSetEncoder {
public:
    explicit NativeInformationSetEncoder(
        Value cards = Value::make_object()
    );

    void set_cards(Value cards);

    Value build_observation(
        const Value &snapshot,
        std::int32_t actor
    ) const;

    InferenceRequest encode_actions(
        const Value &observation,
        const Value &actions
    ) const;

    InferenceRequest encode_choices(
        const Value &observation,
        const Value &request,
        const Value &candidates
    ) const;

private:
    Value cards_;
};

} // namespace ptcg::ai

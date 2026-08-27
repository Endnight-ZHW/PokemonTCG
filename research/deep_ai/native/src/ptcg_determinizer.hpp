#pragma once

#include "ptcg_value.hpp"

#include <cstdint>

namespace ptcg::ai {

class NativeDeterminizer {
public:
    explicit NativeDeterminizer(
        Value deck_specs = Value::make_object()
    );

    void set_decks(Value deck_specs);

    Value determinize(
        const Value &snapshot,
        std::int32_t actor,
        std::uint32_t seed
    ) const;

private:
    Value deck_specs_;
};

} // namespace ptcg::ai

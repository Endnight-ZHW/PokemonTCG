#pragma once

#include "ptcg_value.hpp"

#include <cstdint>
#include <string>

namespace ptcg::ai {

inline constexpr int NATIVE_INFOSET_ABI_VERSION = 1;

struct InformationSetProjection {
    Value observation = Value::make_object();
    std::uint64_t public_hash = 0;
    std::uint64_t actor_private_hash = 0;
    std::uint64_t tree_key = 0;
};

// Validates the client/runtime snapshot boundary. Training may project an
// authoritative state internally, but a runtime request must already have all
// unobservable identities replaced by one of the supported hidden markers.
std::string validate_runtime_snapshot(
    const Value &snapshot,
    std::int32_t actor
);

// Produces the only state representation accepted by the v3 encoder/tree.
// Opponent hidden zones and both players' deck/prize identities are removed.
InformationSetProjection project_information_set(
    const Value &snapshot,
    std::int32_t actor
);

std::uint64_t stable_value_hash(const Value &value) noexcept;

} // namespace ptcg::ai

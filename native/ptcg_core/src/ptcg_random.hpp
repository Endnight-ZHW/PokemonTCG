#pragma once

#include <cstdint>

namespace ptcg::ai {

// Portable deterministic RNG shared by rules, simulation and search.  It is
// intentionally framework-free so ptcg_core does not depend on the AI layer.
class XorShift32 {
public:
    explicit XorShift32(std::uint32_t seed = 0x6D2B79F5u);

    std::uint32_t state() const noexcept;
    void set_state(std::uint32_t state) noexcept;
    std::uint32_t next_u32() noexcept;
    float next_unit() noexcept;

private:
    std::uint32_t state_;
};

} // namespace ptcg::ai

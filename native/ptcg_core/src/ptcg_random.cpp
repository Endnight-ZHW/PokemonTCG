#include "ptcg_random.hpp"

namespace ptcg::ai {

XorShift32::XorShift32(std::uint32_t seed)
    : state_(seed == 0 ? 0x6D2B79F5u : seed) {}

std::uint32_t XorShift32::state() const noexcept {
    return state_;
}

void XorShift32::set_state(std::uint32_t state) noexcept {
    state_ = state == 0 ? 0x6D2B79F5u : state;
}

std::uint32_t XorShift32::next_u32() noexcept {
    std::uint32_t value = state_;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    state_ = value;
    return value;
}

float XorShift32::next_unit() noexcept {
    return static_cast<float>(next_u32()) / 4294967296.0F;
}

} // namespace ptcg::ai

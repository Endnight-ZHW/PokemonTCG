#pragma once

#include "ptcg_rules.hpp"
#include "ptcg_value.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace ptcg::ai {

inline constexpr int NATIVE_GAME_ABI_VERSION = 1;

struct GameExecutionResult {
    bool success = false;
    std::string error_code;
    Value state = Value::make_object();
    Value pending = Value::make_object();
    Value continuation = Value::make_object();
    std::vector<std::string> event_types;
    std::vector<Value> events;
    std::uint32_t rng_state = 0;
};

class NativeGameKernel {
public:
    explicit NativeGameKernel(Value cards = Value::make_object());

    void set_cards(Value cards);
    std::size_t card_count() const noexcept;
    std::size_t implemented_op_count() const noexcept;
    static std::size_t required_op_count() noexcept;
    std::int64_t pokemon_max_hp(const Value &pokemon) const;
    std::int64_t pokemon_current_hp(const Value &pokemon) const;
    std::int64_t estimate_public_damage(
        const Value &state,
        std::int32_t actor,
        const Value &attacker,
        const Value &defender,
        std::int64_t base_damage
    ) const;
    Value legal_actions(
        const Value &state,
        std::int32_t actor
    ) const;
    static Value choice_candidates(const Value &request);

    GameExecutionResult apply_action(
        Value state,
        const Value &action,
        std::uint32_t rng_state
    ) const;
    GameExecutionResult resume_choice(
        Value state,
        const Value &continuation,
        const Value &selected_options,
        bool cancelled,
        std::uint32_t rng_state
    ) const;

private:
    Value cards_;
    NativeRulesKernel rules_;
};

} // namespace ptcg::ai

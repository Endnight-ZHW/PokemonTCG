#pragma once

#include "ptcg_ai_core.hpp"
#include "ptcg_value.hpp"

#include <cstddef>
#include <cstdint>
#include <set>
#include <string>
#include <vector>

namespace ptcg::ai {

inline constexpr int NATIVE_RULES_ABI_VERSION = 1;

struct VmExecutionResult {
    bool success = false;
    std::string error_code;
    Value state = Value::make_object();
    Value context = Value::make_object();
    Value modifier = Value::make_object();
    Value pending = Value::make_object();
    Value continuation = Value::make_object();
    std::vector<std::string> event_types;
    std::vector<Value> events;
    std::uint32_t rng_state = 0;
};

class NativeRulesKernel {
public:
    explicit NativeRulesKernel(Value cards = Value::make_object());

    void set_cards(Value cards);
    std::size_t card_count() const noexcept;
    bool supports(const std::string &op) const noexcept;
    std::size_t implemented_op_count() const noexcept;
    static std::size_t required_op_count() noexcept;
    static const std::set<std::string> &implemented_ops() noexcept;

    VmExecutionResult execute(
        Value state,
        const Value &command_spec,
        std::int32_t actor,
        const std::string &source_slot,
        std::uint32_t seed,
        const std::string &context_mode,
        Value initial_context = Value::make_object()
    ) const;
    VmExecutionResult resume(
        Value state,
        Value context,
        const Value &continuation,
        const Value &selected_options,
        bool cancelled,
        std::uint32_t rng_state
    ) const;

private:
    Value cards_;
};

} // namespace ptcg::ai

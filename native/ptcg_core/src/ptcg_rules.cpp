#include "ptcg_rules.hpp"
#include "ptcg_rules_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <unordered_set>


namespace ptcg::ai {

using namespace rules_detail;

NativeRulesKernel::NativeRulesKernel(Value cards)
    : cards_(std::move(cards)) {
    if (!cards_.is_object()) {
        throw std::invalid_argument("cards_must_be_object");
    }
}

void NativeRulesKernel::set_cards(Value cards) {
    if (!cards.is_object()) {
        throw std::invalid_argument("cards_must_be_object");
    }
    cards_ = std::move(cards);
}

std::size_t NativeRulesKernel::card_count() const noexcept {
    return cards_.is_object() ? cards_.as_object().size() : 0;
}

bool NativeRulesKernel::supports(const std::string &op) const noexcept {
    return IMPLEMENTED_OPS.find(op) != IMPLEMENTED_OPS.end();
}

std::size_t NativeRulesKernel::implemented_op_count() const noexcept {
    return IMPLEMENTED_OPS.size();
}

std::size_t NativeRulesKernel::required_op_count() noexcept {
    return 80;
}

const std::set<std::string> &NativeRulesKernel::implemented_ops() noexcept {
    return IMPLEMENTED_OPS;
}

VmExecutionResult NativeRulesKernel::execute(
    Value state,
    const Value &command_spec,
    std::int32_t actor,
    const std::string &source_slot,
    std::uint32_t seed,
    const std::string &context_mode,
    Value initial_context
) const {
    VmExecutionResult result;
    result.state = std::move(state);
    if (initial_context.is_object()) {
        result.context = std::move(initial_context);
    }
    XorShift32 rng(seed);
    result.rng_state = rng.state();
    if (
        actor != 0
        && actor != 1
    ) {
        result.error_code = "invalid_actor";
        return result;
    }
    if (!command_spec.is_object()) {
        result.error_code = "invalid_command_spec";
        return result;
    }
    const std::string op = string_arg(command_spec, "op");
    if (!supports(op)) {
        result.error_code = "unsupported_native_vm_op";
        return result;
    }
    const Value *args_ptr = command_spec.find("args");
    const Value empty_args = Value::make_object();
    const Value &args = (
        args_ptr != nullptr && args_ptr->is_object()
    ) ? *args_ptr : empty_args;
    if (
        context_mode == "attack"
        && result.context.find("base_damage") == nullptr
    ) {
        result.context["base_damage"] = Value(30);
    }

    try {
        Value &self = player(result.state, actor);
        Value &opponent = player(result.state, 1 - actor);
        Value *source = pokemon(self, source_slot);
        Value *opponent_active = pokemon(opponent, "active");
        auto suspend = [&result](Value request, Value continuation) {
            increment_integer(result.state, "choice_sequence");
            result.pending = std::move(request);
            result.continuation = std::move(continuation);
        };

        bool early_return = false;
        bool handled = execute_vm_modifier_pipeline(
            cards_, command_spec, op, args, actor, source_slot,
            context_mode, rng, result, early_return);
        if (!handled) handled = execute_vm_damage_pipeline(
            cards_, command_spec, op, args, actor, source_slot,
            context_mode, rng, result, early_return);
        if (!handled) handled = execute_vm_card_pipeline(
            cards_, command_spec, op, args, actor, source_slot,
            context_mode, rng, result, early_return);
        if (!handled) handled = execute_vm_trigger_pipeline(
            cards_, command_spec, op, args, actor, source_slot,
            context_mode, rng, result, early_return);
        if (early_return) return result;
        if (!handled) throw std::invalid_argument("unsupported_native_vm_op");
        if (!result.pending.as_object().empty()) {
            result.continuation["context_mode"] = Value(context_mode);
        }
        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    result.rng_state = rng.state();
    return result;
}

VmExecutionResult NativeRulesKernel::resume(
    Value state,
    Value context,
    const Value &continuation,
    const Value &selected_options,
    bool cancelled,
    std::uint32_t rng_state
) const {
    VmExecutionResult result;
    result.state = std::move(state);
    result.context = std::move(context);
    XorShift32 rng(rng_state);
    result.rng_state = rng.state();
    if (
        !continuation.is_object()
        || !selected_options.is_array()
    ) {
        result.error_code = "invalid_native_continuation";
        return result;
    }

    const std::string op = string_arg(continuation, "op");
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_arg(continuation, "actor", -1)
    );
    const std::string source_slot = string_arg(
        continuation,
        "source_slot",
        "active"
    );
    const std::int64_t stage = integer_arg(continuation, "stage");
    const Value *spec = continuation.find("command_spec");
    if (
        actor != 0
        && actor != 1
    ) {
        result.error_code = "invalid_actor";
        return result;
    }
    if (spec == nullptr || !spec->is_object() || !supports(op)) {
        result.error_code = "invalid_native_continuation_op";
        return result;
    }
    const Value *args_ptr = spec->find("args");
    const Value empty_args = Value::make_object();
    const Value &args = (
        args_ptr != nullptr && args_ptr->is_object()
    ) ? *args_ptr : empty_args;

    try {
        Value &self = player(result.state, actor);
        Value &opponent = player(result.state, 1 - actor);
        auto next = [&result](Value request, Value next_continuation) {
            increment_integer(result.state, "choice_sequence");
            result.pending = std::move(request);
            result.continuation = std::move(next_continuation);
        };

        increment_integer(result.state, "revision");
        if (
            cancelled
            && op != "search_any_and_switch"
            && op != "look_top_attach_energy"
            && op != "look_top_deck"
        ) {
            if (
                (
                    op == "attach_energy"
                    && string_arg(args, "from_zone", "hand") == "deck"
                )
                || (
                    op == "search_cards"
                    && string_arg(args, "from_zone", "deck") == "deck"
                )
            ) {
                shuffle_array(
                    required(self, "deck").as_array(),
                    rng
                );
                result.event_types.emplace_back("deck_shuffled");
            }
            result.success = true;
            result.rng_state = rng.state();
            return result;
        }

        bool early_return = false;
        bool handled = resume_vm_cards(
            *this, cards_, continuation, selected_options, cancelled, op, args,
            actor, source_slot, stage, rng, result, early_return);
        if (!handled) handled = resume_vm_damage(
            *this, cards_, continuation, selected_options, cancelled, op, args,
            actor, source_slot, stage, rng, result, early_return);
        if (!handled) handled = resume_vm_choices(
            *this, cards_, continuation, selected_options, cancelled, op, args,
            actor, source_slot, stage, rng, result, early_return);
        if (!handled) handled = resume_vm_triggers(
            *this, cards_, continuation, selected_options, cancelled, op, args,
            actor, source_slot, stage, rng, result, early_return);
        if (early_return) return result;
        if (!handled) throw std::invalid_argument("unsupported_native_resume_op");

        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    result.rng_state = rng.state();
    return result;
}

} // namespace ptcg::ai

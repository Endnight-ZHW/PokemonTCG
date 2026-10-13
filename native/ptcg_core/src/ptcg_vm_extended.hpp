#pragma once
#include "ptcg_rules.hpp"

namespace ptcg::ai::rules_detail {
bool execute_vm_extended(const Value &cards, const Value &spec, const std::string &op,
    const Value &args, int actor, const std::string &slot, const std::string &mode,
    XorShift32 &rng, VmExecutionResult &result);
bool resume_vm_extended(const NativeRulesKernel &kernel, const Value &cards,
    const Value &continuation, const Value &selected, bool cancelled,
    const std::string &op, const Value &args, int actor, const std::string &slot,
    std::int64_t stage, XorShift32 &rng, VmExecutionResult &result);
}

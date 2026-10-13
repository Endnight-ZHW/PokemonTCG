#pragma once
#include "ptcg_value.hpp"
#include "ptcg_rules.hpp"

namespace ptcg::ai::card_runtime {
const Value *rule(const Value &cards, const std::string &id, const std::string &effect);
Value attacks(const Value &cards, const Value &pokemon);
bool board_rule(const Value &cards, const Value &state, int owner, const std::string &effect);
std::int64_t bench_limit(const Value &cards, const Value &state, int owner);
bool protects_effect(const Value &cards, const Value &state, int owner,
    const std::string &slot, bool counters_only = false);
bool tera_protection(const Value &cards, const Value &pokemon, const std::string &slot);
bool basic_in_play(const Value &cards, const Value &pokemon);
void on_hand_attachment(const Value &cards, VmExecutionResult &result, int owner,
    const std::string &slot, const std::string &energy_id);
Value take_hand_attachment_trigger(Value &context);
bool knocked_out(const Value &cards, const Value &pokemon);
std::int64_t attachment_units(const Value &cards, const Value &pokemon, std::size_t index);
std::int64_t temporary_rule(const Value &pokemon, const std::string &effect,
    std::int64_t turn, const std::string &attack_name = "");
void add_temporary_rule(Value &target, const std::string &effect, std::int64_t amount,
    int actor, const Value &source, const std::string &source_slot,
    std::int64_t expires, std::int64_t starts = 0, const std::string &attack_name = "");
}

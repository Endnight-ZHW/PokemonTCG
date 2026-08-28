#pragma once

#include "ptcg_rules.hpp"

#include <functional>
#include <limits>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai::rules_detail {

using Array = Value::Array;
using Object = Value::Object;

extern const std::set<std::string> IMPLEMENTED_OPS;

void append_event( VmExecutionResult &result, const std::string &event_type, Object data );
void append_events( std::vector<Value> &destination, const std::vector<Value> &source );
bool coin_branch_runs_after_attack_damage(const std::string &op);
std::string lower_ascii(std::string value);
std::string upper_ascii(std::string value);
const Value &required(const Value &value, const std::string &key);
Value &required(Value &value, const std::string &key);
std::int64_t integer_arg( const Value &args, const std::string &key, std::int64_t fallback = 0 );
bool bool_arg( const Value &args, const std::string &key, bool fallback = false );
std::string string_arg( const Value &args, const std::string &key, std::string fallback = {} );
Value &player(Value &state, std::int32_t index);
const Value &player(const Value &state, std::int32_t index);
Value *pokemon(Value &player_value, const std::string &slot);
const Value *pokemon(const Value &player_value, const std::string &slot);
std::vector<Value *> all_pokemon(Value &player_value);
std::vector<const Value *> all_pokemon(const Value &player_value);
std::string card_id(const Value &pokemon_value);
const Value *card_definition(const Value &cards, const std::string &id);
bool string_array_contains_ci(const Value *array, const std::string &needle);
bool card_has_subtype( const Value &cards, const std::string &id, const std::string &subtype );
std::int64_t pokemon_hp( const Value &cards, const Value &pokemon_value );
bool card_is_pokemon(const Value &cards, const std::string &id);
bool card_is_energy(const Value &cards, const std::string &id);
bool card_matches_energy( const Value &cards, const std::string &id, const std::string &energy_type );
std::int64_t energy_units( const Value &cards, const Value *pokemon_value, const std::string &filter = "any" );
void append_string(Value &array_value, const std::string &value);
std::vector<std::string> draw_cards(Value &player_value, std::int64_t count);
bool attached_energy_card_matches( const Value &cards, const Value &pokemon_value, std::size_t card_index, const std::string &energy_type );
Array card_id_values(const std::vector<std::string> &card_ids);
Array card_id_values(const std::vector<Value> &cards);
Array selected_card_id_values(const Value &selected_options);
void append_card_zone_event( VmExecutionResult &result, const std::string &event_type, std::int32_t owner, Array card_ids, const std::string &source_zone, const std::string &target_zone, const std::string &visibility );
void append_cards_drawn_event( VmExecutionResult &result, std::int32_t owner, const std::vector<std::string> &drawn, const std::string &purpose = "effect" );
void append_damage_feedback_event( VmExecutionResult &result, const std::string &event_type, std::int32_t actor, std::int32_t target_player, const std::string &target_slot, std::int64_t amount );
void append_healed_event( VmExecutionResult &result, std::int32_t actor, std::int32_t target_player, const std::string &target_slot, std::int64_t healed_counters );
void append_status_event( VmExecutionResult &result, const std::string &event_type, std::int32_t actor, std::int32_t target_player, const std::string &target_slot, const std::string &status );
bool prevents_attack_effects(const Value &target);
void shuffle_array(Array &values, XorShift32 &rng);
Value new_pokemon(const Value &cards, const std::string &id);
void set_integer(Value &object, const std::string &key, std::int64_t value);
std::int64_t get_integer( const Value &object, const std::string &key, std::int64_t fallback = 0 );
void add_damage(Value &pokemon_value, std::int64_t damage);
std::int64_t heal_damage(Value &pokemon_value, std::int64_t amount);
bool condition_applies( const Value &cards, const Value &state, std::int32_t actor, const std::string &condition );
std::int64_t evaluate_formula_ast( const Value &formula, const Value &cards, const Value &state, std::int32_t actor );
void append_modifier( Value &pokemon_value, const std::string &op, const Value &args );
Value modifier_probe( const std::string &op, const Value &args, const Value *source, std::int32_t actor, const std::string &source_slot );
std::int64_t bench_count(const Value &player_value);
void set_attack_damage(Value &context, std::int64_t damage, bool add);
void return_pokemon_to_hand(Value &player_value, const std::string &slot);
Value pokemon_option( const Value &pokemon_value, std::int32_t owner, const std::string &slot );
Value card_option( const std::string &id, std::int32_t owner, const std::string &zone, std::int64_t index );
Value attachment_option( const std::string &id, std::int32_t owner, const std::string &slot, std::int64_t index );
Value id_option(const std::string &id, const std::string &label = {});
void decorate_energy_distribution_option( Value &option, std::int32_t actor, std::int64_t energy_index, const std::string &energy_card_id );
std::int64_t energy_option_index(const Value &option);
std::string energy_option_card_id(const Value &option);
void validate_energy_distribution_selection( const Array &selected_options, bool same_target, std::int64_t max_per_target );
Array pokemon_options( Value &player_value, std::int32_t owner, bool include_active, bool include_bench );
Array rare_candy_options( const Value &cards, Value &player_value, std::int32_t actor );
bool card_matches_filter( const Value &cards, const std::string &id, const std::string &filter );
Array zone_options( const Value &cards, const Value &player_value, std::int32_t owner, const std::string &zone, const std::string &filter, std::int64_t first_index = 0, std::int64_t last_index = std::numeric_limits<std::int64_t>::max(), bool descending = false, const std::string &filter_name = "" );
Value pending_request( const std::string &request_type, std::int32_t actor, std::int64_t min_select, std::int64_t max_select, bool allow_duplicates, bool can_cancel, Array options, const std::string &continuation_kind );
void increment_integer(Value &object, const std::string &key);
Value make_continuation( const std::string &op, const Value &command_spec, std::int32_t actor, const std::string &source_slot, std::int64_t stage = 0 );
std::vector<std::size_t> selected_indices( const Value &selected_options, const std::string &zone );
std::vector<std::string> selected_zone_card_ids( const Value &player_value, const Value &selected_options, const std::string &zone, std::int32_t owner );
std::vector<Value> remove_selected( Value &player_value, const std::string &zone, const Value &selected_options );
std::size_t discard_selected( Value &player_value, const std::string &zone, const Value &selected_options );
std::string selected_slot(const Value &selected_options);
bool selected_confirmation(const Value &selected_options);
void switch_active(Value &player_value, const std::string &bench_slot);
void switch_active_with_event( VmExecutionResult &result, Value &player_value, std::int32_t actor, std::int32_t target_player, const std::string &bench_slot, const std::string &reason = "effect" );
void discard_pokemon(Value &player_value, const std::string &slot);

bool execute_vm_modifier_pipeline(const Value &cards, const Value &command_spec, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, const std::string &context_mode, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool execute_vm_damage_pipeline(const Value &cards, const Value &command_spec, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, const std::string &context_mode, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool execute_vm_card_pipeline(const Value &cards, const Value &command_spec, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, const std::string &context_mode, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool execute_vm_trigger_pipeline(const Value &cards, const Value &command_spec, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, const std::string &context_mode, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool resume_vm_cards(const NativeRulesKernel &kernel, const Value &cards, const Value &continuation, const Value &selected_options, bool cancelled, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, std::int64_t stage, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool resume_vm_damage(const NativeRulesKernel &kernel, const Value &cards, const Value &continuation, const Value &selected_options, bool cancelled, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, std::int64_t stage, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool resume_vm_choices(const NativeRulesKernel &kernel, const Value &cards, const Value &continuation, const Value &selected_options, bool cancelled, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, std::int64_t stage, XorShift32 &rng, VmExecutionResult &result, bool &early_return);
bool resume_vm_triggers(const NativeRulesKernel &kernel, const Value &cards, const Value &continuation, const Value &selected_options, bool cancelled, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, std::int64_t stage, XorShift32 &rng, VmExecutionResult &result, bool &early_return);

} // namespace ptcg::ai::rules_detail

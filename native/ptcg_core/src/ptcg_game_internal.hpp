#pragma once

#include "ptcg_game.hpp"

#include <functional>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai::game_detail {

using Array = Value::Array;
using Object = Value::Object;

void append_event( GameExecutionResult &result, const std::string &event_type, Object data );
void append_events( std::vector<Value> &destination, const std::vector<Value> &source );
const Value &required(const Value &value, const std::string &key);
Value &required(Value &value, const std::string &key);
std::string string_arg( const Value &value, const std::string &key, const std::string &fallback = {} );
std::int64_t integer_arg( const Value &value, const std::string &key, std::int64_t fallback = 0 );
bool bool_arg( const Value &value, const std::string &key, bool fallback = false );
void set_integer(Value &value, const std::string &key, std::int64_t number);
void increment(Value &value, const std::string &key);
Value &player(Value &state, std::int32_t actor);
const Value &player(const Value &state, std::int32_t actor);
const Value *card_definition( const Value &cards, const std::string &card_id );
bool energy_switches_with_active_on_attach( const Value &cards, const std::string &card_id, const std::string &target_slot );
Value *pokemon(Value &player_value, const std::string &slot);
const Value *pokemon( const Value &player_value, const std::string &slot );
void clear_attack_effects_on_leave(Value &target);
void switch_active(Value &player_value, const std::string &bench_slot);
void append_slot_transition_event( GameExecutionResult &result, const std::string &event_type, std::int32_t actor, std::int32_t target_player, const std::string &bench_slot, const std::string &outgoing_card_id, const std::string &incoming_card_id, const std::string &reason );
void switch_active_with_event( GameExecutionResult &result, Value &player_value, std::int32_t actor, std::int32_t target_player, const std::string &bench_slot, const std::string &event_type, const std::string &reason );
Value make_pokemon(const std::string &card_id, bool placed_this_turn);
bool array_contains_string(const Value *value, const std::string &needle);
bool card_has_subtype(const Value &card, const std::string &subtype);
bool is_pokemon_card(const Value &card);
bool is_basic_pokemon(const Value &card);
bool is_energy_card(const Value &card);
bool is_trainer_card(const Value &card);
bool is_tool_card(const Value &card);
bool is_supporter_card(const Value &card);
bool is_stadium_card(const Value &card);
Value card_ref( std::int32_t actor, const std::string &zone, std::size_t index, const std::string &card_id );
Value pokemon_ref( std::int32_t actor, const std::string &slot, const Value &pokemon_value );
Value slot_ref(std::int32_t actor, const std::string &slot);
Value make_action( const Value &state, const std::string &kind, std::int32_t actor, Value source = Value(), Value target = Value(), Value payload = Value::make_object() );
void append_pokemon_rows( const Value &player_value, std::vector<std::pair<std::string, const Value *>> &rows );
bool is_player_first_turn( const Value &state, std::int32_t actor );
std::vector<std::string> energy_units( const Value &cards, const Value &pokemon_value );
std::int64_t energy_card_unit_count( const Value &cards, const std::string &card_id );
bool attached_tool_damage_boost_targets_active( const Value &cards, const Value &attacker );
std::int64_t attached_attack_damage_delta( const Value &cards, const Value &state, std::int32_t actor, const Value &attacker, bool target_is_opponent_active );
std::int64_t field_aura_attack_damage_delta( const Value &cards, const Value &state, std::int32_t actor, const Value &attacker, const Value &defender, bool target_is_opponent_active );
bool defender_modifier_condition_applies( const Value &cards, const Value &defender, const Value &descriptor, bool defender_is_active );
std::int64_t aura_damage_reduction_delta( const Value &cards, const Value &defender, bool defender_is_active, bool before_weakness );
std::int64_t opponent_active_aura_attack_damage_delta( const Value &cards, const Value &state, std::int32_t actor, bool before_weakness );
std::int64_t attached_defender_damage_delta( const Value &cards, const Value &defender, bool defender_is_active );
bool defender_prevents_attack_damage(const Value &defender);
std::int64_t signed_number_in_text( const std::string &text, std::int64_t fallback );
bool type_matchups_enabled(const Value &state);
std::int64_t apply_active_type_matchups( const Value &cards, const Value &state, const Value &attacker, const Value &defender, std::int64_t damage, bool ignore_weakness, bool ignore_resistance );
std::string lower_ascii(std::string value);
bool pokemon_has_matching_attached_energy( const Value &cards, const Value &pokemon_value, const std::string &filter );
bool pokemon_has_energy_type( const Value &cards, const Value &pokemon_value, const std::string &required_type );
std::int64_t effective_retreat_cost( const Value &cards, const Value &state, const Value &active, const Value *active_card );
bool can_pay_attack_cost( const Value &cards, const Value &pokemon_value, const Value &cost_value );
bool attack_is_locked( const Value &pokemon_value, const std::string &attack_name );
bool player_attack_name_is_locked( const Value &player_value, const std::string &attack_name, std::int64_t turn );
bool ability_is_discard_revive(const Value &ability);
bool rare_candy_has_target( const Value &cards, const Value &owner, std::size_t source_index );
bool card_matches_filter( const Value &cards, const Value &card_id, const std::string &filter, const std::string &filter_name = {} );
bool zone_has_matching_card( const Value &cards, const Value &owner, const std::string &zone, const Value &args );
std::size_t occupied_bench_count(const Value &owner);
bool pokemon_matches_type( const Value &cards, const Value &pokemon_value, const std::string &required_type );
bool has_energy_target( const Value &cards, const Value &owner, const Value &args, const std::string &source_slot = {} );
bool previous_turn_had_knockout( const Value &state, std::int32_t actor );
bool effect_has_visible_target( const Value &cards, const Value &state, std::int32_t actor, const Value &effect, std::size_t source_hand_index, const std::string &source_slot );
bool effect_list_has_visible_target( const Value &cards, const Value &state, std::int32_t actor, const Value &effects, std::size_t source_hand_index, const std::string &source_slot = {} );
bool ability_effect_list_has_visible_target( const Value &cards, const Value &state, std::int32_t actor, const Value &effects, const std::string &source_slot );
bool stadium_has_activation(const Value &card);
std::string stable_choice_option_id( const Value &option, const std::string &request_type );
void append_choice_candidate( Array &result, const std::string &request_id, const std::string &request_type, const std::vector<const Value *> &selected, bool cancelled );
void draw_one(Value &player_value, std::vector<std::string> &events);
void draw_one_with_payload( GameExecutionResult &result, std::int32_t owner, const std::string &purpose );
bool has_pokemon_in_play(const Value &player_value);
void evaluate_terminal_result(Value &state);
bool finalize_terminal_if_needed(GameExecutionResult &result);
void shuffle_array(Array &values, XorShift32 &rng);
void expire_pokemon_modifiers( Value *target, std::int64_t turn );
void expire_all_modifiers( Value &state, std::int64_t turn );
void expire_legacy_attack_locks( Value &player_value, std::int64_t turn );
void reset_turn_flags(Value &player_value);
void complete_checkup_transition( Value &state, std::int32_t actor, std::vector<std::string> &events );
void add_damage(Value &target, std::int64_t amount);
std::int64_t pokemon_hp( const Value &cards, const Value &pokemon_value );
void append_knockout_fact( Value &state, const std::string &card_id, std::int32_t defeated, std::int32_t actor, const std::string &cause_kind = "damage", const std::string &source_kind = "attack_damage", const std::string &slot = "active" );
void discard_active(Value &owner);
void discard_pokemon(Value &owner, const std::string &slot);
Array pokemon_options( const Value &player_value, std::int32_t actor, bool include_active, bool include_bench );
Value action_pending( const std::string &request_type, std::int32_t actor, std::int64_t minimum, std::int64_t maximum, bool can_cancel, Array options, const std::string &continuation_kind, bool finish_attack );
void queue_promotion_if_possible(Value &state, std::int32_t owner);
void suspend_single_prize_choice( GameExecutionResult &result, std::int32_t prize_player );
void suspend_prize_queue( GameExecutionResult &result, const std::vector<std::int32_t> &prize_players, std::int32_t attack_actor, const Value &attack_context );
std::int64_t knockout_prize_value( const Value &cards, const std::string &card_id );
void suspend_knockout_prizes( GameExecutionResult &result, const Value &cards, const std::string &defeated_card_id, std::int32_t prize_player, std::int32_t resume_attack_actor = -1, const Value &resume_attack_context = Value::make_object() );
bool settle_ability_effect_knockouts( GameExecutionResult &result, const Value &cards, std::int32_t effect_actor );
void finish_turn( GameExecutionResult &result, const Value &cards, std::int32_t actor );
void suspend_after_damage_trigger_order( GameExecutionResult &result, std::int32_t attack_actor, std::int32_t trigger_owner, std::int64_t trigger_count, Array remaining_groups, const Value &attack_context );
void suspend_public_trigger_order( GameExecutionResult &result, std::int32_t attack_actor, std::int32_t trigger_owner, Array trigger_specs, Array remaining_groups, const Value &attack_context );
void validate_public_trigger_spec( const Value &state, const Value &spec );
void apply_public_trigger_spec( GameExecutionResult &result, const Value &cards, const Value &spec );
void validate_public_trigger_groups( const Value &state, const Array &groups, std::int32_t attack_actor, const char *error_code );
bool consume_public_trigger_groups( GameExecutionResult &result, const Value &cards, std::int32_t attack_actor, Array groups, const Value &attack_context, const char *error_code );
bool is_basic_energy_id( const Value &cards, const std::string &card_id );
bool is_exp_share_tool( const Value &cards, const std::string &card_id );
void finalize_active_knockout( GameExecutionResult &result, const Value &cards, std::int32_t defeated_owner, std::int32_t prize_player );
bool suspend_exp_share_trigger_if_available( GameExecutionResult &result, const Value &cards, std::int32_t attack_actor );
void append_canonical_modifier( Value &target, const Value &source, const std::string &op, const Value &args, std::int32_t actor, const std::string &source_slot, std::int32_t target_player, std::int64_t turn );
bool same_modifier_source( const Value *left, const Value *right );
void append_serialized_modifier( Value &target, Object descriptor );
void canonicalize_vm_modifiers( Value &state, std::int32_t actor, const std::string &source_slot );
void append_tool_modifiers( Value &target, const Value &definition, std::int32_t actor, const std::string &slot );
bool replaces_attack_damage(const std::string &op);
const Value *find_named_ability( const Value &definition, const std::string &name );
Value canonical_params(const Value &action, const std::string &kind);
void attach_game_continuation( GameExecutionResult &result, const VmExecutionResult &vm, std::int32_t actor, bool finish_attack, Value remaining = Value::make_array(), std::string source_slot = "active", std::string context_mode = "" );
Value remaining_effects( const Array &effects, std::size_t first );
std::int64_t calculated_attack_damage( const Value &state, const Value &cards, std::int32_t actor, const Value &context );
std::int64_t after_damage_energy_draw_count( const Value &cards, const Value *holder, const std::string &scope, std::int64_t damage );
void apply_attack_damage_before_effect( GameExecutionResult &result, const Value &cards, std::int32_t actor, Value &context );
void apply_reactive_thorns( GameExecutionResult &result, const Value &cards, std::int32_t actor, Value &context );
bool attack_effect_runs_before_damage( const std::string &op, const Value &args );
void finish_attack_resolution( GameExecutionResult &result, const Value &cards, std::int32_t actor, Value &context );
bool prize_attaches_to_bench( const Value &cards, const std::string &prize_card_id );
void continue_after_prize_selection( GameExecutionResult &result, const Value &cards, const Value &continuation );
void suspend_exp_share_confirmation( GameExecutionResult &result, std::int32_t defeated_owner, std::int32_t attack_actor, const Value &continuation, std::int64_t remaining, bool remaining_requires_order );
void suspend_exp_share_order( GameExecutionResult &result, std::int32_t defeated_owner, std::int32_t attack_actor, const Value &continuation, std::int64_t count );
void validate_public_exp_share_spec( const Value &state, std::int32_t actor, const Value &spec );
void suspend_public_exp_share_spec_order( GameExecutionResult &result, std::int32_t actor, std::int32_t attack_actor, const Value &continuation, Array trigger_specs );
void suspend_public_exp_share_spec_confirmation( GameExecutionResult &result, std::int32_t actor, std::int32_t attack_actor, const Value &outer_continuation, Value chosen, Array remaining );
bool continue_public_exp_share_spec_queue( GameExecutionResult &result, std::int32_t actor, std::int32_t attack_actor, const Value &continuation );
void continue_after_exp_share_trigger( GameExecutionResult &result, const Value &cards, std::int32_t defeated_owner, std::int32_t attack_actor, const Value &continuation );

} // namespace ptcg::ai::game_detail

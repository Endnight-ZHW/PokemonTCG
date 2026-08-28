#pragma once

#include "ptcg_rules_session.hpp"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace ptcg::ai::session_detail {

using Array = Value::Array;
using Object = Value::Object;

struct CatalogPayload {
    Value cards = Value::make_object();
    std::string content_fingerprint;
    std::string contract_fingerprint;
    std::string descriptor_digest;
};

const Value *field(const Value &value, const std::string &key);
std::string string_field( const Value &value, const std::string &key, std::string fallback = {} );
std::int64_t integer_field( const Value &value, const std::string &key, std::int64_t fallback = 0 );
bool bool_field( const Value &value, const std::string &key, bool fallback = false );
Value &required(Value &value, const std::string &key);
const Value &required(const Value &value, const std::string &key);
Value &player(Value &state, std::int32_t actor);
const Value &player(const Value &state, std::int32_t actor);
bool array_contains_string(const Value *value, const std::string &needle);
bool is_basic_pokemon(const Value &cards, const std::string &card_id);
bool hand_has_basic(const Value &cards, const Value &owner);
bool is_hex_digest(const std::string &value);
Value *named_card_block(Value &card, const char *field_name, const std::string &name);
void apply_ir_blocks( Value &card, const Value &ir_card, const char *field_name, const char *ir_field_name );
CatalogPayload normalize_catalog(const Value &catalog);
void shuffle(Array &values, XorShift32 &rng);
Array draw_cards(Value &owner, std::size_t count);
Value empty_player(std::string name, Array deck);
Value empty_resolution_stack();
Value event( std::string type, std::int32_t actor = -1, Value data = Value::make_object(), std::string visibility = {} );
const Value *state_pokemon( const Value &state, std::int32_t owner, const std::string &slot );
std::string public_card_name( const Value &cards, const std::string &card_id );
std::string public_player_name( const Value &state, std::int32_t actor );
std::string public_slot_name(const std::string &slot);
std::string public_pokemon_name( const Value &cards, const Value &before_state, const Value &after_state, std::int32_t owner, const std::string &slot, const std::string &fallback_card_id = {} );
void append_action_log_line(Value &state, std::string line);
std::string attack_name_for_action( const Value &cards, const Value &action );
std::string ability_name_for_action( const Value &cards, const Value &action );
void append_submitted_action_log( Value &state, const Value &cards, const Value &before_state, const Value &action );
void append_choice_action_log( Value &state, const Value &before_state, const Value &pending, const Value &response );
void append_public_event_logs( Value &state, const Value &cards, const Value &before_state, const std::vector<Value> &events );
void append_canonical_json(std::string &output, const Value &value);
std::string fnv1a64_hex(const std::string &input);
std::int32_t winner_from_state(const Value &state);
bool terminal_from_state(const Value &state);
Value public_option_ref( const Value &source, std::int32_t request_player, const std::string &request_type );
Value public_choice( Value &state, const Value &raw, const std::string &request_id_override = {} );
Value setup_choice( Value &state, std::int32_t player_index, std::string request_type, std::string prompt, Array options, std::string purpose );
std::vector<Value> canonical_events( const GameExecutionResult &result, const Value *before_state = nullptr, const Value *after_state = nullptr, const Value *input = nullptr, std::int32_t actor_hint = -1 );
bool action_equivalent(const Value &submitted, const Value &candidate);
std::string validate_action_shape(const Value &action);
std::string validate_choice_response_shape(const Value &response);
Value hidden_cards(std::size_t count);
void strip_internal_pokemon_fields(Value &pokemon_value);
Value player_view( const Value &owner, bool show_hand, bool hide_setup_board );
void set_prizes(Value &state);
void finish_setup(Value &state, std::vector<Value> &events);
std::string prepare_opening_hands( const Value &cards, Value &state, XorShift32 &rng, std::vector<Value> &events );
std::string validate_snapshot_payload( const Value &snapshot, const Value &cards );

bool typed_action_equivalent(const typed::Action &submitted, const typed::Action &candidate);
Value clone_wire_field(const Value &source, const char *key, Value fallback);
Value reply_search_pokemon_projection(const Value &source);
Value reply_search_player_projection(const Value &source, std::int32_t actor);
Value reply_search_state_projection(const Value &source);

} // namespace ptcg::ai::session_detail

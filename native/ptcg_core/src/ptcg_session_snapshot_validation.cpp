#include "ptcg_rules_session.hpp"
#include "ptcg_session_internal.hpp"

#include "ptcg_random.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <functional>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <unordered_map>
#include <utility>


namespace ptcg::ai::session_detail {

using Array = Value::Array;
using Object = Value::Object;

std::string validate_snapshot_payload(
    const Value &snapshot,
    const Value &cards
) {
    std::string encoded;
    append_canonical_json(encoded, snapshot);
    if (encoded.size() > 1024U * 1024U) {
        return "snapshot_too_large";
    }
    static const std::array<const char *, 30> required_fields = {
        "players", "active_player_idx", "phase", "turn_number",
        "first_player_idx", "stadium_card_id", "stadium_owner_idx",
        "winner", "result_status", "result_reason", "result_conditions",
        "revision", "choice_sequence", "public_deck_keys",
        "apply_type_matchups", "rules_profile_id", "rules_options",
        "action_log", "mulligan_count", "extra_draws", "setup_ready",
        "setup_stage", "setup_actor_idx", "opening_coin_winner_idx",
        "mulligan_bonus_max", "setup_bonus_card_ids", "pending_promotions",
        "processed_action_ids", "resolution_stack", "turn_fact_book",
    };
    for (const char *key : required_fields) {
        if (snapshot.find(key) == nullptr) {
            return std::string("missing_snapshot_field:") + key;
        }
    }
    if (
        !required(snapshot, "players").is_array()
        || required(snapshot, "players").as_array().size() != 2
        || !required(snapshot, "phase").is_string()
        || string_field(snapshot, "phase").empty()
        || integer_field(snapshot, "active_player_idx", -1) < 0
        || integer_field(snapshot, "active_player_idx", -1) > 1
        || integer_field(snapshot, "first_player_idx", -1) < 0
        || integer_field(snapshot, "first_player_idx", -1) > 1
        || integer_field(snapshot, "winner", -2) < -1
        || integer_field(snapshot, "winner", -2) > 1
        || integer_field(snapshot, "turn_number", -1) < 0
        || integer_field(snapshot, "revision", -1) < 0
        || integer_field(snapshot, "choice_sequence", -1) < 0
        || !required(snapshot, "rules_options").is_object()
        || !required(snapshot, "turn_fact_book").is_object()
        || !required(snapshot, "resolution_stack").is_object()
    ) {
        return "invalid_snapshot_shape";
    }
    for (const char *key : {
        "public_deck_keys", "mulligan_count", "extra_draws", "setup_ready",
        "setup_bonus_card_ids", "result_conditions",
    }) {
        const Value *rows = snapshot.find(key);
        if (rows == nullptr || !rows->is_array() || rows->as_array().size() != 2) {
            return std::string("invalid_snapshot_pair:") + key;
        }
    }
    for (const char *key : {"action_log", "pending_promotions", "processed_action_ids"}) {
        const Value *rows = snapshot.find(key);
        if (rows == nullptr || !rows->is_array() || rows->as_array().size() > 4096) {
            return std::string("invalid_snapshot_array:") + key;
        }
    }
    const auto validate_card_array = [&cards](const Value *values) {
        if (values == nullptr || !values->is_array() || values->as_array().size() > 256) {
            return false;
        }
        return std::all_of(
            values->as_array().begin(), values->as_array().end(),
            [&cards](const Value &entry) {
                return entry.is_string()
                    && !entry.string_or().empty()
                    && cards.find(entry.string_or()) != nullptr;
            }
        );
    };
    const auto validate_pokemon = [&cards, &validate_card_array](
        const Value &pokemon_value
    ) {
        if (pokemon_value.is_null()) {
            return true;
        }
        if (!pokemon_value.is_object()) {
            return false;
        }
        const std::string card_id = string_field(pokemon_value, "card_id");
        const std::string tool_id = string_field(
            pokemon_value, "attached_tool_id");
        return !card_id.empty()
            && cards.find(card_id) != nullptr
            && (tool_id.empty() || cards.find(tool_id) != nullptr)
            && validate_card_array(pokemon_value.find("energy_card_ids"))
            && validate_card_array(pokemon_value.find("evolution_stack_ids"));
    };
    for (const Value &owner : required(snapshot, "players").as_array()) {
        if (!owner.is_object() || !string_field(owner, "name").size()) {
            return "invalid_snapshot_player";
        }
        for (const char *zone : {"deck", "hand", "discard", "prizes"}) {
            if (!validate_card_array(owner.find(zone))) {
                return std::string("invalid_snapshot_zone:") + zone;
            }
        }
        const Value *active = owner.find("active");
        const Value *bench = owner.find("bench");
        if (
            active == nullptr || !validate_pokemon(*active)
            || bench == nullptr || !bench->is_array()
            || bench->as_array().size() != 5
            || !std::all_of(
                bench->as_array().begin(), bench->as_array().end(),
                validate_pokemon)
        ) {
            return "invalid_snapshot_board";
        }
    }
    const Value &stack = required(snapshot, "resolution_stack");
    const Value *frames = stack.find("frames");
    const Value *context = stack.find("context");
    const Value *pending = stack.find("pending_request");
    if (
        integer_field(stack, "schema_version", -1) != 3
        || integer_field(stack, "sequence", -1) < 0
        || frames == nullptr || !frames->is_array()
        || frames->as_array().size() > 64
        || context == nullptr || !context->is_object()
        || pending == nullptr
        || (!pending->is_null() && !pending->is_object())
    ) {
        return "invalid_resolution_stack";
    }
    return {};
}


} // namespace ptcg::ai::session_detail

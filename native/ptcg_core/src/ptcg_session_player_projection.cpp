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

Value hidden_cards(std::size_t count) {
    return Value(Array(count, Value("")));
}

void strip_internal_pokemon_fields(Value &pokemon_value) {
    if (!pokemon_value.is_object()) {
        return;
    }
    static const std::unordered_set<std::string> public_fields = {
        "card_id", "damage_counters", "energy_card_ids", "attached_tool_id",
        "status_conditions", "evolution_stack_ids", "can_evolve_this_turn",
        "placed_this_turn", "used_abilities", "healed_this_turn",
        "paralyzed_since_turn", "modifiers",
    };
    Object &row = pokemon_value.as_object();
    for (auto iterator = row.begin(); iterator != row.end();) {
        if (public_fields.find(iterator->first) == public_fields.end()) {
            iterator = row.erase(iterator);
        } else {
            ++iterator;
        }
    }
}

Value player_view(
    const Value &owner,
    bool show_hand,
    bool hide_setup_board
) {
    Value result = owner.deep_clone();
    Object &row = result.as_object();
    const auto count = [&owner](const std::string &key) {
        const Value *value = owner.find(key);
        return static_cast<std::int64_t>(
            value != nullptr && value->is_array() ? value->as_array().size() : 0);
    };
    row["hand_count"] = Value(count("hand"));
    row["deck_count"] = Value(count("deck"));
    row["prize_count"] = Value(count("prizes"));
    row.erase("deck");
    row.erase("prizes");
    if (!show_hand) {
        row.erase("hand");
    }
    Value *public_active = result.find("active");
    if (public_active != nullptr) {
        strip_internal_pokemon_fields(*public_active);
    }
    Value *public_bench = result.find("bench");
    if (public_bench != nullptr && public_bench->is_array()) {
        for (Value &pokemon_value : public_bench->as_array()) {
            strip_internal_pokemon_fields(pokemon_value);
        }
    }
    if (hide_setup_board) {
        const Value *active = owner.find("active");
        row["active"] = active != nullptr && active->is_object()
            ? Value(Object{{"hidden", Value(true)}})
            : Value();
        Array bench;
        const Value *source_bench = owner.find("bench");
        if (source_bench != nullptr && source_bench->is_array()) {
            for (const Value &entry : source_bench->as_array()) {
                bench.push_back(entry.is_object()
                    ? Value(Object{{"hidden", Value(true)}})
                    : Value());
            }
        }
        row["bench"] = Value(std::move(bench));
    }
    return result;
}


} // namespace ptcg::ai::session_detail

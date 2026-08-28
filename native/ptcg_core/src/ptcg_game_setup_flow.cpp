#include "ptcg_game.hpp"
#include "ptcg_game_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>

namespace ptcg::ai::game_detail {

using Array = Value::Array;
using Object = Value::Object;

void draw_one(Value &player_value, std::vector<std::string> &events) {
    Array &deck = required(player_value, "deck").as_array();
    if (deck.empty()) {
        return;
    }
    required(player_value, "hand").as_array().push_back(
        std::move(deck.back())
    );
    deck.pop_back();
    events.emplace_back("cards_drawn");
}

void draw_one_with_payload(
    GameExecutionResult &result,
    std::int32_t owner,
    const std::string &purpose
) {
    Value &owner_value = player(result.state, owner);
    const Array &deck = required(owner_value, "deck").as_array();
    const Array &hand = required(owner_value, "hand").as_array();
    if (deck.empty()) {
        return;
    }
    const std::string card_id = deck.back().string_or();
    const std::int64_t source_index = static_cast<std::int64_t>(
        deck.size() - 1);
    const std::int64_t target_index = static_cast<std::int64_t>(hand.size());
    draw_one(owner_value, result.event_types);
    append_event(result, "cards_drawn", Object{
        {"actor", Value(owner)},
        {"player", Value(owner)},
        {"card_id", Value(card_id)},
        {"card_ids", Value(Array{Value(card_id)})},
        {"count", Value(1)},
        {"source_zone", Value("deck")},
        {"source_index", Value(source_index)},
        {"target_zone", Value("hand")},
        {"target_index", Value(target_index)},
        {"purpose", Value(purpose)},
        {"visibility", Value("owner")},
    });
}

bool has_pokemon_in_play(const Value &player_value) {
    if (pokemon(player_value, "active") != nullptr) {
        return true;
    }
    const Array &bench = required(player_value, "bench").as_array();
    return std::any_of(
        bench.begin(),
        bench.end(),
        [](const Value &entry) { return entry.is_object(); }
    );
}

void evaluate_terminal_result(Value &state) {
    Array condition_rows;
    std::array<std::int64_t, 2> scores{0, 0};
    for (std::int32_t actor = 0; actor < 2; ++actor) {
        Array conditions;
        if (required(
            player(state, actor),
            "prizes"
        ).as_array().empty()) {
            conditions.emplace_back("PRIZES_TAKEN");
        }
        if (!has_pokemon_in_play(player(state, 1 - actor))) {
            conditions.emplace_back("OPPONENT_NO_POKEMON");
        }
        scores[static_cast<std::size_t>(actor)] =
            static_cast<std::int64_t>(conditions.size());
        condition_rows.emplace_back(std::move(conditions));
    }
    if (scores[0] == 0 && scores[1] == 0) {
        return;
    }
    state["phase"] = Value("GAME_OVER");
    state["result_reason"] = Value("RULE_CONDITIONS");
    state["result_conditions"] = Value(std::move(condition_rows));
    if (scores[0] == scores[1]) {
        state["result_status"] = Value("DRAW");
        state["winner"] = Value(-1);
    } else {
        const std::int32_t winner = scores[0] > scores[1] ? 0 : 1;
        state["result_status"] = Value("WIN");
        state["winner"] = Value(winner);
    }
}

bool finalize_terminal_if_needed(GameExecutionResult &result) {
    evaluate_terminal_result(result.state);
    if (string_arg(result.state, "phase") != "GAME_OVER") {
        return false;
    }
    required(
        result.state,
        "pending_promotions"
    ).as_array().clear();
    append_event(
        result,
        "game_over",
        Object{
            {
                "winner",
                Value(integer_arg(result.state, "winner", -1)),
            },
            {
                "result_status",
                Value(string_arg(result.state, "result_status")),
            },
            {"reason", Value("knockout")},
            {
                "conditions",
                required(result.state, "result_conditions"),
            },
        }
    );
    return true;
}

void shuffle_array(Array &values, XorShift32 &rng) {
    for (std::size_t index = values.size(); index > 1; --index) {
        const std::size_t selected = rng.next_u32() % index;
        std::swap(values[index - 1], values[selected]);
    }
}

void expire_pokemon_modifiers(
    Value *target,
    std::int64_t turn
) {
    if (target == nullptr || !target->is_object()) {
        return;
    }
    Value *modifiers = target->find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        return;
    }
    modifiers->as_array().erase(
        std::remove_if(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [turn](const Value &descriptor) {
                if (!descriptor.is_object()) {
                    return false;
                }
                const std::string duration = string_arg(
                    descriptor,
                    "duration"
                );
                if (
                    duration != "until_end_of_turn"
                    && duration
                        != "until_end_of_opponents_next_turn"
                    && duration != "until_next_attack"
                ) {
                    return false;
                }
                const Value *condition = descriptor.find("condition");
                return condition != nullptr
                    && condition->is_object()
                    && integer_arg(
                        *condition,
                        "expires_after_turn",
                        std::numeric_limits<std::int64_t>::max()
                    ) <= turn;
            }
        ),
        modifiers->as_array().end()
    );
}

void expire_all_modifiers(
    Value &state,
    std::int64_t turn
) {
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value &owner_value = player(state, owner);
        expire_pokemon_modifiers(
            owner_value.find("active"),
            turn
        );
        for (Value &entry : required(owner_value, "bench").as_array()) {
            expire_pokemon_modifiers(&entry, turn);
        }
    }
}

void expire_legacy_attack_locks(
    Value &player_value,
    std::int64_t turn
) {
    Value *player_locked_names = player_value.find("attack_locked_names");
    if (player_locked_names != nullptr && player_locked_names->is_object()) {
        auto &names = player_locked_names->as_object();
        for (auto iterator = names.begin(); iterator != names.end();) {
            if (turn >= iterator->second.as_integer(-1)) {
                iterator = names.erase(iterator);
            } else {
                ++iterator;
            }
        }
        if (names.empty()) {
            player_value.erase("attack_locked_names");
        }
    }
    const std::array<std::string, 6> slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (const std::string &slot : slots) {
        Value *target = pokemon(player_value, slot);
        if (target == nullptr) {
            continue;
        }
        target->erase("attack_locked");
        Value *locked_names = target->find("attack_locked_names");
        if (locked_names == nullptr || !locked_names->is_object()) {
            continue;
        }
        auto &names = locked_names->as_object();
        for (auto iterator = names.begin(); iterator != names.end();) {
            if (turn >= iterator->second.as_integer() + 2) {
                iterator = names.erase(iterator);
            } else {
                ++iterator;
            }
        }
        if (names.empty()) {
            target->erase("attack_locked_names");
        }
    }
}

void reset_turn_flags(Value &player_value) {
    player_value["energy_attached_this_turn"] = Value(false);
    player_value["healed_this_turn"] = Value(false);
    player_value["retreated_this_turn"] = Value(false);
    player_value["stadium_played_this_turn"] = Value(false);
    player_value["stadium_used_this_turn"] = Value(false);
    player_value["supporter_played_this_turn"] = Value(false);
    auto reset_pokemon = [](Value *target) {
        if (target == nullptr || !target->is_object()) {
            return;
        }
        (*target)["can_evolve_this_turn"] = Value(true);
        (*target)["damage_prevented"] = Value(false);
        (*target)["all_prevented"] = Value(false);
        (*target)["healed_this_turn"] = Value(false);
        (*target)["placed_this_turn"] = Value(false);
        (*target)["used_abilities"] = Value::make_array();
    };
    reset_pokemon(player_value.find("active"));
    for (Value &entry : required(player_value, "bench").as_array()) {
        reset_pokemon(&entry);
    }
}

void add_damage(Value &target, std::int64_t amount);

void complete_checkup_transition(
    Value &state,
    std::int32_t actor,
    std::vector<std::string> &events
) {
    const std::int32_t next = 1 - actor;
    Value &old_player = player(state, actor);
    expire_legacy_attack_locks(
        old_player,
        integer_arg(state, "turn_number")
    );
    const std::array<std::string, 6> old_slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (const std::string &slot : old_slots) {
        if (Value *target = pokemon(old_player, slot)) {
            (*target)["outgoing_damage_reduction"] = Value(0);
            target->erase("dazzled");
        }
    }
    set_integer(state, "active_player_idx", next);
    increment(state, "turn_number");
    state["phase"] = Value("MAIN");
    old_player["was_ko_by_attack"] = Value(false);
    Value &next_player = player(state, next);
    reset_turn_flags(next_player);
    const Value *fact_book = state.find("turn_fact_book");
    if (fact_book != nullptr && fact_book->is_object()) {
        Value &mutable_facts = required(state, "turn_fact_book");
        mutable_facts["previous_turn"] = required(
            mutable_facts,
            "current_turn"
        );
        mutable_facts["current_turn"] = Value(Object{
            {"knockouts", Value::make_array()},
        });
    }
    events.emplace_back("turn_start");
    if (required(next_player, "deck").as_array().empty()) {
        // Failing the mandatory draw at the start of a turn loses the match.
        // Keep this in the core transition (rather than a caller/UI guard) so
        // replay, search and every binding observe the same terminal state.
        state["phase"] = Value("GAME_OVER");
        state["result_status"] = Value("WIN");
        state["result_reason"] = Value("deck_exhausted");
        state["winner"] = Value(actor);
        state["result_conditions"] = Value(Array{
            actor == 0
                ? Value(Array{Value("opponent_deck_exhausted")})
                : Value::make_array(),
            actor == 1
                ? Value(Array{Value("opponent_deck_exhausted")})
                : Value::make_array(),
        });
        required(state, "pending_promotions").as_array().clear();
        events.emplace_back("deck_exhausted");
        events.emplace_back("game_over");
        return;
    }
    draw_one(next_player, events);
}


} // namespace ptcg::ai::game_detail

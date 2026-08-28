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

void add_damage(Value &target, std::int64_t amount) {
    const std::int64_t counters = std::max<std::int64_t>(
        0,
        amount / 10
    );
    set_integer(
        target,
        "damage_counters",
        integer_arg(target, "damage_counters") + counters
    );
}

std::int64_t pokemon_hp(
    const Value &cards,
    const Value &pokemon_value
) {
    const Value *definition = card_definition(
        cards,
        string_arg(pokemon_value, "card_id")
    );
    if (definition == nullptr) {
        return 0;
    }
    std::int64_t result = integer_arg(*definition, "hp");
    const Value *abilities = definition->find("abilities");
    if (abilities != nullptr && abilities->is_array()) {
        for (const Value &ability : abilities->as_array()) {
            const Value *effects = ability.find("compiled_effects");
            if (effects == nullptr || !effects->is_array()) {
                continue;
            }
            for (const Value &effect : effects->as_array()) {
                if (
                    string_arg(effect, "op")
                        != "register_conditional_hp_boost"
                ) {
                    continue;
                }
                const Value *args = effect.find("args");
                if (args == nullptr || !args->is_object()) {
                    continue;
                }
                const std::string required_type = lower_ascii(
                    string_arg(*args, "energy_type", "any")
                );
                const std::vector<std::string> units = energy_units(
                    cards,
                    pokemon_value
                );
                const std::int64_t attached = static_cast<std::int64_t>(
                    std::count_if(
                        units.begin(),
                        units.end(),
                        [&required_type](const std::string &unit) {
                            const std::string normalized = lower_ascii(unit);
                            return required_type.empty()
                                || required_type == "any"
                                || normalized == required_type
                                || normalized == "rainbow";
                        }
                    )
                );
                if (attached >= integer_arg(*args, "threshold", 1)) {
                    result += integer_arg(*args, "amount");
                }
            }
        }
    }
    const Value *modifiers = pokemon_value.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        return result;
    }
    for (const Value &modifier : modifiers->as_array()) {
        const Value *operation = modifier.find("operation");
        if (
            !modifier.is_object()
            || string_arg(modifier, "hook") != "MAX_HP"
            || operation == nullptr
            || !operation->is_object()
            || string_arg(*operation, "kind") != "hp_delta"
        ) {
            continue;
        }
        const Value *condition = modifier.find("condition");
        if (
            condition != nullptr
            && condition->is_object()
            && bool_arg(*condition, "target_basic")
            && !is_basic_pokemon(*definition)
        ) {
            continue;
        }
        result += integer_arg(*operation, "amount");
    }
    return std::max<std::int64_t>(0, result);
}

void append_knockout_fact(
    Value &state,
    const std::string &card_id,
    std::int32_t defeated,
    std::int32_t actor,
    const std::string &cause_kind,
    const std::string &source_kind,
    const std::string &slot
) {
    Value *book = state.find("turn_fact_book");
    if (book == nullptr || !book->is_object()) {
        return;
    }
    Value *current = book->find("current_turn");
    if (current == nullptr || !current->is_object()) {
        return;
    }
    Value *knockouts = current->find("knockouts");
    if (knockouts == nullptr || !knockouts->is_array()) {
        return;
    }
    Object fact;
    fact["card_id"] = Value(card_id);
    fact["cause_detail"] = Value("");
    fact["cause_kind"] = Value(cause_kind);
    fact["defeated_player"] = Value(defeated);
    fact["slot"] = Value(slot);
    fact["source_kind"] = Value(source_kind);
    fact["source_player"] = Value(actor);
    fact["turn"] = Value(integer_arg(state, "turn_number"));
    knockouts->as_array().emplace_back(std::move(fact));
}

void discard_active(Value &owner) {
    Value *active = owner.find("active");
    if (active == nullptr || !active->is_object()) {
        return;
    }
    Array &discard = required(owner, "discard").as_array();
    discard.emplace_back(string_arg(*active, "card_id"));
    const Value *stack = active->find("evolution_stack_ids");
    if (stack != nullptr && stack->is_array()) {
        for (const Value &entry : stack->as_array()) {
            discard.push_back(entry);
        }
    }
    const std::string tool = string_arg(*active, "attached_tool_id");
    if (!tool.empty()) {
        discard.emplace_back(tool);
    }
    const Value *energy = active->find("energy_card_ids");
    if (energy != nullptr && energy->is_array()) {
        for (const Value &entry : energy->as_array()) {
            discard.push_back(entry);
        }
    }
    owner["active"] = Value();
}

void discard_pokemon(Value &owner, const std::string &slot) {
    if (slot == "active") {
        discard_active(owner);
        return;
    }
    if (slot.rfind("bench_", 0) != 0) {
        return;
    }
    const std::size_t index = static_cast<std::size_t>(
        std::stoul(slot.substr(6))
    );
    Array &bench = required(owner, "bench").as_array();
    if (index >= bench.size() || !bench[index].is_object()) {
        return;
    }
    Value displaced = std::move(bench[index]);
    bench[index] = Value();
    Array &discard = required(owner, "discard").as_array();
    discard.emplace_back(string_arg(displaced, "card_id"));
    const Value *stack = displaced.find("evolution_stack_ids");
    if (stack != nullptr && stack->is_array()) {
        for (const Value &entry : stack->as_array()) {
            discard.push_back(entry);
        }
    }
    const std::string tool = string_arg(displaced, "attached_tool_id");
    if (!tool.empty()) {
        discard.emplace_back(tool);
    }
    const Value *energy = displaced.find("energy_card_ids");
    if (energy != nullptr && energy->is_array()) {
        for (const Value &entry : energy->as_array()) {
            discard.push_back(entry);
        }
    }
}

Array pokemon_options(
    const Value &player_value,
    std::int32_t actor,
    bool include_active,
    bool include_bench
) {
    Array result;
    auto append = [&result, actor](
        const Value &target,
        const std::string &slot
    ) {
        if (!target.is_object()) {
            return;
        }
        result.emplace_back(Object{
            {"kind", Value("pokemon")},
            {"player", Value(actor)},
            {"card_id", Value(string_arg(target, "card_id"))},
            {"slot", Value(slot)},
        });
    };
    if (include_active) {
        const Value *active = player_value.find("active");
        if (active != nullptr) {
            append(*active, "active");
        }
    }
    if (include_bench) {
        const Array &bench = required(player_value, "bench").as_array();
        for (std::size_t index = 0; index < bench.size(); ++index) {
            append(bench[index], "bench_" + std::to_string(index));
        }
    }
    return result;
}

Value action_pending(
    const std::string &request_type,
    std::int32_t actor,
    std::int64_t minimum,
    std::int64_t maximum,
    bool can_cancel,
    Array options,
    const std::string &continuation_kind,
    bool finish_attack
) {
    Object metadata;
    metadata["continuation_kind"] = Value(continuation_kind);
    if (finish_attack) {
        metadata["finish_attack_actor"] = Value(actor);
    }
    Object request;
    request["request_type"] = Value(request_type);
    request["player"] = Value(actor);
    request["min_select"] = Value(minimum);
    request["max_select"] = Value(maximum);
    request["allow_duplicates"] = Value(false);
    request["can_cancel"] = Value(can_cancel);
    request["options"] = Value(std::move(options));
    request["metadata"] = Value(std::move(metadata));
    return Value(std::move(request));
}

void queue_promotion_if_possible(Value &state, std::int32_t owner) {
    if (pokemon(player(state, owner), "active") != nullptr) {
        return;
    }
    const Array &bench = required(player(state, owner), "bench").as_array();
    if (!std::any_of(
        bench.begin(),
        bench.end(),
        [](const Value &entry) { return entry.is_object(); }
    )) {
        return;
    }
    Array &pending = required(state, "pending_promotions").as_array();
    if (std::none_of(
        pending.begin(),
        pending.end(),
        [owner](const Value &entry) {
            return entry.as_integer(-1) == owner;
        }
    )) {
        pending.emplace_back(owner);
    }
}

void suspend_single_prize_choice(
    GameExecutionResult &result,
    std::int32_t prize_player
) {
    Array prize_options;
    const Array &prizes = required(
        player(result.state, prize_player),
        "prizes"
    ).as_array();
    for (std::size_t index = 0; index < prizes.size(); ++index) {
        prize_options.emplace_back(Object{
            {"kind", Value("id")},
            {
                "option_id",
                Value("prize:" + std::to_string(index)),
            },
        });
    }
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "select_prize",
        prize_player,
        1,
        1,
        false,
        std::move(prize_options),
        "select_prize",
        true
    );
    result.continuation = Value(Object{
        {"kind", Value("select_prize")},
        {"actor", Value(prize_player)},
    });
}

void suspend_prize_queue(
    GameExecutionResult &result,
    const std::vector<std::int32_t> &prize_players,
    std::int32_t attack_actor,
    const Value &attack_context
) {
    if (prize_players.empty()) {
        return;
    }
    suspend_single_prize_choice(result, prize_players.front());
    Array remaining;
    remaining.reserve(prize_players.size() - 1);
    for (std::size_t index = 1; index < prize_players.size(); ++index) {
        remaining.emplace_back(prize_players[index]);
    }
    result.continuation["remaining_prize_players"] = Value(
        std::move(remaining)
    );
    if (attack_actor == 0 || attack_actor == 1) {
        result.continuation["resume_attack_actor"] = Value(attack_actor);
        result.continuation["resume_attack_context"] = attack_context;
    }
}

std::int64_t knockout_prize_value(
    const Value &cards,
    const std::string &card_id
) {
    const Value *definition = card_definition(cards, card_id);
    return std::max<std::int64_t>(
        1,
        definition == nullptr
            ? 1
            : integer_arg(*definition, "prize_value", 1)
    );
}

void suspend_knockout_prizes(
    GameExecutionResult &result,
    const Value &cards,
    const std::string &defeated_card_id,
    std::int32_t prize_player,
    std::int32_t resume_attack_actor,
    const Value &resume_attack_context
) {
    const std::size_t available = required(
        player(result.state, prize_player),
        "prizes"
    ).as_array().size();
    const std::size_t count = std::min<std::size_t>(
        available,
        static_cast<std::size_t>(
            knockout_prize_value(cards, defeated_card_id)
        )
    );
    if (count == 0) {
        return;
    }
    suspend_prize_queue(
        result,
        std::vector<std::int32_t>(count, prize_player),
        resume_attack_actor,
        resume_attack_context
    );
}

bool settle_ability_effect_knockouts(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t effect_actor
) {
    struct KnockoutEntry {
        std::int32_t owner;
        std::string slot;
        std::string card_id;
        std::int64_t prize_value;
    };
    std::vector<KnockoutEntry> entries;
    const std::array<std::string, 6> slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (const std::int32_t owner : {1 - effect_actor, effect_actor}) {
        for (const std::string &slot : slots) {
            const Value *target = pokemon(player(result.state, owner), slot);
            if (
                target == nullptr
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
            ) {
                continue;
            }
            const std::string defeated_id = string_arg(*target, "card_id");
            entries.push_back(KnockoutEntry{
                owner,
                slot,
                defeated_id,
                knockout_prize_value(cards, defeated_id),
            });
        }
    }

    std::array<std::size_t, 2> prizes_remaining = {
        required(player(result.state, 0), "prizes").as_array().size(),
        required(player(result.state, 1), "prizes").as_array().size(),
    };
    std::vector<std::int32_t> prize_players;
    for (const KnockoutEntry &entry : entries) {
        const Value *target = pokemon(
            player(result.state, entry.owner),
            entry.slot
        );
        const std::string source_kind = target == nullptr
            ? std::string{}
            : string_arg(*target, "pending_ko_source_kind");
        append_knockout_fact(
            result.state,
            entry.card_id,
            entry.owner,
            effect_actor,
            source_kind == "damage_counters"
                ? "damage_counters"
                : "effect",
            source_kind.empty() ? "attack_effect" : source_kind,
            entry.slot
        );
        discard_pokemon(
            player(result.state, entry.owner),
            entry.slot
        );
        result.event_types.emplace_back("pokemon_ko");
        result.event_types.emplace_back("card_moved");
        const std::int32_t prize_player = 1 - entry.owner;
        for (
            std::int64_t prize = 0;
            prize < entry.prize_value
                && prizes_remaining[
                    static_cast<std::size_t>(prize_player)
                ] > 0;
            ++prize
        ) {
            prize_players.push_back(prize_player);
            --prizes_remaining[
                static_cast<std::size_t>(prize_player)
            ];
        }
    }
    queue_promotion_if_possible(result.state, 1 - effect_actor);
    queue_promotion_if_possible(result.state, effect_actor);
    if (!prize_players.empty()) {
        suspend_prize_queue(
            result,
            prize_players,
            -1,
            Value::make_object()
        );
    }
    return !entries.empty();
}

void finish_turn(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor
) {
    Value &state = result.state;
    std::vector<std::string> &event_types = result.event_types;
    event_types.emplace_back("turn_end");
    append_event(result, "turn_end", Object{
        {"actor", Value(actor)},
        {"player", Value(actor)},
        {"turn", Value(integer_arg(state, "turn_number"))},
        {"visibility", Value("public")},
    });
    event_types.emplace_back("checkup");
    append_event(result, "checkup", Object{
        {"actor", Value(actor)},
        {"outgoing_player", Value(actor)},
        {"turn", Value(integer_arg(state, "turn_number"))},
        {"visibility", Value("public")},
    });
    // Pokémon Checkup is a real settlement phase.  Keeping it visible in the
    // state is required when a checkup KO suspends for prize or promotion
    // choices; advancing the turn here used to leave lethally damaged Pokémon
    // in play and skipped those mandatory choices entirely.
    state["phase"] = Value("POKEMON_CHECKUP");
    expire_all_modifiers(state, integer_arg(state, "turn_number"));

    XorShift32 rng(result.rng_state);
    const auto has_status = [](const Value *target, const std::string &status) {
        return target != nullptr
            && array_contains_string(target->find("status_conditions"), status);
    };
    const auto remove_status = [](
        Value *target,
        const std::string &status
    ) {
        if (target == nullptr) {
            return false;
        }
        Value *conditions = target->find("status_conditions");
        if (conditions == nullptr || !conditions->is_array()) {
            return false;
        }
        const std::size_t before = conditions->as_array().size();
        conditions->as_array().erase(
            std::remove_if(
                conditions->as_array().begin(),
                conditions->as_array().end(),
                [&status](const Value &entry) {
                    return entry.string_or() == status;
                }
            ),
            conditions->as_array().end()
        );
        return conditions->as_array().size() != before;
    };
    const auto append_status_removed = [&result, &event_types](
        std::int32_t owner,
        const std::string &status,
        const std::string &cause
    ) {
        event_types.emplace_back("status_removed");
        append_event(result, "status_removed", Object{
            {"actor", Value(owner)},
            {"player", Value(owner)},
            {"target_player", Value(owner)},
            {"target_slot", Value("active")},
            {"slot", Value("active")},
            {"status", Value(status)},
            {"cause", Value(cause)},
            {"visibility", Value("public")},
        });
    };
    const auto place_checkup_counters = [
        &result,
        &cards,
        &state,
        &event_types
    ](
        std::int32_t owner,
        const std::string &status,
        std::int64_t amount
    ) {
        Value *target = pokemon(player(state, owner), "active");
        if (target == nullptr || amount <= 0) {
            return;
        }
        const std::int64_t maximum_hp = pokemon_hp(cards, *target);
        const bool was_knocked_out = maximum_hp > 0
            && integer_arg(*target, "damage_counters") * 10
                >= maximum_hp;
        add_damage(*target, amount);
        if (
            !was_knocked_out
            && maximum_hp > 0
            && integer_arg(*target, "damage_counters") * 10
                >= maximum_hp
            && target->find("pending_ko_source_kind") == nullptr
        ) {
            (*target)["pending_ko_source_kind"] = Value(
                "special_condition");
        }
        event_types.emplace_back("damage_counters_placed");
        append_event(result, "damage_counters_placed", Object{
            {"actor", Value(owner)},
            {"player", Value(owner)},
            {"target_player", Value(owner)},
            {"target_slot", Value("active")},
            {"slot", Value("active")},
            {"amount", Value(amount)},
            {"counter_count", Value((amount + 9) / 10)},
            {"damage_kind", Value("damage_counters")},
            {"source_kind", Value("special_condition")},
            {"status", Value(status)},
            {"visibility", Value("public")},
        });
    };
    const auto append_status_coin = [
        &result,
        &event_types
    ](
        std::int32_t owner,
        const std::string &purpose,
        bool heads
    ) {
        event_types.emplace_back("coin_flip");
        append_event(result, "coin_flip", Object{
            {"actor", Value(owner)},
            {"player", Value(owner)},
            {"results", Value(Array{Value(heads)})},
            {"purpose", Value(purpose)},
            {"visibility", Value("public")},
        });
    };

    // Official order: Poison, Burn, Sleep, Paralysis, then one simultaneous KO
    // check.  Both Active Pokémon remain eligible for every applicable step
    // even if an earlier step has already made one lethal.
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (has_status(target, "POISONED")) {
            place_checkup_counters(owner, "POISONED", 10);
        }
    }
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (!has_status(target, "BURNED")) {
            continue;
        }
        place_checkup_counters(owner, "BURNED", 20);
        const bool heads = rng.next_u32() < 0x80000000U;
        append_status_coin(owner, "burn_recovery", heads);
        if (heads && remove_status(target, "BURNED")) {
            append_status_removed(owner, "BURNED", "checkup_coin");
        }
    }
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (!has_status(target, "ASLEEP")) {
            continue;
        }
        const bool heads = rng.next_u32() < 0x80000000U;
        append_status_coin(owner, "sleep_recovery", heads);
        if (heads && remove_status(target, "ASLEEP")) {
            append_status_removed(owner, "ASLEEP", "checkup_coin");
        }
    }
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (
            has_status(target, "PARALYZED")
            && integer_arg(state, "turn_number")
                > integer_arg(*target, "paralyzed_since_turn")
            && remove_status(target, "PARALYZED")
        ) {
            append_status_removed(owner, "PARALYZED", "checkup_expiry");
        }
    }
    result.rng_state = rng.state();

    struct CheckupKnockout {
        std::int32_t owner;
        std::string slot;
        std::string card_id;
        std::int64_t prize_value;
        std::string cause_kind;
        std::string source_kind;
    };
    std::vector<CheckupKnockout> knockouts;
    const std::array<std::string, 6> checkup_slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (const std::int32_t owner : {1 - actor, actor}) {
        for (const std::string &slot : checkup_slots) {
            const Value *target = pokemon(player(state, owner), slot);
            if (
                target == nullptr
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
            ) {
                continue;
            }
            const std::string card_id = string_arg(*target, "card_id");
            const std::string source_kind = string_arg(
                *target,
                "pending_ko_source_kind",
                "effect_expiry"
            );
            knockouts.push_back(CheckupKnockout{
                owner,
                slot,
                card_id,
                knockout_prize_value(cards, card_id),
                source_kind == "special_condition"
                    ? "special_condition" : "effect",
                source_kind,
            });
        }
    }

    std::array<std::size_t, 2> prizes_remaining = {
        required(player(state, 0), "prizes").as_array().size(),
        required(player(state, 1), "prizes").as_array().size(),
    };
    std::vector<std::int32_t> prize_players;
    for (const CheckupKnockout &knockout : knockouts) {
        append_knockout_fact(
            state,
            knockout.card_id,
            knockout.owner,
            -1,
            knockout.cause_kind,
            knockout.source_kind,
            knockout.slot
        );
        discard_pokemon(
            player(state, knockout.owner), knockout.slot);
        event_types.emplace_back("pokemon_ko");
        append_event(result, "pokemon_ko", Object{
            {"actor", Value(knockout.owner)},
            {"player", Value(knockout.owner)},
            {"target_player", Value(knockout.owner)},
            {"target_slot", Value(knockout.slot)},
            {"slot", Value(knockout.slot)},
            {"card_id", Value(knockout.card_id)},
            {"cause_kind", Value(knockout.cause_kind)},
            {"source_kind", Value(knockout.source_kind)},
            {"visibility", Value("public")},
        });
        event_types.emplace_back("card_moved");
        const std::int32_t prize_player = 1 - knockout.owner;
        for (
            std::int64_t prize = 0;
            prize < knockout.prize_value
                && prizes_remaining[static_cast<std::size_t>(prize_player)] > 0;
            ++prize
        ) {
            prize_players.push_back(prize_player);
            --prizes_remaining[static_cast<std::size_t>(prize_player)];
        }
    }

    // If both Active Pokémon are Knocked Out between turns, the player whose
    // turn is about to begin promotes first.
    queue_promotion_if_possible(state, 1 - actor);
    queue_promotion_if_possible(state, actor);
    if (!prize_players.empty()) {
        suspend_prize_queue(
            result, prize_players, -1, Value::make_object());
        result.continuation["finish_checkup_after_prizes"] = Value(true);
        result.continuation["resume_checkup_actor"] = Value(actor);
        return;
    }
    if (finalize_terminal_if_needed(result)) {
        return;
    }
    const Value *promotions = state.find("pending_promotions");
    if (
        promotions != nullptr
        && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        return;
    }
    complete_checkup_transition(state, actor, event_types);
}

void suspend_after_damage_trigger_order(
    GameExecutionResult &result,
    std::int32_t attack_actor,
    std::int32_t trigger_owner,
    std::int64_t trigger_count,
    Array remaining_groups,
    const Value &attack_context
) {
    Array options;
    for (std::int64_t index = 0; index < trigger_count; ++index) {
        options.emplace_back(Object{
            {"kind", Value("id")},
            {
                "option_id",
                Value("trigger:" + std::to_string(index)),
            },
        });
    }
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "choose_trigger_order",
        trigger_owner,
        1,
        1,
        false,
        std::move(options),
        "after_damage_trigger_order",
        true
    );
    result.continuation = Value(Object{
        {"kind", Value("after_damage_trigger_order")},
        {"actor", Value(trigger_owner)},
        {"attack_actor", Value(attack_actor)},
        {"trigger_owner", Value(trigger_owner)},
        {"trigger_count", Value(trigger_count)},
        {"remaining_trigger_groups", Value(std::move(remaining_groups))},
        {"attack_context", attack_context},
    });
}

void suspend_public_trigger_order(
    GameExecutionResult &result,
    std::int32_t attack_actor,
    std::int32_t trigger_owner,
    Array trigger_specs,
    Array remaining_groups,
    const Value &attack_context
) {
    if (trigger_specs.size() < 2) {
        throw std::invalid_argument(
            "public_trigger_order_queue_invalid"
        );
    }
    Array options;
    options.reserve(trigger_specs.size());
    for (std::size_t index = 0; index < trigger_specs.size(); ++index) {
        options.emplace_back(Object{
            {"kind", Value("id")},
            {
                "option_id",
                Value("trigger:" + std::to_string(index)),
            },
        });
    }
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "choose_trigger_order",
        trigger_owner,
        1,
        1,
        false,
        std::move(options),
        "public_trigger_order",
        true
    );
    result.continuation = Value(Object{
        {"kind", Value("public_trigger_order")},
        {"actor", Value(trigger_owner)},
        {"attack_actor", Value(attack_actor)},
        {"trigger_owner", Value(trigger_owner)},
        {"trigger_specs", Value(std::move(trigger_specs))},
        {"remaining_trigger_groups", Value(std::move(remaining_groups))},
        {"attack_context", attack_context},
    });
}

void validate_public_trigger_spec(
    const Value &state,
    const Value &spec
) {
    if (!spec.is_object()) {
        throw std::invalid_argument("public_trigger_spec_invalid");
    }
    const std::string op = string_arg(spec, "op");
    const Value *args_value = spec.find("args");
    if (args_value == nullptr || !args_value->is_object()) {
        throw std::invalid_argument("public_trigger_spec_invalid");
    }
    const Value &args = *args_value;
    if (op == "trigger_draw_cards") {
        const std::int32_t owner = static_cast<std::int32_t>(
            integer_arg(args, "player", -1)
        );
        const std::int64_t amount = integer_arg(args, "amount");
        if (
            (owner != 0 && owner != 1)
            || amount <= 0
            || amount > 64
        ) {
            throw std::invalid_argument("public_trigger_spec_invalid");
        }
        return;
    }
    if (op == "trigger_place_damage_counters") {
        const std::int32_t owner = static_cast<std::int32_t>(
            integer_arg(args, "player", -1)
        );
        const std::string slot = string_arg(args, "slot");
        const std::int64_t count = integer_arg(args, "count");
        const std::string expected_card_id = string_arg(
            args,
            "target_card_id"
        );
        if (
            (owner != 0 && owner != 1)
            || slot.empty()
            || count <= 0
            || count > 100
            || expected_card_id.empty()
        ) {
            throw std::invalid_argument("public_trigger_spec_invalid");
        }
        const Value *target = pokemon(
            player(state, owner),
            slot
        );
        if (
            target == nullptr
            || string_arg(*target, "card_id") != expected_card_id
        ) {
            throw std::invalid_argument(
                "public_trigger_target_mismatch"
            );
        }
        return;
    }
    throw std::invalid_argument("public_trigger_spec_unsupported");
}

void apply_public_trigger_spec(
    GameExecutionResult &result,
    const Value &cards,
    const Value &spec
) {
    validate_public_trigger_spec(result.state, spec);
    const std::string op = string_arg(spec, "op");
    const Value &args = required(spec, "args");
    if (op == "trigger_draw_cards") {
        const std::int32_t owner = static_cast<std::int32_t>(
            integer_arg(args, "player", -1)
        );
        const std::int64_t amount = integer_arg(args, "amount");
        for (std::int64_t index = 0; index < amount; ++index) {
            Value &target_player = player(result.state, owner);
            const Array &deck = required(target_player, "deck").as_array();
            const Array &hand = required(target_player, "hand").as_array();
            if (deck.empty()) {
                break;
            }
            const std::string card_id = deck.back().string_or();
            const std::int64_t source_index = static_cast<std::int64_t>(
                deck.size() - 1);
            const std::int64_t target_index = static_cast<std::int64_t>(
                hand.size());
            draw_one(
                target_player,
                result.event_types
            );
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
                {"purpose", Value("public_trigger")},
                {"visibility", Value("owner")},
            });
        }
        return;
    }
    const std::int32_t owner = static_cast<std::int32_t>(
        integer_arg(args, "player", -1)
    );
    Value *target = pokemon(
        player(result.state, owner),
        string_arg(args, "slot")
    );
    if (
        target == nullptr
        || string_arg(*target, "card_id")
            != string_arg(args, "target_card_id")
    ) {
        return;
    }
    const std::int64_t amount = integer_arg(args, "count") * 10;
    const std::string slot = string_arg(args, "slot");
    const std::int64_t maximum_hp = pokemon_hp(cards, *target);
    const bool was_knocked_out = maximum_hp > 0
        && integer_arg(*target, "damage_counters") * 10 >= maximum_hp;
    add_damage(*target, amount);
    if (
        !was_knocked_out
        && maximum_hp > 0
        && integer_arg(*target, "damage_counters") * 10 >= maximum_hp
        && target->find("pending_ko_source_kind") == nullptr
    ) {
        (*target)["pending_ko_source_kind"] = Value("damage_counters");
    }
    result.event_types.emplace_back("damage_counters_placed");
    append_event(result, "damage_counters_placed", Object{
        {"actor", Value(owner)},
        {"player", Value(owner)},
        {"target_player", Value(owner)},
        {"target_slot", Value(slot)},
        {"slot", Value(slot)},
        {"amount", Value(amount)},
        {"counter_count", Value((amount + 9) / 10)},
        {"damage_kind", Value("damage_counters")},
        {"visibility", Value("public")},
    });
}

void validate_public_trigger_groups(
    const Value &state,
    const Array &groups,
    std::int32_t attack_actor,
    const char *error_code
) {
    if (attack_actor != 0 && attack_actor != 1) {
        throw std::invalid_argument(error_code);
    }
    std::int32_t previous_order = -1;
    std::size_t total_specs = 0;
    for (const Value &group : groups) {
        if (!group.is_object()) {
            throw std::invalid_argument(error_code);
        }
        const std::int32_t owner = static_cast<std::int32_t>(
            integer_arg(group, "owner", -1)
        );
        const Value *specs_value = group.find("specs");
        const std::int32_t order = owner == attack_actor
            ? 0
            : (owner == 1 - attack_actor ? 1 : -1);
        if (
            order <= previous_order
            || specs_value == nullptr
            || !specs_value->is_array()
            || specs_value->as_array().empty()
        ) {
            throw std::invalid_argument(error_code);
        }
        previous_order = order;
        total_specs += specs_value->as_array().size();
        if (total_specs > 64) {
            throw std::invalid_argument(error_code);
        }
        for (const Value &spec : specs_value->as_array()) {
            validate_public_trigger_spec(state, spec);
        }
    }
}

bool consume_public_trigger_groups(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t attack_actor,
    Array groups,
    const Value &attack_context,
    const char *error_code
) {
    validate_public_trigger_groups(
        result.state,
        groups,
        attack_actor,
        error_code
    );
    while (!groups.empty()) {
        Value group = std::move(groups.front());
        groups.erase(groups.begin());
        const std::int32_t owner = static_cast<std::int32_t>(
            integer_arg(group, "owner", -1)
        );
        Array specs = required(group, "specs").as_array();
        if (specs.size() > 1) {
            suspend_public_trigger_order(
                result,
                attack_actor,
                owner,
                std::move(specs),
                std::move(groups),
                attack_context
            );
            return true;
        }
        apply_public_trigger_spec(result, cards, specs.front());
    }
    return false;
}

bool is_basic_energy_id(
    const Value &cards,
    const std::string &card_id
) {
    const Value *definition = card_definition(cards, card_id);
    return definition != nullptr
        && is_energy_card(*definition)
        && card_has_subtype(*definition, "Basic");
}

bool is_exp_share_tool(
    const Value &cards,
    const std::string &card_id
) {
    const Value *definition = card_definition(cards, card_id);
    const Value *effects = definition == nullptr
        ? nullptr
        : definition->find("compiled_trainer_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    return std::any_of(
        effects->as_array().begin(),
        effects->as_array().end(),
        [](const Value &effect) {
            return string_arg(effect, "op") == "register_tool_exp_share";
        }
    );
}

void finalize_active_knockout(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t defeated_owner,
    std::int32_t prize_player
) {
    Value *defeated = pokemon(
        player(result.state, defeated_owner),
        "active"
    );
    if (defeated == nullptr) {
        return;
    }
    const std::string defeated_id = string_arg(*defeated, "card_id");
    player(result.state, defeated_owner)["was_ko_by_attack"] =
        Value(true);
    discard_active(player(result.state, defeated_owner));
    queue_promotion_if_possible(result.state, defeated_owner);
    result.event_types.emplace_back("pokemon_ko");
    result.event_types.emplace_back("card_moved");
    suspend_knockout_prizes(
        result,
        cards,
        defeated_id,
        prize_player
    );
}

void suspend_public_exp_share_spec_order(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &continuation,
    Array trigger_specs
);

void suspend_public_exp_share_spec_confirmation(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &outer_continuation,
    Value chosen,
    Array remaining
);

bool suspend_exp_share_trigger_if_available(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t attack_actor
) {
    const std::int32_t owner = 1 - attack_actor;
    Value &defending_player = player(result.state, owner);
    Value *defender = pokemon(defending_player, "active");
    if (
        defender == nullptr
        || string_arg(*defender, "pending_ko_source_kind")
            != "attack_damage"
    ) {
        return false;
    }
    const Array &energy = required(
        *defender,
        "energy_card_ids"
    ).as_array();
    if (std::none_of(
        energy.begin(),
        energy.end(),
        [&cards](const Value &entry) {
            return is_basic_energy_id(cards, entry.string_or());
        }
    )) {
        return false;
    }
    Array trigger_specs;
    const Array &bench = required(defending_player, "bench").as_array();
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (!bench[index].is_object()) {
            continue;
        }
        const std::string tool = string_arg(
            bench[index],
            "attached_tool_id"
        );
        if (tool.empty() || !is_exp_share_tool(cards, tool)) {
            continue;
        }
        trigger_specs.emplace_back(Object{
            {"from_player", Value(owner)},
            {"from_slot", Value("active")},
            {"from_card_id", Value(string_arg(*defender, "card_id"))},
            {"to_player", Value(owner)},
            {"to_slot", Value("bench_" + std::to_string(index))},
            {"to_card_id", Value(string_arg(bench[index], "card_id"))},
            {"target_tool_id", Value(tool)},
        });
    }
    if (trigger_specs.empty()) {
        return false;
    }

    Array knockout_entries;
    const std::array<std::string, 6> slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (const std::int32_t defeated_owner : {1 - attack_actor, attack_actor}) {
        for (const std::string &slot : slots) {
            const Value *target = pokemon(
                player(result.state, defeated_owner), slot);
            if (
                target == nullptr
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
            ) {
                continue;
            }
            knockout_entries.emplace_back(Object{
                {"player_idx", Value(defeated_owner)},
                {"slot", Value(slot)},
                {"card_id", Value(string_arg(*target, "card_id"))},
                {"prize_count", Value(knockout_prize_value(
                    cards, string_arg(*target, "card_id")))},
                {"source_kind", Value(string_arg(
                    *target,
                    "pending_ko_source_kind",
                    "attack_effect"
                ))},
            });
        }
    }
    Value outer_continuation(Object{
        {"knockout_entries", Value(std::move(knockout_entries))},
    });
    if (trigger_specs.size() > 1) {
        suspend_public_exp_share_spec_order(
            result,
            owner,
            attack_actor,
            outer_continuation,
            std::move(trigger_specs)
        );
    } else {
        Value chosen = std::move(trigger_specs.front());
        trigger_specs.clear();
        suspend_public_exp_share_spec_confirmation(
            result,
            owner,
            attack_actor,
            outer_continuation,
            std::move(chosen),
            std::move(trigger_specs)
        );
    }
    return true;
}

} // namespace ptcg::ai::game_detail

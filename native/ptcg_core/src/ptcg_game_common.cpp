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

void append_event(
    GameExecutionResult &result,
    const std::string &event_type,
    Object data
) {
    result.events.emplace_back(Object{
        {"event_type", Value(event_type)},
        {"data", Value(std::move(data))},
    });
}

void append_events(
    std::vector<Value> &destination,
    const std::vector<Value> &source
) {
    destination.insert(
        destination.end(),
        source.begin(),
        source.end()
    );
}

const Value &required(const Value &value, const std::string &key) {
    const Value *found = value.find(key);
    if (found == nullptr) {
        throw std::invalid_argument("missing_field:" + key);
    }
    return *found;
}

Value &required(Value &value, const std::string &key) {
    Value *found = value.find(key);
    if (found == nullptr) {
        throw std::invalid_argument("missing_field:" + key);
    }
    return *found;
}

std::string string_arg(
    const Value &value,
    const std::string &key,
    const std::string &fallback
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->string_or(fallback);
}

std::int64_t integer_arg(
    const Value &value,
    const std::string &key,
    std::int64_t fallback
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_integer(fallback);
}

bool bool_arg(
    const Value &value,
    const std::string &key,
    bool fallback
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_bool(fallback);
}

void set_integer(Value &value, const std::string &key, std::int64_t number) {
    value[key] = Value(number);
}

void increment(Value &value, const std::string &key) {
    set_integer(value, key, integer_arg(value, key) + 1);
}

Value &player(Value &state, std::int32_t actor) {
    if (actor < 0 || actor > 1) {
        throw std::invalid_argument("invalid_actor");
    }
    return required(state, "players").as_array().at(
        static_cast<std::size_t>(actor)
    );
}

const Value &player(const Value &state, std::int32_t actor) {
    if (actor < 0 || actor > 1) {
        throw std::invalid_argument("invalid_actor");
    }
    return required(state, "players").as_array().at(
        static_cast<std::size_t>(actor)
    );
}

const Value *card_definition(
    const Value &cards,
    const std::string &card_id
) {
    return cards.find(card_id);
}

bool energy_switches_with_active_on_attach(
    const Value &cards,
    const std::string &card_id,
    const std::string &target_slot
) {
    if (target_slot.rfind("bench_", 0) != 0) {
        return false;
    }
    const Value *definition = card_definition(cards, card_id);
    const Value *effects = definition != nullptr
        ? definition->find("energy_effects")
        : nullptr;
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    return std::any_of(
        effects->as_array().begin(),
        effects->as_array().end(),
        [](const Value &entry) {
            const Value *condition = entry.find("condition");
            const Value *effect = entry.find("effect");
            return entry.is_object()
                && string_arg(entry, "kind") == "trigger"
                && string_arg(entry, "hook") == "ON_ATTACH"
                && condition != nullptr
                && condition->is_object()
                && string_arg(*condition, "from_zone") == "hand"
                && string_arg(*condition, "target") == "bench"
                && effect != nullptr
                && effect->is_object()
                && string_arg(*effect, "op") == "switch_with_active";
        }
    );
}

Value *pokemon(Value &player_value, const std::string &slot) {
    if (slot == "active") {
        Value *active = player_value.find("active");
        return active != nullptr && active->is_object() ? active : nullptr;
    }
    constexpr const char *prefix = "bench_";
    if (slot.rfind(prefix, 0) != 0) {
        return nullptr;
    }
    const std::size_t index = static_cast<std::size_t>(
        std::stoul(slot.substr(6))
    );
    Array &bench = required(player_value, "bench").as_array();
    if (index >= bench.size() || !bench[index].is_object()) {
        return nullptr;
    }
    return &bench[index];
}

const Value *pokemon(
    const Value &player_value,
    const std::string &slot
) {
    if (slot == "active") {
        const Value *active = player_value.find("active");
        return active != nullptr && active->is_object()
            ? active
            : nullptr;
    }
    constexpr const char *prefix = "bench_";
    if (slot.rfind(prefix, 0) != 0) {
        return nullptr;
    }
    const std::size_t index = static_cast<std::size_t>(
        std::stoul(slot.substr(6))
    );
    const Array &bench = required(player_value, "bench").as_array();
    if (index >= bench.size() || !bench[index].is_object()) {
        return nullptr;
    }
    return &bench[index];
}

void clear_attack_effects_on_leave(Value &target) {
    target.erase("attack_locked");
    target.erase("attack_locked_names");
    target["damage_prevented"] = Value(false);
    target["all_prevented"] = Value(false);
    target["outgoing_damage_reduction"] = Value(0);
    Value *modifiers = target.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        return;
    }
    modifiers->as_array().erase(
        std::remove_if(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [](const Value &descriptor) {
                const std::string duration = string_arg(
                    descriptor,
                    "duration"
                );
                return duration != "persistent"
                    && duration != "until_leave_play";
            }
        ),
        modifiers->as_array().end()
    );
}

void switch_active(Value &player_value, const std::string &bench_slot) {
    Value *active = pokemon(player_value, "active");
    Value *bench_target = pokemon(player_value, bench_slot);
    if (active == nullptr || bench_target == nullptr) {
        throw std::invalid_argument("switch_target_invalid");
    }
    (*active)["status_conditions"] = Value::make_array();
    (*active)["paralyzed_since_turn"] = Value(0);
    clear_attack_effects_on_leave(*active);
    std::swap(*active, *bench_target);
}

void append_slot_transition_event(
    GameExecutionResult &result,
    const std::string &event_type,
    std::int32_t actor,
    std::int32_t target_player,
    const std::string &bench_slot,
    const std::string &outgoing_card_id,
    const std::string &incoming_card_id,
    const std::string &reason
) {
    if (bench_slot.rfind("bench_", 0) != 0) {
        throw std::invalid_argument("slot_transition_target_not_bench");
    }
    const std::int64_t bench_idx = static_cast<std::int64_t>(
        std::stoll(bench_slot.substr(6))
    );
    Array card_ids;
    if (!outgoing_card_id.empty()) {
        card_ids.emplace_back(outgoing_card_id);
    }
    if (!incoming_card_id.empty()) {
        card_ids.emplace_back(incoming_card_id);
    }
    const std::int64_t card_count = static_cast<std::int64_t>(card_ids.size());
    result.event_types.emplace_back(event_type);
    append_event(result, event_type, Object{
        {"actor", Value(actor)},
        {"player", Value(target_player)},
        {"slot", Value(bench_slot)},
        {"bench_idx", Value(bench_idx)},
        {"outgoing_card_id", Value(outgoing_card_id)},
        {"incoming_card_id", Value(incoming_card_id)},
        {"card_ids", Value(std::move(card_ids))},
        {"count", Value(card_count)},
        {"reason", Value(reason)},
        {"visibility", Value("public")},
    });
}

void switch_active_with_event(
    GameExecutionResult &result,
    Value &player_value,
    std::int32_t actor,
    std::int32_t target_player,
    const std::string &bench_slot,
    const std::string &event_type,
    const std::string &reason
) {
    const Value &outgoing = required(player_value, "active");
    const Value *incoming = pokemon(player_value, bench_slot);
    if (!outgoing.is_object() || incoming == nullptr) {
        throw std::invalid_argument("switch_target_invalid");
    }
    const std::string outgoing_card_id = string_arg(outgoing, "card_id");
    const std::string incoming_card_id = string_arg(*incoming, "card_id");
    switch_active(player_value, bench_slot);
    append_slot_transition_event(
        result,
        event_type,
        actor,
        target_player,
        bench_slot,
        outgoing_card_id,
        incoming_card_id,
        reason
    );
}

Value make_pokemon(const std::string &card_id, bool placed_this_turn) {
    Object result;
    result["attached_tool_id"] = Value("");
    result["can_evolve_this_turn"] = Value(true);
    result["card_id"] = Value(card_id);
    result["damage_counters"] = Value(0);
    result["energy_card_ids"] = Value::make_array();
    result["evolution_stack_ids"] = Value::make_array();
    result["damage_prevented"] = Value(false);
    result["all_prevented"] = Value(false);
    result["outgoing_damage_reduction"] = Value(0);
    result["healed_this_turn"] = Value(false);
    result["paralyzed_since_turn"] = Value(0);
    result["placed_this_turn"] = Value(placed_this_turn);
    result["status_conditions"] = Value::make_array();
    result["used_abilities"] = Value::make_array();
    return Value(std::move(result));
}

bool array_contains_string(const Value *value, const std::string &needle) {
    if (value == nullptr || !value->is_array()) {
        return false;
    }
    return std::any_of(
        value->as_array().begin(),
        value->as_array().end(),
        [&needle](const Value &entry) {
            return entry.string_or() == needle;
        }
    );
}

bool card_has_subtype(const Value &card, const std::string &subtype) {
    return array_contains_string(card.find("subtypes"), subtype);
}

bool is_pokemon_card(const Value &card) {
    return integer_arg(card, "hp") > 0
        && string_arg(card, "supertype") != "Energy"
        && string_arg(card, "supertype") != "Trainer";
}

bool is_basic_pokemon(const Value &card) {
    return is_pokemon_card(card) && card_has_subtype(card, "Basic");
}

bool is_energy_card(const Value &card) {
    return string_arg(card, "supertype") == "Energy";
}

bool is_trainer_card(const Value &card) {
    return string_arg(card, "supertype") == "Trainer";
}

bool is_tool_card(const Value &card) {
    return (
        string_arg(card, "trainer_type") == "Tool"
        || card_has_subtype(card, "Tool")
    );
}

bool is_supporter_card(const Value &card) {
    return (
        string_arg(card, "trainer_type") == "Supporter"
        || card_has_subtype(card, "Supporter")
    );
}

bool is_stadium_card(const Value &card) {
    return (
        string_arg(card, "trainer_type") == "Stadium"
        || card_has_subtype(card, "Stadium")
    );
}

Value card_ref(
    std::int32_t actor,
    const std::string &zone,
    std::size_t index,
    const std::string &card_id
) {
    return Value(Object{
        {"kind", Value("card")},
        {"player", Value(actor)},
        {"zone", Value(zone)},
        {"index", Value(static_cast<std::int64_t>(index))},
        {"card_id", Value(card_id)},
    });
}

Value pokemon_ref(
    std::int32_t actor,
    const std::string &slot,
    const Value &pokemon_value
) {
    return Value(Object{
        {"kind", Value("pokemon")},
        {"player", Value(actor)},
        {"slot", Value(slot)},
        {"card_id", Value(string_arg(pokemon_value, "card_id"))},
    });
}

Value slot_ref(std::int32_t actor, const std::string &slot) {
    return Value(Object{
        {"kind", Value("slot")},
        {"player", Value(actor)},
        {"slot", Value(slot)},
    });
}

Value make_action(
    const Value &state,
    const std::string &kind,
    std::int32_t actor,
    Value source,
    Value target,
    Value payload
) {
    return Value(Object{
        {"schema_version", Value(4)},
        {"action_id", Value("")},
        {"base_revision", Value(integer_arg(state, "revision", -1))},
        {"actor", Value(actor)},
        {"kind", Value(kind)},
        {"source", std::move(source)},
        {"target", std::move(target)},
        {"payload", std::move(payload)},
    });
}

void append_pokemon_rows(
    const Value &player_value,
    std::vector<std::pair<std::string, const Value *>> &rows
) {
    const Value *active = player_value.find("active");
    if (active != nullptr && active->is_object()) {
        rows.emplace_back("active", active);
    }
    const Value::Array &bench = required(player_value, "bench").as_array();
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (bench[index].is_object()) {
            rows.emplace_back(
                "bench_" + std::to_string(index),
                &bench[index]
            );
        }
    }
}

bool is_player_first_turn(
    const Value &state,
    std::int32_t actor
) {
    const std::int64_t turn = integer_arg(state, "turn_number");
    const std::int64_t first = integer_arg(state, "first_player_idx", -1);
    return actor == first ? turn == 1 : turn == 2;
}

std::vector<std::string> energy_units(
    const Value &cards,
    const Value &pokemon_value
) {
    std::vector<std::string> result;
    const Value *attached = pokemon_value.find("energy_card_ids");
    if (attached == nullptr || !attached->is_array()) {
        return result;
    }
    const Array &attached_cards = attached->as_array();
    for (
        std::size_t card_index = 0;
        card_index < attached_cards.size();
        ++card_index
    ) {
        const Value *card = card_definition(
            cards,
            attached_cards[card_index].string_or()
        );
        if (card == nullptr) {
            continue;
        }
        bool downgrade_rainbow = false;
        const Value *energy_effects = card->find("energy_effects");
        if (energy_effects != nullptr && energy_effects->is_array()) {
            downgrade_rainbow = std::any_of(
                energy_effects->as_array().begin(),
                energy_effects->as_array().end(),
                [](const Value &effect) {
                    return (
                        effect.is_object()
                        && string_arg(effect, "kind")
                            == "provide_energy"
                        && bool_arg(
                            effect,
                            "downgrade_if_other_special"
                        )
                    );
                }
            );
        }
        if (downgrade_rainbow) {
            downgrade_rainbow = false;
            for (
                std::size_t other_index = 0;
                other_index < attached_cards.size();
                ++other_index
            ) {
                if (other_index == card_index) {
                    continue;
                }
                const Value *other = card_definition(
                    cards,
                    attached_cards[other_index].string_or()
                );
                if (
                    other != nullptr
                    && card_has_subtype(*other, "Special")
                ) {
                    downgrade_rainbow = true;
                    break;
                }
            }
        }
        const Value *provided = card->find("provides_energy");
        if (provided == nullptr || !provided->is_array()) {
            continue;
        }
        for (const Value &unit : provided->as_array()) {
            const std::string energy_type = unit.string_or();
            result.push_back(
                downgrade_rainbow && energy_type == "Rainbow"
                ? "Colorless"
                : energy_type
            );
        }
    }
    return result;
}

std::int64_t energy_card_unit_count(
    const Value &cards,
    const std::string &card_id
) {
    const Value *card = card_definition(cards, card_id);
    const Value *provided = card != nullptr
        ? card->find("provides_energy")
        : nullptr;
    return (
        provided != nullptr && provided->is_array()
    ) ? static_cast<std::int64_t>(provided->as_array().size()) : 0;
}

bool attached_tool_damage_boost_targets_active(
    const Value &cards,
    const Value &attacker
) {
    const std::string tool_id = string_arg(attacker, "attached_tool_id");
    const Value *definition = tool_id.empty()
        ? nullptr
        : card_definition(cards, tool_id);
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
            const Value *args = effect.find("args");
            if (
                string_arg(effect, "op") != "register_tool_modifier"
                || args == nullptr
                || !args->is_object()
            ) {
                return false;
            }
            const std::string name = string_arg(*args, "effect");
            return name == "damage_boost_10"
                || name == "damage_boost_when_behind";
        }
    );
}

std::int64_t attached_attack_damage_delta(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &attacker,
    bool target_is_opponent_active
) {
    std::int64_t result = 0;
    const Value *energy = attacker.find("energy_card_ids");
    if (energy != nullptr && energy->is_array()) {
        for (const Value &entry : energy->as_array()) {
            const Value *definition = card_definition(
                cards,
                entry.string_or()
            );
            const Value *effects = definition != nullptr
                ? definition->find("energy_effects")
                : nullptr;
            if (effects == nullptr || !effects->is_array()) {
                continue;
            }
            for (const Value &effect : effects->as_array()) {
                const Value *operation = effect.find("effect");
                if (
                    effect.is_object()
                    && string_arg(effect, "kind") == "modifier"
                    && string_arg(effect, "hook") == "MODIFY_DAMAGE"
                    && string_arg(effect, "scope")
                        == "attached_attacker"
                    && operation != nullptr
                    && operation->is_object()
                ) {
                    result += integer_arg(*operation, "delta");
                }
            }
        }
    }
    const Value *modifiers = attacker.find("modifiers");
    if (modifiers != nullptr && modifiers->is_array()) {
        for (const Value &modifier : modifiers->as_array()) {
            const Value *operation = modifier.find("operation");
            const Value *condition = modifier.find("condition");
            if (
                condition != nullptr
                && condition->is_object()
                && bool_arg(*condition, "target_active")
                && !target_is_opponent_active
            ) {
                continue;
            }
            if (
                !target_is_opponent_active
                && string_arg(modifier, "scope") == "attached_attacker"
                && attached_tool_damage_boost_targets_active(
                    cards,
                    attacker
                )
            ) {
                continue;
            }
            if (
                condition != nullptr
                && condition->is_object()
                && bool_arg(*condition, "behind_on_prizes")
                && required(
                    player(state, actor),
                    "prizes"
                ).as_array().size() <= required(
                    player(state, 1 - actor),
                    "prizes"
                ).as_array().size()
            ) {
                continue;
            }
            if (
                modifier.is_object()
                && string_arg(modifier, "hook") == "MODIFY_DAMAGE"
                && (
                    string_arg(modifier, "scope")
                        == "attached_attacker"
                    || (
                        string_arg(modifier, "scope") == "self"
                        && string_arg(modifier, "layer")
                            == "attacker_adjust"
                    )
                )
                && operation != nullptr
                && operation->is_object()
                && string_arg(*operation, "kind") == "damage_delta"
            ) {
                result += integer_arg(*operation, "amount");
            }
        }
    }
    const std::int64_t legacy_reduction = std::max<std::int64_t>(
        0,
        integer_arg(attacker, "outgoing_damage_reduction")
    );
    if (legacy_reduction > 0) {
        const bool represented_by_modifier = (
            modifiers != nullptr
            && modifiers->is_array()
            && std::any_of(
                modifiers->as_array().begin(),
                modifiers->as_array().end(),
                [legacy_reduction](const Value &modifier) {
                    const Value *operation = modifier.find("operation");
                    return modifier.is_object()
                        && string_arg(modifier, "hook") == "MODIFY_DAMAGE"
                        && string_arg(modifier, "scope") == "self"
                        && string_arg(modifier, "layer")
                            == "attacker_adjust"
                        && string_arg(modifier, "stacking") == "maximum"
                        && operation != nullptr
                        && operation->is_object()
                        && string_arg(*operation, "kind") == "damage_delta"
                        && integer_arg(*operation, "amount")
                            == -legacy_reduction;
                }
            )
        );
        if (!represented_by_modifier) {
            result -= legacy_reduction;
        }
    }
    return result;
}

std::int64_t field_aura_attack_damage_delta(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &attacker,
    const Value &defender,
    bool target_is_opponent_active
) {
    if (!target_is_opponent_active) {
        return 0;
    }
    const Value *attacker_definition = card_definition(
        cards,
        string_arg(attacker, "card_id")
    );
    const Value *defender_definition = card_definition(
        cards,
        string_arg(defender, "card_id")
    );
    if (attacker_definition == nullptr || defender_definition == nullptr) {
        return 0;
    }
    std::int64_t result = 0;
    const std::array<std::string, 6> slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (const std::string &slot : slots) {
        const Value *source = pokemon(player(state, actor), slot);
        const Value *source_definition = source == nullptr
            ? nullptr
            : card_definition(cards, string_arg(*source, "card_id"));
        const Value *abilities = source_definition == nullptr
            ? nullptr
            : source_definition->find("abilities");
        if (abilities == nullptr || !abilities->is_array()) {
            continue;
        }
        for (const Value &ability : abilities->as_array()) {
            const Value *effects = ability.find("compiled_effects");
            if (effects == nullptr || !effects->is_array()) {
                continue;
            }
            for (const Value &effect : effects->as_array()) {
                if (string_arg(effect, "op") != "register_aura_damage_boost") {
                    continue;
                }
                const Value *args = effect.find("args");
                if (args == nullptr || !args->is_object()) {
                    continue;
                }
                const std::string attacker_subtype = string_arg(
                    *args,
                    "attacker_subtype"
                );
                if (
                    !attacker_subtype.empty()
                    && !card_has_subtype(
                        *attacker_definition,
                        attacker_subtype
                    )
                ) {
                    continue;
                }
                const std::string defender_type = string_arg(
                    *args,
                    "defender_type"
                );
                if (
                    !defender_type.empty()
                    && !array_contains_string(
                        defender_definition->find("energy_types"),
                        defender_type
                    )
                ) {
                    continue;
                }
                result += integer_arg(*args, "amount");
            }
        }
    }
    return result;
}

bool defender_modifier_condition_applies(
    const Value &cards,
    const Value &defender,
    const Value &descriptor,
    bool defender_is_active
) {
    const Value *condition = descriptor.find("condition");
    if (condition == nullptr || !condition->is_object()) {
        return true;
    }
    if (bool_arg(*condition, "target_active") && !defender_is_active) {
        return false;
    }
    if (
        bool_arg(*condition, "requires_attached_energy")
        && required(defender, "energy_card_ids").as_array().empty()
    ) {
        return false;
    }
    const std::string target_stage = string_arg(
        *condition,
        "target_stage"
    );
    if (!target_stage.empty()) {
        const Value *definition = card_definition(
            cards,
            string_arg(defender, "card_id")
        );
        if (definition == nullptr) {
            return false;
        }
        if (
            target_stage == "stage1"
            && !card_has_subtype(*definition, "Stage 1")
        ) {
            return false;
        }
        if (
            target_stage == "stage2"
            && !card_has_subtype(*definition, "Stage 2")
        ) {
            return false;
        }
    }
    return true;
}

std::int64_t aura_damage_reduction_delta(
    const Value &cards,
    const Value &defender,
    bool defender_is_active,
    bool before_weakness
) {
    std::int64_t result = 0;
    const Value *defender_definition = card_definition(
        cards,
        string_arg(defender, "card_id")
    );
    const Value *abilities = defender_definition != nullptr
        ? defender_definition->find("abilities")
        : nullptr;
    if (abilities != nullptr && abilities->is_array()) {
        for (const Value &ability : abilities->as_array()) {
            const Value *effects = ability.find("compiled_effects");
            if (effects == nullptr || !effects->is_array()) {
                continue;
            }
            for (const Value &effect : effects->as_array()) {
                if (
                    string_arg(effect, "op")
                        != "register_aura_damage_reduction"
                ) {
                    continue;
                }
                const Value *args = effect.find("args");
                if (args == nullptr || !args->is_object()) {
                    continue;
                }
                if (
                    bool_arg(*args, "before_weakness")
                    != before_weakness
                ) {
                    continue;
                }
                // Active-spot auras modify the opposing attack as a whole,
                // including damage to the Bench. They are applied from the
                // board-level helper below instead of as a target modifier.
                if (bool_arg(*args, "requires_active")) {
                    continue;
                }
                if (
                    bool_arg(*args, "requires_active")
                    && !defender_is_active
                ) {
                    continue;
                }
                if (
                    bool_arg(*args, "requires_attached_energy")
                    && required(
                        defender,
                        "energy_card_ids"
                    ).as_array().empty()
                ) {
                    continue;
                }
                result -= std::abs(integer_arg(
                    *args,
                    "reduction"
                ));
            }
        }
    }
    return result;
}

std::int64_t opponent_active_aura_attack_damage_delta(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    bool before_weakness
) {
    const Value *source = pokemon(player(state, 1 - actor), "active");
    const Value *definition = source == nullptr
        ? nullptr
        : card_definition(cards, string_arg(*source, "card_id"));
    const Value *abilities = definition == nullptr
        ? nullptr
        : definition->find("abilities");
    if (source == nullptr || abilities == nullptr || !abilities->is_array()) {
        return 0;
    }
    std::int64_t result = 0;
    for (const Value &ability : abilities->as_array()) {
        const Value *effects = ability.find("compiled_effects");
        if (effects == nullptr || !effects->is_array()) {
            continue;
        }
        for (const Value &effect : effects->as_array()) {
            if (
                string_arg(effect, "op")
                    != "register_aura_damage_reduction"
            ) {
                continue;
            }
            const Value *args = effect.find("args");
            if (
                args == nullptr
                || !args->is_object()
                || !bool_arg(*args, "requires_active")
                || bool_arg(*args, "before_weakness") != before_weakness
                || (
                    bool_arg(*args, "requires_attached_energy")
                    && required(*source, "energy_card_ids").as_array().empty()
                )
            ) {
                continue;
            }
            result -= std::abs(integer_arg(*args, "reduction"));
        }
    }
    return result;
}

std::int64_t attached_defender_damage_delta(
    const Value &cards,
    const Value &defender,
    bool defender_is_active
) {
    std::int64_t result = aura_damage_reduction_delta(
        cards,
        defender,
        defender_is_active,
        false
    );
    const Value *energy = defender.find("energy_card_ids");
    if (energy != nullptr && energy->is_array()) {
        for (const Value &entry : energy->as_array()) {
            const Value *definition = card_definition(
                cards,
                entry.string_or()
            );
            const Value *effects = definition != nullptr
                ? definition->find("energy_effects")
                : nullptr;
            if (effects == nullptr || !effects->is_array()) {
                continue;
            }
            for (const Value &effect : effects->as_array()) {
                const Value *operation = effect.find("effect");
                if (
                    effect.is_object()
                    && string_arg(effect, "kind") == "modifier"
                    && string_arg(effect, "hook") == "MODIFY_DAMAGE"
                    && string_arg(effect, "scope")
                        == "attached_defender"
                    && operation != nullptr
                    && operation->is_object()
                ) {
                    result += integer_arg(*operation, "delta");
                }
            }
        }
    }
    const Value *modifiers = defender.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        return result;
    }
    for (const Value &modifier : modifiers->as_array()) {
        const Value *operation = modifier.find("operation");
        if (
            !modifier.is_object()
            || string_arg(modifier, "hook") != "MODIFY_DAMAGE"
            || (
                string_arg(modifier, "scope") != "attached_defender"
                && !(
                    string_arg(modifier, "scope") == "self"
                    && string_arg(modifier, "layer")
                        == "defender_adjust"
                )
            )
            || operation == nullptr
            || !operation->is_object()
            || string_arg(*operation, "kind") != "damage_delta"
            || !defender_modifier_condition_applies(
                cards,
                defender,
                modifier,
                defender_is_active
            )
        ) {
            continue;
        }
        result += integer_arg(*operation, "amount");
    }
    return result;
}

bool defender_prevents_attack_damage(const Value &defender) {
    const Value *modifiers = defender.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        return false;
    }
    return std::any_of(
        modifiers->as_array().begin(),
        modifiers->as_array().end(),
        [](const Value &modifier) {
            const Value *operation = modifier.find("operation");
            return modifier.is_object()
                && string_arg(modifier, "hook") == "MODIFY_DAMAGE"
                && operation != nullptr
                && operation->is_object()
                && string_arg(*operation, "kind")
                    == "prevent_damage";
        }
    );
}

std::int64_t signed_number_in_text(
    const std::string &text,
    std::int64_t fallback
) {
    bool negative = false;
    bool saw_digit = false;
    std::int64_t result = 0;
    for (const unsigned char character : text) {
        if (!saw_digit && character == '-') {
            negative = true;
            continue;
        }
        if (character < '0' || character > '9') {
            continue;
        }
        saw_digit = true;
        result = result * 10 + static_cast<std::int64_t>(character - '0');
    }
    if (!saw_digit) {
        return fallback;
    }
    return negative ? -result : result;
}

bool type_matchups_enabled(const Value &state) {
    const Value *options = state.find("rules_options");
    return options != nullptr && options->is_object()
        ? bool_arg(
            *options,
            "apply_type_matchups",
            bool_arg(state, "apply_type_matchups")
        )
        : bool_arg(state, "apply_type_matchups");
}

std::int64_t apply_active_type_matchups(
    const Value &cards,
    const Value &state,
    const Value &attacker,
    const Value &defender,
    std::int64_t damage,
    bool ignore_weakness,
    bool ignore_resistance
) {
    if (!type_matchups_enabled(state) || damage <= 0) {
        return std::max<std::int64_t>(0, damage);
    }
    const Value *attacker_definition = card_definition(
        cards, string_arg(attacker, "card_id"));
    const Value *defender_definition = card_definition(
        cards, string_arg(defender, "card_id"));
    const Value *attacker_types = attacker_definition != nullptr
        ? attacker_definition->find("energy_types") : nullptr;
    if (
        attacker_types == nullptr
        || !attacker_types->is_array()
        || defender_definition == nullptr
    ) {
        return std::max<std::int64_t>(0, damage);
    }
    const auto matches_attacker_type = [attacker_types](
        const Value &entry
    ) {
        const std::string target_type = string_arg(entry, "energy_type");
        return !target_type.empty() && std::any_of(
            attacker_types->as_array().begin(),
            attacker_types->as_array().end(),
            [&target_type](const Value &type) {
                return type.string_or() == target_type;
            }
        );
    };
    if (!ignore_weakness) {
        const Value *weaknesses = defender_definition->find("weaknesses");
        if (weaknesses != nullptr && weaknesses->is_array()) {
            const auto matching = std::find_if(
                weaknesses->as_array().begin(),
                weaknesses->as_array().end(),
                matches_attacker_type
            );
            if (matching != weaknesses->as_array().end()) {
                const std::int64_t multiplier = std::max<std::int64_t>(
                    1,
                    signed_number_in_text(
                        string_arg(*matching, "value"),
                        integer_arg(*matching, "multiplier", 2)
                    )
                );
                damage *= multiplier;
            }
        }
    }
    if (!ignore_resistance) {
        const Value *resistances = defender_definition->find("resistances");
        if (resistances != nullptr && resistances->is_array()) {
            const auto matching = std::find_if(
                resistances->as_array().begin(),
                resistances->as_array().end(),
                matches_attacker_type
            );
            if (matching != resistances->as_array().end()) {
                damage += signed_number_in_text(
                    string_arg(*matching, "value"),
                    integer_arg(*matching, "amount", -30)
                );
            }
        }
    }
    return std::max<std::int64_t>(0, damage);
}

std::string lower_ascii(std::string value) {
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char character) {
            return static_cast<char>(std::tolower(character));
        }
    );
    return value;
}

bool pokemon_has_matching_attached_energy(
    const Value &cards,
    const Value &pokemon_value,
    const std::string &filter
) {
    const Value *attached = pokemon_value.find("energy_card_ids");
    if (attached == nullptr || !attached->is_array()) {
        return false;
    }
    std::string normalized = lower_ascii(filter);
    if (normalized == "any" || normalized == "energy") {
        return !attached->as_array().empty();
    }
    if (normalized == "basic" || normalized == "basic_energy") {
        return std::any_of(
            attached->as_array().begin(),
            attached->as_array().end(),
            [&cards](const Value &entry) {
                const Value *definition = card_definition(
                    cards,
                    entry.string_or()
                );
                return definition != nullptr
                    && card_has_subtype(*definition, "Basic");
            }
        );
    }
    const std::vector<std::string> units = energy_units(
        cards,
        pokemon_value
    );
    return std::any_of(
        units.begin(),
        units.end(),
        [&normalized](const std::string &unit) {
            const std::string available = lower_ascii(unit);
            return available == normalized || available == "rainbow";
        }
    );
}

bool pokemon_has_energy_type(
    const Value &cards,
    const Value &pokemon_value,
    const std::string &required_type
) {
    const std::string required = lower_ascii(required_type);
    if (required.empty()) {
        return true;
    }
    const std::vector<std::string> units = energy_units(
        cards,
        pokemon_value
    );
    return std::any_of(
        units.begin(),
        units.end(),
        [&required](const std::string &unit) {
            const std::string normalized = lower_ascii(unit);
            return normalized == required || normalized == "rainbow";
        }
    );
}

std::int64_t effective_retreat_cost(
    const Value &cards,
    const Value &state,
    const Value &active,
    const Value *active_card
) {
    std::int64_t cost = active_card != nullptr
        ? integer_arg(*active_card, "retreat_cost")
        : 0;

    const Value *abilities = active_card != nullptr
        ? active_card->find("abilities")
        : nullptr;
    if (abilities != nullptr && abilities->is_array()) {
        for (const Value &ability : abilities->as_array()) {
            const Value *effects = ability.find("compiled_effects");
            if (effects == nullptr || !effects->is_array()) {
                continue;
            }
            for (const Value &effect : effects->as_array()) {
                if (
                    string_arg(effect, "op")
                    != "register_conditional_zero_retreat"
                ) {
                    continue;
                }
                const Value *args = effect.find("args");
                if (
                    args == nullptr
                    || pokemon_has_energy_type(
                        cards,
                        active,
                        string_arg(*args, "energy_type")
                    )
                ) {
                    cost = 0;
                }
            }
        }
    }

    const std::string stadium_id = string_arg(
        state,
        "stadium_card_id"
    );
    const Value *stadium = card_definition(cards, stadium_id);
    if (
        stadium != nullptr
        && active_card != nullptr
        && is_basic_pokemon(*active_card)
    ) {
        const Value *effects = stadium->find("compiled_trainer_effects");
        if (effects != nullptr && effects->is_array()) {
            for (const Value &effect : effects->as_array()) {
                if (string_arg(effect, "op") != "stadium") {
                    continue;
                }
                const Value *args = effect.find("args");
                if (
                    args != nullptr
                    && string_arg(*args, "effect")
                        == "reduce_retreat_cost_basics"
                ) {
                    cost -= integer_arg(*args, "amount", 1);
                }
            }
        }
    }

    const Value *modifiers = active.find("modifiers");
    if (modifiers != nullptr && modifiers->is_array()) {
        for (const Value &modifier : modifiers->as_array()) {
            if (!modifier.is_object()) {
                continue;
            }
            const std::string legacy_kind = string_arg(
                modifier,
                "modifier_kind",
                string_arg(modifier, "effect_type")
            );
            if (legacy_kind == "conditional_zero_retreat") {
                const Value *params = modifier.find("params");
                if (
                    params == nullptr
                    || pokemon_has_energy_type(
                        cards,
                        active,
                        string_arg(*params, "energy_type")
                    )
                ) {
                    cost = 0;
                }
                continue;
            }
            if (string_arg(modifier, "hook") != "CAN_RETREAT") {
                continue;
            }
            const Value *condition = modifier.find("condition");
            if (
                condition != nullptr
                && !pokemon_has_energy_type(
                    cards,
                    active,
                    string_arg(*condition, "energy_type")
                )
            ) {
                continue;
            }
            const Value *operation = modifier.find("operation");
            if (operation == nullptr || !operation->is_object()) {
                continue;
            }
            const std::string kind = string_arg(*operation, "kind");
            if (kind == "retreat_delta") {
                cost += integer_arg(*operation, "amount");
            } else if (kind == "retreat_set") {
                cost = integer_arg(*operation, "value", cost);
            }
        }
    }
    return std::max<std::int64_t>(0, cost);
}

bool can_pay_attack_cost(
    const Value &cards,
    const Value &pokemon_value,
    const Value &cost_value
) {
    if (!cost_value.is_array()) {
        return true;
    }
    std::vector<std::string> available = energy_units(
        cards,
        pokemon_value
    );
    std::size_t colorless = 0;
    for (const Value &required_value : cost_value.as_array()) {
        const std::string required_type = required_value.string_or();
        if (required_type == "Colorless") {
            ++colorless;
            continue;
        }
        auto found = std::find(
            available.begin(),
            available.end(),
            required_type
        );
        if (found == available.end()) {
            found = std::find(
                available.begin(),
                available.end(),
                "Rainbow"
            );
        }
        if (found == available.end()) {
            return false;
        }
        available.erase(found);
    }
    return available.size() >= colorless;
}

bool attack_is_locked(
    const Value &pokemon_value,
    const std::string &attack_name
) {
    if (bool_arg(pokemon_value, "attack_locked")) {
        return true;
    }
    const Value *locked_names = pokemon_value.find(
        "attack_locked_names"
    );
    if (
        locked_names != nullptr
        && locked_names->is_object()
        && (
            locked_names->find("__all__") != nullptr
            || locked_names->find(attack_name) != nullptr
        )
    ) {
        return true;
    }
    const Value *modifiers = pokemon_value.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        return false;
    }
    for (const Value &descriptor : modifiers->as_array()) {
        if (!descriptor.is_object()) {
            continue;
        }
        const Value *operation = descriptor.find("operation");
        if (
            operation == nullptr
            || !operation->is_object()
            || string_arg(*operation, "kind") != "attack_lock"
        ) {
            continue;
        }
        const std::string locked_name = string_arg(
            *operation,
            "attack_name",
            string_arg(*operation, "reason")
        );
        if (
            locked_name.empty()
            || locked_name == "__all__"
            || locked_name == attack_name
        ) {
            return true;
        }
    }
    return false;
}

bool player_attack_name_is_locked(
    const Value &player_value,
    const std::string &attack_name,
    std::int64_t turn
) {
    const Value *locked_names = player_value.find("attack_locked_names");
    if (locked_names == nullptr || !locked_names->is_object()) {
        return false;
    }
    const Value *expires_after_turn = locked_names->find(attack_name);
    return expires_after_turn != nullptr
        && expires_after_turn->as_integer(-1) >= turn;
}


} // namespace ptcg::ai::game_detail

#include "ptcg_game.hpp"

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

namespace ptcg::ai {

namespace {

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
    const std::string &fallback = {}
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->string_or(fallback);
}

std::int64_t integer_arg(
    const Value &value,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *found = value.find(key);
    return found == nullptr ? fallback : found->as_integer(fallback);
}

bool bool_arg(
    const Value &value,
    const std::string &key,
    bool fallback = false
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
    Value source = Value(),
    Value target = Value(),
    Value payload = Value::make_object()
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

std::int64_t attached_attack_damage_delta(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &attacker
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

bool defender_modifier_condition_applies(
    const Value &cards,
    const Value &defender,
    const Value &descriptor
) {
    const Value *condition = descriptor.find("condition");
    if (condition == nullptr || !condition->is_object()) {
        return true;
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

std::int64_t attached_defender_damage_delta(
    const Value &cards,
    const Value &defender
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
                modifier
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

bool ability_is_discard_revive(const Value &ability) {
    const Value *effects = ability.find("compiled_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    for (const Value &effect : effects->as_array()) {
        if (effect.is_object() && string_arg(effect, "op")
            == "discard_then_revive") {
            return true;
        }
    }
    return false;
}

bool rare_candy_has_target(
    const Value &cards,
    const Value &owner,
    std::size_t source_index
) {
    const Array &hand = required(owner, "hand").as_array();
    std::vector<std::string> basic_names;
    std::vector<std::pair<std::string, const Value *>> pokemon_rows;
    append_pokemon_rows(owner, pokemon_rows);
    for (const auto &[slot, pokemon_value] : pokemon_rows) {
        (void)slot;
        if (
            bool_arg(*pokemon_value, "placed_this_turn")
            || !bool_arg(
                *pokemon_value,
                "can_evolve_this_turn",
                true
            )
        ) {
            continue;
        }
        const Value *definition = card_definition(
            cards,
            string_arg(*pokemon_value, "card_id")
        );
        if (definition != nullptr && is_basic_pokemon(*definition)) {
            basic_names.push_back(string_arg(*definition, "name"));
        }
    }
    if (basic_names.empty()) {
        return false;
    }
    for (std::size_t index = 0; index < hand.size(); ++index) {
        if (index == source_index) {
            continue;
        }
        const Value *stage_two = card_definition(
            cards,
            hand[index].string_or()
        );
        if (
            stage_two == nullptr
            || !card_has_subtype(*stage_two, "Stage 2")
        ) {
            continue;
        }
        const std::string stage_one_name = string_arg(
            *stage_two,
            "evolves_from"
        );
        for (const auto &[card_id, candidate] : cards.as_object()) {
            (void)card_id;
            if (
                !candidate.is_object()
                || string_arg(candidate, "name") != stage_one_name
            ) {
                continue;
            }
            const std::string basic_name = string_arg(
                candidate,
                "evolves_from"
            );
            if (
                std::find(
                    basic_names.begin(),
                    basic_names.end(),
                    basic_name
                ) != basic_names.end()
            ) {
                return true;
            }
        }
    }
    return false;
}

bool card_matches_filter(
    const Value &cards,
    const Value &card_id,
    const std::string &filter,
    const std::string &filter_name = {}
) {
    const Value *card = card_definition(cards, card_id.string_or());
    if (card == nullptr) {
        return false;
    }
    if (!filter_name.empty()) {
        return string_arg(*card, "name") == filter_name;
    }
    std::string normalized = filter;
    std::transform(
        normalized.begin(),
        normalized.end(),
        normalized.begin(),
        [](unsigned char value) {
            return static_cast<char>(std::tolower(value));
        }
    );
    if (normalized.empty() || normalized == "any") {
        return true;
    }
    const bool pokemon_card = is_pokemon_card(*card);
    const bool energy_card = is_energy_card(*card);
    const bool basic_energy = (
        energy_card && card_has_subtype(*card, "Basic")
    );
    if (normalized == "basic_pokemon") {
        return is_basic_pokemon(*card);
    }
    if (normalized == "pokemon") {
        return pokemon_card;
    }
    if (
        normalized == "basic"
        || normalized == "basic_energy"
        || normalized == "basic_energy_card"
    ) {
        return basic_energy;
    }
    if (
        normalized == "energy"
        || normalized == "energy_card"
    ) {
        return energy_card;
    }
    if (normalized == "supporter") {
        return is_supporter_card(*card);
    }
    if (normalized == "item") {
        return (
            is_trainer_card(*card)
            && string_arg(*card, "trainer_type") == "Item"
        );
    }
    if (normalized == "item_or_tool") {
        return (
            is_tool_card(*card)
            || (
                is_trainer_card(*card)
                && string_arg(*card, "trainer_type") == "Item"
            )
        );
    }
    if (normalized == "pokemon_and_energy") {
        return pokemon_card || basic_energy;
    }
    if (normalized == "grass_pokemon") {
        return (
            pokemon_card
            && array_contains_string(card->find("energy_types"), "Grass")
        );
    }
    if (normalized == "water_pokemon_and_energy") {
        return (
            (
                pokemon_card
                && array_contains_string(
                    card->find("energy_types"),
                    "Water"
                )
            )
            || (
                energy_card
                && array_contains_string(
                    card->find("provides_energy"),
                    "Water"
                )
            )
        );
    }
    constexpr std::string_view suffix = "_energy";
    if (
        normalized.size() > suffix.size()
        && normalized.compare(
            normalized.size() - suffix.size(),
            suffix.size(),
            suffix
        ) == 0
    ) {
        normalized.resize(normalized.size() - suffix.size());
        if (normalized == "basic") {
            return basic_energy;
        }
        const Value *provided = card->find("provides_energy");
        if (provided == nullptr || !provided->is_array()) {
            return false;
        }
        return std::any_of(
            provided->as_array().begin(),
            provided->as_array().end(),
            [&normalized](const Value &unit) {
                std::string available = unit.string_or();
                std::transform(
                    available.begin(),
                    available.end(),
                    available.begin(),
                    [](unsigned char value) {
                        return static_cast<char>(std::tolower(value));
                    }
                );
                return available == normalized;
            }
        );
    }
    const bool named_energy_type = (
        normalized == "grass"
        || normalized == "fire"
        || normalized == "water"
        || normalized == "lightning"
        || normalized == "psychic"
        || normalized == "fighting"
        || normalized == "darkness"
        || normalized == "metal"
        || normalized == "dragon"
        || normalized == "colorless"
    );
    if (named_energy_type && !energy_card) {
        return false;
    }
    if (energy_card) {
        const Value *provided = card->find("provides_energy");
        if (provided != nullptr && provided->is_array()) {
            return std::any_of(
                provided->as_array().begin(),
                provided->as_array().end(),
                [&normalized](const Value &unit) {
                    std::string available = unit.string_or();
                    std::transform(
                        available.begin(),
                        available.end(),
                        available.begin(),
                        [](unsigned char value) {
                            return static_cast<char>(
                                std::tolower(value)
                            );
                        }
                    );
                    return available == normalized;
                }
            );
        }
    }
    return true;
}

bool zone_has_matching_card(
    const Value &cards,
    const Value &owner,
    const std::string &zone,
    const Value &args
) {
    const Value *rows = owner.find(zone);
    if (rows == nullptr || !rows->is_array()) {
        return false;
    }
    const std::string filter = string_arg(args, "filter", "any");
    const std::string filter_name = string_arg(args, "filter_name");
    return std::any_of(
        rows->as_array().begin(),
        rows->as_array().end(),
        [&cards, &filter, &filter_name](const Value &card_id) {
            return card_matches_filter(
                cards,
                card_id,
                filter,
                filter_name
            );
        }
    );
}

std::size_t occupied_bench_count(const Value &owner) {
    const Value *bench = owner.find("bench");
    if (bench == nullptr || !bench->is_array()) {
        return 0;
    }
    return static_cast<std::size_t>(std::count_if(
        bench->as_array().begin(),
        bench->as_array().end(),
        [](const Value &row) {
            return row.is_object();
        }
    ));
}

bool pokemon_matches_type(
    const Value &cards,
    const Value &pokemon_value,
    const std::string &required_type
) {
    if (required_type.empty()) {
        return true;
    }
    const Value *card = card_definition(
        cards,
        string_arg(pokemon_value, "card_id")
    );
    return (
        card != nullptr
        && array_contains_string(
            card->find("energy_types"),
            required_type
        )
    );
}

bool has_energy_target(
    const Value &cards,
    const Value &owner,
    const Value &args,
    const std::string &source_slot = {}
) {
    const std::string target = string_arg(
        args,
        "target",
        string_arg(args, "to", "self")
    );
    const std::string effective_target = (
        string_arg(args, "destination") == "bench_energy"
    ) ? "bench" : target;
    const std::string required_type = string_arg(
        args,
        "target_pokemon_type"
    );
    std::vector<std::pair<std::string, const Value *>> rows;
    append_pokemon_rows(owner, rows);
    return std::any_of(
        rows.begin(),
        rows.end(),
        [
            &cards,
            &effective_target,
            &required_type,
            &source_slot
        ](const auto &row) {
            if (
                effective_target == "self"
                && row.first != (
                    source_slot.empty() ? "active" : source_slot
                )
            ) {
                return false;
            }
            if (
                effective_target == "bench"
                && row.first.rfind("bench_", 0) != 0
            ) {
                return false;
            }
            if (
                effective_target == "self_basic"
                && (
                    card_definition(
                        cards,
                        string_arg(*row.second, "card_id")
                    ) == nullptr
                    || !is_basic_pokemon(*card_definition(
                        cards,
                        string_arg(*row.second, "card_id")
                    ))
                )
            ) {
                return false;
            }
            return pokemon_matches_type(
                cards,
                *row.second,
                required_type
            );
        }
    );
}

bool previous_turn_had_knockout(
    const Value &state,
    std::int32_t actor
) {
    const Value *book = state.find("turn_fact_book");
    const Value *previous = (
        book != nullptr && book->is_object()
    ) ? book->find("previous_turn") : nullptr;
    const Value *knockouts = (
        previous != nullptr && previous->is_object()
    ) ? previous->find("knockouts") : nullptr;
    if (knockouts == nullptr || !knockouts->is_array()) {
        return false;
    }
    return std::any_of(
        knockouts->as_array().begin(),
        knockouts->as_array().end(),
        [actor](const Value &fact) {
            return (
                fact.is_object()
                && integer_arg(fact, "defeated_player", -1) == actor
            );
        }
    );
}

bool effect_list_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effects,
    std::size_t source_hand_index,
    const std::string &source_slot = {}
);

bool effect_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effect,
    std::size_t source_hand_index,
    const std::string &source_slot
) {
    if (!effect.is_object()) {
        return false;
    }
    const std::string op = string_arg(effect, "op");
    const Value empty_args = Value::make_object();
    const Value *args_value = effect.find("args");
    const Value &args = (
        args_value != nullptr && args_value->is_object()
    ) ? *args_value : empty_args;
    const Value &owner = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    if (
        op == "draw_cards"
        || op == "draw_until"
        || op == "draw_until_more_than_opponent"
        || op == "judge"
        || op == "trekking_shoes"
        || op == "discard_then_draw_cards"
        || op == "shuffle_then_draw_cards"
        || op == "register_tool_modifier"
        || op == "register_tool_exp_share"
    ) {
        return true;
    }
    if (op == "look_top_deck") {
        if (
            string_arg(args, "destination", "hand")
                == "bench_energy"
            && !has_energy_target(cards, owner, args, source_slot)
        ) {
            return false;
        }
        return (
            integer_arg(args, "count", 1) > 0
            && !required(owner, "deck").as_array().empty()
        );
    }
    if (op == "search_item_and_tool") {
        return !required(owner, "deck").as_array().empty();
    }
    if (op == "search_cards") {
        const std::string destination = string_arg(
            args,
            "destination",
            "hand"
        );
        if (
            destination == "bench"
            && occupied_bench_count(owner) >= 5
        ) {
            return false;
        }
        const std::string from_zone = string_arg(
            args,
            "from_zone",
            "deck"
        );
        if (from_zone == "deck") {
            return (
                integer_arg(args, "count", 1) > 0
                && !required(owner, "deck").as_array().empty()
            );
        }
        return zone_has_matching_card(
            cards,
            owner,
            from_zone,
            args
        );
    }
    if (op == "shuffle_from_discard_to_deck") {
        return zone_has_matching_card(
            cards,
            owner,
            "discard",
            args
        );
    }
    if (op == "switch_pokemon") {
        const Value &target_owner = string_arg(args, "target", "self")
            == "opponent" ? opponent : owner;
        return (
            target_owner.find("active") != nullptr
            && target_owner.find("active")->is_object()
            && occupied_bench_count(target_owner) > 0
        );
    }
    if (op == "choose_heal_damage" || op == "heal_all") {
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(owner, rows);
        return std::any_of(
            rows.begin(),
            rows.end(),
            [](const auto &row) {
                return integer_arg(*row.second, "damage_counters") > 0;
            }
        );
    }
    if (op == "heal_damage") {
        const std::string target = string_arg(args, "target", "self");
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(owner, rows);
        return std::any_of(
            rows.begin(),
            rows.end(),
            [&target, &source_slot](const auto &row) {
                if (
                    target == "self"
                    && row.first != (
                        source_slot.empty() ? "active" : source_slot
                    )
                ) {
                    return false;
                }
                return integer_arg(*row.second, "damage_counters") > 0;
            }
        );
    }
    if (op == "attach_energy") {
        // The formal command treats an empty matching source as a successful
        // no-op, allowing later effects in the same ability to continue.  If
        // matching energy does exist, however, a required missing target is
        // an action failure.  Preserve that distinction (notably Xatu's
        // attach-then-draw ability) instead of reducing the list to "any
        // visible effect".
        const std::string from_zone = string_arg(
            args,
            "from_zone",
            "hand"
        );
        if (!zone_has_matching_card(
                cards,
                owner,
                from_zone,
                args
            )) {
            return true;
        }
        return has_energy_target(cards, owner, args, source_slot);
    }
    if (op == "attach_energy_from_discard") {
        return (
            has_energy_target(cards, owner, args, source_slot)
            && zone_has_matching_card(
                cards,
                owner,
                "discard",
                Value(Value::Object{
                    {
                        "filter",
                        Value(string_arg(
                            args,
                            "energy_type",
                            "any"
                        ))
                    },
                })
            )
        );
    }
    if (op == "relocate_energy") {
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(owner, rows);
        if (rows.size() < 2) {
            return false;
        }
        const std::string energy_type = string_arg(
            args,
            "energy_type",
            "any"
        );
        return std::any_of(
            rows.begin(),
            rows.end(),
            [&cards, &energy_type](const auto &row) {
                const Value *energy = row.second->find(
                    "energy_card_ids"
                );
                return (
                    energy != nullptr
                    && energy->is_array()
                    && std::any_of(
                        energy->as_array().begin(),
                        energy->as_array().end(),
                        [&cards, &energy_type](const Value &card_id) {
                            return card_matches_filter(
                                cards,
                                card_id,
                                energy_type
                            );
                        }
                    )
                );
            }
        );
    }
    if (op == "evolve_skip_stage") {
        if (is_player_first_turn(state, actor)) {
            return false;
        }
        return rare_candy_has_target(
            cards,
            owner,
            source_hand_index
        );
    }
    if (op == "hand_to_bottom_then_draw") {
        return required(owner, "hand").as_array().size() > 1;
    }
    if (op == "hand_to_bottom_draw_until") {
        return required(owner, "hand").as_array().size() > 2;
    }
    if (op == "zinnia_resolve") {
        return required(owner, "hand").as_array().size() > 2;
    }
    if (op == "recover_clara") {
        const Value &discard = required(owner, "discard");
        return std::any_of(
            discard.as_array().begin(),
            discard.as_array().end(),
            [&cards](const Value &card_id) {
                const Value *card = card_definition(
                    cards,
                    card_id.string_or()
                );
                return (
                    card != nullptr
                    && (
                        is_pokemon_card(*card)
                        || (
                            is_energy_card(*card)
                            && card_has_subtype(*card, "Basic")
                        )
                    )
                );
            }
        );
    }
    if (op == "draw_and_attach_energy") {
        return (
            occupied_bench_count(owner) > 0
            && (
                !required(owner, "deck").as_array().empty()
                || zone_has_matching_card(
                    cards,
                    owner,
                    "hand",
                    Value(Value::Object{{
                        "filter",
                        Value(
                            string_arg(args, "energy_type", "Grass")
                            + "_energy"
                        ),
                    }})
                )
            )
        );
    }
    if (op == "flip_coin") {
        const Value *branches = effect.find("branches");
        if (branches == nullptr || !branches->is_object()) {
            return true;
        }
        for (const auto &[name, branch] : branches->as_object()) {
            (void)name;
            if (
                branch.is_array()
                && effect_list_has_visible_target(
                    cards,
                    state,
                    actor,
                    branch,
                    source_hand_index,
                    source_slot
                )
            ) {
                return true;
            }
        }
        return false;
    }
    if (op == "flip_coin_then_discard_energy") {
        std::vector<std::pair<std::string, const Value *>> rows;
        append_pokemon_rows(opponent, rows);
        return std::any_of(
            rows.begin(),
            rows.end(),
            [](const auto &row) {
                const Value *energy = row.second->find("energy_card_ids");
                return (
                    energy != nullptr
                    && energy->is_array()
                    && !energy->as_array().empty()
                );
            }
        );
    }
    if (op == "conditional") {
        const std::string condition = string_arg(args, "condition");
        if (
            condition == "ko_last_opponent_turn"
            && !previous_turn_had_knockout(state, actor)
        ) {
            return false;
        }
        const Value *branches = effect.find("branches");
        if (branches == nullptr || !branches->is_object()) {
            return true;
        }
        const Value *cost = branches->find("cost");
        if (cost != nullptr && cost->is_array()) {
            for (const Value &cost_effect : cost->as_array()) {
                if (
                    string_arg(cost_effect, "op") == "discard_cards"
                ) {
                    const Value *cost_args = cost_effect.find("args");
                    const std::int64_t amount = (
                        cost_args != nullptr && cost_args->is_object()
                    ) ? integer_arg(*cost_args, "amount") : 0;
                    if (
                        static_cast<std::int64_t>(
                            required(owner, "hand").as_array().size()
                        ) - 1 < amount
                    ) {
                        return false;
                    }
                }
            }
        }
        const Value *on_pay = branches->find("on_pay");
        return (
            on_pay == nullptr
            || !on_pay->is_array()
            || effect_list_has_visible_target(
                cards,
                state,
                actor,
                *on_pay,
                source_hand_index,
                source_slot
            )
        );
    }
    return true;
}

bool effect_list_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effects,
    std::size_t source_hand_index,
    const std::string &source_slot
) {
    if (!effects.is_array() || effects.as_array().empty()) {
        return true;
    }
    bool has_visible_effect = false;
    for (const Value &effect : effects.as_array()) {
        has_visible_effect = has_visible_effect
            || effect_has_visible_target(
                cards,
                state,
                actor,
                effect,
                source_hand_index,
                source_slot
            );
    }
    return has_visible_effect;
}

bool ability_effect_list_has_visible_target(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const Value &effects,
    const std::string &source_slot
) {
    if (!effects.is_array() || effects.as_array().empty()) {
        return true;
    }
    // A required attach with matching source energy but no target fails the
    // whole ability before later effects execute.  An empty source is a
    // successful no-op, which effect_has_visible_target already distinguishes.
    for (const Value &effect : effects.as_array()) {
        if (
            string_arg(effect, "op") == "attach_energy"
            && !effect_has_visible_target(
                cards,
                state,
                actor,
                effect,
                std::numeric_limits<std::size_t>::max(),
                source_slot
            )
        ) {
            return false;
        }
    }
    return effect_list_has_visible_target(
        cards,
        state,
        actor,
        effects,
        std::numeric_limits<std::size_t>::max(),
        source_slot
    );
}

bool stadium_has_activation(const Value &card) {
    const Value *effects = card.find("compiled_trainer_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    for (const Value &effect : effects->as_array()) {
        if (!effect.is_object()) {
            continue;
        }
        const std::string op = string_arg(effect, "op");
        if (op != "stadium" && op != "set_stadium") {
            return true;
        }
    }
    return false;
}

std::string stable_choice_option_id(
    const Value &option,
    const std::string &request_type
) {
    std::string result = string_arg(option, "option_id");
    if (!result.empty()) {
        return result;
    }
    const Value *nested_ref = option.find("ref");
    const Value &ref = (
        nested_ref != nullptr && nested_ref->is_object()
    ) ? *nested_ref : option;
    const std::string kind = string_arg(ref, "kind");
    const std::int64_t owner = integer_arg(ref, "player", -1);
    if (request_type == "select_retreat_payment") {
        return "retreat:energy:" + std::to_string(
            integer_arg(ref, "index", -1)
        );
    }
    if (kind == "card") {
        return "card:" + std::to_string(owner)
            + ":" + string_arg(ref, "zone")
            + ":" + std::to_string(integer_arg(ref, "index", -1))
            + ":" + string_arg(ref, "card_id");
    }
    if (kind == "pokemon") {
        return "pokemon:" + std::to_string(owner)
            + ":" + string_arg(ref, "slot")
            + ":" + string_arg(ref, "card_id");
    }
    if (kind == "slot") {
        return "slot:" + std::to_string(owner)
            + ":" + string_arg(ref, "slot");
    }
    if (kind == "attachment") {
        return "attachment:" + std::to_string(owner)
            + ":" + string_arg(ref, "slot")
            + ":" + string_arg(ref, "attachment_type")
            + ":" + std::to_string(integer_arg(ref, "index", -1))
            + ":" + string_arg(ref, "card_id");
    }
    return {};
}

void append_choice_candidate(
    Array &result,
    const std::string &request_id,
    const std::string &request_type,
    const std::vector<const Value *> &selected,
    bool cancelled
) {
    Array option_ids;
    std::string signature = "choice:" + request_id + ":";
    for (std::size_t index = 0; index < selected.size(); ++index) {
        const std::string option_id = stable_choice_option_id(
            *selected[index],
            request_type
        );
        if (option_id.empty()) {
            throw std::invalid_argument(
                "choice_option_signature_unavailable"
            );
        }
        option_ids.emplace_back(option_id);
        if (index > 0) {
            signature += "|";
        }
        signature += option_id;
    }
    if (cancelled) {
        signature += "cancel";
    }
    Object candidate{
        {"kind", Value("choice")},
        {"signature", Value(signature)},
        {"request_id", Value(request_id)},
        {"request_type", Value(request_type)},
        {"selected_options", Value(std::move(option_ids))},
        {"cancelled", Value(cancelled)},
    };
    if (!selected.empty()) {
        const Value *ref = selected.front()->find("ref");
        candidate["ref"] = ref != nullptr ? *ref : Value();
    } else {
        candidate["ref"] = Value();
    }
    result.emplace_back(std::move(candidate));
}

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
    draw_one(next_player, events);
}

void finish_turn(
    Value &state,
    std::int32_t actor,
    std::vector<std::string> &events,
    std::uint32_t *rng_state = nullptr
) {
    events.emplace_back("turn_end");
    events.emplace_back("checkup");
    expire_all_modifiers(
        state,
        integer_arg(state, "turn_number")
    );
    XorShift32 rng(rng_state == nullptr ? 1U : *rng_state);
    const auto has_status = [](const Value *target, const std::string &status) {
        return target != nullptr
            && array_contains_string(
                target->find("status_conditions"),
                status
            );
    };
    const auto remove_status = [](
        Value *target,
        const std::string &status
    ) {
        if (target == nullptr) {
            return;
        }
        Value *conditions = target->find("status_conditions");
        if (conditions == nullptr || !conditions->is_array()) {
            return;
        }
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
    };
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (has_status(target, "POISONED")) {
            add_damage(*target, 10);
        }
    }
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (!has_status(target, "BURNED")) {
            continue;
        }
        add_damage(*target, 20);
        if (rng.next_u32() < 0x80000000U) {
            remove_status(target, "BURNED");
        }
    }
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (
            has_status(target, "ASLEEP")
            && rng.next_u32() < 0x80000000U
        ) {
            remove_status(target, "ASLEEP");
        }
    }
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value *target = pokemon(player(state, owner), "active");
        if (
            has_status(target, "PARALYZED")
            && integer_arg(state, "turn_number")
                > integer_arg(*target, "paralyzed_since_turn")
        ) {
            remove_status(target, "PARALYZED");
        }
    }
    if (rng_state != nullptr) {
        *rng_state = rng.state();
    }
    complete_checkup_transition(state, actor, events);
}

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
    const std::string &cause_kind = "damage",
    const std::string &source_kind = "attack_damage",
    const std::string &slot = "active"
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
    std::int32_t resume_attack_actor = -1,
    const Value &resume_attack_context = Value::make_object()
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
    for (std::int32_t owner = 0; owner < 2; ++owner) {
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
    queue_promotion_if_possible(result.state, 0);
    queue_promotion_if_possible(result.state, 1);
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
            draw_one(
                player(result.state, owner),
                result.event_types
            );
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
    add_damage(*target, integer_arg(args, "count") * 10);
    result.event_types.emplace_back("damage_counters_placed");
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
        apply_public_trigger_spec(result, specs.front());
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

bool suspend_exp_share_trigger_if_available(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t attack_actor
) {
    const std::int32_t owner = 1 - attack_actor;
    Value &defending_player = player(result.state, owner);
    Value *defender = pokemon(defending_player, "active");
    if (defender == nullptr) {
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
        defending_player["was_ko_by_attack"] = Value(true);
        append_knockout_fact(
            result.state,
            string_arg(*defender, "card_id"),
            owner,
            attack_actor
        );
        increment(result.state, "choice_sequence");
        result.pending = action_pending(
            "confirm_trigger",
            owner,
            1,
            1,
            false,
            {
                Value(Object{
                    {"kind", Value("id")},
                    {"option_id", Value("confirm:yes")},
                }),
                Value(Object{
                    {"kind", Value("id")},
                    {"option_id", Value("confirm:no")},
                }),
            },
            "confirm_exp_share_trigger",
            true
        );
        result.continuation = Value(Object{
            {"kind", Value("confirm_exp_share_trigger")},
            {"actor", Value(owner)},
            {"attack_actor", Value(attack_actor)},
            {"from_player", Value(owner)},
            {"from_slot", Value("active")},
            {
                "from_card_id",
                Value(string_arg(*defender, "card_id")),
            },
            {"to_player", Value(owner)},
            {
                "to_slot",
                Value("bench_" + std::to_string(index)),
            },
            {
                "to_card_id",
                Value(string_arg(bench[index], "card_id")),
            },
            {"target_tool_id", Value(tool)},
        });
        return true;
    }
    return false;
}

void append_serialized_modifier(
    Value &target,
    Object descriptor
);

void append_canonical_modifier(
    Value &target,
    const Value &source,
    const std::string &op,
    const Value &args,
    std::int32_t actor,
    const std::string &source_slot,
    std::int32_t target_player,
    std::int64_t turn
) {
    if (op == "prevent_all") {
        append_canonical_modifier(
            target,
            source,
            "prevent_damage",
            args,
            actor,
            source_slot,
            target_player,
            turn
        );
        append_canonical_modifier(
            target,
            source,
            "prevent_effects",
            args,
            actor,
            source_slot,
            target_player,
            turn
        );
        return;
    }
    Value *modifiers = target.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        target["modifiers"] = Value::make_array();
        modifiers = target.find("modifiers");
    } else {
        modifiers->as_array().erase(
            std::remove_if(
                modifiers->as_array().begin(),
                modifiers->as_array().end(),
                [](const Value &entry) {
                    return entry.is_object()
                        && entry.find("native_op") != nullptr;
                }
            ),
            modifiers->as_array().end()
        );
    }
    Object descriptor;
    descriptor["condition"] = Value::make_object();
    descriptor["conflict_policy"] = Value("commutative");
    descriptor["controller"] = Value(target_player);
    descriptor["priority"] = Value(0);
    descriptor["scope"] = Value("self");
    descriptor["source_ref"] = Value(Object{
        {"card_id", Value(string_arg(source, "card_id"))},
        {"kind", Value("pokemon")},
        {"player", Value(actor)},
        {"slot", Value(source_slot)},
    });
    descriptor["stacking"] = Value("replace_same_source");
    if (op == "prevent_damage") {
        descriptor["duration"] = Value("until_end_of_opponents_next_turn");
        descriptor["hook"] = Value("MODIFY_DAMAGE");
        descriptor["layer"] = Value("prevent");
        descriptor["operation"] = Value(Object{
            {"kind", Value("prevent_damage")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
        });
    } else if (op == "prevent_effects") {
        descriptor["duration"] = Value("until_end_of_opponents_next_turn");
        descriptor["hook"] = Value("PREVENT_EFFECTS");
        descriptor["layer"] = Value("prevent");
        descriptor["operation"] = Value(Object{
            {"kind", Value("prevent_effects")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
        });
    } else if (op == "apply_attack_lock_basic") {
        descriptor["duration"] = Value("until_end_of_turn");
        descriptor["hook"] = Value("CAN_ATTACK");
        descriptor["layer"] = Value("permission");
        descriptor["operation"] = Value(Object{
            {"attack_name", Value("__all__")},
            {"kind", Value("attack_lock")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
            {"target_basic", Value(true)},
        });
    } else if (op == "apply_dazzling_beam") {
        descriptor["duration"] = Value("until_next_attack");
        descriptor["hook"] = Value("CAN_ATTACK");
        descriptor["layer"] = Value("gate");
        descriptor["operation"] = Value(Object{
            {"kind", Value("attack_gate_coin")},
            {"reason", Value("dazzled")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 1)},
        });
    } else if (op == "apply_outgoing_damage_reduction") {
        descriptor["duration"] = Value("until_end_of_turn");
        descriptor["hook"] = Value("MODIFY_DAMAGE");
        descriptor["layer"] = Value("attacker_adjust");
        descriptor["operation"] = Value(Object{
            {
                "amount",
                Value(-std::abs(integer_arg(args, "amount")))
            },
            {"kind", Value("damage_delta")},
        });
        descriptor["condition"] = Value(Object{
            {
                "expires_after_turn",
                Value(turn + (target_player == actor ? 0 : 1))
            },
        });
        descriptor["stacking"] = Value("maximum");
    } else if (op == "apply_self_attack_lock") {
        const std::string lock_key = (
            string_arg(args, "scope") == "all"
        ) ? "__all__" : string_arg(args, "attack_name");
        descriptor["duration"] = Value("until_end_of_opponents_next_turn");
        descriptor["hook"] = Value("CAN_ATTACK");
        descriptor["layer"] = Value("permission");
        descriptor["operation"] = Value(Object{
            {"attack_name", Value(lock_key)},
            {"kind", Value("attack_lock")},
        });
        descriptor["condition"] = Value(Object{
            {"expires_after_turn", Value(turn + 2)},
        });
    } else {
        return;
    }
    append_serialized_modifier(target, std::move(descriptor));
}

bool same_modifier_source(
    const Value *left,
    const Value *right
) {
    if (
        left == nullptr
        || right == nullptr
        || !left->is_object()
        || !right->is_object()
    ) {
        return false;
    }
    return string_arg(*left, "kind") == string_arg(*right, "kind")
        && integer_arg(*left, "player", -1)
            == integer_arg(*right, "player", -1)
        && string_arg(*left, "slot") == string_arg(*right, "slot")
        && string_arg(*left, "card_id")
            == string_arg(*right, "card_id");
}

void append_serialized_modifier(
    Value &target,
    Object descriptor
) {
    Value *modifiers = target.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        target["modifiers"] = Value::make_array();
        modifiers = target.find("modifiers");
    }
    const Value descriptor_value(std::move(descriptor));
    const Value *operation = descriptor_value.find("operation");
    const Value *source_ref = descriptor_value.find("source_ref");
    const std::string operation_kind = operation == nullptr
        ? std::string{}
        : string_arg(*operation, "kind");
    const std::string stacking = string_arg(
        descriptor_value,
        "stacking"
    );
    if (stacking == "maximum") {
        const std::int64_t candidate = operation == nullptr
            ? 0
            : std::abs(integer_arg(*operation, "amount"));
        const bool stronger_exists = std::any_of(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [&operation_kind, candidate](const Value &entry) {
                const Value *existing = entry.find("operation");
                return existing != nullptr
                    && existing->is_object()
                    && string_arg(*existing, "kind")
                        == operation_kind
                    && std::abs(integer_arg(*existing, "amount"))
                        >= candidate;
            }
        );
        if (stronger_exists) {
            return;
        }
        modifiers->as_array().erase(
            std::remove_if(
                modifiers->as_array().begin(),
                modifiers->as_array().end(),
                [&operation_kind](const Value &entry) {
                    const Value *existing = entry.find("operation");
                    return existing != nullptr
                        && existing->is_object()
                        && string_arg(*existing, "kind")
                            == operation_kind;
                }
            ),
            modifiers->as_array().end()
        );
        modifiers->as_array().push_back(descriptor_value);
        return;
    }
    modifiers->as_array().erase(
        std::remove_if(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [&operation_kind, source_ref](const Value &entry) {
                const Value *existing_operation = entry.find("operation");
                return entry.is_object()
                    && existing_operation != nullptr
                    && string_arg(*existing_operation, "kind")
                        == operation_kind
                    && same_modifier_source(
                        entry.find("source_ref"),
                        source_ref
                    );
            }
        ),
        modifiers->as_array().end()
    );
    modifiers->as_array().push_back(descriptor_value);
}

void canonicalize_vm_modifiers(
    Value &state,
    std::int32_t actor,
    const std::string &source_slot
) {
    static const std::unordered_set<std::string> canonical_ops = {
        "apply_attack_lock_basic",
        "apply_dazzling_beam",
        "apply_outgoing_damage_reduction",
        "apply_self_attack_lock",
        "prevent_all",
        "prevent_damage",
        "prevent_effects",
    };
    const Value *source = pokemon(player(state, actor), source_slot);
    const Value source_snapshot = source == nullptr
        ? Value::make_object()
        : *source;
    const std::array<std::string, 6> slots = {
        "active",
        "bench_0",
        "bench_1",
        "bench_2",
        "bench_3",
        "bench_4",
    };
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        for (const std::string &slot : slots) {
            Value *target = pokemon(player(state, owner), slot);
            if (target == nullptr) {
                continue;
            }
            Value *modifiers = target->find("modifiers");
            if (modifiers == nullptr || !modifiers->is_array()) {
                continue;
            }
            std::vector<std::pair<std::string, Value>> pending;
            Array retained;
            for (const Value &entry : modifiers->as_array()) {
                const std::string op = entry.is_object()
                    ? string_arg(entry, "native_op")
                    : std::string{};
                if (canonical_ops.find(op) == canonical_ops.end()) {
                    retained.push_back(entry);
                    continue;
                }
                const Value *args = entry.find("args");
                pending.emplace_back(
                    op,
                    args != nullptr && args->is_object()
                        ? *args
                        : Value::make_object()
                );
            }
            if (pending.empty()) {
                continue;
            }
            *modifiers = Value(std::move(retained));
            const Value &modifier_source = source_snapshot.is_object()
                && !string_arg(source_snapshot, "card_id").empty()
                ? source_snapshot
                : *target;
            for (const auto &[op, args] : pending) {
                append_canonical_modifier(
                    *target,
                    modifier_source,
                    op,
                    args,
                    actor,
                    source_slot,
                    owner,
                    integer_arg(state, "turn_number")
                );
            }
        }
    }
}

void append_tool_modifiers(
    Value &target,
    const Value &definition,
    std::int32_t actor,
    const std::string &slot
) {
    const Value *effects = definition.find("compiled_trainer_effects");
    if (effects == nullptr || !effects->is_array()) {
        return;
    }
    for (const Value &effect : effects->as_array()) {
        if (string_arg(effect, "op") != "register_tool_modifier") {
            continue;
        }
        const Value *args_ptr = effect.find("args");
        const Value empty_args = Value::make_object();
        const Value &args = (
            args_ptr != nullptr && args_ptr->is_object()
        ) ? *args_ptr : empty_args;
        const std::string effect_name = string_arg(args, "effect");
        Object condition;
        Object operation;
        std::string hook;
        std::string layer;
        std::string scope = "self";
        if (effect_name == "damage_boost_10") {
            hook = "MODIFY_DAMAGE";
            layer = "attacker_adjust";
            scope = "attached_attacker";
            operation["amount"] = Value(10);
            operation["kind"] = Value("damage_delta");
        } else if (effect_name == "damage_boost_when_behind") {
            hook = "MODIFY_DAMAGE";
            layer = "attacker_adjust";
            scope = "attached_attacker";
            condition["behind_on_prizes"] = Value(true);
            operation["amount"] = Value(30);
            operation["kind"] = Value("damage_delta");
        } else if (effect_name == "damage_reduction_stage1") {
            hook = "MODIFY_DAMAGE";
            layer = "defender_adjust";
            scope = "attached_defender";
            condition["target_stage"] = Value("stage1");
            operation["amount"] = Value(
                -std::abs(integer_arg(args, "amount", 30))
            );
            operation["kind"] = Value("damage_delta");
        } else if (effect_name == "hp_boost_basic") {
            hook = "MAX_HP";
            layer = "add";
            condition["target_basic"] = Value(true);
            operation["amount"] = Value(
                integer_arg(args, "amount", 50)
            );
            operation["kind"] = Value("hp_delta");
        } else {
            continue;
        }
        Object descriptor;
        descriptor["condition"] = Value(std::move(condition));
        descriptor["conflict_policy"] = Value("commutative");
        descriptor["controller"] = Value(actor);
        descriptor["duration"] = Value("until_leave_play");
        descriptor["hook"] = Value(std::move(hook));
        descriptor["layer"] = Value(std::move(layer));
        descriptor["operation"] = Value(std::move(operation));
        descriptor["priority"] = Value(
            integer_arg(args, "priority", 0)
        );
        descriptor["scope"] = Value(std::move(scope));
        descriptor["source_ref"] = Value(Object{
            {"card_id", Value(string_arg(target, "card_id"))},
            {"kind", Value("pokemon")},
            {"player", Value(actor)},
            {"slot", Value(slot)},
        });
        descriptor["stacking"] = Value("replace_same_source");
        append_serialized_modifier(target, std::move(descriptor));
    }
}

bool replaces_attack_damage(const std::string &op) {
    return op == "conditional_damage_then_heal"
        || op == "deal_damage"
        || op == "deal_damage_then_heal"
        || op.rfind("deal_damage_per_", 0) == 0
        || op == "deal_damage_plus_bench"
        || op == "deal_damage_with_self_penalty"
        || op == "discard_energy_then_damage"
        || op == "discard_hand_then_damage"
        || op == "flip_coin_repeat_damage"
        || op == "flip_until_tails"
        || op == "mill_then_damage"
        || op == "set_attack_damage_formula";
}

const Value *find_named_ability(
    const Value &definition,
    const std::string &name
) {
    const Value *abilities = definition.find("abilities");
    if (abilities == nullptr || !abilities->is_array()) {
        return nullptr;
    }
    const auto found = std::find_if(
        abilities->as_array().begin(),
        abilities->as_array().end(),
        [&name](const Value &ability) {
            return string_arg(ability, "name") == name;
        }
    );
    return found == abilities->as_array().end() ? nullptr : &*found;
}

Value canonical_params(const Value &action, const std::string &kind) {
    const Value *value = action.find("params");
    Value result = value != nullptr && value->is_object()
        ? *value
        : Value::make_object();
    const Value *payload = action.find("payload");
    if (payload != nullptr && payload->is_object()) {
        result = *payload;
    }
    const Value *source = action.find("source");
    const Value *target = action.find("target");
    if (
        source != nullptr
        && source->is_object()
        && string_arg(*source, "zone") == "hand"
    ) {
        result["hand_idx"] = Value(integer_arg(*source, "index", -1));
    }
    const std::string target_slot = (
        target != nullptr && target->is_object()
    ) ? string_arg(*target, "slot") : std::string{};
    if (kind == "PLAY_BASIC" && !target_slot.empty()) {
        result["target"] = Value(target_slot);
    } else if (kind == "EVOLVE" && !target_slot.empty()) {
        result["slot"] = Value(target_slot);
    } else if (
        kind == "ATTACH_ENERGY"
        || kind == "PLAY_TRAINER"
    ) {
        if (!target_slot.empty()) {
            result["target_slot"] = Value(target_slot);
        }
    } else if (kind == "USE_ABILITY" && source != nullptr
        && source->is_object()) {
        if (string_arg(*source, "zone") == "discard") {
            result["slot"] = Value(
                "discard_"
                + std::to_string(integer_arg(*source, "index", -1))
            );
        } else {
            result["slot"] = Value(string_arg(*source, "slot"));
        }
    } else if (
        (kind == "RETREAT" || kind == "PROMOTE")
        && target_slot.rfind("bench_", 0) == 0
    ) {
        result["bench_idx"] = Value(
            static_cast<std::int64_t>(std::stoll(
                target_slot.substr(6)
            ))
        );
    } else if (kind == "DECLARE_ATTACK") {
        result["attack_idx"] = Value(integer_arg(
            result,
            "attack_index",
            integer_arg(result, "attack_idx", -1)
        ));
    }
    return result;
}

void attach_game_continuation(
    GameExecutionResult &result,
    const VmExecutionResult &vm,
    std::int32_t actor,
    bool finish_attack,
    Value remaining = Value::make_array(),
    std::string source_slot = "active",
    std::string context_mode = ""
) {
    result.pending = vm.pending;
    Value *metadata = result.pending.find("metadata");
    if (metadata == nullptr || !metadata->is_object()) {
        result.pending["metadata"] = Value::make_object();
        metadata = result.pending.find("metadata");
    }
    (*metadata)["continuation_kind"] = Value(
        string_arg(result.pending, "continuation_kind")
    );
    if (finish_attack) {
        (*metadata)["finish_attack_actor"] = Value(actor);
    }
    result.pending.erase("continuation_kind");
    Object continuation;
    continuation["kind"] = Value("vm");
    continuation["actor"] = Value(actor);
    continuation["finish_attack"] = Value(finish_attack);
    continuation["vm"] = vm.continuation;
    continuation["context"] = vm.context;
    continuation["remaining_effects"] = std::move(remaining);
    continuation["source_slot"] = Value(std::move(source_slot));
    continuation["context_mode"] = Value(std::move(context_mode));
    result.continuation = Value(std::move(continuation));
}

Value remaining_effects(
    const Array &effects,
    std::size_t first
) {
    Array result;
    if (first >= effects.size()) {
        return Value(std::move(result));
    }
    result.reserve(effects.size() - first);
    for (std::size_t index = first; index < effects.size(); ++index) {
        result.push_back(effects[index]);
    }
    return Value(std::move(result));
}

std::int64_t calculated_attack_damage(
    const Value &state,
    const Value &cards,
    std::int32_t actor,
    const Value &context
) {
    if (
        bool_arg(context, "attack_failed")
        || bool_arg(context, "damage_applied")
    ) {
        return 0;
    }
    const Value *attacker = pokemon(
        player(state, actor),
        "active"
    );
    const Value *defender = pokemon(
        player(state, 1 - actor),
        "active"
    );
    if (defender == nullptr) {
        return 0;
    }
    const std::int64_t base_damage = integer_arg(
        context,
        "base_damage"
    );
    if (base_damage <= 0) {
        return 0;
    }
    std::int64_t damage = std::max<std::int64_t>(
        0,
        base_damage
            + (
                attacker == nullptr
                ? 0
                : attached_attack_damage_delta(
                    cards,
                    state,
                    actor,
                    *attacker
                )
            )
    );
    if (!bool_arg(context, "ignore_defender_damage_effects")) {
        damage = std::max<std::int64_t>(
            0,
            damage + attached_defender_damage_delta(
                cards,
                *defender
            )
        );
        if (defender_prevents_attack_damage(*defender)) {
            damage = 0;
        }
    }
    return damage;
}

std::int64_t after_damage_energy_draw_count(
    const Value &cards,
    const Value *holder,
    const std::string &scope,
    std::int64_t damage
) {
    if (holder == nullptr || damage <= 0) {
        return 0;
    }
    const Value *energy = holder->find("energy_card_ids");
    if (energy == nullptr || !energy->is_array()) {
        return 0;
    }
    std::int64_t draw_count = 0;
    for (const Value &energy_id : energy->as_array()) {
        const Value *definition = card_definition(
            cards,
            energy_id.string_or()
        );
        const Value *effects = definition == nullptr
            ? nullptr
            : definition->find("energy_effects");
        if (effects == nullptr || !effects->is_array()) {
            continue;
        }
        for (const Value &descriptor : effects->as_array()) {
            if (
                string_arg(descriptor, "kind") != "trigger"
                || string_arg(descriptor, "hook") != "AFTER_DAMAGE"
            ) {
                continue;
            }
            const Value *condition = descriptor.find("condition");
            const Value *effect = descriptor.find("effect");
            if (
                condition == nullptr
                || !condition->is_object()
                || effect == nullptr
                || !effect->is_object()
                || string_arg(*condition, "scope") != scope
                || damage < integer_arg(*condition, "min_damage", 1)
                || string_arg(*effect, "op") != "draw_cards"
            ) {
                continue;
            }
            draw_count += std::max<std::int64_t>(
                0,
                integer_arg(*effect, "amount")
            );
        }
    }
    return draw_count;
}

void apply_attack_damage_before_effect(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor,
    Value &context
) {
    struct DamageTarget {
        std::int32_t player;
        std::string slot;
        std::int64_t amount;
        std::int64_t calculated = 0;
    };
    std::vector<DamageTarget> targets;
    const std::int64_t base_damage = integer_arg(context, "base_damage");
    if (base_damage > 0) {
        targets.push_back(DamageTarget{
            1 - actor,
            "active",
            base_damage,
        });
    }
    const Value *packets = context.find("damage_packets");
    if (packets != nullptr && packets->is_array()) {
        for (const Value &packet : packets->as_array()) {
            const std::int32_t target_player =
                static_cast<std::int32_t>(integer_arg(
                    packet,
                    "target_player",
                    1 - actor
                ));
            const std::string target_slot = string_arg(
                packet,
                "target_slot",
                "active"
            );
            const std::int64_t amount = std::max<std::int64_t>(
                0,
                integer_arg(packet, "amount")
            );
            const auto existing = std::find_if(
                targets.begin(),
                targets.end(),
                [target_player, &target_slot](const DamageTarget &target) {
                    return target.player == target_player
                        && target.slot == target_slot;
                }
            );
            if (existing == targets.end()) {
                targets.push_back(DamageTarget{
                    target_player,
                    target_slot,
                    amount,
                });
            } else {
                existing->amount += amount;
            }
        }
    }
    const Value *attacker = pokemon(
        player(result.state, actor),
        "active"
    );
    for (DamageTarget &target : targets) {
        Value *defender = (
            target.player == 0 || target.player == 1
        ) ? pokemon(
            player(result.state, target.player),
            target.slot
        ) : nullptr;
        if (defender == nullptr || target.amount <= 0) {
            continue;
        }
        Value packet_context = context;
        packet_context["base_damage"] = Value(target.amount);
        packet_context["damage_applied"] = Value(false);
        target.calculated = calculated_attack_damage(
            result.state,
            cards,
            actor,
            packet_context
        );
        if (target.slot != "active" || target.player != 1 - actor) {
            std::int64_t damage = std::max<std::int64_t>(
                0,
                target.amount
                    + (
                        attacker == nullptr
                        ? 0
                        : attached_attack_damage_delta(
                            cards,
                            result.state,
                            actor,
                            *attacker
                        )
                    )
            );
            if (!bool_arg(
                context,
                "ignore_defender_damage_effects"
            )) {
                damage = std::max<std::int64_t>(
                    0,
                    damage + attached_defender_damage_delta(
                        cards,
                        *defender
                    )
                );
                if (defender_prevents_attack_damage(*defender)) {
                    damage = 0;
                }
            }
            target.calculated = damage;
        }
    }
    std::int64_t active_damage = 0;
    for (const DamageTarget &target : targets) {
        Value *defender = (
            target.player == 0 || target.player == 1
        ) ? pokemon(
            player(result.state, target.player),
            target.slot
        ) : nullptr;
        if (defender == nullptr || target.calculated <= 0) {
            continue;
        }
        if (target.player == 1 - actor && target.slot == "active") {
            active_damage += target.calculated;
            context["after_damage_draw_attacker"] = Value(
                after_damage_energy_draw_count(
                    cards,
                    attacker,
                    "attached_attacker",
                    target.calculated
                )
            );
            context["after_damage_draw_defender"] = Value(
                after_damage_energy_draw_count(
                    cards,
                    defender,
                    "attached_defender",
                    target.calculated
                )
            );
        }
        add_damage(*defender, target.calculated);
        const std::int64_t maximum_hp = pokemon_hp(cards, *defender);
        if (
            maximum_hp > 0
            && integer_arg(*defender, "damage_counters") * 10
                >= maximum_hp
            && (
                target.player != 1 - actor
                || target.slot != "active"
            )
        ) {
            (*defender)["pending_ko_source_kind"] = Value(
                "attack_damage"
            );
        }
        result.event_types.emplace_back("damage_dealt");
    }
    if (!targets.empty()) {
        Value *mutable_attacker = pokemon(
            player(result.state, actor),
            "active"
        );
        if (mutable_attacker != nullptr) {
            (*mutable_attacker)["outgoing_damage_reduction"] = Value(0);
        }
    }
    context.erase("damage_packets");
    context["final_damage"] = Value(active_damage);
    context["damage_applied"] = Value(true);
}

void apply_reactive_thorns(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor,
    Value &context
) {
    if (
        bool_arg(context, "reactive_thorns_applied")
        || integer_arg(context, "final_damage") <= 0
    ) {
        return;
    }
    context["reactive_thorns_applied"] = Value(true);
    Value &defending_player = player(result.state, 1 - actor);
    Value *defender = pokemon(defending_player, "active");
    Value *attacker = pokemon(player(result.state, actor), "active");
    if (defender == nullptr || attacker == nullptr) {
        return;
    }
    const Value *definition = card_definition(
        cards,
        string_arg(*defender, "card_id")
    );
    const Value *abilities = definition == nullptr
        ? nullptr
        : definition->find("abilities");
    if (abilities == nullptr || !abilities->is_array()) {
        return;
    }
    for (const Value &ability : abilities->as_array()) {
        const Value *effects = ability.find("compiled_effects");
        if (effects == nullptr || !effects->is_array()) {
            continue;
        }
        for (const Value &effect : effects->as_array()) {
            if (string_arg(effect, "op") != "register_reactive_thorns") {
                continue;
            }
            const Value *args = effect.find("args");
            if (args == nullptr || !args->is_object()) {
                continue;
            }
            const Value *names = args->find("filter_names");
            std::int64_t matching = 0;
            const std::array<std::string, 6> slots = {
                "active",
                "bench_0",
                "bench_1",
                "bench_2",
                "bench_3",
                "bench_4",
            };
            for (const std::string &slot : slots) {
                const Value *candidate = pokemon(defending_player, slot);
                const Value *candidate_definition = candidate == nullptr
                    ? nullptr
                    : card_definition(
                        cards,
                        string_arg(*candidate, "card_id")
                    );
                if (
                    candidate_definition != nullptr
                    && array_contains_string(
                        names,
                        string_arg(*candidate_definition, "name")
                    )
                ) {
                    ++matching;
                }
            }
            if (matching > 0) {
                add_damage(
                    *attacker,
                    matching
                        * integer_arg(*args, "per_pokemon", 3)
                        * 10
                );
                result.event_types.emplace_back(
                    "damage_counters_placed"
                );
            }
            return;
        }
    }
}

bool attack_effect_runs_before_damage(
    const std::string &op,
    const Value &args
) {
    if (op == "deal_damage") {
        return string_arg(
            args,
            "target",
            "opponent_active"
        ) != "self";
    }
    static const std::unordered_set<std::string> before_damage = {
        "choose_damage_target",
        "conditional_damage",
        "conditional_damage_then_heal",
        "deal_damage_per_discard_psychic",
        "deal_damage_per_energy",
        "deal_damage_per_evolved",
        "deal_damage_per_hand_size",
        "deal_damage_per_self_damage",
        "deal_damage_per_self_energy",
        "deal_damage_per_self_energy_type",
        "deal_damage_then_heal",
        "deal_damage_with_self_penalty",
        "deal_bench_damage",
        "discard_energy_then_damage",
        "discard_hand_then_damage",
        "fail_attack",
        "flip_coin",
        "flip_coin_repeat_damage",
        "flip_coin_then_ko",
        "flip_until_tails",
        "mill_then_damage",
        "set_attack_damage_formula",
        "set_attack_flags",
    };
    return before_damage.find(op) != before_damage.end();
}

void finish_attack_resolution(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t actor,
    Value &context
) {
    if (
        !bool_arg(context, "attack_failed")
        && !bool_arg(context, "damage_applied")
    ) {
        apply_attack_damage_before_effect(
            result,
            cards,
            actor,
            context
        );
    }
    if (!bool_arg(context, "after_damage_triggers_applied")) {
        const std::array groups{
            std::pair{
                actor,
                integer_arg(context, "after_damage_draw_attacker")
            },
            std::pair{
                1 - actor,
                integer_arg(context, "after_damage_draw_defender")
            },
        };
        context["after_damage_triggers_applied"] = Value(true);
        for (std::size_t group_index = 0;
             group_index < groups.size();
             ++group_index) {
            const auto [owner, count] = groups[group_index];
            if (count > 1) {
                Array remaining_groups;
                for (
                    std::size_t remaining = group_index + 1;
                    remaining < groups.size();
                    ++remaining
                ) {
                    if (groups[remaining].second <= 0) {
                        continue;
                    }
                    remaining_groups.emplace_back(Object{
                        {"owner", Value(groups[remaining].first)},
                        {"count", Value(groups[remaining].second)},
                    });
                }
                suspend_after_damage_trigger_order(
                    result,
                    actor,
                    owner,
                    count,
                    std::move(remaining_groups),
                    context
                );
                return;
            }
            for (std::int64_t index = 0; index < count; ++index) {
                draw_one(player(result.state, owner), result.event_types);
            }
        }
    }
    apply_reactive_thorns(result, cards, actor, context);

    struct KnockoutEntry {
        std::int32_t owner;
        std::string slot;
        std::string card_id;
        std::int64_t prize_value;
        bool attack_damage;
    };
    std::vector<KnockoutEntry> knockout_entries;
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value &owner_state = player(result.state, owner);
        const std::array<std::string, 6> slots = {
            "active",
            "bench_0",
            "bench_1",
            "bench_2",
            "bench_3",
            "bench_4",
        };
        for (const std::string &slot : slots) {
            Value *target = pokemon(owner_state, slot);
            if (
                target == nullptr
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
            ) {
                continue;
            }
            const std::string defeated_id = string_arg(
                *target,
                "card_id"
            );
            const Value *definition = card_definition(
                cards,
                defeated_id
            );
            knockout_entries.push_back(KnockoutEntry{
                owner,
                slot,
                defeated_id,
                std::max<std::int64_t>(
                    1,
                    definition == nullptr
                        ? 1
                        : integer_arg(*definition, "prize_value", 1)
                ),
                string_arg(*target, "pending_ko_source_kind")
                    == "attack_damage"
                    || (
                        owner == 1 - actor
                        && slot == "active"
                    ),
            });
        }
    }
    if (knockout_entries.size() > 1) {
        std::vector<std::int32_t> prize_players;
        for (const KnockoutEntry &entry : knockout_entries) {
            Value &owner_state = player(result.state, entry.owner);
            if (entry.attack_damage) {
                owner_state["was_ko_by_attack"] = Value(true);
            }
            append_knockout_fact(
                result.state,
                entry.card_id,
                entry.owner,
                actor,
                entry.attack_damage ? "damage" : "effect",
                entry.attack_damage
                    ? "attack_damage"
                    : "attack_effect",
                entry.slot
            );
            discard_pokemon(owner_state, entry.slot);
            result.event_types.emplace_back("pokemon_ko");
            result.event_types.emplace_back("card_moved");
            for (
                std::int64_t prize = 0;
                prize < entry.prize_value
                && !required(
                    player(result.state, 1 - entry.owner),
                    "prizes"
                ).as_array().empty();
                ++prize
            ) {
                prize_players.push_back(1 - entry.owner);
            }
        }
        queue_promotion_if_possible(result.state, 1 - actor);
        queue_promotion_if_possible(result.state, actor);
        if (!prize_players.empty()) {
            suspend_prize_queue(
                result,
                prize_players,
                actor,
                context
            );
        } else {
            evaluate_terminal_result(result.state);
            if (string_arg(result.state, "phase") == "GAME_OVER") {
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
                            Value(integer_arg(
                                result.state,
                                "winner",
                                -1
                            )),
                        },
                        {
                            "result_status",
                            Value(string_arg(
                                result.state,
                                "result_status"
                            )),
                        },
                        {"reason", Value("knockout")},
                        {
                            "conditions",
                            required(
                                result.state,
                                "result_conditions"
                            ),
                        },
                    }
                );
            }
        }
        return;
    }

    std::vector<std::int32_t> bench_prize_players;
    for (std::int32_t owner = 0; owner < 2; ++owner) {
        Value &owner_state = player(result.state, owner);
        Array &bench = required(owner_state, "bench").as_array();
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (
                !bench[index].is_object()
                || pokemon_hp(cards, bench[index]) <= 0
                || integer_arg(
                    bench[index],
                    "damage_counters"
                ) * 10 < pokemon_hp(cards, bench[index])
            ) {
                continue;
            }
            const std::string slot =
                "bench_" + std::to_string(index);
            const std::string defeated_id = string_arg(
                bench[index],
                "card_id"
            );
            const bool attack_damage = string_arg(
                bench[index],
                "pending_ko_source_kind"
            ) == "attack_damage";
            const Value *definition = card_definition(
                cards,
                defeated_id
            );
            const std::int64_t prize_value = std::max<std::int64_t>(
                1,
                definition == nullptr
                    ? 1
                    : integer_arg(*definition, "prize_value", 1)
            );
            if (attack_damage) {
                owner_state["was_ko_by_attack"] = Value(true);
            }
            append_knockout_fact(
                result.state,
                defeated_id,
                owner,
                actor,
                attack_damage ? "damage" : "effect",
                attack_damage ? "attack_damage" : "attack_effect",
                slot
            );
            discard_pokemon(owner_state, slot);
            result.event_types.emplace_back("pokemon_ko");
            result.event_types.emplace_back("card_moved");
            for (
                std::int64_t prize = 0;
                prize < prize_value
                && !required(
                    player(result.state, 1 - owner),
                    "prizes"
                ).as_array().empty();
                ++prize
            ) {
                bench_prize_players.push_back(1 - owner);
            }
        }
    }
    if (!bench_prize_players.empty()) {
        suspend_prize_queue(
            result,
            bench_prize_players,
            actor,
            context
        );
        return;
    }

    Value *attacker = pokemon(player(result.state, actor), "active");
    if (
        attacker != nullptr
        && pokemon_hp(cards, *attacker) > 0
        && integer_arg(*attacker, "damage_counters") * 10
            >= pokemon_hp(cards, *attacker)
    ) {
        const std::string defeated_id = string_arg(*attacker, "card_id");
        discard_active(player(result.state, actor));
        queue_promotion_if_possible(result.state, actor);
        append_knockout_fact(
            result.state,
            defeated_id,
            actor,
            actor,
            "effect",
            "attack_effect"
        );
        result.event_types.emplace_back("pokemon_ko");
        result.event_types.emplace_back("card_moved");
        suspend_knockout_prizes(
            result,
            cards,
            defeated_id,
            1 - actor
        );
        return;
    }
    Value *defender = pokemon(player(result.state, 1 - actor), "active");
    if (
        defender != nullptr
        && pokemon_hp(cards, *defender) > 0
        && integer_arg(*defender, "damage_counters") * 10
            >= pokemon_hp(cards, *defender)
    ) {
        if (suspend_exp_share_trigger_if_available(
            result,
            cards,
            actor
        )) {
            return;
        }
        Array &pending = required(
            result.state,
            "pending_promotions"
        ).as_array();
        pending.erase(
            std::remove_if(
                pending.begin(),
                pending.end(),
                [actor](const Value &entry) {
                    return entry.as_integer(-1) == actor;
                }
            ),
            pending.end()
        );
        const Array &defending_bench = required(
            player(result.state, 1 - actor),
            "bench"
        ).as_array();
        if (std::any_of(
            defending_bench.begin(),
            defending_bench.end(),
            [](const Value &entry) { return entry.is_object(); }
        )) {
            pending.emplace_back(1 - actor);
        }
        queue_promotion_if_possible(result.state, actor);
        const std::string defeated_id = string_arg(
            *defender,
            "card_id"
        );
        discard_active(player(result.state, 1 - actor));
        player(result.state, 1 - actor)["was_ko_by_attack"] =
            Value(true);
        queue_promotion_if_possible(result.state, 1 - actor);
        append_knockout_fact(
            result.state,
            defeated_id,
            1 - actor,
            actor
        );
        result.event_types.emplace_back("pokemon_ko");
        result.event_types.emplace_back("card_moved");
        suspend_knockout_prizes(
            result,
            cards,
            defeated_id,
            actor
        );
        if (pokemon(player(result.state, actor), "active") == nullptr) {
            const Array &attacking_bench = required(
                player(result.state, actor),
                "bench"
            ).as_array();
            if (std::any_of(
                attacking_bench.begin(),
                attacking_bench.end(),
                [](const Value &entry) { return entry.is_object(); }
            )) {
                Array &pending = required(
                    result.state,
                    "pending_promotions"
                ).as_array();
                if (std::none_of(
                    pending.begin(),
                    pending.end(),
                    [actor](const Value &entry) {
                        return entry.as_integer(-1) == actor;
                    }
                )) {
                    pending.emplace_back(actor);
                }
            }
        }
        return;
    }
    if (
        pokemon(player(result.state, actor), "active") == nullptr
    ) {
        queue_promotion_if_possible(result.state, actor);
        evaluate_terminal_result(result.state);
        if (string_arg(result.state, "phase") == "GAME_OVER") {
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
                        Value(integer_arg(
                            result.state,
                            "winner",
                            -1
                        )),
                    },
                    {
                        "result_status",
                        Value(string_arg(
                            result.state,
                            "result_status"
                        )),
                    },
                    {"reason", Value("knockout")},
                    {
                        "conditions",
                        required(
                            result.state,
                            "result_conditions"
                        ),
                    },
                }
            );
        }
        return;
    }
    const Value *promotions = result.state.find("pending_promotions");
    if (
        promotions != nullptr
        && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        return;
    }
    if (finalize_terminal_if_needed(result)) {
        return;
    }
    finish_turn(
        result.state,
        actor,
        result.event_types,
        &result.rng_state
    );
}

bool prize_attaches_to_bench(
    const Value &cards,
    const std::string &prize_card_id
) {
    const Value *definition = card_definition(cards, prize_card_id);
    const Value *effects = definition == nullptr
        ? nullptr
        : definition->find("energy_effects");
    if (effects == nullptr || !effects->is_array()) {
        return false;
    }
    return std::any_of(
        effects->as_array().begin(),
        effects->as_array().end(),
        [](const Value &descriptor) {
            const Value *condition = descriptor.find("condition");
            const Value *effect = descriptor.find("effect");
            return descriptor.is_object()
                && string_arg(descriptor, "kind") == "trigger"
                && string_arg(descriptor, "hook")
                    == "ON_PRIZE_REVEALED"
                && condition != nullptr
                && condition->is_object()
                && string_arg(*condition, "source_zone") == "prizes"
                && effect != nullptr
                && effect->is_object()
                && string_arg(*effect, "op")
                    == "attach_to_benched_pokemon";
        }
    );
}

void continue_after_prize_selection(
    GameExecutionResult &result,
    const Value &cards,
    const Value &continuation
) {
    const Value *remaining_prizes = continuation.find(
        "remaining_prize_players"
    );
    if (
        remaining_prizes != nullptr
        && remaining_prizes->is_array()
        && !remaining_prizes->as_array().empty()
    ) {
        std::vector<std::int32_t> queue;
        queue.reserve(remaining_prizes->as_array().size());
        for (const Value &entry : remaining_prizes->as_array()) {
            const std::int32_t prize_player =
                static_cast<std::int32_t>(entry.as_integer(-1));
            if (prize_player != 0 && prize_player != 1) {
                throw std::invalid_argument(
                    "prize_queue_player_invalid"
                );
            }
            queue.push_back(prize_player);
        }
        suspend_prize_queue(
            result,
            queue,
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_attack_actor",
                -1
            )),
            continuation.find("resume_attack_context") != nullptr
                ? *continuation.find("resume_attack_context")
                : Value::make_object()
        );
        if (bool_arg(continuation, "finish_attack_after_prizes")) {
            result.continuation["finish_attack_after_prizes"] =
                Value(true);
        }
        if (bool_arg(continuation, "finish_checkup_after_prizes")) {
            result.continuation["finish_checkup_after_prizes"] =
                Value(true);
            result.continuation["resume_checkup_actor"] = Value(
                integer_arg(
                    continuation,
                    "resume_checkup_actor",
                    -1
                )
            );
        }
        return;
    }
    evaluate_terminal_result(result.state);
    if (string_arg(result.state, "phase") == "GAME_OVER") {
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
    } else if (bool_arg(
        continuation,
        "finish_attack_after_prizes"
    )) {
        const std::int32_t attack_actor =
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_attack_actor",
                -1
            ));
        if (
            (attack_actor != 0 && attack_actor != 1)
            || string_arg(result.state, "phase") != "ATTACK"
        ) {
            throw std::invalid_argument(
                "prize_attack_resume_context_invalid"
            );
        }
        const Value *promotions = result.state.find(
            "pending_promotions"
        );
        if (
            promotions == nullptr
            || !promotions->is_array()
            || promotions->as_array().empty()
        ) {
            finish_turn(
                result.state,
                attack_actor,
                result.event_types,
                &result.rng_state
            );
        }
    } else if (bool_arg(
        continuation,
        "finish_checkup_after_prizes"
    )) {
        const std::int32_t outgoing_actor =
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_checkup_actor",
                -1
            ));
        if (
            (outgoing_actor != 0 && outgoing_actor != 1)
            || string_arg(result.state, "phase")
                != "POKEMON_CHECKUP"
            || integer_arg(result.state, "active_player_idx")
                != outgoing_actor
        ) {
            throw std::invalid_argument(
                "prize_checkup_resume_context_invalid"
            );
        }
        const Value *promotions = result.state.find(
            "pending_promotions"
        );
        if (
            promotions == nullptr
            || !promotions->is_array()
            || promotions->as_array().empty()
        ) {
            complete_checkup_transition(
                result.state,
                outgoing_actor,
                result.event_types
            );
        }
    } else if (
        continuation.find("resume_attack_context") != nullptr
    ) {
        Value resumed_context = required(
            continuation,
            "resume_attack_context"
        );
        finish_attack_resolution(
            result,
            cards,
            static_cast<std::int32_t>(integer_arg(
                continuation,
                "resume_attack_actor",
                -1
            )),
            resumed_context
        );
    }
}

void suspend_exp_share_confirmation(
    GameExecutionResult &result,
    std::int32_t defeated_owner,
    std::int32_t attack_actor,
    const Value &continuation,
    std::int64_t remaining,
    bool remaining_requires_order
) {
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "confirm_trigger",
        defeated_owner,
        1,
        1,
        false,
        {
            Value(Object{
                {"kind", Value("id")},
                {"option_id", Value("confirm:yes")},
            }),
            Value(Object{
                {"kind", Value("id")},
                {"option_id", Value("confirm:no")},
            }),
        },
        "confirm_exp_share_trigger",
        true
    );
    result.continuation = continuation;
    result.continuation["kind"] = Value(
        "confirm_exp_share_trigger"
    );
    result.continuation["actor"] = Value(defeated_owner);
    result.continuation["attack_actor"] = Value(attack_actor);
    result.continuation["remaining_exp_share_triggers"] =
        Value(remaining);
    result.continuation["remaining_exp_share_requires_order"] =
        Value(remaining_requires_order);
}

void suspend_exp_share_order(
    GameExecutionResult &result,
    std::int32_t defeated_owner,
    std::int32_t attack_actor,
    const Value &continuation,
    std::int64_t count
) {
    if (count < 2 || count > 8) {
        throw std::invalid_argument("exp_share_order_count_invalid");
    }
    Array options;
    options.reserve(static_cast<std::size_t>(count));
    for (std::int64_t index = 0; index < count; ++index) {
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
        defeated_owner,
        1,
        1,
        false,
        std::move(options),
        "public_exp_share_order",
        true
    );
    result.continuation = continuation;
    result.continuation["kind"] = Value(
        "public_exp_share_order"
    );
    result.continuation["actor"] = Value(defeated_owner);
    result.continuation["attack_actor"] = Value(attack_actor);
    result.continuation["exp_share_order_count"] = Value(count);
}

void validate_public_exp_share_spec(
    const Value &state,
    std::int32_t actor,
    const Value &spec
) {
    if (!spec.is_object()) {
        throw std::invalid_argument("public_exp_share_spec_invalid");
    }
    const std::int32_t from_player = static_cast<std::int32_t>(
        integer_arg(spec, "from_player", -1)
    );
    const std::int32_t to_player = static_cast<std::int32_t>(
        integer_arg(spec, "to_player", -1)
    );
    const std::string from_slot = string_arg(spec, "from_slot");
    const std::string to_slot = string_arg(spec, "to_slot");
    const Value *source = (
        from_player == actor
    ) ? pokemon(player(state, from_player), from_slot) : nullptr;
    const Value *target = (
        to_player == actor
    ) ? pokemon(player(state, to_player), to_slot) : nullptr;
    if (
        from_player != actor
        || to_player != actor
        || from_slot != "active"
        || to_slot.rfind("bench_", 0) != 0
        || source == nullptr
        || target == nullptr
        || string_arg(*source, "card_id")
            != string_arg(spec, "from_card_id")
        || string_arg(*target, "card_id")
            != string_arg(spec, "to_card_id")
        || string_arg(*target, "attached_tool_id")
            != string_arg(spec, "target_tool_id")
        || string_arg(spec, "target_tool_id").empty()
    ) {
        throw std::invalid_argument("public_exp_share_spec_invalid");
    }
}

void suspend_public_exp_share_spec_order(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &continuation,
    Array trigger_specs
) {
    if (trigger_specs.size() < 2 || trigger_specs.size() > 8) {
        throw std::invalid_argument("public_exp_share_order_count_invalid");
    }
    Array options;
    options.reserve(trigger_specs.size());
    for (std::size_t index = 0; index < trigger_specs.size(); ++index) {
        validate_public_exp_share_spec(result.state, actor, trigger_specs[index]);
        options.emplace_back(Object{
            {"kind", Value("id")},
            {"option_id", Value("trigger:" + std::to_string(index))},
        });
    }
    increment(result.state, "choice_sequence");
    result.pending = action_pending(
        "choose_trigger_order",
        actor,
        1,
        1,
        false,
        std::move(options),
        "public_exp_share_spec_order",
        true
    );
    result.continuation = continuation;
    result.continuation["kind"] = Value(
        "public_exp_share_spec_order"
    );
    result.continuation["actor"] = Value(actor);
    result.continuation["attack_actor"] = Value(attack_actor);
    result.continuation["exp_share_trigger_specs"] = Value(
        std::move(trigger_specs)
    );
}

void suspend_public_exp_share_spec_confirmation(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &outer_continuation,
    Value chosen,
    Array remaining
) {
    validate_public_exp_share_spec(result.state, actor, chosen);
    const Value *knockout_entries = outer_continuation.find(
        "knockout_entries"
    );
    if (knockout_entries == nullptr || !knockout_entries->is_array()) {
        throw std::invalid_argument("exp_share_knockout_batch_invalid");
    }
    chosen["knockout_entries"] = *knockout_entries;
    chosen["remaining_exp_share_trigger_specs"] = Value(
        std::move(remaining)
    );
    suspend_exp_share_confirmation(
        result,
        actor,
        attack_actor,
        chosen,
        0,
        false
    );
}

bool continue_public_exp_share_spec_queue(
    GameExecutionResult &result,
    std::int32_t actor,
    std::int32_t attack_actor,
    const Value &continuation
) {
    const Value *remaining_value = continuation.find(
        "remaining_exp_share_trigger_specs"
    );
    if (remaining_value == nullptr) {
        return false;
    }
    if (!remaining_value->is_array()) {
        throw std::invalid_argument("public_exp_share_queue_invalid");
    }
    Array remaining = remaining_value->as_array();
    if (remaining.size() > 8) {
        throw std::invalid_argument("public_exp_share_queue_invalid");
    }
    if (remaining.empty()) {
        return false;
    }
    if (remaining.size() > 1) {
        suspend_public_exp_share_spec_order(
            result,
            actor,
            attack_actor,
            continuation,
            std::move(remaining)
        );
        return true;
    }
    Value chosen = std::move(remaining.front());
    remaining.clear();
    suspend_public_exp_share_spec_confirmation(
        result,
        actor,
        attack_actor,
        continuation,
        std::move(chosen),
        std::move(remaining)
    );
    return true;
}

void continue_after_exp_share_trigger(
    GameExecutionResult &result,
    const Value &cards,
    std::int32_t defeated_owner,
    std::int32_t attack_actor,
    const Value &continuation
) {
    if (continue_public_exp_share_spec_queue(
        result,
        defeated_owner,
        attack_actor,
        continuation
    )) {
        return;
    }
    const std::int64_t remaining = std::max<std::int64_t>(
        0,
        integer_arg(
            continuation,
            "remaining_exp_share_triggers"
        )
    );
    const bool remaining_requires_order = bool_arg(
        continuation,
        "remaining_exp_share_requires_order"
    );
    Value *source = pokemon(
        player(result.state, defeated_owner),
        string_arg(continuation, "from_slot", "active")
    );
    Value *target = pokemon(
        player(result.state, defeated_owner),
        string_arg(continuation, "to_slot")
    );
    const bool basic_energy_available = (
        source != nullptr
        && std::any_of(
            required(*source, "energy_card_ids").as_array().begin(),
            required(*source, "energy_card_ids").as_array().end(),
            [&cards](const Value &entry) {
                return is_basic_energy_id(cards, entry.string_or());
            }
        )
    );
    if (
        remaining > 0
        && basic_energy_available
        && target != nullptr
        && string_arg(*source, "card_id")
            == string_arg(continuation, "from_card_id")
        && string_arg(*target, "card_id")
            == string_arg(continuation, "to_card_id")
        && string_arg(*target, "attached_tool_id")
            == string_arg(continuation, "target_tool_id")
    ) {
        if (remaining_requires_order && remaining > 1) {
            suspend_exp_share_order(
                result,
                defeated_owner,
                attack_actor,
                continuation,
                remaining
            );
        } else {
            suspend_exp_share_confirmation(
                result,
                defeated_owner,
                attack_actor,
                continuation,
                remaining - 1,
                false
            );
        }
        return;
    }

    const Value *knockout_entries = continuation.find(
        "knockout_entries"
    );
    if (knockout_entries != nullptr) {
        if (
            !knockout_entries->is_array()
            || knockout_entries->as_array().empty()
            || knockout_entries->as_array().size() > 12
        ) {
            throw std::invalid_argument(
                "exp_share_knockout_batch_invalid"
            );
        }
        struct PublicKnockout {
            std::int32_t owner = -1;
            std::string slot;
            std::string card_id;
            std::int64_t prize_count = 0;
        };
        std::vector<PublicKnockout> entries;
        entries.reserve(knockout_entries->as_array().size());
        std::unordered_set<std::string> seen_slots;
        bool source_seen = false;
        for (const Value &entry : knockout_entries->as_array()) {
            const std::int32_t owner =
                static_cast<std::int32_t>(integer_arg(
                    entry,
                    "player_idx",
                    -1
                ));
            const std::string slot = string_arg(entry, "slot");
            const std::string card_id = string_arg(
                entry,
                "card_id"
            );
            const std::int64_t prize_count = integer_arg(
                entry,
                "prize_count",
                -1
            );
            const std::string key =
                std::to_string(owner) + ":" + slot;
            Value *target = (
                owner == 0 || owner == 1
            ) ? pokemon(player(result.state, owner), slot) : nullptr;
            if (
                target == nullptr
                || card_id.empty()
                || string_arg(*target, "card_id") != card_id
                || prize_count < 1
                || prize_count > 3
                || prize_count != knockout_prize_value(
                    cards,
                    card_id
                )
                || !seen_slots.insert(key).second
                || pokemon_hp(cards, *target) <= 0
                || integer_arg(*target, "damage_counters") * 10
                    < pokemon_hp(cards, *target)
            ) {
                throw std::invalid_argument(
                    "exp_share_knockout_entry_changed"
                );
            }
            source_seen = source_seen || (
                owner == defeated_owner
                && slot == string_arg(
                    continuation,
                    "from_slot",
                    "active"
                )
                && card_id == string_arg(
                    continuation,
                    "from_card_id"
                )
            );
            entries.push_back(PublicKnockout{
                owner,
                slot,
                card_id,
                prize_count,
            });
        }
        if (!source_seen) {
            throw std::invalid_argument(
                "exp_share_knockout_source_missing"
            );
        }

        std::array<std::size_t, 2> available_prizes = {
            required(
                player(result.state, 0),
                "prizes"
            ).as_array().size(),
            required(
                player(result.state, 1),
                "prizes"
            ).as_array().size(),
        };
        std::vector<std::int32_t> prize_players;
        for (const PublicKnockout &entry : entries) {
            Value &owner_state = player(result.state, entry.owner);
            const bool attack_damage = (
                entry.owner == defeated_owner
                && entry.slot == string_arg(
                    continuation,
                    "from_slot",
                    "active"
                )
            );
            if (attack_damage) {
                owner_state["was_ko_by_attack"] = Value(true);
            }
            append_knockout_fact(
                result.state,
                entry.card_id,
                entry.owner,
                attack_actor,
                attack_damage ? "damage" : "effect",
                attack_damage
                    ? "attack_damage"
                    : "attack_effect",
                entry.slot
            );
            discard_pokemon(owner_state, entry.slot);
            result.event_types.emplace_back("pokemon_ko");
            result.event_types.emplace_back("card_moved");
            const std::int32_t prize_player = 1 - entry.owner;
            const std::size_t count = std::min<std::size_t>(
                available_prizes[
                    static_cast<std::size_t>(prize_player)
                ],
                static_cast<std::size_t>(entry.prize_count)
            );
            available_prizes[
                static_cast<std::size_t>(prize_player)
            ] -= count;
            prize_players.insert(
                prize_players.end(),
                count,
                prize_player
            );
        }
        queue_promotion_if_possible(
            result.state,
            1 - attack_actor
        );
        queue_promotion_if_possible(result.state, attack_actor);
        const Value finish_continuation = Value(Object{
            {"finish_attack_after_prizes", Value(true)},
            {"resume_attack_actor", Value(attack_actor)},
        });
        if (!prize_players.empty()) {
            suspend_prize_queue(
                result,
                prize_players,
                attack_actor,
                Value::make_object()
            );
            result.continuation["finish_attack_after_prizes"] =
                Value(true);
        } else {
            continue_after_prize_selection(
                result,
                cards,
                finish_continuation
            );
        }
        return;
    }

    finalize_active_knockout(
        result,
        cards,
        defeated_owner,
        attack_actor
    );
    queue_promotion_if_possible(result.state, attack_actor);
    if (
        result.pending.is_object()
        && !result.pending.as_object().empty()
    ) {
        result.continuation["finish_attack_after_prizes"] =
            Value(true);
        result.continuation["resume_attack_actor"] =
            Value(attack_actor);
        return;
    }
    continue_after_prize_selection(
        result,
        cards,
        Value(Object{
            {"finish_attack_after_prizes", Value(true)},
            {"resume_attack_actor", Value(attack_actor)},
        })
    );
}

} // namespace

NativeGameKernel::NativeGameKernel(Value cards)
    : cards_(cards),
      rules_(std::move(cards)) {}

void NativeGameKernel::set_cards(Value cards) {
    cards_ = cards;
    rules_.set_cards(std::move(cards));
}

std::size_t NativeGameKernel::card_count() const noexcept {
    return cards_.is_object() ? cards_.as_object().size() : 0;
}

Value NativeGameKernel::legal_actions(
    const Value &state,
    std::int32_t actor
) const {
    Array actions;
    if (
        (actor != 0 && actor != 1)
        || !state.is_object()
        || string_arg(state, "result_status", "ONGOING") != "ONGOING"
    ) {
        return Value(std::move(actions));
    }
    const Value *resolution_stack = state.find("resolution_stack");
    if (resolution_stack != nullptr && resolution_stack->is_object()) {
        const Value *pending = resolution_stack->find("pending_request");
        if (pending != nullptr && !pending->is_null()) {
            return Value(std::move(actions));
        }
    }

    const Value &owner = player(state, actor);
    const Value *promotions = state.find("pending_promotions");
    if (
        promotions != nullptr
        && promotions->is_array()
        && !promotions->as_array().empty()
    ) {
        if (promotions->as_array().front().as_integer(-1) != actor) {
            return Value(std::move(actions));
        }
        const Array &bench = required(owner, "bench").as_array();
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (!bench[index].is_object()) {
                continue;
            }
            actions.push_back(make_action(
                state,
                "PROMOTE",
                actor,
                Value(),
                pokemon_ref(
                    actor,
                    "bench_" + std::to_string(index),
                    bench[index]
                )
            ));
        }
        return Value(std::move(actions));
    }

    const std::string phase = string_arg(state, "phase");
    if (phase == "SETUP") {
        if (integer_arg(state, "setup_actor_idx", -1) != actor) {
            return Value(std::move(actions));
        }
        const std::string stage = string_arg(state, "setup_stage");
        if (
            stage != "INITIAL_PLACEMENT"
            && stage != "BONUS_PLACEMENT"
        ) {
            return Value(std::move(actions));
        }
        const Value *setup_ready = state.find("setup_ready");
        if (
            stage == "INITIAL_PLACEMENT"
            && setup_ready != nullptr
            && setup_ready->is_array()
            && setup_ready->as_array().at(
                static_cast<std::size_t>(actor)
            ).as_bool()
        ) {
            return Value(std::move(actions));
        }
        const Array &hand = required(owner, "hand").as_array();
        const Value *active = owner.find("active");
        const bool has_active = active != nullptr && active->is_object();
        const Array *bonus_ids = nullptr;
        const Value *bonus_rows = state.find("setup_bonus_card_ids");
        if (
            bonus_rows != nullptr
            && bonus_rows->is_array()
            && bonus_rows->as_array().size() == 2
            && bonus_rows->as_array()[
                static_cast<std::size_t>(actor)
            ].is_array()
        ) {
            bonus_ids = &bonus_rows->as_array()[
                static_cast<std::size_t>(actor)
            ].as_array();
        }
        for (std::size_t hand_index = 0; hand_index < hand.size(); ++hand_index) {
            const std::string card_id = hand[hand_index].string_or();
            const Value *card = card_definition(cards_, card_id);
            if (card == nullptr || !is_basic_pokemon(*card)) {
                continue;
            }
            if (
                stage == "BONUS_PLACEMENT"
                && (
                    bonus_ids == nullptr
                    || std::none_of(
                        bonus_ids->begin(),
                        bonus_ids->end(),
                        [&card_id](const Value &value) {
                            return value.string_or() == card_id;
                        }
                    )
                )
            ) {
                continue;
            }
            const Value source = card_ref(
                actor,
                "hand",
                hand_index,
                card_id
            );
            if (stage == "INITIAL_PLACEMENT" && !has_active) {
                actions.push_back(make_action(
                    state,
                    "PLAY_BASIC",
                    actor,
                    source,
                    slot_ref(actor, "active")
                ));
            } else if (has_active) {
                const Array &bench = required(owner, "bench").as_array();
                for (std::size_t index = 0; index < bench.size(); ++index) {
                    if (bench[index].is_null()) {
                        actions.push_back(make_action(
                            state,
                            "PLAY_BASIC",
                            actor,
                            source,
                            slot_ref(
                                actor,
                                "bench_" + std::to_string(index)
                            )
                        ));
                    }
                }
            }
        }
        if (stage == "BONUS_PLACEMENT" || has_active) {
            actions.push_back(make_action(
                state,
                "SETUP_DONE",
                actor
            ));
        }
        return Value(std::move(actions));
    }

    if (phase == "ATTACK") {
        if (integer_arg(state, "active_player_idx", -1) == actor) {
            actions.push_back(make_action(
                state,
                "END_TURN",
                actor
            ));
        }
        return Value(std::move(actions));
    }
    if (
        phase != "MAIN"
        || integer_arg(state, "active_player_idx", -1) != actor
    ) {
        return Value(std::move(actions));
    }

    std::vector<std::pair<std::string, const Value *>> pokemon_rows;
    append_pokemon_rows(owner, pokemon_rows);
    std::vector<std::string> empty_bench;
    const Array &bench = required(owner, "bench").as_array();
    for (std::size_t index = 0; index < bench.size(); ++index) {
        if (bench[index].is_null()) {
            empty_bench.push_back("bench_" + std::to_string(index));
        }
    }

    const Array &hand = required(owner, "hand").as_array();
    for (std::size_t hand_index = 0; hand_index < hand.size(); ++hand_index) {
        const std::string card_id = hand[hand_index].string_or();
        const Value *card = card_definition(cards_, card_id);
        if (card == nullptr) {
            continue;
        }
        const Value source = card_ref(
            actor,
            "hand",
            hand_index,
            card_id
        );
        if (is_basic_pokemon(*card)) {
            for (const std::string &slot : empty_bench) {
                actions.push_back(make_action(
                    state,
                    "PLAY_BASIC",
                    actor,
                    source,
                    slot_ref(actor, slot)
                ));
            }
            continue;
        }
        if (
            is_pokemon_card(*card)
            && (
                card_has_subtype(*card, "Stage 1")
                || card_has_subtype(*card, "Stage 2")
            )
            && !is_player_first_turn(state, actor)
        ) {
            const std::string evolves_from = string_arg(
                *card,
                "evolves_from"
            );
            for (const auto &[slot, target] : pokemon_rows) {
                if (
                    bool_arg(*target, "placed_this_turn")
                    || !bool_arg(*target, "can_evolve_this_turn", true)
                ) {
                    continue;
                }
                const Value *target_card = card_definition(
                    cards_,
                    string_arg(*target, "card_id")
                );
                if (
                    target_card == nullptr
                    || string_arg(*target_card, "name") != evolves_from
                ) {
                    continue;
                }
                actions.push_back(make_action(
                    state,
                    "EVOLVE",
                    actor,
                    source,
                    pokemon_ref(actor, slot, *target)
                ));
            }
            continue;
        }
        if (
            is_energy_card(*card)
            && !bool_arg(owner, "energy_attached_this_turn")
        ) {
            for (const auto &[slot, target] : pokemon_rows) {
                actions.push_back(make_action(
                    state,
                    "ATTACH_ENERGY",
                    actor,
                    source,
                    pokemon_ref(actor, slot, *target)
                ));
            }
            continue;
        }
        if (!is_trainer_card(*card)) {
            continue;
        }
        if (is_supporter_card(*card)) {
            if (
                bool_arg(owner, "supporter_played_this_turn")
                || integer_arg(state, "turn_number") == 1
            ) {
                continue;
            }
        } else if (is_stadium_card(*card)) {
            const Value *stadium = state.find("stadium_card_id");
            const Value *current_card = stadium != nullptr
                ? card_definition(cards_, stadium->string_or())
                : nullptr;
            if (
                bool_arg(owner, "stadium_played_this_turn")
                || (
                    current_card != nullptr
                    && string_arg(*current_card, "name")
                        == string_arg(*card, "name")
                )
            ) {
                continue;
            }
        }
        if (is_tool_card(*card)) {
            for (const auto &[slot, target] : pokemon_rows) {
                if (!string_arg(*target, "attached_tool_id").empty()) {
                    continue;
                }
                actions.push_back(make_action(
                    state,
                    "PLAY_TRAINER",
                    actor,
                    source,
                    pokemon_ref(actor, slot, *target)
                ));
            }
        } else {
            actions.push_back(make_action(
                state,
                "PLAY_TRAINER",
                actor,
                source
            ));
        }
    }

    for (const auto &[slot, target] : pokemon_rows) {
        const Value *definition = card_definition(
            cards_,
            string_arg(*target, "card_id")
        );
        const Value *abilities = definition != nullptr
            ? definition->find("abilities")
            : nullptr;
        if (abilities == nullptr || !abilities->is_array()) {
            continue;
        }
        for (const Value &ability : abilities->as_array()) {
            if (
                !ability.is_object()
                || ability_is_discard_revive(ability)
            ) {
                continue;
            }
            const Value *compiled_effects = ability.find(
                "compiled_effects"
            );
            if (
                compiled_effects != nullptr
                && compiled_effects->is_array()
                && !ability_effect_list_has_visible_target(
                    cards_,
                    state,
                    actor,
                    *compiled_effects,
                    slot
                )
            ) {
                continue;
            }
            const std::string trigger = string_arg(ability, "trigger");
            if (
                trigger == "passive"
                || trigger == "on_enter_play"
                || trigger == "on_damaged"
            ) {
                continue;
            }
            const std::string name = string_arg(ability, "name");
            if (
                trigger != "repeatable"
                && array_contains_string(
                    target->find("used_abilities"),
                    name
                )
            ) {
                continue;
            }
            actions.push_back(make_action(
                state,
                "USE_ABILITY",
                actor,
                pokemon_ref(actor, slot, *target),
                Value(),
                Value(Object{{"ability_name", Value(name)}})
            ));
        }
    }

    if (hand.empty() && !empty_bench.empty()) {
        const Array &discard = required(owner, "discard").as_array();
        for (std::size_t index = 0; index < discard.size(); ++index) {
            const std::string card_id = discard[index].string_or();
            const Value *definition = card_definition(cards_, card_id);
            const Value *abilities = definition != nullptr
                ? definition->find("abilities")
                : nullptr;
            if (abilities == nullptr || !abilities->is_array()) {
                continue;
            }
            for (const Value &ability : abilities->as_array()) {
                if (!ability.is_object()
                    || !ability_is_discard_revive(ability)) {
                    continue;
                }
                actions.push_back(make_action(
                    state,
                    "USE_ABILITY",
                    actor,
                    card_ref(actor, "discard", index, card_id),
                    Value(),
                    Value(Object{{
                        "ability_name",
                        Value(string_arg(ability, "name")),
                    }})
                ));
            }
        }
    }

    const std::string stadium_id = string_arg(state, "stadium_card_id");
    const Value *stadium = card_definition(cards_, stadium_id);
    if (
        !stadium_id.empty()
        && stadium != nullptr
        && !bool_arg(owner, "stadium_used_this_turn")
        && stadium_has_activation(*stadium)
    ) {
        actions.push_back(make_action(
            state,
            "USE_STADIUM",
            actor,
            card_ref(actor, "stadium", 0, stadium_id)
        ));
    }

    const Value *active = owner.find("active");
    if (active != nullptr && active->is_object()) {
        const Value *active_card = card_definition(
            cards_,
            string_arg(*active, "card_id")
        );
        const bool special_condition_blocks_action = (
            array_contains_string(
                active->find("status_conditions"),
                "ASLEEP"
            )
            || array_contains_string(
                active->find("status_conditions"),
                "PARALYZED"
            )
        );
        if (
            !bool_arg(owner, "retreated_this_turn")
            && !special_condition_blocks_action
        ) {
            const std::size_t available_units = energy_units(
                cards_,
                *active
            ).size();
            const std::int64_t retreat_cost = effective_retreat_cost(
                cards_,
                state,
                *active,
                active_card
            );
            if (available_units >= static_cast<std::size_t>(
                std::max<std::int64_t>(0, retreat_cost)
            )) {
                for (std::size_t index = 0; index < bench.size(); ++index) {
                    if (!bench[index].is_object()) {
                        continue;
                    }
                    actions.push_back(make_action(
                        state,
                        "RETREAT",
                        actor,
                        pokemon_ref(actor, "active", *active),
                        pokemon_ref(
                            actor,
                            "bench_" + std::to_string(index),
                            bench[index]
                        )
                    ));
                }
            }
        }

        if (
            integer_arg(state, "turn_number") != 1
            && !special_condition_blocks_action
        ) {
            const Value *attacks = active_card != nullptr
                ? active_card->find("attacks")
                : nullptr;
            if (attacks != nullptr && attacks->is_array()) {
                for (
                    std::size_t attack_index = 0;
                    attack_index < attacks->as_array().size();
                    ++attack_index
                ) {
                    const Value &attack = attacks->as_array()[attack_index];
                    const Value *cost = attack.find("cost");
                    if (
                        attack_is_locked(
                            *active,
                            string_arg(attack, "name")
                        )
                        || (
                            cost != nullptr
                            && !can_pay_attack_cost(
                                cards_,
                                *active,
                                *cost
                            )
                        )
                    ) {
                        continue;
                    }
                    const Value *compiled_effects = attack.find(
                        "compiled_effects"
                    );
                    if (
                        integer_arg(attack, "damage") <= 0
                        && compiled_effects != nullptr
                        && compiled_effects->is_array()
                        && !effect_list_has_visible_target(
                            cards_,
                            state,
                            actor,
                            *compiled_effects,
                            std::numeric_limits<std::size_t>::max(),
                            "active"
                        )
                    ) {
                        continue;
                    }
                    actions.push_back(make_action(
                        state,
                        "DECLARE_ATTACK",
                        actor,
                        pokemon_ref(actor, "active", *active),
                        Value(),
                        Value(Object{{
                            "attack_index",
                            Value(static_cast<std::int64_t>(
                                attack_index
                            )),
                        }})
                    ));
                }
            }
        }
    }

    // Keep legality information-set stable. In particular, never dry-run a
    // deck effect here: the pending options could depend on a hidden deck
    // order and make one action appear/disappear across determinizations.
    // Only public/visible target checks belong in this query.
    actions.erase(
        std::remove_if(
            actions.begin(),
            actions.end(),
            [this, &state, actor](const Value &action) {
                const std::string kind = string_arg(action, "kind");
                if (kind != "PLAY_TRAINER") {
                    return false;
                }
                const Value *source = action.find("source");
                if (source == nullptr || !source->is_object()) {
                    return false;
                }
                const Value *definition = card_definition(
                    cards_,
                    string_arg(*source, "card_id")
                );
                const Value *effects = definition != nullptr
                    ? definition->find("compiled_trainer_effects")
                    : nullptr;
                if (effects == nullptr || !effects->is_array()) {
                    return false;
                }
                return !effect_list_has_visible_target(
                    cards_,
                    state,
                    actor,
                    *effects,
                    static_cast<std::size_t>(
                        integer_arg(*source, "index", -1)
                    )
                );
            }
        ),
        actions.end()
    );
    actions.push_back(make_action(state, "END_TURN", actor));
    return Value(std::move(actions));
}

Value NativeGameKernel::choice_candidates(const Value &request) {
    Array result;
    if (!request.is_object()) {
        return Value(std::move(result));
    }
    const Value *allowed = request.find("allowed_candidates");
    if (allowed != nullptr) {
        if (!allowed->is_array()) {
            throw std::invalid_argument(
                "allowed_choice_candidates_must_be_array"
            );
        }
        for (const Value &candidate : allowed->as_array()) {
            if (
                !candidate.is_object()
                || string_arg(candidate, "kind") != "choice"
                || !candidate.find("selected_options")
                || !candidate.find("selected_options")->is_array()
            ) {
                throw std::invalid_argument(
                    "invalid_allowed_choice_candidate"
                );
            }
            result.push_back(candidate);
        }
        return Value(std::move(result));
    }
    const Value *options = request.find("options");
    if (options == nullptr || !options->is_array()) {
        return Value(std::move(result));
    }
    constexpr std::size_t MAX_CANDIDATES = 256;
    const std::int64_t minimum = std::max<std::int64_t>(
        0,
        integer_arg(request, "min_select")
    );
    const std::int64_t maximum = std::max<std::int64_t>(
        minimum,
        integer_arg(request, "max_select")
    );
    const bool allow_duplicates = bool_arg(
        request,
        "allow_duplicates"
    );
    const std::string request_id = string_arg(request, "request_id");
    const std::string request_type = string_arg(
        request,
        "request_type",
        "select"
    );
    std::vector<const Value *> selected;
    std::function<void(std::size_t, std::size_t)> enumerate =
        [&](std::size_t begin, std::size_t remaining) {
            if (result.size() >= MAX_CANDIDATES) {
                return;
            }
            if (remaining == 0) {
                append_choice_candidate(
                    result,
                    request_id,
                    request_type,
                    selected,
                    false
                );
                return;
            }
            for (
                std::size_t index = begin;
                index < options->as_array().size();
                ++index
            ) {
                selected.push_back(&options->as_array()[index]);
                enumerate(
                    allow_duplicates ? index : index + 1,
                    remaining - 1
                );
                selected.pop_back();
                if (result.size() >= MAX_CANDIDATES) {
                    return;
                }
            }
        };
    for (
        std::int64_t size = minimum;
        size <= maximum && result.size() < MAX_CANDIDATES;
        ++size
    ) {
        enumerate(0, static_cast<std::size_t>(size));
    }
    if (
        bool_arg(request, "can_cancel")
        && result.size() < MAX_CANDIDATES
    ) {
        append_choice_candidate(
            result,
            request_id,
            request_type,
            {},
            true
        );
    }
    // Multiple identical physical cards can legitimately produce the same
    // semantic selection (especially for allow_duplicates distribution
    // requests). The tree is keyed by stable signatures, so collapse those
    // aliases before expansion instead of letting a determinization create
    // duplicate edges.
    Array unique;
    unique.reserve(result.size());
    std::unordered_set<std::string> signatures;
    for (Value &candidate : result) {
        const std::string signature = string_arg(
            candidate,
            "signature"
        );
        if (
            !signature.empty()
            && signatures.insert(signature).second
        ) {
            unique.push_back(std::move(candidate));
        }
    }
    return Value(std::move(unique));
}

GameExecutionResult NativeGameKernel::apply_action(
    Value state,
    const Value &action,
    std::uint32_t rng_state
) const {
    GameExecutionResult result;
    result.state = std::move(state);
    result.rng_state = rng_state;
    if (!action.is_object()) {
        result.error_code = "invalid_action";
        return result;
    }
    const std::string kind = string_arg(
        action,
        "action",
        string_arg(action, "kind")
    );
    const Value action_params = canonical_params(action, kind);
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_arg(
            action,
            "actor",
            integer_arg(result.state, "active_player_idx", -1)
        )
    );
    if (actor < 0 || actor > 1) {
        result.error_code = "invalid_actor";
        return result;
    }

    try {
        Value &self = player(result.state, actor);
        Value &opponent = player(result.state, 1 - actor);
        increment(result.state, "revision");

        if (kind == "PLAY_BASIC") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            if (hand_index >= hand.size()) {
                throw std::invalid_argument("invalid_hand_index");
            }
            const std::string id = hand[hand_index].string_or();
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            const std::string target = string_arg(
                action_params,
                "target",
                "active"
            );
            if (target == "active") {
                self["active"] = make_pokemon(id, true);
            } else {
                if (target.rfind("bench_", 0) != 0) {
                    throw std::invalid_argument(
                        "basic_target_slot_invalid"
                    );
                }
                const std::size_t bench_index = static_cast<std::size_t>(
                    std::stoul(target.substr(6))
                );
                required(self, "bench").as_array().at(bench_index) =
                    make_pokemon(id, true);
            }
            result.event_types.emplace_back("pokemon_played");
        } else if (kind == "EVOLVE") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            if (hand_index >= hand.size()) {
                throw std::invalid_argument("invalid_hand_index");
            }
            const std::string next_id = hand[hand_index].string_or();
            Value *target = pokemon(
                self,
                string_arg(action_params, "slot", "active")
            );
            if (target == nullptr) {
                throw std::invalid_argument("evolution_target_missing");
            }
            required(
                *target,
                "evolution_stack_ids"
            ).as_array().emplace_back(string_arg(*target, "card_id"));
            (*target)["card_id"] = Value(next_id);
            (*target)["can_evolve_this_turn"] = Value(false);
            (*target)["status_conditions"] = Value::make_array();
            (*target)["paralyzed_since_turn"] = Value(0);
            (*target)["used_abilities"] = Value::make_array();
            clear_attack_effects_on_leave(*target);
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            result.event_types.emplace_back("pokemon_evolved");
        } else if (kind == "ATTACH_ENERGY") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            const std::string target_slot = string_arg(
                action_params,
                "target_slot",
                "active"
            );
            Value *target = pokemon(
                self,
                target_slot
            );
            if (hand_index >= hand.size() || target == nullptr) {
                throw std::invalid_argument("energy_attachment_invalid");
            }
            const std::string energy_id = hand[hand_index].string_or();
            required(
                *target,
                "energy_card_ids"
            ).as_array().push_back(std::move(hand[hand_index]));
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            self["energy_attached_this_turn"] = Value(true);
            result.event_types.emplace_back("energy_attached");
            if (energy_switches_with_active_on_attach(
                cards_,
                energy_id,
                target_slot
            )) {
                switch_active(self, target_slot);
                result.event_types.emplace_back("switched");
            }
        } else if (kind == "RETREAT") {
            Value *active = pokemon(self, "active");
            if (active == nullptr) {
                throw std::invalid_argument("retreat_active_missing");
            }
            const std::int64_t retreat_cost = effective_retreat_cost(
                cards_,
                result.state,
                *active,
                card_definition(cards_, string_arg(*active, "card_id"))
            );
            const std::size_t bench_index = static_cast<std::size_t>(
                integer_arg(action_params, "bench_idx", -1)
            );
            Array &bench = required(self, "bench").as_array();
            if (
                bench_index >= bench.size()
                || !bench[bench_index].is_object()
            ) {
                throw std::invalid_argument("retreat_target_missing");
            }
            if (retreat_cost <= 0) {
                switch_active(
                    self,
                    "bench_" + std::to_string(bench_index)
                );
                self["retreated_this_turn"] = Value(true);
                result.event_types.emplace_back("retreat");
                result.success = true;
                return result;
            }
            const Array &energy = required(
                *active,
                "energy_card_ids"
            ).as_array();
            if (
                energy_units(cards_, *active).size()
                < static_cast<std::size_t>(retreat_cost)
            ) {
                throw std::invalid_argument("retreat_energy_missing");
            }
            Array options;
            for (std::size_t index = 0; index < energy.size(); ++index) {
                options.emplace_back(Object{
                    {"kind", Value("attachment")},
                    {"player", Value(actor)},
                    {"card_id", Value(energy[index].string_or())},
                    {"slot", Value("active")},
                    {"attachment_type", Value("energy")},
                    {"index", Value(static_cast<std::int64_t>(index))},
                });
            }
            increment(result.state, "choice_sequence");
            result.pending = action_pending(
                "select_retreat_payment",
                actor,
                1,
                static_cast<std::int64_t>(energy.size()),
                true,
                std::move(options),
                "retreat_payment",
                false
            );
            result.continuation = Value(Object{
                {"kind", Value("retreat_payment")},
                {"actor", Value(actor)},
                {
                    "bench_idx",
                    Value(integer_arg(action_params, "bench_idx", -1)),
                },
                {"required_units", Value(retreat_cost)},
            });
        } else if (kind == "PROMOTE") {
            const std::size_t bench_index = static_cast<std::size_t>(
                integer_arg(action_params, "bench_idx", -1)
            );
            Array &bench = required(self, "bench").as_array();
            if (
                bench_index >= bench.size()
                || !bench[bench_index].is_object()
            ) {
                throw std::invalid_argument("promotion_target_missing");
            }
            self["active"] = std::move(bench[bench_index]);
            bench[bench_index] = Value();
            Array &pending = required(
                result.state,
                "pending_promotions"
            ).as_array();
            pending.erase(
                std::remove_if(
                    pending.begin(),
                    pending.end(),
                    [actor](const Value &entry) {
                        return entry.as_integer(-1) == actor;
                    }
                ),
                pending.end()
            );
            result.event_types.emplace_back("promoted");
            if (
                string_arg(result.state, "phase") == "ATTACK"
                && pending.empty()
            ) {
                finish_turn(
                    result.state,
                    static_cast<std::int32_t>(
                        integer_arg(result.state, "active_player_idx")
                    ),
                    result.event_types,
                    &result.rng_state
                );
            } else if (
                string_arg(result.state, "phase")
                    == "POKEMON_CHECKUP"
                && pending.empty()
            ) {
                complete_checkup_transition(
                    result.state,
                    static_cast<std::int32_t>(
                        integer_arg(
                            result.state,
                            "active_player_idx"
                        )
                    ),
                    result.event_types
                );
            }
        } else if (kind == "END_TURN") {
            finish_turn(
                result.state,
                actor,
                result.event_types,
                &result.rng_state
            );
        } else if (kind == "USE_STADIUM") {
            const std::string id = string_arg(
                result.state,
                "stadium_card_id"
            );
            const Value *definition = card_definition(cards_, id);
            if (definition == nullptr) {
                throw std::invalid_argument("stadium_missing");
            }
            const Value *effects = definition->find(
                "compiled_trainer_effects"
            );
            if (effects != nullptr && effects->is_array()) {
                for (const Value &effect : effects->as_array()) {
                    VmExecutionResult vm = rules_.execute(
                        std::move(result.state),
                        effect,
                        actor,
                        "active",
                        result.rng_state,
                        "trainer"
                    );
                    if (!vm.success) {
                        throw std::invalid_argument(vm.error_code);
                    }
                    result.state = std::move(vm.state);
                    result.rng_state = vm.rng_state;
                    for (const std::string &event : vm.event_types) {
                        result.event_types.push_back(
                            event == "damage_counters_placed"
                            ? "damage_dealt"
                            : event
                        );
                    }
                    append_events(result.events, vm.events);
                }
            }
            player(result.state, actor)["stadium_used_this_turn"] =
                Value(true);
        } else if (kind == "PLAY_TRAINER") {
            Array &hand = required(self, "hand").as_array();
            const std::size_t hand_index = static_cast<std::size_t>(
                integer_arg(action_params, "hand_idx", -1)
            );
            if (hand_index >= hand.size()) {
                throw std::invalid_argument("invalid_hand_index");
            }
            const std::string id = hand[hand_index].string_or();
            const Value *definition = card_definition(cards_, id);
            if (definition == nullptr) {
                throw std::invalid_argument("trainer_definition_missing");
            }
            const std::string trainer_type = string_arg(
                *definition,
                "trainer_type"
            );
            hand.erase(
                hand.begin() + static_cast<std::ptrdiff_t>(hand_index)
            );
            if (trainer_type == "Tool") {
                const std::string target_slot = string_arg(
                    action_params,
                    "target_slot",
                    "active"
                );
                Value *target = pokemon(
                    self,
                    target_slot
                );
                if (target == nullptr) {
                    throw std::invalid_argument("tool_target_missing");
                }
                (*target)["attached_tool_id"] = Value(id);
                append_tool_modifiers(
                    *target,
                    *definition,
                    actor,
                    target_slot
                );
                result.event_types.emplace_back("tool_attached");
            } else {
                result.event_types.emplace_back("trainer_played");
                const Value *effects = definition->find(
                    "compiled_trainer_effects"
                );
                if (effects != nullptr && effects->is_array()) {
                    Array rows = effects->as_array();
                    if (
                        rows.size() == 1
                        && string_arg(rows.front(), "op") == "conditional"
                    ) {
                        const Value *branches = rows.front().find("branches");
                        const Value *cost = (
                            branches != nullptr && branches->is_object()
                        ) ? branches->find("cost") : nullptr;
                        const Value *on_pay = (
                            branches != nullptr && branches->is_object()
                        ) ? branches->find("on_pay") : nullptr;
                        const bool has_cost = cost != nullptr
                            && cost->is_array()
                            && !cost->as_array().empty();
                        if (
                            !has_cost
                            && on_pay != nullptr
                            && on_pay->is_array()
                        ) {
                            const Value *conditional_args =
                                rows.front().find("args");
                            const std::string condition = (
                                conditional_args != nullptr
                                && conditional_args->is_object()
                            ) ? string_arg(
                                *conditional_args,
                                "condition"
                            ) : std::string{};
                            if (
                                condition == "ko_last_opponent_turn"
                                && !previous_turn_had_knockout(
                                    result.state,
                                    actor
                                )
                            ) {
                                throw std::invalid_argument(
                                    "conditional_condition_not_met"
                                );
                            }
                            rows = on_pay->as_array();
                        }
                    }
                    for (
                        std::size_t effect_index = 0;
                        effect_index < rows.size();
                        ++effect_index
                    ) {
                        const Value &effect = rows[effect_index];
                        VmExecutionResult vm = rules_.execute(
                            std::move(result.state),
                            effect,
                            actor,
                            "active",
                            result.rng_state,
                            "trainer"
                        );
                        if (!vm.success) {
                            throw std::invalid_argument(vm.error_code);
                        }
                        result.state = std::move(vm.state);
                        result.rng_state = vm.rng_state;
                        result.event_types.insert(
                            result.event_types.end(),
                            vm.event_types.begin(),
                            vm.event_types.end()
                        );
                        append_events(result.events, vm.events);
                        if (!vm.pending.as_object().empty()) {
                            attach_game_continuation(
                                result,
                                vm,
                                actor,
                                false,
                                remaining_effects(
                                    rows,
                                    effect_index + 1
                                ),
                                "active",
                                "trainer"
                            );
                            break;
                        }
                    }
                }
                Value &current_self = player(result.state, actor);
                if (trainer_type == "Supporter") {
                    current_self["supporter_played_this_turn"] = Value(true);
                }
                if (
                    trainer_type == "Supporter"
                    || trainer_type == "Item"
                ) {
                    required(
                        current_self,
                        "discard"
                    ).as_array().emplace_back(id);
                }
            }
        } else if (kind == "USE_ABILITY") {
            std::string slot = string_arg(
                action_params,
                "slot",
                "active"
            );
            const bool discard_source = slot == "discard"
                || slot.rfind("discard_", 0) == 0;
            std::string source_card_id;
            std::string effect_source_slot = slot;
            Value *source = nullptr;
            if (discard_source) {
                std::int64_t discard_index = integer_arg(
                    action_params,
                    "discard_idx",
                    -1
                );
                if (discard_index < 0 && slot.rfind("discard_", 0) == 0) {
                    discard_index = std::stoll(slot.substr(8));
                }
                const Array &discard = required(self, "discard").as_array();
                if (
                    discard_index < 0
                    || static_cast<std::size_t>(discard_index)
                        >= discard.size()
                ) {
                    throw std::invalid_argument("ability_source_missing");
                }
                source_card_id = discard[
                    static_cast<std::size_t>(discard_index)
                ].string_or();
                const std::string requested_id = string_arg(
                    action_params,
                    "card_id"
                );
                if (
                    !requested_id.empty()
                    && requested_id != source_card_id
                ) {
                    throw std::invalid_argument(
                        "ability_source_identity_mismatch"
                    );
                }
                const Array &bench = required(self, "bench").as_array();
                const auto empty = std::find_if(
                    bench.begin(),
                    bench.end(),
                    [](const Value &entry) { return entry.is_null(); }
                );
                if (empty == bench.end()) {
                    throw std::invalid_argument(
                        "ability_revive_target_missing"
                    );
                }
                effect_source_slot = "bench_"
                    + std::to_string(std::distance(bench.begin(), empty));
            } else {
                source = pokemon(self, slot);
                if (source == nullptr) {
                    throw std::invalid_argument("ability_source_missing");
                }
                source_card_id = string_arg(*source, "card_id");
            }
            const Value *definition = card_definition(
                cards_,
                source_card_id
            );
            const std::string ability_name = string_arg(
                action_params,
                "ability_name"
            );
            const Value *ability = definition == nullptr
                ? nullptr
                : find_named_ability(*definition, ability_name);
            if (ability == nullptr) {
                throw std::invalid_argument("ability_missing");
            }
            const Value *effects = ability->find("compiled_effects");
            if (effects != nullptr && effects->is_array()) {
                const Array &rows = effects->as_array();
                for (
                    std::size_t effect_index = 0;
                    effect_index < rows.size();
                    ++effect_index
                ) {
                    const Value &effect = rows[effect_index];
                    VmExecutionResult vm = rules_.execute(
                        std::move(result.state),
                        effect,
                        actor,
                        effect_source_slot,
                        result.rng_state,
                        "ability"
                    );
                    if (!vm.success) {
                        throw std::invalid_argument(vm.error_code);
                    }
                    result.state = std::move(vm.state);
                    result.rng_state = vm.rng_state;
                    for (const std::string &event : vm.event_types) {
                        result.event_types.push_back(
                            event == "damage_counters_placed"
                            ? "damage_dealt"
                            : event
                        );
                    }
                    append_events(result.events, vm.events);
                    if (!vm.pending.as_object().empty()) {
                        attach_game_continuation(
                            result,
                            vm,
                            actor,
                            false,
                            remaining_effects(
                                rows,
                                effect_index + 1
                            ),
                            effect_source_slot,
                            "ability"
                        );
                        break;
                    }
                }
            }
            source = pokemon(
                player(result.state, actor),
                effect_source_slot
            );
            if (
                source != nullptr
                && string_arg(*ability, "trigger") != "repeatable"
                && !array_contains_string(
                    source->find("used_abilities"),
                    ability_name
                )
            ) {
                required(
                    *source,
                    "used_abilities"
                ).as_array().emplace_back(ability_name);
            }
            if (result.pending.as_object().empty()) {
                settle_ability_effect_knockouts(
                    result,
                    cards_,
                    actor
                );
                if (result.pending.as_object().empty()) {
                    finalize_terminal_if_needed(result);
                }
            }
        } else if (kind == "DECLARE_ATTACK") {
            result.state["phase"] = Value("ATTACK");
            result.event_types.emplace_back("attack_declared");
            Value *attacker = pokemon(self, "active");
            Value *defender = pokemon(opponent, "active");
            if (attacker == nullptr || defender == nullptr) {
                throw std::invalid_argument("attack_board_invalid");
            }
            const Value *definition = card_definition(
                cards_,
                string_arg(*attacker, "card_id")
            );
            const Value *attacks = definition == nullptr
                ? nullptr
                : definition->find("attacks");
            const std::size_t attack_index = static_cast<std::size_t>(
                integer_arg(action_params, "attack_idx")
            );
            if (
                attacks == nullptr
                || !attacks->is_array()
                || attack_index >= attacks->as_array().size()
            ) {
                throw std::invalid_argument("attack_missing");
            }
            const Value &attack = attacks->as_array()[attack_index];
            append_event(
                result,
                "attack_declared",
                Object{
                    {"player", Value(actor)},
                    {
                        "card_id",
                        Value(string_arg(*attacker, "card_id")),
                    },
                    {
                        "attack_idx",
                        Value(static_cast<std::int64_t>(attack_index)),
                    },
                    {
                        "attack_name",
                        Value(string_arg(attack, "name")),
                    },
                }
            );
            if (
                array_contains_string(
                    attacker->find("status_conditions"),
                    "CONFUSED"
                )
            ) {
                XorShift32 rng(result.rng_state);
                const bool heads = (rng.next_u32() & 1U) == 0;
                result.rng_state = rng.state();
                result.event_types.emplace_back("coin_flip");
                append_event(
                    result,
                    "coin_flip",
                    Object{
                        {"player", Value(actor)},
                        {"results", Value(Array{Value(heads)})},
                        {"purpose", Value("confusion")},
                    }
                );
                if (!heads) {
                    add_damage(*attacker, 30);
                    result.event_types.emplace_back("confusion_failed");
                    append_event(
                        result,
                        "confusion_failed",
                        Object{
                            {"player", Value(actor)},
                            {"slot", Value("active")},
                            {"self_damage", Value(30)},
                        }
                    );
                    finish_turn(
                        result.state,
                        actor,
                        result.event_types,
                        &result.rng_state
                    );
                    result.success = true;
                    return result;
                }
            }
            bool dazzled = false;
            Value *modifiers = attacker->find("modifiers");
            if (modifiers != nullptr && modifiers->is_array()) {
                const auto gate = std::find_if(
                    modifiers->as_array().begin(),
                    modifiers->as_array().end(),
                    [](const Value &descriptor) {
                        const Value *operation = descriptor.find(
                            "operation"
                        );
                        return operation != nullptr
                            && operation->is_object()
                            && string_arg(*operation, "kind")
                                == "attack_gate_coin"
                            && string_arg(*operation, "reason")
                                == "dazzled";
                    }
                );
                if (gate != modifiers->as_array().end()) {
                    modifiers->as_array().erase(gate);
                    dazzled = true;
                }
            }
            if (dazzled) {
                XorShift32 rng(result.rng_state);
                const bool heads = (rng.next_u32() & 1U) == 0;
                result.rng_state = rng.state();
                result.event_types.emplace_back("coin_flip");
                append_event(
                    result,
                    "coin_flip",
                    Object{
                        {"player", Value(actor)},
                        {"results", Value(Array{Value(heads)})},
                        {"purpose", Value("dazzled")},
                    }
                );
                if (!heads) {
                    result.event_types.emplace_back("dazzled_failed");
                    append_event(
                        result,
                        "dazzled_failed",
                        Object{
                            {"player", Value(actor)},
                            {"slot", Value("active")},
                        }
                    );
                    finish_turn(
                        result.state,
                        actor,
                        result.event_types,
                        &result.rng_state
                    );
                    result.success = true;
                    return result;
                }
            }
            const Value *effects = attack.find("compiled_effects");
            bool replace_damage = false;
            if (effects != nullptr && effects->is_array()) {
                for (const Value &effect : effects->as_array()) {
                    replace_damage = replace_damage
                        || replaces_attack_damage(
                            string_arg(effect, "op")
                        );
                }
            }
            Value context = Value(Object{
                {
                    "base_damage",
                    Value(
                        replace_damage
                        ? 0
                        : integer_arg(attack, "damage")
                    ),
                },
            });
            std::vector<std::string> effect_events;
            std::vector<Value> effect_payloads;
            if (effects != nullptr && effects->is_array()) {
                const Array &rows = effects->as_array();
                for (
                    std::size_t effect_index = 0;
                    effect_index < rows.size();
                    ++effect_index
                ) {
                    const Value &effect = rows[effect_index];
                    const std::string op = string_arg(effect, "op");
                    const Value *args_ptr = effect.find("args");
                    const Value empty_args = Value::make_object();
                    const Value &effect_args = (
                        args_ptr != nullptr && args_ptr->is_object()
                    ) ? *args_ptr : empty_args;
                    if (
                        op == "deal_damage_then_heal"
                        && !bool_arg(context, "damage_applied")
                    ) {
                        context["base_damage"] = Value(integer_arg(
                            effect_args,
                            "damage"
                        ));
                        apply_attack_damage_before_effect(
                            result,
                            cards_,
                            actor,
                            context
                        );
                    } else if (
                        !attack_effect_runs_before_damage(op, effect_args)
                        && !bool_arg(context, "damage_applied")
                    ) {
                        apply_attack_damage_before_effect(
                            result,
                            cards_,
                            actor,
                            context
                        );
                    }
                    VmExecutionResult vm = rules_.execute(
                        std::move(result.state),
                        effect,
                        actor,
                        "active",
                        result.rng_state,
                        "attack",
                        context
                    );
                    if (!vm.success) {
                        throw std::invalid_argument(vm.error_code);
                    }
                    result.state = std::move(vm.state);
                    result.rng_state = vm.rng_state;
                    context = std::move(vm.context);
                    effect_events.insert(
                        effect_events.end(),
                        vm.event_types.begin(),
                        vm.event_types.end()
                    );
                    append_events(effect_payloads, vm.events);
                    if (!vm.pending.as_object().empty()) {
                        vm.context = context;
                        result.event_types.insert(
                            result.event_types.end(),
                            effect_events.begin(),
                            effect_events.end()
                        );
                        append_events(result.events, effect_payloads);
                        attach_game_continuation(
                            result,
                            vm,
                            actor,
                            true,
                            remaining_effects(
                                rows,
                                effect_index + 1
                            ),
                            "active",
                            "attack"
                        );
                        result.success = true;
                        return result;
                    }
                    if (
                        op == "prevent_all"
                        || op == "prevent_damage"
                        || op == "prevent_effects"
                        || op == "apply_self_attack_lock"
                    ) {
                        Value *current_source = pokemon(
                            player(result.state, actor),
                            "active"
                        );
                        if (current_source == nullptr) {
                            continue;
                        }
                        append_canonical_modifier(
                            *current_source,
                            *current_source,
                            op,
                            required(effect, "args"),
                            actor,
                            "active",
                            actor,
                            integer_arg(result.state, "turn_number")
                        );
                    } else if (
                        op == "apply_attack_lock_basic"
                        || op == "apply_dazzling_beam"
                        || op == "apply_outgoing_damage_reduction"
                    ) {
                        Value *current_source = pokemon(
                            player(result.state, actor),
                            "active"
                        );
                        Value *target = pokemon(
                            player(result.state, 1 - actor),
                            "active"
                        );
                        if (current_source == nullptr || target == nullptr) {
                            continue;
                        }
                        const Value *target_card = card_definition(
                            cards_,
                            string_arg(*target, "card_id")
                        );
                        const bool should_register = (
                            !bool_arg(*target, "all_prevented")
                            && (
                                op != "apply_attack_lock_basic"
                                || (
                                    target_card != nullptr
                                    && is_basic_pokemon(*target_card)
                                )
                            )
                        );
                        append_canonical_modifier(
                            *target,
                            *current_source,
                            should_register ? op : std::string{},
                            required(effect, "args"),
                            actor,
                            "active",
                            1 - actor,
                            integer_arg(result.state, "turn_number")
                        );
                    }
                }
            }
            result.event_types.insert(
                result.event_types.end(),
                effect_events.begin(),
                effect_events.end()
            );
            append_events(result.events, effect_payloads);
            finish_attack_resolution(result, cards_, actor, context);
        } else {
            throw std::invalid_argument("unsupported_native_action:" + kind);
        }
        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    return result;
}

GameExecutionResult NativeGameKernel::resume_choice(
    Value state,
    const Value &continuation,
    const Value &selected_options,
    bool cancelled,
    std::uint32_t rng_state
) const {
    GameExecutionResult result;
    result.state = std::move(state);
    result.rng_state = rng_state;
    if (!continuation.is_object()) {
        result.error_code = "invalid_game_continuation";
        return result;
    }
    try {
        const std::string kind = string_arg(continuation, "kind");
        const std::int32_t actor = static_cast<std::int32_t>(
            integer_arg(continuation, "actor", -1)
        );
        if (kind == "vm") {
            const Value *cancel_rollback = continuation.find(
                "cancel_rollback"
            );
            if (cancelled && cancel_rollback != nullptr) {
                if (
                    actor != 0
                    && actor != 1
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_actor_invalid"
                    );
                }
                if (
                    !cancel_rollback->is_object()
                    || cancel_rollback->as_object().size() != 6
                    || cancel_rollback->find("hand_before") == nullptr
                    || cancel_rollback->find("discard_before") == nullptr
                    || cancel_rollback->find("deck_top_before") == nullptr
                    || cancel_rollback->find(
                        "expected_current_deck_count"
                    ) == nullptr
                    || cancel_rollback->find(
                        "supporter_played_before"
                    ) == nullptr
                    || cancel_rollback->find(
                        "choice_sequence_before"
                    ) == nullptr
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_shape_invalid"
                    );
                }
                const Value &hand_before = required(
                    *cancel_rollback,
                    "hand_before"
                );
                const Value &discard_before = required(
                    *cancel_rollback,
                    "discard_before"
                );
                const Value &deck_top_before = required(
                    *cancel_rollback,
                    "deck_top_before"
                );
                if (
                    !hand_before.is_array()
                    || !discard_before.is_array()
                    || !deck_top_before.is_array()
                    || deck_top_before.as_array().size() > 2
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_zone_invalid"
                    );
                }
                auto card_ids = [this](
                    const Value &zone,
                    const char *error
                ) {
                    std::vector<std::string> ids;
                    ids.reserve(zone.as_array().size());
                    for (const Value &entry : zone.as_array()) {
                        const std::string card_id = entry.string_or();
                        if (
                            card_id.empty()
                            || card_definition(cards_, card_id) == nullptr
                        ) {
                            throw std::invalid_argument(error);
                        }
                        ids.push_back(card_id);
                    }
                    return ids;
                };
                const std::vector<std::string> expected_hand = card_ids(
                    hand_before,
                    "cancel_rollback_hand_invalid"
                );
                const std::vector<std::string> expected_discard = card_ids(
                    discard_before,
                    "cancel_rollback_discard_invalid"
                );
                const std::vector<std::string> expected_top = card_ids(
                    deck_top_before,
                    "cancel_rollback_deck_top_invalid"
                );
                Value &owner = player(result.state, actor);
                Array &current_hand = required(
                    owner,
                    "hand"
                ).as_array();
                Array &current_discard = required(
                    owner,
                    "discard"
                ).as_array();
                Array &current_deck = required(
                    owner,
                    "deck"
                ).as_array();
                const std::int64_t expected_deck_count = integer_arg(
                    *cancel_rollback,
                    "expected_current_deck_count",
                    -1
                );
                const std::int64_t sequence_before = integer_arg(
                    *cancel_rollback,
                    "choice_sequence_before",
                    -1
                );
                if (
                    expected_deck_count < 0
                    || static_cast<std::size_t>(expected_deck_count)
                        != current_deck.size()
                    || sequence_before < 0
                    || integer_arg(
                        result.state,
                        "choice_sequence",
                        -1
                    ) != sequence_before + 1
                    || bool_arg(
                        owner,
                        "supporter_played_this_turn"
                    ) == bool_arg(
                        *cancel_rollback,
                        "supporter_played_before"
                    )
                ) {
                    throw std::invalid_argument(
                        "cancel_rollback_precondition_failed"
                    );
                }
                std::vector<std::string> current_visible;
                current_visible.reserve(
                    current_hand.size() + current_discard.size()
                );
                for (const Value &entry : current_hand) {
                    const std::string card_id = entry.string_or();
                    if (
                        card_id.empty()
                        || card_definition(cards_, card_id) == nullptr
                    ) {
                        throw std::invalid_argument(
                            "cancel_rollback_current_hand_invalid"
                        );
                    }
                    current_visible.push_back(card_id);
                }
                for (const Value &entry : current_discard) {
                    const std::string card_id = entry.string_or();
                    if (
                        card_id.empty()
                        || card_definition(cards_, card_id) == nullptr
                    ) {
                        throw std::invalid_argument(
                            "cancel_rollback_current_discard_invalid"
                        );
                    }
                    current_visible.push_back(card_id);
                }
                std::vector<std::string> expected_visible(
                    expected_hand.begin(),
                    expected_hand.end()
                );
                expected_visible.insert(
                    expected_visible.end(),
                    expected_discard.begin(),
                    expected_discard.end()
                );
                expected_visible.insert(
                    expected_visible.end(),
                    expected_top.begin(),
                    expected_top.end()
                );
                std::sort(
                    current_visible.begin(),
                    current_visible.end()
                );
                std::sort(
                    expected_visible.begin(),
                    expected_visible.end()
                );
                if (current_visible != expected_visible) {
                    throw std::invalid_argument(
                        "cancel_rollback_card_conservation_failed"
                    );
                }
                current_hand = hand_before.as_array();
                current_discard = discard_before.as_array();
                for (const Value &entry : deck_top_before.as_array()) {
                    current_deck.push_back(entry);
                }
                owner["supporter_played_this_turn"] = Value(
                    bool_arg(
                        *cancel_rollback,
                        "supporter_played_before"
                    )
                );
                result.state["choice_sequence"] = Value(sequence_before);
                increment(result.state, "revision");
                result.success = true;
                return result;
            }
            VmExecutionResult vm = rules_.resume(
                std::move(result.state),
                required(continuation, "context"),
                required(continuation, "vm"),
                selected_options,
                cancelled,
                result.rng_state
            );
            if (!vm.success) {
                throw std::invalid_argument(vm.error_code);
            }
            result.state = std::move(vm.state);
            result.rng_state = vm.rng_state;
            result.event_types = std::move(vm.event_types);
            result.events = std::move(vm.events);
            canonicalize_vm_modifiers(
                result.state,
                actor,
                string_arg(
                    continuation,
                    "source_slot",
                    "active"
                )
            );
            Value continued_context = vm.context;
            if (!vm.pending.as_object().empty()) {
                attach_game_continuation(
                    result,
                    vm,
                    actor,
                    bool_arg(continuation, "finish_attack"),
                    continuation.find("remaining_effects") != nullptr
                        ? *continuation.find("remaining_effects")
                        : Value::make_array(),
                    string_arg(
                        continuation,
                        "source_slot",
                        "active"
                    ),
                    string_arg(continuation, "context_mode")
                );
                const Value *post_vm_trigger_groups = continuation.find(
                    "post_vm_trigger_groups"
                );
                if (post_vm_trigger_groups != nullptr) {
                    result.continuation["post_vm_trigger_groups"] =
                        *post_vm_trigger_groups;
                }
            } else {
                const Value *remaining = continuation.find(
                    "remaining_effects"
                );
                if (remaining != nullptr && remaining->is_array()) {
                    const Array &rows = remaining->as_array();
                    for (
                        std::size_t effect_index = 0;
                        effect_index < rows.size();
                        ++effect_index
                    ) {
                        VmExecutionResult following = rules_.execute(
                            std::move(result.state),
                            rows[effect_index],
                            actor,
                            string_arg(
                                continuation,
                                "source_slot",
                                "active"
                            ),
                            result.rng_state,
                            string_arg(continuation, "context_mode"),
                            continued_context
                        );
                        if (!following.success) {
                            throw std::invalid_argument(
                                following.error_code
                            );
                        }
                        result.state = std::move(following.state);
                        result.rng_state = following.rng_state;
                        continued_context = following.context;
                        canonicalize_vm_modifiers(
                            result.state,
                            actor,
                            string_arg(
                                continuation,
                                "source_slot",
                                "active"
                            )
                        );
                        result.event_types.insert(
                            result.event_types.end(),
                            following.event_types.begin(),
                            following.event_types.end()
                        );
                        append_events(result.events, following.events);
                        if (!following.pending.as_object().empty()) {
                            attach_game_continuation(
                                result,
                                following,
                                actor,
                                bool_arg(
                                    continuation,
                                    "finish_attack"
                                ),
                                remaining_effects(
                                    rows,
                                    effect_index + 1
                                ),
                                string_arg(
                                    continuation,
                                    "source_slot",
                                    "active"
                                ),
                                string_arg(
                                    continuation,
                                    "context_mode"
                                )
                            );
                            const Value *post_vm_trigger_groups =
                                continuation.find(
                                    "post_vm_trigger_groups"
                                );
                            if (post_vm_trigger_groups != nullptr) {
                                result.continuation[
                                    "post_vm_trigger_groups"
                                ] = *post_vm_trigger_groups;
                            }
                            break;
                        }
                    }
                }
                if (
                    result.pending.as_object().empty()
                    && bool_arg(continuation, "finish_attack")
                ) {
                    const Value *post_vm_trigger_groups = continuation.find(
                        "post_vm_trigger_groups"
                    );
                    if (post_vm_trigger_groups != nullptr) {
                        if (!post_vm_trigger_groups->is_array()) {
                            throw std::invalid_argument(
                                "post_vm_trigger_queue_invalid"
                            );
                        }
                        if (consume_public_trigger_groups(
                            result,
                            actor,
                            post_vm_trigger_groups->as_array(),
                            continued_context,
                            "post_vm_trigger_queue_invalid"
                        )) {
                            result.success = true;
                            return result;
                        }
                    }
                    finish_attack_resolution(
                        result,
                        cards_,
                        actor,
                        continued_context
                    );
                }
            }
            if (
                result.pending.as_object().empty()
                && !bool_arg(continuation, "finish_attack")
            ) {
                if (string_arg(continuation, "context_mode") == "ability") {
                    settle_ability_effect_knockouts(
                        result,
                        cards_,
                        actor
                    );
                }
                if (result.pending.as_object().empty()) {
                    finalize_terminal_if_needed(result);
                }
            }
        } else if (kind == "public_bench_damage_targets") {
            increment(result.state, "revision");
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    -1
                ));
            const std::int32_t target_player =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "target_player",
                    -1
                ));
            const std::int64_t amount = integer_arg(
                continuation,
                "amount"
            );
            const std::int64_t count = integer_arg(
                continuation,
                "count"
            );
            const Value *allowed_value = continuation.find(
                "allowed_targets"
            );
            const Value *groups_value = continuation.find(
                "trigger_groups"
            );
            if (
                cancelled
                || actor != attack_actor
                || (attack_actor != 0 && attack_actor != 1)
                || target_player != 1 - attack_actor
                || amount <= 0
                || amount > 1000
                || count <= 0
                || count > 5
                || string_arg(result.state, "phase") != "ATTACK"
                || integer_arg(
                    result.state,
                    "active_player_idx",
                    -1
                ) != attack_actor
                || pokemon(
                    player(result.state, attack_actor),
                    "active"
                ) == nullptr
                || allowed_value == nullptr
                || !allowed_value->is_array()
                || allowed_value->as_array().size()
                    < static_cast<std::size_t>(count)
                || allowed_value->as_array().size() > 5
                || groups_value == nullptr
                || !groups_value->is_array()
                || !selected_options.is_array()
                || selected_options.as_array().size()
                    != static_cast<std::size_t>(count)
            ) {
                throw std::invalid_argument(
                    "public_bench_damage_selection_invalid"
                );
            }

            std::unordered_set<std::string> allowed_ids;
            std::unordered_set<std::string> allowed_slots;
            for (const Value &target : allowed_value->as_array()) {
                const std::string option_id = string_arg(
                    target,
                    "option_id"
                );
                const std::string slot = string_arg(
                    target,
                    "target_slot"
                );
                const std::string expected_card_id = string_arg(
                    target,
                    "target_card_id"
                );
                const bool valid_slot = (
                    slot.size() == 7
                    && slot.rfind("bench_", 0) == 0
                    && slot[6] >= '0'
                    && slot[6] <= '4'
                );
                const Value *current = valid_slot
                    ? pokemon(
                        player(result.state, target_player),
                        slot
                    )
                    : nullptr;
                if (
                    option_id.empty()
                    || expected_card_id.empty()
                    || !valid_slot
                    || !allowed_ids.insert(option_id).second
                    || !allowed_slots.insert(slot).second
                    || current == nullptr
                    || string_arg(*current, "card_id")
                        != expected_card_id
                ) {
                    throw std::invalid_argument(
                        "public_bench_damage_targets_invalid"
                    );
                }
            }

            Array damage_packets;
            std::unordered_set<std::string> selected_ids;
            for (const Value &selected : selected_options.as_array()) {
                const std::string option_id = string_arg(
                    selected,
                    "option_id"
                );
                const auto found = std::find_if(
                    allowed_value->as_array().begin(),
                    allowed_value->as_array().end(),
                    [&option_id](const Value &target) {
                        return string_arg(target, "option_id")
                            == option_id;
                    }
                );
                if (
                    option_id.empty()
                    || !selected_ids.insert(option_id).second
                    || found == allowed_value->as_array().end()
                ) {
                    throw std::invalid_argument(
                        "public_bench_damage_selection_invalid"
                    );
                }
                damage_packets.emplace_back(Object{
                    {"target_player", Value(target_player)},
                    {
                        "target_slot",
                        Value(string_arg(*found, "target_slot")),
                    },
                    {"amount", Value(amount)},
                });
            }

            Value attack_context(Object{
                {"base_damage", Value(0)},
                {"damage_packets", Value(std::move(damage_packets))},
                {"attack_failed", Value(false)},
            });
            apply_attack_damage_before_effect(
                result,
                cards_,
                attack_actor,
                attack_context
            );
            // The formal primary hit has already produced the exact public
            // reaction queue copied below.  Never synthesize it again from
            // this isolated bench packet.
            attack_context["after_damage_triggers_applied"] = Value(true);
            attack_context["reactive_thorns_applied"] = Value(true);

            Array groups = groups_value->as_array();
            std::int32_t previous_order = -1;
            std::size_t total_specs = 0;
            for (const Value &group : groups) {
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
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
                    throw std::invalid_argument(
                        "public_bench_damage_trigger_queue_invalid"
                    );
                }
                previous_order = order;
                total_specs += specs_value->as_array().size();
                if (total_specs > 64) {
                    throw std::invalid_argument(
                        "public_bench_damage_trigger_queue_invalid"
                    );
                }
                for (const Value &spec : specs_value->as_array()) {
                    validate_public_trigger_spec(result.state, spec);
                }
            }
            while (!groups.empty()) {
                Value group = std::move(groups.front());
                groups.erase(groups.begin());
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
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
                    result.success = true;
                    return result;
                }
                apply_public_trigger_spec(result, specs.front());
            }
            finish_attack_resolution(
                result,
                cards_,
                attack_actor,
                attack_context
            );
        } else if (kind == "public_trigger_order") {
            increment(result.state, "revision");
            const Value *specs_value = continuation.find(
                "trigger_specs"
            );
            if (
                specs_value == nullptr
                || !specs_value->is_array()
                || specs_value->as_array().size() < 2
                || !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_selection_invalid"
                );
            }
            const std::string selected_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            if (selected_id.rfind("trigger:", 0) == 0) {
                try {
                    std::size_t consumed = 0;
                    selected_index = std::stoll(
                        selected_id.substr(8),
                        &consumed
                    );
                    if (consumed != selected_id.size() - 8) {
                        selected_index = -1;
                    }
                } catch (const std::exception &) {
                    selected_index = -1;
                }
            }
            Array trigger_specs = specs_value->as_array();
            if (
                selected_index < 0
                || static_cast<std::size_t>(selected_index)
                    >= trigger_specs.size()
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_selection_invalid"
                );
            }
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    -1
                ));
            const std::int32_t trigger_owner =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "trigger_owner",
                    actor
                ));
            if (
                (attack_actor != 0 && attack_actor != 1)
                || (trigger_owner != 0 && trigger_owner != 1)
                || trigger_owner != actor
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_actor_invalid"
                );
            }
            Value chosen = trigger_specs.at(
                static_cast<std::size_t>(selected_index)
            );
            trigger_specs.erase(
                trigger_specs.begin() + selected_index
            );
            apply_public_trigger_spec(result, chosen);

            const Value *remaining_value = continuation.find(
                "remaining_trigger_groups"
            );
            if (
                remaining_value == nullptr
                || !remaining_value->is_array()
            ) {
                throw std::invalid_argument(
                    "public_trigger_order_queue_invalid"
                );
            }
            Array remaining_groups = remaining_value->as_array();
            if (trigger_specs.size() > 1) {
                suspend_public_trigger_order(
                    result,
                    attack_actor,
                    trigger_owner,
                    std::move(trigger_specs),
                    std::move(remaining_groups),
                    required(continuation, "attack_context")
                );
                result.success = true;
                return result;
            }
            if (trigger_specs.size() == 1) {
                apply_public_trigger_spec(
                    result,
                    trigger_specs.front()
                );
            }
            while (!remaining_groups.empty()) {
                Value group = std::move(remaining_groups.front());
                remaining_groups.erase(remaining_groups.begin());
                if (!group.is_object()) {
                    throw std::invalid_argument(
                        "public_trigger_order_queue_invalid"
                    );
                }
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
                const Value *group_specs_value = group.find("specs");
                if (
                    (owner != 0 && owner != 1)
                    || group_specs_value == nullptr
                    || !group_specs_value->is_array()
                    || group_specs_value->as_array().empty()
                ) {
                    throw std::invalid_argument(
                        "public_trigger_order_queue_invalid"
                    );
                }
                Array group_specs = group_specs_value->as_array();
                if (group_specs.size() > 1) {
                    suspend_public_trigger_order(
                        result,
                        attack_actor,
                        owner,
                        std::move(group_specs),
                        std::move(remaining_groups),
                        required(continuation, "attack_context")
                    );
                    result.success = true;
                    return result;
                }
                apply_public_trigger_spec(
                    result,
                    group_specs.front()
                );
            }
            Value attack_context = required(
                continuation,
                "attack_context"
            );
            finish_attack_resolution(
                result,
                cards_,
                attack_actor,
                attack_context
            );
        } else if (kind == "after_damage_trigger_order") {
            increment(result.state, "revision");
            const std::int64_t trigger_count = std::max<std::int64_t>(
                0,
                integer_arg(continuation, "trigger_count")
            );
            if (
                !selected_options.is_array()
                || selected_options.as_array().size() != 1
                || string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                ).rfind("trigger:", 0) != 0
            ) {
                throw std::invalid_argument(
                    "trigger_order_selection_invalid"
                );
            }
            const std::string selected_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            try {
                std::size_t consumed = 0;
                selected_index = std::stoll(
                    selected_id.substr(8),
                    &consumed
                );
                if (consumed != selected_id.size() - 8) {
                    selected_index = -1;
                }
            } catch (const std::exception &) {
                selected_index = -1;
            }
            if (
                trigger_count < 2
                || selected_index < 0
                || selected_index >= trigger_count
            ) {
                throw std::invalid_argument(
                    "trigger_order_selection_invalid"
                );
            }
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    -1
                ));
            const std::int32_t trigger_owner =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "trigger_owner",
                    actor
                ));
            const std::int64_t resolved_now = (
                trigger_count > 2 ? 1 : trigger_count
            );
            for (std::int64_t index = 0; index < resolved_now; ++index) {
                draw_one(
                    player(result.state, trigger_owner),
                    result.event_types
                );
            }
            if (trigger_count > 2) {
                suspend_after_damage_trigger_order(
                    result,
                    attack_actor,
                    trigger_owner,
                    trigger_count - 1,
                    (
                        continuation.find("remaining_trigger_groups")
                                != nullptr
                            ? continuation.find(
                                "remaining_trigger_groups"
                            )->as_array()
                            : Array{}
                    ),
                    required(continuation, "attack_context")
                );
                result.success = true;
                return result;
            }
            const Value *remaining = continuation.find(
                "remaining_trigger_groups"
            );
            Array remaining_groups = (
                remaining != nullptr && remaining->is_array()
            ) ? remaining->as_array() : Array{};
            while (!remaining_groups.empty()) {
                Value group = std::move(remaining_groups.front());
                remaining_groups.erase(remaining_groups.begin());
                const std::int32_t owner =
                    static_cast<std::int32_t>(integer_arg(
                        group,
                        "owner",
                        -1
                    ));
                const std::int64_t count = std::max<std::int64_t>(
                    0,
                    integer_arg(group, "count")
                );
                if (count > 1) {
                    suspend_after_damage_trigger_order(
                        result,
                        attack_actor,
                        owner,
                        count,
                        std::move(remaining_groups),
                        required(continuation, "attack_context")
                    );
                    result.success = true;
                    return result;
                }
                for (
                    std::int64_t index = 0;
                    index < count;
                    ++index
                ) {
                    draw_one(
                        player(result.state, owner),
                        result.event_types
                    );
                }
            }
            Value attack_context = required(
                continuation,
                "attack_context"
            );
            finish_attack_resolution(
                result,
                cards_,
                attack_actor,
                attack_context
            );
        } else if (kind == "retreat_payment") {
            increment(result.state, "revision");
            if (!cancelled) {
                Value &self = player(result.state, actor);
                Value *active = pokemon(self, "active");
                if (active == nullptr) {
                    throw std::invalid_argument("retreat_active_missing");
                }
                Array &energy = required(
                    *active,
                    "energy_card_ids"
                ).as_array();
                std::vector<std::size_t> indices;
                for (const Value &entry : selected_options.as_array()) {
                    indices.push_back(static_cast<std::size_t>(
                        integer_arg(entry, "index", -1)
                    ));
                }
                std::sort(indices.begin(), indices.end());
                if (
                    std::adjacent_find(indices.begin(), indices.end())
                    != indices.end()
                ) {
                    throw std::invalid_argument(
                        "retreat_payment_duplicate"
                    );
                }
                const std::int64_t required_units = integer_arg(
                    continuation,
                    "required_units"
                );
                std::int64_t paid_units = 0;
                std::vector<std::int64_t> selected_unit_counts;
                selected_unit_counts.reserve(indices.size());
                for (const std::size_t index : indices) {
                    if (index >= energy.size()) {
                        throw std::invalid_argument(
                            "retreat_payment_stale"
                        );
                    }
                    const std::int64_t units = energy_card_unit_count(
                        cards_,
                        energy[index].string_or()
                    );
                    paid_units += units;
                    selected_unit_counts.push_back(units);
                }
                if (paid_units < required_units) {
                    throw std::invalid_argument(
                        "retreat_payment_insufficient"
                    );
                }
                if (std::any_of(
                    selected_unit_counts.begin(),
                    selected_unit_counts.end(),
                    [paid_units, required_units](std::int64_t units) {
                        return paid_units - units >= required_units;
                    }
                )) {
                    throw std::invalid_argument(
                        "retreat_payment_redundant"
                    );
                }
                Array &discard = required(self, "discard").as_array();
                for (
                    auto iterator = indices.rbegin();
                    iterator != indices.rend();
                    ++iterator
                ) {
                    if (*iterator >= energy.size()) {
                        throw std::invalid_argument(
                            "retreat_payment_stale"
                        );
                    }
                    discard.push_back(std::move(energy[*iterator]));
                    energy.erase(
                        energy.begin()
                            + static_cast<std::ptrdiff_t>(*iterator)
                    );
                }
                const std::size_t bench_index = static_cast<std::size_t>(
                    integer_arg(continuation, "bench_idx", -1)
                );
                Array &bench = required(self, "bench").as_array();
                if (
                    bench_index >= bench.size()
                    || !bench[bench_index].is_object()
                ) {
                    throw std::invalid_argument("retreat_target_stale");
                }
                switch_active(
                    self,
                    "bench_" + std::to_string(bench_index)
                );
                self["retreated_this_turn"] = Value(true);
                if (!indices.empty()) {
                    result.event_types.emplace_back("cards_discarded");
                }
                result.event_types.emplace_back("retreat");
            }
        } else if (kind == "energy_attach_distribution") {
            increment(result.state, "revision");
            Value &self = player(result.state, actor);
            Array &deck = required(self, "deck").as_array();
            if (!cancelled) {
                for (const Value &selection : selected_options.as_array()) {
                    const auto energy = std::find_if(
                        deck.begin(),
                        deck.end(),
                        [this](const Value &entry) {
                            const Value *definition = card_definition(
                                cards_,
                                entry.string_or()
                            );
                            return definition != nullptr
                                && string_arg(*definition, "supertype")
                                    == "Energy"
                                && array_contains_string(
                                    definition->find("subtypes"),
                                    "Basic"
                                );
                        }
                    );
                    if (energy == deck.end()) {
                        break;
                    }
                    Value *target = pokemon(
                        self,
                        string_arg(selection, "slot")
                    );
                    if (target == nullptr) {
                        continue;
                    }
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(*energy));
                    deck.erase(energy);
                    result.event_types.emplace_back("energy_attached");
                }
            }
            XorShift32 rng(result.rng_state);
            shuffle_array(deck, rng);
            result.rng_state = rng.state();
            result.event_types.emplace_back("deck_shuffled");
            finish_turn(
                result.state,
                actor,
                result.event_types,
                &result.rng_state
            );
        } else if (kind == "public_exp_share_spec_order") {
            increment(result.state, "revision");
            const Value *specs_value = continuation.find(
                "exp_share_trigger_specs"
            );
            if (
                specs_value == nullptr
                || !specs_value->is_array()
                || specs_value->as_array().size() < 2
                || specs_value->as_array().size() > 8
                || !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "public_exp_share_order_selection_invalid"
                );
            }
            const std::string option_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            if (option_id.rfind("trigger:", 0) == 0) {
                try {
                    std::size_t consumed = 0;
                    selected_index = std::stoll(
                        option_id.substr(8),
                        &consumed
                    );
                    if (consumed != option_id.size() - 8) {
                        selected_index = -1;
                    }
                } catch (const std::exception &) {
                    selected_index = -1;
                }
            }
            Array trigger_specs = specs_value->as_array();
            if (
                selected_index < 0
                || static_cast<std::size_t>(selected_index)
                    >= trigger_specs.size()
            ) {
                throw std::invalid_argument(
                    "public_exp_share_order_selection_invalid"
                );
            }
            Value chosen = trigger_specs.at(
                static_cast<std::size_t>(selected_index)
            );
            trigger_specs.erase(
                trigger_specs.begin() + selected_index
            );
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            if (attack_actor != 0 && attack_actor != 1) {
                throw std::invalid_argument(
                    "public_exp_share_order_actor_invalid"
                );
            }
            suspend_public_exp_share_spec_confirmation(
                result,
                actor,
                attack_actor,
                continuation,
                std::move(chosen),
                std::move(trigger_specs)
            );
        } else if (kind == "public_exp_share_order") {
            increment(result.state, "revision");
            const std::int64_t count = integer_arg(
                continuation,
                "exp_share_order_count"
            );
            if (
                count < 2
                || count > 8
                || !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "exp_share_order_selection_invalid"
                );
            }
            const std::string option_id = string_arg(
                selected_options.as_array().front(),
                "option_id"
            );
            std::int64_t selected_index = -1;
            if (option_id.rfind("trigger:", 0) == 0) {
                try {
                    std::size_t consumed = 0;
                    selected_index = std::stoll(
                        option_id.substr(8),
                        &consumed
                    );
                    if (consumed != option_id.size() - 8) {
                        selected_index = -1;
                    }
                } catch (const std::exception &) {
                    selected_index = -1;
                }
            }
            if (selected_index < 0 || selected_index >= count) {
                throw std::invalid_argument(
                    "exp_share_order_selection_invalid"
                );
            }
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            suspend_exp_share_confirmation(
                result,
                actor,
                attack_actor,
                continuation,
                count - 1,
                count - 1 > 1
            );
        } else if (kind == "confirm_exp_share_trigger") {
            increment(result.state, "revision");
            const bool confirmed = selected_options.is_array()
                && !selected_options.as_array().empty()
                && string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                ) == "confirm:yes";
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            if (!confirmed) {
                continue_after_exp_share_trigger(
                    result,
                    cards_,
                    actor,
                    attack_actor,
                    continuation
                );
            } else {
                Value *source = pokemon(
                    player(result.state, actor),
                    string_arg(continuation, "from_slot", "active")
                );
                Value *target = pokemon(
                    player(result.state, actor),
                    string_arg(continuation, "to_slot")
                );
                if (
                    source == nullptr
                    || target == nullptr
                    || string_arg(*source, "card_id")
                        != string_arg(continuation, "from_card_id")
                    || string_arg(*target, "card_id")
                        != string_arg(continuation, "to_card_id")
                    || string_arg(*target, "attached_tool_id")
                        != string_arg(continuation, "target_tool_id")
                ) {
                    throw std::invalid_argument(
                        "exp_share_entity_changed"
                    );
                }
                Array options;
                const Array &energy = required(
                    *source,
                    "energy_card_ids"
                ).as_array();
                for (std::size_t index = 0; index < energy.size(); ++index) {
                    if (!is_basic_energy_id(
                        cards_,
                        energy[index].string_or()
                    )) {
                        continue;
                    }
                    options.emplace_back(Object{
                        {"kind", Value("attachment")},
                        {"player", Value(actor)},
                        {
                            "slot",
                            Value(string_arg(
                                continuation,
                                "from_slot",
                                "active"
                            )),
                        },
                        {
                            "index",
                            Value(static_cast<std::int64_t>(index)),
                        },
                        {"attachment_type", Value("energy")},
                        {"card_id", Value(energy[index].string_or())},
                    });
                }
                if (options.empty()) {
                    continue_after_exp_share_trigger(
                        result,
                        cards_,
                        actor,
                        attack_actor,
                        continuation
                    );
                } else {
                    increment(result.state, "choice_sequence");
                    result.pending = action_pending(
                        "select_attachment",
                        actor,
                        1,
                        1,
                        false,
                        std::move(options),
                        "select_exp_share_energy",
                        true
                    );
                    Value continued = continuation;
                    continued["kind"] = Value(
                        "select_exp_share_energy"
                    );
                    result.continuation = std::move(continued);
                }
            }
        } else if (kind == "select_exp_share_energy") {
            increment(result.state, "revision");
            if (
                !selected_options.is_array()
                || selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "exp_share_energy_selection_invalid"
                );
            }
            const Value &selection =
                selected_options.as_array().front();
            const std::int32_t attack_actor =
                static_cast<std::int32_t>(integer_arg(
                    continuation,
                    "attack_actor",
                    1 - actor
                ));
            Value *source = pokemon(
                player(result.state, actor),
                string_arg(continuation, "from_slot", "active")
            );
            Value *target = pokemon(
                player(result.state, actor),
                string_arg(continuation, "to_slot")
            );
            if (source == nullptr || target == nullptr) {
                throw std::invalid_argument(
                    "exp_share_entity_changed"
                );
            }
            Array &energy = required(
                *source,
                "energy_card_ids"
            ).as_array();
            const std::size_t index = static_cast<std::size_t>(
                integer_arg(selection, "index", -1)
            );
            if (
                index >= energy.size()
                || energy[index].string_or()
                    != string_arg(selection, "card_id")
                || !is_basic_energy_id(
                    cards_,
                    energy[index].string_or()
                )
            ) {
                throw std::invalid_argument(
                    "exp_share_energy_selection_changed"
                );
            }
            required(
                *target,
                "energy_card_ids"
            ).as_array().push_back(std::move(energy[index]));
            energy.erase(
                energy.begin() + static_cast<std::ptrdiff_t>(index)
            );
            result.event_types.emplace_back("energy_attached");
            continue_after_exp_share_trigger(
                result,
                cards_,
                actor,
                attack_actor,
                continuation
            );
        } else if (kind == "select_prize") {
            increment(result.state, "revision");
            if (
                selected_options.is_array()
                && !selected_options.as_array().empty()
            ) {
                const std::string option = string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                );
                const std::size_t index = static_cast<std::size_t>(
                    std::stoul(option.substr(option.find(':') + 1))
                );
                Array &prizes = required(
                    player(result.state, actor),
                    "prizes"
                ).as_array();
                if (index >= prizes.size()) {
                    throw std::invalid_argument("prize_index_invalid");
                }
                const std::string prize_card_id =
                    prizes[index].string_or();
                Array targets = pokemon_options(
                    player(result.state, actor),
                    actor,
                    false,
                    true
                );
                if (
                    !targets.empty()
                    && prize_attaches_to_bench(
                        cards_,
                        prize_card_id
                    )
                ) {
                    increment(result.state, "choice_sequence");
                    result.pending = action_pending(
                        "select_prize_energy_target",
                        actor,
                        0,
                        1,
                        true,
                        std::move(targets),
                        "treasure_prize_target",
                        true
                    );
                    result.continuation = continuation;
                    result.continuation["kind"] = Value(
                        "treasure_prize_target"
                    );
                    result.continuation["actor"] = Value(actor);
                    result.continuation["prize_index"] = Value(
                        static_cast<std::int64_t>(index)
                    );
                    result.continuation["prize_card_id"] = Value(
                        prize_card_id
                    );
                    result.success = true;
                    return result;
                }
                required(
                    player(result.state, actor),
                    "hand"
                ).as_array().push_back(std::move(prizes[index]));
                prizes.erase(
                    prizes.begin() + static_cast<std::ptrdiff_t>(index)
                );
                result.event_types.emplace_back("prize_taken");
            }
            continue_after_prize_selection(
                result,
                cards_,
                continuation
            );
        } else if (kind == "treasure_prize_target") {
            increment(result.state, "revision");
            Array &prizes = required(
                player(result.state, actor),
                "prizes"
            ).as_array();
            const std::size_t index = static_cast<std::size_t>(
                integer_arg(continuation, "prize_index", -1)
            );
            const std::string expected_id = string_arg(
                continuation,
                "prize_card_id"
            );
            if (
                index >= prizes.size()
                || prizes[index].string_or() != expected_id
                || !prize_attaches_to_bench(cards_, expected_id)
            ) {
                throw std::invalid_argument(
                    "treasure_prize_entity_changed"
                );
            }
            Value prize = std::move(prizes[index]);
            prizes.erase(
                prizes.begin() + static_cast<std::ptrdiff_t>(index)
            );
            if (
                !cancelled
                && selected_options.is_array()
                && !selected_options.as_array().empty()
            ) {
                if (selected_options.as_array().size() != 1) {
                    throw std::invalid_argument(
                        "treasure_prize_target_invalid"
                    );
                }
                const Value &selection =
                    selected_options.as_array().front();
                const std::string selected_slot = string_arg(
                    selection,
                    "slot"
                );
                if (
                    integer_arg(selection, "player", -1) != actor
                    || (
                        selected_slot != "active"
                        && selected_slot.rfind("bench_", 0) != 0
                    )
                ) {
                    throw std::invalid_argument(
                        "treasure_prize_target_invalid"
                    );
                }
                Value *target = pokemon(
                    player(result.state, actor),
                    selected_slot
                );
                if (
                    target == nullptr
                    || string_arg(*target, "card_id")
                        != string_arg(selection, "card_id")
                ) {
                    throw std::invalid_argument(
                        "treasure_prize_target_changed"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(prize));
                result.event_types.emplace_back("energy_attached");
            } else {
                required(
                    player(result.state, actor),
                    "hand"
                ).as_array().push_back(std::move(prize));
            }
            result.event_types.emplace_back("prize_taken");
            continue_after_prize_selection(
                result,
                cards_,
                continuation
            );
        } else {
            throw std::invalid_argument("unsupported_game_continuation");
        }
        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    return result;
}

} // namespace ptcg::ai

#include "ptcg_rules.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <unordered_set>

namespace ptcg::ai {

namespace {

using Array = Value::Array;
using Object = Value::Object;

void append_event(
    VmExecutionResult &result,
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

const std::set<std::string> IMPLEMENTED_OPS = {
    "apply_attack_lock_basic",
    "apply_dazzling_beam",
    "apply_outgoing_damage_reduction",
    "apply_self_attack_lock",
    "apply_status",
    "attach_energy",
    "attach_energy_from_discard",
    "choose_damage_target",
    "choose_heal_damage",
    "conditional",
    "conditional_damage",
    "conditional_damage_then_heal",
    "conditional_search",
    "conditional_status",
    "deal_bench_damage",
    "deal_damage",
    "deal_damage_per_discard_psychic",
    "deal_damage_per_energy",
    "deal_damage_per_evolved",
    "deal_damage_per_hand_size",
    "deal_damage_per_self_damage",
    "deal_damage_per_self_energy",
    "deal_damage_per_self_energy_type",
    "deal_damage_plus_bench",
    "deal_damage_then_heal",
    "deal_damage_with_self_penalty",
    "discard_cards",
    "discard_energy",
    "discard_energy_then_damage",
    "discard_hand_then_damage",
    "discard_then_draw_cards",
    "discard_then_revive",
    "draw_and_attach_energy",
    "draw_cards",
    "draw_until",
    "draw_until_more_than_opponent",
    "evolve_skip_stage",
    "fail_attack",
    "flip_coin",
    "flip_coin_repeat_damage",
    "flip_coin_then_discard_energy",
    "flip_coin_then_ko",
    "flip_until_tails",
    "hand_to_bottom_draw_until",
    "hand_to_bottom_then_draw",
    "heal_all",
    "heal_damage",
    "judge",
    "look_top_attach_energy",
    "look_top_deck",
    "mill_then_damage",
    "place_counters_then_self_discard",
    "place_damage_counters",
    "prevent_all",
    "prevent_damage",
    "prevent_effects",
    "register_aura_damage_boost",
    "register_aura_damage_reduction",
    "register_conditional_hp_boost",
    "register_conditional_zero_retreat",
    "register_reactive_thorns",
    "register_tool_exp_share",
    "register_tool_modifier",
    "recover_clara",
    "relocate_energy",
    "return_to_hand",
    "search_any_and_switch",
    "search_cards",
    "search_item_and_tool",
    "set_attack_damage_formula",
    "set_attack_flags",
    "shuffle_from_discard_to_deck",
    "shuffle_then_draw_cards",
    "switch_pokemon",
    "trekking_shoes",
    "trigger_draw_cards",
    "trigger_move_basic_energy",
    "trigger_place_damage_counters",
    "trigger_switch_with_active",
    "zinnia_resolve",
};

bool coin_branch_runs_after_attack_damage(const std::string &op) {
    // Coin flips themselves (and attack-failure branches) are resolved before
    // damage. These release-card branch effects are explicitly post-damage:
    // status, recoil/payment cleanup, and protection for the next turn.
    static const std::unordered_set<std::string> post_damage_ops = {
        "apply_status",
        "discard_energy",
        "prevent_all",
    };
    return post_damage_ops.find(op) != post_damage_ops.end();
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

std::string upper_ascii(std::string value) {
    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char character) {
            return static_cast<char>(std::toupper(character));
        }
    );
    return value;
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

std::int64_t integer_arg(
    const Value &args,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *value = args.find(key);
    return value == nullptr ? fallback : value->as_integer(fallback);
}

bool bool_arg(
    const Value &args,
    const std::string &key,
    bool fallback = false
) {
    const Value *value = args.find(key);
    return value == nullptr ? fallback : value->as_bool(fallback);
}

std::string string_arg(
    const Value &args,
    const std::string &key,
    std::string fallback = {}
) {
    const Value *value = args.find(key);
    return value == nullptr
        ? std::move(fallback)
        : value->string_or(std::move(fallback));
}

Value &player(Value &state, std::int32_t index) {
    if (index != 0 && index != 1) {
        throw std::invalid_argument("invalid_actor");
    }
    Array &players = required(state, "players").as_array();
    if (players.size() != 2) {
        throw std::invalid_argument("invalid_player_count");
    }
    return players[static_cast<std::size_t>(index)];
}

const Value &player(const Value &state, std::int32_t index) {
    if (index != 0 && index != 1) {
        throw std::invalid_argument("invalid_actor");
    }
    const Array &players = required(state, "players").as_array();
    if (players.size() != 2) {
        throw std::invalid_argument("invalid_player_count");
    }
    return players[static_cast<std::size_t>(index)];
}

Value *pokemon(Value &player_value, const std::string &slot) {
    if (slot == "active") {
        Value &active = required(player_value, "active");
        return active.is_object() ? &active : nullptr;
    }
    constexpr std::string_view prefix = "bench_";
    if (slot.rfind(prefix.data(), 0) != 0) {
        return nullptr;
    }
    const std::string suffix = slot.substr(prefix.size());
    if (
        suffix.empty()
        || !std::all_of(suffix.begin(), suffix.end(), [](unsigned char value) {
            return std::isdigit(value) != 0;
        })
    ) {
        return nullptr;
    }
    const std::size_t index = static_cast<std::size_t>(std::stoul(suffix));
    Array &bench = required(player_value, "bench").as_array();
    if (index >= bench.size() || !bench[index].is_object()) {
        return nullptr;
    }
    return &bench[index];
}

const Value *pokemon(const Value &player_value, const std::string &slot) {
    return pokemon(const_cast<Value &>(player_value), slot);
}

std::vector<Value *> all_pokemon(Value &player_value) {
    std::vector<Value *> result;
    if (Value *active = pokemon(player_value, "active")) {
        result.push_back(active);
    }
    Array &bench = required(player_value, "bench").as_array();
    for (Value &entry : bench) {
        if (entry.is_object()) {
            result.push_back(&entry);
        }
    }
    return result;
}

std::vector<const Value *> all_pokemon(const Value &player_value) {
    std::vector<const Value *> result;
    if (const Value *active = pokemon(player_value, "active")) {
        result.push_back(active);
    }
    const Array &bench = required(player_value, "bench").as_array();
    for (const Value &entry : bench) {
        if (entry.is_object()) {
            result.push_back(&entry);
        }
    }
    return result;
}

std::string card_id(const Value &pokemon_value) {
    const Value *value = pokemon_value.find("card_id");
    return value == nullptr ? std::string{} : value->string_or();
}

const Value *card_definition(const Value &cards, const std::string &id) {
    return cards.find(id);
}

bool string_array_contains_ci(const Value *array, const std::string &needle) {
    if (array == nullptr || !array->is_array()) {
        return false;
    }
    const std::string lowered = lower_ascii(needle);
    for (const Value &entry : array->as_array()) {
        if (
            entry.is_string()
            && lower_ascii(entry.as_string()) == lowered
        ) {
            return true;
        }
    }
    return false;
}

bool card_has_subtype(
    const Value &cards,
    const std::string &id,
    const std::string &subtype
) {
    const Value *definition = card_definition(cards, id);
    return definition != nullptr
        && string_array_contains_ci(definition->find("subtypes"), subtype);
}

std::int64_t pokemon_hp(
    const Value &cards,
    const Value &pokemon_value
) {
    const std::string id = card_id(pokemon_value);
    const Value *definition = card_definition(cards, id);
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
            && !card_has_subtype(cards, id, "Basic")
        ) {
            continue;
        }
        result += integer_arg(*operation, "amount");
    }
    return std::max<std::int64_t>(0, result);
}

bool card_is_pokemon(const Value &cards, const std::string &id) {
    const Value *definition = card_definition(cards, id);
    if (definition == nullptr) {
        return false;
    }
    const std::string supertype = lower_ascii(
        string_arg(*definition, "supertype")
    );
    return integer_arg(*definition, "hp") > 0
        && supertype != "energy"
        && supertype != "trainer";
}

bool card_is_energy(const Value &cards, const std::string &id) {
    const Value *definition = card_definition(cards, id);
    const Value *supertype = definition == nullptr
        ? nullptr
        : definition->find("supertype");
    return supertype != nullptr
        && lower_ascii(supertype->string_or()) == "energy";
}

bool card_matches_energy(
    const Value &cards,
    const std::string &id,
    const std::string &energy_type
) {
    const Value *definition = card_definition(cards, id);
    if (definition == nullptr) {
        return false;
    }
    std::string normalized = lower_ascii(energy_type);
    bool basic_only = false;
    if (
        normalized.rfind("basic_", 0) == 0
        && normalized != "basic_energy"
    ) {
        basic_only = true;
        normalized = normalized.substr(6);
    }
    if (normalized == "any" || normalized == "energy") {
        return card_is_energy(cards, id);
    }
    if (
        normalized == "basic"
        || normalized == "basic_energy"
    ) {
        return card_is_energy(cards, id)
            && card_has_subtype(cards, id, "Basic");
    }
    return card_is_energy(cards, id)
        && (!basic_only || card_has_subtype(cards, id, "Basic"))
        && (
            string_array_contains_ci(
                definition->find("provides_energy"),
                normalized
            ) || string_array_contains_ci(
                definition->find("energy_types"),
                normalized
            )
        );
}

std::int64_t energy_units(
    const Value &cards,
    const Value *pokemon_value,
    const std::string &filter = "any"
) {
    if (pokemon_value == nullptr) {
        return 0;
    }
    const Value *energy = pokemon_value->find("energy_card_ids");
    if (energy == nullptr || !energy->is_array()) {
        return 0;
    }
    const std::string normalized_filter = lower_ascii(filter);
    std::int64_t count = 0;
    for (
        std::size_t card_index = 0;
        card_index < energy->as_array().size();
        ++card_index
    ) {
        const Value &entry = energy->as_array()[card_index];
        const std::string id = entry.string_or();
        const Value *definition = card_definition(cards, id);
        if (definition == nullptr || !card_is_energy(cards, id)) {
            continue;
        }
        bool downgrades_with_other_special = false;
        const Value *effects = definition->find("energy_effects");
        if (effects != nullptr && effects->is_array()) {
            downgrades_with_other_special = std::any_of(
                effects->as_array().begin(),
                effects->as_array().end(),
                [](const Value &effect) {
                    return effect.is_object()
                        && string_arg(effect, "kind") == "provide_energy"
                        && bool_arg(
                            effect,
                            "downgrade_if_other_special"
                        );
                }
            );
        }
        bool has_other_special = false;
        if (downgrades_with_other_special) {
            for (
                std::size_t other_index = 0;
                other_index < energy->as_array().size();
                ++other_index
            ) {
                if (
                    other_index != card_index
                    && card_has_subtype(
                        cards,
                        energy->as_array()[other_index].string_or(),
                        "Special"
                    )
                ) {
                    has_other_special = true;
                    break;
                }
            }
        }
        const bool downgrade_wildcard =
            downgrades_with_other_special && has_other_special;
        const Value *provides = definition->find("provides_energy");
        if (
            provides == nullptr
            || !provides->is_array()
            || provides->as_array().empty()
        ) {
            if (
                normalized_filter == "any"
                || normalized_filter == "energy"
                || (
                    (
                        normalized_filter == "basic"
                        || normalized_filter == "basic_energy"
                    )
                    && card_has_subtype(cards, id, "Basic")
                )
                || string_array_contains_ci(
                    definition->find("energy_types"),
                    normalized_filter
                )
            ) {
                ++count;
            }
            continue;
        }
        for (const Value &provider : provides->as_array()) {
            std::string provided_type = lower_ascii(provider.string_or());
            if (downgrade_wildcard && provided_type == "rainbow") {
                provided_type = "colorless";
            }
            if (
                normalized_filter == "any"
                || normalized_filter == "energy"
                || (
                    (
                        normalized_filter == "basic"
                        || normalized_filter == "basic_energy"
                    )
                    && card_has_subtype(cards, id, "Basic")
                )
                || provided_type == normalized_filter
                || provided_type == "rainbow"
            ) {
                ++count;
            }
        }
    }
    return count;
}

void append_string(Value &array_value, const std::string &value) {
    array_value.as_array().emplace_back(value);
}

std::vector<std::string> draw_cards(Value &player_value, std::int64_t count) {
    Array &deck = required(player_value, "deck").as_array();
    Array &hand = required(player_value, "hand").as_array();
    std::vector<std::string> drawn;
    while (count-- > 0 && !deck.empty()) {
        const std::string id = deck.back().string_or();
        hand.push_back(std::move(deck.back()));
        deck.pop_back();
        drawn.push_back(id);
    }
    return drawn;
}

bool attached_energy_card_matches(
    const Value &cards,
    const Value &pokemon_value,
    std::size_t card_index,
    const std::string &energy_type
) {
    const Value *attached = pokemon_value.find("energy_card_ids");
    if (
        attached == nullptr
        || !attached->is_array()
        || card_index >= attached->as_array().size()
    ) {
        return false;
    }
    const std::string id = attached->as_array()[card_index].string_or();
    const Value *definition = card_definition(cards, id);
    if (definition == nullptr || !card_is_energy(cards, id)) {
        return false;
    }
    std::string normalized = lower_ascii(energy_type);
    bool basic_only = false;
    if (
        normalized.rfind("basic_", 0) == 0
        && normalized != "basic_energy"
    ) {
        basic_only = true;
        normalized = normalized.substr(6);
    }
    if (
        normalized == "basic"
        || normalized == "basic_energy"
        || basic_only
    ) {
        if (!card_has_subtype(cards, id, "Basic")) {
            return false;
        }
        if (normalized == "basic" || normalized == "basic_energy") {
            return true;
        }
    }
    if (normalized == "any" || normalized == "energy") {
        return true;
    }

    bool downgrade_wildcard = false;
    const Value *effects = definition->find("energy_effects");
    if (effects != nullptr && effects->is_array()) {
        downgrade_wildcard = std::any_of(
            effects->as_array().begin(),
            effects->as_array().end(),
            [](const Value &effect) {
                return effect.is_object()
                    && string_arg(effect, "kind") == "provide_energy"
                    && bool_arg(effect, "downgrade_if_other_special");
            }
        );
    }
    if (downgrade_wildcard) {
        downgrade_wildcard = false;
        for (
            std::size_t other_index = 0;
            other_index < attached->as_array().size();
            ++other_index
        ) {
            if (
                other_index != card_index
                && card_has_subtype(
                    cards,
                    attached->as_array()[other_index].string_or(),
                    "Special"
                )
            ) {
                downgrade_wildcard = true;
                break;
            }
        }
    }
    const Value *provides = definition->find("provides_energy");
    if (provides != nullptr && provides->is_array()) {
        for (const Value &provider : provides->as_array()) {
            std::string provided_type = lower_ascii(provider.string_or());
            if (downgrade_wildcard && provided_type == "rainbow") {
                provided_type = "colorless";
            }
            if (
                provided_type == normalized
                || (provided_type == "rainbow" && !downgrade_wildcard)
            ) {
                return true;
            }
        }
    }
    return string_array_contains_ci(
        definition->find("energy_types"),
        normalized
    );
}

Array card_id_values(const std::vector<std::string> &card_ids) {
    Array values;
    values.reserve(card_ids.size());
    for (const std::string &card_id : card_ids) {
        values.emplace_back(card_id);
    }
    return values;
}

Array card_id_values(const std::vector<Value> &cards) {
    Array values;
    values.reserve(cards.size());
    for (const Value &card : cards) {
        const std::string card_id = card.string_or();
        if (!card_id.empty()) {
            values.emplace_back(card_id);
        }
    }
    return values;
}

Array selected_card_id_values(const Value &selected_options) {
    Array values;
    if (!selected_options.is_array()) {
        return values;
    }
    values.reserve(selected_options.as_array().size());
    for (const Value &option : selected_options.as_array()) {
        const std::string card_id = string_arg(option, "card_id");
        if (!card_id.empty()) {
            values.emplace_back(card_id);
        }
    }
    return values;
}

void append_card_zone_event(
    VmExecutionResult &result,
    const std::string &event_type,
    std::int32_t owner,
    Array card_ids,
    const std::string &source_zone,
    const std::string &target_zone,
    const std::string &visibility
) {
    if (card_ids.empty()) {
        return;
    }
    const std::int64_t count = static_cast<std::int64_t>(
        card_ids.size());
    result.event_types.emplace_back(event_type);
    append_event(result, event_type, Object{
        {"player", Value(owner)},
        {"card_ids", Value(std::move(card_ids))},
        {"count", Value(count)},
        {"source_zone", Value(source_zone)},
        {"target_zone", Value(target_zone)},
        {"visibility", Value(visibility)},
    });
}

void append_cards_drawn_event(
    VmExecutionResult &result,
    std::int32_t owner,
    const std::vector<std::string> &drawn,
    const std::string &purpose = "effect"
) {
    if (drawn.empty()) {
        return;
    }
    result.event_types.emplace_back("cards_drawn");
    append_event(result, "cards_drawn", Object{
        {"player", Value(owner)},
        {"card_ids", Value(card_id_values(drawn))},
        {"count", Value(static_cast<std::int64_t>(drawn.size()))},
        {"source_zone", Value("deck")},
        {"target_zone", Value("hand")},
        {"purpose", Value(purpose)},
        {"visibility", Value("owner")},
    });
}

void append_damage_feedback_event(
    VmExecutionResult &result,
    const std::string &event_type,
    std::int32_t actor,
    std::int32_t target_player,
    const std::string &target_slot,
    std::int64_t amount
) {
    if (amount <= 0) {
        return;
    }
    result.event_types.emplace_back(event_type);
    append_event(result, event_type, Object{
        {"actor", Value(actor)},
        {"player", Value(target_player)},
        {"target_player", Value(target_player)},
        {"target_slot", Value(target_slot)},
        {"slot", Value(target_slot)},
        {"amount", Value(amount)},
        {"counter_count", Value((amount + 9) / 10)},
        {
            "damage_kind",
            Value(event_type == "damage_counters_placed"
                ? "damage_counters" : "damage"),
        },
        {"visibility", Value("public")},
    });
}

void append_healed_event(
    VmExecutionResult &result,
    std::int32_t actor,
    std::int32_t target_player,
    const std::string &target_slot,
    std::int64_t healed_counters
) {
    append_damage_feedback_event(
        result,
        "healed",
        actor,
        target_player,
        target_slot,
        healed_counters * 10
    );
}

void append_status_event(
    VmExecutionResult &result,
    const std::string &event_type,
    std::int32_t actor,
    std::int32_t target_player,
    const std::string &target_slot,
    const std::string &status
) {
    if (status.empty()) {
        return;
    }
    result.event_types.emplace_back(event_type);
    append_event(result, event_type, Object{
        {"actor", Value(actor)},
        {"player", Value(target_player)},
        {"target_player", Value(target_player)},
        {"target_slot", Value(target_slot)},
        {"slot", Value(target_slot)},
        {"status", Value(status)},
        {"visibility", Value("public")},
    });
}

bool prevents_attack_effects(const Value &target) {
    if (bool_arg(target, "all_prevented")) {
        return true;
    }
    const Value *modifiers = target.find("modifiers");
    return modifiers != nullptr
        && modifiers->is_array()
        && std::any_of(
            modifiers->as_array().begin(),
            modifiers->as_array().end(),
            [](const Value &descriptor) {
                const Value *operation = descriptor.find("operation");
                return descriptor.is_object()
                    && string_arg(descriptor, "hook") == "PREVENT_EFFECTS"
                    && operation != nullptr
                    && operation->is_object()
                    && string_arg(*operation, "kind") == "prevent_effects";
            }
        );
}

void shuffle_array(Array &values, XorShift32 &rng) {
    for (std::size_t index = values.size(); index > 1; --index) {
        const std::size_t selected = rng.next_u32() % index;
        std::swap(values[index - 1], values[selected]);
    }
}

Value new_pokemon(const Value &cards, const std::string &id) {
    Object result;
    result["card_id"] = Value(id);
    result["damage_counters"] = Value(0);
    result["energy_card_ids"] = Value::make_array();
    result["attached_tool_id"] = Value("");
    result["status_conditions"] = Value::make_array();
    result["evolution_stack_ids"] = Value::make_array();
    result["can_evolve_this_turn"] = Value(true);
    result["placed_this_turn"] = Value(true);
    result["damage_prevented"] = Value(false);
    result["all_prevented"] = Value(false);
    result["outgoing_damage_reduction"] = Value(0);
    Array used_abilities;
    const Value *definition = card_definition(cards, id);
    const Value *abilities = definition == nullptr
        ? nullptr
        : definition->find("abilities");
    if (abilities != nullptr && abilities->is_array()) {
        for (const Value &ability : abilities->as_array()) {
            bool marks_used = string_arg(
                ability,
                "trigger"
            ) == "on_enter_play";
            const Value *effects = ability.find("compiled_effects");
            if (effects != nullptr && effects->is_array()) {
                for (const Value &effect : effects->as_array()) {
                    if (
                        string_arg(effect, "op")
                        == "discard_then_revive"
                    ) {
                        marks_used = true;
                    }
                }
            }
            if (marks_used) {
                used_abilities.emplace_back(
                    string_arg(ability, "name")
                );
            }
        }
    }
    result["used_abilities"] = Value(std::move(used_abilities));
    result["healed_this_turn"] = Value(false);
    result["paralyzed_since_turn"] = Value(0);
    return Value(std::move(result));
}

void set_integer(Value &object, const std::string &key, std::int64_t value) {
    object[key] = Value(value);
}

std::int64_t get_integer(
    const Value &object,
    const std::string &key,
    std::int64_t fallback = 0
) {
    const Value *value = object.find(key);
    return value == nullptr ? fallback : value->as_integer(fallback);
}

void add_damage(Value &pokemon_value, std::int64_t damage) {
    const std::int64_t counters = std::max<std::int64_t>(0, damage) / 10;
    set_integer(
        pokemon_value,
        "damage_counters",
        get_integer(pokemon_value, "damage_counters") + counters
    );
}

std::int64_t heal_damage(Value &pokemon_value, std::int64_t amount) {
    const std::int64_t current = get_integer(
        pokemon_value,
        "damage_counters"
    );
    const std::int64_t healed = std::min(
        current,
        std::max<std::int64_t>(0, amount) / 10
    );
    set_integer(pokemon_value, "damage_counters", current - healed);
    if (healed > 0) {
        pokemon_value["healed_this_turn"] = Value(true);
    }
    return healed;
}

bool condition_applies(
    const Value &cards,
    const Value &state,
    std::int32_t actor,
    const std::string &condition
) {
    const Value &self = player(state, actor);
    const Value &opponent = player(state, 1 - actor);
    const Value *opponent_active = pokemon(opponent, "active");
    if (condition == "own_bench_damaged") {
        const Array &bench = required(self, "bench").as_array();
        return std::any_of(
            bench.begin(),
            bench.end(),
            [](const Value &entry) {
                return entry.is_object()
                    && get_integer(entry, "damage_counters") > 0;
            }
        );
    }
    if (condition == "opponent_active_damaged") {
        return opponent_active != nullptr
            && get_integer(*opponent_active, "damage_counters") > 0;
    }
    if (condition == "opponent_active_evolved") {
        return opponent_active != nullptr
            && !card_has_subtype(
                cards,
                card_id(*opponent_active),
                "Basic"
            );
    }
    if (condition == "own_hand_empty") {
        return required(self, "hand").as_array().empty();
    }
    if (condition == "field_energy_ge_5") {
        std::int64_t total = 0;
        for (const Value *entry : all_pokemon(self)) {
            total += energy_units(cards, entry);
        }
        return total >= 5;
    }
    if (
        condition == "ko_by_attack_last_turn"
        || condition == "ko_by_attack_damage_last_turn"
    ) {
        const Value *fact_book = state.find("turn_fact_book");
        const Value *previous = fact_book != nullptr
            && fact_book->is_object()
            ? fact_book->find("previous_turn")
            : nullptr;
        const Value *knockouts = previous != nullptr
            && previous->is_object()
            ? previous->find("knockouts")
            : nullptr;
        if (
            knockouts != nullptr
            && knockouts->is_array()
            && !knockouts->as_array().empty()
        ) {
            return std::any_of(
                knockouts->as_array().begin(),
                knockouts->as_array().end(),
                [actor](const Value &fact) {
                    return integer_arg(fact, "defeated_player", -1) == actor
                        && string_arg(fact, "source_kind")
                            == "attack_damage";
                }
            );
        }
        const Value *flag = self.find("was_ko_by_attack");
        return flag != nullptr && flag->as_bool();
    }
    if (condition == "ko_last_opponent_turn") {
        const Value *fact_book = state.find("turn_fact_book");
        const Value *previous = fact_book != nullptr
            && fact_book->is_object()
            ? fact_book->find("previous_turn")
            : nullptr;
        const Value *knockouts = previous != nullptr
            && previous->is_object()
            ? previous->find("knockouts")
            : nullptr;
        if (
            knockouts != nullptr
            && knockouts->is_array()
            && !knockouts->as_array().empty()
        ) {
            return std::any_of(
                knockouts->as_array().begin(),
                knockouts->as_array().end(),
                [actor](const Value &fact) {
                    return integer_arg(fact, "defeated_player", -1) == actor
                        && integer_arg(fact, "source_player", -1) >= 0;
                }
            );
        }
        const Value *flag = self.find("was_ko_by_attack");
        return flag != nullptr && flag->as_bool();
    }
    return false;
}

std::int64_t bench_count(const Value &player_value);

std::int64_t evaluate_formula_ast(
    const Value &formula,
    const Value &cards,
    const Value &state,
    std::int32_t actor
) {
    if (!formula.is_object()) {
        return formula.as_integer();
    }
    const std::string op = string_arg(formula, "op");
    if (op == "const") {
        return integer_arg(formula, "value");
    }
    if (op == "damage_counters") {
        const std::int32_t owner = string_arg(
            formula,
            "target",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        const Value *target = pokemon(player(state, owner), "active");
        return target == nullptr
            ? 0
            : integer_arg(*target, "damage_counters");
    }
    if (op == "bench_count") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        return bench_count(player(state, owner));
    }
    if (op == "hand_size") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        return static_cast<std::int64_t>(
            required(player(state, owner), "hand").as_array().size()
        );
    }
    if (op == "discard_count") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        const Value *filter = formula.find("filter");
        const std::string card_type = (
            filter != nullptr && filter->is_object()
        ) ? lower_ascii(string_arg(*filter, "card_type"))
          : std::string{};
        const std::string energy_type = (
            filter != nullptr && filter->is_object()
        ) ? string_arg(*filter, "energy_type")
          : std::string{};
        std::int64_t total = 0;
        for (
            const Value &entry
            : required(player(state, owner), "discard").as_array()
        ) {
            const Value *definition = card_definition(
                cards,
                entry.string_or()
            );
            if (definition == nullptr) {
                continue;
            }
            const std::string supertype = lower_ascii(
                string_arg(*definition, "supertype")
            );
            if (
                card_type == "pokemon"
                && supertype != "pokémon"
                && supertype != "pokemon"
            ) {
                continue;
            }
            if (card_type == "energy" && supertype != "energy") {
                continue;
            }
            if (
                !energy_type.empty()
                && !string_array_contains_ci(
                    definition->find("energy_types"),
                    energy_type
                )
            ) {
                continue;
            }
            ++total;
        }
        return total;
    }
    if (op == "energy_count") {
        const std::string scope = string_arg(
            formula,
            "scope",
            string_arg(formula, "target", "self")
        );
        const std::string filter = string_arg(
            formula,
            "energy_type",
            string_arg(formula, "filter", "any")
        );
        const Value &self = player(state, actor);
        const Value &opponent = player(state, 1 - actor);
        if (
            scope == "self"
            || scope == "self_active"
            || scope == "source"
        ) {
            return energy_units(cards, pokemon(self, "active"), filter);
        }
        if (scope == "opponent" || scope == "opponent_active") {
            return energy_units(
                cards,
                pokemon(opponent, "active"),
                filter
            );
        }
        const Value &owner = (
            scope == "all_opponent" || scope == "opponent_all"
        ) ? opponent : self;
        if (
            scope != "all_self"
            && scope != "self_all"
            && scope != "all_opponent"
            && scope != "opponent_all"
        ) {
            throw std::invalid_argument(
                "unsupported_formula_energy_scope:" + scope
            );
        }
        std::int64_t total = energy_units(
            cards,
            pokemon(owner, "active"),
            filter
        );
        const Array &bench = required(owner, "bench").as_array();
        for (const Value &entry : bench) {
            total += energy_units(
                cards,
                entry.is_object() ? &entry : nullptr,
                filter
            );
        }
        return total;
    }
    if (op == "evolved_count") {
        const std::int32_t owner = string_arg(
            formula,
            "player",
            "self"
        ) == "opponent" ? 1 - actor : actor;
        const Value &owner_state = player(state, owner);
        std::int64_t total = 0;
        const Value *active = pokemon(owner_state, "active");
        if (
            active != nullptr
            && !card_has_subtype(cards, card_id(*active), "Basic")
        ) {
            ++total;
        }
        const Array &bench = required(owner_state, "bench").as_array();
        for (const Value &entry : bench) {
            if (
                entry.is_object()
                && !card_has_subtype(cards, card_id(entry), "Basic")
            ) {
                ++total;
            }
        }
        return total;
    }
    if (const Value *constant = formula.find("const")) {
        return constant->as_integer();
    }
    if (op == "sub") {
        const Value *left = formula.find("lhs");
        if (left == nullptr) {
            left = formula.find("left");
        }
        const Value *right = formula.find("rhs");
        if (right == nullptr) {
            right = formula.find("right");
        }
        if (left == nullptr || right == nullptr) {
            throw std::invalid_argument(
                "formula_ast_binary_operands_missing"
            );
        }
        return evaluate_formula_ast(*left, cards, state, actor)
            - evaluate_formula_ast(*right, cards, state, actor);
    }
    if (op == "add") {
        std::int64_t result = 0;
        const Value *terms = formula.find("terms");
        if (terms != nullptr && terms->is_array()) {
            for (const Value &term : terms->as_array()) {
                result += evaluate_formula_ast(
                    term,
                    cards,
                    state,
                    actor
                );
            }
        }
        return result;
    }
    if (op == "mul" || op == "multiply") {
        const Value *terms = formula.find("terms");
        if (terms == nullptr) {
            terms = formula.find("factors");
        }
        std::int64_t result = 1;
        if (terms != nullptr && terms->is_array()) {
            for (const Value &term : terms->as_array()) {
                result *= evaluate_formula_ast(
                    term,
                    cards,
                    state,
                    actor
                );
            }
        }
        return result;
    }
    if (op == "if") {
        const bool applies = condition_applies(
            cards,
            state,
            actor,
            string_arg(formula, "condition")
        );
        const Value *branch = formula.find(applies ? "then" : "else");
        return branch == nullptr
            ? 0
            : evaluate_formula_ast(*branch, cards, state, actor);
    }
    throw std::invalid_argument("unsupported_formula_ast:" + op);
}

void append_modifier(
    Value &pokemon_value,
    const std::string &op,
    const Value &args
) {
    Value *modifiers = pokemon_value.find("modifiers");
    if (modifiers == nullptr || !modifiers->is_array()) {
        pokemon_value["modifiers"] = Value::make_array();
        modifiers = pokemon_value.find("modifiers");
    }
    Object descriptor;
    descriptor["native_op"] = Value(op);
    descriptor["args"] = args;
    modifiers->as_array().emplace_back(std::move(descriptor));
}

Value modifier_probe(
    const std::string &op,
    const Value &args,
    const Value *source,
    std::int32_t actor,
    const std::string &source_slot
) {
    if (
        op == "register_reactive_thorns"
        || op == "register_tool_exp_share"
    ) {
        return Value(Object{{"registered", Value(false)}});
    }
    static const std::map<std::string, std::string, std::less<>> kinds = {
        {"register_aura_damage_boost", "aura_damage_boost"},
        {"register_aura_damage_reduction", "aura_damage_reduction"},
        {"register_conditional_hp_boost", "conditional_hp_boost"},
        {"register_conditional_zero_retreat", "conditional_zero_retreat"},
        {"register_tool_modifier", "tool"},
    };
    const auto found = kinds.find(op);
    if (found == kinds.end()) {
        return Value::make_object();
    }
    if (source == nullptr) {
        return Value(Object{{"registered", Value(false)}});
    }
    Object result;
    result["registered"] = Value(true);
    result["modifier_kind"] = Value(found->second);
    result["player"] = Value(actor);
    result["slot"] = Value(source_slot);
    result["card_id"] = Value(card_id(*source));
    result["params"] = args;
    return Value(std::move(result));
}

std::int64_t bench_count(const Value &player_value) {
    const Array &bench = required(player_value, "bench").as_array();
    return static_cast<std::int64_t>(std::count_if(
        bench.begin(),
        bench.end(),
        [](const Value &entry) { return entry.is_object(); }
    ));
}

void set_attack_damage(Value &context, std::int64_t damage, bool add) {
    const std::int64_t previous = get_integer(context, "base_damage");
    set_integer(context, "base_damage", add ? previous + damage : damage);
}

void return_pokemon_to_hand(Value &player_value, const std::string &slot) {
    Value *target = pokemon(player_value, slot);
    if (target == nullptr) {
        return;
    }
    Array &hand = required(player_value, "hand").as_array();
    const Value *stack = target->find("evolution_stack_ids");
    if (stack != nullptr && stack->is_array()) {
        for (const Value &entry : stack->as_array()) {
            hand.push_back(entry);
        }
    }
    hand.emplace_back(card_id(*target));
    const Value *energy = target->find("energy_card_ids");
    if (energy != nullptr && energy->is_array()) {
        for (const Value &entry : energy->as_array()) {
            hand.push_back(entry);
        }
    }
    const std::string tool = string_arg(*target, "attached_tool_id");
    if (!tool.empty()) {
        hand.emplace_back(tool);
    }
    if (slot == "active") {
        player_value["active"] = Value();
        return;
    }
    const std::size_t index = static_cast<std::size_t>(
        std::stoul(slot.substr(std::string("bench_").size()))
    );
    required(player_value, "bench").as_array().at(index) = Value();
}

Value pokemon_option(
    const Value &pokemon_value,
    std::int32_t owner,
    const std::string &slot
) {
    Object option;
    option["kind"] = Value("pokemon");
    option["player"] = Value(owner);
    option["card_id"] = Value(card_id(pokemon_value));
    option["slot"] = Value(slot);
    return Value(std::move(option));
}

Value card_option(
    const std::string &id,
    std::int32_t owner,
    const std::string &zone,
    std::int64_t index
) {
    Object option;
    option["kind"] = Value("card");
    option["player"] = Value(owner);
    option["card_id"] = Value(id);
    option["zone"] = Value(zone);
    option["index"] = Value(index);
    return Value(std::move(option));
}

Value attachment_option(
    const std::string &id,
    std::int32_t owner,
    const std::string &slot,
    std::int64_t index
) {
    Object option;
    option["kind"] = Value("attachment");
    option["player"] = Value(owner);
    option["card_id"] = Value(id);
    option["slot"] = Value(slot);
    option["attachment_type"] = Value("energy");
    option["index"] = Value(index);
    return Value(std::move(option));
}

Value id_option(const std::string &id) {
    Object option;
    option["kind"] = Value("id");
    option["option_id"] = Value(id);
    return Value(std::move(option));
}

void decorate_energy_distribution_option(
    Value &option,
    std::int32_t actor,
    std::int64_t energy_index,
    const std::string &energy_card_id
) {
    option["option_id"] = Value(
        "energy:"
        + std::to_string(energy_index)
        + ":"
        + energy_card_id
        + "->pokemon:"
        + std::to_string(actor)
        + ":"
        + string_arg(option, "slot")
        + ":"
        + string_arg(option, "card_id")
    );
}

std::int64_t energy_option_index(const Value &option) {
    const Value *explicit_index = option.find("energy_index");
    if (explicit_index != nullptr) {
        return explicit_index->as_integer(-1);
    }
    const std::string option_id = string_arg(option, "option_id");
    constexpr const char *prefix = "energy:";
    if (option_id.rfind(prefix, 0) != 0) {
        return -1;
    }
    const std::size_t start = std::char_traits<char>::length(prefix);
    const std::size_t end = option_id.find(':', start);
    if (end == std::string::npos) {
        return -1;
    }
    try {
        return std::stoll(option_id.substr(start, end - start));
    } catch (const std::exception &) {
        return -1;
    }
}

std::string energy_option_card_id(const Value &option) {
    const std::string explicit_id = string_arg(
        option,
        "energy_card_id"
    );
    if (!explicit_id.empty()) {
        return explicit_id;
    }
    const std::string option_id = string_arg(option, "option_id");
    constexpr const char *prefix = "energy:";
    if (option_id.rfind(prefix, 0) != 0) {
        return {};
    }
    const std::size_t index_end = option_id.find(
        ':',
        std::char_traits<char>::length(prefix)
    );
    if (index_end == std::string::npos) {
        return {};
    }
    const std::size_t id_end = option_id.find("->", index_end + 1);
    if (id_end == std::string::npos) {
        return {};
    }
    return option_id.substr(
        index_end + 1,
        id_end - index_end - 1
    );
}

void validate_energy_distribution_selection(
    const Array &selected_options,
    bool same_target,
    std::int64_t max_per_target
) {
    std::unordered_set<std::int64_t> selected_energy_indices;
    std::map<std::string, std::int64_t, std::less<>> selected_by_target;
    std::string first_target;
    for (const Value &selected : selected_options) {
        const std::int64_t energy_index = energy_option_index(selected);
        const std::string target_slot = string_arg(selected, "slot");
        if (
            energy_index < 0
            || target_slot.empty()
            || !selected_energy_indices.insert(energy_index).second
        ) {
            throw std::invalid_argument(
                "energy_distribution_selection_invalid"
            );
        }
        if (first_target.empty()) {
            first_target = target_slot;
        } else if (same_target && target_slot != first_target) {
            throw std::invalid_argument(
                "energy_distribution_target_mismatch"
            );
        }
        const std::int64_t target_count = ++selected_by_target[target_slot];
        if (target_count > max_per_target) {
            throw std::invalid_argument(
                "energy_distribution_target_capacity_exceeded"
            );
        }
    }
}

Array pokemon_options(
    Value &player_value,
    std::int32_t owner,
    bool include_active,
    bool include_bench
) {
    Array options;
    if (include_active) {
        if (Value *active = pokemon(player_value, "active")) {
            options.push_back(pokemon_option(
                *active,
                owner,
                "active"
            ));
        }
    }
    if (include_bench) {
        Array &bench = required(player_value, "bench").as_array();
        for (std::size_t index = 0; index < bench.size(); ++index) {
            if (!bench[index].is_object()) {
                continue;
            }
            options.push_back(pokemon_option(
                bench[index],
                owner,
                "bench_" + std::to_string(index)
            ));
        }
    }
    return options;
}

Array rare_candy_options(
    const Value &cards,
    Value &player_value,
    std::int32_t actor
) {
    Array options;
    const Array &hand = required(player_value, "hand").as_array();
    Array board = pokemon_options(player_value, actor, true, true);
    for (std::size_t hand_index = 0; hand_index < hand.size(); ++hand_index) {
        const std::string evolution_id = hand[hand_index].string_or();
        if (!card_has_subtype(cards, evolution_id, "Stage 2")) {
            continue;
        }
        const Value *stage_two = card_definition(cards, evolution_id);
        const std::string stage_one_name = stage_two == nullptr
            ? std::string{}
            : string_arg(*stage_two, "evolves_from");
        std::string basic_name;
        for (const auto &[candidate_id, candidate] : cards.as_object()) {
            (void)candidate_id;
            if (
                candidate.is_object()
                && string_arg(candidate, "name") == stage_one_name
            ) {
                basic_name = string_arg(candidate, "evolves_from");
                if (!basic_name.empty()) {
                    break;
                }
            }
        }
        if (basic_name.empty()) {
            continue;
        }
        for (const Value &target_option : board) {
            Value *target = pokemon(
                player_value,
                string_arg(target_option, "slot")
            );
            const Value *target_definition = target == nullptr
                ? nullptr
                : card_definition(cards, card_id(*target));
            if (
                target == nullptr
                || target_definition == nullptr
                || bool_arg(*target, "placed_this_turn")
                || !bool_arg(*target, "can_evolve_this_turn", true)
                || string_arg(*target_definition, "name") != basic_name
            ) {
                continue;
            }
            Value option = card_option(
                evolution_id,
                actor,
                "hand",
                static_cast<std::int64_t>(hand_index)
            );
            option["option_id"] = Value(
                "rare_candy:"
                + string_arg(target_option, "slot")
                + ":"
                + std::to_string(hand_index)
                + ":"
                + evolution_id
            );
            options.push_back(std::move(option));
        }
    }
    return options;
}

bool card_matches_filter(
    const Value &cards,
    const std::string &id,
    const std::string &filter
) {
    const std::string normalized = lower_ascii(filter);
    const Value *definition = card_definition(cards, id);
    if (normalized.empty() || normalized == "any") {
        return true;
    }
    if (normalized == "pokemon") {
        return card_is_pokemon(cards, id);
    }
    if (normalized == "basic_pokemon") {
        return card_is_pokemon(cards, id)
            && card_has_subtype(cards, id, "Basic");
    }
    if (normalized == "stage2") {
        return card_is_pokemon(cards, id)
            && card_has_subtype(cards, id, "Stage 2");
    }
    if (normalized == "grass_pokemon") {
        return card_is_pokemon(cards, id)
            && definition != nullptr
            && string_array_contains_ci(
                definition->find("energy_types"),
                "Grass"
            );
    }
    if (normalized == "water_pokemon_and_energy") {
        return card_matches_energy(cards, id, "water")
            || (
                card_is_pokemon(cards, id)
                && definition != nullptr
                && string_array_contains_ci(
                    definition->find("energy_types"),
                    "Water"
                )
            );
    }
    if (normalized == "pokemon_and_energy") {
        return card_is_pokemon(cards, id)
            || (
                card_is_energy(cards, id)
                && card_has_subtype(cards, id, "Basic")
            );
    }
    constexpr std::string_view energy_suffix = "_energy";
    if (
        normalized.size() > energy_suffix.size()
        && normalized.compare(
            normalized.size() - energy_suffix.size(),
            energy_suffix.size(),
            energy_suffix
        ) == 0
    ) {
        return card_has_subtype(cards, id, "Basic")
            && card_matches_energy(
                cards,
                id,
                normalized.substr(
                    0,
                    normalized.size() - energy_suffix.size()
                )
            );
    }
    if (normalized == "basic_energy") {
        return card_matches_energy(cards, id, "basic");
    }
    if (normalized == "energy") {
        return card_is_energy(cards, id);
    }
    if (definition == nullptr) {
        return false;
    }
    const std::string trainer_type = lower_ascii(
        string_arg(*definition, "trainer_type")
    );
    if (normalized == "item") {
        return trainer_type == "item";
    }
    if (normalized == "tool") {
        return trainer_type == "tool";
    }
    if (normalized == "item_or_tool") {
        return trainer_type == "item" || trainer_type == "tool";
    }
    if (normalized == "supporter") {
        return trainer_type == "supporter";
    }
    return card_matches_energy(cards, id, normalized);
}

Array zone_options(
    const Value &cards,
    const Value &player_value,
    std::int32_t owner,
    const std::string &zone,
    const std::string &filter,
    std::int64_t first_index = 0,
    std::int64_t last_index = std::numeric_limits<std::int64_t>::max(),
    bool descending = false,
    const std::string &filter_name = ""
) {
    const Array &values = required(player_value, zone).as_array();
    const std::int64_t bounded_last = std::min<std::int64_t>(
        last_index,
        static_cast<std::int64_t>(values.size()) - 1
    );
    Array options;
    if (descending) {
        for (
            std::int64_t index = bounded_last;
            index >= first_index && index >= 0;
            --index
        ) {
            const std::string id = values[
                static_cast<std::size_t>(index)
            ].string_or();
            const Value *definition = card_definition(cards, id);
            if (
                card_matches_filter(cards, id, filter)
                && (
                    filter_name.empty()
                    || (
                        definition != nullptr
                        && string_arg(*definition, "name") == filter_name
                    )
                )
            ) {
                options.push_back(card_option(
                    id,
                    owner,
                    zone,
                    index
                ));
            }
        }
    } else {
        for (
            std::int64_t index = std::max<std::int64_t>(0, first_index);
            index <= bounded_last;
            ++index
        ) {
            const std::string id = values[
                static_cast<std::size_t>(index)
            ].string_or();
            const Value *definition = card_definition(cards, id);
            if (
                card_matches_filter(cards, id, filter)
                && (
                    filter_name.empty()
                    || (
                        definition != nullptr
                        && string_arg(*definition, "name") == filter_name
                    )
                )
            ) {
                options.push_back(card_option(
                    id,
                    owner,
                    zone,
                    index
                ));
            }
        }
    }
    return options;
}

Value pending_request(
    const std::string &request_type,
    std::int32_t actor,
    std::int64_t min_select,
    std::int64_t max_select,
    bool allow_duplicates,
    bool can_cancel,
    Array options,
    const std::string &continuation_kind
) {
    Object result;
    result["request_type"] = Value(request_type);
    result["player"] = Value(actor);
    result["min_select"] = Value(min_select);
    result["max_select"] = Value(max_select);
    result["allow_duplicates"] = Value(allow_duplicates);
    result["can_cancel"] = Value(can_cancel);
    result["options"] = Value(std::move(options));
    result["continuation_kind"] = Value(continuation_kind);
    return Value(std::move(result));
}

void increment_integer(Value &object, const std::string &key) {
    set_integer(object, key, get_integer(object, key) + 1);
}

Value make_continuation(
    const std::string &op,
    const Value &command_spec,
    std::int32_t actor,
    const std::string &source_slot,
    std::int64_t stage = 0
) {
    Object value;
    value["op"] = Value(op);
    value["command_spec"] = command_spec;
    value["actor"] = Value(actor);
    value["source_slot"] = Value(source_slot);
    value["stage"] = Value(stage);
    return Value(std::move(value));
}

std::vector<std::size_t> selected_indices(
    const Value &selected_options,
    const std::string &zone
) {
    if (!selected_options.is_array()) {
        throw std::invalid_argument("selected_options_not_array");
    }
    std::vector<std::size_t> indices;
    for (const Value &option : selected_options.as_array()) {
        if (
            !option.is_object()
            || string_arg(option, "kind") != "card"
            || string_arg(option, "zone") != zone
        ) {
            throw std::invalid_argument("selected_card_option_invalid");
        }
        const std::int64_t index = integer_arg(option, "index", -1);
        if (index < 0) {
            throw std::invalid_argument("selected_card_index_invalid");
        }
        indices.push_back(static_cast<std::size_t>(index));
    }
    std::sort(indices.begin(), indices.end());
    if (std::adjacent_find(indices.begin(), indices.end()) != indices.end()) {
        throw std::invalid_argument("duplicate_selected_card");
    }
    return indices;
}

std::vector<std::string> selected_zone_card_ids(
    const Value &player_value,
    const Value &selected_options,
    const std::string &zone,
    std::int32_t owner
) {
    if (!selected_options.is_array()) {
        throw std::invalid_argument("selected_options_not_array");
    }
    const Array &cards = required(player_value, zone).as_array();
    std::unordered_set<std::size_t> selected_indices;
    std::vector<std::string> result;
    result.reserve(selected_options.as_array().size());
    for (const Value &option : selected_options.as_array()) {
        if (
            !option.is_object()
            || string_arg(option, "kind") != "card"
            || string_arg(option, "zone") != zone
            || integer_arg(option, "player", -1) != owner
        ) {
            throw std::invalid_argument("selected_card_option_invalid");
        }
        const std::int64_t raw_index = integer_arg(option, "index", -1);
        if (
            raw_index < 0
            || static_cast<std::size_t>(raw_index) >= cards.size()
        ) {
            throw std::invalid_argument("selected_card_out_of_range");
        }
        const std::size_t index = static_cast<std::size_t>(raw_index);
        if (!selected_indices.insert(index).second) {
            throw std::invalid_argument("duplicate_selected_card");
        }
        const std::string actual_id = cards[index].string_or();
        const std::string claimed_id = string_arg(option, "card_id");
        if (actual_id.empty() || claimed_id != actual_id) {
            throw std::invalid_argument("selected_card_identity_mismatch");
        }
        result.push_back(actual_id);
    }
    return result;
}

std::vector<Value> remove_selected(
    Value &player_value,
    const std::string &zone,
    const Value &selected_options
) {
    Array &values = required(player_value, zone).as_array();
    std::vector<Value> removed;
    removed.reserve(selected_options.as_array().size());
    for (const Value &selection : selected_options.as_array()) {
        if (
            string_arg(selection, "kind") != "card"
            || string_arg(selection, "zone") != zone
        ) {
            throw std::invalid_argument("selected_card_option_invalid");
        }
        const std::string wanted = string_arg(
            selection,
            "card_id"
        );
        auto selected = wanted.empty()
            ? values.end()
            : std::find_if(
                values.begin(),
                values.end(),
                [&wanted](const Value &entry) {
                    return entry.string_or() == wanted;
                }
            );
        if (selected == values.end()) {
            const std::int64_t raw_index = integer_arg(
                selection,
                "index",
                -1
            );
            if (
                raw_index < 0
                || static_cast<std::size_t>(raw_index) >= values.size()
            ) {
                throw std::invalid_argument(
                    "selected_card_out_of_range"
                );
            }
            selected = values.begin()
                + static_cast<std::ptrdiff_t>(raw_index);
        }
        if (selected == values.end()) {
            throw std::invalid_argument("selected_card_out_of_range");
        }
        removed.push_back(std::move(*selected));
        values.erase(selected);
    }
    return removed;
}

std::size_t discard_selected(
    Value &player_value,
    const std::string &zone,
    const Value &selected_options
) {
    Array &values = required(player_value, zone).as_array();
    std::vector<std::string> wanted_ids;
    wanted_ids.reserve(selected_options.as_array().size());
    for (const Value &selection : selected_options.as_array()) {
        if (
            !selection.is_object()
            || string_arg(selection, "kind") != "card"
            || string_arg(selection, "zone") != zone
        ) {
            throw std::invalid_argument("selected_card_option_invalid");
        }
        const std::string id = string_arg(selection, "card_id");
        if (id.empty()) {
            throw std::invalid_argument("selected_card_id_missing");
        }
        wanted_ids.push_back(id);
    }
    std::vector<std::size_t> indices;
    indices.reserve(wanted_ids.size());
    for (std::size_t index = 0; index < values.size(); ++index) {
        const auto wanted = std::find(
            wanted_ids.begin(),
            wanted_ids.end(),
            values[index].string_or()
        );
        if (wanted == wanted_ids.end()) {
            continue;
        }
        indices.push_back(index);
        wanted_ids.erase(wanted);
    }
    if (!wanted_ids.empty()) {
        throw std::invalid_argument("selected_card_out_of_range");
    }
    Array &discard = required(player_value, "discard").as_array();
    std::size_t moved = 0;
    for (auto iterator = indices.rbegin(); iterator != indices.rend(); ++iterator) {
        if (*iterator >= values.size()) {
            throw std::invalid_argument("selected_card_out_of_range");
        }
        discard.push_back(std::move(values[*iterator]));
        values.erase(
            values.begin() + static_cast<std::ptrdiff_t>(*iterator)
        );
        ++moved;
    }
    return moved;
}

std::string selected_slot(const Value &selected_options) {
    if (
        !selected_options.is_array()
        || selected_options.as_array().size() != 1
    ) {
        throw std::invalid_argument("single_pokemon_selection_required");
    }
    const Value &option = selected_options.as_array().front();
    if (!option.is_object()) {
        throw std::invalid_argument("selected_pokemon_option_invalid");
    }
    return string_arg(option, "slot");
}

bool selected_confirmation(const Value &selected_options) {
    if (
        !selected_options.is_array()
        || selected_options.as_array().size() != 1
    ) {
        throw std::invalid_argument("confirmation_selection_required");
    }
    const std::string option_id = string_arg(
        selected_options.as_array().front(),
        "option_id"
    );
    if (option_id == "confirm:yes") {
        return true;
    }
    if (option_id == "confirm:no") {
        return false;
    }
    throw std::invalid_argument("confirmation_selection_invalid");
}

void switch_active(Value &player_value, const std::string &bench_slot) {
    if (bench_slot.rfind("bench_", 0) != 0) {
        throw std::invalid_argument("switch_target_not_bench");
    }
    const std::size_t index = static_cast<std::size_t>(
        std::stoul(bench_slot.substr(6))
    );
    Array &bench = required(player_value, "bench").as_array();
    Value &active = required(player_value, "active");
    if (
        index >= bench.size()
        || !active.is_object()
        || !bench[index].is_object()
    ) {
        throw std::invalid_argument("switch_target_invalid");
    }
    if (Value *conditions = active.find("status_conditions")) {
        if (conditions->is_array()) {
            conditions->as_array().clear();
        }
    }
    if (Value *modifiers = active.find("modifiers")) {
        if (modifiers->is_array()) {
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
    }
    active["paralyzed_since_turn"] = Value(0);
    active["damage_prevented"] = Value(false);
    active["all_prevented"] = Value(false);
    active["outgoing_damage_reduction"] = Value(0);
    std::swap(active, bench[index]);
}

void switch_active_with_event(
    VmExecutionResult &result,
    Value &player_value,
    std::int32_t actor,
    std::int32_t target_player,
    const std::string &bench_slot,
    const std::string &reason = "effect"
) {
    const Value &outgoing = required(player_value, "active");
    const Value *incoming = pokemon(player_value, bench_slot);
    if (!outgoing.is_object() || incoming == nullptr) {
        throw std::invalid_argument("switch_target_invalid");
    }
    const std::string outgoing_card_id = string_arg(outgoing, "card_id");
    const std::string incoming_card_id = string_arg(*incoming, "card_id");
    switch_active(player_value, bench_slot);
    const std::int64_t bench_idx = static_cast<std::int64_t>(
        std::stoll(bench_slot.substr(6))
    );
    result.event_types.emplace_back("switched");
    append_event(result, "switched", Object{
        {"actor", Value(actor)},
        {"player", Value(target_player)},
        {"slot", Value(bench_slot)},
        {"bench_idx", Value(bench_idx)},
        {"outgoing_card_id", Value(outgoing_card_id)},
        {"incoming_card_id", Value(incoming_card_id)},
        {
            "card_ids",
            Value(Array{Value(outgoing_card_id), Value(incoming_card_id)}),
        },
        {"count", Value(2)},
        {"reason", Value(reason)},
        {"visibility", Value("public")},
    });
}

void discard_pokemon(Value &player_value, const std::string &slot) {
    Value *target = pokemon(player_value, slot);
    if (target == nullptr) {
        throw std::invalid_argument("discard_pokemon_missing");
    }
    Array &discard = required(player_value, "discard").as_array();
    discard.emplace_back(card_id(*target));
    if (const Value *evolutions = target->find("evolution_stack_ids")) {
        for (const Value &entry : evolutions->as_array()) {
            discard.push_back(entry);
        }
    }
    const std::string tool = string_arg(*target, "attached_tool_id");
    if (!tool.empty()) {
        discard.emplace_back(tool);
    }
    if (const Value *energy = target->find("energy_card_ids")) {
        for (const Value &entry : energy->as_array()) {
            discard.push_back(entry);
        }
    }
    if (slot == "active") {
        player_value["active"] = Value();
    } else {
        const std::size_t index = static_cast<std::size_t>(
            std::stoul(slot.substr(6))
        );
        required(player_value, "bench").as_array().at(index) = Value();
    }
}

} // namespace

NativeRulesKernel::NativeRulesKernel(Value cards)
    : cards_(std::move(cards)) {
    if (!cards_.is_object()) {
        throw std::invalid_argument("cards_must_be_object");
    }
}

void NativeRulesKernel::set_cards(Value cards) {
    if (!cards.is_object()) {
        throw std::invalid_argument("cards_must_be_object");
    }
    cards_ = std::move(cards);
}

std::size_t NativeRulesKernel::card_count() const noexcept {
    return cards_.is_object() ? cards_.as_object().size() : 0;
}

bool NativeRulesKernel::supports(const std::string &op) const noexcept {
    return IMPLEMENTED_OPS.find(op) != IMPLEMENTED_OPS.end();
}

std::size_t NativeRulesKernel::implemented_op_count() const noexcept {
    return IMPLEMENTED_OPS.size();
}

std::size_t NativeRulesKernel::required_op_count() noexcept {
    return 80;
}

const std::set<std::string> &NativeRulesKernel::implemented_ops() noexcept {
    return IMPLEMENTED_OPS;
}

VmExecutionResult NativeRulesKernel::execute(
    Value state,
    const Value &command_spec,
    std::int32_t actor,
    const std::string &source_slot,
    std::uint32_t seed,
    const std::string &context_mode,
    Value initial_context
) const {
    VmExecutionResult result;
    result.state = std::move(state);
    if (initial_context.is_object()) {
        result.context = std::move(initial_context);
    }
    XorShift32 rng(seed);
    result.rng_state = rng.state();
    if (
        actor != 0
        && actor != 1
    ) {
        result.error_code = "invalid_actor";
        return result;
    }
    if (!command_spec.is_object()) {
        result.error_code = "invalid_command_spec";
        return result;
    }
    const std::string op = string_arg(command_spec, "op");
    if (!supports(op)) {
        result.error_code = "unsupported_native_vm_op";
        return result;
    }
    const Value *args_ptr = command_spec.find("args");
    const Value empty_args = Value::make_object();
    const Value &args = (
        args_ptr != nullptr && args_ptr->is_object()
    ) ? *args_ptr : empty_args;
    if (
        context_mode == "attack"
        && result.context.find("base_damage") == nullptr
    ) {
        result.context["base_damage"] = Value(30);
    }

    try {
        Value &self = player(result.state, actor);
        Value &opponent = player(result.state, 1 - actor);
        Value *source = pokemon(self, source_slot);
        Value *opponent_active = pokemon(opponent, "active");
        auto suspend = [&result](Value request, Value continuation) {
            increment_integer(result.state, "choice_sequence");
            result.pending = std::move(request);
            result.continuation = std::move(continuation);
        };

        if (
            op == "apply_attack_lock_basic"
            || op == "apply_dazzling_beam"
            || op == "apply_outgoing_damage_reduction"
            || op == "apply_self_attack_lock"
            || op == "prevent_all"
            || op == "prevent_damage"
            || op == "prevent_effects"
        ) {
            const bool player_attack_name_lock = (
                op == "apply_self_attack_lock"
                && string_arg(args, "scope") == "player"
            );
            if (player_attack_name_lock) {
                Value *locks = self.find("attack_locked_names");
                if (locks == nullptr || !locks->is_object()) {
                    self["attack_locked_names"] = Value::make_object();
                    locks = self.find("attack_locked_names");
                }
                const std::string attack_name = string_arg(
                    args,
                    "attack_name"
                );
                if (!attack_name.empty()) {
                    (*locks)[attack_name] = Value(
                        integer_arg(result.state, "turn_number") + 2
                    );
                }
            }
            Value *target = (
                op == "apply_self_attack_lock"
                || op == "prevent_all"
                || op == "prevent_damage"
                || op == "prevent_effects"
            ) ? source : opponent_active;
            if (target != nullptr && !player_attack_name_lock) {
                bool effect_applies = true;
                if (
                    target == opponent_active
                    && context_mode == "attack"
                    && prevents_attack_effects(*target)
                ) {
                    effect_applies = false;
                }
                if (effect_applies && op == "apply_attack_lock_basic") {
                    effect_applies = card_has_subtype(
                        cards_,
                        card_id(*target),
                        "Basic"
                    );
                }
                if (effect_applies) {
                    append_modifier(*target, op, args);
                    if (op == "prevent_all" || op == "prevent_damage") {
                        (*target)["damage_prevented"] = Value(true);
                    }
                    if (op == "prevent_all" || op == "prevent_effects") {
                        (*target)["all_prevented"] = Value(true);
                    }
                    if (op == "apply_outgoing_damage_reduction") {
                        (*target)["outgoing_damage_reduction"] = Value(
                            std::max<std::int64_t>(
                                integer_arg(
                                    *target,
                                    "outgoing_damage_reduction"
                                ),
                                std::abs(integer_arg(args, "amount"))
                            )
                        );
                    }
                }
            }
        } else if (op == "apply_status" || op == "conditional_status") {
            bool applies = true;
            if (op == "conditional_status") {
                applies = condition_applies(
                    cards_,
                    result.state,
                    actor,
                    string_arg(args, "condition")
                );
            }
            if (
                applies
                && opponent_active != nullptr
                && !(
                    context_mode == "attack"
                    && prevents_attack_effects(*opponent_active)
                )
            ) {
                Value *conditions = opponent_active->find(
                    "status_conditions"
                );
                if (conditions == nullptr || !conditions->is_array()) {
                    (*opponent_active)["status_conditions"] =
                        Value::make_array();
                    conditions = opponent_active->find(
                        "status_conditions"
                    );
                }
                const std::string status = upper_ascii(
                    string_arg(args, "status")
                );
                std::vector<std::string> replaced_statuses;
                if (
                    status == "ASLEEP"
                    || status == "PARALYZED"
                    || status == "CONFUSED"
                ) {
                    for (const Value &entry : conditions->as_array()) {
                        const std::string current = entry.string_or();
                        if (
                            current != status
                            && (
                                current == "ASLEEP"
                                || current == "PARALYZED"
                                || current == "CONFUSED"
                            )
                        ) {
                            replaced_statuses.push_back(current);
                        }
                    }
                    conditions->as_array().erase(
                        std::remove_if(
                            conditions->as_array().begin(),
                            conditions->as_array().end(),
                            [](const Value &entry) {
                                const std::string current =
                                    entry.string_or();
                                return current == "ASLEEP"
                                    || current == "PARALYZED"
                                    || current == "CONFUSED";
                            }
                        ),
                        conditions->as_array().end()
                    );
                }
                for (const std::string &replaced : replaced_statuses) {
                    append_status_event(
                        result,
                        "status_removed",
                        actor,
                        1 - actor,
                        "active",
                        replaced
                    );
                }
                if (
                    std::find(
                        replaced_statuses.begin(),
                        replaced_statuses.end(),
                        "PARALYZED"
                    ) != replaced_statuses.end()
                ) {
                    set_integer(*opponent_active, "paralyzed_since_turn", 0);
                }
                const auto already = std::find_if(
                    conditions->as_array().begin(),
                    conditions->as_array().end(),
                    [&status](const Value &entry) {
                        return entry.string_or() == status;
                    }
                );
                if (already == conditions->as_array().end()) {
                    conditions->as_array().emplace_back(status);
                }
                if (status == "PARALYZED") {
                    set_integer(
                        *opponent_active,
                        "paralyzed_since_turn",
                        get_integer(result.state, "turn_number")
                    );
                }
                append_status_event(
                    result,
                    "status_applied",
                    actor,
                    1 - actor,
                    "active",
                    status
                );
            }
        } else if (op == "attach_energy") {
            const std::string from_zone = string_arg(
                args,
                "from_zone",
                "hand"
            );
            Value &source_zone = required(self, from_zone);
            Array &source_cards = source_zone.as_array();
            const std::string filter = string_arg(
                args,
                "filter",
                "any"
            );
            const std::string target_kind = string_arg(
                args,
                "to",
                source_slot
            );
            std::int64_t amount = integer_arg(args, "amount", 1);
            const std::int64_t going_second_bonus = integer_arg(
                args,
                "going_second_bonus"
            );
            const bool bonus_applied = going_second_bonus > amount
                && actor != integer_arg(result.state, "first_player_idx", -1)
                && integer_arg(result.state, "turn_number") == 2;
            if (bonus_applied) {
                amount = going_second_bonus;
            }
            const bool optional = bool_arg(args, "optional")
                || bonus_applied
                || args.find("min_select") != nullptr;
            const bool select_source = bool_arg(args, "select_source");
            const bool single_optional_bench = (
                target_kind == "bench"
                && optional
                && std::count_if(
                    required(self, "bench").as_array().begin(),
                    required(self, "bench").as_array().end(),
                    [](const Value &entry) {
                        return entry.is_object();
                    }
                ) == 1
            );
            if (
                target_kind == "any"
                || target_kind == "self_basic"
                || (
                    target_kind == "bench"
                    && (
                        amount > 1
                        || select_source
                        || single_optional_bench
                    )
                )
            ) {
                const bool bench_only = target_kind == "bench";
                Array targets = pokemon_options(
                    self,
                    actor,
                    !bench_only,
                    true
                );
                if (target_kind == "self_basic") {
                    targets.erase(
                        std::remove_if(
                            targets.begin(),
                            targets.end(),
                            [this](const Value &entry) {
                                return !card_has_subtype(
                                    cards_,
                                    string_arg(entry, "card_id"),
                                    "Basic"
                                );
                            }
                        ),
                        targets.end()
                    );
                }
                std::vector<std::string> matching_energy_ids;
                for (const Value &entry : source_cards) {
                    if (card_matches_energy(
                        cards_,
                        entry.string_or(),
                        filter
                    )) {
                        matching_energy_ids.push_back(entry.string_or());
                    }
                }
                const std::int64_t matching_energy =
                    static_cast<std::int64_t>(
                        matching_energy_ids.size()
                    );
                if (matching_energy == 0 || targets.empty()) {
                    if (
                        context_mode == "ability"
                        && from_zone == "hand"
                        && !optional
                    ) {
                        throw std::invalid_argument(
                            matching_energy == 0
                                ? "required_energy_source_missing"
                                : "required_energy_target_missing"
                        );
                    }
                    // Hidden deck searches and optional attack effects may
                    // still resolve without finding a card.
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                const std::int64_t max_per_target = bench_only
                    ? integer_arg(args, "max_per_target", 99)
                    : amount;
                const bool same_target = bool_arg(args, "same_target")
                    || target_kind == "any"
                    || target_kind == "self_basic";
                const std::int64_t target_capacity = std::max<
                    std::int64_t
                >(
                    0,
                    static_cast<std::int64_t>(targets.size())
                        * max_per_target
                );
                const std::int64_t maximum = std::min({
                    amount,
                    matching_energy,
                    target_capacity,
                });
                if (
                    targets.size() == 1
                    && !optional
                    && !select_source
                ) {
                    Value *target = pokemon(
                        self,
                        string_arg(targets.front(), "slot")
                    );
                    std::int64_t remaining = maximum;
                    for (
                        std::size_t index = 0;
                        index < source_cards.size() && remaining > 0;
                    ) {
                        if (!card_matches_energy(
                            cards_,
                            source_cards[index].string_or(),
                            filter
                        )) {
                            ++index;
                            continue;
                        }
                        required(
                            *target,
                            "energy_card_ids"
                        ).as_array().push_back(
                            std::move(source_cards[index])
                        );
                        source_cards.erase(
                            source_cards.begin()
                                + static_cast<std::ptrdiff_t>(index)
                        );
                        --remaining;
                        result.event_types.emplace_back(
                            "energy_attached"
                        );
                    }
                    if (from_zone == "deck") {
                        shuffle_array(source_cards, rng);
                        result.event_types.emplace_back("deck_shuffled");
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                Array options;
                Array presented_energy_ids;
                const bool distribution = optional
                    || select_source
                    || bench_only;
                if (distribution) {
                    std::vector<std::int64_t> exposed_energy_indices;
                    std::map<std::string, std::int64_t, std::less<>>
                        exposed_by_id;
                    for (
                        std::int64_t index = 0;
                        index < matching_energy;
                        ++index
                    ) {
                        const std::string &card_id = matching_energy_ids[
                            static_cast<std::size_t>(index)
                        ];
                        if (
                            select_source
                            && exposed_by_id[card_id] >= maximum
                        ) {
                            continue;
                        }
                        exposed_energy_indices.push_back(index);
                        ++exposed_by_id[card_id];
                        if (
                            !select_source
                            && exposed_energy_indices.size()
                                >= static_cast<std::size_t>(maximum)
                        ) {
                            break;
                        }
                    }
                    for (const std::int64_t index : exposed_energy_indices) {
                        presented_energy_ids.emplace_back(
                            matching_energy_ids[
                                static_cast<std::size_t>(index)
                            ]
                        );
                    }
                    for (const Value &target : targets) {
                        for (const std::int64_t index : exposed_energy_indices) {
                            Value option = target;
                            decorate_energy_distribution_option(
                                option,
                                actor,
                                index,
                                matching_energy_ids[
                                    static_cast<std::size_t>(index)
                                ]
                            );
                            options.push_back(std::move(option));
                        }
                    }
                } else {
                    options = std::move(targets);
                }
                Value continued = make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                );
                continued["effective_amount"] = Value(maximum);
                continued["distribution"] = Value(distribution);
                const std::int64_t minimum = distribution
                    ? std::min(
                        maximum,
                        integer_arg(args, "min_select")
                    )
                    : 1;
                Value request = pending_request(
                        distribution
                            ? "distribute_energy"
                            : "select_energy_target",
                        actor,
                        minimum,
                        distribution ? maximum : 1,
                        false,
                        distribution && minimum == 0,
                        std::move(options),
                        distribution
                            ? "energy_attach_distribution"
                            : "attach_energy_to_board"
                    );
                if (distribution) {
                    request["metadata"] = Value(Object{
                        {"card_ids", Value(std::move(presented_energy_ids))},
                        {"domain", Value("distribute_energy")},
                        {"energy_type", Value(filter)},
                        {"max_per_target", Value(max_per_target)},
                        {"purpose", Value("energy_attach_distribution")},
                        {"same_target", Value(same_target)},
                        {"source_player", Value(actor)},
                        {"source_zone", Value(from_zone)},
                    });
                }
                suspend(
                    std::move(request),
                    std::move(continued)
                );
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            if (target_kind == "bench" && amount <= 1 && !select_source) {
                Array targets = pokemon_options(
                    self,
                    actor,
                    false,
                    true
                );
                const bool has_matching_energy = std::any_of(
                    source_cards.begin(),
                    source_cards.end(),
                    [this, &filter](const Value &entry) {
                        return card_matches_energy(
                            cards_,
                            entry.string_or(),
                            filter
                        );
                    }
                );
                if (!has_matching_energy || targets.empty()) {
                    // The formal engine does not shuffle for this no-op.
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                if (targets.size() == 1 && !optional) {
                    Value *target = pokemon(
                        self,
                        string_arg(targets.front(), "slot")
                    );
                    const auto energy = std::find_if(
                        source_cards.begin(),
                        source_cards.end(),
                        [this, &filter](const Value &entry) {
                            return card_matches_energy(
                                cards_,
                                entry.string_or(),
                                filter
                            );
                        }
                    );
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(*energy));
                    source_cards.erase(energy);
                    result.event_types.emplace_back("energy_attached");
                    if (from_zone == "deck") {
                        shuffle_array(source_cards, rng);
                        result.event_types.emplace_back("deck_shuffled");
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                suspend(
                    pending_request(
                        "select_own_bench_energy",
                        actor,
                        optional ? 0 : 1,
                        1,
                        false,
                        optional,
                        std::move(targets),
                        "attach_energy_to_bench"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            Value *target = pokemon(
                self,
                target_kind == "self"
                    ? source_slot
                    : target_kind
            );
            std::int64_t remaining = amount;
            if (target != nullptr) {
                Array &attachments = required(
                    *target,
                    "energy_card_ids"
                ).as_array();
                for (
                    std::size_t index = 0;
                    index < source_cards.size() && remaining > 0;
                ) {
                    if (!card_matches_energy(
                        cards_,
                        source_cards[index].string_or(),
                        filter
                    )) {
                        ++index;
                        continue;
                    }
                    attachments.push_back(std::move(source_cards[index]));
                    source_cards.erase(
                        source_cards.begin()
                            + static_cast<std::ptrdiff_t>(index)
                    );
                    --remaining;
                    result.event_types.emplace_back("energy_attached");
                }
            }
            if (from_zone == "deck") {
                shuffle_array(source_cards, rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (op == "attach_energy_from_discard") {
            const std::string filter = string_arg(
                args,
                "energy_type",
                string_arg(args, "filter", "basic")
            );
            const Array sources = zone_options(
                cards_,
                self,
                actor,
                "discard",
                filter
            );
            Array targets = pokemon_options(
                self,
                actor,
                string_arg(args, "target", "self") != "bench",
                string_arg(args, "target", "self") != "self"
            );
            const std::string target_type = string_arg(
                args,
                "target_pokemon_type"
            );
            if (!target_type.empty()) {
                targets.erase(
                    std::remove_if(
                        targets.begin(),
                        targets.end(),
                        [this, &target_type](const Value &entry) {
                            const Value *definition = card_definition(
                                cards_,
                                string_arg(entry, "card_id")
                            );
                            return definition == nullptr
                                || !string_array_contains_ci(
                                    definition->find("energy_types"),
                                    target_type
                                );
                        }
                    ),
                    targets.end()
                );
            }
            if (sources.empty() || targets.empty()) {
                const bool required_public_attach = (
                    context_mode == "trainer"
                    || context_mode == "ability"
                ) && args.find("min_select") == nullptr
                    && !bool_arg(args, "optional");
                if (required_public_attach) {
                    throw std::invalid_argument(
                        sources.empty()
                            ? "required_energy_source_missing"
                            : "required_energy_target_missing"
                    );
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const bool select_source = bool_arg(args, "select_source");
            const std::int64_t maximum = std::min<std::int64_t>(
                integer_arg(args, "amount", 1),
                static_cast<std::int64_t>(sources.size())
            );
            std::vector<std::size_t> exposed_source_indices;
            std::map<std::string, std::int64_t, std::less<>> exposed_by_id;
            for (std::size_t index = 0; index < sources.size(); ++index) {
                const std::string card_id = string_arg(
                    sources[index],
                    "card_id"
                );
                if (select_source && exposed_by_id[card_id] >= maximum) {
                    continue;
                }
                exposed_source_indices.push_back(index);
                ++exposed_by_id[card_id];
                if (
                    !select_source
                    && exposed_source_indices.size()
                        >= static_cast<std::size_t>(maximum)
                ) {
                    break;
                }
            }
            Array options;
            Array presented_energy_ids;
            for (const std::size_t index : exposed_source_indices) {
                presented_energy_ids.emplace_back(
                    string_arg(sources[index], "card_id")
                );
            }
            for (const Value &target : targets) {
                for (const std::size_t index : exposed_source_indices) {
                    Value option = target;
                    decorate_energy_distribution_option(
                        option,
                        actor,
                        static_cast<std::int64_t>(index),
                        string_arg(sources[index], "card_id")
                    );
                    options.push_back(std::move(option));
                }
            }
            const bool optional_count = args.find("min_select") != nullptr
                || bool_arg(args, "optional");
            const std::string target_kind = string_arg(
                args,
                "target",
                "self"
            );
            const bool same_target = bool_arg(args, "same_target")
                || target_kind == "self"
                || target_kind == "self_or_bench";
            if (
                targets.size() == 1
                && static_cast<std::int64_t>(sources.size()) == maximum
                && !optional_count
                && !select_source
            ) {
                Array &discard = required(self, "discard").as_array();
                Value *target = pokemon(
                    self,
                    string_arg(targets.front(), "slot")
                );
                std::int64_t remaining = maximum;
                for (
                    std::size_t index = 0;
                    index < discard.size() && remaining > 0;
                ) {
                    if (!card_matches_energy(
                            cards_,
                            discard[index].string_or(),
                            filter
                        )) {
                        ++index;
                        continue;
                    }
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(discard[index]));
                    discard.erase(
                        discard.begin()
                            + static_cast<std::ptrdiff_t>(index)
                    );
                    --remaining;
                    result.event_types.emplace_back("energy_attached");
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const std::int64_t minimum = optional_count
                ? std::min(
                    maximum,
                    integer_arg(args, "min_select")
                )
                : maximum;
            Value request = pending_request(
                    "distribute_energy",
                    actor,
                    minimum,
                    maximum,
                    false,
                    minimum == 0,
                    std::move(options),
                    "attach_discard_energy_distribution"
                );
            request["metadata"] = Value(Object{
                {"card_ids", Value(std::move(presented_energy_ids))},
                {"domain", Value("distribute_energy")},
                {"energy_type", Value(filter)},
                {"max_per_target", Value(same_target ? maximum : 99)},
                {
                    "purpose",
                    Value("attach_discard_energy_distribution")
                },
                {"same_target", Value(same_target)},
                {"source_player", Value(actor)},
                {"source_zone", Value("discard")},
            });
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (
            op == "choose_damage_target"
            || op == "choose_heal_damage"
        ) {
            const bool damage = op == "choose_damage_target";
            Value &target_player = damage ? opponent : self;
            Array options = pokemon_options(
                target_player,
                damage ? 1 - actor : actor,
                true,
                true
            );
            if (!damage) {
                options.erase(
                    std::remove_if(
                        options.begin(),
                        options.end(),
                        [&target_player](const Value &entry) {
                            const Value *target = pokemon(
                                target_player,
                                string_arg(entry, "slot")
                            );
                            return target == nullptr
                                || get_integer(
                                    *target,
                                    "damage_counters"
                                ) <= 0;
                        }
                    ),
                    options.end()
                );
                if (options.size() == 1) {
                    const std::string target_slot = string_arg(
                        options.front(), "slot");
                    Value *target = pokemon(
                        target_player,
                        target_slot
                    );
                    const std::int64_t healed = target == nullptr
                        ? 0 : heal_damage(
                            *target, integer_arg(args, "amount", 30));
                    if (healed > 0) {
                        self["healed_this_turn"] = Value(true);
                        append_healed_event(
                            result, actor, actor, target_slot, healed);
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
            }
            suspend(
                pending_request(
                    damage ? "damage_target" : "select_heal_target",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    std::move(options),
                    damage ? "damage_target" : "heal_target"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "conditional") {
            Array options = zone_options(
                cards_,
                self,
                actor,
                "hand",
                "any"
            );
            if (options.size() < 2) {
                throw std::invalid_argument(
                    "conditional_cost_cards_insufficient"
                );
            }
            Value continued = make_continuation(
                op,
                command_spec,
                actor,
                source_slot
            );
            if (options.size() == 2) {
                // The authoritative VM does not publish a decision when the
                // cost has only one legal payment: it discards both cards
                // and advances directly to the search request. Keep that
                // forced transition out of the information-set tree.
                const std::size_t removed = discard_selected(
                    self,
                    "hand",
                    Value(std::move(options))
                );
                if (removed > 0) {
                    result.event_types.emplace_back("cards_discarded");
                }
                continued["stage"] = Value(1);
                Array search_options = zone_options(
                    cards_, self, actor, "deck", "pokemon");
                if (search_options.empty()) {
                    shuffle_array(required(self, "deck").as_array(), rng);
                    result.event_types.emplace_back("deck_shuffled");
                } else {
                    suspend(
                        pending_request(
                            "search_move",
                            actor,
                            0,
                            1,
                            false,
                            false,
                            std::move(search_options),
                            "search_move"
                        ),
                        std::move(continued)
                    );
                }
            } else {
                suspend(
                    pending_request(
                        "discard_cards",
                        actor,
                        2,
                        2,
                        false,
                        false,
                        std::move(options),
                        "discard_cards"
                    ),
                    std::move(continued)
                );
            }
        } else if (op == "conditional_damage") {
            if (
                condition_applies(
                    cards_,
                    result.state,
                    actor,
                    string_arg(args, "condition")
                )
            ) {
                set_attack_damage(
                    result.context,
                    integer_arg(args, "bonus"),
                    true
                );
            }
        } else if (op == "conditional_damage_then_heal") {
            const bool healed = source != nullptr
                && bool_arg(*source, "healed_this_turn");
            const std::int64_t total = integer_arg(args, "base", 60)
                + (healed ? integer_arg(args, "bonus", 90) : 0);
            set_attack_damage(result.context, total, true);
        } else if (op == "conditional_search") {
            const bool going_second_first_turn = (
                actor != integer_arg(result.state, "first_player_idx")
                && actor == integer_arg(result.state, "active_player_idx")
                && integer_arg(result.state, "turn_number") == 2
            );
            const std::int64_t requested = going_second_first_turn
                ? integer_arg(args, "max_count", 3)
                : integer_arg(args, "default_count", 1);
            Array options = zone_options(
                cards_,
                self,
                actor,
                "deck",
                string_arg(args, "filter", "any")
            );
            if (options.empty()) {
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const std::int64_t count = std::min<std::int64_t>(
                requested,
                static_cast<std::int64_t>(options.size())
            );
            const std::int64_t minimum = 0;
            suspend(
                pending_request(
                    "search_move",
                    actor,
                    minimum,
                    count,
                    false,
                    true,
                    std::move(options),
                    "search_move"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "deal_damage") {
            const Value *formula = args.find("formula_ast");
            const std::int64_t amount = formula == nullptr
                ? integer_arg(args, "amount")
                : std::max<std::int64_t>(
                    0,
                    evaluate_formula_ast(
                        *formula,
                        cards_,
                        result.state,
                        actor
                    )
                );
            const std::string target = string_arg(
                args,
                "target",
                "opponent_active"
            );
            Value *target_pokemon = target == "self"
                ? source
                : opponent_active;
            if (context_mode == "attack") {
                set_attack_damage(result.context, amount, true);
                for (const std::string &key : {
                    "ignore_weakness",
                    "ignore_resistance",
                    "ignore_defender_damage_effects",
                }) {
                    if (bool_arg(args, key)) {
                        result.context[key] = Value(true);
                    }
                }
            } else if (target_pokemon != nullptr) {
                add_damage(*target_pokemon, amount);
                append_damage_feedback_event(
                    result,
                    "damage_dealt",
                    actor,
                    target == "self" ? actor : 1 - actor,
                    target == "self" ? source_slot : "active",
                    amount
                );
            }
        } else if (
            op == "deal_damage_per_discard_psychic"
            || op == "deal_damage_per_energy"
            || op == "deal_damage_per_evolved"
            || op == "deal_damage_per_hand_size"
            || op == "deal_damage_per_self_damage"
            || op == "deal_damage_per_self_energy"
            || op == "deal_damage_per_self_energy_type"
            || op == "deal_damage_plus_bench"
            || op == "deal_damage_with_self_penalty"
        ) {
            std::int64_t total = 0;
            if (op == "deal_damage_per_discard_psychic") {
                std::int64_t count = 0;
                for (const Value &entry : required(self, "discard").as_array()) {
                    const std::string id = entry.string_or();
                    const Value *definition = card_definition(cards_, id);
                    if (
                        card_is_pokemon(cards_, id)
                        && definition != nullptr
                        && string_array_contains_ci(
                            definition->find("energy_types"),
                            "Psychic"
                        )
                    ) {
                        ++count;
                    }
                }
                total = integer_arg(args, "base", 80)
                    + count * integer_arg(args, "per_card", 10);
            } else if (op == "deal_damage_per_energy") {
                const std::string count_from = string_arg(
                    args,
                    "count_from",
                    "self"
                );
                std::int64_t count = 0;
                if (count_from == "opponent_active") {
                    count = energy_units(cards_, opponent_active);
                } else if (count_from == "all_opponent") {
                    for (const Value *entry : all_pokemon(opponent)) {
                        count += energy_units(cards_, entry);
                    }
                } else {
                    count = energy_units(cards_, source);
                }
                total = integer_arg(args, "base")
                    + count * integer_arg(args, "per_energy");
            } else if (op == "deal_damage_per_evolved") {
                std::int64_t count = 0;
                for (const Value *entry : all_pokemon(self)) {
                    if (!card_has_subtype(
                        cards_,
                        card_id(*entry),
                        "Basic"
                    )) {
                        ++count;
                    }
                }
                total = count * integer_arg(args, "per_evolved", 50);
            } else if (op == "deal_damage_per_hand_size") {
                total = static_cast<std::int64_t>(
                    required(self, "hand").as_array().size()
                ) * integer_arg(args, "per");
            } else if (op == "deal_damage_per_self_damage") {
                total = integer_arg(args, "base")
                    + (
                        source == nullptr
                        ? 0
                        : get_integer(*source, "damage_counters")
                    ) * integer_arg(args, "per_counter");
            } else if (
                op == "deal_damage_per_self_energy"
                || op == "deal_damage_per_self_energy_type"
            ) {
                const std::string filter = string_arg(
                    args,
                    op == "deal_damage_per_self_energy"
                        ? "energy_filter"
                        : "energy_type"
                );
                total = integer_arg(args, "base")
                    + energy_units(cards_, source, filter)
                        * integer_arg(args, "per_energy");
            } else if (op == "deal_damage_plus_bench") {
                total = integer_arg(args, "base")
                    + bench_count(self) * integer_arg(args, "per_bench");
            } else {
                total = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "base")
                        - (
                            source == nullptr
                            ? 0
                            : get_integer(*source, "damage_counters")
                        ) * integer_arg(args, "per_counter")
                );
            }
            set_attack_damage(result.context, total, true);
        } else if (op == "deal_bench_damage") {
            const bool targets_self = string_arg(
                args,
                "player",
                "opponent"
            ) == "self";
            const std::int32_t target_owner = targets_self
                ? actor
                : 1 - actor;
            Value &target_player = targets_self ? self : opponent;
            Array options = pokemon_options(
                target_player,
                target_owner,
                false,
                true
            );
            const std::int64_t actual_count = std::min<std::int64_t>(
                std::max<std::int64_t>(
                    0,
                    integer_arg(args, "count", 1)
                ),
                static_cast<std::int64_t>(options.size())
            );
            if (
                bool_arg(args, "choose_targets")
                && options.size() > 1
                && actual_count > 0
            ) {
                suspend(
                    pending_request(
                        "select_bench_targets",
                        actor,
                        actual_count,
                        actual_count,
                        false,
                        false,
                        std::move(options),
                        "deal_bench_damage"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
            } else {
                const std::int64_t amount = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "amount")
                );
                for (
                    std::int64_t index = 0;
                    index < actual_count;
                    ++index
                ) {
                    const std::string slot = string_arg(
                        options.at(static_cast<std::size_t>(index)),
                        "slot"
                    );
                    Value *target = pokemon(target_player, slot);
                    if (target == nullptr) {
                        continue;
                    }
                    if (context_mode == "attack") {
                        Value *packets = result.context.find(
                            "damage_packets"
                        );
                        if (packets == nullptr || !packets->is_array()) {
                            result.context["damage_packets"] =
                                Value::make_array();
                            packets = result.context.find(
                                "damage_packets"
                            );
                        }
                        packets->as_array().emplace_back(Object{
                            {"target_player", Value(target_owner)},
                            {"target_slot", Value(slot)},
                            {"amount", Value(amount)},
                        });
                    } else {
                        std::int64_t applied = amount;
                        if (bool_arg(*target, "damage_prevented")) {
                            applied = 0;
                        }
                        add_damage(*target, applied);
                        append_damage_feedback_event(
                            result,
                            "damage_dealt",
                            actor,
                            target_owner,
                            slot,
                            applied
                        );
                        const std::int64_t maximum_hp = pokemon_hp(
                            cards_,
                            *target
                        );
                        if (
                            maximum_hp > 0
                            && integer_arg(
                                *target,
                                "damage_counters"
                            ) * 10 >= maximum_hp
                            && target->find("pending_ko_source_kind") == nullptr
                        ) {
                            (*target)["pending_ko_source_kind"] = Value(
                                "attack_effect"
                            );
                        }
                    }
                }
            }
        } else if (op == "discard_cards") {
            const std::int64_t amount = integer_arg(args, "amount", 1);
            const std::string zone = string_arg(
                args,
                "from",
                string_arg(args, "from_zone", "hand")
            );
            suspend(
                pending_request(
                    "discard_cards",
                    actor,
                    amount,
                    amount,
                    false,
                    false,
                    zone_options(
                        cards_,
                        self,
                        actor,
                        zone,
                        "any"
                    ),
                    "discard_cards"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "discard_energy") {
            Value &target_player = string_arg(
                args,
                "from",
                "self"
            ) == "self" ? self : opponent;
            Value *target = pokemon(target_player, "active");
            Array options;
            if (target != nullptr) {
                const Array &energy = required(
                    *target,
                    "energy_card_ids"
                ).as_array();
                for (std::size_t index = 0; index < energy.size(); ++index) {
                    if (attached_energy_card_matches(
                        cards_,
                        *target,
                        index,
                        string_arg(args, "filter", "any")
                    )) {
                        options.push_back(attachment_option(
                            energy[index].string_or(),
                            string_arg(args, "from", "self") == "self"
                                ? actor
                                : 1 - actor,
                            "active",
                            static_cast<std::int64_t>(index)
                        ));
                    }
                }
            }
            const std::int64_t amount = std::min<std::int64_t>(
                integer_arg(args, "amount", 1),
                static_cast<std::int64_t>(options.size())
            );
            if (amount == 0) {
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            if (
                static_cast<std::int64_t>(options.size()) == amount
            ) {
                Array &energy = required(
                    *target,
                    "energy_card_ids"
                ).as_array();
                std::vector<std::size_t> indices;
                std::vector<Value> removed;
                for (const Value &option : options) {
                    const std::size_t index = static_cast<std::size_t>(
                        integer_arg(option, "index", -1)
                    );
                    indices.push_back(index);
                    removed.push_back(energy.at(index));
                }
                std::sort(indices.begin(), indices.end());
                for (
                    auto iterator = indices.rbegin();
                    iterator != indices.rend();
                    ++iterator
                ) {
                    energy.erase(
                        energy.begin()
                            + static_cast<std::ptrdiff_t>(*iterator)
                    );
                }
                Array &discard = required(
                    target_player,
                    "discard"
                ).as_array();
                for (Value &entry : removed) {
                    discard.push_back(std::move(entry));
                }
                result.event_types.emplace_back("cards_discarded");
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            suspend(
                pending_request(
                    "select_attachment",
                    actor,
                    amount,
                    amount,
                    false,
                    false,
                    std::move(options),
                    "discard_energy_attachments"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "discard_energy_then_damage") {
            if (source != nullptr) {
                Array &attached = required(
                    *source,
                    "energy_card_ids"
                ).as_array();
                Array &discard = required(self, "discard").as_array();
                std::int64_t discarded = 0;
                for (std::size_t index = 0; index < attached.size();) {
                    if (!attached_energy_card_matches(
                        cards_,
                        *source,
                        index,
                        "fighting"
                    )) {
                        ++index;
                        continue;
                    }
                    discard.push_back(std::move(attached[index]));
                    attached.erase(
                        attached.begin()
                            + static_cast<std::ptrdiff_t>(index)
                    );
                    ++discarded;
                }
                set_attack_damage(
                    result.context,
                    integer_arg(args, "base", 10)
                        + discarded * integer_arg(args, "per_energy", 60),
                    true
                );
                if (discarded > 0) {
                    result.event_types.emplace_back("cards_discarded");
                }
            }
        } else if (op == "discard_hand_then_damage") {
            Array &hand = required(self, "hand").as_array();
            Array &discard = required(self, "discard").as_array();
            const std::int64_t count = static_cast<std::int64_t>(
                hand.size()
            );
            for (Value &entry : hand) {
                discard.push_back(std::move(entry));
            }
            hand.clear();
            set_attack_damage(
                result.context,
                integer_arg(args, "base_damage", 60)
                    + (
                        count >= integer_arg(args, "threshold", 5)
                        ? integer_arg(args, "bonus", 150)
                        : 0
                    ),
                true
            );
            if (count > 0) {
                result.event_types.emplace_back("cards_discarded");
            }
        } else if (op == "discard_then_draw_cards") {
            Array &hand = required(self, "hand").as_array();
            Array &discard = required(self, "discard").as_array();
            const bool discard_hand = bool_arg(
                args,
                "discard_hand"
            );
            const std::int64_t discard_amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "discard_amount", 1)
            );
            const std::int64_t draw_amount = integer_arg(
                args,
                "draw_amount",
                integer_arg(args, "draw", 7)
            );
            if (
                !discard_hand
                && !hand.empty()
                && static_cast<std::int64_t>(hand.size()) > discard_amount
            ) {
                suspend(
                    pending_request(
                        "search_move",
                        actor,
                        1,
                        discard_amount,
                        false,
                        false,
                        zone_options(
                            cards_,
                            self,
                            actor,
                            "hand",
                            "any"
                        ),
                        "discard_hand_then_draw"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const std::size_t discarded_count = discard_hand
                ? hand.size()
                : std::min<std::size_t>(
                    hand.size(),
                    static_cast<std::size_t>(discard_amount)
                );
            Array discarded_ids;
            if (discard_hand || discarded_count == hand.size()) {
                discarded_ids.reserve(hand.size());
                for (Value &entry : hand) {
                    discarded_ids.emplace_back(entry.string_or());
                    discard.push_back(std::move(entry));
                }
                hand.clear();
            }
            const auto drawn = discard_hand || discarded_count > 0
                ? draw_cards(self, draw_amount)
                : std::vector<std::string>{};
            if (discarded_count > 0) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
            }
            append_cards_drawn_event(
                result, actor, drawn, "discard_then_draw");
        } else if (op == "discard_then_revive") {
            Array &discard = required(self, "discard").as_array();
            Array &bench = required(self, "bench").as_array();
            const std::string wanted = string_arg(args, "card_id");
            const auto found = std::find_if(
                discard.begin(),
                discard.end(),
                [&wanted](const Value &entry) {
                    return entry.string_or() == wanted;
                }
            );
            const auto empty = std::find_if(
                bench.begin(),
                bench.end(),
                [](const Value &entry) { return entry.is_null(); }
            );
            if (found != discard.end() && empty != bench.end()) {
                *empty = new_pokemon(cards_, wanted);
                discard.erase(found);
                result.event_types.emplace_back("card_moved");
                const auto drawn = draw_cards(self, 3);
                append_cards_drawn_event(
                    result, actor, drawn, "discard_then_revive");
            }
        } else if (op == "draw_and_attach_energy") {
            const auto drawn = draw_cards(
                self,
                2
            );
            append_cards_drawn_event(
                result, actor, drawn, "draw_and_attach_energy");
            if (drawn.empty()) {
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const std::string filter = string_arg(
                args,
                "energy_type",
                "Grass"
            );
            const Array &hand = required(self, "hand").as_array();
            const std::int64_t matching = static_cast<std::int64_t>(
                std::count_if(
                    hand.begin(),
                    hand.end(),
                    [this, &filter](const Value &entry) {
                        return card_matches_energy(
                            cards_,
                            entry.string_or(),
                            filter
                        );
                    }
                )
            );
            const std::int64_t maximum = std::min<std::int64_t>(
                integer_arg(args, "energy_count", 2),
                matching
            );
            Array targets = pokemon_options(
                self,
                actor,
                false,
                true
            );
            if (maximum <= 0 || targets.empty()) {
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const std::int64_t minimum = std::min<std::int64_t>(
                integer_arg(args, "min_select"),
                maximum
            );
            Array options;
            std::vector<std::string> matching_energy_ids;
            for (const Value &entry : hand) {
                if (card_matches_energy(
                    cards_,
                    entry.string_or(),
                    filter
                )) {
                    matching_energy_ids.push_back(entry.string_or());
                }
            }
            matching_energy_ids.resize(
                static_cast<std::size_t>(maximum)
            );
            for (const Value &target : targets) {
                for (
                    std::int64_t index = 0;
                    index < maximum;
                    ++index
                ) {
                    Value option = target;
                    decorate_energy_distribution_option(
                        option,
                        actor,
                        index,
                        matching_energy_ids[
                            static_cast<std::size_t>(index)
                        ]
                    );
                    options.push_back(std::move(option));
                }
            }
            if (
                targets.size() == 1
                && minimum == maximum
            ) {
                Value *target = pokemon(
                    self,
                    string_arg(targets.front(), "slot")
                );
                Array &mutable_hand = required(self, "hand").as_array();
                for (
                    std::int64_t count = 0;
                    count < maximum;
                    ++count
                ) {
                    const auto energy = std::find_if(
                        mutable_hand.begin(),
                        mutable_hand.end(),
                        [this, &filter](const Value &entry) {
                            return card_matches_energy(
                                cards_,
                                entry.string_or(),
                                filter
                            );
                        }
                    );
                    if (energy == mutable_hand.end()) {
                        break;
                    }
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(*energy));
                    mutable_hand.erase(energy);
                    result.event_types.emplace_back("energy_attached");
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            Value request = pending_request(
                    "distribute_energy",
                    actor,
                    minimum,
                    maximum,
                    false,
                    false,
                    std::move(options),
                    "draw_attach_distribution"
                );
            Array presented_energy_ids;
            for (const std::string &card_id : matching_energy_ids) {
                presented_energy_ids.emplace_back(card_id);
            }
            request["metadata"] = Value(Object{
                {"card_ids", Value(std::move(presented_energy_ids))},
                {"domain", Value("distribute_energy")},
                {"energy_type", Value(filter)},
                {"max_per_target", Value(maximum)},
                {"purpose", Value("draw_attach_distribution")},
                {"same_target", Value(true)},
                {"source_player", Value(actor)},
                {"source_zone", Value("hand")},
            });
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "deal_damage_then_heal") {
            set_attack_damage(
                result.context,
                integer_arg(args, "damage", 10),
                true
            );
            const std::int64_t healed = source == nullptr
                ? 0 : heal_damage(
                    *source, integer_arg(args, "heal", 10));
            if (healed > 0) {
                self["healed_this_turn"] = Value(true);
                append_healed_event(
                    result, actor, actor, source_slot, healed);
            }
        } else if (
            op == "draw_cards"
            || op == "trigger_draw_cards"
        ) {
            const std::int32_t target = op == "trigger_draw_cards"
                ? static_cast<std::int32_t>(
                    integer_arg(args, "player", actor)
                )
                : (
                    string_arg(args, "player", "self") == "opponent"
                    ? 1 - actor
                    : actor
                );
            const auto drawn = draw_cards(
                player(result.state, target),
                integer_arg(args, "amount", 1)
            );
            append_cards_drawn_event(result, target, drawn, op);
        } else if (
            op == "draw_until"
            || op == "draw_until_more_than_opponent"
        ) {
            const std::int64_t target = op == "draw_until"
                ? integer_arg(args, "target_hand_size")
                : static_cast<std::int64_t>(
                    required(opponent, "hand").as_array().size() + 1
                );
            const std::int64_t current = static_cast<std::int64_t>(
                required(self, "hand").as_array().size()
            );
            const auto drawn = draw_cards(self, std::max<std::int64_t>(
                0,
                target - current
            ));
            append_cards_drawn_event(result, actor, drawn, op);
        } else if (op == "evolve_skip_stage") {
            Array options = rare_candy_options(
                cards_,
                self,
                actor
            );
            suspend(
                pending_request(
                    "evolve_skip_stage",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    std::move(options),
                    "evolve_skip_stage"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "fail_attack") {
            result.context["attack_failed"] = Value(true);
        } else if (
            op == "flip_coin"
            || op == "flip_coin_repeat_damage"
            || op == "flip_coin_then_discard_energy"
            || op == "flip_coin_then_ko"
            || op == "flip_until_tails"
        ) {
            Array flips;
            if (op == "flip_coin_repeat_damage") {
                const std::int64_t count = std::min<std::int64_t>(
                    32,
                    integer_arg(args, "flips", 3)
                );
                for (std::int64_t index = 0; index < count; ++index) {
                    flips.emplace_back((rng.next_u32() & 1U) == 0U);
                }
            } else if (op == "flip_coin_then_ko") {
                flips.emplace_back((rng.next_u32() & 1U) == 0U);
                flips.emplace_back((rng.next_u32() & 1U) == 0U);
            } else if (op == "flip_until_tails") {
                for (std::int64_t index = 0; index < 32; ++index) {
                    const bool heads = (rng.next_u32() & 1U) == 0U;
                    flips.emplace_back(heads);
                    if (!heads) {
                        break;
                    }
                }
            } else {
                flips.emplace_back((rng.next_u32() & 1U) == 0U);
            }
            Value continuation = make_continuation(
                op,
                command_spec,
                actor,
                source_slot
            );
            continuation["flips"] = Value(std::move(flips));
            continuation["context_mode"] = Value(context_mode);
            suspend(
                pending_request(
                    "coin_flip",
                    actor,
                    0,
                    0,
                    false,
                    false,
                    {},
                    "coin"
                ),
                std::move(continuation)
            );
        } else if (
            op == "hand_to_bottom_draw_until"
            || op == "hand_to_bottom_then_draw"
        ) {
            const std::int64_t size = static_cast<std::int64_t>(
                required(self, "hand").as_array().size()
            );
            const bool until = op == "hand_to_bottom_draw_until";
            if (until && size == 1) {
                Array &hand = required(self, "hand").as_array();
                Array &deck = required(self, "deck").as_array();
                Array returned_ids{Value(hand.front().string_or())};
                deck.insert(deck.begin(), std::move(hand.front()));
                hand.erase(hand.begin());
                append_card_zone_event(
                    result,
                    "card_moved",
                    actor,
                    std::move(returned_ids),
                    "hand",
                    "deck",
                    "owner"
                );
                const std::int64_t draw_count = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "target_hand_size", 5)
                        - static_cast<std::int64_t>(hand.size())
                );
                const auto drawn = draw_cards(self, draw_count);
                append_cards_drawn_event(
                    result, actor, drawn, "hand_to_bottom");
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            suspend(
                pending_request(
                    until ? "houb" : "hand_bottom_draw",
                    actor,
                    until ? 1 : 0,
                    until ? 1 : size,
                    false,
                    !until,
                    zone_options(
                        cards_,
                        self,
                        actor,
                        "hand",
                        "any"
                    ),
                    until ? "houb" : "hand_bottom_draw"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "heal_all") {
            static constexpr std::array<const char *, 6> slots{
                "active", "bench_0", "bench_1", "bench_2", "bench_3",
                "bench_4",
            };
            for (const char *slot : slots) {
                Value *entry = pokemon(self, slot);
                const std::int64_t healed = entry == nullptr
                    ? 0 : heal_damage(
                        *entry, integer_arg(args, "amount", 20));
                if (healed > 0) {
                    append_healed_event(
                        result, actor, actor, slot, healed);
                    self["healed_this_turn"] = Value(true);
                }
            }
        } else if (op == "heal_damage") {
            Value *target = source;
            const std::string target_name = string_arg(
                args,
                "target",
                "self"
            );
            if (target_name == "opponent_active") {
                target = opponent_active;
            }
            const std::int64_t healed = target == nullptr
                ? 0 : heal_damage(*target, integer_arg(args, "amount"));
            if (healed > 0) {
                if (target_name != "opponent_active") {
                    self["healed_this_turn"] = Value(true);
                }
                append_healed_event(
                    result,
                    actor,
                    target_name == "opponent_active" ? 1 - actor : actor,
                    target_name == "opponent_active" ? "active" : source_slot,
                    healed
                );
            }
        } else if (op == "judge") {
            for (std::int32_t index : {0, 1}) {
                Value &target = player(result.state, index);
                Array &hand = required(target, "hand").as_array();
                Array &deck = required(target, "deck").as_array();
                const Array returned = hand;
                for (Value &entry : hand) {
                    deck.push_back(std::move(entry));
                }
                hand.clear();
                if (!returned.empty()) {
                    append_event(result, "card_moved", Object{
                        {"player", Value(index)},
                        {"card_ids", Value(returned)},
                        {"count", Value(static_cast<std::int64_t>(returned.size()))},
                        {"source_zone", Value("hand")},
                        {"target_zone", Value("deck")},
                        {"visibility", Value("owner")},
                    });
                    result.event_types.emplace_back("card_moved");
                }
                shuffle_array(deck, rng);
                append_event(result, "deck_shuffled", Object{
                    {"player", Value(index)},
                });
                result.event_types.emplace_back("deck_shuffled");
                const auto drawn = draw_cards(
                    target,
                    integer_arg(args, "draw", 4)
                );
                if (!drawn.empty()) {
                    append_event(result, "cards_drawn", Object{
                        {"player", Value(index)},
                        {"card_ids", Value(card_id_values(drawn))},
                        {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                        {"purpose", Value("judge")},
                        {"visibility", Value("owner")},
                    });
                    result.event_types.emplace_back("cards_drawn");
                }
            }
        } else if (
            op == "look_top_attach_energy"
            || op == "look_top_deck"
        ) {
            Array &deck = required(self, "deck").as_array();
            const std::int64_t count = std::min<std::int64_t>(
                integer_arg(args, "count"),
                static_cast<std::int64_t>(deck.size())
            );
            const std::int64_t first = static_cast<std::int64_t>(
                deck.size()
            ) - count;
            Array options = zone_options(
                cards_,
                self,
                actor,
                "deck",
                string_arg(args, "filter", "any"),
                first,
                static_cast<std::int64_t>(deck.size()) - 1,
                true
            );
            const std::int64_t take = std::min<std::int64_t>(
                integer_arg(args, "take", 1),
                static_cast<std::int64_t>(options.size())
            );
            const std::int64_t minimum = std::min<std::int64_t>(
                take,
                args.find("min_select") == nullptr
                    ? (
                        integer_arg(args, "take", 1) >= 99
                        ? 0
                        : 1
                    )
                    : integer_arg(args, "min_select")
            );
            const bool attach = op == "look_top_attach_energy";
            if (options.empty()) {
                Array returned;
                returned.reserve(static_cast<std::size_t>(count));
                for (
                    std::int64_t index = 0;
                    index < count && !deck.empty();
                    ++index
                ) {
                    returned.push_back(std::move(deck.back()));
                    deck.pop_back();
                }
                if (bool_arg(args, "shuffle_rest")) {
                    for (Value &entry : returned) {
                        deck.push_back(std::move(entry));
                    }
                    shuffle_array(deck, rng);
                    result.event_types.emplace_back("deck_shuffled");
                } else if (bool_arg(args, "rest_bottom", true)) {
                    for (Value &entry : returned) {
                        deck.insert(deck.begin(), std::move(entry));
                    }
                } else {
                    for (auto iterator = returned.rbegin();
                         iterator != returned.rend();
                         ++iterator) {
                        deck.push_back(std::move(*iterator));
                    }
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            suspend(
                pending_request(
                    attach ? "look_top_attach_energy" : "look_top",
                    actor,
                    minimum,
                    take,
                    false,
                    minimum <= 0,
                    std::move(options),
                    attach ? "look_top_attach_energy" : "look_top"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "mill_then_damage") {
            Array &deck = required(self, "deck").as_array();
            Array &discard = required(self, "discard").as_array();
            Array non_energy;
            Array revealed_cards;
            std::int64_t energy_count = 0;
            std::int64_t remaining = std::min<std::int64_t>(
                integer_arg(args, "mill_count", 5),
                static_cast<std::int64_t>(deck.size())
            );
            while (remaining-- > 0) {
                Value entry = std::move(deck.back());
                deck.pop_back();
                const std::string card_id = entry.string_or();
                const bool matched = card_is_energy(cards_, card_id);
                revealed_cards.emplace_back(Object{
                    {"card_id", Value(card_id)},
                    {"matched", Value(matched)},
                    {"destination", Value(Object{
                        {"player", Value(actor)},
                        {"zone", Value(matched ? "discard" : "deck")},
                    })},
                });
                if (matched) {
                    discard.push_back(std::move(entry));
                    ++energy_count;
                } else {
                    non_energy.push_back(std::move(entry));
                }
            }
            for (Value &entry : non_energy) {
                deck.push_back(std::move(entry));
            }
            shuffle_array(deck, rng);
            result.rng_state = rng.state();
            set_attack_damage(
                result.context,
                energy_count * integer_arg(args, "damage_per", 80),
                true
            );
            append_event(result, "cards_revealed", Object{
                {"player", Value(actor)},
                {"cards", Value(std::move(revealed_cards))},
                {"summary", Value(Object{
                    {"kind", Value("energy_damage")},
                    {"matched_count", Value(energy_count)},
                    {
                        "amount",
                        Value(energy_count * integer_arg(args, "damage_per", 80)),
                    },
                })},
            });
            result.event_types.emplace_back("cards_revealed");
            result.event_types.emplace_back("deck_shuffled");
        } else if (op == "place_counters_then_self_discard") {
            Array options = pokemon_options(
                opponent,
                1 - actor,
                true,
                true
            );
            if (options.size() == 1) {
                const std::string target_slot = string_arg(
                    options.front(), "slot");
                Value *target = pokemon(
                    opponent,
                    target_slot
                );
                if (
                    target != nullptr
                    && !(
                        context_mode == "attack"
                        && prevents_attack_effects(*target)
                    )
                ) {
                    const std::int64_t amount = integer_arg(
                        args, "counters", 2) * 10;
                    add_damage(
                        *target,
                        amount
                    );
                    const std::int64_t maximum_hp = pokemon_hp(
                        cards_,
                        *target
                    );
                    if (
                        maximum_hp > 0
                        && integer_arg(
                            *target,
                            "damage_counters"
                        ) * 10 >= maximum_hp
                        && target->find("pending_ko_source_kind") == nullptr
                    ) {
                        (*target)["pending_ko_source_kind"] = Value(
                            "damage_counters"
                        );
                    }
                    append_damage_feedback_event(
                        result,
                        "damage_counters_placed",
                        actor,
                        1 - actor,
                        target_slot,
                        amount
                    );
                }
                discard_pokemon(self, source_slot);
                if (
                    source_slot == "active"
                    && !pokemon_options(
                        self,
                        actor,
                        false,
                        true
                    ).empty()
                ) {
                    required(
                        result.state,
                        "pending_promotions"
                    ).as_array().emplace_back(actor);
                }
                result.event_types.emplace_back("cards_discarded");
            } else {
                suspend(
                    pending_request(
                        "place_counters_self_discard",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        std::move(options),
                        "place_counters_self_discard"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
            }
        } else if (op == "place_damage_counters") {
            if (source != nullptr) {
                const std::int64_t amount = integer_arg(args, "amount");
                const bool self_damage = string_arg(
                    args,
                    "damage_kind",
                    "damage_counters"
                ) == "self_damage";
                add_damage(*source, amount);
                const std::int64_t maximum_hp = pokemon_hp(cards_, *source);
                if (
                    maximum_hp > 0
                    && integer_arg(*source, "damage_counters") * 10
                        >= maximum_hp
                    && source->find("pending_ko_source_kind") == nullptr
                ) {
                    (*source)["pending_ko_source_kind"] = Value(
                        self_damage ? "attack_effect" : "damage_counters"
                    );
                }
                append_damage_feedback_event(
                    result,
                    self_damage ? "damage_dealt" : "damage_counters_placed",
                    actor,
                    actor,
                    source_slot,
                    amount
                );
            }
        } else if (
            op.rfind("register_", 0) == 0
        ) {
            if (source != nullptr) {
                append_modifier(*source, op, args);
            }
            result.modifier = modifier_probe(
                op,
                args,
                source,
                actor,
                source_slot
            );
        } else if (op == "recover_clara") {
            const std::int64_t pokemon_count = std::max<std::int64_t>(
                0,
                integer_arg(args, "pokemon_count", 2)
            );
            const std::int64_t energy_count = std::max<std::int64_t>(
                0,
                integer_arg(args, "energy_count", 2)
            );
            Value request = pending_request(
                    "clara",
                    actor,
                    0,
                    energy_count + pokemon_count,
                    false,
                    true,
                    zone_options(
                        cards_,
                        self,
                        actor,
                        "discard",
                        "pokemon_and_energy"
                    ),
                    "clara"
                );
            request["metadata"] = Value(Object{
                {"category_limits", Value(Object{
                    {"energy", Value(energy_count)},
                    {"pokemon", Value(pokemon_count)},
                })},
                {"domain", Value("recover")},
                {"energy_count", Value(energy_count)},
                {"pokemon_count", Value(pokemon_count)},
                {"purpose", Value("clara")},
            });
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "relocate_energy") {
            const std::string filter = string_arg(
                args,
                "energy_type",
                string_arg(args, "filter", "any")
            );
            Array board = pokemon_options(self, actor, true, true);
            struct RelocateSource {
                std::string slot;
                Value option;
                Array attachments;
            };
            std::vector<RelocateSource> sources;
            for (const Value &option : board) {
                const std::string slot = string_arg(option, "slot");
                Value *candidate = pokemon(self, slot);
                if (
                    candidate == nullptr
                    || (
                        bool_arg(args, "from_self")
                        && slot != source_slot
                    )
                ) {
                    continue;
                }
                Array attachments;
                const Array &energy = required(
                    *candidate,
                    "energy_card_ids"
                ).as_array();
                for (
                    std::size_t index = 0;
                    index < energy.size();
                    ++index
                ) {
                    if (attached_energy_card_matches(
                        cards_,
                        *candidate,
                        index,
                        filter
                    )) {
                        attachments.push_back(attachment_option(
                            energy[index].string_or(),
                            actor,
                            slot,
                            static_cast<std::int64_t>(index)
                        ));
                    }
                }
                if (!attachments.empty()) {
                    sources.push_back(RelocateSource{
                        slot,
                        option,
                        std::move(attachments),
                    });
                }
            }
            if (sources.empty() || board.size() <= 1) {
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            if (sources.size() > 1) {
                Array options;
                for (const RelocateSource &entry : sources) {
                    options.push_back(entry.option);
                }
                Value continued = make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot,
                    -1
                );
                suspend(
                    pending_request(
                        "distribute_energy",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        std::move(options),
                        "energy_relocate_source"
                    ),
                    std::move(continued)
                );
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            const RelocateSource &only = sources.front();
            const std::int64_t amount = std::min<std::int64_t>(
                integer_arg(args, "amount", 1),
                static_cast<std::int64_t>(only.attachments.size())
            );
            const bool optional_count = args.find("min_select") != nullptr
                || bool_arg(args, "optional");
            const std::int64_t minimum = optional_count
                ? std::min(
                    amount,
                    integer_arg(args, "min_select")
                )
                : amount;
            const bool exact_choice = minimum < amount
                || static_cast<std::int64_t>(only.attachments.size())
                    > amount;
            Value continued = make_continuation(
                op,
                command_spec,
                actor,
                only.slot,
                0
            );
            Array options;
            std::string request_type;
            std::string continuation_kind;
            if (exact_choice) {
                options = only.attachments;
                request_type = "select_attachment";
                continuation_kind = "energy_relocate_attachments";
            } else {
                for (const Value &target : board) {
                    if (string_arg(target, "slot") == only.slot) {
                        continue;
                    }
                    options.push_back(target);
                }
                request_type = "distribute_energy";
                continuation_kind = "energy_relocate_distribution";
                continued["stage"] = Value(1);
                continued["selected_attachments"] = Value(
                    only.attachments
                );
            }
            suspend(
                pending_request(
                    request_type,
                    actor,
                    minimum,
                    amount,
                    request_type == "distribute_energy" && amount > 1,
                    minimum == 0,
                    std::move(options),
                    continuation_kind
                ),
                std::move(continued)
            );
        } else if (op == "return_to_hand") {
            return_pokemon_to_hand(self, source_slot);
            result.event_types.emplace_back("card_moved");
        } else if (
            op == "search_any_and_switch"
            || op == "search_cards"
            || op == "search_item_and_tool"
        ) {
            std::string request_type;
            std::string continuation_kind;
            std::string filter;
            std::int64_t minimum = 0;
            std::int64_t maximum = 1;
            bool can_cancel = false;
            if (op == "search_any_and_switch") {
                request_type = "search_any_switch";
                continuation_kind = "search_any_switch";
                filter = "any";
                minimum = integer_arg(args, "min_select");
                maximum = integer_arg(args, "count", 2);
                can_cancel = true;
            } else if (op == "search_cards") {
                request_type = "search_move";
                continuation_kind = "search_move";
                filter = string_arg(args, "filter", "any");
                minimum = integer_arg(args, "min_select", 1);
                maximum = integer_arg(args, "count", 1);
                can_cancel = minimum == 0;
            } else {
                request_type = "arven";
                continuation_kind = "arven";
                filter = "item_or_tool";
                minimum = 1;
                maximum = 2;
            }
            const std::string source_zone = op == "search_cards"
                ? string_arg(args, "from_zone", "deck")
                : "deck";
            if (source_zone == "deck") {
                if (op == "search_item_and_tool") {
                    minimum = 0;
                    can_cancel = false;
                } else if (op == "search_cards") {
                    if (filter != "any") {
                        minimum = 0;
                    }
                    // A zero-card hidden search resolves the effect. It must
                    // not roll back a Trainer or a cost that was already paid.
                    can_cancel = minimum == 0 && context_mode != "trainer";
                }
            }
            Array options = zone_options(
                cards_,
                self,
                actor,
                source_zone,
                filter,
                0,
                std::numeric_limits<std::int64_t>::max(),
                false,
                op == "search_cards"
                    ? string_arg(args, "filter_name")
                    : std::string{}
            );
            if (
                op == "search_cards"
                && string_arg(args, "destination", "hand") == "bench"
            ) {
                maximum = std::min<std::int64_t>(
                    maximum,
                    std::max<std::int64_t>(
                        0,
                        5 - static_cast<std::int64_t>(
                            bench_count(self)
                        )
                    )
                );
            }
            if (options.empty()) {
                if (source_zone == "deck") {
                    shuffle_array(
                        required(self, "deck").as_array(),
                        rng
                    );
                    result.event_types.emplace_back("deck_shuffled");
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            if (maximum <= 0) {
                if (source_zone == "deck") {
                    shuffle_array(
                        required(self, "deck").as_array(),
                        rng
                    );
                    result.event_types.emplace_back("deck_shuffled");
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            maximum = std::min<std::int64_t>(
                maximum,
                static_cast<std::int64_t>(options.size())
            );
            minimum = std::min(minimum, maximum);
            Value request = pending_request(
                request_type,
                actor,
                minimum,
                maximum,
                false,
                can_cancel,
                std::move(options),
                continuation_kind
            );
            if (op == "search_item_and_tool") {
                request["metadata"] = Value(Object{
                    {"category_limits", Value(Object{
                        {"item", Value(1)},
                        {"tool", Value(1)},
                    })},
                    {"domain", Value("search")},
                    {"purpose", Value("arven")},
                });
            }
            suspend(
                std::move(request),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "set_attack_damage_formula") {
            std::int64_t total = integer_arg(args, "base");
            const Value *condition_bonus = args.find("condition_bonus");
            if (
                condition_bonus != nullptr
                && condition_bonus->is_object()
                && condition_applies(
                    cards_,
                    result.state,
                    actor,
                    string_arg(*condition_bonus, "condition")
                )
            ) {
                total += integer_arg(*condition_bonus, "bonus");
            }
            total += bench_count(self)
                * integer_arg(args, "per_own_bench");
            if (source != nullptr) {
                total += get_integer(*source, "damage_counters")
                    * integer_arg(args, "per_self_damage_counter");
                const std::string energy_type = string_arg(
                    args,
                    "per_self_energy_type"
                );
                if (!energy_type.empty()) {
                    total += energy_units(cards_, source, energy_type)
                        * integer_arg(args, "per_energy");
                }
            }
            set_attack_damage(result.context, total, false);
        } else if (op == "set_attack_flags") {
            for (const std::string &key : {
                "ignore_weakness",
                "ignore_resistance",
                "ignore_defender_damage_effects",
            }) {
                if (bool_arg(args, key)) {
                    result.context[key] = Value(true);
                }
            }
        } else if (op == "shuffle_from_discard_to_deck") {
            const Array options = zone_options(
                cards_,
                self,
                actor,
                "discard",
                string_arg(args, "filter", "any")
            );
            suspend(
                pending_request(
                    "shuffle_from_discard",
                    actor,
                    std::min<std::int64_t>(
                        1,
                        static_cast<std::int64_t>(options.size())
                    ),
                    std::min<std::int64_t>(
                        integer_arg(args, "count", 1),
                        static_cast<std::int64_t>(options.size())
                    ),
                    false,
                    true,
                    options,
                    "shuffle_from_discard"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "shuffle_then_draw_cards") {
            Array &hand = required(self, "hand").as_array();
            Array &deck = required(self, "deck").as_array();
            if (bool_arg(args, "shuffle_hand")) {
                const Array returned = hand;
                for (Value &entry : hand) {
                    deck.push_back(std::move(entry));
                }
                hand.clear();
                if (!returned.empty()) {
                    append_event(result, "card_moved", Object{
                        {"player", Value(actor)},
                        {"card_ids", Value(returned)},
                        {"count", Value(static_cast<std::int64_t>(returned.size()))},
                        {"source_zone", Value("hand")},
                        {"target_zone", Value("deck")},
                        {"visibility", Value("owner")},
                    });
                    result.event_types.emplace_back("card_moved");
                }
                shuffle_array(deck, rng);
                result.event_types.emplace_back("deck_shuffled");
            }
            const auto drawn = draw_cards(
                self,
                integer_arg(args, "draw", 5)
            );
            if (!drawn.empty()) {
                append_event(result, "cards_drawn", Object{
                    {"player", Value(actor)},
                    {"card_ids", Value(card_id_values(drawn))},
                    {"count", Value(static_cast<std::int64_t>(drawn.size()))},
                    {"purpose", Value("shuffle_then_draw")},
                    {"visibility", Value("owner")},
                });
                result.event_types.emplace_back("cards_drawn");
            }
        } else if (op == "switch_pokemon") {
            const bool opponent_target = string_arg(
                args,
                "target",
                "self"
            ) == "opponent";
            const bool optional = bool_arg(args, "optional");
            const bool controller_chooses = bool_arg(args, "you_choose");
            Value &target = opponent_target ? opponent : self;
            Array options = pokemon_options(
                target,
                opponent_target ? 1 - actor : actor,
                false,
                true
            );
            if (options.empty()) {
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            if (optional) {
                suspend(
                    pending_request(
                        "confirm",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        {
                            id_option("confirm:yes"),
                            id_option("confirm:no"),
                        },
                        "switch_confirm"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot
                    )
                );
            } else if (
                options.size() == 1
                && !(opponent_target && controller_chooses)
            ) {
                switch_active_with_event(
                    result,
                    target,
                    actor,
                    opponent_target ? 1 - actor : actor,
                    string_arg(options.front(), "slot"),
                    "switch_pokemon"
                );
            } else {
                const std::int32_t chooser = (
                    opponent_target && !controller_chooses
                ) ? 1 - actor : actor;
                suspend(
                    pending_request(
                        opponent_target && controller_chooses
                            ? "select_opponent_bench"
                            : "select_bench",
                        chooser,
                        1,
                        1,
                        false,
                        false,
                        std::move(options),
                        "switch"
                    ),
                    make_continuation(
                        op,
                        command_spec,
                        actor,
                        source_slot,
                        1
                    )
                );
            }
        } else if (op == "trekking_shoes") {
            suspend(
                pending_request(
                    "confirm",
                    actor,
                    1,
                    1,
                    false,
                    false,
                    {id_option("confirm:yes"), id_option("confirm:no")},
                    "trekking_shoes"
                ),
                make_continuation(
                    op,
                    command_spec,
                    actor,
                    source_slot
                )
            );
        } else if (op == "trigger_place_damage_counters") {
            const std::int32_t target_owner = static_cast<std::int32_t>(
                integer_arg(args, "player", actor));
            const std::string target_slot = string_arg(
                args, "slot", "active");
            Value &target_player = player(
                result.state,
                target_owner
            );
            if (
                Value *target = pokemon(
                    target_player,
                    target_slot
                )
            ) {
                const std::int64_t amount = integer_arg(args, "count") * 10;
                add_damage(*target, amount);
                append_damage_feedback_event(
                    result,
                    "damage_counters_placed",
                    actor,
                    target_owner,
                    target_slot,
                    amount
                );
            }
        } else if (op == "trigger_move_basic_energy") {
            Value &from_player = player(
                result.state,
                static_cast<std::int32_t>(
                    integer_arg(args, "from_player", actor)
                )
            );
            Value &to_player = player(
                result.state,
                static_cast<std::int32_t>(
                    integer_arg(args, "to_player", actor)
                )
            );
            Value *from = pokemon(
                from_player,
                string_arg(args, "from_slot", "active")
            );
            Value *to = pokemon(
                to_player,
                string_arg(args, "to_slot", "active")
            );
            if (from != nullptr && to != nullptr) {
                Array &source_energy = required(
                    *from,
                    "energy_card_ids"
                ).as_array();
                Array &target_energy = required(
                    *to,
                    "energy_card_ids"
                ).as_array();
                const auto found = std::find_if(
                    source_energy.begin(),
                    source_energy.end(),
                    [this](const Value &entry) {
                        return card_matches_energy(
                            cards_,
                            entry.string_or(),
                            "basic"
                        );
                    }
                );
                if (found != source_energy.end()) {
                    target_energy.push_back(std::move(*found));
                    source_energy.erase(found);
                    result.event_types.emplace_back("energy_attached");
                }
            }
        } else if (op == "trigger_switch_with_active") {
            Value &target_player = player(
                result.state,
                static_cast<std::int32_t>(
                    integer_arg(args, "player", actor)
                )
            );
            Array &bench = required(target_player, "bench").as_array();
            const std::size_t index = static_cast<std::size_t>(
                integer_arg(args, "bench_idx")
            );
            Value &active = required(target_player, "active");
            if (
                index < bench.size()
                && active.is_object()
                && bench[index].is_object()
            ) {
                const std::int32_t target_owner = static_cast<std::int32_t>(
                    integer_arg(args, "player", actor)
                );
                switch_active_with_event(
                    result,
                    target_player,
                    actor,
                    target_owner,
                    "bench_" + std::to_string(index),
                    "trigger_switch_with_active"
                );
            }
        } else if (op == "zinnia_resolve") {
            Array &hand = required(self, "hand").as_array();
            const std::int64_t draw_amount = (
                pokemon(opponent, "active") == nullptr ? 0 : 1
            ) + static_cast<std::int64_t>(
                pokemon_options(
                    opponent,
                    1 - actor,
                    false,
                    true
                ).size()
            );
            if (hand.size() == 2) {
                Array &discard = required(self, "discard").as_array();
                Array discarded_ids;
                discarded_ids.reserve(hand.size());
                for (Value &entry : hand) {
                    discarded_ids.emplace_back(entry.string_or());
                    discard.push_back(std::move(entry));
                }
                hand.clear();
                const auto drawn = draw_cards(self, draw_amount);
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
                append_cards_drawn_event(
                    result, actor, drawn, "zinnia");
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            Value continued = make_continuation(
                op,
                command_spec,
                actor,
                source_slot
            );
            continued["draw_amount"] = Value(draw_amount);
            suspend(
                pending_request(
                    "zinnia",
                    actor,
                    2,
                    2,
                    false,
                    false,
                    zone_options(
                        cards_,
                        self,
                        actor,
                        "hand",
                        "any"
                    ),
                    "zinnia"
                ),
                std::move(continued)
            );
        }
        if (!result.pending.as_object().empty()) {
            result.continuation["context_mode"] = Value(context_mode);
        }
        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    result.rng_state = rng.state();
    return result;
}

VmExecutionResult NativeRulesKernel::resume(
    Value state,
    Value context,
    const Value &continuation,
    const Value &selected_options,
    bool cancelled,
    std::uint32_t rng_state
) const {
    VmExecutionResult result;
    result.state = std::move(state);
    result.context = std::move(context);
    XorShift32 rng(rng_state);
    result.rng_state = rng.state();
    if (
        !continuation.is_object()
        || !selected_options.is_array()
    ) {
        result.error_code = "invalid_native_continuation";
        return result;
    }

    const std::string op = string_arg(continuation, "op");
    const std::int32_t actor = static_cast<std::int32_t>(
        integer_arg(continuation, "actor", -1)
    );
    const std::string source_slot = string_arg(
        continuation,
        "source_slot",
        "active"
    );
    const std::int64_t stage = integer_arg(continuation, "stage");
    const Value *spec = continuation.find("command_spec");
    if (
        actor != 0
        && actor != 1
    ) {
        result.error_code = "invalid_actor";
        return result;
    }
    if (spec == nullptr || !spec->is_object() || !supports(op)) {
        result.error_code = "invalid_native_continuation_op";
        return result;
    }
    const Value *args_ptr = spec->find("args");
    const Value empty_args = Value::make_object();
    const Value &args = (
        args_ptr != nullptr && args_ptr->is_object()
    ) ? *args_ptr : empty_args;

    try {
        Value &self = player(result.state, actor);
        Value &opponent = player(result.state, 1 - actor);
        auto next = [&result](Value request, Value next_continuation) {
            increment_integer(result.state, "choice_sequence");
            result.pending = std::move(request);
            result.continuation = std::move(next_continuation);
        };

        increment_integer(result.state, "revision");
        if (
            cancelled
            && op != "search_any_and_switch"
            && op != "look_top_attach_energy"
            && op != "look_top_deck"
        ) {
            if (
                (
                    op == "attach_energy"
                    && string_arg(args, "from_zone", "hand") == "deck"
                )
                || (
                    op == "search_cards"
                    && string_arg(args, "from_zone", "deck") == "deck"
                )
            ) {
                shuffle_array(
                    required(self, "deck").as_array(),
                    rng
                );
                result.event_types.emplace_back("deck_shuffled");
            }
            result.success = true;
            result.rng_state = rng.state();
            return result;
        }

        if (op == "attach_energy") {
            const std::string from_zone = string_arg(
                args,
                "from_zone",
                "hand"
            );
            Array &source_cards = required(self, from_zone).as_array();
            const std::string filter = string_arg(
                args,
                "filter",
                "any"
            );
            const bool distribution = bool_arg(
                continuation,
                "distribution"
            );
            if (selected_options.as_array().empty()) {
                const bool optional_choice = bool_arg(args, "optional")
                    || args.find("min_select") != nullptr
                    || (
                        integer_arg(args, "going_second_bonus")
                            > integer_arg(args, "amount", 1)
                        && actor
                            != integer_arg(
                                result.state,
                                "first_player_idx",
                                -1
                            )
                        && integer_arg(result.state, "turn_number") == 2
                    );
                if (!optional_choice) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                if (from_zone == "deck") {
                    shuffle_array(source_cards, rng);
                    result.event_types.emplace_back("deck_shuffled");
                }
                result.success = true;
                result.rng_state = rng.state();
                return result;
            }
            std::int64_t remaining = integer_arg(
                continuation,
                "effective_amount",
                integer_arg(args, "amount", 1)
            );
            if (distribution) {
                remaining = std::min<std::int64_t>(
                    remaining,
                    static_cast<std::int64_t>(
                        selected_options.as_array().size()
                    )
                );
            }
            std::size_t selection_index = 0;
            const std::string target_kind = string_arg(
                args,
                "to",
                source_slot
            );
            const bool same_target = bool_arg(args, "same_target")
                || target_kind == "any"
                || target_kind == "self_basic";
            const std::int64_t max_per_target = std::max<std::int64_t>(
                0,
                target_kind == "bench"
                    ? integer_arg(args, "max_per_target", 99)
                    : integer_arg(
                        continuation,
                        "effective_amount",
                        integer_arg(args, "amount", 1)
                    )
            );
            if (distribution) {
                validate_energy_distribution_selection(
                    selected_options.as_array(),
                    same_target,
                    max_per_target
                );
            }
            const std::string forced_target_slot = (
                distribution
                && same_target
                && !selected_options.as_array().empty()
            ) ? string_arg(
                selected_options.as_array().front(),
                "slot"
            ) : std::string{};
            while (remaining-- > 0) {
                const Value &selected = distribution
                    ? selected_options.as_array().at(selection_index++)
                    : selected_options.as_array().front();
                const std::string selected_target_slot =
                    forced_target_slot.empty()
                    ? string_arg(selected, "slot")
                    : forced_target_slot;
                Value *target = pokemon(
                    self,
                    selected_target_slot
                );
                if (target == nullptr) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                const auto energy = std::find_if(
                    source_cards.begin(),
                    source_cards.end(),
                    [this, &filter, &selected](const Value &entry) {
                        const std::string selected_id =
                            energy_option_card_id(selected);
                        return card_matches_energy(
                            cards_,
                            entry.string_or(),
                            filter
                        ) && (
                            selected_id.empty()
                            || entry.string_or() == selected_id
                        );
                    }
                );
                if (energy == source_cards.end()) {
                    throw std::invalid_argument(
                        "energy_attachment_source_missing"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(*energy));
                source_cards.erase(energy);
                result.event_types.emplace_back("energy_attached");
            }
            if (from_zone == "deck") {
                shuffle_array(source_cards, rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (op == "discard_then_draw_cards") {
            const std::int64_t discard_amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "discard_amount", 1)
            );
            if (
                selected_options.as_array().empty()
                || static_cast<std::int64_t>(
                    selected_options.as_array().size()
                ) > discard_amount
            ) {
                throw std::invalid_argument(
                    "discard_hand_selection_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                "hand",
                actor
            );
            Array discarded_ids = selected_card_id_values(
                selected_options);
            const std::size_t removed = discard_selected(
                self,
                "hand",
                selected_options
            );
            if (removed != selected_options.as_array().size()) {
                throw std::invalid_argument(
                    "discard_hand_selection_out_of_range"
                );
            }
            if (removed > 0) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
            }
            const auto drawn = draw_cards(
                self,
                integer_arg(
                    args,
                    "draw_amount",
                    integer_arg(args, "draw", 7)
                )
            );
            append_cards_drawn_event(
                result, actor, drawn, "discard_then_draw");
        } else if (op == "attach_energy_from_discard") {
            Array &discard = required(self, "discard").as_array();
            const std::string filter = string_arg(
                args,
                "energy_type",
                "basic"
            );
            const Array &targets = selected_options.as_array();
            const bool same_target = bool_arg(args, "same_target")
                || string_arg(args, "target", "self") == "self"
                || string_arg(args, "target", "self") == "self_or_bench"
                || (
                    !targets.empty()
                    && std::all_of(
                        targets.begin(),
                        targets.end(),
                        [&targets](const Value &entry) {
                            return string_arg(entry, "slot")
                                == string_arg(targets.front(), "slot");
                        }
                    )
                );
            validate_energy_distribution_selection(
                targets,
                same_target,
                same_target
                    ? std::max<std::int64_t>(
                        0,
                        integer_arg(args, "amount", 1)
                    )
                    : 99
            );
            const std::string forced_target_slot = (
                same_target && !targets.empty()
            ) ? string_arg(targets.front(), "slot") : std::string{};
            for (std::size_t index = 0; index < targets.size(); ++index) {
                const std::string slot = forced_target_slot.empty()
                    ? string_arg(targets[index], "slot")
                    : forced_target_slot;
                Value *target = pokemon(self, slot);
                if (target == nullptr) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                const std::string selected_id =
                    energy_option_card_id(targets[index]);
                const auto source = std::find_if(
                    discard.begin(),
                    discard.end(),
                    [this, &filter, &selected_id](const Value &entry) {
                        return card_matches_energy(
                            cards_,
                            entry.string_or(),
                            filter
                        ) && (
                            selected_id.empty()
                            || entry.string_or() == selected_id
                        );
                    }
                );
                if (source == discard.end()) {
                    throw std::invalid_argument(
                        "energy_attachment_source_missing"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(*source));
                discard.erase(source);
                result.event_types.emplace_back("energy_attached");
            }
        } else if (op == "deal_bench_damage") {
            const bool targets_self = string_arg(
                args,
                "player",
                "opponent"
            ) == "self";
            const std::int32_t target_owner = targets_self
                ? actor
                : 1 - actor;
            Value &target_player = targets_self ? self : opponent;
            const std::int64_t expected_count = std::min<std::int64_t>(
                std::max<std::int64_t>(
                    0,
                    integer_arg(args, "count", 1)
                ),
                static_cast<std::int64_t>(
                    pokemon_options(
                        target_player,
                        target_owner,
                        false,
                        true
                    ).size()
                )
            );
            if (
                expected_count <= 0
                || selected_options.as_array().size()
                    != static_cast<std::size_t>(expected_count)
            ) {
                throw std::invalid_argument(
                    "bench_damage_selection_invalid"
                );
            }
            std::unordered_set<std::string> selected_slots;
            const std::int64_t amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "amount")
            );
            for (const Value &selected : selected_options.as_array()) {
                const std::string slot = string_arg(selected, "slot");
                Value *target = pokemon(target_player, slot);
                if (
                    slot.rfind("bench_", 0) != 0
                    || !selected_slots.insert(slot).second
                    || target == nullptr
                    || integer_arg(selected, "player", target_owner)
                        != target_owner
                    || (
                        !string_arg(selected, "card_id").empty()
                        && string_arg(selected, "card_id")
                            != string_arg(*target, "card_id")
                    )
                ) {
                    throw std::invalid_argument(
                        "bench_damage_selection_invalid"
                    );
                }
                if (
                    string_arg(continuation, "context_mode")
                        == "attack"
                ) {
                    Value *packets = result.context.find(
                        "damage_packets"
                    );
                    if (packets == nullptr || !packets->is_array()) {
                        result.context["damage_packets"] =
                            Value::make_array();
                        packets = result.context.find("damage_packets");
                    }
                    packets->as_array().emplace_back(Object{
                        {"target_player", Value(target_owner)},
                        {"target_slot", Value(slot)},
                        {"amount", Value(amount)},
                    });
                } else {
                    std::int64_t applied = amount;
                    if (bool_arg(*target, "damage_prevented")) {
                        applied = 0;
                    }
                    add_damage(*target, applied);
                    append_damage_feedback_event(
                        result,
                        "damage_dealt",
                        actor,
                        target_owner,
                        slot,
                        applied
                    );
                    const std::int64_t maximum_hp = pokemon_hp(
                        cards_,
                        *target
                    );
                    if (
                        maximum_hp > 0
                        && integer_arg(
                            *target,
                            "damage_counters"
                        ) * 10 >= maximum_hp
                        && target->find("pending_ko_source_kind") == nullptr
                    ) {
                        (*target)["pending_ko_source_kind"] = Value(
                            "attack_effect"
                        );
                    }
                }
            }
        } else if (
            op == "choose_damage_target"
            || op == "choose_heal_damage"
        ) {
            const bool damage = op == "choose_damage_target";
            Value &target_player = damage ? opponent : self;
            const std::string target_slot = selected_slot(
                selected_options
            );
            Value *target = pokemon(
                target_player,
                target_slot
            );
            if (target == nullptr) {
                throw std::invalid_argument("selected_target_missing");
            }
            if (damage) {
                std::int64_t amount = std::max<std::int64_t>(
                    0,
                    integer_arg(args, "amount")
                );
                if (
                    string_arg(continuation, "context_mode") == "attack"
                ) {
                    Value *packets = result.context.find("damage_packets");
                    if (packets == nullptr || !packets->is_array()) {
                        result.context["damage_packets"] = Value::make_array();
                        packets = result.context.find("damage_packets");
                    }
                    packets->as_array().emplace_back(Object{
                        {"target_player", Value(1 - actor)},
                        {"target_slot", Value(target_slot)},
                        {"amount", Value(amount)},
                    });
                } else {
                    if (bool_arg(*target, "damage_prevented")) {
                        amount = 0;
                    }
                    add_damage(*target, amount);
                    append_damage_feedback_event(
                        result,
                        "damage_dealt",
                        actor,
                        1 - actor,
                        target_slot,
                        amount
                    );
                    const std::int64_t maximum_hp = pokemon_hp(
                        cards_,
                        *target
                    );
                    if (
                        maximum_hp > 0
                        && integer_arg(
                            *target,
                            "damage_counters"
                        ) * 10 >= maximum_hp
                        && target->find("pending_ko_source_kind") == nullptr
                    ) {
                        (*target)["pending_ko_source_kind"] = Value(
                            "attack_effect"
                        );
                    }
                }
            } else {
                const std::int64_t healed = heal_damage(
                    *target, integer_arg(args, "amount", 30));
                if (healed > 0) {
                    self["healed_this_turn"] = Value(true);
                    append_healed_event(
                        result, actor, actor, target_slot, healed);
                }
            }
        } else if (op == "conditional") {
            if (stage == 0) {
                if (selected_options.as_array().size() != 2) {
                    throw std::invalid_argument(
                        "conditional_cost_selection_count_invalid"
                    );
                }
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "hand",
                    actor
                );
                Array discarded_ids = selected_card_id_values(
                    selected_options);
                const std::size_t removed = discard_selected(
                    self,
                    "hand",
                    selected_options
                );
                if (removed > 0) {
                    append_card_zone_event(
                        result,
                        "cards_discarded",
                        actor,
                        std::move(discarded_ids),
                        "hand",
                        "discard",
                        "public"
                    );
                }
                Array options = zone_options(
                    cards_,
                    self,
                    actor,
                    "deck",
                    "pokemon"
                );
                if (options.empty()) {
                    shuffle_array(
                        required(self, "deck").as_array(),
                        rng
                    );
                    result.event_types.emplace_back("deck_shuffled");
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                Value continued = continuation;
                continued["stage"] = Value(1);
                next(
                    pending_request(
                        "search_move",
                        actor,
                        0,
                        1,
                        false,
                        false,
                        std::move(options),
                        "search_move"
                    ),
                    std::move(continued)
                );
            } else {
                if (selected_options.as_array().size() > 1) {
                    throw std::invalid_argument(
                        "conditional_search_selection_count_invalid"
                    );
                }
                for (const std::string &selected_id : selected_zone_card_ids(
                    self,
                    selected_options,
                    "deck",
                    actor
                )) {
                    if (!card_is_pokemon(cards_, selected_id)) {
                        throw std::invalid_argument(
                            "conditional_search_selection_invalid"
                        );
                    }
                }
                std::vector<Value> removed = remove_selected(
                    self,
                    "deck",
                    selected_options
                );
                Array selected_ids = card_id_values(removed);
                Array &hand = required(self, "hand").as_array();
                for (Value &entry : removed) {
                    hand.push_back(std::move(entry));
                }
                append_card_zone_event(
                    result,
                    "cards_selected",
                    actor,
                    std::move(selected_ids),
                    "deck",
                    "hand",
                    "public"
                );
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (
            op == "conditional_search"
            || op == "search_cards"
            || op == "search_item_and_tool"
        ) {
            std::vector<Value> removed;
            if (op == "search_item_and_tool") {
                const std::vector<std::string> selected_ids =
                    selected_zone_card_ids(
                        self,
                        selected_options,
                        "deck",
                        actor
                    );
                if (selected_ids.size() > 2) {
                    throw std::invalid_argument(
                        "arven_selection_count_exceeded"
                    );
                }
                std::int64_t item_count = 0;
                std::int64_t tool_count = 0;
                for (const std::string &selected_id : selected_ids) {
                    const Value *definition = card_definition(
                        cards_, selected_id);
                    const std::string kind = definition == nullptr
                        ? std::string{}
                        : lower_ascii(string_arg(
                            *definition,
                            "trainer_type"
                        ));
                    if (kind == "item") {
                        ++item_count;
                    } else if (kind == "tool") {
                        ++tool_count;
                    } else {
                        throw std::invalid_argument(
                            "arven_selection_category_invalid"
                        );
                    }
                }
                if (item_count > 1 || tool_count > 1) {
                    throw std::invalid_argument(
                        "arven_category_limit_exceeded"
                    );
                }
                removed = remove_selected(
                    self,
                    "deck",
                    selected_options
                );
            } else {
                const std::string source_zone = op == "search_cards"
                    ? string_arg(args, "from_zone", "deck")
                    : "deck";
                const std::string filter = string_arg(args, "filter", "any");
                const std::string filter_name = op == "search_cards"
                    ? string_arg(args, "filter_name")
                    : std::string{};
                const std::vector<std::string> selected_ids =
                    selected_zone_card_ids(
                        self,
                        selected_options,
                        source_zone,
                        actor
                    );
                std::int64_t maximum = integer_arg(args, "count", 1);
                if (op == "conditional_search") {
                    const bool going_second_first_turn = (
                        actor != integer_arg(
                            result.state, "first_player_idx")
                        && actor == integer_arg(
                            result.state, "active_player_idx")
                        && integer_arg(result.state, "turn_number") == 2
                    );
                    maximum = going_second_first_turn
                        ? integer_arg(args, "max_count", 3)
                        : integer_arg(args, "default_count", 1);
                }
                if (
                    selected_ids.size()
                    > static_cast<std::size_t>(
                        std::max<std::int64_t>(0, maximum))
                ) {
                    throw std::invalid_argument(
                        "search_selection_count_exceeded"
                    );
                }
                for (const std::string &selected_id : selected_ids) {
                    const Value *definition = card_definition(
                        cards_, selected_id);
                    if (
                        !card_matches_filter(cards_, selected_id, filter)
                        || (
                            !filter_name.empty()
                            && (
                                definition == nullptr
                                || string_arg(*definition, "name")
                                    != filter_name
                            )
                        )
                    ) {
                        throw std::invalid_argument(
                            "search_selection_filter_mismatch"
                        );
                    }
                }
                if (
                    op == "search_cards"
                    && string_arg(args, "destination", "hand") == "bench"
                    && selected_options.as_array().size()
                        > static_cast<std::size_t>(
                            std::max<std::int64_t>(0, 5 - bench_count(self))
                        )
                ) {
                    throw std::invalid_argument(
                        "bench_destination_capacity_exceeded"
                    );
                }
                removed = remove_selected(
                    self,
                    source_zone,
                    selected_options
                );
            }
            const std::string destination = op == "search_cards"
                ? string_arg(args, "destination", "hand")
                : "hand";
            if (destination == "bench") {
                Array &bench = required(self, "bench").as_array();
                for (Value &entry : removed) {
                    const auto empty = std::find_if(
                        bench.begin(),
                        bench.end(),
                        [](const Value &value) { return value.is_null(); }
                    );
                    if (empty == bench.end()) {
                        break;
                    }
                    *empty = new_pokemon(cards_, entry.string_or());
                    result.event_types.emplace_back("card_moved");
                }
            } else {
                Array selected_ids = card_id_values(removed);
                Array &hand = required(self, "hand").as_array();
                for (Value &entry : removed) {
                    hand.push_back(std::move(entry));
                }
                const std::string source_zone = op == "search_cards"
                    ? string_arg(args, "from_zone", "deck")
                    : "deck";
                const bool public_identity = source_zone == "discard"
                    || op == "conditional_search"
                    || op == "search_item_and_tool"
                    || bool_arg(args, "reveal");
                append_card_zone_event(
                    result,
                    "cards_selected",
                    actor,
                    std::move(selected_ids),
                    source_zone,
                    "hand",
                    public_identity ? "public" : "owner"
                );
            }
            if (
                op != "search_cards"
                || string_arg(args, "from_zone", "deck") == "deck"
            ) {
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
            }
        } else if (op == "discard_cards") {
            const std::string zone = string_arg(
                args,
                "from",
                string_arg(args, "from_zone", "hand")
            );
            const std::int64_t amount = std::max<std::int64_t>(
                0,
                integer_arg(args, "amount", 1)
            );
            if (
                selected_options.as_array().size()
                != static_cast<std::size_t>(amount)
            ) {
                throw std::invalid_argument(
                    "discard_selection_count_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                zone,
                actor
            );
            Array discarded_ids = selected_card_id_values(
                selected_options);
            const std::size_t removed = discard_selected(
                self,
                zone,
                selected_options
            );
            if (removed > 0) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    zone,
                    "discard",
                    "public"
                );
            }
        } else if (op == "discard_energy") {
            const bool own = string_arg(args, "from", "self") == "self";
            Value &owner = own ? self : opponent;
            const std::int32_t owner_index = own ? actor : 1 - actor;
            Value *target = pokemon(owner, "active");
            if (target == nullptr) {
                throw std::invalid_argument("energy_discard_target_missing");
            }
            Array &energy = required(*target, "energy_card_ids").as_array();
            const std::string filter = string_arg(args, "filter", "any");
            const std::int64_t matching_count = static_cast<std::int64_t>(
                std::count_if(
                    energy.begin(),
                    energy.end(),
                    [this, target, &energy, &filter](const Value &entry) {
                        const std::size_t index = static_cast<std::size_t>(
                            &entry - energy.data()
                        );
                        return attached_energy_card_matches(
                            cards_, *target, index, filter);
                    }
                )
            );
            const std::int64_t expected_count = std::min<std::int64_t>(
                std::max<std::int64_t>(0, integer_arg(args, "amount", 1)),
                matching_count
            );
            if (
                selected_options.as_array().size()
                != static_cast<std::size_t>(expected_count)
            ) {
                throw std::invalid_argument(
                    "energy_discard_selection_count_invalid"
                );
            }
            std::vector<std::size_t> indices;
            for (const Value &entry : selected_options.as_array()) {
                const std::int64_t raw_index = integer_arg(
                    entry, "index", -1);
                if (
                    !entry.is_object()
                    || string_arg(entry, "kind") != "attachment"
                    || string_arg(entry, "attachment_type") != "energy"
                    || integer_arg(entry, "player", -1) != owner_index
                    || string_arg(entry, "slot") != "active"
                    || raw_index < 0
                    || static_cast<std::size_t>(raw_index) >= energy.size()
                    || energy[static_cast<std::size_t>(raw_index)].string_or()
                        != string_arg(entry, "card_id")
                    || !attached_energy_card_matches(
                        cards_,
                        *target,
                        static_cast<std::size_t>(raw_index),
                        filter
                    )
                ) {
                    throw std::invalid_argument(
                        "energy_discard_selection_invalid"
                    );
                }
                indices.push_back(static_cast<std::size_t>(raw_index));
            }
            std::sort(indices.begin(), indices.end());
            if (
                std::adjacent_find(indices.begin(), indices.end())
                != indices.end()
            ) {
                throw std::invalid_argument(
                    "duplicate_energy_discard_selection"
                );
            }
            Array &discard = required(owner, "discard").as_array();
            for (const std::size_t index : indices) {
                if (index >= energy.size()) {
                    throw std::invalid_argument(
                        "energy_attachment_out_of_range"
                    );
                }
                discard.push_back(energy[index]);
            }
            for (auto index = indices.rbegin(); index != indices.rend(); ++index) {
                energy.erase(
                    energy.begin() + static_cast<std::ptrdiff_t>(*index)
                );
            }
            if (!indices.empty()) {
                result.event_types.emplace_back("cards_discarded");
            }
        } else if (op == "draw_and_attach_energy") {
            const std::string filter = string_arg(
                args,
                "energy_type",
                "Grass"
            );
            Array &hand = required(self, "hand").as_array();
            validate_energy_distribution_selection(
                selected_options.as_array(),
                true,
                std::max<std::int64_t>(
                    0,
                    integer_arg(args, "energy_count", 2)
                )
            );
            const std::string forced_target_slot = (
                selected_options.as_array().empty()
            ) ? std::string{} : string_arg(
                selected_options.as_array().front(),
                "slot"
            );
            for (const Value &selected : selected_options.as_array()) {
                const auto energy = std::find_if(
                    hand.begin(),
                    hand.end(),
                    [this, &filter, &selected](const Value &entry) {
                        const std::string selected_id =
                            energy_option_card_id(selected);
                        return card_matches_energy(
                            cards_,
                            entry.string_or(),
                            filter
                        ) && (
                            selected_id.empty()
                            || entry.string_or() == selected_id
                        );
                    }
                );
                if (energy == hand.end()) {
                    throw std::invalid_argument(
                        "energy_attachment_source_missing"
                    );
                }
                Value *target = pokemon(
                    self,
                    forced_target_slot.empty()
                        ? string_arg(selected, "slot")
                        : forced_target_slot
                );
                if (target == nullptr) {
                    throw std::invalid_argument(
                        "energy_attachment_target_missing"
                    );
                }
                required(
                    *target,
                    "energy_card_ids"
                ).as_array().push_back(std::move(*energy));
                hand.erase(energy);
                result.event_types.emplace_back("energy_attached");
            }
        } else if (op == "evolve_skip_stage") {
            if (
                selected_options.as_array().size() != 1
                || !selected_options.as_array().front().is_object()
            ) {
                throw std::invalid_argument("evolution_card_required");
            }
            const Value &selected = selected_options.as_array().front();
            Array &hand = required(self, "hand").as_array();
            const std::int64_t selected_index = integer_arg(
                selected,
                "index",
                -1
            );
            if (
                selected_index < 0
                || static_cast<std::size_t>(selected_index) >= hand.size()
                || hand[static_cast<std::size_t>(selected_index)].string_or()
                    != string_arg(selected, "card_id")
            ) {
                throw std::invalid_argument("evolution_card_stale");
            }
            Value removed = std::move(
                hand[static_cast<std::size_t>(selected_index)]
            );
            hand.erase(
                hand.begin()
                    + static_cast<std::ptrdiff_t>(selected_index)
            );
            const Value *evolution = card_definition(
                cards_,
                removed.string_or()
            );
            const std::string skipped_stage_name = evolution == nullptr
                ? std::string{}
                : string_arg(*evolution, "evolves_from");
            std::string basic_name;
            if (!skipped_stage_name.empty()) {
                for (const auto &[unused_id, definition] : cards_.as_object()) {
                    (void)unused_id;
                    if (
                        definition.is_object()
                        && string_arg(definition, "name")
                            == skipped_stage_name
                    ) {
                        basic_name = string_arg(
                            definition,
                            "evolves_from"
                        );
                        break;
                    }
                }
            }
            std::string target_slot = string_arg(
                selected,
                "target_slot"
            );
            if (target_slot.empty()) {
                const std::string option_id = string_arg(
                    selected,
                    "option_id"
                );
                constexpr const char *prefix = "rare_candy:";
                if (option_id.rfind(prefix, 0) == 0) {
                    const std::size_t end = option_id.find(
                        ':',
                        std::char_traits<char>::length(prefix)
                    );
                    if (end != std::string::npos) {
                        target_slot = option_id.substr(
                            std::char_traits<char>::length(prefix),
                            end - std::char_traits<char>::length(prefix)
                        );
                    }
                }
            }
            Value *target = target_slot.empty()
                ? nullptr
                : pokemon(self, target_slot);
            if (target == nullptr && target_slot.empty()) {
                for (Value *candidate : all_pokemon(self)) {
                    const Value *definition = card_definition(
                        cards_,
                        card_id(*candidate)
                    );
                    if (
                        card_has_subtype(
                            cards_,
                            card_id(*candidate),
                            "Basic"
                        )
                        && (
                            basic_name.empty()
                            || (
                                definition != nullptr
                                && string_arg(*definition, "name")
                                    == basic_name
                            )
                        )
                    ) {
                        target = candidate;
                        break;
                    }
                }
            }
            if (target == nullptr) {
                throw std::invalid_argument("evolution_target_missing");
            }
            const Value *target_definition = card_definition(
                cards_,
                card_id(*target)
            );
            if (
                !card_has_subtype(cards_, card_id(*target), "Basic")
                || (
                    !basic_name.empty()
                    && (
                        target_definition == nullptr
                        || string_arg(*target_definition, "name")
                            != basic_name
                    )
                )
            ) {
                throw std::invalid_argument("evolution_target_stale");
            }
            required(
                *target,
                "evolution_stack_ids"
            ).as_array().emplace_back(card_id(*target));
            (*target)["card_id"] = std::move(removed);
            (*target)["can_evolve_this_turn"] = Value(false);
            result.event_types.emplace_back("pokemon_evolved");
        } else if (
            op == "flip_coin"
            || op == "flip_coin_repeat_damage"
            || op == "flip_coin_then_discard_energy"
            || op == "flip_coin_then_ko"
            || op == "flip_until_tails"
        ) {
            const Value *flip_value = continuation.find("flips");
            if (flip_value == nullptr || !flip_value->is_array()) {
                throw std::invalid_argument("coin_results_missing");
            }
            const Array &flips = flip_value->as_array();
            const std::int64_t heads = static_cast<std::int64_t>(
                std::count_if(
                    flips.begin(),
                    flips.end(),
                    [](const Value &entry) { return entry.as_bool(); }
                )
            );
            if (stage == 0) {
                result.event_types.emplace_back("coin_flip");
                append_event(
                    result,
                    "coin_flip",
                    Object{{"results", Value(flips)}}
                );
            }
            if (op == "flip_coin") {
                const Value *branches = spec->find("branches");
                const Value *branch = (
                    branches != nullptr && branches->is_object()
                ) ? branches->find(
                    !flips.empty() && flips.front().as_bool()
                        ? "on_heads"
                        : "on_tails"
                ) : nullptr;
                if (branch != nullptr && branch->is_array()) {
                    for (const Value &branch_spec : branch->as_array()) {
                        if (
                            bool_arg(result.context, "defer_coin_post_damage")
                            && coin_branch_runs_after_attack_damage(
                                string_arg(branch_spec, "op")
                            )
                        ) {
                            Value *deferred = result.context.find(
                                "deferred_attack_effects"
                            );
                            if (deferred == nullptr || !deferred->is_array()) {
                                result.context["deferred_attack_effects"] =
                                    Value::make_array();
                                deferred = result.context.find(
                                    "deferred_attack_effects"
                                );
                            }
                            deferred->as_array().push_back(branch_spec);
                            continue;
                        }
                        VmExecutionResult following = execute(
                            std::move(result.state),
                            branch_spec,
                            actor,
                            source_slot,
                            rng.state(),
                            string_arg(
                                continuation,
                                "context_mode"
                            ),
                            result.context
                        );
                        if (!following.success) {
                            throw std::invalid_argument(
                                following.error_code
                            );
                        }
                        result.state = std::move(following.state);
                        result.context = std::move(following.context);
                        rng.set_state(following.rng_state);
                        result.event_types.insert(
                            result.event_types.end(),
                            following.event_types.begin(),
                            following.event_types.end()
                        );
                        append_events(result.events, following.events);
                        if (!following.pending.as_object().empty()) {
                            result.pending = std::move(following.pending);
                            result.continuation = std::move(
                                following.continuation
                            );
                            break;
                        }
                    }
                }
            } else if (op == "flip_coin_repeat_damage") {
                set_attack_damage(
                    result.context,
                    heads * integer_arg(args, "damage_per_head", 10),
                    true
                );
            } else if (op == "flip_coin_then_discard_energy") {
                if (stage == 0) {
                    if (!flips.empty() && flips.front().as_bool()) {
                        Array options;
                        auto append_attachments = [
                            &options,
                            &opponent,
                            actor
                        ](const std::string &slot) {
                            Value *target = pokemon(opponent, slot);
                            if (target == nullptr) {
                                return;
                            }
                            const Array &energy = required(
                                *target,
                                "energy_card_ids"
                            ).as_array();
                            for (
                                std::size_t index = 0;
                                index < energy.size();
                                ++index
                            ) {
                                options.push_back(attachment_option(
                                    energy[index].string_or(),
                                    1 - actor,
                                    slot,
                                    static_cast<std::int64_t>(index)
                                ));
                            }
                        };
                        append_attachments("active");
                        const Array &bench = required(
                            opponent,
                            "bench"
                        ).as_array();
                        for (
                            std::size_t index = 0;
                            index < bench.size();
                            ++index
                        ) {
                            append_attachments(
                                "bench_" + std::to_string(index)
                            );
                        }
                        if (!options.empty()) {
                            Value continued = continuation;
                            continued["stage"] = Value(1);
                            next(
                                pending_request(
                                    "select_attachment",
                                    actor,
                                    1,
                                    1,
                                    false,
                                    false,
                                    std::move(options),
                                    "discard_attachment"
                                ),
                                std::move(continued)
                            );
                        }
                    }
                } else {
                    if (
                        selected_options.as_array().size() != 1
                        || string_arg(
                            selected_options.as_array().front(),
                            "kind"
                        ) != "attachment"
                    ) {
                        throw std::invalid_argument(
                            "selected_attachment_invalid"
                        );
                    }
                    const Value &selection =
                        selected_options.as_array().front();
                    if (integer_arg(selection, "player", -1) != 1 - actor) {
                        throw std::invalid_argument(
                            "selected_attachment_owner_invalid"
                        );
                    }
                    Value *target = pokemon(
                        opponent,
                        string_arg(selection, "slot")
                    );
                    if (target == nullptr) {
                        throw std::invalid_argument(
                            "selected_attachment_target_missing"
                        );
                    }
                    Array &energy = required(
                        *target,
                        "energy_card_ids"
                    ).as_array();
                    const std::int64_t raw_index = integer_arg(
                        selection,
                        "index",
                        -1
                    );
                    if (
                        raw_index < 0
                        || static_cast<std::size_t>(raw_index)
                            >= energy.size()
                        || energy[static_cast<std::size_t>(raw_index)]
                                .string_or()
                            != string_arg(selection, "card_id")
                    ) {
                        throw std::invalid_argument(
                            "selected_attachment_stale"
                        );
                    }
                    required(
                        opponent,
                        "discard"
                    ).as_array().push_back(std::move(
                        energy[static_cast<std::size_t>(raw_index)]
                    ));
                    energy.erase(
                        energy.begin()
                            + static_cast<std::ptrdiff_t>(raw_index)
                    );
                    result.event_types.emplace_back("cards_discarded");
                }
            } else if (op == "flip_until_tails") {
                set_attack_damage(
                    result.context,
                    heads * integer_arg(args, "per_head", 20),
                    true
                );
            } else if (stage == 0 && heads == 2) {
                Value *target = pokemon(opponent, "active");
                if (
                    target != nullptr
                    && !(
                        string_arg(continuation, "context_mode") == "attack"
                        && prevents_attack_effects(*target)
                    )
                ) {
                    const std::string defeated_id = card_id(*target);
                    const Value *defeated_definition = card_definition(
                        cards_,
                        defeated_id
                    );
                    const std::int64_t prize_value = std::max<std::int64_t>(
                        1,
                        defeated_definition == nullptr
                            ? 1
                            : integer_arg(
                                *defeated_definition,
                                "prize_value",
                                1
                            )
                    );
                    discard_pokemon(opponent, "active");
                    result.event_types.emplace_back(
                        "direct_knockout_applied"
                    );
                    result.event_types.emplace_back("pokemon_ko");
                    result.event_types.emplace_back("card_moved");
                    if (!pokemon_options(
                            opponent,
                            1 - actor,
                            false,
                            true
                        ).empty()) {
                        required(
                            result.state,
                            "pending_promotions"
                        ).as_array().emplace_back(1 - actor);
                    }
                    Value *fact_book = result.state.find("turn_fact_book");
                    if (fact_book != nullptr && fact_book->is_object()) {
                        Value *current = fact_book->find("current_turn");
                        if (current != nullptr && current->is_object()) {
                            Value *knockouts = current->find("knockouts");
                            if (knockouts != nullptr && knockouts->is_array()) {
                                Object fact;
                                fact["card_id"] = Value(defeated_id);
                                fact["cause_detail"] = Value("");
                                fact["cause_kind"] = Value(
                                    "direct_knockout"
                                );
                                fact["defeated_player"] = Value(1 - actor);
                                fact["slot"] = Value("active");
                                fact["source_kind"] = Value(
                                    "attack_effect"
                                );
                                fact["source_player"] = Value(actor);
                                fact["turn"] = Value(get_integer(
                                    result.state,
                                    "turn_number"
                                ));
                                knockouts->as_array().emplace_back(
                                    std::move(fact)
                                );
                            }
                        }
                    }
                    Array prize_options;
                    const Array &prizes = required(
                        self,
                        "prizes"
                    ).as_array();
                    for (std::size_t index = 0; index < prizes.size(); ++index) {
                        prize_options.push_back(id_option(
                            "prize:" + std::to_string(index)
                        ));
                    }
                    Value continued = continuation;
                    continued["stage"] = Value(1);
                    continued["remaining_prizes"] = Value(
                        std::max<std::int64_t>(0, prize_value - 1)
                    );
                    next(
                        pending_request(
                            "select_prize",
                            actor,
                            1,
                            1,
                            false,
                            false,
                            std::move(prize_options),
                            "select_prize"
                        ),
                        std::move(continued)
                    );
                }
            } else if (stage == 1) {
                if (
                    selected_options.as_array().size() != 1
                    || !selected_options.as_array().front().is_object()
                ) {
                    throw std::invalid_argument(
                        "prize_selection_invalid"
                    );
                }
                const std::string selected = string_arg(
                    selected_options.as_array().front(),
                    "option_id"
                );
                const std::size_t separator = selected.find(':');
                if (
                    selected.rfind("prize:", 0) != 0
                    || separator == std::string::npos
                    || separator + 1 >= selected.size()
                ) {
                    throw std::invalid_argument(
                        "prize_selection_invalid"
                    );
                }
                const std::size_t index = static_cast<std::size_t>(
                    std::stoul(selected.substr(separator + 1))
                );
                Array &prizes = required(self, "prizes").as_array();
                Array &hand = required(self, "hand").as_array();
                if (index >= prizes.size()) {
                    throw std::invalid_argument("prize_index_invalid");
                }
                hand.push_back(std::move(prizes[index]));
                prizes.erase(
                    prizes.begin() + static_cast<std::ptrdiff_t>(index)
                );
                result.event_types.clear();
                result.event_types.emplace_back("prize_taken");
                const std::int64_t remaining = std::max<std::int64_t>(
                    0,
                    integer_arg(continuation, "remaining_prizes")
                );
                if (remaining > 0 && !prizes.empty()) {
                    Array prize_options;
                    for (
                        std::size_t prize_index = 0;
                        prize_index < prizes.size();
                        ++prize_index
                    ) {
                        prize_options.push_back(id_option(
                            "prize:" + std::to_string(prize_index)
                        ));
                    }
                    Value continued = continuation;
                    continued["remaining_prizes"] = Value(remaining - 1);
                    next(
                        pending_request(
                            "select_prize",
                            actor,
                            1,
                            1,
                            false,
                            false,
                            std::move(prize_options),
                            "select_prize"
                        ),
                        std::move(continued)
                    );
                }
            }
        } else if (
            op == "hand_to_bottom_draw_until"
            || op == "hand_to_bottom_then_draw"
        ) {
            if (
                op == "hand_to_bottom_draw_until"
                && selected_options.as_array().size() != 1
            ) {
                throw std::invalid_argument(
                    "hand_bottom_selection_count_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                "hand",
                actor
            );
            std::vector<Value> removed = remove_selected(
                self,
                "hand",
                selected_options
            );
            Array returned_ids = card_id_values(removed);
            Array &deck = required(self, "deck").as_array();
            deck.insert(
                deck.begin(),
                std::make_move_iterator(removed.begin()),
                std::make_move_iterator(removed.end())
            );
            append_card_zone_event(
                result,
                "cards_selected",
                actor,
                std::move(returned_ids),
                "hand",
                "deck",
                "owner"
            );
            const std::int64_t draw_count = (
                op == "hand_to_bottom_then_draw"
            ) ? static_cast<std::int64_t>(removed.size()) : std::max<std::int64_t>(
                0,
                integer_arg(args, "target_hand_size", 5)
                    - static_cast<std::int64_t>(
                        required(self, "hand").as_array().size()
                    )
            );
            const auto drawn = draw_cards(self, draw_count);
            append_cards_drawn_event(
                result, actor, drawn, "hand_to_bottom");
        } else if (
            op == "look_top_attach_energy"
            || op == "look_top_deck"
        ) {
            const bool bench_energy = (
                op == "look_top_deck"
                && string_arg(args, "destination", "hand")
                    == "bench_energy"
            );
            Array bench_targets;
            if (bench_energy) {
                const std::string target_type = string_arg(
                    args,
                    "target_pokemon_type",
                    "Lightning"
                );
                for (Value &option : pokemon_options(
                    self,
                    actor,
                    false,
                    true
                )) {
                    Value *target = pokemon(
                        self,
                        string_arg(option, "slot")
                    );
                    const Value *definition = target == nullptr
                        ? nullptr
                        : card_definition(cards_, card_id(*target));
                    if (
                        definition != nullptr
                        && (
                            target_type.empty()
                            || string_array_contains_ci(
                                definition->find("energy_types"),
                                target_type
                            )
                        )
                    ) {
                        bench_targets.push_back(std::move(option));
                    }
                }
            }
            Array look_top_targets;
            if (op == "look_top_attach_energy") {
                look_top_targets = pokemon_options(
                    self,
                    actor,
                    true,
                    true
                );
            }
            if (
                op == "look_top_attach_energy"
                && stage == 0
                && !selected_options.as_array().empty()
                && look_top_targets.size() > 1
            ) {
                Value continued = continuation;
                continued["stage"] = Value(1);
                continued["selected_cards"] = selected_options;
                next(
                    pending_request(
                        "select_energy_target",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        std::move(look_top_targets),
                        "look_top_attach_target"
                    ),
                    std::move(continued)
                );
                result.event_types.emplace_back("cards_selected");
            } else {
                const Value &card_selection = (
                    (op == "look_top_attach_energy" && stage == 1)
                    || (bench_energy && stage == 1)
                ) ? required(continuation, "selected_cards")
                  : selected_options;
                if (
                    bench_energy
                    && stage == 0
                    && !card_selection.as_array().empty()
                    && !bench_targets.empty()
                    && !(
                        bench_targets.size() == 1
                        && card_selection.as_array().size() <= 1
                    )
                ) {
                    Array options;
                    for (const Value &target : bench_targets) {
                        for (
                            std::size_t energy_index = 0;
                            energy_index < card_selection.as_array().size();
                            ++energy_index
                        ) {
                            Value option = target;
                            const Value &selected_card =
                                card_selection.as_array()[energy_index];
                            decorate_energy_distribution_option(
                                option,
                                actor,
                                static_cast<std::int64_t>(energy_index),
                                string_arg(selected_card, "card_id")
                            );
                            options.push_back(std::move(option));
                        }
                    }
                    Value continued = continuation;
                    continued["stage"] = Value(1);
                    continued["selected_cards"] = card_selection;
                    const std::int64_t count =
                        static_cast<std::int64_t>(
                            card_selection.as_array().size()
                        );
                    next(
                        pending_request(
                            "distribute_energy",
                            actor,
                            count,
                            count,
                            false,
                            false,
                            std::move(options),
                            "look_top_bench_energy_distribution"
                        ),
                        std::move(continued)
                    );
                    result.event_types.emplace_back("cards_selected");
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                Array &deck = required(self, "deck").as_array();
                const std::size_t top_count = static_cast<std::size_t>(
                    std::min<std::int64_t>(
                        integer_arg(args, "count"),
                        static_cast<std::int64_t>(deck.size())
                    )
                );
                const std::size_t first_top = deck.size() - top_count;
                const std::vector<std::string> selected_card_ids =
                    selected_zone_card_ids(
                        self,
                        card_selection,
                        "deck",
                        actor
                    );
                if (
                    selected_card_ids.size()
                    > static_cast<std::size_t>(std::max<std::int64_t>(
                        0,
                        integer_arg(args, "take", 1)
                    ))
                ) {
                    throw std::invalid_argument(
                        "look_top_selection_count_exceeded"
                    );
                }
                const std::string card_filter = string_arg(
                    args, "filter", "any");
                for (const std::string &selected_id : selected_card_ids) {
                    if (!card_matches_filter(
                        cards_, selected_id, card_filter
                    )) {
                        throw std::invalid_argument(
                            "look_top_selection_filter_mismatch"
                        );
                    }
                }
                const std::vector<std::size_t> selected = selected_indices(
                    card_selection,
                    "deck"
                );
                for (const std::size_t index : selected) {
                    if (index < first_top || index >= deck.size()) {
                        throw std::invalid_argument("stale_choice");
                    }
                }
                Array chosen_cards;
                Array remaining_top;
                for (std::size_t position = 0; position < top_count; ++position) {
                    const std::size_t index = deck.size() - 1 - position;
                    if (
                        std::binary_search(
                            selected.begin(),
                            selected.end(),
                            index
                        )
                    ) {
                        chosen_cards.push_back(deck[index]);
                    } else {
                        remaining_top.push_back(deck[index]);
                    }
                }
                deck.erase(
                    deck.begin() + static_cast<std::ptrdiff_t>(first_top),
                    deck.end()
                );
                if (op == "look_top_attach_energy") {
                    const std::string target_slot = stage == 1
                        ? selected_slot(selected_options)
                        : (
                            look_top_targets.empty()
                            ? std::string{}
                            : string_arg(
                                look_top_targets.front(),
                                "slot"
                            )
                        );
                    Value *target = pokemon(self, target_slot);
                    if (target == nullptr) {
                        throw std::invalid_argument(
                            "look_top_energy_target_missing"
                        );
                    }
                    Array &energy = required(
                        *target,
                        "energy_card_ids"
                    ).as_array();
                    for (Value &entry : chosen_cards) {
                        energy.push_back(std::move(entry));
                        result.event_types.emplace_back(
                            "energy_attached"
                        );
                    }
                } else if (bench_energy) {
                    std::vector<bool> attached(
                        chosen_cards.size(),
                        false
                    );
                    if (stage == 0 && bench_targets.size() == 1) {
                        Value *target = pokemon(
                            self,
                            string_arg(bench_targets.front(), "slot")
                        );
                        if (target == nullptr) {
                            throw std::invalid_argument(
                                "look_top_energy_target_missing"
                            );
                        }
                        Array &energy = required(
                            *target,
                            "energy_card_ids"
                        ).as_array();
                        for (
                            std::size_t index = 0;
                            index < chosen_cards.size();
                            ++index
                        ) {
                            energy.push_back(
                                std::move(chosen_cards[index])
                            );
                            attached[index] = true;
                            result.event_types.emplace_back(
                                "energy_attached"
                            );
                        }
                    } else if (stage == 1) {
                        if (
                            selected_options.as_array().size()
                            != chosen_cards.size()
                        ) {
                            throw std::invalid_argument(
                                "look_top_energy_target_count_invalid"
                            );
                        }
                        validate_energy_distribution_selection(
                            selected_options.as_array(),
                            false,
                            static_cast<std::int64_t>(chosen_cards.size())
                        );
                        for (
                            const Value &target_option
                                : selected_options.as_array()
                        ) {
                            const std::size_t energy_index =
                                static_cast<std::size_t>(
                                    energy_option_index(target_option)
                                );
                            if (
                                energy_index >= chosen_cards.size()
                                || attached[energy_index]
                            ) {
                                throw std::invalid_argument(
                                    "look_top_energy_selection_invalid"
                                );
                            }
                            const std::string target_slot = string_arg(
                                target_option, "slot");
                            const bool valid_target = std::any_of(
                                bench_targets.begin(),
                                bench_targets.end(),
                                [&target_slot, &target_option](
                                    const Value &candidate
                                ) {
                                    return string_arg(candidate, "slot")
                                            == target_slot
                                        && integer_arg(
                                            target_option, "player", -1)
                                            == integer_arg(
                                                candidate, "player", -2)
                                        && string_arg(
                                            target_option, "card_id")
                                            == string_arg(
                                                candidate, "card_id");
                                }
                            );
                            Value *target = pokemon(
                                self,
                                target_slot
                            );
                            if (!valid_target || target == nullptr) {
                                throw std::invalid_argument(
                                    "look_top_energy_target_missing"
                                );
                            }
                            const std::string selected_energy_id =
                                energy_option_card_id(target_option);
                            if (
                                !selected_energy_id.empty()
                                && selected_energy_id
                                    != chosen_cards[energy_index].string_or()
                            ) {
                                throw std::invalid_argument(
                                    "look_top_energy_selection_stale"
                                );
                            }
                            required(
                                *target,
                                "energy_card_ids"
                            ).as_array().push_back(
                                std::move(chosen_cards[energy_index])
                            );
                            attached[energy_index] = true;
                            result.event_types.emplace_back(
                                "energy_attached"
                            );
                        }
                    }
                    for (
                        std::size_t index = 0;
                        index < chosen_cards.size();
                        ++index
                    ) {
                        if (!attached[index]) {
                            remaining_top.push_back(
                                std::move(chosen_cards[index])
                            );
                        }
                    }
                } else {
                    Array &hand = required(self, "hand").as_array();
                    for (Value &entry : chosen_cards) {
                        hand.push_back(std::move(entry));
                    }
                    result.event_types.emplace_back("cards_selected");
                }
                for (Value &entry : remaining_top) {
                    if (bool_arg(args, "shuffle_rest")) {
                        deck.push_back(std::move(entry));
                    } else if (bool_arg(args, "rest_bottom", true)) {
                        deck.insert(deck.begin(), std::move(entry));
                    } else {
                        deck.push_back(std::move(entry));
                    }
                }
                if (bool_arg(args, "shuffle_rest")) {
                    shuffle_array(deck, rng);
                    result.event_types.emplace_back("deck_shuffled");
                } else if (!bool_arg(args, "rest_bottom", true)) {
                    std::reverse(
                        deck.end()
                            - static_cast<std::ptrdiff_t>(
                                remaining_top.size()
                            ),
                        deck.end()
                    );
                }
            }
        } else if (op == "place_counters_then_self_discard") {
            const std::string target_slot = selected_slot(selected_options);
            Value *target = pokemon(
                opponent,
                target_slot
            );
            if (target == nullptr) {
                throw std::invalid_argument("counter_target_missing");
            }
            const std::int64_t amount = integer_arg(
                args, "counters", 2) * 10;
            add_damage(*target, amount);
            const std::int64_t maximum_hp = pokemon_hp(cards_, *target);
            if (
                maximum_hp > 0
                && integer_arg(*target, "damage_counters") * 10
                    >= maximum_hp
                && target->find("pending_ko_source_kind") == nullptr
            ) {
                (*target)["pending_ko_source_kind"] = Value(
                    "damage_counters"
                );
            }
            append_damage_feedback_event(
                result,
                "damage_counters_placed",
                actor,
                1 - actor,
                target_slot,
                amount
            );
            discard_pokemon(self, source_slot);
            if (
                source_slot == "active"
                && !pokemon_options(
                    self,
                    actor,
                    false,
                    true
                ).empty()
            ) {
                required(
                    result.state,
                    "pending_promotions"
                ).as_array().emplace_back(actor);
            }
            result.event_types.emplace_back("cards_discarded");
        } else if (op == "recover_clara") {
            const std::int64_t max_energy = std::max<std::int64_t>(
                0,
                integer_arg(args, "energy_count", 2)
            );
            const std::int64_t max_pokemon = std::max<std::int64_t>(
                0,
                integer_arg(args, "pokemon_count", 2)
            );
            const std::vector<std::string> selected_ids =
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "discard",
                    actor
                );
            if (
                selected_ids.size()
                > static_cast<std::size_t>(max_energy + max_pokemon)
            ) {
                throw std::invalid_argument(
                    "clara_selection_count_exceeded"
                );
            }
            std::int64_t energy_count = 0;
            std::int64_t pokemon_count = 0;
            for (const std::string &id : selected_ids) {
                if (card_matches_energy(cards_, id, "basic")) {
                    ++energy_count;
                } else if (card_is_pokemon(cards_, id)) {
                    ++pokemon_count;
                } else {
                    throw std::invalid_argument(
                        "clara_selection_category_invalid"
                    );
                }
            }
            if (
                energy_count > max_energy
                || pokemon_count > max_pokemon
            ) {
                throw std::invalid_argument(
                    "clara_category_limit_exceeded"
                );
            }
            std::vector<Value> removed = remove_selected(
                self,
                "discard",
                selected_options
            );
            Array recovered_ids = card_id_values(removed);
            Array &hand = required(self, "hand").as_array();
            for (Value &entry : removed) {
                hand.push_back(std::move(entry));
            }
            append_card_zone_event(
                result,
                "cards_selected",
                actor,
                std::move(recovered_ids),
                "discard",
                "hand",
                "public"
            );
        } else if (op == "relocate_energy") {
            auto relocation_targets = [
                &self,
                actor
            ](const std::string &excluded_slot) {
                Array options = pokemon_options(
                    self,
                    actor,
                    true,
                    true
                );
                options.erase(
                    std::remove_if(
                        options.begin(),
                        options.end(),
                        [&excluded_slot](const Value &entry) {
                            return string_arg(entry, "slot")
                                == excluded_slot;
                        }
                    ),
                    options.end()
                );
                return options;
            };
            auto request_relocation_targets = [
                &next,
                &relocation_targets,
                &args,
                actor
            ](
                Value continued,
                const std::string &selected_source_slot,
                Value attachments
            ) {
                const std::int64_t count =
                    static_cast<std::int64_t>(
                        attachments.as_array().size()
                    );
                continued["source_slot"] = Value(
                    selected_source_slot
                );
                continued["stage"] = Value(1);
                continued["selected_attachments"] = std::move(
                    attachments
                );
                const bool same_target = bool_arg(args, "same_target");
                const std::int64_t target_count = same_target ? 1 : count;
                next(
                    pending_request(
                        !same_target && count > 1
                            ? "distribute_energy"
                            : "select_energy_target",
                        actor,
                        target_count,
                        target_count,
                        !same_target && count > 1,
                        false,
                        relocation_targets(selected_source_slot),
                        !same_target && count > 1
                            ? "energy_relocate_distribution"
                            : "energy_relocate_target"
                    ),
                    std::move(continued)
                );
            };
            if (stage == -1) {
                const std::string selected_source_slot = selected_slot(
                    selected_options
                );
                Value *selected_source = pokemon(
                    self,
                    selected_source_slot
                );
                if (selected_source == nullptr) {
                    throw std::invalid_argument(
                        "energy_relocate_source_missing"
                    );
                }
                const Value &source_option =
                    selected_options.as_array().front();
                if (
                    integer_arg(source_option, "player", -1) != actor
                    || string_arg(source_option, "card_id")
                        != string_arg(*selected_source, "card_id")
                ) {
                    throw std::invalid_argument(
                        "energy_relocate_source_stale"
                    );
                }
                const std::string filter = string_arg(
                    args,
                    "energy_type",
                    string_arg(args, "filter", "any")
                );
                Array attachments;
                const Array &energy = required(
                    *selected_source,
                    "energy_card_ids"
                ).as_array();
                for (
                    std::size_t index = 0;
                    index < energy.size();
                    ++index
                ) {
                    if (attached_energy_card_matches(
                        cards_,
                        *selected_source,
                        index,
                        filter
                    )) {
                        attachments.push_back(attachment_option(
                            energy[index].string_or(),
                            actor,
                            selected_source_slot,
                            static_cast<std::int64_t>(index)
                        ));
                    }
                }
                const std::int64_t amount = std::min<std::int64_t>(
                    integer_arg(args, "amount", 1),
                    static_cast<std::int64_t>(attachments.size())
                );
                const bool optional_count =
                    args.find("min_select") != nullptr
                    || bool_arg(args, "optional");
                const std::int64_t minimum = optional_count
                    ? std::min(
                        amount,
                        integer_arg(args, "min_select")
                    )
                    : amount;
                const bool exact_choice = minimum < amount
                    || static_cast<std::int64_t>(attachments.size())
                        > amount;
                Value continued = continuation;
                continued["source_slot"] = Value(
                    selected_source_slot
                );
                if (exact_choice) {
                    continued["stage"] = Value(0);
                    next(
                        pending_request(
                            "select_attachment",
                            actor,
                            minimum,
                            amount,
                            false,
                            minimum == 0,
                            std::move(attachments),
                            "energy_relocate_attachments"
                        ),
                        std::move(continued)
                    );
                } else {
                    attachments.resize(
                        static_cast<std::size_t>(amount)
                    );
                    request_relocation_targets(
                        std::move(continued),
                        selected_source_slot,
                        std::move(attachments)
                    );
                }
            } else if (stage == 0) {
                if (selected_options.as_array().empty()) {
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                Value *selected_source = pokemon(self, source_slot);
                if (selected_source == nullptr) {
                    throw std::invalid_argument(
                        "energy_relocate_source_missing"
                    );
                }
                const Array &source_energy = required(
                    *selected_source,
                    "energy_card_ids"
                ).as_array();
                const std::string filter = string_arg(
                    args,
                    "energy_type",
                    string_arg(args, "filter", "any")
                );
                std::unordered_set<std::size_t> selected_indices;
                for (const Value &attachment : selected_options.as_array()) {
                    const std::int64_t raw_index = integer_arg(
                        attachment, "index", -1);
                    if (
                        !attachment.is_object()
                        || string_arg(attachment, "kind") != "attachment"
                        || string_arg(attachment, "attachment_type")
                            != "energy"
                        || integer_arg(attachment, "player", -1) != actor
                        || string_arg(attachment, "slot") != source_slot
                        || raw_index < 0
                        || static_cast<std::size_t>(raw_index)
                            >= source_energy.size()
                        || !selected_indices.insert(
                            static_cast<std::size_t>(raw_index)).second
                        || source_energy[
                            static_cast<std::size_t>(raw_index)].string_or()
                            != string_arg(attachment, "card_id")
                        || !attached_energy_card_matches(
                            cards_,
                            *selected_source,
                            static_cast<std::size_t>(raw_index),
                            filter
                        )
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_attachment_invalid"
                        );
                    }
                }
                Value continued = continuation;
                request_relocation_targets(
                    std::move(continued),
                    source_slot,
                    selected_options
                );
            } else {
                Value *source = pokemon(self, source_slot);
                if (source == nullptr) {
                    throw std::invalid_argument(
                        "energy_relocate_source_missing"
                    );
                }
                const Value &attachments = required(
                    continuation,
                    "selected_attachments"
                );
                const bool same_target = bool_arg(args, "same_target");
                const std::size_t expected_targets = same_target
                    ? 1
                    : attachments.as_array().size();
                if (
                    selected_options.as_array().size()
                    != expected_targets
                ) {
                    throw std::invalid_argument(
                        "energy_relocate_target_count"
                    );
                }
                std::vector<std::size_t> indices;
                std::unordered_set<std::size_t> unique_indices;
                for (const Value &entry : attachments.as_array()) {
                    const std::int64_t raw_index = integer_arg(
                        entry, "index", -1);
                    if (
                        !entry.is_object()
                        || string_arg(entry, "kind") != "attachment"
                        || string_arg(entry, "attachment_type") != "energy"
                        || integer_arg(entry, "player", -1) != actor
                        || string_arg(entry, "slot") != source_slot
                        || raw_index < 0
                        || !unique_indices.insert(
                            static_cast<std::size_t>(raw_index)).second
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_attachment_invalid"
                        );
                    }
                    indices.push_back(static_cast<std::size_t>(raw_index));
                }
                Array &source_energy = required(
                    *source,
                    "energy_card_ids"
                ).as_array();
                for (std::size_t index = 0; index < indices.size(); ++index) {
                    if (
                        indices[index] >= source_energy.size()
                        || source_energy[indices[index]].string_or()
                            != string_arg(
                                attachments.as_array()[index], "card_id")
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_attachment_stale"
                        );
                    }
                }
                std::vector<Value *> targets;
                targets.reserve(selected_options.as_array().size());
                for (const Value &target_option
                    : selected_options.as_array()) {
                    const std::string target_slot = string_arg(
                        target_option, "slot");
                    Value *target = pokemon(self, target_slot);
                    if (
                        target == nullptr
                        || target_slot == source_slot
                        || integer_arg(target_option, "player", -1) != actor
                        || string_arg(target_option, "card_id")
                            != string_arg(*target, "card_id")
                    ) {
                        throw std::invalid_argument(
                            "energy_relocate_target_missing"
                        );
                    }
                    targets.push_back(target);
                }
                Array moved;
                for (const std::size_t index : indices) {
                    moved.push_back(source_energy.at(index));
                }
                std::vector<std::size_t> removal_indices = indices;
                std::sort(
                    removal_indices.begin(),
                    removal_indices.end()
                );
                for (
                    auto index = removal_indices.rbegin();
                    index != removal_indices.rend();
                    ++index
                ) {
                    source_energy.erase(
                        source_energy.begin()
                            + static_cast<std::ptrdiff_t>(*index)
                    );
                }
                for (std::size_t index = 0; index < moved.size(); ++index) {
                    Value *target = targets[
                        same_target ? 0 : index];
                    required(
                        *target,
                        "energy_card_ids"
                    ).as_array().push_back(std::move(moved[index]));
                    result.event_types.emplace_back("energy_attached");
                }
            }
        } else if (op == "search_any_and_switch") {
            if (stage == 0) {
                if (selected_options.as_array().size() > 2) {
                    throw std::invalid_argument(
                        "search_selection_count_exceeded"
                    );
                }
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "deck",
                    actor
                );
                std::vector<Value> removed = remove_selected(
                    self,
                    "deck",
                    selected_options
                );
                Array selected_ids = card_id_values(removed);
                Array &hand = required(self, "hand").as_array();
                for (Value &entry : removed) {
                    hand.push_back(std::move(entry));
                }
                append_card_zone_event(
                    result,
                    "cards_selected",
                    actor,
                    std::move(selected_ids),
                    "deck",
                    "hand",
                    "owner"
                );
                shuffle_array(required(self, "deck").as_array(), rng);
                result.event_types.emplace_back("deck_shuffled");
                if (pokemon_options(self, actor, false, true).empty()) {
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                Value continued = continuation;
                continued["stage"] = Value(1);
                next(
                    pending_request(
                        "confirm",
                        actor,
                        1,
                        1,
                        false,
                        false,
                        {id_option("confirm:yes"), id_option("confirm:no")},
                        "search_any_switch_confirm"
                    ),
                    std::move(continued)
                );
            } else if (stage == 1) {
                if (selected_confirmation(selected_options)) {
                    Array options = pokemon_options(
                        self,
                        actor,
                        false,
                        true
                    );
                    if (options.size() == 1) {
                        switch_active_with_event(
                            result,
                            self,
                            actor,
                            actor,
                            string_arg(options.front(), "slot"),
                            "search_any_and_switch"
                        );
                    } else if (!options.empty()) {
                        Value continued = continuation;
                        continued["stage"] = Value(2);
                        next(
                            pending_request(
                                "select_bench",
                                actor,
                                1,
                                1,
                                false,
                                false,
                                std::move(options),
                                "search_any_switch_bench"
                            ),
                            std::move(continued)
                        );
                    }
                }
            } else {
                switch_active_with_event(
                    result,
                    self,
                    actor,
                    actor,
                    selected_slot(selected_options),
                    "search_any_and_switch"
                );
            }
        } else if (op == "shuffle_from_discard_to_deck") {
            const std::string filter = string_arg(args, "filter", "any");
            const std::vector<std::string> selected_ids =
                selected_zone_card_ids(
                    self,
                    selected_options,
                    "discard",
                    actor
                );
            if (
                selected_ids.empty()
                || selected_ids.size()
                    > static_cast<std::size_t>(std::max<std::int64_t>(
                        0,
                        integer_arg(args, "count", 1)
                    ))
            ) {
                throw std::invalid_argument(
                    "shuffle_recovery_selection_count_invalid"
                );
            }
            for (const std::string &selected_id : selected_ids) {
                if (!card_matches_filter(cards_, selected_id, filter)) {
                    throw std::invalid_argument(
                        "shuffle_recovery_filter_mismatch"
                    );
                }
            }
            std::vector<Value> removed = remove_selected(
                self,
                "discard",
                selected_options
            );
            Array returned_ids = card_id_values(removed);
            Array &deck = required(self, "deck").as_array();
            for (Value &entry : removed) {
                deck.push_back(std::move(entry));
            }
            if (!removed.empty()) {
                append_card_zone_event(
                    result,
                    "card_moved",
                    actor,
                    std::move(returned_ids),
                    "discard",
                    "deck",
                    "public"
                );
            }
            shuffle_array(deck, rng);
            result.event_types.emplace_back("deck_shuffled");
        } else if (op == "switch_pokemon") {
            const bool opponent_target = string_arg(
                args,
                "target",
                "self"
            ) == "opponent";
            Value &target = opponent_target ? opponent : self;
            if (bool_arg(args, "optional") && stage == 0) {
                if (selected_confirmation(selected_options)) {
                    Array options = pokemon_options(
                        target,
                        opponent_target ? 1 - actor : actor,
                        false,
                        true
                    );
                    if (options.size() == 1) {
                        switch_active_with_event(
                            result,
                            target,
                            actor,
                            opponent_target ? 1 - actor : actor,
                            string_arg(options.front(), "slot"),
                            "switch_pokemon"
                        );
                    } else if (!options.empty()) {
                        Value continued = continuation;
                        continued["stage"] = Value(1);
                        next(
                            pending_request(
                                "select_bench",
                                actor,
                                1,
                                1,
                                false,
                                false,
                                std::move(options),
                                "switch"
                            ),
                            std::move(continued)
                        );
                    }
                }
            } else {
                switch_active_with_event(
                    result,
                    target,
                    actor,
                    opponent_target ? 1 - actor : actor,
                    selected_slot(selected_options),
                    "switch_pokemon"
                );
            }
        } else if (op == "trekking_shoes") {
            Array &deck = required(self, "deck").as_array();
            if (!deck.empty()) {
                const std::int64_t source_index =
                    static_cast<std::int64_t>(deck.size() - 1);
                const std::string moved_card_id =
                    deck.back().string_or();
                if (selected_confirmation(selected_options)) {
                    Array &hand = required(self, "hand").as_array();
                    const std::int64_t target_index =
                        static_cast<std::int64_t>(hand.size());
                    hand.push_back(std::move(deck.back()));
                    append_event(
                        result,
                        "card_moved",
                        Object{
                            {"actor", Value(actor)},
                            {"visibility", Value("owner")},
                            {"card_id", Value(moved_card_id)},
                            {
                                "source",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("deck")},
                                    {"index", Value(source_index)},
                                }),
                            },
                            {
                                "target",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("hand")},
                                    {"index", Value(target_index)},
                                }),
                            },
                            {"amount", Value(1)},
                            {"player", Value(actor)},
                            {
                                "card_ids",
                                Value(Array{Value(moved_card_id)}),
                            },
                            {"count", Value(1)},
                            {"source_zone", Value("deck")},
                            {"source_index", Value(source_index)},
                            {"target_zone", Value("hand")},
                            {"target_index", Value(target_index)},
                        }
                    );
                } else {
                    Array &discard = required(self, "discard").as_array();
                    const std::int64_t target_index =
                        static_cast<std::int64_t>(discard.size());
                    discard.push_back(std::move(deck.back()));
                    deck.pop_back();
                    result.event_types.emplace_back("cards_discarded");
                    append_event(
                        result,
                        "cards_discarded",
                        Object{
                            {"actor", Value(actor)},
                            {"visibility", Value("public")},
                            {"card_id", Value(moved_card_id)},
                            {
                                "source",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("deck")},
                                    {"index", Value(source_index)},
                                }),
                            },
                            {
                                "target",
                                Value(Object{
                                    {"player", Value(actor)},
                                    {"zone", Value("discard")},
                                    {"index", Value(target_index)},
                                }),
                            },
                            {"amount", Value(1)},
                            {"player", Value(actor)},
                            {
                                "card_ids",
                                Value(Array{Value(moved_card_id)}),
                            },
                            {"count", Value(1)},
                            {"source_zone", Value("deck")},
                            {"source_index", Value(source_index)},
                            {"target_zone", Value("discard")},
                            {"target_index", Value(target_index)},
                        }
                    );
                    const auto drawn = draw_cards(self, 1);
                    if (!drawn.empty()) {
                        result.event_types.emplace_back("cards_drawn");
                        Array drawn_ids;
                        drawn_ids.reserve(drawn.size());
                        for (const std::string &card_id : drawn) {
                            drawn_ids.emplace_back(card_id);
                        }
                        append_event(
                            result,
                            "cards_drawn",
                            Object{
                                {"actor", Value(actor)},
                                {"visibility", Value("owner")},
                                {
                                    "source",
                                    Value(Object{
                                        {"player", Value(actor)},
                                        {"zone", Value("deck")},
                                    }),
                                },
                                {
                                    "target",
                                    Value(Object{
                                        {"player", Value(actor)},
                                        {"zone", Value("hand")},
                                    }),
                                },
                                {
                                    "amount",
                                    Value(static_cast<std::int64_t>(
                                        drawn.size()
                                    )),
                                },
                                {"player", Value(actor)},
                                {"card_ids", Value(std::move(drawn_ids))},
                                {
                                    "count",
                                    Value(static_cast<std::int64_t>(
                                        drawn.size()
                                    )),
                                },
                                {"source_zone", Value("deck")},
                                {"target_zone", Value("hand")},
                            }
                        );
                    }
                    result.success = true;
                    result.rng_state = rng.state();
                    return result;
                }
                deck.pop_back();
                result.event_types.emplace_back("card_moved");
            }
        } else if (op == "zinnia_resolve") {
            if (selected_options.as_array().size() != 2) {
                throw std::invalid_argument(
                    "zinnia_selection_count_invalid"
                );
            }
            selected_zone_card_ids(
                self,
                selected_options,
                "hand",
                actor
            );
            std::vector<Value> removed = remove_selected(
                self,
                "hand",
                selected_options
            );
            Array discarded_ids = card_id_values(removed);
            Array &discard = required(self, "discard").as_array();
            for (Value &entry : removed) {
                discard.push_back(std::move(entry));
            }
            if (!removed.empty()) {
                append_card_zone_event(
                    result,
                    "cards_discarded",
                    actor,
                    std::move(discarded_ids),
                    "hand",
                    "discard",
                    "public"
                );
            }
            const auto drawn = draw_cards(
                self,
                integer_arg(continuation, "draw_amount")
            );
            append_cards_drawn_event(result, actor, drawn, "zinnia");
        } else {
            throw std::invalid_argument("unsupported_native_resume_op");
        }

        result.success = true;
    } catch (const std::exception &error) {
        result.success = false;
        result.error_code = error.what();
    }
    result.rng_state = rng.state();
    return result;
}

} // namespace ptcg::ai

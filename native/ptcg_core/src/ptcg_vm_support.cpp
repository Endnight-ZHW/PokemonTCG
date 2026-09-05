#include "ptcg_rules.hpp"
#include "ptcg_rules_internal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <unordered_set>


namespace ptcg::ai::rules_detail {

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
    std::int64_t fallback
) {
    const Value *value = args.find(key);
    return value == nullptr ? fallback : value->as_integer(fallback);
}

bool bool_arg(
    const Value &args,
    const std::string &key,
    bool fallback
) {
    const Value *value = args.find(key);
    return value == nullptr ? fallback : value->as_bool(fallback);
}

std::string string_arg(
    const Value &args,
    const std::string &key,
    std::string fallback
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
    const std::string &filter
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
    const std::string &purpose
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
    std::int64_t fallback
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

} // namespace ptcg::ai::rules_detail

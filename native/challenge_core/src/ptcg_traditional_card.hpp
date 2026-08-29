#pragma once

#include "ptcg_traditional_value.hpp"

#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai::traditional_card {

inline const Value &catalog_cards(const Value &catalog) {
    const Value *cards = traditional_value::field(catalog, "cards");
    return cards != nullptr && cards->is_object() ? *cards : catalog;
}

inline const Value *card(const Value &cards, const std::string &card_id) {
    const Value &rows = catalog_cards(cards);
    const Value *definition = traditional_value::field(rows, card_id);
    return definition != nullptr && definition->is_object()
        ? definition : nullptr;
}

inline bool has_subtype(const Value &definition, const std::string &subtype) {
    return traditional_value::array_contains(
        traditional_value::array_field(definition, "subtypes"), subtype);
}

inline bool is_pokemon(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr
        && traditional_value::string_field(*definition, "supertype")
            == "Pokémon";
}

inline bool is_basic_pokemon(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr
        && traditional_value::string_field(*definition, "supertype")
            == "Pokémon"
        && has_subtype(*definition, "Basic");
}

inline bool is_trainer(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr
        && traditional_value::string_field(*definition, "supertype")
            == "Trainer";
}

inline bool is_energy(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr
        && traditional_value::string_field(*definition, "supertype")
            == "Energy";
}

inline bool is_basic_energy(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr
        && traditional_value::string_field(*definition, "supertype")
            == "Energy"
        && has_subtype(*definition, "Basic");
}

inline bool is_special_energy(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr
        && traditional_value::string_field(*definition, "supertype")
            == "Energy"
        && has_subtype(*definition, "Special");
}

inline bool is_stage1(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr && has_subtype(*definition, "Stage 1");
}

inline bool is_stage2(const Value &cards, const std::string &card_id) {
    const Value *definition = card(cards, card_id);
    return definition != nullptr && has_subtype(*definition, "Stage 2");
}

inline bool downgrades_rainbow(const Value &definition) {
    for (const Value &effect : traditional_value::array_field(
        definition, "energy_effects"
    )) {
        if (traditional_value::string_field(effect, "kind") == "provide_energy"
            && traditional_value::bool_field(
                effect, "downgrade_if_other_special")) {
            return true;
        }
    }
    return false;
}

inline std::vector<std::string> energy_units(
    const Value &cards,
    const Value &pokemon
) {
    std::vector<std::string> result;
    const Value::Array &attached = traditional_value::array_field(
        pokemon, "energy_card_ids");
    for (std::size_t index = 0; index < attached.size(); ++index) {
        const std::string card_id = attached[index].string_or();
        const Value *definition = card(cards, card_id);
        if (definition == nullptr) continue;
        bool downgrade = false;
        if (downgrades_rainbow(*definition)) {
            for (std::size_t other = 0; other < attached.size(); ++other) {
                if (other != index
                    && is_special_energy(cards, attached[other].string_or())) {
                    downgrade = true;
                    break;
                }
            }
        }
        for (const Value &provided : traditional_value::array_field(
            *definition, "provides_energy"
        )) {
            const std::string unit = provided.string_or();
            result.push_back(
                downgrade && unit == "Rainbow" ? "Colorless" : unit);
        }
    }
    return result;
}

inline std::int64_t energy_unit_count(
    const Value &cards,
    const Value *pokemon
) {
    return pokemon == nullptr ? 0
        : static_cast<std::int64_t>(energy_units(cards, *pokemon).size());
}

inline std::int64_t energy_type_count(
    const Value &cards,
    const Value *pokemon,
    std::string energy_type
) {
    if (pokemon == nullptr) return 0;
    energy_type = traditional_value::lower_ascii(std::move(energy_type));
    const auto units = energy_units(cards, *pokemon);
    if (energy_type.empty() || energy_type == "any" || energy_type == "energy") {
        return static_cast<std::int64_t>(units.size());
    }
    return static_cast<std::int64_t>(std::count_if(
        units.begin(), units.end(), [&energy_type](const std::string &unit) {
            const std::string normalized = traditional_value::lower_ascii(unit);
            return normalized == energy_type || normalized == "rainbow";
        }));
}

inline std::int64_t missing_energy(
    const Value &cards,
    const Value &pokemon,
    const Value::Array &cost
) {
    std::vector<std::string> available = energy_units(cards, pokemon);
    std::int64_t missing = 0;
    std::int64_t colorless = 0;
    for (const Value &required_value : cost) {
        const std::string required = required_value.string_or();
        if (required == "Colorless") {
            ++colorless;
            continue;
        }
        auto found = std::find(available.begin(), available.end(), required);
        if (found == available.end()) {
            found = std::find(available.begin(), available.end(), "Rainbow");
        }
        if (found == available.end()) ++missing;
        else available.erase(found);
    }
    return missing + std::max<std::int64_t>(
        0, colorless - static_cast<std::int64_t>(available.size()));
}

inline const Value &player(const Value &state, std::int32_t actor) {
    static const Value empty = Value::make_object();
    const Value *players = traditional_value::field(state, "players");
    return players != nullptr && players->is_array() && actor >= 0
        && static_cast<std::size_t>(actor) < players->as_array().size()
        ? players->as_array()[static_cast<std::size_t>(actor)] : empty;
}

inline const Value *active(const Value &state, std::int32_t actor) {
    const Value *value = traditional_value::field(player(state, actor), "active");
    return value != nullptr && value->is_object() ? value : nullptr;
}

inline std::int64_t bench_count(const Value &owner) {
    const Value::Array &bench = traditional_value::array_field(owner, "bench");
    return static_cast<std::int64_t>(std::count_if(
        bench.begin(), bench.end(),
        [](const Value &pokemon) { return pokemon.is_object(); }));
}

} // namespace ptcg::ai::traditional_card

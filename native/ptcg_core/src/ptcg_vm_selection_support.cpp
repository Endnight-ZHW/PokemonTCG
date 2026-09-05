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

Value id_option(const std::string &id, const std::string &label) {
    Object option;
    option["kind"] = Value("id");
    option["option_id"] = Value(id);
    if (!label.empty()) {
        option["label"] = Value(label);
    }
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
    std::int64_t first_index,
    std::int64_t last_index,
    bool descending,
    const std::string &filter_name
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

void decorate_deck_search_request(
    Value &request,
    const Value &cards,
    const Value &player_value,
    std::int32_t actor
) {
    Object presentation;
    const Value *existing = request.find("presentation");
    if (existing != nullptr && existing->is_object()) {
        presentation = existing->as_object();
    }
    presentation["domain"] = Value("search");
    presentation["purpose"] = Value(string_arg(
        request,
        "continuation_kind",
        string_arg(request, "request_type", "search_move")
    ));
    presentation["source_player"] = Value(actor);
    presentation["source_zone"] = Value("deck");
    presentation["browse_card_refs"] = Value(zone_options(
        cards,
        player_value,
        actor,
        "deck",
        "any"
    ));
    request["presentation"] = Value(std::move(presentation));
}

void increment_integer(Value &object, const std::string &key) {
    set_integer(object, key, get_integer(object, key) + 1);
}

Value make_continuation(
    const std::string &op,
    const Value &command_spec,
    std::int32_t actor,
    const std::string &source_slot,
    std::int64_t stage
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

} // namespace ptcg::ai::rules_detail

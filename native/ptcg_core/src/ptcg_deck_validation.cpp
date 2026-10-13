#include "ptcg_deck_validation.hpp"

#include <algorithm>
#include <cmath>
#include <map>

namespace ptcg::ai {
namespace {
std::string text(const Value &row, const char *key) {
    const auto *value = row.find(key);
    return value ? value->string_or() : std::string{};
}
bool subtype(const Value &row, const char *name) {
    const auto *values = row.find("subtypes");
    if (!values || !values->is_array()) return false;
    return std::any_of(values->as_array().begin(), values->as_array().end(),
        [name](const Value &v) { return v.string_or() == name; });
}
}

Value validate_deck(const Value &cards, const Value &entries) {
    Value::Array errors;
    std::int64_t total = 0;
    bool basic = false;
    std::map<std::string, std::int64_t> names, limits, groups;
    auto error = [&](const char *code, const std::string &id = "",
                     std::int64_t count = 0, std::int64_t limit = 0) {
        errors.emplace_back(Value::Object{{"code", Value(code)},
            {"card_id", Value(id)}, {"count", Value(count)}, {"limit", Value(limit)}});
    };
    if (!entries.is_array() || entries.as_array().size() > 1000) {
        error("invalid_deck_entries");
    } else {
        for (const Value &entry : entries.as_array()) {
            const std::string id = entry.is_string() ? entry.string_or() : text(entry, "card_id");
            const Value *amount = entry.is_object() ? entry.find("count") : nullptr;
            if ((!entry.is_string() && (!entry.is_object() || !amount || !amount->is_number()
                || !std::isfinite(amount->as_number()) || std::floor(amount->as_number()) != amount->as_number()
                || amount->as_number() < 1.0 || amount->as_number() > 1000.0))
                || id.empty() || id.size() > 128) {
                error("invalid_deck_entry", id);
                continue;
            }
            const auto count = entry.is_string() ? 1 : amount->as_integer();
            if (count <= 0 || count > 1000) {
                error("invalid_deck_count", id, count);
                continue;
            }
            total += count;
            const Value *card = cards.find(id);
            if (!card || !card->is_object()) {
                error("unknown_card", id);
                continue;
            }
            basic = basic || (text(*card, "supertype") == "Pokémon" && subtype(*card, "Basic"));
            const bool basic_energy = text(*card, "supertype") == "Energy" && subtype(*card, "Basic");
            std::string name = text(*card, "deck_name");
            if (name.empty()) name = text(*card, "name");
            if (name.empty()) name = id;
            std::int64_t limit = basic_energy ? 60 : 4;
            if (const Value *override = card->find("deck_copy_limit")) {
                if (override->is_integer() && override->as_integer() > 0)
                    limit = override->as_integer();
            }
            names[name] += count;
            auto found = limits.find(name);
            limits[name] = found == limits.end() ? limit : std::min(found->second, limit);
            for (const char *group : {"ACE SPEC", "Radiant", "Prism Star"}) {
                if (subtype(*card, group)) {
                    // Prism Star restricts each name; the other groups restrict the whole deck.
                    groups[std::string(group) + (std::string(group) == "Prism Star" ? ":" + name : "")] += count;
                }
            }
        }
    }
    if (total != 60) error("invalid_deck_size", "", total, 60);
    if (!basic) error("missing_basic_pokemon");
    for (const auto &[name, count] : names)
        if (count > limits[name]) error("deck_name_limit", name, count, limits[name]);
    for (const auto &[group, count] : groups)
        if (count > 1) error("deck_group_limit", group, count, 1);
    return Value(Value::Object{{"valid", Value(errors.empty())},
        {"card_count", Value(total)}, {"errors", Value(std::move(errors))}});
}
}

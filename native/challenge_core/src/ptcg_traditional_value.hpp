#pragma once

#include "ptcg_value.hpp"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>

namespace ptcg::ai::traditional_value {

inline const Value *field(const Value &value, std::string_view key) noexcept {
    return value.is_object() ? value.find(std::string(key)) : nullptr;
}

inline std::string string_field(
    const Value &value,
    std::string_view key,
    std::string fallback = {}
) {
    const Value *entry = field(value, key);
    return entry == nullptr ? std::move(fallback)
                            : entry->string_or(std::move(fallback));
}

inline std::int64_t integer_field(
    const Value &value,
    std::string_view key,
    std::int64_t fallback = 0
) noexcept {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_integer(fallback);
}

inline bool bool_field(
    const Value &value,
    std::string_view key,
    bool fallback = false
) noexcept {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_bool(fallback);
}

inline double number_field(
    const Value &value,
    std::string_view key,
    double fallback = 0.0
) noexcept {
    const Value *entry = field(value, key);
    return entry == nullptr ? fallback : entry->as_number(fallback);
}

inline const Value::Array &array_field(
    const Value &value,
    std::string_view key
) noexcept {
    static const Value::Array empty;
    const Value *entry = field(value, key);
    return entry != nullptr && entry->is_array() ? entry->as_array() : empty;
}

inline bool array_contains(
    const Value::Array &values,
    const std::string &needle
) {
    return std::any_of(
        values.begin(), values.end(), [&needle](const Value &value) {
            return value.string_or() == needle;
        });
}

inline bool array_contains(const Value *values, const std::string &needle) {
    return values != nullptr && values->is_array()
        && array_contains(values->as_array(), needle);
}

inline std::string lower_ascii(std::string value) {
    std::transform(
        value.begin(), value.end(), value.begin(),
        [](unsigned char character) {
            return static_cast<char>(std::tolower(character));
        });
    return value;
}

} // namespace ptcg::ai::traditional_value

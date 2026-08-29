#pragma once

#include "ptcg_value.hpp"

#include <cstdint>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

#include <nlohmann/json.hpp>

namespace ptcg::json_adapter {

inline nlohmann::json parse_strict(const std::string &text, int max_depth = 32) {
    bool valid = true;
    int container_depth = 0;
    std::vector<std::unordered_set<std::string>> object_keys;
    auto callback = [&](int, nlohmann::json::parse_event_t event, nlohmann::json &parsed) {
        using event_t = nlohmann::json::parse_event_t;
        if (event == event_t::object_start) {
            ++container_depth;
            valid = valid && container_depth - 1 <= max_depth;
            object_keys.emplace_back();
        } else if (event == event_t::array_start) {
            ++container_depth;
            valid = valid && container_depth - 1 <= max_depth;
        } else if (event == event_t::object_end) {
            if (!object_keys.empty()) object_keys.pop_back();
            --container_depth;
        } else if (event == event_t::array_end) {
            --container_depth;
        } else if (event == event_t::key && !object_keys.empty()) {
            valid = valid && object_keys.back().insert(parsed.get<std::string>()).second;
        }
        return valid;
    };
    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(text.begin(), text.end(), callback, true, false);
    } catch (const nlohmann::json::exception &) {
        throw std::runtime_error("invalid_json");
    }
    if (!valid || parsed.is_discarded()) throw std::runtime_error("invalid_json");
    return parsed;
}

inline nlohmann::json read_strict_file(const std::string &path, int max_depth = 32) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("json_open_failed:" + path);
    input.seekg(0, std::ios::end);
    const auto size = input.tellg();
    if (size < 0 || size > 64 * 1024 * 1024) {
        throw std::runtime_error("json_size_invalid:" + path);
    }
    input.seekg(0, std::ios::beg);
    std::string text(static_cast<std::size_t>(size), '\0');
    input.read(text.data(), static_cast<std::streamsize>(text.size()));
    if (!input && !text.empty()) throw std::runtime_error("json_read_failed:" + path);
    return parse_strict(text, max_depth);
}

inline ptcg::ai::Value to_value(const nlohmann::json &source) {
    using ptcg::ai::Value;
    if (source.is_null()) return Value(nullptr);
    if (source.is_boolean()) return Value(source.get<bool>());
    if (source.is_number_unsigned()) {
        const auto value = source.get<std::uint64_t>();
        if (value > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
            throw std::runtime_error("json_integer_out_of_range");
        }
        return Value(static_cast<std::int64_t>(value));
    }
    if (source.is_number_integer()) return Value(source.get<std::int64_t>());
    if (source.is_number_float()) return Value(source.get<double>());
    if (source.is_string()) return Value(source.get<std::string>());
    if (source.is_array()) {
        Value::Array values;
        values.reserve(source.size());
        for (const auto &item : source) values.push_back(to_value(item));
        return Value(std::move(values));
    }
    if (source.is_object()) {
        Value::Object values;
        for (auto item = source.begin(); item != source.end(); ++item) {
            values.emplace(item.key(), to_value(item.value()));
        }
        return Value(std::move(values));
    }
    throw std::runtime_error("unsupported_json_value");
}

inline nlohmann::json from_value(const ptcg::ai::Value &source) {
    using Type = ptcg::ai::Value::Type;
    switch (source.type()) {
        case Type::null_value:
            return nullptr;
        case Type::boolean:
            return source.as_bool();
        case Type::integer:
            return source.as_integer();
        case Type::number:
            return source.as_number();
        case Type::string:
            return source.as_string();
        case Type::array: {
            nlohmann::json result = nlohmann::json::array();
            for (const ptcg::ai::Value &entry : source.as_array()) {
                result.push_back(from_value(entry));
            }
            return result;
        }
        case Type::object: {
            nlohmann::json result = nlohmann::json::object();
            for (const auto &[key, entry] : source.as_object()) {
                result[key] = from_value(entry);
            }
            return result;
        }
    }
    throw std::runtime_error("unsupported_value_type");
}

} // namespace ptcg::json_adapter

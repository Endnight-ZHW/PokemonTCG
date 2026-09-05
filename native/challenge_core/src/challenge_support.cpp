#include "challenge_support.hpp"
#include "../../common/ptcg_sha256.hpp"
#include "../../common/ptcg_json_string.hpp"

#include <array>
#include <charconv>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>

namespace ptcg::ai::challenge {

std::string json_scalar_text(const Value &value) {
    switch (value.type()) {
        case Value::Type::null_value:
            return "null";
        case Value::Type::boolean:
            return value.as_bool() ? "true" : "false";
        case Value::Type::integer:
            return std::to_string(value.as_integer());
        case Value::Type::number: {
            const double number = value.as_number();
            if (!std::isfinite(number)) return "null";
            std::array<char, 64> buffer{};
            const auto converted = std::to_chars(
                buffer.data(), buffer.data() + buffer.size(), number,
                std::chars_format::general,
                std::numeric_limits<double>::max_digits10);
            if (converted.ec == std::errc{}) {
                return std::string(buffer.data(), converted.ptr);
            }
            std::ostringstream fallback;
            fallback << std::setprecision(17) << number;
            return fallback.str();
        }
        case Value::Type::string: {
            std::string result;
            json_text::append_string(result, value.as_string());
            return result;
        }
        case Value::Type::array:
        case Value::Type::object:
            throw std::logic_error("json_scalar_requires_scalar");
    }
    throw std::logic_error("invalid_value_type");
}

std::string sha256_text(const std::string &value) {
    return crypto::sha256(value);
}

std::uint32_t string_hash32(const std::string &value) noexcept {
    // Godot String::hash uses the 32-bit DJB2 family. Challenge identifiers
    // are UTF-8; every action/sequence signature itself is ASCII.
    std::uint32_t hash = 5381U;
    for (const unsigned char byte : value) {
        hash = ((hash << 5U) + hash) + static_cast<std::uint32_t>(byte);
    }
    return hash;
}

} // namespace ptcg::ai::challenge

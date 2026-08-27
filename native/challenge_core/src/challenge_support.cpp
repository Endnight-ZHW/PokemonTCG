#include "challenge_support.hpp"

#include <array>
#include <charconv>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>

namespace ptcg::ai::challenge {
namespace {

void append_json_string(std::string &output, const std::string &value) {
    static constexpr char hex[] = "0123456789abcdef";
    output.push_back('"');
    for (const unsigned char byte : value) {
        switch (byte) {
            case '"': output += "\\\""; break;
            case '\\': output += "\\\\"; break;
            case '\b': output += "\\b"; break;
            case '\f': output += "\\f"; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default:
                if (byte < 0x20U) {
                    output += "\\u00";
                    output.push_back(hex[(byte >> 4U) & 0x0fU]);
                    output.push_back(hex[byte & 0x0fU]);
                } else {
                    output.push_back(static_cast<char>(byte));
                }
                break;
        }
    }
    output.push_back('"');
}

constexpr std::array<std::uint32_t, 64> SHA256_K{
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
};

constexpr std::uint32_t rotate_right(std::uint32_t value, unsigned bits) {
    return (value >> bits) | (value << (32U - bits));
}

void sha256_block(
    std::array<std::uint32_t, 8> &state,
    const unsigned char *block
) {
    std::array<std::uint32_t, 64> words{};
    for (std::size_t index = 0; index < 16; ++index) {
        const std::size_t offset = index * 4;
        words[index] = (static_cast<std::uint32_t>(block[offset]) << 24U)
            | (static_cast<std::uint32_t>(block[offset + 1]) << 16U)
            | (static_cast<std::uint32_t>(block[offset + 2]) << 8U)
            | static_cast<std::uint32_t>(block[offset + 3]);
    }
    for (std::size_t index = 16; index < words.size(); ++index) {
        const std::uint32_t x = words[index - 15];
        const std::uint32_t y = words[index - 2];
        const std::uint32_t s0 = rotate_right(x, 7) ^ rotate_right(x, 18) ^ (x >> 3U);
        const std::uint32_t s1 = rotate_right(y, 17) ^ rotate_right(y, 19) ^ (y >> 10U);
        words[index] = words[index - 16] + s0 + words[index - 7] + s1;
    }
    std::uint32_t a = state[0];
    std::uint32_t b = state[1];
    std::uint32_t c = state[2];
    std::uint32_t d = state[3];
    std::uint32_t e = state[4];
    std::uint32_t f = state[5];
    std::uint32_t g = state[6];
    std::uint32_t h = state[7];
    for (std::size_t index = 0; index < words.size(); ++index) {
        const std::uint32_t sum1 = rotate_right(e, 6) ^ rotate_right(e, 11)
            ^ rotate_right(e, 25);
        const std::uint32_t choice = (e & f) ^ (~e & g);
        const std::uint32_t temp1 = h + sum1 + choice + SHA256_K[index] + words[index];
        const std::uint32_t sum0 = rotate_right(a, 2) ^ rotate_right(a, 13)
            ^ rotate_right(a, 22);
        const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        const std::uint32_t temp2 = sum0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

} // namespace

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
            append_json_string(result, value.as_string());
            return result;
        }
        case Value::Type::array:
        case Value::Type::object:
            throw std::logic_error("json_scalar_requires_scalar");
    }
    throw std::logic_error("invalid_value_type");
}

std::string sha256_text(const std::string &value) {
    std::array<std::uint32_t, 8> state{
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
    };
    const std::uint64_t bit_length = static_cast<std::uint64_t>(value.size()) * 8U;
    std::size_t offset = 0;
    while (offset + 64 <= value.size()) {
        sha256_block(state, reinterpret_cast<const unsigned char *>(value.data() + offset));
        offset += 64;
    }
    std::array<unsigned char, 128> tail{};
    const std::size_t remaining = value.size() - offset;
    if (remaining > 0) {
        std::memcpy(tail.data(), value.data() + offset, remaining);
    }
    tail[remaining] = 0x80U;
    const std::size_t padded = remaining < 56 ? 64 : 128;
    for (std::size_t index = 0; index < 8; ++index) {
        tail[padded - 1 - index] = static_cast<unsigned char>(bit_length >> (index * 8U));
    }
    sha256_block(state, tail.data());
    if (padded == 128) sha256_block(state, tail.data() + 64);
    static constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(64);
    for (const std::uint32_t word : state) {
        for (int shift = 28; shift >= 0; shift -= 4) {
            result.push_back(hex[(word >> static_cast<unsigned>(shift)) & 0x0fU]);
        }
    }
    return result;
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

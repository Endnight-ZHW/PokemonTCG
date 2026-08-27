#include "ptcg_traditional_strategy.hpp"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

using ptcg::ai::TraditionalStrategyCatalog;
using ptcg::ai::Value;

namespace {

class Reader {
public:
    explicit Reader(const char *path) : input_(path, std::ios::binary) {
        if (!input_) throw std::runtime_error("fixture_open_failed");
    }

    std::string bytes() {
        const std::uint32_t size = scalar<std::uint32_t>();
        if (size > 16U * 1024U * 1024U) throw std::runtime_error("fixture_size_invalid");
        std::string value(size, '\0');
        input_.read(value.data(), static_cast<std::streamsize>(size));
        if (!input_) throw std::runtime_error("fixture_truncated");
        return value;
    }

    Value value() {
        const char tag = scalar<char>();
        if (tag == 'n') return Value(nullptr);
        if (tag == 'f') return Value(false);
        if (tag == 't') return Value(true);
        if (tag == 'i') return Value(scalar<std::int64_t>());
        if (tag == 'd') return Value(scalar<double>());
        if (tag == 's') return Value(bytes());
        if (tag == 'a') {
            const std::uint32_t count = scalar<std::uint32_t>();
            Value::Array rows;
            rows.reserve(count);
            for (std::uint32_t index = 0; index < count; ++index) {
                rows.push_back(value());
            }
            return Value(std::move(rows));
        }
        if (tag == 'o') {
            const std::uint32_t count = scalar<std::uint32_t>();
            Value::Object rows;
            for (std::uint32_t index = 0; index < count; ++index) {
                std::string key = bytes();
                Value item = value();
                rows.emplace(std::move(key), std::move(item));
            }
            return Value(std::move(rows));
        }
        throw std::runtime_error("fixture_tag_invalid");
    }

    template <typename T>
    T scalar() {
        T value{};
        input_.read(reinterpret_cast<char *>(&value), sizeof(value));
        if (!input_) throw std::runtime_error("fixture_truncated");
        return value;
    }

private:
    std::ifstream input_;
};

const Value &field(const Value &value, const char *key) {
    const Value *found = value.find(key);
    if (found == nullptr) throw std::runtime_error(std::string("field_missing:") + key);
    return *found;
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc != 2) throw std::runtime_error("fixture_path_required");
        Reader reader(argv[1]);
        if (reader.scalar<char>() != 'P'
            || reader.scalar<char>() != 'T'
            || reader.scalar<char>() != 'C'
            || reader.scalar<char>() != 'G'
            || reader.scalar<char>() != 'T'
            || reader.scalar<char>() != 'A'
            || reader.scalar<char>() != 'C'
            || reader.scalar<char>() != 'T'
            || reader.scalar<char>() != '1') {
            throw std::runtime_error("fixture_magic_invalid");
        }
        Value strategies = reader.value();
        Value cards = reader.value();
        TraditionalStrategyCatalog catalog(
            std::move(strategies), std::move(cards));
        if (!catalog.valid()) throw std::runtime_error("strategy_catalog_invalid");
        const std::uint32_t count = reader.scalar<std::uint32_t>();
        for (std::uint32_t index = 0; index < count; ++index) {
            const Value row = reader.value();
            const Value &state = field(row, "state");
            const Value &preferred = field(row, "preferred");
            const Value &over = field(row, "over");
            const std::string surface = field(row, "surface").string_or();
            const double preferred_score = surface == "choice"
                ? catalog.choice_score(state, 0, field(row, "choice"), preferred)
                : catalog.action_score(state, 0, preferred);
            const double over_score = surface == "choice"
                ? catalog.choice_score(state, 0, field(row, "choice"), over)
                : catalog.action_score(state, 0, over);
            if (!(preferred_score > over_score)) {
                std::cerr << field(row, "id").string_or() << ": "
                          << preferred_score << " <= " << over_score << '\n';
                return 3;
            }
        }
        std::cout << "CHALLENGE_CORE_TACTICS_OK scenarios=" << count << '\n';
        return count == 109 ? 0 : 4;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 2;
    }
}

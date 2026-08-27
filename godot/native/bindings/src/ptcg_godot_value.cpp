#include "ptcg_godot_value.hpp"

#include <stdexcept>
#include <string>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace ptcg::ai {

namespace {

std::string utf8_string(const godot::String &source) {
    const godot::CharString encoded = source.utf8();
    return std::string(encoded.get_data(), encoded.length());
}

} // namespace

Value value_from_godot(const godot::Variant &source) {
    using godot::Variant;
    switch (source.get_type()) {
        case Variant::NIL:
            return Value();
        case Variant::BOOL:
            return Value(static_cast<bool>(source));
        case Variant::INT:
            return Value(static_cast<std::int64_t>(source));
        case Variant::FLOAT:
            return Value(static_cast<double>(source));
        case Variant::STRING:
        case Variant::STRING_NAME:
            return Value(utf8_string(godot::String(source)));
        case Variant::ARRAY: {
            const godot::Array values = source;
            Value::Array result;
            result.reserve(static_cast<std::size_t>(values.size()));
            for (int64_t index = 0; index < values.size(); ++index) {
                result.push_back(value_from_godot(values[index]));
            }
            return Value(std::move(result));
        }
        case Variant::DICTIONARY: {
            const godot::Dictionary values = source;
            const godot::Array keys = values.keys();
            Value::Object result;
            for (int64_t index = 0; index < keys.size(); ++index) {
                const Variant key = keys[index];
                result[utf8_string(godot::String(key))] = value_from_godot(
                    values[key]
                );
            }
            return Value(std::move(result));
        }
        default:
            throw std::invalid_argument("unsupported_godot_value_type");
    }
}

godot::Variant value_to_godot(const Value &source) {
    using godot::Variant;
    switch (source.type()) {
        case Value::Type::null_value:
            return Variant();
        case Value::Type::boolean:
            return Variant(source.as_bool());
        case Value::Type::integer:
            return Variant(source.as_integer());
        case Value::Type::number:
            return Variant(source.as_number());
        case Value::Type::string:
            return Variant(godot::String::utf8(source.as_string().c_str()));
        case Value::Type::array: {
            godot::Array result;
            result.resize(static_cast<int64_t>(source.as_array().size()));
            for (
                std::size_t index = 0;
                index < source.as_array().size();
                ++index
            ) {
                result[static_cast<int64_t>(index)] = value_to_godot(
                    source.as_array()[index]
                );
            }
            return Variant(result);
        }
        case Value::Type::object: {
            godot::Dictionary result;
            for (const auto &[key, value] : source.as_object()) {
                result[godot::String::utf8(key.c_str())] = value_to_godot(
                    value
                );
            }
            return Variant(result);
        }
    }
    return Variant();
}

} // namespace ptcg::ai

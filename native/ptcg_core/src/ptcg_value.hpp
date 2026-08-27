#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace ptcg::ai {

// Small dependency-free JSON-shaped value used at the shared rules boundary.
// Godot and the opt-in Deep AI research binding translate their native
// mapping/array types to this representation once, outside the simulation loop.
class Value {
public:
    enum class Type : std::uint8_t {
        null_value,
        boolean,
        integer,
        number,
        string,
        array,
        object,
    };

    using Array = std::vector<Value>;
    using Object = std::map<std::string, Value, std::less<>>;

    Value() = default;
    Value(std::nullptr_t) {}
    Value(bool value) : type_(Type::boolean), boolean_(value) {}
    Value(std::int64_t value) : type_(Type::integer), integer_(value) {}
    Value(int value) : Value(static_cast<std::int64_t>(value)) {}
    Value(double value) : type_(Type::number), number_(value) {}
    Value(std::string value)
        : type_(Type::string), string_(std::move(value)) {}
    Value(const char *value) : Value(std::string(value)) {}
    Value(Array value)
        : type_(Type::array),
          array_(std::make_shared<Array>(std::move(value))) {}
    Value(Object value)
        : type_(Type::object),
          object_(std::make_shared<Object>(std::move(value))) {}

    static Value make_array() {
        return Value(Array{});
    }

    static Value make_object() {
        return Value(Object{});
    }

    Type type() const noexcept {
        return type_;
    }

    bool is_null() const noexcept {
        return type_ == Type::null_value;
    }

    bool is_bool() const noexcept {
        return type_ == Type::boolean;
    }

    bool is_integer() const noexcept {
        return type_ == Type::integer;
    }

    bool is_number() const noexcept {
        return type_ == Type::number || type_ == Type::integer;
    }

    bool is_string() const noexcept {
        return type_ == Type::string;
    }

    bool is_array() const noexcept {
        return type_ == Type::array;
    }

    bool is_object() const noexcept {
        return type_ == Type::object;
    }

    bool as_bool(bool fallback = false) const noexcept {
        return type_ == Type::boolean ? boolean_ : fallback;
    }

    std::int64_t as_integer(std::int64_t fallback = 0) const noexcept {
        if (type_ == Type::integer) {
            return integer_;
        }
        if (type_ == Type::number) {
            return static_cast<std::int64_t>(number_);
        }
        return fallback;
    }

    double as_number(double fallback = 0.0) const noexcept {
        if (type_ == Type::number) {
            return number_;
        }
        if (type_ == Type::integer) {
            return static_cast<double>(integer_);
        }
        return fallback;
    }

    const std::string &as_string() const {
        if (type_ != Type::string) {
            throw std::logic_error("value_is_not_string");
        }
        return string_;
    }

    std::string string_or(std::string fallback = {}) const {
        return type_ == Type::string ? string_ : std::move(fallback);
    }

    Array &as_array() {
        if (type_ != Type::array) {
            throw std::logic_error("value_is_not_array");
        }
        if (!array_) {
            array_ = std::make_shared<Array>();
        } else if (!array_.unique()) {
            array_ = std::make_shared<Array>(*array_);
        }
        return *array_;
    }

    const Array &as_array() const {
        if (type_ != Type::array) {
            throw std::logic_error("value_is_not_array");
        }
        if (!array_) {
            static const Array empty;
            return empty;
        }
        return *array_;
    }

    Object &as_object() {
        if (type_ != Type::object) {
            throw std::logic_error("value_is_not_object");
        }
        if (!object_) {
            object_ = std::make_shared<Object>();
        } else if (!object_.unique()) {
            object_ = std::make_shared<Object>(*object_);
        }
        return *object_;
    }

    const Object &as_object() const {
        if (type_ != Type::object) {
            throw std::logic_error("value_is_not_object");
        }
        if (!object_) {
            static const Object empty;
            return empty;
        }
        return *object_;
    }

    Value &operator[](const std::string &key) {
        if (type_ == Type::null_value) {
            type_ = Type::object;
            object_ = std::make_shared<Object>();
        }
        return as_object()[key];
    }

    const Value *find(const std::string &key) const noexcept {
        if (type_ != Type::object) {
            return nullptr;
        }
        if (!object_) {
            return nullptr;
        }
        const auto found = object_->find(key);
        return found == object_->end() ? nullptr : &found->second;
    }

    Value *find(const std::string &key) {
        if (type_ != Type::object) {
            return nullptr;
        }
        if (!object_) {
            return nullptr;
        }
        if (!object_.unique()) {
            object_ = std::make_shared<Object>(*object_);
        }
        const auto found = object_->find(key);
        return found == object_->end() ? nullptr : &found->second;
    }

    bool contains(const std::string &key) const noexcept {
        return find(key) != nullptr;
    }

    bool erase(const std::string &key) {
        if (type_ != Type::object) {
            return false;
        }
        return as_object().erase(key) > 0;
    }

    Value deep_clone() const {
        switch (type_) {
            case Type::null_value:
                return Value();
            case Type::boolean:
                return Value(boolean_);
            case Type::integer:
                return Value(integer_);
            case Type::number:
                return Value(number_);
            case Type::string:
                return Value(string_);
            case Type::array: {
                Array clone;
                const Array &source = as_array();
                clone.reserve(source.size());
                for (const Value &entry : source) {
                    clone.push_back(entry.deep_clone());
                }
                return Value(std::move(clone));
            }
            case Type::object: {
                Object clone;
                for (const auto &[key, entry] : as_object()) {
                    clone.emplace(key, entry.deep_clone());
                }
                return Value(std::move(clone));
            }
        }
        throw std::logic_error("unsupported_value_type");
    }

    bool operator==(const Value &other) const noexcept {
        if (type_ != other.type_) {
            return is_number() && other.is_number()
                && as_number() == other.as_number();
        }
        switch (type_) {
            case Type::null_value:
                return true;
            case Type::boolean:
                return boolean_ == other.boolean_;
            case Type::integer:
                return integer_ == other.integer_;
            case Type::number:
                return number_ == other.number_;
            case Type::string:
                return string_ == other.string_;
            case Type::array:
                return (
                    array_ == other.array_
                    || (
                        array_ && other.array_
                        && *array_ == *other.array_
                    )
                );
            case Type::object:
                return (
                    object_ == other.object_
                    || (
                        object_ && other.object_
                        && *object_ == *other.object_
                    )
                );
        }
        return false;
    }

private:
    Type type_ = Type::null_value;
    bool boolean_ = false;
    std::int64_t integer_ = 0;
    double number_ = 0.0;
    std::string string_;
    std::shared_ptr<Array> array_;
    std::shared_ptr<Object> object_;
};

} // namespace ptcg::ai

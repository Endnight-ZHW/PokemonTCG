#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

#include <nlohmann/json.hpp>

namespace ptcg::relay {

inline constexpr int kProtocolVersion = 6;
inline constexpr std::size_t kMaxMessageBytes = 262144;
inline constexpr std::size_t kMaxControlMessageBytes = 1024;
inline constexpr int kMaxMessagesPerSecond = 60;
inline constexpr int kMaxJsonDepth = 32;
inline constexpr std::int64_t kMaxWireInteger = 2147483647;

enum class ControlType { create_room, join_room, resume_room };

struct ControlCommand {
    ControlType type = ControlType::create_room;
    std::string room_id;
    std::string role;
    std::string resume_token;
};

struct JsonResult {
    bool ok = false;
    nlohmann::json value;
    std::string error;
};

struct ControlResult {
    bool ok = false;
    ControlCommand command;
    std::string error;
};

struct ValidationResult {
    bool ok = false;
    std::string error;
};

JsonResult parse_strict_json_object(std::string_view raw, std::string object_error);
ControlResult parse_control_message(std::string_view raw, bool is_text = true);
ValidationResult validate_forward_message(
    const nlohmann::json &message,
    std::string_view room_id,
    int sender
);
nlohmann::json error_message(std::string message);

} // namespace ptcg::relay

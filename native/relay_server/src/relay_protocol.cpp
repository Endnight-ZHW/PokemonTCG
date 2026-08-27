#include "relay_protocol.hpp"

#include <array>
#include <regex>
#include <unordered_set>
#include <vector>

namespace ptcg::relay {
namespace {

const std::regex kRoomCode("^[0-9]{4}$");
const std::regex kResumeToken("^[A-Za-z0-9_-]{16,128}$");
const std::unordered_set<std::string> kMessageTypes = {
    "welcome", "deck_select", "lobby_update", "state_update",
    "action_submit", "choice_submit", "resync_request", "surrender",
    "ping", "pong", "error",
};

bool exact_keys(const nlohmann::json &row, std::initializer_list<const char *> keys) {
    if (row.size() != keys.size()) {
        return false;
    }
    for (const char *key : keys) {
        if (!row.contains(key)) {
            return false;
        }
    }
    return true;
}

bool is_wire_integer(const nlohmann::json &value) {
    return value.is_number_integer() && !value.is_boolean();
}

} // namespace

JsonResult parse_strict_json_object(std::string_view raw, std::string object_error) {
    JsonResult result;
    bool valid = true;
    int container_depth = 0;
    std::vector<std::unordered_set<std::string>> object_keys;
    try {
        auto callback = [&](int, nlohmann::json::parse_event_t event, nlohmann::json &parsed) {
            using event_t = nlohmann::json::parse_event_t;
            if (event == event_t::object_start) {
                ++container_depth;
                if (container_depth - 1 > kMaxJsonDepth) {
                    valid = false;
                }
                object_keys.emplace_back();
            } else if (event == event_t::array_start) {
                ++container_depth;
                if (container_depth - 1 > kMaxJsonDepth) {
                    valid = false;
                }
            } else if (event == event_t::object_end) {
                if (!object_keys.empty()) {
                    object_keys.pop_back();
                }
                --container_depth;
            } else if (event == event_t::array_end) {
                --container_depth;
            } else if (event == event_t::key && !object_keys.empty()) {
                if (!object_keys.back().insert(parsed.get<std::string>()).second) {
                    valid = false;
                }
            }
            return valid;
        };
        result.value = nlohmann::json::parse(raw.begin(), raw.end(), callback, true, false);
    } catch (const nlohmann::json::exception &) {
        result.error = "收到无效JSON。";
        return result;
    }
    if (!valid || result.value.is_discarded()) {
        result.error = "收到无效JSON。";
        return result;
    }
    if (!result.value.is_object()) {
        result.error = std::move(object_error);
        return result;
    }
    result.ok = true;
    return result;
}

ControlResult parse_control_message(std::string_view raw, bool is_text) {
    ControlResult result;
    if (!is_text) {
        result.error = "只接受 UTF-8 JSON 文本控制消息。";
        return result;
    }
    if (raw.size() > kMaxControlMessageBytes) {
        result.error = "控制消息超过大小限制。";
        return result;
    }
    JsonResult parsed = parse_strict_json_object(raw, "控制消息必须是对象。");
    if (!parsed.ok) {
        result.error = parsed.error == "收到无效JSON。" ? "收到无效JSON控制消息。" : parsed.error;
        return result;
    }
    const auto &message = parsed.value;
    if (!message.contains("type") || !message["type"].is_string()) {
        result.error = "未知命令: null";
        return result;
    }
    const std::string type = message["type"].get<std::string>();
    if (type == "create_room") {
        if (!exact_keys(message, {"type"})) {
            result.error = "创建房间控制消息包含未知字段。";
            return result;
        }
        result.command.type = ControlType::create_room;
    } else if (type == "join_room") {
        if (!exact_keys(message, {"type", "room_id"}) || !message["room_id"].is_string()) {
            result.error = "加入房间控制消息字段无效。";
            return result;
        }
        result.command.room_id = message["room_id"].get<std::string>();
        if (!std::regex_match(result.command.room_id, kRoomCode)) {
            result.error = "房间号格式无效。";
            return result;
        }
        result.command.type = ControlType::join_room;
    } else if (type == "resume_room") {
        if (!exact_keys(message, {"type", "room_id", "role", "resume_token"}) ||
            !message["room_id"].is_string() || !message["role"].is_string() ||
            !message["resume_token"].is_string()) {
            result.error = "恢复房间控制消息字段无效。";
            return result;
        }
        result.command.room_id = message["room_id"].get<std::string>();
        result.command.role = message["role"].get<std::string>();
        result.command.resume_token = message["resume_token"].get<std::string>();
        if (!std::regex_match(result.command.room_id, kRoomCode)) {
            result.error = "房间号格式无效。";
            return result;
        }
        if (result.command.role != "p1" && result.command.role != "p2") {
            result.error = "恢复房间角色无效。";
            return result;
        }
        if (!std::regex_match(result.command.resume_token, kResumeToken)) {
            result.error = "恢复凭证无效。";
            return result;
        }
        result.command.type = ControlType::resume_room;
    } else {
        result.error = "未知命令: " + type;
        return result;
    }
    result.ok = true;
    return result;
}

ValidationResult validate_forward_message(
    const nlohmann::json &message,
    std::string_view room_id,
    int sender
) {
    const std::array<const char *, 9> required = {
        "protocol_version", "message_type", "room_id", "sender", "sequence",
        "state_revision", "action_id", "request_id", "payload",
    };
    for (const char *key : required) {
        if (!message.contains(key)) {
            return {false, "协议 v6 消息缺少必要字段。"};
        }
    }
    if (!is_wire_integer(message["protocol_version"]) || message["protocol_version"] != kProtocolVersion) {
        return {false, "协议版本不兼容；旧 v5 房间不能恢复，请双方更新到协议 v6。"};
    }
    if (!message["room_id"].is_string() || message["room_id"].get<std::string>() != room_id) {
        return {false, "消息房间号不匹配。"};
    }
    if (!is_wire_integer(message["sender"]) || message["sender"] != sender) {
        return {false, "消息发送方与连接身份不匹配。"};
    }
    if (!message["message_type"].is_string() ||
        kMessageTypes.count(message["message_type"].get<std::string>()) == 0) {
        return {false, "未知协议 v6 消息类型。"};
    }
    if (!message["payload"].is_object()) {
        return {false, "协议 v6 payload 必须是对象。"};
    }
    if (!is_wire_integer(message["sequence"]) || message["sequence"] <= 0 ||
        message["sequence"] > kMaxWireInteger ||
        !is_wire_integer(message["state_revision"]) || message["state_revision"] < -1 ||
        message["state_revision"] > kMaxWireInteger) {
        return {false, "协议 v6 序号或局面版本无效。"};
    }
    if (!message["action_id"].is_string() || !message["request_id"].is_string()) {
        return {false, "协议 v6 标识符必须是字符串。"};
    }
    if (message["action_id"].get_ref<const std::string &>().size() > 128 ||
        message["request_id"].get_ref<const std::string &>().size() > 128) {
        return {false, "协议 v6 标识符编码无效或过长。"};
    }
    return {true, {}};
}

nlohmann::json error_message(std::string message) {
    return {
        {"type", "error"},
        {"message", std::move(message)},
        {"expected_version", kProtocolVersion},
    };
}

} // namespace ptcg::relay

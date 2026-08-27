#include "relay_protocol.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

using nlohmann::json;
using namespace ptcg::relay;

namespace {

void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

json valid_frame() {
    return {
        {"protocol_version", 6},
        {"message_type", "ping"},
        {"room_id", "1234"},
        {"sender", 0},
        {"sequence", 1},
        {"state_revision", -1},
        {"action_id", ""},
        {"request_id", "request-1"},
        {"payload", json::object()},
    };
}

} // namespace

int main() {
    auto create = parse_control_message(R"({"type":"create_room"})");
    require(create.ok && create.command.type == ControlType::create_room, "create control");

    auto join = parse_control_message(R"({"type":"join_room","room_id":"1234"})");
    require(join.ok && join.command.room_id == "1234", "join control");
    require(!parse_control_message(R"({"type":"join_room","room_id":"12"})").ok, "room code format");
    require(!parse_control_message(R"({"type":"create_room","padding":1})").ok, "unknown create key");
    require(!parse_control_message(R"({"type":"create_room","type":"join_room"})").ok, "duplicate key");
    require(!parse_control_message(R"({"type":"create_room"})", false).ok, "binary control");

    auto resume = parse_control_message(
        R"({"type":"resume_room","room_id":"1234","role":"p2","resume_token":"abcdefghijklmnop"})"
    );
    require(resume.ok && resume.command.role == "p2", "resume control");
    require(!parse_control_message(
        R"({"type":"resume_room","room_id":"1234","role":"p3","resume_token":"abcdefghijklmnop"})"
    ).ok, "resume role");

    require(!parse_strict_json_object(R"({"value":NaN})", "object").ok, "non-finite JSON");
    require(!parse_strict_json_object(R"([1,2])", "object").ok, "object boundary");
    std::string deep = R"({"v":)";
    deep.append(34, '[');
    deep += "0";
    deep.append(34, ']');
    deep += "}";
    require(!parse_strict_json_object(deep, "object").ok, "JSON depth");

    json frame = valid_frame();
    require(validate_forward_message(frame, "1234", 0).ok, "valid v6 frame");
    frame["protocol_version"] = 5;
    require(!validate_forward_message(frame, "1234", 0).ok, "protocol 5 rejection");
    frame = valid_frame();
    frame["sender"] = true;
    require(!validate_forward_message(frame, "1234", 0).ok, "bool is not wire integer");
    frame = valid_frame();
    frame["sequence"] = 2147483648LL;
    require(!validate_forward_message(frame, "1234", 0).ok, "sequence bound");
    frame = valid_frame();
    frame["action_id"] = std::string(129, 'x');
    require(!validate_forward_message(frame, "1234", 0).ok, "identifier bound");
    frame = valid_frame();
    frame.erase("payload");
    require(!validate_forward_message(frame, "1234", 0).ok, "required field");

    const auto error = error_message("bad");
    require(error["type"] == "error" && error["expected_version"] == 6, "error envelope");
    std::cout << "RELAY_PROTOCOL_TESTS_OK\n";
    return 0;
}

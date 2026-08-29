#include "challenge_controller.hpp"
#include "challenge_support.hpp"
#include "ptcg_json_adapter.hpp"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#endif

#ifndef PTCG_AGENT_IMPLEMENTATION_HASH
#define PTCG_AGENT_IMPLEMENTATION_HASH "unversioned"
#endif

#ifndef PTCG_AGENT_BUILD_ID
#define PTCG_AGENT_BUILD_ID "working-tree"
#endif

namespace {

using Json = nlohmann::json;
using ptcg::ai::ChallengeController;
using ptcg::ai::Value;

constexpr const char *PROTOCOL = "ptcg.challenge_agent.ipc/1";
constexpr std::size_t MAX_LINE_BYTES = 16U * 1024U * 1024U;

std::string required_string(const Json &source, const char *key) {
    const auto found = source.find(key);
    if (found == source.end() || !found->is_string()
        || found->get<std::string>().empty()) {
        throw std::runtime_error(std::string("agent_config_missing:") + key);
    }
    return found->get<std::string>();
}

void emit(Json response) {
    response["protocol"] = PROTOCOL;
    std::cout << response.dump() << '\n' << std::flush;
}

Json error_response(const Json &id, const std::string &error) {
    return Json{
        {"id", id},
        {"success", false},
        {"error", error},
    };
}

std::string read_file_bytes(const std::string &path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("agent_config_file_unreadable:" + path);
    return std::string(
        std::istreambuf_iterator<char>(stream),
        std::istreambuf_iterator<char>());
}

void verify_file_hash(
    const Json &config,
    const std::string &path,
    const char *hash_key
) {
    if (ptcg::ai::challenge::sha256_text(read_file_bytes(path))
        != required_string(config, hash_key)) {
        throw std::runtime_error(std::string("agent_config_hash_mismatch:") + hash_key);
    }
}

} // namespace

int main(int argc, char **argv) {
#if defined(_WIN32)
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    if (argc != 3 || std::string(argv[1]) != "--config") {
        std::cerr << "usage: ptcg_challenge_agent --config <path>\n";
        return 2;
    }
    ChallengeController controller;
    Value configured;
    try {
        const Json config = ptcg::json_adapter::read_strict_file(argv[2], 32);
        if (!config.is_object()) throw std::runtime_error("agent_config_not_object");
        const std::string strategy_hash = required_string(
            config, "strategies_hash");
        const std::string catalog_path = required_string(config, "catalog_path");
        const std::string decks_path = required_string(config, "decks_path");
        const std::string strategies_path = required_string(
            config, "strategies_path");
        verify_file_hash(config, catalog_path, "catalog_file_sha256");
        verify_file_hash(config, decks_path, "decks_file_sha256");
        verify_file_hash(config, strategies_path, "strategies_file_sha256");
        const Json catalog_json = ptcg::json_adapter::read_strict_file(
            catalog_path, 64);
        const Json decks_json = ptcg::json_adapter::read_strict_file(
            decks_path, 32);
        const Json strategies_json = ptcg::json_adapter::read_strict_file(
            strategies_path, 64);
        configured = controller.configure(
            ptcg::json_adapter::to_value(catalog_json),
            ptcg::json_adapter::to_value(decks_json),
            ptcg::json_adapter::to_value(strategies_json));
        Value contract = controller.get_contract();
        contract["agent_protocol"] = Value(PROTOCOL);
        contract["implementation_hash"] = Value(PTCG_AGENT_IMPLEMENTATION_HASH);
        contract["build_id"] = Value(PTCG_AGENT_BUILD_ID);
        emit(Json{
            {"type", "ready"},
            {"success", configured.find("success") != nullptr
                && configured.find("success")->as_bool(false)},
            {"error", configured.find("error") == nullptr
                ? "" : configured.find("error")->string_or()},
            {"implementation_hash", PTCG_AGENT_IMPLEMENTATION_HASH},
            {"strategy_hash", strategy_hash},
            {"build_id", PTCG_AGENT_BUILD_ID},
            {"contract", ptcg::json_adapter::from_value(contract)},
        });
    } catch (const std::exception &error) {
        emit(Json{
            {"type", "ready"},
            {"success", false},
            {"error", error.what()},
            {"implementation_hash", PTCG_AGENT_IMPLEMENTATION_HASH},
            {"build_id", PTCG_AGENT_BUILD_ID},
        });
        return 3;
    }

    std::string line;
    while (std::getline(std::cin, line)) {
        Json id = nullptr;
        try {
            if (line.size() > MAX_LINE_BYTES) {
                throw std::runtime_error("agent_request_too_large");
            }
            const Json request = ptcg::json_adapter::parse_strict(line, 64);
            if (!request.is_object()) throw std::runtime_error("agent_request_not_object");
            if (request.value("protocol", "") != PROTOCOL) {
                throw std::runtime_error("agent_protocol_mismatch");
            }
            const auto id_field = request.find("id");
            if (id_field == request.end()) throw std::runtime_error("agent_request_id_missing");
            id = *id_field;
            const std::string operation = request.value("op", "");
            if (operation == "reset") {
                controller.reset_match(required_string(request, "match_id"));
                emit(Json{{"id", id}, {"success", true}});
            } else if (operation == "decide") {
                const auto request_value = request.find("request");
                if (request_value == request.end() || !request_value->is_object()) {
                    throw std::runtime_error("agent_decision_request_missing");
                }
                const std::int64_t generation = request.value<std::int64_t>(
                    "generation", 1);
                const Value result = controller.decide(
                    ptcg::json_adapter::to_value(*request_value), generation);
                emit(Json{
                    {"id", id},
                    {"success", true},
                    {"result", ptcg::json_adapter::from_value(result)},
                });
            } else if (operation == "cancel") {
                controller.cancel(request.value<std::int64_t>("generation", 1));
                emit(Json{{"id", id}, {"success", true}});
            } else if (operation == "contract") {
                Value contract = controller.get_contract();
                contract["agent_protocol"] = Value(PROTOCOL);
                contract["implementation_hash"] = Value(
                    PTCG_AGENT_IMPLEMENTATION_HASH);
                contract["build_id"] = Value(PTCG_AGENT_BUILD_ID);
                emit(Json{
                    {"id", id},
                    {"success", true},
                    {"contract", ptcg::json_adapter::from_value(contract)},
                });
            } else if (operation == "shutdown") {
                emit(Json{{"id", id}, {"success", true}});
                return 0;
            } else {
                throw std::runtime_error("agent_operation_unknown");
            }
        } catch (const std::exception &error) {
            emit(error_response(id, error.what()));
        }
    }
    return 0;
}

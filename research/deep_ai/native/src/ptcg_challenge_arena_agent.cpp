#include "ptcg_challenge_arena.hpp"

#include "ptcg_json_adapter.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>

#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#endif

namespace ptcg::ai {
namespace {

using Json = nlohmann::json;
constexpr const char *AGENT_PROTOCOL = "ptcg.challenge_agent.ipc/1";
constexpr std::size_t MAX_LINE_BYTES = 16U * 1024U * 1024U;

Value error_value(const std::string &error, bool cancelled = false) {
    return Value(Value::Object{
        {"success", Value(false)},
        {"cancelled", Value(cancelled)},
        {"error", Value(error)},
    });
}

class InProcessChallengeArenaAgent final : public ChallengeArenaAgent {
public:
    InProcessChallengeArenaAgent(
        const ChallengeArenaAgentSpec &spec,
        const Value &catalog,
        const Value &decks
    ) : implementation_hash_(spec.implementation_hash) {
        try {
            configured_ = controller_.configure(catalog, decks, spec.strategies);
            ready_ = configured_.find("success") != nullptr
                && configured_.find("success")->as_bool(false);
            error_ = configured_.find("error") == nullptr
                ? std::string{} : configured_.find("error")->string_or();
        } catch (const std::exception &error) {
            error_ = error.what();
        } catch (...) {
            error_ = "unknown_in_process_configuration_error";
        }
    }

    bool ready() const noexcept override { return ready_; }
    std::string configuration_error() const override { return error_; }
    Value decide(const Value &request, std::int64_t generation) override {
        return controller_.decide(request, generation);
    }
    Value reset_match(const std::string &match_id) override {
        controller_.reset_match(match_id);
        return Value(Value::Object{{"success", Value(true)}});
    }
    void cancel(std::int64_t generation) noexcept override {
        controller_.cancel(generation);
    }
    Value contract() const override {
        Value result = controller_.get_contract();
        result["agent_backend"] = Value("in_process");
        result["implementation_hash"] = Value(implementation_hash_);
        return result;
    }

private:
    ChallengeController controller_;
    Value configured_ = Value::make_object();
    std::string implementation_hash_;
    std::string error_;
    bool ready_ = false;
};

#if defined(_WIN32)

std::wstring wide(const std::string &value) {
    if (value.empty()) return {};
    const int count = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0);
    if (count <= 0) throw std::runtime_error("external_agent_path_not_utf8");
    std::wstring result(static_cast<std::size_t>(count), L'\0');
    if (MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
            static_cast<int>(value.size()), result.data(), count) != count) {
        throw std::runtime_error("external_agent_path_conversion_failed");
    }
    return result;
}

std::wstring quote_argument(const std::wstring &value) {
    std::wstring result = L"\"";
    std::size_t slashes = 0;
    for (const wchar_t character : value) {
        if (character == L'\\') {
            ++slashes;
        } else if (character == L'\"') {
            result.append(slashes * 2 + 1, L'\\');
            result.push_back(L'\"');
            slashes = 0;
        } else {
            result.append(slashes, L'\\');
            slashes = 0;
            result.push_back(character);
        }
    }
    result.append(slashes * 2, L'\\');
    result.push_back(L'\"');
    return result;
}

std::string safe_file_stem(std::string value) {
    for (char &character : value) {
        const unsigned char byte = static_cast<unsigned char>(character);
        if (!std::isalnum(byte) && character != '-' && character != '_'
            && character != '.') {
            character = '_';
        }
    }
    return value.empty() ? "agent" : value;
}

class ExternalProcessChallengeArenaAgent final : public ChallengeArenaAgent {
public:
    explicit ExternalProcessChallengeArenaAgent(const ChallengeArenaAgentSpec &spec)
        : expected_implementation_hash_(spec.implementation_hash),
          expected_strategy_hash_(spec.strategy_hash),
          timeout_milliseconds_(spec.decision_timeout_milliseconds) {
        try {
            start(spec);
            const Json ready = read_message(30000);
            if (ready.value("protocol", "") != AGENT_PROTOCOL
                || ready.value("type", "") != "ready") {
                throw std::runtime_error("external_agent_ready_protocol_invalid");
            }
            if (!ready.value("success", false)) {
                throw std::runtime_error(
                    "external_agent_configuration_failed:"
                    + ready.value("error", "unknown"));
            }
            if (ready.value("implementation_hash", "")
                != expected_implementation_hash_) {
                throw std::runtime_error("external_agent_implementation_hash_mismatch");
            }
            if (ready.value("strategy_hash", "") != expected_strategy_hash_) {
                throw std::runtime_error("external_agent_strategy_hash_mismatch");
            }
            const auto contract = ready.find("contract");
            if (contract == ready.end() || !contract->is_object()) {
                throw std::runtime_error("external_agent_contract_missing");
            }
            if (contract->value("schema", "") != "ptcg.native_challenge_ai/1"
                || contract->value("action_schema_version", 0) != 4
                || contract->value("choice_view_schema_version", 0) != 2
                || contract->value("snapshot_schema_version", 0) != 3
                || !contract->value("callback_free", false)) {
                throw std::runtime_error("external_agent_contract_incompatible");
            }
            contract_ = ptcg::json_adapter::to_value(*contract);
            ready_ = true;
        } catch (const std::exception &error) {
            error_ = error.what();
            terminate();
        } catch (...) {
            error_ = "unknown_external_agent_start_error";
            terminate();
        }
    }

    ~ExternalProcessChallengeArenaAgent() override {
        if (ready_ && process_alive()) {
            try {
                (void)transact("shutdown", Json::object(), 2000);
            } catch (...) {}
        }
        terminate();
        close_handles();
    }

    bool ready() const noexcept override { return ready_; }
    std::string configuration_error() const override { return error_; }

    Value decide(const Value &request, std::int64_t generation) override {
        if (!ready_) return error_value(error_.empty()
            ? "external_agent_not_ready" : error_);
        try {
            const Json response = transact(
                "decide",
                Json{
                    {"request", ptcg::json_adapter::from_value(request)},
                    {"generation", generation},
                },
                timeout_milliseconds_);
            if (!response.value("success", false)) {
                return error_value("external_agent_protocol_error:"
                    + response.value("error", "unknown"));
            }
            const auto result = response.find("result");
            if (result == response.end() || !result->is_object()) {
                return error_value("external_agent_result_missing");
            }
            return ptcg::json_adapter::to_value(*result);
        } catch (const std::exception &error) {
            error_ = error.what();
            terminate();
            return error_value(error_);
        }
    }

    Value reset_match(const std::string &match_id) override {
        if (!ready_) return error_value(error_.empty()
            ? "external_agent_not_ready" : error_);
        try {
            const Json response = transact(
                "reset", Json{{"match_id", match_id}}, 10000);
            return response.value("success", false)
                ? Value(Value::Object{{"success", Value(true)}})
                : error_value(response.value("error", "external_agent_reset_failed"));
        } catch (const std::exception &error) {
            error_ = error.what();
            terminate();
            return error_value(error_);
        }
    }

    void cancel(std::int64_t) noexcept override {
        cancelled_ = true;
        terminate();
    }

    Value contract() const override { return contract_; }

private:
    void start(const ChallengeArenaAgentSpec &spec) {
        if (spec.executable_path.empty() || spec.process_config_path.empty()
            || spec.implementation_hash.empty() || spec.strategy_hash.empty()) {
            throw std::runtime_error("external_agent_spec_incomplete");
        }
        SECURITY_ATTRIBUTES security{};
        security.nLength = sizeof(security);
        security.bInheritHandle = TRUE;
        HANDLE child_stdin_read = nullptr;
        HANDLE child_stdout_write = nullptr;
        if (!CreatePipe(&child_stdout_read_, &child_stdout_write, &security, 0)
            || !SetHandleInformation(child_stdout_read_, HANDLE_FLAG_INHERIT, 0)
            || !CreatePipe(&child_stdin_read, &child_stdin_write_, &security, 0)
            || !SetHandleInformation(child_stdin_write_, HANDLE_FLAG_INHERIT, 0)) {
            if (child_stdin_read != nullptr) CloseHandle(child_stdin_read);
            if (child_stdout_write != nullptr) CloseHandle(child_stdout_write);
            throw std::runtime_error("external_agent_pipe_creation_failed");
        }
        HANDLE error_handle = CreateFileW(
            L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (!spec.process_log_directory.empty()) {
            const std::filesystem::path directory(spec.process_log_directory);
            std::filesystem::create_directories(directory);
            const std::filesystem::path log = directory /
                (safe_file_stem(spec.agent_id) + "-"
                    + std::to_string(GetCurrentThreadId()) + ".log");
            HANDLE file = CreateFileW(
                log.wstring().c_str(), FILE_APPEND_DATA,
                FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file != INVALID_HANDLE_VALUE) {
                if (error_handle != INVALID_HANDLE_VALUE) CloseHandle(error_handle);
                error_handle = file;
            }
        }
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = child_stdin_read;
        startup.hStdOutput = child_stdout_write;
        startup.hStdError = error_handle;
        PROCESS_INFORMATION process{};
        std::wstring command = quote_argument(wide(spec.executable_path))
            + L" --config " + quote_argument(wide(spec.process_config_path));
        const BOOL created = CreateProcessW(
            nullptr, command.data(), nullptr, nullptr, TRUE,
            CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
        CloseHandle(child_stdin_read);
        CloseHandle(child_stdout_write);
        if (error_handle != INVALID_HANDLE_VALUE) CloseHandle(error_handle);
        if (!created) throw std::runtime_error("external_agent_process_start_failed");
        process_handle_.store(process.hProcess, std::memory_order_release);
        thread_handle_ = process.hThread;
    }

    Json transact(
        const std::string &operation,
        Json payload,
        std::uint32_t timeout
    ) {
        std::lock_guard<std::mutex> lock(transaction_mutex_);
        if (!process_alive()) throw std::runtime_error("external_agent_process_exited");
        const std::uint64_t id = ++request_id_;
        payload["protocol"] = AGENT_PROTOCOL;
        payload["id"] = id;
        payload["op"] = operation;
        write_message(payload);
        const Json response = read_message(timeout);
        if (response.value("protocol", "") != AGENT_PROTOCOL
            || response.value<std::uint64_t>("id", 0) != id) {
            throw std::runtime_error("external_agent_response_mismatch");
        }
        return response;
    }

    void write_message(const Json &message) {
        const std::string line = message.dump() + "\n";
        if (line.size() > MAX_LINE_BYTES) {
            throw std::runtime_error("external_agent_request_too_large");
        }
        std::size_t offset = 0;
        while (offset < line.size()) {
            DWORD written = 0;
            if (!WriteFile(
                    child_stdin_write_, line.data() + offset,
                    static_cast<DWORD>(line.size() - offset), &written, nullptr)
                || written == 0) {
                throw std::runtime_error("external_agent_write_failed");
            }
            offset += written;
        }
    }

    Json read_message(std::uint32_t timeout) {
        const auto deadline = std::chrono::steady_clock::now()
            + std::chrono::milliseconds(timeout);
        std::string line;
        while (std::chrono::steady_clock::now() < deadline) {
            if (cancelled_) throw std::runtime_error("external_agent_cancelled");
            DWORD available = 0;
            if (!PeekNamedPipe(
                    child_stdout_read_, nullptr, 0, nullptr, &available, nullptr)) {
                throw std::runtime_error("external_agent_read_failed");
            }
            if (available == 0) {
                if (!process_alive()) {
                    throw std::runtime_error("external_agent_process_exited");
                }
                Sleep(1);
                continue;
            }
            char buffer[4096];
            DWORD read = 0;
            if (!ReadFile(
                    child_stdout_read_, buffer,
                    static_cast<DWORD>(std::min<std::size_t>(
                        sizeof(buffer), available)), &read, nullptr)) {
                throw std::runtime_error("external_agent_read_failed");
            }
            for (DWORD index = 0; index < read; ++index) {
                if (buffer[index] == '\n') {
                    return ptcg::json_adapter::parse_strict(line, 64);
                }
                line.push_back(buffer[index]);
                if (line.size() > MAX_LINE_BYTES) {
                    throw std::runtime_error("external_agent_response_too_large");
                }
            }
        }
        throw std::runtime_error("external_agent_timeout");
    }

    bool process_alive() const noexcept {
        HANDLE process = process_handle_.load(std::memory_order_acquire);
        return process != nullptr
            && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    }

    void terminate() noexcept {
        HANDLE process = process_handle_.load(std::memory_order_acquire);
        if (process != nullptr && WaitForSingleObject(process, 0) == WAIT_TIMEOUT) {
            TerminateProcess(process, 20);
            WaitForSingleObject(process, 5000);
        }
    }

    void close_handles() noexcept {
        if (child_stdin_write_ != nullptr) CloseHandle(child_stdin_write_);
        if (child_stdout_read_ != nullptr) CloseHandle(child_stdout_read_);
        if (thread_handle_ != nullptr) CloseHandle(thread_handle_);
        HANDLE process = process_handle_.exchange(nullptr, std::memory_order_acq_rel);
        if (process != nullptr) CloseHandle(process);
        child_stdin_write_ = nullptr;
        child_stdout_read_ = nullptr;
        thread_handle_ = nullptr;
    }

    std::string expected_implementation_hash_;
    std::string expected_strategy_hash_;
    std::uint32_t timeout_milliseconds_ = 120000;
    std::string error_;
    Value contract_ = Value::make_object();
    std::atomic<HANDLE> process_handle_{nullptr};
    HANDLE thread_handle_ = nullptr;
    HANDLE child_stdin_write_ = nullptr;
    HANDLE child_stdout_read_ = nullptr;
    std::mutex transaction_mutex_;
    std::uint64_t request_id_ = 0;
    std::atomic<bool> cancelled_{false};
    bool ready_ = false;
};

#endif

class UnsupportedExternalAgent final : public ChallengeArenaAgent {
public:
    bool ready() const noexcept override { return false; }
    std::string configuration_error() const override {
        return "external_agent_backend_requires_windows";
    }
    Value decide(const Value &, std::int64_t) override {
        return error_value(configuration_error());
    }
    Value reset_match(const std::string &) override {
        return error_value(configuration_error());
    }
    void cancel(std::int64_t) noexcept override {}
    Value contract() const override { return Value::make_object(); }
};

} // namespace

std::unique_ptr<ChallengeArenaAgent> make_challenge_arena_agent(
    const ChallengeArenaAgentSpec &spec,
    const Value &catalog,
    const Value &decks
) {
    if (spec.backend == "in_process") {
        return std::make_unique<InProcessChallengeArenaAgent>(
            spec, catalog, decks);
    }
    if (spec.backend == "external_process") {
#if defined(_WIN32)
        return std::make_unique<ExternalProcessChallengeArenaAgent>(spec);
#else
        return std::make_unique<UnsupportedExternalAgent>();
#endif
    }
    throw std::invalid_argument("unknown_challenge_arena_agent_backend");
}

} // namespace ptcg::ai

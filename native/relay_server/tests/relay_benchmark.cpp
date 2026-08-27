#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace net = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
using tcp = net::ip::tcp;
using json = nlohmann::json;
using clock_type = std::chrono::steady_clock;

namespace {

class Client {
public:
    Client(const std::string &host, const std::string &port, const std::string &forwarded)
        : websocket_(context_) {
        tcp::resolver resolver(context_);
        beast::get_lowest_layer(websocket_).connect(resolver.resolve(host, port));
        const std::string authority = host.find(':') == std::string::npos
            ? host + ":" + port : "[" + host + "]:" + port;
        websocket_.set_option(websocket::stream_base::decorator(
            [forwarded](websocket::request_type &request) {
                request.set("X-Forwarded-For", forwarded);
            }
        ));
        websocket_.handshake(authority, "/");
    }

    void send(const json &message) {
        const std::string wire = message.dump();
        websocket_.write(net::buffer(wire));
    }

    json receive() {
        beast::flat_buffer buffer;
        websocket_.read(buffer);
        return json::parse(beast::buffers_to_string(buffer.data()));
    }

    void disconnect() {
        beast::error_code ignored;
        beast::get_lowest_layer(websocket_).socket().shutdown(tcp::socket::shutdown_both, ignored);
        beast::get_lowest_layer(websocket_).socket().close(ignored);
    }

private:
    net::io_context context_;
    websocket::stream<beast::tcp_stream> websocket_;
};

struct Pair {
    std::unique_ptr<Client> host;
    std::unique_ptr<Client> guest;
    std::string room;
};

json frame(const std::string &room, int sender, int sequence, const char *phase) {
    return {
        {"protocol_version", 6}, {"message_type", "ping"}, {"room_id", room},
        {"sender", sender}, {"sequence", sequence}, {"state_revision", -1},
        {"action_id", ""},
        {"request_id", std::string(phase) + "-" + std::to_string(sequence)},
        {"payload", {{"phase", phase}}},
    };
}

Pair create_pair(const std::string &host, const std::string &port, int index) {
    Pair pair;
    const std::string source = "198.18." + std::to_string(index / 250)
        + "." + std::to_string(index % 250 + 1);
    pair.host = std::make_unique<Client>(host, port, source);
    pair.host->send({{"type", "create_room"}});
    const json created = pair.host->receive();
    if (created.value("type", "") != "room_created") throw std::runtime_error("create_failed");
    pair.room = created.value("room_id", "");
    pair.guest = std::make_unique<Client>(host, port, source);
    pair.guest->send({{"type", "join_room"}, {"room_id", pair.room}});
    if (pair.guest->receive().value("type", "") != "room_joined") {
        throw std::runtime_error("join_failed");
    }
    if (pair.host->receive().value("type", "") != "opponent_joined"
        || pair.guest->receive().value("type", "") != "opponent_joined") {
        throw std::runtime_error("pair_failed");
    }
    return pair;
}

struct PhaseResult {
    std::int64_t messages = 0;
    double seconds = 0.0;
    double throughput = 0.0;
    double p95_ms = 0.0;
    int failures = 0;
};

PhaseResult run_phase(
    std::vector<Pair> &pairs,
    int rounds,
    std::chrono::milliseconds interval,
    const char *name
) {
    std::mutex latency_mutex;
    std::vector<double> latencies;
    latencies.reserve(pairs.size() * static_cast<std::size_t>(rounds) * 2U);
    std::atomic<int> failures{0};
    std::vector<std::thread> workers;
    const auto started = clock_type::now();
    for (Pair &pair : pairs) {
        workers.emplace_back([&pair, rounds, interval, name, &latencies, &latency_mutex, &failures] {
            try {
                auto deadline = clock_type::now();
                std::vector<double> local;
                local.reserve(static_cast<std::size_t>(rounds) * 2U);
                for (int round = 1; round <= rounds; ++round) {
                    auto sent = clock_type::now();
                    pair.host->send(frame(pair.room, 0, round, name));
                    if (pair.guest->receive().value("sequence", 0) != round) ++failures;
                    local.push_back(std::chrono::duration<double, std::milli>(clock_type::now() - sent).count());
                    sent = clock_type::now();
                    pair.guest->send(frame(pair.room, 1, round, name));
                    if (pair.host->receive().value("sequence", 0) != round) ++failures;
                    local.push_back(std::chrono::duration<double, std::milli>(clock_type::now() - sent).count());
                    if (interval.count() > 0) {
                        deadline += interval;
                        std::this_thread::sleep_until(deadline);
                    }
                }
                std::lock_guard<std::mutex> lock(latency_mutex);
                latencies.insert(latencies.end(), local.begin(), local.end());
            } catch (const std::exception &) {
                ++failures;
            }
        });
    }
    for (auto &worker : workers) worker.join();
    const double seconds = std::chrono::duration<double>(clock_type::now() - started).count();
    std::sort(latencies.begin(), latencies.end());
    const std::int64_t expected = static_cast<std::int64_t>(pairs.size()) * rounds * 2;
    const std::size_t p95_index = latencies.empty() ? 0
        : std::min(latencies.size() - 1, static_cast<std::size_t>(latencies.size() * 0.95));
    return {
        expected,
        seconds,
        expected / seconds,
        latencies.empty() ? 0.0 : latencies[p95_index],
        failures.load() + static_cast<int>(expected - static_cast<std::int64_t>(latencies.size())),
    };
}

json phase_json(const PhaseResult &result) {
    return {
        {"messages", result.messages}, {"seconds", result.seconds},
        {"throughput_messages_per_second", result.throughput},
        {"p95_latency_ms", result.p95_ms}, {"failures", result.failures},
    };
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc != 3) throw std::runtime_error("usage: relay_benchmark <host> <port>");
        constexpr int room_count = 100;
        std::vector<Pair> pairs;
        pairs.reserve(room_count);
        for (int index = 0; index < room_count; ++index) {
            pairs.push_back(create_pair(argv[1], argv[2], index));
            // Keep setup below the legacy and current 60 handshakes/source/s
            // boundary so the same load client can measure either server.
            if ((index + 1) % 25 == 0 && index + 1 < room_count) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1100));
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1100));
        const PhaseResult sustained = run_phase(
            pairs, 120, std::chrono::milliseconds(25), "sustained");
        std::this_thread::sleep_for(std::chrono::milliseconds(1100));
        const PhaseResult burst = run_phase(
            pairs, 60, std::chrono::milliseconds(0), "burst60");
        for (Pair &pair : pairs) {
            pair.guest->disconnect();
            pair.host->disconnect();
        }
        const bool success = sustained.failures == 0 && burst.failures == 0;
        std::cout << "RELAY_BENCHMARK " << json({
            {"rooms", room_count}, {"connections", room_count * 2},
            {"sustained", phase_json(sustained)}, {"burst_60_per_connection", phase_json(burst)},
            {"legal_frames_lost", sustained.failures + burst.failures}, {"success", success},
        }).dump() << '\n';
        return success ? 0 : 3;
    } catch (const std::exception &error) {
        std::cerr << "RELAY_BENCHMARK_FAILED: " << error.what() << '\n';
        return 2;
    }
}

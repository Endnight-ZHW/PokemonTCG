#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <nlohmann/json.hpp>

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <thread>

namespace net = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace websocket = beast::websocket;
using tcp = net::ip::tcp;
using json = nlohmann::json;

namespace {

void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

class Client {
public:
    Client(const std::string &host, const std::string &port, std::string forwarded = {})
        : websocket_(context_) {
        tcp::resolver resolver(context_);
        const auto endpoints = resolver.resolve(host, port);
        beast::get_lowest_layer(websocket_).connect(endpoints);
        if (!forwarded.empty()) {
            websocket_.set_option(websocket::stream_base::decorator(
                [forwarded = std::move(forwarded)](websocket::request_type &request) {
                    request.set("X-Forwarded-For", forwarded);
                }
            ));
        }
        const std::string authority = host.find(':') == std::string::npos
            ? host + ":" + port : "[" + host + "]:" + port;
        websocket_.handshake(authority, "/");
    }

    void send(const json &message) {
        const std::string wire = message.dump();
        websocket_.write(net::buffer(wire));
    }

    void send_wire(const std::string &wire) {
        websocket_.text(true);
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

json frame(const std::string &room, int sender, int sequence, int protocol = 6) {
    return {
        {"protocol_version", protocol},
        {"message_type", "ping"},
        {"room_id", room},
        {"sender", sender},
        {"sequence", sequence},
        {"state_revision", -1},
        {"action_id", ""},
        {"request_id", "integration-" + std::to_string(sequence)},
        {"payload", json::object()},
    };
}

struct Pair {
    std::unique_ptr<Client> host;
    std::unique_ptr<Client> guest;
    std::string room;
    std::string host_token;
    std::string guest_token;
};

Pair make_pair(const std::string &host, const std::string &port) {
    Pair result;
    result.host = std::make_unique<Client>(host, port);
    result.host->send({{"type", "create_room"}});
    const json created = result.host->receive();
    require(created.value("type", "") == "room_created", "room creation");
    result.room = created.value("room_id", "");
    result.host_token = created.value("resume_token", "");
    result.guest = std::make_unique<Client>(host, port);
    result.guest->send({{"type", "join_room"}, {"room_id", result.room}});
    const json joined = result.guest->receive();
    require(joined.value("type", "") == "room_joined", "room join");
    result.guest_token = joined.value("resume_token", "");
    require(result.host->receive().value("type", "") == "opponent_joined", "host paired");
    require(result.guest->receive().value("type", "") == "opponent_joined", "guest paired");
    return result;
}

void basic_and_resume(const std::string &host, const std::string &port) {
    Pair pair = make_pair(host, port);
    const json first = frame(pair.room, 0, 1);
    pair.host->send(first);
    require(pair.guest->receive() == first, "transparent forward");

    pair.host->send(frame(pair.room, 0, 2, 5));
    const json rejected = pair.host->receive();
    require(rejected.value("type", "") == "error" && rejected.value("expected_version", 0) == 6,
        "protocol 5 rejection");

    pair.guest->disconnect();
    require(pair.host->receive().value("type", "") == "opponent_disconnected", "disconnect notice");
    auto resumed = std::make_unique<Client>(host, port);
    resumed->send({
        {"type", "resume_room"}, {"room_id", pair.room}, {"role", "p2"},
        {"resume_token", pair.guest_token},
    });
    require(resumed->receive().value("type", "") == "room_resumed", "room resume");
    require(pair.host->receive().value("type", "") == "opponent_joined", "host resume notice");
    require(resumed->receive().value("type", "") == "opponent_joined", "guest resume notice");
    const json resumed_frame = frame(pair.room, 1, 3);
    resumed->send(resumed_frame);
    require(pair.host->receive() == resumed_frame, "forward after resume");
    resumed->disconnect();
    pair.host->disconnect();
}

void concurrent_join(const std::string &host, const std::string &port) {
    auto owner = std::make_unique<Client>(host, port);
    owner->send({{"type", "create_room"}});
    const std::string room = owner->receive().value("room_id", "");
    auto left = std::make_unique<Client>(host, port);
    auto right = std::make_unique<Client>(host, port);
    json left_reply;
    json right_reply;
    std::thread a([&] {
        left->send({{"type", "join_room"}, {"room_id", room}});
        left_reply = left->receive();
    });
    std::thread b([&] {
        right->send({{"type", "join_room"}, {"room_id", room}});
        right_reply = right->receive();
    });
    a.join();
    b.join();
    const int joined = static_cast<int>(left_reply.value("type", "") == "room_joined")
        + static_cast<int>(right_reply.value("type", "") == "room_joined");
    const int rejected = static_cast<int>(left_reply.value("type", "") == "error")
        + static_cast<int>(right_reply.value("type", "") == "error");
    require(joined == 1 && rejected == 1, "atomic guest slot claim");
    require(owner->receive().value("type", "") == "opponent_joined", "single join notice");
    Client *winner = left_reply.value("type", "") == "room_joined" ? left.get() : right.get();
    require(winner->receive().value("type", "") == "opponent_joined", "winning guest pair notice");
    left->disconnect();
    right->disconnect();
    owner->disconnect();
}

void rate_limit(const std::string &host, const std::string &port) {
    Pair pair = make_pair(host, port);
    std::atomic<int> received{0};
    std::thread reader([&] {
        for (int index = 0; index < 59; ++index) {
            if (pair.guest->receive().value("message_type", "") == "ping") {
                ++received;
            }
        }
    });
    for (int sequence = 1; sequence <= 60; ++sequence) {
        pair.host->send(frame(pair.room, 0, sequence));
    }
    const json limited = pair.host->receive();
    reader.join();
    require(received.load() == 59, "frames below rate limit");
    require(limited.value("type", "") == "error"
        && limited.value("message", "").find("频率") != std::string::npos,
        "rate limit error");
    pair.guest->disconnect();
    pair.host->disconnect();
}

void trusted_proxy_header(const std::string &host, const std::string &port) {
    Client client(host, port, "198.51.100.17");
    client.send({{"type", "not_a_command"}});
    require(client.receive().value("type", "") == "error", "proxy control response");
    client.disconnect();
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc != 3 && argc != 4) {
            throw std::runtime_error("usage: relay_integration_tests <host> <port> [smoke]");
        }
        basic_and_resume(argv[1], argv[2]);
        if (argc == 4 && std::string(argv[3]) == "smoke") {
            std::cout << "RELAY_IPV6_TEST_OK\n";
            return 0;
        }
        concurrent_join(argv[1], argv[2]);
        rate_limit(argv[1], argv[2]);
        trusted_proxy_header(argv[1], argv[2]);
        std::cout << "RELAY_INTEGRATION_TESTS_OK\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "RELAY_INTEGRATION_TEST_FAILED: " << error.what() << '\n';
        return 2;
    }
}

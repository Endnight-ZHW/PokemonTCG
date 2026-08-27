#include "relay_protocol.hpp"

#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cctype>
#include <csignal>
#include <cstdlib>
#include <deque>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <bcrypt.h>
#else
#include <cerrno>
#include <sys/random.h>
#endif

#ifndef PTCG_RELAY_VERSION_MAJOR
#define PTCG_RELAY_VERSION_MAJOR 0
#define PTCG_RELAY_VERSION_MINOR 0
#define PTCG_RELAY_VERSION_PATCH 0
#endif
#define PTCG_STRINGIFY_INNER(value) #value
#define PTCG_STRINGIFY(value) PTCG_STRINGIFY_INNER(value)
#define PTCG_RELAY_VERSION \
    PTCG_STRINGIFY(PTCG_RELAY_VERSION_MAJOR) "." \
    PTCG_STRINGIFY(PTCG_RELAY_VERSION_MINOR) "." \
    PTCG_STRINGIFY(PTCG_RELAY_VERSION_PATCH)

namespace net = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace websocket = beast::websocket;
using tcp = net::ip::tcp;
using json = nlohmann::json;
using clock_type = std::chrono::steady_clock;
using namespace std::chrono_literals;

namespace ptcg::relay {
namespace {

constexpr auto kRoomWaitTimeout = 120s;
constexpr auto kRoomTtl = 3600s;
constexpr auto kReconnectGrace = 120s;
constexpr std::size_t kMaxQueuedMessages = 32;
constexpr std::size_t kMaxQueuedBytes = kMaxMessageBytes * 4;

std::mutex g_log_mutex;

void log_event(std::string level, std::string event, json fields = json::object()) {
    fields["level"] = std::move(level);
    fields["event"] = std::move(event);
    fields["timestamp_ms"] = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()
    ).count();
    std::lock_guard<std::mutex> lock(g_log_mutex);
    std::cout << fields.dump() << '\n' << std::flush;
}

bool secure_random(unsigned char *destination, std::size_t size) {
#ifdef _WIN32
    return BCryptGenRandom(
        nullptr,
        destination,
        static_cast<ULONG>(size),
        BCRYPT_USE_SYSTEM_PREFERRED_RNG
    ) == 0;
#else
    std::size_t offset = 0;
    while (offset < size) {
        const ssize_t read = ::getrandom(destination + offset, size - offset, 0);
        if (read > 0) {
            offset += static_cast<std::size_t>(read);
            continue;
        }
        if (read < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
#endif
}

std::string make_resume_token() {
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::array<unsigned char, 32> bytes{};
    if (!secure_random(bytes.data(), bytes.size())) {
        throw std::runtime_error("operating-system CSPRNG failed");
    }
    std::string result;
    result.reserve(43);
    std::uint32_t accumulator = 0;
    int bits = 0;
    for (unsigned char byte : bytes) {
        accumulator = (accumulator << 8U) | byte;
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            result.push_back(alphabet[(accumulator >> bits) & 63U]);
        }
    }
    if (bits > 0) {
        result.push_back(alphabet[(accumulator << (6 - bits)) & 63U]);
    }
    return result;
}

class FixedWindowLimiter {
public:
    bool allow() {
        const auto now = clock_type::now();
        if (now - started_ >= 1s) {
            started_ = now;
            count_ = 0;
        }
        ++count_;
        return count_ <= kMaxMessagesPerSecond;
    }

private:
    clock_type::time_point started_ = clock_type::now();
    int count_ = 0;
};

class KeyedRateLimiter {
public:
    bool allow(const std::string &key) {
        const auto now = clock_type::now();
        const auto cutoff = now - 1s;
        std::lock_guard<std::mutex> lock(mutex_);
        auto &events = events_[key];
        while (!events.empty() && events.front() <= cutoff) {
            events.pop_front();
        }
        if (events.size() >= static_cast<std::size_t>(kMaxMessagesPerSecond)) {
            return false;
        }
        events.push_back(now);
        if (++cleanup_counter_ % 128 == 0) {
            for (auto it = events_.begin(); it != events_.end();) {
                auto &row = it->second;
                while (!row.empty() && row.front() <= cutoff) {
                    row.pop_front();
                }
                it = row.empty() ? events_.erase(it) : std::next(it);
            }
        }
        return true;
    }

private:
    std::mutex mutex_;
    std::unordered_map<std::string, std::deque<clock_type::time_point>> events_;
    std::size_t cleanup_counter_ = 0;
};

class RelayState;

class Session : public std::enable_shared_from_this<Session> {
public:
    Session(tcp::socket socket, std::shared_ptr<RelayState> state, std::optional<net::ip::address> trusted_proxy);
    ~Session();

    void run();
    void assign(std::string room, std::string role, json response, std::chrono::seconds wait);
    void paired();
    void send_json(json message);
    void send_text(std::string message);
    void reject(std::string message);
    void forward_error(std::string message);
    const std::string &room() const { return room_; }
    const std::string &role() const { return role_; }

private:
    void read_http_request();
    void on_http_request(beast::error_code error, std::size_t transferred);
    void accept_websocket();
    void send_http(http::status status, std::string body);
    void read_message();
    void on_message(beast::error_code error, std::size_t transferred);
    void handle_control(std::string raw, bool is_text);
    void handle_forward(std::string raw, bool is_text);
    void enqueue(std::string message, bool close_after);
    void write_next();
    void on_write(beast::error_code error, std::size_t transferred);
    void begin_close();
    void finish(std::string reason);
    void arm_wait(std::chrono::seconds duration);
    std::string source_key() const;

    websocket::stream<beast::tcp_stream> websocket_;
    beast::flat_buffer input_;
    http::request<http::string_body> request_;
    std::shared_ptr<RelayState> state_;
    net::steady_timer wait_timer_;
    std::optional<net::ip::address> trusted_proxy_;
    std::string remote_address_;
    std::string forwarded_address_;
    std::string room_;
    std::string role_;
    std::deque<std::string> outgoing_;
    std::size_t outgoing_bytes_ = 0;
    FixedWindowLimiter rate_limiter_;
    bool websocket_open_ = false;
    bool control_complete_ = false;
    bool paired_ = false;
    bool writing_ = false;
    bool close_after_flush_ = false;
    bool finished_ = false;
    bool connection_counted_ = false;
};

class RelayState : public std::enable_shared_from_this<RelayState> {
public:
    RelayState(net::io_context &context, std::size_t max_rooms)
        : strand_(net::make_strand(context)), cleanup_timer_(strand_), max_rooms_(max_rooms) {}

    void start() { schedule_cleanup(); }
    void create(const std::shared_ptr<Session> &session);
    void join(const std::shared_ptr<Session> &session, std::string room_id);
    void resume(
        const std::shared_ptr<Session> &session,
        std::string room_id,
        std::string role,
        std::string token
    );
    void forward(const std::shared_ptr<Session> &session, std::string raw);
    void disconnected(const std::shared_ptr<Session> &session, std::string room_id, std::string role);
    bool allow_handshake(const std::string &source) { return handshake_limiter_.allow(source); }
    void connection_opened() { connections_.fetch_add(1, std::memory_order_relaxed); }
    void connection_closed() { connections_.fetch_sub(1, std::memory_order_relaxed); }
    json health() const {
        return {
            {"status", "ok"},
            {"connections", connections_.load(std::memory_order_relaxed)},
            {"rooms", room_count_.load(std::memory_order_relaxed)},
            {"version", PTCG_RELAY_VERSION},
            {"protocol", kProtocolVersion},
        };
    }

private:
    struct Room {
        std::weak_ptr<Session> p1;
        std::weak_ptr<Session> p2;
        std::string p1_token;
        std::string p2_token;
        clock_type::time_point created = clock_type::now();
        clock_type::time_point last_active = created;
    };

    void schedule_cleanup();
    void cleanup();
    std::string generate_code();
    static std::weak_ptr<Session> &slot(Room &room, const std::string &role) {
        return role == "p1" ? room.p1 : room.p2;
    }
    static std::string &token(Room &room, const std::string &role) {
        return role == "p1" ? room.p1_token : room.p2_token;
    }

    net::strand<net::io_context::executor_type> strand_;
    net::steady_timer cleanup_timer_;
    std::unordered_map<std::string, Room> rooms_;
    std::size_t max_rooms_;
    KeyedRateLimiter handshake_limiter_;
    std::atomic<std::size_t> connections_{0};
    std::atomic<std::size_t> room_count_{0};
};

Session::Session(
    tcp::socket socket,
    std::shared_ptr<RelayState> state,
    std::optional<net::ip::address> trusted_proxy
) : websocket_(std::move(socket)), state_(std::move(state)), wait_timer_(websocket_.get_executor()),
    trusted_proxy_(std::move(trusted_proxy)) {
    beast::error_code error;
    remote_address_ = beast::get_lowest_layer(websocket_).socket().remote_endpoint(error).address().to_string();
    if (error) {
        remote_address_ = "<unknown>";
    }
}

Session::~Session() {
    if (connection_counted_) state_->connection_closed();
}

void Session::run() {
    log_event("info", "connection_opened", {{"remote", remote_address_}});
    read_http_request();
}

void Session::read_http_request() {
    beast::get_lowest_layer(websocket_).expires_after(30s);
    http::async_read(
        beast::get_lowest_layer(websocket_), input_, request_,
        beast::bind_front_handler(&Session::on_http_request, shared_from_this())
    );
}

void Session::on_http_request(beast::error_code error, std::size_t) {
    if (error) {
        finish("http_read_error");
        return;
    }
    if (trusted_proxy_ && remote_address_ == trusted_proxy_->to_string()) {
        const auto header = request_[http::field::x_forwarded_for];
        if (!header.empty()) {
            std::string candidate(header);
            const auto comma = candidate.find(',');
            candidate = candidate.substr(0, comma);
            candidate.erase(candidate.begin(), std::find_if(candidate.begin(), candidate.end(), [](unsigned char c) {
                return !std::isspace(c);
            }));
            candidate.erase(std::find_if(candidate.rbegin(), candidate.rend(), [](unsigned char c) {
                return !std::isspace(c);
            }).base(), candidate.end());
            beast::error_code address_error;
            const auto address = net::ip::make_address(candidate, address_error);
            if (!address_error) {
                forwarded_address_ = address.to_string();
            }
        }
    }
    if (!websocket::is_upgrade(request_)) {
        if (request_.method() == http::verb::get && request_.target() == "/healthz") {
            send_http(http::status::ok, state_->health().dump());
        } else {
            send_http(http::status::not_found, json({{"status", "not_found"}}).dump());
        }
        return;
    }
    accept_websocket();
}

void Session::send_http(http::status status, std::string body) {
    auto response = std::make_shared<http::response<http::string_body>>(status, request_.version());
    response->set(http::field::server, std::string("ptcg_relay_server/") + PTCG_RELAY_VERSION);
    response->set(http::field::content_type, "application/json; charset=utf-8");
    response->keep_alive(false);
    response->body() = std::move(body);
    response->prepare_payload();
    http::async_write(
        beast::get_lowest_layer(websocket_), *response,
        [self = shared_from_this(), response](beast::error_code, std::size_t) {
            beast::error_code ignored;
            beast::get_lowest_layer(self->websocket_).socket().shutdown(tcp::socket::shutdown_both, ignored);
            self->finish("http_complete");
        }
    );
}

void Session::accept_websocket() {
    beast::get_lowest_layer(websocket_).expires_never();
    websocket_.set_option(websocket::stream_base::timeout::suggested(beast::role_type::server));
    websocket_.set_option(websocket::stream_base::decorator([](websocket::response_type &response) {
        response.set(http::field::server, std::string("ptcg_relay_server/") + PTCG_RELAY_VERSION);
    }));
    websocket_.read_message_max(kMaxMessageBytes);
    websocket_.async_accept(request_, [self = shared_from_this()](beast::error_code error) {
        if (error) {
            self->finish("websocket_accept_error");
            return;
        }
        self->websocket_open_ = true;
        self->connection_counted_ = true;
        self->state_->connection_opened();
        if (!self->state_->allow_handshake(self->source_key())) {
            self->reject("控制握手频率过高。");
            return;
        }
        self->read_message();
    });
}

std::string Session::source_key() const {
    return forwarded_address_.empty() ? remote_address_ : forwarded_address_;
}

void Session::read_message() {
    if (finished_ || !websocket_open_) {
        return;
    }
    input_.consume(input_.size());
    websocket_.async_read(input_, beast::bind_front_handler(&Session::on_message, shared_from_this()));
}

void Session::on_message(beast::error_code error, std::size_t) {
    if (error == websocket::error::closed) {
        finish("peer_closed");
        return;
    }
    if (error) {
        finish(error == websocket::error::message_too_big ? "message_too_big" : "websocket_read_error");
        return;
    }
    const bool is_text = websocket_.got_text();
    const std::string raw = beast::buffers_to_string(input_.data());
    if (!rate_limiter_.allow()) {
        forward_error("发送频率过高。");
        read_message();
        return;
    }
    if (!control_complete_) {
        handle_control(raw, is_text);
    } else {
        handle_forward(raw, is_text);
    }
}

void Session::handle_control(std::string raw, bool is_text) {
    const ControlResult parsed = parse_control_message(raw, is_text);
    if (!parsed.ok) {
        reject(parsed.error);
        return;
    }
    control_complete_ = true;
    switch (parsed.command.type) {
    case ControlType::create_room:
        state_->create(shared_from_this());
        break;
    case ControlType::join_room:
        state_->join(shared_from_this(), parsed.command.room_id);
        break;
    case ControlType::resume_room:
        state_->resume(
            shared_from_this(), parsed.command.room_id, parsed.command.role,
            parsed.command.resume_token
        );
        break;
    }
}

void Session::handle_forward(std::string raw, bool is_text) {
    if (!is_text) {
        forward_error("只接受 UTF-8 JSON 文本消息。");
        read_message();
        return;
    }
    if (raw.size() > kMaxMessageBytes) {
        forward_error("消息超过大小限制。");
        read_message();
        return;
    }
    JsonResult parsed = parse_strict_json_object(raw, "协议 v6 消息必须是对象。");
    if (!parsed.ok) {
        forward_error(parsed.error);
        read_message();
        return;
    }
    const int sender = role_ == "p1" ? 0 : 1;
    const ValidationResult valid = validate_forward_message(parsed.value, room_, sender);
    if (!valid.ok) {
        forward_error(valid.error);
        read_message();
        return;
    }
    state_->forward(shared_from_this(), std::move(raw));
    read_message();
}

void Session::assign(
    std::string room,
    std::string role,
    json response,
    std::chrono::seconds wait
) {
    net::post(websocket_.get_executor(), [self = shared_from_this(), room = std::move(room),
        role = std::move(role), response = std::move(response), wait]() mutable {
        if (self->finished_) {
            return;
        }
        self->room_ = std::move(room);
        self->role_ = std::move(role);
        self->enqueue(response.dump(), false);
        if (wait.count() > 0) {
            self->arm_wait(wait);
        }
    });
}

void Session::paired() {
    net::post(websocket_.get_executor(), [self = shared_from_this()] {
        if (self->finished_ || self->paired_) {
            return;
        }
        self->paired_ = true;
        self->wait_timer_.cancel();
        self->read_message();
    });
}

void Session::arm_wait(std::chrono::seconds duration) {
    wait_timer_.expires_after(duration);
    wait_timer_.async_wait([self = shared_from_this()](beast::error_code error) {
        if (!error && !self->paired_ && !self->finished_) {
            self->reject("等待对手超时");
        }
    });
}

void Session::send_json(json message) {
    send_text(message.dump());
}

void Session::send_text(std::string message) {
    net::post(websocket_.get_executor(), [self = shared_from_this(), message = std::move(message)]() mutable {
        self->enqueue(std::move(message), false);
    });
}

void Session::reject(std::string message) {
    net::post(websocket_.get_executor(), [self = shared_from_this(), message = std::move(message)]() mutable {
        self->enqueue(error_message(std::move(message)).dump(), true);
    });
}

void Session::forward_error(std::string message) {
    send_json(error_message(std::move(message)));
}

void Session::enqueue(std::string message, bool close_after) {
    if (finished_ || !websocket_open_) {
        return;
    }
    if (outgoing_.size() >= kMaxQueuedMessages || outgoing_bytes_ + message.size() > kMaxQueuedBytes) {
        log_event("warning", "send_queue_overflow", {{"room_id", room_}, {"role", role_}});
        beast::error_code ignored;
        beast::get_lowest_layer(websocket_).socket().cancel(ignored);
        finish("send_queue_overflow");
        return;
    }
    outgoing_bytes_ += message.size();
    outgoing_.push_back(std::move(message));
    close_after_flush_ = close_after_flush_ || close_after;
    if (!writing_) {
        write_next();
    }
}

void Session::write_next() {
    if (outgoing_.empty()) {
        writing_ = false;
        if (close_after_flush_) {
            begin_close();
        }
        return;
    }
    writing_ = true;
    websocket_.text(true);
    websocket_.async_write(
        net::buffer(outgoing_.front()),
        beast::bind_front_handler(&Session::on_write, shared_from_this())
    );
}

void Session::on_write(beast::error_code error, std::size_t) {
    if (error) {
        finish("websocket_write_error");
        return;
    }
    outgoing_bytes_ -= outgoing_.front().size();
    outgoing_.pop_front();
    write_next();
}

void Session::begin_close() {
    if (!websocket_open_ || finished_) {
        finish("closed");
        return;
    }
    websocket_.async_close(websocket::close_code::normal, [self = shared_from_this()](beast::error_code) {
        self->finish("server_closed");
    });
}

void Session::finish(std::string reason) {
    if (finished_) {
        return;
    }
    finished_ = true;
    websocket_open_ = false;
    wait_timer_.cancel();
    log_event("info", "connection_closed", {
        {"remote", source_key()}, {"room_id", room_}, {"role", role_}, {"reason", std::move(reason)},
    });
    if (!room_.empty() && !role_.empty()) {
        state_->disconnected(shared_from_this(), room_, role_);
    }
}

void RelayState::create(const std::shared_ptr<Session> &session) {
    net::post(strand_, [self = shared_from_this(), session] {
        self->cleanup();
        if (self->rooms_.size() >= self->max_rooms_) {
            session->reject("房间数量已达上限。");
            return;
        }
        try {
            const std::string code = self->generate_code();
            Room room;
            room.p1 = session;
            room.p1_token = make_resume_token();
            const std::string token = room.p1_token;
            self->rooms_.emplace(code, std::move(room));
            self->room_count_.store(self->rooms_.size(), std::memory_order_relaxed);
            session->assign(code, "p1", {
                {"type", "room_created"}, {"room_id", code}, {"resume_token", token},
            }, kRoomWaitTimeout);
            log_event("info", "room_created", {{"room_id", code}});
        } catch (const std::exception &error) {
            log_event("error", "room_create_failed", {{"message", error.what()}});
            session->reject("无法创建房间。");
        }
    });
}

void RelayState::join(const std::shared_ptr<Session> &session, std::string room_id) {
    net::post(strand_, [self = shared_from_this(), session, room_id = std::move(room_id)] {
        self->cleanup();
        auto found = self->rooms_.find(room_id);
        if (found == self->rooms_.end()) {
            session->reject("房间不存在");
            return;
        }
        Room &room = found->second;
        if (!room.p2.expired()) {
            session->reject("房间已满");
            return;
        }
        room.p2 = session;
        if (room.p2_token.empty()) {
            room.p2_token = make_resume_token();
        }
        room.last_active = clock_type::now();
        session->assign(room_id, "p2", {
            {"type", "room_joined"}, {"room_id", room_id}, {"resume_token", room.p2_token},
        }, 0s);
        auto host = room.p1.lock();
        if (host) {
            host->send_json({{"type", "opponent_joined"}});
            host->paired();
        }
        session->send_json({{"type", "opponent_joined"}});
        session->paired();
        log_event("info", "room_joined", {{"room_id", room_id}});
    });
}

void RelayState::resume(
    const std::shared_ptr<Session> &session,
    std::string room_id,
    std::string role,
    std::string supplied_token
) {
    net::post(strand_, [self = shared_from_this(), session, room_id = std::move(room_id),
        role = std::move(role), supplied_token = std::move(supplied_token)] {
        self->cleanup();
        auto found = self->rooms_.find(room_id);
        if (found == self->rooms_.end()) {
            session->reject("房间恢复期限已过");
            return;
        }
        Room &room = found->second;
        if (supplied_token != token(room, role)) {
            session->reject("恢复凭证不匹配");
            return;
        }
        if (!slot(room, role).expired()) {
            session->reject("该玩家仍在线");
            return;
        }
        slot(room, role) = session;
        room.last_active = clock_type::now();
        const std::string opponent_role = role == "p1" ? "p2" : "p1";
        auto opponent = slot(room, opponent_role).lock();
        session->assign(room_id, role, {
            {"type", "room_resumed"}, {"room_id", room_id}, {"resume_token", supplied_token},
        }, opponent ? 0s : kReconnectGrace);
        if (opponent) {
            opponent->send_json({{"type", "opponent_joined"}});
            session->send_json({{"type", "opponent_joined"}});
            opponent->paired();
            session->paired();
        }
        log_event("info", "room_resumed", {{"room_id", room_id}, {"role", role}});
    });
}

void RelayState::forward(const std::shared_ptr<Session> &session, std::string raw) {
    net::post(strand_, [self = shared_from_this(), session, raw = std::move(raw)]() mutable {
        auto found = self->rooms_.find(session->room());
        if (found == self->rooms_.end()) {
            return;
        }
        Room &room = found->second;
        auto current = slot(room, session->role()).lock();
        if (!current || current.get() != session.get()) {
            return;
        }
        const std::string opponent_role = session->role() == "p1" ? "p2" : "p1";
        auto opponent = slot(room, opponent_role).lock();
        if (!opponent) {
            session->forward_error("对手正在重连，请稍候。");
            return;
        }
        room.last_active = clock_type::now();
        opponent->send_text(std::move(raw));
    });
}

void RelayState::disconnected(
    const std::shared_ptr<Session> &session,
    std::string room_id,
    std::string role
) {
    net::post(strand_, [self = shared_from_this(), session, room_id = std::move(room_id), role = std::move(role)] {
        auto found = self->rooms_.find(room_id);
        if (found == self->rooms_.end()) {
            return;
        }
        Room &room = found->second;
        auto current = slot(room, role).lock();
        if (!current || current.get() != session.get()) {
            return;
        }
        slot(room, role).reset();
        room.last_active = clock_type::now();
        const std::string opponent_role = role == "p1" ? "p2" : "p1";
        if (auto opponent = slot(room, opponent_role).lock()) {
            opponent->send_json({{"type", "opponent_disconnected"}});
        }
        self->cleanup();
    });
}

void RelayState::schedule_cleanup() {
    cleanup_timer_.expires_after(5s);
    cleanup_timer_.async_wait([self = shared_from_this()](beast::error_code error) {
        if (!error) {
            self->cleanup();
            self->schedule_cleanup();
        }
    });
}

void RelayState::cleanup() {
    const auto now = clock_type::now();
    for (auto it = rooms_.begin(); it != rooms_.end();) {
        const Room &room = it->second;
        const bool both_disconnected = room.p1.expired() && room.p2.expired();
        const bool reconnect_expired = both_disconnected && now - room.last_active > kReconnectGrace;
        const bool never_joined_expired = room.p2_token.empty() && now - room.created > kRoomTtl;
        if (reconnect_expired || never_joined_expired) {
            log_event("info", "room_expired", {{"room_id", it->first}});
            it = rooms_.erase(it);
        } else {
            ++it;
        }
    }
    room_count_.store(rooms_.size(), std::memory_order_relaxed);
}

std::string RelayState::generate_code() {
    std::array<unsigned char, 2> random{};
    for (int attempt = 0; attempt < 100; ++attempt) {
        if (!secure_random(random.data(), random.size())) {
            throw std::runtime_error("operating-system CSPRNG failed");
        }
        const unsigned value = (static_cast<unsigned>(random[0]) << 8U) | random[1];
        const std::string code = std::to_string(1000U + value % 9000U);
        if (rooms_.count(code) == 0) {
            return code;
        }
    }
    for (int code = 1000; code <= 9999; ++code) {
        const std::string candidate = std::to_string(code);
        if (rooms_.count(candidate) == 0) {
            return candidate;
        }
    }
    throw std::runtime_error("no available room codes");
}

class Listener : public std::enable_shared_from_this<Listener> {
public:
    Listener(
        net::io_context &context,
        tcp::endpoint endpoint,
        std::shared_ptr<RelayState> state,
        std::optional<net::ip::address> trusted_proxy
    ) : context_(context), acceptor_(net::make_strand(context)), state_(std::move(state)),
        trusted_proxy_(std::move(trusted_proxy)) {
        beast::error_code error;
        acceptor_.open(endpoint.protocol(), error);
        if (error) throw beast::system_error(error);
        acceptor_.set_option(net::socket_base::reuse_address(true), error);
        if (error) throw beast::system_error(error);
        acceptor_.bind(endpoint, error);
        if (error) throw beast::system_error(error);
        acceptor_.listen(net::socket_base::max_listen_connections, error);
        if (error) throw beast::system_error(error);
    }

    void run() { accept(); }

private:
    void accept() {
        acceptor_.async_accept(net::make_strand(context_), [self = shared_from_this()](
            beast::error_code error, tcp::socket socket
        ) {
            if (!error) {
                std::make_shared<Session>(
                    std::move(socket), self->state_, self->trusted_proxy_
                )->run();
            } else if (error != net::error::operation_aborted) {
                log_event("error", "accept_failed", {{"message", error.message()}});
            }
            if (error != net::error::operation_aborted) {
                self->accept();
            }
        });
    }

    net::io_context &context_;
    tcp::acceptor acceptor_;
    std::shared_ptr<RelayState> state_;
    std::optional<net::ip::address> trusted_proxy_;
};

struct Options {
    std::string host = "127.0.0.1";
    unsigned short port = 8766;
    int threads = 2;
    std::size_t max_rooms = 100;
    std::optional<net::ip::address> trusted_proxy;
};

void print_usage() {
    std::cout << "ptcg_relay_server --host 127.0.0.1 --port 8766 --threads 2 --max-rooms 100 "
                 "[--trusted-proxy <ip>]\n";
}

Options parse_options(int argc, char **argv) {
    Options result;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            print_usage();
            std::exit(0);
        }
        if (index + 1 >= argc) {
            throw std::invalid_argument("missing value for " + argument);
        }
        const std::string value = argv[++index];
        if (argument == "--host") {
            result.host = value;
        } else if (argument == "--port") {
            const long parsed = std::stol(value);
            if (parsed < 1 || parsed > 65535) throw std::invalid_argument("invalid port");
            result.port = static_cast<unsigned short>(parsed);
        } else if (argument == "--threads") {
            result.threads = std::stoi(value);
            if (result.threads < 1 || result.threads > 256) throw std::invalid_argument("invalid thread count");
        } else if (argument == "--max-rooms") {
            const long long parsed = std::stoll(value);
            if (parsed < 1 || parsed > 9000) throw std::invalid_argument("invalid room limit");
            result.max_rooms = static_cast<std::size_t>(parsed);
        } else if (argument == "--trusted-proxy") {
            beast::error_code error;
            result.trusted_proxy = net::ip::make_address(value, error);
            if (error) throw std::invalid_argument("invalid trusted proxy address");
        } else {
            throw std::invalid_argument("unknown option: " + argument);
        }
    }
    return result;
}

} // namespace
} // namespace ptcg::relay

int main(int argc, char **argv) {
    try {
        const auto options = ptcg::relay::parse_options(argc, argv);
        beast::error_code address_error;
        const auto address = net::ip::make_address(options.host, address_error);
        if (address_error) {
            throw std::invalid_argument("invalid host address: " + options.host);
        }
        net::io_context context(options.threads);
        auto state = std::make_shared<ptcg::relay::RelayState>(context, options.max_rooms);
        state->start();
        std::make_shared<ptcg::relay::Listener>(
            context, tcp::endpoint(address, options.port), state, options.trusted_proxy
        )->run();
        net::signal_set signals(context, SIGINT, SIGTERM);
        signals.async_wait([&context](beast::error_code, int) { context.stop(); });
        ptcg::relay::log_event("info", "relay_started", {
            {"host", options.host}, {"port", options.port}, {"threads", options.threads},
            {"max_rooms", options.max_rooms},
        });
        std::vector<std::thread> workers;
        for (int index = 1; index < options.threads; ++index) {
            workers.emplace_back([&context] { context.run(); });
        }
        context.run();
        for (auto &worker : workers) {
            worker.join();
        }
        ptcg::relay::log_event("info", "relay_stopped");
        return 0;
    } catch (const std::exception &error) {
        ptcg::relay::log_event("error", "startup_failed", {{"message", error.what()}});
        ptcg::relay::print_usage();
        return 2;
    }
}

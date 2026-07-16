"""轻量级 WebSocket 中继服务器 — 宝可梦卡牌对战的云端房间中转.

玩家双方都作为 WebSocket 客户端连接到此服务器。
服务器将同一房间的两人配对后，透明转发所有游戏消息。

使用与游戏相同的 websockets.sync API，确保版本兼容。

用法:  python relay_server.py [--host 0.0.0.0] [--port 8766]
"""
import json
import logging
import random
import re
import secrets
import threading
import time
from collections import deque

import websockets.sync.server

logger = logging.getLogger("relay")

ROOM_WAIT_TIMEOUT = 120
ROOM_TTL = 60 * 60
ROOM_RECONNECT_GRACE = 120
RELAY_RECV_TIMEOUT = 30
MAX_MESSAGE_BYTES = 262_144
MAX_CONTROL_MESSAGE_BYTES = 1024
MAX_MESSAGES_PER_SECOND = 60
MAX_CONTROL_HANDSHAKES_PER_SECOND = 60
MAX_JSON_DEPTH = 32
RATE_LIMIT_WINDOW_SECONDS = 1.0
# v3 is retained as a diagnostic marker only.  New rooms are strict v4 rooms;
# accepting a v3 frame would silently drop the v4 hidden-information contract.
PROTOCOL_V3 = 3
PROTOCOL_V4 = 4
MAX_WIRE_INTEGER = 2_147_483_647
MSG_ERROR = "error"
MSG_OPPONENT_DISCONNECTED = "opponent_disconnected"
ROOM_CODE_PATTERN = re.compile(r"^[0-9]{4}$")
RESUME_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
V4_MESSAGE_TYPES = {
    "welcome",
    "deck_select",
    "lobby_update",
    "state_update",
    "action_submit",
    "choice_submit",
    "resync_request",
    "surrender",
    "ping",
    "pong",
    "error",
}

# 房间表: room_id -> {"p1": ws | None, "p2": ws | None, "created_at": float, "p2_joined": threading.Event}
rooms: dict[str, dict] = {}
rooms_lock = threading.Lock()


def _send_error(websocket, message: str):
    websocket.send(json.dumps({
        "type": MSG_ERROR,
        "message": message,
        "expected_version": PROTOCOL_V4,
    }, ensure_ascii=False))


def _reject_json_constant(value: str):
    raise ValueError(f"non-finite JSON number: {value}")


def _strict_json_object(rows: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in rows:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def _load_json_object(raw: str, *, object_error: str) -> tuple[dict | None, str]:
    """Parse strict JSON and require an object at the wire boundary."""
    try:
        message = json.loads(
            raw,
            parse_constant=_reject_json_constant,
            object_pairs_hook=_strict_json_object,
        )
    except (json.JSONDecodeError, ValueError, RecursionError):
        return None, "收到无效JSON。"
    if not isinstance(message, dict):
        return None, object_error
    if not _json_tree_depth_is_bounded(message):
        return None, "收到无效JSON。"
    return message, ""


def _json_tree_depth_is_bounded(value, max_depth: int = MAX_JSON_DEPTH) -> bool:
    """Reject adversarial nesting without relying on interpreter recursion limits."""
    stack = [(value, 0)]
    while stack:
        current, depth = stack.pop()
        if depth > max_depth:
            return False
        if isinstance(current, dict):
            stack.extend((item, depth + 1) for item in current.values())
        elif isinstance(current, (list, tuple)):
            stack.extend((item, depth + 1) for item in current)
    return True


def _valid_forward_message(message: dict, room_id: str, sender: int) -> tuple[bool, str]:
    required_fields = {
        "protocol_version", "message_type", "room_id", "sender", "sequence",
        "state_revision", "action_id", "request_id", "payload",
    }
    if not required_fields.issubset(message):
        return False, "协议 v4 消息缺少必要字段。"
    if message.get("protocol_version") != PROTOCOL_V4:
        return False, "协议版本不兼容；旧 v3 房间不能恢复，请双方更新到协议 v4。"
    if not isinstance(message.get("room_id"), str) or message.get("room_id") != room_id:
        return False, "消息房间号不匹配。"
    if not _is_wire_integer(message.get("sender")) or message.get("sender") != sender:
        return False, "消息发送方与连接身份不匹配。"
    if not isinstance(message.get("message_type"), str) or (
        message["message_type"] not in V4_MESSAGE_TYPES
    ):
        return False, "未知协议 v4 消息类型。"
    if not isinstance(message.get("payload"), dict):
        return False, "协议 v4 payload 必须是对象。"
    if (
        not _is_wire_integer(message.get("sequence"))
        or message["sequence"] <= 0
        or message["sequence"] > MAX_WIRE_INTEGER
        or not _is_wire_integer(message.get("state_revision"))
        or message["state_revision"] < -1
        or message["state_revision"] > MAX_WIRE_INTEGER
    ):
        return False, "协议 v4 序号或局面版本无效。"
    if not isinstance(message.get("action_id"), str) or not isinstance(
        message.get("request_id"), str
    ):
        return False, "协议 v4 标识符必须是字符串。"
    action_id_size = _utf8_size(message["action_id"])
    request_id_size = _utf8_size(message["request_id"])
    if (
        action_id_size < 0
        or request_id_size < 0
        or action_id_size > 128
        or request_id_size > 128
    ):
        return False, "协议 v4 标识符编码无效或过长。"
    return True, ""


def _is_wire_integer(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _utf8_size(value: str) -> int:
    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError:
        return -1


def _parse_control_message(raw) -> tuple[dict | None, str]:
    """Validate the one-shot relay handshake before touching the room table."""
    if not isinstance(raw, str):
        return None, "只接受 UTF-8 JSON 文本控制消息。"
    raw_size = _utf8_size(raw)
    if raw_size < 0:
        return None, "只接受 UTF-8 JSON 文本控制消息。"
    if raw_size > MAX_CONTROL_MESSAGE_BYTES:
        return None, "控制消息超过大小限制。"
    message, parse_error = _load_json_object(
        raw,
        object_error="控制消息必须是对象。",
    )
    if message is None:
        if parse_error == "收到无效JSON。":
            return None, "收到无效JSON控制消息。"
        return None, parse_error
    message_type = message.get("type")
    if message_type == "create_room":
        if set(message) != {"type"}:
            return None, "创建房间控制消息包含未知字段。"
        return message, ""
    if message_type == "join_room":
        room_id = message.get("room_id")
        if set(message) != {"type", "room_id"} or not isinstance(room_id, str):
            return None, "加入房间控制消息字段无效。"
        if not ROOM_CODE_PATTERN.fullmatch(room_id):
            return None, "房间号格式无效。"
        return message, ""
    if message_type == "resume_room":
        room_id = message.get("room_id")
        role = message.get("role")
        token = message.get("resume_token")
        if set(message) != {"type", "room_id", "role", "resume_token"}:
            return None, "恢复房间控制消息字段无效。"
        if not isinstance(room_id, str) or not ROOM_CODE_PATTERN.fullmatch(room_id):
            return None, "房间号格式无效。"
        if role not in ("p1", "p2"):
            return None, "恢复房间角色无效。"
        if not isinstance(token, str) or not RESUME_TOKEN_PATTERN.fullmatch(token):
            return None, "恢复凭证无效。"
        return message, ""
    return None, f"未知命令: {message_type}"


class _RateLimiter:
    def __init__(self, limit: int = MAX_MESSAGES_PER_SECOND):
        self.limit = limit
        self.window_started = time.monotonic()
        self.count = 0

    def allow(self) -> bool:
        now = time.monotonic()
        if now - self.window_started >= 1.0:
            self.window_started = now
            self.count = 0
        self.count += 1
        return self.count <= self.limit


class _KeyedRateLimiter:
    """Thread-safe rolling-window limiter shared by connections from one source."""

    def __init__(
        self,
        limit: int = MAX_CONTROL_HANDSHAKES_PER_SECOND,
        window_seconds: float = RATE_LIMIT_WINDOW_SECONDS,
        clock=time.monotonic,
    ):
        if limit <= 0:
            raise ValueError("rate limit must be positive")
        if window_seconds <= 0:
            raise ValueError("rate limit window must be positive")
        self.limit = limit
        self.window_seconds = window_seconds
        self._clock = clock
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()
        self._last_cleanup = self._clock()

    @staticmethod
    def _discard_expired(events: deque[float], cutoff: float) -> None:
        while events and events[0] <= cutoff:
            events.popleft()

    def allow(self, key: str) -> bool:
        now = self._clock()
        cutoff = now - self.window_seconds
        with self._lock:
            if now - self._last_cleanup >= self.window_seconds:
                for existing_key, existing_events in tuple(self._events.items()):
                    self._discard_expired(existing_events, cutoff)
                    if not existing_events:
                        del self._events[existing_key]
                self._last_cleanup = now

            events = self._events.setdefault(key, deque())
            self._discard_expired(events, cutoff)
            if len(events) >= self.limit:
                return False
            events.append(now)
            return True


def _remote_rate_key(remote) -> str:
    """Group reconnects by host while keeping malformed addresses isolated."""
    if isinstance(remote, (tuple, list)) and remote:
        return str(remote[0])
    return str(remote) if remote is not None else "<unknown>"


_control_handshake_limiter = _KeyedRateLimiter()


def cleanup_expired_rooms():
    """Remove rooms that have waited too long without a completed match."""
    with rooms_lock:
        expired = _cleanup_expired_rooms_locked(time.time())
    for code in expired:
        logger.info("房间 %s 已过期并清理", code)


def _cleanup_expired_rooms_locked(now: float) -> list[str]:
    expired = [
        code
        for code, room in rooms.items()
        if (
            room.get("p1") is None
            and room.get("p2") is None
            and now - room.get("last_active", room.get("created_at", now))
            > ROOM_RECONNECT_GRACE
        )
        or (
            room.get("p2_token") is None
            and now - room.get("created_at", now) > ROOM_TTL
        )
    ]
    for code in expired:
        room = rooms.pop(code, None)
        if room:
            room["p1_joined"].set()
            room["p2_joined"].set()
    return expired


def _generate_room_code_locked() -> str:
    for _ in range(100):
        code = str(random.randint(1000, 9999))
        if code not in rooms:
            return code
    for code in [str(i).zfill(4) for i in range(1000, 10000)]:
        if code not in rooms:
            return code
    raise RuntimeError("No available room codes")


def generate_room_code() -> str:
    """Generate an available code. Room creation itself uses `_create_room`."""
    with rooms_lock:
        _cleanup_expired_rooms_locked(time.time())
        return _generate_room_code_locked()


def _create_room(websocket) -> str:
    """Allocate and publish a room in one critical section."""
    with rooms_lock:
        _cleanup_expired_rooms_locked(time.time())
        code = _generate_room_code_locked()
        rooms[code] = {
            "p1": websocket,
            "p2": None,
            "created_at": time.time(),
            "last_active": time.time(),
            "p1_token": secrets.token_urlsafe(32),
            "p2_token": None,
            "p1_joined": threading.Event(),
            "p2_joined": threading.Event(),
        }
        rooms[code]["p1_joined"].set()
        return code


def _join_room(websocket, code: str) -> tuple[dict | None, str]:
    """Claim the guest slot atomically and return a stable room reference."""
    with rooms_lock:
        _cleanup_expired_rooms_locked(time.time())
        room = rooms.get(code)
        if room is None:
            return None, "房间不存在"
        if room["p2"] is not None:
            return None, "房间已满"
        room["p2"] = websocket
        if room.get("p2_token") is None:
            room["p2_token"] = secrets.token_urlsafe(32)
        room["p2_joined"].set()
        room["last_active"] = time.time()
        return room, ""


def _resume_room(websocket, code: str, role: str, token: str) -> tuple[dict | None, str]:
    """Reclaim one disconnected room slot using its unguessable credential."""
    with rooms_lock:
        _cleanup_expired_rooms_locked(time.time())
        room = rooms.get(code)
        if room is None:
            return None, "房间恢复期限已过"
        if token != room.get(f"{role}_token"):
            return None, "恢复凭证不匹配"
        if room.get(role) is not None:
            return None, "该玩家仍在线"
        room[role] = websocket
        room[f"{role}_joined"].set()
        room["last_active"] = time.time()
        return room, ""


def handle_client(websocket):
    """处理单个 WebSocket 连接（在独立线程中运行）."""
    remote = websocket.remote_address
    # ``remote_address`` is a 2-tuple for IPv4, commonly a 4-tuple for IPv6,
    # and may be ``None`` for test/custom transports.  Treat it as an opaque
    # value so logging itself can never abort the connection handler.
    remote_label = str(remote)
    logger.info("新连接: %s", remote_label)

    my_room: str | None = None
    my_role: str | None = None
    paired: bool = False
    rate_limiter = _RateLimiter()

    try:
        # 阶段1: 等待控制命令
        if not _control_handshake_limiter.allow(_remote_rate_key(remote)):
            _send_error(websocket, "控制握手频率过高。")
            return
        raw = websocket.recv(timeout=RELAY_RECV_TIMEOUT)
        if not rate_limiter.allow():
            _send_error(websocket, "发送频率过高。")
            return
        msg, control_error = _parse_control_message(raw)
        if msg is None:
            _send_error(websocket, control_error)
            return
        msg_type = msg.get("type", "")

        if msg_type == "create_room":
            code = _create_room(websocket)
            my_room = code
            my_role = "p1"
            websocket.send(json.dumps({
                "type": "room_created", "room_id": code,
                "resume_token": rooms[code]["p1_token"],
            }, ensure_ascii=False))
            logger.info("房间 %s 已创建 (房主: %s)", code, remote_label)

        elif msg_type == "join_room":
            code = msg["room_id"]
            room, join_error = _join_room(websocket, code)
            if room is None:
                _send_error(websocket, join_error)
                logger.warning("%s 加入房间 %s 失败: %s", remote_label, code, join_error)
                return
            my_room = code
            my_role = "p2"
            websocket.send(json.dumps({
                "type": "room_joined", "room_id": code,
                "resume_token": room["p2_token"],
            }, ensure_ascii=False))
            logger.info("%s 加入了房间 %s", remote_label, code)

            # 通知双方对手已加入
            p1 = room["p1"]
            if p1:
                p1.send(json.dumps({"type": "opponent_joined"}, ensure_ascii=False))
            websocket.send(json.dumps({"type": "opponent_joined"}, ensure_ascii=False))
            paired = True

        elif msg_type == "resume_room":
            code = msg["room_id"]
            my_role = msg["role"]
            room, resume_error = _resume_room(
                websocket, code, my_role, msg["resume_token"]
            )
            if room is None:
                _send_error(websocket, resume_error)
                return
            my_room = code
            websocket.send(json.dumps({
                "type": "room_resumed",
                "room_id": code,
                "resume_token": msg["resume_token"],
            }, ensure_ascii=False))
            opponent_role = "p2" if my_role == "p1" else "p1"
            opponent = room.get(opponent_role)
            if opponent:
                opponent.send(json.dumps({"type": "opponent_joined"}, ensure_ascii=False))
                websocket.send(json.dumps({"type": "opponent_joined"}, ensure_ascii=False))
                paired = True
            logger.info("%s 已恢复房间 %s 的 %s", remote_label, code, my_role)

        else:
            _send_error(websocket, f"未知命令: {msg_type}")
            return

        # 阶段2: 首次房主或恢复中的任一方等待对手回到房间。
        if not paired:
            with rooms_lock:
                room = rooms.get(my_room)
            if room:
                opponent_role = "p2" if my_role == "p1" else "p1"
                wait_event = room[f"{opponent_role}_joined"]
                wait_timeout = (
                    ROOM_WAIT_TIMEOUT
                    if msg_type == "create_room"
                    else ROOM_RECONNECT_GRACE
                )
                if not wait_event.wait(timeout=wait_timeout):
                    _send_error(websocket, "等待对手超时")
                    logger.info("房间 %s 等待对手超时", my_room)
                    return
                with rooms_lock:
                    current_room = rooms.get(my_room)
                    paired = current_room is room and room.get(opponent_role) is not None
                if not paired:
                    return

        # 阶段3: 转发 — 双向透明转发游戏消息
        opponent_role = "p2" if my_role == "p1" else "p1"
        expected_sender = 0 if my_role == "p1" else 1
        while True:
            try:
                raw = websocket.recv(timeout=RELAY_RECV_TIMEOUT)
            except TimeoutError:
                continue

            if not rate_limiter.allow():
                _send_error(websocket, "发送频率过高。")
                continue
            if not isinstance(raw, str):
                _send_error(websocket, "只接受 UTF-8 JSON 文本消息。")
                continue
            raw_size = _utf8_size(raw)
            if raw_size < 0:
                _send_error(websocket, "只接受 UTF-8 JSON 文本消息。")
                continue
            if raw_size > MAX_MESSAGE_BYTES:
                _send_error(websocket, "消息超过大小限制。")
                continue

            forwarded, parse_error = _load_json_object(
                raw,
                object_error="协议 v4 消息必须是对象。",
            )
            if forwarded is None:
                _send_error(websocket, parse_error)
                continue

            valid, validation_error = _valid_forward_message(
                forwarded, my_room, expected_sender
            )
            if not valid:
                _send_error(websocket, validation_error)
                continue

            with rooms_lock:
                room = rooms.get(my_room)

            if not room:
                break

            opponent = room.get(opponent_role)
            if opponent:
                try:
                    opponent.send(raw)
                except Exception:
                    # The opponent's handler will release its slot.  Keep this
                    # side alive so the room can be resumed within the grace.
                    continue
            else:
                _send_error(websocket, "对手正在重连，请稍候。")
                continue

    except websockets.exceptions.ConnectionClosed:
        pass
    except json.JSONDecodeError:
        logger.warning("%s 收到无效JSON", remote_label)
    except Exception:
        logger.exception("%s 未预期的错误", remote_label)
    finally:
        logger.info("断开连接: %s (房间: %s)", remote_label, my_room or "N/A")
        opponent = None
        with rooms_lock:
            room = rooms.get(my_room) if my_room else None
            if room is not None and room.get(my_role) is websocket:
                opponent = room.get("p2" if my_role == "p1" else "p1")
                room[my_role] = None
                room[f"{my_role}_joined"].clear()
                room["last_active"] = time.time()
        if opponent:
            try:
                opponent.send(json.dumps({
                    "type": MSG_OPPONENT_DISCONNECTED,
                }, ensure_ascii=False))
            except Exception:
                pass
        cleanup_expired_rooms()


def main(host: str, port: int):
    """启动中继服务器."""
    logger.info("中继服务器启动中: %s:%s", host, port)
    with websockets.sync.server.serve(
        handle_client,
        host,
        port,
        max_size=MAX_MESSAGE_BYTES,
        max_queue=16,
    ) as server:
        logger.info("中继服务器已启动: %s:%s (等待客户端连接...)", host, port)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            logger.info("收到中断信号，正在关闭...")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="宝可梦卡牌中继服务器")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址 (默认 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8766, help="监听端口 (默认 8766)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    main(args.host, args.port)

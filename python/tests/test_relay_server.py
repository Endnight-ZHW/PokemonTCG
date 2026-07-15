"""Directed concurrency and control-handshake tests for the v3 Relay server."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest import mock

PYTHON_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_ROOT))

import relay_server as relay


class _FakeWebSocket:
    def __init__(
        self,
        raw: str = "",
        *,
        host: str = "127.0.0.1",
        port: int = 0,
        remote_address=None,
    ):
        self.raw = raw
        self.remote_address = (
            (host, port) if remote_address is None else remote_address
        )
        self.sent: list[str] = []
        self.recv_count = 0

    def recv(self, *, timeout: float):
        del timeout
        self.recv_count += 1
        if self.recv_count > 1:
            raise AssertionError("test connection unexpectedly requested another frame")
        return self.raw

    def send(self, raw: str) -> None:
        self.sent.append(raw)


class RelayServerTests(unittest.TestCase):
    def setUp(self):
        with relay.rooms_lock:
            relay.rooms.clear()
        self._original_control_limiter = relay._control_handshake_limiter
        relay._control_handshake_limiter = relay._KeyedRateLimiter(limit=1000)

    def tearDown(self):
        relay._control_handshake_limiter = self._original_control_limiter
        with relay.rooms_lock:
            relay.rooms.clear()

    def test_concurrent_room_creation_reserves_unique_codes_atomically(self):
        clients = [_FakeWebSocket(port=index) for index in range(8)]
        barrier = threading.Barrier(len(clients))

        def create(client: _FakeWebSocket) -> str:
            barrier.wait()
            return relay._create_room(client)

        # Force every creator to collide on its random candidate. The locked
        # fallback allocation must still publish every room under a unique key.
        with mock.patch.object(relay.random, "randint", return_value=1234):
            with ThreadPoolExecutor(max_workers=len(clients)) as executor:
                codes = list(executor.map(create, clients))

        self.assertEqual(len(set(codes)), len(clients))
        with relay.rooms_lock:
            self.assertEqual(set(relay.rooms), set(codes))
            self.assertEqual(
                {id(room["p1"]) for room in relay.rooms.values()},
                {id(client) for client in clients},
            )

    def test_concurrent_join_claims_guest_slot_exactly_once(self):
        host = _FakeWebSocket(port=1)
        code = relay._create_room(host)
        guests = [_FakeWebSocket(port=100 + index) for index in range(12)]
        barrier = threading.Barrier(len(guests))

        def join(guest: _FakeWebSocket):
            barrier.wait()
            room, error = relay._join_room(guest, code)
            return guest, room, error

        with ThreadPoolExecutor(max_workers=len(guests)) as executor:
            results = list(executor.map(join, guests))

        winners = [result for result in results if result[1] is not None]
        losers = [result for result in results if result[1] is None]
        self.assertEqual(len(winners), 1)
        self.assertEqual(len(losers), len(guests) - 1)
        self.assertTrue(all(error == "房间已满" for _, _, error in losers))
        with relay.rooms_lock:
            self.assertIs(relay.rooms[code]["p2"], winners[0][0])

    def test_room_cleanup_never_expires_an_active_pair(self):
        host = _FakeWebSocket(port=1)
        guest = _FakeWebSocket(port=2)
        code = relay._create_room(host)
        room, error = relay._join_room(guest, code)
        self.assertIsNotNone(room)
        self.assertEqual(error, "")
        with relay.rooms_lock:
            relay.rooms[code]["created_at"] = 0.0
            expired = relay._cleanup_expired_rooms_locked(relay.ROOM_TTL + 1.0)

        self.assertEqual(expired, [])
        with relay.rooms_lock:
            self.assertIn(code, relay.rooms)

    def test_disconnected_room_slot_can_resume_with_credential(self):
        host = _FakeWebSocket(port=1)
        guest = _FakeWebSocket(port=2)
        code = relay._create_room(host)
        room, error = relay._join_room(guest, code)
        self.assertEqual(error, "")
        token = room["p2_token"]
        with relay.rooms_lock:
            room["p2"] = None
            room["p2_joined"].clear()

        replacement = _FakeWebSocket(port=3)
        resumed, resume_error = relay._resume_room(
            replacement, code, "p2", token
        )

        self.assertEqual(resume_error, "")
        self.assertIs(resumed["p2"], replacement)
        self.assertTrue(resumed["p2_joined"].is_set())
        rejected, rejected_error = relay._resume_room(
            _FakeWebSocket(port=4), code, "p1", "x" * 32
        )
        self.assertIsNone(rejected)
        self.assertIn("凭证", rejected_error)

    def test_resume_control_message_is_strictly_validated(self):
        room = relay._create_room(_FakeWebSocket(port=1))
        token = relay.rooms[room]["p1_token"]
        payload = {
            "type": "resume_room",
            "room_id": room,
            "role": "p1",
            "resume_token": token,
        }
        parsed, error = relay._parse_control_message(json.dumps(payload))
        self.assertEqual(error, "")
        self.assertEqual(parsed, payload)

        malformed = dict(payload, role="owner")
        parsed, error = relay._parse_control_message(json.dumps(malformed))
        self.assertIsNone(parsed)
        self.assertIn("角色", error)

    def test_oversized_control_handshake_is_rejected_before_room_creation(self):
        raw = json.dumps(
            {"type": "create_room", "padding": "界" * relay.MAX_CONTROL_MESSAGE_BYTES},
            ensure_ascii=False,
        )
        self.assertGreater(len(raw.encode("utf-8")), relay.MAX_CONTROL_MESSAGE_BYTES)
        websocket = _FakeWebSocket(raw, port=10)

        relay.handle_client(websocket)

        self.assertEqual(websocket.recv_count, 1)
        self.assertEqual(len(websocket.sent), 1)
        response = json.loads(websocket.sent[0])
        self.assertEqual(response["type"], relay.MSG_ERROR)
        self.assertIn("大小限制", response["message"])
        with relay.rooms_lock:
            self.assertEqual(relay.rooms, {})

    def test_control_handshake_limit_is_shared_across_same_source_connections(self):
        relay._control_handshake_limiter = relay._KeyedRateLimiter(limit=2)
        raw = json.dumps({"type": "join_room", "room_id": "9999"})
        clients = [
            _FakeWebSocket(raw, host="203.0.113.7", port=200 + index)
            for index in range(3)
        ]

        for client in clients:
            relay.handle_client(client)

        messages = [json.loads(client.sent[0])["message"] for client in clients]
        self.assertEqual(messages[:2], ["房间不存在", "房间不存在"])
        self.assertEqual(messages[2], "控制握手频率过高。")
        self.assertEqual(clients[2].recv_count, 0)

        other_source = _FakeWebSocket(raw, host="203.0.113.8", port=300)
        relay.handle_client(other_source)
        self.assertEqual(json.loads(other_source.sent[0])["message"], "房间不存在")

    def test_control_handshake_limiter_is_atomic_under_concurrency(self):
        limiter = relay._KeyedRateLimiter(limit=7, clock=lambda: 10.0)
        barrier = threading.Barrier(32)

        def attempt(_index: int) -> bool:
            barrier.wait()
            return limiter.allow("198.51.100.4")

        with ThreadPoolExecutor(max_workers=32) as executor:
            allowed = list(executor.map(attempt, range(32)))

        self.assertEqual(sum(allowed), 7)

    def test_ipv6_remote_address_does_not_break_connection_logging(self):
        websocket = _FakeWebSocket(
            json.dumps({"type": "join_room", "room_id": "9999"}),
            remote_address=("2001:db8::1", 443, 0, 2),
        )

        relay.handle_client(websocket)

        self.assertEqual(websocket.recv_count, 1)
        self.assertEqual(json.loads(websocket.sent[0])["message"], "房间不存在")

    def test_forward_validation_rejects_bool_sender_and_out_of_range_numbers(self):
        frame = {
            "protocol_version": relay.PROTOCOL_V3,
            "message_type": "ping",
            "room_id": "1234",
            "sender": 1,
            "sequence": 1,
            "state_revision": 0,
            "action_id": "",
            "request_id": "",
            "payload": {},
        }
        self.assertEqual(relay._valid_forward_message(frame, "1234", 1), (True, ""))

        for field, value in (
            ("sender", True),
            ("sequence", relay.MAX_WIRE_INTEGER + 1),
            ("state_revision", relay.MAX_WIRE_INTEGER + 1),
        ):
            malformed = dict(frame)
            malformed[field] = value
            with self.subTest(field=field):
                self.assertFalse(
                    relay._valid_forward_message(malformed, "1234", 1)[0]
                )

    def test_forward_validation_rejects_non_utf8_identifier_without_raising(self):
        frame = {
            "protocol_version": relay.PROTOCOL_V3,
            "message_type": "ping",
            "room_id": "1234",
            "sender": 0,
            "sequence": 1,
            "state_revision": 0,
            "action_id": "\ud800",
            "request_id": "",
            "payload": {},
        }

        valid, error = relay._valid_forward_message(frame, "1234", 0)

        self.assertFalse(valid)
        self.assertIn("标识符", error)

    def test_json_loader_rejects_non_standard_non_finite_numbers(self):
        parsed, error = relay._load_json_object(
            '{"payload":{"value":NaN}}',
            object_error="must be object",
        )

        self.assertIsNone(parsed)
        self.assertEqual(error, "收到无效JSON。")

    def test_json_loader_rejects_duplicate_fields(self):
        parsed, error = relay._load_json_object(
            '{"sender":0,"sender":1}',
            object_error="must be object",
        )

        self.assertIsNone(parsed)
        self.assertEqual(error, "收到无效JSON。")

    def test_json_loader_rejects_excessive_nesting_without_raising(self):
        raw = '{"payload":' + "[" * 2000 + "0" + "]" * 2000 + "}"

        parsed, error = relay._load_json_object(
            raw,
            object_error="must be object",
        )

        self.assertIsNone(parsed)
        self.assertEqual(error, "收到无效JSON。")

    def test_control_parser_rejects_unencodable_text_without_raising(self):
        parsed, error = relay._parse_control_message("\ud800")

        self.assertIsNone(parsed)
        self.assertIn("UTF-8", error)


if __name__ == "__main__":
    unittest.main()

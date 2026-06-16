"""Protocol v2 and multiplayer transport tests."""
import os
import socket
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import websockets.sync.server

from config import NETWORK_TIMEOUT
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.game_state import ActionRequest
from engine.enums import PlayerAction, TurnPhase
from engine.player_state import PokemonInPlay
from engine.turn_manager import TurnManager
from network.message_protocol import (
    MSG_STATE_UPDATE,
    PROTOCOL_VERSION,
    envelope_message,
)
from network.network_manager import NetworkManager
from network.state_serializer import (
    deserialize_game_state,
    deserialize_action_request,
    serialize_game_state,
    serialize_action_request,
)


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _wait_for(predicate, timeout=5.0, interval=0.02):
    start = time.time()
    while time.time() - start < timeout:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise TimeoutError("condition timed out")


def _drain_until(nm: NetworkManager, msg_type: str, timeout=5.0):
    def poll():
        for msg in nm.poll():
            if msg.get("type") == msg_type:
                return msg
        return None
    return _wait_for(poll, timeout=timeout)


class ProtocolV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def test_action_request_roundtrip_keeps_all_network_fields(self):
        card = CardRegistry.get("sv2-delib")
        req = ActionRequest(
            request_type="distribute_energy",
            player=1,
            prompt="分配能量",
            min_select=0,
            max_select=2,
            from_zone="discard",
            card_list=[card],
            target_player="opponent",
            bench_indices=[0, 2],
            allow_duplicates=True,
            flip_count=3,
            until_tails=True,
            pending_card=card,
            distribute_mode="paired",
            target_info=[{"slot": "bench_0", "name": "测试", "bench_idx": 0}],
            max_per_target=2,
            source_name="测试来源",
            request_id="req-7",
        )

        restored = deserialize_action_request(serialize_action_request(req))

        self.assertEqual(restored.request_type, "distribute_energy")
        self.assertEqual(restored.player, 1)
        self.assertEqual(restored.target_player, "opponent")
        self.assertEqual(restored.bench_indices, [0, 2])
        self.assertTrue(restored.allow_duplicates)
        self.assertEqual(restored.flip_count, 3)
        self.assertTrue(restored.until_tails)
        self.assertEqual(restored.distribute_mode, "paired")
        self.assertEqual(restored.target_info[0]["slot"], "bench_0")
        self.assertEqual(restored.max_per_target, 2)
        self.assertEqual(restored.source_name, "测试来源")
        self.assertEqual(restored.request_id, "req-7")
        self.assertEqual(restored.pending_card.api_id, card.api_id)

    def test_envelope_message_adds_v2_metadata(self):
        msg = envelope_message({"type": "action", "action": "END_TURN"}, 12)
        self.assertEqual(msg["version"], PROTOCOL_VERSION)
        self.assertEqual(msg["seq"], 12)
        self.assertIn("sent_at", msg)
        self.assertEqual(msg["action_id"], "act-12")

    def test_stale_uses_receive_time_not_send_time(self):
        nm = NetworkManager()
        nm._connected.set()
        nm._last_recv_time = time.time() - NETWORK_TIMEOUT - 1
        nm._last_send_time = time.time()
        self.assertTrue(nm.is_stale)
        nm._connected.clear()

    def test_incoming_state_updates_are_coalesced(self):
        nm = NetworkManager()
        nm._put_incoming({"type": MSG_STATE_UPDATE, "state": {"turn": 1}})
        nm._put_incoming({"type": MSG_STATE_UPDATE, "state": {"turn": 2}})
        self.assertEqual(nm.poll(), [{"type": MSG_STATE_UPDATE, "state": {"turn": 2}}])

    def test_deserialized_client_state_is_view_only(self):
        from engine.game_state import GameState

        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.active_player_idx = 0
        card = CardRegistry.get("sv2-delib")
        state.p1.active = PokemonInPlay(card)
        state.p2.active = PokemonInPlay(card)
        state.p1.prizes = [card] * 6
        state.p2.prizes = [card] * 6

        restored = deserialize_game_state(
            serialize_game_state(state, for_player_idx=1),
            for_player_idx=1,
        )

        self.assertTrue(restored.is_network_view)
        result = TurnManager(restored).perform_action(
            PlayerAction.END_TURN,
            player_idx=restored.active_player_idx,
        )
        self.assertFalse(result.success)

    def test_lan_transport_wraps_messages_in_protocol_v2(self):
        port = _free_port()
        host = NetworkManager()
        client = NetworkManager()
        try:
            host.start_host(port)
            time.sleep(0.1)
            client.connect_to_host("127.0.0.1", port)
            _wait_for(lambda: host.is_connected and client.is_connected)

            client.send({"type": "probe", "payload": 1})
            received = _drain_until(host, "probe")
            self.assertEqual(received["version"], PROTOCOL_VERSION)
            self.assertEqual(received["payload"], 1)
        finally:
            client.stop()
            host.stop()

    def test_relay_transport_forwards_v2_messages(self):
        from relay_server import handle_client, rooms, rooms_lock

        port = _free_port()
        with rooms_lock:
            rooms.clear()
        server = websockets.sync.server.serve(handle_client, "127.0.0.1", port)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        host = NetworkManager()
        client = NetworkManager()
        try:
            host.connect_to_relay("127.0.0.1", port, is_host=True)
            room_msg = _drain_until(host, "room_created")
            client.connect_to_relay(
                "127.0.0.1", port, is_host=False, room_code=room_msg["room_id"]
            )
            _wait_for(lambda: host.is_connected and client.is_connected)

            client.send({"type": "relay_probe", "payload": 2})
            received = _drain_until(host, "relay_probe")
            self.assertEqual(received["version"], PROTOCOL_VERSION)
            self.assertEqual(received["payload"], 2)
        finally:
            client.stop()
            host.stop()
            server.shutdown()
            thread.join(timeout=2.0)
            with rooms_lock:
                rooms.clear()


if __name__ == "__main__":
    unittest.main()

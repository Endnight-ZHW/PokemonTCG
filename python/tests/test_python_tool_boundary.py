"""Black-box contracts for Python authoring and Relay boundaries."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

PYTHON_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_ROOT))

from engine.action_codec import (
    deserialize_choice_view,
    deserialize_choice_response,
    serialize_choice_view,
    serialize_choice_response,
)
from engine.actions import ChoiceOption, ChoiceView, ChoiceResponse, PokemonRef
from engine.game_state import GameState
from engine.snapshot import snapshot_state, snapshot_to_dict
from relay_server import (
    PROTOCOL_V5,
    PROTOCOL_V6,
    _parse_control_message,
    _valid_forward_message,
)


class PythonToolBoundaryTests(unittest.TestCase):
    def test_pygame_client_is_physically_absent(self):
        self.assertEqual(list((PYTHON_ROOT / "ui").rglob("*.py")), [])
        self.assertFalse((PYTHON_ROOT / "main.py").exists())

    def test_python_rule_executors_are_physically_absent(self):
        retired = (
            "action_availability.py",
            "action_resolver.py",
            "choice_manager.py",
            "damage_calculator.py",
            "effect_runner.py",
            "pending_continuation.py",
            "rules_validator.py",
            "settlement.py",
            "transaction_manager.py",
            "turn_manager.py",
        )
        for name in retired:
            with self.subTest(name=name):
                self.assertFalse((PYTHON_ROOT / "engine" / name).exists())
        command_files = {
            path.name
            for path in (PYTHON_ROOT / "engine" / "commands").glob("*.py")
        }
        self.assertEqual(command_files, {
            "__init__.py",
            "descriptors.py",
            "formula_ast.py",
            "ir.py",
            "vm_contract.py",
        })

    def test_engine_snapshot_has_no_client_view_compatibility_fields(self):
        forbidden_fields = {"is_network_view", "_hand_hidden", "_hand_count"}
        state = GameState()
        payload = snapshot_to_dict(snapshot_state(state))

        def walk_keys(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    yield str(key)
                    yield from walk_keys(child)
            elif isinstance(value, (list, tuple)):
                for child in value:
                    yield from walk_keys(child)

        self.assertTrue(forbidden_fields.isdisjoint(set(walk_keys(payload))))
        for owner in (state, state.p1, state.p2):
            for field in forbidden_fields:
                with self.subTest(owner=type(owner).__name__, field=field):
                    self.assertFalse(hasattr(owner, field))

    def test_choice_codec_round_trip_is_transport_independent(self):
        request = ChoiceView(
            request_id="choice-7",
            base_revision=4,
            request_type="select_bench",
            player=1,
            prompt="choose",
            options=(
                ChoiceOption(
                    "bench:2",
                    "Bench 2",
                    PokemonRef(1, "bench_2", "sv2-delib"),
                ),
            ),
            min_select=1,
            max_select=1,
            presentation={"purpose": "switch"},
        )
        response = ChoiceResponse("choice-7", ("bench:2",))

        self.assertEqual(
            deserialize_choice_view(serialize_choice_view(request)),
            request,
        )
        self.assertEqual(
            deserialize_choice_response(serialize_choice_response(response)),
            response,
        )

    def test_relay_accepts_only_protocol_v6_frames(self):
        frame = {
            "protocol_version": PROTOCOL_V6,
            "message_type": "ping",
            "room_id": "1234",
            "sender": 0,
            "sequence": 1,
            "state_revision": 0,
            "action_id": "",
            "request_id": "",
            "payload": {},
        }
        self.assertEqual(_valid_forward_message(frame, "1234", 0), (True, ""))
        frame["protocol_version"] = PROTOCOL_V5
        valid, error = _valid_forward_message(frame, "1234", 0)
        self.assertFalse(valid)
        self.assertIn("旧 v5 房间不能恢复", error)

        parsed, error = _parse_control_message(json.dumps({"type": "create_room"}))
        self.assertEqual(parsed, {"type": "create_room"})
        self.assertEqual(error, "")


if __name__ == "__main__":
    unittest.main()

"""Contracts for the local-only Python debugging and training toolchain."""
from __future__ import annotations

import inspect
import json
from pathlib import Path
import sys
import unittest

PYTHON_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_ROOT))

from engine.action_codec import (
    deserialize_choice_request,
    deserialize_choice_response,
    serialize_choice_request,
    serialize_choice_response,
)
from engine.actions import ChoiceOption, ChoiceRequest, ChoiceResponse, PokemonRef
from relay_server import (
    PROTOCOL_V3,
    PROTOCOL_V4,
    _parse_control_message,
    _valid_forward_message,
)
from ui.screens.deck_select import DECK_OPTIONS_BY_KEY, DeckSelectScreen
from ui.screens.game_screen import GameScreen
from ui.screens.title_screen import TitleScreen


class PythonToolBoundaryTests(unittest.TestCase):
    def test_legacy_client_modules_are_physically_absent(self):
        forbidden_files = (
            PYTHON_ROOT / "ui" / "screens" / "lobby_screen.py",
            PYTHON_ROOT / "ui" / "screens" / "game_screen_network.py",
            PYTHON_ROOT / "tests" / "test_network_v2.py",
            PYTHON_ROOT / "tests" / "test_multiplayer.py",
        )
        network_sources = list((PYTHON_ROOT / "network").glob("*.py"))
        remaining = network_sources + [path for path in forbidden_files if path.exists()]
        self.assertEqual([str(path) for path in remaining], [])

    def test_pygame_screens_have_no_client_network_parameters(self):
        for screen_type in (DeckSelectScreen, GameScreen):
            parameters = inspect.signature(screen_type.__init__).parameters
            with self.subTest(screen=screen_type.__name__):
                self.assertNotIn("network_manager", parameters)
                self.assertNotIn("is_remote", parameters)
                self.assertNotIn("my_player_idx", parameters)
                self.assertNotIn("initial_state", parameters)

    def test_local_debug_menu_exposes_all_release_decks(self):
        decks = TitleScreen.__new__(TitleScreen)._load_available_decks()
        manifest = json.loads(
            (PYTHON_ROOT.parent / "release_manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            tuple(decks),
            tuple(manifest["release_decks"]),
        )
        self.assertEqual(set(DECK_OPTIONS_BY_KEY), set(manifest["release_decks"]))

    def test_deck_ui_metadata_follows_available_deck_order(self):
        screen = DeckSelectScreen.__new__(DeckSelectScreen)
        available = {"water": [], "fire": []}
        # Exercise the same key-based mapping used by __init__ without
        # coupling this boundary test to an initialized Pygame display.
        screen.deck_keys = list(available)
        screen.deck_options = [DECK_OPTIONS_BY_KEY[key] for key in screen.deck_keys]

        self.assertIn("甲贺忍蛙", screen.deck_options[0]["name"])
        self.assertIn("烈焰猴", screen.deck_options[1]["name"])

    def test_ui_sources_do_not_import_legacy_client_networking(self):
        forbidden_tokens = (
            "from network", "import network", "network_manager", "_is_remote",
        )
        violations = []
        for path in (PYTHON_ROOT / "ui").rglob("*.py"):
            source = path.read_text(encoding="utf-8")
            for token in forbidden_tokens:
                if token in source:
                    violations.append(f"{path.relative_to(PYTHON_ROOT)}: {token}")
        self.assertEqual(violations, [])

    def test_config_has_no_legacy_client_network_endpoints(self):
        source = (PYTHON_ROOT / "config.py").read_text(encoding="utf-8")
        for token in (
            "NETWORK_PORT",
            "NETWORK_TIMEOUT",
            "RELAY_SERVER_HOST",
            "RELAY_SERVER_PORT",
        ):
            with self.subTest(token=token):
                self.assertNotIn(token, source)

    def test_python_gate_resolves_relative_interpreter_before_chdir(self):
        source = (PYTHON_ROOT.parent / "tools" / "test_python.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Resolve-Path -LiteralPath $Python", source)
        self.assertLess(
            source.index("Resolve-Path -LiteralPath $Python"),
            source.index("\nPush-Location"),
        )

    def test_engine_snapshot_has_no_client_view_compatibility_fields(self):
        forbidden_tokens = ("is_network_view", "_hand_hidden", "_hand_count")
        engine_files = (
            PYTHON_ROOT / "engine" / "game_state.py",
            PYTHON_ROOT / "engine" / "player_state.py",
            PYTHON_ROOT / "engine" / "snapshot.py",
            PYTHON_ROOT / "engine" / "turn_manager.py",
        )
        violations = [
            f"{path.name}: {token}"
            for path in engine_files
            for token in forbidden_tokens
            if token in path.read_text(encoding="utf-8")
        ]
        self.assertEqual(violations, [])

    def test_choice_codec_round_trip_is_transport_independent(self):
        request = ChoiceRequest(
            request_id="choice-7",
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
            metadata={"revision": 4},
        )
        response = ChoiceResponse("choice-7", ("bench:2",))

        self.assertEqual(
            deserialize_choice_request(serialize_choice_request(request)),
            request,
        )
        self.assertEqual(
            deserialize_choice_response(serialize_choice_response(response)),
            response,
        )

    def test_relay_accepts_only_protocol_v4_frames(self):
        frame = {
            "protocol_version": PROTOCOL_V4,
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
        frame["protocol_version"] = PROTOCOL_V3
        valid, error = _valid_forward_message(frame, "1234", 0)
        self.assertFalse(valid)
        self.assertIn("旧 v3 房间不能恢复", error)

        parsed, error = _parse_control_message(json.dumps({"type": "create_room"}))
        self.assertEqual(parsed, {"type": "create_room"})
        self.assertEqual(error, "")


if __name__ == "__main__":
    unittest.main()

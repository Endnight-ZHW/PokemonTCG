"""Tests for the local multiplayer launcher helpers."""
import os
import sys
import unittest
from contextlib import redirect_stderr
from io import StringIO

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.launch_multiplayer import build_commands, parse_args


class LaunchMultiplayerTests(unittest.TestCase):
    def test_client_port_defaults_to_host_port(self):
        args = parse_args(["--host-port", "19001"])
        client_port = args.client_port or args.host_port
        self.assertEqual(args.host_port, 19001)
        self.assertEqual(client_port, 19001)

    def test_build_commands_uses_requested_ports(self):
        host_cmd, client_cmd = build_commands(
            "python", "main.py", 19001, "127.0.0.1", 19002
        )
        self.assertEqual(host_cmd, ["python", "main.py", "--host", "19001"])
        self.assertEqual(
            client_cmd,
            ["python", "main.py", "--client", "127.0.0.1", "19002"],
        )

    def test_invalid_port_is_rejected(self):
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit):
                parse_args(["--host-port", "70000"])


if __name__ == "__main__":
    unittest.main()

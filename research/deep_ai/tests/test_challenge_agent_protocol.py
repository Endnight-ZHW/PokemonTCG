from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from deep_ai.challenge_arena import canonical_hash, load_product_payloads
from deep_ai.challenge_arena_build import load_and_verify_agent, sha256_file


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = "ptcg.challenge_agent.ipc/1"


def _latest_agent_manifest() -> Path | None:
    values = list((RESEARCH_ROOT / "build" / "arena-agents" / "challenge_next").glob(
        "*/agent.build.json"
    ))
    return max(values, key=lambda path: path.stat().st_mtime) if values else None


class ChallengeAgentProtocolTests(unittest.TestCase):
    @unittest.skipUnless(_latest_agent_manifest() is not None, "Arena Agent is not built")
    def test_handshake_contract_errors_and_shutdown(self) -> None:
        manifest = load_and_verify_agent(_latest_agent_manifest())
        catalog, decks, _ = load_product_payloads()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (("catalog", catalog), ("decks", decks)):
                (root / f"{name}.json").write_text(
                    json.dumps(value, ensure_ascii=False), encoding="utf-8"
                )
            config = {
                "catalog_path": str(root / "catalog.json"),
                "decks_path": str(root / "decks.json"),
                "strategies_path": str(manifest["strategies_path"]),
                "strategies_hash": canonical_hash(json.loads(
                    Path(manifest["strategies_path"]).read_text(encoding="utf-8")
                )),
                "catalog_file_sha256": sha256_file(root / "catalog.json"),
                "decks_file_sha256": sha256_file(root / "decks.json"),
                "strategies_file_sha256": sha256_file(
                    Path(manifest["strategies_path"])
                ),
            }
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            with subprocess.Popen(
                [manifest["executable_path"], "--config", str(config_path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            ) as process:
                assert process.stdin is not None
                assert process.stdout is not None
                ready = json.loads(process.stdout.readline())
                self.assertEqual(ready["protocol"], PROTOCOL)
                self.assertTrue(ready["success"])
                self.assertEqual(
                    ready["implementation_hash"], manifest["implementation_hash"]
                )
                process.stdin.write("not-json\n")
                process.stdin.flush()
                malformed = json.loads(process.stdout.readline())
                self.assertFalse(malformed["success"])
                request = {
                    "protocol": PROTOCOL,
                    "id": 7,
                    "op": "contract",
                }
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                contract = json.loads(process.stdout.readline())
                self.assertTrue(contract["success"])
                self.assertTrue(contract["contract"]["callback_free"])
                reset = {
                    "protocol": PROTOCOL,
                    "id": 8,
                    "op": "reset",
                    "match_id": "protocol-test",
                }
                process.stdin.write(json.dumps(reset) + "\n")
                process.stdin.flush()
                self.assertTrue(json.loads(process.stdout.readline())["success"])
                cancel = {
                    "protocol": PROTOCOL,
                    "id": 9,
                    "op": "cancel",
                    "generation": 41,
                }
                process.stdin.write(json.dumps(cancel) + "\n")
                process.stdin.flush()
                self.assertTrue(json.loads(process.stdout.readline())["success"])
                shutdown = {"protocol": PROTOCOL, "id": 10, "op": "shutdown"}
                process.stdin.write(json.dumps(shutdown) + "\n")
                process.stdin.flush()
                self.assertTrue(json.loads(process.stdout.readline())["success"])
                self.assertEqual(process.wait(timeout=10), 0)


if __name__ == "__main__":
    unittest.main()

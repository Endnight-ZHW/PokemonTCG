from __future__ import annotations

import http.client
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from engine.ai.dl.run_store import (
    TrainingEventWriter,
    atomic_write_json,
    create_run_layout,
    read_json,
)
from scripts.ai_training_dashboard import DashboardServer, DashboardState


class DashboardAPITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.runs_root = Path(self.temporary.name)
        self.run_dir = create_run_layout(
            self.runs_root,
            "api-run",
            run_payload={
                "preset": "smoke",
                "status": "completed",
                "pid": 0,
            },
        )
        writer = TrainingEventWriter(self.run_dir, "api-run")
        writer.emit(stage="teacher", completed=1, total=2)
        writer.emit(stage="teacher", completed=2, total=2)
        self.state = DashboardState(Path.cwd(), self.runs_root)
        self.server = DashboardServer(("127.0.0.1", 0), self.state)
        self.thread = threading.Thread(
            target=self.server.serve_forever, daemon=True
        )
        self.thread.start()
        self.host, self.port = self.server.server_address
        self.base = f"http://{self.host}:{self.port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.temporary.cleanup()

    def _json(self, path: str) -> dict:
        with urllib.request.urlopen(self.base + path, timeout=3) as response:
            return json.loads(response.read().decode("utf-8"))

    def test_versioned_queries_and_csrf_protection(self):
        session = self._json("/api/v1/session")
        self.assertEqual(session["api_version"], 1)
        self.assertEqual(session["heartbeat_seconds"], 2.0)
        self.assertTrue(session["csrf_token"])
        runs = self._json("/api/v1/runs")["runs"]
        self.assertEqual([row["run_id"] for row in runs], ["api-run"])
        run = self._json("/api/v1/runs/api-run")
        self.assertEqual(run["status"], "completed")

        request = urllib.request.Request(
            self.base + "/api/v1/runs",
            data=b'{"preset":"smoke"}',
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=3)
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()

    def test_dashboard_root_accepts_run_query_and_disables_caching(self):
        with urllib.request.urlopen(
            self.base + "/?run=api-run", timeout=3
        ) as response:
            body = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertIn("自主学习训练台", body)

    def test_sse_last_event_id_reconnects_without_duplicate(self):
        connection = http.client.HTTPConnection(
            self.host, self.port, timeout=3
        )
        connection.request(
            "GET",
            "/api/v1/runs/api-run/events",
            headers={"Last-Event-ID": "1"},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        lines: list[str] = []
        while len(lines) < 8:
            line = response.fp.readline().decode("utf-8").rstrip()
            lines.append(line)
            if line.startswith("data: ") and '"seq": 2' in line:
                break
        response.close()
        connection.close()
        wire = "\n".join(lines)
        self.assertIn("id: 2", wire)
        self.assertIn('"seq": 2', wire)
        self.assertNotIn('"seq": 1', wire)

    def test_encoded_traversal_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(
                self.base + "/api/v1/runs/%2e%2e", timeout=3
            )
        self.assertEqual(caught.exception.code, 400)
        caught.exception.close()


class DashboardReconcileTests(unittest.TestCase):
    def test_v3_pause_resume_and_cancel_publish_cooperative_requests(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run_dir = create_run_layout(
                root,
                "control-run",
                run_payload={
                    "preset": "pilot",
                    "trainer": "infoset_alphazero_v3",
                    "run_format": 3,
                    "status": "running",
                    "pid": os.getpid(),
                },
            )
            state = DashboardState(Path.cwd(), root)
            paused = state.pause("control-run")
            self.assertEqual(paused["status"], "pausing")
            self.assertTrue((run_dir / "pause.request").is_file())

            resumed = state.resume("control-run")
            self.assertEqual(resumed["status"], "running")
            self.assertFalse((run_dir / "pause.request").exists())

            cancelled = state.cancel("control-run")
            self.assertEqual(cancelled["status"], "cancelling")
            self.assertTrue((run_dir / "cancel.request").is_file())

    def test_dead_process_becomes_recoverable_and_active_run_is_exclusive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            dead = create_run_layout(
                root,
                "dead-run",
                run_payload={
                    "preset": "smoke",
                    "status": "running",
                    "pid": 2_147_483_646,
                },
            )
            state = DashboardState(Path.cwd(), root)
            self.assertEqual(
                read_json(dead / "run.json")["status"], "recoverable"
            )

            create_run_layout(
                root,
                "active-run",
                run_payload={
                    "preset": "smoke",
                    "status": "running",
                    "pid": os.getpid(),
                },
            )
            self.assertEqual(state.active_run()["run_id"], "active-run")
            with self.assertRaisesRegex(
                RuntimeError, "another_training_is_active"
            ):
                state.create_run({"preset": "smoke", "deck": "fire"})


if __name__ == "__main__":
    unittest.main()

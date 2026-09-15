from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from deep_ai.evaluation_protocol import GameEvidence
from deep_ai.evaluation_store import EvaluationRunStore
from tests.test_evaluation import protocol, result


class EvaluationStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.protocol = protocol(decks=("fire",))
        self.task = self.protocol.tasks("ac", 0)[0]
        self.row = GameEvidence.from_result(self.protocol, self.task, result(self.task)).row

    def open(self):
        return EvaluationRunStore(self.root, self.protocol)

    def test_directory_lock_is_exclusive(self):
        with self.open():
            with self.assertRaisesRegex(RuntimeError, "output_locked"):
                self.open()
        with self.open():
            pass

    def test_duplicate_and_unknown_task_do_not_write_shards(self):
        with self.open() as store:
            with self.assertRaisesRegex(RuntimeError, "duplicate_task_id"):
                store.append([self.row, self.row])
            with self.assertRaisesRegex(RuntimeError, "unknown_task_id"):
                store.append([{**self.row, "task_id": "unknown"}])
            self.assertFalse(store.games)
            self.assertFalse(list((self.root / "shards").glob("*.jsonl")))

    def test_compact_index_and_elapsed_survive_resume(self):
        with self.open() as store:
            store.append([self.row])
            store.add_elapsed_seconds(1.25)
        with self.open() as store:
            self.assertEqual(store.games, [self.row])
            self.assertEqual(store.elapsed_seconds, 1.25)
        state = json.loads((self.root / "arena-run-state.json").read_text())
        self.assertEqual(state["schema"], "ptcg.ai_evaluation.run_state/1")
        self.assertEqual(state["completed_count"], 1)
        self.assertEqual(state["task_count"], 4)
        self.assertNotIn("task_ids", state)
        self.assertNotIn("completed_task_ids", state)

    def test_pending_attempt_sequence_and_completion(self):
        first = {**self.row, "attempt_number": 1}
        second = {**self.row, "attempt_number": 2}
        with self.open() as store:
            with self.assertRaisesRegex(RuntimeError, "primary_attempt_missing"):
                store.append_attempts([second])
            store.append_attempts([first])
            with self.assertRaisesRegex(RuntimeError, "attempt_duplicate"):
                store.append_attempts([first])
            with self.assertRaisesRegex(RuntimeError, "pending_retries"):
                store.mark_complete("pass")
        with self.open() as store:
            self.assertEqual(store.pending_retry_task_ids, {self.task.task_id})
            store.append_attempts([second])
            store.append([self.row])
            self.assertFalse(store.pending_retry_task_ids)

    def test_corrupt_attempt_shard_is_rejected(self):
        with self.open() as store:
            store.append_attempts([{**self.row, "attempt_number": 1}])
        shard = next((self.root / "attempts").glob("*.jsonl"))
        shard.write_text("corrupt\n")
        with self.assertRaisesRegex(RuntimeError, "sha256_mismatch"):
            self.open()

    def test_rehashed_shard_cannot_hide_a_tampered_attempt(self):
        with self.open() as store:
            store.append_attempts([{**self.row, "attempt_number": 1}])
        shard = next((self.root / "attempts").glob("*.jsonl"))
        attempt = json.loads(shard.read_text())
        attempt["error"] = "tampered"
        data = (json.dumps(attempt) + "\n").encode()
        shard.write_bytes(data)
        path = self.root / "arena-run-state.json"
        state = json.loads(path.read_text())
        state["attempt_shards"][0]["sha256"] = hashlib.sha256(data).hexdigest()
        path.write_text(json.dumps(state))
        with self.assertRaisesRegex(RuntimeError, "attempt_hash_mismatch"):
            self.open()


if __name__ == "__main__":
    unittest.main()

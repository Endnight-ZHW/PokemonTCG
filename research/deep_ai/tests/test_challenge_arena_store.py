from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from deep_ai.challenge_arena_store import ChallengeArenaRunStore
from deep_ai.challenge_arena_retry import TimeoutRetryJournal, attempt_row


class ChallengeArenaStoreTests(unittest.TestCase):
    def test_resume_skips_completed_tasks_and_preserves_shards(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a", "b")
            ) as store:
                store.append(({"task_id": "a", "value": 1},))
                store.add_elapsed_seconds(1.25)
                self.assertEqual(store.completed_task_ids, {"a"})
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a", "b")
            ) as resumed:
                self.assertEqual(resumed.completed_task_ids, {"a"})
                self.assertEqual(resumed.elapsed_seconds, 1.25)
                resumed.append(({"task_id": "b", "value": 2},))
                resumed.mark_complete("pass")
            state = json.loads((root / "arena-run-state.json").read_text(
                encoding="utf-8"
            ))
            self.assertEqual(state["status"], "complete")
            self.assertEqual(len(state["shards"]), 2)

    def test_fingerprint_mismatch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="first", task_ids=("a",)
            ):
                pass
            with self.assertRaisesRegex(RuntimeError, "fingerprint_mismatch"):
                ChallengeArenaRunStore(
                    root, fingerprint="second", task_ids=("a",)
                )

    def test_v1_state_requires_a_new_output_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "arena-run-state.json").write_text(json.dumps({
                "schema": "ptcg.challenge_arena.run_state/1",
                "fingerprint": "fingerprint",
                "task_ids": ["a"],
            }), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "new_output_directory"):
                ChallengeArenaRunStore(
                    root, fingerprint="fingerprint", task_ids=("a",)
                )

    def test_output_directory_lock_is_exclusive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ):
                with self.assertRaisesRegex(RuntimeError, "output_locked"):
                    ChallengeArenaRunStore(
                        root, fingerprint="fingerprint", task_ids=("a",)
                    )

    def test_corrupt_shard_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as store:
                store.append(({"task_id": "a"},))
            shard = next((root / "shards").glob("*.jsonl"))
            shard.write_text("corrupt\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "sha256_mismatch"):
                ChallengeArenaRunStore(
                    root, fingerprint="fingerprint", task_ids=("a",)
                )

    def test_duplicate_task_in_one_shard_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with ChallengeArenaRunStore(
                Path(directory), fingerprint="fingerprint", task_ids=("a",)
            ) as store:
                with self.assertRaisesRegex(RuntimeError, "duplicate_task_id"):
                    store.append(({"task_id": "a"}, {"task_id": "a"}))

    def test_pending_retry_survives_resume_until_final_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as store:
                store.append_attempts(({
                    "task_id": "a",
                    "attempt_number": 1,
                    "failure_kind": "decision_timeout",
                },))
                self.assertEqual(store.pending_retry_task_ids, {"a"})
                with self.assertRaisesRegex(RuntimeError, "pending_retries"):
                    store.mark_complete("pass")
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as resumed:
                self.assertEqual(resumed.pending_retry_task_ids, {"a"})
                self.assertEqual(len(resumed.attempts), 1)
                resumed.append_attempts(({
                    "task_id": "a",
                    "attempt_number": 2,
                    "success": True,
                },))
                resumed.append(({"task_id": "a", "success": True},))
                self.assertFalse(resumed.pending_retry_task_ids)
                resumed.mark_complete("pass")

    def test_corrupt_attempt_shard_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as store:
                store.append_attempts(({
                    "task_id": "a", "attempt_number": 1
                },))
            shard = next((root / "attempts").glob("*.jsonl"))
            shard.write_text("corrupt\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "sha256_mismatch"):
                ChallengeArenaRunStore(
                    root, fingerprint="fingerprint", task_ids=("a",)
                )

    def test_attempt_sequence_and_hash_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as store:
                with self.assertRaisesRegex(RuntimeError, "primary_attempt_missing"):
                    store.append_attempts(({
                        "task_id": "a", "attempt_number": 2
                    },))
                store.append_attempts(({
                    "task_id": "a", "attempt_number": 1
                },))
                with self.assertRaisesRegex(RuntimeError, "attempt_duplicate"):
                    store.append_attempts(({
                        "task_id": "a", "attempt_number": 1
                    },))
            shard = next((root / "attempts").glob("*.jsonl"))
            attempt = json.loads(shard.read_text(encoding="utf-8"))
            attempt["error"] = "tampered"
            payload = (json.dumps(attempt, sort_keys=True) + "\n").encode("utf-8")
            shard.write_bytes(payload)
            state_path = root / "arena-run-state.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["attempt_shards"][0]["sha256"] = hashlib.sha256(
                payload
            ).hexdigest()
            state_path.write_text(json.dumps(state), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "attempt_hash_mismatch"):
                ChallengeArenaRunStore(
                    root, fingerprint="fingerprint", task_ids=("a",)
                )

    def test_recorded_successful_retry_is_finalized_after_resume(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            primary = {
                "task_id": "a",
                "failure_kind": "decision_timeout",
                "error": "external_agent_timeout",
            }
            retry = {
                "task_id": "a",
                "success": True,
                "terminal": True,
                "strength_eligible": True,
                "candidate_score_x2": 2,
            }
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as store:
                store.append_attempts((attempt_row(primary, 1),))
                store.append_attempts((attempt_row(retry, 2),))
            with ChallengeArenaRunStore(
                root, fingerprint="fingerprint", task_ids=("a",)
            ) as resumed:
                journal = TimeoutRetryJournal(resumed, {"a": object()})
                journal.finalize_recorded_retries()
                self.assertFalse(resumed.pending_retry_task_ids)
                self.assertEqual(resumed.completed_task_ids, {"a"})
                self.assertTrue(resumed.games[0]["recovered_timeout"])


if __name__ == "__main__":
    unittest.main()

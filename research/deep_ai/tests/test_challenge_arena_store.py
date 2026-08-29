from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from deep_ai.challenge_arena_store import ChallengeArenaRunStore


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


if __name__ == "__main__":
    unittest.main()

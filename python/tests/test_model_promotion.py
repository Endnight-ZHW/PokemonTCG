from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import promote_ai_models


DECK_KEYS = ("fire", "water")
REPO_ROOT = Path(__file__).resolve().parents[2]


class ModelPromotionTransactionTests(unittest.TestCase):
    def _write_staging(self, root: Path) -> tuple[Path, Path, Path]:
        checkpoints = root / "staging" / "checkpoints"
        runtime = root / "staging" / "runtime" / "ai_models"
        manifest_path = runtime.parent / promote_ai_models.RUNTIME_MANIFEST_NAME
        checkpoints.mkdir(parents=True)
        runtime.mkdir(parents=True)
        models = {}
        for deck_key in DECK_KEYS:
            checkpoint = checkpoints / f"{deck_key}.pt"
            sidecar = checkpoints / f"{deck_key}.json"
            onnx = runtime / f"{deck_key}.onnx"
            checkpoint.write_bytes(f"new-checkpoint-{deck_key}".encode())
            sidecar.write_text(
                json.dumps({
                    "model_path": str(checkpoint),
                    "metadata": {
                        "deck": deck_key,
                        "accepted": True,
                        "verified": True,
                    },
                }),
                encoding="utf-8",
            )
            onnx.write_bytes(f"new-onnx-{deck_key}".encode())
            models[deck_key] = {
                "deck_key": deck_key,
                "checkpoint_sha256": promote_ai_models._sha256(checkpoint),
                "onnx_path": f"res://data/ai_models/{deck_key}.onnx",
                "onnx_size": onnx.stat().st_size,
                "onnx_sha256": promote_ai_models._sha256(onnx),
            }
        manifest_path.write_text(
            json.dumps({
                "format_version": 2,
                "opset": int(
                    promote_ai_models.RELEASE_MANIFEST["onnx"]["opset"]
                ),
                "onnx_runtime_version": str(
                    promote_ai_models.RELEASE_MANIFEST["onnx"]["runtime_version"]
                ),
                "models": models,
            }),
            encoding="utf-8",
        )
        return checkpoints, runtime, manifest_path

    def _write_live(self, root: Path) -> tuple[Path, Path, Path]:
        checkpoints = root / "live" / "python" / "ai_models"
        runtime = root / "live" / "godot" / "ai_models"
        manifest_path = runtime.parent / promote_ai_models.RUNTIME_MANIFEST_NAME
        checkpoints.mkdir(parents=True)
        runtime.mkdir(parents=True)
        for deck_key in DECK_KEYS:
            (checkpoints / f"{deck_key}.pt").write_bytes(
                f"old-checkpoint-{deck_key}".encode()
            )
            (checkpoints / f"{deck_key}.json").write_text(
                json.dumps({"release": "old", "deck": deck_key}),
                encoding="utf-8",
            )
            (runtime / f"{deck_key}.onnx").write_bytes(
                f"old-onnx-{deck_key}".encode()
            )
        manifest_path.write_text('{"release":"old"}\n', encoding="utf-8")
        return checkpoints, runtime, manifest_path

    def _snapshot(
        self,
        checkpoints: Path,
        runtime: Path,
        manifest: Path,
    ) -> dict[str, bytes]:
        paths = [manifest]
        for deck_key in DECK_KEYS:
            paths.extend((
                checkpoints / f"{deck_key}.pt",
                checkpoints / f"{deck_key}.json",
                runtime / f"{deck_key}.onnx",
            ))
        return {str(path): path.read_bytes() for path in paths}

    def _promote(
        self,
        staged_checkpoints: Path,
        staged_runtime: Path,
        live_checkpoints: Path,
        live_runtime: Path,
        transaction_root: Path,
        *,
        defer_commit: bool = False,
    ) -> dict[str, str]:
        return promote_ai_models.promote(
            staged_checkpoints,
            live_checkpoints,
            runtime_source=staged_runtime,
            runtime_destination=live_runtime,
            transaction_root=transaction_root,
            defer_commit=defer_commit,
        )

    def test_combined_bundle_stays_recoverable_until_commit(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, live_manifest = self._write_live(root)
            transaction_root = root / "transaction"

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
            ):
                checksums = self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                    defer_commit=True,
                )

            self.assertEqual(set(checksums), set(DECK_KEYS))
            self.assertTrue((transaction_root / "active" / "journal.json").is_file())
            for deck_key in DECK_KEYS:
                self.assertEqual(
                    (live_checkpoints / f"{deck_key}.pt").read_bytes(),
                    f"new-checkpoint-{deck_key}".encode(),
                )
                self.assertEqual(
                    (live_runtime / f"{deck_key}.onnx").read_bytes(),
                    f"new-onnx-{deck_key}".encode(),
                )
            self.assertEqual(
                set(json.loads(live_manifest.read_text(encoding="utf-8"))["models"]),
                set(DECK_KEYS),
            )
            self.assertTrue(promote_ai_models.commit_promotion(transaction_root))
            self.assertFalse((transaction_root / "active").exists())

    def test_cross_artifact_hash_mismatch_is_rejected_before_live_writes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, staged_manifest = self._write_staging(root)
            live_checkpoints, live_runtime, live_manifest = self._write_live(root)
            old_snapshot = self._snapshot(
                live_checkpoints, live_runtime, live_manifest
            )
            payload = json.loads(staged_manifest.read_text(encoding="utf-8"))
            payload["models"]["water"]["checkpoint_sha256"] = "0" * 64
            staged_manifest.write_text(json.dumps(payload), encoding="utf-8")
            transaction_root = root / "transaction"

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
                self.assertRaisesRegex(ValueError, "water:checkpoint_sha256"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                )

            self.assertEqual(
                self._snapshot(live_checkpoints, live_runtime, live_manifest),
                old_snapshot,
            )
            self.assertFalse((transaction_root / "active").exists())

    def test_promotion_rejects_overlapping_staging_and_live_paths(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            checkpoints, runtime, _manifest = self._write_staging(root)

            with self.assertRaisesRegex(ValueError, "paths must be disjoint"):
                promote_ai_models.promote(
                    checkpoints,
                    checkpoints,
                    runtime_source=runtime,
                    runtime_destination=runtime,
                    transaction_root=root / "transaction",
                )

    def test_commit_rechecks_pending_artifact_hashes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, live_manifest = self._write_live(root)
            old_snapshot = self._snapshot(
                live_checkpoints, live_runtime, live_manifest
            )
            transaction_root = root / "transaction"

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                    defer_commit=True,
                )
            (live_runtime / "water.onnx").write_bytes(b"tampered")

            with self.assertRaisesRegex(OSError, "changed before commit"):
                promote_ai_models.commit_promotion(transaction_root)
            self.assertTrue(promote_ai_models.rollback_promotion(transaction_root))
            self.assertEqual(
                self._snapshot(live_checkpoints, live_runtime, live_manifest),
                old_snapshot,
            )

    def test_interrupted_committed_cleanup_never_restores_partial_backup(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, live_manifest = self._write_live(root)
            transaction_root = root / "transaction"

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                    defer_commit=True,
                )
            committed_snapshot = self._snapshot(
                live_checkpoints, live_runtime, live_manifest
            )
            active_root = transaction_root / "active"

            def interrupted_cleanup(path: Path) -> None:
                self.assertEqual(Path(path).resolve(), active_root.resolve())
                backups = [
                    candidate
                    for candidate in (active_root / "backup").rglob("*")
                    if candidate.is_file()
                ]
                self.assertGreater(len(backups), 1)
                backups[0].unlink()
                raise KeyboardInterrupt("simulated committed cleanup interruption")

            with (
                mock.patch.object(
                    promote_ai_models.shutil,
                    "rmtree",
                    side_effect=interrupted_cleanup,
                ),
                self.assertRaisesRegex(KeyboardInterrupt, "cleanup interruption"),
            ):
                promote_ai_models.commit_promotion(transaction_root)

            journal = json.loads(
                (active_root / "journal.json").read_text(encoding="utf-8")
            )
            self.assertEqual(journal["phase"], "committed")
            self.assertTrue(promote_ai_models.rollback_promotion(transaction_root))
            self.assertEqual(
                self._snapshot(live_checkpoints, live_runtime, live_manifest),
                committed_snapshot,
            )
            self.assertFalse(active_root.exists())

    def test_install_failure_rolls_back_every_artifact_family(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, live_manifest = self._write_live(root)
            old_snapshot = self._snapshot(
                live_checkpoints, live_runtime, live_manifest
            )
            transaction_root = root / "transaction"
            real_move = promote_ai_models._move

            def failing_move(source: Path, target: Path) -> None:
                if source.name == "water.onnx" and "prepared" in source.parts:
                    raise OSError("simulated ONNX install failure")
                real_move(source, target)

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
                mock.patch.object(promote_ai_models, "_move", side_effect=failing_move),
                self.assertRaisesRegex(OSError, "simulated ONNX install failure"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                )

            self.assertEqual(
                self._snapshot(live_checkpoints, live_runtime, live_manifest),
                old_snapshot,
            )
            self.assertFalse((transaction_root / "active").exists())

    def test_interrupted_install_is_recovered_from_persistent_journal(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, live_manifest = self._write_live(root)
            old_snapshot = self._snapshot(
                live_checkpoints, live_runtime, live_manifest
            )
            transaction_root = root / "transaction"
            real_move = promote_ai_models._move

            def interrupted_move(source: Path, target: Path) -> None:
                if source.name == "water.onnx" and "prepared" in source.parts:
                    raise KeyboardInterrupt("simulated process interruption")
                real_move(source, target)

            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
                mock.patch.object(promote_ai_models, "_move", side_effect=interrupted_move),
                self.assertRaisesRegex(KeyboardInterrupt, "process interruption"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                )

            self.assertTrue((transaction_root / "active" / "journal.json").is_file())
            self.assertTrue(promote_ai_models.rollback_promotion(transaction_root))
            self.assertEqual(
                self._snapshot(live_checkpoints, live_runtime, live_manifest),
                old_snapshot,
            )
            self.assertFalse((transaction_root / "active").exists())

    def test_rollback_refuses_unmarked_transaction_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            transaction_root = Path(temp_dir) / "untrusted"
            active_root = transaction_root / "active"
            active_root.mkdir(parents=True)
            sentinel = active_root / "must-not-delete.txt"
            sentinel.write_text("keep", encoding="utf-8")

            with self.assertRaisesRegex(OSError, "unmarked"):
                promote_ai_models.rollback_promotion(transaction_root)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_rollback_refuses_journal_paths_outside_transaction(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, _live_manifest = self._write_live(root)
            transaction_root = root / "transaction"
            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                    defer_commit=True,
                )

            outside = root / "outside" / "fire.pt"
            outside.parent.mkdir()
            outside.write_bytes(b"must-not-use")
            journal_path = transaction_root / "active" / "journal.json"
            journal = json.loads(journal_path.read_text(encoding="utf-8"))
            journal["entries"][0]["backup"] = str(outside)
            journal_path.write_text(json.dumps(journal), encoding="utf-8")

            with self.assertRaisesRegex(OSError, "Unsafe promotion journal backup"):
                promote_ai_models.rollback_promotion(transaction_root)
            self.assertEqual(outside.read_bytes(), b"must-not-use")

    def test_rollback_refuses_target_outside_recorded_destination_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            staged_checkpoints, staged_runtime, _manifest = self._write_staging(root)
            live_checkpoints, live_runtime, _live_manifest = self._write_live(root)
            transaction_root = root / "transaction"
            with (
                mock.patch.object(promote_ai_models, "DECK_KEYS", DECK_KEYS),
                mock.patch.object(promote_ai_models, "_validate_staged"),
            ):
                self._promote(
                    staged_checkpoints,
                    staged_runtime,
                    live_checkpoints,
                    live_runtime,
                    transaction_root,
                    defer_commit=True,
                )

            outside = root / "outside" / "fire.pt"
            outside.parent.mkdir()
            outside.write_bytes(b"must-not-overwrite")
            journal_path = transaction_root / "active" / "journal.json"
            journal = json.loads(journal_path.read_text(encoding="utf-8"))
            checkpoint_entry = next(
                row
                for row in journal["entries"]
                if row["kind"] == "checkpoint" and Path(row["target"]).name == "fire.pt"
            )
            checkpoint_entry["target"] = str(outside)
            journal_path.write_text(json.dumps(journal), encoding="utf-8")

            with self.assertRaisesRegex(
                OSError,
                "checkpoint target outside destination root",
            ):
                promote_ai_models.rollback_promotion(transaction_root)
            self.assertEqual(outside.read_bytes(), b"must-not-overwrite")

    def test_pipeline_stages_onnx_and_commits_only_after_runtime_tests(self):
        source = (REPO_ROOT / "tools" / "train_deep_ai_v10.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("'--output-root', $runtimeStageRoot", source)
        self.assertIn(
            "Assert-PathUnderRoot -Root $buildRoot -Path $outputRootPath",
            source,
        )
        self.assertIn("'--runtime-source', $runtimeStageRoot", source)
        self.assertIn("'--defer-commit'", source)
        self.assertIn("'--commit', '--transaction-root'", source)
        self.assertIn("build_godot.ps1", source)
        self.assertIn("-Target all -Configuration debug", source)
        self.assertIn("smoke_godot_build.ps1", source)
        self.assertIn("-RequireAndroidDevice:$Promote", source)
        self.assertIn(
            "& (Join-Path $PSScriptRoot 'smoke_godot_build.ps1')",
            source,
        )
        self.assertGreaterEqual(
            source.count("'--rollback', '--transaction-root'"),
            2,
        )
        self.assertLess(
            source.index("'--defer-commit'"),
            source.index("'--commit', '--transaction-root'"),
        )
        self.assertLess(
            source.index("test_godot_ai.ps1"),
            source.index("'--commit', '--transaction-root'"),
        )
        self.assertLess(
            source.index("build_godot.ps1"),
            source.index("'--commit', '--transaction-root'"),
        )
        self.assertLess(
            source.index("smoke_godot_build.ps1"),
            source.index("'--commit', '--transaction-root'"),
        )


if __name__ == "__main__":
    unittest.main()

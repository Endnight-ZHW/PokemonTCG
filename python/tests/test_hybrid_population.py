from __future__ import annotations

import json
import random
import tempfile
import unittest
from pathlib import Path

from engine.ai.dl.hybrid_population import (
    HybridPopulationTrainer,
    mix_action_training_rows,
)
from engine.ai.dl.population_rollout import PopulationGameResult
from engine.ai.dl.production_contract import (
    RELEASE_DECKS,
    PopulationTask,
    build_population_schedule,
    derive_deep_decision_seed,
    validate_schedule_closure,
)
from engine.ai.dl.run_store import (
    CheckpointStore,
    ReplayShardStore,
    TrainingEventWriter,
    atomic_write_json,
    capture_rng_state,
    create_run_layout,
    read_events,
    resolve_within,
    restore_rng_state,
)
from scripts.promote_hybrid_candidate import (
    _recover_incomplete_transactions,
)

try:
    import torch
except Exception:
    torch = None


class PopulationScheduleTests(unittest.TestCase):
    def test_deep_seed_derivation_matches_godot_golden(self):
        self.assertEqual(
            derive_deep_decision_seed(17, 42, 1, 7),
            1_639_819_819,
        )

    def test_release_schedule_is_closed_and_complete(self):
        tasks = build_population_schedule(generation=3)
        summary = validate_schedule_closure(
            tasks, expected_decks=RELEASE_DECKS
        )
        self.assertEqual(
            summary,
            {
                "tasks": 1100,
                "matchups": 55,
                "mirrors": 10,
                "cross_deck": 45,
            },
        )
        self.assertEqual(len({task.task_id for task in tasks}), 1100)
        self.assertEqual(
            sum(task.opponent_kind == "history" for task in tasks),
            220,
        )

    def test_history_block_trains_both_current_decks_with_closed_roles(self):
        tasks = [
            task
            for task in build_population_schedule(
                generation=3, decks=("fire", "water")
            )
            if task.deck_a == "fire"
            and task.deck_b == "water"
            and task.opponent_kind == "history"
        ]
        self.assertEqual(len(tasks), 4)
        self.assertEqual(
            [task.history_side for task in tasks], ["b", "b", "a", "a"]
        )
        for current_side in ("a", "b"):
            current = [
                task
                for task in tasks
                if task.history_side != current_side
            ]
            current_players = [
                (
                    task.seat_a
                    if current_side == "a"
                    else 1 - task.seat_a
                )
                for task in current
            ]
            self.assertEqual(set(current_players), {0, 1})
            first_flags = [
                player == task.forced_first_player
                for player, task in zip(current_players, current)
            ]
            self.assertEqual(set(first_flags), {False, True})

    def test_smoke_schedule_stays_non_promotable_mini_closure(self):
        tasks = build_population_schedule(
            generation=1,
            decks=("fire",),
            games_per_matchup=2,
            current_generation_games=2,
            historical_games=0,
        )
        self.assertEqual(len(tasks), 2)
        self.assertEqual({task.seat_a for task in tasks}, {0, 1})
        self.assertTrue(all(task.history_side is None for task in tasks))
        validate_schedule_closure(tasks, expected_decks=("fire",))


class PopulationTrainingContractTests(unittest.TestCase):
    def test_action_mix_is_exact_50_30_20(self):
        fresh = [object() for _ in range(7)]
        replay = [object() for _ in range(20)]
        teacher = [object() for _ in range(20)]
        rows, counts = mix_action_training_rows(
            fresh, replay, teacher, rng=random.Random(17)
        )
        self.assertEqual(len(rows), 20)
        self.assertEqual(
            counts, {"fresh": 10, "replay": 6, "teacher": 4}
        )
        self.assertTrue(all(item in rows for item in fresh))

    def test_bilateral_and_history_trajectory_ownership(self):
        current_task = PopulationTask(
            task_id="current",
            generation=1,
            matchup_index=0,
            deck_a="fire",
            deck_b="water",
            game_index=0,
            seed_block=0,
            seed=17,
            seat_a=0,
            forced_first_player=0,
            opponent_kind="current",
            history_generation=None,
            history_side=None,
        )
        result = PopulationGameResult(
            task_id="current",
            winner_deck="fire",
            winner_player=0,
            score_a=1.0,
            trajectories={"fire": ["fa"], "water": ["wb"]},
            diagnostics={},
            terminal=True,
            steps=1,
        )
        owned = HybridPopulationTrainer._current_trajectories(
            current_task, result
        )
        self.assertEqual(owned, {"fire": ["fa"], "water": ["wb"]})

        historical = PopulationTask(
            **{
                **current_task.to_dict(),
                "task_id": "history",
                "opponent_kind": "history",
                "history_generation": 0,
                "history_side": "a",
            }
        )
        history_result = PopulationGameResult(
            task_id="history",
            winner_deck="water",
            winner_player=1,
            score_a=-1.0,
            trajectories={"fire": ["old"], "water": ["live"]},
            diagnostics={},
            terminal=True,
            steps=1,
        )
        self.assertEqual(
            HybridPopulationTrainer._current_trajectories(
                historical, history_result
            ),
            {"water": ["live"]},
        )


class RunStoreTests(unittest.TestCase):
    @staticmethod
    def _run_fixed_batches(
        run_dir: Path,
        *,
        device: str,
        stop_after: int | None = None,
    ) -> tuple[list[str], list[tuple[str, float]], dict[str, object]]:
        checkpoints = CheckpointStore(run_dir)
        replay = ReplayShardStore(run_dir)
        latest = checkpoints.load_latest(map_location=device)
        if latest is None:
            random.seed(713)
            torch.manual_seed(713)
            if device.startswith("cuda"):
                torch.cuda.manual_seed_all(713)
        model = torch.nn.Linear(3, 1).to(device)
        optimizer = torch.optim.SGD(model.parameters(), lr=0.05)
        completed: set[str] = set()
        sample_order: list[tuple[str, float]] = []
        if latest is not None:
            payload, _row = latest
            model.load_state_dict(payload["models"])
            optimizer.load_state_dict(payload["optimizer"])
            completed = set(payload["completed_task_ids"])
            sample_order = list(payload["sample_order"])
            restore_rng_state(payload["rng"])
        for task_index in range(4):
            task_id = f"task-{task_index}"
            if task_id in completed:
                continue
            python_sample = random.random()
            inputs = torch.randn(2, 3, device=device)
            target = torch.randn(2, 1, device=device) * python_sample
            loss = torch.nn.functional.mse_loss(model(inputs), target)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            completed.add(task_id)
            sample_order.append((task_id, python_sample))
            replay.write(task_id, {"task_id": task_id})
            checkpoints.save(
                task_id,
                {
                    "models": model.state_dict(),
                    "optimizer": optimizer.state_dict(),
                    "rng": capture_rng_state(),
                    "completed_task_ids": sorted(completed),
                    "sample_order": list(sample_order),
                    "replay_shards": replay.rows(verify=True),
                },
            )
            if stop_after is not None and len(completed) >= stop_after:
                break
        state = {
            key: value.detach().cpu().clone()
            for key, value in model.state_dict().items()
        }
        return sorted(completed), sample_order, state

    def test_events_are_ordered_and_reconnect_skips_seen_rows(self):
        with tempfile.TemporaryDirectory() as temp:
            run_dir = create_run_layout(
                temp,
                "event-run",
                run_payload={"status": "created"},
            )
            writer = TrainingEventWriter(run_dir, "event-run")
            first = writer.emit(stage="teacher", completed=1, total=2)
            second = writer.emit(stage="teacher", completed=2, total=2)
            self.assertEqual((first["seq"], second["seq"]), (1, 2))
            self.assertEqual(
                [row["seq"] for row in read_events(
                    run_dir / "events.jsonl", after_seq=1
                )],
                [2],
            )
            resumed = TrainingEventWriter(run_dir, "event-run")
            self.assertEqual(
                resumed.emit(stage="dagger")["seq"], 3
            )

    def test_run_paths_reject_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                resolve_within(root, "../outside")
            with self.assertRaises(ValueError):
                resolve_within(root, root.parent / "outside")

    @unittest.skipIf(torch is None, "PyTorch is not installed")
    def test_checkpoint_hash_and_rng_restore_are_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            run_dir = create_run_layout(
                temp,
                "checkpoint-run",
                run_payload={"status": "created"},
            )
            store = CheckpointStore(run_dir)
            random.seed(91)
            torch.manual_seed(91)
            model = torch.nn.Linear(3, 1)
            optimizer = torch.optim.SGD(model.parameters(), lr=0.05)

            def update() -> tuple[float, float]:
                scale = random.random()
                inputs = torch.randn(2, 3)
                target = torch.randn(2, 1) * scale
                loss = torch.nn.functional.mse_loss(model(inputs), target)
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
                return scale, float(loss.detach())

            update()
            checkpoint = {
                "models": model.state_dict(),
                "optimizer": optimizer.state_dict(),
                "rng": capture_rng_state(),
                "completed_task_ids": ["task-0"],
            }
            row = store.save("task-0", checkpoint)
            expected_sample = update()
            expected_state = {
                key: value.detach().clone()
                for key, value in model.state_dict().items()
            }

            loaded, _ = store.load_latest()
            model.load_state_dict(loaded["models"])
            optimizer.load_state_dict(loaded["optimizer"])
            restore_rng_state(loaded["rng"])
            actual_sample = update()
            self.assertEqual(actual_sample, expected_sample)
            for key, value in model.state_dict().items():
                self.assertTrue(torch.equal(value, expected_state[key]))

            checkpoint_path = run_dir / "checkpoints" / row["path"]
            checkpoint_path.write_bytes(
                checkpoint_path.read_bytes() + b"corrupt"
            )
            with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                store.load_latest()

    @unittest.skipIf(torch is None, "PyTorch is not installed")
    def test_cpu_continuous_and_resumed_batches_are_identical(self):
        with (
            tempfile.TemporaryDirectory() as continuous_temp,
            tempfile.TemporaryDirectory() as resumed_temp,
        ):
            continuous = create_run_layout(
                continuous_temp,
                "continuous",
                run_payload={"status": "created"},
            )
            resumed = create_run_layout(
                resumed_temp,
                "resumed",
                run_payload={"status": "created"},
            )
            expected = self._run_fixed_batches(continuous, device="cpu")
            first_half = self._run_fixed_batches(
                resumed, device="cpu", stop_after=2
            )
            self.assertEqual(first_half[0], ["task-0", "task-1"])
            actual = self._run_fixed_batches(resumed, device="cpu")
            self.assertEqual(actual[:2], expected[:2])
            self.assertEqual(
                [row["batch_id"] for row in ReplayShardStore(
                    resumed
                ).rows(verify=True)],
                [f"task-{index}" for index in range(4)],
            )
            for key in expected[2]:
                self.assertTrue(torch.equal(expected[2][key], actual[2][key]))

    @unittest.skipUnless(
        torch is not None and torch.cuda.is_available(),
        "CUDA is not available",
    )
    def test_cuda_resume_restores_rng_without_duplicate_tasks(self):
        with (
            tempfile.TemporaryDirectory() as continuous_temp,
            tempfile.TemporaryDirectory() as resumed_temp,
        ):
            continuous = create_run_layout(
                continuous_temp,
                "cuda-continuous",
                run_payload={"status": "created"},
            )
            resumed = create_run_layout(
                resumed_temp,
                "cuda-resumed",
                run_payload={"status": "created"},
            )
            expected = self._run_fixed_batches(
                continuous, device="cuda"
            )
            self._run_fixed_batches(
                resumed, device="cuda", stop_after=2
            )
            actual = self._run_fixed_batches(resumed, device="cuda")
            self.assertEqual(actual[:2], expected[:2])
            self.assertEqual(
                actual[0], [f"task-{index}" for index in range(4)]
            )
            for key in expected[2]:
                self.assertTrue(torch.equal(expected[2][key], actual[2][key]))


class HybridPromotionRecoveryTests(unittest.TestCase):
    def test_recovery_rejects_backup_outside_transaction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            transaction_parent = root / "transactions"
            transaction_root = transaction_parent / "attempt"
            target = root / "live" / "fire.pt"
            outside_backup = root / "outside" / "fire.pt"
            target.parent.mkdir(parents=True)
            outside_backup.parent.mkdir(parents=True)
            target.write_bytes(b"live")
            outside_backup.write_bytes(b"untrusted")
            atomic_write_json(
                transaction_root / "journal.json",
                {
                    "state": "applying",
                    "entries": [{
                        "target": str(target),
                        "backup": str(outside_backup),
                        "existed": True,
                        "backup_sha256": "0" * 64,
                    }],
                },
            )

            with self.assertRaisesRegex(OSError, "Unsafe backup"):
                _recover_incomplete_transactions(
                    transaction_parent,
                    {target.resolve()},
                )
            self.assertEqual(target.read_bytes(), b"live")


if __name__ == "__main__":
    unittest.main()

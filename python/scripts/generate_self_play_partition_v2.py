from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from engine.ai.dl.alphazero_v2 import (
    AlphaZeroV2Config,
    AlphaZeroV2Trainer,
    _atomic_write_json,
)


def _live_pid(pid: object) -> bool:
    if type(pid) is not int or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except (OSError, ValueError):
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate one durable AlphaZero v2 self-play partition."
    )
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--worker-index", type=int, required=True)
    parser.add_argument("--worker-count", type=int, required=True)
    parser.add_argument("--search-slots", type=int, default=8)
    parser.add_argument("--target-batch", type=int, default=64)
    parser.add_argument("--max-batch", type=int, default=128)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    config_path = run_dir / "config.json"
    run_path = run_dir / "run.json"
    if not config_path.is_file() or not run_path.is_file():
        raise RuntimeError("self_play_partition_run_metadata_missing")
    config_payload = json.loads(config_path.read_text(encoding="utf-8"))
    config = AlphaZeroV2Config(**config_payload)
    if Path(config.output_dir).resolve() != run_dir:
        raise RuntimeError("self_play_partition_output_dir_mismatch")
    run_payload = json.loads(run_path.read_text(encoding="utf-8"))
    if _live_pid(run_payload.get("pid")):
        raise RuntimeError("self_play_partition_trainer_is_running")

    # Advisory worker locks permit distinct partitions to run together while
    # rejecting accidental duplicate workers for the same partition.
    try:
        import fcntl
    except ImportError as exc:  # pragma: no cover - server workers are Linux.
        raise RuntimeError("self_play_partition_requires_posix_lock") from exc
    lock_dir = run_dir / "self_play" / "worker_locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_path = lock_dir / (
        f"worker-{args.worker_index:02d}-of-{args.worker_count:02d}.lock"
    )
    with lock_path.open("a+", encoding="utf-8") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("self_play_partition_worker_already_running") \
                from exc
        lock_handle.seek(0)
        lock_handle.truncate()
        lock_handle.write(str(os.getpid()) + "\n")
        lock_handle.flush()

        trainer = AlphaZeroV2Trainer(config)
        summary = trainer.run_self_play_partition(
            worker_index=args.worker_index,
            worker_count=args.worker_count,
            search_slots=args.search_slots,
            target_batch_size=args.target_batch,
            max_batch_size=args.max_batch,
        )
        result_path = lock_dir / (
            f"worker-{args.worker_index:02d}-of-{args.worker_count:02d}.json"
        )
        _atomic_write_json(result_path, summary)
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

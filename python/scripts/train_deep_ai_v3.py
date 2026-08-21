from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from dataclasses import asdict
from pathlib import Path

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.replay_v3 import ReplayStoreV3  # noqa: E402
from engine.ai.dl.run_control_v3 import TrainingCancelled  # noqa: E402
from engine.ai.dl.run_store import update_run  # noqa: E402
from engine.ai.dl.teacher_v3 import (  # noqa: E402
    generate_teacher_replay_v3,
    teacher_tasks_v3,
)
from engine.ai.dl.trainer_v3 import (  # noqa: E402
    AlphaZeroV3Config,
    AlphaZeroV3Trainer,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Deep AI v3 toolchain")
    commands = parser.add_subparsers(dest="command", required=True)
    bootstrap = commands.add_parser("bootstrap")
    bootstrap.add_argument("--output", type=Path, required=True)
    bootstrap.add_argument("--games-per-matchup", type=int, default=20)
    bootstrap.add_argument("--task-limit", type=int)
    bootstrap.add_argument("--max-decisions", type=int, default=512)
    bootstrap.add_argument("--workers", type=int, default=1)
    bootstrap.add_argument("--challenge-node-budget", type=int, default=1)
    bootstrap.add_argument("--challenge-max-depth", type=int, default=2)
    bootstrap.add_argument("--seed", type=int, default=17)

    verify = commands.add_parser("verify-replay")
    verify.add_argument("--replay", type=Path, required=True)

    train = commands.add_parser("train")
    train.add_argument("--preset", choices=("smoke", "pilot", "release"), default="smoke")
    train.add_argument("--output-dir", type=Path, required=True)
    train.add_argument("--teacher-replay", type=Path)
    train.add_argument("--device")
    train.add_argument("--seed", type=int, default=17)
    train.add_argument("--cycles", type=int)
    train.add_argument("--cycle-samples", type=int)
    train.add_argument("--simulations", type=int)
    train.add_argument("--concurrent-games", type=int)
    train.add_argument("--actor-threads", type=int)
    train.add_argument("--batch-size", type=int)
    return parser


def _atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def _config(args: argparse.Namespace) -> AlphaZeroV3Config:
    overrides = {"seed": args.seed}
    for name in (
        "device", "cycles", "cycle_samples", "simulations",
        "concurrent_games", "actor_threads", "batch_size",
    ):
        value = getattr(args, name)
        if value is not None:
            overrides[name] = value
    if args.teacher_replay is not None:
        overrides["teacher_replay"] = str(args.teacher_replay.resolve())
    factory = {
        "smoke": AlphaZeroV3Config.smoke,
        "pilot": AlphaZeroV3Config.pilot,
        "release": AlphaZeroV3Config,
    }[args.preset]
    return factory(str(args.output_dir.resolve()), **overrides)


def _dashboard_status_callback(output_dir: Path):
    run_json = output_dir / "run.json"

    def publish(status: str) -> None:
        if not run_json.is_file():
            return
        resumable = (
            output_dir / "checkpoints-v3" / "latest.json"
        ).is_file()
        update_run(
            output_dir,
            status=str(status),
            resumable=resumable,
        )

    return publish


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "bootstrap":
        replay = ReplayStoreV3(args.output.resolve())
        tasks = teacher_tasks_v3(
            games_per_matchup=args.games_per_matchup,
            seed=args.seed,
        )
        if args.task_limit is not None:
            tasks = tasks[: max(0, args.task_limit)]
        summary = generate_teacher_replay_v3(
            tasks,
            replay,
            max_decisions=args.max_decisions,
            workers=args.workers,
            challenge_config={
                "search_node_budget": args.challenge_node_budget,
                "planner_max_depth": args.challenge_max_depth,
            },
        )
        summary["replay"] = replay.verify()
        source = {
            "schema": "ptcg_deep_teacher_source_v3",
            "challenge_config": summary["challenge_config"],
            "task_count": len(tasks),
            "tasks": [asdict(task) for task in tasks],
            "replay": summary["replay"],
        }
        canonical = json.dumps(
            source,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        source["manifest_sha256"] = hashlib.sha256(canonical).hexdigest()
        source_path = replay.root / "teacher-source-v3.json"
        _atomic_json(source_path, source)
        summary["source_manifest"] = str(source_path)
    elif args.command == "verify-replay":
        summary = ReplayStoreV3(args.replay.resolve()).verify()
    else:
        output_dir = args.output_dir.resolve()
        publish = _dashboard_status_callback(output_dir)
        try:
            summary = AlphaZeroV3Trainer(
                _config(args),
                status_callback=publish,
            ).run()
        except TrainingCancelled:
            publish("cancelled")
            print(json.dumps({
                "trainer": "infoset_alphazero_v3",
                "status": "cancelled",
                "resumable": (
                    output_dir / "checkpoints-v3" / "latest.json"
                ).is_file(),
            }, ensure_ascii=False, indent=2, sort_keys=True))
            return 130
        except BaseException:
            publish("recoverable")
            raise
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    if args.command == "train" and not bool(summary.get("pilot_passed")):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

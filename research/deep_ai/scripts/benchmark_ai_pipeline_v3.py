from __future__ import annotations

import argparse
import os
import json
import platform
import statistics
import sys
import time
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

RESEARCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = RESEARCH_ROOT / "python"
NATIVE_ROOT = RESEARCH_ROOT / "build" / "native"
for import_root in (NATIVE_ROOT, PYTHON_ROOT):
    if str(import_root) not in sys.path:
        sys.path.insert(0, str(import_root))

import torch  # noqa: E402

from deep_ai.actor_v3 import (  # noqa: E402
    ActorConfigV3,
    GameTaskV3,
    NativeActorServiceV3,
)
from deep_ai.inference_v3 import NativeBatchTorchBrokerV3  # noqa: E402
from deep_ai.model_v3 import create_model  # noqa: E402
from deep_ai.teacher_v3 import (  # noqa: E402
    TeacherTaskV3,
    setup_teacher_game,
)
from engine.native_state_codec import state_to_native_snapshot  # noqa: E402


def _tasks(games: int, max_decisions: int, seed: int) -> list[GameTaskV3]:
    decks = (
        "fire", "water", "psychic", "lightning", "fighting",
        "colorless", "dragon", "grass", "steel", "darkness",
    )
    return [
        GameTaskV3(
            f"benchmark-v3-{index:03d}",
            0,
            decks[index % len(decks)],
            decks[(index * 3 + 1) % len(decks)],
            seed + index * 101,
            index & 1,
            (index >> 1) & 1,
            max_decisions=max_decisions,
        )
        for index in range(games)
    ]


def _end_to_end(
    model: Any,
    *,
    device: str,
    games: int,
    simulations: int,
    max_decisions: int,
    seed: int,
) -> dict[str, Any]:
    config = ActorConfigV3(
        concurrent_games=games,
        search_slots=min(16, games),
        simulations=simulations,
        max_depth=32,
        max_inflight_leaves=min(8, simulations),
        inference_target_batch=128,
        inference_max_batch=256,
        training=True,
        strict=False,
    )
    started = time.perf_counter()
    with NativeActorServiceV3(
        {0: model}, device=device, config=config
    ) as actors:
        result = actors.run(_tasks(games, max_decisions, seed))
    elapsed = time.perf_counter() - started
    native = result["native"]
    structural = [
        row for row in result["games"]
        if row["error"] not in {"", "v3_actor_decision_cap"}
    ]
    return {
        "elapsed_seconds": elapsed,
        "games": games,
        "decisions": int(native["decisions"]),
        "simulations": int(native["simulations"]),
        "simulations_per_second": int(native["simulations"]) / elapsed,
        "decisions_per_second": int(native["decisions"]) / elapsed,
        "structural_errors": len(structural),
        "structural_details": structural,
        "native": native,
        "inference": result["inference"],
    }


def _fixed_root(
    model: Any,
    *,
    device: str,
    games: int,
    simulations: int,
    seed: int,
) -> dict[str, Any]:
    import json as json_module
    import ptcg_ai_core

    cards = json_module.loads(
        (REPO_ROOT / "godot" / "data" / "cards.json").read_text(encoding="utf-8")
    )
    decks = json_module.loads(
        (REPO_ROOT / "godot" / "data" / "decks.json").read_text(encoding="utf-8")
    )
    state = setup_teacher_game(
        TeacherTaskV3("fixed-v3", 0, "fire", "water", seed, 0, 0)
    )
    snapshot = state_to_native_snapshot(state)
    actor = int(snapshot["active_player_idx"])
    batch = ptcg_ai_core.NativeSelfPlayBatch()
    limiter = ptcg_ai_core.NativeSearchLimiter(min(16, games))
    broker = NativeBatchTorchBrokerV3(
        batch,
        {0: model},
        device=device,
        target_batch_size=128,
        max_batch_size=256,
    )
    jobs = [
        ptcg_ai_core.NativeSearchJob(cards, decks, batch, limiter)
        for _ in range(games)
    ]
    started = time.perf_counter()
    for index, job in enumerate(jobs):
        job.start(
            snapshot,
            actor,
            seed + index * 101,
            {
                "simulations": simulations,
                "max_depth": 32,
                "max_inflight_leaves": min(8, simulations),
                "training": True,
                "model_slot": 0,
            },
        )
    with ThreadPoolExecutor(max_workers=games) as executor:
        results = list(executor.map(lambda job: job.wait(), jobs))
    elapsed = time.perf_counter() - started
    batch.close()
    broker.close()
    completed = sum(int(row["simulations"]) for row in results)
    errors = [row.get("error", "") for row in results if not row.get("success")]
    return {
        "elapsed_seconds": elapsed,
        "games": games,
        "simulations": completed,
        "simulations_per_second": completed / elapsed,
        "errors": errors,
        "inference": broker.metrics,
    }


def run_benchmark(args: argparse.Namespace) -> dict[str, Any]:
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)
    model = create_model()
    fixed_rows = []
    e2e_rows = []
    for repeat in range(args.repeats):
        fixed_rows.append(_fixed_root(
            model,
            device=args.device,
            games=args.games,
            simulations=args.simulations,
            seed=args.seed + repeat * 10_000,
        ))
        e2e_rows.append(_end_to_end(
            model,
            device=args.device,
            games=args.games,
            simulations=args.simulations,
            max_decisions=args.max_decisions,
            seed=args.seed + repeat * 10_000,
        ))
    fixed_median = statistics.median(
        row["simulations_per_second"] for row in fixed_rows
    )
    e2e_median = statistics.median(
        row["simulations_per_second"] for row in e2e_rows
    )
    payload = {
        "schema": "ptcg_deep_pipeline_benchmark_v3",
        "hardware": {
            "platform": platform.platform(),
            "processor": platform.processor(),
            "torch": torch.__version__,
            "cuda": str(torch.version.cuda or ""),
            "device": (
                torch.cuda.get_device_name(0)
                if args.device.startswith("cuda") and torch.cuda.is_available()
                else args.device
            ),
        },
        "workload": {
            "repeats": args.repeats,
            "games": args.games,
            "simulations": args.simulations,
            "max_decisions": args.max_decisions,
            "seed": args.seed,
        },
        "fixed_root": {"median": fixed_median, "runs": fixed_rows},
        "end_to_end": {"median": e2e_median, "runs": e2e_rows},
        "fixed_root_ratio": e2e_median / max(fixed_median, 1e-9),
        "fixed_root_gate_60_percent": e2e_median >= fixed_median * 0.60,
        "structural_errors": sum(row["structural_errors"] for row in e2e_rows),
    }
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--games", type=int, default=64)
    parser.add_argument("--simulations", type=int, default=64)
    parser.add_argument("--max-decisions", type=int, default=64)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    payload = run_benchmark(args)
    wire = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(
            prefix=args.output.name + ".",
            suffix=".tmp",
            dir=args.output.parent,
        )
        try:
            with os.fdopen(
                descriptor, "w", encoding="utf-8", newline="\n"
            ) as handle:
                handle.write(wire)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, args.output)
        finally:
            try:
                os.unlink(name)
            except FileNotFoundError:
                pass
    print(wire, end="")
    return 0 if payload["structural_errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

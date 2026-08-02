#!/usr/bin/env python
"""Compare the old whole-search cap with the v2 cooperative CPU limiter."""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import ptcg_ai_core
from scripts.benchmark_native_search_copy_v2 import _fixture


def _start_job(
    cards: dict[str, Any],
    decks: dict[str, Any],
    state: dict[str, Any],
    actor: int,
    batch: Any,
    limiter: Any,
    *,
    index: int,
    simulations: int,
    max_depth: int,
    max_inflight_leaves: int,
):
    job = ptcg_ai_core.NativeSearchJob(
        cards,
        decks,
        batch,
        limiter,
    )
    job.start(
        state,
        actor,
        7103 + index * 104729,
        {
            "simulations": simulations,
            "max_depth": max_depth,
            "c_puct": 1.4,
            "dirichlet_epsilon": 0.0,
            "temperature": 0.0,
            "training": False,
            "inference_wait_milliseconds": 25,
            "max_inflight_leaves": max_inflight_leaves,
        },
    )
    return job


def _serve_batch(batch: Any, stats: dict[str, Any]) -> None:
    tensors = batch.poll_inference(256, 10, 128, 2)
    request_ids = tensors["request_ids"]
    if request_ids.size == 0:
        return
    size = int(request_ids.size)
    stats["batches"] += 1
    stats["requests"] += size
    stats["max_batch"] = max(stats["max_batch"], size)
    batch.submit_inference(
        request_ids,
        np.zeros(tensors["candidate_mask"].shape, np.float32),
        np.zeros((size, 3), np.float32),
        tensors["candidate_mask"],
    )


def _run(
    *,
    cards: dict[str, Any],
    decks: dict[str, Any],
    state: dict[str, Any],
    actor: int,
    games: int,
    simulations: int,
    max_depth: int,
    cpu_slots: int,
    cooperative: bool,
    max_inflight_leaves: int,
) -> dict[str, Any]:
    batch = ptcg_ai_core.NativeSelfPlayBatch()
    limiter = (
        ptcg_ai_core.NativeSearchLimiter(cpu_slots)
        if cooperative
        else None
    )
    jobs: list[Any] = []
    next_index = 0
    initial = games if cooperative else min(games, cpu_slots)
    for _ in range(initial):
        jobs.append(
            _start_job(
                cards,
                decks,
                state,
                actor,
                batch,
                limiter,
                index=next_index,
                simulations=simulations,
                max_depth=max_depth,
                max_inflight_leaves=max_inflight_leaves,
            )
        )
        next_index += 1

    stats = {"batches": 0, "requests": 0, "max_batch": 0}
    completed = 0
    started = time.perf_counter()
    deadline = started + 120.0
    while completed < games:
        if time.perf_counter() >= deadline:
            for job in jobs:
                job.cancel()
            raise TimeoutError("native_parallel_benchmark_timeout")
        _serve_batch(batch, stats)
        retained = []
        for job in jobs:
            if not job.finished:
                retained.append(job)
                continue
            result = job.wait()
            if not result["success"]:
                raise RuntimeError(
                    f"native_parallel_search_failed:{result}"
                )
            completed += 1
            if not cooperative and next_index < games:
                retained.append(
                    _start_job(
                        cards,
                        decks,
                        state,
                        actor,
                        batch,
                        None,
                        index=next_index,
                        simulations=simulations,
                        max_depth=max_depth,
                        max_inflight_leaves=max_inflight_leaves,
                    )
                )
                next_index += 1
        jobs = retained
    elapsed = time.perf_counter() - started
    total_simulations = games * simulations
    return {
        "elapsed_seconds": elapsed,
        "simulations_per_second": total_simulations / elapsed,
        "inference_batches": stats["batches"],
        "inference_requests": stats["requests"],
        "average_batch": (
            stats["requests"] / max(1, stats["batches"])
        ),
        "max_batch": stats["max_batch"],
        "limiter_capacity": int(limiter.capacity) if limiter else 0,
        "limiter_max_active": int(limiter.max_active) if limiter else 0,
    }


def benchmark(
    *,
    repeats: int,
    games: int,
    simulations: int,
    max_depth: int,
    cpu_slots: int,
    max_inflight_leaves: int,
) -> dict[str, Any]:
    cards, decks, state, actor = _fixture(
        Path(__file__).resolve().parents[2]
    )
    samples: dict[str, list[dict[str, Any]]] = {
        "whole_search_cap": [],
        "cooperative_limiter": [],
    }
    for _ in range(repeats):
        samples["whole_search_cap"].append(
            _run(
                cards=cards,
                decks=decks,
                state=state,
                actor=actor,
                games=games,
                simulations=simulations,
                max_depth=max_depth,
                cpu_slots=cpu_slots,
                cooperative=False,
                max_inflight_leaves=max_inflight_leaves,
            )
        )
        samples["cooperative_limiter"].append(
            _run(
                cards=cards,
                decks=decks,
                state=state,
                actor=actor,
                games=games,
                simulations=simulations,
                max_depth=max_depth,
                cpu_slots=cpu_slots,
                cooperative=True,
                max_inflight_leaves=max_inflight_leaves,
            )
        )

    def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "samples": rows,
            "median_elapsed_seconds": statistics.median(
                row["elapsed_seconds"] for row in rows
            ),
            "median_simulations_per_second": statistics.median(
                row["simulations_per_second"] for row in rows
            ),
            "median_average_batch": statistics.median(
                row["average_batch"] for row in rows
            ),
            "max_observed_batch": max(row["max_batch"] for row in rows),
            "max_active_simulations": max(
                row["limiter_max_active"] for row in rows
            ),
        }

    legacy = summarize(samples["whole_search_cap"])
    cooperative = summarize(samples["cooperative_limiter"])
    return {
        "schema": "native_parallel_search_benchmark/1",
        "games": games,
        "simulations_per_game": simulations,
        "max_depth": max_depth,
        "cpu_slots": cpu_slots,
        "max_inflight_leaves": max_inflight_leaves,
        "whole_search_cap": legacy,
        "cooperative_limiter": cooperative,
        "throughput_speedup": (
            cooperative["median_simulations_per_second"]
            / legacy["median_simulations_per_second"]
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--games", type=int, default=64)
    parser.add_argument("--simulations", type=int, default=64)
    parser.add_argument("--max-depth", type=int, default=32)
    parser.add_argument("--cpu-slots", type=int, default=16)
    parser.add_argument("--max-inflight-leaves", type=int, default=1)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if min(
        args.repeats,
        args.games,
        args.simulations,
        args.max_depth,
        args.cpu_slots,
        args.max_inflight_leaves,
    ) <= 0:
        parser.error("all numeric arguments must be positive")
    report = benchmark(
        repeats=args.repeats,
        games=args.games,
        simulations=args.simulations,
        max_depth=args.max_depth,
        cpu_slots=args.cpu_slots,
        max_inflight_leaves=args.max_inflight_leaves,
    )
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

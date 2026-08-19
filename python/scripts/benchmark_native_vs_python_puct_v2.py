#!/usr/bin/env python
"""Compare native PUCT with the Python rules/deepcopy correctness fallback."""
from __future__ import annotations

import argparse
import copy
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
from engine.ai.dl.alphazero_v2 import (
    GameTask,
    _advance_nondecision_phase,
    _setup_game,
)
from engine.ai.dl.inference_v2 import UniformEvaluator
from engine.ai.dl.native_bridge_v2 import (
    game_state_to_native_wire,
    mask_native_snapshot,
)
from engine.ai.dl.puct_v2 import (
    InformationSetPUCT,
    PythonGameEnvironment,
)


def _fixture(repo_root: Path):
    formal = _setup_game(
        GameTask(
            game_id="native-vs-python-puct",
            generation=0,
            deck_a="fire",
            deck_b="water",
            seed=3907,
            seat_a=0,
            first_player=0,
        )
    )
    while _advance_nondecision_phase(formal):
        pass
    environment = PythonGameEnvironment()
    actor = environment.actor(formal)
    cards = json.loads(
        (repo_root / "godot" / "data" / "cards.json").read_text(
            encoding="utf-8"
        )
    )
    decks = json.loads(
        (repo_root / "godot" / "data" / "decks.json").read_text(
            encoding="utf-8"
        )
    )
    native_state = mask_native_snapshot(
        game_state_to_native_wire(formal),
        actor,
    )
    return formal, native_state, cards, decks, actor


def _run_python(
    formal: Any,
    actor: int,
    *,
    simulations: int,
    max_depth: int,
    seed: int,
) -> float:
    search = InformationSetPUCT(
        UniformEvaluator(),
        PythonGameEnvironment(),
        simulations=simulations,
        c_puct=1.4,
        dirichlet_epsilon=0.0,
        training=False,
        max_depth=max_depth,
        seed=seed,
    )
    started = time.perf_counter()
    result = search.search(
        copy.deepcopy(formal),
        actor,
        min_simulations=simulations,
        temperature=0.0,
    )
    elapsed = time.perf_counter() - started
    if result.simulations != simulations:
        raise RuntimeError("python_puct_simulation_count_mismatch")
    return elapsed


def _run_native(
    native_state: dict[str, Any],
    cards: dict[str, Any],
    decks: dict[str, Any],
    actor: int,
    *,
    simulations: int,
    max_depth: int,
    seed: int,
) -> float:
    batch = ptcg_ai_core.NativeSelfPlayBatch()
    job = ptcg_ai_core.NativeSearchJob(cards, decks, batch)
    started = time.perf_counter()
    job.start(
        native_state,
        actor,
        seed,
        {
            "simulations": simulations,
            "max_depth": max_depth,
            "c_puct": 1.4,
            "dirichlet_epsilon": 0.0,
            "temperature": 0.0,
            "training": False,
            "inference_wait_milliseconds": 10,
        },
    )
    deadline = started + 120.0
    while not job.finished:
        if time.perf_counter() >= deadline:
            job.cancel()
            raise TimeoutError("native_puct_benchmark_timeout")
        tensors = batch.poll_inference(256, 10)
        request_ids = tensors["request_ids"]
        if request_ids.size == 0:
            continue
        batch.submit_inference(
            request_ids,
            np.zeros(tensors["candidate_mask"].shape, np.float32),
            np.zeros((request_ids.size, 3), np.float32),
            tensors["candidate_mask"],
        )
    result = job.wait()
    elapsed = time.perf_counter() - started
    if not result["success"]:
        raise RuntimeError(f"native_puct_benchmark_failed:{result}")
    if int(result["simulations"]) != simulations:
        raise RuntimeError("native_puct_simulation_count_mismatch")
    return elapsed


def benchmark(
    *,
    repeats: int,
    simulations: int,
    max_depth: int,
    seed: int,
) -> dict[str, Any]:
    formal, native_state, cards, decks, actor = _fixture(
        Path(__file__).resolve().parents[2]
    )
    python_samples: list[float] = []
    native_samples: list[float] = []
    for repeat in range(repeats + 1):
        run_seed = seed + repeat * 104729
        python_elapsed = _run_python(
            formal,
            actor,
            simulations=simulations,
            max_depth=max_depth,
            seed=run_seed,
        )
        native_elapsed = _run_native(
            native_state,
            cards,
            decks,
            actor,
            simulations=simulations,
            max_depth=max_depth,
            seed=run_seed,
        )
        if repeat > 0:
            python_samples.append(python_elapsed)
            native_samples.append(native_elapsed)
    python_median = statistics.median(python_samples)
    native_median = statistics.median(native_samples)
    return {
        "schema": "native_vs_python_infoset_puct_benchmark/1",
        "baseline": "python_rules_deepcopy_infoset_puct",
        "candidate": "cpp_native_infoset_puct",
        "same_seed_and_simulation_count": True,
        "repeats": repeats,
        "simulations_per_search": simulations,
        "max_depth": max_depth,
        "python": {
            "samples_seconds": python_samples,
            "median_seconds": python_median,
            "simulations_per_second": simulations / python_median,
        },
        "native": {
            "samples_seconds": native_samples,
            "median_seconds": native_median,
            "simulations_per_second": simulations / native_median,
        },
        "throughput_speedup": python_median / native_median,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--simulations", type=int, default=128)
    parser.add_argument("--max-depth", type=int, default=32)
    parser.add_argument("--seed", type=int, default=3907)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if min(args.repeats, args.simulations, args.max_depth) <= 0:
        parser.error("repeats, simulations and max-depth must be positive")
    report = benchmark(
        repeats=args.repeats,
        simulations=args.simulations,
        max_depth=args.max_depth,
        seed=args.seed,
    )
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

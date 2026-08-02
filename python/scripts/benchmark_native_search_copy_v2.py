#!/usr/bin/env python
"""Benchmark AlphaZero v2 state-copy and infoset-candidate hot paths.

The benchmark uses the same native rules, determinizer, encoder, PUCT loop and
inference queue for every mode. It is a development measurement, not the
formal 10x release benchmark against the old Python planner.
"""
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


def _fixture(repo_root: Path):
    from engine.ai.dl.alphazero_v2 import (
        GameTask,
        _advance_nondecision_phase,
        _setup_game,
    )
    from engine.ai.dl.native_bridge_v2 import (
        game_state_to_native_wire,
        mask_native_snapshot,
    )
    from engine.game_engine import DEFAULT_GAME_ENGINE

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
    formal = _setup_game(
        GameTask(
            game_id="native-copy-benchmark",
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
    request = DEFAULT_GAME_ENGINE.pending_choice_request(formal)
    actor = (
        int(request.player)
        if request is not None
        else int(formal.active_player_idx)
    )
    state = mask_native_snapshot(
        game_state_to_native_wire(formal),
        actor,
    )
    return cards, decks, state, actor


def _run_once(
    cards: dict[str, Any],
    decks: dict[str, list[str]],
    state: dict[str, Any],
    actor: int,
    *,
    simulations: int,
    max_depth: int,
    force_deep_state_copy: bool,
    verify_candidate_cache: bool,
) -> tuple[float, dict[str, Any]]:
    batch = ptcg_ai_core.NativeSelfPlayBatch()
    job = ptcg_ai_core.NativeSearchJob(cards, decks, batch)
    started = time.perf_counter()
    job.start(
        state,
        actor,
        3907,
        {
            "simulations": simulations,
            "max_depth": max_depth,
            "c_puct": 1.4,
            "dirichlet_epsilon": 0.0,
            "temperature": 0.0,
            "training": False,
            "force_deep_state_copy": force_deep_state_copy,
            "verify_candidate_cache": verify_candidate_cache,
            "inference_wait_milliseconds": 10,
        },
    )
    deadline = started + 60.0
    while not job.finished:
        if time.perf_counter() >= deadline:
            job.cancel()
            raise TimeoutError("native_copy_benchmark_timeout")
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
        raise RuntimeError(f"native_copy_benchmark_failed:{result}")
    return elapsed, result


def benchmark(
    *,
    repeats: int,
    simulations: int,
    max_depth: int,
) -> dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[2]
    cards, decks, state, actor = _fixture(repo_root)
    modes = {
        "recursive_copy_regenerate_candidates": (True, True),
        "cow_regenerate_candidates": (False, True),
        "cow_infoset_candidate_cache": (False, False),
    }
    elapsed_by_mode: dict[str, list[float]] = {}
    profile_by_mode: dict[str, dict[str, list[int]]] = {}
    reference: dict[str, Any] | None = None
    profile_fields = (
        "determinization_microseconds",
        "projection_microseconds",
        "candidate_generation_microseconds",
        "apply_microseconds",
        "encoding_microseconds",
        "inference_wait_microseconds",
        "candidate_cache_hits",
        "candidate_cache_misses",
    )
    compared_fields = (
        "selected",
        "candidates",
        "visits",
        "value_sums",
        "probabilities",
        "simulations",
        "tree_nodes",
        "chance_nodes",
        "chance_edges",
    )
    for mode, (force_deep, verify_cache) in modes.items():
        samples: list[float] = []
        profiles = {field: [] for field in profile_fields}
        for repeat_index in range(repeats + 1):
            elapsed, result = _run_once(
                cards,
                decks,
                state,
                actor,
                simulations=simulations,
                max_depth=max_depth,
                force_deep_state_copy=force_deep,
                verify_candidate_cache=verify_cache,
            )
            if reference is None:
                reference = result
            elif any(
                result[field] != reference[field]
                for field in compared_fields
            ):
                raise RuntimeError("native_copy_modes_diverged")
            samples.append(elapsed)
            if repeat_index > 0:
                for field in profile_fields:
                    profiles[field].append(int(result[field]))
        elapsed_by_mode[mode] = samples[1:]
        profile_by_mode[mode] = profiles

    recursive_median = statistics.median(
        elapsed_by_mode["recursive_copy_regenerate_candidates"]
    )
    cow_median = statistics.median(
        elapsed_by_mode["cow_regenerate_candidates"]
    )
    cached_median = statistics.median(
        elapsed_by_mode["cow_infoset_candidate_cache"]
    )
    return {
        "schema": "native_search_hot_path_benchmark/2",
        "repeats": repeats,
        "simulations_per_search": simulations,
        "max_depth": max_depth,
        "recursive_copy_regenerate_candidates": {
            "samples_seconds": elapsed_by_mode[
                "recursive_copy_regenerate_candidates"
            ],
            "median_seconds": recursive_median,
            "simulations_per_second": simulations / recursive_median,
            "median_profile_microseconds": {
                field: statistics.median(values)
                for field, values in profile_by_mode[
                    "recursive_copy_regenerate_candidates"
                ].items()
            },
        },
        "cow_regenerate_candidates": {
            "samples_seconds": elapsed_by_mode[
                "cow_regenerate_candidates"
            ],
            "median_seconds": cow_median,
            "simulations_per_second": simulations / cow_median,
            "median_profile_microseconds": {
                field: statistics.median(values)
                for field, values in profile_by_mode[
                    "cow_regenerate_candidates"
                ].items()
            },
        },
        "cow_infoset_candidate_cache": {
            "samples_seconds": elapsed_by_mode[
                "cow_infoset_candidate_cache"
            ],
            "median_seconds": cached_median,
            "simulations_per_second": simulations / cached_median,
            "median_profile_microseconds": {
                field: statistics.median(values)
                for field, values in profile_by_mode[
                    "cow_infoset_candidate_cache"
                ].items()
            },
        },
        "cow_copy_speedup": recursive_median / cow_median,
        "candidate_cache_speedup": cow_median / cached_median,
        "combined_speedup": recursive_median / cached_median,
        "behavior_equal": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--simulations", type=int, default=128)
    parser.add_argument("--max-depth", type=int, default=32)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.repeats <= 0 or args.simulations <= 0 or args.max_depth <= 0:
        parser.error("repeats, simulations and max-depth must be positive")
    report = benchmark(
        repeats=args.repeats,
        simulations=args.simulations,
        max_depth=args.max_depth,
    )
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

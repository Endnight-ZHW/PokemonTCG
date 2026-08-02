#!/usr/bin/env python
"""Compare native v2 PUCT with an isolated retired DeepRoot v1 measurement."""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from scripts.benchmark_native_vs_python_puct_v2 import (  # noqa: E402
    _run_native,
)
from engine.ai.dl.native_bridge_v2 import mask_native_snapshot  # noqa: E402


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def benchmark(
    *,
    historical_path: Path,
    repeats: int,
    max_depth: int,
) -> dict[str, Any]:
    repo_root = Path(__file__).resolve().parents[2]
    historical = json.loads(
        historical_path.read_text(encoding="utf-8-sig")
    )
    if (
        historical.get("schema")
        != "retired_deeproot_ismcts_v1_measurement/1"
        or historical.get("planner_id") != "deep_root_ismcts_v1"
        or historical.get("historical_commit") != "b0f12b5"
    ):
        raise ValueError("retired_deeproot_measurement_invalid")
    simulations = int(historical.get("simulations_per_search", 0))
    seed = int(historical.get("seed", 0))
    actor = int(historical.get("actor", -1))
    state = dict(historical.get("state") or {})
    if simulations != 64 or actor not in (0, 1) or not state:
        raise ValueError("retired_deeproot_fixture_invalid")
    cards = json.loads(
        (repo_root / "godot/data/cards.json").read_text(
            encoding="utf-8"
        )
    )
    decks = dict(historical.get("decks") or {})
    if set(decks) != set(state.get("public_deck_keys") or ()):
        raise ValueError("retired_deeproot_deck_specs_invalid")
    native_state = mask_native_snapshot(state, actor)
    native_samples: list[float] = []
    for repeat in range(repeats + 1):
        native_elapsed = _run_native(
            native_state,
            cards,
            decks,
            actor,
            simulations=simulations,
            max_depth=max_depth,
            seed=seed + repeat * 104729,
        )
        if repeat > 0:
            native_samples.append(native_elapsed)
    native_median = statistics.median(native_samples)
    historical_median = float(historical.get("median_seconds", 0.0))
    if historical_median <= 0.0:
        raise ValueError("retired_deeproot_timing_invalid")
    return {
        "schema": "native_vs_python_infoset_puct_benchmark/1",
        "baseline": "retired_deeproot_ismcts_v1",
        "candidate": "cpp_native_infoset_puct_v2",
        "same_seed_and_simulation_count": True,
        "same_root_state": True,
        "simulations_per_search": simulations,
        "max_depth": max_depth,
        "historical": {
            **historical,
            "source_sha256": _sha256(historical_path),
        },
        "native": {
            "repeats": repeats,
            "samples_seconds": native_samples,
            "median_seconds": native_median,
            "simulations_per_second": simulations / native_median,
        },
        "throughput_speedup": historical_median / native_median,
        "release_baseline_complete": True,
        "release_baseline_note": (
            "Retired DeepRootISMCTS v1 was executed from detached commit "
            "b0f12b5 on the same machine with the same root state, seeds, "
            "and 64 simulations."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--historical", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--max-depth", type=int, default=16)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repeats <= 0 or args.max_depth <= 0:
        parser.error("repeats and max-depth must be positive")
    report = benchmark(
        historical_path=args.historical,
        repeats=args.repeats,
        max_depth=args.max_depth,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2)
        + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

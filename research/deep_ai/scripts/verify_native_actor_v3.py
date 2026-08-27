from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import tempfile
import time
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
from deep_ai.model_v3 import create_model  # noqa: E402
from deep_ai.v3_contract import RELEASE_DECKS  # noqa: E402


def _tasks(count: int, seed: int, max_decisions: int) -> list[GameTaskV3]:
    matchups = [
        (left, right)
        for left_index, left in enumerate(RELEASE_DECKS)
        for right in RELEASE_DECKS[left_index:]
    ]
    rows = []
    for index in range(int(count)):
        deck_a, deck_b = matchups[(index // 4) % len(matchups)]
        closure = index % 4
        rows.append(GameTaskV3(
            f"native-v3-{index:05d}",
            0,
            deck_a,
            deck_b,
            int(seed) + index * 101,
            closure & 1,
            (closure >> 1) & 1,
            max_decisions=max_decisions,
        ))
    return rows


class _UnusedModel(torch.nn.Module):
    def forward(self, *inputs: Any):
        batch, candidates = inputs[5].shape[:2]
        return (
            torch.zeros((batch, candidates), device=inputs[5].device),
            torch.zeros((batch, 3), device=inputs[5].device),
        )


def verify(args: argparse.Namespace) -> dict[str, Any]:
    direct = args.mode == "rules"
    device = "cpu" if direct else args.device
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)
    model = _UnusedModel() if direct else create_model()
    config = ActorConfigV3(
        concurrent_games=args.actors,
        search_slots=args.search_slots,
        simulations=1 if direct else args.simulations,
        max_depth=args.max_depth,
        max_inflight_leaves=1 if direct else min(8, args.simulations),
        inference_target_batch=128,
        inference_max_batch=256,
        training=False,
        strict=False,
        direct_policy=direct,
    )
    tasks = _tasks(args.games, args.seed, args.max_decisions)
    started = time.perf_counter()
    with NativeActorServiceV3({0: model}, device=device, config=config) as actors:
        result = actors.run(tasks)
    elapsed = time.perf_counter() - started
    structural = [
        row for row in result["games"]
        if str(row.get("error", ""))
            not in {"", "v3_actor_decision_cap"}
    ]
    return {
        "schema": "ptcg_native_actor_verification_v3",
        "mode": args.mode,
        "hardware": {
            "platform": platform.platform(),
            "processor": platform.processor(),
            "torch": torch.__version__,
            "cuda": str(torch.version.cuda or ""),
            "device": (
                torch.cuda.get_device_name(0)
                if device.startswith("cuda") and torch.cuda.is_available()
                else device
            ),
        },
        "workload": {
            "games": len(tasks),
            "actors": args.actors,
            "simulations": 0 if direct else args.simulations,
            "max_decisions": args.max_decisions,
            "seed": args.seed,
            "matchups": 55,
            "seat_first_player_closures": 4,
        },
        "elapsed_seconds": elapsed,
        "games_per_second": len(tasks) / max(elapsed, 1e-9),
        "structural_errors": len(structural),
        "structural_details": structural,
        "truncated_games": sum(
            str(row.get("error", "")) == "v3_actor_decision_cap"
            for row in result["games"]
        ),
        "native": result["native"],
        "inference": result["inference"],
    }


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("rules", "cuda-soak"), required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--games", type=int)
    parser.add_argument("--actors", type=int, default=64)
    parser.add_argument("--search-slots", type=int, default=16)
    parser.add_argument("--simulations", type=int, default=8)
    parser.add_argument("--max-depth", type=int, default=32)
    parser.add_argument("--max-decisions", type=int)
    parser.add_argument("--seed", type=int, default=1701)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.games is None:
        args.games = 2_200 if args.mode == "rules" else 256
    if args.max_decisions is None:
        args.max_decisions = 512 if args.mode == "rules" else 64
    payload = verify(args)
    if args.output is not None:
        _atomic_json(args.output.resolve(), payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if payload["structural_errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

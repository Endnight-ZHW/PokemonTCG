"""Create or resume a transactional hybrid population training run."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
INVOCATION_CWD = Path.cwd()
sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.hybrid_population import (  # noqa: E402
    HybridPopulationConfig,
    load_hybrid_config,
    prepare_hybrid_run,
    run_hybrid_population_training,
)
from engine.ai.dl.run_store import validate_run_id  # noqa: E402
from engine.ai.dl.model import torch  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run hybrid_population_rl with atomic checkpoints and a deterministic "
            "cross-deck population schedule."
        )
    )
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--preset",
        choices=["smoke", "research2", "research10", "release"],
        default="smoke",
    )
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--smoke-deck", default="fire")
    parser.add_argument(
        "--model-variant",
        choices=["v6_pooled", "v6_cross_attention"],
        default="v6_cross_attention",
    )
    parser.add_argument(
        "--runs-root",
        default=str(REPO_ROOT / "build" / "ai_training" / "runs"),
    )
    parser.add_argument(
        "--resume",
        action=argparse.BooleanOptionalAction,
        default=True,
    )
    args = parser.parse_args()

    run_id = validate_run_id(args.run_id)
    runs_root_value = Path(args.runs_root)
    runs_root = (
        runs_root_value.resolve()
        if runs_root_value.is_absolute()
        else (INVOCATION_CWD / runs_root_value).resolve()
    )
    run_dir = runs_root / run_id
    if not run_dir.exists():
        config = HybridPopulationConfig.from_preset(
            args.preset,
            seed=args.seed,
            smoke_deck=args.smoke_deck,
            model_variant=args.model_variant,
        )
        prepare_hybrid_run(REPO_ROOT, runs_root, run_id, config)
    elif not args.resume:
        parser.error(f"Run already exists: {run_id}")
    else:
        existing = load_hybrid_config(run_dir)
        if existing.preset != args.preset:
            parser.error(
                f"Existing run preset is {existing.preset}, not {args.preset}"
            )
        if existing.model_variant != args.model_variant:
            parser.error(
                "Existing run model variant is "
                f"{existing.model_variant}, not {args.model_variant}"
            )
        if int(existing.seed) != int(args.seed):
            parser.error(
                f"Existing run seed is {existing.seed}, not {args.seed}"
            )
        if (
            args.preset == "smoke"
            and tuple(existing.decks) != (str(args.smoke_deck),)
        ):
            parser.error(
                "Existing Smoke run deck is "
                f"{tuple(existing.decks)!r}, not {(str(args.smoke_deck),)!r}"
            )
        config = existing

    if args.preset in {"research2", "research10", "release"}:
        if (
            torch is None
            or not bool(torch.cuda.is_available())
            or not str(config.device).startswith("cuda")
            or not bool(config.use_amp)
        ):
            parser.error(
                f"{args.preset} requires CUDA and AMP; CPU fallback is "
                "not a valid v6 research/release run"
            )

    summary = run_hybrid_population_training(REPO_ROOT, run_dir)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    os.chdir(PYTHON_ROOT)
    raise SystemExit(main())

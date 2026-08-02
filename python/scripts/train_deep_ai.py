"""Single supported Deep AI training entrypoint: AlphaZero v2."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.alphazero_v2 import (  # noqa: E402
    AlphaZeroV2Config,
    AlphaZeroV2Trainer,
    generate_bootstrap_cache,
    load_bootstrap_splits,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Train the universal information-set AlphaZero v2 Deep AI. "
            "Legacy teacher_dagger_rl, alpha_zero_rl, and "
            "hybrid_population_rl pipelines have been removed."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    bootstrap = subparsers.add_parser(
        "bootstrap",
        help="Generate the one-time frozen 1,100-game Challenge dataset.",
    )
    bootstrap.add_argument(
        "--output",
        type=Path,
        default=PYTHON_ROOT / "data" / "ai_training" / "bootstrap-v2.pt",
    )
    bootstrap.add_argument("--workers", type=int, default=16)
    bootstrap.add_argument("--seed", type=int, default=17)
    bootstrap.add_argument("--max-decisions", type=int, default=512)

    verify = subparsers.add_parser(
        "verify-cache",
        help="Validate the frozen dataset and all source fingerprints.",
    )
    verify.add_argument(
        "--cache",
        type=Path,
        default=PYTHON_ROOT / "data" / "ai_training" / "bootstrap-v2.pt",
    )

    train = subparsers.add_parser(
        "train",
        help="Run the generation-synchronous AlphaZero v2 pipeline.",
    )
    train.add_argument(
        "--preset",
        choices=("smoke", "release"),
        default="smoke",
    )
    train.add_argument(
        "--output-dir",
        type=Path,
        default=PYTHON_ROOT / "build" / "ai_training" / "alphazero-v2",
    )
    train.add_argument(
        "--bootstrap-cache",
        type=Path,
        default=PYTHON_ROOT / "data" / "ai_training" / "bootstrap-v2.pt",
    )
    train.add_argument("--device", default="cuda")
    train.add_argument("--seed", type=int, default=17)
    train.add_argument("--simulations", type=int)
    train.add_argument("--actor-threads", type=int)
    train.add_argument("--concurrent-games", type=int)
    train.add_argument("--inference-target-batch", type=int)
    train.add_argument("--inference-max-batch", type=int)
    train.add_argument("--inference-coalesce-ms", type=float)
    train.add_argument("--native-inflight-leaves", type=int)
    train.add_argument("--batch-size", type=int)
    train.add_argument(
        "--allow-python-fallback",
        action="store_true",
        help=(
            "Permit the slow Python rules fallback. Intended only for smoke "
            "and correctness tests; release defaults to the native ABI."
        ),
    )
    return parser


def _config(args: argparse.Namespace) -> AlphaZeroV2Config:
    overrides = {
        "device": str(args.device),
        "seed": int(args.seed),
    }
    for argument, field in (
        ("simulations", "simulations"),
        ("actor_threads", "actor_threads"),
        ("concurrent_games", "concurrent_games"),
        ("inference_target_batch", "inference_target_batch"),
        ("inference_max_batch", "inference_max_batch"),
        ("native_inflight_leaves", "native_inflight_leaves"),
        ("batch_size", "batch_size"),
    ):
        value = getattr(args, argument)
        if value is not None:
            overrides[field] = int(value)
    if args.inference_coalesce_ms is not None:
        overrides["inference_coalesce_ms"] = float(
            args.inference_coalesce_ms
        )
    if args.allow_python_fallback:
        overrides["require_native"] = False
    factory = (
        AlphaZeroV2Config.release
        if args.preset == "release"
        else AlphaZeroV2Config.smoke
    )
    return factory(
        str(args.output_dir),
        str(args.bootstrap_cache),
        **overrides,
    )


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "bootstrap":
        summary = generate_bootstrap_cache(
            args.output,
            repo_root=REPO_ROOT,
            workers=args.workers,
            seed=args.seed,
            max_decisions=args.max_decisions,
        )
    elif args.command == "verify-cache":
        train_samples, validation_samples = load_bootstrap_splits(
            args.cache,
            repo_root=REPO_ROOT,
        )
        summary = {
            "valid": True,
            "samples": len(train_samples) + len(validation_samples),
            "train_samples": len(train_samples),
            "validation_samples": len(validation_samples),
            "cache": str(args.cache),
        }
    else:
        from engine.ai.dl.run_store import update_run

        run_json = args.output_dir / "run.json"
        if run_json.is_file():
            update_run(args.output_dir, status="running")
        try:
            summary = AlphaZeroV2Trainer(_config(args)).run()
        except Exception as exc:
            if run_json.is_file():
                update_run(
                    args.output_dir,
                    status="failed",
                    pid=0,
                    resumable=(
                        args.output_dir / "training_state.json"
                    ).is_file(),
                    error=f"{type(exc).__name__}:{exc}",
                )
            raise
        if run_json.is_file():
            update_run(
                args.output_dir,
                status="completed",
                pid=0,
                resumable=False,
                # A strong candidate is not promotable until the independent
                # rules, security, performance and device evidence bundle has
                # been finalized and hashed.
                promotable=False,
                gate={
                    "status": (
                        "pending_evidence"
                        if (
                            args.preset == "release"
                            and summary["accepted"]
                        )
                        else "rejected"
                    ),
                    "evidence_path": str(
                        Path(summary["evidence_path"]).relative_to(
                            args.output_dir
                        ).as_posix()
                    ),
                    "evidence_sha256": summary["evidence_sha256"],
                },
            )
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

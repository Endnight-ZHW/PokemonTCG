from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import replace
from pathlib import Path


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = RESEARCH_ROOT / "python"
NATIVE_ROOT = RESEARCH_ROOT / "build" / "native"
for import_root in (NATIVE_ROOT, PYTHON_ROOT):
    if str(import_root) not in sys.path:
        sys.path.insert(0, str(import_root))

from deep_ai.challenge_arena import (  # noqa: E402
    PRODUCT_STRATEGIES,
    load_agent_spec,
)
from deep_ai.evaluation_challenge import run_challenge_evaluation


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run callback-free native Challenge-vs-Challenge games and write "
            "paired strength/performance reports."
        )
    )
    parser.add_argument(
        "--preset",
        choices=("smoke", "pr", "refactor", "strategy", "nightly", "release", "calibration"),
        default="smoke",
    )
    parser.add_argument("--candidate", default="challenge_next")
    parser.add_argument("--baseline", help="Champion spec; smoke defaults to the frozen 0.8.0 anchor.")
    parser.add_argument("--anchor", default="challenge_release_v1")
    parser.add_argument("--anchor-build-manifest", type=Path)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--declare-only", action="store_true")
    parser.add_argument(
        "--candidate-engine",
        choices=("deck_planner_v1", "turn_beam_v2", "strategic_intent_v3"),
    )
    parser.add_argument(
        "--baseline-engine",
        choices=("deck_planner_v1", "turn_beam_v2", "strategic_intent_v3"),
    )
    parser.add_argument(
        "--candidate-deck-inspection",
        choices=("enabled", "disabled"),
        help="A/B treatment: let the candidate use owner-only full-deck browse data.",
    )
    parser.add_argument(
        "--baseline-deck-inspection",
        choices=("enabled", "disabled"),
        help="A/B treatment: let the baseline use owner-only full-deck browse data.",
    )
    parser.add_argument("--candidate-build-manifest", type=Path)
    parser.add_argument("--baseline-build-manifest", type=Path)
    parser.add_argument(
        "--comparison-mode",
        choices=("release-bundle", "implementation-only", "same-binary-strategy"),
        default="release-bundle",
    )
    parser.add_argument("--allow-self-play", action="store_true")
    parser.add_argument(
        "--workers",
        type=int,
        default=max(1, min(8, os.cpu_count() or 1)),
    )
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--replicates", type=int)
    parser.add_argument("--max-decisions", type=int, default=1024)
    parser.add_argument(
        "--decision-timeout-milliseconds",
        type=int,
        default=120000,
        help="Equal watchdog for both agents; timeout is retried and never scored.",
    )
    parser.add_argument("--trace-all", action="store_true")
    parser.add_argument(
        "--output",
        type=Path,
        help="Output directory (default: build/challenge-arena/<preset>)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    args.baseline = args.baseline or ("challenge_release_v1" if args.preset == "smoke" else "challenge_refactor_before" if args.preset == "refactor" else "challenge_champion_v1")
    product_strategies = json.loads(PRODUCT_STRATEGIES.read_text(encoding="utf-8"))
    candidate = load_agent_spec(
        args.candidate,
        product_strategies=product_strategies,
        build_manifest=args.candidate_build_manifest,
    )
    baseline = load_agent_spec(
        args.baseline,
        product_strategies=product_strategies,
        build_manifest=args.baseline_build_manifest,
    )
    if args.candidate_engine:
        candidate = replace(
            candidate,
            evaluation_options={
                **dict(candidate.evaluation_options),
                "engine": args.candidate_engine,
            },
        )
    if args.baseline_engine:
        baseline = replace(
            baseline,
            evaluation_options={
                **dict(baseline.evaluation_options),
                "engine": args.baseline_engine,
            },
        )
    if args.candidate_deck_inspection:
        candidate = replace(
            candidate,
            evaluation_options={
                **dict(candidate.evaluation_options),
                "use_deck_inspection": (
                    args.candidate_deck_inspection == "enabled"
                ),
            },
        )
    if args.baseline_deck_inspection:
        baseline = replace(
            baseline,
            evaluation_options={
                **dict(baseline.evaluation_options),
                "use_deck_inspection": (
                    args.baseline_deck_inspection == "enabled"
                ),
            },
        )
    if args.decision_timeout_milliseconds <= 0:
        raise ValueError("decision_timeout_milliseconds_must_be_positive")
    paired_options = {"time_budget_ms": 0, "search_worker_mode": "single"}
    candidate = replace(candidate, evaluation_options={**dict(candidate.evaluation_options), **paired_options})
    baseline = replace(baseline, evaluation_options={**dict(baseline.evaluation_options), **paired_options})
    candidate = replace(
        candidate,
        decision_timeout_milliseconds=args.decision_timeout_milliseconds,
    )
    baseline = replace(
        baseline,
        decision_timeout_milliseconds=args.decision_timeout_milliseconds,
    )
    anchor = None
    if args.preset in {"release", "refactor", "strategy"}:
        anchor = load_agent_spec(args.anchor, build_manifest=args.anchor_build_manifest)
        anchor = replace(anchor, decision_timeout_milliseconds=args.decision_timeout_milliseconds,
                         evaluation_options={**dict(anchor.evaluation_options), **paired_options})
    output = args.output or Path("build") / "challenge-arena" / args.preset
    if not output.is_absolute():
        output = (REPO_ROOT / output).resolve()
    result = run_challenge_evaluation(
        preset=args.preset,
        candidate=candidate,
        champion=baseline,
        workers=args.workers,
        output=output,
        seed=args.seed,
        replicates=args.replicates,
        max_decisions=args.max_decisions,
        trace_all=args.trace_all,
        allow_self_play=args.allow_self_play,
        comparison_mode=args.comparison_mode,
        anchor=anchor,
        cache_root=args.cache_dir,
        declare_only=args.declare_only,
    )
    if args.declare_only:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    summary = result
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    status = summary["gate_status"]
    return {
        "pass": 0,
        "fail": 3,
        "inconclusive": 4,
        "infrastructure_fail": 5,
    }.get(status, 2)


if __name__ == "__main__":
    raise SystemExit(main())

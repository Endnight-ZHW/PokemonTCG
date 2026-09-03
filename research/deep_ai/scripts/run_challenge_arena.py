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
    run_arena,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run callback-free native Challenge-vs-Challenge games and write "
            "paired strength/performance reports."
        )
    )
    parser.add_argument(
        "--preset",
        choices=("smoke", "pr", "nightly", "release", "calibration", "focused"),
        default="smoke",
    )
    parser.add_argument("--candidate", default="challenge_next")
    parser.add_argument("--baseline", default="challenge_release_v1")
    parser.add_argument(
        "--candidate-engine",
        choices=("turn_beam_v2", "strategic_intent_v3"),
    )
    parser.add_argument(
        "--baseline-engine",
        choices=("turn_beam_v2", "strategic_intent_v3"),
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
    parser.add_argument(
        "--candidate-strategy-optimization",
        choices=("enabled", "disabled"),
    )
    parser.add_argument(
        "--baseline-strategy-optimization",
        choices=("enabled", "disabled"),
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
    parser.add_argument("--max-decisions", type=int, default=512)
    parser.add_argument(
        "--decision-timeout-milliseconds",
        type=int,
        default=120000,
        help="Equal watchdog for both agents; timeout is retried and never scored.",
    )
    parser.add_argument("--candidate-deck", action="append", default=[])
    parser.add_argument("--baseline-deck", action="append", default=[])
    parser.add_argument(
        "--mirror-only",
        action="store_true",
        help="Run only same-deck matchups; requires the focused preset.",
    )
    parser.add_argument("--trace-all", action="store_true")
    parser.add_argument("--bootstrap-samples", type=int, default=2000)
    parser.add_argument("--truncated-rate-limit", type=float, default=0.001)
    parser.add_argument(
        "--latency-ratio-limit",
        type=float,
        default=1.15,
        help="Diagnostic-only search P95 ratio warning threshold.",
    )
    parser.add_argument(
        "--max-candidate-p95-ms",
        type=float,
        help="Diagnostic-only absolute search P95 warning threshold.",
    )
    parser.add_argument(
        "--gate",
        choices=("auto", "none", "structural", "regression", "promotion"),
        default="auto",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output directory (default: build/challenge-arena/<preset>)",
    )
    return parser


def _selected_gate(preset: str, requested: str) -> str:
    if requested != "auto":
        return requested
    if preset == "smoke":
        return "structural"
    if preset in {"pr", "nightly"}:
        return "regression"
    if preset == "release":
        return "promotion"
    return "none"


def _gate_passed(summary: dict, gate: str, truncated_limit: float) -> bool:
    if gate == "none":
        return True
    if gate == "structural":
        integrity = summary["integrity"]
        return (
            int(integrity["structural_errors"]) == 0
            and float(integrity["truncated_rate"]) <= float(truncated_limit)
        )
    return bool(summary["gates"][gate]["passed"])


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
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
    if args.candidate_strategy_optimization:
        candidate = replace(
            candidate,
            evaluation_options={
                **dict(candidate.evaluation_options),
                "use_strategy_optimization": (
                    args.candidate_strategy_optimization == "enabled"
                ),
            },
        )
    if args.baseline_strategy_optimization:
        baseline = replace(
            baseline,
            evaluation_options={
                **dict(baseline.evaluation_options),
                "use_strategy_optimization": (
                    args.baseline_strategy_optimization == "enabled"
                ),
            },
        )
    if args.decision_timeout_milliseconds <= 0:
        raise ValueError("decision_timeout_milliseconds_must_be_positive")
    candidate = replace(
        candidate,
        decision_timeout_milliseconds=args.decision_timeout_milliseconds,
    )
    baseline = replace(
        baseline,
        decision_timeout_milliseconds=args.decision_timeout_milliseconds,
    )
    output = args.output or Path("build") / "challenge-arena" / args.preset
    if not output.is_absolute():
        output = (REPO_ROOT / output).resolve()
    result = run_arena(
        preset=args.preset,
        candidate=candidate,
        baseline=baseline,
        workers=args.workers,
        output=output,
        seed=args.seed,
        replicates=args.replicates,
        max_decisions=args.max_decisions,
        candidate_decks=args.candidate_deck,
        baseline_decks=args.baseline_deck,
        mirror_only=args.mirror_only,
        trace_all=args.trace_all,
        bootstrap_samples=args.bootstrap_samples,
        truncated_rate_limit=args.truncated_rate_limit,
        latency_ratio_limit=args.latency_ratio_limit,
        max_candidate_p95_ms=args.max_candidate_p95_ms,
        allow_self_play=args.allow_self_play,
        comparison_mode=args.comparison_mode,
    )
    summary = result["summary"]
    gate = _selected_gate(args.preset, args.gate)
    canonical_status = str(summary["arena"]["gate_status"])
    if args.gate == "auto":
        status = canonical_status
    elif canonical_status == "infrastructure_fail":
        status = "infrastructure_fail"
    else:
        status = (
            "pass"
            if _gate_passed(summary, gate, args.truncated_rate_limit)
            else "fail"
        )
    passed = status == "pass"
    payload = {
        "schema": summary["schema"],
        "preset": args.preset,
        "candidate": candidate.agent_id,
        "baseline": baseline.agent_id,
        "games": summary["games"],
        "score_rate": summary["paired_statistics"]["score_rate"],
        "score_rate_ci": summary["paired_statistics"]["score_rate_ci"],
        "confidence_level": summary["paired_statistics"]["confidence_level"],
        "structural_errors": summary["integrity"]["structural_errors"],
        "truncated_rate": summary["integrity"]["truncated_rate"],
        "persistent_timeouts": summary["reliability"][
            "persistent_timeout_games"
        ],
        "performance_advisory": summary["performance_advisory"]["status"],
        "gate": gate,
        "status": status,
        "passed": passed,
        "output": str(output),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return {
        "pass": 0,
        "fail": 3,
        "inconclusive": 4,
        "infrastructure_fail": 5,
    }.get(status, 2)


if __name__ == "__main__":
    raise SystemExit(main())

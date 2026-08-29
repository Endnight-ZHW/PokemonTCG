from __future__ import annotations

import argparse
import json
import os
import sys
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
        choices=("smoke", "pr", "nightly", "release", "focused"),
        default="smoke",
    )
    parser.add_argument("--candidate", default="challenge_next")
    parser.add_argument("--baseline", default="challenge_release_v1")
    parser.add_argument(
        "--workers",
        type=int,
        default=max(1, min(8, os.cpu_count() or 1)),
    )
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--replicates", type=int)
    parser.add_argument("--max-decisions", type=int, default=512)
    parser.add_argument("--candidate-deck", action="append", default=[])
    parser.add_argument("--baseline-deck", action="append", default=[])
    parser.add_argument("--trace-all", action="store_true")
    parser.add_argument("--bootstrap-samples", type=int, default=2000)
    parser.add_argument("--truncated-rate-limit", type=float, default=0.01)
    parser.add_argument("--latency-ratio-limit", type=float, default=1.15)
    parser.add_argument("--max-candidate-p95-ms", type=float)
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
    )
    baseline = load_agent_spec(
        args.baseline,
        product_strategies=product_strategies,
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
        trace_all=args.trace_all,
        bootstrap_samples=args.bootstrap_samples,
        truncated_rate_limit=args.truncated_rate_limit,
        latency_ratio_limit=args.latency_ratio_limit,
        max_candidate_p95_ms=args.max_candidate_p95_ms,
    )
    summary = result["summary"]
    gate = _selected_gate(args.preset, args.gate)
    passed = _gate_passed(summary, gate, args.truncated_rate_limit)
    payload = {
        "schema": summary["schema"],
        "preset": args.preset,
        "candidate": candidate.agent_id,
        "baseline": baseline.agent_id,
        "games": summary["games"],
        "score_rate": summary["paired_statistics"]["score_rate"],
        "score_rate_ci95": summary["paired_statistics"]["score_rate_ci95"],
        "structural_errors": summary["integrity"]["structural_errors"],
        "truncated_rate": summary["integrity"]["truncated_rate"],
        "gate": gate,
        "passed": passed,
        "output": str(output),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if passed else 3


if __name__ == "__main__":
    raise SystemExit(main())

"""Warm, repeat and alternate a frozen public-request trace on two controllers."""
from __future__ import annotations

import argparse
import json
import math
import time
from collections import defaultdict
from pathlib import Path

from compare_challenge_decisions import (
    ExternalController, action_semantics, load_product_payloads, timing_summary,
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--allow-decision-changes", action="store_true",
                        help="Compare latency of a strategy change and report decision differences")
    args = parser.parse_args()
    if args.rounds < 3:
        parser.error("At least three measured rounds are required")
    requests = json.loads(args.trace.read_text(encoding="utf-8"))
    if not requests:
        parser.error("Trace must contain public decision requests")
    args.output.mkdir(parents=True, exist_ok=True)
    catalog, decks, _ = load_product_payloads()
    agents = []
    rounds = []
    divergences = 0
    examples = []
    try:
        for role in ("baseline", "candidate"):
            agents.append(ExternalController(getattr(args, role), catalog, decks, args.output / role))
        for round_index in range(args.rounds + 1):
            results = [[], []]
            elapsed = [[], []]
            diagnostics = [[], []]
            for version in ((0, 1) if round_index % 2 == 0 else (1, 0)):
                match_id = None
                for index, request in enumerate(requests):
                    if request["match_instance_id"] != match_id:
                        match_id = request["match_instance_id"]
                        agents[version].call("reset", match_id=match_id)
                    started = time.perf_counter()
                    result = agents[version].call("decide", request=request, generation=index + 1)
                    wall_ms = (time.perf_counter() - started) * 1000.0
                    if not result.get("success"):
                        raise RuntimeError(result)
                    elapsed[version].append(float(result.get("elapsed_ms", wall_ms)))
                    origin = ("choice" if request["kind"] == "choice" else "cache"
                              if result.get("turn_plan_cache_hit") or result.get("native_turn_plan_cache_hit")
                              else "search" if result.get("search_depth_applicable") else "simple")
                    diagnostics[version].append({"origin": origin, "wall_ms": wall_ms,
                        "nodes_expanded": result.get("nodes_expanded", 0),
                        "strategic_shadow_nodes": result.get("strategic_shadow_nodes", 0),
                        "completion_reason": result.get("strategic_completion_reason", result.get("completion_reason")),
                        "strategic_explanation": result.get("strategic_explanation", {}),
                        "strategic_plan_score": result.get("strategic_plan_score", {}),
                        "native_performance_counters": result.get("native_performance_counters", {})})
                    results[version].append(result["choice_response"] if request["kind"] == "choice"
                                            else action_semantics(result["action"]))
            changed = sum(left != right for left, right in zip(results[0], results[1]))
            if changed and not args.allow_decision_changes:
                raise AssertionError("Frozen trace produced different actions or choices")
            if round_index == 0:
                print("CHALLENGE_TIMING_WARMUP_OK", flush=True)
                continue
            divergences += changed
            samples = [{"index": index, "kind": request["kind"],
                        "deck": request.get("deck_key", ""),
                        "baseline": elapsed[0][index], "candidate": elapsed[1][index],
                        "diagnostics": {"baseline": diagnostics[0][index], "candidate": diagnostics[1][index]}}
                       for index, request in enumerate(requests)]
            if round_index == 1:
                examples = [{"index": index, "request": requests[index],
                    "baseline": left, "candidate": right,
                    "diagnostics": samples[index]["diagnostics"]}
                    for index, (left, right) in enumerate(zip(results[0], results[1])) if left != right]
            rounds.append({"round": round_index, "samples": samples, "summary": timing_summary(samples)})
            print("CHALLENGE_TIMING_ROUND_OK", round_index, flush=True)
    finally:
        for agent in agents:
            agent.close()
    report = {"schema": "ptcg.challenge_trace_timing/1", "workers": 1,
              "warmup_rounds": 1, "trace": str(args.trace.resolve()),
              "baseline_manifest": str(args.baseline.resolve()),
              "candidate_manifest": str(args.candidate.resolve()),
              "requests_per_round": len(requests), "rounds": rounds, "divergences": divergences}
    by_origin = {}
    for role in ("baseline", "candidate"):
        grouped = defaultdict(list)
        for measured in rounds:
            for row in measured["samples"]:
                grouped[row["diagnostics"][role]["origin"]].append(row[role])
        by_origin[role] = {origin: {"samples": len(values),
            "p50_ms": sorted(values)[len(values) // 2],
            "p95_ms": sorted(values)[math.ceil(len(values) * 0.95) - 1],
            "max_ms": max(values)} for origin, values in sorted(grouped.items())}
    report["latency_by_origin"] = by_origin
    report["decks"] = sorted({request.get("deck_key", "") for request in requests})
    (args.output / "decision-changes.json").write_text(json.dumps(examples, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("CHALLENGE_TRACE_TIMING_OK", flush=True)


if __name__ == "__main__":
    main()

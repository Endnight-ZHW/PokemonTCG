"""Replay public Challenge requests serially with paired time/worker settings.

The trace determines positions independently of candidate outcomes. Keep one
controller per seat and replay every request so plan and prize memory are real.
This is a latency/decision audit, not an Arena win-rate measurement.
"""
from __future__ import annotations

import argparse
import json
import math
import time
from collections import defaultdict
from pathlib import Path

from compare_challenge_decisions import ExternalController, action_semantics, load_product_payloads
from deep_ai.challenge_arena_build import sha256_file


def quantiles(values):
    values = sorted(values)
    return {"samples": len(values), **{
        name: values[min(len(values) - 1, math.ceil(len(values) * q) - 1)] if values else 0
        for name, q in (("p50_ms", .5), ("p95_ms", .95), ("p99_ms", .99), ("max_ms", 1))}}


def semantic_result(result, kind):
    if kind == "choice":
        return result["choice_response"]
    return {"action": action_semantics(result["action"]),
            "sequence": [action_semantics(a) for a in result.get("sequence", [])],
            "score_milli": result.get("score_milli"),
            "worst_score_milli": result.get("worst_score_milli")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--time-budget-ms", type=int, default=0)
    parser.add_argument("--search-workers", type=int, choices=(1, 3), default=1)
    parser.add_argument("--engine", choices=("turn_beam_v2", "strategic_intent_v3"))
    parser.add_argument("--assert-parity", action="store_true")
    args = parser.parse_args()
    if args.rounds < 1 or args.warmups < 0 or args.time_budget_ms < 0:
        parser.error("invalid measurement budget")
    catalog, decks, _ = load_product_payloads()
    requests = json.loads(args.trace.read_text(encoding="utf-8-sig"))
    args.output.mkdir(parents=True, exist_ok=True)
    timings = {role: defaultdict(list) for role in ("baseline", "candidate")}
    totals = {role: defaultdict(float) for role in timings}
    changed = set()
    with (args.output / "samples.jsonl").open("w", encoding="utf-8") as stream:
        for round_index in range(-args.warmups, args.rounds):
            controllers = {role: [ExternalController(getattr(args, role), catalog, decks,
                args.output / f"round-{round_index}" / role / str(actor)) for actor in (0, 1)]
                for role in timings}
            active_match = None
            try:
                for index, original in enumerate(requests):
                    request = {**original, "time_budget_ms": args.time_budget_ms,
                        "internal_evaluation_batch": args.search_workers == 1}
                    if args.engine:
                        request["engine"] = args.engine
                    if request["match_instance_id"] != active_match:
                        active_match = request["match_instance_id"]
                        for agents in controllers.values():
                            for agent in agents:
                                agent.call("reset", match_id=active_match)
                    results = {}
                    sample = {"round": round_index, "index": index, "kind": request["kind"],
                              "deck": request.get("deck_key"), "turn": request["state"].get("turn_number")}
                    order = ("baseline", "candidate") if (index + round_index) % 2 else ("candidate", "baseline")
                    for role in order:
                        started = time.perf_counter()
                        result = controllers[role][request["actor"]].call("decide", request=request,
                            generation=request["revision"] + 1)
                        wall_ms = (time.perf_counter() - started) * 1000
                        if not result.get("success"):
                            raise RuntimeError({"role": role, "index": index, "result": result})
                        if request["kind"] == "action" and action_semantics(result["action"]) not in [
                                action_semantics(a) for a in request["actions"]]:
                            raise AssertionError(f"illegal returned action: {role} {index}")
                        results[role] = result
                        origin = result["decision_origin"]
                        sample[role] = {"elapsed_ms": result["elapsed_ms"], "wall_ms": wall_ms,
                            "origin": origin, "nodes_expanded": result.get("nodes_expanded", 0),
                            "strategic_shadow_ms": result.get("strategic_shadow_ms", 0),
                            "strategic_probe_ms": result.get("strategic_probe_ms", 0),
                            "fallback_reason": result.get("strategic_fallback_reason", ""),
                            "counters": result.get("native_performance_counters", {})}
                        if round_index >= 0:
                            timings[role][origin].append(result["elapsed_ms"])
                            timings[role]["all"].append(result["elapsed_ms"])
                            timings[role]["wall"].append(wall_ms)
                            for key, value in sample[role]["counters"].items():
                                if isinstance(value, (int, float)) and not isinstance(value, bool):
                                    totals[role][key] += value
                    equal = semantic_result(results["baseline"], request["kind"]) == semantic_result(
                        results["candidate"], request["kind"])
                    sample["equal"] = equal
                    if not equal:
                        changed.add(index)
                        if args.assert_parity:
                            (args.output / "divergence.json").write_text(json.dumps(
                                {"request": request, **results}, ensure_ascii=False, indent=2), encoding="utf-8")
                            raise AssertionError(f"decision/score divergence at trace index {index}")
                    stream.write(json.dumps(sample, ensure_ascii=False) + "\n")
                    stream.flush()
                    if (index + 1) % 25 == 0:
                        print(f"TRACE_PROGRESS round={round_index} requests={index + 1}/{len(requests)}", flush=True)
            finally:
                for agents in controllers.values():
                    for agent in agents:
                        agent.close()
    summary = {"schema": "ptcg.challenge_efficiency_timing/1", "baseline": str(args.baseline.resolve()),
        "candidate": str(args.candidate.resolve()), "trace": str(args.trace.resolve()),
        "trace_sha256": sha256_file(args.trace), "requests": len(requests), "rounds": args.rounds,
        "warmups": args.warmups, "time_budget_ms": args.time_budget_ms,
        "search_workers": args.search_workers, "concurrent_games": 1, "changed_requests": sorted(changed),
        "timing": {role: {origin: quantiles(values) for origin, values in rows.items()}
                   for role, rows in timings.items()}, "work": totals}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("TRACE_BENCHMARK_OK", json.dumps(summary["timing"]), flush=True)


if __name__ == "__main__":
    main()

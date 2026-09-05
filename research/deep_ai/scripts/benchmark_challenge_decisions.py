"""Warm, repeat and alternate a frozen public-request trace on two controllers."""
from __future__ import annotations

import argparse
import json
import time
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
    try:
        for role in ("baseline", "candidate"):
            agents.append(ExternalController(getattr(args, role), catalog, decks, args.output / role))
        for round_index in range(args.rounds + 1):
            results = [[], []]
            elapsed = [[], []]
            for version in ((0, 1) if round_index % 2 == 0 else (1, 0)):
                agents[version].call("reset", match_id=requests[0]["match_instance_id"])
                for index, request in enumerate(requests):
                    started = time.perf_counter()
                    result = agents[version].call("decide", request=request, generation=index + 1)
                    wall_ms = (time.perf_counter() - started) * 1000.0
                    if not result.get("success"):
                        raise RuntimeError(result)
                    elapsed[version].append(float(result.get("elapsed_ms", wall_ms)))
                    results[version].append(result["choice_response"] if request["kind"] == "choice"
                                            else action_semantics(result["action"]))
            if results[0] != results[1]:
                raise AssertionError("Frozen trace produced different actions or choices")
            if round_index == 0:
                print("CHALLENGE_TIMING_WARMUP_OK", flush=True)
                continue
            samples = [{"index": index, "kind": request["kind"],
                        "baseline": elapsed[0][index], "candidate": elapsed[1][index]}
                       for index, request in enumerate(requests)]
            rounds.append({"round": round_index, "samples": samples, "summary": timing_summary(samples)})
            print("CHALLENGE_TIMING_ROUND_OK", round_index, flush=True)
    finally:
        for agent in agents:
            agent.close()
    report = {"schema": "ptcg.challenge_trace_timing/1", "workers": 1,
              "warmup_rounds": 1, "trace": str(args.trace.resolve()),
              "baseline_manifest": str(args.baseline.resolve()),
              "candidate_manifest": str(args.candidate.resolve()),
              "requests_per_round": len(requests), "rounds": rounds, "divergences": 0}
    (args.output / "summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("CHALLENGE_TRACE_TIMING_OK", flush=True)


if __name__ == "__main__":
    main()

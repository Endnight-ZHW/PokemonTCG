"""Measure the shared evaluator over 40,000 checked synthetic games."""
from __future__ import annotations

import argparse
import json
import random
import sys
import time
import tracemalloc
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "research/deep_ai/python"))
from deep_ai.evaluation_protocol import EvaluationProtocol, GameEvidence
from deep_ai.evaluation_statistics import EvaluationAccumulator
from deep_ai.evaluation_fairness import canonical_hash
from deep_ai.challenge_arena_build import write_json_atomic
from deep_ai.v3_contract import RELEASE_DECKS


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    protocol = EvaluationProtocol.create(
        backend="challenge", mode="promotion", decks=RELEASE_DECKS,
        participants={role: {"content_hash": canonical_hash(role)}
                      for role in ("candidate", "champion", "anchor")},
        context={"rules_hash": "synthetic", "decks_hash": "synthetic"})
    rng = random.Random(20260915)
    rounds = []
    for replicate in range(100):
        rows = []
        for task in protocol.tasks("ac", replicate):
            winner = rng.randrange(-1, 2)
            rows.append(GameEvidence.from_result(protocol, task, {
                **task.to_dict(), "winner_seat": winner, "success": True,
                "terminal": True, "truncated": False, "error": "", "decisions": 10,
                "final_state_hash": canonical_hash([task.task_id, winner]),
            }))
        rounds.append(rows)

    def summarize(incremental):
        accumulator = EvaluationAccumulator(protocol)
        for rows in rounds:
            for evidence in rows:
                accumulator.add(evidence)
            if incremental:
                accumulator.advance()
        report = accumulator.report(final=True)
        return {key: report[key] for key in ("record", "strength", "gate_status", "completed_rounds")}

    measurements, reports = {}, {}
    for name, incremental in (("single_summary", False), ("incremental_rounds", True)):
        started = time.perf_counter()
        reports[name] = summarize(incremental)
        elapsed = time.perf_counter() - started
        tracemalloc.start()
        summarize(incremental)
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        measurements[name] = {"seconds": elapsed, "peak_auxiliary_bytes": peak}
    payload = {
        "schema": "ptcg.ai_evaluation.benchmark/1", "games": 40000, "synthetic": True,
        "measurements": measurements,
        "reports_match": reports["single_summary"] == reports["incremental_rounds"],
        "report": reports["incremental_rounds"],
        "measurement_scope": "Shared evaluator only; checked input evidence and protocol allocation excluded from auxiliary memory.",
    }
    write_json_atomic(args.output, payload)
    print(json.dumps(payload))
    return 0 if payload["reports_match"] else 3


if __name__ == "__main__":
    raise SystemExit(main())

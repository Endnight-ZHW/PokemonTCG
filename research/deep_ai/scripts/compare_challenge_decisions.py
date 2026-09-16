"""Compare frozen/current agents on identical public requests and rules RNG.

Both agents receive every decision for their seat. Only the frozen result is
applied, so the first divergence cannot be hidden by later game outcomes.
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
import time
import math
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

RESEARCH_ROOT = Path(__file__).resolve().parents[1]
for directory in (RESEARCH_ROOT / "python", RESEARCH_ROOT / "build" / "native"):
    sys.path.insert(0, str(directory))

import ptcg_ai_core as native
from deep_ai.challenge_arena import load_product_payloads, product_engine_id
from deep_ai.challenge_audit import ExternalController, action_semantics, append_history, mix32
from engine.game_engine import _flatten_native_rows


def timing_summary(rows: list[dict]) -> dict:
    report = {}
    for role in ("baseline", "candidate"):
        samples = sorted(row[role] for row in rows)
        report[role] = {
            "samples": len(samples),
            "p50_ms": samples[len(samples) // 2] if samples else 0.0,
            "p95_ms": samples[math.ceil(len(samples) * 0.95) - 1] if samples else 0.0,
        }
    return report


def compare_game(index, keys, args, catalog, decks):
    directory = args.output / f"game-{index:02d}"
    own, other = keys[index % len(keys)], keys[(index + 1) % len(keys)]
    game_seed = 20260621 + index * 101
    match_id = f"parity:{args.engine}:{index}"
    expand = lambda key: [row["card_id"] for row in decks[key]["cards"] for _ in range(row["count"])]
    session = native.NativeRulesSession()
    created = session.create(catalog, [expand(own), expand(other)],
                             {"public_deck_keys": [own, other]}, game_seed)
    assert created["success"], created
    histories = [[], []]
    append_history(histories, created["events"])
    agents = []
    counts = Counter()
    nodes = [0, 0]
    history_requests = [[], []]
    coverage = set()
    timings = []
    try:
        for version, manifest in enumerate((args.baseline, args.candidate)):
            agents.append([])
            for seat in (0, 1):
                controller = ExternalController(manifest, catalog, decks, directory / f"{version}-{seat}")
                agents[version].append(controller)
                controller.call("reset", match_id=match_id)
        for step in range(512):
            state = session.snapshot()
            if state["result_status"] != "ONGOING":
                (directory / "timings.json").write_text(json.dumps(timings), encoding="utf-8")
                return {"index": index, "decks": [own, other], "decisions": sum(counts.values()),
                        "counts": dict(counts), "nodes": nodes, "winner": state["winner"],
                        "turns": state["turn_number"], "coverage": sorted(coverage),
                        "timing": timing_summary(timings)}
            pending = next((session.pending_choice(seat) for seat in (0, 1)
                            if session.pending_choice(seat)), None)
            actor = (pending["player"] if pending else state["pending_promotions"][0]
                     if state["pending_promotions"] else state["setup_actor_idx"]
                     if state["phase"] == "SETUP" else state["active_player_idx"])
            kind = "choice" if pending else "action"
            decision_seed = mix32(mix32(game_seed ^ 0x9E3779B9)
                                 ^ mix32(session.revision + 0x85EBCA6B)
                                 ^ mix32((actor + 1) * 0xC2B2AE35)
                                 ^ (0x27D4EB2F if pending else 0x165667B1)) or 17
            observation = session.ai_observation_for(actor)
            request = {"kind": kind, "actor": actor, "revision": session.revision,
                       "request_id": pending["request_id"] if pending else f"{match_id}:{session.revision}",
                       "state": observation, "public_snapshot": observation,
                       "public_history": histories[actor], "deck_key": [own, other][actor],
                       "match_seed": game_seed, "seed": decision_seed, "match_instance_id": match_id,
                       "engine": args.engine, "node_budget": 192, "belief_samples": 3,
                       "internal_evaluation_batch": True, "use_deck_inspection": True}
            if pending:
                request["choice"] = pending
            else:
                request["actions"] = _flatten_native_rows(session.legal_actions(actor))
                assert request["actions"], "empty authoritative actions"
            results = [None, None]
            measured = {"step": step, "kind": kind}
            order = (0, 1) if (step + index) % 2 == 0 else (1, 0)
            for version in order:
                started = time.perf_counter()
                results[version] = agents[version][actor].call("decide", request=request, generation=step + 1)
                wall_ms = (time.perf_counter() - started) * 1000.0
                role = "baseline" if version == 0 else "candidate"
                measured[role] = float(results[version].get("elapsed_ms", wall_ms))
                measured[role + "_wall_ms"] = wall_ms
            # Warm up each pair before including it in timing summaries.
            if step >= 5:
                timings.append(measured)
            counts[kind] += 1
            for version, result in enumerate(results):
                assert result.get("success"), (version, step, result)
                nodes[version] += result.get("nodes_expanded", 0)
            signatures = [(row["choice_response"] if pending else action_semantics(row["action"]))
                          for row in results]
            if signatures[0] != signatures[1]:
                (directory / "divergence.json").write_text(json.dumps(
                    {"request": request, "baseline": results[0], "candidate": results[1]},
                    ensure_ascii=False, indent=2), encoding="utf-8")
                raise AssertionError(f"decision divergence: game={index} step={step} kind={kind}")
            history_requests[actor].append(copy.deepcopy(request))
            current = results[1]
            tag = current["decision_origin"]
            coverage.add(tag)
            fixture = directory / f"{tag}.json"
            if not fixture.exists():
                fixture.write_text(json.dumps(history_requests[actor], ensure_ascii=False), encoding="utf-8")
            applied = (session.apply_choice(results[0]["choice_response"]) if pending else session.apply_action(
                {**results[0]["action"], "action_id": f"audit:{index}:{step}",
                 "base_revision": session.revision, "actor": actor}))
            assert applied["success"], applied
            append_history(histories, applied["events"])
        raise AssertionError(f"game {index} did not terminate within 512 decisions")
    finally:
        for rows in agents:
            for controller in rows:
                controller.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", choices=(product_engine_id(),), default=product_engine_id())
    parser.add_argument("--games", type=int, default=10)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    catalog, decks, _ = load_product_payloads()
    keys = json.loads((RESEARCH_ROOT.parents[1] / "godot/data/release_manifest.json").read_text(encoding="utf-8"))["release_decks"]
    games = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(compare_game, index, keys, args, catalog, decks) for index in range(args.games)]
        for future in as_completed(futures):
            game = future.result()
            games.append(game)
            print(json.dumps(game), flush=True)
    summary = {"engine": args.engine, "games": sorted(games, key=lambda row: row["index"]),
               "workers": args.workers, "timing_warmup_decisions_per_game": 5,
               "baseline_manifest": str(args.baseline.resolve()),
               "candidate_manifest": str(args.candidate.resolve()),
               "decisions_compared": sum(row["decisions"] for row in games), "divergences": 0,
               "baseline_nodes": sum(row["nodes"][0] for row in games),
               "candidate_nodes": sum(row["nodes"][1] for row in games)}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("CHALLENGE_DECISION_PARITY_OK", summary["decisions_compared"], flush=True)


if __name__ == "__main__":
    main()

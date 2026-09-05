"""Compare frozen/current agents on identical public requests and rules RNG.

Both agents receive every decision for their seat. Only the frozen result is
applied, so the first divergence cannot be hidden by later game outcomes.
"""
from __future__ import annotations

import argparse
import copy
import json
import queue
import subprocess
import sys
import threading
import time
import math
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

RESEARCH_ROOT = Path(__file__).resolve().parents[1]
for directory in (RESEARCH_ROOT / "python", RESEARCH_ROOT / "build" / "native"):
    sys.path.insert(0, str(directory))

import ptcg_ai_core as native
from deep_ai.challenge_arena import canonical_hash, load_product_payloads
from deep_ai.challenge_arena_build import load_and_verify_agent, sha256_file
from engine.game_engine import _flatten_native_rows


class ExternalController:
    def __init__(self, manifest: Path, catalog: dict, decks: dict, directory: Path):
        built = load_and_verify_agent(manifest)
        directory.mkdir(parents=True, exist_ok=True)
        config = {"strategies_path": built["strategies_path"]}
        for name, data in (("catalog", catalog), ("decks", decks)):
            path = directory / f"{name}.json"
            path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            config[f"{name}_path"] = str(path.resolve())
        for name in ("catalog", "decks", "strategies"):
            config[f"{name}_file_sha256"] = sha256_file(Path(config[f"{name}_path"]))
        config["strategies_hash"] = canonical_hash(json.loads(
            Path(config["strategies_path"]).read_text(encoding="utf-8")))
        path = directory / "config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        self.log = (directory / "stderr.log").open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [built["executable_path"], "--config", str(path.resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, encoding="utf-8",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.serial = 0
        self.responses = queue.Queue()
        threading.Thread(target=self._read_responses, daemon=True).start()
        ready = self._response()
        if not ready.get("success"):
            self.close()
            raise RuntimeError(ready)

    def _read_responses(self):
        for line in self.process.stdout:
            self.responses.put(line)
        self.responses.put("")

    def _response(self):
        try:
            line = self.responses.get(timeout=120)
        except queue.Empty as error:
            raise TimeoutError("Challenge audit agent exceeded its 120-second watchdog") from error
        if not line:
            raise RuntimeError("Challenge audit agent exited without a response")
        return json.loads(line)

    def call(self, op: str, **values):
        self.serial += 1
        self.process.stdin.write(json.dumps({
            "protocol": "ptcg.challenge_agent.ipc/1", "id": self.serial,
            "op": op, **values}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        response = self._response()
        if not response.get("success") or response.get("id") != self.serial:
            raise RuntimeError(response)
        return response.get("result", response)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)
        self.process.stdin.close()
        self.log.close()


def action_semantics(action: dict) -> dict:
    # Duplicate cards/attachments can have equal card IDs but distinct indices.
    # Keep their complete identity; only the submission token may differ.
    return {key: value for key, value in action.items() if key != "action_id"}


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


def append_history(histories: list[list], events: list):
    # Match the Arena's event normalization and owner/private projection.
    for raw in events:
        event = copy.deepcopy(raw)
        data = event.setdefault("data", {})
        actor = event.setdefault("actor", data.get("player", -1))
        for name in ("source", "target"):
            endpoint = event.setdefault(name, {})
            if endpoint.get("player", -1) < 0:
                endpoint["player"] = data.get(f"{name}_player", data.get("player", actor))
            endpoint.setdefault("zone", data.get(f"{name}_zone", ""))
            endpoint.setdefault("slot", data.get(f"{name}_slot",
                                "" if name == "source" else data.get("slot", "")))
            endpoint.setdefault("index", data.get(f"{name}_index", -1))
        event.setdefault("card_id", data.get("card_id", ""))
        private_draw = event.get("event_type") in ("cards_drawn", "cards_selected", "prize_taken")
        visibility = event.setdefault("visibility", data.get("visibility", "owner" if private_draw else "public"))
        owners = (event.get("visibility_owner"), data.get("visibility_owner"),
                  data.get("owner"), data.get("player"), event["source"].get("player"),
                  event["target"].get("player"), actor)
        owner = next((value for value in owners if value in (0, 1)), -1)
        if visibility != "public" and owner in (0, 1):
            data.setdefault("visibility_owner", owner)
        for viewer in (0, 1):
            if visibility == "private" and owner != viewer:
                continue
            projected = copy.deepcopy(event)
            if visibility == "owner" and owner != viewer:
                projected["card_id"] = ""
                for key in ("card_id", "source_card_id", "target_card_id"):
                    if key in projected["data"]:
                        projected["data"][key] = ""
                for key in ("card_ids", "cards", "selected_card_ids"):
                    if key in projected["data"]:
                        projected["data"][key] = []
                for key in ("source_index", "target_index"):
                    if key in projected["data"]:
                        projected["data"][key] = -1
                for name in ("source", "target"):
                    for key in ("card_id", "id"):
                        if key in projected[name]:
                            projected[name][key] = ""
                    projected[name]["index"] = -1
            histories[viewer].append(projected)
            histories[viewer][:] = histories[viewer][-4096:]


def mix32(value: int) -> int:
    value &= 0xFFFFFFFF
    value = ((value ^ (value >> 16)) * 0x7FEB352D) & 0xFFFFFFFF
    value = ((value ^ (value >> 15)) * 0x846CA68B) & 0xFFFFFFFF
    return value ^ (value >> 16)


def compare_game(index, keys, args, catalog, decks):
    directory = args.output / f"game-{index:02d}"
    own, other = keys[index % len(keys)], keys[(index + 1) % len(keys)]
    game_seed = 20260621 + index * 101
    match_id = f"simplification:{args.engine}:{index}"
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
                       "internal_evaluation_batch": True, "use_deck_inspection": True,
                       "use_strategy_optimization": True}
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
            tag = ("strategic_cache" if current.get("turn_plan_cache_hit")
                   and args.engine == "strategic_intent_v3" and not current.get("strategic_fallback")
                   else "strategic_override" if not current.get("strategic_fallback", True)
                   and not current.get("forced_tactic") else "")
            if tag:
                coverage.add(tag)
                fixture = directory / f"{tag}.json"
                if not fixture.exists():
                    fixture.write_text(json.dumps(history_requests[actor], ensure_ascii=False), encoding="utf-8")
            if current.get("strategic_fallback"):
                coverage.add("legacy_fallback")
            if current.get("turn_plan_cache_hit") and not current.get("strategic_fallback") and args.engine == "strategic_intent_v3":
                assert not current["strategic_shadow_legacy"] and current["strategic_shadow_nodes"] == 0
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
    parser.add_argument("--engine", choices=("turn_beam_v2", "strategic_intent_v3"), default="strategic_intent_v3")
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

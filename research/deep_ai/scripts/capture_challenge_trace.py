"""Capture public requests from a frozen agent for reproducible latency audits.

Five adjacent-deck matches cover all ten product decks. Stop at a predeclared
turn/decision limit; no outcome or candidate latency selects the positions.
These prefixes measure decisions, not win rate, so are not Arena strength rows.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

import sys
RESEARCH_ROOT = Path(__file__).resolve().parents[1]
for directory in (RESEARCH_ROOT / "python", RESEARCH_ROOT / "build/native"):
    sys.path.insert(0, str(directory))
import ptcg_ai_core as native
from engine.game_engine import _flatten_native_rows
from deep_ai.challenge_arena import load_product_payloads, product_engine_id
from deep_ai.challenge_audit import ExternalController, append_history, mix32
from deep_ai.challenge_arena_build import sha256_file


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=170101)
    parser.add_argument("--max-turn", type=int, default=8)
    parser.add_argument("--max-decisions", type=int, default=100)
    parser.add_argument("--snapshot-fixture", type=Path,
                        help="Resume one verified rules snapshot, for late-game latency coverage")
    parser.add_argument("--time-budget-ms", type=int, default=0)
    parser.add_argument("--search-workers", type=int, choices=(1, 3), default=1)
    args = parser.parse_args()
    catalog, decks, _ = load_product_payloads()
    keys = json.loads((RESEARCH_ROOT.parents[1] / "godot/data/release_manifest.json").read_text(encoding="utf-8"))["release_decks"]
    args.output.mkdir(parents=True, exist_ok=True)
    captured = []
    fixture = json.loads(args.snapshot_fixture.read_text(encoding="utf-8")) if args.snapshot_fixture else None
    pairs = [fixture["snapshot"]["public_deck_keys"]] if fixture else [keys[offset:offset + 2] for offset in range(0, len(keys), 2)]
    for game, pair in enumerate(pairs):
        if len(pair) != 2:
            raise ValueError("Trace capture requires an even product deck count")
        seed = args.seed + game * 104729
        match_id = f"latency-prefix-{seed}-{game}"
        expand = lambda key: [row["card_id"] for row in decks[key]["cards"] for _ in range(row["count"])]
        session = native.NativeRulesSession()
        if fixture:
            session.set_catalog(catalog)
            created = session.restore(fixture["snapshot"], fixture["rng_state"])
        else:
            created = session.create(catalog, [expand(key) for key in pair], {"public_deck_keys": pair}, seed)
        assert created["success"], created
        histories = [[], []]
        append_history(histories, created.get("events", []))
        requests = []
        agent = ExternalController(args.agent, catalog, decks, args.output / f"game-{game:02d}")
        try:
            agent.call("reset", match_id=match_id)
            for step in range(args.max_decisions):
                state = session.snapshot()
                if state["result_status"] != "ONGOING" or state["turn_number"] > args.max_turn:
                    break
                pending = next((session.pending_choice(seat) for seat in (0, 1) if session.pending_choice(seat)), None)
                actor = (pending["player"] if pending else state["pending_promotions"][0]
                    if state["pending_promotions"] else state["setup_actor_idx"]
                    if state["phase"] == "SETUP" else state["active_player_idx"])
                observation = session.ai_observation_for(actor)
                request = {"kind": "choice" if pending else "action", "actor": actor,
                    "revision": session.revision, "state": observation, "public_snapshot": observation,
                    "request_id": pending["request_id"] if pending else f"{match_id}:{session.revision}",
                    "public_history": copy.deepcopy(histories[actor]), "deck_key": pair[actor],
                    "match_seed": seed, "seed": mix32(seed ^ session.revision ^ actor) or 17,
                    "match_instance_id": match_id, "engine": product_engine_id(), "node_budget": 192,
                    "belief_samples": 3, "internal_evaluation_batch": args.search_workers == 1,
                    "time_budget_ms": args.time_budget_ms,
                    "use_deck_inspection": True}
                request.update({"choice": pending} if pending else {"actions": _flatten_native_rows(session.legal_actions(actor))})
                result = agent.call("decide", request=request, generation=step + 1)
                assert result.get("success"), result
                requests.append(request)
                applied = session.apply_choice(result["choice_response"]) if pending else session.apply_action(
                    {**result["action"], "action_id": f"capture:{game}:{step}"})
                assert applied["success"], applied
                append_history(histories, applied["events"])
        finally:
            agent.close()
        captured.extend(requests)
        (args.output / f"game-{game:02d}.json").write_text(json.dumps(requests, ensure_ascii=False), encoding="utf-8")
        print(json.dumps({"game": game, "decks": pair, "requests": len(requests)}), flush=True)
    (args.output / "requests.json").write_text(json.dumps(captured, ensure_ascii=False), encoding="utf-8")
    (args.output / "capture-manifest.json").write_text(json.dumps({
        "schema": "ptcg.challenge_trace_capture/1", "agent_manifest": str(args.agent.resolve()),
        "seed": args.seed, "max_turn": args.max_turn, "max_decisions": args.max_decisions,
        "requests": len(captured), "decks": keys, "pairs": pairs,
        "snapshot_fixture": str(args.snapshot_fixture) if args.snapshot_fixture else None,
        "snapshot_fixture_sha256": sha256_file(args.snapshot_fixture) if args.snapshot_fixture else None,
        "time_budget_ms": args.time_budget_ms, "search_workers": args.search_workers}, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()

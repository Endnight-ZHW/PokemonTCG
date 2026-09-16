"""Public-request auditing utilities, including frozen external-agent adaptation.

Historical engine negotiation is confined to this evaluation adapter. Product
controllers keep their single-engine contract.
"""
from __future__ import annotations

import copy
import json
import queue
import subprocess
import threading
from pathlib import Path

from .challenge_arena import canonical_hash
from .challenge_arena_build import load_and_verify_agent, sha256_file


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
        self.reader = threading.Thread(target=self._read_responses, daemon=True)
        self.reader.start()
        try:
            ready = self._response()
            self.contract = ready.get("contract", {})
            if not ready.get("success"):
                raise RuntimeError(ready)
        except BaseException:
            self.close()
            raise

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
        if op == "decide" and "request" in values:
            # A trace records observations, not the implementation's engine id.
            supported = self.contract.get("supported_engines", [])
            requested = values["request"].get("engine")
            if supported and requested not in supported:
                preferred = next((engine for engine in ("deck_planner_v1", "strategic_intent_v3", "turn_beam_v2")
                                  if engine in supported), self.contract.get("engine_id"))
                values["request"] = {**values["request"], "engine": preferred}
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
        self.reader.join(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def action_semantics(action: dict) -> dict:
    # Duplicate cards/attachments can have equal card IDs but distinct indices.
    # Keep their complete identity; only the submission token may differ.
    return {key: value for key, value in action.items() if key != "action_id"}


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


def decision_metadata(result: dict) -> dict:
    """Normalize only fields consumed by current audit reports."""
    origin = result.get("decision_origin")
    if not origin:
        origin = ("cache" if result.get("turn_plan_cache_hit") else
                  "forced_tactic" if result.get("forced_tactic") else
                  "choice_policy" if result.get("kind") == "choice" else "search")
    return {"origin": origin, "engine_id": result.get("engine_id", ""),
            "policy_id": result.get("policy_id", ""), "turn_goal": result.get("turn_goal", ""),
            "plan_reason": result.get("plan_reason", ""),
            "completion_reason": result.get("completion_reason", result.get("strategic_completion_reason", "")),
            "nodes_expanded": result.get("nodes_expanded", 0),
            "cache_hit": bool(result.get("turn_plan_cache_hit")),
            "counters": result.get("native_performance_counters", {})}

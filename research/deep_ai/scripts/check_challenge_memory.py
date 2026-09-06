"""Replay real lifetime regressions against a standalone (optionally ASan) agent."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

RESEARCH = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RESEARCH / "python"))

from deep_ai.challenge_arena import canonical_hash, load_product_payloads
from deep_ai.challenge_arena_build import sha256_file, write_json_atomic


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    catalog, decks, strategies = load_product_payloads()
    config = {"strategies_hash": canonical_hash(strategies)}
    for name, value in (("catalog", catalog), ("decks", decks), ("strategies", strategies)):
        path = args.output / f"{name}.json"
        write_json_atomic(path, value)
        config[f"{name}_path"] = str(path.resolve())
        config[f"{name}_file_sha256"] = sha256_file(path)
    config_path = args.output / "config.json"
    write_json_atomic(config_path, config)
    fixtures = RESEARCH.parents[1] / "native/challenge_core/tests/fixtures"
    paths = [fixtures / name for name in ("legacy_replay_lifetime.json", "mandatory_attack_lifetime.json")]
    requests = [json.loads(path.read_text(encoding="utf-8"))["request"] for path in paths]
    commands = []
    for request in requests:
        commands.extend([
            {"op": "reset", "match_id": request["match_instance_id"]},
            {"op": "decide", "request": request, "generation": request["revision"] + 1},
        ])
    commands.append({"op": "shutdown"})
    wire = "".join(json.dumps({"protocol": "ptcg.challenge_agent.ipc/1", "id": index, **command},
                            ensure_ascii=False) + "\n" for index, command in enumerate(commands, 1))
    # communicate drains stdout and stderr while waiting; no pipe can fill and
    # hide a sanitizer failure. ASan is deliberately slower than release builds.
    result = subprocess.run([str(args.executable.resolve()), "--config", str(config_path.resolve())],
        input=wire, capture_output=True, text=True, encoding="utf-8", timeout=600,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        env={**os.environ, "ASAN_OPTIONS": "halt_on_error=1"})
    (args.output / "stdout.jsonl").write_text(result.stdout, encoding="utf-8")
    (args.output / "stderr.log").write_text(result.stderr, encoding="utf-8")
    if result.returncode or "ERROR: AddressSanitizer" in result.stderr:
        raise RuntimeError(f"memory_regression_failed:{result.returncode}; see {args.output / 'stderr.log'}")
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    if len(responses) != len(commands) + 1 or not all(row.get("success") for row in responses):
        raise RuntimeError("memory_regression_incomplete_or_failed_response")
    for index, row in enumerate(responses[1:], 1):
        if row.get("id") != index:
            raise RuntimeError("memory_regression_response_id_mismatch")
    semantics = lambda action: {key: value for key, value in action.items() if key != "action_id"}
    for index, request in enumerate(requests):
        decision = responses[2 + index * 2]["result"]
        if not decision.get("success") or semantics(decision["action"]) not in [
                semantics(action) for action in request["actions"]]:
            raise RuntimeError("memory_regression_illegal_decision")
        if not decision.get("strategic_shadow_legacy") or decision.get("strategic_shadow_nodes", 0) <= 0:
            raise RuntimeError("memory_regression_did_not_exercise_legacy_path")
    write_json_atomic(args.output / "summary.json", {"status": "pass", "cases": len(requests),
        "executable_sha256": sha256_file(args.executable), "stderr_empty": not result.stderr,
        "fixtures": [{"name": path.name, "sha256": sha256_file(path)} for path in paths]})
    print("CHALLENGE_MEMORY_REGRESSION_OK", len(requests), flush=True)


if __name__ == "__main__":
    main()

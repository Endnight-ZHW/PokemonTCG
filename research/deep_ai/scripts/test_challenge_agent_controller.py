"""Run the real controller regressions against a frozen external native agent.

The supplied research binding provides only the authoritative rules sessions;
every AI decision, cancellation and continuation is sent to the frozen agent.
This allows an isolated candidate to be checked while another Arena cohort
continues using its existing binding and immutable agent artifacts.
"""
from __future__ import annotations

import argparse
import json
import sys
import unittest
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--rules-binding", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test", action="append", default=[])
    args = parser.parse_args()
    research = Path(__file__).resolve().parents[1]
    sys.path[:0] = [str(args.rules_binding.resolve()), str(research / "python"), str(research / "tests")]
    from compare_challenge_decisions import ExternalController
    from deep_ai.challenge_arena_build import load_and_verify_agent
    from test_challenge_controller import ChallengeControllerTests

    manifest = load_and_verify_agent(args.manifest)
    args.output.mkdir(parents=True, exist_ok=True)
    serial = 0

    class Controller:
        def __init__(self, external):
            self.external = external

        def decide(self, request, generation):
            return self.external.call("decide", request=request, generation=generation)

        def cancel(self, generation):
            return self.external.call("cancel", generation=generation)

        def reset_match(self, match_id):
            return self.external.call("reset", match_id=match_id)

    class AgentControllerTests(ChallengeControllerTests):
        def make_controller(self):
            nonlocal serial
            serial += 1
            external = ExternalController(args.manifest, self.catalog, self.decks,
                args.output / "controllers" / str(serial))
            self.addCleanup(external.close)
            controller = Controller(external)
            controller.reset_match("controller-test")
            return controller

    suite = (unittest.TestSuite(AgentControllerTests(name) for name in args.test)
        if args.test else unittest.defaultTestLoader.loadTestsFromTestCase(AgentControllerTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    summary = {"manifest": str(args.manifest.resolve()), "implementation_hash": manifest["implementation_hash"],
        "tests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
        "skipped": len(result.skipped), "success": result.wasSuccessful() and not result.skipped,
        "rules_binding_directory": str(args.rules_binding.resolve()),
        "scope": "frozen native AI over IPC, authoritative rules binding; no neural inference"}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

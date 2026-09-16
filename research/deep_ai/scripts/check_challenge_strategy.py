"""Check all decks against the strongest prior result on the same anchor schedule."""
from pathlib import Path
import argparse
import json
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from deep_ai.evaluation_protection import protect_anchor_scores
from deep_ai.challenge_arena_build import write_json_atomic


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-run", required=True, type=Path)
    parser.add_argument("--protect-run", required=True, action="append", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = protect_anchor_scores(args.candidate_run, args.protect_run)
    write_json_atomic(args.output, result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["gate_status"] == "pass" else 3


if __name__ == "__main__":
    raise SystemExit(main())

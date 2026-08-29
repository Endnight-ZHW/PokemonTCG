from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
PYTHON_ROOT = RESEARCH_ROOT / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from deep_ai.challenge_arena_build import (  # noqa: E402
    agent_input_manifest,
    load_and_verify_agent,
    load_and_verify_binding,
    write_agent_sidecar,
    write_binding_sidecar,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    agent_input = subparsers.add_parser("agent-input")
    agent_input.add_argument("--repo-root", type=Path, required=True)
    agent_input.add_argument("--source-root", type=Path, required=True)
    agent_input.add_argument("--compiler", default="")
    binding_write = subparsers.add_parser("write-binding")
    binding_write.add_argument("--repo-root", type=Path, required=True)
    binding_write.add_argument("--binding", type=Path, required=True)
    binding_write.add_argument("--output", type=Path, required=True)
    binding_write.add_argument("--compiler", default="")
    binding_verify = subparsers.add_parser("verify-binding")
    binding_verify.add_argument("--repo-root", type=Path, required=True)
    binding_verify.add_argument("--binding", type=Path, required=True)
    binding_verify.add_argument("--sidecar", type=Path, required=True)
    agent_write = subparsers.add_parser("write-agent")
    agent_write.add_argument("--repo-root", type=Path, required=True)
    agent_write.add_argument("--source-root", type=Path, required=True)
    agent_write.add_argument("--executable", type=Path, required=True)
    agent_write.add_argument("--strategies", type=Path, required=True)
    agent_write.add_argument("--output", type=Path, required=True)
    agent_write.add_argument("--git-ref", required=True)
    agent_write.add_argument("--build-id", required=True)
    agent_write.add_argument("--compiler", default="")
    agent_verify = subparsers.add_parser("verify-agent")
    agent_verify.add_argument("--sidecar", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "agent-input":
        value = agent_input_manifest(
            args.repo_root, args.source_root, compiler=args.compiler
        )
    elif args.command == "write-binding":
        value = write_binding_sidecar(
            args.repo_root,
            args.binding,
            args.output,
            compiler=args.compiler,
        )
    elif args.command == "verify-binding":
        value = load_and_verify_binding(args.repo_root, args.binding, args.sidecar)
    elif args.command == "write-agent":
        value = write_agent_sidecar(
            args.repo_root,
            args.source_root,
            args.executable,
            args.strategies,
            args.output,
            git_ref=args.git_ref,
            build_id=args.build_id,
            compiler=args.compiler,
        )
    else:
        value = load_and_verify_agent(args.sidecar)
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

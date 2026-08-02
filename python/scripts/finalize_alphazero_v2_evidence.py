"""Finalize the fail-closed AlphaZero v2 release evidence bundle."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.release_evidence_v2 import (  # noqa: E402
    finalize_release_evidence,
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--rules-parity", type=Path, required=True)
    parser.add_argument("--infoset-security", type=Path, required=True)
    parser.add_argument("--performance", type=Path, required=True)
    parser.add_argument("--windows-runtime", type=Path, required=True)
    parser.add_argument("--android-runtime", type=Path, required=True)
    args = parser.parse_args(argv)
    result = finalize_release_evidence(
        args.run_dir,
        inputs={
            "rules_parity": args.rules_parity,
            "infoset_security": args.infoset_security,
            "performance": args.performance,
            "windows_runtime": args.windows_runtime,
            "android_runtime": args.android_runtime,
        },
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

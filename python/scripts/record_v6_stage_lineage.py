"""Attach hash-verified v6 research evidence to a completed child run."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.run_store import (  # noqa: E402
    read_json,
    sha256_file,
    update_run,
    utc_now,
)


def record_lineage(
    run_dir: Path,
    evidence_path: Path,
    *,
    kind: str,
) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    evidence_path = evidence_path.resolve()
    run = read_json(run_dir / "run.json")
    evidence = json.loads(evidence_path.read_text(encoding="utf-8-sig"))
    run_config = dict(run.get("config") or {})
    variant = str(run_config.get("model_variant", ""))
    if kind == "ablation":
        if (
            str(run.get("preset", "")) != "research10"
            or str(evidence.get("schema", "")) != "deep_ai_v6_ablation_v1"
            or str(evidence.get("winner", "")) != variant
            or bool(evidence.get("promotable"))
            or bool(evidence.get("release_manifest_modified"))
        ):
            raise RuntimeError(
                "Ablation evidence does not match this research10 run"
            )
    elif kind == "research10_gate":
        evidence_run = dict(evidence.get("run") or {})
        if (
            str(run.get("preset", "")) != "release"
            or str(evidence.get("schema", ""))
            != "deep_ai_v6_research10_gate_v1"
            or not bool(evidence.get("valid"))
            or bool(evidence.get("promotable"))
            or str(evidence_run.get("model_variant", "")) != variant
        ):
            raise RuntimeError(
                "research10 gate evidence does not match this release run"
            )
    else:
        raise ValueError(f"Unknown lineage kind: {kind}")

    lineage = dict(run.get("stage_lineage") or {})
    lineage[kind] = {
        "kind": kind,
        "path": str(evidence_path),
        "sha256": sha256_file(evidence_path),
        "model_variant": variant,
        "recorded_at": utc_now(),
    }
    update_run(run_dir, stage_lineage=lineage)
    return lineage[kind]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument(
        "--kind",
        choices=["ablation", "research10_gate"],
        required=True,
    )
    args = parser.parse_args()
    result = record_lineage(
        args.run_dir,
        args.evidence,
        kind=args.kind,
    )
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Merge Godot AI-evaluation shards into one authoritative schema-v7 result."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

try:
    from scripts.build_ai_evaluation_provenance import current_analysis_provenance
except ModuleNotFoundError:  # Direct ``python python/scripts/...`` execution.
    from build_ai_evaluation_provenance import current_analysis_provenance

try:
    from scripts.ai_evaluation_v7 import (
        MergeError,
        PROTOCOL_ID,
        SCHEMA_VERSION,
        experimental_units,
        merge_payloads,
        summarize_strength,
    )
except ModuleNotFoundError:  # Direct ``python python/scripts/...`` execution.
    from ai_evaluation_v7 import (  # type: ignore[no-redef]
        MergeError,
        PROTOCOL_ID,
        SCHEMA_VERSION,
        experimental_units,
        merge_payloads,
        summarize_strength,
    )


def _summarize_role_crossover(matches: list[dict[str, Any]]) -> dict[str, Any]:
    """Compatibility helper for focused tests; v7's canonical field is strength."""
    _, cross_units = experimental_units(matches)
    strength = summarize_strength([], cross_units)["cross_role"]
    return {
        "method": strength["method"],
        "overall": {
            "blocks": strength["all_units"],
            "complete_blocks": strength["complete_units"],
            "clean_blocks": strength["clean_units"],
            "role_balanced": strength["complete_units"] == strength["all_units"],
            "role_crossover_adjusted_point_rate": strength["overall"]["point_rate"],
            "role_crossover_adjusted_point_delta": strength["overall"]["point_delta"],
        },
        "per_unordered_matchup": strength["per_unordered_matchup"],
    }


def merge_files(
    input_paths: Sequence[Path],
    output_path: Path,
    *,
    workers: int = 1,
    search_depth_input_paths: Sequence[Path] | None = None,
    wall_clock_ms: float | None = None,
    wall_clock_scope: str | None = None,
) -> dict[str, Any]:
    shards = [json.loads(path.read_text(encoding="utf-8-sig")) for path in input_paths]
    search_depth_shards = (
        [json.loads(path.read_text(encoding="utf-8-sig")) for path in search_depth_input_paths]
        if search_depth_input_paths
        else None
    )
    payload = merge_payloads(
        shards,
        workers=max(1, int(workers)),
        search_depth_shards=search_depth_shards,
        analysis_provenance=current_analysis_provenance(
            Path(__file__).resolve().parents[2]
        ),
        wall_clock_ms=wall_clock_ms,
        wall_clock_scope=wall_clock_scope,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload


def _write_error(path: Path | None, error: str) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "protocol_id": PROTOCOL_ID,
                "artifact_kind": "ai_evaluation_merge_error",
                "valid": False,
                "error": error,
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", required=True, type=Path)
    parser.add_argument(
        "--search-depth-input",
        "--performance-input",
        dest="search_depth_input",
        action="append",
        type=Path,
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--error-output", type=Path)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument(
        "--wall-clock-ms",
        type=float,
        help="Measured wall time of the main evidence stage (diagnostic only).",
    )
    parser.add_argument(
        "--wall-clock-scope",
        choices=("full_evidence_stage", "current_attempt_only"),
        help=(
            "Explicit scope for --wall-clock-ms. If omitted, the merge "
            "infers a safe scope from checkpoint restoration."
        ),
    )
    args = parser.parse_args()
    try:
        payload = merge_files(
            args.input,
            args.output,
            workers=max(1, args.workers),
            search_depth_input_paths=args.search_depth_input,
            wall_clock_ms=args.wall_clock_ms,
            wall_clock_scope=args.wall_clock_scope,
        )
    except (MergeError, OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        error = str(exc)
        _write_error(args.error_output, error)
        print(json.dumps({"valid": False, "error": error}, ensure_ascii=False))
        return 1
    print(
        json.dumps(
            {
                "valid": True,
                "output": str(args.output),
                "games": payload["observed"]["games"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

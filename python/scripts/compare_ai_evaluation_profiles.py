"""Compare two schema-v3 AI evaluation results for equivalence and profile deltas."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _match_signature(payload: dict[str, Any]) -> list[tuple[Any, ...]]:
    rows = []
    for row in payload.get("matches") or []:
        rows.append((
            str(row.get("pair_key") or ""),
            int(row.get("seat") or 0),
            str(row.get("winner") or ""),
            str(row.get("terminal_reason") or ""),
            int(row.get("actions") or 0),
        ))
    return sorted(rows)


def _ratio(candidate: float, baseline: float) -> float | None:
    if baseline <= 0.0:
        return None
    return round(candidate / baseline, 4)


def compare_profiles(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    baseline_segments = (baseline.get("performance_profile") or {}).get("segments_ms") or {}
    candidate_segments = (candidate.get("performance_profile") or {}).get("segments_ms") or {}
    segment_keys = sorted(set(baseline_segments) | set(candidate_segments))
    segments = {}
    for key in segment_keys:
        before = _float(baseline_segments.get(key))
        after = _float(candidate_segments.get(key))
        segments[key] = {
            "baseline_ms": round(before, 3),
            "candidate_ms": round(after, 3),
            "ratio": _ratio(after, before),
            "delta_ms": round(after - before, 3),
        }
    baseline_elapsed = _float(baseline.get("elapsed_ms"))
    candidate_elapsed = _float(candidate.get("elapsed_ms"))
    return {
        "same_match_results": _match_signature(baseline) == _match_signature(candidate),
        "baseline_games": int((baseline.get("summary") or {}).get("games") or 0),
        "candidate_games": int((candidate.get("summary") or {}).get("games") or 0),
        "elapsed_ms": {
            "baseline": round(baseline_elapsed, 3),
            "candidate": round(candidate_elapsed, 3),
            "ratio": _ratio(candidate_elapsed, baseline_elapsed),
            "delta_ms": round(candidate_elapsed - baseline_elapsed, 3),
        },
        "segments": segments,
    }


def render_text(comparison: dict[str, Any]) -> str:
    elapsed = comparison["elapsed_ms"]
    lines = [
        f"same_match_results={str(comparison['same_match_results']).lower()}",
        (
            "elapsed_ms: "
            f"baseline={elapsed['baseline']:.3f} "
            f"candidate={elapsed['candidate']:.3f} "
            f"ratio={elapsed['ratio']}"
        ),
        "segments:",
    ]
    ordered = sorted(
        comparison["segments"].items(),
        key=lambda item: abs(_float(item[1].get("delta_ms"))),
        reverse=True,
    )
    for key, row in ordered[:12]:
        lines.append(
            f"- {key}: baseline={row['baseline_ms']:.3f} candidate={row['candidate_ms']:.3f} ratio={row['ratio']}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    candidate = json.loads(args.candidate.read_text(encoding="utf-8"))
    comparison = compare_profiles(baseline, candidate)
    if args.json:
        print(json.dumps(comparison, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_text(comparison))
    return 0 if comparison["same_match_results"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

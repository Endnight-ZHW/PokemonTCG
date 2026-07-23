"""Summarize authoritative schema-v5 AI evaluation performance profile data."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


SEGMENT_HINTS = {
    "ai_determinize_ms": "GameState.from_dict / hidden-information determinization / deck expansion",
    "ai_rollout_apply_action_ms": "GameEngine.apply_action and VM settlement hot path",
    "ai_rollout_legal_actions_ms": "GameEngine.legal_actions and VMActionAvailability",
    "ai_rollout_heuristic_action_ms": "Challenge AI heuristic scoring",
    "ai_rollout_evaluate_ms": "Challenge AI board evaluation / ChallengeAIMath native aggregation",
    "ai_request_context_ms": "AI request deserialization and cached catalog/engine access",
    "runner_legal_actions_ms": "top-level legal action generation",
    "runner_decide_action_wall_ms": "end-to-end Challenge AI decision wall time",
    "runner_apply_action_ms": "top-level rule application",
    "runner_setup_game_ms": "deck expansion, shuffle, mulligan setup",
}


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _hint_for_segment(segment: str) -> str:
    if segment in SEGMENT_HINTS:
        return SEGMENT_HINTS[segment]
    if "legal_actions" in segment:
        return "legal action generation"
    if "apply" in segment:
        return "rule application / settlement"
    if "heuristic" in segment or "score" in segment or "evaluate" in segment:
        return "heuristic scoring / board evaluation"
    if "determinize" in segment or "context" in segment:
        return "state clone / snapshot / determinization"
    return "inspect after profile confirms this remains hot"


def summarize_profile(payload: dict[str, Any], *, top: int = 12) -> dict[str, Any]:
    if int(payload.get("schema_version") or 0) != 5:
        return {
            "enabled": False,
            "error": "schema_v5_required",
            "top_segments": [],
            "counts": {},
        }
    profile = payload.get("performance_profile") or {}
    if not profile.get("enabled"):
        return {
            "enabled": False,
            "error": "performance_profile_not_enabled",
            "top_segments": [],
            "counts": {},
        }
    segments = {
        str(key): _float(value)
        for key, value in (profile.get("segments_ms") or {}).items()
    }
    counts = {
        str(key): _int(value)
        for key, value in (profile.get("counts") or {}).items()
    }
    ordered = sorted(segments.items(), key=lambda item: (-item[1], item[0]))[: max(1, top)]
    return {
        "enabled": True,
        "games": _int((payload.get("observed") or {}).get("games")),
        "decisions": counts.get("decisions", 0),
        "simulations": counts.get("ai_simulations", 0),
        "top_segments": [
            {
                "segment": key,
                "ms": round(value, 3),
                "candidate": _hint_for_segment(key),
            }
            for key, value in ordered
        ],
        "counts": counts,
    }


def render_text(summary: dict[str, Any]) -> str:
    if not summary.get("enabled"):
        return "performance_profile_not_enabled"
    lines = [
        f"games={summary.get('games', 0)} decisions={summary.get('decisions', 0)} simulations={summary.get('simulations', 0)}",
        "top_segments:",
    ]
    for row in summary.get("top_segments") or []:
        lines.append(
            f"- {row['segment']}: {row['ms']:.3f} ms | {row['candidate']}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--top", type=int, default=12)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    payload = json.loads(args.input.read_text(encoding="utf-8"))
    summary = summarize_profile(payload, top=max(1, args.top))
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_text(summary))
    return 0 if summary.get("enabled") else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Merge parallel Godot traditional-AI evaluation shards into one schema-v2 result."""
from __future__ import annotations

import argparse
import json
import random
import time
import zlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 2
BOOTSTRAP_ITERATIONS = 400
BOOTSTRAP_SEED = 90210
DECK_ORDER = [
    "colorless",
    "darkness",
    "dragon",
    "fighting",
    "fire",
    "grass",
    "lightning",
    "psychic",
    "steel",
    "water",
]


class MergeError(ValueError):
    pass


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


def _round(value: float, digits: int = 4) -> float:
    return round(float(value), digits)


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    index = int(max(0.0, min(1.0, pct)) * (len(ordered) - 1))
    return ordered[index]


def _ci(values: list[float]) -> dict[str, Any]:
    return {
        "lower": _round(_percentile(values, 0.025), 4),
        "upper": _round(_percentile(values, 0.975), 4),
        "samples": len(values),
    }


def _match_point(row: dict[str, Any]) -> float:
    winner = str(row.get("winner") or "draw")
    if winner == "A":
        return 1.0
    if winner == "B":
        return 0.0
    return 0.5


def _is_clean_match(row: dict[str, Any]) -> bool:
    return (
        str(row.get("terminal_reason") or "") == "game_over"
        and _int(row.get("invalid_actions")) == 0
        and _int(row.get("choice_failures")) == 0
        and _int(row.get("rule_exceptions")) == 0
        and not bool(row.get("max_actions_exhausted"))
    )


def _empty_stats() -> dict[str, Any]:
    return {
        "games": 0,
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "completed_games": 0,
        "clean_games": 0,
        "clean_wins": 0,
        "clean_losses": 0,
        "clean_draws": 0,
        "score_total": 0.0,
        "actions": 0,
        "turns": 0,
        "decisions": 0,
        "choices": 0,
        "decision_ms_total": 0.0,
        "decision_ms_values": [],
        "invalid_actions": 0,
        "choice_failures": 0,
        "rule_exceptions": 0,
        "time_capped_decisions": 0,
        "max_actions_exhaustions": 0,
    }


def _merge_match(stats: dict[str, Any], row: dict[str, Any]) -> None:
    stats["games"] += 1
    winner = str(row.get("winner") or "draw")
    if winner == "A":
        stats["wins"] += 1
    elif winner == "B":
        stats["losses"] += 1
    else:
        stats["draws"] += 1

    if str(row.get("terminal_reason") or "") == "game_over":
        stats["completed_games"] += 1
    if _is_clean_match(row):
        stats["clean_games"] += 1
        if winner == "A":
            stats["clean_wins"] += 1
        elif winner == "B":
            stats["clean_losses"] += 1
        else:
            stats["clean_draws"] += 1

    decisions = _int(row.get("decisions"))
    choices = _int(row.get("choices"))
    average_ms = _float(row.get("average_decision_ms"))
    stats["score_total"] += _float(row.get("score"))
    stats["actions"] += _int(row.get("actions"))
    stats["turns"] += _int(row.get("turns"))
    stats["decisions"] += decisions
    stats["choices"] += choices
    stats["decision_ms_total"] += average_ms * max(1, decisions + choices)
    stats["decision_ms_values"].append(average_ms)
    stats["invalid_actions"] += _int(row.get("invalid_actions"))
    stats["choice_failures"] += _int(row.get("choice_failures"))
    stats["rule_exceptions"] += _int(row.get("rule_exceptions"))
    stats["time_capped_decisions"] += _int(row.get("time_capped_decisions"))
    if bool(row.get("max_actions_exhausted")):
        stats["max_actions_exhaustions"] += 1


def _elo_delta(point_rate: float) -> float:
    clamped = max(0.001, min(0.999, float(point_rate)))
    return 400.0 * __import__("math").log10(clamped / (1.0 - clamped))


def _finalize_stats(stats: dict[str, Any]) -> dict[str, Any]:
    games = max(1, _int(stats.get("games")))
    decisions_and_choices = max(1, _int(stats.get("decisions")) + _int(stats.get("choices")))
    decisions = max(1, _int(stats.get("decisions")))
    point_rate = (_float(stats.get("wins")) + _float(stats.get("draws")) * 0.5) / games
    clean_games = _int(stats.get("clean_games"))
    clean_point_rate = 0.0
    if clean_games > 0:
        clean_point_rate = (
            _float(stats.get("clean_wins")) + _float(stats.get("clean_draws")) * 0.5
        ) / clean_games
    result = dict(stats)
    result["win_rate"] = _round(_float(stats.get("wins")) / games, 4)
    result["draw_rate"] = _round(_float(stats.get("draws")) / games, 4)
    result["point_rate"] = _round(point_rate, 4)
    result["completion_rate"] = _round(_float(stats.get("completed_games")) / games, 4)
    result["max_action_exhaustion_rate"] = _round(_float(stats.get("max_actions_exhaustions")) / games, 4)
    result["clean_point_rate"] = _round(clean_point_rate, 4)
    result["average_score"] = _round(_float(stats.get("score_total")) / games, 3)
    result["average_actions"] = _round(_float(stats.get("actions")) / games, 3)
    result["average_turns"] = _round(_float(stats.get("turns")) / games, 3)
    result["average_decision_ms"] = _round(_float(stats.get("decision_ms_total")) / decisions_and_choices, 3)
    result["decision_ms_p50"] = _round(_percentile(list(stats.get("decision_ms_values") or []), 0.50), 3)
    result["decision_ms_p95"] = _round(_percentile(list(stats.get("decision_ms_values") or []), 0.95), 3)
    result["time_capped_decision_rate"] = _round(_float(stats.get("time_capped_decisions")) / decisions, 4)
    result["elo_delta"] = _round(_elo_delta(point_rate), 3)
    result.pop("decision_ms_values", None)
    return result


def _summarize_matches(matches: list[dict[str, Any]]) -> dict[str, Any]:
    stats = _empty_stats()
    for row in matches:
        _merge_match(stats, row)
    return _finalize_stats(stats)


def _group_by_deck(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row.get("deck") or "")].append(row)
    return dict(grouped)


def _bootstrap_point_rate_ci(matches: list[dict[str, Any]], seed: int) -> dict[str, Any]:
    if not matches:
        return _ci([])
    groups = _group_by_deck(matches)
    rng = random.Random(max(1, int(seed)))
    values: list[float] = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        points = 0.0
        count = 0
        for deck in sorted(groups):
            rows = groups[deck]
            for _sample in range(len(rows)):
                row = rows[rng.randrange(len(rows))]
                points += _match_point(row)
                count += 1
        values.append(points / max(1, count))
    return _ci(values)


def _pair_key(row: dict[str, Any]) -> tuple[str, int, int]:
    return (
        str(row.get("deck") or ""),
        _int(row.get("seed_block")),
        _int(row.get("seed")),
    )


def _paired_rows(matches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, int, int], list[dict[str, Any]]] = defaultdict(list)
    for row in matches:
        grouped[_pair_key(row)].append(row)
    pairs: list[dict[str, Any]] = []
    for (_deck, _block, _seed), rows in sorted(grouped.items()):
        first = rows[0]
        games = max(1, len(rows))
        points = sum(_match_point(row) for row in rows)
        score = sum(_float(row.get("score")) for row in rows)
        point_rate = points / games
        pairs.append({
            "deck": str(first.get("deck") or ""),
            "seed": _int(first.get("seed")),
            "seed_block": _int(first.get("seed_block")),
            "games": games,
            "complete": len(rows) >= 2,
            "clean": all(_is_clean_match(row) for row in rows),
            "point_rate": _round(point_rate, 4),
            "point_delta": _round(point_rate - 0.5, 4),
            "score_delta": _round(score / games, 3),
        })
    return pairs


def _bootstrap_pair_delta_values(pair_rows: list[dict[str, Any]], seed: int) -> list[float]:
    if not pair_rows:
        return []
    groups = _group_by_deck(pair_rows)
    rng = random.Random(max(1, int(seed)))
    values: list[float] = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        total = 0.0
        count = 0
        for deck in sorted(groups):
            rows = groups[deck]
            for _sample in range(len(rows)):
                row = rows[rng.randrange(len(rows))]
                total += _float(row.get("point_delta"))
                count += 1
        values.append(total / max(1, count))
    return values


def _probability_positive(values: list[float]) -> float:
    if not values:
        return 0.5
    positive = 0.0
    for value in values:
        if value > 0.0:
            positive += 1.0
        elif value == 0.0:
            positive += 0.5
    return _round(positive / len(values), 4)


def _summarize_pairs(pair_rows: list[dict[str, Any]], seed: int) -> dict[str, Any]:
    count = len(pair_rows)
    boot = _bootstrap_pair_delta_values(pair_rows, seed)
    return {
        "pairs": pair_rows,
        "paired_pairs": count,
        "clean_pairs": sum(1 for row in pair_rows if bool(row.get("clean"))),
        "paired_point_delta": _round(sum(_float(row.get("point_delta")) for row in pair_rows) / max(1, count), 4),
        "paired_score_delta": _round(sum(_float(row.get("score_delta")) for row in pair_rows) / max(1, count), 3),
        "paired_delta_ci95": _ci(boot),
        "probability_a_better": _probability_positive(boot),
    }


def _apply_paired_summary(target: dict[str, Any], paired: dict[str, Any]) -> None:
    for key in (
        "paired_pairs",
        "clean_pairs",
        "paired_point_delta",
        "paired_score_delta",
        "paired_delta_ci95",
        "probability_a_better",
    ):
        target[key] = paired.get(key)


def _summarize_by_deck(matches: list[dict[str, Any]], pair_rows: list[dict[str, Any]]) -> dict[str, Any]:
    pairs_by_deck = _group_by_deck(pair_rows)
    result: dict[str, Any] = {}
    for deck, rows in sorted(_group_by_deck(matches).items(), key=lambda item: _deck_sort_key(item[0])):
        stats = _summarize_matches(rows)
        stats["point_rate_ci95"] = _bootstrap_point_rate_ci(rows, BOOTSTRAP_SEED + _stable_deck_seed(deck))
        paired = _summarize_pairs(
            pairs_by_deck.get(deck, []),
            BOOTSTRAP_SEED + 1000 + _stable_deck_seed(deck),
        )
        _apply_paired_summary(stats, paired)
        result[deck] = stats
    return result


def _summarize_seats(matches: list[dict[str, Any]]) -> dict[str, Any]:
    first = _empty_stats()
    second = _empty_stats()
    seat_counts = {"a_player_0": 0, "a_player_1": 0}
    for row in matches:
        _merge_match(first if bool(row.get("strategy_a_first")) else second, row)
        if _int(row.get("strategy_a_player")) == 0:
            seat_counts["a_player_0"] += 1
        else:
            seat_counts["a_player_1"] += 1
    first_stats = _finalize_stats(first)
    second_stats = _finalize_stats(second)
    return {
        "strategy_a_first": first_stats,
        "strategy_a_second": second_stats,
        "seat_counts": seat_counts,
        "seat_gap": abs(seat_counts["a_player_0"] - seat_counts["a_player_1"]),
        "first_player_point_rate_gap": _round(
            abs(_float(first_stats.get("point_rate")) - _float(second_stats.get("point_rate"))),
            4,
        ),
    }


def _stable_deck_seed(deck: str) -> int:
    return zlib.crc32(deck.encode("utf-8")) % 100000


def _deck_sort_key(deck: str) -> tuple[int, str]:
    try:
        return (DECK_ORDER.index(deck), deck)
    except ValueError:
        return (999, deck)


def _match_sort_key(row: dict[str, Any]) -> tuple[int, int, int, int]:
    deck = str(row.get("deck") or "")
    return (
        _deck_sort_key(deck)[0],
        _int(row.get("seed_block")),
        _int(row.get("seat")),
        _int(row.get("strategy_a_player")),
    )


def _validate_shards(shards: list[dict[str, Any]]) -> dict[str, Any]:
    if not shards:
        raise MergeError("no_shards")
    reference = shards[0]
    if _int(reference.get("schema_version")) != SCHEMA_VERSION:
        raise MergeError("schema_version")
    for index, payload in enumerate(shards):
        if _int(payload.get("schema_version")) != SCHEMA_VERSION:
            raise MergeError(f"shard_{index}:schema_version")
        if payload.get("strategy_fingerprint") != reference.get("strategy_fingerprint"):
            raise MergeError(f"shard_{index}:strategy_fingerprint")
        if payload.get("deck_keys") != reference.get("deck_keys"):
            raise MergeError(f"shard_{index}:deck_keys")
        config = payload.get("config") or {}
        ref_config = reference.get("config") or {}
        for key in ("seed", "seed_blocks_per_deck", "max_actions", "eval_preset"):
            if config.get(key) != ref_config.get(key):
                raise MergeError(f"shard_{index}:config:{key}")
    return reference


def merge_payloads(shards: list[dict[str, Any]], *, workers: int = 1) -> dict[str, Any]:
    reference = _validate_shards(shards)
    matches: list[dict[str, Any]] = []
    seen: set[tuple[str, int, int, int]] = set()
    for shard_index, payload in enumerate(shards):
        for row in payload.get("matches") or []:
            key = (
                str(row.get("deck") or ""),
                _int(row.get("seed_block")),
                _int(row.get("seed")),
                _int(row.get("seat")),
            )
            if key in seen:
                raise MergeError(f"duplicate_match:{key}")
            seen.add(key)
            merged_row = dict(row)
            merged_row["shard_index"] = shard_index
            matches.append(merged_row)
    matches.sort(key=_match_sort_key)

    pair_rows = _paired_rows(matches)
    paired = _summarize_pairs(pair_rows, BOOTSTRAP_SEED + 777)
    summary = _summarize_matches(matches)
    summary["point_rate_ci95"] = _bootstrap_point_rate_ci(matches, BOOTSTRAP_SEED)
    _apply_paired_summary(summary, paired)

    config = dict(reference.get("config") or {})
    config["seed_block_start"] = 0
    config["seed_block_count"] = _int(config.get("seed_blocks_per_deck"))
    config["parallel_workers"] = max(1, int(workers))
    config["shards"] = len(shards)

    return {
        "schema_version": SCHEMA_VERSION,
        "created_at_unix": int(time.time()),
        "self_check": bool(reference.get("self_check")),
        "eval_preset": reference.get("eval_preset"),
        "mode": reference.get("mode", "mirror"),
        "deck_keys": reference.get("deck_keys") or [],
        "config": config,
        "strategies": reference.get("strategies") or {},
        "strategy_fingerprint": reference.get("strategy_fingerprint") or {},
        "summary": summary,
        "per_deck": _summarize_by_deck(matches, pair_rows),
        "paired": paired,
        "seat": _summarize_seats(matches),
        "terminal_reasons": dict(Counter(str(row.get("terminal_reason") or "") for row in matches)),
        "matches": matches,
        "shards": [
            {
                "index": index,
                "games": _int((payload.get("summary") or {}).get("games")),
                "config": payload.get("config") or {},
            }
            for index, payload in enumerate(shards)
        ],
    }


def merge_files(input_paths: list[Path], output_path: Path, *, workers: int = 1) -> dict[str, Any]:
    shards = [json.loads(path.read_text(encoding="utf-8")) for path in input_paths]
    payload = merge_payloads(shards, workers=workers)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=1)
    args = parser.parse_args()
    try:
        payload = merge_files(args.input, args.output, workers=max(1, args.workers))
    except MergeError as exc:
        print(json.dumps({"valid": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps({"valid": True, "output": str(args.output), "games": payload["summary"]["games"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

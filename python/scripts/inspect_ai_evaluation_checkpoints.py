"""Validate resumable schema-v7 AI evaluation checkpoints for the scheduler.

The Godot runner remains the authority that restores checkpoint rows.  This
inspector mirrors its record validation so the PowerShell LPT scheduler never
mistakes an arbitrary file name for completed evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 7
PROTOCOL_ID = "traditional_ai_evaluation_v7"
CHECKPOINT_ARTIFACT_KIND = "ai_evaluation_checkpoint_unit"
INSPECTION_ARTIFACT_KIND = "ai_evaluation_checkpoint_inspection"
_GODOT_APPROX_EPSILON = 0.00001


def _godot_int(value: object) -> int:
    """Apply the conversions used by ``int(Variant)`` for checkpoint fields."""
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("non-finite number")
        return int(value)
    if isinstance(value, str):
        return int(value.strip() or "0", 10)
    raise ValueError(f"cannot convert {type(value).__name__} to int")


def _godot_string(value: object) -> str:
    if value is None:
        return "<null>"
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def _godot_bool(value: object) -> bool:
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return bool(value)
    return True


def _round_away_from_zero(value: float) -> float:
    if value >= 0.0:
        return float(math.floor(value + 0.5))
    return float(math.ceil(value - 0.5))


def _is_equal_approx(left: float, right: float) -> bool:
    if left == right:
        return True
    tolerance = _GODOT_APPROX_EPSILON * abs(left)
    if tolerance < _GODOT_APPROX_EPSILON:
        tolerance = _GODOT_APPROX_EPSILON
    return abs(left - right) < tolerance


def _checkpoint_normalized(value: object) -> object:
    if isinstance(value, dict):
        return {
            _godot_string(key): _checkpoint_normalized(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_checkpoint_normalized(item) for item in value]
    if isinstance(value, float) and math.isfinite(value):
        rounded = _round_away_from_zero(value)
        if _is_equal_approx(value, rounded):
            return int(rounded)
    return value


def _canonical_json(value: object) -> str:
    if isinstance(value, dict):
        parts = (
            f"{json.dumps(str(key), ensure_ascii=False)}:"
            f"{_canonical_json(value[key])}"
            for key in sorted(value)
        )
        return "{" + ",".join(parts) + "}"
    if isinstance(value, list):
        return "[" + ",".join(_canonical_json(item) for item in value) + "]"
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
    )


def checkpoint_matches_sha256(rows: list[object]) -> str:
    """Return the hash produced by Godot's ``_checkpoint_matches_sha256``."""
    canonical = _canonical_json(_checkpoint_normalized(rows))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _evidence_unit_id_from_match(row: dict[str, object]) -> str:
    matchup_kind = _godot_string(row.get("matchup_kind", ""))
    deck_a = _godot_string(
        row.get("strategy_a_deck", row.get("deck", ""))
    )
    deck_b = _godot_string(
        row.get("strategy_b_deck", row.get("deck", ""))
    )
    seed_block = _godot_int(row.get("seed_block", -1))
    seed = _godot_int(row.get("seed", 0))
    if matchup_kind == "cross":
        lower, upper = sorted((deck_a, deck_b))
        return f"cross|{lower}|{upper}|{seed_block}|{seed}"
    return f"mirror|{deck_a}|{seed_block}|{seed}"


def _expected_match_identities(
    unit_id: str,
) -> Counter[tuple[str, str, str, int, int, int]]:
    parts = unit_id.split("|")
    if parts[0:1] == ["mirror"] and len(parts) == 4:
        deck = parts[1]
        numeric_parts = parts[2:]
        directions = ((deck, deck),)
        kind = "mirror"
    elif parts[0:1] == ["cross"] and len(parts) == 5:
        lower, upper = parts[1], parts[2]
        if not lower or not upper or lower >= upper:
            return Counter()
        numeric_parts = parts[3:]
        directions = ((lower, upper), (upper, lower))
        kind = "cross"
    else:
        return Counter()
    if not parts[1] or any(not value for value in numeric_parts):
        return Counter()
    try:
        seed_block, seed = (_godot_int(value) for value in numeric_parts)
    except (TypeError, ValueError):
        return Counter()
    if (
        seed_block < 0
        or seed < 0
        or numeric_parts != [str(seed_block), str(seed)]
    ):
        return Counter()
    return Counter(
        (kind, deck_a, deck_b, seed_block, seed, seat)
        for deck_a, deck_b in directions
        for seat in (0, 1)
    )


def _match_identities(
    rows: list[object],
) -> Counter[tuple[str, str, str, int, int, int]]:
    identities: Counter[tuple[str, str, str, int, int, int]] = Counter()
    for row in rows:
        if not isinstance(row, dict):
            return Counter()
        identities[(
            _godot_string(row.get("matchup_kind", "")),
            _godot_string(
                row.get("strategy_a_deck", row.get("deck", ""))
            ),
            _godot_string(
                row.get("strategy_b_deck", row.get("deck", ""))
            ),
            _godot_int(row.get("seed_block", -1)),
            _godot_int(row.get("seed", 0)),
            _godot_int(row.get("seat", -1)),
        )] += 1
    return identities


def _match_has_fatal_error(row: dict[str, object]) -> bool:
    return (
        _godot_string(row.get("terminal_reason", "")) != "game_over"
        or _godot_int(row.get("invalid_actions", 0)) > 0
        or _godot_int(row.get("choice_failures", 0)) > 0
        or _godot_int(row.get("rule_exceptions", 0)) > 0
        or _godot_bool(row.get("max_actions_exhausted", False))
    )


def checkpoint_record_error(
    record: object,
    *,
    simulation_fingerprint: str,
    task_manifest_id: str,
    shard_index: int,
    shard_count: int,
) -> str | None:
    """Return ``None`` exactly when a record is safe to restore."""
    if not isinstance(record, dict):
        return "record_not_object"
    try:
        if _godot_int(record.get("schema_version", 0)) != SCHEMA_VERSION:
            return "schema_version"
        if _godot_string(record.get("protocol_id", "")) != PROTOCOL_ID:
            return "protocol_id"
        if (
            _godot_string(record.get("artifact_kind", ""))
            != CHECKPOINT_ARTIFACT_KIND
        ):
            return "artifact_kind"
        if (
            _godot_string(record.get("simulation_fingerprint", ""))
            != simulation_fingerprint
        ):
            return "simulation_fingerprint"
        if (
            _godot_string(record.get("task_manifest_id", ""))
            != task_manifest_id
        ):
            return "task_manifest_id"
        if (
            _godot_int(record.get("evidence_shard_index", -1))
            != shard_index
        ):
            return "evidence_shard_index"
        if (
            _godot_int(record.get("evidence_shard_count", 0))
            != shard_count
        ):
            return "evidence_shard_count"

        unit_id = _godot_string(record.get("unit_id", ""))
        rows = record.get("matches", [])
        expected_games = 4 if unit_id.startswith("cross|") else 2
        if not unit_id:
            return "unit_id"
        if not isinstance(rows, list) or len(rows) != expected_games:
            return "game_count"
        expected_identities = _expected_match_identities(unit_id)
        if (
            not expected_identities
            or _match_identities(rows) != expected_identities
        ):
            return "match_identity_set"
        if (
            _godot_string(record.get("matches_sha256", ""))
            != checkpoint_matches_sha256(rows)
        ):
            return "matches_sha256"
        for row in rows:
            if not isinstance(row, dict):
                return "match_not_object"
            if _evidence_unit_id_from_match(row) != unit_id:
                return "match_unit_identity"
            if _match_has_fatal_error(row):
                return "fatal_match"
    except (OverflowError, TypeError, ValueError):
        return "field_type"
    return None


def _read_json(path: Path) -> object:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-finite JSON constant: {value}")

    return json.loads(
        path.read_text(encoding="utf-8-sig"),
        parse_constant=reject_constant,
    )


def inspect_checkpoint_root(
    checkpoint_root: Path,
    *,
    simulation_fingerprint: str,
    task_manifest_id: str,
    shard_count: int,
) -> dict[str, object]:
    """Inspect all logical shard directories and return reusable unit IDs."""
    if shard_count <= 0:
        raise ValueError("shard_count must be positive")

    valid_by_shard: dict[str, list[str]] = {}
    conflicts_by_shard: dict[str, list[str]] = {}
    invalid_reasons: Counter[str] = Counter()
    files_seen = 0
    idempotent_duplicates = 0
    duplicate_conflicts = 0

    for shard_index in range(shard_count):
        shard_key = str(shard_index)
        shard_directory = checkpoint_root / f"shard-{shard_index:03d}"
        hashes_by_unit: dict[str, str] = {}
        conflicted_units: set[str] = set()
        try:
            paths = sorted(shard_directory.iterdir(), key=lambda path: path.name)
        except (FileNotFoundError, NotADirectoryError, OSError):
            paths = []
        for path in paths:
            if not path.is_file() or path.suffix != ".json":
                continue
            files_seen += 1
            try:
                record = _read_json(path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                invalid_reasons["invalid_json"] += 1
                continue
            error = checkpoint_record_error(
                record,
                simulation_fingerprint=simulation_fingerprint,
                task_manifest_id=task_manifest_id,
                shard_index=shard_index,
                shard_count=shard_count,
            )
            if error is not None:
                invalid_reasons[error] += 1
                continue

            assert isinstance(record, dict)
            unit_id = _godot_string(record.get("unit_id", ""))
            matches_hash = _godot_string(record.get("matches_sha256", ""))
            if unit_id in conflicted_units:
                continue
            existing_hash = hashes_by_unit.get(unit_id)
            if existing_hash is None:
                hashes_by_unit[unit_id] = matches_hash
            elif existing_hash == matches_hash:
                idempotent_duplicates += 1
            else:
                # A conflicting immutable history is never considered complete
                # by the scheduler.  Godot will independently flag it if the
                # shard is run before the operator removes the stale records.
                hashes_by_unit.pop(unit_id, None)
                conflicted_units.add(unit_id)
                duplicate_conflicts += 1

        valid_by_shard[shard_key] = sorted(hashes_by_unit)
        conflicts_by_shard[shard_key] = sorted(conflicted_units)

    invalid_records = sum(invalid_reasons.values())
    return {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "artifact_kind": INSPECTION_ARTIFACT_KIND,
        "simulation_fingerprint": simulation_fingerprint,
        "task_manifest_id": task_manifest_id,
        "evidence_shard_count": shard_count,
        "valid_unit_ids_by_shard": valid_by_shard,
        "conflicting_unit_ids_by_shard": conflicts_by_shard,
        "diagnostics": {
            "files_seen": files_seen,
            "valid_unique_units": sum(map(len, valid_by_shard.values())),
            "invalid_records": invalid_records,
            "invalid_records_by_reason": dict(sorted(invalid_reasons.items())),
            "idempotent_duplicates": idempotent_duplicates,
            "duplicate_conflicts": duplicate_conflicts,
        },
    }


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = (
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_name = handle.name
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink()
            except FileNotFoundError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint-root", required=True, type=Path)
    parser.add_argument("--simulation-fingerprint", required=True)
    parser.add_argument("--task-manifest-id", required=True)
    parser.add_argument("--shard-count", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.shard_count <= 0:
        parser.error("--shard-count must be positive")
    payload = inspect_checkpoint_root(
        args.checkpoint_root,
        simulation_fingerprint=args.simulation_fingerprint,
        task_manifest_id=args.task_manifest_id,
        shard_count=args.shard_count,
    )
    _write_json_atomic(args.output, payload)
    print(
        json.dumps(
            {
                "checkpoint_inspection": str(args.output),
                "valid_unique_units": payload["diagnostics"][
                    "valid_unique_units"
                ],
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

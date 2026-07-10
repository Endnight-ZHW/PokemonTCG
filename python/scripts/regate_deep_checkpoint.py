"""Re-apply the current release gate to a fully evaluated Deep AI checkpoint."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


PYTHON_ROOT = Path(__file__).resolve().parents[1]
INVOCATION_CWD = Path.cwd()
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai.dl.encoder import ENCODER_SCHEMA_VERSION
from engine.ai.dl.model import CHECKPOINT_VERSION, load_checkpoint, save_checkpoint
from engine.ai.dl.release_gate import (
    DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
    DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    DEFAULT_MIN_ACCEPTED_POINT_RATE,
    has_strength_and_reliability_floor,
)
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from scripts.validate_ai_models import validate_model


def _resolve(path: Path) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(os.fspath(path))))
    return path.resolve() if path.is_absolute() else (INVOCATION_CWD / path).resolve()


def _deck_summary(metadata: dict[str, Any], deck_key: str) -> dict[str, Any]:
    summary = metadata.get("summary")
    if not isinstance(summary, dict):
        raise ValueError("Checkpoint metadata has no training summary")
    row = summary.get(deck_key)
    if not isinstance(row, dict):
        raise ValueError(f"Checkpoint metadata has no summary for deck '{deck_key}'")
    return row


def _choice_examples(row: dict[str, Any]) -> int:
    total = int((row.get("choice") or {}).get("choice_examples") or 0)
    total += int((row.get("distill_choice") or {}).get("choice_examples") or 0)
    total += int(row.get("loaded_choice_examples") or 0)
    return max(0, total)


def _verify_evidence(
    payload: dict[str, Any],
    metadata: dict[str, Any],
    deck_key: str,
    *,
    min_games: int,
    min_point_rate: float,
    min_delta_point_rate: float,
    max_step_exhaustion_rate: float,
) -> None:
    schema = dict(payload.get("schema") or {})
    expected_schema = {
        "rules_version": RULES_SCHEMA_VERSION,
        "action_version": ACTION_SCHEMA_VERSION,
        "encoder_version": ENCODER_SCHEMA_VERSION,
    }
    errors: list[str] = []
    if int(payload.get("version") or 0) != CHECKPOINT_VERSION:
        errors.append("checkpoint_version")
    for key, expected in expected_schema.items():
        if int(schema.get(key) or 0) != int(expected):
            errors.append(key)
    if str(metadata.get("deck") or "") != deck_key:
        errors.append("deck")
    if int(metadata.get("planner_version") or 0) != PLANNER_SCHEMA_VERSION:
        errors.append("planner_version")
    if not isinstance(metadata.get("seed"), int):
        errors.append("seed")

    row = _deck_summary(metadata, deck_key)
    candidate = row.get("eval") if isinstance(row.get("eval"), dict) else {}
    baseline = row.get("challenge_baseline_eval")
    baseline = baseline if isinstance(baseline, dict) else None
    if int(candidate.get("games") or 0) < int(min_games):
        errors.append("eval_games")
    for metric in (
        "invalid_action_rate",
        "no_target_action_rate",
        "rule_exception_rate",
        "decision_timeout_rate",
    ):
        if float(candidate.get(metric, 0.0) or 0.0) > 0.0:
            errors.append(metric)
    if not has_strength_and_reliability_floor(
        candidate,
        min_point_rate=min_point_rate,
        paired_baseline=baseline,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate_limit=max_step_exhaustion_rate,
    ):
        errors.append("strength_or_reliability")
    if bool(metadata.get("choice_head_enabled")) and _choice_examples(row) <= 0:
        errors.append("choice_head_untrained")
    if errors:
        raise ValueError("Checkpoint cannot pass the current release gate: " + ",".join(errors))


def regate(
    source: Path,
    output: Path,
    *,
    deck_key: str,
    min_games: int = DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    min_point_rate: float = DEFAULT_MIN_ACCEPTED_POINT_RATE,
    min_delta_point_rate: float = DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    max_step_exhaustion_rate: float = DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
) -> dict[str, Any]:
    source = _resolve(source)
    output = _resolve(output)
    if output.suffix.lower() != ".pt":
        raise ValueError("Re-gated checkpoint output must use the .pt extension")
    sidecar_path = source.with_suffix(".json")
    if not source.is_file() or not sidecar_path.is_file():
        raise FileNotFoundError(f"Missing checkpoint or sidecar: {source}")

    model, payload = load_checkpoint(str(source), "cpu")
    sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
    embedded_metadata = dict(payload.get("metadata") or {})
    sidecar_metadata = dict(sidecar.get("metadata") or {})
    if embedded_metadata != sidecar_metadata:
        raise ValueError("Checkpoint and sidecar metadata do not match")

    metadata = copy.deepcopy(embedded_metadata)
    _verify_evidence(
        payload,
        metadata,
        deck_key,
        min_games=min_games,
        min_point_rate=min_point_rate,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate=max_step_exhaustion_rate,
    )
    row = _deck_summary(metadata, deck_key)
    row["accepted"] = True
    row["min_delta_point_rate"] = float(min_delta_point_rate)
    metadata.update({
        "accepted": True,
        "training_gate_accepted": True,
        "verified": True,
        "verification_status": "verified_accepted",
        "verification_note": "Existing full evaluation evidence passed the current release gate.",
        "min_delta_point_rate": float(min_delta_point_rate),
        "max_step_exhaustion_rate": float(max_step_exhaustion_rate),
        "regated_at": int(time.time()),
        "regated_from": str(source),
    })

    output.parent.mkdir(parents=True, exist_ok=True)
    output_sidecar = output.with_suffix(".json")
    with tempfile.TemporaryDirectory(
        prefix=".deep_checkpoint_regate-",
        dir=output.parent,
    ) as temp_dir:
        transaction_root = Path(temp_dir)
        staged_model = transaction_root / f"{deck_key}.pt"
        staged_sidecar = transaction_root / f"{deck_key}.json"
        save_checkpoint(str(staged_model), model, metadata)
        staged_sidecar.write_text(
            json.dumps(
                {
                    "checkpoint_sha256": _sha256(staged_model),
                    "model_path": str(output),
                    "metadata": metadata,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )
        validation = validate_model(
            deck_key,
            model_dir=str(transaction_root),
            min_games=min_games,
            min_point_rate=min_point_rate,
            min_delta_point_rate=min_delta_point_rate,
            max_step_exhaustion_rate=max_step_exhaustion_rate,
        )
        if not validation["valid"]:
            raise ValueError(
                "Re-gated checkpoint failed validation: "
                + ",".join(validation["errors"])
            )

        backup_model = transaction_root / "previous.pt"
        backup_sidecar = transaction_root / "previous.json"
        targets = (
            (staged_model, output, backup_model),
            (staged_sidecar, output_sidecar, backup_sidecar),
        )
        backed_up: list[tuple[Path, Path]] = []
        installed: list[Path] = []
        try:
            for _staged, target, backup in targets:
                if target.exists():
                    os.replace(target, backup)
                    backed_up.append((backup, target))
            for staged, target, _backup in targets:
                os.replace(staged, target)
                installed.append(target)
        except Exception:
            for target in reversed(installed):
                try:
                    target.unlink(missing_ok=True)
                except OSError:
                    pass
            rollback_errors: list[str] = []
            for backup, target in reversed(backed_up):
                try:
                    os.replace(backup, target)
                except OSError as exc:
                    rollback_errors.append(f"{target}:{exc}")
            if rollback_errors:
                raise OSError(
                    "Re-gating failed and rollback was incomplete: "
                    + "; ".join(rollback_errors)
                ) from None
            raise
    validation["model_path"] = str(output)
    return validation


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--deck", required=True)
    parser.add_argument("--min-games", type=int, default=DEFAULT_MIN_ACCEPTED_EVAL_GAMES)
    parser.add_argument("--min-point-rate", type=float, default=DEFAULT_MIN_ACCEPTED_POINT_RATE)
    parser.add_argument("--min-delta-point-rate", type=float, default=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE)
    parser.add_argument("--max-step-exhaustion-rate", type=float, default=DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE)
    args = parser.parse_args()
    try:
        result = regate(
            args.source,
            args.output,
            deck_key=args.deck,
            min_games=max(0, args.min_games),
            min_point_rate=max(0.0, min(1.0, args.min_point_rate)),
            min_delta_point_rate=max(-1.0, min(1.0, args.min_delta_point_rate)),
            max_step_exhaustion_rate=max(0.0, min(1.0, args.max_step_exhaustion_rate)),
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from None
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

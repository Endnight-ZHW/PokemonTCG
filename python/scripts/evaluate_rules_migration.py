"""Evaluate released Deep AI checkpoints before a Python rules schema bump.

The command writes immutable evidence only.  It never edits checkpoints,
sidecars, ONNX files, or the release manifest.  A full release-eligible run
requires the pinned toolchain and 600 paired games for every release deck.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.ai.dl.model import load_checkpoint
from engine.ai.dl.release_gate import (
    DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
    DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    DEFAULT_MIN_ACCEPTED_POINT_RATE,
    has_strength_and_reliability_floor,
    release_delta_point_rate,
)
from engine.ai.dl.rules_migration import (
    EVIDENCE_FORMAT_VERSION,
    DIAGNOSTIC_RATE_KEYS,
    canonical_payload_sha256,
    expected_runtime_versions,
    rules_source_fingerprint,
    runtime_contract_errors,
    runtime_versions,
    sha256_file,
)
from engine.ai.dl.training import evaluate_challenge_baseline, evaluate_model


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return payload


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    try:
        os.replace(temporary, path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _release_decks(manifest_path: Path) -> list[str]:
    manifest = _read_json(manifest_path)
    decks = manifest.get("release_decks")
    if not isinstance(decks, list) or not decks or not all(isinstance(x, str) for x in decks):
        raise ValueError("release_manifest.json has no valid release_decks")
    if int(manifest.get("model_count") or 0) != len(decks) or len(set(decks)) != len(decks):
        raise ValueError("release manifest deck/model count mismatch")
    return list(decks)


def _load_source(model_path: Path, deck: str, device: str):
    sidecar_path = model_path.with_suffix(".json")
    if not model_path.is_file() or not sidecar_path.is_file():
        raise FileNotFoundError(f"Missing checkpoint or sidecar for {deck}")
    model_hash = sha256_file(model_path)
    sidecar = _read_json(sidecar_path)
    if str(sidecar.get("checkpoint_sha256") or "") != model_hash:
        raise ValueError(f"Sidecar hash mismatch for {deck}")
    model, checkpoint = load_checkpoint(str(model_path), device)
    embedded = dict(checkpoint.get("metadata") or {})
    if embedded != dict(sidecar.get("metadata") or {}):
        raise ValueError(f"Embedded metadata differs from sidecar for {deck}")
    if str(embedded.get("deck") or "") != deck:
        raise ValueError(f"Checkpoint deck mismatch for {deck}")
    schema = dict(checkpoint.get("schema") or embedded)
    return model, checkpoint, embedded, schema, model_hash


def _release_accepted(
    candidate: dict[str, Any],
    baseline: dict[str, Any],
    *,
    min_point_rate: float,
    min_delta_point_rate: float,
    max_step_exhaustion_rate: float,
) -> bool:
    if any(float(candidate.get(key, 0.0) or 0.0) != 0.0 for key in DIAGNOSTIC_RATE_KEYS):
        return False
    return has_strength_and_reliability_floor(
        candidate,
        min_point_rate=min_point_rate,
        paired_baseline=baseline,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate_limit=max_step_exhaustion_rate,
    )


def evaluate_deck(
    *,
    deck: str,
    model_dir: Path,
    output_dir: Path,
    source_rules_version: int,
    target_rules_version: int,
    games: int,
    seed: int | None,
    workers: int,
    max_steps: int,
    device: str,
    teacher_search_preset: str,
    use_mcts: bool,
    mcts_simulations: int,
    rules_source: dict[str, Any],
    environment: dict[str, Any],
    expected_environment: dict[str, str],
    environment_errors: list[str],
    allow_unpinned_environment: bool,
    min_point_rate: float,
    min_delta_point_rate: float,
    max_step_exhaustion_rate: float,
    resume: bool,
) -> tuple[dict[str, Any], bool]:
    model_path = model_dir / f"{deck}.pt"
    model, checkpoint, metadata, schema, model_hash = _load_source(model_path, deck, device)
    actual_source_rules = int(schema.get("rules_version") or 0)
    if actual_source_rules != source_rules_version:
        raise ValueError(
            f"{deck}: expected source rules v{source_rules_version}, found v{actual_source_rules}"
        )
    if int(schema.get("action_version") or 0) != ACTION_SCHEMA_VERSION:
        raise ValueError(f"{deck}: action schema mismatch")
    row = dict((metadata.get("summary") or {}).get(deck) or {})
    eval_seed = int(seed if seed is not None else row.get("eval_seed") or 0)
    if eval_seed <= 0:
        eval_seed = int(metadata.get("seed") or 17) + 900_000

    evaluation = {
        "seed": eval_seed,
        "games": games,
        "workers": workers,
        "max_steps": max_steps,
        "teacher_search_preset": teacher_search_preset,
        "use_mcts": use_mcts,
        "mcts_simulations": mcts_simulations,
    }
    run_identity = {
        "format_version": EVIDENCE_FORMAT_VERSION,
        "deck": deck,
        "model_sha256": model_hash,
        "migration": {
            "source_rules_version": source_rules_version,
            "target_rules_version": target_rules_version,
            "action_version": ACTION_SCHEMA_VERSION,
        },
        "evaluation": evaluation,
        "rules_source_sha256": str(rules_source.get("sha256") or ""),
        "environment": {
            "actual": environment,
            "expected": expected_environment,
            "errors": environment_errors,
            "allow_unpinned": allow_unpinned_environment,
        },
        "gate": {
            "min_point_rate": min_point_rate,
            "min_delta_point_rate": min_delta_point_rate,
            "max_step_exhaustion_rate": max_step_exhaustion_rate,
        },
    }
    identity_sha256 = canonical_payload_sha256(run_identity)
    evidence_path = output_dir / f"{deck}.json"
    if resume and evidence_path.is_file():
        try:
            existing = _read_json(evidence_path)
            candidate_games = int((existing.get("candidate") or {}).get("games") or 0)
            baseline_games = int(
                (existing.get("challenge_baseline") or {}).get("games") or 0
            )
            if (
                str(existing.get("run_identity_sha256") or "") == identity_sha256
                and candidate_games == games
                and baseline_games == games
                and int(existing.get("completed_at") or 0) > 0
            ):
                return existing, True
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            pass

    started = time.time()
    baseline = evaluate_challenge_baseline(
        deck,
        eval_seed,
        games,
        max_steps=max_steps,
        workers=workers,
        teacher_search_preset=teacher_search_preset,
    )
    candidate = evaluate_model(
        model,
        deck,
        eval_seed,
        games,
        device=device,
        max_steps=max_steps,
        workers=workers,
        teacher_search_preset=teacher_search_preset,
        use_mcts=use_mcts,
        mcts_simulations=mcts_simulations,
    )
    delta = release_delta_point_rate(candidate, baseline)
    accepted = _release_accepted(
        candidate,
        baseline,
        min_point_rate=min_point_rate,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate=max_step_exhaustion_rate,
    )
    full_game_count = games >= DEFAULT_MIN_ACCEPTED_EVAL_GAMES
    release_eligible = not environment_errors and full_game_count and not allow_unpinned_environment
    evidence = {
        "format_version": EVIDENCE_FORMAT_VERSION,
        "deck": deck,
        "model_path": str(model_path.resolve()),
        "model_sha256": model_hash,
        "checkpoint_version": int(checkpoint.get("version") or 0),
        "migration": {
            "source_rules_version": source_rules_version,
            "target_rules_version": target_rules_version,
            "action_version": ACTION_SCHEMA_VERSION,
        },
        "evaluation": evaluation,
        "run_identity": run_identity,
        "run_identity_sha256": identity_sha256,
        "rules_source": rules_source,
        "environment": {
            "actual": environment,
            "expected": expected_environment,
            "errors": environment_errors,
        },
        "challenge_baseline": baseline,
        "candidate": candidate,
        "paired_delta_point_rate": delta,
        "accepted": accepted,
        "release_eligible": release_eligible,
        "elapsed_seconds": round(time.time() - started, 3),
        "completed_at": int(time.time()),
    }
    _write_json_atomic(evidence_path, evidence)
    return evidence, False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deck", default="all")
    parser.add_argument("--model-dir", type=Path, default=PYTHON_ROOT / "data" / "ai_models")
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "build" / "rules_v3_evidence")
    parser.add_argument("--manifest", type=Path, default=REPO_ROOT / "release_manifest.json")
    parser.add_argument("--toolchain-lock", type=Path, default=REPO_ROOT / "tools" / "toolchain.lock.json")
    parser.add_argument("--source-rules-version", type=int, default=RULES_SCHEMA_VERSION)
    parser.add_argument("--target-rules-version", type=int, default=RULES_SCHEMA_VERSION + 1)
    parser.add_argument("--games", type=int, default=DEFAULT_MIN_ACCEPTED_EVAL_GAMES)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--workers", type=int, default=max(1, min(12, (os.cpu_count() or 2) - 2)))
    parser.add_argument("--max-steps", type=int, default=160)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--teacher-search-preset", default="quality")
    parser.add_argument("--use-mcts", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--mcts-simulations", type=int, default=64)
    parser.add_argument("--allow-unpinned-environment", action="store_true")
    parser.add_argument(
        "--resume",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Reuse a completed per-deck artifact only when its full run identity matches.",
    )
    parser.add_argument("--min-point-rate", type=float, default=DEFAULT_MIN_ACCEPTED_POINT_RATE)
    parser.add_argument("--min-delta-point-rate", type=float, default=DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE)
    parser.add_argument("--max-step-exhaustion-rate", type=float, default=DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE)
    args = parser.parse_args()

    decks = _release_decks(args.manifest.resolve())
    if args.deck != "all":
        if args.deck not in decks:
            parser.error(f"Unknown release deck: {args.deck}")
        decks = [args.deck]
    if args.target_rules_version <= args.source_rules_version:
        parser.error("target rules version must be greater than source rules version")
    games = max(1, int(args.games))
    actual_environment = runtime_versions()
    expected_environment = expected_runtime_versions(args.toolchain_lock.resolve())
    environment_errors = runtime_contract_errors(
        actual_environment,
        expected_environment,
        require_cuda=str(args.device).startswith("cuda"),
    )
    if environment_errors and not args.allow_unpinned_environment:
        parser.error(
            "Pinned evaluation environment mismatch: " + "; ".join(environment_errors)
        )
    rules_source = rules_source_fingerprint(PYTHON_ROOT)
    output_dir = args.output_dir.resolve()
    results: dict[str, Any] = {}
    for deck in decks:
        print(f"[{deck}] checking {games}-game paired evidence...", flush=True)
        result, reused = evaluate_deck(
            deck=deck,
            model_dir=args.model_dir.resolve(),
            output_dir=output_dir,
            source_rules_version=int(args.source_rules_version),
            target_rules_version=int(args.target_rules_version),
            games=games,
            seed=args.seed,
            workers=max(1, int(args.workers)),
            max_steps=max(20, int(args.max_steps)),
            device=str(args.device),
            teacher_search_preset=str(args.teacher_search_preset),
            use_mcts=bool(args.use_mcts),
            mcts_simulations=max(1, int(args.mcts_simulations)),
            rules_source=rules_source,
            environment=actual_environment,
            expected_environment=expected_environment,
            environment_errors=environment_errors,
            allow_unpinned_environment=bool(args.allow_unpinned_environment),
            min_point_rate=max(0.0, min(1.0, float(args.min_point_rate))),
            min_delta_point_rate=max(-1.0, min(1.0, float(args.min_delta_point_rate))),
            max_step_exhaustion_rate=max(0.0, min(1.0, float(args.max_step_exhaustion_rate))),
            resume=bool(args.resume),
        )
        results[deck] = result
        print(
            json.dumps(
                {
                    "deck": deck,
                    "mode": "reused" if reused else "evaluated",
                    "accepted": results[deck]["accepted"],
                    "release_eligible": results[deck]["release_eligible"],
                    "paired_delta_point_rate": results[deck]["paired_delta_point_rate"],
                    "evidence": str(output_dir / f"{deck}.json"),
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
    return 0 if all(row["accepted"] for row in results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())

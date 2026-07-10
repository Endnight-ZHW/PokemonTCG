"""Evidence contracts for migrating released models to a new rules schema.

Rules migrations deliberately live outside checkpoint metadata until every
release deck has been evaluated.  This module keeps those evaluation artifacts
tamper-evident and makes the final promotion gate a pure, testable operation.
"""
from __future__ import annotations

import hashlib
import copy
import json
import platform
import re
from pathlib import Path
from typing import Any, Iterable

from engine.ai.dl.release_gate import (
    DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
    DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    DEFAULT_MIN_ACCEPTED_POINT_RATE,
    has_strength_and_reliability_floor,
    release_delta_point_rate,
)


EVIDENCE_FORMAT_VERSION = 1
DIAGNOSTIC_RATE_KEYS = (
    "invalid_action_rate",
    "no_target_action_rate",
    "rule_exception_rate",
    "decision_timeout_rate",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_payload_sha256(payload: Any) -> str:
    """Hash JSON data independently of key insertion order or whitespace."""
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _semantic_source_bytes(relative_path: str, raw: bytes) -> bytes:
    """Ignore schema labels themselves while hashing executable semantics.

    The evaluation is run before the repository-wide version flip.  Replacing
    the two integer labels must therefore not invalidate otherwise identical
    evidence, while every executable rule or policy change still does.
    """
    if relative_path == "engine/actions.py":
        text = raw.decode("utf-8")
        text = re.sub(
            r"^(ACTION_SCHEMA_VERSION|RULES_SCHEMA_VERSION)\s*=\s*\d+\s*$",
            r"\1 = <SCHEMA_VERSION>",
            text,
            flags=re.MULTILINE,
        )
        return text.encode("utf-8")
    return raw


def rules_source_fingerprint(python_root: Path) -> dict[str, Any]:
    """Hash rules, AI policy, encoder, and canonical card/deck definitions."""
    python_root = python_root.resolve()
    paths: list[Path] = sorted(
        path
        for path in (python_root / "engine").rglob("*.py")
        if "__pycache__" not in path.parts
    )
    paths.extend(
        python_root / "data" / name
        for name in (
            "card_models.py",
            "card_registry.py",
            "deck_definitions.py",
            "ai_policies.json",
        )
    )
    digest = hashlib.sha256()
    rows: list[dict[str, str]] = []
    for path in sorted(paths):
        if not path.is_file():
            raise FileNotFoundError(path)
        relative = path.relative_to(python_root).as_posix()
        content = _semantic_source_bytes(relative, path.read_bytes())
        file_digest = hashlib.sha256(content).hexdigest()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(content)
        digest.update(b"\0")
        rows.append({"path": relative, "sha256": file_digest})
    return {
        "algorithm": "sha256-semantic-v1",
        "sha256": digest.hexdigest(),
        "file_count": len(rows),
        "files": rows,
    }


def runtime_versions() -> dict[str, Any]:
    versions: dict[str, Any] = {
        "python": platform.python_version(),
        "implementation": platform.python_implementation(),
    }
    for module_name in ("numpy", "torch", "onnx", "onnxruntime"):
        try:
            module = __import__(module_name)
            versions[module_name] = str(getattr(module, "__version__", "unknown"))
        except ImportError:
            versions[module_name] = None
    try:
        import torch

        versions["cuda_available"] = bool(torch.cuda.is_available())
        versions["cuda_version"] = str(torch.version.cuda or "")
        versions["gpu_name"] = (
            str(torch.cuda.get_device_name(0)) if torch.cuda.is_available() else ""
        )
    except ImportError:
        versions.update({"cuda_available": False, "cuda_version": "", "gpu_name": ""})
    return versions


def expected_runtime_versions(toolchain_lock: Path) -> dict[str, str]:
    payload = json.loads(toolchain_lock.read_text(encoding="utf-8"))
    python = dict(payload.get("python") or {})
    return {
        "python": str(python.get("version") or ""),
        "numpy": str(python.get("numpy") or ""),
        "torch": str(python.get("torch") or ""),
        "cuda": str(python.get("cuda") or ""),
        "onnx": str(python.get("onnx") or ""),
        "onnxruntime": str(python.get("onnxruntime") or ""),
    }


def _base_version(value: Any) -> str:
    return str(value or "").split("+", 1)[0]


def runtime_contract_errors(
    actual: dict[str, Any],
    expected: dict[str, str],
    *,
    require_cuda: bool,
) -> list[str]:
    errors: list[str] = []
    for key in ("python", "numpy", "torch", "onnx", "onnxruntime"):
        if _base_version(actual.get(key)) != _base_version(expected.get(key)):
            errors.append(
                f"{key}:expected={expected.get(key) or 'missing'}:"
                f"actual={actual.get(key) or 'missing'}"
            )
    if str(actual.get("implementation") or "") != "CPython":
        errors.append("implementation:expected=CPython")
    if require_cuda and not bool(actual.get("cuda_available")):
        errors.append("cuda:required")
    if (
        require_cuda
        and expected.get("cuda")
        and str(actual.get("cuda_version") or "") != str(expected["cuda"])
    ):
        errors.append(
            f"cuda_version:expected={expected['cuda']}:"
            f"actual={actual.get('cuda_version') or 'missing'}"
        )
    return errors


def evidence_gate_errors(
    evidence: dict[str, Any],
    *,
    deck_key: str,
    model_sha256: str,
    target_rules_version: int,
    rules_fingerprint: str,
    min_games: int = DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
    min_point_rate: float = DEFAULT_MIN_ACCEPTED_POINT_RATE,
    min_delta_point_rate: float = DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    max_step_exhaustion_rate: float = DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
) -> list[str]:
    """Return every reason an artifact cannot authorize schema promotion."""
    errors: list[str] = []
    if int(evidence.get("format_version") or 0) != EVIDENCE_FORMAT_VERSION:
        errors.append("format_version")
    if str(evidence.get("deck") or "") != deck_key:
        errors.append("deck")
    if str(evidence.get("model_sha256") or "") != model_sha256:
        errors.append("model_sha256")
    migration = dict(evidence.get("migration") or {})
    if int(migration.get("target_rules_version") or 0) != int(target_rules_version):
        errors.append("target_rules_version")
    fingerprint = dict(evidence.get("rules_source") or {})
    if str(fingerprint.get("sha256") or "") != rules_fingerprint:
        errors.append("rules_source")
    if evidence.get("release_eligible") is not True:
        errors.append("release_environment")
    if evidence.get("accepted") is not True:
        errors.append("accepted")

    candidate = evidence.get("candidate")
    baseline = evidence.get("challenge_baseline")
    if not isinstance(candidate, dict):
        candidate = {}
        errors.append("candidate")
    if not isinstance(baseline, dict):
        baseline = {}
        errors.append("challenge_baseline")
    games = int(candidate.get("games") or 0)
    if games < int(min_games) or int(baseline.get("games") or 0) != games:
        errors.append("eval_games")
    candidate_points = candidate.get("game_points")
    baseline_points = baseline.get("game_points")
    if (
        not isinstance(candidate_points, list)
        or not isinstance(baseline_points, list)
        or len(candidate_points) != games
        or len(baseline_points) != games
    ):
        errors.append("paired_game_points")
    for key in DIAGNOSTIC_RATE_KEYS:
        if float(candidate.get(key, 0.0) or 0.0) != 0.0:
            errors.append(key)
    if not has_strength_and_reliability_floor(
        candidate,
        min_point_rate=min_point_rate,
        paired_baseline=baseline,
        min_delta_point_rate=min_delta_point_rate,
        max_step_exhaustion_rate_limit=max_step_exhaustion_rate,
    ):
        errors.append("strength_or_reliability")
    recorded_delta = evidence.get("paired_delta_point_rate")
    actual_delta = release_delta_point_rate(candidate, baseline)
    if actual_delta is None or abs(float(recorded_delta or 0.0) - actual_delta) > 1e-12:
        errors.append("paired_delta_point_rate")
    return list(dict.fromkeys(errors))


def validate_release_evidence_set(
    evidence_rows: Iterable[dict[str, Any]],
    *,
    release_decks: Iterable[str],
    model_hashes: dict[str, str],
    target_rules_version: int,
    rules_fingerprint: str,
    min_games: int = DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
) -> dict[str, list[str]]:
    by_deck: dict[str, dict[str, Any]] = {}
    duplicates: set[str] = set()
    for row in evidence_rows:
        deck = str(row.get("deck") or "")
        if deck in by_deck:
            duplicates.add(deck)
        by_deck[deck] = row
    result: dict[str, list[str]] = {}
    for deck in release_decks:
        if deck not in by_deck:
            result[deck] = ["missing_evidence"]
            continue
        errors = evidence_gate_errors(
            by_deck[deck],
            deck_key=deck,
            model_sha256=str(model_hashes.get(deck) or ""),
            target_rules_version=target_rules_version,
            rules_fingerprint=rules_fingerprint,
            min_games=min_games,
        )
        if deck in duplicates:
            errors.append("duplicate_evidence")
        if errors:
            result[deck] = errors
    extra = sorted(set(by_deck).difference(release_decks).difference({""}))
    if extra:
        result["<extra>"] = extra
    return result


def migrated_checkpoint_payload(
    checkpoint: dict[str, Any],
    evidence: dict[str, Any],
    *,
    deck_key: str,
    target_rules_version: int,
    evidence_sha256: str,
) -> dict[str, Any]:
    """Return a v-next checkpoint payload without mutating the source object."""
    payload = copy.deepcopy(checkpoint)
    metadata = dict(payload.get("metadata") or {})
    schema = dict(payload.get("schema") or {})
    source_rules_version = int(schema.get("rules_version") or metadata.get("rules_version") or 0)
    if source_rules_version >= int(target_rules_version):
        raise ValueError("target rules version must be newer than the checkpoint")
    if str(metadata.get("deck") or "") != deck_key:
        raise ValueError("checkpoint deck does not match migration evidence")

    candidate = copy.deepcopy(dict(evidence.get("candidate") or {}))
    baseline = copy.deepcopy(dict(evidence.get("challenge_baseline") or {}))
    summary = copy.deepcopy(dict(metadata.get("summary") or {}))
    row = copy.deepcopy(dict(summary.get(deck_key) or {}))
    row.update(
        {
            "eval": candidate,
            "challenge_baseline_eval": baseline,
            "eval_seed": int((evidence.get("evaluation") or {}).get("seed") or 0),
            "eval_use_mcts": bool((evidence.get("evaluation") or {}).get("use_mcts")),
            "mcts_simulations": int(
                (evidence.get("evaluation") or {}).get("mcts_simulations") or 0
            ),
            "paired_delta_point_rate": evidence.get("paired_delta_point_rate"),
            "delta_point_rate": evidence.get("paired_delta_point_rate"),
            "accepted": True,
            "rules_migration_evidence_sha256": evidence_sha256,
        }
    )
    summary[deck_key] = row
    metadata.update(
        {
            "rules_version": int(target_rules_version),
            "summary": summary,
            "accepted": True,
            "training_gate_accepted": True,
            "verified": True,
            "verification_status": "verified_rules_migration",
            "verification_note": (
                f"Paired rules migration evaluation passed for rules v{target_rules_version}."
            ),
            "rules_migration": {
                "source_rules_version": source_rules_version,
                "target_rules_version": int(target_rules_version),
                "evidence_sha256": evidence_sha256,
                "source_model_sha256": str(evidence.get("model_sha256") or ""),
                "rules_source_sha256": str(
                    (evidence.get("rules_source") or {}).get("sha256") or ""
                ),
                "completed_at": int(evidence.get("completed_at") or 0),
            },
        }
    )
    schema["rules_version"] = int(target_rules_version)
    payload["schema"] = schema
    payload["metadata"] = metadata
    return payload

"""Export a completed run into an isolated Godot candidate bundle.

Release runs are the only promotable input.  The explicitly opted-in
``research10`` path exists solely for the fixed 280-game v6 research gate and
cannot enter the authoritative finalization/promotion tools.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.run_store import (  # noqa: E402
    atomic_write_json,
    read_json,
    resolve_within,
    sha256_file,
    update_run,
    utc_now,
)
from engine.ai.dl.encoder import (  # noqa: E402
    ACTION_NUMERIC_SIZE,
    CARD_IDENTITY_MODE,
    CARD_VOCAB_SIZE,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
)
from engine.ai.dl.production_contract import preset_for  # noqa: E402
from scripts.export_onnx_models import (  # noqa: E402
    _assert_export_environment,
    export_all,
)


def _deep_model_contract(
    run: dict[str, Any],
    runtime: dict[str, Any],
    decks: list[str],
) -> dict[str, Any]:
    rows = dict(runtime.get("models") or {})
    if set(rows) != set(decks):
        raise RuntimeError("Candidate runtime model set is incomplete")
    configs = [dict(rows[deck].get("model_config") or {}) for deck in decks]
    if not configs or any(config != configs[0] for config in configs[1:]):
        raise RuntimeError("Candidate model configurations are not identical")
    config = configs[0]
    variant = str((run.get("config") or {}).get("model_variant", ""))
    expected_cross_attention = variant == "v6_cross_attention"
    if (
        variant not in {"v6_pooled", "v6_cross_attention"}
        or bool(config.get("candidate_cross_attention"))
        != expected_cross_attention
        or int(config.get("state_numeric_size", 0)) != STATE_NUMERIC_SIZE
        or int(config.get("state_card_slots", 0)) != STATE_CARD_SLOTS
        or int(config.get("action_numeric_size", 0)) != ACTION_NUMERIC_SIZE
        or int(config.get("card_bucket_count", 0))
        != CARD_VOCAB_SIZE
        or int(config.get("card_embed_dim", 0)) != 32
        or int(config.get("hidden_size", 0)) != 384
        or int(config.get("attention_heads", 0)) != 4
        or int(config.get("candidate_cross_attention_heads", 0)) != 4
        or not bool(config.get("choice_head_enabled"))
        or not bool(config.get("use_attention"))
        or not bool(config.get("use_slot_embeddings"))
        or not bool(config.get("use_token_type_embeddings"))
        or str(config.get("state_norm", "")) != "layer"
        or int(config.get("deck_embed_dim", -1)) != 0
        or int(config.get("num_decks", 0)) != 10
        or str(config.get("card_identity_mode", ""))
        != CARD_IDENTITY_MODE
    ):
        raise RuntimeError("Candidate model configuration is incompatible")
    checkpoint_versions = {
        int(dict(rows[deck]).get("checkpoint_version", 0))
        for deck in decks
    }
    encoder_versions = {
        int(dict(rows[deck]).get("encoder_version", 0))
        for deck in decks
    }
    if len(checkpoint_versions) != 1 or len(encoder_versions) != 1:
        raise RuntimeError("Candidate model schema versions are inconsistent")
    return {
        "variant": variant,
        "checkpoint_version": checkpoint_versions.pop(),
        "encoder_version": encoder_versions.pop(),
        "card_vocab_version": int(runtime.get("card_vocab_version", 0)),
        "card_vocab_size": int(runtime.get("card_vocab_size", 0)),
        "card_vocab_sha256": str(runtime.get("card_vocab_sha256", "")),
        "config": config,
    }


def _file_rows(root: Path, paths: list[Path]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for path in paths:
        result[str(path.relative_to(root).as_posix())] = {
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
        }
    return result


def prepare_candidate(
    run_dir: Path,
    *,
    allow_research: bool = False,
) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    run = read_json(run_dir / "run.json")
    preset = str(run.get("preset", ""))
    research_only = preset == "research10"
    if preset != "release" and not (allow_research and research_only):
        raise RuntimeError(
            "Only a fixed Release run can create a candidate bundle unless "
            "--allow-research is explicitly used for research10"
        )
    if research_only and bool(run.get("promotable")):
        raise RuntimeError("A research10 run must remain non-promotable")
    if preset == "release" and not bool(run.get("promotable")):
        raise RuntimeError("A fixed Release run must remain promotable")
    if str(run.get("status", "")) not in {"completed", "exporting_candidate"}:
        raise RuntimeError("Training must complete before candidate export")
    expected_preset = preset_for(preset)
    config = dict(run.get("config") or {})
    expected_fields = {
        "decks": list(expected_preset.decks),
        "seed": 17,
        "teacher_games": expected_preset.teacher_games,
        "dagger_games": expected_preset.dagger_games,
        "generations": expected_preset.generations,
        "games_per_matchup": expected_preset.games_per_matchup,
        "current_generation_games": expected_preset.current_generation_games,
        "historical_games": expected_preset.historical_games,
        "mcts_simulations": expected_preset.mcts_simulations,
        "rollout_workers": expected_preset.rollout_workers,
        "use_amp": expected_preset.use_amp,
        "device": expected_preset.device,
    }
    if any(config.get(key) != value for key, value in expected_fields.items()):
        raise RuntimeError(
            f"{preset} run does not match the fixed v6 training contract"
        )
    release = read_json(REPO_ROOT / "release_manifest.json")
    decks = [str(item) for item in release.get("release_decks", [])]
    if len(decks) != int(release.get("model_count", 0)):
        raise RuntimeError("Release model set is invalid")
    model_root = run_dir / "models"
    for deck in decks:
        for suffix in (".pt", ".json"):
            if not (model_root / f"{deck}{suffix}").is_file():
                raise RuntimeError(f"Candidate model artifact is missing: {deck}{suffix}")

    _assert_export_environment()
    stage_data = run_dir / "staging" / "godot" / "data"
    onnx_root = stage_data / "ai_models"
    runtime = export_all(
        onnx_root,
        checkpoint_root=model_root,
        tolerance=1e-4,
        candidate=True,
    )
    evidence_sha = str(
        dict(runtime.get("deep_planner") or {}).get("evidence_sha256", "")
    ).lower()
    if len(evidence_sha) != 64:
        raise RuntimeError("Candidate bundle evidence hash is invalid")
    deep_model = _deep_model_contract(run, runtime, decks)

    candidate_release = json.loads(json.dumps(release))
    candidate_release["deep_runtime_enabled"] = True
    candidate_release["compatible_model_count"] = len(decks)
    candidate_release["legacy_model_count"] = 0
    candidate_release["candidate_evaluation"] = True
    candidate_release["deep_planner"] = dict(runtime["deep_planner"])
    candidate_release["deep_model"] = deep_model
    release_path = stage_data / "release_manifest.json"
    atomic_write_json(release_path, candidate_release)
    vocab_path = stage_data / "ai_card_vocab.json"
    atomic_write_json(
        vocab_path,
        read_json(REPO_ROOT / "python" / "data" / "ai_card_vocab.json"),
    )

    artifact_paths = [
        release_path,
        vocab_path,
        stage_data / "ai_models_runtime.json",
        *[model_root / f"{deck}.pt" for deck in decks],
        *[model_root / f"{deck}.json" for deck in decks],
        *[onnx_root / f"{deck}.onnx" for deck in decks],
    ]
    manifest = {
        "format_version": 1,
        "kind": "hybrid_candidate_bundle_v1",
        "run_id": str(run["run_id"]),
        "source_preset": preset,
        "research_only": research_only,
        "created_at": utc_now(),
        "candidate_evidence_sha256": evidence_sha,
        "deep_planner": runtime["deep_planner"],
        "deep_model": deep_model,
        "release_decks": decks,
        "files": _file_rows(run_dir, artifact_paths),
        "evaluation_status": "pending",
        "promotable": False,
    }
    manifest_path = run_dir / "staging" / "candidate_manifest.json"
    atomic_write_json(manifest_path, manifest)
    manifest_sha = sha256_file(manifest_path)
    update_run(
        run_dir,
        candidate_stage={
            "status": (
                "ready_for_research_godot_evaluation"
                if research_only
                else "ready_for_godot_evaluation"
            ),
            "source_preset": preset,
            "research_only": research_only,
            "manifest_path": str(manifest_path.relative_to(run_dir).as_posix()),
            "manifest_sha256": manifest_sha,
            "runtime_manifest_path": str(
                (stage_data / "ai_models_runtime.json").relative_to(run_dir).as_posix()
            ),
            "release_manifest_path": str(
                release_path.relative_to(run_dir).as_posix()
            ),
            "candidate_evidence_sha256": evidence_sha,
        },
    )
    return {
        "run_id": run["run_id"],
        "candidate_manifest": str(manifest_path),
        "candidate_manifest_sha256": manifest_sha,
        "candidate_evidence_sha256": evidence_sha,
        "models": len(decks),
        "research_only": research_only,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument(
        "--allow-research",
        action="store_true",
        help=(
            "Allow a completed, non-promotable research10 run to create an "
            "isolated evaluation bundle"
        ),
    )
    args = parser.parse_args()
    result = prepare_candidate(
        args.run_dir,
        allow_research=bool(args.allow_research),
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    os.chdir(PYTHON_ROOT)
    raise SystemExit(main())

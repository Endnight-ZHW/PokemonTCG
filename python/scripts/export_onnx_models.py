"""Transactionally export the universal AlphaZero v2 checkpoint to ONNX."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import numpy as np


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from data.ai_card_vocab import (  # noqa: E402
    CARD_VOCAB_VERSION,
    card_vocab_sha256,
    card_vocab_size,
)
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION  # noqa: E402
from engine.ai.dl.model_v2 import load_checkpoint, torch  # noqa: E402
from engine.ai.dl.v2_contract import (  # noqa: E402
    CHECKPOINT_VERSION,
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    MODEL_VARIANT,
    ONNX_INPUT_NAMES,
    ONNX_OUTPUT_NAMES,
    RELEASE_DECKS,
    RUNTIME_MANIFEST_FORMAT_VERSION,
    contract_dict,
)


RELEASE_MANIFEST = json.loads(
    (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
)
OPSET = int(RELEASE_MANIFEST["onnx"]["opset"])
ORT_VERSION = str(RELEASE_MANIFEST["onnx"]["runtime_version"])
if tuple(RELEASE_MANIFEST["release_decks"]) != RELEASE_DECKS:
    raise RuntimeError("release_deck_contract_mismatch")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _dummy_inputs(batch: int = 2, candidates: int = 5):
    return (
        torch.zeros(batch, 128, dtype=torch.float32),
        torch.zeros(batch, 128, 16, dtype=torch.float32),
        torch.zeros(batch, 128, dtype=torch.int64),
        torch.zeros(batch, 128, 4, dtype=torch.int64),
        torch.zeros(batch, candidates, 32, dtype=torch.float32),
        torch.zeros(batch, candidates, dtype=torch.int64),
        torch.ones(batch, candidates, dtype=torch.int64),
        torch.zeros(batch, candidates, 4, dtype=torch.int64),
        torch.ones(batch, candidates, dtype=torch.bool),
        torch.zeros(batch, dtype=torch.int64),
        torch.ones(batch, dtype=torch.int64),
    )


def _export(model: Any, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    dynamic_axes: dict[str, dict[int, str]] = {
        name: {0: "batch"} for name in ONNX_INPUT_NAMES
    }
    for name in (
        "candidate_numeric",
        "candidate_card_ids",
        "candidate_type_ids",
        "candidate_refs",
        "candidate_mask",
    ):
        dynamic_axes[name][1] = "candidates"
    dynamic_axes["policy_logits"] = {0: "batch", 1: "candidates"}
    dynamic_axes["wdl_logits"] = {0: "batch"}
    torch.onnx.export(
        model.cpu().eval(),
        _dummy_inputs(),
        destination,
        input_names=list(ONNX_INPUT_NAMES),
        output_names=list(ONNX_OUTPUT_NAMES),
        dynamic_axes=dynamic_axes,
        opset_version=OPSET,
        do_constant_folding=True,
    )


def _verify(model: Any, path: Path) -> dict[str, float]:
    import onnxruntime as ort

    inputs = _dummy_inputs(batch=3, candidates=7)
    with torch.inference_mode():
        expected = [
            value.detach().cpu().numpy()
            for value in model.cpu().eval()(*inputs)
        ]
    session = ort.InferenceSession(
        str(path),
        providers=["CPUExecutionProvider"],
    )
    actual = session.run(
        list(ONNX_OUTPUT_NAMES),
        {
            name: value.detach().cpu().numpy()
            for name, value in zip(ONNX_INPUT_NAMES, inputs, strict=True)
        },
    )
    maxima = {
        name: float(np.max(np.abs(reference - candidate)))
        for name, reference, candidate in zip(
            ONNX_OUTPUT_NAMES,
            expected,
            actual,
            strict=True,
        )
    }
    if any(not np.isfinite(value) or value > 1e-4 for value in maxima.values()):
        raise RuntimeError(f"onnx_parity_failed:{maxima}")
    return maxima


def _manifest(
    checkpoint: Path,
    onnx_path: Path,
    payload: dict[str, Any],
    parity: dict[str, float],
    evidence_sha256: str,
) -> dict[str, Any]:
    metadata = dict(payload.get("metadata") or {})
    return {
        "format_version": RUNTIME_MANIFEST_FORMAT_VERSION,
        "inference_format": "onnx-fp32",
        "opset": OPSET,
        "onnx_runtime_version": ORT_VERSION,
        "input_names": list(ONNX_INPUT_NAMES),
        "output_names": list(ONNX_OUTPUT_NAMES),
        "contract": contract_dict(),
        "compatibility_bridge": {
            "version": 2,
            "python_rules_version": RULES_SCHEMA_VERSION,
            "python_action_version": ACTION_SCHEMA_VERSION,
            "python_encoder_version": ENCODER_SCHEMA_VERSION,
            "godot_rules_version": RELEASE_MANIFEST["schemas"]["godot_rules"],
            "godot_action_version": RELEASE_MANIFEST["schemas"]["godot_actions"],
        },
        "deep_planner": {
            "planner_id": "infoset_puct_v2",
            "schema_version": DEEP_PLANNER_VERSION,
            "leaf_evaluator": "neural_wdl",
            "value_head_mode": "search_backup",
            "challenge_prior_weight": 0.0,
            "full_turn_rollout": False,
            "c_puct": 1.4,
            "training_simulations": 128,
            "evidence_sha256": str(evidence_sha256).lower(),
        },
        "models": {
            "universal": {
                "model_variant": MODEL_VARIANT,
                "checkpoint_version": CHECKPOINT_VERSION,
                "encoder_version": ENCODER_SCHEMA_VERSION,
                "planner_version": DEEP_PLANNER_VERSION,
                "checkpoint_sha256": _sha256(checkpoint),
                "onnx_path": "res://data/ai_models/universal.onnx",
                "onnx_sha256": _sha256(onnx_path),
                "onnx_size": onnx_path.stat().st_size,
                "parity_max_abs_error": parity,
                "model_config": dict(payload.get("model_config") or {}),
                "metadata": {
                    "generation": metadata.get("generation"),
                    "accepted": bool(metadata.get("accepted")),
                },
            }
        },
        "deck_routes": {
            deck: "universal" for deck in RELEASE_DECKS
        },
        "card_vocab_version": CARD_VOCAB_VERSION,
        "card_vocab_size": card_vocab_size(),
        "card_vocab_sha256": card_vocab_sha256(),
    }


def export_universal(
    checkpoint: Path,
    output: Path,
    manifest_path: Path,
    *,
    evidence_sha256: str,
) -> dict[str, Any]:
    started = time.perf_counter()
    model, payload = load_checkpoint(str(checkpoint), "cpu")
    transaction = Path(
        tempfile.mkdtemp(prefix="alphazero-v2-onnx-", dir=output.parent)
    )
    try:
        staged_onnx = transaction / output.name
        staged_manifest = transaction / manifest_path.name
        _export(model, staged_onnx)
        parity = _verify(model, staged_onnx)
        manifest = _manifest(
            checkpoint,
            staged_onnx,
            payload,
            parity,
            evidence_sha256,
        )
        manifest["elapsed_seconds"] = round(
            time.perf_counter() - started,
            3,
        )
        staged_manifest.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staged_onnx, output)
        os.replace(staged_manifest, manifest_path)
        return manifest
    finally:
        shutil.rmtree(transaction, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=PYTHON_ROOT / "data" / "ai_models" / "universal.pt",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "godot" / "data" / "ai_models" / "universal.onnx",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=REPO_ROOT / "godot" / "data" / "ai_models_runtime.json",
    )
    parser.add_argument("--evidence-sha256", default="")
    args = parser.parse_args(argv)
    manifest = export_universal(
        args.checkpoint,
        args.output,
        args.manifest,
        evidence_sha256=args.evidence_sha256,
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

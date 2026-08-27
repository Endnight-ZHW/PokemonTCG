from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np

RESEARCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = RESEARCH_ROOT / "python"
PRODUCT_PYTHON_ROOT = REPO_ROOT / "python"
for import_root in (PYTHON_ROOT, PRODUCT_PYTHON_ROOT):
    if str(import_root) not in sys.path:
        sys.path.insert(0, str(import_root))

from deep_ai.model_v3 import create_model  # noqa: E402
from deep_ai.v3_contract import (  # noqa: E402
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    CHECKPOINT_VERSION,
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
    MODEL_VARIANT,
    ONNX_INPUT_NAMES,
    ONNX_OUTPUT_NAMES,
    PLANNER_ID,
    RELEASE_DECKS,
    RUNTIME_MANIFEST_FORMAT_VERSION,
    STATE_GLOBAL_SIZE,
    contract_dict,
)


RELEASE_MANIFEST = json.loads(
    (RESEARCH_ROOT / "research_manifest.json").read_text(encoding="utf-8")
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_bundle(path: Path, device: str = "cpu"):
    import torch
    from safetensors.torch import load_file

    root = path if path.is_dir() else path.parent
    state_path = root / "state.json"
    model_path = root / "model.safetensors"
    bundle_path = root / "bundle.json"
    if (
        not state_path.is_file()
        or not model_path.is_file()
        or not bundle_path.is_file()
    ):
        raise ValueError("v3_checkpoint_bundle_required")
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    if (
        bundle.get("schema") != "ptcg_deep_learner_v3"
        or int(bundle.get("checkpoint_version", 0)) != CHECKPOINT_VERSION
    ):
        raise ValueError("incompatible_v2_checkpoint_use_v3_fresh_run")
    for name, digest in dict(bundle.get("files", {})).items():
        artifact = (root / name).resolve()
        if (
            artifact.parent != root.resolve()
            or not artifact.is_file()
            or _sha256(artifact) != str(digest)
        ):
            raise ValueError(f"v3_checkpoint_file_hash_mismatch:{name}")
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if (
        int(state.get("checkpoint_version", 0)) != CHECKPOINT_VERSION
        or int(state.get("encoder_version", 0)) != ENCODER_SCHEMA_VERSION
        or state.get("model_variant") != MODEL_VARIANT
    ):
        raise ValueError("incompatible_v2_checkpoint_use_v3_fresh_run")
    model = create_model(**dict(state.get("model_config", {})))
    model.load_state_dict(load_file(str(model_path), device=device), strict=True)
    model.to(device).eval()
    return model, state


def _inputs(batch: int = 2, candidates: int = 7):
    import torch

    return (
        torch.zeros(batch, STATE_GLOBAL_SIZE),
        torch.zeros(batch, ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
        torch.zeros(batch, ENTITY_SLOTS, dtype=torch.long),
        torch.zeros(batch, ENTITY_SLOTS, ENTITY_TYPE_FIELDS, dtype=torch.long),
        torch.ones(batch, ENTITY_SLOTS, dtype=torch.bool),
        torch.zeros(batch, candidates, CANDIDATE_NUMERIC_SIZE),
        torch.zeros(batch, candidates, dtype=torch.long),
        torch.ones(batch, candidates, dtype=torch.long),
        torch.zeros(batch, candidates, CANDIDATE_REF_FIELDS, dtype=torch.long),
        torch.ones(batch, candidates, dtype=torch.bool),
        torch.zeros(batch, dtype=torch.long),
        torch.ones(batch, dtype=torch.long),
    )


def export_v3(
    checkpoint: Path,
    output: Path,
    manifest_path: Path,
    *,
    evidence_sha256: str = "",
) -> dict[str, Any]:
    import onnxruntime as ort
    import torch

    model, _state = load_bundle(checkpoint)
    output.parent.mkdir(parents=True, exist_ok=True)
    example = _inputs()
    dynamic_axes = {
        name: {0: "batch"}
        for name in ONNX_INPUT_NAMES
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
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=output.name + ".",
        suffix=".tmp",
        dir=output.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        torch.onnx.export(
            model,
            example,
            str(temporary),
            input_names=list(ONNX_INPUT_NAMES),
            output_names=list(ONNX_OUTPUT_NAMES),
            dynamic_axes=dynamic_axes,
            opset_version=17,
            do_constant_folding=True,
        )
        os.replace(temporary, output)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()
    session = ort.InferenceSession(
        str(output),
        providers=["CPUExecutionProvider"],
    )
    numpy_inputs = {
        name: value.detach().cpu().numpy()
        for name, value in zip(ONNX_INPUT_NAMES, example, strict=True)
    }
    with torch.inference_mode():
        expected = [value.detach().cpu().numpy() for value in model(*example)]
    actual = session.run(list(ONNX_OUTPUT_NAMES), numpy_inputs)
    parity = {
        name: float(np.max(np.abs(left - right)))
        for name, left, right in zip(
            ONNX_OUTPUT_NAMES, expected, actual, strict=True
        )
    }
    if max(parity.values(), default=0.0) > 1e-4:
        raise RuntimeError(f"v3_onnx_parity_failed:{parity}")
    planner = {
        "planner_id": PLANNER_ID,
        "schema_version": DEEP_PLANNER_VERSION,
        "c_puct": 1.4,
        "training_simulations": 128,
        "challenge_prior_weight": 0.0,
        "full_turn_rollout": False,
        "leaf_evaluator": "neural_wdl",
        "value_head_mode": "search_backup",
        "evidence_sha256": str(evidence_sha256).lower(),
    }
    manifest = {
        "format_version": RUNTIME_MANIFEST_FORMAT_VERSION,
        "opset": 17,
        "onnx_runtime_version": ort.__version__,
        "contract": contract_dict(),
        "source_schemas": {
            "python_rules_version": RELEASE_MANIFEST["schemas"]["python_rules"],
            "python_action_version": RELEASE_MANIFEST["schemas"]["python_actions"],
            "python_encoder_version": ENCODER_SCHEMA_VERSION,
        },
        "deep_planner": planner,
        "deck_routes": {deck: "universal" for deck in RELEASE_DECKS},
        "models": {
            "universal": {
                "onnx_path": "res://data/ai_models/universal.onnx",
                "onnx_sha256": _sha256(output),
                "onnx_size": output.stat().st_size,
                "model_variant": MODEL_VARIANT,
                "checkpoint_version": CHECKPOINT_VERSION,
                "encoder_version": ENCODER_SCHEMA_VERSION,
                "planner_version": DEEP_PLANNER_VERSION,
                "parity_max_abs_error": parity,
            }
        },
        "input_names": list(ONNX_INPUT_NAMES),
        "output_names": list(ONNX_OUTPUT_NAMES),
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=manifest_path.name + ".",
        suffix=".tmp",
        dir=manifest_path.parent,
    )
    try:
        with os.fdopen(
            descriptor, "w", encoding="utf-8", newline="\n"
        ) as handle:
            json.dump(
                manifest,
                handle,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, manifest_path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary_name)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--evidence-sha256", default="")
    args = parser.parse_args()
    result = export_v3(
        args.checkpoint.resolve(),
        args.output.resolve(),
        args.manifest.resolve(),
        evidence_sha256=args.evidence_sha256,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

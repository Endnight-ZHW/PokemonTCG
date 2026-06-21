"""Export the eight accepted Deep AI checkpoints to deterministic FP32 ONNX."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn

from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_BUCKET_COUNT,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
)
from engine.ai.dl.model import load_checkpoint
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION

DECK_KEYS = (
    "fire",
    "water",
    "psychic",
    "lightning",
    "fighting",
    "colorless",
    "dragon",
    "grass",
)
ONNX_OPSET = 17
ONNX_RUNTIME_VERSION = "1.26.0"
COMPATIBILITY_BRIDGE_VERSION = 1
INPUT_NAMES = (
    "state_numeric",
    "state_cards",
    "action_numeric",
    "action_cards",
    "choice_numeric",
    "choice_cards",
)
OUTPUT_NAMES = ("action_logits", "state_value", "choice_logits")


class ExportModel(nn.Module):
    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model

    def forward(
        self,
        state_numeric,
        state_cards,
        action_numeric,
        action_cards,
        choice_numeric,
        choice_cards,
    ):
        action_logits, value = self.model(
            state_numeric,
            state_cards,
            action_numeric,
            action_cards,
        )
        choice_logits = self.model.score_choices(
            state_numeric,
            state_cards,
            choice_numeric,
            choice_cards,
        )
        return action_logits, value, choice_logits


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _inputs(seed: int, action_count: int, choice_count: int) -> tuple[torch.Tensor, ...]:
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    state_numeric = torch.randn((1, STATE_NUMERIC_SIZE), generator=generator)
    state_cards = torch.randint(
        0,
        CARD_BUCKET_COUNT,
        (1, STATE_CARD_SLOTS),
        generator=generator,
        dtype=torch.int64,
    )
    state_cards[0, -8:] = 0
    action_numeric = torch.randn(
        (1, action_count, ACTION_NUMERIC_SIZE),
        generator=generator,
    )
    action_cards = torch.randint(
        0,
        CARD_BUCKET_COUNT,
        (1, action_count),
        generator=generator,
        dtype=torch.int64,
    )
    choice_numeric = torch.randn(
        (1, choice_count, ACTION_NUMERIC_SIZE),
        generator=generator,
    )
    choice_cards = torch.randint(
        0,
        CARD_BUCKET_COUNT,
        (1, choice_count),
        generator=generator,
        dtype=torch.int64,
    )
    return (
        state_numeric,
        state_cards,
        action_numeric,
        action_cards,
        choice_numeric,
        choice_cards,
    )


def _export_one(checkpoint: Path, output: Path) -> tuple[dict[str, Any], ExportModel]:
    model, payload = load_checkpoint(str(checkpoint), "cpu")
    model.eval()
    wrapper = ExportModel(model).eval()
    if hasattr(torch.backends, "mha") and hasattr(torch.backends.mha, "set_fastpath_enabled"):
        torch.backends.mha.set_fastpath_enabled(False)
    dummy = _inputs(20260621, 3, 4)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        wrapper,
        dummy,
        str(output),
        input_names=list(INPUT_NAMES),
        output_names=list(OUTPUT_NAMES),
        dynamic_axes={
            "action_numeric": {1: "action_count"},
            "action_cards": {1: "action_count"},
            "choice_numeric": {1: "choice_count"},
            "choice_cards": {1: "choice_count"},
            "action_logits": {1: "action_count"},
            "choice_logits": {1: "choice_count"},
        },
        opset_version=ONNX_OPSET,
        do_constant_folding=True,
    )
    checked = onnx.load(str(output))
    onnx.checker.check_model(checked)
    return payload, wrapper


def _verify_one(
    wrapper: ExportModel,
    output: Path,
    *,
    tolerance: float,
) -> dict[str, float]:
    session = ort.InferenceSession(str(output), providers=["CPUExecutionProvider"])
    maxima = {name: 0.0 for name in OUTPUT_NAMES}
    for index, (actions, choices) in enumerate(((1, 1), (3, 5), (17, 11))):
        tensors = _inputs(7701 + index, actions, choices)
        with torch.no_grad():
            expected = wrapper(*tensors)
        actual = session.run(
            list(OUTPUT_NAMES),
            {
                name: tensor.detach().cpu().numpy()
                for name, tensor in zip(INPUT_NAMES, tensors)
            },
        )
        for name, left, right in zip(OUTPUT_NAMES, expected, actual):
            difference = float(
                np.max(np.abs(left.detach().cpu().numpy() - np.asarray(right)))
            )
            maxima[name] = max(maxima[name], difference)
            if difference > tolerance:
                raise RuntimeError(
                    f"{output.name} {name} parity error {difference:.8g} > {tolerance}"
                )
    return maxima


def export_all(
    output_root: Path,
    *,
    checkpoint_root: Path,
    tolerance: float = 1e-4,
) -> dict[str, Any]:
    started = time.perf_counter()
    model_rows: dict[str, Any] = {}
    for deck_key in DECK_KEYS:
        checkpoint = checkpoint_root / f"{deck_key}.pt"
        if not checkpoint.is_file():
            raise FileNotFoundError(checkpoint)
        onnx_path = output_root / f"{deck_key}.onnx"
        payload, wrapper = _export_one(checkpoint, onnx_path)
        maxima = _verify_one(wrapper, onnx_path, tolerance=tolerance)
        schema = dict(payload.get("schema") or {})
        model_rows[deck_key] = {
            "deck_key": deck_key,
            "checkpoint_version": int(payload.get("version") or 0),
            "checkpoint_sha256": _sha256(checkpoint),
            "onnx_path": f"res://data/ai_models/{deck_key}.onnx",
            "onnx_size": onnx_path.stat().st_size,
            "onnx_sha256": _sha256(onnx_path),
            "opset": ONNX_OPSET,
            "rules_version": int(schema.get("rules_version") or 0),
            "action_version": int(schema.get("action_version") or 0),
            "encoder_version": int(schema.get("encoder_version") or 0),
            "planner_version": PLANNER_SCHEMA_VERSION,
            "parity_max_abs_error": maxima,
        }
    manifest = {
        "format_version": 2,
        "inference_format": "onnx-fp32",
        "onnx_runtime_version": ONNX_RUNTIME_VERSION,
        "execution_provider": "CPUExecutionProvider",
        "opset": ONNX_OPSET,
        "search_simulations": 256,
        "watchdog_seconds": 8.0,
        "state_numeric_size": STATE_NUMERIC_SIZE,
        "state_card_slots": STATE_CARD_SLOTS,
        "action_numeric_size": ACTION_NUMERIC_SIZE,
        "card_bucket_count": CARD_BUCKET_COUNT,
        "semantic_feature_sizes": {
            "known_card": 53,
            "missing_card_legacy": 48,
        },
        "input_names": list(INPUT_NAMES),
        "output_names": list(OUTPUT_NAMES),
        "compatibility_bridge": {
            "version": COMPATIBILITY_BRIDGE_VERSION,
            "python_rules_version": RULES_SCHEMA_VERSION,
            "python_action_version": ACTION_SCHEMA_VERSION,
            "python_encoder_version": ENCODER_SCHEMA_VERSION,
            "godot_rules_version": 3,
            "godot_action_version": 3,
        },
        "models": model_rows,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }
    manifest_path = output_root.parent / "ai_models_runtime.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-root",
        type=Path,
        default=REPO_ROOT / "godot_client" / "data" / "ai_models",
    )
    parser.add_argument(
        "--checkpoint-root",
        type=Path,
        default=REPO_ROOT / "data" / "ai_models",
    )
    parser.add_argument("--tolerance", type=float, default=1e-4)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        with __import__("tempfile").TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            generated = export_all(
                temp_root / "ai_models",
                checkpoint_root=args.checkpoint_root,
                tolerance=args.tolerance,
            )
            current_manifest = args.output_root.parent / "ai_models_runtime.json"
            if not current_manifest.is_file():
                raise SystemExit("ONNX runtime manifest is missing.")
            current = json.loads(current_manifest.read_text(encoding="utf-8"))
            generated.pop("elapsed_seconds", None)
            current.pop("elapsed_seconds", None)
            if generated != current:
                raise SystemExit("Committed ONNX manifest is stale.")
            for deck_key in DECK_KEYS:
                generated_path = temp_root / "ai_models" / f"{deck_key}.onnx"
                current_path = args.output_root / f"{deck_key}.onnx"
                if not current_path.is_file() or _sha256(generated_path) != _sha256(current_path):
                    raise SystemExit(f"Committed ONNX model is stale: {deck_key}")
        print("ONNX models are current and parity-verified.")
        return 0
    manifest = export_all(
        args.output_root,
        checkpoint_root=args.checkpoint_root,
        tolerance=args.tolerance,
    )
    print(
        json.dumps(
            {
                "models": len(manifest["models"]),
                "elapsed_seconds": manifest["elapsed_seconds"],
                "max_error": max(
                    max(row["parity_max_abs_error"].values())
                    for row in manifest["models"].values()
                ),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

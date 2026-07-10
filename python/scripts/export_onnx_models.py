"""Export the release Deep AI checkpoints to deterministic FP32 ONNX."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
RELEASE_MANIFEST = json.loads(
    (REPO_ROOT / "release_manifest.json").read_text(encoding="utf-8")
)
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn

from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_BUCKET_COUNT,
    CARD_SEMANTIC_SIZE,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
)
from engine.ai.dl.model import CHECKPOINT_VERSION, load_checkpoint
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION

DECK_KEYS = tuple(str(key) for key in RELEASE_MANIFEST["release_decks"])
if len(DECK_KEYS) != int(RELEASE_MANIFEST["model_count"]) or len(set(DECK_KEYS)) != len(DECK_KEYS):
    raise RuntimeError("release_manifest.json has an invalid release model set")
ONNX_OPSET = int(RELEASE_MANIFEST["onnx"]["opset"])
ONNX_RUNTIME_VERSION = str(RELEASE_MANIFEST["onnx"]["runtime_version"])
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


def _assert_export_environment() -> None:
    """Fail before export when the reproducible toolchain is not active."""
    lock = json.loads(
        (REPO_ROOT / "tools" / "toolchain.lock.json").read_text(encoding="utf-8")
    )["python"]
    actual = {
        "version": platform.python_version(),
        "numpy": np.__version__,
        "torch": torch.__version__.split("+", 1)[0],
        "onnx": onnx.__version__,
        "onnxruntime": ort.__version__,
    }
    mismatches = [
        f"{name}={actual[name]} (expected {lock[name]})"
        for name in actual
        if str(actual[name]) != str(lock[name])
    ]
    if mismatches:
        raise RuntimeError(
            "ONNX export requires the locked environment: " + "; ".join(mismatches)
        )


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


def _inputs(
    seed: int,
    action_count: int,
    choice_count: int,
    *,
    empty_state_cards: bool = False,
) -> tuple[torch.Tensor, ...]:
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
    if empty_state_cards:
        state_cards.zero_()
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


def _export_one(
    checkpoint: Path,
    output: Path,
    *,
    loaded: tuple[nn.Module, dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], ExportModel]:
    model, payload = loaded if loaded is not None else load_checkpoint(str(checkpoint), "cpu")
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
    scenarios = ((1, 1, False), (3, 5, False), (17, 11, False), (1, 1, True))
    for index, (actions, choices, empty_state_cards) in enumerate(scenarios):
        tensors = _inputs(
            7701 + index,
            actions,
            choices,
            empty_state_cards=empty_state_cards,
        )
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
            left_array = left.detach().cpu().numpy()
            right_array = np.asarray(right)
            if not np.isfinite(left_array).all() or not np.isfinite(right_array).all():
                raise RuntimeError(f"{output.name} {name} produced non-finite output")
            difference = float(
                np.max(np.abs(left_array - right_array))
            )
            maxima[name] = max(maxima[name], difference)
            if difference > tolerance:
                raise RuntimeError(
                    f"{output.name} {name} parity error {difference:.8g} > {tolerance}"
                )
    return maxima


def _preflight_release_checkpoints(
    checkpoint_root: Path,
) -> dict[str, tuple[nn.Module, dict[str, Any]]]:
    """Load and validate the complete release set before writing ONNX files."""
    loaded: dict[str, tuple[nn.Module, dict[str, Any]]] = {}
    errors: list[str] = []
    for deck_key in DECK_KEYS:
        checkpoint = checkpoint_root / f"{deck_key}.pt"
        try:
            model, payload = load_checkpoint(str(checkpoint), "cpu")
        except Exception as exc:
            errors.append(f"{deck_key}:unloadable:{exc}")
            continue
        schema = dict(payload.get("schema") or {})
        metadata = dict(payload.get("metadata") or {})
        deck_errors: list[str] = []
        if int(payload.get("version") or 0) != CHECKPOINT_VERSION:
            deck_errors.append(
                f"checkpoint_version={int(payload.get('version') or 0)}"
            )
        expected_schema = {
            "rules_version": RULES_SCHEMA_VERSION,
            "action_version": ACTION_SCHEMA_VERSION,
            "encoder_version": ENCODER_SCHEMA_VERSION,
        }
        for key, expected in expected_schema.items():
            if int(schema.get(key) or 0) != int(expected):
                deck_errors.append(f"{key}={int(schema.get(key) or 0)}")
        if str(metadata.get("deck") or "") != deck_key:
            deck_errors.append(f"deck={metadata.get('deck')!r}")
        if not bool(metadata.get("accepted")):
            deck_errors.append("not_accepted")
        if not bool(metadata.get("verified")):
            deck_errors.append("not_verified")
        if int(metadata.get("planner_version") or 0) != PLANNER_SCHEMA_VERSION:
            deck_errors.append(
                f"planner_version={int(metadata.get('planner_version') or 0)}"
            )
        if deck_errors:
            errors.append(f"{deck_key}:" + ",".join(deck_errors))
        else:
            loaded[deck_key] = (model, payload)
    if errors:
        raise ValueError("Invalid release checkpoint(s): " + "; ".join(errors))
    return loaded


def export_all(
    output_root: Path,
    *,
    checkpoint_root: Path,
    tolerance: float = 1e-4,
) -> dict[str, Any]:
    started = time.perf_counter()
    missing_checkpoints = [
        checkpoint_root / f"{deck_key}.pt"
        for deck_key in DECK_KEYS
        if not (checkpoint_root / f"{deck_key}.pt").is_file()
    ]
    if missing_checkpoints:
        missing = ", ".join(str(path) for path in missing_checkpoints)
        raise FileNotFoundError(f"Missing release checkpoint(s): {missing}")
    loaded_checkpoints = _preflight_release_checkpoints(checkpoint_root)
    output_root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".onnx_export-",
        dir=output_root.parent,
    ) as temp_dir:
        transaction_root = Path(temp_dir)
        staged_root = transaction_root / "ai_models"
        staged_manifest = transaction_root / "ai_models_runtime.json"
        model_rows: dict[str, Any] = {}
        for deck_key in DECK_KEYS:
            checkpoint = checkpoint_root / f"{deck_key}.pt"
            onnx_path = staged_root / f"{deck_key}.onnx"
            payload, wrapper = _export_one(
                checkpoint,
                onnx_path,
                loaded=loaded_checkpoints[deck_key],
            )
            maxima = _verify_one(wrapper, onnx_path, tolerance=tolerance)
            schema = dict(payload.get("schema") or {})
            model_rows[deck_key] = {
                "deck_key": deck_key,
                "checkpoint_version": int(payload.get("version") or 0),
                "choice_head_enabled": bool(
                    (payload.get("model_config") or {}).get(
                        "choice_head_enabled",
                        payload.get("choice_head_enabled", False),
                    )
                ),
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
            "search_simulations": int(RELEASE_MANIFEST["onnx"]["search_simulations"]),
            "watchdog_seconds": float(RELEASE_MANIFEST["onnx"]["watchdog_seconds"]),
            "state_numeric_size": STATE_NUMERIC_SIZE,
            "state_card_slots": STATE_CARD_SLOTS,
            "action_numeric_size": ACTION_NUMERIC_SIZE,
            "card_bucket_count": CARD_BUCKET_COUNT,
            "semantic_feature_sizes": {
                "known_card": CARD_SEMANTIC_SIZE,
                "missing_card": CARD_SEMANTIC_SIZE,
            },
            "input_names": list(INPUT_NAMES),
            "output_names": list(OUTPUT_NAMES),
            "compatibility_bridge": {
                "version": COMPATIBILITY_BRIDGE_VERSION,
                "python_rules_version": RULES_SCHEMA_VERSION,
                "python_action_version": ACTION_SCHEMA_VERSION,
                "python_encoder_version": ENCODER_SCHEMA_VERSION,
                "godot_rules_version": int(
                    RELEASE_MANIFEST["schemas"]["godot_rules"]
                ),
                "godot_action_version": int(
                    RELEASE_MANIFEST["schemas"]["godot_actions"]
                ),
            },
            "models": model_rows,
            "elapsed_seconds": round(time.perf_counter() - started, 3),
        }
        staged_manifest.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        # Only replace the live runtime bundle after every model has exported
        # and passed parity.  Restore the previous bundle on ordinary install
        # or verification failures.
        output_root.mkdir(parents=True, exist_ok=True)
        backup_root = transaction_root / "backup"
        backup_root.mkdir()
        manifest_path = output_root.parent / "ai_models_runtime.json"
        files = [
            (
                staged_root / f"{deck_key}.onnx",
                output_root / f"{deck_key}.onnx",
                backup_root / f"{deck_key}.onnx",
            )
            for deck_key in DECK_KEYS
        ]
        files.append((staged_manifest, manifest_path, backup_root / "ai_models_runtime.json"))
        backed_up: list[tuple[Path, Path]] = []
        installed: list[Path] = []
        try:
            for _staged, target, backup in files:
                if target.exists():
                    os.replace(target, backup)
                    backed_up.append((backup, target))
            for staged, target, _backup in files:
                os.replace(staged, target)
                installed.append(target)
            for deck_key, row in model_rows.items():
                if _sha256(output_root / f"{deck_key}.onnx") != row["onnx_sha256"]:
                    raise OSError(f"Installed ONNX checksum mismatch: {deck_key}")
            installed_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if installed_manifest != manifest:
                raise OSError("Installed ONNX manifest verification failed")
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
                    "ONNX export failed and rollback was incomplete: "
                    + "; ".join(rollback_errors)
                ) from None
            raise
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-root",
        type=Path,
        default=REPO_ROOT / "godot" / "data" / "ai_models",
    )
    parser.add_argument(
        "--checkpoint-root",
        type=Path,
        default=PYTHON_ROOT / "data" / "ai_models",
    )
    parser.add_argument("--tolerance", type=float, default=1e-4)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        _assert_export_environment()
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from None
    if args.check:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            try:
                generated = export_all(
                    temp_root / "ai_models",
                    checkpoint_root=args.checkpoint_root,
                    tolerance=args.tolerance,
                )
            except (OSError, RuntimeError, ValueError) as exc:
                raise SystemExit(str(exc)) from None
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
    try:
        manifest = export_all(
            args.output_root,
            checkpoint_root=args.checkpoint_root,
            tolerance=args.tolerance,
        )
    except (OSError, RuntimeError, ValueError) as exc:
        raise SystemExit(str(exc)) from None
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

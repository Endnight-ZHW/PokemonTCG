"""Verify the pinned DL environment and run real checkpoint inference."""
from __future__ import annotations

import argparse
import json
import site
import sys
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.model import load_checkpoint
from engine.ai.dl.rules_migration import (
    expected_runtime_versions,
    runtime_contract_errors,
    runtime_versions,
)


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return payload


def _infer_checkpoint(path: Path, deck_index: int, device: str) -> dict[str, Any]:
    import torch

    model, payload = load_checkpoint(str(path), device)
    config = dict(payload.get("model_config") or {})
    state_numeric = torch.zeros(
        (1, int(config["state_numeric_size"])), dtype=torch.float32, device=device
    )
    state_cards = torch.zeros(
        (1, int(config["state_card_slots"])), dtype=torch.long, device=device
    )
    action_numeric = torch.zeros(
        (1, 2, int(config["action_numeric_size"])), dtype=torch.float32, device=device
    )
    action_cards = torch.zeros((1, 2), dtype=torch.long, device=device)
    action_mask = torch.tensor([[True, False]], dtype=torch.bool, device=device)
    deck_idx = torch.tensor([deck_index], dtype=torch.long, device=device)
    with torch.inference_mode():
        logits, value = model(
            state_numeric,
            state_cards,
            action_numeric,
            action_cards,
            action_mask,
            deck_idx,
        )
    if not torch.isfinite(logits[:, :1]).all() or not torch.isfinite(value).all():
        raise ValueError(f"Non-finite checkpoint output: {path}")
    result = {
        "checkpoint_version": int(payload.get("version") or 0),
        "logits_shape": list(logits.shape),
        "value_shape": list(value.shape),
        "finite": True,
    }
    del model, payload, state_numeric, state_cards, action_numeric, action_cards
    del action_mask, deck_idx, logits, value
    if str(device).startswith("cuda"):
        torch.cuda.empty_cache()
    return result


def verify(
    *,
    toolchain_lock: Path,
    release_manifest: Path,
    model_dir: Path,
    device: str,
    check_models: bool,
) -> dict[str, Any]:
    actual = runtime_versions()
    expected = expected_runtime_versions(toolchain_lock)
    errors = runtime_contract_errors(
        actual,
        expected,
        require_cuda=str(device).startswith("cuda"),
    )
    if bool(site.ENABLE_USER_SITE):
        errors.append("user_site:must_be_disabled")
    if errors:
        raise ValueError("DL environment mismatch: " + "; ".join(errors))

    result: dict[str, Any] = {
        "valid": True,
        "executable": sys.executable,
        "environment": actual,
        "models": {},
    }
    if not check_models:
        return result
    manifest = _read_json(release_manifest)
    decks = list(manifest.get("release_decks") or [])
    if len(decks) != int(manifest.get("model_count") or 0):
        raise ValueError("Release deck/model count mismatch")
    for index, deck in enumerate(decks):
        path = model_dir / f"{deck}.pt"
        if not path.is_file():
            raise FileNotFoundError(path)
        result["models"][deck] = _infer_checkpoint(path, index, device)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--toolchain-lock", type=Path, default=REPO_ROOT / "tools" / "toolchain.lock.json"
    )
    parser.add_argument(
        "--release-manifest", type=Path, default=REPO_ROOT / "release_manifest.json"
    )
    parser.add_argument("--model-dir", type=Path, default=PYTHON_ROOT / "data" / "ai_models")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--skip-models", action="store_true")
    args = parser.parse_args()
    try:
        result = verify(
            toolchain_lock=args.toolchain_lock.resolve(),
            release_manifest=args.release_manifest.resolve(),
            model_dir=args.model_dir.resolve(),
            device=str(args.device),
            check_models=not bool(args.skip_models),
        )
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from None
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

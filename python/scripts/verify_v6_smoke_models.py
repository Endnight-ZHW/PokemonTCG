"""Export and verify completed one-deck v6 Smoke models."""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.hybrid_population import FINGERPRINT_FILES  # noqa: E402
from engine.ai.dl.run_store import (  # noqa: E402
    atomic_write_json,
    build_fingerprint,
    read_json,
    sha256_file,
)
from scripts.export_onnx_models import (  # noqa: E402
    _benchmark_one,
    _export_one,
    _verify_one,
)


def verify_run(run_dir: Path) -> dict[str, Any]:
    run_dir = run_dir.resolve()
    run = read_json(run_dir / "run.json")
    config = dict(run.get("config") or {})
    decks = list(config.get("decks") or [])
    variant = str(config.get("model_variant", ""))
    if (
        str(run.get("preset", "")) != "smoke"
        or str(run.get("status", "")) != "completed"
        or bool(run.get("promotable"))
        or len(decks) != 1
        or variant not in {"v6_pooled", "v6_cross_attention"}
    ):
        raise RuntimeError(f"Invalid completed v6 Smoke run: {run_dir}")
    current_fingerprint = build_fingerprint(
        REPO_ROOT,
        config,
        extra_files=FINGERPRINT_FILES,
    )
    if dict(run.get("fingerprint") or {}) != current_fingerprint:
        raise RuntimeError(
            f"Smoke run fingerprint no longer matches the code: {run_dir}"
        )
    deck = str(decks[0])
    checkpoint = run_dir / "models" / f"{deck}.pt"
    checkpoint_sha = sha256_file(checkpoint)
    expected_checkpoint_sha = str(
        dict(run.get("candidate_models") or {})
        .get(deck, {})
        .get("sha256", "")
    ).lower()
    if checkpoint_sha != expected_checkpoint_sha:
        raise RuntimeError(
            f"Smoke checkpoint hash mismatch: {checkpoint}"
        )
    with tempfile.TemporaryDirectory(prefix="v6-smoke-onnx-") as directory:
        output = Path(directory) / f"{deck}.onnx"
        payload, wrapper = _export_one(checkpoint, output)
        parity = _verify_one(wrapper, output, tolerance=1e-4)
        performance = _benchmark_one(output)
    model_config = dict(payload.get("model_config") or {})
    expected_cross_attention = variant == "v6_cross_attention"
    if (
        int(payload.get("version", 0)) != 11
        or int((payload.get("schema") or {}).get("encoder_version", 0)) != 6
        or int(model_config.get("state_numeric_size", 0)) != 960
        or int(model_config.get("state_card_slots", 0)) != 128
        or int(model_config.get("action_numeric_size", 0)) != 178
        or int(model_config.get("card_embed_dim", 0)) != 32
        or int(model_config.get("hidden_size", 0)) != 384
        or int(model_config.get("attention_heads", 0)) != 4
        or int(
            model_config.get("candidate_cross_attention_heads", 0)
        )
        != 4
        or bool(model_config.get("candidate_cross_attention"))
        != expected_cross_attention
        or int(model_config.get("num_decks", 0)) != 10
        or str(model_config.get("card_identity_mode", ""))
        != "vocab_v1"
    ):
        raise RuntimeError(
            f"Smoke model configuration is incompatible: {run_dir}"
        )
    return {
        "run_id": run.get("run_id"),
        "variant": variant,
        "deck": deck,
        "checkpoint_version": int(payload.get("version", 0)),
        "checkpoint_sha256": checkpoint_sha,
        "run_fingerprint": current_fingerprint,
        "encoder_version": int(
            (payload.get("schema") or {}).get("encoder_version", 0)
        ),
        "parity_max_abs_error": parity,
        "performance_32_action_16_choice": performance,
        "model_config": model_config,
        "passed": True,
        "promotable": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run-dir",
        action="append",
        type=Path,
        required=True,
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    rows = [verify_run(path) for path in args.run_dir]
    variants = {row["variant"] for row in rows}
    if variants != {"v6_pooled", "v6_cross_attention"}:
        raise RuntimeError(
            "Smoke verification requires one pooled and one cross-attention run"
        )
    report = {
        "schema": "deep_ai_v6_smoke_verification_v1",
        "passed": True,
        "promotable": False,
        "runs": rows,
    }
    if args.output is not None:
        atomic_write_json(args.output, report)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

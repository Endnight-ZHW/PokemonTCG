"""Export the tiny dynamic-shape ONNX model used by the Godot runtime contract."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


RESEARCH_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = RESEARCH_ROOT / "python"
for import_root in (PYTHON_ROOT,):
    if str(import_root) not in sys.path:
        sys.path.insert(0, str(import_root))

import torch  # noqa: E402

from deep_ai.v3_contract import (  # noqa: E402
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
    ONNX_INPUT_NAMES,
    ONNX_OUTPUT_NAMES,
    STATE_GLOBAL_SIZE,
)


class NativeRuntimeContractModel(torch.nn.Module):
    """Cheap non-constant graph that keeps every v3 ABI input observable."""

    def forward(
        self,
        state_global,
        entity_numeric,
        entity_card_ids,
        entity_type_ids,
        entity_mask,
        candidate_numeric,
        candidate_card_ids,
        candidate_type_ids,
        candidate_refs,
        candidate_mask,
        actor_deck_id,
        opponent_deck_id,
    ):
        anchor = (
            state_global[:, 0]
            + entity_numeric[:, 0, 0]
            + entity_card_ids[:, 0].float()
            + entity_type_ids[:, 0, 0].float()
            + entity_mask[:, 0].float()
            + actor_deck_id.float()
            + opponent_deck_id.float()
        )
        policy = (
            candidate_numeric[:, :, 0]
            + candidate_card_ids.float()
            + candidate_type_ids.float()
            + candidate_refs[:, :, 0].float()
            + candidate_mask.float()
            + anchor[:, None]
        ) * 1.0e-12
        wdl = torch.stack(
            (anchor, anchor * 0.5, -anchor),
            dim=1,
        ) * 1.0e-12
        return policy, wdl


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    destination = Path(args.output).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    batch, candidates = 2, 7
    inputs = (
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
    dynamic_axes = {name: {0: "batch"} for name in ONNX_INPUT_NAMES}
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
        NativeRuntimeContractModel().eval(),
        inputs,
        str(destination),
        input_names=list(ONNX_INPUT_NAMES),
        output_names=list(ONNX_OUTPUT_NAMES),
        dynamic_axes=dynamic_axes,
        opset_version=17,
    )
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

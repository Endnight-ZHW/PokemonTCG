"""Export the tiny dynamic-shape ONNX model used by the Godot runtime contract."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


PYTHON_ROOT = Path(__file__).resolve().parents[1]
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from scripts.export_onnx_models import _export, torch  # noqa: E402


class NativeRuntimeContractModel(torch.nn.Module):
    """Cheap non-constant graph that keeps every v2 ABI input observable."""

    def forward(
        self,
        state_global,
        entity_numeric,
        entity_card_ids,
        entity_type_ids,
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
    _export(NativeRuntimeContractModel(), destination)
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

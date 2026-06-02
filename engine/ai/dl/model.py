"""PyTorch model for legal-action scoring.

The module degrades cleanly when torch is not installed so the main game can
ship without a hard DL dependency.
"""
from __future__ import annotations

from typing import Any

from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_BUCKET_COUNT,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
)

try:  # pragma: no cover - exercised only when torch is installed.
    import torch
    from torch import nn
except Exception:  # pragma: no cover - no torch in normal game runtime.
    torch = None
    nn = None


TORCH_AVAILABLE = torch is not None
CHECKPOINT_VERSION = 1


if TORCH_AVAILABLE:

    class DeepActionModel(nn.Module):
        """Score each legal candidate action and estimate state value."""

        def __init__(
            self,
            *,
            state_numeric_size: int = STATE_NUMERIC_SIZE,
            state_card_slots: int = STATE_CARD_SLOTS,
            action_numeric_size: int = ACTION_NUMERIC_SIZE,
            card_bucket_count: int = CARD_BUCKET_COUNT,
            card_embed_dim: int = 32,
            hidden_size: int = 192,
        ):
            super().__init__()
            self.state_numeric_size = state_numeric_size
            self.state_card_slots = state_card_slots
            self.action_numeric_size = action_numeric_size
            self.card_bucket_count = card_bucket_count
            self.card_embed_dim = card_embed_dim
            self.hidden_size = hidden_size

            self.card_embedding = nn.Embedding(card_bucket_count, card_embed_dim, padding_idx=0)
            self.state_net = nn.Sequential(
                nn.Linear(state_numeric_size + card_embed_dim, hidden_size),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size),
                nn.ReLU(),
            )
            self.action_net = nn.Sequential(
                nn.Linear(hidden_size + action_numeric_size + card_embed_dim, hidden_size),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size // 2),
                nn.ReLU(),
                nn.Linear(hidden_size // 2, 1),
            )
            self.value_head = nn.Sequential(
                nn.Linear(hidden_size, hidden_size // 2),
                nn.ReLU(),
                nn.Linear(hidden_size // 2, 1),
            )

        def forward(self, state_numeric, state_card_ids, action_numeric, action_card_ids, action_mask=None):
            state_embeds = self.card_embedding(state_card_ids.long())
            mask = (state_card_ids != 0).float().unsqueeze(-1)
            pooled = (state_embeds * mask).sum(dim=1) / mask.sum(dim=1).clamp_min(1.0)
            state_hidden = self.state_net(torch.cat([state_numeric.float(), pooled], dim=-1))

            action_embeds = self.card_embedding(action_card_ids.long())
            batch, action_count, _ = action_numeric.shape
            expanded_state = state_hidden.unsqueeze(1).expand(batch, action_count, state_hidden.shape[-1])
            action_input = torch.cat([expanded_state, action_numeric.float(), action_embeds], dim=-1)
            logits = self.action_net(action_input).squeeze(-1)
            if action_mask is not None:
                logits = logits.masked_fill(~action_mask.bool(), -1_000_000_000.0)
            value = self.value_head(state_hidden).squeeze(-1)
            return logits, value

else:

    class DeepActionModel:  # type: ignore[no-redef]
        def __init__(self, *args, **kwargs):
            raise RuntimeError("PyTorch is required for DeepActionModel")


def create_model(**kwargs):
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is not installed. Install torch in the DL training environment.")
    return DeepActionModel(**kwargs)


def checkpoint_payload(model, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is not installed.")
    return {
        "version": CHECKPOINT_VERSION,
        "model_state": model.state_dict(),
        "metadata": metadata or {},
        "model_config": {
            "state_numeric_size": model.state_numeric_size,
            "state_card_slots": model.state_card_slots,
            "action_numeric_size": model.action_numeric_size,
            "card_bucket_count": model.card_bucket_count,
            "card_embed_dim": model.card_embed_dim,
            "hidden_size": model.hidden_size,
        },
    }


def save_checkpoint(path: str, model, metadata: dict[str, Any] | None = None) -> None:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is not installed.")
    import os

    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    torch.save(checkpoint_payload(model, metadata), path)


def load_checkpoint(path: str, device: str = "cpu"):
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is not installed.")
    payload = torch.load(path, map_location=device)
    if isinstance(payload, dict) and "model_state" in payload:
        config = payload.get("model_config") or {}
        model = create_model(**config)
        model.load_state_dict(payload["model_state"])
        model.to(device)
        model.eval()
        return model, payload
    model = create_model()
    model.load_state_dict(payload)
    model.to(device)
    model.eval()
    return model, {"version": 0, "metadata": {}, "model_config": {}}

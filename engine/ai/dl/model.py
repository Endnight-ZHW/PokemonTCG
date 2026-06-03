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
    CARD_SEMANTIC_SIZE,
)

try:  # pragma: no cover - exercised only when torch is installed.
    import torch
    from torch import nn
except Exception:  # pragma: no cover - no torch in normal game runtime.
    torch = None
    nn = None


TORCH_AVAILABLE = torch is not None
CHECKPOINT_VERSION = 6


if TORCH_AVAILABLE:

    class DeepActionModel(nn.Module):
        """Score each legal candidate action and estimate state value.

        v6 upgrades: doubled hidden_size (384), self-attention over card slots,
        LayerNorm for small-batch stability, deeper value head.
        """

        def __init__(
            self,
            *,
            state_numeric_size: int = STATE_NUMERIC_SIZE,
            state_card_slots: int = STATE_CARD_SLOTS,
            action_numeric_size: int = ACTION_NUMERIC_SIZE,
            card_bucket_count: int = CARD_BUCKET_COUNT,
            card_embed_dim: int = 32,
            hidden_size: int = 384,
            choice_head_enabled: bool = True,
            use_attention: bool = True,
            state_norm: str = "layer",
        ):
            super().__init__()
            self.state_numeric_size = state_numeric_size
            self.state_card_slots = state_card_slots
            self.action_numeric_size = action_numeric_size
            self.card_bucket_count = card_bucket_count
            self.card_embed_dim = card_embed_dim
            self.hidden_size = hidden_size
            self.choice_head_enabled = bool(choice_head_enabled)
            self.use_attention = bool(use_attention) and (card_embed_dim >= 4)
            self.state_norm = "batch" if str(state_norm).lower() == "batch" else "layer"

            # Card identity embedding (hash-bucket based)
            self.card_embedding = nn.Embedding(card_bucket_count, card_embed_dim, padding_idx=0)

            # Multi-head self-attention over card slots for relational reasoning
            if self.use_attention:
                self.card_attn = nn.MultiheadAttention(card_embed_dim, num_heads=4, batch_first=True)
                self.card_attn_norm = nn.LayerNorm(card_embed_dim)
            else:
                self.card_attn = None
                self.card_attn_norm = None

            def make_state_norm():
                if self.state_norm == "batch":
                    return nn.BatchNorm1d(hidden_size)
                return nn.LayerNorm(hidden_size)

            # State encoder: [numeric + pooled_card_embed] -> hidden
            self.state_net = nn.Sequential(
                nn.Linear(state_numeric_size + card_embed_dim, hidden_size),
                make_state_norm(),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size),
                make_state_norm(),
                nn.ReLU(),
            )

            # Action scorer: [state_hidden + action_numeric + action_card_embed] -> logit
            self.action_net = nn.Sequential(
                nn.Linear(hidden_size + action_numeric_size + card_embed_dim, hidden_size),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size // 2),
                nn.ReLU(),
                nn.Linear(hidden_size // 2, 1),
            )
            self.choice_net = nn.Sequential(
                nn.Linear(hidden_size + action_numeric_size + card_embed_dim, hidden_size),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size // 2),
                nn.ReLU(),
                nn.Linear(hidden_size // 2, 1),
            )

            # Value head: hidden -> scalar
            self.value_head = nn.Sequential(
                nn.Linear(hidden_size, hidden_size // 2),
                nn.ReLU(),
                nn.Linear(hidden_size // 2, hidden_size // 4),
                nn.ReLU(),
                nn.Linear(hidden_size // 4, 1),
            )

        def _state_hidden(self, state_numeric, state_card_ids):
            state_embeds = self.card_embedding(state_card_ids.long())  # [B, slots, embed_dim]

            # Self-attention: let card slots attend to each other
            if self.card_attn is not None:
                attn_out, _ = self.card_attn(state_embeds, state_embeds, state_embeds)
                state_embeds = self.card_attn_norm(state_embeds + attn_out)

            # Mean-pool embeddings over card slots (masking pad slots)
            mask = (state_card_ids != 0).float().unsqueeze(-1)
            pooled = (state_embeds * mask).sum(dim=1) / mask.sum(dim=1).clamp_min(1.0)

            x = torch.cat([state_numeric.float(), pooled], dim=-1)
            return self.state_net(x)

        def _score_candidates(self, state_hidden, candidate_numeric, candidate_card_ids, scorer, candidate_mask=None):
            candidate_embeds = self.card_embedding(candidate_card_ids.long())
            batch, candidate_count, _ = candidate_numeric.shape
            expanded_state = state_hidden.unsqueeze(1).expand(batch, candidate_count, state_hidden.shape[-1])
            candidate_input = torch.cat([expanded_state, candidate_numeric.float(), candidate_embeds], dim=-1)
            logits = scorer(candidate_input).squeeze(-1)
            if candidate_mask is not None:
                logits = logits.masked_fill(~candidate_mask.bool(), -1_000_000_000.0)
            return logits

        def forward(self, state_numeric, state_card_ids, action_numeric, action_card_ids, action_mask=None):
            state_hidden = self._state_hidden(state_numeric, state_card_ids)
            logits = self._score_candidates(state_hidden, action_numeric, action_card_ids, self.action_net, action_mask)
            value = self.value_head(state_hidden).squeeze(-1)
            return logits, value

        def score_choices(self, state_numeric, state_card_ids, choice_numeric, choice_card_ids, choice_mask=None):
            state_hidden = self._state_hidden(state_numeric, state_card_ids)
            scorer = self.choice_net if self.choice_head_enabled else self.action_net
            logits = self._score_candidates(state_hidden, choice_numeric, choice_card_ids, scorer, choice_mask)
            return logits

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
        "encoder_config": {
            "state_numeric_size": model.state_numeric_size,
            "state_card_slots": model.state_card_slots,
            "action_numeric_size": model.action_numeric_size,
            "card_bucket_count": model.card_bucket_count,
        },
        "model_config": {
            "state_numeric_size": model.state_numeric_size,
            "state_card_slots": model.state_card_slots,
            "action_numeric_size": model.action_numeric_size,
            "card_bucket_count": model.card_bucket_count,
            "card_embed_dim": model.card_embed_dim,
            "hidden_size": model.hidden_size,
            "choice_head_enabled": bool(getattr(model, "choice_head_enabled", True)),
            "use_attention": bool(getattr(model, "use_attention", True)),
            "state_norm": getattr(model, "state_norm", "layer"),
        },
        "choice_head_enabled": bool(getattr(model, "choice_head_enabled", True)),
    }


def _infer_model_config_from_state_dict(state_dict: dict[str, Any]) -> dict[str, Any]:
    """Infer enough config to load pre-v1 raw state_dict checkpoints."""
    config: dict[str, Any] = {}
    try:
        card_weight = state_dict["card_embedding.weight"]
        config["card_bucket_count"] = int(card_weight.shape[0])
        config["card_embed_dim"] = int(card_weight.shape[1])
    except Exception:
        config["card_bucket_count"] = CARD_BUCKET_COUNT
        config["card_embed_dim"] = 32
    try:
        state_weight = state_dict["state_net.0.weight"]
        hidden_size = int(state_weight.shape[0])
        config["hidden_size"] = hidden_size
        config["state_numeric_size"] = int(state_weight.shape[1]) - int(config["card_embed_dim"])
    except Exception:
        config["hidden_size"] = 384
        config["state_numeric_size"] = STATE_NUMERIC_SIZE
    try:
        action_weight = state_dict["action_net.0.weight"]
        config["action_numeric_size"] = int(action_weight.shape[1]) - int(config["hidden_size"]) - int(config["card_embed_dim"])
    except Exception:
        config["action_numeric_size"] = ACTION_NUMERIC_SIZE
    config["state_card_slots"] = 32
    config["state_norm"] = "batch"
    return config


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
        version = int(payload.get("version") or 0)
        config = dict(payload.get("model_config") or {})
        config.setdefault("choice_head_enabled", version >= 3)
        config.setdefault("use_attention", version >= 5)
        config.setdefault("state_norm", "layer" if version >= 6 else "batch")
        model = create_model(**config)
        strict = version >= 5
        model.load_state_dict(payload["model_state"], strict=strict)
        model.to(device)
        model.eval()
        return model, payload
    config = _infer_model_config_from_state_dict(payload)
    config["choice_head_enabled"] = False
    config["state_norm"] = "batch"
    model = create_model(**config)
    model.load_state_dict(payload, strict=False)
    model.to(device)
    model.eval()
    return model, {"version": 0, "metadata": {}, "model_config": config}

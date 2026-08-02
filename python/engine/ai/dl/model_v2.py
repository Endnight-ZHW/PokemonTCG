"""Universal information-set policy/WDL transformer."""
from __future__ import annotations

import os
import warnings
from typing import Any

from data.ai_card_vocab import (
    CARD_VOCAB_VERSION,
    card_vocab_sha256,
    card_vocab_size,
)
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION

from .v2_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CHECKPOINT_VERSION,
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    MODEL_DIM,
    MODEL_FFN_DIM,
    MODEL_HEADS,
    MODEL_LAYERS,
    MODEL_VARIANT,
    RELEASE_DECKS,
    STATE_GLOBAL_SIZE,
    TRAINER_ID,
)

try:
    import torch
    from torch import nn
except Exception:  # pragma: no cover - the normal game can omit PyTorch.
    torch = None
    nn = None


TORCH_AVAILABLE = torch is not None


def _safe_torch_load(path: str, map_location: Any = "cpu") -> Any:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is not installed")
    try:
        return torch.load(path, map_location=map_location, weights_only=True)
    except TypeError:
        return torch.load(path, map_location=map_location)
    except Exception as exc:
        if "Weights only load failed" not in str(exc):
            raise
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", FutureWarning)
            return torch.load(path, map_location=map_location, weights_only=False)


if TORCH_AVAILABLE:

    class UniversalInformationSetModel(nn.Module):
        """One policy/WDL network shared by all release decks."""

        def __init__(
            self,
            *,
            card_vocab_size_: int | None = None,
            model_dim: int = MODEL_DIM,
            layers: int = MODEL_LAYERS,
            heads: int = MODEL_HEADS,
            ffn_dim: int = MODEL_FFN_DIM,
            dropout: float = 0.0,
            entity_type_vocab: int = 32,
            candidate_type_vocab: int = 64,
            candidate_ref_vocab: int = 160,
            num_decks: int = len(RELEASE_DECKS),
        ) -> None:
            super().__init__()
            if model_dim % heads:
                raise ValueError("model_dim_must_be_divisible_by_heads")
            self.card_vocab_size = int(card_vocab_size_ or card_vocab_size())
            self.model_dim = int(model_dim)
            self.layers = int(layers)
            self.heads = int(heads)
            self.ffn_dim = int(ffn_dim)
            self.dropout = float(dropout)
            self.entity_type_vocab = int(entity_type_vocab)
            self.candidate_type_vocab = int(candidate_type_vocab)
            self.candidate_ref_vocab = int(candidate_ref_vocab)
            self.num_decks = int(num_decks)
            self.variant = MODEL_VARIANT

            self.card_embedding = nn.Embedding(
                self.card_vocab_size,
                model_dim,
                padding_idx=0,
            )
            self.entity_type_embedding = nn.Embedding(
                entity_type_vocab,
                model_dim,
                padding_idx=0,
            )
            self.entity_numeric_projection = nn.Linear(
                ENTITY_NUMERIC_SIZE,
                model_dim,
            )
            self.slot_embedding = nn.Embedding(ENTITY_SLOTS + 1, model_dim)
            self.global_projection = nn.Linear(STATE_GLOBAL_SIZE, model_dim)
            self.deck_embedding = nn.Embedding(num_decks, model_dim)

            encoder_layer = nn.TransformerEncoderLayer(
                d_model=model_dim,
                nhead=heads,
                dim_feedforward=ffn_dim,
                dropout=dropout,
                activation="gelu",
                batch_first=True,
                norm_first=True,
            )
            self.entity_transformer = nn.TransformerEncoder(
                encoder_layer,
                num_layers=layers,
                norm=nn.LayerNorm(model_dim),
                enable_nested_tensor=False,
            )

            self.candidate_numeric_projection = nn.Linear(
                CANDIDATE_NUMERIC_SIZE,
                model_dim,
            )
            self.candidate_type_embedding = nn.Embedding(
                candidate_type_vocab,
                model_dim,
                padding_idx=0,
            )
            self.candidate_ref_embedding = nn.Embedding(
                candidate_ref_vocab,
                model_dim,
                padding_idx=0,
            )
            self.candidate_cross_attention = nn.MultiheadAttention(
                model_dim,
                heads,
                dropout=dropout,
                batch_first=True,
            )
            self.candidate_norm = nn.LayerNorm(model_dim)
            self.policy_head = nn.Sequential(
                nn.Linear(model_dim * 2, model_dim),
                nn.GELU(),
                nn.Linear(model_dim, 1),
            )
            self.wdl_head = nn.Sequential(
                nn.Linear(model_dim, model_dim),
                nn.GELU(),
                nn.Linear(model_dim, 3),
            )

        def config_dict(self) -> dict[str, Any]:
            return {
                "card_vocab_size_": self.card_vocab_size,
                "model_dim": self.model_dim,
                "layers": self.layers,
                "heads": self.heads,
                "ffn_dim": self.ffn_dim,
                "dropout": self.dropout,
                "entity_type_vocab": self.entity_type_vocab,
                "candidate_type_vocab": self.candidate_type_vocab,
                "candidate_ref_vocab": self.candidate_ref_vocab,
                "num_decks": self.num_decks,
            }

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
            entity_cards = self.card_embedding(entity_card_ids.long())
            entity_types = self.entity_type_embedding(
                entity_type_ids.long().clamp(
                    min=0,
                    max=self.entity_type_vocab - 1,
                )
            ).sum(dim=-2)
            slots = torch.arange(
                entity_card_ids.shape[1],
                device=entity_card_ids.device,
            )
            entity_tokens = (
                entity_cards
                + entity_types
                + self.entity_numeric_projection(entity_numeric.float())
                + self.slot_embedding(slots + 1).unsqueeze(0)
            )

            actor_deck = self.deck_embedding(
                actor_deck_id.long().clamp(0, self.num_decks - 1)
            )
            opponent_deck = self.deck_embedding(
                opponent_deck_id.long().clamp(0, self.num_decks - 1)
            )
            global_token = (
                self.global_projection(state_global.float())
                + actor_deck
                - opponent_deck
            ).unsqueeze(1)

            memory = torch.cat((global_token, entity_tokens), dim=1)
            entity_padding = entity_card_ids.eq(0)
            global_padding = torch.zeros(
                (entity_padding.shape[0], 1),
                dtype=torch.bool,
                device=entity_padding.device,
            )
            memory_padding = torch.cat(
                (global_padding, entity_padding),
                dim=1,
            )
            memory = self.entity_transformer(
                memory,
                src_key_padding_mask=memory_padding,
            )
            state_token = memory[:, 0]

            candidate_tokens = (
                self.candidate_numeric_projection(candidate_numeric.float())
                + self.card_embedding(candidate_card_ids.long())
                + self.candidate_type_embedding(
                    candidate_type_ids.long().clamp(
                        min=0,
                        max=self.candidate_type_vocab - 1,
                    )
                )
                + self.candidate_ref_embedding(
                    candidate_refs.long().clamp(
                        min=0,
                        max=self.candidate_ref_vocab - 1,
                    )
                ).sum(dim=-2)
            )
            context, _ = self.candidate_cross_attention(
                candidate_tokens,
                memory,
                memory,
                key_padding_mask=memory_padding,
                need_weights=False,
            )
            candidate_tokens = self.candidate_norm(
                candidate_tokens + context
            )
            expanded_state = state_token.unsqueeze(1).expand(
                -1,
                candidate_tokens.shape[1],
                -1,
            )
            policy_logits = self.policy_head(
                torch.cat((candidate_tokens, expanded_state), dim=-1)
            ).squeeze(-1)
            policy_logits = policy_logits.masked_fill(
                ~candidate_mask.bool(),
                torch.finfo(policy_logits.dtype).min,
            )
            return policy_logits, self.wdl_head(state_token)


else:

    class UniversalInformationSetModel:  # type: ignore[no-redef]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            raise RuntimeError("PyTorch is required for AlphaZero v2")


def create_model(**kwargs: Any):
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for AlphaZero v2")
    return UniversalInformationSetModel(**kwargs)


def checkpoint_payload(
    model: UniversalInformationSetModel,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for AlphaZero v2")
    normalized = dict(metadata or {})
    normalized.update(
        {
            "trainer": TRAINER_ID,
            "model_variant": MODEL_VARIANT,
            "rules_version": RULES_SCHEMA_VERSION,
            "action_version": ACTION_SCHEMA_VERSION,
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "checkpoint_version": CHECKPOINT_VERSION,
            "planner_version": DEEP_PLANNER_VERSION,
            "card_vocab_version": CARD_VOCAB_VERSION,
            "card_vocab_size": card_vocab_size(),
            "card_vocab_sha256": card_vocab_sha256(),
            "universal": True,
            "release_decks": list(RELEASE_DECKS),
        }
    )
    return {
        "version": CHECKPOINT_VERSION,
        "model_state": model.state_dict(),
        "model_config": model.config_dict(),
        "metadata": normalized,
        "schema": {
            "rules_version": RULES_SCHEMA_VERSION,
            "action_version": ACTION_SCHEMA_VERSION,
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "checkpoint_version": CHECKPOINT_VERSION,
            "deep_planner_version": DEEP_PLANNER_VERSION,
            "card_vocab_version": CARD_VOCAB_VERSION,
        },
    }


def save_checkpoint(
    path: str,
    model: UniversalInformationSetModel,
    metadata: dict[str, Any] | None = None,
) -> None:
    payload = checkpoint_payload(model, metadata)
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    torch.save(payload, path)


def load_checkpoint(path: str, device: str = "cpu"):
    payload = _safe_torch_load(path, map_location=device)
    if not isinstance(payload, dict) or "model_state" not in payload:
        raise ValueError("legacy_checkpoint_is_read_only")
    if int(payload.get("version") or 0) != CHECKPOINT_VERSION:
        raise ValueError("legacy_checkpoint_is_read_only")
    schema = dict(payload.get("schema") or {})
    required = {
        "encoder_version": ENCODER_SCHEMA_VERSION,
        "checkpoint_version": CHECKPOINT_VERSION,
        "deep_planner_version": DEEP_PLANNER_VERSION,
        "card_vocab_version": CARD_VOCAB_VERSION,
    }
    mismatches = [
        name
        for name, expected in required.items()
        if int(schema.get(name) or 0) != expected
    ]
    metadata = dict(payload.get("metadata") or {})
    if str(metadata.get("card_vocab_sha256") or "") != card_vocab_sha256():
        mismatches.append("card_vocab_sha256")
    if str(metadata.get("model_variant") or "") != MODEL_VARIANT:
        mismatches.append("model_variant")
    if mismatches:
        raise ValueError("incompatible_v2_checkpoint:" + ",".join(mismatches))
    model = create_model(**dict(payload.get("model_config") or {}))
    model.load_state_dict(payload["model_state"], strict=True)
    model.to(device)
    model.eval()
    return model, payload

"""Universal information-set Transformer for Deep AI v3."""
from __future__ import annotations

from typing import Any

import numpy as np

from data.ai_card_vocab import (
    CARD_VOCAB_VERSION,
    card_vocab_sha256,
    card_vocab_size,
)
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION

from .encoder_v3 import card_semantic_table
from .v3_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    CARD_SEMANTIC_SIZE,
    CHECKPOINT_VERSION,
    DEEP_PLANNER_VERSION,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
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
except Exception:  # pragma: no cover - the normal client may omit PyTorch.
    torch = None
    nn = None


TORCH_AVAILABLE = torch is not None


if TORCH_AVAILABLE:

    class UniversalInformationSetModelV3(nn.Module):
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
            candidate_ref_vocab: int = 512,
            num_decks: int = len(RELEASE_DECKS),
            semantic_table_: np.ndarray | None = None,
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

            semantics = np.asarray(
                semantic_table_ if semantic_table_ is not None else card_semantic_table(),
                dtype=np.float32,
            )
            if semantics.shape != (self.card_vocab_size, CARD_SEMANTIC_SIZE):
                raise ValueError(
                    "v3_card_semantic_shape_mismatch:"
                    f"{semantics.shape}!="
                    f"{(self.card_vocab_size, CARD_SEMANTIC_SIZE)}"
                )
            self.register_buffer(
                "card_semantics",
                torch.from_numpy(np.ascontiguousarray(semantics)),
                persistent=True,
            )
            self.card_embedding = nn.Embedding(
                self.card_vocab_size,
                model_dim,
                padding_idx=0,
            )
            self.card_semantic_projection = nn.Sequential(
                nn.Linear(CARD_SEMANTIC_SIZE, model_dim),
                nn.GELU(),
                nn.Linear(model_dim, model_dim),
            )
            self.entity_type_embedding = nn.Embedding(
                entity_type_vocab,
                model_dim,
                padding_idx=0,
            )
            self.entity_type_field_embedding = nn.Embedding(
                ENTITY_TYPE_FIELDS,
                model_dim,
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
            self.candidate_ref_field_embedding = nn.Embedding(
                CANDIDATE_REF_FIELDS,
                model_dim,
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

        def _card_features(self, card_ids):
            ids = card_ids.long().clamp(0, self.card_vocab_size - 1)
            semantic = self.card_semantics[ids].float()
            return self.card_embedding(ids) + self.card_semantic_projection(semantic)

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
            batch_size = entity_card_ids.shape[0]
            entity_cards = self._card_features(entity_card_ids)
            entity_fields = torch.arange(
                ENTITY_TYPE_FIELDS,
                device=entity_type_ids.device,
            )
            entity_types = (
                self.entity_type_embedding(
                    entity_type_ids.long().clamp(
                        min=0,
                        max=self.entity_type_vocab - 1,
                    )
                )
                + self.entity_type_field_embedding(entity_fields).view(
                    1, 1, ENTITY_TYPE_FIELDS, self.model_dim
                )
            ).sum(dim=-2)
            slots = torch.arange(ENTITY_SLOTS, device=entity_card_ids.device)
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
            entity_padding = ~entity_mask.bool()
            global_padding = torch.zeros(
                (batch_size, 1),
                dtype=torch.bool,
                device=entity_padding.device,
            )
            memory_padding = torch.cat((global_padding, entity_padding), dim=1)
            memory = self.entity_transformer(
                memory,
                src_key_padding_mask=memory_padding,
            )
            state_token = memory[:, 0]

            reference_fields = torch.arange(
                CANDIDATE_REF_FIELDS,
                device=candidate_refs.device,
            )
            candidate_reference_tokens = (
                self.candidate_ref_embedding(
                    candidate_refs.long().clamp(
                        min=0,
                        max=self.candidate_ref_vocab - 1,
                    )
                )
                + self.candidate_ref_field_embedding(reference_fields).view(
                    1, 1, CANDIDATE_REF_FIELDS, self.model_dim
                )
            ).sum(dim=-2)
            candidate_tokens = (
                self.candidate_numeric_projection(candidate_numeric.float())
                + self._card_features(candidate_card_ids)
                + self.candidate_type_embedding(
                    candidate_type_ids.long().clamp(
                        min=0,
                        max=self.candidate_type_vocab - 1,
                    )
                )
                + candidate_reference_tokens
            )
            context, _ = self.candidate_cross_attention(
                candidate_tokens,
                memory,
                memory,
                key_padding_mask=memory_padding,
                need_weights=False,
            )
            candidate_tokens = self.candidate_norm(candidate_tokens + context)
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

    class UniversalInformationSetModelV3:  # type: ignore[no-redef]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            raise RuntimeError("PyTorch is required for Deep AI v3")


def create_model(**kwargs: Any):
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for Deep AI v3")
    return UniversalInformationSetModelV3(**kwargs)


def checkpoint_metadata(extra: dict[str, Any] | None = None) -> dict[str, Any]:
    result = dict(extra or {})
    result.update(
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
    return result

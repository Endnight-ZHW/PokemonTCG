"""PyTorch model for legal-action scoring.

The module degrades cleanly when torch is not installed so the main game can
ship without a hard DL dependency.
"""
from __future__ import annotations

import warnings
from typing import Any

from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_BUCKET_COUNT,
    CARD_IDENTITY_MODE,
    CARD_VOCAB_SHA256,
    CARD_VOCAB_SIZE,
    CARD_VOCAB_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
    CARD_SEMANTIC_SIZE,
    ENCODER_SCHEMA_VERSION,
    STATE_TOKEN_OWNERS,
    STATE_TOKEN_TYPES,
    TOKEN_OWNER_COUNT,
    TOKEN_TYPE_COUNT,
)
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION

try:  # pragma: no cover - exercised only when torch is installed.
    import torch
    from torch import nn
except Exception:  # pragma: no cover - no torch in normal game runtime.
    torch = None
    nn = None


TORCH_AVAILABLE = torch is not None
CHECKPOINT_VERSION = 11


def safe_torch_load(path: str, map_location: Any = "cpu") -> Any:
    """Load trusted project checkpoints without PyTorch's unsafe-load warning."""
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is not installed.")
    serialization = getattr(torch, "serialization", None)
    add_safe_globals = getattr(serialization, "add_safe_globals", None)
    if callable(add_safe_globals):
        try:
            from torch.torch_version import TorchVersion
            add_safe_globals([TorchVersion])
        except Exception:
            pass
    try:
        return torch.load(path, map_location=map_location, weights_only=True)
    except TypeError as exc:
        if "weights_only" not in str(exc):
            raise
        return torch.load(path, map_location=map_location)
    except Exception as exc:
        message = str(exc)
        if "Weights only load failed" not in message or "TorchVersion" not in message:
            raise
        with warnings.catch_warnings():
            warnings.filterwarnings(
                "ignore",
                message=".*weights_only=False.*",
                category=FutureWarning,
            )
            return torch.load(path, map_location=map_location, weights_only=False)


if TORCH_AVAILABLE:

    class DeepActionModel(nn.Module):
        """Score each legal candidate action and estimate state value.

        Encoder-v6 models add fixed-layout token/owner embeddings and let each
        action or choice query attend directly to the state-card sequence.
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
            use_slot_embeddings: bool = True,
            state_norm: str = "layer",
            deck_embed_dim: int = 0,
            num_decks: int = 10,
            use_token_type_embeddings: bool = True,
            candidate_cross_attention: bool = True,
            attention_heads: int = 4,
            candidate_cross_attention_heads: int = 4,
            card_identity_mode: str = CARD_IDENTITY_MODE,
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
            self.use_slot_embeddings = bool(use_slot_embeddings)
            self.state_norm = "batch" if str(state_norm).lower() == "batch" else "layer"
            self.deck_embed_dim = max(0, int(deck_embed_dim))
            self.num_decks = max(1, int(num_decks))
            self.use_token_type_embeddings = bool(use_token_type_embeddings)
            self.candidate_cross_attention = bool(candidate_cross_attention)
            self.attention_heads = int(attention_heads)
            self.candidate_cross_attention_heads = int(
                candidate_cross_attention_heads
            )
            self.card_identity_mode = str(card_identity_mode or CARD_IDENTITY_MODE)
            if (
                self.attention_heads != 4
                or self.candidate_cross_attention_heads != 4
            ):
                raise ValueError(
                    "Deep AI v6 requires four-head state and candidate attention"
                )

            # Encoder v6 uses append-only vocabulary indices.  Legacy
            # checkpoints may still declare hash_v1 and load their old table.
            self.card_embedding = nn.Embedding(card_bucket_count, card_embed_dim, padding_idx=0)
            self.slot_embedding = (
                nn.Embedding(state_card_slots, card_embed_dim)
                if self.use_slot_embeddings else None
            )
            if self.use_token_type_embeddings:
                if state_card_slots != len(STATE_TOKEN_TYPES):
                    raise ValueError(
                        "Token-type embeddings require the encoder-v6 "
                        f"{len(STATE_TOKEN_TYPES)}-slot layout"
                    )
                self.token_type_embedding = nn.Embedding(
                    TOKEN_TYPE_COUNT,
                    card_embed_dim,
                    padding_idx=0,
                )
                self.token_owner_embedding = nn.Embedding(
                    TOKEN_OWNER_COUNT,
                    card_embed_dim,
                )
                self.register_buffer(
                    "state_token_types",
                    torch.tensor(STATE_TOKEN_TYPES, dtype=torch.long),
                    persistent=False,
                )
                self.register_buffer(
                    "state_token_owners",
                    torch.tensor(STATE_TOKEN_OWNERS, dtype=torch.long),
                    persistent=False,
                )
            else:
                self.token_type_embedding = None
                self.token_owner_embedding = None
                self.state_token_types = None
                self.state_token_owners = None

            # Deck embedding (optional, for per-deck strategy learning)
            if self.deck_embed_dim > 0:
                self.deck_embedding = nn.Embedding(
                    self.num_decks,
                    self.deck_embed_dim,
                )
            else:
                self.deck_embedding = None

            # Multi-head self-attention over card slots for relational reasoning
            if self.use_attention:
                self.card_attn = nn.MultiheadAttention(
                    card_embed_dim,
                    num_heads=self.attention_heads,
                    batch_first=True,
                )
                self.card_attn_norm = nn.LayerNorm(card_embed_dim)
            else:
                self.card_attn = None
                self.card_attn_norm = None

            if self.candidate_cross_attention:
                query_input_dim = action_numeric_size + card_embed_dim
                self.action_query = nn.Linear(query_input_dim, card_embed_dim)
                self.choice_query = nn.Linear(query_input_dim, card_embed_dim)
                self.action_cross_attn = nn.MultiheadAttention(
                    card_embed_dim,
                    num_heads=self.candidate_cross_attention_heads,
                    batch_first=True,
                )
                self.choice_cross_attn = nn.MultiheadAttention(
                    card_embed_dim,
                    num_heads=self.candidate_cross_attention_heads,
                    batch_first=True,
                )
                self.action_cross_norm = nn.LayerNorm(card_embed_dim)
                self.choice_cross_norm = nn.LayerNorm(card_embed_dim)
            else:
                self.action_query = None
                self.choice_query = None
                self.action_cross_attn = None
                self.choice_cross_attn = None
                self.action_cross_norm = None
                self.choice_cross_norm = None

            def make_state_norm():
                if self.state_norm == "batch":
                    return nn.BatchNorm1d(hidden_size)
                return nn.LayerNorm(hidden_size)

            # State encoder: [numeric + pooled_card_embed + optional deck_embed] -> hidden
            state_input_dim = state_numeric_size + card_embed_dim + self.deck_embed_dim
            self.state_net = nn.Sequential(
                nn.Linear(state_input_dim, hidden_size),
                make_state_norm(),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size),
                make_state_norm(),
                nn.ReLU(),
            )

            # Action scorer: pooled v6 control omits the final cross-context.
            candidate_context_dim = (
                card_embed_dim if self.candidate_cross_attention else 0
            )
            scorer_input_dim = (
                hidden_size
                + action_numeric_size
                + card_embed_dim
                + candidate_context_dim
            )
            self.action_net = nn.Sequential(
                nn.Linear(scorer_input_dim, hidden_size),
                nn.ReLU(),
                nn.Linear(hidden_size, hidden_size // 2),
                nn.ReLU(),
                nn.Linear(hidden_size // 2, 1),
            )
            self.choice_net = nn.Sequential(
                nn.Linear(scorer_input_dim, hidden_size),
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

        def _state_features(self, state_numeric, state_card_ids, deck_idx=None):
            state_embeds = self.card_embedding(state_card_ids.long())  # [B, slots, embed_dim]
            card_mask = state_card_ids != 0

            if self.slot_embedding is not None:
                positions = torch.arange(
                    state_card_ids.shape[1],
                    device=state_card_ids.device,
                )
                position_embeds = self.slot_embedding(positions).unsqueeze(0)
                state_embeds = state_embeds + position_embeds * card_mask.unsqueeze(-1)

            if self.token_type_embedding is not None:
                type_embeds = self.token_type_embedding(
                    self.state_token_types
                ).unsqueeze(0)
                owner_embeds = self.token_owner_embedding(
                    self.state_token_owners
                ).unsqueeze(0)
                state_embeds = state_embeds + (
                    type_embeds + owner_embeds
                ) * card_mask.unsqueeze(-1)

            padding_mask = ~card_mask
            empty_rows = padding_mask.all(dim=1, keepdim=True)
            slot_indices = torch.arange(
                padding_mask.shape[1],
                device=padding_mask.device,
            ).unsqueeze(0)
            first_slot = slot_indices == 0
            safe_padding_mask = padding_mask & ~(empty_rows & first_slot)

            # Self-attention: let card slots attend to each other
            if self.card_attn is not None:
                # MultiheadAttention returns NaNs when every token in a row is
                # masked. Keep one zero token visible for empty synthetic states.
                # Keep this entirely tensor-driven so ONNX records the empty-row
                # branch instead of freezing the tracing example's Python bool.
                attn_out, _ = self.card_attn(
                    state_embeds,
                    state_embeds,
                    state_embeds,
                    key_padding_mask=safe_padding_mask,
                    need_weights=False,
                )
                state_embeds = self.card_attn_norm(state_embeds + attn_out)

            # Mean-pool embeddings over card slots (masking pad slots)
            mask = card_mask.float().unsqueeze(-1)
            pooled = (state_embeds * mask).sum(dim=1) / mask.sum(dim=1).clamp_min(1.0)

            parts = [state_numeric.float(), pooled]

            # Optional deck embedding
            if self.deck_embedding is not None and deck_idx is not None:
                deck_emb = self.deck_embedding(deck_idx.long())
                parts.append(deck_emb)
            elif self.deck_embed_dim > 0:
                # No deck_idx provided — use zero embedding
                batch = state_numeric.shape[0]
                parts.append(torch.zeros(batch, self.deck_embed_dim, device=state_numeric.device))

            x = torch.cat(parts, dim=-1)
            return (
                self.state_net(x),
                state_embeds,
                card_mask,
                safe_padding_mask,
            )

        def _state_hidden(self, state_numeric, state_card_ids, deck_idx=None):
            return self._state_features(
                state_numeric,
                state_card_ids,
                deck_idx,
            )[0]

        def _score_candidates(
            self,
            state_hidden,
            state_embeds,
            state_padding_mask,
            candidate_numeric,
            candidate_card_ids,
            scorer,
            candidate_mask=None,
            *,
            query_projection=None,
            cross_attention=None,
            cross_norm=None,
        ):
            candidate_embeds = self.card_embedding(candidate_card_ids.long())
            batch, candidate_count, _ = candidate_numeric.shape
            expanded_state = state_hidden.unsqueeze(1).expand(batch, candidate_count, state_hidden.shape[-1])
            candidate_parts = [
                expanded_state,
                candidate_numeric.float(),
                candidate_embeds,
            ]
            if (
                query_projection is not None
                and cross_attention is not None
                and cross_norm is not None
            ):
                query_input = torch.cat(
                    [candidate_numeric.float(), candidate_embeds],
                    dim=-1,
                )
                query = query_projection(query_input)
                context, _ = cross_attention(
                    query,
                    state_embeds,
                    state_embeds,
                    key_padding_mask=state_padding_mask,
                    need_weights=False,
                )
                candidate_parts.append(cross_norm(query + context))
            candidate_input = torch.cat(candidate_parts, dim=-1)
            logits = scorer(candidate_input).squeeze(-1)
            if candidate_mask is not None:
                mask_value = torch.finfo(logits.dtype).min
                logits = logits.masked_fill(~candidate_mask.bool(), mask_value)
            return logits

        def forward(self, state_numeric, state_card_ids, action_numeric, action_card_ids, action_mask=None, deck_idx=None):
            (
                state_hidden,
                state_embeds,
                _card_mask,
                state_padding_mask,
            ) = self._state_features(state_numeric, state_card_ids, deck_idx)
            logits = self._score_candidates(
                state_hidden,
                state_embeds,
                state_padding_mask,
                action_numeric,
                action_card_ids,
                self.action_net,
                action_mask,
                query_projection=self.action_query,
                cross_attention=self.action_cross_attn,
                cross_norm=self.action_cross_norm,
            )
            value = self.value_head(state_hidden).squeeze(-1)
            return logits, value

        def score_choices(self, state_numeric, state_card_ids, choice_numeric, choice_card_ids, choice_mask=None, deck_idx=None):
            (
                state_hidden,
                state_embeds,
                _card_mask,
                state_padding_mask,
            ) = self._state_features(state_numeric, state_card_ids, deck_idx)
            scorer = self.choice_net if self.choice_head_enabled else self.action_net
            logits = self._score_candidates(
                state_hidden,
                state_embeds,
                state_padding_mask,
                choice_numeric,
                choice_card_ids,
                scorer,
                choice_mask,
                query_projection=self.choice_query,
                cross_attention=self.choice_cross_attn,
                cross_norm=self.choice_cross_norm,
            )
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
    if bool(getattr(model, "_legacy_checkpoint_read_only", False)):
        raise ValueError(
            "Legacy Deep AI checkpoints are read-only and cannot be saved "
            "as encoder-v6/checkpoint-v11 models"
        )
    normalized_metadata = dict(metadata or {})
    normalized_metadata.setdefault("rules_version", RULES_SCHEMA_VERSION)
    normalized_metadata.setdefault("action_version", ACTION_SCHEMA_VERSION)
    normalized_metadata.setdefault("encoder_version", ENCODER_SCHEMA_VERSION)
    normalized_metadata.setdefault("card_vocab_version", CARD_VOCAB_VERSION)
    normalized_metadata.setdefault("card_vocab_sha256", CARD_VOCAB_SHA256)
    normalized_metadata.setdefault("card_vocab_size", CARD_VOCAB_SIZE)
    normalized_metadata.setdefault("card_identity_mode", CARD_IDENTITY_MODE)
    return {
        "version": CHECKPOINT_VERSION,
        "model_state": model.state_dict(),
        "metadata": normalized_metadata,
        "schema": {
            "rules_version": RULES_SCHEMA_VERSION,
            "action_version": ACTION_SCHEMA_VERSION,
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "card_vocab_version": CARD_VOCAB_VERSION,
        },
        "encoder_config": {
            "state_numeric_size": model.state_numeric_size,
            "state_card_slots": model.state_card_slots,
            "action_numeric_size": model.action_numeric_size,
            "card_bucket_count": model.card_bucket_count,
            "card_identity_mode": getattr(
                model, "card_identity_mode", CARD_IDENTITY_MODE
            ),
            "card_vocab_size": CARD_VOCAB_SIZE,
            "card_vocab_sha256": CARD_VOCAB_SHA256,
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
            "use_slot_embeddings": bool(getattr(model, "use_slot_embeddings", False)),
            "state_norm": getattr(model, "state_norm", "layer"),
            "deck_embed_dim": getattr(model, "deck_embed_dim", 0),
            "num_decks": int(getattr(model, "num_decks", 10)),
            "use_token_type_embeddings": bool(
                getattr(model, "use_token_type_embeddings", False)
            ),
            "candidate_cross_attention": bool(
                getattr(model, "candidate_cross_attention", False)
            ),
            "attention_heads": int(getattr(model, "attention_heads", 4)),
            "candidate_cross_attention_heads": int(
                getattr(model, "candidate_cross_attention_heads", 4)
            ),
            "card_identity_mode": getattr(
                model, "card_identity_mode", CARD_IDENTITY_MODE
            ),
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
    config["use_slot_embeddings"] = False
    config["use_token_type_embeddings"] = False
    config["candidate_cross_attention"] = False
    config["attention_heads"] = 4
    config["candidate_cross_attention_heads"] = 4
    config["card_identity_mode"] = "hash_v1"
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
    payload = safe_torch_load(path, map_location=device)
    if isinstance(payload, dict) and "model_state" in payload:
        version = int(payload.get("version") or 0)
        if version >= 11:
            schema = dict(payload.get("schema") or {})
            encoder_config = dict(payload.get("encoder_config") or {})
            compatibility_errors: list[str] = []
            if int(schema.get("encoder_version") or 0) != ENCODER_SCHEMA_VERSION:
                compatibility_errors.append("encoder_version")
            if int(schema.get("card_vocab_version") or 0) != CARD_VOCAB_VERSION:
                compatibility_errors.append("card_vocab_version")
            if int(encoder_config.get("state_card_slots") or 0) != STATE_CARD_SLOTS:
                compatibility_errors.append("state_card_slots")
            if int(encoder_config.get("card_vocab_size") or 0) != CARD_VOCAB_SIZE:
                compatibility_errors.append("card_vocab_size")
            if (
                str(encoder_config.get("card_vocab_sha256") or "")
                != CARD_VOCAB_SHA256
            ):
                compatibility_errors.append("card_vocab_sha256")
            if (
                str(encoder_config.get("card_identity_mode") or "")
                != CARD_IDENTITY_MODE
            ):
                compatibility_errors.append("card_identity_mode")
            if compatibility_errors:
                raise ValueError(
                    "Incompatible encoder-v6 checkpoint: "
                    + ", ".join(compatibility_errors)
                )
        config = dict(payload.get("model_config") or {})
        config.setdefault("choice_head_enabled", version >= 3)
        config.setdefault("use_attention", version >= 5)
        config.setdefault("use_slot_embeddings", version >= 9)
        config.setdefault("state_norm", "layer" if version >= 6 else "batch")
        config.setdefault("deck_embed_dim", 0)  # v6 and older: no deck embedding
        config.setdefault("num_decks", 10)
        config.setdefault("use_token_type_embeddings", version >= 11)
        config.setdefault("candidate_cross_attention", version >= 11)
        config.setdefault("attention_heads", 4)
        config.setdefault("candidate_cross_attention_heads", 4)
        config.setdefault(
            "card_identity_mode",
            CARD_IDENTITY_MODE if version >= 11 else "hash_v1",
        )
        model = create_model(**config)
        strict = version >= 5
        model.load_state_dict(payload["model_state"], strict=strict)
        model.to(device)
        model.eval()
        if version < CHECKPOINT_VERSION:
            model._legacy_checkpoint_read_only = True
            payload.setdefault("compatibility", {})
            payload["compatibility"].update({
                "read_only": True,
                "runtime_compatible": False,
                "loaded_checkpoint_version": version,
                "required_checkpoint_version": CHECKPOINT_VERSION,
            })
        return model, payload
    config = _infer_model_config_from_state_dict(payload)
    config["choice_head_enabled"] = False
    config["state_norm"] = "batch"
    model = create_model(**config)
    model.load_state_dict(payload, strict=False)
    model.to(device)
    model.eval()
    model._legacy_checkpoint_read_only = True
    return model, {
        "version": 0,
        "metadata": {},
        "model_config": config,
        "compatibility": {
            "read_only": True,
            "runtime_compatible": False,
            "loaded_checkpoint_version": 0,
            "required_checkpoint_version": CHECKPOINT_VERSION,
        },
    }

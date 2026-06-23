"""Card synergy pre-training for deep-learning AI.

Before gameplay training, pre-train card embeddings to capture functional
relationships between cards. This gives the model a better inductive bias
about deck synergies — evolution chains, energy-type matching, trainer
card roles, etc.

The pre-training task: given a pair of card embeddings, predict whether
they have a synergistic relationship (binary classification with
contrastive loss).
"""
from __future__ import annotations

import random
from collections import defaultdict
from typing import Any

from data.deck_definitions import (
    COLORLESS_DECK,
    DRAGON_DECK,
    FIGHTING_DECK,
    FIRE_DECK,
    GRASS_DECK,
    LIGHTNING_DECK,
    PSYCHIC_DECK_NATU,
    WATER_DECK,
)

ALL_DECKS = {
    "fire": FIRE_DECK,
    "water": WATER_DECK,
    "psychic": PSYCHIC_DECK_NATU,
    "lightning": LIGHTNING_DECK,
    "fighting": FIGHTING_DECK,
    "colorless": COLORLESS_DECK,
    "dragon": DRAGON_DECK,
    "grass": GRASS_DECK,
}


class SynergyPreTrainer:
    """Build card-synergy datasets and pre-train card embeddings.

    Usage:
        trainer = SynergyPreTrainer()
        pairs, labels = trainer.build_dataset()
        # Train a simple embedding model with contrastive loss on these pairs
        embeddings = trainer.train_embeddings(pairs, labels, embedding_dim=32)
        # Load embeddings into DeepActionModel.card_embedding
    """

    def __init__(self, seed: int = 17):
        self.rng = random.Random(seed)
        self._card_cache: dict[str, Any] = {}

    # ------------------------------------------------------------------
    # Dataset construction
    # ------------------------------------------------------------------

    def build_dataset(self) -> tuple[list[tuple[str, str]], list[float]]:
        """Build (card_id_a, card_id_b, label) triples for synergy pre-training.

        Returns (pairs, labels) where:
        - pairs[i] = (card_id_a, card_id_b)
        - labels[i] = 1.0 if synergistic, 0.0 if not
        """
        pairs: list[tuple[str, str]] = []
        labels: list[float] = []

        for deck_key, deck_spec in ALL_DECKS.items():
            card_ids = [cid for cid, _ in deck_spec]
            card_map = self._build_card_map(card_ids)

            # Positive pairs: cards within same deck that have synergy
            positive_pairs = self._generate_positive_pairs(deck_key, card_ids, card_map)
            for a, b in positive_pairs:
                pairs.append((a, b))
                labels.append(1.0)

            # Negative pairs: random cards from different decks or no synergy
            negative_pairs = self._generate_negative_pairs(
                deck_key, card_ids, card_map, len(positive_pairs)
            )
            for a, b in negative_pairs:
                pairs.append((a, b))
                labels.append(0.0)

        return pairs, labels

    def _build_card_map(self, card_ids: list[str]) -> dict[str, Any]:
        """Build a map from card_id to card metadata for synergy detection."""
        from data.card_registry import CardRegistry

        card_map: dict[str, Any] = {}
        for cid in card_ids:
            if cid in self._card_cache:
                card_map[cid] = self._card_cache[cid]
                continue
            try:
                card = CardRegistry.get(cid)
                self._card_cache[cid] = card
                card_map[cid] = card
            except Exception:
                card_map[cid] = None
        return card_map

    def _generate_positive_pairs(
        self,
        deck_key: str,
        card_ids: list[str],
        card_map: dict[str, Any],
    ) -> list[tuple[str, str]]:
        """Generate pairs of cards that have synergistic relationships."""
        pairs: list[tuple[str, str]] = []
        seen: set[tuple[str, str]] = set()

        def add(a: str, b: str) -> None:
            if a == b:
                return
            key = (a, b) if a < b else (b, a)
            if key not in seen:
                seen.add(key)
                pairs.append((a, b))

        # Categorize cards by type
        pokemon: list[str] = []
        trainers: list[str] = []
        energy_cards: list[str] = []

        for cid in card_ids:
            card = card_map.get(cid)
            if card is None:
                continue
            if getattr(card, "is_pokemon", False):
                pokemon.append(cid)
            elif getattr(card, "is_trainer", False):
                trainers.append(cid)
            elif getattr(card, "is_energy", False):
                energy_cards.append(cid)

        # 1. Evolution chains: Basic <-> Stage1, Stage1 <-> Stage2
        for cid_a in pokemon:
            card_a = card_map.get(cid_a)
            if card_a is None:
                continue
            evolves_to = getattr(card_a, "evolves_to", []) or []
            for cid_b in pokemon:
                if cid_b in evolves_to:
                    add(cid_a, cid_b)
                card_b = card_map.get(cid_b)
                if card_b is None:
                    continue
                if getattr(card_b, "evolves_from", "") == cid_a:
                    add(cid_a, cid_b)

        # 2. Energy type matching: Pokemon <-> matching Energy
        for cid_p in pokemon:
            card_p = card_map.get(cid_p)
            if card_p is None:
                continue
            p_types = set(getattr(card_p, "energy_types", []) or [])
            for cid_e in energy_cards:
                card_e = card_map.get(cid_e)
                if card_e is None:
                    continue
                e_types = set(getattr(card_e, "provides_energy", []) or [])
                e_types.update(getattr(card_e, "energy_types", []) or [])
                if p_types & e_types or "Rainbow" in e_types:
                    add(cid_p, cid_e)

        # 3. Trainer synergy: search cards <-> their typical targets
        search_card_patterns = {
            "sv1-151": "pokemon",       # 巢穴球 → basic Pokemon
            "sv1-153": "pokemon",       # 高级球 → any Pokemon
            "sv1-152": "pokemon",       # 神奇糖果 → Stage 2 Pokemon
            "sv2-catch": "pokemon",     # 宝可梦捕捉器 → opponent bench
            "svi-erec": "energy",       # 能量再利用 → Energy in discard
            "sv3-134": "any",           # 厉害钓竿 → any in discard
        }
        for cid_t in trainers:
            target_type = search_card_patterns.get(cid_t, "")
            if target_type == "pokemon":
                for cid_p in pokemon:
                    card_p = card_map.get(cid_p)
                    if card_p is None:
                        continue
                    if cid_t == "sv1-152":  # Rare Candy: only stage 2 targets
                        if getattr(card_p, "is_stage2", False):
                            add(cid_t, cid_p)
                    elif cid_t == "sv1-151":  # Nest Ball: basic only
                        if getattr(card_p, "is_basic_pokemon", False) and not getattr(card_p, "is_stage1", False):
                            add(cid_t, cid_p)
                    else:
                        add(cid_t, cid_p)
            elif target_type == "energy":
                for cid_e in energy_cards:
                    add(cid_t, cid_e)
            elif target_type == "any":
                for cid_p in pokemon[:3]:  # Sample a few
                    add(cid_t, cid_p)

        # 4. Same-deck co-occurrence: cards in the same deck are loosely synergistic
        # Sample a limited number to avoid overwhelming the dataset
        max_cooccurrence = len(pokemon) * 2
        sampled = 0
        for _ in range(max_cooccurrence * 3):
            if sampled >= max_cooccurrence:
                break
            a = self.rng.choice(pokemon) if pokemon and self.rng.random() < 0.6 else self.rng.choice(card_ids)
            b = self.rng.choice(card_ids)
            if a != b and (a, b) not in seen and (b, a) not in seen:
                add(a, b)
                sampled += 1

        return pairs

    def _generate_negative_pairs(
        self,
        deck_key: str,
        card_ids: list[str],
        card_map: dict[str, Any],
        target_count: int,
    ) -> list[tuple[str, str]]:
        """Generate negative pairs: cards unlikely to have synergy together."""
        pairs: list[tuple[str, str]] = []
        seen: set[tuple[str, str]] = set()

        # Get cards from OTHER decks for true negatives
        other_cards: list[str] = []
        for other_key, other_spec in ALL_DECKS.items():
            if other_key == deck_key:
                continue
            other_cards.extend(cid for cid, _ in other_spec)

        attempts = 0
        max_attempts = target_count * 5
        while len(pairs) < target_count and attempts < max_attempts:
            attempts += 1

            # Mix: 70% cross-deck, 30% same-deck but different card types
            if self.rng.random() < 0.7 and other_cards:
                a = self.rng.choice(card_ids)
                b = self.rng.choice(other_cards)
            else:
                a = self.rng.choice(card_ids)
                b = self.rng.choice(card_ids)

            if a == b:
                continue

            key = (a, b) if a < b else (b, a)
            if key in seen:
                continue

            # Skip pairs that might actually have synergy
            card_a = card_map.get(a)
            card_b = card_map.get(b)
            if card_a is not None and card_b is not None:
                # Same evolution chain = positive, skip
                if getattr(card_a, "evolves_to", []) and b in (getattr(card_a, "evolves_to", []) or []):
                    continue
                if getattr(card_b, "evolves_to", []) and a in (getattr(card_b, "evolves_to", []) or []):
                    continue
                # Energy matching = positive, skip
                a_types = set(getattr(card_a, "energy_types", []) or [])
                b_provides = set(getattr(card_b, "provides_energy", []) or [])
                if a_types & b_provides or "Rainbow" in b_provides:
                    continue
                b_types = set(getattr(card_b, "energy_types", []) or [])
                a_provides = set(getattr(card_a, "provides_energy", []) or [])
                if b_types & a_provides or "Rainbow" in a_provides:
                    continue

            seen.add(key)
            pairs.append((a, b))

        return pairs

    # ------------------------------------------------------------------
    # Embedding pre-training
    # ------------------------------------------------------------------

    def train_embeddings(
        self,
        pairs: list[tuple[str, str]],
        labels: list[float],
        *,
        embedding_dim: int = 32,
        num_epochs: int = 50,
        batch_size: int = 128,
        learning_rate: float = 0.001,
        device: str = "cpu",
    ) -> dict[str, list[float]]:
        """Train card embeddings using contrastive learning on synergy pairs.

        Uses a margin-based contrastive loss:
        - For positive pairs: minimize distance between embeddings
        - For negative pairs: maximize distance (above margin)

        Returns dict mapping card_id -> embedding vector.
        """
        try:
            import torch
        except ImportError:
            raise RuntimeError("PyTorch is required for synergy pre-training")

        # Build card vocabulary
        all_cards = sorted(set(cid for pair in pairs for cid in pair))
        card_to_idx = {cid: i for i, cid in enumerate(all_cards)}
        num_cards = len(all_cards)

        if num_cards < 2:
            return {}

        # Initialize embeddings
        embeddings = torch.nn.Embedding(num_cards, embedding_dim).to(device)
        torch.nn.init.xavier_uniform_(embeddings.weight)

        # Convert pairs to indices
        pair_indices = [
            (card_to_idx[a], card_to_idx[b])
            for a, b in pairs
        ]
        label_tensor = torch.tensor(labels, dtype=torch.float32, device=device)

        optimizer = torch.optim.Adam(embeddings.parameters(), lr=learning_rate)

        # Training loop with contrastive loss
        margin = 0.5
        for epoch in range(num_epochs):
            # Shuffle
            indices = list(range(len(pair_indices)))
            self.rng.shuffle(indices)

            total_loss = 0.0
            num_batches = 0
            for start in range(0, len(indices), batch_size):
                batch_idx = indices[start:start + batch_size]
                batch_pairs = [pair_indices[i] for i in batch_idx]
                batch_labels = label_tensor[batch_idx]

                a_indices = torch.tensor([p[0] for p in batch_pairs], dtype=torch.long, device=device)
                b_indices = torch.tensor([p[1] for p in batch_pairs], dtype=torch.long, device=device)

                emb_a = embeddings(a_indices)
                emb_b = embeddings(b_indices)

                # Cosine similarity
                cos_sim = torch.nn.functional.cosine_similarity(emb_a, emb_b, dim=-1)

                # Contrastive loss: positive → high similarity, negative → low similarity
                positive_mask = batch_labels > 0.5
                negative_mask = ~positive_mask

                loss_pos = (1.0 - cos_sim[positive_mask]).sum() if positive_mask.any() else 0.0
                loss_neg = torch.clamp(cos_sim[negative_mask] - margin, min=0.0).sum() if negative_mask.any() else 0.0

                loss = (loss_pos + loss_neg) / max(1, len(batch_idx))

                optimizer.zero_grad()
                loss.backward()
                optimizer.step()

                total_loss += float(loss.detach().cpu().item())
                num_batches += 1

            if (epoch + 1) % 10 == 0:
                avg_loss = total_loss / max(1, num_batches)
                print(f"  Synergy pre-train epoch {epoch + 1}/{num_epochs}, loss={avg_loss:.4f}")

        # Export embeddings
        with torch.no_grad():
            weight = embeddings.weight.detach().cpu().numpy()

        return {cid: weight[card_to_idx[cid]].tolist() for cid in all_cards}


def load_synergy_embeddings_into_model(
    model: Any,
    synergy_embeddings: dict[str, list[float]],
    encoder: Any,
) -> None:
    """Load pre-trained synergy embeddings into a DeepActionModel.

    Maps card api_ids through the encoder's card_bucket() hash to set
    the model's card_embedding weights appropriately.

    Since card_bucket uses a hash, direct mapping isn't 1:1. Instead,
    we average embeddings that map to the same bucket.
    """
    try:
        import torch
    except ImportError:
        return

    if not synergy_embeddings:
        return

    card_bucket = encoder.card_bucket if hasattr(encoder, "card_bucket") else None
    if card_bucket is None:
        from engine.ai.dl.encoder import card_bucket as _card_bucket
        card_bucket = _card_bucket

    embedding_dim = len(next(iter(synergy_embeddings.values())))
    bucket_count = getattr(model, "card_bucket_count", 4096)

    # Accumulate embeddings per bucket
    bucket_sums: dict[int, list[float]] = defaultdict(lambda: [0.0] * embedding_dim)
    bucket_counts: dict[int, int] = defaultdict(int)

    for cid, emb in synergy_embeddings.items():
        bucket = card_bucket(cid)
        if 0 <= bucket < bucket_count:
            bucket_counts[bucket] += 1
            current = bucket_sums[bucket]
            for i, v in enumerate(emb):
                current[i] += v

    # Average and set weights
    with torch.no_grad():
        weight = model.card_embedding.weight
        for bucket in range(bucket_count):
            if bucket_counts.get(bucket, 0) > 0:
                avg = [v / bucket_counts[bucket] for v in bucket_sums[bucket]]
                weight[bucket] = torch.tensor(avg, dtype=weight.dtype, device=weight.device)
        # Padding index (0) stays at zero
        if hasattr(model.card_embedding, "padding_idx") and model.card_embedding.padding_idx is not None:
            weight[model.card_embedding.padding_idx] = 0.0

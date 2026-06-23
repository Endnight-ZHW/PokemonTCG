"""Curiosity-driven exploration for deep-learning AI training.

Provides intrinsic motivation rewards that encourage the model to visit novel
game states, pushing it beyond the teacher's known strategies.

Two exploration strategies:
1. Count-based: Track state signatures, reward visiting rarely-seen states
2. RND (Random Network Distillation): Predictor network tries to match a fixed
   random target network; prediction error = novelty bonus

The count-based approach is lightweight and works without extra model training.
"""
from __future__ import annotations

import hashlib
import math
from collections import defaultdict
from typing import Any


class StateNoveltyTracker:
    """Count-based exploration bonus using state signature hashing.

    Tracks how often each state "signature" has been visited and provides
    a bonus reward inversely proportional to visit count.

    The signature is a hash over key state features (board positions, HP,
    energy counts, hand size, etc.) to avoid counting truly identical states
    only — similar but not byte-identical states should share the count.

    Usage:
        tracker = StateNoveltyTracker(beta=0.05)
        bonus = tracker.bonus(state, player_idx)
        # total_reward = extrinsic_reward + bonus
    """

    def __init__(
        self,
        beta: float = 0.05,
        beta_anneal_rate: float = 0.9995,
        min_beta: float = 0.005,
        hash_bucket_count: int = 100_000,
    ):
        self.beta = max(0.0, float(beta))
        self.beta_anneal_rate = float(beta_anneal_rate)
        self.min_beta = max(0.0, float(min_beta))
        self._visit_counts: dict[int, int] = defaultdict(int)
        self._total_visits: int = 0
        self._hash_bucket_count = max(1000, int(hash_bucket_count))

    def bonus(self, state: Any, player_idx: int) -> float:
        """Compute intrinsic reward bonus for visiting this state.

        Uses count-based exploration: bonus = beta / sqrt(count + 1).
        Also anneals beta toward min_beta over time.
        """
        if self.beta <= 0:
            return 0.0

        sig = self._state_signature(state, player_idx)
        bucket = sig % self._hash_bucket_count
        count = self._visit_counts[bucket]
        self._visit_counts[bucket] = count + 1
        self._total_visits += 1

        # Anneal beta
        self.beta = max(self.min_beta, self.beta * self.beta_anneal_rate)

        return self.beta / math.sqrt(count + 1)

    def normalize_bonus(self, raw_bonus: float, running_stats: dict[str, float] | None = None) -> float:
        """Normalize bonus reward to stabilize training.

        Without normalization, early-game novelty bonuses can dominate the RL signal.
        """
        if running_stats is None:
            return raw_bonus

        mean = running_stats.get("bonus_mean", 0.0)
        std = max(1e-6, running_stats.get("bonus_std", 1.0))
        return max(-1.0, min(1.0, (raw_bonus - mean) / std))

    def _state_signature(self, state: Any, player_idx: int) -> int:
        """Create a hash-based signature of the game state.

        Captures key strategic features while ignoring irrelevant detail
        (like exact card order within deck).
        """
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)

        features: list[str] = [
            # Phase
            str(getattr(state, "phase", "")),
            str(state.turn_number),
            # Active Pokemon
            self._pokemon_signature(player.active),
            self._pokemon_signature(opponent.active),
            # Bench state
            "|".join(self._pokemon_signature(p) for p in player.bench if p),
            "|".join(self._pokemon_signature(p) for p in opponent.bench if p),
            # Resources
            f"h{len(player.hand)}",
            f"d{len(player.deck)}",
            f"p{6 - len(player.prizes)}",
            f"oh{opponent.hand_count}",
            f"op{6 - len(opponent.prizes)}",
            # Turn flags
            f"e{1 if player.energy_attached_this_turn else 0}",
            f"s{1 if player.supporter_played_this_turn else 0}",
        ]

        joined = "|".join(features)
        digest = hashlib.blake2b(joined.encode("utf-8"), digest_size=8).digest()
        return int.from_bytes(digest, "big")

    def _pokemon_signature(self, pokemon: Any) -> str:
        """Compact signature for a Pokemon in play."""
        if pokemon is None:
            return "_"
        card = getattr(pokemon, "card", None)
        cid = getattr(card, "api_id", "?") if card else "?"
        hp = pokemon.current_hp
        energy = len(getattr(pokemon, "energy_cards", []) or [])
        evolved = len(getattr(pokemon, "evolution_stack", []) or [])
        status = "|".join(sorted(
            str(getattr(s, "name", s)) for s in (getattr(pokemon, "status_conditions", []) or [])
        ))
        return f"{cid}:{hp}:{energy}:{evolved}:{status}"

    def stats(self) -> dict[str, Any]:
        """Return diagnostic statistics."""
        return {
            "total_visits": self._total_visits,
            "unique_states": len(self._visit_counts),
            "current_beta": self.beta,
            "max_visits_single": max(self._visit_counts.values()) if self._visit_counts else 0,
            "median_visits": self._median_visits(),
        }

    def _median_visits(self) -> float:
        if not self._visit_counts:
            return 0.0
        sorted_counts = sorted(self._visit_counts.values())
        n = len(sorted_counts)
        if n % 2 == 1:
            return float(sorted_counts[n // 2])
        return (sorted_counts[n // 2 - 1] + sorted_counts[n // 2]) / 2.0

    def reset(self) -> None:
        """Reset visit counts (e.g., between training runs)."""
        self._visit_counts.clear()
        self._total_visits = 0


# ---------------------------------------------------------------------------
# Optional: Random Network Distillation (RND) for more advanced exploration
# ---------------------------------------------------------------------------

class RNDExplorer:
    """Random Network Distillation exploration bonus.

    Uses a predictor network trained to match a fixed randomly-initialized
    target network. States that are novel produce higher prediction error,
    which becomes the intrinsic reward.

    This is more expressive than count-based exploration because it can
    generalize similarity across states.

    Requires PyTorch.
    """

    def __init__(
        self,
        input_dim: int = 128,
        hidden_dim: int = 64,
        learning_rate: float = 1e-4,
        beta: float = 0.05,
        device: str = "cpu",
    ):
        try:
            import torch
            from torch import nn
        except ImportError:
            raise RuntimeError("PyTorch is required for RNDExplorer")

        self.beta = float(beta)
        self.device = device

        # Target network (fixed, random)
        self.target_net = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
        ).to(device)
        for p in self.target_net.parameters():
            p.requires_grad = False

        # Predictor network (trained to match target)
        self.predictor_net = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
        ).to(device)

        self.optimizer = torch.optim.Adam(self.predictor_net.parameters(), lr=learning_rate)
        self.mse_loss = nn.MSELoss(reduction="none")

        # Running stats for normalization
        self._obs_mean: torch.Tensor | None = None
        self._obs_std: torch.Tensor | None = None
        self._reward_mean: float = 0.0
        self._reward_std: float = 1.0
        self._update_count: int = 0

    def bonus(self, features: list[float]) -> float:
        """Compute RND intrinsic reward for a state feature vector.

        Args:
            features: State feature vector (list of floats).

        Returns:
            Intrinsic reward = MSE(predictor(features), target(features)).
        """
        import torch

        feat_tensor = torch.tensor(features, dtype=torch.float32, device=self.device).unsqueeze(0)

        with torch.no_grad():
            target_out = self.target_net(feat_tensor)
            pred_out = self.predictor_net(feat_tensor)
            error = self.mse_loss(pred_out, target_out).mean(dim=-1)
            raw_bonus = float(error.squeeze().cpu().item())

        # Update running stats
        self._update_count += 1
        if self._update_count <= 1:
            self._reward_mean = raw_bonus
            self._reward_std = 1.0
        else:
            decay = 0.99
            self._reward_mean = decay * self._reward_mean + (1 - decay) * raw_bonus
            self._reward_std = decay * self._reward_std + (1 - decay) * abs(raw_bonus - self._reward_mean)

        # Normalize
        normalized = (raw_bonus - self._reward_mean) / max(1e-6, self._reward_std)
        return self.beta * max(-3.0, min(3.0, normalized))

    def update(self, features_list: list[list[float]]) -> float:
        """Train the predictor on a batch of visited states.

        Returns the average loss.
        """
        import torch

        if not features_list:
            return 0.0

        feats = torch.tensor(features_list, dtype=torch.float32, device=self.device)

        target_out = self.target_net(feats)
        pred_out = self.predictor_net(feats)
        loss = self.mse_loss(pred_out, target_out).mean()

        self.optimizer.zero_grad()
        loss.backward()
        self.optimizer.step()

        return float(loss.detach().cpu().item())


def extract_exploration_features(state, player_idx: int, encoder=None) -> list[float]:
    """Extract a compact feature vector for RND exploration.

    Uses a subset of the full state encoding to keep the RND networks small.
    Falls back to hand-crafted features if no encoder is provided.
    """
    if encoder is not None:
        encoded = encoder.encode_state(state, player_idx)
        # Take the first 128 numeric features as a compact representation
        return encoded.numeric[:128] if len(encoded.numeric) >= 128 else encoded.numeric

    # Fallback: hand-crafted compact features
    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    features: list[float] = []

    # Phase one-hot (simple)
    phase_name = str(getattr(state, "phase", "MAIN"))
    for p in ["SETUP", "DRAW", "MAIN", "ATTACK", "GAME_OVER"]:
        features.append(1.0 if phase_name == p else 0.0)

    # Turn number (normalized)
    features.append(min(1.0, state.turn_number / 20.0))

    # Player resources
    features.append(min(1.0, len(player.hand) / 15.0))
    features.append(min(1.0, len(player.deck) / 60.0))
    features.append(min(1.0, len(player.discard) / 30.0))
    features.append((6 - len(player.prizes)) / 6.0)

    # Opponent resources
    features.append(min(1.0, opponent.hand_count / 15.0))
    features.append((6 - len(opponent.prizes)) / 6.0)

    # Active Pokemon HP ratios
    if player.active:
        features.append(min(1.0, player.active.current_hp / max(1, player.active.card.hp)))
    else:
        features.append(0.0)
    if opponent.active:
        features.append(min(1.0, opponent.active.current_hp / max(1, opponent.active.card.hp)))
    else:
        features.append(0.0)

    # Bench counts
    features.append(player.bench_count() / 5.0)
    features.append(opponent.bench_count() / 5.0)

    # Energy totals
    own_energy = sum(
        len(getattr(p, "energy_cards", []) or [])
        for _, p in player.get_all_pokemon() if p
    )
    features.append(min(1.0, own_energy / 12.0))

    # Pad to 128
    while len(features) < 128:
        features.append(0.0)

    return features[:128]

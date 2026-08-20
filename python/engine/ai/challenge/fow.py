"""Fog-of-war masking and cloning helpers for ChallengeAI."""
from __future__ import annotations

from engine.game_state import GameState
from engine.snapshot import clone_state


class ChallengeAIFogMixin:
    """Owns hidden-zone masking used by fair-information AI search."""

    def _masked_clone_for_eval(self, state: GameState, player_idx: int) -> GameState:
        """Clone a sampled hidden world without exposing opponent identities."""
        from engine.ai.observation import fair_search_clone

        return fair_search_clone(
            state,
            player_idx,
            self.random.randrange(0, 2**31),
        )

    def _clone_state(self, state: GameState) -> GameState:
        return clone_state(state)

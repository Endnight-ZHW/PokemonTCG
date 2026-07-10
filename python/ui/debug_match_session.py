"""Local-only match session used by the Pygame debugging UI.

The Python application is a development surface, not a shipping network client.
Keeping construction of the mutable rules state behind this small facade makes
that boundary explicit while preserving the existing ``GameScreen`` adapter.
"""

from __future__ import annotations

from dataclasses import dataclass

from engine.game_state import GameState
from engine.turn_manager import TurnManager


@dataclass(slots=True)
class DebugMatchSession:
    """Own one local rules state and its legacy turn-manager adapter."""

    state: GameState
    turn_manager: TurnManager

    @classmethod
    def create(
        cls,
        deck_one: list[str],
        deck_two: list[str],
        *,
        apply_type_matchups: bool = False,
    ) -> "DebugMatchSession":
        state = GameState()
        state.apply_type_matchups = bool(apply_type_matchups)
        state.setup_game(deck_one, deck_two)
        return cls(state=state, turn_manager=TurnManager(state))

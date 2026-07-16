"""Local-only match session used by the Pygame debugging UI.

The Python application is a development surface, not a shipping network client.
Keeping construction of the mutable rules state behind this small facade makes
that boundary explicit while preserving the existing ``GameScreen`` adapter.
"""

from __future__ import annotations

from dataclasses import dataclass

from engine.actions import ChoiceResponse
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import GameState
from engine.random_source import RandomSource
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
        rng = RandomSource()
        setup = DEFAULT_GAME_ENGINE.begin_game(state, deck_one, deck_two, rng)
        if not setup.success or setup.pending_choice is None:
            raise ValueError(setup.message or "无法开始对局。")
        # The Python/Pygame surface is a local debugging client.  Keep it
        # playable under the official setup state machine by using the same
        # deterministic policy as Challenge AI; the shipping Godot client
        # exposes the interactive first/second choice.
        response = ChoiceResponse(
            setup.pending_choice.request_id,
            ("turn_order:first",),
        )
        resolved = DEFAULT_GAME_ENGINE.apply_choice(
            state,
            setup.pending_choice,
            response,
            rng,
        )
        if not resolved.success:
            raise ValueError(resolved.message or "无法选择先后攻。")
        return cls(state=state, turn_manager=TurnManager(state))

"""Fog-of-war masking and cloning helpers for ChallengeAI."""
from __future__ import annotations

from engine.game_state import GameState
from engine.snapshot import clone_state


class ChallengeAIFogMixin:
    """Owns hidden-zone masking used by fair-information AI search."""

    @staticmethod
    def _is_opponent_masked(state: GameState, opponent_idx: int) -> bool:
        """Legacy helper retained while old search code is phased out."""
        return False

    def _cleanup_fow_registry(self) -> None:
        """Compatibility no-op: the sampler never mutates CardRegistry."""
        return None

    def _masked_clone_for_eval(self, state: GameState, player_idx: int) -> GameState:
        """Compatibility wrapper around the non-leaking hidden-world sampler."""
        from engine.ai.observation import fair_search_clone

        return fair_search_clone(
            state,
            player_idx,
            self.random.randrange(0, 2**31),
        )

    def _clone_state(self, state: GameState) -> GameState:
        return clone_state(state, rebuild_event_bus=True)

    def _rebuild_event_bus(self, state: GameState):
        from engine.commands.modifier_registration import register_pokemon_modifiers

        state.event_bus.clear()
        for player_idx in (0, 1):
            player = state.get_player(player_idx)
            for slot, pokemon in player.get_all_pokemon():
                if pokemon:
                    register_pokemon_modifiers(pokemon, player_idx, slot, event_bus=state.event_bus)

"""Display-player and board-position helpers for GameScreen."""
from __future__ import annotations

from engine.enums import TurnPhase
from ui.components.hand_display import get_hand_layout


class GameScreenLayoutMixin:
    """Owns view orientation and screen-space board helper methods."""

    def _get_display_player(self):
        """Get the player whose hand/board should be displayed at bottom."""
        if self.challenge_mode:
            return self.state.get_player(self.human_player_idx)
        if self._is_remote_host:
            return self.state.get_player(self.my_player_idx)
        if self._is_remote_client:
            return self.state.get_player(self.my_player_idx)
        if self.state.phase == TurnPhase.SETUP:
            return self.state.get_player(self.setup_player_idx)
        return self.state.get_active_player()

    def _get_opponent(self):
        """Get the opponent for UI rendering."""
        if self.challenge_mode:
            return self.state.get_player(self.ai_player_idx)
        if self._is_remote_host or self._is_remote_client:
            return self.state.get_player(1 - self.my_player_idx)
        if self.state.phase == TurnPhase.SETUP:
            other_idx = 1 - self.setup_player_idx
            return self.state.get_player(other_idx)
        return self.state.get_opponent()

    def _get_display_player_idx(self) -> int:
        if self.challenge_mode:
            return self.human_player_idx
        if self._is_remote_host or self._is_remote_client:
            return self.my_player_idx
        if self.state.phase == TurnPhase.SETUP:
            return self.setup_player_idx
        return self.state.active_player_idx

    def _active_x(self):
        """Center the active card in the play area."""
        return self.layout.player_active.x

    def _bench_row_x(self):
        """Starting X for a row of bench cards, centered in play area."""
        return self.layout.bench_slot("player", 0).x

    def _opp_active_rect(self):
        if not self._get_opponent().active:
            return None
        return self.layout.active_rect("opponent")

    def _opp_bench_rect(self, idx):
        return self.layout.bench_slot("opponent", idx)

    def _player_active_rect(self):
        return self.layout.active_rect("player")

    def _player_bench_rect(self, idx):
        return self.layout.bench_slot("player", idx)

    def _get_hand_layout(self):
        """Calculate hand card positions at the bottom of the screen."""
        return get_hand_layout(self)

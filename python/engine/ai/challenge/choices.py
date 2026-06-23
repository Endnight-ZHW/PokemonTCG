"""Expert pending-choice scoring helpers for ChallengeAI."""
from __future__ import annotations


class ExpertChoiceMixin:
    """Reusable card-choice bonuses for searches, discards, and targets."""

    def _expert_choice_card_value(self, state, player_idx: int, card, *, mode: str = "search") -> float:
        player = state.get_player(player_idx)
        cid = getattr(card, "api_id", "")
        value = 0.0
        if cid in self.profile.core_cards:
            value += 90.0
        if cid in self.profile.engine_cards:
            value += 55.0
        if cid in self.profile.evolution_cards:
            value += 45.0
        if getattr(card, "is_energy", False):
            targets = [pokemon for _, pokemon in player.get_all_pokemon() if pokemon is not None]
            if any(self._best_missing_energy(pokemon) > 0 for pokemon in targets):
                value += 45.0
        if mode == "discard":
            duplicates = sum(1 for held in player.hand if getattr(held, "api_id", None) == cid)
            if cid in self.profile.core_cards and duplicates <= 1:
                value += 120.0
            if duplicates > 1:
                value -= 80.0
            if getattr(card, "is_energy", False) and player.energy_attached_this_turn:
                value -= 35.0
        return value

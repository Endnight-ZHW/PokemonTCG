"""Expert action sequencing helpers for ChallengeAI."""
from __future__ import annotations

from engine.enums import PlayerAction
from engine.effects.runtime_effects import trainer_runtime_effects


class ExpertSequencingMixin:
    """Bonuses that make action ordering look more like a planned turn."""

    def _expert_action_order_bonus(self, state, player_idx: int, action) -> float:
        player = state.get_player(player_idx)
        bonus = 0.0

        if action.kind in {PlayerAction.DECLARE_ATTACK, PlayerAction.RETREAT, PlayerAction.END_TURN}:
            bonus += self._expert_terminal_action_value(state, player_idx, action)

        if action.kind == PlayerAction.ATTACH_ENERGY:
            hand_idx = action.hand_index()
            target_slot = action.target_slot()
            if isinstance(hand_idx, int) and isinstance(target_slot, str) and 0 <= hand_idx < len(player.hand):
                target = player.get_pokemon(target_slot)
                if target is not None:
                    cid = getattr(target.card, "api_id", "")
                    before = self._best_missing_energy(target)
                    after = min(
                        [
                            self._missing_energy_count_with_extra(target, attack.cost, player.hand[hand_idx])
                            for attack in target.card.attacks
                        ] or [before]
                    )
                    if after < before:
                        bonus += 80.0 + (before - after) * 65.0
                    if after == 0:
                        bonus += 130.0
                    if cid in self.profile.core_cards:
                        bonus += 45.0
                    if target_slot == "active" and cid in self.profile.core_cards and before == 0:
                        bonus += 155.0

        elif action.kind == PlayerAction.EVOLVE:
            hand_idx = action.hand_index()
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                card = player.hand[hand_idx]
                cid = getattr(card, "api_id", "")
                bonus += 55.0
                if cid in self.profile.core_cards or cid in self.profile.evolution_cards:
                    bonus += 85.0

        elif action.kind == PlayerAction.USE_ABILITY:
            slot = action.primary_slot()
            pokemon = player.get_pokemon(slot) if isinstance(slot, str) else None
            if pokemon is not None:
                bonus += 35.0
                if self._best_missing_energy(pokemon) > 0:
                    bonus += 35.0

        elif action.kind == PlayerAction.PLAY_TRAINER:
            hand_idx = action.hand_index()
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                card = player.hand[hand_idx]
                effects = trainer_runtime_effects(card)
                if self._effects_include_terminal_development(effects):
                    bonus += 75.0
                if self._effects_include_draw(effects) and len(player.hand) <= 4:
                    bonus += 55.0

        elif action.kind == PlayerAction.PLAY_BASIC:
            hand_idx = action.hand_index()
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                cid = getattr(player.hand[hand_idx], "api_id", "")
                if cid in self.profile.preferred_bench or cid in self.profile.core_cards:
                    bonus += 55.0

        return bonus

    def _expert_terminal_tie_breaker(self, state, player_idx: int, action) -> float:
        if action.kind == PlayerAction.END_TURN:
            return -1000.0
        return self._expert_action_order_bonus(state, player_idx, action)

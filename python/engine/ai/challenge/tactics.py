"""Expert tactical scoring helpers for ChallengeAI."""
from __future__ import annotations

from typing import Any

from engine.enums import PlayerAction


class ExpertTacticsMixin:
    """Small tactical bonuses layered on top of the legacy evaluator."""

    def _expert_state_value_bonus(self, state, player_idx: int) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        score = 0.0

        if player.active and opponent.active:
            own_damage = self._best_available_damage(state, player_idx)
            opp_damage = self._best_available_damage(state, 1 - player_idx)
            if own_damage >= opponent.active.current_hp:
                score += 220 + opponent.active.card.prize_value * 120
            if opp_damage >= player.active.current_hp:
                score -= 240 + player.active.card.prize_value * 130

        ready_attackers = 0
        nearly_ready_core = 0
        for slot, pokemon in player.get_all_pokemon():
            if pokemon is None:
                continue
            missing = self._best_missing_energy(pokemon)
            cid = getattr(pokemon.card, "api_id", "")
            if missing == 0 and getattr(pokemon.card, "attacks", None):
                ready_attackers += 1
            if missing <= 1 and cid in self.profile.core_cards:
                nearly_ready_core += 1
            if slot != "active" and cid in self.profile.core_cards and missing > 1:
                score -= min(90.0, missing * 24.0)

        score += ready_attackers * 55
        score += nearly_ready_core * 40
        if player.bench_count() == 0 and len(player.prizes) <= 4:
            score -= 95
        return score

    def _expert_terminal_action_value(self, state, player_idx: int, action) -> float:
        if action.kind == PlayerAction.DECLARE_ATTACK:
            attack_idx = action.attack_index()
            if isinstance(attack_idx, int):
                damage = self._estimated_attack_damage(state, player_idx, attack_idx)
                opponent = state.get_player(1 - player_idx)
                if opponent.active and damage >= opponent.active.current_hp:
                    return 520.0 + opponent.active.card.prize_value * 180.0
                return damage * 0.9
        if action.kind == PlayerAction.END_TURN:
            return -120.0
        if action.kind == PlayerAction.RETREAT:
            bench_idx = action.bench_index()
            if isinstance(bench_idx, int):
                player = state.get_player(player_idx)
                if 0 <= bench_idx < len(player.bench):
                    target = player.bench[bench_idx]
                    if target is not None:
                        return self._promotion_value_for_state(state, player_idx, target) * 0.12
        return 0.0

    def _expert_target_pressure(self, state, player_idx: int, pokemon: Any) -> float:
        if pokemon is None:
            return 0.0
        value = pokemon.card.prize_value * 55.0
        if pokemon.current_hp <= 70:
            value += 70.0
        if self._best_available_damage_against_candidate(state, player_idx, pokemon) >= pokemon.current_hp:
            value -= 90.0
        return value

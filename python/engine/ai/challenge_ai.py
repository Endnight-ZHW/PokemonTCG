"""Fair-information challenge AI for local single-player matches.

The AI acts only through the normal rules layer.  It may inspect its own hidden
zones, but scoring and action generation intentionally avoid the opponent's
hand/deck/prize identities.
"""
from __future__ import annotations

import random
import time
from dataclasses import replace
from typing import Any

from engine.enums import PlayerAction, StatusType, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.ai.challenge.choices import ExpertChoiceMixin
from engine.ai.challenge.fow import ChallengeAIFogMixin
from engine.ai.challenge.layers import ActionEnumerator, ChoicePolicy, Evaluator, Simulator
from engine.ai.challenge.sequencing import ExpertSequencingMixin
from engine.ai.challenge.tactics import ExpertTacticsMixin
from engine.ai.challenge.types import AIAction, AIChoice, AIConfig
from engine.ai.effect_features import (
    as_effect_list,
    effect_branch,
    effect_branches,
    effect_feature_names,
    effect_params,
    effect_type,
    iter_effects_recursive,
)
from engine.ai.profiles import (
    get_deck_ai_profile,
    load_policy_weights,
    merged_profile_weights,
)
from engine.effects.runtime_effects import (
    ability_runtime_effects,
    attack_runtime_effects,
    trainer_runtime_effects,
)
from engine.rules_validator import (
    can_attach_energy,
    can_declare_attack,
    can_evolve,
    can_play_item,
    can_play_stadium,
    can_play_supporter,
    can_play_tool,
    can_retreat,
    can_use_ability,
)
from utils.logger import get_logger

_logger = get_logger(__name__)
from engine.turn_manager import TurnManager


class ChallengeAI(ExpertSequencingMixin, ExpertChoiceMixin, ExpertTacticsMixin, ChallengeAIFogMixin):
    """Rules-policy backend using the shared information-set planner."""

    def __init__(self, config: AIConfig | None = None):
        self.config = config or AIConfig()
        self.profile = self.config.profile or get_deck_ai_profile(self.config.deck_key)
        loaded_weights = (
            self.config.policy_weights
            if self.config.policy_weights is not None
            else load_policy_weights(self.profile.key, self.config.policy_path)
        )
        self.policy_weights = merged_profile_weights(self.profile, loaded_weights)
        self.random = random.Random(self.config.random_seed)
        self.last_decision_trace: dict[str, Any] = {}
        self._last_legal_action_trace: dict[str, Any] = {}
        self.enumerator = ActionEnumerator(self)
        self.simulator = Simulator(self)
        self.evaluator = Evaluator(self)
        self.choice_policy = ChoicePolicy(self)
        self.planner = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def choose_action(self, state: GameState, player_idx: int) -> AIAction:
        if state.phase == TurnPhase.SETUP:
            selected = self._choose_setup_action(state, player_idx)
            self._record_decision_trace(state, player_idx, selected)
            return selected
        if state.phase == TurnPhase.ATTACK:
            selected = AIAction(PlayerAction.END_TURN, {}, terminal=True)
            self._record_decision_trace(state, player_idx, selected)
            return selected
        if state.phase != TurnPhase.MAIN:
            selected = AIAction(PlayerAction.END_TURN, {}, terminal=True)
            self._record_decision_trace(state, player_idx, selected)
            return selected

        deadline = (
            float("inf")
            if self.config.deterministic_search
            else time.perf_counter() + max(0.01, self.config.thinking_time_seconds)
        )
        selected = self._unified_search_action(state, player_idx, deadline)
        self._record_decision_trace(state, player_idx, selected)
        return selected

    def _unified_search_action(
        self,
        state: GameState,
        player_idx: int,
        deadline: float,
    ) -> AIAction:
        from engine.ai.planner import AnytimePlanner, HeuristicBackend, PlannerConfig

        root_actions = self.legal_actions(state, player_idx)
        if not root_actions:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True, actor=player_idx)
        backend = HeuristicBackend(
            priority=self._quick_action_priority,
            evaluator=self.evaluate_state,
            choice_resolver=self.resolve_pending_action,
        )
        thinking_time = max(0.01, float(self.config.thinking_time_seconds))
        planner_deadline = deadline
        self.planner = AnytimePlanner(
            backend,
            PlannerConfig(
                thinking_time_seconds=thinking_time,
                simulation_budget=max(1, int(self.config.search_node_budget)),
                max_depth=max(2, int(self.config.planner_max_depth)),
                opponent_branch_limit=max(
                    1,
                    int(self.config.response_branch_limit or self.config.opponent_response_actions),
                ),
                random_seed=int(self.config.random_seed),
            ),
        )
        selected = self.planner.search(
            state,
            player_idx,
            actions=root_actions,
            deadline=planner_deadline,
        )
        return self._validated_or_fallback_action(
            state,
            player_idx,
            selected,
            root_actions,
        )

    def explain_legal_actions(self, state: GameState, player_idx: int) -> dict[str, Any]:
        """Return the last legal-action trace after recomputing candidates."""
        self.legal_actions(state, player_idx)
        return dict(self._last_legal_action_trace)

    def cancel_search(self) -> None:
        if self.planner is not None:
            self.planner.cancel()

    def _validated_or_fallback_action(
        self,
        state: GameState,
        player_idx: int,
        preferred: AIAction,
        fallback_actions: list[AIAction],
    ) -> AIAction:
        ko_attack = self._best_immediate_ko_attack(state, player_idx, fallback_actions)
        if ko_attack is not None and self._should_override_with_ko_attack(state, player_idx, preferred, ko_attack):
            return ko_attack
        if preferred.action == PlayerAction.DECLARE_ATTACK:
            if self._attack_draw_pressure_is_unsafe(state, player_idx, preferred):
                productive_action = self._best_productive_nonterminal_action(state, player_idx, fallback_actions)
                if productive_action is not None:
                    return productive_action
                end_turn = next((a for a in fallback_actions if a.action == PlayerAction.END_TURN), None)
                if end_turn is not None:
                    return end_turn
            if self._attack_feeds_dangerous_retaliation(state, player_idx, preferred):
                productive_action = self._best_productive_nonterminal_action(state, player_idx, fallback_actions)
                if productive_action is not None:
                    return productive_action
                end_turn = next((a for a in fallback_actions if a.action == PlayerAction.END_TURN), None)
                if end_turn is not None:
                    return end_turn
            development_action = self._best_pre_attack_development_action(
                state, player_idx, preferred, fallback_actions
            )
            if development_action is not None:
                return development_action
        if preferred.action in {PlayerAction.RETREAT, PlayerAction.END_TURN}:
            development_action = self._best_pre_terminal_development_action(
                state, player_idx, preferred, fallback_actions
            )
            if development_action is not None:
                return development_action
        if preferred.action == PlayerAction.PLAY_TRAINER:
            development_action = self._best_pre_major_draw_development_action(
                state, player_idx, preferred, fallback_actions
            )
            if development_action is not None:
                return development_action
        if preferred.action == PlayerAction.END_TURN:
            productive_attack = self._best_productive_attack(state, player_idx, fallback_actions)
            if productive_attack is not None:
                return productive_attack
            damaging_attack = self._best_damaging_attack(state, player_idx, fallback_actions)
            if damaging_attack is not None:
                return damaging_attack
            productive_action = self._best_productive_nonterminal_action(state, player_idx, fallback_actions)
            if productive_action is not None:
                return productive_action
        if self._action_executes_successfully(state, player_idx, preferred):
            return preferred
        for action in fallback_actions:
            if self._action_executes_successfully(state, player_idx, action):
                return action
        return AIAction(PlayerAction.END_TURN, {}, terminal=True)

    def _best_immediate_ko_attack(
        self, state: GameState, player_idx: int, actions: list[AIAction]
    ) -> AIAction | None:
        if not hasattr(state, "get_player"):
            return None
        opponent = state.get_player(1 - player_idx)
        if opponent.active is None:
            return None
        candidates: list[tuple[float, AIAction]] = []
        for action in actions:
            if action.action != PlayerAction.DECLARE_ATTACK:
                continue
            attack_idx = action.params.get("attack_idx")
            if not isinstance(attack_idx, int):
                continue
            damage = self._estimated_attack_damage(state, player_idx, attack_idx)
            if damage < opponent.active.current_hp:
                continue
            value = damage + opponent.active.card.prize_value * 120
            candidates.append((value, action))
        if not candidates:
            return None
        candidates.sort(key=lambda row: row[0], reverse=True)
        action = candidates[0][1]
        return action if self._action_executes_successfully(state, player_idx, action) else None

    def _best_productive_attack(
        self, state: GameState, player_idx: int, actions: list[AIAction]
    ) -> AIAction | None:
        if not hasattr(state, "get_player"):
            return None
        player = state.get_player(player_idx)
        if player.active is None:
            return None
        candidates: list[tuple[float, AIAction]] = []
        for action in actions:
            if action.action != PlayerAction.DECLARE_ATTACK:
                continue
            attack_idx = action.params.get("attack_idx")
            if not isinstance(attack_idx, int) or not (0 <= attack_idx < len(player.active.card.attacks)):
                continue
            attack = player.active.card.attacks[attack_idx]
            effects = attack_runtime_effects(attack)
            if self._attack_draw_pressure_is_unsafe(state, player_idx, action):
                continue
            if not self._attack_has_productive_effect(effects):
                continue
            if self._attack_feeds_dangerous_retaliation(state, player_idx, action):
                continue
            utility = self._effect_tactical_value(state, player_idx, effects)
            damage = self._estimated_attack_damage(state, player_idx, attack_idx)
            value = utility * 2.2 + damage * 0.45
            if self._effects_include_draw(effects) and len(player.hand) <= 3:
                value += 85
            if damage <= 0 and utility < 20:
                continue
            candidates.append((value, action))
        candidates.sort(key=lambda row: row[0], reverse=True)
        for _value, action in candidates:
            if self._action_executes_successfully(state, player_idx, action):
                return action
        return None

    def _best_damaging_attack(
        self, state: GameState, player_idx: int, actions: list[AIAction]
    ) -> AIAction | None:
        if not hasattr(state, "get_player"):
            return None
        player = state.get_player(player_idx)
        if player.active is None:
            return None
        base_score = self.evaluate_state(state, player_idx)
        candidates: list[tuple[float, AIAction]] = []
        for action in actions:
            if action.action != PlayerAction.DECLARE_ATTACK:
                continue
            attack_idx = action.params.get("attack_idx")
            if not isinstance(attack_idx, int) or not (0 <= attack_idx < len(player.active.card.attacks)):
                continue
            damage = self._estimated_attack_damage(state, player_idx, attack_idx)
            attack = player.active.card.attacks[attack_idx]
            effect_value = self._effect_tactical_value(
                state, player_idx, attack_runtime_effects(attack)
            )
            if self._attack_draw_pressure_is_unsafe(state, player_idx, action):
                continue
            if damage <= 0 and effect_value <= 0:
                continue
            if self._attack_feeds_dangerous_retaliation(state, player_idx, action):
                continue
            sim_score = self._simulated_action_score(state, player_idx, action)
            if sim_score is None:
                continue
            # Avoid emergency attacks that immediately lose the game unless no
            # legal validation path can see the loss. Normal damaging attacks
            # should never be ranked below an empty pass.
            value = (sim_score - base_score) + damage * 0.55 + effect_value * 0.35
            candidates.append((value, action))
        if not candidates:
            return None
        candidates.sort(key=lambda row: row[0], reverse=True)
        return candidates[0][1]

    def _best_productive_nonterminal_action(
        self, state: GameState, player_idx: int, actions: list[AIAction]
    ) -> AIAction | None:
        base_score = self.evaluate_state(state, player_idx)
        candidates: list[tuple[float, AIAction]] = []
        productive_types = {
            PlayerAction.USE_ABILITY,
            PlayerAction.PLAY_TRAINER,
            PlayerAction.ATTACH_ENERGY,
            PlayerAction.EVOLVE,
            PlayerAction.PLAY_BASIC,
        }
        for action in actions:
            if action.action not in productive_types:
                continue
            sim_score = self._simulated_action_score(state, player_idx, action)
            if sim_score is None:
                continue
            delta = sim_score - base_score
            quick = self._quick_action_priority(state, player_idx, action)
            if delta < 8 and quick < 360:
                continue
            candidates.append((delta + quick * 0.08, action))
        if not candidates:
            return None
        candidates.sort(key=lambda row: row[0], reverse=True)
        return candidates[0][1]

    def _attack_feeds_dangerous_retaliation(
        self, state: GameState, player_idx: int, attack_action: AIAction
    ) -> bool:
        if attack_action.action != PlayerAction.DECLARE_ATTACK:
            return False
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if player.active is None or opponent.active is None:
            return False
        attack_idx = attack_action.params.get("attack_idx")
        if not isinstance(attack_idx, int):
            return False
        damage = self._estimated_attack_damage(state, player_idx, attack_idx)
        if damage <= 0 or damage >= opponent.active.current_hp:
            return False
        if not any(
            self._effect_type(effect) == "damage_per_self_damage"
            for attack in opponent.active.card.attacks
            for effect in attack_runtime_effects(attack)
        ):
            return False

        before = self._best_potential_retaliation_damage(state, 1 - player_idx)
        sim = self._clone_state(state)
        sim_opp = sim.get_player(1 - player_idx).active
        if sim_opp is None:
            return False
        sim_opp.damage_counters += max(1, damage // 10)
        after = self._best_potential_retaliation_damage(sim, 1 - player_idx)
        if after <= before + 20:
            return False
        if after <= before + 30 and after < 90:
            return False
        if after >= player.active.current_hp:
            return True
        if before >= player.active.current_hp:
            return False
        return damage < 100 and after >= max(90, player.active.current_hp * 0.45)

    def _best_potential_retaliation_damage(self, state: GameState, player_idx: int) -> int:
        """Estimate immediate or one-attachment retaliation from the active Pokemon."""
        player = state.get_player(player_idx)
        if player.active is None:
            return 0
        best = self._best_available_damage(state, player_idx)
        can_reasonably_attach = player.hand_count > 0 or bool(player.deck)
        if not can_reasonably_attach:
            return best
        for attack_idx, attack in enumerate(player.active.card.attacks):
            if not any(
                self._effect_type(effect) == "damage_per_self_damage"
                for effect in attack_runtime_effects(attack)
            ):
                continue
            if self._missing_energy_count(player.active, attack.cost) <= 1:
                best = max(best, self._estimated_attack_damage(state, player_idx, attack_idx))
        return best

    def _best_pre_major_draw_development_action(
        self,
        state: GameState,
        player_idx: int,
        preferred_trainer: AIAction,
        actions: list[AIAction],
    ) -> AIAction | None:
        """Cash in clear board resources before a large hand refresh."""
        if not self._is_major_hand_refresh_action(state, player_idx, preferred_trainer):
            return None
        base_score = self.evaluate_state(state, player_idx)
        trainer_score = self._simulated_action_score(state, player_idx, preferred_trainer)
        candidates: list[tuple[float, AIAction]] = []
        for action in actions:
            if action == preferred_trainer:
                continue
            if action.action not in {
                PlayerAction.ATTACH_ENERGY,
                PlayerAction.EVOLVE,
                PlayerAction.USE_ABILITY,
                PlayerAction.PLAY_BASIC,
            }:
                continue
            value = self._pre_major_draw_development_value(
                state, player_idx, action, base_score, trainer_score
            )
            if value <= 0:
                continue
            candidates.append((value, action))
        if not candidates:
            return None
        candidates.sort(key=lambda row: row[0], reverse=True)
        return candidates[0][1]

    def _is_major_hand_refresh_action(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> bool:
        if action.action != PlayerAction.PLAY_TRAINER:
            return False
        player = state.get_player(player_idx)
        hand_idx = action.params.get("hand_idx")
        if not isinstance(hand_idx, int) or not (0 <= hand_idx < len(player.hand)):
            return False
        effects = trainer_runtime_effects(player.hand[hand_idx])
        return self._effects_include_major_hand_refresh(effects)

    def _effects_include_major_hand_refresh(self, effects: list[Any]) -> bool:
        effects = as_effect_list(effects)
        for effect in effects or []:
            etype = self._effect_type(effect)
            if etype in {
                "discard_draw",
                "shuffle_draw",
                "judge",
                "houb",
                "zinnia_resolve",
            }:
                return True
            if etype == "discard_then_draw":
                params = self._effect_params(effect)
                if int(params.get("draw_amount", params.get("draw", 0)) or 0) >= 3:
                    return True
            for key in ("on_heads", "on_tails", "on_success", "on_fail", "on_pay"):
                branch = effect_branch(effect, key)
                if self._effects_include_major_hand_refresh(branch):
                    return True
        return False

    def _best_pre_terminal_development_action(
        self,
        state: GameState,
        player_idx: int,
        preferred: AIAction,
        actions: list[AIAction],
    ) -> AIAction | None:
        """Cash in clear development before a terminal pass or switch."""
        if preferred.action not in {PlayerAction.RETREAT, PlayerAction.END_TURN}:
            return None
        base_score = self.evaluate_state(state, player_idx)
        preferred_score = None
        if preferred.action != PlayerAction.END_TURN:
            preferred_score = self._simulated_action_score(state, player_idx, preferred)
        allow_draw = preferred.action == PlayerAction.END_TURN
        candidates: list[tuple[float, AIAction]] = []
        for action in actions:
            if action == preferred or action.action in {
                PlayerAction.DECLARE_ATTACK,
                PlayerAction.RETREAT,
                PlayerAction.END_TURN,
            }:
                continue
            if action.action not in {
                PlayerAction.ATTACH_ENERGY,
                PlayerAction.EVOLVE,
                PlayerAction.USE_ABILITY,
                PlayerAction.PLAY_TRAINER,
                PlayerAction.PLAY_BASIC,
            }:
                continue
            value = self._pre_terminal_development_value(
                state, player_idx, action, base_score, preferred_score, allow_draw
            )
            if value <= 0:
                continue
            candidates.append((value, action))
        if not candidates:
            return None
        candidates.sort(key=lambda row: row[0], reverse=True)
        return candidates[0][1]

    def _pre_terminal_development_value(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
        base_score: float,
        preferred_score: float | None,
        allow_draw: bool,
    ) -> float:
        sim_score = self._simulated_action_score(state, player_idx, action)
        if sim_score is None:
            return 0.0
        delta = sim_score - base_score
        terminal_delta = 0.0 if preferred_score is None else sim_score - preferred_score
        quick = self._quick_action_priority(state, player_idx, action)
        value = max(0.0, delta) * 0.22 + max(0.0, terminal_delta) * 0.35

        if action.action == PlayerAction.ATTACH_ENERGY:
            attach_value = self._pre_attack_attach_value(state, player_idx, action)
            if attach_value <= 0:
                return 0.0
            value += 65.0 + attach_value * 0.72
        elif action.action == PlayerAction.EVOLVE:
            value += 60.0 + max(0.0, quick - 320.0) * 0.20
        elif action.action == PlayerAction.USE_ABILITY:
            slot = action.params.get("slot")
            ability = self._ability_for_action(state, player_idx, action)
            if ability is None:
                return 0.0
            effects = ability_runtime_effects(ability)
            effect_value = self._effect_tactical_value(
                state, player_idx, effects, source_slot=slot if isinstance(slot, str) else None
            )
            converts = self._ability_converts_pre_draw_resource(state, player_idx, slot, effects)
            if not converts and effect_value < 70:
                return 0.0
            value += 70.0 + effect_value * 0.65 + max(0.0, quick - 300.0) * 0.22
        elif action.action == PlayerAction.PLAY_TRAINER:
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if not isinstance(hand_idx, int) or not (0 <= hand_idx < len(player.hand)):
                return 0.0
            effects = trainer_runtime_effects(player.hand[hand_idx])
            if self._effects_include_major_hand_refresh(effects) and not allow_draw:
                return 0.0
            effect_value = self._effect_tactical_value(state, player_idx, effects)
            resource_effect = self._effects_include_terminal_development(effects)
            if not resource_effect and not (allow_draw and self._effects_include_draw(effects)):
                return 0.0
            value += 55.0 + effect_value * 0.68 + max(0.0, quick - 360.0) * 0.22
            if resource_effect:
                value += 35.0
        elif action.action == PlayerAction.PLAY_BASIC:
            if not allow_draw:
                return 0.0
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if not isinstance(hand_idx, int) or not (0 <= hand_idx < len(player.hand)):
                return 0.0
            cid = getattr(player.hand[hand_idx], "api_id", "")
            if cid not in self.profile.core_cards and cid not in self.profile.preferred_bench:
                return 0.0
            value += 50.0 + self._profile_card_bonus(state, player_idx, player.hand[hand_idx]) * 0.35

        return value if value >= 80.0 else 0.0

    def _effects_include_terminal_development(self, effects: list[Any]) -> bool:
        effects = as_effect_list(effects)
        for effect in effects or []:
            etype = self._effect_type(effect)
            if etype in {
                "energy_attach",
                "attach_from_discard",
                "draw_and_attach_energy",
                "energy_relocate",
                "look_top_deck",
                "search",
                "conditional_search_extra",
                "search_any_and_switch",
                "shuffle_from_discard",
            }:
                return True
            for branch in effect_branches(effect):
                if self._effects_include_terminal_development(branch):
                    return True
        return False

    def _pre_major_draw_development_value(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
        base_score: float,
        trainer_score: float | None,
    ) -> float:
        sim_score = self._simulated_action_score(state, player_idx, action)
        if sim_score is None:
            return 0.0
        delta = sim_score - base_score
        trainer_delta = 0.0 if trainer_score is None else sim_score - trainer_score
        quick = self._quick_action_priority(state, player_idx, action)
        value = max(0.0, delta) * 0.25 + max(0.0, trainer_delta) * 0.18

        if action.action == PlayerAction.ATTACH_ENERGY:
            attach_value = self._pre_attack_attach_value(state, player_idx, action)
            if attach_value <= 0:
                return 0.0
            value += 70.0 + attach_value * 0.75
        elif action.action == PlayerAction.EVOLVE:
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            card_bonus = 0.0
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                card_bonus = self._profile_card_bonus(state, player_idx, player.hand[hand_idx])
            value += 80.0 + max(0.0, quick - 320.0) * 0.20 + card_bonus * 0.35
        elif action.action == PlayerAction.PLAY_BASIC:
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if not isinstance(hand_idx, int) or not (0 <= hand_idx < len(player.hand)):
                return 0.0
            card = player.hand[hand_idx]
            cid = getattr(card, "api_id", "")
            if cid not in self.profile.core_cards and cid not in self.profile.preferred_bench:
                return 0.0
            value += 70.0 + self._profile_card_bonus(state, player_idx, card) * 0.45
            if player.bench_count() < 3:
                value += 25.0
        elif action.action == PlayerAction.USE_ABILITY:
            slot = action.params.get("slot")
            ability = self._ability_for_action(state, player_idx, action)
            if ability is None:
                return 0.0
            effects = ability_runtime_effects(ability)
            if not self._ability_converts_pre_draw_resource(state, player_idx, slot, effects):
                return 0.0
            value += 85.0
            value += self._effect_tactical_value(
                state, player_idx, effects, source_slot=slot if isinstance(slot, str) else None
            ) * 0.55
            value += max(0.0, quick - 300.0) * 0.25

        return value if value >= 75.0 else 0.0

    def _ability_for_action(self, state: GameState, player_idx: int, action: AIAction):
        player = state.get_player(player_idx)
        slot = action.params.get("slot")
        ability_name = action.params.get("ability_name")
        if not isinstance(slot, str) or not isinstance(ability_name, str):
            return None
        pokemon = player.get_pokemon(slot)
        if pokemon is None:
            return None
        return next((a for a in pokemon.card.abilities if a.name == ability_name), None)

    def _ability_converts_pre_draw_resource(
        self,
        state: GameState,
        player_idx: int,
        source_slot: Any,
        effects: list[Any],
    ) -> bool:
        effects = as_effect_list(effects)
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = dict(self._effect_params(effect))
            if etype in ("energy_attach", "attach_from_discard", "draw_and_attach_energy"):
                if etype == "attach_from_discard":
                    params.setdefault("from_zone", "discard")
                elif etype == "energy_attach":
                    params.setdefault("from_zone", "hand")
                if self._energy_acceleration_value(
                    state, player_idx, params, source_slot if isinstance(source_slot, str) else None
                ) > 0:
                    return True
            elif etype == "energy_relocate":
                if self._best_energy_relocation_gain(
                    state, player_idx, source_slot if isinstance(source_slot, str) else None, params
                ) > 0:
                    return True
            for branch in effect_branches(effect):
                if self._ability_converts_pre_draw_resource(state, player_idx, source_slot, branch):
                    return True
        return False

    def _best_pre_attack_development_action(
        self,
        state: GameState,
        player_idx: int,
        preferred_attack: AIAction,
        actions: list[AIAction],
    ) -> AIAction | None:
        """Prefer obvious development before ending the turn with a weak attack."""
        if not hasattr(state, "get_player"):
            return None
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if player.active is None or opponent.active is None:
            return None
        attack_idx = preferred_attack.params.get("attack_idx")
        if not isinstance(attack_idx, int) or not (0 <= attack_idx < len(player.active.card.attacks)):
            return None

        attack = player.active.card.attacks[attack_idx]
        damage = self._estimated_attack_damage(state, player_idx, attack_idx)
        effect_value = self._effect_tactical_value(
            state, player_idx, attack_runtime_effects(attack)
        )
        if damage >= opponent.active.current_hp:
            return None
        if damage >= 95 or effect_value >= 95:
            return None
        if damage >= 70 and opponent.active.current_hp <= damage + 30:
            return None

        base_score = self.evaluate_state(state, player_idx)
        attack_score = self._simulated_action_score(state, player_idx, preferred_attack)
        candidates: list[tuple[float, AIAction]] = []
        for action in actions:
            if action.action not in {
                PlayerAction.ATTACH_ENERGY,
                PlayerAction.EVOLVE,
                PlayerAction.USE_ABILITY,
                PlayerAction.PLAY_TRAINER,
                PlayerAction.PLAY_BASIC,
            }:
                continue
            value = self._pre_attack_development_value(
                state, player_idx, action, base_score, attack_score
            )
            if value <= 0:
                continue
            candidates.append((value, action))
        if not candidates:
            return None
        candidates.sort(key=lambda row: row[0], reverse=True)
        return candidates[0][1]

    def _pre_attack_development_value(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
        base_score: float,
        attack_score: float | None = None,
    ) -> float:
        sim_score = self._simulated_action_score(state, player_idx, action)
        if sim_score is None:
            return 0.0
        delta = sim_score - base_score
        attack_delta = 0.0 if attack_score is None else sim_score - attack_score
        quick = self._quick_action_priority(state, player_idx, action)
        value = 0.0
        if action.action == PlayerAction.ATTACH_ENERGY:
            value += self._pre_attack_attach_value(state, player_idx, action)
        elif action.action == PlayerAction.EVOLVE:
            value += 55.0 + max(0.0, delta) * 0.20
        elif action.action == PlayerAction.USE_ABILITY:
            effects = []
            slot = action.params.get("slot")
            ability_name = action.params.get("ability_name")
            player = state.get_player(player_idx)
            if isinstance(slot, str) and isinstance(ability_name, str):
                pokemon = player.get_pokemon(slot)
                if pokemon is not None:
                    ability = next((a for a in pokemon.card.abilities if a.name == ability_name), None)
                    effects = ability_runtime_effects(ability) if ability is not None else []
            value += max(0.0, delta) * 0.35 + max(0.0, quick - 300.0) * 0.20
            value += self._effect_tactical_value(state, player_idx, effects, source_slot=slot if isinstance(slot, str) else None) * 0.35
            if self._attack_has_productive_effect(effects):
                value += 8.0
        elif action.action == PlayerAction.PLAY_TRAINER:
            effects = []
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                effects = trainer_runtime_effects(player.hand[hand_idx])
            value += max(0.0, delta) * 0.25 + max(0.0, quick - 360.0) * 0.18
            value += self._effect_tactical_value(state, player_idx, effects) * 0.45
            if self._attack_has_productive_effect(effects):
                value += 8.0
            if self._effects_include_draw(effects) and len(player.hand) <= 3:
                value += 12.0
        elif action.action == PlayerAction.PLAY_BASIC:
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                cid = getattr(player.hand[hand_idx], "api_id", "")
                if cid in self.profile.core_cards or cid in self.profile.preferred_bench:
                    value += 45.0
                if player.bench_count() < 3:
                    value += 35.0
            value += max(0.0, delta) * 0.18
        if delta >= 35:
            value += delta * 0.35
        if attack_delta >= 25:
            value += attack_delta * 0.55
        if quick >= 430:
            value += (quick - 430) * 0.08
        return value if value >= 45.0 else 0.0

    def _pre_attack_attach_value(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> float:
        player = state.get_player(player_idx)
        hand_idx = action.params.get("hand_idx")
        target_slot = action.params.get("target_slot")
        if not isinstance(hand_idx, int) or not isinstance(target_slot, str):
            return 0.0
        if not (0 <= hand_idx < len(player.hand)):
            return 0.0
        pokemon = player.get_pokemon(target_slot)
        if pokemon is None:
            return 0.0
        energy_card = player.hand[hand_idx]
        before = self._best_missing_energy(pokemon)
        after = min(
            [
                self._missing_energy_count_with_extra(pokemon, attack.cost, energy_card)
                for attack in pokemon.card.attacks
            ] or [before]
        )
        if after >= before:
            return 0.0
        damage_ceiling = self._best_pokemon_damage(state, player_idx, pokemon)
        value = (before - after) * 85.0
        value += min(120.0, damage_ceiling * 0.45)
        if after == 0:
            value += 145.0
        elif after == 1 and damage_ceiling >= 100:
            value += 80.0
        if getattr(pokemon.card, "api_id", "") in self.profile.core_cards:
            value += 45.0
        return value

    def _simulated_action_score(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> float | None:
        rng_state = self.random.getstate()
        try:
            sim = self._clone_state(state)
            result = self._apply_action_for_sim(sim, player_idx, action)
            if result is None or not result.success or sim.winner == 1 - player_idx:
                return None
            return self.evaluate_state(sim, player_idx)
        except Exception as exc:
            _logger.debug("search action scoring failed: %s %s -> %s", action.action, action.params, exc)
            return None
        finally:
            self.random.setstate(rng_state)

    def _attack_has_productive_effect(self, effects: list[Any]) -> bool:
        productive = {
            "draw",
            "shuffle_draw",
            "discard_draw",
            "discard_then_draw",
            "draw_until",
            "draw_until_more",
            "search",
            "energy_attach",
            "attach_from_discard",
            "draw_and_attach_energy",
            "energy_relocate",
            "look_top_deck",
        }
        return any(
            any(name in productive for name in effect_feature_names(effect))
            for effect in iter_effects_recursive(effects)
        )

    def _effects_include_draw(self, effects: list[Any]) -> bool:
        return any(
            any("draw" in name for name in effect_feature_names(effect))
            for effect in iter_effects_recursive(effects)
        )

    def _should_override_with_ko_attack(
        self, state: GameState, player_idx: int, preferred: AIAction, ko_attack: AIAction
    ) -> bool:
        if preferred.action == PlayerAction.END_TURN:
            return True
        if preferred.action != PlayerAction.DECLARE_ATTACK:
            return False
        preferred_idx = preferred.params.get("attack_idx")
        ko_idx = ko_attack.params.get("attack_idx")
        if preferred_idx == ko_idx:
            return False
        if not isinstance(preferred_idx, int):
            return True
        opponent = state.get_player(1 - player_idx)
        preferred_damage = self._estimated_attack_damage(state, player_idx, preferred_idx)
        return opponent.active is not None and preferred_damage < opponent.active.current_hp

    def _action_executes_successfully(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> bool:
        if action.action in ("NOOP", "SETUP_DONE"):
            return True
        rng_state = self.random.getstate()
        try:
            sim = self._clone_state(state)
            result = self._apply_action_for_sim(sim, player_idx, action)
            return result is not None and result.success
        except Exception as exc:
            _logger.debug("search action validation failed: %s %s -> %s", action.action, action.params, exc)
            return False
        finally:
            self.random.setstate(rng_state)

    def resolve_pending_action(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        return self.choice_policy.resolve_pending_action(state, action_request)

    def _resolve_pending_action_impl(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        req = action_request
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx

        if (
            req.request_type in ("search_deck", "select_hand_to_discard")
            and (getattr(req, "from_zone", "") or "").lower() in {"board", "bench"}
        ):
            from engine.actions import PokemonRef, resolve_pokemon_ref
            from engine.game_engine import DEFAULT_GAME_ENGINE

            structured = DEFAULT_GAME_ENGINE.choice_request(state, req)
            candidates = [
                option for option in structured.options
                if isinstance(option.ref, PokemonRef)
                and resolve_pokemon_ref(state, option.ref) is not None
            ]
            if candidates:
                prompt = (req.prompt or "").lower()

                def board_value(option):
                    pokemon = resolve_pokemon_ref(state, option.ref)
                    if pokemon is None:
                        return -10**9
                    if "回复" in req.prompt or "heal" in prompt:
                        return max(0, pokemon.card.hp - pokemon.current_hp)
                    if "附着能量" in req.prompt or "energy" in prompt:
                        return self._energy_target_value(
                            state,
                            option.ref.player,
                            option.ref.slot,
                        )
                    if option.ref.player != player_idx:
                        return self._target_priority(pokemon)
                    return self._promotion_value_for_state(
                        state,
                        option.ref.player,
                        pokemon,
                    )

                selected = max(candidates, key=board_value)
                return AIChoice(
                    selected_cards=[selected.ref],
                    option_ids=[selected.option_id],
                )

        if req.request_type in ("search_deck", "select_hand_to_discard"):
            cards = list(req.card_list)
            if req.request_type == "select_hand_to_discard" or self._is_hand_cost_selection(req):
                ranked = sorted(cards, key=lambda c: self._discard_priority(state, player_idx, c))
            else:
                ranked = sorted(
                    cards,
                    key=lambda c: self._search_card_value(state, player_idx, c, req),
                    reverse=True,
                )
            count = max(req.min_select, min(req.max_select, len(ranked)))
            return AIChoice(selected_cards=ranked[:count])

        if req.request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            slot = self._choose_bench_slot(state, req)
            return AIChoice(selected_bench_slot=slot)

        if req.request_type == "select_bench_targets":
            target_player = self._request_target_player(state, req)
            choices = [
                i for i in (req.bench_indices or range(5))
                if 0 <= i < len(target_player.bench) and target_player.bench[i] is not None
            ]
            ranked = sorted(
                choices,
                key=lambda i: self._target_priority(target_player.bench[i]),
                reverse=True,
            )
            selected: list[int] = []
            for idx in ranked:
                selected.append(idx)
                if len(selected) >= req.max_select:
                    break
            return AIChoice(selected_bench_targets=selected)

        if req.request_type == "confirm":
            return AIChoice(confirmed=self._confirm_pending(state, player_idx, req))

        if req.request_type == "coin_flip":
            if getattr(req, "until_tails", False):
                results = []
                max_flips = max(2, min(16, int(self.config.coin_sample_count) * 2))
                for _ in range(max_flips):
                    head = self.random.random() < 0.5
                    results.append(head)
                    if not head:
                        break
                if results and all(results):
                    results.append(False)
            else:
                results = [self.random.random() < 0.5 for _ in range(max(1, req.flip_count))]
            return AIChoice(coin_results=results)

        if req.request_type == "distribute_energy":
            return AIChoice(assignments=self._choose_energy_assignments(state, player_idx, req))

        if req.request_type == "evolve_skip_stage":
            candidate = self._choose_evolve_skip_stage_candidate(state, player_idx, req)
            if candidate is not None:
                return AIChoice(
                    selected_cards=[candidate],
                    option_ids=[self._evolve_skip_stage_option_id(candidate)],
                )
            return AIChoice(cancelled=True, confirmed=False)

        return AIChoice(cancelled=True, confirmed=False)

    def apply_choice(
        self,
        state: GameState,
        action_request: ActionRequest,
        choice: AIChoice | None = None,
    ) -> ActionRequest | ActionResult | None:
        return self.simulator.apply_choice(state, action_request, choice)

    def _apply_choice_impl(
        self,
        state: GameState,
        action_request: ActionRequest,
        choice: AIChoice | None = None,
    ) -> ActionRequest | ActionResult | None:
        """Apply an AIChoice to an ActionRequest callback, including UI-side switch logic."""
        req = action_request
        choice = choice or self.resolve_pending_action(state, req)
        result: ActionRequest | ActionResult | None = None

        if choice.cancelled:
            return None

        if req.request_type in ("search_deck", "select_hand_to_discard"):
            if req.callback:
                result = req.callback(choice.selected_cards)

        elif req.request_type == "select_own_bench_energy":
            if req.callback:
                result = req.callback(choice.selected_bench_slot)

        elif req.request_type in ("select_bench", "select_opponent_bench"):
            slot = choice.selected_bench_slot
            target_player = self._request_target_player(state, req)
            if slot is not None and 0 <= slot < len(target_player.bench) and target_player.bench[slot]:
                if req.callback:
                    # Callback does the switch in the engine layer (unified semantics)
                    result = req.callback(slot)
                else:
                    # Legacy fallback: switch directly
                    target_player.switch_active_to_bench(slot)

        elif req.request_type == "select_bench_targets":
            if req.callback:
                result = req.callback(choice.selected_bench_targets)

        elif req.request_type == "confirm":
            if req.callback:
                result = req.callback(choice.confirmed)

        elif req.request_type == "coin_flip":
            if req.callback:
                result = req.callback(choice.coin_results)

        elif req.request_type == "distribute_energy":
            if req.callback:
                result = req.callback(choice.assignments)

        elif req.request_type == "evolve_skip_stage":
            selected = (
                choice.selected_cards[0]
                if choice.selected_cards and isinstance(choice.selected_cards[0], dict)
                else self._choose_evolve_skip_stage_candidate(state, req.player, req)
            )
            if selected is not None and req.callback:
                result = req.callback(selected)

        self._consume_pending_card(state, req)
        return result

    # ------------------------------------------------------------------
    # Action generation and search
    # ------------------------------------------------------------------

    def legal_actions(self, state: GameState, player_idx: int) -> list[AIAction]:
        return self.enumerator.legal_actions(state, player_idx)

    def _legal_actions_impl(
        self,
        state: GameState,
        player_idx: int,
        actions: list[AIAction] | None = None,
    ) -> list[AIAction]:
        from engine.game_engine import DEFAULT_GAME_ENGINE

        actions = list(actions) if actions is not None else list(
            DEFAULT_GAME_ENGINE.legal_actions(state, player_idx)
        )
        trace: dict[str, Any] = {
            "player_idx": player_idx,
            "phase": getattr(state.phase, "name", str(state.phase)),
            "generated": [self._trace_action(action) for action in actions],
            "rejected": [],
            "accepted": [],
        }
        if state.phase == TurnPhase.SETUP:
            result = actions[: self.config.max_turn_actions]
            trace["accepted"] = [self._trace_action(action) for action in result]
            self._last_legal_action_trace = trace
            return result
        if state.phase != TurnPhase.MAIN:
            trace["accepted"] = [self._trace_action(action) for action in actions]
            self._last_legal_action_trace = trace
            return actions

        player = state.get_player(player_idx)
        actions = [
            action for action in actions
            if action.action != PlayerAction.USE_ABILITY
            or self._generated_ability_has_value(state, player_idx, action)
        ]
        actions = self._filter_strategically_relevant_actions(state, player_idx, actions, trace)
        if not self.config.skip_effect_dry_run:
            actions = self._filter_currently_executable_actions(state, player_idx, actions, trace)
        actions.sort(key=lambda a: self._quick_action_priority(state, player_idx, a), reverse=True)
        result = actions[: self.config.max_turn_actions]
        # END_TURN must always be available as a legal terminal action
        if not any(a.action == PlayerAction.END_TURN for a in result):
            end_turn = [a for a in actions if a.action == PlayerAction.END_TURN]
            if end_turn:
                result.append(end_turn[0])
        trace["accepted"] = [self._trace_action(action) for action in result]
        self._last_legal_action_trace = trace
        return result

    def _generated_ability_has_value(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
    ) -> bool:
        ability = self._ability_for_action(state, player_idx, action)
        slot = action.params.get("slot")
        return bool(
            ability is not None
            and isinstance(slot, str)
            and self._ability_has_available_value(state, player_idx, slot, ability)
        )

    def _filter_strategically_relevant_actions(
        self,
        state: GameState,
        player_idx: int,
        actions: list[AIAction],
        trace: dict[str, Any] | None = None,
    ) -> list[AIAction]:
        filtered: list[AIAction] = []
        player = state.get_player(player_idx)
        for action in actions:
            if action.action == PlayerAction.PLAY_TRAINER:
                hand_idx = action.params.get("hand_idx")
                if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                    effects = trainer_runtime_effects(player.hand[hand_idx])
                    if self._draw_pressure_is_unsafe(state, player_idx, effects):
                        self._trace_rejection(trace, action, "draw_or_search_deck_pressure")
                        continue
                    if effects and not self._effects_have_available_value(state, player_idx, effects):
                        self._trace_rejection(trace, action, "effect_has_no_available_value")
                        continue
                    if self._effects_include_type(effects, "switch_self") and not self._switch_self_has_good_target(
                        state, player_idx
                    ):
                        self._trace_rejection(trace, action, "switch_self_has_no_good_target")
                        continue
            elif action.action == PlayerAction.RETREAT:
                bench_idx = action.params.get("bench_idx")
                if isinstance(bench_idx, int) and not self._retreat_has_good_target(
                    state, player_idx, bench_idx
                ):
                    self._trace_rejection(trace, action, "retreat_has_no_good_target")
                    continue
            filtered.append(action)
        return filtered

    def _effects_include_type(self, effects: list[Any], effect_type: str) -> bool:
        return any(
            effect_type in effect_feature_names(effect)
            for effect in iter_effects_recursive(effects)
        )

    def _switch_self_has_good_target(self, state: GameState, player_idx: int) -> bool:
        player = state.get_player(player_idx)
        if not player.active or not player.bench_count():
            return False
        candidate_indices = [idx for idx, p in enumerate(player.bench) if p is not None]
        if not candidate_indices:
            return False
        good_indices = [idx for idx in candidate_indices if self._retreat_has_good_target(state, player_idx, idx)]
        if not good_indices:
            return False
        candidates = [player.bench[idx] for idx in good_indices if player.bench[idx] is not None]
        best_bench = max(
            candidates,
            key=lambda p: self._promotion_value_for_state(state, player_idx, p),
        )
        active_value = self._promotion_value_for_state(state, player_idx, player.active)
        if player.active.status_conditions:
            active_value -= 90
        best_missing = self._best_missing_energy(best_bench)
        active_safe = (
            not player.active.status_conditions
            and player.active.current_hp > max(40, player.active.card.hp * 0.35)
        )
        if best_missing > 0 and active_safe:
            return False
        return self._promotion_value_for_state(state, player_idx, best_bench) > active_value + 25

    def _retreat_has_good_target(
        self, state: GameState, player_idx: int, bench_idx: int
    ) -> bool:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not (0 <= bench_idx < len(player.bench)):
            return False
        target = player.bench[bench_idx]
        if target is None:
            return False

        target_ready_damage = 0
        for attack_idx, attack in enumerate(target.card.attacks):
            if target.has_enough_energy(attack.cost):
                original_active = player.active
                try:
                    player.active = target
                    target_ready_damage = max(
                        target_ready_damage,
                        self._estimated_attack_damage(state, player_idx, attack_idx),
                    )
                finally:
                    player.active = original_active
        if opponent.active and target_ready_damage >= opponent.active.current_hp:
            return True

        opponent_damage = self._best_available_damage(state, 1 - player_idx)
        active_survives = opponent_damage < player.active.current_hp
        target_falls = opponent_damage >= target.current_hp
        if active_survives and target_falls:
            return False

        target_cid = getattr(target.card, "api_id", "")
        target_is_core = target_cid in self.profile.core_cards
        target_is_engine = target_cid in self.profile.engine_cards or target_cid in self.profile.preferred_bench
        active_safe = (
            not player.active.status_conditions
            and player.active.current_hp > max(50, player.active.card.hp * 0.45)
        )
        if active_safe and not target_is_core and target_is_engine and target_ready_damage < 70:
            return False

        active_value = self._promotion_value_for_state(state, player_idx, player.active)
        target_value = self._promotion_value_for_state(state, player_idx, target)
        if player.active.status_conditions or player.active.current_hp <= max(40, player.active.card.hp * 0.35):
            return target_value > active_value - 20
        return target_value > active_value + 25

    def _filter_currently_executable_actions(
        self,
        state: GameState,
        player_idx: int,
        actions: list[AIAction],
        trace: dict[str, Any] | None = None,
    ) -> list[AIAction]:
        """Drop generated actions whose effect layer currently has no valid resolution.

        Rules-validator functions (can_play_*) already cover most legality checks.
        Only trainer cards with custom trainer_effects need a dry-run simulation
        because their resolution may carry additional constraints.
        """
        filtered: list[AIAction] = []
        opponent_idx = 1 - player_idx
        for action in actions:
            need_sim = False
            if action.action == PlayerAction.PLAY_TRAINER:
                hand_idx = action.params.get("hand_idx")
                player = state.get_player(player_idx)
                if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                    card = player.hand[hand_idx]
                    if trainer_runtime_effects(card):
                        need_sim = True
            elif action.action == PlayerAction.USE_ABILITY:
                pass  # can_use_ability already fully validates
            elif action.action == PlayerAction.USE_STADIUM:
                pass  # can_play_stadium already fully validates
            else:
                filtered.append(action)
                continue

            if not need_sim:
                filtered.append(action)
                continue

            if self._is_opponent_masked(state, opponent_idx):
                sim = self._clone_state(state)
            else:
                sim = self._masked_clone_for_eval(state, player_idx)
            result = self._apply_action_for_sim(sim, player_idx, action)
            if result is not None and result.success:
                filtered.append(action)
            else:
                reason = "dry_run_failed"
                if result is not None and getattr(result, "log_message", ""):
                    reason = f"{reason}: {result.log_message}"
                self._trace_rejection(trace, action, reason)
        return filtered

    def _ability_has_available_value(
        self, state: GameState, player_idx: int, slot: str, ability: Any
    ) -> bool:
        effects = ability_runtime_effects(ability)
        if self._draw_pressure_is_unsafe(state, player_idx, effects):
            return False
        return self._effects_have_available_value(
            state, player_idx, effects, source_slot=slot
        )

    def _draw_pressure_is_unsafe(self, state: GameState, player_idx: int, effects: list[Any]) -> bool:
        draw_count = self._estimated_draw_count(state, player_idx, effects)
        search_count = self._estimated_deck_search_count(effects)
        if draw_count <= 0 and search_count <= 0:
            return False
        deck_left = len(state.get_player(player_idx).deck)
        depletion = draw_count + search_count
        if depletion > 0 and deck_left <= depletion + 1:
            return True
        if deck_left <= draw_count:
            return True
        if deck_left <= 4:
            return True
        if deck_left <= 8 and draw_count >= 3:
            return True
        if deck_left <= 6 and search_count > 0:
            return True
        return False

    def _attack_draw_pressure_is_unsafe(self, state: GameState, player_idx: int, action: AIAction) -> bool:
        if action.action != PlayerAction.DECLARE_ATTACK:
            return False
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        attack_idx = action.params.get("attack_idx")
        if player.active is None or not isinstance(attack_idx, int):
            return False
        if not (0 <= attack_idx < len(player.active.card.attacks)):
            return False
        if opponent.active is not None and self._estimated_attack_damage(state, player_idx, attack_idx) >= opponent.active.current_hp:
            return False
        return self._draw_pressure_is_unsafe(
            state,
            player_idx,
            attack_runtime_effects(player.active.card.attacks[attack_idx]),
        )

    def _estimated_draw_count(self, state: GameState, player_idx: int, effects: list[Any]) -> int:
        effects = as_effect_list(effects)
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        total = 0
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype == "draw":
                total += int(params.get("amount", params.get("count", params.get("draw", 1))) or 1)
            elif etype == "shuffle_draw":
                total += int(params.get("amount", params.get("count", params.get("draw", 5))) or 5)
            elif etype == "discard_draw":
                total += int(params.get("amount", params.get("count", params.get("draw", 3))) or 3)
            elif etype == "discard_then_draw":
                total += int(params.get("draw_amount", params.get("draw", 1)) or 1)
            elif etype in ("draw_until", "draw_until_more"):
                target = int(params.get("target_hand_size", params.get("count", 5)) or 5)
                total += max(0, target - len(player.hand))
            elif etype == "houb":
                target = int(params.get("target_hand_size", 5) or 5)
                total += max(0, target - len(player.hand))
            elif etype == "zinnia_resolve":
                opp_count = (1 if opponent.active else 0) + opponent.bench_count()
                total += max(0, opp_count - 1)
            for branch in effect_branches(effect):
                total += self._estimated_draw_count(state, player_idx, branch)
        return total

    def _estimated_deck_search_count(self, effects: list[Any]) -> int:
        effects = as_effect_list(effects)
        total = 0
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            from_zone = str(params.get("from_zone", "deck") or "deck")
            if etype in ("search", "conditional_search_extra", "search_any_and_switch") and from_zone == "deck":
                total += int(params.get("take", params.get("count", 1)) or 1)
            elif etype == "look_top_deck" and str(params.get("destination", "") or "") in {"hand", "bench_energy"}:
                total += int(params.get("take", 1) or 1)
            elif etype == "arven":
                total += 2
            for branch in effect_branches(effect):
                total += self._estimated_deck_search_count(branch)
        return total

    def _effects_have_available_value(
        self,
        state: GameState,
        player_idx: int,
        effects: list[Any],
        source_slot: str | None = None,
        _depth: int = 0,
    ) -> bool:
        if _depth > 8:
            return False
        effects = as_effect_list(effects)
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        saw_known_resource_effect = False
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype in ("draw", "shuffle_draw", "discard_draw", "discard_then_draw", "draw_until", "draw_until_more"):
                saw_known_resource_effect = True
                if player.deck:
                    return True
            elif etype in ("hand_to_bottom_draw", "judge", "trekking_shoes", "houb"):
                saw_known_resource_effect = True
                if player.deck:
                    return True
            elif etype == "zinnia_resolve":
                saw_known_resource_effect = True
                if player.deck and ((1 if opponent.active else 0) + opponent.bench_count()) > 1:
                    return True
            elif etype in ("energy_attach", "attach_from_discard", "draw_and_attach_energy"):
                saw_known_resource_effect = True
                accel_params = dict(params)
                if etype == "attach_from_discard":
                    accel_params.setdefault("from_zone", "discard")
                elif etype == "energy_attach":
                    accel_params.setdefault("from_zone", "hand")
                if self._energy_acceleration_value(state, player_idx, accel_params, source_slot) > 0:
                    return True
            elif etype == "energy_relocate":
                saw_known_resource_effect = True
                if self._best_energy_relocation_gain(state, player_idx, source_slot, params) > 0:
                    return True
            elif etype in ("heal", "heal_all", "potion_heal"):
                saw_known_resource_effect = True
                if any(p and p.current_hp < p.card.hp for _, p in player.get_all_pokemon()):
                    return True
            elif etype in ("damage_and_self_heal", "conditional_damage_heal"):
                saw_known_resource_effect = True
                if opponent.active is not None or any(p and p.current_hp < p.card.hp for _, p in player.get_all_pokemon()):
                    return True
            elif etype in ("search", "look_top_deck", "conditional_search_extra", "search_any_and_switch"):
                saw_known_resource_effect = True
                if self._search_effect_has_available_value(state, player_idx, params):
                    return True
            elif etype == "arven":
                saw_known_resource_effect = True
                if self._arven_has_available_value(state, player_idx):
                    return True
            elif etype == "shuffle_from_discard":
                saw_known_resource_effect = True
                if self._discard_search_has_available_value(state, player_idx, params):
                    return True
            elif etype == "switch_self":
                saw_known_resource_effect = True
                if player.active is not None and player.bench_count() > 0:
                    return True
            elif etype == "switch_opponent":
                saw_known_resource_effect = True
                if (
                    opponent.active is not None
                    and opponent.bench_count() > 0
                    and not getattr(opponent.active, "all_prevented_next_turn", False)
                ):
                    return True
            elif etype in ("energy_discard", "coin_flip_energy_discard"):
                saw_known_resource_effect = True
                if (
                    opponent.active is not None
                    and bool(getattr(opponent.active, "energy_cards", []) or [])
                    and not getattr(opponent.active, "all_prevented_next_turn", False)
                ):
                    return True
            elif etype in ("any_pokemon_damage", "place_counters_and_self_ko"):
                saw_known_resource_effect = True
                if any(
                    p is not None and not getattr(p, "all_prevented_next_turn", False)
                    for p in [opponent.active, *opponent.bench]
                ):
                    return True
            elif etype in ("prevent_all", "attack_lock_basic"):
                saw_known_resource_effect = True
                if opponent.active is not None and not getattr(opponent.active, "all_prevented_next_turn", False):
                    return True
            elif etype == "damage_counter_self":
                saw_known_resource_effect = True
                source = player.get_pokemon(source_slot) if source_slot else player.active
                amount = int(params.get("amount", 0) or 0)
                if source is not None and source.current_hp > amount:
                    return True
            elif etype == "conditional":
                saw_known_resource_effect = True
                if self._conditional_effect_has_available_value(
                    state, player_idx, params, source_slot, _depth=_depth + 1
                ):
                    return True
            elif etype in ("coin_flip",):
                saw_known_resource_effect = True
                if self._coin_branch_has_available_value(
                    state, player_idx, params, source_slot, _depth=_depth + 1
                ):
                    return True
            elif etype:
                return True
        return not saw_known_resource_effect

    def _conditional_effect_has_available_value(
        self,
        state: GameState,
        player_idx: int,
        params: dict[str, Any],
        source_slot: str | None,
        *,
        _depth: int,
    ) -> bool:
        player = state.get_player(player_idx)
        condition = str(params.get("condition", "") or "")
        if condition == "ko_by_attack_last_turn" and not player.was_ko_by_attack:
            return False

        cost = params.get("cost")
        if cost and not bool(params.get("optional", False)):
            if not self._effect_cost_is_payable(state, player_idx, cost):
                return False

        on_pay = list(effect_branches({"params": {"on_pay": params.get("on_pay") or []}}))
        if not on_pay:
            return True
        return self._effects_have_available_value(
            state, player_idx, on_pay, source_slot=source_slot, _depth=_depth
        )

    def _coin_branch_has_available_value(
        self,
        state: GameState,
        player_idx: int,
        params: dict[str, Any],
        source_slot: str | None,
        *,
        _depth: int,
    ) -> bool:
        for key in ("on_heads", "on_tails", "on_success", "on_fail"):
            branch = list(effect_branches({"params": {key: params.get(key) or []}}))
            if branch and self._effects_have_available_value(
                state, player_idx, branch, source_slot=source_slot, _depth=_depth
            ):
                return True
        return False

    def _effect_cost_is_payable(self, state: GameState, player_idx: int, cost: Any) -> bool:
        if not cost:
            return True
        costs = cost if isinstance(cost, list) else [cost]
        player = state.get_player(player_idx)
        for item in costs:
            etype = self._effect_type(item)
            params = self._effect_params(item)
            if etype == "discard":
                from_zone = str(params.get("from", params.get("from_zone", "hand")) or "hand")
                amount = int(params.get("amount", 1) or 1)
                if from_zone == "hand":
                    # Trainer cards are popped before resolving their costs.
                    if max(0, len(player.hand) - 1) < amount:
                        return False
                elif from_zone == "discard" and len(player.discard) < amount:
                    return False
        return True

    def _arven_has_available_value(self, state: GameState, player_idx: int) -> bool:
        player = state.get_player(player_idx)
        return any(
            getattr(card, "is_trainer_item", False) or getattr(card, "is_trainer_tool", False)
            for card in player.deck
        )

    def _search_effect_has_available_value(
        self, state: GameState, player_idx: int, params: dict[str, Any]
    ) -> bool:
        player = state.get_player(player_idx)
        destination = str(params.get("destination", "hand") or "hand")
        if destination == "bench" and not player.bench_has_space():
            return False
        from_zone = str(params.get("from_zone", "deck") or "deck")
        count = int(params.get("count", params.get("take", 1)) or 1)
        if from_zone == "discard":
            pool = player.discard
        elif from_zone == "hand":
            pool = player.hand
        else:
            look_count = int(params.get("count", 0) or 0)
            pool = player.deck[-look_count:] if params.get("count") and from_zone == "deck" else player.deck
        if not pool or count <= 0:
            return False
        filter_type = str(params.get("filter", "pokemon") or "pokemon")
        filter_name = str(params.get("filter_name", "") or "")
        return any(self._search_filter_matches(card, filter_type, filter_name) for card in pool)

    def _discard_search_has_available_value(
        self, state: GameState, player_idx: int, params: dict[str, Any]
    ) -> bool:
        player = state.get_player(player_idx)
        if not player.discard:
            return False
        filter_type = str(params.get("filter", "any") or "any")
        return any(self._search_filter_matches(card, filter_type, "") for card in player.discard)

    def _search_filter_matches(self, card: Any, filter_type: str, filter_name: str = "") -> bool:
        if filter_name:
            return getattr(card, "name", "") == filter_name
        normalized = filter_type.lower()
        if normalized in ("", "any"):
            return True
        if normalized == "basic_pokemon":
            return bool(getattr(card, "is_basic_pokemon", False))
        if normalized == "pokemon":
            return bool(getattr(card, "is_pokemon", False))
        if normalized in ("basic_energy", "basic_energy_card"):
            return bool(getattr(card, "is_basic_energy", False))
        if normalized in ("energy", "energy_card"):
            return bool(getattr(card, "is_energy", False))
        if normalized == "supporter":
            return bool(getattr(card, "is_trainer_supporter", False))
        if normalized == "item":
            return bool(getattr(card, "is_trainer_item", False))
        if normalized == "item_or_tool":
            return bool(getattr(card, "is_trainer_item", False) or getattr(card, "is_trainer_tool", False))
        if normalized == "pokemon_and_energy":
            return bool(getattr(card, "is_pokemon", False) or getattr(card, "is_basic_energy", False))
        if normalized == "grass_pokemon":
            return bool(getattr(card, "is_pokemon", False) and "Grass" in getattr(card, "energy_types", []))
        if normalized == "water_pokemon_and_energy":
            return bool(
                (getattr(card, "is_pokemon", False) and "Water" in getattr(card, "energy_types", []))
                or (getattr(card, "is_energy", False) and self._energy_filter_matches(card, "water"))
            )
        if normalized.endswith("_energy"):
            return bool(getattr(card, "is_energy", False) and self._energy_filter_matches(card, normalized))
        return True

    def _apply_action_for_sim(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> ActionResult | None:
        return self.simulator.apply_action(state, player_idx, action)

    def _apply_action_for_sim_impl(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> ActionResult | None:
        from engine.ai.planner import _map_legacy_choice
        from engine.game_engine import DEFAULT_GAME_ENGINE
        from engine.random_source import SamplingRandomSource

        def choose(sim_state, structured_request):
            legacy_choice = self._resolve_pending_for_sim(
                sim_state,
                structured_request.legacy_request,
            )
            mapped = _map_legacy_choice(structured_request, legacy_choice)
            if mapped is not None:
                return mapped
            return DEFAULT_GAME_ENGINE._default_choice_response(
                structured_request,
                rng,
            )

        rng = SamplingRandomSource(self.random.randrange(0, 2**31))
        step = DEFAULT_GAME_ENGINE.apply_action(
            state,
            action.with_actor(player_idx) if action.actor is None else action,
            rng,
            auto_resolve=True,
            choice_policy=choose,
            auto_finish_attack=True,
        )
        if step.action_result is not None:
            return step.action_result
        return ActionResult(step.success, step.message)

    def _auto_promote_for_sim(self, state: GameState) -> None:
        guard = 0
        while state.pending_promotions and guard < 4 and state.winner is None:
            guard += 1
            player_idx = state.pop_pending_promotion()
            player = state.get_player(player_idx)
            if player.active is not None:
                continue
            candidates = [(i, p) for i, p in enumerate(player.bench) if p is not None]
            if not candidates:
                if not player.has_any_pokemon_in_play():
                    state.winner = 1 - player_idx
                    state.phase = TurnPhase.GAME_OVER
                continue
            bench_idx, _ = max(
                candidates,
                key=lambda row: self._forced_promotion_value(state, player_idx, row[1]),
            )
            player.promote_from_bench(bench_idx)
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).continue_after_promotion()
            # continue loop if more promotions queued
        if state.winner is not None:
            return
        for player_idx in (0, 1):
            player = state.get_player(player_idx)
            if player.active is not None:
                continue
            if not player.has_any_pokemon_in_play():
                state.winner = 1 - player_idx
                state.phase = TurnPhase.GAME_OVER
                return
            state.pending_promotion_player = player_idx
            if guard < 4:
                self._auto_promote_for_sim(state)
            return

    # ------------------------------------------------------------------
    # Setup
    # ------------------------------------------------------------------

    def _choose_setup_action(self, state: GameState, player_idx: int) -> AIAction:
        actions = self._setup_actions(state, player_idx)
        if not actions:
            return AIAction("SETUP_DONE", {}, terminal=True)
        actions.sort(key=lambda a: self._setup_action_value(state, player_idx, a), reverse=True)
        return actions[0]

    def _setup_actions(self, state: GameState, player_idx: int) -> list[AIAction]:
        player = state.get_player(player_idx)
        actions: list[AIAction] = []
        seen: set[str] = set()
        for hand_idx, card in enumerate(player.hand):
            if not card.is_basic_pokemon or card.api_id in seen:
                continue
            seen.add(card.api_id)
            if player.active is None:
                actions.append(AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": hand_idx, "target": "active"}))
            elif player.bench_has_space():
                empty = player.find_empty_bench_slot()
                if empty is not None:
                    actions.append(AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": hand_idx, "target": f"bench_{empty}"}))
        if player.active is not None:
            actions.append(AIAction("SETUP_DONE", {}, terminal=True))
        return actions

    # ------------------------------------------------------------------
    # Pending choices
    # ------------------------------------------------------------------

    def _resolve_pending_for_sim(self, state: GameState, req: ActionRequest) -> AIChoice:
        if req.request_type == "coin_flip":
            if getattr(req, "until_tails", False):
                results = []
                max_flips = max(2, min(16, int(self.config.coin_sample_count) * 2))
                for _ in range(max_flips):
                    head = self.random.random() < 0.5
                    results.append(head)
                    if not head:
                        break
                if results and all(results):
                    results.append(False)
                return AIChoice(coin_results=results)
            flips = max(1, req.flip_count)
            return AIChoice(coin_results=[self.random.random() < 0.5 for _ in range(flips)])
        return self.resolve_pending_action(state, req)

    def _choose_evolve_skip_stage_candidate(
        self,
        state: GameState,
        player_idx: int,
        req: ActionRequest,
    ) -> dict[str, Any] | None:
        candidates = [
            candidate for candidate in (getattr(req, "target_info", None) or [])
            if isinstance(candidate, dict)
        ]
        if not candidates:
            return None
        owner_idx = player_idx if player_idx in (0, 1) else state.active_player_idx
        player = state.get_player(owner_idx)

        def candidate_value(candidate: dict[str, Any]) -> float:
            slot = str(candidate.get("slot", "") or "")
            card_id = str(candidate.get("card_id", "") or "")
            value = 0.0
            try:
                from data.card_registry import CardRegistry

                stage2 = CardRegistry.get(card_id) if card_id else None
            except Exception:
                stage2 = None
            if stage2 is not None:
                value += self._search_card_value(state, owner_idx, stage2, req)
                value += max(0, int(getattr(stage2, "hp", 0))) * 0.2
                if getattr(stage2, "api_id", "") in self.profile.evolution_cards:
                    value += 50
            target = player.get_pokemon(slot)
            if target is not None:
                value += self._promotion_value_for_state(state, owner_idx, target) * 0.1
            if slot == "active":
                value += 12
            return value

        return max(candidates, key=candidate_value)

    @staticmethod
    def _evolve_skip_stage_option_id(candidate: dict[str, Any]) -> str:
        return "rare_candy:%s:%d:%s" % (
            str(candidate.get("slot", "") or ""),
            int(candidate.get("hand_index", -1)),
            str(candidate.get("card_id", "") or ""),
        )

    def _choose_bench_slot(self, state: GameState, req: ActionRequest) -> int | None:
        player = self._request_target_player(state, req)
        candidates = [
            i for i in (req.bench_indices or range(len(player.bench)))
            if 0 <= i < len(player.bench) and player.bench[i] is not None
        ]
        if not candidates:
            return None

        if req.request_type == "select_opponent_bench" or req.target_player == "opponent":
            return max(candidates, key=lambda i: self._target_priority(player.bench[i]))
        if req.request_type == "select_own_bench_energy":
            owner_idx = self._request_target_player_idx(state, req)
            return max(candidates, key=lambda i: self._energy_target_value(state, owner_idx, f"bench_{i}"))
        owner_idx = self._request_target_player_idx(state, req)
        if self._is_self_switch_request(req):
            good = [i for i in candidates if self._retreat_has_good_target(state, owner_idx, i)]
            if good:
                candidates = good
        return max(candidates, key=lambda i: self._promotion_value_for_state(state, owner_idx, player.bench[i]))

    def _is_self_switch_request(self, req: ActionRequest) -> bool:
        if req.target_player == "opponent" or req.request_type == "select_opponent_bench":
            return False
        if req.request_type != "select_bench":
            return False
        prompt = (req.prompt or "").lower()
        source_name = (getattr(req, "source_name", "") or "").lower()
        text = f"{prompt} {source_name}"
        return any(marker in text for marker in ("switch", "retreat", "替换", "交换", "撤退"))

    def _request_target_player(self, state: GameState, req: ActionRequest):
        if req.target_player == "opponent" or req.request_type == "select_opponent_bench":
            owner_idx = req.player if req.player in (0, 1) else state.active_player_idx
            return state.get_player(1 - owner_idx)
        if req.target_player == "self" or req.request_type == "select_own_bench_energy":
            owner_idx = req.player if req.player in (0, 1) else state.active_player_idx
            return state.get_player(owner_idx)
        if req.player in (0, 1):
            return state.get_player(req.player)
        return state.get_active_player()

    def _request_target_player_idx(self, state: GameState, req: ActionRequest) -> int:
        if req.target_player == "opponent" or req.request_type == "select_opponent_bench":
            owner_idx = req.player if req.player in (0, 1) else state.active_player_idx
            return 1 - owner_idx
        if req.target_player == "self" or req.request_type == "select_own_bench_energy":
            return req.player if req.player in (0, 1) else state.active_player_idx
        if req.player in (0, 1):
            return req.player
        return state.active_player_idx

    def _confirm_pending(self, state: GameState, player_idx: int, req: ActionRequest) -> bool:
        prompt = req.prompt or ""
        prompt_l = prompt.lower()
        player = state.get_player(player_idx)
        if "牌库顶" in prompt or ("top" in prompt_l and "hand" in prompt_l):
            return self._should_keep_top_deck_card(state, player_idx)
        if "switch" in prompt_l or "替换" in prompt or "交换" in prompt:
            if not player.active or not player.bench_count():
                return False
            good_indices = [
                idx for idx, p in enumerate(player.bench)
                if p is not None and self._retreat_has_good_target(state, player_idx, idx)
            ]
            if not good_indices:
                return False
            best_bench = max(
                (player.bench[idx] for idx in good_indices if player.bench[idx] is not None),
                key=lambda p: self._promotion_value_for_state(state, player_idx, p),
            )
            active_value = self._promotion_value_for_state(state, player_idx, player.active)
            if player.active.status_conditions:
                active_value -= 90
            best_missing = self._best_missing_energy(best_bench)
            active_safe = (
                not player.active.status_conditions
                and player.active.current_hp > max(40, player.active.card.hp * 0.35)
            )
            if best_missing > 0 and active_safe:
                return False
            return self._promotion_value_for_state(state, player_idx, best_bench) > active_value + 25
        if "discard" in prompt_l or "draw" in prompt_l:
            return True
        if player.active and player.active.current_hp <= max(40, player.active.card.hp * 0.35):
            return True
        if "heal" in prompt_l:
            return any(p and p.current_hp < p.card.hp for _, p in player.get_all_pokemon())
        return True

    def _is_hand_cost_selection(self, req: ActionRequest) -> bool:
        if (getattr(req, "from_zone", "") or "").lower() != "hand":
            return False
        prompt = req.prompt or ""
        prompt_l = prompt.lower()
        cost_markers = (
            "discard",
            "bottom",
            "put",
            "丢",
            "弃",
            "放回",
            "牌库底",
            "牌库下方",
            "洗回",
        )
        return any(marker in prompt_l or marker in prompt for marker in cost_markers)

    def _should_keep_top_deck_card(self, state: GameState, player_idx: int) -> bool:
        player = state.get_player(player_idx)
        if not player.deck:
            return False
        card = player.deck[-1]
        value = self._card_value(state, player_idx, card)
        if getattr(card, "api_id", "") in self.profile.core_cards:
            return True
        if getattr(card, "is_energy", False):
            targets = [p for _, p in player.get_all_pokemon() if p is not None]
            if any(self._best_missing_energy(p) > 0 for p in targets):
                return True
        duplicates = sum(1 for c in player.hand if getattr(c, "api_id", None) == getattr(card, "api_id", None))
        if duplicates >= 2 and value < 90:
            return False
        return value >= 55

    def _choose_energy_assignments(
        self, state: GameState, player_idx: int, req: ActionRequest
    ) -> list[tuple[int, str]]:
        targets = list(getattr(req, "target_info", []) or [])
        cards = list(req.card_list)
        mode = getattr(req, "distribute_mode", "") or ""
        if not targets:
            return []
        if mode == "source_select":
            return self._choose_energy_source_assignment(state, player_idx, targets)
        if not cards:
            return []
        assignments: list[tuple[int, str]] = []
        per_target: dict[str, int] = {}
        for energy_idx, energy_card in enumerate(cards):
            available_targets = [
                t for t in targets
                if per_target.get(t["slot"], 0) < getattr(req, "max_per_target", 99)
            ]
            if not available_targets:
                break
            best_target = max(
                available_targets,
                key=lambda t: self._energy_assignment_target_value(state, player_idx, t["slot"], energy_card) -
                per_target.get(t["slot"], 0) * 12,
            )
            slot = best_target["slot"]
            assignments.append((energy_idx, slot))
            per_target[slot] = per_target.get(slot, 0) + 1
        return assignments

    def _choose_energy_source_assignment(
        self, state: GameState, player_idx: int, targets: list[dict[str, Any]]
    ) -> list[tuple[int, str]]:
        scored: list[tuple[float, str]] = []
        for info in targets:
            slot = str(info.get("slot", ""))
            pokemon = state.get_player(player_idx).get_pokemon(slot)
            if pokemon is None or not pokemon.energy_cards:
                continue
            scored.append((self._best_energy_relocation_gain(state, player_idx, slot), slot))
        if not scored:
            return []
        scored.sort(key=lambda row: row[0], reverse=True)
        return [(0, scored[0][1])]

    def _consume_pending_card(self, state: GameState, req: ActionRequest):
        card = getattr(req, "pending_card", None)
        if not card:
            return
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)
        # Use identity (is) rather than equality (==) for the discard guard:
        # Card.__eq__ matches by api_id, and CardRegistry returns singleton
        # objects, so multiple deck copies are the same object.  Without an
        # identity check the second copy would be skipped because its __eq__
        # already matches the first one sitting in the discard pile.
        if all(c is not card for c in player.discard) and card not in player.hand:
            if getattr(card, "is_trainer_supporter", False) or getattr(card, "is_trainer_item", False):
                player.discard.append(card)
        req.pending_card = None

    # ------------------------------------------------------------------
    # Evaluation
    # ------------------------------------------------------------------

    def evaluate_state(self, state: GameState, player_idx: int) -> float:
        return self.evaluator.evaluate_state(state, player_idx)

    def _evaluate_state_impl(self, state: GameState, player_idx: int) -> float:
        opponent_idx = 1 - player_idx
        if state.winner == player_idx:
            return 1_000_000
        if state.winner == opponent_idx:
            return -1_000_000

        player = state.get_player(player_idx)
        opponent = state.get_player(opponent_idx)
        score = 0.0
        score += (6 - len(player.prizes)) * 1150
        score -= (6 - len(opponent.prizes)) * 1220
        score += len(player.hand) * 12
        score -= opponent.hand_count * 4
        score += min(len(player.deck), 12) * 2
        if len(player.deck) <= 2:
            score -= (3 - len(player.deck)) * 80

        score += self._board_value(state, player_idx)
        score -= self._board_value(state, opponent_idx) * 0.95
        score += self._attack_pressure(state, player_idx)
        score -= self._attack_pressure(state, opponent_idx) * 0.85
        score += self._attack_plan_score(state, player_idx)
        score -= self._attack_plan_score(state, opponent_idx) * 0.72
        score += self._tempo_score(state, player_idx)
        score += self._initiative_score(state, player_idx)
        score -= self._initiative_score(state, opponent_idx) * 0.80
        score += sum(self._card_value(state, player_idx, c) * 0.12 for c in player.hand)
        score += self._policy_state_score(state, player_idx)
        score += self._expert_state_value_bonus(state, player_idx)
        score -= self._expert_state_value_bonus(state, opponent_idx) * 0.55
        return score

    def _tempo_score(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        score = 0.0
        if player.active and opponent.active:
            own_best = self._best_available_damage(state, player_idx)
            opp_best = self._best_available_damage(state, 1 - player_idx)
            if own_best >= opponent.active.current_hp:
                score += 190 + opponent.active.card.prize_value * 130
            if opp_best >= player.active.current_hp:
                score -= 210 + player.active.card.prize_value * 145

            own_missing = self._best_missing_energy(player.active)
            opp_missing = self._best_missing_energy(opponent.active)
            score += max(0, 3 - own_missing) * 34
            score -= max(0, 3 - opp_missing) * 26
            if player.active.current_hp <= max(40, player.active.card.hp * 0.3):
                score -= 90
            if opponent.active.current_hp <= max(40, opponent.active.card.hp * 0.3):
                score += 90

        score += self._bench_snipe_pressure(state, player_idx)
        score -= self._bench_snipe_pressure(state, 1 - player_idx) * 0.75
        score += self._resource_shape_score(state, player_idx)
        score -= self._resource_shape_score(state, 1 - player_idx) * 0.75
        return score

    def _initiative_score(self, state: GameState, player_idx: int) -> float:
        """Score whether resources are on Pokemon that can become real attacks."""
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        active = player.active
        if active is None:
            return -400.0

        active_missing = self._best_missing_energy(active)
        active_damage = self._best_ready_pokemon_damage(state, player_idx, active)
        score = 0.0
        if active_missing == 0:
            score += 170 + active_damage * 0.70
            if opponent.active and active_damage >= opponent.active.current_hp:
                score += 260 + opponent.active.card.prize_value * 120
        elif active_missing == 1:
            score += 80
        elif active_missing == 2:
            score -= 55
        else:
            score -= 130

        if active_missing > 0 and state.turn_number >= 3:
            if len(active.energy_cards) == 0:
                score -= 90
            if opponent.active and self._best_available_damage(state, 1 - player_idx) >= active.current_hp:
                score -= 120

        ready_bench = []
        nearly_ready_bench = []
        for bench_idx, pokemon in enumerate(player.bench):
            if pokemon is None:
                continue
            missing = self._best_missing_energy(pokemon)
            if missing == 0:
                damage = self._best_ready_pokemon_damage(state, player_idx, pokemon)
                ready_bench.append((bench_idx, pokemon, damage))
                score += 65 + damage * 0.30
            elif missing == 1:
                damage = self._best_pokemon_damage_with_max_missing(state, player_idx, pokemon, 1)
                nearly_ready_bench.append((bench_idx, pokemon, damage))
                score += 28 + damage * 0.12

        if active_missing > 0 and ready_bench:
            can_move_ready = any(can_retreat(state, player_idx, idx)[0] for idx, _pokemon, _damage in ready_bench)
            score += 115 if can_move_ready else -85
        if active_missing >= 2 and not ready_bench and not nearly_ready_bench:
            score -= 70
        return score

    def _best_pokemon_damage(self, state: GameState, player_idx: int, pokemon) -> int:
        return self._best_pokemon_damage_with_max_missing(state, player_idx, pokemon, None)

    def _best_ready_pokemon_damage(self, state: GameState, player_idx: int, pokemon) -> int:
        return self._best_pokemon_damage_with_max_missing(state, player_idx, pokemon, 0)

    def _best_pokemon_damage_with_max_missing(
        self,
        state: GameState,
        player_idx: int,
        pokemon,
        max_missing: int | None,
    ) -> int:
        if not pokemon or not pokemon.card.attacks:
            return 0
        player = state.get_player(player_idx)
        original_active = player.active
        try:
            player.active = pokemon
            return max(
                [
                    self._estimated_attack_damage(state, player_idx, attack_idx)
                    for attack_idx, attack in enumerate(pokemon.card.attacks)
                    if max_missing is None or self._missing_energy_count(pokemon, attack.cost) <= max_missing
                ] or [0]
            )
        finally:
            player.active = original_active

    def _best_ready_attack_effect_value(self, state: GameState, player_idx: int, pokemon) -> float:
        if not pokemon or not pokemon.card.attacks:
            return 0.0
        player = state.get_player(player_idx)
        original_active = player.active
        try:
            player.active = pokemon
            return max(
                [
                    self._effect_tactical_value(
                        state, player_idx, attack_runtime_effects(attack)
                    )
                    for attack in pokemon.card.attacks
                    if self._missing_energy_count(pokemon, attack.cost) == 0
                ] or [0.0]
            )
        finally:
            player.active = original_active

    def _field_energy_count(self, player: Any) -> int:
        return sum(
            len(getattr(pokemon, "energy_cards", []) or [])
            for _, pokemon in player.get_all_pokemon()
            if pokemon is not None
        )

    def _board_value(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        total = 0.0
        for slot, pokemon in player.get_all_pokemon():
            if pokemon is None:
                continue
            slot_bonus = 55 if slot == "active" else 25
            hp_ratio = pokemon.current_hp / max(1, pokemon.card.hp)
            total += slot_bonus + pokemon.current_hp * 0.55 + hp_ratio * 45
            total += len(pokemon.energy_cards) * 22
            total += len(pokemon.evolution_stack) * 42
            if "ex" in pokemon.card.subtypes:
                total += 45
            total += self._ready_attack_value(pokemon)
            total += self._profile_pokemon_bonus(pokemon, slot)
            total -= len(pokemon.status_conditions) * 22
            if StatusType.ASLEEP in pokemon.status_conditions or StatusType.PARALYZED in pokemon.status_conditions:
                total -= 50
        return total

    def _attack_pressure(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not opponent.active:
            return 0.0
        pressure = 0.0
        for attack_idx, attack in enumerate(player.active.card.attacks):
            if can_declare_attack(state, player_idx, attack_idx)[0]:
                damage = self._estimated_attack_damage(state, player_idx, attack_idx)
                pressure = max(pressure, damage * 1.2)
                if damage >= opponent.active.current_hp:
                    pressure += 260 + opponent.active.card.prize_value * 110
                pressure += self._effect_tactical_value(
                    state, player_idx, attack_runtime_effects(attack)
                )
        pressure += self._target_immunity_penalty(opponent.active) * 0.5
        return pressure

    def _best_available_damage(self, state: GameState, player_idx: int) -> int:
        player = state.get_player(player_idx)
        if not player.active:
            return 0
        return max(
            [
                self._estimated_attack_damage(state, player_idx, attack_idx)
                for attack_idx, _ in enumerate(player.active.card.attacks)
                if can_declare_attack(state, player_idx, attack_idx)[0]
            ] or [0]
        )

    def _best_missing_energy(self, pokemon) -> int:
        if not pokemon.card.attacks:
            return 99
        return min(self._missing_energy_count(pokemon, atk.cost) for atk in pokemon.card.attacks)

    def _bench_snipe_pressure(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active:
            return 0.0
        pressure = 0.0
        low_bench = [p for p in opponent.bench if p is not None and p.current_hp <= 90]
        if not low_bench:
            return 0.0
        for attack_idx, attack in enumerate(player.active.card.attacks):
            if not can_declare_attack(state, player_idx, attack_idx)[0]:
                continue
            for effect in attack_runtime_effects(attack):
                etype = self._effect_type(effect)
                params = self._effect_params(effect)
                if etype in ("any_pokemon_damage", "place_counters_and_self_ko"):
                    amount = int(params.get("amount", params.get("counters", 0) * 10) or 0)
                    best = max(low_bench, key=lambda p: self._target_priority(p))
                    pressure += amount * 0.9
                    if amount >= best.current_hp:
                        pressure += 170 + best.card.prize_value * 90
        return pressure

    def _resource_shape_score(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        pokemon = [p for _, p in player.get_all_pokemon() if p is not None]
        energy_in_play = sum(len(p.energy_cards) for p in pokemon)
        evolved = sum(1 for p in pokemon if p.evolution_stack or p.card.api_id in self.profile.evolution_cards)
        damaged = sum(max(0, p.card.hp - p.current_hp) for p in pokemon)
        ready_attackers = sum(1 for p in pokemon if self._best_missing_energy(p) == 0 and p.card.attacks)
        score = energy_in_play * 18 + evolved * 42 + ready_attackers * 55
        score -= damaged * 0.12
        if player.bench_count() == 0:
            score -= 75
        elif player.bench_count() >= 3:
            score += 45
        return score

    def _ready_attack_value(self, pokemon) -> float:
        if not pokemon.card.attacks:
            return 0.0
        best = 0.0
        for attack in pokemon.card.attacks:
            missing = self._missing_energy_count(pokemon, attack.cost)
            impact = attack.damage + self._static_effect_value(
                attack_runtime_effects(attack)
            )
            if missing == 0:
                readiness_bonus = 80
            elif missing == 1:
                readiness_bonus = 36
            elif missing == 2 and impact >= 110:
                readiness_bonus = 18
            else:
                readiness_bonus = 0
            best = max(
                best,
                impact - missing * 72 + readiness_bonus,
            )
        return best * 0.45

    def _attack_plan_score(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        total = 0.0
        for slot, pokemon in player.get_all_pokemon():
            if pokemon is None:
                continue
            slot_weight = 1.18 if slot == "active" else 0.78
            total += self._pokemon_attack_plan_value(state, player_idx, pokemon) * slot_weight
        return total

    def _pokemon_attack_plan_value(self, state: GameState, player_idx: int, pokemon) -> float:
        if pokemon is None or not pokemon.card.attacks:
            return 0.0
        player = state.get_player(player_idx)
        original_active = player.active
        best = 0.0
        try:
            player.active = pokemon
            for attack_idx, attack in enumerate(pokemon.card.attacks):
                missing = self._missing_energy_count(pokemon, attack.cost)
                damage = self._estimated_attack_damage(state, player_idx, attack_idx)
                impact = damage + self._static_effect_value(
                    attack_runtime_effects(attack)
                ) * 0.75
                if missing == 0:
                    value = 78 + impact * 0.82
                elif missing == 1:
                    value = 38 + impact * 0.50
                elif missing == 2:
                    value = impact * 0.26
                elif missing == 3:
                    value = impact * 0.10
                else:
                    value = 0.0
                if impact >= 110 and missing <= 2:
                    value += (3 - missing) * 38
                if getattr(pokemon.card, "api_id", "") in self.profile.core_cards:
                    value *= 1.14
                best = max(best, value)
        finally:
            player.active = original_active
        return best

    def _estimated_attack_damage(self, state: GameState, player_idx: int, attack_idx: int) -> int:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not opponent.active:
            return 0
        if getattr(opponent.active, 'damage_prevented_next_turn', False):
            return 0
        attack = player.active.card.attacks[attack_idx]
        damage = attack.damage
        for effect in attack_runtime_effects(attack):
            compiled_damage = self._compiled_damage_value(state, player_idx, effect)
            if compiled_damage is not None:
                damage = max(damage, compiled_damage)
                continue

            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype == "conditional_damage_bonus":
                condition = str(params.get("condition", "") or "")
                bonus = int(params.get("bonus", params.get("amount", 0)) or 0)
                if condition == "opponent_active_damaged":
                    if opponent.active.damage_counters > 0:
                        damage += bonus
                elif condition == "field_energy_ge_5":
                    if self._field_energy_count(player) >= 5:
                        damage += bonus
                elif condition == "opponent_active_evolved":
                    if opponent.active and not opponent.active.card.is_basic_pokemon:
                        damage += bonus
                elif condition == "ko_by_attack_last_turn":
                    if player.was_ko_by_attack:
                        damage += bonus
                elif opponent.active.damage_counters > 0:
                    damage += bonus
            elif etype == "attack_damage_formula":
                formula_damage = int(params.get("base", 0) or 0)
                per_own_bench = int(params.get("per_own_bench", 0) or 0)
                if per_own_bench:
                    formula_damage += player.bench_count() * per_own_bench
                per_counter = int(params.get("per_self_damage_counter", 0) or 0)
                if per_counter:
                    formula_damage += player.active.damage_counters * per_counter
                energy_type = str(params.get("per_self_energy_type", "") or "").lower()
                if energy_type:
                    energy_count = sum(
                        1 for c in player.active.energy_cards
                        if energy_type in {
                            str(e).lower()
                            for e in getattr(c, "provides_energy", [])
                        }
                    )
                    formula_damage += energy_count * int(params.get("per_energy", 0) or 0)
                condition_bonus = params.get("condition_bonus") or {}
                if isinstance(condition_bonus, dict):
                    condition = str(condition_bonus.get("condition", "") or "")
                    applies = False
                    if condition == "ko_by_attack_last_turn":
                        applies = player.was_ko_by_attack
                    elif condition == "own_bench_damaged":
                        applies = any(p is not None and p.damage_counters > 0 for p in player.bench)
                    elif condition == "opponent_active_evolved":
                        applies = opponent.active is not None and not opponent.active.card.is_basic_pokemon
                    elif condition == "opponent_active_damaged":
                        applies = opponent.active is not None and opponent.active.damage_counters > 0
                    elif condition == "own_hand_empty":
                        applies = len(player.hand) == 0
                    if applies:
                        formula_damage += int(condition_bonus.get("bonus", 0) or 0)
                damage = max(damage, formula_damage)
            elif etype == "conditional_damage_heal":
                base = int(params.get("base", damage) or 0)
                bonus = int(params.get("bonus", 0) or 0)
                condition = params.get("condition", "")
                damaged_self = any(
                    p is not None and p.damage_counters > 0
                    for _, p in player.get_all_pokemon()
                )
                damage = max(damage, base + (bonus if condition in ("self_damaged", "") and damaged_self else 0))
            elif etype in ("damage_per_self_energy", "damage_per_self_energy_type"):
                energy_type = params.get("energy_type", params.get("energy_filter", "any"))
                if energy_type and energy_type != "any":
                    required = str(energy_type).lower()
                    energy_count = sum(
                        1 for c in player.active.energy_cards
                        if required in {str(e).lower() for e in getattr(c, "provides_energy", [])}
                    )
                else:
                    energy_count = len(player.active.energy_cards)
                base = int(params.get("base", 0) or 0)
                damage = max(damage, base + energy_count * int(params.get("per_energy", 20)))
            elif etype == "damage_per_energy":
                count_from = params.get("count_from", "self")
                source = player.active if count_from == "self" else opponent.active
                base = int(params.get("base", 0) or 0)
                damage = max(damage, base + len(source.energy_cards) * int(params.get("per_energy", 0)))
            elif etype == "damage_plus_bench":
                damage = max(damage, int(params.get("base", 0)) + player.bench_count() * int(params.get("per_bench", 20)))
            elif etype == "damage_per_hand_size":
                per = int(params.get("per", 20) or 20)
                damage = max(damage, len(player.hand) * per)
            elif etype == "discard_hand_conditional_bonus":
                threshold = int(params.get("threshold", 5) or 5)
                base = int(params.get("base_damage", damage) or damage)
                bonus = int(params.get("bonus", 0) or 0)
                damage = max(damage, base + (bonus if len(player.hand) >= threshold else 0))
            elif etype == "damage_per_self_damage":
                base = int(params.get("base", 0) or 0)
                per_counter = int(params.get("per_counter", 10) or 10)
                damage = max(damage, base + player.active.damage_counters * per_counter)
            elif etype == "damage_self_penalty":
                base = int(params.get("base", damage) or damage)
                per_counter = int(params.get("per_counter", 20) or 20)
                damage = max(0, max(damage, base - player.active.damage_counters * per_counter))
            elif etype == "damage_per_evolved":
                evolved = sum(
                    1 for _, p in player.get_all_pokemon()
                    if p is not None and (p.evolution_stack or p.card.api_id in self.profile.evolution_cards)
                )
                damage = max(damage, evolved * int(params.get("per_evolved", 50) or 50))
            elif etype == "damage_per_discard_psychic":
                base = int(params.get("base", 80) or 80)
                per_card = int(params.get("per_card", 10) or 10)
                psychic = sum(
                    1 for c in player.discard
                    if getattr(c, "is_pokemon", False)
                    and "Psychic" in getattr(c, "energy_types", [])
                )
                damage = max(damage, base + psychic * per_card)
            elif etype == "discard_fighting_energy_damage":
                fighting = sum(1 for c in player.active.energy_cards if "Fighting" in getattr(c, "provides_energy", []))
                damage = max(
                    damage,
                    int(params.get("base", 10) or 10) + fighting * int(params.get("per_energy", 60) or 60),
                )
            elif etype == "mill_and_damage_per_energy":
                energy_seen = sum(1 for c in player.deck[-5:] if getattr(c, "is_energy", False))
                damage = max(damage, energy_seen * int(params.get("damage_per", 80) or 80))
            elif etype == "damage_and_self_heal":
                damage = max(damage, int(params.get("damage", damage) or damage))
            elif etype == "any_pokemon_damage":
                damage = max(damage, int(params.get("amount", 0) or 0))
            elif etype == "coin_flip_triple":
                flips = int(params.get("flips", 3) or 3)
                damage = max(damage, int(flips * 0.5 * int(params.get("damage_per_head", 10) or 10)))
            elif etype == "coin_flip_until_tails":
                damage = max(damage, int(params.get("per_head", 20) or 20))
            elif etype == "coin_flip_double_ko":
                damage = max(damage, int(opponent.active.current_hp * 0.25))
            elif etype == "coin_flip":
                heads = effect_branch(effect, "on_heads")
                tails = effect_branch(effect, "on_tails")
                heads_damage = self._branch_expected_damage(state, player_idx, heads)
                tails_damage = self._branch_expected_damage(state, player_idx, tails)
                damage = max(damage, int((heads_damage + tails_damage) / 2))
        damage = self._apply_estimated_damage_modifiers(state, player_idx, damage)
        return max(0, damage)

    def _compiled_damage_value(self, state: GameState, player_idx: int, effect: Any) -> int | None:
        if not isinstance(effect, dict) or str(effect.get("op", "") or "") != "deal_damage":
            return None

        params = self._effect_params(effect)
        target = str(params.get("target", "opponent_active") or "opponent_active")
        if target not in {"opponent_active", "any_opponent"}:
            return None

        formula_ast = params.get("formula_ast")
        if formula_ast is not None:
            try:
                from engine.commands.base import ResolutionContext
                from engine.commands.formula_ast import evaluate_formula_ast
                from engine.commands.resolution_stack import ResolutionStack

                ctx = ResolutionContext(
                    state,
                    player_idx,
                    "active",
                    ResolutionStack(state),
                )
                return evaluate_formula_ast(formula_ast, ctx)
            except (TypeError, ValueError):
                return None

        if "amount" in params:
            return int(params.get("amount", 0) or 0)
        return None

    def _apply_estimated_damage_modifiers(self, state: GameState, player_idx: int, damage: int) -> int:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        attacker = player.active
        defender = opponent.active
        if attacker is None or defender is None or damage <= 0:
            return max(0, damage)

        defender_tool = getattr(defender, "attached_tool", None)
        if defender_tool is not None:
            for effect in trainer_runtime_effects(defender_tool):
                params = self._effect_params(effect)
                if (
                    params.get("effect") == "damage_reduction_stage1"
                    and getattr(defender.card, "is_stage1", False)
                ):
                    damage -= int(params.get("amount", 30) or 30)

        outgoing_reduction = int(
            getattr(attacker, "outgoing_damage_reduction_next_turn", 0) or 0
        )
        if outgoing_reduction > 0:
            damage -= outgoing_reduction
        return max(0, damage)

    @staticmethod
    def _effect_type(effect: Any) -> str:
        return effect_type(effect)

    @staticmethod
    def _effect_params(effect: Any) -> dict[str, Any]:
        return effect_params(effect)

    def _branch_expected_damage(self, state: GameState, player_idx: int, effects: list[Any]) -> int:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not opponent.active:
            return 0
        effects = as_effect_list(effects)
        damage = 0
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype == "damage":
                damage += int(params.get("amount", 0) or 0)
            elif etype == "damage_per_self_energy":
                damage += len(player.active.energy_cards) * int(params.get("per_energy", 20) or 20)
            elif etype == "energy_discard":
                damage += 25 if opponent.active.energy_cards else 0
            elif etype == "attack_fail":
                damage -= 30
        return max(0, damage)

    def _effect_tactical_value(
        self,
        state: GameState,
        player_idx: int,
        effects: list[Any],
        source_slot: str | None = None,
    ) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        target_immune_effects = getattr(opponent.active, 'all_prevented_next_turn', False) if opponent.active else False
        effects = as_effect_list(effects)
        value = 0.0
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype in ("draw", "shuffle_draw", "discard_draw", "draw_until", "draw_until_more"):
                draw_count = int(params.get("amount", params.get("count", params.get("draw", 1))) or 1)
                value += 24 + draw_count * 8
            elif etype in ("discard_then_draw",):
                value += 20 + int(params.get("draw_amount", params.get("draw", 1)) or 1) * 10
            elif etype == "trekking_shoes":
                value += 38
            elif etype == "zinnia_resolve":
                if len(player.hand) >= 2:
                    opp_count = (1 if opponent.active else 0) + opponent.bench_count()
                    value += 18 + max(0, opp_count - 1) * 13
            elif etype == "houb":
                target = int(params.get("target_hand_size", 5) or 5)
                if len(player.hand) > 1:
                    value += 20 + max(0, target - len(player.hand) + 1) * 12
            elif etype == "arven":
                item_count = sum(1 for card in player.deck if getattr(card, "is_trainer_item", False))
                tool_count = sum(1 for card in player.deck if getattr(card, "is_trainer_tool", False))
                targets = min(1, item_count) + min(1, tool_count)
                if targets:
                    value += 28 + targets * 24
            elif etype in ("search", "look_top_deck", "conditional_search_extra", "search_any_and_switch"):
                value += 42
                if etype == "look_top_deck" and params.get("destination") == "bench_energy":
                    value += self._energy_acceleration_value(state, player_idx, params, source_slot)
            elif etype in ("energy_attach", "attach_from_discard", "draw_and_attach_energy"):
                accel_params = dict(params)
                if etype == "attach_from_discard":
                    accel_params.setdefault("from_zone", "discard")
                elif etype == "energy_attach":
                    accel_params.setdefault("from_zone", "hand")
                accel_value = self._energy_acceleration_value(state, player_idx, accel_params, source_slot)
                if accel_value > 0:
                    value += 45 + accel_value
                elif etype == "draw_and_attach_energy":
                    value += 18
            elif etype == "energy_relocate":
                value += self._best_energy_relocation_gain(state, player_idx, source_slot, params)
            elif etype == "tool":
                effect_name = str(params.get("effect", ""))
                if "damage_boost" in effect_name:
                    value += 55
                elif "hp_boost" in effect_name:
                    value += 45
                else:
                    value += 28
            elif etype in ("energy_discard", "coin_flip_energy_discard"):
                if target_immune_effects:
                    value += 0
                else:
                    value += 55 if opponent.active and opponent.active.energy_cards else 18
            elif etype in ("switch_self", "return_to_hand"):
                value += 35 if player.bench_count() else 0
            elif etype == "switch_opponent":
                if target_immune_effects:
                    value += 0
                else:
                    value += 65 if opponent.bench_count() else 0
            elif etype in (
                "prevent_all",
                "attack_lock_basic",
                "apply_outgoing_damage_reduction",
                "self_attack_lock",
            ):
                if target_immune_effects and etype != "self_attack_lock":
                    value += 0
                else:
                    value += 70
            elif etype in ("heal", "heal_all", "potion_heal", "damage_and_self_heal", "conditional_damage_heal"):
                damaged = sum(max(0, p.card.hp - p.current_hp) for _, p in player.get_all_pokemon() if p)
                value += min(80, damaged * 0.6)
            elif etype == "damage_counter_self":
                source = player.get_pokemon(source_slot) if source_slot else player.active
                amount = int(params.get("amount", 0) or 0)
                if source and source.current_hp <= amount + 20:
                    value -= 95
                else:
                    value -= amount * 0.35
            elif etype in ("any_pokemon_damage", "place_counters_and_self_ko"):
                amount = int(params.get("amount", params.get("counters", 0) * 10) or 0)
                low_targets = [
                    p for p in [opponent.active, *opponent.bench]
                    if p is not None and p.current_hp <= max(90, amount)
                ]
                # Filter out immune targets for bench/active targeting
                snipeable = [p for p in low_targets
                             if not getattr(p, 'all_prevented_next_turn', False)]
                if not snipeable and not low_targets:
                    value += 0
                elif not snipeable:
                    value += amount * 0.15  # reduced: active immune but bench may not be
                else:
                    value += amount * 0.35 + (90 if snipeable else 0)
            elif "coin" in etype:
                value += 12
        return value

    def _static_effect_value(self, effects: list[Any]) -> float:
        value = 0.0
        resource_effects = {
            "draw",
            "search",
            "look_top_deck",
            "shuffle_draw",
            "discard_then_draw",
            "trekking_shoes",
            "houb",
            "zinnia_resolve",
        }
        energy_effects = {
            "energy_attach",
            "attach_from_discard",
            "draw_and_attach_energy",
            "energy_relocate",
        }
        prevention_effects = {"prevent_all", "attack_lock_basic"}
        healing_effects = {
            "heal",
            "heal_all",
            "potion_heal",
            "damage_and_self_heal",
            "conditional_damage_heal",
        }
        disruption_effects = {"energy_discard", "switch_opponent", "any_pokemon_damage"}
        for effect in iter_effects_recursive(effects):
            names = set(effect_feature_names(effect))
            if names & resource_effects:
                value += 35
            elif names & energy_effects:
                value += 42
            elif names & prevention_effects:
                value += 60
            elif names & healing_effects:
                value += 32
            elif names & disruption_effects:
                value += 45
            elif any("coin" in name for name in names):
                value += 14
            else:
                value += 10
        return value

    def _policy_state_score(self, state: GameState, player_idx: int) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        features = self._policy_features(state, player_idx)
        score = sum(self.policy_weights.get(name, 0.0) * value for name, value in features.items())
        if player.active and opponent.active:
            best_damage = max(
                [
                    self._estimated_attack_damage(state, player_idx, idx)
                    for idx, _ in enumerate(player.active.card.attacks)
                    if can_declare_attack(state, player_idx, idx)[0]
                ] or [0]
            )
            if best_damage >= opponent.active.current_hp:
                score += opponent.active.card.prize_value * 75 * self.policy_weights.get("ko_pressure", 1.0)
        return score

    def _policy_features(self, state: GameState, player_idx: int) -> dict[str, float]:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        own_pokemon = [p for _, p in player.get_all_pokemon() if p is not None]
        own_ids = [p.card.api_id for p in own_pokemon]
        hand_ids = [getattr(c, "api_id", "") for c in player.hand]
        matching_energy_hand = sum(
            1 for c in player.hand
            if getattr(c, "is_energy", False) and self._energy_matches_profile(c)
        )
        matching_energy_attached = sum(
            1 for p in own_pokemon for c in p.energy_cards if self._energy_matches_profile(c)
        )
        low_hp_targets = sum(
            1 for p in [opponent.active, *opponent.bench]
            if p is not None and p.current_hp <= 70
        )
        damaged_self = sum(max(0, p.card.hp - p.current_hp) for p in own_pokemon)
        return {
            "core_in_play": sum(1 for cid in own_ids if cid in self.profile.core_cards),
            "core_in_hand": sum(1 for cid in hand_ids if cid in self.profile.core_cards),
            "engine_in_play": sum(1 for cid in own_ids if cid in self.profile.engine_cards),
            "engine_in_hand": sum(1 for cid in hand_ids if cid in self.profile.engine_cards),
            "preferred_bench": sum(
                1 for p in player.bench if p is not None and p.card.api_id in self.profile.preferred_bench
            ),
            "evolved_count": sum(1 for p in own_pokemon if p.evolution_stack or p.card.api_id in self.profile.evolution_cards),
            "matching_energy_attached": matching_energy_attached,
            "matching_energy_hand": matching_energy_hand,
            "trainer_in_hand": sum(1 for cid in hand_ids if cid in self.profile.trainer_cards),
            "damaged_self": damaged_self,
            "low_hp_targets": low_hp_targets,
            "hand_size": len(player.hand),
            "bench_count": player.bench_count(),
        }

    def _profile_pokemon_bonus(self, pokemon, slot: str = "") -> float:
        cid = getattr(pokemon.card, "api_id", "")
        value = 0.0
        if cid in self.profile.core_cards:
            value += self.policy_weights.get("core_in_play", 0.0)
        if cid in self.profile.engine_cards:
            value += self.policy_weights.get("engine_in_play", 0.0)
        if slot != "active" and cid in self.profile.preferred_bench:
            value += self.policy_weights.get("preferred_bench", 0.0)
        if cid in self.profile.evolution_cards or pokemon.evolution_stack:
            value += self.policy_weights.get("evolved_count", 0.0) * 0.7
        return value

    def _profile_card_bonus(self, state: GameState, player_idx: int, card: Any) -> float:
        cid = getattr(card, "api_id", "")
        if not cid:
            return 0.0
        value = 0.0
        if cid in self.profile.core_cards:
            value += self.policy_weights.get("core_in_hand", 0.0)
        if cid in self.profile.engine_cards:
            value += self.policy_weights.get("engine_in_hand", 0.0)
        if cid in self.profile.preferred_bench:
            value += self.policy_weights.get("preferred_bench", 0.0)
        if cid in self.profile.evolution_cards:
            value += self.policy_weights.get("evolved_count", 0.0)
        if cid in self.profile.trainer_cards:
            value += self.policy_weights.get("trainer_in_hand", 0.0)
        if getattr(card, "is_energy", False) and self._energy_matches_profile(card):
            value += self.policy_weights.get("matching_energy_hand", 0.0)
        return value

    def _energy_matches_profile(self, card: Any) -> bool:
        provided = set(getattr(card, "provides_energy", []) or [])
        if not self.profile.energy_types:
            return bool(provided)
        if "Rainbow" in provided:
            return True
        if "Colorless" in self.profile.energy_types and provided:
            return True
        return bool(provided & self.profile.energy_types)

    # ------------------------------------------------------------------
    # Heuristics
    # ------------------------------------------------------------------

    def _card_value(self, state: GameState, player_idx: int, card: Any) -> float:
        if not hasattr(card, "api_id"):
            return 0.0
        player = state.get_player(player_idx)
        value = 0.0
        if card.is_pokemon:
            value += card.hp * 0.4 + len(card.attacks) * 10
            if card.is_basic_pokemon:
                value += 45 if player.bench_has_space() else 5
            else:
                if any(p and card.evolves_from.lower() == p.card.name.lower() for _, p in player.get_all_pokemon()):
                    value += 95
                else:
                    value += 20
            if "ex" in card.subtypes:
                value += 50
        elif card.is_energy:
            value += 45
            if player.active:
                best_missing = min(
                    [self._missing_energy_count(player.active, atk.cost) for atk in player.active.card.attacks] or [0]
                )
                value += max(0, 30 - best_missing * 5)
        elif card.is_trainer:
            value += 30
            text = " ".join(getattr(card, "rules", []) or [])
            if "draw" in text.lower() or card.is_trainer_supporter:
                value += 30
            if card.is_trainer_item:
                value += 22
            if card.is_trainer_tool:
                value += 18
            if card.is_trainer_stadium:
                value += 12
            for effect in trainer_runtime_effects(card):
                etype = self._effect_type(effect)
                if etype in ("search", "look_top_deck", "arven", "evolve_skip_stage"):
                    value += 55
                elif etype in ("draw", "discard_draw", "draw_until", "draw_and_attach_energy", "shuffle_draw"):
                    value += 45
                else:
                    value += self._static_effect_value([effect]) * 0.35
        value += self._profile_card_bonus(state, player_idx, card)
        return value

    def _search_card_value(
        self, state: GameState, player_idx: int, card: Any, req: ActionRequest | None = None
    ) -> float:
        value = self._card_value(state, player_idx, card)
        player = state.get_player(player_idx)
        prompt = ((req.prompt if req else "") or "").lower()
        from_zone = (getattr(req, "from_zone", "") or "").lower() if req else ""
        if getattr(card, "is_pokemon", False):
            if getattr(card, "is_basic_pokemon", False) and player.bench_has_space():
                value += 45
            if getattr(card, "is_stage1", False) or getattr(card, "is_stage2", False):
                if any(
                    p and getattr(card, "evolves_from", "").lower() == p.card.name.lower()
                    for _, p in player.get_all_pokemon()
                ):
                    value += 95
        if getattr(card, "is_energy", False):
            targets = [p for _, p in player.get_all_pokemon() if p is not None]
            if targets:
                best_missing = min(self._best_missing_energy(p) for p in targets)
                value += max(0, 4 - best_missing) * 20
            if "energy" in prompt or "energy" in from_zone:
                value += 28
        if getattr(card, "is_trainer", False):
            effects = trainer_runtime_effects(card)
            value += self._effect_tactical_value(state, player_idx, effects) * 0.45
        if getattr(card, "api_id", "") in self.profile.core_cards:
            value += 70
        if getattr(card, "api_id", "") in self.profile.engine_cards:
            value += 42
        value += self._expert_choice_card_value(state, player_idx, card, mode="search")
        return value

    def _discard_priority(self, state: GameState, player_idx: int, card: Any) -> float:
        player = state.get_player(player_idx)
        value = self._card_value(state, player_idx, card)
        duplicates = sum(1 for c in player.hand if getattr(c, "api_id", None) == getattr(card, "api_id", None))
        if duplicates > 1:
            value -= 55
        if getattr(card, "is_energy", False) and not player.energy_attached_this_turn:
            value += 80
        if getattr(card, "is_stage1", False) or getattr(card, "is_stage2", False):
            if not any(p and card.evolves_from.lower() == p.card.name.lower() for _, p in player.get_all_pokemon()):
                value -= 40
        value += self._expert_choice_card_value(state, player_idx, card, mode="discard")
        return value

    def _quick_action_priority(self, state: GameState, player_idx: int, action: AIAction) -> float:
        player = state.get_player(player_idx)
        profile_bonus = 0.0
        hand_idx = action.params.get("hand_idx")
        if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
            profile_bonus += self._profile_card_bonus(state, player_idx, player.hand[hand_idx])
        slot = action.params.get("slot") or action.params.get("target_slot") or action.params.get("target")
        if isinstance(slot, str):
            pokemon = player.get_pokemon(slot)
            if pokemon:
                profile_bonus += self._profile_pokemon_bonus(pokemon, slot) * 0.35
        expert_bonus = self._expert_action_order_bonus(state, player_idx, action)
        if action.action == PlayerAction.DECLARE_ATTACK:
            attack_idx = action.params["attack_idx"]
            attack = player.active.card.attacks[attack_idx] if player.active else None
            effect_bonus = self._effect_tactical_value(
                state,
                player_idx,
                attack_runtime_effects(attack) if attack else [],
            )
            damage = self._estimated_attack_damage(state, player_idx, attack_idx)
            ko_bonus = 0.0
            opponent = state.get_player(1 - player_idx)
            if opponent.active and damage >= opponent.active.current_hp:
                ko_bonus = 120 + opponent.active.card.prize_value * 80
            return 500 + damage + effect_bonus * 0.7 + ko_bonus + profile_bonus + expert_bonus
        if action.action == PlayerAction.PLAY_TRAINER:
            return 360 + profile_bonus + self._trainer_action_priority(state, player_idx, action) + expert_bonus
        if action.action == PlayerAction.EVOLVE:
            return 330 + profile_bonus + expert_bonus
        if action.action == PlayerAction.ATTACH_ENERGY:
            return 300 + profile_bonus + self._attach_action_priority(state, player_idx, action) + expert_bonus
        if action.action == PlayerAction.USE_ABILITY:
            return 280 + profile_bonus + self._ability_action_priority(state, player_idx, action) + expert_bonus
        if action.action == PlayerAction.PLAY_BASIC:
            return 210 + profile_bonus + expert_bonus
        if action.action == PlayerAction.RETREAT:
            return 120 + profile_bonus + expert_bonus
        if action.action == PlayerAction.END_TURN:
            return -50 + expert_bonus
        return expert_bonus

    def _trainer_action_priority(self, state: GameState, player_idx: int, action: AIAction) -> float:
        player = state.get_player(player_idx)
        hand_idx = action.params.get("hand_idx")
        if not isinstance(hand_idx, int) or not (0 <= hand_idx < len(player.hand)):
            return 0.0
        card = player.hand[hand_idx]
        effects = trainer_runtime_effects(card)
        value = self._effect_tactical_value(state, player_idx, effects) * 1.4
        value += self._card_value(state, player_idx, card) * 0.18
        target_slot = action.params.get("target_slot")
        if getattr(card, "is_trainer_tool", False) and isinstance(target_slot, str):
            target = player.get_pokemon(target_slot)
            if target:
                value += self._pokemon_development_value(target) * 0.18
                if self._best_missing_energy(target) == 0:
                    value += 35
        return value

    def _ability_action_priority(self, state: GameState, player_idx: int, action: AIAction) -> float:
        player = state.get_player(player_idx)
        slot = action.params.get("slot")
        ability_name = action.params.get("ability_name")
        if not isinstance(slot, str) or not isinstance(ability_name, str):
            return 0.0
        pokemon = player.get_pokemon(slot)
        if pokemon is None:
            return 0.0
        ability = next((a for a in pokemon.card.abilities if a.name == ability_name), None)
        if ability is None:
            return 0.0
        value = self._effect_tactical_value(
            state,
            player_idx,
            ability_runtime_effects(ability),
            source_slot=slot,
        ) * 1.5
        value += self._pokemon_development_value(pokemon) * 0.12
        if self._best_missing_energy(pokemon) > 0:
            value += 25
        return value

    def _setup_action_value(self, state: GameState, player_idx: int, action: AIAction) -> float:
        if action.action == "SETUP_DONE":
            return 10
        player = state.get_player(player_idx)
        card = player.hand[action.params["hand_idx"]]
        value = card.hp + self._ready_attack_value_for_card(card)
        value += self._profile_card_bonus(state, player_idx, card) * 1.5
        if action.params.get("target") == "active":
            value += 80
            if card.api_id in self.profile.setup_active:
                value += 120
            if (
                card.api_id in self.profile.preferred_bench
                and card.api_id not in self.profile.setup_active
                and self._has_alternative_setup_active_in_hand(state, player_idx, card.api_id)
            ):
                value -= 260
        elif card.api_id in self.profile.preferred_bench:
            value += 70
        return value

    def _has_alternative_setup_active_in_hand(
        self, state: GameState, player_idx: int, card_id: str
    ) -> bool:
        player = state.get_player(player_idx)
        return any(
            getattr(card, "is_basic_pokemon", False)
            and getattr(card, "api_id", "") != card_id
            and getattr(card, "api_id", "") in self.profile.setup_active
            for card in player.hand
        )

    def _ready_attack_value_for_card(self, card) -> float:
        if not getattr(card, "attacks", None):
            return 0.0
        return max(
            (
                atk.damage
                - len(atk.cost) * 15
                + self._static_effect_value(attack_runtime_effects(atk))
                for atk in card.attacks
            ),
            default=0.0,
        )

    def _target_priority(self, pokemon) -> float:
        if pokemon is None:
            return -10**9
        value = pokemon.card.prize_value * 140
        value += (pokemon.card.hp - pokemon.current_hp) * 1.4
        value += len(pokemon.energy_cards) * 35
        value += self._ready_attack_value(pokemon)
        if pokemon.current_hp <= 60:
            value += 120
        if pokemon.current_hp <= 80:
            value += self.policy_weights.get("low_hp_targets", 0.0)
        if "ex" in getattr(pokemon.card, "subtypes", []):
            value += self.policy_weights.get("ko_pressure", 1.0) * 35
        value += self._target_immunity_penalty(pokemon)
        return value

    def _target_immunity_penalty(self, pokemon) -> float:
        """Penalty for targeting a Pokemon with active immunity/prevention flags."""
        if pokemon is None:
            return 0.0
        penalty = 0.0
        if getattr(pokemon, 'damage_prevented_next_turn', False):
            penalty -= 120.0
        if getattr(pokemon, 'all_prevented_next_turn', False):
            penalty -= 80.0
        return penalty

    def _pokemon_development_value(self, pokemon) -> float:
        if pokemon is None:
            return -10**9
        return (
            self._ready_attack_value(pokemon)
            + pokemon.card.hp * 0.35
            + len(pokemon.evolution_stack) * 40
            + self._profile_pokemon_bonus(pokemon) * 0.6
        )

    def _promotion_value(self, pokemon) -> float:
        if pokemon is None:
            return -10**9
        return self._pokemon_development_value(pokemon) - pokemon.damage_counters * 12 - pokemon.card.retreat_cost * 8

    def _promotion_value_for_state(self, state: GameState, player_idx: int, pokemon) -> float:
        if pokemon is None:
            return -10**9
        value = self._promotion_value(pokemon)
        missing = self._best_missing_energy(pokemon)
        ready_damage = self._best_ready_pokemon_damage(state, player_idx, pokemon)
        if missing == 0:
            damage = ready_damage
            value += 140 + damage * 0.85
            value += self._best_ready_attack_effect_value(state, player_idx, pokemon) * 0.25
            opponent = state.get_player(1 - player_idx)
            if opponent.active and damage >= opponent.active.current_hp:
                value += 240 + opponent.active.card.prize_value * 110
        elif missing == 1:
            damage = self._best_pokemon_damage_with_max_missing(state, player_idx, pokemon, 1)
            value += 55 + damage * 0.20
        else:
            damage = self._best_pokemon_damage(state, player_idx, pokemon)
            value -= min(120, missing * 35)
        value += len(pokemon.energy_cards) * 18
        cid = getattr(pokemon.card, "api_id", "")
        opponent = state.get_player(1 - player_idx)
        opponent_damage = self._best_available_damage_against_candidate(state, player_idx, pokemon)
        if opponent_damage >= pokemon.current_hp:
            can_trade = opponent.active is not None and ready_damage >= opponent.active.current_hp
            value -= 85
            if not can_trade:
                value -= 90 + min(110, self._profile_pokemon_bonus(pokemon) * 0.45)
                value -= len(pokemon.energy_cards) * 24
                if cid in self.profile.core_cards or cid in self.profile.evolution_cards:
                    value -= 55
                if cid in self.profile.engine_cards:
                    value -= 30
        if missing > 0 and cid in self.profile.preferred_bench and cid not in self.profile.setup_active:
            value -= 70 + min(80, missing * 24)
        if missing > 0 and cid in self.profile.engine_cards and cid not in self.profile.core_cards:
            value -= 45
        if missing > 0 and pokemon.card.hp <= 70:
            value -= 45
        if pokemon.current_hp <= max(30, pokemon.card.hp * 0.25) and missing > 0:
            value -= 90
        return value

    def _forced_promotion_value(self, state: GameState, player_idx: int, pokemon) -> float:
        if pokemon is None:
            return -10**9
        opponent = state.get_player(1 - player_idx)
        ready_damage = self._best_ready_pokemon_damage(state, player_idx, pokemon)
        ready_effect = self._best_ready_attack_effect_value(state, player_idx, pokemon)
        opponent_damage = self._best_available_damage_against_candidate(state, player_idx, pokemon)
        can_take_prize = opponent.active is not None and ready_damage >= opponent.active.current_hp
        survives = opponent_damage <= 0 or opponent_damage < pokemon.current_hp
        cid = getattr(pokemon.card, "api_id", "")

        if can_take_prize:
            return (
                1000
                + ready_damage * 1.2
                + opponent.active.card.prize_value * 180
                + self._promotion_value_for_state(state, player_idx, pokemon) * 0.25
            )
        if survives:
            return (
                420
                + ready_damage * 0.75
                + ready_effect * 0.25
                + pokemon.current_hp * 0.35
                + self._promotion_value_for_state(state, player_idx, pokemon) * 0.25
            )

        asset_value = (
            self._pokemon_development_value(pokemon)
            + self._profile_pokemon_bonus(pokemon) * 0.85
            + len(pokemon.energy_cards) * 55
            + len(pokemon.evolution_stack) * 45
            + pokemon.card.prize_value * 120
        )
        value = ready_damage * 0.55 + ready_effect * 0.15 - asset_value
        if cid in self.profile.core_cards:
            value -= 120
        if cid in self.profile.engine_cards:
            value -= 70
        if pokemon.card.hp <= 70:
            value += 45
        if not pokemon.energy_cards:
            value += 35
        return value

    def _best_available_damage_against_candidate(self, state: GameState, player_idx: int, candidate) -> int:
        if candidate is None:
            return 0
        player = state.get_player(player_idx)
        original_active = player.active
        try:
            player.active = candidate
            return self._best_available_damage(state, 1 - player_idx)
        finally:
            player.active = original_active

    def _energy_target_value(self, state: GameState, player_idx: int, slot: str) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None:
            return -10**9
        best_missing = min([self._missing_energy_count(pokemon, atk.cost) for atk in pokemon.card.attacks] or [0])
        matching_bonus = self.policy_weights.get("matching_energy_attached", 0.0)
        return (
            self._pokemon_development_value(pokemon)
            + max(0, 4 - best_missing) * 35
            + matching_bonus
            + self._energy_plan_target_bonus(state, player_idx, slot)
        )

    def _energy_plan_target_bonus(self, state: GameState, player_idx: int, slot: str) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None:
            return -10**9
        cid = getattr(pokemon.card, "api_id", "")
        bonus = 0.0
        if cid in self.profile.core_cards:
            bonus += 95
        if cid in self.profile.evolution_cards or pokemon.evolution_stack:
            bonus += 45
        if cid in self.profile.engine_cards:
            bonus += 22
            if cid not in self.profile.core_cards:
                if len(pokemon.energy_cards) > 0:
                    bonus -= 55 * len(pokemon.energy_cards)
                if self._best_pokemon_damage(state, player_idx, pokemon) < 110:
                    bonus -= 25
        if slot != "active" and cid in self.profile.preferred_bench:
            bonus += 34
        if "ex" in getattr(pokemon.card, "subtypes", []):
            bonus += 45
        damage_ceiling = self._best_pokemon_damage(state, player_idx, pokemon)
        bonus += min(120.0, damage_ceiling * 0.35)
        missing = self._best_missing_energy(pokemon)
        if missing == 0:
            bonus += 35
        elif missing == 1:
            bonus += 25
        elif missing <= 3 and damage_ceiling >= 110:
            bonus += 30
        if slot == "active" and pokemon.current_hp <= max(40, pokemon.card.hp * 0.35) and missing > 0:
            bonus -= 65
        return bonus

    def _energy_assignment_target_value(
        self, state: GameState, player_idx: int, slot: str, energy_card: Any
    ) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None:
            return -10**9
        return (
            self._energy_target_value(state, player_idx, slot)
            + self._energy_attachment_marginal_value(state, player_idx, slot, energy_card)
        )

    def _energy_attachment_marginal_value(
        self, state: GameState, player_idx: int, slot: str, energy_card: Any
    ) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None:
            return -10**9
        before = self._best_missing_energy(pokemon)
        after = min(
            [
                self._missing_energy_count_with_extra(pokemon, attack.cost, energy_card)
                for attack in pokemon.card.attacks
            ] or [before]
        )
        progress = max(0, before - after)
        value = max(progress * 80, self._energy_attack_progress_value(pokemon, energy_card))
        if after == 0 and before > 0:
            value += 165 + self._best_pokemon_damage(state, player_idx, pokemon) * 0.22
        elif after == 1 and before > 1:
            value += 70
        if slot == "active":
            value += 30
        if self._energy_matches_profile(energy_card):
            value += self.policy_weights.get("matching_energy_attached", 0.0) * 0.6
        return value

    def _energy_removal_penalty(
        self,
        state: GameState,
        player_idx: int,
        slot: str,
        energy_card: Any | None = None,
    ) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None or not pokemon.energy_cards:
            return 0.0
        card = energy_card if energy_card in pokemon.energy_cards else pokemon.energy_cards[0]
        before = self._best_missing_energy(pokemon)
        original = list(pokemon.energy_cards)
        try:
            pokemon.energy_cards.remove(card)
            after = self._best_missing_energy(pokemon)
        finally:
            pokemon.energy_cards = original
        penalty = max(0, after - before) * 105
        if before == 0 and after > 0:
            penalty += 150
        if slot == "active":
            penalty += 45
        if self._best_pokemon_damage(state, player_idx, pokemon) >= 100 and before == 0:
            penalty += 35
        return penalty

    def _best_energy_relocation_gain(
        self,
        state: GameState,
        player_idx: int,
        source_slot: str | None = None,
        params: dict[str, Any] | None = None,
    ) -> float:
        player = state.get_player(player_idx)
        amount = int((params or {}).get("amount", 1) or 1)
        if source_slot:
            source_slots = [source_slot]
        else:
            source_slots = [
                slot for slot, pokemon in player.get_all_pokemon()
                if pokemon is not None and pokemon.energy_cards
            ]
        target_slots = [
            slot for slot, pokemon in player.get_all_pokemon()
            if pokemon is not None
        ]
        best = -float("inf")
        for src_slot in source_slots:
            source = player.get_pokemon(src_slot)
            if source is None or not source.energy_cards:
                continue
            for energy_card in source.energy_cards[: max(1, amount)]:
                loss = self._energy_removal_penalty(state, player_idx, src_slot, energy_card)
                for tgt_slot in target_slots:
                    if tgt_slot == src_slot:
                        continue
                    gain = self._energy_attachment_marginal_value(state, player_idx, tgt_slot, energy_card)
                    if gain <= 0:
                        continue
                    best = max(best, gain - loss)
        return 0.0 if best == -float("inf") else best

    def _energy_acceleration_value(
        self,
        state: GameState,
        player_idx: int,
        params: dict[str, Any],
        source_slot: str | None = None,
    ) -> float:
        player = state.get_player(player_idx)
        from_zone = str(params.get("from_zone", "deck"))
        filter_type = str(params.get("filter", params.get("energy_type", "any")) or "any")
        amount = int(params.get("amount", params.get("take", params.get("energy_count", 1))) or 1)
        if params.get("destination") == "bench_energy":
            amount = int(params.get("take", amount) or amount)

        if from_zone == "discard":
            source_cards = player.discard
        elif from_zone == "hand":
            source_cards = player.hand
        else:
            look_count = int(params.get("count", 0) or 0)
            source_cards = player.deck[-look_count:] if look_count > 0 else player.deck

        matching = [
            c for c in source_cards
            if getattr(c, "is_energy", False) and self._energy_filter_matches(c, filter_type)
        ]
        if not matching and params.get("destination") == "bench_energy":
            matching = [
                c for c in player.deck
                if getattr(c, "is_energy", False) and self._energy_filter_matches(c, filter_type)
            ][:amount]
        if not matching:
            return 0.0

        target_slots = self._energy_effect_target_slots(state, player_idx, params, source_slot)
        if not target_slots:
            return 0.0
        usable = matching[: max(1, min(amount, len(matching)))]
        best_marginal = max(
            self._energy_attachment_marginal_value(state, player_idx, slot, card)
            for card in usable
            for slot in target_slots
        )
        return min(260.0, len(usable) * 35 + max(0.0, best_marginal))

    def _energy_effect_target_slots(
        self,
        state: GameState,
        player_idx: int,
        params: dict[str, Any],
        source_slot: str | None = None,
    ) -> list[str]:
        player = state.get_player(player_idx)
        target_spec = str(params.get("to", params.get("target", "self")) or "self")
        if params.get("destination") == "bench_energy":
            target_spec = "bench"
        if target_spec == "self":
            slot = source_slot or "active"
            return [slot] if player.get_pokemon(slot) is not None else []
        if target_spec == "bench":
            return [f"bench_{i}" for i, p in enumerate(player.bench) if p is not None]
        if target_spec in ("any", "self_or_bench"):
            return [slot for slot, pokemon in player.get_all_pokemon() if pokemon is not None]
        if target_spec == "self_basic":
            return [
                slot for slot, pokemon in player.get_all_pokemon()
                if pokemon is not None and pokemon.card.is_basic_pokemon
            ]
        return [target_spec] if player.get_pokemon(target_spec) is not None else []

    def _energy_filter_matches(self, card: Any, filter_type: str) -> bool:
        if not getattr(card, "is_energy", False):
            return False
        normalized = filter_type.lower()
        if normalized in ("", "any", "energy"):
            return True
        if normalized in ("basic", "basic_energy"):
            return getattr(card, "is_basic_energy", False)
        if normalized.endswith("_energy"):
            normalized = normalized[:-7]
        if normalized == "basic":
            return getattr(card, "is_basic_energy", False)
        return any(str(et).lower() == normalized for et in getattr(card, "provides_energy", []) or [])

    def _attach_action_priority(self, state: GameState, player_idx: int, action: AIAction) -> float:
        player = state.get_player(player_idx)
        hand_idx = action.params.get("hand_idx")
        target_slot = action.params.get("target_slot")
        if not isinstance(hand_idx, int) or not isinstance(target_slot, str):
            return 0.0
        if not (0 <= hand_idx < len(player.hand)):
            return 0.0
        pokemon = player.get_pokemon(target_slot)
        if pokemon is None:
            return 0.0
        energy_card = player.hand[hand_idx]
        before = self._best_missing_energy(pokemon)
        after = min(
            [
                self._missing_energy_count_with_extra(pokemon, attack.cost, energy_card)
                for attack in pokemon.card.attacks
            ] or [before]
        )
        progress = max(0, before - after)
        value = max(progress * 55, self._energy_attack_progress_value(pokemon, energy_card) * 0.85)
        value += self._energy_plan_target_bonus(state, player_idx, target_slot) * 0.55
        if after == 0 and before > 0:
            value += 130
        elif after == 1 and before > 1:
            value += 55
        if target_slot == "active":
            value += 60
            if before > 0:
                value += 75
            if state.turn_number >= 3 and len(pokemon.energy_cards) == 0:
                value += 45
            if self._has_better_bench_energy_plan(state, player_idx, energy_card):
                value -= 135
        else:
            active_missing = self._best_missing_energy(player.active) if player.active else 99
            target_is_core = getattr(pokemon.card, "api_id", "") in self.profile.core_cards
            if active_missing > 0 and state.turn_number >= 3 and not target_is_core:
                value -= 55
            if after == 0:
                value += 35
        return value

    def _has_better_bench_energy_plan(
        self, state: GameState, player_idx: int, energy_card: Any
    ) -> bool:
        player = state.get_player(player_idx)
        if player.active is None:
            return False
        active_cid = getattr(player.active.card, "api_id", "")
        if (
            active_cid in self.profile.core_cards
            and player.active.current_hp > max(50, player.active.card.hp * 0.35)
            and self._best_pokemon_damage(state, player_idx, player.active) >= 110
        ):
            return False
        active_value = self._energy_assignment_target_value(state, player_idx, "active", energy_card)
        best_bench = -float("inf")
        for bench_idx, pokemon in enumerate(player.bench):
            if pokemon is None:
                continue
            slot = f"bench_{bench_idx}"
            value = self._energy_assignment_target_value(state, player_idx, slot, energy_card)
            if getattr(pokemon.card, "api_id", "") in self.profile.core_cards:
                value += 45
            best_bench = max(best_bench, value)
        return best_bench > active_value + 70

    def _energy_attack_progress_value(self, pokemon, energy_card: Any) -> float:
        if pokemon is None or not getattr(pokemon.card, "attacks", None):
            return 0.0
        best = 0.0
        for attack in pokemon.card.attacks:
            before = self._missing_energy_count(pokemon, attack.cost)
            after = self._missing_energy_count_with_extra(pokemon, attack.cost, energy_card)
            progress = max(0, before - after)
            if progress <= 0:
                continue
            impact = (
                float(getattr(attack, "damage", 0) or 0)
                + self._static_effect_value(attack_runtime_effects(attack)) * 0.6
            )
            value = progress * (45.0 + min(130.0, impact * 0.38))
            if after == 0:
                value += 95.0 + min(90.0, impact * 0.28)
            elif after == 1:
                value += 38.0 + min(45.0, impact * 0.16)
            best = max(best, value)
        return best

    def _missing_energy_count_with_extra(self, pokemon, cost: list[str], energy_card: Any) -> int:
        available = list(pokemon.available_energy)
        available.extend(getattr(energy_card, "provides_energy", []) or [])
        missing = 0
        for required in cost:
            if required == "Colorless":
                continue
            if required in available:
                available.remove(required)
            elif "Rainbow" in available:
                available.remove("Rainbow")
            else:
                missing += 1
        colorless = sum(1 for c in cost if c == "Colorless")
        return missing + max(0, colorless - len(available))

    def _missing_energy_count(self, pokemon, cost: list[str]) -> int:
        available = list(pokemon.available_energy)
        missing = 0
        for required in cost:
            if required == "Colorless":
                continue
            if required in available:
                available.remove(required)
            elif "Rainbow" in available:
                available.remove("Rainbow")
            else:
                missing += 1
        colorless = sum(1 for c in cost if c == "Colorless")
        return missing + max(0, colorless - len(available))

    def _action_key(
        self, state: GameState, player_idx: int, action: AIAction, card_key: str = ""
    ) -> tuple:
        params = tuple(sorted((k, v) for k, v in action.params.items() if k != "hand_idx"))
        if "hand_idx" in action.params and card_key:
            return (action.action, card_key, params)
        return (action.action, params)

    def _trace_action(self, action: AIAction) -> dict[str, Any]:
        action_name = action.action.name if isinstance(action.action, PlayerAction) else str(action.action)
        return {
            "action": action_name,
            "params": dict(action.params or {}),
            "terminal": bool(getattr(action, "terminal", False)),
        }

    def _trace_rejection(
        self,
        trace: dict[str, Any] | None,
        action: AIAction,
        reason: str,
    ) -> None:
        if trace is None:
            return
        row = self._trace_action(action)
        row["reason"] = reason
        trace.setdefault("rejected", []).append(row)

    def _record_decision_trace(
        self,
        state: GameState,
        player_idx: int,
        selected: AIAction,
    ) -> None:
        self.last_decision_trace = {
            "player_idx": player_idx,
            "phase": getattr(state.phase, "name", str(state.phase)),
            "search_algorithm": self.config.search_algorithm,
            "selected": self._trace_action(selected),
            "legal_actions": dict(self._last_legal_action_trace),
        }

def create_challenge_ai(deck_key: str, config: AIConfig | None = None) -> ChallengeAI:
    """Create a challenge AI configured for one of the built-in deck keys."""
    base = config or AIConfig()
    profile = get_deck_ai_profile(deck_key)
    return ChallengeAI(replace(base, deck_key=deck_key, profile=profile))

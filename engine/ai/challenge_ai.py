"""Fair-information challenge AI for local single-player matches.

The AI acts only through the normal rules layer.  It may inspect its own hidden
zones, but scoring and action generation intentionally avoid the opponent's
hand/deck/prize identities.
"""
from __future__ import annotations

import random
import time
from dataclasses import dataclass, field
from typing import Any

from engine.enums import PlayerAction, StatusType, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
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
from engine.snapshot import restore_state, snapshot_state
from engine.turn_manager import TurnManager


@dataclass(frozen=True)
class AIConfig:
    thinking_time_seconds: float = 5.0
    beam_width: int = 16
    max_sequence_depth: int = 8
    max_turn_actions: int = 30
    coin_sample_count: int = 8
    random_seed: int = 17


@dataclass(frozen=True)
class AIAction:
    action: PlayerAction | str
    params: dict[str, Any] = field(default_factory=dict)
    terminal: bool = False


@dataclass
class AIChoice:
    selected_cards: list[Any] = field(default_factory=list)
    selected_bench_slot: int | None = None
    selected_bench_targets: list[int] = field(default_factory=list)
    coin_results: list[bool] = field(default_factory=list)
    confirmed: bool = True
    assignments: list[tuple[int, str]] = field(default_factory=list)
    cancelled: bool = False


class ChallengeAI:
    """A tactical single-player opponent using legal actions and beam search."""

    def __init__(self, config: AIConfig | None = None):
        self.config = config or AIConfig()
        self.random = random.Random(self.config.random_seed)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def choose_action(self, state: GameState, player_idx: int) -> AIAction:
        if state.phase == TurnPhase.SETUP:
            return self._choose_setup_action(state, player_idx)
        if state.phase == TurnPhase.ATTACK:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)
        if state.phase != TurnPhase.MAIN:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        deadline = time.perf_counter() + max(0.01, self.config.thinking_time_seconds)
        return self._beam_search_action(state, player_idx, deadline)

    def resolve_pending_action(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        req = action_request
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)

        if req.request_type in ("search_deck", "select_hand_to_discard"):
            cards = list(req.card_list)
            if req.request_type == "select_hand_to_discard":
                ranked = sorted(cards, key=lambda c: self._discard_priority(state, player_idx, c))
            else:
                ranked = sorted(cards, key=lambda c: self._card_value(state, player_idx, c), reverse=True)
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
                for _ in range(12):
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

        return AIChoice(cancelled=True, confirmed=False)

    def apply_choice(
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
                    result = req.callback(slot)
                else:
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

        self._consume_pending_card(state, req)
        return result

    # ------------------------------------------------------------------
    # Action generation and search
    # ------------------------------------------------------------------

    def legal_actions(self, state: GameState, player_idx: int) -> list[AIAction]:
        if state.phase == TurnPhase.SETUP:
            return self._setup_actions(state, player_idx)
        if state.phase == TurnPhase.ATTACK:
            return [AIAction(PlayerAction.END_TURN, {}, terminal=True)]
        if state.phase != TurnPhase.MAIN or state.active_player_idx != player_idx:
            return []

        player = state.get_player(player_idx)
        actions: list[AIAction] = []
        seen: set[tuple] = set()

        def add(action: AIAction, card_key: str = ""):
            key = self._action_key(state, player_idx, action, card_key)
            if key not in seen:
                seen.add(key)
                actions.append(action)

        empty_slots = [f"bench_{i}" for i, p in enumerate(player.bench) if p is None]
        for hand_idx, card in enumerate(player.hand):
            card_key = getattr(card, "api_id", str(hand_idx))
            if card.is_basic_pokemon:
                for target in empty_slots:
                    add(AIAction(PlayerAction.PLAY_BASIC, {"hand_idx": hand_idx, "target": target}), card_key)
            elif card.is_stage1 or card.is_stage2:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_evolve(state, player_idx, slot, card)[0]:
                        add(AIAction(PlayerAction.EVOLVE, {"hand_idx": hand_idx, "slot": slot}), card_key)
            elif card.is_energy:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_attach_energy(state, player_idx, card, slot)[0]:
                        add(AIAction(PlayerAction.ATTACH_ENERGY, {"hand_idx": hand_idx, "target_slot": slot}), card_key)
            elif card.is_trainer:
                if card.is_trainer_tool:
                    for slot, pokemon in player.get_all_pokemon():
                        if pokemon and can_play_tool(state, player_idx, slot)[0]:
                            add(AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx, "target_slot": slot}), card_key)
                elif card.is_trainer_supporter:
                    if can_play_supporter(state, player_idx)[0]:
                        add(AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}), card_key)
                elif card.is_trainer_stadium:
                    if can_play_stadium(state, player_idx, card)[0]:
                        add(AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}), card_key)
                elif can_play_item(state, player_idx)[0]:
                    add(AIAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}), card_key)

        for slot, pokemon in player.get_all_pokemon():
            if not pokemon:
                continue
            for ability in pokemon.card.abilities:
                if getattr(ability, "trigger", "") not in ("", "on_turn"):
                    continue
                if can_use_ability(state, player_idx, slot, ability.name)[0]:
                    add(AIAction(PlayerAction.USE_ABILITY, {"slot": slot, "ability_name": ability.name}), ability.name)

        if state.stadium_card and not player.stadium_used_this_turn:
            add(AIAction(PlayerAction.USE_STADIUM, {}), getattr(state.stadium_card, "api_id", "stadium"))

        for bench_idx, pokemon in enumerate(player.bench):
            if pokemon and can_retreat(state, player_idx, bench_idx)[0]:
                add(AIAction(PlayerAction.RETREAT, {"bench_idx": bench_idx}))

        if player.active:
            for attack_idx, _ in enumerate(player.active.card.attacks):
                if can_declare_attack(state, player_idx, attack_idx)[0]:
                    add(AIAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": attack_idx}, terminal=True))

        add(AIAction(PlayerAction.END_TURN, {}, terminal=True))
        actions = self._filter_currently_executable_actions(state, player_idx, actions)
        actions.sort(key=lambda a: self._quick_action_priority(state, player_idx, a), reverse=True)
        return actions[: self.config.max_turn_actions]

    def _filter_currently_executable_actions(
        self, state: GameState, player_idx: int, actions: list[AIAction]
    ) -> list[AIAction]:
        """Drop generated actions whose effect layer currently has no valid resolution."""
        needs_dry_run = {
            PlayerAction.PLAY_TRAINER,
            PlayerAction.USE_ABILITY,
            PlayerAction.USE_STADIUM,
        }
        filtered: list[AIAction] = []
        for action in actions:
            if action.action not in needs_dry_run:
                filtered.append(action)
                continue
            sim = self._clone_state(state)
            result = self._apply_action_for_sim(sim, player_idx, action)
            if result is not None and result.success:
                filtered.append(action)
        return filtered

    def _beam_search_action(self, state: GameState, player_idx: int, deadline: float) -> AIAction:
        root_actions = self.legal_actions(state, player_idx)
        if not root_actions:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        frontier: list[tuple[float, int, GameState, AIAction]] = [
            (self.evaluate_state(state, player_idx), 0, self._clone_state(state), AIAction("NOOP"))
        ]
        best_score = -10**18
        best_action = root_actions[-1]

        for depth in range(self.config.max_sequence_depth):
            if time.perf_counter() >= deadline:
                break
            candidates: list[tuple[float, int, GameState, AIAction]] = []
            for _, actions_used, node_state, first_action in frontier:
                if time.perf_counter() >= deadline:
                    break
                actions = self.legal_actions(node_state, player_idx)
                for action in actions:
                    sim = self._clone_state(node_state)
                    result = self._apply_action_for_sim(sim, player_idx, action)
                    score = self.evaluate_state(sim, player_idx)
                    if result and not result.success:
                        score -= 100
                    root = action if first_action.action == "NOOP" else first_action
                    if action.terminal or sim.phase != TurnPhase.MAIN or sim.winner is not None:
                        if score > best_score:
                            best_score = score
                            best_action = root
                    else:
                        candidates.append((score, actions_used + 1, sim, root))

            if not candidates:
                break
            candidates.sort(key=lambda row: row[0], reverse=True)
            frontier = candidates[: self.config.beam_width]
            if frontier and frontier[0][0] > best_score:
                best_score = frontier[0][0]
                best_action = frontier[0][3]
        return best_action

    def _apply_action_for_sim(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> ActionResult | None:
        tm = TurnManager(state)
        if action.action == "SETUP_DONE":
            return ActionResult(True, "setup done")
        if action.action == "NOOP":
            return ActionResult(True, "")
        try:
            result = tm.perform_action(action.action, player_idx=player_idx, **action.params)
        except Exception as exc:
            return ActionResult(False, str(exc))
        self._resolve_result_pending_for_sim(state, result)
        self._auto_promote_for_sim(state)
        if (
            action.action == PlayerAction.DECLARE_ATTACK
            and result.success
            and state.phase == TurnPhase.ATTACK
            and state.winner is None
        ):
            try:
                end_result = tm.perform_action(PlayerAction.END_TURN, player_idx=player_idx)
            except Exception:
                return result
            self._resolve_result_pending_for_sim(state, end_result)
            self._auto_promote_for_sim(state)
        return result

    def _resolve_result_pending_for_sim(self, state: GameState, result: ActionResult):
        guard = 0
        while result and result.pending_action and guard < 8:
            guard += 1
            req = result.pending_action
            choice = self._resolve_pending_for_sim(state, req)
            callback_result = self.apply_choice(state, req, choice)
            if isinstance(callback_result, ActionRequest):
                result = ActionResult(True, "", pending_action=callback_result)
            elif isinstance(callback_result, ActionResult):
                result = callback_result
            else:
                result.pending_action = None
            self._auto_promote_for_sim(state)

    def _auto_promote_for_sim(self, state: GameState) -> None:
        guard = 0
        while state.pending_promotion_player >= 0 and guard < 4 and state.winner is None:
            guard += 1
            player_idx = state.pending_promotion_player
            player = state.get_player(player_idx)
            if player.active is not None:
                state.pending_promotion_player = -1
                continue
            candidates = [(i, p) for i, p in enumerate(player.bench) if p is not None]
            if not candidates:
                state.pending_promotion_player = -1
                if not player.has_any_pokemon_in_play():
                    state.winner = 1 - player_idx
                    state.phase = TurnPhase.GAME_OVER
                continue
            bench_idx, _ = max(candidates, key=lambda row: self._promotion_value(row[1]))
            player.promote_from_bench(bench_idx)
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).continue_after_promotion()
            else:
                state.pending_promotion_player = -1

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
                return AIChoice(coin_results=[True, False])
            flips = max(1, req.flip_count)
            sample_count = max(flips, self.config.coin_sample_count)
            pattern = [(i % 2) == 0 for i in range(sample_count)]
            return AIChoice(coin_results=pattern[:flips])
        return self.resolve_pending_action(state, req)

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
            return max(candidates, key=lambda i: self._pokemon_development_value(player.bench[i]))
        return max(candidates, key=lambda i: self._promotion_value(player.bench[i]))

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

    def _confirm_pending(self, state: GameState, player_idx: int, req: ActionRequest) -> bool:
        prompt = req.prompt or ""
        if "discard" in prompt.lower() or "draw" in prompt.lower():
            return True
        player = state.get_player(player_idx)
        if player.active and player.active.current_hp <= max(40, player.active.card.hp * 0.35):
            return True
        return True

    def _choose_energy_assignments(
        self, state: GameState, player_idx: int, req: ActionRequest
    ) -> list[tuple[int, str]]:
        targets = list(getattr(req, "target_info", []) or [])
        cards = list(req.card_list)
        if not targets or not cards:
            return []
        assignments: list[tuple[int, str]] = []
        per_target: dict[str, int] = {}
        for energy_idx, _ in enumerate(cards):
            best_target = max(
                targets,
                key=lambda t: self._energy_target_value(state, player_idx, t["slot"]) -
                per_target.get(t["slot"], 0) * 12,
            )
            slot = best_target["slot"]
            if per_target.get(slot, 0) >= getattr(req, "max_per_target", 99):
                continue
            assignments.append((energy_idx, slot))
            per_target[slot] = per_target.get(slot, 0) + 1
        return assignments

    def _consume_pending_card(self, state: GameState, req: ActionRequest):
        card = getattr(req, "pending_card", None)
        if not card:
            return
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)
        if card not in player.discard and card not in player.hand:
            if getattr(card, "is_trainer_supporter", False) or getattr(card, "is_trainer_item", False):
                player.discard.append(card)
        req.pending_card = None

    # ------------------------------------------------------------------
    # Evaluation
    # ------------------------------------------------------------------

    def evaluate_state(self, state: GameState, player_idx: int) -> float:
        opponent_idx = 1 - player_idx
        if state.winner == player_idx:
            return 1_000_000
        if state.winner == opponent_idx:
            return -1_000_000

        player = state.get_player(player_idx)
        opponent = state.get_player(opponent_idx)
        score = 0.0
        score += (6 - len(player.prizes)) * 320
        score -= (6 - len(opponent.prizes)) * 340
        score += len(player.hand) * 12
        score -= opponent.hand_count * 4
        score += min(len(player.deck), 12) * 2
        if len(player.deck) <= 2:
            score -= (3 - len(player.deck)) * 80

        score += self._board_value(state, player_idx)
        score -= self._board_value(state, opponent_idx) * 0.95
        score += self._attack_pressure(state, player_idx)
        score -= self._attack_pressure(state, opponent_idx) * 0.85
        score += sum(self._card_value(state, player_idx, c) * 0.12 for c in player.hand)
        return score

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
        return pressure

    def _ready_attack_value(self, pokemon) -> float:
        if not pokemon.card.attacks:
            return 0.0
        best = 0.0
        for attack in pokemon.card.attacks:
            missing = self._missing_energy_count(pokemon, attack.cost)
            best = max(best, attack.damage - missing * 30 + len(attack.effects) * 12)
        return best * 0.45

    def _estimated_attack_damage(self, state: GameState, player_idx: int, attack_idx: int) -> int:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not opponent.active:
            return 0
        attack = player.active.card.attacks[attack_idx]
        damage = attack.damage
        for effect in attack.effects:
            etype = getattr(effect, "effect_type", "")
            params = getattr(effect, "params", {})
            if etype == "conditional_damage_bonus" and opponent.active.damage_counters > 0:
                damage += int(params.get("bonus", params.get("amount", 0)) or 0)
            elif etype in ("damage_per_self_energy", "damage_per_self_energy_type"):
                damage = max(damage, len(player.active.energy_cards) * int(params.get("per_energy", 20)))
            elif etype == "damage_plus_bench":
                damage = max(damage, int(params.get("base", 0)) + player.bench_count() * int(params.get("per_bench", 20)))
        return max(0, damage)

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
            for effect in getattr(card, "trainer_effects", []) or []:
                if effect.effect_type in ("search", "look_top_deck", "arven", "evolve_skip_stage"):
                    value += 55
                elif effect.effect_type in ("draw", "discard_draw", "draw_until", "draw_and_attach_energy"):
                    value += 45
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
        return value

    def _quick_action_priority(self, state: GameState, player_idx: int, action: AIAction) -> float:
        if action.action == PlayerAction.DECLARE_ATTACK:
            return 500 + self._estimated_attack_damage(state, player_idx, action.params["attack_idx"])
        if action.action == PlayerAction.PLAY_TRAINER:
            return 360
        if action.action == PlayerAction.EVOLVE:
            return 330
        if action.action == PlayerAction.ATTACH_ENERGY:
            return 300
        if action.action == PlayerAction.USE_ABILITY:
            return 280
        if action.action == PlayerAction.PLAY_BASIC:
            return 210
        if action.action == PlayerAction.RETREAT:
            return 120
        if action.action == PlayerAction.END_TURN:
            return -50
        return 0

    def _setup_action_value(self, state: GameState, player_idx: int, action: AIAction) -> float:
        if action.action == "SETUP_DONE":
            return 10
        player = state.get_player(player_idx)
        card = player.hand[action.params["hand_idx"]]
        value = card.hp + self._ready_attack_value_for_card(card)
        if action.params.get("target") == "active":
            value += 80
        return value

    def _ready_attack_value_for_card(self, card) -> float:
        if not getattr(card, "attacks", None):
            return 0.0
        return max((atk.damage - len(atk.cost) * 15 + len(atk.effects) * 10 for atk in card.attacks), default=0.0)

    def _target_priority(self, pokemon) -> float:
        if pokemon is None:
            return -10**9
        value = pokemon.card.prize_value * 140
        value += (pokemon.card.hp - pokemon.current_hp) * 1.4
        value += len(pokemon.energy_cards) * 35
        value += self._ready_attack_value(pokemon)
        if pokemon.current_hp <= 60:
            value += 120
        return value

    def _pokemon_development_value(self, pokemon) -> float:
        if pokemon is None:
            return -10**9
        return self._ready_attack_value(pokemon) + pokemon.card.hp * 0.35 + len(pokemon.evolution_stack) * 40

    def _promotion_value(self, pokemon) -> float:
        if pokemon is None:
            return -10**9
        return self._pokemon_development_value(pokemon) - pokemon.damage_counters * 12 - pokemon.card.retreat_cost * 8

    def _energy_target_value(self, state: GameState, player_idx: int, slot: str) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None:
            return -10**9
        best_missing = min([self._missing_energy_count(pokemon, atk.cost) for atk in pokemon.card.attacks] or [0])
        return self._pokemon_development_value(pokemon) + max(0, 4 - best_missing) * 35

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

    # ------------------------------------------------------------------
    # State cloning
    # ------------------------------------------------------------------

    def _clone_state(self, state: GameState) -> GameState:
        clone = GameState()
        restore_state(clone, snapshot_state(state))
        clone.action_log = list(state.action_log)
        clone.pending_promotion_player = state.pending_promotion_player
        self._rebuild_event_bus(clone)
        return clone

    def _rebuild_event_bus(self, state: GameState):
        from engine.commands.modifier_registration import register_pokemon_modifiers

        state.event_bus.clear()
        for player_idx in (0, 1):
            player = state.get_player(player_idx)
            for slot, pokemon in player.get_all_pokemon():
                if pokemon:
                    register_pokemon_modifiers(pokemon, player_idx, slot, event_bus=state.event_bus)

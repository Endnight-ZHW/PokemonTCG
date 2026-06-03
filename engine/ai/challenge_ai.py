"""Fair-information challenge AI for local single-player matches.

The AI acts only through the normal rules layer.  It may inspect its own hidden
zones, but scoring and action generation intentionally avoid the opponent's
hand/deck/prize identities.
"""
from __future__ import annotations

import random
import time
from collections import defaultdict
from dataclasses import dataclass, field, replace
from math import comb
from typing import Any

from engine.enums import PlayerAction, StatusType, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.ai.profiles import (
    DEFAULT_POLICY_PATH,
    DeckAIProfile,
    get_deck_ai_profile,
    load_policy_weights,
    merged_profile_weights,
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
from engine.snapshot import restore_state, snapshot_state
from engine.turn_manager import TurnManager


@dataclass(frozen=True)
class AIConfig:
    thinking_time_seconds: float = 6.0
    beam_width: int = 16
    max_sequence_depth: int = 8
    max_turn_actions: int = 30
    coin_sample_count: int = 8
    opponent_response_actions: int = 8
    opponent_response_weight: float = 0.55
    deterministic_search: bool = False
    random_seed: int = 17
    deck_key: str | None = None
    policy_path: str | None = DEFAULT_POLICY_PATH
    policy_weights: dict[str, float] | None = None
    profile: DeckAIProfile | None = None
    # Search settings. "hybrid" uses beam-style root pruning plus minimax scoring.
    search_algorithm: str = "hybrid"  # "hybrid", "beam", or "minimax"
    minimax_max_depth: int = 3  # full turn-pairs (MAX+MIN = one pair)
    minimax_determinizations: int = 3  # opponent-hand worlds for PIMC
    search_node_budget: int = 0  # 0 means unlimited; training presets use a fixed deterministic cap.
    chance_branch_limit: int = 4
    response_branch_limit: int = 0  # 0 falls back to opponent_response_actions.
    skip_effect_dry_run: bool = False


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


class ActionEnumerator:
    """Legal action generation layer for ChallengeAI."""

    def __init__(self, ai: Any):
        self.ai = ai

    def legal_actions(self, state: GameState, player_idx: int) -> list[AIAction]:
        return self.ai._legal_actions_impl(state, player_idx)


class Simulator:
    """State transition and pending-choice resolution layer for ChallengeAI."""

    def __init__(self, ai: Any):
        self.ai = ai

    def apply_action(self, state: GameState, player_idx: int, action: AIAction) -> ActionResult | None:
        return self.ai._apply_action_for_sim_impl(state, player_idx, action)

    def apply_choice(
        self,
        state: GameState,
        action_request: ActionRequest,
        choice: AIChoice | None = None,
    ) -> ActionRequest | ActionResult | None:
        return self.ai._apply_choice_impl(state, action_request, choice)


class Evaluator:
    """Tactical state evaluation layer for ChallengeAI."""

    def __init__(self, ai: Any):
        self.ai = ai

    def evaluate_state(self, state: GameState, player_idx: int) -> float:
        return self.ai._evaluate_state_impl(state, player_idx)


class ChoicePolicy:
    """Context-aware choices for searches, discards, switches, and coin flips."""

    def __init__(self, ai: Any):
        self.ai = ai

    def resolve_pending_action(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        return self.ai._resolve_pending_action_impl(state, action_request)


class ChallengeAI:
    """A tactical single-player opponent using legal actions and beam search."""

    # Fog-of-war type profiles for opponent hidden-zone card masking
    _FOW_POKEMON_BASIC = "pokemon_basic"
    _FOW_POKEMON_STAGE1 = "pokemon_stage1"
    _FOW_POKEMON_STAGE2 = "pokemon_stage2"
    _FOW_ENERGY_BASIC = "energy_basic"
    _FOW_ENERGY_SPECIAL = "energy_special"
    _FOW_TRAINER_ITEM = "trainer_item"
    _FOW_TRAINER_SUPPORTER = "trainer_supporter"
    _FOW_TRAINER_STADIUM = "trainer_stadium"
    _FOW_TRAINER_TOOL = "trainer_tool"
    _FOW_UNKNOWN = "unknown"

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
        self._forced_coin_results: list[list[bool]] = []
        self._fow_cache: dict[str, Any] = {}
        self._fow_counter: dict[str, int] = defaultdict(int)
        self.enumerator = ActionEnumerator(self)
        self.simulator = Simulator(self)
        self.evaluator = Evaluator(self)
        self.choice_policy = ChoicePolicy(self)

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

        deadline = (
            float("inf")
            if self.config.deterministic_search
            else time.perf_counter() + max(0.01, self.config.thinking_time_seconds)
        )
        if self.config.search_algorithm == "minimax":
            return self._minimax_search_action(state, player_idx, deadline)
        if self.config.search_algorithm == "hybrid":
            return self._hybrid_search_action(state, player_idx, deadline)
        return self._beam_search_action(state, player_idx, deadline)

    def _minimax_search_action(
        self, state: GameState, player_idx: int, deadline: float
    ) -> AIAction:
        from engine.ai.minimax import MinimaxSearcher

        searcher = MinimaxSearcher(self)
        return searcher.search(
            state,
            player_idx,
            deadline,
            max_depth=self.config.minimax_max_depth,
            determinizations=self.config.minimax_determinizations,
        )

    def _hybrid_search_action(
        self, state: GameState, player_idx: int, deadline: float
    ) -> AIAction:
        """Prune root moves with ChallengeAI ordering, then score them with minimax."""
        root_actions = self.legal_actions(state, player_idx)
        if not root_actions:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        candidate_limit = max(1, min(len(root_actions), int(self.config.beam_width)))
        candidates = list(root_actions[:candidate_limit])

        end_turn = next((action for action in root_actions if action.action == PlayerAction.END_TURN), None)
        if end_turn is not None and not any(action.action == PlayerAction.END_TURN for action in candidates):
            candidates.append(end_turn)

        from engine.ai.minimax import MinimaxSearcher

        searcher = MinimaxSearcher(self)
        return searcher.search(
            state,
            player_idx,
            deadline,
            max_depth=self.config.minimax_max_depth,
            determinizations=self.config.minimax_determinizations,
            root_actions=candidates,
        )

    def resolve_pending_action(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        return self.choice_policy.resolve_pending_action(state, action_request)

    def _resolve_pending_action_impl(self, state: GameState, action_request: ActionRequest) -> AIChoice:
        req = action_request
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx

        if req.request_type in ("search_deck", "select_hand_to_discard"):
            cards = list(req.card_list)
            if req.request_type == "select_hand_to_discard":
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
        return self.enumerator.legal_actions(state, player_idx)

    def _legal_actions_impl(self, state: GameState, player_idx: int) -> list[AIAction]:
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
        if not self.config.skip_effect_dry_run:
            actions = self._filter_currently_executable_actions(state, player_idx, actions)
        actions.sort(key=lambda a: self._quick_action_priority(state, player_idx, a), reverse=True)
        result = actions[: self.config.max_turn_actions]
        # END_TURN must always be available as a legal terminal action
        if not any(a.action == PlayerAction.END_TURN for a in result):
            end_turn = [a for a in actions if a.action == PlayerAction.END_TURN]
            if end_turn:
                result.append(end_turn[0])
        return result

    def _filter_currently_executable_actions(
        self, state: GameState, player_idx: int, actions: list[AIAction]
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
                    if getattr(card, "trainer_effects", None):
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
        return filtered

    def _beam_search_action(self, state: GameState, player_idx: int, deadline: float) -> AIAction:
        self._cleanup_fow_registry()
        self._fow_cache.clear()
        root_actions = self.legal_actions(state, player_idx)
        if not root_actions:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        frontier: list[tuple[float, int, GameState, AIAction]] = [
            (self.evaluate_state(state, player_idx), 0, self._masked_clone_for_eval(state, player_idx), AIAction("NOOP"))
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
                    outcomes = self._simulate_action_outcomes(node_state, player_idx, action, deadline)
                    if not outcomes:
                        continue
                    scored = [
                        (
                            self._score_simulated_outcome(sim, player_idx, action, result, deadline),
                            sim,
                            result,
                            weight,
                        )
                        for sim, result, weight in outcomes
                    ]
                    total_weight = sum(row[3] for row in scored) or 1.0
                    score = sum(row[0] * row[3] for row in scored) / total_weight
                    _, sim, result, _weight = max(scored, key=lambda row: row[0])
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

    def _simulate_action_outcomes(
        self, state: GameState, player_idx: int, action: AIAction, deadline: float | None = None
    ) -> list[tuple[GameState, ActionResult | None, float]]:
        branches = self._action_coin_branches(state, player_idx, action)
        outcomes: list[tuple[GameState, ActionResult | None, float]] = []
        for coin_results, weight in branches:
            if deadline is not None and time.perf_counter() >= deadline:
                break
            sim = self._clone_state(state)
            if coin_results is None:
                result = self._apply_action_for_sim(sim, player_idx, action)
            else:
                result = self._apply_action_for_sim_with_coin_results(
                    sim, player_idx, action, coin_results
                )
            outcomes.append((sim, result, weight))
        return outcomes

    def _score_simulated_outcome(
        self,
        sim: GameState,
        player_idx: int,
        action: AIAction,
        result: ActionResult | None,
        deadline: float | None = None,
    ) -> float:
        score = self.evaluate_state(sim, player_idx)
        if result and not result.success:
            score -= 100
        if (
            sim.winner is None
            and self.config.opponent_response_weight > 0
            and (action.terminal or sim.phase != TurnPhase.MAIN or sim.active_player_idx != player_idx)
        ):
            score += self.config.opponent_response_weight * self._opponent_response_adjustment(
                sim, player_idx, deadline
            )
        return score

    def _opponent_response_adjustment(
        self, state: GameState, player_idx: int, deadline: float | None = None
    ) -> float:
        opponent_idx = 1 - player_idx
        if state.winner is not None or state.phase == TurnPhase.GAME_OVER:
            return 0.0

        response_root = self._clone_state(state)
        if response_root.pending_promotion_player >= 0:
            self._auto_promote_for_sim(response_root)
        if response_root.phase == TurnPhase.DRAW:
            TurnManager(response_root).advance_phase()
        if response_root.active_player_idx != opponent_idx or response_root.phase not in (TurnPhase.MAIN, TurnPhase.ATTACK):
            return 0.0

        base_score = self.evaluate_state(response_root, player_idx)
        response_limit = int(self.config.response_branch_limit or self.config.opponent_response_actions)
        actions = [
            action for action in self.legal_actions(response_root, opponent_idx)
            if action.action in (
                PlayerAction.DECLARE_ATTACK,
                PlayerAction.USE_ABILITY,
                PlayerAction.RETREAT,
                PlayerAction.END_TURN,
            )
        ][: max(1, response_limit)]
        if not actions:
            return 0.0

        worst_score = base_score
        for action in actions:
            if deadline is not None and time.perf_counter() >= deadline:
                break
            sim = self._clone_state(response_root)
            result = self._apply_action_for_sim(sim, opponent_idx, action)
            score = self.evaluate_state(sim, player_idx)
            if result and not result.success:
                score += 75
            worst_score = min(worst_score, score)
        return max(-650.0, min(120.0, worst_score - base_score))

    def _action_coin_branches(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> list[tuple[list[bool] | None, float]]:
        profile = self._action_coin_profile(state, player_idx, action)
        if profile is None:
            return [(None, 1.0)]
        flip_count, until_tails = profile
        return [
            (results, weight)
            for results, weight in self._coin_outcome_branches(flip_count, until_tails)
        ]

    def _coin_outcome_branches(self, flip_count: int = 1, until_tails: bool = False) -> list[tuple[list[bool], float]]:
        """Return deterministic weighted representative coin outcomes."""
        branch_limit = max(1, int(self.config.chance_branch_limit or self.config.coin_sample_count or 1))
        if until_tails:
            max_heads = max(0, branch_limit - 1)
            branches: list[tuple[list[bool], float]] = []
            for heads in range(max_heads):
                branches.append(([True] * heads + [False], 0.5 ** (heads + 1)))
            branches.append(([True] * max_heads + [False], 0.5 ** max_heads))
            return branches

        flips = max(1, int(flip_count or 1))
        all_head_counts = list(range(flips + 1))
        head_counts = list(all_head_counts)
        if len(head_counts) > branch_limit:
            if branch_limit <= 1:
                selected = {round(flips / 2)}
            elif branch_limit == 2:
                selected = {flips // 2, flips}
            else:
                selected = {0, round(flips / 2), flips}
            for count in all_head_counts:
                if len(selected) >= branch_limit:
                    break
                selected.add(count)
            head_counts = sorted(selected)
        weights_by_heads = {heads: 0.0 for heads in head_counts}
        for heads in all_head_counts:
            weight = comb(flips, heads) * (0.5 ** flips)
            target = heads if heads in weights_by_heads else min(
                head_counts,
                key=lambda selected_heads: (abs(selected_heads - heads), selected_heads),
            )
            weights_by_heads[target] += weight
        branches = []
        for heads in head_counts:
            results = [True] * heads + [False] * (flips - heads)
            branches.append((results, weights_by_heads[heads]))
        return branches or [([False] * flips, 1.0)]

    def _action_coin_profile(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> tuple[int, bool] | None:
        effects: list[Any] = []
        if action.action == PlayerAction.DECLARE_ATTACK:
            player = state.get_player(player_idx)
            attack_idx = action.params.get("attack_idx")
            if player.active and isinstance(attack_idx, int) and 0 <= attack_idx < len(player.active.card.attacks):
                effects = player.active.card.attacks[attack_idx].effects
        elif action.action == PlayerAction.PLAY_TRAINER:
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                effects = getattr(player.hand[hand_idx], "trainer_effects", []) or []
        elif action.action == PlayerAction.USE_ABILITY:
            player = state.get_player(player_idx)
            pokemon = player.get_pokemon(action.params.get("slot") or "active")
            if pokemon:
                for ability in pokemon.card.abilities:
                    if ability.name == action.params.get("ability_name"):
                        effects = getattr(ability, "effects", []) or []
                        break
        return self._effects_coin_profile(effects)

    def _effects_coin_profile(self, effects: list[Any]) -> tuple[int, bool] | None:
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype in ("coin_flip", "coin_flip_energy_discard"):
                return (1, False)
            if etype == "coin_flip_until_tails":
                return (1, True)
            if etype == "coin_flip_triple":
                return (int(params.get("flips", 3) or 3), False)
            if etype == "coin_flip_double_ko":
                return (2, False)
            for key in ("on_heads", "on_tails", "on_success", "on_fail"):
                branch = params.get(key) or []
                if isinstance(branch, dict):
                    branch = [branch]
                nested = self._effects_coin_profile(branch)
                if nested is not None:
                    return nested
        return None

    def _action_uses_coin(self, state: GameState, player_idx: int, action: AIAction) -> bool:
        if action.action == PlayerAction.DECLARE_ATTACK:
            player = state.get_player(player_idx)
            attack_idx = action.params.get("attack_idx")
            if player.active and isinstance(attack_idx, int) and 0 <= attack_idx < len(player.active.card.attacks):
                return self._effects_use_coin(player.active.card.attacks[attack_idx].effects)
        if action.action == PlayerAction.PLAY_TRAINER:
            player = state.get_player(player_idx)
            hand_idx = action.params.get("hand_idx")
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
                return self._effects_use_coin(getattr(player.hand[hand_idx], "trainer_effects", []) or [])
        if action.action == PlayerAction.USE_ABILITY:
            player = state.get_player(player_idx)
            pokemon = player.get_pokemon(action.params.get("slot") or "active")
            if pokemon:
                for ability in pokemon.card.abilities:
                    if ability.name == action.params.get("ability_name"):
                        return self._effects_use_coin(getattr(ability, "effects", []) or [])
        return False

    def _effects_use_coin(self, effects: list[Any]) -> bool:
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if "coin" in etype:
                return True
            for key in ("on_heads", "on_tails", "on_success", "on_fail"):
                branch = params.get(key) or []
                if isinstance(branch, dict):
                    branch = [branch]
                if self._effects_use_coin(branch):
                    return True
        return False

    def _apply_action_for_sim(
        self, state: GameState, player_idx: int, action: AIAction
    ) -> ActionResult | None:
        return self.simulator.apply_action(state, player_idx, action)

    def _apply_action_for_sim_with_coin_results(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
        coin_results: list[bool],
    ) -> ActionResult | None:
        previous = self._forced_coin_results
        self._forced_coin_results = [list(coin_results)]
        try:
            return self._apply_action_for_sim(state, player_idx, action)
        finally:
            self._forced_coin_results = previous

    def _apply_action_for_sim_impl(
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
            _logger.debug("action simulation failed: %s %s -> %s", action.action, action.params, exc)
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
            if self._forced_coin_results:
                forced = list(self._forced_coin_results.pop(0))
                if getattr(req, "until_tails", False):
                    if not forced or all(forced):
                        forced.append(False)
                    first_tail = next((i for i, result in enumerate(forced) if not result), len(forced) - 1)
                    return AIChoice(coin_results=forced[: first_tail + 1])
                flips = max(1, req.flip_count)
                if len(forced) < flips:
                    forced.extend([False] * (flips - len(forced)))
                return AIChoice(coin_results=forced[:flips])
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
        prompt_l = prompt.lower()
        player = state.get_player(player_idx)
        if "switch" in prompt_l or "替换" in prompt or "交换" in prompt:
            if not player.active or not player.bench_count():
                return False
            best_bench = max(
                (p for p in player.bench if p is not None),
                key=lambda p: self._promotion_value(p),
            )
            active_value = self._promotion_value(player.active)
            if player.active.status_conditions:
                active_value -= 90
            return self._promotion_value(best_bench) > active_value + 25
        if "discard" in prompt_l or "draw" in prompt_l:
            return True
        if player.active and player.active.current_hp <= max(40, player.active.card.hp * 0.35):
            return True
        if "heal" in prompt_l:
            return any(p and p.current_hp < p.card.hp for _, p in player.get_all_pokemon())
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
            available_targets = [
                t for t in targets
                if per_target.get(t["slot"], 0) < getattr(req, "max_per_target", 99)
            ]
            if not available_targets:
                break
            best_target = max(
                available_targets,
                key=lambda t: self._energy_target_value(state, player_idx, t["slot"]) -
                per_target.get(t["slot"], 0) * 12,
            )
            slot = best_target["slot"]
            assignments.append((energy_idx, slot))
            per_target[slot] = per_target.get(slot, 0) + 1
        return assignments

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
        score += self._tempo_score(state, player_idx)
        score += sum(self._card_value(state, player_idx, c) * 0.12 for c in player.hand)
        score += self._policy_state_score(state, player_idx)
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
                pressure += self._effect_tactical_value(state, player_idx, attack.effects)
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
            for effect in attack.effects:
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
            best = max(
                best,
                attack.damage - missing * 30 + self._static_effect_value(attack.effects),
            )
        return best * 0.45

    def _estimated_attack_damage(self, state: GameState, player_idx: int, attack_idx: int) -> int:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not opponent.active:
            return 0
        if getattr(opponent.active, 'damage_prevented_next_turn', False):
            return 0
        attack = player.active.card.attacks[attack_idx]
        damage = attack.damage
        for effect in attack.effects:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype == "conditional_damage_bonus" and opponent.active.damage_counters > 0:
                damage += int(params.get("bonus", params.get("amount", 0)) or 0)
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
                    if "Psychic" in getattr(c, "provides_energy", []) or "Psychic" in getattr(c, "energy_types", [])
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
                heads = params.get("on_heads") or []
                tails = params.get("on_tails") or []
                heads_damage = self._branch_expected_damage(state, player_idx, heads)
                tails_damage = self._branch_expected_damage(state, player_idx, tails)
                damage = max(damage, int((heads_damage + tails_damage) / 2))
        return max(0, damage)

    @staticmethod
    def _effect_type(effect: Any) -> str:
        if isinstance(effect, dict):
            return str(effect.get("effect_type", ""))
        return str(getattr(effect, "effect_type", ""))

    @staticmethod
    def _effect_params(effect: Any) -> dict[str, Any]:
        if isinstance(effect, dict):
            params = effect.get("params", {})
        else:
            params = getattr(effect, "params", {})
        return params if isinstance(params, dict) else {}

    def _branch_expected_damage(self, state: GameState, player_idx: int, effects: list[Any]) -> int:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if not player.active or not opponent.active:
            return 0
        if isinstance(effects, dict):
            effects = [effects]
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

    def _effect_tactical_value(self, state: GameState, player_idx: int, effects: list[Any]) -> float:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        target_immune_effects = getattr(opponent.active, 'all_prevented_next_turn', False) if opponent.active else False
        if isinstance(effects, dict):
            effects = [effects]
        value = 0.0
        for effect in effects or []:
            etype = self._effect_type(effect)
            params = self._effect_params(effect)
            if etype in ("draw", "shuffle_draw", "discard_draw", "draw_until", "draw_until_more"):
                value += 24 + int(params.get("count", params.get("draw", 1)) or 1) * 8
            elif etype in ("search", "look_top_deck", "conditional_search_extra", "search_any_and_switch"):
                value += 42
            elif etype in ("energy_attach", "attach_from_discard", "draw_and_attach_energy"):
                value += 45
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
            elif etype in ("prevent_all", "attack_lock_basic", "self_attack_lock"):
                if target_immune_effects and etype != "self_attack_lock":
                    value += 0
                else:
                    value += 70
            elif etype in ("heal", "heal_all", "potion_heal", "damage_and_self_heal", "conditional_damage_heal"):
                damaged = sum(max(0, p.card.hp - p.current_hp) for _, p in player.get_all_pokemon() if p)
                value += min(80, damaged * 0.6)
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
        if isinstance(effects, dict):
            effects = [effects]
        value = 0.0
        for effect in effects or []:
            etype = self._effect_type(effect)
            if etype in ("draw", "search", "look_top_deck", "shuffle_draw"):
                value += 35
            elif etype in ("energy_attach", "attach_from_discard", "draw_and_attach_energy"):
                value += 42
            elif etype in ("prevent_all", "attack_lock_basic"):
                value += 60
            elif etype in ("heal", "heal_all", "potion_heal", "damage_and_self_heal", "conditional_damage_heal"):
                value += 32
            elif etype in ("energy_discard", "switch_opponent", "any_pokemon_damage"):
                value += 45
            elif "coin" in etype:
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
            for effect in getattr(card, "trainer_effects", []) or []:
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
            effects = getattr(card, "trainer_effects", []) or []
            value += self._effect_tactical_value(state, player_idx, effects) * 0.45
        if getattr(card, "api_id", "") in self.profile.core_cards:
            value += 70
        if getattr(card, "api_id", "") in self.profile.engine_cards:
            value += 42
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
        if action.action == PlayerAction.DECLARE_ATTACK:
            attack_idx = action.params["attack_idx"]
            return 500 + self._estimated_attack_damage(state, player_idx, attack_idx) + profile_bonus
        if action.action == PlayerAction.PLAY_TRAINER:
            return 360 + profile_bonus
        if action.action == PlayerAction.EVOLVE:
            return 330 + profile_bonus
        if action.action == PlayerAction.ATTACH_ENERGY:
            return 300 + profile_bonus
        if action.action == PlayerAction.USE_ABILITY:
            return 280 + profile_bonus
        if action.action == PlayerAction.PLAY_BASIC:
            return 210 + profile_bonus
        if action.action == PlayerAction.RETREAT:
            return 120 + profile_bonus
        if action.action == PlayerAction.END_TURN:
            return -50
        return 0

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
        elif card.api_id in self.profile.preferred_bench:
            value += 70
        return value

    def _ready_attack_value_for_card(self, card) -> float:
        if not getattr(card, "attacks", None):
            return 0.0
        return max(
            (atk.damage - len(atk.cost) * 15 + self._static_effect_value(atk.effects) for atk in card.attacks),
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

    def _energy_target_value(self, state: GameState, player_idx: int, slot: str) -> float:
        pokemon = state.get_player(player_idx).get_pokemon(slot)
        if pokemon is None:
            return -10**9
        best_missing = min([self._missing_energy_count(pokemon, atk.cost) for atk in pokemon.card.attacks] or [0])
        matching_bonus = self.policy_weights.get("matching_energy_attached", 0.0)
        return self._pokemon_development_value(pokemon) + max(0, 4 - best_missing) * 35 + matching_bonus

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
    # Fog-of-war masking (opponent hidden-zone scrubbing)
    # ------------------------------------------------------------------

    @staticmethod
    def _card_fow_profile(card) -> str:
        """Return the fog-of-war type profile key for a card."""
        if getattr(card, "is_pokemon", False):
            if getattr(card, "is_basic_pokemon", False):
                return ChallengeAI._FOW_POKEMON_BASIC
            if getattr(card, "is_stage1", False):
                return ChallengeAI._FOW_POKEMON_STAGE1
            if getattr(card, "is_stage2", False):
                return ChallengeAI._FOW_POKEMON_STAGE2
            return ChallengeAI._FOW_POKEMON_BASIC
        if getattr(card, "is_energy", False):
            if getattr(card, "is_basic_energy", False):
                return ChallengeAI._FOW_ENERGY_BASIC
            return ChallengeAI._FOW_ENERGY_SPECIAL
        if getattr(card, "is_trainer", False):
            if getattr(card, "is_trainer_item", False):
                return ChallengeAI._FOW_TRAINER_ITEM
            if getattr(card, "is_trainer_supporter", False):
                return ChallengeAI._FOW_TRAINER_SUPPORTER
            if getattr(card, "is_trainer_stadium", False):
                return ChallengeAI._FOW_TRAINER_STADIUM
            if getattr(card, "is_trainer_tool", False):
                return ChallengeAI._FOW_TRAINER_TOOL
            return ChallengeAI._FOW_TRAINER_ITEM
        return ChallengeAI._FOW_UNKNOWN

    def _get_fow_card(self, original_card):
        """Return a fog-of-war placeholder preserving type tags, hiding identity."""
        from data.card_models import AttackDef, Card as CardModel
        from data.card_registry import CardRegistry

        profile = self._card_fow_profile(original_card)
        idx = self._fow_counter[profile]
        self._fow_counter[profile] = idx + 1
        key = f"_fow_{profile}_{idx}"

        if key in self._fow_cache:
            self._register_fow_card(key, self._fow_cache[key])
            return self._fow_cache[key]

        subtypes = list(getattr(original_card, "subtypes", []))
        supertype = getattr(original_card, "supertype", "")

        if profile == self._FOW_POKEMON_BASIC:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes, hp=100, energy_types=["Colorless"],
                attacks=[AttackDef("???", [], 0, "")],
            )
        elif profile == self._FOW_POKEMON_STAGE1:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes, hp=110, energy_types=["Colorless"],
                evolves_from="???",
                attacks=[AttackDef("???", [], 0, "")],
            )
        elif profile == self._FOW_POKEMON_STAGE2:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes, hp=150, energy_types=["Colorless"],
                evolves_from="???",
                attacks=[AttackDef("???", [], 0, "")],
            )
        elif profile == self._FOW_ENERGY_BASIC:
            placeholder = CardModel(
                api_id=key, name="? Energy", supertype="Energy",
                subtypes=["Basic"],
            )
        elif profile == self._FOW_ENERGY_SPECIAL:
            placeholder = CardModel(
                api_id=key, name="? Energy", supertype="Energy",
                subtypes=["Special"],
            )
        elif profile == self._FOW_TRAINER_ITEM:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Item"],
            )
        elif profile == self._FOW_TRAINER_SUPPORTER:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Supporter"],
            )
        elif profile == self._FOW_TRAINER_STADIUM:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Stadium"],
            )
        elif profile == self._FOW_TRAINER_TOOL:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Tool"],
            )
        else:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes,
            )

        self._register_fow_card(key, placeholder)
        self._fow_cache[key] = placeholder
        return placeholder

    @staticmethod
    def _register_fow_card(key: str, card: Any) -> None:
        """Keep a fog-of-war placeholder resolvable by snapshot restore."""
        from data.card_registry import CardRegistry

        CardRegistry._cards[key] = card
        if card.name not in CardRegistry._by_name:
            CardRegistry._by_name[card.name] = []
        if key not in CardRegistry._by_name[card.name]:
            CardRegistry._by_name[card.name].append(key)

    @staticmethod
    def _is_opponent_masked(state: GameState, opponent_idx: int) -> bool:
        """Check if opponent hidden zones are already masked."""
        opponent = state.get_player(opponent_idx)
        if opponent.hand and getattr(opponent.hand[0], "api_id", "").startswith("_fow_"):
            return True
        if opponent.deck and getattr(opponent.deck[0], "api_id", "").startswith("_fow_"):
            return True
        return False

    def _cleanup_fow_registry(self) -> None:
        """Remove fog-of-war placeholders from the global CardRegistry."""
        from data.card_registry import CardRegistry

        for key in list(self._fow_cache):
            CardRegistry._cards.pop(key, None)
        for name, ids in list(CardRegistry._by_name.items()):
            CardRegistry._by_name[name] = [i for i in ids if not i.startswith("_fow_")]
            if not CardRegistry._by_name[name]:
                del CardRegistry._by_name[name]

    def _masked_clone_for_eval(self, state: GameState, player_idx: int) -> GameState:
        """Clone and scrub hidden information for fair beam-search evaluation.

        - Shuffles AI's own deck to remove draw-order foreknowledge
        - Replaces opponent hand/deck/prize cards with fog-of-war placeholders
        """
        # Do not remove cached placeholders here. Beam-search frontier nodes may
        # still snapshot/restore masked states containing these _fow_* ids.
        self._fow_counter.clear()

        clone = self._clone_state(state)
        self.random.shuffle(clone.get_player(player_idx).deck)

        opponent_idx = 1 - player_idx
        opponent = clone.get_player(opponent_idx)
        opponent.hand = [self._get_fow_card(c) for c in opponent.hand]
        opponent.deck = [self._get_fow_card(c) for c in opponent.deck]
        opponent.prizes = [self._get_fow_card(c) for c in opponent.prizes]

        return clone

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


def create_challenge_ai(deck_key: str, config: AIConfig | None = None) -> ChallengeAI:
    """Create a challenge AI configured for one of the built-in deck keys."""
    base = config or AIConfig()
    profile = get_deck_ai_profile(deck_key)
    return ChallengeAI(replace(base, deck_key=deck_key, profile=profile))

"""Expectiminimax with Alpha-Beta pruning for two-player Pokemon TCG.

Tree structure:
  MAX node: AI is the active player (chooses action to maximize score)
  MIN node: Opponent is the active player (chooses action to minimize AI score)
  CHANCE node: Coin flip / random draw resolution (expected value over samples)

The search alternates full turns:
  MAX (AI turn) -> MIN (Opponent turn) -> MAX -> MIN -> ...

Determinization: At the root, sample K 'worlds' by filling opponent's
hidden zones with actual cards from the known decklist. Each determinization
is searched independently, and the action with the best average score across
all determinizations is chosen.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import TYPE_CHECKING

from engine.enums import PlayerAction, TurnPhase

if TYPE_CHECKING:
    from engine.ai.challenge_ai import AIAction, ChallengeAI
    from engine.game_state import ActionResult, GameState


@dataclass(frozen=True)
class _SearchResult:
    action: AIAction | None
    score: float
    complete: bool


class MinimaxSearcher:
    """Expectiminimax + Alpha-Beta search that reuses ChallengeAI's components.

    This replaces the existing beam search with a proper two-player alternating
    tree search. It uses the same Simulator, Evaluator, and ActionEnumerator
    as ChallengeAI, so the behavioral changes are purely in how the search tree
    is structured.
    """

    def __init__(self, ai: ChallengeAI):
        self.ai = ai
        self.max_turn_depth = 0
        self.ply_depth_limit = 8
        self.node_budget = 0
        self.nodes_searched = 0
        self._depth_incomplete = False

    # ------------------------------------------------------------------
    # Public entry point
    # ------------------------------------------------------------------

    def search(
        self,
        state: GameState,
        player_idx: int,
        deadline: float,
        max_depth: int = 3,
        determinizations: int = 3,
        root_actions: list[AIAction] | None = None,
    ) -> AIAction:
        """Return the best action for *player_idx* from *state*.

        Uses iterative deepening within the time budget, with determinization
        for the opponent's hidden information.
        """
        self.ai._cleanup_fow_registry()
        self.ai._fow_cache.clear()
        root_actions = list(root_actions) if root_actions is not None else self.ai.legal_actions(state, player_idx)
        if not root_actions:
            from engine.ai.challenge_ai import AIAction
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        self.node_budget = max(0, int(getattr(self.ai.config, "search_node_budget", 0) or 0))
        self.ply_depth_limit = max(4, int(getattr(self.ai.config, "max_sequence_depth", 8) or 8))
        best_action: AIAction | None = None
        partial_action: AIAction | None = None

        # Iterative deepening: only adopt the deepest completed iteration.
        # Scores from different depths are not directly comparable.
        for depth in range(1, max_depth + 1):
            self.nodes_searched = 0
            self._depth_incomplete = False
            if self._search_stopped(deadline):
                break
            result = self._search_at_depth(
                state, player_idx, root_actions, depth, deadline, determinizations,
            )
            if result.action is not None:
                partial_action = result.action
            if not result.complete:
                break
            if result.action is not None:
                best_action = result.action

        return best_action or partial_action or root_actions[-1]

    # ------------------------------------------------------------------
    # Depth-bounded search with determinization
    # ------------------------------------------------------------------

    def _search_at_depth(
        self,
        state: GameState,
        player_idx: int,
        root_actions: list[AIAction],
        max_depth: int,
        deadline: float,
        determinizations: int,
    ) -> _SearchResult:
        """Search at a fixed depth across multiple determinizations."""
        self.max_turn_depth = max_depth
        target_dets = max(1, int(determinizations or 1))

        if target_dets <= 1:
            det_state = self._determinize(state, player_idx)
            scored = self._score_root_actions_static(
                det_state, player_idx, root_actions, deadline,
            )
            scored = self._score_root_actions(
                det_state, player_idx, root_actions, deadline, True,
                scored,
            )
        else:
            # PIMC: average over multiple determinized worlds
            accumulated: dict[int, float] = {}
            counts: dict[int, float] = {}
            completed_dets = 0
            for _ in range(target_dets):
                if self._search_stopped(deadline):
                    break
                det_state = self._determinize(state, player_idx)
                static_scored = self._score_root_actions_static(
                    det_state, player_idx, root_actions, deadline,
                )
                scored = self._score_root_actions(
                    det_state, player_idx, root_actions, deadline, False,
                    static_scored,
                )
                for idx, sc in scored.items():
                    accumulated[idx] = accumulated.get(idx, 0.0) + sc
                    counts[idx] = counts.get(idx, 0) + 1
                if self._depth_incomplete:
                    break
                completed_dets += 1

            scored = {
                idx: accumulated[idx] / max(1, counts[idx])
                for idx in accumulated
            }
            if completed_dets < target_dets:
                self._depth_incomplete = True

        if not scored:
            return _SearchResult(None, -float("inf"), False)

        best_idx = max(scored, key=lambda k: scored[k])
        best_action = root_actions[best_idx]
        complete = (
            not self._depth_incomplete
            and len(scored) == len(root_actions)
        )
        return _SearchResult(best_action, scored[best_idx], complete)

    def _score_root_actions(
        self,
        state: GameState,
        player_idx: int,
        actions: list[AIAction],
        deadline: float,
        use_root_alpha: bool,
        initial_scores: dict[int, float] | None = None,
    ) -> dict[int, float]:
        """Evaluate each root action with minimax, return {action_idx: score}."""
        scored: dict[int, float] = dict(initial_scores or {})
        alpha = -float("inf")

        # PIMC averages root scores across worlds, so multi-world searches need
        # exact candidate scores. Single-world searches can safely use root
        # alpha for speed because pruned actions cannot become the best action.
        ordered = self._order_actions_max(state, player_idx, actions)
        for orig_idx, action in ordered:
            if self._search_stopped(deadline):
                break
            child_v = self._score_child_from_action(
                state, player_idx, player_idx, action, 0, 0,
                alpha if use_root_alpha else -float("inf"), float("inf"), deadline,
            )
            scored[orig_idx] = child_v
            if use_root_alpha:
                alpha = max(alpha, child_v)

        return scored

    def _score_root_actions_static(
        self,
        state: GameState,
        player_idx: int,
        actions: list[AIAction],
        deadline: float,
    ) -> dict[int, float]:
        """Cheap one-ply score for every root action.

        This keeps incomplete budgeted searches from being dominated by action
        ordering. Deep search results overwrite these values when available.
        """
        scored: dict[int, float] = {}
        for idx, action in enumerate(actions):
            if time.perf_counter() >= deadline:
                self._depth_incomplete = True
                break
            scored[idx] = self._one_ply_action_value(state, player_idx, player_idx, action, deadline)
        return scored

    def _one_ply_action_value(
        self,
        state: GameState,
        player_idx: int,
        actor_idx: int,
        action: AIAction,
        deadline: float,
    ) -> float:
        if self._action_uses_chance(state, actor_idx, action):
            total = 0.0
            total_weight = 0.0
            for coin_results, weight in self.ai._action_coin_branches(state, actor_idx, action):
                if coin_results is None:
                    continue
                if time.perf_counter() >= deadline:
                    self._depth_incomplete = True
                    break
                total += weight * self._one_ply_forced_value(
                    state, player_idx, actor_idx, action, coin_results,
                )
                total_weight += weight
            if total_weight > 0:
                return total / total_weight

        rng_state = self.ai.random.getstate()
        forced_coin_results = [list(row) for row in self.ai._forced_coin_results]
        try:
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim(sim, actor_idx, action)
            if result is None or not result.success:
                return self._failed_action_value(state, player_idx, actor_idx)
            return self.ai.evaluate_state(sim, player_idx)
        finally:
            self.ai.random.setstate(rng_state)
            self.ai._forced_coin_results = forced_coin_results

    def _one_ply_forced_value(
        self,
        state: GameState,
        player_idx: int,
        actor_idx: int,
        action: AIAction,
        coin_results: list[bool],
    ) -> float:
        rng_state = self.ai.random.getstate()
        forced_coin_results = [list(row) for row in self.ai._forced_coin_results]
        try:
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim_with_coin_results(
                sim, actor_idx, action, coin_results,
            )
            if result is None or not result.success:
                return self._failed_action_value(state, player_idx, actor_idx)
            return self.ai.evaluate_state(sim, player_idx)
        finally:
            self.ai.random.setstate(rng_state)
            self.ai._forced_coin_results = forced_coin_results

    # ------------------------------------------------------------------
    # MAX node: AI's turn
    # ------------------------------------------------------------------

    def _max_value(
        self,
        state: GameState,
        player_idx: int,
        depth: int,
        alpha: float,
        beta: float,
        deadline: float,
        ply_depth: int = 0,
    ) -> float:
        """MAX node: AI chooses action to maximize score."""
        if ply_depth >= self.ply_depth_limit or self._is_terminal(state, depth, deadline):
            return self.ai.evaluate_state(state, player_idx)

        self._resolve_pending(state)
        actions = self.ai.legal_actions(state, player_idx)
        if not actions:
            return self.ai.evaluate_state(state, player_idx)

        ordered = self._order_actions_max(state, player_idx, actions)
        v = -float("inf")
        searched = False
        for _orig_idx, action in ordered:
            if self._search_stopped(deadline):
                break
            child_v = self._score_child_from_action(
                state, player_idx, player_idx, action, depth, ply_depth, alpha, beta, deadline,
            )
            searched = True
            v = max(v, child_v)
            alpha = max(alpha, v)
            if alpha >= beta:
                break

        return v if searched else self.ai.evaluate_state(state, player_idx)

    # ------------------------------------------------------------------
    # MIN node: opponent's turn
    # ------------------------------------------------------------------

    def _min_value(
        self,
        state: GameState,
        player_idx: int,
        depth: int,
        alpha: float,
        beta: float,
        deadline: float,
        ply_depth: int = 0,
    ) -> float:
        """MIN node: opponent chooses action to minimize AI's score.

        After the opponent's turn ends, depth increases by 1 (a full turn pair
        has completed: MAX + MIN).
        """
        if ply_depth >= self.ply_depth_limit or self._is_terminal(state, depth, deadline):
            return self.ai.evaluate_state(state, player_idx)

        opponent_idx = 1 - player_idx
        self._resolve_pending(state)
        actions = self.ai.legal_actions(state, opponent_idx)
        if not actions:
            return self.ai.evaluate_state(state, player_idx)

        ordered = self._order_actions_min(state, opponent_idx, actions)
        v = float("inf")
        searched = False
        for _orig_idx, action in ordered:
            if self._search_stopped(deadline):
                break
            child_v = self._score_child_from_action(
                state, player_idx, opponent_idx, action, depth, ply_depth, alpha, beta, deadline,
            )
            searched = True
            v = min(v, child_v)
            beta = min(beta, v)
            if alpha >= beta:
                break

        return v if searched else self.ai.evaluate_state(state, player_idx)

    # ------------------------------------------------------------------
    # CHANCE node: coin flips / random elements
    # ------------------------------------------------------------------

    def _chance_value(
        self,
        state: GameState,
        player_idx: int,
        actor_idx: int,
        action: AIAction,
        depth: int,
        ply_depth: int,
        alpha: float,
        beta: float,
        deadline: float,
    ) -> float:
        """CHANCE node: expected value over deterministic weighted coin branches."""
        total = 0.0
        total_weight = 0.0
        branches = [
            (results, weight)
            for results, weight in self.ai._action_coin_branches(state, actor_idx, action)
            if results is not None
        ]
        for coin_results, weight in branches:
            if self._search_stopped(deadline):
                break
            if not self._consume_node(deadline):
                break
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim_with_coin_results(
                sim, actor_idx, action, coin_results
            )
            if result is None or not result.success:
                value = self._failed_action_value(state, player_idx, actor_idx)
            else:
                value = self._value_after_action(
                    sim, player_idx, actor_idx, depth, ply_depth + 1, alpha, beta, deadline,
                )
            total += weight * value
            total_weight += weight

        if total_weight <= 0:
            return self.ai.evaluate_state(state, player_idx)
        return total / total_weight

    def _score_child_from_action(
        self,
        state: GameState,
        player_idx: int,
        actor_idx: int,
        action: AIAction,
        depth: int,
        ply_depth: int,
        alpha: float,
        beta: float,
        deadline: float,
    ) -> float:
        if self._action_uses_chance(state, actor_idx, action):
            return self._chance_value(state, player_idx, actor_idx, action, depth, ply_depth, alpha, beta, deadline)
        if not self._consume_node(deadline):
            return self.ai.evaluate_state(state, player_idx)
        sim = self.ai._clone_state(state)
        result = self.ai._apply_action_for_sim(sim, actor_idx, action)
        if result is None or not result.success:
            return self._failed_action_value(state, player_idx, actor_idx)
        return self._value_after_action(sim, player_idx, actor_idx, depth, ply_depth + 1, alpha, beta, deadline)

    def _failed_action_value(self, state: GameState, player_idx: int, actor_idx: int) -> float:
        """Score a simulated illegal/failed action without continuing the branch."""
        base = self.ai.evaluate_state(state, player_idx)
        penalty = 5000.0
        return base - penalty if actor_idx == player_idx else base + penalty

    def _value_after_action(
        self,
        state: GameState,
        player_idx: int,
        actor_idx: int,
        depth: int,
        ply_depth: int,
        alpha: float,
        beta: float,
        deadline: float,
    ) -> float:
        if ply_depth >= self.ply_depth_limit or self._is_terminal(state, depth, deadline):
            return self.ai.evaluate_state(state, player_idx)
        if state.active_player_idx == actor_idx:
            if actor_idx == player_idx:
                return self._max_value(state, player_idx, depth, alpha, beta, deadline, ply_depth)
            return self._min_value(state, player_idx, depth, alpha, beta, deadline, ply_depth)
        if actor_idx == player_idx:
            return self._min_value(state, player_idx, depth, alpha, beta, deadline, 0)
        return self._max_value(state, player_idx, depth + 1, alpha, beta, deadline, 0)

    # ------------------------------------------------------------------
    # Action ordering (for better pruning)
    # ------------------------------------------------------------------

    def _order_actions_max(
        self, state: GameState, player_idx: int, actions: list[AIAction],
    ) -> list[tuple[int, AIAction]]:
        """Order actions descending by heuristic score (best first → earlier beta cutoffs)."""
        scored = [
            (self.ai._quick_action_priority(state, player_idx, action), idx, action)
            for idx, action in enumerate(actions)
        ]
        scored.sort(key=lambda x: x[0], reverse=True)
        return [(idx, action) for _, idx, action in scored]

    def _order_actions_min(
        self, state: GameState, opponent_idx: int, actions: list[AIAction],
    ) -> list[tuple[int, AIAction]]:
        """Order opponent actions strongest-first for useful cutoffs under budget."""
        scored = [
            (self.ai._quick_action_priority(state, opponent_idx, action), idx, action)
            for idx, action in enumerate(actions)
        ]
        scored.sort(key=lambda x: x[0], reverse=True)
        return [(idx, action) for _, idx, action in scored]

    # ------------------------------------------------------------------
    # Terminal / depth check
    # ------------------------------------------------------------------

    def _is_terminal(self, state: GameState, depth: int, deadline: float) -> bool:
        if state.winner is not None:
            return True
        if state.phase == TurnPhase.GAME_OVER:
            return True
        if depth >= self.max_turn_depth:
            return True
        if self._search_stopped(deadline):
            return True
        return False

    def _search_stopped(self, deadline: float) -> bool:
        stopped = (
            time.perf_counter() >= deadline
            or (self.node_budget > 0 and self.nodes_searched >= self.node_budget)
        )
        if stopped:
            self._depth_incomplete = True
        return stopped

    def _consume_node(self, deadline: float) -> bool:
        if self._search_stopped(deadline):
            return False
        self.nodes_searched += 1
        return True

    # ------------------------------------------------------------------
    # Pending resolution
    # ------------------------------------------------------------------

    def _resolve_pending(self, state: GameState) -> None:
        """Resolve pending promotions before enumerating actions."""
        if state.pending_promotion_player >= 0:
            self.ai._auto_promote_for_sim(state)
        if state.phase == TurnPhase.DRAW:
            try:
                from engine.turn_manager import TurnManager
                TurnManager(state).advance_phase()
            except Exception:
                pass

    # ------------------------------------------------------------------
    # Chance detection
    # ------------------------------------------------------------------

    def _action_uses_chance(self, state: GameState, player_idx: int, action: AIAction) -> bool:
        """Check if an action involves random elements (coin flips)."""
        return self.ai._action_uses_coin(state, player_idx, action)

    # ------------------------------------------------------------------
    # Determinization (PIMC for hidden information)
    # ------------------------------------------------------------------

    def _determinize(self, state: GameState, player_idx: int) -> GameState:
        """Create a determinized world for the opponent's hidden information.

        Currently uses fog-of-war masking (type-preserving placeholders for
        hidden cards). This provides reasonable opponent simulation without
        needing the opponent's exact decklist.

        Future enhancement: when deck_key is known, sample actual cards from
        the opponent's decklist for more accurate simulation.
        """
        return self.ai._masked_clone_for_eval(state, player_idx)

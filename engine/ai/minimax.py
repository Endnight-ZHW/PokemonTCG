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

import random
import time
from typing import Any, TYPE_CHECKING

from engine.enums import PlayerAction, TurnPhase

if TYPE_CHECKING:
    from engine.ai.challenge_ai import AIAction, ChallengeAI
    from engine.game_state import ActionResult, GameState


class MinimaxSearcher:
    """Expectiminimax + Alpha-Beta search that reuses ChallengeAI's components.

    This replaces the existing beam search with a proper two-player alternating
    tree search. It uses the same Simulator, Evaluator, and ActionEnumerator
    as ChallengeAI, so the behavioral changes are purely in how the search tree
    is structured.
    """

    def __init__(self, ai: ChallengeAI):
        self.ai = ai

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
        root_actions = list(root_actions) if root_actions is not None else self.ai.legal_actions(state, player_idx)
        if not root_actions:
            from engine.ai.challenge_ai import AIAction
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        best_action = root_actions[-1]
        best_score = -float("inf")

        # Iterative deepening: try depth 1, 2, ... up to max_depth
        for depth in range(1, max_depth + 1):
            if time.perf_counter() >= deadline:
                break
            action, score = self._search_at_depth(
                state, player_idx, root_actions, depth, deadline, determinizations,
            )
            if action is not None and score > best_score:
                best_score = score
                best_action = action

        return best_action

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
    ) -> tuple[AIAction | None, float]:
        """Search at a fixed depth across multiple determinizations."""
        self.max_turn_depth = max_depth

        if determinizations <= 1:
            scored = self._score_root_actions(
                state, player_idx, root_actions, deadline, None,
            )
        else:
            # PIMC: average over multiple determinized worlds
            accumulated: dict[int, float] = {}
            counts: dict[int, float] = {}
            for _ in range(determinizations):
                if time.perf_counter() >= deadline:
                    break
                det_state = self._determinize(state, player_idx)
                scored = self._score_root_actions(
                    det_state, player_idx, root_actions, deadline, None,
                )
                for idx, sc in scored.items():
                    accumulated[idx] = accumulated.get(idx, 0.0) + sc
                    counts[idx] = counts.get(idx, 0) + 1

            scored = {
                idx: accumulated[idx] / max(1, counts[idx])
                for idx in accumulated
            }

        if not scored:
            return None, -float("inf")

        best_idx = max(scored, key=lambda k: scored[k])
        best_action = root_actions[best_idx]
        return best_action, scored[best_idx]

    def _score_root_actions(
        self,
        state: GameState,
        player_idx: int,
        actions: list[AIAction],
        deadline: float,
        _unused,
    ) -> dict[int, float]:
        """Evaluate each root action with minimax, return {action_idx: score}."""
        alpha = -float("inf")
        beta = float("inf")
        scored: dict[int, float] = {}

        # Order actions for better pruning (higher priority first for MAX)
        ordered = self._order_actions_max(state, player_idx, actions)
        for orig_idx, action in ordered:
            if time.perf_counter() >= deadline:
                break
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim(sim, player_idx, action)

            if self._is_terminal(sim, 0, deadline):
                child_v = self.ai.evaluate_state(sim, player_idx)
            elif self._action_uses_chance(state, player_idx, action):
                child_v = self._chance_value(sim, player_idx, action, 0, alpha, beta, deadline)
            elif sim.active_player_idx == player_idx:
                child_v = self._max_value(sim, player_idx, 0, alpha, beta, deadline)
            else:
                child_v = self._min_value(sim, player_idx, 0, alpha, beta, deadline)

            scored[orig_idx] = child_v
            alpha = max(alpha, child_v)

        return scored

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
    ) -> float:
        """MAX node: AI chooses action to maximize score."""
        if self._is_terminal(state, depth, deadline):
            return self.ai.evaluate_state(state, player_idx)

        self._resolve_pending(state)
        actions = self.ai.legal_actions(state, player_idx)
        if not actions:
            return self.ai.evaluate_state(state, player_idx)

        ordered = self._order_actions_max(state, player_idx, actions)
        v = -float("inf")
        for _orig_idx, action in ordered:
            if time.perf_counter() >= deadline:
                break
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim(sim, player_idx, action)

            if self._is_terminal(sim, depth, deadline):
                child_v = self.ai.evaluate_state(sim, player_idx)
            elif self._action_uses_chance(state, player_idx, action):
                child_v = self._chance_value(sim, player_idx, action, depth, alpha, beta, deadline)
            elif sim.active_player_idx == player_idx:
                child_v = self._max_value(sim, player_idx, depth, alpha, beta, deadline)
            else:
                child_v = self._min_value(sim, player_idx, depth, alpha, beta, deadline)

            v = max(v, child_v)
            alpha = max(alpha, v)
            if alpha >= beta:
                break

        return v

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
    ) -> float:
        """MIN node: opponent chooses action to minimize AI's score.

        After the opponent's turn ends, depth increases by 1 (a full turn pair
        has completed: MAX + MIN).
        """
        if self._is_terminal(state, depth, deadline):
            return self.ai.evaluate_state(state, player_idx)

        opponent_idx = 1 - player_idx
        self._resolve_pending(state)
        actions = self.ai.legal_actions(state, opponent_idx)
        if not actions:
            return self.ai.evaluate_state(state, player_idx)

        ordered = self._order_actions_min(state, opponent_idx, actions)
        v = float("inf")
        for _orig_idx, action in ordered:
            if time.perf_counter() >= deadline:
                break
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim(sim, opponent_idx, action)

            if self._is_terminal(sim, depth, deadline):
                child_v = self.ai.evaluate_state(sim, player_idx)
            elif self._action_uses_chance(state, opponent_idx, action):
                child_v = self._chance_value(sim, player_idx, action, depth, alpha, beta, deadline)
            elif sim.active_player_idx == opponent_idx:
                child_v = self._min_value(sim, player_idx, depth, alpha, beta, deadline)
            else:
                # Opponent's turn ended → AI's turn → depth increases
                child_v = self._max_value(sim, player_idx, depth + 1, alpha, beta, deadline)

            v = min(v, child_v)
            beta = min(beta, v)
            if alpha >= beta:
                break

        return v

    # ------------------------------------------------------------------
    # CHANCE node: coin flips / random elements
    # ------------------------------------------------------------------

    def _chance_value(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
        depth: int,
        alpha: float,
        beta: float,
        deadline: float,
    ) -> float:
        """CHANCE node: expected value over coin-flip samples."""
        samples = max(1, min(6, int(getattr(self.ai.config, 'coin_sample_count', 8) // 2)))
        actor_idx = state.active_player_idx

        total = 0.0
        actual_samples = 0
        for _ in range(samples):
            if time.perf_counter() >= deadline:
                break
            sim = self.ai._clone_state(state)
            result = self.ai._apply_action_for_sim(sim, actor_idx, action)
            actual_samples += 1

            if self._is_terminal(sim, depth, deadline):
                total += self.ai.evaluate_state(sim, player_idx)
            elif sim.active_player_idx == actor_idx:
                total += self._max_value(sim, player_idx, depth, alpha, beta, deadline)
            else:
                total += self._min_value(sim, player_idx, depth, alpha, beta, deadline)

        return total / max(1, actual_samples)

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
        """Order actions ascending by heuristic score (worst-for-us first → earlier alpha cutoffs)."""
        scored = [
            (self.ai._quick_action_priority(state, opponent_idx, action), idx, action)
            for idx, action in enumerate(actions)
        ]
        scored.sort(key=lambda x: x[0])  # ascending: worst for AI first
        return [(idx, action) for _, idx, action in scored]

    # ------------------------------------------------------------------
    # Terminal / depth check
    # ------------------------------------------------------------------

    def _is_terminal(self, state: GameState, depth: int, deadline: float) -> bool:
        if time.perf_counter() >= deadline:
            return True
        if state.winner is not None:
            return True
        if state.phase == TurnPhase.GAME_OVER:
            return True
        if depth >= self.max_turn_depth:
            return True
        return False

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

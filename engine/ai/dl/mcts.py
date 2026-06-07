"""Monte Carlo Tree Search guided by the neural network.

AlphaZero-style MCTS with:
- PUCT action selection using model's policy/value heads
- Chance nodes for modeling draw randomness (card draw during turn start)
- State snapshotting for efficient tree search

The MCTS reuses ChallengeAI's ActionEnumerator for legal-action generation
and the encoder + model for leaf evaluation.
"""
from __future__ import annotations

import math
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, TYPE_CHECKING

from engine.enums import PlayerAction, TurnPhase
from engine.snapshot import restore_state, snapshot_state

if TYPE_CHECKING:
    from engine.ai.challenge_ai import AIAction, ChallengeAI
    from engine.ai.dl.encoder import ActionStateEncoder, EncodedAction, EncodedState
    from engine.game_state import GameState

# PyTorch may not be available in the main game runtime
try:
    import torch
    TORCH_AVAILABLE = True
except Exception:
    torch = None
    TORCH_AVAILABLE = False


@dataclass
class _MCTSNode:
    """A node in the MCTS search tree."""

    # Action that led to this node (None for root)
    action: AIAction | None = None

    # Children: action -> child node
    children: dict[int, _MCTSNode] = field(default_factory=dict)

    # Statistics
    visit_count: int = 0
    total_value: float = 0.0
    prior_prob: float = 0.0

    # Virtual loss for parallel MCTS (future use)
    virtual_loss: int = 0

    # State snapshot (lazy — only captured when expanded)
    state_snapshot: Any | None = None

    # Whether this is a chance node (models draw randomness)
    is_chance: bool = False
    # For chance nodes: list of (child_node, probability_weight)
    chance_branches: list[tuple[_MCTSNode, float]] = field(default_factory=list)

    @property
    def q_value(self) -> float:
        """Mean action value Q(s,a)."""
        if self.visit_count == 0:
            return 0.0
        return self.total_value / self.visit_count

    @property
    def effective_visits(self) -> int:
        """Visits adjusted for virtual loss."""
        return self.visit_count + self.virtual_loss

    def puct_score(self, parent_visits: int, c_puct: float) -> float:
        """PUCT score: Q + c_puct * P * sqrt(N_parent) / (1 + n)."""
        if parent_visits <= 0:
            return self.prior_prob
        exploration = c_puct * self.prior_prob * math.sqrt(parent_visits) / (1.0 + self.effective_visits)
        return self.q_value + exploration


@dataclass
class _MCTSSearchResult:
    """Result of an MCTS search at the root."""
    action_probs: dict[int, float]  # action_index -> probability (visit count distribution)
    root_value: float               # mean value of the root state
    best_action_idx: int            # action with the highest visit count


class MCTSGuidedSearch:
    """AlphaZero-style MCTS guided by a neural network.

    Usage:
        searcher = MCTSGuidedSearch(model, encoder, legal_ai, num_simulations=200)
        action_probs, root_value = searcher.search(state, player_idx, deck_key)
        # action_probs[action_idx] = visit_count / total_visits
    """

    def __init__(
        self,
        model: Any,
        encoder: ActionStateEncoder,
        legal_ai: ChallengeAI,
        *,
        num_simulations: int = 200,
        c_puct: float = 1.4,
        temperature: float = 1.0,
        use_chance_nodes: bool = True,
        chance_branch_limit: int = 4,
        device: str = "cpu",
        dirichlet_alpha: float = 0.3,
        dirichlet_epsilon: float = 0.25,
        add_dirichlet_noise: bool = True,
    ):
        self.model = model
        self.encoder = encoder
        self.legal_ai = legal_ai
        self.num_simulations = max(1, int(num_simulations))
        self.c_puct = float(c_puct)
        self.temperature = max(0.05, float(temperature))
        self.use_chance_nodes = bool(use_chance_nodes)
        self.chance_branch_limit = max(2, min(8, int(chance_branch_limit)))
        self.device = device
        self.dirichlet_alpha = float(dirichlet_alpha)
        self.dirichlet_epsilon = float(dirichlet_epsilon)
        self.add_dirichlet_noise = bool(add_dirichlet_noise)

        # Encode cache to avoid re-encoding the same state
        self._encode_cache: dict[int, tuple] = {}

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def search(
        self,
        state: GameState,
        player_idx: int,
        deck_key: str | None = None,
        *,
        deadline: float | None = None,
        actions: list[AIAction] | None = None,
    ) -> _MCTSSearchResult:
        """Run MCTS from the given state and return action probabilities + root value.

        Args:
            state: Current game state (will be snapshotted, not mutated).
            player_idx: Index of the player to act (0 or 1).
            deck_key: Deck identifier for encoder context.
            deadline: Optional time deadline (seconds since epoch).
            actions: Pre-computed legal actions (avoids re-enumeration).

        Returns:
            _MCTSSearchResult with action_probs, root_value, and best_action_idx.
        """
        self._encode_cache.clear()
        root_snap = snapshot_state(state)

        if actions is None:
            actions = self.legal_ai.legal_actions(state, player_idx)
        if not actions:
            return _MCTSSearchResult({}, 0.0, -1)

        root = _MCTSNode()
        root.state_snapshot = root_snap

        # Evaluate root state for prior probabilities
        with torch.no_grad():
            encoded_state = self.encoder.encode_state(state, player_idx, deck_key)
            encoded_actions = [self.encoder.encode_action(state, player_idx, a) for a in actions]
            priors, root_value = self._evaluate_state_actions(
                encoded_state, encoded_actions,
            )

        # Apply Dirichlet noise to root priors for exploration
        if self.add_dirichlet_noise:
            noise = self._dirichlet_noise(len(actions))
            for i in range(len(actions)):
                priors[i] = (
                    (1.0 - self.dirichlet_epsilon) * priors[i]
                    + self.dirichlet_epsilon * noise[i]
                )

        # Expand root: create child nodes
        for i, action in enumerate(actions):
            child = _MCTSNode(action=action, prior_prob=priors[i])
            root.children[i] = child

        # Run simulations
        for _ in range(self.num_simulations):
            if deadline is not None and time.perf_counter() >= deadline:
                break
            # Restore state to root for each simulation
            sim_state = self._clone_from_snapshot(root_snap, state)
            self._simulate(sim_state, player_idx, deck_key, root)

        # Compute action probabilities from visit counts
        total_visits = sum(child.visit_count for child in root.children.values())
        if total_visits <= 0:
            total_visits = 1
        action_probs = {
            idx: child.visit_count / total_visits
            for idx, child in root.children.items()
        }
        best_idx = max(root.children.keys(), key=lambda k: root.children[k].visit_count)

        return _MCTSSearchResult(
            action_probs=action_probs,
            root_value=root_value,
            best_action_idx=best_idx,
        )

    def select_action(
        self,
        state: GameState,
        player_idx: int,
        deck_key: str | None = None,
        *,
        actions: list[AIAction] | None = None,
        deterministic: bool = True,
    ) -> AIAction:
        """Convenience: run MCTS and return the chosen action.

        Args:
            deterministic: If True, return the most-visited action.
                          If False, sample from the visit distribution.
        """
        if actions is None:
            actions = self.legal_ai.legal_actions(state, player_idx)
        if not actions:
            from engine.ai.challenge_ai import AIAction
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)

        result = self.search(state, player_idx, deck_key, actions=actions)

        if deterministic:
            idx = result.best_action_idx
            if 0 <= idx < len(actions):
                return actions[idx]
            return actions[-1]

        # Stochastic selection based on visit proportions
        import random
        total = sum(result.action_probs.values())
        if total <= 0:
            return actions[-1]
        r = random.random() * total
        cumulative = 0.0
        for idx in sorted(result.action_probs.keys()):
            cumulative += result.action_probs[idx]
            if r <= cumulative:
                if 0 <= idx < len(actions):
                    return actions[idx]
                break
        return actions[-1]

    # ------------------------------------------------------------------
    # Simulation
    # ------------------------------------------------------------------

    def _simulate(
        self,
        state: GameState,
        player_idx: int,
        deck_key: str | None,
        node: _MCTSNode,
    ) -> float:
        """Run one MCTS simulation: select → expand → evaluate → backup."""
        # Selection: traverse tree to a leaf
        leaf, leaf_state, leaf_player, path = self._select(state, player_idx, node)

        # Expansion + Evaluation
        if leaf_state.winner is not None or leaf_state.phase == TurnPhase.GAME_OVER:
            value = self._terminal_value(leaf_state, player_idx)
        else:
            value = self._expand_and_evaluate(leaf_state, leaf_player, deck_key, leaf, path)

        # Backup
        self._backup(path, value, player_idx)
        return value

    def _select(
        self,
        state: GameState,
        player_idx: int,
        root: _MCTSNode,
    ) -> tuple[_MCTSNode, GameState, int, list[tuple[_MCTSNode, int]]]:
        """Select a leaf node by traversing the tree with PUCT.

        Returns (leaf_node, leaf_state, leaf_player_idx, path).
        Path is list of (node, player_idx_for_that_node) for backup.
        """
        node = root
        current_state = state
        current_player = player_idx
        path: list[tuple[_MCTSNode, int]] = [(root, player_idx)]

        while True:
            # Check terminal
            if current_state.winner is not None or current_state.phase == TurnPhase.GAME_OVER:
                return node, current_state, current_player, path

            # If no children, this is a leaf
            if not node.children and not node.chance_branches:
                return node, current_state, current_player, path

            # Handle chance nodes
            if node.is_chance and node.chance_branches:
                # Select chance branch (weighted random or UCB-style)
                selected_branch = self._select_chance_branch(node, current_state, current_player)
                if selected_branch is None:
                    return node, current_state, current_player, path
                child_node, _weight = selected_branch
                # Apply the chance outcome to get next state
                next_state = self._apply_chance_outcome(current_state, child_node)
                path.append((child_node, current_player))
                node = child_node
                current_state = next_state
                continue

            # Select child with highest PUCT score
            if not node.children:
                return node, current_state, current_player, path

            parent_visits = sum(c.effective_visits for c in node.children.values())
            best_idx = max(
                node.children.keys(),
                key=lambda k: node.children[k].puct_score(parent_visits, self.c_puct),
            )
            child = node.children[best_idx]
            action = child.action
            if action is None:
                return node, current_state, current_player, path

            # Apply action to advance state
            next_state = self._apply_action_clone(current_state, current_player, action)
            if next_state is None:
                # Action failed — treat as terminal with negative value
                return node, current_state, current_player, path

            # Determine next player
            next_player = next_state.active_player_idx if next_state.phase == TurnPhase.MAIN else current_player

            path.append((child, current_player))
            node = child
            current_state = next_state
            current_player = next_player

    def _select_chance_branch(
        self,
        node: _MCTSNode,
        state: GameState,
        player_idx: int,
    ) -> tuple[_MCTSNode, float] | None:
        """Select a chance branch using UCB1-style selection over weighted branches."""
        if not node.chance_branches:
            return None
        total_visits = sum(n.visit_count for n, _ in node.chance_branches) + 1
        best_score = -float("inf")
        best_branch = None
        for child, weight in node.chance_branches:
            q = child.q_value if child.visit_count > 0 else 0.0
            ucb = q + 2.0 * weight * math.sqrt(total_visits) / (1.0 + child.visit_count)
            if ucb > best_score:
                best_score = ucb
                best_branch = (child, weight)
        return best_branch

    def _expand_and_evaluate(
        self,
        state: GameState,
        player_idx: int,
        deck_key: str | None,
        node: _MCTSNode,
        path: list[tuple[_MCTSNode, int]],
    ) -> float:
        """Expand a leaf node and return its evaluated value."""
        if state.pending_promotion_player >= 0:
            self.legal_ai._auto_promote_for_sim(state)
        if state.phase == TurnPhase.DRAW:
            from engine.turn_manager import TurnManager
            TurnManager(state).advance_phase()

        actions = self.legal_ai.legal_actions(state, player_idx)
        if not actions:
            return self._evaluate_terminal_heuristic(state, player_idx)

        # Encode and evaluate
        encoded_state = self.encoder.encode_state(state, player_idx, deck_key)
        encoded_actions = [self.encoder.encode_action(state, player_idx, a) for a in actions]

        with torch.no_grad():
            priors, value = self._evaluate_state_actions(encoded_state, encoded_actions)

        # Create children
        for i, action in enumerate(actions):
            child = _MCTSNode(action=action, prior_prob=priors[i])
            node.children[i] = child

        # If chance nodes enabled, insert chance nodes after draw-triggering actions
        if self.use_chance_nodes:
            self._maybe_add_chance_children(state, player_idx, deck_key, node, encoded_state)

        return value

    def _maybe_add_chance_children(
        self,
        state: GameState,
        player_idx: int,
        deck_key: str | None,
        node: _MCTSNode,
        encoded_state: EncodedState,
    ) -> None:
        """Insert chance nodes after the END_TURN action to model next-turn draw.

        This models the randomness of what card will be drawn at the start of
        the next turn, making the MCTS robust to draw variance.
        """
        # Only add chance nodes for END_TURN and DECLARE_ATTACK (terminal) actions
        for idx, child in list(node.children.items()):
            action = child.action
            if action is None:
                continue
            action_name = action.action.name if isinstance(action.action, PlayerAction) else str(action.action)
            if action_name not in (PlayerAction.END_TURN.name,):
                continue

            # Get draw probability distribution for next turn
            draw_branches = self._estimate_draw_distribution(state, player_idx)
            if len(draw_branches) <= 1:
                continue  # No randomness to model

            # Create chance branches
            for card_category, probability in draw_branches:
                chance_child = _MCTSNode(
                    action=None,
                    prior_prob=child.prior_prob * probability,
                    is_chance=False,
                )
                # Store metadata for state transition
                chance_child._chance_info = {
                    "type": "draw",
                    "category": card_category,
                    "probability": probability,
                }

            # Move children of END_TURN under a chance wrapper
            wrapper = _MCTSNode(action=action, prior_prob=child.prior_prob, is_chance=True)
            for card_cat, prob in draw_branches:
                sub = _MCTSNode(
                    action=None,
                    prior_prob=child.prior_prob * prob,
                )
                sub._chance_info = {"type": "draw", "category": card_cat, "probability": prob}
                wrapper.chance_branches.append((sub, prob))

            # Replace the original child with the chance wrapper
            if wrapper.chance_branches:
                node.children[idx] = wrapper

    def _estimate_draw_distribution(
        self,
        state: GameState,
        player_idx: int,
    ) -> list[tuple[str, float]]:
        """Estimate the probability distribution of next-turn draw.

        Returns list of (category_label, probability) tuples.
        Categories: pokemon, trainer_item, trainer_supporter, energy, other.
        """
        player = state.get_player(player_idx)
        deck = player.deck
        if not deck:
            return [("empty", 1.0)]

        total = len(deck)
        counts: dict[str, int] = defaultdict(int)
        for card in deck:
            if getattr(card, "is_basic_pokemon", False) or getattr(card, "is_stage1", False) or getattr(card, "is_stage2", False):
                counts["pokemon"] += 1
            elif getattr(card, "is_trainer_item", False):
                counts["trainer_item"] += 1
            elif getattr(card, "is_trainer_supporter", False):
                counts["trainer_supporter"] += 1
            elif getattr(card, "is_trainer_stadium", False) or getattr(card, "is_trainer_tool", False):
                counts["trainer_other"] += 1
            elif getattr(card, "is_energy", False):
                counts["energy"] += 1
            else:
                counts["other"] += 1

        # Sort by probability, merge tail
        branches = sorted(
            [(cat, count / total) for cat, count in counts.items() if count > 0],
            key=lambda x: x[1],
            reverse=True,
        )
        if len(branches) > self.chance_branch_limit:
            # Merge smallest branches into "other"
            kept = branches[: self.chance_branch_limit - 1]
            merged_prob = sum(p for _, p in branches[self.chance_branch_limit - 1:])
            if merged_prob > 0:
                kept.append(("other_merged", merged_prob))
            branches = kept

        return branches

    def _apply_chance_outcome(
        self,
        state: GameState,
        child_node: _MCTSNode,
    ) -> GameState:
        """Apply a chance outcome (e.g., draw a specific card type) to advance state."""
        # For draw chance nodes, actually perform the draw
        chance_info = getattr(child_node, "_chance_info", {})
        if chance_info.get("type") == "draw":
            category = chance_info.get("category", "")
            # Advance phase to trigger draw
            if state.phase == TurnPhase.MAIN:
                from engine.turn_manager import TurnManager
                try:
                    TurnManager(state).advance_phase()
                except Exception:
                    pass
        return state

    # ------------------------------------------------------------------
    # Backup
    # ------------------------------------------------------------------

    def _backup(
        self,
        path: list[tuple[_MCTSNode, int]],
        value: float,
        root_player: int,
    ) -> None:
        """Backup the evaluated value through the search path."""
        for node, node_player in reversed(path):
            node.visit_count += 1
            # Value is always from root_player's perspective
            if node_player == root_player:
                node.total_value += value
            else:
                node.total_value += (-value)

    # ------------------------------------------------------------------
    # Model evaluation
    # ------------------------------------------------------------------

    def _evaluate_state_actions(
        self,
        encoded_state: EncodedState,
        encoded_actions: list[EncodedAction],
    ) -> tuple[list[float], float]:
        """Use the model to get action priors and state value.

        Returns (list of prior probabilities per action, scalar value).
        """
        if not TORCH_AVAILABLE or self.model is None:
            # Fallback: uniform priors, neutral value
            n = len(encoded_actions)
            return ([1.0 / max(1, n)] * n, 0.0)

        state_numeric_size = int(getattr(self.model, "state_numeric_size", len(encoded_state.numeric)))
        state_card_slots = int(getattr(self.model, "state_card_slots", len(encoded_state.card_ids)))
        action_numeric_size = int(getattr(self.model, "action_numeric_size", len(encoded_actions[0].numeric)))

        state_numeric = torch.tensor(
            [_fit_sequence(encoded_state.numeric, state_numeric_size, 0.0)],
            dtype=torch.float32,
            device=self.device,
        )
        state_cards = torch.tensor(
            [_fit_sequence(encoded_state.card_ids, state_card_slots, 0)],
            dtype=torch.long,
            device=self.device,
        )
        action_numeric = torch.tensor(
            [[_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in encoded_actions]],
            dtype=torch.float32,
            device=self.device,
        )
        action_cards = torch.tensor(
            [[a.card_id for a in encoded_actions]],
            dtype=torch.long,
            device=self.device,
        )

        logits, value = self.model(state_numeric, state_cards, action_numeric, action_cards)
        probs = torch.softmax(logits[0] / self.temperature, dim=0).detach().cpu().tolist()
        scalar_value = float(value[0].detach().cpu().item())

        return probs, scalar_value

    # ------------------------------------------------------------------
    # State manipulation helpers
    # ------------------------------------------------------------------

    def _clone_from_snapshot(self, snap: Any, template_state: GameState) -> GameState:
        """Create a fresh GameState copy from a snapshot."""
        from engine.game_state import GameState

        new_state = GameState()
        restore_state(new_state, snap)
        return new_state

    def _apply_action_clone(
        self,
        state: GameState,
        player_idx: int,
        action: AIAction,
    ) -> GameState | None:
        """Apply an action via the ChallengeAI simulator. Returns None on failure."""
        try:
            result = self.legal_ai._apply_action_for_sim(state, player_idx, action)
            if result is None or not result.success:
                return None
            return state
        except Exception:
            return None

    # ------------------------------------------------------------------
    # Terminal evaluation
    # ------------------------------------------------------------------

    def _terminal_value(self, state: GameState, player_idx: int) -> float:
        """Value of a terminal (game-over) state."""
        if state.winner == player_idx:
            return 1.0
        if state.winner == 1 - player_idx:
            return -1.0
        return 0.0

    def _evaluate_terminal_heuristic(self, state: GameState, player_idx: int) -> float:
        """Heuristic value when no actions are available."""
        if state.winner == player_idx:
            return 1.0
        if state.winner == 1 - player_idx:
            return -1.0
        # Use ChallengeAI evaluator as fallback
        raw = self.legal_ai.evaluate_state(state, player_idx)
        return max(-1.0, min(1.0, raw / 1_000_000.0))

    # ------------------------------------------------------------------
    # Dirichlet noise
    # ------------------------------------------------------------------

    def _dirichlet_noise(self, n: int) -> list[float]:
        """Generate Dirichlet noise for root prior exploration."""
        import random

        if n <= 0:
            return []
        alpha = self.dirichlet_alpha
        # Approximate Dirichlet via Gamma distribution
        gamma_samples = [random.gammavariate(alpha, 1.0) for _ in range(n)]
        total = sum(gamma_samples)
        return [s / max(1e-8, total) for s in gamma_samples]


def _fit_sequence(values: list, size: int, pad):
    """Pad or truncate a sequence to the given size."""
    if len(values) >= size:
        return values[:size]
    return values + [pad] * (size - len(values))

"""Public data types used by ChallengeAI."""
from __future__ import annotations

from dataclasses import dataclass

from engine.actions import GameAction as AIAction
from engine.ai.profiles import DEFAULT_POLICY_PATH, DeckAIProfile


@dataclass(frozen=True)
class AIConfig:
    thinking_time_seconds: float = 8.0
    beam_width: int = 24
    max_sequence_depth: int = 10
    max_turn_actions: int = 40
    coin_sample_count: int = 10
    opponent_response_actions: int = 10
    opponent_response_weight: float = 0.55
    deterministic_search: bool = False
    random_seed: int = 17
    deck_key: str | None = None
    policy_path: str | None = DEFAULT_POLICY_PATH
    policy_weights: dict[str, float] | None = None
    profile: DeckAIProfile | None = None
    search_algorithm: str = "hybrid"
    minimax_max_depth: int = 4
    minimax_determinizations: int = 3
    search_node_budget: int = 2500
    chance_branch_limit: int = 6
    response_branch_limit: int = 0
    skip_effect_dry_run: bool = False
    # Legacy search fields above remain loadable for old settings files, but
    # runtime decisions always use the shared information-set planner.
    use_unified_planner: bool = True
    planner_max_depth: int = 16

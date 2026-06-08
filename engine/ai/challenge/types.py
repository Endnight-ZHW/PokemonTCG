"""Public data types used by ChallengeAI."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from engine.ai.profiles import DEFAULT_POLICY_PATH, DeckAIProfile
from engine.enums import PlayerAction


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
    search_algorithm: str = "hybrid"
    minimax_max_depth: int = 3
    minimax_determinizations: int = 3
    search_node_budget: int = 0
    chance_branch_limit: int = 4
    response_branch_limit: int = 0
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

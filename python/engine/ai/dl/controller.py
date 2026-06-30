"""Runtime controller for the optional deep-learning AI."""
from __future__ import annotations

import os
import random
import json
import time
from dataclasses import dataclass
from typing import Any

from engine.ai.challenge_ai import AIAction, AIChoice, AIConfig, ChallengeAI, create_challenge_ai
from engine.ai.dl.encoder import ActionStateEncoder
from engine.ai.dl.encoder import ENCODER_SCHEMA_VERSION
from engine.ai.observation import Observation
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.ai.dl.model import TORCH_AVAILABLE, load_checkpoint, torch
from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.enums import PlayerAction, TurnPhase
from engine.snapshot import snapshot_state, state_from_snapshot
from utils.logger import get_logger

_logger = get_logger(__name__)


DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")
DEFAULT_MIN_ACCEPTED_EVAL_GAMES = 600


def _fit_sequence(values: list, size: int, pad):
    if len(values) >= size:
        return values[:size]
    return values + [pad] * (size - len(values))


@dataclass(frozen=True)
class DeepLearningAIConfig:
    model_path: str | None = None
    device: str = "cpu"
    temperature: float = 0.35
    deterministic: bool = True
    fallback_enabled: bool = True
    random_seed: int = 17
    fallback_config: AIConfig | None = None
    choice_confidence_threshold: float = 0.30
    # Shared planner settings; field names are retained for checkpoint/CLI compatibility.
    use_mcts: bool = True
    mcts_simulations: int = 256
    mcts_c_puct: float = 1.4
    mcts_chance_nodes: bool = False
    mcts_dirichlet_noise: bool = False  # False for inference, True for training
    max_thinking_time_seconds: float = 8.0


def _metadata_eval_summary(metadata: dict[str, Any], deck_key: str) -> dict[str, Any] | None:
    summary = metadata.get("summary")
    if isinstance(summary, dict):
        deck_summary = summary.get(deck_key)
        if not isinstance(deck_summary, dict) and len(summary) == 1:
            only_summary = next(iter(summary.values()))
            deck_summary = only_summary if isinstance(only_summary, dict) else None
        if isinstance(deck_summary, dict):
            eval_summary = deck_summary.get("eval")
            if isinstance(eval_summary, dict):
                return eval_summary
    return None


def _metadata_eval_games(metadata: dict[str, Any], deck_key: str) -> int:
    eval_summary = _metadata_eval_summary(metadata, deck_key)
    if eval_summary is not None:
        games = eval_summary.get("games")
        if isinstance(games, (int, float)):
            return int(games)
    raw_eval_games = metadata.get("eval_games")
    if isinstance(raw_eval_games, (int, float)):
        return int(raw_eval_games)
    return 0


def _metadata_eval_has_no_bad_actions(metadata: dict[str, Any], deck_key: str) -> bool:
    eval_summary = _metadata_eval_summary(metadata, deck_key)
    if eval_summary is None:
        return False
    invalid_rate = eval_summary.get("invalid_action_rate")
    no_target_rate = eval_summary.get("no_target_action_rate")
    rule_exception_rate = eval_summary.get("rule_exception_rate")
    timeout_rate = eval_summary.get("decision_timeout_rate")
    if isinstance(invalid_rate, (int, float)) and isinstance(no_target_rate, (int, float)):
        return (
            float(invalid_rate) <= 0.0
            and float(no_target_rate) <= 0.0
            and float(rule_exception_rate or 0.0) <= 0.0
            and float(timeout_rate or 0.0) <= 0.0
        )
    invalid_actions = eval_summary.get("invalid_actions")
    no_target_actions = eval_summary.get("no_target_actions")
    if isinstance(invalid_actions, (int, float)) and isinstance(no_target_actions, (int, float)):
        return int(invalid_actions) <= 0 and int(no_target_actions) <= 0
    return False


def _schema_is_current(metadata: dict[str, Any]) -> bool:
    return (
        int(metadata.get("rules_version") or 0) == RULES_SCHEMA_VERSION
        and int(metadata.get("action_version") or 0) == ACTION_SCHEMA_VERSION
        and int(metadata.get("encoder_version") or 0) == ENCODER_SCHEMA_VERSION
        and int(metadata.get("planner_version") or 0) == PLANNER_SCHEMA_VERSION
        and isinstance(metadata.get("seed"), int)
    )


def is_deep_model_accepted(
    deck_key: str | None,
    model_dir: str = DEFAULT_MODEL_DIR,
    min_eval_games: int = DEFAULT_MIN_ACCEPTED_EVAL_GAMES,
) -> bool:
    """Return True only for deployed, verified, accepted Deep AI checkpoints."""
    if not deck_key:
        return False
    model_path = os.path.join(model_dir, f"{deck_key}.pt")
    sidecar_path = os.path.splitext(model_path)[0] + ".json"
    if not os.path.exists(model_path):
        return False
    try:
        if os.path.getsize(model_path) <= 0:
            return False
    except OSError:
        return False
    try:
        with open(sidecar_path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return False
    metadata = payload.get("metadata") if isinstance(payload, dict) else {}
    if not isinstance(metadata, dict):
        return False
    accepted = bool(metadata.get("accepted"))
    verified = bool(metadata.get("verified")) or metadata.get("verification_status") == "verified_accepted"
    has_enough_eval = _metadata_eval_games(metadata, deck_key) >= max(0, int(min_eval_games))
    return (
        accepted
        and verified
        and has_enough_eval
        and _metadata_eval_has_no_bad_actions(metadata, deck_key)
        and _schema_is_current(metadata)
    )


class DeepLearningAI:
    """Legal-action scorer backed by a torch model with ChallengeAI fallback."""

    def __init__(self, deck_key: str | None = None, config: DeepLearningAIConfig | None = None):
        self.deck_key = deck_key
        self.config = config or DeepLearningAIConfig()
        fallback_config = self.config.fallback_config or AIConfig(
            deck_key=deck_key or "",
            thinking_time_seconds=4.0,
            beam_width=18,
            max_sequence_depth=8,
            max_turn_actions=36,
            minimax_max_depth=3,
            minimax_determinizations=2,
            search_node_budget=1600,
            use_unified_planner=True,
        )
        self.fallback: ChallengeAI = create_challenge_ai(deck_key or "", fallback_config)
        self.encoder = ActionStateEncoder()
        self.random = random.Random(self.config.random_seed)
        self.model = None
        self.model_metadata: dict[str, Any] = {}
        self._active_searcher = None
        self._load_model()

    @property
    def model_available(self) -> bool:
        return self.model is not None and TORCH_AVAILABLE

    def choose_action(self, state, player_idx: int) -> AIAction:
        if not self.model_available:
            return self._fallback_action(state, player_idx)

        actions = self.fallback.legal_actions(state, player_idx)
        if not actions:
            return AIAction(PlayerAction.END_TURN, {}, terminal=True)
        if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
            return self._fallback_action(state, player_idx)

        try:
            if self.config.use_mcts:
                return self._choose_with_mcts(state, player_idx, actions)
            return self._choose_with_model(state, player_idx, actions)
        except Exception as exc:
            _logger.debug("deep-learning action selection failed, falling back: %s", exc)
            return self._fallback_action(state, player_idx)

    def resolve_pending_action(self, state, action_request):
        if self.model_available and bool(getattr(self.model, "choice_head_enabled", False)):
            try:
                choice = self._choose_pending_with_model(state, action_request)
                if choice is not None:
                    return choice
            except Exception as exc:
                _logger.debug("deep-learning pending choice failed, falling back: %s", exc)
        return self.fallback.resolve_pending_action(state, action_request)

    def apply_choice(self, state, action_request, choice=None):
        return self.fallback.apply_choice(state, action_request, choice)

    def legal_actions(self, state, player_idx: int) -> list[AIAction]:
        return self.fallback.legal_actions(state, player_idx)

    def cancel_search(self) -> None:
        self.fallback.cancel_search()
        searcher = self._active_searcher
        if searcher is not None:
            cancel = getattr(searcher, "cancel", None)
            if callable(cancel):
                cancel()

    def _fallback_action(self, state, player_idx: int) -> AIAction:
        if self.config.fallback_enabled:
            return self.fallback.choose_action(state, player_idx)
        return AIAction(PlayerAction.END_TURN, {}, terminal=True)

    def _choose_with_model(self, state, player_idx: int, actions: list[AIAction]) -> AIAction:
        assert torch is not None
        observation = Observation.from_state(state, player_idx)
        encoded_state = self.encoder.encode_observation(observation, self.deck_key)
        encoded_actions = [
            self.encoder.encode_game_action(observation, action)
            for action in actions
        ]

        device = self.config.device
        state_numeric_size = int(getattr(self.model, "state_numeric_size", len(encoded_state.numeric)))
        state_card_slots = int(getattr(self.model, "state_card_slots", len(encoded_state.card_ids)))
        action_numeric_size = int(getattr(self.model, "action_numeric_size", len(encoded_actions[0].numeric)))
        with torch.no_grad():
            state_numeric = torch.tensor(
                [_fit_sequence(encoded_state.numeric, state_numeric_size, 0.0)],
                dtype=torch.float32,
                device=device,
            )
            state_cards = torch.tensor(
                [_fit_sequence(encoded_state.card_ids, state_card_slots, 0)],
                dtype=torch.long,
                device=device,
            )
            action_numeric = torch.tensor(
                [[_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in encoded_actions]],
                dtype=torch.float32,
                device=device,
            )
            action_cards = torch.tensor([[a.card_id for a in encoded_actions]], dtype=torch.long, device=device)
            logits, _ = self.model(state_numeric, state_cards, action_numeric, action_cards)
            logits = logits[0]
            temperature = max(0.05, float(self.config.temperature))
            if self.config.deterministic:
                ranked = torch.argsort(logits, descending=True).detach().cpu().tolist()
            else:
                probs = torch.softmax(logits / temperature, dim=0)
                ranked = torch.multinomial(
                    probs,
                    num_samples=len(actions),
                    replacement=False,
                ).detach().cpu().tolist()
        for idx in ranked:
            if self._action_executes_on_clone(state, player_idx, actions[idx]):
                return actions[idx]
        return self._fallback_action(state, player_idx)

    def _choose_with_mcts(self, state, player_idx: int, actions: list[AIAction]) -> AIAction:
        """Select an action with the shared planner and neural priors/value."""
        from engine.ai.dl.mcts import MCTSGuidedSearch

        searcher = MCTSGuidedSearch(
            self.model,
            self.encoder,
            self.fallback,
            num_simulations=int(self.config.mcts_simulations),
            c_puct=float(self.config.mcts_c_puct),
            temperature=float(self.config.temperature),
            use_chance_nodes=bool(self.config.mcts_chance_nodes),
            device=self.config.device,
            add_dirichlet_noise=bool(self.config.mcts_dirichlet_noise),
        )
        max_time = max(0.0, float(self.config.max_thinking_time_seconds))
        deadline = time.perf_counter() + max_time if max_time > 0.0 else None
        self._active_searcher = searcher
        try:
            selected = searcher.select_action(
                state,
                player_idx,
                self.deck_key,
                actions=actions,
                deterministic=self.config.deterministic,
                deadline=deadline,
            )
        finally:
            self._active_searcher = None
        if self._action_executes_on_clone(state, player_idx, selected):
            return selected
        return self._choose_with_model(state, player_idx, actions)

    def _action_executes_on_clone(self, state, player_idx: int, action: AIAction) -> bool:
        if action.action not in {
            PlayerAction.PLAY_TRAINER,
            PlayerAction.USE_ABILITY,
            PlayerAction.USE_STADIUM,
            PlayerAction.RETREAT,
            PlayerAction.DECLARE_ATTACK,
        }:
            return True
        rng_state = random.getstate()
        try:
            cloned = state_from_snapshot(snapshot_state(state), rebuild_event_bus=True)
            result = self.fallback._apply_action_for_sim(cloned, player_idx, action)
            return result is not None and bool(result.success)
        except Exception:
            return False
        finally:
            random.setstate(rng_state)

    @property
    def mcts_search(self):
        """Create a fresh shared-planner adapter for external training code."""
        from engine.ai.dl.mcts import MCTSGuidedSearch

        return MCTSGuidedSearch(
            self.model,
            self.encoder,
            self.fallback,
            num_simulations=int(self.config.mcts_simulations),
            c_puct=float(self.config.mcts_c_puct),
            temperature=float(self.config.temperature),
            use_chance_nodes=bool(self.config.mcts_chance_nodes),
            device=self.config.device,
            add_dirichlet_noise=bool(self.config.mcts_dirichlet_noise),
        )

    def _pending_choice_candidates(self, state, req) -> tuple[list[Any], str] | None:
        request_type = getattr(req, "request_type", "")
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        if request_type in ("search_deck", "select_hand_to_discard"):
            candidates = list(getattr(req, "card_list", []) or [])
            return (candidates, request_type) if candidates else None
        if request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            target_player = state.get_player(1 - player_idx) if request_type == "select_opponent_bench" else state.get_player(player_idx)
            candidates = [
                idx for idx in range(len(target_player.bench))
                if target_player.bench[idx] is not None
            ]
            return (candidates, request_type) if candidates else None
        if request_type == "select_bench_targets":
            target_player = state.get_player(1 - player_idx) if getattr(req, "target_player", "") == "opponent" else state.get_player(player_idx)
            candidates = [
                idx for idx in (getattr(req, "bench_indices", None) or range(len(target_player.bench)))
                if 0 <= idx < len(target_player.bench) and target_player.bench[idx] is not None
            ]
            return (candidates, request_type) if candidates else None
        if request_type == "confirm":
            return [True, False], request_type
        return None

    def _choose_pending_with_model(self, state, req) -> AIChoice | None:
        assert torch is not None
        candidate_info = self._pending_choice_candidates(state, req)
        if candidate_info is None:
            return None
        candidates, request_type = candidate_info
        player_idx = req.player if req.player in (0, 1) else state.active_player_idx
        encoded_state = self.encoder.encode_state(state, player_idx, self.deck_key)
        encoded_choices = [
            self.encoder.encode_choice(state, player_idx, request_type, candidate, idx)
            for idx, candidate in enumerate(candidates)
        ]
        if not encoded_choices:
            return None

        device = self.config.device
        state_numeric_size = int(getattr(self.model, "state_numeric_size", len(encoded_state.numeric)))
        state_card_slots = int(getattr(self.model, "state_card_slots", len(encoded_state.card_ids)))
        action_numeric_size = int(getattr(self.model, "action_numeric_size", len(encoded_choices[0].numeric)))
        with torch.no_grad():
            state_numeric = torch.tensor(
                [_fit_sequence(encoded_state.numeric, state_numeric_size, 0.0)],
                dtype=torch.float32,
                device=device,
            )
            state_cards = torch.tensor(
                [_fit_sequence(encoded_state.card_ids, state_card_slots, 0)],
                dtype=torch.long,
                device=device,
            )
            choice_numeric = torch.tensor(
                [[_fit_sequence(a.numeric, action_numeric_size, 0.0) for a in encoded_choices]],
                dtype=torch.float32,
                device=device,
            )
            choice_cards = torch.tensor([[a.card_id for a in encoded_choices]], dtype=torch.long, device=device)
            if hasattr(self.model, "score_choices"):
                logits = self.model.score_choices(state_numeric, state_cards, choice_numeric, choice_cards)
            else:
                logits, _ = self.model(state_numeric, state_cards, choice_numeric, choice_cards)
            probs = torch.softmax(logits[0] / max(0.05, float(self.config.temperature)), dim=0)
            ranked = torch.argsort(probs, descending=True).detach().cpu().tolist()
            confidence = float(probs[ranked[0]].detach().cpu().item()) if ranked else 0.0
        if confidence < float(self.config.choice_confidence_threshold):
            return None

        if request_type in ("search_deck", "select_hand_to_discard"):
            count = max(req.min_select, min(req.max_select, len(candidates)))
            return AIChoice(selected_cards=[candidates[idx] for idx in ranked[:count]])
        if request_type in ("select_bench", "select_opponent_bench", "select_own_bench_energy"):
            return AIChoice(selected_bench_slot=int(candidates[ranked[0]]))
        if request_type == "select_bench_targets":
            count = max(req.min_select, min(req.max_select, len(candidates)))
            return AIChoice(selected_bench_targets=[int(candidates[idx]) for idx in ranked[:count]])
        if request_type == "confirm":
            return AIChoice(confirmed=bool(candidates[ranked[0]]))
        return None

    def _load_model(self) -> None:
        if not TORCH_AVAILABLE:
            return
        path = self.config.model_path or self._default_model_path()
        if not path or not os.path.exists(path):
            return
        try:
            model, payload = load_checkpoint(path, self.config.device)
            metadata = dict(payload.get("metadata") or {})
            schema = dict(payload.get("schema") or {})
            merged_schema = dict(schema)
            merged_schema.update(metadata)
            if not _schema_is_current(merged_schema):
                _logger.warning(
                    "deep-learning model schema mismatch for %s; using Rules AI fallback",
                    path,
                )
                self.model = None
                self.model_metadata = metadata
                return
            self.model = model
            self.model_metadata = metadata
        except Exception as exc:
            _logger.warning("failed to load deep-learning AI model %s: %s", path, exc)
            self.model = None
            self.model_metadata = {}

    def _default_model_path(self) -> str:
        if self.deck_key:
            deck_path = os.path.join(DEFAULT_MODEL_DIR, f"{self.deck_key}.pt")
            if os.path.exists(deck_path):
                return deck_path
        return os.path.join(DEFAULT_MODEL_DIR, "default.pt")

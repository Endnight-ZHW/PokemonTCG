"""Two-sided population self-play for ``hybrid_population_rl``.

Unlike the legacy target-vs-opponent rollout, every applicable decision in a
population game is made by that seat's model and both trajectories are returned
to their owning deck.  Choice examples are deliberately not produced here:
the v1 Choice head remains Teacher/DAgger supervised.
"""
from __future__ import annotations

import random
import time
from dataclasses import dataclass
from typing import Any

from data.deck_definitions import expand_deck
from engine.actions import ChoiceResponse
from engine.ai.dl.encoder import ActionStateEncoder
from engine.ai.dl.mcts import MCTSGuidedSearch
from engine.ai.dl.production_contract import DEEP_PLANNER_CONSTANTS, PopulationTask
from engine.ai.dl.training import (
    TrainingExample,
    _action_executes_on_clone,
    _action_has_no_available_target,
    _action_signature,
    _finalize_episode_examples,
    _forward_example,
    _make_teacher,
    _restore_rng,
    _snapshot_metrics,
    _step_reward_components,
    _terminal_reward,
)
from engine.ai.training import (
    DECK_SPECS,
    finish_setup,
    force_end_turn,
    terminal_training_score,
)
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import DEFAULT_GAME_ENGINE
from engine.game_state import GameState
from engine.random_source import RandomSource
from engine.turn_manager import TurnManager

try:
    import torch
except Exception:  # pragma: no cover
    torch = None


@dataclass
class PopulationGameResult:
    task_id: str
    winner_deck: str | None
    winner_player: int | None
    score_a: float
    trajectories: dict[str, list[TrainingExample]]
    diagnostics: dict[str, dict[str, Any]]
    terminal: bool
    steps: int


def _forced_setup(
    task: PopulationTask,
    teacher_search_preset: str,
) -> tuple[GameState, list[Any], dict[int, str], Any]:
    rng_state = random.getstate()
    random.seed(task.seed)
    try:
        deck_a_player = 1 if task.seat_a == 1 else 0
        deck_by_player = {
            deck_a_player: task.deck_a,
            1 - deck_a_player: task.deck_b,
        }
        state = GameState()
        setup_rng = RandomSource(task.seed)
        setup = DEFAULT_GAME_ENGINE.begin_game(
            state,
            expand_deck(DECK_SPECS[deck_by_player[0]]),
            expand_deck(DECK_SPECS[deck_by_player[1]]),
            setup_rng,
        )
        if not setup.success:
            raise RuntimeError(setup.message)
        state.public_deck_keys = (deck_by_player[0], deck_by_player[1])
        ais = [
            _make_teacher(deck_by_player[0], task.seed + 11, teacher_search_preset),
            _make_teacher(deck_by_player[1], task.seed + 29, teacher_search_preset),
        ]

        request = DEFAULT_GAME_ENGINE.pending_choice_request(state)
        if request is None or request.request_type != "choose_turn_order":
            raise RuntimeError("Opening turn-order choice is missing")
        coin_winner = int(state.opening_coin_winner_idx)
        desired = "first" if coin_winner == task.forced_first_player else "second"
        option = next(
            (item for item in request.options if str(item.value) == desired),
            None,
        )
        if option is None:
            raise RuntimeError("Opening turn-order option is missing")
        choice_step = DEFAULT_GAME_ENGINE.apply_choice(
            state,
            ChoiceResponse(request.request_id, (option.option_id,)),
            setup_rng,
        )
        if not choice_step.success:
            raise RuntimeError(choice_step.message)
        with setup_rng.bind_state(state):
            finish_setup(state, TurnManager(state), ais, setup_rng)
        if int(state.first_player_idx) != int(task.forced_first_player):
            raise RuntimeError("Forced first-player closure was not applied")
        return state, ais, deck_by_player, rng_state
    except Exception:
        random.setstate(rng_state)
        raise


def play_population_game(
    task: PopulationTask,
    model_a: Any,
    model_b: Any,
    *,
    device: str,
    max_steps: int,
    mcts_simulations: int,
    teacher_search_preset: str = "quality",
    decision_seconds: float = 2.0,
    training_exploration: bool = True,
    record_trajectories: bool = True,
) -> PopulationGameResult:
    """Play one game and return separate, terminal-labelled trajectories."""

    if torch is None:
        raise RuntimeError("PyTorch is required for population rollouts")
    state, ais, deck_by_player, rng_state = _forced_setup(
        task, teacher_search_preset
    )
    deck_a_player = 1 if task.seat_a == 1 else 0
    models = {
        deck_a_player: model_a,
        1 - deck_a_player: model_b,
    }
    encoders = {0: ActionStateEncoder(), 1: ActionStateEncoder()}
    searchers = {
        player: MCTSGuidedSearch(
            models[player],
            encoders[player],
            ais[player],
            num_simulations=max(1, int(mcts_simulations)),
            c_puct=float(DEEP_PLANNER_CONSTANTS["c_puct"]),
            temperature=1.0 if training_exploration else 0.0,
            use_chance_nodes=False,
            device=device,
            add_dirichlet_noise=training_exploration,
            max_depth=int(DEEP_PLANNER_CONSTANTS["max_depth"]),
            root_only_neural=True,
            neural_prior_weight=float(
                DEEP_PLANNER_CONSTANTS["neural_prior_weight"]
            ),
            thinking_time_seconds=max(0.01, float(decision_seconds)),
            match_seed=task.seed,
        )
        for player in (0, 1)
    }
    examples: dict[int, list[TrainingExample]] = {0: [], 1: []}
    diagnostics: dict[int, dict[str, Any]] = {
        player: {
            "deck": deck_by_player[player],
            "actions": 0,
            "invalid_actions": 0,
            "illegal_choices": 0,
            "rule_exceptions": 0,
            "decision_timeouts": 0,
            "decision_seconds": 0.0,
            "encoding_seconds": 0.0,
            "search_seconds": 0.0,
            "model_value_seconds": 0.0,
            "environment_step_seconds": 0.0,
            "max_step_exhaustions": 0,
            "seat": player,
            "first_player": int(state.first_player_idx),
            "searches": [],
            "reward_components": {},
        }
        for player in (0, 1)
    }
    failed_signatures: dict[int, set[tuple]] = {0: set(), 1: set()}
    steps = 0
    try:
        for step_index in range(max(1, int(max_steps))):
            steps = step_index + 1
            if state.is_terminal():
                break
            if state.pending_promotion_player >= 0:
                ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                continue
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).advance_phase()
                continue
            if state.phase not in (TurnPhase.MAIN, TurnPhase.ATTACK):
                TurnManager(state).advance_phase()
                continue

            player = int(state.active_player_idx)
            ai = ais[player]
            actions = ai.legal_actions(state, player)
            if not actions:
                force_end_turn(state, player)
                continue
            started = time.perf_counter()
            before = (
                _snapshot_metrics(state, player, ai)
                if record_trajectories
                else {}
            )
            search_started = time.perf_counter()
            search = searchers[player].search(
                state,
                player,
                deck_by_player[player],
                actions=actions,
                deadline=started + max(0.01, float(decision_seconds)),
            )
            diagnostics[player]["search_seconds"] += (
                time.perf_counter() - search_started
            )
            if int(search.simulations) != max(1, int(mcts_simulations)):
                diagnostics[player]["decision_timeouts"] += 1
                raise RuntimeError(
                    "population_search_incomplete:"
                    f"{search.simulations}/{max(1, int(mcts_simulations))}"
                )
            sampled_index = max(
                0,
                min(int(search.selected_action_idx), len(actions) - 1),
            )
            chosen_index = sampled_index
            if record_trajectories:
                diagnostics[player]["searches"].append({
                    "revision": int(getattr(state, "revision", 0)),
                    "turn": int(getattr(state, "turn_number", 0)),
                    "raw_priors": dict(search.raw_priors),
                    "noisy_priors": dict(search.noisy_priors),
                    "visit_counts": dict(search.visit_counts),
                    "visit_distribution": dict(search.action_probs),
                    "temperature": float(search.temperature),
                    "sample_seed": search.sample_seed,
                    "sampled_action_index": sampled_index,
                    "sampled_action_signature": str(
                        actions[sampled_index].signature
                    ),
                })
            if not _action_executes_on_clone(
                ai,
                state,
                player,
                actions[sampled_index],
            ):
                diagnostics[player]["invalid_actions"] += 1
                raise RuntimeError(
                    "population_sampled_illegal_action:"
                    f"{actions[sampled_index].signature}"
                )
            # The sampled visit distribution is both the policy target and
            # the behavior policy.  Do not apply a heuristic postprocessor
            # that would silently replace the sampled candidate.
            action = actions[chosen_index]
            example: TrainingExample | None = None
            if record_trajectories:
                encoding_started = time.perf_counter()
                encoded_state = encoders[player].encode_state(
                    state, player, deck_by_player[player]
                )
                encoded_actions = [
                    encoders[player].encode_action(
                        state,
                        player,
                        item,
                    )
                    for item in actions
                ]
                diagnostics[player]["encoding_seconds"] += (
                    time.perf_counter() - encoding_started
                )
                model_value_started = time.perf_counter()
                with torch.no_grad():
                    _, value = _forward_example(
                        models[player],
                        TrainingExample(
                            encoded_state,
                            encoded_actions,
                            0,
                            source="self_play",
                        ),
                        device,
                    )
                    predicted_value = float(
                        value.reshape(-1)[0].detach().cpu().item()
                    )
                diagnostics[player]["model_value_seconds"] += (
                    time.perf_counter() - model_value_started
                )
                policy_target = [
                    float(search.action_probs.get(index, 0.0))
                    for index in range(len(actions))
                ]
                example = TrainingExample(
                    encoded_state,
                    encoded_actions,
                    chosen_index,
                    source="self_play",
                    value_target=predicted_value,
                    phase_tag=f"population_g{task.generation}",
                    policy_target=policy_target,
                )

            elapsed = time.perf_counter() - started
            diagnostics[player]["actions"] += 1
            diagnostics[player]["decision_seconds"] += elapsed
            if elapsed > float(decision_seconds):
                diagnostics[player]["decision_timeouts"] += 1
            if _action_has_no_available_target(ai, state, player, action):
                diagnostics[player]["invalid_actions"] += 1
            try:
                environment_started = time.perf_counter()
                result = ai._apply_action_for_sim(state, player, action)
            except Exception:
                result = None
                diagnostics[player]["rule_exceptions"] += 1
            finally:
                diagnostics[player]["environment_step_seconds"] += (
                    time.perf_counter() - environment_started
                )
            invalid = result is None or not bool(result.success)
            if invalid:
                diagnostics[player]["invalid_actions"] += 1
                failed_signatures[player].add(_action_signature(action))
                if len(failed_signatures[player]) >= 2:
                    force_end_turn(state, player)
                    failed_signatures[player].clear()
            else:
                failed_signatures[player].clear()
            if example is not None:
                after = _snapshot_metrics(state, player, ai)
                reward_components = _step_reward_components(
                    before,
                    after,
                    invalid=invalid,
                )
                example.reward = reward_components["total"]
                for component, value in reward_components.items():
                    diagnostics[player]["reward_components"][component] = (
                        float(
                            diagnostics[player]["reward_components"].get(
                                component,
                                0.0,
                            )
                        )
                        + float(value)
                    )
                examples[player].append(example)

        truncated = not state.is_terminal()
        position_scores: dict[int, float] = {}
        if truncated:
            diagnostics[0]["max_step_exhaustions"] = 1
            diagnostics[1]["max_step_exhaustions"] = 1
            position_scores = {
                player: float(ais[player].evaluate_state(state, player))
                for player in (0, 1)
            }
            state.set_result("DRAW", reason="MAX_STEPS")

        winner_player: int | None
        if getattr(state, "result_status", "") == "DRAW":
            winner_player = None
        else:
            winner_player = (
                int(state.winner) if state.winner in (0, 1) else None
            )
        for player in (0, 1):
            logical_winner = (
                None
                if winner_player is None
                else 0 if winner_player == player else 1
            )
            score = (
                position_scores[player]
                if truncated
                else terminal_training_score(state, player)
            )
            _finalize_episode_examples(
                examples[player],
                _terminal_reward(logical_winner, score),
            )
        winner_deck = (
            deck_by_player[winner_player]
            if winner_player in (0, 1)
            else None
        )
        trajectories: dict[str, list[TrainingExample]] = {}
        if task.deck_a == task.deck_b:
            # Mirrors still have two owners.  Use explicit seat-qualified keys
            # so callers cannot silently collapse one side's trajectory.
            trajectories[f"{task.deck_a}@p{deck_a_player}"] = examples[deck_a_player]
            trajectories[f"{task.deck_b}@p{1 - deck_a_player}"] = examples[
                1 - deck_a_player
            ]
        else:
            trajectories[task.deck_a] = examples[deck_a_player]
            trajectories[task.deck_b] = examples[1 - deck_a_player]
        return PopulationGameResult(
            task_id=task.task_id,
            winner_deck=winner_deck,
            winner_player=winner_player,
            score_a=(
                position_scores[deck_a_player]
                if truncated
                else terminal_training_score(state, deck_a_player)
            ),
            trajectories=trajectories,
            diagnostics={
                f"{deck_by_player[player]}@p{player}": diagnostics[player]
                for player in (0, 1)
            },
            terminal=state.is_terminal(),
            steps=steps,
        )
    finally:
        _restore_rng(rng_state)

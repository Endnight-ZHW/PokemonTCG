"""Training helpers for the optional deep-learning AI."""
from __future__ import annotations

import json
import os
import random
import time
from dataclasses import dataclass
from typing import Any, Callable

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS, expand_deck
from engine.ai.challenge_ai import AIAction, AIConfig, create_challenge_ai
from engine.ai.dl.encoder import ACTION_NUMERIC_SIZE, ActionStateEncoder, EncodedAction, EncodedState
from engine.ai.dl.model import TORCH_AVAILABLE, create_model, load_checkpoint, save_checkpoint, torch
from engine.ai.dl.replay import ReplayBuffer
from engine.ai.training import DECK_SPECS, finish_setup, force_end_turn, terminal_training_score
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from engine.turn_manager import TurnManager


DEFAULT_MODEL_DIR = os.path.join("data", "ai_models")

TRAINING_AI_SEARCH = {
    "thinking_time_seconds": 0.0,
    "beam_width": 6,
    "max_sequence_depth": 3,
    "max_turn_actions": 20,
    "coin_sample_count": 4,
    "opponent_response_actions": 4,
    "opponent_response_weight": 0.35,
    "deterministic_search": True,
}


@dataclass(frozen=True)
class DeepTrainingConfig:
    deck: str = "all"
    games: int = 500
    seed: int = 17
    model: str | None = None
    output: str | None = None
    device: str = "cpu"
    bootstrap_games: int = 200
    bootstrap_epochs: int = 10
    self_play_epochs: int = 10
    eval_games: int = 100
    workers: int = 1
    max_steps: int = 120
    learning_rate: float = 1e-3
    batch_size: int = 64
    progress_jsonl: str | None = None


@dataclass
class TrainingExample:
    state: EncodedState
    actions: list[EncodedAction]
    target_index: int
    value_target: float = 0.0
    policy_advantage: float | None = None


ProgressCallback = Callable[[dict[str, Any]], None]


def is_torch_available() -> bool:
    return TORCH_AVAILABLE


def _ensure_cards_loaded() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS, use_api=False)


def _deck_keys(deck: str) -> list[str]:
    if deck == "all":
        return list(DECK_SPECS)
    if deck not in DECK_SPECS:
        raise ValueError(f"Unknown deck key: {deck}")
    return [deck]


def _output_path_for_deck(deck_key: str) -> str:
    return os.path.join(DEFAULT_MODEL_DIR, f"{deck_key}.pt")


def _action_signature(action: AIAction) -> tuple:
    return (
        action.action.name if isinstance(action.action, PlayerAction) else str(action.action),
        tuple(sorted((action.params or {}).items())),
        bool(action.terminal),
    )


def _find_action_index(actions: list[AIAction], selected: AIAction) -> int | None:
    signature = _action_signature(selected)
    for idx, action in enumerate(actions):
        if _action_signature(action) == signature:
            return idx
    selected_name = selected.action.name if isinstance(selected.action, PlayerAction) else str(selected.action)
    for idx, action in enumerate(actions):
        action_name = action.action.name if isinstance(action.action, PlayerAction) else str(action.action)
        if action_name == selected_name and (action.params or {}) == (selected.params or {}):
            return idx
    return None


def _opponent_for(deck_key: str, index: int) -> str:
    opponents = [key for key in DECK_SPECS if key != deck_key]
    return opponents[index % len(opponents)]


def _make_teacher(deck_key: str, seed: int):
    return create_challenge_ai(
        deck_key,
        AIConfig(**TRAINING_AI_SEARCH, random_seed=seed, policy_path=None),
    )


def _setup_match(deck_key: str, opponent_key: str, seed: int, seat: int):
    rng_state = random.getstate()
    random.seed(seed)
    try:
        deck_a_player_idx = 1 if seat == 1 else 0
        state = GameState()
        deck1_key = deck_key if deck_a_player_idx == 0 else opponent_key
        deck2_key = opponent_key if deck_a_player_idx == 0 else deck_key
        state.setup_game(expand_deck(DECK_SPECS[deck1_key]), expand_deck(DECK_SPECS[deck2_key]))
        tm = TurnManager(state)
        if deck_a_player_idx == 0:
            ai0 = _make_teacher(deck_key, seed + 11)
            ai1 = _make_teacher(opponent_key, seed + 29)
        else:
            ai0 = _make_teacher(opponent_key, seed + 29)
            ai1 = _make_teacher(deck_key, seed + 11)
        finish_setup(state, tm, [ai0, ai1])
        return state, tm, [ai0, ai1], deck_a_player_idx, rng_state
    except Exception:
        random.setstate(rng_state)
        raise


def _restore_rng(rng_state) -> None:
    random.setstate(rng_state)


def collect_bootstrap_examples(
    deck_key: str,
    games: int,
    seed: int,
    *,
    max_steps: int = 120,
    encoder: ActionStateEncoder | None = None,
) -> list[TrainingExample]:
    """Collect imitation examples from ChallengeAI self-play."""
    _ensure_cards_loaded()
    encoder = encoder or ActionStateEncoder()
    examples: list[TrainingExample] = []
    target_games = max(0, int(games))
    for game_idx in range(target_games):
        opponent_key = _opponent_for(deck_key, game_idx)
        seat = game_idx % 2
        state, _, ais, target_player_idx, rng_state = _setup_match(
            deck_key,
            opponent_key,
            seed + game_idx * 101,
            seat,
        )
        try:
            failed_signatures: dict[int, set[tuple]] = {0: set(), 1: set()}
            for _ in range(max_steps):
                if state.winner is not None or state.phase == TurnPhase.GAME_OVER:
                    break
                if state.pending_promotion_player >= 0:
                    ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                    continue
                if state.phase == TurnPhase.DRAW:
                    TurnManager(state).advance_phase()
                    continue
                if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
                    TurnManager(state).advance_phase()
                    continue

                player_idx = state.active_player_idx if state.phase != TurnPhase.SETUP else target_player_idx
                ai = ais[player_idx]
                if player_idx == target_player_idx:
                    actions = ai.legal_actions(state, player_idx)
                    selected = ai.choose_action(state, player_idx)
                    target_index = _find_action_index(actions, selected)
                    if actions and target_index is not None:
                        examples.append(TrainingExample(
                            encoder.encode_state(state, player_idx, deck_key),
                            [encoder.encode_action(state, player_idx, action) for action in actions],
                            target_index,
                            value_target=0.0,
                        ))
                    action = selected
                else:
                    action = ai.choose_action(state, player_idx)

                before = (state.turn_number, state.phase, state.active_player_idx, state.winner)
                result = ai._apply_action_for_sim(state, player_idx, action)
                after = (state.turn_number, state.phase, state.active_player_idx, state.winner)
                signature = _action_signature(action)
                if result is None or not result.success or before == after:
                    failed_signatures[player_idx].add(signature)
                    if len(failed_signatures[player_idx]) >= 3:
                        force_end_turn(state, player_idx)
                        failed_signatures[player_idx].clear()
                else:
                    failed_signatures[player_idx].clear()
        finally:
            _restore_rng(rng_state)
    return examples


def _forward_example(model, example: TrainingExample, device: str):
    """Single-example forward pass used during action selection (inference only)."""
    assert torch is not None
    state_numeric = torch.tensor([example.state.numeric], dtype=torch.float32, device=device)
    state_cards = torch.tensor([example.state.card_ids], dtype=torch.long, device=device)
    action_numeric = torch.tensor([[a.numeric for a in example.actions]], dtype=torch.float32, device=device)
    action_cards = torch.tensor([[a.card_id for a in example.actions]], dtype=torch.long, device=device)
    return model(state_numeric, state_cards, action_numeric, action_cards)


def _forward_batch(model, examples: list[TrainingExample], device: str):
    """Batched forward pass for mini-batch training.

    Pads the action dimension across examples since each state may have a
    different number of legal actions.
    """
    assert torch is not None
    B = len(examples)
    if B == 0:
        return None, None

    state_numeric = torch.tensor([ex.state.numeric for ex in examples], dtype=torch.float32, device=device)
    state_cards = torch.tensor([ex.state.card_ids for ex in examples], dtype=torch.long, device=device)

    max_actions = max(len(ex.actions) for ex in examples)
    action_numeric = torch.zeros(B, max_actions, ACTION_NUMERIC_SIZE, dtype=torch.float32, device=device)
    action_cards = torch.zeros(B, max_actions, dtype=torch.long, device=device)
    action_mask = torch.zeros(B, max_actions, dtype=torch.bool, device=device)

    for i, ex in enumerate(examples):
        n = len(ex.actions)
        if n == 0:
            continue
        action_numeric[i, :n] = torch.tensor([a.numeric for a in ex.actions], dtype=torch.float32)
        action_cards[i, :n] = torch.tensor([a.card_id for a in ex.actions], dtype=torch.long)
        action_mask[i, :n] = True

    logits, value = model(state_numeric, state_cards, action_numeric, action_cards, action_mask)
    return logits, value, action_mask


def _train_examples(
    model,
    examples: list[TrainingExample],
    *,
    device: str,
    learning_rate: float,
    epochs: int = 1,
    batch_size: int = 64,
) -> dict[str, Any]:
    if not examples:
        return {"examples": 0, "loss": 0.0, "total_loss": 0.0, "policy_loss": 0.0, "value_loss": 0.0}
    assert torch is not None
    import torch.nn.functional as F

    model.train()
    optimizer = torch.optim.Adam(model.parameters(), lr=learning_rate)
    total_loss = 0.0
    total_policy_loss = 0.0
    total_value_loss = 0.0
    steps = 0
    bs = max(1, int(batch_size))

    for _ in range(max(1, int(epochs))):
        random.shuffle(examples)
        for batch_start in range(0, len(examples), bs):
            batch = examples[batch_start:batch_start + bs]
            logits, value, action_mask = _forward_batch(model, batch, device)
            if logits is None:
                continue

            targets = torch.tensor([ex.target_index for ex in batch], dtype=torch.long, device=device)
            value_targets = torch.tensor([float(ex.value_target) for ex in batch], dtype=torch.float32, device=device)

            policy_loss = torch.tensor(0.0, device=device)
            for i, ex in enumerate(batch):
                if not ex.actions or action_mask[i].sum() == 0:
                    continue
                if ex.policy_advantage is None:
                    loss_i = F.cross_entropy(logits[i, :action_mask[i].sum().item()].unsqueeze(0),
                                              targets[i].unsqueeze(0))
                else:
                    log_probs = F.log_softmax(logits[i, :action_mask[i].sum().item()], dim=-1)
                    advantage = max(-1.5, min(1.5, float(ex.policy_advantage)))
                    loss_i = -log_probs[ex.target_index] * advantage
                policy_loss = policy_loss + loss_i

            policy_loss = policy_loss / len(batch)
            value_loss = F.mse_loss(value, value_targets)
            loss = policy_loss + 0.2 * value_loss

            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
            optimizer.step()

            total_loss += float(loss.detach().cpu().item())
            total_policy_loss += float(policy_loss.detach().cpu().item())
            total_value_loss += float(value_loss.detach().cpu().item())
            steps += 1

    model.eval()
    avg_total = round(total_loss / max(1, steps), 6)
    return {
        "examples": len(examples),
        "loss": avg_total,
        "total_loss": avg_total,
        "policy_loss": round(total_policy_loss / max(1, steps), 6),
        "value_loss": round(total_value_loss / max(1, steps), 6),
    }


def _select_model_action(model, encoder, state, player_idx: int, deck_key: str, legal_ai, device: str, temperature: float):
    assert torch is not None
    actions = legal_ai.legal_actions(state, player_idx)
    if not actions:
        return AIAction(PlayerAction.END_TURN, {}, terminal=True), None
    encoded_state = encoder.encode_state(state, player_idx, deck_key)
    encoded_actions = [encoder.encode_action(state, player_idx, action) for action in actions]
    with torch.no_grad():
        example = TrainingExample(encoded_state, encoded_actions, 0)
        logits, value = _forward_example(model, example, device)
        probs = torch.softmax(logits[0] / max(0.05, temperature), dim=0)
        target_index = int(torch.multinomial(probs, 1).item())
        predicted_value = float(value[0].detach().cpu().item())
    return actions[target_index], TrainingExample(
        encoded_state,
        encoded_actions,
        target_index,
        value_target=predicted_value,
        policy_advantage=0.0,
    )


def _snapshot_metrics(state, player_idx: int) -> dict[str, float]:
    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    return {
        "prizes_taken": float(6 - len(player.prizes)),
        "opp_prizes_taken": float(6 - len(opponent.prizes)),
    }


def _step_reward(before: dict, after: dict) -> float:
    """Intermediate reward from metric deltas (prize swings)."""
    r = 0.0
    prize_delta = after["prizes_taken"] - before["prizes_taken"]
    opp_prize_delta = after["opp_prizes_taken"] - before["opp_prizes_taken"]
    if prize_delta > 0:
        r += prize_delta * 0.2
    if opp_prize_delta > 0:
        r -= opp_prize_delta * 0.2
    return r


def _play_model_game(
    model,
    deck_key: str,
    seed: int,
    *,
    device: str,
    max_steps: int,
    record: bool,
) -> tuple[int | None, float, list[TrainingExample]]:
    encoder = ActionStateEncoder()
    opponent_key = _opponent_for(deck_key, seed)
    seat = seed % 2
    state, _, ais, target_player_idx, rng_state = _setup_match(deck_key, opponent_key, seed, seat)
    examples: list[TrainingExample] = []
    target_ai = ais[target_player_idx]
    step_rewards: list[float] = []
    try:
        failed_signatures: dict[int, set[tuple]] = {0: set(), 1: set()}
        for _ in range(max_steps):
            if state.winner is not None or state.phase == TurnPhase.GAME_OVER:
                break
            if state.pending_promotion_player >= 0:
                ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                continue
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).advance_phase()
                continue
            if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
                TurnManager(state).advance_phase()
                continue

            before_metrics = _snapshot_metrics(state, target_player_idx)

            player_idx = state.active_player_idx if state.phase != TurnPhase.SETUP else target_player_idx
            if player_idx == target_player_idx:
                action, example = _select_model_action(
                    model, encoder, state, player_idx, deck_key, target_ai, device, temperature=0.9
                )
                if record and example is not None:
                    examples.append(example)
                ai = target_ai
            else:
                ai = ais[player_idx]
                action = ai.choose_action(state, player_idx)

            result = ai._apply_action_for_sim(state, player_idx, action)
            signature = _action_signature(action)
            if result is None or not result.success:
                failed_signatures[player_idx].add(signature)
                if len(failed_signatures[player_idx]) >= 3:
                    force_end_turn(state, player_idx)
                    failed_signatures[player_idx].clear()
            else:
                failed_signatures[player_idx].clear()

            if record:
                after_metrics = _snapshot_metrics(state, target_player_idx)
                step_rewards.append(_step_reward(before_metrics, after_metrics))

        if state.winner is not None:
            logical_winner = 0 if state.winner == target_player_idx else 1
            score = terminal_training_score(state, target_player_idx)
        else:
            logical_winner = None
            score = target_ai.evaluate_state(state, target_player_idx)
        terminal_reward = max(-1.0, min(1.0, score / 1_000_000.0))
        if logical_winner == 0:
            terminal_reward = max(terminal_reward, 1.0)
        elif logical_winner == 1:
            terminal_reward = min(terminal_reward, -1.0)

        # Discount intermediate rewards into examples (gamma=0.99, backwards).
        gamma = 0.99
        discounted = 0.0
        for i in range(len(examples) - 1, -1, -1):
            step_r = step_rewards[i] if i < len(step_rewards) else 0.0
            discounted = step_r + gamma * discounted
            predicted_v = examples[i].value_target  # model's prediction, saved before overwrite
            total_r = float(discounted) + terminal_reward
            examples[i].value_target = total_r
            examples[i].policy_advantage = total_r - predicted_v

        return logical_winner, score, examples
    finally:
        _restore_rng(rng_state)


def evaluate_model(model, deck_key: str, seed: int, games: int, *, device: str, max_steps: int = 120) -> dict[str, Any]:
    stats = {"wins": 0, "losses": 0, "draws": 0, "avg_score": 0.0, "games": max(0, int(games))}
    if games <= 0:
        return stats
    score_total = 0.0
    for idx in range(games):
        winner, score, _ = _play_model_game(
            model,
            deck_key,
            seed + idx * 97,
            device=device,
            max_steps=max_steps,
            record=False,
        )
        score_total += score
        if winner == 0:
            stats["wins"] += 1
        elif winner == 1:
            stats["losses"] += 1
        else:
            stats["draws"] += 1
    stats["avg_score"] = round(score_total / max(1, games), 3)
    return stats


def _load_or_create_model(config: DeepTrainingConfig):
    assert torch is not None
    if config.model and os.path.exists(config.model):
        model, _ = load_checkpoint(config.model, config.device)
        return model
    model = create_model()
    model.to(config.device)
    return model


def _open_progress_writer(path: str | None):
    if not path:
        return None
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    return open(path, "w", encoding="utf-8")


def _train_deck_pipeline(
    model,
    deck_key: str,
    deck_seed: int,
    config: DeepTrainingConfig,
    emit: Callable[[dict[str, Any]], None],
    total_done: int,
    total_training_games: int,
) -> tuple[dict[str, Any], int]:
    """Run the full bootstrap + self-play + eval pipeline for one deck."""
    bootstrap_games = max(0, int(config.bootstrap_games))
    self_play_games = max(0, int(config.games))
    eval_games = max(0, int(config.eval_games))
    max_steps = max(20, int(config.max_steps))

    emit({
        "type": "deck_started",
        "deck": deck_key,
        "seed": deck_seed,
        "target_games": self_play_games,
        "bootstrap_games": bootstrap_games,
        "eval_games": eval_games,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    buffer = ReplayBuffer(capacity=50000, seed=deck_seed)

    bootstrap = collect_bootstrap_examples(
        deck_key, bootstrap_games, deck_seed, max_steps=max_steps,
    )
    buffer.extend(bootstrap)
    total_done += bootstrap_games
    emit({
        "type": "bootstrap_finished",
        "deck": deck_key,
        "games_played": bootstrap_games,
        "examples": len(bootstrap),
        "buffer_size": buffer.size,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    bootstrap_result = _train_examples(
        model, list(buffer), device=config.device,
        learning_rate=config.learning_rate,
        epochs=config.bootstrap_epochs,
        batch_size=config.batch_size,
    )
    emit({
        "type": "train_phase_finished",
        "deck": deck_key, "phase": "bootstrap",
        **bootstrap_result,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    wins = losses = draws = 0
    score_total = 0.0
    for game_idx in range(self_play_games):
        winner, score, examples = _play_model_game(
            model, deck_key,
            deck_seed + 500_000 + game_idx * 113,
            device=config.device, max_steps=max_steps, record=True,
        )
        buffer.extend(examples)
        score_total += score
        if winner == 0:
            wins += 1
        elif winner == 1:
            losses += 1
        else:
            draws += 1
        total_done += 1
        games_played = game_idx + 1
        emit({
            "type": "self_play_game_finished",
            "deck": deck_key, "game": games_played,
            "target_games": self_play_games, "winner": winner,
            "score": round(float(score), 3),
            "stats": {"wins": wins, "losses": losses, "draws": draws},
            "win_rate": round(wins / max(1, games_played), 4),
            "avg_score": round(score_total / max(1, games_played), 3),
            "examples": len(examples),
            "buffer_size": buffer.size,
            "total_games_played": total_done,
            "total_training_games": total_training_games,
        })

    self_play_result = _train_examples(
        model, list(buffer), device=config.device,
        learning_rate=config.learning_rate * 0.5,
        epochs=config.self_play_epochs,
        batch_size=config.batch_size,
    )
    emit({
        "type": "train_phase_finished",
        "deck": deck_key, "phase": "self_play",
        **self_play_result,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    eval_result = evaluate_model(
        model, deck_key, deck_seed + 900_000, eval_games,
        device=config.device, max_steps=max_steps,
    )
    total_done += eval_games
    eval_win_rate = 0.0
    if eval_games > 0:
        eval_win_rate = round(float(eval_result.get("wins", 0)) / max(1, eval_games), 4)
    emit({
        "type": "eval_finished",
        "deck": deck_key, "eval": eval_result, "win_rate": eval_win_rate,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })

    stats = {"wins": wins, "losses": losses, "draws": draws}
    summary = {
        "bootstrap": bootstrap_result,
        "self_play": self_play_result,
        "self_play_stats": stats,
        "eval": eval_result,
    }
    emit({
        "type": "deck_finished",
        "deck": deck_key, "training_games": self_play_games,
        "stats": stats, "eval": eval_result,
        "total_games_played": total_done,
        "total_training_games": total_training_games,
    })
    return summary, total_done


def run_deep_training(
    config: DeepTrainingConfig,
    progress_callback: ProgressCallback | None = None,
) -> dict[str, Any]:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for deep-learning AI training.")
    _ensure_cards_loaded()
    assert torch is not None

    writer = _open_progress_writer(config.progress_jsonl)

    def emit(event: dict[str, Any]) -> None:
        event = dict(event)
        event.setdefault("timestamp", time.time())
        if progress_callback:
            progress_callback(event)
        if writer:
            writer.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
            writer.flush()

    deck_keys = _deck_keys(config.deck)
    started = time.time()
    train_summary: dict[str, Any] = {}
    bootstrap_games = max(0, int(config.bootstrap_games))
    self_play_games = max(0, int(config.games))
    eval_games = max(0, int(config.eval_games))
    total_training_games = (bootstrap_games + self_play_games + eval_games) * len(deck_keys)
    total_done = 0
    model_paths: dict[str, str] = {}

    try:
        emit({
            "type": "run_started",
            "trainer": "rl_ai",
            "deck": config.deck,
            "deck_keys": deck_keys,
            "games_per_deck": self_play_games,
            "bootstrap_games": bootstrap_games,
            "eval_games": eval_games,
            "workers": int(config.workers),
            "device": config.device,
            "max_steps": max(20, int(config.max_steps)),
            "total_training_games": total_training_games,
        })

        for offset, deck_key in enumerate(deck_keys):
            deck_seed = config.seed + offset * 1009

            # Each deck gets its own model to avoid catastrophic forgetting.
            model = _load_or_create_model(config)
            model.to(config.device)

            deck_summary, total_done = _train_deck_pipeline(
                model, deck_key, deck_seed, config, emit,
                total_done, total_training_games,
            )
            train_summary[deck_key] = deck_summary

            output_path = config.output or _output_path_for_deck(deck_key)
            metadata = {
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "deck": deck_key,
                "games": self_play_games,
                "bootstrap_games": bootstrap_games,
                "eval_games": eval_games,
                "workers": int(config.workers),
                "trainer": "bootstrap_plus_policy_gradient_v1",
                "summary": {deck_key: deck_summary},
            }
            save_checkpoint(output_path, model, metadata)
            model_paths[deck_key] = output_path
            sidecar = os.path.splitext(output_path)[0] + ".json"
            with open(sidecar, "w", encoding="utf-8") as fh:
                json.dump({"model_path": output_path, "metadata": metadata}, fh,
                          ensure_ascii=False, indent=2, sort_keys=True)

        payload = {
            "model_paths": model_paths,
            "metadata": {
                "created_at": int(time.time()),
                "elapsed_seconds": round(time.time() - started, 3),
                "deck": config.deck,
                "deck_keys": deck_keys,
                "games": self_play_games,
                "bootstrap_games": bootstrap_games,
                "eval_games": eval_games,
                "workers": int(config.workers),
                "trainer": "bootstrap_plus_policy_gradient_v1",
                "summary": train_summary,
            },
        }
        emit({
            "type": "run_finished",
            "model_paths": model_paths,
            "model_count": len(deck_keys),
            "total_games_played": total_done,
            "total_training_games": total_training_games,
            "elapsed_seconds": round(time.time() - started, 3),
        })
        return payload
    except Exception as exc:
        emit({"type": "error", "message": str(exc)})
        raise
    finally:
        if writer:
            writer.close()

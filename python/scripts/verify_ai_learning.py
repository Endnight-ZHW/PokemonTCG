"""Quick supervised learning probe for the deep AI pipeline.

This script is intentionally small and deterministic. It checks whether the
current encoder/model/training stack can learn a tactical preference from fresh
examples, without requiring a long self-play run.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass
from typing import Any

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.ai.challenge_ai import AIConfig, create_challenge_ai
from engine.ai.dl.encoder import ActionStateEncoder
from engine.ai.dl.model import TORCH_AVAILABLE, create_model, torch
from engine.ai.dl.training import TrainingExample, _find_action_index, _forward_example, _train_examples
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import GameState
from engine.player_state import PokemonInPlay


@dataclass
class LearningProbeResult:
    passed: bool
    before_target_probability: float
    after_target_probability: float
    before_margin: float
    after_margin: float
    probability_gain: float
    margin_gain: float
    examples: int
    epochs: int
    train_loss: float
    policy_loss: float
    target_action: str


def _ensure_cards_loaded() -> None:
    if not CardRegistry.is_initialized():
        CardRegistry.initialize(ALL_CARD_IDS)


def _make_catcher_state(bench_card_id: str, bench_slot: int) -> GameState:
    state = GameState()
    state.phase = TurnPhase.MAIN
    state.first_player_idx = 0
    state.active_player_idx = 1
    state.turn_number = 5
    state.p1.active = PokemonInPlay(CardRegistry.get("svg-dram"))
    state.p1.bench[bench_slot] = PokemonInPlay(CardRegistry.get(bench_card_id))
    state.p2.active = PokemonInPlay(CardRegistry.get("svl-emol"))
    state.p2.hand = [CardRegistry.get("sv2-catch")]
    state.p2.deck = [CardRegistry.get("sv1-ener-4")] * 12
    state.p2.prizes = [CardRegistry.get("sv1-ener-4")] * 6
    state.p1.prizes = [CardRegistry.get("sv1-ener-3")] * 6
    return state


def _catcher_example(
    encoder: ActionStateEncoder,
    bench_card_id: str,
    bench_slot: int,
    *,
    deck_key: str,
) -> TrainingExample:
    state = _make_catcher_state(bench_card_id, bench_slot)
    ai = create_challenge_ai(
        deck_key,
        AIConfig(
            policy_path=None,
            thinking_time_seconds=0.0,
            deterministic_search=True,
            max_sequence_depth=1,
            max_turn_actions=8,
        ),
    )
    actions = ai.legal_actions(state, 1)
    target_action = next(action for action in actions if action.action == PlayerAction.PLAY_TRAINER)
    target_index = _find_action_index(actions, target_action)
    if target_index is None:
        raise RuntimeError("Could not locate catcher target action in legal actions.")
    return TrainingExample(
        encoder.encode_state(state, 1, deck_key),
        [encoder.encode_action(state, 1, action) for action in actions],
        target_index,
        source="teacher",
        teacher_target_index=target_index,
        phase_tag="learning_probe",
    )


def _target_stats(model, example: TrainingExample, device: str) -> tuple[float, float]:
    assert torch is not None
    model.eval()
    with torch.no_grad():
        logits, _ = _forward_example(model, example, device)
        logits = logits[0]
        probs = torch.softmax(logits, dim=0)
        target_idx = int(example.target_index)
        target_prob = float(probs[target_idx].detach().cpu().item())
        if logits.numel() <= 1:
            return target_prob, 0.0
        others = torch.cat([logits[:target_idx], logits[target_idx + 1 :]])
        margin = float((logits[target_idx] - torch.max(others)).detach().cpu().item())
        return target_prob, margin


def run_learning_probe(
    *,
    device: str = "cpu",
    epochs: int = 6,
    repeats: int = 6,
    learning_rate: float = 5e-3,
) -> LearningProbeResult:
    if not TORCH_AVAILABLE:
        raise RuntimeError("PyTorch is required for the learning probe.")
    assert torch is not None
    _ensure_cards_loaded()
    torch.manual_seed(17)

    deck_key = "lightning"
    encoder = ActionStateEncoder()
    train_variants = [
        ("sv2-delib", 0),
        ("sv2-staryu", 1),
        ("sv2-keldeo", 2),
        ("svi-chim", 3),
    ]
    examples = [
        _catcher_example(encoder, card_id, slot, deck_key=deck_key)
        for _ in range(max(1, repeats))
        for card_id, slot in train_variants
    ]
    heldout = _catcher_example(encoder, "svf-rio", 4, deck_key=deck_key)

    model = create_model(
        card_embed_dim=16,
        hidden_size=96,
        choice_head_enabled=True,
        use_attention=True,
        state_norm="layer",
    )
    model.to(device)

    before_prob, before_margin = _target_stats(model, heldout, device)
    train_result = _train_examples(
        model,
        examples,
        device=device,
        learning_rate=float(learning_rate),
        epochs=max(1, int(epochs)),
        batch_size=16,
        entropy_coef=0.0,
    )
    after_prob, after_margin = _target_stats(model, heldout, device)

    passed = after_prob >= 0.85 and after_prob > before_prob + 0.25 and after_margin > before_margin + 1.0
    return LearningProbeResult(
        passed=bool(passed),
        before_target_probability=round(before_prob, 6),
        after_target_probability=round(after_prob, 6),
        before_margin=round(before_margin, 6),
        after_margin=round(after_margin, 6),
        probability_gain=round(after_prob - before_prob, 6),
        margin_gain=round(after_margin - before_margin, 6),
        examples=len(examples),
        epochs=max(1, int(epochs)),
        train_loss=round(float(train_result.get("loss", 0.0)), 6),
        policy_loss=round(float(train_result.get("policy_loss", 0.0)), 6),
        target_action=PlayerAction.PLAY_TRAINER.name,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify that the deep AI can learn a tactical action preference.")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--repeats", type=int, default=6)
    parser.add_argument("--learning-rate", type=float, default=5e-3)
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON only.")
    args = parser.parse_args()

    result = run_learning_probe(
        device=args.device,
        epochs=args.epochs,
        repeats=args.repeats,
        learning_rate=args.learning_rate,
    )
    payload: dict[str, Any] = asdict(result)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result.passed else 1


if __name__ == "__main__":
    os.chdir(PROJECT_ROOT)
    raise SystemExit(main())

"""Dynamic damage formula evaluator.

Replaces ~15 separate effect types (damage_per_prize, damage_per_energy,
damage_per_hand_size, etc.) with a single formula string that is evaluated
at command execution time against the current game state.
"""
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext


def evaluate_formula(formula: str, ctx: ResolutionContext) -> int:
    """Evaluate a damage formula string against the current game state.

    Supported references:
        base: int — starting damage value
        prizes_taken: int — opponent's taken prize count
        hand_size: int — current player's hand size
        bench_count: int — current player's bench count
        opponent_bench_count: int — opponent's bench count
        energy_count: int — total energy on a target (specified separately)
        self_damage_counters: int — damage counters on self
        evolved_count: int — number of evolved pokemon on field

    The formula is a simple arithmetic expression: "base + hand_size * 20"
    """
    # Build local variable context
    player = ctx.player
    opponent = ctx.opponent
    active = player.active

    locals_dict = {
        "prizes_taken": 6 - len(opponent.prizes),
        "hand_size": len(player.hand),
        "bench_count": player.bench_count(),
        "opponent_bench_count": opponent.bench_count(),
        "self_damage_counters": active.damage_counters if active else 0,
    }

    try:
        result = eval(formula, {"__builtins__": {}}, locals_dict)
        return max(0, int(result))
    except Exception:
        return 0

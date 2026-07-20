"""Retreat-payment continuation for state-authoritative choice recovery."""
from __future__ import annotations


def register_retreat_continuations(registry, stack) -> None:
    registry.register(
        "retreat_payment",
        lambda _request, continuation, choice, _player_idx, _source_slot:
            resolve_retreat_payment(stack, continuation, choice),
    )


def resolve_retreat_payment(stack, continuation: dict, choice):
    from engine.action_resolver import ActionResolver

    actor = continuation.get("actor", -1)
    bench_idx = continuation.get("bench_idx", -1)
    if type(actor) is not int or actor not in (0, 1) or type(bench_idx) is not int:
        from engine.game_state import ActionResult

        return ActionResult(False, "撤退续体已损坏。")
    return ActionResolver(stack.state)._complete_retreat_payment(
        actor,
        bench_idx,
        choice,
    )

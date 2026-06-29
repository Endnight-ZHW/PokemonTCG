"""Continuation registry wiring for ResolutionStack pending choices."""
from __future__ import annotations

from engine.commands.vm_registry import ContinuationRegistry
from engine.commands.board_continuations import register_board_continuations
from engine.commands.coin_continuations import register_coin_continuations
from engine.commands.energy_continuations import register_energy_continuations
from engine.commands.hand_continuations import register_hand_continuations
from engine.commands.recovery_continuations import register_recovery_continuations
from engine.commands.search_continuations import register_search_continuations


def build_resolution_stack_continuation_registry(stack) -> ContinuationRegistry:
    """Build the continuation registry used by a ResolutionStack instance."""
    registry = ContinuationRegistry()
    register_coin_continuations(registry, stack)
    register_board_continuations(registry, stack)
    register_hand_continuations(registry, stack)
    register_recovery_continuations(registry, stack)
    register_search_continuations(registry, stack)
    register_energy_continuations(registry, stack)
    return registry

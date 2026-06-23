"""Command factory registry — replaces the giant if-elif-else chain.

Each effect_type string maps to a factory function that produces an ICommand.
New cards compose existing commands; new effect types require only a new
factory registration, not a new elif branch.
"""
from __future__ import annotations
from typing import Callable, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import ICommand
    from data.card_models import EffectDef

_command_registry: dict[str, Callable[..., ICommand]] = {}


def register_command(effect_type: str, factory: Callable[..., ICommand]):
    """Register a command factory for an effect type."""
    _command_registry[effect_type] = factory


def build_command(effect_def, **overrides) -> ICommand:
    """Build an ICommand from an EffectDef.

    Tries the DSL compiler first (primitives), then falls back to the
    legacy command registry. This allows gradual migration: primitives
    take priority, unported effect types use the old handlers.

    Args:
        effect_def: EffectDef object or dict with effect_type + params.
        **overrides: Additional kwargs passed to the factory.

    Returns:
        An ICommand ready to be pushed onto the ResolutionStack.
    """
    # Try DSL compiler first (primitives take priority)
    from engine.commands.dsl_compiler import compile_effect
    return compile_effect(effect_def, **overrides)


def build_commands(effect_defs: list, **overrides) -> list[ICommand]:
    """Build a list of ICommands from a list of EffectDefs."""
    return [build_command(e, **overrides) for e in effect_defs]


def is_registered(effect_type: str) -> bool:
    return effect_type in _command_registry

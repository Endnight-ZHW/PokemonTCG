"""Command factory facade for building native VM commands."""
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import ICommand
    from data.card_models import EffectDef


def build_command(effect_def: EffectDef | dict, **overrides) -> ICommand:
    """Build a native ICommand from an EffectDef or effect dictionary.

    Args:
        effect_def: EffectDef object or dict with effect_type + params.
        **overrides: Additional kwargs passed to the factory.

    Returns:
        An ICommand ready to be pushed onto the ResolutionStack.
    """
    from engine.commands.dsl_compiler import compile_effect
    return compile_effect(effect_def, **overrides)


def build_commands(effect_defs: list, **overrides) -> list[ICommand]:
    """Build a list of ICommands from a list of EffectDefs."""
    return [build_command(e, **overrides) for e in effect_defs]

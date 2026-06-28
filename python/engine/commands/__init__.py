"""Command pattern + Resolution Stack for card game effects.

Replaces the linear for-effect-in-effects loop and the giant if-elif-else
effect dispatcher with a LIFO resolution stack of ICommand objects.
"""
from engine.commands.base import ICommand, CommandResult, ResolutionContext
from engine.commands.resolution_stack import ResolutionStack
from engine.commands.registry import build_command

__all__ = [
    "ICommand", "CommandResult", "ResolutionContext",
    "ResolutionStack",
    "build_command",
]

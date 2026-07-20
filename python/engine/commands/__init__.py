"""Command pattern + Resolution Stack for card game effects.

Replaces the linear for-effect-in-effects loop and the giant if-elif-else
effect dispatcher with a LIFO resolution stack of ICommand objects.
"""
from engine.commands.base import ICommand, CommandResult, ResolutionContext
from engine.commands.resolution_stack import ResolutionStack
from engine.commands.registry import build_command
from engine.commands.vm_contract import VM_IR_VERSION
from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS
from engine.commands.vm_interpreter import ResolutionResult, VMInterpreter
from engine.commands.vm_registry import CommandRegistry, ContinuationRegistry

__all__ = [
    "ICommand", "CommandResult", "ResolutionContext",
    "ResolutionStack",
    "ResolutionResult",
    "build_command",
    "VM_IR_VERSION",
    "VM_COMMAND_DESCRIPTORS",
    "VMInterpreter",
    "CommandRegistry",
    "ContinuationRegistry",
]

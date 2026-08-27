"""Card IR authoring contracts; execution lives in ``ptcg_core``."""

from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS
from engine.commands.ir import (
    CommandSpec,
    compile_effect_to_spec,
    compile_effects_to_payload,
    compile_effects_to_specs,
)
from engine.commands.vm_contract import VM_IR_VERSION

__all__ = [
    "CommandSpec",
    "VM_COMMAND_DESCRIPTORS",
    "VM_IR_VERSION",
    "compile_effect_to_spec",
    "compile_effects_to_payload",
    "compile_effects_to_specs",
]

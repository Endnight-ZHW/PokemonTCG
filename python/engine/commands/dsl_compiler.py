"""DSL Compiler — translates EffectDef data into atomic primitive Commands.

This is the bridge between existing card effect data (effect_type + params)
and the new atomic primitives. Effect types must be explicitly registered as
native primitives; unknown effects fail instead of falling back to legacy
effect dispatch.
"""
from __future__ import annotations
from typing import Callable, TYPE_CHECKING

from engine.commands.ir import (
    CommandSpec,
    compile_effect_to_spec,
    compile_effects_to_payload,
    compile_effects_to_specs,
    missing_ir_effect_types,
)
from engine.commands.dsl_compiler_combat import (
    COMBAT_COMMAND_FACTORIES,
    COMBAT_EFFECT_FACTORIES,
)
from engine.commands.dsl_compiler_control import (
    CONTROL_COMMAND_FACTORIES,
    CONTROL_EFFECT_FACTORIES,
)
from engine.commands.dsl_compiler_support import (
    SUPPORT_COMMAND_FACTORIES,
    SUPPORT_EFFECT_FACTORIES,
)
from engine.commands.trigger_commands import TRIGGER_COMMAND_FACTORIES
from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS
from engine.commands.vm_contract import validate_command_spec
from engine.commands.vm_registry import DEFAULT_COMMAND_REGISTRY

if TYPE_CHECKING:
    from engine.commands.base import ICommand
    from engine.commands.primitives_combat import DealDamage

# Registry: effect_type -> factory(parsed_params) -> ICommand
_primitives_registry: dict[str, Callable] = {}


def register_primitive(effect_type: str, factory: Callable):
    """Register a primitive compiler for an effect type."""
    _primitives_registry[effect_type] = factory


def register_command_op(effect_op: str, factory: Callable):
    """Register a VM op compiler for direct CommandSpec execution."""
    DEFAULT_COMMAND_REGISTRY.register(effect_op, factory)


def compile_effect(effect_def, **overrides) -> ICommand:
    """Compile a single EffectDef into a native ICommand.

    Args:
        effect_def: EffectDef object or dict with effect_type + params
        **overrides: passed through to the command factory
    """
    if hasattr(effect_def, 'effect_type'):
        etype = effect_def.effect_type
        params = dict(effect_def.params)
    elif isinstance(effect_def, dict):
        etype = effect_def.get("effect_type", "")
        params = dict(effect_def.get("params", {}))
    else:
        raise ValueError(f"Invalid effect_def: {effect_def}")

    factory = _primitives_registry.get(etype)
    if factory is not None:
        command = factory(params, **overrides)
        from engine.commands.continuation_state import tag_legacy_effect

        return tag_legacy_effect(command, etype, params)

    raise ValueError(f"No native command registered for effect_type={etype!r}")


def compile_effects(effect_defs: list, **overrides) -> list[ICommand]:
    """Compile a list of EffectDefs into ICommands."""
    return [compile_effect(e, **overrides) for e in effect_defs]


def compile_command_spec(spec) -> ICommand:
    """Compile a VM CommandSpec/dict directly into a native ICommand.

    This bypasses effect_type dispatch entirely for migrated atomic ops.
    """
    if isinstance(spec, CommandSpec):
        spec_payload = spec.to_dict()
    elif isinstance(spec, dict):
        spec_payload = dict(spec)
    else:
        raise ValueError(f"Invalid command spec: {spec!r}")

    op = str(spec_payload.get("op", "") or "")
    raw_args = spec_payload.get("args", {})
    if isinstance(raw_args, dict) and "effect_type" in raw_args:
        raise ValueError("VM command specs must not carry legacy effect_type args")

    if not DEFAULT_COMMAND_REGISTRY.supports_op(op):
        raise ValueError(f"No native ICommand registered for VM op={op!r}")
    spec_errors = validate_command_spec(
        spec_payload,
        supported_ops=set(DEFAULT_COMMAND_REGISTRY.supported_ops),
        descriptors=VM_COMMAND_DESCRIPTORS,
    )
    if spec_errors:
        raise ValueError("Invalid VM command spec: " + "; ".join(spec_errors))
    args = dict(spec_payload.get("args", {}))
    branches = dict(spec_payload.get("branches", {}))
    command = DEFAULT_COMMAND_REGISTRY.build(op, args, branches)
    from engine.commands.continuation_state import tag_command_spec

    return tag_command_spec(
        command,
        {"op": op, "args": args, "branches": branches},
    )


__all__ = [
    "CommandSpec",
    "compile_effect",
    "compile_effects",
    "compile_command_spec",
    "compile_effect_to_spec",
    "compile_effects_to_payload",
    "compile_effects_to_specs",
    "missing_ir_effect_types",
    "register_primitive",
    "register_command_op",
]


# ═══════════════════════════════════════════════════════
# Primitive Mappings
# ═══════════════════════════════════════════════════════


# Primitive mappings are intentionally explicit. Many release effects have
# card-specific prompts, failure semantics, logging, and discard ownership; add
# new effect types here only after parity tests prove equivalent behavior.
_EFFECT_TO_PRIMITIVE = {
    **COMBAT_EFFECT_FACTORIES,
    **SUPPORT_EFFECT_FACTORIES,
    **CONTROL_EFFECT_FACTORIES,
}


for etype, factory in _EFFECT_TO_PRIMITIVE.items():
    register_primitive(etype, factory)


def _register_foundational_command_ops() -> None:
    """Register current VM ops while the legacy branch remains as fallback."""

    command_factories = {
        **COMBAT_COMMAND_FACTORIES,
        **SUPPORT_COMMAND_FACTORIES,
        **CONTROL_COMMAND_FACTORIES,
        **TRIGGER_COMMAND_FACTORIES,
    }

    for op, factory in command_factories.items():
        register_command_op(op, factory)


_register_foundational_command_ops()

_descriptor_ops = frozenset(VM_COMMAND_DESCRIPTORS)
if DEFAULT_COMMAND_REGISTRY.supported_ops != _descriptor_ops:
    raise RuntimeError(
        "Python VM handlers and descriptors must be 1:1; "
        f"missing_handlers={sorted(_descriptor_ops - DEFAULT_COMMAND_REGISTRY.supported_ops)} "
        f"missing_descriptors={sorted(DEFAULT_COMMAND_REGISTRY.supported_ops - _descriptor_ops)}"
    )

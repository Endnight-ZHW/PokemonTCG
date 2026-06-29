"""Versioned VM command contract shared by Python export and runtimes."""
from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any

VM_IR_VERSION = 1
COMMAND_SPEC_KEYS = frozenset({"op", "args", "branches"})
BRANCH_KEYS = frozenset({
    "cost",
    "on_heads",
    "on_tails",
    "on_pay",
    "on_success",
    "on_fail",
    "on_failure",
})


def iter_command_specs(value: Any) -> Iterable[Mapping[str, Any]]:
    """Yield every VM command-shaped mapping in a nested value."""
    if isinstance(value, Mapping):
        if "op" in value:
            yield value
        for item in value.values():
            yield from iter_command_specs(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from iter_command_specs(item)


def validate_command_spec(
    spec: Mapping[str, Any],
    *,
    supported_ops: set[str] | frozenset[str] | None = None,
    path: str = "$",
) -> list[str]:
    """Return contract violations for one VM command spec and its branches."""
    errors: list[str] = []
    op = spec.get("op")
    if not isinstance(op, str) or not op:
        errors.append(f"{path}.op must be a non-empty string")
    elif supported_ops is not None and op not in supported_ops:
        errors.append(f"{path}.op is unsupported: {op}")

    args = spec.get("args", {})
    if not isinstance(args, Mapping):
        errors.append(f"{path}.args must be an object")
    elif "effect_type" in args:
        errors.append(f"{path}.args must not contain legacy effect_type")

    branches = spec.get("branches", {})
    if not isinstance(branches, Mapping):
        errors.append(f"{path}.branches must be an object")
        return errors

    for branch_name, branch_items in branches.items():
        if not isinstance(branch_name, str):
            errors.append(f"{path}.branches keys must be strings")
            continue
        if branch_name not in BRANCH_KEYS:
            errors.append(f"{path}.branches.{branch_name} is not a known branch key")
        if not isinstance(branch_items, list):
            errors.append(f"{path}.branches.{branch_name} must be an array")
            continue
        for index, item in enumerate(branch_items):
            if not isinstance(item, Mapping):
                errors.append(f"{path}.branches.{branch_name}[{index}] must be an object")
                continue
            errors.extend(validate_command_spec(
                item,
                supported_ops=supported_ops,
                path=f"{path}.branches.{branch_name}[{index}]",
            ))
    return errors


def assert_command_spec(
    spec: Mapping[str, Any],
    *,
    supported_ops: set[str] | frozenset[str] | None = None,
) -> None:
    """Raise ValueError when a VM command violates the shared contract."""
    errors = validate_command_spec(spec, supported_ops=supported_ops)
    if errors:
        raise ValueError("; ".join(errors))

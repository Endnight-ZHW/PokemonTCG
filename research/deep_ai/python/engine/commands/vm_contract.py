"""Versioned VM command contract shared by Python export and runtimes."""
from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any

from engine.commands.descriptors import VM_COMMAND_DESCRIPTORS

VM_IR_VERSION = 3
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
        # Formula AST nodes also use an ``op`` tag. Published VM instructions
        # always carry the command envelope, even when args/branches are empty.
        if "op" in value and ("args" in value or "branches" in value):
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
    descriptors: Mapping[str, Mapping[str, Any]] | None = None,
    execution_context: str | None = None,
    allow_internal: bool = True,
    path: str = "$",
) -> list[str]:
    """Return contract violations for one VM command spec and its branches."""
    errors: list[str] = []
    extra_keys = set(spec) - COMMAND_SPEC_KEYS
    if extra_keys:
        errors.append(f"{path} has unknown fields: {sorted(extra_keys)}")
    op = spec.get("op")
    if not isinstance(op, str) or not op:
        errors.append(f"{path}.op must be a non-empty string")
    elif supported_ops is not None and op not in supported_ops:
        errors.append(f"{path}.op is unsupported: {op}")

    descriptor_table = descriptors or VM_COMMAND_DESCRIPTORS
    descriptor = descriptor_table.get(op) if isinstance(op, str) else None
    if isinstance(op, str) and op and descriptor is None:
        errors.append(f"{path}.op has no command descriptor: {op}")
    elif descriptor is not None:
        contexts = descriptor.get("allowed_contexts", ())
        if execution_context is not None and execution_context not in contexts:
            errors.append(
                f"{path}.op is not allowed in {execution_context} context: {op}"
            )
        if not allow_internal and bool(descriptor.get("internal", False)):
            errors.append(f"{path}.op is internal and cannot appear in card data: {op}")

    args = spec.get("args", {})
    if not isinstance(args, Mapping):
        errors.append(f"{path}.args must be an object")
    elif "effect_type" in args:
        errors.append(f"{path}.args must not contain legacy effect_type")
    elif descriptor is not None:
        errors.extend(_validate_object_schema(
            args,
            descriptor.get("args_schema", {}),
            path=f"{path}.args",
        ))

    branches = spec.get("branches", {})
    if not isinstance(branches, Mapping):
        errors.append(f"{path}.branches must be an object")
        return errors

    if descriptor is not None:
        branch_schema = descriptor.get("branch_schema", {})
        allowed = set(branch_schema.get("allowed_keys", ()))
        unknown = set(branches) - allowed
        if unknown:
            errors.append(f"{path}.branches has unknown fields: {sorted(unknown)}")
        missing = set(branch_schema.get("required", ())) - set(branches)
        if missing:
            errors.append(f"{path}.branches is missing required fields: {sorted(missing)}")

    for branch_name, branch_items in branches.items():
        if not isinstance(branch_name, str):
            errors.append(f"{path}.branches keys must be strings")
            continue
        if descriptor is None and branch_name not in BRANCH_KEYS:
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
                descriptors=descriptor_table,
                execution_context=execution_context,
                allow_internal=allow_internal,
                path=f"{path}.branches.{branch_name}[{index}]",
            ))
    return errors


def _validate_object_schema(
    value: Mapping[str, Any],
    schema: Mapping[str, Any],
    *,
    path: str,
) -> list[str]:
    errors: list[str] = []
    properties = schema.get("properties", {})
    if not isinstance(properties, Mapping):
        return [f"{path} descriptor properties must be an object"]
    if schema.get("additional_properties") is not False:
        return [f"{path} descriptor must disable additional properties"]
    extra = set(value) - set(properties)
    if extra:
        errors.append(f"{path} has unknown fields: {sorted(extra)}")
    missing = set(schema.get("required", ())) - set(value)
    if missing:
        errors.append(f"{path} is missing required fields: {sorted(missing)}")
    for key, item in value.items():
        field_schema = properties.get(key)
        if not isinstance(field_schema, Mapping):
            continue
        errors.extend(_validate_field(item, field_schema, path=f"{path}.{key}"))
    return errors


def _validate_field(value: Any, schema: Mapping[str, Any], *, path: str) -> list[str]:
    expected = schema.get("type")
    types = list(expected) if isinstance(expected, list) else [expected]
    if not any(_matches_type(value, type_name) for type_name in types):
        return [f"{path} must have type {expected!r}"]
    if "enum" in schema and value not in schema["enum"]:
        return [f"{path} must be one of {schema['enum']!r}"]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            return [f"{path} must be >= {schema['minimum']}"]
        if "maximum" in schema and value > schema["maximum"]:
            return [f"{path} must be <= {schema['maximum']}"]
    if isinstance(value, list) and isinstance(schema.get("items"), Mapping):
        errors: list[str] = []
        for index, item in enumerate(value):
            errors.extend(_validate_field(
                item, schema["items"], path=f"{path}[{index}]"
            ))
        return errors
    return []


def _matches_type(value: Any, expected: Any) -> bool:
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "object":
        return isinstance(value, Mapping)
    if expected == "array":
        return isinstance(value, list)
    return False


def command_spec_validation_result(
    spec: Mapping[str, Any],
    **kwargs: Any,
) -> dict[str, Any]:
    """Structured, side-effect-free preflight used by tooling and runtimes."""
    errors = validate_command_spec(spec, **kwargs)
    return {
        "ok": not errors,
        "legal": not errors,
        "error_code": "" if not errors else "invalid_vm_spec",
        "message": "" if not errors else "; ".join(errors),
    }


def assert_command_spec(
    spec: Mapping[str, Any],
    *,
    supported_ops: set[str] | frozenset[str] | None = None,
) -> None:
    """Raise ValueError when a VM command violates the shared contract."""
    errors = validate_command_spec(spec, supported_ops=supported_ops)
    if errors:
        raise ValueError("; ".join(errors))

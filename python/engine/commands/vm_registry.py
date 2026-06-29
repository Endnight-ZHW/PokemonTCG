"""Small registries used by the VM interpreter compatibility layer."""
from __future__ import annotations

from collections.abc import Callable
from typing import Any


class CommandRegistry:
    """Registry for VM op -> command factory mappings."""

    def __init__(self) -> None:
        self._factories: dict[str, Callable[[dict[str, Any], dict[str, Any]], Any]] = {}

    def register(
        self,
        op: str,
        factory: Callable[[dict[str, Any], dict[str, Any]], Any],
    ) -> None:
        if not op:
            raise ValueError("VM op name must be non-empty")
        self._factories[op] = factory

    def supports(self, op: str) -> bool:
        return op in self._factories

    def supports_op(self, op: str) -> bool:
        return self.supports(op)

    @property
    def supported_ops(self) -> frozenset[str]:
        return frozenset(self._factories)

    def build(self, op: str, args: dict[str, Any], branches: dict[str, Any]):
        return self._factories[op](args, branches)

    def try_build(self, op: str, args: dict[str, Any], branches: dict[str, Any]):
        factory = self._factories.get(op)
        if factory is None:
            return None
        return factory(args, branches)


class ContinuationRegistry:
    """Registry for serializable pending-choice continuation handlers."""

    def __init__(self) -> None:
        self._handlers: dict[str, Callable[..., Any]] = {}

    def register(self, kind: str, handler: Callable[..., Any]) -> None:
        if not kind:
            raise ValueError("Continuation kind must be non-empty")
        self._handlers[kind] = handler

    def supports(self, kind: str) -> bool:
        return kind in self._handlers

    @property
    def supported_kinds(self) -> frozenset[str]:
        return frozenset(self._handlers)

    def dispatch(self, kind: str, *args):
        return self._handlers[kind](*args)


DEFAULT_COMMAND_REGISTRY = CommandRegistry()

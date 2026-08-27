"""Typed card-authoring model and deterministic Card IR v3 compiler.

Release definitions live in small element-oriented Python modules. Every
consumer crosses this immutable boundary before compiling VM commands, while
the generated JSON/Card IR v3 payload remains deterministic.
"""
from __future__ import annotations

import ast
from collections import defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from hashlib import sha256
import inspect
import json
from pathlib import Path
from types import MappingProxyType
from typing import Any

from engine.commands.descriptors import (
    VM_COMMAND_DESCRIPTORS,
    descriptor_export_payload,
)
from engine.commands.ir import (
    BRANCH_KEYS,
    OP_BY_EFFECT_TYPE,
    compile_effects_to_payload,
)
from engine.commands.vm_contract import VM_IR_VERSION, iter_command_specs


JsonScalar = None | bool | int | float | str
JsonValue = JsonScalar | tuple["JsonValue", ...] | Mapping[str, "JsonValue"]


def _freeze(value: Any) -> JsonValue:
    if isinstance(value, EffectSpec):
        return value
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, Mapping):
        return MappingProxyType({str(key): _freeze(item) for key, item in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    raise TypeError(f"Card DSL values must be JSON-shaped, got {type(value).__name__}")


def _thaw(value: Any) -> Any:
    if isinstance(value, EffectSpec):
        return value.to_authoring_dict()
    if isinstance(value, Mapping):
        return {str(key): _thaw(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_thaw(item) for item in value]
    return value


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return sha256(encoded).hexdigest()


@dataclass(frozen=True, slots=True)
class SourceLocation:
    path: str
    line: int
    column: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {"path": self.path, "line": self.line, "column": self.column}


@dataclass(frozen=True, slots=True)
class EffectSpec:
    effect_type: str
    params: Mapping[str, Any] = field(default_factory=dict)
    source: SourceLocation | None = None

    def __post_init__(self) -> None:
        if not self.effect_type or self.effect_type not in OP_BY_EFFECT_TYPE:
            raise ValueError(f"Unknown card effect type: {self.effect_type!r}")
        object.__setattr__(self, "params", _freeze(dict(self.params)))

    def to_authoring_dict(self) -> dict[str, Any]:
        return {
            "effect_type": self.effect_type,
            "params": _authoring_params(self.params),
        }


@dataclass(frozen=True, slots=True)
class EffectBlock:
    name: str
    effects: tuple[EffectSpec, ...] = ()
    trigger: str = ""
    text: str = ""


@dataclass(frozen=True, slots=True)
class CardEffectSpec:
    card_id: str
    attacks: tuple[EffectBlock, ...] = ()
    abilities: tuple[EffectBlock, ...] = ()
    trainer_effects: tuple[EffectSpec, ...] = ()
    energy_effects: tuple[Mapping[str, Any], ...] = ()
    source: SourceLocation | None = None

    def __post_init__(self) -> None:
        if not self.card_id:
            raise ValueError("Card DSL card_id must not be empty")
        object.__setattr__(
            self,
            "energy_effects",
            tuple(_freeze(dict(item)) for item in self.energy_effects),
        )

    def to_authoring_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {}
        if self.attacks:
            result["attacks"] = {
                block.name: {
                    "effects": [effect.to_authoring_dict() for effect in block.effects]
                }
                for block in self.attacks
            }
        if self.abilities:
            result["abilities"] = {
                block.name: {
                    "trigger": block.trigger,
                    **({"text": block.text} if block.text else {}),
                    "effects": [effect.to_authoring_dict() for effect in block.effects],
                }
                for block in self.abilities
            }
        if self.trainer_effects:
            rows = [effect.to_authoring_dict() for effect in self.trainer_effects]
            result["trainer_effect"] = rows[0] if len(rows) == 1 else rows
        if self.energy_effects:
            result["energy_effects"] = [_thaw(item) for item in self.energy_effects]
        return result


@dataclass(frozen=True, slots=True)
class SourceIndex:
    cards: Mapping[str, SourceLocation]
    effects: Mapping[str, Mapping[str, tuple[SourceLocation, ...]]]
    duplicate_card_ids: tuple[str, ...] = ()


def _caller_source(depth: int = 2) -> SourceLocation:
    frame = inspect.stack()[depth]
    path = Path(frame.filename).resolve()
    return SourceLocation(_relative_source_path(path), frame.lineno, 0)


def effect(effect_type: str, /, **params: Any) -> EffectSpec:
    """Create one typed effect at the caller's source location."""
    return EffectSpec(effect_type, params, _caller_source())


def attack(name: str, *effects: EffectSpec) -> EffectBlock:
    return EffectBlock(name=name, effects=tuple(effects))


def ability(
    name: str,
    *effects: EffectSpec,
    trigger: str = "",
    text: str = "",
) -> EffectBlock:
    return EffectBlock(name=name, effects=tuple(effects), trigger=trigger, text=text)


def card(
    card_id: str,
    *,
    attacks: Iterable[EffectBlock] = (),
    abilities: Iterable[EffectBlock] = (),
    trainer_effects: Iterable[EffectSpec] = (),
    energy_effects: Iterable[Mapping[str, Any]] = (),
) -> CardEffectSpec:
    return CardEffectSpec(
        card_id=card_id,
        attacks=tuple(attacks),
        abilities=tuple(abilities),
        trainer_effects=tuple(trainer_effects),
        energy_effects=tuple(energy_effects),
        source=_caller_source(),
    )


def _authoring_params(params: Mapping[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in params.items():
        if key in BRANCH_KEYS and isinstance(value, EffectSpec):
            result[key] = value.to_authoring_dict()
        elif key in BRANCH_KEYS and isinstance(value, tuple):
            result[key] = [
                item.to_authoring_dict() if isinstance(item, EffectSpec) else _thaw(item)
                for item in value
            ]
        else:
            result[key] = _thaw(value)
    return result


def _effect_from_mapping(
    raw: Mapping[str, Any],
    source_for_type,
) -> EffectSpec:
    effect_type = str(raw.get("effect_type", "") or "")
    params: dict[str, Any] = {}
    for key, value in dict(raw.get("params", {}) or {}).items():
        if key in BRANCH_KEYS and isinstance(value, Mapping) and value.get("effect_type"):
            params[key] = _effect_from_mapping(value, source_for_type)
        elif key in BRANCH_KEYS and isinstance(value, (list, tuple)):
            params[key] = tuple(
                _effect_from_mapping(item, source_for_type)
                if isinstance(item, Mapping) and item.get("effect_type")
                else item
                for item in value
            )
        else:
            params[key] = value
    return EffectSpec(effect_type, params, source_for_type(effect_type))


def card_specs_from_mappings(
    values: Mapping[str, Mapping[str, Any]],
    *,
    source_index: SourceIndex | None = None,
) -> dict[str, CardEffectSpec]:
    """Normalize authoring mappings into the immutable card model."""
    result: dict[str, CardEffectSpec] = {}
    for card_id, raw_value in values.items():
        raw = dict(raw_value or {})
        locations = (
            source_index.effects.get(card_id, {}) if source_index is not None else {}
        )
        cursors: defaultdict[str, int] = defaultdict(int)

        def source_for_type(effect_type: str) -> SourceLocation | None:
            rows = tuple(locations.get(effect_type, ()))
            index = cursors[effect_type]
            cursors[effect_type] += 1
            return rows[index] if index < len(rows) else None

        attack_blocks: list[EffectBlock] = []
        for name, block_value in dict(raw.get("attacks", {}) or {}).items():
            block = dict(block_value or {})
            attack_blocks.append(EffectBlock(
                name=str(name),
                effects=tuple(
                    _effect_from_mapping(item, source_for_type)
                    for item in block.get("effects", [])
                ),
            ))
        ability_blocks: list[EffectBlock] = []
        for name, block_value in dict(raw.get("abilities", {}) or {}).items():
            block = dict(block_value or {})
            ability_blocks.append(EffectBlock(
                name=str(name),
                effects=tuple(
                    _effect_from_mapping(item, source_for_type)
                    for item in block.get("effects", [])
                ),
                trigger=str(block.get("trigger", "") or ""),
                text=str(block.get("text", "") or ""),
            ))
        trainer_raw = raw.get("trainer_effect", [])
        if isinstance(trainer_raw, Mapping):
            trainer_raw = [trainer_raw]
        trainer_effects = tuple(
            _effect_from_mapping(item, source_for_type)
            for item in trainer_raw or []
        )
        result[str(card_id)] = CardEffectSpec(
            card_id=str(card_id),
            attacks=tuple(attack_blocks),
            abilities=tuple(ability_blocks),
            trainer_effects=trainer_effects,
            energy_effects=tuple(
                dict(item)
                for item in raw.get("energy_effects", [])
                if isinstance(item, Mapping)
            ),
            source=(
                source_index.cards.get(str(card_id))
                if source_index is not None else None
            ),
        )
    return result


def iter_effect_specs(value: CardEffectSpec) -> Iterable[EffectSpec]:
    def descend(item: EffectSpec) -> Iterable[EffectSpec]:
        yield item
        for key in sorted(BRANCH_KEYS):
            branch = item.params.get(key)
            if isinstance(branch, EffectSpec):
                yield from descend(branch)
            elif isinstance(branch, tuple):
                for nested in branch:
                    if isinstance(nested, EffectSpec):
                        yield from descend(nested)

    for block in (*value.attacks, *value.abilities):
        for item in block.effects:
            yield from descend(item)
    for item in value.trainer_effects:
        yield from descend(item)


def compile_card_ir_v3(
    specs: Mapping[str, CardEffectSpec],
    *,
    all_card_ids: Iterable[str] = (),
) -> dict[str, Any]:
    """Compile typed specs to deterministic, source-mapped Card IR v3."""
    ids = sorted(set(str(card_id) for card_id in all_card_ids) | set(specs))
    cards: dict[str, Any] = {}
    used_ops: set[str] = set()
    effect_count = 0
    command_count = 0
    source_mapped = 0

    def compile_block(block: EffectBlock, pointer: str) -> dict[str, Any]:
        nonlocal effect_count, command_count, source_mapped
        commands = compile_effects_to_payload(block.effects)
        command_count += sum(1 for _ in iter_command_specs(commands))
        used_ops.update(
            str(command.get("op", ""))
            for command in iter_command_specs(commands)
        )
        sources = []
        for index, item in enumerate(block.effects):
            nested = list(_iter_nested_effects(item))
            effect_count += len(nested)
            source_mapped += sum(1 for effect_row in nested if effect_row.source)
            for nested_index, effect_row in enumerate(nested):
                sources.append({
                    "path": f"{pointer}/effects/{index}/{nested_index}",
                    "effect_type": effect_row.effect_type,
                    "op": OP_BY_EFFECT_TYPE[effect_row.effect_type],
                    "source": effect_row.source.to_dict() if effect_row.source else None,
                })
        return {
            "trigger": block.trigger,
            "text": block.text,
            "commands": commands,
            "source_map": sources,
        }

    for card_id in ids:
        spec = specs.get(card_id)
        if spec is None:
            cards[card_id] = {
                "source": None,
                "attacks": {},
                "abilities": {},
                "trainer_commands": [],
                "energy_effects": [],
                "source_map": [],
            }
            continue
        attack_rows = {
            block.name: compile_block(block, f"/cards/{card_id}/attacks/{block.name}")
            for block in spec.attacks
        }
        ability_rows = {
            block.name: compile_block(block, f"/cards/{card_id}/abilities/{block.name}")
            for block in spec.abilities
        }
        trainer_block = EffectBlock("trainer", spec.trainer_effects)
        trainer = compile_block(trainer_block, f"/cards/{card_id}/trainer")
        cards[card_id] = {
            "source": spec.source.to_dict() if spec.source else None,
            "attacks": attack_rows,
            "abilities": ability_rows,
            "trainer_commands": trainer["commands"],
            "energy_effects": [_thaw(item) for item in spec.energy_effects],
            "source_map": trainer["source_map"],
        }

    descriptor_payload = descriptor_export_payload(VM_IR_VERSION)
    payload: dict[str, Any] = {
        "format": "ptcg_card_ir/3",
        "vm_ir_version": VM_IR_VERSION,
        "descriptor_digest": descriptor_payload["descriptor_digest"],
        "card_count": len(ids),
        "authored_card_count": len(specs),
        "effect_count": effect_count,
        "command_count": command_count,
        "source_mapped_effect_count": source_mapped,
        "source_map_coverage": 1.0 if effect_count == 0 else source_mapped / effect_count,
        "used_vm_ops": sorted(used_ops),
        "unused_vm_ops": sorted(set(VM_COMMAND_DESCRIPTORS) - used_ops),
        "cards": cards,
    }
    payload["content_fingerprint"] = _canonical_sha256(payload)
    payload["contract_fingerprint"] = _canonical_sha256({
        "native_abi_version": 2,
        "protocol_version": 6,
        "action_schema_version": 4,
        "choice_view_schema_version": 2,
        "snapshot_schema_version": 3,
        "journal_format_version": 1,
        "format": payload["format"],
        "vm_ir_version": payload["vm_ir_version"],
        "descriptor_digest": payload["descriptor_digest"],
        "content_fingerprint": payload["content_fingerprint"],
    })
    return payload


def _iter_nested_effects(value: EffectSpec) -> Iterable[EffectSpec]:
    yield value
    for key in sorted(BRANCH_KEYS):
        branch = value.params.get(key)
        if isinstance(branch, EffectSpec):
            yield from _iter_nested_effects(branch)
        elif isinstance(branch, tuple):
            for nested in branch:
                if isinstance(nested, EffectSpec):
                    yield from _iter_nested_effects(nested)


def discover_card_sources(cards_root: Path) -> SourceIndex:
    """Read effect locations from the single-source ``CARDS`` modules."""
    cards: dict[str, SourceLocation] = {}
    effects: dict[str, dict[str, list[SourceLocation]]] = {}
    duplicates: set[str] = set()
    for path in sorted(cards_root.glob("*.py")):
        if path.name == "__init__.py":
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in tree.body:
            if not isinstance(node, (ast.Assign, ast.AnnAssign)):
                continue
            value = node.value
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if not any(
                isinstance(target, ast.Name) and target.id == "CARDS"
                for target in targets
            ):
                continue
            if not isinstance(value, ast.Dict):
                continue
            for key_node, card_node in zip(value.keys, value.values):
                card_id = _literal_string(key_node)
                if not card_id:
                    continue
                location = SourceLocation(
                    _relative_source_path(path.resolve()),
                    int(getattr(key_node, "lineno", 0)),
                    int(getattr(key_node, "col_offset", 0)),
                )
                if card_id in cards:
                    duplicates.add(card_id)
                cards[card_id] = location
                by_type: defaultdict[str, list[SourceLocation]] = defaultdict(list)
                for effect_node in _effect_dict_nodes(card_node):
                    effect_type = _dict_string_field(effect_node, "effect_type")
                    if effect_type:
                        by_type[effect_type].append(SourceLocation(
                            location.path,
                            int(getattr(effect_node, "lineno", location.line)),
                            int(getattr(effect_node, "col_offset", 0)),
                        ))
                effects[card_id] = dict(by_type)
    return SourceIndex(
        cards=MappingProxyType(cards),
        effects=MappingProxyType({
            card_id: MappingProxyType({
                effect_type: tuple(rows)
                for effect_type, rows in by_type.items()
            })
            for card_id, by_type in effects.items()
        }),
        duplicate_card_ids=tuple(sorted(duplicates)),
    )


def _effect_dict_nodes(node: ast.AST) -> Iterable[ast.Dict]:
    if isinstance(node, ast.Dict) and _dict_string_field(node, "effect_type"):
        yield node
    for child in ast.iter_child_nodes(node):
        yield from _effect_dict_nodes(child)


def _dict_string_field(node: ast.Dict, field_name: str) -> str:
    for key, value in zip(node.keys, node.values):
        if _literal_string(key) == field_name:
            return _literal_string(value)
    return ""


def _literal_string(node: ast.AST | None) -> str:
    return str(node.value) if isinstance(node, ast.Constant) and isinstance(node.value, str) else ""


def _relative_source_path(path: Path) -> str:
    repo_root = Path(__file__).resolve().parents[2]
    try:
        return path.relative_to(repo_root).as_posix()
    except ValueError:
        return path.as_posix()


__all__ = [
    "SourceLocation",
    "EffectSpec",
    "EffectBlock",
    "CardEffectSpec",
    "SourceIndex",
    "effect",
    "attack",
    "ability",
    "card",
    "card_specs_from_mappings",
    "iter_effect_specs",
    "compile_card_ir_v3",
    "discover_card_sources",
]

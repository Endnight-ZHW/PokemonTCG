"""Serializable action and choice contracts shared by rules, AI, UI, and tooling."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from engine.enums import PlayerAction


ACTION_SCHEMA_VERSION = 4
RULES_SCHEMA_VERSION = 5

_TERMINAL_ACTION_KINDS = frozenset({
    "DECLARE_ATTACK",
    "END_TURN",
    "SETUP_DONE",
})


@dataclass(frozen=True)
class CardRef:
    player: int
    zone: str
    index: int
    card_id: str

    @property
    def ref_id(self) -> str:
        return f"card:{self.player}:{self.zone}:{self.index}:{self.card_id}"


@dataclass(frozen=True)
class PokemonRef:
    player: int
    slot: str
    card_id: str

    @property
    def ref_id(self) -> str:
        return f"pokemon:{self.player}:{self.slot}:{self.card_id}"


@dataclass(frozen=True)
class SlotRef:
    """Reference to an empty board destination rather than a Pokemon."""

    player: int
    slot: str

    @property
    def ref_id(self) -> str:
        return f"slot:{self.player}:{self.slot}"


@dataclass(frozen=True)
class AttachmentRef:
    player: int
    slot: str
    attachment_type: str
    index: int
    card_id: str

    @property
    def ref_id(self) -> str:
        return (
            f"attachment:{self.player}:{self.slot}:{self.attachment_type}:"
            f"{self.index}:{self.card_id}"
        )


EntityRef = CardRef | PokemonRef | SlotRef | AttachmentRef


def resolve_pokemon_ref(state, ref: PokemonRef):
    if (
        not isinstance(ref, PokemonRef)
        or type(ref.player) is not int
        or ref.player not in (0, 1)
        or not isinstance(ref.slot, str)
        or not isinstance(ref.card_id, str)
    ):
        return None
    pokemon = state.get_player(ref.player).get_pokemon(ref.slot)
    if pokemon is None:
        return None
    if ref.card_id and getattr(pokemon.card, "api_id", "") != ref.card_id:
        return None
    return pokemon


@dataclass(frozen=True)
class ChoiceOption:
    option_id: str
    label: str
    ref: EntityRef | None = None


@dataclass
class ChoiceView:
    request_id: str
    base_revision: int
    request_type: str
    player: int
    prompt: str
    options: tuple[ChoiceOption, ...] = ()
    min_select: int = 1
    max_select: int = 1
    allow_duplicates: bool = False
    can_cancel: bool = False
    presentation: dict[str, Any] = field(default_factory=dict)
    schema_version: int = 2


@dataclass(frozen=True)
class ChoiceResponse:
    request_id: str
    option_ids: tuple[str, ...] = ()
    cancelled: bool = False


@dataclass(frozen=True)
class GameAction:
    """Strict Action v4 DTO used by Python tooling and native bindings."""

    kind: PlayerAction | str
    payload: dict[str, Any] = field(default_factory=dict)
    actor: int = -1
    source: EntityRef | None = None
    target: EntityRef | None = None
    action_id: str = ""
    base_revision: int = -1
    schema_version: int = ACTION_SCHEMA_VERSION

    @property
    def kind_name(self) -> str:
        return (
            self.kind.name
            if isinstance(self.kind, PlayerAction)
            else str(self.kind)
        )

    @property
    def terminal(self) -> bool:
        return self.kind_name in _TERMINAL_ACTION_KINDS

    def with_actor(self, actor: int) -> "GameAction":
        return GameAction(
            kind=self.kind,
            payload=dict(self.payload),
            actor=actor,
            source=self.source,
            target=self.target,
            action_id=self.action_id,
            base_revision=self.base_revision,
            schema_version=self.schema_version,
        )

    @property
    def signature(self) -> tuple:
        return (
            self.kind_name,
            _freeze(self.payload),
            _freeze(self.source),
            _freeze(self.target),
        )

    def hand_index(self, default: int = -1) -> int:
        if isinstance(self.source, CardRef) and self.source.zone == "hand":
            return int(self.source.index)
        return default

    def source_slot(self, default: str = "") -> str:
        if isinstance(self.source, (PokemonRef, SlotRef, AttachmentRef)):
            return str(self.source.slot)
        return default

    def target_slot(self, default: str = "") -> str:
        if isinstance(self.target, (PokemonRef, SlotRef, AttachmentRef)):
            return str(self.target.slot)
        return default

    def primary_slot(self, default: str = "") -> str:
        source = self.source_slot()
        return source if source else self.target_slot(default)

    def bench_index(self, default: int = -1) -> int:
        slot = self.target_slot()
        if slot.startswith("bench_") and slot[6:].isdigit():
            return int(slot[6:])
        return default

    def attack_index(self, default: int = -1) -> int:
        value = self.payload.get("attack_index", default)
        return int(value) if type(value) is int else default

    def ability_name(self, default: str = "") -> str:
        value = self.payload.get("ability_name", default)
        return str(value) if isinstance(value, str) else default


@dataclass
class StepResult:
    success: bool
    message: str = ""
    pending_choice: ChoiceView | None = None
    events: tuple[dict[str, Any], ...] = ()
    winner: int | None = None
    terminal: bool = False
    error_code: str = ""


def _freeze(value: Any):
    if isinstance(value, (CardRef, PokemonRef, SlotRef, AttachmentRef)):
        return tuple(
            (field_name, _freeze(getattr(value, field_name)))
            for field_name in value.__dataclass_fields__
        )
    if isinstance(value, dict):
        return tuple(sorted((str(key), _freeze(item)) for key, item in value.items()))
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    if isinstance(value, set):
        return tuple(sorted(_freeze(item) for item in value))
    return value

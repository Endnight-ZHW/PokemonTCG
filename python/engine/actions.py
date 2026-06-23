"""Serializable action and choice contracts shared by rules, AI, UI, and network."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from engine.enums import PlayerAction


ACTION_SCHEMA_VERSION = 2
RULES_SCHEMA_VERSION = 2


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


EntityRef = CardRef | PokemonRef | AttachmentRef


def resolve_pokemon_ref(state, ref: PokemonRef):
    if not isinstance(ref, PokemonRef) or ref.player not in (0, 1):
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
    value: Any = field(default=None, compare=False, repr=False)


@dataclass
class ChoiceRequest:
    request_id: str
    request_type: str
    player: int
    prompt: str
    options: tuple[ChoiceOption, ...] = ()
    min_select: int = 1
    max_select: int = 1
    allow_duplicates: bool = False
    can_cancel: bool = False
    metadata: dict[str, Any] = field(default_factory=dict)
    legacy_request: Any = field(default=None, compare=False, repr=False)


@dataclass(frozen=True)
class ChoiceResponse:
    request_id: str
    option_ids: tuple[str, ...] = ()
    cancelled: bool = False


@dataclass(frozen=True)
class GameAction:
    """A stable action contract.

    The first three fields intentionally match the old ``AIAction`` constructor
    so existing callers can migrate without a flag day.
    """

    action: PlayerAction | str
    params: dict[str, Any] = field(default_factory=dict)
    terminal: bool = False
    actor: int | None = None
    source: EntityRef | None = None
    target: EntityRef | None = None
    action_id: str = ""

    def with_actor(self, actor: int) -> "GameAction":
        return GameAction(
            self.action,
            dict(self.params),
            self.terminal,
            actor,
            self.source,
            self.target,
            self.action_id,
        )

    @property
    def signature(self) -> tuple:
        action_name = self.action.name if isinstance(self.action, PlayerAction) else str(self.action)
        return action_name, _freeze(self.params)


@dataclass
class StepResult:
    success: bool
    message: str = ""
    action_result: Any = None
    pending_choice: ChoiceRequest | None = None
    events: tuple[dict[str, Any], ...] = ()
    winner: int | None = None
    terminal: bool = False
    error_code: str = ""


def _freeze(value: Any):
    if isinstance(value, dict):
        return tuple(sorted((str(key), _freeze(item)) for key, item in value.items()))
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    if isinstance(value, set):
        return tuple(sorted(_freeze(item) for item in value))
    return value

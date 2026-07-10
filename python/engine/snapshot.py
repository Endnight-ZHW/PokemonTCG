"""Game state snapshot system for undo/redo and state rollback.

Captures the complete game state at a point in time. Supports:
- undo: restore the previous state
- redo: re-apply a reverted state
- Debugging: compare state snapshots
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, TYPE_CHECKING
import copy

if TYPE_CHECKING:
    from engine.game_state import GameState
    from engine.player_state import PlayerState, PokemonInPlay
    from data.card_models import Card


SNAPSHOT_SCHEMA_VERSION = 1


@dataclass
class PlayerSnapshot:
    """Serializable snapshot of a single player's state."""
    name: str
    hand_ids: list[str]           # card api_ids in hand order
    deck_ids: list[str]           # card api_ids in deck order (reversed: top is last)
    discard_ids: list[str]        # card api_ids in discard
    prize_ids: list[str]          # card api_ids in prizes
    active: Optional[PokemonSnapshot] = None
    bench: list[Optional[PokemonSnapshot]] = field(default_factory=lambda: [None]*5)
    supporter_played: bool = False
    energy_attached: bool = False
    retreated: bool = False
    stadium_played: bool = False
    stadium_used: bool = False
    healed: bool = False
    vstar_used: bool = False
    was_ko_by_attack: bool = False


@dataclass
class PokemonSnapshot:
    """Serializable snapshot of a single Pokemon in play."""
    card_id: str
    damage_counters: int = 0
    energy_card_ids: list[str] = field(default_factory=list)
    attached_tool_id: Optional[str] = None
    status_conditions: list[str] = field(default_factory=list)
    evolution_stack_ids: list[str] = field(default_factory=list)
    can_evolve_this_turn: bool = True
    placed_this_turn: bool = True
    used_abilities: list[str] = field(default_factory=list)
    damage_prevented: bool = False
    all_prevented: bool = False
    outgoing_damage_reduction: int = 0
    attack_locked: bool = False
    attack_locked_names: dict = field(default_factory=dict)
    dazzled: bool = False
    max_hp_modifiers: list[dict] = field(default_factory=list)
    paralyzed_since_turn: int = 0


@dataclass
class GameSnapshot:
    """Complete game state snapshot."""
    turn_number: int
    phase: str
    active_player_idx: int
    first_player_idx: int
    p1: PlayerSnapshot
    p2: PlayerSnapshot
    stadium_card_id: Optional[str] = None
    winner: Optional[int] = None
    apply_type_matchups: bool = False
    mulligan_bonus_given: list[int] = field(default_factory=list)
    pending_promotions: list[int] = field(default_factory=list)
    revision: int = 0
    choice_sequence: int = 0
    public_deck_keys: tuple[str | None, str | None] = (None, None)
    resolution_stack: dict = field(
        default_factory=lambda: {
            "frames": [],
            "pending_request": None,
            "sequence": 0,
            "context": {},
        }
    )
    event_stream: list[dict] = field(default_factory=list)
    mulligan_count: tuple[int, int] = (0, 0)
    extra_draws: tuple[int, int] = (0, 0)
    action_log: list[str] = field(default_factory=list)


class SnapshotManager:
    """Manages undo/redo history for game state.

    Usage:
        mgr = SnapshotManager()
        mgr.capture(state)          # take snapshot
        mgr.undo(state)             # restore previous
        mgr.redo(state)             # re-apply reverted
    """

    def __init__(self, max_history: int = 20):
        self._history: list[GameSnapshot] = []
        self._redo_stack: list[GameSnapshot] = []
        self._max = max_history

    def capture(self, state: GameState):
        """Take a snapshot and push onto history."""
        snap = snapshot_state(state)
        self._history.append(snap)
        self._redo_stack.clear()
        if len(self._history) > self._max:
            self._history.pop(0)

    def undo(self, state: GameState) -> bool:
        """Restore the previous snapshot. Returns True on success."""
        if len(self._history) < 1:
            return False
        current = snapshot_state(state)
        self._redo_stack.append(current)
        previous = self._history.pop()
        restore_state(state, previous)
        return True

    def redo(self, state: GameState) -> bool:
        """Re-apply a reverted snapshot. Returns True on success."""
        if not self._redo_stack:
            return False
        current = snapshot_state(state)
        self._history.append(current)
        next_state = self._redo_stack.pop()
        restore_state(state, next_state)
        return True

    def can_undo(self) -> bool:
        return len(self._history) > 0

    def can_redo(self) -> bool:
        return len(self._redo_stack) > 0

    def clear(self):
        self._history.clear()
        self._redo_stack.clear()


# ═══════════════════════════════════════════════════════
# Capture / Restore functions
# ═══════════════════════════════════════════════════════

def snapshot_state(state: GameState) -> GameSnapshot:
    """Capture the current game state into a serializable snapshot."""
    return GameSnapshot(
        turn_number=state.turn_number,
        phase=state.phase.name if hasattr(state.phase, 'name') else str(state.phase),
        active_player_idx=state.active_player_idx,
        first_player_idx=state.first_player_idx,
        p1=_snapshot_player(state.p1),
        p2=_snapshot_player(state.p2),
        stadium_card_id=state.stadium_card.api_id if state.stadium_card else None,
        winner=state.winner,
        apply_type_matchups=getattr(state, "apply_type_matchups", False),
        mulligan_bonus_given=sorted(state._mulligan_bonus_given),
        pending_promotions=list(state.pending_promotions),
        revision=getattr(state, "revision", 0),
        choice_sequence=getattr(state, "choice_sequence", 0),
        public_deck_keys=tuple(getattr(state, "public_deck_keys", (None, None))),
        resolution_stack=copy.deepcopy(
            getattr(
                state,
                "resolution_stack",
                {
                    "frames": [],
                    "pending_request": None,
                    "sequence": 0,
                    "context": {},
                },
            )
        ),
        event_stream=_snapshot_event_stream(state),
        mulligan_count=tuple(getattr(state, "mulligan_count", (0, 0))),
        extra_draws=tuple(getattr(state, "extra_draws", (0, 0))),
        action_log=list(getattr(state, "action_log", ())),
    )


def restore_state(
    state: GameState,
    snap: GameSnapshot,
    *,
    rebuild_event_bus: bool = True,
):
    """Restore game state from a snapshot."""
    from engine.enums import TurnPhase

    state.turn_number = snap.turn_number
    state.phase = TurnPhase[snap.phase]
    state.active_player_idx = snap.active_player_idx
    state.first_player_idx = snap.first_player_idx
    state.winner = snap.winner
    state.apply_type_matchups = snap.apply_type_matchups
    state.pending_promotions = list(snap.pending_promotions)
    state.revision = getattr(snap, "revision", 0)
    state.choice_sequence = getattr(snap, "choice_sequence", 0)
    state.public_deck_keys = tuple(
        getattr(snap, "public_deck_keys", (None, None))
    )
    state.mulligan_count = tuple(getattr(snap, "mulligan_count", (0, 0)))
    state.extra_draws = tuple(getattr(snap, "extra_draws", (0, 0)))
    state.action_log = list(getattr(snap, "action_log", ()))
    state.resolution_stack = copy.deepcopy(
        getattr(
            snap,
            "resolution_stack",
            {
                "frames": [],
                "pending_request": None,
                "sequence": 0,
                "context": {},
            },
        )
    )
    # Never retain a callback that closes over the state from before restore.
    # Serializable VM continuations are rebuilt on demand by GameEngine.
    state._pending_choice_runtime = None
    _restore_event_stream(state, getattr(snap, "event_stream", []))
    state._ko_from_attack = False
    state._mulligan_bonus_given = set(snap.mulligan_bonus_given)

    _restore_player(state.p1, snap.p1)
    _restore_player(state.p2, snap.p2)

    state.stadium_card = _lookup_card(snap.stadium_card_id) if snap.stadium_card_id else None
    if rebuild_event_bus:
        rebuild_state_event_bus(state)


def clone_state(state: GameState, *, rebuild_event_bus: bool = True) -> GameState:
    """Create a full GameState copy through the snapshot system."""
    from engine.game_state import GameState

    clone = GameState()
    try:
        restore_state(clone, snapshot_state(state), rebuild_event_bus=False)
        clone.action_log = list(state.action_log)
    except KeyError:
        # Tests, editors, and generated scenarios may contain cards that are
        # intentionally not registered globally. A deep copy keeps those
        # snapshots local instead of mutating CardRegistry with placeholders.
        clone = copy.deepcopy(state)
        clone._pending_choice_runtime = None
    if rebuild_event_bus:
        rebuild_state_event_bus(clone)
    return clone


def state_from_snapshot(snap: GameSnapshot, *, rebuild_event_bus: bool = True) -> GameState:
    """Create a GameState from an existing snapshot."""
    from engine.game_state import GameState

    state = GameState()
    restore_state(state, snap, rebuild_event_bus=False)
    if rebuild_event_bus:
        rebuild_state_event_bus(state)
    return state


def snapshot_to_dict(snap: GameSnapshot) -> dict:
    """Convert a GameSnapshot to a JSON-compatible dictionary."""
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "turn_number": int(snap.turn_number),
        "phase": str(snap.phase),
        "active_player_idx": int(snap.active_player_idx),
        "first_player_idx": int(snap.first_player_idx),
        "p1": _player_snapshot_to_dict(snap.p1),
        "p2": _player_snapshot_to_dict(snap.p2),
        "stadium_card_id": snap.stadium_card_id,
        "winner": snap.winner,
        "apply_type_matchups": bool(snap.apply_type_matchups),
        "mulligan_bonus_given": list(snap.mulligan_bonus_given),
        "pending_promotions": list(snap.pending_promotions),
        "revision": int(snap.revision),
        "choice_sequence": int(snap.choice_sequence),
        "public_deck_keys": list(snap.public_deck_keys),
        "resolution_stack": copy.deepcopy(snap.resolution_stack),
        "event_stream": copy.deepcopy(snap.event_stream),
        "mulligan_count": list(snap.mulligan_count),
        "extra_draws": list(snap.extra_draws),
        "action_log": list(snap.action_log),
    }


def snapshot_from_dict(data: dict) -> GameSnapshot:
    """Rebuild a GameSnapshot from snapshot_to_dict output."""
    if not isinstance(data, dict):
        raise ValueError("Snapshot payload must be an object")
    schema_version = data.get("schema_version", 0)
    if type(schema_version) is not int:
        raise ValueError("Snapshot schema_version is invalid")
    # Version 0 is the pre-schema JSON shape and remains readable. Future
    # versions require an explicit migration instead of partial interpretation.
    if schema_version not in (0, SNAPSHOT_SCHEMA_VERSION):
        raise ValueError(f"Unsupported snapshot schema version: {schema_version}")
    return GameSnapshot(
        turn_number=int(data.get("turn_number", 0)),
        phase=str(data.get("phase", "SETUP")),
        active_player_idx=int(data.get("active_player_idx", 0)),
        first_player_idx=int(data.get("first_player_idx", 0)),
        p1=_player_snapshot_from_dict(dict(data.get("p1", {}))),
        p2=_player_snapshot_from_dict(dict(data.get("p2", {}))),
        stadium_card_id=data.get("stadium_card_id"),
        winner=data.get("winner"),
        apply_type_matchups=bool(data.get("apply_type_matchups", False)),
        mulligan_bonus_given=list(data.get("mulligan_bonus_given", [])),
        pending_promotions=list(data.get("pending_promotions", [])),
        revision=int(data.get("revision", 0)),
        choice_sequence=int(data.get("choice_sequence", 0)),
        public_deck_keys=tuple(data.get("public_deck_keys", [None, None])),
        resolution_stack=copy.deepcopy(
            data.get(
                "resolution_stack",
                {"frames": [], "pending_request": None, "sequence": 0, "context": {}},
            )
        ),
        event_stream=copy.deepcopy(data.get("event_stream", [])),
        mulligan_count=tuple(data.get("mulligan_count", [0, 0])),
        extra_draws=tuple(data.get("extra_draws", [0, 0])),
        action_log=[str(item) for item in data.get("action_log", [])],
    )


def canonical_state_payload(state: GameState) -> dict:
    """Return the single JSON state shape used by persistence and rollback."""
    return snapshot_to_dict(snapshot_state(state))


def state_from_payload(payload: dict, *, rebuild_event_bus: bool = True) -> GameState:
    """Restore a GameState from :func:`canonical_state_payload`."""
    return state_from_snapshot(
        snapshot_from_dict(payload),
        rebuild_event_bus=rebuild_event_bus,
    )


def rebuild_state_event_bus(state: GameState):
    """Re-register event-driven modifiers after snapshot restore."""
    from engine.commands.modifier_registration import register_pokemon_modifiers
    from engine.effects.modifier_manager import ModifierManager

    state.event_bus.clear()
    state.modifier_manager = ModifierManager(state.event_bus)
    for player_idx in (0, 1):
        player = state.get_player(player_idx)
        for slot, pokemon in player.get_all_pokemon():
            if pokemon:
                register_pokemon_modifiers(
                    pokemon,
                    player_idx,
                    slot,
                    event_bus=state.event_bus,
                )


def _snapshot_event_stream(state: GameState) -> list[dict]:
    events = getattr(getattr(state, "event_stream", None), "_events", ())
    return [
        {
            "event_type": getattr(event, "event_type", ""),
            "data": copy.deepcopy(getattr(event, "data", {}) or {}),
        }
        for event in events
    ]


def _player_snapshot_to_dict(snap: PlayerSnapshot) -> dict:
    return {
        "name": snap.name,
        "hand_ids": list(snap.hand_ids),
        "deck_ids": list(snap.deck_ids),
        "discard_ids": list(snap.discard_ids),
        "prize_ids": list(snap.prize_ids),
        "active": _pokemon_snapshot_to_dict(snap.active),
        "bench": [_pokemon_snapshot_to_dict(pokemon) for pokemon in snap.bench],
        "supporter_played": bool(snap.supporter_played),
        "energy_attached": bool(snap.energy_attached),
        "retreated": bool(snap.retreated),
        "stadium_played": bool(snap.stadium_played),
        "stadium_used": bool(snap.stadium_used),
        "healed": bool(snap.healed),
        "vstar_used": bool(snap.vstar_used),
        "was_ko_by_attack": bool(snap.was_ko_by_attack),
    }


def _player_snapshot_from_dict(data: dict) -> PlayerSnapshot:
    bench = [
        _pokemon_snapshot_from_dict(item) if isinstance(item, dict) else None
        for item in data.get("bench", [])
    ]
    while len(bench) < 5:
        bench.append(None)
    return PlayerSnapshot(
        name=str(data.get("name", "")),
        hand_ids=list(data.get("hand_ids", [])),
        deck_ids=list(data.get("deck_ids", [])),
        discard_ids=list(data.get("discard_ids", [])),
        prize_ids=list(data.get("prize_ids", [])),
        active=(
            _pokemon_snapshot_from_dict(data["active"])
            if isinstance(data.get("active"), dict)
            else None
        ),
        bench=bench[:5],
        supporter_played=bool(data.get("supporter_played", False)),
        energy_attached=bool(data.get("energy_attached", False)),
        retreated=bool(data.get("retreated", False)),
        stadium_played=bool(data.get("stadium_played", False)),
        stadium_used=bool(data.get("stadium_used", False)),
        healed=bool(data.get("healed", False)),
        vstar_used=bool(data.get("vstar_used", False)),
        was_ko_by_attack=bool(data.get("was_ko_by_attack", False)),
    )


def _pokemon_snapshot_to_dict(snap: PokemonSnapshot | None) -> dict | None:
    if snap is None:
        return None
    return {
        "card_id": snap.card_id,
        "damage_counters": int(snap.damage_counters),
        "energy_card_ids": list(snap.energy_card_ids),
        "attached_tool_id": snap.attached_tool_id,
        "status_conditions": list(snap.status_conditions),
        "evolution_stack_ids": list(snap.evolution_stack_ids),
        "can_evolve_this_turn": bool(snap.can_evolve_this_turn),
        "placed_this_turn": bool(snap.placed_this_turn),
        "used_abilities": list(snap.used_abilities),
        "damage_prevented": bool(snap.damage_prevented),
        "all_prevented": bool(snap.all_prevented),
        "outgoing_damage_reduction": int(snap.outgoing_damage_reduction),
        "attack_locked": bool(snap.attack_locked),
        "attack_locked_names": copy.deepcopy(snap.attack_locked_names),
        "dazzled": bool(snap.dazzled),
        "max_hp_modifiers": copy.deepcopy(snap.max_hp_modifiers),
        "paralyzed_since_turn": int(snap.paralyzed_since_turn),
    }


def _pokemon_snapshot_from_dict(data: dict) -> PokemonSnapshot:
    return PokemonSnapshot(
        card_id=str(data.get("card_id", "")),
        damage_counters=int(data.get("damage_counters", 0)),
        energy_card_ids=list(data.get("energy_card_ids", [])),
        attached_tool_id=data.get("attached_tool_id"),
        status_conditions=list(data.get("status_conditions", [])),
        evolution_stack_ids=list(data.get("evolution_stack_ids", [])),
        can_evolve_this_turn=bool(data.get("can_evolve_this_turn", True)),
        placed_this_turn=bool(data.get("placed_this_turn", True)),
        used_abilities=list(data.get("used_abilities", [])),
        damage_prevented=bool(data.get("damage_prevented", False)),
        all_prevented=bool(data.get("all_prevented", False)),
        outgoing_damage_reduction=int(data.get("outgoing_damage_reduction", 0)),
        attack_locked=bool(data.get("attack_locked", False)),
        attack_locked_names=copy.deepcopy(data.get("attack_locked_names", {})),
        dazzled=bool(data.get("dazzled", False)),
        max_hp_modifiers=copy.deepcopy(data.get("max_hp_modifiers", [])),
        paralyzed_since_turn=int(data.get("paralyzed_since_turn", 0)),
    )


def _restore_event_stream(state: GameState, events: list[dict]) -> None:
    from engine.events.game_events import GameEvent, GameEventStream

    if not hasattr(state, "event_stream") or state.event_stream is None:
        state.event_stream = GameEventStream()
    state.event_stream._events = [
        GameEvent(
            str(event.get("event_type", "")),
            copy.deepcopy(event.get("data", {}) or {}),
        )
        for event in events
        if isinstance(event, dict)
    ]


def _snapshot_player(player: PlayerState) -> PlayerSnapshot:
    return PlayerSnapshot(
        name=player.name,
        hand_ids=[c.api_id for c in player.hand],
        deck_ids=[c.api_id for c in player.deck],
        discard_ids=[c.api_id for c in player.discard],
        prize_ids=[c.api_id for c in player.prizes],
        active=_snapshot_pokemon(player.active) if player.active else None,
        bench=[_snapshot_pokemon(p) if p else None for p in player.bench],
        supporter_played=player.supporter_played_this_turn,
        energy_attached=player.energy_attached_this_turn,
        retreated=player.retreated_this_turn,
        stadium_played=player.stadium_played_this_turn,
        stadium_used=player.stadium_used_this_turn,
        healed=player.healed_this_turn,
        vstar_used=player.vstar_power_used,
        was_ko_by_attack=player.was_ko_by_attack,
    )


def _restore_player(player: PlayerState, snap: PlayerSnapshot):
    player.name = snap.name
    player.hand = [_require_card(cid) for cid in snap.hand_ids]
    player.deck = [_require_card(cid) for cid in snap.deck_ids]
    player.discard = [_require_card(cid) for cid in snap.discard_ids]
    player.prizes = [_require_card(cid) for cid in snap.prize_ids]
    player.active = _restore_pokemon(snap.active) if snap.active else None
    player.bench = [_restore_pokemon(p) if p else None for p in snap.bench]
    player.supporter_played_this_turn = snap.supporter_played
    player.energy_attached_this_turn = snap.energy_attached
    player.retreated_this_turn = snap.retreated
    player.stadium_played_this_turn = snap.stadium_played
    player.stadium_used_this_turn = snap.stadium_used
    player.healed_this_turn = snap.healed
    player.vstar_power_used = snap.vstar_used
    player.was_ko_by_attack = snap.was_ko_by_attack


def _snapshot_pokemon(p: PokemonInPlay) -> PokemonSnapshot:
    return PokemonSnapshot(
        card_id=p.card.api_id,
        damage_counters=p.damage_counters,
        energy_card_ids=[c.api_id for c in p.energy_cards],
        attached_tool_id=p.attached_tool.api_id if p.attached_tool else None,
        status_conditions=sorted(status.name for status in p.status_conditions),
        evolution_stack_ids=[c.api_id for c in p.evolution_stack],
        can_evolve_this_turn=p.can_evolve_this_turn,
        placed_this_turn=p.placed_this_turn,
        used_abilities=sorted(p.used_abilities),
        damage_prevented=p.damage_prevented_next_turn,
        all_prevented=p.all_prevented_next_turn,
        outgoing_damage_reduction=p.outgoing_damage_reduction_next_turn,
        attack_locked=p.attack_locked,
        attack_locked_names=dict(p.attack_locked_names),
        dazzled=p.dazzled,
        max_hp_modifiers=copy.deepcopy(getattr(p, "max_hp_modifiers", [])),
        paralyzed_since_turn=p.paralyzed_since_turn,
    )


def _restore_pokemon(snap: PokemonSnapshot) -> PokemonInPlay:
    from engine.player_state import PokemonInPlay
    from engine.enums import StatusType

    pokemon = PokemonInPlay(card=_require_card(snap.card_id))
    pokemon.damage_counters = snap.damage_counters
    pokemon.energy_cards = [_require_card(cid) for cid in snap.energy_card_ids]
    pokemon.attached_tool = _lookup_card(snap.attached_tool_id) if snap.attached_tool_id else None
    pokemon.status_conditions = {StatusType[s] for s in snap.status_conditions}
    pokemon.evolution_stack = [_require_card(cid) for cid in snap.evolution_stack_ids]
    pokemon.can_evolve_this_turn = snap.can_evolve_this_turn
    pokemon.placed_this_turn = snap.placed_this_turn
    pokemon.used_abilities = set(snap.used_abilities)
    pokemon.damage_prevented_next_turn = snap.damage_prevented
    pokemon.all_prevented_next_turn = snap.all_prevented
    pokemon.outgoing_damage_reduction_next_turn = snap.outgoing_damage_reduction
    pokemon.attack_locked = snap.attack_locked
    pokemon.attack_locked_names = dict(snap.attack_locked_names)
    pokemon.dazzled = snap.dazzled
    pokemon.max_hp_modifiers = copy.deepcopy(snap.max_hp_modifiers)
    pokemon.paralyzed_since_turn = snap.paralyzed_since_turn
    return pokemon


def _lookup_card(api_id: str | None):
    """Look up a card by api_id. Returns None if not found."""
    if api_id is None:
        return None
    from data.card_registry import CardRegistry
    return CardRegistry.get(api_id)


def _require_card(api_id: str):
    """Look up a card, raising if not found."""
    card = _lookup_card(api_id)
    if card is None:
        raise KeyError(f"Card not in registry: {api_id}")
    return card

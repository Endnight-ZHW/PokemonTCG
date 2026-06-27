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
        mulligan_bonus_given=list(state._mulligan_bonus_given),
        pending_promotions=list(state.pending_promotions),
        revision=getattr(state, "revision", 0),
        choice_sequence=getattr(state, "choice_sequence", 0),
        public_deck_keys=tuple(getattr(state, "public_deck_keys", (None, None))),
    )


def restore_state(state: GameState, snap: GameSnapshot):
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
    state._piercing_attack = False
    state._ko_from_attack = False
    state._mulligan_bonus_given = set(snap.mulligan_bonus_given)

    _restore_player(state.p1, snap.p1)
    _restore_player(state.p2, snap.p2)

    state.stadium_card = _lookup_card(snap.stadium_card_id) if snap.stadium_card_id else None


def clone_state(state: GameState, *, rebuild_event_bus: bool = True) -> GameState:
    """Create a full GameState copy through the snapshot system."""
    from engine.game_state import GameState

    clone = GameState()
    try:
        restore_state(clone, snapshot_state(state))
        clone.action_log = list(state.action_log)
    except KeyError:
        # Tests, editors, and generated scenarios may contain cards that are
        # intentionally not registered globally. A deep copy keeps those
        # snapshots local instead of mutating CardRegistry with placeholders.
        clone = copy.deepcopy(state)
    if rebuild_event_bus:
        rebuild_state_event_bus(clone)
    return clone


def state_from_snapshot(snap: GameSnapshot, *, rebuild_event_bus: bool = True) -> GameState:
    """Create a GameState from an existing snapshot."""
    from engine.game_state import GameState

    state = GameState()
    restore_state(state, snap)
    if rebuild_event_bus:
        rebuild_state_event_bus(state)
    return state


def rebuild_state_event_bus(state: GameState):
    """Re-register event-driven modifiers after snapshot restore."""
    from engine.commands.modifier_registration import register_pokemon_modifiers

    state.event_bus.clear()
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
        status_conditions=[s.name for s in p.status_conditions],
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

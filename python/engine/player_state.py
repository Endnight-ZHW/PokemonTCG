"""Read/query model for a player state projected by ``ptcg_core``."""
from dataclasses import dataclass, field
from typing import Optional
from engine.rules_constants import MAX_BENCH_SIZE
from engine.enums import StatusType
from engine.energy_view import EnergyView


@dataclass
class PokemonInPlay:
    """A Pokemon sitting in the Active spot or on the Bench."""
    card: "Card"                       # The base Card object
    damage_counters: int = 0           # Current damage (each = 10 HP)
    energy_cards: list["Card"] = field(default_factory=list)  # Unified energy cards (basic + special)
    attached_tool: Optional["Card"] = None
    status_conditions: set[StatusType] = field(default_factory=set)
    evolution_stack: list["Card"] = field(default_factory=list)
    can_evolve_this_turn: bool = True
    placed_this_turn: bool = True
    damage_prevented_next_turn: bool = False  # For prevent_damage / prevent_all effects (blocks all damage)
    all_prevented_next_turn: bool = False  # For prevent_effects / prevent_all effects (blocks additional effects only)
    outgoing_damage_reduction_next_turn: int = 0  # Reduces this Pokemon's next attack damage.
    attack_locked: bool = False  # For attack_lock_basic effect (雪暴马 冻结)
    attack_locked_names: dict = field(default_factory=dict)  # Instance-scoped named attack locks.
    dazzled: bool = False  # For dazzling_beam (炫目光束): next attack requires coin flip
    modifiers: list[dict] = field(default_factory=list)
    max_hp_modifiers: list[dict] = field(default_factory=list)
    used_abilities: set[str] = field(default_factory=set)
    paralyzed_since_turn: int = 0  # Track which turn paralysis was applied for correct duration
    healed_this_turn: bool = False
    pending_ko_cause: str = ""

    @property
    def current_hp(self) -> int:
        """Read-only projection of descriptors authored by ptcg_core."""
        maximum = max(0, int(getattr(self.card, "hp", 0) or 0))
        is_basic = "Basic" in set(
            getattr(self.card, "subtypes", ()) or ()
        )
        available = [str(value).lower() for value in self.available_energy]
        for descriptor in self.modifiers:
            if not isinstance(descriptor, dict):
                continue
            operation = descriptor.get("operation", {})
            condition = descriptor.get("condition", {})
            if (
                descriptor.get("hook") != "MAX_HP"
                or not isinstance(operation, dict)
                or operation.get("kind") != "hp_delta"
                or (condition.get("target_basic", False) and not is_basic)
            ):
                continue
            required_type = str(
                condition.get("energy_type", "") or ""
            ).lower()
            threshold = max(0, int(condition.get("threshold", 0) or 0))
            if required_type and threshold:
                matching = sum(
                    value in {required_type, "rainbow"}
                    for value in available
                )
                if matching < threshold:
                    continue
            maximum += int(operation.get("amount", 0) or 0)
        return max(0, maximum - self.damage_counters * 10)

    @property
    def available_energy(self) -> list[str]:
        """All energy types provided by cards in energy_cards (unified list)."""
        return EnergyView.from_pokemon(self).available_types

    def has_enough_energy(self, cost: list[str]) -> bool:
        """Check if attached energy satisfies attack cost.
        Colorless costs can be paid by any energy type.
        Rainbow providers can pay for any type. Provider-specific downgrade
        rules are applied by available_energy."""
        return EnergyView.from_pokemon(self).can_pay(cost)

class PlayerState:
    """All state for a single player."""

    def __init__(self, name: str = ""):
        self.name = name or "玩家"
        self.deck: list["Card"] = []
        self.hand: list["Card"] = []
        self.discard: list["Card"] = []
        self.prizes: list["Card"] = []
        self.active: Optional[PokemonInPlay] = None
        self.bench: list[Optional[PokemonInPlay]] = [None] * MAX_BENCH_SIZE

        # Once-per-turn flags
        self.supporter_played_this_turn: bool = False
        self.energy_attached_this_turn: bool = False
        self.retreated_this_turn: bool = False
        self.stadium_played_this_turn: bool = False
        self.stadium_used_this_turn: bool = False
        self.healed_this_turn: bool = False  # Track if any healing happened this turn

        # Game-wide once-per-game flags
        self.vstar_power_used: bool = False

        # Track if a Pokemon was KO'd by attack damage last turn (for 愤怒冷冻 etc.)
        self.was_ko_by_attack: bool = False
        # Broader official condition used by cards which only say that one of
        # your Pokemon was Knocked Out during the opponent's previous turn.
        self.was_ko_last_turn: bool = False
        # Player-scoped named attack restrictions, e.g. Cavern Tackle. Values
        # are the last turn number on which the restriction remains active.
        self.attack_locked_names: dict[str, int] = {}

    @property
    def hand_count(self) -> int:
        return len(self.hand)

    def bench_has_space(self) -> bool:
        return self.bench.count(None) > 0

    def bench_count(self) -> int:
        return sum(1 for s in self.bench if s is not None)

    def get_all_pokemon(self) -> list[tuple[str, Optional[PokemonInPlay]]]:
        """Get all Pokemon slots as (slot_name, pokemon) pairs."""
        result = [("active", self.active)]
        for i, pokemon in enumerate(self.bench):
            result.append((f"bench_{i}", pokemon))
        return result

    def get_pokemon(self, slot: str) -> Optional[PokemonInPlay]:
        """Get Pokemon by slot name: 'active' or 'bench_N'."""
        if slot == "active":
            return self.active
        elif slot.startswith("bench_"):
            try:
                idx = int(slot.split("_")[1])
            except (ValueError, IndexError):
                return None
            if 0 <= idx < MAX_BENCH_SIZE:
                return self.bench[idx]
        return None

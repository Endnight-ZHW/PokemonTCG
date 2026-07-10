"""Player state: hand, deck, discard, prizes, bench, active pokemon."""
import random
from dataclasses import dataclass, field
from typing import Optional
from engine.rules_constants import MAX_BENCH_SIZE, PRIZE_CARDS
from engine.enums import StatusType


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
    attack_locked_names: dict = field(default_factory=dict)  # attack_name → turn_applied (岩窟冲撞 self-lock)
    dazzled: bool = False  # For dazzling_beam (炫目光束): next attack requires coin flip
    max_hp_modifiers: list[dict] = field(default_factory=list)
    used_abilities: set[str] = field(default_factory=set)
    paralyzed_since_turn: int = 0  # Track which turn paralysis was applied for correct duration

    @property
    def current_hp(self) -> int:
        """Remaining HP after tool/ability max-HP modifiers and damage counters."""
        from engine.effects.pokemon_stat_hooks import current_hp

        return current_hp(self)

    @property
    def is_knocked_out(self) -> bool:
        return self.current_hp <= 0

    @property
    def available_energy(self) -> list[str]:
        """All energy types provided by cards in energy_cards (unified list)."""
        result = []
        for card in self.energy_cards:
            provided = list(card.provides_energy)
            for effect in getattr(card, "energy_effects", []) or []:
                if (
                    effect.get("kind") == "provide_energy"
                    and effect.get("downgrade_if_other_special")
                ):
                    has_other_special = any(
                        other is not card and other.is_special_energy
                        for other in self.energy_cards
                    )
                    if has_other_special:
                        provided = [
                            "Colorless" if energy == "Rainbow" else energy
                            for energy in provided
                        ]
            result.extend(provided)
        return result

    def has_special_energy(self, api_id: str) -> bool:
        """Check if a specific special energy card is attached."""
        return any(c.api_id == api_id and c.is_special_energy for c in self.energy_cards)

    def can_attack(self) -> bool:
        """Check if Pokemon can attack (not Asleep/Paralyzed/Attack locked)."""
        return (StatusType.ASLEEP not in self.status_conditions and
                StatusType.PARALYZED not in self.status_conditions and
                not self.attack_locked)

    def can_retreat(self) -> bool:
        """Check if Pokemon can retreat (not Asleep/Paralyzed)."""
        return (StatusType.ASLEEP not in self.status_conditions and
                StatusType.PARALYZED not in self.status_conditions)

    def has_enough_energy(self, cost: list[str]) -> bool:
        """Check if attached energy satisfies attack cost.
        Colorless costs can be paid by any energy type.
        Rainbow providers can pay for any type. Provider-specific downgrade
        rules are applied by available_energy."""
        available = self.available_energy

        # Match specific (non-Colorless) requirements first
        for required in cost:
            if required == "Colorless":
                continue
            if required in available:
                available.remove(required)
            elif "Rainbow" in available:
                available.remove("Rainbow")
            else:
                return False

        # Remaining energy must cover Colorless requirements
        colorless_count = sum(1 for c in cost if c == "Colorless")
        return len(available) >= colorless_count


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

        # Remote-play: actual hand count when hand contents are hidden
        self._hand_count: int = 0
        self._hand_hidden: bool = False

        # Shuffle animation callback
        self.on_shuffle: callable = None
        self.random_source = None

    @property
    def hand_count(self) -> int:
        """Number of cards in hand. Uses _hand_count when hand is hidden (remote play)."""
        if self._hand_hidden:
            return self._hand_count
        return len(self.hand)

    # ---- Zone operations ----

    def draw_cards(self, count: int) -> list["Card"]:
        """Draw `count` cards from top of deck. Returns drawn cards."""
        drawn = []
        for _ in range(count):
            if self.deck:
                drawn.append(self.deck.pop())
            else:
                break  # deck exhausted
        self.hand.extend(drawn)
        return drawn

    @property
    def deck_exhausted(self) -> bool:
        """Check if deck is empty (player cannot draw and should lose)."""
        return len(self.deck) == 0

    def shuffle_deck(self):
        if self.random_source is not None:
            self.random_source.shuffle(self.deck)
        else:
            random.shuffle(self.deck)
        if self.on_shuffle:
            self.on_shuffle()

    def discard_from_hand(self, indices: list[int]) -> list["Card"]:
        """Discard specific cards from hand by index (sorted descending)."""
        discarded = []
        for i in sorted(indices, reverse=True):
            if 0 <= i < len(self.hand):
                card = self.hand.pop(i)
                self.discard.append(card)
                discarded.append(card)
        return discarded

    def discard_entire_hand(self):
        """Move all hand cards to discard."""
        self.discard.extend(self.hand)
        self.hand.clear()

    def mill_from_deck(self, count: int) -> list["Card"]:
        """Discard from top of deck."""
        milled = []
        for _ in range(count):
            if self.deck:
                milled.append(self.deck.pop())
        self.discard.extend(milled)
        return milled

    def set_prizes(self, count: int = PRIZE_CARDS):
        """Take top `count` cards from deck as prize cards."""
        for _ in range(count):
            if self.deck:
                self.prizes.append(self.deck.pop())

    def take_prize(self, prize_idx: int = 0) -> Optional["Card"]:
        """Take one prize card. Returns card or None."""
        if self.prizes:
            card = self.prizes.pop(prize_idx)
            self.hand.append(card)
            return card
        return None

    # ---- Bench/Active operations ----

    def bench_has_space(self) -> bool:
        return self.bench.count(None) > 0

    def bench_count(self) -> int:
        return sum(1 for s in self.bench if s is not None)

    def find_empty_bench_slot(self) -> int | None:
        """Return index of first empty bench slot, or None."""
        for i, slot in enumerate(self.bench):
            if slot is None:
                return i
        return None

    def place_active(self, card: "Card") -> PokemonInPlay:
        """Place a Basic Pokemon in the Active spot."""
        pokemon = PokemonInPlay(card=card)
        self.active = pokemon
        return pokemon

    def place_bench(self, card: "Card", slot_idx: int = None) -> PokemonInPlay:
        """Place a Basic Pokemon on the Bench."""
        if slot_idx is None:
            slot_idx = self.find_empty_bench_slot()
        if slot_idx is None or slot_idx < 0 or slot_idx >= MAX_BENCH_SIZE:
            raise ValueError(f"Invalid bench slot: {slot_idx}")
        pokemon = PokemonInPlay(card=card)
        self.bench[slot_idx] = pokemon
        return pokemon

    def promote_from_bench(self, bench_idx: int):
        """Move a benched Pokemon to the Active spot."""
        if self.active is not None:
            raise ValueError("Active spot already occupied")
        pokemon = self.bench[bench_idx]
        if pokemon is None:
            raise ValueError(f"No Pokemon on bench slot {bench_idx}")
        self.bench[bench_idx] = None
        self.active = pokemon

    def switch_active_to_bench(self, bench_idx: int):
        """Move Active Pokemon to bench, swapping places."""
        if self.active is None:
            return
        old_active = self.active
        old_bench = self.bench[bench_idx]

        # Clear status conditions on retreat
        old_active.status_conditions.clear()

        # Swap
        self.bench[bench_idx] = old_active
        self.active = old_bench

    def has_any_pokemon_in_play(self) -> bool:
        """Check if player has any Pokemon (Active or Bench)."""
        if self.active is not None:
            return True
        return any(s is not None for s in self.bench)

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

    # ---- Energy operations ----

    def attach_energy_from_hand(self, hand_idx: int, target_slot: str):
        """Attach an energy card from hand to a Pokemon."""
        if not (0 <= hand_idx < len(self.hand)):
            raise ValueError(f"Invalid hand index: {hand_idx}")
        card = self.hand[hand_idx]
        if not card.is_energy:
            raise ValueError(f"Card is not energy: {card.name}")

        target = self.get_pokemon(target_slot)
        if target is None:
            raise ValueError(f"Invalid target: {target_slot}")

        self.hand.pop(hand_idx)
        target.energy_cards.append(card)
        self.energy_attached_this_turn = True

    def pay_retreat_cost(
        self,
        retreat_cost: int,
        energy_indices: list[int] | tuple[int, ...] | None = None,
    ):
        """Remove energy from active to pay retreat cost."""
        active = self.active
        if active is None or retreat_cost <= 0:
            return

        from engine.rules_validator import energy_card_units

        if energy_indices is None:
            chosen: list[int] = []
            paid = 0
            for index in range(len(active.energy_cards) - 1, -1, -1):
                chosen.append(index)
                paid += energy_card_units(active.energy_cards[index], active)
                if paid >= retreat_cost:
                    break
        else:
            chosen = sorted(set(energy_indices), reverse=True)

        for index in sorted(chosen, reverse=True):
            if not (0 <= index < len(active.energy_cards)):
                continue
            card = active.energy_cards.pop(index)
            self.discard.append(card)

    # ---- Evolution ----

    def evolve_pokemon(self, slot: str, evolution_card: "Card"):
        """Evolve a Pokemon with the given evolution card."""
        target = self.get_pokemon(slot)
        if target is None:
            raise ValueError(f"Invalid target: {slot}")

        # Apply evolution
        target.evolution_stack.append(target.card)
        old_card = target.card
        target.card = evolution_card

        # Clear status conditions on evolution
        target.status_conditions.clear()

        # Reset evolution flag
        target.can_evolve_this_turn = False
        target.used_abilities.clear()

        return old_card

    # ---- Reset for new turn ----

    def reset_turn_flags(self):
        """Reset once-per-turn flags at start of turn."""
        self.supporter_played_this_turn = False
        self.energy_attached_this_turn = False
        self.retreated_this_turn = False
        self.stadium_played_this_turn = False
        self.stadium_used_this_turn = False
        self.healed_this_turn = False

        # Mark all Pokemon as not placed this turn
        for _slot, pokemon in self.get_all_pokemon():
            if pokemon is None:
                continue
            pokemon.placed_this_turn = False
            pokemon.can_evolve_this_turn = True
            pokemon.used_abilities.clear()
            # These effects protect this Pokemon during the opponent's next
            # turn. If they were not consumed, they expire when its controller
            # starts a new turn.
            pokemon.damage_prevented_next_turn = False
            pokemon.all_prevented_next_turn = False

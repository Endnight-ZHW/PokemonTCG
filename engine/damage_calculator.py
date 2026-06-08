"""Damage calculator - applies weakness, resistance, and modifiers."""
from engine.rules_constants import DAMAGE_PER_COUNTER
from data.card_models import Card, WeakRes
from engine.player_state import PokemonInPlay


def calculate_damage(
    base_damage: int,
    attacking_type: str,
    defending_card: Card,
    defending_weaknesses: list[WeakRes],
    defending_resistances: list[WeakRes],
    active_effects: list = None,
    piercing: bool = False,
) -> int:
    """Calculate final damage after weakness, resistance, and modifiers.

    Order:
    1. Start with base damage
    2. Apply Weakness (usually x2)
    3. Apply Resistance (usually -30 in modern era, or -20 in older cards)
    4. Apply any other modifiers (abilities, tools, stadiums, etc.)
    5. Minimum damage is 0 (before weakness/resistance can cause 0, but
       weakness doubles first, so damage is at least 0)

    If piercing=True, weakness and resistance are skipped.

    Returns final damage (in HP units, not damage counters).
    """
    if active_effects is None:
        active_effects = []

    damage = base_damage

    if not piercing:
        # Apply Weakness: if defender has weakness to attacker's type
        for weak in defending_weaknesses:
            if weak.energy_type == attacking_type:
                damage = apply_weakness(damage, weak.value)
                break  # Only one weakness applies (rarely do Pokemon have multiple weaknesses)

        # Apply Resistance: if defender has resistance to attacker's type
        for resist in defending_resistances:
            if resist.energy_type == attacking_type:
                damage = apply_resistance(damage, resist.value)
                break

    # Apply active modifiers (from abilities, tools, stadiums)
    for effect in active_effects:
        if hasattr(effect, 'modify_damage'):
            damage = effect.modify_damage(damage)

    return max(0, damage)


def apply_weakness(damage: int, weakness_value: str) -> int:
    """Apply weakness multiplier. Usually '×2' = double damage."""
    if weakness_value in ("×2", "x2"):
        return damage * 2
    # Parse numeric multiplier
    try:
        multiplier = float(weakness_value.replace("×", "").replace("x", ""))
        return int(damage * multiplier)
    except ValueError:
        return damage


def apply_resistance(damage: int, resistance_value: str) -> int:
    """Apply resistance reduction. Usually '-30' or '-20'."""
    try:
        reduction = int(resistance_value.replace("-", ""))
        return damage - reduction
    except ValueError:
        return damage


def damage_to_counters(damage: int) -> int:
    """Convert HP damage to damage counters (1 counter = 10 damage)."""
    # In PTCG, damage is tracked in damage counters (each = 10 HP).
    # Damage values are always multiples of 10.
    return damage // DAMAGE_PER_COUNTER


def counters_to_damage(counters: int) -> int:
    """Convert damage counters to HP damage."""
    return counters * DAMAGE_PER_COUNTER

"""Effective attached-energy view shared by rules, formulas, and AI.

Cards remain the authoritative attachment objects.  ``EnergyView`` derives the
energy *units* that those cards currently provide, including effects whose
provider changes according to the other attached cards.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Sequence


WILDCARD_ENERGY = "Rainbow"
COLORLESS_ENERGY = "Colorless"


@dataclass(frozen=True)
class EnergyUnit:
    """One effective energy unit supplied by an attached card."""

    energy_type: str
    card_index: int


@dataclass(frozen=True)
class EnergyPayment:
    """Result of matching effective energy units against an attack cost."""

    missing_specific: tuple[str, ...] = ()
    missing_colorless: int = 0

    @property
    def missing_count(self) -> int:
        return len(self.missing_specific) + self.missing_colorless

    @property
    def can_pay(self) -> bool:
        return self.missing_count == 0


class EnergyView:
    """Read-only effective-energy projection for one Pokemon's attachments."""

    def __init__(self, cards: Iterable[Any] = ()):
        self.cards: tuple[Any, ...] = tuple(cards or ())
        self.units: tuple[EnergyUnit, ...] = tuple(
            EnergyUnit(energy_type, card_index)
            for card_index, _card in enumerate(self.cards)
            for energy_type in self._providers_for_card(card_index)
        )

    @classmethod
    def from_pokemon(cls, pokemon: Any) -> "EnergyView":
        if pokemon is None:
            return cls()
        return cls(getattr(pokemon, "energy_cards", ()) or ())

    @property
    def available_types(self) -> list[str]:
        """Compatibility representation used by existing callers."""
        return [unit.energy_type for unit in self.units]

    @property
    def total_units(self) -> int:
        return len(self.units)

    def with_card(self, card: Any) -> "EnergyView":
        """Return the effective view after attaching ``card``."""
        return EnergyView((*self.cards, card))

    def card_unit_count(self, card_index: int) -> int:
        return sum(1 for unit in self.units if unit.card_index == card_index)

    def selected_unit_count(self, card_indices: Iterable[int]) -> int:
        selected = set(card_indices)
        return sum(1 for unit in self.units if unit.card_index in selected)

    def count(self, energy_type: str = "any") -> int:
        """Count effective units, optionally restricted to one energy type.

        A wildcard unit is every named type at once, but is still only one unit.
        Colorless queries count units that explicitly provide Colorless (plus a
        wildcard); paying a Colorless cost is handled separately and may use any
        remaining unit.
        """
        normalized = _normalize_energy_type(energy_type)
        if normalized in {"", "any"}:
            return self.total_units
        wildcard = _normalize_energy_type(WILDCARD_ENERGY)
        return sum(
            1
            for unit in self.units
            if _normalize_energy_type(unit.energy_type) in {normalized, wildcard}
        )

    def payment(self, cost: Sequence[str] | None) -> EnergyPayment:
        """Match a cost using exact typed units, then wildcards, then any unit.

        All exact matches for typed requirements are reserved before wildcard
        units are assigned.  The remaining units then pay Colorless requirements.
        This prevents a wildcard from being spent on a type for which an exact
        provider existed while another typed requirement goes unpaid.
        """
        normalized_cost = [_normalize_energy_type(value) for value in (cost or ())]
        colorless = _normalize_energy_type(COLORLESS_ENERGY)
        wildcard = _normalize_energy_type(WILDCARD_ENERGY)

        typed_requirements = [value for value in normalized_cost if value != colorless]
        colorless_required = sum(1 for value in normalized_cost if value == colorless)

        exact_units: dict[str, int] = {}
        wildcard_units = 0
        for unit in self.units:
            unit_type = _normalize_energy_type(unit.energy_type)
            if unit_type == wildcard:
                wildcard_units += 1
            else:
                exact_units[unit_type] = exact_units.get(unit_type, 0) + 1

        unmatched: list[str] = []
        for required in typed_requirements:
            if exact_units.get(required, 0) > 0:
                exact_units[required] -= 1
            else:
                unmatched.append(required)

        wildcard_for_typed = min(len(unmatched), wildcard_units)
        if wildcard_for_typed:
            unmatched = unmatched[wildcard_for_typed:]
            wildcard_units -= wildcard_for_typed

        remaining_units = wildcard_units + sum(exact_units.values())
        missing_colorless = max(0, colorless_required - remaining_units)
        return EnergyPayment(tuple(unmatched), missing_colorless)

    def can_pay(self, cost: Sequence[str] | None) -> bool:
        return self.payment(cost).can_pay

    def missing_count(self, cost: Sequence[str] | None) -> int:
        return self.payment(cost).missing_count

    def _providers_for_card(self, card_index: int) -> tuple[str, ...]:
        card = self.cards[card_index]
        if not getattr(card, "is_energy", False):
            return ()

        providers = list(getattr(card, "provides_energy", ()) or ())
        for effect in getattr(card, "energy_effects", ()) or ():
            if (
                effect.get("kind") == "provide_energy"
                and effect.get("downgrade_if_other_special")
                and self._has_other_special_energy(card_index)
            ):
                providers = [
                    COLORLESS_ENERGY
                    if _normalize_energy_type(provider)
                    == _normalize_energy_type(WILDCARD_ENERGY)
                    else provider
                    for provider in providers
                ]
        return tuple(str(provider) for provider in providers if str(provider))

    def _has_other_special_energy(self, card_index: int) -> bool:
        # Compare attachment positions, not object identity.  CardRegistry returns
        # shared card objects, so two copies may intentionally be the same object.
        return any(
            other_index != card_index and getattr(other, "is_special_energy", False)
            for other_index, other in enumerate(self.cards)
        )


def _normalize_energy_type(value: Any) -> str:
    return str(value or "").strip().lower()

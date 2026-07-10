from __future__ import annotations

import copy
import unittest

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.enums import StatusType, TurnPhase
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.snapshot import (
    SNAPSHOT_SCHEMA_VERSION,
    canonical_state_payload,
    snapshot_from_dict,
    state_from_payload,
)


class SnapshotSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def _state(self) -> GameState:
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.revision = 7
        state.choice_sequence = 2
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.hand = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        return state

    def test_canonical_payload_roundtrip_has_explicit_schema(self):
        state = self._state()
        payload = canonical_state_payload(state)
        self.assertEqual(payload["schema_version"], SNAPSHOT_SCHEMA_VERSION)

        restored = state_from_payload(payload)
        self.assertEqual(canonical_state_payload(restored), payload)

    def test_pre_schema_payload_remains_readable(self):
        payload = canonical_state_payload(self._state())
        payload.pop("schema_version")
        restored = state_from_payload(payload)
        self.assertEqual(restored.revision, 7)
        self.assertEqual(restored.p1.hand[0].api_id, "sv1-ener-2")

    def test_canonical_payload_sorts_set_backed_fields(self):
        state = self._state()
        state._mulligan_bonus_given = {1, 0}
        state.p1.active.status_conditions = {
            StatusType.POISONED,
            StatusType.ASLEEP,
            StatusType.BURNED,
        }

        payload = canonical_state_payload(state)

        self.assertEqual(payload["mulligan_bonus_given"], [0, 1])
        self.assertEqual(
            payload["p1"]["active"]["status_conditions"],
            sorted(["POISONED", "ASLEEP", "BURNED"]),
        )
        self.assertEqual(canonical_state_payload(state), payload)

    def test_unknown_or_invalid_schema_fails_closed(self):
        payload = canonical_state_payload(self._state())
        future = copy.deepcopy(payload)
        future["schema_version"] = SNAPSHOT_SCHEMA_VERSION + 1
        with self.assertRaisesRegex(ValueError, "Unsupported snapshot schema"):
            snapshot_from_dict(future)

        invalid = copy.deepcopy(payload)
        invalid["schema_version"] = "not-an-integer"
        with self.assertRaisesRegex(ValueError, "schema_version is invalid"):
            snapshot_from_dict(invalid)

        bool_version = copy.deepcopy(payload)
        bool_version["schema_version"] = True
        with self.assertRaisesRegex(ValueError, "schema_version is invalid"):
            snapshot_from_dict(bool_version)

        with self.assertRaisesRegex(ValueError, "must be an object"):
            snapshot_from_dict([])


if __name__ == "__main__":
    unittest.main()

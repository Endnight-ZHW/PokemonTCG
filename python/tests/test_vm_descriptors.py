from __future__ import annotations

import json
from pathlib import Path
import unittest

from engine.commands.descriptors import (
    VM_COMMAND_DESCRIPTORS,
    descriptor_export_payload,
)
from engine.commands.dsl_compiler import DEFAULT_COMMAND_REGISTRY
from engine.commands.dsl_compiler import compile_command_spec
from engine.commands.vm_contract import VM_IR_VERSION, validate_command_spec


class VmCommandDescriptorTests(unittest.TestCase):
    def test_authoritative_inventory_is_frozen_and_matches_handlers(self):
        self.assertEqual(len(VM_COMMAND_DESCRIPTORS), 80)
        self.assertEqual(
            frozenset(VM_COMMAND_DESCRIPTORS),
            DEFAULT_COMMAND_REGISTRY.supported_ops,
        )
        with self.assertRaises(TypeError):
            VM_COMMAND_DESCRIPTORS["late_op"] = {}  # type: ignore[index]
        mutated = dict(VM_COMMAND_DESCRIPTORS["draw_cards"])
        mutated["args_schema"]["properties"]["late"] = {"type": "string"}
        self.assertNotIn(
            "late",
            VM_COMMAND_DESCRIPTORS["draw_cards"]["args_schema"]["properties"],
        )

    def test_export_is_deterministic_and_checked_in_for_godot(self):
        first = descriptor_export_payload(VM_IR_VERSION)
        second = descriptor_export_payload(VM_IR_VERSION)
        self.assertEqual(first, second)
        self.assertEqual(len(first["descriptor_digest"]), 64)
        checked_in = json.loads(
            Path(__file__).resolve().parents[2]
            .joinpath("godot/data/vm_command_descriptors.json")
            .read_text(encoding="utf-8")
        )
        self.assertEqual(checked_in, first)

    def test_every_op_has_strict_schema_and_negative_contract_cases(self):
        supported = set(VM_COMMAND_DESCRIPTORS)
        required_cases = 0
        typed_cases = 0
        enum_cases = 0
        range_cases = 0
        for op, descriptor_value in VM_COMMAND_DESCRIPTORS.items():
            descriptor = dict(descriptor_value)
            with self.subTest(op=op):
                self.assertEqual(descriptor["op"], op)
                self.assertFalse(
                    descriptor["args_schema"]["additional_properties"]
                )
                self.assertFalse(
                    descriptor["branch_schema"]["additional_properties"]
                )
                self.assertTrue(descriptor["semantic_kind"])
                self.assertTrue(descriptor["preflight_evaluator"])
                self.assertTrue(descriptor["allowed_contexts"])
                self.assertIs(descriptor["requires_boolean_success"], True)

                extra_arg = {
                    "op": op,
                    "args": {"__extra__": 1},
                    "branches": {},
                }
                self.assertTrue(validate_command_spec(
                    extra_arg,
                    supported_ops=supported,
                    descriptors=VM_COMMAND_DESCRIPTORS,
                ))

                extra_branch = {
                    "op": op,
                    "args": {},
                    "branches": {"__extra__": []},
                }
                self.assertTrue(validate_command_spec(
                    extra_branch,
                    supported_ops=supported,
                    descriptors=VM_COMMAND_DESCRIPTORS,
                ))

                wrong_context = {
                    "op": op,
                    "args": {},
                    "branches": {},
                }
                context_errors = validate_command_spec(
                    wrong_context,
                    supported_ops=supported,
                    descriptors=VM_COMMAND_DESCRIPTORS,
                    execution_context="__invalid__",
                )
                self.assertTrue(any("context" in error for error in context_errors))

                required = list(descriptor["args_schema"]["required"])
                if required:
                    required_cases += 1
                    self.assertTrue(any(
                        "missing required" in error
                        for error in validate_command_spec(
                            {"op": op, "args": {}, "branches": {}},
                            supported_ops=supported,
                            descriptors=VM_COMMAND_DESCRIPTORS,
                        )
                    ))

                properties = descriptor["args_schema"]["properties"]
                if properties:
                    typed_cases += 1
                    key, schema = next(iter(properties.items()))
                    bad = self._wrong_type(schema["type"])
                    errors = validate_command_spec(
                        {"op": op, "args": {key: bad}, "branches": {}},
                        supported_ops=supported,
                        descriptors=VM_COMMAND_DESCRIPTORS,
                    )
                    self.assertTrue(any(key in error for error in errors))
                for key, schema in properties.items():
                    if schema.get("enum"):
                        enum_cases += 1
                        errors = validate_command_spec(
                            {"op": op, "args": {key: "__invalid__"}, "branches": {}},
                            supported_ops=supported,
                            descriptors=VM_COMMAND_DESCRIPTORS,
                        )
                        self.assertTrue(any("one of" in error for error in errors))
                        break
                    if "minimum" in schema:
                        range_cases += 1
                        errors = validate_command_spec(
                            {"op": op, "args": {key: schema["minimum"] - 1}, "branches": {}},
                            supported_ops=supported,
                            descriptors=VM_COMMAND_DESCRIPTORS,
                        )
                        self.assertTrue(any(">=" in error for error in errors))
                        break

        self.assertGreater(required_cases, 0)
        self.assertGreater(typed_cases, 0)
        self.assertGreater(enum_cases, 0)
        self.assertGreater(range_cases, 0)

    def test_internal_ops_are_rejected_from_card_data(self):
        for op, descriptor in VM_COMMAND_DESCRIPTORS.items():
            if not descriptor["internal"]:
                continue
            errors = validate_command_spec(
                {"op": op, "args": {}, "branches": {}},
                supported_ops=set(VM_COMMAND_DESCRIPTORS),
                descriptors=VM_COMMAND_DESCRIPTORS,
                allow_internal=False,
            )
            self.assertTrue(any("internal" in error for error in errors), op)

    def test_compiler_does_not_normalize_away_malformed_envelopes(self):
        malformed_specs = (
            {"op": "draw_cards", "args": {}, "branches": {}, "extra": True},
            {"op": "draw_cards", "args": [], "branches": {}},
            {"op": "draw_cards", "args": {}, "branches": []},
        )
        for spec in malformed_specs:
            with self.subTest(spec=spec):
                with self.assertRaisesRegex(ValueError, "Invalid VM command spec"):
                    compile_command_spec(spec)

    def test_exp_share_trigger_uses_attached_descriptor_card_identity(self):
        """A cloned tool must work without the historical svg2-exps ID."""
        from copy import deepcopy

        from data.card_registry import CardRegistry
        from data.deck_definitions import ALL_CARD_IDS
        from engine.commands.modifier_registration import register_pokemon_modifiers
        from engine.commands.trigger_commands import command_specs_from_trigger_results
        from engine.enums import EventType
        from engine.game_state import GameState
        from engine.player_state import PokemonInPlay

        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

        cloned_tool = deepcopy(CardRegistry.get("svg2-exps"))
        cloned_tool.api_id = "clone-exp-share"

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[0].attached_tool = cloned_tool
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        register_pokemon_modifiers(
            state.p1.bench[0],
            0,
            "bench_0",
            event_bus=state.event_bus,
        )
        results = state.event_bus.emit(
            EventType.POKEMON_KO,
            state=state,
            player_idx=0,
            slot="active",
            knocked_out=state.p1.active,
            from_attack=True,
        )
        specs = command_specs_from_trigger_results(results)

        self.assertEqual(len(specs), 1)
        self.assertEqual(specs[0]["op"], "trigger_move_basic_energy")
        self.assertEqual(specs[0]["args"]["target_tool_id"], "clone-exp-share")

    @staticmethod
    def _wrong_type(expected):
        types = expected if isinstance(expected, list) else [expected]
        candidates = {
            "integer": "wrong",
            "number": "wrong",
            "string": 123,
            "boolean": "wrong",
            "object": [],
            "array": {},
        }
        return candidates[types[0]]


if __name__ == "__main__":
    unittest.main()

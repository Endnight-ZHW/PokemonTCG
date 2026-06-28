import json
import inspect
import tempfile
import unittest
from pathlib import Path

from card_data.effects import CARD_EFFECTS
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.commands.dsl_compiler import (
    compile_command_spec,
    compile_effect,
    compile_effect_to_spec,
    missing_ir_effect_types,
)
from engine.commands.resolution_stack import ResolutionStack
from engine.actions import ChoiceResponse
from engine.enums import StatusType
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.snapshot import clone_state, restore_state, snapshot_state
from scripts.export_godot_data import export


def _walk_effects(value):
    if isinstance(value, dict):
        if value.get("effect_type"):
            yield value
        for item in value.values():
            yield from _walk_effects(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _walk_effects(item)


class VmIrContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def test_all_release_effects_compile_to_vm_ir(self):
        self.assertEqual(missing_ir_effect_types(CARD_EFFECTS), set())
        compiled = [compile_effect_to_spec(effect).to_dict() for effect in _walk_effects(CARD_EFFECTS)]
        self.assertTrue(compiled)
        self.assertTrue(all(row["op"] for row in compiled))

    def test_all_release_effects_compile_to_native_commands(self):
        release_effects = list(_walk_effects(CARD_EFFECTS))
        self.assertTrue(release_effects)
        for effect in release_effects:
            with self.subTest(effect_type=effect.get("effect_type", "")):
                command = compile_effect(effect)
                self.assertEqual(type(command).__module__, "engine.commands.primitives")

    def test_immediate_marker_effects_compile_to_explicit_ops(self):
        expected_ops = {
            "apply_outgoing_damage_reduction": "apply_outgoing_damage_reduction",
            "attack_lock_basic": "apply_attack_lock_basic",
            "dazzling_beam": "apply_dazzling_beam",
            "prevent_all": "prevent_all",
            "prevent_damage": "prevent_damage",
            "prevent_effects": "prevent_effects",
            "self_attack_lock": "apply_self_attack_lock",
        }
        found = {
            effect.get("effect_type"): compile_effect_to_spec(effect).to_dict()
            for effect in _walk_effects(CARD_EFFECTS)
            if effect.get("effect_type") in expected_ops
        }
        self.assertEqual(set(found), set(expected_ops))
        for effect_type, op in expected_ops.items():
            with self.subTest(effect_type=effect_type):
                spec = found[effect_type]
                self.assertEqual(spec["op"], op)
                self.assertNotIn("effect_type", spec["args"])

    def test_damage_formula_effects_compile_to_explicit_ops(self):
        expected_ops = {
            "damage_per_discard_psychic": "deal_damage_per_discard_psychic",
            "damage_per_energy": "deal_damage_per_energy",
            "damage_per_evolved": "deal_damage_per_evolved",
            "damage_per_hand_size": "deal_damage_per_hand_size",
            "damage_per_self_damage": "deal_damage_per_self_damage",
            "damage_per_self_energy": "deal_damage_per_self_energy",
            "damage_per_self_energy_type": "deal_damage_per_self_energy_type",
            "damage_plus_bench": "deal_damage_plus_bench",
        }
        found = {
            effect.get("effect_type"): compile_effect_to_spec(effect).to_dict()
            for effect in _walk_effects(CARD_EFFECTS)
            if effect.get("effect_type") in expected_ops
        }
        self.assertEqual(set(found), set(expected_ops))
        for effect_type, op in expected_ops.items():
            with self.subTest(effect_type=effect_type):
                spec = found[effect_type]
                self.assertEqual(spec["op"], op)
                self.assertNotIn("effect_type", spec["args"])

    def test_wrapper_effects_compile_without_legacy_effect_type_args(self):
        expected_ops = {
            "clara": "recover_clara",
            "coin_flip_double_ko": "flip_coin_then_ko",
            "coin_flip_energy_discard": "flip_coin_then_discard_energy",
            "coin_flip_triple": "flip_coin_repeat_damage",
            "coin_flip_until_tails": "flip_until_tails",
            "shuffle_from_discard": "shuffle_from_discard_to_deck",
            "switch_opponent": "switch_pokemon",
            "switch_self": "switch_pokemon",
            "tool": "register_tool_modifier",
        }
        found = {
            effect.get("effect_type"): compile_effect_to_spec(effect).to_dict()
            for effect in _walk_effects(CARD_EFFECTS)
            if effect.get("effect_type") in expected_ops
        }
        self.assertEqual(set(found), set(expected_ops))
        for effect_type, op in expected_ops.items():
            with self.subTest(effect_type=effect_type):
                spec = found[effect_type]
                self.assertEqual(spec["op"], op)
                self.assertNotIn("effect_type", spec["args"])
        self.assertEqual(found["switch_self"]["args"]["target"], "self")
        self.assertEqual(found["switch_opponent"]["args"]["target"], "opponent")

    def test_modifier_effects_compile_to_explicit_registration_ops(self):
        expected_ops = {
            "aura_damage_boost": "register_aura_damage_boost",
            "aura_damage_reduction": "register_aura_damage_reduction",
            "conditional_hp_boost": "register_conditional_hp_boost",
            "conditional_zero_retreat": "register_conditional_zero_retreat",
            "reactive_thorns": "register_reactive_thorns",
            "tool_exp_share": "register_tool_exp_share",
        }
        found = {
            effect.get("effect_type"): compile_effect_to_spec(effect).to_dict()
            for effect in _walk_effects(CARD_EFFECTS)
            if effect.get("effect_type") in expected_ops
        }
        self.assertEqual(set(found), set(expected_ops))
        for effect_type, op in expected_ops.items():
            with self.subTest(effect_type=effect_type):
                spec = found[effect_type]
                self.assertEqual(spec["op"], op)
                self.assertNotIn("effect_type", spec["args"])

    def test_release_compiled_ir_has_no_legacy_effect_type_args(self):
        offenders = []
        for effect in _walk_effects(CARD_EFFECTS):
            spec = compile_effect_to_spec(effect).to_dict()
            if "effect_type" in spec.get("args", {}):
                offenders.append((effect.get("effect_type"), spec))
        self.assertEqual(offenders, [])

    def test_generic_legacy_vm_ops_are_not_compilable(self):
        legacy_ops = {
            "deal_damage_formula",
            "recover_from_discard",
            "register_modifier",
            "register_trigger",
        }
        for op in legacy_ops:
            with self.subTest(op=op):
                with self.assertRaisesRegex(ValueError, "No native ICommand registered"):
                    compile_command_spec({"op": op, "args": {}, "branches": {}})

    def test_vm_command_specs_reject_legacy_effect_type_args(self):
        with self.assertRaisesRegex(ValueError, "legacy effect_type args"):
            compile_command_spec({
                "op": "deal_damage",
                "args": {"effect_type": "damage", "amount": 10},
                "branches": {},
            })

        with self.assertRaisesRegex(ValueError, "requires explicit target"):
            compile_command_spec({
                "op": "switch_pokemon",
                "args": {},
                "branches": {},
            })

    def test_migrated_native_commands_do_not_reuse_effect_type_fields(self):
        from engine.commands.primitives import (
            CoinFlipSpecial,
            DealDamageFormula,
            RecoverFromDiscard,
            RegisterModifier,
        )

        formula_kinds = set()
        coin_kinds = set()
        recover_modes = set()
        modifier_kinds = set()
        offenders = []
        for effect in _walk_effects(CARD_EFFECTS):
            command = compile_effect(effect)
            if isinstance(command, DealDamageFormula):
                formula_kinds.add(command.formula_kind)
                if hasattr(command, "effect_type"):
                    offenders.append(effect.get("effect_type"))
            if isinstance(command, CoinFlipSpecial):
                coin_kinds.add(command.coin_kind)
                if hasattr(command, "effect_type"):
                    offenders.append(effect.get("effect_type"))
            if isinstance(command, RecoverFromDiscard):
                recover_modes.add(command.mode)
                if hasattr(command, "effect_type"):
                    offenders.append(effect.get("effect_type"))
            if isinstance(command, RegisterModifier):
                modifier_kinds.add(command.modifier_kind)
                if hasattr(command, "effect_type") or "effect_type" in command.params:
                    offenders.append(effect.get("effect_type"))

        self.assertTrue(formula_kinds)
        self.assertTrue(coin_kinds)
        self.assertTrue(recover_modes)
        self.assertTrue(modifier_kinds)
        self.assertEqual(offenders, [])

    def test_unknown_effect_type_cannot_fall_back_to_legacy_command(self):
        with self.assertRaisesRegex(ValueError, "No native command registered"):
            compile_effect({"effect_type": "__unknown_effect__", "params": {}})

    def test_action_resolver_reports_unknown_effect_as_rule_failure(self):
        from engine.action_resolver import ActionResolver

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        result = ActionResolver(state)._execute_effects(
            [{"effect_type": "__unknown_effect__", "params": {}}],
            0,
            "active",
        )

        self.assertFalse(result.success)
        self.assertIn("No native command registered", result.log_message)

    def test_foundational_effects_use_native_commands(self):
        native_effect_types = {
            "damage",
            "damage_counter_self",
            "damage_per_discard_psychic",
            "damage_per_energy",
            "damage_per_evolved",
            "damage_per_hand_size",
            "damage_plus_bench",
            "damage_per_self_damage",
            "damage_per_self_energy",
            "damage_per_self_energy_type",
            "damage_self_penalty",
            "attack_damage_formula",
            "conditional_damage_bonus",
            "conditional_damage_heal",
            "damage_and_self_heal",
            "discard_hand_conditional_bonus",
            "discard_fighting_energy_damage",
            "mill_and_damage_per_energy",
            "any_pokemon_damage",
            "bench_damage",
            "place_counters_and_self_ko",
            "status",
            "conditional_status",
            "draw",
            "draw_until",
            "draw_until_more",
            "shuffle_draw",
            "judge",
            "shuffle_from_discard",
            "clara",
            "hand_to_bottom_draw",
            "houb",
            "zinnia_resolve",
            "search",
            "conditional",
            "look_top_deck",
            "look_top_attach_energy",
            "draw_and_attach_energy",
            "arven",
            "trekking_shoes",
            "attach_from_discard",
            "coin_flip_triple",
            "coin_flip_double_ko",
            "coin_flip_until_tails",
            "coin_flip_energy_discard",
            "conditional_search_extra",
            "search_any_and_switch",
            "ability_discard_revive",
            "tool_exp_share",
            "evolve_skip_stage",
            "discard",
            "discard_draw",
            "discard_then_draw",
            "energy_attach",
            "energy_discard",
            "energy_relocate",
            "heal",
            "heal_all",
            "potion_heal",
            "switch_self",
            "switch_opponent",
            "coin_flip",
            "attack_fail",
            "piercing_marker",
            "return_to_hand",
            "dazzling_beam",
            "attack_lock_basic",
            "apply_outgoing_damage_reduction",
            "self_attack_lock",
            "prevent_damage",
            "prevent_effects",
            "prevent_all",
            "tool",
            "aura_damage_reduction",
            "aura_damage_boost",
            "conditional_hp_boost",
            "conditional_zero_retreat",
            "reactive_thorns",
        }
        for effect_type in native_effect_types:
            with self.subTest(effect_type=effect_type):
                command = compile_effect({"effect_type": effect_type, "params": {}})
                self.assertEqual(type(command).__module__, "engine.commands.primitives")

    def test_set_attack_damage_formula_is_native_primitive(self):
        from engine.commands.primitives import SetAttackDamageFormula

        execute_source = inspect.getsource(SetAttackDamageFormula.execute)
        self.assertNotIn("_handle_attack_damage_formula", execute_source)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "set_attack_damage_formula",
            "args": {"base": 30},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(result.damage_dealt, 30)
        self.assertEqual(state.p2.active.damage_counters, 3)

    def test_primitives_do_not_import_legacy_effect_module(self):
        import engine.commands.primitives as primitives

        source = Path(primitives.__file__).read_text(encoding="utf-8")
        self.assertNotIn("engine.effects", source)
        self.assertNotIn("execute_effect(", source)
        self.assertFalse(hasattr(primitives, "NoOp"))

    def test_engine_effects_package_does_not_expose_dispatcher(self):
        import engine.effects as effects_package

        self.assertFalse(hasattr(effects_package, "execute_effect"))

    def test_action_resolver_does_not_expose_single_effect_shim(self):
        from engine.action_resolver import ActionResolver

        self.assertFalse(hasattr(ActionResolver, "_execute_effect"))

    def test_vm_command_specs_execute_without_effect_type(self):
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "deal_damage", "args": {"amount": 20}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 2)

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "apply_status", "args": {"status": "asleep"}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIn(StatusType.ASLEEP, state.p2.active.status_conditions)

        state.p1.deck = [CardRegistry.get("sv1-ener-2"), CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_until", "args": {"target_hand_size": 3}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(len(state.p1.hand), 3)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-1")]
        state.p2.hand = [
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-4"),
        ]
        state.p1.deck = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-6"),
            CardRegistry.get("sv1-ener-7"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_until_more_than_opponent", "args": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(len(state.p1.hand), 4)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p1.deck = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-4")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "shuffle_then_draw_cards",
            "args": {"shuffle_hand": True, "draw": 2},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(len(state.p1.hand), 2)
        self.assertEqual(len(state.p1.deck), 2)
        self.assertCountEqual(
            [card.api_id for card in state.p1.hand + state.p1.deck],
            ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4"],
        )

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-1")]
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.p2.hand = []
        state.p2.deck = [CardRegistry.get("sv1-ener-3")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "judge", "args": {"draw": 1}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(len(state.p1.hand), 1)
        self.assertEqual(len(state.p1.deck), 1)
        self.assertCountEqual(
            [card.api_id for card in state.p1.hand + state.p1.deck],
            ["sv1-ener-1", "sv1-ener-2"],
        )
        self.assertEqual(state.p2.hand, [])
        self.assertEqual([card.api_id for card in state.p2.deck], ["sv1-ener-3"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.p1.discard = [
            CardRegistry.get("sv1-104"),
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("svf-potion"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "shuffle_from_discard_to_deck",
            "args": {"filter": "pokemon_and_energy", "count": 2},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "recover_from_discard_to_deck",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "recover_from_discard_to_deck",
        )
        selected = tuple(
            option.option_id
            for option in request.options
            if getattr(option.ref, "card_id", "") in {"sv1-104", "sv1-ener-1"}
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, selected))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.discard], ["svf-potion"])
        self.assertCountEqual(
            [card.api_id for card in state.p1.deck],
            ["sv1-ener-2", "sv1-104", "sv1-ener-1"],
        )

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.discard = [
            CardRegistry.get("sv1-104"),
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("svf-potion"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "recover_clara",
            "args": {"pokemon_count": 1, "energy_count": 1},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "recover_clara",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "recover_clara",
        )
        selected = tuple(option.option_id for option in request.options)
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, selected))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-104", "sv1-ener-1"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p1.deck = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-4")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "hand_to_bottom_then_draw", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "hand_to_bottom_then_draw",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "hand_to_bottom_then_draw",
        )
        selected = tuple(
            option.option_id
            for option in request.options
            if getattr(option.ref, "card_id", "") == "sv1-ener-1"
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, selected))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2", "sv1-ener-4"])
        self.assertEqual([card.api_id for card in state.p1.deck], ["sv1-ener-1", "sv1-ener-3"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p1.deck = [
            CardRegistry.get("sv1-ener-4"),
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-6"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "hand_to_bottom_draw_until",
            "args": {"target_hand_size": 5},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "hand_to_bottom_draw_until",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "hand_to_bottom_draw_until",
        )
        first_card = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "card_id", "") == "sv1-ener-1"
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (first_card,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual(
            [card.api_id for card in state.p1.hand],
            ["sv1-ener-2", "sv1-ener-3", "sv1-ener-6", "sv1-ener-5", "sv1-ener-4"],
        )
        self.assertEqual([card.api_id for card in state.p1.deck], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-6")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {"amount": 1, "from_zone": "deck", "filter": "fighting", "to": "self"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-6"])
        self.assertEqual([card.api_id for card in state.p1.deck], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p1.hand = [CardRegistry.get("sv1-ener-4")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {"amount": 1, "from_zone": "hand", "filter": "lightning", "to": "bench", "optional": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_energy_to_bench",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "select_own_bench_energy")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_energy_to_bench",
        )
        self.assertEqual(request.min_select, 0)
        bench_zero = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "bench_0")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (bench_zero,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-4"])
        self.assertEqual(state.p1.hand, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {"amount": 1, "from_zone": "hand", "filter": "fire", "to": "any"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_energy_to_board",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "search_deck")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_energy_to_board",
        )
        active_option = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "active")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (active_option,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-2"])
        self.assertEqual(state.p1.hand, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p1.deck = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {
                "amount": 2,
                "from_zone": "deck",
                "filter": "basic_energy",
                "to": "bench",
                "max_per_target": 1,
                "min_select": 0,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_energy_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "distribute_energy")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_energy_distribution",
        )
        self.assertEqual(request.min_select, 0)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 1)
        self.assertEqual(state.p1.deck, [])

        state = GameState()
        state.first_player_idx = 1
        state.active_player_idx = 0
        state.turn_number = 2
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-5"),
            CardRegistry.get("sv1-ener-5"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {"amount": 1, "from_zone": "deck", "filter": "psychic", "to": "any", "going_second_bonus": 3},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_energy_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_energy_distribution",
        )
        self.assertEqual(request.max_select, 3)
        active_target = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "active")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (active_target, active_target, active_target)))
        self.assertTrue(step.success, step.message)
        self.assertEqual(len(state.p1.active.energy_cards), 3)
        self.assertEqual(state.p1.deck, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svg2-tort"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-3")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {"amount": 2, "from_zone": "deck", "filter": "water", "to": "self_basic", "min_select": 0},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_energy_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_energy_distribution",
        )
        self.assertEqual([getattr(option.ref, "slot", "") for option in request.options], ["bench_0"])
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id, request.options[0].option_id)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 2)
        self.assertEqual(state.p1.deck, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.discard = [CardRegistry.get("sv1-ener-2"), CardRegistry.get("sv1-ener-1")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy_from_discard",
            "args": {"amount": 1, "energy_type": "fire", "target": "self"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p1.discard = [CardRegistry.get("sv1-ener-7")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy_from_discard",
            "args": {"amount": 1, "energy_type": "darkness", "target": "bench"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_discard_energy_to_bench",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "select_own_bench_energy")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_discard_energy_to_bench",
        )
        bench_one = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "bench_1")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (bench_one,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.bench[1].energy_cards], ["sv1-ener-7"])
        self.assertEqual(state.p1.discard, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.discard = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy_from_discard",
            "args": {"amount": 1, "energy_type": "fire", "target": "self_or_bench"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_discard_energy_to_board",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "search_deck")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_discard_energy_to_board",
        )
        active_option = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "active")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (active_option,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-2"])
        self.assertEqual(state.p1.discard, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p1.discard = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy_from_discard",
            "args": {"amount": 2, "energy_type": "basic", "target": "bench", "min_select": 0},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "attach_discard_energy_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "distribute_energy")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "attach_discard_energy_distribution",
        )
        self.assertEqual(request.min_select, 0)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 1)
        self.assertEqual(state.p1.discard, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svd-seviper"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.discard = [CardRegistry.get("sv1-ener-7")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy_from_discard",
            "args": {
                "amount": 1,
                "energy_type": "Darkness",
                "target": "bench",
                "target_pokemon_type": "Darkness",
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNone(result.pending_choice)
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-7"])
        self.assertEqual(state.p1.bench[1].energy_cards, [])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "relocate_energy",
            "args": {"amount": 1, "from_self": True, "energy_type": "basic_energy"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNone(result.pending_choice)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "relocate_energy",
            "args": {"amount": 99, "from_self": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "energy_relocate_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "distribute_energy")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "energy_relocate_distribution",
        )
        self.assertEqual(request.min_select, 2)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.energy_cards, [])
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 1)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[0].energy_cards = [CardRegistry.get("sv1-ener-3")]
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "relocate_energy",
            "args": {"amount": 2, "min_select": 0, "same_target": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "energy_relocate_source",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.metadata.get("distribute_mode"), "source_select")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "energy_relocate_source",
        )
        active_source = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "active")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (active_source,)))
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "energy_relocate_distribution",
        )
        bench_one = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "bench_1")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (bench_one, bench_one)))
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.energy_cards, [])
        self.assertEqual([card.api_id for card in state.p1.bench[1].energy_cards], ["sv1-ener-1", "sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-3"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-104"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p1.deck = [CardRegistry.get("sv1-ener-4"), CardRegistry.get("sv1-ener-5")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "zinnia_resolve", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "zinnia_resolve",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "zinnia_resolve",
        )
        selected = tuple(option.option_id for option in request.options[:2])
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, selected))
        self.assertTrue(step.success, step.message)
        self.assertCountEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1", "sv1-ener-2"])
        self.assertEqual(
            [card.api_id for card in state.p1.hand],
            ["sv1-ener-3", "sv1-ener-5", "sv1-ener-4"],
        )

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-104"),
            CardRegistry.get("sv1-ener-2"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "search_cards",
            "args": {
                "from_zone": "deck",
                "filter": "basic_pokemon",
                "destination": "bench",
                "count": 1,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "search_cards",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_cards",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(state.p1.bench[0])
        self.assertEqual(state.p1.bench[0].card.api_id, "sv1-104")
        self.assertCountEqual([card.api_id for card in state.p1.deck], ["sv1-ener-1", "sv1-ener-2"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.discard = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("svf-potion")]
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}))
        stack.push(compile_command_spec({
            "op": "search_cards",
            "args": {
                "from_zone": "discard",
                "filter": "basic_energy",
                "destination": "hand",
                "count": 1,
                "min_select": 0,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "search_cards",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_cards",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-1", "sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("svf-potion"), CardRegistry.get("sv1-ener-1")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "look_top_deck",
            "args": {
                "count": 2,
                "take": 1,
                "filter": "energy",
                "destination": "hand",
                "rest_bottom": True,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "look_top_deck")
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.metadata.get("continuation", {}).get("kind"), "look_top_deck")
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-1"])
        self.assertEqual([card.api_id for card in state.p1.deck], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("svf-potion"), CardRegistry.get("sv1-ener-4")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "look_top_deck",
            "args": {
                "count": 2,
                "take": 1,
                "filter": "lightning_energy",
                "destination": "bench_energy",
                "shuffle_rest": True,
                "min_select": 0,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "look_top_deck")
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.metadata.get("continuation", {}).get("kind"), "look_top_deck")
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNone(step.pending_choice)
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-4"])
        self.assertEqual([card.api_id for card in state.p1.deck], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svl-pikaex"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [
            CardRegistry.get("svf-potion"),
            CardRegistry.get("sv1-ener-4"),
            CardRegistry.get("sv1-ener-4"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "look_top_deck",
            "args": {
                "count": 3,
                "take": 2,
                "filter": "lightning_energy",
                "destination": "bench_energy",
                "shuffle_rest": True,
                "min_select": 0,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        request = engine.choice_request(state, result.pending_choice)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "look_top_bench_energy_distribution",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.bench[1].energy_cards), 1)
        self.assertEqual([card.api_id for card in state.p1.deck], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [
            CardRegistry.get("svf-potion"),
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "look_top_attach_energy",
            "args": {"count": 3, "take": 2, "filter": "basic_energy"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "look_top_attach_energy")
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.metadata.get("continuation", {}).get("kind"), "look_top_attach_energy")
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "look_top_attach_target",
        )
        bench_zero = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_0"
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (bench_zero,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual(
            [card.api_id for card in state.p1.bench[0].energy_cards],
            ["sv1-ener-2", "sv1-ener-1"],
        )
        self.assertEqual([card.api_id for card in state.p1.deck], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-1")]
        state.p1.deck = [CardRegistry.get("sv1-ener-1")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "draw_and_attach_energy",
            "args": {"energy_count": 2, "energy_type": "Grass", "min_select": 0},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "draw_and_attach_energy_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "draw_and_attach_energy_distribution",
        )
        self.assertEqual(request.min_select, 0)
        self.assertEqual(request.max_select, 2)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(len(state.p1.bench[0].energy_cards), 1)
        self.assertEqual(len(state.p1.hand), 1)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p1.deck = [CardRegistry.get("sv1-104")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional",
            "args": {},
            "branches": {
                "cost": [{
                    "op": "discard_cards",
                    "args": {"amount": 2, "from": "hand"},
                    "branches": {},
                }],
                "on_pay": [{
                    "op": "search_cards",
                    "args": {
                        "from_zone": "deck",
                        "filter": "pokemon",
                        "destination": "hand",
                        "count": 1,
                    },
                    "branches": {},
                }],
            },
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "discard_hand_cards",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "discard_hand_cards",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:2])),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_cards",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertCountEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1", "sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-3", "sv1-104"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.was_ko_by_attack = True
        state.p1.deck = [CardRegistry.get("sv1-ener-1")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional",
            "args": {"condition": "ko_by_attack_last_turn"},
            "branches": {
                "on_pay": [{
                    "op": "draw_cards",
                    "args": {"amount": 1},
                    "branches": {},
                }],
            },
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(state.p1.was_ko_by_attack)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("svf-potion"),
            CardRegistry.get("svl-vitb"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "search_item_and_tool", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "search_item_and_tool",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_item_and_tool",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["svf-potion", "svl-vitb"])
        self.assertEqual([card.api_id for card in state.p1.deck], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("svf-potion")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "trekking_shoes", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "trekking_shoes",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "trekking_shoes",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:no",)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-1"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["svf-potion"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "flip_coin_repeat_damage",
            "args": {"flips": 3, "damage_per_head": 10},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "coin_special")
        self.assertEqual(result.pending_choice.continuation.get("coin_kind"), "repeat_damage")
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.metadata.get("continuation", {}).get("kind"), "coin_special")
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("coin:heads", "coin:tails", "coin:heads")),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 2)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "flip_until_tails",
            "args": {"per_head": 20},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "coin_special")
        self.assertEqual(result.pending_choice.continuation.get("coin_kind"), "until_tails")
        request = engine.choice_request(state, result.pending_choice)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("coin:heads", "coin:heads", "coin:tails")),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 4)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "flip_coin_then_ko", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "coin_special")
        self.assertEqual(result.pending_choice.continuation.get("coin_kind"), "double_ko")
        request = engine.choice_request(state, result.pending_choice)
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("coin:heads", "coin:heads")),
        )
        self.assertTrue(step.success, step.message)
        self.assertTrue(state.p2.active.is_knocked_out)

        state = GameState()
        state.first_player_idx = 0
        state.active_player_idx = 1
        state.turn_number = 2
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.deck = [
            CardRegistry.get("svg2-zaru"),
            CardRegistry.get("sv1-104"),
            CardRegistry.get("svg2-tort"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional_search",
            "args": {"filter": "grass_pokemon", "max_count": 3, "default_count": 1},
            "branches": {},
        }))
        result = stack.resolve_all(1, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        request = engine.choice_request(state, result.pending_choice)
        selected = tuple(option.option_id for option in request.options)
        self.assertEqual(request.min_select, 0)
        self.assertEqual(request.max_select, 2)
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, selected))
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p2.hand], ["svg2-zaru", "svg2-tort"])
        self.assertEqual([card.api_id for card in state.p2.deck], ["sv1-104"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-tatsu"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-1")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "search_any_and_switch",
            "args": {"count": 1, "min_select": 0, "switch_optional": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "search_any_and_switch",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_any_and_switch",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_any_switch_confirm",
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, ("confirm:yes",)))
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.card.api_id, "svf-rio")
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-1"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-tatsu"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "search_any_and_switch",
            "args": {"count": 1, "min_select": 0, "switch_optional": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "search_any_and_switch",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_any_and_switch",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, ("confirm:yes",)))
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "search_any_switch_bench",
        )
        bench_one = next(option.option_id for option in request.options if getattr(option.ref, "slot", "") == "bench_1")
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (bench_one,)))
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.card.api_id, "svi-chim")

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = []
        state.p1.discard = [CardRegistry.get("svg2-empo")]
        state.p1.deck = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "discard_then_revive",
            "args": {"card_id": "svg2-empo"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p1.bench[0].card.api_id, "svg2-empo")
        self.assertEqual(state.p1.discard, [])
        self.assertEqual(
            [card.api_id for card in state.p1.hand],
            ["sv1-ener-3", "sv1-ener-2", "sv1-ener-1"],
        )

        state = GameState()
        state.turn_number = 3
        state.p1.active = PokemonInPlay(CardRegistry.get("svg2-turt"))
        state.p1.active.placed_this_turn = False
        state.p1.active.can_evolve_this_turn = True
        state.p1.hand = [CardRegistry.get("svg2-tort")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "evolve_skip_stage", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success, result.log_messages)
        self.assertEqual(state.p1.active.card.api_id, "svg2-tort")
        self.assertEqual([card.api_id for card in state.p1.active.evolution_stack], ["svg2-turt"])
        self.assertEqual(state.p1.hand, [])
        self.assertFalse(state.p1.active.can_evolve_this_turn)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-1")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "flip_coin_then_discard_energy",
            "args": {},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "coin_energy_discard")
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "coin_energy_discard",
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, ("coin:heads",)))
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        request = step.pending_choice
        self.assertFalse(request.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "discard_attachment",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.energy_cards, [])
        self.assertEqual([card.api_id for card in state.p2.discard], ["sv1-ener-1"])

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_tool_exp_share",
            "args": {},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)

        from engine.action_resolver import ActionResolver

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[0].attached_tool = CardRegistry.get("svg2-exps")
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_tool_exp_share",
            "args": {},
            "branches": {},
        }))
        result = stack.resolve_all(0, "bench_0")
        self.assertTrue(result.success)
        state._ko_from_attack = True
        ActionResolver(state)._handle_ko(0, "active")
        state._ko_from_attack = False
        self.assertIsNone(state.p1.active)
        self.assertEqual([card.api_id for card in state.p1.bench[0].energy_cards], ["sv1-ener-2"])
        self.assertNotIn("sv1-ener-2", [card.api_id for card in state.p1.discard])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.active.damage_counters = 3
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"), damage_counters=2)
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "heal_all", "args": {"amount": 20}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p1.active.damage_counters, 1)
        self.assertEqual(state.p1.bench[0].damage_counters, 0)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"), damage_counters=4)
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"), damage_counters=5)
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({"op": "choose_heal_damage", "args": {"amount": 30}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "choose_heal_damage",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "choose_heal_damage",
        )
        bench_zero = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_0"
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (bench_zero,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.damage_counters, 4)
        self.assertEqual(state.p1.bench[0].damage_counters, 2)
        self.assertTrue(state.p1.healed_this_turn)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        state.p1.was_ko_by_attack = True
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional_status",
            "args": {"status": "paralyzed", "condition": "ko_by_attack_last_turn"},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIn(StatusType.PARALYZED, state.p2.active.status_conditions)

        state = GameState()
        state.turn_number = 7
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "apply_dazzling_beam",
            "args": {"target": "opponent_active"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertTrue(state.p2.active.dazzled)

        state.p2.active.dazzled = False
        state.p2.active.all_prevented_next_turn = True
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "apply_dazzling_beam",
            "args": {"target": "opponent_active"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertFalse(state.p2.active.dazzled)
        self.assertFalse(state.p2.active.all_prevented_next_turn)

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "apply_attack_lock_basic",
            "args": {"target": "opponent_active"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertTrue(state.p2.active.attack_locked)

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "apply_outgoing_damage_reduction",
            "args": {
                "target": "opponent_active",
                "amount": 50,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.outgoing_damage_reduction_next_turn, 50)

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "apply_self_attack_lock",
            "args": {"attack_name": "漆黑之刃"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p1.active.attack_locked_names["漆黑之刃"], 7)

        from engine.commands.damage_pipeline import resolve_damage
        from engine.rules_validator import effective_retreat_cost

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-ente"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_aura_damage_reduction",
            "args": {"reduction": 20},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        damage, _logs = resolve_damage(
            state,
            state.p2.active,
            state.p1.active,
            100,
            "Colorless",
        )
        self.assertEqual(damage, 80)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svm-zacian"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svm-cobalion"))
        state.p2.active = PokemonInPlay(CardRegistry.get("svd-seviper"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_aura_damage_boost",
            "args": {
                "amount": 30,
                "attacker_subtype": "Basic",
                "defender_type": "Darkness",
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "bench_0")
        self.assertTrue(result.success)
        damage, _logs = resolve_damage(
            state,
            state.p1.active,
            state.p2.active,
            100,
            "Metal",
        )
        self.assertEqual(damage, 130)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-maus"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-maus"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_reactive_thorns",
            "args": {
                "filter_names": ["一对鼠", "一家鼠ex", "一家鼠"],
                "per_pokemon": 3,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        damage, _logs = resolve_damage(
            state,
            state.p2.active,
            state.p1.active,
            50,
            "Colorless",
        )
        self.assertEqual(damage, 50)
        self.assertEqual(state.p2.active.damage_counters, 6)

        from dataclasses import replace

        state = GameState()
        retreat_card = replace(
            CardRegistry.get("svi-chim"),
            api_id="test-retreater",
            retreat_cost=2,
            abilities=[],
        )
        state.p1.active = PokemonInPlay(retreat_card)
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-5")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_conditional_zero_retreat",
            "args": {"energy_type": "psychic"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(effective_retreat_cost(state, state.p1), 0)

        state = GameState()
        hp_card = replace(
            CardRegistry.get("svi-chim"),
            api_id="test-hp-boost",
            hp=100,
            abilities=[],
        )
        state.p1.active = PokemonInPlay(hp_card)
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-8"),
            CardRegistry.get("sv1-ener-8"),
            CardRegistry.get("sv1-ener-8"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_conditional_hp_boost",
            "args": {
                "energy_type": "Metal",
                "threshold": 3,
                "amount": 100,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p1.active.current_hp, 200)
        cloned = clone_state(state)
        self.assertEqual(cloned.p1.active.current_hp, 200)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_tool_modifier",
            "args": {"effect": "damage_boost_10"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        damage, _logs = resolve_damage(
            state,
            state.p1.active,
            state.p2.active,
            100,
            "Fire",
        )
        self.assertEqual(damage, 110)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "flip_coin",
            "args": {},
            "branches": {
                "on_heads": [{"op": "deal_damage", "args": {"amount": 10}}],
                "on_tails": [{"op": "fail_attack", "args": {}}],
            },
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "flip_coin_branch",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "flip_coin_branch",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("coin:heads",)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 1)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "switch_pokemon",
            "args": {"target": "self"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "switch_bench",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "switch_bench",
        )
        bench_one = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_1"
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (bench_one,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.card.api_id, "sv1-113")
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "switch_pokemon",
            "args": {"target": "self", "optional": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "switch_confirm",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "switch_confirm",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        self.assertFalse(step.pending_choice.legacy_request._resolution_stack_had_callback)
        self.assertEqual(
            step.pending_choice.metadata.get("continuation", {}).get("kind"),
            "switch_bench",
        )
        bench_one = next(
            option.option_id
            for option in step.pending_choice.options
            if getattr(option.ref, "slot", "") == "bench_1"
        )
        step = engine.apply_choice(
            state,
            step.pending_choice,
            ChoiceResponse(step.pending_choice.request_id, (bench_one,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p1.active.card.api_id, "sv1-113")
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p1.deck = [CardRegistry.get("sv1-ener-4")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "discard_cards",
            "args": {"amount": 2, "from": "hand"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "discard_hand_cards",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "discard_hand_cards",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(
                request.request_id,
                tuple(option.option_id for option in request.options[:2]),
            ),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv1-ener-2", "sv1-ener-1"])
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-3", "sv1-ener-4"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("sv1-ener-1"), CardRegistry.get("sv1-ener-2")]
        state.p1.deck = [CardRegistry.get("sv1-ener-3"), CardRegistry.get("sv1-ener-4")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "discard_then_draw_cards",
            "args": {"discard_hand": True, "draw": 2},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1", "sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-4", "sv1-ener-3"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p1.deck = [CardRegistry.get("sv1-ener-4"), CardRegistry.get("sv1-ener-5")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "discard_then_draw_cards",
            "args": {"discard_amount": 1, "draw_amount": 1},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "discard_hand_then_draw",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "discard_hand_then_draw",
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1"])
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2", "sv1-ener-3", "sv1-ener-5"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active.energy_cards = [CardRegistry.get("sv1-ener-3")]
        state.p1.deck = [CardRegistry.get("sv1-ener-4")]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "discard_energy",
            "args": {"amount": 1, "from": "self", "filter": "any"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1"])
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-4"])

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "discard_energy",
            "args": {"amount": 1, "from": "opponent", "filter": "any"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.energy_cards, [])
        self.assertEqual([card.api_id for card in state.p2.discard], ["sv1-ener-3"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_hand_size",
            "args": {"per": 10},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 3)

        state.p2.active.damage_counters = 0
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_plus_bench",
            "args": {"base": 10, "per_bench": 20},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 5)

        state.p1.active.damage_counters = 2
        state.p2.active.damage_counters = 0
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_self_damage",
            "args": {"base": 60, "per_counter": 10},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 8)

        state.p1.active.damage_counters = 3
        state.p2.active.damage_counters = 0
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_with_self_penalty",
            "args": {"base": 200, "per_counter": 20},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 14)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"), damage_counters=1)
        state._attack_damage_context = {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 30,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        }
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional_damage",
            "args": {"bonus": 120, "condition": "opponent_active_damaged"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state._attack_damage_context["base_damage"], 150)
        self.assertEqual(state.p2.active.damage_counters, 1)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.was_ko_by_attack = True
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional_damage",
            "args": {"bonus": 90, "condition": "ko_by_attack_last_turn"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 9)
        self.assertFalse(state.p1.was_ko_by_attack)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-4"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "discard_hand_then_damage",
            "args": {"threshold": 5, "base_damage": 60, "bonus": 150},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p1.hand, [])
        self.assertEqual(
            [card.api_id for card in state.p1.discard],
            ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4"],
        )
        self.assertEqual(state.p2.active.damage_counters, 6)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-6"),
            CardRegistry.get("sv1-ener-5"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "discard_energy_then_damage",
            "args": {"base": 10, "per_energy": 60},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["sv1-ener-5"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv1-ener-6"])
        self.assertEqual(state.p2.active.damage_counters, 7)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [
            CardRegistry.get("sv2-delib"),
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "mill_then_damage",
            "args": {"mill_count": 3, "damage_per": 40},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertCountEqual([card.api_id for card in state.p1.discard], ["sv1-ener-1", "sv1-ener-2"])
        self.assertEqual(state.p2.active.damage_counters, 8)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.healed_this_turn = True
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "conditional_damage_then_heal",
            "args": {"base": 60, "bonus": 90},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 15)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"), damage_counters=3)
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_then_heal",
            "args": {"damage": 10, "heal": 20},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 1)
        self.assertEqual(state.p1.active.damage_counters, 1)
        self.assertTrue(state.p1.healed_this_turn)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active.energy_cards = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
        ]
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_energy",
            "args": {
                "base": 10,
                "per_energy": 20,
                "count_from": "opponent_active",
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 5)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-5"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_self_energy",
            "args": {
                "base": 30,
                "per_energy": 30,
                "energy_filter": "fire",
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 6)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_self_energy_type",
            "args": {
                "base": 60,
                "per_energy": 20,
                "energy_type": "Grass",
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 8)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.discard = [CardRegistry.get("sv1-106"), CardRegistry.get("svi-chim")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_discard_psychic",
            "args": {"base": 80, "per_card": 10},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 9)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svg2-tort"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage_per_evolved",
            "args": {"per_evolved": 50},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 10)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"), damage_counters=2)
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"), damage_counters=1)
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv2-38"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state._attack_damage_context = {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 0,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        }
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "set_attack_damage_formula",
            "args": {
                "base": 100,
                "per_own_bench": 20,
                "per_self_energy_type": "Fire",
                "per_energy": 30,
                "per_self_damage_counter": 10,
                "condition_bonus": {
                    "condition": "own_bench_damaged",
                    "bonus": 50,
                    "consume": False,
                },
                "piercing": True,
                "ignore_defender_effects": True,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state._attack_damage_context["base_damage"], 240)
        self.assertTrue(state._attack_damage_context["piercing"])
        self.assertTrue(state._attack_damage_context["ignore_defender_effects"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state._attack_damage_context = {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 0,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        }
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "deal_damage", "args": {"amount": 30}}))
        stack.push(compile_command_spec({
            "op": "set_attack_flags",
            "args": {"ignore_weakness": True, "ignore_resistance": True, "ignore_effects": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state._attack_damage_context["base_damage"], 30)
        self.assertTrue(state._attack_damage_context["piercing"])
        self.assertTrue(state._attack_damage_context["ignore_defender_effects"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-tatsu"))
        energy = CardRegistry.get("sv1-ener-3")
        tool = CardRegistry.get("svl-vitb")
        evo = CardRegistry.get("sv2-38")
        state.p1.active.energy_cards = [energy]
        state.p1.active.attached_tool = tool
        state.p1.active.evolution_stack = [evo]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "return_to_hand", "args": {}, "branches": {}}))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNone(state.p1.active)
        self.assertEqual(
            [card.api_id for card in state.p1.hand],
            ["svl-vitb", "sv2-38", "sv1-ener-3", "sv2-tatsu"],
        )

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-104"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_bench_damage",
            "args": {"amount": 10, "count": 5, "player": "opponent", "choose_targets": False},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.bench[0].damage_counters, 1)
        self.assertEqual(state.p2.bench[1].damage_counters, 1)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv1-113"))
        state.p2.bench[1] = PokemonInPlay(CardRegistry.get("sv1-104"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "deal_bench_damage",
            "args": {"amount": 30, "count": 1, "player": "opponent", "choose_targets": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "bench_damage_targets",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "bench_damage_targets",
        )
        bench_one = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_1"
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (bench_one,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.bench[0].damage_counters, 0)
        self.assertEqual(state.p2.bench[1].damage_counters, 3)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-grex"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv2-staryu"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "choose_damage_target",
            "args": {"amount": 40, "player": "opponent", "piercing_on_bench": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertEqual(result.pending_choice.request_type, "search_deck")
        self.assertEqual(result.pending_choice.from_zone, "board")
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "choose_damage_target",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "choose_damage_target",
        )
        bench_zero = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_0"
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (bench_zero,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.active.damage_counters, 0)
        self.assertEqual(state.p2.bench[0].damage_counters, 4)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("sv2-starm"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv2-staryu"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({"op": "draw_cards", "args": {"amount": 1}}))
        stack.push(compile_command_spec({
            "op": "place_counters_then_self_ko",
            "args": {"counters": 2, "target_player": "opponent"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIsNotNone(result.pending_choice)
        self.assertFalse(result.pending_choice._resolution_stack_had_callback)
        self.assertEqual(
            result.pending_choice.continuation.get("kind"),
            "place_counters_then_self_ko",
        )
        engine = GameEngine()
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "place_counters_then_self_ko",
        )
        bench_zero = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_0"
        )
        step = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (bench_zero,)),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(state.p2.bench[0].damage_counters, 2)
        self.assertIsNone(state.p1.active)
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv2-starm"])
        self.assertEqual(state.pending_promotion_player, 0)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

    def test_nested_effect_branches_are_serialized(self):
        coin_flip = next(
            effect
            for effect in _walk_effects(CARD_EFFECTS)
            if effect.get("effect_type") == "coin_flip"
        )
        spec = compile_effect_to_spec(coin_flip).to_dict()
        self.assertEqual(spec["op"], "flip_coin")
        self.assertIn("on_heads", spec["branches"])
        self.assertIn("on_tails", spec["branches"])
        self.assertEqual(spec["branches"]["on_heads"][0]["op"], "deal_damage")
        self.assertEqual(spec["branches"]["on_tails"][0]["op"], "fail_attack")

    def test_exported_cards_include_compiled_effects(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output = Path(output_dir)
            export(output, copy_images=False)
            cards = json.loads((output / "data" / "cards.json").read_text(encoding="utf-8"))
            contract = json.loads(
                (output / "tests" / "fixtures" / "data_contract.json").read_text(
                    encoding="utf-8"
                )
            )

        card = next(
            row
            for row in cards.values()
            if any(attack["effects"] for attack in row["attacks"])
        )
        attack = next(attack for attack in card["attacks"] if attack["effects"])
        self.assertEqual(len(attack["compiled_effects"]), len(attack["effects"]))
        self.assertIn("op", attack["compiled_effects"][0])
        self.assertEqual(len(contract["compiled_effect_examples"]), 78)

    def test_special_energy_metadata_drives_energy_providers(self):
        double_turbo = CardRegistry.get("svi-dtur")
        jet = CardRegistry.get("svi-jete")
        miracle = CardRegistry.get("svi-mirc")
        luminous = CardRegistry.get("svg2-lume")

        self.assertEqual(double_turbo.provides_energy, ["Colorless", "Colorless"])
        self.assertEqual(jet.provides_energy, ["Colorless"])
        self.assertEqual(miracle.provides_energy, ["Colorless"])
        self.assertEqual(luminous.provides_energy, ["Rainbow"])
        self.assertTrue(
            any(
                effect.get("hook") == "AFTER_DAMAGE"
                for effect in miracle.energy_effects
            )
        )

    def test_snapshot_and_clone_preserve_resolution_stack(self):
        state = GameState()
        state.resolution_stack = {
            "frames": [{"op": "draw_cards", "args": {"amount": 1}}],
            "pending_request": {"request_id": "choice:1"},
            "sequence": 7,
            "context": {"player": 0},
        }
        snap = snapshot_state(state)
        state.resolution_stack["frames"].append({"op": "deal_damage"})

        restore_state(state, snap)
        self.assertEqual(state.resolution_stack, snap.resolution_stack)

        clone = clone_state(state)
        self.assertEqual(clone.resolution_stack, state.resolution_stack)
        clone.resolution_stack["context"]["player"] = 1
        self.assertEqual(state.resolution_stack["context"]["player"], 0)


if __name__ == "__main__":
    unittest.main()

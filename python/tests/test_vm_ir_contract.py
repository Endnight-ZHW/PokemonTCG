import ast
import json
import inspect
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from card_data.effects import CARD_EFFECTS
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.commands.dsl_compiler import (
    compile_command_spec,
    compile_effect,
    compile_effects_to_payload,
    compile_effect_to_spec,
    missing_ir_effect_types,
)
from engine.commands.attack_frames import (
    FinalizeAttackDamage,
    attack_damage_context,
    begin_attack_damage_context,
)
from engine.commands.vm_contract import VM_IR_VERSION, validate_command_spec
from engine.commands.vm_registry import DEFAULT_COMMAND_REGISTRY, ContinuationRegistry
from engine.commands.resolution_stack import ResolutionStack
from engine.commands.trigger_commands import (
    collect_on_attach_command_specs,
    command_specs_from_trigger_results,
    execute_trigger_commands,
)
from engine.effects.modifier_manager import MAX_HP, MODIFY_DAMAGE
from engine.actions import ChoiceResponse
from engine.enums import EventType, PlayerAction, StatusType, TurnPhase
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

    def assertNativeCommandModule(self, command):
        module = type(command).__module__
        self.assertTrue(
            module == "engine.commands.primitives"
            or module.startswith("engine.commands.primitives_"),
            module,
        )

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
                self.assertNativeCommandModule(command)

    def test_attack_state_bridge_fields_are_not_used_by_production_code(self):
        import engine.commands.attack_frames as attack_frames
        import engine.commands.primitives_attack as primitives_attack
        import engine.commands.primitives_combat as primitives_combat
        import engine.effects.damage_effects as damage_effects
        import engine.effects.special_effects as special_effects
        import engine.game_state as game_state
        import engine.snapshot as snapshot

        forbidden = (
            "._attack_damage_context",
            "._piercing_attack",
            "._attack_ignore_defender_effects",
        )
        modules = (
            primitives_attack,
            primitives_combat,
            damage_effects,
            special_effects,
            attack_frames,
            game_state,
            snapshot,
        )
        for module in modules:
            source = inspect.getsource(module)
            for token in forbidden:
                with self.subTest(module=module.__name__, token=token):
                    self.assertNotIn(token, source)

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

    def test_damage_formula_effects_compile_to_formula_ast(self):
        formula_effects = {
            "damage_per_discard_psychic",
            "damage_per_energy",
            "damage_per_evolved",
            "damage_per_hand_size",
            "damage_per_self_damage",
            "damage_per_self_energy",
            "damage_per_self_energy_type",
            "damage_plus_bench",
            "damage_self_penalty",
            "attack_damage_formula",
        }
        found = {
            effect.get("effect_type"): compile_effect_to_spec(effect).to_dict()
            for effect in _walk_effects(CARD_EFFECTS)
            if effect.get("effect_type") in formula_effects
        }
        self.assertEqual(set(found), formula_effects)
        for effect_type in formula_effects:
            with self.subTest(effect_type=effect_type):
                spec = found[effect_type]
                self.assertEqual(spec["op"], "deal_damage")
                self.assertIn("formula_ast", spec["args"])
                self.assertIsInstance(spec["args"]["formula_ast"], dict)
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

    def test_vm_contract_version_and_validator(self):
        valid = {
            "op": "flip_coin",
            "args": {},
            "branches": {
                "on_heads": [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
                "on_tails": [],
            },
        }
        supported = {"flip_coin", "draw_cards"}
        self.assertEqual(validate_command_spec(valid, supported_ops=supported), [])
        invalid = {
            "op": "draw_cards",
            "args": {"effect_type": "draw", "amount": 1},
            "branches": {"unknown": [{}]},
        }
        errors = validate_command_spec(invalid, supported_ops=supported)
        self.assertTrue(any("effect_type" in error for error in errors))
        self.assertTrue(any("unknown" in error for error in errors))
        self.assertEqual(VM_IR_VERSION, 1)

    def test_foundational_vm_ops_are_registry_backed(self):
        for op in ("deal_damage", "draw_cards", "apply_status", "draw_until"):
            with self.subTest(op=op):
                self.assertTrue(DEFAULT_COMMAND_REGISTRY.supports(op))
                command = compile_command_spec({"op": op, "args": {}, "branches": {}})
                self.assertNativeCommandModule(command)

    def test_trigger_vm_ops_are_registry_backed(self):
        specs = [
            {
                "op": "trigger_draw_cards",
                "args": {"player": 0, "amount": 1, "source": "test"},
                "branches": {},
            },
            {
                "op": "trigger_place_damage_counters",
                "args": {"player": 0, "slot": "active", "count": 1, "source": "test"},
                "branches": {},
            },
            {
                "op": "trigger_move_basic_energy",
                "args": {
                    "from_player": 0,
                    "from_slot": "active",
                    "to_player": 0,
                    "to_slot": "bench_0",
                    "source": "test",
                },
                "branches": {},
            },
            {
                "op": "trigger_switch_with_active",
                "args": {
                    "player": 0,
                    "bench_idx": 0,
                    "slot": "bench_0",
                    "source": "test",
                },
                "branches": {},
            },
        ]
        for spec in specs:
            with self.subTest(op=spec["op"]):
                self.assertTrue(DEFAULT_COMMAND_REGISTRY.supports(spec["op"]))
                command = compile_command_spec(spec)
                self.assertEqual(type(command).__module__, "engine.commands.trigger_commands")

    def test_on_attach_jet_energy_collects_switch_trigger_spec(self):
        from engine.commands import trigger_commands as trigger_module

        self.assertIn(
            "ModifierManager",
            inspect.getsource(collect_on_attach_command_specs),
        )
        self.assertNotIn('"svi-jete"', inspect.getsource(trigger_module))
        self.assertNotIn("'svi-jete'", inspect.getsource(trigger_module))
        specs = collect_on_attach_command_specs(
            CardRegistry.get("svi-jete"),
            0,
            "bench_0",
            "hand",
        )
        self.assertEqual(len(specs), 1)
        self.assertEqual(specs[0]["op"], "trigger_switch_with_active")
        self.assertEqual(
            specs[0]["args"],
            {
                "player": 0,
                "bench_idx": 0,
                "source": "喷射能量",
                "slot": "bench_0",
            },
        )
        self.assertEqual(
            collect_on_attach_command_specs(CardRegistry.get("svi-jete"), 0, "active", "hand"),
            [],
        )
        self.assertEqual(
            collect_on_attach_command_specs(CardRegistry.get("svi-jete"), 0, "bench_0", "deck"),
            [],
        )

    def test_public_jet_energy_attach_resolves_switch_through_trigger_vm_op(self):
        from engine.action_resolver import ActionResolver

        self.assertIsNone(importlib.util.find_spec("engine.effects.modifier_registry"))
        self.assertNotIn(
            "get_special_energy_attach_effect",
            inspect.getsource(ActionResolver._attach_energy),
        )

        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("svi-jete")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        result = ActionResolver(state).resolve(
            PlayerAction.ATTACH_ENERGY,
            player_idx=0,
            hand_idx=0,
            target_slot="bench_0",
        )

        self.assertTrue(result.success, result.log_message)
        self.assertEqual(state.p1.active.card.api_id, "sv2-delib")
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["svi-jete"])
        self.assertEqual(state.p1.bench[0].card.api_id, "svi-chim")
        self.assertIn("喷射能量", result.log_message)

    def test_vm_jet_energy_direct_attach_resolves_on_attach_trigger(self):
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.hand = [CardRegistry.get("svi-jete")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {
                "amount": 1,
                "from_zone": "hand",
                "filter": "any",
                "to": "bench",
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success, result.log_messages)
        self.assertIsNone(result.pending_choice)
        self.assertEqual(state.p1.active.card.api_id, "sv2-delib")
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["svi-jete"])
        self.assertEqual(state.p1.bench[0].card.api_id, "svi-chim")

    def test_vm_jet_energy_choice_attach_resumes_on_attach_trigger(self):
        engine = GameEngine()
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svf-rio"))
        state.p1.hand = [CardRegistry.get("svi-jete")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "attach_energy",
            "args": {
                "amount": 1,
                "from_zone": "hand",
                "filter": "any",
                "to": "bench",
                "optional": True,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success, result.log_messages)
        self.assertIsNotNone(result.pending_choice)
        self.assertEqual(result.pending_choice.continuation.get("kind"), "attach_energy_to_bench")

        request = engine.choice_request(state, result.pending_choice)
        bench_zero = next(
            option.option_id
            for option in request.options
            if getattr(option.ref, "slot", "") == "bench_0"
        )
        step = engine.apply_choice(state, request, ChoiceResponse(request.request_id, (bench_zero,)))

        self.assertTrue(step.success, step.message)
        self.assertIsNone(step.pending_choice)
        self.assertEqual(state.p1.active.card.api_id, "sv2-delib")
        self.assertEqual([card.api_id for card in state.p1.active.energy_cards], ["svi-jete"])
        self.assertEqual(state.p1.bench[0].card.api_id, "svi-chim")
        self.assertEqual(state.p1.bench[1].card.api_id, "svf-rio")

    def test_combat_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_combat

        for name in (
            "_command_result_from_action_result",
            "_attack_context_for_opponent_active",
            "_consume_effect_damage_prevention",
            "_check_bench_protection",
            "_discard_pokemon_for_effect",
            "_award_prizes_for_effect_ko",
            "_set_promotion_or_game_over",
            "_handle_effect_ko_if_needed",
            "_queue_or_apply_opponent_active_damage",
            "DealDamage",
            "DealDamageFormula",
            "SetAttackDamageFormula",
            "ConditionalDamageHeal",
            "DamageAndSelfHeal",
            "ConditionalDamageBonus",
            "DiscardHandThenDamage",
            "DiscardEnergyThenDamage",
            "MillThenDamage",
            "BenchDamage",
            "ChooseDamageTarget",
            "PlaceCountersThenSelfKo",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_combat, name))
                self.assertEqual(
                    getattr(primitives_combat, name).__module__,
                    "engine.commands.primitives_combat",
                )

    def test_combat_dsl_factories_are_split_from_compiler_facade(self):
        from engine.commands import dsl_compiler
        from engine.commands.dsl_compiler_combat import (
            COMBAT_COMMAND_FACTORIES,
            COMBAT_EFFECT_FACTORIES,
        )
        from engine.commands.primitives_combat import DealDamage, DealDamageFormula

        self.assertIn("damage", COMBAT_EFFECT_FACTORIES)
        self.assertIn("damage_per_hand_size", COMBAT_EFFECT_FACTORIES)
        self.assertIn("deal_damage", COMBAT_COMMAND_FACTORIES)
        self.assertIn("deal_damage_per_hand_size", COMBAT_COMMAND_FACTORIES)
        self.assertFalse(hasattr(dsl_compiler, "_make_damage"))
        self.assertFalse(hasattr(dsl_compiler, "_make_attack_damage_formula"))
        self.assertIsInstance(compile_effect({"effect_type": "damage", "params": {}}), DealDamage)
        self.assertIsInstance(
            compile_effect({"effect_type": "damage_per_hand_size", "params": {}}),
            DealDamageFormula,
        )

    def test_support_dsl_factories_are_split_from_compiler_facade(self):
        from engine.commands import dsl_compiler
        from engine.commands.dsl_compiler_support import (
            SUPPORT_COMMAND_FACTORIES,
            SUPPORT_EFFECT_FACTORIES,
        )
        from engine.commands.primitives_draw import DrawCards
        from engine.commands.primitives_search import SearchCards
        from engine.commands.primitives_status import ApplyStatus

        self.assertIn("draw", SUPPORT_EFFECT_FACTORIES)
        self.assertIn("status", SUPPORT_EFFECT_FACTORIES)
        self.assertIn("search", SUPPORT_EFFECT_FACTORIES)
        self.assertIn("draw_cards", SUPPORT_COMMAND_FACTORIES)
        self.assertIn("apply_status", SUPPORT_COMMAND_FACTORIES)
        self.assertIn("search_cards", SUPPORT_COMMAND_FACTORIES)
        self.assertFalse(hasattr(dsl_compiler, "_make_draw"))
        self.assertFalse(hasattr(dsl_compiler, "_make_status"))
        self.assertFalse(hasattr(dsl_compiler, "_make_search"))
        self.assertIsInstance(compile_effect({"effect_type": "draw", "params": {}}), DrawCards)
        self.assertIsInstance(compile_effect({"effect_type": "status", "params": {}}), ApplyStatus)
        self.assertIsInstance(compile_effect({"effect_type": "search", "params": {}}), SearchCards)

    def test_control_dsl_factories_are_split_from_compiler_facade(self):
        from engine.commands import dsl_compiler
        from engine.commands.dsl_compiler_control import (
            CONTROL_COMMAND_FACTORIES,
            CONTROL_EFFECT_FACTORIES,
        )
        from engine.commands.primitives_attack import AttackFail, RegisterModifier
        from engine.commands.primitives_board import SwitchPokemon
        from engine.commands.primitives_coin import FlipCoin

        self.assertIn("coin_flip", CONTROL_EFFECT_FACTORIES)
        self.assertIn("switch_self", CONTROL_EFFECT_FACTORIES)
        self.assertIn("tool_exp_share", CONTROL_EFFECT_FACTORIES)
        self.assertIn("flip_coin", CONTROL_COMMAND_FACTORIES)
        self.assertIn("switch_pokemon", CONTROL_COMMAND_FACTORIES)
        self.assertIn("register_tool_exp_share", CONTROL_COMMAND_FACTORIES)
        self.assertFalse(hasattr(dsl_compiler, "_make_coin_flip"))
        self.assertFalse(hasattr(dsl_compiler, "_make_switch_self"))
        self.assertFalse(hasattr(dsl_compiler, "_make_register_modifier"))
        self.assertIsInstance(compile_effect({"effect_type": "coin_flip", "params": {}}), FlipCoin)
        self.assertIsInstance(compile_effect({"effect_type": "switch_self", "params": {}}), SwitchPokemon)
        self.assertIsInstance(compile_effect({"effect_type": "attack_fail", "params": {}}), AttackFail)
        self.assertIsInstance(
            compile_effect({"effect_type": "tool_exp_share", "params": {}}),
            RegisterModifier,
        )

    def test_draw_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_draw

        for name in (
            "DrawCards",
            "DrawUntil",
            "DrawUntilMore",
            "ShuffleThenDrawCards",
            "Judge",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_draw, name))
                self.assertEqual(
                    getattr(primitives_draw, name).__module__,
                    "engine.commands.primitives_draw",
                )

    def test_search_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_search

        for name in (
            "SearchCards",
            "LookTopDeck",
            "LookTopAttachEnergy",
            "SearchItemAndTool",
            "TrekkingShoes",
            "ConditionalSearchExtra",
            "SearchAnyAndSwitch",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_search, name))
                self.assertEqual(
                    getattr(primitives_search, name).__module__,
                    "engine.commands.primitives_search",
                )

    def test_energy_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_energy

        for name in (
            "DrawAndAttachEnergy",
            "EnergyAttach",
            "AttachEnergyFromDiscard",
            "EnergyRelocate",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_energy, name))
                self.assertEqual(
                    getattr(primitives_energy, name).__module__,
                    "engine.commands.primitives_energy",
                )

    def test_coin_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_coin

        for name in (
            "CoinFlipSpecial",
            "CoinFlipEnergyDiscard",
            "Conditional",
            "FlipCoin",
            "_branch_payload",
            "_build_branch_command",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_coin, name))
                self.assertEqual(
                    getattr(primitives_coin, name).__module__,
                    "engine.commands.primitives_coin",
                )

    def test_attack_state_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_attack

        for name in (
            "AttackFail",
            "SetAttackFlags",
            "ReturnToHand",
            "SetPrevention",
            "DazzlingBeam",
            "AttackLockBasic",
            "OutgoingDamageReduction",
            "SelfAttackLock",
            "RegisterModifier",
            "RegisterToolModifier",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_attack, name))
                self.assertEqual(
                    getattr(primitives_attack, name).__module__,
                    "engine.commands.primitives_attack",
                )

    def test_recovery_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_recovery

        for name in (
            "RecoverFromDiscard",
            "HandToBottomThenDraw",
            "HandToBottomDrawUntil",
            "ZinniaResolve",
            "AbilityDiscardRevive",
            "EvolveSkipStage",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_recovery, name))
                self.assertEqual(
                    getattr(primitives_recovery, name).__module__,
                    "engine.commands.primitives_recovery",
                )

    def test_board_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_board

        for name in (
            "_energy_card_matches",
            "DiscardEnergy",
            "HealDamage",
            "ChooseHealDamage",
            "SwitchPokemon",
            "SearchZone",
            "DiscardCards",
            "DiscardThenDrawCards",
        ):
            with self.subTest(name=name):
                self.assertIs(getattr(primitives, name), getattr(primitives_board, name))
                self.assertEqual(
                    getattr(primitives_board, name).__module__,
                    "engine.commands.primitives_board",
                )

    def test_status_commands_are_split_from_primitives_facade(self):
        from engine.commands import primitives
        from engine.commands import primitives_status

        self.assertIs(primitives.ApplyStatus, primitives_status.ApplyStatus)
        self.assertEqual(
            primitives_status.ApplyStatus.__module__,
            "engine.commands.primitives_status",
        )

    def test_all_exported_vm_ops_are_registry_backed(self):
        ops = {
            compile_effect_to_spec(effect).op
            for effect in _walk_effects(CARD_EFFECTS)
        }
        self.assertTrue(ops)
        missing = sorted(op for op in ops if not DEFAULT_COMMAND_REGISTRY.supports(op))
        self.assertEqual(missing, [])

    def test_resolution_stack_continuation_registry_covers_common_kinds(self):
        state = GameState()
        stack = ResolutionStack(state)
        registry = stack.continuation_registry
        self.assertIs(stack._continuation_registry(), registry)
        expected = {
            "flip_coin_branch",
            "bench_damage_targets",
            "choose_damage_target",
            "energy_attach_distribution",
            "search_cards",
            "search_any_switch_bench",
        }
        self.assertTrue(expected.issubset(registry.supported_kinds))

    def test_energy_continuations_are_module_registered(self):
        from engine.commands.energy_continuations import register_energy_continuations

        stack = ResolutionStack(GameState())
        registry = ContinuationRegistry()
        register_energy_continuations(registry, stack)
        expected = {
            "draw_and_attach_energy_distribution",
            "energy_attach_distribution",
            "attach_energy_distribution",
            "attach_energy_to_bench",
            "attach_energy_to_board",
            "attach_discard_energy_distribution",
            "attach_discard_energy_to_bench",
            "attach_discard_energy_to_board",
            "energy_relocate_source",
            "energy_relocate_distribution",
        }
        self.assertEqual(registry.supported_kinds, frozenset(expected))
        self.assertFalse(
            hasattr(stack, "_resolve_attach_energy_distribution_continuation")
        )

    def test_search_continuations_are_module_registered(self):
        from engine.commands.search_continuations import register_search_continuations

        stack = ResolutionStack(GameState())
        registry = ContinuationRegistry()
        register_search_continuations(registry, stack)
        expected = {
            "search_cards",
            "search_item_and_tool",
            "trekking_shoes",
            "look_top_deck",
            "detached_energy_distribution",
            "look_top_bench_energy_distribution",
            "look_top_attach_energy",
            "look_top_attach_target",
            "search_any_and_switch",
            "search_any_switch_confirm",
            "search_any_switch_bench",
        }
        self.assertEqual(registry.supported_kinds, frozenset(expected))
        removed_stack_handlers = {
            "_resolve_search_cards_continuation",
            "_resolve_search_item_and_tool_continuation",
            "_resolve_trekking_shoes_continuation",
            "_resolve_look_top_deck_continuation",
            "_resolve_detached_energy_distribution_continuation",
            "_resolve_look_top_bench_energy_distribution_continuation",
            "_resolve_look_top_attach_energy_continuation",
            "_resolve_look_top_attach_target_continuation",
            "_resolve_search_any_and_switch_continuation",
            "_resolve_search_any_switch_confirm_continuation",
            "_resolve_search_any_switch_bench_continuation",
        }
        self.assertFalse(any(hasattr(stack, name) for name in removed_stack_handlers))

    def test_coin_continuations_are_module_registered(self):
        from engine.commands.coin_continuations import register_coin_continuations

        stack = ResolutionStack(GameState())
        registry = ContinuationRegistry()
        register_coin_continuations(registry, stack)
        expected = {
            "flip_coin_branch",
            "coin_special",
            "coin_energy_discard",
            "discard_attachment",
        }
        self.assertEqual(registry.supported_kinds, frozenset(expected))
        removed_stack_handlers = {
            "_continue_flip_coin_branch",
            "_resolve_coin_special_continuation",
            "_resolve_coin_energy_discard_continuation",
            "_resolve_discard_attachment_continuation",
        }
        self.assertFalse(any(hasattr(stack, name) for name in removed_stack_handlers))

    def test_board_continuations_are_module_registered(self):
        from engine.commands.board_continuations import register_board_continuations

        stack = ResolutionStack(GameState())
        registry = ContinuationRegistry()
        register_board_continuations(registry, stack)
        expected = {
            "switch_confirm",
            "switch_bench",
            "bench_damage_targets",
            "choose_damage_target",
            "place_counters_then_self_ko",
            "choose_heal_damage",
        }
        self.assertEqual(registry.supported_kinds, frozenset(expected))
        removed_stack_handlers = {
            "_resolve_switch_confirm_continuation",
            "_resolve_switch_bench_continuation",
            "_resolve_bench_damage_targets_continuation",
            "_resolve_choose_damage_target_continuation",
            "_resolve_place_counters_then_self_ko_continuation",
            "_resolve_choose_heal_damage_continuation",
        }
        self.assertFalse(any(hasattr(stack, name) for name in removed_stack_handlers))

    def test_hand_continuations_are_module_registered(self):
        from engine.commands.hand_continuations import register_hand_continuations

        stack = ResolutionStack(GameState())
        registry = ContinuationRegistry()
        register_hand_continuations(registry, stack)
        expected = {
            "discard_hand_cards",
            "discard_hand_then_draw",
            "hand_to_bottom_then_draw",
            "hand_to_bottom_draw_until",
            "zinnia_resolve",
        }
        self.assertEqual(registry.supported_kinds, frozenset(expected))
        removed_stack_handlers = {
            "_resolve_discard_hand_cards_continuation",
            "_resolve_discard_hand_then_draw_continuation",
            "_hand_indices_for_selected_cards",
            "_resolve_hand_to_bottom_then_draw_continuation",
            "_resolve_hand_to_bottom_draw_until_continuation",
            "_resolve_zinnia_resolve_continuation",
        }
        self.assertFalse(any(hasattr(stack, name) for name in removed_stack_handlers))

    def test_recovery_continuations_are_module_registered(self):
        from engine.commands.recovery_continuations import register_recovery_continuations

        stack = ResolutionStack(GameState())
        registry = ContinuationRegistry()
        register_recovery_continuations(registry, stack)
        expected = {
            "recover_from_discard_to_deck",
            "recover_clara",
        }
        self.assertEqual(registry.supported_kinds, frozenset(expected))
        removed_stack_handlers = {
            "_resolve_recover_from_discard_to_deck_continuation",
            "_resolve_recover_clara_continuation",
        }
        self.assertFalse(any(hasattr(stack, name) for name in removed_stack_handlers))

    def test_choice_helpers_are_split_from_resolution_stack(self):
        from engine.commands import choice_helpers

        stack = ResolutionStack(GameState())
        for name in (
            "selected_top_positions_from_request",
            "selected_card_indices_from_request",
            "peek_expected_top_cards",
            "pop_expected_top_cards",
            "return_top_cards_except_selected",
            "attach_lightning_energy_to_bench",
            "take_selected_cards_from_zone",
            "take_one_selected_card_from_zone",
            "find_selected_card_in_zone",
            "resolve_board_choice",
        ):
            with self.subTest(name=name):
                self.assertTrue(hasattr(choice_helpers, name))
                self.assertFalse(hasattr(stack, f"_{name}"))

    def test_resolution_stack_unknown_continuation_hard_fails(self):
        class Request:
            continuation = {"kind": "missing_continuation"}

        result = ResolutionStack(GameState())._resolve_request_continuation(
            Request(),
            choice=[],
            player_idx=0,
            source_slot="active",
        )

        self.assertFalse(result.success)
        self.assertIn("Unknown VM continuation", result.log_message)

    def test_modifier_manager_orders_same_hook_stably(self):
        state = GameState()
        calls = []

        state.modifier_manager.register(
            MAX_HP,
            lambda _data: calls.append("late") or {"source": "late"},
            source="late",
            owner_player=0,
            priority=10,
        )
        state.modifier_manager.register(
            MAX_HP,
            lambda _data: calls.append("early") or {"source": "early"},
            source="early",
            owner_player=0,
            priority=20,
        )
        state.modifier_manager.register(
            MAX_HP,
            lambda _data: calls.append("tie") or {"source": "tie"},
            source="tie",
            owner_player=0,
            priority=10,
        )

        result = state.modifier_manager.emit(MAX_HP, pokemon=None)
        self.assertEqual(calls, ["early", "late", "tie"])
        self.assertEqual([row["source"] for row in result], ["early", "late", "tie"])

    def test_event_backed_modifier_hooks_have_explicit_stable_order(self):
        state = GameState()
        calls = []

        state.modifier_manager.register(
            MODIFY_DAMAGE,
            lambda _data: calls.append("late") or {"source": "late"},
            source="late",
            owner_player=0,
            priority=10,
        )
        state.modifier_manager.register(
            MODIFY_DAMAGE,
            lambda _data: calls.append("early") or {"source": "early"},
            source="early",
            owner_player=0,
            priority=20,
        )
        state.modifier_manager.register(
            MODIFY_DAMAGE,
            lambda _data: calls.append("tie") or {"source": "tie"},
            source="tie",
            owner_player=0,
            priority=10,
        )

        result = state.modifier_manager.emit(MODIFY_DAMAGE, state=state)

        self.assertEqual(calls, ["early", "late", "tie"])
        self.assertEqual([row["source"] for row in result], ["early", "late", "tie"])
        listeners = state.event_bus._listeners[EventType.DAMAGE_ABOUT_TO_BE_DEALT]
        self.assertEqual([listener.source for listener in listeners], ["early", "late", "tie"])
        self.assertTrue(all(listener.sequence > 0 for listener in listeners))
        by_source = {listener.source: listener for listener in listeners}
        self.assertGreater(by_source["early"].priority, by_source["late"].priority)
        self.assertEqual(by_source["late"].priority, by_source["tie"].priority)
        self.assertLess(by_source["late"].sequence, by_source["tie"].sequence)

    def test_event_backed_modifier_hook_errors_are_not_swallowed(self):
        state = GameState()

        def broken_hook(_data):
            raise RuntimeError("broken modifier")

        state.modifier_manager.register(
            MODIFY_DAMAGE,
            broken_hook,
            source="broken-modifier",
            owner_player=0,
            priority=10,
        )

        with self.assertRaisesRegex(ValueError, "broken-modifier.*broken modifier"):
            state.modifier_manager.emit(MODIFY_DAMAGE, state=state)

    def test_python_stat_and_retreat_hooks_own_mbf_logic(self):
        import engine.effects.pokemon_stat_hooks as pokemon_stat_hooks
        import engine.effects.retreat_modifier_hooks as retreat_modifier_hooks
        import engine.player_state as player_state
        import engine.rules_validator as rules_validator

        player_state_source = Path(player_state.__file__).read_text(encoding="utf-8")
        rules_validator_source = Path(rules_validator.__file__).read_text(encoding="utf-8")
        stat_hook_source = Path(pokemon_stat_hooks.__file__).read_text(encoding="utf-8")
        retreat_hook_source = Path(retreat_modifier_hooks.__file__).read_text(encoding="utf-8")

        self.assertIn("pokemon_stat_hooks import current_hp", player_state_source)
        self.assertNotIn("conditional_hp_boost", player_state_source)
        self.assertNotIn("hp_boost_basic", player_state_source)
        self.assertIn("retreat_modifier_hooks import effective_retreat_cost", rules_validator_source)
        self.assertNotIn("conditional_zero_retreat", rules_validator_source)
        self.assertNotIn("EventType.CAN_RETREAT", rules_validator_source)
        self.assertIn("ModifierManager", stat_hook_source)
        self.assertIn("MAX_HP", stat_hook_source)
        self.assertIn("CAN_RETREAT", retreat_hook_source)
        self.assertIn("modifier_manager", retreat_hook_source)

    def test_python_modifier_hooks_register_through_modifier_manager(self):
        import engine.commands.modifier_registration as modifier_registration

        source = Path(modifier_registration.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        legacy_trigger_payload_keys = []
        command_specs_keys = 0
        trigger_callback_names = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "_register_mbf_hook":
                if len(node.args) >= 3 and isinstance(node.args[1], ast.Name):
                    if node.args[1].id in {"AFTER_DAMAGE", "POKEMON_KO"}:
                        callback = node.args[2]
                        if isinstance(callback, ast.Name):
                            trigger_callback_names.add(callback.id)
            if not isinstance(node, ast.Dict):
                continue
            for key in node.keys:
                if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
                    continue
                if key.value in {"command", "commands"}:
                    legacy_trigger_payload_keys.append((key.value, node.lineno))
                if key.value == "command_specs":
                    command_specs_keys += 1

        function_defs = {
            node.name: node
            for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef)
        }
        mutation_methods = {
            "add",
            "append",
            "clear",
            "discard",
            "extend",
            "insert",
            "pop",
            "popitem",
            "remove",
            "reverse",
            "sort",
            "update",
        }
        board_roots = {
            "attacker",
            "data",
            "defender",
            "holder",
            "knocked_out",
            "owner",
            "player",
            "pokemon",
            "source",
            "state",
            "target",
        }

        def root_name(expr):
            if isinstance(expr, ast.Name):
                return expr.id
            if isinstance(expr, ast.Attribute):
                return root_name(expr.value)
            if isinstance(expr, ast.Subscript):
                return root_name(expr.value)
            if isinstance(expr, ast.Call):
                return root_name(expr.func)
            return None

        direct_mutations = []
        for callback_name in sorted(trigger_callback_names):
            callback = function_defs.get(callback_name)
            self.assertIsNotNone(callback, callback_name)
            for node in ast.walk(callback):
                if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                    targets = [node.target] if hasattr(node, "target") else list(node.targets)
                    for target in targets:
                        if isinstance(target, (ast.Attribute, ast.Subscript)):
                            root = root_name(target)
                            if root in board_roots:
                                direct_mutations.append((callback_name, root, node.lineno))
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                    root = root_name(node.func.value)
                    if root in board_roots and node.func.attr in mutation_methods:
                        direct_mutations.append((callback_name, root, node.lineno))

        self.assertIn("ModifierManager", source)
        self.assertIn("MODIFY_DAMAGE", source)
        self.assertIn("CAN_RETREAT", source)
        self.assertIn("AFTER_DAMAGE", source)
        self.assertIn("POKEMON_KO", source)
        self.assertIn("_register_mbf_hook", source)
        self.assertNotIn("EventType", source)
        self.assertNotIn("event_bus.register(", source)
        self.assertNotIn("exp_share_used", source)
        self.assertNotIn("团结一致", source)
        self.assertGreater(command_specs_keys, 0)
        self.assertEqual(legacy_trigger_payload_keys, [])
        self.assertGreater(len(trigger_callback_names), 0)
        self.assertEqual(direct_mutations, [])

    def test_migrated_native_commands_do_not_reuse_effect_type_fields(self):
        from engine.commands.primitives_coin import CoinFlipSpecial
        from engine.commands.primitives_combat import DealDamageFormula
        from engine.commands.primitives_recovery import RecoverFromDiscard
        from engine.commands.primitives_attack import RegisterModifier

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

    def test_action_resolver_executes_compiled_effect_specs_directly(self):
        from engine.action_resolver import ActionResolver

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]

        result = ActionResolver(state)._execute_effects(
            [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
            0,
            "active",
        )

        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

    def test_action_resolver_rejects_compiled_specs_with_legacy_effect_type_args(self):
        from engine.action_resolver import ActionResolver

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        result = ActionResolver(state)._execute_effects(
            [{
                "op": "draw_cards",
                "args": {"amount": 1, "effect_type": "draw"},
                "branches": {},
            }],
            0,
            "active",
        )

        self.assertFalse(result.success)
        self.assertIn("legacy effect_type", result.log_message)

    def test_attack_effect_stack_executes_compiled_specs_directly(self):
        from engine.action_resolver import ActionResolver

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        context = {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 0,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        }

        result = ActionResolver(state)._execute_attack_effects(
            [{"op": "deal_damage", "args": {"amount": 20}, "branches": {}}],
            0,
            "active",
            context,
        )

        self.assertTrue(result.success)
        self.assertEqual(result.damage_dealt, 20)
        self.assertEqual(state.p2.active.damage_counters, 2)

    def test_attack_base_damage_replacement_prefers_compiled_ir(self):
        from types import SimpleNamespace
        from engine.action_resolver import _attack_effects_replace_base_damage

        compiled_formula_attack = SimpleNamespace(
            effects=[{"effect_type": "damage"}],
            compiled_effects=[{
                "op": "deal_damage",
                "args": {"formula_ast": {"op": "hand_size", "player": "self"}},
                "branches": {},
            }],
        )
        direct_damage_attack = SimpleNamespace(
            effects=[],
            compiled_effects=[{
                "op": "deal_damage",
                "args": {"amount": 20},
                "branches": {},
            }],
        )

        self.assertTrue(_attack_effects_replace_base_damage(compiled_formula_attack))
        self.assertFalse(_attack_effects_replace_base_damage(direct_damage_attack))

    def test_card_registry_populates_compiled_effect_payloads(self):
        cards = list(CardRegistry.all_cards().values())
        self.assertTrue(cards)
        attack_rows = [
            attack
            for card in cards
            for attack in card.attacks
            if attack.effects
        ]
        ability_rows = [
            ability
            for card in cards
            for ability in card.abilities
            if ability.effects
        ]
        trainer_rows = [card for card in cards if card.trainer_effects]
        self.assertTrue(attack_rows)
        self.assertTrue(ability_rows)
        self.assertTrue(trainer_rows)

        for attack in attack_rows:
            self.assertEqual(
                attack.compiled_effects,
                compile_effects_to_payload(attack.effects),
            )
        for ability in ability_rows:
            self.assertEqual(
                ability.compiled_effects,
                compile_effects_to_payload(ability.effects),
            )
        for card in trainer_rows:
            self.assertEqual(
                card.compiled_trainer_effects,
                compile_effects_to_payload(card.trainer_effects),
            )

    def test_release_compiled_effects_do_not_use_legacy_formula_ops(self):
        legacy_formula_ops = {
            "deal_damage_per_discard_psychic",
            "deal_damage_per_energy",
            "deal_damage_per_evolved",
            "deal_damage_per_hand_size",
            "deal_damage_per_self_damage",
            "deal_damage_per_self_energy",
            "deal_damage_per_self_energy_type",
            "deal_damage_plus_bench",
            "deal_damage_with_self_penalty",
            "set_attack_damage_formula",
        }
        offenders = []

        def walk_specs(value):
            if isinstance(value, dict):
                if value.get("op"):
                    yield value
                for child in value.values():
                    yield from walk_specs(child)
            elif isinstance(value, (list, tuple)):
                for child in value:
                    yield from walk_specs(child)

        for card in CardRegistry.all_cards().values():
            for attack in card.attacks:
                for spec in walk_specs(attack.compiled_effects):
                    if spec.get("op") in legacy_formula_ops:
                        offenders.append((card.api_id, attack.name, spec.get("op")))
            for ability in card.abilities:
                for spec in walk_specs(ability.compiled_effects):
                    if spec.get("op") in legacy_formula_ops:
                        offenders.append((card.api_id, ability.name, spec.get("op")))
            for spec in walk_specs(card.compiled_trainer_effects):
                if spec.get("op") in legacy_formula_ops:
                    offenders.append((card.api_id, "trainer", spec.get("op")))

        self.assertEqual(offenders, [])

    def test_runtime_and_ai_use_runtime_effect_selectors_instead_of_effect_fields(self):
        checked_files = [
            Path("engine/action_resolver.py"),
            Path("engine/game_engine.py"),
            Path("engine/ai/challenge_ai.py"),
            Path("engine/ai/dl/encoder.py"),
            Path("engine/ai/challenge/sequencing.py"),
            Path("engine/ai/dl/training.py"),
            Path("engine/effects/pokemon_stat_hooks.py"),
            Path("engine/effects/retreat_modifier_hooks.py"),
            Path("engine/commands/modifier_registration.py"),
        ]
        forbidden = (
            ".trainer_effects",
            ".compiled_trainer_effects",
            ".compiled_effects",
            'getattr(card, "trainer_effects"',
            'getattr(card, "compiled_trainer_effects"',
            'getattr(attack, "effects"',
            'getattr(attack, "compiled_effects"',
            'getattr(ability, "effects"',
            'getattr(ability, "compiled_effects"',
            "card.compiled_trainer_effects",
            "attack.compiled_effects",
            "ability.compiled_effects",
            "attack.effects",
            "ability.effects",
            "atk.effects",
        )
        offenders = []
        for relative in checked_files:
            path = Path(__file__).resolve().parents[1] / relative
            source = path.read_text(encoding="utf-8")
            for token in forbidden:
                if token in source:
                    offenders.append(f"{relative}:{token}")
        self.assertEqual(offenders, [])

        ai_files = [
            Path("engine/ai/challenge_ai.py"),
            Path("engine/ai/challenge/sequencing.py"),
            Path("engine/ai/dl/encoder.py"),
            Path("engine/ai/dl/training.py"),
        ]
        raw_effect_type_offenders = []
        for relative in ai_files:
            path = Path(__file__).resolve().parents[1] / relative
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if isinstance(node, ast.Attribute) and node.attr == "effect_type":
                    raw_effect_type_offenders.append(f"{relative}:{node.lineno}:attr")
                if (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Name)
                    and node.func.id == "getattr"
                    and len(node.args) >= 2
                    and isinstance(node.args[1], ast.Constant)
                    and node.args[1].value == "effect_type"
                ):
                    raw_effect_type_offenders.append(f"{relative}:{node.lineno}:getattr")
                if (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "get"
                    and node.args
                    and isinstance(node.args[0], ast.Constant)
                    and node.args[0].value == "effect_type"
                ):
                    raw_effect_type_offenders.append(f"{relative}:{node.lineno}:dict-get")
                if (
                    isinstance(node, ast.Subscript)
                    and isinstance(node.slice, ast.Constant)
                    and node.slice.value == "effect_type"
                ):
                    raw_effect_type_offenders.append(f"{relative}:{node.lineno}:subscript")
        self.assertEqual(raw_effect_type_offenders, [])

    def test_compiled_only_static_modifier_payloads_drive_hooks(self):
        from data.card_models import AbilityDef, Card
        from engine.effects.retreat_modifier_hooks import effective_retreat_cost
        from engine.rules_constants import TOOL_HP_BOOST

        tool = Card(
            api_id="test-compiled-hp-tool",
            name="Compiled HP Tool",
            supertype="Trainer",
            subtypes=["Tool"],
            compiled_trainer_effects=[{
                "op": "register_tool_modifier",
                "args": {"effect": "hp_boost_basic"},
                "branches": {},
            }],
        )
        pokemon = PokemonInPlay(CardRegistry.get("svi-chim"))
        pokemon.attached_tool = tool
        self.assertEqual(
            pokemon.current_hp,
            pokemon.card.hp + TOOL_HP_BOOST,
        )

        ability = AbilityDef(
            name="Compiled Free Retreat",
            text="",
            effects=[],
            compiled_effects=[{
                "op": "register_conditional_zero_retreat",
                "args": {"energy_type": "Fire"},
                "branches": {},
            }],
        )
        retreat_card = Card(
            api_id="test-compiled-retreat",
            name="Compiled Retreat Pokemon",
            supertype="Pokémon",
            subtypes=["Basic"],
            hp=80,
            retreat_cost=2,
            abilities=[ability],
        )
        state = GameState()
        state.p1.active = PokemonInPlay(retreat_card)
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
        self.assertEqual(effective_retreat_cost(state, state.p1), 0)

    def test_compiled_only_reactive_trigger_payloads_drive_hooks(self):
        from data.card_models import AbilityDef, Card
        from engine.commands.modifier_registration import register_pokemon_modifiers

        ability = AbilityDef(
            name="Compiled Thorns",
            text="",
            effects=[{
                "effect_type": "damage",
                "params": {"amount": 999},
            }],
            compiled_effects=[{
                "op": "register_reactive_thorns",
                "args": {
                    "filter_names": ["Compiled Thorns Holder"],
                    "per_pokemon": 4,
                },
                "branches": {},
            }],
        )
        thorn_card = Card(
            api_id="test-compiled-thorns",
            name="Compiled Thorns Holder",
            supertype="Pokémon",
            subtypes=["Basic"],
            hp=80,
            abilities=[ability],
        )
        state = GameState()
        state.p1.active = PokemonInPlay(thorn_card)
        state.p1.bench[0] = PokemonInPlay(thorn_card)
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        register_pokemon_modifiers(
            state.p1.active,
            0,
            "active",
            event_bus=state.event_bus,
        )
        trigger_results = state.event_bus.emit(
            EventType.DAMAGE_DEALT,
            final_damage=50,
            attacker=state.p2.active,
            defender=state.p1.active,
            state=state,
            ignore_defender_effects=False,
        )
        trigger_specs = command_specs_from_trigger_results(trigger_results)

        self.assertEqual(len(trigger_specs), 1)
        self.assertEqual(trigger_specs[0]["op"], "trigger_place_damage_counters")
        self.assertEqual(
            {
                key: trigger_specs[0]["args"][key]
                for key in ("player", "slot", "count")
            },
            {"player": 1, "slot": "active", "count": 8},
        )

    def test_availability_accepts_compiled_search_and_switch_specs(self):
        from engine.effects.availability import effects_have_legal_target

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        self.assertTrue(effects_have_legal_target(
            state,
            0,
            [{
                "op": "search_cards",
                "args": {
                    "from_zone": "deck",
                    "filter": "basic_energy",
                    "destination": "hand",
                    "count": 1,
                },
                "branches": {},
            }],
        ))
        self.assertFalse(effects_have_legal_target(
            state,
            0,
            [{"op": "switch_pokemon", "args": {"target": "opponent"}, "branches": {}}],
        ))

        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svi-skwv"))
        self.assertTrue(effects_have_legal_target(
            state,
            0,
            [{"op": "switch_pokemon", "args": {"target": "opponent"}, "branches": {}}],
        ))

    def test_availability_checks_compiled_conditional_discard_cost(self):
        from engine.effects.availability import effects_cost_is_payable

        effect = {
            "op": "conditional",
            "args": {
                "condition": "always",
                "cost": [{
                    "op": "discard_cards",
                    "args": {"from_zone": "hand", "amount": 2},
                    "branches": {},
                }],
            },
            "branches": {
                "on_pay": [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
            },
        }
        state = GameState()
        state.p1.hand = [CardRegistry.get("sv1-ener-1")]
        self.assertFalse(effects_cost_is_payable(state, 0, [effect]))

        state.p1.hand.append(CardRegistry.get("sv1-ener-2"))
        self.assertTrue(effects_cost_is_payable(state, 0, [effect]))

    def test_action_resolver_prefers_compiled_trainer_effects(self):
        from data.card_models import Card
        from engine.action_resolver import ActionResolver

        card = Card(
            api_id="test-compiled-item",
            name="Compiled Item",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[],
        )
        card.compiled_trainer_effects = [{
            "op": "draw_cards",
            "args": {"amount": 1},
            "branches": {},
        }]
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.p1.hand = [card]
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]

        result = ActionResolver(state)._play_trainer(0, 0)

        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])
        self.assertEqual([card.api_id for card in state.p1.discard], ["test-compiled-item"])

    def test_action_resolver_prefers_compiled_ability_effects(self):
        from data.card_models import AbilityDef, Card
        from engine.action_resolver import ActionResolver

        ability = AbilityDef(
            name="Compiled Draw",
            text="",
            trigger="repeatable",
            effects=[],
        )
        ability.compiled_effects = [{
            "op": "draw_cards",
            "args": {"amount": 1},
            "branches": {},
        }]
        card = Card(
            api_id="test-compiled-ability",
            name="Compiled Ability Pokemon",
            supertype="Pokémon",
            subtypes=["Basic"],
            hp=60,
            abilities=[ability],
        )
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.p1.active = PokemonInPlay(card)
        state.p1.deck = [CardRegistry.get("sv1-ener-3")]

        result = ActionResolver(state)._use_ability(0, "active", "Compiled Draw")

        self.assertTrue(result.success)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-3"])

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
                self.assertNativeCommandModule(command)

    def test_set_attack_damage_formula_is_native_primitive(self):
        from engine.commands.primitives_combat import SetAttackDamageFormula

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

    def test_deal_damage_formula_ast_can_replace_attack_damage_formula(self):
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.was_ko_by_attack = True
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        attack_context = begin_attack_damage_context(state, stack, {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 0,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        })
        stack.push(compile_command_spec({
            "op": "deal_damage",
            "args": {
                "formula_ast": {
                    "op": "add",
                    "terms": [
                        {"const": 100},
                        {
                            "op": "if",
                            "condition": "ko_by_attack_last_turn",
                            "then": {"const": 120},
                            "else": {"const": 0},
                        },
                    ],
                },
                "consume_condition": "ko_by_attack_last_turn",
                "piercing": True,
                "ignore_defender_effects": True,
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success)
        self.assertEqual(attack_context["base_damage"], 220)
        self.assertTrue(attack_context["piercing"])
        self.assertTrue(attack_context["ignore_defender_effects"])
        self.assertFalse(state.p1.was_ko_by_attack)
        self.assertEqual(state.p2.active.damage_counters, 0)

    def test_deal_damage_formula_ast_covers_discard_evolved_and_arithmetic(self):
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svg2-tort"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv1-106"))
        state.p1.discard = [
            CardRegistry.get("sv1-106"),
            CardRegistry.get("svi-chim"),
            CardRegistry.get("sv1-ener-5"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage",
            "args": {
                "piercing": True,
                "formula_ast": {
                    "op": "add",
                    "terms": [
                        {"const": 30},
                        {
                            "op": "mul",
                            "factors": [
                                {
                                    "op": "discard_count",
                                    "player": "self",
                                    "filter": {
                                        "card_type": "pokemon",
                                        "energy_type": "Psychic",
                                    },
                                },
                                {"const": 10},
                            ],
                        },
                        {
                            "op": "mul",
                            "factors": [
                                {"op": "evolved_count", "player": "self"},
                                {"const": 20},
                            ],
                        },
                        {
                            "op": "div",
                            "args": [
                                {"op": "sub", "args": [{"const": 40}, {"const": 10}]},
                                {"const": 3},
                            ],
                        },
                    ],
                },
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success)
        self.assertEqual(result.damage_dealt, 90)
        self.assertEqual(state.p2.active.damage_counters, 9)

    def test_deal_damage_formula_ast_covers_condition_nodes(self):
        formula_spec = {
            "op": "deal_damage",
            "args": {
                "formula_ast": {
                    "op": "add",
                    "terms": [
                        {"const": 10},
                        {
                            "op": "if",
                            "condition": "own_hand_empty",
                            "then": {"const": 30},
                            "else": {"const": 0},
                        },
                        {
                            "op": "mul",
                            "factors": [
                                {"op": "condition", "condition": "opponent_active_damaged"},
                                {"const": 20},
                            ],
                        },
                    ],
                },
            },
            "branches": {},
        }

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.hand = []
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active.damage_counters = 1
        stack = ResolutionStack(state)
        stack.push(compile_command_spec(formula_spec))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success)
        self.assertEqual(result.damage_dealt, 60)
        self.assertEqual(state.p2.active.damage_counters, 7)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.hand = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec(formula_spec))
        result = stack.resolve_all(0, "active")

        self.assertTrue(result.success)
        self.assertEqual(result.damage_dealt, 10)
        self.assertEqual(state.p2.active.damage_counters, 1)

    def test_deal_damage_formula_ast_rejects_unknown_energy_scope(self):
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage",
            "args": {
                "formula_ast": {
                    "op": "energy_count",
                    "scope": "sideboard",
                    "energy_type": "Fire",
                },
            },
            "branches": {},
        }))

        result = stack.resolve_all(0, "active")

        self.assertFalse(result.success)
        self.assertTrue(
            any("Unknown energy_count scope" in message for message in result.log_messages)
        )
        self.assertEqual(state.p2.active.damage_counters, 0)

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

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"), damage_counters=2)
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-5"),
        ]
        state.p1.hand = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "deal_damage",
            "args": {
                "formula_ast": {
                    "op": "add",
                    "terms": [
                        {
                            "op": "mul",
                            "factors": [{"op": "hand_size"}, {"const": 10}],
                        },
                        {
                            "op": "mul",
                            "factors": [
                                {"op": "energy_count", "scope": "self", "energy_type": "Fire"},
                                {"const": 20},
                            ],
                        },
                        {
                            "op": "mul",
                            "factors": [
                                {"op": "damage_counters", "target": "self"},
                                {"const": 10},
                            ],
                        },
                    ],
                },
            },
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertEqual(state.p2.active.damage_counters, 7)

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
            "energy_attach_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(request.request_type, "distribute_energy")
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "energy_attach_distribution",
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
            "energy_attach_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "energy_attach_distribution",
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
            "energy_attach_distribution",
        )
        request = engine.choice_request(state, result.pending_choice)
        self.assertEqual(
            request.metadata.get("continuation", {}).get("kind"),
            "energy_attach_distribution",
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
        state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_tool_exp_share",
            "args": {},
            "branches": {},
        }))
        self.assertTrue(stack.resolve_all(0, "bench_0").success)
        stack = ResolutionStack(state)
        stack.push(compile_command_spec({
            "op": "register_tool_exp_share",
            "args": {},
            "branches": {},
        }))
        self.assertTrue(stack.resolve_all(0, "bench_1").success)
        observed_payloads = []

        def observe_ko_payload(data):
            observed_payloads.append(dict(data))
            return None

        state.event_bus.register(
            EventType.POKEMON_KO,
            observe_ko_payload,
            source="test:observe_ko_payload",
            owner_player=0,
            priority=-50,
        )
        trigger_results = state.event_bus.emit(
            EventType.POKEMON_KO,
            state=state,
            player_idx=0,
            slot="active",
            knocked_out=state.p1.active,
            from_attack=True,
        )
        self.assertEqual(
            [card.api_id for card in state.p1.active.energy_cards],
            ["sv1-ener-2"],
        )
        self.assertEqual(state.p1.bench[0].energy_cards, [])
        self.assertEqual(state.p1.bench[1].energy_cards, [])
        self.assertEqual(len(trigger_results), 2)
        self.assertEqual(
            [result.get("exclusive_group") for result in trigger_results],
            ["tool_exp_share", "tool_exp_share"],
        )
        self.assertEqual(len(observed_payloads), 1)
        self.assertNotIn("exp_share_used", observed_payloads[0])
        trigger_specs = command_specs_from_trigger_results(trigger_results)
        self.assertEqual(len(trigger_specs), 1)
        self.assertEqual(trigger_specs[0]["op"], "trigger_move_basic_energy")
        self.assertEqual(
            trigger_specs[0]["args"],
            {
                "from_player": 0,
                "from_slot": "active",
                "to_player": 0,
                "to_slot": "bench_0",
                "source": "学习装置",
            },
        )
        trigger_result = execute_trigger_commands(
            state,
            trigger_specs,
            player_idx=0,
            source_slot="active",
        )
        self.assertTrue(trigger_result.success)
        self.assertEqual(state.p1.active.energy_cards, [])
        self.assertEqual(
            [card.api_id for card in state.p1.bench[0].energy_cards],
            ["sv1-ener-2"],
        )

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
        from engine.effects.pokemon_stat_hooks import current_hp as hooked_current_hp
        from engine.effects.retreat_modifier_hooks import effective_retreat_cost as hooked_retreat_cost

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
        self.assertTrue(stack.resolve_all(0, "active").success)
        trigger_results = state.event_bus.emit(
            EventType.DAMAGE_DEALT,
            final_damage=50,
            attacker=state.p2.active,
            defender=state.p1.active,
            state=state,
            ignore_defender_effects=False,
        )
        self.assertEqual(state.p2.active.damage_counters, 0)
        trigger_specs = command_specs_from_trigger_results(trigger_results)
        self.assertEqual(len(trigger_specs), 1)
        self.assertEqual(trigger_specs[0]["op"], "trigger_place_damage_counters")
        self.assertEqual(
            {
                key: trigger_specs[0]["args"][key]
                for key in ("player", "slot", "count")
            },
            {"player": 1, "slot": "active", "count": 6},
        )
        trigger_result = execute_trigger_commands(state, trigger_specs)
        self.assertTrue(trigger_result.success)
        self.assertEqual(state.p2.active.damage_counters, 6)

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active.energy_cards = [CardRegistry.get("svi-mirc")]
        state.p2.deck = [CardRegistry.get("sv1-ener-3")]
        from engine.commands.modifier_registration import register_pokemon_modifiers

        register_pokemon_modifiers(
            state.p2.active,
            1,
            "active",
            event_bus=state.event_bus,
        )
        trigger_results = state.event_bus.emit(
            EventType.DAMAGE_DEALT,
            final_damage=10,
            attacker=state.p1.active,
            defender=state.p2.active,
            state=state,
            ignore_defender_effects=False,
        )
        self.assertEqual(len(state.p2.hand), 0)
        trigger_specs = command_specs_from_trigger_results(trigger_results)
        self.assertEqual(len(trigger_specs), 1)
        self.assertEqual(trigger_specs[0]["op"], "trigger_draw_cards")
        self.assertEqual(
            trigger_specs[0]["args"],
            {"player": 1, "amount": 1, "source": "奇迹能量"},
        )
        trigger_result = execute_trigger_commands(state, trigger_specs)
        self.assertTrue(trigger_result.success)
        self.assertEqual(len(state.p2.hand), 1)

        legacy_trigger_payloads = [
            {"command": trigger_specs[0]},
            {"commands": [trigger_specs[0]]},
            object(),
        ]
        self.assertEqual(command_specs_from_trigger_results(legacy_trigger_payloads), [])
        shorthand_trigger_specs = command_specs_from_trigger_results([
            {"command_specs": [{"op": "draw_cards", "player": 1, "amount": 1}]}
        ])
        self.assertEqual(shorthand_trigger_specs[0]["op"], "trigger_draw_cards")
        empty_group_specs = command_specs_from_trigger_results([
            {"exclusive_group": "empty-first", "command_specs": []},
            {"exclusive_group": "empty-first", "command_specs": [None]},
            {
                "exclusive_group": "empty-first",
                "command_specs": [{
                    "op": "trigger_draw_cards",
                    "args": {"player": 1, "amount": 1, "source": "empty-first"},
                    "branches": {},
                }],
            },
        ])
        self.assertEqual(len(empty_group_specs), 1)
        self.assertEqual(empty_group_specs[0]["op"], "trigger_draw_cards")
        self.assertEqual(empty_group_specs[0]["args"]["source"], "empty-first")
        with self.assertRaisesRegex(ValueError, "serializable VM command spec"):
            command_specs_from_trigger_results([{"command_specs": [object()]}])
        with self.assertRaisesRegex(ValueError, "command_specs must be a list"):
            command_specs_from_trigger_results([{"command_specs": {"op": "draw_cards"}}])
        with self.assertRaisesRegex(ValueError, "registered trigger_\\* VM ops"):
            command_specs_from_trigger_results([
                {
                    "command_specs": [{
                        "op": "draw_cards",
                        "args": {"amount": 1},
                        "branches": {},
                    }],
                }
            ])
        with self.assertRaisesRegex(ValueError, "registered trigger_\\* VM ops"):
            command_specs_from_trigger_results([
                {"op": "draw_cards", "args": {"amount": 1}, "branches": {}}
            ])
        bad_trigger_result = execute_trigger_commands(state, [object()])
        self.assertFalse(bad_trigger_result.success)
        self.assertIn("serializable VM command spec", bad_trigger_result.log_message)
        non_trigger_result = execute_trigger_commands(
            state,
            [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
        )
        self.assertFalse(non_trigger_result.success)
        self.assertIn("registered trigger_* VM ops", non_trigger_result.log_message)

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
        self.assertEqual(hooked_retreat_cost(state, state.p1), 0)

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
        self.assertEqual(hooked_current_hp(state.p1.active), 200)
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
        stack = ResolutionStack(state)
        attack_context = begin_attack_damage_context(state, stack, {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 30,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        })
        stack.push(compile_command_spec({
            "op": "conditional_damage",
            "args": {"bonus": 120, "condition": "opponent_active_damaged"},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIs(attack_damage_context(state, stack), attack_context)
        self.assertEqual(attack_context["base_damage"], 150)
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
        stack = ResolutionStack(state)
        attack_context = begin_attack_damage_context(state, stack, {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 0,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        })
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
        self.assertIs(attack_damage_context(state, stack), attack_context)
        self.assertEqual(attack_context["base_damage"], 240)
        self.assertTrue(attack_context["piercing"])
        self.assertTrue(attack_context["ignore_defender_effects"])

        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        stack = ResolutionStack(state)
        attack_context = begin_attack_damage_context(state, stack, {
            "active": True,
            "player_idx": 0,
            "attacker": state.p1.active,
            "base_damage": 0,
            "attacker_type": "Fire",
            "piercing": False,
            "ignore_defender_effects": False,
        })
        stack.push(compile_command_spec({"op": "deal_damage", "args": {"amount": 30}}))
        stack.push(compile_command_spec({
            "op": "set_attack_flags",
            "args": {"ignore_weakness": True, "ignore_resistance": True, "ignore_effects": True},
            "branches": {},
        }))
        result = stack.resolve_all(0, "active")
        self.assertTrue(result.success)
        self.assertIs(attack_damage_context(state, stack), attack_context)
        self.assertEqual(attack_context["base_damage"], 30)
        self.assertTrue(attack_context["piercing"])
        self.assertTrue(attack_context["ignore_defender_effects"])

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

    def test_attack_frame_fails_on_invalid_explicit_trigger_command_specs(self):
        state = GameState()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))

        state.event_bus.register(
            EventType.DAMAGE_DEALT,
            lambda _data: {"command_specs": [object()]},
            source="bad-trigger-spec",
            owner_player=0,
        )

        stack = ResolutionStack(state)
        begin_attack_damage_context(
            state,
            stack,
            {
                "active": True,
                "player_idx": 0,
                "attacker": state.p1.active,
                "base_damage": 20,
                "attacker_type": "Fire",
            },
        )
        stack.push(FinalizeAttackDamage())

        result = stack.resolve_all(0, "active")

        self.assertFalse(result.success)
        self.assertIn("serializable VM command spec", " ".join(result.log_messages))
        self.assertEqual(state.p2.active.damage_counters, 0)

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
        self.assertEqual(contract["vm_version"], VM_IR_VERSION)
        self.assertEqual(contract["vm"]["runtime_effect_source"], "compiled_effects")

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

import json
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.actions import ChoiceResponse
from engine.commands.continuation_state import (
    ContinuationStateError,
    restore_resolution_stack,
)
from engine.commands.resolution_stack import ResolutionStack
from engine.commands.dsl_compiler import compile_command_spec
from engine.commands.vm_registry import ContinuationRegistry
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.actions import GameAction
from engine.player_state import PokemonInPlay
from engine.random_source import ScriptedRandomSource
from engine.snapshot import (
    clone_state,
    snapshot_from_dict,
    snapshot_state,
    snapshot_to_dict,
    state_from_snapshot,
)


class PendingContinuationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def _state_with_pending_discard(self):
        state = GameState()
        state.p1.hand = [
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-4"),
        ]
        legacy = ActionRequest(
            request_type="search_deck",
            player=0,
            prompt="选择一张手牌丢弃",
            min_select=1,
            max_select=1,
            from_zone="hand",
            card_list=list(state.p1.hand),
            continuation={
                "kind": "discard_hand_cards",
                "player_idx": 0,
                "amount": 1,
            },
        )
        # Production VM requests are wrapped before they reach GameEngine.
        legacy = ResolutionStack(state)._wrap_pending_choice(legacy, 0, "active")
        engine = GameEngine()
        request = engine.choice_request(state, legacy)
        return engine, state, request

    def test_json_snapshot_rebuilds_pending_continuation_and_applies_choice(self):
        engine, state, request = self._state_with_pending_discard()
        payload = json.loads(json.dumps(snapshot_to_dict(snapshot_state(state))))
        restored = state_from_snapshot(snapshot_from_dict(payload))

        self.assertIsNone(restored._pending_choice_runtime)
        rebuilt = engine.pending_choice_request(restored)
        self.assertEqual(rebuilt.request_id, request.request_id)
        self.assertEqual(
            rebuilt.metadata["continuation"]["kind"],
            "discard_hand_cards",
        )

        response = ChoiceResponse(rebuilt.request_id, (rebuilt.options[0].option_id,))
        result = engine.apply_choice(restored, rebuilt, response)

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(restored.p1.hand), 1)
        self.assertEqual(len(restored.p1.discard), 1)
        self.assertIsNone(restored.resolution_stack["pending_request"])

    def test_pending_continuation_clone_resolves_independently(self):
        engine, state, _request = self._state_with_pending_discard()
        cloned = clone_state(state)
        cloned_request = engine.pending_choice_request(cloned)
        result = engine.apply_choice(
            cloned,
            cloned_request,
            ChoiceResponse(
                cloned_request.request_id,
                (cloned_request.options[1].option_id,),
            ),
        )

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(cloned.p1.hand), 1)
        self.assertEqual(len(cloned.p1.discard), 1)
        self.assertEqual(len(state.p1.hand), 2)
        self.assertEqual(len(state.p1.discard), 0)
        self.assertIsNotNone(state.resolution_stack["pending_request"])

    def test_attack_snapshot_restores_remaining_damage_and_turn_frames(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(CardRegistry.get("sv1-114"))
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active = PokemonInPlay(CardRegistry.get("sv2-delib"))
        psychic = CardRegistry.get("sv1-ener-5")
        water = CardRegistry.get("sv1-ener-3")
        state.p1.active.energy_cards = [psychic, water]
        state.p1.deck = [water] * 8
        state.p2.deck = [water] * 8
        state.p1.prizes = [water] * 6
        state.p2.prizes = [water] * 6
        engine = GameEngine()

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        resume = step.pending_choice.metadata["continuation"]["_resume"]
        self.assertTrue(resume["complete"])
        self.assertEqual(
            [frame["kind"] for frame in resume["frames"]],
            ["finalize_attack_turn", "finalize_attack_ko_checks"],
        )

        restored = state_from_snapshot(snapshot_state(state))
        request = engine.pending_choice_request(restored)
        decline = next(option for option in request.options if option.value is False)
        result = engine.apply_choice(
            restored,
            request,
            ChoiceResponse(request.request_id, (decline.option_id,)),
        )

        self.assertTrue(result.success, result.message)
        self.assertEqual(restored.p2.active.damage_counters, 5)
        self.assertEqual(restored.active_player_idx, 1)
        self.assertEqual(restored.phase, TurnPhase.MAIN)

    def test_snapshot_restores_compiled_commands_after_choice(self):
        state = GameState()
        state.p1.deck = [
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-4"),
            CardRegistry.get("sv1-ener-5"),
        ]
        stack = ResolutionStack(state)
        stack.push_many([
            compile_command_spec({
                "op": "search_cards",
                "args": {
                    "from_zone": "deck",
                    "filter": "energy",
                    "destination": "hand",
                    "count": 1,
                },
                "branches": {},
            }),
            compile_command_spec({
                "op": "draw_cards",
                "args": {"amount": 1, "player": "self"},
                "branches": {},
            }),
        ])
        pending = stack.resolve_all(0, "active").pending_choice
        engine = GameEngine()
        request = engine.choice_request(state, pending)
        resume = request.metadata["continuation"]["_resume"]
        self.assertEqual(resume["frames"][0]["kind"], "command_spec")
        self.assertEqual(resume["frames"][0]["spec"]["op"], "draw_cards")

        restored = state_from_snapshot(snapshot_state(state))
        rebuilt = engine.pending_choice_request(restored)
        result = engine.apply_choice(
            restored,
            rebuilt,
            ChoiceResponse(rebuilt.request_id, (rebuilt.options[0].option_id,)),
        )

        self.assertTrue(result.success, result.message)
        self.assertEqual(len(restored.p1.hand), 2)
        self.assertEqual(len(restored.p1.deck), 1)

    def test_snapshot_rejects_incomplete_vm_resume_frames(self):
        class UntaggedCommand:
            def execute(self, _ctx):
                from engine.commands.base import CommandResult

                return CommandResult.ok()

        state = GameState()
        state.p1.deck = [CardRegistry.get("sv1-ener-3")]
        stack = ResolutionStack(state)
        stack.push_many([
            compile_command_spec({
                "op": "search_cards",
                "args": {
                    "from_zone": "deck",
                    "filter": "energy",
                    "destination": "hand",
                    "count": 1,
                },
                "branches": {},
            }),
            UntaggedCommand(),
        ])
        engine = GameEngine()
        request = engine.choice_request(state, stack.resolve_all(0, "active").pending_choice)
        self.assertFalse(request.metadata["continuation"]["_resume"]["complete"])

        restored = state_from_snapshot(snapshot_state(state))
        result = engine.apply_choice(
            restored,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "unsupported_continuation_state")

    def test_corrupt_compiled_resume_frame_fails_closed_without_mutation(self):
        state = GameState()
        engine = GameEngine()
        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "corrupt resume",
                continuation={
                    "kind": "choose_heal_damage",
                    "_resume": {
                        "version": 1,
                        "player_idx": 0,
                        "source_slot": "active",
                        "complete": True,
                        "frames": [{
                            "kind": "command_spec",
                            "spec": {"op": "not_a_real_vm_op"},
                        }],
                        "context": {},
                        "attack_failed": False,
                    },
                },
            ),
        )
        restored = state_from_snapshot(snapshot_state(state))
        before = snapshot_state(restored)

        result = engine.apply_choice(
            restored,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "unsupported_continuation_state")
        self.assertEqual(snapshot_state(restored), before)

    def test_restored_attack_choice_requires_serialized_remaining_frames(self):
        state = GameState()
        engine = GameEngine()
        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "attack choice",
                continuation={"kind": "choose_heal_damage"},
            ),
        )
        request.metadata["finish_attack_actor"] = 0
        engine.transaction_manager.persist_pending_choice(state, request)
        restored = state_from_snapshot(snapshot_state(state))
        before = snapshot_state(restored)

        result = engine.apply_choice(
            restored,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "unsupported_continuation_state")
        self.assertEqual(snapshot_state(restored), before)

    def test_finish_attack_actor_rejects_bool_in_canonical_pending_state(self):
        engine, state, request = self._state_with_pending_discard()
        request.metadata["finish_attack_actor"] = True
        engine.transaction_manager.persist_pending_choice(state, request)
        restored = state_from_snapshot(snapshot_state(state))
        before = snapshot_state(restored)

        result = engine.apply_choice(
            restored,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "invalid_pending_choice")
        self.assertEqual(snapshot_state(restored), before)

    def test_vm_resume_rejects_bool_values_in_integer_and_flag_fields(self):
        base = {
            "version": 1,
            "player_idx": 0,
            "source_slot": "active",
            "complete": True,
            "frames": [],
            "context": {},
            "attack_failed": False,
        }
        corruptions = (
            ("version", True),
            ("player_idx", False),
            ("complete", 1),
            ("attack_failed", 0),
        )
        for field, value in corruptions:
            with self.subTest(field=field):
                payload = dict(base)
                payload[field] = value
                with self.assertRaises(ContinuationStateError):
                    restore_resolution_stack(ResolutionStack(GameState()), payload)

        finalize = dict(base)
        finalize["frames"] = [{"kind": "finalize_attack_turn", "actor": True}]
        with self.assertRaisesRegex(ContinuationStateError, "actor is invalid"):
            restore_resolution_stack(ResolutionStack(GameState()), finalize)

    def test_pending_payload_rejects_bool_player_and_revision(self):
        engine, state, request = self._state_with_pending_discard()
        state._pending_choice_runtime = None
        state.resolution_stack["pending_request"]["player"] = True
        with self.assertRaisesRegex(ValueError, "数值字段无效"):
            engine.pending_choice_request(state)

        engine, state, request = self._state_with_pending_discard()
        request.metadata["revision"] = True
        state.resolution_stack["pending_request"]["metadata"]["revision"] = True
        before = snapshot_state(state)
        result = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (request.options[0].option_id,)),
        )
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "stale_choice")
        self.assertEqual(snapshot_state(state), before)

    def test_state_owned_runtime_ignores_forged_callback(self):
        engine, state, request = self._state_with_pending_discard()
        forged_called = []
        forged_legacy = ActionRequest(
            request_type=request.request_type,
            player=0,
            prompt=request.prompt,
            callback=lambda _choice: forged_called.append(True),
        )
        forged = replace(request, legacy_request=forged_legacy)

        result = engine.apply_choice(
            state,
            forged,
            ChoiceResponse(forged.request_id, (forged.options[0].option_id,)),
        )

        self.assertTrue(result.success, result.message)
        self.assertEqual(forged_called, [])
        self.assertEqual(len(state.p1.discard), 1)

    def test_unknown_and_callback_only_snapshot_continuations_fail_closed(self):
        state = GameState()
        engine = GameEngine()
        unknown = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "unknown",
                continuation={"kind": "not_registered"},
            ),
        )
        result = engine.apply_choice(
            state,
            unknown,
            ChoiceResponse(unknown.request_id, ("confirm:yes",)),
        )
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "unknown_continuation")

        legacy_state = GameState()
        legacy = engine.choice_request(
            legacy_state,
            ActionRequest(
                "confirm",
                0,
                "legacy callback",
                callback=lambda _choice: ActionResult(True, "resolved"),
            ),
        )
        restored = state_from_snapshot(snapshot_state(legacy_state))
        result = engine.apply_choice(
            restored,
            legacy,
            ChoiceResponse(legacy.request_id, ("confirm:yes",)),
        )
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "missing_continuation")

    def test_restored_continuation_exception_rolls_back_state_rng_and_pending(self):
        state = GameState()
        state.p1.hand = [CardRegistry.get("sv1-ener-3")]
        engine = GameEngine()
        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "transactional continuation",
                continuation={"kind": "test_transaction_failure"},
            ),
        )
        restored = state_from_snapshot(snapshot_state(state))
        rng = ScriptedRandomSource([True, False], seed=17)
        before = snapshot_state(restored)
        before_rng = rng.getstate()

        def registry_factory(stack):
            registry = ContinuationRegistry()

            def fail_after_mutation(_req, _cont, _choice, _player_idx, _slot):
                stack.state.p1.hand.clear()
                rng.coin()
                raise RuntimeError("continuation failed")

            registry.register("test_transaction_failure", fail_after_mutation)
            return registry

        with patch(
            "engine.commands.vm_interpreter.build_resolution_stack_continuation_registry",
            registry_factory,
        ):
            rebuilt = engine.pending_choice_request(restored)
            result = engine.apply_choice(
                restored,
                rebuilt,
                ChoiceResponse(rebuilt.request_id, ("confirm:yes",)),
                rng,
            )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "choice_exception")
        self.assertIn("continuation failed", result.message)
        self.assertEqual(snapshot_state(restored), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertIsNotNone(restored.resolution_stack["pending_request"])


if __name__ == "__main__":
    unittest.main()

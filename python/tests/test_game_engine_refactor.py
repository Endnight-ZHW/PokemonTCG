import json
import copy
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from data.card_models import AbilityDef, Card, EffectDef
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.action_codec import deserialize_game_action, serialize_game_action
from engine.actions import CardRef, ChoiceResponse, GameAction, PokemonRef, StepResult
from engine.action_availability import VMActionAvailability
from engine.ai.observation import Observation, fair_search_clone
from engine.ai.planner import AnytimePlanner, HeuristicBackend, PlannerConfig
from engine.commands.vm_registry import ContinuationRegistry
from engine.enums import EventType, PlayerAction, StatusType, TurnPhase
from engine.events.game_events import GameEvent
from engine.choice_manager import VMChoiceManager
from engine.commands.vm_interpreter import VMInterpreter
from engine.effect_runner import VMEffectRunner
from engine.game_engine import GameEngine
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.player_state import PokemonInPlay
from engine.random_source import (
    PortableRandomSourceV1,
    RandomSource,
    SamplingRandomSource,
    ScriptedRandomSource,
)
from engine.settlement import VMSettlementManager
from engine.snapshot import SnapshotManager, clone_state, snapshot_state
from engine.transaction_manager import VMTransactionManager
from engine.turn_manager import TurnManager


class GameEngineRefactorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    def _main_state(self) -> GameState:
        basic = CardRegistry.get("sv2-delib")
        energy = CardRegistry.get("sv1-ener-3")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(basic)
        state.p1.active.damage_counters = 2
        state.p1.active.energy_cards = [energy]
        state.p1.bench[0] = PokemonInPlay(basic)
        state.p1.bench[0].damage_counters = 1
        state.p1.hand = [
            CardRegistry.get("svi-chim"),
            energy,
            CardRegistry.get("svf-potion"),
        ]
        state.p1.deck = [energy] * 8
        state.p2.active = PokemonInPlay(CardRegistry.get("svi-chim"))
        state.p2.deck = [CardRegistry.get("sv1-ener-2")] * 8
        state.p1.prizes = [energy] * 6
        state.p2.prizes = [energy] * 6
        return state

    def test_public_transaction_boundary_lives_in_transaction_manager(self):
        engine = GameEngine()
        self.assertIsInstance(engine.transaction_manager, VMTransactionManager)

        state = self._main_state()
        rng = PortableRandomSourceV1(17)
        checkpoint = engine.transaction_manager.capture_transaction(state, rng)
        expected_state = checkpoint["state"]
        expected_rng = checkpoint["rng_state"]

        state.turn_number = 99
        state.action_log.append("must roll back")
        rng.coin()
        engine.transaction_manager.rollback_transaction(state, rng, checkpoint)

        self.assertEqual(snapshot_state(state), expected_state)
        self.assertEqual(rng.getstate(), expected_rng)

    def test_non_attack_choice_chain_persists_next_pending_request(self):
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.active_player_idx = 0
        state.revision = 4
        engine = GameEngine()

        second_request = ActionRequest(
            request_type="confirm",
            player=0,
            prompt="second choice",
            callback=lambda _payload: ActionResult(True, "second resolved"),
        )
        first_request = ActionRequest(
            request_type="confirm",
            player=0,
            prompt="first choice",
            callback=lambda _payload: second_request,
        )
        first_choice = engine.choice_request(state, first_request)
        engine.transaction_manager.persist_pending_choice(state, first_choice)

        step = engine.apply_choice(
            state,
            first_choice,
            ChoiceResponse(first_choice.request_id, ("confirm:yes",)),
            RandomSource(7),
        )

        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        self.assertEqual(step.pending_choice.prompt, "second choice")
        self.assertEqual(
            state.resolution_stack["pending_request"]["request_id"],
            step.pending_choice.request_id,
        )
        self.assertEqual(
            state.resolution_stack["pending_request"]["prompt"],
            "second choice",
        )

    def test_invalid_actor_fails_closed_at_public_boundaries(self):
        state = self._main_state()
        engine = GameEngine()
        before = snapshot_state(state)

        with self.assertRaises(ValueError):
            state.get_player(2)
        with self.assertRaises(ValueError):
            state.get_player(True)
        self.assertEqual(engine.legal_actions(state, -1), ())

        result = engine.apply_action(
            state,
            GameAction("NOOP", actor=2),
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "invalid_actor")
        self.assertEqual(snapshot_state(state), before)

    def test_pending_choice_blocks_actions_and_rejects_forged_requests(self):
        state = self._main_state()
        engine = GameEngine()
        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "authoritative request",
                callback=lambda _choice: ActionResult(True, "resolved"),
            ),
        )
        before = snapshot_state(state)

        blocked = engine.apply_action(state, GameAction("NOOP", actor=0))
        self.assertFalse(blocked.success)
        self.assertEqual(blocked.error_code, "pending_choice")
        self.assertEqual(engine.legal_actions(state, 0), ())

        forged = replace(request, player=1)
        rejected = engine.apply_choice(
            state,
            forged,
            ChoiceResponse(forged.request_id, ("confirm:yes",)),
        )
        self.assertFalse(rejected.success)
        self.assertEqual(rejected.error_code, "stale_choice")

        invalid_actor = replace(request, player=9)
        rejected = engine.apply_choice(
            state,
            invalid_actor,
            ChoiceResponse(invalid_actor.request_id, ("confirm:yes",)),
        )
        self.assertFalse(rejected.success)
        self.assertEqual(rejected.error_code, "invalid_actor")
        self.assertEqual(snapshot_state(state), before)

        no_pending = engine.apply_choice(
            self._main_state(),
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
        )
        self.assertFalse(no_pending.success)
        self.assertEqual(no_pending.error_code, "no_pending_choice")

    def test_choice_policy_exception_rolls_back_whole_action(self):
        state = self._main_state()
        engine = GameEngine()
        rng = ScriptedRandomSource([True, False], seed=41)
        potion_action = next(
            action
            for action in engine.legal_actions(state, 0)
            if action.action == PlayerAction.PLAY_TRAINER
            and state.p1.hand[action.params["hand_idx"]].api_id == "svf-potion"
        )
        before = snapshot_state(state)
        before_rng = rng.getstate()

        def broken_policy(policy_state, _request):
            rng.coin()
            policy_state.p1.active.damage_counters += 5
            raise RuntimeError("broken choice policy")

        result = engine.apply_action(
            state,
            potion_action,
            rng,
            auto_resolve=True,
            choice_policy=broken_policy,
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "choice_policy_exception")
        self.assertIn("broken choice policy", result.message)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)

    def test_choice_exception_restores_scripted_coin_cursor(self):
        state = self._main_state()
        engine = GameEngine()
        rng = ScriptedRandomSource([True, False], seed=43)

        def broken_callback(_choice):
            self.assertTrue(state.random_source.coin())
            state.p1.active.damage_counters += 3
            raise RuntimeError("broken choice callback")

        request = engine.choice_request(
            state,
            ActionRequest("confirm", 0, "confirm", callback=broken_callback),
        )
        before = snapshot_state(state)
        before_rng = rng.getstate()

        result = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
            rng,
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "choice_exception")
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertTrue(rng.coin())

    def test_turn_markers_expire_at_their_authoritative_boundaries(self):
        state = self._main_state()
        state.phase = TurnPhase.POKEMON_CHECKUP
        state.p1.active.dazzled = True
        state.p1.was_ko_by_attack = True
        state.p2.active.damage_prevented_next_turn = True
        state.p2.active.all_prevented_next_turn = True
        state.p2.was_ko_by_attack = True
        rng = RandomSource(47)

        with rng.bind_state(state):
            TurnManager(state).advance_phase()

        self.assertEqual(state.active_player_idx, 1)
        self.assertFalse(state.p1.active.dazzled)
        self.assertFalse(state.p1.was_ko_by_attack)
        self.assertFalse(state.p2.active.damage_prevented_next_turn)
        self.assertFalse(state.p2.active.all_prevented_next_turn)
        self.assertTrue(state.p2.was_ko_by_attack)

        with rng.bind_state(state):
            result = TurnManager(state).perform_action(PlayerAction.END_TURN, 1)
        self.assertTrue(result.success, result.log_message)
        self.assertFalse(state.p2.was_ko_by_attack)

    def test_confused_and_dazzled_failed_attacks_still_finish_turn(self):
        for marker in ("confused", "dazzled"):
            with self.subTest(marker=marker):
                state = self._main_state()
                if marker == "confused":
                    state.p1.active.status_conditions.add(StatusType.CONFUSED)
                else:
                    state.p1.active.dazzled = True

                result = GameEngine().apply_action(
                    state,
                    GameAction(
                        PlayerAction.DECLARE_ATTACK,
                        {"attack_idx": 0},
                        actor=0,
                    ),
                    ScriptedRandomSource([False]),
                )

                self.assertTrue(result.success, result.message)
                self.assertTrue(result.action_result.attack_failed)
                self.assertEqual(state.active_player_idx, 1)
                self.assertEqual(state.turn_number, 4)
                self.assertEqual(state.phase, TurnPhase.MAIN)
                self.assertEqual(len(state.p2.hand), 1)

    def test_confusion_self_ko_finishes_turn_after_promotion(self):
        state = self._main_state()
        state.p1.active.damage_counters = 3
        state.p1.active.status_conditions.add(StatusType.CONFUSED)

        engine = GameEngine()
        attack = engine.apply_action(
            state,
            GameAction(
                PlayerAction.DECLARE_ATTACK,
                {"attack_idx": 0},
                actor=0,
            ),
            ScriptedRandomSource([False]),
        )

        self.assertTrue(attack.success, attack.message)
        self.assertIsNone(state.p1.active)
        self.assertEqual(state.pending_promotions, [0])
        self.assertEqual(state.phase, TurnPhase.ATTACK)

        self.assertIsNotNone(attack.pending_choice)
        prize = engine.apply_choice(
            state,
            attack.pending_choice,
            ChoiceResponse(
                attack.pending_choice.request_id,
                (attack.pending_choice.options[0].option_id,),
            ),
        )
        self.assertTrue(prize.success, prize.message)

        promotion = engine.apply_action(
            state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
        )

        self.assertTrue(promotion.success, promotion.message)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)
        self.assertEqual(state.pending_promotions, [])

    def test_snapshot_preserves_debug_state(self):
        state = self._main_state()
        state.mulligan_count = (2, 1)
        state.extra_draws = (1, 3)
        state.action_log = ["before snapshot"]

        restored = clone_state(state)

        self.assertEqual(restored.mulligan_count, (2, 1))
        self.assertEqual(restored.extra_draws, (1, 3))
        self.assertEqual(restored.action_log, ["before snapshot"])

    def test_choice_request_boundary_lives_in_choice_manager(self):
        engine = GameEngine()
        self.assertIsInstance(engine.choice_manager, VMChoiceManager)

        state = self._main_state()
        legacy = ActionRequest(
            request_type="confirm",
            player=0,
            prompt="confirm",
            min_select=1,
            max_select=1,
            continuation={"kind": "test_confirm"},
        )
        request = engine.choice_manager.choice_request(state, legacy)
        response = engine.choice_manager.default_choice_response(
            request,
            PortableRandomSourceV1(5),
        )

        self.assertEqual(request.request_id, legacy.request_id)
        self.assertEqual(response.request_id, request.request_id)
        self.assertEqual(len(response.option_ids), 1)
        selected = [
            option for option in request.options
            if option.option_id in response.option_ids
        ]
        self.assertIs(
            engine.choice_manager.legacy_choice_payload(legacy, selected, response),
            True,
        )

    def test_settlement_boundary_lives_in_settlement_manager(self):
        engine = GameEngine()
        self.assertIsInstance(engine.settlement_manager, VMSettlementManager)
        self.assertIs(engine.settlement_manager.choice_manager, engine.choice_manager)

        state = self._main_state()
        event = {"event_type": "test_event", "data": {"value": 1}}
        first = engine.settlement_manager.step_from_action_result(
            state,
            ActionResult(True, "first"),
            events=(event,),
        )
        second = StepResult(True, "second", events=({"event_type": "second"},))
        merged = engine.settlement_manager.merge_steps(first, second)

        self.assertTrue(merged.success)
        self.assertIn("first", merged.message)
        self.assertIn("second", merged.message)
        self.assertEqual(
            [row["event_type"] for row in merged.events],
            ["test_event", "second"],
        )

    def test_action_availability_boundary_lives_in_availability_service(self):
        engine = GameEngine()
        self.assertIsInstance(engine.availability, VMActionAvailability)

        sentinel = GameAction(PlayerAction.END_TURN, actor=0)

        class RecordingAvailability(VMActionAvailability):
            def __init__(self):
                super().__init__()
                self.calls = []

            def enumerate_actions(self, state, actor):
                self.calls.append((state, actor))
                return (sentinel,)

        availability = RecordingAvailability()
        delegated = GameEngine(availability=availability)
        state = self._main_state()

        self.assertEqual(
            delegated.legal_actions(state, 0, validate_effects=False),
            (sentinel,),
        )
        self.assertEqual(availability.calls, [(state, 0)])

    def test_action_resolver_vm_effect_execution_lives_in_effect_runner(self):
        from engine.action_resolver import ActionResolver

        state = GameState()
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        resolver = ActionResolver(state)
        runner = resolver._effect_runner()
        self.assertIsInstance(runner, VMEffectRunner)

        result = runner.execute_effects(
            [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
            0,
            "active",
        )

        self.assertTrue(result.success, result.log_message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

    def test_resolution_stack_interpreter_loop_lives_in_vm_interpreter(self):
        from engine.commands.dsl_compiler import compile_command_spec
        from engine.commands.resolution_stack import ResolutionStack

        state = GameState()
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        self.assertIsInstance(stack.vm_interpreter, VMInterpreter)
        stack.push(compile_command_spec({
            "op": "draw_cards",
            "args": {"amount": 1},
            "branches": {},
        }))
        resolved = stack.resolve_all(0, "active")

        self.assertTrue(resolved.success)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

        registry = ContinuationRegistry()
        injected = ResolutionStack(GameState(), continuation_registry=registry)
        self.assertIs(injected.continuation_registry, registry)

    def test_runtime_trigger_settlement_uses_serializable_command_specs(self):
        from engine.commands.resolution_stack import ResolutionStack
        from engine.commands.trigger_commands import (
            command_specs_from_trigger_results,
            push_trigger_command_specs,
            trigger_draw_cards_spec,
        )

        spec = trigger_draw_cards_spec(0, 1, "behavior-test")
        normalized = command_specs_from_trigger_results([
            {"source": "behavior-test", "command_specs": [spec]},
            {"source": "legacy", "command": object(), "commands": [object()]},
        ])
        self.assertEqual(normalized, [spec])
        with self.assertRaisesRegex(ValueError, "serializable VM command spec"):
            command_specs_from_trigger_results([
                {"command_specs": [object()]},
            ])

        state = GameState()
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        stack = ResolutionStack(state)
        push_trigger_command_specs(stack, normalized)
        resolved = stack.resolve_all(0, "active")

        self.assertTrue(resolved.success)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

    def test_every_enumerated_action_executes_on_a_snapshot(self):
        state = self._main_state()
        engine = GameEngine()
        actions = engine.legal_actions(state, 0)
        self.assertTrue(actions)
        for action in actions:
            with self.subTest(action=action.signature):
                simulation = clone_state(state)
                result = engine.apply_action(
                    simulation,
                    action,
                    ScriptedRandomSource([True, False]),
                    auto_resolve=True,
                )
                self.assertTrue(result.success, result.message)

    def test_identical_pokemon_are_targeted_by_slot(self):
        state = self._main_state()
        engine = GameEngine()
        potion_action = next(
            action
            for action in engine.legal_actions(state, 0)
            if action.action == PlayerAction.PLAY_TRAINER
            and state.p1.hand[action.params["hand_idx"]].api_id == "svf-potion"
        )
        step = engine.apply_action(state, potion_action, auto_resolve=False)
        self.assertIsNotNone(step.pending_choice)
        bench_option = next(
            option
            for option in step.pending_choice.options
            if isinstance(option.ref, PokemonRef) and option.ref.slot == "bench_0"
        )
        active_damage = state.p1.active.damage_counters
        result = engine.apply_choice(
            state,
            step.pending_choice,
            ChoiceResponse(step.pending_choice.request_id, (bench_option.option_id,)),
        )
        self.assertTrue(result.success, result.message)
        self.assertEqual(state.p1.active.damage_counters, active_damage)
        self.assertEqual(state.p1.bench[0].damage_counters, 0)

    def test_choice_cardinality_and_duplicate_rules_are_enforced(self):
        state = self._main_state()
        request = ActionRequest(
            "search_deck",
            0,
            "choose",
            min_select=1,
            max_select=2,
            card_list=[state.p1.deck[0]],
            allow_duplicates=False,
            callback=lambda cards: None,
        )
        engine = GameEngine()
        structured = engine.choice_request(state, request)
        option_id = structured.options[0].option_id
        duplicate = engine.apply_choice(
            state,
            structured,
            ChoiceResponse(structured.request_id, (option_id, option_id)),
        )
        self.assertFalse(duplicate.success)
        self.assertEqual(duplicate.error_code, "duplicate_choice")

        structured = engine.choice_request(state, request)
        missing = engine.apply_choice(
            state,
            structured,
            ChoiceResponse(structured.request_id, ()),
        )
        self.assertFalse(missing.success)
        self.assertEqual(missing.error_code, "choice_count")

    def test_energy_distribution_rejects_per_target_limit_bypass(self):
        state = self._main_state()
        engine = GameEngine()
        callback_payloads = []
        structured = engine.choice_request(
            state,
            ActionRequest(
                "distribute_energy",
                0,
                "distribute",
                min_select=2,
                max_select=2,
                card_list=[state.p1.deck[0], state.p1.deck[1]],
                target_info=[
                    {"slot": "active", "name": "active"},
                    {"slot": "bench_0", "name": "bench"},
                ],
                max_per_target=1,
                callback=lambda payload: callback_payloads.append(payload),
            ),
        )
        active_options = [
            option
            for option in structured.options
            if option.value.get("slot") == "active"
        ]

        result = engine.apply_choice(
            state,
            structured,
            ChoiceResponse(
                structured.request_id,
                (active_options[0].option_id, active_options[1].option_id),
            ),
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "choice_target_limit")
        self.assertEqual(callback_payloads, [])
        self.assertIsNotNone(state.resolution_stack["pending_request"])

    def test_malformed_public_requests_fail_without_raising(self):
        state = self._main_state()
        engine = GameEngine()

        invalid_action = engine.apply_action(state, None)
        self.assertFalse(invalid_action.success)
        self.assertEqual(invalid_action.error_code, "invalid_action")

        invalid_ref = engine.apply_action(
            state,
            GameAction(PlayerAction.END_TURN, actor=0, source=object()),
        )
        self.assertFalse(invalid_ref.success)
        self.assertEqual(invalid_ref.error_code, "stale_action_reference")

        bool_ref = engine.apply_action(
            state,
            GameAction(
                PlayerAction.END_TURN,
                actor=0,
                source=CardRef(True, "hand", 0, ""),
            ),
        )
        self.assertFalse(bool_ref.success)
        self.assertEqual(bool_ref.error_code, "stale_action_reference")

        encoded = serialize_game_action(
            GameAction(
                PlayerAction.END_TURN,
                actor=0,
                source=CardRef(0, "hand", 0, ""),
            )
        )
        encoded["source"]["player"] = True
        with self.assertRaisesRegex(ValueError, "player is invalid"):
            deserialize_game_action(encoded)

        request = engine.choice_request(
            state,
            ActionRequest("confirm", 0, "confirm", callback=lambda _choice: None),
        )
        malformed_ref_request = replace(
            request,
            options=(replace(request.options[0], ref=PokemonRef(True, "active", "")),),
        )
        malformed_ref = engine.apply_choice(
            state,
            malformed_ref_request,
            ChoiceResponse(malformed_ref_request.request_id, ("confirm:yes",)),
        )
        self.assertFalse(malformed_ref.success)
        self.assertEqual(malformed_ref.error_code, "invalid_choice_request")

        malformed = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, None),
        )
        self.assertFalse(malformed.success)
        self.assertEqual(malformed.error_code, "invalid_choice_response")
        self.assertIsNotNone(state.resolution_stack["pending_request"])

        state.resolution_stack["sequence"] = {"not": "numeric"}
        blocked = engine.apply_action(
            state,
            GameAction(PlayerAction.END_TURN, actor=0),
        )
        self.assertFalse(blocked.success)
        self.assertEqual(blocked.error_code, "pending_choice")

    def test_corrupt_cancel_checkpoint_rolls_back_and_returns_failure(self):
        state = self._main_state()
        engine = GameEngine()
        rng = RandomSource(18)
        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "cancel",
                min_select=0,
                can_cancel=True,
            ),
        )
        state.resolution_stack["context"] = {
            "cancel_action_checkpoint": {
                "state": {"schema_version": 999},
            },
        }
        before = snapshot_state(state)
        before_rng = rng.getstate()

        result = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (), cancelled=True),
            rng,
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "choice_exception")
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)

    def test_state_owned_choice_structure_fails_closed(self):
        def negative_min(request):
            request.min_select = -1

        def inverted_bounds(request):
            request.max_select = request.min_select - 1

        def non_bool_duplicates(request):
            request.allow_duplicates = 1

        def non_bool_cancel(request):
            request.can_cancel = 1

        def empty_option_id(request):
            request.options = (
                replace(request.options[0], option_id=""),
                request.options[1],
            )

        def non_string_option_id(request):
            request.options = (
                replace(request.options[0], option_id=7),
                request.options[1],
            )

        def duplicate_option_id(request):
            request.options = (request.options[0], request.options[0])

        def non_string_option_label(request):
            request.options = (
                replace(request.options[0], label={"bad": "label"}),
                request.options[1],
            )

        corruptions = {
            "negative min": negative_min,
            "max below min": inverted_bounds,
            "non-bool allow_duplicates": non_bool_duplicates,
            "non-bool can_cancel": non_bool_cancel,
            "empty option id": empty_option_id,
            "non-string option id": non_string_option_id,
            "duplicate option id": duplicate_option_id,
            "non-string option label": non_string_option_label,
        }
        for label, corrupt in corruptions.items():
            with self.subTest(label=label):
                state = self._main_state()
                engine = GameEngine()
                callback_payloads = []
                request = engine.choice_request(
                    state,
                    ActionRequest(
                        "confirm",
                        0,
                        "confirm",
                        callback=lambda payload: callback_payloads.append(payload),
                    ),
                )
                corrupt(request)
                before = snapshot_state(state)
                with self.assertRaises(ValueError):
                    engine.transaction_manager.persist_pending_choice(state, request)
                self.assertEqual(callback_payloads, [])
                self.assertEqual(snapshot_state(state), before)

    def test_failed_choice_rolls_back_state_events_and_rng(self):
        state = self._main_state()
        engine = GameEngine()
        rng = RandomSource(19)

        def fail_after_mutation(_choice):
            state.random_source.coin()
            state.p1.active.damage_counters += 4
            state._log("partial choice mutation")
            state.event_stream.push(GameEvent("partial_choice", {"amount": 4}))
            return ActionResult(False, "choice failed")

        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "confirm",
                callback=fail_after_mutation,
            ),
        )
        before_state = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)

        result = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
            rng,
        )

        self.assertFalse(result.success)
        self.assertEqual(result.message, "choice failed")
        self.assertEqual(snapshot_state(state), before_state)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_failed_choice_restores_nested_events_runtime_and_result_payload(self):
        state = self._main_state()
        engine = GameEngine()
        state.event_stream.push(GameEvent("existing", {"nested": {"value": 1}}))
        holder = {}

        def fail_after_mutation(_choice):
            state.event_stream._events[0].data["nested"]["value"] = 99
            holder["request"].metadata["poisoned"] = True
            return ActionResult(
                False,
                "choice failed",
                damage_dealt=90,
                cards_drawn=[state.p1.deck[-1]],
                pokemon_ko=["p1_active"],
            )

        request = engine.choice_request(
            state,
            ActionRequest("confirm", 0, "confirm", callback=fail_after_mutation),
        )
        holder["request"] = request
        before = snapshot_state(state)

        result = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
        )

        self.assertFalse(result.success)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(state.event_stream._events[0].data["nested"]["value"], 1)
        self.assertEqual(result.action_result.cards_drawn, [])
        self.assertEqual(result.action_result.damage_dealt, 0)
        self.assertEqual(result.action_result.pokemon_ko, [])
        retry = engine.pending_choice_request(state)
        self.assertNotIn("poisoned", retry.metadata)

    def test_successful_choice_commits_rng_and_state(self):
        state = self._main_state()
        engine = GameEngine()
        rng = RandomSource(23)

        def commit_after_random(_choice):
            state.random_source.coin()
            state.p1.active.damage_counters += 1
            return ActionResult(True, "choice committed")

        request = engine.choice_request(
            state,
            ActionRequest(
                "confirm",
                0,
                "confirm",
                callback=commit_after_random,
            ),
        )
        before_rng = rng.getstate()
        before_damage = state.p1.active.damage_counters

        result = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("confirm:yes",)),
            rng,
        )

        self.assertTrue(result.success, result.message)
        self.assertNotEqual(rng.getstate(), before_rng)
        self.assertEqual(state.p1.active.damage_counters, before_damage + 1)

    def test_failed_action_after_vm_mutation_rolls_back_state_events_and_rng(self):
        state = self._main_state()
        state.p1.active.damage_counters = 0
        state.p1.bench[0].damage_counters = 0
        engine = GameEngine()
        rng = RandomSource(29)
        energy = CardRegistry.get("sv1-ener-5")
        partial_fail_item = Card(
            api_id="test-partial-action-rollback",
            name="Partial Action Rollback",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[],
            compiled_trainer_effects=[
                {
                    "op": "shuffle_then_draw_cards",
                    "args": {"draw": 1, "shuffle_hand": True},
                    "branches": {},
                },
                {
                    "op": "choose_heal_damage",
                    "args": {"amount": 30, "target_player": "self"},
                    "branches": {},
                },
            ],
        )
        state.p1.hand = [partial_fail_item, energy]
        state.p1.deck = [
            CardRegistry.get("sv1-ener-1"),
            CardRegistry.get("sv1-ener-2"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 1}))
        before = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)

        result = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            rng,
            auto_resolve=False,
        )

        self.assertFalse(result.success)
        self.assertIn("没有受伤的宝可梦", result.message)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_failed_attack_trigger_after_damage_rolls_back_public_action(self):
        state = self._main_state()
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p2.active.damage_counters = 0
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 2}))

        def malformed_after_damage(_data):
            return {
                "command_specs": [
                    {
                        "op": "trigger_place_damage_counters",
                        "args": {
                            "player": 0,
                            "slot": "active",
                            "count": 1,
                            "source": "test",
                        },
                        "branches": {},
                    },
                    {
                        "op": "__unknown_trigger__",
                        "args": {},
                        "branches": {},
                    },
                ],
            }

        state.event_bus.register(
            EventType.DAMAGE_DEALT,
            malformed_after_damage,
            source="malformed-after-damage",
            owner_player=0,
        )
        engine = GameEngine()
        rng = RandomSource(30)
        before = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)

        result = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            rng,
            auto_resolve=True,
        )

        self.assertFalse(result.success)
        self.assertIn("__unknown_trigger__", result.message)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_failed_attack_modifier_hook_rolls_back_public_action(self):
        state = self._main_state()
        state.p1.active.energy_cards = [
            CardRegistry.get("sv1-ener-3"),
            CardRegistry.get("sv1-ener-3"),
        ]
        state.p2.active.damage_counters = 0
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 6}))

        def broken_modifier(_data):
            raise RuntimeError("broken damage modifier")

        state.event_bus.register(
            EventType.DAMAGE_ABOUT_TO_BE_DEALT,
            broken_modifier,
            source="broken-damage-modifier",
            owner_player=0,
            priority=100,
        )
        engine = GameEngine()
        rng = RandomSource(34)
        before = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)

        result = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            rng,
            auto_resolve=True,
        )

        self.assertFalse(result.success)
        self.assertIn("broken-damage-modifier", result.message)
        self.assertIn("broken damage modifier", result.message)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_failed_choice_continuation_ko_hook_rolls_back_choice_transaction(self):
        state = self._main_state()
        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("sv2-delib"))
        state.p2.active.damage_counters = max(0, (state.p2.active.card.hp - 10) // 10)
        choice_damage_item = Card(
            api_id="test-choice-ko-rollback",
            name="Choice KO Rollback",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[],
            compiled_trainer_effects=[{
                "op": "choose_damage_target",
                "args": {"amount": 20, "player": "opponent"},
                "branches": {},
            }],
        )
        state.p1.hand = [choice_damage_item]
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 7}))
        engine = GameEngine()
        rng = RandomSource(35)

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            rng,
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)

        def broken_ko_hook(_data):
            raise RuntimeError("broken choice ko hook")

        state.event_bus.register(
            EventType.POKEMON_KO,
            broken_ko_hook,
            source="broken-choice-ko-hook",
            owner_player=0,
            priority=100,
        )
        before_choice = snapshot_state(state)
        before_stack = copy.deepcopy(state.resolution_stack)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)
        active_option = next(
            option
            for option in step.pending_choice.options
            if isinstance(option.ref, PokemonRef) and option.ref.slot == "active"
        )

        result = engine.apply_choice(
            state,
            step.pending_choice,
            ChoiceResponse(step.pending_choice.request_id, (active_option.option_id,)),
            rng,
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "ko_trigger_failed")
        self.assertIn("broken-choice-ko-hook", result.message)
        self.assertIn("broken choice ko hook", result.message)
        self.assertEqual(snapshot_state(state), before_choice)
        self.assertEqual(state.resolution_stack, before_stack)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_failed_non_attack_ko_trigger_rolls_back_public_action(self):
        state = self._main_state()
        state.p2.active.damage_counters = 4
        ko_item = Card(
            api_id="test-ko-trigger-rollback",
            name="KO Trigger Rollback",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[],
            compiled_trainer_effects=[{
                "op": "deal_damage",
                "args": {"amount": 20},
                "branches": {},
            }],
        )
        state.p1.hand = [ko_item]
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 4}))

        def malformed_ko_trigger(_data):
            return {
                "command_specs": [{
                    "op": "draw_cards",
                    "args": {"amount": 1},
                    "branches": {},
                }],
            }

        state.event_bus.register(
            EventType.POKEMON_KO,
            malformed_ko_trigger,
            source="malformed-ko-trigger",
            owner_player=0,
        )
        engine = GameEngine()
        rng = RandomSource(32)
        before = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)

        result = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            rng,
            auto_resolve=True,
        )

        self.assertFalse(result.success)
        self.assertEqual(result.error_code, "ko_trigger_failed")
        self.assertIn("registered trigger_* VM ops", result.message)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_failed_on_attach_trigger_rolls_back_public_action(self):
        state = self._main_state()
        energy = CardRegistry.get("sv1-ener-3")
        state.p1.hand = [energy]
        state.p1.active.energy_cards = []
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 5}))
        engine = GameEngine()
        rng = RandomSource(33)
        before = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = list(state.event_stream._events)

        with patch(
            "engine.commands.trigger_commands.collect_on_attach_command_specs",
            return_value=[{
                "op": "draw_cards",
                "args": {"amount": 1},
                "branches": {},
            }],
        ):
            result = engine.apply_action(
                state,
                GameAction(
                    PlayerAction.ATTACH_ENERGY,
                    {"hand_idx": 0, "target_slot": "active"},
                    actor=0,
                ),
                rng,
                auto_resolve=True,
            )

        self.assertFalse(result.success)
        self.assertIn("registered trigger_* VM ops", result.message)
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(list(state.event_stream._events), before_events)
        self.assertEqual(result.events, ())
        self.assertIsNone(result.pending_choice)

    def test_cancelled_trainer_choice_restores_action_checkpoint(self):
        state = self._main_state()
        engine = GameEngine()
        rng = RandomSource(31)
        caitlin = CardRegistry.get("svi-cait")
        energy = CardRegistry.get("sv1-ener-5")
        state.p1.hand = [caitlin, energy, CardRegistry.get("svi-chim")]
        state.p1.deck = [energy] * 4
        state.p1.discard = []
        state.action_log = ["preexisting log"]
        state.event_stream.push(GameEvent("preexisting", {"value": 1}))
        before = snapshot_state(state)
        before_rng = rng.getstate()
        before_log = list(state.action_log)
        before_events = [
            (event.event_type, event.data)
            for event in state.event_stream._events
        ]

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            rng,
            auto_resolve=False,
        )

        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        self.assertTrue(step.pending_choice.can_cancel)
        self.assertNotIn(caitlin, state.p1.hand)
        self.assertTrue(state.p1.supporter_played_this_turn)
        checkpoint = state.resolution_stack["context"].get("cancel_action_checkpoint")
        self.assertIsInstance(checkpoint, dict)
        json.dumps(checkpoint)
        self.assertEqual(
            [
                (event["event_type"], event["data"])
                for event in checkpoint.get("events", [])
            ],
            before_events,
        )

        result = engine.apply_choice(
            state,
            step.pending_choice,
            ChoiceResponse(step.pending_choice.request_id, (), cancelled=True),
            rng,
        )

        self.assertTrue(result.success, result.message)
        after = snapshot_state(state)
        self.assertEqual(replace(after, revision=before.revision), before)
        self.assertEqual(state.revision, before.revision + 2)
        self.assertEqual(rng.getstate(), before_rng)
        self.assertEqual(state.action_log, before_log)
        self.assertEqual(
            [
                (event.event_type, event.data)
                for event in state.event_stream._events
            ],
            before_events,
        )
        self.assertIsNone(state.resolution_stack["pending_request"])
        self.assertEqual(state.resolution_stack["frames"], [])
        self.assertNotIn(
            "cancel_action_checkpoint",
            state.resolution_stack.get("context", {}),
        )

    def test_double_turbo_energy_can_pay_two_unit_retreat(self):
        state = self._main_state()
        active = state.p1.active
        state.p1.active = PokemonInPlay(
            replace(active.card, api_id="test-two-retreat", retreat_cost=2),
            damage_counters=active.damage_counters,
        )
        double_turbo = CardRegistry.get("svi-dtur")
        self.assertIsNotNone(double_turbo)
        state.p1.active.energy_cards = [double_turbo]
        engine = GameEngine()
        retreat = next(
            action
            for action in engine.legal_actions(state, 0, validate_effects=False)
            if action.action == PlayerAction.RETREAT
        )
        self.assertEqual(retreat.params, {"bench_idx": 0})
        pending = engine.apply_action(state, retreat)
        self.assertTrue(pending.success, pending.message)
        self.assertIsNotNone(pending.pending_choice)
        self.assertEqual(pending.pending_choice.request_type, "select_retreat_payment")
        self.assertEqual(
            [option.option_id for option in pending.pending_choice.options],
            ["retreat:energy:0"],
        )
        result = engine.apply_choice(
            state,
            ChoiceResponse(
                pending.pending_choice.request_id,
                ("retreat:energy:0",),
            ),
        )
        self.assertTrue(result.success, result.message)
        self.assertIn(double_turbo, state.p1.discard)

    def test_passive_stadium_is_not_an_activatable_action(self):
        state = self._main_state()
        state.stadium_card = Card(
            api_id="test-passive-stadium",
            name="Passive Stadium",
            supertype="Trainer",
            subtypes=["Stadium"],
            trainer_effects=[
                EffectDef("stadium", {"stadium_type": "passive"})
            ],
        )
        actions = GameEngine().legal_actions(state, 0, validate_effects=False)
        self.assertFalse(any(action.action == PlayerAction.USE_STADIUM for action in actions))

    def test_legal_actions_use_compiled_trainer_effect_targets(self):
        state = self._main_state()
        compiled_switch_item = Card(
            api_id="test-compiled-catcher",
            name="Compiled Catcher",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[],
            compiled_trainer_effects=[{
                "op": "switch_pokemon",
                "args": {"target": "opponent"},
                "branches": {},
            }],
        )
        state.p1.hand = [compiled_switch_item]
        state.p2.bench = [None] * len(state.p2.bench)
        engine = GameEngine()

        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svi-skwv"))
        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertTrue(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

    def test_rules_runtime_rejects_raw_only_trainer_effects(self):
        state = self._main_state()
        raw_only_item = Card(
            api_id="test-raw-only-draw",
            name="Raw Only Draw",
            supertype="Trainer",
            subtypes=["Item"],
            trainer_effects=[EffectDef("draw", {"amount": 1})],
            compiled_trainer_effects=[],
        )
        state.p1.hand = [raw_only_item]
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        engine = GameEngine()
        from engine.effects.runtime_effects import strict_trainer_runtime_effects

        strict_effects = strict_trainer_runtime_effects(raw_only_item)
        self.assertEqual(strict_effects[0]["op"], "__missing_compiled_effect__")

        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertFalse(any(action.action == PlayerAction.PLAY_TRAINER for action in actions))

        before = snapshot_state(state)
        result = engine.apply_action(
            state,
            GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": 0}, actor=0),
            auto_resolve=False,
        )

        self.assertFalse(result.success)
        self.assertEqual(snapshot_state(state), before)

    def test_legal_actions_use_compiled_ability_effect_targets(self):
        state = self._main_state()
        ability = AbilityDef(
            name="Compiled Gust",
            text="",
            trigger="repeatable",
            effects=[],
            compiled_effects=[{
                "op": "switch_pokemon",
                "args": {"target": "opponent"},
                "branches": {},
            }],
        )
        state.p1.active.card = replace(
            state.p1.active.card,
            abilities=[ability],
        )
        state.p2.bench = [None] * len(state.p2.bench)
        engine = GameEngine()

        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertFalse(any(action.action == PlayerAction.USE_ABILITY for action in actions))

        state.p2.bench[0] = PokemonInPlay(CardRegistry.get("svi-skwv"))
        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertTrue(any(action.action == PlayerAction.USE_ABILITY for action in actions))

    def test_compiled_stadium_effects_can_be_activated(self):
        state = self._main_state()
        state.p1.hand = []
        state.p1.deck = [CardRegistry.get("sv1-ener-2")]
        state.stadium_card = Card(
            api_id="test-compiled-stadium",
            name="Compiled Stadium",
            supertype="Trainer",
            subtypes=["Stadium"],
            trainer_effects=[],
            compiled_trainer_effects=[{
                "op": "draw_cards",
                "args": {"amount": 1, "stadium_type": "activatable"},
                "branches": {},
            }],
        )
        engine = GameEngine()
        actions = engine.legal_actions(state, 0, validate_effects=False)
        self.assertTrue(any(action.action == PlayerAction.USE_STADIUM for action in actions))

        step = engine.apply_action(
            state,
            GameAction(PlayerAction.USE_STADIUM, {}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual([card.api_id for card in state.p1.hand], ["sv1-ener-2"])

    def test_evolution_preserves_energy_and_tool(self):
        riolu = CardRegistry.get("svf-rio")
        lucario = CardRegistry.get("svf-luca")
        energy = CardRegistry.get("sv1-ener-6")
        tool = CardRegistry.get("sv1-201")
        pokemon = PokemonInPlay(riolu)
        pokemon.energy_cards = [energy]
        pokemon.attached_tool = tool
        state = GameState()
        state.p1.active = pokemon
        state.p1.evolve_pokemon("active", lucario)
        self.assertEqual(state.p1.active.energy_cards, [energy])
        self.assertIs(state.p1.active.attached_tool, tool)

    def test_attack_is_atomic_through_checkup_and_turn_switch(self):
        attacker = CardRegistry.get("sv1-107")
        psychic = CardRegistry.get("sv1-ener-5")
        defender = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(attacker)
        state.p1.active.energy_cards = [psychic]
        state.p2.active = PokemonInPlay(defender)
        state.p1.deck = [psychic] * 4
        state.p2.deck = [psychic] * 4
        state.p1.prizes = [psychic] * 6
        state.p2.prizes = [psychic] * 6

        result = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            ScriptedRandomSource([True, True, False]),
            auto_resolve=True,
        )
        self.assertTrue(result.success, result.message)
        self.assertEqual(state.p2.active.damage_counters, 2)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_attack_choice_completion_also_switches_turn_atomically(self):
        attacker = CardRegistry.get("sv2-38")
        water = CardRegistry.get("sv1-ener-3")
        defender = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(attacker)
        state.p1.active.energy_cards = [water]
        state.p2.active = PokemonInPlay(defender)
        state.p1.deck = [water] * 4
        state.p2.deck = [water] * 4
        state.p1.prizes = [water] * 6
        state.p2.prizes = [water] * 6
        engine = GameEngine()

        attack_step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(attack_step.success, attack_step.message)
        self.assertIsNotNone(attack_step.pending_choice)
        self.assertEqual(state.phase, TurnPhase.ATTACK)

        result = engine.apply_choice(
            state,
            ChoiceResponse(attack_step.pending_choice.request_id, ()),
        )
        self.assertTrue(result.success, result.message)
        self.assertIsNone(result.pending_choice)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_attack_turn_finish_resolves_inside_attack_stack(self):
        attacker = CardRegistry.get("sv1-107")
        psychic = CardRegistry.get("sv1-ener-5")
        defender = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(attacker)
        state.p1.active.energy_cards = [psychic]
        state.p2.active = PokemonInPlay(defender)
        state.p1.deck = [psychic] * 4
        state.p2.deck = [psychic] * 4
        state.p1.prizes = [psychic] * 6
        state.p2.prizes = [psychic] * 6
        engine = GameEngine()
        self.assertFalse(hasattr(GameEngine, "_finish_attack_turn"))

        result = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            ScriptedRandomSource([True, True, False]),
            auto_resolve=True,
        )

        self.assertTrue(result.success, result.message)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_pending_attack_choice_finish_resolves_inside_attack_stack(self):
        attacker = CardRegistry.get("sv2-38")
        water = CardRegistry.get("sv1-ener-3")
        defender = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(attacker)
        state.p1.active.energy_cards = [water]
        state.p2.active = PokemonInPlay(defender)
        state.p1.deck = [water] * 4
        state.p2.deck = [water] * 4
        state.p1.prizes = [water] * 6
        state.p2.prizes = [water] * 6
        engine = GameEngine()
        self.assertFalse(hasattr(GameEngine, "_finish_attack_turn"))

        attack_step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(attack_step.success, attack_step.message)
        self.assertIsNotNone(attack_step.pending_choice)

        result = engine.apply_choice(
            state,
            ChoiceResponse(attack_step.pending_choice.request_id, ()),
        )

        self.assertTrue(result.success, result.message)
        self.assertIsNone(result.pending_choice)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_pending_attack_choice_is_serialized_in_resolution_stack(self):
        metal = CardRegistry.get("sv1-ener-8")
        psychic = CardRegistry.get("sv1-ener-5")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(CardRegistry.get("svm-cobalion"), placed_this_turn=False)
        state.p1.active.energy_cards = [metal, metal]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svm-zacian"), placed_this_turn=False)
        state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svm-zamazenta"), placed_this_turn=False)
        state.p1.deck = [metal, metal]
        state.p1.prizes = [psychic] * 6
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"), placed_this_turn=False)
        state.p2.deck = [psychic] * 4
        state.p2.prizes = [psychic] * 6
        engine = GameEngine()

        attack_step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )

        self.assertTrue(attack_step.success, attack_step.message)
        self.assertIsNotNone(attack_step.pending_choice)
        pending = state.resolution_stack["pending_request"]
        self.assertEqual(pending["request_id"], attack_step.pending_choice.request_id)
        self.assertEqual(pending["request_type"], "distribute_energy")
        self.assertEqual(pending["metadata"]["finish_attack_actor"], 0)
        frame_kinds = [frame["kind"] for frame in state.resolution_stack["frames"]]
        self.assertEqual(frame_kinds, ["finalize_attack", "continuation"])
        self.assertEqual(
            state.resolution_stack["frames"][1]["data"]["kind"],
            "energy_attach_distribution",
        )
        cloned = clone_state(state)
        self.assertEqual(cloned.resolution_stack, state.resolution_stack)

        bench_1 = next(
            option
            for option in attack_step.pending_choice.options
            if option.value.get("slot") == "bench_1"
        )
        result = engine.apply_choice(
            state,
            attack_step.pending_choice,
            ChoiceResponse(attack_step.pending_choice.request_id, (bench_1.option_id,)),
        )

        self.assertTrue(result.success, result.message)
        self.assertIsNone(result.pending_choice)
        self.assertIsNone(state.resolution_stack["pending_request"])
        self.assertEqual(state.resolution_stack["frames"], [])
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

    def test_cancelled_optional_attack_choice_continues_attack_stack(self):
        metal = CardRegistry.get("sv1-ener-8")
        psychic = CardRegistry.get("sv1-ener-5")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(CardRegistry.get("svm-cobalion"), placed_this_turn=False)
        state.p1.active.energy_cards = [metal, metal]
        state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svm-zacian"), placed_this_turn=False)
        state.p1.deck = [metal, metal]
        state.p1.prizes = [psychic] * 6
        state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"), placed_this_turn=False)
        state.p2.deck = [psychic] * 4
        state.p2.prizes = [psychic] * 6
        engine = GameEngine()

        attack_step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(attack_step.success, attack_step.message)
        self.assertIsNotNone(attack_step.pending_choice)
        self.assertTrue(attack_step.pending_choice.can_cancel)

        result = engine.apply_choice(
            state,
            attack_step.pending_choice,
            ChoiceResponse(attack_step.pending_choice.request_id, (), cancelled=True),
        )

        self.assertTrue(result.success, result.message)
        self.assertIsNone(result.pending_choice)
        self.assertIsNone(state.resolution_stack["pending_request"])
        self.assertEqual(state.resolution_stack["frames"], [])
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)
        self.assertEqual(len(state.p1.deck), 2)
        self.assertEqual(state.p1.bench[0].energy_cards, [])

    def test_attack_promotion_finish_marker_is_snapshot_backed(self):
        from engine.commands.attack_frames import FINISH_ATTACK_AFTER_PROMOTIONS_KEY

        tatsugiri = CardRegistry.get("sv2-tatsu")
        bench = CardRegistry.get("svi-chim")
        water = CardRegistry.get("sv1-ener-3")
        defender = CardRegistry.get("sv2-delib")
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.p1.active = PokemonInPlay(tatsugiri)
        state.p1.active.energy_cards = [water]
        state.p1.bench[0] = PokemonInPlay(bench)
        state.p2.active = PokemonInPlay(defender)
        state.p1.deck = [water] * 4
        state.p2.deck = [water]
        state.p1.prizes = [water] * 6
        state.p2.prizes = [water] * 6

        step = GameEngine().apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 1}, actor=0),
            auto_resolve=True,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(state.pending_promotions, [0])
        self.assertEqual(state.phase, TurnPhase.ATTACK)
        self.assertFalse(hasattr(state, "_finish_attack_after_promotions"))
        self.assertEqual(
            state.resolution_stack["context"][FINISH_ATTACK_AFTER_PROMOTIONS_KEY],
            0,
        )

        cloned = clone_state(state)
        self.assertEqual(
            cloned.resolution_stack["context"][FINISH_ATTACK_AFTER_PROMOTIONS_KEY],
            0,
        )
        promoted = GameEngine().apply_action(
            cloned,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
        )

        self.assertTrue(promoted.success, promoted.message)
        self.assertEqual(cloned.pending_promotions, [])
        self.assertEqual(cloned.active_player_idx, 1)
        self.assertEqual(cloned.phase, TurnPhase.MAIN)
        self.assertEqual(len(cloned.p2.hand), 1)
        self.assertNotIn(
            FINISH_ATTACK_AFTER_PROMOTIONS_KEY,
            cloned.resolution_stack["context"],
        )

    def test_attack_promotion_finish_marker_rejects_bool_actor(self):
        from engine.commands.attack_frames import (
            FINISH_ATTACK_AFTER_PROMOTIONS_KEY,
            finish_attack_after_promotions_actor,
        )

        state = self._main_state()
        state.resolution_stack["context"] = {
            FINISH_ATTACK_AFTER_PROMOTIONS_KEY: True,
        }

        self.assertIsNone(finish_attack_after_promotions_actor(state))

    def test_observation_and_registry_ignore_hidden_identity_swaps(self):
        state = self._main_state()
        state.public_deck_keys = ("fire", "water")
        first = Observation.from_state(state, 1)
        state.p1.hand = [CardRegistry.get("svi-ente")] * len(state.p1.hand)
        state.p1.deck = [CardRegistry.get("sv1-ener-2")] * len(state.p1.deck)
        state.p1.prizes = [CardRegistry.get("svi-chim")] * len(state.p1.prizes)
        second = Observation.from_state(state, 1)
        self.assertEqual(first, second)

        registry_ids = set(CardRegistry.all_cards())
        worlds = [
            fair_search_clone(state, 1, seed)
            for seed in (1, 2, 3)
        ]
        self.assertEqual(set(CardRegistry.all_cards()), registry_ids)
        hidden_worlds = {
            tuple(card.api_id for card in world.p1.hand + world.p1.deck + world.p1.prizes)
            for world in worlds
        }
        self.assertGreater(len(hidden_worlds), 1)

    def test_fair_search_clone_preserves_pending_stack_and_event_stream(self):
        state = self._main_state()
        state.public_deck_keys = ("fire", "water")
        state.resolution_stack = {
            "frames": [
                {"kind": "finalize_attack", "actor": 0},
                {
                    "kind": "continuation",
                    "operation": "choose_heal_damage",
                    "data": {"amount": 30},
                },
            ],
            "pending_request": {"request_id": "choice:ai:1"},
            "sequence": 12,
            "context": {"finish_attack_after_promotions": 0},
        }
        state.event_stream.push(GameEvent("preexisting", {"value": 3}))
        state.action_log = ["preexisting log"]

        cloned = fair_search_clone(state, 1, seed=22)

        self.assertEqual(cloned.resolution_stack, state.resolution_stack)
        self.assertEqual(
            [(event.event_type, event.data) for event in cloned.event_stream._events],
            [(event.event_type, event.data) for event in state.event_stream._events],
        )
        self.assertEqual(cloned.action_log, state.action_log)
        cloned.resolution_stack["context"]["finish_attack_after_promotions"] = 1
        cloned.event_stream._events[0].data["value"] = 99
        cloned.action_log.append("mutated")
        self.assertEqual(state.resolution_stack["context"]["finish_attack_after_promotions"], 0)
        self.assertEqual(state.event_stream._events[0].data["value"], 3)
        self.assertEqual(state.action_log, ["preexisting log"])

    def test_snapshot_manager_undo_redo_preserves_stack_and_event_stream(self):
        state = self._main_state()
        state.resolution_stack = {
            "frames": [{"kind": "finalize_attack", "actor": 0}],
            "pending_request": {
                "request_id": "choice:snapshot:1",
                "kind": "select_cards",
            },
            "sequence": 3,
            "context": {"checkpoint": {"rng": [1, 2, 3]}},
        }
        state.event_stream.push(
            GameEvent("preexisting", {"value": 1, "nested": {"counter": 1}})
        )
        undo_snapshot = snapshot_state(state)

        manager = SnapshotManager()
        manager.capture(state)

        state.resolution_stack = {
            "frames": [
                {"kind": "continuation", "operation": "choose_heal_damage"}
            ],
            "pending_request": {"request_id": "choice:snapshot:2"},
            "sequence": 4,
            "context": {"checkpoint": {"rng": [8, 9]}},
        }
        state.event_stream.push(
            GameEvent("redo_target", {"value": 2, "nested": {"counter": 2}})
        )
        redo_snapshot = snapshot_state(state)

        self.assertTrue(manager.undo(state))
        self.assertEqual(snapshot_state(state), undo_snapshot)

        state.resolution_stack["context"]["checkpoint"]["rng"][0] = 99
        state.event_stream._events[0].data["nested"]["counter"] = 99

        self.assertTrue(manager.redo(state))
        self.assertEqual(snapshot_state(state), redo_snapshot)

    def test_snapshot_manager_rebinds_modifiers_to_restored_pokemon(self):
        state = self._main_state()
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-ente"))
        manager = SnapshotManager()
        manager.capture(state)
        state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"))

        self.assertTrue(manager.undo(state))
        results = state.event_bus.emit(
            EventType.DAMAGE_ABOUT_TO_BE_DEALT,
            attacker=state.p2.active,
            defender=state.p1.active,
            ignore_defender_effects=False,
        )
        self.assertTrue(any(result.get("delta") == -20 for result in results))

        self.assertTrue(manager.redo(state))
        results = state.event_bus.emit(
            EventType.DAMAGE_ABOUT_TO_BE_DEALT,
            attacker=state.p2.active,
            defender=state.p1.active,
            ignore_defender_effects=False,
        )
        self.assertEqual(results, [])

    def test_anytime_planner_does_not_mutate_real_state(self):
        state = self._main_state()
        state.public_deck_keys = ("water", "fire")
        before = snapshot_state(state)
        registry_ids = set(CardRegistry.all_cards())
        backend = HeuristicBackend(
            priority=lambda _state, _actor, _action: 0.0,
            evaluator=lambda _state, _perspective: 0.0,
        )
        planner = AnytimePlanner(
            backend,
            PlannerConfig(
                thinking_time_seconds=0.2,
                simulation_budget=6,
                max_depth=4,
                random_seed=7,
            ),
        )
        legal = GameEngine().legal_actions(state, 0)
        selected = planner.search(state, 0, actions=legal)
        self.assertIn(selected.signature, {action.signature for action in legal})
        self.assertEqual(snapshot_state(state), before)
        self.assertEqual(set(CardRegistry.all_cards()), registry_ids)

    def test_planner_samples_coin_outcomes_from_each_root_perspective(self):
        class CoinEngine:
            @staticmethod
            def legal_actions(state, actor, **_kwargs):
                return (GameAction("COIN", actor=actor),)

            @staticmethod
            def apply_action(state, action, rng, **_kwargs):
                state.winner = action.actor if rng.coin() else 1 - action.actor
                return StepResult(True, winner=state.winner, terminal=True)

        backend = HeuristicBackend(
            priority=lambda _state, _actor, _action: 0.0,
            evaluator=lambda _state, _perspective: 0.0,
        )
        values = []
        for actor in (0, 1):
            state = self._main_state()
            state.active_player_idx = actor
            planner = AnytimePlanner(
                backend,
                PlannerConfig(
                    thinking_time_seconds=1.0,
                    simulation_budget=128,
                    max_depth=2,
                    random_seed=31,
                ),
                engine=CoinEngine(),
            )
            action = planner.search(
                state,
                actor,
                actions=[GameAction("COIN", actor=actor)],
            )
            values.append(planner.last_result.values[action.signature])
        for value in values:
            self.assertLess(abs(value), 0.3)
        self.assertAlmostEqual(values[0], values[1], places=7)

    def test_random_sources_support_scripted_and_sampled_coin_results(self):
        scripted = ScriptedRandomSource([True, False, True])
        self.assertEqual([scripted.coin() for _ in range(3)], [True, False, True])

        sampled = SamplingRandomSource(73)
        heads = sum(sampled.coin() for _ in range(2000))
        self.assertGreater(heads, 900)
        self.assertLess(heads, 1100)

        portable = PortableRandomSourceV1(20260620)
        self.assertEqual(
            [portable.next_u32() for _ in range(8)],
            [
                524962086,
                2612715569,
                807984655,
                1456231579,
                1471417396,
                275645069,
                3620116690,
                2672266556,
            ],
        )
        saved = portable.get_state()
        next_value = portable.next_u32()
        portable.set_state(saved)
        self.assertEqual(portable.next_u32(), next_value)

    def test_game_action_canonical_round_trip_preserves_stable_refs(self):
        action = GameAction(
            PlayerAction.ATTACH_ENERGY,
            {"hand_idx": 2, "target_slot": "bench_1"},
            actor=0,
            source=None,
            target=PokemonRef(0, "bench_1", "sv2-delib"),
        )
        restored = deserialize_game_action(serialize_game_action(action))
        self.assertEqual(restored.action, action.action)
        self.assertEqual(restored.params, action.params)
        self.assertEqual(restored.target, action.target)


if __name__ == "__main__":
    unittest.main()

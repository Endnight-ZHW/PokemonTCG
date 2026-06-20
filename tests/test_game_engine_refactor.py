import unittest
from dataclasses import replace

from data.card_models import Card, EffectDef
from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.actions import ChoiceResponse, GameAction, PokemonRef, StepResult
from engine.ai.observation import Observation, fair_search_clone
from engine.ai.planner import AnytimePlanner, HeuristicBackend, PlannerConfig
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import ActionRequest, GameState
from engine.player_state import PokemonInPlay
from engine.random_source import SamplingRandomSource, ScriptedRandomSource
from engine.snapshot import clone_state, snapshot_state
from network.state_serializer import deserialize_game_action, serialize_game_action


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
        self.assertEqual(retreat.params["energy_indices"], [0])
        result = engine.apply_action(state, retreat)
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
            attack_step.pending_choice,
            ChoiceResponse(
                attack_step.pending_choice.request_id,
                ("coin:heads",),
            ),
        )
        self.assertTrue(result.success, result.message)
        self.assertIsNone(result.pending_choice)
        self.assertEqual(state.active_player_idx, 1)
        self.assertEqual(state.phase, TurnPhase.MAIN)

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

    def test_game_action_network_round_trip_preserves_stable_refs(self):
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

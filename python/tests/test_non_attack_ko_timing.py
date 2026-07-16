"""Timing contracts for KO batches that do not come from attack damage."""
from __future__ import annotations

import copy
import unittest

from data.card_registry import CardRegistry
from data.deck_definitions import ALL_CARD_IDS
from engine.actions import ChoiceResponse, GameAction
from engine.commands.attack_frames import FinalizeAttackKoChecks
from engine.commands.modifier_registration import register_pokemon_modifiers
from engine.commands.resolution_stack import ResolutionStack
from engine.commands.trigger_commands import trigger_draw_cards_spec
from engine.enums import EventType, PlayerAction, StatusType, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.pending_continuation import PendingContinuationError
from engine.player_state import PokemonInPlay
from engine.random_source import ScriptedRandomSource
from engine.snapshot import clone_state, snapshot_state, state_from_snapshot


class NonAttackKnockoutTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CardRegistry.is_initialized():
            CardRegistry.initialize(ALL_CARD_IDS)

    @staticmethod
    def _card(card_id: str):
        return CardRegistry.get(card_id)

    def _base_state(self) -> GameState:
        state = GameState()
        state.phase = TurnPhase.MAIN
        state.turn_number = 3
        state.first_player_idx = 0
        state.active_player_idx = 0
        state.begin_turn_fact_window(0, 3)
        state.p1.deck = [self._card("sv1-ener-3")] * 3
        state.p2.deck = [self._card("sv1-ener-4")] * 3
        return state

    @staticmethod
    def _round_trip(engine: GameEngine, state: GameState):
        restored = state_from_snapshot(snapshot_state(state))
        request = engine.pending_choice_request(restored)
        return restored, request

    def test_confusion_self_ko_prize_pause_rolls_back_and_finishes_after_promotion(self):
        state = self._base_state()
        state.p1.active = PokemonInPlay(self._card("sv2-delib"))
        state.p1.active.damage_counters = 3
        state.p1.active.status_conditions.add(StatusType.CONFUSED)
        state.p1.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p2.active = PokemonInPlay(self._card("sv2-delib"))
        state.p2.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p1.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]
        state.p2.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]

        engine = GameEngine()
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            ScriptedRandomSource([False]),
            auto_resolve=False,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual(step.pending_choice.request_type, "select_prize")
        self.assertEqual(step.pending_choice.player, 1)
        self.assertIsNone(state.p1.active)
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv2-delib"])
        self.assertEqual(len(state.p2.prizes), 2)
        self.assertEqual(state.pending_promotions, [0])
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.ATTACK, 0, 3,
        ))
        resume = step.pending_choice.metadata["continuation"]["_resume"]
        self.assertTrue(resume["complete"])
        self.assertEqual(
            [frame["kind"] for frame in resume["frames"]],
            ["finalize_attack_turn", "finalize_knockout_batch"],
        )

        state, request = self._round_trip(engine, state)
        before_invalid = snapshot_state(state)
        invalid = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, ("prize:missing",)),
        )
        self.assertFalse(invalid.success)
        self.assertEqual(invalid.error_code, "invalid_choice")
        self.assertEqual(snapshot_state(state), before_invalid)

        request = engine.pending_choice_request(state)
        selected = request.options[1]
        prize = engine.apply_choice(
            state,
            request,
            ChoiceResponse(request.request_id, (selected.option_id,)),
        )
        self.assertTrue(prize.success, prize.message)
        self.assertEqual([card.api_id for card in state.p2.hand], ["sv1-ener-4"])
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.ATTACK, 0, 3,
        ))
        self.assertEqual(state.pending_promotions, [0])
        self.assertFalse(any("的回合 ——" in row for row in state.action_log))

        promoted = engine.apply_action(
            state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
        )
        self.assertTrue(promoted.success, promoted.message)
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.MAIN, 1, 4,
        ))
        self.assertEqual(state.pending_promotions, [])
        self.assertEqual(len(state.p2.hand), 2)  # selected prize, then turn draw
        promotion_idx = next(i for i, row in enumerate(state.action_log) if "提升至战斗区" in row)
        turn_idx = next(i for i, row in enumerate(state.action_log) if "的回合 ——" in row)
        draw_idx = next(i for i, row in enumerate(state.action_log) if "抽了1张卡" in row)
        self.assertLess(promotion_idx, turn_idx)
        self.assertLess(turn_idx, draw_idx)

    def test_failed_attack_checkup_choice_is_authoritative_and_auto_resolvable(self):
        state = self._base_state()
        state.p1.active = PokemonInPlay(self._card("sv2-delib"))
        state.p1.active.status_conditions.add(StatusType.CONFUSED)
        state.p2.active = PokemonInPlay(self._card("sv2-delib"))
        state.p2.active.damage_counters = 5
        state.p2.active.status_conditions.add(StatusType.POISONED)
        state.p2.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p1.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]
        state.p2.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]
        auto_state = clone_state(state)

        engine = GameEngine()
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            ScriptedRandomSource([False]),
            auto_resolve=False,
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual((step.pending_choice.request_type, step.pending_choice.player), (
            "select_prize", 0,
        ))
        self.assertIsNotNone(state.resolution_stack["pending_request"])
        authoritative = engine.pending_choice_request(state)
        self.assertEqual(authoritative.request_id, step.pending_choice.request_id)
        resolved = engine.apply_choice(
            state,
            authoritative,
            ChoiceResponse(authoritative.request_id, (authoritative.options[0].option_id,)),
        )
        self.assertTrue(resolved.success, resolved.message)
        self.assertIsNone(state.resolution_stack["pending_request"])
        self.assertEqual(state.pending_promotions, [1])

        auto = engine.apply_action(
            auto_state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            ScriptedRandomSource([False]),
            auto_resolve=True,
        )
        self.assertTrue(auto.success, auto.message)
        self.assertIsNone(auto.pending_choice)
        self.assertIsNone(auto_state.resolution_stack["pending_request"])
        self.assertEqual(len(auto_state.p1.prizes), 1)
        self.assertEqual(auto_state.pending_promotions, [1])

    def test_checkup_prize_snapshot_without_resume_fails_closed(self):
        state = self._base_state()
        state.p1.active = PokemonInPlay(self._card("sv2-delib"))
        state.p2.active = PokemonInPlay(self._card("sv2-delib"))
        state.p2.active.damage_counters = 5
        state.p2.active.status_conditions.add(StatusType.POISONED)
        state.p2.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p1.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]
        state.p2.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]

        engine = GameEngine()
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.END_TURN, {}, actor=0),
        )
        self.assertTrue(step.success, step.message)
        self.assertEqual(step.pending_choice.request_type, "select_prize")

        damaged = state_from_snapshot(snapshot_state(state))
        continuation = damaged.resolution_stack["pending_request"]["metadata"]["continuation"]
        continuation.pop("_resume", None)
        # Cross a second snapshot boundary to prove no ephemeral callback can
        # conceal the damaged authoritative payload.
        damaged = state_from_snapshot(snapshot_state(damaged))
        before = snapshot_state(damaged)
        with self.assertRaises(PendingContinuationError) as caught:
            engine.pending_choice_request(damaged)
        self.assertEqual(caught.exception.error_code, "unsupported_continuation_state")
        self.assertEqual(snapshot_state(damaged), before)

    def test_promotion_resumed_attack_persists_late_checkup_choice(self):
        state = self._base_state()
        state.p1.active = PokemonInPlay(self._card("sv2-delib"))
        state.p1.active.damage_counters = 3
        state.p1.active.status_conditions.add(StatusType.CONFUSED)
        state.p1.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p2.active = PokemonInPlay(self._card("sv2-delib"))
        state.p2.active.damage_counters = 5
        state.p2.active.status_conditions.add(StatusType.POISONED)
        state.p2.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p1.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]
        state.p2.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]

        engine = GameEngine()
        attack = engine.apply_action(
            state,
            GameAction(PlayerAction.DECLARE_ATTACK, {"attack_idx": 0}, actor=0),
            ScriptedRandomSource([False]),
        )
        self.assertTrue(attack.success, attack.message)
        first_prize = engine.apply_choice(
            state,
            attack.pending_choice,
            ChoiceResponse(
                attack.pending_choice.request_id,
                (attack.pending_choice.options[0].option_id,),
            ),
        )
        self.assertTrue(first_prize.success, first_prize.message)
        self.assertEqual(state.pending_promotions, [0])
        auto_state = clone_state(state)

        promotion = engine.apply_action(
            state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
            auto_resolve=False,
        )
        self.assertTrue(promotion.success, promotion.message)
        self.assertEqual((promotion.pending_choice.request_type, promotion.pending_choice.player), (
            "select_prize", 0,
        ))
        self.assertIsNotNone(state.resolution_stack["pending_request"])
        authoritative = engine.pending_choice_request(state)
        resolved = engine.apply_choice(
            state,
            authoritative,
            ChoiceResponse(authoritative.request_id, (authoritative.options[0].option_id,)),
        )
        self.assertTrue(resolved.success, resolved.message)
        self.assertIsNone(state.resolution_stack["pending_request"])
        self.assertEqual(state.pending_promotions, [1])

        auto = engine.apply_action(
            auto_state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
            auto_resolve=True,
        )
        self.assertTrue(auto.success, auto.message)
        self.assertIsNone(auto.pending_choice)
        self.assertIsNone(auto_state.resolution_stack["pending_request"])
        self.assertEqual(len(auto_state.p1.prizes), 1)
        self.assertEqual(auto_state.pending_promotions, [1])

    def test_mystical_comet_target_and_prize_each_survive_snapshot(self):
        state = self._base_state()
        state.p1.active = PokemonInPlay(self._card("sv2-starm"))
        state.p1.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p2.active = PokemonInPlay(self._card("sv2-delib"))
        state.p2.active.damage_counters = 4
        state.p2.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p1.prizes = [self._card("sv1-ener-3")]
        state.p2.prizes = [self._card("sv1-ener-3"), self._card("sv1-ener-4")]

        engine = GameEngine()
        step = engine.apply_action(
            state,
            GameAction(
                PlayerAction.USE_ABILITY,
                {"slot": "active", "ability_name": "神秘彗星"},
                actor=0,
            ),
        )
        self.assertTrue(step.success, step.message)
        self.assertIsNotNone(step.pending_choice)
        self.assertIsNotNone(state.p1.active)  # cost/effect waits for a target

        state, target_request = self._round_trip(engine, state)
        active_target = next(
            option for option in target_request.options
            if getattr(option.ref, "slot", "") == "active"
        )
        target_step = engine.apply_choice(
            state,
            target_request,
            ChoiceResponse(target_request.request_id, (active_target.option_id,)),
        )
        self.assertTrue(target_step.success, target_step.message)
        self.assertEqual(target_step.pending_choice.request_type, "select_prize")
        self.assertIsNone(state.p1.active)
        self.assertIsNone(state.p2.active)
        self.assertEqual([card.api_id for card in state.p1.discard], ["sv2-starm"])
        self.assertEqual([card.api_id for card in state.p2.discard], ["sv2-delib"])
        self.assertEqual(len(state.p1.prizes), 1)
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.MAIN, 0, 3,
        ))

        state, prize_request = self._round_trip(engine, state)
        prize_step = engine.apply_choice(
            state,
            prize_request,
            ChoiceResponse(prize_request.request_id, (prize_request.options[0].option_id,)),
        )
        self.assertTrue(prize_step.success, prize_step.message)
        self.assertTrue(prize_step.terminal)
        self.assertEqual((state.result_status, state.winner), ("WIN", 0))
        self.assertEqual(state.phase, TurnPhase.GAME_OVER)
        self.assertEqual(state.pending_promotions, [])
        counter_idx = next(i for i, row in enumerate(state.action_log) if "伤害指示物" in row)
        source_idx = next(i for i, row in enumerate(state.action_log) if "放置于弃牌区" in row)
        ko_idx = next(i for i, row in enumerate(state.action_log) if "被击倒" in row)
        prize_idx = next(i for i, row in enumerate(state.action_log) if "获得了奖赏卡" in row)
        self.assertLess(counter_idx, source_idx)
        self.assertLess(source_idx, ko_idx)
        self.assertLess(ko_idx, prize_idx)

    def test_checkup_double_ko_treasure_prizes_promotions_then_turn_draw(self):
        state = self._base_state()
        for player in (state.p1, state.p2):
            player.active = PokemonInPlay(self._card("sv2-delib"))
            player.active.damage_counters = 5
            player.active.status_conditions.add(StatusType.POISONED)
            player.bench[0] = PokemonInPlay(self._card("svi-chim"))
        state.p1.prizes = [self._card("sv1-ener-4"), self._card("sv1-ener-3")]
        state.p2.prizes = [self._card("svi-trea"), self._card("sv1-ener-3")]

        engine = GameEngine()
        step = engine.apply_action(
            state,
            GameAction(PlayerAction.END_TURN, {}, actor=0),
        )

        self.assertTrue(step.success, step.message)
        self.assertEqual((step.pending_choice.request_type, step.pending_choice.player), (
            "select_prize", 1,
        ))
        self.assertIsNone(state.p1.active)
        self.assertIsNone(state.p2.active)
        self.assertEqual(state.pending_promotions, [1, 0])
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.POKEMON_CHECKUP, 0, 3,
        ))
        self.assertEqual(len(state.turn_fact_book["current"]["knockouts"]), 2)
        paused_facts = copy.deepcopy(state.turn_fact_book)
        resume = step.pending_choice.metadata["continuation"]["_resume"]
        self.assertTrue(resume["complete"])
        self.assertIn("finalize_checkup_turn", [frame["kind"] for frame in resume["frames"]])
        self.assertFalse(any("的回合 ——" in row or "抽了1张卡" in row for row in state.action_log))

        state, first_prize = self._round_trip(engine, state)
        treasure = next(option for option in first_prize.options if option.option_id == "prize:0")
        treasure_step = engine.apply_choice(
            state,
            first_prize,
            ChoiceResponse(first_prize.request_id, (treasure.option_id,)),
        )
        self.assertTrue(treasure_step.success, treasure_step.message)
        self.assertEqual(treasure_step.pending_choice.request_type, "select_prize_energy_target")
        self.assertEqual([card.api_id for card in state.p2.prizes], [
            "svi-trea", "sv1-ener-3",
        ])
        self.assertEqual(state.turn_fact_book, paused_facts)

        state, energy_target = self._round_trip(engine, state)
        bench_target = next(
            option for option in energy_target.options
            if getattr(option.ref, "slot", "") == "bench_0"
        )
        target_step = engine.apply_choice(
            state,
            energy_target,
            ChoiceResponse(energy_target.request_id, (bench_target.option_id,)),
        )
        self.assertTrue(target_step.success, target_step.message)
        self.assertEqual((target_step.pending_choice.request_type, target_step.pending_choice.player), (
            "select_prize", 0,
        ))
        self.assertEqual([card.api_id for card in state.p2.prizes], ["sv1-ener-3"])
        self.assertEqual([card.api_id for card in state.p2.bench[0].energy_cards], ["svi-trea"])
        self.assertEqual(state.turn_fact_book, paused_facts)

        state, second_prize = self._round_trip(engine, state)
        second_step = engine.apply_choice(
            state,
            second_prize,
            ChoiceResponse(second_prize.request_id, (second_prize.options[-1].option_id,)),
        )
        self.assertTrue(second_step.success, second_step.message)
        self.assertIsNone(second_step.pending_choice)
        self.assertEqual(state.pending_promotions, [1, 0])
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.POKEMON_CHECKUP, 0, 3,
        ))
        self.assertEqual(state.turn_fact_book, paused_facts)
        self.assertFalse(any("的回合 ——" in row or "抽了1张卡" in row for row in state.action_log))

        state = state_from_snapshot(snapshot_state(state))
        first_promotion = engine.apply_action(
            state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=1),
        )
        self.assertTrue(first_promotion.success, first_promotion.message)
        self.assertEqual(state.pending_promotions, [0])
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.POKEMON_CHECKUP, 0, 3,
        ))

        state = state_from_snapshot(snapshot_state(state))
        final_promotion = engine.apply_action(
            state,
            GameAction("PROMOTE", {"bench_idx": 0}, actor=0),
        )
        self.assertTrue(final_promotion.success, final_promotion.message)
        self.assertEqual((state.phase, state.active_player_idx, state.turn_number), (
            TurnPhase.MAIN, 1, 4,
        ))
        self.assertEqual(state.pending_promotions, [])
        self.assertEqual(state.turn_fact_book["current"]["turn_number"], 4)
        self.assertEqual(state.turn_fact_book["current"]["turn_player"], 1)
        self.assertEqual(len(state.turn_fact_book["previous"]["knockouts"]), 2)
        promotion_rows = [
            i for i, row in enumerate(state.action_log) if "提升至战斗区" in row
        ]
        turn_idx = next(i for i, row in enumerate(state.action_log) if "的回合 ——" in row)
        draw_idx = next(i for i, row in enumerate(state.action_log) if "抽了1张卡" in row)
        self.assertEqual(len(promotion_rows), 2)
        self.assertLess(max(promotion_rows), turn_idx)
        self.assertLess(turn_idx, draw_idx)

    def test_attack_simultaneous_ko_groups_exp_share_by_current_player(self):
        for turn_owner in (0, 1):
            with self.subTest(turn_owner=turn_owner):
                state = self._base_state()
                state.phase = TurnPhase.ATTACK
                state.active_player_idx = turn_owner
                basic = self._card("svi-chim")
                tool = self._card("svg2-exps")
                energies = [self._card("sv1-ener-1"), self._card("sv1-ener-2")]
                for owner in (0, 1):
                    player = state.get_player(owner)
                    player.active = PokemonInPlay(basic)
                    player.active.damage_counters = 99
                    player.active.pending_ko_cause = "attack_damage"
                    player.active.energy_cards = list(energies)
                    player.prizes = [basic] * 6
                    for bench_idx in (0, 1):
                        player.bench[bench_idx] = PokemonInPlay(basic)
                        player.bench[bench_idx].attached_tool = tool
                        register_pokemon_modifiers(
                            player.bench[bench_idx],
                            owner,
                            f"bench_{bench_idx}",
                            event_bus=state.event_bus,
                        )

                stack = ResolutionStack(state)
                stack.push(FinalizeAttackKoChecks())
                result = stack.resolve_all(turn_owner, "active")
                engine = GameEngine()
                request = engine.choice_manager.choice_request(state, result.pending_choice)
                engine.transaction_manager.persist_pending_choice(state, request)
                state, request = self._round_trip(engine, state)

                self.assertEqual(request.request_type, "choose_trigger_order")
                self.assertEqual(request.player, turn_owner)
                self.assertEqual(
                    {
                        int(spec["args"]["to_player"])
                        for spec in request.metadata["continuation"]["specs"]
                    },
                    {turn_owner},
                )
                first = engine.apply_choice(
                    state,
                    request,
                    ChoiceResponse(request.request_id, (request.options[0].option_id,)),
                )
                self.assertEqual((first.pending_choice.request_type, first.pending_choice.player), (
                    "confirm_trigger", turn_owner,
                ))
                first_decline = engine.apply_choice(
                    state,
                    first.pending_choice,
                    ChoiceResponse(first.pending_choice.request_id, ("confirm:no",)),
                )
                self.assertEqual(
                    (first_decline.pending_choice.request_type, first_decline.pending_choice.player),
                    ("confirm_trigger", turn_owner),
                )
                second_decline = engine.apply_choice(
                    state,
                    first_decline.pending_choice,
                    ChoiceResponse(first_decline.pending_choice.request_id, ("confirm:no",)),
                )
                self.assertEqual(
                    (second_decline.pending_choice.request_type, second_decline.pending_choice.player),
                    ("choose_trigger_order", 1 - turn_owner),
                )
                self.assertEqual(
                    {
                        int(spec["args"]["to_player"])
                        for spec in second_decline.pending_choice.metadata["continuation"]["specs"]
                    },
                    {1 - turn_owner},
                )

    def test_checkup_simultaneous_ko_groups_triggers_by_incoming_player(self):
        for outgoing in (0, 1):
            with self.subTest(outgoing=outgoing):
                state = self._base_state()
                state.phase = TurnPhase.POKEMON_CHECKUP
                state.active_player_idx = outgoing
                basic = self._card("svi-chim")
                for owner in (0, 1):
                    player = state.get_player(owner)
                    player.active = PokemonInPlay(basic)
                    player.active.damage_counters = 99
                    player.active.pending_ko_cause = "special_condition"
                    player.bench[0] = PokemonInPlay(basic)
                    player.prizes = [basic] * 6
                    player.deck = [self._card("sv1-ener-3")] * 4
                    for ordinal in (0, 1):
                        def hook(data, *, owner=owner, ordinal=ordinal):
                            if int(data.get("player_idx", -1)) != owner:
                                return None
                            return {
                                "command_specs": [trigger_draw_cards_spec(
                                    owner,
                                    1,
                                    f"P{owner}-trigger-{ordinal}",
                                )],
                            }

                        state.event_bus.register(
                            EventType.POKEMON_KO,
                            hook,
                            source=f"test:checkup:{owner}:{ordinal}",
                            owner_player=owner,
                            priority=20 - ordinal,
                        )

                stack = ResolutionStack(state)
                stack.push(FinalizeAttackKoChecks())
                result = stack.resolve_all(outgoing, "active")
                engine = GameEngine()
                request = engine.choice_manager.choice_request(state, result.pending_choice)
                engine.transaction_manager.persist_pending_choice(state, request)
                state, request = self._round_trip(engine, state)
                incoming = 1 - outgoing

                self.assertEqual((request.request_type, request.player), (
                    "choose_trigger_order", incoming,
                ))
                self.assertEqual(
                    {int(spec["args"]["player"]) for spec in request.metadata["continuation"]["specs"]},
                    {incoming},
                )
                first_group = engine.apply_choice(
                    state,
                    request,
                    ChoiceResponse(request.request_id, (request.options[0].option_id,)),
                )
                self.assertTrue(first_group.success, first_group.message)
                self.assertEqual(
                    (first_group.pending_choice.request_type, first_group.pending_choice.player),
                    ("choose_trigger_order", outgoing),
                )
                self.assertEqual(len(state.get_player(incoming).hand), 2)
                self.assertEqual(len(state.get_player(outgoing).hand), 0)


if __name__ == "__main__":
    unittest.main()

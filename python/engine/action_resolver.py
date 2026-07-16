"""Action resolver - executes game actions and mutates GameState."""
import copy
import random
from engine.rules_constants import COIN_FLIP_THRESHOLD
from engine.enums import TurnPhase, StatusType, PlayerAction
from engine.game_state import GameState, ActionResult
from engine.events.game_events import GameEvent
from engine.rules_validator import (
    can_play_basic, can_evolve, can_attach_energy, can_play_supporter,
    can_play_item, can_play_stadium, can_play_tool, can_retreat,
    can_declare_attack, can_use_ability
)
from engine.commands.modifier_registration import (
    register_pokemon_modifiers,
    unregister_pokemon_modifiers,
)
from engine.effects.availability import (
    effect_params,
    effects_cost_is_payable,
    effects_have_legal_target,
)
from engine.effects.runtime_effects import (
    strict_ability_runtime_effects as ability_runtime_effects,
    strict_attack_runtime_effects as attack_runtime_effects,
    strict_trainer_runtime_effects as trainer_runtime_effects,
)
from data.card_models import Card
from engine.commands.attack_frames import clear_attack_damage_context
from engine.commands.dsl_compiler import compile_command_spec
from engine.commands.registry import build_command
from engine.effect_runner import (
    FULL_DAMAGE_EFFECT_TYPES,
    FULL_DAMAGE_VM_OPS,
    VMEffectRunner,
    attack_effects_replace_base_damage as _attack_effects_replace_base_damage,
    build_runtime_command as _build_runtime_command,
    command_result_to_action_result,
    effect_args as _effect_args,
    effect_op as _effect_op,
    effect_replaces_base_damage as _effect_replaces_base_damage,
    effect_type as _effect_type,
    merge_action_results,
)


def _cr_to_ar(cr) -> ActionResult:
    """Convert CommandResult to ActionResult (legacy compatibility)."""
    return command_result_to_action_result(cr)


class ActionResolver:
    """Handles execution of all game actions."""

    def __init__(self, state: GameState):
        self.state = state

    def _effect_runner(self) -> VMEffectRunner:
        return VMEffectRunner(
            self.state,
            compile_command_spec=compile_command_spec,
            build_command=build_command,
        )

    def resolve(
        self,
        action: PlayerAction,
        *,
        finish_attack_in_stack: bool = False,
        **params,
    ) -> ActionResult:
        action_map = {
            PlayerAction.PLAY_BASIC: self._play_basic,
            PlayerAction.EVOLVE: self._evolve,
            PlayerAction.ATTACH_ENERGY: self._attach_energy,
            PlayerAction.PLAY_TRAINER: self._play_trainer,
            PlayerAction.USE_ABILITY: self._use_ability,
            PlayerAction.USE_STADIUM: self._use_stadium,
            PlayerAction.RETREAT: self._retreat,
            PlayerAction.DECLARE_ATTACK: self._declare_attack,
            PlayerAction.END_TURN: self._end_turn,
        }
        handler = action_map.get(action)
        if handler is None:
            return ActionResult(False, f"未知动作: {action}")
        if action == PlayerAction.DECLARE_ATTACK:
            params["finish_attack_in_stack"] = finish_attack_in_stack
        return handler(**params)

    def _use_stadium(self, player_idx: int) -> ActionResult:
        """Activate the current stadium's activatable effect (once per turn per player)."""
        if self.state.stadium_card is None:
            return ActionResult(False, "场上没有竞技场卡。")
        if self.state.phase != TurnPhase.MAIN:
            return ActionResult(False, "只能在主要阶段使用竞技场效果。")

        player = self.state.get_player(player_idx)

        # Check per-turn limit
        if player.stadium_used_this_turn:
            return ActionResult(False, "本回合已使用过竞技场效果。")

        # Check stadium type — only activatable stadiums can be triggered
        stadium = self.state.stadium_card
        stadium_type = "passive"
        for effect in trainer_runtime_effects(stadium):
            if effect_params(effect).get("stadium_type") == "activatable":
                stadium_type = "activatable"
                break

        if stadium_type != "activatable":
            return ActionResult(False, f"「{stadium.name}」的效果是持续生效的，无需手动发动。")

        msg = f"{player.name}使用了竞技场「{stadium.name}」的效果。"
        self.state._log(msg)

        result = ActionResult(True, msg)
        stadium_effects = trainer_runtime_effects(stadium)
        if stadium_effects:
            eff_result = self._execute_effects(
                stadium_effects, player_idx, "active"
            )
            merge_action_results(result, eff_result)

        if result.success:
            player.stadium_used_this_turn = True
        return result

    def use_stadium(self, player_idx: int) -> ActionResult:
        """Public shortcut for USE_STADIUM action."""
        return self._use_stadium(player_idx=player_idx)

    # ---- Individual Action Handlers ----

    def _play_basic(self, player_idx: int, hand_idx: int,
                    target: str) -> ActionResult:
        player = self.state.get_player(player_idx)
        if not (0 <= hand_idx < len(player.hand)):
            return ActionResult(False, "无效的手牌序号。")
        card = player.hand[hand_idx]

        ok, reason = can_play_basic(self.state, player_idx, card, target)
        if not ok:
            return ActionResult(False, reason)

        player.hand.pop(hand_idx)

        if (
            self.state.phase == TurnPhase.SETUP
            and getattr(self.state, "setup_stage", "") == "BONUS_PLACEMENT"
        ):
            eligible = self.state.setup_bonus_card_ids[player_idx]
            card_id = str(getattr(card, "api_id", "") or "")
            # Validation above proves one matching bonus-drawn entity exists.
            # Remove exactly one occurrence so duplicate IDs remain usable.
            eligible.remove(card_id)

        if target == "active":
            pokemon = player.place_active(card)
        else:
            bench_idx = int(target.split("_")[1])
            pokemon = player.place_bench(card, bench_idx)

        pokemon.placed_this_turn = True

        # Register event-driven modifiers for this Pokemon
        register_pokemon_modifiers(pokemon, player_idx, target,
                                   event_bus=self.state.event_bus)

        slot_cn = "战斗区" if target == "active" else f"备战区{target.split('_')[1]}"
        msg = f"{player.name}将{card.name}放置于{slot_cn}。"
        self.state._log(msg)

        result = ActionResult(True, msg)
        for ability in card.abilities:
            if ability.trigger == "on_enter_play":
                ability_effects = ability_runtime_effects(ability)
                ab_results = self._execute_effects(
                    ability_effects, player_idx, target
                )
                result.log_message += f" | 特性: {ability.name}"
                merge_action_results(result, ab_results)

        return result

    def _evolve(self, player_idx: int, hand_idx: int, slot: str) -> ActionResult:
        player = self.state.get_player(player_idx)
        if not (0 <= hand_idx < len(player.hand)):
            return ActionResult(False, "无效的手牌序号。")
        card = player.hand[hand_idx]

        ok, reason = can_evolve(self.state, player_idx, slot, card)
        if not ok:
            return ActionResult(False, reason)

        player.hand.pop(hand_idx)
        old_card = player.evolve_pokemon(slot, card)

        # Re-register modifiers after evolution (new abilities, tools carry over)
        pokemon = player.get_pokemon(slot)
        if pokemon:
            unregister_pokemon_modifiers(old_card.api_id, slot,
                                          event_bus=self.state.event_bus,
                                          player_idx=player_idx)
            register_pokemon_modifiers(pokemon, player_idx, slot,
                                       event_bus=self.state.event_bus)

        msg = f"{player.name}将{old_card.name}进化成了{card.name}！"
        self.state._log(msg)

        result = ActionResult(True, msg)
        for ability in card.abilities:
            if ability.trigger == "on_enter_play":
                ability_effects = ability_runtime_effects(ability)
                ab_results = self._execute_effects(
                    ability_effects, player_idx, slot
                )
                result.log_message += f" | 特性: {ability.name}"
                merge_action_results(result, ab_results)

        return result

    def _attach_energy(self, player_idx: int, hand_idx: int,
                       target_slot: str) -> ActionResult:
        player = self.state.get_player(player_idx)
        if not (0 <= hand_idx < len(player.hand)):
            return ActionResult(False, "无效的手牌序号。")
        card = player.hand[hand_idx]

        ok, reason = can_attach_energy(self.state, player_idx, card, target_slot)
        if not ok:
            return ActionResult(False, reason)

        player.attach_energy_from_hand(hand_idx, target_slot)
        target = player.get_pokemon(target_slot)
        if target:
            unregister_pokemon_modifiers(target.card.api_id, target_slot,
                                         event_bus=self.state.event_bus,
                                         player_idx=player_idx)
            register_pokemon_modifiers(target, player_idx, target_slot,
                                       event_bus=self.state.event_bus)

        slot_cn = "战斗宝可梦" if target_slot == "active" else f"备战区{target_slot.split('_')[1]}"
        msg = f"{player.name}将{card.name}附着于{slot_cn}。"
        self.state._log(msg)

        from engine.commands.trigger_commands import (
            collect_on_attach_command_specs,
            execute_trigger_commands,
        )

        trigger_specs = collect_on_attach_command_specs(
            card,
            player_idx,
            target_slot,
            "hand",
        )
        if trigger_specs:
            trigger_result = execute_trigger_commands(
                self.state,
                trigger_specs,
                player_idx=player_idx,
                source_slot=target_slot,
            )
            if trigger_result.log_message:
                msg += " " + trigger_result.log_message
            if not trigger_result.success:
                return ActionResult(False, msg)

        return ActionResult(True, msg)

    def _play_trainer(self, player_idx: int, hand_idx: int,
                      **params) -> ActionResult:
        player = self.state.get_player(player_idx)
        if not (0 <= hand_idx < len(player.hand)):
            return ActionResult(False, "无效的手牌序号。")
        card = player.hand[hand_idx]

        if not card.is_trainer:
            return ActionResult(False, f"{card.name}不是训练家卡。")

        if card.is_trainer_supporter:
            ok, reason = can_play_supporter(self.state, player_idx)
            if not ok:
                return ActionResult(False, reason)
        elif card.is_trainer_item:
            ok, reason = can_play_item(self.state, player_idx)
            if not ok:
                return ActionResult(False, reason)
        elif card.is_trainer_stadium:
            ok, reason = can_play_stadium(self.state, player_idx, card)
            if not ok:
                return ActionResult(False, reason)
        elif card.is_trainer_tool:
            target_slot = params.get("target_slot", "active")
            ok, reason = can_play_tool(self.state, player_idx, target_slot)
            if not ok:
                return ActionResult(False, reason)

        trainer_effects = trainer_runtime_effects(card)
        if trainer_effects:
            if not effects_cost_is_payable(
                self.state,
                player_idx,
                trainer_effects,
                exclude_hand_index=hand_idx,
            ):
                return ActionResult(False, "无法支付代价。")
            if not effects_have_legal_target(
                self.state,
                player_idx,
                trainer_effects,
                source_slot=params.get("target_slot", "active"),
                exclude_hand_index=hand_idx,
            ):
                return ActionResult(False, "没有合法目标，不能使用。")

        # Pop card from hand BEFORE executing effects,
        # so discard-cost card_list doesn't include this card.
        # If effects fail, put the card back.
        player.hand.pop(hand_idx)

        # Log usage first, then execute effects (effect details appear after)
        msg = f"{player.name}使用了{card.name}。"
        self.state._log(msg)

        result = ActionResult(True, msg)
        if trainer_effects:
            effect_result = self._execute_effects(
                trainer_effects, player_idx, "active"
            )
            if not effect_result.success:
                # Effect failed — return card to hand
                player.hand.insert(hand_idx, card)
                return effect_result
            result = effect_result

        if card.is_trainer_tool:
            target_slot = params.get("target_slot", "active")
            target = player.get_pokemon(target_slot)
            if target:
                target.attached_tool = card
                unregister_pokemon_modifiers(target.card.api_id, target_slot,
                                             event_bus=self.state.event_bus,
                                             player_idx=player_idx)
                register_pokemon_modifiers(target, player_idx, target_slot,
                                           event_bus=self.state.event_bus)

        if card.is_trainer_stadium:
            if self.state.stadium_card:
                previous_owner = getattr(self.state, "stadium_owner_idx", -1)
                if previous_owner not in (0, 1):
                    previous_owner = player_idx
                self.state.get_player(previous_owner).discard.append(self.state.stadium_card)
            self.state.stadium_card = card
            self.state.stadium_owner_idx = player_idx
            player.stadium_played_this_turn = True

        # The card moves to discard as part of PLAY_TRAINER itself, before a
        # follow-up selection is resolved.  A cancellable request still keeps
        # the action checkpoint, so cancelling restores the entire pre-action
        # state instead of exposing a different paused state than Godot.
        if card.is_trainer_supporter:
            player.supporter_played_this_turn = True
            player.discard.append(card)
        elif card.is_trainer_item:
            player.discard.append(card)

        return result

    def _use_ability(self, player_idx: int, slot: str,
                     ability_name: str, **params) -> ActionResult:
        if slot == "discard":
            return self._use_discard_ability(player_idx, ability_name, **params)
        ok, reason = can_use_ability(
            self.state, player_idx, slot, ability_name
        )
        if not ok:
            return ActionResult(False, reason)

        player = self.state.get_player(player_idx)
        pokemon = player.get_pokemon(slot)

        for ability in pokemon.card.abilities:
            if ability.name.lower() == ability_name.lower():
                ability_effects = ability_runtime_effects(ability)
                if ability_effects and not effects_have_legal_target(
                    self.state,
                    player_idx,
                    ability_effects,
                    source_slot=slot,
                ):
                    return ActionResult(False, "没有合法目标，不能使用该特性。")
                msg = f"{player.name}使用了{pokemon.card.name}的特性{ability.name}。"
                self.state._log(msg)
                result = self._execute_effects(ability_effects, player_idx, slot)
                if result.success and ability.trigger != "repeatable":
                    pokemon.used_abilities.add(ability.name)
                return result

        return ActionResult(False, f"未找到特性'{ability_name}'。")

    def _use_discard_ability(
        self,
        player_idx: int,
        ability_name: str,
        discard_idx: int = -1,
        card_id: str = "",
        **_params,
    ) -> ActionResult:
        """Resolve an ability whose source card is in the discard pile."""
        if self.state.phase != TurnPhase.MAIN or self.state.active_player_idx != player_idx:
            return ActionResult(False, "只能在自己的主要阶段使用该特性。")
        player = self.state.get_player(player_idx)
        if type(discard_idx) is not int or not (0 <= discard_idx < len(player.discard)):
            return ActionResult(False, "弃牌区中的特性来源已失效。")
        card = player.discard[discard_idx]
        if card_id and card.api_id != card_id:
            return ActionResult(False, "弃牌区中的特性来源已变化。")
        ability = next(
            (candidate for candidate in card.abilities
             if candidate.name.lower() == ability_name.lower()),
            None,
        )
        if ability is None:
            return ActionResult(False, f"未找到特性'{ability_name}'。")
        if player.hand:
            return ActionResult(False, "手牌不为空，无法使用紧急上浮。")
        if not player.bench_has_space():
            return ActionResult(False, "备战区已满。")

        effects = copy.deepcopy(ability_runtime_effects(ability))
        found_zone_effect = False
        for effect in effects:
            if not isinstance(effect, dict):
                continue
            op = str(effect.get("op", "") or "")
            effect_kind = str(effect.get("effect_type", "") or "")
            if op == "discard_then_revive" or effect_kind == "ability_discard_revive":
                args = effect.setdefault("args" if op else "params", {})
                args["discard_idx"] = discard_idx
                args["card_id"] = card.api_id
                found_zone_effect = True
        if not found_zone_effect:
            return ActionResult(False, "该特性不能从弃牌区发动。")

        self.state._log(f"{player.name}从弃牌区使用了{card.name}的特性{ability.name}。")
        return self._execute_effects(effects, player_idx, "discard")

    def _retreat(
        self,
        player_idx: int,
        bench_idx: int,
        energy_indices: list[int] | tuple[int, ...] | None = None,
    ) -> ActionResult:
        ok, reason = can_retreat(self.state, player_idx, bench_idx, energy_indices)
        if not ok:
            return ActionResult(False, reason)

        player = self.state.get_player(player_idx)
        from engine.rules_validator import _get_effective_retreat_cost
        retreat_cost = _get_effective_retreat_cost(self.state, player)
        pokemon_name = player.active.card.name

        player.pay_retreat_cost(retreat_cost, energy_indices)
        player.switch_active_to_bench(bench_idx)
        player.retreated_this_turn = True

        msg = f"{player.name}将{pokemon_name}撤退（支付{retreat_cost}个能量）。"
        self.state._log(msg)
        return ActionResult(True, msg)

    def _declare_attack(
        self,
        player_idx: int,
        attack_idx: int,
        *,
        finish_attack_in_stack: bool = False,
    ) -> ActionResult:
        ok, reason = can_declare_attack(self.state, player_idx, attack_idx)
        if not ok:
            return ActionResult(False, reason)

        player = self.state.get_player(player_idx)
        attacker = player.active
        attack = attacker.card.attacks[attack_idx]
        attacker_type = attacker.card.energy_types[0] if attacker.card.energy_types else "Colorless"

        self.state.event_stream.push(GameEvent("attack_declared", {
            "player": player_idx,
            "card_id": attacker.card.api_id,
            "attack_idx": attack_idx,
            "attack_name": attack.name,
        }))

        # Check confusion
        if StatusType.CONFUSED in attacker.status_conditions:
            source = getattr(self.state, "random_source", None)
            coin = ("heads" if source.coin() else "tails") if source else random.choice(["heads", "tails"])
            self.state.event_stream.push(GameEvent("coin_flip", {
                "player": player_idx, "results": [coin == "heads"], "purpose": "confusion",
            }))
            if coin == "tails":
                before_hp = attacker.current_hp
                attacker.damage_counters += 3
                if before_hp > 0 and attacker.current_hp <= 0:
                    attacker.pending_ko_cause = "special_condition"
                self.state.event_stream.push(GameEvent("confusion_failed", {
                    "player": player_idx, "slot": "active", "self_damage": 30,
                }))
                msg = (f"{player.name}的{attacker.card.name}处于混乱状态！"
                       f"掷出反面。攻击失败，自身放置3个伤害指示物。")
                self.state._log(msg)
                result = ActionResult(True, msg, attack_failed=True)
                if attacker.is_knocked_out:
                    ko_result = self.resolve_knockout_batch(
                        default_cause="special_condition",
                        source_player=None,
                        finish_attack_actor=(
                            player_idx if finish_attack_in_stack else None
                        ),
                    )
                    merge_action_results(result, ko_result)
                return result

        # Check dazzling_beam marker (炫目光束 effect)
        if attacker.dazzled:
            attacker.dazzled = False
            source = getattr(self.state, "random_source", None)
            coin = ("heads" if source.coin() else "tails") if source else random.choice(["heads", "tails"])
            self.state.event_stream.push(GameEvent("coin_flip", {
                "player": player_idx, "results": [coin == "heads"], "purpose": "dazzled",
            }))
            self.state._log(f"{attacker.card.name}受炫目光束影响，掷硬币: {coin}!")
            if coin == "tails":
                msg = f"{attacker.card.name}的招式失败！（炫目光束效果）"
                self.state._log(msg)
                self.state.event_stream.push(GameEvent("dazzled_failed", {
                    "player": player_idx, "slot": "active",
                }))
                return ActionResult(True, msg, attack_failed=True)

        msg = f"{player.name}的{attacker.card.name}使用了{attack.name}！"
        self.state._log(msg)

        result = ActionResult(True, msg)

        replace_base_damage = _attack_effects_replace_base_damage(attack)
        attack_damage_context = {
            "active": True,
            "player_idx": player_idx,
            "attacker": attacker,
            "base_damage": 0 if replace_base_damage else int(attack.damage or 0),
            "attacker_type": attacker_type,
            "ignore_weakness": False,
            "ignore_resistance": False,
            "ignore_defender_damage_effects": False,
        }

        # Execute all attack effects and the final damage/KO frame in one VM
        # stack so pending choices resume the remaining attack frames.
        eff_result = self._execute_attack_effects(
            attack_runtime_effects(attack),
            player_idx,
            "active",
            attack_damage_context,
            finish_attack_in_stack=finish_attack_in_stack,
        )
        merge_action_results(result, eff_result)

        if not result.success:
            clear_attack_damage_context(self.state)
            return result

        return result

    def _end_turn(self, player_idx: int) -> ActionResult:
        msg = f"{self.state.get_player(player_idx).name}结束了回合。"
        self.state._log(msg)
        return ActionResult(True, msg)

    # ---- Effect Execution (Resolution Stack) ----

    def _execute_effects(self, effects: list, player_idx: int,
                         source_slot: str) -> ActionResult:
        """Execute normal effects through the VM effect runner."""
        return self._effect_runner().execute_effects(effects, player_idx, source_slot)

    def _execute_attack_effects(
        self,
        effects: list,
        player_idx: int,
        source_slot: str,
        attack_damage_context: dict,
        *,
        finish_attack_in_stack: bool = False,
    ) -> ActionResult:
        return self._effect_runner().execute_attack_effects(
            effects,
            player_idx,
            source_slot,
            attack_damage_context,
            finish_attack_in_stack=finish_attack_in_stack,
        )

    # ---- KO Checking ----

    def resolve_knockout_batch(
        self,
        *,
        default_cause: str = "rule",
        source_player: int | None = None,
        finish_attack_actor: int | None = None,
        finish_checkup_actor: int | None = None,
    ) -> ActionResult:
        """Resolve every currently Knocked Out Pokemon through one VM batch."""
        return self._effect_runner().resolve_knockout_batch(
            default_cause=default_cause,
            source_player=source_player,
            finish_attack_actor=finish_attack_actor,
            finish_checkup_actor=finish_checkup_actor,
        )

    def _check_kos(self) -> list[str]:
        return self._effect_runner().check_kos()

    def _handle_ko(self, player_idx: int, slot: str):
        self._effect_runner().handle_ko(player_idx, slot)

    def _prompt_bench_promotion(self, player_idx: int):
        """Let the UI handle bench promotion selection.
        Sets a flag so TurnManager pauses before advancing the turn."""
        self._effect_runner().prompt_bench_promotion(player_idx)

    # ---- Pokemon Checkup ----

    def resolve_checkup(self) -> tuple[list[str], ActionResult]:
        results = []

        # Pokemon Checkup is resolved by condition for both Active Pokemon:
        # Poison, Burn, Asleep, then Paralyzed.  KO is checked only after all
        # four passes so simultaneous damage cannot be biased by player order.
        for player_idx in range(2):
            player = self.state.get_player(player_idx)
            if player.active:
                active = player.active
                name = active.card.name
                if StatusType.POISONED in active.status_conditions:
                    if active.current_hp <= 10:
                        active.pending_ko_cause = "special_condition"
                    active.damage_counters += 1
                    results.append(f"{name}因中毒受到1个伤害指示物。")

        for player_idx in range(2):
            player = self.state.get_player(player_idx)
            if player.active:
                active = player.active
                name = active.card.name
                if StatusType.BURNED in active.status_conditions:
                    if active.current_hp <= 20:
                        active.pending_ko_cause = "special_condition"
                    active.damage_counters += 2
                    source = getattr(self.state, "random_source", None)
                    roll = source.random() if source else random.random()
                    if roll < COIN_FLIP_THRESHOLD:
                        active.status_conditions.remove(StatusType.BURNED)
                        results.append(f"{name}因灼伤受到2个伤害指示物并治愈了！")
                    else:
                        results.append(f"{name}因灼伤受到2个伤害指示物（仍未治愈）。")

        for player_idx in range(2):
            player = self.state.get_player(player_idx)
            if player.active:
                active = player.active
                name = active.card.name
                if StatusType.ASLEEP in active.status_conditions:
                    source = getattr(self.state, "random_source", None)
                    roll = source.random() if source else random.random()
                    if roll < COIN_FLIP_THRESHOLD:
                        active.status_conditions.remove(StatusType.ASLEEP)
                        results.append(f"{name}醒来了！")
                    else:
                        results.append(f"{name}仍在睡眠中。")

        for player_idx in range(2):
            player = self.state.get_player(player_idx)
            if player.active:
                active = player.active
                name = active.card.name
                if StatusType.PARALYZED in active.status_conditions:
                    # PTCG rule: Paralyzed cures at end of the paralyzed player's NEXT turn.
                    if self.state.turn_number > active.paralyzed_since_turn:
                        active.status_conditions.remove(StatusType.PARALYZED)
                        results.append(f"{name}的麻痹治愈了。")
                    else:
                        results.append(f"{name}仍处于麻痹状态。")

        # Log causal checkup outcomes before KO/prize settlement logs.
        for message in results:
            self.state._log(message)

        settlement = self.resolve_knockout_batch(
            default_cause="special_condition",
            source_player=None,
            finish_checkup_actor=self.state.active_player_idx,
        )
        ko_slots = list(settlement.pokemon_ko)
        if ko_slots:
            ko_summary = f"击倒: {', '.join(ko_slots)}"
            results.append(ko_summary)
            self.state._log(ko_summary)
        return results, settlement

"""Action resolver - executes game actions and mutates GameState."""
import random
from engine.rules_constants import DAMAGE_PER_COUNTER, COIN_FLIP_THRESHOLD
from engine.enums import TurnPhase, StatusType, PlayerAction, EventType
from engine.game_state import GameState, ActionResult, ActionRequest
from engine.rules_validator import (
    can_play_basic, can_evolve, can_attach_energy, can_play_supporter,
    can_play_item, can_play_stadium, can_play_tool, can_retreat,
    can_declare_attack, can_use_ability, check_win_condition
)
from engine.damage_calculator import calculate_damage
from engine.player_state import PokemonInPlay
from engine.commands.modifier_registration import (
    register_pokemon_modifiers,
    unregister_pokemon_modifiers,
)
from engine.commands.damage_pipeline import resolve_damage as event_damage_pipeline
from engine.effects.modifier_registry import (
    get_special_energy_attach_effect,
)
from data.card_models import Card
from engine.commands.resolution_stack import ResolutionStack
from engine.commands.registry import build_command
from engine.commands.base import CommandResult


def _cr_to_ar(cr: CommandResult) -> ActionResult:
    """Convert CommandResult to ActionResult (legacy compatibility)."""
    return ActionResult(
        success=cr.success,
        log_message=cr.log_message,
        damage_dealt=cr.damage_dealt,
        cards_drawn=cr.cards_drawn,
        cards_discarded=getattr(cr, 'cards_discarded', 0),
        pokemon_ko=cr.pokemon_ko,
        status_applied=cr.status_applied,
        pending_action=cr.pending_choice,
        attack_failed=cr.attack_failed,
    )


def merge_action_results(target: ActionResult, source: ActionResult) -> ActionResult:
    """Merge source into target, preserving all user-visible result fields."""
    if source.log_message:
        target.log_message = (
            f"{target.log_message} {source.log_message}".strip()
            if target.log_message else source.log_message
        )
    target.success = target.success and source.success
    target.damage_dealt += source.damage_dealt
    target.cards_drawn.extend(source.cards_drawn)
    target.cards_discarded += source.cards_discarded
    target.pokemon_ko.extend(source.pokemon_ko)
    target.status_applied.extend(source.status_applied)
    target.prize_taken = target.prize_taken or source.prize_taken
    target.attack_failed = target.attack_failed or source.attack_failed
    if source.pending_action:
        target.pending_action = source.pending_action
    return target


FULL_DAMAGE_EFFECT_TYPES = {
    "damage_per_self_damage",
    "damage_per_self_energy",
    "damage_per_self_energy_type",
    "damage_plus_bench",
    "damage_per_hand_size",
    "damage_per_energy",
    "damage_per_evolved",
    "damage_self_penalty",
    "damage_per_discard_psychic",
    "conditional_damage_heal",
    "mill_and_damage_per_energy",
}


def _effect_type(effect) -> str:
    if isinstance(effect, dict):
        return str(effect.get("type") or effect.get("effect_type") or "")
    return str(getattr(effect, "type", "") or getattr(effect, "effect_type", ""))


def _attack_effects_replace_base_damage(attack) -> bool:
    return any(
        _effect_type(effect) in FULL_DAMAGE_EFFECT_TYPES
        for effect in getattr(attack, "effects", []) or []
    )


class ActionResolver:
    """Handles execution of all game actions."""

    def __init__(self, state: GameState):
        self.state = state

    def resolve(self, action: PlayerAction, **params) -> ActionResult:
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
        for effect in stadium.trainer_effects:
            if hasattr(effect, 'params') and effect.params.get("stadium_type") == "activatable":
                stadium_type = "activatable"
                break

        if stadium_type != "activatable":
            return ActionResult(False, f"「{stadium.name}」的效果是持续生效的，无需手动发动。")

        msg = f"{player.name}使用了竞技场「{stadium.name}」的效果。"
        self.state._log(msg)

        result = ActionResult(True, msg)
        for effect in stadium.trainer_effects:
            eff_result = self._execute_effect(effect, player_idx, "active")
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
                ab_results = self._execute_effects(
                    ability.effects, player_idx, target
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
                                          event_bus=self.state.event_bus)
            register_pokemon_modifiers(pokemon, player_idx, slot,
                                       event_bus=self.state.event_bus)

        msg = f"{player.name}将{old_card.name}进化成了{card.name}！"
        self.state._log(msg)

        result = ActionResult(True, msg)
        for ability in card.abilities:
            if ability.trigger == "on_enter_play":
                ab_results = self._execute_effects(
                    ability.effects, player_idx, slot
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

        slot_cn = "战斗宝可梦" if target_slot == "active" else f"备战区{target_slot.split('_')[1]}"
        msg = f"{player.name}将{card.name}附着于{slot_cn}。"
        self.state._log(msg)

        # Special energy on-attach effects (generic hook)
        should_switch, switch_msg = get_special_energy_attach_effect(card, player, target_slot)
        if should_switch:
            bench_idx = int(target_slot.split("_")[1])
            target = player.get_pokemon(target_slot)
            player.switch_active_to_bench(bench_idx)
            poke_name = target.card.name if target else "宝可梦"
            self.state._log(f"喷射能量效果：将{poke_name}切换为战斗宝可梦！")
            msg += " " + switch_msg

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

        # Pop card from hand BEFORE executing effects,
        # so discard-cost card_list doesn't include this card.
        # If effects fail, put the card back.
        player.hand.pop(hand_idx)

        # Log usage first, then execute effects (effect details appear after)
        msg = f"{player.name}使用了{card.name}。"
        self.state._log(msg)

        result = ActionResult(True, msg)
        if card.trainer_effects:
            effect_result = self._execute_effects(
                card.trainer_effects, player_idx, "active"
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

        if card.is_trainer_stadium:
            if self.state.stadium_card:
                player.discard.append(self.state.stadium_card)
            self.state.stadium_card = card
            player.stadium_played_this_turn = True

        # Only discard supporter/item if no pending action (e.g. search prompts).
        # If there IS a pending action, the card is consumed when the action completes.
        if not result.pending_action:
            if card.is_trainer_supporter:
                player.supporter_played_this_turn = True
                player.discard.append(card)
            elif card.is_trainer_item:
                player.discard.append(card)
        else:
            # Card is consumed during the pending action — mark supporter usage now
            # to prevent reuse, but keep the card until the pending action completes
            if card.is_trainer_supporter:
                player.supporter_played_this_turn = True
            # Defer discard until pending action completes. Store card reference
            # so it can be returned to hand on cancel.
            result.pending_action.pending_card = card

        return result

    def _use_ability(self, player_idx: int, slot: str,
                     ability_name: str, **params) -> ActionResult:
        ok, reason = can_use_ability(
            self.state, player_idx, slot, ability_name
        )
        if not ok:
            return ActionResult(False, reason)

        player = self.state.get_player(player_idx)
        pokemon = player.get_pokemon(slot)

        for ability in pokemon.card.abilities:
            if ability.name.lower() == ability_name.lower():
                msg = f"{player.name}使用了{pokemon.card.name}的特性{ability.name}。"
                self.state._log(msg)
                result = self._execute_effects(ability.effects, player_idx, slot)
                if result.success:
                    pokemon.used_abilities.add(ability.name)
                return result

        return ActionResult(False, f"未找到特性'{ability_name}'。")

    def _retreat(self, player_idx: int, bench_idx: int) -> ActionResult:
        ok, reason = can_retreat(self.state, player_idx, bench_idx)
        if not ok:
            return ActionResult(False, reason)

        player = self.state.get_player(player_idx)
        from engine.rules_validator import _get_effective_retreat_cost
        retreat_cost = _get_effective_retreat_cost(self.state, player)
        pokemon_name = player.active.card.name

        player.pay_retreat_cost(retreat_cost)
        player.switch_active_to_bench(bench_idx)
        player.retreated_this_turn = True

        msg = f"{player.name}将{pokemon_name}撤退（支付{retreat_cost}个能量）。"
        self.state._log(msg)
        return ActionResult(True, msg)

    def _declare_attack(self, player_idx: int, attack_idx: int) -> ActionResult:
        ok, reason = can_declare_attack(self.state, player_idx, attack_idx)
        if not ok:
            return ActionResult(False, reason)

        player = self.state.get_player(player_idx)
        attacker = player.active
        attack = attacker.card.attacks[attack_idx]
        attacker_type = attacker.card.energy_types[0] if attacker.card.energy_types else "Colorless"

        # Check confusion
        if StatusType.CONFUSED in attacker.status_conditions:
            coin = random.choice(["heads", "tails"])
            if coin == "tails":
                attacker.damage_counters += 3
                msg = (f"{player.name}的{attacker.card.name}处于混乱状态！"
                       f"掷出反面。攻击失败，自身放置3个伤害指示物。")
                self.state._log(msg)
                ko_results = self._check_kos()
                result = ActionResult(True, msg)
                if ko_results:
                    result.pokemon_ko.extend(ko_results)
                return result

        # Check dazzling_beam marker (炫目光束 effect)
        if attacker.dazzled:
            attacker.dazzled = False
            coin = random.choice(["heads", "tails"])
            self.state._log(f"{attacker.card.name}受炫目光束影响，掷硬币: {coin}!")
            if coin == "tails":
                msg = f"{attacker.card.name}的招式失败！（炫目光束效果）"
                self.state._log(msg)
                return ActionResult(True, msg)

        msg = f"{player.name}的{attacker.card.name}使用了{attack.name}！"
        self.state._log(msg)

        result = ActionResult(True, msg)

        opponent = self.state.get_opponent()
        defender = opponent.active

        # Execute custom effects
        for effect in attack.effects:
            eff_result = self._execute_effect(
                effect, player_idx, "active"
            )
            merge_action_results(result, eff_result)

        apply_base_damage = attack.damage > 0 and not _attack_effects_replace_base_damage(attack)

        # Apply base damage + KO checks. If a pending action (e.g. coin flip)
        # was generated by effects, defer damage until it resolves — otherwise
        # damage would be applied before the coin flip result is known.
        if result.pending_action and apply_base_damage and defender is not None:
            orig_callback = result.pending_action.callback

            def attack_complete_wrapper(choice_result):
                inner = orig_callback(choice_result) if orig_callback else ActionResult(True, "")
                if inner is None:
                    inner = ActionResult(True, "")

                # Callback may return an ActionRequest if the effect chain
                # produces another pending action (e.g. search after coin flip).
                # Wrap it recursively so damage stays deferred.
                if isinstance(inner, ActionRequest):
                    chain_cb = inner.callback

                    def deeper_wrapper(cr):
                        return attack_complete_wrapper(cr)

                    inner.callback = deeper_wrapper
                    return inner

                # ActionResult — terminal: apply damage and KO checks
                if not inner.attack_failed and apply_base_damage:
                    self._apply_attack_damage(defender, attacker, attack, attacker_type, inner)
                self._do_attack_ko_checks(inner)
                return inner

            result.pending_action.callback = attack_complete_wrapper
        else:
            if apply_base_damage and defender is not None and not result.attack_failed:
                self._apply_attack_damage(defender, attacker, attack, attacker_type, result)
            self._do_attack_ko_checks(result)

        return result

    def _apply_attack_damage(self, defender, attacker, attack, attacker_type, result):
        """Apply base attack damage via the event-driven damage pipeline."""
        if defender.damage_prevented_next_turn:
            defender.damage_prevented_next_turn = False
            defender.all_prevented_next_turn = False
            self.state._log(f"{defender.card.name}免疫了所有伤害！")
            return

        piercing = getattr(self.state, '_piercing_attack', False)
        self.state._piercing_attack = False

        final_damage, mod_logs = event_damage_pipeline(
            self.state, attacker, defender,
            attack.damage, attacker_type,
            piercing=piercing,
        )
        for log_msg in mod_logs:
            self.state._log(log_msg)

        counters = final_damage // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        result.damage_dealt += final_damage

        self.state._log(f"对{defender.card.name}造成了{final_damage}点伤害"
                        f"（剩余HP {defender.current_hp}）。")

    def _do_attack_ko_checks(self, result):
        """Check KOs and win condition after attack damage."""
        self.state._ko_from_attack = True
        ko_results = self._check_kos()
        self.state._ko_from_attack = False
        result.pokemon_ko.extend(ko_results)

        from engine.rules_validator import check_win_condition
        winner = check_win_condition(self.state)
        if winner is not None:
            self.state.winner = winner
            self.state.phase = TurnPhase.GAME_OVER
            self.state._log(f"{self.state.get_player(winner).name}获胜！")

    def _end_turn(self, player_idx: int) -> ActionResult:
        msg = f"{self.state.get_player(player_idx).name}结束了回合。"
        self.state._log(msg)
        return ActionResult(True, msg)

    # ---- Effect Execution (Resolution Stack) ----

    def _execute_effects(self, effects: list, player_idx: int,
                         source_slot: str) -> ActionResult:
        """Execute a list of effects using the ResolutionStack.

        Each effect is built into an ICommand via the registry and pushed
        onto a LIFO ResolutionStack. Triggers (on_enter_play abilities, etc.)
        push new commands onto the stack, which resolve before the caller
        continues — correctly modeling nested trigger trees.
        """
        stack = ResolutionStack(self.state)
        try:
            commands = [build_command(e) for e in effects]
        except KeyError as e:
            return ActionResult(False, str(e))
        stack.push_many(commands)
        rr = stack.resolve_all(player_idx, source_slot)

        result = ActionResult(
            success=rr.success,
            log_message=" ".join(rr.log_messages),
            damage_dealt=rr.damage_dealt,
            cards_drawn=rr.cards_drawn,
            cards_discarded=rr.cards_discarded,
            pokemon_ko=rr.pokemon_ko,
            status_applied=rr.status_applied,
            pending_action=rr.pending_choice,
            attack_failed=rr.attack_failed,
        )
        return result

    def _execute_effect(self, effect_def, player_idx: int,
                        source_slot: str) -> ActionResult:
        """Execute a single effect via the ResolutionStack (1-item stack)."""
        return self._execute_effects([effect_def], player_idx, source_slot)

    # ---- KO Checking ----

    def _check_kos(self) -> list[str]:
        ko_slots = []

        for player_idx in [0, 1]:
            player = self.state.get_player(player_idx)

            if player.active and player.active.is_knocked_out:
                ko_slots.append(f"p{player_idx}_active")
                self._handle_ko(player_idx, "active")

            for i, pokemon in enumerate(player.bench):
                if pokemon and pokemon.is_knocked_out:
                    ko_slots.append(f"p{player_idx}_bench_{i}")
                    self._handle_ko(player_idx, f"bench_{i}")

        return ko_slots

    def _handle_ko(self, player_idx: int, slot: str):
        player = self.state.get_player(player_idx)
        opponent = self.state.get_player(1 - player_idx)
        pokemon = player.get_pokemon(slot)

        if pokemon is None:
            return

        if self.state._ko_from_attack:
            player.was_ko_by_attack = True

        prize_count = pokemon.card.prize_value

        # Unregister modifier listeners for the KO'd Pokemon
        unregister_pokemon_modifiers(pokemon.card.api_id, slot,
                                      event_bus=self.state.event_bus)

        self.state.discard_pokemon(player_idx, slot)
        self.state._log(f"{player.name}的{pokemon.card.name}被击倒了！")

        for _ in range(prize_count):
            if opponent.prizes:
                opponent.take_prize()
                self.state._log(
                    f"{opponent.name}获得了奖品卡！"
                    f"（剩余{len(opponent.prizes)}张）"
                )

        if not player.has_any_pokemon_in_play():
            self.state.winner = 1 - player_idx
            self.state._log(
                f"{opponent.name}获胜——对手场上没有宝可梦了！"
            )
            self.state.phase = TurnPhase.GAME_OVER
            return

        if slot == "active":
            self._prompt_bench_promotion(player_idx)

    def _prompt_bench_promotion(self, player_idx: int):
        """Let the UI handle bench promotion selection.
        Sets a flag so TurnManager pauses before advancing the turn."""
        self.state.pending_promotion_player = player_idx

    # ---- Pokemon Checkup ----

    def resolve_checkup(self):
        results = []

        for player_idx in range(2):
            player = self.state.get_player(player_idx)

            if player.active:
                active = player.active
                name = active.card.name

                if StatusType.POISONED in active.status_conditions:
                    active.damage_counters += 1
                    results.append(f"{name}因中毒受到1个伤害指示物。")

                if StatusType.BURNED in active.status_conditions:
                    active.damage_counters += 2
                    if random.random() < COIN_FLIP_THRESHOLD:
                        active.status_conditions.remove(StatusType.BURNED)
                        results.append(f"{name}因灼伤受到2个伤害指示物并治愈了！")
                    else:
                        results.append(f"{name}因灼伤受到2个伤害指示物（仍未治愈）。")

                if StatusType.ASLEEP in active.status_conditions:
                    if random.random() < COIN_FLIP_THRESHOLD:
                        active.status_conditions.remove(StatusType.ASLEEP)
                        results.append(f"{name}醒来了！")
                    else:
                        results.append(f"{name}仍在睡眠中。")

                if StatusType.PARALYZED in active.status_conditions:
                    # PTCG rule: Paralyzed cures at end of the paralyzed player's NEXT turn.
                    if self.state.turn_number > active.paralyzed_since_turn:
                        active.status_conditions.remove(StatusType.PARALYZED)
                        results.append(f"{name}的麻痹治愈了。")
                    else:
                        results.append(f"{name}仍处于麻痹状态。")

        ko_slots = self._check_kos()
        if ko_slots:
            results.append(f"击倒: {', '.join(ko_slots)}")

        winner = check_win_condition(self.state)
        if winner is not None:
            self.state.winner = winner
            self.state.phase = TurnPhase.GAME_OVER

        for r in results:
            self.state._log(r)

        return results

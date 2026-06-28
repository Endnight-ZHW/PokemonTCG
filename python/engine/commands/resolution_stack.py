"""LIFO Resolution Stack for card game effects.

The stack ensures that triggered effects resolve before the triggering
effect continues — modeling the nested trigger tree correctly.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Optional, TYPE_CHECKING

from engine.commands.base import CommandResult

if TYPE_CHECKING:
    from engine.game_state import GameState
    from engine.commands.base import ICommand, ResolutionContext, ResolutionContext


@dataclass
class ResolutionResult:
    """Aggregated result of resolving a stack of commands."""
    success: bool = True
    log_messages: list[str] = field(default_factory=list)
    damage_dealt: int = 0
    cards_drawn: list = field(default_factory=list)
    cards_discarded: int = 0
    pokemon_ko: list[str] = field(default_factory=list)
    status_applied: list[str] = field(default_factory=list)
    pending_choice: Optional[Any] = None
    attack_failed: bool = False

    def merge(self, cr: CommandResult):
        self.damage_dealt += cr.damage_dealt
        self.cards_drawn.extend(cr.cards_drawn)
        self.cards_discarded += getattr(cr, 'cards_discarded', 0)
        self.pokemon_ko.extend(cr.pokemon_ko)
        self.status_applied.extend(cr.status_applied)
        if cr.log_message:
            self.log_messages.append(cr.log_message)
        if cr.pending_choice:
            self.pending_choice = cr.pending_choice
        self.attack_failed = self.attack_failed or cr.attack_failed
        self.success = self.success and cr.success


class ResolutionStack:
    """LIFO stack for resolving card game commands.

    Usage:
        stack = ResolutionStack(state)
        stack.push(DealDamageCommand(100))
        stack.push_many([DrawCommand(2), ApplyStatusCommand("poisoned")])
        result = stack.resolve_all()
    """

    def __init__(self, state: GameState):
        self.state = state
        self._stack: list[ICommand] = []
        self._context: Optional[ResolutionContext] = None

    def push(self, command: ICommand):
        """Push a single command onto the stack (resolves next)."""
        self._stack.append(command)

    def push_many(self, commands: list[ICommand]):
        """Push multiple commands. First in list resolves first (so push in reverse)."""
        for cmd in reversed(commands):
            self._stack.append(cmd)

    def resolve_all(self, player_idx: int = 0,
                    source_slot: str = "active") -> ResolutionResult:
        """Resolve everything on the stack until empty or a choice is needed."""
        from engine.commands.base import ResolutionContext

        result = ResolutionResult()
        ctx = ResolutionContext(self.state, player_idx, source_slot, self)

        while self._stack:
            cmd = self._stack.pop()
            try:
                cr = cmd.execute(ctx)
            except Exception as e:
                cr = CommandResult(success=False, log_message=str(e))

            result.merge(cr)

            if not cr.success:
                # On failure, stop resolution and return
                return result

            if cr.pending_choice:
                # Pause for UI input — store remaining stack for resume
                result.pending_choice = self._wrap_pending_choice(
                    cr.pending_choice, player_idx, source_slot
                )
                return result

            # Side effects are already on the stack (pushed via ctx.push_side
            # during execute), so the loop just continues.

        return result

    def resume_after_choice(self, player_idx: int = 0,
                            source_slot: str = "active") -> ResolutionResult:
        """Continue resolving after a UI choice was made. Reuses remaining stack."""
        return self.resolve_all(player_idx, source_slot)

    @property
    def depth(self) -> int:
        return len(self._stack)

    def clear(self):
        self._stack.clear()

    # ---- Pending continuation helpers ---------------------------------

    def _wrap_pending_choice(self, req, player_idx: int, source_slot: str):
        """Resume the remaining command stack after a pending choice resolves.

        A ResolutionStack can pause in the middle of a multi-effect card, for
        example "choose a Pokemon, attach an energy, then draw 2". The old
        callback resolved only the choice effect and then dropped the remaining
        commands because the local stack was no longer reachable. Wrapping the
        callback keeps the rest of the effect chain alive for UI, AI simulation,
        and training.
        """
        if req is None or getattr(req, "_resolution_stack_wrapped", False):
            return req

        original_callback = req.callback
        setattr(req, "_resolution_stack_wrapped", True)
        setattr(req, "_resolution_stack_had_callback", original_callback is not None)

        def chained(choice):
            original_result = self._resolve_request_continuation(
                req, choice, player_idx, source_slot
            )
            if original_callback:
                callback_result = original_callback(choice)
                original_result = self._merge_callback_results(
                    original_result,
                    callback_result,
                )
            return self._continue_after_callback_result(
                original_result, player_idx, source_slot
            )

        req.callback = chained
        return req

    def _resolve_request_continuation(
        self,
        req,
        choice,
        player_idx: int,
        source_slot: str,
    ):
        from engine.game_state import ActionResult

        continuation = dict(getattr(req, "continuation", {}) or {})
        kind = str(continuation.get("kind", "") or "")
        if kind == "":
            return None

        if kind == "flip_coin_branch":
            results = [bool(item) for item in (choice or [])]
            is_heads = bool(results and results[0])
            cn = "正面" if is_heads else "反面"
            self.state._log(f"掷硬币: {cn}!")
            branch_items = list(
                continuation.get("on_heads" if is_heads else "on_tails", [])
                or []
            )
            if branch_items:
                try:
                    from engine.commands.primitives import _build_branch_command

                    self.push_many([
                        _build_branch_command(item)
                        for item in branch_items
                    ])
                except Exception as exc:
                    return ActionResult(False, str(exc))
            return ActionResult(True, f"硬币: {cn}.")

        if kind == "coin_special":
            return self._resolve_coin_special_continuation(
                continuation,
                choice,
                player_idx,
            )

        if kind == "coin_energy_discard":
            return self._resolve_coin_energy_discard_continuation(
                choice,
                player_idx,
            )

        if kind == "discard_attachment":
            return self._resolve_discard_attachment_continuation(choice)

        if kind == "switch_confirm":
            return self._resolve_switch_confirm_continuation(
                continuation,
                choice,
            )

        if kind == "switch_bench":
            return self._resolve_switch_bench_continuation(
                continuation,
                choice,
            )

        if kind == "discard_hand_cards":
            return self._resolve_discard_hand_cards_continuation(
                continuation,
                choice,
            )

        if kind == "discard_hand_then_draw":
            return self._resolve_discard_hand_then_draw_continuation(
                continuation,
                choice,
            )

        if kind == "bench_damage_targets":
            return self._resolve_bench_damage_targets_continuation(
                continuation,
                choice,
            )

        if kind == "choose_damage_target":
            return self._resolve_choose_damage_target_continuation(
                continuation,
                choice,
            )

        if kind == "place_counters_then_self_ko":
            return self._resolve_place_counters_then_self_ko_continuation(
                continuation,
                choice,
                player_idx,
                source_slot,
            )

        if kind == "choose_heal_damage":
            return self._resolve_choose_heal_damage_continuation(
                continuation,
                choice,
            )

        if kind == "recover_from_discard_to_deck":
            return self._resolve_recover_from_discard_to_deck_continuation(
                continuation,
                choice,
            )

        if kind == "recover_clara":
            return self._resolve_recover_clara_continuation(
                continuation,
                choice,
            )

        if kind == "hand_to_bottom_then_draw":
            return self._resolve_hand_to_bottom_then_draw_continuation(
                continuation,
                choice,
            )

        if kind == "hand_to_bottom_draw_until":
            return self._resolve_hand_to_bottom_draw_until_continuation(
                continuation,
                choice,
            )

        if kind == "zinnia_resolve":
            return self._resolve_zinnia_resolve_continuation(
                continuation,
                choice,
            )

        if kind == "search_cards":
            return self._resolve_search_cards_continuation(
                continuation,
                choice,
            )

        if kind == "search_item_and_tool":
            return self._resolve_search_item_and_tool_continuation(
                continuation,
                choice,
            )

        if kind == "trekking_shoes":
            return self._resolve_trekking_shoes_continuation(
                continuation,
                choice,
            )

        if kind == "look_top_deck":
            return self._resolve_look_top_deck_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "detached_energy_distribution":
            return self._resolve_detached_energy_distribution_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "look_top_bench_energy_distribution":
            return self._resolve_look_top_bench_energy_distribution_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "look_top_attach_energy":
            return self._resolve_look_top_attach_energy_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "look_top_attach_target":
            return self._resolve_look_top_attach_target_continuation(
                continuation,
                choice,
            )

        if kind == "draw_and_attach_energy_distribution":
            return self._resolve_draw_and_attach_energy_distribution_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "attach_energy_distribution":
            return self._resolve_attach_energy_distribution_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "attach_energy_to_bench":
            return self._resolve_attach_energy_to_bench_continuation(
                continuation,
                choice,
            )

        if kind == "attach_energy_to_board":
            return self._resolve_attach_energy_to_board_continuation(
                continuation,
                choice,
            )

        if kind == "attach_discard_energy_distribution":
            return self._resolve_attach_discard_energy_distribution_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "attach_discard_energy_to_bench":
            return self._resolve_attach_discard_energy_to_bench_continuation(
                continuation,
                choice,
            )

        if kind == "attach_discard_energy_to_board":
            return self._resolve_attach_discard_energy_to_board_continuation(
                continuation,
                choice,
            )

        if kind == "energy_relocate_source":
            return self._resolve_energy_relocate_source_continuation(
                continuation,
                choice,
            )

        if kind == "energy_relocate_distribution":
            return self._resolve_energy_relocate_distribution_continuation(
                req,
                continuation,
                choice,
            )

        if kind == "search_any_and_switch":
            return self._resolve_search_any_and_switch_continuation(
                continuation,
                choice,
            )

        if kind == "search_any_switch_confirm":
            return self._resolve_search_any_switch_confirm_continuation(
                continuation,
                choice,
            )

        if kind == "search_any_switch_bench":
            return self._resolve_search_any_switch_bench_continuation(
                continuation,
                choice,
            )

        return ActionResult(False, f"Unknown VM continuation: {kind}")

    def _resolve_coin_special_continuation(
        self,
        continuation: dict,
        choice,
        player_idx: int,
    ):
        from engine.game_state import ActionResult
        from engine.rules_constants import DAMAGE_PER_COUNTER
        from engine.commands.primitives import (
            _consume_effect_damage_prevention,
            _queue_or_apply_opponent_active_damage,
        )

        results = [bool(item) for item in (choice or [])]
        heads = sum(1 for result in results if result)
        coin_kind = str(continuation.get("coin_kind", "repeat_damage") or "repeat_damage")
        params = dict(continuation.get("params", {}) or {})
        player = self.state.get_player(player_idx)
        opponent = self.state.get_player(1 - player_idx)

        if coin_kind == "double_ko":
            if len(results) >= 2 and results[0] and results[1]:
                target = opponent.active
                if target is None:
                    return ActionResult(True, "没有对手宝可梦。")
                if _consume_effect_damage_prevention(self.state, target):
                    return ActionResult(True, "击倒效果被免疫。")
                remaining = target.current_hp
                counters = max(1, (remaining + DAMAGE_PER_COUNTER - 1) // DAMAGE_PER_COUNTER)
                target.damage_counters += counters
                self.state._log(f"{target.card.name}被大树切割击倒！")
                return ActionResult(True, f"{target.card.name}被击倒！", pokemon_ko=["opponent_active"])
            self.state._log("大树切割失败。")
            return ActionResult(True, "大树切割失败。")

        damage_per = int(
            params.get(
                "per_head",
                params.get("damage_per_head", 10 if coin_kind == "repeat_damage" else 20),
            )
            or 0
        )
        total = heads * damage_per
        self.state._log(f"掷硬币结果: {heads}次正面，造成{total}点伤害。")
        if total > 0 and opponent.active:
            result = _queue_or_apply_opponent_active_damage(
                self.state,
                player_idx,
                player,
                opponent,
                total,
                "",
                f"硬币伤害: {total}。",
            )
            if result is not None:
                return result
        return ActionResult(True, f"硬币伤害: {total}。", damage_dealt=total)

    def _resolve_coin_energy_discard_continuation(
        self,
        choice,
        player_idx: int,
    ):
        from engine.game_state import ActionRequest, ActionResult

        results = [bool(item) for item in (choice or [])]
        is_heads = bool(results and results[0])
        cn = "正面" if is_heads else "反面"
        self.state._log(f"掷硬币: {cn}!")
        if not is_heads:
            return ActionResult(True, f"硬币: {cn}。没有丢弃能量。")

        opponent_idx = 1 - player_idx
        opponent = self.state.get_player(opponent_idx)
        attachment_options = []
        for slot_name, pokemon in opponent.get_all_pokemon():
            if not pokemon:
                continue
            for index, energy in enumerate(pokemon.energy_cards):
                attachment_options.append({
                    "player": opponent_idx,
                    "slot": slot_name,
                    "attachment_type": "energy",
                    "index": index,
                    "card_id": energy.api_id,
                    "label": f"{pokemon.card.name} - {energy.name}",
                })
        if not attachment_options:
            return ActionResult(True, "对手场上没有能量可丢弃。")

        return ActionRequest(
            request_type="select_attachment",
            player=player_idx,
            prompt="选择对手场上的1个能量丢弃。",
            min_select=1,
            max_select=1,
            target_player="opponent",
            target_info=attachment_options,
            continuation={"kind": "discard_attachment"},
        )

    def _resolve_discard_attachment_continuation(self, choice):
        from engine.game_state import ActionResult
        from engine.actions import AttachmentRef

        selected_refs = list(choice or [])
        ref = selected_refs[0] if selected_refs else None
        if not isinstance(ref, AttachmentRef):
            return ActionResult(False, "没有选择有效能量。")
        target_poke = self.state.get_player(ref.player).get_pokemon(ref.slot)
        if (
            target_poke is None
            or ref.index < 0
            or ref.index >= len(target_poke.energy_cards)
            or target_poke.energy_cards[ref.index].api_id != ref.card_id
        ):
            return ActionResult(False, "选择的能量已不存在。")
        discarded_energy = target_poke.energy_cards.pop(ref.index)
        self.state.get_player(ref.player).discard.append(discarded_energy)
        self.state._log(f"从{target_poke.card.name}身上丢弃了{discarded_energy.name}。")
        return ActionResult(True, f"粉碎之锤：丢弃了{target_poke.card.name}的1个能量。")

    def _resolve_switch_confirm_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionRequest, ActionResult

        if not bool(choice):
            return ActionResult(True, "未替换宝可梦。")

        bench_indices = [
            int(index)
            for index in continuation.get("bench_indices", []) or []
        ]
        target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
        if len(bench_indices) == 1:
            return self._resolve_switch_bench_continuation(
                {
                    "target_player_idx": target_player_idx,
                    "bench_indices": bench_indices,
                },
                bench_indices[0],
            )

        return ActionRequest(
            request_type=str(continuation.get("request_type", "select_bench")),
            player=int(continuation.get("chooser_idx", target_player_idx) or 0),
            prompt="选择要替换上场的宝可梦",
            min_select=1,
            max_select=1,
            target_player=str(continuation.get("request_target_player", "self")),
            bench_indices=bench_indices,
            continuation={
                "kind": "switch_bench",
                "target_player_idx": target_player_idx,
                "bench_indices": bench_indices,
            },
        )

    def _resolve_switch_bench_continuation(self, continuation: dict, choice):
        from engine.game_state import ActionResult

        try:
            bench_idx = int(choice)
        except (TypeError, ValueError):
            return ActionResult(False, "没有选择有效的备战宝可梦。")

        allowed = continuation.get("bench_indices", None)
        if allowed is not None:
            allowed_indices = {int(index) for index in allowed or []}
            if allowed_indices and bench_idx not in allowed_indices:
                return ActionResult(False, "选择的备战宝可梦不在可用范围内。")

        target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
        player = self.state.get_player(target_player_idx)
        if (
            bench_idx < 0
            or bench_idx >= len(player.bench)
            or player.active is None
            or player.bench[bench_idx] is None
        ):
            return ActionResult(False, "选择的备战宝可梦已不存在。")

        active_name = player.active.card.name
        bench_name = player.bench[bench_idx].card.name
        player.switch_active_to_bench(bench_idx)
        self.state._log(f"将{active_name}与{bench_name}互换了。")
        return ActionResult(True, "替换了战斗宝可梦。")

    def _resolve_discard_hand_cards_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        amount = int(continuation.get("amount", 0) or 0)
        player = self.state.get_player(player_idx)
        indices_to_discard = self._hand_indices_for_selected_cards(
            player,
            choice,
            amount,
        )
        discarded = player.discard_from_hand(indices_to_discard)
        self.state._log(f"从手牌丢弃了{len(discarded)}张卡。")
        return ActionResult(
            True,
            f"丢弃了{len(discarded)}张手牌。",
            cards_discarded=len(discarded),
        )

    def _resolve_discard_hand_then_draw_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        discard_amount = int(continuation.get("discard_amount", 0) or 0)
        draw_amount = int(continuation.get("draw_amount", 0) or 0)
        player = self.state.get_player(player_idx)
        indices_to_discard = self._hand_indices_for_selected_cards(
            player,
            choice,
            discard_amount,
        )
        discarded = player.discard_from_hand(indices_to_discard)
        drawn = player.draw_cards(draw_amount)
        self.state._log(
            f"{player.name}丢弃了{len(discarded)}张手牌并抽取了{len(drawn)}张卡。"
        )
        return ActionResult(
            True,
            f"丢弃{len(discarded)}张手牌并抽取了{len(drawn)}张。",
            cards_drawn=drawn,
            cards_discarded=len(discarded),
        )

    @staticmethod
    def _hand_indices_for_selected_cards(player, choice, limit: int) -> list[int]:
        from collections import Counter

        selected_cards = list(choice or [])[: max(0, int(limit or 0))]
        target_counts = Counter(
            getattr(card, "api_id", "")
            for card in selected_cards
        )
        indices_to_discard = []
        for index, hand_card in enumerate(player.hand):
            api_id = getattr(hand_card, "api_id", "")
            if target_counts.get(api_id, 0) > 0:
                indices_to_discard.append(index)
                target_counts[api_id] -= 1
        return indices_to_discard

    def _resolve_bench_damage_targets_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult
        from engine.rules_constants import DAMAGE_PER_COUNTER

        target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
        target_state = self.state.get_player(target_player_idx)
        amount = int(continuation.get("amount", 0) or 0)
        count = int(continuation.get("count", 1) or 1)
        counters = amount // DAMAGE_PER_COUNTER
        allowed = {
            int(index)
            for index in continuation.get("bench_indices", []) or []
        }
        selected_indices = []
        for item in list(choice or [])[:count]:
            try:
                selected_indices.append(int(item))
            except (TypeError, ValueError):
                continue

        hits = 0
        for index in selected_indices:
            if allowed and index not in allowed:
                continue
            if 0 <= index < len(target_state.bench) and target_state.bench[index]:
                target_state.bench[index].damage_counters += counters
                hits += 1
        self.state._log(
            f"对{target_state.name}的备战区造成了{hits}次{amount}点伤害。"
        )
        return ActionResult(True, f"Bench damage dealt to {hits} Pokemon.")

    def _resolve_choose_damage_target_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult
        from engine.rules_constants import DAMAGE_PER_COUNTER
        from engine.commands.primitives import _consume_effect_damage_prevention

        target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
        slot_name, target_poke = self._resolve_board_choice(
            target_player_idx,
            choice,
        )
        if target_poke is None:
            return ActionResult(True, "")
        if _consume_effect_damage_prevention(self.state, target_poke):
            return ActionResult(True, "")

        amount = int(continuation.get("amount", 0) or 0)
        target_poke.damage_counters += amount // DAMAGE_PER_COUNTER
        self.state._log(f"对{target_poke.card.name}造成了{amount}点伤害。")
        return ActionResult(True, "")

    def _resolve_place_counters_then_self_ko_continuation(
        self,
        continuation: dict,
        choice,
        player_idx: int,
        source_slot: str,
    ):
        from engine.enums import TurnPhase
        from engine.game_state import ActionResult
        from engine.commands.primitives import (
            _discard_pokemon_for_effect,
            _handle_effect_ko_if_needed,
            _set_promotion_or_game_over,
        )

        target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
        slot_name, target_poke = self._resolve_board_choice(
            target_player_idx,
            choice,
        )
        if target_poke is None or not slot_name:
            return ActionResult(True, "神秘彗星没有选择目标。")

        counters = int(continuation.get("counters", 0) or 0)
        ko_slots: list[str] = []
        target_poke.damage_counters += counters
        self.state._log(f"在{target_poke.card.name}身上放置了{counters}个伤害指示物。")
        _handle_effect_ko_if_needed(
            self.state,
            target_player_idx,
            slot_name,
            target_poke,
            ko_slots,
        )
        if self.state.phase != TurnPhase.GAME_OVER:
            source = _discard_pokemon_for_effect(
                self.state,
                player_idx,
                source_slot,
            )
            if source:
                self.state._log(f"{source.card.name}被放置于弃牌区。")
                if source_slot == "active":
                    _set_promotion_or_game_over(self.state, player_idx)

        return ActionResult(
            True,
            "神秘彗星结算完毕。",
            pokemon_ko=list(ko_slots),
        )

    def _resolve_choose_heal_damage_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult
        from engine.rules_constants import DAMAGE_PER_COUNTER

        target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
        _slot_name, target_poke = self._resolve_board_choice(
            target_player_idx,
            choice,
        )
        if target_poke is None:
            return ActionResult(False, "无效的回复目标。")

        amount = int(continuation.get("amount", 0) or 0)
        counters = amount // DAMAGE_PER_COUNTER
        target_poke.damage_counters = max(0, target_poke.damage_counters - counters)
        self.state.get_player(target_player_idx).healed_this_turn = True
        self.state._log(f"{target_poke.card.name}回复了{amount}点HP。")
        return ActionResult(True, f"{target_poke.card.name}回复了{amount}点HP。")

    def _resolve_recover_from_discard_to_deck_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        count = int(continuation.get("count", 0) or 0)
        player = self.state.get_player(player_idx)
        selected = self._take_selected_cards_from_zone(player, "discard", choice, count)
        if not selected:
            self.state._log(f"{player.name}没有从弃牌区选择卡牌。")
            return ActionResult(True, "没有选择卡牌。")
        player.deck.extend(selected)
        player.shuffle_deck()
        self.state._log(f"{player.name}将{len(selected)}张卡从弃牌区洗回牌库。")
        return ActionResult(True, f"将{len(selected)}张卡洗回牌库。")

    def _resolve_recover_clara_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        pokemon_limit = int(continuation.get("pokemon_count", 0) or 0)
        energy_limit = int(continuation.get("energy_count", 0) or 0)
        player = self.state.get_player(player_idx)
        selected = list(choice or [])
        pokemon_taken = 0
        energy_taken = 0
        for card in selected:
            candidate = self._find_selected_card_in_zone(
                player,
                "discard",
                card,
            )
            if candidate is None:
                continue
            if getattr(candidate, "is_pokemon", False) and pokemon_taken < pokemon_limit:
                player.discard.remove(candidate)
                player.hand.append(candidate)
                pokemon_taken += 1
                continue
            if getattr(candidate, "is_basic_energy", False) and energy_taken < energy_limit:
                player.discard.remove(candidate)
                player.hand.append(candidate)
                energy_taken += 1
                continue
        self.state._log(
            f"{player.name}从弃牌区回收了{pokemon_taken}只宝可梦和{energy_taken}张基本能量。"
        )
        return ActionResult(
            True,
            f"回收了{pokemon_taken}只宝可梦和{energy_taken}张基本能量。",
        )

    def _resolve_hand_to_bottom_then_draw_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        selected = self._take_selected_cards_from_zone(
            player,
            "hand",
            choice,
            len(list(choice or [])),
        )
        for card in selected:
            player.deck.insert(0, card)
        self.state._log(f"{player.name}将{len(selected)}张手牌放回牌库底。")
        drawn = player.draw_cards(len(selected))
        self.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
        return ActionResult(
            True,
            f"放回{len(selected)}张并抽取了{len(drawn)}张。",
            cards_drawn=drawn,
        )

    def _resolve_hand_to_bottom_draw_until_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        target = int(continuation.get("target_hand_size", 5) or 5)
        player = self.state.get_player(player_idx)
        selected = self._take_selected_cards_from_zone(player, "hand", choice, 1)
        if selected:
            player.deck.insert(0, selected[0])
        to_draw = max(0, target - len(player.hand))
        drawn = player.draw_cards(to_draw)
        if selected:
            self.state._log(
                f"{player.name}将1张手牌放回牌库底，抽取了{len(drawn)}张。"
            )
        return ActionResult(
            True,
            f"抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )

    def _resolve_zinnia_resolve_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        discard_count = int(continuation.get("discard_count", 2) or 2)
        draw_amount = int(continuation.get("draw_amount", 0) or 0)
        player = self.state.get_player(player_idx)
        discarded = self._take_selected_cards_from_zone(
            player,
            "hand",
            choice,
            discard_count,
        )
        player.discard.extend(discarded)
        self.state._log(f"{player.name}丢弃了{len(discarded)}张手牌（希嘉娜的决心）。")
        drawn = player.draw_cards(draw_amount)
        self.state._log(
            f"{player.name}抽取了{len(drawn)}张卡（对手场上有{draw_amount}只宝可梦）。"
        )
        return ActionResult(
            True,
            f"丢弃{len(discarded)}张手牌，抽取了{len(drawn)}张。",
            cards_drawn=drawn,
            cards_discarded=len(discarded),
        )

    def _resolve_search_cards_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        from_zone = str(continuation.get("from_zone", "deck") or "deck")
        destination = str(continuation.get("destination", "hand") or "hand")
        count = int(continuation.get("count", 1) or 1)
        player = self.state.get_player(player_idx)
        selected = self._take_selected_cards_from_zone(
            player,
            from_zone,
            choice,
            count,
        )
        moved = 0
        for card in selected:
            if destination == "hand":
                player.hand.append(card)
                moved += 1
                continue
            if destination == "bench":
                slot = player.find_empty_bench_slot()
                if slot is None:
                    continue
                pokemon = player.place_bench(card, slot)
                if pokemon is not None:
                    pokemon.placed_this_turn = True
                    moved += 1
        if from_zone == "deck":
            player.shuffle_deck()
        self.state._log(f"{player.name}从{from_zone}选择了{moved}张卡。")
        return ActionResult(True, f"选择了{moved}张卡。")

    def _resolve_search_item_and_tool_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        item_taken = False
        tool_taken = False
        moved = 0
        for selected in list(choice or []):
            card = self._find_selected_card_in_zone(player, "deck", selected)
            if card is None:
                continue
            if getattr(card, "is_trainer_item", False) and not item_taken:
                player.deck.remove(card)
                player.hand.append(card)
                item_taken = True
                moved += 1
                continue
            if getattr(card, "is_trainer_tool", False) and not tool_taken:
                player.deck.remove(card)
                player.hand.append(card)
                tool_taken = True
                moved += 1
        player.shuffle_deck()
        self.state._log(f"{player.name}从牌库选择了{moved}张卡（派帕）。")
        return ActionResult(True, f"选择了{moved}张卡。")

    def _resolve_trekking_shoes_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        confirmed = bool(choice)
        top_card = player.deck[-1] if player.deck else None
        expected_id = str(continuation.get("top_card_id", "") or "")
        if top_card is not None and expected_id:
            if getattr(top_card, "api_id", "") != expected_id:
                return ActionResult(False, "牌库顶卡已变化，无法继续结算。")

        top_name = str(continuation.get("top_card_name", "") or "")
        if confirmed:
            if player.deck:
                card = player.deck.pop()
                player.hand.append(card)
                self.state._log(f"{player.name}将牌库顶的「{card.name}」加入了手牌。")
            return ActionResult(True, "将牌库顶卡加入手牌。")

        if player.deck:
            card = player.deck.pop()
            player.discard.append(card)
            self.state._log(
                f"{player.name}丢弃了牌库顶的「{getattr(card, 'name', top_name)}」。"
            )
        drawn = player.draw_cards(1)
        if drawn:
            self.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
        return ActionResult(
            True,
            f"丢弃牌库顶并抽取了{len(drawn)}张。",
            cards_drawn=drawn,
        )

    def _resolve_look_top_deck_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionRequest, ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        take = int(continuation.get("take", 1) or 1)
        destination = str(continuation.get("destination", "hand") or "hand")
        selected_positions = self._selected_top_positions_from_request(
            req,
            continuation,
            choice,
            take,
        )

        if destination == "bench_energy":
            top_cards, error = self._peek_expected_top_cards(player, continuation)
            if error:
                return ActionResult(False, error)
            selected_cards = [
                top_cards[index]
                for index in selected_positions
                if 0 <= index < len(top_cards)
            ]
            bench_pokes = [
                (index, pokemon)
                for index, pokemon in enumerate(player.bench)
                if pokemon is not None
                and getattr(pokemon.card, "energy_types", None)
                and "Lightning" in pokemon.card.energy_types
            ]
            if selected_cards and not (
                len(bench_pokes) == 1 and len(selected_cards) <= 1
            ) and bench_pokes:
                targets_info = [
                    {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                    for index, pokemon in bench_pokes
                ]
                return ActionRequest(
                    request_type="distribute_energy",
                    player=player_idx,
                    prompt="分配能量 — 电气发生器",
                    card_list=selected_cards,
                    target_info=targets_info,
                    distribute_mode="distribute",
                    min_select=len(selected_cards),
                    max_select=len(selected_cards),
                    source_name="电气发生器",
                    continuation={
                        "kind": "look_top_bench_energy_distribution",
                        "player_idx": player_idx,
                        "top_card_ids": list(continuation.get("top_card_ids", []) or []),
                        "selected_top_positions": selected_positions,
                        "rest_bottom": bool(continuation.get("rest_bottom", True)),
                        "shuffle_rest": bool(continuation.get("shuffle_rest", False)),
                    },
                )

            top_cards, error = self._pop_expected_top_cards(player, continuation)
            if error:
                return ActionResult(False, error)
            selected_cards = self._return_top_cards_except_selected(
                player,
                top_cards,
                selected_positions,
                rest_bottom=bool(continuation.get("rest_bottom", True)),
                shuffle_rest=bool(continuation.get("shuffle_rest", False)),
            )
            self.state._log(
                f"{player.name}查看了牌库顶{len(top_cards)}张卡，选择了{len(selected_cards)}张。"
            )
            return self._attach_lightning_energy_to_bench(
                player_idx,
                selected_cards,
            )

        top_cards, error = self._pop_expected_top_cards(player, continuation)
        if error:
            return ActionResult(False, error)
        selected_cards = self._return_top_cards_except_selected(
            player,
            top_cards,
            selected_positions,
            rest_bottom=bool(continuation.get("rest_bottom", True)),
            shuffle_rest=bool(continuation.get("shuffle_rest", False)),
        )
        for card in selected_cards:
            player.hand.append(card)
            self.state._log(f"{player.name}将{card.name}加入手牌。")
        self.state._log(
            f"{player.name}查看了牌库顶{len(top_cards)}张卡，选择了{len(selected_cards)}张。"
        )
        return ActionResult(True, f"选择了{len(selected_cards)}张卡。")

    def _resolve_detached_energy_distribution_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        source_cards = list(getattr(req, "card_list", []) or [])
        assignments = self._normalize_energy_assignments(choice)
        attached = 0
        for energy_index, target_slot in assignments:
            if energy_index < 0 or energy_index >= len(source_cards):
                continue
            target = player.get_pokemon(target_slot)
            if target is None:
                continue
            card = source_cards[energy_index]
            target.energy_cards.append(card)
            attached += 1
            self.state._log(f"将{card.name}附着于备战区{target.card.name}。")
        return ActionResult(True, f"附着了{attached}张能量。")

    def _resolve_look_top_bench_energy_distribution_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        top_cards, error = self._pop_expected_top_cards(player, continuation)
        if error:
            return ActionResult(False, error)
        selected_positions = [
            int(index)
            for index in continuation.get("selected_top_positions", []) or []
        ]
        selected_cards = self._return_top_cards_except_selected(
            player,
            top_cards,
            selected_positions,
            rest_bottom=bool(continuation.get("rest_bottom", True)),
            shuffle_rest=bool(continuation.get("shuffle_rest", False)),
        )
        source_cards = list(getattr(req, "card_list", []) or selected_cards)
        assignments = self._normalize_energy_assignments(choice)
        attached = 0
        for energy_index, target_slot in assignments:
            if energy_index < 0 or energy_index >= len(source_cards):
                continue
            card = self._resolve_source_card(selected_cards, source_cards[energy_index])
            if card is None:
                continue
            target = player.get_pokemon(target_slot)
            if target is None:
                continue
            target.energy_cards.append(card)
            selected_cards.remove(card)
            attached += 1
            self.state._log(f"将{card.name}附着于备战区{target.card.name}。")
        return ActionResult(True, f"附着了{attached}张能量。")

    def _resolve_look_top_attach_energy_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionRequest, ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        take = int(continuation.get("take", 99) or 99)
        selected_positions = self._selected_top_positions_from_request(
            req,
            continuation,
            choice,
            take,
        )
        targets = [
            (slot, pokemon)
            for slot, pokemon in player.get_all_pokemon()
            if pokemon is not None
        ]
        if selected_positions and len(targets) > 1:
            return ActionRequest(
                request_type="search_deck",
                player=player_idx,
                prompt=f"选择1只宝可梦附着{len(selected_positions)}张能量。",
                min_select=1,
                max_select=1,
                from_zone="board",
                target_player="self",
                card_list=[pokemon.card for _slot, pokemon in targets],
                continuation={
                    "kind": "look_top_attach_target",
                    "player_idx": player_idx,
                    "top_card_ids": list(continuation.get("top_card_ids", []) or []),
                    "selected_top_positions": selected_positions,
                },
            )

        top_cards, error = self._pop_expected_top_cards(player, continuation)
        if error:
            return ActionResult(False, error)
        selected_cards = self._return_top_cards_except_selected(
            player,
            top_cards,
            selected_positions,
            rest_bottom=False,
            shuffle_rest=True,
        )
        if not selected_cards:
            self.state._log(f"{player.name}查看了牌库顶{len(top_cards)}张卡，没有选择能量。")
            return ActionResult(True, "未选择能量。")
        if not targets:
            return ActionResult(False, "没有宝可梦可附着能量。")
        target = targets[0][1]
        for card in selected_cards:
            target.energy_cards.append(card)
        self.state._log(f"将{len(selected_cards)}张能量附着于{target.card.name}。")
        return ActionResult(True, f"附着了{len(selected_cards)}张能量。")

    def _resolve_look_top_attach_target_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        _slot_name, target = self._resolve_board_choice(player_idx, choice)
        if target is None:
            return ActionResult(False, "没有有效附着目标。")

        top_cards, error = self._pop_expected_top_cards(player, continuation)
        if error:
            return ActionResult(False, error)
        selected_positions = [
            int(index)
            for index in continuation.get("selected_top_positions", []) or []
        ]
        selected_cards = self._return_top_cards_except_selected(
            player,
            top_cards,
            selected_positions,
            rest_bottom=False,
            shuffle_rest=True,
        )
        for card in selected_cards:
            target.energy_cards.append(card)
        self.state._log(f"将{len(selected_cards)}张能量附着于{target.card.name}。")
        return ActionResult(True, f"附着了{len(selected_cards)}张能量。")

    def _resolve_draw_and_attach_energy_distribution_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        return self._resolve_energy_distribution_continuation(
            player_idx=int(continuation.get("player_idx", 0) or 0),
            source_zone="hand",
            source_cards=list(getattr(req, "card_list", []) or []),
            choice=choice,
            max_per_target=int(continuation.get("max_per_target", 99) or 99),
            same_target=bool(continuation.get("same_target", True)),
            zone_name="手牌",
        )

    def _resolve_attach_energy_distribution_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        source_zone = str(continuation.get("source_zone", "hand") or "hand")
        zone_name = str(
            continuation.get("zone_name", "")
            or ("手牌" if source_zone == "hand" else "牌库")
        )
        return self._resolve_energy_distribution_continuation(
            player_idx=int(continuation.get("player_idx", 0) or 0),
            source_zone=source_zone,
            source_cards=list(getattr(req, "card_list", []) or []),
            choice=choice,
            max_per_target=int(continuation.get("max_per_target", 99) or 99),
            same_target=bool(continuation.get("same_target", False)),
            zone_name=zone_name,
        )

    def _resolve_attach_energy_to_bench_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        if choice is None:
            return ActionResult(True, "未选择附能目标。")
        try:
            bench_idx = int(choice)
        except (TypeError, ValueError):
            return ActionResult(False, "没有有效附能目标。")

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        target = player.get_pokemon(f"bench_{bench_idx}")
        return self._attach_energy_to_target(
            player_idx=player_idx,
            source_zone=str(continuation.get("source_zone", "hand") or "hand"),
            zone_name=str(continuation.get("zone_name", "") or "手牌"),
            filter_type=str(continuation.get("filter_type", "any") or "any"),
            amount=int(continuation.get("amount", 1) or 1),
            target=target,
            optional=bool(continuation.get("optional", False)),
        )

    def _resolve_attach_energy_to_board_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        _slot_name, target = self._resolve_board_choice(player_idx, choice)
        if target is None:
            return ActionResult(False, "没有有效附能目标。")
        return self._attach_energy_to_target(
            player_idx=player_idx,
            source_zone=str(continuation.get("source_zone", "hand") or "hand"),
            zone_name=str(continuation.get("zone_name", "") or "手牌"),
            filter_type=str(continuation.get("filter_type", "any") or "any"),
            amount=int(continuation.get("amount", 1) or 1),
            target=target,
            optional=bool(continuation.get("optional", False)),
        )

    def _resolve_attach_discard_energy_distribution_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        return self._resolve_energy_distribution_continuation(
            player_idx=int(continuation.get("player_idx", 0) or 0),
            source_zone="discard",
            source_cards=list(getattr(req, "card_list", []) or []),
            choice=choice,
            max_per_target=int(continuation.get("max_per_target", 99) or 99),
            same_target=bool(continuation.get("same_target", False)),
            zone_name="弃牌区",
        )

    def _resolve_attach_discard_energy_to_bench_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        if choice is None:
            return ActionResult(True, "未选择附能目标。")
        try:
            bench_idx = int(choice)
        except (TypeError, ValueError):
            return ActionResult(True, "未选择有效目标。")

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        target = player.get_pokemon(f"bench_{bench_idx}")
        if target is None:
            return ActionResult(True, "未选择有效目标。")
        return self._attach_discard_energy_to_target(
            player_idx=player_idx,
            count=int(continuation.get("count", 1) or 1),
            target=target,
            energy_type=str(continuation.get("energy_type", "any") or "any"),
        )

    def _resolve_attach_discard_energy_to_board_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        _slot_name, target = self._resolve_board_choice(player_idx, choice)
        if target is None:
            return ActionResult(False, "没有有效附能目标。")
        return self._attach_discard_energy_to_target(
            player_idx=player_idx,
            count=int(continuation.get("count", 1) or 1),
            target=target,
            energy_type=str(continuation.get("energy_type", "any") or "any"),
        )

    def _resolve_energy_distribution_continuation(
        self,
        *,
        player_idx: int,
        source_zone: str,
        source_cards: list,
        choice,
        max_per_target: int,
        same_target: bool,
        zone_name: str,
    ):
        from engine.game_state import ActionResult

        player = self.state.get_player(player_idx)
        source_pool = self._energy_source_pool(player, source_zone)
        assignments = self._normalize_energy_assignments(choice)
        forced_slot = assignments[0][1] if same_target and assignments else ""
        attached_count = 0
        per_target: dict[str, int] = {}

        for energy_index, target_slot in assignments:
            if energy_index < 0 or energy_index >= len(source_cards):
                continue
            final_slot = forced_slot or target_slot
            if not final_slot or per_target.get(final_slot, 0) >= max_per_target:
                continue
            target = player.get_pokemon(final_slot)
            if target is None:
                continue
            card = self._resolve_source_card(source_pool, source_cards[energy_index])
            if card is None:
                continue
            source_pool.remove(card)
            target.energy_cards.append(card)
            per_target[final_slot] = per_target.get(final_slot, 0) + 1
            attached_count += 1

        if source_zone != "hand" and source_zone != "discard":
            player.shuffle_deck()
        self.state._log(f"从{zone_name}附着了{attached_count}个能量。")
        return ActionResult(True, f"附着了{attached_count}个能量。")

    def _attach_energy_to_target(
        self,
        *,
        player_idx: int,
        source_zone: str,
        zone_name: str,
        filter_type: str,
        amount: int,
        target,
        optional: bool,
    ):
        from engine.game_state import ActionResult

        if target is None:
            return (
                ActionResult(True, "无目标宝可梦。")
                if optional
                else ActionResult(False, "没有目标宝可梦。")
            )
        player = self.state.get_player(player_idx)
        source_pool = self._energy_source_pool(player, source_zone)
        matching = [
            card
            for card in source_pool
            if self._energy_card_matches(card, filter_type)
        ]
        if not matching and optional:
            return ActionResult(True, f"{zone_name}中无匹配的能量。")

        attached = 0
        for card in list(matching[: min(amount, len(matching))]):
            if card in source_pool:
                source_pool.remove(card)
                target.energy_cards.append(card)
                attached += 1
        if source_zone != "hand" and source_zone != "discard":
            player.shuffle_deck()
        self.state._log(f"从{zone_name}向{target.card.name}附着了{attached}个能量。")
        return ActionResult(True, f"Attached {attached} energy from {source_zone}.")

    def _attach_discard_energy_to_target(
        self,
        *,
        player_idx: int,
        count: int,
        target,
        energy_type: str,
    ):
        from engine.game_state import ActionResult

        player = self.state.get_player(player_idx)
        matching = self._matching_discard_energy(player.discard, energy_type)
        attached = 0
        for card in list(matching[:count]):
            if card in player.discard:
                player.discard.remove(card)
                target.energy_cards.append(card)
                attached += 1
        self.state._log(f"从弃牌区将{attached}个{energy_type}能量附着于{target.card.name}。")
        return ActionResult(True, f"从弃牌区附着了{attached}个能量。")

    @staticmethod
    def _energy_source_pool(player, source_zone: str):
        if source_zone == "hand":
            return player.hand
        if source_zone == "discard":
            return player.discard
        return player.deck

    @staticmethod
    def _normalize_energy_assignments(choice) -> list[tuple[int, str]]:
        assignments: list[tuple[int, str]] = []
        for fallback_index, item in enumerate(list(choice or [])):
            if isinstance(item, (list, tuple)) and len(item) >= 2:
                try:
                    energy_index = int(item[0])
                except (TypeError, ValueError):
                    continue
                assignments.append((energy_index, str(item[1] or "")))
                continue
            slot = str(getattr(item, "slot", "") or "")
            if not slot and isinstance(item, dict):
                slot = str(item.get("slot", "") or "")
            if slot:
                assignments.append((fallback_index, slot))
        return assignments

    @staticmethod
    def _resolve_source_card(source_pool: list, selected):
        if selected in source_pool:
            return selected
        selected_id = getattr(selected, "api_id", "")
        if not selected_id:
            return None
        for card in source_pool:
            if getattr(card, "api_id", "") == selected_id:
                return card
        return None

    @staticmethod
    def _energy_card_matches(card, energy_type: str) -> bool:
        normalized = str(energy_type or "any").lower()
        if not getattr(card, "is_energy", False):
            return False
        if normalized in {"any", "energy"}:
            return True
        if normalized in {"basic", "basic_energy"}:
            return bool(getattr(card, "is_basic_energy", False))
        return any(
            str(provided).lower() == normalized
            for provided in getattr(card, "provides_energy", [])
        )

    @staticmethod
    def _matching_discard_energy(discard: list, energy_type: str) -> list:
        normalized = str(energy_type or "any").lower()
        return [
            card
            for card in discard
            if getattr(card, "is_basic_energy", False)
            and (
                normalized in {"any", "basic", "basic_energy"}
                or any(
                    str(provided).lower() == normalized
                    for provided in getattr(card, "provides_energy", [])
                )
            )
        ]

    def _resolve_energy_relocate_source_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionRequest, ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        assignments = self._normalize_energy_assignments(choice)
        if not assignments:
            return ActionResult(True, "未选择来源宝可梦。")
        _energy_index, source_slot = assignments[0]
        source = player.get_pokemon(source_slot)
        energy_type = str(continuation.get("energy_type", "any") or "any")
        matching_source = (
            [
                card
                for card in source.energy_cards
                if self._energy_card_matches(card, energy_type)
            ]
            if source is not None else []
        )
        if source is None or not matching_source:
            return ActionResult(True, "来源宝可梦没有可转附能量。")

        amount = int(continuation.get("amount", 1) or 1)
        move_count = min(amount, len(matching_source))
        optional_count = bool(continuation.get("optional_count", False))
        raw_min_select = continuation.get("min_select", None)
        if raw_min_select is None:
            min_move = 0 if optional_count else move_count
        else:
            min_move = int(raw_min_select or 0)
        min_move = min(move_count, max(0, min_move))
        targets_info = []
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon is not None and pokemon is not source:
                targets_info.append({
                    "slot": slot_name,
                    "name": pokemon.card.name,
                    "bench_idx": int(slot_name.split("_")[1]) if slot_name.startswith("bench_") else -1,
                })
        if not targets_info:
            return ActionResult(True, "没有目标宝可梦可转附能量。")
        return ActionRequest(
            request_type="distribute_energy",
            player=player_idx,
            prompt=f"分配能量 — {source.card.name}",
            card_list=list(matching_source[:move_count]),
            target_info=targets_info,
            distribute_mode="paired",
            min_select=min_move,
            max_select=move_count,
            max_per_target=move_count,
            source_name=source.card.name,
            continuation={
                "kind": "energy_relocate_distribution",
                "player_idx": player_idx,
                "source_slot": source_slot,
                "max_per_target": move_count,
                "same_target": bool(continuation.get("same_target", False)),
            },
        )

    def _resolve_energy_relocate_distribution_continuation(
        self,
        req,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        source_slot = str(continuation.get("source_slot", "") or "")
        source = player.get_pokemon(source_slot)
        if source is None:
            return ActionResult(False, "来源宝可梦已不存在。")
        source_cards = list(getattr(req, "card_list", []) or [])
        assignments = self._normalize_energy_assignments(choice)
        forced_slot = assignments[0][1] if bool(continuation.get("same_target", False)) and assignments else ""
        moved = 0
        for energy_index, target_slot in assignments:
            if energy_index < 0 or energy_index >= len(source_cards):
                continue
            card = self._resolve_source_card(source.energy_cards, source_cards[energy_index])
            if card is None:
                continue
            target = player.get_pokemon(forced_slot or target_slot)
            if target is None:
                continue
            source.energy_cards.remove(card)
            target.energy_cards.append(card)
            moved += 1
        self.state._log(f"将{moved}个能量从{source.card.name}转附。")
        return ActionResult(True, f"转附了{moved}个能量。")

    def _resolve_search_any_and_switch_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionRequest, ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        count = int(continuation.get("count", 2) or 2)
        player = self.state.get_player(player_idx)
        selected = self._take_selected_cards_from_zone(player, "deck", choice, count)
        for card in selected:
            player.hand.append(card)
        player.shuffle_deck()
        self.state._log(f"{player.name}从牌库选择了{len(selected)}张卡。")
        if not bool(continuation.get("switch_optional", True)):
            return ActionResult(True, f"选择了{len(selected)}张卡。")
        bench_indices = [
            index
            for index, pokemon in enumerate(player.bench)
            if pokemon is not None
        ]
        if not bench_indices:
            return ActionResult(True, f"选择了{len(selected)}张卡。")
        return ActionRequest(
            request_type="confirm",
            player=player_idx,
            prompt="是否替换战斗宝可梦？",
            continuation={
                "kind": "search_any_switch_confirm",
                "player_idx": player_idx,
                "bench_indices": bench_indices,
            },
        )

    def _resolve_search_any_switch_confirm_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionRequest, ActionResult

        if not bool(choice):
            return ActionResult(True, "未替换宝可梦。")
        player_idx = int(continuation.get("player_idx", 0) or 0)
        player = self.state.get_player(player_idx)
        bench_indices = []
        for index in continuation.get("bench_indices", []) or []:
            try:
                bench_idx = int(index)
            except (TypeError, ValueError):
                continue
            if 0 <= bench_idx < len(player.bench) and player.bench[bench_idx] is not None:
                bench_indices.append(bench_idx)
        if not bench_indices:
            return ActionResult(True, "没有备战宝可梦可替换。")
        if len(bench_indices) == 1:
            player.switch_active_to_bench(bench_indices[0])
            return ActionResult(True, "替换了战斗宝可梦。")
        return ActionRequest(
            request_type="select_bench",
            player=player_idx,
            prompt="选择替换战斗区的宝可梦。",
            min_select=1,
            max_select=1,
            bench_indices=bench_indices,
            continuation={
                "kind": "search_any_switch_bench",
                "player_idx": player_idx,
                "bench_indices": bench_indices,
            },
        )

    def _resolve_search_any_switch_bench_continuation(
        self,
        continuation: dict,
        choice,
    ):
        from engine.game_state import ActionResult

        player_idx = int(continuation.get("player_idx", 0) or 0)
        try:
            bench_idx = int(choice)
        except (TypeError, ValueError):
            return ActionResult(False, "没有选择有效的备战宝可梦。")
        allowed = {
            int(index)
            for index in continuation.get("bench_indices", []) or []
        }
        if allowed and bench_idx not in allowed:
            return ActionResult(False, "选择的备战宝可梦不在可用范围内。")
        player = self.state.get_player(player_idx)
        if bench_idx < 0 or bench_idx >= len(player.bench) or player.bench[bench_idx] is None:
            return ActionResult(False, "选择的备战宝可梦已不存在。")
        player.switch_active_to_bench(bench_idx)
        return ActionResult(True, "替换了战斗宝可梦。")

    def _selected_top_positions_from_request(
        self,
        req,
        continuation: dict,
        choice,
        limit: int,
    ) -> list[int]:
        display_positions = [
            int(index)
            for index in continuation.get("display_top_positions", []) or []
        ]
        request_indices = self._selected_card_indices_from_request(
            list(getattr(req, "card_list", []) or []),
            choice,
            limit,
        )
        selected_positions = []
        for request_index in request_indices:
            if 0 <= request_index < len(display_positions):
                selected_positions.append(display_positions[request_index])
        return selected_positions

    @staticmethod
    def _selected_card_indices_from_request(
        available: list,
        choice,
        limit: int,
    ) -> list[int]:
        selected_items = list(choice or [])[: max(0, int(limit or 0))]
        used: set[int] = set()
        indices = []
        for selected in selected_items:
            matched = -1
            for index, candidate in enumerate(available):
                if index in used:
                    continue
                if candidate is selected:
                    matched = index
                    break
            if matched < 0:
                selected_id = getattr(selected, "api_id", "")
                if selected_id:
                    for index, candidate in enumerate(available):
                        if index in used:
                            continue
                        if getattr(candidate, "api_id", "") == selected_id:
                            matched = index
                            break
            if matched >= 0:
                used.add(matched)
                indices.append(matched)
        return indices

    def _peek_expected_top_cards(self, player, continuation: dict):
        expected_ids = [
            str(card_id)
            for card_id in continuation.get("top_card_ids", []) or []
        ]
        count = len(expected_ids) or int(continuation.get("count", 0) or 0)
        if len(player.deck) < count:
            return [], "牌库顶卡已变化，无法继续结算。"
        top_cards = [player.deck[-1 - index] for index in range(count)]
        if expected_ids and [
            getattr(card, "api_id", "")
            for card in top_cards
        ] != expected_ids:
            return [], "牌库顶卡已变化，无法继续结算。"
        return top_cards, ""

    def _pop_expected_top_cards(self, player, continuation: dict):
        top_cards, error = self._peek_expected_top_cards(player, continuation)
        if error:
            return [], error
        for _card in top_cards:
            player.deck.pop()
        return top_cards, ""

    @staticmethod
    def _return_top_cards_except_selected(
        player,
        top_cards: list,
        selected_positions: list[int],
        *,
        rest_bottom: bool,
        shuffle_rest: bool,
    ) -> list:
        from collections import Counter

        selected_counter = Counter(int(index) for index in selected_positions)
        selected_cards = []
        rest = []
        for index, card in enumerate(top_cards):
            if selected_counter.get(index, 0) > 0:
                selected_counter[index] -= 1
                selected_cards.append(card)
            else:
                rest.append(card)
        if shuffle_rest:
            player.deck.extend(rest)
            player.shuffle_deck()
        else:
            for card in rest:
                if rest_bottom:
                    player.deck.insert(0, card)
                else:
                    player.deck.append(card)
        return selected_cards

    def _attach_lightning_energy_to_bench(
        self,
        player_idx: int,
        selected_cards: list,
    ):
        from engine.game_state import ActionResult

        player = self.state.get_player(player_idx)
        if not selected_cards:
            return ActionResult(True, "未选择能量。")
        bench_pokes = [
            (index, pokemon)
            for index, pokemon in enumerate(player.bench)
            if pokemon is not None
            and getattr(pokemon.card, "energy_types", None)
            and "Lightning" in pokemon.card.energy_types
        ]
        if not bench_pokes:
            player.deck.extend(selected_cards)
            player.shuffle_deck()
            self.state._log("备战区没有雷属性宝可梦可附着能量。")
            return ActionResult(True, "备战区没有雷属性宝可梦可附着能量。")
        _index, bench_pokemon = bench_pokes[0]
        for card in selected_cards:
            bench_pokemon.energy_cards.append(card)
        self.state._log(f"将{len(selected_cards)}张能量附着于备战区{bench_pokemon.card.name}。")
        return ActionResult(True, f"附着了{len(selected_cards)}张能量。")

    def _take_selected_cards_from_zone(
        self,
        player,
        zone_name: str,
        choice,
        limit: int,
    ) -> list:
        taken = []
        for selected in list(choice or [])[: max(0, int(limit or 0))]:
            card = self._take_one_selected_card_from_zone(
                player,
                zone_name,
                selected,
            )
            if card is not None:
                taken.append(card)
        return taken

    @staticmethod
    def _take_one_selected_card_from_zone(player, zone_name: str, selected):
        card = ResolutionStack._find_selected_card_in_zone(
            player,
            zone_name,
            selected,
        )
        if card is None:
            return None
        getattr(player, zone_name).remove(card)
        return card

    @staticmethod
    def _find_selected_card_in_zone(player, zone_name: str, selected):
        zone = getattr(player, zone_name, None)
        if not isinstance(zone, list):
            return None
        if selected in zone:
            return selected
        selected_id = getattr(selected, "api_id", "")
        if not selected_id:
            return None
        for card in zone:
            if getattr(card, "api_id", "") == selected_id:
                return card
        return None

    def _resolve_board_choice(self, player_idx: int, choice):
        from engine.actions import PokemonRef, resolve_pokemon_ref

        player = self.state.get_player(player_idx)
        for item in list(choice or []):
            if isinstance(item, PokemonRef):
                pokemon = resolve_pokemon_ref(self.state, item)
                if pokemon is not None and item.player == player_idx:
                    return item.slot, pokemon
                continue
            selected_id = getattr(item, "api_id", "")
            if not selected_id:
                continue
            for slot_name, pokemon in player.get_all_pokemon():
                if pokemon is None:
                    continue
                if getattr(pokemon.card, "api_id", "") == selected_id:
                    return slot_name, pokemon
        return "", None

    @staticmethod
    def _merge_callback_results(first, second):
        if first is None:
            return second
        if second is None:
            return first
        from engine.game_state import ActionRequest, ActionResult

        if isinstance(first, ActionResult) and isinstance(second, ActionResult):
            return ResolutionStack._merge_action_results(first, second)
        if isinstance(second, ActionRequest):
            return second
        return first

    def _continue_after_callback_result(
        self,
        original_result,
        player_idx: int,
        source_slot: str,
    ):
        from engine.game_state import ActionRequest, ActionResult

        if isinstance(original_result, ActionRequest):
            return self._wrap_pending_choice(
                original_result, player_idx, source_slot
            )

        if isinstance(original_result, ActionResult):
            if original_result.pending_action:
                original_result.pending_action = self._wrap_pending_choice(
                    original_result.pending_action, player_idx, source_slot
                )
                return original_result
            if not original_result.success:
                return original_result

        if not self._stack:
            return original_result

        continuation = self._to_action_result(
            self.resume_after_choice(player_idx, source_slot)
        )
        if isinstance(original_result, ActionResult):
            return self._merge_action_results(original_result, continuation)
        return continuation

    @staticmethod
    def _to_action_result(rr: ResolutionResult):
        from engine.game_state import ActionResult

        return ActionResult(
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

    @staticmethod
    def _merge_action_results(first, second):
        if second.log_message:
            first.log_message = (
                f"{first.log_message} {second.log_message}".strip()
                if first.log_message else second.log_message
            )
        first.success = first.success and second.success
        first.damage_dealt += second.damage_dealt
        first.cards_drawn.extend(second.cards_drawn)
        first.cards_discarded += second.cards_discarded
        first.pokemon_ko.extend(second.pokemon_ko)
        first.status_applied.extend(second.status_applied)
        first.attack_failed = first.attack_failed or second.attack_failed
        if second.pending_action:
            first.pending_action = second.pending_action
        return first

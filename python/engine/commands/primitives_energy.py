"""Energy attachment and relocation VM primitive commands."""
from __future__ import annotations

from dataclasses import dataclass, field

from engine.commands.base import CommandResult, ResolutionContext


@dataclass
class DrawAndAttachEnergy:
    """Draw cards, then optionally attach matching basic energy from hand to bench."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        energy_count = int(self.params.get("energy_count", 2) or 2)
        energy_type = str(self.params.get("energy_type", "Grass") or "Grass")

        drawn = player.draw_cards(2)
        drawn_count = len(drawn)
        ctx.state._log(f"{player.name}抽取了{drawn_count}张卡。")

        matching_energy = [
            card
            for card in player.hand
            if getattr(card, "is_basic_energy", False)
            and energy_type in str(getattr(card, "provides_energy", []))
        ]
        if not matching_energy:
            return CommandResult.ok(
                f"抽了{drawn_count}张，但手牌中没有G能量可附着。",
                cards_drawn=drawn,
            )

        bench_slots = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
        if not bench_slots:
            return CommandResult.ok(
                f"抽了{drawn_count}张，但备战区没有宝可梦。",
                cards_drawn=drawn,
            )

        max_attach = min(energy_count, len(matching_energy))
        min_attach = min(int(self.params.get("min_select", max_attach) or 0), max_attach)

        if len(bench_slots) == 1 and min_attach == max_attach and max_attach <= energy_count:
            _idx, bench_pokemon = bench_slots[0]
            attached = 0
            for card in matching_energy[:max_attach]:
                player.hand.remove(card)
                bench_pokemon.energy_cards.append(card)
                attached += 1
            ctx.state._log(f"将{attached}张G能量附着于备战区{bench_pokemon.card.name}。")
            return CommandResult.ok(
                f"抽了{drawn_count}张，附着了{attached}张G能量。",
                cards_drawn=drawn,
            )

        energy_to_distribute = matching_energy[:max_attach]
        targets_info = [
            {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
            for index, pokemon in bench_slots
        ]

        return CommandResult.ok(
            f"选择最多{max_attach}张G能量分配到备战宝可梦。",
            cards_drawn=drawn,
            pending_choice=ActionRequest(
                request_type="distribute_energy",
                player=ctx.player_idx,
                prompt="分配能量 — 菜种的活力",
                card_list=energy_to_distribute,
                target_info=targets_info,
                distribute_mode="distribute",
                min_select=min_attach,
                max_select=max_attach,
                max_per_target=max_attach,
                source_name="菜种的活力",
                continuation={
                    "kind": "draw_and_attach_energy_distribution",
                    "player_idx": ctx.player_idx,
                    "max_per_target": max_attach,
                    "same_target": True,
                    "energy_type": energy_type,
                },
            ),
        )


@dataclass
class EnergyAttach:
    """Attach matching energy from hand/deck to legal targets."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        amount = int(self.params.get("amount", 1) or 1)
        base_amount = amount
        from_zone = str(self.params.get("from_zone", "hand") or "hand")
        filter_type = str(self.params.get("filter", "any") or "any")
        to_target = str(self.params.get("to", "self") or "self")
        optional = bool(self.params.get("optional", False))
        max_per_target = int(self.params.get("max_per_target", 99) or 99)
        bonus_applied = False

        going_second_bonus = int(self.params.get("going_second_bonus", 0) or 0)
        if going_second_bonus > 0 and ctx.state.is_going_second_first_turn(ctx.player_idx):
            amount = going_second_bonus
            bonus_applied = amount > base_amount
            ctx.state._log(f"后攻最初回合！可附着最多{amount}张能量。")

        optional_count = bool(optional or bonus_applied or "min_select" in self.params)
        min_attach = int(self.params.get("min_select", 0 if optional_count else 1) or 0)
        source_pool, zone_name = self._energy_source(player, from_zone)
        if not self._matching_energy_cards(source_pool, filter_type):
            return CommandResult.ok(f"{zone_name}中无匹配的能量。")

        def distribution(energy_cards, targets_info, *, min_select, max_select, max_per_target=99, same_target=False):
            max_select = min(max(0, int(max_select)), len(energy_cards))
            min_select = min(max_select, max(0, int(min_select)))
            if max_select <= 0:
                return CommandResult.ok(f"{zone_name}中无匹配的能量。")

            return CommandResult.ok(
                f"选择最多{max_select}个能量附着。",
                pending_choice=ActionRequest(
                    request_type="distribute_energy",
                    player=ctx.player_idx,
                    prompt=f"分配能量 — {zone_name}",
                    card_list=list(energy_cards[:max_select]),
                    target_info=targets_info,
                    distribute_mode="distribute",
                    min_select=min_select,
                    max_select=max_select,
                    max_per_target=max_per_target,
                    source_name=zone_name,
                    continuation={
                        "kind": "energy_attach_distribution",
                        "player_idx": ctx.player_idx,
                        "source_zone": from_zone,
                        "zone_name": zone_name,
                        "max_per_target": max_per_target,
                        "same_target": same_target,
                    },
                ),
            )

        def attach_to_target(target, amount_to_attach=amount):
            if target is None:
                if optional:
                    return CommandResult.ok("无目标宝可梦。")
                return CommandResult.fail("没有目标宝可梦。")
            if optional_count:
                matching = self._matching_energy_cards(source_pool, filter_type)
                energy_to_distribute = matching[:min(amount_to_attach, len(matching))]
                target_slot = self._slot_for_pokemon(player, target)
                return distribution(
                    energy_to_distribute,
                    [{"slot": target_slot, "name": target.card.name}],
                    min_select=min_attach,
                    max_select=len(energy_to_distribute),
                    max_per_target=amount_to_attach,
                    same_target=True,
                )
            return self._attach_immediate(ctx, source_pool, zone_name, from_zone, filter_type, amount_to_attach, target)

        if to_target == "self":
            return attach_to_target(player.get_pokemon(ctx.source_slot), amount)

        if to_target == "bench":
            bench_slots = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
            if not bench_slots:
                return CommandResult.ok("备战区无宝可梦。") if optional else CommandResult.fail("备战区没有宝可梦可附着能量。")
            if len(bench_slots) == 1:
                target_slot = f"bench_{bench_slots[0][0]}"
                target = player.get_pokemon(target_slot)
                if optional_count:
                    matching = self._matching_energy_cards(source_pool, filter_type)
                    energy_to_distribute = matching[:min(min(amount, max_per_target), len(matching))]
                    return distribution(
                        energy_to_distribute,
                        [{"slot": target_slot, "name": target.card.name, "bench_idx": bench_slots[0][0]}],
                        min_select=min_attach,
                        max_select=len(energy_to_distribute),
                        max_per_target=max_per_target,
                    )
                return attach_to_target(target, min(amount, max_per_target))
            if amount <= 1:
                return CommandResult.ok(
                    "选择备战宝可梦附着能量。",
                    pending_choice=ActionRequest(
                        request_type="select_own_bench_energy",
                        player=ctx.player_idx,
                        prompt="选择1只备战宝可梦附着能量。",
                        min_select=0 if optional_count else 1,
                        max_select=1,
                        bench_indices=[index for index, _pokemon in bench_slots],
                        can_cancel=optional_count,
                        continuation={
                            "kind": "attach_energy_to_bench",
                            "player_idx": ctx.player_idx,
                            "source_zone": from_zone,
                            "zone_name": zone_name,
                            "filter_type": filter_type,
                            "amount": amount,
                            "optional": optional,
                        },
                    ),
                )
            matching = self._matching_energy_cards(source_pool, filter_type)
            targets_info = [
                {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                for index, pokemon in bench_slots
            ]
            capacity = max(0, len(targets_info) * max_per_target)
            energy_to_distribute = matching[:min(amount, capacity)]
            return distribution(
                energy_to_distribute,
                targets_info,
                min_select=min_attach if optional_count else len(energy_to_distribute),
                max_select=len(energy_to_distribute),
                max_per_target=max_per_target,
            )

        if to_target in {"any", "self_basic"}:
            candidates = []
            for slot_name, pokemon in player.get_all_pokemon():
                if pokemon is None:
                    continue
                if to_target == "self_basic" and not pokemon.card.is_basic_pokemon:
                    continue
                candidates.append((slot_name, pokemon))
            if not candidates:
                message = "没有基础宝可梦可附着能量。" if to_target == "self_basic" else "场上没有宝可梦可附着能量。"
                return CommandResult.ok(message) if optional else CommandResult.fail(message)
            if len(candidates) == 1:
                return attach_to_target(candidates[0][1], amount)
            if optional_count:
                matching = self._matching_energy_cards(source_pool, filter_type)
                energy_to_distribute = matching[:min(amount, len(matching))]
                return distribution(
                    energy_to_distribute,
                    [{"slot": slot_name, "name": pokemon.card.name} for slot_name, pokemon in candidates],
                    min_select=min_attach,
                    max_select=len(energy_to_distribute),
                    max_per_target=amount,
                    same_target=True,
                )

            return CommandResult.ok(
                "选择1只宝可梦附着能量。",
                pending_choice=ActionRequest(
                    request_type="search_deck",
                    player=ctx.player_idx,
                    prompt="选择1只宝可梦附着能量。",
                    min_select=1,
                    max_select=1,
                    from_zone="board",
                    target_player="self",
                    card_list=[pokemon.card for _slot_name, pokemon in candidates],
                    continuation={
                        "kind": "attach_energy_to_board",
                        "player_idx": ctx.player_idx,
                        "source_zone": from_zone,
                        "zone_name": zone_name,
                        "filter_type": filter_type,
                        "amount": amount,
                        "optional": optional,
                    },
                ),
            )

        return attach_to_target(player.get_pokemon(to_target), amount)

    @staticmethod
    def _energy_source(player, from_zone: str):
        return (player.hand, "手牌") if from_zone == "hand" else (player.deck, "牌库")

    @staticmethod
    def _matching_energy_cards(source_zone, filter_type: str):
        filter_type = str(filter_type or "any").lower()
        return [
            card for card in source_zone
            if getattr(card, "is_energy", False)
            and (
                filter_type in {"any", "energy"}
                or (filter_type in {"basic", "basic_energy"} and getattr(card, "is_basic_energy", False))
                or any(str(energy_type).lower() == filter_type for energy_type in getattr(card, "provides_energy", []))
            )
        ]

    @staticmethod
    def _slot_for_pokemon(player, target_pokemon):
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon is target_pokemon:
                return slot_name
        return ""

    def _attach_immediate(
        self,
        ctx: ResolutionContext,
        source_pool,
        zone_name: str,
        from_zone: str,
        filter_type: str,
        amount: int,
        target,
        optional: bool = False,
    ) -> CommandResult:
        from engine.commands.base import CommandResult

        if target is None:
            return CommandResult.ok("无目标宝可梦。") if optional else CommandResult.fail("没有目标宝可梦。")
        matching = self._matching_energy_cards(source_pool, filter_type)
        if not matching and optional:
            return CommandResult.ok(f"{zone_name}中无匹配的能量。")
        attached = 0
        trigger_specs = []
        for card in matching[:min(amount, len(matching))]:
            if card in source_pool:
                source_pool.remove(card)
                target.energy_cards.append(card)
                attached += 1
                target_slot = self._slot_for_pokemon(ctx.player, target)
                if target_slot:
                    from engine.commands.trigger_commands import collect_on_attach_command_specs

                    trigger_specs.extend(
                        collect_on_attach_command_specs(
                            card,
                            ctx.player_idx,
                            target_slot,
                            from_zone,
                        )
                    )
        if from_zone == "deck":
            ctx.player.shuffle_deck()
        ctx.state._log(f"从{zone_name}向{target.card.name}附着了{attached}个能量。")
        if trigger_specs:
            from engine.commands.trigger_commands import push_trigger_command_specs

            push_trigger_command_specs(ctx.stack, trigger_specs)
        return CommandResult.ok(f"Attached {attached} energy from {from_zone}.")

    @staticmethod
    def _command_to_action(command_result: CommandResult):
        from engine.game_state import ActionResult

        return ActionResult(
            command_result.success,
            command_result.log_message,
            cards_drawn=command_result.cards_drawn,
            cards_discarded=command_result.cards_discarded,
            pending_action=command_result.pending_choice,
        )


@dataclass
class AttachEnergyFromDiscard:
    """Attach matching basic energy from discard to legal targets."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        amount = int(self.params.get("amount", 1) or 1)
        energy_type = str(self.params.get("energy_type", "any") or "any")
        target_spec = str(self.params.get("target", "self") or "self")
        target_pokemon_type = str(self.params.get("target_pokemon_type", "") or "")
        optional_count = bool("min_select" in self.params or self.params.get("optional", False))

        matching = self._matching_discard_energy(player.discard, energy_type)
        count = min(amount, len(matching))
        min_attach = min(count, int(self.params.get("min_select", count if not optional_count else 0) or 0))
        if count == 0:
            return CommandResult.ok("弃牌区没有符合条件的能量。")

        def request_distribution(
            energy_cards,
            targets_info,
            *,
            min_select,
            max_select,
            max_per_target=99,
            same_target=False,
        ):
            max_select = min(max(0, int(max_select)), len(energy_cards))
            min_select = min(max_select, max(0, int(min_select)))
            if max_select <= 0:
                return CommandResult.ok("弃牌区没有符合条件的能量。")

            return CommandResult.ok(
                f"选择最多{max_select}个能量附着。",
                pending_choice=ActionRequest(
                    request_type="distribute_energy",
                    player=ctx.player_idx,
                    prompt="分配能量 — 弃牌区",
                    card_list=list(energy_cards[:max_select]),
                    target_info=targets_info,
                    distribute_mode="distribute",
                    min_select=min_select,
                    max_select=max_select,
                    max_per_target=max_per_target,
                    source_name="弃牌区",
                    continuation={
                        "kind": "attach_discard_energy_distribution",
                        "player_idx": ctx.player_idx,
                        "max_per_target": max_per_target,
                        "same_target": same_target,
                    },
                ),
            )

        if target_spec == "self":
            target_pokemon = player.active
            if target_pokemon is None:
                return CommandResult.fail("没有战斗宝可梦。")
            if not self._pokemon_matches_target_type(target_pokemon, target_pokemon_type):
                return CommandResult.ok("没有符合条件的附着目标。")
            if optional_count:
                return request_distribution(
                    matching[:count],
                    [{"slot": "active", "name": target_pokemon.card.name}],
                    min_select=min_attach,
                    max_select=count,
                    max_per_target=count,
                    same_target=True,
                )
            return self._attach_immediate(ctx, matching, count, target_pokemon, energy_type)

        if target_spec == "bench":
            bench_slots = [
                (index, pokemon)
                for index, pokemon in enumerate(player.bench)
                if pokemon is not None and self._pokemon_matches_target_type(pokemon, target_pokemon_type)
            ]
            if not bench_slots:
                return CommandResult.ok("备战区无符合条件的宝可梦。")
            if len(bench_slots) == 1:
                bench_index, target_pokemon = bench_slots[0]
                if optional_count:
                    return request_distribution(
                        matching[:count],
                        [{"slot": f"bench_{bench_index}", "name": target_pokemon.card.name, "bench_idx": bench_index}],
                        min_select=min_attach,
                        max_select=count,
                        max_per_target=count,
                    )
                return self._attach_immediate(ctx, matching, count, target_pokemon, energy_type)
            if count <= 1:
                return CommandResult.ok(
                    "选择备战宝可梦附着能量。",
                    pending_choice=ActionRequest(
                        request_type="select_own_bench_energy",
                        player=ctx.player_idx,
                        prompt="选择1只备战宝可梦附着能量。",
                        min_select=0 if optional_count else 1,
                        max_select=1,
                        bench_indices=[index for index, _pokemon in bench_slots],
                        can_cancel=optional_count,
                        continuation={
                            "kind": "attach_discard_energy_to_bench",
                            "player_idx": ctx.player_idx,
                            "count": count,
                            "energy_type": energy_type,
                        },
                    ),
                )
            energy_to_distribute = matching[:count]
            targets_info = [
                {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                for index, pokemon in bench_slots
            ]
            return request_distribution(
                energy_to_distribute,
                targets_info,
                min_select=min_attach if optional_count else len(energy_to_distribute),
                max_select=len(energy_to_distribute),
            )

        if target_spec == "self_or_bench":
            all_pokemon = []
            if player.active and self._pokemon_matches_target_type(player.active, target_pokemon_type):
                all_pokemon.append(("active", player.active))
            for index, pokemon in enumerate(player.bench):
                if pokemon is not None and self._pokemon_matches_target_type(pokemon, target_pokemon_type):
                    all_pokemon.append((f"bench_{index}", pokemon))
            if not all_pokemon:
                return CommandResult.fail("没有目标宝可梦。")
            if optional_count:
                return request_distribution(
                    matching[:count],
                    [{"slot": slot_name, "name": pokemon.card.name} for slot_name, pokemon in all_pokemon],
                    min_select=min_attach,
                    max_select=count,
                    max_per_target=count,
                    same_target=True,
                )
            if len(all_pokemon) == 1:
                return self._attach_immediate(ctx, matching, count, all_pokemon[0][1], energy_type)

            return CommandResult.ok(
                "选择1只宝可梦附着能量。",
                pending_choice=ActionRequest(
                    request_type="search_deck",
                    player=ctx.player_idx,
                    prompt="选择1只宝可梦附着能量。",
                    min_select=1,
                    max_select=1,
                    from_zone="board",
                    target_player="self",
                    card_list=[pokemon.card for _slot_name, pokemon in all_pokemon],
                    continuation={
                        "kind": "attach_discard_energy_to_board",
                        "player_idx": ctx.player_idx,
                        "count": count,
                        "energy_type": energy_type,
                    },
                ),
            )

        return CommandResult.fail(f"未知目标: {target_spec}")

    @staticmethod
    def _matching_discard_energy(discard, energy_type: str):
        energy_type = str(energy_type or "any").lower()
        return [
            card for card in discard
            if getattr(card, "is_basic_energy", False)
            and (
                energy_type in {"any", "basic", "basic_energy"}
                or any(str(provided).lower() == energy_type for provided in getattr(card, "provides_energy", []))
            )
        ]

    @staticmethod
    def _pokemon_matches_target_type(pokemon, target_type: str) -> bool:
        normalized = str(target_type or "").lower()
        if not normalized:
            return True
        return any(str(card_type).lower() == normalized for card_type in pokemon.card.energy_types)

    def _attach_immediate(self, ctx: ResolutionContext, matching, count: int, target_pokemon, energy_type: str):
        from engine.commands.base import CommandResult

        attached = 0
        for card in list(matching[:count]):
            if card in ctx.player.discard:
                ctx.player.discard.remove(card)
                target_pokemon.energy_cards.append(card)
                attached += 1
        ctx.state._log(f"从弃牌区将{attached}个{energy_type}能量附着于{target_pokemon.card.name}。")
        return CommandResult.ok(f"从弃牌区附着了{attached}个能量。")

    @staticmethod
    def _command_to_action(command_result: CommandResult):
        from engine.game_state import ActionResult

        return ActionResult(
            command_result.success,
            command_result.log_message,
            cards_drawn=command_result.cards_drawn,
            cards_discarded=command_result.cards_discarded,
            pending_action=command_result.pending_choice,
        )


@dataclass
class EnergyRelocate:
    """Move attached energy between the player's Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        amount = int(self.params.get("amount", 2) or 2)
        from_self = bool(self.params.get("from_self", False))
        energy_type = str(self.params.get("energy_type", self.params.get("filter", "any")) or "any")
        same_target = bool(self.params.get("same_target", False))
        optional_count = bool("min_select" in self.params or self.params.get("optional", False))

        if from_self:
            source_pokemon = player.active
            matching_source = (
                self._matching_energy_cards(source_pokemon.energy_cards, energy_type)
                if source_pokemon is not None else []
            )
            if source_pokemon is None or not matching_source:
                return CommandResult.ok("没有能量可转附。")

            bench_pokemon = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
            if not bench_pokemon:
                return CommandResult.ok("备战区没有宝可梦可转附能量。")

            move_count = min(amount, len(matching_source))
            min_move = min(move_count, int(self.params.get("min_select", move_count if not optional_count else 0) or 0))

            if len(bench_pokemon) == 1:
                bench_index, target_pokemon = bench_pokemon[0]
                if optional_count:
                    return self._request_distribution(
                        ctx,
                        source_pokemon,
                        list(matching_source[:move_count]),
                        [{"slot": f"bench_{bench_index}", "name": target_pokemon.card.name, "bench_idx": bench_index}],
                        min_select=min_move,
                        max_select=move_count,
                        max_per_target=move_count,
                    )
                moved = self._move_energy(ctx, source_pokemon, target_pokemon, matching_source, move_count)
                return CommandResult.ok(
                    f"将{moved}个能量从{source_pokemon.card.name}转附到{target_pokemon.card.name}。"
                )

            energy_to_move = list(matching_source[:move_count])
            return self._request_distribution(
                ctx,
                source_pokemon,
                energy_to_move,
                [
                    {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                    for index, pokemon in bench_pokemon
                ],
                min_select=min_move,
                max_select=move_count,
            )

        all_pokemon = [
            (slot_name, pokemon)
            for slot_name, pokemon in player.get_all_pokemon()
            if pokemon is not None
            and self._matching_energy_cards(pokemon.energy_cards, energy_type)
        ]
        if not all_pokemon:
            return CommandResult.ok("场上没有宝可梦附着能量。")

        if sum(1 for _slot_name, pokemon in player.get_all_pokemon() if pokemon is not None) <= 1:
            return CommandResult.ok("没有其他宝可梦可转附能量。")

        source_options = []
        for slot_name, pokemon in all_pokemon:
            source_options.append({
                "slot": slot_name,
                "name": pokemon.card.name,
                "bench_idx": int(slot_name.split("_")[1]) if slot_name.startswith("bench_") else -1,
            })

        return CommandResult.ok(
            "选择来源宝可梦。",
            pending_choice=ActionRequest(
                request_type="distribute_energy",
                player=ctx.player_idx,
                prompt="选择来源宝可梦",
                card_list=[],
                target_info=source_options,
                distribute_mode="source_select",
                source_name="选择来源",
                continuation={
                    "kind": "energy_relocate_source",
                    "player_idx": ctx.player_idx,
                    "amount": amount,
                    "energy_type": energy_type,
                    "same_target": same_target,
                    "optional_count": optional_count,
                    "min_select": self.params.get("min_select", None),
                },
            ),
        )

    @staticmethod
    def _matching_energy_cards(cards, energy_type: str):
        energy_type = str(energy_type or "any").lower()
        return [
            card for card in cards
            if getattr(card, "is_energy", False)
            and (
                energy_type in {"any", "energy"}
                or (energy_type in {"basic", "basic_energy"} and getattr(card, "is_basic_energy", False))
                or any(str(provided).lower() == energy_type for provided in getattr(card, "provides_energy", []))
            )
        ]

    def _request_distribution(
        self,
        ctx: ResolutionContext,
        source_pokemon,
        energy_cards,
        targets_info,
        *,
        min_select,
        max_select,
        max_per_target=99,
        same_target=False,
        mode="distribute",
    ) -> CommandResult:
        from engine.commands.base import CommandResult

        return CommandResult.ok(
            "选择能量卡分配到宝可梦。",
            pending_choice=self._distribution_request(
                ctx,
                source_pokemon,
                energy_cards,
                targets_info,
                min_select=min_select,
                max_select=max_select,
                max_per_target=max_per_target,
                same_target=same_target,
                mode=mode,
            ),
        )

    @staticmethod
    def _distribution_request(
        ctx: ResolutionContext,
        source_pokemon,
        energy_cards,
        targets_info,
        *,
        min_select,
        max_select,
        max_per_target=99,
        same_target=False,
        mode="distribute",
    ):
        from engine.game_state import ActionRequest

        max_select = min(max(0, int(max_select)), len(energy_cards))
        min_select = min(max_select, max(0, int(min_select)))
        source_slot = ""
        for slot_name, pokemon in ctx.player.get_all_pokemon():
            if pokemon is source_pokemon:
                source_slot = slot_name
                break

        return ActionRequest(
            request_type="distribute_energy",
            player=ctx.player_idx,
            prompt=f"分配能量 — {source_pokemon.card.name}",
            card_list=list(energy_cards[:max_select]),
            target_info=targets_info,
            distribute_mode=mode,
            min_select=min_select,
            max_select=max_select,
            max_per_target=max_per_target,
            source_name=source_pokemon.card.name,
            continuation={
                "kind": "energy_relocate_distribution",
                "player_idx": ctx.player_idx,
                "source_slot": source_slot,
                "max_per_target": max_per_target,
                "same_target": same_target,
            },
        )

    def _move_energy(self, ctx: ResolutionContext, source_pokemon, target_pokemon, matching_source, move_count: int) -> int:
        moved = 0
        for card in list(matching_source[:move_count]):
            if card in source_pokemon.energy_cards:
                source_pokemon.energy_cards.remove(card)
                target_pokemon.energy_cards.append(card)
                moved += 1
        ctx.state._log(f"将{moved}个能量从{source_pokemon.card.name}转附到{target_pokemon.card.name}。")
        return moved


__all__ = [
    "DrawAndAttachEnergy",
    "EnergyAttach",
    "AttachEnergyFromDiscard",
    "EnergyRelocate",
]

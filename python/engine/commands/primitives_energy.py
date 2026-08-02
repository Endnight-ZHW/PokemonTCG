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
        select_source = bool(self.params.get("select_source", False))
        same_target = bool(self.params.get("same_target", False))
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
            if from_zone == "deck":
                player.shuffle_deck()
            return CommandResult.ok(f"{zone_name}中无匹配的能量。")

        def distribution(energy_cards, targets_info, *, min_select, max_select, max_per_target=99, same_target=False):
            max_select = min(max(0, int(max_select)), len(energy_cards))
            min_select = min(max_select, max(0, int(min_select)))
            if max_select <= 0:
                return CommandResult.ok(f"{zone_name}中无匹配的能量。")

            # Match the Godot reference VM: unless ``select_source`` is set,
            # the first ``amount`` matching source cards are fixed by the
            # effect and the player chooses only the targets/count.  Exposing
            # every physical source entity created an unintended source x
            # target product (and could exceed the 60-option protocol) for
            # optional hand/deck attachments.  Explicit source-selection
            # effects still expose every matching card.
            if select_source:
                # Source selection distinguishes card identities and counts,
                # not interchangeable physical copies.  At most
                # ``max_select`` copies of one ID can participate in any
                # response, so publishing more only creates duplicate policy
                # edges and can overflow the source x target protocol.
                exposed_energy_cards = []
                exposed_by_id: dict[str, int] = {}
                for card in energy_cards:
                    card_id = str(getattr(card, "api_id", "") or "")
                    if exposed_by_id.get(card_id, 0) >= max_select:
                        continue
                    exposed_energy_cards.append(card)
                    exposed_by_id[card_id] = exposed_by_id.get(card_id, 0) + 1
            else:
                exposed_energy_cards = list(energy_cards[:max_select])

            return CommandResult.ok(
                f"选择最多{max_select}个能量附着。",
                pending_choice=ActionRequest(
                    request_type="distribute_energy",
                    player=ctx.player_idx,
                    prompt=f"分配能量 — {zone_name}",
                    card_list=exposed_energy_cards,
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
            if optional_count or select_source:
                matching = self._matching_energy_cards(source_pool, filter_type)
                target_slot = self._slot_for_pokemon(player, target)
                return distribution(
                    matching,
                    [{"slot": target_slot, "name": target.card.name}],
                    min_select=min_attach,
                    max_select=min(amount_to_attach, len(matching)),
                    max_per_target=amount_to_attach,
                    same_target=True,
                )
            return self._attach_immediate(ctx, source_pool, zone_name, from_zone, filter_type, amount_to_attach, target)

        if to_target == "self":
            return attach_to_target(player.get_pokemon(ctx.source_slot), amount)

        if to_target == "bench":
            bench_slots = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
            if not bench_slots:
                return (
                    CommandResult.ok("备战区无宝可梦。")
                    if optional_count
                    else CommandResult.fail("备战区没有宝可梦可附着能量。")
                )
            if len(bench_slots) == 1:
                target_slot = f"bench_{bench_slots[0][0]}"
                target = player.get_pokemon(target_slot)
                if optional_count or select_source:
                    matching = self._matching_energy_cards(source_pool, filter_type)
                    return distribution(
                        matching,
                        [{"slot": target_slot, "name": target.card.name, "bench_idx": bench_slots[0][0]}],
                        min_select=min_attach,
                        max_select=min(amount, max_per_target, len(matching)),
                        max_per_target=max_per_target,
                        same_target=True,
                    )
                return attach_to_target(target, min(amount, max_per_target))
            if amount <= 1:
                if select_source:
                    matching = self._matching_energy_cards(source_pool, filter_type)
                    return distribution(
                        matching,
                        [
                            {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                            for index, pokemon in bench_slots
                        ],
                        min_select=min_attach,
                        max_select=min(amount, len(matching)),
                        max_per_target=max_per_target,
                        same_target=True,
                    )
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
            return distribution(
                matching,
                targets_info,
                min_select=min_attach if optional_count else min(amount, capacity, len(matching)),
                max_select=min(amount, capacity, len(matching)),
                max_per_target=max_per_target,
                same_target=same_target,
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
                return (
                    CommandResult.ok(message)
                    if optional_count
                    else CommandResult.fail(message)
                )
            if len(candidates) == 1:
                return attach_to_target(candidates[0][1], amount)
            if optional_count or select_source:
                matching = self._matching_energy_cards(source_pool, filter_type)
                return distribution(
                    matching,
                    [{"slot": slot_name, "name": pokemon.card.name} for slot_name, pokemon in candidates],
                    min_select=min_attach,
                    max_select=min(amount, len(matching)),
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
            if from_zone == "deck":
                ctx.player.shuffle_deck()
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
        select_source = bool(self.params.get("select_source", False))
        same_target = bool(self.params.get("same_target", False))

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

            # The Godot reference VM fixes the source cards to the first
            # ``amount`` matching discard entries unless the effect asks the
            # player to select a source explicitly.  Exposing every physical
            # copy here created a source x target product larger than the
            # ChoiceRequest protocol permits (Chi-Yu with a full board and a
            # large Fire Energy discard).  Preserve explicit source-selection
            # effects, while matching the reference semantics for effects
            # that only ask where/how many of the fixed cards to attach.
            if select_source:
                exposed_energy_cards = []
                exposed_by_id: dict[str, int] = {}
                for card in energy_cards:
                    card_id = str(getattr(card, "api_id", "") or "")
                    if exposed_by_id.get(card_id, 0) >= max_select:
                        continue
                    exposed_energy_cards.append(card)
                    exposed_by_id[card_id] = exposed_by_id.get(card_id, 0) + 1
            else:
                exposed_energy_cards = list(energy_cards[:max_select])

            return CommandResult.ok(
                f"选择最多{max_select}个能量附着。",
                pending_choice=ActionRequest(
                    request_type="distribute_energy",
                    player=ctx.player_idx,
                    prompt="分配能量 — 弃牌区",
                    card_list=exposed_energy_cards,
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
                        "explicit_bounds": True,
                    },
                ),
            )

        if target_spec == "self":
            target_pokemon = player.active
            if target_pokemon is None:
                return CommandResult.fail("没有战斗宝可梦。")
            if not self._pokemon_matches_target_type(target_pokemon, target_pokemon_type):
                return CommandResult.ok("没有符合条件的附着目标。")
            if optional_count or select_source or len(matching) > count:
                return request_distribution(
                    matching,
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
                if optional_count or select_source or len(matching) > count:
                    return request_distribution(
                        matching,
                        [{"slot": f"bench_{bench_index}", "name": target_pokemon.card.name, "bench_idx": bench_index}],
                        min_select=min_attach,
                        max_select=count,
                        max_per_target=count,
                        same_target=True,
                    )
                return self._attach_immediate(ctx, matching, count, target_pokemon, energy_type)
            targets_info = [
                {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                for index, pokemon in bench_slots
            ]
            return request_distribution(
                matching,
                targets_info,
                min_select=min_attach if optional_count else count,
                max_select=count,
                same_target=same_target,
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
            if optional_count or select_source or len(matching) > count:
                return request_distribution(
                    matching,
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
        from engine.game_state import ActionRequest

        player = ctx.player
        amount = max(0, int(self.params.get("amount", 2) or 2))
        from_self = bool(self.params.get("from_self", False))
        energy_type = str(self.params.get("energy_type", self.params.get("filter", "any")) or "any")
        same_target = bool(self.params.get("same_target", False))
        optional_count = bool("min_select" in self.params or self.params.get("optional", False))

        all_pokemon = [
            (slot_name, pokemon)
            for slot_name, pokemon in player.get_all_pokemon()
            if pokemon is not None
            and self._matching_energy_cards(pokemon.energy_cards, energy_type)
            and (not from_self or slot_name == "active")
        ]
        if not all_pokemon:
            return CommandResult.ok("场上没有宝可梦附着能量。")

        if sum(1 for _slot_name, pokemon in player.get_all_pokemon() if pokemon is not None) <= 1:
            return CommandResult.ok("没有其他宝可梦可转附能量。")

        if len(all_pokemon) == 1:
            source_slot, source_pokemon = all_pokemon[0]
            request = self._attachment_or_target_request(
                ctx,
                source_slot,
                source_pokemon,
                amount=amount,
                energy_type=energy_type,
                optional_count=optional_count,
                min_select=self.params.get("min_select", None),
                same_target=same_target,
            )
            return CommandResult.ok(
                "选择要转附的能量和目标。",
                pending_choice=request,
            ) if request is not None else CommandResult.ok("没有可转附的能量。")

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
                    "purpose": "relocate_energy_source",
                    "player_idx": ctx.player_idx,
                    "source_player": ctx.player_idx,
                    "source_zone": "field",
                    "amount": amount,
                    "energy_type": energy_type,
                    "same_target": same_target,
                    "same_source": True,
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

    def _attachment_or_target_request(
        self,
        ctx: ResolutionContext,
        source_slot,
        source_pokemon,
        *,
        amount,
        energy_type,
        optional_count,
        min_select,
        same_target=False,
    ):
        from engine.actions import AttachmentRef
        from engine.game_state import ActionRequest

        targets_info = [
            {
                "player": ctx.player_idx,
                "slot": slot_name,
                "name": pokemon.card.name,
                "card_id": pokemon.card.api_id,
                "bench_idx": int(slot_name.split("_", 1)[1]) if slot_name.startswith("bench_") else -1,
            }
            for slot_name, pokemon in ctx.player.get_all_pokemon()
            if pokemon is not None and slot_name != source_slot
        ]
        if not targets_info:
            return None
        matching = [
            (index, card)
            for index, card in enumerate(source_pokemon.energy_cards)
            if card in self._matching_energy_cards(source_pokemon.energy_cards, energy_type)
        ]
        move_count = min(max(0, int(amount)), len(matching))
        if move_count <= 0:
            return None
        if min_select is None:
            request_min = 0 if optional_count else move_count
        else:
            request_min = min(move_count, max(0, int(min_select or 0)))
        refs = [
            AttachmentRef(
                ctx.player_idx,
                source_slot,
                "energy",
                index,
                str(getattr(card, "api_id", "") or ""),
            )
            for index, card in matching
        ]
        exact_choice_required = request_min < move_count or len(refs) > move_count
        if exact_choice_required:
            return ActionRequest(
                request_type="select_attachment",
                player=ctx.player_idx,
                prompt=f"选择从{source_pokemon.card.name}转附的能量。",
                min_select=request_min,
                max_select=move_count,
                can_cancel=request_min <= 0,
                target_info=[
                    {
                        "player": ref.player,
                        "slot": ref.slot,
                        "attachment_type": ref.attachment_type,
                        "index": ref.index,
                        "card_id": ref.card_id,
                        "label": f"{source_pokemon.card.name} - {getattr(card, 'name', ref.card_id)}",
                    }
                    for ref, (_index, card) in zip(refs, matching)
                ],
                continuation={
                    "kind": "energy_relocate_attachments",
                    "purpose": "relocate_energy",
                    "player_idx": ctx.player_idx,
                    "source_player": ctx.player_idx,
                    "source_zone": "field",
                    "source_slot": source_slot,
                    "amount": move_count,
                    "energy_type": energy_type,
                    "same_source": True,
                    "same_target": same_target,
                    "max_per_target": move_count,
                },
            )
        return self._distribution_request(
            ctx,
            source_pokemon,
            [card for _index, card in matching[:move_count]],
            targets_info,
            attachment_refs=refs[:move_count],
            same_target=same_target,
        )

    @staticmethod
    def _distribution_request(
        ctx: ResolutionContext,
        source_pokemon,
        energy_cards,
        targets_info,
        *,
        attachment_refs,
        same_target=False,
    ):
        from engine.game_state import ActionRequest

        move_count = min(len(energy_cards), len(attachment_refs))
        source_slot = ""
        for slot_name, pokemon in ctx.player.get_all_pokemon():
            if pokemon is source_pokemon:
                source_slot = slot_name
                break

        return ActionRequest(
            request_type="distribute_energy",
            player=ctx.player_idx,
            prompt=f"分配能量 — {source_pokemon.card.name}",
            card_list=list(energy_cards[:move_count]),
            target_info=targets_info,
            distribute_mode="paired",
            min_select=move_count,
            max_select=move_count,
            max_per_target=move_count,
            source_name=source_pokemon.card.name,
            continuation={
                "kind": "energy_relocate_distribution",
                "purpose": "relocate_energy_target",
                "player_idx": ctx.player_idx,
                "source_player": ctx.player_idx,
                "source_zone": "field",
                "source_slot": source_slot,
                "attachment_refs": [
                    {
                        "kind": "attachment",
                        "player": ref.player,
                        "zone": "field",
                        "slot": ref.slot,
                        "index": ref.index,
                        "attachment_type": ref.attachment_type,
                        "card_id": ref.card_id,
                    }
                    for ref in attachment_refs[:move_count]
                ],
                "card_ids": [ref.card_id for ref in attachment_refs[:move_count]],
                "same_source": True,
                "max_per_target": move_count,
                "same_target": same_target,
            },
        )


__all__ = [
    "DrawAndAttachEnergy",
    "EnergyAttach",
    "AttachEnergyFromDiscard",
    "EnergyRelocate",
]

"""Deck-search and top-deck VM primitive commands."""
from __future__ import annotations

from dataclasses import dataclass, field

from engine.commands.base import CommandResult, ResolutionContext


@dataclass
class SearchCards:
    """Search a player zone for matching cards and move selected cards."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        player = ctx.player
        from_zone = str(self.params.get("from_zone", "deck") or "deck")
        filter_type = str(self.params.get("filter", "pokemon") or "pokemon")
        filter_name = str(self.params.get("filter_name", "") or "")
        destination = str(self.params.get("destination", "hand") or "hand")
        count = int(self.params.get("count", 1) or 1)
        default_min = 0 if bool(self.params.get("optional", False)) else min(1, count)
        min_select = int(self.params.get("min_select", default_min) or 0)

        search_pool = player.deck if from_zone == "deck" else player.discard
        valid_cards = [card for card in search_pool if self._matches(card, filter_type, filter_name)]
        if not valid_cards:
            if from_zone == "deck":
                player.shuffle_deck()
            return CommandResult.ok(f"No valid cards found in {from_zone}.")

        max_select = min(count, len(valid_cards))
        if destination == "bench":
            max_select = min(
                max_select,
                sum(1 for pokemon in player.bench if pokemon is None),
            )
        if max_select <= 0:
            if from_zone == "deck":
                player.shuffle_deck()
            return CommandResult.ok("No open Bench slots.")
        return CommandResult.ok(
            f"Search {from_zone} for {filter_type}.",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从{from_zone}选择{count}张卡（{filter_type}）",
                min_select=min(min_select, max_select),
                max_select=max_select,
                from_zone=from_zone,
                card_list=valid_cards,
                can_cancel=min_select <= 0,
                continuation={
                    "kind": "search_cards",
                    "player_idx": ctx.player_idx,
                    "from_zone": from_zone,
                    "destination": destination,
                    "count": count,
                },
            ),
        )

    @staticmethod
    def _matches(card, filter_type: str, filter_name: str) -> bool:
        if filter_name:
            return getattr(card, "name", "") == filter_name
        if filter_type == "any":
            return True
        if filter_type == "basic_pokemon":
            return bool(getattr(card, "is_basic_pokemon", False))
        if filter_type == "pokemon":
            return bool(getattr(card, "is_pokemon", False))
        if filter_type == "basic_energy":
            return bool(getattr(card, "is_basic_energy", False))
        if filter_type == "energy":
            return bool(getattr(card, "is_energy", False))
        if filter_type == "supporter":
            return bool(getattr(card, "is_trainer_supporter", False))
        if filter_type == "grass_pokemon":
            return bool(
                getattr(card, "is_pokemon", False)
                and getattr(card, "energy_types", None)
                and "Grass" in card.energy_types
            )
        if filter_type == "item":
            return bool(getattr(card, "is_trainer_item", False))
        if filter_type == "item_or_tool":
            return bool(
                getattr(card, "is_trainer_item", False)
                or getattr(card, "is_trainer_tool", False)
            )
        return True


@dataclass
class LookTopDeck:
    """Look at the top deck cards, choose matching cards, then return the rest."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        count = int(self.params.get("count", 5) or 5)
        take = int(self.params.get("take", 1) or 1)
        rest_bottom = bool(self.params.get("rest_bottom", True))
        shuffle_rest = bool(self.params.get("shuffle_rest", False))
        filter_type = str(self.params.get("filter", "") or "")
        destination = str(self.params.get("destination", "hand") or "hand")
        min_select = int(self.params.get("min_select", 0 if take >= 99 else 1) or 0)

        player = ctx.player
        top_cards = [
            player.deck[-1 - index]
            for index in range(min(count, len(player.deck)))
        ]

        display_cards = []
        display_top_positions = []
        for index, card in enumerate(top_cards):
            if self._matches(card, filter_type):
                display_cards.append(card)
                display_top_positions.append(index)
        if not display_cards:
            top_cards = []
            for _ in range(min(count, len(player.deck))):
                top_cards.append(player.deck.pop())
            if shuffle_rest:
                player.deck.extend(top_cards)
                player.shuffle_deck()
            elif rest_bottom:
                for card in top_cards:
                    player.deck.insert(0, card)
            else:
                player.deck.extend(reversed(top_cards))
            return CommandResult.ok(f"牌库顶{count}张没有可选择的卡。")

        max_select = min(take, len(display_cards))
        return CommandResult.ok(
            f"Look at top {len(display_cards)} cards.",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从牌库顶选择最多{take}张卡。",
                min_select=min(min_select, max_select),
                max_select=max_select,
                from_zone="deck",
                card_list=display_cards,
                can_cancel=min_select <= 0,
                continuation={
                    "kind": "look_top_deck",
                    "player_idx": ctx.player_idx,
                    "count": len(top_cards),
                    "take": take,
                    "rest_bottom": rest_bottom,
                    "shuffle_rest": shuffle_rest,
                    "destination": destination,
                    "top_card_ids": [getattr(card, "api_id", "") for card in top_cards],
                    "display_top_positions": display_top_positions,
                },
            ),
        )

    @staticmethod
    def _matches(card, filter_type: str) -> bool:
        if filter_type == "lightning_energy":
            return bool(
                getattr(card, "is_basic_energy", False)
                and any(
                    "Lightning" in str(energy_type)
                    for energy_type in getattr(card, "provides_energy", [])
                )
            )
        if filter_type == "supporter":
            return bool(getattr(card, "is_trainer_supporter", False))
        if filter_type == "energy":
            return bool(getattr(card, "is_energy", False))
        if filter_type == "water_pokemon_and_energy":
            return bool(
                (
                    getattr(card, "is_pokemon", False)
                    and getattr(card, "energy_types", None)
                    and "Water" in card.energy_types
                )
                or (
                    getattr(card, "is_basic_energy", False)
                    and "Water" in str(getattr(card, "provides_energy", []))
                )
            )
        return True

    @staticmethod
    def _attach_to_lightning_bench(ctx: ResolutionContext, taken: list):
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        if not taken:
            return ActionResult(True, "未选择能量。")

        bench_pokes = [
            (i, pokemon)
            for i, pokemon in enumerate(player.bench)
            if pokemon is not None
            and getattr(pokemon.card, "energy_types", None)
            and "Lightning" in pokemon.card.energy_types
        ]
        if not bench_pokes:
            player.deck.extend(taken)
            player.shuffle_deck()
            ctx.state._log("备战区没有雷属性宝可梦可附着能量。")
            return ActionResult(True, "备战区没有雷属性宝可梦可附着能量。")
        if len(bench_pokes) == 1 and len(taken) <= 1:
            _idx, bench_pokemon = bench_pokes[0]
            for card in taken:
                bench_pokemon.energy_cards.append(card)
            ctx.state._log(f"将{len(taken)}张能量附着于备战区{bench_pokemon.card.name}。")
            return ActionResult(True, f"附着了{len(taken)}张能量。")

        targets_info = [
            {"slot": f"bench_{idx}", "name": pokemon.card.name, "bench_idx": idx}
            for idx, pokemon in bench_pokes
        ]

        return ActionRequest(
            request_type="distribute_energy",
            player=ctx.player_idx,
            prompt="分配能量 — 电气发生器",
            card_list=taken,
            target_info=targets_info,
            distribute_mode="distribute",
            min_select=len(taken),
            max_select=len(taken),
            source_name="电气发生器",
            continuation={
                "kind": "detached_energy_distribution",
                "player_idx": ctx.player_idx,
                "source_name": "电气发生器",
            },
        )


@dataclass
class LookTopAttachEnergy:
    """Look at top deck cards, attach selected matching energy to one Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        count = int(self.params.get("count", 5) or 5)
        take = int(self.params.get("take", 99) or 99)
        filter_type = str(self.params.get("filter", "basic_energy") or "basic_energy")

        player = ctx.player
        top_cards = [
            player.deck[-1 - index]
            for index in range(min(count, len(player.deck)))
        ]

        eligible = []
        display_top_positions = []
        for index, card in enumerate(top_cards):
            if self._matches_energy(card, filter_type):
                eligible.append(card)
                display_top_positions.append(index)
        if not eligible:
            top_cards = []
            for _ in range(min(count, len(player.deck))):
                top_cards.append(player.deck.pop())
            player.deck.extend(top_cards)
            player.shuffle_deck()
            return CommandResult.ok("没有可附着的能量。")

        return CommandResult.ok(
            f"查看牌库顶{len(top_cards)}张卡。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt="选择任意数量的基本能量附着于1只宝可梦。",
                min_select=0,
                max_select=min(take, len(eligible)),
                from_zone="deck",
                card_list=eligible,
                continuation={
                    "kind": "look_top_attach_energy",
                    "player_idx": ctx.player_idx,
                    "count": len(top_cards),
                    "take": take,
                    "top_card_ids": [getattr(card, "api_id", "") for card in top_cards],
                    "display_top_positions": display_top_positions,
                },
            ),
        )

    @staticmethod
    def _matches_energy(card, filter_type: str) -> bool:
        filter_type = str(filter_type or "any")
        if filter_type in {"any", "energy"}:
            return bool(getattr(card, "is_energy", False))
        if filter_type in {"basic", "basic_energy"}:
            return bool(getattr(card, "is_basic_energy", False))
        return bool(
            getattr(card, "is_energy", False)
            and any(
                str(provided).lower() == filter_type.lower()
                for provided in getattr(card, "provides_energy", [])
            )
        )


@dataclass
class SearchItemAndTool:
    """Search the deck for up to one Item and up to one Tool."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        player = ctx.player
        available = [
            card for card in player.deck
            if getattr(card, "is_trainer_item", False)
            or getattr(card, "is_trainer_tool", False)
        ]
        if not available:
            player.shuffle_deck()
            return CommandResult.ok("牌库中没有物品卡或宝可梦道具卡。")

        return CommandResult.ok(
            "选择1张物品卡和1张宝可梦道具卡加入手牌。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt="选择1张「物品」和1张「宝可梦道具」（派帕）",
                min_select=1,
                max_select=min(2, len(available)),
                from_zone="deck",
                card_list=available,
                continuation={
                    "kind": "search_item_and_tool",
                    "player_idx": ctx.player_idx,
                },
            ),
        )


@dataclass
class TrekkingShoes:
    """Look at the top deck card; keep it or discard it and draw one."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        player = ctx.player
        if not player.deck:
            return CommandResult.ok("牌库为空。")
        top_card = player.deck[-1]

        return CommandResult.ok(
            f"牌库顶是「{top_card.name}」。",
            pending_choice=ActionRequest(
                request_type="confirm",
                player=ctx.player_idx,
                prompt=f"牌库顶是「{top_card.name}」。是否放入手牌？\n（选「否」将丢弃此卡并抽1张）",
                continuation={
                    "kind": "trekking_shoes",
                    "player_idx": ctx.player_idx,
                    "top_card_id": getattr(top_card, "api_id", ""),
                    "top_card_name": getattr(top_card, "name", ""),
                },
            ),
        )


@dataclass
class ConditionalSearchExtra:
    """Search more cards on the second player's first turn."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        search_count = (
            int(self.params.get("max_count", 3) or 3)
            if ctx.state.is_going_second_first_turn(ctx.player_idx)
            else int(self.params.get("default_count", 1) or 1)
        )
        max_count = int(self.params.get("max_count", search_count) or search_count)
        return SearchCards(params={
            "from_zone": "deck",
            "filter": str(self.params.get("filter", "grass_pokemon") or "grass_pokemon"),
            "destination": "hand",
            "count": search_count,
            "min_select": 0 if search_count == max_count else 1,
        }).execute(ctx)


@dataclass
class SearchAnyAndSwitch:
    """Search deck for any cards, then optionally switch the source Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        player = ctx.player
        if not player.deck:
            return CommandResult.ok("牌库中没有卡。")
        count = int(self.params.get("count", 2) or 2)
        min_select = int(self.params.get("min_select", 0) or 0)
        switch_optional = bool(self.params.get("switch_optional", True))

        return CommandResult.ok(
            f"从牌库选择最多{count}张任意卡。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从牌库选择最多{count}张卡加入手牌（生存战略）",
                min_select=min_select,
                max_select=count,
                from_zone="deck",
                card_list=list(player.deck),
                can_cancel=min_select <= 0,
                continuation={
                    "kind": "search_any_and_switch",
                    "player_idx": ctx.player_idx,
                    "count": count,
                    "switch_optional": switch_optional,
                },
            ),
        )


__all__ = [
    "SearchCards",
    "LookTopDeck",
    "LookTopAttachEnergy",
    "SearchItemAndTool",
    "TrekkingShoes",
    "ConditionalSearchExtra",
    "SearchAnyAndSwitch",
]

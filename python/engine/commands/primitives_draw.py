"""Draw and hand-refresh VM primitive commands."""
from __future__ import annotations

from dataclasses import dataclass

from engine.commands.base import CommandResult, ResolutionContext


@dataclass
class DrawCards:
    count: int = 1
    player: str = "self"  # 'self' or 'opponent'

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        p = ctx.player if self.player == "self" else ctx.opponent
        drawn = p.draw_cards(self.count)
        ctx.state._log(f"{p.name}抽取了{len(drawn)}张卡。")
        return CommandResult.ok(
            f"抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )


@dataclass
class DrawUntil:
    target_hand_size: int = 5

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        current = len(ctx.player.hand)
        to_draw = max(0, self.target_hand_size - current)
        if to_draw == 0:
            ctx.state._log(f"{ctx.player.name}的手牌已有{current}张，无需抽取。")
            return CommandResult.ok(f"Hand already has {current} cards.")
        drawn = ctx.player.draw_cards(to_draw)
        ctx.state._log(
            f"{ctx.player.name}抽取了{len(drawn)}张卡，现在手牌有{len(ctx.player.hand)}张。"
        )
        return CommandResult.ok(
            f"Drew {len(drawn)} cards to reach {self.target_hand_size}.",
            cards_drawn=drawn,
        )


@dataclass
class DrawUntilMore:
    """Draw until this player has more cards in hand than the opponent."""

    margin: int = 1

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        target = len(ctx.opponent.hand) + int(self.margin or 1)
        current = len(ctx.player.hand)
        to_draw = max(0, target - current)
        if to_draw == 0:
            ctx.state._log(
                f"{ctx.player.name}的手牌已有{current}张（比对手的{len(ctx.opponent.hand)}张多1张或以上），无需抽取。"
            )
            return CommandResult.ok(f"Hand already has {current} cards.")
        drawn = ctx.player.draw_cards(to_draw)
        ctx.state._log(
            f"{ctx.player.name}抽取了{len(drawn)}张卡（目标比对手多1张，抽了{to_draw}张）。"
        )
        return CommandResult.ok(
            f"抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )


@dataclass
class ShuffleThenDrawCards:
    """Shuffle this player's hand into the deck, then draw cards."""

    draw_amount: int = 5
    shuffle_hand: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        player = ctx.player
        if self.shuffle_hand:
            hand_size = len(player.hand)
            player.deck.extend(player.hand)
            player.hand.clear()
            player.shuffle_deck()
            ctx.state._log(f"{player.name}将{hand_size}张手牌洗回牌库。")

        drawn = player.draw_cards(int(self.draw_amount or 0))
        ctx.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
        return CommandResult.ok(
            f"洗回手牌并抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )


@dataclass
class Judge:
    """Both players shuffle their hands into their decks, then draw cards."""

    draw_amount: int = 4

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        drawn_cards = []
        draw_amount = int(self.draw_amount or 0)
        for player_idx in (0, 1):
            player = ctx.state.get_player(player_idx)
            hand_size = len(player.hand)
            if hand_size == 0:
                continue
            player.deck.extend(player.hand)
            player.hand.clear()
            player.shuffle_deck()
            drawn = player.draw_cards(draw_amount)
            drawn_cards.extend(drawn)
            ctx.state._log(f"{player.name}将{hand_size}张手牌洗回牌库，抽取了{len(drawn)}张卡。")

        return CommandResult.ok(
            f"Judge: both players shuffled and drew {draw_amount}.",
            cards_drawn=drawn_cards,
        )

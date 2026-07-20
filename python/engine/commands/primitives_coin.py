"""Coin-flip and branch-frame VM primitive commands."""
from __future__ import annotations

from dataclasses import dataclass, field

from engine.commands.base import CommandResult, ResolutionContext
from engine.random_source import RandomSource


@dataclass
class CoinFlipSpecial:
    """Native coin-flip attack variants with fixed post-flip resolution."""

    coin_kind: str = "repeat_damage"
    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        coin_kind = str(self.coin_kind or "repeat_damage")
        params = dict(self.params or {})

        if coin_kind == "until_tails":
            prompt = "掷硬币直到出现反面（连续旋转）"
            flip_count = 1
            until_tails = True
        elif coin_kind == "double_ko":
            prompt = "掷2次硬币"
            flip_count = 2
            until_tails = False
        else:
            flip_count = int(params.get("flips", 3) or 3)
            prompt = f"掷{flip_count}次硬币"
            until_tails = False

        results = _authoritative_coin_results(
            ctx,
            flip_count=flip_count,
            until_tails=until_tails,
        )
        return CommandResult.ok(
            "掷硬币中...",
            pending_choice=ActionRequest(
                request_type="coin_flip",
                player=ctx.player_idx,
                prompt=prompt,
                min_select=0,
                max_select=0,
                flip_count=len(results),
                until_tails=until_tails,
                continuation={
                    "kind": "coin_special",
                    "coin_kind": coin_kind,
                    "params": params,
                    "results": results,
                },
            ),
        )


@dataclass
class CoinFlipEnergyDiscard:
    """Flip a coin; on heads choose and discard one opponent energy."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        opponent_idx = 1 - ctx.player_idx
        opponent = ctx.state.get_player(opponent_idx)
        if not any(pokemon and pokemon.energy_cards for _slot, pokemon in opponent.get_all_pokemon()):
            return CommandResult.ok("对手场上没有能量可丢弃。")

        results = _authoritative_coin_results(ctx, flip_count=1)
        return CommandResult.ok(
            "掷硬币中...",
            pending_choice=ActionRequest(
                request_type="coin_flip",
                player=ctx.player_idx,
                prompt="掷1次硬币（粉碎之锤）",
                min_select=0,
                max_select=0,
                flip_count=1,
                continuation={
                    "kind": "coin_energy_discard",
                    "results": results,
                },
            ),
        )


@dataclass
class Conditional:
    """VM conditional frame: optional precondition, then cost before on-pay branch."""

    params: dict = field(default_factory=dict)
    cost: list = field(default_factory=list)
    on_pay: list = field(default_factory=list)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        condition = str(self.params.get("condition", "") or "")
        if condition in {"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn"}:
            if not ctx.state.had_knockout_last_opponent_turn(
                ctx.player_idx,
                causes={"attack_damage"},
            ):
                ctx.state._log(f"{ctx.player.name}上个对手回合没有宝可梦因招式伤害昏厥，无法使用此卡。")
                return CommandResult.fail("不满足使用条件，卡牌保留在手牌中。")
        elif (
            condition == "ko_last_opponent_turn"
            and not ctx.state.had_knockout_last_opponent_turn(ctx.player_idx)
        ):
            ctx.state._log(f"{ctx.player.name}上个对手回合没有宝可梦昏厥，无法使用此卡。")
            return CommandResult.fail("不满足使用条件，卡牌保留在手牌中。")

        sequence = list(self.cost or []) + list(self.on_pay or [])
        if sequence:
            try:
                ctx.stack.push_many([_build_branch_command(item) for item in sequence])
            except Exception as exc:
                return CommandResult.fail(str(exc))
        return CommandResult.ok("条件效果已结算。")


@dataclass
class FlipCoin:
    on_heads: list = field(default_factory=list)
    on_tails: list = field(default_factory=list)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        results = _authoritative_coin_results(ctx, flip_count=1)
        return CommandResult.ok(
            "掷硬币中...",
            pending_choice=ActionRequest(
                request_type="coin_flip",
                player=ctx.player_idx,
                prompt="掷1次硬币",
                min_select=0,
                max_select=0,
                flip_count=1,
                continuation={
                    "kind": "flip_coin_branch",
                    "on_heads": _branch_payload(self.on_heads),
                    "on_tails": _branch_payload(self.on_tails),
                    "results": results,
                },
            ),
        )


def _authoritative_coin_results(
    ctx: ResolutionContext,
    *,
    flip_count: int,
    until_tails: bool = False,
) -> list[bool]:
    """Consume rule RNG before publishing the display acknowledgement."""
    rng = getattr(ctx.state, "random_source", None)
    if rng is None or not callable(getattr(rng, "coin", None)):
        # Direct command tests and legacy local tools can execute a stack
        # outside GameEngine's bind_state context.  The outcome is still
        # produced by the command rather than supplied by its caller.
        rng = RandomSource()
    results: list[bool] = []
    if until_tails:
        for _ in range(32):
            result = bool(rng.coin())
            results.append(result)
            if not result:
                break
    else:
        results = [bool(rng.coin()) for _ in range(max(1, int(flip_count)))]
    return results


def _branch_payload(items):
    payload = []
    for item in items or []:
        if hasattr(item, "to_dict"):
            payload.append(item.to_dict())
        elif hasattr(item, "effect_type"):
            payload.append({
                "effect_type": str(getattr(item, "effect_type", "") or ""),
                "params": dict(getattr(item, "params", {}) or {}),
            })
        elif isinstance(item, dict):
            payload.append(dict(item))
        else:
            payload.append(item)
    return payload


def _build_branch_command(item):
    if isinstance(item, dict) and "op" in item:
        from engine.commands.dsl_compiler import compile_command_spec

        return compile_command_spec(item)
    from engine.commands.registry import build_command

    return build_command(item)


__all__ = [
    "CoinFlipSpecial",
    "CoinFlipEnergyDiscard",
    "Conditional",
    "FlipCoin",
    "_authoritative_coin_results",
    "_branch_payload",
    "_build_branch_command",
]

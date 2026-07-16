"""Status-condition VM commands."""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from engine.enums import StatusType

if TYPE_CHECKING:
    from engine.commands.base import CommandResult, ResolutionContext


@dataclass
class ApplyStatus:
    status: str = ""
    target: str = "opponent_active"
    condition: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        if self.condition and not self._check_condition(ctx):
            return CommandResult.ok("")

        if self.target == "opponent_active":
            target = ctx.opponent.active
        else:
            target = ctx.player.active

        if target is None:
            return CommandResult.fail("没有状态效果的目标。")

        status_map = {
            "poisoned": StatusType.POISONED,
            "burned": StatusType.BURNED,
            "asleep": StatusType.ASLEEP,
            "paralyzed": StatusType.PARALYZED,
            "confused": StatusType.CONFUSED,
        }
        status_key = str(self.status or "").lower()
        st = status_map.get(status_key)
        if st is None:
            return CommandResult.fail(f"未知状态: {self.status}")

        from engine.commands.attack_frames import is_opponent_attack_effect

        if (
            getattr(target, "all_prevented_next_turn", False)
            and is_opponent_attack_effect(ctx.state, ctx.stack, target)
        ):
            ctx.state._log(f"{target.card.name}免疫了所有效果！")
            return CommandResult.ok("免疫了效果。")

        if st in (StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED):
            target.status_conditions -= {
                StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED
            }
        target.status_conditions.add(st)
        if st == StatusType.PARALYZED:
            target.paralyzed_since_turn = ctx.state.turn_number
        status_cn_map = {
            "poisoned": "中毒",
            "burned": "灼伤",
            "asleep": "睡眠",
            "paralyzed": "麻痹",
            "confused": "混乱",
        }
        cn_status = status_cn_map.get(status_key, self.status)
        msg = f"{target.card.name}陷入了{cn_status}状态！"
        ctx.state._log(msg)
        return CommandResult.ok(msg, status_applied=[status_key])

    def _check_condition(self, ctx: ResolutionContext) -> bool:
        if self.condition in {"ko_by_attack_last_turn", "ko_by_attack_damage_last_turn"}:
            if not ctx.state.had_knockout_last_opponent_turn(
                ctx.player_idx,
                causes={"attack_damage"},
            ):
                ctx.state._log(f"上个对手回合没有宝可梦因招式伤害昏厥，{self.status}效果不触发。")
                return False
            return True
        if self.condition == "ko_last_opponent_turn":
            return ctx.state.had_knockout_last_opponent_turn(ctx.player_idx)
        return False


__all__ = ["ApplyStatus"]

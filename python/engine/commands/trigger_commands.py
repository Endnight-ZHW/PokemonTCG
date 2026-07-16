"""Runtime commands produced by MBF/event triggers."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, TYPE_CHECKING

from engine.commands.base import CommandResult

if TYPE_CHECKING:
    from engine.commands.base import ICommand, ResolutionContext
    from engine.game_state import GameState


def pokemon_ref_for_state(state: GameState, pokemon: Any) -> tuple[int, str] | None:
    """Return a stable in-play ref for a Pokemon object, if it is still in play."""
    if state is None or pokemon is None:
        return None
    for player_idx in (0, 1):
        for slot, candidate in state.get_player(player_idx).get_all_pokemon():
            if candidate is pokemon:
                return player_idx, slot
    return None


def _pokemon_from_ref(state: GameState, player_idx: int | None, slot: str) -> Any:
    if player_idx not in (0, 1) or not slot:
        return None
    return state.get_player(int(player_idx)).get_pokemon(str(slot))


def _as_int(value: Any, default: int = 0) -> int:
    if value is None or value == "":
        return int(default)
    try:
        return int(value)
    except (TypeError, ValueError):
        return int(default)


def trigger_draw_cards_spec(
    player_idx: int,
    count: int,
    source_name: str = "",
) -> dict[str, Any]:
    return {
        "op": "trigger_draw_cards",
        "args": {
            "player": int(player_idx),
            "amount": int(count or 0),
            "source": str(source_name or ""),
        },
        "branches": {},
    }


def trigger_place_damage_counters_spec(
    player_idx: int,
    slot: str,
    counters: int,
    source_name: str = "",
    target_card_id: str = "",
) -> dict[str, Any]:
    return {
        "op": "trigger_place_damage_counters",
        "args": {
            "player": int(player_idx),
            "slot": str(slot or "active"),
            "count": int(counters or 0),
            "source": str(source_name or ""),
            "target_ref": {
                "kind": "pokemon",
                "player": int(player_idx),
                "slot": str(slot or "active"),
                "card_id": str(target_card_id or ""),
            },
        },
        "branches": {},
    }


def trigger_move_basic_energy_spec(
    from_player_idx: int,
    from_slot: str,
    to_player_idx: int,
    to_slot: str,
    source_name: str = "",
    *,
    select_source: bool = False,
    optional: bool = False,
    target_tool_id: str = "",
) -> dict[str, Any]:
    return {
        "op": "trigger_move_basic_energy",
        "args": {
            "from_player": int(from_player_idx),
            "from_slot": str(from_slot or "active"),
            "to_player": int(to_player_idx),
            "to_slot": str(to_slot or "active"),
            "source": str(source_name or ""),
            "select_source": bool(select_source),
            "optional": bool(optional),
            "target_tool_id": str(target_tool_id or ""),
        },
        "branches": {},
    }


def trigger_switch_with_active_spec(
    player_idx: int,
    bench_idx: int,
    source_name: str = "",
    slot: str = "",
) -> dict[str, Any]:
    bench_idx = _as_int(bench_idx, -1)
    return {
        "op": "trigger_switch_with_active",
        "args": {
            "player": int(player_idx),
            "bench_idx": bench_idx,
            "source": str(source_name or ""),
            "slot": str(slot or (f"bench_{bench_idx}" if bench_idx >= 0 else "")),
        },
        "branches": {},
    }


def collect_on_attach_command_specs(
    card: Any,
    player_idx: int,
    target_slot: str,
    source_zone: str = "hand",
) -> list[dict[str, Any]]:
    from engine.effects.event_bus import EventBus
    from engine.effects.modifier_manager import ModifierManager, ON_ATTACH

    manager = ModifierManager(EventBus())
    _register_on_attach_card_hooks(manager, card, player_idx)
    return command_specs_from_trigger_results(
        manager.emit(
            ON_ATTACH,
            card=card,
            player_idx=player_idx,
            target_slot=str(target_slot or ""),
            source_zone=str(source_zone or ""),
        )
    )


def _register_on_attach_card_hooks(manager: Any, card: Any, player_idx: int) -> None:
    from engine.effects.modifier_manager import ON_ATTACH

    for effect in getattr(card, "energy_effects", []) or []:
        if effect.get("kind") != "trigger" or effect.get("hook") != ON_ATTACH:
            continue
        effect_data = effect.get("effect") or {}
        if effect_data.get("op") != "switch_with_active":
            continue
        condition = dict(effect.get("condition") or {})
        priority = int(effect.get("priority", 0) or 0)
        source_name = str(getattr(card, "name", "") or getattr(card, "api_id", ""))
        manager.register(
            ON_ATTACH,
            lambda data, condition=condition, source_name=source_name:
                _on_attach_switch_with_active(data, condition, source_name),
            source=source_name or "on_attach",
            owner_player=player_idx,
            priority=priority,
        )


def _on_attach_switch_with_active(
    data: dict[str, Any],
    condition: dict[str, Any],
    source_name: str,
) -> dict[str, Any] | None:
    source_zone = str(data.get("source_zone", "") or "")
    target_slot = str(data.get("target_slot", "") or "")
    condition_zone = str(condition.get("from_zone", "") or "")
    if condition_zone and condition_zone != source_zone:
        return None
    if str(condition.get("target", "") or "") == "bench" and not target_slot.startswith("bench_"):
        return None
    try:
        bench_idx = int(target_slot.split("_", 1)[1])
    except (IndexError, ValueError):
        return None
    return {
        "source": source_name,
        "command_specs": [
            trigger_switch_with_active_spec(
                int(data.get("player_idx", 0) or 0),
                bench_idx,
                source_name,
                target_slot,
            )
        ],
    }


@dataclass
class PlaceDamageCountersOnPokemon:
    pokemon: Any = None
    counters: int = 0
    log_message: str = ""
    player_idx: int | None = None
    slot: str = ""
    expected_card_id: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        pokemon = self.pokemon or _pokemon_from_ref(ctx.state, self.player_idx, self.slot)
        if (
            pokemon is not None
            and self.expected_card_id
            and str(getattr(pokemon.card, "api_id", "") or "") != self.expected_card_id
        ):
            # Never retarget a delayed reaction to a replacement that happens
            # to occupy the old slot.
            pokemon = None
        if pokemon is None or int(self.counters or 0) <= 0:
            return CommandResult.ok()
        counters = int(self.counters or 0)
        pokemon.damage_counters += counters
        if self.log_message:
            ctx.state._log(self.log_message)
        return CommandResult.ok(self.log_message)


@dataclass
class DrawCardsForPlayer:
    player_idx: int
    count: int
    source_name: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        player = ctx.state.get_player(int(self.player_idx))
        drawn = player.draw_cards(max(0, int(self.count or 0)))
        if not drawn:
            return CommandResult.ok()
        source = f"{self.source_name}效果：" if self.source_name else ""
        message = f"{source}{player.name}抽取了{len(drawn)}张卡。"
        ctx.state._log(message)
        return CommandResult.ok(message, cards_drawn=drawn)


@dataclass
class MoveBasicEnergyBetweenPokemon:
    source_pokemon: Any = None
    target_pokemon: Any = None
    source_name: str = ""
    from_player_idx: int | None = None
    from_slot: str = ""
    to_player_idx: int | None = None
    to_slot: str = ""
    select_source: bool = False
    optional: bool = False
    target_tool_id: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        source_pokemon = self.source_pokemon or _pokemon_from_ref(
            ctx.state,
            self.from_player_idx,
            self.from_slot,
        )
        target_pokemon = self.target_pokemon or _pokemon_from_ref(
            ctx.state,
            self.to_player_idx,
            self.to_slot,
        )
        if source_pokemon is None or target_pokemon is None:
            return CommandResult.ok()
        basic_energies = [
            (index, card)
            for index, card in enumerate(list(getattr(source_pokemon, "energy_cards", []) or []))
            if getattr(card, "is_basic_energy", False)
        ]
        if not basic_energies:
            return CommandResult.ok()
        if self.select_source:
            from engine.game_state import ActionRequest

            source_card_id = str(getattr(source_pokemon.card, "api_id", "") or "")
            target_card_id = str(getattr(target_pokemon.card, "api_id", "") or "")
            continuation = {
                "kind": "confirm_exp_share_trigger",
                "domain": "trigger",
                "frame_id": (
                    f"trigger:exp_share:{self.from_player_idx}:{self.from_slot}:"
                    f"{self.to_player_idx}:{self.to_slot}"
                ),
                "from_player": int(self.from_player_idx),
                "from_slot": str(self.from_slot),
                "from_card_id": source_card_id,
                "to_player": int(self.to_player_idx),
                "to_slot": str(self.to_slot),
                "to_card_id": target_card_id,
                "source_name": str(self.source_name or "学习装置"),
                "target_tool_id": str(self.target_tool_id or ""),
            }
            return CommandResult.ok(
                pending_choice=ActionRequest(
                    request_type="confirm_trigger",
                    player=int(self.to_player_idx),
                    prompt=f"是否使用{self.source_name or '学习装置'}？",
                    min_select=1,
                    max_select=1,
                    continuation=continuation,
                )
            )
        for card in list(getattr(source_pokemon, "energy_cards", []) or []):
            if not getattr(card, "is_basic_energy", False):
                continue
            source_pokemon.energy_cards.remove(card)
            target_pokemon.energy_cards.append(card)
            source = f"{self.source_name}效果：" if self.source_name else ""
            message = f"{source}将{card.name}转附给{target_pokemon.card.name}。"
            ctx.state._log(message)
            return CommandResult.ok(message)
        return CommandResult.ok()


@dataclass
class TriggerOrderFrame:
    """Let the trigger owner choose the next entity trigger to resolve."""

    specs: list[dict[str, Any]]

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        specs = [dict(spec) for spec in self.specs or []]
        if not specs:
            return CommandResult.ok()
        grouped: dict[int, list[dict[str, Any]]] = {0: [], 1: []}
        for spec in specs:
            grouped[_trigger_owner(spec, ctx.player_idx)].append(spec)
        if grouped[0] and grouped[1]:
            ctx.stack.push_many([
                TriggerOrderFrame(grouped[owner])
                for owner in _trigger_group_order(ctx.state)
                if grouped[owner]
            ])
            return CommandResult.ok()
        if len(specs) == 1:
            ctx.stack.push_many(_compile_trigger_command_items(specs))
            return CommandResult.ok()

        from engine.game_state import ActionRequest

        chooser = _trigger_owner(specs[0], ctx.player_idx)
        return CommandResult.ok(
            pending_choice=ActionRequest(
                request_type="choose_trigger_order",
                player=chooser,
                prompt="选择下一个要结算的触发效果。",
                min_select=1,
                max_select=1,
                target_info=[
                    {
                        "index": index,
                        "label": str(
                            (spec.get("args", {}) or {}).get("source")
                            or spec.get("op", "触发效果")
                        ),
                        "op": str(spec.get("op", "") or ""),
                    }
                    for index, spec in enumerate(specs)
                ],
                continuation={
                    "kind": "choose_trigger_order",
                    "domain": "trigger",
                    "frame_id": "trigger:order",
                    "specs": specs,
                    "chooser": chooser,
                },
            )
        )


def _trigger_owner(spec: dict[str, Any], default: int = 0) -> int:
    args = spec.get("args", {}) if isinstance(spec, dict) else {}
    if not isinstance(args, dict):
        return int(default if default in (0, 1) else 0)
    value = args.get("to_player", args.get("player", args.get("player_idx", default)))
    return int(value) if type(value) is int and value in (0, 1) else int(default)


def _trigger_group_order(state: GameState) -> tuple[int, int]:
    """Return APNAP order, using the incoming player during Checkup."""
    from engine.enums import TurnPhase

    turn_owner = int(state.active_player_idx)
    if state.phase == TurnPhase.POKEMON_CHECKUP:
        return 1 - turn_owner, turn_owner
    return turn_owner, 1 - turn_owner


@dataclass
class SwitchWithActiveForPlayer:
    player_idx: int = 0
    bench_idx: int = -1
    source_name: str = ""
    slot: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        player_idx = int(self.player_idx)
        bench_idx = int(self.bench_idx)
        player = ctx.state.get_player(player_idx)
        if bench_idx < 0 or bench_idx >= len(player.bench):
            return CommandResult.ok()
        target = player.bench[bench_idx]
        if player.active is None or target is None:
            return CommandResult.ok()
        player.switch_active_to_bench(bench_idx)
        source = f"{self.source_name}效果：" if self.source_name else ""
        message = f"{source}将{target.card.name}切换为战斗宝可梦！"
        ctx.state._log(message)
        return CommandResult.ok(message)


def command_spec_from_trigger_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {}
    if isinstance(payload.get("args"), dict) and isinstance(payload.get("branches"), dict):
        return {
            "op": str(payload.get("op", "") or ""),
            "args": dict(payload.get("args", {}) or {}),
            "branches": dict(payload.get("branches", {}) or {}),
        }
    op = str(payload.get("op", "") or "")
    if op == "draw_cards":
        return trigger_draw_cards_spec(
            int(payload.get("player", payload.get("player_idx", 0)) or 0),
            int(payload.get("amount", payload.get("count", 0)) or 0),
            str(payload.get("source", payload.get("source_name", "")) or ""),
        )
    if op == "place_damage_counters":
        return trigger_place_damage_counters_spec(
            int(payload.get("player", payload.get("player_idx", 0)) or 0),
            str(payload.get("slot", "active") or "active"),
            int(payload.get("count", payload.get("counters", 0)) or 0),
            str(payload.get("source", payload.get("source_name", "")) or ""),
            str(payload.get("target_card_id", "") or ""),
        )
    if op == "move_basic_energy":
        from_player = _as_int(payload.get("from_player", payload.get("player", 0)), 0)
        return trigger_move_basic_energy_spec(
            from_player,
            str(payload.get("from_slot", "active") or "active"),
            _as_int(payload.get("to_player", from_player), from_player),
            str(payload.get("to_slot", "active") or "active"),
            str(payload.get("source", payload.get("source_name", "")) or ""),
        )
    if op == "switch_with_active":
        return trigger_switch_with_active_spec(
            _as_int(payload.get("player", payload.get("player_idx", 0)), 0),
            _as_int(payload.get("bench_idx", -1), -1),
            str(payload.get("source", payload.get("source_name", "")) or ""),
            str(payload.get("slot", "") or ""),
        )
    return {}


def command_specs_from_trigger_results(results: Iterable[Any]) -> list[dict[str, Any]]:
    specs: list[dict[str, Any]] = []
    claimed_groups: set[str] = set()
    for result in results:
        if not isinstance(result, dict):
            continue
        group = str(result.get("exclusive_group", "") or "")
        if group and group in claimed_groups:
            continue
        if isinstance(result.get("args"), dict) and isinstance(result.get("branches"), dict):
            specs.append(_require_trigger_command_spec(result))
            if group:
                claimed_groups.add(group)
            continue
        if "command_specs" not in result:
            continue
        raw_specs = result.get("command_specs")
        if raw_specs is None:
            continue
        if not isinstance(raw_specs, (list, tuple)):
            raise ValueError("Trigger command_specs must be a list of serializable VM command specs")
        appended = False
        for payload in raw_specs:
            if payload is None:
                continue
            spec = command_spec_from_trigger_payload(payload)
            if not spec:
                raise ValueError("Trigger payload must be a serializable VM command spec")
            specs.append(_require_trigger_command_spec(spec))
            appended = True
        if group and appended:
            claimed_groups.add(group)
    return specs


def execute_trigger_commands(
    state: GameState,
    commands: Iterable[dict[str, Any]],
    *,
    player_idx: int = 0,
    source_slot: str = "active",
) -> CommandResult:
    commands = list(commands or [])
    if not commands:
        return CommandResult.ok()
    from engine.commands.resolution_stack import ResolutionStack

    stack = ResolutionStack(state)
    try:
        normalized = _normalize_trigger_specs(commands)
        stack.push(TriggerOrderFrame(normalized))
    except (KeyError, TypeError, ValueError) as exc:
        return CommandResult(success=False, log_message=str(exc))
    rr = stack.resolve_all(player_idx, source_slot)
    return CommandResult(
        success=rr.success,
        log_message=" ".join(rr.log_messages),
        damage_dealt=rr.damage_dealt,
        cards_drawn=rr.cards_drawn,
        cards_discarded=rr.cards_discarded,
        pokemon_ko=rr.pokemon_ko,
        status_applied=rr.status_applied,
        pending_choice=rr.pending_choice,
        attack_failed=rr.attack_failed,
    )


def push_trigger_command_specs(stack: Any, specs: Iterable[Any]) -> None:
    normalized = _normalize_trigger_specs(specs)
    if normalized:
        stack.push(TriggerOrderFrame(normalized))


def retarget_pending_after_damage_entity(
    stack: Any,
    player_idx: int,
    from_slot: str,
    to_slot: str,
    card_id: str,
) -> None:
    """Move serialized reactive targets when a known Pokemon changes slots."""
    raw_specs = getattr(stack, "context", {}).get(
        "pending_after_damage_trigger_specs", []
    )
    if not isinstance(raw_specs, list):
        return
    for spec in raw_specs:
        if not isinstance(spec, dict) or spec.get("op") != "trigger_place_damage_counters":
            continue
        args = spec.get("args")
        if not isinstance(args, dict):
            continue
        target_ref = args.get("target_ref")
        if not isinstance(target_ref, dict):
            continue
        if (
            target_ref.get("player") != int(player_idx)
            or target_ref.get("slot") != str(from_slot)
            or target_ref.get("card_id") != str(card_id)
        ):
            continue
        target_ref["slot"] = str(to_slot)
        args["player"] = int(player_idx)
        args["slot"] = str(to_slot)


def _compile_trigger_command_items(items: Iterable[Any]) -> list[ICommand]:
    commands: list[ICommand] = []
    for item in items:
        spec = command_spec_from_trigger_payload(item)
        if spec:
            spec = _require_trigger_command_spec(spec)
            from engine.commands.dsl_compiler import compile_command_spec

            commands.append(compile_command_spec(spec))
            continue
        raise ValueError("Trigger payload must be a serializable VM command spec")
    return commands


def _normalize_trigger_specs(items: Iterable[Any]) -> list[dict[str, Any]]:
    specs: list[dict[str, Any]] = []
    for item in items:
        spec = command_spec_from_trigger_payload(item)
        if not spec:
            raise ValueError("Trigger payload must be a serializable VM command spec")
        specs.append(_require_trigger_command_spec(spec))
    return specs


def _require_trigger_command_spec(spec: dict[str, Any]) -> dict[str, Any]:
    op = str(spec.get("op", "") or "")
    if op not in TRIGGER_COMMAND_FACTORIES:
        raise ValueError(
            f"Trigger command specs must use registered trigger_* VM ops, got {op!r}"
        )
    return spec


def _source_log(source: str, default_message: str) -> str:
    source = str(source or "")
    return default_message if not source else f"{source}：{default_message}"


def _make_trigger_draw_cards(args: dict[str, Any], _branches: dict[str, Any]):
    return DrawCardsForPlayer(
        int(args.get("player", args.get("player_idx", 0)) or 0),
        int(args.get("amount", args.get("count", 0)) or 0),
        str(args.get("source", args.get("source_name", "")) or ""),
    )


def _make_trigger_place_damage_counters(args: dict[str, Any], _branches: dict[str, Any]):
    counters = int(args.get("count", args.get("counters", 0)) or 0)
    source = str(args.get("source", args.get("source_name", "")) or "")
    log_message = str(args.get("log_message", "") or "")
    if not log_message and counters > 0:
        log_message = _source_log(source, f"放置了{counters}个伤害指示物！")
    target_ref = args.get("target_ref", {})
    if not isinstance(target_ref, dict):
        target_ref = {}
    player_idx = _as_int(
        target_ref.get("player", args.get("player", args.get("player_idx", 0))),
        0,
    )
    slot = str(target_ref.get("slot", args.get("slot", "active")) or "active")
    return PlaceDamageCountersOnPokemon(
        None,
        counters,
        log_message,
        player_idx=player_idx,
        slot=slot,
        expected_card_id=str(target_ref.get("card_id", "") or ""),
    )


def _make_trigger_move_basic_energy(args: dict[str, Any], _branches: dict[str, Any]):
    from_player = _as_int(args.get("from_player", args.get("player", 0)), 0)
    return MoveBasicEnergyBetweenPokemon(
        None,
        None,
        str(args.get("source", args.get("source_name", "")) or ""),
        from_player_idx=from_player,
        from_slot=str(args.get("from_slot", "active") or "active"),
        to_player_idx=_as_int(args.get("to_player", from_player), from_player),
        to_slot=str(args.get("to_slot", "active") or "active"),
        select_source=bool(args.get("select_source", False)),
        optional=bool(args.get("optional", False)),
        target_tool_id=str(args.get("target_tool_id", "") or ""),
    )


def _make_trigger_switch_with_active(args: dict[str, Any], _branches: dict[str, Any]):
    return SwitchWithActiveForPlayer(
        player_idx=_as_int(args.get("player", args.get("player_idx", 0)), 0),
        bench_idx=_as_int(args.get("bench_idx", -1), -1),
        source_name=str(args.get("source", args.get("source_name", "")) or ""),
        slot=str(args.get("slot", "") or ""),
    )


TRIGGER_COMMAND_FACTORIES = {
    "trigger_draw_cards": _make_trigger_draw_cards,
    "trigger_place_damage_counters": _make_trigger_place_damage_counters,
    "trigger_move_basic_energy": _make_trigger_move_basic_energy,
    "trigger_switch_with_active": _make_trigger_switch_with_active,
}


__all__ = [
    "DrawCardsForPlayer",
    "MoveBasicEnergyBetweenPokemon",
    "PlaceDamageCountersOnPokemon",
    "SwitchWithActiveForPlayer",
    "TriggerOrderFrame",
    "TRIGGER_COMMAND_FACTORIES",
    "collect_on_attach_command_specs",
    "command_spec_from_trigger_payload",
    "command_specs_from_trigger_results",
    "execute_trigger_commands",
    "pokemon_ref_for_state",
    "push_trigger_command_specs",
    "retarget_pending_after_damage_entity",
    "trigger_draw_cards_spec",
    "trigger_move_basic_energy_spec",
    "trigger_place_damage_counters_spec",
    "trigger_switch_with_active_spec",
]

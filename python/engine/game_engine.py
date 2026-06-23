"""Authoritative action enumeration and execution facade."""
from __future__ import annotations

from itertools import combinations
from typing import Any, Callable

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
    PokemonRef,
    StepResult,
)
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.random_source import RandomSource
from engine.rules_validator import (
    can_attach_energy,
    can_declare_attack,
    can_evolve,
    can_play_item,
    can_play_stadium,
    can_play_supporter,
    can_play_tool,
    can_retreat,
    can_use_ability,
    effective_retreat_cost,
    energy_card_units,
)
from engine.snapshot import clone_state
from engine.turn_manager import TurnManager


class GameEngine:
    """Single rules-facing API used by gameplay, AI, and training."""

    def legal_actions(
        self,
        state: GameState,
        actor: int,
        *,
        validate_effects: bool = True,
    ) -> tuple[GameAction, ...]:
        raw = self._enumerate_actions(state, actor)
        if not validate_effects:
            return tuple(raw)

        validated: list[GameAction] = []
        for action in raw:
            if action.action not in {
                PlayerAction.PLAY_TRAINER,
                PlayerAction.USE_ABILITY,
                PlayerAction.USE_STADIUM,
            }:
                validated.append(action)
                continue
            simulation = clone_state(state)
            result = self.apply_action(
                simulation,
                action,
                RandomSource(0),
                auto_resolve=True,
                auto_finish_attack=True,
            )
            if result.success:
                validated.append(action)
        return tuple(validated)

    def apply_action(
        self,
        state: GameState,
        action: GameAction,
        rng: RandomSource | None = None,
        *,
        auto_resolve: bool = False,
        choice_policy: Callable[[GameState, ChoiceRequest], ChoiceResponse] | None = None,
        auto_finish_attack: bool = True,
    ) -> StepResult:
        rng = rng or RandomSource()
        actor = state.active_player_idx if action.actor is None else action.actor
        reference_error = self._validate_action_references(state, action)
        if reference_error:
            return StepResult(
                False,
                reference_error,
                error_code="stale_action_reference",
                winner=state.winner,
            )

        if action.action == "NOOP":
            return StepResult(True, action_result=ActionResult(True, ""), winner=state.winner)
        if action.action == "SETUP_DONE":
            return StepResult(True, "setup done", ActionResult(True, "setup done"), winner=state.winner)
        if action.action == "PROMOTE":
            return self._apply_promotion(state, actor, action)

        try:
            event_offset = len(getattr(state.event_stream, "_events", ()))
            with rng.bind_state(state):
                result = TurnManager(state).perform_action(
                    action.action,
                    player_idx=actor,
                    **dict(action.params),
                )
        except Exception as exc:
            return StepResult(False, str(exc), error_code="action_exception", winner=state.winner)

        step = self._step_from_action_result(
            state,
            result,
            events=self._events_since(state, event_offset),
        )
        if (
            auto_finish_attack
            and action.action == PlayerAction.DECLARE_ATTACK
            and step.pending_choice is not None
        ):
            step.pending_choice.metadata["finish_attack_actor"] = actor
        if auto_resolve:
            step = self._resolve_all_choices(state, step, rng, choice_policy)

        if (
            auto_finish_attack
            and step.success
            and action.action == PlayerAction.DECLARE_ATTACK
            and state.winner is None
            and state.phase == TurnPhase.ATTACK
            and step.pending_choice is None
        ):
            step = self._merge_steps(
                step,
                self._finish_attack_turn(
                    state,
                    actor,
                    rng,
                    auto_resolve=auto_resolve,
                    choice_policy=choice_policy,
                ),
            )

        step.winner = state.winner
        step.terminal = state.winner is not None or state.phase == TurnPhase.GAME_OVER
        return step

    def apply_choice(
        self,
        state: GameState,
        request: ChoiceRequest,
        response: ChoiceResponse,
        rng: RandomSource | None = None,
    ) -> StepResult:
        rng = rng or RandomSource()
        if response.request_id != request.request_id:
            return StepResult(False, "选择请求已过期。", error_code="stale_choice")
        if int(request.metadata.get("revision", getattr(state, "revision", 0))) != int(
            getattr(state, "revision", 0)
        ):
            return StepResult(False, "局面已变化，选择请求已过期。", error_code="stale_choice")
        if response.cancelled:
            if not request.can_cancel:
                return StepResult(False, "该选择不可取消。", error_code="choice_not_cancellable")
            self._cancel_pending_card(state, request.legacy_request)
            state.revision = getattr(state, "revision", 0) + 1
            return StepResult(True, "选择已取消。", winner=state.winner)

        option_map = {option.option_id: option for option in request.options}
        selected: list[ChoiceOption] = []
        for option_id in response.option_ids:
            option = option_map.get(option_id)
            if option is None:
                return StepResult(False, "包含无效选择项。", error_code="invalid_choice")
            selected.append(option)
        if not request.allow_duplicates and len(set(response.option_ids)) != len(response.option_ids):
            return StepResult(False, "该选择不允许重复目标。", error_code="duplicate_choice")
        if not (request.min_select <= len(selected) <= request.max_select):
            return StepResult(False, "选择数量不符合要求。", error_code="choice_count")

        legacy = request.legacy_request
        if legacy is None:
            return StepResult(False, "选择请求缺少解析上下文。", error_code="missing_continuation")

        try:
            event_offset = len(getattr(state.event_stream, "_events", ()))
            payload = self._legacy_choice_payload(legacy, selected, response)
            with rng.bind_state(state):
                callback_result = legacy.callback(payload) if legacy.callback else None
        except Exception as exc:
            return StepResult(False, str(exc), error_code="choice_exception", winner=state.winner)

        self._consume_pending_card(state, legacy)
        state.revision = getattr(state, "revision", 0) + 1
        if isinstance(callback_result, ActionRequest):
            result = ActionResult(True, pending_action=callback_result)
        elif isinstance(callback_result, ActionResult):
            result = callback_result
        else:
            result = ActionResult(True, "")
        step = self._step_from_action_result(
            state,
            result,
            events=self._events_since(state, event_offset),
        )
        attack_actor = request.metadata.get("finish_attack_actor")
        if step.pending_choice is not None and attack_actor in (0, 1):
            step.pending_choice.metadata["finish_attack_actor"] = int(attack_actor)
        elif (
            step.success
            and attack_actor in (0, 1)
            and state.winner is None
            and state.phase == TurnPhase.ATTACK
        ):
            step = self._merge_steps(
                step,
                self._finish_attack_turn(
                    state,
                    int(attack_actor),
                    rng,
                    auto_resolve=False,
                    choice_policy=None,
                ),
            )
        return step

    def _finish_attack_turn(
        self,
        state: GameState,
        actor: int,
        rng: RandomSource,
        *,
        auto_resolve: bool,
        choice_policy: Callable[[GameState, ChoiceRequest], ChoiceResponse] | None,
    ) -> StepResult:
        event_offset = len(getattr(state.event_stream, "_events", ()))
        with rng.bind_state(state):
            result = TurnManager(state).perform_action(
                PlayerAction.END_TURN,
                player_idx=actor,
            )
        step = self._step_from_action_result(
            state,
            result,
            events=self._events_since(state, event_offset),
        )
        if auto_resolve:
            step = self._resolve_all_choices(state, step, rng, choice_policy)
        return step

    def choice_request(self, state: GameState, request: ActionRequest) -> ChoiceRequest:
        if request.request_id:
            request_id = request.request_id
        else:
            sequence = int(getattr(state, "choice_sequence", 0))
            state.choice_sequence = sequence + 1
            request_id = (
                f"choice:{getattr(state, 'revision', 0)}:{request.player}:"
                f"{request.request_type}:{sequence}"
            )
        request.request_id = request_id
        options = tuple(self._choice_options(state, request))
        min_select = max(0, int(request.min_select))
        max_select = max(0, int(request.max_select))
        allow_duplicates = bool(request.allow_duplicates)
        if request.request_type == "coin_flip":
            if request.until_tails:
                min_select, max_select = 1, 32
            else:
                min_select = max_select = max(1, int(request.flip_count or 1))
            allow_duplicates = True
        elif request.request_type == "distribute_energy":
            if request.distribute_mode == "source_select":
                min_select = max_select = 1
            else:
                amount = max(1, len(request.card_list))
                min_select = max_select = amount
                allow_duplicates = True
        can_cancel = min_select <= 0 or bool(getattr(request, "can_cancel", False))
        return ChoiceRequest(
            request_id=request_id,
            request_type=request.request_type,
            player=request.player,
            prompt=request.prompt,
            options=options,
            min_select=min_select,
            max_select=max_select,
            allow_duplicates=allow_duplicates,
            can_cancel=can_cancel,
            metadata={
                "from_zone": request.from_zone,
                "target_player": request.target_player,
                "distribute_mode": request.distribute_mode,
                "flip_count": request.flip_count,
                "until_tails": request.until_tails,
                "revision": getattr(state, "revision", 0),
            },
            legacy_request=request,
        )

    def choice_response_from_legacy(
        self,
        request: ChoiceRequest,
        payload,
        *,
        cancelled: bool = False,
    ) -> ChoiceResponse:
        """Map transitional UI payloads to stable option IDs."""
        if cancelled:
            return ChoiceResponse(request.request_id, (), True)
        if request.request_type == "coin_flip":
            return ChoiceResponse(
                request.request_id,
                tuple("coin:heads" if value else "coin:tails" for value in payload or []),
            )
        if request.request_type == "confirm":
            return ChoiceResponse(
                request.request_id,
                ("confirm:yes" if payload else "confirm:no",),
            )
        if request.request_type in {
            "select_bench",
            "select_opponent_bench",
            "select_own_bench_energy",
        }:
            option = next(
                (option for option in request.options if option.value == payload),
                None,
            )
            return ChoiceResponse(
                request.request_id,
                (option.option_id,) if option is not None else (),
            )
        if request.request_type == "select_bench_targets":
            option_ids = []
            for target in payload or []:
                match = next(
                    (option for option in request.options if option.value == target),
                    None,
                )
                if match is not None:
                    option_ids.append(match.option_id)
            return ChoiceResponse(request.request_id, tuple(option_ids))
        if request.request_type == "distribute_energy":
            option_ids = []
            for _energy_idx, slot in payload or []:
                match = next(
                    (
                        option for option in request.options
                        if isinstance(option.value, dict)
                        and str(option.value.get("slot", "")) == str(slot)
                    ),
                    None,
                )
                if match is not None:
                    option_ids.append(match.option_id)
            return ChoiceResponse(request.request_id, tuple(option_ids))

        unused = list(request.options)
        option_ids = []
        for selected in payload or []:
            match = next(
                (
                    option for option in unused
                    if option.value is selected
                    or getattr(option.value, "api_id", None)
                    == getattr(selected, "api_id", None)
                ),
                None,
            )
            if match is not None:
                option_ids.append(match.option_id)
                unused.remove(match)
        return ChoiceResponse(request.request_id, tuple(option_ids))

    def _enumerate_actions(self, state: GameState, actor: int) -> list[GameAction]:
        if state.pending_promotion_player >= 0:
            if actor != state.pending_promotion_player:
                return []
            player = state.get_player(actor)
            return [
                GameAction(
                    "PROMOTE",
                    {"bench_idx": bench_idx},
                    actor=actor,
                    target=PokemonRef(actor, f"bench_{bench_idx}", pokemon.card.api_id),
                )
                for bench_idx, pokemon in enumerate(player.bench)
                if pokemon is not None
            ]
        if state.phase == TurnPhase.SETUP:
            return self._setup_actions(state, actor)
        if state.phase == TurnPhase.ATTACK:
            if state.active_player_idx == actor:
                return [GameAction(PlayerAction.END_TURN, {}, True, actor)]
            return []
        if state.phase != TurnPhase.MAIN or state.active_player_idx != actor:
            return []

        player = state.get_player(actor)
        actions: list[GameAction] = []
        seen: set[tuple] = set()

        def add(action: GameAction):
            if action.signature not in seen:
                seen.add(action.signature)
                actions.append(action)

        empty_slots = [f"bench_{idx}" for idx, pokemon in enumerate(player.bench) if pokemon is None]
        for hand_idx, card in enumerate(player.hand):
            source = CardRef(actor, "hand", hand_idx, card.api_id)
            if card.is_basic_pokemon:
                for target_slot in empty_slots:
                    add(GameAction(
                        PlayerAction.PLAY_BASIC,
                        {"hand_idx": hand_idx, "target": target_slot},
                        actor=actor,
                        source=source,
                        target=PokemonRef(actor, target_slot, ""),
                    ))
            elif card.is_stage1 or card.is_stage2:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_evolve(state, actor, slot, card)[0]:
                        add(GameAction(
                            PlayerAction.EVOLVE,
                            {"hand_idx": hand_idx, "slot": slot},
                            actor=actor,
                            source=source,
                            target=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))
            elif card.is_energy:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_attach_energy(state, actor, card, slot)[0]:
                        add(GameAction(
                            PlayerAction.ATTACH_ENERGY,
                            {"hand_idx": hand_idx, "target_slot": slot},
                            actor=actor,
                            source=source,
                            target=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))
            elif card.is_trainer_tool:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_play_tool(state, actor, slot)[0]:
                        add(GameAction(
                            PlayerAction.PLAY_TRAINER,
                            {"hand_idx": hand_idx, "target_slot": slot},
                            actor=actor,
                            source=source,
                            target=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))
            elif card.is_trainer_supporter and can_play_supporter(state, actor)[0]:
                add(GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}, actor=actor, source=source))
            elif card.is_trainer_stadium and can_play_stadium(state, actor, card)[0]:
                add(GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}, actor=actor, source=source))
            elif card.is_trainer_item and can_play_item(state, actor)[0]:
                add(GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}, actor=actor, source=source))

        for slot, pokemon in player.get_all_pokemon():
            if pokemon is None:
                continue
            for ability in pokemon.card.abilities:
                if can_use_ability(state, actor, slot, ability.name)[0]:
                    add(GameAction(
                        PlayerAction.USE_ABILITY,
                        {"slot": slot, "ability_name": ability.name},
                        actor=actor,
                        source=PokemonRef(actor, slot, pokemon.card.api_id),
                    ))

        if self._stadium_is_activatable(state) and not player.stadium_used_this_turn:
            add(GameAction(PlayerAction.USE_STADIUM, {}, actor=actor))

        for bench_idx, pokemon in enumerate(player.bench):
            if pokemon is None:
                continue
            for payment in self._retreat_payments(state, actor, bench_idx):
                add(GameAction(
                    PlayerAction.RETREAT,
                    {"bench_idx": bench_idx, "energy_indices": list(payment)},
                    actor=actor,
                    target=PokemonRef(actor, f"bench_{bench_idx}", pokemon.card.api_id),
                ))

        if player.active:
            for attack_idx, _attack in enumerate(player.active.card.attacks):
                if can_declare_attack(state, actor, attack_idx)[0]:
                    add(GameAction(
                        PlayerAction.DECLARE_ATTACK,
                        {"attack_idx": attack_idx},
                        True,
                        actor,
                        source=PokemonRef(actor, "active", player.active.card.api_id),
                    ))

        add(GameAction(PlayerAction.END_TURN, {}, True, actor))
        return actions

    def _setup_actions(self, state: GameState, actor: int) -> list[GameAction]:
        player = state.get_player(actor)
        actions: list[GameAction] = []
        empty_slots = [idx for idx, pokemon in enumerate(player.bench) if pokemon is None]
        for hand_idx, card in enumerate(player.hand):
            if not card.is_basic_pokemon:
                continue
            source = CardRef(actor, "hand", hand_idx, card.api_id)
            if player.active is None:
                actions.append(GameAction(
                    PlayerAction.PLAY_BASIC,
                    {"hand_idx": hand_idx, "target": "active"},
                    actor=actor,
                    source=source,
                    target=PokemonRef(actor, "active", ""),
                ))
            elif empty_slots:
                for bench_idx in empty_slots:
                    target = f"bench_{bench_idx}"
                    actions.append(GameAction(
                        PlayerAction.PLAY_BASIC,
                        {"hand_idx": hand_idx, "target": target},
                        actor=actor,
                        source=source,
                        target=PokemonRef(actor, target, ""),
                    ))
        if player.active is not None:
            actions.append(GameAction("SETUP_DONE", {}, True, actor))
        return actions

    def _retreat_payments(self, state: GameState, actor: int, bench_idx: int) -> tuple[tuple[int, ...], ...]:
        player = state.get_player(actor)
        if not can_retreat(state, actor, bench_idx)[0] or player.active is None:
            return ()
        cost = effective_retreat_cost(state, player)
        if cost <= 0:
            return ((),)
        cards = player.active.energy_cards
        payments: list[tuple[int, ...]] = []
        for size in range(1, len(cards) + 1):
            for indices in combinations(range(len(cards)), size):
                units = sum(energy_card_units(cards[index], player.active) for index in indices)
                if units < cost:
                    continue
                if any(
                    sum(energy_card_units(cards[index], player.active) for index in subset) >= cost
                    for subset_size in range(1, len(indices))
                    for subset in combinations(indices, subset_size)
                ):
                    continue
                payments.append(indices)
        return tuple(payments)

    @staticmethod
    def _apply_promotion(state: GameState, actor: int, action: GameAction) -> StepResult:
        if state.pending_promotion_player != actor:
            return StepResult(False, "当前没有该玩家的晋升请求。", error_code="invalid_promotion")
        bench_idx = action.params.get("bench_idx")
        player = state.get_player(actor)
        if (
            not isinstance(bench_idx, int)
            or not (0 <= bench_idx < len(player.bench))
            or player.bench[bench_idx] is None
        ):
            return StepResult(False, "晋升目标无效。", error_code="invalid_promotion_target")
        if player.active is not None:
            return StepResult(False, "战斗区不为空，不能执行晋升。", error_code="active_not_empty")
        player.promote_from_bench(bench_idx)
        message = f"{player.name}将{player.active.card.name}提升至战斗区。"
        state._log(message)
        manager = TurnManager(state)
        if state.phase == TurnPhase.DRAW:
            manager.continue_after_promotion()
        else:
            state.pop_pending_promotion()
        state.revision = getattr(state, "revision", 0) + 1
        return StepResult(
            True,
            message,
            ActionResult(True, message),
            winner=state.winner,
            terminal=state.winner is not None or state.phase == TurnPhase.GAME_OVER,
        )

    @staticmethod
    def _stadium_is_activatable(state: GameState) -> bool:
        stadium = state.stadium_card
        if stadium is None:
            return False
        return any(
            getattr(effect, "params", {}).get("stadium_type") == "activatable"
            for effect in stadium.trainer_effects
        )

    def _resolve_all_choices(
        self,
        state: GameState,
        step: StepResult,
        rng: RandomSource,
        choice_policy: Callable[[GameState, ChoiceRequest], ChoiceResponse] | None,
    ) -> StepResult:
        guard = 0
        aggregate = step
        while aggregate.success and aggregate.pending_choice is not None and guard < 32:
            guard += 1
            request = aggregate.pending_choice
            response = (
                choice_policy(state, request)
                if choice_policy is not None
                else self._default_choice_response(request, rng)
            )
            next_step = self.apply_choice(state, request, response, rng)
            aggregate = self._merge_steps(aggregate, next_step)
        if guard >= 32 and aggregate.pending_choice is not None:
            aggregate.success = False
            aggregate.error_code = "choice_loop"
            aggregate.message = "选择链超过安全上限。"
        return aggregate

    def _default_choice_response(self, request: ChoiceRequest, rng: RandomSource) -> ChoiceResponse:
        if request.request_type == "coin_flip":
            flip_count = int(request.metadata.get("flip_count", 1) or 1)
            until_tails = bool(request.metadata.get("until_tails", False))
            results: list[str] = []
            if until_tails:
                for _ in range(32):
                    option_id = "coin:heads" if rng.coin() else "coin:tails"
                    results.append(option_id)
                    if option_id.endswith("tails"):
                        break
            else:
                results = [
                    "coin:heads" if rng.coin() else "coin:tails"
                    for _ in range(max(1, flip_count))
                ]
            return ChoiceResponse(request.request_id, tuple(results))
        count = min(len(request.options), max(request.min_select, min(request.max_select, len(request.options))))
        return ChoiceResponse(request.request_id, tuple(option.option_id for option in request.options[:count]))

    def _step_from_action_result(
        self,
        state: GameState,
        result: ActionResult,
        *,
        events: tuple[dict[str, Any], ...] = (),
    ) -> StepResult:
        pending = self.choice_request(state, result.pending_action) if result.pending_action else None
        return StepResult(
            success=bool(result.success),
            message=result.log_message,
            action_result=result,
            pending_choice=pending,
            events=events,
            winner=state.winner,
            terminal=state.winner is not None or state.phase == TurnPhase.GAME_OVER,
        )

    @staticmethod
    def _merge_steps(first: StepResult, second: StepResult) -> StepResult:
        message = " ".join(part for part in (first.message, second.message) if part)
        return StepResult(
            success=first.success and second.success,
            message=message,
            action_result=GameEngine._combine_action_results(
                first.action_result,
                second.action_result,
            ),
            pending_choice=second.pending_choice,
            events=first.events + second.events,
            winner=second.winner,
            terminal=second.terminal,
            error_code=second.error_code or first.error_code,
        )

    @staticmethod
    def _events_since(state: GameState, offset: int) -> tuple[dict[str, Any], ...]:
        events = list(getattr(state.event_stream, "_events", ()))[offset:]
        return tuple(
            {
                "event_type": getattr(event, "event_type", ""),
                "data": dict(getattr(event, "data", {}) or {}),
            }
            for event in events
        )

    @staticmethod
    def _combine_action_results(first: ActionResult | None, second: ActionResult | None):
        if first is None:
            return second
        if second is None:
            return first
        return ActionResult(
            success=first.success and second.success,
            log_message=" ".join(
                part for part in (first.log_message, second.log_message) if part
            ),
            damage_dealt=first.damage_dealt + second.damage_dealt,
            cards_drawn=list(first.cards_drawn) + list(second.cards_drawn),
            cards_discarded=first.cards_discarded + second.cards_discarded,
            pokemon_ko=list(first.pokemon_ko) + list(second.pokemon_ko),
            status_applied=list(first.status_applied) + list(second.status_applied),
            prize_taken=first.prize_taken or second.prize_taken,
            pending_action=second.pending_action,
            attack_failed=first.attack_failed or second.attack_failed,
        )

    def _choice_options(self, state: GameState, request: ActionRequest) -> list[ChoiceOption]:
        if request.request_type == "coin_flip":
            return [
                ChoiceOption("coin:heads", "正面", value=True),
                ChoiceOption("coin:tails", "反面", value=False),
            ]
        if request.request_type in {"select_bench", "select_opponent_bench", "select_own_bench_energy"}:
            target_idx = self._choice_target_player_idx(state, request)
            player = state.get_player(target_idx)
            allowed = request.bench_indices or list(range(len(player.bench)))
            return [
                ChoiceOption(
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id).ref_id,
                    pokemon.card.name,
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id),
                    idx,
                )
                for idx in allowed
                if 0 <= idx < len(player.bench) and (pokemon := player.bench[idx]) is not None
            ]
        if request.request_type == "select_bench_targets":
            target_idx = self._choice_target_player_idx(state, request)
            player = state.get_player(target_idx)
            allowed = request.bench_indices or list(range(len(player.bench)))
            return [
                ChoiceOption(
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id).ref_id,
                    pokemon.card.name,
                    PokemonRef(target_idx, f"bench_{idx}", pokemon.card.api_id),
                    idx,
                )
                for idx in allowed
                if 0 <= idx < len(player.bench) and (pokemon := player.bench[idx]) is not None
            ]
        if request.request_type == "confirm":
            return [
                ChoiceOption("confirm:yes", "是", value=True),
                ChoiceOption("confirm:no", "否", value=False),
            ]
        if request.request_type == "distribute_energy":
            options = []
            for idx, target in enumerate(request.target_info or []):
                slot = str(target.get("slot", ""))
                player_idx = request.player if request.player in (0, 1) else state.active_player_idx
                pokemon = state.get_player(player_idx).get_pokemon(slot)
                ref = PokemonRef(player_idx, slot, pokemon.card.api_id if pokemon else "")
                options.append(ChoiceOption(ref.ref_id, target.get("name", slot), ref, target))
            return options

        refs = self._card_list_refs(state, request)
        return [
            ChoiceOption(ref.ref_id, getattr(card, "name", str(card)), ref, card)
            for ref, card in refs
        ]

    def _card_list_refs(self, state: GameState, request: ActionRequest):
        if request.from_zone in {"board", "bench"}:
            return self._board_card_refs(state, request)
        player_idx = request.player if request.player in (0, 1) else state.active_player_idx
        zone = request.from_zone or "choices"
        return [
            (CardRef(player_idx, zone, idx, getattr(card, "api_id", "")), card)
            for idx, card in enumerate(request.card_list)
        ]

    def _board_card_refs(self, state: GameState, request: ActionRequest):
        candidate_ids = [getattr(card, "api_id", "") for card in request.card_list]
        refs = []
        player_order = [self._choice_target_player_idx(state, request)]
        if request.target_player == "" and request.from_zone == "board":
            player_order = [1 - request.player, request.player] if request.player in (0, 1) else [0, 1]
        remaining = list(candidate_ids)
        for player_idx in player_order:
            for slot, pokemon in state.get_player(player_idx).get_all_pokemon():
                if pokemon is None or pokemon.card.api_id not in remaining:
                    continue
                remaining.remove(pokemon.card.api_id)
                refs.append((PokemonRef(player_idx, slot, pokemon.card.api_id), pokemon.card))
        while len(refs) < len(request.card_list):
            idx = len(refs)
            card = request.card_list[idx]
            refs.append((CardRef(request.player, request.from_zone or "choices", idx, card.api_id), card))
        return refs

    @staticmethod
    def _choice_target_player_idx(state: GameState, request: ActionRequest) -> int:
        owner = request.player if request.player in (0, 1) else state.active_player_idx
        if request.target_player == "opponent" or request.request_type == "select_opponent_bench":
            return 1 - owner
        return owner

    @staticmethod
    def _legacy_choice_payload(
        request: ActionRequest,
        selected: list[ChoiceOption],
        response: ChoiceResponse,
    ):
        if request.request_type == "coin_flip":
            return [option_id == "coin:heads" for option_id in response.option_ids]
        if request.request_type == "confirm":
            return bool(selected and selected[0].value)
        if request.request_type in {"select_bench", "select_opponent_bench", "select_own_bench_energy"}:
            return int(selected[0].value) if selected else None
        if request.request_type == "select_bench_targets":
            return [int(option.value) for option in selected]
        if request.request_type == "distribute_energy":
            if request.distribute_mode == "source_select":
                return [(0, str(selected[0].value.get("slot", "")))] if selected else []
            return [
                (energy_idx, str(option.value.get("slot", "")))
                for energy_idx, option in enumerate(selected)
            ]
        pokemon_refs = [option.ref for option in selected if isinstance(option.ref, PokemonRef)]
        if pokemon_refs:
            return pokemon_refs
        return [option.value for option in selected]

    @staticmethod
    def _consume_pending_card(state: GameState, request: ActionRequest) -> None:
        card = request.pending_card
        if card is None:
            return
        player_idx = request.player if request.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)
        if all(existing is not card for existing in player.discard) and card not in player.hand:
            if card.is_trainer_supporter or card.is_trainer_item:
                player.discard.append(card)
        request.pending_card = None

    @staticmethod
    def _cancel_pending_card(state: GameState, request: ActionRequest | None) -> None:
        if request is None or request.pending_card is None:
            return
        card = request.pending_card
        player_idx = request.player if request.player in (0, 1) else state.active_player_idx
        player = state.get_player(player_idx)
        if all(existing is not card for existing in player.hand):
            player.hand.append(card)
        if getattr(card, "is_trainer_supporter", False):
            player.supporter_played_this_turn = False
        request.pending_card = None

    @staticmethod
    def _validate_action_references(state: GameState, action: GameAction) -> str:
        for ref in (action.source, action.target):
            if ref is None:
                continue
            if isinstance(ref, CardRef):
                if ref.player not in (0, 1):
                    return "卡牌引用的玩家无效。"
                zone = getattr(state.get_player(ref.player), ref.zone, None)
                if not isinstance(zone, list):
                    continue
                if not (0 <= ref.index < len(zone)):
                    return "卡牌引用已失效。"
                card = zone[ref.index]
                if ref.card_id and getattr(card, "api_id", "") != ref.card_id:
                    return "卡牌引用与当前局面不一致。"
            elif isinstance(ref, PokemonRef):
                if ref.player not in (0, 1):
                    return "宝可梦引用的玩家无效。"
                pokemon = state.get_player(ref.player).get_pokemon(ref.slot)
                # Empty setup destinations intentionally have no current card.
                if pokemon is None:
                    if ref.card_id:
                        return "宝可梦引用已失效。"
                    continue
                if ref.card_id and pokemon.card.api_id != ref.card_id:
                    return "宝可梦引用与当前局面不一致。"
            elif isinstance(ref, AttachmentRef):
                if ref.player not in (0, 1):
                    return "附着卡引用的玩家无效。"
                pokemon = state.get_player(ref.player).get_pokemon(ref.slot)
                if pokemon is None:
                    return "附着卡所属宝可梦已不存在。"
                attachments = (
                    pokemon.energy_cards
                    if ref.attachment_type == "energy"
                    else [pokemon.attached_tool] if pokemon.attached_tool else []
                )
                if not (0 <= ref.index < len(attachments)):
                    return "附着卡引用已失效。"
                if ref.card_id and attachments[ref.index].api_id != ref.card_id:
                    return "附着卡引用与当前局面不一致。"
        return ""


DEFAULT_GAME_ENGINE = GameEngine()

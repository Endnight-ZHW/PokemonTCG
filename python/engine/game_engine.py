"""Python state adapter for the authoritative C++ rules core."""
from __future__ import annotations

import copy
from typing import Any, Callable, Mapping

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceView,
    ChoiceResponse,
    GameAction,
    PokemonRef,
    SlotRef,
    StepResult,
)
from engine.enums import PlayerAction
from engine.game_state import GameState
from engine.native_state_codec import (
    adopt_native_snapshot,
    native_catalog_payload,
    state_to_native_snapshot,
)
from engine.random_source import PortableRandomSourceV1, RandomSource


class NativeChoiceAdapter:
    """Choice DTO helpers; settlement remains exclusively in ptcg_core."""

    def default_choice_response(
        self,
        request: ChoiceView,
        _rng: RandomSource | None = None,
    ) -> ChoiceResponse:
        if request.request_type == "coin_flip":
            return ChoiceResponse(request.request_id, ())
        if request.request_type == "choose_turn_order":
            return ChoiceResponse(request.request_id, ("turn:first",))
        if request.request_type == "choose_mulligan_draw_count":
            draws = [
                option.option_id
                for option in request.options
                if option.option_id.startswith("draw:")
            ]
            selected = max(
                draws,
                key=lambda value: int(value[5:]),
                default="draw:0",
            )
            return ChoiceResponse(request.request_id, (selected,))
        if request.request_type == "select_retreat_payment":
            return self._retreat_payment(request)
        if request.request_type in {"confirm", "confirm_trigger"}:
            yes = next(
                (
                    row.option_id
                    for row in request.options
                    if row.option_id == "confirm:yes"
                ),
                request.options[0].option_id if request.options else "",
            )
            return ChoiceResponse(request.request_id, (yes,) if yes else ())
        count = max(0, int(request.min_select))
        if not request.allow_duplicates:
            selected = tuple(
                option.option_id for option in request.options[:count]
            )
        elif request.options:
            selected = tuple(
                request.options[0].option_id for _ in range(count)
            )
        else:
            selected = ()
        return ChoiceResponse(
            request.request_id,
            selected,
            bool(request.can_cancel and count > 0 and not selected),
        )

    @staticmethod
    def _retreat_payment(request: ChoiceView) -> ChoiceResponse:
        required = max(0, int(request.presentation.get("required_units", 0)))
        if required <= 0:
            return ChoiceResponse(request.request_id, ())
        cards = native_catalog_payload()["cards"]
        candidates: list[tuple[str, int]] = []
        for option in request.options:
            card_id = (
                option.ref.card_id
                if isinstance(option.ref, AttachmentRef)
                else ""
            )
            definition = cards.get(card_id, {})
            units = len(definition.get("provides_energy", []) or [])
            candidates.append((option.option_id, max(1, units)))
        candidates.sort(key=lambda row: (-row[1], row[0]))
        selected: list[tuple[str, int]] = []
        paid = 0
        for candidate in candidates:
            selected.append(candidate)
            paid += candidate[1]
            if paid >= required:
                break
        if paid < required:
            return ChoiceResponse(request.request_id, (), request.can_cancel)
        for index in range(len(selected) - 1, -1, -1):
            if paid - selected[index][1] >= required:
                paid -= selected[index][1]
                selected.pop(index)
        return ChoiceResponse(
            request.request_id,
            tuple(option_id for option_id, _units in selected),
        )


class GameEngine:
    """Project ``NativeRulesSession`` ABI 2 results into Python AI state."""

    def __init__(self, *_args, **_kwargs) -> None:
        self.choice_manager = NativeChoiceAdapter()
        self._action_sequence = 0

    def begin_game(
        self,
        state: GameState,
        deck1: list[str],
        deck2: list[str],
        rng: RandomSource | None = None,
    ) -> StepResult:
        rng = rng or PortableRandomSourceV1(1)
        try:
            native = _native_module()
            session = native.NativeRulesSession()
            result = session.create(
                native_catalog_payload(),
                [list(deck1), list(deck2)],
                {
                    "public_deck_keys": [
                        str(value or "")
                        for value in getattr(
                            state, "public_deck_keys", ("", "")
                        )
                    ],
                    "player_names": [state.p1.name, state.p2.name],
                    "rules_profile_id": state.rules_profile_id,
                    "rules_options": copy.deepcopy(state.rules_options),
                },
                _rng_state(rng),
            )
        except Exception as error:
            return _failure(state, "native_create_failed", error)
        return self._adopt_result(state, rng, result)

    def legal_actions(
        self,
        state: GameState,
        actor: int,
        *,
        validate_effects: bool = True,
    ) -> tuple[GameAction, ...]:
        del validate_effects
        if type(actor) is not int or actor not in (0, 1):
            return ()
        try:
            session = self._restore_session(state, _state_rng(state))
            query = session.legal_actions(actor)
            if not bool(query.get("success", False)):
                return ()
            return tuple(_flatten_actions(query))
        except Exception:
            return ()

    def pending_choice(
        self,
        state: GameState,
    ) -> ChoiceView | None:
        try:
            session = self._restore_session(state, _state_rng(state))
            for viewer in (0, 1):
                pending = session.pending_choice(viewer)
                if isinstance(pending, dict):
                    return _choice_from_native(pending)
        except Exception:
            return None
        return None

    def apply_action(
        self,
        state: GameState,
        action: GameAction,
        rng: RandomSource | None = None,
        *,
        auto_resolve: bool = False,
        choice_policy: Callable[
            [GameState, ChoiceView], ChoiceResponse
        ] | None = None,
        auto_finish_attack: bool = True,
    ) -> StepResult:
        del auto_finish_attack
        rng = rng or PortableRandomSourceV1(_state_rng(state))
        step = self._apply_action_once(state, action, rng)
        if not step.success or not auto_resolve:
            return step
        events = list(step.events)
        guard = 0
        while step.pending_choice is not None and guard < 64:
            guard += 1
            response = (
                choice_policy(state, step.pending_choice)
                if choice_policy is not None
                else self.choice_manager.default_choice_response(
                    step.pending_choice, rng
                )
            )
            if not isinstance(response, ChoiceResponse):
                response = self.choice_manager.default_choice_response(
                    step.pending_choice, rng
                )
            step = self.apply_choice(state, response, rng)
            events.extend(step.events)
            if not step.success:
                return step
        if step.pending_choice is not None:
            return StepResult(
                False,
                "native_choice_guard",
                error_code="native_choice_guard",
                winner=state.winner,
                terminal=state.is_terminal(),
            )
        step.events = tuple(events)
        return step

    def _apply_action_once(
        self,
        state: GameState,
        action: GameAction,
        rng: RandomSource,
    ) -> StepResult:
        if not isinstance(action, GameAction):
            return _failure(state, "invalid_action")
        actor = state.active_player_idx if action.actor is None else action.actor
        try:
            session = self._restore_session(state, _rng_state(rng))
            query = session.legal_actions(int(actor))
            native_action = _matching_native_action(query, action, int(actor))
            if native_action is None:
                return _failure(state, "illegal_action")
            if not action.action_id:
                self._action_sequence += 1
                native_action["action_id"] = (
                    f"python-native:{state.revision}:{self._action_sequence}"
                )
            else:
                native_action["action_id"] = str(action.action_id)
            result = session.apply_action(native_action)
        except Exception as error:
            return _failure(state, "native_action_failed", error)
        return self._adopt_result(state, rng, result)

    def apply_choice(
        self,
        state: GameState,
        response: ChoiceResponse,
        rng: RandomSource | None = None,
    ) -> StepResult:
        if not isinstance(response, ChoiceResponse):
            return _failure(state, "invalid_choice")
        rng = rng or PortableRandomSourceV1(_state_rng(state))
        try:
            session = self._restore_session(state, _rng_state(rng))
            result = session.apply_choice({
                "request_id": str(response.request_id),
                "option_ids": [
                    str(value) for value in response.option_ids
                ],
                "cancelled": bool(response.cancelled),
            })
        except Exception as error:
            return _failure(state, "native_choice_failed", error)
        return self._adopt_result(state, rng, result)

    def surrender(self, state: GameState, actor: int) -> StepResult:
        rng = PortableRandomSourceV1(_state_rng(state))
        try:
            session = self._restore_session(state, _rng_state(rng))
            result = session.surrender(int(actor))
        except Exception as error:
            return _failure(state, "native_surrender_failed", error)
        return self._adopt_result(state, rng, result)

    def _restore_session(self, state: GameState, rng_state: int):
        native = _native_module()
        session = native.NativeRulesSession()
        session.set_catalog(native_catalog_payload())
        restored = session.restore(
            state_to_native_snapshot(state),
            int(rng_state) & 0xFFFFFFFF,
        )
        if not bool(restored.get("success", False)):
            raise ValueError(
                restored.get("error_code", "native_restore_failed")
            )
        return session

    @staticmethod
    def _adopt_result(
        state: GameState,
        rng: RandomSource,
        result: Mapping[str, Any],
    ) -> StepResult:
        success = bool(result.get("success", False))
        if success:
            adopt_native_snapshot(
                state,
                result.get("state", {}),
                rng_state=int(result.get("rng_state", 0)),
            )
            _set_rng_state(rng, int(result.get("rng_state", 0)))
        pending = (
            _choice_from_native(result["pending"])
            if success and isinstance(result.get("pending"), dict)
            else None
        )
        message = str(
            result.get("message_key")
            or result.get("error_code")
            or ""
        )
        winner = int(result.get("winner", -1))
        return StepResult(
            success=success,
            message=message,
            pending_choice=pending,
            events=tuple(copy.deepcopy(list(result.get("events", []) or []))),
            winner=winner if winner in (0, 1) else None,
            terminal=bool(result.get("terminal", False)),
            error_code=str(result.get("error_code", "")),
        )


def _native_module():
    try:
        import ptcg_ai_core
    except ImportError:
        from python import ptcg_ai_core  # type: ignore
    if int(ptcg_ai_core.abi_version()) != 2:
        raise RuntimeError("native_rules_abi_mismatch")
    return ptcg_ai_core


def _rng_state(rng: RandomSource) -> int:
    getter = getattr(rng, "get_native_state", None)
    if callable(getter):
        return int(getter()) & 0xFFFFFFFF
    getter = getattr(rng, "get_state", None)
    if callable(getter):
        return int(getter()) & 0xFFFFFFFF
    return 0x6D2B79F5


def _set_rng_state(rng: RandomSource, value: int) -> None:
    setter = getattr(rng, "set_native_state", None)
    if callable(setter):
        setter(value)
        return
    setter = getattr(rng, "set_state", None)
    if callable(setter):
        setter(value)


def _state_rng(state: GameState) -> int:
    return int(
        getattr(state, "_native_rng_state", 0x6D2B79F5)
    ) & 0xFFFFFFFF


def _flatten_actions(query: Mapping[str, Any]) -> list[GameAction]:
    return [
        _formal_action(row)
        for row in _flatten_native_rows(query, include_ids=True)
    ]


def _matching_native_action(
    query: Mapping[str, Any],
    action: GameAction,
    actor: int,
) -> dict[str, Any] | None:
    requested_kind = action.kind_name
    for native_row in _flatten_native_rows(query):
        candidate = _formal_action(native_row)
        if (
            candidate.kind_name == requested_kind
            and candidate.actor == actor
            and candidate.payload == action.payload
            and candidate.source == action.source
            and candidate.target == action.target
        ):
            return native_row
    return None


def _flatten_native_rows(
    query: Mapping[str, Any],
    *,
    include_ids: bool = False,
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    ordinal = 0
    for group_value in query.get("groups", []):
        if not isinstance(group_value, Mapping):
            continue
        targets = list(group_value.get("targets", []) or []) or [None]
        for target in targets:
            action_id = (
                f"native-legal:{int(query.get('base_revision', -1))}:"
                f"{ordinal}"
                if include_ids
                else ""
            )
            result.append({
                "schema_version": 4,
                "action_id": action_id,
                "base_revision": int(group_value.get(
                    "base_revision", query.get("base_revision", -1)
                )),
                "actor": int(group_value.get("actor", -1)),
                "kind": str(group_value.get("kind", "")),
                "source": copy.deepcopy(group_value.get("source")),
                "target": copy.deepcopy(target),
                "payload": copy.deepcopy(
                    dict(group_value.get("payload", {}) or {})
                ),
            })
            ordinal += 1
    return result


def _formal_action(row: Mapping[str, Any]) -> GameAction:
    kind = str(row.get("kind", ""))
    actor = int(row.get("actor", -1))
    source = row.get("source")
    target = row.get("target")
    payload = copy.deepcopy(dict(row.get("payload", {}) or {}))
    action_value = PlayerAction.__members__.get(kind, kind)
    return GameAction(
        kind=action_value,
        payload=payload,
        actor=actor,
        source=_ref_from_native(source),
        target=_ref_from_native(target),
        action_id=str(row.get("action_id", "")),
        base_revision=int(row.get("base_revision", -1)),
    )


def _choice_from_native(row: Mapping[str, Any]) -> ChoiceView:
    options: list[ChoiceOption] = []
    for option_value in row.get("options", []):
        if not isinstance(option_value, Mapping):
            continue
        ref = _ref_from_native(option_value.get("ref"))
        options.append(ChoiceOption(
            str(option_value.get("option_id", "")),
            str(option_value.get("label", "")),
            ref,
        ))
    presentation = copy.deepcopy(
        dict(row.get("presentation", {}) or {})
    )
    return ChoiceView(
        request_id=str(row.get("request_id", "")),
        base_revision=int(row.get("base_revision", -1)),
        request_type=str(row.get("request_type", "")),
        player=int(row.get("player", 0)),
        prompt=str(row.get("prompt", "")),
        options=tuple(options),
        min_select=int(row.get("min_select", 1)),
        max_select=int(row.get("max_select", 1)),
        allow_duplicates=bool(row.get("allow_duplicates", False)),
        can_cancel=bool(row.get("can_cancel", False)),
        presentation=presentation,
    )


def _ref_from_native(value: Any):
    if not isinstance(value, Mapping):
        return None
    kind = str(value.get("kind", ""))
    player = int(value.get("player", -1))
    if player not in (0, 1):
        return None
    if kind == "card":
        return CardRef(
            player,
            str(value.get("zone", "")),
            int(value.get("index", -1)),
            str(value.get("card_id", "")),
        )
    if kind == "pokemon":
        return PokemonRef(
            player,
            str(value.get("slot", "")),
            str(value.get("card_id", "")),
        )
    if kind == "slot":
        return SlotRef(player, str(value.get("slot", "")))
    if kind == "attachment":
        return AttachmentRef(
            player,
            str(value.get("slot", "")),
            str(value.get("attachment_type", "")),
            int(value.get("index", -1)),
            str(value.get("card_id", "")),
        )
    return None


def _failure(
    state: GameState,
    code: str,
    error: Exception | None = None,
) -> StepResult:
    message = f"{code}:{error}" if error is not None else code
    return StepResult(
        success=False,
        message=message,
        winner=state.winner,
        terminal=state.is_terminal(),
        error_code=code,
    )


DEFAULT_GAME_ENGINE = GameEngine()


__all__ = ["GameEngine", "DEFAULT_GAME_ENGINE", "NativeChoiceAdapter"]

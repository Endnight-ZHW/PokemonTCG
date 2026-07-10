"""Transaction boundary helpers for public rules actions and choices."""
from __future__ import annotations

import copy
from typing import Any

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    PokemonRef,
    StepResult,
)
from engine.enums import TurnPhase
from engine.game_state import GameState
from engine.random_source import RandomSource
from engine.snapshot import (
    rebuild_state_event_bus,
    restore_state,
    snapshot_from_dict,
    snapshot_state,
    snapshot_to_dict,
)


class VMTransactionManager:
    """Owns rollback, cancellation, and serialized pending-choice stack state."""

    @staticmethod
    def capture_transaction(state: GameState, rng: RandomSource) -> dict[str, Any]:
        state_snapshot = snapshot_state(state)
        return {
            "state": state_snapshot,
            "state_clone": (
                copy.deepcopy(state)
                if VMTransactionManager._snapshot_has_unregistered_cards(state_snapshot)
                else None
            ),
            "rng_state": rng.getstate(),
            "action_log": list(getattr(state, "action_log", ())),
            "events": list(getattr(getattr(state, "event_stream", None), "_events", ())),
        }

    @staticmethod
    def rollback_transaction(
        state: GameState,
        rng: RandomSource,
        checkpoint: dict[str, Any],
    ) -> None:
        state_clone = checkpoint.get("state_clone")
        if state_clone is not None:
            state.__dict__.clear()
            state.__dict__.update(copy.deepcopy(state_clone.__dict__))
        else:
            restore_state(state, checkpoint["state"])
        rebuild_state_event_bus(state)
        rng.setstate(checkpoint["rng_state"])
        state.action_log = list(checkpoint.get("action_log", ()))
        event_stream = getattr(state, "event_stream", None)
        if event_stream is not None and hasattr(event_stream, "_events"):
            event_stream._events = list(checkpoint.get("events", ()))

    def rollback_failed_step(
        self,
        state: GameState,
        rng: RandomSource,
        checkpoint: dict[str, Any],
        step: StepResult,
    ) -> StepResult:
        self.rollback_transaction(state, rng, checkpoint)
        step.pending_choice = None
        step.events = ()
        step.winner = state.winner
        step.terminal = state.winner is not None or state.phase == TurnPhase.GAME_OVER
        return step

    @staticmethod
    def resolution_stack_payload(state: GameState) -> dict[str, Any]:
        stack = getattr(state, "resolution_stack", None)
        if not isinstance(stack, dict):
            stack = {}
        return {
            "frames": copy.deepcopy(stack.get("frames", [])),
            "pending_request": copy.deepcopy(stack.get("pending_request")),
            "sequence": int(stack.get("sequence", getattr(state, "choice_sequence", 0)) or 0),
            "context": copy.deepcopy(stack.get("context", {})),
        }

    def persist_pending_choice(self, state: GameState, request: ChoiceRequest) -> None:
        stack = self.resolution_stack_payload(state)
        frames: list[dict[str, Any]] = []
        attack_actor = request.metadata.get("finish_attack_actor")
        if attack_actor in (0, 1):
            frames.append({"kind": "finalize_attack", "actor": int(attack_actor)})
        continuation = request.metadata.get("continuation")
        if isinstance(continuation, dict) and continuation.get("kind"):
            frames.append({
                "kind": "continuation",
                "operation": str(continuation.get("kind", "")),
                "data": copy.deepcopy(continuation),
            })
        stack["frames"] = frames
        stack["pending_request"] = self.choice_request_to_dict(request)
        stack["sequence"] = int(getattr(state, "choice_sequence", stack.get("sequence", 0)) or 0)
        state.resolution_stack = stack

    def pending_choice_payload(self, state: GameState) -> dict[str, Any] | None:
        pending = self.resolution_stack_payload(state).get("pending_request")
        return pending if isinstance(pending, dict) else None

    def has_pending_choice(self, state: GameState) -> bool:
        return self.pending_choice_payload(state) is not None

    def clear_pending_choice_stack(self, state: GameState) -> None:
        stack = self.resolution_stack_payload(state)
        stack["frames"] = []
        stack["pending_request"] = None
        stack["sequence"] = int(getattr(state, "choice_sequence", stack.get("sequence", 0)) or 0)
        context = copy.deepcopy(stack.get("context", {}))
        if isinstance(context, dict):
            context.pop("cancel_action_checkpoint", None)
        stack["context"] = context
        state.resolution_stack = stack

    def store_cancel_checkpoint(
        self,
        state: GameState,
        checkpoint: dict[str, Any],
    ) -> None:
        stack = self.resolution_stack_payload(state)
        context = copy.deepcopy(stack.get("context", {}))
        state_payload = snapshot_to_dict(checkpoint["state"])
        context["cancel_action_checkpoint"] = {
            "state": state_payload,
            "rng_state": self.json_safe(checkpoint["rng_state"]),
            "action_log": copy.deepcopy(checkpoint.get("action_log", ())),
            "events": copy.deepcopy(state_payload.get("event_stream", [])),
        }
        stack["context"] = context
        state.resolution_stack = stack

    def restore_cancel_checkpoint(
        self,
        state: GameState,
        rng: RandomSource,
        request: ChoiceRequest,
    ) -> bool:
        stack = self.resolution_stack_payload(state)
        context = stack.get("context", {})
        checkpoint = (
            context.get("cancel_action_checkpoint")
            if isinstance(context, dict)
            else None
        )
        if not isinstance(checkpoint, dict):
            return False
        snapshot_payload = checkpoint.get("state")
        if not isinstance(snapshot_payload, dict):
            return False
        snapshot = snapshot_from_dict(snapshot_payload)
        restored_revision = int(getattr(snapshot, "revision", 0)) + 1
        restore_state(state, snapshot)
        rebuild_state_event_bus(state)
        state.revision = restored_revision
        state.action_log = list(checkpoint.get("action_log", ()))
        if "events" in checkpoint:
            self.restore_event_stream(state, checkpoint.get("events", []))
        if "rng_state" in checkpoint:
            rng.setstate(self.tuple_from_json_safe(checkpoint["rng_state"]))
        legacy = request.legacy_request
        if legacy is not None:
            legacy.pending_card = None
        return True

    @staticmethod
    def restore_event_stream(state: GameState, events: Any) -> None:
        from engine.events.game_events import GameEvent, GameEventStream

        if not hasattr(state, "event_stream") or state.event_stream is None:
            state.event_stream = GameEventStream()
        rebuilt = []
        for event in events or []:
            if isinstance(event, dict):
                rebuilt.append(
                    GameEvent(
                        str(event.get("event_type", "")),
                        copy.deepcopy(event.get("data", {}) or {}),
                    )
                )
            elif hasattr(event, "event_type"):
                rebuilt.append(
                    GameEvent(
                        str(getattr(event, "event_type", "")),
                        copy.deepcopy(getattr(event, "data", {}) or {}),
                    )
                )
        state.event_stream._events = rebuilt

    @classmethod
    def choice_request_to_dict(cls, request: ChoiceRequest) -> dict[str, Any]:
        return {
            "request_id": request.request_id,
            "request_type": request.request_type,
            "player": int(request.player),
            "prompt": request.prompt,
            "options": [cls.choice_option_to_dict(option) for option in request.options],
            "min_select": int(request.min_select),
            "max_select": int(request.max_select),
            "allow_duplicates": bool(request.allow_duplicates),
            "can_cancel": bool(request.can_cancel),
            "metadata": cls.json_safe(request.metadata),
        }

    @classmethod
    def choice_option_to_dict(cls, option: ChoiceOption) -> dict[str, Any]:
        return {
            "option_id": option.option_id,
            "label": option.label,
            "ref": cls.entity_ref_to_dict(option.ref) if option.ref is not None else None,
            "value": cls.json_safe(option.value),
        }

    @staticmethod
    def entity_ref_to_dict(ref) -> dict[str, Any]:
        if isinstance(ref, CardRef):
            return {
                "kind": "card",
                "player": int(ref.player),
                "zone": ref.zone,
                "slot": "",
                "index": int(ref.index),
                "attachment_type": "",
                "card_id": ref.card_id,
            }
        if isinstance(ref, PokemonRef):
            return {
                "kind": "pokemon",
                "player": int(ref.player),
                "zone": "",
                "slot": ref.slot,
                "index": -1,
                "attachment_type": "",
                "card_id": ref.card_id,
            }
        if isinstance(ref, AttachmentRef):
            return {
                "kind": "attachment",
                "player": int(ref.player),
                "zone": "",
                "slot": ref.slot,
                "index": int(ref.index),
                "attachment_type": ref.attachment_type,
                "card_id": ref.card_id,
            }
        return {}

    @classmethod
    def json_safe(cls, value):
        if hasattr(value, "api_id"):
            return getattr(value, "api_id")
        if isinstance(value, dict):
            return {str(key): cls.json_safe(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [cls.json_safe(item) for item in value]
        if isinstance(value, set):
            return sorted(cls.json_safe(item) for item in value)
        if isinstance(value, (str, int, float, bool)) or value is None:
            return value
        return str(value)

    @classmethod
    def tuple_from_json_safe(cls, value):
        if isinstance(value, list):
            return tuple(cls.tuple_from_json_safe(item) for item in value)
        if isinstance(value, tuple):
            return tuple(cls.tuple_from_json_safe(item) for item in value)
        return value

    @staticmethod
    def _snapshot_has_unregistered_cards(state_snapshot) -> bool:
        from data.card_registry import CardRegistry

        return any(
            card_id and CardRegistry.get(card_id) is None
            for card_id in VMTransactionManager._snapshot_card_ids(state_snapshot)
        )

    @staticmethod
    def _snapshot_card_ids(state_snapshot):
        def pokemon_ids(pokemon_snapshot):
            if pokemon_snapshot is None:
                return
            yield pokemon_snapshot.card_id
            yield from pokemon_snapshot.energy_card_ids
            if pokemon_snapshot.attached_tool_id:
                yield pokemon_snapshot.attached_tool_id
            yield from pokemon_snapshot.evolution_stack_ids

        def player_ids(player_snapshot):
            yield from player_snapshot.hand_ids
            yield from player_snapshot.deck_ids
            yield from player_snapshot.discard_ids
            yield from player_snapshot.prize_ids
            yield from pokemon_ids(player_snapshot.active)
            for bench_snapshot in player_snapshot.bench:
                yield from pokemon_ids(bench_snapshot)

        yield from player_ids(state_snapshot.p1)
        yield from player_ids(state_snapshot.p2)
        if state_snapshot.stadium_card_id:
            yield state_snapshot.stadium_card_id

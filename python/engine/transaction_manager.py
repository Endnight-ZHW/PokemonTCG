"""Transaction boundary helpers for public rules actions and choices."""
from __future__ import annotations

import copy
import math
from typing import Any

from engine.action_codec import (
    serialize_choice_option_internal,
    serialize_choice_request_internal,
    serialize_entity_ref,
)
from engine.actions import (
    ChoiceOption,
    ChoiceRequest,
    StepResult,
)
from engine.enums import TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
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
            # Existing event payloads are mutable dictionaries.  A shallow
            # list copy would let a failed callback mutate the checkpoint
            # itself and leak that mutation through rollback.
            "events": copy.deepcopy(
                list(getattr(getattr(state, "event_stream", None), "_events", ()))
            ),
            # Kept only for rollback within the current process.  This object
            # is never included in GameSnapshot or any wire/file payload.
            "pending_choice_runtime": VMTransactionManager._clone_pending_runtime(
                getattr(state, "_pending_choice_runtime", None)
            ),
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
            restore_state(state, checkpoint["state"], rebuild_event_bus=False)
        rebuild_state_event_bus(state)
        rng.setstate(checkpoint["rng_state"])
        state.action_log = list(checkpoint.get("action_log", ()))
        event_stream = getattr(state, "event_stream", None)
        if event_stream is not None and hasattr(event_stream, "_events"):
            event_stream._events = copy.deepcopy(list(checkpoint.get("events", ())))
        runtime = checkpoint.get("pending_choice_runtime")
        metadata = getattr(runtime, "metadata", {})
        continuation = (
            metadata.get("continuation", {})
            if isinstance(metadata, dict)
            else {}
        )
        # A failed VM callback may already have consumed commands from its
        # captured in-memory stack.  Drop that closure and rebuild from the
        # checkpoint's serialized resume frames on the next attempt.
        state._pending_choice_runtime = (
            None
            if isinstance(continuation, dict) and continuation.get("kind")
            else VMTransactionManager._clone_pending_runtime(runtime)
        )

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
        # Do not expose cards, damage, KOs, or other aggregates produced by a
        # transaction that did not commit.  Keep only the public failure text.
        step.action_result = ActionResult(False, step.message)
        step.winner = state.winner
        step.terminal = state.is_terminal()
        return step

    @staticmethod
    def resolution_stack_payload(state: GameState) -> dict[str, Any]:
        stack = getattr(state, "resolution_stack", None)
        if not isinstance(stack, dict):
            stack = {}
        raw_sequence = stack.get("sequence", getattr(state, "choice_sequence", 0))
        try:
            sequence = int(raw_sequence or 0)
        except (TypeError, ValueError, OverflowError):
            try:
                sequence = int(getattr(state, "choice_sequence", 0) or 0)
            except (TypeError, ValueError, OverflowError):
                sequence = 0
        return {
            "frames": copy.deepcopy(stack.get("frames", [])),
            "pending_request": copy.deepcopy(stack.get("pending_request")),
            "sequence": sequence,
            "context": copy.deepcopy(stack.get("context", {})),
        }

    def persist_pending_choice(self, state: GameState, request: ChoiceRequest) -> None:
        stack = self.resolution_stack_payload(state)
        frames: list[dict[str, Any]] = []
        attack_actor = request.metadata.get("finish_attack_actor")
        if type(attack_actor) is int and attack_actor in (0, 1):
            frames.append({"kind": "finalize_attack", "actor": attack_actor})
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
        state._pending_choice_runtime = request

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
        state._pending_choice_runtime = None

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
        # The pending action revision may already have been observed by a
        # remote client.  Cancellation is a new committed transaction and
        # must advance beyond both the checkpoint and the published state.
        restored_revision = max(
            int(getattr(state, "revision", 0)),
            int(getattr(snapshot, "revision", 0)),
        ) + 1
        restore_state(state, snapshot, rebuild_event_bus=False)
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
        return serialize_choice_request_internal(request)

    @classmethod
    def choice_option_to_dict(cls, option: ChoiceOption) -> dict[str, Any]:
        return serialize_choice_option_internal(option)

    @staticmethod
    def entity_ref_to_dict(ref) -> dict[str, Any]:
        payload = serialize_entity_ref(ref)
        return payload if payload is not None else {}

    @classmethod
    def json_safe(cls, value):
        # Transaction checkpoints also contain Python MT19937 state arrays
        # larger than the public protocol's generic-container bound.  They are
        # local snapshot data, not action/choice wire payloads.
        if hasattr(value, "api_id"):
            return getattr(value, "api_id")
        if isinstance(value, dict):
            return {str(key): cls.json_safe(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [cls.json_safe(item) for item in value]
        if isinstance(value, set):
            return sorted(cls.json_safe(item) for item in value)
        if type(value) is float and not math.isfinite(value):
            raise ValueError("transaction checkpoint numbers must be finite")
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

    @classmethod
    def _clone_pending_runtime(cls, runtime):
        """Copy mutable request metadata without cloning shared Card records.

        Callback functions intentionally remain the same live callable.  VM
        requests with serializable continuations are discarded on rollback
        and rebuilt from state; this clone protects legacy callback-only
        requests from poisoning their own retry metadata.
        """
        if not isinstance(runtime, ChoiceRequest):
            return runtime
        cloned = copy.copy(runtime)
        cloned.metadata = copy.deepcopy(runtime.metadata)
        cloned.options = tuple(
            ChoiceOption(
                option.option_id,
                option.label,
                option.ref,
                cls._clone_runtime_value(option.value),
            )
            for option in runtime.options
        )
        legacy = runtime.legacy_request
        if isinstance(legacy, ActionRequest):
            legacy_clone = copy.copy(legacy)
            legacy_clone.card_list = list(legacy.card_list)
            legacy_clone.bench_indices = list(legacy.bench_indices)
            legacy_clone.target_info = cls._clone_runtime_value(legacy.target_info)
            legacy_clone.continuation = copy.deepcopy(legacy.continuation)
            cloned.legacy_request = legacy_clone
        return cloned

    @classmethod
    def _clone_runtime_value(cls, value):
        if hasattr(value, "api_id"):
            return value
        if isinstance(value, dict):
            return {
                key: cls._clone_runtime_value(item)
                for key, item in value.items()
            }
        if isinstance(value, list):
            return [cls._clone_runtime_value(item) for item in value]
        if isinstance(value, tuple):
            return tuple(cls._clone_runtime_value(item) for item in value)
        if isinstance(value, set):
            return {cls._clone_runtime_value(item) for item in value}
        return copy.deepcopy(value)

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

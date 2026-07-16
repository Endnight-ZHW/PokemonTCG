"""Serializable VM stack state for pending-choice snapshot recovery."""
from __future__ import annotations

import copy
from typing import Any


RESUME_STATE_VERSION = 1


class ContinuationStateError(ValueError):
    pass


def serialize_resolution_stack(stack, player_idx: int, source_slot: str) -> dict[str, Any]:
    """Encode the commands that must run after the current choice.

    Unsupported commands do not break the live game.  Instead the payload is
    marked incomplete so a later snapshot restore fails closed rather than
    silently skipping rules work.
    """
    frames = []
    unsupported = []
    for command in list(getattr(stack, "_stack", ())):
        try:
            frames.append(_encode_command(command))
        except ContinuationStateError:
            unsupported.append(
                f"{type(command).__module__}.{type(command).__qualname__}"
            )

    try:
        context = _encode_context(stack, player_idx, source_slot)
        context_supported = True
    except ContinuationStateError:
        context = {}
        context_supported = False

    return {
        "version": RESUME_STATE_VERSION,
        "player_idx": int(player_idx),
        "source_slot": str(source_slot or "active"),
        "complete": not unsupported and context_supported,
        "frames": frames,
        "unsupported_frames": unsupported,
        "context": context,
        "attack_failed": bool(getattr(stack, "attack_failed", False)),
    }


def restore_resolution_stack(stack, payload: dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        raise ContinuationStateError("VM resume payload must be an object")
    version = payload.get("version", 0)
    if type(version) is not int:
        raise ContinuationStateError("VM resume version is invalid")
    if version != RESUME_STATE_VERSION:
        raise ContinuationStateError(f"Unsupported VM resume version: {version}")
    complete = payload.get("complete", False)
    if type(complete) is not bool:
        raise ContinuationStateError("VM resume completeness flag is invalid")
    if not complete:
        names = ", ".join(str(item) for item in payload.get("unsupported_frames", []))
        suffix = f": {names}" if names else ""
        raise ContinuationStateError(f"VM continuation state is incomplete{suffix}")

    frames = payload.get("frames", [])
    if not isinstance(frames, list):
        raise ContinuationStateError("VM resume frames must be a list")
    player_idx = payload.get("player_idx", -1)
    if type(player_idx) is not int or player_idx not in (0, 1):
        raise ContinuationStateError("VM resume player is invalid")
    if not isinstance(payload.get("source_slot", "active"), str):
        raise ContinuationStateError("VM resume source_slot is invalid")
    attack_failed = payload.get("attack_failed", False)
    if type(attack_failed) is not bool:
        raise ContinuationStateError("VM resume attack_failed flag is invalid")

    # Decode into locals first so a malformed context cannot partially replace
    # a live stack before restoration reports failure.
    try:
        decoded_frames = [_decode_command(frame) for frame in frames]
        decoded_context = _decode_context(stack.state, payload.get("context", {}))
    except ContinuationStateError:
        raise
    except Exception as exc:
        raise ContinuationStateError(f"Unable to decode VM resume state: {exc}") from exc
    stack._stack = decoded_frames
    stack.context = decoded_context
    stack._attack_failed = attack_failed


def tag_command_spec(command, spec: dict[str, Any]):
    """Attach the stable compiler input used to recreate a command."""
    setattr(command, "_vm_resume_descriptor", {
        "kind": "command_spec",
        "spec": _json_safe(spec),
    })
    return command


def tag_legacy_effect(command, effect_type: str, params: dict[str, Any]):
    setattr(command, "_vm_resume_descriptor", {
        "kind": "legacy_effect",
        "effect_type": str(effect_type),
        "params": _json_safe(params),
    })
    return command


def _encode_command(command) -> dict[str, Any]:
    descriptor = getattr(command, "_vm_resume_descriptor", None)
    if isinstance(descriptor, dict):
        return copy.deepcopy(_json_safe(descriptor))

    from engine.commands.attack_frames import (
        DiscardKnockoutBatch,
        FinalizeAfterDamageTriggers,
        FinalizeAttackDamage,
        FinalizeAttackKoChecks,
        FinalizeAttackTurn,
        FinalizeCheckupTurn,
        FinalizeKnockoutBatch,
        PrizeSelectionFrame,
    )
    from engine.commands.trigger_commands import TriggerOrderFrame

    if isinstance(command, FinalizeAttackDamage):
        return {"kind": "finalize_attack_damage"}
    if isinstance(command, FinalizeAfterDamageTriggers):
        return {"kind": "finalize_after_damage_triggers"}
    if isinstance(command, FinalizeAttackKoChecks):
        return {"kind": "finalize_attack_ko_checks"}
    if isinstance(command, TriggerOrderFrame):
        return {"kind": "trigger_order", "specs": _json_safe(command.specs)}
    if isinstance(command, DiscardKnockoutBatch):
        return {"kind": "discard_knockout_batch", "entries": _json_safe(command.entries)}
    if isinstance(command, PrizeSelectionFrame):
        return {"kind": "prize_selection", "player_idx": int(command.player_idx)}
    if isinstance(command, FinalizeKnockoutBatch):
        return {"kind": "finalize_knockout_batch"}
    if isinstance(command, FinalizeCheckupTurn):
        return {"kind": "finalize_checkup_turn", "actor": int(command.actor)}
    if isinstance(command, FinalizeAttackTurn):
        return {"kind": "finalize_attack_turn", "actor": int(command.actor)}
    raise ContinuationStateError(f"Unsupported VM resume command: {type(command)!r}")


def _decode_command(payload: Any):
    if not isinstance(payload, dict):
        raise ContinuationStateError("VM resume frame must be an object")
    kind = str(payload.get("kind", "") or "")
    if kind == "command_spec":
        spec = payload.get("spec")
        if not isinstance(spec, dict):
            raise ContinuationStateError("VM command_spec frame is invalid")
        from engine.commands.dsl_compiler import compile_command_spec

        return compile_command_spec(copy.deepcopy(spec))
    if kind == "legacy_effect":
        effect_type = str(payload.get("effect_type", "") or "")
        params = payload.get("params", {})
        if not effect_type or not isinstance(params, dict):
            raise ContinuationStateError("VM legacy_effect frame is invalid")
        from engine.commands.dsl_compiler import compile_effect

        return compile_effect({"effect_type": effect_type, "params": copy.deepcopy(params)})

    from engine.commands.attack_frames import (
        DiscardKnockoutBatch,
        FinalizeAfterDamageTriggers,
        FinalizeAttackDamage,
        FinalizeAttackKoChecks,
        FinalizeAttackTurn,
        FinalizeCheckupTurn,
        FinalizeKnockoutBatch,
        PrizeSelectionFrame,
    )
    from engine.commands.trigger_commands import TriggerOrderFrame

    if kind == "finalize_attack_damage":
        return FinalizeAttackDamage()
    if kind == "finalize_after_damage_triggers":
        return FinalizeAfterDamageTriggers()
    if kind == "finalize_attack_ko_checks":
        return FinalizeAttackKoChecks()
    if kind == "trigger_order":
        specs = payload.get("specs", [])
        if not isinstance(specs, list):
            raise ContinuationStateError("Trigger-order specs are invalid")
        return TriggerOrderFrame(copy.deepcopy(specs))
    if kind == "discard_knockout_batch":
        entries = payload.get("entries", [])
        if not isinstance(entries, list):
            raise ContinuationStateError("Knockout-batch entries are invalid")
        return DiscardKnockoutBatch(copy.deepcopy(entries))
    if kind == "prize_selection":
        player_idx = payload.get("player_idx", -1)
        if type(player_idx) is not int or player_idx not in (0, 1):
            raise ContinuationStateError("Prize-selection player is invalid")
        return PrizeSelectionFrame(player_idx)
    if kind == "finalize_knockout_batch":
        return FinalizeKnockoutBatch()
    if kind == "finalize_checkup_turn":
        actor = payload.get("actor", -1)
        if type(actor) is not int or actor not in (0, 1):
            raise ContinuationStateError("Finalize-checkup actor is invalid")
        return FinalizeCheckupTurn(actor)
    if kind == "finalize_attack_turn":
        actor = payload.get("actor", -1)
        if type(actor) is not int or actor not in (0, 1):
            raise ContinuationStateError("Finalize-attack actor is invalid")
        return FinalizeAttackTurn(actor)
    raise ContinuationStateError(f"Unknown VM resume frame kind: {kind}")


def _encode_context(stack, player_idx: int, source_slot: str) -> dict[str, Any]:
    raw = getattr(stack, "context", {})
    if not isinstance(raw, dict):
        raise ContinuationStateError("VM stack context must be an object")
    result = {}
    for key, value in raw.items():
        if key != "attack_damage":
            result[str(key)] = _json_safe(value)
            continue
        if not isinstance(value, dict):
            raise ContinuationStateError("Attack context must be an object")
        encoded = {
            str(field): _json_safe(field_value)
            for field, field_value in value.items()
            if field != "attacker"
        }
        attacker = value.get("attacker")
        if attacker is not None:
            actor = int(value.get("player_idx", player_idx))
            slot = _pokemon_slot(stack.state, actor, attacker)
            if not slot:
                slot = str(source_slot or "active")
            encoded["attacker_ref"] = {
                "player": actor,
                "slot": slot,
                "card_id": str(getattr(getattr(attacker, "card", None), "api_id", "") or ""),
            }
        result["attack_damage"] = encoded
    return result


def _decode_context(state, payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ContinuationStateError("VM resume context must be an object")
    result = copy.deepcopy(payload)
    attack = result.get("attack_damage")
    if attack is None:
        return result
    if not isinstance(attack, dict):
        raise ContinuationStateError("Attack resume context must be an object")
    attacker_ref = attack.pop("attacker_ref", None)
    if attacker_ref is not None:
        if not isinstance(attacker_ref, dict):
            raise ContinuationStateError("Attack attacker_ref must be an object")
        player_idx = attacker_ref.get("player", -1)
        if type(player_idx) is not int or player_idx not in (0, 1):
            raise ContinuationStateError("Attack attacker_ref player is invalid")
        slot = str(attacker_ref.get("slot", "") or "")
        attacker = state.get_player(player_idx).get_pokemon(slot)
        expected_id = str(attacker_ref.get("card_id", "") or "")
        if attacker is None or (
            expected_id and getattr(attacker.card, "api_id", "") != expected_id
        ):
            raise ContinuationStateError("Attack attacker_ref no longer matches state")
        attack["attacker"] = attacker
    return result


def _pokemon_slot(state, player_idx: int, target) -> str:
    if player_idx not in (0, 1):
        return ""
    for slot, pokemon in state.get_player(player_idx).get_all_pokemon():
        if pokemon is target:
            return slot
    return ""


def _json_safe(value):
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if isinstance(value, set):
        return sorted(_json_safe(item) for item in value)
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    raise ContinuationStateError(f"Value is not serializable: {type(value)!r}")

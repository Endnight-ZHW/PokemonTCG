"""Strict Python-to-native bridge for AlphaZero v2 self-play.

The formal Python engine remains the owner of the real match.  Action-root
search receives a privacy-masked Godot-compatible snapshot, runs entirely in
``ptcg_ai_core`` and maps the selected native action back to the current
authoritative Python legal-action object before it can be applied.
"""
from __future__ import annotations

import copy
import json
import threading
import time
from pathlib import Path
from typing import Any, Sequence

from engine.actions import ChoiceResponse, GameAction
from engine.snapshot import canonical_state_payload

from .inference_v2 import NativeBatchTorchBroker
from .puct_v2 import SearchCandidate, SearchResult


HIDDEN_CARD = "__hidden_card__"
HIDDEN_PRIZE = "__hidden_prize__"


class NativeBridgeError(RuntimeError):
    """A fail-closed state, action, inference or ABI bridge failure."""


def native_training_bridge_available() -> bool:
    try:
        import ptcg_ai_core  # type: ignore

        return (
            int(ptcg_ai_core.abi_version()) == 2
            and hasattr(ptcg_ai_core, "NativeGameKernel")
            and hasattr(ptcg_ai_core, "NativeSearchJob")
            and hasattr(ptcg_ai_core, "NativeSelfPlayBatch")
            and hasattr(ptcg_ai_core, "validate_runtime_snapshot")
        )
    except Exception:
        return False


def _json_value(value: Any) -> Any:
    """Return a detached JSON-shaped value and reject accidental objects."""
    try:
        return json.loads(
            json.dumps(value, ensure_ascii=False, allow_nan=False)
        )
    except (TypeError, ValueError) as exc:
        raise NativeBridgeError("native_state_is_not_json") from exc


def _pokemon_payload(snapshot: dict[str, Any] | None) -> dict[str, Any] | None:
    if snapshot is None:
        return None
    source_modifiers = [
        row
        for row in snapshot.get("modifiers", [])
        if isinstance(row, dict)
    ]
    represented_attack_locks: set[str] = set()
    for descriptor in source_modifiers:
        operation = descriptor.get("operation")
        if (
            not isinstance(operation, dict)
            or str(operation.get("kind", "")) != "attack_lock"
        ):
            continue
        represented_attack_locks.add(
            str(
                operation.get("attack_name")
                or operation.get("reason")
                or "__all__"
            )
        )
    payload: dict[str, Any] = {
        "card_id": str(snapshot.get("card_id", "")),
        "damage_counters": int(snapshot.get("damage_counters", 0)),
        "energy_card_ids": list(snapshot.get("energy_card_ids", [])),
        "attached_tool_id": str(snapshot.get("attached_tool_id") or ""),
        "status_conditions": sorted(snapshot.get("status_conditions", [])),
        "evolution_stack_ids": list(snapshot.get("evolution_stack_ids", [])),
        "can_evolve_this_turn": bool(
            snapshot.get("can_evolve_this_turn", True)
        ),
        "placed_this_turn": bool(snapshot.get("placed_this_turn", True)),
        "used_abilities": sorted(snapshot.get("used_abilities", [])),
        "damage_prevented": bool(
            snapshot.get("damage_prevented", False)
        ),
        "all_prevented": bool(snapshot.get("all_prevented", False)),
        "outgoing_damage_reduction": int(
            snapshot.get("outgoing_damage_reduction", 0)
        ),
        "healed_this_turn": bool(snapshot.get("healed_this_turn", False)),
        "paralyzed_since_turn": int(snapshot.get("paralyzed_since_turn", 0)),
    }
    if (
        bool(snapshot.get("attack_locked", False))
        and "__all__" not in represented_attack_locks
    ):
        payload["attack_locked"] = True
    attack_locked_names = _json_value(
        snapshot.get("attack_locked_names", {})
    )
    if isinstance(attack_locked_names, dict):
        unrepresented_attack_locks = {
            str(name): applied
            for name, applied in attack_locked_names.items()
            if str(name) not in represented_attack_locks
        }
        if unrepresented_attack_locks:
            payload["attack_locked_names"] = unrepresented_attack_locks
    elif attack_locked_names:
        payload["attack_locked_names"] = attack_locked_names
    modifiers = [
        _json_value(row)
        for row in source_modifiers
    ]
    for row in snapshot.get("max_hp_modifiers", []):
        if not isinstance(row, dict):
            continue
        modifier_kind = str(
            row.get("modifier_kind", row.get("effect_type", ""))
        )
        if not modifier_kind:
            continue
        if (
            modifier_kind == "conditional_hp_boost"
            and any(
                isinstance(existing, dict)
                and (existing.get("operation") or {}).get("kind")
                == "hp_delta"
                for existing in modifiers
            )
        ):
            continue
        params = dict(row.get("params", {}))
        for key in ("energy_type", "threshold", "amount"):
            if key in row and key not in params:
                params[key] = row[key]
        modifiers.append(
            {
                "source": str(row.get("source", modifier_kind)),
                "source_player": int(row.get("source_player", -1)),
                "source_slot": str(row.get("source_slot", "")),
                "source_card_id": str(
                    row.get("source_card_id", snapshot.get("card_id", ""))
                ),
                "modifier_kind": modifier_kind,
                "params": _json_value(params),
            }
        )
    if modifiers:
        payload["modifiers"] = modifiers
    return payload


def _player_payload(snapshot: dict[str, Any]) -> dict[str, Any]:
    bench = [
        _pokemon_payload(row)
        for row in snapshot.get("bench", [])
    ]
    while len(bench) < 5:
        bench.append(None)
    payload = {
        "name": str(snapshot.get("name", "")),
        "deck": list(snapshot.get("deck_ids", [])),
        "hand": list(snapshot.get("hand_ids", [])),
        "discard": list(snapshot.get("discard_ids", [])),
        "prizes": list(snapshot.get("prize_ids", [])),
        "active": _pokemon_payload(snapshot.get("active")),
        "bench": bench[:5],
        "supporter_played_this_turn": bool(
            snapshot.get("supporter_played", False)
        ),
        "energy_attached_this_turn": bool(
            snapshot.get("energy_attached", False)
        ),
        "retreated_this_turn": bool(snapshot.get("retreated", False)),
        "stadium_played_this_turn": bool(
            snapshot.get("stadium_played", False)
        ),
        "stadium_used_this_turn": bool(
            snapshot.get("stadium_used", False)
        ),
        "healed_this_turn": bool(snapshot.get("healed", False)),
        "vstar_power_used": bool(snapshot.get("vstar_used", False)),
        "was_ko_by_attack": bool(snapshot.get("was_ko_by_attack", False)),
    }
    attack_locked_names = {
        str(name): int(expires)
        for name, expires in dict(
            snapshot.get("attack_locked_names", {}) or {}
        ).items()
    }
    if attack_locked_names:
        payload["attack_locked_names"] = attack_locked_names
    return payload


def _knockout_fact(fact: Any) -> dict[str, Any] | None:
    if not isinstance(fact, dict):
        return None
    defeated_player = int(fact.get("defeated_player", fact.get("owner", -1)))
    source_kind = str(fact.get("source_kind", fact.get("cause", "rule")))
    source_player_value = fact.get("source_player", -1)
    source_player = (
        int(source_player_value) if source_player_value in (0, 1) else -1
    )
    if source_kind == "attack_damage":
        cause_kind = "damage"
    elif source_kind == "direct_knockout":
        source_kind = "attack_effect"
        cause_kind = "direct_knockout"
    elif source_kind in {"damage_counter", "damage_counters"}:
        cause_kind = "damage_counters"
    elif source_kind == "special_condition":
        cause_kind = "special_condition"
    else:
        cause_kind = "effect"
    return {
        "defeated_player": defeated_player,
        "slot": str(fact.get("slot", "")),
        "card_id": str(fact.get("card_id", "")),
        "source_player": source_player,
        "source_kind": source_kind,
        "cause_kind": str(fact.get("cause_kind", cause_kind)),
        "cause_detail": _json_value(
            fact.get("cause_detail", fact.get("cause_details", ""))
        ),
        "turn": int(fact.get("turn", fact.get("turn_number", 0))),
    }


def _turn_fact_book(snapshot: Any) -> dict[str, Any]:
    source = snapshot if isinstance(snapshot, dict) else {}

    def window(primary: str, fallback: str) -> dict[str, Any]:
        raw = source.get(primary, source.get(fallback, {}))
        row = raw if isinstance(raw, dict) else {}
        facts = [
            mapped
            for fact in row.get("knockouts", [])
            if (mapped := _knockout_fact(fact)) is not None
        ]
        return {"knockouts": facts}

    return {
        "current_turn": window("current_turn", "current"),
        "previous_turn": window("previous_turn", "previous"),
    }


def game_state_to_native_wire(state: Any) -> dict[str, Any]:
    """Convert a formal Python GameState to the frozen Godot/native shape."""
    snapshot = canonical_state_payload(state)
    rules_options = dict(snapshot.get("rules_options", {}))
    apply_type_matchups = bool(snapshot.get("apply_type_matchups", False))
    rules_options["apply_type_matchups"] = apply_type_matchups
    mulligan_value = snapshot.get("mulligan_bonus_max", (0, 0))
    if isinstance(mulligan_value, (list, tuple)):
        mulligan_bonus_max = max(
            (int(value) for value in mulligan_value),
            default=0,
        )
    else:
        mulligan_bonus_max = int(mulligan_value or 0)
    payload = {
        "players": [
            _player_payload(snapshot["p1"]),
            _player_payload(snapshot["p2"]),
        ],
        "active_player_idx": int(snapshot["active_player_idx"]),
        "phase": str(snapshot["phase"]),
        "turn_number": int(snapshot["turn_number"]),
        "first_player_idx": int(snapshot["first_player_idx"]),
        "stadium_card_id": str(snapshot.get("stadium_card_id") or ""),
        "stadium_owner_idx": int(snapshot.get("stadium_owner_idx", -1)),
        "winner": (
            -1
            if snapshot.get("winner") is None
            else int(snapshot["winner"])
        ),
        "result_status": str(snapshot.get("result_status", "ONGOING")),
        "result_reason": str(snapshot.get("result_reason", "")),
        "result_conditions": _json_value(
            snapshot.get("result_conditions", [[], []])
        ),
        "revision": int(snapshot.get("revision", 0)),
        "choice_sequence": int(snapshot.get("choice_sequence", 0)),
        "public_deck_keys": [
            str(value or "")
            for value in snapshot.get("public_deck_keys", ("", ""))
        ],
        "apply_type_matchups": apply_type_matchups,
        "rules_profile_id": str(
            snapshot.get("rules_profile_id", "CN_MAINLAND_3_1_0")
        ),
        "rules_options": _json_value(rules_options),
        "action_log": [
            str(value) for value in snapshot.get("action_log", [])
        ],
        "mulligan_count": list(snapshot.get("mulligan_count", (0, 0))),
        "extra_draws": list(snapshot.get("extra_draws", (0, 0))),
        "setup_ready": [
            bool(value)
            for value in snapshot.get(
                "setup_initial_done",
                (False, False),
            )
        ],
        "setup_stage": str(snapshot.get("setup_stage", "TURN_ORDER")),
        "setup_actor_idx": int(snapshot.get("setup_actor_idx", -1)),
        "opening_coin_winner_idx": int(
            snapshot.get("opening_coin_winner_idx", -1)
        ),
        "mulligan_bonus_max": mulligan_bonus_max,
        "setup_bonus_card_ids": [
            list(row)
            for row in snapshot.get("setup_bonus_card_ids", ([], []))
        ],
        "pending_promotions": list(
            snapshot.get("pending_promotions", [])
        ),
        "processed_action_ids": [
            str(value)
            for value in getattr(state, "_native_processed_action_ids", [])
        ],
        "resolution_stack": _json_value(
            snapshot.get("resolution_stack", {})
        ),
        "turn_fact_book": _turn_fact_book(
            snapshot.get("turn_fact_book", {})
        ),
    }
    return _json_value(payload)


def mask_native_snapshot(
    wire_state: dict[str, Any],
    actor: int,
) -> dict[str, Any]:
    """Remove every private identity before crossing the native ABI."""
    if actor not in (0, 1):
        raise NativeBridgeError("invalid_native_actor")
    result = copy.deepcopy(wire_state)
    players = result.get("players")
    if not isinstance(players, list) or len(players) != 2:
        raise NativeBridgeError("invalid_native_players")
    for player_index, player in enumerate(players):
        if not isinstance(player, dict):
            raise NativeBridgeError("invalid_native_player")
        player["deck"] = [HIDDEN_CARD] * len(player.get("deck", []))
        player["prizes"] = [HIDDEN_PRIZE] * len(
            player.get("prizes", [])
        )
        if player_index != actor:
            player["hand"] = [HIDDEN_CARD] * len(
                player.get("hand", [])
            )
    bonus_rows = result.get("setup_bonus_card_ids", [[], []])
    if isinstance(bonus_rows, list) and len(bonus_rows) == 2:
        bonus_rows[1 - actor] = [HIDDEN_CARD] * len(
            bonus_rows[1 - actor]
        )
    stack = result.get("resolution_stack")
    if isinstance(stack, dict):
        context = stack.get("context")
        public_promotion_context = (
            (
                isinstance(context, dict)
                and set(context) == {"finish_attack_after_promotions"}
                and type(context.get("finish_attack_after_promotions"))
                    is int
                and int(context["finish_attack_after_promotions"])
                    in (0, 1)
                and str(result.get("phase", "")) == "ATTACK"
                and isinstance(result.get("pending_promotions"), list)
                and bool(result["pending_promotions"])
            )
            or (
                isinstance(context, dict)
                and set(context) == {"finish_checkup_after_promotions"}
                and type(context.get("finish_checkup_after_promotions"))
                    is int
                and int(context["finish_checkup_after_promotions"])
                    in (0, 1)
                and int(result.get("active_player_idx", -1))
                    == int(context["finish_checkup_after_promotions"])
                and str(result.get("phase", ""))
                    == "POKEMON_CHECKUP"
                and isinstance(result.get("pending_promotions"), list)
                and bool(result["pending_promotions"])
            )
        )
        if (
            stack.get("frames")
            or stack.get("pending_request") is not None
            or (stack.get("context") and not public_promotion_context)
        ):
            raise NativeBridgeError(
                "native_root_choice_continuation_unavailable"
            )
        result["resolution_stack"] = {
            "schema_version": int(stack.get("schema_version", 3)),
            "frames": [],
            "pending_request": None,
            "sequence": int(stack.get("sequence", 0)),
            "context": {},
        }
    return result


def _freeze(value: Any) -> Any:
    if isinstance(value, dict):
        return tuple(
            sorted((str(key), _freeze(item)) for key, item in value.items())
        )
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    return value


def _native_action_key(row: dict[str, Any]) -> tuple[Any, ...]:
    kind = str(row.get("kind", ""))
    actor = int(row.get("actor", -1))
    return (
        kind,
        actor,
        _reference_key(row.get("source")),
        _reference_key(row.get("target")),
        _freeze(dict(row.get("payload", {}) or {})),
    )


def _formal_action_key(action: GameAction) -> tuple[Any, ...]:
    from engine.action_codec import serialize_entity_ref

    return (
        action.kind_name,
        int(action.actor),
        _reference_key(serialize_entity_ref(action.source)),
        _reference_key(serialize_entity_ref(action.target)),
        _freeze(action.payload),
    )


def _reference_key(value: Any) -> tuple[Any, ...] | None:
    """Canonicalize compact native and full Action v4 reference shapes."""
    if not isinstance(value, dict):
        return None
    kind = str(value.get("kind", ""))
    player = int(value.get("player", -1))
    if kind == "card":
        return (
            kind,
            player,
            str(value.get("zone", "")),
            int(value.get("index", -1)),
            str(value.get("card_id", "")),
        )
    if kind in {"pokemon", "slot"}:
        return (
            kind,
            player,
            str(value.get("slot", "")),
            str(value.get("card_id", "")),
        )
    if kind == "attachment":
        return (
            kind,
            player,
            str(value.get("slot", "")),
            str(value.get("attachment_type", "")),
            int(value.get("index", -1)),
            str(value.get("card_id", "")),
        )
    return _freeze(value)


def _formal_choice_key(
    response: ChoiceResponse,
) -> tuple[str, tuple[str, ...], bool]:
    return (
        str(response.request_id),
        tuple(str(option_id) for option_id in response.option_ids),
        bool(response.cancelled),
    )


def _native_choice_key(
    row: dict[str, Any],
) -> tuple[str, tuple[str, ...], bool]:
    selected = row.get("selected_options", [])
    if not isinstance(selected, list):
        raise NativeBridgeError("invalid_native_choice_selection")
    return (
        str(row.get("request_id", "")),
        tuple(str(option_id) for option_id in selected),
        bool(row.get("cancelled", False)),
    )


def _native_choice_view(
    pending: dict[str, Any],
    candidates: Sequence[SearchCandidate],
    actor: int,
) -> dict[str, Any]:
    if (
        not isinstance(pending, dict)
        or int(pending.get("player", -1)) != actor
        or not isinstance(pending.get("options"), list)
    ):
        raise NativeBridgeError("invalid_formal_pending_choice")
    options = _json_value(pending["options"])
    option_by_id: dict[str, dict[str, Any]] = {}
    for option in options:
        if not isinstance(option, dict):
            raise NativeBridgeError("invalid_formal_choice_option")
        option_id = str(option.get("option_id", ""))
        ref = option.get("ref")
        if not option_id or option_id in option_by_id:
            raise NativeBridgeError("duplicate_formal_choice_option")
        if isinstance(ref, dict):
            ref_player = int(ref.get("player", actor))
            ref_zone = str(ref.get("zone", ""))
            if (
                ref_player != actor
                and ref_zone in {"deck", "hand", "prize", "prizes"}
            ):
                raise NativeBridgeError(
                    "opponent_hidden_choice_reference_rejected"
                )
        option_by_id[option_id] = option

    request_id = str(pending.get("request_id", ""))
    request_type = str(pending.get("request_type", ""))
    if not request_id or not request_type:
        raise NativeBridgeError("invalid_formal_pending_choice")
    allowed: list[dict[str, Any]] = []
    seen: set[tuple[str, tuple[str, ...], bool]] = set()
    for candidate in candidates:
        response = candidate.payload
        if not isinstance(response, ChoiceResponse):
            raise NativeBridgeError("invalid_formal_choice_candidate")
        key = _formal_choice_key(response)
        if key[0] != request_id or key in seen:
            raise NativeBridgeError("invalid_formal_choice_candidate")
        seen.add(key)
        for option_id in key[1]:
            if option_id not in option_by_id:
                raise NativeBridgeError("stale_formal_choice_candidate")
        first_ref = (
            option_by_id[key[1][0]].get("ref")
            if key[1]
            else None
        )
        allowed.append(
            {
                "kind": "choice",
                "signature": str(candidate.signature),
                "request_id": request_id,
                "request_type": request_type,
                "selected_options": list(key[1]),
                "cancelled": key[2],
                "ref": _json_value(first_ref),
            }
        )

    metadata = pending.get("metadata", {})
    continuation = (
        metadata.get("continuation", {})
        if isinstance(metadata, dict)
        else {}
    )
    visible_continuation: dict[str, Any] = {}
    if isinstance(continuation, dict):
        top_card_ids = continuation.get("top_card_ids")
        if top_card_ids:
            if (
                not isinstance(top_card_ids, list)
                or any(
                    not isinstance(card_id, str) or not card_id
                    for card_id in top_card_ids
                )
            ):
                raise NativeBridgeError("invalid_visible_top_card_ids")
            visible_continuation["top_card_ids"] = list(top_card_ids)
    return {
        "request_id": request_id,
        "request_type": request_type,
        "player": actor,
        "min_select": int(pending.get("min_select", 0)),
        "max_select": int(pending.get("max_select", 0)),
        "allow_duplicates": bool(
            pending.get("allow_duplicates", False)
        ),
        "can_cancel": bool(pending.get("can_cancel", False)),
        "options": options,
        "metadata": {"continuation": visible_continuation},
        "allowed_candidates": allowed,
    }


def _public_native_prize_continuation(
    wire_state: dict[str, Any],
    pending: dict[str, Any],
    actor: int,
) -> dict[str, Any] | None:
    """Rebuild a prize continuation from public VM control state.

    The authoritative Python result can enter prize selection while the
    selected native determinization did not.  Only stable control frames are
    translated here; the serialized Python context is deliberately ignored so
    private card identities cannot cross the native ABI.
    """
    request_type = str(pending.get("request_type", ""))
    expected_kinds = {
        "select_prize": "select_prize",
        "select_prize_energy_target": "treasure_prize_target",
    }
    expected_kind = expected_kinds.get(request_type)
    if expected_kind is None:
        return None

    def invalid() -> None:
        raise NativeBridgeError(
            "native_public_prize_continuation_invalid"
        )

    if (
        actor not in (0, 1)
        or type(pending.get("player")) is not int
        or pending["player"] != actor
    ):
        invalid()
    metadata = pending.get("metadata")
    if not isinstance(metadata, dict):
        invalid()
    formal = metadata.get("continuation")
    if not isinstance(formal, dict):
        invalid()
    allowed_formal_keys = {
        "kind",
        "domain",
        "player_idx",
        "_resume",
    }
    if request_type == "select_prize_energy_target":
        allowed_formal_keys.update({
            "prize_index",
            "card_id",
            "trigger_hook",
            "trigger_op",
        })
    if (
        set(formal) != allowed_formal_keys
        or formal.get("kind") != expected_kind
        or formal.get("domain") != "prize"
        or type(formal.get("player_idx")) is not int
        or formal["player_idx"] != actor
    ):
        invalid()

    resume = formal.get("_resume")
    expected_resume_keys = {
        "version",
        "player_idx",
        "source_slot",
        "complete",
        "frames",
        "unsupported_frames",
        "context",
        "attack_failed",
    }
    if (
        not isinstance(resume, dict)
        or set(resume) != expected_resume_keys
        or type(resume.get("version")) is not int
        or resume["version"] != 1
        or type(resume.get("player_idx")) is not int
        or resume["player_idx"] not in (0, 1)
        or not isinstance(resume.get("source_slot"), str)
        or not resume["source_slot"]
        or resume.get("complete") is not True
        or resume.get("unsupported_frames") != []
        or not isinstance(resume.get("context"), dict)
        or type(resume.get("attack_failed")) is not bool
        or not isinstance(resume.get("frames"), list)
    ):
        invalid()

    frames = resume["frames"]
    frame_index = 0
    finish_attack_actor = metadata.get("finish_attack_actor")
    has_finish_attack = (
        type(finish_attack_actor) is int
        and finish_attack_actor in (0, 1)
    )
    if "finish_attack_actor" in metadata and not has_finish_attack:
        invalid()
    finish_checkup_actor: int | None = None
    if frames and isinstance(frames[0], dict) and (
        frames[0].get("kind") == "finalize_attack_turn"
    ):
        attack_frame = frames[0]
        if (
            set(attack_frame) != {"kind", "actor"}
            or type(attack_frame.get("actor")) is not int
            or attack_frame["actor"] not in (0, 1)
            or not has_finish_attack
            or attack_frame["actor"] != finish_attack_actor
            or resume["player_idx"] != finish_attack_actor
            or str(wire_state.get("phase", "")) != "ATTACK"
        ):
            invalid()
        frame_index = 1
    elif frames and isinstance(frames[0], dict) and (
        frames[0].get("kind") == "finalize_checkup_turn"
    ):
        checkup_frame = frames[0]
        finish_checkup_actor = checkup_frame.get("actor")
        if (
            set(checkup_frame) != {"kind", "actor"}
            or type(finish_checkup_actor) is not int
            or finish_checkup_actor not in (0, 1)
            or has_finish_attack
            or resume["player_idx"] != finish_checkup_actor
            or str(wire_state.get("phase", ""))
                != "POKEMON_CHECKUP"
            or int(wire_state.get("active_player_idx", -1))
                != finish_checkup_actor
        ):
            invalid()
        frame_index = 1
    elif has_finish_attack:
        invalid()

    if (
        frame_index >= len(frames)
        or not isinstance(frames[frame_index], dict)
        or frames[frame_index] != {"kind": "finalize_knockout_batch"}
    ):
        invalid()
    frame_index += 1
    remaining_prize_players: list[int] = []
    for frame in reversed(frames[frame_index:]):
        if (
            not isinstance(frame, dict)
            or set(frame) != {"kind", "player_idx"}
            or frame.get("kind") != "prize_selection"
            or type(frame.get("player_idx")) is not int
            or frame["player_idx"] not in (0, 1)
        ):
            invalid()
        remaining_prize_players.append(frame["player_idx"])

    result: dict[str, Any] = {
        "kind": expected_kind,
        "actor": actor,
        "remaining_prize_players": remaining_prize_players,
    }
    if has_finish_attack:
        result["finish_attack_after_prizes"] = True
        result["resume_attack_actor"] = int(finish_attack_actor)
    elif finish_checkup_actor is not None:
        result["finish_checkup_after_prizes"] = True
        result["resume_checkup_actor"] = finish_checkup_actor

    if request_type == "select_prize_energy_target":
        prize_index = formal.get("prize_index")
        card_id = formal.get("card_id")
        players = wire_state.get("players")
        if (
            type(prize_index) is not int
            or prize_index < 0
            or not isinstance(card_id, str)
            or not card_id
            or formal.get("trigger_hook") != "ON_PRIZE_REVEALED"
            or formal.get("trigger_op")
                != "attach_to_benched_pokemon"
            or not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
            or not isinstance(players[actor].get("prizes"), list)
            or prize_index >= len(players[actor]["prizes"])
            or players[actor]["prizes"][prize_index] != card_id
        ):
            invalid()
        # This identity was revealed by the prize trigger to the choosing
        # player.  The native search pins only this actor-visible position.
        result["prize_index"] = prize_index
        result["prize_card_id"] = card_id
    return result


def _sanitize_public_after_damage_trigger_groups(
    wire_state: dict[str, Any],
    raw_trigger_specs: Any,
    attack_actor: int,
    *,
    error_code: str,
) -> list[dict[str, Any]] | None:
    """Return a hidden-information-safe public after-damage queue.

    Effect labels are deliberately discarded.  Damage targets are accepted
    only when the formal target identity still matches the public in-play
    Pokemon at that slot.  Unsupported trigger operations return ``None`` so
    callers can fail closed or keep the decision on the reference engine.
    """

    def invalid() -> None:
        raise NativeBridgeError(error_code)

    players = wire_state.get("players")
    if (
        attack_actor not in (0, 1)
        or not isinstance(raw_trigger_specs, list)
        or len(raw_trigger_specs) > 64
        or not isinstance(players, list)
        or len(players) != 2
        or any(not isinstance(player, dict) for player in players)
    ):
        invalid()

    def public_pokemon_card_id(player_idx: int, slot: str) -> str:
        owner = players[player_idx]
        target: Any = None
        if slot == "active":
            target = owner.get("active")
        elif slot.startswith("bench_") and slot[6:].isdigit():
            index = int(slot[6:])
            bench = owner.get("bench")
            if isinstance(bench, list) and 0 <= index < len(bench):
                target = bench[index]
        return (
            str(target.get("card_id", ""))
            if isinstance(target, dict)
            else ""
        )

    grouped: dict[int, list[dict[str, Any]]] = {
        attack_actor: [],
        1 - attack_actor: [],
    }
    for spec in raw_trigger_specs:
        if (
            not isinstance(spec, dict)
            or set(spec) != {"op", "args", "branches"}
            or spec.get("branches") != {}
            or not isinstance(spec.get("args"), dict)
        ):
            invalid()
        op = spec.get("op")
        args = spec["args"]
        if op == "trigger_draw_cards":
            if (
                set(args) != {"player", "amount", "source"}
                or type(args.get("player")) is not int
                or args["player"] not in (0, 1)
                or type(args.get("amount")) is not int
                or not 0 < args["amount"] <= 64
                or not isinstance(args.get("source"), str)
            ):
                invalid()
            owner = args["player"]
            safe_spec = {
                "op": op,
                "args": {
                    "player": owner,
                    "amount": args["amount"],
                },
            }
        elif op == "trigger_place_damage_counters":
            target_ref = args.get("target_ref")
            if (
                set(args) != {
                    "player",
                    "slot",
                    "count",
                    "source",
                    "target_ref",
                }
                or type(args.get("player")) is not int
                or args["player"] not in (0, 1)
                or not isinstance(args.get("slot"), str)
                or not args["slot"]
                or type(args.get("count")) is not int
                or not 0 < args["count"] <= 100
                or not isinstance(args.get("source"), str)
                or not isinstance(target_ref, dict)
                or set(target_ref)
                    != {"kind", "player", "slot", "card_id"}
                or target_ref.get("kind") != "pokemon"
                or target_ref.get("player") != args["player"]
                or target_ref.get("slot") != args["slot"]
                or not isinstance(target_ref.get("card_id"), str)
                or not target_ref["card_id"]
                or public_pokemon_card_id(
                    args["player"],
                    args["slot"],
                ) != target_ref["card_id"]
            ):
                invalid()
            owner = args["player"]
            safe_spec = {
                "op": op,
                "args": {
                    "player": owner,
                    "slot": args["slot"],
                    "count": args["count"],
                    "target_card_id": target_ref["card_id"],
                },
            }
        else:
            return None
        grouped[owner].append(safe_spec)

    return [
        {"owner": owner, "specs": grouped[owner]}
        for owner in (attack_actor, 1 - attack_actor)
        if grouped[owner]
    ]


def _public_native_vm_continuation(
    wire_state: dict[str, Any],
    pending: dict[str, Any],
    actor: int,
    card_definitions: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Translate an actor-visible, stack-complete Python VM pause.

    Only continuations whose entire remaining stack is empty are eligible.
    The whitelist covers actor-visible board, hand, look-top and deck-search
    choices plus Gardenia's draw/attach distribution.  The latter carries a
    minimal public rollback delta because cancelling the request restores the
    whole trainer action.
    """
    metadata = pending.get("metadata")
    formal = (
        metadata.get("continuation")
        if isinstance(metadata, dict)
        else None
    )
    if not isinstance(formal, dict):
        return None

    def invalid() -> None:
        raise NativeBridgeError(
            "native_public_vm_continuation_invalid"
        )

    if formal.get("kind") == "switch_confirm":
        bench_indices = formal.get("bench_indices")
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "confirm"
            or pending.get("min_select") != 1
            or pending.get("max_select") != 1
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not False
            or set(formal) != {
                "kind",
                "target_player_idx",
                "chooser_idx",
                "request_type",
                "request_target_player",
                "bench_indices",
                "_resume",
            }
            or formal.get("target_player_idx") != actor
            or formal.get("chooser_idx") != actor
            or formal.get("request_type") != "select_bench"
            or formal.get("request_target_player") != "self"
            or not isinstance(bench_indices, list)
            or not 1 <= len(bench_indices) <= 5
            or any(
                type(index) is not int or not 0 <= index < 5
                for index in bench_indices
            )
            or len(set(bench_indices)) != len(bench_indices)
        ):
            invalid()

        options = pending.get("options")
        if (
            not isinstance(options, list)
            or len(options) != 2
            or any(
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("label"), str)
                or option.get("ref") is not None
                for option in options
            )
            or {
                (option.get("option_id"), option.get("value"))
                for option in options
            } != {("confirm:yes", True), ("confirm:no", False)}
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
            or not isinstance(players[actor].get("bench"), list)
        ):
            invalid()
        bench = players[actor]["bench"]
        if bench_indices != [
            index for index, pokemon in enumerate(bench)
            if pokemon is not None
        ]:
            invalid()

        resume = formal.get("_resume")
        resume_context = (
            resume.get("context") if isinstance(resume, dict) else None
        )
        raw_trigger_specs = (
            resume_context.get("pending_after_damage_trigger_specs")
            if isinstance(resume_context, dict)
            else None
        )
        if (
            not isinstance(metadata, dict)
            or metadata.get("finish_attack_actor") != actor
            or not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("frames") != [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            or resume.get("unsupported_frames") != []
            or not isinstance(resume_context, dict)
            or set(resume_context) != {
                "attack_resolution",
                "pending_after_damage_trigger_specs",
            }
            or resume_context.get("attack_resolution") != {
                "active": True,
                "player_idx": actor,
            }
            or not isinstance(raw_trigger_specs, list)
            or len(raw_trigger_specs) > 64
            or resume.get("attack_failed") is not False
            or wire_state.get("phase") != "ATTACK"
            or int(wire_state.get("active_player_idx", -1)) != actor
        ):
            invalid()

        post_vm_trigger_groups = _sanitize_public_after_damage_trigger_groups(
            wire_state,
            raw_trigger_specs,
            actor,
            error_code="native_public_vm_trigger_queue_invalid",
        )
        if post_vm_trigger_groups is None:
            invalid()
        source_slot = resume["source_slot"]
        result = {
            "kind": "vm",
            "actor": actor,
            "finish_attack": True,
            "vm": {
                "op": "switch_pokemon",
                "command_spec": {
                    "op": "switch_pokemon",
                    "args": {"target": "self", "optional": True},
                },
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack",
        }
        if post_vm_trigger_groups:
            result["post_vm_trigger_groups"] = post_vm_trigger_groups
        return result

    if formal.get("kind") == "choose_damage_target":
        amount = formal.get("amount")
        target_player = formal.get("target_player_idx")
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "search_deck"
            or set(formal) != {
                "kind",
                "target_player_idx",
                "amount",
                "_resume",
            }
            or type(target_player) is not int
            or target_player != 1 - actor
            or type(amount) is not int
            or not 0 < amount <= 1000
            or pending.get("min_select") != 1
            or pending.get("max_select") != 1
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not False
            or metadata.get("domain") != "search_deck"
            or metadata.get("from_zone") != "board"
            or metadata.get("target_player") != "opponent"
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or any(not isinstance(player, dict) for player in players)
            or not isinstance(players[target_player].get("bench"), list)
            or not isinstance(players[actor].get("active"), dict)
        ):
            invalid()
        target_owner = players[target_player]
        target_bench = target_owner["bench"]
        expected_targets: dict[str, dict[str, Any]] = {}
        if isinstance(target_owner.get("active"), dict):
            expected_targets["active"] = target_owner["active"]
        for index, pokemon in enumerate(target_bench):
            if pokemon is not None:
                if not isinstance(pokemon, dict) or not 0 <= index < 5:
                    invalid()
                expected_targets[f"bench_{index}"] = pokemon
        if not 2 <= len(expected_targets) <= 6:
            invalid()

        options = pending.get("options")
        seen_ids: set[str] = set()
        seen_slots: set[str] = set()
        option_card_ids: list[str] = []
        if (
            not isinstance(options, list)
            or len(options) != len(expected_targets)
        ):
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or option["option_id"] in seen_ids
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), str)
                or not option["value"]
            ):
                invalid()
            ref = option["ref"]
            slot = ref.get("slot")
            target = expected_targets.get(slot)
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "pokemon"
                or ref.get("player") != target_player
                or ref.get("zone") != ""
                or not isinstance(slot, str)
                or slot in seen_slots
                or ref.get("index") != -1
                or ref.get("attachment_type") != ""
                or not isinstance(target, dict)
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or target.get("card_id") != ref["card_id"]
                or option["value"] != ref["card_id"]
            ):
                invalid()
            seen_ids.add(option["option_id"])
            seen_slots.add(slot)
            option_card_ids.append(option["value"])
        if (
            seen_slots != set(expected_targets)
            or metadata.get("card_list_ids") != option_card_ids
        ):
            invalid()

        resume = formal.get("_resume")
        resume_context = (
            resume.get("context") if isinstance(resume, dict) else None
        )
        attack_damage = (
            resume_context.get("attack_damage")
            if isinstance(resume_context, dict)
            else None
        )
        attacker_ref = (
            attack_damage.get("attacker_ref")
            if isinstance(attack_damage, dict)
            else None
        )
        if (
            metadata.get("finish_attack_actor") != actor
            or not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or resume.get("source_slot") != "active"
            or resume.get("complete") is not True
            or resume.get("frames") != [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
                {"kind": "finalize_attack_damage"},
            ]
            or resume.get("unsupported_frames") != []
            or not isinstance(resume_context, dict)
            or set(resume_context) != {
                "attack_damage",
                "attack_resolution",
            }
            or resume_context.get("attack_resolution") != {
                "active": True,
                "player_idx": actor,
            }
            or not isinstance(attack_damage, dict)
            or set(attack_damage) != {
                "active",
                "player_idx",
                "base_damage",
                "attacker_type",
                "ignore_weakness",
                "ignore_resistance",
                "ignore_defender_damage_effects",
                "attacker_ref",
            }
            or attack_damage.get("active") is not True
            or attack_damage.get("player_idx") != actor
            or attack_damage.get("base_damage") != 0
            or not isinstance(attack_damage.get("attacker_type"), str)
            or not attack_damage["attacker_type"]
            or type(attack_damage.get("ignore_weakness")) is not bool
            or type(attack_damage.get("ignore_resistance")) is not bool
            or type(
                attack_damage.get("ignore_defender_damage_effects")
            ) is not bool
            or not isinstance(attacker_ref, dict)
            or set(attacker_ref) != {"player", "slot", "card_id"}
            or attacker_ref.get("player") != actor
            or attacker_ref.get("slot") != "active"
            or not isinstance(attacker_ref.get("card_id"), str)
            or not attacker_ref["card_id"]
            or players[actor]["active"].get("card_id")
                != attacker_ref["card_id"]
            or resume.get("attack_failed") is not False
            or wire_state.get("phase") != "ATTACK"
            or int(wire_state.get("active_player_idx", -1)) != actor
        ):
            invalid()

        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": True,
            "vm": {
                "op": "choose_damage_target",
                "command_spec": {
                    "op": "choose_damage_target",
                    "args": {
                        "amount": amount,
                        "player": "opponent",
                    },
                },
                "actor": actor,
                "source_slot": "active",
                "stage": 0,
            },
            "context": {
                "base_damage": 0,
                "ignore_weakness": attack_damage["ignore_weakness"],
                "ignore_resistance": attack_damage[
                    "ignore_resistance"
                ],
                "ignore_defender_damage_effects": attack_damage[
                    "ignore_defender_damage_effects"
                ],
                "attack_failed": False,
            },
            "remaining_effects": [],
            "source_slot": "active",
            "context_mode": "attack",
        }

    if formal.get("kind") == "energy_relocate_distribution":
        attachment_refs = formal.get("attachment_refs")
        card_ids = formal.get("card_ids")
        source_slot = formal.get("source_slot")
        same_target = formal.get("same_target")
        count = len(attachment_refs) if isinstance(attachment_refs, list) else 0
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "distribute_energy"
            or set(formal) != {
                "kind",
                "purpose",
                "player_idx",
                "source_player",
                "source_zone",
                "source_slot",
                "attachment_refs",
                "card_ids",
                "same_source",
                "max_per_target",
                "same_target",
                "_resume",
            }
            or formal.get("purpose") not in {
                "energy_relocate_target",
                "relocate_energy_target",
            }
            or formal.get("player_idx") != actor
            or formal.get("source_player") != actor
            or formal.get("source_zone") != "field"
            or not isinstance(source_slot, str)
            or (
                source_slot != "active"
                and not (
                    source_slot.startswith("bench_")
                    and source_slot[6:].isdigit()
                    and 0 <= int(source_slot[6:]) < 5
                )
            )
            or not 1 <= count <= 64
            or not isinstance(card_ids, list)
            or len(card_ids) != count
            or any(not isinstance(card_id, str) or not card_id for card_id in card_ids)
            or formal.get("same_source") is not True
            or formal.get("max_per_target") != count
            or type(same_target) is not bool
            or pending.get("min_select") != count
            or pending.get("max_select") != count
            or pending.get("allow_duplicates") is not (count > 1)
            or pending.get("can_cancel") is not False
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
            or not isinstance(players[actor].get("bench"), list)
        ):
            invalid()
        owner = players[actor]
        bench = owner["bench"]

        def board_pokemon(slot: str) -> dict[str, Any] | None:
            if slot == "active":
                value = owner.get("active")
            elif slot.startswith("bench_") and slot[6:].isdigit():
                index = int(slot[6:])
                value = bench[index] if 0 <= index < len(bench) else None
            else:
                value = None
            return value if isinstance(value, dict) else None

        source = board_pokemon(source_slot)
        source_energy = source.get("energy_card_ids") if source is not None else None
        safe_attachments: list[dict[str, Any]] = []
        seen_indices: set[int] = set()
        if not isinstance(source_energy, list):
            invalid()
        for ordinal, ref in enumerate(attachment_refs):
            if not isinstance(ref, dict):
                invalid()
            index = ref.get("index")
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "attachment"
                or ref.get("player") != actor
                or ref.get("zone") != "field"
                or ref.get("slot") != source_slot
                or type(index) is not int
                or not 0 <= index < len(source_energy)
                or index in seen_indices
                or ref.get("attachment_type") != "energy"
                or ref.get("card_id") != card_ids[ordinal]
                or source_energy[index] != card_ids[ordinal]
            ):
                invalid()
            seen_indices.add(index)
            safe_attachments.append({
                "kind": "attachment",
                "player": actor,
                "card_id": card_ids[ordinal],
                "slot": source_slot,
                "attachment_type": "energy",
                "index": index,
            })

        options = pending.get("options")
        expected_slots = {
            "active" if slot_index == -1 else f"bench_{slot_index}"
            for slot_index, pokemon in [
                (-1, owner.get("active")),
                *list(enumerate(bench)),
            ]
            if pokemon is not None
            and ("active" if slot_index == -1 else f"bench_{slot_index}")
                != source_slot
        }
        seen_slots: set[str] = set()
        if not isinstance(options, list) or not options:
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), dict)
            ):
                invalid()
            ref = option["ref"]
            value = option["value"]
            slot = ref.get("slot")
            target = board_pokemon(str(slot))
            if (
                not isinstance(slot, str)
                or slot not in expected_slots
                or slot in seen_slots
                or set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "pokemon"
                or ref.get("player") != actor
                or ref.get("zone") != ""
                or ref.get("index") != -1
                or ref.get("attachment_type") != ""
                or target is None
                or ref.get("card_id") != target.get("card_id")
                or set(value) != {
                    "player",
                    "slot",
                    "name",
                    "card_id",
                    "bench_idx",
                }
                or value.get("player") != actor
                or value.get("slot") != slot
                or not isinstance(value.get("name"), str)
                or value.get("card_id") != ref.get("card_id")
                or value.get("bench_idx")
                    != (-1 if slot == "active" else int(slot[6:]))
                or option.get("option_id")
                    != f"pokemon:{actor}:{slot}:{ref.get('card_id')}"
            ):
                invalid()
            seen_slots.add(slot)
        if seen_slots != expected_slots:
            invalid()

        if (
            not isinstance(metadata, dict)
            or metadata.get("domain") != "distribute_energy"
            or metadata.get("distribute_mode") != "paired"
            or metadata.get("max_per_target") != count
            or metadata.get("card_ids") != card_ids
            or metadata.get("card_list_ids") != card_ids
            or metadata.get("purpose") not in {
                "energy_relocate_target",
                "relocate_energy_target",
            }
            or metadata.get("source_player") != actor
            or metadata.get("source_zone") != "field"
            or metadata.get("source_slot") != source_slot
            or metadata.get("same_source") is not True
            or metadata.get("same_target") is not same_target
            or metadata.get("attachment_refs") != attachment_refs
            or metadata.get("finish_attack_actor") != actor
        ):
            invalid()

        resume = formal.get("_resume")
        resume_context = (
            resume.get("context") if isinstance(resume, dict) else None
        )
        raw_trigger_specs = (
            resume_context.get("pending_after_damage_trigger_specs")
            if isinstance(resume_context, dict)
            else None
        )
        if (
            not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or resume.get("source_slot") != source_slot
            or resume.get("complete") is not True
            or resume.get("frames") != [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            or resume.get("unsupported_frames") != []
            or not isinstance(resume_context, dict)
            or set(resume_context) != {
                "attack_resolution",
                "pending_after_damage_trigger_specs",
            }
            or resume_context.get("attack_resolution") != {
                "active": True,
                "player_idx": actor,
            }
            or not isinstance(raw_trigger_specs, list)
            or len(raw_trigger_specs) > 64
            or resume.get("attack_failed") is not False
            or wire_state.get("phase") != "ATTACK"
            or int(wire_state.get("active_player_idx", -1)) != actor
        ):
            invalid()

        post_vm_trigger_groups = _sanitize_public_after_damage_trigger_groups(
            wire_state,
            raw_trigger_specs,
            actor,
            error_code="native_public_vm_trigger_queue_invalid",
        )
        if post_vm_trigger_groups is None:
            invalid()
        result = {
            "kind": "vm",
            "actor": actor,
            "finish_attack": True,
            "vm": {
                "op": "relocate_energy",
                "command_spec": {
                    "op": "relocate_energy",
                    "args": {
                        "amount": count,
                        "from_self": source_slot == "active",
                        "energy_type": "any",
                        "min_select": count,
                        "same_target": same_target,
                    },
                },
                "actor": actor,
                "source_slot": source_slot,
                "stage": 1,
                "selected_attachments": safe_attachments,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack",
        }
        if post_vm_trigger_groups:
            result["post_vm_trigger_groups"] = post_vm_trigger_groups
        return result

    if formal.get("kind") == "draw_and_attach_energy_distribution":
        allowed_keys = {
            "kind",
            "player_idx",
            "max_per_target",
            "same_target",
            "energy_type",
            "_resume",
        }
        minimum = pending.get("min_select")
        maximum = pending.get("max_select")
        maximum_per_target = formal.get("max_per_target")
        if (
            actor not in (0, 1)
            or type(pending.get("player")) is not int
            or pending["player"] != actor
            or pending.get("request_type") != "distribute_energy"
            or set(formal) != allowed_keys
            or type(formal.get("player_idx")) is not int
            or formal["player_idx"] != actor
            or type(minimum) is not int
            or type(maximum) is not int
            or not 0 <= minimum <= maximum <= 64
            or type(maximum_per_target) is not int
            or maximum_per_target != maximum
            or formal.get("same_target") is not True
            or not isinstance(formal.get("energy_type"), str)
            or not formal["energy_type"]
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not (minimum == 0)
        ):
            invalid()

        resume = formal.get("_resume")
        expected_resume_keys = {
            "version",
            "player_idx",
            "source_slot",
            "complete",
            "frames",
            "unsupported_frames",
            "context",
            "attack_failed",
        }
        if (
            not isinstance(resume, dict)
            or set(resume) != expected_resume_keys
            or type(resume.get("version")) is not int
            or resume["version"] != 1
            or type(resume.get("player_idx")) is not int
            or resume["player_idx"] != actor
            or resume.get("source_slot") != "active"
            or resume.get("complete") is not True
            or resume.get("frames") != []
            or resume.get("unsupported_frames") != []
            or resume.get("context") != {}
            or resume.get("attack_failed") is not False
            or wire_state.get("phase") != "MAIN"
            or int(wire_state.get("active_player_idx", -1)) != actor
        ):
            invalid()

        if not isinstance(metadata, dict):
            invalid()
        card_ids = metadata.get("card_ids")
        if (
            metadata.get("domain") != "distribute_energy"
            or metadata.get("distribute_mode") != "distribute"
            or metadata.get("max_per_target") != maximum
            or metadata.get("same_target") is not True
            or metadata.get("source_player") != actor
            or metadata.get("source_zone") != ""
            or metadata.get("purpose")
                != "draw_and_attach_energy_distribution"
            or metadata.get("pending_card_id") != ""
            or not isinstance(card_ids, list)
            or card_ids != metadata.get("card_list_ids")
            or len(card_ids) != maximum
            or any(
                not isinstance(card_id, str) or not card_id
                for card_id in card_ids
            )
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
        ):
            invalid()
        owner = players[actor]
        hand = owner.get("hand")
        deck = owner.get("deck")
        discard = owner.get("discard")
        bench = owner.get("bench")
        if (
            not isinstance(hand, list)
            or not isinstance(deck, list)
            or not isinstance(discard, list)
            or not isinstance(bench, list)
            or any(
                not isinstance(card_id, str) or not card_id
                for zone in (hand, deck, discard)
                for card_id in zone
            )
        ):
            invalid()
        remaining_hand = list(hand)
        for card_id in card_ids:
            if card_id not in remaining_hand:
                invalid()
            remaining_hand.remove(card_id)

        options = pending.get("options")
        option_pairs: set[tuple[int, str]] = set()
        target_slots: set[str] = set()
        if not isinstance(options, list) or not options:
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), dict)
            ):
                invalid()
            ref = option["ref"]
            value = option["value"]
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "pokemon"
                or type(ref.get("player")) is not int
                or ref["player"] != actor
                or ref.get("zone") != ""
                or not isinstance(ref.get("slot"), str)
                or not ref["slot"].startswith("bench_")
                or not ref["slot"][6:].isdigit()
                or not 0 <= int(ref["slot"][6:]) < len(bench)
                or ref.get("index") != -1
                or ref.get("attachment_type") != ""
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or set(value) != {
                    "slot",
                    "name",
                    "bench_idx",
                    "energy_index",
                    "energy_card_id",
                }
                or value.get("slot") != ref["slot"]
                or not isinstance(value.get("name"), str)
                or type(value.get("bench_idx")) is not int
                or value["bench_idx"] != int(ref["slot"][6:])
                or type(value.get("energy_index")) is not int
                or not 0 <= value["energy_index"] < len(card_ids)
                or value.get("energy_card_id")
                    != card_ids[value["energy_index"]]
            ):
                invalid()
            target = bench[value["bench_idx"]]
            if (
                not isinstance(target, dict)
                or target.get("card_id") != ref["card_id"]
            ):
                invalid()
            pair = (value["energy_index"], ref["slot"])
            if pair in option_pairs:
                invalid()
            option_pairs.add(pair)
            target_slots.add(ref["slot"])
        if option_pairs != {
            (energy_index, target_slot)
            for energy_index in range(len(card_ids))
            for target_slot in target_slots
        }:
            invalid()

        stack = wire_state.get("resolution_stack")
        stack_context = (
            stack.get("context")
            if isinstance(stack, dict)
            else None
        )
        checkpoint = (
            stack_context.get("cancel_action_checkpoint")
            if isinstance(stack_context, dict)
            and set(stack_context) == {"cancel_action_checkpoint"}
            else None
        )
        if (
            not isinstance(checkpoint, dict)
            or set(checkpoint)
                != {"state", "rng_state", "action_log", "events"}
            or not isinstance(checkpoint.get("state"), dict)
        ):
            invalid()
        before = checkpoint["state"]
        before_owner = before.get("p1" if actor == 0 else "p2")
        before_hand = (
            before_owner.get("hand_ids")
            if isinstance(before_owner, dict)
            else None
        )
        before_deck = (
            before_owner.get("deck_ids")
            if isinstance(before_owner, dict)
            else None
        )
        before_discard = (
            before_owner.get("discard_ids")
            if isinstance(before_owner, dict)
            else None
        )
        before_sequence = before.get("choice_sequence")
        before_revision = before.get("revision")
        if (
            before.get("phase") != "MAIN"
            or before.get("active_player_idx") != actor
            or type(before_sequence) is not int
            or type(before_revision) is not int
            or int(wire_state.get("choice_sequence", -1))
                != before_sequence + 1
            or int(wire_state.get("revision", -1))
                != before_revision + 1
            or not isinstance(before_hand, list)
            or not isinstance(before_deck, list)
            or not isinstance(before_discard, list)
            or any(
                not isinstance(card_id, str) or not card_id
                for zone in (before_hand, before_deck, before_discard)
                for card_id in zone
            )
            or before_owner.get("supporter_played") is not False
            or owner.get("supporter_played_this_turn") is not True
            or len(before_deck) < len(deck)
            or len(before_deck) - len(deck) > 2
            or before_deck[:len(deck)] != deck
            or len(discard) != len(before_discard) + 1
            or discard[:-1] != before_discard
        ):
            invalid()
        deck_top_before = before_deck[len(deck):]
        if sorted([*hand, *discard]) != sorted([
            *before_hand,
            *before_discard,
            *deck_top_before,
        ]):
            invalid()

        args = {
            "energy_count": maximum_per_target,
            "energy_type": formal["energy_type"],
            "min_select": minimum,
        }
        command_spec = {
            "op": "draw_and_attach_energy",
            "args": args,
        }
        source_slot = resume["source_slot"]
        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": False,
            "vm": {
                "op": "draw_and_attach_energy",
                "command_spec": command_spec,
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
            },
            "context": {},
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "",
            "cancel_rollback": {
                "hand_before": list(before_hand),
                "discard_before": list(before_discard),
                "deck_top_before": list(deck_top_before),
                "expected_current_deck_count": len(deck),
                "supporter_played_before": False,
                "choice_sequence_before": before_sequence,
            },
        }

    if formal.get("kind") == "energy_attach_distribution":
        allowed_keys = {
            "kind",
            "player_idx",
            "source_zone",
            "zone_name",
            "max_per_target",
            "same_target",
            "_resume",
        }
        source_zone = formal.get("source_zone")
        minimum = pending.get("min_select")
        maximum = pending.get("max_select")
        max_per_target = formal.get("max_per_target")
        same_target = formal.get("same_target")
        if (
            actor not in (0, 1)
            or type(pending.get("player")) is not int
            or pending["player"] != actor
            or pending.get("request_type") != "distribute_energy"
            or set(formal) != allowed_keys
            or formal.get("player_idx") != actor
            or source_zone not in {"hand", "deck"}
            or not isinstance(formal.get("zone_name"), str)
            or not formal["zone_name"]
            or type(minimum) is not int
            or type(maximum) is not int
            or not 0 <= minimum <= maximum <= 64
            or type(max_per_target) is not int
            or not 0 < max_per_target <= 99
            or type(same_target) is not bool
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not (minimum == 0)
        ):
            invalid()

        if not isinstance(metadata, dict):
            invalid()
        card_ids = metadata.get("card_ids")
        if (
            metadata.get("domain") != "distribute_energy"
            or metadata.get("distribute_mode") != "distribute"
            or metadata.get("max_per_target") != max_per_target
            or metadata.get("same_target") is not same_target
            or metadata.get("source_player") != actor
            or metadata.get("source_zone") != source_zone
            or metadata.get("purpose") != "energy_attach_distribution"
            or metadata.get("pending_card_id") != ""
            or not isinstance(card_ids, list)
            or card_ids != metadata.get("card_list_ids")
            or not maximum <= len(card_ids) <= 64
            or any(
                not isinstance(card_id, str) or not card_id
                for card_id in card_ids
            )
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
        ):
            invalid()
        owner = players[actor]
        source_cards = owner.get(source_zone)
        bench = owner.get("bench")
        active = owner.get("active")
        if (
            not isinstance(source_cards, list)
            or not isinstance(bench, list)
            or any(
                not isinstance(card_id, str) or not card_id
                for card_id in source_cards
            )
        ):
            invalid()
        remaining_source = list(source_cards)
        for card_id in card_ids:
            if card_id not in remaining_source:
                invalid()
            remaining_source.remove(card_id)
            if card_definitions is not None:
                definition = card_definitions.get(card_id)
                if (
                    not isinstance(definition, dict)
                    or definition.get("supertype") != "Energy"
                    or definition.get("energy_effects") not in (None, [])
                ):
                    # Native attach_energy deliberately does not synthesize
                    # Python-only ON_ATTACH trigger frames.
                    invalid()

        options = pending.get("options")
        option_pairs: set[tuple[int, str]] = set()
        target_slots: set[str] = set()
        seen_option_ids: set[str] = set()
        if not isinstance(options, list) or not options:
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or option["option_id"] in seen_option_ids
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), dict)
            ):
                invalid()
            ref = option["ref"]
            value = option["value"]
            slot = ref.get("slot")
            energy_index = value.get("energy_index")
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "pokemon"
                or type(ref.get("player")) is not int
                or ref["player"] != actor
                or ref.get("zone") != ""
                or not isinstance(slot, str)
                or (
                    slot != "active"
                    and not (
                        slot.startswith("bench_")
                        and slot[6:].isdigit()
                        and 0 <= int(slot[6:]) < len(bench)
                    )
                )
                or ref.get("index") != -1
                or ref.get("attachment_type") != ""
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or set(value) not in (
                    {"slot", "name", "energy_index", "energy_card_id"},
                    {
                        "slot",
                        "name",
                        "bench_idx",
                        "energy_index",
                        "energy_card_id",
                    },
                )
                or value.get("slot") != slot
                or not isinstance(value.get("name"), str)
                or type(energy_index) is not int
                or not 0 <= energy_index < len(card_ids)
                or value.get("energy_card_id")
                    != card_ids[energy_index]
            ):
                invalid()
            if "bench_idx" in value and (
                not slot.startswith("bench_")
                or type(value["bench_idx"]) is not int
                or value["bench_idx"] != int(slot[6:])
            ):
                invalid()
            target = (
                active
                if slot == "active"
                else bench[int(slot[6:])]
            )
            if (
                not isinstance(target, dict)
                or target.get("card_id") != ref["card_id"]
                or option["option_id"] != (
                    f"energy:{energy_index}:{card_ids[energy_index]}"
                    f"->pokemon:{actor}:{slot}:{ref['card_id']}"
                )
            ):
                invalid()
            pair = (energy_index, slot)
            if pair in option_pairs:
                invalid()
            seen_option_ids.add(option["option_id"])
            option_pairs.add(pair)
            target_slots.add(slot)
        if (
            len(target_slots) == 0
            or option_pairs != {
                (energy_index, target_slot)
                for energy_index in range(len(card_ids))
                for target_slot in target_slots
            }
            or (
                not same_target
                and any(slot == "active" for slot in target_slots)
            )
        ):
            invalid()

        resume = formal.get("_resume")
        expected_resume_keys = {
            "version",
            "player_idx",
            "source_slot",
            "complete",
            "frames",
            "unsupported_frames",
            "context",
            "attack_failed",
        }
        if (
            not isinstance(resume, dict)
            or set(resume) != expected_resume_keys
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("unsupported_frames") != []
            or resume.get("attack_failed") is not False
        ):
            invalid()
        finish_attack_actor = metadata.get("finish_attack_actor")
        resume_context = resume.get("context")
        raw_trigger_specs = (
            resume_context.get("pending_after_damage_trigger_specs")
            if isinstance(resume_context, dict)
            else None
        )
        attack_resume = (
            type(finish_attack_actor) is int
            and finish_attack_actor == actor
            and resume.get("frames") == [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            and isinstance(resume_context, dict)
            and set(resume_context) == {
                "attack_resolution",
                "pending_after_damage_trigger_specs",
            }
            and resume_context.get("attack_resolution") == {
                "active": True,
                "player_idx": actor,
            }
            and isinstance(raw_trigger_specs, list)
            and len(raw_trigger_specs) <= 64
            and wire_state.get("phase") == "ATTACK"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        main_resume = (
            finish_attack_actor is None
            and resume.get("frames") == []
            and resume.get("context") == {}
            and wire_state.get("phase") == "MAIN"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        if not attack_resume and not main_resume:
            raise NativeBridgeError(
                "native_public_vm_continuation_invalid:"
                "energy_attach_resume:"
                f"actor={actor}:"
                f"phase={wire_state.get('phase')}:"
                "active_player_idx="
                f"{wire_state.get('active_player_idx')}:"
                f"finish_attack_actor={finish_attack_actor}:"
                "resume_shape_mismatch"
            )

        post_vm_trigger_groups: list[dict[str, Any]] = []
        if attack_resume:
            sanitized = _sanitize_public_after_damage_trigger_groups(
                wire_state,
                raw_trigger_specs,
                actor,
                error_code="native_public_vm_trigger_queue_invalid",
            )
            if sanitized is None:
                invalid()
            post_vm_trigger_groups = sanitized

        target_kind = (
            "bench"
            if all(slot.startswith("bench_") for slot in target_slots)
            else "any"
        )
        args = {
            "amount": maximum,
            "from_zone": source_zone,
            "filter": "any",
            "to": target_kind,
            "optional": minimum == 0,
            "select_source": True,
            "min_select": minimum,
            "same_target": same_target,
            "max_per_target": max_per_target,
        }
        command_spec = {
            "op": "attach_energy",
            "args": args,
        }
        source_slot = resume["source_slot"]
        result = {
            "kind": "vm",
            "actor": actor,
            "finish_attack": attack_resume,
            "vm": {
                "op": "attach_energy",
                "command_spec": command_spec,
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
                "effective_amount": maximum,
                "distribution": True,
            },
            "context": (
                {
                    "damage_applied": True,
                    "after_damage_triggers_applied": True,
                    "reactive_thorns_applied": True,
                }
                if attack_resume
                else {}
            ),
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack" if attack_resume else "",
        }
        if post_vm_trigger_groups:
            result["post_vm_trigger_groups"] = post_vm_trigger_groups
        return result

    if formal.get("kind") == "attach_energy_to_board":
        allowed_keys = {
            "kind",
            "player_idx",
            "source_zone",
            "zone_name",
            "filter_type",
            "amount",
            "optional",
            "_resume",
        }
        source_zone = formal.get("source_zone")
        filter_type = formal.get("filter_type")
        amount = formal.get("amount")
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "search_deck"
            or set(formal) != allowed_keys
            or formal.get("player_idx") != actor
            or source_zone not in {"hand", "deck"}
            or not isinstance(formal.get("zone_name"), str)
            or not formal["zone_name"]
            or not isinstance(filter_type, str)
            or not filter_type
            or type(amount) is not int
            or not 0 < amount <= 64
            or formal.get("optional") is not False
            or pending.get("min_select") != 1
            or pending.get("max_select") != 1
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not False
            or not isinstance(metadata, dict)
            or metadata.get("from_zone") != "board"
            or metadata.get("target_player") != "self"
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
        ):
            invalid()
        owner = players[actor]
        source_cards = owner.get(source_zone)
        bench = owner.get("bench")
        active = owner.get("active")
        if (
            not isinstance(source_cards, list)
            or not isinstance(bench, list)
            or any(
                not isinstance(card_id, str) or not card_id
                for card_id in source_cards
            )
        ):
            invalid()

        normalized_filter = filter_type.lower()

        def matches_energy(card_id: str) -> bool:
            if card_definitions is None:
                return True
            definition = card_definitions.get(card_id)
            if (
                not isinstance(definition, dict)
                or definition.get("supertype") != "Energy"
            ):
                return False
            subtypes = definition.get("subtypes", [])
            provides = definition.get("provides_energy", [])
            return (
                normalized_filter in {"any", "energy"}
                or (
                    normalized_filter in {"basic", "basic_energy"}
                    and isinstance(subtypes, list)
                    and any(
                        str(subtype).lower() == "basic"
                        for subtype in subtypes
                    )
                )
                or (
                    isinstance(provides, list)
                    and any(
                        str(energy_type).lower() == normalized_filter
                        for energy_type in provides
                    )
                )
            )

        matching_source_ids = [
            card_id
            for card_id in source_cards
            if matches_energy(card_id)
        ]
        if not matching_source_ids:
            invalid()
        if card_definitions is not None and any(
            not isinstance(card_definitions.get(card_id), dict)
            or card_definitions[card_id].get("energy_effects")
                not in (None, [])
            for card_id in matching_source_ids
        ):
            # Native attach_energy does not synthesize Python ON_ATTACH
            # trigger frames, so every determinization-compatible source
            # must be trigger-free.
            invalid()

        options = pending.get("options")
        seen_slots: set[str] = set()
        seen_option_ids: set[str] = set()
        if not isinstance(options, list) or not options:
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or option["option_id"] in seen_option_ids
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), str)
            ):
                invalid()
            ref = option["ref"]
            slot = ref.get("slot")
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "pokemon"
                or ref.get("player") != actor
                or ref.get("zone") != ""
                or not isinstance(slot, str)
                or (
                    slot != "active"
                    and not (
                        slot.startswith("bench_")
                        and slot[6:].isdigit()
                        and 0 <= int(slot[6:]) < len(bench)
                    )
                )
                or slot in seen_slots
                or ref.get("index") != -1
                or ref.get("attachment_type") != ""
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or option["value"] != ref["card_id"]
                or option["option_id"] != (
                    f"pokemon:{actor}:{slot}:{ref['card_id']}"
                )
            ):
                invalid()
            target = (
                active
                if slot == "active"
                else bench[int(slot[6:])]
            )
            if (
                not isinstance(target, dict)
                or target.get("card_id") != ref["card_id"]
            ):
                invalid()
            seen_slots.add(slot)
            seen_option_ids.add(option["option_id"])

        resume = formal.get("_resume")
        if (
            not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("unsupported_frames") != []
            or resume.get("attack_failed") is not False
        ):
            invalid()
        finish_attack_actor = metadata.get("finish_attack_actor")
        attack_resume = (
            type(finish_attack_actor) is int
            and finish_attack_actor == actor
            and resume.get("frames") == [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            and resume.get("context") == {
                "attack_resolution": {
                    "active": True,
                    "player_idx": actor,
                },
                "pending_after_damage_trigger_specs": [],
            }
            and wire_state.get("phase") == "ATTACK"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        main_resume = (
            finish_attack_actor is None
            and resume.get("frames") == []
            and resume.get("context") == {}
            and wire_state.get("phase") == "MAIN"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        if not attack_resume and not main_resume:
            invalid()

        command_spec = {
            "op": "attach_energy",
            "args": {
                "amount": amount,
                "from_zone": source_zone,
                "filter": filter_type,
                "to": "any",
                "optional": False,
            },
        }
        source_slot = resume["source_slot"]
        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": attack_resume,
            "vm": {
                "op": "attach_energy",
                "command_spec": command_spec,
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
                "effective_amount": amount,
                "distribution": False,
            },
            "context": (
                {
                    "damage_applied": True,
                    "after_damage_triggers_applied": True,
                    "reactive_thorns_applied": True,
                }
                if attack_resume
                else {}
            ),
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack" if attack_resume else "",
        }

    if formal.get("kind") == "discard_hand_then_draw":
        discard_amount = formal.get("discard_amount")
        draw_amount = formal.get("draw_amount")
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "search_deck"
            or set(formal) != {
                "kind",
                "player_idx",
                "discard_amount",
                "draw_amount",
                "_resume",
            }
            or formal.get("player_idx") != actor
            or type(discard_amount) is not int
            or not 0 < discard_amount <= 64
            or type(draw_amount) is not int
            or not 0 <= draw_amount <= 64
            or pending.get("min_select") != 1
            or pending.get("max_select") != discard_amount
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not False
            or not isinstance(metadata, dict)
            or metadata.get("domain") != "search_deck"
            or metadata.get("from_zone") != "hand"
            or metadata.get("target_player") != ""
        ):
            invalid()

        players = wire_state.get("players")
        hand: Any = None
        if (
            isinstance(players, list)
            and len(players) == 2
            and isinstance(players[actor], dict)
        ):
            hand = players[actor].get("hand")
        if (
            not isinstance(hand, list)
            or not discard_amount < len(hand) <= 64
            or any(not isinstance(card_id, str) or not card_id for card_id in hand)
        ):
            invalid()

        options = pending.get("options")
        seen_ids: set[str] = set()
        seen_indices: set[int] = set()
        if not isinstance(options, list) or len(options) != len(hand):
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or option["option_id"] in seen_ids
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), str)
            ):
                invalid()
            ref = option["ref"]
            index = ref.get("index")
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "card"
                or ref.get("player") != actor
                or ref.get("zone") != "hand"
                or ref.get("slot") != ""
                or ref.get("attachment_type") != ""
                or type(index) is not int
                or not 0 <= index < len(hand)
                or index in seen_indices
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or hand[index] != ref["card_id"]
                or option["value"] != ref["card_id"]
            ):
                invalid()
            seen_ids.add(option["option_id"])
            seen_indices.add(index)
        if seen_indices != set(range(len(hand))):
            invalid()

        resume = formal.get("_resume")
        finish_attack_actor = metadata.get("finish_attack_actor")
        if (
            not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("unsupported_frames") != []
            or resume.get("attack_failed") is not False
        ):
            invalid()
        attack_resume = (
            type(finish_attack_actor) is int
            and finish_attack_actor == actor
            and resume.get("frames") == [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            and resume.get("context") == {
                "attack_resolution": {
                    "active": True,
                    "player_idx": actor,
                },
                "pending_after_damage_trigger_specs": [],
            }
            and wire_state.get("phase") == "ATTACK"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        main_resume = (
            finish_attack_actor is None
            and resume.get("frames") == []
            and resume.get("context") == {}
            and wire_state.get("phase") == "MAIN"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        if not attack_resume and not main_resume:
            invalid()

        command_spec = {
            "op": "discard_then_draw_cards",
            "args": {
                "discard_amount": discard_amount,
                "draw_amount": draw_amount,
            },
        }
        source_slot = resume["source_slot"]
        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": attack_resume,
            "vm": {
                "op": "discard_then_draw_cards",
                "command_spec": command_spec,
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
            },
            "context": (
                {
                    "damage_applied": True,
                    "after_damage_triggers_applied": True,
                    "reactive_thorns_applied": True,
                }
                if attack_resume
                else {}
            ),
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack" if attack_resume else "",
        }

    if formal.get("kind") == "search_cards":
        allowed_keys = {
            "kind",
            "player_idx",
            "from_zone",
            "destination",
            "count",
            "_resume",
        }
        from_zone = formal.get("from_zone")
        destination = formal.get("destination")
        count = formal.get("count")
        minimum = pending.get("min_select")
        maximum = pending.get("max_select")
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "search_deck"
            or set(formal) != allowed_keys
            or formal.get("player_idx") != actor
            or from_zone not in {"deck", "discard"}
            or destination not in {"hand", "bench"}
            or type(count) is not int
            or not 0 < count <= 64
            or type(minimum) is not int
            or type(maximum) is not int
            or not 0 <= minimum <= maximum <= count
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not (minimum == 0)
        ):
            invalid()

        players = wire_state.get("players")
        zone: Any = None
        if (
            isinstance(players, list)
            and len(players) == 2
            and isinstance(players[actor], dict)
        ):
            zone = players[actor].get(from_zone)
        if not isinstance(zone, list):
            invalid()
        bench_capacity: int | None = None
        if destination == "bench":
            bench = players[actor].get("bench")
            if (
                not isinstance(bench, list)
            ):
                invalid()
            bench_capacity = sum(target is None for target in bench)
            if maximum > bench_capacity:
                invalid()

        options = pending.get("options")
        seen_ids: set[str] = set()
        seen_indices: set[int] = set()
        if not isinstance(options, list) or not options:
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or option["option_id"] in seen_ids
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), str)
            ):
                invalid()
            ref = option["ref"]
            index = ref.get("index")
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "card"
                or ref.get("player") != actor
                or ref.get("zone") != from_zone
                or ref.get("slot") != ""
                or ref.get("attachment_type") != ""
                or type(index) is not int
                or not 0 <= index < len(zone)
                or index in seen_indices
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or zone[index] != ref["card_id"]
                or option["value"] != ref["card_id"]
            ):
                invalid()
            seen_ids.add(option["option_id"])
            seen_indices.add(index)
        expected_maximum = min(count, len(options))
        if bench_capacity is not None:
            expected_maximum = min(expected_maximum, bench_capacity)
        if maximum != expected_maximum:
            invalid()

        resume = formal.get("_resume")
        finish_attack_actor = (
            metadata.get("finish_attack_actor")
            if isinstance(metadata, dict)
            else None
        )
        if (
            not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("unsupported_frames") != []
            or resume.get("attack_failed") is not False
        ):
            invalid()
        attack_resume = (
            type(finish_attack_actor) is int
            and finish_attack_actor == actor
            and resume.get("frames") == [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            and resume.get("context") == {
                "attack_resolution": {
                    "active": True,
                    "player_idx": actor,
                },
                "pending_after_damage_trigger_specs": [],
            }
            and wire_state.get("phase") == "ATTACK"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        main_resume = (
            finish_attack_actor is None
            and resume.get("frames") == []
            and resume.get("context") == {}
            and wire_state.get("phase") == "MAIN"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        if not attack_resume and not main_resume:
            invalid()

        command_spec = {
            "op": "search_cards",
            "args": {
                "from_zone": from_zone,
                "destination": destination,
                "count": count,
            },
        }
        source_slot = resume["source_slot"]
        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": attack_resume,
            "vm": {
                "op": "search_cards",
                "command_spec": command_spec,
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
            },
            "context": (
                {
                    "damage_applied": True,
                    "after_damage_triggers_applied": True,
                    "reactive_thorns_applied": True,
                }
                if attack_resume
                else {}
            ),
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack" if attack_resume else "",
        }

    if formal.get("kind") == "search_item_and_tool":
        allowed_keys = {
            "kind",
            "player_idx",
            "_resume",
        }
        minimum = pending.get("min_select")
        maximum = pending.get("max_select")
        if (
            actor not in (0, 1)
            or pending.get("player") != actor
            or pending.get("request_type") != "search_deck"
            or set(formal) != allowed_keys
            or formal.get("player_idx") != actor
            or type(minimum) is not int
            or minimum != 1
            or type(maximum) is not int
            or not 1 <= maximum <= 2
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not False
            or not isinstance(card_definitions, dict)
        ):
            invalid()

        players = wire_state.get("players")
        deck: Any = None
        if (
            isinstance(players, list)
            and len(players) == 2
            and isinstance(players[actor], dict)
        ):
            deck = players[actor].get("deck")
        if (
            not isinstance(deck, list)
            or any(
                not isinstance(card_id, str) or not card_id
                for card_id in deck
            )
        ):
            invalid()

        matching_indices: set[int] = set()
        for index, card_id in enumerate(deck):
            definition = card_definitions.get(card_id)
            if not isinstance(definition, dict):
                invalid()
            trainer_type = str(
                definition.get("trainer_type", "")
            ).lower()
            if trainer_type in {"item", "tool"}:
                matching_indices.add(index)
        if (
            not matching_indices
            or maximum != min(2, len(matching_indices))
        ):
            invalid()

        options = pending.get("options")
        seen_ids: set[str] = set()
        seen_indices: set[int] = set()
        if not isinstance(options, list) or not options:
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option)
                    != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or option["option_id"] in seen_ids
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), str)
            ):
                invalid()
            ref = option["ref"]
            index = ref.get("index")
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "card"
                or ref.get("player") != actor
                or ref.get("zone") != "deck"
                or ref.get("slot") != ""
                or ref.get("attachment_type") != ""
                or type(index) is not int
                or index not in matching_indices
                or index in seen_indices
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or deck[index] != ref["card_id"]
                or option["value"] != ref["card_id"]
            ):
                invalid()
            seen_ids.add(option["option_id"])
            seen_indices.add(index)
        if seen_indices != matching_indices:
            invalid()

        resume = formal.get("_resume")
        finish_attack_actor = (
            metadata.get("finish_attack_actor")
            if isinstance(metadata, dict)
            else None
        )
        if (
            not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("unsupported_frames") != []
            or resume.get("attack_failed") is not False
        ):
            invalid()
        attack_resume = (
            type(finish_attack_actor) is int
            and finish_attack_actor == actor
            and resume.get("frames") == [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            and resume.get("context") == {
                "attack_resolution": {
                    "active": True,
                    "player_idx": actor,
                },
                "pending_after_damage_trigger_specs": [],
            }
            and wire_state.get("phase") == "ATTACK"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        main_resume = (
            finish_attack_actor is None
            and resume.get("frames") == []
            and resume.get("context") == {}
            and wire_state.get("phase") == "MAIN"
            and int(wire_state.get("active_player_idx", -1)) == actor
        )
        if not attack_resume and not main_resume:
            invalid()

        source_slot = resume["source_slot"]
        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": attack_resume,
            "vm": {
                "op": "search_item_and_tool",
                "command_spec": {
                    "op": "search_item_and_tool",
                    "args": {},
                },
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
            },
            "context": (
                {
                    "damage_applied": True,
                    "after_damage_triggers_applied": True,
                    "reactive_thorns_applied": True,
                }
                if attack_resume
                else {}
            ),
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack" if attack_resume else "",
        }

    if formal.get("kind") == "look_top_attach_energy":
        allowed_keys = {
            "kind",
            "player_idx",
            "count",
            "take",
            "top_card_ids",
            "display_top_positions",
            "_resume",
        }
        count = formal.get("count")
        take = formal.get("take")
        top_card_ids = formal.get("top_card_ids")
        display_positions = formal.get("display_top_positions")
        if (
            actor not in (0, 1)
            or type(pending.get("player")) is not int
            or pending["player"] != actor
            or pending.get("request_type") != "search_deck"
            or set(formal) != allowed_keys
            or formal.get("player_idx") != actor
            or type(count) is not int
            or not 0 < count <= 64
            or type(take) is not int
            or not 0 < take <= 99
            or not isinstance(top_card_ids, list)
            or len(top_card_ids) != count
            or any(
                not isinstance(card_id, str) or not card_id
                for card_id in top_card_ids
            )
            or not isinstance(display_positions, list)
            or any(
                type(position) is not int
                or not 0 <= position < count
                for position in display_positions
            )
            or len(set(display_positions)) != len(display_positions)
            or pending.get("min_select") != 0
            or pending.get("max_select")
                != min(take, len(display_positions))
            or pending.get("allow_duplicates") is not False
            or pending.get("can_cancel") is not True
        ):
            invalid()

        players = wire_state.get("players")
        if (
            not isinstance(players, list)
            or len(players) != 2
            or not isinstance(players[actor], dict)
            or not isinstance(players[actor].get("deck"), list)
            or len(players[actor]["deck"]) < count
            or [
                str(players[actor]["deck"][-1 - position])
                for position in range(count)
            ] != top_card_ids
        ):
            invalid()
        deck = players[actor]["deck"]

        options = pending.get("options")
        seen_positions: set[int] = set()
        if (
            not isinstance(options, list)
            or len(options) != len(display_positions)
        ):
            invalid()
        for option in options:
            if (
                not isinstance(option, dict)
                or set(option) != {"option_id", "label", "ref", "value"}
                or not isinstance(option.get("option_id"), str)
                or not option["option_id"]
                or not isinstance(option.get("label"), str)
                or not isinstance(option.get("ref"), dict)
                or not isinstance(option.get("value"), str)
            ):
                invalid()
            ref = option["ref"]
            if (
                set(ref) != {
                    "kind",
                    "player",
                    "zone",
                    "slot",
                    "index",
                    "attachment_type",
                    "card_id",
                }
                or ref.get("kind") != "card"
                or ref.get("player") != actor
                or ref.get("zone") != "deck"
                or type(ref.get("index")) is not int
                or ref.get("slot") != ""
                or ref.get("attachment_type") != ""
                or not isinstance(ref.get("card_id"), str)
                or not ref["card_id"]
                or option["value"] != ref["card_id"]
            ):
                invalid()
            position = len(deck) - 1 - ref["index"]
            if (
                position not in display_positions
                or position in seen_positions
                or top_card_ids[position] != ref["card_id"]
            ):
                invalid()
            seen_positions.add(position)
        if seen_positions != set(display_positions):
            invalid()

        resume = formal.get("_resume")
        context = (
            resume.get("context")
            if isinstance(resume, dict)
            else None
        )
        finish_attack_actor = (
            metadata.get("finish_attack_actor")
            if isinstance(metadata, dict)
            else None
        )
        if (
            type(finish_attack_actor) is not int
            or finish_attack_actor != actor
            or not isinstance(resume, dict)
            or set(resume) != {
                "version",
                "player_idx",
                "source_slot",
                "complete",
                "frames",
                "unsupported_frames",
                "context",
                "attack_failed",
            }
            or resume.get("version") != 1
            or resume.get("player_idx") != actor
            or not isinstance(resume.get("source_slot"), str)
            or not resume["source_slot"]
            or resume.get("complete") is not True
            or resume.get("frames") != [
                {"kind": "finalize_attack_turn", "actor": actor},
                {"kind": "finalize_attack_ko_checks"},
                {"kind": "finalize_after_damage_triggers"},
            ]
            or resume.get("unsupported_frames") != []
            or context != {
                "attack_resolution": {
                    "active": True,
                    "player_idx": actor,
                },
                "pending_after_damage_trigger_specs": [],
            }
            or resume.get("attack_failed") is not False
            or wire_state.get("phase") != "ATTACK"
            or int(wire_state.get("active_player_idx", -1)) != actor
        ):
            invalid()

        command_spec = {
            "op": "look_top_attach_energy",
            "args": {
                "count": count,
                "take": take,
                # The formal resolver always returns the unselected cards to
                # the deck and shuffles, and always permits any own Pokemon.
                "shuffle_rest": True,
                "target": "self_or_bench",
            },
        }
        source_slot = resume["source_slot"]
        return {
            "kind": "vm",
            "actor": actor,
            "finish_attack": True,
            "vm": {
                "op": "look_top_attach_energy",
                "command_spec": command_spec,
                "actor": actor,
                "source_slot": source_slot,
                "stage": 0,
            },
            "context": {
                "damage_applied": True,
                "after_damage_triggers_applied": True,
                "reactive_thorns_applied": True,
            },
            "remaining_effects": [],
            "source_slot": source_slot,
            "context_mode": "attack",
        }

    if formal.get("kind") != "look_top_deck":
        return None

    allowed_keys = {
        "kind",
        "player_idx",
        "count",
        "take",
        "rest_bottom",
        "shuffle_rest",
        "destination",
        "top_card_ids",
        "display_top_positions",
        "_resume",
    }
    if (
        actor not in (0, 1)
        or type(pending.get("player")) is not int
        or pending["player"] != actor
        or str(pending.get("request_type", "")) != "search_deck"
        or set(formal) != allowed_keys
        or type(formal.get("player_idx")) is not int
        or formal["player_idx"] != actor
        or type(formal.get("count")) is not int
        or not 0 < formal["count"] <= 64
        or type(formal.get("take")) is not int
        # ``99`` is the formal VM sentinel for "take every matching card"
        # (for example Candice).  Preserve it instead of clamping: the native
        # VM also uses the sentinel to derive a zero minimum selection.
        or not (
            0 < formal["take"] <= 64
            or formal["take"] == 99
        )
        or type(formal.get("rest_bottom")) is not bool
        or type(formal.get("shuffle_rest")) is not bool
        or formal.get("destination") not in {"hand", "bench_energy"}
    ):
        invalid()

    top_card_ids = formal.get("top_card_ids")
    display_positions = formal.get("display_top_positions")
    if (
        not isinstance(top_card_ids, list)
        or len(top_card_ids) != formal["count"]
        or any(
            not isinstance(card_id, str) or not card_id
            for card_id in top_card_ids
        )
        or not isinstance(display_positions, list)
        or any(
            type(position) is not int
            or position < 0
            or position >= formal["count"]
            for position in display_positions
        )
        or len(set(display_positions)) != len(display_positions)
    ):
        invalid()

    resume = formal.get("_resume")
    expected_resume_keys = {
        "version",
        "player_idx",
        "source_slot",
        "complete",
        "frames",
        "unsupported_frames",
        "context",
        "attack_failed",
    }
    if (
        not isinstance(resume, dict)
        or set(resume) != expected_resume_keys
        or type(resume.get("version")) is not int
        or resume["version"] != 1
        or type(resume.get("player_idx")) is not int
        or resume["player_idx"] != actor
        or not isinstance(resume.get("source_slot"), str)
        or not resume["source_slot"]
        or resume.get("complete") is not True
        or resume.get("frames") != []
        or resume.get("unsupported_frames") != []
        or resume.get("context") != {}
        or resume.get("attack_failed") is not False
    ):
        invalid()

    players = wire_state.get("players")
    if (
        not isinstance(players, list)
        or len(players) != 2
        or not isinstance(players[actor], dict)
        or not isinstance(players[actor].get("deck"), list)
        or len(players[actor]["deck"]) < len(top_card_ids)
        or [
            str(players[actor]["deck"][-1 - index])
            for index in range(len(top_card_ids))
        ] != top_card_ids
    ):
        invalid()

    args = {
        "count": formal["count"],
        "take": formal["take"],
        "rest_bottom": formal["rest_bottom"],
        "shuffle_rest": formal["shuffle_rest"],
        "destination": formal["destination"],
    }
    command_spec = {
        "op": "look_top_deck",
        "args": args,
    }
    source_slot = resume["source_slot"]
    return {
        "kind": "vm",
        "actor": actor,
        "finish_attack": False,
        "vm": {
            "op": "look_top_deck",
            "command_spec": command_spec,
            "actor": actor,
            "source_slot": source_slot,
            "stage": 0,
        },
        "context": {},
        "remaining_effects": [],
        "source_slot": source_slot,
        "context_mode": "",
    }


def _public_native_exp_share_continuation(
    wire_state: dict[str, Any],
    pending: dict[str, Any],
    actor: int,
) -> dict[str, Any] | None:
    """Rebuild the public Exp. Share confirmation and pending KO batch."""
    metadata = pending.get("metadata")
    formal = (
        metadata.get("continuation")
        if isinstance(metadata, dict)
        else None
    )
    if (
        not isinstance(formal, dict)
        or formal.get("kind") != "confirm_exp_share_trigger"
    ):
        return None

    def invalid() -> None:
        raise NativeBridgeError(
            "native_public_exp_share_continuation_invalid"
        )

    expected_formal_keys = {
        "kind",
        "domain",
        "frame_id",
        "from_player",
        "from_slot",
        "from_card_id",
        "to_player",
        "to_slot",
        "to_card_id",
        "source_name",
        "target_tool_id",
        "_resume",
    }
    from_slot = formal.get("from_slot")
    to_slot = formal.get("to_slot")
    expected_frame_id = (
        f"trigger:exp_share:{actor}:{from_slot}:"
        f"{actor}:{to_slot}"
    )
    if (
        actor not in (0, 1)
        or type(pending.get("player")) is not int
        or pending["player"] != actor
        or str(pending.get("request_type", "")) != "confirm_trigger"
        or set(formal) != expected_formal_keys
        or formal.get("domain") != "trigger"
        or type(formal.get("from_player")) is not int
        or formal["from_player"] != actor
        or type(formal.get("to_player")) is not int
        or formal["to_player"] != actor
        or from_slot != "active"
        or not isinstance(to_slot, str)
        or not to_slot.startswith("bench_")
        or not to_slot[6:].isdigit()
        or not 0 <= int(to_slot[6:]) < 5
        or formal.get("frame_id") != expected_frame_id
        or not isinstance(formal.get("from_card_id"), str)
        or not formal["from_card_id"]
        or not isinstance(formal.get("to_card_id"), str)
        or not formal["to_card_id"]
        or not isinstance(formal.get("source_name"), str)
        or not isinstance(formal.get("target_tool_id"), str)
        or not formal["target_tool_id"]
    ):
        invalid()

    players = wire_state.get("players")
    if (
        not isinstance(players, list)
        or len(players) != 2
        or not isinstance(players[actor], dict)
    ):
        invalid()
    owner = players[actor]
    active = owner.get("active")
    bench = owner.get("bench")
    bench_index = int(to_slot[6:])
    target = (
        bench[bench_index]
        if isinstance(bench, list) and bench_index < len(bench)
        else None
    )
    if (
        not isinstance(active, dict)
        or active.get("card_id") != formal["from_card_id"]
        or not isinstance(target, dict)
        or target.get("card_id") != formal["to_card_id"]
        or target.get("attached_tool_id")
            != formal["target_tool_id"]
    ):
        invalid()

    resume = formal.get("_resume")
    expected_resume_keys = {
        "version",
        "player_idx",
        "source_slot",
        "complete",
        "frames",
        "unsupported_frames",
        "context",
        "attack_failed",
    }
    finish_attack_actor = (
        metadata.get("finish_attack_actor")
        if isinstance(metadata, dict)
        else None
    )
    if (
        type(finish_attack_actor) is not int
        or finish_attack_actor not in (0, 1)
        or finish_attack_actor == actor
        or not isinstance(resume, dict)
        or set(resume) != expected_resume_keys
        or type(resume.get("version")) is not int
        or resume["version"] != 1
        or type(resume.get("player_idx")) is not int
        or resume["player_idx"] != finish_attack_actor
        or resume.get("source_slot") != "active"
        or resume.get("complete") is not True
        or resume.get("unsupported_frames") != []
        or resume.get("context") != {
            "attack_resolution": {
                "active": True,
                "player_idx": finish_attack_actor,
            },
        }
        or resume.get("attack_failed") is not False
        or str(wire_state.get("phase", "")) != "ATTACK"
        or int(wire_state.get("active_player_idx", -1))
            != finish_attack_actor
    ):
        invalid()

    frames = resume.get("frames")
    if (
        not isinstance(frames, list)
        or len(frames) < 2
        or frames[0] != {
            "kind": "finalize_attack_turn",
            "actor": finish_attack_actor,
        }
        or not isinstance(frames[1], dict)
        or set(frames[1]) != {"kind", "entries"}
        or frames[1].get("kind") != "discard_knockout_batch"
        or not isinstance(frames[1].get("entries"), list)
        or not 1 <= len(frames[1]["entries"]) <= 12
    ):
        invalid()
    knockout_entries: list[dict[str, Any]] = []
    seen_knockout_slots: set[tuple[int, str]] = set()
    source_knockout_seen = False
    for knockout in frames[1]["entries"]:
        if (
            not isinstance(knockout, dict)
            or set(knockout)
                != {"player_idx", "slot", "card_id", "prize_count"}
            or type(knockout.get("player_idx")) is not int
            or knockout["player_idx"] not in (0, 1)
            or not isinstance(knockout.get("slot"), str)
            or (
                knockout["slot"] != "active"
                and not (
                    knockout["slot"].startswith("bench_")
                    and knockout["slot"][6:].isdigit()
                    and 0 <= int(knockout["slot"][6:]) < 5
                )
            )
            or not isinstance(knockout.get("card_id"), str)
            or not knockout["card_id"]
            or type(knockout.get("prize_count")) is not int
            or not 1 <= knockout["prize_count"] <= 3
        ):
            invalid()
        knockout_key = (
            knockout["player_idx"],
            knockout["slot"],
        )
        if knockout_key in seen_knockout_slots:
            invalid()
        knockout_owner = players[knockout["player_idx"]]
        if not isinstance(knockout_owner, dict):
            invalid()
        knockout_bench = knockout_owner.get("bench")
        if (
            knockout["slot"] != "active"
            and (
                not isinstance(knockout_bench, list)
                or int(knockout["slot"][6:]) >= len(knockout_bench)
            )
        ):
            invalid()
        knockout_target = (
            knockout_owner.get("active")
            if knockout["slot"] == "active"
            else knockout_bench[int(knockout["slot"][6:])]
        )
        if (
            not isinstance(knockout_target, dict)
            or knockout_target.get("card_id")
                != knockout["card_id"]
        ):
            invalid()
        seen_knockout_slots.add(knockout_key)
        source_knockout_seen = source_knockout_seen or (
            knockout["player_idx"] == actor
            and knockout["slot"] == from_slot
            and knockout["card_id"] == formal["from_card_id"]
        )
        knockout_entries.append({
            "player_idx": knockout["player_idx"],
            "slot": knockout["slot"],
            "card_id": knockout["card_id"],
            "prize_count": knockout["prize_count"],
        })
    if not source_knockout_seen:
        invalid()

    if len(frames[2:]) > 1:
        invalid()
    remaining_exp_share_triggers = 0
    for frame in reversed(frames[2:]):
        if (
            not isinstance(frame, dict)
            or set(frame) != {"kind", "specs"}
            or frame.get("kind") != "trigger_order"
            or not isinstance(frame.get("specs"), list)
            or not 1 <= len(frame["specs"]) <= 8
        ):
            invalid()
        for spec in frame["specs"]:
            if (
                not isinstance(spec, dict)
                or set(spec) != {"op", "args", "branches"}
                or spec.get("op") != "trigger_move_basic_energy"
                or spec.get("branches") != {}
                or not isinstance(spec.get("args"), dict)
            ):
                invalid()
            args = spec["args"]
            if (
                set(args) != {
                    "from_player",
                    "from_slot",
                    "to_player",
                    "to_slot",
                    "source",
                    "select_source",
                    "optional",
                    "target_tool_id",
                }
                or type(args.get("from_player")) is not int
                or args["from_player"] != actor
                or args.get("from_slot") != from_slot
                or type(args.get("to_player")) is not int
                or args["to_player"] != actor
                or args.get("to_slot") != to_slot
                or not isinstance(args.get("source"), str)
                or args.get("select_source") is not True
                or args.get("optional") is not True
                or args.get("target_tool_id")
                    != formal["target_tool_id"]
            ):
                invalid()
            remaining_exp_share_triggers += 1

    return {
        "kind": "confirm_exp_share_trigger",
        "actor": actor,
        "attack_actor": finish_attack_actor,
        "from_player": actor,
        "from_slot": from_slot,
        "from_card_id": formal["from_card_id"],
        "to_player": actor,
        "to_slot": to_slot,
        "to_card_id": formal["to_card_id"],
        "target_tool_id": formal["target_tool_id"],
        "knockout_entries": knockout_entries,
        "remaining_exp_share_triggers":
            remaining_exp_share_triggers,
        "remaining_exp_share_requires_order":
            remaining_exp_share_triggers > 1,
    }


def _public_native_exp_share_order_continuation(
    wire_state: dict[str, Any],
    pending: dict[str, Any],
    actor: int,
) -> dict[str, Any] | None:
    """Rebuild an all-Exp.-Share trigger-order choice from public entities."""
    metadata = pending.get("metadata")
    formal = (
        metadata.get("continuation")
        if isinstance(metadata, dict)
        else None
    )
    if (
        not isinstance(formal, dict)
        or formal.get("kind") != "choose_trigger_order"
        or not isinstance(formal.get("specs"), list)
        or not formal["specs"]
        or any(
            not isinstance(spec, dict)
            or spec.get("op") != "trigger_move_basic_energy"
            for spec in formal["specs"]
        )
    ):
        return None

    def invalid() -> None:
        raise NativeBridgeError(
            "native_public_exp_share_order_continuation_invalid"
        )

    if (
        actor not in (0, 1)
        or pending.get("request_type") != "choose_trigger_order"
        or type(pending.get("player")) is not int
        or pending["player"] != actor
        or set(formal) != {
            "kind",
            "domain",
            "frame_id",
            "specs",
            "chooser",
            "_resume",
        }
        or formal.get("domain") != "trigger"
        or formal.get("frame_id") != "trigger:order"
        or formal.get("chooser") != actor
        or not 2 <= len(formal["specs"]) <= 8
    ):
        invalid()

    resume = formal.get("_resume")
    frames = resume.get("frames") if isinstance(resume, dict) else None
    if not isinstance(frames, list) or len(frames) != 2:
        invalid()

    players = wire_state.get("players")
    if (
        not isinstance(players, list)
        or len(players) != 2
        or not isinstance(players[actor], dict)
    ):
        invalid()
    owner = players[actor]
    active = owner.get("active")
    bench = owner.get("bench")
    if not isinstance(active, dict) or not isinstance(bench, list):
        invalid()

    trigger_specs: list[dict[str, Any]] = []
    shared: dict[str, Any] | None = None
    expected_args = {
        "from_player",
        "from_slot",
        "to_player",
        "to_slot",
        "source",
        "select_source",
        "optional",
        "target_tool_id",
    }
    for spec in formal["specs"]:
        args = spec.get("args")
        if (
            set(spec) != {"op", "args", "branches"}
            or spec.get("branches") != {}
            or not isinstance(args, dict)
            or set(args) != expected_args
            or args.get("from_player") != actor
            or args.get("from_slot") != "active"
            or args.get("to_player") != actor
            or not isinstance(args.get("to_slot"), str)
            or not args["to_slot"].startswith("bench_")
            or not args["to_slot"][6:].isdigit()
            or not 0 <= int(args["to_slot"][6:]) < 5
            or not isinstance(args.get("source"), str)
            or args.get("select_source") is not True
            or args.get("optional") is not True
            or not isinstance(args.get("target_tool_id"), str)
            or not args["target_tool_id"]
        ):
            invalid()
        bench_index = int(args["to_slot"][6:])
        target = bench[bench_index] if bench_index < len(bench) else None
        if not isinstance(target, dict):
            invalid()
        synthetic_resume = copy.deepcopy(resume)
        synthetic_resume["frames"] = copy.deepcopy(frames)
        synthetic = {
            "request_type": "confirm_trigger",
            "player": actor,
            "metadata": {
                "finish_attack_actor": metadata.get("finish_attack_actor"),
                "continuation": {
                    "kind": "confirm_exp_share_trigger",
                    "domain": "trigger",
                    "frame_id": (
                        f"trigger:exp_share:{actor}:active:"
                        f"{actor}:{args['to_slot']}"
                    ),
                    "from_player": actor,
                    "from_slot": "active",
                    "from_card_id": str(active.get("card_id", "")),
                    "to_player": actor,
                    "to_slot": args["to_slot"],
                    "to_card_id": str(target.get("card_id", "")),
                    "source_name": args["source"],
                    "target_tool_id": args["target_tool_id"],
                    "_resume": synthetic_resume,
                },
            },
        }
        try:
            rebuilt = _public_native_exp_share_continuation(
                wire_state,
                synthetic,
                actor,
            )
        except NativeBridgeError:
            invalid()
        if rebuilt is None:
            invalid()
        current_shared = {
            "attack_actor": rebuilt["attack_actor"],
            "knockout_entries": rebuilt["knockout_entries"],
        }
        if shared is None:
            shared = current_shared
        elif shared != current_shared:
            invalid()
        trigger_specs.append({
            key: rebuilt[key]
            for key in (
                "from_player",
                "from_slot",
                "from_card_id",
                "to_player",
                "to_slot",
                "to_card_id",
                "target_tool_id",
            )
        })
    if shared is None:
        invalid()
    return {
        "kind": "public_exp_share_spec_order",
        "actor": actor,
        "attack_actor": shared["attack_actor"],
        "exp_share_trigger_specs": trigger_specs,
        "knockout_entries": shared["knockout_entries"],
    }


def _public_native_bench_damage_continuation(
    wire_state: dict[str, Any],
    pending: dict[str, Any],
    actor: int,
) -> dict[str, Any] | None:
    """Rebuild an attack's public selected-bench-damage pause.

    The primary hit has already been committed by the reference engine when
    this post-hit effect suspends.  Only public board references and the
    already-serialized public reaction queue cross into the native kernel.
    """
    metadata = pending.get("metadata")
    formal = (
        metadata.get("continuation")
        if isinstance(metadata, dict)
        else None
    )
    if (
        not isinstance(formal, dict)
        or formal.get("kind") != "bench_damage_targets"
    ):
        return None

    def invalid() -> None:
        raise NativeBridgeError(
            "native_public_bench_damage_continuation_invalid"
        )

    finish_attack_actor = (
        metadata.get("finish_attack_actor")
        if isinstance(metadata, dict)
        else None
    )
    target_player = formal.get("target_player_idx")
    amount = formal.get("amount")
    count = formal.get("count")
    bench_indices = formal.get("bench_indices")
    if (
        actor not in (0, 1)
        or type(finish_attack_actor) is not int
        or finish_attack_actor != actor
        or type(pending.get("player")) is not int
        or pending["player"] != actor
        or pending.get("request_type") != "select_bench_targets"
        or set(formal) != {
            "kind",
            "target_player_idx",
            "amount",
            "count",
            "bench_indices",
            "_resume",
        }
        or type(target_player) is not int
        or target_player != 1 - actor
        or type(amount) is not int
        or not 0 < amount <= 1000
        or type(count) is not int
        or not 0 < count <= 5
        or not isinstance(bench_indices, list)
        or not count <= len(bench_indices) <= 5
        or any(
            type(index) is not int or not 0 <= index < 5
            for index in bench_indices
        )
        or len(set(bench_indices)) != len(bench_indices)
        or pending.get("min_select") != count
        or pending.get("max_select") != count
        or pending.get("allow_duplicates") is not False
        or pending.get("can_cancel") is not False
    ):
        invalid()

    players = wire_state.get("players")
    if (
        not isinstance(players, list)
        or len(players) != 2
        or any(not isinstance(player, dict) for player in players)
        or not isinstance(players[target_player].get("bench"), list)
    ):
        invalid()
    bench = players[target_player]["bench"]

    options = pending.get("options")
    safe_targets: list[dict[str, Any]] = []
    seen_options: set[str] = set()
    seen_indices: set[int] = set()
    if (
        not isinstance(options, list)
        or len(options) != len(bench_indices)
    ):
        invalid()
    for option in options:
        if (
            not isinstance(option, dict)
            or set(option) != {"option_id", "label", "ref", "value"}
            or not isinstance(option.get("option_id"), str)
            or not option["option_id"]
            or option["option_id"] in seen_options
            or not isinstance(option.get("label"), str)
            or not isinstance(option.get("ref"), dict)
            or type(option.get("value")) is not int
        ):
            invalid()
        option_id = option["option_id"]
        index = option["value"]
        ref = option["ref"]
        slot = f"bench_{index}"
        if (
            index not in bench_indices
            or index in seen_indices
            or set(ref) != {
                "kind",
                "player",
                "zone",
                "slot",
                "index",
                "attachment_type",
                "card_id",
            }
            or ref.get("kind") != "pokemon"
            or type(ref.get("player")) is not int
            or ref["player"] != target_player
            or ref.get("zone") != ""
            or ref.get("slot") != slot
            or ref.get("index") != -1
            or ref.get("attachment_type") != ""
            or not isinstance(ref.get("card_id"), str)
            or not ref["card_id"]
            or index >= len(bench)
            or not isinstance(bench[index], dict)
            or bench[index].get("card_id") != ref["card_id"]
        ):
            invalid()
        seen_options.add(option_id)
        seen_indices.add(index)
        safe_targets.append({
            "option_id": option_id,
            "target_slot": slot,
            "target_card_id": ref["card_id"],
        })
    if seen_indices != set(bench_indices):
        invalid()

    resume = formal.get("_resume")
    frames = resume.get("frames") if isinstance(resume, dict) else None
    context = (
        resume.get("context")
        if isinstance(resume, dict)
        else None
    )
    raw_trigger_specs = (
        context.get("pending_after_damage_trigger_specs")
        if isinstance(context, dict)
        else None
    )
    if (
        not isinstance(resume, dict)
        or set(resume) != {
            "version",
            "player_idx",
            "source_slot",
            "complete",
            "frames",
            "unsupported_frames",
            "context",
            "attack_failed",
        }
        or resume.get("version") != 1
        or resume.get("player_idx") != actor
        or not isinstance(resume.get("source_slot"), str)
        or not resume["source_slot"]
        or resume.get("complete") is not True
        or frames != [
            {"kind": "finalize_attack_turn", "actor": actor},
            {"kind": "finalize_attack_ko_checks"},
            {"kind": "finalize_after_damage_triggers"},
        ]
        or resume.get("unsupported_frames") != []
        or not isinstance(context, dict)
        or set(context) != {
            "attack_resolution",
            "pending_after_damage_trigger_specs",
        }
        or context.get("attack_resolution") != {
            "active": True,
            "player_idx": actor,
        }
        or not isinstance(raw_trigger_specs, list)
        or len(raw_trigger_specs) > 64
        or resume.get("attack_failed") is not False
        or wire_state.get("phase") != "ATTACK"
        or int(wire_state.get("active_player_idx", -1)) != actor
    ):
        invalid()

    def public_pokemon_card_id(player_idx: int, slot: str) -> str:
        owner = players[player_idx]
        target: Any = None
        if slot == "active":
            target = owner.get("active")
        elif slot.startswith("bench_") and slot[6:].isdigit():
            index = int(slot[6:])
            owner_bench = owner.get("bench")
            if (
                isinstance(owner_bench, list)
                and 0 <= index < len(owner_bench)
            ):
                target = owner_bench[index]
        return (
            str(target.get("card_id", ""))
            if isinstance(target, dict)
            else ""
        )

    grouped: dict[int, list[dict[str, Any]]] = {actor: [], 1 - actor: []}
    for spec in raw_trigger_specs:
        if (
            not isinstance(spec, dict)
            or set(spec) != {"op", "args", "branches"}
            or spec.get("branches") != {}
            or not isinstance(spec.get("args"), dict)
        ):
            invalid()
        op = spec.get("op")
        args = spec["args"]
        if op == "trigger_draw_cards":
            if (
                set(args) != {"player", "amount", "source"}
                or type(args.get("player")) is not int
                or args["player"] not in (0, 1)
                or type(args.get("amount")) is not int
                or not 0 < args["amount"] <= 64
                or not isinstance(args.get("source"), str)
            ):
                invalid()
            owner = args["player"]
            safe_spec = {
                "op": op,
                "args": {
                    "player": owner,
                    "amount": args["amount"],
                },
            }
        elif op == "trigger_place_damage_counters":
            target_ref = args.get("target_ref")
            if (
                set(args) != {
                    "player",
                    "slot",
                    "count",
                    "source",
                    "target_ref",
                }
                or type(args.get("player")) is not int
                or args["player"] not in (0, 1)
                or not isinstance(args.get("slot"), str)
                or not args["slot"]
                or type(args.get("count")) is not int
                or not 0 < args["count"] <= 100
                or not isinstance(args.get("source"), str)
                or not isinstance(target_ref, dict)
                or set(target_ref)
                    != {"kind", "player", "slot", "card_id"}
                or target_ref.get("kind") != "pokemon"
                or target_ref.get("player") != args["player"]
                or target_ref.get("slot") != args["slot"]
                or not isinstance(target_ref.get("card_id"), str)
                or not target_ref["card_id"]
                or public_pokemon_card_id(
                    args["player"],
                    args["slot"],
                ) != target_ref["card_id"]
            ):
                invalid()
            owner = args["player"]
            safe_spec = {
                "op": op,
                "args": {
                    "player": owner,
                    "slot": args["slot"],
                    "count": args["count"],
                    "target_card_id": target_ref["card_id"],
                },
            }
        else:
            # Unsupported reaction types stay on the reference side rather
            # than crossing an incomplete or hidden continuation.
            return None
        grouped[owner].append(safe_spec)

    trigger_groups = [
        {"owner": owner, "specs": grouped[owner]}
        for owner in (actor, 1 - actor)
        if grouped[owner]
    ]
    return {
        "kind": "public_bench_damage_targets",
        "actor": actor,
        "attack_actor": actor,
        "target_player": target_player,
        "amount": amount,
        "count": count,
        "allowed_targets": safe_targets,
        "trigger_groups": trigger_groups,
    }


def _public_native_trigger_continuation(
    wire_state: dict[str, Any],
    pending: dict[str, Any],
    actor: int,
) -> dict[str, Any] | None:
    """Rebuild a fully public after-damage trigger-order stack.

    A native determinization can legitimately observe a different number of
    reactive effects.  Only draw and fixed public damage-counter triggers are
    translated here.  Presentation labels are discarded, and a target card
    identity is accepted only after it is matched against the public in-play
    entity at the declared slot.
    """
    metadata = pending.get("metadata")
    formal = (
        metadata.get("continuation")
        if isinstance(metadata, dict)
        else None
    )
    if (
        not isinstance(formal, dict)
        or formal.get("kind") != "choose_trigger_order"
    ):
        return None

    def invalid() -> None:
        raise NativeBridgeError(
            "native_public_trigger_continuation_invalid"
        )

    allowed_formal_keys = {
        "kind",
        "domain",
        "frame_id",
        "specs",
        "chooser",
        "_resume",
    }
    if (
        actor not in (0, 1)
        or type(pending.get("player")) is not int
        or pending["player"] != actor
        or str(pending.get("request_type", ""))
            != "choose_trigger_order"
        or set(formal) != allowed_formal_keys
        or formal.get("domain") != "trigger"
        or formal.get("frame_id") != "trigger:order"
        or type(formal.get("chooser")) is not int
        or formal["chooser"] != actor
    ):
        invalid()

    players = wire_state.get("players")
    if (
        not isinstance(players, list)
        or len(players) != 2
        or any(not isinstance(player, dict) for player in players)
    ):
        invalid()

    def public_pokemon_card_id(player_idx: int, slot: str) -> str:
        owner = players[player_idx]
        target: Any = None
        if slot == "active":
            target = owner.get("active")
        elif slot.startswith("bench_"):
            try:
                bench_index = int(slot[6:])
            except ValueError:
                return ""
            bench = owner.get("bench")
            if (
                not isinstance(bench, list)
                or bench_index < 0
                or bench_index >= len(bench)
            ):
                return ""
            target = bench[bench_index]
        return (
            str(target.get("card_id", ""))
            if isinstance(target, dict)
            else ""
        )

    unsupported = object()

    def sanitize_specs(
        raw_specs: Any,
        expected_owner: int | None,
    ) -> tuple[int, list[dict[str, Any]]] | object:
        if (
            not isinstance(raw_specs, list)
            or not raw_specs
            or len(raw_specs) > 64
        ):
            invalid()
        owner = expected_owner
        sanitized: list[dict[str, Any]] = []
        for spec in raw_specs:
            if (
                not isinstance(spec, dict)
                or set(spec) != {"op", "args", "branches"}
                or spec.get("branches") != {}
                or not isinstance(spec.get("args"), dict)
            ):
                invalid()
            op = spec.get("op")
            args = spec["args"]
            if op == "trigger_draw_cards":
                if (
                    set(args) != {"player", "amount", "source"}
                    or type(args.get("player")) is not int
                    or args["player"] not in (0, 1)
                    or type(args.get("amount")) is not int
                    or not 0 < args["amount"] <= 64
                    or not isinstance(args.get("source"), str)
                ):
                    invalid()
                spec_owner = args["player"]
                safe_args = {
                    "player": spec_owner,
                    "amount": args["amount"],
                }
            elif op == "trigger_place_damage_counters":
                if (
                    set(args) != {
                        "player",
                        "slot",
                        "count",
                        "source",
                        "target_ref",
                    }
                    or type(args.get("player")) is not int
                    or args["player"] not in (0, 1)
                    or not isinstance(args.get("slot"), str)
                    or not args["slot"]
                    or type(args.get("count")) is not int
                    or not 0 < args["count"] <= 100
                    or not isinstance(args.get("source"), str)
                    or not isinstance(args.get("target_ref"), dict)
                ):
                    invalid()
                target_ref = args["target_ref"]
                if (
                    set(target_ref)
                        != {"kind", "player", "slot", "card_id"}
                    or target_ref.get("kind") != "pokemon"
                    or type(target_ref.get("player")) is not int
                    or target_ref["player"] != args["player"]
                    or target_ref.get("slot") != args["slot"]
                    or not isinstance(target_ref.get("card_id"), str)
                    or not target_ref["card_id"]
                    or public_pokemon_card_id(
                        args["player"],
                        args["slot"],
                    ) != target_ref["card_id"]
                ):
                    invalid()
                spec_owner = args["player"]
                safe_args = {
                    "player": spec_owner,
                    "slot": args["slot"],
                    "count": args["count"],
                    "target_card_id": target_ref["card_id"],
                }
            else:
                # Unsupported trigger kinds are not copied.  A matching
                # native continuation may still be used; otherwise the caller
                # fails closed with continuation_unavailable.
                return unsupported
            if owner is None:
                owner = spec_owner
            if spec_owner != owner:
                invalid()
            sanitized.append({"op": op, "args": safe_args})
        if owner not in (0, 1):
            invalid()
        return int(owner), sanitized

    current = sanitize_specs(formal.get("specs"), actor)
    if current is unsupported:
        return None
    current_owner, current_specs = current
    if len(current_specs) < 2:
        invalid()

    resume = formal.get("_resume")
    expected_resume_keys = {
        "version",
        "player_idx",
        "source_slot",
        "complete",
        "frames",
        "unsupported_frames",
        "context",
        "attack_failed",
    }
    finish_attack_actor = (
        metadata.get("finish_attack_actor")
        if isinstance(metadata, dict)
        else None
    )
    frames = resume.get("frames") if isinstance(resume, dict) else None
    expected_context = {
        "attack_resolution": {
            "active": True,
            "player_idx": finish_attack_actor,
        },
    }
    if (
        type(finish_attack_actor) is not int
        or finish_attack_actor not in (0, 1)
        or not isinstance(resume, dict)
        or set(resume) != expected_resume_keys
        or type(resume.get("version")) is not int
        or resume["version"] != 1
        or type(resume.get("player_idx")) is not int
        or resume["player_idx"] != finish_attack_actor
        or not isinstance(resume.get("source_slot"), str)
        or not resume["source_slot"]
        or resume.get("complete") is not True
        or not isinstance(frames, list)
        or len(frames) < 2
        or frames[0] != {
            "kind": "finalize_attack_turn",
            "actor": finish_attack_actor,
        }
        or frames[1] != {"kind": "finalize_attack_ko_checks"}
        or resume.get("unsupported_frames") != []
        or resume.get("context") != expected_context
        or resume.get("attack_failed") is not False
        or str(wire_state.get("phase", "")) != "ATTACK"
        or int(wire_state.get("active_player_idx", -1))
            != finish_attack_actor
    ):
        invalid()

    remaining_trigger_groups: list[dict[str, Any]] = []
    for frame in reversed(frames[2:]):
        if (
            not isinstance(frame, dict)
            or set(frame) != {"kind", "specs"}
            or frame.get("kind") != "trigger_order"
        ):
            invalid()
        group = sanitize_specs(frame.get("specs"), None)
        if group is unsupported:
            return None
        group_owner, group_specs = group
        remaining_trigger_groups.append({
            "owner": group_owner,
            "specs": group_specs,
        })

    # The formal state is already past primary damage and has materialized the
    # complete reaction queue.  Mark those phases consumed so the native
    # kernel executes only the selected draw triggers, KO settlement and the
    # normal end-of-attack transition.
    attack_context = {
        "damage_applied": True,
        "after_damage_triggers_applied": True,
        "reactive_thorns_applied": True,
    }
    return {
        "kind": "public_trigger_order",
        "actor": actor,
        "attack_actor": finish_attack_actor,
        "trigger_owner": current_owner,
        "trigger_specs": current_specs,
        "remaining_trigger_groups": remaining_trigger_groups,
        "attack_context": attack_context,
    }


class NativeSearchService:
    """Thread-safe native PUCT service sharing one GPU inference broker."""

    def __init__(
        self,
        model: Any,
        *,
        device: str,
        target_batch_size: int,
        max_batch_size: int,
        coalesce_ms: float,
        repo_root: Path | None = None,
        simulation_limiter: Any | None = None,
        max_inflight_leaves: int = 8,
    ) -> None:
        if not native_training_bridge_available():
            raise NativeBridgeError("ptcg_ai_core_training_bridge_unavailable")
        import ptcg_ai_core  # type: ignore

        self.native = ptcg_ai_core
        self.repo_root = repo_root or Path(__file__).resolve().parents[4]
        self.cards = json.loads(
            (self.repo_root / "godot" / "data" / "cards.json").read_text(
                encoding="utf-8"
            )
        )
        self.decks = json.loads(
            (self.repo_root / "godot" / "data" / "decks.json").read_text(
                encoding="utf-8"
            )
        )
        self.batch = ptcg_ai_core.NativeSelfPlayBatch()
        self.game = ptcg_ai_core.NativeGameKernel(self.cards)
        self.broker = NativeBatchTorchBroker(
            self.batch,
            model,
            device=device,
            target_batch_size=target_batch_size,
            max_batch_size=max_batch_size,
            poll_wait_ms=max(1, int(round(coalesce_ms))),
            amp=True,
        )
        self._closed = False
        self._active = 0
        self._lock = threading.Lock()
        self._simulation_limiter = simulation_limiter
        self._max_inflight_leaves = max(1, int(max_inflight_leaves))
        self._choice_contexts: dict[int, dict[str, Any]] = {}
        self.search_decisions = 0
        self.search_simulations = 0
        self.search_tree_nodes = 0
        self.search_chance_nodes = 0
        self.search_chance_edges = 0
        self.search_determinization_microseconds = 0
        self.search_projection_microseconds = 0
        self.search_candidate_generation_microseconds = 0
        self.search_apply_microseconds = 0
        self.search_encoding_microseconds = 0
        self.search_inference_wait_microseconds = 0
        self.search_max_pending_leaves = 0
        self.search_candidate_cache_hits = 0
        self.search_candidate_cache_misses = 0

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            if self._active:
                raise NativeBridgeError("native_search_closed_with_active_jobs")
            self._closed = True
            self._choice_contexts.clear()
        self.broker.close()
        self.batch.close()

    def __enter__(self) -> "NativeSearchService":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def search_action(
        self,
        state: Any,
        actor: int,
        candidates: Sequence[SearchCandidate],
        *,
        simulations: int,
        c_puct: float,
        seed: int,
        training: bool,
        temperature: float,
        max_depth: int = 128,
    ) -> SearchResult:
        if not candidates or any(
            isinstance(candidate.payload, ChoiceResponse)
            for candidate in candidates
        ):
            raise NativeBridgeError("native_action_root_required")
        with self._lock:
            if self._closed:
                raise NativeBridgeError("native_search_service_closed")
            self._active += 1
        started = time.perf_counter()
        try:
            wire = mask_native_snapshot(
                game_state_to_native_wire(state),
                actor,
            )
            boundary_error = str(
                self.native.validate_runtime_snapshot(wire, actor)
            )
            if boundary_error:
                raise NativeBridgeError(
                    "native_hidden_information_violation:"
                    + boundary_error
                )
            # Effect legality can depend on the remaining deck multiset.  The
            # ABI snapshot stays masked; a native determinization reconstructs
            # one compatible world from the public deck route before the legal
            # set is compared.
            legal_world = self.native.NativeDeterminizer(
                self.decks
            ).determinize(
                wire,
                actor,
                (
                    (int(seed) & 0xFFFFFFFF)
                    ^ (0x9E3779B9 * 1)
                ) & 0xFFFFFFFF,
            )
            native_actions = list(self.game.legal_actions(legal_world, actor))
            formal_by_key: dict[tuple[Any, ...], SearchCandidate] = {}
            for candidate in candidates:
                if not isinstance(candidate.payload, GameAction):
                    raise NativeBridgeError("invalid_formal_action_candidate")
                key = _formal_action_key(candidate.payload)
                if key in formal_by_key:
                    raise NativeBridgeError(
                        "duplicate_formal_action_candidate"
                    )
                formal_by_key[key] = candidate
            native_by_key: dict[tuple[Any, ...], dict[str, Any]] = {}
            for action in native_actions:
                key = _native_action_key(action)
                if key in native_by_key:
                    raise NativeBridgeError(
                        "duplicate_native_action_candidate"
                    )
                native_by_key[key] = action
            missing_keys = formal_by_key.keys() - native_by_key.keys()
            if missing_keys:
                missing = sorted(
                    repr((key, formal_by_key[key].payload))
                    for key in missing_keys
                )
                raise NativeBridgeError(
                    "native_legal_action_set_mismatch:"
                    f"missing={missing}:extra=[]"
                )
            # Hidden deck/prize allocation can make a sampled world expose
            # additional search-dependent actions.  The authoritative formal
            # rules set is the root allowlist; deeper nodes remain entirely
            # native.  Only public action descriptors cross this boundary.
            wire["_native_root_allowed_actions"] = [
                copy.deepcopy(native_by_key[key])
                for key in formal_by_key
            ]

            job = self.native.NativeSearchJob(
                self.cards,
                self.decks,
                self.batch,
                self._simulation_limiter,
            )
            job.start(
                wire,
                actor,
                int(seed) & 0xFFFFFFFF,
                {
                    "simulations": max(1, int(simulations)),
                    "max_depth": max(1, int(max_depth)),
                    "c_puct": float(c_puct),
                    "dirichlet_epsilon": 0.25 if training else 0.0,
                    "temperature": max(0.0, float(temperature)),
                    "training": bool(training),
                    "inference_wait_milliseconds": 25,
                    "max_inflight_leaves": min(
                        max(1, int(simulations)),
                        self._max_inflight_leaves,
                    ),
                },
            )
            result = job.wait()
            if not bool(result.get("success", False)):
                raise NativeBridgeError(
                    "native_search_failed:"
                    + str(result.get("error", "unknown"))
                )
            result_rows = list(result.get("candidates", []))
            probabilities_raw = list(result.get("probabilities", []))
            visits_raw = list(result.get("visits", []))
            if not (
                len(result_rows)
                == len(probabilities_raw)
                == len(visits_raw)
                == len(candidates)
            ):
                raise NativeBridgeError("native_root_result_shape_mismatch")
            probabilities: dict[str, float] = {}
            visits: dict[str, int] = {}
            for row, probability, visit_count in zip(
                result_rows,
                probabilities_raw,
                visits_raw,
                strict=True,
            ):
                formal = formal_by_key.get(_native_action_key(row))
                if formal is None or formal.signature in probabilities:
                    raise NativeBridgeError(
                        "native_root_result_candidate_mismatch"
                    )
                probabilities[formal.signature] = float(probability)
                visits[formal.signature] = int(visit_count)
            selected = formal_by_key.get(
                _native_action_key(dict(result.get("selected", {})))
            )
            if selected is None:
                raise NativeBridgeError(
                    "native_selected_action_is_not_authoritative"
                )
            self._record_search_metrics(result)
            self._remember_next_choice(state, result)
            return SearchResult(
                selected=selected,
                visits=visits,
                probabilities=probabilities,
                root_value=float(result.get("root_value", 0.0)),
                simulations=int(result.get("simulations", 0)),
                elapsed_seconds=time.perf_counter() - started,
                degraded_deadline=False,
            )
        finally:
            with self._lock:
                self._active -= 1

    def search_choice(
        self,
        state: Any,
        actor: int,
        candidates: Sequence[SearchCandidate],
        *,
        simulations: int,
        c_puct: float,
        seed: int,
        training: bool,
        temperature: float,
        max_depth: int = 128,
    ) -> SearchResult:
        if not candidates or any(
            not isinstance(candidate.payload, ChoiceResponse)
            for candidate in candidates
        ):
            raise NativeBridgeError("native_choice_root_required")
        if len(candidates) == 1:
            # The native rules kernel auto-resolves forced choices.  The
            # authoritative Python engine can still expose that transition
            # as a one-candidate request, so no native continuation remains
            # to search.  Crossing this forced boundary is deterministic and
            # must not consume PUCT simulations.  Keep any cached next choice:
            # the native kernel auto-resolves forced requests while the formal
            # engine still exposes them, so that cache may already describe the
            # first non-forced request beyond this boundary.  It is validated
            # against that later request before reuse below.
            forced = candidates[0]
            return SearchResult(
                selected=forced,
                visits={forced.signature: 1},
                probabilities={forced.signature: 1.0},
                root_value=0.0,
                simulations=0,
                elapsed_seconds=0.0,
                degraded_deadline=False,
            )
        with self._lock:
            if self._closed:
                raise NativeBridgeError("native_search_service_closed")
            cached = self._choice_contexts.get(id(state))
            continuation = (
                copy.deepcopy(cached["continuation"])
                if (
                    cached is not None
                    and cached.get("state") is state
                )
                else None
            )
            self._active += 1
        started = time.perf_counter()
        try:
            full_wire = game_state_to_native_wire(state)
            stack = full_wire.get("resolution_stack")
            pending = (
                stack.get("pending_request")
                if isinstance(stack, dict)
                else None
            )
            native_pending = _native_choice_view(
                pending,
                candidates,
                actor,
            )
            cached_pending = (
                cached.get("pending")
                if isinstance(cached, dict)
                else None
            )
            cached_continuation_kind = (
                str(continuation.get("kind", ""))
                if isinstance(continuation, dict)
                else ""
            )
            public_prize_continuation = (
                _public_native_prize_continuation(
                    full_wire,
                    pending,
                    actor,
                )
            )
            if public_prize_continuation is not None:
                continuation = public_prize_continuation
            public_exp_share_continuation = (
                _public_native_exp_share_continuation(
                    full_wire,
                    pending,
                    actor,
                )
            )
            if public_exp_share_continuation is not None:
                continuation = public_exp_share_continuation
            public_exp_share_order_continuation = (
                _public_native_exp_share_order_continuation(
                    full_wire,
                    pending,
                    actor,
                )
            )
            if public_exp_share_order_continuation is not None:
                continuation = public_exp_share_order_continuation
            public_bench_damage_continuation = (
                _public_native_bench_damage_continuation(
                    full_wire,
                    pending,
                    actor,
                )
            )
            if public_bench_damage_continuation is not None:
                # The primary hit is already committed in the formal state.
                # Rebuild this post-hit target choice from public references
                # instead of trusting a determinization-specific VM cache.
                continuation = public_bench_damage_continuation
            public_trigger_continuation = (
                _public_native_trigger_continuation(
                    full_wire,
                    pending,
                    actor,
                )
            )
            if public_trigger_continuation is not None:
                # Trigger multiplicity can differ between determinizations.
                # The authoritative public queue therefore takes precedence
                # over a cached native continuation from a sampled world.
                continuation = public_trigger_continuation
            formal_continuation = (
                (
                    pending.get("metadata", {}).get("continuation")
                    if isinstance(pending, dict)
                    and isinstance(pending.get("metadata"), dict)
                    else None
                )
            )
            formal_kind = (
                str(formal_continuation.get("kind", ""))
                if isinstance(formal_continuation, dict)
                else ""
            )
            if (
                continuation is None
                or formal_kind in {
                    "attach_energy_to_board",
                    "discard_hand_then_draw",
                    "draw_and_attach_energy_distribution",
                    "energy_attach_distribution",
                    "look_top_attach_energy",
                    "search_cards",
                    "search_item_and_tool",
                }
            ):
                public_vm_continuation = _public_native_vm_continuation(
                        full_wire,
                        pending,
                        actor,
                        self.cards,
                    )
                if public_vm_continuation is not None:
                    # Detached drawn-card and revealed attack deck-top
                    # choices are fixed by the formal actor observation, not
                    # by a sampled native determinization.
                    continuation = public_vm_continuation
                    if (
                        formal_kind == "energy_attach_distribution"
                        and formal_continuation.get("source_zone")
                            == "deck"
                    ):
                        visible = native_pending["metadata"][
                            "continuation"
                        ]
                        visible["revealed_source_zone"] = "deck"
                        visible["revealed_source_card_ids"] = list(
                            pending["metadata"]["card_ids"]
                        )
            if continuation is None:
                error = NativeBridgeError(
                    "native_choice_continuation_unavailable"
                )
                # Keep diagnostics free of option/card identities.  The
                # request and continuation kinds are public protocol tags and
                # are sufficient to route a missing reconstruction handler.
                error.add_note(
                    "native_choice_context:"
                    f"actor={int(actor)}:"
                    f"request_type={str(pending.get('request_type', '')) if isinstance(pending, dict) else ''}:"
                    f"continuation_kind={formal_kind or 'none'}"
                )
                formal_specs = (
                    formal_continuation.get("specs")
                    if isinstance(formal_continuation, dict)
                    else None
                )
                trigger_ops = sorted({
                    str(spec.get("op", ""))
                    for spec in formal_specs
                    if isinstance(spec, dict) and spec.get("op")
                }) if isinstance(formal_specs, list) else []
                error.add_note(
                    "native_choice_cache_context:"
                    f"cached_request_type={str(cached_pending.get('request_type', '')) if isinstance(cached_pending, dict) else 'none'}:"
                    f"cached_continuation_kind={cached_continuation_kind or 'none'}:"
                    f"trigger_ops={','.join(trigger_ops) or 'none'}"
                )
                raise error
            if isinstance(stack, dict):
                full_wire["resolution_stack"] = {
                    "schema_version": int(
                        stack.get("schema_version", 3)
                    ),
                    "frames": [],
                    "pending_request": None,
                    "sequence": int(stack.get("sequence", 0)),
                    "context": {},
                }
            wire = mask_native_snapshot(full_wire, actor)
            boundary_error = str(
                self.native.validate_runtime_snapshot(wire, actor)
            )
            if boundary_error:
                raise NativeBridgeError(
                    "native_hidden_information_violation:"
                    + boundary_error
                )

            formal_by_key: dict[
                tuple[str, tuple[str, ...], bool],
                SearchCandidate,
            ] = {}
            for candidate in candidates:
                key = _formal_choice_key(candidate.payload)
                if key in formal_by_key:
                    raise NativeBridgeError(
                        "duplicate_formal_choice_candidate"
                    )
                formal_by_key[key] = candidate
            native_rows = list(
                self.game.choice_candidates(native_pending)
            )
            native_by_key: dict[
                tuple[str, tuple[str, ...], bool],
                dict[str, Any],
            ] = {}
            for row in native_rows:
                key = _native_choice_key(row)
                if key in native_by_key:
                    raise NativeBridgeError(
                        "duplicate_native_choice_candidate"
                    )
                native_by_key[key] = row
            if formal_by_key.keys() != native_by_key.keys():
                raise NativeBridgeError(
                    "native_legal_choice_set_mismatch"
                )

            job = self.native.NativeSearchJob(
                self.cards,
                self.decks,
                self.batch,
                self._simulation_limiter,
            )
            job.start_choice(
                wire,
                actor,
                native_pending,
                continuation,
                int(seed) & 0xFFFFFFFF,
                {
                    "simulations": max(1, int(simulations)),
                    "max_depth": max(1, int(max_depth)),
                    "c_puct": float(c_puct),
                    "dirichlet_epsilon": 0.25 if training else 0.0,
                    "temperature": max(0.0, float(temperature)),
                    "training": bool(training),
                    "inference_wait_milliseconds": 25,
                    "max_inflight_leaves": min(
                        max(1, int(simulations)),
                        self._max_inflight_leaves,
                    ),
                },
            )
            result = job.wait()
            if not bool(result.get("success", False)):
                error = NativeBridgeError(
                    "native_choice_search_failed:"
                    + str(result.get("error", "unknown"))
                )
                formal_specs = (
                    formal_continuation.get("specs")
                    if isinstance(formal_continuation, dict)
                    else None
                )
                trigger_ops = sorted({
                    str(spec.get("op", ""))
                    for spec in formal_specs
                    if isinstance(spec, dict) and spec.get("op")
                }) if isinstance(formal_specs, list) else []
                error.add_note(
                    "native_choice_search_context:"
                    f"request_type={str(pending.get('request_type', '')) if isinstance(pending, dict) else ''}:"
                    f"formal_kind={formal_kind or 'none'}:"
                    f"cached_request_type={str(cached_pending.get('request_type', '')) if isinstance(cached_pending, dict) else 'none'}:"
                    f"cached_continuation_kind={cached_continuation_kind or 'none'}:"
                    f"public_trigger_rebuilt={public_trigger_continuation is not None}:"
                    f"trigger_ops={','.join(trigger_ops) or 'none'}"
                )
                raise error
            result_rows = list(result.get("candidates", []))
            probabilities_raw = list(result.get("probabilities", []))
            visits_raw = list(result.get("visits", []))
            if not (
                len(result_rows)
                == len(probabilities_raw)
                == len(visits_raw)
                == len(candidates)
            ):
                raise NativeBridgeError(
                    "native_choice_result_shape_mismatch:"
                    f"candidates={len(candidates)}:"
                    f"rows={len(result_rows)}:"
                    f"probabilities={len(probabilities_raw)}:"
                    f"visits={len(visits_raw)}"
                )
            probabilities: dict[str, float] = {}
            visits: dict[str, int] = {}
            for row, probability, visit_count in zip(
                result_rows,
                probabilities_raw,
                visits_raw,
                strict=True,
            ):
                formal = formal_by_key.get(_native_choice_key(row))
                if formal is None or formal.signature in probabilities:
                    raise NativeBridgeError(
                        "native_choice_result_candidate_mismatch"
                    )
                probabilities[formal.signature] = float(probability)
                visits[formal.signature] = int(visit_count)
            selected = formal_by_key.get(
                _native_choice_key(
                    dict(result.get("selected", {}))
                )
            )
            if selected is None:
                raise NativeBridgeError(
                    "native_selected_choice_is_not_authoritative"
                )
            self._record_search_metrics(result)
            self._remember_next_choice(state, result)
            return SearchResult(
                selected=selected,
                visits=visits,
                probabilities=probabilities,
                root_value=float(result.get("root_value", 0.0)),
                simulations=int(result.get("simulations", 0)),
                elapsed_seconds=time.perf_counter() - started,
                degraded_deadline=False,
            )
        finally:
            with self._lock:
                self._active -= 1

    def _remember_next_choice(
        self,
        state: Any,
        result: dict[str, Any],
    ) -> None:
        pending = result.get("next_pending")
        continuation = result.get("next_continuation")
        with self._lock:
            if (
                isinstance(pending, dict)
                and pending
                and isinstance(continuation, dict)
                and continuation
            ):
                self._choice_contexts[id(state)] = {
                    "state": state,
                    "pending": copy.deepcopy(pending),
                    "continuation": copy.deepcopy(continuation),
                }
            else:
                self._choice_contexts.pop(id(state), None)

    def _record_search_metrics(self, result: dict[str, Any]) -> None:
        with self._lock:
            self.search_decisions += 1
            self.search_simulations += int(
                result.get("simulations", 0)
            )
            self.search_tree_nodes += int(
                result.get("tree_nodes", 0)
            )
            self.search_chance_nodes += int(
                result.get("chance_nodes", 0)
            )
            self.search_chance_edges += int(
                result.get("chance_edges", 0)
            )
            self.search_determinization_microseconds += int(
                result.get("determinization_microseconds", 0)
            )
            self.search_projection_microseconds += int(
                result.get("projection_microseconds", 0)
            )
            self.search_candidate_generation_microseconds += int(
                result.get("candidate_generation_microseconds", 0)
            )
            self.search_apply_microseconds += int(
                result.get("apply_microseconds", 0)
            )
            self.search_encoding_microseconds += int(
                result.get("encoding_microseconds", 0)
            )
            self.search_inference_wait_microseconds += int(
                result.get("inference_wait_microseconds", 0)
            )
            self.search_max_pending_leaves = max(
                self.search_max_pending_leaves,
                int(result.get("max_pending_leaves", 0)),
            )
            self.search_candidate_cache_hits += int(
                result.get("candidate_cache_hits", 0)
            )
            self.search_candidate_cache_misses += int(
                result.get("candidate_cache_misses", 0)
            )


class NativeModelBackend:
    """Native action/choice search with a shared GPU inference broker."""

    def __init__(
        self,
        model: Any,
        *,
        device: str,
        target_batch_size: int,
        max_batch_size: int,
        coalesce_ms: float,
        simulation_limiter: Any | None = None,
        max_inflight_leaves: int = 8,
    ) -> None:
        self.native_search = NativeSearchService(
            model,
            device=device,
            target_batch_size=target_batch_size,
            max_batch_size=max_batch_size,
            coalesce_ms=coalesce_ms,
            simulation_limiter=simulation_limiter,
            max_inflight_leaves=max_inflight_leaves,
        )

    def evaluate(self, *args: Any, **kwargs: Any):
        raise NativeBridgeError("native_direct_evaluation_unavailable")

    def search_action(self, *args: Any, **kwargs: Any) -> SearchResult:
        return self.native_search.search_action(*args, **kwargs)

    def search_choice(self, *args: Any, **kwargs: Any) -> SearchResult:
        return self.native_search.search_choice(*args, **kwargs)

    def close(self) -> None:
        self.native_search.close()

    def __enter__(self) -> "NativeModelBackend":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    @property
    def native_metrics(self) -> dict[str, float | int]:
        broker = self.native_search.broker
        limiter = self.native_search._simulation_limiter
        return {
            "inference_batches": int(broker.batch_count),
            "inference_requests": int(broker.request_count),
            "max_inference_batch": int(broker.max_observed_batch),
            "max_inference_queue": int(broker.max_queue_depth),
            "inference_seconds": float(broker.total_inference_seconds),
            "search_decisions": int(
                self.native_search.search_decisions
            ),
            "search_simulations": int(
                self.native_search.search_simulations
            ),
            "search_tree_nodes": int(
                self.native_search.search_tree_nodes
            ),
            "search_chance_nodes": int(
                self.native_search.search_chance_nodes
            ),
            "search_chance_edges": int(
                self.native_search.search_chance_edges
            ),
            "search_determinization_microseconds": int(
                self.native_search.search_determinization_microseconds
            ),
            "search_projection_microseconds": int(
                self.native_search.search_projection_microseconds
            ),
            "search_candidate_generation_microseconds": int(
                self.native_search.search_candidate_generation_microseconds
            ),
            "search_apply_microseconds": int(
                self.native_search.search_apply_microseconds
            ),
            "search_encoding_microseconds": int(
                self.native_search.search_encoding_microseconds
            ),
            "search_inference_wait_microseconds": int(
                self.native_search.search_inference_wait_microseconds
            ),
            "search_max_pending_leaves": int(
                self.native_search.search_max_pending_leaves
            ),
            "search_candidate_cache_hits": int(
                self.native_search.search_candidate_cache_hits
            ),
            "search_candidate_cache_misses": int(
                self.native_search.search_candidate_cache_misses
            ),
            "simulation_thread_capacity": (
                int(limiter.capacity) if limiter is not None else 0
            ),
            "max_active_simulations": (
                int(limiter.max_active) if limiter is not None else 0
            ),
        }

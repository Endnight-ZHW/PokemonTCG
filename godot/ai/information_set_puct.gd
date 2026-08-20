class_name InformationSetPUCT
extends RefCounted

## Godot adapter for the native information-set PUCT implementation.

const PLANNER_ID := "infoset_puct_v2"
const SCHEMA_VERSION := 2
const C_PUCT := 1.4
const WATCHDOG_USEC := 2000000
const STOP_MARGIN_USEC := 50000
const WINDOWS_MIN_SIMULATIONS := 32
const WINDOWS_TARGET_SIMULATIONS := 128
const WINDOWS_MAX_SIMULATIONS := 256
const WINDOWS_LEAF_BATCH_SIZE := 8
const ANDROID_MIN_SIMULATIONS := 16
const ANDROID_TARGET_SIMULATIONS := 64
const ANDROID_MAX_SIMULATIONS := 128
const ANDROID_LEAF_BATCH_SIZE := 4

var _native: Variant


func _init() -> void:
	if ClassDB.class_exists("NativeDeepSearch"):
		_native = ClassDB.instantiate("NativeDeepSearch")
		var catalog := CardCatalog.shared()
		_native.call("set_catalog", catalog.cards)
		_native.call("set_decks", catalog.decks)


func decide(
	request: Dictionary,
	cancel_check: Callable,
	inference: Variant,
) -> Dictionary:
	if _native == null:
		return {
			"success": false,
			"cancelled": false,
			"error": "native_search_extension_unavailable",
			"deep_failure_reason": "native_search_extension_unavailable",
			"planner": PLANNER_ID,
			"request_id": str(request.get("request_id", "")),
			"revision": int(request.get("revision", -1)),
			"elapsed_ms": 0.0,
			"simulations": 0,
			"degraded_deadline": false,
		}
	var result := Dictionary(_native.call(
		"decide",
		request,
		cancel_check,
		inference,
	))
	if not bool(result.get("success", false)):
		return result
	if str(request.get("kind", "action")) == "choice":
		var choice_value: Variant = request.get("choice", {})
		var selected_value: Variant = result.get("selected_options", [])
		if not choice_value is Dictionary or not selected_value is Array:
			result["success"] = false
			result["error"] = "native_choice_selection_missing"
			result["deep_failure_reason"] = result["error"]
			return result
		var choice: Dictionary = choice_value
		var request_id := str(choice.get("request_id", ""))
		if (
			request_id.is_empty()
			or str(result.get("choice_request_id", "")) != request_id
		):
			result["success"] = false
			result["error"] = "native_choice_request_mismatch"
			result["deep_failure_reason"] = result["error"]
			return result
		var public_option_ids: Dictionary = {}
		for option_value in choice.get("options", []):
			if not option_value is Dictionary:
				continue
			var option_id := str(Dictionary(option_value).get("option_id", ""))
			if not option_id.is_empty():
				public_option_ids[option_id] = true
		var selected_ids: Array[String] = []
		for option_id_value in selected_value:
			var option_id := str(option_id_value)
			if not public_option_ids.has(option_id):
				result["success"] = false
				result["error"] = "native_choice_not_in_public_option_set"
				result["deep_failure_reason"] = result["error"]
				return result
			selected_ids.append(option_id)
		var cancelled := bool(result.get("choice_cancelled", false))
		if (
			(cancelled and not bool(choice.get("can_cancel", false)))
			or (
				not cancelled
				and (
					selected_ids.size() < int(choice.get("min_select", 0))
					or selected_ids.size() > int(choice.get("max_select", 0))
				)
			)
			or (
				not bool(choice.get("allow_duplicates", false))
				and _has_duplicate_ids(selected_ids)
			)
		):
			result["success"] = false
			result["error"] = "native_choice_constraints_unsatisfied"
			result["deep_failure_reason"] = result["error"]
			return result
		result["kind"] = "choice"
		result["choice_response"] = {
			"request_id": request_id,
			"option_ids": selected_ids,
			"cancelled": cancelled,
		}
		return result
	var signature := str(result.get("action_signature", ""))
	var rows_value: Variant = request.get("actions", [])
	if signature.is_empty() or not rows_value is Array:
		result["success"] = false
		result["error"] = "native_action_signature_missing"
		result["deep_failure_reason"] = result["error"]
		return result
	for row_value in rows_value:
		if not row_value is Dictionary:
			continue
		var action := GameAction.from_dict(row_value)
		if (
			action != null
			and AIPositionEvaluator.action_signature(action) == signature
		):
			result["action"] = Dictionary(row_value).duplicate(true)
			result["selected_action_signature"] = signature
			return result
	result["success"] = false
	result["error"] = "native_action_not_in_authoritative_legal_set"
	result["deep_failure_reason"] = result["error"]
	return result


static func _has_duplicate_ids(values: Array[String]) -> bool:
	var seen: Dictionary = {}
	for value in values:
		if seen.has(value):
			return true
		seen[value] = true
	return false


func contract() -> Dictionary:
	return (
		Dictionary(_native.call("get_contract"))
		if _native != null
		else {}
	)

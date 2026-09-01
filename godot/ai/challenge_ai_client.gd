class_name ChallengeAIClient
extends RefCounted

## Thin Godot adapter for the single native Challenge implementation.
## Rules, search, tactics, choice policy, and strategy scoring live in C++.

const TRADITIONAL_ENGINE_ID := "turn_beam_v2"
const STRATEGY_DATA_PATH := "res://data/ai_strategies.json"
const MAX_PUBLIC_HISTORY := 4096
const CHOICE_VIEW_FIELDS := [
	"schema_version",
	"request_id",
	"base_revision",
	"player",
	"request_type",
	"prompt",
	"options",
	"min_select",
	"max_select",
	"allow_duplicates",
	"can_cancel",
	"presentation",
]

var _controller: Variant = null
var _catalog_identity := 0
var _generation := 0
var _strategy_data: Dictionary = {}


func cancel_native_request() -> void:
	if _controller != null and _controller.has_method("cancel"):
		_controller.cancel(_generation)


func decide(
	request: Dictionary,
	cancel_check: Callable,
	_inference: Variant = null,
) -> Dictionary:
	var error := _request_error(request)
	if not error.is_empty():
		return _failure(request, error)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		return _cancelled(request)
	var catalog := CardCatalog.shared()
	var controller: Variant = _configured_controller(catalog)
	if controller == null:
		return _failure(request, "native_challenge_controller_unavailable")
	_generation += 1
	controller.reset_match(str(request.get("match_instance_id", "")))
	var result: Dictionary = controller.decide(request, _generation)
	if cancel_check.is_valid() and bool(cancel_check.call()):
		controller.cancel(_generation)
		return _cancelled(request)
	return result


func _configured_controller(catalog: CardCatalog) -> Variant:
	if catalog == null or not ClassDB.class_exists("NativeChallengeAI"):
		return null
	if _strategy_data.is_empty():
		_strategy_data = _read_json(STRATEGY_DATA_PATH)
	if _strategy_data.is_empty():
		return null
	var identity := int(catalog.get_instance_id())
	if _controller == null or identity != _catalog_identity:
		_controller = ClassDB.instantiate("NativeChallengeAI")
		_catalog_identity = 0
		if _controller == null:
			return null
		var configured: Dictionary = _controller.configure(
			catalog.native_rules_catalog(),
			catalog.decks,
			_strategy_data,
		)
		if not bool(configured.get("success", false)):
			_controller = null
			return null
		_catalog_identity = identity
	return _controller


static func _request_error(request: Dictionary) -> String:
	var kind := str(request.get("kind", "action"))
	if kind not in ["action", "choice"]:
		return "invalid_request_kind"
	if request.get("actor") is not int or int(request.get("actor")) not in [0, 1]:
		return "invalid_actor"
	if request.get("revision") is not int or int(request.get("revision")) < 0:
		return "invalid_request_revision"
	if request.get("state") is not Dictionary:
		return "invalid_runtime_state"
	var history_error := _public_history_error(
		request.get("public_history", []),
		int(request.get("actor", -1)),
	)
	if not history_error.is_empty():
		return history_error
	if kind == "action" and request.get("actions") is not Array:
		return "invalid_authoritative_legal_actions"
	if kind == "choice":
		var choice_error := _choice_view_error(request.get("choice"))
		if not choice_error.is_empty():
			return choice_error
	return ""


static func _public_history_error(value: Variant, perspective: int) -> String:
	if value is not Array or Array(value).size() > MAX_PUBLIC_HISTORY:
		return "invalid_public_history"
	for event_value in Array(value):
		if event_value is not Dictionary:
			return "invalid_public_history"
		var event: Dictionary = event_value
		var visibility := str(event.get("visibility", PresentationEvent.PUBLIC))
		if (
			str(event.get("event_type", "")).is_empty()
			or visibility not in [
				PresentationEvent.PUBLIC,
				PresentationEvent.OWNER,
				PresentationEvent.PRIVATE,
			]
			or event.get("data", {}) is not Dictionary
			or event.get("source", {}) is not Dictionary
			or event.get("target", {}) is not Dictionary
		):
			return "invalid_public_history"
		var data: Dictionary = event.get("data", {})
		var owner := int(data.get(
			"visibility_owner",
			data.get(
				"player",
				Dictionary(event.get("target", {})).get(
					"player",
					Dictionary(event.get("source", {})).get("player", -1),
				),
			),
		))
		if visibility != PresentationEvent.PUBLIC and owner not in [0, 1]:
			return "invalid_public_history"
		if visibility == PresentationEvent.PRIVATE and owner != perspective:
			return "private_public_history"
		if (
			visibility != PresentationEvent.PUBLIC
			and owner != perspective
			and _history_has_card_identity(event)
		):
			return "private_public_history"
	return ""


static func _history_has_card_identity(event: Dictionary) -> bool:
	if not str(event.get("card_id", "")).is_empty():
		return true
	var data: Dictionary = event.get("data", {})
	for field in PresentationEvent.CARD_ID_FIELDS:
		if not str(data.get(field, "")).is_empty():
			return true
	for field in PresentationEvent.CARD_LIST_FIELDS:
		var value: Variant = data.get(field, [])
		if value is Array and not Array(value).is_empty():
			return true
	return false


static func _choice_view_error(value: Variant) -> String:
	if value is not Dictionary:
		return "invalid_choice_view"
	var row: Dictionary = value
	if row.size() != CHOICE_VIEW_FIELDS.size():
		return "invalid_choice_view"
	for field in CHOICE_VIEW_FIELDS:
		if not row.has(field):
			return "invalid_choice_view"
	if (
		row["schema_version"] is not int
		or int(row["schema_version"]) != ChoiceView.SCHEMA_VERSION
		or row["base_revision"] is not int
		or int(row["base_revision"]) < 0
		or row["player"] is not int
		or int(row["player"]) not in [0, 1]
		or row["request_id"] is not String
		or str(row["request_id"]).is_empty()
		or row["request_type"] is not String
		or str(row["request_type"]).is_empty()
		or row["prompt"] is not String
		or row["options"] is not Array
		or row["min_select"] is not int
		or row["max_select"] is not int
		or int(row["min_select"]) < 0
		or int(row["max_select"]) < int(row["min_select"])
		or row["allow_duplicates"] is not bool
		or row["can_cancel"] is not bool
		or row["presentation"] is not Dictionary
	):
		return "invalid_choice_view"
	for option_value in row["options"]:
		if option_value is not Dictionary:
			return "invalid_choice_view"
		var option: Dictionary = option_value
		for option_field in option:
			if option_field not in ["option_id", "label", "ref"]:
				return "private_choice_field"
		if option.size() not in [2, 3] or not option.has("option_id") or not option.has("label"):
			return "invalid_choice_view"
		if (
			option["option_id"] is not String
			or str(option["option_id"]).is_empty()
			or option["label"] is not String
		):
			return "invalid_choice_view"
		if option.has("ref") and (
			option["ref"] is not Dictionary
			or not EntityRef.validate_dict(option["ref"]).is_empty()
		):
			return "invalid_choice_ref"
	var view := ChoiceView.from_dict(row)
	return "" if view.to_dict() == row else "invalid_choice_view"


static func _failure(request: Dictionary, error: String) -> Dictionary:
	return {
		"success": false,
		"kind": str(request.get("kind", "action")),
		"error": error,
		"decision_origin": "failure",
		"failure_stage": "request_decode",
		"revision": int(request.get("revision", -1)),
		"request_id": str(request.get("request_id", "")),
	}


static func _cancelled(request: Dictionary) -> Dictionary:
	var result := _failure(request, "cancelled")
	result["cancelled"] = true
	return result


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

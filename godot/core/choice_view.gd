class_name ChoiceView
extends RefCounted

const SCHEMA_VERSION := 2
const PRIVATE_FIELD_NAMES: Array[String] = [
	"value",
	"continuation",
	"guard",
	"command",
	"commands",
	"checkpoint",
	"snapshot",
]

# Only these author-provided hints may cross the rules/presentation boundary.
# Continuations, checkpoints, commands, guards and transaction snapshots remain
# exclusively in GameState's authoritative ResolutionStack.
const PRESENTATION_FIELDS: Array[String] = [
	"domain",
	"purpose",
	"decision_mode",
	"cancel_mode",
	"cancels_action",
	"card_ids",
	"revealed_card_ids",
	"top_card_id",
	"attachment_refs",
	"source_player",
	"source_slot",
	"source_zone",
	"source_card_id",
	"card_id",
	"target_player",
	"target_slot",
	"target_slots",
	"required_units",
	"max_per_target",
	"same_target",
	"same_source",
	"pokemon_count",
	"energy_count",
	"energy_type",
	"predetermined_flips",
	"category_limits",
	"selection_mode",
	"amount",
	"count",
	"owner",
	"trigger_id",
	"trigger_ids",
	"hook",
	"labels",
]

var request_id: String
var base_revision: int
var request_type: String
var player: int
var prompt: String
var options: Array[Dictionary]
var min_select: int
var max_select: int
var allow_duplicates: bool
var can_cancel: bool
var presentation: Dictionary


func _init(
	p_request_id: String = "",
	p_base_revision: int = -1,
	p_request_type: String = "",
	p_player: int = 0,
	p_prompt: String = "",
	p_options: Array[Dictionary] = [],
	p_min_select: int = 1,
	p_max_select: int = 1,
	p_allow_duplicates: bool = false,
	p_can_cancel: bool = false,
	p_presentation: Dictionary = {},
) -> void:
	request_id = p_request_id
	base_revision = p_base_revision
	request_type = p_request_type
	player = p_player
	prompt = _public_prompt(p_prompt, p_request_type)
	options = _public_options(p_options, p_request_type, p_player)
	min_select = p_min_select
	max_select = p_max_select
	allow_duplicates = p_allow_duplicates
	can_cancel = p_can_cancel
	presentation = _project_presentation(p_presentation, p_request_type)


func to_dict() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"request_id": request_id,
		"base_revision": base_revision,
		"player": player,
		"request_type": request_type,
		"prompt": prompt,
		"options": _public_options(options, request_type, player),
		"min_select": min_select,
		"max_select": max_select,
		"allow_duplicates": allow_duplicates,
		"can_cancel": can_cancel,
		"presentation": presentation.duplicate(true),
	}


static func from_dict(data: Dictionary) -> ChoiceView:
	var raw_options: Array[Dictionary] = []
	for option in data.get("options", []):
		if option is Dictionary:
			raw_options.append(Dictionary(option))
	return ChoiceView.new(
		str(data.get("request_id", "")),
		int(data.get("base_revision", -1)),
		str(data.get("request_type", "")),
		int(data.get("player", 0)),
		str(data.get("prompt", "")),
		raw_options,
		int(data.get("min_select", 1)),
		int(data.get("max_select", 1)),
		bool(data.get("allow_duplicates", false)),
		bool(data.get("can_cancel", false)),
		Dictionary(data.get("presentation", {})),
	)


static func _public_options(
	raw_options: Array[Dictionary],
	request_type: String = "",
	request_player: int = -1,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(raw_options.size()):
		var raw: Dictionary = raw_options[index]
		var option_id := str(raw.get("option_id", ""))
		if option_id.is_empty():
			continue
		if request_type == "select_prize":
			# A malformed producer must not smuggle a face-down identity through a
			# label or option id. Prize responses are positional by contract.
			result.append({
				"option_id": "prize:%d" % index,
				"label": "奖励牌 %d" % (index + 1),
			})
			continue
		var option: Dictionary = {
			"option_id": option_id,
			"label": str(raw.get("label", "")),
		}
		# Choosing a face-down Prize is positional. Even if a future producer
		# accidentally attaches an authoritative card ref, ChoiceView must not turn
		# that into a reveal.
		if (
			raw.get("ref") is Dictionary
			and _ref_is_public_for_request(
				Dictionary(raw["ref"]), request_type, request_player)
		):
			option["ref"] = Dictionary(raw["ref"]).duplicate(true)
		result.append(option)
	return result


static func _project_presentation(
	raw: Dictionary,
	request_type: String = "",
) -> Dictionary:
	var result: Dictionary = {}
	for field in PRESENTATION_FIELDS:
		if request_type == "select_prize" and field in [
			"card_ids",
			"revealed_card_ids",
			"top_card_id",
			"attachment_refs",
			"source_card_id",
			"card_id",
			"labels",
		]:
			continue
		if raw.has(field):
			var copied: Variant = _json_copy(raw[field])
			copied = _normalize_presentation_value(field, copied)
			if _presentation_value_is_valid(field, copied):
				result[field] = copied
	return result


static func _normalize_presentation_value(field: String, value: Variant) -> Variant:
	if field in [
		"source_player", "target_player", "owner", "required_units",
		"max_per_target", "pokemon_count", "energy_count", "amount", "count",
	]:
		return int(value) if _is_wire_integer(value) else value
	if field == "category_limits" and value is Dictionary:
		var limits := Dictionary(value).duplicate(true)
		for category in limits:
			if _is_wire_integer(limits[category]):
				limits[category] = int(limits[category])
		return limits
	if field == "attachment_refs" and value is Array:
		var refs: Array = []
		for ref_value in Array(value):
			if not ref_value is Dictionary:
				refs.append(ref_value)
				continue
			var ref := Dictionary(ref_value).duplicate(true)
			for integer_field in ["player", "index", "units"]:
				if ref.has(integer_field) and _is_wire_integer(ref[integer_field]):
					ref[integer_field] = int(ref[integer_field])
			refs.append(ref)
		return refs
	return value


static func _public_prompt(raw_prompt: String, request_type: String) -> String:
	return "请选择奖励牌。" if request_type == "select_prize" else raw_prompt


static func _ref_is_public_for_request(
	value: Dictionary,
	request_type: String,
	request_player: int,
) -> bool:
	if request_type == "select_prize" or not EntityRef.validate_dict(value).is_empty():
		return false
	var ref := EntityRef.from_dict(value)
	if ref.kind != "card":
		return true
	# Prize identity is never public before the award resolves. Hidden hand/deck
	# refs may only be shown to the player who owns this ChoiceView.
	if ref.zone == "prizes":
		return false
	if ref.zone in ["hand", "deck"] and ref.player != request_player:
		return false
	return true


static func _presentation_value_is_valid(field: String, value: Variant) -> bool:
	if value == null:
		return false
	if field in [
		"domain", "purpose", "decision_mode", "cancel_mode", "source_slot",
		"source_zone", "source_card_id", "card_id", "target_slot",
		"energy_type", "selection_mode", "trigger_id", "hook",
	]:
		return value is String
	if field in ["source_player", "target_player", "owner"]:
		return value is int and int(value) in [-1, 0, 1]
	if field in [
		"required_units", "max_per_target", "pokemon_count", "energy_count",
		"amount", "count",
	]:
		return value is int and int(value) >= 0
	if field in ["same_target", "same_source", "cancels_action"]:
		return value is bool
	if field in [
		"card_ids", "revealed_card_ids", "target_slots", "trigger_ids", "labels",
	]:
		if not value is Array or Array(value).size() > 256:
			return false
		for item in Array(value):
			if not item is String:
				return false
		return true
	if field == "predetermined_flips":
		if not value is Array or Array(value).size() > 256:
			return false
		for item in Array(value):
			if not item is bool:
				return false
		return true
	if field == "attachment_refs":
		if not value is Array or Array(value).size() > 256:
			return false
		for ref_value in Array(value):
			if not ref_value is Dictionary:
				return false
			var ref := Dictionary(ref_value)
			var entity_ref_valid := (
				EntityRef.validate_dict(ref).is_empty()
				and str(ref.get("zone", "")) != "prizes"
			)
			var unit_ref_valid := (
				ref.size() == 2
				and ref.get("option_id") is String
				and not str(ref.get("option_id", "")).is_empty()
				and ref.get("units") is int
				and int(ref.get("units", 0)) > 0
			)
			if not entity_ref_valid and not unit_ref_valid:
				return false
		return true
	if field == "category_limits":
		if not value is Dictionary or Dictionary(value).size() > 256:
			return false
		for category in Dictionary(value):
			if (
				not category is String
				or not Dictionary(value)[category] is int
				or int(Dictionary(value)[category]) < 0
			):
				return false
		return true
	return false


static func _is_wire_integer(value: Variant) -> bool:
	if value is int:
		return true
	return (
		value is float
		and is_finite(value)
		and value >= -2147483648.0
		and value <= 2147483647.0
		and value == floorf(value)
	)


static func _json_copy(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			if key is String and str(key) not in PRIVATE_FIELD_NAMES:
				result[key] = _json_copy(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_json_copy(item))
		return result
	if value is String or value is bool or value is int or value is float or value == null:
		return value
	return null

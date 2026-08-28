extends RefCounted

const VERSION := 6
const MAX_MESSAGE_BYTES := 262144
const MAX_IDENTIFIER_BYTES := 128
const MAX_TEXT_BYTES := 2048
const MAX_DECK_CARDS := 60
const MAX_PRIZES := 6
const MAX_BENCH_SIZE := 5
const MAX_LEGAL_ACTIONS := 256
const MAX_PRESENTATION_EVENTS := 256
const MAX_CHOICE_OPTIONS := 60
const MAX_ACTION_LOG_ENTRIES := 256
const MAX_GENERIC_CONTAINER_ITEMS := 512
const MAX_JSON_DEPTH := 12

const GAME_PHASES: Array[String] = [
	"SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER",
]
const STATUS_CONDITIONS: Array[String] = [
	"POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED",
]
const SETUP_STAGES: Array[String] = [
	"TURN_ORDER", "INITIAL_PLACEMENT", "BONUS_DRAW", "BONUS_PLACEMENT", "COMPLETE",
]
const RESULT_STATUSES: Array[String] = ["ONGOING", "WIN", "DRAW"]
const RULES_PROFILE_ID := "CN_MAINLAND_3_1_0"

static func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


static func _is_integer_number(value: Variant) -> bool:
	if value is int:
		return true
	return (
		value is float
		and is_finite(value)
		and value >= -2147483648.0
		and value <= 2147483647.0
		and value == floorf(value)
	)


static func _has_integer(row: Dictionary, field: String) -> bool:
	return row.has(field) and _is_integer_number(row[field])



static func _validate_hidden_pokemon(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	return (
		row.size() == 1
		and row.get("hidden") is bool
		and bool(row["hidden"])
	)


static func _validate_rules_options(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var options: Dictionary = value
	return (
		options.size() == 1
		and options.has("apply_type_matchups")
		and options["apply_type_matchups"] is bool
	)


static func _validate_result_conditions(value: Variant) -> bool:
	if not value is Array or Array(value).size() != 2:
		return false
	for player_conditions in Array(value):
		if not _bounded_string_array(player_conditions, 8, 64):
			return false
	return true



static func _bounded_string(value: Variant, max_bytes: int) -> bool:
	return value is String and value.to_utf8_buffer().size() <= max_bytes


static func _bounded_int(
	row: Dictionary,
	field: String,
	minimum: int,
	maximum: int,
) -> bool:
	return (
		_has_integer(row, field)
		and int(row[field]) >= minimum
		and int(row[field]) <= maximum
	)


static func _bounded_string_array(
	value: Variant,
	max_items: int,
	max_string_bytes: int,
) -> bool:
	if not value is Array or Array(value).size() > max_items:
		return false
	for item in value:
		if not _bounded_string(item, max_string_bytes):
			return false
	return true


static func _bounded_integer_array(
	value: Variant,
	max_items: int,
	minimum: int,
	maximum: int,
) -> bool:
	if not value is Array or Array(value).size() > max_items:
		return false
	for item in Array(value):
		if (
			not _is_integer_number(item)
			or int(item) < minimum
			or int(item) > maximum
		):
			return false
	return true


static func _fixed_string_array(
	value: Variant,
	expected_items: int,
	max_string_bytes: int,
) -> bool:
	return (
		value is Array
		and Array(value).size() == expected_items
		and _bounded_string_array(value, expected_items, max_string_bytes)
	)


static func _fixed_int_array(
	value: Variant,
	expected_items: int,
	minimum: int,
	maximum: int,
) -> bool:
	if not value is Array or Array(value).size() != expected_items:
		return false
	for item in value:
		if not _is_integer_number(item) or int(item) < minimum or int(item) > maximum:
			return false
	return true


static func _fixed_bool_array(value: Variant, expected_items: int) -> bool:
	if not value is Array or Array(value).size() != expected_items:
		return false
	for item in value:
		if not item is bool:
			return false
	return true


static func _bounded_player_index_array(value: Variant, max_items: int) -> bool:
	if not value is Array or Array(value).size() > max_items:
		return false
	for item in value:
		if not _is_integer_number(item) or int(item) not in [0, 1]:
			return false
	return true


static func _json_tree_is_bounded(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_JSON_DEPTH:
		return false
	if value == null or value is bool or value is int:
		return true
	if value is float:
		return is_finite(value)
	if value is String:
		return _bounded_string(value, MAX_TEXT_BYTES * 4)
	if value is Array:
		var values: Array = value
		if values.size() > MAX_GENERIC_CONTAINER_ITEMS:
			return false
		for item in values:
			if not _json_tree_is_bounded(item, depth + 1):
				return false
		return true
	if value is Dictionary:
		var row: Dictionary = value
		if row.size() > MAX_GENERIC_CONTAINER_ITEMS:
			return false
		for key_value in row.keys():
			if (
				not _bounded_string(key_value, MAX_IDENTIFIER_BYTES)
				or not _json_tree_is_bounded(row[key_value], depth + 1)
			):
				return false
		return true
	return false


static func _valid_sha256(value: Variant) -> bool:
	if not value is String:
		return false
	var text := str(value)
	return (
		text.length() == 64
		and text == text.to_lower()
		and text.is_valid_hex_number(false)
	)


static func _json_tree_is_serializable(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_JSON_DEPTH:
		return false
	if value == null or value is bool or value is int or value is String:
		return true
	if value is float:
		return is_finite(value)
	if value is Array:
		for item in value:
			if not _json_tree_is_serializable(item, depth + 1):
				return false
		return true
	if value is Dictionary:
		var row: Dictionary = value
		for key_value in row:
			if (
				not key_value is String
				or not _json_tree_is_serializable(row[key_value], depth + 1)
			):
				return false
		return true
	return false

class_name ActionDefinitionRegistry
extends RefCounted

## Schema-only Action v4 descriptor registry. Candidate generation, preflight
## and execution are owned by ptcg_core and cannot be bound from GDScript.

const ACTION_SCHEMA_VERSION := 4

var _definitions: Dictionary = {}
var _frozen := false
var _registration_errors: Array[String] = []

static var _shared: ActionDefinitionRegistry


func _init() -> void:
	_register_defaults()
	freeze()


static func shared() -> ActionDefinitionRegistry:
	if _shared == null:
		_shared = ActionDefinitionRegistry.new()
	return _shared


func register_definition(kind: String, definition: Dictionary) -> bool:
	if _frozen:
		_registration_errors.append(
			"Action definition registry is frozen: %s" % kind)
		return false
	if kind.is_empty() or _definitions.has(kind):
		_registration_errors.append(
			"Duplicate or empty action definition: %s" % kind)
		return false
	var row := definition.duplicate(true)
	row["kind"] = kind
	for default_row in [
		["encoding_id", -1], ["public", true], ["terminal", false],
		["source_kinds", []], ["source_required", false],
		["target_kinds", []], ["target_required", false], ["payload", {}],
	]:
		if not row.has(default_row[0]):
			row[default_row[0]] = default_row[1]
	_definitions[kind] = row
	return true


func freeze() -> bool:
	if _frozen:
		return true
	if not _registration_errors.is_empty():
		return false
	var encoding_ids: Dictionary = {}
	for kind_value in _definitions:
		var kind := str(kind_value)
		var row: Dictionary = _definitions[kind]
		if not bool(row.get("public", true)):
			continue
		var encoding_id := int(row.get("encoding_id", -1))
		if encoding_id < 0 or encoding_ids.has(encoding_id):
			return false
		encoding_ids[encoding_id] = kind
	_frozen = true
	return true


func is_frozen() -> bool:
	return _frozen


func has(kind: String) -> bool:
	return _definitions.has(kind)


func definition(kind: String) -> Dictionary:
	return Dictionary(_definitions.get(kind, {})).duplicate(true)


func public_kinds() -> Array[String]:
	var result: Array[String] = []
	for kind_value in _definitions:
		var kind := str(kind_value)
		if bool(Dictionary(_definitions[kind]).get("public", true)):
			result.append(kind)
	result.sort_custom(func(left: String, right: String) -> bool:
		return encoding_index(left) < encoding_index(right))
	return result


func all_kinds() -> Array[String]:
	var result: Array[String] = []
	for kind_value in _definitions:
		result.append(str(kind_value))
	result.sort_custom(func(left: String, right: String) -> bool:
		return encoding_index(left) < encoding_index(right))
	return result


func encoder_kinds() -> Array[String]:
	return public_kinds()


func encoding_index(kind: String) -> int:
	return int(Dictionary(_definitions.get(kind, {})).get("encoding_id", -1))


func is_terminal(kind: String) -> bool:
	return bool(Dictionary(_definitions.get(kind, {})).get("terminal", false))


func validate_action(
	action: GameAction,
	require_public: bool = true,
) -> Dictionary:
	if action == null or action.schema_version != ACTION_SCHEMA_VERSION:
		return _invalid("invalid_schema", "动作 schema 版本无效。")
	if not _definitions.has(action.kind):
		return _invalid("illegal_action", "未知动作类型。")
	var row: Dictionary = _definitions[action.kind]
	if require_public and not bool(row.get("public", true)):
		return _invalid("illegal_action", "该动作不能由外部提交。")
	if action.actor not in [0, 1]:
		return _invalid("unauthorized_actor", "动作玩家无效。")
	var payload_schema: Dictionary = row.get("payload", {})
	if action.payload.size() != payload_schema.size():
		return _invalid("invalid_schema", "动作载荷字段不匹配。")
	for field_value in payload_schema:
		var field := str(field_value)
		if not action.payload.has(field) or not _value_matches_type(
			action.payload[field], str(payload_schema[field])):
			return _invalid("invalid_schema", "动作载荷字段无效：%s" % field)
	var ref_error := _validate_ref_shape(
		action.source,
		Array(row.get("source_kinds", [])),
		bool(row.get("source_required", false)),
		"source",
	)
	if not ref_error.is_empty():
		return _invalid("invalid_ref", ref_error)
	ref_error = _validate_ref_shape(
		action.target,
		Array(row.get("target_kinds", [])),
		bool(row.get("target_required", false)),
		"target",
	)
	if not ref_error.is_empty():
		return _invalid("invalid_ref", ref_error)
	for ref in [action.source, action.target]:
		if ref != null and ref.player != action.actor:
			return _invalid("invalid_ref", "动作引用与玩家不一致。")
	return {"ok": true, "code": "", "message": ""}


func validate_wire_dict(
	value: Variant,
	require_action_id: bool = true,
) -> Dictionary:
	if not value is Dictionary:
		return _invalid("invalid_schema", "动作必须是对象。")
	var data: Dictionary = value
	var expected := [
		"schema_version", "action_id", "base_revision", "actor",
		"kind", "source", "target", "payload",
	]
	if data.size() != expected.size():
		return _invalid("invalid_schema", "动作包含缺失或多余字段。")
	for field in expected:
		if not data.has(field):
			return _invalid("invalid_schema", "动作缺少字段：%s" % field)
	if not _is_wire_integer(data["schema_version"]) or int(
		data["schema_version"]) != ACTION_SCHEMA_VERSION:
		return _invalid("invalid_schema", "动作 schema 版本无效。")
	if not _is_wire_integer(data["base_revision"]) or int(
		data["base_revision"]) < 0:
		return _invalid("invalid_schema", "动作基础版本无效。")
	if not _is_wire_integer(data["actor"]) or int(data["actor"]) not in [0, 1]:
		return _invalid("unauthorized_actor", "动作玩家无效。")
	if not data["kind"] is String or not data["payload"] is Dictionary:
		return _invalid("invalid_schema", "动作类型或载荷无效。")
	if not data["action_id"] is String or (
		require_action_id and str(data["action_id"]).is_empty()):
		return _invalid("invalid_schema", "动作缺少唯一 ID。")
	for ref_field in ["source", "target"]:
		if data[ref_field] != null:
			var raw_error := EntityRef.validate_dict(data[ref_field])
			if not raw_error.is_empty():
				return _invalid("invalid_ref", raw_error)
	return validate_action(GameAction.from_dict(data), true)


func _register_defaults() -> void:
	var rows: Array[Dictionary] = [
		{"kind": "PLAY_BASIC", "encoding_id": 0, "source_kinds": ["card"], "source_required": true, "target_kinds": ["slot"], "target_required": true},
		{"kind": "EVOLVE", "encoding_id": 1, "source_kinds": ["card"], "source_required": true, "target_kinds": ["pokemon"], "target_required": true},
		{"kind": "ATTACH_ENERGY", "encoding_id": 2, "source_kinds": ["card"], "source_required": true, "target_kinds": ["pokemon"], "target_required": true},
		{"kind": "PLAY_TRAINER", "encoding_id": 3, "source_kinds": ["card"], "source_required": true, "target_kinds": ["pokemon"]},
		{"kind": "USE_ABILITY", "encoding_id": 4, "source_kinds": ["pokemon", "card"], "source_required": true, "payload": {"ability_name": "String"}},
		{"kind": "USE_STADIUM", "encoding_id": 5, "source_kinds": ["card"], "source_required": true},
		{"kind": "RETREAT", "encoding_id": 6, "source_kinds": ["pokemon"], "source_required": true, "target_kinds": ["pokemon"], "target_required": true},
		{"kind": "DECLARE_ATTACK", "encoding_id": 7, "terminal": true, "source_kinds": ["pokemon"], "source_required": true, "payload": {"attack_index": "int"}},
		{"kind": "PROMOTE", "encoding_id": 8, "target_kinds": ["pokemon"], "target_required": true},
		{"kind": "SETUP_DONE", "encoding_id": 9, "terminal": true},
		{"kind": "END_TURN", "encoding_id": 10, "terminal": true},
		{"kind": "NOOP", "encoding_id": -1, "public": false},
	]
	for row in rows:
		var kind := str(row.get("kind", ""))
		row.erase("kind")
		register_definition(kind, row)


static func _validate_ref_shape(
	ref: EntityRef,
	allowed_kinds: Array,
	required: bool,
	field: String,
) -> String:
	if ref == null:
		return "%s 引用缺失。" % field if required else ""
	var error := ref.validation_error()
	if not error.is_empty():
		return error
	if ref.kind not in allowed_kinds:
		return "%s 引用类型不允许。" % field
	return ""


static func _value_matches_type(value: Variant, expected: String) -> bool:
	match expected:
		"String":
			return value is String and not str(value).is_empty()
		"int":
			return _is_wire_integer(value) and int(value) >= 0
		"bool":
			return value is bool
		_:
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


static func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}

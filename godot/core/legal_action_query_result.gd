class_name LegalActionQueryResult
extends RefCounted

const SCHEMA_VERSION := 1

var success: bool
var code: String
var message: String
var base_revision: int
var groups: Array[LegalActionGroup]


func _init(
	p_success: bool = false,
	p_code: String = "",
	p_message: String = "",
	p_base_revision: int = -1,
	p_groups: Array[LegalActionGroup] = [],
) -> void:
	success = p_success
	code = p_code
	message = p_message
	base_revision = p_base_revision
	groups.assign(p_groups)


static func ok(revision: int, legal_groups: Array[LegalActionGroup]) -> LegalActionQueryResult:
	return LegalActionQueryResult.new(true, "", "", revision, legal_groups)


static func failure(
	revision: int,
	error_code: String,
	error_message: String,
) -> LegalActionQueryResult:
	return LegalActionQueryResult.new(
		false,
		error_code if not error_code.is_empty() else "legal_action_query_error",
		error_message,
		revision,
		[],
	)


func to_dict() -> Dictionary:
	var rows: Array[Dictionary] = []
	for group in groups:
		rows.append(group.to_dict())
	return {
		"schema_version": SCHEMA_VERSION,
		"success": success,
		"code": code,
		"message": message,
		"base_revision": base_revision,
		"groups": rows,
	}


static func from_dict(data: Dictionary) -> LegalActionQueryResult:
	var parsed_groups: Array[LegalActionGroup] = []
	for value in data.get("groups", []):
		if value is Dictionary:
			parsed_groups.append(LegalActionGroup.from_dict(value))
	return LegalActionQueryResult.new(
		bool(data.get("success", false)),
		str(data.get("code", "")),
		str(data.get("message", "")),
		int(data.get("base_revision", -1)),
		parsed_groups,
	)


func immutable_copy() -> LegalActionQueryResult:
	var copied_groups: Array[LegalActionGroup] = []
	for group in groups:
		copied_groups.append(group.immutable_copy())
	return LegalActionQueryResult.new(
		success, code, message, base_revision, copied_groups)


func concrete_actions() -> Array[GameAction]:
	var result: Array[GameAction] = []
	if not success:
		return result
	for group in groups:
		result.append_array(group.concrete_actions())
	return result

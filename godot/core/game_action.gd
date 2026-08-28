class_name GameAction
extends RefCounted

const SCHEMA_VERSION := 4

var schema_version := SCHEMA_VERSION
var kind: String
var payload: Dictionary
var actor: int
var source: EntityRef
var target: EntityRef
var action_id: String
var base_revision: int

var terminal: bool:
	get:
		return ActionDefinitionRegistry.shared().is_terminal(kind)


func _init(
	p_kind: String = "",
	p_payload: Dictionary = {},
	p_actor: int = -1,
	p_source: EntityRef = null,
	p_target: EntityRef = null,
	p_action_id: String = "",
	p_base_revision: int = -1,
	p_schema_version: int = SCHEMA_VERSION,
) -> void:
	kind = p_kind
	payload = normalize_wire_payload(p_kind, p_payload)
	actor = p_actor
	source = p_source
	target = p_target
	action_id = p_action_id
	base_revision = p_base_revision
	schema_version = p_schema_version


static func create(
	p_kind: String,
	p_payload: Dictionary,
	p_actor: int,
	p_source: EntityRef = null,
	p_target: EntityRef = null,
	p_action_id: String = "",
	p_base_revision: int = -1,
) -> GameAction:
	return GameAction.new(
		p_kind, p_payload, p_actor, p_source, p_target,
		p_action_id, p_base_revision, SCHEMA_VERSION)


static func validate_wire_dict(
	value: Variant,
	require_action_id: bool = true,
) -> Dictionary:
	return ActionDefinitionRegistry.shared().validate_wire_dict(
		value, require_action_id)


static func validate_instance(
	value: GameAction,
	public_only: bool = true,
) -> Dictionary:
	return ActionDefinitionRegistry.shared().validate_action(value, public_only)


static func is_known_kind(value: String) -> bool:
	return ActionDefinitionRegistry.shared().has(value)


static func encoder_kinds() -> Array[String]:
	return ActionDefinitionRegistry.shared().encoder_kinds()


static func encoding_index(value: String) -> int:
	return ActionDefinitionRegistry.shared().encoding_index(value)


static func is_terminal_kind(value: String) -> bool:
	return ActionDefinitionRegistry.shared().is_terminal(value)


func to_dict() -> Dictionary:
	return {
		"schema_version": schema_version,
		"action_id": action_id,
		"base_revision": base_revision,
		"actor": actor,
		"kind": kind,
		"source": source.to_dict() if source else null,
		"target": target.to_dict() if target else null,
		"payload": payload.duplicate(true),
	}


static func from_dict(data: Dictionary) -> GameAction:
	var strict := GameAction.create(
		str(data.get("kind", "")),
		Dictionary(data.get("payload", {})),
		int(data.get("actor", -1)),
		EntityRef.from_dict(data["source"]) if data.get("source") is Dictionary else null,
		EntityRef.from_dict(data["target"]) if data.get("target") is Dictionary else null,
		str(data.get("action_id", "")),
		int(data.get("base_revision", -1)),
	)
	strict.schema_version = int(data.get("schema_version", 0))
	return strict


static func normalize_wire_payload(
	action_kind: String,
	raw_payload: Dictionary,
) -> Dictionary:
	# Godot's JSON parser represents protocol numbers as floats. Keep the public
	# wire format permissive, then canonicalize schema-declared integers at the
	# DTO boundary so attack variants remain distinct after a network round trip.
	var result := raw_payload.duplicate(true)
	var definition := ActionDefinitionRegistry.shared().definition(action_kind)
	var payload_schema: Dictionary = definition.get("payload", {})
	for field_value in payload_schema:
		var field := str(field_value)
		if str(payload_schema[field]) != "int" or not result.has(field):
			continue
		var value: Variant = result[field]
		if (
			(value is int or value is float)
			and not value is bool
			and is_finite(float(value))
			and float(value) >= -2147483648.0
			and float(value) <= 2147483647.0
			and float(value) == floorf(float(value))
		):
			result[field] = int(value)
	return result


func hand_index(default_value: int = -1) -> int:
	if source != null and source.kind == "card" and source.zone == "hand":
		return source.index
	return default_value


func source_slot(default_value: String = "") -> String:
	if source != null and source.kind in ["pokemon", "slot", "attachment"]:
		return source.slot
	return default_value


func target_slot(default_value: String = "") -> String:
	if target != null and target.kind in ["pokemon", "slot", "attachment"]:
		return target.slot
	return default_value


func primary_slot(default_value: String = "") -> String:
	var slot := source_slot()
	return slot if not slot.is_empty() else target_slot(default_value)


func bench_index(default_value: int = -1) -> int:
	var slot := target_slot()
	if slot.begins_with("bench_") and slot.trim_prefix("bench_").is_valid_int():
		return slot.trim_prefix("bench_").to_int()
	return default_value


func attack_index(default_value: int = -1) -> int:
	var value: Variant = payload.get("attack_index", default_value)
	return (
		int(value)
		if (
			(value is int or value is float)
			and not value is bool
			and is_finite(float(value))
			and float(value) >= -2147483648.0
			and float(value) <= 2147483647.0
			and float(value) == floorf(float(value))
		)
		else default_value
	)


func ability_name(default_value: String = "") -> String:
	var value: Variant = payload.get("ability_name", default_value)
	return str(value) if value is String else default_value

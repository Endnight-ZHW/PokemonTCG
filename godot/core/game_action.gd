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
var _legacy_constructed := true

# Read-only compatibility views for the existing UI, Challenge AI and executor.
# External serialization never exposes these v3 names.
var action: String:
	get:
		return kind
var params: Dictionary:
	get:
		return _legacy_params()
var terminal: bool:
	get:
		return ActionDefinitionRegistry.shared().is_terminal(kind)


func _init(
	p_action: String = "",
	p_params: Dictionary = {},
	p_terminal: bool = false,
	p_actor: int = -1,
	p_source: EntityRef = null,
	p_target: EntityRef = null,
	p_action_id: String = "",
	p_base_revision: int = -1,
	p_schema_version: int = SCHEMA_VERSION,
) -> void:
	kind = p_action
	payload = p_params.duplicate(true)
	actor = p_actor
	source = p_source
	target = p_target
	action_id = p_action_id
	base_revision = p_base_revision
	schema_version = p_schema_version
	# p_terminal is deliberately ignored; terminal is registry-derived.
	var _ignored_terminal := p_terminal


static func create(
	p_kind: String,
	p_payload: Dictionary,
	p_actor: int,
	p_source: EntityRef = null,
	p_target: EntityRef = null,
	p_action_id: String = "",
	p_base_revision: int = -1,
) -> GameAction:
	var result := GameAction.new(
		p_kind, p_payload, false, p_actor, p_source, p_target,
		p_action_id, p_base_revision, SCHEMA_VERSION)
	result._legacy_constructed = false
	return result


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


func is_legacy_constructed() -> bool:
	return _legacy_constructed


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
	if data.has("kind") or data.has("schema_version"):
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
	return GameAction.new(
		str(data.get("action", "")), Dictionary(data.get("params", {})),
		bool(data.get("terminal", false)), int(data.get("actor", -1)),
		EntityRef.from_dict(data["source"]) if data.get("source") is Dictionary else null,
		EntityRef.from_dict(data["target"]) if data.get("target") is Dictionary else null,
		str(data.get("action_id", "")), int(data.get("base_revision", -1)),
		int(data.get("schema_version", SCHEMA_VERSION)),
	)


func _legacy_params() -> Dictionary:
	var result := payload.duplicate(true)
	if source != null and source.kind == "card":
		if source.zone == "hand":
			_set_default(result, "hand_idx", source.index)
		elif source.zone == "discard" and kind == "USE_ABILITY":
			_set_default(result, "slot", "discard_%d" % source.index)
	if source != null and source.kind == "pokemon" and kind == "USE_ABILITY":
		_set_default(result, "slot", source.slot)
	if target != null:
		match kind:
			"PLAY_BASIC":
				_set_default(result, "target", target.slot)
			"EVOLVE":
				_set_default(result, "slot", target.slot)
			"ATTACH_ENERGY", "PLAY_TRAINER":
				_set_default(result, "target_slot", target.slot)
			"RETREAT", "PROMOTE":
				if target.slot.begins_with("bench_"):
					_set_default(result, "bench_idx", target.slot.trim_prefix("bench_").to_int())
	if payload.has("attack_index"):
		_set_default(result, "attack_idx", int(payload["attack_index"]))
	return result


static func _set_default(row: Dictionary, key: String, value: Variant) -> void:
	if not row.has(key):
		row[key] = value

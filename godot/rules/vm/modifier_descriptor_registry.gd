class_name VMModifierDescriptorRegistry
extends RefCounted

const REQUIRED_FIELDS: Array[String] = [
	"hook",
	"layer",
	"priority",
	"controller",
	"source_ref",
	"scope",
	"duration",
	"stacking",
	"conflict_policy",
	"condition",
	"operation",
]

const HOOK_LAYERS := {
	"MODIFY_DAMAGE": [
		"base_replacement", "attacker_adjust", "weakness", "resistance",
		"defender_adjust", "prevent", "clamp",
	],
	"MAX_HP": ["base", "add", "set", "clamp"],
	"CAN_RETREAT": ["base", "add", "set", "clamp"],
	"CAN_ATTACK": ["permission", "gate"],
	"PREVENT_EFFECTS": ["prevent"],
}

const OPERATION_DEFINITIONS := {
	"damage_delta": {
		"hook": "MODIFY_DAMAGE",
		"layers": ["attacker_adjust", "defender_adjust"],
		"keys": ["kind", "amount"],
		"integer_keys": ["amount"],
	},
	"prevent_damage": {
		"hook": "MODIFY_DAMAGE",
		"layers": ["prevent"],
		"keys": ["kind"],
		"integer_keys": [],
	},
	"hp_delta": {
		"hook": "MAX_HP",
		"layers": ["add"],
		"keys": ["kind", "amount"],
		"integer_keys": ["amount"],
	},
	"retreat_delta": {
		"hook": "CAN_RETREAT",
		"layers": ["add"],
		"keys": ["kind", "amount"],
		"integer_keys": ["amount"],
	},
	"retreat_set": {
		"hook": "CAN_RETREAT",
		"layers": ["set"],
		"keys": ["kind", "value"],
		"integer_keys": ["value"],
	},
	"attack_lock": {
		"hook": "CAN_ATTACK",
		"layers": ["permission"],
		"keys": ["kind", "attack_name"],
		"integer_keys": [],
	},
	"attack_gate_coin": {
		"hook": "CAN_ATTACK",
		"layers": ["gate"],
		"keys": ["kind", "reason"],
		"integer_keys": [],
	},
	"prevent_effects": {
		"hook": "PREVENT_EFFECTS",
		"layers": ["prevent"],
		"keys": ["kind"],
		"integer_keys": [],
	},
}

const SCOPES: Array[String] = [
	"self", "attached_attacker", "attached_defender", "active", "allied_board",
]
const DURATIONS: Array[String] = [
	"persistent", "until_leave_play", "until_switch_or_evolve",
	"until_end_of_turn", "until_end_of_opponents_next_turn", "until_next_attack",
]
const STACKING: Array[String] = ["stack", "replace_same_source", "maximum", "unique"]
const CONFLICT_POLICIES: Array[String] = ["commutative", "controller_choice"]
const CONDITION_TYPES := {
	"attacker_subtype": TYPE_STRING,
	"defender_type": TYPE_STRING,
	"requires_attached_energy": TYPE_BOOL,
	"energy_type": TYPE_STRING,
	"threshold": TYPE_INT,
	"behind_on_prizes": TYPE_BOOL,
	"target_stage": TYPE_STRING,
	"target_basic": TYPE_BOOL,
	"expires_after_turn": TYPE_INT,
}

static var _shared: VMModifierDescriptorRegistry

var _definitions: Dictionary = {}
var _frozen := false


func _init() -> void:
	for operation_kind in OPERATION_DEFINITIONS:
		register_definition(str(operation_kind), OPERATION_DEFINITIONS[operation_kind])
	freeze()


static func shared() -> VMModifierDescriptorRegistry:
	if _shared == null:
		_shared = VMModifierDescriptorRegistry.new()
	return _shared


func register_definition(operation_kind: String, definition: Dictionary) -> bool:
	if _frozen or operation_kind.is_empty() or _definitions.has(operation_kind):
		return false
	_definitions[operation_kind] = definition.duplicate(true)
	return true


func freeze() -> void:
	if _frozen:
		return
	for definition_value in _definitions.values():
		_deep_make_read_only(definition_value)
	_definitions.make_read_only()
	_frozen = true


func is_frozen() -> bool:
	return _frozen and _definitions.is_read_only()


func operation_kinds() -> Array[String]:
	var result: Array[String] = []
	for value in _definitions.keys():
		result.append(str(value))
	result.sort()
	return result


func validation_error(value: Variant) -> String:
	if not value is Dictionary:
		return "ModifierDescriptor必须是对象。"
	var descriptor: Dictionary = value
	if descriptor.size() != REQUIRED_FIELDS.size():
		return "ModifierDescriptor包含缺失或多余字段。"
	for field in REQUIRED_FIELDS:
		if not descriptor.has(field):
			return "ModifierDescriptor缺少字段：%s" % field
	if not descriptor.get("hook") is String or not HOOK_LAYERS.has(str(descriptor["hook"])):
		return "ModifierDescriptor hook无效。"
	if not descriptor.get("layer") is String:
		return "ModifierDescriptor layer类型无效。"
	var hook := str(descriptor["hook"])
	var layer := str(descriptor["layer"])
	if layer not in HOOK_LAYERS[hook]:
		return "ModifierDescriptor layer与hook不匹配。"
	if not descriptor.get("priority") is int:
		return "ModifierDescriptor priority必须是整数。"
	if int(descriptor["controller"]) not in [0, 1] or not descriptor.get("controller") is int:
		return "ModifierDescriptor controller无效。"
	var ref_error := EntityRef.validate_dict(descriptor.get("source_ref"))
	if not ref_error.is_empty():
		return "ModifierDescriptor source_ref无效：%s" % ref_error
	if not descriptor.get("scope") is String or str(descriptor["scope"]) not in SCOPES:
		return "ModifierDescriptor scope无效。"
	if not descriptor.get("duration") is String or str(descriptor["duration"]) not in DURATIONS:
		return "ModifierDescriptor duration无效。"
	if not descriptor.get("stacking") is String or str(descriptor["stacking"]) not in STACKING:
		return "ModifierDescriptor stacking无效。"
	if (
		not descriptor.get("conflict_policy") is String
		or str(descriptor["conflict_policy"]) not in CONFLICT_POLICIES
	):
		return "ModifierDescriptor conflict_policy无效。"
	if not descriptor.get("condition") is Dictionary:
		return "ModifierDescriptor condition必须是对象。"
	var condition: Dictionary = descriptor["condition"]
	for key_value in condition:
		var key := str(key_value)
		if not CONDITION_TYPES.has(key):
			return "ModifierDescriptor condition字段未知：%s" % key
		if typeof(condition[key]) != int(CONDITION_TYPES[key]):
			return "ModifierDescriptor condition字段%s类型无效。" % key
	if not descriptor.get("operation") is Dictionary:
		return "ModifierDescriptor operation必须是对象。"
	var operation: Dictionary = descriptor["operation"]
	var operation_kind := str(operation.get("kind", ""))
	if not _definitions.has(operation_kind):
		return "ModifierDescriptor operation未知：%s" % operation_kind
	var definition: Dictionary = _definitions[operation_kind]
	if hook != str(definition.get("hook", "")) or layer not in definition.get("layers", []):
		return "ModifierDescriptor operation与hook/layer不匹配。"
	var operation_keys: Array = definition.get("keys", [])
	if operation.size() != operation_keys.size():
		return "ModifierDescriptor operation包含缺失或多余字段。"
	for key in operation_keys:
		if not operation.has(key):
			return "ModifierDescriptor operation缺少字段：%s" % key
	for key in definition.get("integer_keys", []):
		if not operation.get(key) is int:
			return "ModifierDescriptor operation字段%s必须是整数。" % key
	for key in operation:
		if key == "kind" or key in definition.get("integer_keys", []):
			continue
		if not operation.get(key) is String:
			return "ModifierDescriptor operation字段%s必须是字符串。" % key
	return ""


# JSON has a single numeric type, so a relay roundtrip may decode integral
# descriptor fields as floats even though the authoritative runtime stores ints.
# Normalize only fields whose frozen contract explicitly declares integers;
# fractional, non-finite and out-of-range values remain invalid.
func wire_validation_error(value: Variant) -> String:
	if not value is Dictionary:
		return validation_error(value)
	var normalized: Dictionary = Dictionary(value).duplicate(true)
	for field in ["priority", "controller"]:
		if normalized.has(field) and _is_wire_integer(normalized[field]):
			normalized[field] = int(normalized[field])
	if normalized.get("condition") is Dictionary:
		var condition: Dictionary = normalized["condition"]
		for field in condition:
			if (
				CONDITION_TYPES.get(str(field), TYPE_NIL) == TYPE_INT
				and _is_wire_integer(condition[field])
			):
				condition[field] = int(condition[field])
	if normalized.get("operation") is Dictionary:
		var operation: Dictionary = normalized["operation"]
		var definition: Dictionary = _definitions.get(str(operation.get("kind", "")), {})
		for field in definition.get("integer_keys", []):
			if operation.has(field) and _is_wire_integer(operation[field]):
				operation[field] = int(operation[field])
	return validation_error(normalized)


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


static func _deep_make_read_only(value: Variant) -> void:
	if value is Dictionary:
		for nested in Dictionary(value).values():
			_deep_make_read_only(nested)
		Dictionary(value).make_read_only()
	elif value is Array:
		for nested in Array(value):
			_deep_make_read_only(nested)
		Array(value).make_read_only()

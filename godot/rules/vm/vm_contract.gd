class_name VMContract
extends RefCounted

const IR_VERSION := 3
const MAX_VM_STEPS := 4096
const MAX_FRAME_DEPTH := 64
const COMMAND_KEYS := ["op", "args", "branches"]
const SUPPORTED_EFFECT_TYPES: Array[String] = [
	"ability_discard_revive",
	"any_pokemon_damage",
	"arven",
	"apply_outgoing_damage_reduction",
	"attach_from_discard",
	"attack_fail",
	"attack_flags",
	"attack_damage_formula",
	"attack_lock_basic",
	"aura_damage_reduction",
	"aura_damage_boost",
	"bench_damage",
	"clara",
	"coin_flip",
	"coin_flip_double_ko",
	"coin_flip_energy_discard",
	"coin_flip_triple",
	"coin_flip_until_tails",
	"conditional",
	"conditional_damage_bonus",
	"conditional_damage_heal",
	"conditional_hp_boost",
	"conditional_search_extra",
	"conditional_status",
	"conditional_zero_retreat",
	"damage",
	"damage_and_self_heal",
	"damage_counter_self",
	"damage_per_discard_psychic",
	"damage_per_energy",
	"damage_per_evolved",
	"damage_per_hand_size",
	"damage_per_self_damage",
	"damage_per_self_energy",
	"damage_per_self_energy_type",
	"damage_plus_bench",
	"damage_self_penalty",
	"dazzling_beam",
	"discard",
	"discard_draw",
	"discard_fighting_energy_damage",
	"discard_hand_conditional_bonus",
	"discard_then_draw",
	"draw",
	"draw_and_attach_energy",
	"draw_until",
	"draw_until_more",
	"energy_attach",
	"energy_discard",
	"energy_relocate",
	"evolve_skip_stage",
	"hand_to_bottom_draw",
	"heal",
	"heal_all",
	"houb",
	"judge",
	"look_top_deck",
	"look_top_attach_energy",
	"mill_and_damage_per_energy",
	"place_counters_and_self_ko",
	"potion_heal",
	"prevent_all",
	"prevent_damage",
	"prevent_effects",
	"reactive_thorns",
	"return_to_hand",
	"search",
	"search_any_and_switch",
	"self_attack_lock",
	"shuffle_draw",
	"shuffle_from_discard",
	"status",
	"switch_opponent",
	"switch_self",
	"tool",
	"tool_exp_share",
	"trekking_shoes",
	"zinnia_resolve",
]
const DESCRIPTOR_PATH := "res://data/vm_command_descriptors.json"
const DESCRIPTOR_SCHEMA_VERSION := 1
const BRANCH_KEYS := {
	"cost": true,
	"on_heads": true,
	"on_tails": true,
	"on_pay": true,
	"on_success": true,
	"on_fail": true,
	"on_failure": true,
}

static var _descriptor_payload: Dictionary = {}
static var _descriptor_load_attempted := false
static var _descriptor_load_error := ""


static func supports_effect_type(effect_type: String) -> bool:
	return effect_type in SUPPORTED_EFFECT_TYPES


static func native_command_ops() -> Array[String]:
	var result: Array[String] = []
	var descriptors: Variant = _load_descriptor_payload().get("descriptors", {})
	if not descriptors is Dictionary:
		return result
	for op_value in Dictionary(descriptors):
		result.append(str(op_value))
	result.sort()
	return result


static func command_descriptor(op: String) -> Dictionary:
	var native := _native_descriptor(op)
	if not native.is_empty():
		return native.duplicate(true)
	# Test harnesses may build a closed custom registry. Production commands
	# always come from the generated descriptor payload above.
	return {
		"op": op,
		"args_schema": {
			"type": "object",
			"properties": {},
			"required": [],
			"additional_properties": false,
		},
		"branch_schema": {
			"type": "object",
			"allowed_keys": [],
			"required": [],
			"additional_properties": false,
		},
		"semantic_kind": "test_only",
		"allowed_contexts": ["ability", "attack", "trainer", "trigger", "test"],
		"attack_timing": "none",
		"preflight_evaluator": "always",
		"may_suspend": false,
		"replaces_base_damage": false,
		"internal": false,
		"implementation_kind": "test_only",
		"requires_boolean_success": true,
	}


static func native_command_descriptors() -> Dictionary:
	var payload := _load_descriptor_payload()
	var descriptors: Variant = payload.get("descriptors", {})
	if not descriptors is Dictionary:
		return {}
	return Dictionary(descriptors).duplicate(true)


static func golden_command_ops() -> Array[String]:
	var payload := _load_descriptor_payload()
	var raw: Variant = payload.get("golden_ops", [])
	var result: Array[String] = []
	if not raw is Array:
		return result
	for value in Array(raw):
		if not value is String or str(value).is_empty():
			return []
		result.append(str(value))
	result.sort()
	return result


static func descriptor_load_error() -> String:
	_load_descriptor_payload()
	return _descriptor_load_error


static func command_semantic_kind(op: String) -> String:
	return str(_native_descriptor(op).get("semantic_kind", ""))


static func command_preflight_evaluator(op: String) -> String:
	return str(_native_descriptor(op).get("preflight_evaluator", ""))


static func command_attack_timing(op: String) -> String:
	return str(_native_descriptor(op).get("attack_timing", "none"))


static func command_replaces_base_damage(op: String, args: Dictionary = {}) -> bool:
	var descriptor := _native_descriptor(op)
	if descriptor.is_empty():
		return false
	var replacement: Variant = descriptor.get(
		"replaces_base_damage", false)
	if replacement is bool:
		return bool(replacement)
	return str(replacement) == "when_formula_ast" and args.has("formula_ast")


static func _native_descriptor(op: String) -> Dictionary:
	var payload := _load_descriptor_payload()
	var descriptors: Variant = payload.get("descriptors", {})
	if not descriptors is Dictionary or not Dictionary(descriptors).has(op):
		return {}
	return Dictionary(Dictionary(descriptors)[op])


static func _load_descriptor_payload() -> Dictionary:
	if _descriptor_load_attempted:
		return _descriptor_payload
	_descriptor_load_attempted = true
	if not FileAccess.file_exists(DESCRIPTOR_PATH):
		_descriptor_load_error = "VM descriptor payload is missing: %s" % DESCRIPTOR_PATH
		return {}
	var file := FileAccess.open(DESCRIPTOR_PATH, FileAccess.READ)
	if file == null:
		_descriptor_load_error = "VM descriptor payload cannot be opened: %s" % DESCRIPTOR_PATH
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_descriptor_load_error = "VM descriptor payload must be a dictionary"
		return {}
	var payload := Dictionary(parsed)
	if int(payload.get("descriptor_schema_version", 0)) != DESCRIPTOR_SCHEMA_VERSION:
		_descriptor_load_error = "VM descriptor schema version is incompatible"
		return {}
	if int(payload.get("vm_ir_version", 0)) != IR_VERSION:
		_descriptor_load_error = "VM descriptor IR version is incompatible"
		return {}
	if str(payload.get("digest_algorithm", "")) != "sha256":
		_descriptor_load_error = "VM descriptor digest algorithm is unsupported"
		return {}
	var descriptors: Variant = payload.get("descriptors")
	if not descriptors is Dictionary or Dictionary(descriptors).is_empty():
		_descriptor_load_error = "VM descriptor inventory is empty"
		return {}
	var golden_ops: Variant = payload.get("golden_ops")
	if not golden_ops is Array:
		_descriptor_load_error = "VM golden inventory is missing"
		return {}
	var descriptor_ops: Array[String] = []
	for op_value in Dictionary(descriptors):
		descriptor_ops.append(str(op_value))
	descriptor_ops.sort()
	var published_golden_ops: Array[String] = []
	for op_value in Array(golden_ops):
		if not op_value is String:
			_descriptor_load_error = "VM golden inventory contains a non-string op"
			return {}
		published_golden_ops.append(str(op_value))
	published_golden_ops.sort()
	if published_golden_ops != descriptor_ops:
		_descriptor_load_error = "VM golden and descriptor inventories differ"
		return {}
	_descriptor_payload = payload.duplicate(true)
	return _descriptor_payload


static func validate_command_descriptor(
	op: String,
	descriptor: Dictionary,
) -> Array[String]:
	var errors: Array[String] = []
	var allowed_keys := {
		"op": true,
		"args_schema": true,
		"branch_schema": true,
		"semantic_kind": true,
		"allowed_contexts": true,
		"attack_timing": true,
		"preflight_evaluator": true,
		"may_suspend": true,
		"replaces_base_damage": true,
		"internal": true,
		"implementation_kind": true,
		"requires_boolean_success": true,
	}
	for key_value in descriptor:
		if not allowed_keys.has(str(key_value)):
			errors.append("descriptor has unknown field for %s: %s" % [op, key_value])
	if op.is_empty():
		errors.append("descriptor op must be non-empty")
	if str(descriptor.get("op", "")) != op:
		errors.append("descriptor op mismatch for %s" % op)
	var args: Variant = descriptor.get("args_schema")
	if (
		not args is Dictionary
		or str(Dictionary(args).get("type", "")) != "object"
		or not Dictionary(args).get("properties", {}) is Dictionary
		or not Dictionary(args).get("required", []) is Array
		or Dictionary(args).get("additional_properties", true) != false
	):
		errors.append("descriptor args_schema is invalid for %s" % op)
	else:
		var properties := Dictionary(args).get("properties", {}) as Dictionary
		for required_value in Dictionary(args).get("required", []):
			if not properties.has(str(required_value)):
				errors.append("descriptor requires unknown arg for %s: %s" % [op, required_value])
		for property_value in properties:
			var property_schema: Variant = properties[property_value]
			if not property_schema is Dictionary or not Dictionary(property_schema).has("type"):
				errors.append("descriptor arg schema is invalid for %s.%s" % [op, property_value])
			else:
				errors.append_array(_validate_field_descriptor(
					Dictionary(property_schema), "%s.%s" % [op, property_value]))
	var branches: Variant = descriptor.get("branch_schema")
	if (
		not branches is Dictionary
		or str(Dictionary(branches).get("type", "")) != "object"
		or not Dictionary(branches).get("allowed_keys", []) is Array
		or not Dictionary(branches).get("required", []) is Array
		or Dictionary(branches).get("additional_properties", true) != false
	):
		errors.append("descriptor branch_schema is invalid for %s" % op)
	else:
		var allowed_branches: Array = Dictionary(branches).get("allowed_keys", [])
		for branch_value in allowed_branches:
			if not BRANCH_KEYS.has(str(branch_value)):
				errors.append("descriptor branch key is unknown for %s: %s" % [
					op, branch_value])
		for required_branch_value in Dictionary(branches).get("required", []):
			if not allowed_branches.has(required_branch_value):
				errors.append("descriptor requires unknown branch for %s: %s" % [
					op, required_branch_value])
	if str(descriptor.get("semantic_kind", "")).is_empty():
		errors.append("descriptor semantic_kind is missing for %s" % op)
	if str(descriptor.get("preflight_evaluator", "")).is_empty():
		errors.append("descriptor preflight evaluator is missing for %s" % op)
	if not descriptor.get("allowed_contexts", []) is Array or Array(
		descriptor.get("allowed_contexts", [])).is_empty():
		errors.append("descriptor contexts are invalid for %s" % op)
	else:
		for context_value in descriptor.get("allowed_contexts", []):
			if str(context_value) not in ["ability", "attack", "trainer", "trigger", "test"]:
				errors.append("descriptor context is unknown for %s: %s" % [op, context_value])
	if str(descriptor.get("attack_timing", "")) not in [
		"none", "pre_damage", "damage", "replace_damage", "post_damage",
	]:
		errors.append("descriptor attack timing is invalid for %s" % op)
	if str(descriptor.get("implementation_kind", "")) not in [
		"atomic", "control", "native_composite", "test_only",
	]:
		errors.append("descriptor implementation kind is invalid for %s" % op)
	if not descriptor.get("may_suspend") is bool:
		errors.append("descriptor may_suspend is invalid for %s" % op)
	if not descriptor.get("internal") is bool:
		errors.append("descriptor internal is invalid for %s" % op)
	var replacement: Variant = descriptor.get("replaces_base_damage")
	if not replacement is bool and not replacement is String:
		errors.append("descriptor replacement contract is invalid for %s" % op)
	elif replacement is String and str(replacement) != "when_formula_ast":
		errors.append("descriptor replacement mode is invalid for %s" % op)
	if descriptor.get("requires_boolean_success") != true:
		errors.append("descriptor result contract is invalid for %s" % op)
	return errors


static func _validate_field_descriptor(schema: Dictionary, path: String) -> Array[String]:
	var errors: Array[String] = []
	var type_value: Variant = schema.get("type")
	var type_values: Array = type_value if type_value is Array else [type_value]
	if type_values.is_empty():
		errors.append("descriptor field type is empty for %s" % path)
	for item in type_values:
		if str(item) not in ["integer", "number", "string", "boolean", "object", "array"]:
			errors.append("descriptor field type is unknown for %s: %s" % [path, item])
	if schema.has("enum") and not schema["enum"] is Array:
		errors.append("descriptor field enum must be an array for %s" % path)
	if schema.has("minimum") and not schema["minimum"] is int and not schema["minimum"] is float:
		errors.append("descriptor field minimum must be numeric for %s" % path)
	if schema.has("maximum") and not schema["maximum"] is int and not schema["maximum"] is float:
		errors.append("descriptor field maximum must be numeric for %s" % path)
	if schema.has("items"):
		if not schema["items"] is Dictionary:
			errors.append("descriptor array items must be a schema for %s" % path)
		else:
			errors.append_array(_validate_field_descriptor(
				Dictionary(schema["items"]), "%s[]" % path))
	return errors


static func validate_command_registry(
	descriptors: Dictionary,
	handlers: Dictionary,
	expected_ops: Array = [],
) -> Array[String]:
	var errors: Array[String] = []
	var expected: Dictionary = {}
	for op_value in expected_ops:
		var op := str(op_value)
		if expected.has(op):
			errors.append("duplicate expected VM op: %s" % op)
		expected[op] = true
	if expected.is_empty():
		for op_value in descriptors:
			expected[str(op_value)] = true

	var descriptor_ops: Array[String] = []
	for op_value in descriptors:
		descriptor_ops.append(str(op_value))
	descriptor_ops.sort()
	for op in descriptor_ops:
		errors.append_array(validate_command_descriptor(op, Dictionary(descriptors[op])))
		if not expected.has(op):
			errors.append("unexpected VM command descriptor: %s" % op)
		if not handlers.has(op):
			errors.append("VM command descriptor is missing a handler: %s" % op)

	var handler_ops: Array[String] = []
	for op_value in handlers:
		handler_ops.append(str(op_value))
	handler_ops.sort()
	for op in handler_ops:
		if not descriptors.has(op):
			errors.append("VM command handler is missing a descriptor: %s" % op)

	var expected_names: Array[String] = []
	for op_value in expected:
		expected_names.append(str(op_value))
	expected_names.sort()
	for op in expected_names:
		if not descriptors.has(op):
			errors.append("expected VM command descriptor is missing: %s" % op)
	return errors


static func validate_command_spec(
	spec: Dictionary,
	supported_ops: Dictionary = {},
	path: String = "$",
	descriptors: Dictionary = {},
	execution_context: String = "",
) -> Array[String]:
	var errors: Array[String] = []
	for key_value in spec:
		if str(key_value) not in COMMAND_KEYS:
			errors.append("%s has unknown field: %s" % [path, key_value])
	var op := str(spec.get("op", ""))
	if op.is_empty():
		errors.append("%s.op must be a non-empty string" % path)
	elif not supported_ops.is_empty() and not supported_ops.has(op):
		errors.append("%s.op is unsupported: %s" % [path, op])
	var descriptor_table := descriptors
	if descriptor_table.is_empty():
		descriptor_table = native_command_descriptors()
	var descriptor: Dictionary = {}
	if not op.is_empty():
		if not descriptor_table.has(op):
			errors.append("%s.op has no command descriptor: %s" % [path, op])
		else:
			descriptor = Dictionary(descriptor_table[op])
			if (
				not execution_context.is_empty()
				and not Array(descriptor.get(
					"allowed_contexts", [])).has(execution_context)
			):
				errors.append("%s.op is not allowed in %s context: %s" % [
					path, execution_context, op])

	var args: Variant = spec.get("args", {})
	if not args is Dictionary:
		errors.append("%s.args must be a dictionary" % path)
	elif Dictionary(args).has("effect_type"):
		errors.append("%s.args must not contain legacy effect_type" % path)
	elif not descriptor.is_empty():
		errors.append_array(_validate_object_schema(
			Dictionary(args),
			Dictionary(descriptor.get("args_schema", {})),
			"%s.args" % path,
		))

	var branches: Variant = spec.get("branches", {})
	if not branches is Dictionary:
		errors.append("%s.branches must be a dictionary" % path)
		return errors
	var allowed_branches: Dictionary = {}
	if not descriptor.is_empty():
		var branch_schema := Dictionary(descriptor.get("branch_schema", {}))
		for key_value in branch_schema.get("allowed_keys", []):
			allowed_branches[str(key_value)] = true
		for required_value in branch_schema.get("required", []):
			if not Dictionary(branches).has(str(required_value)):
				errors.append("%s.branches is missing required field: %s" % [
					path, required_value])

	for branch_name in Dictionary(branches):
		var branch_key := str(branch_name)
		if (
			(not descriptor.is_empty() and not allowed_branches.has(branch_key))
			or (descriptor.is_empty() and not BRANCH_KEYS.has(branch_key))
		):
			errors.append("%s.branches has unknown field: %s" % [path, branch_key])
		var branch_items: Variant = Dictionary(branches)[branch_name]
		if not branch_items is Array:
			errors.append("%s.branches.%s must be an array" % [path, branch_key])
			continue
		for index in range(Array(branch_items).size()):
			var item: Variant = Array(branch_items)[index]
			if not item is Dictionary:
				errors.append("%s.branches.%s[%d] must be a dictionary" % [
					path, branch_key, index])
				continue
			errors.append_array(validate_command_spec(
				Dictionary(item),
				supported_ops,
				"%s.branches.%s[%d]" % [path, branch_key, index],
				descriptor_table,
				execution_context,
			))
	return errors


static func _validate_object_schema(
	value: Dictionary,
	schema: Dictionary,
	path: String,
) -> Array[String]:
	var errors: Array[String] = []
	var properties: Variant = schema.get("properties", {})
	if not properties is Dictionary:
		return ["%s descriptor properties must be a dictionary" % path]
	for key_value in value:
		var key := str(key_value)
		if not Dictionary(properties).has(key):
			errors.append("%s has unknown field: %s" % [path, key])
			continue
		var field_schema: Variant = Dictionary(properties)[key]
		if field_schema is Dictionary:
			errors.append_array(_validate_field_schema(
				value[key_value], Dictionary(field_schema), "%s.%s" % [path, key]))
	for required_value in schema.get("required", []):
		if not value.has(str(required_value)):
			errors.append("%s is missing required field: %s" % [path, required_value])
	return errors


static func _validate_field_schema(
	value: Variant,
	schema: Dictionary,
	path: String,
) -> Array[String]:
	var expected: Variant = schema.get("type")
	var expected_types: Array = expected if expected is Array else [expected]
	var matches := false
	for expected_value in expected_types:
		if _matches_schema_type(value, str(expected_value)):
			matches = true
			break
	if not matches:
		return ["%s has invalid type; expected %s" % [path, JSON.stringify(expected)]]
	if schema.has("enum") and not Array(schema.get("enum", [])).has(value):
		return ["%s has invalid enum value" % path]
	if (value is int or value is float) and not value is bool:
		if schema.has("minimum") and float(value) < float(schema["minimum"]):
			return ["%s is below minimum" % path]
		if schema.has("maximum") and float(value) > float(schema["maximum"]):
			return ["%s is above maximum" % path]
	if value is Array and schema.get("items") is Dictionary:
		var errors: Array[String] = []
		for index in range(Array(value).size()):
			errors.append_array(_validate_field_schema(
				Array(value)[index], Dictionary(schema["items"]), "%s[%d]" % [path, index]))
		return errors
	return []


static func _matches_schema_type(value: Variant, expected: String) -> bool:
	match expected:
		"integer":
			return (
				value is int
				or (value is float and is_finite(float(value)) and float(value) == floor(float(value)))
			)
		"number":
			return (value is int or value is float) and not value is bool
		"string":
			return value is String
		"boolean":
			return value is bool
		"object":
			return value is Dictionary
		"array":
			return value is Array
	return false

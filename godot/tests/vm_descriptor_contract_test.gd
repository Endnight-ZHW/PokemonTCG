extends SceneTree

const FIXTURE_PATH := "res://tests/fixtures/vm_native_golden.json"

var failures: Array[String] = []


func _initialize() -> void:
	_run_tests()
	if failures.is_empty():
		print("VM_DESCRIPTOR_CONTRACT_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	var descriptors := VMContract.native_command_descriptors()
	var ops := VMContract.native_command_ops()
	var fixture := _read_json(FIXTURE_PATH)
	var cases: Dictionary = fixture.get("cases", {})
	var supported: Dictionary = {}
	for op_value in ops:
		supported[str(op_value)] = true
	_check(
		descriptors.size() == 80
		and ops.size() == 80
		and cases.size() == 80
		and VMContract.descriptor_load_error().is_empty(),
		"generated VM descriptor inventory did not load as 80 ops",
	)

	var evaluators: Dictionary = {}
	var typed_cases := 0
	var required_cases := 0
	for op_value in ops:
		var op := str(op_value)
		var descriptor := Dictionary(descriptors.get(op, {}))
		var descriptor_errors := VMContract.validate_command_descriptor(op, descriptor)
		_check(descriptor_errors.is_empty(),
			"invalid descriptor for %s: %s" % [op, "; ".join(descriptor_errors)])
		evaluators[str(descriptor.get("preflight_evaluator", ""))] = true
		var spec := Dictionary(Dictionary(cases.get(op, {})).get("command_spec", {}))
		_check(
			VMContract.validate_command_spec(
				spec, supported, "$", descriptors).is_empty(),
			"golden command spec failed strict descriptor validation: %s" % op,
		)
		_check(
			not VMContract.validate_command_spec(
				spec, supported, "$", descriptors, "__invalid__").is_empty(),
			"descriptor accepted an unsupported execution context: %s" % op,
		)

		var extra_arg := spec.duplicate(true)
		var extra_args := Dictionary(extra_arg.get("args", {}))
		extra_args["__extra__"] = 1
		extra_arg["args"] = extra_args
		_check(
			not VMContract.validate_command_spec(
				extra_arg, supported, "$", descriptors).is_empty(),
			"descriptor accepted an extra arg: %s" % op,
		)

		var extra_branch := spec.duplicate(true)
		var extra_branches := Dictionary(extra_branch.get("branches", {}))
		extra_branches["__extra__"] = []
		extra_branch["branches"] = extra_branches
		_check(
			not VMContract.validate_command_spec(
				extra_branch, supported, "$", descriptors).is_empty(),
			"descriptor accepted an extra branch: %s" % op,
		)

		var args_schema := Dictionary(descriptor.get("args_schema", {}))
		var properties := Dictionary(args_schema.get("properties", {}))
		if not properties.is_empty():
			typed_cases += 1
			var property_key := str(properties.keys()[0])
			var property_schema := Dictionary(properties[property_key])
			var wrong_type_spec := spec.duplicate(true)
			var wrong_args := Dictionary(wrong_type_spec.get("args", {}))
			wrong_args[property_key] = _wrong_type(property_schema.get("type"))
			wrong_type_spec["args"] = wrong_args
			_check(
				not VMContract.validate_command_spec(
					wrong_type_spec, supported, "$", descriptors).is_empty(),
				"descriptor accepted a wrong arg type: %s.%s" % [op, property_key],
			)
		var required: Array = args_schema.get("required", [])
		if not required.is_empty():
			required_cases += 1
			var missing_spec := spec.duplicate(true)
			var missing_args := Dictionary(missing_spec.get("args", {}))
			missing_args.erase(str(required[0]))
			missing_spec["args"] = missing_args
			_check(
				not VMContract.validate_command_spec(
					missing_spec, supported, "$", descriptors).is_empty(),
				"descriptor accepted a missing required arg: %s" % op,
			)
	_check(typed_cases > 0 and required_cases > 0,
		"descriptor negative generation did not cover typed/required args")

	var availability := VMAvailability.new(CardCatalog.shared())
	var registered_evaluators: Dictionary = {}
	for evaluator_value in availability.preflight_evaluator_names():
		registered_evaluators[str(evaluator_value)] = true
	_check(_same_keys(evaluators, registered_evaluators),
		"descriptor preflight classifications and evaluator registry differ")

	var state := GameState.new()
	var ordinary := availability.preflight_effects(
		state,
		0,
		[{"op": "deal_damage", "args": {"amount": 10}, "branches": {}}],
	)
	_check(
		bool(ordinary.get("ok", false))
		and not bool(ordinary.get("legal", true))
		and str(ordinary.get("error_code", "")).is_empty(),
		"ordinary target illegality was reported as a VM contract error",
	)
	var malformed := availability.preflight_effects(
		state,
		0,
		[{"op": "draw_cards", "args": {"unknown": 1}, "branches": {}}],
	)
	_check(
		not bool(malformed.get("ok", true))
		and not bool(malformed.get("legal", true))
		and str(malformed.get("error_code", "")) == "invalid_vm_spec",
		"malformed VM preflight did not fail closed with invalid_vm_spec",
	)
	var unknown := availability.preflight_effects(
		state,
		0,
		[{"op": "__unknown__", "args": {}, "branches": {}}],
	)
	_check(
		not bool(unknown.get("ok", true))
		and str(unknown.get("error_code", "")) == "invalid_vm_spec",
		"unknown VM op was treated as an ordinary legal/illegal candidate",
	)
	var internal := availability.preflight_effects(
		state,
		0,
		[{
			"op": "trigger_draw_cards",
			"args": {"amount": 1, "player": 0, "source": "test"},
			"branches": {},
		}],
	)
	_check(
		not bool(internal.get("ok", true))
		and str(internal.get("error_code", "")) == "internal_vm_op",
		"internal VM op was exposed through public card preflight",
	)


func _wrong_type(expected: Variant) -> Variant:
	var types: Array = expected if expected is Array else [expected]
	match str(types[0]):
		"integer", "number":
			return "wrong"
		"string":
			return 123
		"boolean":
			return "wrong"
		"object":
			return []
		"array":
			return {}
	return null


func _same_keys(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for key_value in left:
		if not right.has(key_value):
			return false
	return true


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("missing fixture: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		failures.append("invalid fixture: %s" % path)
		return {}
	return Dictionary(parsed)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

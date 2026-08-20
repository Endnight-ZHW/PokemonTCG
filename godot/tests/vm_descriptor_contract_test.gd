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

	var typed_cases := 0
	var required_cases := 0
	for op_value in ops:
		var op := str(op_value)
		var descriptor := Dictionary(descriptors.get(op, {}))
		var descriptor_errors := VMContract.validate_command_descriptor(op, descriptor)
		_check(descriptor_errors.is_empty(),
			"invalid descriptor for %s: %s" % [op, "; ".join(descriptor_errors)])
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

class_name VMCommandRegistry
extends RefCounted

var _ops: Dictionary = {}
var _descriptors: Dictionary = {}
var _handlers: Dictionary = {}
var _frozen := false
var _registration_errors: Array[String] = []


func register_descriptor(op: String, descriptor: Dictionary) -> bool:
	if _frozen:
		return false
	if op.is_empty():
		_record_registration_error("VM op name must be non-empty")
		return false
	if _ops.has(op):
		_record_registration_error("Duplicate VM op registration: %s" % op)
		return false
	var descriptor_errors := VMContract.validate_command_descriptor(op, descriptor)
	if not descriptor_errors.is_empty():
		_record_registration_error(
			"Invalid VM command descriptor: %s" % "; ".join(descriptor_errors))
		return false
	_ops[op] = true
	_descriptors[op] = descriptor.duplicate(true)
	return true


func register_descriptors(descriptors: Dictionary) -> bool:
	var registered_all := true
	for op_value in descriptors:
		var op := str(op_value)
		if not register_descriptor(op, Dictionary(descriptors[op_value])):
			registered_all = false
	return registered_all


func register_op(op: String, handler: Callable = Callable()) -> bool:
	if not register_descriptor(op, VMContract.command_descriptor(op)):
		return false
	if handler.is_valid():
		_handlers[op] = handler
	return true


func register_many(ops: Array) -> bool:
	var registered_all := true
	for op_value in ops:
		if not register_op(str(op_value)):
			registered_all = false
	return registered_all


func register_handler(op: String, handler: Callable) -> bool:
	if _frozen:
		return false
	if op.is_empty():
		_record_registration_error("VM op name must be non-empty")
		return false
	if not handler.is_valid():
		_record_registration_error("VM command handler must be valid: %s" % op)
		return false
	if not _ops.has(op):
		_record_registration_error("VM command handler has no descriptor: %s" % op)
		return false
	if _handlers.has(op):
		_record_registration_error("Duplicate VM command handler registration: %s" % op)
		return false
	_handlers[op] = handler
	return true


func freeze(expected_ops: Array = []) -> Array[String]:
	if _frozen:
		return []
	var errors := _registration_errors.duplicate()
	errors.append_array(VMContract.validate_command_registry(
		_descriptors,
		_handlers,
		expected_ops,
	))
	if errors.is_empty():
		_frozen = true
	return errors


func is_frozen() -> bool:
	return _frozen


func supports_op(op: String) -> bool:
	return _ops.has(op)


func has_handler(op: String) -> bool:
	return _handlers.has(op)


func supported_ops() -> Dictionary:
	return _ops.duplicate()


func descriptors() -> Dictionary:
	return _descriptors.duplicate(true)


func descriptor(op: String) -> Dictionary:
	if not _descriptors.has(op):
		return {}
	return Dictionary(_descriptors[op]).duplicate(true)


func validate_spec(spec: Dictionary, execution_context: String = "") -> Array[String]:
	return VMContract.validate_command_spec(
		spec,
		_ops,
		"$",
		_descriptors,
		execution_context,
	)


func registration_errors() -> Array[String]:
	return _registration_errors.duplicate()


func _record_registration_error(message: String) -> void:
	_registration_errors.append(message)


func execute(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	spec: Dictionary,
	player_idx: int,
	source_slot: String,
	events: Array[Dictionary]
) -> Dictionary:
	var op := str(spec.get("op", ""))
	if not _frozen:
		var not_ready := VMResult.fail(
			"VM指令注册表尚未冻结。",
			"vm_registry_not_ready",
		)
		not_ready["_handled"] = false
		return not_ready
	if not _ops.has(op) or not _handlers.has(op):
		var unsupported := VMResult.fail(
			"不支持的VM指令: %s" % op,
			"unsupported_vm_op",
		)
		unsupported["_handled"] = false
		return unsupported
	var spec_errors := validate_spec(spec)
	if not spec_errors.is_empty():
		var invalid := VMResult.fail(
			"VM指令结构无效: %s" % "; ".join(spec_errors),
			"invalid_vm_spec",
		)
		invalid["_handled"] = true
		return invalid
	var result: Variant = Callable(_handlers[op]).call(
		state,
		stack,
		rng,
		Dictionary(spec.get("args", {})),
		Dictionary(spec.get("branches", {})),
		player_idx,
		source_slot,
		events,
	)
	var outcome := VMResult.require_explicit(result, "command:%s" % op)
	outcome["_handled"] = true
	return outcome

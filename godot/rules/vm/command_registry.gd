class_name VMCommandRegistry
extends RefCounted

var _ops: Dictionary = {}
var _handlers: Dictionary = {}


func register_op(op: String, handler: Callable = Callable()) -> void:
	if op.is_empty():
		push_error("VM op name must be non-empty")
		return
	_ops[op] = true
	if handler.is_valid():
		_handlers[op] = handler


func register_many(ops: Array) -> void:
	for op_value in ops:
		register_op(str(op_value))


func register_handler(op: String, handler: Callable) -> void:
	if op.is_empty():
		push_error("VM op name must be non-empty")
		return
	if not handler.is_valid():
		push_error("VM command handler must be valid: %s" % op)
		return
	_ops[op] = true
	_handlers[op] = handler


func supports_op(op: String) -> bool:
	return _ops.has(op)


func has_handler(op: String) -> bool:
	return _handlers.has(op)


func supported_ops() -> Dictionary:
	return _ops.duplicate()


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
	if not _ops.has(op) or not _handlers.has(op):
		return {"_handled": false}
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
	if result is Dictionary:
		result["_handled"] = true
		return result
	return {"_handled": true, "success": true, "message": ""}

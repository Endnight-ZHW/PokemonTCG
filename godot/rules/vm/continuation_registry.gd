class_name VMContinuationRegistry
extends RefCounted

var _handlers: Dictionary = {}


func register(operation: String, handler: Callable) -> void:
	if operation.is_empty():
		push_error("VM continuation name must be non-empty")
		return
	if not handler.is_valid():
		push_error("VM continuation handler must be valid: %s" % operation)
		return
	_handlers[operation] = handler


func supports(operation: String) -> bool:
	return _handlers.has(operation)


func supported_operations() -> Dictionary:
	return _handlers.duplicate()


func execute(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	operation: String,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary]
) -> Dictionary:
	if not _handlers.has(operation):
		return VMResult.fail("未知续执行操作: %s" % operation, "unknown_continuation")
	var result: Variant = Callable(_handlers[operation]).call(
		state, stack, rng, data, selected, events)
	if result is Dictionary:
		return result
	return VMResult.ok()

class_name VMContinuationRegistry
extends RefCounted

var _handlers: Dictionary = {}
var _frozen := false
var _registration_errors: Array[String] = []


func register(operation: String, handler: Callable) -> bool:
	if _frozen:
		return false
	if operation.is_empty():
		_record_registration_error("VM continuation name must be non-empty")
		return false
	if not handler.is_valid():
		_record_registration_error("VM continuation handler must be valid: %s" % operation)
		return false
	if _handlers.has(operation):
		_record_registration_error("Duplicate VM continuation registration: %s" % operation)
		return false
	_handlers[operation] = handler
	return true


func freeze() -> Array[String]:
	if _frozen:
		return []
	if _registration_errors.is_empty():
		_frozen = true
	return _registration_errors.duplicate()


func is_frozen() -> bool:
	return _frozen


func supports(operation: String) -> bool:
	return _handlers.has(operation)


func supported_operations() -> Dictionary:
	return _handlers.duplicate()


func registration_errors() -> Array[String]:
	return _registration_errors.duplicate()


func _record_registration_error(message: String) -> void:
	_registration_errors.append(message)


func execute(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	operation: String,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary]
) -> Dictionary:
	if not _frozen:
		return VMResult.fail(
			"VM续执行注册表尚未冻结。",
			"vm_registry_not_ready",
		)
	if not _handlers.has(operation):
		return VMResult.fail("未知续执行操作: %s" % operation, "unknown_continuation")
	var result: Variant = Callable(_handlers[operation]).call(
		state, stack, rng, data, selected, events)
	return VMResult.require_explicit(result, "continuation:%s" % operation)

class_name MotionGroup
extends RefCounted

signal completed(group: MotionGroup)

var _handles: Array[MotionHandle] = []
var _sealed := false
var _completed := false


func add(handle: MotionHandle) -> void:
	if handle == null or _sealed or _completed:
		return
	_handles.append(handle)
	if not handle.completed.is_connected(_on_handle_completed):
		handle.completed.connect(_on_handle_completed, CONNECT_ONE_SHOT)
	_try_complete()


func seal() -> void:
	_sealed = true
	_try_complete()


func cancel() -> void:
	if _completed:
		return
	_sealed = true
	for handle in _handles.duplicate():
		if handle != null:
			handle.cancel()
	_try_complete()


func is_completed() -> bool:
	return _completed


func pending_count() -> int:
	var result := 0
	for handle in _handles:
		if handle != null and not handle.is_finished():
			result += 1
	return result


func _on_handle_completed(_handle: MotionHandle) -> void:
	_try_complete()


func _try_complete() -> void:
	if _completed or not _sealed or pending_count() > 0:
		return
	_completed = true
	completed.emit(self)

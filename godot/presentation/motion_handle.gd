class_name MotionHandle
extends RefCounted

signal completed(handle: MotionHandle)

const RUNNING := "running"
const COMPLETED := "completed"
const CANCELLED := "cancelled"

var status := RUNNING
var tween: Tween


func bind_tween(value: Tween) -> MotionHandle:
	tween = value
	if tween == null or not tween.is_valid():
		finish()
	elif not tween.finished.is_connected(_on_tween_finished):
		tween.finished.connect(_on_tween_finished, CONNECT_ONE_SHOT)
	return self


func is_finished() -> bool:
	return status != RUNNING


func finish() -> void:
	if is_finished():
		return
	status = COMPLETED
	completed.emit(self)


func cancel() -> void:
	if is_finished():
		return
	if tween != null and tween.is_valid():
		tween.kill()
	status = CANCELLED
	completed.emit(self)


func _on_tween_finished() -> void:
	finish()

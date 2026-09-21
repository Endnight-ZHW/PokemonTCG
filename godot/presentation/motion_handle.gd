class_name MotionHandle
extends RefCounted

signal completed(handle: MotionHandle)

const RUNNING := "running"
const COMPLETED := "completed"
const CANCELLED := "cancelled"

var status := RUNNING
var tween: Tween
var _owner: Node


func bind_tween(value: Tween, owner: Node = null) -> MotionHandle:
	_disconnect_owner()
	tween = value
	if tween == null or not tween.is_valid():
		finish()
	else:
		# Godot kills a node-bound Tween when its owner leaves the tree without
		# emitting Tween.finished. Release any presentation barrier in that case.
		if owner != null and not is_finished():
			_owner = owner
			_owner.tree_exiting.connect(cancel, CONNECT_ONE_SHOT)
		if not tween.finished.is_connected(_on_tween_finished):
			tween.finished.connect(_on_tween_finished, CONNECT_ONE_SHOT)
	return self


func is_finished() -> bool:
	return status != RUNNING


func finish() -> void:
	if is_finished():
		return
	status = COMPLETED
	_disconnect_owner()
	completed.emit(self)


func cancel() -> void:
	if is_finished():
		return
	if tween != null and tween.is_valid():
		tween.kill()
	status = CANCELLED
	_disconnect_owner()
	completed.emit(self)


func _disconnect_owner() -> void:
	if is_instance_valid(_owner) and _owner.tree_exiting.is_connected(cancel):
		_owner.tree_exiting.disconnect(cancel)
	_owner = null


func _on_tween_finished() -> void:
	finish()

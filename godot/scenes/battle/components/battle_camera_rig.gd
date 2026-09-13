class_name BattleCameraRig
extends Node

var physical_world: BattleWorld3D
var _impulse_handle: MotionHandle

func configure(world: BattleWorld3D) -> void:
	cancel()
	physical_world = world

func impulse(strength: float, duration: float, reduced_motion: bool) -> MotionHandle:
	cancel()
	var handle := MotionHandle.new()
	if reduced_motion or duration <= 0.0 or not is_instance_valid(physical_world):
		handle.finish()
		return handle
	_impulse_handle = handle
	var tween := create_tween()
	tween.tween_method(_sample_impulse.bind(strength), 0.0, 1.0, duration)
	handle.completed.connect(_on_completed.bind(handle), CONNECT_ONE_SHOT)
	handle.bind_tween(tween)
	return handle

func _sample_impulse(progress: float, strength: float) -> void:
	if not is_instance_valid(physical_world):
		return
	var envelope := pow(1.0 - progress, 2.0) * strength * 7.0
	physical_world.camera_offset(Vector2(sin(progress * TAU * 2.0), sin(progress * TAU * 3.0) * 0.3) * envelope)

func _on_completed(_completed: MotionHandle, expected: MotionHandle) -> void:
	if _impulse_handle != expected:
		return
	_impulse_handle = null
	if is_instance_valid(physical_world):
		physical_world.camera_offset(Vector2.ZERO)

func cancel() -> void:
	if _impulse_handle != null:
		_impulse_handle.cancel()
	_impulse_handle = null
	if is_instance_valid(physical_world):
		physical_world.camera_offset(Vector2.ZERO)

func _exit_tree() -> void:
	cancel()

class_name BattleCameraRig
extends Node

var _targets: Array[Control] = []
var _origins: Dictionary = {}
var _impulse_tween: Tween
var _impulse_handle: MotionHandle


func configure(targets: Array[Control]) -> void:
	_cancel_tween()
	_reset_targets()
	_targets.clear()
	_origins.clear()
	for target in targets:
		if target == null or not is_instance_valid(target) or target in _targets:
			continue
		_targets.append(target)
		_origins[target.get_instance_id()] = target.position


func impulse(strength: float, duration: float, reduced_motion: bool) -> MotionHandle:
	_cancel_tween()
	_reset_targets()
	var handle := MotionHandle.new()
	if reduced_motion or duration <= 0.0 or _targets.is_empty():
		handle.finish()
		return handle
	_capture_origins()
	_impulse_tween = create_tween()
	for offset in [
		Vector2(strength * 7.0, 0.0),
		Vector2(-strength * 7.0, strength * 2.0),
		Vector2(strength * 4.0, -strength * 2.0),
		Vector2.ZERO,
	]:
		_impulse_tween.tween_method(
			_apply_offset,
			_current_offset(),
			offset,
			duration / 4.0,
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_impulse_handle = handle
	handle.completed.connect(
		_on_impulse_completed.bind(handle),
		CONNECT_ONE_SHOT,
	)
	handle.bind_tween(_impulse_tween)
	return handle


func cancel() -> void:
	_cancel_tween()
	_reset_targets()


func _exit_tree() -> void:
	cancel()


func _capture_origins() -> void:
	for target in _targets:
		if target != null and is_instance_valid(target):
			_origins[target.get_instance_id()] = target.position


func _current_offset() -> Vector2:
	for target in _targets:
		if target == null or not is_instance_valid(target):
			continue
		return target.position - Vector2(_origins.get(
			target.get_instance_id(),
			target.position,
		))
	return Vector2.ZERO


func _apply_offset(offset: Vector2) -> void:
	for target in _targets:
		if target == null or not is_instance_valid(target):
			continue
		var origin := Vector2(_origins.get(target.get_instance_id(), target.position))
		target.position = origin + offset


func _cancel_tween() -> void:
	var handle := _impulse_handle
	var tween := _impulse_tween
	_impulse_handle = null
	_impulse_tween = null
	if handle != null and not handle.is_finished():
		handle.cancel()
	elif tween != null and tween.is_valid():
		tween.kill()


func _on_impulse_completed(
	_completed_handle: MotionHandle,
	expected_handle: MotionHandle,
) -> void:
	if expected_handle != _impulse_handle:
		return
	_impulse_handle = null
	_impulse_tween = null
	_reset_targets()


func _reset_targets() -> void:
	for target in _targets:
		if target == null or not is_instance_valid(target):
			continue
		if _origins.has(target.get_instance_id()):
			target.position = Vector2(_origins[target.get_instance_id()])

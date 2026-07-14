class_name HandMotionController
extends RefCounted

var _host_ref: WeakRef
var _tweens: Dictionary


func configure(host: Node, tween_registry: Dictionary) -> void:
	_host_ref = weakref(host) if host != null else null
	_tweens = tween_registry


func move_card(
	view: CardView,
	target_position: Vector2,
	target_rotation: float,
	duration: float,
	completion: Callable = Callable(),
) -> MotionHandle:
	var handle := MotionHandle.new()
	if view == null or not is_instance_valid(view):
		handle.cancel()
		return handle
	var instance_id := view.get_instance_id()
	_cancel_entry(instance_id)
	if duration <= 0.0 or _host() == null:
		view.position = target_position
		view.rotation_degrees = target_rotation
		view.remember_base_position()
		if completion.is_valid():
			completion.call()
		handle.finish()
		return handle
	var tween := _host().create_tween().set_parallel(true)
	_tweens[instance_id] = tween
	tween.tween_property(view, "position", target_position, duration).set_trans(
		Tween.TRANS_QUAD,
	).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		view,
		"rotation_degrees",
		target_rotation,
		duration,
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(
		_finish_entry.bind(view, instance_id, completion),
	)
	handle.bind_tween(tween)
	return handle


func cancel_all() -> void:
	if _tweens == null:
		return
	for tween_value in _tweens.values():
		var tween := tween_value as Tween
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()


func _cancel_entry(instance_id: int) -> void:
	if _tweens == null:
		return
	var previous := _tweens.get(instance_id) as Tween
	if previous != null and previous.is_valid():
		previous.kill()
	_tweens.erase(instance_id)


func _finish_entry(
	view: CardView,
	instance_id: int,
	completion: Callable,
) -> void:
	if _tweens != null:
		_tweens.erase(instance_id)
	if view != null and is_instance_valid(view):
		view.remember_base_position()
	if completion.is_valid():
		completion.call()


func _host() -> Node:
	if _host_ref == null:
		return null
	var value: Variant = _host_ref.get_ref()
	return value as Node if is_instance_valid(value) else null

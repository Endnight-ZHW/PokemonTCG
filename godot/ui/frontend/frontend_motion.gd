class_name FrontendMotion
extends RefCounted

## Shared, accessibility-aware motion policy for non-battle screens.
## Only opacity and scale are animated so Container-owned layout stays stable.

const _TWEEN_META := &"frontend_motion_tween"


static func animation_mode() -> String:
	var settings := _settings()
	if settings == null:
		return "standard"
	var value := str(settings.get("animation_mode"))
	return value if value in ["cinematic", "standard", "fast", "reduced"] else "standard"


static func is_reduced() -> bool:
	return animation_mode() == "reduced"


static func is_low_quality() -> bool:
	var settings := _settings()
	if settings == null:
		return false
	if settings.has_method("resolved_quality_profile"):
		return str(settings.call("resolved_quality_profile")) == "low"
	return str(settings.get("quality_profile")) == "low"


static func decorative_motion_enabled() -> bool:
	return not is_reduced() and not is_low_quality()


static func duration(base_duration: float = 0.24) -> float:
	match animation_mode():
		"cinematic":
			return base_duration
		"standard":
			return base_duration * 0.82
		"fast":
			return base_duration * 0.46
		"reduced":
			return 0.0
	return base_duration


static func play_enter(
	control: Control,
	base_duration: float = 0.24,
	from_scale: float = 0.975,
) -> Tween:
	if not is_instance_valid(control):
		return null
	_stop_existing(control)
	control.pivot_offset = control.size * 0.5
	control.modulate.a = 1.0
	control.scale = Vector2.ONE
	var seconds := duration(base_duration)
	if seconds <= 0.0 or not control.is_inside_tree():
		return null
	control.modulate.a = 0.0
	control.scale = Vector2.ONE * from_scale
	var tween := control.create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_QUINT)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate:a", 1.0, seconds)
	tween.tween_property(control, "scale", Vector2.ONE, seconds)
	control.set_meta(_TWEEN_META, tween)
	tween.finished.connect(func() -> void:
		if is_instance_valid(control):
			control.remove_meta(_TWEEN_META)
	)
	return tween


static func play_exit(control: Control, base_duration: float = 0.16) -> Tween:
	if not is_instance_valid(control):
		return null
	_stop_existing(control)
	var seconds := duration(base_duration)
	if seconds <= 0.0 or not control.is_inside_tree():
		control.modulate.a = 0.0
		return null
	var tween := control.create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(control, "modulate:a", 0.0, seconds)
	control.set_meta(_TWEEN_META, tween)
	tween.finished.connect(func() -> void:
		if is_instance_valid(control):
			control.remove_meta(_TWEEN_META)
	)
	return tween


static func settle(control: Control) -> void:
	if not is_instance_valid(control):
		return
	_stop_existing(control)
	control.modulate.a = 1.0
	control.scale = Vector2.ONE


static func _stop_existing(control: Control) -> void:
	if not control.has_meta(_TWEEN_META):
		return
	var tween: Tween = control.get_meta(_TWEEN_META) as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	control.remove_meta(_TWEEN_META)


static func _settings() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("AppSettings")

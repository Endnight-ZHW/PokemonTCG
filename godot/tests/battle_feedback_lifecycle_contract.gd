extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings := root.get_node_or_null("AppSettings")
	var previous_mode := str(settings.get("animation_mode"))
	var previous_reduced := bool(settings.get("reduced_motion"))
	await _run_announcement_modes(settings)
	_run_reduced_slots(settings)
	await _run_fast_feedback_barrier(settings)
	settings.set("animation_mode", previous_mode)
	settings.set("reduced_motion", previous_reduced)
	if failures.is_empty():
		print("BATTLE_FEEDBACK_LIFECYCLE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_announcement_modes(settings: Node) -> void:
	var scene := load(
		"res://scenes/battle/components/battle_announcement_layer.tscn"
	) as PackedScene
	var announcements := scene.instantiate() as BattleAnnouncementLayer
	var director := PresentationDirector.new()
	root.add_child(announcements)
	root.add_child(director)
	await process_frame
	director.floating_text_requested.connect(func(
		text: String,
		target: Dictionary,
		color: Color,
	) -> void:
		if (
			str(target.get(PresentationDirector.FEEDBACK_CHANNEL_KEY, ""))
			!= PresentationDirector.FEEDBACK_CHANNEL_ANNOUNCEMENT
		):
			return
		var handle := announcements.show_announcement(
			text,
			color,
			MotionPolicy.reduced(),
		)
		director.register_feedback_motion(handle)
	)
	var event_revision := 500
	for mode in ["cinematic", "standard", "fast", "reduced"]:
		settings.set("animation_mode", mode)
		settings.set("reduced_motion", mode == "reduced")
		director.set_speed_mode(mode)
		announcements.clear()
		var events: Array[Dictionary] = []
		for event_type in ["turn_end", "checkup", "turn_start"]:
			events.append(PresentationEvent.normalize({
				"event_type": event_type,
				"actor": 0,
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 0, "slot": "active"},
				"data": {"player": 0, "slot": "active", "turn": 4},
			}, event_revision, events.size()))
		event_revision += 1
		var observed: Array[String] = []
		var reduced_position_changed := false
		director.play(events)
		for _frame in range(300):
			var text := announcements.current_text
			if not text.is_empty() and (observed.is_empty() or observed[-1] != text):
				observed.append(text)
			if mode == "reduced" and announcements.motion_root.position != Vector2.ZERO:
				reduced_position_changed = true
			if not director.is_playing() and not announcements.is_presenting():
				break
			await process_frame
		_expect(
			observed == ["回合结束", "宝可梦检查", "第 4 回合"],
			"%s mode replaced or reordered semantic announcements: %s"
			% [mode, str(observed)],
		)
		_expect(
			not director.is_playing() and not announcements.is_presenting(),
			"%s announcement queue did not finish" % mode,
		)
		if mode == "reduced":
			_expect(
				not reduced_position_changed,
				"reduced announcements used spatial motion",
			)
	director.queue_free()
	announcements.queue_free()
	await process_frame


func _run_reduced_slots(settings: Node) -> void:
	settings.set("animation_mode", "reduced")
	settings.set("reduced_motion", true)
	var layer := BattleEffectLayer.new()
	root.add_child(layer)
	var anchor := Vector2(360.0, 260.0)
	var handles: Array[MotionHandle] = [
		layer.floating_text("-10", anchor, DesignTokens.RED, false),
		layer.floating_text("中毒", anchor, DesignTokens.PURPLE, false),
		layer.floating_text("灼伤", anchor, DesignTokens.RED, false),
	]
	var positions: Array[Vector2] = []
	for row_value in layer.floating_texts:
		var row: Dictionary = row_value
		positions.append(Vector2(row.get("position", Vector2.ZERO)))
	var all_finished := true
	for handle in handles:
		if not handle.is_finished():
			all_finished = false
	_expect(
		all_finished
		and positions.size() == 3
		and positions[0] != positions[1]
		and positions[0] != positions[2]
		and positions[1] != positions[2],
		"same-frame reduced feedback did not receive distinct target slots",
	)
	layer.queue_free()


func _run_fast_feedback_barrier(settings: Node) -> void:
	settings.set("animation_mode", "fast")
	settings.set("reduced_motion", false)
	var director := PresentationDirector.new()
	var layer := BattleEffectLayer.new()
	var camera := BattleCameraRig.new()
	var camera_target := Control.new()
	camera_target.position = Vector2(80.0, 120.0)
	root.add_child(camera_target)
	root.add_child(layer)
	root.add_child(camera)
	root.add_child(director)
	camera.configure([camera_target])
	director.set_speed_mode("fast")
	director.floating_text_requested.connect(func(
		text: String,
		_target: Dictionary,
		color: Color,
	) -> void:
		var handle := layer.floating_text(
			text,
			Vector2(300.0, 220.0),
			color,
			true,
		)
		director.register_feedback_motion(handle)
	)
	director.camera_impulse_requested.connect(func(
		strength: float,
		duration: float,
	) -> void:
		var handle := camera.impulse(strength, duration, false)
		director.register_feedback_motion(handle)
	)
	director.play([PresentationEvent.normalize({
		"event_type": "damage_dealt",
		"actor": 0,
		"amount": 30,
		"source": {"player": 0, "slot": "active"},
		"target": {"player": 1, "slot": "active"},
		"data": {"player": 1, "slot": "active", "amount": 30},
	}, 600, 0)])
	for _frame in range(120):
		if not director.is_playing():
			break
		await process_frame
	var camera_position := camera_target.position
	var text_position := (
		Vector2(layer.floating_texts[0].get("position", Vector2.ZERO))
		if not layer.floating_texts.is_empty()
		else Vector2.ZERO
	)
	await process_frame
	await process_frame
	var stable_text_position := (
		Vector2(layer.floating_texts[0].get("position", Vector2.ZERO))
		if not layer.floating_texts.is_empty()
		else text_position
	)
	_expect(
		not director.is_playing()
		and camera._impulse_handle == null
		and camera_position.distance_to(Vector2(80.0, 120.0)) < 0.01
		and camera_target.position.distance_to(camera_position) < 0.01
		and stable_text_position.distance_to(text_position) < 0.01,
		"fast camera/floating feedback wrote position after its event barrier",
	)
	director.queue_free()
	camera.queue_free()
	layer.queue_free()
	camera_target.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

extends SceneTree

const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
var failures: Array[String] = []
var sequence := 9000
var output := ""
var table: BattleTable
var _done := false


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(90.0).timeout
	if not _done:
		push_error("Animation graphics capture timed out")
		quit(1)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Animation visual checks require a graphics renderer")
		quit(1)
		return
	root.size = Vector2i(1600, 900)
	root.content_scale_size = root.size
	Engine.max_fps = 60
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	settings.quality_profile = "high"
	output = ProjectSettings.globalize_path("res://../build/animation-preview")
	DirAccess.make_dir_recursive_absolute(output)
	table = TABLE.instantiate() as BattleTable
	root.add_child(table)
	for element in BattleFeedbackCue.ELEMENTS:
		await _capture("damage_dealt", element, 0.26, element.to_lower() + "-travel")
		await _capture("damage_dealt", element, 0.44, element.to_lower() + "-contact")
		await _capture("damage_dealt", element, 0.68, element.to_lower() + "-impact")
	for action in ["energy_attached", "pokemon_evolved", "healed", "damage_prevented", "status_POISONED", "status_BURNED", "status_ASLEEP", "status_PARALYZED", "status_CONFUSED", "pokemon_ko", "game_over"]:
		await _capture(action, "Fire", 0.60, action)
	await _capture("energy_attached", "Fire", 0.92, "energy-contact")
	await _capture("pokemon_evolved", "Fire", 0.92, "evolution-contact")
	await _capture("damage_dealt", "Lightning", 0.65, "opponent-view", 1)
	await _capture("heavy_hit", "Lightning", 0.44, "heavy-lightning-contact")
	for mode in ["cinematic", "fast"]:
		settings.animation_mode = mode
		await _capture("damage_dealt", "Fire", 0.44, mode + "-contact")
	settings.animation_mode = "standard"
	settings.quality_profile = "medium"
	await _capture("damage_dealt", "Water", 0.44, "medium-contact")
	for resolution in [Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900), Vector2i(640, 960)]:
		root.size = resolution
		root.content_scale_size = resolution
		settings.quality_profile = "low"
		await _capture("damage_dealt", "Water", 0.65, "low-%dx%d" % [resolution.x, resolution.y])
	settings.animation_mode = "reduced"
	await _capture("damage_dealt", "Fire", 1.0, "reduced")
	table.queue_free()
	await process_frame
	_done = true
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("BATTLE_ANIMATION_VISUAL_OK")
	quit(0 if failures.is_empty() else 1)


func _freeze(cue: BattleFeedbackCue, progress: float) -> void:
	if not cue.event_id.is_empty() and is_zero_approx(progress):
		table.render3d.world.feedback.set_process(false)


func _capture(kind: String, element: String, progress: float, filename: String, viewer: int = 0) -> void:
	sequence += 1
	table.process_mode = Node.PROCESS_MODE_INHERIT
	var fixture := BattleAnimationPreview.build(kind, element, viewer, sequence, table.catalog)
	table.cancel_presentations("capture", fixture.before_view)
	for frame in range(8):
		await process_frame
		await RenderingServer.frame_post_draw
	var renderer := table.render3d.world.feedback
	renderer.sampled.connect(_freeze)
	var handle := table.submit_transition(fixture.request)
	var found := false
	var id := str(fixture.request.events[0].event_id)
	for frame in range(180):
		for row in renderer._bursts:
			var cue := row.cue as BattleFeedbackCue
			if cue.event_id != id: continue
			if cue.motion_driven:
				var source := table.presentation_runtime.feedback_motion_sources.get(id) as WeakRef
				var flyer := source.get_ref() as Control
				var motion := flyer.get_meta("motion_handle") as MotionHandle
				motion.tween.pause()
				motion.tween.custom_step(maxf(0.0, cue.duration * progress - float(row.time)))
			renderer._sample(row, progress)
			row.time = cue.duration * progress
			var glyphs := row.node as MultiMeshInstance3D
			if glyphs == null or glyphs.multimesh.visible_instance_count < 1:
				failures.append(filename + " has no visible glyph instances")
			found = true
			break
		if found or handle.is_completed(): break
		await process_frame
	if not found and not MotionPolicy.reduced():
		failures.append(filename + " missed its keyframe")
	table.process_mode = Node.PROCESS_MODE_DISABLED
	table.render3d.sync_surfaces()
	for frame in range(3):
		await process_frame
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		failures.append(filename + " did not render an image")
	else:
		image.save_png(output.path_join(filename + ".png"))
	renderer.sampled.disconnect(_freeze)
	table.process_mode = Node.PROCESS_MODE_INHERIT
	table.cancel_presentations("capture_finished", fixture.after_view)

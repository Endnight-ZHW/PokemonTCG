extends SceneTree

## A landing cue must be on the rendered card, never its legacy Control dock.
const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
var failures: Array[String] = []
var table: BattleTable
var sequence := 18000
var done := false
var output := ""
var captures := 0


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(120.0).timeout
	if not done:
		push_error("Landing feedback contract timed out")
		quit(1)


func check(value: bool, message: String) -> void:
	if not value and message not in failures: failures.append(message)


func _run() -> void:
	Engine.max_fps = 60
	root.get_node("AppSettings").animation_mode = "standard"
	output = ProjectSettings.globalize_path("res://../build/landing-feedback")
	DirAccess.make_dir_recursive_absolute(output)
	table = TABLE.instantiate() as BattleTable
	root.add_child(table)
	for resolution in [Vector2i(1280, 768), Vector2i(900, 540), Vector2i(640, 960)]:
		root.size = resolution
		root.content_scale_size = resolution
		# Workbench embeds the table below its own toolbar.
		table.offset_top = 48
		for viewer in [0, 1]:
			for kind in ["trainer_played", "cards_discarded", "stadium_changed", "pokemon_played", "cards_drawn", "prize_taken"]:
				await _check_landing(kind, viewer, resolution)
	table.queue_free()
	await process_frame
	done = true
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("BATTLE_LANDING_FEEDBACK_OK cases=36 captures=%d" % captures)
	quit(0 if failures.is_empty() else 1)


func _check_landing(kind: String, viewer: int, resolution: Vector2i) -> void:
	sequence += 1
	var key := "%s-%dx%d-p%d" % [kind, resolution.x, resolution.y, viewer]
	var fixture := BattleAnimationPreview.build(kind, "Fire", viewer, sequence, table.catalog)
	table.process_mode = Node.PROCESS_MODE_INHERIT
	table.cancel_presentations("landing_geometry", fixture.before_view)
	for frame in range(5): await process_frame
	var renderer := table.render3d.world.feedback
	var matches: Array[BattleFeedbackCue] = []
	var freezer := func(cue: BattleFeedbackCue, _progress: float) -> void:
		if cue.kind not in ["trainer", "card_land", "land", "stadium", "prize"] or not matches.is_empty(): return
		matches.append(cue)
		table.process_mode = Node.PROCESS_MODE_DISABLED
	renderer.sampled.connect(freezer)
	var handle := table.submit_transition(fixture.request)
	for frame in range(180):
		if not matches.is_empty() or handle.is_completed(): break
		await process_frame
	check(not matches.is_empty(), key + " produced no landing cue")
	if not matches.is_empty():
		var cue := matches[0]
		var row: Dictionary = {}
		for candidate in renderer._bursts:
			if candidate.cue == cue: row = candidate
		check(not row.is_empty(), key + " lost its landing cue before capture")
		if not row.is_empty():
			renderer._sample(row, 0.32)
			table.render3d.sync_surfaces()
			var anchor: Control
			if kind in ["cards_drawn", "prize_taken", "cards_discarded"]:
				for mover in table.card_motion_layer.entities:
					if is_instance_valid(mover) and bool(mover.get_meta("motion_completed", false)):
						anchor = mover
						break
				if anchor == null:
					# Opponent-hand cards are adopted by the hidden hand at contact
					# and no longer belong to the active-flyer collection.
					var adopted := table.presentation_runtime.accent_sources.get(cue.get_instance_id()) as WeakRef
					if adopted != null: anchor = adopted.get_ref() as Control
			else:
				anchor = table.presentation_runtime._feedback_anchor(fixture.request.events[0].get("target", {}))
			# Inspect the rendered body / flight pose independently of the helper
			# that binds cues, so reverting to a Control center fails this check.
			var pose: Variant = null
			if anchor is CardMotionEntity:
				pose = (anchor as CardMotionEntity).current_pose()
				if pose is Transform3D and anchor.has_meta("physical_settle"):
					pose = BattleCardPath3D.settle(pose, float(anchor.get_meta("physical_settle")))
			elif anchor != null:
				var key_suffix := str(maxi(0, mini((anchor as ZoneView).count, 6) - 1)) if anchor is ZoneView else ""
				var physical := table.render3d.world.entities.get(table.render3d._key(anchor, key_suffix)) as CardEntity3D
				if physical != null: pose = physical.global_transform
			check(pose is Transform3D, key + " has no physical landing card")
			check(cue.has_surface_pose, key + " still uses a point-only effect")
			if pose is Transform3D:
				var projection := table.render3d.world.projection
				var face: Transform3D = pose
				face.origin += face.basis.y * CardEntity3D.THICKNESS * 0.5
				check(projection.world_to_screen(cue.target).distance_to(projection.world_to_screen(face.origin)) < 2.0, key + " draws feedback away from the physical card")
				check(is_equal_approx(cue.width, face.basis.x.length()), key + " uses a fixed placeholder width")
				check(cue.surface_pose.basis.is_equal_approx(face.basis), key + " loses the card tilt or proportions")
				var node := row.node as MultiMeshInstance3D
				check(node != null and node.multimesh.visible_instance_count > 0, key + " has no rendered landing accents")
				# The headless dummy renderer does not retain MultiMesh transforms.
				# Inspect actual instance geometry only with a graphics backend.
				if node != null and kind != "prize_taken" and DisplayServer.get_name() != "headless":
					var rim := node.multimesh.get_instance_transform(0)
					check(rim.basis.y.normalized().dot(face.basis.y.normalized()) > 0.999, key + " draws the rim on a different plane")
					var left := projection.world_to_screen(rim * Vector3(-0.345, 0, 0))
					var right := projection.world_to_screen(rim * Vector3(0.345, 0, 0))
					var card_span := projection.world_to_screen(face * Vector3(-0.5, 0, 0)).distance_to(projection.world_to_screen(face * Vector3(0.5, 0, 0)))
					var ratio := left.distance_to(right) / maxf(1.0, card_span)
					check(ratio > 0.99 and ratio < 1.12, key + " has an oversized detached rim: " + str(ratio))
				if DisplayServer.get_name() != "headless" and kind in ["trainer_played", "cards_discarded", "stadium_changed"]:
					for frame in range(2):
						await process_frame
						await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(output.path_join(key + ".png"))
					captures += 1
	renderer.sampled.disconnect(freezer)
	table.process_mode = Node.PROCESS_MODE_INHERIT
	table.cancel_presentations("landing_capture_finished", fixture.after_view)
	check(table.presentation_runtime.accent_sources.is_empty() and renderer._bursts.is_empty(), key + " retained an accent after cancellation")

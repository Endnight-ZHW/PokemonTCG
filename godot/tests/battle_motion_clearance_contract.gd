extends SceneTree

const REPORT_PATH := "res://../build/battle-animation-polish/clearance.json"

var failures: Array[String] = []
var report: Array[Dictionary] = []
var done := false


func _initialize() -> void:
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(90.0).timeout
	if not done:
		push_error("Motion clearance contract timed out")
		quit(1)


func _run() -> void:
	var output_path := ProjectSettings.globalize_path(REPORT_PATH)
	var directory_error := DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	if directory_error != OK:
		push_error("Cannot create motion clearance report directory: %s (%s)" % [output_path.get_base_dir(), error_string(directory_error)])
		done = true
		quit(1)
		return
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot open motion clearance report: %s (%s)" % [output_path, error_string(FileAccess.get_open_error())])
		done = true
		quit(1)
		return
	Engine.max_fps = 120
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	var table := preload("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	for size_value in [Vector2i(1280, 720), Vector2i(640, 960)]:
		root.size = size_value
		root.content_scale_size = size_value
		for viewer in [0, 1]:
			for kind in ["cards_drawn", "opening_draw", "prize_taken", "pokemon_evolved", "energy_attached", "cards_discarded", "switched", "retreat"]:
				await _inspect(table, kind, viewer, size_value)
			await _inspect(table, "opening_draw", viewer, size_value, 40)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	table.queue_free()
	await process_frame
	done = true
	var audit := "--audit-only" in OS.get_cmdline_user_args()
	for failure in failures:
		if audit: print("CLEARANCE_AUDIT " + failure)
		else: push_error(failure)
	if failures.is_empty(): print("BATTLE_MOTION_CLEARANCE_OK cases=%d" % report.size())
	quit(0 if failures.is_empty() or audit else 1)


func _inspect(table: BattleTable, kind: String, viewer: int, resolution: Vector2i, hand_count: int = 5) -> void:
	var fixture := BattleAnimationPreview.build(kind, "Fire", viewer, 26000 + report.size(), table.catalog)
	if hand_count > 5:
		for state: GameState in [fixture.before_state, fixture.after_state]:
			for index in range(hand_count - 5): state.players[0].hand.push_front("svi-chim")
		fixture.before_view = BattleViewModel.capture_player_view(fixture.before_state, viewer, [], "", false, "preview")
		fixture.after_view = BattleViewModel.capture_player_view(fixture.after_state, viewer, [], "", false, "preview")
		fixture.request = BattleTransitionRequest.create(fixture.after_view, fixture.request.events, 0, BattleTransitionRequest.CAUSE_REFRESH)
	table.cancel_presentations("clearance_fixture", fixture.before_view)
	for i in range(4): await process_frame
	var handle := table.submit_transition(fixture.request)
	var row := {"kind": kind, "viewer": viewer, "hand_count": hand_count, "resolution": str(resolution), "minimum_y": 100.0, "samples": 0, "intersections": 0, "examples": []}
	var frames := 0
	while not handle.is_completed() and frames < 400:
		await process_frame
		table.render3d.sync_surfaces()
		frames += 1
		for token in table.card_motion_layer.entities:
			var flyer := token as Control
			if flyer == null or not flyer.visible or bool(flyer.get_meta("motion_completed", false)): continue
			var physical := table.render3d.world.entities.get(table.render3d._key(flyer)) as CardEntity3D
			if physical == null or not physical.visible: continue
			row.samples += 1
			var pose := physical.transform
			var extent := absf(pose.basis.x.y) * 0.5 + absf(pose.basis.z.y) * CardEntity3D.ASPECT * 0.5 + absf(pose.basis.y.y) * physical.half_height()
			row.minimum_y = minf(row.minimum_y, pose.origin.y - extent)
			for key in table.render3d.world.entities:
				var other := table.render3d.world.entities[key] as CardEntity3D
				if other == physical or not other.visible or not other.body.visible: continue
				if str(key).begins_with("surface:%d:" % flyer.get_instance_id()): continue
				if intersects(physical.transform, physical.half_height(), other.transform, other.half_height()):
					row.intersections += 1
					if row.examples.size() < 3:
						var anchor_row: Dictionary = table.render3d._anchors.get(int(str(key).get_slice(":", 1)), {})
						var anchor := (anchor_row.ref as WeakRef).get_ref() as Control if anchor_row.has("ref") else null
						row.examples.append({"frame": frames, "obstacle": str(anchor.name) if anchor != null else str(key), "flip": float(flyer.get_meta("physical_flip_progress", 0)), "flight_y": pose.origin.y})
	if row.minimum_y < -0.002 or row.intersections > 0:
		failures.append("%s p%d %s min_y=%.4f collisions=%d %s" % [kind, viewer, resolution, row.minimum_y, row.intersections, str(row.examples)])
	if not handle.is_completed() or row.samples == 0:
		failures.append(kind + " did not exercise/finish a flight")
	if table.card_motion_layer.active_motion_count() != 0:
		failures.append(kind + " left a moving entity after completion")
	report.append(row)
	table.cancel_presentations("clearance_finished", fixture.after_view)


static func intersects(a: Transform3D, height_a: float, b: Transform3D, height_b: float) -> bool:
	var half_a := Vector3(0.5, height_a, CardEntity3D.ASPECT * 0.5)
	var half_b := Vector3(0.5, height_b, CardEntity3D.ASPECT * 0.5)
	var axes: Array[Vector3] = [a.basis.x, a.basis.y, a.basis.z, b.basis.x, b.basis.y, b.basis.z]
	for i in range(3):
		for j in range(3): axes.append(a.basis[i].cross(b.basis[j]))
	for value in axes:
		if value.length_squared() < 0.000001: continue
		var axis := value.normalized()
		var radius := 0.0
		for i in range(3): radius += absf(axis.dot(a.basis[i])) * half_a[i] + absf(axis.dot(b.basis[i])) * half_b[i]
		if absf(axis.dot(b.origin - a.origin)) >= radius - 0.002: return false
	return true

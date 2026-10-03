extends SceneTree

## Records complete actions, including pickup and handoff, not just impact VFX.
const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
var failures: Array[String] = []
var records: Array[Dictionary] = []
var table: BattleTable
var caption: Label
var output := ""
var done := false


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(360.0).timeout
	if not done:
		push_error("Full-motion animation review timed out")
		quit(1)


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Full-motion review requires real graphics")
		quit(1)
		return
	root.size = Vector2i(1280, 768)
	root.content_scale_size = root.size
	Engine.max_fps = 60
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	settings.quality_profile = "high"
	output = ProjectSettings.globalize_path("res://../build/animation-review")
	var actions: Array = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = ProjectSettings.globalize_path(arg.trim_prefix("--output="))
		if arg.begins_with("--actions="): actions = Array(arg.trim_prefix("--actions=").split(",", false))
	DirAccess.make_dir_recursive_absolute(output)
	table = TABLE.instantiate() as BattleTable
	root.add_child(table)
	table.offset_top = 48
	caption = Label.new()
	caption.position = Vector2(22, 8)
	caption.size = Vector2(1236, 34)
	caption.add_theme_font_override("font", preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres"))
	caption.add_theme_font_size_override("font_size", 20)
	caption.add_theme_color_override("font_color", DesignTokens.TEXT)
	root.add_child(caption)
	var selected: Array = BattleAnimationPreview.ACTIONS.keys() if actions.is_empty() else actions
	for kind in selected:
		await _record(str(kind), 0)
		if not actions.is_empty(): await _record(str(kind), 1)
	if actions.is_empty():
		await _record("cards_drawn", 1)
		await _record("switched", 1)
		await _record("energy_attached", 1)
		for element in BattleFeedbackCue.ELEMENTS:
			await _record("heavy_attack", 0, element, element.to_lower())
	var file := FileAccess.open(output.path_join("motion-review.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"godot": Engine.get_version_info().string, "fps": 20, "mode": "standard", "records": records}, "\t"))
	file.close()
	table.queue_free()
	caption.queue_free()
	await process_frame
	done = true
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("BATTLE_ANIMATION_MOTION_OK")
	quit(0 if failures.is_empty() else 1)


func _record(kind: String, viewer: int, element: String = "Fire", variant: String = "") -> void:
	var key := kind + ("-opponent" if viewer == 1 else "") + ("-" + variant if not variant.is_empty() else "")
	var folder := output.path_join(key)
	DirAccess.make_dir_recursive_absolute(folder)
	var fixture := BattleAnimationPreview.build(kind, element, viewer, 14000 + records.size(), table.catalog)
	table.cancel_presentations("motion_review", fixture.before_view)
	caption.text = "%s · %s · %s · 标准模式" % [str(BattleAnimationPreview.ACTIONS.get(kind, kind)), EnergyIconCatalog.type_display_name_for(element), "对手视角" if viewer == 1 else "己方视角"]
	for frame in range(8):
		await process_frame
		await RenderingServer.frame_post_draw
	# Encoding PNGs in the animation loop blocks the main thread and changes its
	# timing. Keep readbacks in memory, then encode after the action has settled.
	var images: Array[Image] = [root.get_texture().get_image()]
	var timestamps: Array[int] = [0]
	var handle := table.submit_transition(fixture.request)
	var frames := 0
	var live_movers := 0
	var styles: Dictionary = {}
	var started := Time.get_ticks_msec()
	while not handle.is_completed() and Time.get_ticks_msec() - started < 8000:
		await process_frame
		await RenderingServer.frame_post_draw
		frames += 1
		live_movers = maxi(live_movers, table.card_motion_layer.active_motion_count())
		for entity in table.card_motion_layer.entities:
			if is_instance_valid(entity) and entity.has_meta("motion_kind"):
				styles[str(entity.get_meta("motion_kind"))] = true
		if frames % 3 == 0:
			images.append(root.get_texture().get_image())
			timestamps.append(Time.get_ticks_msec() - started)
	if not handle.is_completed():
		failures.append(key + " did not complete")
		table.cancel_presentations("review_timeout", fixture.after_view)
	for frame in range(6):
		await process_frame
		await RenderingServer.frame_post_draw
		if frame % 3 == 0:
			images.append(root.get_texture().get_image())
			timestamps.append(Time.get_ticks_msec() - started)
	for view in table.hand_views + table.opponent_hand_views:
		if view.has_meta("physical_settle"):
			failures.append(key + " left a hand card in its landing pose")
	for index in range(images.size()):
		images[index].save_png(folder.path_join("%04d.png" % index))
	records.append({"kind": kind, "key": key, "label": str(BattleAnimationPreview.ACTIONS.get(kind, kind)), "element": element, "viewer": viewer, "captures": images.size(), "timestamps_ms": timestamps, "rendered_frames": frames, "moving_entities": live_movers, "styles": styles.keys()})

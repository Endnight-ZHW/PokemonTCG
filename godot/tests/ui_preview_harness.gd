class_name UIPreviewHarness
extends RefCounted

const OUTPUT_ROOT := "res://../build/ui-preview"

var tree: SceneTree
var _settings_node: Node
var _settings_snapshot: Dictionary = {}
var finished := false


func configure(preview_tree: SceneTree) -> void:
	tree = preview_tree


func _settle_frontend(frame_count: int = 3) -> void:
	# Explicit frame waits make container layout deterministic even when the
	# renderer is faster than the former timer-based preview cadence.
	for _frame in range(maxi(frame_count, 2)):
		await tree.process_frame

func _click_control(control: Control) -> void:
	if control == null:
		return
	await _move_pointer_to_control(control)
	var pointer_position := _physical_control_rect(control).get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pointer_position
	press.global_position = pointer_position
	Input.parse_input_event(press)
	await tree.process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pointer_position
	release.global_position = pointer_position
	Input.parse_input_event(release)
	await tree.process_frame

func _move_pointer_to_control(control: Control) -> void:
	if control == null:
		return
	var pointer_position := _physical_control_rect(control).get_center()
	Input.warp_mouse(pointer_position)
	var motion := InputEventMouseMotion.new()
	motion.position = pointer_position
	motion.global_position = pointer_position
	Input.parse_input_event(motion)
	await tree.process_frame
	await RenderingServer.frame_post_draw

func _begin_mouse_press(control: Control) -> bool:
	if control == null:
		return false
	await _move_pointer_to_control(control)
	var pointer_position := _physical_control_rect(control).get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pointer_position
	press.global_position = pointer_position
	Input.parse_input_event(press)
	await tree.process_frame
	await RenderingServer.frame_post_draw
	return _is_pressed_draw_mode(control)

func _cancel_mouse_press(guard_button: BaseButton = null) -> void:
	var restore_disabled := false
	if guard_button != null:
		restore_disabled = guard_button.disabled
		guard_button.disabled = true
	var release_position := Vector2(4.0, 4.0)
	Input.warp_mouse(release_position)
	var motion := InputEventMouseMotion.new()
	motion.position = release_position
	motion.global_position = release_position
	Input.parse_input_event(motion)
	await tree.process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = release_position
	release.global_position = release_position
	Input.parse_input_event(release)
	await tree.process_frame
	if guard_button != null and is_instance_valid(guard_button):
		guard_button.disabled = restore_disabled

func _begin_touch_press(control: Control, touch_index := 0) -> bool:
	if control == null:
		return false
	await _move_pointer_to_control(control)
	var pointer_position := _physical_control_rect(control).get_center()
	var touch := InputEventScreenTouch.new()
	touch.index = touch_index
	touch.pressed = true
	touch.position = pointer_position
	Input.parse_input_event(touch)
	# Synthetic ScreenTouch events do not pass through the platform's mouse-from-
	# touch translator on desktop. Feed the companion mouse event Godot emits on
	# Android as well; the preceding ScreenTouch keeps this distinct from the
	# ordinary mouse-only fixture above.
	var emulated_press := InputEventMouseButton.new()
	emulated_press.button_index = MOUSE_BUTTON_LEFT
	emulated_press.pressed = true
	emulated_press.position = pointer_position
	emulated_press.global_position = pointer_position
	Input.parse_input_event(emulated_press)
	await tree.process_frame
	await RenderingServer.frame_post_draw
	return _is_pressed_draw_mode(control)

func _cancel_touch_press(touch_index := 0) -> void:
	var release_position := Vector2(4.0, 4.0)
	var release := InputEventScreenTouch.new()
	release.index = touch_index
	release.pressed = false
	release.position = release_position
	Input.parse_input_event(release)
	var emulated_release := InputEventMouseButton.new()
	emulated_release.button_index = MOUSE_BUTTON_LEFT
	emulated_release.pressed = false
	emulated_release.position = release_position
	emulated_release.global_position = release_position
	Input.parse_input_event(emulated_release)
	await tree.process_frame

func _is_pressed_draw_mode(control: Control) -> bool:
	if not control is BaseButton:
		return false
	return (control as BaseButton).get_draw_mode() in [
		BaseButton.DRAW_PRESSED,
		BaseButton.DRAW_HOVER_PRESSED,
	]

func _physical_control_rect(control: Control) -> Rect2:
	if control == null:
		return Rect2()
	var logical_rect := control.get_global_rect()
	var final_transform := tree.root.get_final_transform()
	var physical_start := final_transform * logical_rect.position
	var physical_end := final_transform * logical_rect.end
	return Rect2(physical_start, physical_end - physical_start).abs()

func _assert_physical_touch_targets(controls: Array, label: String) -> bool:
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(tree.root.size))
	for value in controls:
		var control := value as Control
		if control == null or not control.is_visible_in_tree():
			push_error("%s is missing a visible touch target" % label)
			return false
		var rect := _physical_control_rect(control)
		if rect.size.x < 48.0 or rect.size.y < 48.0:
			push_error("%s target %s is below physical 48x48: %s" % [
				label,
				control.get_path(),
				rect,
			])
			return false
		if not viewport_rect.encloses(rect):
			push_error("%s target %s escapes the physical viewport: %s / %s" % [
				label,
				control.get_path(),
				rect,
				viewport_rect,
			])
			return false
	return true

func _move_pointer_to_hand_card_exposed_edge(card: CardView) -> bool:
	if card == null:
		return false
	# The right half of a dense fan card is intentionally covered by its next
	# sibling. Probe a small deterministic grid inside the exposed leading strip,
	# using the same logical rectangle as GUI input. Every probe is routed as a real
	# mouse motion and accepted only when Viewport GUI picking names this card.
	for x_fraction in [0.08, 0.16, 0.24, 0.32, 0.40]:
		for y_fraction in [0.50, 0.36, 0.64, 0.22, 0.78]:
			# InputEvent positions use the same logical GUI coordinates reported by
			# get_global_rect(). A Canvas/global transform includes Window stretch and
			# maps this point a second time after a 900×540 resize.
			var card_rect := card.get_global_rect()
			var pointer_position := card_rect.position + Vector2(
				card_rect.size.x * float(x_fraction),
				card_rect.size.y * float(y_fraction),
			)
			await _move_pointer_to_position(pointer_position)
			if _pointer_is_over_card(card):
				return true
	return false

func _move_pointer_to_position(pointer_position: Vector2) -> void:
	# Parsed input uses physical Window coordinates. Map logical Control points
	# through the final transform; compact UI normally resolves to a 1:1 transform,
	# while large/ultrawide captures can still scale the design canvas upward.
	var window_position := tree.root.get_final_transform() * pointer_position
	Input.warp_mouse(window_position)
	var motion := InputEventMouseMotion.new()
	motion.position = window_position
	motion.global_position = window_position
	Input.parse_input_event(motion)
	await tree.process_frame
	await tree.process_frame

func _pointer_is_over_card(card: CardView) -> bool:
	if card == null:
		return false
	var hovered_control := tree.root.gui_get_hovered_control()
	return (
		hovered_control != null
		and (
			hovered_control == card
			or card.is_ancestor_of(hovered_control)
		)
	)

func _dense_hand_hover_failure_message(prefix: String, card: CardView) -> String:
	var hovered_control := tree.root.gui_get_hovered_control()
	return "%s: target=%s rect=%s pointer=%s hovered=%s" % [
		prefix,
		str(card.get_path()) if card != null else "<null>",
		str(card.get_global_rect()) if card != null else "<null>",
		str(tree.root.get_mouse_position()),
		(
			str(hovered_control.get_path())
			if hovered_control != null
			else "<null>"
		),
	]

func _preview_card_draws_above(upper: CardView, lower: CardView) -> bool:
	if upper == null or lower == null:
		return false
	return (
		upper.z_index > lower.z_index
		or (
			upper.z_index == lower.z_index
			and upper.get_index() > lower.get_index()
		)
	)

func _wait_until_hidden(control: Control, maximum_frames := 45) -> void:
	if control == null:
		return
	for _frame in range(maximum_frames):
		if not control.visible:
			return
		await tree.process_frame

func _energy_count_badge_is_readable(card: CardView, expected: String) -> bool:
	if card == null:
		return false
	var badge := card.find_child("EnergyBadge", true, false) as Control
	var count_badge := (
		badge.find_child("CountBadge", true, false) as Control
		if badge != null
		else null
	)
	if count_badge == null:
		return false
	return (
		str(count_badge.get_meta("count_text", "")) == expected
		and int(count_badge.get_meta("font_size", 0)) >= 9
		and count_badge.size.x > count_badge.size.y
		and Rect2(Vector2.ZERO, badge.size).encloses(
			Rect2(count_badge.position, count_badge.size)
		)
	)

func _energy_badge_for_group(card: CardView, group_key: String) -> Control:
	if card == null:
		return null
	var row := card.find_child("EnergyRow", true, false) as HBoxContainer
	if row == null:
		return null
	for child_value in row.get_children():
		var child := child_value as Control
		if child != null and str(child.get_meta("energy_group_key", "")) == group_key:
			return child
	return null

func _settle_rendered(frame_count := 3) -> void:
	for _frame in range(maxi(frame_count, 2)):
		await tree.process_frame
		await RenderingServer.frame_post_draw

func _update_battle_preview(
	ui,
	preview_state: GameState,
	action_rows: Array,
	selected_source := "",
	ai_is_thinking := false,
	mode := "local",
) -> void:
	var typed_action_rows: Array[Dictionary] = []
	for row_value in action_rows:
		if row_value is Dictionary:
			typed_action_rows.append(Dictionary(row_value))
	# Battle baselines exercise BattleTable itself; no shell modal is part of
	# these states. Force a completed close so a previous inspector cannot leave
	# its 86% shade in a later capture on a very fast renderer.
	if ui.modal_layer:
		ui.modal_layer.visible = false
	ui.state = preview_state
	ui.current_view_player = 0
	ui.selected_entity_key = selected_source
	ui.ai_thinking = ai_is_thinking
	ui.game_mode = mode
	if ui.battle_screen:
		ui.battle_screen.update_view(
			preview_state,
			0,
			typed_action_rows,
			selected_source,
			ai_is_thinking,
			mode,
		)

func _enable_deterministic_preview_mode() -> bool:
	_settings_node = tree.root.get_node_or_null("AppSettings")
	if _settings_node == null:
		return false
	_settings_snapshot = {
		"master_volume": _settings_node.get("master_volume"),
		"music_volume": _settings_node.get("music_volume"),
		"sfx_volume": _settings_node.get("sfx_volume"),
		"muted": _settings_node.get("muted"),
		"reduced_motion": _settings_node.get("reduced_motion"),
		"card_cache_size": _settings_node.get("card_cache_size"),
		"animation_mode": _settings_node.get("animation_mode"),
		"quality_profile": _settings_node.get("quality_profile"),
	}
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		true,
		int(_settings_snapshot.card_cache_size),
		"reduced",
		"high",
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)
	return true

func _set_preview_quality(profile: String) -> void:
	_set_preview_motion("reduced", profile)

func _set_preview_motion(mode: String, profile: String) -> void:
	if _settings_node == null:
		return
	_settings_node.call(
		"update",
		float(_settings_node.get("master_volume")),
		bool(_settings_node.get("muted")),
		mode == "reduced",
		int(_settings_node.get("card_cache_size")),
		mode,
		profile,
		float(_settings_node.get("music_volume")),
		float(_settings_node.get("sfx_volume")),
	)

func _restore_preview_settings() -> void:
	if _settings_node == null or _settings_snapshot.is_empty():
		return
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		bool(_settings_snapshot.reduced_motion),
		int(_settings_snapshot.card_cache_size),
		str(_settings_snapshot.animation_mode),
		str(_settings_snapshot.quality_profile),
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)

func _finish(exit_code: int) -> void:
	if finished:
		return
	finished = true
	_restore_preview_settings()
	tree.quit(exit_code)

func _capture(filename: String) -> bool:
	var texture := tree.root.get_texture()
	if texture == null:
		push_error("Unable to capture preview %s: viewport texture is unavailable" % filename)
		return false
	var image := texture.get_image()
	if image == null:
		push_error("Unable to capture preview %s: viewport image is unavailable" % filename)
		return false
	var result := image.save_png(ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, filename]))
	if result != OK:
		push_error("Unable to save preview %s" % filename)
		return false
	return true

func _captures_differ(first_filename: String, second_filename: String) -> bool:
	var first_path := ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, first_filename]
	)
	var second_path := ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, second_filename]
	)
	return FileAccess.get_file_as_bytes(first_path) != FileAccess.get_file_as_bytes(
		second_path
	)

func _assert_network_first_screen(page: NetworkLobbyPage, label: String) -> bool:
	if page == null or page.page_scroll == null or page.connect_button == null:
		push_error("%s preview is missing its network layout controls" % label)
		return false
	var scroll := page.page_scroll
	var viewport_rect := scroll.get_global_rect()
	var button_rect := page.connect_button.get_global_rect()
	var page_rect := page.page.get_global_rect()
	var top_bar := page.page.get_node("TopBar") as Control
	var steps := page.page.get_node("Steps") as Control
	var top_bar_rect := top_bar.get_global_rect()
	var steps_rect := steps.get_global_rect()
	var scrollbar := scroll.get_v_scroll_bar()
	var left_gutter := page_rect.position.x - viewport_rect.position.x
	var right_gutter := viewport_rect.end.x - page_rect.end.x
	var top_gutter := page_rect.position.y - viewport_rect.position.y
	var fits := (
		not scrollbar.visible
		and scroll.scroll_vertical == 0
		and viewport_rect.encloses(page_rect)
		and viewport_rect.encloses(top_bar_rect)
		and viewport_rect.encloses(steps_rect)
		and viewport_rect.encloses(button_rect)
		and left_gutter >= -0.5
		and right_gutter >= -0.5
		and absf(left_gutter - right_gutter) <= 2.0
		and absf(page_rect.get_center().x - viewport_rect.get_center().x) <= 1.0
		and absf(top_gutter) <= 1.0
		and page.page.get_parent() == page.page_center
	)
	if not fits:
		push_error(
			"%s must fit, top-align and remain horizontally centered at 1600x900 without vertical scrolling: viewport=%s page=%s top=%s steps=%s button=%s gutters=%.1f/%.1f/%.1f scroll=%d max=%.1f visible=%s"
			% [
				label,
				viewport_rect,
				page_rect,
				top_bar_rect,
				steps_rect,
				button_rect,
				left_gutter,
				right_gutter,
				top_gutter,
				scroll.scroll_vertical,
				scrollbar.max_value,
				scrollbar.visible,
			]
		)
	return fits

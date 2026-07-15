class_name CoinShowcase
extends Control

signal audio_requested(cue: String)

const COIN_SIZE := 104.0
const FIRST_TOSS_DURATION := 0.90
const FOLLOWUP_TOSS_DURATION := 0.55
const QUICK_TOSS_DURATION := 0.16
const RESULT_GAP := 0.08
const FINAL_HOLD := 0.34


class CoinToken:
	extends Control

	var face_heads := true:
		set(value):
			face_heads = value
			if face_label != null:
				face_label.text = "正" if face_heads else "反"
			queue_redraw()
	var face_label: Label


	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(COIN_SIZE, COIN_SIZE)
		size = custom_minimum_size
		pivot_offset = size * 0.5
		face_label = Label.new()
		face_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		face_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		face_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		face_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		face_label.add_theme_font_size_override("font_size", 34)
		face_label.add_theme_color_override("font_color", Color("3b2600"))
		face_label.add_theme_color_override(
			"font_outline_color",
			Color(1.0, 0.91, 0.52, 0.62),
		)
		face_label.add_theme_constant_override("outline_size", 2)
		face_label.text = "正" if face_heads else "反"
		add_child(face_label)


	func _draw() -> void:
		var center := size * 0.5
		draw_circle(center + Vector2(0, 3), COIN_SIZE * 0.49, Color(0.20, 0.11, 0.01, 0.72))
		draw_circle(center, COIN_SIZE * 0.49, Color("d18b16"))
		draw_circle(center, COIN_SIZE * 0.445, Color("ffd45e"))
		draw_circle(center, COIN_SIZE * 0.365, Color("e8a92d"))
		draw_circle(center + Vector2(-8, -9), COIN_SIZE * 0.27, Color("ffd967"))
		draw_arc(
			center,
			COIN_SIZE * 0.40,
			-2.65,
			-0.55,
			24,
			Color(1.0, 0.96, 0.72, 0.92),
			3.0,
			true,
		)


var title_text := "抛硬币"
var persistent := false
var results: Array[bool] = []
var _history_count := 0
var _current_index := -1
var _current_face := true
var _toss_progress := 0.0
var _generation := 0
var _active_handle: MotionHandle
var _active_tween: Tween
var _token: CoinToken
var _title_label: Label
var _summary_label: Label
var _history_label: Label


func _init() -> void:
	custom_minimum_size = Vector2(520, 286)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false


func _ready() -> void:
	_build_nodes()
	resized.connect(_layout_nodes)
	_layout_nodes()
	_update_text()
	queue_redraw()


func play(
	p_results: Array,
	p_persistent: bool = false,
	p_title: String = "抛硬币",
) -> MotionHandle:
	clear()
	persistent = p_persistent
	title_text = p_title
	results.clear()
	for value in p_results:
		results.append(bool(value))
	_history_count = 0
	_current_index = -1
	_current_face = results[0] if not results.is_empty() else true
	_toss_progress = 0.0
	modulate = Color.WHITE
	visible = true
	_build_nodes()
	_token.face_heads = _current_face
	_update_text()
	_layout_nodes()
	queue_redraw()

	var handle := MotionHandle.new()
	_active_handle = handle
	var run_generation := _generation
	if results.is_empty():
		handle.finish()
		return handle

	_active_tween = create_tween()
	if MotionPolicy.reduced():
		_active_tween.tween_callback(_show_reduced_result)
		_active_tween.tween_interval(0.45)
	else:
		var motion_scale := _motion_scale()
		for index in range(results.size()):
			var duration := _duration_for_index(index)
			_active_tween.tween_callback(_begin_toss.bind(index))
			_active_tween.tween_method(
				_set_toss_progress.bind(index),
				0.0,
				1.0,
				duration,
			).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
			_active_tween.tween_callback(_complete_toss.bind(index))
			_active_tween.tween_interval(
				(RESULT_GAP if index + 1 < results.size() else FINAL_HOLD)
				* motion_scale
			)
	if not persistent:
		_active_tween.tween_property(self, "modulate:a", 0.0, 0.16)
	handle.completed.connect(
		_on_playback_completed.bind(run_generation),
		CONNECT_ONE_SHOT,
	)
	handle.bind_tween(_active_tween)
	return handle


func clear() -> void:
	_generation += 1
	var handle := _active_handle
	_active_handle = null
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
	if handle != null and not handle.is_finished():
		handle.cancel()
	_history_count = 0
	_current_index = -1
	_toss_progress = 0.0
	modulate = Color.WHITE
	visible = false


func _exit_tree() -> void:
	clear()


func _build_nodes() -> void:
	if _token != null:
		return
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", Color("ffe59a"))
	add_child(_title_label)

	_token = CoinToken.new()
	add_child(_token)

	_summary_label = Label.new()
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary_label.add_theme_font_size_override("font_size", 18)
	_summary_label.add_theme_color_override("font_color", Color("f4f7ff"))
	add_child(_summary_label)

	_history_label = Label.new()
	_history_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_history_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_history_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_history_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_history_label.add_theme_font_size_override("font_size", 15)
	_history_label.add_theme_color_override("font_color", Color("c9d5e8"))
	add_child(_history_label)


func _layout_nodes() -> void:
	if _token == null:
		return
	var width := maxf(custom_minimum_size.x, size.x)
	var height := maxf(custom_minimum_size.y, size.y)
	_title_label.position = Vector2(18, 12)
	_title_label.size = Vector2(maxf(0.0, width - 36), 32)
	var base_center := Vector2(width * 0.5, minf(118.0, height * 0.43))
	var lift := _coin_lift(_toss_progress)
	_token.position = base_center - Vector2(COIN_SIZE, COIN_SIZE) * 0.5 + Vector2(0, -lift)
	_token.scale = Vector2(
		1.0 + 0.05 * sin(_toss_progress * PI),
		_coin_vertical_scale(_toss_progress),
	)
	_token.rotation = sin(_toss_progress * TAU * 2.0) * 0.055
	_summary_label.position = Vector2(18, height - 98)
	_summary_label.size = Vector2(maxf(0.0, width - 36), 28)
	_history_label.position = Vector2(24, height - 65)
	_history_label.size = Vector2(maxf(0.0, width - 48), 58)


func _begin_toss(index: int) -> void:
	_current_index = index
	_toss_progress = 0.0
	_current_face = results[index - 1] if index > 0 else not results[index]
	_token.face_heads = _current_face
	audio_requested.emit("coin_toss")
	_update_text()
	_layout_nodes()
	queue_redraw()


func _set_toss_progress(progress: float, index: int) -> void:
	if index != _current_index:
		return
	_toss_progress = clampf(progress, 0.0, 1.0)
	var half_turn := int(floor(_toss_progress * 17.0))
	var start_face := results[index - 1] if index > 0 else not results[index]
	_current_face = (
		results[index]
		if _toss_progress >= 0.94
		else (start_face if half_turn % 2 == 0 else not start_face)
	)
	_token.face_heads = _current_face
	_layout_nodes()
	queue_redraw()


func _complete_toss(index: int) -> void:
	_current_index = index
	_history_count = maxi(_history_count, index + 1)
	_current_face = results[index]
	_toss_progress = 1.0
	_token.face_heads = _current_face
	audio_requested.emit("coin_land")
	_update_text()
	_layout_nodes()
	queue_redraw()


func _show_reduced_result() -> void:
	_history_count = results.size()
	_current_index = results.size() - 1
	_current_face = results[-1]
	_toss_progress = 1.0
	_token.face_heads = _current_face
	audio_requested.emit("coin_land")
	_update_text()
	_layout_nodes()
	queue_redraw()


func _on_playback_completed(
	handle: MotionHandle,
	expected_generation: int,
) -> void:
	if expected_generation != _generation or handle != _active_handle:
		return
	_active_handle = null
	_active_tween = null
	if not persistent:
		visible = false


func _update_text() -> void:
	if _title_label == null:
		return
	_title_label.text = title_text
	var heads := 0
	for index in range(_history_count):
		if results[index]:
			heads += 1
	var tails := _history_count - heads
	if _history_count >= results.size() and not results.is_empty():
		_summary_label.text = "正面 %d · 反面 %d" % [heads, tails]
	elif _current_index >= 0:
		_summary_label.text = "第 %d/%d 次 · 抛掷中…" % [_current_index + 1, results.size()]
	else:
		_summary_label.text = "准备抛掷"
	var rows: Array[String] = []
	var line: Array[String] = []
	for index in range(_history_count):
		line.append("●正" if results[index] else "○反")
		if line.size() == 10:
			rows.append("  ".join(line))
			line.clear()
	if not line.is_empty():
		rows.append("  ".join(line))
	_history_label.text = "\n".join(rows)
	accessibility_name = "%s；%s；%s" % [
		title_text,
		_summary_label.text,
		_history_label.text.replace("\n", "，"),
	]


func _duration_for_index(index: int) -> float:
	var motion_scale := _motion_scale()
	if results.size() > 6 and index >= 3 and index < results.size() - 1:
		return QUICK_TOSS_DURATION * motion_scale
	return (
		FIRST_TOSS_DURATION if index == 0 else FOLLOWUP_TOSS_DURATION
	) * motion_scale


func _motion_scale() -> float:
	var base := float(MotionPolicy.BASE_DURATIONS.get("card_place", 0.46))
	if base <= 0.0:
		return 1.0
	return maxf(0.1, MotionPolicy.duration("card_place") / base)


func _coin_lift(progress: float) -> float:
	if progress <= 0.82:
		return sin((progress / 0.82) * PI) * 94.0
	var bounce_progress := (progress - 0.82) / 0.18
	return sin(bounce_progress * PI) * (1.0 - bounce_progress) * 13.0


func _coin_vertical_scale(progress: float) -> float:
	if MotionPolicy.reduced() or progress <= 0.0 or progress >= 1.0:
		return 1.0
	return maxf(0.08, absf(cos(progress * PI * 17.0)))


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	draw_style_box(
		_showcase_style(),
		rect.grow(-2.0),
	)
	var base_center := Vector2(rect.size.x * 0.5, minf(118.0, rect.size.y * 0.43))
	var lift_ratio := clampf(_coin_lift(_toss_progress) / 94.0, 0.0, 1.0)
	var shadow_size := Vector2(92.0 - lift_ratio * 30.0, 18.0 - lift_ratio * 6.0)
	var shadow_center := base_center + Vector2(0, COIN_SIZE * 0.54)
	var points := PackedVector2Array()
	for index in range(32):
		var angle := TAU * float(index) / 32.0
		points.append(shadow_center + Vector2(
			cos(angle) * shadow_size.x * 0.5,
			sin(angle) * shadow_size.y * 0.5,
		))
	draw_colored_polygon(points, Color(0.0, 0.0, 0.0, 0.34 - lift_ratio * 0.16))
	if _current_index >= 0 and _toss_progress >= 0.82:
		var burst_progress := clampf((_toss_progress - 0.82) / 0.18, 0.0, 1.0)
		for index in range(12):
			var angle := TAU * float(index) / 12.0 + float(_current_index) * 0.37
			var radius := lerpf(48.0, 78.0, burst_progress)
			var particle_center := base_center + Vector2.from_angle(angle) * radius
			var particle_radius := lerpf(4.0, 1.6, burst_progress)
			draw_circle(
				particle_center,
				particle_radius,
				Color(1.0, 0.78, 0.25, 0.88 - burst_progress * 0.28),
			)


func _showcase_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.036, 0.067, 0.96)
	style.border_color = Color(0.94, 0.68, 0.20, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(16)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0, 5)
	return style

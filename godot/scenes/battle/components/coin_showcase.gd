class_name CoinShowcase
extends Control

signal audio_requested(cue: String)
signal audio_event_requested(request: AudioCueRequest)
signal audio_scope_cancel_requested(scope_id: StringName)

const COIN_SIZE := 104.0


var title_text := "抛硬币"
var persistent := false
var results: Array[bool] = []
var _history_count := 0
var _current_index := -1
var _toss_progress := 0.0
var _generation := 0
var _active_handle: MotionHandle
var _active_tween: Tween
var render_in_table := false
var embedded_stage: CoinStage3D
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
	_toss_progress = 0.0
	modulate = Color.WHITE
	visible = true
	_build_nodes()
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
		_active_tween.tween_interval(MotionPolicy.PROFILE.coin_reduced_hold)
	else:
		for index in range(results.size()):
			var duration := _duration_for_index(index)
			_active_tween.tween_callback(_begin_toss.bind(index))
			_active_tween.tween_method(
				_set_toss_progress.bind(index),
				0.0,
				1.0,
				duration,
			).set_trans(Tween.TRANS_LINEAR)
			_active_tween.tween_callback(_complete_toss.bind(index))
			_active_tween.tween_interval(
				(MotionPolicy.PROFILE.coin_result_gap if index + 1 < results.size() else MotionPolicy.PROFILE.coin_result_hold)
			)
	if not persistent:
		_active_tween.tween_property(self, "modulate:a", 0.0, MotionPolicy.duration("coin_fade"))
	handle.completed.connect(
		_on_playback_completed.bind(run_generation),
		CONNECT_ONE_SHOT,
	)
	handle.bind_tween(_active_tween)
	return handle


func clear() -> void:
	audio_scope_cancel_requested.emit(_audio_scope())
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
	if _title_label != null:
		return
	if not render_in_table:
		embedded_stage = CoinStage3D.new()
		embedded_stage.name = "PhysicalCoinStage"
		embedded_stage.sample_pose = render_coin
		add_child(embedded_stage)
		embedded_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", DesignTokens.TEXT)
	add_child(_title_label)

	_summary_label = Label.new()
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary_label.add_theme_font_size_override("font_size", 18)
	_summary_label.add_theme_color_override("font_color", DesignTokens.TEXT)
	add_child(_summary_label)

	_history_label = Label.new()
	_history_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_history_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_history_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_history_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_history_label.add_theme_font_size_override("font_size", 15)
	_history_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	add_child(_history_label)


func _layout_nodes() -> void:
	if _title_label == null:
		return
	_title_label.position = Vector2(12, 3)
	_title_label.size = Vector2(maxf(0.0, size.x - 24), 32)
	var footer := _result_rect()
	_summary_label.position = footer.position + Vector2(12, 7)
	_summary_label.size = Vector2(footer.size.x - 24, 28)
	_history_label.position = footer.position + Vector2(12, 38)
	_history_label.size = Vector2(footer.size.x - 24, maxf(0.0, footer.size.y - 43))
	if embedded_stage != null:
		embedded_stage._sync_frame()


## Both the table and choice modal sample this exact authoritative timeline.
func render_coin(coin: CoinEntity3D, projection: BattleProjection3D, to_render := Transform2D.IDENTITY) -> void:
	coin.visible = is_visible_in_tree() and not results.is_empty() and _current_index >= 0
	if not coin.visible:
		return
	var index := clampi(_current_index, 0, results.size() - 1)
	var start_heads: bool = results[index - 1] if index > 0 else not results[index]
	var center := _coin_center()
	coin.pose_for_toss(projection, to_render * center, COIN_SIZE * 1.12 * to_render.x.length(),
		_toss_progress, results[index], start_heads, MotionPolicy.reduced())


func is_playing() -> bool:
	return _active_handle != null and not _active_handle.is_finished()


func _coin_center() -> Vector2:
	return Vector2(size.x * 0.5, size.y * 0.50)


func _begin_toss(index: int) -> void:
	_current_index = index
	_toss_progress = 0.0
	_emit_audio("coin_toss", index)
	_update_text()
	_layout_nodes()
	queue_redraw()


func _set_toss_progress(progress: float, index: int) -> void:
	if index != _current_index:
		return
	_toss_progress = clampf(progress, 0.0, 1.0)
	if _toss_progress >= MotionPolicy.PROFILE.coin_contact_fraction:
		_land_toss(index)
	_layout_nodes()
	queue_redraw()


func _complete_toss(index: int) -> void:
	_current_index = index
	_toss_progress = 1.0
	_land_toss(index)
	_update_text()
	_layout_nodes()
	queue_redraw()


func _land_toss(index: int) -> void:
	if _history_count > index:
		return
	_history_count = index + 1
	_emit_audio("coin_land", _current_index)
	_update_text()


func _show_reduced_result() -> void:
	_history_count = results.size()
	_current_index = results.size() - 1
	_toss_progress = 1.0
	_emit_audio("coin_land", _current_index)
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
	if results.size() > 6 and index >= 3 and index < results.size() - 1:
		return MotionPolicy.duration("coin_quick")
	return MotionPolicy.duration("coin_first" if index == 0 else "coin_followup")


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var title_width := _label_plate_width(_title_label, 56, 180)
	var title_rect := Rect2((size.x - title_width) * 0.5, 0, title_width, 40)
	draw_style_box(_showcase_style(), title_rect)
	draw_line(title_rect.position + Vector2(18, 39), title_rect.end - Vector2(18, 1), Color(DesignTokens.GOLD, 0.55), 1.5, true)
	draw_style_box(_showcase_style(), _result_rect())
	var center := _coin_center()
	var landing := MotionPolicy.PROFILE.coin_contact_fraction
	if _toss_progress >= landing and not MotionPolicy.reduced():
		var contact := clampf((_toss_progress - landing) / (1.0 - landing), 0.0, 1.0)
		draw_arc(center, lerpf(52, 68, contact), 0, TAU, 48, Color(DesignTokens.GOLD, sin(contact * PI) * 0.42), 1.5, true)


func _label_plate_width(label: Label, padding: float, minimum: float) -> float:
	var content := 0.0
	if label != null:
		var font := label.get_theme_font("font")
		for line in label.text.split("\n"):
			content = maxf(content, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x)
	return minf(size.x - 24, maxf(minimum, content + padding))


func _result_rect() -> Rect2:
	var width := maxf(_label_plate_width(_summary_label, 40, 240), _label_plate_width(_history_label, 40, 240))
	var rows := maxi(1, ceili(float(_history_count) / 10.0))
	var height := minf(105, 46 + rows * 22)
	return Rect2((size.x - width) * 0.5, size.y - height, width, height)


func _showcase_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = DesignTokens.PANEL
	style.border_color = Color(DesignTokens.GOLD, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.shadow_color = DesignTokens.SHADOW
	style.shadow_size = 6
	style.shadow_offset = Vector2(0, 3)
	return style


func _audio_scope() -> StringName:
	return StringName("coin:%d" % get_instance_id())


func _emit_audio(cue: String, ordinal: int) -> void:
	if not is_visible_in_tree():
		return
	audio_requested.emit(cue)
	audio_event_requested.emit(AudioCueRequest.make(StringName(cue), _audio_scope(), str(_generation), cue, ordinal))

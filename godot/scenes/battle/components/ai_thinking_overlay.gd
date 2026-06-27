class_name AIThinkingOverlay
extends Control

var active := false
var reduced_motion := false
var ai_player := 1
var ai_name := "AI"
var started_msec := 0
var slot_rects: Array[Rect2] = []
var _time := 0.0
var _status_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	modulate.a = 0.0
	set_process(false)
	_ensure_status_label()
	resized.connect(_layout_status_label)


func configure(
	p_active: bool,
	p_ai_player: int,
	p_slot_rects: Array[Rect2],
	p_reduced_motion: bool,
	p_ai_name: String = "AI",
	p_started_msec: int = 0,
) -> void:
	_ensure_status_label()
	active = p_active
	ai_player = p_ai_player
	slot_rects = p_slot_rects.duplicate()
	reduced_motion = p_reduced_motion
	ai_name = p_ai_name if not p_ai_name.strip_edges().is_empty() else "AI"
	started_msec = p_started_msec
	visible = active
	modulate.a = 1.0 if active else 0.0
	if _status_label:
		_status_label.visible = active
	_update_status_label()
	_layout_status_label()
	set_process(active)
	queue_redraw()


func is_animating() -> bool:
	return active and not reduced_motion


func _process(delta: float) -> void:
	_time += delta
	_update_status_label()
	if not reduced_motion:
		queue_redraw()


func _draw() -> void:
	if not active:
		return
	var accent := DesignTokens.RED.lightened(0.12)
	var pulse := 0.0 if reduced_motion else (sin(_time * 3.2) + 1.0) * 0.5
	var ring_alpha := 0.16 if reduced_motion else 0.12 + pulse * 0.10
	for rect in slot_rects:
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		var grown := rect.grow(9.0 + pulse * 4.0)
		var radius := maxf(8.0, minf(grown.size.x, grown.size.y) * 0.09)
		var fill := Color(accent.r, accent.g, accent.b, 0.035 + ring_alpha * 0.18)
		var border := Color(accent.r, accent.g, accent.b, ring_alpha)
		draw_rect(grown, fill, true)
		draw_rect(grown, border, false, 2.0)
		_draw_corner_ticks(grown, border.lightened(0.2), radius)
	if reduced_motion:
		return
	var scan_y := fposmod(_time * 86.0, maxf(1.0, size.y))
	var scan_color := Color(accent.r, accent.g, accent.b, 0.10)
	draw_rect(Rect2(0, scan_y, size.x, 2.0), scan_color, true)


func _ensure_status_label() -> void:
	if _status_label != null:
		return
	_status_label = Label.new()
	_status_label.name = "AIThinkingStatus"
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.custom_minimum_size = Vector2(278.0, 38.0)
	_status_label.size = _status_label.custom_minimum_size
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", DesignTokens.TEXT)
	_status_label.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color(0.055, 0.10, 0.17, 0.96),
			8,
			DesignTokens.CYAN.darkened(0.10),
			1,
			10,
		),
	)
	_status_label.visible = false
	add_child(_status_label)


func _layout_status_label() -> void:
	if _status_label == null:
		return
	var label_size := _status_label.custom_minimum_size
	_status_label.size = label_size
	_status_label.position = Vector2(
		clampf(size.x * 0.165, 116.0, maxf(116.0, size.x - label_size.x - 24.0)),
		clampf(size.y * 0.49 - label_size.y * 0.5, 72.0, maxf(72.0, size.y - label_size.y - 72.0)),
	)


func _update_status_label() -> void:
	if _status_label == null:
		return
	var elapsed := 0.0
	if started_msec > 0:
		elapsed = float(Time.get_ticks_msec() - started_msec) / 1000.0
	var dots := ""
	if not reduced_motion:
		var dot_count := int(floor(_time * 2.4)) % 4
		for _index in range(dot_count):
			dots += "."
	_status_label.text = "%s 思考中%s · %.1fs" % [
		ai_name,
		dots,
		maxf(0.0, elapsed),
	]


func _draw_corner_ticks(rect: Rect2, color: Color, length: float) -> void:
	var width := 2.0
	draw_line(rect.position, rect.position + Vector2(length, 0), color, width)
	draw_line(rect.position, rect.position + Vector2(0, length), color, width)
	draw_line(
		rect.position + Vector2(rect.size.x, 0),
		rect.position + Vector2(rect.size.x - length, 0),
		color,
		width,
	)
	draw_line(
		rect.position + Vector2(rect.size.x, 0),
		rect.position + Vector2(rect.size.x, length),
		color,
		width,
	)
	draw_line(
		rect.position + Vector2(0, rect.size.y),
		rect.position + Vector2(length, rect.size.y),
		color,
		width,
	)
	draw_line(
		rect.position + Vector2(0, rect.size.y),
		rect.position + Vector2(0, rect.size.y - length),
		color,
		width,
	)
	draw_line(
		rect.position + rect.size,
		rect.position + rect.size - Vector2(length, 0),
		color,
		width,
	)
	draw_line(
		rect.position + rect.size,
		rect.position + rect.size - Vector2(0, length),
		color,
		width,
	)

class_name BattlePlaymat
extends Control

var quality_profile := "high"
var _time := 0.0
var _redraw_accumulator := 0.0
var _field_guides: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func _process(delta: float) -> void:
	_time += delta
	if quality_profile == "low":
		return
	_redraw_accumulator += delta
	var interval := 1.0 / (20.0 if quality_profile == "high" else 12.0)
	if _redraw_accumulator >= interval:
		_redraw_accumulator = 0.0
		queue_redraw()


func set_field_guides(guides: Array[Dictionary]) -> void:
	_field_guides = guides.duplicate(true)
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color("#070b13"))
	_draw_backdrop()
	_draw_side_rails()
	var table_points := _table_points()
	var table_shadow := table_points.duplicate()
	for index in range(table_shadow.size()):
		table_shadow[index] += Vector2(0, 11)
	draw_colored_polygon(table_shadow, Color(0, 0, 0, 0.30))
	draw_colored_polygon(table_points, Color(0.095, 0.125, 0.17, 0.92))
	_draw_table_depth(table_points)
	_draw_table_inner(table_points)
	if quality_profile != "low":
		_draw_subtle_grid(table_points)
	if _field_guides.is_empty():
		_draw_slot_markers()
	else:
		_draw_field_guides()
	_draw_center_lines()


func _draw_backdrop() -> void:
	var middle := size.y * 0.50
	var bands := 16 if quality_profile == "low" else 36
	for index in range(bands):
		var t := float(index) / float(maxi(1, bands - 1))
		var y := size.y * t
		var top_side := y < middle
		var local_t := y / middle if top_side else (y - middle) / maxf(1.0, size.y - middle)
		var color := (
			Color("#3e0610").lerp(Color("#130912"), local_t)
			if top_side
			else Color("#03215f").lerp(Color("#06101f"), local_t)
		)
		draw_rect(Rect2(0, y, size.x, size.y / float(bands) + 1.0), color)


func _draw_side_rails() -> void:
	var rail_height := maxf(42.0, size.y * 0.070)
	var top_rail := PackedVector2Array([
		Vector2(0, 0),
		Vector2(size.x, 0),
		Vector2(size.x - size.x * 0.055, rail_height),
		Vector2(size.x * 0.055, rail_height),
	])
	var bottom_rail := PackedVector2Array([
		Vector2(size.x * 0.055, size.y - rail_height),
		Vector2(size.x - size.x * 0.055, size.y - rail_height),
		Vector2(size.x, size.y),
		Vector2(0, size.y),
	])
	draw_colored_polygon(top_rail, Color(0.54, 0.03, 0.08, 0.66))
	draw_colored_polygon(bottom_rail, Color(0.03, 0.18, 0.62, 0.70))
	var accent := Color("#f4e94a")
	accent.a = 0.72
	draw_line(
		Vector2(size.x * 0.07, rail_height + 8),
		Vector2(size.x * 0.93, rail_height + 8),
		accent,
		3.0,
	)
	draw_line(
		Vector2(size.x * 0.07, size.y - rail_height - 8),
		Vector2(size.x * 0.93, size.y - rail_height - 8),
		accent,
		3.0,
	)


func _table_points() -> PackedVector2Array:
	var inset_x := maxf(54.0, size.x * 0.065)
	var top_y := maxf(82.0, size.y * 0.13)
	var bottom_y := size.y - maxf(76.0, size.y * 0.12)
	var top_width := size.x - inset_x * 2.6
	var bottom_width := size.x - inset_x * 1.28
	var center_x := size.x * 0.5
	var cut_top := maxf(34.0, size.x * 0.026)
	var cut_bottom := maxf(46.0, size.x * 0.034)
	var top_left := center_x - top_width * 0.5
	var top_right := center_x + top_width * 0.5
	var bottom_left := center_x - bottom_width * 0.5
	var bottom_right := center_x + bottom_width * 0.5
	return PackedVector2Array([
		Vector2(top_left + cut_top, top_y),
		Vector2(top_right - cut_top, top_y),
		Vector2(top_right, top_y + cut_top),
		Vector2(bottom_right, bottom_y - cut_bottom),
		Vector2(bottom_right - cut_bottom, bottom_y),
		Vector2(bottom_left + cut_bottom, bottom_y),
		Vector2(bottom_left, bottom_y - cut_bottom),
		Vector2(top_left, top_y + cut_top),
	])


func _draw_table_depth(points: PackedVector2Array) -> void:
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, Color(0.60, 0.66, 0.72, 0.66), 5.0)
	draw_polyline(outline, Color(0.02, 0.03, 0.05, 0.86), 1.5)
	var bottom_edge := PackedVector2Array([
		points[4],
		points[5],
		points[5] + Vector2(0, 13),
		points[4] + Vector2(0, 13),
	])
	draw_colored_polygon(bottom_edge, Color(0.025, 0.035, 0.052, 0.72))


func _draw_table_inner(points: PackedVector2Array) -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.50)
	var radius := minf(size.x, size.y) * 0.30
	var pulse := 0.055
	if quality_profile != "low":
		pulse += sin(_time * 0.65) * 0.012
	draw_circle(center, radius, Color(0.82, 0.88, 1.0, pulse))
	draw_circle(center, radius * 0.56, Color(0.58, 0.72, 1.0, pulse * 0.76))
	draw_line(
		Vector2(points[7].x + 20, center.y),
		Vector2(points[3].x - 20, center.y),
		Color(0.86, 0.91, 1.0, 0.28),
		2.0,
	)
	draw_arc(center, radius * 0.98, -0.08, TAU + 0.08, 96, Color(1, 1, 1, 0.08), 1.5)
	draw_arc(center, radius * 0.56, 0.0, TAU, 96, Color(1, 1, 1, 0.10), 1.5)


func _draw_subtle_grid(points: PackedVector2Array) -> void:
	var grid_color := Color(0.72, 0.82, 0.92, 0.045)
	var top_y := points[0].y + 8.0
	var bottom_y := points[5].y - 8.0
	for index in range(1, 11):
		var t := float(index) / 11.0
		var x_top := lerpf(points[7].x + 32.0, points[2].x - 32.0, t)
		var x_bottom := lerpf(points[6].x + 40.0, points[3].x - 40.0, t)
		draw_line(Vector2(x_top, top_y), Vector2(x_bottom, bottom_y), grid_color, 1.0)
	for index in range(1, 7):
		var t := float(index) / 7.0
		var y := lerpf(top_y, bottom_y, t)
		var left := lerpf(points[7].x + 10.0, points[6].x + 18.0, t)
		var right := lerpf(points[2].x - 10.0, points[3].x - 18.0, t)
		draw_line(Vector2(left, y), Vector2(right, y), grid_color, 1.0)


func _draw_slot_markers() -> void:
	var center_x := size.x * 0.5
	var middle := size.y * 0.50
	var active_size := Vector2(size.x * 0.085, size.y * 0.145)
	_draw_slot_rect(
		Rect2(center_x - active_size.x * 0.5, middle - active_size.y - 14.0, active_size.x, active_size.y),
		Color(0.95, 0.18, 0.24, 0.12),
	)
	_draw_slot_rect(
		Rect2(center_x - active_size.x * 0.5, middle + 14.0, active_size.x, active_size.y),
		Color(0.15, 0.44, 1.0, 0.15),
	)
	var bench_w := size.x * 0.052
	var bench_h := size.y * 0.092
	var gap := size.x * 0.015
	var total := bench_w * 5.0 + gap * 4.0
	var start_x := center_x - total * 0.5
	for index in range(5):
		_draw_slot_rect(
			Rect2(start_x + float(index) * (bench_w + gap), middle - active_size.y - bench_h - 28.0, bench_w, bench_h),
			Color(0.95, 0.18, 0.24, 0.09),
		)
		_draw_slot_rect(
			Rect2(start_x + float(index) * (bench_w + gap), middle + active_size.y + 30.0, bench_w, bench_h),
			Color(0.15, 0.44, 1.0, 0.11),
		)


func _draw_field_guides() -> void:
	for guide_value in _field_guides:
		var guide: Dictionary = guide_value
		match str(guide.get("kind", "")):
			"bench":
				_draw_bench_tray(guide)
			"active":
				_draw_active_pad(guide)


func _draw_bench_tray(guide: Dictionary) -> void:
	var rect: Rect2 = guide.get("rect", Rect2())
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var side := str(guide.get("side", "own"))
	var depth := clampf(float(guide.get("depth", 0.5)), 0.0, 1.0)
	var accent := Color("#4b95ff") if side == "own" else Color("#ef6572")
	var shadow_offset := Vector2(0, 8.0 + depth * 8.0)
	_draw_beveled_panel(
		Rect2(rect.position + shadow_offset, rect.size),
		Color(0, 0, 0, 0.28),
		Color(0, 0, 0, 0.0),
		0.0,
		maxf(10.0, rect.size.y * 0.14),
	)
	_draw_beveled_panel(
		rect,
		Color(0.055, 0.060, 0.070, 0.86),
		accent.darkened(0.26),
		3.0,
		maxf(10.0, rect.size.y * 0.14),
	)
	var inner := rect.grow(-5.0)
	_draw_beveled_panel(
		inner,
		Color(0.24, 0.24, 0.27, 0.70),
		Color(1, 1, 1, 0.11),
		1.0,
		maxf(8.0, inner.size.y * 0.11),
	)
	var lip_rect := Rect2(rect.position, Vector2(rect.size.x, maxf(5.0, rect.size.y * 0.08)))
	draw_rect(lip_rect, accent.lightened(0.12) * Color(1, 1, 1, 0.72), true)
	var slots: Array = guide.get("slots", [])
	for slot_value in slots:
		var slot_rect: Rect2 = slot_value
		var slot_fill := Color(0.0, 0.0, 0.0, 0.15)
		_draw_beveled_panel(
			slot_rect.grow(4.0),
			slot_fill,
			Color(1, 1, 1, 0.08),
			1.0,
			maxf(5.0, slot_rect.size.x * 0.09),
		)


func _draw_active_pad(guide: Dictionary) -> void:
	var rect: Rect2 = guide.get("rect", Rect2())
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var side := str(guide.get("side", "own"))
	var depth := clampf(float(guide.get("depth", 0.5)), 0.0, 1.0)
	var accent := Color("#62d7ff") if side == "own" else Color("#ff7a8a")
	var center := rect.position + rect.size * 0.5
	var radius := maxf(rect.size.x, rect.size.y) * (0.54 + depth * 0.08)
	var glow := 0.12 + sin(_time * 1.2) * 0.018 if quality_profile != "low" else 0.10
	draw_circle(center, radius, Color(accent.r, accent.g, accent.b, glow))
	draw_circle(center, radius * 0.68, Color(1, 1, 1, glow * 0.42))
	_draw_beveled_panel(
		rect.grow(9.0),
		Color(0.015, 0.030, 0.036, 0.28),
		accent.darkened(0.10),
		1.5,
		maxf(9.0, rect.size.x * 0.08),
	)


func _draw_slot_rect(slot: Rect2, color: Color) -> void:
	draw_rect(slot, color, true)
	draw_rect(slot, Color(1, 1, 1, 0.10), false, 1.0)


func _draw_beveled_panel(
	rect: Rect2,
	fill: Color,
	border: Color,
	border_width: float,
	cut: float,
) -> void:
	var points := _beveled_points(rect, cut)
	draw_colored_polygon(points, fill)
	if border_width > 0.0 and border.a > 0.0:
		var outline := points.duplicate()
		outline.append(points[0])
		draw_polyline(outline, border, border_width)


func _beveled_points(rect: Rect2, cut: float) -> PackedVector2Array:
	var c := clampf(cut, 0.0, minf(rect.size.x, rect.size.y) * 0.42)
	return PackedVector2Array([
		rect.position + Vector2(c, 0),
		rect.position + Vector2(rect.size.x - c, 0),
		rect.position + Vector2(rect.size.x, c),
		rect.position + Vector2(rect.size.x, rect.size.y - c),
		rect.position + Vector2(rect.size.x - c, rect.size.y),
		rect.position + Vector2(c, rect.size.y),
		rect.position + Vector2(0, rect.size.y - c),
		rect.position + Vector2(0, c),
	])


func _draw_center_lines() -> void:
	var middle := size.y * 0.50
	draw_line(
		Vector2(size.x * 0.12, middle - 1.0),
		Vector2(size.x * 0.88, middle - 1.0),
		Color(1, 1, 1, 0.12),
		1.0,
	)

class_name BattlePlaymat
extends Control

var quality_profile := "high":
	set(value):
		quality_profile = value
		_update_processing()
		if is_inside_tree():
			queue_redraw()
var _time := 0.0
var _redraw_accumulator := 0.0
var _field_guides: Array[Dictionary] = []
var _pile_guides: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_update_processing()


func _process(delta: float) -> void:
	if not _animations_enabled():
		set_process(false)
		queue_redraw()
		return
	_time += delta
	_redraw_accumulator += delta
	# The playmat is almost entirely static. These restrained refresh rates keep
	# the ambient scan and glow alive without turning the board into a costly
	# full-screen animation.
	var interval := 1.0 / (16.0 if quality_profile == "high" else 8.0)
	if _redraw_accumulator >= interval:
		_redraw_accumulator = 0.0
		queue_redraw()


func _update_processing() -> void:
	if not is_inside_tree():
		return
	set_process(_animations_enabled())


func _animations_enabled() -> bool:
	if quality_profile == "low" or not is_inside_tree():
		return false
	var settings := get_node_or_null("/root/AppSettings")
	return settings == null or not bool(settings.get("reduced_motion"))


func set_field_guides(guides: Array[Dictionary]) -> void:
	_field_guides = guides.duplicate(true)
	queue_redraw()


func set_pile_guides(guides: Array[Dictionary]) -> void:
	_pile_guides = guides.duplicate(true)
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color("#04070d"))
	_draw_backdrop()
	_draw_side_rails()
	var table_points := _table_points()
	_draw_table_shell(table_points)
	_draw_table_depth(table_points)
	_draw_honeycomb_texture(table_points)
	if quality_profile != "low":
		_draw_subtle_grid(table_points)
	_draw_table_inner(table_points)
	_draw_scan_light(table_points)
	_draw_ambient_sparks(table_points)
	_draw_pile_docks()
	if _field_guides.is_empty():
		_draw_slot_markers()
	else:
		_draw_field_guides()
	_draw_center_lines()


func _draw_backdrop() -> void:
	var middle := size.y * 0.50
	var bands := 14 if quality_profile == "low" else 28 if quality_profile == "medium" else 44
	for index in range(bands):
		var t := float(index) / float(maxi(1, bands - 1))
		var y := size.y * t
		var top_side := y < middle
		var local_t := y / middle if top_side else (y - middle) / maxf(1.0, size.y - middle)
		var color := (
			Color("#4a0713").lerp(Color("#120a12"), local_t)
			if top_side
			else Color("#07101d").lerp(Color("#032768"), local_t)
		)
		draw_rect(Rect2(0, y, size.x, size.y / float(bands) + 1.0), color)
	# A quiet horizon and dark side wings make the arena feel recessed without
	# stealing contrast from cards placed along the outer lanes.
	draw_rect(Rect2(0, middle - 2.0, size.x, 4.0), Color(0, 0, 0, 0.42))
	draw_rect(Rect2(0, middle - 0.5, size.x, 1.0), Color(0.68, 0.78, 0.90, 0.13))
	var wing_width := maxf(70.0, size.x * 0.085)
	for index in range(8):
		var alpha := 0.018 + float(index) * 0.012
		var offset := float(index) * wing_width / 8.0
		draw_rect(Rect2(offset, 0, wing_width / 8.0 + 1.0, size.y), Color(0, 0, 0, alpha))
		draw_rect(
			Rect2(size.x - offset - wing_width / 8.0, 0, wing_width / 8.0 + 1.0, size.y),
			Color(0, 0, 0, alpha),
		)


func _draw_side_rails() -> void:
	var rail_height := maxf(48.0, size.y * 0.078)
	var top_rail := PackedVector2Array([
		Vector2(0, 0),
		Vector2(size.x, 0),
		Vector2(size.x - size.x * 0.060, rail_height),
		Vector2(size.x * 0.060, rail_height),
	])
	var bottom_rail := PackedVector2Array([
		Vector2(size.x * 0.060, size.y - rail_height),
		Vector2(size.x - size.x * 0.060, size.y - rail_height),
		Vector2(size.x, size.y),
		Vector2(0, size.y),
	])
	draw_colored_polygon(top_rail, Color("#17080d"))
	draw_colored_polygon(bottom_rail, Color("#07101f"))
	var top_color := Color("#d8324f")
	var bottom_color := Color("#3078e8")
	top_color.a = 0.48
	bottom_color.a = 0.54
	draw_polyline(_closed_points(top_rail), top_color, 7.0)
	draw_polyline(_closed_points(bottom_rail), bottom_color, 7.0)
	var metal := Color(0.72, 0.78, 0.84, 0.42)
	draw_line(
		Vector2(size.x * 0.075, rail_height + 5.0),
		Vector2(size.x * 0.925, rail_height + 5.0),
		metal,
		2.0,
	)
	draw_line(
		Vector2(size.x * 0.075, size.y - rail_height - 5.0),
		Vector2(size.x * 0.925, size.y - rail_height - 5.0),
		metal,
		2.0,
	)
	_draw_rail_ticks(rail_height, true, top_color)
	_draw_rail_ticks(size.y - rail_height, false, bottom_color)


func _draw_rail_ticks(y: float, points_down: bool, color: Color) -> void:
	var direction := 1.0 if points_down else -1.0
	for index in range(5):
		var x := lerpf(size.x * 0.25, size.x * 0.75, float(index) / 4.0)
		draw_line(Vector2(x - 13.0, y), Vector2(x - 6.0, y + direction * 6.0), color, 2.0)
		draw_line(Vector2(x - 6.0, y + direction * 6.0), Vector2(x + 13.0, y), color, 2.0)


func _table_points() -> PackedVector2Array:
	var inset_x := maxf(44.0, size.x * 0.045)
	var top_y := maxf(64.0, size.y * 0.098)
	var bottom_y := size.y - maxf(62.0, size.y * 0.094)
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


func _draw_table_shell(points: PackedVector2Array) -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.5)
	var shadow := points.duplicate()
	for index in range(shadow.size()):
		shadow[index] += Vector2(0, 14.0)
	draw_colored_polygon(shadow, Color(0, 0, 0, 0.46))
	draw_colored_polygon(points, Color("#111722"))
	draw_polyline(_closed_points(points), Color(0.01, 0.015, 0.025, 0.95), 18.0)
	draw_polyline(_closed_points(points), Color(0.40, 0.46, 0.54, 0.82), 11.0)
	draw_polyline(_closed_points(points), Color(0.76, 0.82, 0.88, 0.58), 5.0)
	draw_polyline(_closed_points(points), Color(0.035, 0.050, 0.075, 0.96), 2.0)
	var glass_points := _scale_points(points, center, 0.982)
	draw_colored_polygon(glass_points, Color(0.035, 0.065, 0.105, 0.95))
	var top_glass := _table_half_points(glass_points, true)
	var bottom_glass := _table_half_points(glass_points, false)
	draw_colored_polygon(top_glass, Color(0.24, 0.025, 0.055, 0.13))
	draw_colored_polygon(bottom_glass, Color(0.025, 0.12, 0.34, 0.16))
	# Two translucent inset plates sell the laminated glass construction.
	var inner := _scale_points(points, center, 0.955)
	draw_polyline(_closed_points(inner), Color(0.55, 0.70, 0.84, 0.22), 2.0)
	var core := _scale_points(points, center, 0.925)
	draw_polyline(_closed_points(core), Color(0.01, 0.03, 0.06, 0.64), 1.0)


func _draw_table_depth(points: PackedVector2Array) -> void:
	var bottom_edge := PackedVector2Array([
		points[4],
		points[5],
		points[5] + Vector2(0, 15),
		points[4] + Vector2(0, 15),
	])
	draw_colored_polygon(bottom_edge, Color(0.015, 0.025, 0.045, 0.90))
	draw_line(points[5], points[4], Color(0.74, 0.82, 0.90, 0.32), 2.0)


func _draw_table_inner(points: PackedVector2Array) -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.50)
	var radius := Vector2(minf(size.x * 0.275, 410.0), minf(size.y * 0.285, 238.0))
	var pulse := 0.052
	if _animations_enabled():
		pulse += sin(_time * 0.52) * 0.010
	var lens := _ellipse_points(center, radius * 0.62, 96)
	draw_colored_polygon(lens, Color(0.25, 0.52, 0.76, pulse * 0.44))
	for ring_scale in [1.0, 0.78, 0.61, 0.43]:
		var ring := _ellipse_points(center, radius * float(ring_scale), 96)
		draw_polyline(_closed_points(ring), Color(0.70, 0.82, 0.94, pulse + 0.025), 1.5)
	var upper_arc := _ellipse_arc_points(center, radius * 1.02, PI, TAU, 48)
	var lower_arc := _ellipse_arc_points(center, radius * 1.02, 0.0, PI, 48)
	draw_polyline(upper_arc, Color(1.0, 0.22, 0.34, 0.16), 3.0)
	draw_polyline(lower_arc, Color(0.18, 0.52, 1.0, 0.18), 3.0)
	draw_line(
		Vector2(points[7].x + 26.0, center.y),
		Vector2(points[3].x - 26.0, center.y),
		Color(0.80, 0.88, 0.96, 0.16),
		1.0,
	)
	var core := _ellipse_points(center, Vector2(34.0, 18.0), 32)
	draw_colored_polygon(core, Color(0.72, 0.86, 1.0, 0.075))
	draw_polyline(_closed_points(core), Color(0.85, 0.93, 1.0, 0.18), 1.0)


func _draw_honeycomb_texture(points: PackedVector2Array) -> void:
	if quality_profile == "low":
		return
	var center := Vector2(size.x * 0.5, size.y * 0.5)
	# Medium uses fewer, larger cells; high keeps the texture crisp while still
	# avoiding hundreds of tiny per-frame primitives on wide screens.
	var radius := 26.0 if quality_profile == "high" else 38.0
	var horizontal_step := radius * 1.76
	var vertical_step := radius * 1.52
	var top_y := points[0].y + radius * 1.5
	var bottom_y := points[5].y - radius * 1.5
	var row := 0
	var y := top_y
	while y <= bottom_y:
		var x := points[7].x + radius * 2.0 + (horizontal_step * 0.5 if row % 2 == 1 else 0.0)
		while x <= points[2].x - radius * 2.0:
			var hex_center := Vector2(x, y)
			if _point_inside_polygon(hex_center, points):
				var edge_factor := clampf(absf(x - center.x) / maxf(1.0, size.x * 0.46), 0.0, 1.0)
				var alpha := 0.016 + edge_factor * edge_factor * 0.042
				var tint := Color("#ff6479") if y < center.y else Color("#62a5ff")
				tint = Color(0.60, 0.70, 0.80, 1.0).lerp(tint, edge_factor * 0.34)
				tint.a = alpha
				var hexagon := _hex_points(hex_center, radius)
				draw_polyline(_closed_points(hexagon), tint, 1.0)
			x += horizontal_step
		y += vertical_step
		row += 1


func _draw_subtle_grid(points: PackedVector2Array) -> void:
	var grid_color := Color(0.68, 0.80, 0.92, 0.035)
	var top_y := points[0].y + 8.0
	var bottom_y := points[5].y - 8.0
	for index in range(1, 9):
		var t := float(index) / 9.0
		var x_top := lerpf(points[7].x + 32.0, points[2].x - 32.0, t)
		var x_bottom := lerpf(points[6].x + 40.0, points[3].x - 40.0, t)
		draw_line(Vector2(x_top, top_y), Vector2(x_bottom, bottom_y), grid_color, 1.0)
	for index in range(1, 6):
		var t := float(index) / 6.0
		var y := lerpf(top_y, bottom_y, t)
		var left := lerpf(points[7].x + 10.0, points[6].x + 18.0, t)
		var right := lerpf(points[2].x - 10.0, points[3].x - 18.0, t)
		draw_line(Vector2(left, y), Vector2(right, y), grid_color, 1.0)


func _draw_scan_light(points: PackedVector2Array) -> void:
	if not _animations_enabled():
		return
	var travel := fmod(_time * (0.060 if quality_profile == "high" else 0.040), 1.0)
	var top_y := points[0].y + 26.0
	var bottom_y := points[5].y - 26.0
	var y := lerpf(top_y, bottom_y, travel)
	var half_height := 18.0 if quality_profile == "high" else 24.0
	var upper_bounds := _table_bounds_at_y(points, y - half_height)
	var lower_bounds := _table_bounds_at_y(points, y + half_height)
	var beam := PackedVector2Array([
		Vector2(upper_bounds.x + 18.0, y - half_height),
		Vector2(upper_bounds.y - 18.0, y - half_height),
		Vector2(lower_bounds.y - 18.0, y + half_height),
		Vector2(lower_bounds.x + 18.0, y + half_height),
	])
	draw_colored_polygon(beam, Color(0.52, 0.77, 1.0, 0.016 if quality_profile == "high" else 0.010))
	var bounds := _table_bounds_at_y(points, y)
	draw_line(
		Vector2(bounds.x + 22.0, y),
		Vector2(bounds.y - 22.0, y),
		Color(0.72, 0.88, 1.0, 0.065 if quality_profile == "high" else 0.036),
		1.0,
	)


func _draw_ambient_sparks(points: PackedVector2Array) -> void:
	if quality_profile != "high" or not _animations_enabled():
		return
	for index in range(14):
		var seed := float(index + 1)
		var x := size.x * (0.18 + fmod(absf(sin(seed * 27.13)) * 43758.5, 1.0) * 0.64)
		var y := size.y * (0.22 + fmod(absf(sin(seed * 11.91)) * 131.7, 1.0) * 0.56)
		var point := Vector2(x, y)
		if not _point_inside_polygon(point, points):
			continue
		var twinkle := 0.5 + sin(_time * 0.75 + seed * 1.7) * 0.5
		var radius := 0.7 + fmod(seed * 0.73, 1.0) * 1.1
		draw_circle(point, radius, Color(0.80, 0.91, 1.0, 0.055 + twinkle * 0.09))


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


func _draw_pile_docks() -> void:
	for guide_value in _pile_guides:
		var guide: Dictionary = guide_value
		_draw_pile_dock(guide)


func _draw_pile_dock(guide: Dictionary) -> void:
	var rect: Rect2 = guide.get("rect", Rect2())
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var side := str(guide.get("side", "own"))
	var depth := clampf(float(guide.get("depth", 0.5)), 0.0, 1.0)
	var accent := Color("#428ff2") if side == "own" else Color("#df5365")
	var fill := (
		Color(0.018, 0.060, 0.115, 0.88)
		if side == "own"
		else Color(0.105, 0.022, 0.040, 0.88)
	)
	var metal := Color(0.58, 0.66, 0.75, 0.68)
	_draw_rounded_panel(
		Rect2(rect.position + Vector2(0.0, 4.0 + depth * 2.0), rect.size),
		Color(0.0, 0.0, 0.0, 0.34),
		Color.TRANSPARENT,
		0.0,
		7.0,
	)
	_draw_rounded_panel(rect, Color("#151b24"), metal, 2.0, 7.0)
	_draw_rounded_panel(
		rect.grow(-3.0),
		fill,
		Color(0.80, 0.88, 0.96, 0.12),
		1.0,
		5.0,
	)
	# The two shallow recesses stay visible around the card silhouettes and make
	# deck plus discard read as one tabletop object, not two floating UI tiles.
	for key in ["deck_rect", "discard_rect"]:
		var slot: Rect2 = guide.get(key, Rect2())
		if slot.size.x <= 0.0 or slot.size.y <= 0.0:
			continue
		_draw_rounded_panel(
			slot.grow(2.5),
			Color(0.0, 0.008, 0.018, 0.50),
			Color(0.76, 0.84, 0.92, 0.16),
			1.0,
			4.0,
		)
	var rail_y := rect.position.y + 2.5 if side == "own" else rect.end.y - 2.5
	var rail := accent
	rail.a = 0.82
	draw_line(
		Vector2(rect.position.x + 14.0, rail_y),
		Vector2(rect.end.x - 14.0, rail_y),
		rail,
		2.5,
	)
	for bolt in [
		rect.position + Vector2(8.0, 8.0),
		Vector2(rect.end.x - 8.0, rect.position.y + 8.0),
		rect.end - Vector2(8.0, 8.0),
		Vector2(rect.position.x + 8.0, rect.end.y - 8.0),
	]:
		draw_circle(bolt, 1.7, Color(0.75, 0.82, 0.90, 0.52))


func _draw_bench_tray(guide: Dictionary) -> void:
	var rect: Rect2 = guide.get("rect", Rect2())
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var side := str(guide.get("side", "own"))
	var depth := clampf(float(guide.get("depth", 0.5)), 0.0, 1.0)
	var accent := Color("#438fe8") if side == "own" else Color("#e25868")
	var tray_fill := (
		Color(0.025, 0.105, 0.205, 0.20)
		if side == "own"
		else Color(0.205, 0.035, 0.060, 0.18)
	)
	var tray_border := accent
	tray_border.a = 0.36 + depth * 0.08
	# Bench rows are intentionally light, shallow trays. Their small-radius
	# rectangular silhouette separates each side without boxing cards inside a
	# large ornamental frame.
	_draw_rounded_panel(
		Rect2(rect.position + Vector2(0, 3.0 + depth * 2.0), rect.size),
		Color(0, 0, 0, 0.18),
		Color.TRANSPARENT,
		0.0,
		8.0,
	)
	_draw_rounded_panel(rect, tray_fill, tray_border, 1.5, 8.0)
	_draw_rounded_panel(
		rect.grow(-4.0),
		Color(0.012, 0.024, 0.042, 0.20),
		Color(0.78, 0.88, 0.96, 0.055),
		1.0,
		6.0,
	)
	var slots: Array = guide.get("slots", [])
	for slot_value in slots:
		var slot_rect: Rect2 = slot_value
		var slot_border := accent
		slot_border.a = 0.18 + depth * 0.04
		_draw_rounded_panel(
			slot_rect.grow(2.5),
			Color(0.0, 0.008, 0.018, 0.24),
			slot_border,
			1.0,
			5.0,
		)
	# The colored edge faces the duel lane, making the red and blue territories
	# legible even when all five bench positions are occupied.
	var lane_y := rect.end.y - 2.0 if side == "opponent" else rect.position.y + 2.0
	var rail_color := accent
	rail_color.a = 0.68
	draw_line(
		Vector2(rect.position.x + 14.0, lane_y),
		Vector2(rect.end.x - 14.0, lane_y),
		rail_color,
		2.0,
	)


func _draw_active_pad(guide: Dictionary) -> void:
	var rect: Rect2 = guide.get("rect", Rect2())
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var side := str(guide.get("side", "own"))
	var depth := clampf(float(guide.get("depth", 0.5)), 0.0, 1.0)
	var accent := Color("#58b7f5") if side == "own" else Color("#f56875")
	var platform := rect.grow(10.0)
	var platform_fill := (
		Color(0.025, 0.155, 0.285, 0.16)
		if side == "own"
		else Color(0.285, 0.035, 0.065, 0.15)
	)
	var border := accent
	border.a = 0.54 + depth * 0.10
	_draw_rounded_panel(
		Rect2(platform.position + Vector2(0, 4.0 + depth * 3.0), platform.size),
		Color(0, 0, 0, 0.22),
		Color.TRANSPARENT,
		0.0,
		8.0,
	)
	_draw_rounded_panel(platform, platform_fill, border, 1.5, 8.0)
	_draw_rounded_panel(
		rect.grow(3.0),
		Color(0.0, 0.010, 0.022, 0.25),
		Color(0.82, 0.91, 1.0, 0.10),
		1.0,
		5.0,
	)
	_draw_corner_brackets(platform.grow(-2.0), accent, 16.0, 2.0)
	var lane_y := platform.position.y + 2.0 if side == "own" else platform.end.y - 2.0
	var lane_color := accent
	lane_color.a = 0.78
	draw_line(
		Vector2(platform.position.x + 22.0, lane_y),
		Vector2(platform.end.x - 22.0, lane_y),
		lane_color,
		2.5,
	)


func _draw_slot_rect(slot: Rect2, color: Color) -> void:
	_draw_rounded_panel(slot, color, Color(1, 1, 1, 0.10), 1.0, 5.0)


func _draw_rounded_panel(
	rect: Rect2,
	fill: Color,
	border: Color,
	border_width: float,
	radius: float,
) -> void:
	var points := _rounded_rect_points(rect, radius)
	draw_colored_polygon(points, fill)
	if border_width > 0.0 and border.a > 0.0:
		draw_polyline(_closed_points(points), border, border_width, true)


func _draw_corner_brackets(
	rect: Rect2,
	color: Color,
	length: float,
	width: float,
) -> void:
	var bracket := minf(length, minf(rect.size.x, rect.size.y) * 0.24)
	var top_left := rect.position
	var top_right := Vector2(rect.end.x, rect.position.y)
	var bottom_right := rect.end
	var bottom_left := Vector2(rect.position.x, rect.end.y)
	draw_line(top_left, top_left + Vector2(bracket, 0), color, width)
	draw_line(top_left, top_left + Vector2(0, bracket), color, width)
	draw_line(top_right, top_right + Vector2(-bracket, 0), color, width)
	draw_line(top_right, top_right + Vector2(0, bracket), color, width)
	draw_line(bottom_right, bottom_right + Vector2(-bracket, 0), color, width)
	draw_line(bottom_right, bottom_right + Vector2(0, -bracket), color, width)
	draw_line(bottom_left, bottom_left + Vector2(bracket, 0), color, width)
	draw_line(bottom_left, bottom_left + Vector2(0, -bracket), color, width)


func _rounded_rect_points(rect: Rect2, radius: float) -> PackedVector2Array:
	var r := clampf(radius, 0.0, minf(rect.size.x, rect.size.y) * 0.5)
	if r <= 0.0:
		return PackedVector2Array([
			rect.position,
			Vector2(rect.end.x, rect.position.y),
			rect.end,
			Vector2(rect.position.x, rect.end.y),
		])
	var centers := [
		rect.position + Vector2(r, r),
		Vector2(rect.end.x - r, rect.position.y + r),
		rect.end - Vector2(r, r),
		Vector2(rect.position.x + r, rect.end.y - r),
	]
	var starts := [PI, PI * 1.5, 0.0, PI * 0.5]
	var points := PackedVector2Array()
	const CORNER_SEGMENTS := 4
	for corner_index in range(4):
		for segment_index in range(CORNER_SEGMENTS + 1):
			var angle := float(starts[corner_index]) + (
				PI * 0.5 * float(segment_index) / float(CORNER_SEGMENTS)
			)
			points.append(
				Vector2(centers[corner_index]) + Vector2(cos(angle), sin(angle)) * r
			)
	return points


func _closed_points(points: PackedVector2Array) -> PackedVector2Array:
	var closed := points.duplicate()
	if not closed.is_empty():
		closed.append(closed[0])
	return closed


func _scale_points(
	points: PackedVector2Array,
	center: Vector2,
	scale_factor: float,
) -> PackedVector2Array:
	var scaled := PackedVector2Array()
	for point in points:
		scaled.append(center + (point - center) * scale_factor)
	return scaled


func _table_half_points(points: PackedVector2Array, top_half: bool) -> PackedVector2Array:
	var middle := size.y * 0.5
	var bounds := _table_bounds_at_y(points, middle)
	var left_middle := Vector2(bounds.x, middle)
	var right_middle := Vector2(bounds.y, middle)
	if top_half:
		return PackedVector2Array([
			points[0], points[1], points[2], right_middle, left_middle, points[7],
		])
	return PackedVector2Array([
		left_middle, right_middle, points[3], points[4], points[5], points[6],
	])


func _table_bounds_at_y(points: PackedVector2Array, y: float) -> Vector2:
	var left := INF
	var right := -INF
	for index in range(points.size()):
		var start := points[index]
		var finish := points[(index + 1) % points.size()]
		if is_equal_approx(start.y, finish.y):
			if is_equal_approx(y, start.y):
				left = minf(left, minf(start.x, finish.x))
				right = maxf(right, maxf(start.x, finish.x))
			continue
		if y < minf(start.y, finish.y) or y > maxf(start.y, finish.y):
			continue
		var t := (y - start.y) / (finish.y - start.y)
		var x := lerpf(start.x, finish.x, t)
		left = minf(left, x)
		right = maxf(right, x)
	if is_inf(left) or is_inf(right):
		return Vector2(points[7].x, points[2].x)
	return Vector2(left, right)


func _ellipse_points(center: Vector2, radius: Vector2, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(maxi(8, segments)):
		var angle := TAU * float(index) / float(maxi(8, segments))
		points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	return points


func _ellipse_arc_points(
	center: Vector2,
	radius: Vector2,
	start_angle: float,
	end_angle: float,
	segments: int,
) -> PackedVector2Array:
	var points := PackedVector2Array()
	var count := maxi(4, segments)
	for index in range(count + 1):
		var angle := lerpf(start_angle, end_angle, float(index) / float(count))
		points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	return points


func _hex_points(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(6):
		var angle := PI / 6.0 + TAU * float(index) / 6.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


func _point_inside_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var previous := polygon.size() - 1
	for current in range(polygon.size()):
		var a := polygon[current]
		var b := polygon[previous]
		if ((a.y > point.y) != (b.y > point.y)):
			var crossing_x := (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
			if point.x < crossing_x:
				inside = not inside
		previous = current
	return inside


func _draw_center_lines() -> void:
	var middle := size.y * 0.50
	draw_line(
		Vector2(size.x * 0.12, middle - 5.0),
		Vector2(size.x * 0.88, middle - 5.0),
		Color(1.0, 0.20, 0.31, 0.10),
		2.0,
	)
	draw_line(
		Vector2(size.x * 0.12, middle + 5.0),
		Vector2(size.x * 0.88, middle + 5.0),
		Color(0.20, 0.51, 1.0, 0.12),
		2.0,
	)
	draw_line(
		Vector2(size.x * 0.12, middle - 1.0),
		Vector2(size.x * 0.88, middle - 1.0),
		Color(0.84, 0.91, 0.98, 0.16),
		1.0,
	)
	var center_x := size.x * 0.5
	var diamond := PackedVector2Array([
		Vector2(center_x, middle - 9.0),
		Vector2(center_x + 18.0, middle),
		Vector2(center_x, middle + 9.0),
		Vector2(center_x - 18.0, middle),
	])
	draw_colored_polygon(diamond, Color(0.52, 0.72, 0.92, 0.10))
	draw_polyline(_closed_points(diamond), Color(0.82, 0.91, 1.0, 0.22), 1.0)

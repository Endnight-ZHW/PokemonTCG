class_name BattlePlaymat
extends Control

var quality_profile := "high"
var _time := 0.0
var _redraw_accumulator := 0.0


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


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color("#070b13"))
	var middle := size.y * 0.49
	var bands := 18 if quality_profile == "low" else 34
	for index in range(bands):
		var t := float(index) / float(bands)
		var y := size.y * t
		var top_side := y < middle
		var local_t := y / middle if top_side else (y - middle) / maxf(1.0, size.y - middle)
		var color := (
			Color("#3b0610").lerp(Color("#120913"), local_t)
			if top_side
			else Color("#031b54").lerp(Color("#06101f"), local_t)
		)
		draw_rect(
			Rect2(0, y, size.x, size.y / float(bands) + 1.0),
			color,
		)

	var rail_height := maxf(38.0, size.y * 0.065)
	draw_rect(Rect2(0, 0, size.x, rail_height), Color(0.64, 0.03, 0.08, 0.5))
	draw_rect(
		Rect2(0, size.y - rail_height, size.x, rail_height),
		Color(0.04, 0.20, 0.72, 0.52),
	)
	var accent := Color("#f4e94a")
	accent.a = 0.72
	draw_line(
		Vector2(48, rail_height + 8),
		Vector2(size.x - 48, rail_height + 8),
		accent,
		3.0,
	)
	draw_line(
		Vector2(48, size.y - rail_height - 8),
		Vector2(size.x - 48, size.y - rail_height - 8),
		accent,
		3.0,
	)

	var inset_x := maxf(42.0, size.x * 0.055)
	var inset_y := maxf(74.0, size.y * 0.11)
	var corner_cut := maxf(46.0, minf(size.x, size.y) * 0.075)
	var table_points := PackedVector2Array([
		Vector2(inset_x + corner_cut, inset_y),
		Vector2(size.x - inset_x - corner_cut, inset_y),
		Vector2(size.x - inset_x, inset_y + corner_cut),
		Vector2(size.x - inset_x, size.y - inset_y - corner_cut),
		Vector2(size.x - inset_x - corner_cut, size.y - inset_y),
		Vector2(inset_x + corner_cut, size.y - inset_y),
		Vector2(inset_x, size.y - inset_y - corner_cut),
		Vector2(inset_x, inset_y + corner_cut),
	])
	draw_colored_polygon(table_points, Color(0.10, 0.14, 0.20, 0.82))
	var table_outline := table_points.duplicate()
	table_outline.append(table_points[0])
	draw_polyline(table_outline, Color(0.52, 0.58, 0.66, 0.58), 4.0)
	draw_polyline(table_outline, Color(0.02, 0.03, 0.05, 0.74), 1.0)

	var grid_alpha := 0.05 if quality_profile == "high" else 0.028
	var grid_color := Color(0.72, 0.82, 0.92, grid_alpha)
	var grid_step := 58 if quality_profile == "high" else 82
	for x in range(int(inset_x), int(size.x - inset_x), grid_step):
		draw_line(Vector2(x, inset_y), Vector2(x, size.y - inset_y), grid_color, 1.0)
	for y in range(int(inset_y), int(size.y - inset_y), grid_step):
		draw_line(Vector2(inset_x, y), Vector2(size.x - inset_x, y), grid_color, 1.0)

	var pulse := 0.06
	if quality_profile != "low":
		pulse += sin(_time * 0.7) * 0.014
	draw_circle(
		Vector2(size.x * 0.5, middle),
		minf(size.x, size.y) * 0.31,
		Color(0.82, 0.88, 1.0, pulse),
	)
	draw_circle(
		Vector2(size.x * 0.5, middle),
		minf(size.x, size.y) * 0.18,
		Color(0.58, 0.72, 1.0, pulse * 0.7),
	)
	draw_line(
		Vector2(inset_x + 14, middle),
		Vector2(size.x - inset_x - 14, middle),
		Color(0.86, 0.91, 1.0, 0.32),
		2.0,
	)

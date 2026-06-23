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
	draw_rect(rect, Color("#09150f"))
	var bands := 24 if quality_profile == "low" else 40
	for index in range(bands):
		var t := float(index) / float(bands)
		var color := Color("#172b1d").lerp(Color("#0b1511"), t)
		draw_rect(
			Rect2(0, size.y * t, size.x, size.y / float(bands) + 1.0),
			color,
		)
	var grid_alpha := 0.055 if quality_profile == "high" else 0.035
	var grid_color := Color(0.48, 0.75, 0.58, grid_alpha)
	for x in range(0, int(size.x), 64):
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color, 1.0)
	for y in range(0, int(size.y), 64):
		draw_line(Vector2(0, y), Vector2(size.x, y), grid_color, 1.0)
	var middle := size.y * 0.48
	draw_rect(
		Rect2(0, 0, size.x, middle),
		Color(0.16, 0.28, 0.42, 0.08),
	)
	draw_rect(
		Rect2(0, middle, size.x, size.y - middle),
		Color(0.45, 0.30, 0.12, 0.07),
	)
	var pulse := 0.08
	if quality_profile != "low":
		pulse += sin(_time * 0.7) * 0.018
	draw_circle(
		Vector2(size.x * 0.5, size.y * 0.48),
		minf(size.x, size.y) * 0.34,
		Color(0.22, 0.62, 0.38, pulse),
	)
	draw_line(
		Vector2(20, middle),
		Vector2(size.x - 20, middle),
		Color(0.62, 0.85, 0.68, 0.2),
		2.0,
	)

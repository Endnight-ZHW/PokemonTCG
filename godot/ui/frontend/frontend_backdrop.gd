@tool
class_name FrontendBackdrop
extends Control

const VARIANT_TITLE := "title"
const VARIANT_NEUTRAL := "neutral"
const VARIANT_VICTORY := "victory"
@export_enum("title", "neutral", "victory") var variant := VARIANT_NEUTRAL:
	set(value):
		variant = value
		queue_redraw()

func configure(value: String) -> void:
	variant = value

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	resized.connect(queue_redraw)

func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), FrontendPalette.BACKGROUND)
	var cloth := FrontendPalette.PANEL.darkened(0.20)
	for band in range(32):
		var t := float(band) / 31.0
		var ink := cloth.lerp(FrontendPalette.BACKGROUND, t * 0.75)
		draw_rect(Rect2(0, size.y * t, size.x, size.y / 31.0 + 1.0), ink)
	for y in range(24, int(size.y) - 20, 6):
		draw_line(Vector2(18, y), Vector2(size.x - 18, y), Color(0.7, 0.8, 0.77, 0.013))
	var wood := FrontendPalette.WOOD.darkened(0.32)
	for y in [0.0, size.y - 14.0]:
		draw_rect(Rect2(0, y, size.x, 14), wood)
		for grain in range(4):
			var points := PackedVector2Array()
			for x in range(0, int(size.x) + 20, 20):
				points.append(Vector2(x, y + 2.0 + grain * 3.0 + sin(x * 0.015 + grain) * 0.8))
			draw_polyline(points, Color(0.8, 0.65, 0.43, 0.07), 1.0)
	draw_rect(Rect2(Vector2(16, 18), size - Vector2(32, 36)), Color(FrontendPalette.GOLD, 0.12), false, 1.0)
	if variant == VARIANT_VICTORY:
		for radius in [90.0, 104.0]:
			draw_arc(Vector2(size.x * 0.5, size.y * 0.3), radius, PI * 0.12, PI * 0.88, 48, Color(FrontendPalette.GOLD, 0.10), 1.0, true)

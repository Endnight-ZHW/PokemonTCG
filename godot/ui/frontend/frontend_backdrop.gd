@tool
class_name FrontendBackdrop
extends Control

var accent_tint := Color("91a89f")

func set_accent(color: Color) -> void:
	accent_tint = color
	queue_redraw()

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
	if variant == "title":
		var right_tint := Color("e7edeb").lerp(accent_tint, 0.055)
		for band in range(80):
			var t := float(band) / 79.0
			var blend := smoothstep(0.20, 0.80, t)
			draw_rect(Rect2(size.x * t, 0, size.x / 79.0 + 1, size.y), FrontendPalette.BACKGROUND.lerp(right_tint, blend))
		var center := Vector2(size.x * 0.79, size.y * 0.38)
		var radius := size.y * 0.37
		for ring in range(30, 0, -1):
			draw_circle(center, radius * float(ring) / 20.0, Color(Color.WHITE, 0.018), true, -1, true)
		for r in [radius, radius * 1.22]:
			draw_arc(center, r, PI * 1.12, TAU * 1.03, 96, Color(accent_tint.darkened(0.25), 0.13), 1.0, true)
		var horizon := size.y * 0.70
		draw_line(Vector2(size.x * 0.48, horizon), Vector2(size.x, horizon), Color(FrontendPalette.TEXT, 0.065), 1, true)
		for offset in range(4):
			var y := horizon + pow(float(offset + 1) / 4, 1.6) * (size.y - horizon)
			draw_line(Vector2(size.x * 0.48, y), Vector2(size.x, y), Color(FrontendPalette.TEXT, 0.025), 1, true)
		for x in range(8):
			for y in range(4):
				draw_circle(Vector2(size.x - 42 - x * 16, 38 + y * 16), 1.2, Color(FrontendPalette.TEXT, 0.10), true, -1, true)

	else:
		draw_line(Vector2.ZERO, Vector2(size.x, 0), FrontendPalette.TEXT, 6)
		draw_line(Vector2.ZERO, Vector2(size.x * 0.10, 0), FrontendPalette.GOLD, 6)
		if variant == VARIANT_VICTORY:
			draw_arc(Vector2(size.x * 0.82, size.y * 0.4), size.y * 0.42,
				0, TAU, 96, Color("e8e6df"), 34, true)

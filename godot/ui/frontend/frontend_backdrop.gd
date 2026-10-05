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
		draw_rect(Rect2(Vector2.ZERO, size), HomePalette.BACKGROUND)
		var center := Vector2(size.x * 0.78, size.y * 0.48)
		var radius := size.y * 0.42
		var tint := HomePalette.BACKGROUND.lerp(accent_tint, 0.085)
		for ring in range(60, 0, -1):
			var fraction := float(ring) / 60.0
			draw_circle(center, radius * 1.48 * fraction, Color(tint, 0.04), true, -1, true)
		var line_color := Color(accent_tint.darkened(0.25), 0.07)
		draw_arc(center, radius, PI * 1.08, TAU * 1.12, 128, line_color, 2.0, true)
		draw_arc(center, radius * 0.77, -PI * 0.32, PI * 0.55, 96, Color(Color.WHITE, 0.75), 16, true)
		var ball_center := Vector2(size.x * 0.98, size.y * 0.10)
		var ball_radius := size.y * 0.17
		var ball_ink := Color(HomePalette.TEXT, 0.035)
		draw_circle(ball_center, ball_radius, ball_ink, false, 12, true)
		draw_line(ball_center - Vector2(ball_radius, 0), ball_center + Vector2(ball_radius, 0), ball_ink, 12, true)
		draw_circle(ball_center, ball_radius * 0.25, HomePalette.BACKGROUND, true, -1, true)
		draw_circle(ball_center, ball_radius * 0.25, ball_ink, false, 8, true)

	else:
		var center := Vector2(size.x * 0.75, size.y * 0.48)
		var tint := accent_tint if variant == VARIANT_VICTORY else Color("c5d6e6")
		for ring in range(40, 0, -1):
			draw_circle(center, size.y * 0.75 * float(ring) / 40.0, Color(tint, 0.009), true, -1, true)

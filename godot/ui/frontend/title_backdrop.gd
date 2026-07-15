@tool
class_name TitleBackdrop
extends Control

## Asset-light midnight arena used behind the title page. Static artwork is
## redrawn only when the viewport or accessibility profile changes.

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")

const NIGHT_TOP := Color("#07101d")
const NIGHT_MID := Color("#0d1b30")
const NIGHT_BOTTOM := Color("#030812")
const CYAN_LIGHT := Color("#62d7ff")
const GOLD_LIGHT := Color("#f4c84a")
const ENERGY_TICK_COLORS := [
	Color("#62d879"), # Grass
	Color("#ff6b55"), # Fire
	Color("#55baff"), # Water
	Color("#f7d84a"), # Lightning
	Color("#c482ff"), # Psychic
	Color("#d68b58"), # Fighting
	Color("#78839f"), # Darkness
	Color("#c8d4df"), # Metal
]

var _quality := "high"
var _decorations_reduced := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)
	_connect_settings()
	_refresh_runtime_settings()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_draw_night_gradient()
	_draw_spotlights()
	_draw_stars()
	_draw_emblem()
	_draw_energy_ticks()
	_draw_arena()
	_draw_vignette()


func _draw_night_gradient() -> void:
	var bands := 24 if _quality == "low" else 48
	for index in range(bands):
		var t := float(index) / float(maxi(1, bands - 1))
		var color: Color
		if t < 0.52:
			color = NIGHT_TOP.lerp(NIGHT_MID, smoothstep(0.0, 0.52, t))
		else:
			color = NIGHT_MID.lerp(NIGHT_BOTTOM, smoothstep(0.52, 1.0, t))
		var y := size.y * t
		draw_rect(
			Rect2(0, y, size.x, size.y / float(bands) + 2.0),
			color,
		)
	var horizon_y := size.y * 0.62
	draw_rect(
		Rect2(0, horizon_y, size.x, maxf(1.0, size.y * 0.004)),
		Color(CYAN_LIGHT, 0.08 if _decorations_reduced else 0.13),
	)


func _draw_spotlights() -> void:
	var layer_count := 2 if _decorations_reduced else 5
	_draw_spotlight(
		Vector2(size.x * 0.08, -size.y * 0.04),
		Vector2(size.x * 0.39, size.y * 0.72),
		size.x * 0.18,
		CYAN_LIGHT,
		layer_count,
	)
	_draw_spotlight(
		Vector2(size.x * 0.93, -size.y * 0.02),
		Vector2(size.x * 0.69, size.y * 0.69),
		size.x * 0.12,
		GOLD_LIGHT,
		layer_count,
	)
	_draw_soft_glow(
		Vector2(size.x * 0.50, size.y * 0.27),
		minf(size.x, size.y) * 0.35,
		Color(CYAN_LIGHT, 0.07 if _decorations_reduced else 0.12),
		3 if _decorations_reduced else 6,
	)


func _draw_spotlight(
	origin: Vector2,
	target: Vector2,
	base_half_width: float,
	color: Color,
	layers: int,
) -> void:
	var direction := target - origin
	var perpendicular := direction.normalized().orthogonal()
	for index in range(layers):
		var t := float(index) / float(maxi(1, layers - 1))
		var width := base_half_width * lerpf(1.15, 0.38, t)
		var beam := PackedVector2Array([
			origin - perpendicular * width * 0.035,
			origin + perpendicular * width * 0.035,
			target + perpendicular * width,
			target - perpendicular * width,
		])
		draw_colored_polygon(beam, Color(color, lerpf(0.010, 0.025, t)))


func _draw_soft_glow(
	center: Vector2,
	radius: float,
	color: Color,
	layers: int,
) -> void:
	for index in range(layers):
		var t := float(index) / float(maxi(1, layers - 1))
		draw_circle(
			center,
			radius * lerpf(1.0, 0.24, t),
			Color(color, color.a * lerpf(0.11, 0.28, t)),
		)


func _draw_stars() -> void:
	var points := [
		Vector2(0.05, 0.10), Vector2(0.13, 0.31), Vector2(0.21, 0.08),
		Vector2(0.29, 0.24), Vector2(0.36, 0.11), Vector2(0.44, 0.35),
		Vector2(0.55, 0.08), Vector2(0.63, 0.30), Vector2(0.71, 0.13),
		Vector2(0.79, 0.27), Vector2(0.87, 0.07), Vector2(0.95, 0.34),
		Vector2(0.09, 0.49), Vector2(0.27, 0.43), Vector2(0.74, 0.45),
		Vector2(0.91, 0.50), Vector2(0.17, 0.61), Vector2(0.84, 0.59),
	]
	var count := 7 if _decorations_reduced else 12 if _quality == "medium" else points.size()
	for index in range(count):
		var point: Vector2 = points[index] * size
		var radius := 0.8 + float(index % 3) * 0.45
		var color := Color(0.72, 0.88, 1.0, 0.24 + float(index % 2) * 0.16)
		draw_circle(point, radius, color)
		if not _decorations_reduced and index % 5 == 0:
			draw_line(point - Vector2(3.0, 0), point + Vector2(3.0, 0), color, 1.0, true)
			draw_line(point - Vector2(0, 3.0), point + Vector2(0, 3.0), color, 1.0, true)


func _draw_emblem() -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.28)
	var base_radius := minf(size.x, size.y) * 0.17
	var ink := Color(CYAN_LIGHT, 0.085 if _decorations_reduced else 0.14)
	for scale_value in [1.0, 1.28, 1.58]:
		draw_arc(center, base_radius * scale_value, 0.0, TAU, 112, ink, 2.0, true)
	draw_line(
		center - Vector2(base_radius, 0),
		center + Vector2(base_radius, 0),
		ink,
		2.0,
		true,
	)
	draw_circle(center, base_radius * 0.235, Color(0.03, 0.08, 0.14, 0.68))
	draw_circle(center, base_radius * 0.125, Color(CYAN_LIGHT, ink.a * 0.48))
	draw_arc(center, base_radius * 0.235, 0, TAU, 64, ink, 2.0, true)


func _draw_energy_ticks() -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.28)
	var base_radius := minf(size.x, size.y) * 0.17
	var tick_radius := base_radius * 1.58
	var tick_length := maxf(7.0, base_radius * 0.09)
	var tick_width := 2.5 if _decorations_reduced else 4.0
	for index in range(ENERGY_TICK_COLORS.size()):
		var angle := -PI * 0.5 + TAU * float(index) / float(ENERGY_TICK_COLORS.size())
		var radial := Vector2(cos(angle), sin(angle))
		var color: Color = ENERGY_TICK_COLORS[index]
		color.a = 0.18 if _decorations_reduced else 0.34
		draw_line(
			center + radial * (tick_radius - tick_length),
			center + radial * (tick_radius + tick_length),
			color,
			tick_width,
			true,
		)
		if not _decorations_reduced:
			draw_circle(center + radial * tick_radius, tick_width * 0.72, Color(color, 0.58))


func _draw_arena() -> void:
	var floor_top := size.y * 0.62
	draw_rect(
		Rect2(0, floor_top, size.x, size.y - floor_top),
		Color(0.01, 0.025, 0.055, 0.38),
	)
	var center := Vector2(size.x * 0.5, size.y * 0.88)
	var base_radius := minf(size.x, size.y) * 0.10
	var ink := Color(CYAN_LIGHT, 0.10 if _decorations_reduced else 0.18)
	draw_set_transform(center, 0.0, Vector2(2.8, 0.52))
	for radius_scale in [0.72, 1.18, 1.78, 2.52]:
		draw_arc(Vector2.ZERO, base_radius * radius_scale, 0.0, TAU, 112, ink, 2.0, true)
	draw_arc(
		Vector2.ZERO,
		base_radius * 0.72,
		0.0,
		TAU,
		96,
		Color(GOLD_LIGHT, 0.12 if _decorations_reduced else 0.20),
		2.4,
		true,
	)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var perspective_color := Color(CYAN_LIGHT, 0.065 if _decorations_reduced else 0.11)
	for x_ratio in [0.08, 0.28, 0.72, 0.92]:
		draw_line(
			Vector2(size.x * 0.5, floor_top),
			Vector2(size.x * x_ratio, size.y),
			perspective_color,
			1.2,
			true,
		)


func _draw_vignette() -> void:
	var layers := 4 if _decorations_reduced else 7
	var max_width := minf(size.x, size.y) * 0.08
	for index in range(layers):
		var t := float(index + 1) / float(layers)
		var width := max_width * t
		var shade := Color(0.0, 0.008, 0.025, lerpf(0.022, 0.055, t))
		draw_rect(Rect2(0, 0, width, size.y), shade)
		draw_rect(Rect2(size.x - width, 0, width, size.y), shade)
		draw_rect(Rect2(0, 0, size.x, width * 0.55), shade)


func _connect_settings() -> void:
	if Engine.is_editor_hint():
		return
	var settings := get_node_or_null("/root/AppSettings")
	if settings == null or not settings.has_signal("changed"):
		return
	var callback := Callable(self, "_refresh_runtime_settings")
	if not settings.is_connected("changed", callback):
		settings.connect("changed", callback)


func _refresh_runtime_settings() -> void:
	_quality = "high"
	_decorations_reduced = false
	if not Engine.is_editor_hint():
		var settings := get_node_or_null("/root/AppSettings")
		if settings != null and settings.has_method("resolved_quality_profile"):
			_quality = str(settings.call("resolved_quality_profile"))
		_decorations_reduced = FRONTEND_MOTION.is_reduced() or _quality == "low"
	queue_redraw()


func _on_resized() -> void:
	queue_redraw()

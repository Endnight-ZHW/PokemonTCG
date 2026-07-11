@tool
class_name TitleBackdrop
extends Control

## Bright, asset-light title backdrop. Static artwork is redrawn only when the
## viewport or quality profile changes; animation moves the card-back nodes.

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")

@onready var card_layer: Control = %CardBackLayer
@onready var card_backs: Array[TextureRect] = [
	%CardBackOne,
	%CardBackTwo,
	%CardBackThree,
	%CardBackFour,
]

var _quality := "high"
var _motion_enabled := false
var _elapsed := 0.0
var _parallax := Vector2.ZERO
var _base_positions: Array[Vector2] = []
var _base_rotations: Array[float] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)
	_connect_settings()
	_refresh_runtime_settings()
	call_deferred("_layout_card_backs")


func _process(delta: float) -> void:
	_elapsed += delta
	var target := Vector2.ZERO
	if not Engine.is_editor_hint() and is_inside_tree():
		var pointer := get_viewport().get_mouse_position()
		target = Vector2(
			clampf(pointer.x / maxf(size.x, 1.0) - 0.5, -0.5, 0.5),
			clampf(pointer.y / maxf(size.y, 1.0) - 0.5, -0.5, 0.5),
		) * 13.0
	_parallax = _parallax.lerp(target, minf(1.0, delta * 3.2))
	_apply_card_motion()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready():
		_refresh_processing()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_draw_sky_gradient()
	_draw_light_rays()
	_draw_cloud_bank(Vector2(size.x * 0.13, size.y * 0.24), size.x * 0.17, 0.24)
	_draw_cloud_bank(Vector2(size.x * 0.84, size.y * 0.18), size.x * 0.21, 0.21)
	_draw_cloud_bank(Vector2(size.x * 0.50, size.y * 0.54), size.x * 0.32, 0.11)
	_draw_emblem()
	_draw_arena()
	_draw_sparkles()


func _draw_sky_gradient() -> void:
	var top := Color("#9cc5f4")
	var upper_mid := Color("#eaf6ff")
	var lower_mid := Color("#a8cdef")
	var bottom := Color("#214b86")
	var bands := 18 if _quality == "low" else 32
	for index in range(bands):
		var t := float(index) / float(maxi(1, bands - 1))
		var color := (
			top.lerp(upper_mid, t / 0.46)
			if t < 0.46
			else upper_mid.lerp(lower_mid, (t - 0.46) / 0.30)
			if t < 0.76
			else lower_mid.lerp(bottom, (t - 0.76) / 0.24)
		)
		var y := size.y * t
		draw_rect(
			Rect2(0, y, size.x, size.y / float(bands) + 2.0),
			color,
		)
	var horizon := Color(0.95, 0.985, 1.0, 0.34)
	draw_rect(Rect2(0, size.y * 0.54, size.x, size.y * 0.20), horizon)


func _draw_light_rays() -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.20)
	var ray_color := Color(0.91, 0.98, 1.0, 0.18 if _quality != "low" else 0.09)
	var ray_count := 14 if _quality != "low" else 7
	for index in range(ray_count):
		var angle := lerpf(-2.88, -0.26, float(index) / float(maxi(1, ray_count - 1)))
		var endpoint := center + Vector2(cos(angle), sin(angle)) * maxf(size.x, size.y) * 1.15
		draw_line(center, endpoint, ray_color, 2.0, true)


func _draw_cloud_bank(center: Vector2, radius: float, alpha: float) -> void:
	var lobes := 5 if _quality == "low" else 8
	for index in range(lobes):
		var x := (float(index) / float(maxi(1, lobes - 1)) - 0.5) * radius * 1.55
		var y := sin(float(index) * 1.7) * radius * 0.09
		var local_radius := radius * (0.32 + float((index * 7) % 3) * 0.055)
		_draw_soft_cloud_disc(center + Vector2(x, y), local_radius, alpha)
	_draw_soft_cloud_disc(center + Vector2(0, radius * 0.10), radius * 0.52, alpha)


func _draw_soft_cloud_disc(center: Vector2, radius: float, alpha: float) -> void:
	var layers := 3 if _quality == "low" else 5
	for index in range(layers):
		var t := float(index) / float(maxi(1, layers - 1))
		var color := Color(0.97, 0.99, 1.0, alpha * lerpf(0.12, 0.30, t))
		draw_circle(center, radius * lerpf(1.22, 0.66, t), color)


func _draw_emblem() -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.22)
	var base_radius := minf(size.x, size.y) * 0.15
	var ink := Color(0.38, 0.78, 1.0, 0.20 if _quality != "low" else 0.11)
	for scale_value in [0.72, 1.0, 1.30, 1.58]:
		draw_arc(center, base_radius * scale_value, 0.0, TAU, 96, ink, 2.0, true)
	draw_line(
		center - Vector2(base_radius * 1.58, 0),
		center + Vector2(base_radius * 1.58, 0),
		ink,
		2.0,
		true,
	)
	draw_circle(center, base_radius * 0.24, Color(0.88, 0.97, 1.0, ink.a * 0.72))
	draw_arc(center, base_radius * 0.24, 0, TAU, 64, ink, 2.0, true)


func _draw_arena() -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.91)
	var ink := Color(0.55, 0.84, 1.0, 0.22)
	draw_set_transform(center, 0.0, Vector2(2.55, 0.48))
	for radius in [72.0, 112.0, 164.0, 226.0]:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 96, ink, 2.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var floor_color := Color(0.08, 0.25, 0.52, 0.18)
	draw_rect(Rect2(0, size.y * 0.82, size.x, size.y * 0.18), floor_color)


func _draw_sparkles() -> void:
	var points := [
		Vector2(0.08, 0.12), Vector2(0.19, 0.34), Vector2(0.31, 0.09),
		Vector2(0.68, 0.12), Vector2(0.82, 0.36), Vector2(0.93, 0.10),
		Vector2(0.12, 0.68), Vector2(0.89, 0.64), Vector2(0.73, 0.72),
	]
	var count := 5 if _quality == "low" else points.size()
	for index in range(count):
		var point: Vector2 = points[index] * size
		var radius := 2.0 + float(index % 3)
		var color := Color(1.0, 0.98, 0.78, 0.64 if index % 2 == 0 else 0.42)
		draw_line(point - Vector2(radius * 2.0, 0), point + Vector2(radius * 2.0, 0), color, 1.5, true)
		draw_line(point - Vector2(0, radius * 2.0), point + Vector2(0, radius * 2.0), color, 1.5, true)


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
	_motion_enabled = not Engine.is_editor_hint()
	if not Engine.is_editor_hint():
		var settings := get_node_or_null("/root/AppSettings")
		if settings != null and settings.has_method("resolved_quality_profile"):
			_quality = str(settings.call("resolved_quality_profile"))
		_motion_enabled = FRONTEND_MOTION.decorative_motion_enabled()
	if _quality == "low":
		_motion_enabled = false
	_elapsed = 0.0
	_parallax = Vector2.ZERO
	_layout_card_backs()
	_refresh_processing()
	queue_redraw()


func _refresh_processing() -> void:
	set_process(_motion_enabled and is_visible_in_tree())
	if not is_processing():
		_apply_card_motion()


func _on_resized() -> void:
	_layout_card_backs()
	queue_redraw()


func _layout_card_backs() -> void:
	if not is_node_ready() or size.x <= 0.0 or size.y <= 0.0:
		return
	var compact := size.x < 1180.0 or size.x / maxf(size.y, 1.0) < 1.5
	var visible_count := 2 if _quality == "low" or compact else 3 if _quality == "medium" else 4
	var card_size := Vector2(138, 193) if compact else Vector2(172, 240)
	var placements := [
		[Vector2(-card_size.x * 0.30, size.y * 0.18), -0.38],
		[Vector2(size.x - card_size.x * 0.58, size.y * 0.13), 0.31],
		[Vector2(size.x - card_size.x * 0.38, size.y * 0.62), 0.20],
		[Vector2(size.x * 0.07, size.y * 0.72), -0.24],
	]
	_base_positions.clear()
	_base_rotations.clear()
	for index in range(card_backs.size()):
		var card := card_backs[index]
		card.visible = index < visible_count
		card.size = card_size
		card.pivot_offset = card_size * 0.5
		var position_value: Vector2 = placements[index][0]
		var rotation_value: float = placements[index][1]
		_base_positions.append(position_value)
		_base_rotations.append(rotation_value)
	_apply_card_motion()


func _apply_card_motion() -> void:
	if not is_node_ready() or _base_positions.size() != card_backs.size():
		return
	for index in range(card_backs.size()):
		var float_offset := 0.0
		var rotation_offset := 0.0
		if _motion_enabled:
			float_offset = sin(_elapsed * 0.58 + index * 1.4) * 4.5
			rotation_offset = sin(_elapsed * 0.34 + index) * 0.009
		card_backs[index].position = (
			_base_positions[index]
			+ _parallax * (0.18 + float(index) * 0.06)
			+ Vector2(0, float_offset)
		)
		card_backs[index].rotation = _base_rotations[index] + rotation_offset

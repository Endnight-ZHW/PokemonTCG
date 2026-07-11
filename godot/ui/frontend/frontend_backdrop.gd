@tool
class_name FrontendBackdrop
extends Control

## Lightweight shared background for non-battle pages.
## `variant` accepts "title", "neutral", or "victory".

const VARIANT_TITLE := "title"
const VARIANT_NEUTRAL := "neutral"
const VARIANT_VICTORY := "victory"
const _VALID_VARIANTS := [VARIANT_TITLE, VARIANT_NEUTRAL, VARIANT_VICTORY]

@export_enum("title", "neutral", "victory") var variant: String = VARIANT_NEUTRAL:
	set(value):
		variant = value if value in _VALID_VARIANTS else VARIANT_NEUTRAL
		if is_node_ready():
			_apply_variant()

@onready var card_fan: Control = %CardFan
@onready var cards: Array[TextureRect] = [
	%FeaturedCardOne,
	%FeaturedCardTwo,
	%FeaturedCardThree,
]

var _elapsed := 0.0
var _motion_enabled := false
var _quality := "high"
var _parallax := Vector2.ZERO
var _card_base_positions: Array[Vector2] = []
var _card_base_rotations: Array[float] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_layout_decorations)
	_connect_settings()
	_refresh_runtime_settings()
	_apply_variant()
	call_deferred("_layout_decorations")


func configure(value: String) -> void:
	variant = value


func _process(delta: float) -> void:
	_elapsed += delta
	_update_parallax(delta)
	_apply_card_motion()
	queue_redraw()


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
	if Engine.is_editor_hint():
		_quality = "high"
		_motion_enabled = true
	else:
		var settings := get_node_or_null("/root/AppSettings")
		_quality = "high"
		if settings != null and settings.has_method("resolved_quality_profile"):
			_quality = str(settings.call("resolved_quality_profile"))
		_motion_enabled = FrontendMotion.decorative_motion_enabled()
	set_process(_motion_enabled and is_visible_in_tree())
	if not _motion_enabled:
		_elapsed = 0.0
		_parallax = Vector2.ZERO
	_layout_decorations()
	queue_redraw()


func _apply_variant() -> void:
	if not is_node_ready():
		return
	match variant:
		VARIANT_TITLE:
			card_fan.modulate = Color(0.92, 0.97, 1.0, 0.43)
		VARIANT_VICTORY:
			card_fan.modulate = Color(1.0, 0.86, 0.48, 0.34)
		_:
			card_fan.modulate = Color(0.62, 0.8, 1.0, 0.14)
	_layout_decorations()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready():
		set_process(_motion_enabled and is_visible_in_tree())


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var colors := _background_colors()
	var band_count := 18 if _quality == "low" else 32
	for index in range(band_count):
		var t := float(index) / float(maxi(1, band_count - 1))
		var y := size.y * float(index) / float(band_count)
		draw_rect(
			Rect2(0.0, y, size.x, size.y / float(band_count) + 1.0),
			colors[0].lerp(colors[1], t),
		)
	_draw_glows()
	if _quality != "low":
		_draw_grid()
	match variant:
		VARIANT_TITLE:
			_draw_title_marks()
		VARIANT_VICTORY:
			_draw_victory_marks()
		_:
			_draw_neutral_marks()


func _background_colors() -> Array[Color]:
	match variant:
		VARIANT_TITLE:
			return [Color("#102846"), Color("#06101e")]
		VARIANT_VICTORY:
			return [Color("#282313"), Color("#07111f")]
		_:
			return [Color("#0d1c32"), Color("#07111f")]


func _draw_glows() -> void:
	var pulse := 1.0
	if _motion_enabled:
		pulse += sin(_elapsed * 0.58) * 0.08
	match variant:
		VARIANT_TITLE:
			_draw_soft_circle(
				Vector2(size.x * 0.19, size.y * 0.45) + _parallax * 0.4,
				minf(size.x, size.y) * 0.42 * pulse,
				Color(0.08, 0.53, 0.96, 0.13),
			)
			_draw_soft_circle(
				Vector2(size.x * 0.86, size.y * 0.08) - _parallax * 0.3,
				minf(size.x, size.y) * 0.27,
				Color(0.96, 0.62, 0.13, 0.075),
			)
		VARIANT_VICTORY:
			_draw_soft_circle(
				Vector2(size.x * 0.5, size.y * 0.32),
				minf(size.x, size.y) * 0.48 * pulse,
				Color(0.98, 0.68, 0.14, 0.14),
			)
			_draw_soft_circle(
				Vector2(size.x * 0.5, size.y * 0.64),
				minf(size.x, size.y) * 0.32,
				Color(0.15, 0.6, 0.95, 0.065),
			)
		_:
			_draw_soft_circle(
				Vector2(size.x * 0.82, size.y * 0.22) - _parallax * 0.2,
				minf(size.x, size.y) * 0.34,
				Color(0.09, 0.49, 0.87, 0.09),
			)


func _draw_soft_circle(center: Vector2, radius: float, color: Color) -> void:
	var steps := 5 if _quality == "low" else 10
	for index in range(steps):
		var t := float(index + 1) / float(steps)
		var layer_color := color
		layer_color.a *= 0.22 + t * 0.12
		draw_circle(center, radius * (1.0 - float(index) / float(steps) * 0.82), layer_color)


func _draw_grid() -> void:
	var spacing := 92.0
	var offset := Vector2(fmod(_parallax.x * 0.12, spacing), fmod(_parallax.y * 0.12, spacing))
	var grid_color := Color(0.32, 0.63, 0.9, 0.038 if variant != VARIANT_VICTORY else 0.024)
	var x := offset.x - spacing
	while x < size.x + spacing:
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color, 1.0)
		x += spacing
	var y := offset.y - spacing
	while y < size.y + spacing:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid_color, 1.0)
		y += spacing


func _draw_title_marks() -> void:
	var ink := Color(0.36, 0.78, 1.0, 0.11)
	var center := Vector2(size.x * 0.08, size.y * 0.88)
	for radius in [54.0, 76.0, 104.0]:
		draw_arc(center, radius, -1.2, 1.75, 36, ink, 1.5, true)


func _draw_neutral_marks() -> void:
	var ink := Color(0.42, 0.75, 0.98, 0.075)
	for index in range(7):
		var point := Vector2(size.x * (0.08 + index * 0.135), size.y * (0.9 - float(index % 2) * 0.025))
		draw_circle(point, 2.0, ink)


func _draw_victory_marks() -> void:
	var gold := Color(1.0, 0.79, 0.28, 0.16)
	var center := Vector2(size.x * 0.5, size.y * 0.29)
	for radius in [86.0, 126.0, 172.0]:
		draw_arc(center, radius, PI * 0.08, PI * 0.92, 54, gold, 1.5, true)
	if not _motion_enabled:
		return
	var confetti := [
		Vector2(0.12, 0.15), Vector2(0.22, 0.28), Vector2(0.33, 0.12),
		Vector2(0.68, 0.14), Vector2(0.77, 0.29), Vector2(0.89, 0.17),
		Vector2(0.15, 0.58), Vector2(0.84, 0.61), Vector2(0.29, 0.72),
		Vector2(0.72, 0.75),
	]
	for index in range(confetti.size()):
		var point: Vector2 = confetti[index] * size
		point.y += sin(_elapsed * 0.8 + index * 1.7) * 8.0
		var color := gold if index % 2 == 0 else Color(0.32, 0.78, 1.0, 0.13)
		draw_line(point - Vector2(3, 5), point + Vector2(3, 5), color, 2.0, true)


func _layout_decorations() -> void:
	if not is_node_ready() or size.x <= 0.0 or size.y <= 0.0:
		return
	var compact := size.x < 1100.0 or size.x / maxf(size.y, 1.0) < 1.35
	var show_cards := variant != VARIANT_NEUTRAL or not compact
	card_fan.visible = show_cards
	if not show_cards:
		return
	var card_size := Vector2(150, 210) if compact else Vector2(190, 266)
	if variant == VARIANT_VICTORY:
		card_size *= 0.86
	var origin := Vector2(size.x * (0.04 if variant == VARIANT_TITLE else 0.78), size.y * 0.54)
	if compact:
		origin = Vector2(size.x * 0.72, size.y * 0.64)
	var spread := card_size.x * 0.58
	_card_base_positions.clear()
	_card_base_rotations.clear()
	for index in range(cards.size()):
		var card := cards[index]
		card.size = card_size
		card.pivot_offset = card_size * 0.5
		var base_position := origin + Vector2(index * spread, absf(index - 1.0) * 26.0)
		var base_rotation := deg_to_rad(float(index - 1) * 8.0)
		_card_base_positions.append(base_position)
		_card_base_rotations.append(base_rotation)
		card.visible = index < (2 if compact or _quality == "low" else 3)
	_apply_card_motion()


func _update_parallax(delta: float) -> void:
	var target := Vector2.ZERO
	if is_inside_tree():
		var mouse := get_viewport().get_mouse_position()
		target = Vector2(
			clampf(mouse.x / maxf(size.x, 1.0) - 0.5, -0.5, 0.5),
			clampf(mouse.y / maxf(size.y, 1.0) - 0.5, -0.5, 0.5),
		) * 18.0
	_parallax = _parallax.lerp(target, minf(1.0, delta * 3.5))


func _apply_card_motion() -> void:
	if not is_node_ready() or _card_base_positions.size() != cards.size():
		return
	for index in range(cards.size()):
		var float_offset := 0.0
		var rotation_offset := 0.0
		if _motion_enabled:
			float_offset = sin(_elapsed * 0.72 + index * 1.1) * 5.0
			rotation_offset = sin(_elapsed * 0.46 + index * 0.8) * 0.012
		cards[index].position = _card_base_positions[index] + _parallax * (0.28 + index * 0.12) + Vector2(0, float_offset)
		cards[index].rotation = _card_base_rotations[index] + rotation_offset

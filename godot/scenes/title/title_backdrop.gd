class_name TitleBackdrop
extends Control

var featured_ids: Array[String] = [
	"svl-pikaex",
	"svg-alt",
	"svi-maus",
	"svg2-tort",
]
var featured: Array[TextureRect] = []
var card_backs: Array[TextureRect] = []
var elapsed := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_cards()
	resized.connect(_layout_cards)
	if not AppSettings.changed.is_connected(_apply_runtime_settings):
		AppSettings.changed.connect(_apply_runtime_settings)
	_apply_runtime_settings()
	call_deferred("_layout_cards")


func _process(delta: float) -> void:
	elapsed += delta
	for index in range(featured.size()):
		var card := featured[index]
		card.rotation = sin(elapsed * 0.42 + index * 0.8) * 0.035
		card.position.y += sin(elapsed * 0.8 + index) * 0.025
	for index in range(card_backs.size()):
		var back := card_backs[index]
		back.rotation += delta * (0.018 if index % 2 == 0 else -0.014)
	queue_redraw()


func _apply_runtime_settings() -> void:
	set_process(not AppSettings.reduced_motion)
	if AppSettings.reduced_motion:
		elapsed = 0.0
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), DesignTokens.BG_DEEP)
	var strips := 36
	for index in range(strips):
		var t := float(index) / float(strips)
		var color := Color("#102342").lerp(Color("#07101d"), t)
		draw_rect(
			Rect2(0, size.y * t, size.x, size.y / strips + 1),
			color,
		)
	var grid := Color(0.28, 0.57, 0.85, 0.045)
	for x in range(0, int(size.x), 78):
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid, 1)
	for y in range(0, int(size.y), 78):
		draw_line(Vector2(0, y), Vector2(size.x, y), grid, 1)
	var glow_alpha := 0.11 + sin(elapsed * 0.55) * 0.018
	draw_circle(
		Vector2(size.x * 0.28, size.y * 0.46),
		minf(size.x, size.y) * 0.34,
		Color(0.12, 0.55, 0.95, glow_alpha),
	)
	draw_circle(
		Vector2(size.x * 0.78, size.y * 0.15),
		minf(size.x, size.y) * 0.22,
		Color(0.93, 0.62, 0.18, 0.05),
	)


func _build_cards() -> void:
	for card_id in featured_ids:
		var card := TextureRect.new()
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		card.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		card.texture = CardTextureCache.get_texture(str(
			CardDatabase.get_card(card_id).get("image_path", "")
		))
		card.modulate = Color(1, 1, 1, 0.76)
		add_child(card)
		featured.append(card)
	for index in range(5):
		var back := TextureRect.new()
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		back.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		back.texture = CardTextureCache.get_texture("res://assets/cards/card_back.webp")
		back.modulate = Color(1, 1, 1, 0.10 + index * 0.012)
		add_child(back)
		card_backs.append(back)


func _layout_cards() -> void:
	if size.x <= 0:
		return
	var card_size := Vector2(188, 264)
	var positions := [
		Vector2(size.x * 0.08, size.y * 0.22),
		Vector2(size.x * 0.19, size.y * 0.15),
		Vector2(size.x * 0.31, size.y * 0.24),
		Vector2(size.x * 0.20, size.y * 0.43),
	]
	for index in range(featured.size()):
		featured[index].size = card_size
		featured[index].position = positions[index]
		featured[index].pivot_offset = card_size * 0.5
	var back_positions := [
		Vector2(size.x * 0.04, size.y * 0.06),
		Vector2(size.x * 0.39, size.y * 0.08),
		Vector2(size.x * 0.05, size.y * 0.66),
		Vector2(size.x * 0.42, size.y * 0.68),
		Vector2(size.x * 0.72, size.y * 0.76),
	]
	for index in range(card_backs.size()):
		card_backs[index].size = Vector2(78, 110)
		card_backs[index].position = back_positions[index]
		card_backs[index].pivot_offset = Vector2(39, 55)

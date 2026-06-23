class_name VictoryScreen
extends Control

signal rematch_requested
signal title_requested

var winner := 0
var turn_count := 0
var winner_name := ""
var winner_card_id := ""
var particles: Array[Dictionary] = []
var elapsed := 0.0

var winner_label: Label
var summary_label: Label
var card_image: TextureRect


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_build()
	_spawn_confetti()


func configure(
	p_winner: int,
	p_turn_count: int,
	p_winner_name: String,
	p_winner_card_id: String = "",
) -> void:
	winner = p_winner
	turn_count = p_turn_count
	winner_name = p_winner_name
	winner_card_id = p_winner_card_id
	if is_node_ready():
		_refresh()


func _process(delta: float) -> void:
	elapsed += delta
	for row in particles:
		row["position"] = Vector2(row["position"]) + Vector2(row["velocity"]) * delta
		row["velocity"] = Vector2(row["velocity"]) + Vector2(0, 36) * delta
		row["rotation"] = float(row["rotation"]) + float(row["spin"]) * delta
		if Vector2(row["position"]).y > size.y + 20:
			row["position"] = Vector2(randf_range(0, size.x), randf_range(-120, -20))
			row["velocity"] = Vector2(randf_range(-35, 35), randf_range(55, 110))
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#09111f"))
	var strips := 32
	for index in range(strips):
		var t := float(index) / float(strips)
		var color := Color("#9b6912").lerp(Color("#09111f"), t)
		draw_rect(Rect2(0, size.y * t, size.x, size.y / strips + 1), color)
	var glow := 0.10 + sin(elapsed * 1.2) * 0.025
	draw_circle(
		Vector2(size.x * 0.5, size.y * 0.35),
		minf(size.x, size.y) * 0.32,
		Color(1.0, 0.78, 0.18, glow),
	)
	for row in particles:
		var position_value: Vector2 = row["position"]
		var color: Color = row["color"]
		var particle_size := float(row["size"])
		draw_set_transform(position_value, float(row["rotation"]), Vector2.ONE)
		draw_rect(
			Rect2(-particle_size, -particle_size * 0.45, particle_size * 2, particle_size * 0.9),
			color,
		)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(820, 560)
	panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.04, 0.065, 0.10, 0.93),
			24,
			DesignTokens.GOLD,
			2,
			0,
		),
	)
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, 46)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 38)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)
	var eyebrow := Label.new()
	eyebrow.text = "MATCH COMPLETE"
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eyebrow.add_theme_font_size_override("font_size", 16)
	eyebrow.add_theme_color_override("font_color", DesignTokens.CYAN)
	content.add_child(eyebrow)
	winner_label = Label.new()
	winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_label.add_theme_font_size_override("font_size", 48)
	winner_label.add_theme_color_override("font_color", DesignTokens.GOLD)
	content.add_child(winner_label)
	var showcase := HBoxContainer.new()
	showcase.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_child(showcase)
	card_image = TextureRect.new()
	card_image.custom_minimum_size = Vector2(145, 204)
	card_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	showcase.add_child(card_image)
	summary_label = Label.new()
	summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary_label.add_theme_font_size_override("font_size", 20)
	summary_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	content.add_child(summary_label)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 18)
	content.add_child(buttons)
	var rematch := Button.new()
	rematch.text = "再次选择牌组"
	rematch.custom_minimum_size = Vector2(245, 58)
	rematch.pressed.connect(rematch_requested.emit)
	buttons.add_child(rematch)
	var title := Button.new()
	title.text = "返回标题"
	title.custom_minimum_size = Vector2(245, 58)
	title.pressed.connect(title_requested.emit)
	buttons.add_child(title)
	_refresh()


func _refresh() -> void:
	winner_label.text = "%s 获胜！" % (
		winner_name if not winner_name.is_empty() else "玩家 %d" % (winner + 1)
	)
	summary_label.text = "历经 %d 回合，胜利已经写入牌桌。" % turn_count
	card_image.texture = CardTextureCache.get_texture(str(
		CardDatabase.get_card(winner_card_id).get("image_path", "")
	)) if not winner_card_id.is_empty() else null
	card_image.visible = card_image.texture != null


func _spawn_confetti() -> void:
	var colors := [
		DesignTokens.GOLD,
		DesignTokens.CYAN,
		DesignTokens.RED,
		DesignTokens.GREEN,
		DesignTokens.PURPLE,
	]
	var count := 34 if AppSettings.resolved_quality_profile() == "low" else 70
	for _index in range(count):
		particles.append({
			"position": Vector2(randf_range(0, maxf(1, size.x)), randf_range(-size.y, 0)),
			"velocity": Vector2(randf_range(-35, 35), randf_range(55, 115)),
			"size": randf_range(2.5, 6.0),
			"color": colors.pick_random(),
			"rotation": randf_range(0, TAU),
			"spin": randf_range(-3.0, 3.0),
		})


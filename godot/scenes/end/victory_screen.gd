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

@onready var winner_label: Label = %WinnerLabel
@onready var summary_label: Label = %SummaryLabel
@onready var card_image: TextureRect = %CardImage
@onready var victory_panel: PanelContainer = %VictoryPanel
@onready var animation_player: AnimationPlayer = %AnimationPlayer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_resolve_nodes()
	_ensure_connections()
	if not AppSettings.changed.is_connected(_apply_runtime_settings):
		AppSettings.changed.connect(_apply_runtime_settings)
	victory_panel.resized.connect(_center_panel_pivot)
	_center_panel_pivot()
	_refresh()
	if not AppSettings.reduced_motion:
		animation_player.play("enter")
	_apply_runtime_settings()


func configure(
	p_winner: int,
	p_turn_count: int,
	p_winner_name: String,
	p_winner_card_id: String = "",
) -> void:
	_resolve_nodes()
	_ensure_connections()
	winner = p_winner
	turn_count = p_turn_count
	winner_name = p_winner_name
	winner_card_id = p_winner_card_id
	if is_node_ready():
		_refresh()


func _resolve_nodes() -> void:
	winner_label = get_node(
		"Center/VictoryPanel/Margin/Content/WinnerLabel"
	) as Label
	summary_label = get_node(
		"Center/VictoryPanel/Margin/Content/SummaryLabel"
	) as Label
	card_image = get_node(
		"Center/VictoryPanel/Margin/Content/Showcase/CardImage"
	) as TextureRect
	victory_panel = get_node("Center/VictoryPanel") as PanelContainer
	animation_player = get_node("AnimationPlayer") as AnimationPlayer


func _ensure_connections() -> void:
	var rematch_button := get_node(
		"Center/VictoryPanel/Margin/Content/Buttons/RematchButton"
	) as Button
	var title_button := get_node(
		"Center/VictoryPanel/Margin/Content/Buttons/TitleButton"
	) as Button
	if not rematch_button.pressed.is_connected(rematch_requested.emit):
		rematch_button.pressed.connect(rematch_requested.emit)
	if not title_button.pressed.is_connected(title_requested.emit):
		title_button.pressed.connect(title_requested.emit)


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


func _apply_runtime_settings() -> void:
	if AppSettings.reduced_motion:
		particles.clear()
		set_process(false)
		if animation_player:
			animation_player.stop()
	else:
		var desired_count := _confetti_count()
		if particles.size() != desired_count:
			particles.clear()
			_spawn_confetti()
		set_process(true)
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


func _refresh() -> void:
	winner_label.text = "%s 获胜！" % (
		winner_name if not winner_name.is_empty() else "玩家 %d" % (winner + 1)
	)
	summary_label.text = "历经 %d 回合，胜利已经写入牌桌。" % turn_count
	card_image.texture = CardTextureCache.get_texture(str(
		CardDatabase.get_card(winner_card_id).get("image_path", "")
	)) if not winner_card_id.is_empty() else null
	card_image.visible = card_image.texture != null


func _center_panel_pivot() -> void:
	victory_panel.pivot_offset = victory_panel.size * 0.5


func _spawn_confetti() -> void:
	var colors := [
		DesignTokens.GOLD,
		DesignTokens.CYAN,
		DesignTokens.RED,
		DesignTokens.GREEN,
		DesignTokens.PURPLE,
	]
	var count := _confetti_count()
	for _index in range(count):
		particles.append({
			"position": Vector2(randf_range(0, maxf(1, size.x)), randf_range(-size.y, 0)),
			"velocity": Vector2(randf_range(-35, 35), randf_range(55, 115)),
			"size": randf_range(2.5, 6.0),
			"color": colors.pick_random(),
			"rotation": randf_range(0, TAU),
			"spin": randf_range(-3.0, 3.0),
		})


func _confetti_count() -> int:
	return 34 if AppSettings.resolved_quality_profile() == "low" else 70

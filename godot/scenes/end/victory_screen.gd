class_name VictoryScreen
extends Control

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")

signal rematch_requested
signal title_requested

const WIDE_MIN_WIDTH := 1360.0
const WIDE_MIN_ASPECT := 1.5
const MAX_PANEL_WIDTH := 1120.0

var winner := 0
var turn_count := 0
var winner_name := ""
var winner_card_id := ""
var context: Dictionary = {}
var _entrance_started := false

@onready var safe_content: MarginContainer = %SafeContent
@onready var victory_panel: PanelContainer = %VictoryPanel
@onready var panel_margin: MarginContainer = %PanelMargin
@onready var content: VBoxContainer = %Content
@onready var winner_label: Label = %WinnerLabel
@onready var result_subtitle: Label = %ResultSubtitle
@onready var result_grid: GridContainer = %ResultGrid
@onready var card_stage: PanelContainer = %CardStage
@onready var card_frame: Control = %CardFrame
@onready var card_image: TextureRect = %CardImage
@onready var card_placeholder: CenterContainer = %CardPlaceholder
@onready var card_name_label: Label = %CardNameLabel
@onready var summary_label: Label = %SummaryLabel
@onready var mode_value: Label = %ModeValue
@onready var deck_value: Label = %DeckValue
@onready var turn_value: Label = %TurnValue
@onready var mode_row: HBoxContainer = %ModeRow
@onready var deck_row: HBoxContainer = %DeckRow
@onready var turn_row: HBoxContainer = %TurnRow
@onready var rematch_button: Button = %RematchButton
@onready var title_button: Button = %TitleButton
@onready var footer_hint: Label = %FooterHint
@onready var animation_player: AnimationPlayer = %AnimationPlayer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_connect_actions()
	if not resized.is_connected(_apply_responsive_layout):
		resized.connect(_apply_responsive_layout)
	if not victory_panel.resized.is_connected(_center_panel_pivot):
		victory_panel.resized.connect(_center_panel_pivot)
	if not AppSettings.changed.is_connected(_on_runtime_settings_changed):
		AppSettings.changed.connect(_on_runtime_settings_changed)
	_apply_responsive_layout()
	_refresh()
	call_deferred("_start_entrance")
	rematch_button.call_deferred("grab_focus")


func configure(
	p_winner: int,
	p_turn_count: int,
	p_winner_name: String,
	p_winner_card_id: String = "",
	p_context: Dictionary = {},
) -> void:
	winner = p_winner
	turn_count = p_turn_count
	winner_name = p_winner_name
	winner_card_id = p_winner_card_id
	context = p_context.duplicate(true)
	_connect_actions()
	if is_node_ready():
		_refresh()


func _connect_actions() -> void:
	var rematch := get_node_or_null(
		"SafeContent/Center/VictoryPanel/PanelMargin/Content/Buttons/RematchButton"
	) as Button
	var back_to_title := get_node_or_null(
		"SafeContent/Center/VictoryPanel/PanelMargin/Content/Buttons/TitleButton"
	) as Button
	if rematch == null or back_to_title == null:
		return
	if not rematch.pressed.is_connected(rematch_requested.emit):
		rematch.pressed.connect(rematch_requested.emit)
	if not back_to_title.pressed.is_connected(title_requested.emit):
		back_to_title.pressed.connect(title_requested.emit)
	rematch.focus_neighbor_right = rematch.get_path_to(back_to_title)
	rematch.focus_next = rematch.get_path_to(back_to_title)
	back_to_title.focus_neighbor_left = back_to_title.get_path_to(rematch)
	back_to_title.focus_previous = back_to_title.get_path_to(rematch)


func _refresh() -> void:
	var display_name := winner_name.strip_edges()
	if display_name.is_empty():
		display_name = "玩家 %d" % (winner + 1)
	winner_label.text = "%s，胜利！" % display_name
	result_subtitle.text = "PLAYER %d · MATCH COMPLETE" % (winner + 1)

	var mode_label := _mode_label()
	var deck_label := _winner_deck_label()
	mode_value.text = mode_label
	deck_value.text = deck_label
	turn_value.text = "%d 回合" % maxi(0, turn_count)
	summary_label.text = "%s 在第 %d 回合锁定胜局。代表卡与本局信息已经为你整理完毕。" % [
		display_name,
		maxi(0, turn_count),
	]
	_refresh_card()


func _refresh_card() -> void:
	var card_data: Dictionary = {}
	if not winner_card_id.is_empty():
		card_data = CardDatabase.get_card(winner_card_id)
	var image_path := str(card_data.get("image_path", ""))
	card_image.texture = (
		CardTextureCache.get_texture(image_path) if not image_path.is_empty() else null
	)
	card_image.visible = card_image.texture != null
	card_placeholder.visible = not card_image.visible

	var explicit_name := str(context.get("winner_card_name", "")).strip_edges()
	var resolved_name := explicit_name
	if resolved_name.is_empty():
		resolved_name = str(card_data.get("name", "")).strip_edges()
	if resolved_name.is_empty():
		resolved_name = "本局未记录代表卡"
	card_name_label.text = resolved_name
	card_image.tooltip_text = resolved_name


func _mode_label() -> String:
	var explicit_label := str(context.get("mode_label", "")).strip_edges()
	if not explicit_label.is_empty():
		return explicit_label
	var mode := str(context.get("mode", "")).strip_edges().to_lower()
	return {
		"local": "本地双人",
		"challenge": "Challenge AI",
		"deep": "Deep AI",
		"network": "联机对战",
		"lan": "LAN 联机",
		"relay": "Relay 联机",
	}.get(mode, "自定义对局")


func _winner_deck_label() -> String:
	for key: String in ["winner_deck_name", "winner_deck", "deck_name"]:
		if context.has(key):
			var direct := _stringify_deck(context.get(key))
			if not direct.is_empty():
				return direct

	var decks: Variant = context.get("decks", context.get("player_decks", []))
	if decks is Array:
		var deck_list := decks as Array
		if winner >= 0 and winner < deck_list.size():
			var from_array := _stringify_deck(deck_list[winner])
			if not from_array.is_empty():
				return from_array
	elif decks is Dictionary:
		var deck_map := decks as Dictionary
		var value: Variant = null
		if deck_map.has(winner):
			value = deck_map[winner]
		elif deck_map.has(str(winner)):
			value = deck_map[str(winner)]
		elif deck_map.has("player_%d" % (winner + 1)):
			value = deck_map["player_%d" % (winner + 1)]
		var from_map := _stringify_deck(value)
		if not from_map.is_empty():
			return from_map
	return "本局未记录"


func _stringify_deck(value: Variant) -> String:
	if value is String or value is StringName:
		return str(value).strip_edges()
	if value is Dictionary:
		var row := value as Dictionary
		for key: String in ["display_name", "name", "title", "deck_name", "key"]:
			var label := str(row.get(key, "")).strip_edges()
			if not label.is_empty():
				return label
	return ""


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var aspect := size.x / maxf(1.0, size.y)
	var wide := size.x >= WIDE_MIN_WIDTH and aspect >= WIDE_MIN_ASPECT
	var base_margin := 24 if wide else 14
	var horizontal_margin := maxi(
		base_margin,
		int(ceil(maxf(0.0, size.x - MAX_PANEL_WIDTH) * 0.5)),
	)
	var vertical_margin := 24 if wide else 6
	safe_content.add_theme_constant_override("margin_left", horizontal_margin)
	safe_content.add_theme_constant_override("margin_right", horizontal_margin)
	safe_content.add_theme_constant_override("margin_top", vertical_margin)
	safe_content.add_theme_constant_override("margin_bottom", vertical_margin)

	var available_width := maxf(0.0, size.x - horizontal_margin * 2.0)
	victory_panel.custom_minimum_size.x = minf(MAX_PANEL_WIDTH, available_width)
	result_grid.columns = 2 if wide else 1
	result_grid.add_theme_constant_override("h_separation", 22 if wide else 12)
	result_grid.add_theme_constant_override("v_separation", 22 if wide else 10)
	panel_margin.add_theme_constant_override("margin_left", 34 if wide else 18)
	panel_margin.add_theme_constant_override("margin_right", 34 if wide else 18)
	panel_margin.add_theme_constant_override("margin_top", 28 if wide else 12)
	panel_margin.add_theme_constant_override("margin_bottom", 28 if wide else 12)
	content.add_theme_constant_override("separation", 12 if wide else 6)
	winner_label.add_theme_font_size_override("font_size", 46 if wide else 34)
	result_subtitle.visible = wide
	summary_label.visible = wide
	footer_hint.visible = wide
	card_stage.custom_minimum_size = Vector2(300, 304) if wide else Vector2(0, 168)
	card_frame.custom_minimum_size = Vector2(172, 242) if wide else Vector2(100, 140)
	for row: HBoxContainer in [mode_row, deck_row, turn_row]:
		row.custom_minimum_size.y = 44 if wide else 36
	rematch_button.custom_minimum_size = Vector2(248 if wide else 214, 56 if wide else 52)
	title_button.custom_minimum_size = Vector2(218 if wide else 194, 56 if wide else 52)
	call_deferred("_center_panel_pivot")


func _center_panel_pivot() -> void:
	if victory_panel:
		victory_panel.pivot_offset = victory_panel.size * 0.5


func _start_entrance() -> void:
	if _entrance_started:
		return
	_entrance_started = true
	_center_panel_pivot()
	if not FRONTEND_MOTION.decorative_motion_enabled():
		_show_final_motion_state()
		return
	var animation: Animation = (
		animation_player.get_animation("enter") if animation_player else null
	)
	if animation == null:
		FRONTEND_MOTION.play_enter(victory_panel, 0.38, 0.94)
		return
	var duration := FRONTEND_MOTION.duration(animation.length)
	animation_player.speed_scale = animation.length / maxf(duration, 0.001)
	animation_player.play("enter")


func _on_runtime_settings_changed() -> void:
	if not FRONTEND_MOTION.decorative_motion_enabled():
		_show_final_motion_state()


func _show_final_motion_state() -> void:
	if animation_player:
		animation_player.stop()
		animation_player.speed_scale = 1.0
	victory_panel.modulate = Color.WHITE
	victory_panel.scale = Vector2.ONE

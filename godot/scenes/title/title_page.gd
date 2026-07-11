class_name TitlePage
extends Control

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")

signal mode_selected(mode: String)
signal network_selected(kind: String)
signal settings_requested
signal help_requested

const WIDE_MIN_WIDTH := 1360.0
const WIDE_MIN_ASPECT := 1.5
const MAX_CONTENT_WIDTH := 1480.0
const WIDE_OUTER_MARGIN := 28
const COMPACT_OUTER_MARGIN := 16

@export_category("Editable Copy")
@export var game_title := "宝可梦卡牌对战"
@export var subtitle := "真实卡图 · 原生规则 · 离线 AI · 跨平台联机"

var _version_text := "Client 0.0.0 · Rules v0 · Protocol v0"
var _is_wide := false
var _entrance_started := false

@onready var safe_content: MarginContainer = %SafeContent
@onready var page_frame: VBoxContainer = %PageFrame
@onready var header_panel: PanelContainer = %HeaderPanel
@onready var header_tag: Label = %HeaderTag
@onready var version_label: Label = %VersionLabel
@onready var body_grid: GridContainer = %BodyGrid
@onready var hero_panel: PanelContainer = %HeroPanel
@onready var hero_margin: MarginContainer = %HeroMargin
@onready var hero_content: VBoxContainer = %HeroContent
@onready var hero_eyebrow: Label = %HeroEyebrow
@onready var title_label: Label = %TitleLabel
@onready var hero_subtitle: Label = %HeroSubtitle
@onready var hero_description: Label = %HeroDescription
@onready var feature_row: HBoxContainer = %FeatureRow
@onready var hero_mosaic: HBoxContainer = %HeroMosaic
@onready var modes_panel: PanelContainer = %ModesPanel
@onready var modes_margin: MarginContainer = %ModesMargin
@onready var modes_subheading: Label = %ModesSubheading
@onready var mode_grid: GridContainer = %ModeGrid
@onready var online_card: PanelContainer = %OnlineCard
@onready var online_margin: MarginContainer = %OnlineMargin
@onready var online_description: Label = %OnlineDescription
@onready var animation_player: AnimationPlayer = %AnimationPlayer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_title_copy_to_controls()
	_connect_actions()
	_setup_focus_navigation()
	if not resized.is_connected(_apply_responsive_layout):
		resized.connect(_apply_responsive_layout)
	if not page_frame.resized.is_connected(_center_frame_pivot):
		page_frame.resized.connect(_center_frame_pivot)
	if not AppSettings.changed.is_connected(_on_runtime_settings_changed):
		AppSettings.changed.connect(_on_runtime_settings_changed)
	_apply_responsive_layout()
	call_deferred("_start_entrance")
	%LocalTwoPlayerButton.call_deferred("grab_focus")


func configure(version_text: String) -> void:
	_version_text = version_text
	_connect_actions()
	var label := get_node_or_null(
		"SafeContent/PageFrame/HeaderPanel/HeaderMargin/HeaderRow/VersionLabel"
	) as Label
	if label:
		label.text = _version_text


func _title_copy_to_controls() -> void:
	title_label.text = game_title
	hero_subtitle.text = subtitle
	version_label.text = _version_text


func _connect_actions() -> void:
	var bindings: Array = [
		[%LocalTwoPlayerButton, mode_selected.emit.bind("local")],
		[%ChallengeAIButton, mode_selected.emit.bind("challenge")],
		[%DeepAIButton, mode_selected.emit.bind("deep")],
		[%LANButton, network_selected.emit.bind("lan")],
		[%RelayButton, network_selected.emit.bind("relay")],
		[%SettingsButton, settings_requested.emit],
		[%HelpButton, help_requested.emit],
	]
	for row: Array in bindings:
		var button := row[0] as Button
		var callback := row[1] as Callable
		if not button.pressed.is_connected(callback):
			button.pressed.connect(callback)


func _setup_focus_navigation() -> void:
	var local := %LocalTwoPlayerButton as Button
	var challenge := %ChallengeAIButton as Button
	var deep := %DeepAIButton as Button
	var lan := %LANButton as Button
	var relay := %RelayButton as Button
	var settings := %SettingsButton as Button
	var help := %HelpButton as Button

	_set_focus_neighbor(local, "right", challenge)
	_set_focus_neighbor(local, "bottom", deep)
	_set_focus_neighbor(local, "top", settings)
	_set_focus_neighbor(challenge, "left", local)
	_set_focus_neighbor(challenge, "bottom", lan)
	_set_focus_neighbor(challenge, "top", help)
	_set_focus_neighbor(deep, "top", local)
	_set_focus_neighbor(deep, "right", lan)
	_set_focus_neighbor(lan, "top", challenge)
	_set_focus_neighbor(lan, "left", deep)
	_set_focus_neighbor(lan, "right", relay)
	_set_focus_neighbor(relay, "top", challenge)
	_set_focus_neighbor(relay, "left", lan)
	_set_focus_neighbor(settings, "right", help)
	_set_focus_neighbor(settings, "bottom", local)
	_set_focus_neighbor(help, "left", settings)
	_set_focus_neighbor(help, "bottom", challenge)


func _set_focus_neighbor(source: Control, direction: String, target: Control) -> void:
	var path := source.get_path_to(target)
	match direction:
		"left":
			source.focus_neighbor_left = path
		"right":
			source.focus_neighbor_right = path
		"top":
			source.focus_neighbor_top = path
		"bottom":
			source.focus_neighbor_bottom = path


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var aspect := size.x / maxf(1.0, size.y)
	_is_wide = size.x >= WIDE_MIN_WIDTH and aspect >= WIDE_MIN_ASPECT
	var base_margin := WIDE_OUTER_MARGIN if _is_wide else COMPACT_OUTER_MARGIN
	var horizontal_margin := maxi(
		base_margin,
		int(ceil(maxf(0.0, size.x - MAX_CONTENT_WIDTH) * 0.5)),
	)
	var vertical_margin := 24 if _is_wide else 8
	safe_content.add_theme_constant_override("margin_left", horizontal_margin)
	safe_content.add_theme_constant_override("margin_right", horizontal_margin)
	safe_content.add_theme_constant_override("margin_top", vertical_margin)
	safe_content.add_theme_constant_override("margin_bottom", vertical_margin)

	body_grid.columns = 2 if _is_wide else 1
	body_grid.add_theme_constant_override("h_separation", 24 if _is_wide else 14)
	body_grid.add_theme_constant_override("v_separation", 24 if _is_wide else 12)
	page_frame.add_theme_constant_override("separation", 18 if _is_wide else 8)
	mode_grid.add_theme_constant_override("h_separation", 16 if _is_wide else 12)
	mode_grid.add_theme_constant_override("v_separation", 16 if _is_wide else 12)

	header_panel.custom_minimum_size.y = 64 if _is_wide else 54
	header_tag.visible = _is_wide
	version_label.visible = _is_wide
	hero_eyebrow.visible = _is_wide
	hero_description.visible = _is_wide
	feature_row.visible = _is_wide
	hero_mosaic.visible = _is_wide
	modes_subheading.visible = _is_wide
	online_description.visible = _is_wide

	hero_panel.size_flags_vertical = (
		Control.SIZE_EXPAND_FILL if _is_wide else Control.SIZE_SHRINK_BEGIN
	)
	hero_panel.custom_minimum_size = Vector2(0, 0 if _is_wide else 104)
	modes_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", 54 if _is_wide else 32)
	hero_subtitle.add_theme_font_size_override("font_size", 20 if _is_wide else 15)
	hero_margin.add_theme_constant_override("margin_left", 32 if _is_wide else 20)
	hero_margin.add_theme_constant_override("margin_right", 32 if _is_wide else 20)
	hero_margin.add_theme_constant_override("margin_top", 28 if _is_wide else 9)
	hero_margin.add_theme_constant_override("margin_bottom", 28 if _is_wide else 9)
	hero_content.add_theme_constant_override("separation", 12 if _is_wide else 4)
	modes_margin.add_theme_constant_override("margin_left", 24 if _is_wide else 18)
	modes_margin.add_theme_constant_override("margin_right", 24 if _is_wide else 18)
	modes_margin.add_theme_constant_override("margin_top", 22 if _is_wide else 12)
	modes_margin.add_theme_constant_override("margin_bottom", 22 if _is_wide else 12)
	online_margin.add_theme_constant_override("margin_left", 16 if _is_wide else 12)
	online_margin.add_theme_constant_override("margin_right", 16 if _is_wide else 12)
	online_margin.add_theme_constant_override("margin_top", 13 if _is_wide else 8)
	online_margin.add_theme_constant_override("margin_bottom", 13 if _is_wide else 8)

	var tile_height := 176.0 if _is_wide else 128.0
	for button: Button in [
		%LocalTwoPlayerButton,
		%ChallengeAIButton,
		%DeepAIButton,
	]:
		button.custom_minimum_size.y = tile_height
	online_card.custom_minimum_size.y = tile_height
	call_deferred("_center_frame_pivot")


func _center_frame_pivot() -> void:
	if page_frame:
		page_frame.pivot_offset = page_frame.size * 0.5


func _start_entrance() -> void:
	if _entrance_started:
		return
	_entrance_started = true
	_center_frame_pivot()
	if FRONTEND_MOTION.is_reduced():
		_show_final_motion_state()
		return
	var animation: Animation = (
		animation_player.get_animation("enter") if animation_player else null
	)
	if animation == null:
		FRONTEND_MOTION.play_enter(page_frame, 0.28, 0.985)
		return
	var duration := FRONTEND_MOTION.duration(animation.length)
	animation_player.speed_scale = animation.length / maxf(duration, 0.001)
	animation_player.play("enter")


func _on_runtime_settings_changed() -> void:
	if AppSettings.reduced_motion:
		_show_final_motion_state()


func _show_final_motion_state() -> void:
	if animation_player:
		animation_player.stop()
		animation_player.speed_scale = 1.0
	page_frame.modulate = Color.WHITE
	page_frame.scale = Vector2.ONE

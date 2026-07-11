class_name TitlePage
extends Control

const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")

signal mode_selected(mode: String)
signal network_selected(kind: String)
signal settings_requested
signal help_requested

const MAX_CONTENT_WIDTH := 1500.0
const WIDE_MIN_WIDTH := 1180.0
const WIDE_MIN_HEIGHT := 650.0
const WIDE_MIN_ASPECT := 1.5
const COMPACT_MIN_WIDTH := 900.0
const COMPACT_MIN_HEIGHT := 600.0
const COMPACT_MIN_ASPECT := 1.15
const CARD_ASPECT := 419.0 / 300.0

enum LayoutTier {
	WIDE,
	COMPACT_LANDSCAPE,
	DENSE,
}

@export_category("Editable Copy")
@export var game_title := "宝可梦卡牌对战"
@export var brand_subtitle := "P T C G  ·  TABLETOP EDITION"

var _version_text := "v0.0.0"
var _layout_tier := LayoutTier.WIDE
var _embedded_backdrop_enabled := true
var _entrance_started := false
var _entrance_tweens: Array[Tween] = []
var _motion_enabled := false
var _elapsed := 0.0
var _parallax := Vector2.ZERO
var _card_base_positions: Array[Vector2] = []
var _card_base_rotations: Array[float] = []

@onready var embedded_backdrop: Control = %EmbeddedBackdrop
@onready var safe_content: MarginContainer = %SafeContent
@onready var page_frame: VBoxContainer = %PageFrame
@onready var header_panel: Control = %HeaderPanel
@onready var header_content: VBoxContainer = %HeaderContent
@onready var title_stack: Control = %TitleStack
@onready var title_shadow: Label = %TitleShadow
@onready var title_label: Label = %TitleLabel
@onready var brand_subtitle_label: Label = %BrandSubtitle
@onready var type_orbs_center: CenterContainer = %TypeOrbsCenter
@onready var body_grid: GridContainer = %BodyGrid
@onready var hero_panel: Control = %HeroPanel
@onready var card_stage: Control = %CardStage
@onready var modes_panel: MarginContainer = %ModesPanel
@onready var mode_stack: VBoxContainer = %ModeStack
@onready var footer_row: HBoxContainer = %FooterRow
@onready var version_label: Label = %VersionLabel

@onready var cards: Array[TextureRect] = [%GrassCard, %WaterCard, %FireCard]
@onready var card_shadows: Array[TextureRect] = [
	%GrassCardShadow,
	%WaterCardShadow,
	%FireCardShadow,
]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	title_label.text = game_title
	title_shadow.text = game_title
	brand_subtitle_label.text = brand_subtitle
	version_label.text = _version_text
	embedded_backdrop.visible = _embedded_backdrop_enabled
	_connect_actions()
	_setup_focus_navigation()
	if not resized.is_connected(_apply_responsive_layout):
		resized.connect(_apply_responsive_layout)
	if not card_stage.resized.is_connected(_layout_cards):
		card_stage.resized.connect(_layout_cards)
	var settings := _settings_node()
	if settings != null and settings.has_signal("changed"):
		var callback := Callable(self, "_on_runtime_settings_changed")
		if not settings.is_connected("changed", callback):
			settings.connect("changed", callback)
	_apply_responsive_layout()
	_refresh_motion_state()
	call_deferred("_start_entrance")
	%LocalTwoPlayerButton.call_deferred("grab_focus")


func configure(version_text: String) -> void:
	_version_text = version_text
	_connect_actions()
	_setup_focus_navigation()
	var label := get_node_or_null(
		"SafeContent/PageFrame/FooterRow/VersionLabel"
	) as Label
	if label:
		label.text = _version_text


func set_embedded_backdrop_visible(enabled: bool) -> void:
	_embedded_backdrop_enabled = enabled
	var backdrop := get_node_or_null("EmbeddedBackdrop") as Control
	if backdrop:
		backdrop.visible = enabled


func _process(delta: float) -> void:
	_elapsed += delta
	var pointer := get_viewport().get_mouse_position()
	var target := Vector2(
		clampf(pointer.x / maxf(size.x, 1.0) - 0.5, -0.5, 0.5),
		clampf(pointer.y / maxf(size.y, 1.0) - 0.5, -0.5, 0.5),
	) * 12.0
	_parallax = _parallax.lerp(target, minf(1.0, delta * 3.4))
	_apply_card_motion()


func _connect_actions() -> void:
	var bindings: Array = [
		[%LocalTwoPlayerButton, mode_selected.emit.bind("local")],
		[%AIButton, mode_selected.emit.bind("challenge")],
		[%NetworkButton, network_selected.emit.bind("lan")],
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
	var ai := %AIButton as Button
	var network := %NetworkButton as Button
	var settings := %SettingsButton as Button
	var help := %HelpButton as Button
	_set_focus_neighbor(local, "top", help)
	_set_focus_neighbor(local, "bottom", ai)
	_set_focus_neighbor(ai, "top", local)
	_set_focus_neighbor(ai, "bottom", network)
	_set_focus_neighbor(network, "top", ai)
	_set_focus_neighbor(network, "bottom", settings)
	_set_focus_neighbor(settings, "top", network)
	_set_focus_neighbor(settings, "bottom", local)
	_set_focus_neighbor(settings, "left", help)
	_set_focus_neighbor(settings, "right", help)
	_set_focus_neighbor(help, "top", network)
	_set_focus_neighbor(help, "bottom", local)
	_set_focus_neighbor(help, "left", settings)
	_set_focus_neighbor(help, "right", settings)
	var tab_order: Array[Button] = [local, ai, network, settings, help]
	for index in range(tab_order.size()):
		var button := tab_order[index]
		button.focus_next = button.get_path_to(tab_order[(index + 1) % tab_order.size()])
		button.focus_previous = button.get_path_to(
			tab_order[posmod(index - 1, tab_order.size())]
		)


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
	if not is_node_ready() or size.x <= 0.0 or size.y <= 0.0:
		return
	var aspect := size.x / maxf(size.y, 1.0)
	if size.x >= WIDE_MIN_WIDTH and size.y >= WIDE_MIN_HEIGHT and aspect >= WIDE_MIN_ASPECT:
		_layout_tier = LayoutTier.WIDE
	elif (
		size.x >= COMPACT_MIN_WIDTH
		and size.y >= COMPACT_MIN_HEIGHT
		and aspect >= COMPACT_MIN_ASPECT
	):
		_layout_tier = LayoutTier.COMPACT_LANDSCAPE
	else:
		_layout_tier = LayoutTier.DENSE

	var base_margin := 24 if _layout_tier == LayoutTier.WIDE else 18 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 14
	var horizontal_margin := maxi(
		base_margin,
		int(ceil(maxf(0.0, size.x - MAX_CONTENT_WIDTH) * 0.5)),
	)
	var vertical_margin := 10 if _layout_tier == LayoutTier.WIDE else 8 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 6
	for side in ["left", "right"]:
		safe_content.add_theme_constant_override("margin_" + side, horizontal_margin)
	for side in ["top", "bottom"]:
		safe_content.add_theme_constant_override("margin_" + side, vertical_margin)

	var dense := _layout_tier == LayoutTier.DENSE
	body_grid.columns = 1 if dense else 2
	body_grid.add_theme_constant_override("h_separation", 34 if _layout_tier == LayoutTier.WIDE else 18)
	body_grid.add_theme_constant_override("v_separation", 10)
	hero_panel.visible = not dense
	hero_panel.custom_minimum_size.x = 430 if _layout_tier == LayoutTier.WIDE else 320 if not dense else 0
	modes_panel.custom_minimum_size.x = 470 if _layout_tier == LayoutTier.WIDE else 420 if not dense else 0
	modes_panel.add_theme_constant_override("margin_left", 12 if _layout_tier == LayoutTier.WIDE else 6)
	modes_panel.add_theme_constant_override("margin_right", 12 if _layout_tier == LayoutTier.WIDE else 6)
	modes_panel.add_theme_constant_override(
		"margin_top",
		12 if _layout_tier == LayoutTier.WIDE else 4,
	)
	modes_panel.add_theme_constant_override("margin_bottom", 12 if _layout_tier == LayoutTier.WIDE else 4)

	var title_size := 78 if _layout_tier == LayoutTier.WIDE else 54 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 44
	var header_height := 182 if _layout_tier == LayoutTier.WIDE else 124 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 122
	var title_stack_height := 104 if _layout_tier == LayoutTier.WIDE else 70 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 64
	header_panel.custom_minimum_size.y = header_height
	title_stack.custom_minimum_size.y = title_stack_height
	title_label.add_theme_font_size_override("font_size", title_size)
	title_shadow.add_theme_font_size_override("font_size", title_size)
	title_shadow.add_theme_constant_override("outline_size", 13 if _layout_tier == LayoutTier.WIDE else 10 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 8)
	brand_subtitle_label.add_theme_font_size_override("font_size", 18 if _layout_tier == LayoutTier.WIDE else 16 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 14)
	type_orbs_center.visible = not dense

	var button_height := 116 if _layout_tier == LayoutTier.WIDE else 96 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 84
	mode_stack.add_theme_constant_override("separation", 18 if _layout_tier == LayoutTier.WIDE else 12 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 10)
	mode_stack.alignment = BoxContainer.ALIGNMENT_CENTER
	for button: Button in [%LocalTwoPlayerButton, %AIButton, %NetworkButton]:
		button.custom_minimum_size.y = button_height
	footer_row.custom_minimum_size.y = 54 if not dense else 48
	%SettingsButton.custom_minimum_size = Vector2(116 if not dense else 96, 48)
	%HelpButton.custom_minimum_size = Vector2(136 if not dense else 116, 48)
	page_frame.add_theme_constant_override("separation", 10 if _layout_tier == LayoutTier.WIDE else 8 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 5)
	call_deferred("_layout_cards")
	call_deferred("_center_section_pivots")
	_refresh_motion_state()


func _layout_cards() -> void:
	if not is_node_ready() or not hero_panel.visible or card_stage.size.x <= 0.0 or card_stage.size.y <= 0.0:
		return
	var widths := [220.0, 240.0, 260.0] if _layout_tier == LayoutTier.WIDE else [150.0, 168.0, 184.0]
	var rotations := [-0.175, -0.052, 0.122]
	var center := card_stage.size * Vector2(
		0.49,
		0.43 if _layout_tier == LayoutTier.COMPACT_LANDSCAPE else 0.51,
	)
	var spread: float = float(widths[1]) * (0.54 if _layout_tier == LayoutTier.WIDE else 0.50)
	var centers := [
		center + Vector2(-spread * 0.86, 18),
		center + Vector2(-spread * 0.12, -9),
		center + Vector2(spread * 0.62, 9),
	]
	_card_base_positions.clear()
	_card_base_rotations.clear()
	for index in range(cards.size()):
		var card_size := Vector2(widths[index], widths[index] * CARD_ASPECT)
		var position_value: Vector2 = centers[index] - card_size * 0.5
		_card_base_positions.append(position_value)
		_card_base_rotations.append(rotations[index])
		for control: TextureRect in [card_shadows[index], cards[index]]:
			control.size = card_size
			control.pivot_offset = card_size * 0.5
	_apply_card_motion()


func _apply_card_motion() -> void:
	if _card_base_positions.size() != cards.size():
		return
	for index in range(cards.size()):
		var float_offset := 0.0
		var rotation_offset := 0.0
		if _motion_enabled:
			float_offset = sin(_elapsed * 0.72 + index * 1.15) * 4.0
			rotation_offset = sin(_elapsed * 0.44 + index * 0.9) * 0.009
		var position_value := (
			_card_base_positions[index]
			+ _parallax * (0.20 + index * 0.07)
			+ Vector2(0, float_offset)
		)
		cards[index].position = position_value
		cards[index].rotation = _card_base_rotations[index] + rotation_offset
		card_shadows[index].position = position_value + Vector2(9, 12)
		card_shadows[index].rotation = cards[index].rotation


func _refresh_motion_state() -> void:
	if not is_node_ready():
		return
	_motion_enabled = hero_panel.visible and FRONTEND_MOTION.decorative_motion_enabled()
	set_process(_motion_enabled)
	if not _motion_enabled:
		_elapsed = 0.0
		_parallax = Vector2.ZERO
		_apply_card_motion()


func _on_runtime_settings_changed() -> void:
	_refresh_motion_state()
	if not FRONTEND_MOTION.decorative_motion_enabled():
		_show_final_motion_state()


func _settings_node() -> Node:
	return get_node_or_null("/root/AppSettings")


func _center_section_pivots() -> void:
	for section: Control in [header_panel, body_grid, footer_row]:
		section.pivot_offset = section.size * 0.5


func _start_entrance() -> void:
	if _entrance_started or not is_node_ready():
		return
	_entrance_started = true
	_center_section_pivots()
	if not FRONTEND_MOTION.decorative_motion_enabled():
		_show_final_motion_state()
		return
	_animate_section(header_panel, 0.0)
	_animate_section(body_grid, 0.06)
	_animate_section(footer_row, 0.12)


func _animate_section(control: Control, delay: float) -> void:
	control.modulate = Color(1, 1, 1, 0)
	control.scale = Vector2.ONE * 0.985
	var tween := control.create_tween()
	_entrance_tweens.append(tween)
	tween.finished.connect(func() -> void:
		_entrance_tweens.erase(tween)
	)
	tween.tween_interval(FRONTEND_MOTION.duration(delay))
	tween.tween_property(
		control,
		"modulate:a",
		1.0,
		FRONTEND_MOTION.duration(0.28),
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(
		control,
		"scale",
		Vector2.ONE,
		FRONTEND_MOTION.duration(0.28),
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)


func _show_final_motion_state() -> void:
	for tween in _entrance_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_entrance_tweens.clear()
	for section: Control in [header_panel, body_grid, footer_row]:
		section.modulate = Color.WHITE
		section.scale = Vector2.ONE

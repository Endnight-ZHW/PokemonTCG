class_name TitlePage
extends Control

signal mode_selected(mode: String)
signal network_selected(kind: String)
signal settings_requested
signal help_requested

const MAX_CONTENT_WIDTH := 1440.0
const ENERGY_TYPES: Array[String] = ["Grass", "Fire", "Water", "Lightning", "Psychic", "Fighting", "Darkness", "Metal"]
@export var game_title := "宝可梦卡牌对战"
@export var brand_subtitle := "挑选牌组，准备下一场对战。"
var _version_text := "v0.0.0"
var _embedded_backdrop_enabled := true
var _background_active := true

@onready var embedded_backdrop: FrontendBackdrop = %EmbeddedBackdrop
@onready var safe_content: MarginContainer = %SafeContent
@onready var page_frame: VBoxContainer = %PageFrame
@onready var header_panel: Control = %HeaderPanel
@onready var title_label: Label = %TitleLabel
@onready var brand_subtitle_label: Label = %BrandSubtitle
@onready var body_grid: GridContainer = %BodyGrid
@onready var hero_panel: VBoxContainer = %HeroPanel
@onready var card_stage: FrontendCardShowcase3D = %CardStage
@onready var modes_panel: VBoxContainer = %ModesPanel
@onready var mode_stack: VBoxContainer = %ModeStack
@onready var footer_row: HBoxContainer = %FooterRow
@onready var version_label: Label = %VersionLabel
@onready var type_orbs: HBoxContainer = %TypeOrbs
var energy_icons: Array[TextureRect] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	title_label.text = game_title
	brand_subtitle_label.text = brand_subtitle
	version_label.text = _version_text
	embedded_backdrop.visible = _embedded_backdrop_enabled
	for type in ENERGY_TYPES:
		var icon := TextureRect.new()
		icon.name = type + "EnergyIcon"
		icon.texture = EnergyIconCatalog.texture_for(type)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(24, 24)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_meta("energy_type", type)
		type_orbs.add_child(icon)
		energy_icons.append(icon)
	_connect_actions()
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	card_stage.set_active(_background_active)
	call_deferred("_play_enter")

func configure(version_text: String) -> void:
	_version_text = version_text
	if is_node_ready():
		version_label.text = version_text

func set_embedded_backdrop_visible(enabled: bool) -> void:
	_embedded_backdrop_enabled = enabled
	var backdrop := get_node_or_null("EmbeddedBackdrop") as Control
	if backdrop != null:
		backdrop.visible = enabled

func set_background_active(active: bool) -> void:
	_background_active = active
	if is_node_ready():
		card_stage.set_active(active)

func _connect_actions() -> void:
	for row in [
		[%LocalTwoPlayerButton, mode_selected.emit.bind("local")],
		[%AIButton, mode_selected.emit.bind("challenge")],
		[%NetworkButton, network_selected.emit.bind("lan")],
		[%SettingsButton, settings_requested.emit],
		[%HelpButton, help_requested.emit],
	]:
		var button := row[0] as Button
		var callback: Callable = row[1]
		if not button.pressed.is_connected(callback):
			button.pressed.connect(callback)

func _apply_responsive_layout() -> void:
	if not is_node_ready():
		return
	var portrait := size.x < size.y * 1.05
	var compact := size.x < 1180 or size.y < 650
	var margin := 24 if compact else 40
	var side := maxi(margin, int((size.x - MAX_CONTENT_WIDTH) * 0.5))
	for edge in ["left", "right"]:
		safe_content.add_theme_constant_override("margin_" + edge, side)
	for edge in ["top", "bottom"]:
		safe_content.add_theme_constant_override("margin_" + edge, 24 if compact else 32)
	page_frame.add_theme_constant_override("separation", 16 if compact else 24)
	header_panel.custom_minimum_size.y = 76 if compact else 106
	title_label.add_theme_font_size_override("font_size", 34 if compact else 52)
	brand_subtitle_label.add_theme_font_size_override("font_size", 16 if compact else 18)
	body_grid.columns = 1 if portrait else 2
	body_grid.add_theme_constant_override("h_separation", 24 if compact else 48)
	body_grid.add_theme_constant_override("v_separation", 12)
	hero_panel.custom_minimum_size = Vector2(0 if portrait else 300 if compact else 520, minf(280, size.y * 0.3) if portrait else 0)
	modes_panel.custom_minimum_size.x = 0 if portrait else 360 if compact else 440
	card_stage.custom_minimum_size.y = minf(230, size.y * 0.25) if portrait else 0
	mode_stack.add_theme_constant_override("separation", 12 if compact else 24)
	for button in [%LocalTwoPlayerButton, %AIButton, %NetworkButton]:
		button.custom_minimum_size.y = 86 if compact else 112
	%ModeHeading.add_theme_font_size_override("font_size", 18 if compact else 22)
	%HeroCaption.visible = not compact
	type_orbs.add_theme_constant_override("separation", 10 if compact else 14)
	footer_row.custom_minimum_size.y = 52

func _play_enter() -> void:
	FrontendMotion.play_enter(page_frame, 0.20, 0.992)

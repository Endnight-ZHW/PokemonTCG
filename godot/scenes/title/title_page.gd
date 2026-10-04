class_name TitlePage
extends Control

signal mode_selected(mode: String)
signal network_selected(kind: String)
signal settings_requested
signal help_requested
signal showcase_changed(accent: Color)

const MAX_CONTENT_WIDTH := 1440.0
@export var game_title := "宝可梦\n卡牌对战"
static var _remembered_deck_key := ""
var _deck_keys: Array[String] = []
var _deck_index := 0
var _showcase_rng := RandomNumberGenerator.new()
var _application_suspended := false
var _version_text := "v0.0.0"
var _embedded_backdrop_enabled := true
var _background_active := true

@onready var embedded_backdrop: FrontendBackdrop = %EmbeddedBackdrop
@onready var safe_content: MarginContainer = %SafeContent
@onready var page_frame: VBoxContainer = %PageFrame
@onready var header_panel: Control = %HeaderPanel
@onready var title_label: Label = %TitleLabel
@onready var body_grid: HBoxContainer = %BodyGrid
@onready var hero_panel: VBoxContainer = %HeroPanel
@onready var card_stage: FrontendCardShowcase3D = %CardStage
@onready var modes_panel: VBoxContainer = %ModesPanel
@onready var mode_stack: VBoxContainer = %ModeStack
@onready var footer_row: HBoxContainer = %FooterRow
@onready var version_label: Label = %VersionLabel
@onready var showcase_timer: Timer = %ShowcaseTimer

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	title_label.text = game_title
	version_label.text = _version_text
	embedded_backdrop.visible = _embedded_backdrop_enabled
	_deck_keys = DeckVisualCatalog.ordered_deck_keys(CardCatalog.shared())
	_showcase_rng.randomize()
	_deck_index = _deck_keys.find(_remembered_deck_key)
	if _deck_index < 0:
		_deck_index = _showcase_rng.randi_range(0, _deck_keys.size() - 1) if not _deck_keys.is_empty() else 0
	_refresh_featured_deck()
	showcase_timer.timeout.connect(_rotate_random_deck)
	card_stage.interaction_changed.connect(_on_showcase_interaction)
	showcase_timer.start()
	visibility_changed.connect(_refresh_rotation_pause)
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
		_refresh_rotation_pause()
		if not active:
			FrontendMotion.settle(card_stage)

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
	var side := UILayoutPolicy.content_margin(size, MAX_CONTENT_WIDTH, 16, 40)
	for edge in ["left", "right"]:
		safe_content.add_theme_constant_override("margin_" + edge, side)
	for edge in ["top", "bottom"]:
		safe_content.add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 12, 32))
	page_frame.add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 12, 24))
	header_panel.custom_minimum_size.y = 0
	title_label.add_theme_font_size_override("font_size", UILayoutPolicy.fit_int(size, 38, 48))
	body_grid.add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 20, 48))
	body_grid.add_theme_constant_override("v_separation", 12)
	hero_panel.custom_minimum_size = Vector2(UILayoutPolicy.fit(size, 360, 640), 0)
	modes_panel.custom_minimum_size.x = UILayoutPolicy.fit(size, 330, 420)
	card_stage.custom_minimum_size.y = 0
	mode_stack.add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 10, 14))
	for button in [%LocalTwoPlayerButton, %AIButton, %NetworkButton]:
		button.custom_minimum_size.y = UILayoutPolicy.fit(size, 84, 96)
	footer_row.custom_minimum_size.y = 52

func _play_enter() -> void:
	FrontendMotion.play_enter(page_frame, 0.22, 0.992)


func featured_deck_key() -> String:
	return _deck_keys[_deck_index] if not _deck_keys.is_empty() else ""

func featured_accent() -> Color:
	var deck := CardCatalog.shared().get_deck(featured_deck_key())
	return DesignTokens.type_color(str(deck.get("energy_type", "Colorless")))

func _rotate_random_deck() -> void:
	if _deck_keys.size() < 2 or not _background_active or _application_suspended or not is_visible_in_tree() or card_stage.is_interacting():
		return
	# A dedicated cosmetic RNG never consumes the battle/session random stream.
	var next := _showcase_rng.randi_range(0, _deck_keys.size() - 2)
	_deck_index = next + 1 if next >= _deck_index else next
	_refresh_featured_deck()
	FrontendMotion.play_enter(card_stage, 0.20, 1.0)

func _refresh_rotation_pause() -> void:
	showcase_timer.paused = not _background_active or _application_suspended or not is_visible_in_tree() or card_stage.is_interacting()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		_application_suspended = true
	elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
		_application_suspended = false
	else:
		return
	if is_node_ready():
		_refresh_rotation_pause()

func _refresh_featured_deck() -> void:
	var key := featured_deck_key()
	var catalog := CardCatalog.shared()
	var deck := catalog.get_deck(key)
	var name_value := str(deck.get("name", "暂无牌组"))
	var type_value := str(deck.get("energy_type", "Colorless"))
	_remembered_deck_key = key
	card_stage.set_cards([DeckVisualCatalog.representative_card(catalog, key)])
	card_stage.set_deck(name_value, type_value, int(deck.get("card_count", 0)))
	embedded_backdrop.set_accent(featured_accent())
	showcase_changed.emit(featured_accent())

func _on_showcase_interaction(active: bool) -> void:
	FrontendMotion.settle(card_stage)
	if not active:
		showcase_timer.start()
	_refresh_rotation_pause()

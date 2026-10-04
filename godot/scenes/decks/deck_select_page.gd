class_name DeckSelectPage
extends Control

signal back_requested
signal deck_details_requested(deck_key: String)
signal start_requested(
	mode: String,
	first_deck_key: String,
	second_deck_key: String,
	forced_first_player: int,
	apply_type_matchups: bool,
)

const DECK_TILE_SCENE := preload("res://ui/frontend/deck_gallery_tile.tscn")
const FRONTEND_MOTION := preload("res://ui/frontend/frontend_motion.gd")
const MAX_CONTENT_WIDTH := 1480.0
const MODE_LOCAL := "local"
const MODE_CHALLENGE := "challenge"

var catalog: CardCatalog
var mode := MODE_LOCAL

@onready var mode_description: Label = %ModeDescription

@onready var content_margin: MarginContainer = %ContentMargin
@onready var page_content: VBoxContainer = %PageContent
@onready var top_bar: HBoxContainer = %TopBar
@onready var heading: Label = %Heading
@onready var player_one_slot_button: Button = %PlayerOneSlotButton
@onready var player_two_slot_button: Button = %PlayerTwoSlotButton
@onready var slot_hint: Label = %SlotHint
@onready var gallery_panel: PanelContainer = %GalleryPanel
@onready var gallery_scroll: ScrollContainer = %GalleryScroll
@onready var gallery_grid: GridContainer = %GalleryGrid
@onready var gallery_heading: Label = %GalleryHeading
@onready var slot_margin: MarginContainer = %SlotMargin
@onready var detail_panel: PanelContainer = %DetailPanel
@onready var back_to_gallery_button: Button = %BackToGalleryButton
@onready var detail_assignment: Label = %DetailAssignment
@onready var detail_accent: ColorRect = %DetailAccent
@onready var detail_title: Label = %DetailTitle
@onready var detail_tagline: Label = %DetailTagline
@onready var detail_meta: Label = %DetailMeta
@onready var detail_counts: Label = %DetailCounts
@onready var detail_card_grid: GridContainer = %DetailCardGrid
@onready var assign_deck_button: Button = %AssignDeckButton
@onready var details_button: Button = %DetailsButton
@onready var action_content: BoxContainer = %ActionContent
@onready var matchup_toggle: CheckButton = %TypeMatchupToggle
@onready var start_button: Button = %StartButton
@onready var action_summary: Label = %ActionSummary
@onready var action_margin: MarginContainer = %ActionMargin
@onready var master_detail: HBoxContainer = %MasterDetail

var _deck_keys: Array[String] = []
var _selected_keys: Array[String] = ["", ""]
var _tiles: Dictionary = {}
var _active_player_idx := 0
var _preview_deck_key := ""
var _configured := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	call_deferred("_apply_responsive_layout")


func configure(p_catalog: CardCatalog, p_mode: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	catalog = p_catalog
	mode = p_mode if p_mode in [MODE_LOCAL, MODE_CHALLENGE] else MODE_CHALLENGE
	_deck_keys = DeckVisualCatalog.ordered_deck_keys(catalog)
	_active_player_idx = 0
	matchup_toggle.set_pressed_no_signal(false)
	_refresh_matchup_toggle_presentation()
	_refresh_mode_copy()
	_populate_gallery()
	_selected_keys = [
		_deck_keys[0] if not _deck_keys.is_empty() else "",
		_deck_keys[1] if _deck_keys.size() > 1 else (
			_deck_keys[0] if not _deck_keys.is_empty() else ""
		),
	]
	_preview_deck_key = _selected_keys[0]
	_refresh_all()
	_configured = true
	call_deferred("_apply_responsive_layout")
	call_deferred("_play_enter_animation")


func _resolve_nodes() -> void:
	mode_description = %ModeDescription
	content_margin = %ContentMargin
	page_content = %PageContent
	top_bar = %TopBar
	heading = %Heading
	player_one_slot_button = %PlayerOneSlotButton
	player_two_slot_button = %PlayerTwoSlotButton
	slot_hint = %SlotHint
	gallery_panel = %GalleryPanel
	gallery_scroll = %GalleryScroll
	gallery_grid = %GalleryGrid
	gallery_heading = %GalleryHeading
	slot_margin = %SlotMargin
	detail_panel = %DetailPanel
	back_to_gallery_button = %BackToGalleryButton
	detail_assignment = %DetailAssignment
	detail_accent = %DetailAccent
	detail_title = %DetailTitle
	detail_tagline = %DetailTagline
	detail_meta = %DetailMeta
	detail_counts = %DetailCounts
	detail_card_grid = %DetailCardGrid
	assign_deck_button = %AssignDeckButton
	details_button = %DetailsButton
	action_content = %ActionContent
	matchup_toggle = %TypeMatchupToggle
	start_button = %StartButton
	action_summary = %ActionSummary
	action_margin = %ActionMargin
	master_detail = %MasterDetail
	matchup_toggle.accessibility_name = "弱点与抗性规则"
	FrontendPalette.style_scrollbar(gallery_scroll.get_v_scroll_bar())
	FrontendPalette.style_scrollbar(%DetailScroll.get_v_scroll_bar())


func _ensure_connections() -> void:
	var back_button := %BackButton as Button
	var back_callable := Callable(self, "_emit_back_requested")
	if not back_button.pressed.is_connected(back_callable):
		back_button.pressed.connect(back_callable)
	var player_one_callable := _set_active_player.bind(0)
	if not player_one_slot_button.pressed.is_connected(player_one_callable):
		player_one_slot_button.pressed.connect(player_one_callable)
	var player_two_callable := _set_active_player.bind(1)
	if not player_two_slot_button.pressed.is_connected(player_two_callable):
		player_two_slot_button.pressed.connect(player_two_callable)
	if not details_button.pressed.is_connected(_emit_active_deck_details):
		details_button.pressed.connect(_emit_active_deck_details)
	if not start_button.pressed.is_connected(_emit_start_requested):
		start_button.pressed.connect(_emit_start_requested)
	if not assign_deck_button.pressed.is_connected(_assign_preview):
		assign_deck_button.pressed.connect(_assign_preview)
	if not matchup_toggle.toggled.is_connected(_on_matchup_toggled):
		matchup_toggle.toggled.connect(_on_matchup_toggled)
	if not resized.is_connected(_apply_responsive_layout):
		resized.connect(_apply_responsive_layout)
	if not detail_panel.resized.is_connected(_refresh_detail_columns):
		detail_panel.resized.connect(_refresh_detail_columns)
	_refresh_matchup_toggle_presentation()


func _on_matchup_toggled(_enabled: bool) -> void:
	_refresh_matchup_toggle_presentation()


func _refresh_matchup_toggle_presentation() -> void:
	if matchup_toggle == null:
		return
	var enabled := matchup_toggle.button_pressed
	var state_copy := "已开启" if enabled else "已关闭"
	var state_color := FrontendPalette.SUCCESS if enabled else FrontendPalette.MUTED
	matchup_toggle.text = "弱点/抗性：%s" % state_copy
	matchup_toggle.tooltip_text = (
		"当前已开启：攻击伤害会按中国大陆官方步骤计算弱点与抗性。点击可关闭。"
		if enabled
		else "当前已关闭：攻击伤害不计算弱点与抗性。点击可开启。"
	)
	matchup_toggle.accessibility_name = "弱点与抗性规则，%s" % state_copy
	_apply_matchup_toggle_color(matchup_toggle, state_color)


func _apply_matchup_toggle_color(toggle: CheckButton, color: Color) -> void:
	for color_name in [
		&"font_color",
		&"font_hover_color",
		&"font_hover_pressed_color",
		&"font_focus_color",
		&"font_pressed_color",
		&"font_disabled_color",
		&"icon_normal_color",
		&"icon_hover_color",
		&"icon_hover_pressed_color",
		&"icon_focus_color",
		&"icon_pressed_color",
		&"icon_disabled_color",
	]:
		toggle.add_theme_color_override(color_name, color)


func _emit_back_requested() -> void:
	back_requested.emit()


func selected_deck_key(player_idx: int) -> String:
	if player_idx < 0 or player_idx >= _selected_keys.size():
		return ""
	return _selected_keys[player_idx]


func select_deck(player_idx: int, deck_key: String) -> bool:
	if (
		player_idx < 0
		or player_idx >= _selected_keys.size()
		or catalog == null
		or catalog.get_deck(deck_key).is_empty()
	):
		return false
	_selected_keys[player_idx] = deck_key
	if player_idx == _active_player_idx:
		_preview_deck_key = deck_key
	_refresh_all()
	return true


func deck_count() -> int:
	return _deck_keys.size()


func handle_back() -> bool:
	return false


func _populate_gallery() -> void:
	for child in gallery_grid.get_children():
		gallery_grid.remove_child(child)
		child.queue_free()
	_tiles.clear()
	for deck_key in _deck_keys:
		var tile := DECK_TILE_SCENE.instantiate() as DeckGalleryTile
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gallery_grid.add_child(tile)
		tile.configure(
			catalog,
			deck_key,
			DeckVisualCatalog.representative_card(catalog, deck_key),
		)
		tile.pressed.connect(_on_deck_tile_pressed.bind(deck_key))
		_tiles[deck_key] = tile


func _refresh_mode_copy() -> void:
	match mode:
		MODE_LOCAL:
			heading.text = "选择牌组"
			mode_description.text = (
				"为两位玩家分配牌组，可使用同一套牌。先后手由开局硬币决定。"
			)
		_:
			heading.text = "挑战 AI · 选择牌组"
			mode_description.text = (
				"为自己与电脑对手分配牌组。先后手由开局硬币决定。"
			)
	player_two_slot_button.accessibility_name = "%s 牌组" % _second_slot_name()


func _on_deck_tile_pressed(deck_key: String) -> void:
	if catalog == null or catalog.get_deck(deck_key).is_empty():
		return
	_preview_deck_key = deck_key
	_refresh_tiles()
	_refresh_detail()


func _assign_preview() -> void:
	select_deck(_active_player_idx, _preview_deck_key)


func _set_active_player(player_idx: int) -> void:
	if player_idx < 0 or player_idx > 1:
		return
	_active_player_idx = player_idx
	_preview_deck_key = selected_deck_key(player_idx)
	_refresh_all()


func _refresh_all() -> void:
	_refresh_slot_buttons()
	_refresh_tiles()
	_refresh_detail()
	_refresh_start_state()


func _refresh_slot_buttons() -> void:
	var second_slot_name := _second_slot_name()
	player_one_slot_button.text = "玩家 1\n%s" % _deck_display_name(_selected_keys[0])
	player_two_slot_button.text = "%s\n%s" % [
		second_slot_name,
		_deck_display_name(_selected_keys[1]),
	]
	var active_slot := player_one_slot_button if _active_player_idx == 0 else player_two_slot_button
	active_slot.text = "当前 · " + active_slot.text
	player_one_slot_button.set_pressed_no_signal(_active_player_idx == 0)
	player_two_slot_button.set_pressed_no_signal(_active_player_idx == 1)
	slot_hint.text = "分配目标 · %s" % (
		"玩家 1" if _active_player_idx == 0 else second_slot_name
	)


func _refresh_tiles() -> void:
	for tile_value in _tiles.values():
		(tile_value as DeckGalleryTile).set_assignment_state(
			_selected_keys,
			_second_slot_name(),
		)
		(tile_value as DeckGalleryTile).set_pressed_no_signal(
			(tile_value as DeckGalleryTile).deck_key == _preview_deck_key
		)


func _refresh_detail() -> void:
	_clear_detail_cards()
	var deck_key := _preview_deck_key
	var deck := catalog.get_deck(deck_key) if catalog else {}
	if deck.is_empty():
		detail_assignment.text = "尚未选择牌组"
		detail_title.text = "从左侧画廊选择"
		detail_tagline.text = "选择后会在这里显示核心卡与牌组构成。"
		detail_meta.text = ""
		detail_counts.text = ""
		assign_deck_button.disabled = true
		details_button.disabled = true
		return
	var slot_name := "玩家 1" if _active_player_idx == 0 else _second_slot_name()
	var assigned := selected_deck_key(_active_player_idx) == deck_key
	detail_assignment.text = "正在浏览"
	assign_deck_button.text = ("✓ 已分配给 %s" if assigned else "分配给 %s") % slot_name
	assign_deck_button.disabled = assigned
	detail_title.text = str(deck.get("name", deck_key))
	detail_tagline.text = ""
	var energy_type := str(deck.get("energy_type", "Colorless"))
	detail_accent.color = DesignTokens.type_color(energy_type)
	detail_meta.text = "%s · %d 张" % [
		EnergyIconCatalog.type_display_name_for(energy_type),
		int(deck.get("card_count", 0)),
	]
	var counts := _deck_supertype_counts(deck)
	detail_counts.text = "宝可梦 %d · 训练家 %d · 能量 %d" % [
		int(counts.get("Pokémon", 0)),
		int(counts.get("Trainer", 0)),
		int(counts.get("Energy", 0)),
	]
	for card_id in DeckVisualCatalog.preview_cards(catalog, deck_key, 4):
		_add_detail_card(card_id)
	details_button.disabled = false
	details_button.accessibility_description = "查看%s的完整构成" % detail_title.text
	_refresh_detail_columns()


func _add_detail_card(card_id: String) -> void:
	var card := catalog.get_card(card_id)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(48, 67)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.theme_type_variation = &"FrontCardFrame"
	frame.tooltip_text = ""
	frame.accessibility_name = str(card.get("name", card_id))
	var image := TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var tree := Engine.get_main_loop() as SceneTree
	var texture_cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	image.texture = (
		texture_cache.call("get_texture", str(card.get("image_path", ""))) as Texture2D
		if texture_cache
		else null
	)
	frame.add_child(image)
	detail_card_grid.add_child(frame)


func _clear_detail_cards() -> void:
	for child in detail_card_grid.get_children():
		detail_card_grid.remove_child(child)
		child.queue_free()


func _deck_supertype_counts(deck: Dictionary) -> Dictionary:
	var counts := {"Pokémon": 0, "Trainer": 0, "Energy": 0}
	for row_value in deck.get("cards", []):
		var row: Dictionary = row_value
		var card := catalog.get_card(str(row.get("card_id", "")))
		var supertype := str(card.get("supertype", ""))
		counts[supertype] = int(counts.get(supertype, 0)) + int(row.get("count", 0))
	return counts


func _refresh_start_state() -> void:
	var ready := (
		catalog != null
		and not _selected_keys[0].is_empty()
		and not _selected_keys[1].is_empty()
		and not catalog.get_deck(_selected_keys[0]).is_empty()
		and not catalog.get_deck(_selected_keys[1]).is_empty()
	)
	start_button.disabled = not ready
	action_summary.text = (
		"%s  对战  %s" % [
			_deck_display_name(_selected_keys[0]),
			_deck_display_name(_selected_keys[1]),
		]
		if ready
		else "请为两个槽位选择有效牌组"
	)


func _emit_active_deck_details() -> void:
	if not _preview_deck_key.is_empty():
		deck_details_requested.emit(_preview_deck_key)


func _emit_start_requested() -> void:
	if start_button.disabled:
		return
	start_requested.emit(
		mode,
		_selected_keys[0],
		_selected_keys[1],
		-1,
		matchup_toggle.button_pressed,
	)


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var margin := UILayoutPolicy.content_margin(size, MAX_CONTENT_WIDTH, 10, 24)
	for edge in ["left", "right"]:
		content_margin.add_theme_constant_override("margin_" + edge, margin)
	content_margin.add_theme_constant_override("margin_top", UILayoutPolicy.fit_int(size, 8, 22))
	content_margin.add_theme_constant_override("margin_bottom", UILayoutPolicy.fit_int(size, 8, 20))
	page_content.add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 8, 12))
	top_bar.custom_minimum_size.y = UILayoutPolicy.fit(size, 48, 54)
	for slot_button in [player_one_slot_button, player_two_slot_button]:
		slot_button.custom_minimum_size = Vector2(0, UILayoutPolicy.fit(size, 54, 58))
		slot_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for edge in ["top", "bottom"]:
		slot_margin.add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 4, 10))
		action_margin.add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 4, 10))
	start_button.custom_minimum_size = Vector2(UILayoutPolicy.fit(size, 176, 208), 56)
	action_content.vertical = false
	slot_hint.visible = true
	heading.add_theme_font_size_override("font_size", UILayoutPolicy.fit_int(size, 26, 32))
	mode_description.max_lines_visible = 2
	mode_description.visible = false
	action_summary.visible = true
	master_detail.add_theme_constant_override("separation", UILayoutPolicy.fit_int(size, 12, 24))
	gallery_grid.columns = 2
	for tile in _tiles.values():
		tile.custom_minimum_size = Vector2(180, UILayoutPolicy.fit(size, 274, 290))
		tile.artwork_frame.custom_minimum_size.y = UILayoutPolicy.fit(size, 154, 178)
		(tile.card_count_label as Label).custom_minimum_size.x = 54
	for panel in [gallery_panel, detail_panel]:
		var inset := panel.get_child(0) as MarginContainer
		for edge in ["left", "right"]:
			inset.add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 10, 22 if panel == detail_panel else 16))
	_apply_master_detail_visibility()
	_refresh_detail_columns()


func _apply_master_detail_visibility() -> void:
	gallery_panel.visible = true
	detail_panel.visible = true
	back_to_gallery_button.visible = false


func _refresh_detail_columns() -> void:
	var margin := UILayoutPolicy.content_margin(size, MAX_CONTENT_WIDTH, 10, 24)
	var available := (size.x - margin * 2.0 - UILayoutPolicy.fit(size, 12, 24)) * 0.4
	%DetailActions.vertical = false
	for button in [assign_deck_button, details_button]:
		button.custom_minimum_size = Vector2(0, 56)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.add_theme_font_size_override("font_size", UILayoutPolicy.fit_int(size, 16, 18))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var preview_body := detail_card_grid.get_parent() as BoxContainer
	preview_body.vertical = true
	preview_body.get_node("DetailInfo/CoreLabel").visible = true
	preview_body.move_child(detail_card_grid, 1)
	detail_card_grid.columns = 4
	var card_width := clampf((available - 76.0) / 4.0, 48.0, 112.0)
	for frame: Control in detail_card_grid.get_children():
		frame.visible = true
		frame.custom_minimum_size = Vector2(card_width, card_width * 1.4)
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		frame.reset_size()
	# GridContainer can retain its previous allocation when all four columns
	# stay present. Release that width before the scrolling body is fitted again.
	detail_card_grid.reset_size()
	preview_body.reset_size()
	for edge in ["top", "bottom"]:
		detail_panel.get_node("DetailMargin").add_theme_constant_override("margin_" + edge, UILayoutPolicy.fit_int(size, 10, 18))


func _play_enter_animation() -> void:
	if not _configured or not is_instance_valid(page_content):
		return
	FRONTEND_MOTION.play_enter(page_content, 0.22)


func _deck_display_name(deck_key: String) -> String:
	if catalog == null or deck_key.is_empty():
		return "尚未选择"
	return str(catalog.get_deck(deck_key).get("name", deck_key))


func _second_slot_name() -> String:
	match mode:
		MODE_LOCAL:
			return "玩家 2"
		_:
			return "AI 对手"

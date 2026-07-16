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
const WIDE_MIN_WIDTH := 1360.0
const WIDE_MIN_ASPECT := 1.5
const MODE_LOCAL := "local"
const MODE_CHALLENGE := "challenge"
const MODE_DEEP := "deep"

var catalog: CardCatalog
var mode := MODE_LOCAL

@onready var ai_mode_option: OptionButton = %AIModeOption
@onready var first_player_option: OptionButton = %FirstPlayerOption
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
@onready var details_button: Button = %DetailsButton
@onready var action_content: BoxContainer = %ActionContent
@onready var ai_settings: GridContainer = %AISettings
@onready var ai_mode_label: Label = %AIModeLabel
@onready var matchup_toggle: CheckButton = %TypeMatchupToggle
@onready var start_button: Button = %StartButton
@onready var action_summary: Label = %ActionSummary
@onready var action_margin: MarginContainer = %ActionMargin
@onready var master_detail: HBoxContainer = %MasterDetail

var _deck_keys: Array[String] = []
var _selected_keys: Array[String] = ["", ""]
var _tiles: Dictionary = {}
var _active_player_idx := 0
var _compact := false
var _compact_detail_visible := false
var _gallery_scroll_position := 0.0
var _configured := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	call_deferred("_apply_responsive_layout")


func configure(p_catalog: CardCatalog, p_mode: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	catalog = p_catalog
	mode = p_mode if p_mode in [MODE_LOCAL, MODE_CHALLENGE, MODE_DEEP] else MODE_CHALLENGE
	_deck_keys = DeckVisualCatalog.ordered_deck_keys(catalog)
	_active_player_idx = 0
	_compact_detail_visible = false
	_populate_ai_mode_options()
	matchup_toggle.set_pressed_no_signal(false)
	_refresh_matchup_toggle_presentation()
	_refresh_mode_copy()
	_populate_gallery()
	_populate_first_player_options()
	_selected_keys = [
		_deck_keys[0] if not _deck_keys.is_empty() else "",
		_deck_keys[1] if _deck_keys.size() > 1 else (
			_deck_keys[0] if not _deck_keys.is_empty() else ""
		),
	]
	_refresh_all()
	_configured = true
	call_deferred("_apply_responsive_layout")
	call_deferred("_play_enter_animation")


func _resolve_nodes() -> void:
	ai_mode_option = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/AISettings/AIModeOption"
	) as OptionButton
	ai_mode_option.accessibility_name = "AI 类型"
	first_player_option = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/AISettings/FirstPlayerOption"
	) as OptionButton
	first_player_option.accessibility_name = "先后手设置"
	for option in [ai_mode_option, first_player_option]:
		option.get_popup().allow_search = false
	mode_description = get_node("ContentMargin/PageContent/ModeDescription") as Label
	content_margin = get_node("ContentMargin") as MarginContainer
	page_content = get_node("ContentMargin/PageContent") as VBoxContainer
	top_bar = get_node("ContentMargin/PageContent/TopBar") as HBoxContainer
	heading = get_node("ContentMargin/PageContent/TopBar/Heading") as Label
	player_one_slot_button = get_node(
		"ContentMargin/PageContent/SlotPanel/SlotMargin/Slots/PlayerOneSlotButton"
	) as Button
	player_two_slot_button = get_node(
		"ContentMargin/PageContent/SlotPanel/SlotMargin/Slots/PlayerTwoSlotButton"
	) as Button
	slot_hint = get_node(
		"ContentMargin/PageContent/SlotPanel/SlotMargin/Slots/SlotHint"
	) as Label
	slot_margin = get_node("ContentMargin/PageContent/SlotPanel/SlotMargin") as MarginContainer
	gallery_panel = get_node("ContentMargin/PageContent/MasterDetail/GalleryPanel") as PanelContainer
	gallery_scroll = get_node(
		"ContentMargin/PageContent/MasterDetail/GalleryPanel/GalleryMargin/GalleryContent/GalleryScroll"
	) as ScrollContainer
	gallery_grid = get_node(
		"ContentMargin/PageContent/MasterDetail/GalleryPanel/GalleryMargin/GalleryContent/GalleryScroll/GalleryGrid"
	) as GridContainer
	gallery_heading = get_node(
		"ContentMargin/PageContent/MasterDetail/GalleryPanel/GalleryMargin/GalleryContent/GalleryHeading"
	) as Label
	detail_panel = get_node("ContentMargin/PageContent/MasterDetail/DetailPanel") as PanelContainer
	back_to_gallery_button = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailNav/BackToGalleryButton"
	) as Button
	detail_assignment = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailNav/DetailAssignment"
	) as Label
	detail_accent = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailTitleRow/DetailAccent"
	) as ColorRect
	detail_title = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailTitleRow/DetailTitle"
	) as Label
	detail_tagline = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailTagline"
	) as Label
	detail_meta = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailMeta"
	) as Label
	detail_counts = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailCounts"
	) as Label
	detail_card_grid = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailCardGrid"
	) as GridContainer
	details_button = get_node(
		"ContentMargin/PageContent/MasterDetail/DetailPanel/DetailMargin/DetailContent/DetailsButton"
	) as Button
	action_content = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent"
	) as BoxContainer
	ai_settings = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/AISettings"
	) as GridContainer
	ai_mode_label = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/AISettings/AIModeLabel"
	) as Label
	matchup_toggle = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/TypeMatchupToggle"
	) as CheckButton
	matchup_toggle.accessibility_name = "弱点与抗性规则"
	start_button = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/StartButton"
	) as Button
	action_summary = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin/ActionContent/ActionSummary"
	) as Label
	action_margin = get_node(
		"ContentMargin/PageContent/ActionBar/ActionMargin"
	) as MarginContainer
	master_detail = get_node("ContentMargin/PageContent/MasterDetail") as HBoxContainer


func _ensure_connections() -> void:
	var back_button := get_node("ContentMargin/PageContent/TopBar/BackButton") as Button
	var back_callable := Callable(self, "_emit_back_requested")
	if not back_button.pressed.is_connected(back_callable):
		back_button.pressed.connect(back_callable)
	var player_one_callable := _set_active_player.bind(0)
	if not player_one_slot_button.pressed.is_connected(player_one_callable):
		player_one_slot_button.pressed.connect(player_one_callable)
	var player_two_callable := _set_active_player.bind(1)
	if not player_two_slot_button.pressed.is_connected(player_two_callable):
		player_two_slot_button.pressed.connect(player_two_callable)
	if not back_to_gallery_button.pressed.is_connected(_show_compact_gallery):
		back_to_gallery_button.pressed.connect(_show_compact_gallery)
	if not details_button.pressed.is_connected(_emit_active_deck_details):
		details_button.pressed.connect(_emit_active_deck_details)
	if not start_button.pressed.is_connected(_emit_start_requested):
		start_button.pressed.connect(_emit_start_requested)
	if not ai_mode_option.item_selected.is_connected(_on_ai_mode_selected):
		ai_mode_option.item_selected.connect(_on_ai_mode_selected)
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
	var state_color := DesignTokens.GREEN if enabled else DesignTokens.TEXT_MUTED
	matchup_toggle.text = "弱点/抗性：%s" % state_copy
	matchup_toggle.tooltip_text = (
		"当前已开启：攻击伤害会按中国大陆官方步骤计算弱点与抗性。点击可关闭。"
		if enabled
		else "当前已关闭（项目默认）：攻击伤害不计算弱点与抗性。点击可开启。"
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
	_refresh_all()
	return true


func deck_count() -> int:
	return _deck_keys.size()


func handle_back() -> bool:
	if _compact and _compact_detail_visible:
		_show_compact_gallery()
		return true
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


func _populate_first_player_options() -> void:
	first_player_option.clear()
	first_player_option.add_item("由硬币胜者选择")
	first_player_option.set_item_metadata(0, -1)
	first_player_option.select(0)
	first_player_option.disabled = true


func _populate_ai_mode_options() -> void:
	ai_mode_option.clear()
	ai_mode_option.add_item("Challenge AI")
	ai_mode_option.set_item_metadata(0, MODE_CHALLENGE)
	ai_mode_option.select(0)
	ai_mode_option.disabled = true


func _on_ai_mode_selected(index: int) -> void:
	if index < 0 or index >= ai_mode_option.item_count:
		return
	var selected_mode := str(ai_mode_option.get_item_metadata(index))
	if selected_mode not in [MODE_CHALLENGE, MODE_DEEP] or selected_mode == mode:
		return
	mode = selected_mode
	_refresh_mode_copy()
	_refresh_ai_slot_copy()


func _refresh_mode_copy() -> void:
	match mode:
		MODE_LOCAL:
			heading.text = "选择本地双人牌组"
			mode_description.text = (
				"为两个玩家分别挑选牌组。允许双方使用同一套牌；交接回合时会自动保护手牌隐私。"
			)
		MODE_DEEP:
			heading.text = "选择 Deep AI 牌组"
			mode_description.text = (
				"Deep AI 会在开局时加载本地模型；模型不可用时会自动回退 Challenge AI。"
			)
		_:
			heading.text = "选择 Challenge AI 牌组"
			mode_description.text = (
				"玩家固定为玩家 1，Challenge AI 为玩家 2；双方都只通过公开规则接口行动。"
			)
	player_two_slot_button.accessibility_name = "%s 牌组" % _second_slot_name()


func _refresh_ai_slot_copy() -> void:
	# Mode switching is intentionally copy-only: it must not rebuild the gallery,
	# recreate detail cards, or reset deck/turn/scroll state.
	_refresh_slot_buttons()
	_refresh_tiles()
	if first_player_option.item_count >= 3:
		first_player_option.set_item_text(2, "%s 先攻" % _second_slot_name())
	var deck_key := selected_deck_key(_active_player_idx)
	var deck := catalog.get_deck(deck_key) if catalog else {}
	if not deck.is_empty():
		detail_assignment.text = "正在配置 · %s" % (
			"玩家 1" if _active_player_idx == 0 else _second_slot_name()
		)


func _on_deck_tile_pressed(deck_key: String) -> void:
	if not select_deck(_active_player_idx, deck_key):
		return
	if _compact:
		_gallery_scroll_position = gallery_scroll.scroll_vertical
		_compact_detail_visible = true
		_apply_master_detail_visibility()


func _set_active_player(player_idx: int) -> void:
	if player_idx < 0 or player_idx > 1:
		return
	_active_player_idx = player_idx
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
	player_one_slot_button.set_pressed_no_signal(_active_player_idx == 0)
	player_two_slot_button.set_pressed_no_signal(_active_player_idx == 1)
	slot_hint.text = "正在为 %s 选择牌组" % (
		"玩家 1" if _active_player_idx == 0 else second_slot_name
	)


func _refresh_tiles() -> void:
	for tile_value in _tiles.values():
		(tile_value as DeckGalleryTile).set_assignment_state(
			_active_player_idx,
			_selected_keys,
			_second_slot_name(),
		)


func _refresh_detail() -> void:
	_clear_detail_cards()
	var deck_key := selected_deck_key(_active_player_idx)
	var deck := catalog.get_deck(deck_key) if catalog else {}
	if deck.is_empty():
		detail_assignment.text = "尚未选择牌组"
		detail_title.text = "从左侧画廊选择"
		detail_tagline.text = "选择后会在这里显示核心卡与牌组构成。"
		detail_meta.text = ""
		detail_counts.text = ""
		details_button.disabled = true
		return
	var second_slot_name := _second_slot_name()
	detail_assignment.text = "正在配置 · %s" % (
		"玩家 1" if _active_player_idx == 0 else second_slot_name
	)
	detail_title.text = str(deck.get("name", deck_key))
	detail_tagline.text = DeckVisualCatalog.tagline(deck_key)
	var energy_type := str(deck.get("energy_type", "Colorless"))
	detail_accent.color = DesignTokens.type_color(energy_type)
	detail_meta.text = "%s · %d 张 · 发布牌组" % [
		_energy_display_name(energy_type),
		int(deck.get("card_count", 0)),
	]
	var counts := _deck_supertype_counts(deck)
	detail_counts.text = "Pokémon %d　 Trainer %d　 Energy %d" % [
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
	frame.custom_minimum_size = Vector2(94, 132)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.theme_type_variation = &"FrontCardFrame"
	frame.tooltip_text = str(card.get("name", card_id))
	var image := TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture = _card_texture(str(card.get("image_path", "")))
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
	ai_settings.visible = mode != MODE_LOCAL
	action_summary.text = (
		"%s  对战  %s" % [
			_deck_display_name(_selected_keys[0]),
			_deck_display_name(_selected_keys[1]),
		]
		if ready
		else "请为两个槽位选择有效牌组"
	)


func _emit_active_deck_details() -> void:
	_emit_deck_details_for_player(_active_player_idx)


func _emit_deck_details_for_player(player_idx: int) -> void:
	var deck_key := selected_deck_key(player_idx)
	if not deck_key.is_empty():
		deck_details_requested.emit(deck_key)


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
	var was_compact := _compact
	var aspect := size.x / maxf(1.0, size.y)
	_compact = not (size.x >= WIDE_MIN_WIDTH and aspect >= WIDE_MIN_ASPECT)
	var short_landscape := size.y < 840.0
	if _compact and not was_compact:
		_compact_detail_visible = false
	var horizontal_margin := (
		maxf(24.0, (size.x - MAX_CONTENT_WIDTH) * 0.5)
		if not _compact
		else 18.0
	)
	content_margin.add_theme_constant_override("margin_left", int(horizontal_margin))
	content_margin.add_theme_constant_override("margin_right", int(horizontal_margin))
	content_margin.add_theme_constant_override(
		"margin_top", 10 if short_landscape else 16 if _compact else 22
	)
	content_margin.add_theme_constant_override(
		"margin_bottom", 10 if short_landscape else 14 if _compact else 20
	)
	page_content.add_theme_constant_override("separation", 8 if short_landscape else 12)
	top_bar.custom_minimum_size.y = 50 if short_landscape else 54
	for slot_button in [player_one_slot_button, player_two_slot_button]:
		slot_button.custom_minimum_size.y = 54 if short_landscape else 58
	for side in ["top", "bottom"]:
		slot_margin.add_theme_constant_override(
			"margin_" + side, 6 if short_landscape else 10
		)
		action_margin.add_theme_constant_override(
			"margin_" + side, 4 if short_landscape else 10
		)
	start_button.custom_minimum_size = Vector2(192, 50 if short_landscape else 54)
	var dense_action_layout := _compact and size.x < 680.0
	action_content.vertical = dense_action_layout
	ai_mode_label.visible = dense_action_layout
	ai_settings.columns = 2 if dense_action_layout else 3
	ai_mode_option.custom_minimum_size = Vector2(
		180 if dense_action_layout else 150,
		48 if short_landscape else 50,
	)
	first_player_option.custom_minimum_size = Vector2(
		180,
		48 if short_landscape else 50,
	)
	heading.add_theme_font_size_override("font_size", 26 if _compact else 32)
	mode_description.max_lines_visible = 2 if _compact else -1
	action_summary.visible = not _compact or size.x >= 900.0
	master_detail.add_theme_constant_override("separation", 24 if not _compact else 0)
	var gallery_width := maxf(300.0, size.x - horizontal_margin * 2.0 - 44.0)
	gallery_grid.columns = (
		2
		if not _compact
		else clampi(int(floor(gallery_width / 266.0)), 1, 3)
	)
	_apply_master_detail_visibility()
	_refresh_detail_columns()


func _apply_master_detail_visibility() -> void:
	gallery_panel.visible = not _compact or not _compact_detail_visible
	detail_panel.visible = not _compact or _compact_detail_visible
	back_to_gallery_button.visible = _compact
	gallery_heading.text = (
		"全部牌组 · 选择后分配给当前槽位"
		if not _compact
		else "全部牌组 · 轻触查看并分配"
	)


func _show_compact_gallery() -> void:
	_compact_detail_visible = false
	_apply_master_detail_visibility()
	call_deferred("_restore_gallery_scroll")


func _restore_gallery_scroll() -> void:
	gallery_scroll.scroll_vertical = int(_gallery_scroll_position)


func _refresh_detail_columns() -> void:
	var available := detail_panel.size.x
	if available <= 0.0:
		available = size.x * (0.42 if not _compact else 1.0)
	detail_card_grid.columns = clampi(int(floor((available - 52.0) / 108.0)), 1, 4)


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
		MODE_DEEP:
			return "Deep AI"
		_:
			return "Challenge AI"


func _energy_display_name(energy_type: String) -> String:
	return {
		"Grass": "草属性",
		"Fire": "火属性",
		"Water": "水属性",
		"Lightning": "雷属性",
		"Psychic": "超能力",
		"Fighting": "斗属性",
		"Darkness": "恶属性",
		"Metal": "钢属性",
		"Dragon": "龙属性",
		"Colorless": "无色",
	}.get(energy_type, energy_type)


func _card_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	var cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	if cache and cache.has_method("get_texture"):
		return cache.call("get_texture", path) as Texture2D
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

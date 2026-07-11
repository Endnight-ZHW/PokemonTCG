class_name UIWorkbench
extends Control

const TITLE_SCENE := preload("res://scenes/title/title_page.tscn")
const DECK_SCENE := preload("res://scenes/decks/deck_select_page.tscn")
const NETWORK_SCENE := preload("res://scenes/network/network_lobby_page.tscn")
const BATTLE_SCENE := preload("res://scenes/battle/battle_screen.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")
const SETTINGS_SCENE := preload("res://ui/dialogs/settings_panel.tscn")
const CHOICE_SCENE := preload("res://ui/dialogs/choice_panel.tscn")
const HELP_PANEL_SCENE := preload("res://ui/panels/help_panel.tscn")
const CARD_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/card_inspector_panel.tscn")
const ZONE_INSPECTOR_PANEL_SCENE := preload("res://ui/panels/zone_inspector_panel.tscn")
const DECK_DETAIL_PANEL_SCENE := preload("res://ui/panels/deck_detail_panel.tscn")
const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")

var catalog := CardCatalog.new()
var current_battle: BattleScreen
var sample_state: GameState
var event_sequence := 0

@onready var preview_host: Control = %PreviewHost
@onready var preview_caption: Label = %PreviewCaption


func _ready() -> void:
	_resolve_nodes()
	_bind_toolbar()
	show_preview("battle")


func show_preview(kind: String) -> void:
	_resolve_nodes()
	_clear_preview()
	match kind:
		"title":
			_show_title()
		"decks":
			_show_decks()
		"network":
			_show_network()
		"settings":
			_show_settings()
		"choice":
			_show_choice()
		"energy_choice":
			_show_energy_choice()
		"ai_thinking":
			_show_ai_thinking()
		"help":
			_show_help()
		"inspector":
			_show_inspector()
		"zone":
			_show_zone()
		"deck_detail":
			_show_deck_detail()
		"victory":
			_show_victory()
		_:
			_show_battle()


func trigger_presentation(kind: String) -> void:
	_resolve_nodes()
	if kind == "victory":
		show_preview("victory")
		return
	if current_battle == null or not is_instance_valid(current_battle):
		show_preview("battle")
	event_sequence += 1
	var event := _presentation_event(kind)
	current_battle.play_presentation([event], event_sequence, 0)


func _bind_toolbar() -> void:
	for button_name in [
		"TitlePreview",
		"DeckPreview",
		"NetworkPreview",
		"SettingsPreview",
		"ChoicePreview",
		"EnergyChoicePreview",
		"BattlePreview",
		"AIThinkingPreview",
		"VictoryPreview",
		"HelpPreview",
		"InspectorPreview",
		"ZonePreview",
		"DeckDetailsPreview",
	]:
		var button := get_node(
			"Layout/Sidebar/Scroll/Buttons/" + button_name
		) as Button
		var key := str(button.get_meta("preview"))
		button.pressed.connect(show_preview.bind(key))
	for button_name in [
		"DrawEvent",
		"EnergyAttachEvent",
		"EvolveEvent",
		"AttackEvent",
		"DamageEvent",
		"KOEvent",
		"VictoryEvent",
	]:
		var button := get_node(
			"Layout/Sidebar/Scroll/Buttons/" + button_name
		) as Button
		var key := str(button.get_meta("event"))
		button.pressed.connect(trigger_presentation.bind(key))


func _show_title() -> void:
	preview_caption.text = "标题页 · 可编辑文字、按钮和进入动画"
	var page := TITLE_SCENE.instantiate() as TitlePage
	preview_host.add_child(page)
	page.configure("v%s" % AppState.APP_VERSION)


func _show_decks() -> void:
	preview_caption.text = "牌组选择 · 动态数据填入静态场景"
	var page := DECK_SCENE.instantiate() as DeckSelectPage
	preview_host.add_child(page)
	page.configure(catalog, "challenge")


func _show_network() -> void:
	preview_caption.text = "网络大厅 · LAN/Relay 共用布局"
	var page := NETWORK_SCENE.instantiate() as NetworkLobbyPage
	preview_host.add_child(page)
	page.configure(catalog, "relay", "wss://relay.example.invalid")


func _show_settings() -> void:
	preview_caption.text = "设置面板 · 前台主题、分区表单与实时数值"
	var panel := _centered_panel(Vector2(700, 650), true)
	var settings := SETTINGS_SCENE.instantiate() as SettingsPanel
	panel.add_child(settings)
	settings.configure()


func _show_choice() -> void:
	preview_caption.text = "复杂选择 · 卡图网格与文本选项"
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_host.add_child(center)
	var panel_container := PanelContainer.new()
	panel_container.custom_minimum_size = Vector2(720, 560)
	center.add_child(panel_container)
	var panel := CHOICE_SCENE.instantiate() as ChoicePanel
	panel_container.add_child(panel)
	panel.configure("选择 1～2 张卡牌；此预览不会提交规则响应。", true)
	for card_id in ["sv1-151", "sv1-189", "svf-potion", "svi-jete"]:
		var card := load("res://ui/card_view.tscn").instantiate() as CardView
		card.custom_minimum_size = Vector2(86, 121)
		card.configure(card_id, null, false, -1, 0, "", true)
		panel.card_grid.add_child(card)
	for text in ["选择第一项", "选择第二项", "取消并返回"]:
		var button := Button.new()
		button.custom_minimum_size.y = 48
		button.text = text
		panel.option_list.add_child(button)


func _show_energy_choice() -> void:
	preview_caption.text = "能量分配选择 · 多张能量可重复选择同一目标"
	var center := _centered_panel(Vector2(760, 620))
	var panel := CHOICE_SCENE.instantiate() as ChoicePanel
	center.add_child(panel)
	panel.configure("请选择 2–2 项。重复点击同一目标表示多张能量分到同一处。", true)
	panel.add_child(_label("待分配能量", 18, DesignTokens.GOLD))
	var energy_grid := GridContainer.new()
	energy_grid.columns = 4
	energy_grid.add_theme_constant_override("h_separation", 8)
	panel.add_child(energy_grid)
	panel.move_child(energy_grid, 2)
	for card_id in ["sv1-ener-2", "sv1-ener-2"]:
		energy_grid.add_child(_card_thumb(card_id, false))
	for card_id in ["svi-hrot", "svi-chim", "svi-ente"]:
		var button := Button.new()
		button.custom_minimum_size.y = 48
		button.text = catalog.card_name(card_id)
		panel.option_list.add_child(button)


func _show_help() -> void:
	preview_caption.text = "帮助面板 · 四类导航与单一纵向滚动区"
	var panel := _centered_panel(Vector2(860, 650), true)
	var content := HELP_PANEL_SCENE.instantiate() as HelpPanel
	panel.add_child(content)
	content.configure()


func _show_inspector() -> void:
	preview_caption.text = "卡牌检查器 · 大图、完整卡文和附属卡"
	var panel := _centered_panel(Vector2(860, 650))
	var content := CARD_INSPECTOR_PANEL_SCENE.instantiate() as CardInspectorPanel
	panel.add_child(content)
	var pokemon := PokemonState.new("svi-hrot")
	pokemon.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2"])
	content.configure(catalog, {
		"card_id": "svi-hrot",
		"location": "加热洛托姆 · 我方战斗区",
		"pokemon": pokemon,
	})


func _show_zone() -> void:
	preview_caption.text = "区域查看 · 公开弃牌与隐藏牌库/奖品"
	var panel := _centered_panel(Vector2(820, 620))
	var content := ZONE_INSPECTOR_PANEL_SCENE.instantiate() as ZoneInspectorPanel
	panel.add_child(content)
	content.configure(catalog, {
		"hidden": false,
		"card_ids": ["sv1-180", "sv1-189", "svf-potion", "sv1-ener-2"],
		"count": 4,
	})


func _show_deck_detail() -> void:
	preview_caption.text = "牌组详情 · 核心卡与 Pokémon/Trainer/Energy 分组"
	var panel := _centered_panel(Vector2(900, 680), true)
	var content := DECK_DETAIL_PANEL_SCENE.instantiate() as DeckDetailPanel
	panel.add_child(content)
	content.configure(catalog, "fire")


func _show_battle() -> void:
	preview_caption.text = "战斗场景 · 使用左侧按钮触发演出"
	sample_state = UIPreviewStateFactory.battle_state()
	current_battle = BATTLE_SCENE.instantiate() as BattleScreen
	preview_host.add_child(current_battle)
	current_battle.initialize_ui()
	current_battle.update_view(
		sample_state,
		0,
		UIPreviewStateFactory.action_rows(sample_state),
		"pokemon:0:active",
		false,
		"preview",
	)


func _show_ai_thinking() -> void:
	preview_caption.text = "AI 思考 · 轻量状态层与对手侧牌位反馈"
	sample_state = UIPreviewStateFactory.battle_state()
	sample_state.active_player_idx = 1
	sample_state.players[1].name = "Challenge AI"
	current_battle = BATTLE_SCENE.instantiate() as BattleScreen
	preview_host.add_child(current_battle)
	current_battle.initialize_ui()
	current_battle.update_view(
		sample_state,
		0,
		[],
		"",
		true,
		"challenge",
	)


func _show_victory() -> void:
	preview_caption.text = "胜利页 · 模式、牌组与代表卡摘要"
	var victory := VICTORY_SCENE.instantiate() as VictoryScreen
	victory.configure(0, 12, "预览玩家", "svi-hrot", {
		"mode_label": "Challenge AI",
		"winner_deck_name": "烈焰猴",
		"winner_card_name": catalog.card_name("svi-hrot"),
	})
	preview_host.add_child(victory)


func _presentation_event(kind: String) -> Dictionary:
	var base := {
		"event_id": "workbench:%d" % event_sequence,
		"actor": 0,
		"visibility": "public",
	}
	match kind:
		"draw":
			base.merge({
				"event_type": "cards_drawn",
				"card_id": "sv1-151",
				"source": {"player": 0, "zone": "deck"},
				"target": {"player": 0, "zone": "hand"},
				"amount": 1,
				"data": {"player": 0, "count": 1, "card_ids": ["sv1-151"]},
			})
		"attach_energy":
			base.merge({
				"event_type": "energy_attached",
				"card_id": "sv1-ener-2",
				"source": {"player": 0, "zone": "hand", "index": 0},
				"target": {"player": 0, "slot": "active"},
				"data": {
					"player": 0,
					"slot": "active",
					"card_id": "sv1-ener-2",
					"source_zone": "hand",
					"source_index": 0,
				},
			})
		"evolve":
			base.merge({
				"event_type": "pokemon_evolved",
				"card_id": "svi-infr",
				"source": {"player": 0, "zone": "hand"},
				"target": {"player": 0, "slot": "active"},
			})
		"attack":
			base.merge({
				"event_type": "attack_declared",
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 1, "slot": "active"},
			})
		"ko":
			base.merge({
				"event_type": "pokemon_ko",
				"card_id": "sv2-keldeo",
				"source": {"player": 1, "slot": "active"},
				"target": {"player": 1, "zone": "discard"},
			})
		_:
			base.merge({
				"event_type": "damage_dealt",
				"source": {"player": 0, "slot": "active"},
				"target": {"player": 1, "slot": "active"},
				"amount": 90,
			})
	return base


func _centered_panel(min_size: Vector2, frontend_surface: bool = false) -> Container:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_host.add_child(center)
	var panel := PanelContainer.new()
	var available := preview_host.size
	if available.x <= 0.0 or available.y <= 0.0:
		available = Vector2(1280, 720)
	panel.custom_minimum_size = Vector2(
		minf(min_size.x, maxf(320.0, available.x - 32.0)),
		minf(min_size.y, maxf(320.0, available.y - 32.0)),
	)
	if frontend_surface:
		panel.theme = FRONTEND_THEME
	center.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)
	return content


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


func _card_thumb(card_id: String, hidden: bool) -> CardView:
	var card := load("res://ui/card_view.tscn").instantiate() as CardView
	card.custom_minimum_size = Vector2(76, 107)
	card.configure(card_id, null, hidden, -1, -1, "", true)
	card.tooltip_text = "隐藏卡牌" if hidden else catalog.card_name(card_id)
	return card


func _card_image(card_id: String, min_size: Vector2) -> TextureRect:
	var image := TextureRect.new()
	image.custom_minimum_size = min_size
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture = CardTextureCache.get_texture(str(catalog.get_card(card_id).get("image_path", "")))
	return image


func _clear_preview() -> void:
	current_battle = null
	for child in preview_host.get_children():
		preview_host.remove_child(child)
		child.queue_free()


func _resolve_nodes() -> void:
	preview_host = get_node("Layout/PreviewColumn/PreviewHost") as Control
	preview_caption = get_node("Layout/PreviewColumn/PreviewCaption") as Label

class_name UIWorkbench
extends Control

const TITLE_SCENE := preload("res://scenes/title/title_page.tscn")
const DECK_SCENE := preload("res://scenes/decks/deck_select_page.tscn")
const NETWORK_SCENE := preload("res://scenes/network/network_lobby_page.tscn")
const BATTLE_SCENE := preload("res://scenes/battle/battle_screen.tscn")
const VICTORY_SCENE := preload("res://scenes/end/victory_screen.tscn")
const SETTINGS_SCENE := preload("res://ui/dialogs/settings_panel.tscn")
const CHOICE_SCENE := preload("res://ui/dialogs/choice_panel.tscn")

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
	page.configure("Workbench Preview · Rules v3 · Protocol v3")


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
	preview_caption.text = "设置面板 · Inspector 可调的静态表单"
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_host.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(700, 650)
	center.add_child(panel)
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
	preview_caption.text = "帮助面板 · 标题和暂停菜单共用的只读内容"
	var panel := _centered_panel(Vector2(760, 620))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)
	content.add_child(_label("规则与操作帮助", 26, DesignTokens.GOLD))
	for row in [
		"准备阶段放置基础宝可梦。主要阶段打出卡牌、附能、进化和撤退。",
		"长按卡牌打开完整检查器。弃牌和竞技场可以查看公开卡。",
		"牌库与奖品只显示数量，联网视角不会暴露隐藏身份。",
	]:
		content.add_child(_label("· " + row, 16, DesignTokens.TEXT))


func _show_inspector() -> void:
	preview_caption.text = "卡牌检查器 · 大图、完整卡文和附属卡"
	var panel := _centered_panel(Vector2(860, 650))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)
	content.add_child(_label("加热洛托姆 · 我方战斗区", 24, DesignTokens.GOLD))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	content.add_child(row)
	row.add_child(_card_image("svi-hrot", Vector2(210, 294)))
	var details := RichTextLabel.new()
	details.custom_minimum_size = Vector2(520, 294)
	details.fit_content = true
	details.bbcode_enabled = true
	details.text = "[color=#9eb0ca]Pokémon · Basic[/color]\n\nHP 90/90 · 附着能量 2\n\n[color=#f4c84a]高温冲撞 · 100[/color]\n造成伤害后自身受到40点伤害。"
	row.add_child(details)
	content.add_child(_label("附着能量", 18, DesignTokens.GOLD))
	var grid := GridContainer.new()
	grid.columns = 6
	content.add_child(grid)
	for card_id in ["sv1-ener-2", "sv1-ener-2"]:
		grid.add_child(_card_thumb(card_id, false))


func _show_zone() -> void:
	preview_caption.text = "区域查看 · 公开弃牌与隐藏牌库/奖品"
	var panel := _centered_panel(Vector2(820, 620))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)
	content.add_child(_label("弃牌区 · 公开卡牌", 24, DesignTokens.GOLD))
	var discard_grid := GridContainer.new()
	discard_grid.columns = 6
	content.add_child(discard_grid)
	for card_id in ["sv1-180", "sv1-189", "svf-potion", "sv1-ener-2"]:
		discard_grid.add_child(_card_thumb(card_id, false))
	content.add_child(_label("牌库 · 隐藏区域，只显示数量", 20, DesignTokens.GOLD))
	var hidden_grid := GridContainer.new()
	hidden_grid.columns = 8
	content.add_child(hidden_grid)
	for _index in range(8):
		hidden_grid.add_child(_card_thumb("", true))


func _show_deck_detail() -> void:
	preview_caption.text = "牌组详情 · 60 张构成与核心宝可梦"
	var deck := catalog.get_deck("fire")
	var panel := _centered_panel(Vector2(860, 650))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	panel.add_child(content)
	content.add_child(_label("%s · fire" % deck.get("name", "烈焰猴"), 24, DesignTokens.GOLD))
	content.add_child(_label("Fire · 60 张 · Pokémon/Trainer/Energy 构成", 16, DesignTokens.TEXT_MUTED))
	var grid := GridContainer.new()
	grid.columns = 6
	content.add_child(grid)
	for card_id in ["svi-infr", "svi-chim", "svi-monf", "svi-ente", "svi-hrot", "svi-chiy"]:
		grid.add_child(_card_thumb(card_id, false))
	for row_value in deck.get("cards", []).slice(0, 12):
		var row: Dictionary = row_value
		content.add_child(_label("%d × %s" % [
			int(row.get("count", 0)),
			catalog.card_name(str(row.get("card_id", ""))),
		], 14, DesignTokens.TEXT))


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


func _show_victory() -> void:
	preview_caption.text = "胜利页 · 彩带与 AnimationPlayer 入场"
	var victory := VICTORY_SCENE.instantiate() as VictoryScreen
	victory.configure(0, 12, "预览玩家", "svi-hrot")
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


func _centered_panel(min_size: Vector2) -> PanelContainer:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_host.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = min_size
	center.add_child(panel)
	return panel


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

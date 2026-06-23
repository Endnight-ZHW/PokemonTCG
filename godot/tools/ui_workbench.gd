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
		"BattlePreview",
		"VictoryPreview",
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


func _clear_preview() -> void:
	current_battle = null
	for child in preview_host.get_children():
		preview_host.remove_child(child)
		child.queue_free()


func _resolve_nodes() -> void:
	preview_host = get_node("Layout/PreviewColumn/PreviewHost") as Control
	preview_caption = get_node("Layout/PreviewColumn/PreviewCaption") as Label

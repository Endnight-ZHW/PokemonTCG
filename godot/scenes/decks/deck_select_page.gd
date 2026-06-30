class_name DeckSelectPage
extends Control

signal back_requested
signal deck_details_requested(deck_key: String)
signal start_requested(
	mode: String,
	first_deck_key: String,
	second_deck_key: String,
	forced_first_player: int,
)

var catalog: CardCatalog
var mode := "local"

@onready var deck_one_option: OptionButton = %DeckOneOption
@onready var deck_two_option: OptionButton = %DeckTwoOption
@onready var first_player_option: OptionButton = %FirstPlayerOption
@onready var mode_description: Label = %ModeDescription


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func configure(p_catalog: CardCatalog, p_mode: String) -> void:
	_resolve_nodes()
	_ensure_connections()
	catalog = p_catalog
	mode = p_mode
	(get_node("Root/TopBar/Heading") as Label).text = (
		"选择本地双人牌组"
		if mode == "local"
		else "选择 Challenge AI 牌组"
		if mode == "challenge"
		else "选择 Deep AI 牌组"
	)
	mode_description.text = (
		"热座模式：回合交接时会遮挡手牌。双方都使用 Godot 原生规则引擎。"
		if mode == "local"
		else "玩家固定为玩家 1，AI 为玩家 2；AI 只能通过公开信息和正常规则接口行动。"
	)
	(get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckTwoPanel/Margin/Content/DeckTwoTitle"
	) as Label).text = "玩家 2" if mode == "local" else "AI"
	(get_node(
		"Root/Center/MainPanel/Margin/Content/AISettings"
	) as HBoxContainer).visible = mode != "local"
	_populate_decks(deck_one_option)
	_populate_decks(deck_two_option)
	if deck_two_option.item_count > 1:
		deck_two_option.select(1)
	_populate_ai_options()
	_refresh_preview(deck_one_option, get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckOnePanel/Margin/Content/DeckOnePreview"
	) as HBoxContainer)
	_refresh_preview(deck_two_option, get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckTwoPanel/Margin/Content/DeckTwoPreview"
	) as HBoxContainer)
	if not AppSettings.reduced_motion:
		(get_node("AnimationPlayer") as AnimationPlayer).play("enter")


func _resolve_nodes() -> void:
	deck_one_option = get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckOnePanel/Margin/Content/DeckOneOption"
	) as OptionButton
	deck_two_option = get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckTwoPanel/Margin/Content/DeckTwoOption"
	) as OptionButton
	first_player_option = get_node(
		"Root/Center/MainPanel/Margin/Content/AISettings/FirstPlayerOption"
	) as OptionButton
	mode_description = get_node(
		"Root/Center/MainPanel/Margin/Content/ModeDescription"
	) as Label


func _ensure_connections() -> void:
	var back_button := get_node("Root/TopBar/BackButton") as Button
	var start_button := get_node(
		"Root/Center/MainPanel/Margin/Content/StartButton"
	) as Button
	if not back_button.pressed.is_connected(back_requested.emit):
		back_button.pressed.connect(back_requested.emit)
	if not start_button.pressed.is_connected(_emit_start_requested):
		start_button.pressed.connect(_emit_start_requested)
	if not deck_one_option.item_selected.is_connected(_on_deck_one_selected):
		deck_one_option.item_selected.connect(_on_deck_one_selected)
	if not deck_two_option.item_selected.is_connected(_on_deck_two_selected):
		deck_two_option.item_selected.connect(_on_deck_two_selected)
	var deck_one_details := get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckOnePanel/Margin/Content/DeckOneDetailsButton"
	) as Button
	var deck_two_details := get_node(
		"Root/Center/MainPanel/Margin/Content/Columns/DeckTwoPanel/Margin/Content/DeckTwoDetailsButton"
	) as Button
	if not deck_one_details.pressed.is_connected(_emit_deck_one_details):
		deck_one_details.pressed.connect(_emit_deck_one_details)
	if not deck_two_details.pressed.is_connected(_emit_deck_two_details):
		deck_two_details.pressed.connect(_emit_deck_two_details)


func _on_deck_one_selected(_index: int) -> void:
	_refresh_preview(
		deck_one_option,
		get_node(
			"Root/Center/MainPanel/Margin/Content/Columns/DeckOnePanel/Margin/Content/DeckOnePreview"
		) as HBoxContainer,
	)


func _on_deck_two_selected(_index: int) -> void:
	_refresh_preview(
		deck_two_option,
		get_node(
			"Root/Center/MainPanel/Margin/Content/Columns/DeckTwoPanel/Margin/Content/DeckTwoPreview"
		) as HBoxContainer,
	)


func _emit_deck_one_details() -> void:
	if deck_one_option.item_count == 0:
		return
	deck_details_requested.emit(str(deck_one_option.get_item_metadata(deck_one_option.selected)))


func _emit_deck_two_details() -> void:
	if deck_two_option.item_count == 0:
		return
	deck_details_requested.emit(str(deck_two_option.get_item_metadata(deck_two_option.selected)))


func _populate_decks(option: OptionButton) -> void:
	option.clear()
	var deck_keys: Array = catalog.decks.keys()
	deck_keys.sort()
	for key_value in deck_keys:
		var key := str(key_value)
		var deck := catalog.get_deck(key)
		option.add_item("%s · %s" % [
			deck.get("name", key),
			deck.get("energy_type", ""),
		])
		option.set_item_metadata(option.item_count - 1, key)


func _populate_ai_options() -> void:
	first_player_option.clear()
	for row in [["先后手随机", -1], ["玩家 1 先攻", 0], ["AI 先攻", 1]]:
		first_player_option.add_item(row[0])
		first_player_option.set_item_metadata(first_player_option.item_count - 1, row[1])


func _refresh_preview(option: OptionButton, preview: HBoxContainer) -> void:
	if catalog == null or option.item_count == 0:
		return
	for child in preview.get_children():
		child.queue_free()
	var deck_key := str(option.get_item_metadata(option.selected))
	var deck := catalog.get_deck(deck_key)
	var shown := 0
	for row_value in deck.get("cards", []):
		if shown >= 4:
			break
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var card := catalog.get_card(card_id)
		if str(card.get("supertype", "")) != "Pokémon":
			continue
		var image := TextureRect.new()
		image.custom_minimum_size = Vector2(72, 101)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
		image.tooltip_text = str(card.get("name", card_id))
		preview.add_child(image)
		shown += 1


func _emit_start_requested() -> void:
	if deck_one_option.item_count == 0 or deck_two_option.item_count == 0:
		return
	var forced_first := -1
	if mode != "local":
		forced_first = int(
			first_player_option.get_item_metadata(first_player_option.selected)
		)
	start_requested.emit(
		mode,
		str(deck_one_option.get_item_metadata(deck_one_option.selected)),
		str(deck_two_option.get_item_metadata(deck_two_option.selected)),
		forced_first,
	)

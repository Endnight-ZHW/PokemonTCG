class_name DeckDetailPanel
extends VBoxContainer

signal card_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")

var catalog: CardCatalog


func configure(p_catalog: CardCatalog, deck_key: String) -> bool:
	catalog = p_catalog
	_clear_children()
	add_theme_constant_override("separation", 10)
	var deck := catalog.get_deck(deck_key)
	if deck.is_empty():
		add_child(_label("找不到牌组：%s" % deck_key, 16, DesignTokens.TEXT_MUTED))
		return false
	var rows: Array = deck.get("cards", [])
	var counts := {"Pokémon": 0, "Trainer": 0, "Energy": 0}
	var core_cards: Array[String] = []
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var count := int(row.get("count", 0))
		var card := catalog.get_card(card_id)
		var supertype := str(card.get("supertype", ""))
		counts[supertype] = int(counts.get(supertype, 0)) + count
		if supertype == "Pokémon" and core_cards.size() < 6:
			core_cards.append(card_id)
	add_child(_label(
		"牌组 key：%s · 属性：%s · 共 %d 张" % [
			deck_key,
			str(deck.get("energy_type", "")),
			int(deck.get("card_count", 0)),
		],
		16,
		DesignTokens.TEXT_MUTED,
	))
	add_child(_label(
		"Pokémon %d · Trainer %d · Energy %d" % [
			int(counts.get("Pokémon", 0)),
			int(counts.get("Trainer", 0)),
			int(counts.get("Energy", 0)),
		],
		17,
		DesignTokens.GOLD,
	))
	_add_card_grid_section("核心宝可梦预览", core_cards)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	add_child(_label("完整构成", 20, DesignTokens.GOLD))
	add_child(list)
	for row_value in rows:
		var row: Dictionary = row_value
		var card_id := str(row.get("card_id", ""))
		var card := catalog.get_card(card_id)
		var label := _label(
			"%2d × %s  [%s]" % [
				int(row.get("count", 0)),
				str(card.get("name", card_id)),
				card_id,
			],
			14,
			DesignTokens.TEXT,
		)
		list.add_child(label)
	return true


func _add_card_grid_section(title_text: String, card_ids: Array[String]) -> void:
	add_child(_label(title_text, 20, DesignTokens.GOLD))
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)
	for card_id in card_ids:
		var card_view := CARD_SCENE.instantiate() as CardView
		card_view.custom_minimum_size = Vector2(82, 116)
		card_view.configure(card_id, null, false, -1, -1, "", true)
		card_view.tooltip_text = catalog.card_name(card_id)
		card_view.activated.connect(func(
			_selected_id: String,
			_hand_index: int,
			_player: int,
			_slot: String,
		) -> void:
			card_requested.emit({"card_id": card_id, "location": title_text})
		)
		grid.add_child(card_view)


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

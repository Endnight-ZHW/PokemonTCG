class_name ZoneInspectorPanel
extends VBoxContainer

signal card_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")

var catalog: CardCatalog


func configure(p_catalog: CardCatalog, context: Dictionary) -> void:
	catalog = p_catalog
	_clear_children()
	add_theme_constant_override("separation", 12)
	var is_hidden_zone := bool(context.get("hidden", false))
	var count := int(context.get("count", 0))
	if is_hidden_zone:
		add_child(_label(
			"这是隐藏区域。这里只显示数量，不显示具体卡牌身份。",
			16,
			DesignTokens.TEXT_MUTED,
		))
		_add_card_grid_section("隐藏卡牌（%d）" % count, _hidden_card_rows(count), true)
		return
	var card_ids: Array[String] = []
	for value in context.get("card_ids", []):
		var card_id := str(value)
		if not card_id.is_empty():
			card_ids.append(card_id)
	if card_ids.is_empty():
		add_child(_label("这里没有公开卡牌。", 16, DesignTokens.TEXT_MUTED))
	else:
		_add_card_grid_section("公开卡牌（%d）" % card_ids.size(), card_ids, false)


func _add_card_grid_section(
	title_text: String,
	card_ids: Array,
	is_hidden: bool,
) -> void:
	add_child(_label(title_text, 20, DesignTokens.GOLD))
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)
	if card_ids.is_empty():
		grid.add_child(_label("无", 14, DesignTokens.TEXT_MUTED))
		return
	for value in card_ids:
		var card_id := str(value)
		var card_view := CARD_SCENE.instantiate() as CardView
		card_view.custom_minimum_size = Vector2(82, 116)
		card_view.configure(card_id, null, is_hidden, -1, -1, "", true)
		card_view.tooltip_text = ""
		if not is_hidden and not card_id.is_empty():
			card_view.activated.connect(func(
				_selected_id: String,
				_hand_index: int,
				_player: int,
				_slot: String,
			) -> void:
				card_requested.emit({"card_id": card_id, "location": title_text})
			)
		grid.add_child(card_view)


func _hidden_card_rows(count: int) -> Array[String]:
	var result: Array[String] = []
	for _index in range(mini(maxi(0, count), 24)):
		result.append("")
	return result


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

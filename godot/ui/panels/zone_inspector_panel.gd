class_name ZoneInspectorPanel
extends VBoxContainer

signal card_requested(context: Dictionary)

const CARD_GRID_SECTION := preload("res://ui/panels/card_grid_section.tscn")

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
	var section := CARD_GRID_SECTION.instantiate() as CardGridSection
	section.configure(catalog, title_text, card_ids, is_hidden)
	section.card_requested.connect(card_requested.emit)
	add_child(section)


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

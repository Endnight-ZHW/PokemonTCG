class_name CardGridSection
extends VBoxContainer

signal card_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")

var catalog: CardCatalog
var title_text := ""


func configure(
	p_catalog: CardCatalog,
	p_title: String,
	card_ids: Array,
	is_hidden: bool,
) -> void:
	catalog = p_catalog
	title_text = p_title
	_clear_children()
	add_theme_constant_override("separation", 8)
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
		card_view.set_catalog(catalog)
		card_view.configure(card_id, null, is_hidden, -1, -1, "", true)
		card_view.tooltip_text = ""
		if not is_hidden and not card_id.is_empty():
			card_view.activated.connect(_on_card_activated.bind(card_id))
		grid.add_child(card_view)


func _on_card_activated(
	_selected_id: String,
	_hand_index: int,
	_player: int,
	_slot: String,
	card_id: String,
) -> void:
	card_requested.emit({"card_id": card_id, "location": title_text})


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

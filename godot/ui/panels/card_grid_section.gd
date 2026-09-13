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
	add_child(DesignTokens.label(title_text, 20, FrontendPalette.GOLD))
	var grid := HFlowContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	add_child(grid)
	if card_ids.is_empty():
		grid.add_child(DesignTokens.label("无", 16, FrontendPalette.MUTED))
		return
	for value in card_ids:
		var card_id := str(value)
		var card_view := CARD_SCENE.instantiate() as CardView
		card_view.custom_minimum_size = Vector2(112, 156)
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


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

class_name ChoicePanel
extends VBoxContainer

signal option_toggled(option_id: String)

const CARD_SCENE := preload("res://ui/card_view.tscn")
const CARD_TILE_SIZE := Vector2(112, 172)
const CHOICE_CARD_SIZE := Vector2(92, 130)
const ENERGY_CARD_SIZE := Vector2(54, 76)

@onready var metadata_label: Label = %MetadataLabel
@onready var empty_label: Label = %EmptyLabel
@onready var energy_preview: VBoxContainer = %EnergyPreview
@onready var energy_grid: HFlowContainer = %EnergyGrid
@onready var card_grid: GridContainer = %CardGrid
@onready var option_list: VBoxContainer = %OptionList

var _option_cards: Dictionary = {}
var _option_badges: Dictionary = {}
var _option_buttons: Dictionary = {}
var _selection_counts: Dictionary = {}


func configure(metadata_text: String, has_options: bool) -> void:
	_resolve_nodes()
	clear_options()
	metadata_label.text = metadata_text
	metadata_label.visible = not metadata_text.is_empty()
	empty_label.visible = not has_options
	card_grid.visible = false
	option_list.visible = false
	energy_preview.visible = false


func clear_options() -> void:
	_resolve_nodes()
	_clear_children(card_grid)
	_clear_children(option_list)
	_clear_children(energy_grid)
	_option_cards.clear()
	_option_badges.clear()
	_option_buttons.clear()
	_selection_counts.clear()


func add_card_option(
	option_id: String,
	card_id: String,
	caption_text: String,
	player: int,
) -> CardView:
	_resolve_nodes()
	card_grid.visible = true
	var tile := PanelContainer.new()
	tile.name = "CardChoiceTile"
	tile.custom_minimum_size = CARD_TILE_SIZE
	tile.mouse_filter = Control.MOUSE_FILTER_STOP
	tile.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.06, 0.11, 0.18, 0.82),
			DesignTokens.RADIUS_SMALL,
			DesignTokens.BORDER_SOFT,
			1,
			6,
		),
	)
	tile.gui_input.connect(_on_tile_gui_input.bind(option_id, tile))

	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 6)
	tile.add_child(content)

	var card_area := Control.new()
	card_area.custom_minimum_size = CHOICE_CARD_SIZE
	card_area.mouse_filter = Control.MOUSE_FILTER_PASS
	content.add_child(card_area)

	var card_view := CARD_SCENE.instantiate() as CardView
	card_view.custom_minimum_size = CHOICE_CARD_SIZE
	card_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	card_view.configure(card_id, null, false, -1, player, "", true)
	card_view.tooltip_text = caption_text if not caption_text.is_empty() else card_id
	card_view.activated.connect(func(
		_card_id: String,
		_hand_index: int,
		_owner: int,
		_slot: String,
	) -> void:
		option_toggled.emit(option_id)
	)
	card_area.add_child(card_view)

	var badge := Label.new()
	badge.visible = false
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.text = "0"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", Color("#07101d"))
	badge.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			DesignTokens.GOLD,
			8,
			Color("#fff2a6"),
			1,
			2,
		),
	)
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -30
	badge.offset_top = 3
	badge.offset_right = -3
	badge.offset_bottom = 25
	card_area.add_child(badge)

	var caption := Label.new()
	caption.custom_minimum_size = Vector2(CARD_TILE_SIZE.x - 10.0, 26.0)
	caption.mouse_filter = Control.MOUSE_FILTER_PASS
	caption.text = caption_text
	caption.tooltip_text = caption_text
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_theme_font_size_override("font_size", 12)
	caption.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	content.add_child(caption)

	card_grid.add_child(tile)
	_option_cards[option_id] = card_view
	_option_badges[option_id] = badge
	_selection_counts[option_id] = 0
	return card_view


func add_text_option(option_id: String, label_text: String) -> Button:
	_resolve_nodes()
	option_list.visible = true
	var button := Button.new()
	button.text = label_text
	button.custom_minimum_size.y = DesignTokens.TOUCH_MIN
	button.focus_mode = Control.FOCUS_ALL
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.set_meta("option_id", option_id)
	button.set_meta("base_text", label_text)
	button.pressed.connect(func() -> void:
		option_toggled.emit(option_id)
	)
	_option_buttons[option_id] = button
	_selection_counts[option_id] = 0
	option_list.add_child(button)
	return button


func add_energy_preview(card_ids: Array[String], catalog: CardCatalog) -> void:
	_resolve_nodes()
	if card_ids.is_empty():
		energy_preview.visible = false
		return
	energy_preview.visible = true
	_clear_children(energy_grid)
	for card_id in card_ids:
		var card := CARD_SCENE.instantiate() as CardView
		card.custom_minimum_size = ENERGY_CARD_SIZE
		card.configure(card_id, null, false, -1, -1, "", true)
		card.tooltip_text = catalog.card_name(card_id)
		energy_grid.add_child(card)


func refresh_selection(
	selected_ids: Array[String],
	_max_select: int,
	allow_duplicates: bool,
) -> void:
	var counts := {}
	for option_id in selected_ids:
		var key := str(option_id)
		counts[key] = int(counts.get(key, 0)) + 1
	for option_id in _option_cards.keys():
		var count := int(counts.get(option_id, 0))
		_selection_counts[option_id] = count
		var card_view := _option_cards[option_id] as CardView
		if card_view:
			card_view.set_selected(count > 0)
		var badge := _option_badges[option_id] as Label
		if badge:
			badge.visible = count > 0 and (allow_duplicates or count > 1)
			badge.text = str(count)
	for option_id in _option_buttons.keys():
		var count := int(counts.get(option_id, 0))
		_selection_counts[option_id] = count
		var button := _option_buttons[option_id] as Button
		if button == null:
			continue
		var base_text := str(button.get_meta("base_text", button.text))
		button.text = "%s  ×%d" % [base_text, count] if count > 0 else base_text
		if count > 0:
			button.add_theme_stylebox_override(
				"normal",
				GameUITheme.panel_style(
					Color("#29435a"),
					8,
					GameUITheme.COLOR_ACCENT,
					2,
				),
			)
		else:
			button.remove_theme_stylebox_override("normal")


func card_option_count() -> int:
	return _option_cards.size()


func text_option_count() -> int:
	return _option_buttons.size()


func selected_count_for(option_id: String) -> int:
	return int(_selection_counts.get(option_id, 0))


func _resolve_nodes() -> void:
	metadata_label = get_node("MetadataLabel") as Label
	empty_label = get_node("EmptyLabel") as Label
	energy_preview = get_node("EnergyPreview") as VBoxContainer
	energy_grid = get_node("EnergyPreview/EnergyGrid") as HFlowContainer
	card_grid = get_node("CardGrid") as GridContainer
	option_list = get_node("OptionList") as VBoxContainer


func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		child.queue_free()


func _on_tile_gui_input(event: InputEvent, option_id: String, tile: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			option_toggled.emit(option_id)
		tile.accept_event()

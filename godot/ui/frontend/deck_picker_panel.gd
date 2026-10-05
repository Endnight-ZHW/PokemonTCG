class_name DeckPickerPanel
extends VBoxContainer

signal deck_selected(deck_key: String)

const TILE := preload("res://ui/frontend/deck_gallery_tile.tscn")
var grid: GridContainer

func configure(catalog: CardCatalog, selected_key: String) -> void:
	grid = GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	add_child(grid)
	for key in DeckVisualCatalog.ordered_deck_keys(catalog):
		var tile := TILE.instantiate() as DeckGalleryTile
		tile.custom_minimum_size = Vector2(180, 324)
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(tile)
		tile.configure(catalog, key, DeckVisualCatalog.representative_card(catalog, key))
		tile.set_assignment_state([selected_key], "")
		tile.set_pressed_no_signal(key == selected_key)
		tile.pressed.connect(deck_selected.emit.bind(key))
	resized.connect(_layout)
	_layout()

func _layout() -> void:
	grid.columns = 4 if size.x >= 1040 else 3 if size.x >= 660 else 2

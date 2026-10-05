class_name FrontendCardTile
extends Button

## Artwork and count have separate layout space: neither text nor badges cover art.
func configure(catalog: CardCatalog, card_id: String, count: int) -> void:
	custom_minimum_size = Vector2(130, 246)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	theme_type_variation = &"DeckGalleryTileButton"
	accessibility_name = "%s，%d 张" % [catalog.card_name(card_id), count]
	tooltip_text = catalog.card_name(card_id)
	var body := VBoxContainer.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(body)
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 10
	body.offset_right = -10
	body.offset_top = 10
	body.offset_bottom = -10
	body.add_theme_constant_override("separation", 8)
	var art := TextureRect.new()
	art.custom_minimum_size.y = 178
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.texture = FrontendAttributes.card_texture(catalog, card_id)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	body.add_child(art)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(row)
	var caption := Label.new()
	caption.text = catalog.card_name(card_id)
	caption.add_theme_font_size_override("font_size", 15)
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(caption)
	var badge := Label.new()
	badge.text = "×%d" % count
	badge.add_theme_font_size_override("font_size", 16)
	badge.add_theme_color_override("font_color", FrontendPalette.GOLD)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badge)

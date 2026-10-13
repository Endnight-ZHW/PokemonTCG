class_name FrontendCardTile
extends Button

## Artwork and count have separate layout space: neither text nor badges cover art.
var _count_badge: Label
var _card_name := ""
var _art: TextureRect

func configure(catalog: CardCatalog, card_id: String, count: int, show_printing: bool = false) -> void:
	custom_minimum_size = Vector2(130, 246)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	theme_type_variation = &"DeckGalleryTileButton"
	_card_name = catalog.card_name(card_id)
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
	_art = art
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
	_count_badge = badge
	set_count(count)
	if show_printing:
		var printing := Label.new()
		printing.text = printing_caption(catalog.get_card(card_id))
		printing.add_theme_font_size_override("font_size", 13)
		printing.add_theme_color_override("font_color", FrontendPalette.MUTED)
		printing.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		printing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		body.add_child(printing)
		custom_minimum_size.y += 22
		tooltip_text += "\n" + printing.text

func set_count(count: int) -> void:
	accessibility_name = "%s，%d 张" % [_card_name, count]
	if _count_badge:
		_count_badge.text = "×%d" % count
		_count_badge.add_theme_color_override("font_color", FrontendPalette.GOLD if count > 0 else FrontendPalette.MUTED)

func set_tile_height(height: float) -> void:
	custom_minimum_size.y = height
	if _art: _art.custom_minimum_size.y = minf(178, maxf(72, height - 92))

static func printing_caption(card: Dictionary) -> String:
	var parts: PackedStringArray = []
	var printing := "%s %s" % [card.get("set_id", ""), card.get("number", "")]
	if not printing.strip_edges().is_empty(): parts.append(printing.strip_edges())
	var rarity := str(card.get("rarity", ""))
	if not rarity.is_empty(): parts.append(rarity)
	return " · ".join(parts)

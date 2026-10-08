class_name CardInspectorPanel
extends VBoxContainer

signal card_requested(context: Dictionary)
signal art_requested

var catalog: CardCatalog
var rule_scroll: ScrollContainer
var rule_contents: VBoxContainer
var attachment_buttons: Array[Button] = []
var _content_grid: GridContainer
var _art_column: VBoxContainer
var _image_button: Button
var _zoom_button: Button
var _content := CardDetailContent.new()
var _generation := 0
var _reading_revision := 0
var _identity := ""


func _ready() -> void:
	SurfacePalette.apply(self)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	resized.connect(_apply_responsive_layout)


func configure(p_catalog: CardCatalog, context: Dictionary) -> void:
	var card_id := str(context.get("card_id", ""))
	var pokemon := context.get("pokemon") as PokemonState
	var instance_key := str(context.get("instance_key", ""))
	if instance_key.is_empty() and str(context.get("slot", "")).is_empty() and not context.has("hand_index") and pokemon != null:
		instance_key = str(pokemon.get_instance_id())
	var identity := "%s|%s|%s|%s|%s" % [card_id, context.get("player", ""), context.get("slot", ""), context.get("hand_index", ""), instance_key]
	var saved := get_reading_position() if identity == _identity else 0
	_identity = identity
	_generation += 1
	catalog = p_catalog
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_content_grid = null
	_image_button = null
	rule_scroll = null
	attachment_buttons.clear()
	_content.configure(self, catalog)
	add_theme_constant_override("separation", 12)
	if card_id.is_empty():
		add_child(_content.paragraph("没有可查看的卡牌。", 18, _content.muted))
		return
	var card := catalog.get_card(card_id)
	var location := str(context.get("location", ""))
	var heading := _content.hbox(10)
	heading.name = "FixedCardTitle"
	var titles := _content.vbox(2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(titles)
	titles.add_child(_content.paragraph("卡牌详情" + ("  /  " + location if not location.is_empty() else ""), 13, _content.muted))
	titles.add_child(_content.paragraph(str(card.get("name", card_id)), 28, _content.ink, true))
	var badge := _content.badge("对战中" if context.get("pokemon") != null else "卡面规则", _content.green)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heading.add_child(badge)
	add_child(heading)
	add_child(_content.separator())
	_content_grid = GridContainer.new()
	_content_grid.name = "TwoColumns"
	_content_grid.columns = 2
	_content_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_grid.add_theme_constant_override("h_separation", 28)
	_content_grid.resized.connect(_apply_responsive_layout)
	add_child(_content_grid)
	_art_column = _content.vbox(12)
	_art_column.name = "FixedArtwork"
	_content_grid.add_child(_art_column)
	_image_button = _content.button("")
	_image_button.name = "CardArtwork"
	_image_button.custom_minimum_size = Vector2(120, 168)
	_image_button.expand_icon = true
	_image_button.icon = FrontendAttributes.card_texture(catalog, card_id)
	DesignTokens.preserve_art_icon(_image_button)
	_image_button.add_theme_stylebox_override("normal", _content.style(SurfacePalette.for_control(self).INSET, 12, _content.line, 1, 6))
	_image_button.accessibility_name = "放大查看%s卡图" % str(card.get("name", card_id))
	_image_button.pressed.connect(art_requested.emit)
	_art_column.add_child(_image_button)
	if _image_button.icon == null:
		var missing := _content.label("暂无卡图", 18, _content.muted)
		missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_image_button.add_child(missing)
		missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_zoom_button = _content.button("放大卡图  ↗")
	_zoom_button.name = "ZoomArtwork"
	_zoom_button.pressed.connect(art_requested.emit)
	_art_column.add_child(_zoom_button)
	var printing := _content.label(str(card.get("number", "")), 13, _content.muted)
	printing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_art_column.add_child(printing)
	var reading := _content.reading_pane()
	rule_scroll = reading.scroll
	rule_contents = reading.contents
	_content_grid.add_child(rule_scroll)
	rule_contents.add_child(_content.identity_row(card))
	var evolution := str(card.get("evolves_from", ""))
	if not evolution.is_empty():
		rule_contents.add_child(_content.paragraph("进化自  " + evolution, 15, _content.muted))
	_content.add_rules(rule_contents, card, false)
	if pokemon != null:
		rule_contents.add_child(_content.state_block(pokemon))
		_content.add_attachments(rule_contents, pokemon)
	attachment_buttons.assign(_content.attachment_buttons)
	for button in attachment_buttons:
		button.pressed.connect(func() -> void:
			card_requested.emit({"card_id": str(button.get_meta("card_id")), "location": "附着卡／进化链"}))
	rule_contents.accessibility_description = CardPresentation.accessibility_text(card, catalog, pokemon)
	add_child(_content.separator())
	_apply_responsive_layout.call_deferred()
	restore_reading_position(saved)


func get_reading_position() -> int:
	return rule_scroll.scroll_vertical if is_instance_valid(rule_scroll) else 0


func restore_reading_position(value: int) -> void:
	var generation := _generation
	_reading_revision += 1
	var revision := _reading_revision
	for frame in 3:
		await get_tree().process_frame
		if generation != _generation or revision != _reading_revision or not is_instance_valid(rule_scroll):
			return
		rule_scroll.scroll_vertical = maxi(0, value)


func _apply_responsive_layout() -> void:
	if not is_instance_valid(_content_grid) or not is_inside_tree():
		return
	var width := maxf(1.0, size.x)
	var reading_height := maxf(1.0, _content_grid.size.y)
	var image_width := minf(300.0, width * 0.32)
	image_width = minf(image_width, maxf(60.0, reading_height - 100.0) * 300.0 / 419.0)
	_image_button.custom_minimum_size = Vector2(image_width, image_width * 419.0 / 300.0 + 12.0)
	_art_column.custom_minimum_size.x = image_width
	_content_grid.add_theme_constant_override("h_separation", 18 if width < 760 else 28)

class_name CardInspectorPanel
extends VBoxContainer

signal card_requested(context: Dictionary)
signal art_requested

const CARD_GRID_SECTION := preload("res://ui/panels/card_grid_section.tscn")

var catalog: CardCatalog
var _content_grid: GridContainer
var _image_button: Button
var _detail_text: RichTextLabel


func _ready() -> void:
	SurfacePalette.apply(self)
	resized.connect(_apply_responsive_layout)
	var window := get_window()
	if window and not window.size_changed.is_connected(_apply_responsive_layout):
		window.size_changed.connect(_apply_responsive_layout)


func configure(p_catalog: CardCatalog, context: Dictionary) -> void:
	catalog = p_catalog
	_clear_children()
	add_theme_constant_override("separation", 12)
	var card_id := str(context.get("card_id", ""))
	if card_id.is_empty():
		add_child(DesignTokens.label("没有可查看的卡牌。", 16, SurfacePalette.for_control(self).MUTED))
		return
	var card := catalog.get_card(card_id)
	var location := str(context.get("location", ""))
	if not location.is_empty():
		add_child(DesignTokens.label(location, 16, SurfacePalette.for_control(self).MUTED))
	_content_grid = GridContainer.new()
	_content_grid.columns = 2
	_content_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_grid.add_theme_constant_override("h_separation", 18)
	_content_grid.add_theme_constant_override("v_separation", 14)
	add_child(_content_grid)
	_image_button = Button.new()
	_image_button.custom_minimum_size = Vector2(260, 363)
	_image_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_image_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_image_button.focus_mode = Control.FOCUS_NONE
	_image_button.flat = true
	_image_button.expand_icon = true
	_image_button.icon = _texture_for_path(str(card.get("image_path", "")))
	DesignTokens.preserve_art_icon(_image_button)
	_image_button.tooltip_text = ""
	_image_button.accessibility_name = "放大查看%s卡图" % str(card.get("name", card_id))
	_image_button.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(SurfacePalette.for_control(self).INSET, 6, SurfacePalette.for_control(self).BORDER, 1, 0),
	)
	_image_button.add_theme_stylebox_override(
		"hover",
		DesignTokens.panel_style(SurfacePalette.for_control(self).RAISED, 6, SurfacePalette.for_control(self).GOLD, 2, 0),
	)
	_image_button.pressed.connect(art_requested.emit)
	_content_grid.add_child(_image_button)
	if SurfacePalette.is_frontend(self):
		_style_frontend_art_button()
	var detail := RichTextLabel.new()
	_detail_text = detail
	detail.custom_minimum_size = Vector2.ZERO
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The modal owns scrolling for card text, evolution and attachments together.
	detail.fit_content = true
	detail.scroll_active = false
	detail.mouse_filter = Control.MOUSE_FILTER_PASS
	detail.bbcode_enabled = true
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.text = DesignTokens.rich_text("[color=#{muted}]%s[/color]\n\n%s") % [
		CardPresentation.meta_text(card),
		_card_detail_bbcode(card_id, context.get("pokemon") as PokemonState),
	]
	detail.text = SurfacePalette.format_card_text(self, detail.text)
	detail.tooltip_text = ""
	detail.accessibility_description = CardPresentation.accessibility_text(
		card,
		catalog,
		context.get("pokemon") as PokemonState,
	)
	_content_grid.add_child(detail)
	var pokemon := context.get("pokemon") as PokemonState
	if pokemon:
		_add_card_grid_section("进化链", _pokemon_evolution_cards(pokemon), false)
		_add_card_grid_section("附着能量", pokemon.energy_card_ids, false)
		if not pokemon.attached_tool_id.is_empty():
			_add_card_grid_section("宝可梦道具", [pokemon.attached_tool_id], false)
	call_deferred("_apply_responsive_layout")


func _apply_responsive_layout() -> void:
	if _content_grid == null or not is_instance_valid(_content_grid):
		return
	if not is_inside_tree():
		return
	var tree := get_tree()
	if tree == null or tree.root == null:
		return
	var available_width := size.x
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer and (ancestor as ScrollContainer).size.x > 1.0:
			available_width = (ancestor as ScrollContainer).size.x - 14.0
			break
		ancestor = ancestor.get_parent()
	_content_grid.columns = 2
	var image_width := clampf(available_width * 0.34, 120.0, 260.0)
	if _image_button:
		_image_button.custom_minimum_size = Vector2(image_width, image_width * 1.4 + (36 if SurfacePalette.is_frontend(self) else 0))
	if _detail_text:
		_detail_text.add_theme_font_size_override("normal_font_size", 18)


func _style_frontend_art_button() -> void:
	_image_button.flat = false
	_image_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in [&"normal", &"hover", &"pressed", &"hover_pressed"]:
		var normal: bool = state == &"normal"
		var fill := Color.WHITE if normal else Color("f9ece8")
		var style := FrontendPalette.panel(fill, 8, FrontendPalette.CONTROL_BORDER if normal else FrontendPalette.GOLD, 2, 6)
		style.content_margin_bottom = 36
		_image_button.add_theme_stylebox_override(state, style)
	var footer := HBoxContainer.new()
	footer.name = "ArtZoomHint"
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 6)
	_image_button.add_child(footer)
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_top = -32
	footer.offset_bottom = -4
	var icon := TextureRect.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(18, 18)
	icon.texture = preload("res://assets/ui/frontend/magnify.svg")
	icon.self_modulate = FrontendPalette.TEXT
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	footer.add_child(icon)
	var caption := Label.new()
	caption.text = "放大卡图"
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.add_theme_font_size_override("font_size", 16)
	caption.add_theme_color_override("font_color", FrontendPalette.TEXT)
	footer.add_child(caption)


func _add_card_grid_section(
	title_text: String,
	card_ids: Array,
	is_hidden: bool,
) -> void:
	var section := CARD_GRID_SECTION.instantiate() as CardGridSection
	add_child(section)
	section.configure(catalog, title_text, card_ids, is_hidden)
	section.card_requested.connect(card_requested.emit)


func _pokemon_evolution_cards(pokemon: PokemonState) -> Array[String]:
	var result: Array[String] = []
	for value in pokemon.evolution_stack_ids:
		var card_id := str(value)
		if not card_id.is_empty():
			result.append(card_id)
	if not pokemon.card_id.is_empty():
		result.append(pokemon.card_id)
	return result


func _card_detail_bbcode(card_id: String, pokemon: PokemonState = null) -> String:
	var card := catalog.get_card(card_id)
	return CardPresentation.detail_bbcode(
		card,
		catalog,
		pokemon,
		CardPresentation.DetailLevel.FULL,
	)


func _texture_for_path(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	var texture_cache := (
		tree.root.get_node_or_null("CardTextureCache")
		if tree and tree.root
		else null
	)
	if texture_cache and texture_cache.has_method("get_texture"):
		return texture_cache.call("get_texture", path) as Texture2D
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_content_grid = null
	_image_button = null
	_detail_text = null

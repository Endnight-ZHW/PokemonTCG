class_name CardInspectorPanel
extends VBoxContainer

signal card_requested(context: Dictionary)

const CARD_SCENE := preload("res://ui/card_view.tscn")

var catalog: CardCatalog
var _content_grid: GridContainer
var _image_button: Button
var _detail_text: RichTextLabel


func _ready() -> void:
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
		add_child(_label("没有可查看的卡牌。", 16, DesignTokens.TEXT_MUTED))
		return
	var card := catalog.get_card(card_id)
	var location := str(context.get("location", ""))
	if not location.is_empty():
		add_child(_label(location, 15, DesignTokens.TEXT_MUTED))
	_content_grid = GridContainer.new()
	_content_grid.columns = 2
	_content_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_grid.add_theme_constant_override("h_separation", 18)
	_content_grid.add_theme_constant_override("v_separation", 14)
	add_child(_content_grid)
	_image_button = Button.new()
	_image_button.custom_minimum_size = Vector2(260, 363)
	_image_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_image_button.focus_mode = Control.FOCUS_NONE
	_image_button.flat = true
	_image_button.expand_icon = true
	_image_button.icon = _texture_for_path(str(card.get("image_path", "")))
	_image_button.tooltip_text = ""
	_image_button.accessibility_name = "放大查看%s卡图" % str(card.get("name", card_id))
	_image_button.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(Color("#0e1b2c"), 6, DesignTokens.BORDER, 1, 0),
	)
	_image_button.add_theme_stylebox_override(
		"hover",
		DesignTokens.panel_style(Color("#132740"), 6, DesignTokens.CYAN, 2, 0),
	)
	_image_button.pressed.connect(_show_art_zoom.bind(card))
	_content_grid.add_child(_image_button)
	var detail := RichTextLabel.new()
	_detail_text = detail
	detail.custom_minimum_size = Vector2(500, 363)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.fit_content = true
	detail.bbcode_enabled = true
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.text = "[color=#9eb0ca]%s[/color]\n\n%s" % [
		CardPresentation.meta_text(card),
		_card_detail_bbcode(card_id, context.get("pokemon") as PokemonState),
	]
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
	var compact_layout := tree.root.size.x <= 900 or (size.x > 0.0 and size.x < 720.0)
	_content_grid.columns = 1 if compact_layout else 2
	if _image_button:
		_image_button.custom_minimum_size = (
			Vector2(180, 251) if compact_layout else Vector2(260, 363)
		)
	if _detail_text:
		_detail_text.custom_minimum_size = (
			Vector2(0, 280) if compact_layout else Vector2(500, 363)
		)


func _show_art_zoom(card: Dictionary) -> void:
	var texture := _texture_for_path(str(card.get("image_path", "")))
	if texture == null:
		return
	var viewport_size := get_viewport_rect().size
	var available := Vector2(
		maxf(180.0, viewport_size.x - 64.0),
		maxf(251.0, viewport_size.y - 118.0),
	)
	var image_size := Vector2(300.0, 419.0)
	var scale_factor := minf(
		1.0,
		minf(available.x / image_size.x, available.y / image_size.y),
	)
	image_size *= scale_factor
	var popup := PopupPanel.new()
	popup.name = "CardArtZoom"
	popup.exclusive = true
	popup.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(Color("#081321"), 12, DesignTokens.CYAN, 1, 12),
	)
	add_child(popup)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	popup.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var title := Label.new()
	title.text = str(card.get("name", "卡牌原图"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", DesignTokens.GOLD)
	column.add_child(title)
	var image := TextureRect.new()
	image.custom_minimum_size = image_size
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	column.add_child(image)
	var close_button := Button.new()
	close_button.custom_minimum_size = Vector2(0, 48)
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.text = "关闭原图"
	close_button.accessibility_name = "关闭卡牌原图"
	close_button.pressed.connect(popup.hide)
	column.add_child(close_button)
	popup.popup_hide.connect(popup.queue_free)
	popup.popup_centered_clamped(Vector2i(image_size + Vector2(36, 104)), 0.92)


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


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return label


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

class_name BattleDetailPanel
extends PanelContainer

signal close_requested
signal height_changed

var detail_image: TextureRect
var detail_title: Label
var detail_meta: Label
var close_button: Button
var hp_group: HBoxContainer
var type_icons: HBoxContainer
var rule_scroll: ScrollContainer
var rule_contents: VBoxContainer
var header: VBoxContainer
var current_card_id := ""
var current_context: Dictionary = {}
var expanded := false
var _catalog: CardCatalog
var _card: Dictionary = {}
var _pokemon: PokemonState
var _identity := ""
var _content := CardDetailContent.new()
var _column: VBoxContainer
var _available := Vector2(420, 340)
var _narrow := false
var _generation := 0
var _layout_revision := 0
var _visibility_tween: Tween


func _ready() -> void:
	set_meta("ui_surface", ModalSpec.Surface.BATTLE)
	SurfacePalette.apply(self)
	_content.configure(self, CardCatalog.shared())
	var panel_style := _content.style(_content.paper, 14, _content.line, 1, 12)
	panel_style.shadow_color = Color(0.14, 0.12, 0.10, 0.13)
	panel_style.shadow_size = 10
	add_theme_stylebox_override("panel", panel_style)
	clear()


func show_card(card_id: String, pokemon: PokemonState = null, context: Variant = {}) -> void:
	if card_id.is_empty():
		clear()
		return
	var normalized: Dictionary = context if context is Dictionary else {}
	_catalog = context as CardCatalog if context is CardCatalog else normalized.get("catalog") as CardCatalog
	if _catalog == null:
		_catalog = CardCatalog.shared()
	_card = Dictionary(normalized.get("card_data", {}))
	if _card.is_empty():
		_card = _catalog.get_card(card_id)
	if _card.is_empty():
		clear()
		return
	var identity := "%s|%s" % [card_id, normalized.get("instance_key", pokemon.get_instance_id() if pokemon != null else "")]
	var saved := get_reading_position() if identity == _identity else 0
	var was_visible := visible
	_identity = identity
	current_card_id = card_id
	current_context = normalized.duplicate(true)
	_pokemon = pokemon
	_rebuild(saved)
	show()
	if not was_visible:
		_play_present_motion()


func _rebuild(saved: int) -> void:
	_generation += 1
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_content.configure(self, _catalog)
	_column = _content.vbox(8)
	_column.name = "Content"
	add_child(_column)
	header = _content.vbox(4)
	header.name = "FixedIdentityAndHP"
	_column.add_child(header)
	var headline := _content.hbox(6 if _narrow else 10)
	header.add_child(headline)
	detail_title = _content.paragraph(str(_card.get("name", current_card_id)), 17 if _narrow else 19, _content.ink, true)
	detail_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	headline.add_child(detail_title)
	hp_group = _content.hbox(3 if _narrow else 4)
	hp_group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	headline.add_child(hp_group)
	if int(_card.get("hp", 0)) > 0:
		hp_group.add_child(_content.label("HP", 11 if _narrow else 12, _content.muted))
		if _pokemon != null:
			var state := CardPresentation.battle_state(_pokemon, _catalog, int(_card.hp))
			hp_group.add_child(_content.label(str(state.current_hp), 18 if _narrow else 22, _content.green, true))
			hp_group.add_child(_content.label("/ %d" % int(state.maximum_hp), 12 if _narrow else 14, _content.muted))
		else:
			hp_group.add_child(_content.label(str(int(_card.hp)), 18 if _narrow else 22, _content.ink, true))
	type_icons = _content.attribute_icons(_card, 18 if _narrow else 24)
	hp_group.add_child(type_icons)
	close_button = _content.button("×")
	close_button.name = "CloseSidebar"
	close_button.custom_minimum_size = Vector2(48, 48)
	close_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close_button.accessibility_name = "关闭卡牌预览"
	close_button.pressed.connect(_on_close_pressed)
	if not _narrow:
		headline.add_child(close_button)
	var context_row := _content.hbox(8)
	header.add_child(context_row)
	detail_image = _content.texture(FrontendAttributes.card_texture(_catalog, current_card_id), Vector2(36, 50))
	detail_image.accessibility_name = str(_card.get("name", current_card_id))
	context_row.add_child(detail_image)
	var identity := _content.vbox(3)
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	context_row.add_child(identity)
	var metadata := _card.duplicate()
	metadata.erase("energy_types")
	detail_meta = _content.paragraph(_content.compact_meta(metadata), 12, _content.muted)
	identity.add_child(detail_meta)
	if _pokemon != null:
		var status := _content.status_text(_pokemon)
		if not status.is_empty():
			identity.add_child(_content.paragraph(status, 12, DesignTokens.RED, true))
	if _narrow:
		context_row.add_child(close_button)
	_column.add_child(_content.separator())
	var reading := _content.reading_pane()
	rule_scroll = reading.scroll
	rule_contents = reading.contents
	rule_contents.add_theme_constant_override("separation", 10 if expanded else 12)
	_column.add_child(rule_scroll)
	_content.add_rules(rule_contents, _card, true)
	if _pokemon != null:
		_content.add_attachment_summary(rule_contents, _pokemon)
	rule_contents.accessibility_description = CardPresentation.accessibility_text(_card, _catalog, _pokemon)
	_settle_layout(saved)


func fit_available_size(available: Vector2, expand_content := false) -> void:
	var previous := _available
	_available = available
	var rebuild := _narrow != (available.x < 280.0) or expanded != expand_content
	_narrow = available.x < 280.0
	expanded = expand_content
	if rebuild and not current_card_id.is_empty():
		_rebuild(get_reading_position())
	if is_instance_valid(_column):
		_column.add_theme_constant_override("separation", 4 if available.y < 220.0 else 8)
	custom_minimum_size = Vector2(available.x, 0)
	_measure_height()
	if not previous.is_equal_approx(available) and not rebuild:
		_settle_layout(get_reading_position())


func _measure_height() -> void:
	var height := _available.y
	if expanded and is_instance_valid(rule_contents) and is_instance_valid(header):
		var padding := get_theme_stylebox("panel").get_minimum_size().y
		var required := padding + header.get_combined_minimum_size().y + 18.0 + rule_contents.get_combined_minimum_size().y
		height = minf(_available.y, ceilf(maxf(340.0, required) / 4.0) * 4.0)
	size = Vector2(_available.x, height)


func _settle_layout(saved: int) -> void:
	var generation := _generation
	_layout_revision += 1
	var revision := _layout_revision
	for frame in 4:
		await get_tree().process_frame
		if generation != _generation or revision != _layout_revision or not is_instance_valid(rule_scroll):
			return
		_measure_height()
		rule_scroll.scroll_vertical = maxi(0, saved)
	height_changed.emit()


func get_reading_position() -> int:
	return rule_scroll.scroll_vertical if is_instance_valid(rule_scroll) else 0


func restore_reading_position(value: int) -> void:
	_settle_layout(value)


func clear() -> void:
	_generation += 1
	_kill_visibility_tween()
	modulate.a = 1.0
	current_card_id = ""
	current_context.clear()
	_identity = ""
	_card = {}
	_pokemon = null
	hide()
	if is_instance_valid(rule_scroll):
		rule_scroll.scroll_vertical = 0


func hide_card() -> void:
	clear()


func is_showing_card() -> bool:
	return visible and not current_card_id.is_empty()


func _on_close_pressed() -> void:
	clear()
	close_requested.emit()


func _play_present_motion() -> void:
	_kill_visibility_tween()
	var duration := MotionPolicy.duration("panel")
	if duration <= 0.0 or MotionPolicy.reduced():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	_visibility_tween = create_tween()
	_visibility_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_visibility_tween.tween_property(self, "modulate:a", 1.0, duration)
	_visibility_tween.finished.connect(func() -> void: _visibility_tween = null)


func _kill_visibility_tween() -> void:
	if _visibility_tween and _visibility_tween.is_valid():
		_visibility_tween.kill()
	_visibility_tween = null

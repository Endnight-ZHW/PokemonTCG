class_name CardReadingPane
extends VBoxContainer

## Embedded, read-only card details. Switching between art and rules never
## replaces the owning choice workspace or changes its selection/draft.
var rule_scroll: ScrollContainer
var rule_contents: VBoxContainer
var art_button: Button
var art_image: TextureRect
var title_label: Label
var hp_group: HBoxContainer
var art_return_button: Button
var art_view: VBoxContainer
var large_art: TextureRect
var card_id := ""
var showing_art := false
var _card: Dictionary = {}
var _content := CardDetailContent.new()
var _title_row: HBoxContainer
var _stats_row: HBoxContainer
var _meta_label: Label
var _hint_label: Label
var _missing_label: Label
var _rules_position := 0
var _generation := 0


func _ready() -> void:
	SurfacePalette.apply(self)
	_content.configure(self, CardCatalog.shared())
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)
	var header := _content.hbox(10)
	header.name = "FixedCardIdentity"
	add_child(header)
	art_button = _content.button("")
	art_button.name = "PreviewArtwork"
	art_button.custom_minimum_size = Vector2(56, 78)
	art_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	art_button.tooltip_text = "查看卡图"
	art_button.pressed.connect(show_art)
	header.add_child(art_button)
	art_image = _content.texture(null, Vector2.ZERO)
	art_button.add_child(art_image)
	art_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art_image.offset_left = 3
	art_image.offset_top = 3
	art_image.offset_right = -3
	art_image.offset_bottom = -3
	_missing_label = _content.label("暂无\n卡图", 12, _content.muted)
	_missing_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_missing_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	art_button.add_child(_missing_label)
	_missing_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var summary := _content.vbox(3)
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(summary)
	_title_row = _content.hbox(8)
	summary.add_child(_title_row)
	title_label = _content.paragraph("卡牌说明", 19, _content.ink, true)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_row.add_child(title_label)
	hp_group = _content.hbox(4)
	hp_group.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title_row.add_child(hp_group)
	_stats_row = _content.hbox(4)
	summary.add_child(_stats_row)
	_meta_label = _content.paragraph("", 13, _content.muted)
	summary.add_child(_meta_label)
	_hint_label = _content.label("点击小图查看卡图 ↗", 12, _content.muted)
	summary.add_child(_hint_label)
	add_child(_content.separator())
	var reading := _content.reading_pane()
	rule_scroll = reading.scroll
	rule_contents = reading.contents
	rule_contents.add_theme_constant_override("separation", 12)
	add_child(rule_scroll)
	art_view = _content.vbox(8)
	art_view.name = "ArtworkView"
	art_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art_view.hide()
	add_child(art_view)
	art_return_button = _content.button("← 返回卡牌说明")
	art_return_button.pressed.connect(show_rules)
	art_view.add_child(art_return_button)
	large_art = _content.texture(null, Vector2.ZERO)
	large_art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art_view.add_child(large_art)
	resized.connect(_fit_header)
	clear()


func show_card(p_catalog: CardCatalog, id: String) -> void:
	var catalog := p_catalog if p_catalog != null else CardCatalog.shared()
	var card := catalog.get_card(id)
	if id == card_id and _card == card:
		return
	var changed := id != card_id
	var saved := 0 if changed else get_reading_position()
	_generation += 1
	card_id = id
	_card = card
	_content.configure(self, catalog)
	_clear_children(hp_group)
	hp_group.accessibility_name = ""
	hp_group.tooltip_text = ""
	_clear_children(rule_contents)
	title_label.text = str(card.get("name", "卡牌资料暂不可用"))
	art_image.texture = FrontendAttributes.card_texture(catalog, id)
	large_art.texture = art_image.texture
	art_button.disabled = art_image.texture == null
	_missing_label.visible = art_button.disabled
	_hint_label.visible = not art_button.disabled
	art_button.accessibility_name = "查看%s卡图" % title_label.text
	large_art.accessibility_name = title_label.text
	if int(card.get("hp", 0)) > 0:
		hp_group.add_child(_content.label("HP", 11, _content.muted))
		hp_group.add_child(_content.label(str(int(card.hp)), 20, _content.ink, true))
		hp_group.tooltip_text = "卡面 HP"
		hp_group.accessibility_name = "卡面 HP %d" % int(card.hp)
		hp_group.add_child(_content.attribute_icons(card, 20))
	var metadata := card.duplicate()
	metadata.erase("energy_types")
	_meta_label.text = _content.compact_meta(metadata)
	if card.is_empty():
		rule_contents.add_child(_content.paragraph("暂时无法读取这张卡牌的图片和效果说明。", 16, _content.muted))
	else:
		var evolution := str(card.get("evolves_from", ""))
		if not evolution.is_empty():
			rule_contents.add_child(_content.paragraph("进化自  " + evolution, 13, _content.muted))
		_content.add_rules(rule_contents, card, true)
	rule_contents.accessibility_description = CardPresentation.accessibility_text(card, catalog)
	if changed:
		showing_art = false
		art_view.hide()
		rule_scroll.show()
	_rules_position = saved
	_restore_scroll(saved, _generation)
	_fit_header()


func clear() -> void:
	_generation += 1
	card_id = ""
	_card = {}
	_rules_position = 0
	showing_art = false
	if not is_instance_valid(rule_contents): return
	_clear_children(rule_contents)
	_clear_children(hp_group)
	rule_contents.accessibility_description = ""
	hp_group.accessibility_name = ""
	hp_group.tooltip_text = ""
	title_label.text = "卡牌说明"
	_meta_label.text = ""
	art_image.texture = null
	large_art.texture = null
	_missing_label.show()
	_hint_label.hide()
	art_button.disabled = true
	art_view.hide()
	rule_scroll.show()
	rule_scroll.scroll_vertical = 0
	rule_contents.add_child(_content.paragraph("选择卡牌查看效果。", 16, _content.muted))


func show_art() -> void:
	if art_image.texture == null or showing_art: return
	_rules_position = rule_scroll.scroll_vertical
	showing_art = true
	rule_scroll.hide()
	art_view.show()


func show_rules() -> void:
	if not showing_art: return
	showing_art = false
	art_view.hide()
	rule_scroll.show()
	_restore_scroll(_rules_position, _generation)


func handle_back() -> bool:
	if not showing_art: return false
	show_rules()
	return true


func get_reading_position() -> int:
	return _rules_position if showing_art else rule_scroll.scroll_vertical


func _restore_scroll(value: int, generation: int) -> void:
	if not is_inside_tree(): return
	for frame in 3:
		await get_tree().process_frame
		if not is_inside_tree() or generation != _generation or showing_art: return
		rule_scroll.scroll_vertical = maxi(0, value)


func _fit_header() -> void:
	if not is_instance_valid(hp_group): return
	var narrow := size.x < 340.0
	var target: Node = _stats_row if narrow else _title_row
	if hp_group.get_parent() != target:
		hp_group.reparent(target)
	_stats_row.visible = narrow and hp_group.get_child_count() > 0
	var short := size.y < 240.0
	art_button.custom_minimum_size = Vector2(48, 67) if short else Vector2(56, 78)
	_hint_label.visible = not short and art_image.texture != null


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

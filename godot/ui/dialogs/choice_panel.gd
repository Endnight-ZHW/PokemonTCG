class_name ChoicePanel
extends VBoxContainer

signal option_toggled(option_id: String)
signal energy_index_requested(index: int)
signal undo_requested
signal clear_requested

const CARD_SCENE := preload("res://ui/card_view.tscn")
const CARD_TILE_SIZE := Vector2(112, 172)
const CHOICE_CARD_SIZE := Vector2(92, 130)
const ENERGY_CARD_SIZE := Vector2(54, 76)

@onready var metadata_label: Label = %MetadataLabel
@onready var empty_label: Label = %EmptyLabel
@onready var energy_preview: VBoxContainer = %EnergyPreview
@onready var energy_preview_label: Label = %EnergyPreviewLabel
@onready var energy_grid: HFlowContainer = %EnergyGrid
@onready var energy_actions: HBoxContainer = %EnergyActions
@onready var card_grid: GridContainer = %CardGrid
@onready var option_list: VBoxContainer = %OptionList
@onready var preview_panel: PanelContainer = %PreviewPanel
@onready var preview_image: TextureRect = %PreviewImage
@onready var preview_title: Label = %PreviewTitle
@onready var preview_text: RichTextLabel = %PreviewText

var catalog: CardCatalog
var _option_cards: Dictionary = {}
var _option_badges: Dictionary = {}
var _option_buttons: Dictionary = {}
var _option_card_ids: Dictionary = {}
var _option_labels: Dictionary = {}
var _selection_counts: Dictionary = {}
var _energy_preview_cards: Array[CardView] = []
var _energy_assignment_labels: Array[Label] = []
var _energy_distribution_mode := false
var _previewed_card_id := ""


func configure(
	metadata_text: String,
	has_options: bool,
	p_catalog: CardCatalog = null,
) -> void:
	_resolve_nodes()
	catalog = p_catalog
	clear_options()
	_configure_preview_panel()
	metadata_label.text = metadata_text
	metadata_label.visible = not metadata_text.is_empty()
	empty_label.visible = not has_options
	card_grid.visible = false
	option_list.visible = false
	energy_preview.visible = false
	_hide_preview()


func clear_options() -> void:
	_resolve_nodes()
	_clear_children(card_grid)
	_clear_children(option_list)
	_clear_children(energy_grid)
	_option_cards.clear()
	_option_badges.clear()
	_option_buttons.clear()
	_option_card_ids.clear()
	_option_labels.clear()
	_selection_counts.clear()
	_energy_preview_cards.clear()
	_energy_assignment_labels.clear()
	_energy_distribution_mode = false
	_hide_preview()


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
	card_view.focus_entered.connect(_preview_card.bind(card_id))
	card_view.detail_requested.connect(func(_card_id: String) -> void:
		_preview_card(card_id)
	)
	card_view.activated.connect(func(
		_card_id: String,
		_hand_index: int,
		_owner: int,
		_slot: String,
	) -> void:
		_preview_card(card_id)
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
	_option_card_ids[option_id] = card_id
	_option_labels[option_id] = caption_text if not caption_text.is_empty() else _card_name(card_id)
	_selection_counts[option_id] = 0
	if _previewed_card_id.is_empty():
		_preview_card(card_id)
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
	_option_labels[option_id] = label_text
	_selection_counts[option_id] = 0
	option_list.add_child(button)
	return button


func add_energy_preview(card_ids: Array[String], catalog: CardCatalog) -> void:
	_add_preview_cards(card_ids, catalog, "待分配能量", true)


func add_revealed_cards(
	card_ids: Array[String],
	catalog: CardCatalog,
	label_text: String = "已查看卡牌",
) -> void:
	_add_preview_cards(card_ids, catalog, label_text, false)


func _add_preview_cards(
	card_ids: Array[String],
	catalog: CardCatalog,
	label_text: String,
	interactive_distribution: bool,
) -> void:
	_resolve_nodes()
	if self.catalog == null and catalog != null:
		self.catalog = catalog
	if card_ids.is_empty():
		energy_preview.visible = false
		return
	energy_preview.visible = true
	energy_preview_label.text = label_text
	energy_actions.visible = interactive_distribution
	_energy_distribution_mode = interactive_distribution
	_clear_children(energy_grid)
	_energy_preview_cards.clear()
	_energy_assignment_labels.clear()
	for index in range(card_ids.size()):
		var preview_index := index
		var card_id := card_ids[index]
		var preview_card_id := card_id
		var tile := VBoxContainer.new()
		tile.mouse_filter = Control.MOUSE_FILTER_PASS
		tile.alignment = BoxContainer.ALIGNMENT_CENTER
		tile.add_theme_constant_override("separation", 3)
		var card := CARD_SCENE.instantiate() as CardView
		card.custom_minimum_size = ENERGY_CARD_SIZE
		card.configure(card_id, null, false, -1, -1, "", true)
		card.tooltip_text = _card_name(card_id)
		card.focus_entered.connect(_preview_card.bind(preview_card_id))
		card.detail_requested.connect(func(_card_id: String) -> void:
			_preview_card(preview_card_id)
		)
		card.activated.connect(func(
			_card_id: String,
			_hand_index: int,
			_owner: int,
			_slot: String,
		) -> void:
			_preview_card(preview_card_id)
			if interactive_distribution:
				energy_index_requested.emit(preview_index)
		)
		tile.add_child(card)
		_energy_preview_cards.append(card)
		var assignment := Label.new()
		assignment.custom_minimum_size = Vector2(76, 18)
		assignment.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		assignment.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		assignment.tooltip_text = "尚未分配"
		assignment.add_theme_font_size_override("font_size", 10)
		assignment.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
		assignment.text = "待分配"
		assignment.visible = interactive_distribution
		tile.add_child(assignment)
		_energy_assignment_labels.append(assignment)
		energy_grid.add_child(tile)
	if _previewed_card_id.is_empty() and not card_ids.is_empty():
		_preview_card(str(card_ids[0]))


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
	_refresh_energy_assignment_labels(selected_ids)


func card_option_count() -> int:
	return _option_cards.size()


func text_option_count() -> int:
	return _option_buttons.size()


func selected_count_for(option_id: String) -> int:
	return int(_selection_counts.get(option_id, 0))


func previewed_card_id() -> String:
	return _previewed_card_id


func is_preview_visible() -> bool:
	return preview_panel != null and preview_panel.visible


func _resolve_nodes() -> void:
	metadata_label = get_node("MetadataLabel") as Label
	empty_label = get_node("EmptyLabel") as Label
	energy_preview = get_node("ContentRow/ChoiceColumn/EnergyPreview") as VBoxContainer
	energy_preview_label = get_node(
		"ContentRow/ChoiceColumn/EnergyPreview/EnergyPreviewLabel"
	) as Label
	energy_grid = get_node(
		"ContentRow/ChoiceColumn/EnergyPreview/EnergyGrid"
	) as HFlowContainer
	energy_actions = get_node(
		"ContentRow/ChoiceColumn/EnergyPreview/EnergyActions"
	) as HBoxContainer
	card_grid = get_node("ContentRow/ChoiceColumn/CardGrid") as GridContainer
	option_list = get_node("ContentRow/ChoiceColumn/OptionList") as VBoxContainer
	preview_panel = get_node("ContentRow/PreviewPanel") as PanelContainer
	preview_image = get_node(
		"ContentRow/PreviewPanel/PreviewContent/PreviewImage"
	) as TextureRect
	preview_title = get_node(
		"ContentRow/PreviewPanel/PreviewContent/PreviewTitle"
	) as Label
	preview_text = get_node(
		"ContentRow/PreviewPanel/PreviewContent/PreviewText"
	) as RichTextLabel
	if energy_actions and not energy_actions.has_meta("choice_panel_connected"):
		energy_actions.set_meta("choice_panel_connected", true)
		var undo_button := energy_actions.get_node("UndoButton") as Button
		var clear_button := energy_actions.get_node("ClearButton") as Button
		undo_button.pressed.connect(func() -> void:
			undo_requested.emit()
		)
		clear_button.pressed.connect(func() -> void:
			clear_requested.emit()
		)


func _refresh_energy_assignment_labels(selected_ids: Array[String]) -> void:
	if _energy_assignment_labels.is_empty():
		return
	if not _energy_distribution_mode:
		return
	for index in range(_energy_assignment_labels.size()):
		var label := _energy_assignment_labels[index]
		var card := _energy_preview_cards[index] if index < _energy_preview_cards.size() else null
		if index < selected_ids.size():
			var option_id := str(selected_ids[index])
			var target_label := str(_option_labels.get(option_id, option_id))
			label.text = "→ %s" % target_label
			label.tooltip_text = target_label
			label.add_theme_color_override("font_color", DesignTokens.GOLD)
			if card:
				card.set_selected(true)
		elif index == selected_ids.size():
			label.text = "当前"
			label.tooltip_text = "下一张将分配的能量"
			label.add_theme_color_override("font_color", DesignTokens.CYAN)
			if card:
				card.set_selected(true)
		else:
			label.text = "待分配"
			label.tooltip_text = "尚未分配"
			label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
			if card:
				card.set_selected(false)


func _configure_preview_panel() -> void:
	if preview_panel:
		preview_panel.add_theme_stylebox_override(
			"panel",
			DesignTokens.panel_style(
				Color(0.055, 0.10, 0.17, 0.94),
				DesignTokens.RADIUS_SMALL,
				DesignTokens.BORDER_SOFT,
				1,
				8,
			),
		)
	if preview_text:
		preview_text.bbcode_enabled = true
		preview_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		preview_text.scroll_active = true


func _preview_card(card_id: String) -> void:
	_resolve_nodes()
	_configure_preview_panel()
	if card_id.is_empty():
		_hide_preview()
		return
	var card := _card_data(card_id)
	if card.is_empty():
		_hide_preview()
		return
	_previewed_card_id = card_id
	preview_panel.visible = true
	preview_image.texture = _texture_for_path(str(card.get("image_path", "")))
	preview_title.text = str(card.get("name", card_id))
	preview_text.text = _card_detail_bbcode(card_id)
	preview_text.scroll_to_line(0)


func _hide_preview() -> void:
	_previewed_card_id = ""
	if preview_panel:
		preview_panel.visible = false
	if preview_image:
		preview_image.texture = null
	if preview_title:
		preview_title.text = "卡牌预览"
	if preview_text:
		preview_text.text = "选择卡牌查看效果。"


func _card_detail_bbcode(card_id: String) -> String:
	var card := _card_data(card_id)
	var rows: Array[String] = []
	rows.append("[color=#9eb0ca]%s[/color]" % _card_type_text(card))
	if int(card.get("hp", 0)) > 0:
		rows.append("HP %d" % int(card.get("hp", 0)))
	if int(card.get("retreat_cost", 0)) > 0:
		rows.append("撤退费用：%d" % int(card.get("retreat_cost", 0)))
	if not str(card.get("evolves_from", "")).is_empty():
		rows.append("进化自：%s" % str(card.get("evolves_from", "")))
	var provides := _string_array(card.get("provides_energy", []))
	if not provides.is_empty():
		rows.append("提供能量：%s" % " / ".join(provides))
	for ability_value in card.get("abilities", []):
		var ability: Dictionary = ability_value
		rows.append("[color=#62d7ff]特性 · %s[/color]\n%s" % [
			str(ability.get("name", "")),
			str(ability.get("text", "")),
		])
	for attack_value in card.get("attacks", []):
		var attack: Dictionary = attack_value
		rows.append("[color=#f4c84a]%s · %s[/color]\n%s" % [
			str(attack.get("name", "")),
			str(attack.get("damage", "")),
			str(attack.get("text", "")),
		])
	if not str(card.get("trainer_text", "")).is_empty():
		rows.append(str(card.get("trainer_text", "")))
	for rule_value in card.get("rules", []):
		var rule := str(rule_value)
		if not rule.is_empty() and rule not in rows:
			rows.append(rule)
	for effect_value in card.get("energy_effects", []):
		var effect: Dictionary = effect_value
		var effect_text := _energy_effect_text(effect)
		if not effect_text.is_empty() and effect_text not in rows:
			rows.append(effect_text)
	return "\n\n".join(rows)


func _card_type_text(card: Dictionary) -> String:
	var supertype := str(card.get("supertype", ""))
	var subtypes := _string_array(card.get("subtypes", []))
	return "%s%s" % [
		supertype,
		" · %s" % " / ".join(subtypes) if not subtypes.is_empty() else "",
	]


func _energy_effect_text(effect: Dictionary) -> String:
	var kind := str(effect.get("kind", ""))
	match kind:
		"provide_energy":
			var types := _string_array(effect.get("types", []))
			return "能量效果：提供 %s" % " / ".join(types) if not types.is_empty() else ""
		"modifier":
			return "能量效果：伤害修正 %s" % JSON.stringify(effect.get("effect", {}))
		"trigger":
			return "能量效果：附着触发 %s" % JSON.stringify(effect.get("effect", {}))
	return "能量效果：%s" % JSON.stringify(effect)


func _string_array(values: Variant) -> Array[String]:
	var result: Array[String] = []
	if values is Array:
		for value in values:
			var text := str(value)
			if not text.is_empty():
				result.append(text)
	return result


func _card_name(card_id: String) -> String:
	return str(_card_data(card_id).get("name", card_id))


func _card_data(card_id: String) -> Dictionary:
	if catalog:
		return catalog.get_card(card_id)
	var database := _root_child("CardDatabase")
	if database and database.has_method("get_card"):
		return database.call("get_card", card_id)
	return {}


func _texture_for_path(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var texture_cache := _root_child("CardTextureCache")
	if texture_cache and texture_cache.has_method("get_texture"):
		return texture_cache.call("get_texture", path) as Texture2D
	return (
		load(path) as Texture2D
		if ResourceLoader.exists(path)
		else null
	)


func _root_child(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)


func _clear_children(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		child.queue_free()


func _on_tile_gui_input(event: InputEvent, option_id: String, tile: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			_preview_card(str(_option_card_ids.get(option_id, "")))
			option_toggled.emit(option_id)
		tile.accept_event()

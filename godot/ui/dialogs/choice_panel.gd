class_name ChoicePanel
extends VBoxContainer

signal option_toggled(option_id: String)
signal energy_index_requested(index: int)
signal undo_requested
signal clear_requested

const CARD_SCENE := preload("res://ui/card_view.tscn")
const ATTACHMENT_VISUALS := preload("res://ui/attachment_visual_descriptor.gd")
const CARD_TILE_SIZE := Vector2(112, 172)
const CHOICE_CARD_SIZE := Vector2(92, 130)
const ENERGY_CARD_SIZE := Vector2(54, 76)
const REVEALED_CARD_SIZE := Vector2(78, 110)
const ENERGY_TARGET_TILE_SIZE := Vector2(256, 164)
const CARD_GRID_GAP := 10.0
const NARROW_PREVIEW_MIN_WIDTH := 120.0
const NARROW_PREVIEW_MAX_WIDTH := 176.0

@onready var prompt_label: Label = %PromptLabel
@onready var metadata_label: Label = %MetadataLabel
@onready var selection_hint_label: Label = %SelectionHintLabel
@onready var blocked_reason_label: Label = %BlockedReasonLabel
@onready var empty_label: Label = %EmptyLabel
@onready var content_row: BoxContainer = %ContentRow
@onready var choice_column: VBoxContainer = %ChoiceColumn
@onready var energy_preview: VBoxContainer = %EnergyPreview
@onready var energy_preview_label: Label = %EnergyPreviewLabel
@onready var energy_grid: HFlowContainer = %EnergyGrid
@onready var energy_actions: HBoxContainer = %EnergyActions
@onready var undo_button: Button = %UndoButton
@onready var clear_button: Button = %ClearButton
@onready var preview_toggle_button: Button = %PreviewToggleButton
@onready var card_grid: HFlowContainer = %CardGrid
@onready var option_list: VBoxContainer = %OptionList
@onready var preview_panel: PanelContainer = %PreviewPanel
@onready var preview_image: TextureRect = %PreviewImage
@onready var preview_title: Label = %PreviewTitle
@onready var preview_text: RichTextLabel = %PreviewText

var catalog: CardCatalog
var energy_distribution: EnergyDistributionPanel
var _option_cards: Dictionary = {}
var _option_badges: Dictionary = {}
var _option_tiles: Dictionary = {}
var _option_captions: Dictionary = {}
var _option_buttons: Dictionary = {}
var _option_card_ids: Dictionary = {}
var _option_labels: Dictionary = {}
var _selection_counts: Dictionary = {}
var _option_disabled_reasons: Dictionary = {}
var _last_selected_ids: Array[String] = []
var _compact_preview_expanded := false
var _compact_choice_layout := false
var _previewed_card_id := ""
var _selection_max := 0
var _selection_min := -1
var _request_type := ""
var _allow_duplicates := false
var _choice_context: Dictionary = {}
var _responsive_update_queued := false


func configure(
	metadata_text: String,
	has_options: bool,
	p_catalog: CardCatalog = null,
	context: Dictionary = {},
) -> void:
	_resolve_nodes()
	catalog = p_catalog
	clear_options()
	_choice_context = context.duplicate(true)
	_selection_min = int(_choice_context.get("min_select", -1))
	_selection_max = maxi(0, int(_choice_context.get("max_select", 0)))
	_request_type = str(_choice_context.get("request_type", ""))
	_allow_duplicates = bool(_choice_context.get("allow_duplicates", false))
	_configure_preview_panel()
	var prompt_text := str(_choice_context.get("prompt", "")).strip_edges()
	prompt_label.text = prompt_text
	prompt_label.visible = not prompt_text.is_empty()
	metadata_label.text = metadata_text
	metadata_label.visible = not metadata_text.is_empty()
	selection_hint_label.visible = false
	blocked_reason_label.visible = false
	var optional_empty_with_prompt := (
		not has_options
		and _effective_min_select() <= 0
		and not prompt_text.is_empty()
	)
	empty_label.visible = not has_options and not optional_empty_with_prompt
	empty_label.text = (
		"没有符合条件的卡牌，点击下方“继续结算”。"
		if _effective_min_select() <= 0
		else "当前没有合法选项，暂时无法继续。"
	)
	content_row.visible = has_options
	card_grid.visible = false
	option_list.visible = false
	energy_preview.visible = false
	energy_distribution._update_energy_action_buttons(0)
	_compact_preview_expanded = false
	_hide_preview()
	_queue_responsive_layout()


func clear_options() -> void:
	_resolve_nodes()
	_clear_children(card_grid)
	_clear_children(option_list)
	_clear_children(energy_grid)
	_option_cards.clear()
	_option_badges.clear()
	_option_tiles.clear()
	_option_captions.clear()
	_option_buttons.clear()
	_option_card_ids.clear()
	_option_labels.clear()
	_selection_counts.clear()
	_option_disabled_reasons.clear()
	_last_selected_ids.clear()
	energy_distribution._energy_preview_cards.clear()
	energy_distribution._energy_assignment_labels.clear()
	energy_distribution._energy_distribution_mode = false
	energy_distribution._energy_target_models.clear()
	energy_distribution._energy_target_tiles.clear()
	energy_distribution._energy_target_cards.clear()
	energy_distribution._energy_target_existing_rows.clear()
	energy_distribution._energy_target_projected_rows.clear()
	energy_distribution._energy_target_status_labels.clear()
	energy_distribution._energy_target_key_by_option_id.clear()
	energy_distribution._energy_index_by_option_id.clear()
	energy_distribution._energy_source_card_ids.clear()
	_compact_preview_expanded = false
	content_row.visible = false
	card_grid.visible = false
	option_list.visible = false
	energy_preview.visible = false
	energy_distribution._update_energy_action_buttons(0)
	_clear_blocked_reason()
	_hide_preview()


func add_card_option(
	option_id: String,
	card_id: String,
	caption_text: String,
	player: int,
) -> CardView:
	_resolve_nodes()
	content_row.visible = true
	card_grid.visible = true
	empty_label.visible = false
	var tile := PanelContainer.new()
	tile.name = "CardChoiceTile"
	tile.custom_minimum_size = CARD_TILE_SIZE
	tile.mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_card_tile_style(tile, false, false, false)
	tile.gui_input.connect(_on_tile_gui_input.bind(option_id, tile))
	tile.mouse_entered.connect(_on_card_tile_hover_changed.bind(option_id, true))
	tile.mouse_exited.connect(_on_card_tile_hover_changed.bind(option_id, false))

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
	# Selection in a scrollable grid must not lift the first row into the clip
	# boundary. The stronger ring, glow and badge carry the selected state here.
	card_view.selected_lift = 0.0
	card_view.selected_scale = 1.0
	card_view.hover_lift = 2.0
	card_view.hover_scale = 1.02
	card_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	card_view.set_catalog(catalog)
	card_view.configure(card_id, null, false, -1, player, "", true)
	card_view.tooltip_text = ""
	card_view.detail_requested.connect(func(_card_id: String) -> void:
		_preview_card(card_id)
	)
	card_view.activated.connect(func(
		_card_id: String,
		_hand_index: int,
		_owner: int,
		_slot: String,
	) -> void:
		_request_card_option(option_id, card_id)
	)
	card_view.mouse_entered.connect(
		_on_card_tile_hover_changed.bind(option_id, true)
	)
	card_view.mouse_exited.connect(
		_on_card_tile_hover_changed.bind(option_id, false)
	)
	card_area.add_child(card_view)
	_apply_choice_selection_ring(card_view)

	var badge := Label.new()
	badge.name = "SelectionStatusBadge"
	badge.visible = false
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.text = "✓"
	badge.tooltip_text = ""
	badge.accessibility_name = "已选择"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override("font_color", Color("#07101d"))
	badge.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.28))
	badge.add_theme_constant_override("outline_size", 1)
	badge.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			DesignTokens.GOLD,
			10,
			Color("#fff2a6"),
			1,
			2,
		),
	)
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	# Keep the status chip outside the card face so it does not cover the
	# printed card name or HP. The gold outline remains the primary state cue.
	badge.offset_left = -30
	badge.offset_top = -23
	badge.offset_right = 2
	badge.offset_bottom = -1
	card_area.add_child(badge)

	var caption := Label.new()
	# The tile panel contributes 6 px on each side. Keep the combined minimum
	# exactly CARD_TILE_SIZE so responsive column calculations stay truthful.
	caption.custom_minimum_size = Vector2(CARD_TILE_SIZE.x - 12.0, 24.0)
	caption.mouse_filter = Control.MOUSE_FILTER_PASS
	caption.text = caption_text
	caption.tooltip_text = ""
	caption.accessibility_description = caption_text
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
	_option_tiles[option_id] = tile
	_option_captions[option_id] = caption
	_option_card_ids[option_id] = card_id
	_option_labels[option_id] = caption_text if not caption_text.is_empty() else _card_name(card_id)
	_selection_counts[option_id] = 0
	if _previewed_card_id.is_empty():
		_preview_card(card_id)
	_queue_responsive_layout()
	return card_view


func add_text_option(option_id: String, label_text: String) -> Button:
	_resolve_nodes()
	content_row.visible = true
	option_list.visible = true
	empty_label.visible = false
	var button := Button.new()
	button.text = label_text
	button.custom_minimum_size.y = DesignTokens.TOUCH_MIN
	button.focus_mode = Control.FOCUS_NONE
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.set_meta("option_id", option_id)
	button.set_meta("base_text", label_text)
	button.set_meta("choice_blocked", false)
	button.set_meta("choice_disabled_reason", "")
	button.pressed.connect(_on_text_option_pressed.bind(option_id))
	_option_buttons[option_id] = button
	_option_labels[option_id] = label_text
	_selection_counts[option_id] = 0
	option_list.add_child(button)
	_apply_text_option_style(option_id)
	return button




func _ensure_energy_distribution() -> void:
	if energy_distribution != null and is_instance_valid(energy_distribution):
		return
	energy_distribution = get_node_or_null(
		"EnergyDistributionPanel"
	) as EnergyDistributionPanel
	if energy_distribution == null:
		energy_distribution = EnergyDistributionPanel.new()
		energy_distribution.name = "EnergyDistributionPanel"
		add_child(energy_distribution)
	energy_distribution.configure(self)


func add_energy_preview(card_ids: Array[String], p_catalog: CardCatalog) -> void:
	energy_distribution.add_energy_preview(card_ids, p_catalog)


func configure_energy_distribution(
	card_ids: Array[String],
	target_models: Array[Dictionary],
	p_catalog: CardCatalog,
) -> void:
	energy_distribution.configure_energy_distribution(
		card_ids, target_models, p_catalog,
	)

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
	content_row.visible = true
	energy_preview.visible = true
	energy_preview_label.text = label_text
	energy_actions.visible = interactive_distribution
	energy_distribution._energy_distribution_mode = interactive_distribution
	if interactive_distribution:
		energy_distribution._energy_source_card_ids.assign(card_ids)
	energy_distribution._update_energy_action_buttons(0)
	_clear_children(energy_grid)
	energy_distribution._energy_preview_cards.clear()
	energy_distribution._energy_assignment_labels.clear()
	for index in range(card_ids.size()):
		var preview_index := index
		var card_id := card_ids[index]
		var preview_card_id := card_id
		var tile := VBoxContainer.new()
		tile.mouse_filter = Control.MOUSE_FILTER_PASS
		tile.alignment = BoxContainer.ALIGNMENT_CENTER
		tile.add_theme_constant_override("separation", 3)
		var card: CardView
		if card_id.is_empty():
			var placeholder := PanelContainer.new()
			placeholder.custom_minimum_size = ENERGY_CARD_SIZE
			placeholder.mouse_filter = Control.MOUSE_FILTER_STOP
			placeholder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			placeholder.tooltip_text = "第 %d 张待分配能量" % (index + 1)
			placeholder.accessibility_name = placeholder.tooltip_text
			placeholder.add_theme_stylebox_override(
				"panel",
				DesignTokens.panel_style(
					DesignTokens.SURFACE_ELEVATED,
					DesignTokens.RADIUS_SMALL,
					DesignTokens.BORDER,
					1,
					4,
				),
			)
			var placeholder_label := Label.new()
			placeholder_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			placeholder_label.text = "能量\n%d" % (index + 1)
			placeholder_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			placeholder_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			placeholder_label.add_theme_font_size_override("font_size", 11)
			placeholder.add_child(placeholder_label)
			placeholder.gui_input.connect(
				energy_distribution._on_energy_placeholder_gui_input.bind(preview_index)
			)
			tile.add_child(placeholder)
		else:
			card = CARD_SCENE.instantiate() as CardView
			card.custom_minimum_size = (
				ENERGY_CARD_SIZE if interactive_distribution else REVEALED_CARD_SIZE
			)
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card.selected_lift = 0.0
			card.selected_scale = 1.0
			card.set_catalog(self.catalog)
			card.configure(card_id, null, false, -1, -1, "", true)
			card.tooltip_text = ""
			card.accessibility_name = _card_name(card_id)
			card.detail_requested.connect(func(_card_id: String) -> void:
				_preview_card(preview_card_id)
				if interactive_distribution and _compact_choice_layout:
					_compact_preview_expanded = true
					_queue_responsive_layout()
			)
			card.activated.connect(func(
				_card_id: String,
				_hand_index: int,
				_owner: int,
				_slot: String,
			) -> void:
				energy_distribution._on_energy_preview_card_activated(
					preview_card_id,
					preview_index,
					interactive_distribution,
				)
			)
			tile.add_child(card)
		energy_distribution._energy_preview_cards.append(card)
		var assignment := Label.new()
		assignment.custom_minimum_size = Vector2(130, 20)
		assignment.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		assignment.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		assignment.tooltip_text = ""
		assignment.accessibility_description = "尚未分配"
		assignment.add_theme_font_size_override("font_size", 10)
		assignment.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
		assignment.text = "第 %d 张 · 等待" % (index + 1)
		assignment.visible = interactive_distribution
		tile.add_child(assignment)
		energy_distribution._energy_assignment_labels.append(assignment)
		energy_grid.add_child(tile)
	if _previewed_card_id.is_empty() and not card_ids.is_empty():
		_preview_card(str(card_ids[0]))
	_queue_responsive_layout()


func _clear_children_immediate(parent: Node) -> void:
	if parent == null:
		return
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func refresh_selection(
	selected_ids: Array[String],
	max_select: int,
	allow_duplicates: bool,
) -> void:
	_selection_max = maxi(0, max_select)
	_allow_duplicates = allow_duplicates
	var selection_changed := selected_ids != _last_selected_ids
	_last_selected_ids.assign(selected_ids)
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
			badge.visible = count > 0
			badge.text = "✓%d" % count if count > 1 else "✓"
			badge.tooltip_text = ""
			badge.accessibility_name = "已选择 %d 次" % count if count > 1 else "已选择"
			badge.accessibility_name = badge.tooltip_text
			badge.offset_left = -36 if count > 1 else -30
		_refresh_card_tile_visual(str(option_id))
	for option_id in _option_buttons.keys():
		var count := int(counts.get(option_id, 0))
		_selection_counts[option_id] = count
		_apply_text_option_style(str(option_id))
	for option_id in energy_distribution._energy_target_key_by_option_id.keys():
		_selection_counts[option_id] = int(counts.get(option_id, 0))
	if selection_changed:
		_clear_blocked_reason()
	_update_selection_hint(selected_ids.size())
	energy_distribution._refresh_energy_assignment_labels(selected_ids)
	energy_distribution._refresh_energy_target_tiles(selected_ids)
	energy_distribution._update_energy_action_buttons(selected_ids.size())


func set_option_disabled_reasons(reasons: Dictionary) -> void:
	_option_disabled_reasons.clear()
	for option_id_value in reasons:
		var option_id := str(option_id_value)
		var reason := str(reasons[option_id_value]).strip_edges()
		if not option_id.is_empty() and not reason.is_empty():
			_option_disabled_reasons[option_id] = reason
	for option_id in _option_cards.keys():
		_refresh_card_tile_visual(str(option_id))
	for option_id in _option_buttons.keys():
		_apply_text_option_style(str(option_id))
	energy_distribution._refresh_energy_target_tiles(_last_selected_ids)
	if blocked_reason_label and blocked_reason_label.visible:
		var shown_reason := blocked_reason_label.text
		var reason_still_present := false
		for current_reason in _option_disabled_reasons.values():
			if str(current_reason) == shown_reason:
				reason_still_present = true
				break
		if not reason_still_present:
			_clear_blocked_reason()


func show_blocked_reason(reason: String) -> void:
	_resolve_nodes()
	var clean_reason := reason.strip_edges()
	if clean_reason.is_empty():
		_clear_blocked_reason()
		return
	blocked_reason_label.text = clean_reason
	blocked_reason_label.tooltip_text = clean_reason
	blocked_reason_label.accessibility_name = clean_reason
	blocked_reason_label.visible = true


func option_disabled_reason(option_id: String) -> String:
	return str(_option_disabled_reasons.get(option_id, ""))


func card_option_count() -> int:
	return (
		energy_distribution._energy_target_models.size()
		if energy_distribution._energy_distribution_mode and not energy_distribution._energy_target_models.is_empty()
		else _option_cards.size()
	)


func text_option_count() -> int:
	return _option_buttons.size()


func selected_count_for(option_id: String) -> int:
	return int(_selection_counts.get(option_id, 0))


func previewed_card_id() -> String:
	return _previewed_card_id


func _resolve_nodes() -> void:
	_ensure_energy_distribution()
	prompt_label = get_node("PromptLabel") as Label
	metadata_label = get_node("MetadataLabel") as Label
	selection_hint_label = get_node("SelectionHintLabel") as Label
	blocked_reason_label = get_node("BlockedReasonLabel") as Label
	empty_label = get_node("EmptyLabel") as Label
	content_row = get_node("ContentRow") as BoxContainer
	choice_column = get_node("ContentRow/ChoiceColumn") as VBoxContainer
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
	undo_button = get_node(
		"ContentRow/ChoiceColumn/EnergyPreview/EnergyActions/UndoButton"
	) as Button
	clear_button = get_node(
		"ContentRow/ChoiceColumn/EnergyPreview/EnergyActions/ClearButton"
	) as Button
	preview_toggle_button = get_node(
		"ContentRow/ChoiceColumn/PreviewToggleButton"
	) as Button
	card_grid = get_node("ContentRow/ChoiceColumn/CardGrid") as HFlowContainer
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
		undo_button.pressed.connect(func() -> void:
			undo_requested.emit()
		)
		clear_button.pressed.connect(func() -> void:
			clear_requested.emit()
		)
	if preview_toggle_button and not preview_toggle_button.has_meta(
		"choice_panel_connected"
	):
		preview_toggle_button.set_meta("choice_panel_connected", true)
		preview_toggle_button.pressed.connect(_toggle_compact_preview)


func _toggle_compact_preview() -> void:
	_compact_preview_expanded = not _compact_preview_expanded
	_queue_responsive_layout()


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
		preview_text.focus_mode = Control.FOCUS_NONE
		preview_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		preview_text.scroll_active = true
		DesignTokens.style_scrollbar(preview_text.get_v_scroll_bar())


func _preview_card(card_id: String) -> void:
	_resolve_nodes()
	_configure_preview_panel()
	if card_id.is_empty():
		_hide_preview()
		return
	var card := _card_data(card_id)
	_previewed_card_id = card_id
	preview_panel.visible = true
	if card.is_empty():
		preview_image.texture = null
		preview_title.text = "卡牌资料暂不可用"
		preview_text.text = "暂时无法读取这张卡牌的图片和效果说明。"
		preview_text.scroll_to_line(0)
		preview_panel.tooltip_text = "卡牌资料暂不可用"
		_apply_responsive_layout()
		return
	preview_panel.tooltip_text = ""
	preview_image.texture = _texture_for_path(str(card.get("image_path", "")))
	preview_title.text = str(card.get("name", card_id))
	preview_text.text = _card_detail_bbcode(card_id)
	preview_text.scroll_to_line(0)
	# Resolve the right-hand preview in the same input turn. Deferring this step
	# briefly leaves the scene's 270 px default minimum in a narrow layout.
	_apply_responsive_layout()


func _hide_preview() -> void:
	_previewed_card_id = ""
	if preview_panel:
		preview_panel.visible = false
		preview_panel.tooltip_text = ""
	if preview_image:
		preview_image.texture = null
	if preview_title:
		preview_title.text = "卡牌预览"
	if preview_text:
		preview_text.text = "选择卡牌查看效果。"
		preview_text.scroll_to_line(0)
	_queue_responsive_layout()


func _card_detail_bbcode(card_id: String) -> String:
	var card := _card_data(card_id)
	return "[color=#9eb0ca]%s[/color]\n\n%s" % [
		CardPresentation.meta_text(card),
		CardPresentation.detail_bbcode(
			card,
			catalog,
			null,
			CardPresentation.DetailLevel.FULL,
		),
	]


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
			_request_card_option(option_id, str(_option_card_ids.get(option_id, "")))
		tile.accept_event()


func _request_card_option(option_id: String, card_id: String) -> void:
	# Preview is always available, including for a currently blocked choice.
	_preview_card(card_id)
	var blocked_reason := _blocked_reason_for_unselected(option_id)
	if not blocked_reason.is_empty():
		show_blocked_reason(blocked_reason)
		return
	_clear_blocked_reason()
	option_toggled.emit(option_id)


func _on_text_option_pressed(option_id: String) -> void:
	var blocked_reason := _blocked_reason_for_unselected(option_id)
	if not blocked_reason.is_empty():
		show_blocked_reason(blocked_reason)
		return
	_clear_blocked_reason()
	option_toggled.emit(option_id)


func _blocked_reason_for_unselected(option_id: String) -> String:
	# A selected ordinary option must remain interactive so it can be cancelled.
	# In duplicate distribution mode another tap means "add one more", so target
	# capacity still applies; assigned energy is removed with rewind/undo instead.
	if int(_selection_counts.get(option_id, 0)) > 0 and not _allow_duplicates:
		return ""
	return str(_option_disabled_reasons.get(option_id, ""))


func _clear_blocked_reason() -> void:
	if blocked_reason_label:
		blocked_reason_label.visible = false
		blocked_reason_label.text = ""
		blocked_reason_label.tooltip_text = ""
		blocked_reason_label.accessibility_name = ""


func _on_card_tile_hover_changed(option_id: String, hovered: bool) -> void:
	var tile := _option_tiles.get(option_id) as PanelContainer
	if tile == null:
		return
	tile.set_meta("choice_hovered", hovered)
	_refresh_card_tile_visual(option_id)


func _refresh_card_tile_visual(option_id: String) -> void:
	var tile := _option_tiles.get(option_id) as PanelContainer
	if tile == null:
		return
	var selected := int(_selection_counts.get(option_id, 0)) > 0
	var hovered := bool(tile.get_meta("choice_hovered", false))
	var blocked_reason := _blocked_reason_for_unselected(option_id)
	var blocked := not blocked_reason.is_empty()
	tile.set_meta("choice_blocked", blocked)
	tile.set_meta("choice_disabled_reason", blocked_reason)
	tile.tooltip_text = ""
	tile.accessibility_description = blocked_reason if blocked else ""
	tile.mouse_default_cursor_shape = (
		Control.CURSOR_FORBIDDEN if blocked else Control.CURSOR_POINTING_HAND
	)
	_apply_card_tile_style(tile, selected, hovered, blocked)
	var card_view := _option_cards.get(option_id) as CardView
	if card_view:
		# CardView renders disabled reasons as an in-card interaction overlay. Choice
		# tiles keep the card face pristine and communicate blocking around the card.
		card_view.set_disabled_reason("")
	var caption := _option_captions.get(option_id) as Label
	if caption:
		caption.add_theme_color_override(
			"font_color",
			DesignTokens.GOLD
			if selected
			else DesignTokens.RED
			if blocked
			else DesignTokens.TEXT
			if hovered
			else DesignTokens.TEXT_MUTED,
		)
		caption.tooltip_text = ""
		caption.accessibility_description = (
			blocked_reason if blocked else str(_option_labels.get(option_id, ""))
		)


func _apply_card_tile_style(
	tile: PanelContainer,
	selected: bool,
	hovered: bool,
	blocked: bool,
) -> void:
	var background := Color(0.06, 0.11, 0.18, 0.88)
	var border := DesignTokens.BORDER_SOFT
	var border_width := 1
	if selected:
		background = Color(0.085, 0.125, 0.18, 0.96)
		border = Color(DesignTokens.GOLD, 0.92)
		border_width = 2
	elif blocked:
		background = Color(0.06, 0.10, 0.16, 0.92)
		border = Color(DesignTokens.RED, 0.58 if hovered else 0.34)
		border_width = 2 if hovered else 1
	elif hovered:
		background = Color(0.075, 0.14, 0.215, 0.94)
		border = Color(DesignTokens.CYAN, 0.72)
		border_width = 2
	var style := DesignTokens.panel_style(
		background,
		DesignTokens.RADIUS_SMALL,
		border,
		border_width,
		6,
	)
	if selected:
		style.shadow_color = Color(DesignTokens.GOLD, 0.20)
		style.shadow_size = 7
		style.shadow_offset = Vector2.ZERO
	tile.add_theme_stylebox_override("panel", style)


func _apply_text_option_style(option_id: String) -> void:
	var button := _option_buttons.get(option_id) as Button
	if button == null:
		return
	var count := int(_selection_counts.get(option_id, 0))
	var selected := count > 0
	var blocked_reason := _blocked_reason_for_unselected(option_id)
	var blocked := not blocked_reason.is_empty()
	var base_text := str(button.get_meta("base_text", button.text))
	button.text = (
		"✓ %s%s" % [base_text, "  ×%d" % count if count > 1 else ""]
		if selected
		else base_text
	)
	# Keep the control enabled so tapping a blocked option can explain why it is
	# unavailable. Only its presentation and routing state are disabled.
	button.disabled = false
	button.set_meta("choice_blocked", blocked)
	button.set_meta("choice_disabled_reason", blocked_reason)
	button.tooltip_text = blocked_reason if blocked else base_text
	button.accessibility_name = (
		"%s，%s" % [base_text, blocked_reason]
		if blocked
		else "%s，已选择" % base_text
		if selected
		else base_text
	)
	button.mouse_default_cursor_shape = (
		Control.CURSOR_FORBIDDEN if blocked else Control.CURSOR_POINTING_HAND
	)
	var normal_style: StyleBoxFlat
	var hover_style: StyleBoxFlat
	var pressed_style: StyleBoxFlat
	var font_color := DesignTokens.TEXT
	var hover_font_color := DesignTokens.TEXT
	var pressed_font_color := DesignTokens.TEXT
	if selected:
		normal_style = DesignTokens.panel_style(
			Color(0.16, 0.20, 0.23, 0.98), 10, DesignTokens.GOLD, 2, 12)
		hover_style = DesignTokens.panel_style(
			Color(0.20, 0.25, 0.27, 1.0), 10, Color("#ffe27a"), 2, 12)
		pressed_style = DesignTokens.panel_style(
			Color(DesignTokens.GOLD, 0.28), 10, DesignTokens.GOLD, 3, 12)
		font_color = DesignTokens.GOLD
		hover_font_color = Color("#ffe27a")
		pressed_font_color = Color("#fff1b0")
	elif blocked:
		normal_style = DesignTokens.panel_style(
			Color(0.045, 0.075, 0.12, 0.94), 10, Color(DesignTokens.RED, 0.34), 1, 12)
		hover_style = DesignTokens.panel_style(
			Color(0.065, 0.095, 0.14, 0.98), 10, Color(DesignTokens.RED, 0.64), 2, 12)
		pressed_style = hover_style
		font_color = DesignTokens.TEXT_MUTED
		hover_font_color = DesignTokens.RED
		pressed_font_color = DesignTokens.RED
	else:
		normal_style = DesignTokens.panel_style(
			DesignTokens.PANEL_RAISED, 10, DesignTokens.BORDER, 1, 12)
		hover_style = DesignTokens.panel_style(
			Color("#213754"), 10, DesignTokens.CYAN, 2, 12)
		pressed_style = DesignTokens.panel_style(
			Color(DesignTokens.CYAN, 0.20), 10, DesignTokens.CYAN, 2, 12)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_stylebox_override("pressed", pressed_style)
	button.add_theme_color_override("font_color", font_color)
	button.add_theme_color_override("font_hover_color", hover_font_color)
	button.add_theme_color_override("font_pressed_color", pressed_font_color)


func _apply_choice_selection_ring(card_view: CardView) -> void:
	var ring := card_view.get_node_or_null("SelectionRing") as Panel
	if ring == null:
		return
	var style := DesignTokens.panel_style(
		Color.TRANSPARENT,
		11,
		DesignTokens.GOLD,
		3,
		0,
	)
	style.draw_center = false
	style.shadow_color = Color(DesignTokens.GOLD, 0.62)
	style.shadow_size = 8
	style.shadow_offset = Vector2.ZERO
	ring.add_theme_stylebox_override("panel", style)


func _update_selection_hint(selected_count: int) -> void:
	if selection_hint_label == null:
		return
	if _selection_max <= 0:
		selection_hint_label.visible = false
		return
	if energy_distribution._energy_distribution_mode or _request_type == "distribute_energy":
		energy_distribution._update_energy_selection_hint(selected_count)
		return
	var has_card_options := not _option_cards.is_empty()
	var item_name := "卡牌" if has_card_options else "选项"
	var counter := "张" if has_card_options else "项"
	var quantified_item := "张卡牌" if has_card_options else "项"
	if _request_type in [
		"select_energy_target",
		"select_energy_source",
		"select_own_bench_energy",
		"select_prize_energy_target",
		"evolve_skip_stage",
		"select_heal_target",
		"damage_target",
		"bench_damage_target",
		"place_counters_self_discard",
		"select_bench",
		"select_bench_slot",
		"select_opponent_bench",
	]:
		item_name = "目标"
		counter = "个"
		quantified_item = "个目标"
	elif _request_type == "select_attachment":
		item_name = "附着物"
		counter = "个"
		quantified_item = "个附着物"
	var minimum := _effective_min_select()
	if _selection_max == 1:
		if selected_count > 0:
			selection_hint_label.text = (
				"已选择 1 %s · 点击其他%s可直接换选" % [quantified_item, item_name]
			)
		elif minimum <= 0:
			selection_hint_label.text = "可选择 1 %s · 也可以不选" % quantified_item
		else:
			selection_hint_label.text = "请选择 1 %s" % quantified_item
		selection_hint_label.visible = true
		return
	if selected_count < minimum:
		selection_hint_label.text = "已选择 %d / %d %s · 还需 %d %s" % [
			selected_count,
			_selection_max,
			counter,
			minimum - selected_count,
			counter,
		]
	elif selected_count >= _selection_max:
		selection_hint_label.text = "已选择 %d / %d %s · 已达到上限，可以确认" % [
			selected_count,
			_selection_max,
			counter,
		]
	else:
		selection_hint_label.text = "已选择 %d / %d %s · 已满足要求，可继续选择或确认" % [
			selected_count,
			_selection_max,
			counter,
		]
	selection_hint_label.visible = true


func _effective_min_select() -> int:
	if _selection_min >= 0:
		return clampi(_selection_min, 0, _selection_max)
	# Legacy callers did not provide context. Treat a non-empty choice as requiring
	# at least one item; new callers provide the exact minimum in context.
	return 1 if _selection_max > 0 else 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_queue_responsive_layout()


func _queue_responsive_layout() -> void:
	if _responsive_update_queued or not is_inside_tree():
		return
	_responsive_update_queued = true
	call_deferred("_flush_responsive_layout")


func _flush_responsive_layout() -> void:
	_responsive_update_queued = false
	if is_inside_tree():
		_apply_responsive_layout()


func _apply_responsive_layout() -> void:
	_resolve_nodes()
	var available_width := _responsive_available_width()
	if available_width <= 1.0:
		return
	var has_preview := not _previewed_card_id.is_empty()
	var compact_preview := available_width < 820.0
	_compact_choice_layout = compact_preview
	if prompt_label:
		prompt_label.visible = (
			not prompt_label.text.is_empty()
			and not (compact_preview and energy_distribution._energy_distribution_mode)
		)
	if energy_preview_label:
		energy_preview_label.visible = not (
			compact_preview and energy_distribution._energy_distribution_mode
		)
	var show_preview := has_preview and (
		not compact_preview or _compact_preview_expanded
	)
	if content_row:
		content_row.vertical = compact_preview and show_preview
	if preview_toggle_button:
		preview_toggle_button.visible = (
			has_preview
			and compact_preview
			and not energy_distribution._energy_distribution_mode
		)
		preview_toggle_button.text = (
			"收起卡牌说明" if _compact_preview_expanded else "查看卡牌说明"
		)
		preview_toggle_button.tooltip_text = (
			"收起当前卡牌的图片与规则说明"
			if _compact_preview_expanded
			else "展开当前卡牌的图片与规则说明"
		)
		preview_toggle_button.accessibility_name = preview_toggle_button.text
	var preview_width := 0.0
	var preview_height := 0.0
	var image_size := Vector2.ZERO
	if available_width >= 840.0:
		preview_width = 270.0
		preview_height = 430.0
		image_size = Vector2(206, 288)
	elif available_width >= 640.0:
		preview_width = 220.0
		preview_height = 370.0
		image_size = Vector2(166, 232)
	elif available_width >= 500.0:
		preview_width = available_width if compact_preview else 176.0
		preview_height = 315.0
		image_size = Vector2(132, 184)
	else:
		preview_width = available_width
		var narrow_image_width := clampf(available_width * 0.42, 96.0, 150.0)
		image_size = Vector2(narrow_image_width, narrow_image_width * 1.4)
		preview_height = maxf(260.0, image_size.y + 120.0)
	if compact_preview:
		preview_width = available_width
	energy_distribution._update_energy_action_buttons(_last_selected_ids.size())
	if preview_panel:
		# Keep the horizontal minimum compact. BoxContainer allocates the desired
		# preview share through stretch ratios, so a former wide layout cannot stop
		# its modal/scroll viewport from shrinking later.
		preview_panel.custom_minimum_size = Vector2(
			0.0 if compact_preview else NARROW_PREVIEW_MIN_WIDTH,
			preview_height,
		)
		preview_panel.visible = show_preview
	if preview_image:
		preview_image.custom_minimum_size = Vector2(88.0, image_size.y)
	var row_gap := (
		float(content_row.get_theme_constant("separation"))
		if content_row
		else 14.0
	)
	var choice_width := available_width
	if show_preview and not compact_preview:
		choice_width -= preview_width + row_gap
	var tile_width := (
		ENERGY_TARGET_TILE_SIZE.x
		if energy_distribution._energy_distribution_mode and not energy_distribution._energy_target_models.is_empty()
		else CARD_TILE_SIZE.x
	)
	var fitted_columns := floori(
		(maxf(tile_width, choice_width) + CARD_GRID_GAP)
		/ (tile_width + CARD_GRID_GAP)
	)
	# HFlowContainer wraps without contributing the width of every configured
	# column to its minimum size. Match its allocation to the target preview
	# width while retaining one compact tile as the grid's stable minimum.
	if preview_panel:
		var choice_target := maxf(tile_width, choice_width)
		preview_panel.size_flags_stretch_ratio = maxf(
			0.01,
			preview_width / choice_target,
		)
	if card_grid:
		card_grid.set_meta("responsive_columns", clampi(fitted_columns, 1, 5))
		card_grid.set_meta(
			"responsive_preview_width",
			preview_width if show_preview else 0.0,
		)


func responsive_column_count() -> int:
	return int(card_grid.get_meta("responsive_columns", 1)) if card_grid else 1


func responsive_preview_width() -> float:
	return (
		float(card_grid.get_meta("responsive_preview_width", 0.0))
		if card_grid
		else 0.0
	)


func _responsive_available_width() -> float:
	# Dynamic child minima can temporarily keep ChoicePanel and ModalBody wider
	# than the visible scroll viewport after a window shrink. The viewport is the
	# stable constraint that lets the following pass reduce preview and columns.
	var available_width := size.x
	var ancestor := get_parent()
	while ancestor:
		if ancestor is ScrollContainer:
			var scroll := ancestor as ScrollContainer
			var viewport_width := scroll.size.x
			var vertical_bar := scroll.get_v_scroll_bar()
			if vertical_bar and vertical_bar.visible:
				viewport_width -= vertical_bar.size.x
			if viewport_width > 1.0:
				available_width = viewport_width
			break
		ancestor = ancestor.get_parent()
	if available_width <= 1.0 and get_parent() is Control:
		available_width = (get_parent() as Control).size.x
	return available_width

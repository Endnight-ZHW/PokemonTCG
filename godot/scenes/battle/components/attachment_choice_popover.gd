class_name AttachmentChoicePopover
extends Control

signal option_chosen(option_id: String)
signal option_toggled(option_id: String)
signal confirmed
signal cancelled
signal dismissed

const ATTACHMENT_VISUALS := preload("res://ui/attachment_visual_descriptor.gd")
const WIDE_WIDTH := 326.0
const COMPACT_INSET := 12.0
const ROW_HEIGHT := 52.0

var _catalog: CardCatalog
var _options: Array[Dictionary] = []
var _selected_ids: Array[String] = []
var _disabled_reasons: Dictionary = {}
var _min_select := 1
var _max_select := 1
var _can_cancel := false
var _source_ref: WeakRef
var _safe_rect := Rect2()
var _compact := false
var _source_label_text := ""

var _panel: PanelContainer
var _title_label: Label
var _source_label: Label
var _scroll: ScrollContainer
var _option_rows: VBoxContainer
var _confirm_button: Button
var _cancel_button: Button
var _button_by_id: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 218
	visible = false
	_build_nodes()
	var viewport := get_viewport()
	if viewport and not viewport.size_changed.is_connected(_reposition):
		viewport.size_changed.connect(_reposition)


func show_for_source(
	options: Array,
	selected_ids: Array,
	disabled_reasons: Dictionary,
	min_select: int,
	max_select: int,
	can_cancel: bool,
	source_control: Control,
	safe_rect: Rect2,
	catalog: CardCatalog,
	source_label: String,
) -> void:
	if source_control == null or not is_instance_valid(source_control):
		return
	_build_nodes()
	_catalog = catalog
	_options.clear()
	for value in options:
		if value is Dictionary:
			_options.append(Dictionary(value).duplicate(true))
	_selected_ids.assign(selected_ids)
	_disabled_reasons = disabled_reasons.duplicate(true)
	_min_select = maxi(0, min_select)
	_max_select = maxi(_min_select, max_select)
	_can_cancel = can_cancel
	_source_ref = weakref(source_control)
	_safe_rect = safe_rect
	_source_label_text = source_label
	_compact = safe_rect.size.x < 960.0 or safe_rect.size.y <= 540.0
	_rebuild_rows()
	visible = true
	modulate.a = 1.0
	_reposition()
	_play_open_motion()


func refresh_selection(
	selected_ids: Array,
	disabled_reasons: Dictionary = {},
) -> void:
	_selected_ids.assign(selected_ids)
	_disabled_reasons = disabled_reasons.duplicate(true)
	_sync_buttons()


func dismiss(emit_signal := true) -> void:
	if not visible:
		return
	visible = false
	_source_ref = null
	if emit_signal:
		dismissed.emit()


func panel_global_rect() -> Rect2:
	return _panel.get_global_rect() if _panel != null and visible else Rect2()


func source_contains_global_point(point: Vector2) -> bool:
	if _source_ref == null:
		return false
	var source = _source_ref.get_ref()
	if not source is Control or not is_instance_valid(source):
		return false
	if source.has_method("contains_visual_global_point"):
		return bool(source.call("contains_visual_global_point", point))
	return (source as Control).get_global_rect().has_point(point)


func is_compact_layout() -> bool:
	return _compact


func option_count() -> int:
	return _options.size()


func _build_nodes() -> void:
	if _panel != null:
		return
	_panel = PanelContainer.new()
	_panel.name = "AttachmentPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	_title_label = Label.new()
	_title_label.text = "选择附着能量"
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color("ffd46a"))
	content.add_child(_title_label)

	_source_label = Label.new()
	_source_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_source_label.add_theme_font_size_override("font_size", 12)
	_source_label.add_theme_color_override("font_color", Color("d9b35b"))
	content.add_child(_source_label)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_scroll)
	_option_rows = VBoxContainer.new()
	_option_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_option_rows.add_theme_constant_override("separation", 4)
	_scroll.add_child(_option_rows)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 8)
	content.add_child(footer)
	_cancel_button = Button.new()
	_cancel_button.custom_minimum_size = Vector2(84, 48)
	_cancel_button.focus_mode = Control.FOCUS_NONE
	_cancel_button.text = "取消"
	_cancel_button.pressed.connect(func() -> void: cancelled.emit())
	footer.add_child(_cancel_button)
	_confirm_button = Button.new()
	_confirm_button.custom_minimum_size = Vector2(132, 48)
	_confirm_button.focus_mode = Control.FOCUS_NONE
	_confirm_button.pressed.connect(func() -> void: confirmed.emit())
	footer.add_child(_confirm_button)


func _rebuild_rows() -> void:
	for child in _option_rows.get_children():
		child.free()
	_button_by_id.clear()
	_source_label.text = _source_label_text
	for option in _options:
		var option_id := str(option.get("option_id", ""))
		if option_id.is_empty():
			continue
		var button := Button.new()
		button.name = "Attachment_%s" % option_id.validate_node_name()
		button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = _max_select > 1 or _min_select == 0
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var descriptor: AttachmentVisualDescriptor = _attachment_descriptor(option)
		button.text = _option_label(option, descriptor)
		button.tooltip_text = str(_disabled_reasons.get(option_id, ""))
		button.accessibility_name = "%s；来源：%s" % [button.text, _source_label_text]
		button.add_theme_font_size_override("font_size", 13)
		var icon: Texture2D = descriptor.icon if descriptor != null else null
		if icon != null:
			button.icon = icon
			button.expand_icon = true
		if descriptor != null:
			button.set_meta("attachment_card_id", descriptor.card_id)
			button.set_meta("attachment_index", descriptor.first_physical_index())
			button.set_meta("attachment_group_key", descriptor.group_key)
			button.set_meta(
				"provided_energy_units",
				descriptor.provided_energy_units.duplicate(),
			)
			button.set_meta("attachment_fallback_label", descriptor.fallback_label)
		button.pressed.connect(_on_option_pressed.bind(option_id))
		_option_rows.add_child(button)
		_button_by_id[option_id] = button
	_sync_buttons()


func _sync_buttons() -> void:
	for option_id_value in _button_by_id.keys():
		var option_id := str(option_id_value)
		var button := _button_by_id[option_id] as Button
		if button == null:
			continue
		var selected := option_id in _selected_ids
		button.set_pressed_no_signal(selected)
		var reason := str(_disabled_reasons.get(option_id, ""))
		button.disabled = not selected and not reason.is_empty()
		button.tooltip_text = reason
		button.modulate = Color("ffd56a") if selected else Color.WHITE
	var valid_count := _selected_ids.size()
	_confirm_button.visible = _max_select != 1 or _min_select == 0
	_confirm_button.disabled = valid_count < _min_select or valid_count > _max_select
	_confirm_button.text = (
		"不选择并继续"
		if valid_count == 0 and _min_select == 0
		else "确认选择（%d/%d）" % [valid_count, _max_select]
	)
	_cancel_button.visible = _can_cancel


func _on_option_pressed(option_id: String) -> void:
	if _max_select == 1 and _min_select == 1:
		option_chosen.emit(option_id)
		return
	option_toggled.emit(option_id)


func _option_label(
	option: Dictionary,
	descriptor: AttachmentVisualDescriptor = null,
) -> String:
	if descriptor == null:
		descriptor = _attachment_descriptor(option)
	var fallback_name: String = str(option.get("label", "能量"))
	var energy_name: String = (
		descriptor.display_name
		if descriptor != null and descriptor.has_known_identity
		else fallback_name
	)
	var index: int = descriptor.first_physical_index() if descriptor != null else -1
	return "%s · 第%d张" % [energy_name, index + 1] if index >= 0 else energy_name


func _option_icon(option: Dictionary) -> Texture2D:
	var descriptor: AttachmentVisualDescriptor = _attachment_descriptor(option)
	return descriptor.icon if descriptor != null else null


func _attachment_descriptor(option: Dictionary) -> AttachmentVisualDescriptor:
	var ref: Dictionary = _attachment_ref(option)
	return ATTACHMENT_VISUALS.resolve(
		str(ref.get("attachment_type", ref.get("type", "energy"))),
		str(ref.get("card_id", "")),
		int(ref.get("index", -1)),
		_catalog,
	)


func _attachment_ref(option: Dictionary) -> Dictionary:
	var ref_value: Variant = option.get("ref")
	return ATTACHMENT_VISUALS.canonical_ref(ref_value)


func _reposition() -> void:
	if not visible or _panel == null:
		return
	var safe := _safe_rect
	var owner := get_parent()
	if owner != null and owner.has_method("_safe_popover_rect"):
		var refreshed: Variant = owner.call("_safe_popover_rect")
		if refreshed is Rect2 and (refreshed as Rect2).size.x > 0.0:
			safe = refreshed as Rect2
	if safe.size.x <= 0.0 or safe.size.y <= 0.0:
		var viewport := get_viewport()
		safe = Rect2(Vector2.ZERO, Vector2(viewport.size) if viewport else size)
	_safe_rect = safe
	_compact = safe.size.x < 960.0 or safe.size.y <= 540.0
	if _compact:
		var panel_size := Vector2(
			maxf(240.0, safe.size.x - COMPACT_INSET * 2.0),
			minf(286.0, safe.size.y * 0.52),
		)
		_panel.size = panel_size
		_panel.global_position = Vector2(
			safe.position.x + (safe.size.x - panel_size.x) * 0.5,
			safe.end.y - panel_size.y - COMPACT_INSET,
		)
		_scroll.custom_minimum_size.y = minf(132.0, ROW_HEIGHT * minf(2.5, _options.size()))
		return
	var source_rect := _source_global_rect()
	var visible_rows := mini(4, maxi(1, _options.size()))
	var panel_size := Vector2(WIDE_WIDTH, 132.0 + float(visible_rows) * (ROW_HEIGHT + 4.0))
	panel_size.y = minf(panel_size.y, safe.size.y)
	var position := Vector2(
		source_rect.get_center().x - panel_size.x * 0.5,
		source_rect.position.y - panel_size.y - 10.0,
	)
	if position.y < safe.position.y:
		position.y = source_rect.end.y + 10.0
	position.x = clampf(position.x, safe.position.x, safe.end.x - panel_size.x)
	position.y = clampf(position.y, safe.position.y, safe.end.y - panel_size.y)
	_panel.size = panel_size
	_panel.global_position = position
	_scroll.custom_minimum_size.y = float(visible_rows) * (ROW_HEIGHT + 4.0)


func _source_global_rect() -> Rect2:
	if _source_ref == null:
		return Rect2()
	var source = _source_ref.get_ref()
	if not source is Control or not is_instance_valid(source):
		return Rect2()
	if source.has_method("visual_global_bounds"):
		return source.call("visual_global_bounds") as Rect2
	return (source as Control).get_global_rect()


func _play_open_motion() -> void:
	var duration := MotionPolicy.duration("panel")
	if duration <= 0.0 or MotionPolicy.reduced():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, duration).set_trans(
		Tween.TRANS_QUAD,
	).set_ease(Tween.EASE_OUT)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.034, 0.055, 0.083, 0.985)
	style.border_color = Color(0.91, 0.63, 0.18, 0.90)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.46)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 4)
	return style

class_name CardView
extends Control

signal activated(card_id: String, hand_index: int, player: int, slot: String)
signal detail_requested(card_id: String)
signal card_dropped(
	hand_index: int,
	card_id: String,
	target_player: int,
	target_slot: String,
)
signal action_requested(action: GameAction)

const LONG_PRESS_MSEC := 350
const DRAG_THRESHOLD := 14.0

var card_id := ""
var hand_index := -1
var owner_player := -1
var slot := ""
var target_player := -1
var target_slot := ""
var is_hidden_card := false
var empty := true
var selected := false
var targetable := false
var compact := false
var pokemon: PokemonState
var catalog: CardCatalog

var shadow: Panel
var frame: Panel
var image: TextureRect
var empty_label: Label
var info_panel: PanelContainer
var name_label: Label
var hp_bar: ProgressBar
var meta_label: Label
var status_row: HBoxContainer
var selection_ring: Panel
var target_glow: Panel
var action_overlay: PanelContainer
var action_buttons: VBoxContainer
var action_hint: Label

var _press_msec := 0
var _press_position := Vector2.ZERO
var _pressed := false
var _hovered := false
var _base_position := Vector2.ZERO
var _has_base_position := false
var _content_signature := ""
var _actions_signature := ""
var _pending_action_rows: Array[Dictionary] = []
var _pending_action_hint := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	_build()
	resized.connect(_on_resized)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_on_resized()
	_refresh()
	var pending_rows := _pending_action_rows.duplicate()
	var pending_hint := _pending_action_hint
	_actions_signature = ""
	set_actions(pending_rows, pending_hint)


func configure(
	p_card_id: String,
	p_pokemon: PokemonState = null,
	p_hidden: bool = false,
	p_hand_index: int = -1,
	p_player: int = -1,
	p_slot: String = "",
	p_compact: bool = false,
) -> void:
	var next_signature := _build_content_signature(
		p_card_id,
		p_pokemon,
		p_hidden,
		p_hand_index,
		p_player,
		p_slot,
		p_compact,
	)
	card_id = p_card_id
	pokemon = p_pokemon
	is_hidden_card = p_hidden
	hand_index = p_hand_index
	owner_player = p_player
	slot = p_slot
	compact = p_compact
	empty = card_id.is_empty() and not is_hidden_card
	if next_signature == _content_signature:
		return
	_content_signature = next_signature
	_refresh()


func set_catalog(value: CardCatalog) -> void:
	catalog = value


func set_actions(rows: Array[Dictionary], target_hint := "") -> void:
	_pending_action_rows = rows.duplicate()
	_pending_action_hint = target_hint
	if not is_node_ready() or action_overlay == null or action_buttons == null:
		return
	var signature_parts: Array[String] = [target_hint]
	for row in rows:
		var action: GameAction = row.get("action")
		signature_parts.append("%s:%s" % [
			JSON.stringify(action.to_dict()) if action else "",
			str(row.get("label", action.action if action else "")),
		])
	var signature := "|".join(signature_parts)
	if signature == _actions_signature:
		action_overlay.visible = selected and (
			not rows.is_empty() or not target_hint.is_empty()
		)
		return
	_actions_signature = signature
	for child in action_buttons.get_children():
		action_buttons.remove_child(child)
		child.free()
	action_hint.text = target_hint
	action_hint.visible = not target_hint.is_empty()
	var shown := 0
	for row in rows:
		if shown >= 3:
			break
		var action: GameAction = row.get("action")
		if action == null:
			continue
		var button := Button.new()
		button.text = str(row.get("label", action.action))
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.custom_minimum_size.y = 30
		button.add_theme_font_size_override("font_size", 11)
		button.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color(0.035, 0.075, 0.12, 0.96),
				7,
				DesignTokens.CYAN,
				1,
				0,
			),
		)
		button.pressed.connect(action_requested.emit.bind(action))
		action_buttons.add_child(button)
		shown += 1
	var overlay_height := 8.0 + float(shown) * 33.0
	if not target_hint.is_empty():
		overlay_height += 27.0
	action_overlay.offset_top = -maxf(40.0, overlay_height)
	action_overlay.visible = selected and (
		shown > 0 or not target_hint.is_empty()
	)


func configure_target(player: int, target_slot_value: String) -> void:
	target_player = player
	target_slot = target_slot_value


func set_selected(value: bool) -> void:
	selected = value
	if selection_ring:
		selection_ring.visible = value
	_update_lift()


func set_targetable(value: bool) -> void:
	targetable = value
	if target_glow:
		target_glow.visible = value


func set_empty_label(text: String) -> void:
	if empty_label:
		empty_label.text = text


func global_center() -> Vector2:
	return global_position + size * 0.5


func flash(color: Color, duration: float = 0.3) -> void:
	if frame == null:
		return
	var overlay := ColorRect.new()
	overlay.color = Color(color.r, color.g, color.b, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 0.58, duration * 0.28)
	tween.tween_property(overlay, "color:a", 0.0, duration * 0.72)
	tween.tween_callback(overlay.queue_free)


func shake(strength: float = 7.0, duration: float = 0.26) -> void:
	var origin := position
	var tween := create_tween()
	for offset in [
		Vector2(strength, 0),
		Vector2(-strength, 0),
		Vector2(strength * 0.65, 0),
		Vector2(-strength * 0.65, 0),
		Vector2.ZERO,
	]:
		tween.tween_property(
			self,
			"position",
			origin + offset,
			duration / 5.0,
		)


func _build() -> void:
	shadow = Panel.new()
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.add_theme_stylebox_override("panel", DesignTokens.shadow_style(10))
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.position += Vector2(0, 4)
	add_child(shadow)

	frame = Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(frame)

	image = TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.offset_left = 3
	image.offset_top = 3
	image.offset_right = -3
	image.offset_bottom = -3
	frame.add_child(image)

	empty_label = Label.new()
	empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	empty_label.text = "空位"
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	empty_label.add_theme_font_size_override("font_size", 15)
	empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(empty_label)

	info_panel = PanelContainer.new()
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.025, 0.045, 0.075, 0.9),
			8,
			Color.TRANSPARENT,
			0,
			5,
		),
	)
	info_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	info_panel.offset_top = -54
	frame.add_child(info_panel)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 1)
	info_panel.add_child(info)
	name_label = Label.new()
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", DesignTokens.TEXT)
	info.add_child(name_label)
	hp_bar = ProgressBar.new()
	hp_bar.custom_minimum_size.y = 5
	hp_bar.show_percentage = false
	hp_bar.add_theme_stylebox_override(
		"background",
		DesignTokens.panel_style(Color("#253247"), 3, Color.TRANSPARENT, 0, 0),
	)
	hp_bar.add_theme_stylebox_override(
		"fill",
		DesignTokens.panel_style(DesignTokens.GREEN, 3, Color.TRANSPARENT, 0, 0),
	)
	info.add_child(hp_bar)
	meta_label = Label.new()
	meta_label.add_theme_font_size_override("font_size", 11)
	meta_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	meta_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	info.add_child(meta_label)

	status_row = HBoxContainer.new()
	status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_row.add_theme_constant_override("separation", 3)
	status_row.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	status_row.position = Vector2(-6, 6)
	frame.add_child(status_row)

	target_glow = Panel.new()
	target_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_glow.visible = false
	target_glow.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.25, 0.72, 1.0, 0.11),
			11,
			DesignTokens.CYAN,
			3,
			0,
		),
	)
	target_glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(target_glow)

	selection_ring = Panel.new()
	selection_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	selection_ring.visible = false
	selection_ring.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(1.0, 0.82, 0.25, 0.08),
			11,
			DesignTokens.GOLD,
			3,
			0,
		),
	)
	selection_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(selection_ring)

	action_overlay = PanelContainer.new()
	action_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	action_overlay.visible = false
	action_overlay.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.018, 0.035, 0.065, 0.92),
			9,
			DesignTokens.GOLD,
			1,
			2,
		),
	)
	action_overlay.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	action_overlay.offset_left = 5
	action_overlay.offset_right = -5
	action_overlay.offset_bottom = -5
	var action_margin := MarginContainer.new()
	action_margin.add_theme_constant_override("margin_left", 4)
	action_margin.add_theme_constant_override("margin_right", 4)
	action_margin.add_theme_constant_override("margin_top", 4)
	action_margin.add_theme_constant_override("margin_bottom", 4)
	action_overlay.add_child(action_margin)
	var action_content := VBoxContainer.new()
	action_content.add_theme_constant_override("separation", 3)
	action_margin.add_child(action_content)
	action_hint = Label.new()
	action_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	action_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_hint.add_theme_font_size_override("font_size", 10)
	action_hint.add_theme_color_override("font_color", DesignTokens.GOLD)
	action_content.add_child(action_hint)
	action_buttons = VBoxContainer.new()
	action_buttons.add_theme_constant_override("separation", 3)
	action_content.add_child(action_buttons)
	add_child(action_overlay)


func _refresh() -> void:
	if not is_node_ready():
		return
	var frame_color := Color("#15253a")
	var border_color := DesignTokens.BORDER
	if is_hidden_card:
		image.texture = CardTextureCache.get_texture("res://assets/cards/card_back.webp")
		empty_label.visible = false
		info_panel.visible = false
		frame_color = Color("#15284e")
		border_color = DesignTokens.GOLD.darkened(0.3)
	elif empty:
		image.texture = null
		empty_label.visible = true
		info_panel.visible = false
		frame_color = Color(0.04, 0.10, 0.08, 0.42)
		border_color = Color(0.30, 0.58, 0.42, 0.52)
	else:
		var card := CardDatabase.get_card(card_id)
		image.texture = CardTextureCache.get_texture(str(card.get("image_path", "")))
		empty_label.visible = image.texture == null
		empty_label.text = str(card.get("name", card_id))
		info_panel.visible = pokemon != null and not compact
		name_label.text = str(card.get("name", card_id))
		var energy_types: Array = card.get("energy_types", [])
		if not energy_types.is_empty():
			border_color = DesignTokens.type_color(str(energy_types[0]))
		if pokemon:
			var maximum := maxi(1, int(card.get("hp", 1)))
			var current := pokemon.current_hp(catalog) if catalog else maximum - (
				pokemon.damage_counters * 10
			)
			hp_bar.max_value = maximum
			hp_bar.value = current
			var hp_ratio := float(current) / float(maximum)
			var hp_color := (
				DesignTokens.GREEN
				if hp_ratio > 0.55
				else DesignTokens.GOLD
				if hp_ratio > 0.25
				else DesignTokens.RED
			)
			hp_bar.add_theme_stylebox_override(
				"fill",
				DesignTokens.panel_style(hp_color, 3, Color.TRANSPARENT, 0, 0),
			)
			meta_label.text = "HP %d/%d  ·  ◈%d%s" % [
				current,
				maximum,
				pokemon.energy_card_ids.size(),
				"  ·  道具" if not pokemon.attached_tool_id.is_empty() else "",
			]
			_refresh_statuses()
	frame.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(frame_color, 11, border_color, 2, 0),
	)


func _refresh_statuses() -> void:
	for child in status_row.get_children():
		child.queue_free()
	if pokemon == null:
		return
	for status in pokemon.status_conditions:
		var badge := Label.new()
		badge.text = {
			"POISONED": "毒",
			"BURNED": "灼",
			"ASLEEP": "眠",
			"PARALYZED": "麻",
			"CONFUSED": "乱",
		}.get(status, str(status).left(1))
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.custom_minimum_size = Vector2(22, 22)
		badge.add_theme_font_size_override("font_size", 11)
		badge.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
		badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.status_color(status),
				11,
				Color.TRANSPARENT,
				0,
				0,
			),
		)
		status_row.add_child(badge)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_press_msec = Time.get_ticks_msec()
			_press_position = event.position
			accept_event()
		else:
			if not _pressed:
				return
			_pressed = false
			var held := Time.get_ticks_msec() - _press_msec
			var moved: float = Vector2(event.position).distance_to(_press_position)
			if held >= LONG_PRESS_MSEC and not card_id.is_empty():
				detail_requested.emit(card_id)
			elif moved < DRAG_THRESHOLD:
				activated.emit(card_id, hand_index, owner_player, slot)
			accept_event()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_pressed = true
			_press_msec = Time.get_ticks_msec()
			_press_position = event.position
		else:
			if not _pressed:
				return
			_pressed = false
			var held := Time.get_ticks_msec() - _press_msec
			var moved: float = Vector2(event.position).distance_to(_press_position)
			if held >= LONG_PRESS_MSEC and not card_id.is_empty():
				detail_requested.emit(card_id)
			elif moved < DRAG_THRESHOLD:
				activated.emit(card_id, hand_index, owner_player, slot)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if hand_index < 0 or card_id.is_empty():
		return null
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(98, 138)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = image.texture
	preview.modulate = Color(1, 1, 1, 0.92)
	set_drag_preview(preview)
	return {
		"kind": "hand_card",
		"hand_index": hand_index,
		"card_id": card_id,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return (
		not target_slot.is_empty()
		and data is Dictionary
		and str(data.get("kind", "")) == "hand_card"
	)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(Vector2.ZERO, data):
		return
	card_dropped.emit(
		int(data.get("hand_index", -1)),
		str(data.get("card_id", "")),
		target_player,
		target_slot,
	)


func _on_resized() -> void:
	pivot_offset = size * 0.5
	if info_panel:
		info_panel.offset_top = -54
		info_panel.offset_bottom = -3
		info_panel.offset_left = 3
		info_panel.offset_right = -3


func _on_mouse_entered() -> void:
	_hovered = true
	_update_lift()


func _on_mouse_exited() -> void:
	_hovered = false
	_pressed = false
	_update_lift()


func _update_lift() -> void:
	if not is_inside_tree() or not _has_base_position:
		return
	var desired_scale := Vector2.ONE
	var desired_y := _base_position.y
	if selected:
		desired_scale = Vector2(1.06, 1.06)
		desired_y -= 12.0
	elif _hovered:
		desired_scale = Vector2(1.035, 1.035)
		desired_y -= 6.0
	if action_overlay:
		action_overlay.visible = selected and (
			action_buttons.get_child_count() > 0 or action_hint.visible
		)
	if AppSettings.reduced_motion:
		scale = desired_scale
		position.y = desired_y
		return
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", desired_scale, 0.12)
	tween.tween_property(self, "position:y", desired_y, 0.12)


func remember_base_position() -> void:
	_base_position = position
	_has_base_position = true
	_update_lift()


func _build_content_signature(
	p_card_id: String,
	p_pokemon: PokemonState,
	p_hidden: bool,
	p_hand_index: int,
	p_player: int,
	p_slot: String,
	p_compact: bool,
) -> String:
	var pokemon_signature := ""
	if p_pokemon:
		pokemon_signature = "%s:%d:%s:%s:%s" % [
			p_pokemon.card_id,
			p_pokemon.damage_counters,
			",".join(p_pokemon.energy_card_ids),
			p_pokemon.attached_tool_id,
			",".join(p_pokemon.status_conditions),
		]
	return "%s|%s|%s|%d|%d|%s|%s" % [
		p_card_id,
		pokemon_signature,
		str(p_hidden),
		p_hand_index,
		p_player,
		p_slot,
		str(p_compact),
	]

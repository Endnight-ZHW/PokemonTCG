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

@export_category("Card Layout")
@export var selected_lift := 12.0
@export var hover_lift := 6.0
@export var selected_scale := 1.06
@export var hover_scale := 1.035
@export var interaction_duration := 0.12
@export_category("Action Overlay")
@export_range(1, 5, 1) var maximum_action_buttons := 3

const ENERGY_LABELS := {
	"Grass": "G",
	"Fire": "F",
	"Water": "W",
	"Lightning": "L",
	"Psychic": "P",
	"Fighting": "F",
	"Darkness": "D",
	"Metal": "M",
	"Dragon": "D",
	"Colorless": "C",
	"Rainbow": "R",
	"Special": "SP",
}

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

@onready var shadow: Panel = %Shadow
@onready var frame: Panel = %Frame
@onready var image: TextureRect = %Image
@onready var empty_label: Label = %EmptyLabel
@onready var status_row: HBoxContainer = %StatusRow
@onready var selection_ring: Panel = %SelectionRing
@onready var target_glow: Panel = %TargetGlow
@onready var action_overlay: PanelContainer = %ActionOverlay
@onready var action_buttons: VBoxContainer = %ActionButtons
@onready var action_hint: Label = %ActionHint
@onready var animation_player: AnimationPlayer = %AnimationPlayer

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
var _presentation_hidden := false
var _presentation_tween: Tween
var _table_depth := 0.5
var _near_side := true
var depth_edge: Panel
var top_gloss: ColorRect
var hp_pill: Label
var damage_badge: Label
var energy_row: HBoxContainer
var tool_badge: Label
var _empty_slot_label_text := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	_resolve_scene_nodes()
	_ensure_overlay_nodes()
	resized.connect(_on_resized)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_on_resized()
	_refresh()
	selection_ring.visible = selected
	target_glow.visible = targetable
	_refresh_state_animation()
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


func set_table_depth(value: float, near_side: bool = true) -> void:
	_table_depth = clampf(value, 0.0, 1.0)
	_near_side = near_side
	_resolve_scene_nodes()
	_apply_depth_visuals()
	_layout_battle_overlay()


func set_actions(rows: Array[Dictionary], target_hint := "") -> void:
	_pending_action_rows = rows.duplicate()
	_pending_action_hint = target_hint
	_resolve_scene_nodes()
	if action_overlay == null or action_buttons == null:
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
		child.queue_free()
	action_hint.text = target_hint
	action_hint.visible = not target_hint.is_empty()
	var shown := 0
	for row in rows:
		if shown >= maximum_action_buttons:
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
	_refresh_state_animation()
	_refresh_empty_slot_visibility()
	_update_lift()


func set_targetable(value: bool) -> void:
	targetable = value
	if target_glow:
		target_glow.visible = value
	_refresh_state_animation()
	_refresh_empty_slot_visibility()


func set_empty_label(text: String) -> void:
	_empty_slot_label_text = text
	if empty_label:
		empty_label.text = text
	_refresh_empty_slot_visibility()


func set_presentation_hidden(value: bool) -> void:
	_presentation_hidden = value
	_kill_presentation_tween()
	modulate.a = 0.0 if value else 1.0


func reveal_presentation(duration: float = 0.14, delay: float = 0.0) -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	if duration <= 0.0:
		modulate.a = 1.0
		return
	_presentation_tween = create_tween()
	if delay > 0.0:
		_presentation_tween.tween_interval(delay)
	_presentation_tween.tween_property(self, "modulate:a", 1.0, duration)


func clear_presentation_state() -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	modulate.a = 1.0


func is_presentation_hidden() -> bool:
	return _presentation_hidden


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


func _refresh() -> void:
	_resolve_scene_nodes()
	if frame == null or image == null or empty_label == null:
		return
	_ensure_overlay_nodes()
	frame.modulate.a = 1.0
	if shadow:
		shadow.modulate.a = 1.0
	if depth_edge:
		depth_edge.modulate.a = 1.0
	_refresh_statuses()
	var frame_color := Color("#15253a")
	var border_color := DesignTokens.BORDER
	var current_card := {}
	if is_hidden_card:
		image.texture = _card_texture("res://assets/cards/card_back.webp")
		empty_label.visible = false
		frame_color = Color("#15284e")
		border_color = DesignTokens.GOLD.darkened(0.3)
		_refresh_battle_overlay({}, border_color)
	elif empty:
		image.texture = null
		empty_label.visible = not _is_field_empty_slot()
		if _is_field_empty_slot():
			frame_color = Color(0.02, 0.05, 0.04, 0.03)
			border_color = Color(0.30, 0.80, 0.55, 0.10)
		else:
			frame_color = Color(0.025, 0.07, 0.055, 0.30)
			border_color = Color(0.30, 0.66, 0.45, 0.34)
		_refresh_battle_overlay({}, border_color)
	else:
		var card := _card_data(card_id)
		current_card = card
		image.texture = _card_texture(str(card.get("image_path", "")))
		empty_label.visible = image.texture == null
		empty_label.text = str(card.get("name", card_id))
		var energy_types: Array = card.get("energy_types", [])
		if not energy_types.is_empty():
			border_color = DesignTokens.type_color(str(energy_types[0]))
		_refresh_battle_overlay(current_card, border_color)
	frame.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(frame_color, 9, border_color, 2, 0),
	)
	_refresh_empty_slot_visibility()
	_apply_depth_visuals()


func _refresh_statuses() -> void:
	_resolve_scene_nodes()
	if status_row == null:
		return
	for child in status_row.get_children():
		status_row.remove_child(child)
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
		badge.custom_minimum_size = Vector2(24, 22)
		badge.add_theme_font_size_override("font_size", 12)
		badge.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
		badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.status_color(status),
				7,
				Color(1, 1, 1, 0.52),
				1,
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
	_layout_battle_overlay()
	_apply_depth_visuals()


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
		desired_scale = Vector2.ONE * selected_scale
		desired_y -= selected_lift
	elif _hovered:
		desired_scale = Vector2.ONE * hover_scale
		desired_y -= hover_lift
	if action_overlay:
		action_overlay.visible = selected and (
			action_buttons.get_child_count() > 0 or action_hint.visible
		)
	if _reduced_motion_enabled():
		scale = desired_scale
		position.y = desired_y
		return
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", desired_scale, interaction_duration)
	tween.tween_property(self, "position:y", desired_y, interaction_duration)


func remember_base_position() -> void:
	_base_position = position
	_has_base_position = true
	_update_lift()


func _refresh_state_animation() -> void:
	if animation_player == null and has_node("AnimationPlayer"):
		animation_player = get_node("AnimationPlayer") as AnimationPlayer
	if animation_player == null:
		return
	animation_player.stop()
	if _reduced_motion_enabled():
		animation_player.play("RESET")
		return
	if selected:
		animation_player.play("selected_pulse")
	elif targetable:
		animation_player.play("target_pulse")
	else:
		animation_player.play("RESET")


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


func _resolve_scene_nodes() -> void:
	if shadow == null:
		shadow = get_node_or_null("Shadow") as Panel
	if frame == null:
		frame = get_node_or_null("Frame") as Panel
	if image == null:
		image = get_node_or_null("Frame/Image") as TextureRect
	if empty_label == null:
		empty_label = get_node_or_null("Frame/EmptyLabel") as Label
	if status_row == null:
		status_row = get_node_or_null("Frame/StatusRow") as HBoxContainer
	if selection_ring == null:
		selection_ring = get_node_or_null("SelectionRing") as Panel
	if target_glow == null:
		target_glow = get_node_or_null("TargetGlow") as Panel
	if action_overlay == null:
		action_overlay = get_node_or_null("ActionOverlay") as PanelContainer
	if action_buttons == null:
		action_buttons = get_node_or_null(
			"ActionOverlay/Margin/Content/ActionButtons"
		) as VBoxContainer
	if action_hint == null:
		action_hint = get_node_or_null(
			"ActionOverlay/Margin/Content/ActionHint"
		) as Label
	if animation_player == null:
		animation_player = get_node_or_null("AnimationPlayer") as AnimationPlayer


func _ensure_overlay_nodes() -> void:
	if depth_edge != null:
		return
	depth_edge = Panel.new()
	depth_edge.name = "DepthEdge"
	depth_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	depth_edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	depth_edge.z_index = -1
	add_child(depth_edge)
	move_child(depth_edge, 1)

	top_gloss = ColorRect.new()
	top_gloss.name = "TopGloss"
	top_gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_gloss.color = Color(1, 1, 1, 0.09)
	top_gloss.z_index = 3
	add_child(top_gloss)

	hp_pill = _new_overlay_label("HPPill")
	hp_pill.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_pill.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_pill.z_index = 8
	add_child(hp_pill)

	damage_badge = _new_overlay_label("DamageBadge")
	damage_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	damage_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	damage_badge.z_index = 9
	add_child(damage_badge)

	energy_row = HBoxContainer.new()
	energy_row.name = "EnergyRow"
	energy_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	energy_row.add_theme_constant_override("separation", 2)
	energy_row.z_index = 8
	add_child(energy_row)

	tool_badge = _new_overlay_label("ToolBadge")
	tool_badge.text = "TOOL"
	tool_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tool_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tool_badge.z_index = 8
	add_child(tool_badge)


func _new_overlay_label(node_name: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _is_field_empty_slot() -> bool:
	return empty and not slot.is_empty() and not is_hidden_card


func _refresh_empty_slot_visibility() -> void:
	if empty_label == null or frame == null:
		return
	if not _is_field_empty_slot():
		if shadow:
			shadow.modulate.a = 1.0
		if depth_edge:
			depth_edge.modulate.a = 1.0
		return
	var show_hint := selected or targetable
	empty_label.text = _empty_slot_label_text if show_hint else ""
	empty_label.visible = show_hint
	if show_hint:
		empty_label.add_theme_color_override("font_color", DesignTokens.CYAN)
	var alpha := 0.76 if targetable else 0.46 if selected else 0.0
	frame.modulate.a = alpha
	if shadow:
		shadow.modulate.a = 0.30 if show_hint else 0.0
	if depth_edge:
		depth_edge.modulate.a = alpha


func _refresh_battle_overlay(card: Dictionary, border_color: Color) -> void:
	if hp_pill == null or damage_badge == null or energy_row == null or tool_badge == null:
		return
	var show_overlay := pokemon != null and not compact and not empty and not is_hidden_card
	hp_pill.visible = show_overlay
	damage_badge.visible = false
	energy_row.visible = show_overlay
	tool_badge.visible = false
	top_gloss.visible = not empty
	if not show_overlay:
		_clear_energy_badges()
		return
	var maximum := _pokemon_max_hp(card, pokemon)
	var current := pokemon.current_hp(catalog) if catalog else maximum - (
		pokemon.damage_counters * 10
	)
	var hp_ratio := float(current) / float(maxi(1, maximum))
	var hp_color := (
		DesignTokens.GREEN
		if hp_ratio > 0.55
		else DesignTokens.GOLD
		if hp_ratio > 0.25
		else DesignTokens.RED
	)
	hp_pill.text = "HP%d" % current
	hp_pill.tooltip_text = "HP %d/%d" % [current, maximum]
	hp_pill.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
	hp_pill.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(hp_color, 8, Color(1, 1, 1, 0.78), 1, 0),
	)
	var damage := pokemon.damage_counters * 10
	if damage > 0:
		damage_badge.visible = true
		damage_badge.text = "%d" % damage
		damage_badge.tooltip_text = "%d damage" % damage
		damage_badge.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
		damage_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.RED.lightened(0.16),
				12,
				Color(1, 1, 1, 0.72),
				1,
				0,
			),
		)
	_refresh_energy_badges()
	if not pokemon.attached_tool_id.is_empty():
		tool_badge.visible = true
		tool_badge.tooltip_text = "Tool: %s" % _card_data(
			pokemon.attached_tool_id
		).get("name", pokemon.attached_tool_id)
		tool_badge.add_theme_color_override("font_color", DesignTokens.TEXT)
		tool_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color("#213146"),
				6,
				border_color.lightened(0.25),
				1,
				0,
			),
		)
	_layout_battle_overlay()


func _refresh_energy_badges() -> void:
	_clear_energy_badges()
	if pokemon == null:
		return
	var grouped := _attached_energy_groups()
	for row_value in grouped:
		var row: Dictionary = row_value
		var energy_type := str(row.get("type", "Colorless"))
		var count := int(row.get("count", 1))
		var badge := Label.new()
		badge.name = "EnergyBadge"
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		badge.custom_minimum_size = Vector2(24, 24)
		badge.text = _energy_label(energy_type, count)
		badge.tooltip_text = "%s energy x%d" % [energy_type, count]
		badge.add_theme_font_size_override("font_size", 11)
		badge.add_theme_color_override("font_color", _energy_font_color(energy_type))
		badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				_energy_color(energy_type),
				12,
				Color(1, 1, 1, 0.70),
				1,
				0,
			),
		)
		energy_row.add_child(badge)


func _clear_energy_badges() -> void:
	if energy_row == null:
		return
	for child in energy_row.get_children():
		energy_row.remove_child(child)
		child.queue_free()


func _attached_energy_groups() -> Array[Dictionary]:
	var counts := {}
	for energy_id in pokemon.energy_card_ids:
		var provided := catalog.provides_energy(energy_id) if catalog else []
		var card := catalog.get_card(energy_id) if catalog else {}
		var energy_type := "Special" if "Special" in card.get("subtypes", []) else "Colorless"
		if not provided.is_empty():
			energy_type = str(provided[0])
		if not counts.has(energy_type):
			counts[energy_type] = 0
		counts[energy_type] += 1
	var result: Array[Dictionary] = []
	for energy_type in counts.keys():
		result.append({
			"type": str(energy_type),
			"count": int(counts[energy_type]),
		})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return str(left.get("type", "")) < str(right.get("type", ""))
	)
	return result


func _energy_label(energy_type: String, count: int) -> String:
	var prefix := str(ENERGY_LABELS.get(energy_type, energy_type.left(1).to_upper()))
	return prefix if count <= 1 else "%s%d" % [prefix, count]


func _energy_color(energy_type: String) -> Color:
	if energy_type == "Rainbow":
		return Color("#f4c84a")
	if energy_type == "Special":
		return Color("#7a87a8")
	return DesignTokens.type_color(energy_type)


func _energy_font_color(energy_type: String) -> Color:
	return DesignTokens.BG_DEEP if energy_type in [
		"Grass", "Fire", "Water", "Lightning", "Fighting", "Colorless", "Rainbow",
	] else DesignTokens.TEXT


func _pokemon_max_hp(card: Dictionary, pokemon_value: PokemonState) -> int:
	var maximum := maxi(1, int(card.get("hp", 1)))
	if pokemon_value == null or catalog == null:
		return maximum
	if not pokemon_value.attached_tool_id.is_empty():
		for effect in catalog.get_card(
			pokemon_value.attached_tool_id
		).get("trainer_effects", []):
			if (
				effect.get("params", {}).get("effect", "") == "hp_boost_basic"
				and catalog.is_basic_pokemon(pokemon_value.card_id)
			):
				maximum += 50
	return maximum


func _layout_battle_overlay() -> void:
	if hp_pill == null:
		return
	var badge_scale := clampf(size.x / 130.0, 0.68, 1.06)
	var hp_size := Vector2(58, 24) * badge_scale
	hp_pill.position = Vector2(size.x - hp_size.x - 5.0, 4.0)
	hp_pill.size = hp_size
	hp_pill.add_theme_font_size_override("font_size", int(17 * badge_scale))
	var damage_size := Vector2(30, 30) * badge_scale
	damage_badge.position = Vector2(
		size.x - damage_size.x - 3.0,
		size.y * 0.42,
	)
	damage_badge.size = damage_size
	damage_badge.add_theme_font_size_override("font_size", int(14 * badge_scale))
	energy_row.position = Vector2(5.0, size.y - 26.0 * badge_scale)
	energy_row.size = Vector2(size.x - 10.0, 25.0 * badge_scale)
	tool_badge.position = Vector2(5.0, 5.0)
	tool_badge.size = Vector2(42.0 * badge_scale, 20.0 * badge_scale)
	tool_badge.add_theme_font_size_override("font_size", int(10 * badge_scale))
	status_row.offset_left = -6.0
	status_row.offset_top = 6.0
	status_row.offset_right = -6.0
	if top_gloss:
		top_gloss.position = Vector2(5.0, 5.0)
		top_gloss.size = Vector2(maxf(0.0, size.x - 10.0), maxf(4.0, size.y * 0.18))


func _apply_depth_visuals() -> void:
	if shadow:
		var shadow_drop := 4.0 + _table_depth * 7.0
		shadow.offset_left = 1.0 + _table_depth * 1.5
		shadow.offset_top = shadow_drop
		shadow.offset_right = 2.0 + _table_depth * 2.0
		shadow.offset_bottom = shadow_drop + 2.0
	if depth_edge:
		var edge := 2.0 + _table_depth * 4.0
		depth_edge.offset_left = edge
		depth_edge.offset_top = edge
		depth_edge.offset_right = edge + 1.0
		depth_edge.offset_bottom = edge + 1.0
		depth_edge.add_theme_stylebox_override(
			"panel",
			DesignTokens.panel_style(
				Color(0, 0, 0, 0.30 + _table_depth * 0.18),
				9,
				Color(0, 0, 0, 0.0),
				0,
				0,
			),
		)


func _kill_presentation_tween() -> void:
	if _presentation_tween and _presentation_tween.is_valid():
		_presentation_tween.kill()
	_presentation_tween = null


func _card_data(value: String) -> Dictionary:
	var database := _root_child("CardDatabase")
	if database and database.has_method("get_card"):
		return database.call("get_card", value)
	if catalog:
		return catalog.get_card(value)
	return {}


func _card_texture(path: String) -> Texture2D:
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


func _reduced_motion_enabled() -> bool:
	var settings := _root_child("AppSettings")
	return bool(settings.get("reduced_motion")) if settings else false


func _root_child(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)

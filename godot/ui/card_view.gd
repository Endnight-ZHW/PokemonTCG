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
signal drag_started(hand_index: int)
signal drag_ended

const LONG_PRESS_MSEC := 350
const DRAG_THRESHOLD := 14.0
const ENERGY_ICONS := preload("res://ui/energy_icon_catalog.gd")

@export_category("Card Layout")
@export var selected_lift := 12.0
@export var hover_lift := 6.0
@export var selected_scale := 1.06
@export var hover_scale := 1.035
@export var interaction_duration := 0.12

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

const ENERGY_DISPLAY_NAMES := {
	"Grass": "草能量",
	"Fire": "火能量",
	"Water": "水能量",
	"Lightning": "雷能量",
	"Psychic": "超能能量",
	"Fighting": "斗能量",
	"Darkness": "恶能量",
	"Metal": "钢能量",
	"Dragon": "龙能量",
	"Colorless": "无色能量",
	"Rainbow": "彩虹能量",
	"Special": "特殊能量",
}

const MAXIMUM_ENERGY_BADGES := 4
const MINIMUM_ENERGY_BADGE_SIZE := 18.0
const DEFAULT_ENERGY_BADGE_SIZE := 24.0
const ENERGY_BADGE_SEPARATION := 2.0

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
var actionable := false
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
@onready var actionable_marker: Panel = %ActionableMarker
@onready var interaction_hint: Panel = %InteractionHint
@onready var interaction_hint_label: Label = %InteractionHintLabel
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
var _pending_action_rows: Array[Dictionary] = []
var _pending_action_hint := ""
var _disabled_reason := ""
var _legal_target_hint := ""
var _allowed_drop_hand_indices: Array[int] = []
var _dragging := false
var _presentation_hidden := false
var _presentation_tween: Tween
var _lift_tween: Tween
var _shake_tween: Tween
var _flash_overlays: Array[ColorRect] = []
var _table_depth := 0.5
var _near_side := true
var depth_edge: Panel
var top_gloss: ColorRect
var hp_pill: Label
var damage_badge: Label
var energy_row: HBoxContainer
var tool_badge: Label
var _empty_slot_label_text := ""
var _texture_cache: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE
	_resolve_scene_nodes()
	_normalize_interaction_overlay_z_order()
	_ensure_overlay_nodes()
	resized.connect(_on_resized)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_on_resized()
	_refresh()
	selection_ring.visible = selected
	target_glow.visible = targetable
	_refresh_interaction_visuals()
	_refresh_state_animation()
	_disable_legacy_action_overlay()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _dragging:
		_dragging = false
		drag_ended.emit()


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
	clear_interaction_state()
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
	# Compatibility shim. Card actions now live in the battle-table popover, never
	# inside CardView: child controls here would change the card's minimum size.
	_pending_action_rows = rows.duplicate()
	_pending_action_hint = target_hint
	_resolve_scene_nodes()
	_disable_legacy_action_overlay()


func configure_target(player: int, target_slot_value: String) -> void:
	if target_player != player or target_slot != target_slot_value:
		_legal_target_hint = ""
		_allowed_drop_hand_indices.clear()
		set_targetable(false)
	target_player = player
	target_slot = target_slot_value
	_refresh_interaction_visuals()


func set_interaction_state(
	p_actionable: bool,
	disabled_reason := "",
	legal_target_hint := "",
	allowed_hand_indices: Array = [],
) -> void:
	# Read-only presentation state supplied by the interaction router. CardView
	# visualizes legality but never derives or executes a game action itself.
	actionable = p_actionable
	_disabled_reason = disabled_reason
	_legal_target_hint = legal_target_hint
	_replace_allowed_drop_hand_indices(allowed_hand_indices)
	set_targetable(
		not _legal_target_hint.is_empty()
		or not _allowed_drop_hand_indices.is_empty()
	)
	_refresh_interaction_visuals()


func set_actionable(value: bool, disabled_reason := "") -> void:
	actionable = value
	_disabled_reason = disabled_reason
	_refresh_interaction_visuals()


func is_actionable() -> bool:
	return actionable


func set_disabled_reason(reason: String) -> void:
	_disabled_reason = reason
	_refresh_interaction_visuals()


func get_disabled_reason() -> String:
	return _disabled_reason


func set_legal_target_hint(text: String) -> void:
	_legal_target_hint = text
	set_targetable(
		not _legal_target_hint.is_empty()
		or not _allowed_drop_hand_indices.is_empty()
	)


func get_legal_target_hint() -> String:
	return _legal_target_hint


func set_allowed_drop_hand_indices(indices: Array) -> void:
	_replace_allowed_drop_hand_indices(indices)
	set_targetable(
		not _legal_target_hint.is_empty()
		or not _allowed_drop_hand_indices.is_empty()
	)


func get_allowed_drop_hand_indices() -> Array[int]:
	return _allowed_drop_hand_indices.duplicate()


func clear_interaction_state() -> void:
	actionable = false
	_disabled_reason = ""
	_legal_target_hint = ""
	_allowed_drop_hand_indices.clear()
	set_targetable(false)
	_refresh_interaction_visuals()


func set_selected(value: bool) -> void:
	selected = value
	if selection_ring:
		selection_ring.visible = value
	_refresh_state_animation()
	_refresh_empty_slot_visibility()
	_refresh_interaction_visuals()
	_update_lift()


func set_targetable(value: bool) -> void:
	targetable = value
	if not value:
		_legal_target_hint = ""
		_allowed_drop_hand_indices.clear()
	if target_glow:
		target_glow.visible = value
	_refresh_state_animation()
	_refresh_empty_slot_visibility()
	_refresh_interaction_visuals()


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
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = null
	_clear_flash_overlays()
	modulate.a = 1.0


func is_presentation_hidden() -> bool:
	return _presentation_hidden


func global_center() -> Vector2:
	return global_position + size * 0.5


func flash(color: Color, duration: float = 0.3) -> void:
	if frame == null:
		return
	var overlay := ColorRect.new()
	_flash_overlays.append(overlay)
	overlay.color = Color(color.r, color.g, color.b, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.z_index = 24
	add_child(overlay)
	if duration <= 0.0 or _reduced_motion_enabled():
		overlay.color.a = 0.34
		var instant_tween := create_tween()
		instant_tween.tween_property(overlay, "color:a", 0.0, 0.08)
		instant_tween.tween_callback(_dispose_flash_overlay.bind(overlay))
		return
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 0.58, duration * 0.28)
	tween.tween_property(overlay, "color:a", 0.0, duration * 0.72)
	tween.tween_callback(_dispose_flash_overlay.bind(overlay))


func shake(strength: float = 7.0, duration: float = 0.26) -> void:
	if _reduced_motion_enabled():
		return
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	var origin := position
	if _has_base_position:
		origin.x = _base_position.x
	position.x = origin.x
	_shake_tween = create_tween()
	for offset in [
		Vector2(strength, 0),
		Vector2(-strength, 0),
		Vector2(strength * 0.65, 0),
		Vector2(-strength * 0.65, 0),
		Vector2.ZERO,
	]:
		_shake_tween.tween_property(
			self,
			"position",
			origin + offset,
			duration / 5.0,
		)
	_shake_tween.tween_callback(func() -> void: _shake_tween = null)


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
	_dragging = true
	drag_started.emit(hand_index)
	return {
		"kind": "hand_card",
		"hand_index": hand_index,
		"card_id": card_id,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if (
		target_slot.is_empty()
		or not data is Dictionary
		or str(data.get("kind", "")) != "hand_card"
		or not data.has("hand_index")
	):
		return false
	var dropped_hand_index := int(data.get("hand_index", -1))
	return _allowed_drop_hand_indices.has(dropped_hand_index)


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
	if energy_row != null and energy_row.visible and pokemon != null:
		_refresh_energy_badges()
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
	if _reduced_motion_enabled():
		if _lift_tween and _lift_tween.is_valid():
			_lift_tween.kill()
		_lift_tween = null
		scale = desired_scale
		position.y = desired_y
		return
	if _lift_tween and _lift_tween.is_valid():
		_lift_tween.kill()
	_lift_tween = create_tween().set_parallel(true)
	_lift_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_lift_tween.tween_property(self, "scale", desired_scale, interaction_duration)
	_lift_tween.tween_property(self, "position:y", desired_y, interaction_duration)


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
	if actionable_marker == null:
		actionable_marker = get_node_or_null("ActionableMarker") as Panel
	if interaction_hint == null:
		interaction_hint = get_node_or_null("InteractionHint") as Panel
	if interaction_hint_label == null:
		interaction_hint_label = get_node_or_null(
			"InteractionHint/InteractionHintLabel"
		) as Label
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


func _replace_allowed_drop_hand_indices(indices: Array) -> void:
	_allowed_drop_hand_indices.clear()
	for value in indices:
		var index := int(value)
		if index < 0 or _allowed_drop_hand_indices.has(index):
			continue
		_allowed_drop_hand_indices.append(index)


func _normalize_interaction_overlay_z_order() -> void:
	# Keep every interaction outline in this CardView's effective Z layer. Scene
	# order still draws these nodes after Frame on their own card, while a sibling
	# CardView with a higher Z now covers the lower card and its outline together.
	for overlay: CanvasItem in [
		target_glow,
		selection_ring,
		actionable_marker,
		interaction_hint,
	]:
		if overlay == null:
			continue
		overlay.z_as_relative = true
		overlay.z_index = 0


func _disable_legacy_action_overlay() -> void:
	if action_buttons:
		for child in action_buttons.get_children():
			action_buttons.remove_child(child)
			child.queue_free()
		action_buttons.visible = false
	if action_hint:
		action_hint.text = ""
		action_hint.visible = false
	if action_overlay:
		action_overlay.visible = false
		action_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _refresh_interaction_visuals() -> void:
	_resolve_scene_nodes()
	# Only one card-outline state is shown at a time. A selected source stays gold,
	# a legal target uses the stronger cyan target treatment, and an otherwise
	# actionable card gets the quiet outer ring below.
	if selection_ring:
		selection_ring.visible = selected
	if target_glow:
		target_glow.visible = targetable and not selected
	var can_show_marker := (
		actionable
		and not empty
		and not is_hidden_card
		and not selected
		and not targetable
	)
	if actionable_marker:
		actionable_marker.visible = can_show_marker
		var actionable_style := DesignTokens.panel_style(
			Color.TRANSPARENT,
			13,
			Color(0.36, 0.88, 1.0, 0.98),
			3,
			0,
		)
		# The marker sits above the whole CardView so it must never paint its
		# center. Even a very low-alpha fill noticeably veils detailed card art.
		actionable_style.draw_center = false
		actionable_style.shadow_color = Color(0.20, 0.78, 1.0, 0.50)
		actionable_style.shadow_size = 5
		actionable_style.shadow_offset = Vector2.ZERO
		actionable_marker.add_theme_stylebox_override("panel", actionable_style)

	var hint_text := ""
	var hint_color := DesignTokens.GOLD
	if targetable and not selected:
		hint_text = (
			_legal_target_hint
			if not _legal_target_hint.is_empty()
			else "可放置"
			if not _allowed_drop_hand_indices.is_empty()
			else "可选择"
		)
		hint_color = DesignTokens.CYAN
	elif selected and not actionable and not _disabled_reason.is_empty():
		hint_text = _disabled_reason
	if interaction_hint:
		interaction_hint.visible = not hint_text.is_empty()
		interaction_hint.tooltip_text = hint_text
		interaction_hint.accessibility_name = hint_text
		interaction_hint.add_theme_stylebox_override(
			"panel",
			DesignTokens.panel_style(
				Color(0.018, 0.042, 0.07, 0.94),
				7,
				hint_color,
				1,
				0,
			),
		)
	if interaction_hint_label:
		interaction_hint_label.text = hint_text
		interaction_hint_label.add_theme_color_override("font_color", hint_color)


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
	energy_row.mouse_filter = Control.MOUSE_FILTER_PASS
	energy_row.add_theme_constant_override("separation", int(ENERGY_BADGE_SEPARATION))
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
		_set_energy_summary([])
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
		_set_energy_summary([])
		return
	var grouped := _attached_energy_groups()
	_set_energy_summary(grouped)
	if grouped.is_empty():
		return
	var available_width := maxf(0.0, size.x - 10.0)
	var capacity := clampi(
		int(floor(
			(available_width + ENERGY_BADGE_SEPARATION)
			/ (MINIMUM_ENERGY_BADGE_SIZE + ENERGY_BADGE_SEPARATION)
		)),
		1,
		MAXIMUM_ENERGY_BADGES,
	)
	var has_overflow := grouped.size() > capacity
	var visible_group_count := capacity - 1 if has_overflow else grouped.size()
	var slot_count := capacity if has_overflow else visible_group_count
	var badge_size := minf(
		DEFAULT_ENERGY_BADGE_SIZE,
		floor(
			(available_width - ENERGY_BADGE_SEPARATION * float(maxi(0, slot_count - 1)))
			/ float(maxi(1, slot_count))
		),
	)
	badge_size = maxf(MINIMUM_ENERGY_BADGE_SIZE, badge_size)
	for index in range(visible_group_count):
		var row_value: Variant = grouped[index]
		var row: Dictionary = row_value
		var energy_type := str(row.get("type", "Colorless"))
		var count := int(row.get("count", 1))
		energy_row.add_child(_new_energy_badge(
			energy_type,
			count,
			str(row.get("icon_card_id", "")),
			str(row.get("display_name", "")),
			badge_size,
		))
	if has_overflow:
		var overflow_count := 0
		for index in range(visible_group_count, grouped.size()):
			overflow_count += int((grouped[index] as Dictionary).get("count", 1))
		energy_row.add_child(_new_energy_overflow_badge(overflow_count, badge_size))


func _new_energy_badge(
	energy_type: String,
	count: int,
	icon_card_id := "",
	display_name := "",
	badge_size := DEFAULT_ENERGY_BADGE_SIZE,
) -> Control:
	var badge := Control.new()
	badge.name = "EnergyBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_PASS
	badge.custom_minimum_size = Vector2(badge_size, badge_size)
	var accessible_name := (
		display_name
		if not display_name.is_empty()
		else str(ENERGY_DISPLAY_NAMES.get(energy_type, energy_type))
	)
	badge.tooltip_text = "%s x%d" % [accessible_name, count]
	badge.accessibility_name = badge.tooltip_text

	var plate := Panel.new()
	plate.name = "Plate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.025, 0.055, 0.09, 0.92),
			12,
			_energy_color(energy_type).lightened(0.28),
			1,
			0,
		),
	)
	badge.add_child(plate)

	var texture: Texture2D = (
		ENERGY_ICONS.texture_for_card_id(icon_card_id)
		if not icon_card_id.is_empty()
		else ENERGY_ICONS.texture_for(energy_type)
	)
	if texture == null:
		var fallback := Label.new()
		fallback.name = "FallbackLabel"
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.text = _energy_label(energy_type, count)
		fallback.add_theme_font_size_override("font_size", 10)
		fallback.add_theme_color_override("font_color", DesignTokens.TEXT)
		fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
		fallback.add_theme_constant_override("outline_size", 2)
		badge.add_child(fallback)
		return badge

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 2.0
	icon.offset_top = 2.0
	icon.offset_right = -2.0
	icon.offset_bottom = -2.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = texture
	badge.add_child(icon)

	if count > 1:
		var count_badge := Label.new()
		count_badge.name = "CountBadge"
		count_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_badge.anchor_left = 1.0
		count_badge.anchor_top = 1.0
		count_badge.anchor_right = 1.0
		count_badge.anchor_bottom = 1.0
		count_badge.offset_left = -14.0
		count_badge.offset_top = -14.0
		count_badge.offset_right = 1.0
		count_badge.offset_bottom = 1.0
		count_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		count_badge.text = str(count)
		count_badge.add_theme_font_size_override("font_size", 9)
		count_badge.add_theme_color_override("font_color", Color.WHITE)
		count_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color(0.02, 0.04, 0.075, 0.98),
				7,
				Color(1, 1, 1, 0.82),
				1,
				0,
			),
		)
		badge.add_child(count_badge)
	return badge


func _new_energy_overflow_badge(count: int, badge_size: float) -> Control:
	var badge := Control.new()
	badge.name = "EnergyOverflowBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_PASS
	badge.custom_minimum_size = Vector2(badge_size, badge_size)
	badge.tooltip_text = "另有 %d 张附加能量" % count
	badge.accessibility_name = badge.tooltip_text

	var plate := Panel.new()
	plate.name = "Plate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.025, 0.055, 0.09, 0.94),
			12,
			DesignTokens.GOLD.lightened(0.12),
			1,
			0,
		),
	)
	badge.add_child(plate)

	var label := Label.new()
	label.name = "OverflowLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = "+%d" % count
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
	label.add_theme_constant_override("outline_size", 2)
	badge.add_child(label)
	return badge


func _set_energy_summary(grouped: Array[Dictionary]) -> void:
	if is_hidden_card or empty or pokemon == null or grouped.is_empty():
		tooltip_text = ""
		accessibility_description = ""
		return
	var parts: Array[String] = []
	for row in grouped:
		var display_name := str(row.get("display_name", ""))
		if display_name.is_empty():
			display_name = str(ENERGY_DISPLAY_NAMES.get(
				str(row.get("type", "Colorless")),
				str(row.get("type", "Colorless")),
			))
		parts.append("%s ×%d" % [display_name, int(row.get("count", 1))])
	var summary := "附加能量：%s" % "、".join(parts)
	tooltip_text = summary
	accessibility_description = summary


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
		var icon_card_id := (
			energy_id
			if not ENERGY_ICONS.path_for_card_id(energy_id).is_empty()
			else ""
		)
		var group_key := (
			"card:%s" % icon_card_id
			if not icon_card_id.is_empty()
			else "type:%s" % energy_type
		)
		if not counts.has(group_key):
			counts[group_key] = {
				"type": energy_type,
				"count": 0,
				"icon_card_id": icon_card_id,
				"display_name": (
					str(card.get("name", energy_type))
					if not icon_card_id.is_empty()
					else ""
				),
			}
		counts[group_key]["count"] = int(counts[group_key].get("count", 0)) + 1
	var result: Array[Dictionary] = []
	for group_key in counts:
		result.append(counts[group_key] as Dictionary)
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := "%s:%s" % [
			str(left.get("type", "")), str(left.get("icon_card_id", "")),
		]
		var right_key := "%s:%s" % [
			str(right.get("type", "")), str(right.get("icon_card_id", "")),
		]
		return left_key < right_key
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


func _dispose_flash_overlay(overlay_value: Variant) -> void:
	var overlay_is_valid := is_instance_valid(overlay_value)
	var live_overlays: Array[ColorRect] = []
	for existing_value in _flash_overlays:
		if not is_instance_valid(existing_value):
			continue
		if overlay_is_valid and existing_value == overlay_value:
			continue
		live_overlays.append(existing_value)
	_flash_overlays = live_overlays
	if not overlay_is_valid:
		return
	var overlay := overlay_value as ColorRect
	if overlay:
		overlay.queue_free()


func _clear_flash_overlays() -> void:
	for overlay_value in _flash_overlays.duplicate():
		if not is_instance_valid(overlay_value):
			continue
		var overlay := overlay_value as ColorRect
		if overlay:
			overlay.queue_free()
	_flash_overlays.clear()


func _card_data(value: String) -> Dictionary:
	var database := _root_child("CardDatabase")
	if database and database.has_method("get_card"):
		return database.call("get_card", value)
	if catalog:
		return catalog.get_card(value)
	return {}


func _action_signature(action: GameAction) -> String:
	if action == null:
		return ""
	var parts: Array[String] = [
		action.action,
		str(action.actor),
		str(action.terminal),
		action.action_id,
		_entity_signature(action.source),
		_entity_signature(action.target),
	]
	var keys: Array = action.params.keys()
	keys.sort()
	for key in keys:
		parts.append("%s=%s" % [str(key), _value_signature(action.params[key])])
	return "|".join(parts)


func _entity_signature(ref: EntityRef) -> String:
	if ref == null:
		return ""
	return "%s,%d,%s,%s,%d,%s,%s" % [
		ref.kind,
		ref.player,
		ref.zone,
		ref.slot,
		ref.index,
		ref.attachment_type,
		ref.card_id,
	]


func _value_signature(value: Variant) -> String:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var parts: Array[String] = []
		for key in keys:
			parts.append("%s:%s" % [str(key), _value_signature(value[key])])
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var parts: Array[String] = []
		for item in value:
			parts.append(_value_signature(item))
		return "[" + ",".join(parts) + "]"
	return str(value)


func _card_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var texture_cache := _card_texture_cache()
	if texture_cache and texture_cache.has_method("get_texture"):
		return texture_cache.call("get_texture", path) as Texture2D
	return (
		load(path) as Texture2D
		if ResourceLoader.exists(path)
		else null
	)


func _card_texture_cache() -> Node:
	if _texture_cache and is_instance_valid(_texture_cache):
		return _texture_cache
	_texture_cache = _root_child("CardTextureCache")
	return _texture_cache


func _reduced_motion_enabled() -> bool:
	var settings := _root_child("AppSettings")
	return bool(settings.get("reduced_motion")) if settings else false


func _root_child(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)

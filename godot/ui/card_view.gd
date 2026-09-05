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
signal hovered_changed(hovered: bool)

const LONG_PRESS_MSEC := 350
const MOUSE_DRAG_THRESHOLD := 8.0
const TOUCH_DRAG_THRESHOLD := 12.0
const TOUCH_SCROLL_AXIS_RATIO := 1.25
const MINIMUM_TOUCH_TARGET := 48.0
const ENERGY_ICONS := preload("res://ui/energy_icon_catalog.gd")
const ATTACHMENT_VISUALS := preload("res://ui/attachment_visual_descriptor.gd")
const ENERGY_COUNT_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const CARD_BACK_TEXTURE: Texture2D = preload("res://assets/cards/card_back.webp")
const MIN_CARD_CORNER_RADIUS := 3
const MAX_CARD_CORNER_RADIUS := 6


class EnergyCountBadgeVisual:
	extends Control

	var _count_text := ""
	var _draw_font: Font
	var _draw_font_size := 10


	func configure(value: String, draw_font: Font, draw_font_size: int) -> void:
		_count_text = value
		_draw_font = draw_font
		_draw_font_size = draw_font_size
		set_meta("count_text", value)
		set_meta("font_size", draw_font_size)
		set_meta("outline_size", 1)
		queue_redraw()


	func _draw() -> void:
		var background := get_theme_stylebox("normal")
		if background != null:
			draw_style_box(background, Rect2(Vector2.ZERO, size))
		if _draw_font == null or _count_text.is_empty():
			return
		var text_width := _draw_font.get_string_size(
			_count_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			_draw_font_size,
		).x
		var baseline := (
			(size.y - _draw_font.get_height(_draw_font_size)) * 0.5
			+ _draw_font.get_ascent(_draw_font_size)
		)
		var origin := Vector2((size.x - text_width) * 0.5, baseline)
		for outline_offset in [
			Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1),
		]:
			draw_string(
				_draw_font,
				origin + outline_offset,
				_count_text,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				_draw_font_size,
				Color(0, 0, 0, 0.98),
			)
		draw_string(
			_draw_font,
			origin,
			_count_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			_draw_font_size,
			Color.WHITE,
		)


@export_category("Card Layout")
@export var selected_lift := 12.0
@export var hover_lift := 6.0
@export var selected_scale := 1.06
@export var hover_scale := 1.035
@export var interaction_duration := 0.12

const MAXIMUM_ENERGY_BADGES := 4
const MINIMUM_ENERGY_BADGE_SIZE := 17.0
const DEFAULT_ENERGY_BADGE_SIZE := 25.0
const ENERGY_BADGE_SEPARATION := 2.0

var card_id := ""
var local_visual_id := ""
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

@onready var interaction_root: Control = %InteractionRoot
@onready var feedback_root: Control = %FeedbackRoot
@onready var content_root: Control = %ContentRoot
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
@onready var animation_player: AnimationPlayer = %AnimationPlayer

var _press_msec := 0
var _press_position := Vector2.ZERO
var _pressed := false
var _touch_pointer := -1
var _touch_scrolling := false
var _hovered := false
var _base_position := Vector2.ZERO
var _has_base_position := false
var _content_signature := ""
var _disabled_reason := ""
var _legal_target_hint := ""
var _show_inline_target_hint := true
var _target_accent := DesignTokens.CYAN
var _allowed_drop_hand_indices: Array[int] = []
var _dragging := false
var _drag_masked := false
var _native_drag_masked := false
var _presentation_hidden := false
var _presentation_tween: Tween
var _presentation_motion_handle: MotionHandle
var _lift_tween: Tween
var _shake_tween: Tween
var _shake_motion_handle: MotionHandle
var _interaction_target_offset := Vector2.ZERO
var _interaction_target_scale := Vector2.ONE
var _interaction_target_reduced := false
var _interaction_target_initialized := false
var _active_state_animation := ""
var _flash_overlays: Array[ColorRect] = []
var _table_depth := 0.5
var _near_side := true
var depth_edge: Panel
var battle_overlay: CardBattleOverlay
var top_gloss: ColorRect
var _empty_slot_label_text := ""


func set_local_visual_id(value: String) -> void:
	local_visual_id = value
	if value.is_empty():
		if has_meta("local_visual_id"):
			remove_meta("local_visual_id")
	else:
		set_meta("local_visual_id", value)


func _ready() -> void:
	set_process(false)
	visibility_changed.connect(_sync_detached_selection_ring)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE
	_resolve_scene_nodes()
	_normalize_interaction_overlay_z_order()
	battle_overlay._ensure_overlay_nodes()
	_make_card_content_input_transparent()
	resized.connect(_on_resized)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_on_resized()
	_refresh()
	_sync_detached_selection_ring()
	target_glow.visible = targetable
	_refresh_interaction_visuals()
	_refresh_state_animation()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _dragging:
		_set_native_drag_masked(false)
		_dragging = false
		drag_ended.emit()


func _process(_delta: float) -> void:
	# SelectionRing intentionally stays at the legacy root path for ChoicePanel
	# styling compatibility. Mirror the layered transforms without ever writing
	# CardView.position, which belongs exclusively to the external layout owner.
	_sync_detached_selection_ring()


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
	battle_overlay._layout_battle_overlay()


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
	show_inline_target_hint := true,
) -> void:
	if (
		actionable == p_actionable
		and _disabled_reason == disabled_reason
		and _legal_target_hint == legal_target_hint
		and _show_inline_target_hint == show_inline_target_hint
		and _allowed_drop_hand_indices == allowed_hand_indices
		and targetable == (not legal_target_hint.is_empty() or not allowed_hand_indices.is_empty())
	):
		return
	# Read-only presentation state supplied by the interaction router. CardView
	# visualizes legality but never derives or executes a game action itself.
	actionable = p_actionable
	_disabled_reason = disabled_reason
	_legal_target_hint = legal_target_hint
	_show_inline_target_hint = show_inline_target_hint
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


func set_disabled_reason(reason: String) -> void:
	_disabled_reason = reason
	_refresh_interaction_visuals()


func set_legal_target_hint(text: String) -> void:
	_legal_target_hint = text
	set_targetable(
		not _legal_target_hint.is_empty()
		or not _allowed_drop_hand_indices.is_empty()
	)


func set_allowed_drop_hand_indices(indices: Array) -> void:
	_replace_allowed_drop_hand_indices(indices)
	set_targetable(
		not _legal_target_hint.is_empty()
		or not _allowed_drop_hand_indices.is_empty()
	)


func clear_interaction_state() -> void:
	actionable = false
	_disabled_reason = ""
	_legal_target_hint = ""
	_show_inline_target_hint = true
	_allowed_drop_hand_indices.clear()
	set_targetable(false)
	_refresh_interaction_visuals()


func set_selected(value: bool) -> void:
	if selected == value:
		return
	selected = value
	_sync_detached_selection_ring()
	_refresh_state_animation()
	_refresh_empty_slot_visibility()
	_refresh_interaction_visuals()
	_update_lift()


func set_targetable(value: bool) -> void:
	targetable = value
	if not value:
		_legal_target_hint = ""
		_show_inline_target_hint = true
		_allowed_drop_hand_indices.clear()
		_target_accent = DesignTokens.CYAN
	if target_glow:
		target_glow.visible = value
	_refresh_state_animation()
	_refresh_empty_slot_visibility()
	_refresh_interaction_visuals()


func set_target_accent(value: Color = DesignTokens.CYAN) -> void:
	# Target accents are contextual (cyan for destinations, amber for attachment
	# sources). A transparent/default-like value falls back to cyan, and leaving
	# targetable state resets it so a later interaction cannot inherit stale UI.
	var resolved := value if value.a > 0.0 else DesignTokens.CYAN
	if _target_accent.is_equal_approx(resolved):
		return
	_target_accent = resolved
	_refresh_interaction_visuals()


func set_empty_label(text: String) -> void:
	_empty_slot_label_text = text
	if empty_label:
		empty_label.text = text
	_refresh_empty_slot_visibility()


func set_presentation_hidden(value: bool) -> void:
	_presentation_hidden = value
	_kill_presentation_tween()
	_set_presentation_alpha(0.0 if value else 1.0)


func reveal_presentation(
	duration: float = 0.14,
	delay: float = 0.0,
) -> MotionHandle:
	var handle := MotionHandle.new()
	_presentation_hidden = false
	_kill_presentation_tween()
	if duration <= 0.0:
		_set_presentation_alpha(1.0)
		handle.finish()
		return handle
	_resolve_scene_nodes()
	if content_root == null:
		modulate.a = 1.0
		handle.finish()
		return handle
	_presentation_tween = create_tween()
	if delay > 0.0:
		_presentation_tween.tween_interval(delay)
	_presentation_tween.tween_property(content_root, "modulate:a", 1.0, duration)
	_presentation_motion_handle = handle
	handle.bind_tween(_presentation_tween)
	handle.completed.connect(
		_on_presentation_motion_completed.bind(handle),
		CONNECT_ONE_SHOT,
	)
	return handle


func clear_presentation_state() -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	if _shake_tween and _shake_tween.is_valid():
		if _shake_motion_handle != null and not _shake_motion_handle.is_finished():
			_shake_motion_handle.cancel()
		else:
			_shake_tween.kill()
	_shake_tween = null
	_shake_motion_handle = null
	if feedback_root:
		feedback_root.position = Vector2.ZERO
	_clear_flash_overlays()
	# Older presentation callers may still mask the CardView root directly.
	# Reconcile that legacy alpha without using the layout transform properties.
	modulate.a = 1.0
	_set_presentation_alpha(1.0)


func is_presentation_hidden() -> bool:
	return _presentation_hidden


func set_drag_masked(value: bool) -> void:
	# This mask is owned by the drag coordinator and is deliberately independent
	# from presentation staging. A pending authoritative action can therefore keep
	# the source hidden after Godot's native drag has already ended.
	if _drag_masked == value:
		return
	_drag_masked = value
	_apply_content_visibility()


func is_drag_masked() -> bool:
	return _drag_masked


func clear_drag_mask() -> void:
	set_drag_masked(false)


func cancel_drag_state() -> void:
	# Resync/scene teardown must not wait for NOTIFICATION_DRAG_END: the native
	# drag may outlive the authoritative view replacement by one input frame.
	_pressed = false
	_touch_pointer = -1
	_touch_scrolling = false
	_dragging = false
	_set_native_drag_masked(false)
	set_drag_masked(false)


func global_center() -> Vector2:
	# Hand and table cards can be rotated, scaled and lifted around their center.
	# Transforming the local midpoint keeps presentation flights anchored to the
	# actual rendered card instead of the unrotated layout rectangle.
	if content_root:
		return content_root.get_global_transform_with_canvas() * (content_root.size * 0.5)
	return get_global_transform_with_canvas() * (size * 0.5)


func visual_global_bounds() -> Rect2:
	# Selection and hover deliberately transform InteractionRoot rather than the
	# layout-owned CardView root. Expose that rendered rectangle to table overlays
	# and hit tests so they follow the card the player actually sees.
	_resolve_scene_nodes()
	var visual_root := interaction_root if interaction_root != null else self
	var transform := visual_root.get_global_transform_with_canvas()
	var visual_size := visual_root.size
	var corners := PackedVector2Array([
		transform * Vector2.ZERO,
		transform * Vector2(visual_size.x, 0.0),
		transform * visual_size,
		transform * Vector2(0.0, visual_size.y),
	])
	var minimum := corners[0]
	var maximum := corners[0]
	for corner in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	return Rect2(minimum, maximum - minimum)


func contains_visual_global_point(global_point: Vector2) -> bool:
	_resolve_scene_nodes()
	var visual_root := interaction_root if interaction_root != null else self
	var local_point := (
		visual_root.get_global_transform_with_canvas().affine_inverse()
		* global_point
	)
	return _minimum_touch_rect(visual_root.size).has_point(local_point)




func _ensure_battle_overlay() -> void:
	if battle_overlay != null and is_instance_valid(battle_overlay):
		return
	battle_overlay = get_node_or_null("BattleOverlay") as CardBattleOverlay
	if battle_overlay == null:
		battle_overlay = CardBattleOverlay.new()
		battle_overlay.name = "BattleOverlay"
		add_child(battle_overlay)
	battle_overlay.configure(self)


func attachment_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	return battle_overlay.attachment_visual_global_rect(
		attachment_type, attachment_card_id, attachment_index,
	)


func prospective_attachment_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	return battle_overlay.prospective_attachment_visual_global_rect(
		attachment_type, attachment_card_id, attachment_index,
	)


func attachment_layout_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	return battle_overlay.attachment_layout_visual_global_rect(
		attachment_type, attachment_card_id, attachment_index,
	)

func _get_tooltip(_at_position: Vector2) -> String:
	# Card details have dedicated click/long-press surfaces. Native hover tooltips
	# duplicate that content, obscure the board, and behave poorly on touch.
	return ""


func attachment_anchor_global(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Vector2:
	return battle_overlay.attachment_visual_global_rect(
		attachment_type,
		attachment_card_id,
		attachment_index,
	).get_center()


func _has_point(point: Vector2) -> bool:
	# Input arrives in the layout root's local space, while hover/selection lift
	# and scale InteractionRoot. Transform through canvas space so the visible
	# raised edge remains clickable and the old, vacated rectangle does not.
	var global_point := get_global_transform_with_canvas() * point
	return contains_visual_global_point(global_point)


func _minimum_touch_rect(control_size: Vector2) -> Rect2:
	# Compact landscape can render a bench card narrower than the recommended
	# touch target. Keep the artwork unchanged while expanding only its hit shape
	# around the same center; sibling Z/order resolves the rare overlap.
	var hit_size := Vector2(
		maxf(control_size.x, MINIMUM_TOUCH_TARGET),
		maxf(control_size.y, MINIMUM_TOUCH_TARGET),
	)
	return Rect2((control_size - hit_size) * 0.5, hit_size)


func flash(color: Color, duration: float = 0.3) -> MotionHandle:
	var handle := MotionHandle.new()
	if frame == null:
		handle.finish()
		return handle
	var overlay := ColorRect.new()
	_flash_overlays.append(overlay)
	overlay.color = Color(color.r, color.g, color.b, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Stay above every local badge (maximum 9) without escaping the battle-card
	# layer and flashing over the HUD/action popover when a hand card is selected.
	overlay.z_index = 10
	(content_root if content_root else self).add_child(overlay)
	if duration <= 0.0 or _reduced_motion_enabled():
		overlay.color.a = 0.34
		var instant_tween := create_tween()
		instant_tween.tween_property(overlay, "color:a", 0.0, 0.08)
		instant_tween.tween_callback(_dispose_flash_overlay.bind(overlay))
		handle.bind_tween(instant_tween)
		return handle
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 0.58, duration * 0.28)
	tween.tween_property(overlay, "color:a", 0.0, duration * 0.72)
	tween.tween_callback(_dispose_flash_overlay.bind(overlay))
	handle.bind_tween(tween)
	return handle


func shake(strength: float = 7.0, duration: float = 0.26) -> MotionHandle:
	var handle := MotionHandle.new()
	_resolve_scene_nodes()
	if feedback_root == null:
		handle.finish()
		return handle
	if _reduced_motion_enabled():
		feedback_root.position = Vector2.ZERO
		handle.finish()
		return handle
	if _shake_tween and _shake_tween.is_valid():
		if _shake_motion_handle != null and not _shake_motion_handle.is_finished():
			_shake_motion_handle.cancel()
		else:
			_shake_tween.kill()
	feedback_root.position = Vector2.ZERO
	_shake_tween = create_tween()
	for offset in [
		Vector2(strength, 0),
		Vector2(-strength, 0),
		Vector2(strength * 0.65, 0),
		Vector2(-strength * 0.65, 0),
		Vector2.ZERO,
	]:
		_shake_tween.tween_property(
			feedback_root,
			"position",
			offset,
			duration / 5.0,
		)
	_shake_tween.tween_callback(func() -> void:
		feedback_root.position = Vector2.ZERO
		_shake_tween = null
		_shake_motion_handle = null
	)
	_shake_motion_handle = handle
	handle.bind_tween(_shake_tween)
	return handle


func _refresh() -> void:
	_resolve_scene_nodes()
	if frame == null or image == null or empty_label == null:
		return
	battle_overlay._ensure_overlay_nodes()
	frame.modulate.a = 1.0
	if shadow:
		shadow.modulate.a = 1.0
	if depth_edge:
		depth_edge.modulate.a = 1.0
	_refresh_statuses()
	var texture_cache := _root_child("CardTextureCache")
	var frame_color := Color("#15253a")
	var border_color := DesignTokens.BORDER
	var current_card := {}
	if is_hidden_card:
		image.texture = (
			texture_cache.call("get_texture", "res://assets/cards/card_back.webp") as Texture2D
			if texture_cache
			else CARD_BACK_TEXTURE
		)
		if image.texture == null:
			image.texture = CARD_BACK_TEXTURE
		empty_label.visible = false
		frame_color = Color("#15284e")
		border_color = DesignTokens.GOLD.darkened(0.3)
		battle_overlay._refresh_battle_overlay({}, border_color)
	elif empty:
		image.texture = null
		empty_label.visible = not _is_field_empty_slot()
		if _is_field_empty_slot():
			frame_color = Color(0.02, 0.05, 0.04, 0.03)
			border_color = Color(0.30, 0.80, 0.55, 0.10)
		else:
			frame_color = Color(0.025, 0.07, 0.055, 0.30)
			border_color = Color(0.30, 0.66, 0.45, 0.34)
		battle_overlay._refresh_battle_overlay({}, border_color)
	else:
		var card := _card_data(card_id)
		current_card = card
		image.texture = (
			texture_cache.call("get_texture", str(card.get("image_path", ""))) as Texture2D
			if texture_cache
			else null
		)
		empty_label.visible = image.texture == null
		empty_label.text = str(card.get("name", card_id))
		var energy_types: Array = card.get("energy_types", [])
		if not energy_types.is_empty():
			border_color = DesignTokens.type_color(str(energy_types[0]))
		battle_overlay._refresh_battle_overlay(current_card, border_color)
	frame.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			frame_color,
			_card_corner_radius(),
			border_color,
			2,
			0,
		),
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
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
				3,
				Color(1, 1, 1, 0.52),
				1,
				0,
			),
		)
		status_row.add_child(badge)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
		return
	if event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)
		return
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
			elif moved < MOUSE_DRAG_THRESHOLD:
				activated.emit(card_id, hand_index, owner_player, slot)
			accept_event()
	elif event is InputEventMouseMotion and _pressed and hand_index >= 0:
		if Vector2(event.position).distance_to(_press_position) >= MOUSE_DRAG_THRESHOLD:
			_begin_forced_drag()
			accept_event()


func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touch_pointer = event.index
		_touch_scrolling = false
		_pressed = true
		_press_msec = Time.get_ticks_msec()
		_press_position = event.position
		accept_event()
		return
	if event.index != _touch_pointer:
		return
	_touch_pointer = -1
	var was_pressed := _pressed
	_pressed = false
	if not was_pressed or _touch_scrolling or _dragging:
		accept_event()
		return
	var held := Time.get_ticks_msec() - _press_msec
	var moved := event.position.distance_to(_press_position)
	if held >= LONG_PRESS_MSEC and moved < TOUCH_DRAG_THRESHOLD and not card_id.is_empty():
		detail_requested.emit(card_id)
	elif moved < TOUCH_DRAG_THRESHOLD:
		activated.emit(card_id, hand_index, owner_player, slot)
	accept_event()


func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	if event.index != _touch_pointer or not _pressed:
		return
	if _touch_scrolling:
		var active_scroll := _ancestor_scroll_container()
		if active_scroll != null:
			active_scroll.scroll_horizontal -= int(event.relative.x)
		accept_event()
		return
	var displacement := event.position - _press_position
	if displacement.length() < TOUCH_DRAG_THRESHOLD:
		return
	if absf(displacement.x) >= absf(displacement.y) * TOUCH_SCROLL_AXIS_RATIO:
		_touch_scrolling = true
		var scroll := _ancestor_scroll_container()
		if scroll != null:
			scroll.scroll_horizontal -= int(event.relative.x)
		accept_event()
		return
	if displacement.y < -TOUCH_DRAG_THRESHOLD and hand_index >= 0:
		_begin_forced_drag()
		accept_event()


func _ancestor_scroll_container() -> ScrollContainer:
	var current := get_parent()
	while current != null:
		if current is ScrollContainer:
			return current as ScrollContainer
		current = current.get_parent()
	return null


func _begin_forced_drag() -> void:
	if _dragging:
		return
	var data: Variant = _get_drag_data(Vector2.ZERO)
	if data == null:
		return
	_pressed = false
	force_drag(data, null)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if hand_index < 0 or card_id.is_empty():
		return null
	if not _dragging:
		_dragging = true
		_set_native_drag_masked(true)
		drag_started.emit(hand_index)
	return {
		"kind": "hand_card",
		"hand_index": hand_index,
		"card_id": card_id,
	}


func drag_grab_offset_local() -> Vector2:
	# Keep the physical grab point stable when CardView hands visual ownership to
	# the table's persistent drag proxy. Clamping also makes synthetic/keyboard
	# drags deterministic when no real pointer press preceded the request.
	return Vector2(
		clampf(_press_position.x, 0.0, size.x),
		clampf(_press_position.y, 0.0, size.y),
	)


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
	if interaction_root:
		interaction_root.pivot_offset = interaction_root.size * 0.5
	if feedback_root:
		feedback_root.pivot_offset = feedback_root.size * 0.5
	if content_root:
		content_root.pivot_offset = content_root.size * 0.5
	if selection_ring:
		selection_ring.pivot_offset = selection_ring.size * 0.5
	battle_overlay._layout_battle_overlay()
	if (
		battle_overlay.energy_row != null
		and battle_overlay.energy_row.visible
		and pokemon != null
	):
		battle_overlay._refresh_energy_badges()
	_apply_depth_visuals()


func _on_mouse_entered() -> void:
	_hovered = true
	_update_lift()
	hovered_changed.emit(true)


func _on_mouse_exited() -> void:
	_hovered = false
	_pressed = false
	_update_lift()
	hovered_changed.emit(false)


func _update_lift() -> void:
	if not is_inside_tree() or not _has_base_position:
		return
	_resolve_scene_nodes()
	if interaction_root == null:
		return
	var desired_scale := Vector2.ONE
	var desired_offset := Vector2.ZERO
	if selected:
		desired_scale = Vector2.ONE * selected_scale
		desired_offset.y = -selected_lift
	elif _hovered:
		desired_scale = Vector2.ONE * hover_scale
		desired_offset.y = -hover_lift
	var reduced := _reduced_motion_enabled()
	if (
		_interaction_target_initialized
		and _interaction_target_offset.is_equal_approx(desired_offset)
		and _interaction_target_scale.is_equal_approx(desired_scale)
		and _interaction_target_reduced == reduced
	):
		return
	_interaction_target_initialized = true
	_interaction_target_offset = desired_offset
	_interaction_target_scale = desired_scale
	_interaction_target_reduced = reduced
	if reduced:
		if _lift_tween and _lift_tween.is_valid():
			_lift_tween.kill()
		_lift_tween = null
		interaction_root.scale = desired_scale
		interaction_root.position = desired_offset
		return
	if _lift_tween and _lift_tween.is_valid():
		_lift_tween.kill()
	_lift_tween = create_tween().set_parallel(true)
	_lift_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_lift_tween.tween_property(
		interaction_root, "scale", desired_scale, interaction_duration
	)
	_lift_tween.tween_property(
		interaction_root, "position", desired_offset, interaction_duration
	)


func remember_base_position() -> void:
	_base_position = position
	_has_base_position = true
	_update_lift()


func _refresh_state_animation() -> void:
	if animation_player == null and has_node("AnimationPlayer"):
		animation_player = get_node("AnimationPlayer") as AnimationPlayer
	if animation_player == null:
		return
	var desired_animation := "RESET"
	if _reduced_motion_enabled():
		desired_animation = "RESET"
	elif selected:
		desired_animation = "selected_pulse"
	elif targetable:
		desired_animation = "target_pulse"
	if _active_state_animation == desired_animation:
		return
	_active_state_animation = desired_animation
	animation_player.stop()
	animation_player.play(desired_animation)


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
	_ensure_battle_overlay()
	if interaction_root == null:
		interaction_root = get_node_or_null("InteractionRoot") as Control
	if feedback_root == null:
		feedback_root = get_node_or_null(
			"InteractionRoot/FeedbackRoot"
		) as Control
	if content_root == null:
		content_root = get_node_or_null(
			"InteractionRoot/FeedbackRoot/ContentRoot"
		) as Control
	var content_path := "InteractionRoot/FeedbackRoot/ContentRoot/"
	if shadow == null:
		shadow = get_node_or_null(content_path + "Shadow") as Panel
	if frame == null:
		frame = get_node_or_null(content_path + "Frame") as Panel
	if image == null:
		image = get_node_or_null(content_path + "Frame/Image") as TextureRect
	if empty_label == null:
		empty_label = get_node_or_null(content_path + "Frame/EmptyLabel") as Label
	if status_row == null:
		status_row = get_node_or_null(content_path + "Frame/StatusRow") as HBoxContainer
	if selection_ring == null:
		selection_ring = get_node_or_null("SelectionRing") as Panel
	if target_glow == null:
		target_glow = get_node_or_null(content_path + "TargetGlow") as Panel
	if actionable_marker == null:
		actionable_marker = get_node_or_null(content_path + "ActionableMarker") as Panel
	if interaction_hint == null:
		interaction_hint = get_node_or_null(content_path + "InteractionHint") as Panel
	if interaction_hint_label == null:
		interaction_hint_label = get_node_or_null(
			content_path + "InteractionHint/InteractionHintLabel"
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


func _make_card_content_input_transparent() -> void:
	# CardView owns the full pointer gesture. Visual descendants must not become
	# separate hit targets or they can split a press/release pair and prevent the
	# card's activation, long-press, or drag handlers from completing.
	for child in get_children():
		_make_control_branch_input_transparent(child)


func _make_control_branch_input_transparent(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_make_control_branch_input_transparent(child)


func _refresh_interaction_visuals() -> void:
	_resolve_scene_nodes()
	# Only one card-outline state is shown at a time. A selected source stays gold,
	# a legal target uses the stronger cyan target treatment, and an otherwise
	# actionable card gets the quiet outer ring below.
	if selection_ring:
		selection_ring.visible = selected and _content_is_visible()
	if target_glow:
		target_glow.visible = targetable and not selected
		var target_style := DesignTokens.panel_style(
			Color.TRANSPARENT,
			_outline_corner_radius(),
			_target_accent,
			3,
			0,
		)
		target_style.draw_center = false
		var target_shadow := _target_accent
		target_shadow.a = 0.46
		target_style.shadow_color = target_shadow
		target_style.shadow_size = 5
		target_style.shadow_offset = Vector2.ZERO
		target_glow.add_theme_stylebox_override("panel", target_style)
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
			_outline_corner_radius(),
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
		hint_color = _target_accent
	elif selected and not actionable and not _disabled_reason.is_empty():
		hint_text = _disabled_reason
	if interaction_hint:
		# Attachment-source choices already expose their instruction in the battle
		# task header and in the anchored popover. Repeating it as an opaque strip
		# over the Pokemon makes the card bottom and its badges harder to read.
		interaction_hint.visible = (
			_show_inline_target_hint and not hint_text.is_empty()
		)
		interaction_hint.add_theme_stylebox_override(
			"panel",
			DesignTokens.panel_style(
				Color(0.018, 0.042, 0.07, 0.94),
				4,
				hint_color,
				1,
				0,
			),
		)
	if interaction_hint_label:
		interaction_hint_label.text = hint_text
		interaction_hint_label.add_theme_color_override("font_color", hint_color)
	battle_overlay._refresh_accessibility_summary()


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


func _card_corner_radius() -> int:
	var card_width := size.x if size.x > 0.0 else custom_minimum_size.x
	return clampi(
		int(round(card_width / 24.0)),
		MIN_CARD_CORNER_RADIUS,
		MAX_CARD_CORNER_RADIUS,
	)


func _outline_corner_radius() -> int:
	return mini(MAX_CARD_CORNER_RADIUS, _card_corner_radius() + 1)


func _apply_card_corner_styles() -> void:
	var card_radius := _card_corner_radius()
	_set_control_corner_radius(shadow, "panel", card_radius)
	_set_control_corner_radius(frame, "panel", card_radius)
	_set_control_corner_radius(target_glow, "panel", _outline_corner_radius())
	_set_control_corner_radius(selection_ring, "panel", _outline_corner_radius())
	_set_control_corner_radius(actionable_marker, "panel", _outline_corner_radius())
	_set_control_corner_radius(depth_edge, "panel", card_radius)


func _set_control_corner_radius(
	control: Control,
	style_name: String,
	radius: int,
) -> void:
	if control == null:
		return
	var current := control.get_theme_stylebox(style_name) as StyleBoxFlat
	if current == null:
		return
	if (
		current.corner_radius_top_left == radius
		and current.corner_radius_top_right == radius
		and current.corner_radius_bottom_right == radius
		and current.corner_radius_bottom_left == radius
	):
		return
	var shaped := current.duplicate() as StyleBoxFlat
	shaped.corner_radius_top_left = radius
	shaped.corner_radius_top_right = radius
	shaped.corner_radius_bottom_right = radius
	shaped.corner_radius_bottom_left = radius
	control.add_theme_stylebox_override(style_name, shaped)


func _apply_depth_visuals() -> void:
	if shadow:
		var shadow_drop := 2.5 + _table_depth * 4.0
		shadow.offset_left = 0.5 + _table_depth
		shadow.offset_top = shadow_drop
		shadow.offset_right = 1.0 + _table_depth * 1.5
		shadow.offset_bottom = shadow_drop + 1.0
	if depth_edge:
		var edge := 1.0 + _table_depth * 2.5
		depth_edge.offset_left = edge
		depth_edge.offset_top = edge
		depth_edge.offset_right = edge + 0.75
		depth_edge.offset_bottom = edge + 0.75
		depth_edge.add_theme_stylebox_override(
			"panel",
			DesignTokens.panel_style(
				Color(0, 0, 0, 0.30 + _table_depth * 0.18),
				_card_corner_radius(),
				Color(0, 0, 0, 0.0),
				0,
				0,
			),
		)
	_apply_card_corner_styles()


func _kill_presentation_tween() -> void:
	if _presentation_motion_handle != null and not _presentation_motion_handle.is_finished():
		_presentation_motion_handle.cancel()
	elif _presentation_tween and _presentation_tween.is_valid():
		_presentation_tween.kill()
	_presentation_tween = null
	_presentation_motion_handle = null


func _on_presentation_motion_completed(
	_completed_handle: MotionHandle,
	expected_handle: MotionHandle,
) -> void:
	if _presentation_motion_handle == expected_handle:
		_presentation_motion_handle = null
		_presentation_tween = null


func _set_presentation_alpha(alpha: float) -> void:
	_resolve_scene_nodes()
	if content_root:
		content_root.modulate.a = clampf(alpha, 0.0, 1.0)
	else:
		modulate.a = clampf(alpha, 0.0, 1.0)
	_sync_detached_selection_ring()


func _set_native_drag_masked(value: bool) -> void:
	if _native_drag_masked == value:
		return
	_native_drag_masked = value
	_apply_content_visibility()


func _apply_content_visibility() -> void:
	_resolve_scene_nodes()
	if content_root:
		content_root.visible = _content_is_visible()
	_sync_detached_selection_ring()


func _content_is_visible() -> bool:
	return not _drag_masked and not _native_drag_masked


func _sync_detached_selection_ring() -> void:
	set_process(selected and is_visible_in_tree())
	if selection_ring == null:
		return
	var content_visible := _content_is_visible()
	if content_root:
		content_visible = content_visible and content_root.visible
		selection_ring.self_modulate.a = content_root.modulate.a
	else:
		selection_ring.self_modulate.a = modulate.a
	selection_ring.visible = selected and content_visible
	if interaction_root:
		selection_ring.scale = interaction_root.scale
		var feedback_offset := Vector2.ZERO
		if feedback_root:
			feedback_offset = feedback_root.position * interaction_root.scale
		selection_ring.position = interaction_root.position + feedback_offset
	selection_ring.pivot_offset = selection_ring.size * 0.5


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


func _reduced_motion_enabled() -> bool:
	var settings := _root_child("AppSettings")
	return bool(settings.get("reduced_motion")) if settings else false


func _root_child(node_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)

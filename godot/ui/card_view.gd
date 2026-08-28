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
var top_gloss: ColorRect
var hp_pill: Label
var damage_badge: Label
var energy_row: HBoxContainer
var tool_badge: Label
var _empty_slot_label_text := ""


func set_local_visual_id(value: String) -> void:
	local_visual_id = value
	if value.is_empty():
		if has_meta("local_visual_id"):
			remove_meta("local_visual_id")
	else:
		set_meta("local_visual_id", value)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE
	_resolve_scene_nodes()
	_normalize_interaction_overlay_z_order()
	_ensure_overlay_nodes()
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
	_layout_battle_overlay()


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
	_show_inline_target_hint = true
	_allowed_drop_hand_indices.clear()
	set_targetable(false)
	_refresh_interaction_visuals()


func set_selected(value: bool) -> void:
	selected = value
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


func set_drag_hidden(value: bool) -> void:
	# Compatibility-friendly semantic alias for callers that describe the visual
	# result rather than the mask source.
	set_drag_masked(value)


func is_drag_hidden() -> bool:
	return _drag_masked or _native_drag_masked


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


func _get_tooltip(_at_position: Vector2) -> String:
	# Card details have dedicated click/long-press surfaces. Native hover tooltips
	# duplicate that content, obscure the board, and behave poorly on touch.
	return ""


func attachment_anchor_global(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Vector2:
	return attachment_visual_global_rect(
		attachment_type,
		attachment_card_id,
		attachment_index,
	).get_center()


func attachment_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	# Attachments are summarized as badges on a Pokemon card. Motion that starts
	# at the Pokemon's centre makes it look as if the Pokemon itself moved, and is
	# especially ambiguous when an opponent chooses one of several bench slots.
	# Expose the complete rendered badge bounds so presentation can preserve its
	# visual footprint as well as a stable source/landing point.
	var anchor: Control
	match attachment_type:
		"energy":
			anchor = energy_row
			# The row spans the card width while its badges are packed from the
			# leading edge. Anchor to a rendered badge rather than the empty centre
			# of that container so the energy visibly peels out of the icon itself.
			if energy_row != null and energy_row.get_child_count() > 0:
				var energy_badges: Array[Control] = []
				for child_value in energy_row.get_children():
					var child := child_value as Control
					if child == null:
						continue
					energy_badges.append(child)
					var physical_indices: Array = child.get_meta("energy_indices", [])
					var card_ids: Array = child.get_meta("energy_card_ids", [])
					if (
						attachment_index >= 0
						and attachment_index in physical_indices
						and (
							attachment_card_id.is_empty()
							or attachment_card_id in card_ids
						)
					):
						anchor = child
						break
					if (
						anchor == energy_row
						and not attachment_card_id.is_empty()
						and attachment_card_id in card_ids
					):
						anchor = child
				if (
					anchor == energy_row
					and attachment_index >= 0
					and attachment_index < energy_badges.size()
				):
					anchor = energy_badges[attachment_index]
				elif anchor == energy_row and not energy_badges.is_empty():
					anchor = energy_badges[0]
		"tool":
			anchor = tool_badge
	if anchor != null and is_instance_valid(anchor) and anchor.visible:
		return _control_visual_global_rect(anchor)
	return Rect2(global_center(), Vector2.ZERO)


func prospective_attachment_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	# A serialized attach event lands before its target CardView is updated.  The
	# moving badge still needs the geometry of the group that will exist at
	# contact, especially when a new energy type creates/reorders a badge or falls
	# into overflow.  Keep that prediction beside the rendering algorithm so both
	# paths share the same capacity and sizing rules.
	if attachment_type == "tool" and pokemon != null:
		_resolve_scene_nodes()
		if tool_badge != null and tool_badge.visible:
			return _control_visual_global_rect(tool_badge)
		var overlay_parent := content_root if content_root != null else self
		return _local_control_rect_global_bounds(
			overlay_parent,
			_tool_badge_layout_rect(),
		)
	if (
		attachment_type != "energy"
		or pokemon == null
		or attachment_card_id.is_empty()
	):
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			attachment_index,
		)
	_resolve_scene_nodes()
	if energy_row == null:
		return Rect2(global_center(), Vector2.ZERO)
	var prospective_ids: Array = pokemon.energy_card_ids.duplicate()
	var target_index := attachment_index
	if (
		target_index >= 0
		and target_index < prospective_ids.size()
		and str(prospective_ids[target_index]) == attachment_card_id
	):
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			target_index,
		)
	if target_index >= 0 and target_index < prospective_ids.size():
		prospective_ids.insert(target_index, attachment_card_id)
	else:
		target_index = prospective_ids.size()
		prospective_ids.append(attachment_card_id)
	var grouped := ATTACHMENT_VISUALS.grouped_energy(prospective_ids, catalog)
	if grouped.is_empty():
		return Rect2(global_center(), Vector2.ZERO)
	return _energy_group_layout_global_rect(
		grouped,
		target_index,
		attachment_card_id,
		attachment_index,
	)


func attachment_layout_visual_global_rect(
	attachment_type: String,
	attachment_card_id: String = "",
	attachment_index: int = -1,
) -> Rect2:
	# Newly-created batch covers can be queried before BoxContainer has received
	# its first sort notification. Resolve current energy geometry from the same
	# deterministic layout math instead of briefly treating every child as x=0.
	if attachment_type != "energy" or pokemon == null:
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			attachment_index,
		)
	_resolve_scene_nodes()
	if energy_row == null:
		return Rect2(global_center(), Vector2.ZERO)
	var target_index := attachment_index
	if (
		target_index < 0
		or target_index >= pokemon.energy_card_ids.size()
		or (
			not attachment_card_id.is_empty()
			and str(pokemon.energy_card_ids[target_index]) != attachment_card_id
		)
	):
		target_index = -1
		if not attachment_card_id.is_empty():
			for index in range(pokemon.energy_card_ids.size()):
				if str(pokemon.energy_card_ids[index]) == attachment_card_id:
					target_index = index
					break
	if target_index < 0:
		return attachment_visual_global_rect(
			attachment_type,
			attachment_card_id,
			attachment_index,
		)
	var grouped := ATTACHMENT_VISUALS.grouped_energy(
		pokemon.energy_card_ids,
		catalog,
	)
	return _energy_group_layout_global_rect(
		grouped,
		target_index,
		attachment_card_id,
		attachment_index,
	)


func _energy_group_layout_global_rect(
	grouped: Array,
	target_index: int,
	attachment_card_id: String,
	attachment_index: int,
) -> Rect2:
	var layout := _energy_badge_layout(grouped)
	var capacity := int(layout.get("capacity", 1))
	var visible_group_count := int(layout.get("visible_group_count", 0))
	var badge_ordinal := -1
	for group_index in range(grouped.size()):
		var descriptor := grouped[group_index] as AttachmentVisualDescriptor
		if descriptor != null and target_index in descriptor.physical_indices:
			badge_ordinal = (
				mini(group_index, capacity - 1)
				if group_index >= visible_group_count
				else group_index
			)
			break
	if badge_ordinal < 0:
		return attachment_visual_global_rect(
			"energy",
			attachment_card_id,
			attachment_index,
		)
	var badge_size := float(layout.get("badge_size", DEFAULT_ENERGY_BADGE_SIZE))
	var local_rect := Rect2(
		Vector2(float(badge_ordinal) * (badge_size + ENERGY_BADGE_SEPARATION), 0.0),
		Vector2(badge_size, badge_size),
	)
	return _local_control_rect_global_bounds(energy_row, local_rect)


func _control_visual_global_rect(control: Control) -> Rect2:
	var transform := control.get_global_transform_with_canvas()
	var corners := PackedVector2Array([
		transform * Vector2.ZERO,
		transform * Vector2(control.size.x, 0.0),
		transform * control.size,
		transform * Vector2(0.0, control.size.y),
	])
	var minimum := corners[0]
	var maximum := corners[0]
	for corner in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	return Rect2(minimum, maximum - minimum)


func _local_control_rect_global_bounds(control: Control, local_rect: Rect2) -> Rect2:
	var transform := control.get_global_transform_with_canvas()
	var corners := PackedVector2Array([
		transform * local_rect.position,
		transform * Vector2(local_rect.end.x, local_rect.position.y),
		transform * local_rect.end,
		transform * Vector2(local_rect.position.x, local_rect.end.y),
	])
	var minimum := corners[0]
	var maximum := corners[0]
	for corner in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	return Rect2(minimum, maximum - minimum)


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
	_ensure_overlay_nodes()
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
		_refresh_battle_overlay(current_card, border_color)
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
	_layout_battle_overlay()
	if energy_row != null and energy_row.visible and pokemon != null:
		_refresh_energy_badges()
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
	_refresh_accessibility_summary()


func _ensure_overlay_nodes() -> void:
	if depth_edge != null:
		return
	_resolve_scene_nodes()
	var overlay_parent: Control = content_root if content_root else self
	depth_edge = Panel.new()
	depth_edge.name = "DepthEdge"
	depth_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	depth_edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	depth_edge.z_index = -1
	overlay_parent.add_child(depth_edge)
	overlay_parent.move_child(depth_edge, 1)

	top_gloss = ColorRect.new()
	top_gloss.name = "TopGloss"
	top_gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_gloss.color = Color(1, 1, 1, 0.09)
	top_gloss.z_index = 3
	overlay_parent.add_child(top_gloss)

	hp_pill = _new_overlay_label("HPPill")
	hp_pill.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_pill.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_pill.z_index = 8
	overlay_parent.add_child(hp_pill)

	damage_badge = _new_overlay_label("DamageBadge")
	damage_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	damage_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	damage_badge.z_index = 9
	overlay_parent.add_child(damage_badge)

	energy_row = HBoxContainer.new()
	energy_row.name = "EnergyRow"
	energy_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	energy_row.add_theme_constant_override("separation", int(ENERGY_BADGE_SEPARATION))
	energy_row.z_index = 8
	overlay_parent.add_child(energy_row)

	tool_badge = _new_overlay_label("ToolBadge")
	tool_badge.text = "道具"
	tool_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tool_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tool_badge.z_index = 8
	overlay_parent.add_child(tool_badge)


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
	hp_pill.tooltip_text = ""
	hp_pill.accessibility_name = "HP %d/%d" % [current, maximum]
	hp_pill.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
	hp_pill.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(hp_color, 4, Color(1, 1, 1, 0.78), 1, 0),
	)
	var damage := pokemon.damage_counters * 10
	if damage > 0:
		damage_badge.visible = true
		damage_badge.text = "%d" % damage
		damage_badge.tooltip_text = ""
		damage_badge.accessibility_name = "伤害 %d" % damage
		damage_badge.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
		damage_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.RED.lightened(0.16),
				4,
				Color(1, 1, 1, 0.72),
				1,
				0,
			),
		)
	_layout_battle_overlay()
	_refresh_energy_badges()
	if not pokemon.attached_tool_id.is_empty():
		tool_badge.visible = true
		tool_badge.tooltip_text = ""
		tool_badge.accessibility_name = "宝可梦道具：%s" % _card_data(
			pokemon.attached_tool_id
		).get("name", pokemon.attached_tool_id)
		tool_badge.add_theme_color_override("font_color", DesignTokens.TEXT)
		tool_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color("#213146"),
				3,
				border_color.lightened(0.25),
				1,
				0,
			),
		)


func _refresh_energy_badges() -> void:
	_clear_energy_badges()
	var badge_scale := clampf(size.x / 130.0, 0.68, 1.06)
	energy_row.size = Vector2(maxf(0.0, size.x - 10.0), 25.0 * badge_scale)
	if pokemon == null:
		_set_energy_summary([])
		return
	var grouped := _attached_energy_groups()
	_set_energy_summary(grouped)
	if grouped.is_empty():
		return
	var layout := _energy_badge_layout(grouped)
	var capacity := int(layout.get("capacity", 1))
	var has_overflow := bool(layout.get("has_overflow", false))
	var visible_group_count := int(layout.get("visible_group_count", 0))
	var badge_size := float(layout.get("badge_size", DEFAULT_ENERGY_BADGE_SIZE))
	for index in range(visible_group_count):
		var row_value: Variant = grouped[index]
		var row: Dictionary = row_value
		var energy_type := str(row.get("type", "Colorless"))
		# Badge numerals describe effective energy units. This differs from the
		# number of physical attachments for cards such as Double Turbo Energy and
		# for a shared stack of several Colorless-providing Special Energy cards.
		var count := int(row.get("visual_count", row.get("count", 1)))
		var badge := _new_energy_badge(
			energy_type,
			count,
			str(row.get("icon_card_id", "")),
			str(row.get("display_name", "")),
			badge_size,
			str(row.get("marker", "")),
			row.get("icon") as Texture2D,
			str(row.get("fallback_label", "?")),
		)
		badge.set_meta("energy_type", energy_type)
		badge.set_meta("energy_group_key", str(row.get("group_key", "")))
		badge.set_meta("energy_card_ids", row.get("card_ids", []).duplicate())
		badge.set_meta("energy_indices", row.get("indices", []).duplicate())
		badge.set_meta(
			"provided_energy_units",
			row.get("provided_energy_units", []).duplicate(),
		)
		badge.set_meta("provided_unit_count", int(row.get("provided_unit_count", 0)))
		badge.set_meta("physical_card_count", int(row.get("count", 1)))
		energy_row.add_child(badge)
	if has_overflow:
		var overflow_count := 0
		var overflow_card_ids: Array = []
		var overflow_indices: Array = []
		var overflow_group_keys: Array[String] = []
		for index in range(visible_group_count, grouped.size()):
			var overflow_row := grouped[index] as Dictionary
			overflow_count += int(overflow_row.get("count", 1))
			overflow_card_ids.append_array(overflow_row.get("card_ids", []))
			overflow_indices.append_array(overflow_row.get("indices", []))
			overflow_group_keys.append(str(overflow_row.get("group_key", "")))
		var overflow_badge := _new_energy_overflow_badge(overflow_count, badge_size)
		overflow_badge.set_meta("energy_card_ids", overflow_card_ids)
		overflow_badge.set_meta("energy_indices", overflow_indices)
		overflow_badge.set_meta("energy_group_keys", overflow_group_keys)
		energy_row.add_child(overflow_badge)


func _energy_badge_layout(grouped: Array) -> Dictionary:
	# Derive the badge budget from CardView, not EnergyRow's current minimum.
	# Otherwise old 24px children can keep a just-resized bench row artificially
	# large and make the next generation of badges perpetuate that overflow.
	var badge_scale := clampf(size.x / 130.0, 0.68, 1.06)
	var available_width := maxf(0.0, size.x - 10.0)
	var available_height := maxf(1.0, 25.0 * badge_scale)
	var maximum_badge_size := minf(DEFAULT_ENERGY_BADGE_SIZE, floor(available_height))
	var minimum_badge_size := minf(MINIMUM_ENERGY_BADGE_SIZE, maximum_badge_size)
	var capacity := clampi(
		int(floor(
			(available_width + ENERGY_BADGE_SEPARATION)
			/ (minimum_badge_size + ENERGY_BADGE_SEPARATION)
		)),
		1,
		MAXIMUM_ENERGY_BADGES,
	)
	var has_overflow := grouped.size() > capacity
	var visible_group_count := capacity - 1 if has_overflow else grouped.size()
	var slot_count := capacity if has_overflow else visible_group_count
	var badge_size := minf(
		maximum_badge_size,
		floor(
			(available_width - ENERGY_BADGE_SEPARATION * float(maxi(0, slot_count - 1)))
			/ float(maxi(1, slot_count))
		),
	)
	return {
		"capacity": capacity,
		"has_overflow": has_overflow,
		"visible_group_count": visible_group_count,
		"badge_size": maxf(minimum_badge_size, badge_size),
	}


func _new_energy_badge(
	energy_type: String,
	count: int,
	icon_card_id := "",
	display_name := "",
	badge_size := DEFAULT_ENERGY_BADGE_SIZE,
	marker := "",
	texture_override: Texture2D = null,
	fallback_label := "?",
) -> Control:
	var badge := Control.new()
	badge.name = "EnergyBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.custom_minimum_size = Vector2(badge_size, badge_size)
	badge.size = badge.custom_minimum_size
	var accessible_name := (
		display_name
		if not display_name.is_empty()
		else ENERGY_ICONS.display_name_for(energy_type)
	)
	badge.tooltip_text = ""
	badge.accessibility_name = "%s x%d" % [accessible_name, count]

	var texture: Texture2D = texture_override
	if texture == null:
		texture = (
			ENERGY_ICONS.texture_for_card_id(icon_card_id)
			if not icon_card_id.is_empty()
			else ENERGY_ICONS.texture_for(energy_type)
		)

	var plate := Panel.new()
	plate.name = "Plate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var plate_style := DesignTokens.panel_style(
		(
			Color(0.018, 0.038, 0.065, 0.14)
			if texture != null
			else Color(0.09, 0.115, 0.15, 0.82)
		),
		int(round(badge_size * 0.5)),
		_energy_color(energy_type).lightened(0.38),
		1,
		0,
	)
	plate_style.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
	plate_style.shadow_size = 1
	plate_style.shadow_offset = Vector2(0, 1)
	plate.add_theme_stylebox_override("panel", plate_style)
	badge.add_child(plate)

	if texture == null:
		var fallback := Label.new()
		fallback.name = "FallbackLabel"
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.text = fallback_label
		fallback.add_theme_font_size_override(
			"font_size",
			maxi(8, int(round(badge_size * 0.42))),
		)
		fallback.add_theme_color_override("font_color", DesignTokens.TEXT)
		fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
		fallback.add_theme_constant_override("outline_size", 2)
		badge.add_child(fallback)
	else:
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var icon_inset := maxf(1.0, round(badge_size * 0.07))
		icon.offset_left = icon_inset
		icon.offset_top = icon_inset
		icon.offset_right = -icon_inset
		icon.offset_bottom = -icon_inset
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = texture
		badge.add_child(icon)

		if not marker.is_empty():
			var marker_size := clampf(round(badge_size * 0.45), 8.0, 11.0)
			var marker_badge := Label.new()
			marker_badge.name = "SpecialMarker"
			marker_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			marker_badge.position = Vector2(-1.0, -1.0)
			marker_badge.size = Vector2(marker_size, marker_size)
			marker_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			marker_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			marker_badge.text = marker
			marker_badge.add_theme_font_size_override(
				"font_size",
				maxi(7, int(round(badge_size * 0.30))),
			)
			marker_badge.add_theme_color_override("font_color", Color.WHITE)
			marker_badge.add_theme_stylebox_override(
				"normal",
				DesignTokens.panel_style(
					Color(0.075, 0.10, 0.145, 0.90),
					int(round(marker_size * 0.5)),
					_energy_color(energy_type).lightened(0.42),
					1,
					0,
				),
			)
			badge.add_child(marker_badge)

	if count > 1:
		var count_text := str(count)
		var count_height := clampf(round(badge_size * 0.62), 11.0, 15.0)
		var extra_digit_width := float(maxi(0, count_text.length() - 1)) * 4.0
		var count_width := minf(badge_size, count_height + extra_digit_width)
		var count_badge := EnergyCountBadgeVisual.new()
		count_badge.name = "CountBadge"
		count_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_badge.position = Vector2(
			badge_size - count_width,
			badge_size - count_height,
		)
		count_badge.size = Vector2(count_width, count_height)
		count_badge.custom_minimum_size = count_badge.size
		count_badge.z_index = 4
		count_badge.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				Color(0.012, 0.028, 0.055, 0.98),
				int(round(count_height * 0.5)),
				Color(0.94, 0.975, 1.0, 0.98),
				1,
				0,
			),
		)
		count_badge.configure(
			count_text,
			ENERGY_COUNT_FONT,
			clampi(int(round(badge_size * 0.50)), 9, 12),
		)
		badge.add_child(count_badge)
	return badge


func _new_energy_overflow_badge(count: int, badge_size: float) -> Control:
	var badge := Control.new()
	badge.name = "EnergyOverflowBadge"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.custom_minimum_size = Vector2(badge_size, badge_size)
	badge.size = badge.custom_minimum_size
	badge.tooltip_text = ""
	badge.accessibility_name = "另有 %d 张附加能量" % count

	var plate := Panel.new()
	plate.name = "Plate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.055, 0.075, 0.105, 0.74),
			int(round(badge_size * 0.5)),
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
	label.add_theme_font_size_override(
		"font_size",
		maxi(8, int(round(badge_size * 0.38))),
	)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
	label.add_theme_constant_override("outline_size", 2)
	badge.add_child(label)
	return badge


func _set_energy_summary(grouped: Array[Dictionary]) -> void:
	_refresh_accessibility_summary(grouped)


func _refresh_accessibility_summary(energy_groups: Array[Dictionary] = []) -> void:
	var parts: Array[String] = []
	if is_hidden_card:
		parts.append("隐藏卡牌")
	elif empty:
		parts.append(_empty_slot_label_text if not _empty_slot_label_text.is_empty() else "空牌位")
	else:
		var card := _card_data(card_id)
		parts.append(str(card.get("name", card_id)))
		if pokemon != null:
			var maximum := _pokemon_max_hp(card, pokemon)
			var current := pokemon.current_hp(catalog) if catalog else maximum - (
				pokemon.damage_counters * 10
			)
			parts.append("HP %d/%d" % [current, maximum])
			var damage := pokemon.damage_counters * 10
			if damage > 0:
				parts.append("伤害 %d" % damage)
			if not pokemon.status_conditions.is_empty():
				parts.append("状态：%s" % "、".join(pokemon.status_conditions))
			if not pokemon.attached_tool_id.is_empty():
				parts.append("宝可梦道具：%s" % _card_data(
					pokemon.attached_tool_id
				).get("name", pokemon.attached_tool_id))
			if energy_groups.is_empty():
				energy_groups = _attached_energy_groups()
			var energy_parts: Array[String] = []
			for row in energy_groups:
				var display_name := str(row.get("display_name", ""))
				if display_name.is_empty():
					display_name = ENERGY_ICONS.display_name_for(
						str(row.get("type", "Colorless"))
					)
				energy_parts.append("%s ×%d" % [
					display_name,
					int(row.get("visual_count", row.get("count", 1))),
				])
			if not energy_parts.is_empty():
				parts.append("附加能量：%s" % "、".join(energy_parts))
	if selected and not actionable and not _disabled_reason.is_empty():
		parts.append(_disabled_reason)
	elif targetable and not _legal_target_hint.is_empty():
		parts.append(_legal_target_hint)
	var summary := "；".join(parts)
	tooltip_text = ""
	accessibility_description = summary
	accessibility_name = parts[0] if not parts.is_empty() else "卡牌"


func _clear_energy_badges() -> void:
	if energy_row == null:
		return
	for child in energy_row.get_children():
		energy_row.remove_child(child)
		child.queue_free()


func _attached_energy_groups() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if pokemon == null:
		return result
	for descriptor_value in ATTACHMENT_VISUALS.grouped_energy(
		pokemon.energy_card_ids,
		catalog,
	):
		var descriptor := descriptor_value as AttachmentVisualDescriptor
		if descriptor != null:
			result.append(descriptor.to_dictionary())
	return result


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
	var native_maximum := pokemon_value.max_hp(catalog)
	return native_maximum if native_maximum > 0 else maximum


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
	if interaction_hint != null:
		interaction_hint.offset_left = 5.0
		interaction_hint.offset_right = -5.0
		if energy_row.visible:
			# Source-selection hints used to sit on the same bottom strip as the
			# attachment badges. Reserve the energy row and keep the hint directly
			# above it so every physical attachment remains readable and anchorable.
			var hint_bottom := -26.0 * badge_scale - 2.0
			var hint_height := clampf(27.0 * badge_scale, 20.0, 29.0)
			interaction_hint.offset_bottom = hint_bottom
			interaction_hint.offset_top = hint_bottom - hint_height
		else:
			interaction_hint.offset_top = -34.0
			interaction_hint.offset_bottom = -5.0
	var tool_rect := _tool_badge_layout_rect()
	tool_badge.position = tool_rect.position
	tool_badge.size = tool_rect.size
	tool_badge.add_theme_font_size_override("font_size", int(10 * badge_scale))
	status_row.offset_left = -6.0
	status_row.offset_top = 6.0
	status_row.offset_right = -6.0
	if top_gloss:
		top_gloss.position = Vector2(3.0, 3.0)
		top_gloss.size = Vector2(maxf(0.0, size.x - 6.0), maxf(3.0, size.y * 0.14))


func _tool_badge_layout_rect() -> Rect2:
	var badge_scale := clampf(size.x / 130.0, 0.68, 1.06)
	return Rect2(
		Vector2(5.0, 5.0),
		Vector2(42.0, 20.0) * badge_scale,
	)


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

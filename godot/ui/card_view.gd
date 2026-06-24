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
@onready var info_panel: PanelContainer = %InfoPanel
@onready var name_label: Label = %NameLabel
@onready var hp_bar: ProgressBar = %HPBar
@onready var meta_label: Label = %MetaLabel
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


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
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
	_update_lift()


func set_targetable(value: bool) -> void:
	targetable = value
	if target_glow:
		target_glow.visible = value
	_refresh_state_animation()


func set_empty_label(text: String) -> void:
	if empty_label:
		empty_label.text = text


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
	if not is_node_ready():
		return
	_refresh_statuses()
	var frame_color := Color("#15253a")
	var border_color := DesignTokens.BORDER
	if is_hidden_card:
		image.texture = _card_texture("res://assets/cards/card_back.webp")
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
		var card := _card_data(card_id)
		image.texture = _card_texture(str(card.get("image_path", "")))
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
	frame.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(frame_color, 11, border_color, 2, 0),
	)


func _refresh_statuses() -> void:
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

class_name BattleMotionEntities
extends Node

var table: BattleTable


func configure(p_table: BattleTable) -> void:
	table = p_table


func _create_paper_card_token(
	texture: Texture2D,
	size_value: Vector2,
	transient_kind: String,
	z_value: int,
	depth: float = 0.55,
	single_face: bool = true,
) -> Control:
	var card := CardMotionEntity.new()
	card.name = transient_kind
	card.configure_motion("visual:%d" % card.get_instance_id())
	card.set_meta("battle_transient_visual", true)
	card.set_meta("battle_transient_kind", transient_kind)
	card.set_meta("paper_card_token", true)
	card.set_meta("paper_card_single_face", single_face)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = size_value
	card.custom_minimum_size = size_value
	card.pivot_offset = size_value * 0.5
	card.z_index = z_value

	var shadow := Panel.new()
	shadow.name = "PaperShadow"
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.position = Vector2.ZERO
	shadow.size = size_value
	var shadow_style := DesignTokens.shadow_style(int(8.0 + depth * 7.0))
	# Motion already separates the card from the table.  An offset filled panel
	# reads as a second card stuck underneath, so every transient card uses only
	# a transparent soft cast shadow.
	shadow_style.bg_color = Color.TRANSPARENT
	shadow_style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	shadow_style.shadow_size = 7
	shadow_style.shadow_offset = Vector2(0.0, 4.0)
	shadow.add_theme_stylebox_override(
		"panel",
		shadow_style,
	)
	card.add_child(shadow)

	var inset := (
		0.0
		if single_face
		else maxf(2.0, minf(size_value.x, size_value.y) * 0.032)
	)
	var image := TextureRect.new()
	image.name = "PaperImage"
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.position = Vector2(inset, inset)
	image.size = Vector2(
		maxf(1.0, size_value.x - inset * 2.0),
		maxf(1.0, size_value.y - inset * 2.0),
	)
	image.z_index = 2
	card.add_child(image)

	if not single_face:
		var gloss := ColorRect.new()
		gloss.name = "PaperGloss"
		gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gloss.color = Color(1.0, 1.0, 1.0, 0.10)
		gloss.position = Vector2(inset * 1.5, inset * 1.5)
		gloss.size = Vector2(
			maxf(1.0, size_value.x - inset * 3.0),
			maxf(3.0, size_value.y * 0.17),
		)
		gloss.z_index = 3
		card.add_child(gloss)
	return card

func _configure_attachment_badge_marker(
	card: Control,
	descriptor: AttachmentVisualDescriptor,
) -> void:
	if card == null or descriptor == null:
		return
	var marker_text := descriptor.marker
	if marker_text.is_empty() and descriptor.icon == null:
		marker_text = descriptor.fallback_label
	card.set_meta("attachment_badge_marker_text", marker_text)
	card.set_meta("attachment_badge_has_icon", descriptor.icon != null)
	var marker := card.get_node_or_null("AttachmentBadgeMarker") as Label
	if marker_text.is_empty():
		if marker != null:
			marker.visible = false
		return
	if marker == null:
		marker = Label.new()
		marker.name = "AttachmentBadgeMarker"
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		marker.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		marker.add_theme_color_override("font_color", Color.WHITE)
		marker.add_theme_color_override("font_outline_color", Color("#0b111b"))
		marker.add_theme_constant_override("outline_size", 3)
		marker.z_index = 4
		card.add_child(marker)
	marker.text = marker_text
	marker.visible = true
	_layout_attachment_badge_marker(card)

func _layout_attachment_badge_marker(card: Control) -> void:
	if card == null or not is_instance_valid(card):
		return
	var marker := card.get_node_or_null("AttachmentBadgeMarker") as Label
	if marker == null:
		return
	var diameter := minf(card.size.x, card.size.y)
	var has_icon := bool(card.get_meta("attachment_badge_has_icon", false))
	if has_icon:
		var marker_size := maxf(12.0, diameter * 0.48)
		marker.size = Vector2(marker_size, marker_size)
		marker.position = Vector2(
			maxf(0.0, card.size.x - marker_size),
			maxf(0.0, card.size.y - marker_size),
		)
		marker.add_theme_font_size_override(
			"font_size",
			maxi(9, roundi(marker_size * 0.48)),
		)
	else:
		marker.position = Vector2.ZERO
		marker.size = card.size
		marker.add_theme_font_size_override(
			"font_size",
			maxi(11, roundi(diameter * 0.42)),
		)

func _resize_paper_card_token(card: Control, size_value: Vector2) -> void:
	if card == null or not is_instance_valid(card):
		return
	card.size = size_value
	card.custom_minimum_size = size_value
	card.pivot_offset = size_value * 0.5
	var shadow := card.get_node_or_null("PaperShadow") as Panel
	if shadow:
		shadow.size = size_value
	var edge := card.get_node_or_null("PaperEdge") as Panel
	if edge:
		edge.size = size_value
	var face := card.get_node_or_null("PaperFace") as Panel
	if face:
		face.size = size_value
	var single_face := bool(card.get_meta("paper_card_single_face", true))
	var inset := (
		0.0
		if single_face
		else maxf(2.0, minf(size_value.x, size_value.y) * 0.032)
	)
	var image := card.get_node_or_null("PaperImage") as TextureRect
	if image:
		image.position = Vector2(inset, inset)
		image.size = Vector2(
			maxf(1.0, size_value.x - inset * 2.0),
			maxf(1.0, size_value.y - inset * 2.0),
		)
	var gloss := card.get_node_or_null("PaperGloss") as ColorRect
	if gloss:
		gloss.position = Vector2(inset * 1.5, inset * 1.5)
		gloss.size = Vector2(
			maxf(1.0, size_value.x - inset * 3.0),
			maxf(3.0, size_value.y * 0.17),
		)
	_layout_attachment_badge_marker(card)

func _spawn_flying_card(
	texture: Texture2D,
	start: Vector2,
	finish: Vector2,
	duration: float,
	delay: float,
	event_type: String,
	index: int,
	start_size: Vector2 = Vector2.ZERO,
	finish_size: Vector2 = Vector2.ZERO,
	start_rotation: float = 0.0,
	finish_rotation: float = 0.0,
	landing_view: Control = null,
	existing_flyer: Control = null,
	motion_event_id: String = "",
	landing_attachment_type: String = "",
	landing_attachment_card_id: String = "",
	landing_attachment_index: int = -1,
	flip_texture: Texture2D = null,
	stage_opponent_hand_landing: bool = false,
	opponent_hand_stage_count_delta: int = 0,
) -> Control:
	_prune_flyers()
	while existing_flyer == null and table.card_motion_layer.entities.size() >= table.card_motion_layer._max_active_flyers():
		var oldest: Control = table.card_motion_layer.entities.pop_front()
		_dispose_flyer(oldest)
	var default_size := table.motion_geometry._flying_card_size(event_type)
	var flying_size := start_size if start_size != Vector2.ZERO else default_size
	var landing_size := finish_size if finish_size != Vector2.ZERO else default_size
	var motion_start := start
	var flying: Control
	if existing_flyer != null and is_instance_valid(existing_flyer):
		flying = existing_flyer
		table.hand_presentation._cancel_hand_layout_motion(flying)
		motion_start = flying.position + flying.size * 0.5
		flying_size = flying.size
		# A staged hand proxy may already have reflowed, and a drag proxy may be
		# tilted at its parked target. Continue from that exact pose instead of
		# snapping back to the batch snapshot rotation.
		start_rotation = flying.rotation_degrees
		var previous := table.card_motion_layer.tweens.get(flying.get_instance_id()) as Tween
		if previous != null and previous.is_valid():
			previous.kill()
		table.card_motion_layer.tweens.erase(flying.get_instance_id())
		if flying not in table.card_motion_layer.entities:
			table.card_motion_layer.add(flying)
	else:
		flying = _create_paper_card_token(
			texture,
			flying_size,
			"CardMotionEntity",
			100 + index,
			table.motion_geometry._motion_depth_for_point((start + finish) * 0.5),
		)
	flying.set_meta("card_motion_entity", true)
	flying.set_meta("motion_start", motion_start)
	flying.set_meta("motion_finish", finish)
	flying.set_meta("motion_start_size", flying_size)
	flying.set_meta("motion_finish_size", landing_size)
	if landing_view != null:
		flying.set_meta("motion_landing_view", landing_view)
	if not landing_attachment_type.is_empty():
		flying.set_meta(
			"motion_landing_attachment_type",
			landing_attachment_type,
		)
	elif flying.has_meta("motion_landing_attachment_type"):
		flying.remove_meta("motion_landing_attachment_type")
	if not landing_attachment_card_id.is_empty():
		flying.set_meta(
			"motion_landing_attachment_card_id",
			landing_attachment_card_id,
		)
		flying.set_meta("motion_landing_attachment_index", landing_attachment_index)
	if not landing_attachment_type.is_empty():
		var landing_descriptor := AttachmentVisualDescriptor.resolve(
			landing_attachment_type,
			landing_attachment_card_id,
			landing_attachment_index,
			table.catalog,
		)
		_configure_attachment_badge_marker(flying, landing_descriptor)
	if flip_texture != null:
		flying.set_meta("motion_flip_texture", flip_texture)
		flying.set_meta("motion_flip_swapped", false)
		flying.set_meta(
			"motion_flip_to_attachment_badge",
			not landing_attachment_type.is_empty(),
		)
		var attachment_marker := flying.get_node_or_null(
			"AttachmentBadgeMarker",
		) as Label
		if attachment_marker != null and not landing_attachment_type.is_empty():
			attachment_marker.visible = false
	elif flying.has_meta("motion_flip_texture"):
		flying.remove_meta("motion_flip_texture")
		flying.remove_meta("motion_flip_swapped")
		flying.remove_meta("motion_flip_to_attachment_badge")
	if stage_opponent_hand_landing:
		flying.set_meta("opponent_hand_staged_landing", true)
		flying.set_meta(
			"opponent_hand_stage_count_delta",
			opponent_hand_stage_count_delta,
		)
	elif flying.has_meta("opponent_hand_staged_landing"):
		flying.remove_meta("opponent_hand_staged_landing")
		flying.remove_meta("opponent_hand_stage_count_delta")
	flying.position = motion_start - flying.size * 0.5
	flying.pivot_offset = flying.size * 0.5
	flying.rotation_degrees = start_rotation
	flying.modulate.a = 1.0
	table.card_motion_layer.add(flying)
	var drag_continuation := flying.has_meta("drag_session_id")
	var travel_distance := motion_start.distance_to(finish)
	if drag_continuation:
		# The player already performed the large spatial movement. Successful
		# authority only needs a short physical settle from the release/park pose;
		# replaying the normal 74 px arc reads as a second card placement.
		duration = minf(duration, clampf(travel_distance / 420.0, 0.12, 0.22))
		delay = 0.0
	var arc_height := (
		clampf(travel_distance * 0.16, 10.0, 26.0)
		if drag_continuation
		else maxf(
			table.motion_arc_height_min,
			travel_distance * table.motion_arc_distance_ratio,
		)
	)
	var control := Vector2(
		(motion_start.x + finish.x) * 0.5,
		minf(motion_start.y, finish.y) - arc_height - float(index) * table.motion_arc_stagger_height,
	)
	var spin := 2.0 if drag_continuation else (
		16.0 + float(index) * 2.0
		if event_type in ["cards_discarded", "pokemon_ko"]
		else -7.0 + float(index) * 3.0
	)
	var tween := create_tween()
	if delay > 0.0:
		tween.tween_interval(delay)
	table.card_motion_layer.bind_tween(flying, tween)
	tween.tween_method(
		_update_flyer.bind(
			flying,
			motion_start,
			control,
			finish,
			spin,
			flying_size,
			landing_size,
			start_rotation,
			finish_rotation,
		),
		0.0,
		1.0,
		duration,
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(_finish_flyer.bind(flying, finish, event_type))
	if landing_view != null:
		var landing_wait := (
			MotionPolicy.duration("draw_landing")
			if event_type in ["cards_drawn", "prize_taken"]
			else 0.22
		)
		var landing_feedback: Dictionary = table.presentation_runtime.landing_feedbacks.get(
			motion_event_id,
			{},
		)
		landing_wait = maxf(
			landing_wait,
			float(landing_feedback.get("camera_duration", 0.0)),
		)
		if bool(flying.get_meta("opponent_hand_staged_landing", false)):
			landing_wait = maxf(
				landing_wait,
				MotionPolicy.duration("hand_reflow"),
			)
		tween.tween_interval(landing_wait)
	table.card_motion_layer._register_event_motion(flying, motion_event_id, tween)
	return flying

func _update_flyer(
	progress: float,
	flying_value: Variant,
	start: Vector2,
	control: Vector2,
	finish: Vector2,
	spin: float,
	start_size: Vector2,
	finish_size: Vector2,
	start_rotation: float,
	finish_rotation: float,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	var dynamic_finish := table.card_motion_layer._motion_entity_finish(flying, finish)
	var dynamic_control := control + (dynamic_finish - finish) * 0.5
	var inverse := 1.0 - progress
	var point := (
		start * inverse * inverse
		+ dynamic_control * 2.0 * inverse * progress
		+ dynamic_finish * progress * progress
	)
	var size_value := start_size.lerp(finish_size, progress)
	_resize_paper_card_token(flying, size_value)
	flying.position = point - size_value * 0.5
	flying.rotation_degrees = (
		lerpf(start_rotation, finish_rotation, progress)
		+ sin(progress * PI) * spin * 0.12
	)
	var lift := 1.0 + sin(progress * PI) * 0.16
	var flip_scale := _update_flyer_flip(flying, progress)
	flying.scale = Vector2(lift * flip_scale, lift)
	flying.modulate.a = 1.0

func _update_flyer_flip(flying: Control, progress: float) -> float:
	if flying == null or not flying.has_meta("motion_flip_texture"):
		return 1.0
	var phase := clampf((progress - 0.32) / 0.34, 0.0, 1.0)
	if phase >= 0.5 and not bool(flying.get_meta("motion_flip_swapped", false)):
		var paper_image := flying.get_node_or_null("PaperImage") as TextureRect
		if paper_image != null:
			paper_image.texture = flying.get_meta("motion_flip_texture") as Texture2D
		var attachment_marker := flying.get_node_or_null(
			"AttachmentBadgeMarker",
		) as Label
		if attachment_marker != null:
			attachment_marker.visible = bool(flying.get_meta(
				"motion_flip_to_attachment_badge",
				false,
			))
		flying.set_meta("motion_flip_swapped", true)
	return maxf(0.025, absf(cos(phase * PI)))

func _finish_flyer(
	flying_value: Variant,
	finish: Vector2,
	event_type: String,
) -> void:
	if not is_instance_valid(flying_value):
		return
	var flying := flying_value as Control
	if flying == null:
		return
	finish = table.card_motion_layer._motion_entity_finish(flying, finish)
	table.card_motion_layer.tweens.erase(flying.get_instance_id())
	flying.set_meta("motion_completed", true)
	if flying.has_meta("motion_finish_size"):
		_resize_paper_card_token(
			flying,
			table.motion_geometry._vector_or_default(flying.get_meta("motion_finish_size"), flying.size),
		)
	flying.position = finish - flying.size * 0.5
	flying.scale = Vector2.ONE
	flying.modulate.a = 1.0
	if flying.has_meta("motion_flip_texture"):
		var paper_image := flying.get_node_or_null("PaperImage") as TextureRect
		if paper_image != null:
			paper_image.texture = flying.get_meta("motion_flip_texture") as Texture2D
		var attachment_marker := flying.get_node_or_null(
			"AttachmentBadgeMarker",
		) as Label
		if attachment_marker != null:
			attachment_marker.visible = bool(flying.get_meta(
				"motion_flip_to_attachment_badge",
				false,
			))
	var handed_off_to_local_hand := false
	if flying.has_meta("motion_landing_view"):
		var landing_view := table.presentation_runtime._valid_control(flying.get_meta("motion_landing_view"))
		if landing_view != null:
			handed_off_to_local_hand = (
				event_type in ["cards_drawn", "prize_taken"]
				and landing_view is CardView
				and (landing_view as CardView).hand_index >= 0
				and (landing_view as CardView).owner_player == table.view_player
			)
			var reveal_duration := (
				0.0
				if handed_off_to_local_hand
				else MotionPolicy.duration("draw_landing")
				if event_type in ["cards_drawn", "prize_taken"]
				else 0.14
			)
			var reveal_handle := table.presentation_runtime._reveal_presentation_node(
				landing_view,
				false,
				reveal_duration,
			)
			var event_id := str(flying.get_meta("motion_event_id", ""))
			if not event_id.is_empty() and table.hand_presentation._hand_transition_sequences.has(event_id):
				var row: Dictionary = table.hand_presentation._hand_transition_sequences[event_id]
				var landing_handles: Array = row.get("landing_handles", [])
				landing_handles.append(reveal_handle)
				row["landing_handles"] = landing_handles
				table.hand_presentation._hand_transition_sequences[event_id] = row
			_remove_revealed_node_from_events(landing_view)
	if not table.presentation_runtime._play_card_landing_feedback(flying, finish):
		table.presentation_runtime._burst_world_at_motion_point(
			finish,
			table.card_motion_layer._motion_landing_color(event_type),
			"card_land",
		)
	table.hand_presentation._adopt_opponent_hand_landing_flyer(flying)
	if handed_off_to_local_hand and is_instance_valid(flying):
		# The landing CardView now owns the visual and will participate in every
		# later insertion reflow.  Keeping the completed flyer visible at its old
		# landing pose produced a second, stale hand fan until the event ended.
		flying.visible = false
		flying.modulate.a = 0.0
		flying.set_meta("motion_visual_handed_off", true)

func _remove_revealed_node_from_events(node: Control) -> void:
	for event_id_value in table.presentation_runtime.reveals.keys():
		var event_id := str(event_id_value)
		var nodes: Array = table.presentation_runtime.reveals.get(event_id, [])
		if node in nodes:
			nodes.erase(node)
			table.presentation_runtime.reveals[event_id] = nodes

func _remove_revealed_node_for_event(node: Control, event_id: String) -> void:
	if node == null or event_id.is_empty() or not table.presentation_runtime.reveals.has(event_id):
		return
	var nodes: Array = table.presentation_runtime.reveals.get(event_id, [])
	nodes.erase(node)
	table.presentation_runtime.reveals[event_id] = nodes

func _prune_flyers() -> void:
	var live: Array[Control] = []
	for flyer in table.card_motion_layer.entities:
		if is_instance_valid(flyer) and not flyer.is_queued_for_deletion():
			live.append(flyer)
	table.card_motion_layer.entities.assign(live)

func _clear_active_flyers() -> void:
	# Cancel the rolling queues first. Otherwise cancelling an active item can
	# synchronously refill its newly freed slot while a resync is clearing the
	# presentation tree.
	table.card_motion_layer._clear_card_motion_batches()
	for tween_value in table.card_motion_layer.tweens.values():
		var tween := tween_value as Tween
		if tween and tween.is_valid():
			tween.kill()
	table.card_motion_layer.tweens.clear()
	for flyer in table.card_motion_layer.entities.duplicate():
		if is_instance_valid(flyer):
			table.card_motion_layer._release_shuffle_source_zone(flyer)
			table.card_motion_layer._complete_event_motion_entity(flyer)
			flyer.visible = false
			flyer.modulate.a = 0.0
			flyer.free()
	table.card_motion_layer.entities.clear()
	table.card_motion_layer._clear_shuffle_source_masks()
	_clear_effect_child_controls(["CardMotionEntity", "FlyingCard"])
	table.card_motion_layer._finish_all_event_motions()

func _clear_active_flyers_for_event(event_id: String) -> void:
	if event_id.is_empty():
		return
	table.card_motion_layer._clear_card_motion_batches_for_event(event_id)
	for flyer in table.card_motion_layer.entities.duplicate():
		if (
			is_instance_valid(flyer)
			and str(flyer.get_meta("motion_event_id", "")) == event_id
		):
			_dispose_flyer(flyer)

func _dispose_flyer(flying: Control) -> void:
	if not is_instance_valid(flying):
		return
	table.hand_presentation._cancel_hand_layout_motion(flying)
	table.card_motion_layer._release_shuffle_source_zone(flying)
	table.card_motion_layer._complete_event_motion_entity(flying)
	var tween := table.card_motion_layer.tweens.get(flying.get_instance_id()) as Tween
	if tween and tween.is_valid():
		tween.kill()
	table.card_motion_layer.tweens.erase(flying.get_instance_id())
	table.card_motion_layer.forget(flying)
	flying.visible = false
	flying.modulate.a = 0.0
	flying.free()

func _clear_effect_child_controls(prefixes: Array = []) -> void:
	if table.effects == null:
		return
	var active_prefixes := prefixes.duplicate()
	if active_prefixes.is_empty():
		active_prefixes = ["PresentationCover", "CardMotionEntity", "FlyingCard"]
	for child in table.effects.get_children():
		var control := child as Control
		if control == null or not is_instance_valid(control):
			continue
		# RevealLayer is a reusable presentation executor, not one of the
		# short-lived table.card_motion_layer.entities it owns.
		if control == table.reveal_layer:
			continue
		var name_value := str(control.name)
		var kind_value := str(control.get_meta("battle_transient_kind", ""))
		if (
			not prefixes.is_empty()
			and kind_value == "SnapshotOpponentHandProxy"
		):
			continue
		var should_clear := false
		for prefix_value in active_prefixes:
			var prefix := str(prefix_value)
			if name_value.begins_with(prefix) or kind_value == prefix:
				should_clear = true
				break
		if not should_clear and prefixes.is_empty():
			should_clear = true
		if not should_clear:
			continue
		table.card_motion_layer._release_shuffle_source_zone(control)
		table.card_motion_layer._complete_event_motion_entity(control)
		var instance_id := control.get_instance_id()
		var flyer_tween := table.card_motion_layer.tweens.get(instance_id) as Tween
		if flyer_tween and flyer_tween.is_valid():
			flyer_tween.kill()
		table.card_motion_layer.tweens.erase(instance_id)
		var cover_tween := table.presentation_runtime.cover_tweens.get(instance_id) as Tween
		if cover_tween and cover_tween.is_valid():
			cover_tween.kill()
		table.presentation_runtime.cover_tweens.erase(instance_id)
		table.card_motion_layer.entities.erase(control)
		control.visible = false
		control.modulate.a = 0.0
		if not control.is_queued_for_deletion():
			control.queue_free()
